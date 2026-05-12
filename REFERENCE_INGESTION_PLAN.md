# Reference Ingestion — Build Plan

Draft proposal for a new ContentForge feature: a cross-product **Reference Library** populated by an **Ingestion Pipeline** that handles external content (text, docs, PDFs, YouTube, podcasts, video files, Google Drive folders) and turns it into searchable reference material the content brief and OC generation can pull from.

This plan is plain English only — no code — to match `BUILDPLAN.md` conventions. Status: not yet sliced into the live build plan; awaiting review before insertion.

## Why this exists

The product spec already covers two kinds of context:

- **Voice profile** — per product, defines tone and style for that product's content.
- **Competitor intel** — per product, auto-scraped from a configured competitor account list, surfaces what's currently working in that niche.

Neither concept covers **evergreen, cross-product reference material**: proven hook frameworks, copywriting prompts, transcripts of masterclasses the operator has paid for, third-party teardown threads, books, podcasts, anything the operator wants to inform every product's content output rather than just one product's.

Right now, that material lives outside the system (Google Drive, YouTube, PDFs on disk). The brief generator and OC see none of it. This plan brings it in once and lets every brief rewrite reference it.

## Why "ingestion" is the framing

Because the operator never wants to retype someone else's content. The system has to accept a URL, a Drive folder, a podcast RSS feed, or an uploaded file — and figure out how to parse it. For audio and video, that means transcribing it. For Google Docs, that means exporting the text. For PDFs, that means extracting it. The ingestion pipeline is the surface that makes "drop a link, get reference material" work for any source the operator brings.

The first concrete payload is the School of Hard Knocks bonus folder (3 docs already saved as seed data under `priv/seeds/references/school_of_hard_knocks/`, plus 13 videos totalling ≈21 GB still sitting in Drive). The plan must handle that batch on day one — and generalize to any future source the operator subscribes to.

## What the feature delivers

- A new **reference_library** concept: tagged, categorized, searchable reference documents that are not tied to a specific product.
- An **ingestion pipeline** that accepts a source descriptor (URL, file upload, Drive folder ID, YouTube URL, podcast RSS, raw file path) and produces one or more reference documents.
- A **transcription step** for audio and video sources that uses local whisper (free, runs on the M-series Mac) by default, with a hook for a paid provider later if throughput becomes a problem.
- **Brief generator awareness**: the brief rewrite step receives the most relevant references for the product (matched by tag, category, or full-text search) so the brief can cite specific frameworks rather than reinventing them.
- A **tiny admin surface**: list, view, tag, retire references. No fancy UI — just enough to curate.

## What this feature deliberately does NOT do (yet)

- Vector embeddings / semantic search. Postgres full-text + tags is enough for the volume the operator will realistically curate (hundreds of references, not millions). Defer until search quality actually limits the brief.
- Re-running brief rewrites every time a reference is added. References are passive context; existing rewrite triggers are sufficient.
- Auto-discovering new references (RSS auto-pull, channel monitoring). Day one is "operator drops a link, system ingests." Discovery can come later.

## Phase structure (proposed)

The phase below is sized so each slice fits a single architect → coder → reviewer loop in the swarmforge flow. Each slice ships green before the next one starts. The transcription slice is ordered early because the operator already has paid video content waiting on it.

### Phase 17 — Reference Library and Ingestion Pipeline

**Why now:** Every brief rewrite that runs without this pipeline ignores reference material the operator has already paid for. Shipping this lifts the ceiling on every existing feature instead of adding a parallel one.

**Slice 17.1 — Reference schema and context module.**
Introduce reference sources (where the material came from), reference documents (one ingested artifact, with title, body, source pointer, ingested-at timestamp), and reference tags. Add a context module exposing the standard CRUD plus a "find references for product X with tag Y" query. Migration includes Postgres full-text indexing on document body. No ingestion logic yet; documents can only be created directly in tests.

**Slice 17.2 — Local file ingest path.**
Operator drops a markdown or plain-text file into a watched directory or uploads it via API; the pipeline creates a reference source and one reference document. This slice exists primarily to lock down the pipeline contract (source → document) using the cheapest possible source type. The 3 already-saved School of Hard Knocks docs are the test fixtures.

**Slice 17.3 — Google Drive folder ingest.**
Operator submits a Drive folder ID; the pipeline lists files in the folder, classifies each by MIME type, and dispatches per-file ingestion jobs. Google Docs export to markdown via the Drive API. Other file types queue for later slices and are recorded as "pending" reference documents so the operator can see what's coming. Auth uses a service account credential stored in the existing api_keys table or its successor.

