# ContentForge Specification

## Overview

ContentForge is a standalone Elixir/Phoenix app that ingests a product's repo and website, then runs a tiered AI pipeline: OpenClaw (a fast local model) generates large batches of content variants — posts, blog drafts, and video scripts — then smarter models (Claude, Gemini, xAI) rank and critique each batch, and only the top-ranked items proceed to expensive production steps (video rendering, publishing). A feedback loop pulls performance metrics from each platform and feeds them back into the content brief, so the system learns what actually works over time. The app exposes both a LiveView dashboard and a REST API so OpenClaw and other external tools can drive the entire pipeline programmatically.

## Primary User

- **Who:** Solo developer/founder managing multiple products
- **Context:** Running locally or deployed alongside other apps in the provisioner ecosystem; used daily or on-demand to keep content flowing across platforms without manual writing
- **Goal:** Publish consistent, high-quality content about each product without doing the work manually — let AI generate in bulk, let smarter AI pick winners, and let the scheduler handle the rest

---

## Features

### Feature 1: Product Registry

**Purpose:** Register and configure each product so the system knows what to generate content about, where to publish it, and how often.

Acceptance criteria:
- [ ] A product has: name, repo URL (optional), site URL (optional), voice profile (text, required before first generation run), per-platform posting frequency, and a list of enabled publishing targets
- [ ] Products can be created, read, updated, and deleted via LiveView UI
- [ ] Products can be created, read, updated, and deleted via REST API
- [ ] Each product has a publishing target config: each platform (YouTube, LinkedIn, Twitter/X, Reddit, Facebook/Instagram, blog) has enabled/disabled toggle and a cadence (e.g. 3x/week, 1x/month)
- [ ] Products are stored in PostgreSQL
- [ ] Each product can register one or more blog webhook endpoints (URL + optional HMAC secret) for blog delivery
- [ ] Voice profile is a required text field on the product. Generation runs are blocked until a voice profile is set. The voice profile defines tone, vocabulary, personality, and communication style for all content generated for that product.
- [ ] The content brief always includes the voice profile as context for both generation (OC) and ranking (smart models). Ranking models should evaluate voice consistency as part of their scoring.
- [ ] If performance data shows content that drifts from the voice profile is outperforming on-brand content, the brief rewrite must flag this explicitly ("off-brand content is outperforming -- consider updating the voice profile") rather than silently shifting tone.

---

### Feature 2: Content Ingestion Pipeline

**Purpose:** Extract context from a product's repo and live site so AI has accurate, specific material to work from — not just generic descriptions.

Acceptance criteria:
- [ ] Given a repo URL, the system clones it to a temp directory and extracts: README, any docs/ files, CHANGELOG, and key source files (lib/, src/, etc.) up to a configurable token limit
- [ ] Given a site URL, the system crawls up to N pages (configurable) and extracts text content, headings, and metadata
- [ ] Screenshots of key pages are captured using a headless browser (Playwright or Chrome DevTools MCP)
- [ ] Extracted content is stored as a "product snapshot" in R2 with a timestamp
- [ ] A new snapshot is triggered on demand or on a schedule (e.g. weekly)
- [ ] Ingestion jobs run via Oban

---

### Feature 3: AI Content Generation Pipeline

**Purpose:** Generate large batches of content variants cheaply, then use smarter models to rank and filter — so only the best content reaches expensive production steps or gets published.

**Model roles:**
- **OpenClaw** (primary generator): fast, cheap, high-volume — generates all first-draft content variants
- **Smart review models** (Claude Opus, Gemini Pro, xAI): score and critique drafts, vote on winners, write improvement notes

