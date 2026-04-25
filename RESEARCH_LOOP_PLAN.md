# Competitor Research Loop — Build Plan

A swarmforge-ready build plan for standing up content-forge as the corpus
of record for competitor research, the synthesis brain that turns raw
posts into structured intel, and the feedback loop that closes the
prediction-vs-actual gap on our own published content.

**Status:** Greenfield. No phases of this plan are running yet.
content-forge has the schemas and Oban jobs but is not booted on this
machine.

## Why this exists

Lead Intelligence has been doing scraping and content analysis ad hoc.
Its Twitter scraper crashed because the upstream Apify actor went bad,
its analyze_posts pipeline produces a parallel corpus to content-forge's
competitor_intel table, and there is no feedback loop closing the gap
between what we predicted would land and what actually did.

content-forge already has the right shape for all of this: a
products → competitors → competitor_posts → competitor_intel pipeline,
a multi-model ranker, a published_posts engagement table, a scoreboard
that compares predicted to actual, and a winner repurposing engine.
None of it is wired in dev or fully live. This plan brings it up.

The just-shipped redirects in lead_intelligence's MCP server now point
seven scraping/analysis tools at content-forge. Those redirects only
have somewhere to go once this plan is at least partially executed.

## Architectural principles

1. **content-forge is the corpus of record.** Every competitor post
   eventually lives in `competitor_posts`. Every synthesized pattern
   lives in `competitor_intel`. lead_intelligence does not duplicate
   this state.
2. **Synthesis works with or without an Anthropic key.** If an API key
   is configured, the existing LLMAdapter does headless synthesis via
   the Oban job. If not, an MCP tool surface lets a Claude session
   read top posts and write back structured intel manually. Both paths
   produce the same `competitor_intel` row shape.
3. **Apify integration is per-platform configurable, not hardcoded.**
   When an actor goes bad, swap it in config without code changes.
4. **The feedback loop is a first-class deliverable, not a v2.**
   MetricsPoller has to be on a schedule by the end of this plan, even
   if some platform fetchers are stubs. Without the loop, this is just
   another scraper.
5. **The corrective signal is external, not internal.** When our content
   underperforms, we do not auto-rewrite the brief from internal data
   alone — internal underperformance can be noise (algorithm change,
   holiday lull, news cycle). Instead we check whether competitors won
   that same week. Our drop + competitor wins = real signal, pivot
   toward what is working in market right now. Our drop + competitor
   drops = market noise, do nothing.
6. **Comments are first-class research data, not optional flavour.**
   For posts that perform well, the comment thread tells us why — what
   the audience valued, what they asked, what they pushed back on.
   Synthesis without comments is pattern-matching on the surface
   only. Synthesis with comments is reasoning about resonance.
7. **No new "competitor analysis" features inside lead_intelligence.**
   Anything new for research goes into content-forge.

---

## Phase 0 — Local environment up

**Scope.** content-forge is not currently booted on m4. There is no
content_forge_dev database, no launchd plist, no Phoenix server
running. Bring it up.

**Work.**
- Create the `content_forge_dev` Postgres database.
- Run dependency fetch and database migrations.
- Confirm the dev server boots, the dashboard renders, and the
  existing test suite passes against the local dev database.
- Add a launchd plist mirroring lead_intelligence's pattern so the
  Phoenix server stays alive between sessions. Logs go to
  `~/Library/Logs/content-forge.log`. KeepAlive true. RunAtLoad true.
- Confirm the Oban queues actually start at boot (no jobs should be
  attempted yet, but the queue supervisor must be live).

**Acceptance criteria.**
- `mix phx.server` boots clean against `content_forge_dev`.
- Dashboard pages render at the configured port without 500s.
- launchd shows `com.zyzyva.content-forge` running.
- Restarting the launchd job picks up where it left off without
  manual intervention.

**Dependencies.** None. This is the foundation.

---

## Phase 1 — Fix the Twitter Apify adapter and harvest comments

**Scope.** content-forge's Apify adapter is configurable per platform
but the documented default for Twitter is a generic `apify~twitter-scraper`
identifier. We have already discovered that the apidojo Twitter actor
is broken and that the working substitute is the kaitoeasyapi
pay-per-result scraper. The adapter also passes a conservative
input shape that does not include the `from` key kaitoeasyapi requires
for user-specific scrapes. Additionally, the adapter today only
harvests posts; it must also harvest comments on viral posts so the
synthesizer can reason about audience resonance, not just surface
patterns.

**Work.**

