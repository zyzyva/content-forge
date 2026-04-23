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
- [ ] A product has: name, repo URL (optional), site URL (optional), voice profile (text, required before first generation run), per-platform posting frequency, and a list of enabled publishing targets
- [ ] Products can be created, read, updated, and deleted via LiveView UI
- [ ] Products can be created, read, updated, and deleted via REST API
- [ ] Each product has a publishing target config: each platform (YouTube, LinkedIn, Twitter/X, Reddit, Facebook/Instagram, blog) has enabled/disabled toggle and a cadence (e.g. 3x/week, 1x/month)
- [ ] Products are stored in PostgreSQL
- [ ] Each product can register one or more blog webhook endpoints (URL + optional HMAC secret) for blog delivery
- [ ] Voice profile is a required text field on the product. Generation runs are blocked until a voice profile is set. The voice profile defines tone, vocabulary, personality, and communication style for all content generated for that product.
- [ ] The content brief always includes the voice profile as context for both generation (OC) and ranking (smart models). Ranking models should evaluate voice consistency as part of their scoring.
- [ ] If performance data shows content that drifts from the voice profile is outperforming on-brand content, the brief rewrite must flag this explicitly ("off-brand content is outperforming -- consider updating the voice profile") rather than silently shifting tone.

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
- Stage 0 (Competitor intelligence): Before generating, pull recent top-performing content from competitor accounts in the same niche (via Apify/content intelligence). Feed trending topics, formats, hooks, and engagement patterns into the content brief. "Competitors are getting 5x engagement on before/after posts this month" directly steers what OC generates.
- Stage 1 (Content brief -- living strategy doc): On first run, query Claude, Gemini, and xAI with the product snapshot and competitor intelligence asking what makes high-ranking content in this niche. Synthesize into a content brief. On subsequent runs, the brief is rewritten (not appended to) by a smart model that receives: the product snapshot, competitor intel, the full performance scoreboard (see Feature 7), and the previous brief. The rewrite identifies which angles/formats/hooks are working, which are underperforming, and what to try next. This is the system's "program.md" -- the strategic document that steers all generation.
- Stage 2 (Bulk generation via OpenClaw): OpenClaw generates N variants of each content type per run -- for example, 20 Twitter posts, 10 LinkedIn posts, 5 blog drafts, 10 video scripts. Each variant takes a different angle (educational, entertaining, problem-aware, social proof, etc.). Every batch must include at least one explicitly humorous/funny variant per content type -- humor is a required angle, not optional. OpenClaw receives the full content brief including performance insights so it biases toward what's working.
- Stage 3 (Multi-model ranking with performance context): Each smart model independently scores every draft on accuracy (0-10), SEO relevance (0-10), and entertainment/education value (0-10). Critically, each model also receives the performance scoreboard showing: how similar past content actually performed, how accurate that model's previous scores were vs real engagement (calibration data), and which angles/formats are currently outperforming. This lets models learn from their own prediction errors. Scores are averaged across models. Each model also writes a short critique that references performance data ("this angle has historically underperformed for this product" or "similar hooks drove 3x engagement last month"). Top-scoring drafts per content type advance; the rest are archived.
- Stage 3.5 (Image generation -- required for social posts): Every social post that advances past ranking gets an AI-generated image tailored to the content. The image prompt is derived from the post text and product branding by a smart model. Images are generated via AI image generation (Flux/DALL-E/etc), stored in R2, and attached at publish time. This is not optional -- posts with images dramatically outperform text-only on every platform.
- Stage 4 (Script gate -- video only): Before any video is produced, the top-ranked scripts go through a second ranking pass focused specifically on visual storytelling, hook strength, and retention. Only scripts clearing a configurable threshold proceed to video production. This gate prevents spending on HeyGen/ElevenLabs for weak scripts.
- Stage 5 (Winner repurposing): When performance metrics confirm a published piece is a winner (above rolling average), automatically queue cross-platform variants. A winning Twitter post spawns LinkedIn, Reddit, and blog expansion drafts. A winning blog post spawns social post variants and a video script. Repurposed variants enter Stage 2 with a "repurposed_from" link to the original and go through normal ranking. This is how one hit becomes 10 pieces of content.

Acceptance criteria:
- [x] Content brief generation queries at least 2 smart models and stores the synthesized brief per product with a timestamp and version number
- [ ] On subsequent runs (when performance data exists), the content brief is fully rewritten by a smart model that receives: product snapshot, performance scoreboard, and previous brief. The rewrite replaces the previous brief (old versions are kept in a brief_versions table for history)
- [ ] When ranking drafts, each smart model receives the performance scoreboard alongside the drafts, including that model's own calibration data (predicted score vs actual engagement for past content it scored)
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
- [ ] Competitor intelligence: configurable list of competitor social accounts per product. Before each generation run, an Oban job scrapes recent posts from competitor accounts (via Apify), extracts top-performing content by engagement, and summarizes trending topics/formats/hooks. Summary is included in the content brief.
- [ ] Image generation: every social post that passes ranking gets an AI-generated image. A smart model writes an image prompt from the post text + product branding. The image request is issued through the `ContentForge.MediaForge` HTTP client (Integration 1) against the Media Forge `/api/v1/generation/images` endpoint. Media Forge selects the underlying provider (Flux, DALL-E, or other) internally, stores the image in R2, and returns either a synchronous result carrying the storage URL or an async job id that Content Forge resolves by polling job status (webhook-based resolution lands separately under Phase 10.5). The resulting R2 URL is written onto the draft. Image generation runs as an Oban job in the `:content_generation` queue after ranking, before scheduling. If Media Forge is not configured on this deployment (no shared secret), the job logs the condition and leaves the draft without an image rather than writing a placeholder URL; downstream publishing treats a missing image as a blocker and the dashboard surfaces "Media Forge unavailable" for the affected product.
- [ ] Winner repurposing: when a published piece is labeled "winner" by the scoreboard, an Oban job automatically generates cross-platform variants (Twitter winner -> LinkedIn/Reddit/blog drafts, blog winner -> social posts + video script). Repurposed drafts have a repurposed_from field linking to the original and enter the normal ranking pipeline.
- [ ] POST /api/products/:id/competitors -- add/remove competitor accounts for a product
- [ ] GET /api/products/:id/competitor-intel -- retrieve latest competitor intelligence summary

---

### Feature 3.5: Competitor Content Monitoring

**Purpose:** Know what's working in the niche before generating content. Track competitor accounts, scrape their recent posts, identify top-performing formats and hooks, and feed that intelligence into the content brief.