**Pipeline stages:**
- Stage 0 (Competitor intelligence): Before generating, pull recent top-performing content from competitor accounts in the same niche (via Apify/content intelligence). Feed trending topics, formats, hooks, and engagement patterns into the content brief. "Competitors are getting 5x engagement on before/after posts this month" directly steers what OC generates.
- Stage 1 (Content brief -- living strategy doc): On first run, query Claude, Gemini, and xAI with the product snapshot and competitor intelligence asking what makes high-ranking content in this niche. Synthesize into a content brief. On subsequent runs, the brief is rewritten (not appended to) by a smart model that receives: the product snapshot, competitor intel, the full performance scoreboard (see Feature 7), and the previous brief. The rewrite identifies which angles/formats/hooks are working, which are underperforming, and what to try next. This is the system's "program.md" -- the strategic document that steers all generation.
- Stage 2 (Bulk generation via OpenClaw): OpenClaw generates N variants of each content type per run -- for example, 20 Twitter posts, 10 LinkedIn posts, 5 blog drafts, 10 video scripts. Each variant takes a different angle (educational, entertaining, problem-aware, social proof, etc.). Every batch must include at least one explicitly humorous/funny variant per content type -- humor is a required angle, not optional. OpenClaw receives the full content brief including performance insights so it biases toward what's working.
- Stage 3 (Multi-model ranking with performance context): Each smart model independently scores every draft on accuracy (0-10), SEO relevance (0-10), and entertainment/education value (0-10). Critically, each model also receives the performance scoreboard showing: how similar past content actually performed, how accurate that model's previous scores were vs real engagement (calibration data), and which angles/formats are currently outperforming. This lets models learn from their own prediction errors. Scores are averaged across models. Each model also writes a short critique that references performance data ("this angle has historically underperformed for this product" or "similar hooks drove 3x engagement last month"). Top-scoring drafts per content type advance; the rest are archived.
- Stage 3.5 (Image generation -- required for social posts): Every social post that advances past ranking gets an AI-generated image tailored to the content. The image prompt is derived from the post text and product branding by a smart model. Images are generated via AI image generation (Flux/DALL-E/etc), stored in R2, and attached at publish time. This is not optional -- posts with images dramatically outperform text-only on every platform.
- Stage 4 (Script gate -- video only): Before any video is produced, the top-ranked scripts go through a second ranking pass focused specifically on visual storytelling, hook strength, and retention. Only scripts clearing a configurable threshold proceed to video production. This gate prevents spending on HeyGen/ElevenLabs for weak scripts.
- Stage 5 (Winner repurposing): When performance metrics confirm a published piece is a winner (above rolling average), automatically queue cross-platform variants. A winning Twitter post spawns LinkedIn, Reddit, and blog expansion drafts. A winning blog post spawns social post variants and a video script. Repurposed variants enter Stage 2 with a "repurposed_from" link to the original and go through normal ranking. This is how one hit becomes 10 pieces of content.

Acceptance criteria:
- [ ] Content brief generation queries at least 2 smart models and stores the synthesized brief per product with a timestamp and version number
- [ ] On subsequent runs (when performance data exists), the content brief is fully rewritten by a smart model that receives: product snapshot, performance scoreboard, and previous brief. The rewrite replaces the previous brief (old versions are kept in a brief_versions table for history)
- [ ] When ranking drafts, each smart model receives the performance scoreboard alongside the drafts, including that model's own calibration data (predicted score vs actual engagement for past content it scored)
- [ ] OpenClaw is the designated bulk generation model — its API endpoint is configurable so it can be swapped
- [ ] Per run, the system generates: configurable N variants per platform (default: 20 posts per social platform, 5 blog drafts, 10 video scripts)
- [ ] Every batch guarantees at least one humor/funny variant per content type — the content brief instructs OpenClaw to include this angle
- [ ] Humor variants are labeled with angle "humor" so ranking models and humans can filter/compare by angle
- [ ] Each variant stores: content text, platform target, angle/type label, generating model, per-model scores (accuracy/SEO/EEV), averaged composite score, per-model critique text, and status (draft/ranked/approved/rejected/published)
- [ ] After ranking, top N per content type (configurable, default: top 3) are promoted to review queue; rest archived
- [ ] Video scripts have a second ranking pass with a configurable score threshold gate before video production is triggered
- [ ] All generation and ranking jobs run via Oban with retry support
- [ ] Content brief, all variants, scores, and critiques are accessible via REST API
- [ ] External models (OpenClaw or others) can submit new variants and scores via API without going through the LiveView
- [ ] Competitor intelligence: configurable list of competitor social accounts per product. Before each generation run, an Oban job scrapes recent posts from competitor accounts (via Apify), extracts top-performing content by engagement, and summarizes trending topics/formats/hooks. Summary is included in the content brief.
- [ ] Image generation: every social post that passes ranking gets an AI-generated image. A smart model writes an image prompt from the post text + product branding. Image is generated via configurable provider (Flux/DALL-E), stored in R2, and linked to the draft. Image generation runs as an Oban job after ranking, before scheduling.
- [ ] Winner repurposing: when a published piece is labeled "winner" by the scoreboard, an Oban job automatically generates cross-platform variants (Twitter winner -> LinkedIn/Reddit/blog drafts, blog winner -> social posts + video script). Repurposed drafts have a repurposed_from field linking to the original and enter the normal ranking pipeline.
- [ ] POST /api/products/:id/competitors -- add/remove competitor accounts for a product
- [ ] GET /api/products/:id/competitor-intel -- retrieve latest competitor intelligence summary

