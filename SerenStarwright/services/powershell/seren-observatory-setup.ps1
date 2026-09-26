<#
# ══════════════════════════════════════════════════════════════════════════
#  seren-observatory-setup.ps1  -  one-shot SerenObservatory installer (Windows)
#
#  Refactored to dot-source seren-install-lib.ps1 (shared installer library).
#  Identity lines + config are the only unique parts.
#
#  USAGE (same flags as before)
#    powershell -ExecutionPolicy Bypass -File .\seren-observatory-setup.ps1
#    powershell -ExecutionPolicy Bypass -File .\seren-observatory-setup.ps1 -Service
#    powershell -ExecutionPolicy Bypass -File .\seren-observatory-setup.ps1 -Wheel .\seren_observatory-0.1.0-py3-none-any.whl
#    powershell -ExecutionPolicy Bypass -File .\seren-observatory-setup.ps1 -Local D:\serenDaemon\SerenCore\.dev-wheelhouse   # dev builds from seren-dev-publish.ps1
#    powershell -ExecutionPolicy Bypass -File .\seren-observatory-setup.ps1 -NoUpdates  # turn update checking off
# ══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]    $Port      = 7777,
  [string] $ObsHost   = "0.0.0.0",
  [string] $Token     = "",
  [switch] $GenToken,
  [string] $Wheel     = "",
  [string] $Local     = "",
  [string] $Ref       = "",
  [string] $Repo      = "ChadRoesler/SerenObservatory",
  [switch] $Service,
  [switch] $NoUpdates,
  # -- service identity (only meaningful alongside -Service) -------------------
  # Forwarded to the NSSM wrapper. The password is NOT a parameter - it rides
  # in $env:SEREN_SERVICE_PASSWORD, because on Windows a command line is
  # readable by any other process.
  [string] $ServiceUser = "",
  [switch] $LocalSystem,
  [string] $Instance  = "",
  # Starwright's install root (~/seren/<install>): venvs, apps, stores, logs
  # under one folder, absolute paths. Empty = the old layout.
  [string] $Root      = "",
  [string] $VenvDir   = "",
  [switch] $Describe,   # print service metadata as JSON and exit (no side effects)
  [switch] $Json        # stream JSON Lines events on stdout; humans go to stderr
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