Acceptance criteria:
- [ ] Each product has a list of competitor social accounts (platform + handle/URL)
- [ ] A scheduled Oban job (configurable cadence, default weekly) scrapes recent posts from each competitor account via Apify
- [ ] Posts are scored by engagement (likes, shares, comments relative to the account's average)
- [ ] A summary job synthesizes the top-performing competitor content into a "competitor intel" document: trending topics, winning formats, effective hooks, engagement patterns
- [ ] Competitor intel is stored per product with a timestamp and included in the content brief context
- [ ] Dashboard shows competitor content trends alongside your own performance
- [ ] Competitor accounts and intel are manageable via REST API

---

### Feature 4: Short-form Post Publishing

**Purpose:** Publish approved short-form posts to Twitter/X, LinkedIn, Reddit, and Facebook/Instagram.

Acceptance criteria:
- [x] Twitter/X: Post text (up to 280 chars) with image attachment via Twitter v2 API
- [x] LinkedIn: Post text + image to a personal profile or company page via LinkedIn API
- [x] Reddit: Submit a text post to a configured subreddit via Reddit API (image optional per subreddit rules)
- [x] Facebook/Instagram: Post text + image via Meta Graph API
- [x] All social posts include the AI-generated image from Stage 3.5 -- image is required, not optional
- [ ] Missing-image enforcement on social posts: when an approved social post draft has no image at publish time, the publisher does not call the platform client. Instead it logs "publish blocked: missing image" for that draft, marks the draft as blocked pending image generation, and the drafts queue and publishing schedule view in the dashboard show the draft with a distinct "blocked" label. A human (or a future automated retry) is expected to re-run image generation for the draft before it will publish. Non-social drafts (blog, video) are unaffected by this rule. (Ships under Phase 10.2b.)
- [x] Each connector retrieves its OAuth tokens / API keys from 1Password at runtime
- [x] A failed publish is retried via Oban (up to 3 attempts) and flagged if all retries fail
- [x] Published posts record the platform post ID, timestamp, and link
- [x] Post timing optimization: track engagement by hour-of-day and day-of-week per platform per product. The scheduler picks optimal posting windows based on historical performance. Falls back to configured cadence when insufficient data exists (fewer than 20 published posts).

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

**Stack:** ElevenLabs (voiceover audio), HeyGen (AI avatar talking head), Playwright (screen recording of live site), Remotion + Node.js sidecar (programmatic video composition). Final encoding and format normalization are delegated to Media Forge via the HTTP client (Integration 1); there is no local FFmpeg invocation inside Content Forge.

**Script-first design:** Scripts are generated and ranked in Feature 3 before any video production begins. Video production only triggers for scripts that pass the ranking threshold. Multiple script variants may be produced as separate videos if budget allows, or only the top 1-2 proceed.

Acceptance criteria:
- [ ] Video production job only starts when a script has passed the script gate (ranking score above threshold)
- [ ] Multiple scripts can be queued for production in parallel — each tracked as a separate video job
- [ ] ElevenLabs voiceover: script is sent to ElevenLabs, MP3 stored in R2 keyed to the script ID
- [ ] Playwright screen recorder: headless browser navigates the live site, records walkthrough as video, stored in R2
- [ ] HeyGen talking head: script + configured avatar submitted to HeyGen API, result polled and stored in R2
- [ ] Remotion sidecar assembles final video: intro slate, screen recording segments, talking head segments, outro, with voiceover laid over
- [ ] Final encoding and format normalization are performed by Media Forge via the `ContentForge.MediaForge` HTTP client (Integration 1). The Remotion-assembled video is handed off to Media Forge's video-render endpoint (single-output render for the YouTube path today; batch render is reserved for when per-platform renditions are added under Feature 11 or Phase 15). Media Forge may respond synchronously with a finished R2 key or asynchronously with a job identifier that Content Forge resolves by polling job status (webhook resolution arrives under Phase 10.5). The returned R2 key is recorded on the video job's per-step storage map under the final-encode step, and the video job transitions from `assembled` to `encoded`. If Media Forge is not configured on this deployment, the step logs "Media Forge unavailable" and the video job pauses at `assembled` with a dashboard-visible note rather than advancing to YouTube upload. No local FFmpeg invocation occurs inside Content Forge.
- [ ] Final video uploaded to YouTube with AI-generated title, description, tags, and thumbnail (from screenshot)
- [ ] YouTube OAuth tokens are encrypted in PostgreSQL; app refreshes automatically
- [ ] Each video job tracks per-step status in DB (script_approved / voiceover_done / recording_done / avatar_done / assembled / uploaded)
- [ ] Failed steps retry via Oban; a step failing 3 times pauses the job and alerts via dashboard
- [ ] Video production is gated behind a feature flag per product (HeyGen costs money)

---

### Feature 7: Performance Metrics & Feedback Loop

**Purpose:** Pull real performance data from each platform after content is published, surface what's working, flag videos for clipping, and feed insights back into the content brief so future generation improves over time.

**Why this matters:** Without feedback, the system is generating blind. With it, OpenClaw and the ranking models can learn which angles, hooks, and formats actually drive views, engagement, and conversions for each product. The feedback loop is inspired by Karpathy's AutoResearch pattern: measure, compare predicted vs actual, keep what works, discard what doesn't, and let the strategy evolve autonomously.

**Performance scoreboard:** A single table (`content_scoreboard`) that serves as the system's memory. Every published piece gets a row with: content_id, product_id, platform, angle, format, composite_ai_score (predicted), actual_engagement_score (measured), delta (predicted minus actual), per-model predicted scores, outcome label (winner/loser based on whether it beat the product's rolling average for that platform). This scoreboard is the primary input to content brief rewrites and ranking context.

**Model calibration:** Each smart model's scoring accuracy is tracked over time. If Claude consistently over-scores humor posts that flop, that signal is fed back to Claude on the next ranking round: "Your humor scores have been 2.3 points higher than actual performance on average. Adjust accordingly." This is the equivalent of AutoResearch's agent learning from its own failed experiments.

Acceptance criteria:
- [ ] Performance scoreboard table: content_id, product_id, platform, angle, format, composite_ai_score, actual_engagement_score, delta, per_model_scores (jsonb), outcome (winner/loser/pending), measured_at timestamps (24h/7d/30d)
- [ ] After each metrics sync, every published piece is labeled winner (above rolling average) or loser (below) for its platform
- [ ] Model calibration table: model_name, product_id, platform, angle, avg_score_delta, sample_count, last_updated. Updated after each metrics sync. Tracks how accurately each model's scores predict real engagement.
- [ ] YouTube Analytics: after a video is published, a scheduled job pulls views, watch time, average view duration, audience retention curve, likes, comments, and shares at 24h / 7d / 30d intervals
- [ ] Social metrics: for each published post, pull platform-native engagement metrics (likes, shares, impressions, replies, click-throughs) at the same intervals
- [ ] Blog metrics: if a blog webhook endpoint returns view/engagement data (optional), record it; otherwise track delivery status only
- [ ] Long-tail monitoring: a weekly job re-checks all published content regardless of age. If engagement changed significantly (configurable threshold, default 20%) since last measurement, the scoreboard is updated, winner/loser labels are recalculated, and the content is flagged as "resurfaced" for the next brief rewrite. This captures late viral hits, evergreen SEO content, and algorithm resurfaces.
- [ ] "Clip this" detection: videos where the audience retention curve shows a high-engagement segment (above configurable threshold for configurable duration) are automatically flagged with the timestamp range and a suggested short-form clip title
- [ ] Clipping queue: flagged video segments are added to a clip queue; each clip can be approved to produce a short-form video (Reels/Shorts/TikTok length) cut from the source
- [ ] Content brief rewrite trigger: after each metrics sync, if 5+ new measured pieces exist since the last rewrite, trigger a brief rewrite job. A smart model receives the full scoreboard, current brief, and product snapshot, and writes a new brief version replacing the old one.
- [ ] The scoreboard and model calibration data are available via API so OpenClaw and smart models can read them during generation and ranking
- [ ] GET /api/products/:id/scoreboard -- returns the performance scoreboard for a product, filterable by platform, angle, date range
- [ ] GET /api/products/:id/calibration -- returns per-model calibration data for a product
- [ ] Engagement spike alerts: a fast-cadence poller (hourly for first 24h after publishing) checks early engagement. If a post's engagement in the first hour exceeds 3x the product's average for that platform, flag it as "hot" on the dashboard. Hot posts are candidates for paid boosting or rapid follow-up content.
- [ ] Comment volume flagging: when a post accumulates comments above a configurable threshold (default 10), flag it as "needs attention" on the dashboard so the human can personally engage. Pull comment count alongside other metrics. Dashboard shows a dedicated "needs reply" queue.
- [ ] Winner repurposing trigger: when a piece is labeled "winner", automatically trigger cross-platform variant generation (see Stage 5 in Feature 3). Track which repurposed variants came from which original.
- [ ] Dashboard shows per-content performance: views/engagement trend, retention curve for videos, flag for clippable segments, winner/loser labels, hot/needs-reply flags
- [ ] GET /api/products/:id/metrics -- returns aggregated performance data per product
- [ ] GET /api/products/:id/hot -- returns currently hot posts (engagement spike in first 24h)
- [ ] GET /api/products/:id/needs-reply -- returns posts with high comment counts needing personal engagement
- [ ] GET /api/videos/:id/retention -- returns the retention curve data and any flagged clip segments

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