*Post harvesting.*
- Update the actors map in config so the Twitter platform routes to
  the kaitoeasyapi actor identifier.
- Extend the input shape so handle-driven scrapes pass a `from`
  field in addition to the existing handle/username/screenName/
  searchTerms keys. Other actors ignore unknown keys, so this is safe.
- Add a defensive filter that drops any items the actor returns
  carrying a noResults marker, before the normalisation step. This
  protects us from a future actor regression of the kind we just hit.
- Add a test that feeds a recorded kaitoeasyapi response fixture
  through the adapter and asserts the post-map normalisation
  produces the expected likes/retweets/replies/views fields.

*Comment harvesting.*
- Add a new `competitor_post_comments` table linked to
  `competitor_posts` by parent post id. Columns mirror what the
  actor returns for replies — text, author handle, posted_at,
  engagement counts, conversation id, in-reply-to id, and the raw
  payload preserved verbatim.
- Define what counts as a viral post worth fetching comments for.
  Default heuristic: a post that views above five times the account's
  rolling average OR clears an absolute floor of 100k views. These
  thresholds live in config so they can be tuned per product later.
- Extend the adapter (or add a sibling adapter function) so that
  when a post is identified as viral, the system queues a follow-up
  scrape of its comment thread by `conversation_id`. Limit to top
  fifty comments per post by like count; that captures the
  highest-resonance replies without sucking in five thousand noise
  responses.
- Make comment scraping a separate Oban job triggered on (a) initial
  ingestion when a post crosses the threshold, and (b) the
  competitor scrape refresher cron defined in Phase 6 so we re-pull
  comments on posts that gained views since first ingest.

**Acceptance criteria.**
- Running the CompetitorScraper Oban job by hand against a Twitter
  competitor account produces a non-empty list of posts in
  `competitor_posts`.
- The same job against a private or zero-tweet account returns an
  empty list cleanly, without raising and without inserting blank
  rows.
- For any competitor whose recent posts include at least one viral
  post by the threshold rule, the comment-harvesting job populates
  `competitor_post_comments` for that post.
- A second run of the comment-harvesting job over the same posts
  inserts zero new rows.
- The unit test for the adapter passes for both the post and the
  comment paths.

**Dependencies.** Phase 0.

---

## Phase 2 — Open the dev/prod config gate

**Scope.** Today, the scraper adapter and the LLM adapter are only
wired in `:prod`. Dev runs of the Oban jobs see `nil` adapters and
discard immediately. That's fine for tests but pointless for the dev
loop we are about to drive.

**Work.**
- Move the scraper_adapter and intel_model bindings out of the
  `if config_env() == :prod` block in runtime config.
- Replace the gate with environment-variable presence checks, so
  missing APIFY_TOKEN means the scraper adapter reports `:not_configured`
  and missing ANTHROPIC_API_KEY means the synthesizer falls back to
  the MCP-driven path defined in Phase 4.
- Document the new behavior in CLAUDE.md and CONTENT_FORGE_SPEC.md so
  future contributors don't re-add the prod gate.

**Acceptance criteria.**
- Booting in dev with both env vars present, both adapters initialize
  and the corresponding Oban jobs run end-to-end.
- Booting in dev with APIFY_TOKEN missing, scraper jobs return a clear
  `:not_configured` error rather than silently discarding.
- Booting in dev with ANTHROPIC_API_KEY missing, synthesizer jobs do
  not try to call the API and instead leave the synthesis in a
  pending state that Phase 4 covers.

**Dependencies.** Phase 1.

---

## Phase 3 — MCP server in content-forge

**Scope.** content-forge currently has no MCP server. Lead intelligence
has redirected its scraping/analysis tools to "use content-forge",
but content-forge offers no MCP surface for a Claude session to
actually use. Build a focused one.

**Work.**
- Add the SimpleMCP dependency from the same git source lead_intelligence
  uses.
- Build a content-forge MCP server module that exposes a small,
  task-shaped tool set:
    - one to create a product and list products,
    - one to add a competitor account and list competitors per product,
    - one to enqueue a competitor scrape,
    - one to fetch the top N posts for a product, scored against the
      account average, ready for synthesis,
    - one to store a synthesized intel record (the with-or-without-key
      back half of Phase 4),
    - one to get the latest synthesized intel for a product,
    - one to import posts from a sqlite file produced by
      lead_intelligence's standalone scraper, so we never re-pay
      Apify for handles we have already pulled.
- Build a stdio transport wrapper following the lead_intelligence
  pattern.
