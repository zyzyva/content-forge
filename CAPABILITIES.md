# Content Forge - Capability Document

This document provides comprehensive capabilities of the **content-forge** codebase.

**Last verified against:** `afc9e17` (phase-2, 2026-03-28)

---

## Quick Reference

| Attribute | Value |
|-----------|-------|
| **Type** | Web app + background worker |
| **Framework** | Phoenix 1.8.3 with LiveView 1.1.0 |
| **Language** | Elixir ~1.15 |
| **Database** | PostgreSQL (Ecto 3.13) |
| **Job Queue** | Oban 2.18 |
| **Storage** | Cloudflare R2 (via ExAws) |
| **HTTP Server** | Bandit 1.5 |

---

## Feature Matrix by Category

| Category | Implemented | Notes |
|----------|:-----------:|-------|
| **API Key Authentication** | Y | Bearer token, active/inactive per key |
| **Product Management** | Y | CRUD, voice profiles, publishing targets |
| **Content Ingestion** | Y | Website crawling + GitHub repo cloning |
| **Competitor Intelligence** | Y | Scrape posts, synthesize insights via AI |
| **Content Brief Generation** | Y | AI-generated briefs, versioned rewrites |
| **Bulk Content Generation** | Y | Multi-model, multi-platform, multi-angle |
| **Multi-Model Scoring** | Y | Claude, Gemini, xAI ranking with calibration |
| **Draft Review Workflow** | Y | Approve/reject with status tracking |
| **Social Publishing** | Y | Twitter, LinkedIn, Reddit, Facebook, Instagram |
| **Blog Publishing** | Y | Webhook delivery with retry logic |
| **Video Production Pipeline** | Y | Script → voiceover → recording → avatar → upload |
| **YouTube Integration** | Y | Upload, analytics, retention curves |
| **Performance Metrics** | Y | Predicted vs actual engagement, scoreboard |
| **Model Calibration** | Y | Per-model, per-platform, per-angle bias tracking |
| **Clip Flagging** | Y | Auto-detect high-engagement video segments |
| **Optimal Scheduling** | Y | Hour + day-of-week engagement windows |
| **Winner Repurposing** | Y | Auto-generate variants of top-performing drafts |
| **LiveView Dashboard** | Y | 7 real-time pages |
| **REST API** | Y | Full API with Bearer token auth |
| **Object Storage** | Y | R2 for snapshots, images, video assets |

---

## 1. AUTHENTICATION & API KEY MANAGEMENT

### 1.1 API Key Authentication
- [ ] Generate 32-byte random API keys (Base64 encoded)
- [ ] Activate / deactivate individual keys
- [ ] Authenticate API requests via `Authorization: Bearer {key}` header
- [ ] Return 401 on missing or inactive keys

**Implementation:**
- `ContentForge.Accounts` - `lib/content_forge/accounts.ex`
- `ContentForgeWeb.Plugs.ApiAuth` - `lib/content_forge_web/plugs/api_auth.ex`
- Schema: `ContentForge.Accounts.ApiKey` (fields: `key`, `label`, `active`)

---

## 2. PRODUCT MANAGEMENT

### 2.1 Product CRUD
- [ ] Create, read, update, delete products
- [ ] Store product `name`, `repo_url`, `site_url`, `voice_profile`, `publishing_targets`
- [ ] `publishing_targets` stores per-platform credentials as a map

### 2.2 Blog Webhooks
- [ ] Associate multiple webhook URLs per product
- [ ] HMAC-signed delivery
- [ ] Activate / deactivate individual webhooks

### 2.3 Product Snapshots
- [ ] Track `repo` and `site` snapshot types
- [ ] Store R2 keys and token counts per snapshot
- [ ] Get latest snapshot by type for a product

**Implementation:**
- `ContentForge.Products` - `lib/content_forge/products.ex`
- Schemas: `Product`, `BlogWebhook`, `ProductSnapshot` - `lib/content_forge/products/`
- API: `ProductController` - `lib/content_forge_web/controllers/product_controller.ex`
- Routes: `GET/POST/PATCH/DELETE /api/v1/products`, `GET /api/v1/products/:id`

---

## 3. CONTENT INGESTION

