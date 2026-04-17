# Brownlow Enterprise - Agent Bridge installer (Windows)
#
# Does exactly this, in order:
#   1. Install Node.js LTS via winget if not present
#   1b. Install Git (Git Bash) via winget if not present
#   2. Install Claude Code CLI via `npm install -g @anthropic-ai/claude-code`
#   3. Download bridge/index.js to %USERPROFILE%\agent-bridge and install express + ws
#   4. Merge defaultMode=bypassPermissions into %USERPROFILE%\.claude\settings.json
#   5. Write ecosystem.config.js (with CLAUDE_PATH baked in) and start the
#      bridge under pm2 as 'agent-bridge', then pm2 save
#   6. Register a Task Scheduler task that runs `pm2 resurrect` at login
#   7. Print the Tailscale bridge URL and next-step instructions
#
# Usage:
#   powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/carsonbrownlow/brownlow-enterprise-agent-bridge/main/install-windows.ps1 | iex"

$ErrorActionPreference = 'Stop'

# Set execution policy for the current user so npm-shim .ps1 wrappers
# (pm2.ps1, claude.ps1, etc.) are allowed to run. Without this, pm2 and
# other globally-installed tools fail with "running scripts is disabled
# on this system" on machines that still have the default Restricted
# policy. CurrentUser scope does not require admin.
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
} catch {
    Write-Host "[agent-bridge] WARN: could not set execution policy: $_" -ForegroundColor Yellow
}

$RepoRaw     = 'https://raw.githubusercontent.com/carsonbrownlow/brownlow-enterprise-agent-bridge/main'
$InstallDir  = Join-Path $env:USERPROFILE 'agent-bridge'
$Pm2Name     = 'agent-bridge'
$TaskName    = 'AgentBridgeResurrect'
$SettingsDir = Join-Path $env:USERPROFILE '.claude'
$Settings    = Join-Path $SettingsDir 'settings.json'

function Say($msg) { Write-Host "[agent-bridge] $msg" -ForegroundColor Cyan }
function Die($msg) { Write-Host "[agent-bridge] $msg" -ForegroundColor Red; exit 1 }

function Refresh-Path {
    $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

# Run a native command and swallow any non-zero exit / stderr noise.
# Used for pm2 delete and schtasks /delete where "not found" is fine.
function Invoke-IgnoreFail {
    param([scriptblock]$Script)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try { & $Script 2>&1 | Out-Null } catch { }
    $global:LASTEXITCODE = 0
    $ErrorActionPreference = $prev
}

# ---------------------------------------------------------------------------
# 1. Node.js LTS
# ---------------------------------------------------------------------------
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Say 'Installing Node.js LTS via winget'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Die 'winget is not available. Install App Installer from the Microsoft Store, then re-run this script.'
    }
    winget install --id OpenJS.NodeJS.LTS -e --silent --accept-source-agreements --accept-package-agreements
    Refresh-Path
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Die 'Node install completed but `node` is still not on PATH. Open a new PowerShell and re-run.'
    }
} else {
    Say "Node already present: $((node -v))"
}

# ---------------------------------------------------------------------------
# 1b. Git (required by Claude Code for anything git-backed)
# ---------------------------------------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Say 'Installing Git via winget'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Die 'winget is not available. Install App Installer from the Microsoft Store, then re-run this script.'
    }
    winget install --id Git.Git -e --silent --accept-source-agreements --accept-package-agreements
    Refresh-Path
    Say 'Git Bash installed - you may need to restart your terminal before running claude'
} else {
    Say "Git already present: $((git --version))"
}

# ---------------------------------------------------------------------------
# 2. Claude Code CLI
# ---------------------------------------------------------------------------
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Say 'Installing Claude Code CLI globally via npm'
    npm install -g '@anthropic-ai/claude-code'
    Refresh-Path

    # npm global bin on Windows lives at %APPDATA%\npm — make sure it is on PATH
    $NpmBin = Join-Path $env:APPDATA 'npm'
    if ((Test-Path $NpmBin) -and (-not ($env:Path -split ';' | Where-Object { $_ -ieq $NpmBin }))) {
        $env:Path = "$NpmBin;$env:Path"
        $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
        if (-not ($userPath -split ';' | Where-Object { $_ -ieq $NpmBin })) {
            [System.Environment]::SetEnvironmentVariable('Path', "$NpmBin;$userPath", 'User')
        }
    }
} else {
    Say 'Claude Code CLI already present'
}

# ---------------------------------------------------------------------------
# 3. Bridge code + deps
# ---------------------------------------------------------------------------
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir | Out-Null }

Say "Downloading bridge/index.js into $InstallDir"
Invoke-WebRequest -UseBasicParsing -Uri "$RepoRaw/bridge/index.js" -OutFile (Join-Path $InstallDir 'index.js')

$Pkg = Join-Path $InstallDir 'package.json'
if (-not (Test-Path $Pkg)) {
    @'
{
  "name": "agent-bridge",
  "version": "1.0.0",
  "private": true,
  "main": "index.js",
  "type": "commonjs"
}
'@ | Set-Content -Path $Pkg -Encoding utf8
}

Say 'Installing express + ws'
Push-Location $InstallDir
try {
    npm install --no-audit --no-fund express ws
} finally {
    Pop-Location
}

