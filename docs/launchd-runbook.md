# Content Forge launchd Runbook

Phase 17.0 ships the canonical launchd plist that keeps the
Content Forge Phoenix server alive between sessions on the m4
Mac mini. The plist mirrors the lead_intelligence pattern so
operators only need to learn one daemon shape across the
ecosystem.

## What ships

- `priv/launchd/com.zyzyva.content-forge.plist` - the
  authoritative copy lives in the repo so a fresh checkout can
  re-install. Updates land via PR + merge.
- This runbook documents the install, the verification, and the
  uninstall paths.

## Prerequisites

- macOS host with Postgres 14+ available on the default socket.
- `~/.asdf/shims/mix` reachable (the plist's `PATH` points
  there). If you use a different Erlang/Elixir manager, edit
  the plist's `PATH` env var before installing.
- `content_forge_dev` Postgres database created. The `mix
  ecto.create` step is idempotent; run it from the repo root if
  you are not sure whether it exists already.

## Initial DB setup (one-time)

From the repo root:

```bash
cd ~/projects/contentforge_ecosystem/content-forge
MIX_ENV=dev mix deps.get
MIX_ENV=dev mix ecto.create
MIX_ENV=dev mix ecto.migrate
```

`mix ecto.create` is a no-op when the database already exists.
`mix ecto.migrate` is forward-only; run it after any pull that
adds migrations.

## Install the launchd job

```bash
cd ~/projects/contentforge_ecosystem/content-forge
cp priv/launchd/com.zyzyva.content-forge.plist \
   ~/Library/LaunchAgents/com.zyzyva.content-forge.plist

launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/com.zyzyva.content-forge.plist
```

`launchctl bootstrap` loads the plist into the user-domain
service manager. `RunAtLoad: true` starts Phoenix immediately;
`KeepAlive: true` restarts it on any unclean exit.

## Verify

```bash
launchctl list | grep com.zyzyva.content-forge
```

You should see the label with a non-zero PID and an exit code
of 0 (or `-` for "still running").

```bash
curl -s -o /dev/null -w 'status=%{http_code}\n' \
  http://127.0.0.1:4000/dashboard
```

Expected `status=200`. The dev server binds to `127.0.0.1:4000`
per `config/dev.exs`; this is the default Phoenix dev port and
does not collide with any of the other zyzyva daemons (lead
intelligence runs on 4010, marketing-research on its own port,
etc).

```bash
tail -f ~/Library/Logs/content-forge.log
```

Watch the boot for any provider warnings. Missing API keys
(Anthropic, Apify, etc.) downgrade the dependent feature to
"unavailable" but do not block boot.

## Restart behaviour

`KeepAlive: true` means killing the Phoenix process triggers a
restart within seconds. Exercise this once per machine to
confirm:

```bash
pkill -f 'content_forge.*phx.server'
sleep 5
launchctl list | grep com.zyzyva.content-forge
```

The PID column should show a fresh PID. The log should show a
clean boot sequence with no Postgres connection storms (the
Repo's pool reconnects gracefully).

## Uninstall

```bash
launchctl bootout gui/$(id -u) \
  ~/Library/LaunchAgents/com.zyzyva.content-forge.plist
rm ~/Library/LaunchAgents/com.zyzyva.content-forge.plist
```

`launchctl bootout` is the inverse of `bootstrap`; it stops the
service and unloads the plist. The repo copy under `priv/launchd/`
remains so a future re-install is a single `cp` away.

## Updating the plist

Edit `priv/launchd/com.zyzyva.content-forge.plist` in the repo,
land the change through the normal PR flow, then:

```bash
launchctl bootout gui/$(id -u) \
  ~/Library/LaunchAgents/com.zyzyva.content-forge.plist

cp priv/launchd/com.zyzyva.content-forge.plist \
   ~/Library/LaunchAgents/com.zyzyva.content-forge.plist

launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/com.zyzyva.content-forge.plist
```

`launchctl` does not auto-reload edits to a loaded plist; the
bootout / bootstrap dance is required.

## Why a stable port

Content Forge's OpenClaw plugin (Phase 16.1+) hits
`http://localhost:4000/api/v1/openclaw/tools/...` by default.
Changing the port here means updating the plugin's `baseUrl` in
`~/.openclaw/plugins/content-forge/openclaw.plugin.json`. Keep
4000 unless a future ecosystem service forces a move; document
any change in this runbook and in the OpenClaw plugin runbook.
