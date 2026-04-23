# Content Forge Build Plan

Wave-by-wave plan for the swarmforge flow. Every slice is sized so the architect can write an unambiguous acceptance spec, the coder can implement it in one TDD loop, and the reviewer can gate it with the full quality suite without the slice sprawling.

Plain English only — no code. `CONTENT_FORGE_SPEC.md` is the source of truth for feature intent. This document only sequences and slices the remaining work.

## Delivery Mechanism

All remaining phases (10 through 15) ship via the swarmforge tmux flow defined in `swarmforge/`. Per slice:

1. **Architect** reads this plan, picks the next slice, writes the acceptance spec into `CONTENT_FORGE_SPEC.md`, commits on `master`, and notifies the coder.
2. **Coder** merges from `master`, implements the slice TDD-style in `.worktrees/coder` on the `swarmforge-coder` branch, runs the full local quality gate (`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test`; add `mix credo --strict` once it lands), updates `BUILDLOG.md`, commits, and notifies the reviewer.
3. **Reviewer** merges from `swarmforge-coder`, runs the deep gate (full suite + `mix test --cover`), looks for silent failures and pattern-match-first compliance, refactors small things in place if needed, commits on `swarmforge-reviewer`, and notifies both architect and coder. The architect then merges the reviewer's branch into `master`.

If `mix credo --strict` is not yet wired into the project, the first coder slice should add it (see Bootstrap below). The reviewer must not skip a gate just because it is unconfigured — they should fail back to the architect with a request to wire it.

A slice is "done" only when:

- All quality gates pass on the reviewer's branch.
- `BUILDLOG.md` reflects the change with role + date + commit hash.
- `CAPABILITIES.md` is refreshed at end of phase if it has drifted.

## Bootstrap (done before Phase 10)

Both items below landed 2026-04-22 before any Phase 10 work. Retained here as a record of what the swarm depends on.

- **B1. Wire `mix credo --strict` into the project.** ✅ Done. Credo dep installed, `.credo.exs` generated with relaxed nesting and complexity thresholds to grandfather Features 1-9 hotspots, existing findings snapshotted in `.credo_baseline.txt` (44 findings). Reviewer constitution amended to require baseline diffing — slices must not introduce new findings.
- **B2. `mix precommit` alias.** ✅ Done. Runs `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`. Credo is not included in this alias (it would always fail on existing debt); the reviewer runs `mix credo --strict` separately and diffs against the baseline.

## Guiding Principles

## Guiding Principles

- **Bias toward revenue.** Phase 10 (Media Forge wiring) ships working demos faster than any new feature; it goes first.
- **One slice per TDD loop.** Each slice below is intended to fit in a single coder handoff: write one failing test, make it pass, refactor, hand to reviewer.
- **External services behind named modules.** Every integration is swappable in tests via `Req.Test`.
- **Missing credentials downgrade gracefully.** The dashboard should surface "unavailable" rather than crash when a provider is not configured.
- **No placeholder data in production paths.** If the real provider is not wired, the feature is gated off, not faked.

## Phase 10 — Media Forge Integration (unblocks live demos)

**Why first:** Media Forge shipped 2026-04-22. Every slice in this phase replaces stubbed or home-rolled media work with calls into the running service at `http://192.168.1.37:5001`. Delivers functioning end-to-end flows for existing features.

- **10.1 Media Forge HTTP client module** ✅ Shipped `ba3c3ee`.
  - One named module that wraps base URL, `X-MediaForge-Secret` header, JSON body handling, retries, and error classification (transient vs permanent).
  - Exposes functions for the endpoints we actually call: probe, normalize, render, trim, batch render, image process, image render, generation (images and compare), job status, job cancel.
  - Configured by env vars. Missing secret downgrades the client to `status: :unavailable`, which upstream callers surface in the UI.
  - Ships with `Req.Test` stub usage baked into the test suite.

- **10.1.1 MediaForge.classify/1 exhaustiveness for 3xx** ✅ Shipped `2fadc8f`.
  - The classifier currently pattern-matches 2xx, 4xx, 5xx, timeout, transport/network, and a catch-all for generic error tuples. A successful response in the 300-399 range raises a function-clause error. 304 Not Modified is the realistic case if a future caller enables conditional caching; other 3xx codes are reachable if redirect-following is disabled per request.
  - Add a head matching the 3xx range and return an unexpected-status error tuple carrying the status and body. Add a failing test first asserting the tuple shape when the stub responds with 304.
  - The engineering rule requires exhaustive pattern matches; this closes the gap.

- **10.2 Swap image generation onto Media Forge** ✅ Shipped `613d442`.
  - Remove the local stub from the image generation entry point.
  - Issue generation via Media Forge and wait either by poll or by exposing a signed-webhook receiver.
  - Persist the resulting image bytes or R2 key where the existing schema expects them.
  - Additional requirements surfaced during investigation of the existing image generator:
    - When Media Forge reports the not-configured status (no shared secret on this deployment), the job must log the condition, return a skipped result, and leave the draft without an image. No placeholder URL is ever written. This aligns with the project rule that missing credentials downgrade gracefully rather than producing synthetic output.
    - Align the Oban queue configuration so the image generation job actually runs in dev and prod. Several workers (content brief generator, bulk variant generator, multi-model ranker, script gate, winner repurposing, site crawler, repo ingestion, competitor scraper and synthesizer, image generator) declare queues that are not present in the current Oban config. Add those queues as a prerequisite so this slice delivers a feature that actually executes instead of dropping jobs into dormant queues.
    - Fix the queue-override bug in the image generator's bulk-enqueue path where it currently enqueues child jobs into a queue name that does not exist, instead of using the worker's declared queue. Remove the override.
    - Test expectations: stubbed Media Forge responses only; no live calls. Cover synchronous success, asynchronous success resolved by polling job status, not-configured downgrade with no HTTP call, and transient vs permanent error handling.

