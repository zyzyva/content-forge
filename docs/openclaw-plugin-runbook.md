# OpenClaw `content-forge` Plugin Runbook

Phase 16.1 ships the Content Forge OpenClaw plugin at
`~/.openclaw/plugins/content-forge/` and the matching HTTP tool
surface at `POST /api/v1/openclaw/tools/:tool_name` on the
Phoenix app.

This runbook walks an operator through registering the plugin
with the local OpenClaw gateway and verifying an end-to-end
tool call against a running Content Forge instance.

## Prerequisites

- OpenClaw gateway running locally (default `localhost:18789`).
- Content Forge running on `localhost:4000` (`mix phx.server`).
- At least one product seeded in the Content Forge DB.

## 1. Set the shared secret on the Content Forge side

The controller fails closed on a missing or mismatched
`X-OpenClaw-Tool-Secret` header. Pick a strong value (32+
random bytes, base64-encoded is fine):

```bash
openssl rand -base64 48
```

Export it for the running app or set in `config/runtime.exs`:

```elixir
# config/runtime.exs (for prod / staging)
config :content_forge,
  open_claw_tool_secret: System.get_env("OPENCLAW_TOOL_SECRET")
```

For dev, export before launching:

```bash
export OPENCLAW_TOOL_SECRET="<the-secret-you-just-generated>"
MIX_ENV=dev iex -S mix phx.server
```

Verify it's loaded:

```elixir
iex> Application.get_env(:content_forge, :open_claw_tool_secret)
"<the-secret>"
```

## 2. Configure the plugin with the same secret

The plugin reads its config from the OpenClaw gateway's config
file (usually `~/.openclaw/config.json`). Add a `plugins`
section:

```json
{
  "plugins": {
    "entries": {
      "content-forge": {
        "baseUrl": "http://localhost:4000/api/v1/openclaw",
        "toolSecret": "<the-same-secret>"
      }
    }
  }
}
```

The `baseUrl` default is `http://localhost:4000/api/v1/openclaw`
so it's only needed for non-default ports. `toolSecret` is
required; without it the plugin still registers tools but every
invocation will 401 (the plugin logs a warning at startup).

## 3. Restart the OpenClaw gateway

```bash
# Example for the homebrew install path; adjust if yours differs.
pkill -f openclaw-gateway || true
/opt/homebrew/bin/openclaw gateway &
```

At startup the gateway scans `~/.openclaw/plugins/*`, loads the
`content-forge` entry, calls its default-exported `register(api)`
function, and wires the declared tools into every agent.

## 4. Verify the tool is registered

Run a one-shot agent turn that asks about available tools, or
use the gateway's introspection endpoint:

```bash
curl -s http://localhost:18789/v1/tools | jq '.[] | select(.plugin == "content-forge")'
```

You should see `create_upload_link` in the response.

## 5. End-to-end verification

With a product named `Acme Widgets Inc` seeded in the DB:

```bash
openclaw agent --message "create me an upload link for Acme"
```

Expected output:

```
Upload link for **Acme Widgets Inc** (expires 2026-04-23T14:07:42Z):

https://r2.contentforge.cloud/... (a real presigned URL)

Storage key: `products/<uuid>/assets/<uuid>/upload.bin`
```

If you get a 401, re-check that the secrets match on both
sides. If you get `product_not_found`, check that the product
name is unique enough to match (the lookup is a case-insensitive
substring; "Acme" matches "Acme Widgets Inc"). If multiple
products match, the agent reply will say `ambiguous_product` and
you should refine.

## 6. Tail logs during a live call

Open two terminals:

1. `tail -f priv/logs/dev.log` (or wherever Phoenix writes) for
   the Content Forge side.
2. Run the `openclaw agent` command in the other.

You should see the controller log the inbound tool call, the
presign call hit R2 / the configured storage adapter, and the
response go back to OpenClaw.

## Troubleshooting

- **401 Unauthorized** on every call: secrets mismatch. Check
  both sides. The plugin-side secret is read from
  `plugins.entries['content-forge'].toolSecret` in the gateway
  config; the server-side secret is
  `:content_forge, :open_claw_tool_secret` in the app env.
- **Tool not listed by the gateway**: plugin directory name or
  `openclaw.plugin.json` `id` field is wrong, OR the gateway is
  caching. Restart with `pkill -f openclaw-gateway` and retry.
- **`ambiguous_product`**: refine the product name; the fuzzy
  match is substring-based.
- **`product_not_found`**: confirm the product exists in the DB
  and that its name contains the phrase the user said.

## Currently registered tools

The plugin ships these tools. Each corresponds to a module under
`lib/content_forge/open_claw_tools/` in the Phoenix app.

- **`create_upload_link`** - generate a presigned PUT URL for
  direct-to-storage asset upload (Phase 16.1).
- **`list_recent_assets`** - list a product's recent non-deleted
  assets with media type + tag filters (Phase 16.2).
- **`draft_status`** - report a single draft's status; accepts
  either `draft_id` or a free-text `hint`. Returns
  `ambiguous_draft` when the hint matches more than one draft
  (Phase 16.2).
- **`upcoming_schedule`** - list approved drafts queued for
  publish. Content Forge does not hold per-draft schedule
  timestamps today, so the bot speaks in terms of "queued" rather
  than "scheduled for a day/time" (Phase 16.2).
- **`competitor_intel_summary`** - return the most recent
  competitor intel synthesis (summary, trending topics, winning
  formats, effective hooks). Returns `not_found` when no intel
  row exists (Phase 16.2).

## Future tools (ship pattern)

Each new tool goes under
`lib/content_forge/open_claw_tools/<snake_name>.ex`, registers
in the dispatch map in `ContentForge.OpenClawTools`, and gets a
matching entry in the plugin's `index.js` with its own schema.
The runbook above carries over unchanged for new tools.

Phases 16.3 through 16.6 add:

- **16.3** Light writes + role-based auth framework.
- **16.4** Heavy writes with two-turn confirmation.
- **16.5** Unified tool-invocation audit + dashboard.
- **16.6** Escalate-to-human as a tool.
