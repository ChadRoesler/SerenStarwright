<#
# ==========================================================================
#  seren-hippocampus-setup.ps1  -  one-shot SerenHippocampus installer (Windows)
#
#  The sleep cycle for SerenMemory, split out. Holds no store: it reads
#  short-terms from Memory, writes dockets to Memory, purges what was flagged.
#  Needs a running SerenMemory and the bearer that Memory requires.
#
#  USAGE
#    powershell -ExecutionPolicy Bypass -File .\seren-hippocampus-setup.ps1 -MemoryToken <memory's token>
#    powershell -ExecutionPolicy Bypass -File .\seren-hippocampus-setup.ps1 -Service -GenToken -MemoryToken ...
#    powershell -ExecutionPolicy Bypass -File .\seren-hippocampus-setup.ps1 -Local D:\serenDaemon\SerenCore\.dev-wheelhouse
#    powershell -ExecutionPolicy Bypass -File .\seren-hippocampus-setup.ps1 -ModelUrl ""   # mechanical mode
# ==========================================================================
#>
[CmdletBinding()]
param(
  [int]    $Port        = 7424,
  [string] $HippoHost   = "127.0.0.1",
  [string] $Token       = "",
  [switch] $GenToken,
  [string] $MemoryUrl   = "http://127.0.0.1:7420",
  [string] $MemoryToken = "",
  [string] $MemoryConfig = "",   # Memory's own config: its url AND its bearer, read from the file
  [string] $ModelUrl    = "http://localhost:8090/v1",
  [string] $Wheel       = "",
  [string] $Local       = "",
  [string] $Ref         = "",
  [string] $Repo        = "",
  [string] $RepoDir     = "",
  [switch] $Pypi,
  [switch] $Corp,
  [switch] $NoUpdates,
  [string] $ServiceUser = "",
  [switch] $LocalSystem,
  [switch] $Service,
  [string] $Instance    = "",
  [string] $VenvDir     = "",
  [switch] $Describe,
  [switch] $Json
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

# -- Starwright contracts -----------------------------------------------------
if ($Describe) {
    $describeArgs = @{
        ScriptPath  = $PSCommandPath
        Name        = 'seren-hippocampus'
        Display     = 'Seren Hippocampus'
        Description = 'The sleep cycle for SerenMemory: drafts the docket, resubmits on critique, purges what was flagged'
        Group       = 'brain'
        Package     = 'seren-hippocampus'
        Accent      = '#c9a0dc'
        DefaultHost = $HippoHost
        DefaultPort = $Port
        Requires    = @('seren-memory')
    }
    Get-SerenDescribe @describeArgs
    exit 0
}
if ($Json) { Enable-SerenJson }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\hippocampus" }
$VenvDir = "$VenvDir$Instance"
$AppDir  = "$env:USERPROFILE\seren-hippocampus$Instance"
$CfgPath = "$AppDir\seren-hippocampus.yaml"
$global:Instance = $Instance
if ($Instance -and $Port -eq 7424) { Warn "Instance '$Instance' uses default port 7424 - may collide." }
$memoryTokenLines = ""
if ($MemoryConfig) {
    $sib = Read-SerenSiblingConfig -Path $MemoryConfig
    if ($sib.Url) { $MemoryUrl = $sib.Url }
    if (-not $MemoryToken -and $sib.Token) { $MemoryToken = $sib.Token }
    $memoryTokenLines = Get-SerenSiblingTokenLines -Sib $sib -Indent "  "
    Ok "Memory: $MemoryUrl (from $MemoryConfig$(if ($memoryTokenLines) { ', with its bearer' } else { '' }))"
}
if ($MemoryToken) { $memoryTokenLines = "  bearer_token: `"$MemoryToken`"`n" }
if (-not $memoryTokenLines) { Warn "No -MemoryToken / -MemoryConfig: fine if Memory has no bearer; a Memory installed with -GenToken answers 401 to every sleep." }

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenHippocampus setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find Python -----------------------------------------------------------
$pyInfo = Find-Python
$global:pyInfo = $pyInfo
if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenHippocampus" }

# -- 2. resolve what to install ------------------------------------------------
# Precedence: -Wheel > -Local (dev wheelhouse) > -Repo/-Ref (GitHub) > -Pypi > local build (default)
$wheelSrc = $null
$cleanupWheel = $false
$pyExe = $pyInfo.Exe
$pyArgs = $pyInfo.Args
if ($Wheel) {
  if (-not (Test-Path $Wheel)) { Die "wheel not found: $Wheel" }
  $wheelSrc = (Resolve-Path $Wheel).Path
  Ok "Installing from local wheel: $(Split-Path $wheelSrc -Leaf)"
} elseif ($Local -or $Repo) {
  $wr = Resolve-Wheel -Wheel $Wheel -Local $Local -Ref $Ref -Repo $Repo -Package "seren-hippocampus"
  $wheelSrc = $wr.Src
  $cleanupWheel = $wr.Cleanup
} elseif ($Pypi) {
  $wheelSrc = "seren-hippocampus"
  Ok "Installing the latest seren-hippocampus from PyPI"
} else {
  Step "Building a wheel from the SerenHippocampus checkout"
  if (-not $RepoDir) { $RepoDir = Find-Upward "SerenHippocampus" }
  $pkgDir = Join-Path $RepoDir "SerenHippocampus"
  if (-not (Test-Path (Join-Path $pkgDir "pyproject.toml"))) {
    Die "SerenHippocampus checkout not found at $pkgDir. Use -RepoDir, -Wheel, -Local, -Pypi, or -Ref."
  }
  $buildVenv = Join-Path ([System.IO.Path]::GetTempPath()) "build-venv-hippocampus"
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
$extras = Get-Extras-Suffix -Corp:$Corp
Install-Package -Vpy $vpy -WheelSrc $wheelSrc -Extras $extras -Label "$(if ($Corp) { ' (+ truststore)' } else { '' })"
if ($cleanupWheel) { Remove-Item -Force $wheelSrc -ErrorAction SilentlyContinue }

# -- 4. sanity check ----------------------------------------------------------
Sanity-Check -Vpy $vpy -Module "seren_hippocampus"

# -- 5. config --------------------------------------------------------------
Step "Writing config at $CfgPath"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if ($GenToken) { $Token = & $vpy -c "import secrets; print(secrets.token_urlsafe(32))" }
# A reinstall keeps the existing bearer unless -Token / -GenToken say otherwise.
if (-not $Token -and -not $GenToken) { $Token = Get-SerenReusedToken -Path $CfgPath }
if (Test-Path $CfgPath) {
  $bak = "$CfgPath.bak.$([int][double]::Parse((Get-Date -UFormat %s)))"
  Copy-Item $CfgPath $bak
  Warn "Existing config backed up to $(Split-Path $bak -Leaf)"
}
$serverToken = if ($Token) { "  bearer_token: `"$Token`"`n" } else { "" }
$memoryToken = $memoryTokenLines
@"
# SerenHippocampus config - generated by seren-hippocampus-setup.ps1
# Full reference: see seren-hippocampus.yaml.sample in the repo.
server:
  host: $HippoHost
  port: $Port
$serverToken
memory:
  url: $MemoryUrl
$memoryToken
model:
  url: "$ModelUrl"

sleep:
  mode: thread
  state_path: ~/.seren-hippocampus$Instance/state.json
"@ | Write-SerenTextFile -Path $CfgPath
Ok "Config written"

if ($NoUpdates) {
    @"

# ── Update checking ───────────────────────────────────────────────────
# Turned OFF at install time by -NoUpdates. Flip to true to re-enable, or set
# SEREN_HIPPOCAMPUS_UPDATES_ENABLED=true in the service environment.
updates:
  enabled: false
"@ | Add-SerenTextFile -Path $CfgPath
    Ok "Update checking disabled in config"
}

# -- 5b. launcher -----------------------------------------------------------
$launcher = Write-Launcher -AppDir $AppDir -ServiceName "seren-hippocampus" -Vpy $vpy -Module "seren_hippocampus" -CfgPath $CfgPath

# -- 6. optional autostart ----------------------------------------------------
if ($Service) { Setup-Autostart -ScriptDir $ScriptDir -ServiceName "seren-hippocampus" -AppDir $AppDir -Token $Token -VenvDir $VenvDir -ServiceUser $ServiceUser -LocalSystem:$LocalSystem }

# -- done -------------------------------------------------------------------
$connectHost = if ($HippoHost -eq "0.0.0.0") { "127.0.0.1" } else { $HippoHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenHippocampus is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) { Write-Host "  Start it:        $launcher" -ForegroundColor Blue }
Write-Host "  Health:          http://${connectHost}:$Port/health" -ForegroundColor Blue
Write-Host "  Status:          http://${connectHost}:$Port/status" -ForegroundColor Blue
Write-Host "  Sleep now:       POST http://${connectHost}:$Port/sleep" -ForegroundColor Blue
Write-Host "  Memory:          $MemoryUrl" -ForegroundColor Blue
if ($ModelUrl) { Write-Host "  Model:           $ModelUrl" -ForegroundColor Blue } else { Write-Host "  Model:           none - mechanical mode" -ForegroundColor Yellow }
if ($Token) { Write-Host "  Bearer token:    $Token" -ForegroundColor Yellow }
Write-Host ""
Write-Host "  Sleeps every ~20h; tends denied operations every 5 minutes." -ForegroundColor Yellow
Write-Host "Rip it and win." -ForegroundColor Green

$doneArgs = @{
    Service     = 'seren-hippocampus'
    ConnectHost = $connectHost
    Port        = $Port
    Autostart   = ([bool] $Service)
    Token       = $Token
    Mcp         = $false
    Corp        = ([bool] $Corp)
    Vector      = $false
    Venv        = $VenvDir
    Config      = $CfgPath
}
Send-SerenDone @doneArgs