**Slice 17.4 — PDF ingest.**
Pulls in any PDF reference (Drive-sourced or directly uploaded), extracts text, creates a reference document. Use a maintained Elixir or Erlang PDF text extractor; if none is solid enough, shell to `pdftotext` from the host. Test fixtures: a real PDF the operator selects.

**Slice 17.5 — Audio/video transcription via local whisper.**
For any source whose MIME type is audio or video, the pipeline downloads the file (Drive API for Drive sources, direct download for URL sources), invokes whisper locally on the M-series Mac, and stores the transcript as the reference document body. Source descriptor preserves the original file pointer so the operator can re-listen. Defaults to whisper's `base` or `small` model for speed; configurable per source. Job is async and chunked so a 4 GB video does not block other ingestion. Acceptance: the 13 School of Hard Knocks videos are queued, processed overnight, and become searchable references the next morning.

**Slice 17.6 — YouTube URL ingest.**
Operator submits a YouTube URL; the pipeline downloads with `yt-dlp`, then routes to the same transcription path as 17.5. Captions, when available, are preferred over re-transcription to save time and accuracy. Channel-level subscriptions are out of scope for this slice.

**Slice 17.7 — Tagging and categorization.**
Operator can tag references at ingest time or after the fact. A small set of system categories is seeded — hook framework, prompt template, transcript, article, framework — and references default to "uncategorized" so nothing slips through silently. Optional: a smart model is asked to suggest tags on first ingest; the operator confirms.

**Slice 17.8 — Brief generator integration.**
The brief rewrite job receives, for each product, the top-matching references by tag and full-text relevance against the product snapshot and recent performance scoreboard. The rewrite prompt explicitly invites the smart model to cite reference material when it changes a recommendation ("based on hook framework X from reference Y, switch to before/after format"). Hard cap on injected reference text per brief to keep prompt cost predictable.

**Slice 17.9 — Admin UI.**
A LiveView page under the existing dashboard listing references with title, source, tags, ingest date, and a body preview. Filters by tag and category. Actions: edit tags, retire, re-ingest from source. No write API beyond what the dashboard needs; the API surface for references stays read-only until a real third-party client asks for write access.

**Slice 17.10 — Re-ingest job.**
For any reference whose source supports it (Drive doc, YouTube video with new captions, RSS-fetched article), the operator can trigger a re-ingest that updates the document body in place and bumps an `ingested_at` timestamp. This closes the loop on "the source got updated; pull the new version" without scheduling background re-ingestion that the operator did not ask for.

**Phase exit criteria:** the 3 School of Hard Knocks docs and 13 videos are all visible in the admin UI as searchable references; at least one product's brief rewrite cites a specific framework from the library; the pipeline accepts at least the four source types (file upload, Drive folder, PDF, YouTube URL) without code changes per source.

## Slices that explicitly belong to a future phase

- **Smart-model auto-summarization** of long transcripts so the brief receives a tight digest rather than a full 2-hour transcript. Helpful, but the brief's prompt cap can handle full short docs and excerpted long ones for now.
- **Embeddings + pgvector** for semantic search across references. Worth doing once the library passes ~500 documents or relevance complaints surface in brief rewrites.
- **Channel/feed subscriptions** that pull new content automatically (YouTube channel watcher, podcast RSS poller). Day-one operator behavior is manual drops; automation only after that path proves durable.
- **Reference attribution in published posts.** When a draft is generated using a specific reference, link the published post to the references that influenced it, mirroring the asset attribution trail in Feature 11.

## Risks and decisions to nail down before architect handoff

- **Whisper model choice.** `base` is fast and 80% good; `small` adds accuracy at ~3x time. The operator's pain threshold determines this, not the architect's.
- **Storage location for transcripts.** Inline in the database is fine through the low thousands of documents. R2 with a DB pointer is needed once any single reference body crosses a few megabytes (long video transcripts will).
- **Drive auth model.** Service account vs OAuth. Service account is simpler for one-operator use; OAuth is required if the system ever ingests on behalf of other users. Service account is the right choice today.
- **Reference scope (global vs per-product).** This plan assumes global with optional per-product tagging. If the operator ever has reference material that legally cannot mix products (licensed material per client, for example), a `product_id` column with `null = global` becomes necessary. Add the column from day one to avoid a migration.
- **Coexistence with `competitor_intel`.** Both concepts surface "what's working" — but competitor intel is per-product, automatic, and stale-by-design. References are evergreen and human-curated. They are additive; the brief rewrite prompt should pull from both, clearly labeled.
