# Content Forge MCP Server Runbook

Phase 17.3 ships `ContentForgeMCP.Server`, a SimpleMCP-based
server exposing the research-loop operations a Claude Code
session needs to walk the corpus-of-record loop without
touching the LiveView dashboard.

## What ships in 17.3

- `lib/content_forge_mcp/server.ex` - the SimpleMCP server
  module with nine tools, all routing through the existing
  `ContentForge.Products` / `ContentForge.Jobs.*` context
  modules. Behavior stays consistent with the dashboard.
- `lib/content_forge_mcp/stdio_server.ex` - the stdio transport
  wrapper. JSON-RPC requests on stdin, responses on stdout.
  Errors render as JSON envelopes (no `Error: ` prefix).
- `priv/repo/migrations/20260511120000_*` - pre-empts Phase
  17.4's schema change so `cf_store_intel` can persist
  `audience_signals` + `window` honestly.

## Tool catalogue

| Tool | Purpose |
|------|---------|
| `cf_create_product` | mint a product |
| `cf_list_products` | product index with competitor + intel counts |
| `cf_add_competitor` | register a competitor account on a product |
| `cf_list_competitors` | per-product competitor index |
| `cf_scrape_competitor` | enqueue Oban scrape (async) |
| `cf_top_posts_for_synthesis` | top N posts + comments by window |
| `cf_store_intel` | persist a manual synthesis (without-key path) |
| `cf_get_intel` | latest competitor intel or last five |
| `cf_list_pending_syntheses` | without-key route's pending queue (17.4) |
| `cf_import_twitter_sqlite` | sqlite backfill (posts + comments) via the standalone scraper's `tweets` + `comments` tables (17.5) |

Every tool returns either a structured success map or a
`%{code, message, details}` error envelope. Standard codes:
`not_found`, `unauthorized`, `not_configured`,
`validation_failed`, `dependency_error`, `not_implemented`.

## Run the stdio server by hand

The simplest way to drive the server locally for debugging:

```bash
cd ~/projects/contentforge_ecosystem/content-forge
MIX_ENV=dev mix run --no-halt -e 'ContentForgeMCP.StdioServer.start()'
```

The server reads JSON-RPC on stdin and writes responses on
stdout; stderr carries the boot message and any logs. Pipe
hand-crafted requests in to smoke-test:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | \
  MIX_ENV=dev mix run --no-halt -e 'ContentForgeMCP.StdioServer.start()'
```

## Register with Claude Code

Add the server to your Claude Code MCP configuration
(typically `~/Library/Application Support/Claude/claude_desktop_config.json`
on macOS):

```json
{
  "mcpServers": {
    "content-forge": {
      "command": "mix",
      "args": ["run", "--no-halt", "-e", "ContentForgeMCP.StdioServer.start()"],
      "cwd": "/Users/sales_king/projects/contentforge_ecosystem/content-forge",
      "env": {
        "MIX_ENV": "dev",
        "PATH": "/Users/sales_king/.asdf/shims:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      }
    }
  }
}
```

Restart the Claude Code session; `content-forge` should
appear in the MCP tool inventory alongside whatever else you
have registered (lead_intelligence, etc.).

## Verify

Open a Claude Code session, list tools (the protocol's
`tools/list` request), and confirm all nine `cf_*` entries
show. Then walk the round-trip from the spec:

1. `cf_create_product { "name": "TestProduct" }` -> note the
   `product_id`.
2. `cf_add_competitor { "product_id": "...", "platform":
   "twitter", "handle": "rival" }` -> note the `competitor_id`.
3. `cf_scrape_competitor { "competitor_id": "..." }` -> the
   Oban CompetitorScraper job enqueues; results land in
   `competitor_posts` asynchronously.
4. After a scrape completes: `cf_top_posts_for_synthesis {
   "product_id": "...", "n": 5, "window": "week" }` -> read
   the posts + their captured comments.
5. `cf_store_intel { ... }` -> persist a manual synthesis with
   `audience_signals` populated from the comments you just
   read.
6. `cf_get_intel { "product_id": "..." }` -> read it back.

Any step that needs a missing dependency (no `APIFY_TOKEN`, no
product yet, etc.) returns the structured error envelope
rather than crashing the stdio process.

## Why a separate stdio server (not Phoenix)

The dashboard runs as a launchd-managed Phoenix on
`localhost:4000` (Phase 17.0). The MCP server runs as a Claude
Code subprocess, started fresh per session. They share the
same DB and the same context modules so the corpus stays
consistent, but the two transports never collide on a port:
the stdio server disables the Phoenix endpoint at start time.

## Why the without-key fallback path matters

When `ANTHROPIC_API_KEY` is absent (Phase 17.2 made this an
adapter-layer downgrade rather than a discard), the Phase 17.4
synthesizer inserts a `pending_intel_syntheses` row referencing
the source posts and `:discard`s the Oban job (no retries
against a permanent misconfiguration). A Claude Code session:

1. Calls `cf_list_pending_syntheses { "product_id": "..." }`
   to find work to do.
2. For each pending row, calls `cf_top_posts_for_synthesis`
   with the matching product + window to read the bundle
   (post bodies + comment threads).
3. Reasons through the synthesis by hand and calls
   `cf_store_intel` with the same row shape the autonomous
   path would produce - including the new `audience_signals`
   that the with-key prompt asks the LLM to extract from the
   comment thread.
4. `cf_store_intel` resolves (deletes) any pending rows for
   the matching `(product_id, window)` so the queue stays
   bounded.

The corrective loop (17.6) treats both paths identically.

## Updating the server

The MCP server reads from the same context modules the
dashboard uses; behavior changes when the contexts change.
Adding a new tool means:

1. Append a `SimpleMCP.Tool.new(...)` block in `tools/0`.
2. Add a `handle_tool_call("name", args)` clause routing to a
   private handler.
3. Add a happy-path test + a missing-dependency test in
   `test/content_forge_mcp/server_test.exs`.
4. Update this runbook's tool catalogue table.

The `tools/0` registry is the source of truth; the dispatch
clause + the handler must agree with it (the
`registers exactly the nine documented tools` test catches
drift).