### 3.1 Website Crawling
- [ ] Crawl product site URLs with configurable page depth limit (default 10 pages)
- [ ] Extract page title, body text, meta description, meta keywords via HTML parsing
- [ ] Follow internal links up to configured max pages
- [ ] Store each page as JSON in R2 with unique keys
- [ ] Create product snapshot record with all R2 keys

### 3.2 GitHub Repository Ingestion
- [ ] Shallow-clone repos (`git clone --depth 1`)
- [ ] Extract README, CHANGELOG, LICENSE, `docs/`, `lib/`, `src/` content
- [ ] Estimate token count (~1 token per 4 characters)
- [ ] Truncate to configurable max tokens (default 50,000)
- [ ] Store combined content as text file in R2
- [ ] Create snapshot with token count and R2 key

**Implementation:**
- `ContentForge.Jobs.SiteCrawler` - `lib/content_forge/jobs/site_crawler.ex`
- `ContentForge.Jobs.RepoIngestion` - `lib/content_forge/jobs/repo_ingestion.ex`
- Queue: `:ingestion`, max 3 attempts
- Dependencies: Req (HTTP), Floki (HTML parsing), System.cmd (git)

---

## 4. COMPETITOR INTELLIGENCE

### 4.1 Competitor Account Tracking
- [ ] Track competitor social accounts by platform and handle
- [ ] Supported platforms: twitter, linkedin, instagram, youtube, reddit, facebook
- [ ] Activate / deactivate individual competitor accounts

### 4.2 Competitor Post Scraping
- [ ] Fetch posts for all active competitor accounts for a product
- [ ] Scrape via Apify (mock fallback available in dev)
- [ ] Calculate per-account average engagement
- [ ] Score each post relative to its account's average
- [ ] Store posts with: content, URL, likes, comments, shares, engagement score

### 4.3 Competitive Intelligence Synthesis
- [ ] Analyze top-performing competitor posts with AI
- [ ] Extract trending topics, winning formats, effective hooks
- [ ] Store synthesized intel with source count
- [ ] Auto-schedule synthesis after scraping completes (5s delay)
- [ ] Expose latest intel via REST API

**Implementation:**
- `ContentForge.Jobs.CompetitorScraper` - `lib/content_forge/jobs/competitor_scraper.ex`
- `ContentForge.Jobs.CompetitorIntelSynthesizer` - `lib/content_forge/jobs/competitor_intel_synthesizer.ex`
- `ContentForge.Products` - competitor account/post/intel CRUD functions
- Schemas: `CompetitorAccount`, `CompetitorPost`, `CompetitorIntel` - `lib/content_forge/products/`
- Queue: `:competitor`, max 3 attempts
- API: `CompetitorController` - `lib/content_forge_web/controllers/competitor_controller.ex`
- Routes: `GET/POST/PATCH/DELETE /api/v1/products/:id/competitors`, `GET /api/v1/products/:id/competitor-intel`

---

## 5. CONTENT BRIEF GENERATION

### 5.1 Initial Brief Creation
- [ ] Generate content brief from product voice profile + site/repo snapshot + competitor intel
- [ ] AI-generated, versioned (starting at version 1)
- [ ] Store content, model used, snapshot reference, competitor intel reference

### 5.2 Brief Versioning and Rewrites
- [ ] Trigger rewrite when performance data indicates content is underperforming
- [ ] Preserve version history in `BriefVersion` records
- [ ] Store rewrite reason per version
- [ ] Skip regeneration if current brief is recent and no force_rewrite flag

### 5.3 Brief Access
- [ ] Fetch latest brief for a product
- [ ] List all versions for a brief
- [ ] Expose brief via REST API endpoint

**Implementation:**
- `ContentForge.Jobs.ContentBriefGenerator` - `lib/content_forge/jobs/content_brief_generator.ex`
- `ContentForge.ContentGeneration` - brief CRUD functions
- Schemas: `ContentBrief`, `BriefVersion` - `lib/content_forge/content_generation/`
- Queue: `:content_generation`, max 3 attempts
- API Route: `GET /api/v1/products/:id/brief`

---

## 6. BULK CONTENT GENERATION

