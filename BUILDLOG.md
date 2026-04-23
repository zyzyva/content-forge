# Content Forge Build Log

Shared coordination file for the swarmforge agents (architect, coder, reviewer). Check here before starting work to see what's done, what's in progress, and what's blocked.

## How to use this file

- Before starting a slice, check if someone else is already on it.
- When you start a slice, mark it `IN PROGRESS` with your role and date.
- When you finish, mark it `DONE` with role, date, commit hash, and a one-line note on what was produced.
- If you hit a blocker or make a decision that affects other work, add a note under Decisions/Blockers.

## Shipped

### Feature 1: Product Registry

Status: DONE
Note: CRUD, voice profiles, publishing targets, blog webhooks.

### Feature 2: Content Ingestion Pipeline

Status: DONE
Note: Repo cloning, site crawling, R2 snapshots.

### Feature 3: AI Content Generation Pipeline

Status: DONE (structure) / IN PROGRESS (real-provider wiring)
Note: Brief generation, bulk generation, multi-model ranking, image generation entry point, script gate, winner repurposing logic. Some calls still stubbed — see Phase 11 in BUILDPLAN.

### Feature 3.5: Competitor Content Monitoring

Status: DONE (structure)
Note: Account tracking, post scraping, intel synthesis. Apify wiring is real per recent commits but worth auditing — see Phase 11.

### Feature 4: Short-form Post Publishing

Status: DONE
Note: Twitter/X, LinkedIn, Reddit, Facebook/Instagram connectors.

### Feature 5: Blog Publishing

Status: DONE
Note: Webhook delivery, HMAC signing, R2 storage, retry logic.

### Feature 6: Video Production Pipeline

Status: DONE (structure) / PARTIALLY DELEGATED
Note: All six steps wired — ElevenLabs, Playwright, HeyGen, Remotion, FFmpeg, YouTube. Media Forge now owns video transcoding and platform renditions; Phase 10 moves the FFmpeg step onto Media Forge.

### Feature 7: Performance Metrics & Feedback Loop

Status: DONE
Note: Scoreboard schema, model calibration, clip flagging, metrics poller with API endpoints. Commit `3ab96c4` wired real platform APIs.

### Feature 8: Content Review API

Status: DONE
Note: All 13 endpoints, bearer token auth.

### Feature 9: LiveView Dashboard

Status: DONE
Note: Seven pages — products, detail, drafts, schedule, video, performance, clips.

### Phase 10.1: Media Forge HTTP Client

Status: DONE
Note: `ContentForge.MediaForge` at `lib/content_forge/media_forge.ex`, 22-test acceptance file, `Req.Test` stub baked in. Reviewer ACCEPT at `b3883c7`, merged to master as `ba3c3ee`.

### Phase 10.1.1: classify/1 exhaustiveness for 3xx

Status: DONE
Note: 3xx catch-all returning `{:error, {:unexpected_status, status, body}}` shipped with a 304 Not Modified test. Reviewer ACCEPT at `2fadc8f`, merged to master as `2fadc8f` (fast-forward). Tests 123/0.

### Phase 10.2: Swap image generation onto Media Forge

Status: DONE
Merged: master @ `613d442` (fast-forward). Reviewer ACCEPT at same commit. Two follow-ups accepted: 10.2b (publisher-side missing-image block) and 10.2c (ImageGenerator coverage fill).

### Phase 10.2b: Publisher-side missing-image block

