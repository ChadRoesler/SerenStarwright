<#
# ══════════════════════════════════════════════════════════════════════════
#  seren-kitchen-setup.ps1  -  one-shot SerenKitchen installer (Windows)
#
#  Dot-sources seren-install-lib.ps1 (shared installer library). The identity
#  lines and the state folder are the unique parts: everything a house decides
#  after moving in (fonts, the GitHub token, which fridges, whose names) is set
#  from the kitchen's own page and kept in its state folder, never here. Twin
#  of seren-kitchen-setup.sh.
#
#  The kitchen is the shared board of a house: a fridge per app in its own
#  colour, magnets for whoever holds a repo, and the sheets we leave each
#  other. Loopback by default; a wider bind needs a bearer or the kitchen
#  refuses to start.
#
#  USAGE
#    powershell -ExecutionPolicy Bypass -File .\seren-kitchen-setup.ps1 -Pypi -Service
#    powershell -ExecutionPolicy Bypass -File .\seren-kitchen-setup.ps1 -Root C:\seren\home -Instance home -Pypi -KitchenHost 0.0.0.0 -GenToken -Service
# ══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]    $Port            = 7431,
  [string] $KitchenHost     = "127.0.0.1",
  [string] $Token           = "",
  [switch] $GenToken,
  [string] $StateDir        = "",
  [string] $RepoDir         = "",
  [string] $Wheel           = "",
  [string] $Local           = "",
  [switch] $Pypi,
  [string] $Ref             = "",
  [string] $Repo            = "",
  [switch] $Service,
  [string] $ServiceUser     = "",
  [switch] $NoUpdates,
  [string] $Instance        = "",
  [string] $Root            = "",
  [string] $VenvDir         = "",
  [switch] $Describe,   # print service metadata as JSON and exit (no side effects)
  [switch] $Json        # stream JSON Lines events on stdout; humans go to stderr
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

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

$lib = Find-Upward "services\lib\seren-install-lib.ps1"
if (-not $lib) { Write-Host "ERROR: seren-install-lib.ps1 not found. Keep services/lib/ with shared scripts." -ForegroundColor Red; exit 1 }
. $lib