### 6.1 Draft Creation
- [ ] Create drafts for products across multiple platforms and content types
- [ ] Supported platforms: twitter, linkedin, reddit, facebook, instagram, blog, youtube
- [ ] Content types: post, blog, video_script
- [ ] Content angles: educational, entertaining, problem_aware, social_proof, humor, testimonial, case_study, how_to, listicle
- [ ] Track generating model, angle, raw response, image URL per draft

### 6.2 Bulk Generation via OpenClaw
- [ ] Trigger bulk generation job per product with configurable content type
- [ ] `OpenClawBulkGenerator` Oban worker handles generation queue
- [ ] API endpoint `POST /api/v1/products/:id/generate` to trigger

### 6.3 Draft Lifecycle
- [ ] Status progression: `draft` → `ranked` → `approved` / `rejected` → `published`
- [ ] Approve or reject drafts individually
- [ ] Create repurposed variants of drafts (tracks `repurposed_from` reference)
- [ ] Filter drafts by status, platform, content type

**Implementation:**
- `ContentForge.Jobs.OpenClawBulkGenerator` - `lib/content_forge/jobs/open_claw_bulk_generator.ex`
- `ContentForge.ContentGeneration` - draft CRUD, filtering, status transitions
- Schema: `ContentForge.ContentGeneration.Draft` - `lib/content_forge/content_generation/draft.ex`
- API: `DraftController` - `lib/content_forge_web/controllers/draft_controller.ex`
- Routes: `GET/POST /api/v1/products/:id/drafts`, `POST /api/v1/products/:id/generate`, `POST /api/v1/drafts/:id/approve`, `POST /api/v1/drafts/:id/reject`

---

## 7. MULTI-MODEL SCORING & RANKING

### 7.1 Three-Model Scoring
- [ ] Score drafts with Claude, Gemini, and xAI simultaneously
- [ ] Score dimensions: accuracy (0-10), SEO (0-10), EEV/entertainment-education-value (0-10)
- [ ] Compute composite score (average of all dimensions and models)
- [ ] Enforce unique score per [draft, model] pair

### 7.2 Ranking and Promotion
- [ ] Promote top N drafts to `ranked` status (default: top 3 per content type)
- [ ] Archive previously ranked drafts that fall out of top N
- [ ] Apply model calibration bias adjustments during ranking

### 7.3 Score Access
- [ ] Fetch scores for a specific draft
- [ ] Fetch score by draft + model name
- [ ] Compute composite scores from stored per-model scores
- [ ] API endpoint `POST /api/v1/drafts/:id/score` and `GET` score retrieval

**Implementation:**
- `ContentForge.Jobs.MultiModelRanker` - `lib/content_forge/jobs/multi_model_ranker.ex`
- `ContentForge.ContentGeneration` - score CRUD, composite calculation
- Schema: `ContentForge.ContentGeneration.DraftScore` - `lib/content_forge/content_generation/draft_score.ex`
- Queue: `:content_generation`, max 3 attempts

---

## 8. SOCIAL PUBLISHING

### 8.1 Twitter / X
- [ ] Post tweets (max 280 characters)
- [ ] Attach media via Twitter's 3-step upload flow (INIT → APPEND → FINALIZE)
- [ ] Retry on failure with 5-second delays (configurable max retries, default 3)
- [ ] Credentials: `twitter_access_token`, `twitter_api_key`

### 8.2 LinkedIn
- [ ] Share updates to personal profile or organization page
- [ ] Credentials: `linkedin_access_token`, `linkedin_person_id`, `linkedin_organization_id`

### 8.3 Facebook
- [ ] Post to Facebook pages
- [ ] Attach image by URL
- [ ] Credentials: `facebook_access_token`, `facebook_page_id`

### 8.4 Instagram
- [ ] Post to Instagram business accounts via Facebook Graph API
- [ ] Credentials: `facebook_access_token`, `instagram_account_id`

### 8.5 Reddit
- [ ] Submit posts to subreddits
- [ ] Credentials: `reddit_access_token`, subreddit configured in options

### 8.6 Publisher Orchestration
- [ ] Find next approved draft for a platform automatically
- [ ] Pull credentials from `product.publishing_targets`
- [ ] Consult engagement metrics to post at optimal time windows
- [ ] Record published post with `platform_post_id` and `platform_post_url`
- [ ] Transition draft status to `published` on success

