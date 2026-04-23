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
