<#
# ══════════════════════════════════════════════════════════════════════════
#  seren-soma-setup.ps1  -  one-shot SerenSoma installer (Windows)
#
#  Dot-sources seren-install-lib.ps1 (shared installer library). The identity
#  lines, the robot, Lodestar for hearing and speaking, and the state folder
#  the tokens live in are the unique parts. Twin of seren-soma-setup.sh.
#
#  Soma is the body's nervous system: the voice server a Stack-chan robot
#  dials into over the LAN, its ears and touch, its faces' reactions, night
#  mode and work hours. It binds 0.0.0.0 by nature (the robot is another box),
#  so it always has an API token: the one you give it, or the one it makes
#  into <state>\token the first time it runs. The robot's own control token
#  is a second secret, kept in <state>\control_token, never in the config.
#
#  USAGE
#    powershell -ExecutionPolicy Bypass -File .\seren-soma-setup.ps1 -Pypi -Service -GenToken
#    powershell -ExecutionPolicy Bypass -File .\seren-soma-setup.ps1 -Root C:\seren\home -Instance home -Pypi `
#        -RobotUrl http://192.0.2.21:8080 -Advertise 192.0.2.10 -LodestarConfig C:\seren\home\apps\lodestar\seren-lodestar.yaml -Service
#  The robot's control token may arrive as $env:SEREN_SOMA_ROBOT_TOKEN and Lodestar's
#  bearer as $env:SEREN_LODESTAR_TOKEN instead of on the command line.
# ══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]    $Port        = 7480,
  [string] $SomaHost    = "0.0.0.0",
  [string] $Token       = "",
  [switch] $GenToken,
  [string] $RobotUrl    = "",
  [string] $RobotToken  = "",
  [string] $Advertise   = "",
  [string] $DeviceFrom  = "",
  [string] $Voice       = "",
  [string] $LodestarUrl = "",
  [string] $LodestarToken = "",
  [string] $LodestarConfig = "",
  [string] $SymposiumYaml = "",
  [string] $StateDir    = "",
  [string] $RepoDir     = "",
  [string] $Wheel       = "",
  [string] $Local       = "",
  [switch] $Pypi,
  [string] $Ref         = "",
  [string] $Repo        = "",
  [switch] $Service,
  [string] $ServiceUser = "",
  [switch] $NoUpdates,
  [string] $Instance    = "",
  [string] $Root        = "",
  [string] $VenvDir     = "",
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

