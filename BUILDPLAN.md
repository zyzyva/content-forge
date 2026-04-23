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
  - Additional requirements surfaced during Phase 11/13 work:
    - Applies to blog drafts (content_type = "blog"). Short-form social posts (content_type = "post") are already self-contained so are exempt.
    - The nugget is the first 200 characters of the blog draft, and must be a self-contained factual summary — the reader should understand the core claim without scrolling further. Template requirements: no hedging phrases ("sort of", "might possibly"), no pronoun reference to outside-article context, no hypothetical questions, no preamble.
    - A new schema field `ai_summary_nugget` (text, nullable) on `Draft` stores the extracted/validated nugget once generation runs.
    - A new post-generation validator `ContentForge.ContentGeneration.NuggetValidator.validate/1` inspects a blog draft and returns `{:ok, nugget_text}` if the first paragraph meets the criteria, or `{:error, reasons_list}` if it fails. Criteria: length 100..250 chars after stripping, at least two entity-style tokens (proper nouns or numbers), no disallowed hedging phrases, no pronouns referring to outside context.
    - The blog draft generation prompt (wherever it lives — currently part of `AssetBundleDraftGenerator` for bundle-generated drafts; there is no dedicated blog-generation worker yet) is updated to explicitly instruct the model to open with such a nugget. When blog drafts come from future generators, they inherit this instruction from a shared prompt builder.
    - Post-generation hook: after any blog draft is created, `NuggetValidator.validate/1` runs; on success `ai_summary_nugget` is populated; on failure the draft status is set to `"needs_review"` (new status) with the reasons recorded on `draft.error`.
    - Status list on `Draft` extended to include `"needs_review"`; shared `status_badge` component and dashboard filter tab follow the established extension pattern.
    - Tests: validator returns ok for a well-formed nugget; validator returns error for too-short, too-long, no-entities, hedging, and pronoun-reference cases; generation hook sets `ai_summary_nugget` on success; generation hook sets `needs_review` + error reasons on failure.

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

- **13.1e Video processing dispatch to Media Forge** ✅ Shipped `7772fc9`.
  - New Oban worker `ContentForge.Jobs.AssetVideoProcessor` under queue `:content_generation` that consumes an asset id, calls `MediaForge.enqueue_normalize/1` with the storage key and the video normalization config (probe, normalize to H.264/AAC, generate poster thumbnail), polls until terminal, and on success records duration_ms, width, height, a normalized-video storage key, and a poster-image storage key on the asset. Same error handling rules as 13.1d.
  - Tests mirror 13.1d plus one for duration being recorded correctly.

- **13.2 Tagging and search**
  - Free-text tags plus inferred tags (from filename, EXIF, dominant-color, or model-captioning).
  - Search within a product's asset library by tag and by media type.
  - **Slicing note:** Split free-text tag+search (13.2a, minimum viable) from inferred-tag generation (13.2b, enhancement). 13.2b depends on LLM or Media Forge captioning and can be deferred to polish.

- **13.2a Free-text tag editing, search, and filters** ✅ Shipped `b89e031`.
  - LiveView work on the Assets tab added in 13.1c: each asset row exposes its current tag list as removable chips plus an "add tag" input with autocomplete sourced from `ProductAssets.list_distinct_tags/1` (already shipped in 13.1a). Adding a tag calls a new `ProductAssets.add_tag/2`; removing calls `ProductAssets.remove_tag/2`. Both operations broadcast `:asset_updated` over the existing PubSub topic so other subscribers stay in sync.
  - Search bar above the asset list: a free-text field that filters by case-insensitive substring match against both `tags` (using a new `:search` filter on `list_assets/2` that matches when any tag contains the substring) and `description`. A media-type dropdown filters by `image`, `video`, or all. Filters compose.
  - A "tag facet" row shows up to eight most-common tags for the current product as clickable pills that set the search field to that tag.
  - Backend changes in `ContentForge.ProductAssets`: `list_assets/2` gets a `:search` option that applies an ILIKE over description and a `ANY(tags) ILIKE` over the tags array; `add_tag/2` and `remove_tag/2` are transactional update helpers that preserve the unique-tag invariant per asset.
  - Tests: adding a tag shows up in the row and in autocomplete; removing a tag disappears; search by substring filters correctly; search combined with media_type narrows correctly; tag-facet click prefills the search and filters.

- **13.2b Inferred tag generation from images**
  - Post-processing step that runs after `AssetImageProcessor` marks an asset processed: a small LLM prompt (via the Anthropic client) receives the image's storage key, a one-line description request, and a cap on tag count. The response is a short list of tags normalized to lowercase-with-hyphens and merged into the asset's `tags` array. Duplicate tags are deduped by the existing invariant.
  - Vision is not yet wired on the Anthropic client, so this slice also adds an image-input path to `ContentForge.LLM.Anthropic.complete/2` (or ships a thin variant that accepts an image reference). If that turns out to expand scope too far, the slice reduces to EXIF/filename-based inferences only and the vision-based inference ships in its own follow-up.
  - Tests stub the LLM response; no live calls.

- **13.3 Asset bundles**
  - Group assets into named bundles (for example "Product launch 2026-05 hero set").
  - Bundles attach to drafts and provide media for the generation pipeline.
  - **Slicing note:** Schema + context in 13.3a; LiveView management in 13.3b. Draft-generation-from-bundle is 13.4.

- **13.3a AssetBundle schema and context** ✅ Shipped `641c50d`.
  - New schema `ContentForge.ProductAssets.AssetBundle` at `lib/content_forge/product_assets/asset_bundle.ex` with fields: `product_id` (binary_id fk, required), `name` (string, required, 1..120 chars), `context` (text, nullable — the free-form description of what the bundle represents, for example "Johnson family kitchen remodel, 3 weeks, quartz counters, custom cabinets"), `status` (string enum `"active" | "archived" | "deleted"`, default `"active"`), plus timestamps.
  - Join schema `ContentForge.ProductAssets.BundleAsset` joining `asset_bundles` to `product_assets` with composite uniqueness so an asset can appear in a bundle only once. The join carries `position` (integer) for a display order within the bundle.
  - Migration creates both tables: bundles table with binary_id PK, fk to products with `on_delete: :delete_all`; join table with fks to both sides with `on_delete: :delete_all`, composite unique index on `(bundle_id, asset_id)`, plus a plain index on `bundle_id` for fetch-by-bundle queries.
  - Extend the `ContentForge.ProductAssets` context with `create_bundle/1`, `get_bundle!/1` (preloads the assets in position order), `list_bundles/1` (by product, active by default), `update_bundle/2`, `archive_bundle/1`, `soft_delete_bundle/1`, `add_asset_to_bundle/3` (position defaults to next-in-sequence), `remove_asset_from_bundle/2`, `reorder_bundle_assets/2`.
  - PubSub broadcasts on bundle create, update, archive, delete, and on any membership change (so the LiveView in 13.3b can react).
  - Tests cover: full CRUD happy path, soft delete hides from default list, archived hides from default list, duplicate add_asset is a no-op (or returns the existing row), remove_asset cleans up, reorder applies, the product delete cascades both tables.

