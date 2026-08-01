<#
# ══════════════════════════════════════════════════════════════════════════
#  seren-lodestar-setup.ps1  -  one-shot SerenLodestar installer (Windows)
#
#  Refactored to dot-source seren-install-lib.ps1 (shared installer library).
#  Identity lines + config are the only unique parts.
#
#  USAGE (same flags as before)
#    powershell -ExecutionPolicy Bypass -File .\seren-lodestar-setup.ps1
#    powershell -ExecutionPolicy Bypass -File .\seren-lodestar-setup.ps1 -Service
#    powershell -ExecutionPolicy Bypass -File .\seren-lodestar-setup.ps1 -Wheel .\seren_lodestar-0.1.0-py3-none-any.whl
#    powershell -ExecutionPolicy Bypass -File .\seren-lodestar-setup.ps1 -Mcp -Corp
#    powershell -ExecutionPolicy Bypass -File .\seren-lodestar-setup.ps1 -Updates   # update checking
# ══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]    $Port     = 6361,
  [string] $LodeHost = "0.0.0.0",
  [string] $Token    = "",
  [switch] $GenToken,
  [string] $Wheel    = "",
  [string] $Ref      = "",
  [string] $Repo     = "",
  [switch] $Service,
  [switch] $Mcp,
  [switch] $Corp,
  [switch] $Updates,
  [string] $Instance = "",
  [string] $VenvDir  = "",
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
        Name        = 'seren-lodestar'
        Display     = 'Seren Lodestar'
        Description = 'Management plane for nodes and orchestration'
        Group       = 'core'
        Package     = 'seren-lodestar'
        Accent      = '#F5D76E'
        DefaultHost = $LodeHost
        DefaultPort = $Port
        Extras      = @('corp','updates')
    }
    Get-SerenDescribe @describeArgs
    exit 0
}
if ($Json) { Enable-SerenJson }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\lodestar" }
$VenvDir = "$VenvDir$Instance"
$AppDir  = "$env:USERPROFILE\seren-lodestar$Instance"
$CfgPath = "$AppDir\seren-lodestar.yaml"
$global:Instance = $Instance
if ($Instance -and $Port -eq 6361) {
  Warn "Instance '$Instance' uses default port 6361 — may collide."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenLodestar setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find Python ------------------------------------------------------------
$pyInfo = Find-Python
$global:pyInfo = $pyInfo

if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenLodestar" }

# -- 2. resolve wheel ----------------------------------------------------------
$wr = Resolve-Wheel -Wheel $Wheel -Ref $Ref -Repo $Repo -Package "seren-lodestar"

# -- 3. venv + install ----------------------------------------------------------
$vpy = Create-Venv -VenvDir $VenvDir -PyExe $pyInfo.Exe -PyArgs $pyInfo.Args
# NOTE: no -Mcp here - mcp is a CORE dependency of this package, not an
# extra. Asking pip for [mcp] only earns a "does not provide the extra"
# warning. -Mcp is still accepted so existing scripts keep working.
if ($Mcp) { Write-Host "  ! -Mcp is unnecessary: the MCP SDK is a core dependency here" -ForegroundColor Yellow }
$extras = Get-Extras-Suffix -Corp:$Corp -Updates:$Updates
Install-Package -Vpy $vpy -WheelSrc $wr.Src -Extras $extras -Label " ($(if ($Mcp) { ' + MCP SDK' } else { '' })$(if ($Corp) { ' + truststore' } else { '' }))"
if ($wr.Cleanup) { Remove-Item -Force $wr.Src -ErrorAction SilentlyContinue }

# -- 4. sanity check -----------------------------------------------------------
Sanity-Check -Vpy $vpy -Module "seren_lodestar" -AssetRelPath "viewer/ui/body.html" -AssetLabel "viewer"

# -- 5. config ------------------------------------------------------------------
Step "Writing config at $CfgPath"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if ($GenToken) { $Token = & $vpy -c "import secrets; print(secrets.token_urlsafe(32))" }
if (Test-Path $CfgPath) {
  $bak = "$CfgPath.bak.$([int][double]::Parse((Get-Date -UFormat %s)))"
  Copy-Item $CfgPath $bak; Warn "Backed up to $(Split-Path $bak -Leaf)"
}
$tlsBlock = if ($Corp) { "`ntls:`n  trust_system_store: true" } else { "" }
@"
# SerenLodestar config - generated by seren-lodestar-setup.ps1
# Full reference: see seren-lodestar.yaml.sample in the repo.
server:
  host: $LodeHost
  port: $Port
  bearer_token: "$Token"

runtime:
  inject_bearer_token: true$tlsBlock
"@ | Set-Content -Path $CfgPath -Encoding UTF8
if ($Token) { & $vpy -c "import os,stat; os.chmod('$CfgPath', 0o600)" 2>$null }
Ok "Config written"

# -- 5b. launcher ---------------------------------------------------------------
$launcher = Write-Launcher -AppDir $AppDir -ServiceName "seren-lodestar" -Vpy $vpy -Module "seren_lodestar" -CfgPath $CfgPath

# -- 6. optional autostart ------------------------------------------------------
if ($Service) {
  if ($Token) { "$Token" | Out-File -FilePath "$AppDir\seren-lodestar.env" -Encoding UTF8 }
  Setup-Autostart -ScriptDir $ScriptDir -ServiceName "seren-lodestar" -AppDir $AppDir -Token $Token -VenvDir $VenvDir
}

# -- done -----------------------------------------------------------------------
$connectHost = if ($LodeHost -eq "0.0.0.0") { "127.0.0.1" } else { $LodeHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenLodestar is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) { Write-Host "  Start it:        $launcher" -ForegroundColor Blue }
Write-Host "  Cluster head:    http://${connectHost}:$Port/viewer" -ForegroundColor Blue
if ($Token) { Write-Host "  Bearer token:    $Token" -ForegroundColor Yellow }
if ($Mcp)   { Write-Host "  MCP endpoint:    http://${connectHost}:$Port/mcp/" -ForegroundColor Blue }
if ($Corp)  { Write-Host "  TLS:             OS trust store" -ForegroundColor Blue }
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green

# -- Starwright contract: structured completion event -------------------------
# Human banner above, machine-readable twin here. No-op without -Json.
$doneArgs = @{
    Service     = 'seren-lodestar'
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
