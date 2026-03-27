# ContentForge Specification

## Overview

ContentForge is a standalone Elixir/Phoenix app that ingests a product's repo and website, then runs a tiered AI pipeline: OpenClaw (a fast local model) generates large batches of content variants — posts, blog drafts, and video scripts — then smarter models (Claude, Gemini, xAI) rank and critique each batch, and only the top-ranked items proceed to expensive production steps (video rendering, publishing). A feedback loop pulls performance metrics from each platform and feeds them back into the content brief, so the system learns what actually works over time. The app exposes both a LiveView dashboard and a REST API so OpenClaw and other external tools can drive the entire pipeline programmatically.

## Primary User

- **Who:** Solo developer/founder managing multiple products
- **Context:** Running locally or deployed alongside other apps in the provisioner ecosystem; used daily or on-demand to keep content flowing across platforms without manual writing
- **Goal:** Publish consistent, high-quality content about each product without doing the work manually — let AI generate in bulk, let smarter AI pick winners, and let the scheduler handle the rest

---

## Features

### Feature 1: Product Registry

**Purpose:** Register and configure each product so the system knows what to generate content about, where to publish it, and how often.

Acceptance criteria:
- [ ] A product has: name, repo URL (optional), site URL (optional), per-platform posting frequency, and a list of enabled publishing targets
- [ ] Products can be created, read, updated, and deleted via LiveView UI
- [ ] Products can be created, read, updated, and deleted via REST API
- [ ] Each product has a publishing target config: each platform (YouTube, LinkedIn, Twitter/X, Reddit, Facebook/Instagram, blog) has enabled/disabled toggle and a cadence (e.g. 3x/week, 1x/month)
- [ ] Products are stored in PostgreSQL
- [ ] Each product can register one or more blog webhook endpoints (URL + optional HMAC secret) for blog delivery

---

### Feature 2: Content Ingestion Pipeline

**Purpose:** Extract context from a product's repo and live site so AI has accurate, specific material to work from — not just generic descriptions.

Acceptance criteria:
- [ ] Given a repo URL, the system clones it to a temp directory and extracts: README, any docs/ files, CHANGELOG, and key source files (lib/, src/, etc.) up to a configurable token limit
- [ ] Given a site URL, the system crawls up to N pages (configurable) and extracts text content, headings, and metadata
- [ ] Screenshots of key pages are captured using a headless browser (Playwright or Chrome DevTools MCP)
- [ ] Extracted content is stored as a "product snapshot" in R2 with a timestamp
- [ ] A new snapshot is triggered on demand or on a schedule (e.g. weekly)
- [ ] Ingestion jobs run via Oban

---

### Feature 3: AI Content Generation Pipeline

**Purpose:** Generate large batches of content variants cheaply, then use smarter models to rank and filter — so only the best content reaches expensive production steps or gets published.

**Model roles:**
- **OpenClaw** (primary generator): fast, cheap, high-volume — generates all first-draft content variants
- **Smart review models** (Claude Opus, Gemini Pro, xAI): score and critique drafts, vote on winners, write improvement notes

**Pipeline stages:**
- Stage 1 (Content brief): Query Claude, Gemini, and xAI with the product snapshot asking what makes high-ranking content in this niche. Synthesize their responses into a content brief stored per product. Refresh when performance data changes significantly.
- Stage 2 (Bulk generation via OpenClaw): OpenClaw generates N variants of each content type per run — for example, 20 Twitter posts, 10 LinkedIn posts, 5 blog drafts, 10 video scripts. Each variant takes a different angle (educational, entertaining, problem-aware, social proof, etc.). Every batch must include at least one explicitly humorous/funny variant per content type — humor is a required angle, not optional.
- Stage 3 (Multi-model ranking): Each smart model independently scores every draft on accuracy (0-10), SEO relevance (0-10), and entertainment/education value (0-10). Scores are averaged across models. Each model also writes a short critique. Top-scoring drafts per content type advance; the rest are archived.
- Stage 4 (Script gate — video only): Before any video is produced, the top-ranked scripts go through a second ranking pass focused specifically on visual storytelling, hook strength, and retention. Only scripts clearing a configurable threshold proceed to video production. This gate prevents spending on HeyGen/ElevenLabs for weak scripts.