- **10.2b Publisher-side missing-image block** ✅ Shipped `b89d89c`. (Carved out of 10.2 so the swap slice stayed reviewable; the spec intent was documented under 10.2 but the behavior change was deferred)
  - The publisher currently publishes a social post whether or not it carries an image. Under the spec, every social post that advances past ranking is required to have an AI-generated image, so publishing without one would push incomplete content to platforms and undermine the image-required rule.
  - Change the publisher to treat a missing image on a social post draft as a blocker: do not call the platform client, log the condition, mark the draft as blocked pending image generation, and (optionally) enqueue a retry of image generation for that draft. Non-social drafts are unaffected.
  - The dashboard drafts queue and publishing schedule view surface blocked drafts distinctly so a human can see why nothing published.
  - Tests: one for each platform path showing that a draft without image_url is not published; one for the happy path that does publish when image_url is present; one asserting the drafts queue view labels the blocked draft.

- **10.2c ImageGenerator test coverage fill** ✅ Shipped `78d4437`.
  - ImageGenerator coverage after 10.2 is around 66%. Uncovered paths include the persist-or-fail case when Media Forge returns a success without a usable URL, the unrecognized-sync-body branch, the polling path that observes a late `:not_configured` status from Media Forge, and the generic error tuple from an otherwise-unclassified response.
  - Add focused tests for each uncovered branch using the existing Req.Test stub pattern. No behavior change; pure coverage fill.
  - Reviewer should see module coverage lift above a target (aim for 90%+) while the overall threshold stays at zero.

- **10.2a Media Forge cost mirror and dashboard surfacing** (split from 10.2 for scope control so the swap above stays reviewable)
  - Cost reporting in the dashboard should read from Media Forge's cost endpoint (or our mirrored record), not placeholder numbers.
  - Ingest the Media Forge cost endpoint into a lightweight mirror table (product, cost, provider, generated-at) so the dashboard can display real per-product generation spend.
  - Add a dashboard card on the performance or schedule page showing cumulative image generation cost per product and a rolling seven-day spend number.
  - Backfill strategy for rows that existed before the mirror began: none; start collecting from slice merge forward.

- **10.3 Swap video pipeline FFmpeg step onto Media Forge** ✅ Shipped `42db18f`.
  - Video production pipeline currently calls FFmpeg locally in one step. Replace that step with a Media Forge `/api/v1/video/render` (or `/api/v1/video/batch` for multi-platform) call.
  - Remotion is still responsible for the pre-render composition; Media Forge owns final encoding and per-platform rendition.
  - Preserve existing per-step status tracking in the dashboard.
  - Additional requirements surfaced during investigation:
    - The current step 5 in the video producer is a simulation ("Would FFmpeg encode", returns a fake R2 key) gated behind a product config flag. There is no real FFmpeg invocation today. Removing the simulation and its config flag is part of this slice; no backwards-compatible "enabled" flag is preserved because the local path is being retired entirely.
    - Route the single-output render call through `ContentForge.MediaForge.enqueue_render/1`. Batch render for per-platform outputs is deferred until Feature 11 or Phase 15 needs it; do not add batch call sites yet.
    - Resolution is poll-based: once the enqueue returns a job id, the worker polls job status until done or failed, with a capped retry count and a configurable interval, mirroring the ImageGenerator pattern from 10.2. Webhook resolution waits for 10.5.
    - On a done status, persist the Media Forge R2 key under the final-encode step in the video job's per-step storage map, transition the video job from `assembled` to `encoded`, and let the existing YouTube upload step pick it up from there.
    - On `{:error, :not_configured}`, the step logs "Media Forge unavailable" and leaves the video job at `assembled`. The existing dashboard video status board should show the pause reason; that surfacing lives in 10.3 so the slice ships a visible state transition rather than silent stalling.
    - On transient errors, the worker returns so Oban retries. On permanent errors (4xx/cancel/unexpected-status), mark the video job `failed` with the error recorded on the `error` field.
    - Tests use `Req.Test` stubs for Media Forge responses and cover: sync success with immediate R2 key, async success resolved by polling, `:not_configured` leaves the job at `assembled`, permanent error fails the job, transient error triggers retry. No live Media Forge calls from the suite.

- **10.4 Swap image processing (EXIF, crops, platform renditions) onto Media Forge** (folded into Phase 13 / Feature 11)
  - Any place Content Forge manipulates uploaded images (autorotate, EXIF strip, platform crops) moves to Media Forge's `/api/v1/image/*`.
  - This primarily serves Feature 11 (Product Asset Management) when that lands, but upgrade any existing image pre-processing first so Feature 11 inherits the plumbing.
  - **Deferred-into-13 rationale:** A search at phase time (HEAD `42db18f`) confirmed there are no existing callers doing EXIF, autorotate, crop, or resize work inside Content Forge. The only image touchpoint today is `ImageGenerator` which already routes through `MediaForge.generate_images/1` per 10.2. Because 10.4's acceptance boils down to "swap the zero existing callers", there is nothing to do as a standalone slice. The requirement is folded into the acceptance intent for Feature 11 (Product Asset Management): the first asset-upload caller that wants rotation, EXIF strip, or platform crop must call into the MediaForge image endpoints directly rather than re-introducing a local image library.

