# Brownlow Enterprise - Agent Bridge installer (Windows -> WSL2)
#
# Claude Code's stream-json protocol is not supported natively on Windows,
# so every Windows deployment runs the bridge inside WSL2 Ubuntu. This
# script installs WSL Ubuntu if needed, runs the Linux install.sh inside
# WSL, then sets up Windows-side netsh portproxy + firewall + a scheduled
# task so ws://<host>:3456 on Windows reaches the bridge inside WSL.
#
# Flow:
#   1. If WSL Ubuntu is not installed: wsl --install -d Ubuntu, tell the
#      user to restart and re-run the script.
#   2. Run install.sh inside WSL Ubuntu via curl | bash.
#   3. Resolve the WSL IP (hostname -I inside Ubuntu).
#   4. Self-elevate to admin if needed (netsh + schtasks require admin).
#   5. netsh portproxy 0.0.0.0:3456 -> <WSL-IP>:3456 + firewall rule.
#   6. Scheduled task AgentBridgePortForward re-applies the portproxy at
#      every logon (WSL IP changes on reboot).
#   7. Print bridge URL (tailscale ip -4 inside WSL) and next steps.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/carsonbrownlow/brownlow-enterprise-agent-bridge/main/install-windows.ps1 | iex"

$ErrorActionPreference = 'Stop'

try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
} catch {
    Write-Host "[agent-bridge] WARN: could not set execution policy: $_" -ForegroundColor Yellow
}

$Distro         = 'Ubuntu'
$BridgePort     = 3456
$TaskName       = 'AgentBridgePortForward'
$FirewallRule   = 'Agent Bridge 3456'
$InstallShUrl   = 'https://raw.githubusercontent.com/carsonbrownlow/brownlow-enterprise-agent-bridge/main/install.sh'

function Say($msg)  { Write-Host "[agent-bridge] $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "[agent-bridge] $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "[agent-bridge] $msg" -ForegroundColor Red; exit 1 }