Acceptance criteria:
- [ ] Content brief generation queries at least 2 smart models and stores the synthesized brief per product with a timestamp
- [ ] OpenClaw is the designated bulk generation model — its API endpoint is configurable so it can be swapped
- [ ] Per run, the system generates: configurable N variants per platform (default: 20 posts per social platform, 5 blog drafts, 10 video scripts)
- [ ] Every batch guarantees at least one humor/funny variant per content type — the content brief instructs OpenClaw to include this angle
- [ ] Humor variants are labeled with angle "humor" so ranking models and humans can filter/compare by angle
- [ ] Each variant stores: content text, platform target, angle/type label, generating model, per-model scores (accuracy/SEO/EEV), averaged composite score, per-model critique text, and status (draft/ranked/approved/rejected/published)
- [ ] After ranking, top N per content type (configurable, default: top 3) are promoted to review queue; rest archived
- [ ] Video scripts have a second ranking pass with a configurable score threshold gate before video production is triggered
- [ ] All generation and ranking jobs run via Oban with retry support
- [ ] Content brief, all variants, scores, and critiques are accessible via REST API
- [ ] External models (OpenClaw or others) can submit new variants and scores via API without going through the LiveView

---

### Feature 4: Short-form Post Publishing

**Purpose:** Publish approved short-form posts to Twitter/X, LinkedIn, Reddit, and Facebook/Instagram.

Acceptance criteria:
- [ ] Twitter/X: Post text (up to 280 chars), with optional image attachment, via Twitter v2 API
- [ ] LinkedIn: Post text + optional image to a personal profile or company page via LinkedIn API
- [ ] Reddit: Submit a text post to a configured subreddit via Reddit API
- [ ] Facebook/Instagram: Post text + optional image via Meta Graph API
- [ ] Each connector retrieves its OAuth tokens / API keys from 1Password at runtime
- [ ] A failed publish is retried via Oban (up to 3 attempts) and flagged if all retries fail
- [ ] Published posts record the platform post ID, timestamp, and link

---

### Feature 5: Blog Publishing

**Purpose:** Deliver approved long-form blog articles to any number of registered sites without coupling to a specific CMS.

**Design:** The article (markdown) is saved to Cloudflare R2. A webhook is fired to each registered endpoint for the product with the R2 URL. Each site implements its own receiver to fetch and display the article.

Acceptance criteria:
- [ ] Approved blog articles are stored in R2 as markdown files with a stable URL
- [ ] Each product can have multiple blog webhook endpoints registered (URL + optional HMAC secret)
- [ ] On approval, the system POSTs to each registered webhook with: article title, R2 URL, product slug, publish timestamp, and optional metadata (tags, SEO description)
- [ ] Webhook delivery is retried via Oban on failure
- [ ] Webhook payloads are HMAC-signed when a secret is configured
- [ ] Delivery status (success/failure/pending) is recorded per endpoint per article

---

### Feature 6: Video Production Pipeline

**Purpose:** Produce demo and talking-head videos for YouTube from ranked scripts — with a gate at script selection to avoid spending on weak content.

**Stack:** ElevenLabs (voiceover audio), HeyGen (AI avatar talking head), Playwright (screen recording of live site), Remotion + Node.js sidecar (programmatic video composition), FFmpeg (final assembly/encoding).

**Script-first design:** Scripts are generated and ranked in Feature 3 before any video production begins. Video production only triggers for scripts that pass the ranking threshold. Multiple script variants may be produced as separate videos if budget allows, or only the top 1-2 proceed.

