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
#   6. Auto-runs `pm2 startup` for boot persistence (evals the sudo env
#      line pm2 prints — no manual copy-paste needed)
#   7. Probes /health and prints bridge URL + status (ready / starting /
#      down) + the claude auth reminder and BE-Agent app instructions
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/carsonbrownlow/brownlow-enterprise-agent-bridge/main/install.sh | bash

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/carsonbrownlow/brownlow-enterprise-agent-bridge/main"
INSTALL_DIR="$HOME/agent-bridge"
PM2_NAME="agent-bridge"
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
# 6. Boot persistence via `pm2 startup` (installs a launchd plist under
#    ~/Library/LaunchAgents/com.pm2.<user>.plist). Auto-eval the sudo env
#    line pm2 prints so the user does not have to copy-paste it.
# ---------------------------------------------------------------------------
say "Registering pm2 for boot persistence"
PM2_STARTUP_OUTPUT="$(pm2 startup 2>&1 || true)"
PM2_STARTUP_CMD="$(printf '%s\n' "$PM2_STARTUP_OUTPUT" | grep -E '^[[:space:]]*sudo env' | tail -n1 | sed 's/^[[:space:]]*//')"

if [ -n "$PM2_STARTUP_CMD" ]; then
  say "Auto-running: $PM2_STARTUP_CMD"
  if ! eval "$PM2_STARTUP_CMD"; then
    say "WARN: pm2 startup eval exited non-zero. If prompted for a password above and you skipped it, re-run: $PM2_STARTUP_CMD"
  fi
  pm2 save
else
  say "pm2 startup did not emit a sudo env line. Output was:"
  printf '%s\n' "$PM2_STARTUP_OUTPUT"
  say "You may need to run \`pm2 startup\` manually and follow the printed instructions."
fi

# ---------------------------------------------------------------------------
# 7. Final instructions + health probe
# ---------------------------------------------------------------------------
TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
if [ -z "$TS_IP" ]; then
  BRIDGE_URL="ws://<tailscale-ip>:3456"
  TS_NOTE="  (Tailscale not detected — run 'tailscale ip -4' on this machine to get the IP.)"
else
  BRIDGE_URL="ws://${TS_IP}:3456"
  TS_NOTE=""
fi

# Give pm2 a moment, then probe /health and categorize the response into
# one of three states: session ready / bridge up but session starting /
# bridge not responding.
sleep 2
HEALTH="$(curl -fsS --max-time 3 http://127.0.0.1:3456/health 2>/dev/null || true)"

if [ -z "$HEALTH" ]; then
  HEALTH_STATE="DOWN"
  HEALTH_MSG="⚠️  Bridge is not responding on http://127.0.0.1:3456/health. Check pm2 logs agent-bridge."
elif printf '%s' "$HEALTH" | grep -q '"session_ready":true'; then
  HEALTH_STATE="READY"
  HEALTH_MSG="✅ Bridge is live and the Claude session is ready."
else
  HEALTH_STATE="STARTING"
  HEALTH_MSG="⏳ Bridge is up but the Claude session is still starting. Run 'claude' once to authenticate if you have not already, then pm2 restart agent-bridge."
fi

cat <<EOF

────────────────────────────────────────────────────────────
 Install complete.

 Bridge URL:  ${BRIDGE_URL}
${TS_NOTE}
 Status:      ${HEALTH_STATE}
 ${HEALTH_MSG}

 Next:
   1. If you have not yet authenticated, run 'claude' in this terminal
      to complete the browser login.
   2. Open the BE-Agent app and paste the bridge URL above into
      the connection field.
────────────────────────────────────────────────────────────
EOF