### Feature 10: SEO Quality Pipeline (inspired by seo-agi)

**Purpose:** Add SEO-optimized content generation features including AI Summary Nuggets for LLM citation, quality checklists, and GEO optimization.

Acceptance criteria:
- [ ] AI Summary Nugget: Every generated content (blog posts, social posts) includes a 200-character fact-dense block at the top designed for LLM citation (Perplexity, ChatGPT, Gemini)
- [ ] 28-Point Quality Checklist: Generated content is validated against a checklist including: information gain over top 10 Google results, core answer in first 150 words, fast-scan summary in first 200 words, JSON-LD schema matching page type, FAQ section with PAA questions, single H1 tag, title tag <60 chars, meta description <155 chars
- [ ] Original Research Block: Option to include a data experiment or first-hand observation section for E-E-A-T (Experience) signals
- [ ] Geo/LLM Optimization: Content includes entity-rich writing, RAG targeting for zero-volume long-tail queries, FAQ patterns optimized for AI citation
- [ ] Recursive Fact-Checking: Claims in generated content are validated against 2+ sources for entity consensus (optional, can be toggled per product)
- [ ] Quality Score Display: Each draft shows its quality checklist score (X/28) in the dashboard and API
- [ ] "Not For You" Block: Generated content includes an optional honest section telling readers when the product/service is a bad fit (trust signal)

---

### Feature 11: Product Asset Management

**Purpose:** Allow human-provided media (photos and videos from clients) to be uploaded, organized per product, and used as the foundation for content generation. Today Content Forge assumes AI generates images from scratch. In reality, the most valuable content for many products (contractors, restaurants, retail, real estate, events) is built around real photos of real work — before/after shots, finished jobs, satisfied customers, event highlights. This feature makes the human-provided media the starring input to the content pipeline, with AI writing the surrounding copy instead of fabricating visuals.

**Why this matters for agencies:** A marketing agency managing multiple client brands needs a place to store each client's media separately, kept organized, and made available to the content generation pipeline. Without this, agencies have to manually attach images to every draft in every platform, which defeats the point of automation.

Acceptance criteria:
- [ ] ProductAsset schema: belongs to a product, stores a storage key (Bunny Storage or R2), media type (image or video), original filename, MIME type, file size, duration for videos, width, height, upload timestamp, uploader identity, an array of tags, a free-form description, and a status indicating whether the asset has been processed and is ready to use
- [ ] Support for image formats (JPEG, PNG, WebP, HEIC) and video formats (MP4, MOV, M4V, and other common phone-recorded formats)
- [ ] Storage backend is configurable per deployment: either Cloudflare R2 or Bunny Storage
- [ ] Presigned upload URL generation so the client's browser or phone uploads directly to storage, not through the Phoenix application — this avoids piping large files through the web server
- [ ] Image processing on ingestion: basic validation of dimensions and file size, automatic rotation from EXIF orientation data, generation of a smaller preview thumbnail stored alongside the original
- [ ] Video processing on ingestion: the asset is handed off to the external video processing service (see Video Service spec in its own repository) for probing, format normalization, and generation of standard renditions. The video service returns metadata and storage keys for the rendered outputs, which are recorded as related assets linked to the original
- [ ] Platform rendition strategy: videos may have multiple renditions stored (horizontal landscape for feed posts, vertical for stories/reels, trimmed short-form versions for TikTok and Reels). Images may have crop variants for platforms that strongly prefer specific aspect ratios
- [ ] Asset library UI on the product detail page: browsable grid or list of assets with thumbnails, filter by tag and media type, search by description, sortable by upload date
- [ ] Assets can be tagged with multiple labels (for example "kitchen remodel", "before", "after", "exterior") — tags are free-form per product with autocomplete from previously used tags
- [ ] Asset deletion: soft delete with a grace period, then hard delete of the underlying storage objects. Deleting an asset that is referenced by a published draft flags the publication for awareness rather than silently breaking
- [ ] Asset bundles: related assets can be grouped into a named job or event bundle. A bundle has its own context text describing what the collection represents ("Johnson family kitchen remodel, 3 weeks, quartz counters, custom cabinets"). Content generation can target an entire bundle rather than individual assets, producing coordinated multi-platform campaigns around a single job
- [ ] Draft generation from assets: a new job type that takes a set of asset IDs (or a bundle ID) plus optional context text, and produces drafts across all enabled platforms for the product, where each draft is associated with the appropriate asset as its featured media
- [ ] Draft schema extended: drafts can reference one or more ProductAssets through a many-to-many association, and the publisher knows to attach the matching asset URL when it calls each platform's publishing API
- [ ] Platform-asset compatibility: when generating drafts, the system prefers assets that match each platform's ideal format (vertical video for Reels/Shorts/TikTok, horizontal for YouTube/LinkedIn, images for Twitter if no fitting video exists). If no compatible asset exists for a platform, the draft for that platform is either skipped with a note, or falls back to image-only using whatever photo is available
- [ ] REST API: endpoints to initiate an upload and receive a presigned URL, list assets for a product with filters, get a single asset by ID, update asset tags and description, delete an asset, list bundles, create a bundle, add or remove assets from a bundle, and trigger generation from an asset or bundle
- [ ] Dashboard workflow: from a product detail page, the agency user can click "upload media", drag files (or use a mobile file picker), see upload progress, add tags and context, and then click "generate posts" to kick off drafts. The review queue then shows the drafts with their associated media visible inline
- [ ] Asset usage tracking: each asset records which drafts reference it, which drafts have been approved, and which have been published. This creates an attribution trail from a single photo to the posts it spawned
- [ ] Quota and storage cost tracking: per-product storage usage is tracked so an agency can see how much each client's media consumes and make informed decisions about retention policies

---

### Feature 12: SMS Gateway and Conversational Bot

**Purpose:** Enable phone-based media submission and ongoing conversational interaction with Content Forge so that clients can text photos, videos, and context directly to their marketing assistant instead of using a web form. The bot receives inbound messages, has conversations with authorized senders, requests additional information when needed, collects media via upload links, confirms when drafts are ready for review, sends reminders when a client has gone quiet, and escalates to human staff when it cannot handle a request confidently.

**Why this matters:** Most of the valuable media agencies want (finished jobs, before/after photos, event moments) is captured on a phone by a non-technical person who has no interest in logging into a dashboard. The difference between "marketing system that works" and "marketing system that gets ignored" is whether that person can just text a photo and have everything else handled for them. SMS is the universal interface that every phone supports, and a conversational bot is the minimum viable experience.

