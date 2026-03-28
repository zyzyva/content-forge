# CLAW_TASKS.md
# OC's build queue. OC picks the first [ ] item whose dependencies are all [stable] in CLAUDE_TASKS.md.
# States: [ ] todo → [built] done, awaiting Claude review
# After marking [built], append a review entry to CLAUDE_TASKS.md with the commit hash.

## Rules
- Only start a task when ALL listed dependencies are [stable] in CLAUDE_TASKS.md
- Mark [built] when code compiles clean (mix compile --warnings-as-errors passes) and committed
- Never modify files listed in a [stable] CLAUDE_TASKS entry
- Append review entry to CLAUDE_TASKS.md when marking [built]

---

## Feature 5: Blog Publishing
Dependencies: Feature 1 [stable] (BlogWebhook schema), Feature 3 [stable] (Draft schema)
Files to create: lib/content_forge/jobs/blog_publisher.ex, priv/repo/migrations/*_create_webhook_deliveries.exs, lib/content_forge/products/webhook_delivery.ex

- [ ] WebhookDelivery schema: product_id, blog_webhook_id, draft_id, status (pending/success/failed), delivered_at, error
- [ ] BlogPublisher Oban job: on draft approval for blog type, store markdown in R2, POST to each active webhook with title/r2_url/product_slug/timestamp, HMAC-sign when secret present, record delivery status, retry on failure

---

## Feature 6: Video Production Pipeline
Dependencies: Feature 3 [stable] (ScriptGate, Draft schema)
Files to create: lib/content_forge/jobs/video_producer.ex, lib/content_forge/publishing/youtube.ex, lib/content_forge/publishing/video_job.ex, priv/repo/migrations/*_create_video_jobs.exs

- [ ] VideoJob schema: draft_id (script), status enum (script_approved/voiceover_done/recording_done/avatar_done/assembled/uploaded), per-step r2_keys, error, feature_flag (enabled per product)
- [ ] VideoProducer Oban job pipeline: ElevenLabs voiceover → Playwright screen recording → HeyGen avatar → Remotion assembly → FFmpeg encode → YouTube upload. Each step updates VideoJob status. Failed step retries 3x then pauses job.
- [ ] YouTube connector: OAuth2 client with encrypted token storage, upload video with AI-generated title/description/tags/thumbnail

---

## Feature 7: Performance Metrics & Feedback Loop
Dependencies: Feature 4 [stable] (PublishedPost), Feature 6 [stable] (VideoJob)
Files to create: lib/content_forge/metrics.ex, lib/content_forge/metrics/scoreboard_entry.ex, lib/content_forge/metrics/model_calibration.ex, lib/content_forge/metrics/clip_flag.ex, lib/content_forge/jobs/metrics_poller.ex, lib/content_forge/jobs/brief_rewrite_trigger.ex, priv/repo/migrations/*_create_metrics_tables.exs

- [ ] ContentScoreboard schema: content_id, product_id, platform, angle, format, composite_ai_score, actual_engagement_score, delta, per_model_scores jsonb, outcome (winner/loser/pending), measured_at timestamps
- [ ] ModelCalibration schema: model_name, product_id, platform, angle, avg_score_delta, sample_count, last_updated
- [ ] MetricsPoller job: pulls platform metrics at 24h/7d/30d intervals, updates scoreboard, labels winner/loser vs rolling average, updates model calibration, triggers engagement spike alerts and comment flagging, triggers brief rewrite when 5+ new measured pieces
- [ ] ClipFlag schema + detection: parses YouTube retention curve, flags high-engagement segments with timestamp range and suggested title
- [ ] Metrics API endpoints: GET /api/products/:id/scoreboard, /calibration, /metrics, /hot, /needs-reply; GET /api/videos/:id/retention

---

## Feature 8: Content Review API
Dependencies: Feature 3 [stable], Feature 7 [stable]
Files to modify: lib/content_forge_web/router.ex, existing controllers

- [ ] All draft endpoints already exist — verify GET/POST /api/drafts, POST /api/drafts/:id/approve|reject|score work end to end
- [ ] POST /api/products/:id/generate triggers generation run
- [ ] GET /api/products/:id/brief returns current brief with performance summary
- [ ] POST /api/videos/:id/clip approves flagged segment for short-form clip production

---

## Feature 9: LiveView Dashboard
Dependencies: Features 1-8 [stable]
Files to create: lib/content_forge_web/live/*.ex, assets/

- [ ] Products list LiveView with quick-add form
- [ ] Per-product detail LiveView: snapshot status, brief, draft queue, publishing history
- [ ] Draft review queue LiveView: composite score, per-model scores, critiques, approve/reject
- [ ] Schedule view LiveView: calendar/timeline of upcoming and past posts
- [ ] Video production status board LiveView
- [ ] Performance dashboard LiveView: engagement trends, retention curves, clip queue
- [ ] All views mobile-responsive and WCAG AA accessible