**Implementation:**
- `ContentForge.Publishing.Twitter` - `lib/content_forge/publishing/twitter.ex`
- `ContentForge.Publishing.LinkedIn` - `lib/content_forge/publishing/linkedin.ex`
- `ContentForge.Publishing.Facebook` - `lib/content_forge/publishing/facebook.ex`
- `ContentForge.Publishing.Reddit` - `lib/content_forge/publishing/reddit.ex`
- `ContentForge.Jobs.Publisher` - `lib/content_forge/jobs/publisher.ex`
- `ContentForge.Jobs.PublishingScheduler` - `lib/content_forge/jobs/publishing_scheduler.ex`
- Schema: `ContentForge.Publishing.PublishedPost` - `lib/content_forge/publishing/published_post.ex`
- API: `ScheduleController` - `lib/content_forge_web/controllers/schedule_controller.ex`
- Routes: `POST/GET /api/v1/products/:id/schedule`

---

## 9. BLOG PUBLISHING

### 9.1 Webhook Delivery
- [ ] Deliver approved blog drafts to registered webhook URLs
- [ ] Sign payloads with HMAC secret
- [ ] Track delivery status: `pending` → `success` / `failed`
- [ ] Record delivery timestamp and error messages on failure

### 9.2 Retry Logic
- [ ] Retry failed deliveries via pending status
- [ ] Track all delivery attempts in `WebhookDelivery` records

**Implementation:**
- `ContentForge.Jobs.BlogPublisher` - `lib/content_forge/jobs/blog_publisher.ex`
- Schema: `ContentForge.Publishing.WebhookDelivery` - `lib/content_forge/publishing/webhook_delivery.ex`
- Queue: `default`, max 3 attempts

---

## 10. VIDEO PRODUCTION PIPELINE

### 10.1 Video Job Lifecycle
- [ ] Create video jobs linked to approved `video_script` drafts
- [ ] Status workflow: `script_approved` → `voiceover_done` → `recording_done` → `avatar_done` → `assembled` → `uploaded`
- [ ] Failed and paused states for error handling / manual holds
- [ ] Store per-step R2 asset keys (voiceover, recording, avatar, assembled)
- [ ] Feature flag per video job

### 10.2 Video Production Orchestration
- [ ] `VideoProducer` Oban worker coordinates each pipeline step
- [ ] `ScriptGate` worker gates scripts before production begins
- [ ] Pause and resume individual video jobs

### 10.3 YouTube Upload & Analytics
- [ ] Upload completed videos to YouTube
- [ ] Fetch watch-time retention curves per video
- [ ] Store retention curve data for clip analysis
- [ ] Credentials: YouTube API token stored in `publishing_targets`

**Implementation:**
- `ContentForge.Jobs.VideoProducer` - `lib/content_forge/jobs/video_producer.ex`
- `ContentForge.Jobs.ScriptGate` - `lib/content_forge/jobs/script_gate.ex`
- `ContentForge.Publishing.YouTube` - `lib/content_forge/publishing/youtube.ex`
- Schema: `ContentForge.Publishing.VideoJob` - `lib/content_forge/publishing/video_job.ex`
- API: `MetricsController.video_retention/2` - `GET /api/v1/videos/:id/retention`

---

## 11. PERFORMANCE METRICS & FEEDBACK LOOP

### 11.1 Scoreboard
- [ ] Track predicted AI composite score vs actual platform engagement per draft
- [ ] Calculate delta (predicted minus actual, normalized to -10..10 scale)
- [ ] Classify outcomes: `winner` (delta > 2), `loser` (delta < -2), `pending`
- [ ] Create scoreboard entries from drafts with pre-computed AI scores

### 11.2 Model Calibration
- [ ] Track average prediction bias per [model, product, platform, angle]
- [ ] Incrementally add samples with running average calculation
- [ ] Classify model as `:over_predicts`, `:under_predicts`, or `:calibrated`
- [ ] Upsert calibration records (unique per model + product + platform + angle)
- [ ] Feed calibration data into `MultiModelRanker` for bias-adjusted ranking