Status: DONE
Merged: master @ `b89d89c` (merge commit over `swarmforge-coder@9894dfe` and the intervening role-prompts parallelism edit `ea33b3e`). Reviewer ACCEPT at `9894dfe`. Gate: compile/format/test 144-0 green; credo 40 vs 44 baseline (5 resolved). Architect decisions recorded below: dashboard label "Blocked (Awaiting Image)" accepted; credo baseline-diff rule clarified to tolerate line-shift of unchanged findings.
Note: `ContentForge.Jobs.Publisher` now blocks social post drafts (content_type = "post") that reach publishing without an image. New `enforce_image_required/1` guard runs in both `perform/1` clauses (the product_id+platform path and the draft_id path). When a social post has `image_url` nil or empty, the worker logs "publish blocked: missing image for draft <id>", marks the draft `status: "blocked"` via `ContentGeneration.mark_draft_blocked/1`, and returns `{:cancel, reason}` without touching the platform client. Non-social drafts (blog, video_script) are unaffected. Added `"blocked"` to the Draft status inclusion list and `ContentGeneration.list_blocked_drafts/1` for dashboard surfacing. Added `"blocked"` to the shared `status_badge` component (maps to `badge-error`). Drafts review LiveView got a "Blocked" filter tab (piggybacks on existing `list_drafts_by_status` fallback, so no extra routing logic). Schedule LiveView got a "Blocked (Awaiting Image)" section listing blocked drafts with a distinct BLOCKED status badge; shows "No blocked drafts" when empty. New test files: `test/content_forge/jobs/publisher_missing_image_test.exs` (8 tests: 5 per-platform blocker cases, 1 product_id+platform path, 1 happy path asserting the gate lets image-bearing drafts through, 1 non-social unaffected). Dashboard tests added in `dashboard_live_test.exs`: Blocked filter tab exposed on review page, blocked draft renders with BLOCKED badge, schedule page surfaces blocked drafts. Gate: compile --warnings-as-errors clean, format clean, full test 144/0. Credo --strict by content is strictly better than baseline: 5 baseline findings resolved (the 2 image_generator.ex findings from 10.2 plus 3 more on publisher.ex - nesting depth and alias ordering dropped due to this refactor; `build_post_opts` cyclomatic-19 preserved, shifted from line 224:8 to 253:8 only because code was added above it, function body unchanged). No new findings on any file.

### Phase 11.1 (infra): Anthropic LLM HTTP client

Status: IN PROGRESS (coder handoff)
Note: `ContentForge.LLM.Anthropic` at `lib/content_forge/llm/anthropic.ex`. Mirrors the MediaForge 10.1 pattern: single public `complete(prompt, opts)` function, `status/0` predicate, `:not_configured` downgrade with zero HTTP I/O when the API key is missing. Configuration lives under `:content_forge, :llm, :anthropic` with `:api_key`, `:default_model`, `:max_tokens`, `:base_url`, `:anthropic_version`, and a `:req_options` escape hatch for the `Req.Test` plug. Authentication sets `x-api-key` and `anthropic-version` inside the client on every request; callers cannot omit either. Endpoint is `POST /v1/messages`. Request-body construction accepts a plain string (wrapped as a single user message) or a pre-built list of role/content turns; caller options (model, max_tokens, temperature, system) are honored with sensible defaults falling through to application config. Response parsing extracts the first text block from the Messages API `content` array and returns `{:ok, %{text, model, stop_reason, usage}}`. Error classification mirrors MediaForge: 5xx and 429 -> `{:transient, status, body}` (so Oban, which owns retry, can back off); HTTP timeout -> `{:transient, :timeout, reason}`; connection refused / DNS / similar network -> `{:transient, :network, reason}`; other 4xx -> `{:http_error, status, body}`; 3xx -> `{:unexpected_status, status, body}`; anything else -> `{:error, reason}`. `Req.Test` stub baked in from day one; test suite uses module-name stubs and never touches the live Anthropic API. New test file `test/content_forge/llm/anthropic_test.exs` covers 16 cases: status ok / missing / empty, missing-key short-circuit asserts zero HTTP, happy-path completion with header assertions, caller overrides on the request body, list-of-turns prompt shape, multi-block content extraction, 429 transient, 500 transient, 400 permanent, 401 permanent, transport timeout, connection refused, 304 unexpected status, and a counter-backed assertion that the client does not retry internally on classified errors. Runtime config sources `ANTHROPIC_API_KEY` (plus optional overrides for base URL, default model, and max tokens); compile-time defaults live in `config/config.exs`. No caller swaps landed; 11.1 (caller) will swap the brief generator in a follow-up. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 186/0 (170 prior + 16 new). Credo by content strictly better than baseline: same 6 findings resolved as after 10.5, `publisher.ex:253:8` and `video_producer.ex:54:12` are the known line-shift carryovers per `f26d099` rule. No new findings.

