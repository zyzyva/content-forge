# ContentForge Implementation Audit
Date: 2026-03-27

---

## Summary

The architecture is solid throughout — all schemas, migrations, Oban jobs, API routes, and LiveViews exist. The gaps fall into two categories: features that are fully production-ready, and features that have the right structure but stub out external API calls with placeholder data.

**Overall: ~70-75% production-ready at architectural level.**

---

## Feature Status

### Feature 1: Product Registry — COMPLETE
- All product fields present (name, repo_url, site_url, voice_profile, publishing_targets)
- CRUD via LiveView and REST API
- Blog webhooks with HMAC secret support
- Voice profile required before generation runs
- Minor gap: voice drift detection ("off-brand content outperforming on-brand") not implemented — deferred until metrics data exists

### Feature 2: Content Ingestion Pipeline — COMPLETE
- RepoIngestion job clones repo, extracts README/docs/source up to token limit
- SiteCrawler job crawls up to N pages, extracts text/headings/metadata
- Both store snapshots in R2 via Storage module
- Minor gap: screenshots tracked in schema but never actually captured (Playwright not called)

### Feature 3: AI Content Generation Pipeline — STUBBED
Structure is correct; external calls are mocked:
- ContentBriefGenerator queries are stubbed — returns template, not real Claude/Gemini/xAI responses
- OpenClawBulkGenerator generates placeholder content, not real OpenClaw API calls
- MultiModelRanker scoring logic exists but scoreboard/calibration context is mock data
- ImageGenerator returns placeholder URLs, not real Flux/DALL-E calls
- ScriptGate and WinnerRepurposingEngine logic is correct and not stubbed
- Brief rewrite trigger always returns false (needs real metrics from Feature 7)

### Feature 3.5: Competitor Content Monitoring — COMPLETE
- CompetitorAccount schema and CRUD
- CompetitorScraper job (Apify calls stubbed but structure correct)
- CompetitorIntelSynthesizer synthesizes top posts into intel document
- CompetitorIntel stored per product and included in content brief
- Minor gap: dashboard doesn't show competitor trends alongside own performance

### Feature 4: Short-form Post Publishing — SUBSTANTIALLY COMPLETE
- Twitter, LinkedIn, Reddit, Facebook connectors implemented
- Publisher Oban job with retry
- PublishedPost schema tracks platform post ID, URL, timestamp
- Minor gap: AI-generated images not guaranteed attached to every post (separate job, can fail or not complete in time)
- Minor gap: optimal posting windows function exists but returns mock data

### Feature 5: Blog Publishing — COMPLETE
- Markdown stored in R2 with stable slug-based URL
- Multi-webhook delivery per product
- HMAC signing when secret present
- WebhookDelivery schema tracks per-endpoint success/failure
- Oban retry on failure

### Feature 6: Video Production Pipeline — COMPLETE
- All 6 steps implemented: ElevenLabs → Playwright → HeyGen → Remotion → FFmpeg → YouTube
- Per-step status tracking in VideoJob schema
- Step failure retries 3x then pauses job
- Feature flag per product (HeyGen costs money)
- Note: actual API calls to ElevenLabs, HeyGen, etc. are stubbed — pipeline structure is correct

### Feature 7: Performance Metrics & Feedback Loop — SUBSTANTIALLY STUBBED
Schema and job structure are correct; most logic is either stubbed or not wired:
- ScoreboardEntry and ModelCalibration schemas are correct
- MetricsPoller job exists but platform API calls are stubbed (no real YouTube Analytics, Twitter metrics, etc.)
- Winner/loser labeling logic exists in changeset
- Model calibration schema exists but delta calculation not running from real data
- ClipFlag detection implemented with heuristic spike detection
- Winner repurposing not auto-triggered when scoreboard labels a piece a "winner" — must be manually invoked
- Brief rewrite trigger checks for 5+ new measurements but always returns false (no real metrics flowing in)
- Engagement spike alerts log but don't notify
- Comment volume flagging: endpoint exists, no platform comment count pulling

### Feature 8: Content Review API — COMPLETE
All 13 endpoints implemented and routed:
- GET/POST /api/drafts, GET /api/drafts/:id
- POST /api/drafts/:id/approve, /reject, /score
- POST /api/products/:id/generate
- GET /api/products/:id/brief, /metrics, /hot, /needs-reply
- GET /api/videos/:id/retention
- POST /api/videos/:id/clip
- API key authentication via bearer token

### Feature 9: LiveView Dashboard — SUBSTANTIALLY COMPLETE
- Products list with quick-add form
- Per-product detail (snapshot status, brief, draft queue, publishing history)
- Draft review queue with scores, critiques, approve/reject
- Video production status board
- Performance dashboard with engagement trends
- Clip queue with approve controls
- Minor gap: schedule view exists but no calendar/timeline visualization
- Minor gap: no dedicated script gate view showing threshold vs scores
- Minor gap: WCAG AA compliance not audited or tested

---

## What Needs Real API Wiring

These are the integrations that exist structurally but return stub data:

1. **OpenClaw bulk generation** — `OpenClawBulkGenerator` needs real OpenClaw API calls
2. **Smart model scoring** — `MultiModelRanker` needs real Claude/Gemini/xAI calls with scoreboard context
3. **Image generation** — `ImageGenerator` needs real Flux or DALL-E calls
4. **Apify competitor scraping** — `CompetitorScraper` needs real Apify actor calls per platform
5. **Platform metrics** — `MetricsPoller` needs real YouTube Analytics, Twitter, LinkedIn, Reddit, Facebook metric pulls
6. **ElevenLabs/HeyGen/Remotion/FFmpeg** — `VideoProducer` step functions need real API calls

---

## Auto-Trigger Wiring Gaps

These jobs exist but aren't automatically triggered when they should be:

1. **Winner repurposing** — should trigger when ScoreboardEntry is labeled "winner"; currently requires manual invocation
2. **Brief rewrite** — should trigger when 5+ new measured pieces exist; always returns false until platform metrics flow in
3. **Clip production** — ClipFlags are created but approving one doesn't kick off short-form video production

---

## Testing Coverage

- Unit tests exist for core jobs (repo ingestion, site crawling, metrics poller)
- Controller tests cover main API endpoints
- LiveView tests cover dashboard
- No integration tests of multi-step pipeline
- No end-to-end tests
- No accessibility testing

---

## Recommended Next Steps

1. Wire Feature 7 platform metrics first — this unblocks brief rewrites, model calibration, winner repurposing, and posting window optimization all at once
2. Wire OpenClaw bulk generation and multi-model scoring (Features 3) — makes the pipeline actually generate real content
3. Wire image generation (Feature 3.5 stage) — required for post publishing quality
4. Wire Apify competitor scraping
5. Add auto-triggers for winner repurposing and brief rewrites
6. Build schedule calendar UI and script gate view (Feature 9)
7. Accessibility audit