- Register the new MCP server in the Claude Code config so sessions
  can connect to it.
- Each tool returns structured maps. No tool reaches into Phoenix or
  Bandit; everything goes through the existing context modules
  (Products, Metrics, ContentGeneration, etc.) so behavior is
  consistent with the LiveView surface.

**Acceptance criteria.**
- Claude Code lists the content-forge MCP tools alongside the
  lead_intelligence ones.
- Round-trip: create a product, add a competitor, enqueue a scrape,
  read top posts, store synthesized intel, retrieve it. Every step
  runs cleanly through MCP without touching the dashboard.
- Calling a tool that needs a missing dependency (no APIFY_TOKEN, no
  product yet, etc.) returns a useful structured error, never crashes
  the stdio process.

**Dependencies.** Phase 0, Phase 2.

---

## Phase 4 — With-or-without-key synthesis, comment-aware

**Scope.** The competitor intel synthesizer should produce the same
output regardless of whether an Anthropic key is configured. The
synthesis input must include comment data on viral posts so the
output reflects audience resonance, not just post pattern matching.

**Work.**

*With-or-without-key paths.*
- Keep the existing LLMAdapter as the "with key" path, unchanged in
  contract but updated in inputs (see below).
- Add a second adapter, the manual/MCP path. When the synthesizer
  cannot call an API, instead of discarding it should mark the
  synthesis attempt as `pending_manual` against the product, with a
  reference to the top posts and their comments it was going to
  summarise.
- Expose the pending queue through the MCP tools added in Phase 3:
  a Claude session can list pending syntheses, read the posts and
  comments, decide how to summarise them, and call back to store
  the structured intel with the same shape the with-key path produces.

*Comment-aware synthesis input.*
- Update the prompt the LLMAdapter sends so that for each top post
  passed in, the comment thread comes along. Comments are scoped to
  top fifty by like count to keep the prompt under context limits.
- Update the synthesizer's "fetch top posts" query so that when it
  selects the top N posts for a product, it also pulls the related
  comment rows from `competitor_post_comments` and packages them as
  a single input bundle per post.
- Both paths receive the same input bundle shape so behaviour is
  consistent across with-key and without-key synthesis.

*Schema additions.*
- Extend the `competitor_intel` schema with a new field describing
  audience signals. The field's name should make it clear this is
  derived from comments, not post bodies — `audience_signals` works.
  It carries a list of free-form strings the same way
  `effective_hooks` does, capturing patterns like recurring
  objections, recurring questions, common emotional reactions, and
  any consensus tropes.
- Both paths populate this new field. Synthesis without comments
  available falls back to an empty list, never null.

**Acceptance criteria.**
- With ANTHROPIC_API_KEY set, scheduling a synthesis for a product
  produces a `competitor_intel` row autonomously, no MCP needed.
  The row's `audience_signals` is populated when at least one of the
  source posts has comments harvested.
- With the key absent, the same scheduling produces a pending entry
  visible to MCP. A Claude session can complete it via MCP and the
  resulting row is indistinguishable in shape from the with-key path.
- A test exercises both paths with the LLM client stubbed via
  Req.Test, asserting that comments make it into the prompt and
  that `audience_signals` lands populated.

**Dependencies.** Phase 1 (comments must exist), Phase 2, Phase 3.

---

## Phase 5 — Backfill from lead_intelligence's sqlite (posts + comments)

**Scope.** We already paid Apify to scrape ~6,800 tweets from
@cleanwithmike into `priv/twitter_scrapes.db` inside lead_intelligence.
The standalone scraper there is also being extended to harvest
comments on viral posts ahead of this plan, so the sqlite will carry
both posts and comments by the time this phase runs. There is no
reason to re-scrape any of it.

**Work.**
- Build an importer (called by the MCP tool added in Phase 3) that
  takes a sqlite path, a target product, a target competitor handle,
  and an optional date range.
- For each tweet in the sqlite, upsert a `competitor_posts` row with
  the engagement fields populated, the post URL, the posted_at
  timestamp, and the raw payload preserved in whatever JSON column
  competitor_posts already provides.
- For each row in the sqlite's `comments` table, upsert a
  `competitor_post_comments` row tied to the corresponding parent
  post.
- Recompute the competitor account's rolling engagement average so
  the per-post score field reflects the broader corpus, not just the
  most recent few.
- Idempotent: re-running the importer over the same source should
  produce zero new rows for both posts and comments.

