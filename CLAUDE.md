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
