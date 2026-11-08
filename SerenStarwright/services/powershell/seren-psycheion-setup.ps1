<#
# ══════════════════════════════════════════════════════════════════════════
#  seren-psycheion-setup.ps1  -  one-shot SerenPsycheion installer (Windows)
#
#  Dot-sources seren-install-lib.ps1 (shared installer library). The identity
#  lines and the body it watches (the robot's control API and the Soma voice
#  server) are the unique parts. Twin of seren-psycheion-setup.sh.
#
#  Psycheion is the mind's workshop for a Seren body: watch what it senses
#  and does, set how it behaves. It reaches the body over the body's own HTTP
#  APIs with tokens it holds as POINTERS (a file, an env var, the keychain);
#  the browser never sees them. Loopback by default; a wider bind needs a
#  bearer or Psycheion refuses to start.
#
#  USAGE
#    powershell -ExecutionPolicy Bypass -File .\seren-psycheion-setup.ps1 -Pypi -Service
#    powershell -ExecutionPolicy Bypass -File .\seren-psycheion-setup.ps1 -Root C:\seren\wren -Instance wren -Pypi `
#        -SomaConfig C:\seren\wren\apps\soma\seren-soma.yaml -Service
# ══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]    $Port           = 7429,
  [string] $PsycheionHost  = "127.0.0.1",
  [string] $Token          = "",
  [switch] $GenToken,
  [string] $SomaConfig     = "",
  [string] $RobotUrl       = "",
  [string] $RobotTokenFile = "",
  [string] $VoiceUrl       = "",
  [string] $VoiceTokenFile = "",
  [string] $RepoDir        = "",
  [string] $Wheel          = "",
  [string] $Local          = "",
  [switch] $Pypi,
  [string] $Ref            = "",
  [string] $Repo           = "",
  [switch] $Service,
  [string] $ServiceUser    = "",
  [switch] $NoUpdates,
  [string] $Instance       = "",
  [string] $Root           = "",
  [string] $VenvDir        = "",
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