**Acceptance criteria.**
- After the backfill against the cleanwithmike sqlite, the
  competitor_posts and competitor_post_comments tables together
  contain the same data as the source minus duplicates already
  present.
- Average engagement per account reflects the imported corpus.
- A second run of the importer creates no new rows and reports zero
  inserts.

**Dependencies.** Phase 1 (so competitor_posts and
competitor_post_comments schemas exist and their shapes match what
the live scraper produces), Phase 3 (MCP entry point).

---

## Phase 6 — Schedule the metrics poller and the corrective loop

**Scope.** MetricsPoller exists as an Oban worker but is not on a
schedule. There is also no scheduled refresh of competitor data —
existing scrapes are one-shot. Both must run on schedules, and they
must be tied together by the corrective-loop logic so a drop in our
own performance triggers a fresh look at what competitors are doing
right now.

**Work.**

*MetricsPoller cron.*
- Add an Oban cron entry that calls MetricsPoller for every active
  product on a sensible cadence. The worker's docstring describes
  24-hour, 7-day, and 30-day intervals; pick one cron that issues
  all three at the right moments per published post.
- Decide what "active product" means for cron purposes (probably:
  any product with at least one published post in the last 90 days).
- Add a small operator surface — a LiveView page or an MCP tool —
  showing recent scoreboard outcomes per product so we can verify
  the loop is closing.

*Competitor scrape refresher cron.*
- Add a second Oban cron entry that re-scrapes every active
  competitor account on a weekly cadence. Recent posts are
  incremental; fetching only what's newer than what's already in
  the database keeps cost low.
- Re-evaluate the viral threshold per scrape. Posts that crossed
  the threshold since the last run get queued for comment
  harvesting.

*Corrective loop replacing the auto-rewrite trigger.*
- Replace MetricsPoller's existing "5 poor performers detected →
  force_rewrite" call with a two-condition check:
    1. Did our own published content underperform this period? AND
    2. Did any of our tracked competitors have posts that beat
       their own rolling average in the same window?
- Only when both are true, enqueue a synthesis specifically scoped
  to the "competitors-this-week" winners — a week-windowed input
  rather than the all-time top 10 — and feed that fresh intel to a
  brief regeneration. Document this scoping clearly so the
  synthesizer knows the input window.
- Both conditions false: do nothing this period.
- Our drops without competitor wins: do nothing; assume noise.
- Competitor wins without our drops: do nothing; we are landing,
  no pivot warranted, but the competitor wins still get harvested
  and synthesized as part of normal corpus refresh.

**Acceptance criteria.**
- Within 24 hours of publishing, every published post has a
  scoreboard entry with `actual_engagement_score` populated.
- Within 7 days, the same posts have a 7-day-interval entry.
- The operator surface shows winners and losers for the most recent
  poll cycle.
- The competitor scrape refresher cron picks up new posts on a
  weekly cadence and queues comment harvesting for posts that
  cross the viral threshold since the last run.
- The corrective-loop trigger fires only when both conditions are
  met. A test simulates each combination of internal drops and
  competitor wins and asserts the trigger only fires for the
  drop+wins case.
- Restarting the launchd-managed Phoenix process does not break
  any cron schedule.

**Dependencies.** Phase 0 (Phoenix and Oban must be running),
Phase 1 (competitor scrape adapter must work), Phase 4 (synthesis
must accept a week-windowed input), and Phase 7 (at least one
platform's metrics fetcher needs to be real for the loop to mean
anything).

---

## Phase 7 — Audit per-platform metrics fetchers

**Scope.** Each publishing platform module — twitter, linkedin,
facebook, reddit, youtube — has a metrics-fetch path. Some are
likely stubs. MetricsPoller's loop is only as honest as those
fetchers are.

**Work.**
- For each platform module, classify the metrics fetcher as one of:
  fully implemented, partial stub, or placeholder.
- For partial or placeholder fetchers, document what is missing
  (which API calls, which credentials, which response fields).
- For Twitter specifically: decide whether to use the X API
  directly (cheap reads) or an Apify actor (consistent with the
  scraper). Either is fine; document the choice.
- Implement at minimum the Twitter fetcher. Other platforms can
  remain stubs as long as their stub state is loud, not silent.
- Add a test for each implemented fetcher using a recorded fixture.

**Acceptance criteria.**
- A clear inventory exists in CAPABILITIES.md or similar of which
  platforms can be measured and which cannot.
- The Twitter fetcher returns real numbers for a known live tweet.
- Stub fetchers raise or return an explicit "not implemented" error
  that MetricsPoller logs visibly, rather than silently filling rows
  with zeros.

