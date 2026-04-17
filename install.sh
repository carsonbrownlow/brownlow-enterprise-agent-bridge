#!/usr/bin/env bash
#
# Brownlow Enterprise — Agent Bridge installer
#
# Installs the bridge server into ~/agent-bridge, boots it under pm2, and
# registers it for auto-start on login.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/carsonbrownlow/brownlow-enterprise-agent-bridge/main/install.sh | bash
#
# After install, authenticate Claude Code once:
#   claude
#
# Then restart the bridge so it picks up the creds:
#   pm2 restart agent-bridge

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/carsonbrownlow/brownlow-enterprise-agent-bridge/main"
INSTALL_DIR="${AGENT_BRIDGE_DIR:-$HOME/agent-bridge}"
BRIDGE_DIR="$INSTALL_DIR/bridge"
PM2_NAME="${PM2_NAME:-agent-bridge}"

say()  { printf "\033[1;34m[agent-bridge]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[agent-bridge]\033[0m %s\n" "$*" >&2; exit 1; }

say "Target install dir: $INSTALL_DIR"

command -v node >/dev/null 2>&1 || die "node is required. Install Node 18+ (e.g. via nvm or 'brew install node') and re-run."
command -v npm  >/dev/null 2>&1 || die "npm is required."

NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]")
if [ "$NODE_MAJOR" -lt 18 ]; then
  die "Node $NODE_MAJOR detected. Need Node 18 or newer."
fi

if ! command -v claude >/dev/null 2>&1; then
  say "WARNING: 'claude' CLI not on PATH. The bridge needs Claude Code installed and authenticated."
  say "         Install from https://docs.claude.com/en/docs/claude-code then run 'claude' to log in."
fi

if ! command -v pm2 >/dev/null 2>&1; then
  say "Installing pm2 globally"
  npm install -g pm2
fi

mkdir -p "$BRIDGE_DIR"
cd "$BRIDGE_DIR"

say "Downloading bridge files"
curl -fsSL "$REPO_RAW/bridge/index.js"     -o index.js
curl -fsSL "$REPO_RAW/bridge/package.json" -o package.json

say "Installing dependencies"
npm install --omit=dev --no-audit --no-fund

say "Starting under pm2 as '$PM2_NAME'"
pm2 delete "$PM2_NAME" >/dev/null 2>&1 || true
pm2 start index.js --name "$PM2_NAME" --cwd "$BRIDGE_DIR"
pm2 save

say "Attempting pm2 auto-start on login (may prompt for sudo)"
pm2 startup >/dev/null 2>&1 || say "pm2 startup skipped — run 'pm2 startup' manually if you want auto-start on login."

PORT="${PORT:-3456}"
sleep 1
if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  say "Bridge is up at http://127.0.0.1:$PORT  (health endpoint OK)"
else
  say "Bridge started but /health did not respond yet. Check: pm2 logs $PM2_NAME"
fi

say "Done."
say ""
say "Next steps:"
say "  1. If you haven't already: run 'claude' to authenticate Claude Code."
say "  2. Restart the bridge so it picks up creds: pm2 restart $PM2_NAME"
say "  3. Point your client app at: ws://<this-host>:$PORT"
