<#
# ══════════════════════════════════════════════════════════════════════════
#  seren-loci-setup.ps1  -  one-shot SerenLoci installer (Windows)
#
#  Refactored to dot-source seren-install-lib.ps1 (shared installer library).
#  Identity lines + config + --Vector flag are the unique parts.
#
#  USAGE (same flags as before)
#    powershell -ExecutionPolicy Bypass -File .\seren-loci-setup.ps1
#    powershell -ExecutionPolicy Bypass -File .\seren-loci-setup.ps1 -GenToken -Service
#    powershell -ExecutionPolicy Bypass -File .\seren-loci-setup.ps1 -Wheel .\seren_loci-0.1.0-py3-none-any.whl
#    powershell -ExecutionPolicy Bypass -File .\seren-loci-setup.ps1 -Mcp -Vector -Corp
#    powershell -ExecutionPolicy Bypass -File .\seren-loci-setup.ps1 -NoUpdates  # turn update checking off
# ══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]    $Port      = 7422,
  [string] $LociHost = "127.0.0.1",
  [string] $Token     = "",
  [switch] $GenToken,
  [string] $Wheel     = "",
  [string] $Ref       = "",
  [string] $Repo      = "",
  [switch] $Service,
  [switch] $Mcp,
  [switch] $Corp,
  [switch] $NoUpdates,
  # -- service identity (only meaningful alongside -Service) -------------------
  # Forwarded to the NSSM wrapper. The password is NOT a parameter - it rides
  # in $env:SEREN_SERVICE_PASSWORD, because on Windows a command line is
  # readable by any other process.
  [string] $ServiceUser = "",
  [switch] $LocalSystem,
  [switch] $Vector,
  [string] $Instance  = "",
  [string] $VenvDir   = "",
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
        Name        = 'seren-loci'
        Display     = 'Seren Loci'
        Description = 'Fact store for memory'
        Group       = 'brain'
        Package     = 'seren-loci'
        Accent      = '#5bc8e8'
        DefaultHost = $LociHost
        DefaultPort = $Port
    }
    Get-SerenDescribe @describeArgs
    exit 0
}
if ($Json) { Enable-SerenJson }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\loci" }
$VenvDir = "$VenvDir$Instance"
$AppDir  = "$env:USERPROFILE\seren-loci$Instance"
$CfgPath = "$AppDir\seren-loci.yaml"
$global:Instance = $Instance
if ($Instance -and $Port -eq 7422) {
  Warn "Instance '$Instance' uses default port 7422 — may collide."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenLoci setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find Python (3.10-3.12; torch in [vector] needs 3.12 at most) ---------
$pyInfo = Find-Python
$global:pyInfo = $pyInfo

if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenLoci" }

# -- 2. resolve wheel ----------------------------------------------------------
$wr = Resolve-Wheel -Wheel $Wheel -Ref $Ref -Repo $Repo -Package "seren-loci"

# -- 3. venv + install ---------------------------------------------------------
$vpy = Create-Venv -VenvDir $VenvDir -PyExe $pyInfo.Exe -PyArgs $pyInfo.Args
$extras = Get-Extras-Suffix -Mcp:$Mcp -Corp:$Corp -Vector:$Vector
Install-Package -Vpy $vpy -WheelSrc $wr.Src -Extras $extras -Label " (web stack$(if ($Vector) { ' + sqlite-vec + sentence-transformers/torch' } else { '' })$(if ($Mcp) { ' + MCP SDK' } else { '' })$(if ($Corp) { ' + truststore' } else { '' }))"
if ($wr.Cleanup) { Remove-Item -Force $wr.Src -ErrorAction SilentlyContinue }

# -- 4. sanity check (import + viewer/loci.html) -----------------------------
Sanity-Check -Vpy $vpy -Module "seren_loci" -AssetRelPath "viewer/ui/body.html" -AssetLabel "viewer"

# -- 5. config --------------------------------------------------------------
Step "Writing config at $CfgPath"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if ($GenToken) { $Token = & $vpy -c "import secrets; print(secrets.token_urlsafe(32))" }
if (Test-Path $CfgPath) {
  $bak = "$CfgPath.bak.$([int][double]::Parse((Get-Date -UFormat %s)))"
  Copy-Item $CfgPath $bak
  Warn "Existing config backed up to $(Split-Path $bak -Leaf)"
}
$dbInstance = $Instance
$vectorBlock = if ($Vector) {
  "`n  # Vector finder ON (--Vector). Comment these out for embedding-free floor.`n  embedding_model: sentence-transformers/all-MiniLM-L6-v2`n  embedding_device: cpu"
} else { "" }
$tlsBlock = if ($Corp) {
  "`ntls:`n  trust_system_store: true"
} else { "" }
@"
# SerenLoci config - generated by seren-loci-setup.ps1
# Full reference: see seren-loci.yaml.sample in the repo.
server:
  host: $LociHost
  port: $Port
  bearer_token: "$Token"

storage:
  db_path: ~/.seren-loci$dbInstance/loci.db$vectorBlock$tlsBlock
"@ | Write-SerenTextFile -Path $CfgPath
Ok "Config written"

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

# -- 5b. launcher -----------------------------------------------------------
$launcher = Write-Launcher -AppDir $AppDir -ServiceName "seren-loci" -Vpy $vpy -Module "seren_loci" -CfgPath $CfgPath

# -- 6. optional autostart ----------------------------------------------------
if ($Service) { Setup-Autostart -ScriptDir $ScriptDir -ServiceName "seren-loci" -AppDir $AppDir -Token $Token -VenvDir $VenvDir -ServiceUser $ServiceUser -LocalSystem:$LocalSystem }

# -- done -------------------------------------------------------------------
$connectHost = if ($LociHost -eq "0.0.0.0") { "127.0.0.1" } else { $LociHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenLoci is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) {
  Write-Host "  Start it:        $launcher" -ForegroundColor Blue
}
Write-Host "  Viewer:          http://${connectHost}:$Port/viewer" -ForegroundColor Blue
Write-Host "  VSCode plugin:   set serenLoci.endpoint to http://${connectHost}:$Port" -ForegroundColor Blue
if ($Token) { Write-Host "  Bearer token:    $Token" -ForegroundColor Yellow }
if ($Mcp)    { Write-Host "  MCP endpoint:    http://${connectHost}:$Port/mcp/" -ForegroundColor Blue }
if ($Vector) { Write-Host "  Finder:          vector (sqlite-vec + all-MiniLM-L6-v2)" -ForegroundColor Blue }
if ($Corp)   { Write-Host "  TLS:             OS trust store" -ForegroundColor Blue }
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green

# -- Starwright contract: structured completion event -------------------------
# Human banner above, machine-readable twin here. No-op without -Json.
$doneArgs = @{
    Service     = 'seren-loci'
    ConnectHost = $connectHost
    Port        = $Port
    Autostart   = ([bool] $Service)
    Token       = $Token
    Mcp         = ([bool] $Mcp)
    Corp        = ([bool] $Corp)
    Vector      = ([bool] $Vector)
    Venv        = $VenvDir
    Config      = $CfgPath
}
Send-SerenDone @doneArgs
