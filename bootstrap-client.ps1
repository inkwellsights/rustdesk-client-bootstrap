<#
.SYNOPSIS
    Prepare a Windows client laptop for unattended remote access through a
    self-hosted, Tailscale-only RustDesk relay.

.DESCRIPTION
    Run on a fresh client Windows 10/11 box as Administrator. The script
    automates the parts that are safe to automate and pre-fills RustDesk's
    network settings so nobody has to type the relay IP or key by hand:

      1. Installs Tailscale (if missing).
      2. Joins the tailnet as a TAGGED device (tag:client) via a one-shot auth
         key, with DNS + subnet routes disabled so the laptop's normal internet
         is never disturbed.
      3. Verifies it can reach the relay over Tailscale.
      4. Installs RustDesk (if missing; winget, GitHub release fallback).
      5. Pre-fills the RustDesk *user* config (BOM-free) so the Network panel
         already shows the right ID server / relay / key on first launch.
      6. Launches RustDesk and prints the remaining GUI steps.

    WHY THE LAST STEPS ARE MANUAL (read this before "improving" it):
    On RustDesk 1.4.x the fully-silent paths are unreliable:
      - `--config <blob>` has a known bug where the relay is not applied
        (rustdesk/rustdesk discussion #7118).
      - `--get-id` returns nothing from a non-console (GUI-subsystem) build, so
        the 9-digit ID cannot be captured programmatically.
      - The unattended SERVICE runs as LocalSystem; which on-disk config file it
        reads is account/version dependent, so blind-writing a service-profile
        TOML is a guess, not a guarantee.
    Setting the permanent password + enabling the service through the GUI is the
    ONLY method verified end-to-end on 1.4.x. Pre-filling the user config (this
    script) + that GUI step is reliable: enabling the service propagates the
    pre-filled relay settings. Don't trade that for unverified silence.

    The script is idempotent. Re-running is safe.

.PARAMETER AuthKey
    Tailscale auth key generated with tag:client (admin console -> Settings ->
    Keys -> Generate auth key -> tick tag:client, Reusable OFF, Ephemeral OFF).

.PARAMETER RustdeskPassword
    OPTIONAL. If supplied, the script makes a best-effort `--password` call to
    set the permanent password non-interactively. This is NOT verified on 1.4.x
    so you MUST confirm in the GUI (Security -> a permanent password is set).
    If omitted, set the password in the GUI (the proven path).

.EXAMPLE
    .\bootstrap-client.ps1 -AuthKey tskey-auth-XXXXXXXXXXXX

.EXAMPLE
    .\bootstrap-client.ps1 -AuthKey tskey-auth-XXXXXXXXXXXX -RustdeskPassword 'S0me-Strong-PW'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AuthKey,

    [string]$RustdeskPassword,
    [string]$RelayIp  = '100.78.88.63',
    [string]$RelayKey = 'yIABL36cWQnguBPXRQZcUwyYsyRSZD++vhjQyh7Ctu8=',
    [string]$Tag      = 'tag:client'
)

$ErrorActionPreference = 'Stop'
$TailscaleExe = 'C:\Program Files\Tailscale\tailscale.exe'
$RustDeskExe  = 'C:\Program Files\RustDesk\rustdesk.exe'

function Require-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "Run this in PowerShell as Administrator (right-click Start -> Terminal (Administrator))."
    }
}

