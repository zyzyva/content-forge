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
7) Log progress to Lead Intelligence: call the log_plan_result MCP tool with plan_id 13 and a note like "Completed 1a: schema setup" (use the actual item and a brief description).
8) When ALL Phase 1 items (1a-1e) are checked off, run the REVIEW STEP below.
9) If the review passes with no critical issues, output the completion promise.
10) If the review finds issues, fix them, re-run tests, commit, and re-run the review. Repeat until clean.

REVIEW STEP (run after all items complete):
Run this exact command and save the output:
bash pty:true timeout:300 workdir:~/projects/content-forge command:"claude --model claude-opus-4-6 --effort high -p 'Review the full codebase for Phase 1 of ContentForge. Read CONTENT_FORGE_SPEC.md Phase 1 requirements. Then review all code in lib/, test/, and config/. Check: 1) Every acceptance criterion in Phase 1 is implemented and tested. 2) Code follows Elixir conventions (native JSON module, function head pattern matching, Logger, verified routes). 3) No compilation warnings. 4) Test coverage is thorough (not placeholder tests). 5) Security: API key auth is solid, HMAC signing is correct, no secrets in code. 6) Schema design is clean. Report any issues as CRITICAL (must fix) or MINOR (nice to have). If no critical issues, end with REVIEW_PASSED.' --permission-mode auto --output-format text"

Read the review output. If it contains REVIEW_PASSED, do the COMPLETION STEP. If it contains CRITICAL issues, fix each one, re-run tests, commit, and re-run the review command.

COMPLETION STEP (only after REVIEW_PASSED):
1) Call the complete_plan_step MCP tool with plan_id 13 and step text "Phase 1: Foundation (1a schema, 1b API auth, 1c R2 storage, 1d Product CRUD, 1e webhooks)".
2) Call the log_plan_result MCP tool with plan_id 13 and message "Phase 1 complete. All items 1a-1e implemented, tested, reviewed. REVIEW_PASSED."
3) Run: bash command:"openclaw message send --target telegram --message 'ContentForge Phase 1 complete. All items done and reviewed. Ready to kick off Phase 2.'"
4) Output the completion promise.

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

When you get the Telegram notification that Phase 1 is complete, kick off Phase 2:

```bash
claude --permission-mode auto -p "$(cat ~/projects/content-forge/RALPH_PHASE2.md | grep -A1000 '^\`\`\`$' | tail -n +2 | head -n -1)"
```

Or ask OC to do it: "Phase 1 is done, kick off the Phase 2 ralph loop for ContentForge per RALPH_PHASE2.md"
