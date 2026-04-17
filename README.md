# Brownlow Enterprise — Agent Bridge

Bridge server connecting the BE-Agent iOS app to a persistent Claude Code session.

Runs on the host machine, holds one long-lived `claude -p` process per bridge,
and exposes both an HTTP `POST /message` endpoint and a WebSocket stream with
token-level deltas, heartbeats, and health info.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/carsonbrownlow/brownlow-enterprise-agent-bridge/main/install.sh | bash
```

After install, authenticate Claude Code:

```bash
claude
```

Then restart the bridge so it picks up the creds:

```bash
pm2 restart agent-bridge
```

## Configuration

All settings have sensible defaults. Override via environment variables before
`pm2 start` (or in a `pm2` ecosystem file):

| Env var                 | Default               | Purpose                                       |
| ----------------------- | --------------------- | --------------------------------------------- |
| `PORT`                  | `3456`                | HTTP + WS port                                |
| `CLAUDE_PATH`           | auto-detected         | Path to the `claude` binary                   |
| `CLAUDE_CWD`            | `$HOME`               | cwd for spawned Claude sessions               |
| `BRIDGE_SENTINEL`       | `---AGENT_END---`     | Trailing marker stripped from assistant text  |
| `REQUEST_TIMEOUT_MS`    | `120000`              | Per-request timeout                           |
| `RESPAWN_DELAY_MS`      | `2000`                | Delay before restarting a dead Claude process |
| `HEARTBEAT_INTERVAL_MS` | `3000`                | WS heartbeat cadence                          |
| `BRIDGE_SUPABASE_URL`   | _(optional)_          | If set, POST session summaries here           |
| `BRIDGE_SUPABASE_KEY`   | _(optional)_          | Bearer key for the Supabase endpoint          |

## Endpoints

- `GET  /health` — JSON: auth state, session id, queue depth, uptime, last error, ws client count.
- `POST /message` — `{"message": "..."}` → `{"response": "...", "session_id": "...", "ms": N}`.
- `WS  /` — send `{"type":"message","content":"..."}`; receive `{type:"token"|"heartbeat"|"done"|"error"}` frames. Send `{"type":"end_session"}` to flush a session summary and disconnect.

## Requirements

- Node 18+
- `pm2` (installed automatically by `install.sh`)
- Claude Code installed and authenticated on the host