function Test-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WSLInstalled {
    # wsl --list --quiet returns distro names (often UTF-16LE with NULs on
    # older WSL builds), exit 0 if any are installed. Normalize aggressively.
    try {
        $raw = (wsl --list --quiet 2>$null) -join "`n"
        if (-not $raw) { return $false }
        $clean = ($raw -replace "`0","").Trim()
        return ($clean -match '(?im)^\s*' + [regex]::Escape($Distro) + '\s*$')
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Phase A: install WSL Ubuntu if needed, then ask user to restart + re-run.
# ---------------------------------------------------------------------------
if (-not (Test-WSLInstalled)) {
    Say "WSL $Distro not installed. Installing now — this typically needs a reboot."
    if (-not (Test-Admin)) {
        Warn "wsl --install requires admin. Relaunching this script elevated..."
        $argList = "-NoProfile -ExecutionPolicy Bypass -Command `"irm $($MyInvocation.MyCommand.Path -replace '\\','/') | iex`""
        # When piped via `irm | iex` the script has no path on disk, so the
        # cleanest relaunch is to re-fetch from GitHub.
        $argList = "-NoProfile -ExecutionPolicy Bypass -Command `"irm https://raw.githubusercontent.com/carsonbrownlow/brownlow-enterprise-agent-bridge/main/install-windows.ps1 | iex`""
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
        exit 0
    }

    wsl --install -d $Distro
    Write-Host ''
    Say 'WSL install triggered.'
    Say '1. Restart Windows when prompted.'
    Say '2. After restart, Ubuntu will open and ask you to create a username/password.'
    Say '3. Complete that, then re-run this installer:'
    Write-Host ''
    Write-Host '     powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/carsonbrownlow/brownlow-enterprise-agent-bridge/main/install-windows.ps1 | iex"' -ForegroundColor Green
    Write-Host ''
    exit 0
}

Say "WSL $Distro detected. Proceeding with bridge install inside WSL."

# ---------------------------------------------------------------------------
# Phase B: run the Linux install.sh inside WSL Ubuntu.
# ---------------------------------------------------------------------------
Say 'Running Linux install script inside WSL Ubuntu (this takes a few minutes)...'
wsl -d $Distro -- bash -lc "curl -fsSL $InstallShUrl | bash"
if ($LASTEXITCODE -ne 0) {
    Die "install.sh inside WSL $Distro exited with code $LASTEXITCODE. Check WSL output above."
}

# ---------------------------------------------------------------------------
# Phase C: resolve the WSL IP. hostname -I returns space-separated v4 addrs;
#          the first is the WSL eth0 address reachable from Windows host.
# ---------------------------------------------------------------------------
$WslIp = (wsl -d $Distro -- bash -lc 'hostname -I 2>/dev/null').Trim().Split(' ')[0]
if (-not $WslIp) {
    Die "Could not resolve WSL $Distro IP via hostname -I."
}
Say "WSL IP: $WslIp"

# ---------------------------------------------------------------------------
# Phase D: ensure we are admin before netsh / schtasks. Self-elevate if not.
# ---------------------------------------------------------------------------
if (-not (Test-Admin)) {
    Warn 'Port forwarding + firewall need admin. Relaunching this script elevated...'
    $argList = "-NoProfile -ExecutionPolicy Bypass -Command `"irm https://raw.githubusercontent.com/carsonbrownlow/brownlow-enterprise-agent-bridge/main/install-windows.ps1 | iex`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    exit 0
}

# ---------------------------------------------------------------------------
# Phase E: netsh portproxy + firewall rule.
# ---------------------------------------------------------------------------
Say "Setting up Windows -> WSL port forward on :$BridgePort"

try { & netsh interface portproxy delete v4tov4 listenport=$BridgePort listenaddress=0.0.0.0 *>&1 | Out-Null } catch { }
$global:LASTEXITCODE = 0

& netsh interface portproxy add v4tov4 listenport=$BridgePort listenaddress=0.0.0.0 connectport=$BridgePort connectaddress=$WslIp | Out-Null
if ($LASTEXITCODE -ne 0) { Die "netsh portproxy add failed (exit $LASTEXITCODE)" }

try { & netsh advfirewall firewall delete rule name="$FirewallRule" *>&1 | Out-Null } catch { }
$global:LASTEXITCODE = 0
& netsh advfirewall firewall add rule name="$FirewallRule" dir=in action=allow protocol=TCP localport=$BridgePort | Out-Null
if ($LASTEXITCODE -ne 0) { Warn "Firewall rule add returned $LASTEXITCODE — connections from other hosts may be blocked." }

# ---------------------------------------------------------------------------
# Phase F: scheduled task to re-apply portproxy at every logon.
#          WSL's IP changes across reboots, so the task runs a small PS
#          one-liner that re-reads hostname -I and rewrites the proxy.
# ---------------------------------------------------------------------------
Say "Registering scheduled task '$TaskName' (re-applies port forward at login)"

$ReapplyScript = @"
`$ip = (wsl -d $Distro -- bash -lc 'hostname -I 2>/dev/null').Trim().Split(' ')[0]
if (`$ip) {
    netsh interface portproxy delete v4tov4 listenport=$BridgePort listenaddress=0.0.0.0 2>`$null | Out-Null
    netsh interface portproxy add v4tov4 listenport=$BridgePort listenaddress=0.0.0.0 connectport=$BridgePort connectaddress=`$ip | Out-Null
}
"@
$ReapplyPath = Join-Path $env:ProgramData 'agent-bridge\reapply-portproxy.ps1'
New-Item -ItemType Directory -Path (Split-Path $ReapplyPath) -Force | Out-Null
Set-Content -Path $ReapplyPath -Value $ReapplyScript -Encoding utf8

try { & schtasks /delete /tn $TaskName /f *>&1 | Out-Null } catch { }
$global:LASTEXITCODE = 0

$TaskCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ReapplyPath`""
& schtasks /create /tn $TaskName /tr $TaskCmd /sc ONLOGON /rl HIGHEST /f | Out-Null
if ($LASTEXITCODE -ne 0) {
    Warn "schtasks /create returned $LASTEXITCODE — port forward may not persist across reboots until you re-run this script."
}

# ---------------------------------------------------------------------------
# Phase G: final instructions.
# ---------------------------------------------------------------------------
# Prefer the tailscale IP from inside WSL if the client has it installed,
# otherwise hand back the Windows-reachable bridge URL via the host IP.
$TsIp = ''
try {
    $TsIp = (wsl -d $Distro -- bash -lc 'tailscale ip -4 2>/dev/null | head -n1').Trim()
} catch { $TsIp = '' }

Write-Host ''
Write-Host '────────────────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host '✅ Agent bridge is live on port 3456 (Windows -> WSL Ubuntu)' -ForegroundColor Green
Write-Host ''
if ($TsIp) {
    Write-Host "Bridge URL:  ws://${TsIp}:3456"
    Write-Host 'Enter this in your BE-Agent app to connect.'
} else {
    Write-Host 'Bridge URL:  ws://<tailscale-ip>:3456'
    Write-Host 'Install Tailscale inside WSL (https://tailscale.com) then run'
    Write-Host '  wsl -d Ubuntu -- tailscale ip -4'
    Write-Host 'to get your bridge URL.'
}
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Open Ubuntu from the Start menu.'
Write-Host '  2. Run:  claude'
Write-Host '     Complete the browser login when it opens.'
Write-Host '  3. After any Windows restart, open Ubuntu and run:'
Write-Host '       source ~/.bashrc && pm2 resurrect'
Write-Host '     (the port forward reapplies automatically at login).'
Write-Host '────────────────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ''