### 11.3 Engagement Analytics
- [ ] Calculate rolling average engagement per product
- [ ] Identify hot content (high-performing posts in recent window)
- [ ] Identify posts needing replies (high engagement, no reply)
- [ ] Compute optimal posting windows by hour-of-day (0-23) and day-of-week (1-7)
- [ ] Engagement weighting: comments = 2x, shares = 3x vs likes

### 11.4 Brief Rewrite Triggering
- [ ] `should_trigger_rewrite?/1` evaluates scoreboard to decide if content strategy needs refresh
- [ ] Feeds back into `ContentBriefGenerator` with performance summary

**Implementation:**
- `ContentForge.Metrics` - `lib/content_forge/metrics.ex`
- `ContentForge.Jobs.MetricsPoller` - `lib/content_forge/jobs/metrics_poller.ex`
- Schemas: `ScoreboardEntry`, `ModelCalibration` - `lib/content_forge/metrics/`
- API: `MetricsController` - `lib/content_forge_web/controllers/metrics_controller.ex`
- Routes: `GET /api/v1/products/:id/scoreboard`, `/calibration`, `/metrics`, `/hot`, `/needs-reply`

---

## 12. CLIP FLAGGING

### 12.1 Automatic Spike Detection
- [ ] Parse YouTube retention curve data to find engagement spikes
- [ ] Identify segments where engagement is >20% above video average
- [ ] Classify spike type: `:viral` (>10% engagement rate), `:high_engagement` (>5%), `:notable`
- [ ] Auto-generate clip title as "Clip at {timestamp}"

### 12.2 Manual Clip Creation
- [ ] Create clip flags via API with explicit start/end seconds
- [ ] Store suggested title, segment views, engagement rate, retention curve slice
- [ ] Approve individual clip flags

### 12.3 Clip API
- [ ] `POST /api/v1/videos/:id/clip` - Create clip flag from retention data
- [ ] Batch creation from retention analysis
- [ ] List all clips for a video

**Implementation:**
- `ContentForge.Metrics.ClipFlag` - `lib/content_forge/metrics/clip_flag.ex`
- `ContentForge.Metrics.ClipFlag.from_youtube_retention/3` - bulk spike detection
- API: `MetricsController.clip/2` - `lib/content_forge_web/controllers/metrics_controller.ex`

---

## 13. WINNER REPURPOSING ENGINE

### 13.1 Variant Generation
- [ ] Identify top-performing (winner) drafts
- [ ] Auto-generate repurposed variants targeting different platforms, angles, or content types
- [ ] Track repurposing lineage via `repurposed_from` reference on drafts
- [ ] List all repurposed variants of a source draft

**Implementation:**
- `ContentForge.Jobs.WinnerRepurposingEngine` - `lib/content_forge/jobs/winner_repurposing_engine.ex`
- `ContentForge.ContentGeneration.create_repurposed_draft/2`

---

## 14. IMAGE GENERATION

- [ ] Generate images for social posts
- [ ] Store generated images in R2
- [ ] Associate image URL with draft record

**Implementation:**
- `ContentForge.Jobs.ImageGenerator` - `lib/content_forge/jobs/image_generator.ex`

---

## 15. OBJECT STORAGE (CLOUDFLARE R2)

- [ ] Upload objects to R2 bucket
- [ ] Download objects from R2 bucket
- [ ] Delete objects from R2 bucket
- [ ] Generate public R2 URLs for assets

**Implementation:**
- `ContentForge.Storage` - `lib/content_forge/storage.ex`
- Configured via `R2_BUCKET` (default: "content-forge") and `R2_REGION` (default: "auto") env vars
- Backed by `ExAws` S3-compatible client

---

## 16. BACKGROUND JOB PROCESSING (OBAN)

### 16.1 Queues
- [ ] `default` queue — 10 workers (publishing, scheduling)
- [ ] `events` queue — 50 workers (high-throughput events)
- [ ] `ingestion` queue — site/repo crawling jobs
- [ ] `competitor` queue — competitor scraping and synthesis
- [ ] `content_generation` queue — brief generation, ranking jobs