- **13.3b Bundle management in LiveView** ✅ Shipped `8323486`.
  - New "Bundles" section on the product detail page, rendered as its own tab alongside Assets. Shows active bundles with name, context snippet, asset count, and thumbnail mosaic (first four asset thumbnails).
  - Create-bundle form: name + optional context textarea. Submitting creates the bundle empty.
  - Bundle detail view (inline drawer or new page): shows the bundle's assets in position order, with remove and reorder controls, plus a multi-select picker that lists unattached assets from the product's library filtered by media_type. Assets are attached through `add_asset_to_bundle/3`.
  - Archive + soft-delete buttons on the bundle.
  - Mobile-first: the thumbnail mosaic collapses to single-column below a breakpoint; reorder uses explicit up/down buttons rather than drag-and-drop so phones work.
  - Tests: create a bundle, add and remove assets, archive, soft delete, and the tab renders when there are no bundles with the right empty state.

- **13.4 Draft generation from assets**
  - Generation entry point that accepts an asset bundle and emits draft copy keyed to the visual narrative of the bundle.
  - Model prompt includes asset captions / tags so copy and imagery align.
  - **Slicing note:** Three sub-slices — schema extension for draft↔asset many-to-many (13.4a), the generation worker (13.4b), and the LiveView trigger from the bundle drawer (13.4c).

- **13.4a Draft ↔ ProductAsset many-to-many association** ✅ Shipped `fe68e78`.
  - New join schema `ContentForge.ContentGeneration.DraftAsset` linking `drafts` to `product_assets` so a draft can reference one or more assets as its featured media and an asset can appear in multiple drafts. Join carries a `role` field (enum `"featured" | "gallery"`, default `"featured"`) so the publisher can pick the right one when only a single platform slot is available.
  - Migration creates the join table with binary_id PK, both fks `on_delete: :delete_all`, composite unique on `(draft_id, asset_id)`, plain indexes on each side for reverse lookups.
  - Extend `ContentForge.ContentGeneration.Draft` with `has_many :draft_assets` and `has_many :assets, through: :draft_assets` so existing preload sites work unchanged.
  - Extend `ContentForge.ContentGeneration` context with `attach_asset/3` (draft_id, asset_id, role), `detach_asset/2`, `list_assets_for_draft/1`, and include the assets in the default preload used by the LiveView queue.
  - Existing `draft.image_url` stays in place and continues to be authoritative for published output until 13.5 teaches the publisher to resolve a rendition from the attached assets. The two paths coexist: a draft generated before this slice still publishes via `image_url`; a draft generated from a bundle gets `image_url` populated from the featured asset's thumbnail (or primary storage key) as part of the 13.4b worker.
  - Tests cover: attach adds a row and dedupes on repeat, detach removes, cascade-on-draft-delete and cascade-on-asset-delete, the `through: :assets` preload loads in order, and `role` defaults correctly.

