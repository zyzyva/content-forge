# Content Forge Quick Start (MCP)

End-to-end walkthrough to get from "fresh checkout" to "drafts generated, ranked, ready to publish" using the MCP tool surface, no dashboard required.

Target user: solo operator who wants to drive content-forge from a Claude Code session.

## Prerequisites (one-time)

1. **Postgres running** and `content_forge_dev` DB created. If you booted via Phase 17.0's launchd plist, this is already done.
2. **Env vars set** (in your shell or via `.envrc` / a direnv-style hook):
   - `APIFY_TOKEN` — required for competitor scraping + Twitter/LinkedIn metrics fetching
   - `ANTHROPIC_API_KEY` — required for brief synthesis + multi-model ranking + bulk variant generation
   - `GEMINI_API_KEY` — optional, second smart model for synthesis. With both set, the brief generator runs both providers in parallel and synthesizes.
   - `MEDIA_FORGE_SECRET` — only needed if you want AI image generation or video processing in this session
   - `OPENCLAW_TOOL_SECRET` — only needed if you want OpenClaw (CLI / SMS) to also drive the tool surface alongside the MCP path
3. **MCP server registered with your Claude Code config.** Add to `~/.config/claude-code/mcp-servers.json` (or the equivalent for your install):
   ```json
   {
     "content-forge": {
       "command": "/Users/sales_king/projects/contentforge_ecosystem/content-forge/scripts/start-mcp.sh"
     }
   }
   ```
   See `docs/mcp-runbook.md` for the full registration mechanics if your install differs.

A default product **"AI Chatbot Services"** has already been seeded for you (UUID `784c909b-3d22-4791-8249-880daf5a59fe`). Edit the voice profile via the dashboard or by re-running the seed script with your refinements.

## The end-to-end loop

The numbered steps below are how you actually use content-forge. Each step is one MCP tool call you make from a Claude Code session.

### Step 1. Confirm the product

```
cf_list_products
```

Returns a list including "AI Chatbot Services" with its product id. The id is what every subsequent tool wants.

### Step 2. Add competitors to track

For the chatbot consultancy positioning, useful competitor accounts to scrape live somewhere in the local-services-marketing space. Examples:

- Marketing agencies serving HVAC / dental / legal: Twitter handles, LinkedIn pages
- Other AI chatbot vendors (Drift, Intercom, ManyChat for consumer / Tidio): Twitter, LinkedIn
- Industry voices: Greg Isenberg, marketing strategists with local-services content

For each one:

```
cf_add_competitor
  product_id: <your AI Chatbot Services product id>
  platform: twitter
  handle: <handle without @>
```

Repeat for `linkedin`, `reddit`, etc. as relevant. Realistic starter target: 3-5 competitors.

### Step 3. Trigger competitor scraping

```
cf_scrape_competitor
  competitor_id: <id from step 2>
```

Returns an enqueued job id. The Apify adapter (kaitoeasyapi for Twitter) runs in the background, lands posts in `competitor_posts`. Allow a few minutes.

Check progress with `cf_list_competitors product_id: <id>` — the `post_count` field grows as the scrape completes.

### Step 4. Read the top posts (sanity check)

```
cf_top_posts_for_synthesis
  product_id: <id>
  n: 10
  window: week
```

Returns the top engagement-scored posts across all your tracked competitors in the last week, each with their captured comment threads (when the post crossed the viral threshold). This is the input bundle the synthesizer reads.

### Step 5. Synthesize competitor intel

With both ANTHROPIC_API_KEY and GEMINI_API_KEY set, this happens automatically through the Oban-scheduled synthesizer. You can also trigger or read manually:

```
cf_get_intel
  product_id: <id>
  latest: true
```

Returns the latest `competitor_intel` row: summary, trending topics, winning formats, effective hooks, audience signals (when comments were available). This is what the brief generator reads as input.

If no intel exists yet, check `cf_list_pending_syntheses product_id: <id>` — when the API key isn't reachable, syntheses queue up here for you to complete manually by reading top posts and calling `cf_store_intel`.

### Step 6. Generate drafts

The dashboard or a triggered job is the natural surface here. From the dashboard at `/dashboard/products/<id>`, click "Generate brief + variants" — this runs `ContentBriefGenerator` → `OpenClawBulkGenerator` (LLM-backed) → drafts land in your review queue.