### 16.2 All Workers
| Worker | Queue | Purpose |
|--------|-------|---------|
| `SiteCrawler` | ingestion | Crawl product website |
| `RepoIngestion` | ingestion | Clone and ingest GitHub repo |
| `CompetitorScraper` | competitor | Scrape competitor posts |
| `CompetitorIntelSynthesizer` | competitor | Synthesize AI insights |
| `ContentBriefGenerator` | content_generation | Generate/rewrite content brief |
| `OpenClawBulkGenerator` | content_generation | Bulk draft generation |
| `MultiModelRanker` | content_generation | Score and rank drafts |
| `ImageGenerator` | default | Generate post images |
| `ScriptGate` | default | Gate video scripts |
| `VideoProducer` | default | Orchestrate video pipeline |
| `Publisher` | default | Publish to social platforms |
| `PublishingScheduler` | default | Schedule publishing windows |
| `BlogPublisher` | default | Deliver blog webhook |
| `MetricsPoller` | default | Fetch platform engagement data |
| `WinnerRepurposingEngine` | default | Repurpose winning content |

---

## 17. WEB UI / LIVEVIEW DASHBOARD

All LiveView pages require no authentication at the router level (session-based auth via `live_session` hooks planned).

### 17.1 Dashboard Pages
- [ ] `/dashboard` — Navigation hub with cards linking to all sections (`DashboardLive`)
- [ ] `/dashboard/products` — Browse all products (`Products.ListLive`)
- [ ] `/dashboard/products/:id` — Product detail: snapshots, competitors, briefs (`Products.DetailLive`)
- [ ] `/dashboard/drafts` — Review drafts, approve/reject workflow (`Drafts.ReviewLive`)
- [ ] `/dashboard/schedule` — Publishing calendar and scheduling (`Schedule.Live`)
- [ ] `/dashboard/video` — Video pipeline status board (`Video.StatusLive`)
- [ ] `/dashboard/performance` — Engagement metrics, scoreboard, model calibration (`Performance.DashboardLive`)
- [ ] `/dashboard/clips` — Approve flagged video clip segments (`Clips.QueueLive`)

**Implementation:**
- `lib/content_forge_web/live/dashboard/` - all LiveView modules
- `ContentForgeWeb.Live.Dashboard.Components` - shared dashboard UI components

---

## 18. REST API

All API routes are under `/api/v1/` and require `Authorization: Bearer {key}`.

### 18.1 Products
| Method | Path | Action |
|--------|------|--------|
| GET | `/products` | List all products |
| GET | `/products/:id` | Get product |
| POST | `/products` | Create product |
| PATCH | `/products/:id` | Update product |
| DELETE | `/products/:id` | Delete product |

### 18.2 Competitors
| Method | Path | Action |
|--------|------|--------|
| GET | `/products/:id/competitors` | List competitor accounts |
| GET | `/products/:id/competitors/:cid` | Get competitor |
| POST | `/products/:id/competitors` | Add competitor |
| PATCH | `/products/:id/competitors/:cid` | Update competitor |
| DELETE | `/products/:id/competitors/:cid` | Remove competitor |
| GET | `/products/:id/competitor-intel` | Get synthesized intel |

### 18.3 Drafts & Generation
| Method | Path | Action |
|--------|------|--------|
| GET | `/products/:id/drafts` | List drafts |
| POST | `/products/:id/drafts` | Create draft |
| POST | `/products/:id/generate` | Trigger bulk generation |
| GET | `/products/:id/brief` | Get content brief |
| GET | `/drafts/:id` | Get draft |
| POST | `/drafts/:id/approve` | Approve draft |
| POST | `/drafts/:id/reject` | Reject draft |
| POST | `/drafts/:id/score` | Score draft |

### 18.4 Publishing & Scheduling
| Method | Path | Action |
|--------|------|--------|
| POST | `/products/:id/schedule` | Schedule publishing |
| GET | `/products/:id/schedule` | Get schedule |
| GET | `/products/:id/engagement-metrics` | Get engagement windows |
| POST | `/products/:id/engagement-metrics/refresh` | Recalculate metrics |

### 18.5 Metrics
| Method | Path | Action |
|--------|------|--------|
| GET | `/products/:id/scoreboard` | Performance scoreboard |
| GET | `/products/:id/calibration` | Model calibration data |
| GET | `/products/:id/metrics` | Engagement metrics |
| GET | `/products/:id/hot` | Hot/high-performing content |
| GET | `/products/:id/needs-reply` | High-engagement posts needing reply |
| GET | `/videos/:id/retention` | YouTube retention curve |
| POST | `/videos/:id/clip` | Create clip flag |

