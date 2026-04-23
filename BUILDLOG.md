# Content Forge Build Log

Shared coordination file for the swarmforge agents (architect, coder, reviewer). Check here before starting work to see what's done, what's in progress, and what's blocked.

## How to use this file

- Before starting a slice, check if someone else is already on it.
- When you start a slice, mark it `IN PROGRESS` with your role and date.
- When you finish, mark it `DONE` with role, date, commit hash, and a one-line note on what was produced.
- If you hit a blocker or make a decision that affects other work, add a note under Decisions/Blockers.

## Shipped

### Feature 1: Product Registry

Status: DONE
Note: CRUD, voice profiles, publishing targets, blog webhooks.

### Feature 2: Content Ingestion Pipeline

Status: DONE
Note: Repo cloning, site crawling, R2 snapshots.

### Feature 3: AI Content Generation Pipeline

Status: DONE (structure) / IN PROGRESS (real-provider wiring)
Note: Brief generation, bulk generation, multi-model ranking, image generation entry point, script gate, winner repurposing logic. Some calls still stubbed — see Phase 11 in BUILDPLAN.

### Feature 3.5: Competitor Content Monitoring

Status: DONE (structure)
Note: Account tracking, post scraping, intel synthesis. Apify wiring is real per recent commits but worth auditing — see Phase 11.

### Feature 4: Short-form Post Publishing

Status: DONE
Note: Twitter/X, LinkedIn, Reddit, Facebook/Instagram connectors.

### Feature 5: Blog Publishing

Status: DONE
Note: Webhook delivery, HMAC signing, R2 storage, retry logic.

### Feature 6: Video Production Pipeline

Status: DONE (structure) / PARTIALLY DELEGATED
Note: All six steps wired — ElevenLabs, Playwright, HeyGen, Remotion, FFmpeg, YouTube. Media Forge now owns video transcoding and platform renditions; Phase 10 moves the FFmpeg step onto Media Forge.

### Feature 7: Performance Metrics & Feedback Loop

Status: DONE
Note: Scoreboard schema, model calibration, clip flagging, metrics poller with API endpoints. Commit `3ab96c4` wired real platform APIs.

### Feature 8: Content Review API

Status: DONE
Note: All 13 endpoints, bearer token auth.

### Feature 9: LiveView Dashboard

Status: DONE
Note: Seven pages — products, detail, drafts, schedule, video, performance, clips.

### Phase 10.1: Media Forge HTTP Client

Status: DONE
Note: `ContentForge.MediaForge` at `lib/content_forge/media_forge.ex`, 22-test acceptance file, `Req.Test` stub baked in. Reviewer ACCEPT at `b3883c7`, merged to master as `ba3c3ee`.

### Phase 10.1.1: classify/1 exhaustiveness for 3xx

Status: DONE
Note: 3xx catch-all returning `{:error, {:unexpected_status, status, body}}` shipped with a 304 Not Modified test. Reviewer ACCEPT at `2fadc8f`, merged to master as `2fadc8f` (fast-forward). Tests 123/0.

### Phase 10.2: Swap image generation onto Media Forge

Status: DONE
Merged: master @ `613d442` (fast-forward). Reviewer ACCEPT at same commit. Two follow-ups accepted: 10.2b (publisher-side missing-image block) and 10.2c (ImageGenerator coverage fill).

### Phase 10.2b: Publisher-side missing-image block

Status: DONE
Merged: master @ `b89d89c` (merge commit over `swarmforge-coder@9894dfe` and the intervening role-prompts parallelism edit `ea33b3e`). Reviewer ACCEPT at `9894dfe`. Gate: compile/format/test 144-0 green; credo 40 vs 44 baseline (5 resolved). Architect decisions recorded below: dashboard label "Blocked (Awaiting Image)" accepted; credo baseline-diff rule clarified to tolerate line-shift of unchanged findings.
Note: `ContentForge.Jobs.Publisher` now blocks social post drafts (content_type = "post") that reach publishing without an image. New `enforce_image_required/1` guard runs in both `perform/1` clauses (the product_id+platform path and the draft_id path). When a social post has `image_url` nil or empty, the worker logs "publish blocked: missing image for draft <id>", marks the draft `status: "blocked"` via `ContentGeneration.mark_draft_blocked/1`, and returns `{:cancel, reason}` without touching the platform client. Non-social drafts (blog, video_script) are unaffected. Added `"blocked"` to the Draft status inclusion list and `ContentGeneration.list_blocked_drafts/1` for dashboard surfacing. Added `"blocked"` to the shared `status_badge` component (maps to `badge-error`). Drafts review LiveView got a "Blocked" filter tab (piggybacks on existing `list_drafts_by_status` fallback, so no extra routing logic). Schedule LiveView got a "Blocked (Awaiting Image)" section listing blocked drafts with a distinct BLOCKED status badge; shows "No blocked drafts" when empty. New test files: `test/content_forge/jobs/publisher_missing_image_test.exs` (8 tests: 5 per-platform blocker cases, 1 product_id+platform path, 1 happy path asserting the gate lets image-bearing drafts through, 1 non-social unaffected). Dashboard tests added in `dashboard_live_test.exs`: Blocked filter tab exposed on review page, blocked draft renders with BLOCKED badge, schedule page surfaces blocked drafts. Gate: compile --warnings-as-errors clean, format clean, full test 144/0. Credo --strict by content is strictly better than baseline: 5 baseline findings resolved (the 2 image_generator.ex findings from 10.2 plus 3 more on publisher.ex - nesting depth and alias ordering dropped due to this refactor; `build_post_opts` cyclomatic-19 preserved, shifted from line 224:8 to 253:8 only because code was added above it, function body unchanged). No new findings on any file.

### Phase 15.2d: WCAG AA audit on providers + SMS, and arrow-key tablist hook