From an MCP session you'd Oban-enqueue these directly via Repo + worker calls (not currently a dedicated tool). Roadmap: add `cf_generate_brief` and `cf_generate_drafts` tools if the dashboard friction matters.

### Step 7. Review and approve

Dashboard at `/dashboard/drafts` — multi-model scores per draft (Anthropic + Gemini), composite ranking, approve / reject / override buttons. Blog drafts hit the 12.4 SEO publish gate; social drafts have no equivalent gate today.

For the MCP path:

```
draft_status
  draft_id: <id>
```

Returns the current status, score, blocker reason if any. Approve via the dashboard or via the new `cf_approve_draft` tool (Phase 16.4b) if you want a CLI-driven approval flow.

### Step 8. Publish

Approved drafts:

- **Blog drafts** — `BlogPublisher` fires on approval, hits the configured CMS webhook (WordPress / Generic / Ghost-deferred handlers from PR #1).
- **Social drafts** — currently require platform OAuth credentials on the product's `publishing_targets` map (separate from APIFY_TOKEN, which is for scraping and metrics fetching only). Twitter v2 OAuth, LinkedIn OAuth, etc. PR #2's `cf_publish_text` and `cf_publish_video` MCP tools can drive multi-platform fan-out via these creds once configured.

### Step 9. The feedback loop closes itself

After publishing:

- `MetricsPoller` runs every 6 hours (Oban cron from Phase 17.6) per active product
- It uses Apify (kaitoeasyapi for Twitter, per-platform Apify actors for the rest) to fetch engagement counts on every `PublishedPost`
- `ScoreboardEntry` rows compare predicted vs actual; outcome is `winner` or `loser`
- The corrective trigger fires only when our drop AND a tracked competitor wins in the same window — enqueues a week-windowed synthesis and a forced brief regeneration
- `WinnerRepurposingEngine` enqueues cross-platform repurposed drafts from winners

Verify the loop is closing via:

```
cf_recent_scoreboard
  product_id: <id>
```

Returns recent winners + losers per product + whether the corrective trigger fired in the last 24 hours.

## Where to start your first session

1. Confirm env vars are set (see prerequisites).
2. In a Claude Code session: `cf_list_products` to see "AI Chatbot Services" already seeded.
3. Add 3-5 competitor accounts via `cf_add_competitor`. Twitter handles are easiest to start with since the kaitoeasyapi actor is already configured.
4. Trigger scrapes via `cf_scrape_competitor` for each. Wait a few minutes.
5. Read `cf_top_posts_for_synthesis` to confirm the corpus has content.
6. Watch `cf_get_intel` for the first competitor intel row (or the dashboard equivalent).
7. From here you can hit the dashboard to drive draft generation, or wait for the Oban-scheduled synthesizer to run autonomously every 6 hours.

## Known limitations + planned follow-ups

- **`cf_publish_text` does not record `PublishedPost` rows** for free-form agent-authored text (the NOT NULL `draft_id` constraint rejects). Tracked as a follow-up slice: redesign to auto-create a Draft inside the tool with `status: "approved"` + `generating_model: "agent:cf_publish_text"`.
- **Video publishing** requires Media Forge Phase 4 (video features) to ship before content-forge's `VideoProducer` can hand off final encoding. Media Forge swarm runs in parallel; track at `/Users/sales_king/projects/media_forge/BUILDLOG.md`.
- **AI image generation** requires Media Forge Phase 6. Same parallel track.
- **Native platform OAuth credentials** (Twitter v2, LinkedIn, Facebook, etc.) need a per-product config UI or seed script. Today they live in `Product.publishing_targets` as a free-form map; document the keys per platform.

## Mental model

Content forge is the **orchestration brain**. It does not author your content end-to-end on its own. The right operating posture:

- **You decide** strategic positioning, target audience, voice (the product's `voice_profile`).
- **You curate** which competitors to track and which drafts to approve.
- **Content forge automates** the scrape → synthesize → generate → rank → publish → measure → adjust cycle once you've fed it the inputs.
- **The corrective loop is the differentiator** — it's why content forge gets smarter over time as it sees real engagement vs predicted engagement. Without you ever telling it which posts worked, it figures that out.
