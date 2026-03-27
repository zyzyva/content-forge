# Ralph Loop Prompt: ContentForge Phase 1

## Command

```
/ralph-loop Build ContentForge Phase 1 (Foundation) per the spec at ~/projects/content-forge/CONTENT_FORGE_SPEC.md. Work in ~/projects/content-forge/.

Steps each iteration:

1) Read CONTENT_FORGE_SPEC.md Phase 1 checklist.
2) Identify the next uncompleted item (1a through 1e in order, respecting dependencies: 1d depends on 1a+1b, 1e depends on 1d).
3) Implement it fully with TDD (write failing test first, then make it pass).
4) Run mix compile --warnings-as-errors && mix format && mix test. All must pass.
5) Commit with a descriptive message and push.
6) Check off the item in CONTENT_FORGE_SPEC.md.
7) When ALL Phase 1 items (1a-1e) are checked off, run the REVIEW STEP below.
8) If the review passes with no critical issues, output the completion promise.
9) If the review finds issues, fix them, re-run tests, commit, and re-run the review. Repeat until clean.

REVIEW STEP (run after all items complete):
Run this exact command and save the output:
bash pty:true timeout:300 workdir:~/projects/content-forge command:"claude -p 'Review the full codebase for Phase 1 of ContentForge. Read CONTENT_FORGE_SPEC.md Phase 1 requirements. Then review all code in lib/, test/, and config/. Check: 1) Every acceptance criterion in Phase 1 is implemented and tested. 2) Code follows Elixir conventions (native JSON module, function head pattern matching, Logger, verified routes). 3) No compilation warnings. 4) Test coverage is thorough (not placeholder tests). 5) Security: API key auth is solid, HMAC signing is correct, no secrets in code. 6) Schema design is clean. Report any issues as CRITICAL (must fix) or MINOR (nice to have). If no critical issues, end with REVIEW_PASSED.' --permission-mode bypassPermissions --output-format text"

Read the review output. If it contains REVIEW_PASSED, proceed to completion. If it contains CRITICAL issues, fix each one, re-run tests, commit, and re-run the review command.

Details per item:
- 1a: mix phx.new content_forge --database postgres, add oban + exaws_s3 + req + zyzyva_telemetry deps, configure Oban in application.ex, create Product schema (name, repo_url, site_url, voice_profile text field, publishing_targets as jsonb map of platform configs with enabled/cadence per platform). Run mix ecto.create && mix ecto.migrate.
- 1b: REST API skeleton under /api with bearer token auth plug, JSON error helpers, versioned routes (/api/v1/...). Create an ApiKey schema (encrypted key, label, active boolean). Auth plug checks Authorization header against active keys.
- 1c: ContentForge.Storage module wrapping ExAws.S3 for R2 (put_object, get_object, presigned_url). Config reads R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, CLOUDFLARE_ACCOUNT_ID from env. Write tests with Mox.
- 1d: Product CRUD context (ContentForge.Products), LiveView UI (list + form + detail), API endpoints (GET/POST/PUT/DELETE /api/v1/products). Validate publishing_targets structure. voice_profile is required before generation runs. Full test coverage for context + controller + LiveView.
- 1e: BlogWebhook schema (product_id, url, hmac_secret encrypted, active). CRUD in Products context. HMAC signing utility using :crypto.mac. API endpoints for webhook management. Tests.

Elixir conventions: Use native JSON module (not Jason), function head pattern matching over case/if, Logger not IO.puts, verified routes (~p sigil). Follow the project CLAUDE.md once it exists.

--completion-promise "PHASE_1_COMPLETE" --max-iterations 50
```

## Chaining to Phase 2

When Phase 1 completes, OC can automatically kick off Phase 2 by adding this to the end of the prompt:

"After outputting PHASE_1_COMPLETE, immediately start a new ralph-loop for Phase 2 using ~/projects/content-forge/RALPH_PHASE2.md"

Or keep phases separate and let OC message you when each one finishes.