---

### Feature 3.5: Competitor Content Monitoring

**Purpose:** Know what's working in the niche before generating content. Track competitor accounts, scrape their recent posts, identify top-performing formats and hooks, and feed that intelligence into the content brief.

Acceptance criteria:
- [ ] Each product has a list of competitor social accounts (platform + handle/URL)
- [ ] A scheduled Oban job (configurable cadence, default weekly) scrapes recent posts from each competitor account via Apify
- [ ] Posts are scored by engagement (likes, shares, comments relative to the account's average)
- [ ] A summary job synthesizes the top-performing competitor content into a "competitor intel" document: trending topics, winning formats, effective hooks, engagement patterns
- [ ] Competitor intel is stored per product with a timestamp and included in the content brief context
- [ ] Dashboard shows competitor content trends alongside your own performance
- [ ] Competitor accounts and intel are manageable via REST API

---

### Feature 4: Short-form Post Publishing

**Purpose:** Publish approved short-form posts to Twitter/X, LinkedIn, Reddit, and Facebook/Instagram.

Acceptance criteria:
- [ ] Twitter/X: Post text (up to 280 chars) with image attachment via Twitter v2 API
- [ ] LinkedIn: Post text + image to a personal profile or company page via LinkedIn API
- [ ] Reddit: Submit a text post to a configured subreddit via Reddit API (image optional per subreddit rules)
- [ ] Facebook/Instagram: Post text + image via Meta Graph API
- [ ] All social posts include the AI-generated image from Stage 3.5 -- image is required, not optional
- [ ] Each connector retrieves its OAuth tokens / API keys from 1Password at runtime
- [ ] A failed publish is retried via Oban (up to 3 attempts) and flagged if all retries fail
- [ ] Published posts record the platform post ID, timestamp, and link
- [ ] Post timing optimization: track engagement by hour-of-day and day-of-week per platform per product. The scheduler picks optimal posting windows based on historical performance. Falls back to configured cadence when insufficient data exists (fewer than 20 published posts).

---

### Feature 5: Blog Publishing

**Purpose:** Deliver approved long-form blog articles to any number of registered sites without coupling to a specific CMS.

**Design:** The article (markdown) is saved to Cloudflare R2. A webhook is fired to each registered endpoint for the product with the R2 URL. Each site implements its own receiver to fetch and display the article.

Acceptance criteria:
- [ ] Approved blog articles are stored in R2 as markdown files with a stable URL
- [ ] Each product can have multiple blog webhook endpoints registered (URL + optional HMAC secret)
- [ ] On approval, the system POSTs to each registered webhook with: article title, R2 URL, product slug, publish timestamp, and optional metadata (tags, SEO description)
- [ ] Webhook delivery is retried via Oban on failure
- [ ] Webhook payloads are HMAC-signed when a secret is configured
- [ ] Delivery status (success/failure/pending) is recorded per endpoint per article

---

### Feature 6: Video Production Pipeline

**Purpose:** Produce demo and talking-head videos for YouTube from ranked scripts — with a gate at script selection to avoid spending on weak content.

**Stack:** ElevenLabs (voiceover audio), HeyGen (AI avatar talking head), Playwright (screen recording of live site), Remotion + Node.js sidecar (programmatic video composition), FFmpeg (final assembly/encoding).

**Script-first design:** Scripts are generated and ranked in Feature 3 before any video production begins. Video production only triggers for scripts that pass the ranking threshold. Multiple script variants may be produced as separate videos if budget allows, or only the top 1-2 proceed.

Acceptance criteria:
- [ ] Video production job only starts when a script has passed the script gate (ranking score above threshold)
- [ ] Multiple scripts can be queued for production in parallel — each tracked as a separate video job
- [ ] ElevenLabs voiceover: script is sent to ElevenLabs, MP3 stored in R2 keyed to the script ID
- [ ] Playwright screen recorder: headless browser navigates the live site, records walkthrough as video, stored in R2
- [ ] HeyGen talking head: script + configured avatar submitted to HeyGen API, result polled and stored in R2
- [ ] Remotion sidecar assembles final video: intro slate, screen recording segments, talking head segments, outro, with voiceover laid over
- [ ] FFmpeg handles final encoding and format normalization
- [ ] Final video uploaded to YouTube with AI-generated title, description, tags, and thumbnail (from screenshot)
- [ ] YouTube OAuth tokens are encrypted in PostgreSQL; app refreshes automatically
- [ ] Each video job tracks per-step status in DB (script_approved / voiceover_done / recording_done / avatar_done / assembled / uploaded)
- [ ] Failed steps retry via Oban; a step failing 3 times pauses the job and alerts via dashboard
- [ ] Video production is gated behind a feature flag per product (HeyGen costs money)

---

### Feature 7: Performance Metrics & Feedback Loop

**Purpose:** Pull real performance data from each platform after content is published, surface what's working, flag videos for clipping, and feed insights back into the content brief so future generation improves over time.

**Why this matters:** Without feedback, the system is generating blind. With it, OpenClaw and the ranking models can learn which angles, hooks, and formats actually drive views, engagement, and conversions for each product. The feedback loop is inspired by Karpathy's AutoResearch pattern: measure, compare predicted vs actual, keep what works, discard what doesn't, and let the strategy evolve autonomously.

**Performance scoreboard:** A single table (`content_scoreboard`) that serves as the system's memory. Every published piece gets a row with: content_id, product_id, platform, angle, format, composite_ai_score (predicted), actual_engagement_score (measured), delta (predicted minus actual), per-model predicted scores, outcome label (winner/loser based on whether it beat the product's rolling average for that platform). This scoreboard is the primary input to content brief rewrites and ranking context.

