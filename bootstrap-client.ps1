<#
.SYNOPSIS
    Install and configure RustDesk + Tailscale on a Windows client for unattended
    remote access through a self-hosted, Tailscale-only RustDesk relay.

.DESCRIPTION
    Run on a fresh client Windows 10/11 box as Administrator. The script:
      1. Installs Tailscale if missing.
      2. Joins the tailnet using a one-shot tagged auth key (advertise-tags=tag:client),
         with DNS and subnet routes disabled so it never poisons the client's internet.
      3. Verifies reachability to the relay.
      4. Installs RustDesk if missing.
      5. Writes the RustDesk config so it points at the self-hosted relay.
      6. Launches RustDesk and prints the manual GUI steps that finish the install.

    The script is idempotent. Re-running is safe.

.PARAMETER AuthKey
    A Tailscale auth key generated with tag:client. Generate in the admin console:
    Settings -> Keys -> Generate auth key. Tick "tag:client". Reusable: OFF.
    Ephemeral: OFF.

.EXAMPLE
    .\bootstrap-client.ps1 -AuthKey tskey-auth-XXXXXXXXXXXXXX
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AuthKey,

    [string]$RelayIp  = '100.78.88.63',
    [string]$RelayKey = 'yIABL36cWQnguBPXRQZcUwyYsyRSZD++vhjQyh7Ctu8=',
    [string]$Tag      = 'tag:client'
)

$ErrorActionPreference = 'Stop'

function Require-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "Run this script in PowerShell as Administrator."
    }
}

function Install-Tailscale {
    $exe = 'C:\Program Files\Tailscale\tailscale.exe'
    if (Test-Path $exe) {
        Write-Host "[ok] Tailscale already installed."
        return $exe
    }
    Write-Host "[..] Installing Tailscale via winget..."
    winget install --id Tailscale.Tailscale -e `
        --accept-source-agreements --accept-package-agreements | Out-Null
    if (-not (Test-Path $exe)) {
        throw "Tailscale install failed. Install it manually then re-run."
    }
    Write-Host "[ok] Tailscale installed."
    return $exe
}

function Join-Tailnet {
    param([string]$Exe)
    Write-Host "[..] Joining tailnet (tag:$Tag, no DNS, no routes, unattended)..."
    & $Exe logout 2>$null | Out-Null
    & $Exe up `
        --auth-key=$AuthKey `
        --advertise-tags=$Tag `
        --unattended `
        --accept-dns=false `
        --accept-routes=false `
        --reset
    if ($LASTEXITCODE -ne 0) {
        throw "tailscale up failed (exit $LASTEXITCODE). Check the auth key."
    }
    Write-Host "[ok] Tailnet joined."
}

function Test-RelayReachable {
    param([string]$Exe)
    Write-Host "[..] Pinging relay $RelayIp over Tailscale..."
    $out = & $Exe ping --c 4 $RelayIp 2>&1 | Out-String
    Write-Host $out
    if ($out -notmatch 'pong') {
        throw "Relay $RelayIp unreachable. Check ACL grant tag:client -> tag:rustdesk."
    }
    Write-Host "[ok] Relay reachable."
}

function Install-RustDesk {
    $exe = 'C:\Program Files\RustDesk\rustdesk.exe'
    if (Test-Path $exe) {
        Write-Host "[ok] RustDesk already installed."
        return $exe
    }
    Write-Host "[..] Installing RustDesk..."
    try {
        winget install --id RustDesk.RustDesk -e `
            --accept-source-agreements --accept-package-agreements | Out-Null
    } catch {
        Write-Host "[!!] winget failed, falling back to GitHub release..."
    }
    if (-not (Test-Path $exe)) {
        $tmp = "$env:TEMP\rustdesk-installer.exe"
        $asset = (Invoke-RestMethod `
            'https://api.github.com/repos/rustdesk/rustdesk/releases/latest').assets |
            Where-Object { $_.name -like '*x86_64.exe' } |
            Select-Object -First 1
        if (-not $asset) {
            throw "No x86_64 release found on GitHub."
        }
        Invoke-WebRequest $asset.browser_download_url -OutFile $tmp -UseBasicParsing
        Start-Process -FilePath $tmp -ArgumentList '--silent-install' -Wait
    }
    if (-not (Test-Path $exe)) {
        throw "RustDesk install failed."
    }
    Write-Host "[ok] RustDesk installed."
    return $exe
}

function Write-RustDeskConfig {
    $cfgDir = "$env:APPDATA\RustDesk\config"
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    $cfg = "$cfgDir\RustDesk2.toml"

    # Preserve existing identity fields (rendezvous_server, nat_type, serial, etc.)
    # if a previous install left a config. Only rewrite the [options] keys we own.
    $head = ""
    if (Test-Path $cfg) {
        Copy-Item $cfg "$cfg.bak" -Force
        $lines = Get-Content $cfg
        foreach ($line in $lines) {
            if ($line -match '^\s*\[') { break }
            $head += "$line`n"
        }
    } else {
        $head = "rendezvous_server = '$RelayIp'`nnat_type = 1`nserial = 0`nunlock_pin = ''`n"
    }

    $body = @"

[options]
custom-rendezvous-server = '$RelayIp'
relay-server = '$RelayIp'
key = '$RelayKey'
verification-method = 'use-permanent-password'
"@

    Set-Content -Path $cfg -Value ($head + $body) -Encoding UTF8
    Write-Host "[ok] RustDesk config written to $cfg"
}

function Start-RustDesk {
    param([string]$Exe)
    Start-Process $Exe
    Start-Sleep -Seconds 2
}

function Print-NextSteps {
    Write-Host ""
    Write-Host "================ NEXT MANUAL STEPS (in the RustDesk window) ================" -ForegroundColor Cyan
    Write-Host " 1. Wait for the GREEN status dot at the bottom of the window."
    Write-Host "    Red = relay unreachable; stop and investigate the Tailscale ACL."
    Write-Host ""
    Write-Host " 2. Hamburger menu (top right) -> Security -> 'Use permanent password' ON."
    Write-Host "    Set a permanent password. WRITE IT DOWN. Hand it to your end."
    Write-Host ""
    Write-Host " 3. Hamburger menu -> General -> 'Start RustDesk on boot' ON."
    Write-Host "    (Also tick 'Enable service' if shown.)"
    Write-Host ""
    Write-Host " 4. Note the 9-DIGIT ID on the main window. Hand it to your end."
    Write-Host ""
    Write-Host " 5. From your end's RustDesk: enter the 9-digit ID, click Connect,"
    Write-Host "    enter the permanent password. You're in."
    Write-Host ""
    Write-Host " 6. Back in the Tailscale admin console: revoke the one-shot auth key."
    Write-Host "==========================================================================="
}

# ---- main ----
Require-Admin
$ts = Install-Tailscale
Join-Tailnet -Exe $ts
Test-RelayReachable -Exe $ts
$rd = Install-RustDesk
Write-RustDeskConfig
Start-RustDesk -Exe $rd
Print-NextSteps
