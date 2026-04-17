#!/usr/bin/env bash
#
# Brownlow Enterprise — Agent Bridge installer (macOS)
#
# Does exactly this, in order:
#   1. Installs NVM + Node if not present
#   2. Installs Claude Code CLI if not present
#   3. Downloads bridge/index.js into ~/agent-bridge and installs express + ws
#   4. Ensures ~/.claude/settings.json has defaultMode=bypassPermissions (merged,
#      not overwritten)
#   5. Starts the bridge under pm2 as 'agent-bridge' and saves the pm2 state
#   6. Installs a launchd plist so the bridge resurrects on boot
#   7. Prints the bridge URL (tailscale ip -4), the claude auth reminder, and
#      the BE-Agent app instructions
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/carsonbrownlow/brownlow-enterprise-agent-bridge/main/install.sh | bash

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/carsonbrownlow/brownlow-enterprise-agent-bridge/main"
INSTALL_DIR="$HOME/agent-bridge"
PM2_NAME="agent-bridge"
PLIST_LABEL="com.brownlow.agent-bridge"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
NVM_DIR="$HOME/.nvm"

say() { printf "\033[1;34m[agent-bridge]\033[0m %s\n" "$*"; }

# ---------------------------------------------------------------------------
# 1. NVM + Node
# ---------------------------------------------------------------------------
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  say "Installing NVM"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi

# shellcheck disable=SC1091
export NVM_DIR="$NVM_DIR"
. "$NVM_DIR/nvm.sh"

if ! command -v node >/dev/null 2>&1; then
  say "Installing Node LTS via NVM"
  nvm install --lts
  nvm alias default 'lts/*'
fi
nvm use default >/dev/null

# ---------------------------------------------------------------------------
# 2. Claude Code CLI
# ---------------------------------------------------------------------------
if ! command -v claude >/dev/null 2>&1; then
  say "Installing Claude Code CLI"
  curl -fsSL https://claude.ai/install.sh | bash

  # Ensure ~/.local/bin is on PATH for this and future shells
  if [ -d "$HOME/.local/bin" ]; then
    export PATH="$HOME/.local/bin:$PATH"
    for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
      if [ -f "$rc" ] && ! grep -q '.local/bin' "$rc" 2>/dev/null; then
        printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------
# 3. Bridge code + deps
# ---------------------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
say "Downloading bridge/index.js into $INSTALL_DIR"
curl -fsSL "$REPO_RAW/bridge/index.js" -o "$INSTALL_DIR/index.js"

cd "$INSTALL_DIR"
if [ ! -f package.json ]; then
  cat > package.json <<'PKG'
{
  "name": "agent-bridge",
  "version": "1.0.0",
  "private": true,
  "main": "index.js",
  "type": "commonjs"
}
PKG
fi

say "Installing express + ws"
npm install --no-audit --no-fund express ws

# ---------------------------------------------------------------------------
# 4. Merge defaultMode=bypassPermissions into ~/.claude/settings.json
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.claude"
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

say "Ensuring defaultMode=bypassPermissions in $SETTINGS"
node - "$SETTINGS" <<'NODE'
const fs = require('fs');
const p = process.argv[2];
let cfg = {};
try {
  const raw = fs.readFileSync(p, 'utf8').trim();
  if (raw) cfg = JSON.parse(raw);
} catch (e) {
  console.error('settings.json unreadable, starting fresh:', e.message);
  cfg = {};
}
if (cfg.defaultMode !== 'bypassPermissions') {
  cfg.defaultMode = 'bypassPermissions';
  fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + '\n');
  console.log('defaultMode set to bypassPermissions');
} else {
  console.log('defaultMode already bypassPermissions');
}
NODE

# ---------------------------------------------------------------------------
# 5. pm2 up + save
# ---------------------------------------------------------------------------
if ! command -v pm2 >/dev/null 2>&1; then
  say "Installing pm2"
  npm install -g pm2
fi

say "Starting bridge under pm2 as '$PM2_NAME'"
pm2 delete "$PM2_NAME" >/dev/null 2>&1 || true
pm2 start "$INSTALL_DIR/index.js" --name "$PM2_NAME" --cwd "$INSTALL_DIR"
pm2 save

# ---------------------------------------------------------------------------
# 6. launchd plist for boot persistence
# ---------------------------------------------------------------------------
say "Installing launchd plist at $PLIST_PATH"
mkdir -p "$HOME/Library/LaunchAgents"

NODE_BIN="$(command -v node)"
NODE_BIN_DIR="$(dirname "$NODE_BIN")"
PM2_BIN="$(command -v pm2)"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PM2_BIN}</string>
    <string>resurrect</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${NODE_BIN_DIR}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key>
    <string>${HOME}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${INSTALL_DIR}/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>${INSTALL_DIR}/launchd.err.log</string>
</dict>
</plist>
PLIST

launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl load "$PLIST_PATH"

# ---------------------------------------------------------------------------
# 7. Final instructions
# ---------------------------------------------------------------------------
TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
if [ -z "$TS_IP" ]; then
  BRIDGE_URL="ws://<tailscale-ip>:3456"
  TS_NOTE="  (Tailscale not detected — run 'tailscale ip -4' on this machine to get the IP.)"
else
  BRIDGE_URL="ws://${TS_IP}:3456"
  TS_NOTE=""
fi

cat <<EOF

────────────────────────────────────────────────────────────
 Install complete.

 Bridge URL:  ${BRIDGE_URL}
${TS_NOTE}
 Next:
   1. Run 'claude' once in this terminal to authenticate via browser.
   2. Open the BE-Agent app and paste the bridge URL above into
      the connection field.
────────────────────────────────────────────────────────────
EOF