# ---------------------------------------------------------------------------
# 4. Merge defaultMode=bypassPermissions into %USERPROFILE%\.claude\settings.json
# ---------------------------------------------------------------------------
if (-not (Test-Path $SettingsDir)) { New-Item -ItemType Directory -Path $SettingsDir | Out-Null }

Say "Ensuring defaultMode=bypassPermissions in $Settings"

$cfg = @{}
if (Test-Path $Settings) {
    $raw = Get-Content -Raw -Path $Settings
    if ($raw -and $raw.Trim().Length -gt 0) {
        try {
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            # Convert PSCustomObject -> hashtable so we can safely set a key
            $cfg = @{}
            foreach ($prop in $parsed.PSObject.Properties) { $cfg[$prop.Name] = $prop.Value }
        } catch {
            Say "settings.json unreadable, starting fresh: $_"
            $cfg = @{}
        }
    }
}

if ($cfg['defaultMode'] -ne 'bypassPermissions') {
    $cfg['defaultMode'] = 'bypassPermissions'
    ($cfg | ConvertTo-Json -Depth 20) | Set-Content -Path $Settings -Encoding utf8
    Say 'defaultMode set to bypassPermissions'
} else {
    Say 'defaultMode already bypassPermissions'
}

# ---------------------------------------------------------------------------
# 5. pm2 up + save
# ---------------------------------------------------------------------------
if (-not (Get-Command pm2 -ErrorAction SilentlyContinue)) {
    Say 'Installing pm2 globally'
    npm install -g pm2
    Refresh-Path
}

Say "Starting bridge under pm2 as '$Pm2Name'"
# pm2 delete exits non-zero when the process does not exist. Under
# $ErrorActionPreference='Stop' that would terminate the script, so we
# hard-swallow it with try/catch — "nothing to delete" is the expected
# first-run state.
try {
    & pm2 delete $Pm2Name *>&1 | Out-Null
} catch {
    # Nothing to delete, or pm2 shim complained — either way, fine.
}
$global:LASTEXITCODE = 0

# Write an ecosystem.config.js so CLAUDE_PATH (%APPDATA%\npm\claude.cmd)
# is baked into the pm2 app definition. Using `pm2 start index.js` would
# rely on the parent shell's env, which pm2 resurrect after a reboot
# would not see. The ecosystem file is what pm2 save serializes.
$ClaudeCmd     = Join-Path $env:APPDATA 'npm\claude.cmd'
$EcosystemPath = Join-Path $InstallDir 'ecosystem.config.js'
$IndexJsEsc    = ((Join-Path $InstallDir 'index.js') -replace '\\','\\')
$InstallDirEsc = ($InstallDir -replace '\\','\\')
$ClaudeCmdEsc  = ($ClaudeCmd   -replace '\\','\\')

$ecosystem = @"
module.exports = {
  apps: [{
    name: '$Pm2Name',
    script: '$IndexJsEsc',
    cwd: '$InstallDirEsc',
    env: {
      CLAUDE_PATH: '$ClaudeCmdEsc',
      // The Windows claude.cmd shim via cmd.exe often fails to relay
      // stdout back to Node during the one-shot auth probe, producing
      // false "unparseable output" errors even when claude is
      // authenticated. Skip the probe and let the persistent session
      // surface any real auth failure directly.
      SKIP_AUTH_CHECK: '1'
    }
  }]
};
"@
Set-Content -Path $EcosystemPath -Value $ecosystem -Encoding utf8
Say "Wrote $EcosystemPath (CLAUDE_PATH baked in)"

& pm2 start $EcosystemPath
& pm2 save

# ---------------------------------------------------------------------------
# 6. Task Scheduler — run `pm2 resurrect` at login
# ---------------------------------------------------------------------------
Say "Registering scheduled task '$TaskName' to run pm2 resurrect at login"
$Pm2Cmd = (Get-Command pm2 -ErrorAction SilentlyContinue).Source
if (-not $Pm2Cmd) { $Pm2Cmd = Join-Path $env:APPDATA 'npm\pm2.cmd' }

# schtasks is the most reliable across Windows editions; remove any previous
# copy first. /delete exits non-zero when the task does not exist — swallow it
# with try/catch so a fresh install does not abort here.
try {
    & schtasks /delete /tn $TaskName /f *>&1 | Out-Null
} catch { }
$global:LASTEXITCODE = 0
schtasks /create /tn $TaskName /tr "`"$Pm2Cmd`" resurrect" /sc ONLOGON /rl LIMITED /f | Out-Null

# ---------------------------------------------------------------------------
# 7. Final instructions
# ---------------------------------------------------------------------------
$TsIp = $null
if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    try {
        $TsIp = (& tailscale ip -4 2>$null | Select-Object -First 1).Trim()
    } catch { $TsIp = $null }
}

Write-Host ''
if ($TsIp) {
    Write-Host '✅ Agent bridge is live on port 3456' -ForegroundColor Green
    Write-Host ''
    Write-Host "Bridge URL: ws://${TsIp}:3456"
    Write-Host 'Enter this in your BE-Agent app to connect.'
    Write-Host ''
    Write-Host 'Next step: open a new terminal and run: claude'
    Write-Host 'Complete the browser login when it opens.'
} else {
    Write-Host '✅ Agent bridge is live on port 3456' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Install Tailscale at tailscale.com then run: tailscale ip -4 to get your bridge URL.'
    Write-Host ''
    Write-Host 'Next step: open a new terminal and run: claude'
    Write-Host 'Complete the browser login when it opens.'
}
Write-Host ''