---

## 19. DATA MODELS

### Schemas

| Schema | Key Fields | Purpose |
|--------|------------|---------|
| `ApiKey` | key, label, active | API authentication |
| `Product` | name, repo_url, site_url, voice_profile, publishing_targets | Core product entity |
| `BlogWebhook` | url, hmac_secret, active | Blog delivery endpoints |
| `ProductSnapshot` | snapshot_type, r2_keys, token_count | Crawled site/repo content |
| `CompetitorAccount` | platform, handle, url, active | Tracked competitor accounts |
| `CompetitorPost` | content, post_url, engagement_score, posted_at | Individual competitor posts |
| `CompetitorIntel` | summary, trending_topics, winning_formats, effective_hooks | Synthesized competitive analysis |
| `ContentBrief` | version, content, model_used, performance_summary | AI-generated content strategy |
| `BriefVersion` | version, content, rewrite_reason | Brief version history |
| `Draft` | content, platform, content_type, angle, status, image_url | Content draft for review/publishing |
| `DraftScore` | model_name, accuracy_score, seo_score, eev_score, composite_score | Per-model draft scores |
| `PublishedPost` | platform, platform_post_id, platform_post_url, engagement_data | Published content record |
| `EngagementMetric` | platform, hour_of_day, day_of_week, avg_engagement | Time-based engagement patterns |
| `WebhookDelivery` | status, delivered_at, error | Blog webhook delivery tracking |
| `VideoJob` | status, per_step_r2_keys, feature_flag | Video pipeline state |
| `ScoreboardEntry` | composite_ai_score, actual_engagement_score, delta, outcome | Predicted vs actual performance |
| `ModelCalibration` | model_name, platform, angle, avg_score_delta, sample_count | AI model bias tracking |
| `ClipFlag` | start_seconds, end_seconds, segment_engagement_rate, retention_curve | High-engagement video segments |

---

## 20. EXTERNAL INTEGRATIONS

| Service | Purpose | Module |
|---------|---------|--------|
| PostgreSQL | Primary database | `ContentForge.Repo` |
| Cloudflare R2 | Asset and snapshot storage | `ContentForge.Storage` |
| Twitter API v2 | Post tweets, upload media | `ContentForge.Publishing.Twitter` |
| LinkedIn API | Share posts to profiles/orgs | `ContentForge.Publishing.LinkedIn` |
| Facebook Graph API | Post to pages, manage Instagram | `ContentForge.Publishing.Facebook` |
| Instagram Graph API | Post to business accounts | `ContentForge.Publishing.Facebook` (proxied) |
| Reddit API | Submit posts to subreddits | `ContentForge.Publishing.Reddit` |
| YouTube Data API | Upload videos, fetch retention | `ContentForge.Publishing.YouTube` |
| Apify | Scrape competitor social posts | `ContentForge.Jobs.CompetitorScraper` |
| Anthropic Claude | Content generation and scoring | AI model placeholder |
| Google Gemini | Draft scoring (multi-model) | AI model placeholder |
| xAI Grok | Draft scoring (multi-model) | AI model placeholder |
| Swoosh / Email | Transactional email delivery | `ContentForge.Mailer` |
| Oban | Background job queue | All `ContentForge.Jobs.*` |

---

## 21. ENVIRONMENT VARIABLES

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `DATABASE_URL` | Prod | — | PostgreSQL connection string |
| `SECRET_KEY_BASE` | Prod | — | Session encryption key |
| `PHX_HOST` | Prod | example.com | Public hostname |
| `PORT` | No | 4000 | HTTP port |
| `POOL_SIZE` | No | 10 | DB connection pool size |
| `PHX_SERVER` | No | — | Enable HTTP server |
| `APIFY_TOKEN` | No | — | Apify API token for competitor scraping |
| `R2_BUCKET` | No | content-forge | Cloudflare R2 bucket name |
| `R2_REGION` | No | auto | R2 region |

---

## Document Revision History

| Date | Version | Git Commit | Changes |
|------|---------|------------|---------|
| 2026-03-28 | 1.0 | afc9e17 | Initial documentation of all 9 phases |