function Install-Tailscale {
    if (Test-Path $TailscaleExe) { Write-Host "[ok] Tailscale already installed."; return }
    Write-Host "[..] Installing Tailscale via winget..."
    winget install --id Tailscale.Tailscale -e `
        --accept-source-agreements --accept-package-agreements | Out-Null
    if (-not (Test-Path $TailscaleExe)) {
        throw "Tailscale install failed. Install it manually, then re-run."
    }
    Write-Host "[ok] Tailscale installed."
}

function Join-Tailnet {
    Write-Host "[..] Joining tailnet ($Tag, no DNS, no routes, unattended)..."
    & $TailscaleExe logout 2>$null | Out-Null
    & $TailscaleExe up `
        --auth-key=$AuthKey `
        --advertise-tags=$Tag `
        --unattended `
        --accept-dns=false `
        --accept-routes=false `
        --reset
    if ($LASTEXITCODE -ne 0) {
        throw "tailscale up failed (exit $LASTEXITCODE). Check the auth key is valid and tagged."
    }
    Write-Host "[ok] Tailnet joined."
}

function Test-RelayReachable {
    Write-Host "[..] Pinging relay $RelayIp over Tailscale..."
    $out = & $TailscaleExe ping --c 4 $RelayIp 2>&1 | Out-String
    Write-Host $out
    if ($out -notmatch 'pong') {
        throw "Relay $RelayIp unreachable. Check the ACL grant tag:client -> tag:rustdesk and that the relay row shows tag:rustdesk."
    }
    Write-Host "[ok] Relay reachable."
}

function Install-RustDesk {
    if (Test-Path $RustDeskExe) { Write-Host "[ok] RustDesk already installed."; return }
    Write-Host "[..] Installing RustDesk..."
    try {
        winget install --id RustDesk.RustDesk -e `
            --accept-source-agreements --accept-package-agreements | Out-Null
    } catch {
        Write-Host "[!!] winget failed; falling back to GitHub release..."
    }
    if (-not (Test-Path $RustDeskExe)) {
        $tmp = "$env:TEMP\rustdesk-installer.exe"
        $asset = (Invoke-RestMethod 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest').assets |
            Where-Object { $_.name -like '*x86_64.exe' } | Select-Object -First 1
        if (-not $asset) { throw "No x86_64 RustDesk release found on GitHub." }
        Write-Host "[..] Downloading $($asset.name)..."
        Invoke-WebRequest $asset.browser_download_url -OutFile $tmp -UseBasicParsing
        Start-Process -FilePath $tmp -ArgumentList '--silent-install' -Wait
    }
    if (-not (Test-Path $RustDeskExe)) { throw "RustDesk install failed." }
    Write-Host "[ok] RustDesk installed."
    Start-Sleep -Seconds 3   # let the installer register + start the service
}

function Set-RustDeskUserConfig {
    # Pre-fill the *user* config so the Network panel shows the right relay on
    # first launch. Written WITHOUT a BOM (PS 5.1 Set-Content -Encoding UTF8 adds
    # one, which can break RustDesk's TOML parser). Enabling the service in the
    # GUI propagates these settings to the service context.
    $cfgDir = "$env:APPDATA\RustDesk\config"
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    $cfg = Join-Path $cfgDir 'RustDesk2.toml'
    if (Test-Path $cfg) { Copy-Item $cfg "$cfg.bak" -Force }

    $content = @"
rendezvous_server = '$RelayIp`:21116'
nat_type = 1
serial = 0

[options]
custom-rendezvous-server = '$RelayIp'
relay-server = '$RelayIp'
key = '$RelayKey'
verification-method = 'use-permanent-password'
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($cfg, $content, $utf8NoBom)
    Write-Host "[ok] Pre-filled RustDesk network config (BOM-free) at $cfg"
}

function Try-SetPassword {
    if (-not $RustdeskPassword) { return }
    Write-Host "[..] Best-effort: setting permanent password via --password (unverified on 1.4.x)..."
    try { & $RustDeskExe --password $RustdeskPassword 2>&1 | Out-Null } catch {}
    Write-Host "[!!] VERIFY in the GUI that a permanent password is actually set (Security tab)."
}

function Start-RustDesk { Start-Process $RustDeskExe; Start-Sleep -Seconds 2 }

function Print-NextSteps {
    $pwLine = if ($RustdeskPassword) {
        " 2. Security: CONFIRM the permanent password is set (you passed one; verify it took)."
    } else {
        " 2. Hamburger menu -> Security -> 'Use permanent password' ON -> set one. WRITE IT DOWN."
    }
    Write-Host ""
    Write-Host "================ FINISH IN THE RUSTDESK WINDOW (proven on 1.4.x) ================" -ForegroundColor Cyan
    Write-Host " 1. Wait for the GREEN status dot (bottom of the window). Red = relay unreachable;"
    Write-Host "    stop and check the Tailscale ACL. The ID/Relay/Key are already filled in."
    Write-Host $pwLine
    Write-Host " 3. Hamburger menu -> General -> 'Start RustDesk on boot' ON (this propagates the"
    Write-Host "    relay settings to the unattended service)."
    Write-Host " 4. Read the 9-DIGIT ID on the main window (can't be captured by script on 1.4.x)."
    Write-Host ""
    Write-Host " Hand the 9-digit ID + permanent password to the controlling end."
    Write-Host " Then revoke the one-shot auth key in the Tailscale admin console."
    Write-Host "================================================================================"
}

# ---- main ----
Require-Admin
Install-Tailscale
Join-Tailnet
Test-RelayReachable
Install-RustDesk
Set-RustDeskUserConfig
Try-SetPassword
Start-RustDesk
Print-NextSteps