**Model calibration:** Each smart model's scoring accuracy is tracked over time. If Claude consistently over-scores humor posts that flop, that signal is fed back to Claude on the next ranking round: "Your humor scores have been 2.3 points higher than actual performance on average. Adjust accordingly." This is the equivalent of AutoResearch's agent learning from its own failed experiments.

Acceptance criteria:
- [ ] Performance scoreboard table: content_id, product_id, platform, angle, format, composite_ai_score, actual_engagement_score, delta, per_model_scores (jsonb), outcome (winner/loser/pending), measured_at timestamps (24h/7d/30d)
- [ ] After each metrics sync, every published piece is labeled winner (above rolling average) or loser (below) for its platform
- [ ] Model calibration table: model_name, product_id, platform, angle, avg_score_delta, sample_count, last_updated. Updated after each metrics sync. Tracks how accurately each model's scores predict real engagement.
- [ ] YouTube Analytics: after a video is published, a scheduled job pulls views, watch time, average view duration, audience retention curve, likes, comments, and shares at 24h / 7d / 30d intervals
- [ ] Social metrics: for each published post, pull platform-native engagement metrics (likes, shares, impressions, replies, click-throughs) at the same intervals
- [ ] Blog metrics: if a blog webhook endpoint returns view/engagement data (optional), record it; otherwise track delivery status only
- [ ] Long-tail monitoring: a weekly job re-checks all published content regardless of age. If engagement changed significantly (configurable threshold, default 20%) since last measurement, the scoreboard is updated, winner/loser labels are recalculated, and the content is flagged as "resurfaced" for the next brief rewrite. This captures late viral hits, evergreen SEO content, and algorithm resurfaces.
- [ ] "Clip this" detection: videos where the audience retention curve shows a high-engagement segment (above configurable threshold for configurable duration) are automatically flagged with the timestamp range and a suggested short-form clip title
- [ ] Clipping queue: flagged video segments are added to a clip queue; each clip can be approved to produce a short-form video (Reels/Shorts/TikTok length) cut from the source
- [ ] Content brief rewrite trigger: after each metrics sync, if 5+ new measured pieces exist since the last rewrite, trigger a brief rewrite job. A smart model receives the full scoreboard, current brief, and product snapshot, and writes a new brief version replacing the old one.
- [ ] The scoreboard and model calibration data are available via API so OpenClaw and smart models can read them during generation and ranking
- [ ] GET /api/products/:id/scoreboard -- returns the performance scoreboard for a product, filterable by platform, angle, date range
- [ ] GET /api/products/:id/calibration -- returns per-model calibration data for a product
- [ ] Engagement spike alerts: a fast-cadence poller (hourly for first 24h after publishing) checks early engagement. If a post's engagement in the first hour exceeds 3x the product's average for that platform, flag it as "hot" on the dashboard. Hot posts are candidates for paid boosting or rapid follow-up content.
- [ ] Comment volume flagging: when a post accumulates comments above a configurable threshold (default 10), flag it as "needs attention" on the dashboard so the human can personally engage. Pull comment count alongside other metrics. Dashboard shows a dedicated "needs reply" queue.
- [ ] Winner repurposing trigger: when a piece is labeled "winner", automatically trigger cross-platform variant generation (see Stage 5 in Feature 3). Track which repurposed variants came from which original.
- [ ] Dashboard shows per-content performance: views/engagement trend, retention curve for videos, flag for clippable segments, winner/loser labels, hot/needs-reply flags
- [ ] GET /api/products/:id/metrics -- returns aggregated performance data per product
- [ ] GET /api/products/:id/hot -- returns currently hot posts (engagement spike in first 24h)
- [ ] GET /api/products/:id/needs-reply -- returns posts with high comment counts needing personal engagement
- [ ] GET /api/videos/:id/retention -- returns the retention curve data and any flagged clip segments