- **10.5 Signed-webhook receiver for Media Forge job completion** ✅ Shipped `f990a38`.
  - Endpoint that verifies `X-MediaForge-Signature` (HMAC SHA256, Stripe-style timestamp window, `Plug.Crypto.secure_compare`) and updates the corresponding Content Forge job record.
  - Alternative to polling. Job records should support either mode.
  - This is a prerequisite for the pipeline work above if we want to avoid long poll loops; slice 10.1 through 10.4 can start with polling, then 10.5 upgrades them once shipped.
  - Additional requirements surfaced during investigation:
    - The inbound endpoint lives on a new public route that does not go through the API bearer-token pipeline; authentication is HMAC over the raw request body. A body-reader plug captures the raw body before JSON parsing so the signature check can run against the exact bytes that Media Forge signed.
    - Timestamp window is 300 seconds. Requests with timestamps outside the window are rejected with HTTP 400 and "stale request" in the body. Signature mismatches are rejected with HTTP 401. Both rejections log the condition but do not echo the offending signature.
    - On a valid signature, the handler parses the JSON body, looks up the matching Content Forge record (the image-generator draft by media forge job id, the video job by media forge job id), and applies the completion. Records already in a terminal state are treated as a no-op and return HTTP 200 so Media Forge does not retry.
    - Resolution is shared with polling. A single internal function (in `ContentForge.MediaForge` or a small resolution module) handles "job done" / "job failed" state transitions regardless of whether the trigger was a poll or a webhook. The poller and the webhook controller both call that function so state transitions stay identical.
    - Tests cover: valid webhook updates the draft's `image_url`, valid webhook updates the video job to `encoded`, stale timestamp returns 400, bad signature returns 401, unknown job id returns 404, webhook arriving after polling already resolved returns 200 with a no-op.
    - No live Media Forge calls from the test suite; the webhook side is exercised directly via `Phoenix.ConnTest` with forged valid signatures.

- **10.5a Webhook test output cleanup** ✅ Shipped `d402d8d`.
  - The webhook receiver test file produces noisy output because five rejection paths (stale timestamp, bad signature, malformed body, unknown job id, unsigned request) log warnings that are not wrapped in `capture_log`. Engineering rule says test output must be clean.
  - Wrap each of the five log-producing assertions in `ExUnit.CaptureLog.capture_log/1`. For cases where the function under test also returns a value that the assertion needs, use the `send-to-self` pattern already documented in `CLAUDE.md`.
  - Pure test hygiene; no behavior change.

Phase exit criteria: end-to-end image generation, image processing, and video rendition all run against live Media Forge in dev; tests run against stubs; dashboard shows real cost numbers; no placeholder image URLs anywhere.

## Phase 11 — Real-Provider Wiring Audit

**Why second:** Several generation and scraping paths still return stubbed output. The previous audit (CAPABILITIES.md at commit `afc9e17`) flagged this; HEAD has moved, and a recent commit (`3ab96c4`) wired MetricsPoller to real platform APIs. This phase replaces remaining stubs with real calls — or gates them off cleanly.

- **11.1 Brief generator real-model wiring**
  - Replace any remaining template-text returns with real Anthropic / Google / xAI / OpenAI calls.
  - Pass performance context and competitor context into the prompt.
  - Stubbed in tests, live in dev/prod.
  - **Slicing note:** This one BUILDPLAN entry expands into several coder handoffs, mirroring the Phase 10 pattern of "ship an infra client, then swap each caller". The slices below carve up the work.

- **11.1 (infra) Anthropic LLM client module** ✅ Shipped `00f9ebc`.
  - Ship a named client module wrapping Anthropic's Messages API: base URL, `x-api-key` header, `anthropic-version` header, JSON body construction, timeout, retry policy, and transient-vs-permanent error classification.
  - One public function on the module shape of `complete(prompt, opts)` returning a success tuple carrying the response text, or a classified error tuple.
  - Configured from application env under `:content_forge, :llm, :anthropic` with `:api_key`, `:default_model`, `:max_tokens`. The API key is sourced from an environment variable at runtime via `config/runtime.exs`. When the key is absent, the client reports an `:not_configured` status and every call returns `{:error, :not_configured}` without any HTTP I/O, mirroring the Media Forge pattern.
  - Error classification mirrors MediaForge: 5xx or timeout to transient, 4xx to permanent, connection failure to transient-network, 3xx catch-all to unexpected-status, and a pass-through clause for anything else.
  - `Req.Test` stub adapter baked in from day one; no live Anthropic calls from the test suite.
  - Tests: classification per branch, missing-key downgrade that records zero HTTP calls, one happy-path completion, one rate-limit (429) case returning the transient tuple, one explicit `:not_configured` case.

- **11.1 (caller) Brief generator swap onto LLM client** ✅ Shipped `f57427e`.
  - Remove the hardcoded templated text from the content-brief and brief-rewrite paths.
  - Build the existing context map into a prompt (keep the context shape; only the consumption changes) and call the new LLM client's completion function.
  - On success, the returned text becomes the brief content; the `model_used` field reflects the actual provider and model name rather than the hardcoded "claude" string the placeholder uses today.
  - On `{:error, :not_configured}`, log "LLM unavailable", return a skipped result, and do not create a brief record. No placeholder brief text ever reaches the database, consistent with the project rule that missing credentials downgrade gracefully rather than fabricating output.
  - On transient errors let Oban retry. On permanent errors, cancel the job with the error recorded; no retry until the upstream is fixed.
  - Tests: happy-path brief generation, missing-key skip that records no brief, transient error triggers retry, permanent error cancels the job. Stubbed Anthropic responses only.

