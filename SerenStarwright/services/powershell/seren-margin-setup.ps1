<#
# ══════════════════════════════════════════════════════════════════════════
#  seren-margin-setup.ps1  -  one-shot SerenMargin installer (Windows)
#
#  Refactored to dot-source seren-install-lib.ps1 (shared installer library).
#  Identity lines + config + local-build-from-repo default are the unique parts.
#
#  USAGE (same flags as before)
#    powershell -ExecutionPolicy Bypass -File .\seren-margin-setup.ps1
#    powershell -ExecutionPolicy Bypass -File .\seren-margin-setup.ps1 -Service
#    powershell -ExecutionPolicy Bypass -File .\seren-margin-setup.ps1 -Wheel .\seren_margin-0.1.0-py3-none-any.whl
#    powershell -ExecutionPolicy Bypass -File .\seren-margin-setup.ps1 -Pypi
# ══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]    $Port       = 7421,
  [string] $MarginHost = "127.0.0.1",
  [string] $Token      = "",
  [switch] $GenToken,
  [string] $Wheel      = "",
  [string] $Ref        = "",
  [string] $Repo       = "",
  [string] $RepoDir    = "",
  [switch] $Pypi,
  [switch] $Mcp,
  [switch] $Service,
  [string] $Instance   = "",
  [string] $VenvDir    = ""
,
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
        Name        = 'seren-margin'
        Display     = 'Seren Margin'
        Description = 'Private notes-to-self for an AI assistant'
        Group       = 'auxiliary'
        Package     = 'seren-margin'
        Accent      = '#d1cbba'
        DefaultHost = $MarginHost
        DefaultPort = $Port
    }
    Get-SerenDescribe @describeArgs
    exit 0
}
if ($Json) { Enable-SerenJson }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\margin" }
$VenvDir = "$VenvDir$Instance"
$AppDir  = "$env:USERPROFILE\seren-margin$Instance"
$CfgPath = "$AppDir\seren-margin.yaml"
$global:Instance = $Instance
if ($Instance -and $Port -eq 7421) {
  Warn "Instance '$Instance' uses default port 7421 — may collide."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenMargin setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find Python (3.10-3.12) -----------------------------------------------
$pyInfo = Find-Python
$global:pyInfo = $pyInfo

if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenMargin" }

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
  $wr = Resolve-Wheel -Wheel $Wheel -Ref $Ref -Repo $Repo -Package "seren-margin"
  $wheelSrc = $wr.Src
  $cleanupWheel = $wr.Cleanup
} elseif ($Pypi) {
  $wheelSrc = "seren-margin"
  Ok "Installing the latest seren-margin from PyPI"
} else {
  # DEFAULT: build a wheel from the repo checkout. Margin isn't on PyPI yet.
  Step "Building a wheel from the SerenMargin checkout"
  if (-not $RepoDir) { $RepoDir = Find-Upward "SerenMargin" }
  $pkgDir = Join-Path $RepoDir "SerenMargin"
  if (-not (Test-Path (Join-Path $pkgDir "pyproject.toml"))) {
    Die "SerenMargin checkout not found at $pkgDir. Use -RepoDir, -Wheel, -Pypi, or -Ref."
  }
  $buildVenv = Join-Path ([System.IO.Path]::GetTempPath()) "build-venv-margin"
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
$extras = Get-Extras-Suffix -Mcp:$Mcp
Install-Package -Vpy $vpy -WheelSrc $wheelSrc -Extras $extras -Label " ($(if ($Mcp) { ' + MCP SDK' } else { '' }))"
if ($cleanupWheel) { Remove-Item -Force $wheelSrc -ErrorAction SilentlyContinue }

# -- 4. sanity check (import + mcp-manifest asset) ----------------------------
Sanity-Check -Vpy $vpy -Module "seren_margin" -AssetRelPath "mcp-manifest.yaml" -AssetLabel "MCP manifest"

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
@"
# SerenMargin config - generated by seren-margin-setup.ps1
# Full reference: see seren-margin.yaml.sample in the repo.
server:
  host: $MarginHost
  port: $Port
  db_path: ~/.seren-margin$dbInstance/notes.db
"@ | Set-Content -Path $CfgPath -Encoding UTF8
Ok "Config written"

# -- 5b. launcher -----------------------------------------------------------
$launcher = Write-Launcher -AppDir $AppDir -ServiceName "seren-margin" -Vpy $vpy -Module "seren_margin" -CfgPath $CfgPath

# -- 6. optional autostart ----------------------------------------------------
if ($Service) { Setup-Autostart -ScriptDir $ScriptDir -ServiceName "seren-margin" -AppDir $AppDir -Token $Token -VenvDir $VenvDir }

# -- done -------------------------------------------------------------------
$connectHost = if ($MarginHost -eq "0.0.0.0") { "127.0.0.1" } else { $MarginHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenMargin is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) {
  Write-Host "  Start it:        $launcher" -ForegroundColor Blue
}
Write-Host "  Health:          http://${connectHost}:$Port/health" -ForegroundColor Blue
Write-Host "  Engine-check:    http://${connectHost}:$Port/notes/stats" -ForegroundColor Blue
Write-Host "  MCP manifest:    http://${connectHost}:$Port/mcp-manifest" -ForegroundColor Blue
Write-Host ""
if ($Mcp)   { Write-Host "  MCP endpoint:    http://${connectHost}:$Port/mcp/" -ForegroundColor Blue }
Write-Host "  Private by default, transparent in mechanism, opt-in by deploy." -ForegroundColor Yellow
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green

# -- Starwright contract: structured completion event -------------------------
# Human banner above, machine-readable twin here. No-op without -Json.
$doneArgs = @{
    Service     = 'seren-margin'
    ConnectHost = $connectHost
    Port        = $Port
    Autostart   = ([bool] $Service)
    Token       = $Token
    Mcp         = ([bool] $Mcp)
    Corp        = $false
    Vector      = $false
    Venv        = $VenvDir
    Config      = $CfgPath
}
Send-SerenDone @doneArgs