---

### Feature 8: Content Review API

**Purpose:** Allow OpenClaw and other external LLMs to drive the full pipeline — generating variants, submitting scores and critiques, approving/rejecting drafts, triggering production, and reading metrics — without needing the LiveView UI.

Acceptance criteria:
- [ ] GET /api/drafts — list drafts with filters for product, platform, status, content type, and minimum composite score
- [ ] GET /api/drafts/:id — retrieve a single draft with content, all per-model scores, critiques, and metadata
- [ ] POST /api/drafts — submit a new draft variant (OpenClaw posts content it generated directly)
- [ ] POST /api/drafts/:id/approve — approve a draft for scheduling
- [ ] POST /api/drafts/:id/reject — reject with an optional reason
- [ ] POST /api/drafts/:id/score — submit scores (accuracy, SEO, EEV) and a critique from a named model
- [ ] POST /api/products/:id/generate — trigger a new generation run for a product
- [ ] GET /api/products/:id/brief — retrieve the current content brief including performance summary
- [ ] GET /api/products/:id/metrics — aggregated performance data
- [ ] GET /api/videos/:id/retention — retention curve + flagged clip segments
- [ ] POST /api/videos/:id/clip — approve a flagged segment to produce a short-form clip
- [ ] All endpoints require API key (bearer token); keys stored encrypted in PostgreSQL
- [ ] API responses are JSON

---

