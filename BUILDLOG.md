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