# -- Starwright contract: identity (same values as the bash card and seren_psycheion/_describe.py)
if ($Describe) {
    $describeArgs = @{
        ScriptPath  = $PSCommandPath
        Name        = 'seren-psycheion'
        Display     = 'Seren Psycheion'
        Description = "The mind's workshop for a Seren body: watch what it senses and does, set how it behaves"
        Group       = 'auxiliary'
        Package     = 'seren-psycheion'
        Accent      = '#f2aeb1'
        DefaultHost = $PsycheionHost
        DefaultPort = $Port
        Recommends  = @('seren-soma')
        ConfigKeys  = @{ 'robot-url' = 'soma.robot.url'; 'robot-token-file' = 'soma.robot.token_file';
                         'voice-url' = 'soma.voice.url'; 'voice-token-file' = 'soma.voice.token_file' }
    }
    Get-SerenDescribe @describeArgs
    exit 0
}
if ($Json) { Enable-SerenJson }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\psycheion" }
$layout  = Get-SerenLayout -Root $Root -Short "psycheion" -Instance $Instance -VenvDir $VenvDir -AppDir "$env:USERPROFILE\seren-psycheion"
$VenvDir = $layout.Venv
$AppDir  = $layout.App
$CfgPath = "$AppDir\seren-psycheion.yaml"
$global:Instance = $Instance
if ($Instance -and $Port -eq 7429) {
  Warn "Instance '$Instance' uses default port 7429 - may collide."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenPsycheion setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find Python (3.10+) ---------------------------------------------------
$pyInfo = Find-Python
$global:pyInfo = $pyInfo
if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenPsycheion" }

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
  $wr = Resolve-Wheel -Wheel $Wheel -Local $Local -Ref $Ref -Repo $Repo -Package "seren-psycheion"
  $wheelSrc = $wr.Src
  $cleanupWheel = $wr.Cleanup
} elseif ($Pypi) {
  $wheelSrc = "seren-psycheion"
  Ok "Installing the latest seren-psycheion from PyPI"
} else {
  Step "Building a wheel from the SerenPsycheion checkout"
  if (-not $RepoDir) { $RepoDir = Find-Upward "SerenPsycheion" }
  $pkgDir = Join-Path $RepoDir "SerenPsycheion"
  if (-not (Test-Path (Join-Path $pkgDir "pyproject.toml"))) {
    Die "SerenPsycheion checkout not found at $pkgDir. Use -RepoDir, -Wheel, -Pypi, or -Ref."
  }
  $buildVenv = Join-Path ([System.IO.Path]::GetTempPath()) "build-venv-psycheion"
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

# -- 4. sanity check (import + the viewer's page) ----------------------------
Sanity-Check -Vpy $vpy -Module "seren_psycheion" -AssetRelPath "viewer\ui" -AssetLabel "the viewer's page"

# -- 5. the body ---------------------------------------------------------------
# A Soma config on this box names everything: the robot's url, the voice
# server's host and port, and the state folder its two token files live in.
# Anything given by hand wins over what the file says.
if ($SomaConfig) {
  if (-not (Test-Path $SomaConfig)) { Die "could not read the Soma's config: $SomaConfig" }
  $sib = Read-SerenSiblingConfig -Path $SomaConfig
  if (-not $VoiceUrl -and $sib.Url) { $VoiceUrl = $sib.Url }
  $lines = Get-Content $SomaConfig
  $somaState = ""; $somaRobot = ""; $inRobot = $false
  foreach ($l in $lines) {
    if (-not $somaState -and $l -match '^\s*state_dir:\s*(.*)$') { $somaState = ($Matches[1] -replace '\s*#.*$', '').Trim().Trim('"').Trim("'") }
    if ($l -match '^robot:') { $inRobot = $true; continue }
    if ($l -match '^[^\s#]') { $inRobot = $false }
    if ($inRobot -and -not $somaRobot -and $l -match '^\s+url:\s*(.*)$') { $somaRobot = ($Matches[1] -replace '\s*#.*$', '').Trim() }
  }
  if ($somaState -like "~*") { $somaState = $env:USERPROFILE + $somaState.Substring(1) }
  if (-not $RobotUrl -and $somaRobot) { $RobotUrl = $somaRobot }
  if ($somaState) {
    if (-not $VoiceTokenFile) { $VoiceTokenFile = Join-Path $somaState "token" }
    if (-not $RobotTokenFile) { $RobotTokenFile = Join-Path $somaState "control_token" }
  }
  Ok "The body from ${SomaConfig}: robot $(if ($RobotUrl) { $RobotUrl } else { '?' }), voice $(if ($VoiceUrl) { $VoiceUrl } else { '?' })"
}
if (-not $RobotUrl) { $RobotUrl = "http://192.168.0.201:8080" }
if (-not $VoiceUrl) { $VoiceUrl = "http://127.0.0.1:7480" }
foreach ($f in @($RobotTokenFile, $VoiceTokenFile)) {
  if ($f -and -not ((Test-Path $f) -and (Get-Item $f).Length -gt 0)) { Warn "Token file not there yet: $f (Psycheion reads it when it is)" }
}
if (-not $RobotTokenFile -and -not $VoiceTokenFile) {
  Warn "No token files named: the pages will show the body but calls to it will be refused until soma.robot / soma.voice get a token pointer in $CfgPath."
}

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
if ($PsycheionHost -notmatch '^(127\.|localhost$|::1$)' -and -not $Token) {
  Warn "-PsycheionHost $PsycheionHost with no bearer: SerenPsycheion will REFUSE TO START. Re-run with -GenToken (or -Token)."
}
$tokenLine = if ($Token) { "  bearer_token: `"$Token`"" } else { "  # bearer_token_env: SEREN_PSYCHEION_TOKEN   # needed once host is not loopback" }
$robotFileLine = if ($RobotTokenFile) { "    token_file: '$($RobotTokenFile -replace '\\', '/')'" } else { "    # token_file: ~/seren-soma/state/control_token" }
$voiceFileLine = if ($VoiceTokenFile) { "    token_file: '$($VoiceTokenFile -replace '\\', '/')'" } else { "    # token_file: ~/seren-soma/state/token" }
@"
# SerenPsycheion config - generated by seren-psycheion-setup.ps1
# Full reference: see seren-psycheion.yaml.sample in the repo.
server:
  host: $PsycheionHost
  port: $Port
$tokenLine

# The body. Tokens are POINTERS: token_file (a file holding only the token),
# token_env (an env var's name) or token_keyring ("service/username"). The
# browser never sees these; Psycheion makes the calls itself.
soma:
  robot:                   # the robot's control API (firmware)
    url: $RobotUrl
$robotFileLine
  voice:                   # the body's voice server (Soma)
    url: $VoiceUrl
$voiceFileLine
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
$launcher = Write-Launcher -AppDir $AppDir -ServiceName "seren-psycheion" -Vpy $vpy -Module "seren_psycheion" -CfgPath $CfgPath

# -- 7. optional autostart ----------------------------------------------------
if ($Service) { Setup-Autostart -ScriptDir $ScriptDir -ServiceName "seren-psycheion" -AppDir $AppDir -Token $Token -VenvDir $VenvDir -ServiceUser $ServiceUser }

# -- done -------------------------------------------------------------------
$connectHost = if ($PsycheionHost -eq "0.0.0.0") { "127.0.0.1" } else { $PsycheionHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenPsycheion is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) {
  Write-Host "  Start it:        $launcher" -ForegroundColor Blue
}
Write-Host "  Viewer:          http://${connectHost}:$Port/viewer" -ForegroundColor Blue
Write-Host "  Health:          http://${connectHost}:$Port/health" -ForegroundColor Blue
Write-Host "  The body:        robot $RobotUrl, voice $VoiceUrl" -ForegroundColor Blue
if ($Token) { Write-Host "  Bearer token:    $Token" -ForegroundColor Yellow }
Write-Host ""
Write-Host "  Watch what it senses, set how it behaves. Faces come when Face Studio moves in." -ForegroundColor Yellow
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green

$doneArgs = @{
    Service     = 'seren-psycheion'
    ConnectHost = $connectHost
    Port        = $Port
    Autostart   = ([bool] $Service)
    Token       = $Token
    Venv        = $VenvDir
    Config      = $CfgPath
}
$doneArgs["Bound"] = $PSBoundParameters
Send-SerenDone @doneArgs