### Feature 9: LiveView Dashboard

**Purpose:** Human-friendly UI for managing products, reviewing drafts, monitoring the posting queue, and checking publishing history.

Acceptance criteria:
- [ ] Products list with quick-add form
- [ ] Per-product detail page: snapshot status, content brief, draft queue, publishing history
- [ ] Draft review queue: shows all variants with composite score, per-model scores, critiques, and approve/reject controls
- [ ] Script ranking view: video scripts ranked by score with the gate threshold visible — promote or override
- [ ] Schedule view: calendar or timeline of upcoming and past posts per product per platform
- [ ] Publishing history: each post with platform, timestamp, link, and live performance metrics
- [ ] Video production status board: per-step status (script_approved → voiceover → recording → avatar → assembled → uploaded)
- [ ] Performance dashboard: views/engagement trends per product, retention curves for videos, clippable segment flags
- [ ] Clip queue: flagged video segments with timestamp range, suggested title, approve to produce short-form clip
- [ ] All views are mobile-responsive and accessible (WCAG AA)

---

## Implementation Checklist

### Phase 1: Foundation (items 1a–1c are independent)

- [ ] 1a. Scaffold new Phoenix app `content_forge` with Ecto/PostgreSQL, Oban, and 1Password integration — product registry context
- [ ] 1b. REST API skeleton: authentication middleware, JSON response helpers, versioned routes
- [ ] 1c. Cloudflare R2 client module (reuse ExAws.S3 pattern from other apps)
- [ ] 1d. Product registry CRUD: Ecto schema (including voice_profile text field), context functions, LiveView UI, API endpoints. Generation runs validate voice_profile is present before starting. (depends on 1a, 1b)
- [ ] 1e. Blog webhook registry: schema + CRUD + HMAC signing util (depends on 1d)

### Phase 2: Content Ingestion + Competitor Intelligence (items 2a–2b, 2d are independent)

- [ ] 2a. Repo cloning + extraction: Oban job that git clones to temp dir, reads README/docs, extracts text up to token limit, stores snapshot in R2
- [ ] 2b. Site crawler: Oban job that fetches N pages via WebFetch/Playwright, extracts text + screenshots, stores in R2
- [ ] 2c. Product snapshot schema + storage: link snapshot metadata (timestamp, R2 keys) to product in DB (depends on 2a, 2b)
- [ ] 2d. Competitor account registry: schema (product_id, platform, handle/URL), CRUD in Products context, API endpoints
- [ ] 2e. Competitor scraper: Oban job that scrapes recent posts from competitor accounts via Apify, scores by relative engagement, stores raw data (depends on 2d)
- [ ] 2f. Competitor intel synthesizer: Oban job that takes scraped competitor posts and generates a "competitor intel" summary (trending topics, winning formats, effective hooks) via a smart model. Stored per product with timestamp. (depends on 2e)

### Phase 3: AI Generation Pipeline (3a -> 3b -> 3c -> 3d -> 3e sequential, 3f independent)

- [ ] 3a. Content brief system: brief schema with version history (brief_versions table). On first run, query Claude/Gemini/xAI with snapshot + competitor intel context, synthesize into initial brief. On subsequent runs with performance data, rewrite the brief using scoreboard + calibration + competitor intel instead of appending.
- [ ] 3b. OpenClaw bulk generation: Oban job calls OpenClaw API with content brief (including performance insights + competitor intel) -> N variants per platform, N blog drafts, N video scripts; store all as draft records with angle/type label
- [ ] 3c. Multi-model ranking with performance context: Oban job calls each smart model with: the drafts to score, the product's performance scoreboard, and that model's own calibration data (avg predicted vs actual delta). Models score and critique with awareness of what has actually worked. Store per-model scores + critique; compute composite score; promote top N per type to review queue (depends on 3b)
- [ ] 3d. Script gate: second Oban ranking pass on video scripts only; scripts below threshold are archived; approved scripts enqueue video production jobs (depends on 3c)
- [ ] 3e. Image generation for social posts: Oban job for each ranked social post. Smart model writes an image prompt from post text + product branding. Image generated via configurable provider (Flux/DALL-E), stored in R2, linked to draft. Required before scheduling. (depends on 3c)
- [ ] 3f. Winner repurposing engine: Oban job triggered when scoreboard labels a piece as "winner". Generates cross-platform variants (Twitter -> LinkedIn/Reddit/blog, blog -> social + video script). Repurposed drafts enter Stage 3b with repurposed_from link. (depends on Phase 7 scoreboard, runs async)