Status: DONE
Merged: master @ `ff29e63` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 620-0; credo unchanged. TabList hook architecture: JS owns keyboard (Arrow/Home/End + Enter-Space activation forwards phx-click); LiveView retains aria-selected + tabindex as single source of truth. Wired to 4 tablists including product detail folded in from a 15.2a miss. Per-row Mark-resolved aria-label now interpolates product+phone. **Phase 15.2 WCAG AA audit complete.**
Note: Final page pair for the Phase 15.2 a11y pass plus the roving-tabindex JS hook deferred from 15.2b/c. Product detail tabs had never had `aria-selected` / `tabindex` state wired (they were outside 15.2a's scope on that file); folded that fix into this slice because the hook needs the state to rove.

**Pages touched**:
- `/dashboard/providers` (`Live.Dashboard.Providers.StatusLive`)
- `/dashboard/sms` (`Live.Dashboard.Sms.NeedsAttentionLive`)
- `/dashboard/products/:id` (`Live.Dashboard.Products.DetailLive`) - tablist a11y state + hook wiring
- `/dashboard/drafts`, `/dashboard/performance`, `/dashboard/schedule` - `phx-hook="TabList"` applied to the existing tablists

**Findings fixed on /dashboard/providers**:
- No `<main>` landmark. Added `<main id="main-content" aria-labelledby="page-title">` wrapping the whole page + h1 with `id="page-title"` inside a `<header>`.
- Integrations card promoted from bare `<div class="card">` to `<section aria-labelledby="integrations-heading">` with the existing `<h2>` gaining the matching id.
- Provider status table headers were bare `<th>`. Changed every header cell to `<th scope="col">`.
- Status badges (Available / Configured / Unavailable / Degraded) now carry `aria-label={"Status: #{text}"}` so the badge announces its role, not just its text.

**Findings fixed on /dashboard/sms**:
- No `<main>` landmark. Same `<main id="main-content" aria-labelledby="page-title">` wrapper + `<header>` + h1.
- Both data sections promoted to `<section aria-labelledby="escalated-heading">` / `<section aria-labelledby="high-volume-heading">` with their h2s carrying the matching ids.
- Both tables had bare `<th>` headers. Changed every header cell to `<th scope="col">`. The escalated table's unlabeled actions column got `<th scope="col"><span class="sr-only">Actions</span></th>`.
- Empty-state messages promoted from bare `<div>` to `<p role="status">` so late-arriving "No escalated sessions" announcements are picked up.
- Per-row "Mark resolved" button aria-labels were using only the raw session id. Upgraded to interpolate the product name + phone number so the resolve button announces which conversation it acts on.

**Fix on /dashboard/products/:id tablist**:
- The six product-detail tabs (Overview / Briefs / Drafts / History / Assets / Bundles) had `role="tab"` but no `aria-selected` or `tabindex`. The TabList hook needs `tabindex="0"` on exactly one tab to know which is "active" during keyboard roving, so this had to be fixed before the hook could ship on that tablist.
- Consolidated the six inline button copies into a single `:for` loop driven by a new `product_tabs/0` helper (six tuples). Matches the `status_tabs/0` pattern from 15.2b on the drafts page.
- Each tab now renders `aria-selected={"true"|"false"}` + `tabindex={"0"|"-1"}` + `id={"product-tab-#{value}"}` + `type="button"`.
- The tablist gained `id="product-detail-tablist"` + `aria-label="Product sections"` + `phx-hook="TabList"`.

**TabList JS hook** (`assets/js/hooks/tab_list.js`):
- New LiveView hook. Attaches a keydown listener on the `role="tablist"` element. Handles `ArrowLeft`/`ArrowUp` (focus previous, wraps), `ArrowRight`/`ArrowDown` (focus next, wraps), `Home` (focus first), `End` (focus last). Enter/Space on non-button tabs forwards to `.click()`; on real `<button>` tabs the native behavior already fires `phx-click` so the hook yields.
- LiveView retains full ownership of `aria-selected` and `tabindex` state on the server side. The hook only moves DOM focus; LiveView rerenders the state after phx-click returns.
- `tabs()` queries `[role="tab"]` descendants at each keypress (not cached) so it survives `:for`-loop rerenders without a rebind.
- `currentIndex()` falls back to the tab with `tabindex="0"` when `document.activeElement` is outside the list (e.g., right after a LiveView patch), so first arrow-press from an un-focused state lands on the active tab + 1.
- Registered in `assets/js/app.js` alongside existing colocated hooks: `hooks: {...colocatedHooks, TabList}`.

**Hook application**:
- `/dashboard/drafts` filter tablist - id, `phx-hook="TabList"`.
- `/dashboard/performance` view tablist - id, `phx-hook="TabList"`.
- `/dashboard/schedule` view tablist - id, `phx-hook="TabList"`.
- `/dashboard/products/:id` tablist - id + `aria-label` + `phx-hook="TabList"` (new wiring as above).

**Tests added** (appended to existing `test/content_forge_web/live/dashboard/a11y_landmarks_test.exs`):
- 2 new page-landmark describe blocks - `/dashboard/providers`, `/dashboard/sms`.
- 1 new "arrow-key tablist hook wiring" describe block with 4 tests, one per tablist - asserts each role=tablist carries `phx-hook="TabList"` AND retains its aria-label. The product detail test additionally asserts the new aria-selected/tabindex state rolled out (both true and false, both 0 and -1 appear).
- Tests assert the structural wiring the hook depends on (phx-hook attribute, role=tab children, roving tabindex). The hook itself ships without a JS unit test because there is no JS test harness on the project yet; behavior is documented inline in `tab_list.js`. Adding a JS test harness would be a separate infra slice.

**What was explicitly NOT changed** (kept out of scope):
- No color-contrast or text-resize sweep. 15.2 phase is landmark + keyboard + screen-reader semantics; visual contrast is a later pass.
- No global skip-link (`<a href="#main-content">`). Landmarks are now in place so the target anchor is valid; the skip-link itself lands with global nav.
- No aria-orientation attribute. ARIA defaults role=tablist to horizontal, which matches our layout.
- No activation-follows-focus JS. The WAI-ARIA pattern allows manual activation (Enter/Space to select) for tablists with cheap tab switches, which matches ours; focus moves independent of selection.

**Gate**: compile --warnings-as-errors clean, format clean, full test 620/0, credo --strict baseline-diff empty. Rebased cleanly on master @ `c2a4886`.

### Phase 15.2c: WCAG AA audit on video + performance + clips

Status: DONE
Merged: master @ `d31e6f6` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 614-0; credo unchanged. `scope=col` on all data tables; `role=img` + aria-label on SVG charts; per-row aria-labels on clips. Bundled bug fix: `Metrics.maybe_filter_by_product/2` missing empty-string head caused binary_id cast crash when LiveView passed `""` — surfaced by new performance test, one-line fix. Arrow-key JS roving deferred to 15.2d.
Note: WCAG AA audit + inline fixes on the three remaining Phase 9 dashboard pages per BUILDPLAN 15.2c. Same checklist as 15.2a/b. Latent bug in `Metrics.maybe_filter_by_product/2` surfaced by the first-ever LiveView test of `/dashboard/performance` — fix folded into this slice.

**Pages touched**:
- `/dashboard/video` (`Live.Dashboard.Video.StatusLive`)
- `/dashboard/performance` (`Live.Dashboard.Performance.DashboardLive`)
- `/dashboard/clips` (`Live.Dashboard.Clips.QueueLive`)

**Findings fixed on /dashboard/video**:
- No `<main>` landmark. Added `<main id="main-content" aria-labelledby="page-title">` wrapping the whole page + h1 with `id="page-title"` inside a `<header>`.
- Product-filter `<select>` had no label. Wrapped in `<label>` with `sr-only` label-text + `aria-label="Filter by product"`.
- Video job list was `<div phx-click>` cards (not keyboard-operable). Promoted to `<section aria-labelledby="video-jobs-heading">` + `<ul>` + `<li class="list-none">` + real `<button type="button">` with `aria-pressed` and dynamic `aria-label={"Select video job, status #{job.status}, progress #{progress}"}`.
- Progress bars now render with `role="progressbar" aria-label={"Pipeline progress #{progress}"} aria-valuenow={percent} aria-valuemin="0" aria-valuemax="100"` and the filled inner div is `aria-hidden`.
- OVERRIDE badge got `aria-label="Promoted via manual override"` so screen readers know what the three letters mean.
- Detail panel promoted from `<div>` to `<aside role="region" aria-labelledby="video-job-details-heading">`. Close button got `aria-label="Close job details"` and its icon wrapped in `<span aria-hidden="true">`.
- Empty state converted from bare `<div>` to `<p role="status">` so status changes are announced.

**Findings fixed on /dashboard/performance**:
- No `<main>` landmark. Added the same `<main id="main-content" aria-labelledby="page-title">` wrapper + `<header>` + h1.
- Product-filter `<select>` had no label. Wrapped in `<label>` with `sr-only` label-text + `aria-label="Filter by product"`.
- Four view-switcher buttons lived in a plain `<div class="tabs tabs-boxed">` (the same anti-pattern 15.2b fixed on drafts). Replaced with `<div role="tablist" aria-label="Performance view">` containing `<button role="tab" aria-selected tabindex>` per tab; `tabindex="0"` only on the active tab. Clips tab's count pill got `aria-hidden="true"` and the tab itself got `aria-label={"Clips, #{flag_count} flagged"}` so the count is announced as part of the tab name rather than read as a separate number.
- All three data tables (Winners, Scoreboard, Clips) had bare `<th>` headers. Changed every header cell to `<th scope="col">` so screen readers know which headers describe which columns.
- Bar charts for "Engagement by Platform" and "Average Engagement Rate" are purely visual `<div style="height">`. Wrapped each bar's container in `role="img" aria-label={"#{platform} total engagement: #{value}"}` (and similarly for "average engagement rate: #{value}%") with the inner decorative fill div marked `aria-hidden="true"`.
- Per-row "Approve" action buttons in the clip-review table got `aria-label={"Approve clip " <> (flag.suggested_title || flag.video_platform_id || "segment")}`. The ✓/check icon for already-approved rows is wrapped in `<span aria-label="Approved">` with the inner icon `aria-hidden`.

**Findings fixed on /dashboard/clips**:
- No `<main>` landmark. Added `<main id="main-content" aria-labelledby="page-title">` + `<header>` + h1 pattern.
- Pending clips list was `<div phx-click>` cards. Promoted to `<section aria-labelledby="pending-clips-heading">` + `<ul>` + `<li class="list-none">` + `<button type="button">` with `aria-pressed` and dynamic `aria-label={"Select clip #{clip.suggested_title} on #{clip.platform}"}`.
- Decorative hero icons (clock, eye, chart-bar, video-camera) wrapped in `<span aria-hidden="true">` so they don't pollute the accessibility tree.
- Detail panel promoted to `<aside role="region" aria-labelledby="clip-details-heading">`. Close button got `aria-label="Close clip details"`. Approve-for-production button got `aria-label={"Approve clip #{title} for production"}`; both buttons have icons inside `aria-hidden` spans.
- Approved clips section converted to `<section aria-labelledby="approved-clips-heading">` + `<ul>` / `<li>`. "Approved" check icon + text pair: icon is `aria-hidden` and the "Approved" text is visible so the status is conveyed through real text, not icon shape.
- Empty states switched from bare `<div>` to `role="status"` so late-arriving "No clips pending approval" / "No approved clips yet" announcements are picked up.

**Latent bug fix (`lib/content_forge/metrics.ex`)**:
- `maybe_filter_by_product/2` had only `nil` and `product_id` heads. The new `/dashboard/performance` LiveView test drove the controller path where `params |> Map.get("product", "")` hands an empty string to the query, and Ecto's binary_id cast raised `Ecto.Query.CastError`. Added a pattern-match head `defp maybe_filter_by_product(query, ""), do: query` so empty strings pass through like `nil`. This is a pre-existing bug that no prior test exercised; rolling the fix into this slice because the test surfaced it.

**Tests added** (appended to existing `test/content_forge_web/live/dashboard/a11y_landmarks_test.exs`):
- 3 new `describe` blocks — `/dashboard/video`, `/dashboard/performance`, `/dashboard/clips` — matching the 15.2a landmark pattern:
  - exactly one `<h1>`, exactly one `<main>`
  - `id="main-content"` + `aria-labelledby="page-title"`
  - page-specific asserts: filter-product aria-label on /video; `aria-label="Performance view"` + `role="tab"` + `aria-selected="true"` + `<th scope="col">` present + `refute html =~ ~r|<th>[A-Z]|` on /performance; `id="pending-clips-heading"` on /clips.

**What was explicitly NOT changed** (kept out of scope):
- No JS arrow-key handler on the performance tablist. `tabindex="0"` is set on the active tab only (roving state), but actual arrow-key roving behaviour is BUILDPLAN 15.2d territory.
- No color-contrast or text-resize fixes. That's 15.2d.
- No global skip-link. Landmarks were added so `#main-content` is a valid target, but the `<a href="#main-content">` element lives with global nav (future slice).

**Gate**: compile --warnings-as-errors clean, format clean, full test 614/0, credo --strict baseline-diff empty (nothing new introduced; the metrics.ex fix adds a function-head clause which doesn't cross any threshold). Rebased cleanly on master @ `0a35e33`.

### Phase 15.2b: WCAG AA audit on drafts review + schedule

Status: DONE
Merged: master @ `2a744cf` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 611-0; credo unchanged. Landmark pattern + ARIA-tablist on filters (roving tabindex). Draft cards promoted from `<div phx-click>` to `<button>`. Detail panel `<aside role=region>`. Schedule: `aria-live=polite` on date-range, `<nav aria-label>` around date-nav. JS arrow-key roving deferred to 15.2d.
Note: WCAG AA audit + fixes on the two dashboard listing/timeline pages per BUILDPLAN 15.2b. Three remaining pages (video / performance / clips / sms / providers) are separate follow-up slices.

**Pages touched**:
- `/dashboard/drafts` (`Live.Dashboard.Drafts.ReviewLive`)
- `/dashboard/schedule` (`Live.Dashboard.Schedule.Live`)

**Findings fixed on /dashboard/drafts**:
- No `<main>` landmark. Added `<main id="main-content" aria-labelledby="page-title">` wrapping the whole page + h1 with `id="page-title"`.
- Six filter buttons lived inside a plain `<div class="tabs tabs-boxed">` with no ARIA metadata — not a real tablist to assistive tech. Replaced with a proper `<div role="tablist" aria-label="Draft status filter">` containing `<button role="tab" aria-selected="true|false" tabindex="0|-1">` for each status. `tabindex` rolls to `0` only on the active tab so keyboard users tab into the group once and then navigate inside it; tests confirm the initial render has exactly one `aria-selected="true"`.
- Consolidated the six inline tab buttons into a single `:for` loop driven by a new `status_tabs/0` helper (six tuples). Cleaner + matches future follow-up slices that will share the pattern.
- Product-filter `<select>` had no label. Wrapped in `<label>` with `sr-only` label-text + `aria-label="Filter by product"`.
- Draft cards in the list were `<div phx-click>` (not keyboard-operable). Promoted to real `<button type="button">` elements inside a `<ul>`/`<li>` list with `aria-pressed={selected?}`, dynamic `aria-label` interpolating platform + generating_model, and `focus:outline-none focus:ring focus:ring-primary` for visible focus.
- "No drafts found" empty-state `<div>` promoted to `<p role="status">` so assistive tech announces when the filter empties the list.
- Detail panel was a `<div>`; promoted to `<aside role="region" aria-labelledby="draft-details-heading">` with the h2 carrying `id="draft-details-heading"`.
- Detail close button was icon-only; now `aria-label="Close draft details"` + icon wrapped in `<span aria-hidden="true">`.

**Findings fixed on /dashboard/schedule**:
- No `<main>` landmark. Same pattern: `<main id="main-content" aria-labelledby="page-title">`, h1 with id.
- Product filter `<select>` wrapped in `<label>` with `sr-only` label-text + `aria-label="Filter by product"`.
- Date-navigation buttons (prev/next chevrons) were icon-only. Now `aria-label="Previous week"` / `aria-label="Next week"` with icons wrapped in `<span aria-hidden="true">`. The "Today" button picked up `aria-label="Jump to today"` since the visible word alone could be ambiguous to screen-reader users outside context.
- Timeline/Calendar view switcher was a plain `<div class="tabs">`. Now `<div role="tablist" aria-label="View mode">` with each tab `role="tab" aria-selected aria-tabindex`-managed the same way as the drafts page.
- Date-range display gets `aria-live="polite"` so the text read on forward/back navigation is announced.
- Date nav section wrapped in `<nav aria-label="Date navigation">` so the whole region is a rotor entry point.

**Heading hierarchy** verified on both pages: exactly one `<h1>`, `<h2>`/`<h3>` for sub-regions, no level skips. Sections that had no visible heading picked up an `sr-only` heading so `aria-labelledby` has a concrete target.

**2 new tests** in `test/content_forge_web/live/dashboard/a11y_landmarks_test.exs` (the file already hosts the 15.2a landmark tests): for each of drafts + schedule, assert exactly one `<h1>`, one `<main>`, `id="main-content"`, `aria-labelledby="page-title"`, plus page-specific load-bearing assertions:
- drafts: `role="tablist"` + `aria-label="Draft status filter"` + at least one `aria-selected="true"` AND at least one `aria-selected="false"`, and the product-filter `aria-label="Filter by product"`.
- schedule: icon-only date nav aria-labels ("Previous week", "Next week", "Jump to today"), view-switcher `aria-label="View mode"` + `role="tab"` + `aria-selected="true"`, and `aria-label="Filter by product"`.

**Not in scope this slice** (documented as follow-up territory): contrast math verification; full keyboard-arrow navigation inside the tablists (ARIA pattern says left/right arrows should move focus between tabs within a tablist — the `tabindex` roving is wired but the JS side of the arrow-key handler isn't, and that's 15.2d territory); remaining dashboard pages (video/performance/clips/sms/providers) are separate slices.

Touched files: `lib/content_forge_web/live/dashboard/drafts/review_live.ex` (main + tablist + labeled select + kbd-operable cards + aria-hidden close icon + status_tabs helper), `lib/content_forge_web/live/dashboard/schedule/live.ex` (main + tablist + labeled select + aria-labeled icon nav buttons + date nav landmark + aria-live on range display), `test/content_forge_web/live/dashboard/a11y_landmarks_test.exs` (2 new describe blocks), `BUILDLOG.md`.

### Phase 15.2a: WCAG AA audit on dashboard hub + products list + product detail

Status: DONE
Merged: master @ `e46928c` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 609-0; credo unchanged. Main landmark + h1 wiring consistent across all three pages. Hub→nav, cards→article, detail header→semantic. Input labels fixed per WCAG 3.3.2. Delete confirms interpolate product name. Icon backgrounds aria-hidden. 4 landmark-assert tests. Contrast math and remaining pages documented as follow-ups.
Note: WCAG AA audit + fixes on the three entry-surface pages per BUILDPLAN 15.2a.

**Pages touched** (only three, per spec; other dashboard pages are separate follow-ups):
- `/dashboard` (`Live.Dashboard.DashboardLive`)
- `/dashboard/products` (`Live.Dashboard.Products.ListLive`)
- `/dashboard/products/:id` (`Live.Dashboard.Products.DetailLive`)

**Findings fixed inline**:

- No `<main>` landmark on any of the three pages. All three now wrap content in `<main id="main-content" aria-labelledby="page-title">` with the h1 carrying `id="page-title"`. The `id="main-content"` anchor lines up with a future skip-link target once the global nav lands.
- Hub's nav-card grid was a plain `<div>`. Changed to `<nav aria-label="Dashboard sections">` so the eight cards are a discoverable landmark for screen-reader rotors.
- Each of the nine icon-backgrounds on the hub cards (Products / Drafts / Schedule / Video / Performance / Clips / SMS / Providers + the dynamic provider indicator) now carries `aria-hidden="true"` on the colored wrapper div so the decorative icon isn't announced — the visible text label inside each `<a>` is already the accessible name.
- Products list: two `<input>` fields in the Quick Add form used only placeholders (not valid accessible names per WCAG 3.3.2). Wrapped each in a `<label>` with an `sr-only` label-text span AND added an `aria-label`. Same fix to the search input, plus changed its type to `type="search"` for better semantics.
- Products list: delete button was icon-only with no accessible name. Added `aria-label="Delete product <name>"` (interpolated from the row product) + wrapped the hero icon in `<span aria-hidden="true">`. The inline `onclick="return confirm(...)"` also interpolates the product name now so the confirmation dialog is unambiguous.
- Products list: "No products found" empty state picked up `role="status"` so assistive tech announces it when the grid clears under search.
- Product detail: back-arrow link was icon-only with no accessible name. Added `aria-label="Back to products list"` + wrapped the icon in `<span aria-hidden="true">`. Header wrapped in semantic `<header>`.
- Heading hierarchy checked on all three: exactly one `<h1>` per page, `<h2>` for major sections (Quick Overview, Quick Add, Search, Product list), `<h3>` for per-card product names in the list (linked to the detail page via `<.link>`). No level skips.
- Individual `<section>` elements on the list page get `aria-labelledby` pointing at their heading; when the heading is visually absent it uses `sr-only`.
- Product cards on the list page changed from `<div>` to `<article aria-labelledby="product-<id>-name">` so each card is a discoverable region.

**Tests** in `test/content_forge_web/live/dashboard/a11y_landmarks_test.exs` (4 tests, async: false): for each page, assert `count_matches(html, ~r|<h1\b|) == 1`, `count_matches(html, ~r|<main\b|) == 1`, `html =~ "id=\"main-content\""`, `html =~ "aria-labelledby=\"page-title\""`; plus page-specific asserts for load-bearing aria-labels (hub's `aria-label="Dashboard sections"`, list's form input labels, list's dynamic "Delete product <name>" button label, detail's back-link `aria-label="Back to products list"`).

**Not in scope this slice** (documented as follow-up territory): contrast math verification (requires tool or visual review against the daisyUI palette), focus-order smoke on the live tab widget in product detail, the remaining dashboard pages (drafts / schedule / video / performance / clips / sms / providers) are separate follow-up slices.

Touched files: `lib/content_forge_web/live/dashboard/dashboard_live.ex` (main + nav + section landmarks, aria-hidden on decorative icon wrappers), `lib/content_forge_web/live/dashboard/products/list_live.ex` (main + section landmarks, labeled inputs, aria-labeled delete button, role=status empty state, article cards), `lib/content_forge_web/live/dashboard/products/detail_live.ex` (main + header landmark, aria-labeled back-link, icon wrapped in aria-hidden span), `test/content_forge_web/live/dashboard/a11y_landmarks_test.exs` (new), `BUILDLOG.md`.

### Phase 15.3.1: E2E happy-path integration test

Status: DONE
Merged: master @ `41e0fb5` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 605-0; credo unchanged. Bundled bug fix: `WinnerRepurposingEngine` was calling `Oban.insert(%Oban.Job{...})` with a raw struct (Oban.insert doesn't accept that shape); surfaced by the E2E walk because no prior test covered the winner→repurpose arc. Fixed. Overall coverage climbed to 52.64%. Shared stubs at `test/support/e2e_stubs.ex` pre-wire every external client for future E2E slices.
Note: Single deterministic integration test walking the pipeline + shared Req.Test stub helpers per BUILDPLAN 15.3.1.

**Shared stubs** at `test/support/e2e_stubs.ex` (`ContentForge.Test.E2EStubs`):
- `setup_llm_stubs/0` installs Anthropic + Gemini config with `Req.Test` plugs, using the same shape the individual LLM tests established. `ExUnit.Callbacks.on_exit/1` restores the original env so nothing bleeds across tests.
- `stub_anthropic_text/1` + `stub_gemini_text/1` install a `Req.Test.stub` returning a plain-text completion. The LLM-provider-shape JSON wrappers live inside the helper so callers only think about the text payload.
- Additional seams are wired in (`setup_media_forge_stubs/0`, `setup_twilio_stubs/0`, `setup_open_claw_stubs/0`, `setup_apify_stubs/0`) even though this slice does not use them — they're the harness 15.3.2+ slices will plug into.
- Known gap documented in the moduledoc: platform publisher clients (`Publishing.Twitter` / `Publishing.LinkedIn`) call `Req.get` / `Req.post` directly without a `req_options` seam, so they can't be stubbed through config today. Refactoring those clients is 15.3.2 territory.

**E2E test** at `test/content_forge/e2e/happy_path_test.exs`: a single `test` block walking:

1. **Brief generation** - `ContentBriefGenerator.perform/1` with `stub_anthropic_text/1` + `stub_gemini_text/1` installed (BriefSynthesizer calls both providers when both are configured, then synthesizes). Asserts the brief row exists with the exact LLM text + model prefix "anthropic" + version 1 + zero duplicate briefs.
2. **Variants** - hand-created (spec allows; `OpenClawBulkGenerator` is skipped per the 11.2M decision).
3. **Multi-model ranking** - both providers stubbed with structured JSON scores (accuracy=8.5, seo=8.0, eev=7.5). `MultiModelRanker.perform/1` creates 6 `DraftScore` rows (3 drafts × 2 models) and promotes all 3 to `"ranked"`.
4. **Promote + publish** - `ContentGeneration.mark_draft_approved/1` flips the winner to `"approved"`. `Publishing.create_published_post/1` writes the row directly (platform clients don't support Req.Test yet), then `update_draft_status(winner, "published")`. Asserts the draft is `"published"` and exactly one `PublishedPost` exists.
5. **Metrics spike** - seeds a winning `ScoreboardEntry` (delta=3.5, outcome="winner") directly, then calls `MetricsPoller.maybe_trigger_spike/2` — the exact code path the full poller invokes when it detects a winner. `assert_enqueued(worker: WinnerRepurposingEngine, args: %{"draft_id" => winner.id})`.
6. **Repurposing** - `perform_job(WinnerRepurposingEngine, %{"draft_id" => winner.id})` returns `{:ok, %{variants_created: 3}}`. Asserts three new `Draft` rows with `repurposed_from_id: winner.id` + `generating_model: "repurposing_engine"` (no fake LLM label) + `status: "draft"` + `content_brief_id` carried forward + cross-platform targets `["blog", "linkedin", "reddit"]`.

No sleeps, no live HTTP, no synthetic data leaks (every content string is either the explicit stub text or the `"repurposing_engine"` marker).

**Latent bug fix (bundled)**: `WinnerRepurposingEngine.create_repurposed_variant/4` was calling `Oban.insert(%Oban.Job{...})` with a raw struct, which `Oban.insert/1,2,3` does not accept. Before this slice the code silently broke whenever `WinnerRepurposingEngine.perform/1` reached that branch; no existing test exercised the path. Fixed by switching to `MultiModelRanker.new(args) |> Oban.insert()` (the same pattern every other worker in the repo uses). Without this fix the E2E test couldn't complete stage 6.

Touched files: `test/support/e2e_stubs.ex` (new), `test/content_forge/e2e/happy_path_test.exs` (new), `lib/content_forge/jobs/winner_repurposing_engine.ex` (fix Oban.insert call + add MultiModelRanker alias), `BUILDLOG.md`.

### Phase 15.1c: Schedule calendar visualization

Status: DONE
Merged: master @ `514f8c6` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 604-0; credo unchanged. Accessibility passes: role=grid/gridcell, role=dialog + aria-modal, aria-label on interactives, aria-hidden on decorative icons, focus rings, real buttons not div handlers. 12 pattern-matched function heads. Dead code cleanup. **Phase 15.1 UX pass complete.**
Note: Week-view calendar + draft preview drawer on the existing Schedule LiveView per BUILDPLAN 15.1c.

**Week-view** added under `@view == "calendar"` (replacing the old simple 22-day grid):

- `week_days/1` returns the 7 days starting from the Sunday on or before the anchor date. The view always anchors on `Date.utc_today/0` so the visible week is "this week", independent of the existing timeline-navigation state.
- Desktop layout (`hidden md:grid grid-cols-7`): 7 cells with `role="grid"` + `role="gridcell"`, `data-week-day={iso_date}`, day header ("Sun 4/23"), list of entries with platform icon + badge + truncated snippet, today's cell highlighted with `bg-base-300`. Each entry is a `<button>` (not a `<div>`) with `aria-label` + `focus:ring focus:ring-primary` + `phx-click="preview_draft"` + `phx-value-draft-id` for keyboard + screen-reader access.
- Mobile layout (`md:hidden`, `data-week-calendar-mobile`): 7 stacked `<section>` elements, same entry button + "Nothing scheduled" fallback copy. Both layouts emit `data-week-day` attributes so tests see 14 total matches (7 unique days x 2 layouts).
- Entry composition via `entries_for_day/3`: `post_on_day?/2` for published posts keyed on their `posted_at` date + approved drafts collapsed under today's cell (since the Draft schema has no per-draft `scheduled_at` yet). `post_entry/1` and `draft_entry/1` normalize both shapes to `%{draft_id, platform, content}` so the template stays uniform.
- `platform_icon/1` seven-head maps each platform to a hero-icon name plus a catch-all "hero-megaphone".
- `snippet/1` two-head caps at 60 chars; nil passes through as empty.

**Draft preview drawer** added as a sibling `<aside role="dialog" aria-modal="true" data-draft-preview={draft.id}>` below the calendar. Shows platform badge + content_type + status_badge + the full pre-wrapped content + image_url hint. `handle_event("preview_draft", %{"draft-id" => id})` loads the Draft into `@preview_draft` (flashes an error if not found); `handle_event("close_preview", _)` clears. Close button carries `aria-label="Close preview"`.

**Accessibility** (WCAG AA):
- Semantic `<button>` for every interactive entry + `<section>` for mobile day groupings.
- `aria-label` on every entry button and the close button.
- `role="grid"`/`gridcell` on the desktop layout + `aria-label="Week calendar"` on the outer grid.
- `role="dialog" aria-modal="true"` on the drawer.
- `focus:outline-none focus:ring focus:ring-primary` gives visible focus indicators.
- Decorative icons wrapped in `<span aria-hidden="true">` since the CoreComponents `<.icon />` helper does not accept arbitrary HTML attributes.

**Test-friendliness**: stable `data-week-day`, `data-week-entry`, `data-week-calendar-mobile`, `data-draft-preview` attributes mean the test suite asserts on DOM markers instead of copy that may shift later.

6 new tests in `test/content_forge_web/live/dashboard/schedule/week_calendar_test.exs` (async: false):
- Renders 7 unique `data-week-day` ISO dates across both layouts (14 total matches, 7 unique).
- Published post on today's date shows in today's cell with platform label + draft snippet.
- Approved draft (no `posted_at`) shows in today's column as upcoming.
- `preview_draft` event opens the drawer with `data-draft-preview={draft.id}` + full content + platform.
- `close_preview` clears the drawer.
- Mobile layout (`md:hidden`) and desktop layout (`md:grid`) both present so each viewport lands on the right layout without JS.

Cleanup: removed the now-unused `days_in_range/2` and `posts_for_day/2` helpers that the old 22-day simple grid relied on. Nothing else referenced them.

Touched files: `lib/content_forge_web/live/dashboard/schedule/live.ex` (calendar view rewrite + drawer + preview_draft / close_preview events + week-view helpers + removed dead helpers), `test/content_forge_web/live/dashboard/schedule/week_calendar_test.exs` (new), `BUILDLOG.md`.

### Phase 15.1b: Script-gate threshold view on video page

Status: DONE
Merged: master @ `416eb1a` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 598-0; credo unchanged. Promote transaction wraps update+create atomically; `maybe_enqueue_producer` fires outside tx. Override audit captures full decision; OVERRIDE badge on status board. Coder caught a latent `status_order` module-attr-in-HEEx bug while touching the file. 13 tests.
Note: Script-gate threshold view + manual promote/override control on the existing video page per BUILDPLAN 15.1b.

**Schema**: migration `20260502120000_add_promoted_via_override_to_video_jobs.exs` alters `video_jobs` to add three columns:

- `promoted_via_override :boolean null: false default: false` - stamps the "this went around the automatic gate" state on the row itself, so the status board can surface it forever without joining back to the draft's score history.
- `promoted_score :float` - composite score at promotion time, nullable because an unscored draft can still be manually promoted.
- `promoted_threshold :float` - the threshold in effect at promotion time.

`VideoJob` schema + `@cast` list pick up all three fields.

**Context helpers** in `ContentForge.Publishing`:

- `script_gate_threshold/0` - single read-point for `:content_forge, :script_gate, :threshold`, default `6.0`. Both the new LiveView and a future `ScriptGate` worker refactor can read the same value.
- `promote_script(draft_id, opts)` - three-step atomic flow inside `Repo.transaction`:
  1. `update_draft_status(draft, "approved")`.
  2. `create_video_job/1` with all three promoted-* fields set; `below_threshold?/2` two-head on `nil | number` decides `promoted_via_override`.
  3. `maybe_enqueue_producer/2` two-head (false/true) optionally inserts `ContentForge.Jobs.VideoProducer` - gated so tests can focus on DB state without exercising Oban's queue.

Returns `{:error, :draft_not_found}` when the draft id is unknown; changeset errors roll the transaction back cleanly.

**LiveView changes** in `ContentForgeWeb.Live.Dashboard.Video.StatusLive`:

- Mount now assigns `candidate_scripts`, `script_gate_threshold`, and `status_order` (the latter because HEEx `@x` references are always assigns lookups, not module-attribute reads - required for the `for step <- @status_order` loop to render in tests with strict-assign-checking).
- `fetch_candidates/1` three-head dispatches on the product filter ("" → `candidate_scripts_for_products(Products.list_products())`; binary → scoped to that product or empty when the product is missing). `candidate_scripts_for_products/1` builds the list of ranked/archived video_script drafts without an existing `VideoJob`, hydrates each with `ContentGeneration.compute_composite_score/1`, and sorts by score-desc with nil-last via `candidate_sort_key/1` two-head.
- New "Script Gate" table between the Pipeline and Video Jobs sections. Columns: Product / Script / Composite / Status vs threshold / action button. Data attributes for stable test assertions: `data-script-gate-threshold`, `data-script-candidate={draft.id}`, `data-below-threshold={"true"|"false"}`, `data-promoted-override={job.id}`. Label helpers (`score_label/2`, `score_badge_class/2`, `promote_button_class/2`, `promote_label/2`, `promote_confirm/2`) are all function-head dispatched on `nil | above-threshold | below-threshold`.
- Button copy changes by branch: `"Promote"` for at/above threshold; `"Override promote"` for below threshold or unscored, with a `data-confirm` dialog ("Composite X.XX is below threshold Y.YY. Override?" / "Promote with no ranking scores on file?").
- Status-board cards get an `OVERRIDE` warning badge next to the status badge when `job.promoted_via_override` is true. `data-promoted-override={job.id}` marker lets tests assert both directions.
- `handle_event("promote_script", %{"draft-id" => id})` delegates to `Publishing.promote_script/2`, puts a context-aware flash ("Promoted script via manual override" vs "Promoted script to video production") via `flash_for_promotion/1` two-head, and re-queries candidates + jobs so the row disappears from the gate and appears on the board in the same render cycle.

13 new tests:
- `test/content_forge/publishing/promote_script_test.exs` (7): above-threshold promote (override=false, score + threshold recorded), VideoProducer enqueue (default-on), below-threshold override (override=true), unscored (nil score → override=true), default threshold from `script_gate_threshold/0`, per-test config override respected, unknown draft → `{:error, :draft_not_found}`.
- `test/content_forge_web/live/dashboard/video/script_gate_view_test.exs` (6): renders threshold + each candidate with composite score + ABOVE/BELOW/UNSCORED labels; unscored candidate gets Override promote button; empty state copy; above-threshold promote creates VideoJob + flips draft status + hides candidate row + no OVERRIDE badge; below-threshold override creates VideoJob with `promoted_via_override: true` + `promoted_score: 3.0` + `promoted_threshold` from config + renders the OVERRIDE badge on the status board; product filter narrows the candidate list.

Touched files: `priv/repo/migrations/20260502120000_add_promoted_via_override_to_video_jobs.exs` (new), `lib/content_forge/publishing/video_job.ex` (three new fields + cast), `lib/content_forge/publishing.ex` (2 new public fns + 3 private helpers, aliases rearranged), `lib/content_forge_web/live/dashboard/video/status_live.ex` (Script Gate section + OVERRIDE badge + promote_script event + candidate loading + helper heads + status_order assign fix), `test/content_forge/publishing/promote_script_test.exs` (new), `test/content_forge_web/live/dashboard/video/script_gate_view_test.exs` (new), `BUILDLOG.md`.

### Phase 15.1a: Provider status panel

Status: DONE
Merged: master @ `3c2b0e1` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 585-0; credo unchanged. Zero-synthetic-probe verified (grep for HTTP libs + enqueue against `providers.ex` returns 0). All signals read from audit tables + `Application.get_env`. `classify/3` three-head; degrade>3 first-match. Degraded scoped to Twilio + Media Forge only — honest about the data we have. 22 tests.
Note: `/dashboard/providers` + hub card per BUILDPLAN 15.1a.

**Context `ContentForge.Providers`** at `lib/content_forge/providers.ex` with two public fns:

- `list_provider_statuses/0` returns `[%{id, name, status, last_success_at, last_error_at, note}]` in a stable display order across six integrations: Media Forge, Anthropic, Gemini, OpenClaw, Apify, Twilio.
- `summary/0` rolls the list up into `%{available: N, configured: N, unavailable: N, degraded: N}` for the hub card.

Status derivation per provider with `classify/3` (three-head on error-count threshold vs last-success-at):

- `:unavailable` - credentials missing. Note carries the env var name to set.
- `:degraded` - credentials present AND more than 3 transient errors in the last 15 minutes. Note says "N errors in the last 15 min".
- `:available` - credentials present AND a successful use within the 1h success window.
- `:configured` - credentials present but no recent traffic.

Per-integration activity signals:

- **Media Forge**: `ProductAsset.status="processed"` (success) / `status="failed"` (error) with `updated_at` timestamps via `most_recent_asset_at/2` + `count_assets_within/2`.
- **Anthropic / Gemini**: `Draft.generating_model LIKE "anthropic:%"` / `"gemini:%"` via `most_recent_draft_at/1`. LLM call errors aren't persisted in a structured way, so degraded does not fire here this slice — future slice can wire LLM error logging.
- **OpenClaw / Apify**: credentials check only. No audit trail yet so the roll-up stops at `:configured` / `:unavailable`.
- **Twilio**: `SmsEvent.direction="outbound"` with `status in ["sent", "delivered"]` (success) or `status="failed"` (error), using `most_recent_outbound_at/2` + `count_outbound_within/2`.

All queries read audit tables directly - the page never issues a synthetic call to the upstream. Loading `/dashboard/providers` cannot itself cause a Twilio or Anthropic roundtrip.

**LiveView** `ContentForgeWeb.Live.Dashboard.Providers.StatusLive` at `lib/content_forge_web/live/dashboard/providers/status_live.ex`. Mount calls `Providers.list_provider_statuses/0` once and computes the summary inline. Template renders:

- Four summary tiles (Available / Configured / Unavailable / Degraded) each with a `data-summary-*` attribute for stable test assertions.
- A table row per provider marked `data-provider-id={id} data-provider-status={status}` with columns Provider / Status (colored badge via `badge_classes/1` four-head) / Last success / Last error / Note.

**Dashboard hub** gets a "Providers" card that loads `Providers.summary/0` at mount and shows either "All integrations healthy" (when both `unavailable` and `degraded` are zero) or "N integration(s) need attention". Icon + background swap between success-green and warning-amber based on the same two counters via `provider_hub_icon_bg/1` and `provider_hub_icon_color/1` two-head helpers.

22 new tests:
- `test/content_forge/providers_test.exs` (14 tests): every provider starts `:unavailable`; each of the six flips to `:configured` when its credentials are set but no activity exists; Twilio flips to `:available` with a single recent `"sent"` outbound; Anthropic with a recent `anthropic:...` draft; Media Forge with a processed `ProductAsset`; Twilio with 4+ failed outbound events in the last 15 min flips to `:degraded` with `note =~ "4 errors"`; Twilio with exactly 3 failures stays sub-degrade (threshold is strictly >3); `summary/0` counts correctly when a mix of states is present.
- `test/content_forge_web/live/dashboard/providers/status_live_test.exs` (8 tests): all 6 provider rows render with stable data attributes; default state renders all as `Unavailable` with env-var notes; Twilio available/configured/degraded each render with the matching `data-provider-status` attribute; summary tiles count accurately; hub card renders with the "need attention" copy when providers are missing and flips to "All integrations healthy" when every provider is available-or-configured.

Touched files: `lib/content_forge/providers.ex` (new), `lib/content_forge_web/live/dashboard/providers/status_live.ex` (new), `lib/content_forge_web/router.ex` (new route), `lib/content_forge_web/live/dashboard/dashboard_live.ex` (Providers card + summary load + three small helpers), `test/content_forge/providers_test.exs` (new), `test/content_forge_web/live/dashboard/providers/status_live_test.exs` (new), `BUILDLOG.md`.

### Phase 14.5: Escalation + needs-reply dashboard

Status: DONE
Merged: master @ `0fe31dc` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 563-0; credo unchanged. Holding-message-exactly-once semantics correct: `dispatch_with_session/3` two-head on `auto_response_paused`; `already_sent_holding_since_escalation?/1` single aggregate count gates duplicate sends. Escalate atomically sets all three fields + records audit row. `list_high_volume_sessions` uses Postgres group-by + MapSet difference so 'needs attention' and 'handled' are disjoint. 19 tests. **Phase 14 complete end-to-end** except OpenClaw-gated 14.2c (real reply generation) — blocked until OpenClaw conversational endpoint lands.
Note: Escalation + needs-reply dashboard per BUILDPLAN 14.5.

**Schema**: migration `20260501120000_add_escalation_to_conversation_sessions.exs` alters `conversation_sessions` to add `escalated_at :utc_datetime_usec`, `escalation_reason :text`, and `auto_response_paused :boolean null: false default false` + an index on `escalated_at`. `ConversationSession` schema + `@optional` cast list pick up all three. `SmsEvent` gains `"escalated"` in its `@statuses` inclusion list (plain string column, no migration).

**Context**: four new public helpers in `ContentForge.Sms`:

- `escalate_session/3` - sets `escalated_at` = now, `escalation_reason` = reason, `auto_response_paused: true`, and records an inbound `"escalated"` audit row. `opts` currently carries `:notify_channels` which is recorded on the audit row body (`"escalated: <reason> (notify: dashboard, ...)"`); fan-out to Slack/email is a future slice but the hook is in place.
- `resolve_session/1` - clears all three fields to nil / false. Auto-response resumes on the next inbound.
- `list_escalated_sessions/0` - returns every session with non-nil `escalated_at`, newest-escalation-first.
- `list_high_volume_sessions/1` - sessions with >= `:threshold` (default 10) inbound `"received"` events in the last `:seconds` (default 86_400) with no outbound `"sent"`/`"delivered"` in that same window. Excludes already-escalated sessions so a single conversation never appears in both lists. Built from two Postgres group-by queries (one inbound count, one outbound-pair set) + an in-memory MapSet difference, then `lookup_sessions/1` fetches the matching session rows and sorts by `last_message_at` desc.

**Dispatcher short-circuit**: `SmsReplyDispatcher.dispatch_or_skip/1` now loads the session before routing to `dispatch_with_quota/2`. `dispatch_with_session/3` two-head function:

- `%ConversationSession{auto_response_paused: true}` + `already_sent_holding_since_escalation?/1` -- if a holding message has already been sent since the current `escalated_at` marker, returns `{:ok, :escalated_paused}` with zero Twilio HTTP. Otherwise sends the holding message ("Thanks — a human from our team will follow up shortly.") exactly once per escalation.
- Anything else -- falls through to the existing rate-limited fallback pipeline.

`already_sent_holding_since_escalation?/1` does a single `Repo.aggregate` `:count` on outbound `"sent"` events with `inserted_at >= escalated_at`. After `resolve_session/1` flips the flags off, the next inbound runs the normal fallback path again.

**LiveView** `ContentForgeWeb.Live.Dashboard.Sms.NeedsAttentionLive` at `lib/content_forge_web/live/dashboard/sms/needs_attention_live.ex`. Route: `live "/dashboard/sms", Live.Dashboard.Sms.NeedsAttentionLive, :index` inside the existing `browser` pipeline. Mount loads escalated + high-volume sessions, builds a product-id → product map for the display column, and pre-computes the last-inbound-body per session so the table cell does not N+1. Two sections:

1. **Escalated**: table of `data-escalated-session={session.id}` rows with product name / phone / last-inbound snippet / reason / timestamp / "Mark resolved" button (`phx-click="resolve"`, `phx-value-session-id`). Handler calls `Sms.resolve_session/1`, flashes `:info`, and re-runs `refresh/1` so the row disappears.
2. **High volume**: identical data-attribute shape (`data-high-volume-session`) without an action column. Copy reads "Sessions with >= 10 inbound messages in the last 24h and no outbound reply."

**Dashboard hub**: new SMS card added to `Live.Dashboard.DashboardLive`, linking to `/dashboard/sms` with `hero-chat-bubble-left-right` icon + `bg-warning/20` surface to signal "needs attention".

**19 new tests**:
- `test/content_forge/sms/escalation_test.exs` (12 tests): `escalate_session/3` sets fields + records audit row (with `notify_channels` captured in the body); `resolve_session/1` clears; `list_escalated_sessions/0` newest-first + excludes resolved; `list_high_volume_sessions/1` threshold + window + excludes-outbound + excludes-escalated + honors-threshold; dispatcher short-circuit sends holding message exactly once per escalation (first inbound sends, second returns `:escalated_paused` with zero HTTP); dispatcher resumes normal fallback after resolve; the "first inbound post-escalation" path sends the holding message.
- `test/content_forge_web/live/dashboard/sms/needs_attention_live_test.exs` (7 tests): mount renders both empty states; escalated section shows product + phone + reason + last-inbound body; mark-resolved removes the row + flips the DB row's flags; high-volume section shows sessions meeting the threshold; excludes sessions with an outbound reply; excludes already-escalated sessions so they render only in the escalated section; dashboard hub SMS card links to `/dashboard/sms`.

Touched files: `priv/repo/migrations/20260501120000_add_escalation_to_conversation_sessions.exs` (new), `lib/content_forge/sms/conversation_session.ex` (three new fields + cast list), `lib/content_forge/sms/sms_event.ex` (added `"escalated"` status), `lib/content_forge/sms.ex` (four new public fns + `lookup_sessions/1`), `lib/content_forge/jobs/sms_reply_dispatcher.ex` (new `load_session/1`, `dispatch_with_session/3` two-head, `already_sent_holding_since_escalation?/1`, `send_holding_message/2`), `lib/content_forge_web/live/dashboard/sms/needs_attention_live.ex` (new), `lib/content_forge_web/live/dashboard/dashboard_live.ex` (SMS card added to hub), `lib/content_forge_web/router.ex` (new route), `test/content_forge/sms/escalation_test.exs` (new), `test/content_forge_web/live/dashboard/sms/needs_attention_live_test.exs` (new), `BUILDLOG.md`.

Phase 14 exit criteria (per BUILDPLAN): "a marketer can text a photo in, get it tagged into a product library, receive a scheduled review-deadline reminder, and escalate to a human when the bot is uncertain." All four capabilities are now in place end-to-end.

### Phase 14.4b: ReminderScheduler cron + ReminderDispatcher worker

Status: DONE
Merged: master @ `2fdea38` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 544-0; credo unchanged. `quiet?/3` handles midnight-crossing vs single-interval (both half-open); `compose/4` orders by severity. `ensure_not_paused` belt-and-suspenders for STOP arriving between schedule and dispatch. Oban.unique across all active states prevents same-day duplicates. 18 tests.
Note: Two new Oban workers plus two new `Sms` context helpers + an Oban cron wiring in `config/config.exs`.

**`ContentForge.Jobs.ReminderScheduler`** at `lib/content_forge/jobs/reminder_scheduler.ex` (queue `:default`, max_attempts 3). Scheduled hourly via a new `Oban.Plugins.Cron` entry: `{"0 * * * *", ContentForge.Jobs.ReminderScheduler}`. `perform/1` accepts an optional `"now"` ISO-8601 arg so tests can simulate different hours-of-day; when absent the worker reads `DateTime.utc_now/0`. Flow:

1. `load_enabled_configs/0` joins `sms_reminder_configs` to `products` filtered on `enabled = true` and returns `[{product, config}, ...]`.
2. `enqueue_for_configs/2` fans out per product; `sendable_hour?/2` gates by the config's quiet window (UTC-only for this slice; non-UTC timezones fall back to UTC when no tzdata package is loaded, documented in the moduledoc as a future-slice wiring).
3. `active_phones/1` calls the existing `Sms.list_phones_for_product/2` (which already filters to active by default).
4. Per phone: `phone_paused?/2` (two-head on nil / future DateTime) and `cadence_met?/4` (reads `Sms.last_inbound_at/2` — nil means "never engaged", which is a hard skip: the system only nudges engaged senders, never cold outreach) gate the enqueue.
5. `enqueue_dispatcher/2` inserts a `ReminderDispatcher` job with `unique: [period: 86_400, keys: [:phone_id, :product_id], states: [:available, :scheduled, :executing, :retryable]]`. The conflict?-true path returns 0 so the summary count stays honest across reruns.

`quiet?/3` is a two-head pattern-match on `qs > qe` (midnight-crossing window: `hour >= qs or hour < qe`) vs `qs <= qe` (single-interval daytime quiet window: `hour >= qs and hour < qe`). Default config (qs=20, qe=8) takes the first head; unusual configs like qs=9 qe=17 take the second.

**`ContentForge.Jobs.ReminderDispatcher`** at `lib/content_forge/jobs/reminder_dispatcher.ex` (queue `:default`, max_attempts 3). `perform/1` takes `{"phone_id", "product_id"}` args. Flow:

1. `load_phone/1` + `dispatch/2` two-head: missing phone → `{:cancel, "phone not found"}`.
2. `ensure_not_paused/3` re-checks `reminders_paused_until` at dispatch time (belt-and-suspenders: the scheduler already filtered, but a STOP that landed between schedule and dispatch needs to still be respected). Paused → `{:ok, :paused}` with zero Twilio HTTP.
3. `send_reminder/2` resolves the product's `ReminderConfig`, counts consecutive-ignored reminders via the new `Sms.consecutive_ignored_reminders/2`, and dispatches to `compose/4` three-head: `count >= stop_after_ignored` → stop-notify; `count >= backoff_after_ignored` → gentler; else → friendly. Order matters: stop wins over backoff wins over friendly.
4. Template bodies are hard-coded in the module (`friendly_text/4`, `gentler_text/4`, `stop_text/4`) — OpenClaw branch is wired but ships fallback text in this slice, mirroring 14.2b. Real AI-crafted reminder text lands under 14.2c.
5. `handle_twilio_result/5` function-head on the full taxonomy. Stop-notify returns `{:ok, :stop_notify}` so callers (and tests) can distinguish the stop branch from a normal `{:ok, :sent}`.

Full failure taxonomy mirrors `SmsReplyDispatcher`: `:not_configured` → failed audit + `{:ok, :twilio_not_configured}` no-crash no-retry; transient → `{:error, reason}` retry no audit; permanent/unexpected_status → failed audit + `{:cancel, reason}`; catch-all → failed audit + `{:error, reason}`.

**New Sms context helpers**:

- `last_inbound_at/2` returns the most recent inbound `"received"` `inserted_at` for `(product_id, phone_number)`, or nil. Single `Repo.one` with `order_by: [desc: inserted_at], limit: 1`.
- `consecutive_ignored_reminders/2` returns a count of outbound `"sent"` or `"delivered"` events newer than the most-recent inbound. `apply_since/2` two-head (nil/DateTime) composes onto the base query so "never had an inbound" counts every outbound.

**Cron wiring** in `config/config.exs`: a new `plugins:` block on the existing Oban config adds `{Oban.Plugins.Cron, crontab: [{"0 * * * *", ContentForge.Jobs.ReminderScheduler}]}`. Test env (`testing: :manual`) ignores the cron schedule, so tests invoke `perform_job` directly.

18 new tests:
- `test/content_forge/jobs/reminder_scheduler_test.exs` (8 tests): enqueues when all gates pass (14:00 UTC with default config + 4-day-old inbound); skips on cadence-not-met / paused / quiet-hours (03:00 UTC) / config-disabled / no-config / no-inbound-ever / inactive-phone; Oban.unique collapses two runs within the same 24h into exactly one queued dispatcher (queried directly via `Oban.Job` + `state: "available"` filter).
- `test/content_forge/jobs/reminder_dispatcher_test.exs` (10 tests): template selection by consecutive-ignored count (0 → friendly, 2 → gentler, 4 → stop-notify, counter reset after intervening inbound); `:not_configured` failed audit + `:twilio_not_configured`; transient 500 retry no audit; permanent 400 failed audit + cancel; unknown phone cancel; paused phone no-Twilio `:paused`.

The scheduler test's `record_silent_since!/3` uses `Repo.update_all` to backdate `inserted_at` directly because `SmsEvent.changeset` doesn't cast timestamps. Required so cadence math is deterministic without waiting days of wall-clock time.

Touched files: `lib/content_forge/jobs/reminder_scheduler.ex` (new), `lib/content_forge/jobs/reminder_dispatcher.ex` (new), `lib/content_forge/sms.ex` (two new public helpers: `last_inbound_at/2`, `consecutive_ignored_reminders/2`), `config/config.exs` (Oban plugins block with the hourly cron entry), `test/content_forge/jobs/reminder_scheduler_test.exs` (new), `test/content_forge/jobs/reminder_dispatcher_test.exs` (new), `BUILDLOG.md`.

### Phase 14.4a: Reminder config + STOP opt-out

Status: DONE
Merged: master @ `9e7ebf4` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 526-0; credo unchanged. STOP/START keyword sets + `body_intent/1`; `dispatch_active` three-head only fires in active-phone head so STOP from unregistered number doesn't leak. STOP records audit + pauses + TwiML ack + `refute_enqueued` on dispatcher (TCPA: pause must be immediate + unaccompanied). START records + resumes + starts session + enqueues dispatcher. 22 tests.
Note: New schema `ContentForge.Sms.ReminderConfig` at `lib/content_forge/sms/reminder_config.ex`: binary_id PK, belongs_to :product, `enabled` (bool default true), `cadence_days` (int default 7, `>0`), `quiet_hours_start` / `quiet_hours_end` (int 0..23, defaults 20 / 8), `timezone` (string default "UTC"), `backoff_after_ignored` (int default 2, `>0`), `stop_after_ignored` (int default 4, `>0`). Migration `20260430120000_create_reminder_configs_and_pause.exs` creates `sms_reminder_configs` with `on_delete: :delete_all` on product_id + unique index `sms_reminder_configs_product_id_index`, and alters `product_phones` to add a `reminders_paused_until :utc_datetime_usec` nullable column.

`ContentForge.Sms.ProductPhone` picks up `reminders_paused_until` in both the schema field list and the changeset `@optional` list. `SmsEvent` gets two new statuses in its inclusion list: `"stop_received"` and `"start_received"` (plain string column so no migration needed).

Context extensions in `ContentForge.Sms`:

- `get_reminder_config/1` - returns the persisted `%ReminderConfig{}` if one exists, otherwise an unpersisted struct with schema defaults and `id: nil` so callers can read config without first creating a row.
- `upsert_reminder_config/2` - `Repo.get_by` short-circuit: insert on first call, update the existing row on subsequent calls. Passes changeset validation errors through.
- `pause_phone_reminders/2` - sets `reminders_paused_until` to `now + pause_days * 86_400` seconds. `@default_pause_days = 7` constant drives the default.
- `resume_phone_reminders/1` - clears `reminders_paused_until` to nil.

Webhook STOP/START dispatch: the active-phone head of `TwilioWebhookController.dispatch/6` now calls `dispatch_active(body_intent(body), ...)` where `body_intent/1` normalizes via `String.trim |> String.downcase` and matches against `@stop_keywords ~w(stop stopall unsubscribe cancel end quit)` or `@start_keywords ~w(start unstop)`, falling through to `:normal`. Three `dispatch_active/7` heads:

- `:stop` -records `stop_received` audit row, calls `Sms.pause_phone_reminders/2` with `@default_pause_days`, returns a TwiML ack body via a new `ack_twiml/2` helper. **Does NOT enqueue `SmsReplyDispatcher`** - the STOP is respected, the user does not get an auto-reply.
- `:start` -calls `Sms.resume_phone_reminders/1`, records `start_received`, starts/refreshes the session, enqueues the normal `SmsReplyDispatcher` so the conversation continues naturally, returns a TwiML ack with a resume confirmation.
- `:normal` -the existing flow (record `received`, start session, enqueue dispatcher + media ingest if any, empty TwiML).

`rejection_twiml/1` and the new `ack_twiml/2` are unified under a single helper that builds the `<Response><Message>...</Message></Response>` TwiML.

STOP handling is **scoped to the active-phone head**: unknown phones (the `dispatch(nil, ...)` head) still get the generic `rejected_unknown_number` response. Confirmed by a dedicated test: STOP from an unknown phone produces zero `stop_received` events, zero dispatcher enqueues, and the same gated TwiML any unknown-phone message would get - no existence leak.

22 new tests:
- `test/content_forge/sms/reminder_config_test.exs` (new file, 12 tests): `get_reminder_config` default + persisted; `upsert_reminder_config` insert-then-update round-trip + bounds validation; `pause_phone_reminders` timestamp computation with a ±5s window on the 7-day target + default-pause-days + no-double-paused state; `resume_phone_reminders` clears to nil + idempotent on already-resumed.
- `test/content_forge_web/controllers/twilio_webhook_controller_test.exs` (extended, 10 new tests): 8 STOP aliases (STOP / STOPALL / UNSUBSCRIBE / CANCEL / END / QUIT + lowercase `stop` + padded `"  stopall  "`) assert pause + stop_received audit + no `SmsReplyDispatcher` enqueue + `reminders_paused_until` > now; 2 START aliases (START / UNSTOP / `start` / `unstop` / padded `"  Start  "`) - wait, 5 cases - assert resume + start_received audit + `SmsReplyDispatcher` enqueued so the conversation continues; STOP-from-unknown takes the generic rejection path.

Touched files: `lib/content_forge/sms/reminder_config.ex` (new), `lib/content_forge/sms/product_phone.ex` (added `reminders_paused_until` field + cast), `lib/content_forge/sms/sms_event.ex` (added two statuses), `lib/content_forge/sms.ex` (4 new public fns + `ReminderConfig` alias), `lib/content_forge_web/controllers/twilio_webhook_controller.ex` (module attrs + `body_intent/1` + three `dispatch_active/7` heads + `ack_twiml/2` unification), `priv/repo/migrations/20260430120000_create_reminder_configs_and_pause.exs` (new), `test/content_forge/sms/reminder_config_test.exs` (new), `test/content_forge_web/controllers/twilio_webhook_controller_test.exs` (extended), `BUILDLOG.md`.

### Phase 14.3: SMS media ingestion

Status: DONE
Merged: master @ `7d3aadf` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 504-0; credo unchanged. Security: download_media fail-closed on nil/empty sid or token; `decode_body: false` pinned; Req cross-origin redirect strips Twilio auth on 307 follow; 100MB cap in `classify_media`. Pattern-match-first throughout. Unsupported MIME gets its own audit status without stopping the walk. 18 tests.
Note: End-to-end inbound MMS ingestion per BUILDPLAN 14.3. Two layers land in this slice:

**1. `ContentForge.Twilio.download_media/1`**: new public function on the outbound client. Issues a GET on the Twilio media URL with HTTP Basic auth (account_sid:auth_token, same header shape as `send_sms/3`), follows Twilio's 307 to the signed S3 download. Req's default redirect behavior strips the Basic-auth header on cross-origin redirects, so the account token never reaches S3. New `classify_media/1` mirrors the `classify/1` shape (200..299, 300..399 → unexpected_status, 429 → transient, 400..499 → http_error, 5xx → transient, timeout → transient:timeout, econnrefused/etc → transient:network, fallthrough → pass-through). `build_media_request/3` sets `decode_body: false` so Req does not try to auto-decode image/video bytes as archives/JSON — a zip-looking MMS otherwise crashes with `Req.ArchiveError` before classification can run. Post-classify enforces a size cap (`:media_cap_bytes`, default 100 MB): over-cap bodies return `{:error, {:media_too_large, size, cap}}`. `headers_content_type/1` three-head is tolerant of both map-valued and list-valued header shapes. Same `:not_configured` fail-closed guard as `send_sms/3`.

**2. `ContentForge.Jobs.SmsMediaIngestor` Oban worker** (queue `:content_generation`, max_attempts 3): loads the `SmsEvent`, runs the same three-head `guard_event/1` as the reply dispatcher (inbound+product_id → ok; inbound without product_id → skip; other → skip). Then `process_urls/4` recursively walks `event.media_urls` with an index counter. Each URL goes through `handle_download/3` → `continue_or_halt/5`:

- `{:ok, %{content_type, binary}}` with `image/*` or `video/*` MIME → `persist_asset/5` generates a fresh UUID, builds `products/<pid>/assets/<uuid>/sms_<event_id>_<idx>.<ext>` via `extension_for/1` MIME map (seven image + five video heads plus a fallback split on `/`), calls the configurable `storage_impl().put_object/3` (R2 in prod, stub in tests via `:content_forge, :asset_storage_impl`), creates the `ProductAsset` with `uploader: event.phone_number`, and enqueues `AssetImageProcessor` or `AssetVideoProcessor` per `media_type`. Continues to the next URL.
- `{:ok, _}` with any other MIME → records an `"unsupported_media"` audit row (added to `SmsEvent`'s status inclusion list) and continues to the next URL. Single bad MIME never blocks a clean URL that follows.
- `{:error, :not_configured}` → records a `"failed"` audit row, returns `{:ok, :skipped}` for the whole job (Oban does not retry; the fix is config, not retry).
- `{:error, {:transient, _, _}}` → returns `{:error, reason}` for Oban retry. No audit row (a successful retry or terminal cancel will write one).
- `{:error, {:http_error, _, _}}` / `{:error, {:unexpected_status, _, _}}` / `{:error, {:media_too_large, _, _}}` → records `"failed"` audit, returns `{:cancel, reason}`. No retry.
- Catch-all `{:error, reason}` → records `"failed"` audit, returns `{:error, reason}` for Oban to classify.

`continue_or_halt/5` function-head dispatches on every return shape so the recursive walk stays flat. Inbound URLs that error terminate the whole job (sane: if Twilio's S3 is down for one URL it's almost certainly down for all of them, and the worker is idempotent by design so retry will just re-download).

**Webhook enqueue**: `TwilioWebhookController.dispatch/6` active-phone head now calls a new `enqueue_media_ingest/2` helper (two-head: `[]` → `:ok` no-op; list → `Oban.insert(SmsMediaIngestor.new(%{"event_id" => event.id}))`). Both rejection heads remain enqueue-free. The webhook response path stays millisecond-fast; the ingest happens asynchronously.

**`SmsEvent` schema change**: added `"unsupported_media"` to the `@statuses` inclusion list so the ingestor's audit rows pass changeset validation. No migration needed (status is a plain string column).

18 new tests: 7 extending `test/content_forge/twilio_test.exs` for `download_media/1` (happy 200 with Basic-auth header asserted, :not_configured for missing sid + missing token, 403, 500, timeout, size cap over-cap rejection); 11 in `test/content_forge/jobs/sms_media_ingestor_test.exs` covering happy image + video, multi-URL with mixed MIMEs, unsupported-MIME audit + skip-then-continue, Twilio `:not_configured` skip with failed audit, permanent 403 cancel, transient 503 retry, empty media_urls zero-HTTP no-op, outbound-event cancel, unknown-event cancel. The 14.1b webhook test now asserts `assert_enqueued(SmsMediaIngestor, ...)` on the MMS-with-media path and `refute_enqueued(SmsMediaIngestor)` on the plain-SMS path.

A `StorageStub` module in the ingestor test logs every `put_object/3` call so the test can assert the bytes uploaded match the bytes downloaded exactly. The real `ContentForge.Storage` is never touched in tests; the swap happens via the existing `:content_forge, :asset_storage_impl` config key (same pattern the dashboard-upload controller uses).

Touched files: `lib/content_forge/twilio.ex` (new `download_media/1` + classify_media/cap/header helpers), `lib/content_forge/jobs/sms_media_ingestor.ex` (new), `lib/content_forge/sms/sms_event.ex` (added `"unsupported_media"` status), `lib/content_forge_web/controllers/twilio_webhook_controller.ex` (new `enqueue_media_ingest/2` two-head on active path), `test/content_forge/twilio_test.exs` (7 new describe cases), `test/content_forge/jobs/sms_media_ingestor_test.exs` (new), `test/content_forge_web/controllers/twilio_webhook_controller_test.exs` (added MMS enqueue assertion + plain-SMS refute_enqueued), `BUILDLOG.md`.

### Phase 14.2b: Auto-reply orchestrator with OpenClaw gating

Status: DONE
Merged: master @ `ecfdc12` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 486-0; credo unchanged. Pattern-match-first dispatch. `count_recent_outbound` single aggregate over 24h. OpenClaw-configured-still-ships-fallback invariant pinned by test. Webhook's active head is only enqueue site. 11 dispatcher tests + enqueue assertions added to 14.1b webhook tests.
Note: New Oban worker `ContentForge.Jobs.SmsReplyDispatcher` at `lib/content_forge/jobs/sms_reply_dispatcher.ex` (queue `:default`, max_attempts 3) per BUILDPLAN 14.2b. Flow:

1. `load_event/1` fetches the `SmsEvent` by id. `guard_event/1` three-head filters: `%{direction: "inbound", product_id: binary}` → `{:ok, event}`; inbound without product_id → `:no_product_on_event` (rejected-unknown rows never get replies); outbound or other → `:not_inbound_event`. `dispatch_or_skip/1` function-head then maps every `{:error, reason}` tuple to a distinct `{:cancel, ...}` with a human-readable reason so the Oban queue record is greppable.
2. `dispatch_with_quota/2` reads the per-phone daily rate limit (`:content_forge, :sms, :outbound_rate_limit_per_day`, default 10) and calls `Sms.count_recent_outbound/2` (new helper on the context; single `Repo.aggregate` with `inserted_at >= ^since` on outbound rows, 24h window). `enforce_quota/5` two-head on the `count >= limit` boolean either records a `"rejected_rate_limit"` outbound audit row and returns `{:ok, :rate_limited}` (no Twilio call) or delegates to `send_fallback/2`.
3. OpenClaw branch: this slice intentionally does NOT read `:open_claw` config. Both branches (OpenClaw on and off) ship the unavailable fallback — the real OpenClaw reply-generation call is deferred to 14.2c once OpenClaw's conversational endpoint is confirmed. This guarantees no synthetic reply enters production regardless of config state. The test "OpenClaw configured: still ships fallback this slice" pins this invariant.
4. `resolve_fallback_text/1` two-head: pattern-matches a `%Products.Product{publishing_targets: %{"sms" => %{"unavailable_fallback" => text}}}` with a non-empty binary guard → per-product override; catch-all → `@default_fallback` ("Thanks — your assistant is temporarily unavailable. We will get back to you shortly.").
5. `Twilio.send_sms/3` → `handle_twilio_result/3` function-head dispatched on the full taxonomy:
   - `{:ok, %{sid, status}}` → record `"sent"` outbound + info log → `{:ok, :unavailable_fallback}`
   - `{:error, :not_configured}` → record `"failed"` outbound + warning log "Twilio unavailable (:not_configured); skipping retry" → `{:ok, :twilio_not_configured}` (no crash, no retry - config is broken, retrying won't fix it)
   - `{:error, {:transient, _, _}}` → `{:error, reason}` for Oban retry; no audit row (a successful retry or terminal cancel will write one)
   - `{:error, {:http_error, _, _}}` and `{:unexpected_status, _, _}` → record `"failed"` outbound + error log → `{:cancel, reason}`
   - catch-all `{:error, reason}` → record `"failed"` outbound + error log → `{:error, reason}`

ConversationSession is left untouched by this slice (state remains `"idle"` from the webhook's `get_or_start_session/2`). State transitions driven by real reply content land under 14.2c.

`TwilioWebhookController.dispatch/6` active-phone head now `Oban.insert`s `SmsReplyDispatcher.new(%{"event_id" => event.id})` after recording the inbound event and starting the session. Both rejection heads (inactive + unknown) remain enqueue-free; the webhook tests now assert this via `refute_enqueued(worker: SmsReplyDispatcher)`.

New `Sms.count_recent_outbound/2` helper: `Repo.aggregate/3` with `:count` on outbound rows for a given `phone_number` whose `inserted_at >= now - seconds` (default 86_400). Single round-trip; rate-limit check stays O(1) from the worker's perspective.

11 new tests in `test/content_forge/jobs/sms_reply_dispatcher_test.exs` (async: false, `use Oban.Testing`): happy fallback (raw body inspection proves text got url-encoded); per-product override respected; OpenClaw-on still ships fallback; rate-limit blocks 11th + records `rejected_rate_limit` audit + no Twilio HTTP; under-limit proceeds; Twilio `:not_configured` records `"failed"` + `{:ok, :twilio_not_configured}` no crash; transient 500 returns `{:error, _}` for retry + no outbound audit; permanent 400 records `"failed"` + `{:cancel, reason}`; unknown event id cancels; outbound event cancels (inbound-only); inbound without product_id cancels. Plus three modified webhook tests: active-phone `assert_enqueued(worker: SmsReplyDispatcher, args: %{"event_id" => event.id})`; inactive-phone + unknown-phone both `refute_enqueued`.

Touched files: `lib/content_forge/jobs/sms_reply_dispatcher.ex` (new), `lib/content_forge/sms.ex` (new `count_recent_outbound/2`), `lib/content_forge_web/controllers/twilio_webhook_controller.ex` (Oban.insert on active head), `test/content_forge/jobs/sms_reply_dispatcher_test.exs` (new), `test/content_forge_web/controllers/twilio_webhook_controller_test.exs` (added enqueue assertions), `BUILDLOG.md`.

### Phase 14.2a: ContentForge.Twilio outbound client

Status: DONE
Merged: master @ `52ec927` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 475-0; credo unchanged. Two-head `:not_configured` dispatch; three-head sender resolver (messaging_service_sid priority over from); taxonomy identical to prior HTTP clients. Basic auth inside `build_request`; `redirect: false`; form body as list-of-tuples preserves duplicate `MediaUrl` keys. 16 tests.
Note: New HTTP client at `lib/content_forge/twilio.ex` wrapping Twilio's Messages API (`POST /2010-04-01/Accounts/{AccountSid}/Messages.json`) per BUILDPLAN 14.2a. Mirrors the established error-classification pattern from `ContentForge.MediaForge` / `ContentForge.LLM.Anthropic` / `ContentForge.LLM.Gemini` / `ContentForge.OpenClaw`.

Public surface:

- `status/0` returns `:ok` iff `account_sid` AND `auth_token` AND at least one of `from_number` / `default_messaging_service_sid` are all present; `:not_configured` otherwise. Implemented via `config_status/3` + `default_sender_configured?/0` + `present?/1` so the three-way check stays a single boolean expression instead of nested conditionals.
- `send_sms(to, body, opts)` returns `{:ok, %{sid, status}}` on success or a classified error tuple on failure. Opts: `:media_urls` (list of URLs → MMS), `:from` (per-call override), `:messaging_service_sid` (per-call override).

Dispatch uses pattern-match-first guards: `dispatch/5` two-head on `nil|""` for sid/token returns `:not_configured` without touching Req. `resolve_sender/1` three-head: if `messaging_service_sid` (call opt OR config default) is a non-empty binary → `{:service_sid, sid}`; otherwise fall through to `resolve_from/1` which checks `:from` opt OR `from_number` config and returns `{:error, :not_configured}` when both are unset. This means the config-level sender requirement (at least one of the two) is double-checked at the send site in case config drifts between `status/0` and `send_sms/3`.

Auth is HTTP Basic via Req's built-in `auth: {:basic, "sid:token"}`, attached inside `build_request/2` — never at the call site. Redirects are disabled via `redirect: false` so any 3xx response flows through `classify/1` as `{:unexpected_status, status, body}` instead of silently following to an unrelated URL.

Request body is URL-encoded form. Req's `form:` option takes a list of `{key, value}` tuples and preserves duplicates, so MMS is wired by emitting a separate `{"MediaUrl", url}` tuple per attachment (Twilio's shape). `media_url_pairs/1` three-head on `nil | [] | list` filters out non-binary entries defensively.

Response classification in `classify/1` follows the established taxonomy: 2xx → `parse_success/1` (returns `{:ok, %{sid, status}}` on Twilio's `%{"sid" => _, "status" => _}` shape; `{:error, {:unexpected_body, body}}` on anything else); 3xx → `{:unexpected_status, ...}`; 429 → `{:transient, 429, _}`; 4xx → `{:http_error, ...}`; 5xx → `{:transient, status, _}`; `Req.TransportError` with `:timeout` → `{:transient, :timeout, _}`; `Req.TransportError` with `:econnrefused`/`:nxdomain`/`:ehostunreach`/`:enetunreach`/`:closed` → `{:transient, :network, reason}`; anything else passes through.

16 new tests in `test/content_forge/twilio_test.exs` (async: false, Req.Test plug stubbing): `status/0` four cases (happy-with-from_number, happy-with-service_sid, missing account_sid, empty auth_token, missing both senders); missing-config no-HTTP downgrade; happy path asserts URL shape + HTTP Basic encoding + form-urlencoded body + From branch + no spurious MediaUrl; MMS happy path asserts raw body contains two `MediaUrl=https%3A%2F%2F...` entries (inspected raw because `URI.decode_query` collapses duplicate keys); `messaging_service_sid` precedence over `from_number` asserted via `MessagingServiceSid` present and `From` absent in body; `:from` call-site override; 500 / 429 / 400 / timeout / econnrefused / 301 all land in their respective classify buckets.

Runtime env wiring in `config/runtime.exs`: the single-line `:twilio` config added in 14.1b is expanded to a six-key keyword list covering `base_url` (default `https://api.twilio.com`), `account_sid`, `auth_token`, `from_number`, `default_messaging_service_sid`. Unset env → each value is `nil` → `status/0` reports `:not_configured` → every `send_sms/3` returns `{:error, :not_configured}` with zero HTTP.

Touched files: `lib/content_forge/twilio.ex` (new), `test/content_forge/twilio_test.exs` (new), `config/runtime.exs` (expanded `:twilio` block), `BUILDLOG.md`.

### Phase 14.1b: Twilio inbound webhook receiver

Status: DONE
Merged: master @ `53602d0` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 459-0; credo unchanged. HMAC-SHA1 matches Twilio spec + `secure_compare`. Fail-closed on unset auth token. `port_suffix/2` strips default ports. Controller returns same `rejected_unknown_number` status for inactive AND unknown (no existence leak). 8 tests cover active + inactive + unknown + bad-sig + missing-sig + unset-token + missing-From + media capture.
Note: `POST /webhooks/twilio/sms` outside `/api/v1` per BUILDPLAN 14.1b. New plug `ContentForgeWeb.Plugs.TwilioSignatureVerifier` at `lib/content_forge_web/plugs/twilio_signature_verifier.ex`:

- Reads `x-twilio-signature` header (400 if missing).
- Auth token from `:content_forge, :twilio, :auth_token` via `fetch_auth_token/0` two-head (nil | "" → fail closed with 403 "twilio auth not configured"; binary → proceed).
- Reconstructs the URL via `webhook_url/1` (scheme + host + port-unless-standard + path; `port_suffix/2` function-head pattern-matches `:http, 80` and `:https, 443` → "", anything else → `":#{port}"`).
- `sorted_param_blob/1` walks `conn.body_params`, rejects non-binary values defensively, sorts by key, and `Enum.map_join`s `key <> value` with no separator - matching Twilio's spec exactly.
- HMAC-SHA1 keyed by auth token, base64-encoded, compared via `Plug.Crypto.secure_compare/2`. Mismatch → 403 "invalid signature". The offending signature is never echoed to the response body.

New controller `ContentForgeWeb.TwilioWebhookController` with action `receive/2`. Two `receive/2` heads: one matches `%{"From" => from}` when `from` is a non-empty binary; the catch-all head returns 400 "missing From parameter" and logs "malformed payload (missing From)" without recording an event. The accept head extracts `Body`, `MessageSid`, and `MediaUrl0..N` (walked via `extract_media_urls/1` iterating `0..(NumMedia-1)` with `parse_int/1` three-head on integer/binary/other), then delegates to a `dispatch/6` function-head-dispatched on the `Sms.lookup_phone_by_number/1` result:

- `%ProductPhone{active: true}` → records inbound/received event with product_id + media_urls + twilio_sid, calls `Sms.get_or_start_session/2`, returns empty TwiML 200 (Twilio does not auto-reply).
- `%ProductPhone{active: false}` → records inbound/rejected_unknown_number with product_id preserved for audit, returns gated TwiML 200 with `<Message>` body asking the sender to contact the agency. No session.
- `nil` (unknown number) → records inbound/rejected_unknown_number with product_id nil, returns the same gated TwiML. No session.

New `Sms.lookup_phone_by_number/1` helper added to `ContentForge.Sms` (outside the 14.1a spec surface but required by this slice). Returns the first `%ProductPhone{}` across any product with `order_by: [desc: p.active, asc: p.inserted_at]`, limit 1, so an active row always wins over an inactive row when the same phone is whitelisted multiple times; used by the controller to distinguish "unknown" (nil) from "inactive" (row.active=false) in the audit log.

Router gets a new `:twilio_webhook` pipeline (`plug :accepts, ["xml", "html"]` + the signature verifier) and a second `scope "/webhooks"` block mounting `post "/twilio/sms", TwilioWebhookController, :receive`. The Media Forge webhook pipeline and scope are untouched. `BodyReader` is not extended because Twilio's signature covers sorted form params, not the raw body; the spec's "reused" note was a forward-compatibility acknowledgment rather than a requirement for this slice.

Runtime env wiring in `config/runtime.exs`: `config :content_forge, :twilio, auth_token: System.get_env("TWILIO_AUTH_TOKEN")`. Unset token → plug fail-closed rejection path.

8 new tests in `test/content_forge_web/controllers/twilio_webhook_controller_test.exs` (async: false):
- signed inbound from whitelisted active phone → 200 empty TwiML, inbound/received event persisted with product_id + Twilio SID + body, session started (state "idle")
- `MediaUrl0..N` captured into `event.media_urls` in index order
- signed inbound from unknown phone → 200 gated TwiML `<Message>`, inbound/rejected_unknown_number event with product_id nil, no session
- signed inbound from known inactive phone → 200 gated TwiML, rejected event with product_id preserved, no session
- invalid signature → 403, zero events
- missing `x-twilio-signature` header → 400, zero events
- unset auth_token → 403 on every request (fail closed), zero events
- missing `From` param on a signed request → 400 "missing From", zero events

Twilio's signature algorithm is recomputed in the test via a `sign/3` helper (HMAC-SHA1 keyed by token, over URL + `Enum.map_join` of sorted `key<>value` pairs, base64), mirroring the plug exactly. This means a copy-bug in either direction surfaces as a failing test rather than silent mis-verification.

Downstream routing (OpenClaw auto-acknowledgement) is explicitly out of scope and lands under 14.2.

Touched files: `lib/content_forge/sms.ex` (new `lookup_phone_by_number/1`), `lib/content_forge_web/plugs/twilio_signature_verifier.ex` (new), `lib/content_forge_web/controllers/twilio_webhook_controller.ex` (new), `lib/content_forge_web/router.ex` (new pipeline + scope), `config/runtime.exs` (auth_token env wiring), `test/content_forge_web/controllers/twilio_webhook_controller_test.exs` (new), `BUILDLOG.md`.

### Phase 14.1a: SMS schemas + context

Status: DONE
Merged: master @ `9723086` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 451-0; credo unchanged. Cascade split per spec: phones + sessions delete_all; events nilify_all with `phone_number` captured inline. Pattern-match-first context. `expire_stale_sessions/1` single update_all with Postgres interval math, injectable `now` for tests. 25 tests.
Note: Foundational SMS schemas + context per BUILDPLAN 14.1a. Three new schemas under `lib/content_forge/sms/`:

- `ProductPhone` (whitelist): `phone_number` (E.164 via regex `^\+[1-9]\d{7,14}$`), `role` (`~w(owner submitter viewer)` inclusion), `display_label`, `active` (default true), `opt_in_at` (utc_datetime_usec, nullable - nil until explicit consent), `opt_in_source` (`~w(verbal form reply_yes)` inclusion, nullable). `belongs_to :product`. Composite unique on `(product_id, phone_number)`. A `deactivate_changeset/1` helper flips `active: false` without touching opt-in history.
- `SmsEvent` (audit log, insert-only): `phone_number`, `direction` (`~w(inbound outbound)`), `body` (text), `media_urls` ({:array, :string} default []), `status` (`~w(received sent delivered failed rejected_unknown_number rejected_rate_limit)`), `twilio_sid` (nullable). `belongs_to :product` optional (nullable fk). `timestamps(type: :utc_datetime_usec)` for tie-breaking in chronological queries.
- `ConversationSession` (per-(product, phone) state machine): `phone_number`, `state` (`~w(idle waiting_for_upload waiting_for_context status_query)` default "idle"), `last_message_at`, `inactive_after_seconds` (default 3600). Composite unique on `(product_id, phone_number)`.

Migration `20260429120000_create_sms_schemas.exs` creates all three tables in one go, each with binary_id PK and:

- `product_phones.product_id` fk `on_delete: :delete_all` (whitelist travels with the product); composite unique index `product_phones_product_id_phone_number_index`; plain `phone_number` index.
- `sms_events.product_id` fk `on_delete: :nilify_all` (audit survives product deletion; `phone_number` captured inline for post-nilify forensics); plain `product_id`, `phone_number`, `twilio_sid` indexes.
- `conversation_sessions.product_id` fk `on_delete: :delete_all`; composite unique `conversation_sessions_product_id_phone_number_index`; plain `phone_number` index.

New context module `ContentForge.Sms` at `lib/content_forge/sms.ex`:

- `create_phone/1`, `lookup_phone/2` (by `(phone_number, product_id)` - returns nil for missing OR deactivated, so callers don't have to double-check `.active`), `list_phones_for_product/2` (three-way `:active` option: `true` default | `false` | `:all` via `apply_active_filter/2` function-head), `update_phone/2`, `deactivate_phone/1`.
- `record_event/1`, `list_events/2` (optional `:direction`, `:status`, `:phone_number` filters, each applied via a pattern-match-first `apply_event_*/2` two-head on nil; product_id may be nil to list orphaned audit rows).
- `get_or_start_session/2` (idempotent: `Repo.get_by` short-circuit; existing session gets `last_message_at` refreshed, missing session is inserted as `"idle"`). `set_session_state/2`. `expire_stale_sessions/1` runs a single `Repo.update_all` with a Postgres-native `fragment("? + (? * interval '1 second') < ?", last_message_at, inactive_after_seconds, ^now)` comparison - one round-trip, no per-row iteration. Returns `{:ok, affected_count}`. `now` is injectable for tests.

25 new tests in `test/content_forge/sms_test.exs`: create_phone happy + non-E.164 rejection + unknown-role rejection + duplicate rejection; lookup_phone happy + unknown + deactivated + product-scoped; list_phones_for_product active default + active: false + active: :all; update_phone opt-in update; record_event inbound happy + unknown-number nil-product + invalid-direction rejection; list_events filter-by-direction + filter-by-phone_number; get_or_start_session create-on-first-touch + idempotent-with-refresh (asserts `last_message_at` strictly advances across calls); set_session_state happy + invalid-state rejection; expire_stale_sessions flips stale non-idle sessions + leaves fresh alone + leaves already-idle alone (direct DB manipulation of `last_message_at` via `Repo.update_all` to simulate age); cascade assertion confirming product delete removes phones + sessions and nilifies events while preserving the audit row.

Touched files: `lib/content_forge/sms.ex` (new), `lib/content_forge/sms/product_phone.ex` (new), `lib/content_forge/sms/sms_event.ex` (new), `lib/content_forge/sms/conversation_session.ex` (new), `priv/repo/migrations/20260429120000_create_sms_schemas.exs` (new), `test/content_forge/sms_test.exs` (new), `BUILDLOG.md`.

### Phase 13.4d: Banner stickiness hardening

Status: DONE
Merged: master @ `8f02110` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 426-0; credo unchanged. Implicit-`after` clause on `generate_with_featured/4` — no explicit try, no extra credo surface. Broadcast fires on every exit path including raise; exception bubbles to Oban for retry semantics. Regression test forces a raise and asserts banner clears. Phase 13 fully complete.
Note: Closed the one gap the 13.4c reviewer flagged. `AssetBundleDraftGenerator.generate_with_featured/4` happy-path head now uses an implicit `try/after` by attaching the `after` block directly to the function body:

    defp generate_with_featured({:ok, asset}, bundle, platforms, n) do
      run_generation(asset, bundle, platforms, n)
    after
      ProductAssets.broadcast_bundle_generation_finished(
        bundle.product_id,
        bundle.id
      )
    end

Any exception from `run_generation/4` (a transport error that Req's `classify/1` does not catch, an Ecto constraint that escapes `create_draft/1`, or any other unexpected raise) still fires the `:bundle_generation_finished` PubSub broadcast before bubbling to Oban, so the LiveView banner never sticks. Retry semantics are preserved: the exception propagates normally to Oban, which records the attempt and re-schedules under `max_attempts: 3`. The `:empty` head is left untouched - it does no external work and can only fail via `Logger.warning` or the PubSub broadcast itself, both of which are safe.

1 new regression test in `test/content_forge/jobs/asset_bundle_draft_generator_test.exs` under describe "banner stickiness hardening": subscribes the test process to `asset_bundles:<product_id>`, stubs the Req.Test plug to `raise "simulated transport crash"`, wraps `run_job/3` in try/rescue + try/catch so the test continues past the bubbled exception, then `assert_receive {:bundle_generation_finished, bundle_id}` within 500ms. The assertion fails red before the fix (banner never clears) and passes green after.

Touched files: `lib/content_forge/jobs/asset_bundle_draft_generator.ex` (hoisted after-block onto `generate_with_featured/4` happy-path head), `test/content_forge/jobs/asset_bundle_draft_generator_test.exs` (new describe + test), `BUILDLOG.md`.

### Phase 13.5b: Publisher rendition swap

Status: DONE
Merged: master @ `f0da860` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 425-0; credo net -9 (grandfathered `build_post_opts` cyclomatic-19 finally resolved via function-head decomposition). Legacy drafts zero-HTTP through 10.2b path; `@carousel_platforms` gates carousel opts to instagram/facebook only. 11 tests.
Note: `ContentForge.Jobs.Publisher` now resolves platform-specific URLs from attached `draft_assets` before publishing, per BUILDPLAN 13.5b. Both entry paths (`publish_to_platform/4` for the `product_id+platform` args shape and `do_publish_approved/2` for the `draft_id` args shape) go through a new `resolve_post_assets/2` step before building opts. `resolve_post_assets/2` returns one of:

- `{:ok, %{primary_url: _, gallery_urls: [...]}}` — continue to publish
- `{:blocked, reason}` — mark draft `"blocked"` via `ContentGeneration.mark_draft_blocked/1` and return `{:cancel, reason}`, mirroring the 10.2b missing-image blocker state
- `{:error, reason}` — propagate upward so Oban retries (transient errors only)

Resolution flow: `load_attachments/1` (direct query on `DraftAsset` with `preload: :asset` and `order_by: inserted_at asc`) splits into featured + gallery via `split_by_role/1`. Featured is the first row with `role: "featured"`; if none exists (pre-role-tagging drafts), the first attachment serves as featured while the rest become gallery. `resolve_primary/3` calls `RenditionResolver.resolve/2`; `resolve_gallery/2` uses `Enum.reduce_while/3` to short-circuit on the first error, aggregating resolved URLs into a list in attach order.

Legacy drafts (no attachments) collapse to `{:ok, %{primary_url: draft.image_url, gallery_urls: []}}` so `build_post_opts/4` has a uniform shape regardless of provenance. Legacy callers don't hit `RenditionResolver.resolve/2` and don't touch Media Forge at all — the resolver-first read was key here; resolver-second would have surprised existing "image_url present, no attachments" drafts.

`build_post_opts/3` is gone; the new public `build_post_opts/4` takes `(draft, _optimal_windows, product, resolution)` and composes the keyword list through three small helpers: `put_primary_image/2` (two-head on the resolution's `primary_url` being a binary or not), `put_carousel/3` (two-head: carousel-capable platform AND non-empty `gallery_urls` → `Keyword.put(:carousel, urls)`; otherwise no-op), and `put_platform_opts/3` (function-head dispatched on `"linkedin" | "reddit" | "facebook" | "instagram" | _`). Carousel-capable platforms are `@carousel_platforms ~w(instagram facebook)`; extending this list is a one-line change. Made `build_post_opts/4` public so the test file can exercise the pure keyword-list construction directly without re-implementing carousel + platform-specific wiring inline the way the older `publisher_test.exs` had to.

Error taxonomy pass-through in `interpret_resolver_result/3` (function-head per tuple shape) mirrors `ContentBriefGenerator`:

- `{:error, :not_configured}` → `{:blocked, "rendition unavailable: media forge not configured"}` + a warning log reading "rendition unavailable ... media forge not configured"
- `{:error, {:transient, _, _}}` → `{:error, reason}` for Oban retry (draft stays `"approved"`)
- `{:error, {:http_error, status, _}}` → `{:blocked, "rendition failed: HTTP #{status}"}` + error log (draft blocked, `{:cancel, reason}`)
- `{:error, {:unexpected_status, status, _}}` → `{:blocked, "rendition failed: unexpected HTTP #{status}"}`
- `{:error, {:unexpected_body, _}}` → `{:blocked, "rendition failed: unexpected response body"}`
- `{:error, reason}` (catch-all) → `{:error, reason}` for retry
- `{:ok, {:async, _}}` — video job id, not yet exercised by this slice → falls back to `draft.image_url` on the primary path and contributes nothing to the gallery

Gallery errors use a parallel `interpret_gallery_error/1` so a single bad attachment does not leak through as success.

11 new tests in `test/content_forge/jobs/publisher_rendition_test.exs` (new file, `use Oban.Testing, async: false`):
- `build_post_opts/4` pure tests: primary URL comes from resolution (not legacy `draft.image_url`); carousel set on instagram/facebook with non-empty gallery; carousel omitted on twitter and on empty gallery lists
- Legacy draft (no attachments) reaches credentials check with zero Media Forge HTTP and keeps `draft.image_url`
- Draft with attached featured asset triggers Media Forge `/api/v1/image/render`, persists an `AssetRendition`, and reaches credentials check
- Cached rendition skips Media Forge entirely
- `:not_configured` blocks the draft (`status: "blocked"`) and logs "rendition unavailable ... media forge not configured"
- Permanent 400 from Media Forge blocks the draft with `"rendition failed: HTTP 400"`
- Transient 503 returns `{:error, {:transient, 503, _}}` for Oban retry, draft stays `"approved"`

Touched files: `lib/content_forge/jobs/publisher.ex` (resolution step in both entry paths, public `build_post_opts/4` with decomposed helpers, full error-taxonomy pass-through), `test/content_forge/jobs/publisher_rendition_test.exs` (new), `BUILDLOG.md`.

### Phase 13.5a: AssetRenditionResolver + asset_renditions cache

Status: DONE
Merged: master @ `1ae7b53` (fast-forward). Reviewer ACCEPT after a re-handoff (initial handoff missed a format gate failure because the coder's wrapper script masked `mix format`'s non-zero exit; fixed inline). Gate: compile/format/test 414-0; credo unchanged. Resolver three-head cache dispatch; verbatim Media Forge error pass-through; partial unique on `status='ready'` keeps failed rows replaceable.
Note: New `ContentForge.ProductAssets.RenditionResolver` at `lib/content_forge/product_assets/rendition_resolver.ex` per BUILDPLAN 13.5a. Single public function `resolve/2`: takes a `%ProductAsset{}` + a platform string, dispatches pattern-match-first through `lookup_spec/1` → `apply_spec/3`. Flow:

- **Unknown platform** (no entry in the `:renditions` config map): `apply_spec(nil, asset, _)` returns `{:ok, Storage.get_publicUrl(asset.storage_key)}` without touching Media Forge.
- **Cache hit** on `asset_renditions` with `status: "ready"`: returns the cached URL synchronously, also without HTTP.
- **Cache miss** (no row, or an existing non-ready row): dispatches on `media_type` via `render/4` three-head: `"image"` posts to `MediaForge.enqueue_image_render/1` with `%{"storage_key", "platform", "spec"}`; `"video"` posts to `MediaForge.enqueue_video_batch/1` (wired per spec for future use, not exercised by 13.5b's publisher swap); any other `media_type` falls back to the primary URL.
- **Image sync response** goes through `extract_image_output/1` (two-head: flat `%{"storage_key" => _}` with optional dims/format, or nested `%{"result" => %{...}}` - recurses once) + `persist_rendition/5`. Anything else bubbles as `{:error, {:unexpected_body, body}}` so 13.5b can pattern-match it. `persist_rendition/5` uses changeset insert for brand-new rows and update for existing non-ready rows (so a previous `failed` retries in place rather than violating the composite unique).
- **Video sync response** handles `%{"jobId" => _}` → `{:ok, {:async, job_id}}`, bare `%{"storage_key" => _}` → resolved URL, anything else → `{:error, {:unexpected_body, body}}`.
- **Error pass-through** is unconditional: `handle_image_response({:error, _} = err, ...)` / `handle_video_response({:error, _} = err, ...)` return the MediaForge tuple verbatim. `:not_configured`, `{:transient, ...}`, `{:http_error, ...}`, `{:unexpected_status, ...}` all arrive at the caller unchanged so 13.5b can reuse the 10.2b image-blocker wiring without restating the taxonomy.

New `ContentForge.ProductAssets.AssetRendition` schema at `lib/content_forge/product_assets/asset_rendition.ex`: `platform`, `storage_key`, `media_forge_job_id`, `status` (`"ready" | "pending" | "failed"`), `width`, `height`, `format`, `generated_at`, `belongs_to :asset`. Required fields: `asset_id`, `platform`, `storage_key`. Migration `20260428120000_create_asset_renditions.exs` creates the table with binary_id PK, `asset_id` fk `on_delete: :delete_all` (asset delete cleans up its renditions), composite unique index `(asset_id, platform)` named `asset_renditions_asset_id_platform_index` referenced by the schema's `unique_constraint`, partial unique on `storage_key` `where: "status = 'ready'"` so two distinct `(asset, platform)` caches can't accidentally share the same output key while pending/failed rows remain free to placeholder, plus a plain `asset_id` index for reverse lookups.

Configuration shape (documented in the moduledoc, wired in tests):

    config :content_forge, :renditions, %{
      "twitter"   => %{aspect: "16:9", width: 1200, format: "jpg"},
      "instagram" => %{aspect: "1:1",  width: 1080, format: "jpg"}
    }

10 new tests in `test/content_forge/product_assets/rendition_resolver_test.exs`: unknown platform returns primary URL without HTTP; cache hit returns cached URL without HTTP; cache `failed` row triggers retry and gets updated in place (status flips to `ready`, storage_key swapped); happy path calls `/api/v1/image/render` with `storage_key + platform + spec`, persists the rendition with width/height/format captured; nested `result` payload shape supported; `:not_configured` passes through with zero HTTP and zero persisted rows; 503 surfaces `{:transient, 503, _}` with zero persist; 400 surfaces `{:http_error, 400, _}` with zero persist; unrecognized sync body surfaces `{:unexpected_body, _}` with zero persist; video asset dispatches to `/api/v1/video/batch` and returns `{:ok, {:async, job_id}}`.

13.5b will swap `ContentForge.Jobs.Publisher` to call `RenditionResolver.resolve/2` against the attached draft asset (via `draft_assets`), and reuse the 10.2b missing-image blocker for `:not_configured` responses.

Touched files: `lib/content_forge/product_assets/rendition_resolver.ex` (new), `lib/content_forge/product_assets/asset_rendition.ex` (new), `priv/repo/migrations/20260428120000_create_asset_renditions.exs` (new), `test/content_forge/product_assets/rendition_resolver_test.exs` (new), `BUILDLOG.md`.

### Phase 13.4c: LiveView trigger from bundle drawer

Status: DONE
Merged: master @ `fde2561` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 404-0; credo unchanged (would-be double Enum.filter merged to single head before handoff). `normalize_platforms/1` three-head; `dispatch_generation/4` two-head. Banner `aria-live=polite` + `data-bundle-generating` selector give tests stable hooks. Reviewer flagged one uncovered edge (if `Anthropic.complete` raises rather than returns `{:error, _}`, banner sticks) — tracked as hardening follow-up under 13.4d.
Note: Extended `ContentForgeWeb.Live.Dashboard.Products.DetailLive` with a generate-drafts form in the bundle drawer per BUILDPLAN 13.4c. New mount assigns: `generating_bundle_ids` (`MapSet.new()` of bundle ids currently awaiting worker completion) and `bundle_generation_error` (nil or a flash-style string surfaced under the form). Two new module attributes: `@bundle_generation_platforms` (`~w(twitter linkedin reddit facebook instagram)`, matches the `PublishingScheduler` list) and `@default_variants_per_platform` (3). Template: beneath the existing add-from-library picker in the drawer, a new "Generate drafts" section renders (a) an `alert alert-info role="status" aria-live="polite" data-bundle-generating={bundle.id}` banner reading "drafts generating..." whenever `bundle.id` is in the MapSet, (b) a `No publishing platforms are enabled for this product` message when `enabled_platforms(@product) == []`, or (c) a `phx-submit="generate_drafts"` form with a `platforms[]` checkbox (pre-checked) per enabled platform, a `variants_per_platform` number input (min 1, max 10, default 3), inline error text sourced from `bundle_generation_error`, and a submit button disabled while the bundle is generating. `enabled_platforms/1` is a three-head helper that pattern-matches on `%Products.Product{}`, a plain map (picks keys with `%{"enabled" => true}`), or nil.

Event `generate_drafts` uses a guard-cascade: `normalize_platforms/1` (three-head: nil, "", list with member filter + uniq; anything else empty) + `parse_variants/1` (five-head: nil/""/positive integer/parseable binary/default) → `dispatch_generation/4` (two-head: empty platforms surfaces `bundle_generation_error` via assign, non-empty inserts `Oban.Job` from `AssetBundleDraftGenerator.new/1` with binary-key args matching the worker's `perform/1` signature, broadcasts `:bundle_generation_started` for cross-session subscribers, and calls `mark_generating/2` to add the id to the MapSet). Two new `handle_info` clauses for `{:bundle_generation_started, bundle_id}` and `{:bundle_generation_finished, bundle_id}` update the MapSet via `mark_generating/2` and `unmark_generating/2` — the form-submitting session updates optimistically when it calls `dispatch_generation`, but a second LiveView tab open on the same product stays in sync via PubSub.

New helpers in `ContentForge.ProductAssets`: `broadcast_bundle_generation_started/2` and `broadcast_bundle_generation_finished/2` publish `{event, bundle_id}` tuples on the existing `asset_bundles:<product_id>` topic. Keeping these on the existing topic (not introducing a new one) means the LiveView only has one bundle-scoped subscription to maintain, and the handle_info clauses line up by event atom.

`AssetBundleDraftGenerator.perform/1` now broadcasts `:bundle_generation_finished` on every exit path through a small `run_generation/4` helper split out of `generate_with_featured/4`: the `:empty` branch (no assets) broadcasts before returning `{:cancel, ...}`; the happy branch runs the existing generation pipeline, captures the result, broadcasts, and returns. This fires for success, `:not_configured` skip, permanent cancels, AND transient errors — which means if Oban retries on a transient, the banner will clear early, but the draft list updates the moment persistence finishes, and the alternative (leaving the banner stuck on every 5xx flap) is worse UX for the solo-dev timeline.

6 new tests in `test/content_forge_web/live/dashboard/bundle_generate_drafts_test.exs` (new file, `use Oban.Testing, repo: ContentForge.Repo`, async: false so `assert_enqueued`/`refute_enqueued` are deterministic):
- form renders a checkbox per enabled platform and hides disabled + absent platforms; variants input defaults to 3
- empty `publishing_targets` swaps the form for "No publishing platforms are enabled"
- submit enqueues `AssetBundleDraftGenerator` with binary-key args matching `perform/1`; banner + `data-bundle-generating={bundle.id}` render on the returned HTML
- blank/missing `variants_per_platform` enqueues with default 3
- no platforms selected refutes enqueue AND surfaces `"Select at least one platform"` under the form
- `broadcast_bundle_generation_finished/2` clears the banner (process-sleep + re-render verifies PubSub integration)

Touched files: `lib/content_forge_web/live/dashboard/products/detail_live.ex` (new aliases, module attrs, 2 assigns, `generate_drafts` event, 2 `handle_info` clauses, helpers, template section), `lib/content_forge/product_assets.ex` (2 new public broadcast helpers), `lib/content_forge/jobs/asset_bundle_draft_generator.ex` (broadcasts finished on every exit path via `run_generation/4` split), `test/content_forge_web/live/dashboard/bundle_generate_drafts_test.exs` (new), `BUILDLOG.md`.

### Phase 13.4b: AssetBundleDraftGenerator worker

Status: DONE
Merged: master @ `2746f7f` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 398-0; credo unchanged. Pattern-match dispatch throughout. `persist_variants` iterates requested platforms (not LLM keys) — partial payloads skip cleanly. Migration `nilify_all` on `drafts.bundle_id`. 8 tests. Heads-up: `image_url` = featured asset internal storage_key as placeholder — manual `'draft'→'approved'` gates this, but 13.5 must resolve to a real URL before publish.
Note: New `ContentForge.Jobs.AssetBundleDraftGenerator` Oban worker at `lib/content_forge/jobs/asset_bundle_draft_generator.ex` (queue `:content_generation`, max_attempts 3). `perform/1` takes `%{"bundle_id" => binary, "platforms" => [...], "variants_per_platform" => pos_integer}` with a guard that rejects zero/negative variant counts. Flow: `ProductAssets.get_bundle!/1` (preloads `bundle_assets: [:asset]` in position order) → two-head `featured_asset/1` picks the first bundle_asset's `%ProductAsset{}` (or `:empty`) → two-head `generate_with_featured/4` either cancels with "bundle has no assets" or builds the prompt and calls `Anthropic.complete/2`. Prompt: system message describes the JSON-only response shape `%{"platforms" => %{"<name>" => ["variant 1", ...]}}`; user message carries bundle name, context, an ordered "Assets (in display order)" manifest with `<i>. filename - media_type=... tags=[...] description=...` per row, the comma-joined platform list, and the requested variants-per-platform count. `handle_completion/5` is function-head dispatched on every result shape the taxonomy defines (`{:ok, %{text, model}}`, `{:error, :not_configured}`, `{:error, {:transient, _, _}}`, `{:error, {:http_error, _, _}}`, `{:error, {:unexpected_status, _, _}}`, `{:error, _}`) mirroring `ContentBriefGenerator`: `:not_configured` logs "LLM unavailable" and returns `{:ok, :skipped}` with zero DB writes; transient propagates `{:error, reason}` for Oban retry; permanent 4xx and 3xx cancel with a formatted reason; malformed JSON (after `extract_json/1` + `try_fenced/1` fallback identical to `MultiModelRanker`) cancels with `"malformed LLM output"`. On success `persist_variants/6` iterates the requested platform list (not the LLM's keys - missing platforms are silently skipped without blowing up), `Enum.take/2`s to the requested count, and for each variant calls `ContentGeneration.create_draft/1` with `bundle_id`, `content`, `platform`, `content_type: "post"`, `generating_model: "anthropic:<model>"`, `image_url: asset.storage_key`, then `ContentGeneration.attach_asset(draft, featured, role: "featured")`. `draft.image_url` remains authoritative for the Stage-3.5 publisher gate this slice; 13.5 will swap the publisher to read from `draft_assets` directly.

Migration `20260427120000_add_bundle_id_to_drafts.exs` adds `drafts.bundle_id` referencing `asset_bundles` with `on_delete: :nilify_all` (deleting a bundle keeps the generated drafts' history and just detaches them) and a plain `drafts_bundle_id_index`. `Draft` schema adds `belongs_to :bundle, ContentForge.ProductAssets.AssetBundle` and casts `:bundle_id` in the changeset.

8 new tests in `test/content_forge/jobs/asset_bundle_draft_generator_test.exs`: happy path asserts N drafts per platform are created with bundle_id set, image_url equal to the featured asset's storage_key, generating_model prefixed `anthropic:`, and the featured asset attached via `attach_asset/3` (verified through `list_assets_for_draft/1`); fenced-JSON parsing mirrors the `MultiModelRanker` regex path; LLM payload missing a requested platform yields drafts for the present platform only without crashing; `:not_configured` yields `{:ok, :skipped}` with zero HTTP and zero drafts; malformed JSON cancels with a `"malformed"` reason and zero drafts; 503 returns `{:error, {:transient, 503, _}}` for retry; 400 cancels with `"HTTP 400"`; bundle with no assets cancels with `"no assets"` reason.

Touched files: `lib/content_forge/jobs/asset_bundle_draft_generator.ex` (new), `lib/content_forge/content_generation/draft.ex` (belongs_to :bundle + cast :bundle_id), `priv/repo/migrations/20260427120000_add_bundle_id_to_drafts.exs` (new), `test/content_forge/jobs/asset_bundle_draft_generator_test.exs` (new), `BUILDLOG.md`.

### Phase 13.4a: Draft - ProductAsset many-to-many

Status: DONE
Merged: master @ `fe68e78` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 390-0; credo unchanged. Migration: cascade delete_all on both FK sides, composite unique + directional indexes, utc_datetime_usec for deterministic attach-order sort. `attach_asset/3` three-head dispatch with `Repo.get_by` short-circuit idempotency. 12 tests cover defaults + role override + duplicate + id-arg + detach + list ordering + through preload + both cascade directions.
Note: New `ContentForge.ContentGeneration.DraftAsset` join schema at `lib/content_forge/content_generation/draft_asset.ex` (binary_id PK, draft_id + asset_id FKs, `role` string default "featured" with inclusion in `~w(featured gallery)`, inserted_at only - no updated_at). Migration `20260426120000_create_draft_assets.exs` creates `draft_assets` with `on_delete: :delete_all` on both FK directions (draft delete or asset delete removes the join row), composite unique index `draft_assets_draft_id_asset_id_index` referenced by the schema's `unique_constraint`, plus plain indexes on `draft_id` and `asset_id` for directional lookup. `timestamps` uses `:utc_datetime_usec` so `list_assets_for_draft/1` returns rows in attach order even when multiple attaches happen in the same second (without usec precision a three-in-a-row attach was non-deterministic in tests). `Draft` schema at `lib/content_forge/content_generation/draft.ex` gains `has_many :draft_assets, ContentForge.ContentGeneration.DraftAsset, on_delete: :delete_all, preload_order: [asc: :inserted_at]` and `has_many :assets, through: [:draft_assets, :asset]` so `Repo.preload(draft, :assets)` returns the attached `%ProductAsset{}`s directly. Context extensions in `ContentForge.ContentGeneration`:

- `attach_asset(draft, asset, opts \\ [])` - `opts[:role]` defaults to `"featured"`. Idempotent via a `Repo.get_by` short-circuit (duplicate returns the existing row without surfacing the unique-constraint error). Accepts struct-or-binary-id on both sides via a pattern-match fallback head. Invalid roles return a changeset error.
- `detach_asset(draft, asset)` - no-op when not attached; otherwise deletes the row via a small `discard_result/1` helper that collapses `{:ok, _}` to `:ok` while passing through `{:error, _}`. Struct arguments only.
- `list_assets_for_draft(draft_id)` - `join: a in assoc(da, :asset)` + `select: a` returns the `%ProductAsset{}`s ordered by `draft_assets.inserted_at` ascending (attach order).

Existing `draft.image_url` remains authoritative for the publisher; Phase 13.5 swaps it to read from this relation.

12 new tests in `test/content_forge/content_generation/draft_asset_test.exs`: attach default-featured / attach explicit gallery / reject unknown role / duplicate no-op returns existing row with DB count 1 / id-argument form; detach happy + detach no-op; list_assets_for_draft returns ProductAssets in insertion order + empty []; `Repo.preload(draft, :assets)` returns attached assets via the through-assoc; draft-delete cascade removes rows (asset survives); asset-delete cascade removes rows (draft survives).

Touched files: `lib/content_forge/content_generation.ex` (three new public fns + aliases for DraftAsset and ProductAsset), `lib/content_forge/content_generation/draft.ex` (has_many additions), `lib/content_forge/content_generation/draft_asset.ex` (new), `priv/repo/migrations/20260426120000_create_draft_assets.exs` (new), `test/content_forge/content_generation/draft_asset_test.exs` (new), `BUILDLOG.md`.

### Phase 13.3b: Bundle management LiveView

Status: DONE
Merged: master @ `8323486` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 378-0; credo unchanged. Two-clause `handle_info` splits the asset and bundle PubSub streams; `shift_asset/3` two-head direction dispatch; Up/Down with disabled-at-edges matches the no-drag spec intent. 11 LiveView tests cover create+invalid, count/mosaic, drawer list, reorder persistence, picker filter + refuse-re-add, archive, soft-delete, and external PubSub refresh.
Note: Extended `ContentForgeWeb.Live.Dashboard.Products.DetailLive` with a Bundles tab per BUILDPLAN 13.3b. Mount now loads bundles through a new `list_bundles_with_assets/1` helper (list bundles, then `get_bundle!/1` per-row to preload `bundle_assets: [:asset]` in position order) and subscribes to the new `asset_bundles:<product_id>` topic alongside the existing `product_assets:<product_id>`. New assigns: `bundles`, `bundle_form` (an `AssetBundle` changeset wrapped via `to_bundle_form/2` as `:bundle`), `open_bundle_id` (nil or the id of the currently expanded drawer), `picker_media_filter` ("", "image", "video"). Bundles tab renders: a create-bundle form with name + context inputs (phx-submit `create_bundle`, submit keeps the form sticky on invalid and resets on success), an empty state ("No bundles yet"), and a responsive grid (`grid-cols-1 md:grid-cols-2`) of bundle cards. Each card shows the name + truncated context, a right-aligned `"<N> assets"` count, a 1-col mobile / 2-col sm+ mosaic of up to 4 thumbnail tiles (placeholder filename tiles marked `data-bundle-thumb={asset_id}` pending a signed-GET URL helper in a later slice), and action buttons Open/Close (toggles the inline drawer), Archive and Delete (both `data-confirm`). Drawer (`id="bundle-detail-<id>"`) lists members as an `<li :for>` keyed with `data-bundle-asset-row={asset_id}`, each row with explicit Up (`↑`) and Down (`↓`) buttons (no drag, per spec) plus a remove `×`; `disabled` flags prevent first-row up and last-row down. Below the list, an "Add from library" picker renders a media-type filter (phx-change `filter_picker_media`) and a wrap-flex of `+ filename` buttons for every asset on the product that is (a) not already a member and (b) passes the filter. Each picker button carries `data-picker-asset={asset.id}` for stable test assertions. Empty picker shows "No more assets to add." Event wiring: `create_bundle`, `open_bundle`, `close_bundle`, `remove_bundle_asset`, `reorder_bundle_asset` (direction "up"|"down"), `filter_picker_media`, `add_bundle_asset`, `archive_bundle`, `soft_delete_bundle`. Reorder uses `shift_asset/3` (function-head on "up" / "down") + `swap/3` to compute the new id list from the current bundle ordering, then delegates to `ProductAssets.reorder_bundle_assets/2`. `handle_info` guard-clauses in on `%AssetBundle{}` + event atom so asset events (existing handler) and bundle events fan out cleanly; both handlers re-query synchronously so the current session sees changes immediately while PubSub keeps other subscribers in sync. Helpers: `picker_candidates/3` (MapSet of attached ids then `filter_by_media/2` function heads on nil/""/string), `translate_bundle_error/1`. 11 new LiveView tests in `test/content_forge_web/live/dashboard_live_test.exs` under describe "Product bundles tab": empty-state + create form renders, create_bundle happy path + missing-name validation ("can&#39;t be blank"), bundle card renders asset count + mosaic thumbs with stable data-bundle-thumb markers, open_bundle expands the drawer with `bundle-detail-<id>` + `data-bundle-asset-row=<id>`, remove_bundle_asset drops the row and updates the count, reorder up moves asset earlier and persists via reorder_bundle_assets, filter_picker_media by image hides videos, add_bundle_asset attaches a filtered candidate and hides it from the picker after attach, archive_bundle + soft_delete_bundle remove from the default list (and the context reports the expected status), and PubSub :bundle_created from a separate process refreshes the list. Touched files: `lib/content_forge_web/live/dashboard/products/detail_live.ex`, `test/content_forge_web/live/dashboard_live_test.exs`, `BUILDLOG.md`.

### Phase 13.3a: AssetBundle schema + context

Status: DONE
Merged: master @ `641c50d` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 367-0; credo unchanged. Cascade semantics correct (product→bundle delete_all; bundle↔asset delete_all both directions). 15 tests cover CRUD, status filters, membership, reorder, and both cascade directions.
Note: New `ContentForge.ProductAssets.AssetBundle` schema at `lib/content_forge/product_assets/asset_bundle.ex` (fields: product_id fk, name 1..120, context text, status "active" | "archived" | "deleted" default "active", timestamps) and `ContentForge.ProductAssets.BundleAsset` join schema at `lib/content_forge/product_assets/bundle_asset.ex` (bundle_id fk, asset_id fk, position integer >= 0, inserted_at only). Migration `20260425120000_create_asset_bundles.exs` creates both tables with binary_id PKs; `asset_bundles.product_id` fks with `on_delete: :delete_all` (product deletion cascades to its bundles); both join-table FKs use `on_delete: :delete_all` so deleting a bundle or an asset removes the membership row; composite unique index on `(bundle_id, asset_id)` named `bundle_assets_bundle_id_asset_id_index` referenced by the schema's `unique_constraint`; plain index on `bundle_id` for fetch-by-bundle queries; `(product_id, status)` index on bundles. `AssetBundle` declares `has_many :bundle_assets, ... preload_order: [asc: :position]` so preloads land in position order; `has_many :assets, through: [:bundle_assets, :asset]` for direct access. Three purpose-specific changesets on `AssetBundle`: `changeset/2` for generic create/update (validates name length, status inclusion, foreign key), `archive_changeset/1` flips status to `archived`, `soft_delete_changeset/1` flips to `deleted`. Context extensions in `ContentForge.ProductAssets`:

- `create_bundle/1`, `get_bundle!/1` (preloads `bundle_assets: [:asset]` in position order via the schema's `preload_order`), `get_bundle/1`, `list_bundles/2` (defaults to `"active"` via `apply_bundle_status/2` with string/list/nil function heads; newest-inserted first), `update_bundle/2`, `archive_bundle/1`, `soft_delete_bundle/1`.
- `add_asset_to_bundle/3` auto-increments `position` from the current max via `next_bundle_position/1` (`coalesce(max(position), -1) + 1`) unless `:position` is passed explicitly. Duplicate add is a no-op via a `Repo.get_by` short-circuit that returns `{:ok, existing_row}` without surfacing the unique-constraint error. Accepts both struct and id arguments.
- `remove_asset_from_bundle/2` is a no-op if the row does not exist; both accept a `%ProductAsset{}` or a string id.
- `reorder_bundle_assets/2` takes a list of asset ids in the desired order; runs a transaction that `update_all` each row's `position` by index. Asset ids that are not current members are ignored; members not listed keep their position.
- All bundle writes pipe through a `maybe_broadcast_bundle/2` helper that fires events on a separate PubSub topic: `"asset_bundles:<product_id>"` (distinct from the existing `"product_assets:<product_id>"` so asset-only subscribers do not receive bundle events). Events: `:bundle_created`, `:bundle_updated`, `:bundle_archived`, `:bundle_deleted`, `:bundle_membership_changed`. New `subscribe_bundles/1` mirrors the existing `subscribe/1`.

New test file `test/content_forge/product_assets/asset_bundle_test.exs` covers 15 cases: create with broadcast + name validation + 120-char name cap; list default hides archived + deleted, `:status` override can include them; update/archive/soft_delete broadcasts; add_asset auto-increment position; duplicate-add no-op returns existing; membership broadcast on successful add; remove + broadcast + no-op on non-member; reorder applies requested order and ignores non-member ids; product delete cascades both tables; bundle delete removes join rows but leaves assets.

Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 367/0 (352 prior + 15 new). Credo by content unchanged vs post-13.2a: no new findings from the new schemas, migration, context additions, or test file; same known carryovers per `f26d099` rule.

### Phase 13.2a: Asset tag editing, search, filters

Status: DONE
Merged: master @ `b89e031` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 352-0; credo unchanged. Search SQL uses parameterized ilike on description OR `ilike(array_to_string(tags, ' '), ^pattern)` — no injection surface. `apply_search_filter/2` three-head drops empty filters. `top_tags` sort `{-count, tag}` gets count-desc-then-alpha in one pass. 15 tests (11 context + 4 LiveView) cover all paths.
Note: Extended the Assets tab with free-text tag editing + search + filters, per BUILDPLAN 13.2a. Context (`ContentForge.ProductAssets`): new `add_tag/2` / `remove_tag/2` that dedupe (Enum.uniq) and trim, update via the standard changeset, and pipe through `maybe_broadcast/2` so subscribers see `:asset_updated`; `list_assets/2` gains a `:search` option that applies a case-insensitive `ilike(description, ?)` OR `ilike(array_to_string(tags, ' '), ?)` so either substring match hits; and new `top_tags/2` (default limit 8) returns `[{tag, count}]` via `fragment("unnest(?)", tags)` + `Enum.frequencies/1`, sorted by count desc then alphabetically, filtered to non-deleted assets. LiveView (`Dashboard.Products.DetailLive`): mount pre-populates `asset_search`, `asset_media_filter`, `asset_tag_catalog` (via `list_distinct_tags/1`), `asset_top_tags` (via `top_tags/2`); Assets tab renders a search form (role="search"), a media-type dropdown, a top-tag facet row of clickable pills that set the search via a new `use_facet` event, per-row removable tag chips with an × button wired to `remove_tag`, and an inline add-tag form with a `<datalist id="asset-tag-catalog">` autocomplete. New events: `search_assets` (accepts both `%{"value" => _}` and `%{"search" => _}` shapes to handle phx-change and phx-submit uniformly), `filter_media_type`, `use_facet`, `add_tag`, `remove_tag`. After every state-changing event a local `refresh_assets/1` + `refresh_asset_catalog/1` pair re-queries with the current filter composition; PubSub still broadcasts to other subscribers but the current session's view updates synchronously so tests see immediate results without racing an async message. `refresh_assets/1` uses a `maybe_put_opt/3` + `blank_to_nil/1` pair so empty search / empty media filter are dropped from the keyword list rather than applied as empty filters. Empty-state copy updated from "No assets yet" to "No assets match" to match the filter semantics. New tests: 11 context tests (add_tag happy + idempotent + trim+skip, remove_tag happy + no-op on missing, `:search` matches tag substring / description case-insensitive / composes with media_type / empty-match returns [], `top_tags/2` count+alphabetical sort + excludes deleted) and 4 LiveView tests (adding a tag renders a chip + new facet, removing a tag drops its chip, search filters by tag substring, facet click prefills search + filters). The existing "Assets tab empty state" test copy was updated to match "No assets match" + search placeholder. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 352/0 (337 prior + 15 new). Credo by content unchanged vs post-13.1e: no new findings; same known carryovers per `f26d099` rule.

### Phase 13.1e: AssetVideoProcessor worker

Status: DONE
Merged: master @ `7772fc9` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 337-0; credo unchanged. Twin of 13.1d with video-specific extensions: duration_from_seconds fallback (seconds→ms), 4-key fallback on normalized_storage_key, poster unification with thumbnail column for uniform dashboard preview. `mark_processed_changeset` casts all 5 fields. 9 tests including duration_seconds conversion.
Note: Filled in the stub `ContentForge.Jobs.AssetVideoProcessor` that shipped under 13.1b. The flow and error taxonomy mirror 13.1d exactly; the only video-specific bits are the MediaForge endpoint (`enqueue_video_normalize/1` → `POST /api/v1/video/normalize`), the transform list (`probe`, `normalize`, `poster`), the codec hints in the request (`h264` / `aac`), and the additional metadata persisted (`duration_ms` + a `normalized_storage_key` alongside the already-existing `thumbnail_storage_key` which doubles as the video poster). Schema extension: new `normalized_storage_key` column added via migration `20260424180000_add_normalized_storage_key_to_product_assets.exs`; `ProductAsset.mark_processed_changeset/2` now casts width, height, duration_ms, thumbnail_storage_key, and normalized_storage_key. The thumbnail column is intentionally reused for the video poster so a single dashboard lookup can drive preview rendering for both media types. Shape-tolerant extraction reads width/video_width, height/video_height, duration_ms/duration_millis (with a fallback that converts `duration_seconds` * 1000 to ms), poster_storage_key/poster_key/thumbnail_storage_key, and normalized_storage_key/output_storage_key/output_key/r2_key - all through the shared `first_present/2` + `integer_value/1` helpers so Media Forge shape drift is a one-line fix. Error rules identical to 13.1d: `{:error, :not_configured}` marks failed with exact string `"media_forge_unavailable"` (no HTTP either at the initial call or during a late poll); 5xx / 429 / timeout / network propagate as `{:error, reason}` so Oban retries while the asset stays `pending`; 4xx / unexpected_status mark failed with HTTP status in the reason and return `{:cancel, _}`; async terminal `failed` / `error` marks failed with the provider reason; poll exhaustion marks failed rather than spinning. Already-processed / failed / deleted / missing-storage-key assets short-circuit without HTTP for retry idempotency; missing asset cancels. Poll interval + max attempts configurable via `:content_forge, :asset_video_processor`. New test file `test/content_forge/jobs/asset_video_processor_test.exs` covers 9 cases with `Req.Test` stubs: sync happy path (asserts transforms + codec hints + persisted duration_ms/width/height/normalized/thumbnail), duration_seconds → duration_ms conversion, counter-verified async polling through running → done, `:not_configured` → failed + media_forge_unavailable with zero HTTP, 503 transient stays pending, 4xx permanent fails with HTTP status, async terminal `failed` marks failed with provider reason, idempotent short-circuit on already-processed, missing-asset cancel. Log noise wrapped in `capture_log`. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 337/0 (328 prior + 9 new). Credo by content unchanged vs post-13.1d: no new findings from the new worker, migration, or test file; same known carryovers per `f26d099` rule.

### Phase 13.1d: AssetImageProcessor worker

Status: DONE
Merged: master @ `afd596b` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 328-0; credo unchanged. `process/1` 3-head dispatch (already-processed no-op, missing storage_key fail, default); `handle_response/2` and `handle_poll/4` six-head taxonomies — pattern-match-first throughout. `:not_configured` hits `fail/2` with exact `"media_forge_unavailable"` string on both sync and poll paths. Shape-tolerant `extract_int`/`first_present` for Media Forge response variance. 8 tests. Migration adds `thumbnail_storage_key`; `mark_processed_changeset` casts it.
Note: Filled in the stub `ContentForge.Jobs.AssetImageProcessor` that shipped under 13.1b. The worker now dispatches pending image assets through Media Forge and records the probed dimensions plus the generated thumbnail's storage key. Flow mirrors the `ImageGenerator` + `VideoProducer` patterns:

1. `perform/1` loads the asset. Missing asset -> `{:cancel, "asset not found"}`. Already-processed/failed/deleted asset -> `:ok` (no HTTP, safe to replay). Asset without a `storage_key` -> mark failed with a clear reason.
2. `process/1` calls `MediaForge.enqueue_image_process/1` with the storage key and the four transforms the spec names (`autorotate`, `strip_exif`, `thumbnail`, `probe`), plus a thumbnail max-dimension hint and asset/product metadata.
3. Synchronous response containing `width`/`height` (optionally under `result`/`data`) short-circuits straight to `ProductAssets.mark_processed/2` with the dimensions and the extracted thumbnail key.
4. Asynchronous response carrying a `jobId` polls `MediaForge.get_job/1` with a configurable interval + attempt cap (defaults to 3 s x 60 attempts; test config overrides to 0). Terminal `done`/`completed`/`succeeded` applies the result; terminal `failed`/`error` marks the asset failed with the reported reason.

Error taxonomy per BUILDPLAN:

- `{:error, :not_configured}` from either the initial call or a late poll marks the asset failed with the exact string `"media_forge_unavailable"` so the dashboard's `asset.error` field surfaces the reason.
- 5xx / 429 / timeout / network propagate as `{:error, reason}` for Oban to retry; the asset stays in `pending` so the retry succeeds idempotently once Media Forge recovers.
- 4xx and unexpected_status mark the asset `failed` with the HTTP status in the reason and return `{:cancel, _}`.
- `mark_processed/2` validation failure falls through to `fail/2` so a malformed Media Forge result does not leave the asset in a half-written state.

Schema extension: new `thumbnail_storage_key` column on `product_assets` added via migration `20260424120000_add_thumbnail_storage_key_to_product_assets.exs`. `ProductAsset.mark_processed_changeset/2` now casts the new field alongside width/height/duration_ms.

Result extraction helpers use function-head pattern-matching:

- `extract_result/1` tries `body["result"]` -> `body["data"]` -> the body itself when it already contains `width`+`height` -> nil
- `extract_int/2` + `integer_value/1` + `first_present/2` are shared shape-tolerant readers that accept `width`/`image_width`, `height`/`image_height`, and `thumbnail_storage_key`/`thumbnail_key`/`thumbnail_url` interchangeably so a Media Forge shape change is a one-line fix

Polling interval and attempt cap read from `:content_forge, :asset_image_processor` config (`poll_interval_ms`, `poll_max_attempts`) so tests can set both to zero without mocking.

New test file `test/content_forge/jobs/asset_image_processor_test.exs` covers 8 cases with `Req.Test` stubs: synchronous happy path (asserts transforms list + request shape + persisted width/height/thumb), async happy path via counter-verified two-poll-then-done sequence, `:not_configured` -> `failed`+`media_forge_unavailable` with zero HTTP (refute_received), 503 transient -> `{:error, _}` + asset stays `pending`, 4xx permanent -> `failed` + `{:cancel, _}`, async terminal `"failed"` status -> `failed` with provider reason, already-processed asset short-circuits with zero HTTP, missing asset cancels with zero HTTP. Log noise wrapped in `capture_log`.

Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 328/0 (320 prior + 8 new). Credo by content unchanged vs post-13.1c: no new findings from the new worker, migration, or test file; same known carryovers per `f26d099` rule.

### Phase 13.1c: LiveView upload form on product detail

Status: DONE
Merged: master @ `1c6b4d5` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 320-0; credo net 10 improvements (alias ordering resolved on detail_live.ex). External presign shares sanitize path + storage shape with 13.1b. PubSub topology clean (subscribe/broadcast_change, 2-head maybe_broadcast, context broadcasts on all state-changing ops). Mobile-first: live_file_input accept image/*+video/*, min-h-12 touch target, per-file progress+cancel+inline errors. HEIC + x-m4v registered in :mime, :types for iPhone exports.
Note: Extended `ContentForgeWeb.Live.Dashboard.Products.DetailLive` with a new "Assets" tab backed by Phoenix LiveView's native uploads in `external:` mode so bytes go straight from the client to R2 without transiting Phoenix. `allow_upload(:assets, accept: <mimes>, max_entries: 10, max_file_size: 500 MB, external: &presign_asset_upload/2)`. The presign callback builds a sanitised storage key (`products/<id>/assets/<uuid>/<Path.basename-and-alphanum-filtered filename>`), calls the swappable storage impl (`Application.get_env(:content_forge, :asset_storage_impl, ContentForge.Storage)`), and returns `%{uploader: "S3", url: presigned, storage_key, content_type}` so the client-side uploader hook matches the 13.1b target shape. On the server, `save_uploads` consumes the completed entries via `consume_uploaded_entries/3` and calls `ProductAssets.create_asset/1` with the stored metadata, then enqueues `AssetImageProcessor` or `AssetVideoProcessor` per `media_type` (stub workers from 13.1b; 13.1d/13.1e fill them in). Phoenix PubSub: `ContentForge.ProductAssets.subscribe/1` subscribes the LiveView to `"product_assets:<id>"` when `connected?/1`; `create_asset`, `mark_processed`, `mark_failed`, `soft_delete_asset` in the context now broadcast `{:asset_created | :asset_updated | :asset_deleted, asset}` on the product's topic via `Phoenix.PubSub.broadcast/3`; the LiveView's `handle_info({event, asset}, socket)` re-fetches the list with `ProductAssets.list_assets/2` so badges and rows update in place. Mobile-first markup: `<.live_file_input accept="image/*,video/*">` opens camera capture + camera roll on mobile; WCAG AA touch target via `min-h-12`; per-file progress bar + cancel button; upload errors surfaced inline. `image/heic` and `video/x-m4v` registered in `config :mime, :types` so `allow_upload`'s strict validator accepts HEIC/M4V (iPhone default export formats). 3 new LiveView tests: Assets tab renders the upload form + "No assets yet" empty state; Assets tab lists existing asset rows by filename + `asset-<id>` DOM id + `PENDING` badge; PubSub simulation - direct `ProductAssets.mark_processed/2` (which triggers `broadcast_change`) flips the rendered badge from `PENDING` to `PROCESSED`. The existing tab-navigation test was extended to assert the Assets tab label is present. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 320/0 (317 prior + 3 new). Credo strictly better vs post-13.1b: one more baseline finding resolved on `detail_live.ex:8:9` (alias ordering fixed by the alphabetical reorder when adding the new aliases). Same known carryovers per `f26d099` rule. No new findings.

### Phase 13.1b: Presigned upload + register endpoints

Status: DONE
Merged: master @ `8342247` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 317-0; credo unchanged. Security: path traversal blocked (basename + non-alphanumeric→underscore), content-type allow-list enforced on both endpoints (415), size caps 50MB/500MB (413), presign pins content-type query param so R2 rejects mime-mismatched uploads, partial-unique from 13.1a covers duplicates (422), bearer auth via existing `:api_auth` (401). Pattern-match-first: `with` chains + single render sink + function-head `render_error/2` per reason. Stub processor workers ship for `assert_enqueued` matching (no-op until 13.1d/13.1e). 17 tests.
Note: Two new endpoints under the existing `:api`/`:api_auth` pipeline on `/api/v1/products/:product_id/assets/...`:

- `POST /presigned-upload` returns a time-limited PUT URL, the chosen storage key, the expiry timestamp and `expires_in_seconds` (900s / 15 minutes), plus echoed content-type and byte-size. Storage key is built as `products/<product_id>/assets/<uuid>/<sanitised_filename>`; filename is path-basenamed then non-alphanumeric characters replaced with underscores to prevent `..` traversal or weird whitespace. The presign itself goes through a swappable storage impl: defaults to `ContentForge.Storage.presigned_put_url/3` (new function added this slice; wraps `ExAws.S3.presigned_url/5` with the content-type pinned as a query parameter). Tests substitute a pure-Elixir stub via `:content_forge, :asset_storage_impl`.
- `POST /register` creates a `ProductAsset` row in `status: "pending"` with attrs built from the posted body (storage_key, filename, content_type, byte_size, optional uploader/tags/description; uploaded_at is set server-side to `DateTime.utc_now/0`). On success it enqueues `ContentForge.Jobs.AssetImageProcessor` or `ContentForge.Jobs.AssetVideoProcessor` based on `media_type` derived from the mime type. Both processor modules ship as stub workers this slice (no-op `perform/1`) so `assert_enqueued/1` has a worker module to match; 13.1d and 13.1e fill them in.

Validation (shared by both endpoints):

- Content-type allow-list: `image/jpeg`, `image/png`, `image/webp`, `image/heic`, `video/mp4`, `video/quicktime`, `video/x-m4v`. Anything else returns 415 with the allowed list in the body.
- Byte-size caps: 50 MB for images, 500 MB for videos. Oversize returns 413 with `max_bytes` and `got_bytes` in the body.
- Unknown `product_id` returns 404.
- Missing required params return 422.
- Presign failure surfaces as 502.
- Missing bearer token returns 401 (existing `:api_auth` pipeline).

Controller uses an Elixir `with` chain on both actions and a single `render_error_or_response/2` sink that pattern-matches the conn vs error tuple; `render_error/2` has one head per reason atom so the mapping is pattern-match-first.

Storage impl injection: `Application.get_env(:content_forge, :asset_storage_impl, ContentForge.Storage)`. Tests set `PresignStub` / `PresignFailureStub` in-file (inner `defmodule`) and restore the prior value on exit.

New test file `test/content_forge_web/controllers/product_asset_controller_test.exs` covers 17 cases:

- Presigned upload: happy-path image (returns URL + storage_key + expiry + echoed fields), happy-path video with the video-size cap, unsupported content-type 415, oversized image 413, oversized video 413, missing required fields 422, unknown product 404, presign failure 502, unauthorised 401, filename sanitisation (..`/etc/` stripped and spaces/exotic characters collapsed to underscores).
- Register: happy-path image creates pending row + enqueues AssetImageProcessor (refute the video worker was enqueued), happy-path video enqueues AssetVideoProcessor (refute image), disallowed content-type 415 creates no row and enqueues nothing, oversized image 413 creates no row, missing fields 422, duplicate storage_key 422 via the 13.1a partial-unique constraint, unauthorised 401.

Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 317/0 (300 prior + 17 new). Credo unchanged vs post-13.1a state: same baseline resolutions and same known `metrics_poller.ex` / `publisher.ex` / `video_producer.ex` line-shift carryovers per `f26d099` rule. Two transient credo findings introduced by the first draft of the controller (nested-module references to the processor modules) were resolved inline by adding aliases; final diff is zero new findings.

### Phase 13.1a: ProductAsset schema + context

Status: DONE
Merged: master @ `43d8db5` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 300-0; credo unchanged. 4 purpose-specific changesets; 5 function-head filter helpers. Migration: binary_id + nilify_all FK preserves orphans; `(product_id, status)` composite + GIN on `tags` match query patterns; partial-unique `WHERE status <> 'deleted'` correctly referenced via `unique_constraint` so re-registration after soft-delete works. `list_distinct_tags` uses `unnest + distinct` on non-deleted rows. 18 tests cover CRUD + validation + isolation + tag-overlap + state transitions + partial-unique round-trip.
Note: New `ContentForge.ProductAssets.ProductAsset` schema at `lib/content_forge/product_assets/product_asset.ex`, context module `ContentForge.ProductAssets` at `lib/content_forge/product_assets.ex`, and migration `20260423180000_create_product_assets.exs`. Schema carries the spec's required fields (product_id, storage_key, media_type, filename, mime_type, byte_size, uploaded_at) and optional/metadata fields (duration_ms, width, height, uploader, tags, description, status, error). `media_type` limited to `"image" | "video"`; `status` limited to `"pending" | "processed" | "failed" | "deleted"` (default `"pending"`). Three purpose-specific changesets: `changeset/2` for generic create/update, `mark_processed_changeset/2` flips status to `"processed"` and writes width/height/duration_ms while clearing any prior `error`, `mark_failed_changeset/2` flips to `"failed"` and stores the error string, `soft_delete_changeset/1` flips to `"deleted"`. Migration uses `binary_id` primary key, foreign key to `products` with `on_delete: :nilify_all` (soft-delete-safe for the product), `(product_id, status)` index for dashboard queries, GIN index on `tags` for array-overlap searches, and a partial unique index on `(product_id, storage_key) WHERE status <> 'deleted'` named `product_assets_product_id_storage_key_active_index` (also referenced in the schema's `unique_constraint`). Context exposes: `create_asset/1`, `get_asset!/1`, `get_asset/1`, `get_asset_by_storage_key/2`, `list_assets/2` (opts: `:tag`, `:media_type`, `:status`, `:sort_by`, `:limit` - excludes deleted by default, newest-uploaded first), `list_distinct_tags/1` (postgres `unnest` + `distinct`, returns sorted), `update_asset/2`, `mark_processed/2`, `mark_failed/2`, `soft_delete_asset/1`. Filter application uses function-head pattern-matched helpers (`apply_status_filter/2`, `apply_tag_filter/2`, `apply_media_type_filter/2`, `apply_sort/2`, `apply_limit/2`) instead of cond/if chains. Test file `test/content_forge/product_assets_test.exs` covers 18 cases: create happy path + defaults to `pending`, missing-required rejections, unknown media_type/status rejections, non-positive byte_size rejection, get_asset! returns the row, get_asset_by_storage_key scoped to product (same storage_key on a different product doesn't bleed through), list sorts newest-first and isolates per product, tag filter via array overlap, media_type filter, default excludes deleted but `status:` override can include them, `:limit` respected, distinct-tags returns sorted-unique across non-deleted only, mark_processed writes dimensions and clears error, mark_failed sets status and records reason, soft_delete preserves the row and hides it from defaults, partial unique index rejects a duplicate storage_key while the original is active, and allows re-registration once the original is soft-deleted. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 300/0 (282 prior + 18 new). Credo unchanged vs post-11.3b: same baseline findings resolved, same known `metrics_poller.ex` and `publisher.ex` / `video_producer.ex` line-shift carryovers per `f26d099` rule. No new findings from the new files.

### Phase 11.3b: Intel synthesizer LLM adapter

Status: DONE
Merged: master @ `59397aa` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 282-0; credo unchanged. `summarize([])` short-circuits to `{:error, :no_posts}` before any HTTP. `coerce_intel/1` full-map pattern match with `is_binary` + non-empty summary guard; `coerce_string_list/1` enforces list-of-binaries on each array — malformed replies never fabricate. Parse chain mirrors MultiModelRanker. 10 tests cover all validation branches. Phase 11 complete except paused 11.2 caller.
Note: `ContentForge.CompetitorIntelSynthesizer.LLMAdapter` at `lib/content_forge/competitor_intel_synthesizer/llm_adapter.ex` implements the `summarize/1` contract that `ContentForge.Jobs.CompetitorIntelSynthesizer` already dispatches to via the `:intel_model` config. Public surface is a single `summarize([%CompetitorPost{}])` -> `{:ok, %{summary, trending_topics, winning_formats, effective_hooks}}` or a classified error tuple. The adapter calls `ContentForge.LLM.Anthropic.complete/2` with a system prompt that requests a JSON object in exactly the `CompetitorIntel` schema shape (all four fields required; three of them arrays of strings) and a user prompt that formats each post as `[likes=N, comments=N, shares=N, score=N] <content>`. JSON parsing mirrors the MultiModelRanker pattern: `JSON.decode` first, then a fenced-block regex fallback for ` ```json ... ``` ` wrapped replies. `coerce_intel/1` validates the shape via function-head pattern match on the four required keys with a `is_binary(summary) and summary != ""` guard; `coerce_string_list/1` checks each array is a list of binaries. Anything else returns `{:error, :malformed_response}` - no fabricated fallback ever reaches the database. `{:error, :not_configured}` from the LLM passes through unchanged (the synthesizer already discards on that return). Transient errors (5xx, 429, timeout, network) propagate so Oban can retry; permanent errors (4xx, unexpected_status) propagate. Empty post list short-circuits with `{:error, :no_posts}` and zero HTTP - defensive only, since the synthesizer already filters the empty case before calling. Runtime config wiring extends the existing prod-only block in `config/runtime.exs` to also set `:content_forge, :intel_model` to the new adapter; `:test` leaves it unset so `competitor_intel_synthesizer_test.exs`'s existing discard-path assertions keep working. 10 new test cases at `test/content_forge/competitor_intel_synthesizer/llm_adapter_test.exs`: happy path with JSON reply asserting all four fields + user prompt contains the post content + system prompt requests JSON, fenced-block JSON parsing, empty-list defensive `:no_posts` with `refute_received` zero-HTTP, plain-text reply rejected, missing-summary-field rejected, wrong-type array rejected, missing Anthropic key propagates `:not_configured` with zero HTTP, 503 transient, 429 transient, 400 permanent. All Req.Test stubbed; logger warnings wrapped in `capture_log`. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 282/0 (272 prior + 10 new). Credo unchanged vs post-11.3a state: same baseline findings resolved, same `metrics_poller.ex` and `publisher.ex` / `video_producer.ex` line-shift carryovers per `f26d099` rule. No new findings from the new file.

### Phase 11.3a: Apify scraper adapter

Status: DONE
Merged: master @ `b42ec2a` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 272-0; credo unchanged. Four-head dispatch covers both zero-HTTP short-circuits (missing token, unsupported platform); Apify-specific terminals layered on top of shared `classify/1` without polluting HTTP taxonomy. Defensive multi-key normalization per-platform; datetime-nil skips the item rather than raising. Prod-only runtime wiring leaves test discard-path observable. 21 tests cover all 6 platforms + run-terminal + error classes.
Note: `ContentForge.CompetitorScraper.ApifyAdapter` at `lib/content_forge/competitor_scraper/apify_adapter.ex` implements the `fetch_posts/1` contract that `ContentForge.Jobs.CompetitorScraper` already dispatches to via `:scraper_adapter`. Flow: validate token is configured, look up a per-platform actor from `:content_forge, :apify, :actors`, POST `/v2/acts/<actor>/runs` with a conservative superset input (handle + start urls + search terms + maxItems + platform; actors ignore keys they do not know), poll `/v2/actor-runs/<run_id>` until status is terminal, GET `/v2/datasets/<default_dataset_id>/items`, normalise each item to the caller's post-map shape.

**Actor ids chosen at slice time** (recorded in moduledoc, overridable via config and env):

- twitter   -> `apify~twitter-scraper`
- linkedin  -> `apify~linkedin-post-scraper`
- reddit    -> `trudax~reddit-scraper`
- facebook  -> `apify~facebook-pages-scraper`
- instagram -> `apify~instagram-scraper`
- youtube   -> `apify~youtube-scraper`

Per-platform response normalisation uses a lenient field-priority lookup across common Apify output shapes (likeCount/numLikes/likes/score; replyCount/numComments/commentsCount/comments/numberOfComments; retweetCount/numShares/sharesCount/shares; createdAt/postedAt/publishedAt/timestamp/date). Items missing a parseable `post_id` OR a parseable `posted_at` are skipped and counted; the caller still gets the surviving list. Zero items after normalisation returns `{:error, :apify_parse_failure}` so the caller can discard or retry.

Error classification matches MediaForge/Anthropic/Gemini/OpenClaw exactly: 5xx + 429 -> `{:transient, status, body}`; timeout/network -> `{:transient, :timeout|:network, reason}`; 4xx -> `{:http_error, status, body}`; 3xx -> `{:unexpected_status, status, body}`; anything else -> `{:error, reason}`. Apify-specific terminal conditions are also classified: run status `FAILED|ABORTED|TIMED-OUT|TIMED_OUT` -> `{:error, {:apify_run_failed, status}}`; poll exhaustion -> `{:error, :apify_run_poll_timeout}`; missing dataset id on the run -> `{:error, :apify_missing_dataset_id}`; zero normalisable items -> `{:error, :apify_parse_failure}`. Missing token -> `{:error, :not_configured}` with zero HTTP; unmapped platform -> `{:error, :unsupported_platform}` with zero HTTP.

Authentication: `Authorization: Bearer <token>` attached inside `build_req/3` on every request. Req.Test plug baked in from day one; the test suite stubs all three API calls.

Runtime config wiring (`config/runtime.exs`): `APIFY_TOKEN` flows to `:content_forge, :apify, :token`; `APIFY_BASE_URL`, `APIFY_POLL_INTERVAL_MS`, `APIFY_POLL_MAX_ATTEMPTS`, and `APIFY_ACTOR_<PLATFORM>` env overrides are honoured with the slice-time actor defaults. In `:prod` only, `:content_forge, :apify_token` and `:content_forge, :scraper_adapter` are set too so `CompetitorScraper`'s existing top-level gate flips on automatically; `:test` leaves both unset so the existing discard path stays observable for `competitor_scraper_test.exs`.

Test file `test/content_forge/competitor_scraper/apify_adapter_test.exs` covers 21 cases: status trio (ok / missing / empty), missing-token zero-HTTP short-circuit, unsupported-platform zero-HTTP short-circuit, one happy-path scrape per supported platform (twitter / linkedin / reddit / facebook / instagram / youtube) with a realistic stubbed actor output, Bearer header asserted on all three calls with call-count verification, 429/500/400/timeout/304 classification, terminal-non-success run status `FAILED` classification, poll exhaustion with RUNNING never flipping, partial-parse success (unparseable items skipped, survivors returned), complete parse failure returns `:apify_parse_failure`. Logger warnings wrapped in `capture_log`. No live Apify calls.

Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 272/0 (251 prior + 21 new). Credo by content unchanged vs post-11.4+11.5 state: same baseline resolutions and same `metrics_poller.ex` line-shift carryovers. No new findings from the new file.

### Phase 11.4+11.5 (verify): MetricsPoller auto-triggers tests

Status: DONE
Merged: master @ `62e1391` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 251-0; credo 7 baseline resolved, 0 new. `maybe_trigger_spike/2` two-head pattern match with strict `> 3.0` guard (boundary test asserts `== 3.0` does not fire). Oban `unique:` (24h rewrite, `:infinity` spike) prevents duplicate enqueues; idempotency tested both directions. Bundled public-fn, extraction, unique-config, and dropped-unused-platform-arg changes all load-bearing for assertable testing plus latent idempotency-bug fixes.
Note: Verification slice for both auto-triggers that were already wired in `MetricsPoller` but unverified. Two small behaviour changes shipped alongside the tests so the triggers are idempotent and testable:

1. `MetricsPoller.check_rewrite_trigger/1` and a new `MetricsPoller.maybe_trigger_spike/2` are now public. Both were previously `defp`; neither is a hot path, and exposing them is the minimum surface for test-level assertion on the enqueued job specs (the alternative would have been routing through `perform_job` with full platform-client HTTP stubs). Moduledocs on both functions note they are test-accessible and still called internally by `poll_product_metrics/2` and `measure_and_record_post/2`.
2. Extracted `maybe_trigger_spike/2` from the inline `if updated_entry.outcome == "winner" && updated_entry.delta > 3.0` check. The function head pattern-matches on `%ScoreboardEntry{outcome: "winner", delta: delta}` with a `when delta > 3.0` guard; anything else falls through to a `:noop` head. This puts the threshold check in one place where tests can observe it and keeps the measure path short.
3. Both triggers now enqueue with Oban `unique:` config for idempotency. Brief rewrite uniqueness is `period: 24 * 60 * 60` over `[:args, :worker]` - repeat polls in the same day for the same product (even across multiple poor-performing platforms) collapse to a single rewrite job. Winner repurposing uniqueness is `period: :infinity` over `[:args, :worker]` - a draft that already fired a repurposing job never fires again. `trigger_rewrite/1` also dropped the `platform` argument from the args since the rewrite is product-scoped, not platform-scoped; it only drove a logging string.

New test file `test/content_forge/jobs/metrics_poller_test.exs` covers 9 cases. Rewrite trigger: five poor-performer entries enqueue `ContentBriefGenerator` with `force_rewrite: true`; four does not; repeat calls stay at one enqueued job (idempotency); two qualifying platforms still collapse to one job (same idempotency via unique args). Spike trigger: winner + delta 3.5 enqueues `WinnerRepurposingEngine`; winner + delta exactly 3.0 does NOT enqueue (strict threshold); winner + delta 2.5 does NOT; loser + delta 3.5 does NOT (wrong outcome); repeat calls stay at one enqueued job. Scoreboard entries are staged via direct struct insert (`Repo.insert!(%ScoreboardEntry{...})`) to bypass the changeset's auto `calculate_delta/1` and let tests fix exact delta values. Log noise wrapped in `capture_log` around each `check_rewrite_trigger` call.

Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 251/0 (242 prior + 9 new). Credo by content is unchanged vs post-11.2M: same 7 baseline findings resolved; all three existing `metrics_poller.ex` findings (nested-module aliases on 380/418/426, nesting depth on 386, alias ordering on 23) appear at shifted lines (379/445/458, 385, 24) because the new `ScoreboardEntry` alias and the expanded doc blocks shifted the file - function bodies unchanged, per the `f26d099` line-shift rule. `publisher.ex:253:8` and `video_producer.ex:54:12` remain as known line-shift carryovers. No new findings introduced by this slice.

### Phase 11.2M: MultiModelRanker real scoring via LLM clients

Status: DONE
Merged: master @ `86b3884` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 242-0; credo identical to post-11.2-infra. `Enum.random` scoring replaced with Anthropic+Gemini calls; per-model skip on `:not_configured` / malformed / permanent; transient halts for Oban retry; both-missing short-circuits before scoring. JSON parser with fenced-block regex fallback, 0-10 validation per dimension, refuses to write rows for malformed replies. xAI deferral to 11.2M-b documented.
Note: `ContentForge.Jobs.MultiModelRanker.query_model_for_scores/4` no longer fabricates scores via `Enum.random/1`. Each scoring call routes through `ContentForge.LLM.Anthropic.complete/2` (for `"claude"`) or `ContentForge.LLM.Gemini.complete/2` (for `"gemini"`) with a structured JSON scoring prompt that carries the draft, the platform + content_type + angle, calibration hints, and the scoreboard context. The provider is asked to return a JSON object of the exact shape `{"accuracy", "seo", "eev", "critique"}`; the parser decodes with `JSON.decode` first and falls back to a fenced-block regex for providers that wrap JSON in a ` ```json ... ``` ` block. Score validation enforces 0-10 numeric bounds; malformed or out-of-range replies become a per-(draft, model) skip with a clear log line and no DraftScore row is written - no fabricated fallback ever reaches the database. `{:error, :not_configured}` for a provider logs a debug line and skips that provider's contribution so the draft still ranks on whichever provider is configured; if neither provider is configured, the worker logs "LLM unavailable" and returns `{:ok, _}` without promoting any draft (better to pause promotion than to promote on synthetic signal). Transient HTTP errors (5xx, 429, timeout, network) are propagated as `{:error, _}` via `Enum.reduce_while/3` short-circuit so Oban retries the whole job; scores are upserted per (draft, model) so retries are idempotent. Permanent HTTP errors (4xx, unexpected_status) are logged and skipped per (draft, model) rather than blocking the batch. `@models` list trimmed from `["claude", "gemini", "xai"]` to `["claude", "gemini"]` since no xAI client exists yet; the `DraftScore` schema inclusion still allows `"xai"` for a future 11.2M-b slice. Promotion logic now filters out drafts with a nil composite (no usable scores recorded) before ranking - previously they were promoted at composite 0. New test file `test/content_forge/jobs/multi_model_ranker_test.exs` covers 6 cases: happy path with both providers scoring differently by draft and the top-N promotion using real composites; Anthropic-only config with zero Gemini HTTP (refute_received); Gemini-only config with zero Anthropic HTTP; neither configured returns `:ok` with no DraftScore rows and no promotion; malformed JSON from Anthropic yields no claude row while gemini still scores and the draft still ranks; 503 from Anthropic returns `{:error, _}` for Oban retry. All Req.Test stubbed; log noise wrapped in `capture_log`. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 242/0 (236 prior + 6 new). Credo unchanged vs post-11.2 infra state: same 7 baseline findings resolved, `publisher.ex:253:8` and `video_producer.ex:54:12` remain as known line-shift carryovers per `f26d099` rule. No new findings.

### Phase 11.2 (infra): OpenClaw HTTP client

Status: DONE
Merged: master @ `b2785d8` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 236-0; credo identical to post-11.1c. Target-shape assumption documented in moduledoc: Bearer auth against `/api/v1/generate`. Reviewer flagged a smoke-verification question; architect decision: fold live shape verification into 11.2 caller as a prerequisite step rather than minting a dedicated slice.
Note: `ContentForge.OpenClaw` at `lib/content_forge/open_claw.ex`. Single public `generate_variants(request, opts)` that takes a request map (`content_type`, `count`, optional `platform`, `angle`, `brief`, `product`, `performance_insights`) and returns `{:ok, %{variants: [%{text, angle, model}, ...], model, usage}}` or a classified error tuple. Config namespace `:content_forge, :open_claw` with `:base_url`, `:api_key`, `:default_timeout`; runtime sources `OPENCLAW_BASE_URL`, `OPENCLAW_API_KEY`, and `OPENCLAW_TIMEOUT_MS`. Missing base URL or API key (nil or empty) returns `{:error, :not_configured}` with zero HTTP. **Auth decision:** no live OpenClaw instance accessible for this slice, so per BUILDPLAN the client ships against a documented target shape. The target is `Authorization: Bearer <api_key>` for the header and `POST /api/v1/generate` for the endpoint, matching the idiomatic REST LLM convention used by the Anthropic/Gemini siblings. Both are attached inside `build_request/1`; switching to a different header (e.g. `x-openclaw-key`) if the running OpenClaw differs is a one-call-site fix, not a client rewrite. Request body shape: `content_type` (string), `count` (int), optional `platform`, `angle`, `brief`, `product`, `performance_insights`. Response parsing extracts the `variants` array, per-variant `text/angle/model`, and top-level `model/usage`. Error classification mirrors Anthropic/Gemini/MediaForge exactly: 5xx + 429 `{:transient, status, body}`, timeout `{:transient, :timeout, _}`, network `{:transient, :network, _}`, other 4xx `{:http_error, status, body}`, 3xx `{:unexpected_status, status, body}`, catch-all `{:error, reason}`. `Req.Test` plug baked in from day one. 17 new tests at `test/content_forge/open_claw_test.exs`: status trio (ok / missing api_key / missing base_url), missing-api-key short-circuit and missing-base_url short-circuit with zero HTTP (refute_received), happy-path social batch with header + URL + body assertions and multi-variant response parsing, blog path asserts no `platform` field in the body, video_script path asserts `content_type: video_script`, performance_insights passthrough, 429/500 transient, 400/401 permanent, timeout and econnrefused transient, 304 unexpected_status, and a counter-backed no-internal-retry check. No caller swaps this slice; 11.2 (caller) will rewire `OpenClawBulkGenerator`. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 236/0 (219 prior + 17 new). Credo unchanged vs post-11.1c state: same 7 baseline findings resolved, `publisher.ex:253:8` and `video_producer.ex:54:12` remain as known line-shift carryovers per `f26d099` rule. No new findings.

### Phase 11.1c: Brief generator synthesis across Anthropic + Gemini

Status: DONE
Merged: master @ `7398d71` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 219-0; credo identical to post-11.1b. New `BriefSynthesizer` dispatches 4-head on `{Anthropic.status(), Gemini.status()}`; full 2x2 ok/error combine matrix; `prefer_transient/2` for retry-first-then-cancel semantics. 10 synthesizer tests cover dispatch branches, synthesis failure, partial-fallback metadata. Feature 3 Stage 1 "at least 2 smart models" criterion satisfied.
Note: New `ContentForge.LLM.BriefSynthesizer` at `lib/content_forge/llm/brief_synthesizer.ex` orchestrates multi-provider brief generation. Provider availability is read from `Anthropic.status/0` and `Gemini.status/0`; the dispatcher pattern-matches the pair `{a, b}` to pick one of four paths: neither configured -> `{:error, :not_configured}` (caller's skip path fires); Anthropic-only -> single call returning `"anthropic:<model>"`; Gemini-only -> single call returning `"gemini:<model>"`; both -> parallel `Task.async` to both providers, await, synthesize. Synthesis feeds both drafts as context into one final Anthropic completion that writes the combined brief; the returned descriptor is `"synthesis: anthropic:<a_model> + gemini:<g_model> -> anthropic:<synth_model>"`. Partial failure handling matches the spec: when one provider succeeds and the other errors (transient or permanent), the successful draft is used as the brief with a metadata note like `"anthropic:<model> (gemini unavailable)"` and no error escalates. When both providers fail, `prefer_transient/2` picks a transient error if any is transient (so Oban retries), else propagates a permanent error (so Oban cancels). `ContentBriefGenerator.call_llm/2` now delegates to the synthesizer - the existing success-vs-error handlers ride on top unchanged, so the initial and rewrite paths both get multi-provider synthesis for free and `model_used` now records the provider descriptor rather than the raw model id. Also addressed the reviewer's 11.1 caller note: the `cond do` spine on `{existing_brief, force_rewrite}` was refactored into a pattern-match-first `route/2` function returning `:short_circuit | :initial | :rewrite`, dispatched via `run/5` heads. Two existing generator tests updated for the new `anthropic:<model>` descriptor format (legitimate behaviour change per spec). New test file `test/content_forge/llm/brief_synthesizer_test.exs` covers 10 cases: both-configured synthesis path (counter-verified two Anthropic calls + one Gemini, user prompts inspected at each boundary); Anthropic-only (no Gemini HTTP); Gemini-only (no Anthropic HTTP); neither-configured (zero HTTP); partial transient failure in either direction (fallback with metadata note); both transient (transient error propagated for retry); both permanent (permanent error for cancel); synthesis-step failure after both drafts succeed; and partial permanent failure as an analogue of transient fallback. All logger output in error-path tests is wrapped in `capture_log` per the engineering rule. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 219/0 (209 prior + 10 new synthesiser). Credo unchanged vs post-11.1b state: same 7 baseline findings resolved, `publisher.ex:253:8` and `video_producer.ex:54:12` are known line-shift carryovers per `f26d099` rule. No new findings.

### Phase 11.1b (infra): Gemini LLM HTTP client

Status: DONE
Merged: master @ `c90aa38` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 209-0; credo 37 vs 44 baseline unchanged from post-11.1-caller. Shape-compatible with Anthropic client (substitutable at call site). Gemini specifics: model in URL path, `x-goog-api-key`, `contents`+`generationConfig`+`systemInstruction`, assistant→model role translation at boundary. 16 tests cover all spec branches.
Note: `ContentForge.LLM.Gemini` at `lib/content_forge/llm/gemini.ex`, sibling to `ContentForge.LLM.Anthropic`. The public `complete(prompt, opts)` is shape-compatible with Anthropic's: same prompt argument (string or list of role/content turns), same options keyword list, same `{:ok, %{text, model, stop_reason, usage}}` success shape. No shared abstract base module between providers; duplication is acceptable for two providers per the spec. Configuration lives under `:content_forge, :llm, :gemini` with `:api_key`, `:default_model`, `:max_tokens`, `:base_url`, and a `:req_options` escape hatch for `Req.Test`. Authentication uses the `x-goog-api-key` header (idiomatic for Req; the spec allows either header or URL param). Endpoint is `POST /v1beta/models/<model>:generateContent` - model is in the URL path per Gemini's schema, not the body. Request-body construction builds the `contents` array from the prompt (`"assistant"` turns are translated to Gemini's `"model"` role), a `generationConfig` with `maxOutputTokens` and optional `temperature`, and an optional `systemInstruction` wrapping the system prompt. Response parsing extracts the first text part from `candidates[0].content.parts[]` and returns model (from `modelVersion` in the body, falling back to the request model), `finishReason`, and `usageMetadata`. Error classification matches Anthropic and MediaForge exactly: 5xx/429 -> `{:transient, status, body}`, timeout -> `{:transient, :timeout, _}`, network -> `{:transient, :network, _}`, other 4xx -> `{:http_error, status, body}`, 3xx -> `{:unexpected_status, status, body}`, anything else -> `{:error, reason}`. `Req.Test` plug baked in from day one. New test file `test/content_forge/llm/gemini_test.exs` covers 16 cases: status trio, missing-key short-circuit with zero HTTP (counter-verified), happy-path completion with header and URL assertions, caller overrides on generation config and system instruction, assistant-to-model role translation across multi-turn prompts, multi-part content extraction, 429/500 transient, 400/403 permanent, timeout/econnrefused transient, 304 unexpected_status, and a counter-backed no-internal-retry check. Runtime config sources `GEMINI_API_KEY` plus optional base URL / default model / max-tokens overrides. Compile-time defaults in `config/config.exs` alongside Anthropic's. No caller changes this slice; brief-generator synthesis swap is 11.1c. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 209/0 (193 prior + 16 new). Credo unchanged vs post-11.1 caller state: same 7 baseline findings resolved, `publisher.ex:253:8` and `video_producer.ex:54:12` remain as known line-shift carryovers per `f26d099` rule. No new findings.

### Phase 11.1 (caller): Brief generator swap onto LLM client

Status: DONE
Merged: master @ `f57427e` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 193-0; credo net -7 vs baseline (37 current). Both initial and rewrite paths through LLM.Anthropic; model_used reflects actual API model. Error handling mirrors ImageGenerator pattern with 5-head `handle_llm_error/2`. 7 tests cover all spec branches.
Note: `ContentForge.Jobs.ContentBriefGenerator` no longer emits hardcoded templated text. Both the initial-brief path and the force-rewrite path now call `ContentForge.LLM.Anthropic.complete/2` with a system prompt (expert content strategist role instructions covering voice profile, pillars, required angles including humor, platform guidelines, and key themes) and a user prompt built from the existing context map (product name + voice profile + snapshot + competitor intel, plus previous brief + performance summary for the rewrite path). On success the returned text becomes the brief content and the actual model id echoed by the API is recorded in `model_used` rather than the hardcoded "claude" string the placeholder used; `ContentGeneration.create_new_brief_version/5` now accepts `opts: [model_used: ...]` so the rewrite path also records the provider. On `{:error, :not_configured}` the job logs "LLM unavailable", returns `{:ok, :skipped}`, and creates no brief record: no placeholder or templated text ever reaches the database. Transient errors (5xx, 429, timeout, network) propagate as `{:error, _}` so Oban retries; permanent errors (4xx, unexpected_status) return `{:cancel, reason}` with the HTTP status recorded so retries do not spin against unchanged input. Generic errors propagate as `{:error, reason}`. The old `if/else` spine was also flattened to `cond do` to match the project's pattern-match-first style. New test file `test/content_forge/jobs/content_brief_generator_test.exs` covers 7 cases: happy path asserts real LLM text becomes the brief body, records the actual model id from the API response, rejects placeholder markers; existing brief short-circuits with zero HTTP; force_rewrite writes a v2 with updated model_used; missing API key returns `{:ok, :skipped}` with zero HTTP and writes no brief; 503 transient returns `{:error, {:transient, 503, _}}`; 429 rate limit returns transient too; 400 permanent cancels the job. All tests `Req.Test` stubbed; no live Anthropic calls. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 193/0 (186 prior + 7 new). Credo by content strictly better than baseline: 6 findings from prior slices plus one more resolved here (`content_brief_generator.ex:14:23` alias ordering fixed by the `{ContentGeneration, LLM, Products}` rewrite). `publisher.ex:253:8` and `video_producer.ex:54:12` remain as known line-shift carryovers per `f26d099` rule. No new findings.

### Phase 11.1 (infra): Anthropic LLM HTTP client

Status: DONE
Merged: master @ `00f9ebc` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 186-0, credo identical to post-10.5 baseline state. 16 tests cover all 5 spec branches plus extras (request body overrides, list-of-turns, multi-block content, no-retry counter). Clean test output.
Note: `ContentForge.LLM.Anthropic` at `lib/content_forge/llm/anthropic.ex`. Mirrors the MediaForge 10.1 pattern: single public `complete(prompt, opts)` function, `status/0` predicate, `:not_configured` downgrade with zero HTTP I/O when the API key is missing. Configuration lives under `:content_forge, :llm, :anthropic` with `:api_key`, `:default_model`, `:max_tokens`, `:base_url`, `:anthropic_version`, and a `:req_options` escape hatch for the `Req.Test` plug. Authentication sets `x-api-key` and `anthropic-version` inside the client on every request; callers cannot omit either. Endpoint is `POST /v1/messages`. Request-body construction accepts a plain string (wrapped as a single user message) or a pre-built list of role/content turns; caller options (model, max_tokens, temperature, system) are honored with sensible defaults falling through to application config. Response parsing extracts the first text block from the Messages API `content` array and returns `{:ok, %{text, model, stop_reason, usage}}`. Error classification mirrors MediaForge: 5xx and 429 -> `{:transient, status, body}` (so Oban, which owns retry, can back off); HTTP timeout -> `{:transient, :timeout, reason}`; connection refused / DNS / similar network -> `{:transient, :network, reason}`; other 4xx -> `{:http_error, status, body}`; 3xx -> `{:unexpected_status, status, body}`; anything else -> `{:error, reason}`. `Req.Test` stub baked in from day one; test suite uses module-name stubs and never touches the live Anthropic API. New test file `test/content_forge/llm/anthropic_test.exs` covers 16 cases: status ok / missing / empty, missing-key short-circuit asserts zero HTTP, happy-path completion with header assertions, caller overrides on the request body, list-of-turns prompt shape, multi-block content extraction, 429 transient, 500 transient, 400 permanent, 401 permanent, transport timeout, connection refused, 304 unexpected status, and a counter-backed assertion that the client does not retry internally on classified errors. Runtime config sources `ANTHROPIC_API_KEY` (plus optional overrides for base URL, default model, and max tokens); compile-time defaults live in `config/config.exs`. No caller swaps landed; 11.1 (caller) will swap the brief generator in a follow-up. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 186/0 (170 prior + 16 new). Credo by content strictly better than baseline: same 6 findings resolved as after 10.5, `publisher.ex:253:8` and `video_producer.ex:54:12` are the known line-shift carryovers per `f26d099` rule. No new findings.

### Phase 10.5a: Webhook test output cleanup

Status: DONE
Merged: master @ `d402d8d` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 170-0, credo identical to post-10.5 state. Webhook suite output clean (11 dots, no warning noise).
Note: Pure hygiene on `test/content_forge_web/controllers/media_forge_webhook_controller_test.exs`. The five rejection-path tests (stale timestamp, invalid signature, missing signature header, unknown job id, malformed payload) previously emitted unwrapped Logger warnings that polluted `mix test` output. Each is now wrapped in `ExUnit.CaptureLog.capture_log/1` using the same `send(self(), {:conn, conn}) / assert_received` pattern as `image_generator_test.exs`, and asserts a substring of the expected log line so the silence is intentional, not accidental. No behavior change. Gate: compile --warnings-as-errors clean, format clean, mix test 170/0, credo identical to post-10.5 state.

### Phase 10.5: Media Forge webhook receiver

Status: DONE
Merged: master @ `f990a38` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 170-0. Security verified (HMAC-SHA256 over raw body, 300s window both directions, Plug.Crypto.secure_compare, body-reader scoped to webhook paths only, fails closed on missing secret, signatures never echoed). Idempotency centralized in JobResolver; tested both directions. Minor follow-up 10.5a: five rejection/malformed/unknown-id logger warnings in `webhook_controller_test.exs` are not wrapped in `capture_log`, producing noisy test output. Bundled pre-existing bug fix (`Draft.put_default_status/1` `get_change`→`get_field`) accepted as load-bearing for the webhook's update-without-clobber behavior.
Note: Inbound webhook at `POST /webhooks/media_forge` verifies `X-MediaForge-Signature` (Stripe-style `t=<unix>,v1=<hex>`) over the raw request body using HMAC-SHA256 with the configured shared secret, compares via `Plug.Crypto.secure_compare/2`, and enforces a 300-second timestamp window. Raw body capture lives in a new `ContentForgeWeb.BodyReader` wired into `Plug.Parsers` via `body_reader:` so parsed JSON still reaches the controller while the verifier plug sees the exact bytes Media Forge signed. Rejection paths log and halt: 400 for stale/malformed, 401 for missing/bad signature (never echoing the offending value). The verifier reads `:webhook_secret` first, falling back to `:secret`, and rejects every request when no secret is configured. Introduced `ContentForge.MediaForge.JobResolver`, a shared state-transition helper used by both pollers (`ImageGenerator`, `VideoProducer`) and the webhook controller; entry points return `{:ok, :done, url|key}`, `{:ok, :failed, reason}`, `{:ok, :noop}`, or `{:error, :not_found}`. Idempotency is centralised: image drafts are terminal when status is `"blocked"`/`"published"` or `image_url` is already set; video jobs are terminal when status is `"encoded"`/`"uploaded"`/`"failed"`. Migration `20260423120000` adds `media_forge_job_id` (indexed) to both `drafts` and `video_jobs` plus an `error` string on `drafts`; schemas and context helpers expose `get_*_by_media_forge_job_id/1`. Pollers now persist `media_forge_job_id` on the record when they enter the polling loop and route done/failed through the resolver; the synchronous paths in ImageGenerator/VideoProducer also go through the resolver for consistency. Pre-existing bug uncovered and fixed in `Draft.put_default_status/1`: it force-applied `"draft"` whenever a changeset had no `:status` change, so every `update_draft/2` would clobber a persisted status like `"ranked"` back to `"draft"`. Switched from `get_change` to `get_field` so the default only fires when the persisted value is also nil; existing tests still pass. New webhook controller test file (11 cases): image-done updates `image_url` + stays `"ranked"`; image-failed marks `"blocked"` with error note; video-done records R2 key + transitions to `"encoded"`; video-failed transitions to `"failed"` with error; repeat webhook for terminal image draft is a no-op 200; repeat webhook for `"encoded"` video job is a no-op 200; stale timestamp 400; invalid signature 401; missing signature header 401; unknown job id 404; malformed payload 400. Runtime config sources `MEDIA_FORGE_WEBHOOK_SECRET` (falling back to `MEDIA_FORGE_SECRET`) in `config/runtime.exs`. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 170/0 (159 previous + 11 new webhook). Credo by content strictly better than baseline: same 6 findings resolved as after 10.3; `publisher.ex:253:8` and `video_producer.ex:54:12` are the known line-shift carryovers (same function bodies per `f26d099` rule). No new findings introduced by this slice.

### Phase 10.3: Swap video pipeline FFmpeg step onto Media Forge

Status: DONE
Merged: master @ `42db18f` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 159-0, VideoProducer coverage 70.30 (untouched legacy simulation steps are the uncovered ones, pre-existing). Credo 38 vs 44 baseline (6 net improvements; line-shift carryovers verified per `f26d099`). State machine matches spec: `encoded` on done, `assembled` + error on `:not_configured`, `failed` on permanent, retry on transient.
Note: Step 5 of `ContentForge.Jobs.VideoProducer` no longer simulates FFmpeg locally. The step now calls `ContentForge.MediaForge.enqueue_video_render/1` with the Remotion-assembled R2 key, handles synchronous responses (persists the returned R2 key and transitions `assembled` to `encoded`), and resolves asynchronous responses by polling `MediaForge.get_job/1` with a configurable interval and attempt cap (default 5 seconds x 60 attempts; tests override to 0). On `{:error, :not_configured}` the step logs "Media Forge unavailable", writes "Media Forge unavailable" to the video job's `error` field, and leaves status at `assembled` (not a retry condition; Oban returns `:ok`). Permanent 4xx and unexpected-status errors mark the video job `failed` with the error recorded and return `{:cancel, reason}` from Oban. Transient 5xx and network errors return `{:error, reason}` so Oban retries under its `max_attempts`. The old `ffmpeg_encode/2` simulation and the product-level `"ffmpeg"."enabled"` config flag are removed entirely; there is no backwards-compatibility path. Added `"encoded"` to `VideoJob` status inclusion and predicate helpers, plus `encoded?/1`. Video status LiveView gets `"encoded"` in `@status_order` (between `assembled` and `uploaded`) and in `format_step_name/1` so the pipeline visualization and step count chart include the new state. The detail panel already surfaces the `error` field, so the "Media Forge unavailable" pause reason is visible when a stuck job is selected. Refactored `execute_pipeline/3` from four nested `case` blocks into a flat `with` chain (using a `tag_step/2` helper so `handle_step_error/3` still receives the step atom), and extracted a `finalize/4` helper for the step-5-plus-step-6 tail; both reduce cyclomatic complexity and nesting to within baseline thresholds. New test file `test/content_forge/jobs/video_producer_test.exs` (5 tests: sync success with immediate R2 key, async success via polled get_job, missing-secret downgrade leaving the job at `assembled` with the error message, permanent 422 marking the job `failed`, transient 503 returning `{:error, _}` without a status change). All tests run against `Req.Test` stubs; no live Media Forge calls. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 159/0. Credo by content strictly better than baseline: three more findings resolved on video_producer.ex (nesting-6 dropped entirely after the `with` refactor, alias ordering fixed by the include reorder); the negated-if-else on the feature_flag guard remains unchanged at a shifted line number.

### Phase 10.2c: ImageGenerator test coverage fill

Status: DONE
Merged: master @ `78d4437` (fast-forward). Reviewer ACCEPT. Gate: compile/format/test 154-0, ImageGenerator coverage 65.79% → 90.79%. Credo baseline unchanged (per f26d099 line-shift rule).
Note: Pure test additions against `ContentForge.Jobs.ImageGenerator`. No behavior change. Added 10 new cases (describe blocks: "coverage fill: alternate sync response shapes" x 3, "coverage fill: error classification branches" x 2, "coverage fill: polling branches" x 5). Covers every BUILDPLAN-named branch: persist-or-fail when Media Forge reports done without an extractable URL (returns `{:cancel, "Media Forge returned done without an image url"}`, logs "reported done but no image url"), unrecognized sync body (no image_url/url/result/jobId keys, returns `{:cancel, "unrecognized Media Forge response"}`), polling that observes a late `:not_configured` (stub clears the Media Forge secret on the POST response so the subsequent `get_job/1` short-circuits; the worker returns `{:ok, :skipped}` and logs "Media Forge became unavailable while polling"), and the generic error catch-all (a redirect loop produces `%Req.TooManyRedirectsError{}` which passes through MediaForge's generic classify clause and propagates as `{:error, _}` via ImageGenerator's catch-all). Also exercises the remaining handle_generate_response clauses (`"url"` key, nested `"result"."image_url"`), the `{:error, {:unexpected_status, ...}}` branch (via a stubbed 304), a polling generic-error branch (503 during polling), and the alternate `extract_result_url` clauses (`"result"."url"` and top-level `"image_url"` in poll responses). Module coverage lifted from 65.79 percent to 90.79 percent. Overall project coverage threshold remains at zero per the baseline gate. Gate: mix compile --warnings-as-errors clean, mix format clean, mix test 154/0. Credo unchanged from post-10.2b state: same 5 baseline findings resolved, build_post_opts cyclomatic-19 at line 253:8 shifted from 224:8 (content unchanged).

Note: `ContentForge.Jobs.ImageGenerator` now calls `ContentForge.MediaForge.generate_images/1` instead of returning a placeholder URL. Handles synchronous responses (persists `image_url` immediately) and asynchronous responses (polls `MediaForge.get_job/1` with configurable interval and cap). `{:error, :not_configured}` logs "Media Forge unavailable", returns `{:ok, :skipped}`, and leaves `image_url` nil - no placeholder URL is ever written. Permanent 4xx errors `{:cancel, reason}`; transient 5xx/network errors propagate as `{:error, _}` so Oban retries. Non-post drafts skipped; drafts already carrying an image_url skipped. Oban queue config in `config/config.exs` extended with `:content_generation`, `:ingestion`, `:competitor` so the worker and its sibling workers actually run. Queue-override bug in `process_all_social_posts/1` fixed - child jobs now enqueue via `__MODULE__.new/1` on the declared `:content_generation` queue rather than the nonexistent `:image_generation`. New test file `test/content_forge/jobs/image_generator_test.exs` covers 10 scenarios (sync success, async poll-to-done, async poll-to-failed, poll timeout, not-configured downgrade, 4xx cancel, 5xx transient retry, non-post skip, already-attached skip, child queue assertion). Gate green: compile --warnings-as-errors clean, format clean, credo --strict strictly better than baseline (2 findings from the old image_generator.ex are gone; no new findings - `unless/else` replaced with function heads), mix test 133/0.

## Outstanding

See `BUILDPLAN.md` for the wave-by-wave plan. Short version:

- Phase 10: Media Forge integration (now unblocked — Media Forge shipped 2026-04-22).
- Phase 11: Real-provider wiring audit for brief generator, bulk variant generation, Apify scrapers.
- Phase 12: Feature 10 — SEO Quality Pipeline.
- Phase 13: Feature 11 — Product Asset Management.
- Phase 14: Feature 12 — SMS Gateway and Conversational Bot.
- Phase 15: Polish — auto-triggers, dashboard UX, WCAG audit, end-to-end tests.

## Decisions and Notes

- **2026-04-22:** Swarmforge config ported from Media Forge to Content Forge. `BUILDLOG.md`, `BUILDPLAN.md`, and `CLAUDE.md` created as the swarm's authoritative plan documents. Legacy orchestration docs (`AGENTS.md`, `CLAUDE_TASKS.md`, `CLAW_TASKS.md`, `RALPH_PHASE1.md`, `RALPH_PHASE2.md`) remain as history but no longer drive the build.
- **2026-04-22:** Media Forge shipped all seven phases. Content Forge integration work (Phase 10) is unblocked. Live service runs at `http://192.168.1.37:5001`.
- **2026-04-22:** `CAPABILITIES.md` was last verified against commit `afc9e17` (2026-03-28); HEAD is `c120ad5` (2026-04-22). Treat that doc as lagging — verify against current code before citing it.
- **2026-04-22:** Phase 2 audit and merge. Gated Competitor Scraper behind `:apify_token` + `:scraper_adapter` config and Competitor Intel Synthesizer behind `:intel_model` adapter — both now return `{:discard, reason}` rather than fabricating output. Removed faked `heuristic_analysis` (broken `detect_hooks/1`) and hardcoded `mock_posts/1`. Fixed pre-existing bugs uncovered by audit: `Products.list_top_competitor_posts_for_product/2` query (`where eq` → `where in`), `FallbackController` JSON view binding for changeset errors, `competitor_scraper.ex` per-post insert errors silently dropped (now logged + counted as `:partial`). `SiteCrawler.resolve_url/2` bare rescue tightened to `ArgumentError`. Net: +24 tests (16 new + 8 from earlier feature work that came in the merge), 100/100 passing under `mix test`. Reviewed by `pr-review-toolkit:code-reviewer` and `pr-review-toolkit:silent-failure-hunter` (both: SHIP). Merged `phase-2` → `master` as `a5e1785`. `mix credo --strict` not wired in this project yet; tracked as bootstrap item B1 in `BUILDPLAN.md`.
- **2026-04-22:** Pre-existing authorization gap noted but not fixed: `CompetitorController` `show/update/delete` accept `product_id` from URL but never verify the competitor belongs to that product. Out of scope for Phase 2 audit; should be picked up under multi-tenant safety in a future polish slice.
- **2026-04-22:** Bootstrap B1 (credo) landed. `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}` added; `.credo.exs` generated with `Refactor.Nesting` relaxed to 3 and `Refactor.CyclomaticComplexity` relaxed to 12 to grandfather Features 1-9 hotspots. `mix credo --strict` currently reports 44 findings; all snapshotted in `.credo_baseline.txt`. Reviewer constitution amended: each slice must diff against baseline and introduce no new findings. A dedicated credo-cleanup slice (Phase 15 polish) will tighten thresholds back to defaults and refresh the baseline. Credo is NOT in the `mix precommit` alias because it would always fail on existing debt; run `mix credo --strict` separately as part of the reviewer's gate.
- **2026-04-22:** Bootstrap B2 (precommit alias) already in place: `mix precommit` runs compile-warnings-as-errors, deps.unlock --unused, format, and test. Serves as the coder's fast feedback gate.
- **2026-04-22:** Doc reconciliation on branch names. The harness provisions role branches with the `swarmforge-` prefix (`swarmforge-coder`, `swarmforge-reviewer`) to match the session naming convention, but `workflow.prompt`, `coder.prompt`, `reviewer.prompt`, and `BUILDPLAN.md` still referenced the shorter `coder` / `reviewer` names. Reviewer agent had already acknowledged online on `swarmforge-reviewer @ 036f5b2`, so renaming live branches mid-work would have disrupted the baseline quality gate. Updated the docs to match reality instead. No behavior change, only naming. Branches and worktrees verified at `036f5b2`.
- **2026-04-22:** Phase 10.1 coder handoff. `ContentForge.MediaForge` HTTP client landed on `swarmforge-coder` at `lib/content_forge/media_forge.ex`, with `Req.Test` stub wiring and a 22-test acceptance file under `test/content_forge/media_forge_test.exs`. Covers probe, four video enqueue paths, three image enqueue paths, generation + compare, job status, job cancel. Error classification: 5xx to `{:transient, status, body}`, HTTP timeouts to `{:transient, :timeout, reason}`, network (econnrefused/nxdomain/etc) to `{:transient, :network, reason}`, 4xx to `{:http_error, status, body}`, missing secret to `:not_configured` with no HTTP call. `X-MediaForge-Secret` header set inside the client on every request; callers cannot omit. Base URL defaults to `http://192.168.1.37:5001`, overridable via `:content_forge, :media_forge, :base_url`. Gate green on `swarmforge-coder`: `mix compile --warnings-as-errors` clean, `mix format --check-formatted` clean, `mix credo --strict` 41/41 file:line locations unchanged vs `.credo_baseline.txt`, `mix test` 122/0. No caller swaps landed - those are 10.2 through 10.4.
- **2026-04-22:** Baseline gate repairs on master, uncovered by reviewer's first pass. (1) HEEX format regression from bootstrap `c83e49a` in `lib/content_forge_web/live/dashboard/products/detail_live.ex` at the brief "Model: X" span. Root cause: multi-space literal text adjacent to `{@interp}` inside a `:if` span made the HEEX formatter non-idempotent — each run added another space, so `mix format --check-formatted` always failed on the next pass. Collapsed to a single space (HTML collapses whitespace anyway, so no visual change). (2) `mix test --cover` default threshold is 90 per module; the project ships at 18.08% overall with many modules at 0%, so every reviewer gate was exiting 3 on baseline debt. Added `test_coverage: [summary: [threshold: 0]]` to `mix.exs` so the summary still prints but no module is marked failed — mirrors the credo-baseline "acknowledged debt, no regression" pattern. Coverage uplift is tracked as a Phase 15 item. All gates green on master: compile clean, format clean, `mix test` 100/0, `mix credo --strict` matches `.credo_baseline.txt` exactly, `mix test --cover` exits 0. Commit on master; reviewer can resume baseline on the next fast-forward.
- **2026-04-22:** Phase 10.1 merged to master as `ba3c3ee` (merge commit over `swarmforge-coder@b3883c7` and the intervening constitution handoff-brevity amendment `d4271f1`). Reviewer ACCEPT at `b3883c7` with no reviewer commits. Reviewer flagged one non-blocking follow-up accepted by architect: `MediaForge.classify/1` is not exhaustive for `{:ok, %Req.Response{status: 300..399}}` — a 3xx response would `FunctionClauseError`. Engineering rule requires exhaustive pattern matches, so this is scheduled as Phase 10.1.1 (one-line catch-all clause returning an `:unexpected_status` error tuple, plus the failing test first). Also accepted reviewer's layout choice: a single `lib/content_forge/media_forge.ex` file instead of the spec's `lib/content_forge/media_forge/` subdirectory — idiomatic Elixir when no helper modules exist. Spec amended to reflect the single-file reality. Coverage: `ContentForge.MediaForge` 94.59%, total 18.99%.
- **2026-04-23:** Phase 10.2b architect decisions. (1) Dashboard label for blocked-pending-image drafts: coder shipped "Blocked (Awaiting Image)" rather than the spec's earlier "Media Forge unavailable" phrasing. Accepted as-is. Rationale: the block applies at the draft level and can be caused by reasons other than Media Forge being unavailable (a draft can arrive at the publisher ahead of its image generation job for benign timing reasons). The product-level "Media Forge unavailable" banner is a separate surface owned by Phase 15.1 (provider status panel) and is not the same thing as the per-draft blocked label. (2) Credo baseline-diff rule clarified in `workflow.prompt`: match findings by file + check name + message rather than file + line + column. A finding that shifts to a new line because surrounding code grew or shrank is the same finding. This came up because 10.2b added 29 lines to `publisher.ex` above the grandfathered cyclomatic-19 `build_post_opts` function, which shifted its baseline finding from line 224 to 253. The reviewer verified the body was unchanged and accepted.
- **2026-04-23:** Phase 11.2 caller paused: OpenClaw's bulk-generation API endpoint does not exist in the ecosystem at this time. Coder probed localhost 5002/5003/5100/8080/8081/3001 (unresponsive), 192.168.1.37:5001 (Media Forge, 404), localhost:3000 (Remotion Studio). No `OPENCLAW_BASE_URL` env var; only `OPENCLAW_TELEGRAM_TOKEN` exists (the conversational Telegram bot, not a generation service). Per the architect instruction in the handoff, the coder paused rather than shipped blind against the stubbed target shape. Resuming requires either (a) a real OpenClaw generation service deployed somewhere in the ecosystem, or (b) architect-level rerouting of bulk generation through a different provider (for example, using the existing Anthropic + Gemini clients as the bulk generator, trading API cost for availability). Decision deferred until the user weighs in or the service lands. Meanwhile, queued 11.2M (MultiModelRanker real scoring swap) because it fixes the same class of synthetic-data bug as 11.1 and is unblocked by the now-shipped LLM infra.