Acceptance criteria:
- [ ] Video production job only starts when a script has passed the script gate (ranking score above threshold)
- [ ] Multiple scripts can be queued for production in parallel — each tracked as a separate video job
- [ ] ElevenLabs voiceover: script is sent to ElevenLabs, MP3 stored in R2 keyed to the script ID
- [ ] Playwright screen recorder: headless browser navigates the live site, records walkthrough as video, stored in R2
- [ ] HeyGen talking head: script + configured avatar submitted to HeyGen API, result polled and stored in R2
- [ ] Remotion sidecar assembles final video: intro slate, screen recording segments, talking head segments, outro, with voiceover laid over
- [ ] FFmpeg handles final encoding and format normalization
- [ ] Final video uploaded to YouTube with AI-generated title, description, tags, and thumbnail (from screenshot)
- [ ] YouTube OAuth tokens are encrypted in PostgreSQL; app refreshes automatically
- [ ] Each video job tracks per-step status in DB (script_approved / voiceover_done / recording_done / avatar_done / assembled / uploaded)
- [ ] Failed steps retry via Oban; a step failing 3 times pauses the job and alerts via dashboard
- [ ] Video production is gated behind a feature flag per product (HeyGen costs money)

---

### Feature 7: Performance Metrics & Feedback Loop

**Purpose:** Pull real performance data from each platform after content is published, surface what's working, flag videos for clipping, and feed insights back into the content brief so future generation improves over time.

**Why this matters:** Without feedback, the system is generating blind. With it, OpenClaw and the ranking models can learn which angles, hooks, and formats actually drive views, engagement, and conversions for each product.

Acceptance criteria:
- [ ] YouTube Analytics: after a video is published, a scheduled job pulls views, watch time, average view duration, audience retention curve, likes, comments, and shares at 24h / 7d / 30d intervals
- [ ] Social metrics: for each published post, pull platform-native engagement metrics (likes, shares, impressions, replies, click-throughs) at the same intervals
- [ ] Blog metrics: if a blog webhook endpoint returns view/engagement data (optional), record it; otherwise track delivery status only
- [ ] "Clip this" detection: videos where the audience retention curve shows a high-engagement segment (above configurable threshold for configurable duration) are automatically flagged with the timestamp range and a suggested short-form clip title
- [ ] Clipping queue: flagged video segments are added to a clip queue; each clip can be approved to produce a short-form video (Reels/Shorts/TikTok length) cut from the source
- [ ] Metrics feed back into the content brief: after each metrics sync, a job computes which content angles, formats, and topics are outperforming and appends a performance summary to the product's content brief
- [ ] The content brief performance summary is available via API so OpenClaw and smart models can read it when generating new content
- [ ] Dashboard shows per-content performance: views/engagement trend, retention curve for videos, flag for clippable segments
- [ ] GET /api/products/:id/metrics — returns aggregated performance data per product
- [ ] GET /api/videos/:id/retention — returns the retention curve data and any flagged clip segments

---

### Feature 8: Content Review API

**Purpose:** Allow OpenClaw and other external LLMs to drive the full pipeline — generating variants, submitting scores and critiques, approving/rejecting drafts, triggering production, and reading metrics — without needing the LiveView UI.

Acceptance criteria:
- [ ] GET /api/drafts — list drafts with filters for product, platform, status, content type, and minimum composite score
- [ ] GET /api/drafts/:id — retrieve a single draft with content, all per-model scores, critiques, and metadata
- [ ] POST /api/drafts — submit a new draft variant (OpenClaw posts content it generated directly)
- [ ] POST /api/drafts/:id/approve — approve a draft for scheduling
- [ ] POST /api/drafts/:id/reject — reject with an optional reason
- [ ] POST /api/drafts/:id/score — submit scores (accuracy, SEO, EEV) and a critique from a named model
- [ ] POST /api/products/:id/generate — trigger a new generation run for a product
- [ ] GET /api/products/:id/brief — retrieve the current content brief including performance summary
- [ ] GET /api/products/:id/metrics — aggregated performance data
- [ ] GET /api/videos/:id/retention — retention curve + flagged clip segments
- [ ] POST /api/videos/:id/clip — approve a flagged segment to produce a short-form clip
- [ ] All endpoints require API key (bearer token); keys stored encrypted in PostgreSQL
- [ ] API responses are JSON

---

### Feature 9: LiveView Dashboard

**Purpose:** Human-friendly UI for managing products, reviewing drafts, monitoring the posting queue, and checking publishing history.