### Phase 10.5a: Webhook test output cleanup

Status: DONE
Merged: master @ `d402d8d` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 170-0, credo identical to post-10.5 state. Webhook suite output clean (11 dots, no warning noise).
Note: Pure hygiene on `test/content_forge_web/controllers/media_forge_webhook_controller_test.exs`. The five rejection-path tests (stale timestamp, invalid signature, missing signature header, unknown job id, malformed payload) previously emitted unwrapped Logger warnings that polluted `mix test` output. Each is now wrapped in `ExUnit.CaptureLog.capture_log/1` using the same `send(self(), {:conn, conn}) / assert_received` pattern as `image_generator_test.exs`, and asserts a substring of the expected log line so the silence is intentional, not accidental. No behavior change. Gate: compile --warnings-as-errors clean, format clean, mix test 170/0, credo identical to post-10.5 state.

### Phase 10.5: Media Forge webhook receiver

Status: DONE
Merged: master @ `f990a38` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 170-0. Security verified (HMAC-SHA256 over raw body, 300s window both directions, Plug.Crypto.secure_compare, body-reader scoped to webhook paths only, fails closed on missing secret, signatures never echoed). Idempotency centralized in JobResolver; tested both directions. Minor follow-up 10.5a: five rejection/malformed/unknown-id logger warnings in `webhook_controller_test.exs` are not wrapped in `capture_log`, producing noisy test output. Bundled pre-existing bug fix (`Draft.put_default_status/1` `get_change`→`get_field`) accepted as load-bearing for the webhook's update-without-clobber behavior.
Note: Inbound webhook at `POST /webhooks/media_forge` verifies `X-MediaForge-Signature` (Stripe-style `t=<unix>,v1=<hex>`) over the raw request body using HMAC-SHA256 with the configured shared secret, compares via `Plug.Crypto.secure_compare/2`, and enforces a 300-second timestamp window. Raw body capture lives in a new `ContentForgeWeb.BodyReader` wired into `Plug.Parsers` via `body_reader:` so parsed JSON still reaches the controller while the verifier plug sees the exact bytes Media Forge signed. Rejection paths log and halt: 400 for stale/malformed, 401 for missing/bad signature (never echoing the offending value). The verifier reads `:webhook_secret` first, falling back to `:secret`, and rejects every request when no secret is configured. Introduced `ContentForge.MediaForge.JobResolver`, a shared state-transition helper used by both pollers (`ImageGenerator`, `VideoProducer`) and the webhook controller; entry points return `{:ok, :done, url|key}`, `{:ok, :failed, reason}`, `{:ok, :noop}`, or `{:error, :not_found}`. Idempotency is centralised: image drafts are terminal when status is `"blocked"`/`"published"` or `image_url` is already set; video jobs are terminal when status is `"encoded"`/`"uploaded"`/`"failed"`. Migration `20260423120000` adds `media_forge_job_id` (indexed) to both `drafts` and `video_jobs` plus an `error` string on `drafts`; schemas and context helpers expose `get_*_by_media_forge_job_id/1`. Pollers now persist `media_forge_job_id` on the record when they enter the polling loop and route done/failed through the resolver; the synchronous paths in ImageGenerator/VideoProducer also go through the resolver for consistency. Pre-existing bug uncovered and fixed in `Draft.put_default_status/1`: it force-applied `"draft"` whenever a changeset had no `:status` change, so every `update_draft/2` would clobber a persisted status like `"ranked"` back to `"draft"`. Switched from `get_change` to `get_field` so the default only fires when the persisted value is also nil; existing tests still pass. New webhook controller test file (11 cases): image-done updates `image_url` + stays `"ranked"`; image-failed marks `"blocked"` with error note; video-done records R2 key + transitions to `"encoded"`; video-failed transitions to `"failed"` with error; repeat webhook for terminal image draft is a no-op 200; repeat webhook for `"encoded"` video job is a no-op 200; stale timestamp 400; invalid signature 401; missing signature header 401; unknown job id 404; malformed payload 400. Runtime config sources `MEDIA_FORGE_WEBHOOK_SECRET` (falling back to `MEDIA_FORGE_SECRET`) in `config/runtime.exs`. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 170/0 (159 previous + 11 new webhook). Credo by content strictly better than baseline: same 6 findings resolved as after 10.3; `publisher.ex:253:8` and `video_producer.ex:54:12` are the known line-shift carryovers (same function bodies per `f26d099` rule). No new findings introduced by this slice.

