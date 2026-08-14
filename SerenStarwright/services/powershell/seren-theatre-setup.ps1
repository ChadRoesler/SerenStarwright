<#
# ══════════════════════════════════════════════════════════════════════════
#  seren-theatre-setup.ps1  -  one-shot SerenTheatre installer (Windows)
#
#  Dot-sources seren-install-lib.ps1 (shared installer library). Identity
#  lines, config, the -Stage convenience and the local-build-from-repo
#  default are the unique parts.
#
#  Theatre is the closest sibling to Margin: localhost-only, no bearer token,
#  no MCP surface, requires nothing. Two things it has that Margin doesn't:
#  a STAGE (a directory to watch) and the [stagehand] extra.
#
#  USAGE
#    powershell -ExecutionPolicy Bypass -File .\seren-theatre-setup.ps1
#    powershell -ExecutionPolicy Bypass -File .\seren-theatre-setup.ps1 -Pypi
#    powershell -ExecutionPolicy Bypass -File .\seren-theatre-setup.ps1 -Service
#    powershell -ExecutionPolicy Bypass -File .\seren-theatre-setup.ps1 -Stage D:\fraunkensteinLab
#    powershell -ExecutionPolicy Bypass -File .\seren-theatre-setup.ps1 -Stagehand
#    powershell -ExecutionPolicy Bypass -File .\seren-theatre-setup.ps1 -NoUpdates
#
#  ON THE PORT: 7427, not 7426. 7426 belongs to SerenSymposium's loopback UI
#  shim. Symposium is localhost-only so it isn't in the `seren/port-map` fact,
#  which is exactly why the first pick collided with it.
# ══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]      $Port        = 7427,
  # 127.0.0.1 on purpose. Training logs carry absolute paths, hostnames and
  # the occasional corpus snippet - not something to put on the LAN by
  # accident. Widen it yourself, deliberately, if you mean to.
  [string]   $TheatreHost = "127.0.0.1",
  # Repeatable. Each becomes a stages: entry in the generated config, so a
  # fresh install lands on something real instead of an empty room.
  [string[]] $Stage       = @(),
  [string]   $Wheel       = "",
  [string]   $Ref         = "",
  [string]   $Repo        = "",
  [string]   $RepoDir     = "",
  [switch]   $Pypi,
  # The ONE extra. Pulls the ms-moe CLI so this box can START builds, not just
  # watch them. Opt-in on purpose: watching a run has never required being
  # able to start one, so a plain install stays a viewer and nothing more.
  [switch]   $Stagehand,
  [switch]   $NoUpdates,
  # -- service identity (only meaningful alongside -Service) -------------------
  # Forwarded to the NSSM wrapper. The password is NOT a parameter - it rides
  # in $env:SEREN_SERVICE_PASSWORD, because on Windows a command line is
  # readable by any other process.
  [string]   $ServiceUser = "",
  [switch]   $LocalSystem,
  [switch]   $Service,
  [string]   $Instance    = "",
  [string]   $VenvDir     = ""
