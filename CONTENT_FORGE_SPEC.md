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
- [ ] Content brief generation queries at least 2 smart models and stores the synthesized brief per product with a timestamp and version number
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
- [ ] Image generation: every social post that passes ranking gets an AI-generated image. A smart model writes an image prompt from the post text + product branding. Image is generated via configurable provider (Flux/DALL-E), stored in R2, and linked to the draft. Image generation runs as an Oban job after ranking, before scheduling.
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

### Integration 1: Media Forge HTTP Client

**Purpose:** Provide a single named client module that every Content Forge caller uses to talk to the Media Forge service. The module centralizes the base URL, the shared secret header, retry semantics, and transient-versus-permanent error classification so individual features (image generation, final video encoding, image processing, platform renditions) do not each reinvent them. Every future Media Forge call in the codebase goes through this module; nothing else touches the underlying HTTP layer for Media Forge URLs.

**Why this matters:** Media Forge is the ecosystem's media service. Without a shared client, every caller repeats authentication, drifts in retry behavior, and gets inconsistent at classifying transient versus permanent errors. A single stubbable client also means tests never hit the live service, which matters because the dev instance runs on a different machine on the LAN and is not reliably reachable from CI. This slice delivers the client and its tests only. Swapping existing Content Forge callers (the image generator, the video pipeline, image pre-processing, platform renditions) over to this client is tracked under Phase 10.2 and later slices in `BUILDPLAN.md`.

**Module location and shape:**
- [ ] The public client module is `ContentForge.MediaForge` located under `lib/content_forge/media_forge/`. Internal supporting modules may be introduced as siblings if they keep the public surface narrow, for example an inner HTTP client module and a configuration reader module. Callers outside this directory only ever reference the public module.
- [ ] The module exposes exactly the call functions listed below. It does not expose raw HTTP helpers, raw Req wrappers, or the underlying adapter configuration.

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
- [ ] A 5xx response from Media Forge, or a timeout from the HTTP layer, is returned as a transient error tuple whose second element is the reason. Callers may retry transient errors through their Oban backoff policy.
- [ ] A 4xx response is returned as a permanent error tuple whose elements are the HTTP status code and the response body. Callers must not retry a permanent error without changing the input.
- [ ] A connection refusal or other network-layer failure (DNS failure, refused socket) is returned as a transient error tuple whose reason is network. Callers may retry.
- [ ] Any other unexpected condition is returned as a plain error tuple with enough detail in the reason to diagnose from logs. The client does not rescue-and-swallow these conditions silently.

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