- **11.1b (infra) Google Gemini LLM client module** ✅ Shipped `c90aa38`.
  - Mirror of 11.1 (infra) for Anthropic, targeting Google's Generative Language API.
  - Public function shape is the same as Anthropic's completion function so both providers are substitutable at the call site. Config namespace lives at `:content_forge, :llm, :gemini` with `:api_key`, `:default_model`, `:max_tokens`. API key authentication follows Google's header or URL-param convention as currently documented; the slice picks whichever keeps the client idiomatic with Req.
  - Error classification matches Anthropic and MediaForge: 5xx and 429 transient, 4xx permanent, timeout and connection failure transient-network, 3xx unexpected-status, catch-all pass-through. Missing API key returns `{:error, :not_configured}` with zero HTTP I/O.
  - Response parsing extracts the text from the first candidate's content parts.
  - `Req.Test` stub from day one. Tests: happy-path completion, 429 transient, 500 transient, 400 permanent, missing-key no-HTTP downgrade.

- **11.1c Brief generator synthesis across providers** ✅ Shipped `7398d71`.
  - Update the brief generator to query both Anthropic and Gemini in parallel when both are configured, then synthesize the two drafts into a single brief. Satisfies the "at least 2 smart models" acceptance criterion on Feature 3 Stage 1.
  - Synthesis logic is the simplest thing that works: feed both drafts as context back into one final Anthropic completion that produces the synthesized brief. More sophisticated merging is deferred until performance data says it matters.
  - When only one provider is configured, the brief is generated from that one provider alone (no synthesis step). When neither is configured, the existing skip path fires (no brief record). When one provider succeeds and the other errors transiently, the brief still generates from the successful provider with a note on the brief metadata; neither error escalates if at least one draft succeeded.
  - Tests cover: both configured (synthesis path), Anthropic-only, Gemini-only, neither configured (skip), one transient-failure with other succeeding (single-provider fallback path), both fail transiently (Oban retries).

- **11.2 Bulk variant generation via OpenClaw**
  - Configure the live OpenClaw endpoint for bulk variant generation.
  - Remove mock variant returns.
  - Gate off with "unavailable" if OpenClaw is not configured.
  - **Slicing note:** Expands into an infra slice and a caller slice following the 11.1 pattern.

- **11.2 (infra) OpenClaw HTTP client module** ✅ Shipped `b2785d8`.
  - Ship a named client module at `ContentForge.OpenClaw` under `lib/content_forge/open_claw/` (or a single file if no helpers emerge), wrapping OpenClaw's bulk-generation endpoint.
  - One public function on the shape of `generate_variants(request, opts)` that accepts a request map (product brief, platform, angle, count, content_type) and returns a success tuple carrying the list of generated variants, or a classified error tuple.
  - Config namespace at `:content_forge, :open_claw` with `:base_url`, `:api_key`, `:default_timeout`. API key sourced from env at runtime via `config/runtime.exs`.
  - Error classification mirrors Integrations 1 and 3: 5xx transient, 4xx permanent, timeout transient, connection refusal transient-network, 3xx unexpected-status, catch-all. Missing API key or base URL returns `{:error, :not_configured}` with zero HTTP I/O.
  - Authentication header attached inside the client per OpenClaw's convention (bearer token or custom header, coder confirms against the running OpenClaw instance at the time of the slice). Coder records the chosen header name in the module docstring and the BUILDLOG handoff.
  - If OpenClaw's bulk endpoint is still being finalized at slice time, the client ships against a documented target shape and its tests stub that shape. Switching to a different shape is a one-call-site fix, not a client rewrite.
  - `Req.Test` stub from day one. Tests: happy-path batch generation, 429 transient, 500 transient, 400 permanent, missing-config no-HTTP downgrade.

- **11.2 (caller) OpenClawBulkGenerator swap onto the client** ⏸ Paused 2026-04-23.
  - Paused before implementation. Live-shape verification against OpenClaw failed: localhost ports 5002/5003/5100/8080/8081/3001 unresponsive, 192.168.1.37:5001 is Media Forge, localhost:3000 is Remotion Studio, no `OPENCLAW_BASE_URL` env var is set, and only `OPENCLAW_TELEGRAM_TOKEN` exists (the Telegram bot deployment, not a bulk-generation API). The architect's read: OpenClaw's bulk-generation endpoint does not currently exist in the ecosystem; only the Telegram bot is deployed. Resuming 11.2 (caller) requires either a real OpenClaw generation service to be stood up elsewhere in the ecosystem, or the architect to reroute bulk generation through a different provider (for example, an LLM-based bulk generator using the existing Anthropic / Gemini clients, trading cost for availability). Decision deferred until the user weighs in or the generation service lands.
  - **Prerequisite: live shape verification.** Before writing any swap code, issue one minimal generation request against the running OpenClaw instance and capture the actual response shape, the chosen auth header name, and the exact endpoint path. Compare against the target-shape assumption recorded in the `ContentForge.OpenClaw` moduledoc (`Bearer` header, `/api/v1/generate`). If the live shape differs, fix the client inline as part of this slice and document the delta in the handoff; bundling is acceptable because live reality forces it. If OpenClaw is unreachable at slice time, pause the slice and notify the architect rather than shipping blind against an unverified target.
  - Remove the hardcoded sample-content maps (`generate_social_content`, `generate_blog_content`, `generate_video_script_content`) and their surrounding placeholder scaffolding from the bulk generator job.
  - Build the prompt payload per platform and per content-type from the brief + product context (the existing `build_social_prompt`, `build_blog_prompt`, etc. can stay; only the call that consumes them changes).
  - Call the new OpenClaw client with the appropriate request shape for each content type (social, blog, video script).
  - On `{:error, :not_configured}`: log "OpenClaw unavailable", return a skipped result, do not create any Draft records. No synthetic variants ever reach the database.
  - On transient errors let Oban retry. On permanent errors, cancel the job with the error recorded; no retry until the upstream is fixed.
  - Each returned variant becomes a Draft record with its platform, angle, content, generating model set to the OpenClaw model name echoed in the response, and status `draft`. The existing humor-variant guarantee (at least one per content type per batch) remains a brief-instruction concern, not a post-filter in this slice.
  - Tests: happy-path batch for social + blog + video scripts, missing-config skip with zero Drafts created, transient retry, permanent cancel, humor-angle presence when brief includes the humor instruction.

