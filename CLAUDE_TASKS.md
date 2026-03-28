# CLAUDE_TASKS.md
# Claude's review queue. Claude reviews OC's code, writes real tests, fixes issues, marks [stable].
# States: [ ] pending → [stable] done

## Feature 1: Product Registry
Files: lib/content_forge/products/product.ex, lib/content_forge/products/blog_webhook.ex, lib/content_forge/accounts/api_key.ex, lib/content_forge/accounts.ex, lib/content_forge/products.ex, lib/content_forge_web/plugs/api_auth.ex, lib/content_forge_web/controllers/product_controller.ex, lib/content_forge_web/controllers/product_json.ex
Commit: 78f9d41

- [ ] Product schema has all required fields: name, repo_url (optional), site_url (optional), voice_profile (required), publishing_targets (jsonb), and links to blog webhooks
- [ ] Products CRUD context functions work correctly (create/read/update/delete)
- [ ] Product API endpoints (GET/POST/PUT/DELETE /api/v1/products) work and return correct JSON
- [ ] BlogWebhook schema has product_id, url, hmac_secret, active; CRUD works
- [ ] ApiKey schema has encrypted key, label, active; auth plug rejects invalid/inactive keys
- [ ] Generation is blocked when voice_profile is nil (context enforces this)

## Feature 2: Content Ingestion Pipeline
Files: lib/content_forge/jobs/repo_ingestion.ex, lib/content_forge/jobs/site_crawler.ex, lib/content_forge/products/product_snapshot.ex, lib/content_forge/storage.ex
Commit: b3cd471

- [ ] RepoIngestion job clones to temp dir, extracts README/docs/source files up to token limit, stores snapshot in R2, cleans up temp dir
- [ ] SiteCrawler job fetches N pages (configurable), extracts text + metadata, stores in R2
- [ ] ProductSnapshot schema links snapshot metadata (type, r2_keys, token_count) to product
- [ ] Storage module wraps R2 correctly (put_object, get_object, presigned_url)
- [ ] Both jobs have Oban retry config

## Feature 3: AI Content Generation Pipeline
Files: lib/content_forge/products/content_brief.ex, lib/content_forge/products/brief_version.ex, lib/content_forge/content_generation/draft.ex, lib/content_forge/content_generation/draft_score.ex, lib/content_forge/content_generation.ex, lib/content_forge/jobs/content_brief_generator.ex, lib/content_forge/jobs/open_claw_bulk_generator.ex, lib/content_forge/jobs/multi_model_ranker.ex, lib/content_forge/jobs/script_gate.ex, lib/content_forge/jobs/image_generator.ex, lib/content_forge/jobs/winner_repurposing_engine.ex
Commit: c0b1ccd

- [ ] ContentBrief schema has product_id, version, body text, timestamp; BriefVersion keeps history
- [ ] Draft schema has content, platform, angle, generating_model, composite_score, status (draft/ranked/approved/rejected/published)
- [ ] DraftScore schema has draft_id, model_name, accuracy_score, seo_score, eev_score, critique
- [ ] ContentGeneration context CRUD functions work for drafts and scores
- [ ] ContentBriefGenerator job queries smart models, stores brief with version history
- [ ] OpenClawBulkGenerator job calls OpenClaw API, generates N variants per platform with required humor angle
- [ ] MultiModelRanker job scores each draft with per-model scores, computes composite, promotes top N
- [ ] ScriptGate job filters video scripts by configurable threshold
- [ ] All generation/ranking jobs have Oban retry config
- [ ] Draft API endpoints accessible and correct

## Feature 3.5: Competitor Content Monitoring
Files: lib/content_forge/products/competitor_account.ex, lib/content_forge/products/competitor_post.ex, lib/content_forge/products/competitor_intel.ex, lib/content_forge/jobs/competitor_scraper.ex, lib/content_forge/jobs/competitor_intel_synthesizer.ex, lib/content_forge_web/controllers/competitor_controller.ex
Commit: b3cd471

- [ ] CompetitorAccount schema has product_id, platform, handle, url, active; CRUD works
- [ ] CompetitorPost schema has competitor_account_id, content, engagement_score, raw_data
- [ ] CompetitorIntel schema has product_id, summary, source_count, created_at
- [ ] CompetitorScraper job iterates accounts, calls Apify, scores posts by engagement relative to account average
- [ ] CompetitorIntelSynthesizer job sends top posts to smart model, stores synthesis
- [ ] Competitor API endpoints (POST/GET/DELETE /api/v1/products/:id/competitors) work

## Feature 4: Short-form Publishing
Files: lib/content_forge/publishing/twitter.ex, lib/content_forge/publishing/linkedin.ex, lib/content_forge/publishing/reddit.ex, lib/content_forge/publishing/facebook.ex, lib/content_forge/publishing/published_post.ex, lib/content_forge/publishing/engagement_metric.ex, lib/content_forge/publishing.ex, lib/content_forge/jobs/publisher.ex, lib/content_forge/jobs/publishing_scheduler.ex, lib/content_forge_web/controllers/schedule_controller.ex
Commit: 9784bbb

- [ ] Platform connectors (Twitter, LinkedIn, Reddit, Facebook) have correct API client structure with OAuth2
- [ ] PublishedPost schema has draft_id, platform, post_id, url, published_at
- [ ] EngagementMetric schema has published_post_id, platform, metrics jsonb, measured_at
- [ ] Publisher job calls correct platform connector, records published post
- [ ] PublishingScheduler schedules approved drafts respecting per-platform cadence from product config
- [ ] Schedule API endpoints work
