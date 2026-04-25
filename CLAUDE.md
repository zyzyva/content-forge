# Content Forge — Claude Instructions

## What this project is

Content Forge is the orchestration brain of the zyzyva ecosystem. It plans, drafts, ranks, publishes, and iterates on content for a stable of products. Phoenix 1.8 + LiveView + Oban + Postgres.

The authoritative spec lives in `CONTENT_FORGE_SPEC.md`. The wave-by-wave plan lives in `BUILDPLAN.md`. Phase status lives in `BUILDLOG.md`. If any of those disagree with the code, fix the doc or the code in the same handoff — never leave them drifted.

## Orchestration

This project is built via the swarmforge tmux flow (architect + coder + reviewer + logger). Role prompts live in `swarmforge/`. The constitution at `swarmforge/constitution.prompt` and its subordinates govern what every agent does. Read them before making architectural moves.

## Division of labor across the ecosystem

- **Content Forge (this project)** — orchestration, drafting, ranking, publishing, dashboard, SEO quality, asset management, SMS gateway.
- **Media Forge** (`http://192.168.1.37:5001`) — image/video processing and AI image generation. Consumed via HTTP with `X-MediaForge-Secret` header. Async results return either by polling `/api/v1/jobs/:id` or via signed webhook.
- **OpenClaw** — bulk variant generation + SMS conversational bot.
- **Cloudflare R2** — long-term storage.

When a slice looks like it needs raw image EXIF handling, video transcoding, or provider-level AI image generation, do not implement it here. Route it to Media Forge via the `ContentForge.MediaForge` client module.

## Development guardrails

- Pattern-match-first, `if` / `case` last.
- TDD for every new behavior. No placeholder tests on merge.
- `mix precommit` (compile warnings-as-errors + format check + credo + test) must pass before any handoff.
- Every external service call (Media Forge, OpenClaw, Twilio, Apify, Anthropic, social platforms) goes behind a named module stubbed in tests via `Req.Test`.
- Missing credentials downgrade a feature to "unavailable" in the UI; they never crash a request.
- Mobile-first LiveView markup, WCAG AA accessibility.
- No emdashes in commit messages or code.

## Adapter wiring across Mix envs

Phase 17.2 opened the dev/prod config gate. The `:scraper_adapter` (`ContentForge.CompetitorScraper.ApifyAdapter`) and `:intel_model` (`ContentForge.CompetitorIntelSynthesizer.LLMAdapter`) Application config keys are wired in every Mix env in `config/runtime.exs`, not just `:prod`. Gating happens at the adapter layer based on env-variable presence:

- Missing `APIFY_TOKEN`: `ApifyAdapter.fetch_posts/1` returns `{:error, :not_configured}` immediately with zero HTTP I/O. The scraper job propagates the failure clearly rather than silently discarding.
- Missing `ANTHROPIC_API_KEY`: `ContentForge.LLM.Anthropic.complete/2` returns `{:error, :not_configured}`. The synthesizer propagates that out; Phase 17.4 routes it to the `pending_manual` MCP-driven completion path.

Tests override either key explicitly when they need fully-stubbed adapters. `test/content_forge/runtime_config_test.exs` pins the wiring so a future cleanup cannot quietly re-add the `if config_env() == :prod` block.