- **11.2M MultiModelRanker real scoring via LLM clients** (inserted between 11.2 and 11.3 because it fixes the same class of silent-data bug as 11.1 and is unblocked by the now-shipped LLM infra)
  - `ContentForge.Jobs.MultiModelRanker.query_model_for_scores/4` currently returns `Enum.random(6..9)` for accuracy, SEO, and EEV. Every "top-ranked" draft is a random pick; calibration adjustments run against fake signal. This is synthetic data reaching production flows.
  - Swap the scoring function onto `LLM.Anthropic.complete/2` (and `LLM.Gemini.complete/2` for the Gemini-designated calls) using a structured scoring prompt that asks for a JSON response carrying the three dimension scores plus the critique. The prompt includes the draft, the brief, and the calibration + scoreboard context already being built.
  - Parse the model's JSON response; on parse failure treat as a permanent error for that score attempt and skip promotion for the draft rather than fabricating fallback scores.
  - `{:error, :not_configured}` logs "LLM unavailable for ranking", returns a skipped result for that model's contribution, and the draft is ranked on the remaining providers if any. If neither provider is configured, the ranker returns a skipped result without promoting any drafts.
  - Tests: happy-path scoring via both providers with a stubbed JSON reply, one-provider-missing falls back to the other, neither-provider-configured skips without promoting, malformed JSON reply surfaces a clear error without creating fake scores, transient error triggers Oban retry.
  - This slice does not touch the xAI pseudo-scoring path (no xAI client exists yet). xAI can be added later as an 11.2M-b follow-up if scoring diversity demands a third provider; for now two providers match the "at least 2 smart models" structure the brief generator uses.

- **11.3 Apify competitor scraping audit**
  - Confirm scrapers hit real Apify actors with real API tokens (per-platform actor selection).
  - Replace any remaining mocked returns and verify the intel synthesis step receives real post payloads.
  - **Slicing note:** Investigation at this wave point shows `CompetitorScraper` and `CompetitorIntelSynthesizer` are correctly gated behind `:apify_token` + `:scraper_adapter` and `:intel_model` config respectively, and both discard rather than fabricate when unconfigured. What is missing is the actual adapter implementations. Carves into two slices below.

- **11.3a Apify scraper adapter module** ✅ Shipped `b42ec2a`.
  - Build `ContentForge.CompetitorScraper.ApifyAdapter` implementing `fetch_posts/1` that the existing `CompetitorScraper` already dispatches to via the `:scraper_adapter` config.
  - Public surface: a single `fetch_posts(%CompetitorAccount{})` function that returns a success tuple carrying a list of post maps (each with post_id, content text, post_url, likes_count, comments_count, shares_count, posted_at) or a classified error tuple on the same shapes used elsewhere in the codebase.
  - Per-platform actor routing: a config map under `:content_forge, :apify, :actors` that maps platform names (twitter, linkedin, reddit, facebook, instagram, youtube) to Apify actor ids. Missing actor for a requested platform returns `{:error, :unsupported_platform}` without an HTTP call. The module's moduledoc records which actor id was chosen per platform at slice time so future readers can tell.
  - Apify HTTP interactions run through a thin internal client that wraps Req: run an actor (POST `/v2/acts/{actor}/runs`), poll the run until terminal (GET `/v2/actor-runs/{run_id}`), then fetch dataset items (GET `/v2/datasets/{default_dataset_id}/items`). Polling uses a capped retry count and a configurable interval mirroring the MediaForge + ImageGenerator pattern.
  - Output parsing is per-platform: each actor returns its own JSON shape, and the adapter normalizes to the `CompetitorScraper` expected post map. Parse failures for individual items are logged and counted but do not fail the whole scrape; a partial result is acceptable. Complete parse failure (zero posts normalized) returns a classified error so the caller can retry or discard.
  - Error classification mirrors Integration 1 patterns: 5xx transient, 429 transient, 4xx permanent, timeout transient, connection refusal transient-network, 3xx unexpected-status, catch-all pass-through. Missing API token returns `{:error, :not_configured}` with zero HTTP I/O.
  - `Req.Test` stubbed from day one; no live Apify calls from the suite. Tests cover: one happy-path scrape per supported platform with a realistic stubbed actor output shape, rate-limit transient, permanent 4xx, timeout transient, missing-token short-circuit, unsupported-platform short-circuit, partial-parse success.
  - The slice also sets the runtime config wiring in `config/runtime.exs` so `APIFY_TOKEN` in the environment flows through to `:content_forge, :apify, :token`, and `:content_forge, :scraper_adapter` defaults to `ContentForge.CompetitorScraper.ApifyAdapter` in prod (leaves it unset in test so the discard path stays observable).