Acceptance criteria:
- [ ] Twilio integration: an inbound webhook endpoint receives SMS and MMS messages, and an outbound wrapper service sends replies via Twilio's messaging API. Credentials are loaded from environment variables or 1Password
- [ ] ProductPhone schema: associates phone numbers with products. Multiple phone numbers can be associated with a single product (the business owner, a project manager, a spouse, etc.). Each phone number has a role (owner, submitter, viewer), a display label, and an active flag
- [ ] Whitelist enforcement: when an inbound SMS arrives, the sender's phone number is looked up against ProductPhone. If the number is not found or is inactive, the message is rejected with a polite reply such as "This number isn't recognized. Please contact your agency to get set up." All rejected attempts are logged for agency review
- [ ] Whitelist promotion: when an unauthorized number attempts contact, the agency user sees the attempt in a dashboard view and can approve it by assigning it to an existing product with a chosen role, which adds it to the whitelist
- [ ] Role-based permissions: owners can approve publications and change product settings via SMS commands, submitters can send media and context but cannot approve, and viewers can ask status questions but cannot trigger actions
- [ ] SmsEvent audit log: every inbound and outbound message is recorded with the phone number, direction, product association if any, message body, media URLs if present, the agent response if any, a status code, and a timestamp. This log is the source of truth for troubleshooting, compliance, and usage reporting
- [ ] Conversation session tracking: a ConversationSession per product tracks the active conversation context, last message timestamp, and current flow state (such as waiting for upload, waiting for context, status query, or idle). Sessions expire after a period of inactivity and a new session starts on the next message
- [ ] OpenClaw integration: Content Forge forwards inbound messages to a configured OpenClaw endpoint or internal agent runtime, passing the product identity, sender identity, message content, attached media URLs, conversation history, and available tools. OpenClaw returns either a text response to send via SMS or a structured tool call for Content Forge to execute on its behalf
- [ ] Bot tool surface: the OpenClaw agent has access to a specific set of tools, including sending a reply via SMS, creating a one-time upload link for media submission, listing recently uploaded assets for the product, creating a new asset bundle with a given name, triggering draft generation from an asset or bundle, checking the status of a draft, checking the schedule of upcoming posts, escalating a message to a human staff member, scheduling a follow-up reminder, and recording conversational notes into the product's memory
- [ ] Upload link flow: when the bot calls the create upload link tool, Content Forge generates a unique short-lived URL pointing to a mobile-optimized upload page. The URL is sent via SMS reply. When the client opens the link, they see a simple page with a file picker, a text field for notes, and an upload button. Files upload directly to storage via presigned URLs. On successful upload the assets are created and associated with the product and with the current conversation session
- [ ] Mobile upload page: works on iOS and Android browsers, opens the camera roll or camera directly via standard file input, shows upload progress for each file, handles multiple files at once, and gracefully handles interruptions (tab closed, connection lost) by allowing resume
- [ ] Proactive reminder system: a scheduled Oban job runs hourly and checks every active product with reminders enabled. For each product where the time since the last inbound message exceeds the configured reminder cadence, the job triggers OpenClaw with a "craft a reminder message" instruction. The agent writes a personalized reminder using the product's brand voice and any recent context, and the message is sent via SMS
- [ ] Smart reminder scheduling: reminders only send during business hours for the product's configured timezone, respect weekends and major holidays by default (configurable per product), and adapt their cadence based on historical response patterns. If a client typically responds within 3 days of being reminded, future reminders schedule at 3-day intervals. If responses take longer, the cadence relaxes
- [ ] Reminder backoff and escalation: after a configurable number of consecutive ignored reminders (default 2), the tone shifts from friendly nudge to "checking in, everything okay?". After a further threshold (default 4 total ignored reminders), the system stops sending reminders and notifies agency staff that the client has gone dormant and may need a human call
- [ ] Reminder opt-out: every reminder includes instructions to reply STOP to pause reminders. A STOP reply pauses reminders for the default period (one week) and records the opt-out event. The next reminder after the pause period resumes the normal cycle
- [ ] Per-product phone numbers (optional): the agency can optionally provision a dedicated Twilio phone number for each client, so each client saves a unique "marketing assistant" number in their contacts. Content Forge tracks the provisioned number per product and routes inbound messages to the correct product based on which number received them
- [ ] Rate limiting: outbound SMS per conversation is capped at a configurable number per day to prevent runaway costs if a conversation goes wrong. Exceeding the limit triggers an escalation to agency staff rather than silently dropping messages
- [ ] Status query handling: the bot can answer questions like "when does my Facebook post go out?", "is the Johnson kitchen post ready?", "how did last week's posts do?" by calling the appropriate tools and reporting factual results. The bot must always verify status via tool calls before making factual claims — it cannot invent schedules or engagement numbers
- [ ] Simple edit requests: the bot can handle basic edit requests like "make the LinkedIn one more formal" or "change the caption to mention the 2-week timeline" by regenerating the specific draft variant with modified instructions. More complex changes escalate to human staff
- [ ] Escalation to human staff: when the bot cannot confidently handle a request — either because the request is outside its tool surface, involves pricing or contract questions, involves a complaint, or involves any ambiguity about client intent — it responds with a polite holding message and creates an internal notification for agency staff. Notification channels include Slack, email, or a flagged entry in the Content Forge dashboard (whichever the agency has configured)
- [ ] TCPA compliance logging: each phone number whitelist entry records an opt-in timestamp and an opt-in source (such as "verbal during onboarding call", "filled form", "replied YES to confirmation"). The agency can export the opt-in log for any client on request
- [ ] Initial opt-in flow: when a new phone number is added to a product whitelist, the first outbound message from Content Forge explicitly asks for confirmation: "Hi, this is [agency]'s marketing assistant for [brand]. Reply YES to confirm you'd like to receive messages from us, or STOP to opt out." No further outbound messages are sent until a YES is received
- [ ] Conversation memory: the bot writes useful context from conversations into the product's Memory-Wiki automatically — client preferences, patterns, seasonal business cycles, notable past jobs. This makes future conversations smarter. Sensitive content (complaints, pricing discussions) is flagged and not auto-written
- [ ] REST API for dashboard control: endpoints to list phones associated with a product, add or remove a phone from the whitelist, view the conversation history for a phone or product, manually send an outbound message, pause reminders for a product, and export the opt-in log for compliance purposes
- [ ] Cost tracking: per-product SMS volume (inbound and outbound) is tracked and surfaced in the dashboard so agencies can see what each client is costing them in messaging fees

---

### Feature 13: OpenClaw Tool Surface

**Purpose:** Expose Content Forge's operations as a stable set of named tools that the OpenClaw agent can invoke from any channel it talks to — SMS, the OpenClaw CLI, Telegram, and any future conversational surface. A tool is registered once with the agent and is immediately available across every channel; the channel only handles inbound text and outbound delivery. This turns Content Forge from "a dashboard operators click through" into "the orchestration brain any conversational surface can drive."