### Phase 4: Short-form Publishing (4a–4d are independent of each other, depend on Phase 3)

- [ ] 4a. Twitter/X connector: OAuth2 client, post text + image, retry on failure, record post ID
- [ ] 4b. LinkedIn connector: OAuth2 client, post to profile/page, retry on failure
- [ ] 4c. Reddit connector: OAuth2 client, submit text post to configured subreddit
- [ ] 4d. Facebook/Instagram connector: Meta Graph API client, post text + image
- [ ] 4e. Oban scheduler with timing optimization: per-product, per-platform job that picks next approved draft and calls the right connector. Tracks engagement by hour-of-day and day-of-week per platform per product. Picks optimal posting windows from historical data (requires 20+ published posts, falls back to configured cadence before that). (depends on 4a-4d)

### Phase 5: Blog Publishing (depends on Phase 3)

- [ ] 5a. Blog article R2 storage: write markdown to R2 with stable URL on approval
- [ ] 5b. Webhook delivery: Oban job that POSTs to each registered endpoint, HMAC-signed, with retry
- [ ] 5c. Delivery status tracking: record success/failure per endpoint per article

### Phase 6: Video Production (6a–6c are independent, 6d–6f sequential; all depend on Phase 3 script gate)

- [ ] 6a. ElevenLabs voiceover: HTTP client, send script text, receive and store MP3 in R2 keyed to script ID
- [ ] 6b. Playwright screen recorder: headless browser navigates live site, records walkthrough as video, stores in R2
- [ ] 6c. HeyGen talking head: API client, submit script + avatar config, poll for completion, store in R2
- [ ] 6d. Remotion Node.js sidecar: small Node/Bun service that accepts render jobs via HTTP; Elixir sends script + asset URLs, sidecar assembles and returns video URL
- [ ] 6e. FFmpeg final encode: normalize format, burn in any overlays, produce final MP4 in R2 (depends on 6d)
- [ ] 6f. YouTube upload: OAuth2 client with encrypted token refresh, upload video with AI-generated title/description/tags/thumbnail, record video ID (depends on 6e)
- [ ] 6g. Video production Oban workflow: orchestrate all steps, track per-step status in DB, retry on failure, pause + alert after 3 failures (depends on 6a–6f)

### Phase 7: Metrics & Feedback Loop (depends on Phase 4, 5, 6 publishing)