Acceptance criteria:
- [ ] Products list with quick-add form
- [ ] Per-product detail page: snapshot status, content brief, draft queue, publishing history
- [ ] Draft review queue: shows all variants with composite score, per-model scores, critiques, and approve/reject controls
- [ ] Script ranking view: video scripts ranked by score with the gate threshold visible — promote or override
- [ ] Schedule view: calendar or timeline of upcoming and past posts per product per platform
- [ ] Publishing history: each post with platform, timestamp, link, and live performance metrics
- [ ] Video production status board: per-step status (script_approved → voiceover → recording → avatar → assembled → uploaded)
- [ ] Performance dashboard: views/engagement trends per product, retention curves for videos, clippable segment flags
- [ ] Clip queue: flagged video segments with timestamp range, suggested title, approve to produce short-form clip
- [ ] All views are mobile-responsive and accessible (WCAG AA)

---

## Implementation Checklist

### Phase 1: Foundation (items 1a–1c are independent)

- [ ] 1a. Scaffold new Phoenix app `content_forge` with Ecto/PostgreSQL, Oban, and 1Password integration — product registry context
- [ ] 1b. REST API skeleton: authentication middleware, JSON response helpers, versioned routes
- [ ] 1c. Cloudflare R2 client module (reuse ExAws.S3 pattern from other apps)
- [ ] 1d. Product registry CRUD: Ecto schema, context functions, LiveView UI, API endpoints (depends on 1a, 1b)
- [ ] 1e. Blog webhook registry: schema + CRUD + HMAC signing util (depends on 1d)

### Phase 2: Content Ingestion (items 2a–2b are independent)

- [ ] 2a. Repo cloning + extraction: Oban job that git clones to temp dir, reads README/docs, extracts text up to token limit, stores snapshot in R2
- [ ] 2b. Site crawler: Oban job that fetches N pages via WebFetch/Playwright, extracts text + screenshots, stores in R2
- [ ] 2c. Product snapshot schema + storage: link snapshot metadata (timestamp, R2 keys) to product in DB (depends on 2a, 2b)

### Phase 3: AI Generation Pipeline (3a → 3b → 3c → 3d sequential)

- [ ] 3a. Multi-LLM content brief: query Claude, Gemini, xAI with snapshot context, synthesize into a content brief stored per product; include performance summary field (empty at first)
- [ ] 3b. OpenClaw bulk generation: Oban job calls OpenClaw API with content brief → N variants per platform, N blog drafts, N video scripts; store all as draft records with angle/type label
- [ ] 3c. Multi-model ranking: Oban job calls each smart model to score and critique every draft; store per-model scores + critique; compute composite score; promote top N per type to review queue (depends on 3b)
- [ ] 3d. Script gate: second Oban ranking pass on video scripts only; scripts below threshold are archived; approved scripts enqueue video production jobs (depends on 3c)

### Phase 4: Short-form Publishing (4a–4d are independent of each other, depend on Phase 3)

- [ ] 4a. Twitter/X connector: OAuth2 client, post text + image, retry on failure, record post ID
- [ ] 4b. LinkedIn connector: OAuth2 client, post to profile/page, retry on failure
- [ ] 4c. Reddit connector: OAuth2 client, submit text post to configured subreddit
- [ ] 4d. Facebook/Instagram connector: Meta Graph API client, post text + image
- [ ] 4e. Oban scheduler: per-product, per-platform job that picks next approved draft and calls the right connector (depends on 4a–4d)

### Phase 5: Blog Publishing (depends on Phase 3)

- [ ] 5a. Blog article R2 storage: write markdown to R2 with stable URL on approval
- [ ] 5b. Webhook delivery: Oban job that POSTs to each registered endpoint, HMAC-signed, with retry
- [ ] 5c. Delivery status tracking: record success/failure per endpoint per article

### Phase 6: Video Production (6a–6c are independent, 6d–6f sequential; all depend on Phase 3 script gate)

