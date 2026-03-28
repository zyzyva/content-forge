# CLAUDE_TASKS.md
# Claude's review queue. Claude reviews OC's code, writes real tests, fixes issues, marks [stable].
# States: [ ] pending → [stable] done

## Feature 1: Product Registry
Files: lib/content_forge/products/product.ex, lib/content_forge/products/blog_webhook.ex, lib/content_forge/accounts/api_key.ex, lib/content_forge/accounts.ex, lib/content_forge/products.ex, lib/content_forge_web/plugs/api_auth.ex, lib/content_forge_web/controllers/product_controller.ex, lib/content_forge_web/controllers/product_json.ex
Commit: 78f9d41

- [stable] Product schema has all required fields: name, repo_url (optional), site_url (optional), voice_profile (required), publishing_targets (jsonb), and links to blog webhooks
- [stable] Products CRUD context functions work correctly (create/read/update/delete)
- [stable] Product API endpoints (GET/POST/PUT/DELETE /api/v1/products) work and return correct JSON
- [stable] BlogWebhook schema has product_id, url, hmac_secret, active; CRUD works
- [stable] ApiKey schema has encrypted key, label, active; auth plug rejects invalid/inactive keys
- [stable] Generation is blocked when voice_profile is nil (context enforces this)

## Feature 2: Content Ingestion Pipeline
Files: lib/content_forge/jobs/repo_ingestion.ex, lib/content_forge/jobs/site_crawler.ex, lib/content_forge/products/product_snapshot.ex, lib/content_forge/storage.ex
Commit: b3cd471

- [stable] RepoIngestion job clones to temp dir, extracts README/docs/source files up to token limit, stores snapshot in R2, cleans up temp dir
- [stable] SiteCrawler job fetches N pages (configurable), extracts text + metadata, stores in R2
- [stable] ProductSnapshot schema links snapshot metadata (type, r2_keys, token_count) to product
- [stable] Storage module wraps R2 correctly (put_object, get_object, presigned_url)
- [stable] Both jobs have Oban retry config

## Feature 3: AI Content Generation Pipeline
Files: lib/content_forge/products/content_brief.ex, lib/content_forge/products/brief_version.ex, lib/content_forge/content_generation/draft.ex, lib/content_forge/content_generation/draft_score.ex, lib/content_forge/content_generation.ex, lib/content_forge/jobs/content_brief_generator.ex, lib/content_forge/jobs/open_claw_bulk_generator.ex, lib/content_forge/jobs/multi_model_ranker.ex, lib/content_forge/jobs/script_gate.ex, lib/content_forge/jobs/image_generator.ex, lib/content_forge/jobs/winner_repurposing_engine.ex
Commit: c0b1ccd

- [stable] ContentBrief schema has product_id, version, body text, timestamp; BriefVersion keeps history
- [stable] Draft schema has content, platform, angle, generating_model, composite_score, status (draft/ranked/approved/rejected/published)
- [stable] DraftScore schema has draft_id, model_name, accuracy_score, seo_score, eev_score, critique
- [stable] ContentGeneration context CRUD functions work for drafts and scores
- [stable] ContentBriefGenerator job queries smart models, stores brief with version history
- [stable] OpenClawBulkGenerator job calls OpenClaw API, generates N variants per platform with required humor angle
- [stable] MultiModelRanker job scores each draft with per-model scores, computes composite, promotes top N
- [stable] ScriptGate job filters video scripts by configurable threshold
- [stable] All generation/ranking jobs have Oban retry config
- [stable] Draft API endpoints accessible and correct

## Feature 3.5: Competitor Content Monitoring
Files: lib/content_forge/products/competitor_account.ex, lib/content_forge/products/competitor_post.ex, lib/content_forge/products/competitor_intel.ex, lib/content_forge/jobs/competitor_scraper.ex, lib/content_forge/jobs/competitor_intel_synthesizer.ex, lib/content_forge_web/controllers/competitor_controller.ex
Commit: b3cd471

- [stable] CompetitorAccount schema has product_id, platform, handle, url, active; CRUD works
- [stable] CompetitorPost schema has competitor_account_id, content, engagement_score, raw_data
- [stable] CompetitorIntel schema has product_id, summary, source_count, created_at
- [stable] CompetitorScraper job iterates accounts, calls Apify, scores posts by engagement relative to account average
- [stable] CompetitorIntelSynthesizer job sends top posts to smart model, stores synthesis
- [stable] Competitor API endpoints (POST/GET/DELETE /api/v1/products/:id/competitors) work

## Feature 4: Short-form Publishing
Files: lib/content_forge/publishing/twitter.ex, lib/content_forge/publishing/linkedin.ex, lib/content_forge/publishing/reddit.ex, lib/content_forge/publishing/facebook.ex, lib/content_forge/publishing/published_post.ex, lib/content_forge/publishing/engagement_metric.ex, lib/content_forge/publishing.ex, lib/content_forge/jobs/publisher.ex, lib/content_forge/jobs/publishing_scheduler.ex, lib/content_forge_web/controllers/schedule_controller.ex
Commit: 9784bbb

- [stable] Platform connectors (Twitter, LinkedIn, Reddit, Facebook) have correct API client structure with OAuth2
- [stable] PublishedPost schema has draft_id, platform, post_id, url, published_at
- [stable] EngagementMetric schema has published_post_id, platform, metrics jsonb, measured_at
- [stable] Publisher job calls correct platform connector, records published post
- [stable] PublishingScheduler schedules approved drafts respecting per-platform cadence from product config
- [stable] Schedule API endpoints work

## Feature 5: Blog Publishing
Files: lib/content_forge/publishing/webhook_delivery.ex, lib/content_forge/jobs/blog_publisher.ex, priv/repo/migrations/20250327230011_create_webhook_deliveries.exs
Commit: dc466a7

- [stable] WebhookDelivery schema: product_id, blog_webhook_id, draft_id, status (pending/success/failed), delivered_at, error, timestamps
- [stable] BlogPublisher Oban job (max_attempts: 3): stores markdown in R2 with stable URL (`blogs/{product_slug}/{draft_id}.md`), POSTs to each active webhook, HMAC-signs when secret present, records delivery status
- [stable] Context functions for WebhookDelivery CRUD exist in ContentForge.Publishing

## Feature 6: Video Production Pipeline
Files: lib/content_forge/publishing/video_job.ex, lib/content_forge/publishing/youtube.ex, lib/content_forge/jobs/video_producer.ex, priv/repo/migrations/20250327230012_create_video_jobs.exs
Commit: c217847

- [stable] VideoJob schema: draft_id, product_id, status enum (script_approved→voiceover_done→recording_done→avatar_done→assembled→uploaded), per_step_r2_keys (jsonb), error, feature_flag
- [stable] VideoProducer Oban job: 6-step pipeline (ElevenLabs→Playwright→HeyGen→Remotion→FFmpeg→YouTube), each step updates status, retries 3x then pauses on failure
- [stable] YouTube connector: OAuth2 with encrypted token refresh, multipart upload, AI-generated title/description/tags/thumbnail