**Dependencies.** Phase 0.

---

## Phase 8 — Bootstrap HollerClean as the first product

**Scope.** Use everything above to do a full pass for HollerClean,
end to end, so the loop is not just running but producing useful
output.

**Work.**
- Create a HollerClean product entry with a voice profile and any
  publishing target credentials we have.
- Add @cleanwithmike and two or three other cleaning-business
  operator accounts as competitors.
- Trigger the importer (Phase 5) to load the existing cleanwithmike
  sqlite. Trigger fresh scrapes (Phase 1) for the others.
- Run the synthesizer end to end. If a key is present, it runs
  headless. If not, complete the synthesis through the MCP path
  (Phase 4).
- Verify the resulting competitor_intel row contains hooks, formats,
  and topics that match the patterns we already documented manually
  in the lead_intelligence research session.
- Take whatever drafts content-forge produces from this intel and
  run them through the multi-model ranker so we have a baseline
  prediction.

**Acceptance criteria.**
- HollerClean appears in the product list with at least three
  competitors, each carrying real posts.
- A competitor_intel record exists for HollerClean, populated from
  the synthesis pipeline.
- At least one draft has been generated by the brief generator using
  that intel as input, and ranked by the multi-model ranker.
- Nothing in the workflow required leaving the MCP surface plus the
  CF dashboard. No ad-hoc scripts had to be invoked.

**Dependencies.** Phases 1 through 6 must all be in place. Phase 7
helps but is not blocking — drafts can be ranked even if metrics
fetchers are stubs; the scoreboard half of the loop just produces no
real signal until they aren't.

---

## Phase 9 — Lead Intelligence cleanup follow-up

**Scope.** Once content-forge is doing the work, lead_intelligence's
remaining content/video pipeline becomes redundant. Decide whether
to keep it as a staging area or remove it.

**Work.**
- Decide whether to deprecate analyze_video and analyze_channel_videos
  in lead_intelligence's MCP, redirecting them to content-forge as
  well, OR keep them as a dev-time scratch pad with a clear note
  that the production path is content-forge.
- If deprecating: extend the redirect helper added in commit 223cf0d
  to cover those tools, mirror the description prefix, and update
  the CLAUDE.md note for lead_intelligence.
- Audit the lead_intelligence Content context for code that has no
  production caller anymore (anything fed only by the now-redirected
  scrape tools). Decide repo-by-repo whether to delete or keep.
- Consider whether the standalone scraper script
  (lead_intelligence/priv/scripts/scrape_twitter.exs) belongs in
  content-forge instead, as the dev-time companion to the
  CompetitorScraper Oban job. If yes, move it; if no, document why
  it lives in lead_intelligence.

**Acceptance criteria.**
- The two repos have a clear, documented division of labour: research
  and content production live in content-forge; lead and outreach
  state lives in lead_intelligence.
- No tool in either MCP server claims to do something it cannot
  actually do.
- The CLAUDE.md in each repo reflects the post-cleanup state.

**Dependencies.** Phase 8 (we should not deprecate LI's video tools
until CF has the equivalent or has explicitly chosen not to.)

---

## Open questions

1. Should the metrics poller cadence be fixed (every 6h) or
   adaptive (denser early, sparser later)? Lean fixed-and-simple
   for v1.
2. Should the import-from-sqlite tool live in content-forge or stay
   in lead_intelligence and push into content-forge over HTTP? The
   former is simpler; the latter respects the cross-repo boundary
   more cleanly.
3. Is the X API direct path acceptable for Twitter metrics fetching,
   or do we want everything through Apify for consistency? Direct is
   cheaper but adds a per-tier rate-limit failure mode the rest of
   the system doesn't have.
4. Viral threshold tuning. Default is "5x rolling account average OR
   100k absolute views". Need to revisit per product after a few
   weeks of data — for low-follower-count competitors the absolute
   floor is too high; for huge accounts the relative floor is too
   loose.
5. Comment volume per viral post. Default is top 50 by likes. May
   need to scale up for posts with thousands of comments where the
   long tail is informative, or down for posts where the top 10
   already dominate the signal.

## Out of scope for this plan

- Building HollerClean's Phase 1 contractor pipeline (lives in
  lead_intelligence).
- Any changes to OpenClaw or Media Forge.
- Production deployment beyond launchd on m4. Public hosting,
  TLS, custom domains, multi-host run are separate work.
- Replacing or competing with lead_intelligence's lead-scoring
  pipeline. That's a different problem from content research.