- **11.3b Intel synthesizer LLM adapter module** ✅ Shipped `59397aa`.
  - Build `ContentForge.CompetitorIntelSynthesizer.LLMAdapter` implementing `summarize/1` that the existing synthesizer already dispatches to via the `:intel_model` config.
  - Public surface: a single `summarize([%CompetitorPost{}])` function that returns a success tuple carrying a map with the summary text, trending topics, winning formats, and effective hooks per the `CompetitorIntel` schema, or a classified error tuple on failure.
  - The adapter internally calls `LLM.Anthropic.complete/2` with a structured prompt that asks for a JSON response matching the intel schema shape. JSON parsing mirrors the MultiModelRanker pattern: direct decode, fenced-block regex fallback, reject-malformed-without-fabricating-fallback.
  - `:not_configured` passes through from the LLM client; the synthesizer discards on that path already, so no extra handling is needed. Transient errors propagate so Oban can retry.
  - The slice sets the runtime config wiring so `:content_forge, :intel_model` defaults to the new adapter in prod, unset in test.
  - Tests: happy-path synthesis returning a parsed intel map, malformed JSON rejected without fabrication, missing-LLM-key returns `{:error, :not_configured}`, transient LLM error propagates for retry.

- **11.4 Brief-rewrite auto-trigger**
  - AUDIT.md previously noted the brief-rewrite trigger "always returns false until metrics flow in." Metrics now flow in. Wire the trigger so brief regeneration fires at the documented threshold (5+ new measurements).
  - **Slicing note:** Investigation at this wave point shows both 11.4 and 11.5 are already wired in `MetricsPoller` (`check_rewrite_trigger/1` at line 105 enqueues the rewrite job via `ContentBriefGenerator` with `force_rewrite: true`; `trigger_spike_alert/2` at line 301 enqueues `WinnerRepurposingEngine` when outcome is "winner" and delta exceeds 3.0). What is missing is test coverage: grep for the trigger function names across `test/` returns zero hits, so the behavior is de-facto shipped but unverified.

- **11.5 Winner-repurposing auto-trigger**
  - When the scoreboard marks a piece a winner, auto-fire the repurposing pipeline. Currently manual.

- **11.4+11.5 (verify) MetricsPoller auto-triggers tests** ✅ Shipped `62e1391`.
  - Single verification slice covering both 11.4 and 11.5 since both triggers fire from the same worker and share the same state-to-job-enqueue pattern.
  - Tests for the rewrite trigger: when `should_trigger_rewrite?` would return true for a product + platform pair (at least five scoreboard entries with `delta < -1.0` within the configured window), a call into `MetricsPoller`'s perform path enqueues a `ContentBriefGenerator` job with `force_rewrite: true` for that product.
  - Tests for the spike-alert trigger: when a scoreboard update flips the entry's outcome to `"winner"` and the delta exceeds 3.0, a `WinnerRepurposingEngine` job is enqueued for the corresponding draft.
  - Negative tests: fewer than five poor-performer entries does not enqueue a rewrite; a winner with delta below 3.0 does not enqueue repurposing; the enqueued jobs are idempotent (re-running the same poll does not duplicate jobs for the same state transition).
  - If writing the tests surfaces a bug in the wired code (for example, a threshold off-by-one, a wrong job-arg key, or a missed enqueue path), the fix ships in the same slice. Bundling is acceptable because the test is the first time behavior is being asserted.
  - Oban is in `testing: :manual` mode in this project, so tests assert on the enqueued job specs directly rather than running them.

Phase exit criteria: no stubbed external calls remain in production paths; a dashboard "provider status" panel shows which integrations are live vs unavailable; auto-triggers fire deterministically on the documented conditions.

## Phase 12 — Feature 10: SEO Quality Pipeline

Per `CONTENT_FORGE_SPEC.md` Feature 10. Goal: produce content that is AI-retrievable (GEO-optimized) and meets a 28-point quality bar.

- **12.1 AI Summary Nuggets**
  - First paragraph of every long-form piece is a self-contained summary optimized for AI citation. Structured, entity-dense, scannable.
  - Validation step in the generation pipeline that flags drafts missing the nugget.

- **12.2 28-point SEO checklist**
  - Codify each of the 28 points as a discrete check against a draft.
  - Run the checklist at draft time and surface failures in the review UI.
  - Store checklist results on the draft record for audit.

- **12.3 Original Research block**
  - Pipeline step that sources original data (survey, scrape, or competitor delta) and injects a research block into the draft.
  - If no research can be sourced for a topic, flag rather than fabricate.

- **12.4 Dashboard surfacing**
  - Drafts page shows checklist status per item and blocks publishing on red checks unless manually overridden.

Phase exit criteria: every long-form draft passes the nugget check and the 28-point checklist before hitting publish; research block presence is visible in the dashboard; integration tests cover "draft missing nugget" and "checklist red" paths.

## Phase 13 — Feature 11: Product Asset Management

Per `CONTENT_FORGE_SPEC.md` Feature 11. Leans heavily on Phase 10 Media Forge plumbing.