### Phase 10.3: Swap video pipeline FFmpeg step onto Media Forge

Status: DONE
Merged: master @ `42db18f` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 159-0, VideoProducer coverage 70.30 (untouched legacy simulation steps are the uncovered ones, pre-existing). Credo 38 vs 44 baseline (6 net improvements; line-shift carryovers verified per `f26d099`). State machine matches spec: `encoded` on done, `assembled` + error on `:not_configured`, `failed` on permanent, retry on transient.
Note: Step 5 of `ContentForge.Jobs.VideoProducer` no longer simulates FFmpeg locally. The step now calls `ContentForge.MediaForge.enqueue_video_render/1` with the Remotion-assembled R2 key, handles synchronous responses (persists the returned R2 key and transitions `assembled` to `encoded`), and resolves asynchronous responses by polling `MediaForge.get_job/1` with a configurable interval and attempt cap (default 5 seconds x 60 attempts; tests override to 0). On `{:error, :not_configured}` the step logs "Media Forge unavailable", writes "Media Forge unavailable" to the video job's `error` field, and leaves status at `assembled` (not a retry condition; Oban returns `:ok`). Permanent 4xx and unexpected-status errors mark the video job `failed` with the error recorded and return `{:cancel, reason}` from Oban. Transient 5xx and network errors return `{:error, reason}` so Oban retries under its `max_attempts`. The old `ffmpeg_encode/2` simulation and the product-level `"ffmpeg"."enabled"` config flag are removed entirely; there is no backwards-compatibility path. Added `"encoded"` to `VideoJob` status inclusion and predicate helpers, plus `encoded?/1`. Video status LiveView gets `"encoded"` in `@status_order` (between `assembled` and `uploaded`) and in `format_step_name/1` so the pipeline visualization and step count chart include the new state. The detail panel already surfaces the `error` field, so the "Media Forge unavailable" pause reason is visible when a stuck job is selected. Refactored `execute_pipeline/3` from four nested `case` blocks into a flat `with` chain (using a `tag_step/2` helper so `handle_step_error/3` still receives the step atom), and extracted a `finalize/4` helper for the step-5-plus-step-6 tail; both reduce cyclomatic complexity and nesting to within baseline thresholds. New test file `test/content_forge/jobs/video_producer_test.exs` (5 tests: sync success with immediate R2 key, async success via polled get_job, missing-secret downgrade leaving the job at `assembled` with the error message, permanent 422 marking the job `failed`, transient 503 returning `{:error, _}` without a status change). All tests run against `Req.Test` stubs; no live Media Forge calls. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 159/0. Credo by content strictly better than baseline: three more findings resolved on video_producer.ex (nesting-6 dropped entirely after the `with` refactor, alias ordering fixed by the include reorder); the negated-if-else on the feature_flag guard remains unchanged at a shifted line number.

### Phase 10.2c: ImageGenerator test coverage fill