- [ ] 6a. ElevenLabs voiceover: HTTP client, send script text, receive and store MP3 in R2 keyed to script ID
- [ ] 6b. Playwright screen recorder: headless browser navigates live site, records walkthrough as video, stores in R2
- [ ] 6c. HeyGen talking head: API client, submit script + avatar config, poll for completion, store in R2
- [ ] 6d. Remotion Node.js sidecar: small Node/Bun service that accepts render jobs via HTTP; Elixir sends script + asset URLs, sidecar assembles and returns video URL
- [ ] 6e. FFmpeg final encode: normalize format, burn in any overlays, produce final MP4 in R2 (depends on 6d)
- [ ] 6f. YouTube upload: OAuth2 client with encrypted token refresh, upload video with AI-generated title/description/tags/thumbnail, record video ID (depends on 6e)
- [ ] 6g. Video production Oban workflow: orchestrate all steps, track per-step status in DB, retry on failure, pause + alert after 3 failures (depends on 6a–6f)

### Phase 7: Metrics & Feedback Loop (depends on Phase 4, 5, 6 publishing)

- [ ] 7a. YouTube Analytics poller: Oban scheduled job pulls views, watch time, retention curve, engagement at 24h/7d/30d after upload; store in metrics table
- [ ] 7b. Social metrics poller: per-platform jobs pull likes/shares/impressions/clicks for each published post at same intervals
- [ ] 7c. Retention curve analyzer: detects high-engagement segments (above threshold, above min duration), creates clip suggestions with timestamp range + suggested title
- [ ] 7d. Clip production job: when a clip is approved, cut the source video using FFmpeg and enqueue for short-form publishing
- [ ] 7e. Content brief feedback writer: Oban job that runs after each metrics sync, computes top-performing angles/formats, appends performance summary to product's content brief

### Phase 8: Dashboard (depends on Phases 1–7)

- [ ] 8a. Products list + detail LiveView
- [ ] 8b. Draft review queue LiveView (all variants, composite + per-model scores, critiques, approve/reject)
- [ ] 8c. Script ranking LiveView (video scripts ranked with gate threshold visible)
- [ ] 8d. Schedule + publishing history LiveView with live metrics inline
- [ ] 8e. Video pipeline status board LiveView (per-step progress)
- [ ] 8f. Performance dashboard: trends, retention curves, clip flags
- [ ] 8g. Clip queue LiveView (approve flagged segments for short-form production)
- [ ] 8h. Mobile responsiveness + accessibility pass

---

## Parallelization Notes

- Phase 1 items 1a, 1b, 1c can be built simultaneously by separate agents
- Phase 2 items 2a and 2b (repo vs site ingestion) are fully independent
- Phase 4 items 4a–4d (social connectors) are all independent — one agent per connector
- Phase 6 items 6a, 6b, 6c (voiceover, screen recording, talking head) are independent until assembly
- Phase 7 items 7a and 7b (YouTube vs social metrics) are independent
- Phase 8 LiveView pages can all be built in parallel once data layers exist

---

## Out of Scope

- Native mobile apps — web-only (mobile-responsive LiveView)
- TikTok — API is restricted; add later if access becomes available
- Paid ad management — this is organic content only
- Comment monitoring / social listening — publish-only for now
- Multi-user / team accounts — solo founder only at launch
- Billing / subscriptions — internal tool, no paywall

---

## Architecture Decisions

- **Remotion runtime:** Node.js sidecar service running alongside the Elixir app. Elixir sends render jobs via HTTP. Simple, runs on existing servers.
- **YouTube OAuth tokens:** Encrypted in PostgreSQL. App handles token refresh automatically. Consistent with needing autonomous operation.
- **Reddit config:** Default subreddits stored per product in the publishing target config. AI can suggest a different subreddit per draft at generation time.
- **Blog webhook payload (minimal):** POST body contains `r2_url`, `title`, `slug`, `published_at`, `product_slug`, `tags[]`, `seo_description`. Receiver fetches markdown from R2 using the URL. No full content inline.
- **HeyGen:** Avatar and voice selection will be configurable per product. Evaluate cost per render before enabling by default — gate behind a feature flag.