- **13.1 Asset upload**
  - LiveView upload form for product-level assets (images, short videos, PDFs).
  - Files go to Media Forge for EXIF / normalization / thumbnail generation; renditions land in R2.
  - Records the asset metadata and R2 keys in the Content Forge DB.
  - **Slicing note:** Expands into a schema-plus-context slice, a presigned-upload slice, a LiveView upload-form slice, and two processing dispatch slices (image, video). Each is a single TDD loop.

- **13.1a ProductAsset schema and context module** ✅ Shipped `43d8db5`.
  - New Ecto schema `ContentForge.ProductAssets.ProductAsset` at `lib/content_forge/product_assets/product_asset.ex` with fields: `product_id` (binary_id fk, required), `storage_key` (string, required — the R2 or Bunny object key for the original upload), `media_type` (string enum, `"image"` or `"video"`, required), `filename` (string, required — original filename as provided by the uploader), `mime_type` (string, required), `byte_size` (integer, required), `duration_ms` (integer, nil for images), `width` (integer), `height` (integer), `uploaded_at` (utc_datetime_usec, required), `uploader` (string — free-form identifier of who uploaded, for example a phone number later in Feature 12), `tags` (array of strings, default empty), `description` (text, nullable), `status` (string enum, one of `"pending"`, `"processed"`, `"failed"`, `"deleted"`, default `"pending"`), plus the usual `inserted_at` and `updated_at`.
  - Migration `priv/repo/migrations/<ts>_create_product_assets.exs` creates the table with binary_id primary key, foreign key constraint to `products` with `on_delete: :nilify_all` (soft-delete-safe for the product), an index on `(product_id, status)` for dashboard list queries, and a GIN index on `tags` for array-overlap searches. A partial unique index on `(product_id, storage_key)` where `status != 'deleted'` guards against accidental double-registration of the same upload.
  - New context module `ContentForge.ProductAssets` at `lib/content_forge/product_assets.ex` with: `create_asset/1` (takes attrs, inserts), `get_asset!/1`, `get_asset_by_storage_key/2` (by product and storage_key), `list_assets/2` (by product with filter keyword list — tag, media_type, status — and sort_by :uploaded_at descending by default), `list_distinct_tags/1` (returns sorted unique tags for a product, used for autocomplete), `update_asset/2`, `mark_processed/2` (transitions `pending` → `processed` and writes dimension/duration metadata), `mark_failed/2` (records an error string), `soft_delete_asset/1` (sets status to `"deleted"` without removing the row).
  - No upload flow, no storage integration, no LiveView in this slice. Only the schema, migration, and context.
  - Tests cover: the full CRUD happy path, the filter combinations on `list_assets/2`, the `list_distinct_tags/1` deduplication, the soft-delete preserves the row and hides it from default lists, the unique constraint on storage_key rejects a duplicate, and the status transitions on mark_processed and mark_failed.

- **13.1b Presigned upload URL endpoint** ✅ Shipped `8342247`.
  - New REST endpoint `POST /api/v1/products/:product_id/assets/presigned-upload` under the existing bearer-token API pipeline. Request body carries the intended filename, content type, and byte size. Response carries a presigned PUT URL scoped to a unique storage key (path like `products/<product_id>/assets/<uuid>/<filename>`), the storage key itself, and an expiry timestamp (15 minutes by default).
  - The presigning goes through the existing `ContentForge.Storage` module (`ExAws` R2 backend). The controller does not accept the upload bytes directly; the client uploads straight to R2 via the presigned PUT, avoiding the Phoenix server on the hot path.
  - After the client PUT succeeds, the client posts the upload result back to `POST /api/v1/products/:product_id/assets/register` with the storage key, filename, content type, byte size, and any client-side metadata. The register endpoint creates the `ProductAsset` row in `status: "pending"` and enqueues a processing Oban job (scoped to the right queue based on `media_type`).
  - Content type allow-list: `image/jpeg`, `image/png`, `image/webp`, `image/heic`, `video/mp4`, `video/quicktime`, `video/x-m4v`. Anything else returns a 415.
  - Byte-size cap configurable per deployment; default 500MB for video, 50MB for image. Anything larger returns a 413 with the configured limit in the response body.
  - Tests cover: presigned URL is generated and signed correctly (verify the structure; do not call R2), register endpoint creates a row and enqueues the right processing job per media_type, disallowed content types are rejected, oversized byte sizes are rejected, missing auth on the endpoint returns 401.

- **13.1c LiveView upload form on product detail page** ✅ Shipped `1c6b4d5`.
  - Extend the product detail LiveView with an upload form that uses Phoenix LiveView's native uploads. The form allows multi-file selection, shows per-file progress, and after a file finishes uploading client-side, fires the presigned-upload flow from 13.1b.
  - Mobile-first markup: the file input opens the phone's camera or camera roll via standard `accept` attribute; drag-and-drop is offered on desktop. Touch targets meet WCAG AA.
  - After successful registration, the row appears in an "Assets" section of the product detail page with a pending badge. The processing job flips the badge to `Processed` (or `Failed` with the error) via Phoenix PubSub.
  - Tests: the LiveView renders the form, a stubbed registration call transitions the UI state, a processing completion over PubSub updates the badge.

