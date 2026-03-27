# Ralph Loop Prompt: ContentForge Phase 1

## Command

```
openclaw agent --agent coding --message "/ralph-loop Build ContentForge Phase 1 (Foundation) per the spec at ~/projects/content-forge/CONTENT_FORGE_SPEC.md. Work in ~/projects/content-forge/. Steps each iteration: 1) Read CONTENT_FORGE_SPEC.md Phase 1 checklist. 2) Identify the next uncompleted item (1a through 1e in order, respecting dependencies: 1d depends on 1a+1b, 1e depends on 1d). 3) Implement it fully with TDD (write failing test first, then make it pass). 4) Run mix compile --warnings-as-errors && mix format && mix test. All must pass. 5) Commit with a descriptive message. 6) Check off the item in CONTENT_FORGE_SPEC.md. 7) If all Phase 1 items are checked, output the completion promise.

Details per item:
- 1a: mix phx.new content_forge --database postgres, add oban + exaws_s3 + req + zyzyva_telemetry deps, configure Oban in application.ex, create Product schema (name, repo_url, site_url, voice_profile text field, publishing_targets as jsonb map of platform configs with enabled/cadence per platform). Run mix ecto.create && mix ecto.migrate.
- 1b: REST API skeleton under /api with bearer token auth plug, JSON error helpers, versioned routes (/api/v1/...). Create an ApiKey schema (encrypted key, label, active boolean). Auth plug checks Authorization header against active keys.
- 1c: ContentForge.Storage module wrapping ExAws.S3 for R2 (put_object, get_object, presigned_url). Config reads R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, CLOUDFLARE_ACCOUNT_ID from env. Write tests with Mox.
- 1d: Product CRUD context (ContentForge.Products), LiveView UI (list + form + detail), API endpoints (GET/POST/PUT/DELETE /api/v1/products). Validate publishing_targets structure. Full test coverage for context + controller + LiveView.
- 1e: BlogWebhook schema (product_id, url, hmac_secret encrypted, active). CRUD in Products context. HMAC signing utility using :crypto.mac. API endpoints for webhook management. Tests.

Elixir conventions: Use native JSON module (not Jason), function head pattern matching over case/if, Logger not IO.puts, verified routes (~p sigil). Follow the project CLAUDE.md once it exists.

--completion-promise 'PHASE_1_COMPLETE' --max-iterations 50"
```