# -- Starwright contract: identity (same values as the bash card and seren_soma/_describe.py)
if ($Describe) {
    $describeArgs = @{
        ScriptPath  = $PSCommandPath
        Name        = 'seren-soma'
        Display     = 'Seren Soma'
        Description = "The body's nervous system: a Stack-chan robot's voice, ears and touch"
        Group       = 'auxiliary'
        Package     = 'seren-soma'
        Accent      = '#8fbf88'
        DefaultHost = $SomaHost
        DefaultPort = $Port
        Recommends  = @('seren-lodestar')
        Secrets     = @{ 'robot-token' = 'SEREN_SOMA_ROBOT_TOKEN'; 'lodestar-token' = 'SEREN_LODESTAR_TOKEN' }
        ConfigKeys  = @{ 'robot-url' = 'robot.url'; 'robot-token' = 'robot.token_file'; 'device-from' = 'robot.device_from'; 'advertise' = 'advertise';
                         'voice' = 'voice'; 'state-dir' = 'state_dir'; 'lodestar-url' = 'lodestar.url';
                         'lodestar-token' = 'lodestar.token'; 'symposium-yaml' = 'lodestar.symposium_yaml' }
    }
    Get-SerenDescribe @describeArgs
    exit 0
}
if ($Json) { Enable-SerenJson }
if (-not $RobotToken -and $env:SEREN_SOMA_ROBOT_TOKEN) { $RobotToken = $env:SEREN_SOMA_ROBOT_TOKEN }
# The robot's address is the one thing nobody can guess for you, and seren_soma refuses
# to start without it; so the card refuses too, before anything is installed.
if (-not $RobotUrl) { Die "-RobotUrl is required: the robot's control API, like http://192.0.2.21:8080 (the robot's screen shows its address)" }
if (-not $LodestarToken -and $env:SEREN_LODESTAR_TOKEN) { $LodestarToken = $env:SEREN_LODESTAR_TOKEN }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\soma" }
$layout  = Get-SerenLayout -Root $Root -Short "soma" -Instance $Instance -VenvDir $VenvDir -AppDir "$env:USERPROFILE\seren-soma"
$VenvDir = $layout.Venv
$AppDir  = $layout.App
$CfgPath = "$AppDir\seren-soma.yaml"
if (-not $StateDir) { $StateDir = if ($layout.Data) { $layout.Data } else { "$AppDir\state" } }
$global:Instance = $Instance
if ($Instance -and $Port -eq 7480) {
  Warn "Instance '$Instance' uses default port 7480 - the firmware's check-in expects that port, so a second instance needs a reflashed robot."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenSoma setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find Python (3.10+) ---------------------------------------------------
$pyInfo = Find-Python
$global:pyInfo = $pyInfo
if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenSoma" }

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
  $wr = Resolve-Wheel -Wheel $Wheel -Local $Local -Ref $Ref -Repo $Repo -Package "seren-soma"
  $wheelSrc = $wr.Src
  $cleanupWheel = $wr.Cleanup
} elseif ($Pypi) {
  $wheelSrc = "seren-soma"
  Ok "Installing the latest seren-soma from PyPI"
} else {
  Step "Building a wheel from the SerenSoma checkout"
  if (-not $RepoDir) { $RepoDir = Find-Upward "SerenSoma" }
  $pkgDir = Join-Path $RepoDir "SerenSoma"
  if (-not (Test-Path (Join-Path $pkgDir "pyproject.toml"))) {
    Die "SerenSoma checkout not found at $pkgDir. Use -RepoDir, -Wheel, -Pypi, or -Ref."
  }
  $buildVenv = Join-Path ([System.IO.Path]::GetTempPath()) "build-venv-soma"
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
Sanity-Check -Vpy $vpy -Module "seren_soma" -AssetRelPath "viewer\ui" -AssetLabel "the viewer's page"

# -- 5. the Lodestar that hears and speaks ----------------------------------
$lodeTokenLines = ""
if ($LodestarConfig) {
  $sib = Read-SerenSiblingConfig -Path $LodestarConfig
  if (-not $LodestarUrl -and $sib.Url) { $LodestarUrl = $sib.Url }
  # Soma's token pointers are token / token_env / token_keyring (seren_soma.config.Pointer).
  if ($sib.Token)        { $lodeTokenLines = "  token: `"$($sib.Token)`"" }
  if ($sib.TokenEnv)     { $lodeTokenLines = "  token_env: $($sib.TokenEnv)" }
  if ($sib.TokenKeyring) { $lodeTokenLines = "  token_keyring: `"$($sib.TokenKeyring)`"" }
}
if ($LodestarToken) { $lodeTokenLines = "  token: `"$LodestarToken`"" }
if (-not $SymposiumYaml -and -not $LodestarUrl) {
  foreach ($cand in @($(if ($layout.Root) { Join-Path $layout.Root "apps\symposium\seren-symposium.yaml" }), "$env:USERPROFILE\seren-symposium\seren-symposium.yaml")) {
    if ($cand -and (Test-Path $cand)) { $SymposiumYaml = $cand; break }
  }
}
if ($LodestarUrl) {
  Ok "Hearing and speaking through the Lodestar at $LodestarUrl$(if ($lodeTokenLines) { ', with its bearer' })"
} elseif ($SymposiumYaml) {
  Ok "Lodestar's address and bearer will be read from $SymposiumYaml at startup"
} else {
  Warn "No Lodestar named: the body will react to touch and keep night, but not hear or speak."
  Warn "  Add one later with -LodestarConfig, or lodestar: url / token in $CfgPath."
}

# -- 6. config --------------------------------------------------------------
Step "Writing config at $CfgPath"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
if ($GenToken) { $Token = & $vpy -c "import secrets; print(secrets.token_urlsafe(32))" }
if (-not $Token -and -not $GenToken) { $Token = Get-SerenReusedToken -Path $CfgPath }
if (Test-Path $CfgPath) {
  $bak = "$CfgPath.bak.$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
  Copy-Item $CfgPath $bak; (Get-Item $bak).LastWriteTime = Get-Date
  Warn "Existing config backed up to $(Split-Path $bak -Leaf)"
}
# The robot's control token is a file in the state folder: the config only points at it.
$robotTokenFile = Join-Path $StateDir "control_token"
if ($RobotToken) {
  [System.IO.File]::WriteAllText($robotTokenFile, $RobotToken)
  Protect-SerenConfig -Path $robotTokenFile -ServiceUser $ServiceUser
  Ok "The robot's control token is in $robotTokenFile"
} elseif ((Test-Path $robotTokenFile) -and (Get-Item $robotTokenFile).Length -gt 0) {
  Ok "Keeping the robot's control token already in $robotTokenFile"
} else {
  Warn "No robot control token: give -RobotToken (or `$env:SEREN_SOMA_ROBOT_TOKEN) or write $robotTokenFile yourself; the robot refuses calls without it."
}
$tokenLine = if ($Token) { "  bearer_token: `"$Token`"" } else { "  # The API token: blank means the file ``token`` in the state folder, made the first time." }
$advLine = if ($Advertise) { "advertise: $Advertise" } else { "# advertise: 192.0.2.10" }
$voiceLine = if ($Voice) { "voice: $Voice                # the voice Lodestar speaks in" } else { 'voice: ""                # blank: Lodestar speaks in its own default voice' }
$stateYaml = $StateDir -replace '\\', '/'
$robotFileYaml = $robotTokenFile -replace '\\', '/'
@"
# SerenSoma config - generated by seren-soma-setup.ps1
# Full reference: see seren-soma.yaml.sample in the repo.
server:
  host: $SomaHost
  port: $Port
$tokenLine

# Tokens, what was heard, touches, settings and the log. Outside any repo.
state_dir: '$stateYaml'

# This box's address as the robot reaches it. Blank: the address this box uses toward the robot.
$advLine

$voiceLine
idle_close_seconds: 60     # an open channel with no words this long hangs up

robot:
  url: $RobotUrl
  # Its control token (CONFIG_STACKCHAN_CONTROL_TOKEN in the firmware), a file holding only the token.
  token_file: '$robotFileYaml'
$(if ($DeviceFrom) { "  # The check-in answers only these addresses (the robot through NAT or a proxy).`n  device_from: [$((($DeviceFrom -split ',') | ForEach-Object { $_.Trim() }) -join ', ')]" })

lodestar:
  # Hearing and speaking.
"@ | Write-SerenTextFile -Path $CfgPath
if ($LodestarUrl) {
  "  url: $LodestarUrl" | Add-SerenTextFile -Path $CfgPath
  if ($lodeTokenLines) { $lodeTokenLines | Add-SerenTextFile -Path $CfgPath }
}
if ($SymposiumYaml) {
  "  # Blank url: read from the Symposium config on this box.`n  symposium_yaml: '$($SymposiumYaml -replace '\\', '/')'" | Add-SerenTextFile -Path $CfgPath
} elseif (-not $LodestarUrl) {
  "  # url: http://192.0.2.200:6361`n  # token_env: SEREN_LODESTAR_TOKEN" | Add-SerenTextFile -Path $CfgPath
}
if ($NoUpdates) {
    @"

# Update checking turned OFF at install time by -NoUpdates. It never
# upgrades anything; flip to true to have the info route say when one exists.
updates:
  enabled: false
"@ | Add-SerenTextFile -Path $CfgPath
    Ok "Update checking disabled in config"
}
# The file always carries robot.token_file, a pointer, and often a bearer: protected, the family rule.
Protect-SerenConfig -Path $CfgPath -ServiceUser $ServiceUser
Ok "Config written"

# -- 6b. launcher -----------------------------------------------------------
$launcher = Write-Launcher -AppDir $AppDir -ServiceName "seren-soma" -Vpy $vpy -Module "seren_soma" -CfgPath $CfgPath

# -- 7. optional autostart ----------------------------------------------------
if ($Service) { Setup-Autostart -ScriptDir $ScriptDir -ServiceName "seren-soma" -AppDir $AppDir -Token $Token -VenvDir $VenvDir -ServiceUser $ServiceUser }

# -- done -------------------------------------------------------------------
$connectHost = if ($SomaHost -eq "0.0.0.0") { "127.0.0.1" } else { $SomaHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenSoma is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) {
  Write-Host "  Start it:        $launcher" -ForegroundColor Blue
}
Write-Host "  Viewer:          http://${connectHost}:$Port/viewer" -ForegroundColor Blue
Write-Host "  Health:          http://${connectHost}:$Port/health" -ForegroundColor Blue
Write-Host "  The robot:       $RobotUrl  (it dials back in on port $Port$(if ($Advertise) { " at $Advertise" }))" -ForegroundColor Blue
if ($Token) { Write-Host "  API token:       $Token" -ForegroundColor Yellow } else { Write-Host "  API token:       $StateDir\token (made the first time it runs)" -ForegroundColor Blue }
Write-Host "  On the robot's SD card, soma.yaml names this box as voice: and carries the same control token as token:." -ForegroundColor Blue
Write-Host ""
Write-Host "  A body you can boop. Its face, its voice and its secrets stay yours." -ForegroundColor Yellow
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green

$doneArgs = @{
    Service     = 'seren-soma'
    ConnectHost = $connectHost
    Port        = $Port
    Autostart   = ([bool] $Service)
    Token       = $Token
    Venv        = $VenvDir
    Config      = $CfgPath
}
$doneArgs["Bound"] = $PSBoundParameters
Send-SerenDone @doneArgs