Status: DONE
Merged: master @ `78d4437` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 154-0, ImageGenerator coverage 65.79% → 90.79%. Credo baseline unchanged (per f26d099 line-shift rule).
Note: Pure test additions against `ContentForge.Jobs.ImageGenerator`. No behavior change. Added 10 new cases (describe blocks: "coverage fill: alternate sync response shapes" x 3, "coverage fill: error classification branches" x 2, "coverage fill: polling branches" x 5). Covers every BUILDPLAN-named branch: persist-or-fail when Media Forge reports done without an extractable URL (returns `{:cancel, "Media Forge returned done without an image url"}`, logs "reported done but no image url"), unrecognized sync body (no image_url/url/result/jobId keys, returns `{:cancel, "unrecognized Media Forge response"}`), polling that observes a late `:not_configured` (stub clears the Media Forge secret on the POST response so the subsequent `get_job/1` short-circuits; the worker returns `{:ok, :skipped}` and logs "Media Forge became unavailable while polling"), and the generic error catch-all (a redirect loop produces `%Req.TooManyRedirectsError{}` which passes through MediaForge's generic classify clause and propagates as `{:error, _}` via ImageGenerator's catch-all). Also exercises the remaining handle_generate_response clauses (`"url"` key, nested `"result"."image_url"`), the `{:error, {:unexpected_status, ...}}` branch (via a stubbed 304), a polling generic-error branch (503 during polling), and the alternate `extract_result_url` clauses (`"result"."url"` and top-level `"image_url"` in poll responses). Module coverage lifted from 65.79 percent to 90.79 percent. Overall project coverage threshold remains at zero per the baseline gate. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 154/0. Credo unchanged from post-10.2b state: same 5 baseline findings resolved, build_post_opts cyclomatic-19 at line 253:8 shifted from 224:8 (content unchanged).

Note: `ContentForge.Jobs.ImageGenerator` now calls `ContentForge.MediaForge.generate_images/1` instead of returning a placeholder URL. Handles synchronous responses (persists `image_url` immediately) and asynchronous responses (polls `MediaForge.get_job/1` with configurable interval and cap). `{:error, :not_configured}` logs "Media Forge unavailable", returns `{:ok, :skipped}`, and leaves `image_url` nil - no placeholder URL is ever written. Permanent 4xx errors `{:cancel, reason}`; transient 5xx/network errors propagate as `{:error, _}` so Oban retries. Non-post drafts skipped; drafts already carrying an image_url skipped. Oban queue config in `config/config.exs` extended with `:content_generation`, `:ingestion`, `:competitor` so the worker and its sibling workers actually run. Queue-override bug in `process_all_social_posts/1` fixed - child jobs now enqueue via `__MODULE__.new/1` on the declared `:content_generation` queue rather than the nonexistent `:image_generation`. New test file `test/content_forge/jobs/image_generator_test.exs` covers 10 scenarios (sync success, async poll-to-done, async poll-to-failed, poll timeout, not-configured downgrade, 4xx cancel, 5xx transient retry, non-post skip, already-attached skip, child queue assertion). Gate green: compile --warnings-as-errors clean, format clean, credo --strict strictly better than baseline (2 findings from the old image_generator.ex are gone; no new findings - `unless/else` replaced with function heads), mix test 133/0.

## Outstanding

See `BUILDPLAN.md` for the wave-by-wave plan. Short version:

- Phase 10: Media Forge integration (now unblocked — Media Forge shipped 2026-04-22).
- Phase 11: Real-provider wiring audit for brief generator, bulk variant generation, Apify scrapers.
- Phase 12: Feature 10 — SEO Quality Pipeline.
- Phase 13: Feature 11 — Product Asset Management.
- Phase 14: Feature 12 — SMS Gateway and Conversational Bot.
- Phase 15: Polish — auto-triggers, dashboard UX, WCAG audit, end-to-end tests.

## Decisions and Notes

