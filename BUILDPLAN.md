# Content Forge Build Plan

Wave-by-wave plan for the swarmforge flow. Every slice is sized so the architect can write an unambiguous acceptance spec, the coder can implement it in one TDD loop, and the reviewer can gate it with the full quality suite without the slice sprawling.

Plain English only — no code. `CONTENT_FORGE_SPEC.md` is the source of truth for feature intent. This document only sequences and slices the remaining work.

## Delivery Mechanism

All remaining phases (10 through 15) ship via the swarmforge tmux flow defined in `swarmforge/`. Per slice:

1. **Architect** reads this plan, picks the next slice, writes the acceptance spec into `CONTENT_FORGE_SPEC.md`, commits on `master`, and notifies the coder.
2. **Coder** merges from `master`, implements the slice TDD-style in `.worktrees/coder` on the `coder` branch, runs the full local quality gate (`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test`; add `mix credo --strict` once it lands), updates `BUILDLOG.md`, commits, and notifies the reviewer.
3. **Reviewer** merges from `coder`, runs the deep gate (full suite + `mix test --cover`), looks for silent failures and pattern-match-first compliance, refactors small things in place if needed, commits on `reviewer`, and notifies both architect and coder. The architect then merges the reviewer's branch into `master`.

If `mix credo --strict` is not yet wired into the project, the first coder slice should add it (see Bootstrap below). The reviewer must not skip a gate just because it is unconfigured — they should fail back to the architect with a request to wire it.

A slice is "done" only when:

- All quality gates pass on the reviewer's branch.
- `BUILDLOG.md` reflects the change with role + date + commit hash.
- `CAPABILITIES.md` is refreshed at end of phase if it has drifted.

## Bootstrap (do before Phase 10)

Two small slices that unlock the rest:

- **B1. Wire `mix credo --strict` into the project.** Add `:credo` to `mix.exs` deps, add a `.credo.exs` config tuned for this project, and commit. The reviewer's gate depends on this. Tiny slice; coder can do it in one loop.
- **B2. Add a `mix precommit` alias** combining `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, and `test`, so the local gate is one command. Mirror the alias from Media Forge.

## Guiding Principles

## Guiding Principles

- **Bias toward revenue.** Phase 10 (Media Forge wiring) ships working demos faster than any new feature; it goes first.
- **One slice per TDD loop.** Each slice below is intended to fit in a single coder handoff: write one failing test, make it pass, refactor, hand to reviewer.
- **External services behind named modules.** Every integration is swappable in tests via `Req.Test`.
- **Missing credentials downgrade gracefully.** The dashboard should surface "unavailable" rather than crash when a provider is not configured.
- **No placeholder data in production paths.** If the real provider is not wired, the feature is gated off, not faked.

## Phase 10 — Media Forge Integration (unblocks live demos)

**Why first:** Media Forge shipped 2026-04-22. Every slice in this phase replaces stubbed or home-rolled media work with calls into the running service at `http://192.168.1.37:5001`. Delivers functioning end-to-end flows for existing features.

- **10.1 Media Forge HTTP client module**
  - One named module that wraps base URL, `X-MediaForge-Secret` header, JSON body handling, retries, and error classification (transient vs permanent).
  - Exposes functions for the endpoints we actually call: probe, normalize, render, trim, batch render, image process, image render, generation (images and compare), job status, job cancel.
  - Configured by env vars. Missing secret downgrades the client to `status: :unavailable`, which upstream callers surface in the UI.
  - Ships with `Req.Test` stub usage baked into the test suite.

- **10.2 Swap image generation onto Media Forge**
  - Remove local stub from the image generation entry point.
  - Issue generation via Media Forge and wait either by poll or by exposing a signed-webhook receiver.
  - Persist the resulting image bytes or R2 key where the existing schema expects them.
  - Cost reporting in the dashboard should read from Media Forge's `/api/v1/generation/costs` or our mirrored record, not placeholder numbers.

- **10.3 Swap video pipeline FFmpeg step onto Media Forge**
  - Video production pipeline currently calls FFmpeg locally in one step. Replace that step with a Media Forge `/api/v1/video/render` (or `/api/v1/video/batch` for multi-platform) call.
  - Remotion is still responsible for the pre-render composition; Media Forge owns final encoding and per-platform rendition.
  - Preserve existing per-step status tracking in the dashboard.

- **10.4 Swap image processing (EXIF, crops, platform renditions) onto Media Forge**
  - Any place Content Forge manipulates uploaded images (autorotate, EXIF strip, platform crops) moves to Media Forge's `/api/v1/image/*`.
  - This primarily serves Feature 11 (Product Asset Management) when that lands, but upgrade any existing image pre-processing first so Feature 11 inherits the plumbing.

- **10.5 Signed-webhook receiver for Media Forge job completion**
  - Endpoint that verifies `X-MediaForge-Signature` (HMAC SHA256, Stripe-style timestamp window, `Plug.Crypto.secure_compare`) and updates the corresponding Content Forge job record.
  - Alternative to polling. Job records should support either mode.
  - This is a prerequisite for the pipeline work above if we want to avoid long poll loops; slice 10.1 through 10.4 can start with polling, then 10.5 upgrades them once shipped.

Phase exit criteria: end-to-end image generation, image processing, and video rendition all run against live Media Forge in dev; tests run against stubs; dashboard shows real cost numbers; no placeholder image URLs anywhere.

## Phase 11 — Real-Provider Wiring Audit

**Why second:** Several generation and scraping paths still return stubbed output. The previous audit (CAPABILITIES.md at commit `afc9e17`) flagged this; HEAD has moved, and a recent commit (`3ab96c4`) wired MetricsPoller to real platform APIs. This phase replaces remaining stubs with real calls — or gates them off cleanly.

- **11.1 Brief generator real-model wiring**
  - Replace any remaining template-text returns with real Anthropic / Google / xAI / OpenAI calls.
  - Pass performance context and competitor context into the prompt.
  - Stubbed in tests, live in dev/prod.

- **11.2 Bulk variant generation via OpenClaw**
  - Configure the live OpenClaw endpoint for bulk variant generation.
  - Remove mock variant returns.
  - Gate off with "unavailable" if OpenClaw is not configured.

- **11.3 Apify competitor scraping audit**
  - Confirm scrapers hit real Apify actors with real API tokens (per-platform actor selection).
  - Replace any remaining mocked returns and verify the intel synthesis step receives real post payloads.

- **11.4 Brief-rewrite auto-trigger**
  - AUDIT.md previously noted the brief-rewrite trigger "always returns false until metrics flow in." Metrics now flow in. Wire the trigger so brief regeneration fires at the documented threshold (5+ new measurements).

- **11.5 Winner-repurposing auto-trigger**
  - When the scoreboard marks a piece a winner, auto-fire the repurposing pipeline. Currently manual.

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

- **15.4 Load smoke**
  - Small load test against the Review API and the publishing endpoints to catch N+1s and session-handling issues before they bite in a real launch.

## Open Risks and Unknowns

- `CAPABILITIES.md` lags HEAD. Treat its claims as last-known-good-at-`afc9e17`, not current truth. The architect should refresh it at the end of Phase 11 when the stub/live picture stabilizes.
- Phase 10 depends on Media Forge staying up on the M4 Mac. Any slice that assumes Media Forge is reachable needs a clean fallback path (feature marked unavailable) so a restart does not take the dashboard down.
- Phase 14's Twilio integration has per-minute cost implications; budget-cap the outbound sender before enabling it in prod.
- Phases 13 and 14 both write into the asset flow. If they ship close together, coordinate schema migrations to avoid merge conflicts on the assets table.