**Why this matters:** Content Forge already exposes its operations through a LiveView dashboard and a Review API. Agencies using SMS submission need the same operations invokable by the bot (create an upload link, list recent assets, check a draft's status, schedule a post, approve a blog). Without a shared tool surface, every new channel would re-implement its own subset, drift in auth and error handling, and force tool logic to live inside channel-specific handlers. The tool surface is also the extension point other ecosystem apps (contacts4us, Media Forge consumers, the chatbot consultancy) use to plug into the same agent: they register their own plugins against the gateway, and the agent ends up with a unified ecosystem tool surface.

**Registration pattern:**
- [ ] The OpenClaw gateway loads a Node.js plugin at `~/.openclaw/plugins/content-forge/index.js` that declares each tool's name, human-readable label, description (copy the agent reads when deciding whether to call the tool), and JSON-schema parameters. The plugin's `execute` handler forwards every invocation to the Content Forge HTTP surface and serializes the tool result into the chat payload the gateway expects.
- [ ] Content Forge exposes a single HTTP endpoint for all tool invocations at `POST /api/v1/openclaw/tools/:tool_name`. The controller (`ContentForgeWeb.OpenClawToolController`) is thin: it authenticates, builds the invocation context, delegates to `ContentForge.OpenClawTools.dispatch/3`, and serializes the response. Per-tool logic lives in per-tool modules; the controller does not grow a case statement of business rules.
- [ ] Tool modules live under `ContentForge.OpenClawTools.<Name>` and implement a `call/2` callback `(ctx, params) :: {:ok, map()} | {:error, term()}`. They have no other public surface.
- [ ] The dispatch table (`ContentForge.OpenClawTools.@tools`) maps tool names to modules. Adding a new tool means adding one module plus one line in the map, and adding the matching `registerTool` call in the Node plugin so the gateway knows its schema.

**Authentication:**
- [ ] Every request to the tool endpoint must carry an `X-OpenClaw-Tool-Secret` header whose value equals the configured `:content_forge, :open_claw_tool_secret` env (sourced from `OPENCLAW_TOOL_SECRET` at runtime). The auth plug (`ContentForgeWeb.Plugs.OpenClawToolAuth`) compares via `Plug.Crypto.secure_compare/2`.
- [ ] Missing env, missing header, and mismatched secrets all return an identical bland `401 Unauthorized`. No error text distinguishes the three cases so probing cannot tell which one fired. The secret itself is never logged.
- [ ] The tool endpoint is the only surface authenticated this way; the Review API bearer token, the Twilio HMAC, and the Media Forge webhook signature all live on different pipelines.

**Invocation context (ctx map, present on every tool call):**
- [ ] `:session_id` — the OpenClaw agent session id so tools that persist conversation memory (Phase 16.3 onward) scope to the right thread.
- [ ] `:channel` — a short identifier for the originating surface: `"sms"`, `"cli"`, `"telegram"`, etc. Tools use this when they need channel-specific behavior (for example, an authorization helper reaches for `ProductPhone` on `"sms"` and an `OperatorIdentity` on `"cli"`).
- [ ] `:sender_identity` — the caller's channel-specific identifier: E.164 phone number for SMS, operator id for CLI, handle for Telegram. Product resolution and role checks pivot on this when an explicit `product` param is not supplied.

**Request body shape:**
- [ ] Every POST body contains four top-level fields: `session_id` (string), `channel` (string), `sender_identity` (string or null), `params` (object). The controller builds the ctx map from the first three and passes `params` through to the tool module unchanged.

**Response shape:**
- [ ] Success — `200 {"status":"ok","result": <tool payload>}`. Result values are JSON-safe (atoms serialized to strings, `DateTime` values to ISO-8601).
- [ ] Unknown tool — `404 {"status":"error","error":"unknown_tool","tool_name":"..."}`. Any tool name not in the dispatch map returns this shape so the agent can render "I do not know that tool."
- [ ] Tool error — `422 {"status":"error","error":"<reason>"}`. The controller converts atoms and `{kind, details}` tuples to a human-readable reason string. The reason is the single canonical field the agent uses to decide how to phrase the failure to the user.

**Product resolution contract (shared across tools):**
- [ ] Every tool that operates on a product supports two resolution paths. If `params["product"]` is present it is resolved first: treat as a UUID against `Products.get_product/1`; on cast failure or no row, fall through to a case-insensitive substring match against `Products.list_products/0` by name. A single match returns `{:ok, product}`; zero matches returns `{:error, :product_not_found}`; multiple matches returns `{:error, :ambiguous_product}` carrying the candidate names the agent should echo back.
- [ ] If `params["product"]` is absent or empty and the channel is phone-based (`"sms"` today), resolve via `Sms.lookup_phone_by_number(sender_identity)`. A single active `ProductPhone` row yields `{:ok, product}`; zero or multiple active rows yield `{:error, :missing_product_context}` so the agent can ask the user which product they mean.
- [ ] If neither path yields a product the tool returns `{:error, :missing_product_context}` with no side effects. The controller maps that reason to the 422 response so the agent can render "I could not find your product. Which product are you asking about?".
- [ ] Product resolution is shared between tool modules via `ContentForge.OpenClawTools.ProductResolver`. New tools that need a product reach for the resolver; they do not re-implement the UUID / fuzzy / session paths inline.

**Error taxonomy (the canonical reasons tools return):**
- [ ] `:product_not_found`, `:ambiguous_product`, `:missing_product_context` — product resolution outcomes described above.
- [ ] `:not_found` — a specific record (draft, asset, bundle) identified by id does not exist or is not owned by the resolved product. Tools that accept an id always scope the lookup to the product.
- [ ] `{:presign_failed, reason}` — storage adapter rejection for upload-link-style tools.
- [ ] `:forbidden` — reserved for the authorization framework that 16.3 introduces. Read-only tools in 16.2 do not return this reason; any future write tool that calls the authorization helper surfaces forbidden through this reason.
- [ ] Classified HTTP errors from downstream clients (Media Forge, LLM providers) surface as the same `{:transient, ...}` / `{:http_error, ...}` shapes the clients already use. Tools do not rewrap them.

**Cross-channel invariants:**
- [ ] Tool semantics do not branch on channel. A tool returns the same payload whether called from SMS, CLI, or a future Telegram surface; the channel only changes how the reply is rendered to the user. Tools that need channel-aware authorization delegate to a helper (introduced in 16.3) rather than inlining channel checks.
- [ ] The tool surface never fabricates data when a downstream dependency is unavailable. Missing credentials on any downstream (Media Forge, LLM, Twilio) surface through the standard `:not_configured` -> `:missing_*_context` pattern rather than silently synthesizing a plausible result.

**Acceptance criteria (phase-level, refined per slice in `BUILDPLAN.md`):**
- [x] `create_upload_link` ships end-to-end on SMS and CLI (16.1).
- [ ] `list_recent_assets`, `draft_status`, `upcoming_schedule`, `competitor_intel_summary` ship as read-only tools (16.2) so the agent can answer status and reconnaissance questions.
- [ ] `create_asset_bundle`, `record_memory`, `add_tag_to_asset` ship as light writes under the shared authorization helper (16.3).
- [ ] `generate_drafts_from_bundle`, `schedule_reminder_change`, `approve_draft` ship as heavy writes behind a two-turn confirmation envelope (16.4).
- [ ] Every tool invocation is recorded in a unified `ToolInvocationEvent` surface with a dashboard view and REST mirror (16.5).
- [ ] `escalate_to_human` ships as a first-class tool the agent self-invokes on ambiguity, cost, or complaint (16.6), generalizing the SMS-scoped escalation primitive from Feature 12.

**Out of scope (for the tool surface as a whole):**
- [ ] Streaming tool results. The current shape is request/response; long-running tools that need progress updates should enqueue Oban jobs and return an acknowledgement reason the agent surfaces as "I started that, I will let you know when it finishes."
- [ ] Channel discovery or reply-sending tools. Outbound reply delivery is owned by the SMS dispatcher (Feature 12) and by whichever delivery path the future channel wires up; the agent does not need a `send_reply` tool because the gateway fans its response out.
- [ ] Cross-product or cross-tenant operations. Tools operate on a single product scoped by resolution. An agency-wide dashboard answer that spans products is a dashboard operation, not a tool.

---

### Integration 1: Media Forge HTTP Client

**Purpose:** Provide a single named client module that every Content Forge caller uses to talk to the Media Forge service. The module centralizes the base URL, the shared secret header, retry semantics, and transient-versus-permanent error classification so individual features (image generation, final video encoding, image processing, platform renditions) do not each reinvent them. Every future Media Forge call in the codebase goes through this module; nothing else touches the underlying HTTP layer for Media Forge URLs.

**Why this matters:** Media Forge is the ecosystem's media service. Without a shared client, every caller repeats authentication, drifts in retry behavior, and gets inconsistent at classifying transient versus permanent errors. A single stubbable client also means tests never hit the live service, which matters because the dev instance runs on a different machine on the LAN and is not reliably reachable from CI. This slice delivers the client and its tests only. Swapping existing Content Forge callers (the image generator, the video pipeline, image pre-processing, platform renditions) over to this client is tracked under Phase 10.2 and later slices in `BUILDPLAN.md`.

**Module location and shape:**
- [x] The public client module is `ContentForge.MediaForge` and lives at `lib/content_forge/media_forge.ex` while it remains a single file. If future slices add helper modules they move under a `lib/content_forge/media_forge/` subdirectory at that point. Callers outside the module only ever reference the public module.
- [x] The module exposes exactly the call functions listed below. It does not expose raw HTTP helpers, raw Req wrappers, or the underlying adapter configuration.

**Configuration:**
- [ ] The base URL is read from application configuration at the key `:base_url` under `:media_forge` within the `:content_forge` application. When no value is configured, the default is `http://192.168.1.37:5001`, matching the current dev instance.
- [ ] The shared secret is read from application configuration at the key `:secret` under `:media_forge` within the `:content_forge` application. In production the secret is sourced from an environment variable at runtime through `config/runtime.exs`. In the test environment the secret is left unset by default so missing-secret behavior is observable; individual tests may configure a secret when they need to exercise the authenticated path.
- [ ] When the secret is missing at runtime, the module reports its status as unavailable and every call function returns an error tagged as not configured, immediately, without issuing any network request. Upstream callers (image generator, video pipeline, asset processing) are expected to surface "Media Forge unavailable" in the dashboard and skip the dependent feature rather than crashing the containing request or job.

**Authentication header:**
- [ ] Every outbound request automatically sets the header named `X-MediaForge-Secret` with the configured secret value. Callers cannot omit or override this header. The header is set inside the client, not at the call site.

**Endpoints the client exposes:**
- [ ] A synchronous probe function that posts to `/api/v1/video/probe` and returns the video metadata map on success, or a classified error. This is used to inspect a source file before committing to a full render.
- [ ] Four asynchronous video enqueue functions covering normalization, render, trim, and batch, each posting to `/api/v1/video/normalize`, `/render`, `/trim`, and `/batch` respectively. Each returns a success result carrying the new job identifier on acceptance, or a classified error. Callers then either poll job status or await the signed webhook once Phase 10.5 lands.
- [ ] Three asynchronous image enqueue functions covering image processing, image render, and batch image operations, posting to `/api/v1/image/process`, `/render`, and `/batch`. Each returns the same success-with-job-id shape as the video enqueue functions.
- [ ] A generation function that posts to `/api/v1/generation/images`, and a comparison function that posts to `/api/v1/generation/compare`. Each returns a success map that either contains a synchronous result or a job identifier depending on the provider that Media Forge selects internally. Callers inspect the returned map and branch on the presence of a job identifier.
- [ ] A job status function that performs a GET against `/api/v1/jobs/:id` and returns the status map or a classified error.
- [ ] A job cancellation function that posts to `/api/v1/jobs/:id/cancel` and returns a cancellation acknowledgement map or a classified error.

**Error classification (applies to every call above):**
- [x] A 5xx response from Media Forge, or a timeout from the HTTP layer, is returned as a transient error tuple whose second element is the reason. Callers may retry transient errors through their Oban backoff policy.
- [x] A 4xx response is returned as a permanent error tuple whose elements are the HTTP status code and the response body. Callers must not retry a permanent error without changing the input.
- [x] A connection refusal or other network-layer failure (DNS failure, refused socket) is returned as a transient error tuple whose reason is network. Callers may retry.
- [ ] A 3xx response that reaches the classifier (for example 304 Not Modified when a caller enabled conditional caching, or a 307/308 that is not auto-followed) is returned as an unexpected-status error tuple carrying the status code and the response body. This is the catch-all that keeps `classify/1` exhaustive; it ships in Phase 10.1.1, not 10.1.
- [x] Any other unexpected condition is returned as a plain error tuple with enough detail in the reason to diagnose from logs. The client does not rescue-and-swallow these conditions silently.

**Test stance:**
- [ ] The `Req.Test` stub adapter is wired into this module from the first commit. The test suite uses stubbed responses for every code path and never reaches a live Media Forge instance. Live smoke testing is a separate manual runbook documented in the handoff notes, not a CI concern.
- [ ] Minimum required tests at the end of this slice:
  - [ ] At least one error-classification test per branch: one transient case (a 5xx or a timeout) and one permanent case (a 4xx), each asserting the exact returned tuple shape and that no retry is attempted inside the client.
  - [ ] One missing-secret test asserting that a call returns the not-configured error without any HTTP request being recorded by the stub adapter.
  - [ ] One asynchronous enqueue happy path (either video or image) that asserts the success tuple carries the expected job identifier when the stub responds with one.
  - [ ] One job-status happy path asserting the status map is returned verbatim from a stubbed GET on `/api/v1/jobs/:id`.
  - [ ] One job-cancellation happy path asserting the acknowledgement is returned from a stubbed POST to `/api/v1/jobs/:id/cancel`.

**Out of scope for this slice:**
- [ ] Replacing existing image generation, video pipeline, image processing, and rendition callers with calls into this client is tracked under Phase 10.2 through 10.4 and is not part of this slice.
- [ ] The signed-webhook receiver for asynchronous job completion is Phase 10.5. The client's async enqueue functions return a job identifier that can be either polled via the job status function or resolved by a webhook once the receiver lands; this slice does not build the receiver.
- [ ] No dashboard or LiveView surface changes in this slice. "Media Forge unavailable" messaging is a caller-side concern handled when each existing feature is swapped over.

---

### Integration 2: Media Forge Webhook Receiver

**Purpose:** Give Media Forge a first-class path to notify Content Forge that an asynchronous job has finished. Today every async call (image generation, video render) is resolved by polling `get_job/1` until the remote status flips to done or failed. Polling is correct but expensive in wall-clock time and wasteful of retries. The webhook receiver is an alternative faster path: Media Forge posts a signed completion notice to a Content Forge endpoint, and Content Forge applies the exact same state transition the poller would have applied. Polling continues to exist as a fallback for deployments where inbound webhooks cannot reach Content Forge.

**Why this matters:** With only polling, a production workflow that enqueues ten video renders and ten image generations spends minutes in waiting loops even when Media Forge finished its work in seconds. The webhook closes that gap, shortens time-to-publish, and reduces the chance of Oban retries timing out on long jobs.

**Endpoint and routing:**
- [ ] The receiver is exposed as a single public HTTP route whose path is stable and reserved for Media Forge: `POST /webhooks/media_forge`. The route lives outside the `/api/v1` namespace so it does not inherit the bearer-token pipeline. A dedicated pipeline applies only what this endpoint needs: raw body capture and HMAC signature verification.
- [ ] The route accepts JSON. The success response is HTTP 200 with an empty or trivial JSON body. Every non-success response is a specific status code with a plain-text reason: 400 for malformed payloads or stale timestamps, 401 for bad or missing signatures, 404 for job identifiers that do not match any known Content Forge record. The body never echoes the offending signature or any secret.

**Signature verification:**
- [ ] The header `X-MediaForge-Signature` has the Stripe-style shape `t=<unix-timestamp>,v1=<hex>`. The `v1` value is HMAC SHA256 of the exact byte sequence `<timestamp>.<raw-body>` computed with the Media Forge shared secret.
- [ ] A body-reader plug captures the raw request body before any JSON parsing consumes the stream. The verifier compares signatures using `Plug.Crypto.secure_compare/2` to avoid timing-leak side channels.
- [ ] The allowed timestamp window is 300 seconds in either direction from server time. Requests outside the window are rejected as stale even if the signature would otherwise verify.
- [ ] The shared secret is read from application configuration (same namespace as the outbound client's secret, or a separate `:webhook_secret` key if operations prefer to rotate them independently; the spec allows either as long as it is documented in `config/runtime.exs`). If no secret is configured, every inbound webhook is rejected 401 rather than accepting unsigned input.

**Payload and dispatch:**
- [ ] The JSON body must identify the Media Forge job by id, the event type (for example `job.done` or `job.failed`), and carry a result payload appropriate to the event. Content Forge looks up the matching internal record (image-generation-backed draft, video job) by Media Forge job id.
- [ ] Dispatch is single-function: a shared resolution helper is called by both the poller (in the async enqueue/poll loop) and the webhook controller. The helper reads the current state of the internal record and applies the terminal transition exactly once. Records already in a terminal state produce a 200 no-op response so Media Forge does not retry.
- [ ] For an image-generation draft: on `job.done`, `draft.image_url` is persisted from the payload and the draft status returns to `ranked` (or whatever it was before generation started) so it can progress to scheduling. On `job.failed`, the draft is marked blocked with an error note surfaced in the dashboard. For a video job: on `job.done`, the final R2 key is recorded under the final-encode step in the per-step storage map and the job transitions from `assembled` to `encoded`. On `job.failed`, the job transitions to `failed` with the error recorded.
- [ ] Idempotency: if the poller already resolved the job in the same state, the webhook handler returns 200 and applies no change. If the webhook resolves first, the poller sees a terminal state on its next check and exits cleanly.

**Testing:**
- [ ] Tests are `Phoenix.ConnTest`-based with forged valid signatures for the happy paths and deliberately broken signatures / timestamps for the rejection paths. No live Media Forge is involved; the webhook side is pure inbound verification.
- [ ] Minimum required tests:
  - [ ] A valid signed `job.done` for an image draft updates `image_url` and transitions status, returns 200.
  - [ ] A valid signed `job.done` for a video job records the R2 key and transitions the job to `encoded`, returns 200.
  - [ ] A valid signed `job.failed` for an image draft marks it blocked with an error note.
  - [ ] A valid signed `job.failed` for a video job transitions it to `failed`.
  - [ ] A timestamp outside the 300-second window returns 400 "stale request" regardless of signature validity.
  - [ ] An invalid signature returns 401.
  - [ ] An unknown Media Forge job id returns 404.
  - [ ] A repeat webhook for a record already in a terminal state returns 200 and makes no change (asserted by examining the record before and after).

**Out of scope for this slice:**
- [ ] No changes to the outbound client beyond extracting the shared resolution helper if that makes the two call paths simpler to test.
- [ ] Dashboard surfacing of webhook vs. polling as the resolution source is not part of this slice; the dashboard simply sees the resulting state transitions.
- [ ] No backward-compatibility shim for a pre-webhook Media Forge; the spec assumes Media Forge always signs its webhooks as described.

---

### Integration 3: LLM Client (Anthropic)

**Purpose:** Provide a named HTTP client for Anthropic's Messages API that every Content Forge caller uses when it needs a generative model call. This is the first of what may become a small family of provider clients (Anthropic, Google Gemini, xAI, OpenAI) behind a thin dispatcher. The goal is the same as Media Forge's client: one place for auth, retries, error classification, and test stubbing so brief generation, ranking, and future features do not each re-implement them.

**Why this matters:** Content Forge today is a scaffold with hardcoded templated text where real LLM calls belong. Brief generation returns the same boilerplate for every product; the dashboard shows the scaffold as if it were real output. This violates the project rule against synthetic data reaching production flows. Shipping a single real provider first is the minimum useful step; multi-provider synthesis arrives in a follow-up slice (11.1b) but the client that unblocks every caller lands here.

**Module location and shape:**
- [ ] The public client module is `ContentForge.LLM.Anthropic` and lives at `lib/content_forge/llm/anthropic.ex`. Future sibling provider modules will live under `lib/content_forge/llm/`. Callers outside this directory only reference the public module.
- [ ] The module exposes a single public completion function that takes a prompt (string or a list of message maps) and an options keyword list (model, max tokens, temperature, system prompt). It returns a success tuple carrying the completion text, or a classified error tuple.

**Configuration:**
- [ ] The API key is read from application configuration at `:api_key` under `:anthropic` within `:llm` within `:content_forge`. Production sources the key from an environment variable at runtime through `config/runtime.exs`. Test leaves the key unset by default so missing-key behavior is observable; individual tests may configure a key when they need to exercise the authenticated path.
- [ ] The default model is read from the same configuration at `:default_model`. Callers may override per-call via options. A sensible default (for example the current Claude Sonnet) is configured in `config/config.exs` so no caller has to hardcode a model name.
- [ ] The default max-tokens budget is read similarly at `:max_tokens`, overridable per call.
- [ ] When the API key is missing at runtime, the module reports its status as not-configured and every call returns `{:error, :not_configured}` immediately, with zero HTTP I/O. Upstream callers (brief generator now, ranker later) treat this as a graceful downgrade: log the condition, surface "LLM unavailable" in the dashboard, skip the dependent step. No synthetic or placeholder text is written to the database.

**Authentication and version headers:**
- [ ] Every outbound request sets the `x-api-key` header with the configured key and the `anthropic-version` header with the currently supported API version string. Both are set inside the client, not at the call site; callers cannot omit either.

**Endpoint:**
- [ ] The client posts to Anthropic's Messages endpoint (`/v1/messages` under the Anthropic API base URL). The request body follows the Messages schema: model, max tokens, optional system prompt, messages array with alternating user and assistant turns, optional temperature. The caller's prompt is wrapped into this schema by the client.
- [ ] The response is parsed into a success shape carrying the extracted text content (the first text block from the assistant reply) plus metadata (model echoed by the API, stop reason, usage token counts if available).

**Error classification:**
- [ ] A 5xx response from Anthropic, or a timeout from the HTTP layer, is returned as a transient error tuple whose second element is the reason. Callers may retry through Oban backoff.
- [ ] A 429 rate-limit response is treated as transient (Anthropic honors retry-after). Callers may retry.
- [ ] Any other 4xx response (invalid request, bad API key, insufficient credit) is returned as a permanent error tuple carrying the status code and the response body. Callers must not retry without changing the input.
- [ ] A connection refusal or network-layer failure is returned as a transient-network error tuple with the reason carried. Callers may retry.
- [ ] A 3xx response that reaches the classifier is returned as an unexpected-status error tuple carrying status and body. Catch-all for exhaustiveness.
- [ ] Any other unexpected condition is returned as a plain error tuple with enough context in the reason to diagnose from logs. The client does not rescue-and-swallow silently.

**Test stance:**
- [ ] The `Req.Test` stub adapter is wired into this module from the first commit. The test suite uses stubbed responses for every code path and never reaches the live Anthropic API.
- [ ] Minimum required tests at the end of the infra slice:
  - [ ] A happy-path completion returns the expected text and metadata.
  - [ ] A 429 stubbed response returns a transient error tuple; the client does not retry internally (Oban owns the retry policy).
  - [ ] A 500 stubbed response returns a transient error tuple.
  - [ ] A 400 stubbed response (invalid request) returns a permanent error tuple carrying status and body.
  - [ ] A missing-API-key test asserts `{:error, :not_configured}` is returned without any HTTP request being recorded by the stub.

**Out of scope for this slice:**
- [ ] Adding sibling provider modules for Google Gemini, xAI, or OpenAI. Those land under 11.1b and later follow-up slices.
- [ ] Changing any existing caller to use the new client. The brief-generator swap is a separate slice.
- [ ] Streaming responses, tool use, or other advanced features beyond a single completion request. The client can be extended later without changing the public completion function's shape.

---

### Integration 4: LLM Client (Google Gemini)

**Purpose:** Second provider for generative completions, sibling to Integration 3. Shipping Gemini alongside Anthropic lets the brief generator synthesize from two different models (Feature 3 Stage 1 acceptance criterion "queries at least 2 smart models"), and opens the door for future slices to rotate providers or fall back on rate limits.

**Why this matters:** Cross-model synthesis catches more of what each model misses individually; briefs end up richer. Two providers also avoids a single-vendor dependency on Anthropic; if an outage or policy change blocks one provider, the other still works.

**Module location and shape:**
- [ ] Public module is `ContentForge.LLM.Gemini` at `lib/content_forge/llm/gemini.ex`, sibling to `ContentForge.LLM.Anthropic`. Its public completion function is shape-compatible with Anthropic's so both are substitutable at the call site.
- [ ] No shared abstract base module between providers in this slice. Duplication is acceptable for two providers; if a third arrives, a shared behavior can be introduced at that point.

**Configuration:**
- [ ] API key at `:api_key` under `:gemini` within `:llm` within `:content_forge`. Production sources the key from an environment variable at runtime. Test leaves it unset by default.
- [ ] Default model at `:default_model` and default max-tokens at `:max_tokens` under the same namespace, each overridable per call via options.
- [ ] Missing API key at runtime: the module returns `{:error, :not_configured}` immediately with zero HTTP I/O.

**Authentication:**
- [ ] Google's Generative Language API accepts the API key either as a URL query parameter (`?key=...`) or as an `x-goog-api-key` header. The slice picks the idiomatic option for Req; what matters is that the key is attached inside the client, not at the call site.

**Endpoint:**
- [ ] The client posts to the Gemini `generateContent` endpoint under the Generative Language API base URL. The request body follows Google's schema: contents array with parts, optional system instruction, optional generation config (temperature, max output tokens). The caller's prompt is wrapped into this schema by the client.
- [ ] The response is parsed into a success shape carrying the extracted text content from `candidates[0].content.parts[0].text` plus metadata (model name, finish reason, usage metadata if present).

**Error classification:**
- [ ] Same rules as Integration 3: 5xx transient, 429 transient, 4xx permanent, timeout transient, connection refusal transient-network, 3xx unexpected-status, catch-all pass-through. No silent rescues.

**Test stance:**
- [ ] `Req.Test` stubbed from the first commit. Tests cover happy-path completion, 429 transient, 500 transient, 400 permanent, missing-key no-HTTP downgrade.

**Out of scope for this slice:**
- [ ] Changing any caller to use the new client. The brief-generator synthesis swap is its own slice (11.1c).
- [ ] Streaming, function calling, or multi-modal inputs. The slice ships a single text completion surface.

---

### Integration 5: OpenClaw Client

**Purpose:** Provide a named HTTP client for the ecosystem's OpenClaw bulk-generation service. OpenClaw is the "fast, cheap, high-volume" first-draft generator that seeds every batch; the smart LLMs (Anthropic, Gemini, eventually xAI and OpenAI) rank and critique afterward. Today the bulk generator returns hardcoded sample text per platform / angle, which violates the no-synthetic-data-in-production rule.

**Why this matters:** Without a real OpenClaw wiring, every draft on the dashboard is boilerplate. Ranking runs against fake content, and human review decisions are meaningless. This is the single biggest remaining gap in the content pipeline after the brief generator swap.

**Module location and shape:**
- [ ] Public module is `ContentForge.OpenClaw` at `lib/content_forge/open_claw.ex` (or a subdirectory if helpers emerge). Callers outside this module reference only the public functions.
- [ ] The public surface exposes bulk-generation functions shaped around the three content kinds currently served (social post variants, blog drafts, video scripts). A minimal interface is one function per kind, or one `generate_variants/2` that takes a content-type in the request map; the coder picks whichever keeps the callers clean.

**Configuration:**
- [ ] Base URL, API key, and default timeout live at `:content_forge, :open_claw` in application config. Production sources the key and URL from environment variables at runtime. Test leaves them unset by default so missing-config behavior is observable.
- [ ] When base URL or API key are missing, the client returns `{:error, :not_configured}` immediately with zero HTTP I/O. Upstream callers treat this as a graceful downgrade: log "OpenClaw unavailable", skip the step, surface the unavailability in the dashboard rather than fabricating drafts.

**Authentication:**
- [ ] An auth header is attached inside the client on every request. The header name and token format follow OpenClaw's current convention (bearer token or custom header as OpenClaw documents it). The coder records the chosen header in the module docstring and in the BUILDLOG handoff for future reference.

**Request and response shape:**
- [ ] The request body carries: content brief text, product context (name, voice profile, site summary), platform (for social), angle (for the variant being generated), desired variant count, and any performance insights Content Forge wants to feed in. The exact JSON shape is aligned with OpenClaw's endpoint at the time the slice ships.
- [ ] The success response is parsed into a list of variant maps, each containing at minimum the generated text and a model identifier. Metadata (token usage, provider model name) is preserved so the calling Draft record can store it.

**Error classification:**
- [ ] Same rules as Integrations 1, 3, 4: 5xx transient, 4xx permanent, timeout transient, connection refusal transient-network, 3xx unexpected-status, catch-all pass-through. No silent rescues. The client does not retry internally; Oban owns retry policy.

**Test stance:**
- [ ] `Req.Test` stubbed from day one. Tests cover a happy-path batch for each content kind, 429 transient, 500 transient, 400 permanent, and missing-config no-HTTP downgrade.

**Out of scope for this slice:**
- [ ] Changing any caller to use the new client. The bulk-generator swap is its own slice (11.2 caller).
- [ ] Streaming responses or incremental delivery; the slice ships a single request-per-batch surface.
- [ ] Feeding performance scoreboard data into generation prompts; that wiring lives in 11.4.