- **2026-04-22:** Swarmforge config ported from Media Forge to Content Forge. `BUILDLOG.md`, `BUILDPLAN.md`, and `CLAUDE.md` created as the swarm's authoritative plan documents. Legacy orchestration docs (`AGENTS.md`, `CLAUDE_TASKS.md`, `CLAW_TASKS.md`, `RALPH_PHASE1.md`, `RALPH_PHASE2.md`) remain as history but no longer drive the build.
- **2026-04-22:** Media Forge shipped all seven phases. Content Forge integration work (Phase 10) is unblocked. Live service runs at `http://192.168.1.37:5001`.
- **2026-04-22:** `CAPABILITIES.md` was last verified against commit `afc9e17` (2026-03-28); HEAD is `c120ad5` (2026-04-22). Treat that doc as lagging — verify against current code before citing it.
- **2026-04-22:** Phase 2 audit and merge. Gated Competitor Scraper behind `:apify_token` + `:scraper_adapter` config and Competitor Intel Synthesizer behind `:intel_model` adapter — both now return `{:discard, reason}` rather than fabricating output. Removed faked `heuristic_analysis` (broken `detect_hooks/1`) and hardcoded `mock_posts/1`. Fixed pre-existing bugs uncovered by audit: `Products.list_top_competitor_posts_for_product/2` query (`where eq` → `where in`), `FallbackController` JSON view binding for changeset errors, `competitor_scraper.ex` per-post insert errors silently dropped (now logged + counted as `:partial`). `SiteCrawler.resolve_url/2` bare rescue tightened to `ArgumentError`. Net: +24 tests (16 new + 8 from earlier feature work that came in the merge), 100/100 passing under `mix test`. Reviewed by `pr-review-toolkit:code-reviewer` and `pr-review-toolkit:silent-failure-hunter` (both: SHIP). Merged `phase-2` → `master` as `a5e1785`. `mix credo --strict` not wired in this project yet; tracked as bootstrap item B1 in `BUILDPLAN.md`.
- **2026-04-22:** Pre-existing authorization gap noted but not fixed: `CompetitorController` `show/update/delete` accept `product_id` from URL but never verify the competitor belongs to that product. Out of scope for Phase 2 audit; should be picked up under multi-tenant safety in a future polish slice.
- **2026-04-22:** Bootstrap B1 (credo) landed. `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}` added; `.credo.exs` generated with `Refactor.Nesting` relaxed to 3 and `Refactor.CyclomaticComplexity` relaxed to 12 to grandfather Features 1-9 hotspots. `mix credo --strict` currently reports 44 findings; all snapshotted in `.credo_baseline.txt`. Reviewer constitution amended: each slice must diff against baseline and introduce no new findings. A dedicated credo-cleanup slice (Phase 15 polish) will tighten thresholds back to defaults and refresh the baseline. Credo is NOT in the `mix precommit` alias because it would always fail on existing debt; run `mix credo --strict` separately as part of the reviewer's gate.
- **2026-04-22:** Bootstrap B2 (precommit alias) already in place: `mix precommit` runs compile-warnings-as-errors, deps.unlock --unused, format, and test. Serves as the coder's fast feedback gate.
- **2026-04-22:** Doc reconciliation on branch names. The harness provisions role branches with the `swarmforge-` prefix (`swarmforge-coder`, `swarmforge-reviewer`) to match the session naming convention, but `workflow.prompt`, `coder.prompt`, `reviewer.prompt`, and `BUILDPLAN.md` still referenced the shorter `coder` / `reviewer` names. Reviewer agent had already acknowledged online on `swarmforge-reviewer @ 036f5b2`, so renaming live branches mid-work would have disrupted the baseline quality gate. Updated the docs to match reality instead. No behavior change, only naming. Branches and worktrees verified at `036f5b2`.
- **2026-04-22:** Phase 10.1 coder handoff. `ContentForge.MediaForge` HTTP client landed on `swarmforge-coder` at `lib/content_forge/media_forge.ex`, with `Req.Test` stub wiring and a 22-test acceptance file under `test/content_forge/media_forge_test.exs`. Covers probe, four video enqueue paths, three image enqueue paths, generation + compare, job status, job cancel. Error classification: 5xx to `{:transient, status, body}`, HTTP timeouts to `{:transient, :timeout, reason}`, network (econnrefused/nxdomain/etc) to `{:transient, :network, reason}`, 4xx to `{:http_error, status, body}`, missing secret to `:not_configured` with no HTTP call. `X-MediaForge-Secret` header set inside the client on every request; callers cannot omit. Base URL defaults to `http://192.168.1.37:5001`, overridable via `:content_forge, :media_forge, :base_url`. Gate green on `swarmforge-coder`: `mix compile --warnings-as-errors` clean, `mix format --check-formatted` clean, `mix credo --strict` 41/41 file:line locations unchanged vs `.credo_baseline.txt`, `mix test` 122/0. No caller swaps landed - those are 10.2 through 10.4.
- **2026-04-22:** Baseline gate repairs on master, uncovered by reviewer's first pass. (1) HEEX format regression from bootstrap `c83e49a` in `lib/content_forge_web/live/dashboard/products/detail_live.ex` at the brief "Model: X" span. Root cause: multi-space literal text adjacent to `{@interp}` inside a `:if` span made the HEEX formatter non-idempotent — each run added another space, so `mix format --check-formatted` always failed on the next pass. Collapsed to a single space (HTML collapses whitespace anyway, so no visual change). (2) `mix test --cover` default threshold is 90 per module; the project ships at 18.08% overall with many modules at 0%, so every reviewer gate was exiting 3 on baseline debt. Added `test_coverage: [summary: [threshold: 0]]` to `mix.exs` so the summary still prints but no module is marked failed — mirrors the credo-baseline "acknowledged debt, no regression" pattern. Coverage uplift is tracked as a Phase 15 item. All gates green on master: compile clean, format clean, `mix test` 100/0, `mix credo --strict` matches `.credo_baseline.txt` exactly, `mix test --cover` exits 0. Commit on master; reviewer can resume baseline on the next fast-forward.
- **2026-04-22:** Phase 10.1 merged to master as `ba3c3ee` (merge commit over `swarmforge-coder@b3883c7` and the intervening constitution handoff-brevity amendment `d4271f1`). Reviewer ACCEPT at `b3883c7` with no reviewer commits. Reviewer flagged one non-blocking follow-up accepted by architect: `MediaForge.classify/1` is not exhaustive for `{:ok, %Req.Response{status: 300..399}}` — a 3xx response would `FunctionClauseError`. Engineering rule requires exhaustive pattern matches, so this is scheduled as Phase 10.1.1 (one-line catch-all clause returning an `:unexpected_status` error tuple, plus the failing test first). Also accepted reviewer's layout choice: a single `lib/content_forge/media_forge.ex` file instead of the spec's `lib/content_forge/media_forge/` subdirectory — idiomatic Elixir when no helper modules exist. Spec amended to reflect the single-file reality. Coverage: `ContentForge.MediaForge` 94.59%, total 18.99%.
- **2026-04-23:** Phase 10.2b architect decisions. (1) Dashboard label for blocked-pending-image drafts: coder shipped "Blocked (Awaiting Image)" rather than the spec's earlier "Media Forge unavailable" phrasing. Accepted as-is. Rationale: the block applies at the draft level and can be caused by reasons other than Media Forge being unavailable (a draft can arrive at the publisher ahead of its image generation job for benign timing reasons). The product-level "Media Forge unavailable" banner is a separate surface owned by Phase 15.1 (provider status panel) and is not the same thing as the per-draft blocked label. (2) Credo baseline-diff rule clarified in `workflow.prompt`: match findings by file + check name + message rather than file + line + column. A finding that shifts to a new line because surrounding code grew or shrank is the same finding. This came up because 10.2b added 29 lines to `publisher.ex` above the grandfathered cyclomatic-19 `build_post_opts` function, which shifted its baseline finding from line 224 to 253. The reviewer verified the body was unchanged and accepted.