# -- locate a file by walking UP the tree (reorg-robust; injected by fixup) ---
function Find-Upward {
    param([Parameter(Mandatory)] [string] $Rel, [string] $Start = $PSScriptRoot)
    $dir = $Start
    while ($dir) {
        $candidate = Join-Path $dir $Rel
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
        $parent = Split-Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

# -- source the shared installer library ---------------------------------------
$lib = Find-Upward "services\lib\seren-install-lib.ps1"
if (-not $lib) { Write-Host "ERROR: seren-install-lib.ps1 not found. Keep services/lib/ with shared scripts." -ForegroundColor Red; exit 1 }
. $lib


# -- Starwright contracts -----------------------------------------------------
# -Describe answers with ZERO side effects, so it runs before anything else.
if ($Describe) {
    $describeArgs = @{
        ScriptPath  = $PSCommandPath
        Name        = 'seren-observatory'
        Display     = 'Seren Observatory'
        Description = 'The insight into the node'
        Group       = 'core'
        Package     = 'seren-observatory'
        Accent      = '#f59056'
        DefaultHost = $ObsHost
        DefaultPort = $Port
    }
    Get-SerenDescribe @describeArgs
    exit 0
}
if ($Json) { Enable-SerenJson }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\observatory" }
$layout  = Get-SerenLayout -Root $Root -Short "observatory" -Instance $Instance -VenvDir $VenvDir -AppDir "$env:USERPROFILE\seren-observatory"
$VenvDir = $layout.Venv
$AppDir  = $layout.App
$CfgPath = "$AppDir\seren-observatory.yaml"
$global:Instance = $Instance
if ($Instance -and $Port -eq 7777) {
  Warn "Instance '$Instance' uses default port 7777 - may collide."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenObservatory setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find Python ------------------------------------------------------------
$pyInfo = Find-Python
$global:pyInfo = $pyInfo

# -- 2. resolve wheel (observatory uses -Repo by default, not PyPI) ------------
$wr = Resolve-Wheel -Wheel $Wheel -Local $Local -Ref $Ref -Repo $Repo -Package "seren-observatory"

# -- 3. venv + install (no extras) ---------------------------------------------
$vpy = Create-Venv -VenvDir $VenvDir -PyExe $pyInfo.Exe -PyArgs $pyInfo.Args
$Mcp = $false; $Corp = $false  # observatory has no extras
$extras = Get-Extras-Suffix
Install-Package -Vpy $vpy -WheelSrc $wr.Src -Extras $extras -Label ""
if ($wr.Cleanup) { Remove-Item -Force $wr.Src -ErrorAction SilentlyContinue }

# -- 4. sanity check -----------------------------------------------------------
Sanity-Check -Vpy $vpy -Module "seren_observatory" -AssetRelPath "viewer/ui/body.html" -AssetLabel "viewer"

# -- 5. config ------------------------------------------------------------------
Step "Writing config at $CfgPath"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if (Test-Path $CfgPath) {
  $bak = "$CfgPath.bak.$([int][double]::Parse((Get-Date -UFormat %s)))"
  Copy-Item $CfgPath $bak; Warn "Backed up to $(Split-Path $bak -Leaf)"
}
if ($GenToken) { $Token = & $vpy -c "import secrets; print(secrets.token_urlsafe(32))" }
@"
# SerenObservatory config - generated by seren-observatory-setup.ps1
# The bearer TOKEN is NOT here - it's a safety interlock in
# ~/.seren/secrets.json ({"observatory_token": "..."}), written by this
# installer when -Token / -GenToken is given.
server:
  host: $ObsHost
  port: $Port$(if ($layout.Data) { "`n  secrets_path: '$($layout.Data)\secrets.json'" })
"@ | Write-SerenTextFile -Path $CfgPath
Ok "Config written"

# The token goes where the observatory reads it: ~/.seren/secrets.json. There
# was no way to provide one from this card before, and no seren-secrets tool
# exists, so a Windows observatory always failed closed on its management
# endpoints. Merged into the file if one is already there.
$SecretsFile = Join-Path $env:USERPROFILE ".seren\secrets.json"
# Under an install root the token lives in the root's store and the config
# names it (server.secrets_path): a second cluster's observatory on this box
# has its own, and nothing depends on whose profile the service runs in.
if ($layout.Data) { $SecretsFile = Join-Path $layout.Data "secrets.json" }
if ($Token) {
  $secretsDir = Split-Path $SecretsFile -Parent
  New-Item -ItemType Directory -Force -Path $secretsDir | Out-Null
  $data = @{}
  if (Test-Path $SecretsFile) {
    try {
      $obj = Get-Content $SecretsFile -Raw | ConvertFrom-Json
      foreach ($prop in $obj.PSObject.Properties) { $data[$prop.Name] = $prop.Value }
    } catch { $data = @{} }
  }
  $data["observatory_token"] = $Token
  ($data | ConvertTo-Json) | Write-SerenTextFile -Path $SecretsFile
  # Lock the file to the current user: the NTFS equivalent of chmod 600.
  try {
    icacls $SecretsFile /inheritance:r /grant:r "${env:USERNAME}:(R,W)" | Out-Null
    # ...and to the account the SERVICE runs as. Locking it to the installer
    # alone also locked out SYSTEM, so an observatory running as LocalSystem
    # could not read its own token and failed closed (26 Sept 2026).
    if ($LocalSystem) { icacls $SecretsFile /grant:r "SYSTEM:(R)" | Out-Null }
    elseif ($ServiceUser -and $ServiceUser -ne $env:USERNAME) { icacls $SecretsFile /grant:r "${ServiceUser}:(R)" | Out-Null }
  } catch { Warn "could not restrict ACLs on $SecretsFile - do it by hand" }
  if (-not $layout.Data -and -not $LocalSystem -and $ServiceUser -and $ServiceUser -ne $env:USERNAME) {
    Warn "The service runs as $ServiceUser; copy $SecretsFile into that account's profile (.seren\secrets.json)"
  }
  Ok "Token written to $SecretsFile - the management endpoints are armed"
}

if ($NoUpdates) {
    # Update checking is ON by default across the Seren family: it asks the
    # package index whether a newer release exists and reports it on the info
    # route. It NEVER upgrades anything. -NoUpdates writes the off switch.
    @"

# ── Update checking ───────────────────────────────────────────────────
# Turned OFF at install time by -NoUpdates. Flip to true to re-enable, or set
# SEREN_<SERVICE>_UPDATES_ENABLED=true in the service environment.
updates:
  enabled: false
"@ | Add-SerenTextFile -Path $CfgPath
    Ok "Update checking disabled in config"
}

# -- 5b. launcher ---------------------------------------------------------------
$launcher = Write-Launcher -AppDir $AppDir -ServiceName "seren-observatory" -Vpy $vpy -Module "seren_observatory" -CfgPath $CfgPath

# -- 6. optional autostart ------------------------------------------------------
if ($Service) { Setup-Autostart -ScriptDir $ScriptDir -ServiceName "seren-observatory" -AppDir $AppDir -Token $Token -VenvDir $VenvDir -ServiceUser $ServiceUser -LocalSystem:$LocalSystem }

# -- done -----------------------------------------------------------------------
$connectHost = if ($ObsHost -eq "0.0.0.0") { "127.0.0.1" } else { $ObsHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenObservatory is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) {
  Write-Host "  Start it:        $launcher" -ForegroundColor Blue
}
Write-Host "  Ping:            http://${connectHost}:$Port/api/v1/system/ping" -ForegroundColor Blue
Write-Host ""
if ($Token) {
  Write-Host "  Bearer token:    $Token   (in $SecretsFile)" -ForegroundColor Yellow
} else {
  Write-Host "  No token: the observatory FAILS CLOSED on start/stop/reboot until one exists." -ForegroundColor Yellow
  Write-Host "  Re-run with -GenToken, or write $SecretsFile as {`"observatory_token`": `"...`"}" -ForegroundColor Yellow
}
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green

# -- Starwright contract: structured completion event -------------------------
# Human banner above, machine-readable twin here. No-op without -Json.
$doneArgs = @{
    Service     = 'seren-observatory'
    ConnectHost = $connectHost
    Port        = $Port
    Autostart   = ([bool] $Service)
    Token       = $Token
    Mcp         = ([bool] $Mcp)
    Corp        = ([bool] $Corp)
    Vector      = $false
    Venv        = $VenvDir
    Config      = $CfgPath
}
Send-SerenDone @doneArgs