- **13.1d Image processing dispatch to Media Forge** ✅ Shipped `afd596b`.
  - New Oban worker `ContentForge.Jobs.AssetImageProcessor` under queue `:content_generation` (the existing queue configured in 10.2) that consumes an asset id, calls `MediaForge.enqueue_image_process/1` with the storage key and the requested transforms (autorotate, strip EXIF, generate thumbnail at a fixed size, probe dimensions), polls job status until terminal, and on success calls `ProductAssets.mark_processed/2` with the dimensions returned from Media Forge and the thumbnail's storage key recorded on the asset row.
  - On `{:error, :not_configured}`: mark the asset failed with `"media_forge_unavailable"` so the dashboard surfaces it rather than hanging in `pending`. No synthetic dimensions or thumbnail are fabricated.
  - On transient errors: let Oban retry. On permanent errors: mark the asset failed with the error recorded.
  - Tests use the existing `Req.Test` stub pattern. Cover: happy-path sync + async + not-configured + transient retry + permanent failure.

- **13.1e Video processing dispatch to Media Forge**
  - New Oban worker `ContentForge.Jobs.AssetVideoProcessor` under queue `:content_generation` that consumes an asset id, calls `MediaForge.enqueue_normalize/1` with the storage key and the video normalization config (probe, normalize to H.264/AAC, generate poster thumbnail), polls until terminal, and on success records duration_ms, width, height, a normalized-video storage key, and a poster-image storage key on the asset. Same error handling rules as 13.1d.
  - Tests mirror 13.1d plus one for duration being recorded correctly.

- **13.2 Tagging and search**
  - Free-text tags plus inferred tags (from filename, EXIF, dominant-color, or model-captioning).
  - Search within a product's asset library by tag and by media type.

- **13.3 Asset bundles**
  - Group assets into named bundles (for example "Product launch 2026-05 hero set").
  - Bundles attach to drafts and provide media for the generation pipeline.

- **13.4 Draft generation from assets**
  - Generation entry point that accepts an asset bundle and emits draft copy keyed to the visual narrative of the bundle.
  - Model prompt includes asset captions / tags so copy and imagery align.

- **13.5 Asset renditions on publish**
  - At publish time, Content Forge requests platform-specific renditions from Media Forge (Instagram 1:1, TikTok 9:16, etc.) and attaches the rendition to the platform post.

Phase exit criteria: a marketer can upload a product photo, tag it, drop it in a bundle, generate a draft around it, and publish per-platform renditions without touching any external tool.

## Phase 14 — Feature 12: SMS Gateway and Conversational Bot

Per `CONTENT_FORGE_SPEC.md` Feature 12. Twilio + OpenClaw integration.

- **14.1 Twilio inbound webhook**
  - Signed webhook receiver for SMS. Parses message, identifies contact, routes to a conversation session.
  - Validates Twilio signature. Unknown numbers optionally get a gated response.

- **14.2 Conversation sessions**
  - Session schema that holds conversation state across messages.
  - OpenClaw reply generation with session context.
  - Outbound send via Twilio with retry on transient failure.

- **14.3 Upload flow via SMS**
  - Contact can MMS a photo; Content Forge routes the media through Media Forge (EXIF, rendition) and attaches the asset to the related product or draft.

- **14.4 Reminders**
  - Scheduled outbound reminders (content review deadlines, publish approvals).
  - Oban-driven, idempotent, respects quiet hours.

- **14.5 Escalation**
  - If OpenClaw cannot confidently answer within a session, escalate to a human operator by creating a dashboard notification and pausing autoresponse.

Phase exit criteria: a marketer can text a photo in, get it tagged into a product library, receive a scheduled review-deadline reminder, and escalate to a human when the bot is uncertain.

## Phase 15 — Polish

Pick up after the feature waves clear. Any of these can be inserted earlier if it starts actively blocking sales demos.

- **15.1 Dashboard UX pass**
  - Script-gate threshold view on the video page.
  - Calendar / timeline visualization on the schedule page.
  - Provider status panel (per Phase 11 exit).

- **15.2 WCAG AA audit**
  - Full pass over every LiveView page: contrast, keyboard focus order, ARIA labels, screen-reader verification.
  - Fix findings in small slices, one page at a time.

- **15.3 End-to-end integration tests**
  - At least one multi-step pipeline test per feature: product registered → brief generated → variants ranked → published → metrics collected → winner repurposed.
  - Against stubbed externals; live smoke is a separate manual runbook.

- **15.3a Coverage uplift and threshold tightening**
  - Baseline is `test_coverage: [summary: [threshold: 0]]` in `mix.exs` (acknowledged debt, overall ~18%). Pair with 15.3 work: as E2E tests land, raise the per-module threshold in tranches (start at 25, then 50, then back toward Elixir's default of 90).
  - A dedicated cleanup slice at the end of the wave should set the final threshold and update `BUILDLOG.md` with the final coverage number.

- **15.4 Load smoke**
  - Small load test against the Review API and the publishing endpoints to catch N+1s and session-handling issues before they bite in a real launch.

## Open Risks and Unknowns

- `CAPABILITIES.md` lags HEAD. Treat its claims as last-known-good-at-`afc9e17`, not current truth. The architect should refresh it at the end of Phase 11 when the stub/live picture stabilizes.
- Phase 10 depends on Media Forge staying up on the M4 Mac. Any slice that assumes Media Forge is reachable needs a clean fallback path (feature marked unavailable) so a restart does not take the dashboard down.
- Phase 14's Twilio integration has per-minute cost implications; budget-cap the outbound sender before enabling it in prod.
- Phases 13 and 14 both write into the asset flow. If they ship close together, coordinate schema migrations to avoid merge conflicts on the assets table.