# -- Starwright contract: identity (same values as the bash card and seren_kitchen/_describe.py)
if ($Describe) {
    $describeArgs = @{
        ScriptPath  = $PSCommandPath
        Name        = 'seren-kitchen'
        Display     = 'Seren Kitchen'
        Description = "The kitchen: a fridge per Seren app, magnets for whoever holds it, and the notes we leave each other"
        Group       = 'auxiliary'
        Package     = 'seren-kitchen'
        Accent      = '#e0514b'
        DefaultHost = $KitchenHost
        DefaultPort = $Port
        ConfigKeys  = @{ 'state-dir' = 'state_dir' }
    }
    Get-SerenDescribe @describeArgs
    exit 0
}
if ($Json) { Enable-SerenJson }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\kitchen" }
$layout  = Get-SerenLayout -Root $Root -Short "kitchen" -Instance $Instance -VenvDir $VenvDir -AppDir "$env:USERPROFILE\seren-kitchen"
$VenvDir = $layout.Venv
$AppDir  = $layout.App
$CfgPath = "$AppDir\seren-kitchen.yaml"
if (-not $StateDir) { $StateDir = if ($layout.Data) { $layout.Data } else { Join-Path $AppDir "state" } }
$global:Instance = $Instance
if ($Instance -and $Port -eq 7431) {
  Warn "Instance '$Instance' uses default port 7431 - may collide."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenKitchen setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find Python (3.10+) ---------------------------------------------------
$pyInfo = Find-Python
$global:pyInfo = $pyInfo
if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenKitchen" }

# -- 2. resolve what to install ------------------------------------------------
$wheelSrc = $null
$cleanupWheel = $false
$pyExe = $pyInfo.Exe
$pyArgs = $pyInfo.Args
if ($Wheel) {
  if (-not (Test-Path $Wheel)) { Die "wheel not found: $Wheel" }
  $wheelSrc = (Resolve-Path $Wheel).Path
  Ok "Installing from local wheel: $(Split-Path $wheelSrc -Leaf)"
} elseif ($Local -or $Repo) {
  $wr = Resolve-Wheel -Wheel $Wheel -Local $Local -Ref $Ref -Repo $Repo -Package "seren-kitchen"
  $wheelSrc = $wr.Src
  $cleanupWheel = $wr.Cleanup
} elseif ($Pypi) {
  $wheelSrc = "seren-kitchen"
  Ok "Installing the latest seren-kitchen from PyPI"
} else {
  Step "Building a wheel from the SerenKitchen checkout"
  if (-not $RepoDir) { $RepoDir = Find-Upward "SerenKitchen" }
  $pkgDir = Join-Path $RepoDir "SerenKitchen"
  if (-not (Test-Path (Join-Path $pkgDir "pyproject.toml"))) {
    Die "SerenKitchen checkout not found at $pkgDir. Use -RepoDir (git clone it beside this repo), -Wheel or -Local."
  }
  $buildVenv = Join-Path ([System.IO.Path]::GetTempPath()) "build-venv-kitchen"
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
$vpy = Create-Venv -VenvDir $VenvDir -PyExe $pyExe -PyArgs $pyArgs
Install-Package -Vpy $vpy -WheelSrc $wheelSrc -Extras "" -Label ""
if ($cleanupWheel) { Remove-Item -Force $wheelSrc -ErrorAction SilentlyContinue }

# -- 4. sanity check (import + the page) ------------------------------------
Sanity-Check -Vpy $vpy -Module "seren_kitchen" -AssetRelPath "viewer\ui" -AssetLabel "the page"

# -- 5. the state folder -------------------------------------------------------
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
Ok "Sheets, magnets, pictures, fonts and settings live in $StateDir"
Ok "Fonts, the GitHub token, the fridges and whose house it is are set from the page ('The house' tab) once it runs"

# -- 6. config --------------------------------------------------------------
Step "Writing config at $CfgPath"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if ($GenToken) { $Token = & $vpy -c "import secrets; print(secrets.token_urlsafe(32))" }
if (-not $Token -and -not $GenToken) { $Token = Get-SerenReusedToken -Path $CfgPath }
if (Test-Path $CfgPath) {
  $bak = "$CfgPath.bak.$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
  Copy-Item $CfgPath $bak; (Get-Item $bak).LastWriteTime = Get-Date
  Warn "Existing config backed up to $(Split-Path $bak -Leaf)"
}
$loopbackOnly = ($KitchenHost -match '^(127\.|localhost$|::1$)')
if (-not $loopbackOnly -and -not $Token) {
  Warn "-KitchenHost $KitchenHost with no bearer: SerenKitchen will REFUSE TO START. Re-run with -GenToken (or -Token)."
}
# A kitchen is a page people open from their own machines; a service bound to
# loopback is reachable from this box and nowhere else.
if ($loopbackOnly -and $Service) {
  Warn "LOOPBACK ONLY: bound to $KitchenHost, so the page is reachable from this box and nowhere else."
  Warn "  To open it from another machine, re-run with: -KitchenHost 0.0.0.0 -GenToken"
}
$tokenLine = if ($Token) { "  bearer_token: `"$Token`"" } else { "  # bearer_token_env: SEREN_KITCHEN_TOKEN   # needed once host is not loopback" }
$stateYaml = $StateDir -replace '\\', '/'
@"
# SerenKitchen config - generated by seren-kitchen-setup.ps1
# Full reference: see seren-kitchen.yaml.sample in the repo.
server:
  host: $KitchenHost
  port: $Port
$tokenLine

# Sheets, magnets, freezer facts (one JSON file), the pictures, the fonts and
# settings.json beside it. Fonts, the GitHub token, the fridges and whose house
# it is are set from the page (The house) and kept there, not in this file.
state_dir: '$stateYaml'
"@ | Write-SerenTextFile -Path $CfgPath
if ($NoUpdates) {
    @"

# Update checking turned OFF at install time by -NoUpdates. It never
# upgrades anything; flip to true to have the info route say when one exists.
updates:
  enabled: false
"@ | Add-SerenTextFile -Path $CfgPath
    Ok "Update checking disabled in config"
}
if ($Token) { Protect-SerenConfig -Path $CfgPath -ServiceUser $ServiceUser }
Ok "Config written"

# -- 6b. launcher -----------------------------------------------------------
$launcher = Write-Launcher -AppDir $AppDir -ServiceName "seren-kitchen" -Vpy $vpy -Module "seren_kitchen" -CfgPath $CfgPath

# -- 7. optional autostart ----------------------------------------------------
if ($Service) { Setup-Autostart -ScriptDir $ScriptDir -ServiceName "seren-kitchen" -AppDir $AppDir -Token $Token -VenvDir $VenvDir -ServiceUser $ServiceUser }

# -- done -------------------------------------------------------------------
$connectHost = if ($KitchenHost -eq "0.0.0.0") { "127.0.0.1" } else { $KitchenHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenKitchen is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) {
  Write-Host "  Start it:        $launcher" -ForegroundColor Blue
}
Write-Host "  The kitchen:     http://${connectHost}:$Port/viewer" -ForegroundColor Blue
Write-Host "  Health:          http://${connectHost}:$Port/health" -ForegroundColor Blue
if ($loopbackOnly) { Write-Host "  Loopback only: not reachable from other machines. Re-run with -KitchenHost 0.0.0.0 -GenToken to open it up." -ForegroundColor Yellow }
Write-Host "  State:           $StateDir" -ForegroundColor Blue
if ($Token) { Write-Host "  Bearer token:    $Token" -ForegroundColor Yellow }
Write-Host ""
Write-Host "  A fridge per app, and the notes we leave each other. Don't touch the cheese." -ForegroundColor Yellow
Write-Host "Rip it and win. 🧀🧲" -ForegroundColor Green

$doneArgs = @{
    Service     = 'seren-kitchen'
    ConnectHost = $connectHost
    Port        = $Port
    Autostart   = ([bool] $Service)
    Token       = $Token
    Venv        = $VenvDir
    Config      = $CfgPath
}
$doneArgs["Bound"] = $PSBoundParameters
Send-SerenDone @doneArgs