,
  [switch]   $Describe,   # print service metadata as JSON and exit (no side effects)
  [switch]   $Json        # stream JSON Lines events on stdout; humans go to stderr
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
#
# Extras is passed EXPLICITLY. Get-SerenDescribe derives extras by filtering
# the parsed parameters through a family-wide allowlist of mcp|corp|vector,
# which is correct for the eight services that shipped before this one and
# structurally cannot know about a new extra. Left to derive, -Describe would
# advertise extras:[] while -Stagehand quietly worked, so Starwright would
# never offer the checkbox for something the installer supports. The -Extras
# override is the documented escape hatch.
if ($Describe) {
    $describeArgs = @{
        ScriptPath  = $PSCommandPath
        Name        = 'seren-theatre'
        Display     = 'Seren Theatre'
        Description = 'Watch a model being made. Read-only viewer over training logs and artifacts.'
        Group       = 'auxiliary'
        Package     = 'seren-theatre'
        # Every other service in the constellation gets a colour. The theatre
        # gets the house lights down.
        Accent      = '#171717'
        DefaultHost = $TheatreHost
        DefaultPort = $Port
        Extras      = @('stagehand')
    }
    Get-SerenDescribe @describeArgs
    exit 0
}
if ($Json) { Enable-SerenJson }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\theatre" }
$VenvDir = "$VenvDir$Instance"
$AppDir  = "$env:USERPROFILE\seren-theatre$Instance"
$CfgPath = "$AppDir\seren-theatre.yaml"
$global:Instance = $Instance
if ($Instance -and $Port -eq 7427) {
  Warn "Instance '$Instance' uses default port 7427 — may collide."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenTheatre setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find Python (3.10-3.12) -----------------------------------------------
$pyInfo = Find-Python
$global:pyInfo = $pyInfo

if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenTheatre" }

# -- 2. resolve what to install ------------------------------------------------
# Precedence: -Wheel > -Repo/-Ref (GitHub) > -Pypi > local build (default)
$wheelSrc = $null
$cleanupWheel = $false
$pyExe = $pyInfo.Exe
$pyArgs = $pyInfo.Args
if ($Wheel) {
  if (-not (Test-Path $Wheel)) { Die "wheel not found: $Wheel" }
  $wheelSrc = (Resolve-Path $Wheel).Path
  Ok "Installing from local wheel: $(Split-Path $wheelSrc -Leaf)"
} elseif ($Repo) {
  $wr = Resolve-Wheel -Wheel $Wheel -Ref $Ref -Repo $Repo -Package "seren-theatre"
  $wheelSrc = $wr.Src
  $cleanupWheel = $wr.Cleanup
} elseif ($Pypi) {
  $wheelSrc = "seren-theatre"
  Ok "Installing the latest seren-theatre from PyPI"
} else {
  # DEFAULT: build a wheel from the repo checkout.
  Step "Building a wheel from the SerenTheatre checkout"
  if (-not $RepoDir) { $RepoDir = Find-Upward "SerenTheatre" }
  $pkgDir = Join-Path $RepoDir "SerenTheatre"
  if (-not (Test-Path (Join-Path $pkgDir "pyproject.toml"))) {
    Die "SerenTheatre checkout not found at $pkgDir. Use -RepoDir, -Wheel, -Pypi, or -Ref."
  }
  $buildVenv = Join-Path ([System.IO.Path]::GetTempPath()) "build-venv-theatre"
  & $pyExe $pyArgs -m venv $buildVenv
  & "$buildVenv\Scripts\pip" install -q --upgrade pip build
  Remove-Item -Force (Join-Path $pkgDir "dist\*.whl") -ErrorAction SilentlyContinue
  & "$buildVenv\Scripts\python" -m build --wheel $pkgDir
  Remove-Item -Recurse -Force $buildVenv -ErrorAction SilentlyContinue
  $wheelSrc = Get-ChildItem (Join-Path $pkgDir "dist\*.whl") | Select-Object -First 1
  if (-not $wheelSrc) { Die "build completed but no wheel in $pkgDir\dist\" }
  $wheelSrc = $wheelSrc.FullName
  Ok "Built $(Split-Path $wheelSrc -Leaf)"
}

# -- 3. venv + install ---------------------------------------------------------
# NOT Get-Extras-Suffix: that helper only knows mcp/corp/vector, for the same
# family-wide-allowlist reason -Describe needed an override. Built by hand here.
$vpy = Create-Venv -VenvDir $VenvDir -PyExe $pyExe -PyArgs $pyArgs
$extras = if ($Stagehand) { "[stagehand]" } else { "" }
Install-Package -Vpy $vpy -WheelSrc $wheelSrc -Extras $extras -Label "$(if ($Stagehand) { ' + the ms-moe CLI' } else { '' })"
if ($cleanupWheel) { Remove-Item -Force $wheelSrc -ErrorAction SilentlyContinue }

# -- 4. sanity check -----------------------------------------------------------
# The viewer PACK, not a manifest: Theatre renders /viewer from five files the
# SerenMeninges shell assembles, and they ship only because pyproject declares
# them as package-data. Miss that declaration and the wheel installs perfectly
# while /viewer 500s - so the asset is exactly the right thing to check for.
# FORWARD SLASHES, and not as a style choice. Sanity-Check interpolates this
# straight into a single-quoted PYTHON string literal, where "viewer\ui\..."
# makes \u start a unicode escape and the whole check dies of SyntaxError -
# reported as "Install looks broken" on a perfectly good install. Every sibling
# passes forward slashes; pathlib resolves them fine on Windows.
Sanity-Check -Vpy $vpy -Module "seren_theatre" -AssetRelPath "viewer/ui/body.html" -AssetLabel "viewer pack"

# -- 5. config --------------------------------------------------------------
Step "Writing config at $CfgPath"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if (Test-Path $CfgPath) {
  $bak = "$CfgPath.bak.$([int][double]::Parse((Get-Date -UFormat %s)))"
  Copy-Item $CfgPath $bak
  Warn "Existing config backed up to $(Split-Path $bak -Leaf)"
}
@"
# SerenTheatre config - generated by seren-theatre-setup.ps1
# Full reference: see seren-theatre.yaml.sample in the repo.
server:
  # 127.0.0.1 on purpose. Training logs carry absolute paths, hostnames and
  # the occasional corpus snippet - not for the LAN by accident.
  host: $TheatreHost
  port: $Port

# Only the tail of each log is ever read. The dashboard must never be the
# reason the box is busy.
tail_bytes: 262144
refresh_seconds: 5
"@ | Write-SerenTextFile -Path $CfgPath

if ($Stage.Count -gt 0) {
    $block = "`nstages:`n"
    foreach ($s in $Stage) {
        $leaf = Split-Path $s -Leaf
        $block += "  - name: $leaf`n"
        $block += "    path: $s`n"
        $block += "    logs: [`"*.log`"]`n"
        $block += "    rungs: [`"dryrun_*`", `"*_agent_*`"]`n"
    }
    $block | Add-SerenTextFile -Path $CfgPath
    Ok "Config written with $($Stage.Count) stage(s)"
} else {
    @"

# No stages yet - the room is empty, which is a true reading, not an error.
# A stage is just a directory; add one and restart:
# stages:
#   - name: FraunkensteinsLab
#     path: D:\fraunkensteinLab
stages: []
"@ | Add-SerenTextFile -Path $CfgPath
    Ok "Config written (no stages - pass -Stage PATH, or edit the file)"
}

if ($NoUpdates) {
    # Update checking is ON by default across the Seren family: it asks the
    # package index whether a newer release exists and reports it on the info
    # route. It NEVER upgrades anything. -NoUpdates writes the off switch.
    @"

# ── Update checking ───────────────────────────────────────────────────
# Turned OFF at install time by -NoUpdates. Flip to true to re-enable, or set
# SEREN_THEATRE_UPDATES_ENABLED=true in the service environment.
updates:
  enabled: false
"@ | Add-SerenTextFile -Path $CfgPath
    Ok "Update checking disabled in config"
}

# -- 5b. launcher -----------------------------------------------------------
$launcher = Write-Launcher -AppDir $AppDir -ServiceName "seren-theatre" -Vpy $vpy -Module "seren_theatre" -CfgPath $CfgPath

# -- 6. optional autostart ----------------------------------------------------
if ($Service) { Setup-Autostart -ScriptDir $ScriptDir -ServiceName "seren-theatre" -AppDir $AppDir -Token "" -VenvDir $VenvDir -ServiceUser $ServiceUser -LocalSystem:$LocalSystem }

# -- done -------------------------------------------------------------------
$connectHost = if ($TheatreHost -eq "0.0.0.0") { "127.0.0.1" } else { $TheatreHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenTheatre is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) {
  Write-Host "  Start it:        $launcher" -ForegroundColor Blue
}
Write-Host "  Viewer:          http://${connectHost}:$Port/viewer" -ForegroundColor Blue
Write-Host "  State (JSON):    http://${connectHost}:$Port/api/state" -ForegroundColor Blue
Write-Host "  Health:          http://${connectHost}:$Port/health" -ForegroundColor Blue
Write-Host ""
if ($Stagehand) {
  Write-Host "  Stagehand:       $VenvDir\Scripts\seren-theatre-stagehand.exe --check" -ForegroundColor Blue
  Write-Host "  Start a build:   $VenvDir\Scripts\seren-theatre-stagehand.exe recipe.yaml" -ForegroundColor Blue
  Write-Host "  Stagehand is a COMMAND, not a button. The service exposes no" -ForegroundColor Yellow
  Write-Host "  write route - a stagehand is not on stage." -ForegroundColor Yellow
  Write-Host ""
}
if ($Stage.Count -eq 0) {
  Write-Host "  No stages configured yet - the room is empty. Add one to" -ForegroundColor Yellow
  Write-Host "  $CfgPath, or try a one-off:" -ForegroundColor Yellow
  Write-Host "  `$env:SEREN_THEATRE_STAGE='D:\lab'; & $vpy -m seren_theatre" -ForegroundColor Blue
  Write-Host ""
}
Write-Host "  Read-only by construction. A theatre cannot perturb the thing on the table." -ForegroundColor Yellow
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green

# -- Starwright contract: structured completion event -------------------------
# Human banner above, machine-readable twin here. No-op without -Json.
$doneArgs = @{
    Service     = 'seren-theatre'
    ConnectHost = $connectHost
    Port        = $Port
    Autostart   = ([bool] $Service)
    Token       = ""
    Mcp         = $false
    Corp        = $false
    Vector      = $false
    Venv        = $VenvDir
    Config      = $CfgPath
}
Send-SerenDone @doneArgs
