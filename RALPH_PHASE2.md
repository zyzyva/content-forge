# Ralph Loop Prompt: ContentForge Phase 2

## Command

```
/ralph-loop Build ContentForge Phase 2 (Content Ingestion + Competitor Intelligence) per the spec at ~/projects/content-forge/CONTENT_FORGE_SPEC.md. Work in ~/projects/content-forge/. Phase 1 must already be complete.

Steps each iteration:

1) Read CONTENT_FORGE_SPEC.md Phase 2 checklist.
2) Identify the next uncompleted item (2a through 2f in order, respecting dependencies: 2c depends on 2a+2b, 2e depends on 2d, 2f depends on 2e. Items 2a, 2b, 2d are independent -- pick whichever is next unchecked).
3) Implement it fully with TDD (write failing test first, then make it pass).
4) Run mix compile --warnings-as-errors && mix format && mix test. All must pass.
5) Commit with a descriptive message and push.
6) Check off the item in CONTENT_FORGE_SPEC.md.
7) When ALL Phase 2 items (2a-2f) are checked off, run the REVIEW STEP below.
8) If the review passes with no critical issues, output the completion promise.
9) If the review finds issues, fix them, re-run tests, commit, and re-run the review.

REVIEW STEP:
bash pty:true timeout:300 workdir:~/projects/content-forge command:"claude -p 'Review Phase 2 of ContentForge. Read CONTENT_FORGE_SPEC.md Phase 2 requirements. Review all new code added for Phase 2 (git diff main..HEAD or review lib/content_forge/ingestion/, lib/content_forge/competitors/, and related files). Check: 1) Every Phase 2 acceptance criterion is implemented and tested. 2) Repo cloning handles errors gracefully (missing repos, auth failures, huge repos). 3) Site crawler respects configurable page limits and handles broken pages. 4) Competitor scraper uses Apify correctly with rate limiting. 5) Competitor intel synthesizer calls a smart model and stores results properly. 6) Snapshots are stored in R2 with correct metadata. 7) All Oban jobs have retry logic. 8) Tests are thorough, not placeholders. Report CRITICAL or MINOR issues. End with REVIEW_PASSED if no critical issues.' --permission-mode bypassPermissions --output-format text"

Details per item:
- 2a: Oban job that git clones a repo URL to a temp dir, reads README, docs/, CHANGELOG, key source files (lib/, src/). Extracts text up to configurable token limit. Stores as a product snapshot in R2. Cleans up temp dir. Tests with mocked git clone.
- 2b: Oban job that crawls up to N pages (configurable, default 10) from a site URL. Extracts text content, headings, metadata. Captures screenshots of key pages via Playwright/Chrome DevTools. Stores all in R2 as snapshot. Tests with mocked HTTP.
- 2c: ProductSnapshot schema (product_id, snapshot_type repo/site, r2_keys jsonb, token_count, created_at). Context functions to create/list/get snapshots. Link to product. Migration.
- 2d: CompetitorAccount schema (product_id, platform, handle, url, active). CRUD in Products context. API endpoints: POST/GET/DELETE /api/v1/products/:id/competitors. Tests.
- 2e: Oban job that iterates competitor accounts for a product, scrapes recent posts via Apify (use appropriate actor per platform -- Twitter scraper, LinkedIn scraper, etc.). Scores posts by engagement relative to account average. Stores raw scraped data. Configurable cadence (default weekly). Tests with mocked Apify.
- 2f: Oban job triggered after 2e completes. Sends top-performing competitor posts to a smart model (Claude/Gemini) with prompt: "Analyze these top-performing competitor posts. Identify trending topics, winning formats, effective hooks, and engagement patterns." Stores the synthesis as competitor_intel (product_id, summary text, source_count, created_at). Tests with mocked LLM.

Elixir conventions: native JSON module, function head pattern matching, Logger, verified routes.

--completion-promise "PHASE_2_COMPLETE" --max-iterations 50
```