- **13.4b AssetBundleDraftGenerator worker** ✅ Shipped `2746f7f`.
  - New Oban worker `ContentForge.Jobs.AssetBundleDraftGenerator` under queue `:content_generation` that consumes a bundle id + a list of target platforms + a per-platform variant count. For each target platform, the worker builds a prompt using the bundle's context text, each asset's tags and description, and the bundle's visual narrative (ordered list of assets by position, with each asset's media type and thumbnail reference).
  - Calls `LLM.Anthropic.complete/2` (via the existing shipped client) with a structured JSON prompt asking for N variants per platform. JSON parsing follows the established pattern (direct decode, fenced-block fallback, reject malformed without fabricating).
  - For each returned variant, creates a Draft with status `"draft"`, the platform, content type `"post"` (or `"video_script"` for video-specific platforms), angle, generating_model set to the Anthropic model name, and a `bundle_id` reference recorded on the draft (new optional column added in this slice's migration). Then attaches the bundle's featured asset to the draft via `attach_asset/3` with role `"featured"`, and sets `image_url` from that asset's primary storage key or thumbnail so existing publisher paths keep working.
  - Error handling mirrors the brief generator: `:not_configured` logs "LLM unavailable for bundle drafts", returns a skipped result, creates no drafts. Transient errors retry via Oban. Permanent errors cancel the job.
  - Tests: happy-path generation for two platforms produces the right number of drafts with assets attached and image_url populated from the featured asset; `:not_configured` skip creates no drafts; malformed JSON response rejects without fabricating; transient retries; permanent cancels.

- **13.4c LiveView "Generate drafts" trigger from bundle drawer** ✅ Shipped `fde2561`.

- **13.4d Banner stickiness hardening (small)** ✅ Shipped `8f02110`.
  - If `LLM.Anthropic.complete/2` (or any upstream) raises instead of returning `{:error, _}`, the generator worker's broadcast path never fires and the LiveView banner sticks forever on that bundle. `classify/1` covers every known error tuple shape so this is rare in practice, but a raise is a valid outcome that the broadcast contract currently does not survive.
  - Wrap the completion path in a `try/after` (or equivalent) so the `:finished` broadcast always fires on exit, regardless of whether the call returned or raised. Keep the error reporting path unchanged for the non-raise cases.
  - One regression test that forces a raise inside a stubbed Anthropic client and asserts the banner clears for that bundle id.
  - In the bundle detail drawer shipped under 13.3b, add a "Generate drafts" form that lets the user select target platforms (multi-checkbox over the product's enabled publishing targets) and a per-platform variant count (default 3). Submitting enqueues `AssetBundleDraftGenerator.new/1` with the bundle id, selected platforms, and count.
  - After enqueueing, the drawer shows a "drafts generating..." banner until the job completes; completion is surfaced via PubSub on the existing `content_forge:drafts:<product_id>` topic (new topic if it does not exist yet), and the drafts queue view updates in real time.
  - Tests: submitting the form enqueues the job with the right args; the banner appears and clears; a draft created by the worker links back to its bundle via the new bundle_id column.

- **13.5 Asset renditions on publish**
  - At publish time, Content Forge requests platform-specific renditions from Media Forge (Instagram 1:1, TikTok 9:16, etc.) and attaches the rendition to the platform post.
  - **Must-fix carryover from 13.4b:** Bundle-generated drafts currently have `image_url` set to the featured asset's internal R2 storage key (not a real URL). The manual `"draft"→"approved"` workflow gates this today, but 13.5 must teach the publisher to resolve the correct URL at publish time from the attached `draft_assets` instead of reading `image_url` blindly. Resolution order: prefer a platform-specific rendition from Media Forge for the attached asset; fall back to the asset's primary storage key converted to a signed or public URL; finally fall back to the legacy `draft.image_url` for pre-13.4 drafts.
  - **Slicing note:** Split into rendition resolver (13.5a) and publisher swap (13.5b).

- **13.5a AssetRenditionResolver module** ✅ Shipped `1ae7b53`.
  - New named module `ContentForge.ProductAssets.RenditionResolver` (single file under `lib/content_forge/product_assets/`) that given `(product_asset, platform)` returns `{:ok, public_or_signed_url}` or a classified error. Dispatches to MediaForge for rendition generation when no cached rendition exists, persists the generated rendition's storage key on a new `asset_renditions` table (keyed by `(asset_id, platform)`), and returns the resolved URL.
  - Platform rendition spec map at `config :content_forge, :renditions` with entries like `%{"twitter" => %{aspect: "16:9", width: 1200, format: "jpg"}, "instagram" => %{aspect: "1:1", width: 1080, format: "jpg"}, "reels" => %{aspect: "9:16", width: 1080, format: "jpg"}, ...}`. Unknown platforms fall back to the asset's primary storage key with no rendition.
  - For images the module calls `MediaForge.enqueue_image_render/1` with the source storage key and the target rendition spec, polls until done, records the output storage key on `asset_renditions`, and returns the public URL.
  - For videos (in preparation for future TikTok/Reels/Shorts paths; not used by the initial image-only publisher swap) the module calls `MediaForge.enqueue_video_batch/1` similarly. 13.5b's publisher swap ships image-only; video rendition is wired but not yet exercised.
  - New migration creates `asset_renditions` with `asset_id` fk, `platform` string, `storage_key`, `width`, `height`, `format`, `generated_at`, composite unique on `(asset_id, platform)` and partial unique on `storage_key` to prevent collisions on rendition retries.
  - `:not_configured` passes through from MediaForge and becomes `{:error, :not_configured}` at the resolver's surface. Transient errors propagate for Oban retry. Permanent errors return `{:error, {:permanent, reason}}` so callers can mark drafts blocked.
  - Tests: happy path creates the rendition and returns the URL; second call for the same (asset, platform) hits the cache and does not call MediaForge; `:not_configured` passes through without a rendition row; unknown platform returns the asset's primary URL; transient error propagates; permanent error surfaces clearly.

- **13.5b Publisher resolution swap** ✅ Shipped `f0da860`.
  - Change `ContentForge.Jobs.Publisher.build_post_opts/3` to prefer the `RenditionResolver` path for any draft that has attached `draft_assets`. For each attached asset, resolve the URL via `RenditionResolver.resolve/2` with the draft's platform; choose the featured asset for the primary `image_url` opt and include any gallery assets where the platform supports carousels.
  - Legacy drafts (no attached assets, only `draft.image_url`) continue to publish with that URL unchanged.
  - On `{:error, :not_configured}` from the resolver, reuse the existing missing-image blocker from 10.2b: mark the draft blocked with a note `"rendition unavailable: media forge not configured"`, do not call the platform client. The dashboard's blocked-filter tab already surfaces this via the shared blocked label.
  - On `{:error, {:permanent, _}}`, mark the draft blocked with a note including the permanent reason.
  - On transient errors, return a retryable error from the Publisher worker so Oban retries.
  - Tests: bundle-generated draft with a featured asset publishes with the resolver-sourced URL; legacy draft with `image_url` only publishes unchanged; `:not_configured` from resolver marks the draft blocked; permanent error from resolver marks the draft blocked; transient error triggers Oban retry.

Phase exit criteria: a marketer can upload a product photo, tag it, drop it in a bundle, generate a draft around it, and publish per-platform renditions without touching any external tool.

## Phase 14 — Feature 12: SMS Gateway and Conversational Bot

Per `CONTENT_FORGE_SPEC.md` Feature 12. Twilio + OpenClaw integration.

- **14.1 Twilio inbound webhook**
  - Signed webhook receiver for SMS. Parses message, identifies contact, routes to a conversation session.
  - Validates Twilio signature. Unknown numbers optionally get a gated response.
  - **Slicing note:** Schema foundation (14.1a) first, then the webhook receiver (14.1b), mirroring the 10.5 webhook pattern.

- **14.1a SMS schemas and context (ProductPhone, SmsEvent, ConversationSession)** ✅ Shipped `9723086`.
  - New schema `ContentForge.Sms.ProductPhone` at `lib/content_forge/sms/product_phone.ex` with fields: `product_id` (fk), `phone_number` (E.164 string, required, unique per product), `role` (enum `"owner" | "submitter" | "viewer"`), `display_label` (string), `active` (boolean default true), `opt_in_at` (utc_datetime_usec, nullable — nil until confirmation), `opt_in_source` (string, nullable — such as `"verbal"`, `"form"`, `"reply_yes"`), plus timestamps.
  - New schema `ContentForge.Sms.SmsEvent` at `lib/content_forge/sms/sms_event.ex` with fields: `product_id` (fk nullable — inbound from unknown numbers has no product), `phone_number` (E.164 string, required), `direction` (enum `"inbound" | "outbound"`), `body` (text), `media_urls` ({:array, :string}), `status` (enum `"received" | "sent" | "delivered" | "failed" | "rejected_unknown_number" | "rejected_rate_limit"`), `twilio_sid` (string, nullable), plus timestamps.
  - New schema `ContentForge.Sms.ConversationSession` at `lib/content_forge/sms/conversation_session.ex` with fields: `product_id` (fk), `phone_number` (E.164 string), `state` (enum `"idle" | "waiting_for_upload" | "waiting_for_context" | "status_query"`), `last_message_at` (utc_datetime_usec), `inactive_after_seconds` (integer, default 3600), plus timestamps. Unique on `(product_id, phone_number)`.
  - Migration creates all three tables with binary_id PKs and appropriate FK cascade semantics (phones cascade on product delete, events nilify on product delete so audit history survives, sessions cascade on product delete).
  - New context module `ContentForge.Sms` at `lib/content_forge/sms.ex` with: `lookup_phone/2` (by phone + product, returns nil if not whitelisted), `list_phones_for_product/2` (with active filter), `create_phone/1`, `update_phone/2`, `deactivate_phone/1`, `record_event/1` (inserts an SmsEvent row), `list_events/2` (with filters on product_id, phone_number, direction, status), `get_or_start_session/2` (idempotent lookup by phone+product; creates if missing; refreshes last_message_at), `set_session_state/2`, `expire_stale_sessions/1` (marks sessions past their inactive window).
  - Tests cover: CRUD on all three schemas; `lookup_phone` returns nil for unknown numbers; `record_event` persists inbound and outbound shapes; `get_or_start_session` creates once, reuses on second call, refreshes timestamps; cascade semantics on product delete.

- **14.1b Twilio inbound webhook receiver** ✅ Shipped `53602d0`.
  - New controller `ContentForgeWeb.TwilioWebhookController` at `lib/content_forge_web/controllers/twilio_webhook_controller.ex` with action `receive/2` mounted at `POST /webhooks/twilio/sms` outside the `/api/v1` pipeline. No bearer-token auth; instead a dedicated Twilio signature plug.
  - New plug `ContentForgeWeb.Plugs.TwilioSignatureVerifier` at `lib/content_forge_web/plugs/twilio_signature_verifier.ex`. Reads `x-twilio-signature` header, reconstructs the expected signature (HMAC-SHA1 of the full request URL plus sorted POST param concatenation, keyed by Twilio auth token, base64-encoded), compares via `Plug.Crypto.secure_compare/2`. Mismatch returns 403; missing header returns 400. Twilio auth token sourced from `:content_forge, :twilio, :auth_token` with env-var runtime wiring; if unset the plug rejects every request (fail closed).
  - The body-reader plug from the Media Forge webhook (10.5) is reused so raw body capture is available for any future signing variants; for Twilio the signature is over sorted form params, not raw body, so the shared reader does not interfere.
  - On valid signature, the controller:
    1. Extracts `From` (E.164 phone), `Body`, `NumMedia`, `MediaUrl0..N` from the form params.
    2. Looks up the phone in `ProductPhone`. Unknown phone: records an `SmsEvent` with status `"rejected_unknown_number"` and returns a TwiML `<Message>` body asking the sender to contact the agency to get set up.
    3. Known phone + active: calls `Sms.record_event/1` with direction `"inbound"`, status `"received"`, body, media URLs. Calls `Sms.get_or_start_session/2`. Returns an empty TwiML response (200) so Twilio does not auto-reply.
    4. Known phone + inactive: records `SmsEvent` with status `"rejected_unknown_number"` (same rejection path; distinguished only in the audit log). Returns a polite-rejection TwiML.
  - Routing downstream (to OpenClaw when it lands; to an auto-acknowledgement in the meantime) is out of scope for 14.1b and lands under 14.2.
  - Tests: valid signed inbound from a whitelisted phone records the event and starts a session; valid signed inbound from an unknown phone records a rejection event and returns a gated TwiML; invalid signature returns 403; missing auth-token config returns 403 on every request (fail closed); malformed form params return 400 without recording an event.

- **14.2 Conversation sessions**
  - Session schema that holds conversation state across messages.
  - OpenClaw reply generation with session context.
  - Outbound send via Twilio with retry on transient failure.
  - **Slicing note:** Session schema already shipped under 14.1a. Split remaining work into Twilio outbound client (14.2a) and the auto-reply orchestrator with OpenClaw gating (14.2b). OpenClaw is currently unavailable (see 11.2 caller decision), so 14.2b ships with a graceful-unavailable path so inbound messages get a polite auto-reply today and real replies when OpenClaw comes online.

- **14.2a Twilio outbound client module** ✅ Shipped `52ec927`.
  - Ship a named client at `ContentForge.Twilio` under `lib/content_forge/twilio.ex` that wraps Twilio's Messages API (`POST /2010-04-01/Accounts/{AccountSid}/Messages.json`). Public function `send_sms(to, body, opts)` returns `{:ok, %{sid, status}}` or a classified error tuple.
  - Config namespace at `:content_forge, :twilio` with `:account_sid`, `:auth_token`, `:from_number`, `:default_messaging_service_sid` (optional — preferred over `from_number` when set). Runtime wiring sources all four from env vars. Missing any required field returns `{:error, :not_configured}` with zero HTTP.
  - Auth is HTTP Basic with the account SID as username and the auth token as password. The client attaches this inside its Req pipeline, never at the call site.
  - Error classification matches the established pattern: 5xx + 429 transient; 4xx permanent; timeout + connection refusal transient-network; 3xx unexpected-status; catch-all pass-through.
  - Media: `send_sms/3` accepts a `:media_urls` opt; when present, appends `MediaUrl` params so Twilio delivers MMS. The client is the only code that touches Twilio's URL-encoded form body shape.
  - `Req.Test` stubbed from day one; tests cover happy-path SMS send, happy-path MMS with media_urls, 429 transient, 500 transient, 400 permanent, missing-config no-HTTP downgrade.

- **14.2b Auto-reply orchestrator with OpenClaw gating** ✅ Shipped `ecfdc12`.
  - After the inbound webhook records an `SmsEvent` for a whitelisted phone, enqueue `ContentForge.Jobs.SmsReplyDispatcher` (new Oban worker in queue `:default`, max_attempts 3) with the inbound event id.
  - The worker loads the event, its associated `ConversationSession`, and checks whether OpenClaw is configured via `Application.get_env(:content_forge, :open_claw, :base_url)` (already shipped in 11.2 infra). Two branches:
    - OpenClaw unavailable: send a fallback reply via `Twilio.send_sms/3` with a fixed message ("Thanks — your assistant is temporarily unavailable. We will get back to you shortly.") The worker records the outbound `SmsEvent` and exits `{:ok, :unavailable_fallback}`. The fallback text is configurable per product under `publishing_targets[\"sms\"][\"unavailable_fallback\"]` with the above as default.
    - OpenClaw configured: for this slice, still send the unavailable fallback — the real OpenClaw reply-generation call is deferred to 14.2c once OpenClaw's conversational endpoint is confirmed. The branch is wired but shipping fallback text means no synthetic reply enters production regardless of config state.
  - Session state advances to `"idle"` after each outbound; if the session was already `"waiting_for_upload"` or `"waiting_for_context"`, state stays.
  - Rate limiting: at most 10 outbound SMS per phone per calendar day. Exceeding the cap records a `rejected_rate_limit` event and does not call Twilio. Cap configurable per product.
  - Tests: whitelisted inbound triggers a dispatcher job, dispatcher sends the fallback via a stubbed Twilio client, outbound event is recorded, session state updates, rate-limit cap short-circuits at the 11th send in a day, missing-config Twilio (`:not_configured` from the client) records the outbound event with status `"failed"` and a reason note, does not crash the worker.

- **14.3 Upload flow via SMS** ✅ Shipped `7d3aadf`.
  - Contact can MMS a photo; Content Forge routes the media through Media Forge (EXIF, rendition) and attaches the asset to the related product or draft.
  - Additional requirements surfaced during 14.1/14.2:
    - Inbound MMS media URLs are already captured on `SmsEvent.media_urls` by 14.1b. This slice fills in the ingestion path: download each media URL from Twilio, upload to R2, create a `ProductAsset` record, and enqueue the matching `AssetImageProcessor` or `AssetVideoProcessor` (13.1d/13.1e) so the asset goes through the same Media Forge processing pipeline as a dashboard upload.
    - Extend `ContentForge.Twilio` with `download_media/1` that performs a GET on the Twilio media URL with the same HTTP Basic auth the outbound sender uses, follows Twilio's 307 redirect to the signed S3-backed download, and returns `{:ok, %{content_type, binary}}` or a classified error. Do not cache the download in memory longer than necessary; stream to a tempfile if the body exceeds a configurable cap (default 100MB).
    - New Oban worker `ContentForge.Jobs.SmsMediaIngestor` (queue `:content_generation`, max_attempts 3) that takes an `SmsEvent` id, loads the event, enforces that direction is inbound and product_id is set, iterates each media URL, calls `Twilio.download_media/1`, rejects unsupported MIME types with an audit row (status `"unsupported_media"`), otherwise uploads the bytes to R2 under `products/<product_id>/assets/<uuid>/sms_<event_id>_<index>.<ext>` and creates the `ProductAsset` with `uploader` set to the sender's phone number. The worker then enqueues `AssetImageProcessor` or `AssetVideoProcessor` per media_type, just like the dashboard-upload register endpoint does.
    - The webhook controller at 14.1b enqueues this ingestor when an inbound event has non-empty media URLs. No synchronous download happens in the webhook request; Twilio gets its TwiML response in milliseconds regardless of media size.
    - Error handling: Twilio `:not_configured` on download logs and records a failed-ingestion audit row, then returns `{:ok, :skipped}` so Oban does not retry a permanently broken configuration. Transient download errors propagate for retry. Permanent download errors (4xx from Twilio, for example a deleted message) record a failed-ingestion audit and cancel.
    - Tests: happy-path inbound MMS with a JPEG ends up as a processed ProductAsset with the image processor enqueued; MMS with a disallowed MIME records the audit row and skips; download failure retries transiently then cancels permanently; Twilio `:not_configured` returns skipped without creating assets.

- **14.4 Reminders**
  - Scheduled outbound reminders (content review deadlines, publish approvals).
  - Oban-driven, idempotent, respects quiet hours.
  - **Slicing note:** Reminder configuration schema + STOP opt-out handling (14.4a) first, then the cron scheduler + dispatcher worker (14.4b). OpenClaw gating follows the 14.2b pattern: fallback reminder text today, real AI-crafted text when OpenClaw's conversational endpoint lands.

- **14.4a ReminderConfig schema + STOP opt-out** ✅ Shipped `9e7ebf4`.
  - New schema `ContentForge.Sms.ReminderConfig` at `lib/content_forge/sms/reminder_config.ex` with fields: `product_id` (fk, unique), `enabled` (boolean default true), `cadence_days` (integer default 7 — how often a quiet client gets a reminder), `quiet_hours_start` (integer 0-23 default 20 — no outbound after this local hour), `quiet_hours_end` (integer 0-23 default 8 — no outbound before this local hour), `timezone` (string default "UTC"), `backoff_after_ignored` (integer default 2 — how many unanswered reminders before tone shifts), `stop_after_ignored` (integer default 4 — stop sending after this many total unanswered), plus timestamps.
  - Migration creates `sms_reminder_configs` with binary_id PK, fk to products with `on_delete: :delete_all`, unique index on `product_id`.
  - Extend `ContentForge.Sms.ProductPhone` with a new `reminders_paused_until` field (utc_datetime_usec, nullable). Any outbound send skips phones where `reminders_paused_until` is in the future.
  - Context: `ContentForge.Sms.get_reminder_config/1` (returns default struct if absent), `upsert_reminder_config/2`, `pause_phone_reminders/2` (sets `reminders_paused_until` to `now + pause_days * 86_400` seconds), `resume_phone_reminders/1` (sets nil).
  - STOP handling in the webhook controller 14.1b: before dispatching the normal auto-reply, check if the inbound body is `"STOP"` (or configurable aliases `"STOPALL"`, `"UNSUBSCRIBE"`, `"CANCEL"`, `"END"`, `"QUIT"`) case-insensitive after trim. On match: call `pause_phone_reminders(phone, default_pause_days)` (default 7 days), record an `SmsEvent` with status `"stop_received"`, and return a TwiML acknowledging opt-out ("You've been unsubscribed from reminders for 7 days. Reply START anytime to resume earlier."). Do not enqueue the normal auto-reply on STOP.
  - Symmetric START handling: inbound body `"START"` or `"UNSTOP"` calls `resume_phone_reminders/1`, records `"start_received"`, returns a TwiML confirmation. Normal auto-reply still runs afterward so the conversation continues naturally.
  - Tests cover: default config returned when absent; upsert round-trips; pause computes the timestamp correctly; resume clears it; STOP aliases case-insensitive; START resumes and continues; STOP from unknown phone still takes the generic rejection path (does not leak existence).

- **14.4b ReminderScheduler cron + ReminderDispatcher worker** ✅ Shipped `2fdea38`.
  - New cron-like Oban worker `ContentForge.Jobs.ReminderScheduler` at queue `:default`, scheduled hourly (either via Oban.Plugins.Cron or by its own self-rescheduling pattern — the coder picks whichever is consistent with the project). Each run iterates every product with an active `ReminderConfig`, loads the most recent inbound `SmsEvent` per whitelisted active phone for the product, and for each phone where `now - last_inbound >= cadence_days` AND `reminders_paused_until` is nil-or-past AND the current hour in the product's timezone is within the quiet window, enqueues a `ReminderDispatcher` for that phone.
  - New worker `ContentForge.Jobs.ReminderDispatcher` at queue `:default`, max_attempts 3. Takes a phone id + product id. Composes the reminder text:
    - Count recent unanswered outbound reminders since last inbound. If the count exceeds `backoff_after_ignored`, use a gentler tone template ("checking in, everything okay?"). If it exceeds `stop_after_ignored`, skip the send entirely and fire a dashboard notification that the client has gone dormant.
    - OpenClaw is gated the same way as 14.2b: if configured the branch is wired but still uses the fallback template until 14.2c lands real OpenClaw reply-generation. If unconfigured, use the fallback template directly.
    - Send via `ContentForge.Twilio.send_sms/3`, record an `SmsEvent` with status `"sent"` on success.
  - Idempotency: each dispatcher job is enqueued with Oban `unique:` over `[:args, :worker]` for a one-hour window so a scheduler re-run does not double-fire.
  - Tests cover: scheduler enqueues a dispatcher for a product with a stale last-inbound and no pause; scheduler skips when cadence not reached; scheduler skips when paused; scheduler skips outside quiet hours; dispatcher composes the friendly template by default and the gentler template after backoff; dispatcher fires the dashboard-dormant notification after stop threshold and does not send; idempotency prevents double-enqueue.

- **14.5 Escalation** ✅ Shipped `0fe31dc`.
  - If OpenClaw cannot confidently answer within a session, escalate to a human operator by creating a dashboard notification and pausing autoresponse.
  - Additional requirements surfaced during 14.2/14.4:
    - Extend `ConversationSession` with `escalated_at` (utc_datetime_usec, nullable), `escalation_reason` (text, nullable), and `auto_response_paused` (boolean default false). When a session is escalated, `SmsReplyDispatcher` short-circuits to a single holding-message outbound ("Thanks — a human from our team will follow up shortly.") and then no further auto-replies fire until the session is resolved.
    - `ContentForge.Sms.escalate_session/3` takes a session, a reason string, and options (`notify_channels:` list); marks the session escalated, pauses auto-response, records an `SmsEvent` with status `"escalated"`, and fires any configured notification channels (dashboard for this slice; Slack/email gated behind future wiring). `resolve_session/1` clears the escalation flags so auto-response resumes.
    - New LiveView page at `/dashboard/sms` (`SmsLive.NeedsAttention`) lists all currently escalated sessions across all products with: product name, phone number (display label from the ProductPhone), last inbound body snippet, escalation reason, and escalated-at timestamp. Each row has a "mark resolved" button that calls `resolve_session/1` and flashes success. Sessions with high inbound volume (above a configurable per-session threshold, default 10 messages in 24h with no outbound reply) appear on the same page under a "high-volume" section even if not yet escalated — this is the "needs reply" queue from the spec.
    - Router: new authenticated route `/dashboard/sms` inside the existing dashboard scope so admins land on it from the main nav. Add a "SMS" card to the dashboard hub.
    - Tests: escalate_session records the event, pauses auto-response, and a subsequent dispatcher enqueue is a no-op (holding message only sent once); resolve_session flips back; the LiveView renders escalated sessions and the high-volume queue; marking resolved removes the row from the list.

Phase exit criteria: a marketer can text a photo in, get it tagged into a product library, receive a scheduled review-deadline reminder, and escalate to a human when the bot is uncertain.

## Phase 15 — Polish

Pick up after the feature waves clear. Any of these can be inserted earlier if it starts actively blocking sales demos.

- **15.1 Dashboard UX pass**
  - Script-gate threshold view on the video page.
  - Calendar / timeline visualization on the schedule page.
  - Provider status panel (per Phase 11 exit).
  - **Slicing note:** Three independent sub-slices; start with provider status panel (15.1a) since multiple earlier phases reference "unavailable" surfaces that need a centralized display.

- **15.1a Provider status panel** ✅ Shipped `3c2b0e1`.
  - New LiveView page at `/dashboard/providers` (`ProvidersLive`) plus a hub card. Shows, for every external service the app integrates, whether it is configured and currently reachable:
    - Media Forge (client 10.1): config present (secret + base_url), last successful call timestamp from recent `ImageGenerator` or `AssetImageProcessor` events, last error (if any) from the past hour.
    - LLM Anthropic (11.1 infra): config present (api_key), recent successful completion timestamp, last error.
    - LLM Gemini (11.1b infra): same.
    - OpenClaw (11.2 infra): config present (base_url + token), last successful call timestamp.
    - Apify scraper (11.3a): config present (token), last successful scrape timestamp.
    - Twilio (14.2a): config present (account_sid + auth_token + sender), last successful send timestamp from recent outbound SmsEvents.
  - Each provider row has three states surfaced with the existing `status_badge` component: `Available` (configured + recent success), `Configured` (credentials present, no recent traffic), `Unavailable` (credentials missing). A fourth amber `Degraded` state fires when a provider has had more than 3 transient errors in the last 15 minutes.
  - The page reads directly from application config for the credentials check (no live probe on page load) and from the event/audit tables for recent-activity timestamps. It never issues a synthetic call to the upstream.
  - Tests: each state renders the correct badge; missing credentials show `Unavailable`; credentials present with no traffic show `Configured`; credentials present with a successful event in the last hour show `Available`; three transient errors in the window flip to `Degraded`.
  - The hub card summarizes: count of `Unavailable` + `Degraded` providers; links to the full panel. When all are `Available` or `Configured`, the card shows a compact green state.

- **15.1b Script-gate threshold view on video page** ✅ Shipped `416eb1a`.
  - Add a view on the existing video status page that shows each candidate script's composite score alongside the current gate threshold, with a clear Promote/Override control. A script with score below threshold can still be manually promoted, with the override recorded on the `VideoJob` and surfaced in the status board.

- **15.1c Schedule calendar visualization** ✅ Shipped `514f8c6`.
  - Add a week-view calendar on the schedule page showing upcoming publishes by day + platform. Each cell shows the platform icon + draft snippet; clicking opens the draft preview. Mobile view collapses to a stacked daily list.

- **15.2 WCAG AA audit**
  - Full pass over every LiveView page: contrast, keyboard focus order, ARIA labels, screen-reader verification.
  - Fix findings in small slices, one page at a time.
  - **Slicing note:** One sub-slice per LiveView page. Start with the dashboard entry surfaces (hub + products list + product detail) since those carry the most traffic.

- **15.2a Dashboard hub + products list + product detail accessibility audit** ✅ Shipped `e46928c`.
  - Audit three pages: `/dashboard` (`DashboardLive`), `/dashboard/products` (`Products.ListLive`), `/dashboard/products/:id` (`Products.DetailLive`).
  - For each: check color contrast (all text + icon pairs meet WCAG AA 4.5:1 for normal text, 3:1 for large), keyboard focus order is logical and every interactive element is reachable via Tab, visible focus indicator on every button/link/input, semantic landmarks (`<header>`, `<nav>`, `<main>`, `<footer>` or equivalent `role=` attributes), heading hierarchy (single `<h1>` per page, no skipped levels), ARIA labels on icon-only buttons, form inputs have associated `<label>` elements, interactive custom components use proper `role=button` with `tabindex=0` + Enter/Space handlers if not real buttons.
  - Fix findings inline in the same slice. Add focus-visible styles where missing, rename non-descriptive button text, add aria-labels to icon buttons, rework color pairs that fail contrast.
  - Tests: a per-page assertion that ensures each page contains the required landmarks and a single h1; optionally run an existing a11y-checker library against the rendered HTML if one is already in the project, otherwise the structural assertions are the regression gate. No screen-reader automation — manual verification is documented in the handoff notes.
  - Explicit scope boundary: drafts review, schedule, video status, performance, clips, providers, and SMS pages are NOT touched in this slice. Each gets its own follow-up 15.2b/c/d/e/f/g/h.

- **15.2b Drafts review + schedule accessibility audit** ✅ Shipped `2a744cf`.
  - Same audit checklist as 15.2a applied to `/dashboard/drafts` (`Drafts.ReviewLive`) and `/dashboard/schedule` (`Schedule.Live` — includes the calendar from 15.1c).
  - Drafts review is form-heavy (approve/reject/tag/filter controls); pay extra attention to filter tabs' `role=tablist` + `tabindex` management and to the inline tag chip/remove buttons.
  - Schedule includes the week calendar from 15.1c — that page was already landed with `role=grid` + drawer dialog semantics, so this slice mostly audits the surrounding nav + the per-post rows.
  - Tests add landmark + single-h1 assertions to both pages, matching the pattern established in 15.2a.

- **15.2c Video + performance + clips accessibility audit** ✅ Shipped `d31e6f6`.
  - Same checklist applied to `/dashboard/video` (`Video.StatusLive`), `/dashboard/performance` (`Performance.DashboardLive`), and `/dashboard/clips` (`Clips.QueueLive`).
  - Video page's override/promote controls from 15.1b are specifically checked (button labels, confirm semantics). Performance metrics tables and charts need table headers and chart alt-text equivalents. Clips queue action buttons need aria-labels since they are per-row.

- **15.2d Providers + SMS accessibility audit** ✅ Shipped `ff29e63`.
  - Final page pair: `/dashboard/providers` (`ProvidersLive` from 15.1a) and `/dashboard/sms` (`SmsLive.NeedsAttention` from 14.5). Both are table-heavy list views; same checklist with emphasis on table semantics (`<th scope="col">`) and row-action button labels.
  - **Additionally: arrow-key roving tabindex JS hook across all tablist widgets.** 15.2b and 15.2c both documented this deferral explicitly — the static `tabindex` state is correct (keyboard Tab works), but Left/Right arrow navigation between tabs in a tablist requires a small JS hook. Ship a single reusable Phoenix LiveView JS hook (`Hooks.TabList` or similar) that listens for Left/Right/Home/End on any element under `role=tablist`, moves focus to the appropriate sibling, and fires the existing `phx-click` semantics on Enter/Space so selection remains in-sync with focus. Apply the hook across every `role=tablist` in the dashboard (drafts filter tabs, product detail tab bar, any newly-added ones). Include a test that simulates arrow-key navigation and asserts focus + selection updates.

- **15.3 End-to-end integration tests**
  - At least one multi-step pipeline test per feature: product registered → brief generated → variants ranked → published → metrics collected → winner repurposed.
  - Against stubbed externals; live smoke is a separate manual runbook.
  - **Slicing note:** One end-to-end happy-path test first (15.3.1) to prove the pipeline hangs together with shared stub helpers; follow-ups add edge-case paths (15.3.2+) if gaps appear during the happy-path run. Coverage uplift (15.3a) is a separate slice that trails 15.3.

- **15.3.1 End-to-end happy-path: product → brief → variants → rank → publish → metrics → repurpose** ✅ Shipped `41e0fb5`.
  - Single integration test that walks the whole spine: create a product with a voice profile, stub `LLM.Anthropic` + `LLM.Gemini` to return deterministic brief and variant content, stub `MultiModelRanker`'s per-model stub to return scores that make one draft clearly best, stub the platform publisher clients (Twitter + LinkedIn) to accept, stub `MetricsPoller`'s platform calls to report engagement that labels the draft a winner, and assert that `WinnerRepurposingEngine` eventually enqueues cross-platform repurposed drafts from the original winner.
  - Shared test helpers at `test/support/e2e_stubs.ex` set up `Req.Test` stubs for every external client the pipeline touches in one call. Individual tests opt into which stubs they need. No live HTTP anywhere in the suite.
  - Test runs through `Oban.Testing.perform_job/2` calls for each worker in order (`ContentBriefGenerator`, `OpenClawBulkGenerator` is skipped since it's blocked — the test hand-creates drafts or uses `AssetBundleDraftGenerator` instead, `MultiModelRanker`, `Publisher`, `MetricsPoller`, `WinnerRepurposingEngine`) rather than relying on Oban's actual dispatcher, so the test is deterministic without sleeps.
  - Assertions: at each stage the draft has the expected status (`draft → ranked → approved → published → winner`), the right records exist (`ContentBrief`, `DraftScore` rows per model, `PublishedPost`, `ScoreboardEntry`, repurposed `Draft` rows), and no synthetic data leaked to the DB on any step.
  - Test does NOT exercise OpenClaw bulk generation, real Media Forge calls, or SMS — those are separate E2E slices if/when their externals are available.

- **15.3a Coverage uplift and threshold tightening** ✅ Shipped `915835c`.
  - Baseline is `test_coverage: [summary: [threshold: 0]]` in `mix.exs` (acknowledged debt, overall ~18%). Pair with 15.3 work: as E2E tests land, raise the per-module threshold in tranches (start at 25, then 50, then back toward Elixir's default of 90).
  - A dedicated cleanup slice at the end of the wave should set the final threshold and update `BUILDLOG.md` with the final coverage number.
  - **Refined scope (post-15.3.1 + 15.4):** Overall coverage climbed from 18% to 55.7% with the tests added during Phases 11–15. Raising the per-module threshold above 0 immediately would fail the gate on a long tail of 0%-coverage modules (legacy scaffolding, error views, telemetry supervisors) that do not need tests. This slice does the triage:
    - Grep-and-inventory every module reported at 0% in `mix test --cover`.
    - For each: decide `exclude` (truly unreachable: error views, application/supervisor boilerplate, dev-only modules), `add-smoke` (one or two sanity tests bring it above 10%), or `defer` (worth covering later but not now).
    - Configure `test_coverage: [summary: [threshold: 10], ignore_modules: [...]]` with the excluded list and a modest threshold that catches genuine regressions without failing on incidental low-coverage modules.
    - Document in `BUILDLOG.md` the final overall coverage number, the threshold, and the ignore list with a one-line justification per module so future maintainers can challenge or raise the bar.
    - Further tranches (toward 50 and 90) are separate follow-ups; this slice sets the initial floor.

- **15.4 Load smoke** ✅ Shipped `8448b08`.

- **15.4.1 ScheduleController Oban.insert map-shape fix** ✅ Shipped `5ef58af`.

- **15.4.2 Oban.insert bare-map audit sweep** ✅ Shipped `a7e9bf7`.

- **15.4.3 ScriptGate return shape + Draft archived status** ✅ Shipped `274ff9c`.
  - Two small orthogonal issues surfaced during the 15.4.2 sweep.
    - `ContentForge.Jobs.ScriptGate.perform/1` returns a bare `%{approved: ..., archived: ...}` map. Oban's worker contract expects `:ok`, `{:ok, term}`, `{:error, term}`, `:discard`, `{:cancel, term}`, or `{:snooze, seconds}`. A bare map is neither ok nor error, and Oban's handling of unexpected returns has changed across versions — the current Oban version treats non-conforming returns as success but logs a warning. Fix: wrap the existing map in `{:ok, map}`.
    - `ContentForge.ContentGeneration.Draft` status inclusion list is `~w(draft ranked approved rejected published blocked)`. ScriptGate's archive path tries to transition a draft to `"archived"` but the cast fails silently and the draft stays at its prior status. Add `"archived"` to the inclusion list; extend the shared `status_badge` component with a neutral badge for archived; backfill existing dashboards so the archived filter works.
  - Tests: ScriptGate happy path asserts `{:ok, %{approved:, archived:}}` return; archive path asserts the draft's status genuinely becomes `"archived"` post-transition; dashboard renders the archived badge.
  - Reviewer flagged that `ScheduleController.publish_draft` and `publish_draft.publish_now` still call `Oban.insert` with a bare map. These are the same class of bug as 15.3.1 and 15.4.1: `Oban.insert/1` requires an `%Oban.Job{}` struct, not a map. Any code path reaching these endpoints errors instead of enqueuing.
  - Scope of this slice: grep the repo for `Oban.insert(%{` and `Oban.insert(%Oban.Job{`; any bare-map instance is converted to `Worker.new(args) |> Oban.insert()`. Each converted site gets a focused test that asserts `assert_enqueued` on the correct worker.
  - If the sweep finds more than three instances, ship the fixes with their tests in one commit but keep the test file well-organized per-worker so future greps land on the right ownership.
  - `ContentForgeWeb.ScheduleController.schedule_for_platform/2` calls `Oban.insert(%{...})` with a plain map — same broken shape that the 15.3.1 E2E walk surfaced in `WinnerRepurposingEngine`. `Oban.insert/1` accepts only `%Oban.Job{}` structs (or a changeset). Anything that reaches this code path in production errors rather than enqueues.
  - Fix follows the established pattern: replace the bare-map call with `Publisher.new(args) |> Oban.insert()` (or whichever worker this path is meant to enqueue — inspect the map args and pick the right worker module).
  - Add a focused test that hits the schedule endpoint with a valid product + platform and asserts the correct Oban job is enqueued (via `assert_enqueued`). That's the test that would have caught this bug; it's also the test that locks in the fix.
  - Same-class-of-bug slice; keep it to one focused commit.
  - Small load test against the Review API and the publishing endpoints to catch N+1s and session-handling issues before they bite in a real launch.
  - **Slicing note:** Ship as a single slice. Concrete requirements:
    - A new `mix task` or top-level script under `test/load/review_api_smoke.exs` that uses `Task.async_stream/3` and `Finch` (no new deps if possible — use `Req` which is already a dep) to fire a burst of authenticated requests against the Review API endpoints (GET /api/v1/products, GET /api/v1/products/:id/drafts, POST /api/v1/drafts/:id/score, POST /api/v1/drafts/:id/approve) plus the publishing endpoints (POST /api/v1/products/:id/schedule). Concurrency default 50; total requests default 1000; both configurable by env.
    - The script prints a summary: requests per second, p50/p95/p99 latency, error count by status class, total DB query count if Ecto telemetry is enabled during the run.
    - Seed-a-test-dataset step: the script boots the app, runs an idempotent seed (100 products, 50 drafts per product, one approved per), fires the load, tears down. Runs against `MIX_ENV=dev` with a local DB or `MIX_ENV=load` if a separate load env is configured; tests do NOT run this automatically in CI.
    - N+1 detection: hook `Ecto.Adapters.SQL.Sandbox` or `Ecto.LogEntry` to count queries per request; if any request executes more than 20 queries print it to the report. Exact threshold configurable.
    - Does not replace CI unit + integration tests. This is a manual-run smoke that developers invoke before a release or when touching a hot-path endpoint.
    - Tests: one unit test that runs the script with concurrency 2 + requests 10 against the test-env server to prove the script itself works. CI does not run the full 1000-request sweep.

## Open Risks and Unknowns

- `CAPABILITIES.md` lags HEAD. Treat its claims as last-known-good-at-`afc9e17`, not current truth. The architect should refresh it at the end of Phase 11 when the stub/live picture stabilizes.
- Phase 10 depends on Media Forge staying up on the M4 Mac. Any slice that assumes Media Forge is reachable needs a clean fallback path (feature marked unavailable) so a restart does not take the dashboard down.
- Phase 14's Twilio integration has per-minute cost implications; budget-cap the outbound sender before enabling it in prod.
- Phases 13 and 14 both write into the asset flow. If they ship close together, coordinate schema migrations to avoid merge conflicts on the assets table.