- [ ] 7a. Performance scoreboard schema + context: content_scoreboard table with all fields from spec, winner/loser labeling logic (compare to rolling platform average), context functions for querying by product/platform/angle/date
- [ ] 7b. Model calibration schema + updater: model_calibration table, Oban job that recalculates avg_score_delta per model per product per platform after each metrics sync
- [ ] 7c. YouTube Analytics poller: Oban scheduled job pulls views, watch time, retention curve, engagement at 24h/7d/30d after upload; populates scoreboard
- [ ] 7d. Social metrics poller: per-platform jobs pull likes/shares/impressions/clicks for each published post at same intervals; populates scoreboard
- [ ] 7d2. Long-tail metrics poller: weekly Oban job re-checks ALL published content (not just recent). Compares current metrics to last recorded values. If engagement changed by more than a configurable threshold (default 20%), updates the scoreboard, re-labels winner/loser status, and flags the content as "resurfaced" so the next brief rewrite notices late bloomers. This catches posts that go viral months later or slowly accumulate SEO traffic over time.
- [ ] 7e. Retention curve analyzer: detects high-engagement segments (above threshold, above min duration), creates clip suggestions with timestamp range + suggested title
- [ ] 7f. Clip production job: when a clip is approved, cut the source video using FFmpeg and enqueue for short-form publishing
- [ ] 7g. Content brief rewrite job: Oban job triggered when 5+ new measured pieces exist since last rewrite. Sends scoreboard + calibration + current brief + snapshot to a smart model. Replaces the current brief with the rewrite, stores old version in brief_versions table.
- [ ] 7h. Scoreboard and calibration API endpoints: GET /api/products/:id/scoreboard, GET /api/products/:id/calibration
- [ ] 7i. Engagement spike detector: hourly Oban poller for first 24h after publishing. If a post's engagement in first hour exceeds 3x the product's platform average, flag as "hot". Dashboard shows hot posts prominently. API: GET /api/products/:id/hot
- [ ] 7j. Comment volume monitor: pull comment counts alongside other metrics. When a post exceeds configurable threshold (default 10 comments), flag as "needs reply" on dashboard. API: GET /api/products/:id/needs-reply. Include direct link to the post on the platform so human can respond immediately.
- [ ] 7k. Winner repurposing trigger: when scoreboard labels a piece as "winner", enqueue the repurposing engine (Phase 3, item 3f) to generate cross-platform variants automatically

### Phase 8: Dashboard (depends on Phases 1–7)

- [ ] 8a. Products list + detail LiveView
- [ ] 8b. Draft review queue LiveView (all variants, composite + per-model scores, critiques, approve/reject)
- [ ] 8c. Script ranking LiveView (video scripts ranked with gate threshold visible)
- [ ] 8d. Schedule + publishing history LiveView with live metrics inline
- [ ] 8e. Video pipeline status board LiveView (per-step progress)
- [ ] 8f. Performance dashboard: trends, retention curves, clip flags, competitor intel comparison
- [ ] 8g. Clip queue LiveView (approve flagged segments for short-form production)
- [ ] 8h. Hot posts + needs-reply queue LiveView (engagement spikes, high-comment posts with direct platform links)
- [ ] 8i. Competitor intel LiveView (trending topics, top competitor content, side-by-side with your performance)
- [ ] 8j. Mobile responsiveness + accessibility pass

---

## Parallelization Notes

- Phase 1 items 1a, 1b, 1c can be built simultaneously by separate agents
- Phase 2 items 2a, 2b, and 2d (repo ingestion, site crawler, competitor registry) are fully independent
- Phase 3 item 3e (image generation) and 3f (winner repurposing) are independent of each other
- Phase 4 items 4a-4d (social connectors) are all independent -- one agent per connector
- Phase 6 items 6a, 6b, 6c (voiceover, screen recording, talking head) are independent until assembly
- Phase 7 items 7c and 7d (YouTube vs social metrics) are independent; 7i and 7j (spike detector, comment monitor) are independent
- Phase 8 LiveView pages can all be built in parallel once data layers exist

---

## Out of Scope

- Native mobile apps — web-only (mobile-responsive LiveView)
- TikTok — API is restricted; add later if access becomes available
- Paid ad management — this is organic content only
- Comment monitoring / social listening — publish-only for now
- Multi-user / team accounts — solo founder only at launch
- Billing / subscriptions — internal tool, no paywall

---

## Architecture Decisions

- **Remotion runtime:** Node.js sidecar service running alongside the Elixir app. Elixir sends render jobs via HTTP. Simple, runs on existing servers.
- **YouTube OAuth tokens:** Encrypted in PostgreSQL. App handles token refresh automatically. Consistent with needing autonomous operation.
- **Reddit config:** Default subreddits stored per product in the publishing target config. AI can suggest a different subreddit per draft at generation time.
- **Blog webhook payload (minimal):** POST body contains `r2_url`, `title`, `slug`, `published_at`, `product_slug`, `tags[]`, `seo_description`. Receiver fetches markdown from R2 using the URL. No full content inline.
- **HeyGen:** Avatar and voice selection will be configurable per product. Evaluate cost per render before enabling by default — gate behind a feature flag.
