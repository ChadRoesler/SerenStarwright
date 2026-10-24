<#
══════════════════════════════════════════════════════════════════════════
  seren-lyceum-setup.ps1  -  one-shot SerenLyceum installer (Windows)

  The twin of seren-lyceum-setup.sh. Two environments, on purpose: the
  service's venv never imports torch; it forks the trainer in the TRAINING
  venv (seren-lyceum[train] + a torch built for this GPU), detached, so a
  restart of the service never kills a run. -Train builds that second venv;
  -TrainPython points at one that already exists. With neither, this box
  does not train locally and can still send jobs to a cloud.

  The service is installed with -KeepChildren (NSSM AppKillProcessTree 0)
  for the same reason: NSSM stops a whole process tree by default.

  USAGE
    powershell -ExecutionPolicy Bypass -File .\seren-lyceum-setup.ps1 -Train -Service
    powershell -ExecutionPolicy Bypass -File .\seren-lyceum-setup.ps1 -Train -Label "the desktop" `
        -HippocampusUrl http://192.0.2.200:7254 -HippocampusToken ...

  RUN IT: elevated PowerShell (for -Service), as yourself.
══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]      $Port        = 7428,
  [string]   $LyceumHost  = "127.0.0.1",
  [string]   $Token       = "",
  [switch]   $GenToken,
  [switch]   $Train,
  [string]   $TrainPython = "",
  [string]   $TorchIndex  = "https://download.pytorch.org/whl/cu130",
  [string]   $LlamaCpp    = "",
  [string]   $HfHome      = "",
  [string]   $Label       = "",
  [string]   $HippocampusUrl    = "",
  [string]   $HippocampusToken  = "",
  [string]   $HippocampusConfig = "",
  [string]   $Wheel       = "",
  [string]   $Local       = "",
  [string]   $Ref         = "",
  [string]   $Repo        = "",
  [string]   $RepoDir     = "",
  [switch]   $Pypi,
  [switch]   $NoUpdates,
  [string]   $ServiceUser = "",
  [switch]   $LocalSystem,
  [switch]   $Service,
  [string]   $Instance    = "",
  [string]   $Root        = "",
  [string]   $VenvDir     = "",
  [switch]   $Describe,   # print service metadata as JSON and exit (no side effects)
  [switch]   $Json        # stream JSON Lines events on stdout; humans go to stderr
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

# -- Starwright contract: identity (same values as the bash card) -------------
if ($Describe) {
    $describeArgs = @{
        ScriptPath  = $PSCommandPath
        Name        = 'seren-lyceum'
        Display     = 'Seren Lyceum'
        Description = 'Train your own model: a dataset in, a model out'
        Group       = 'auxiliary'
        Package     = 'seren-lyceum'
        Accent      = '#a17056'
        DefaultHost = $LyceumHost
        DefaultPort = $Port
        Recommends  = @('seren-hippocampus')
        Secrets     = @{ 'hippocampus-token' = 'SEREN_HIPPOCAMPUS_TOKEN' }
        ConfigKeys  = @{ 'label' = 'local.label'; 'llama-cpp' = 'local.llama_cpp'; 'hf-home' = 'local.hf_home';
                         'train-python' = 'local.python'; 'hippocampus-url' = 'hippocampus.url';
                         'hippocampus-token' = 'hippocampus.bearer_token' }
    }
    Get-SerenDescribe @describeArgs
    exit 0
}
if ($Json) { Enable-SerenJson }
if (-not $HippocampusToken -and $env:SEREN_HIPPOCAMPUS_TOKEN) { $HippocampusToken = $env:SEREN_HIPPOCAMPUS_TOKEN }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\lyceum" }
$layout  = Get-SerenLayout -Root $Root -Short "lyceum" -Instance $Instance -VenvDir $VenvDir -AppDir "$env:USERPROFILE\seren-lyceum"
$VenvDir = $layout.Venv
$AppDir  = $layout.App
$CfgPath = "$AppDir\seren-lyceum.yaml"
$TrainVenv = "$VenvDir-train"
$global:Instance = $Instance
if ($Instance -and $Port -eq 7428) {
  Warn "Instance '$Instance' uses default port 7428 - may collide."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenLyceum setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

$pyInfo = Find-Python
$global:pyInfo = $pyInfo
if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenLyceum" }

$wheelSrc = $null
$cleanupWheel = $false
$pyExe = $pyInfo.Exe
$pyArgs = $pyInfo.Args
if ($Wheel) {
  if (-not (Test-Path $Wheel)) { Die "wheel not found: $Wheel" }
  $wheelSrc = (Resolve-Path $Wheel).Path
  Ok "Installing from local wheel: $(Split-Path $wheelSrc -Leaf)"
} elseif ($Local -or $Repo) {
  $wr = Resolve-Wheel -Wheel $Wheel -Local $Local -Ref $Ref -Repo $Repo -Package "seren-lyceum"
  $wheelSrc = $wr.Src
  $cleanupWheel = $wr.Cleanup
} elseif ($Pypi) {
  $wheelSrc = "seren-lyceum"
  Ok "Installing the latest seren-lyceum from PyPI"
} else {
  Step "Building a wheel from the SerenLyceum checkout"
  if (-not $RepoDir) { $RepoDir = Find-Upward "SerenLyceum" }
  $pkgDir = Join-Path $RepoDir "SerenLyceum"
  if (-not (Test-Path (Join-Path $pkgDir "pyproject.toml"))) {
    Die "SerenLyceum checkout not found at $pkgDir. Use -RepoDir, -Wheel, -Pypi, or -Ref."
  }
  $buildVenv = Join-Path ([System.IO.Path]::GetTempPath()) "build-venv-lyceum"
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

# -- the service's venv ---------------------------------------------------------
$vpy = Create-Venv -VenvDir $VenvDir -PyExe $pyExe -PyArgs $pyArgs
Install-Package -Vpy $vpy -WheelSrc $wheelSrc -Extras "" -Label ""
Sanity-Check -Vpy $vpy -Module "seren_lyceum" -AssetRelPath "viewer/ui/body.html" -AssetLabel "viewer pack"

# -- the training environment ---------------------------------------------------
# A second venv, reused when it is there: torch is gigabytes.
if ($TrainPython) {
  if (-not (Test-Path $TrainPython)) { Die "-TrainPython is not an interpreter: $TrainPython" }
  Ok "Training with the environment you named: $TrainPython"
} elseif ($Train) {
  Step "The training environment ($TrainVenv)"
  $TrainPython = Create-Venv -VenvDir $TrainVenv -PyExe $pyExe -PyArgs $pyArgs
  & $TrainPython -c "import torch" 2>$null
  if ($LASTEXITCODE -eq 0) {
    Ok "torch is already there: $(& $TrainPython -c 'import torch; print(torch.__version__)')"
  } else {
    Step "Installing torch from $TorchIndex (the big one)"
    & $TrainPython -m pip install -q --upgrade pip
    & $TrainPython -m pip install torch --index-url $TorchIndex
    if ($LASTEXITCODE -ne 0) { Die "torch did not install from $TorchIndex. A GPU needs a torch built for it; pick the index with -TorchIndex (cpu: https://download.pytorch.org/whl/cpu)." }
  }
  Install-Package -Vpy $TrainPython -WheelSrc $wheelSrc -Extras "[train]" -Label " (the trainer)"
} elseif (Test-Path "$TrainVenv\Scripts\python.exe") {
  $TrainPython = "$TrainVenv\Scripts\python.exe"
  Ok "Keeping the training environment that is there: $TrainVenv"
  Install-Package -Vpy $TrainPython -WheelSrc $wheelSrc -Extras "" -Label " (the trainer, upgraded beside the service)"
} else {
  Warn "No training environment (-Train builds one): this box will not train locally."
}
if ($cleanupWheel) { Remove-Item -Force $wheelSrc -ErrorAction SilentlyContinue }
if ($TrainPython) {
  $checked = (& $TrainPython -m seren_lyceum.trainer.cli --check 2>$null | Select-Object -Last 1)
  if ($checked -match '"ok": true') { Ok "The trainer answers" }
  else { Warn "The trainer's own check did not pass - the UI's This box tab says why." }
}

# -- what this box already knows --------------------------------------------------
if (-not $HfHome -and $env:HF_HOME) { $HfHome = $env:HF_HOME; Ok "Hugging Face's home: $HfHome" }
$hfProbe = if ($HfHome) { $HfHome } else { "$env:USERPROFILE\.cache\huggingface" }
if (Test-Path "$hfProbe\token") { Ok "A Hugging Face login is there already; the Lyceum will use it" }
else { Ok "No Hugging Face login yet - most models need none; the Lyceum asks when one does" }

# -- the sibling hippocampus ------------------------------------------------------
$hipTokenLines = ""
if ($HippocampusConfig) {
  $sib = Read-SerenSiblingConfig -Path $HippocampusConfig
  if (-not $HippocampusUrl) { $HippocampusUrl = $sib.Url }
  $hipTokenLines = Get-SerenSiblingTokenLines -Sib $sib -Indent "  "
}
if ($HippocampusToken) { $hipTokenLines = "  bearer_token: `"$HippocampusToken`"" }
if ($HippocampusUrl) { Ok "Lessons from the hippocampus at $HippocampusUrl" }

# -- config ---------------------------------------------------------------------
Step "Writing config at $CfgPath"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if ($GenToken) { $Token = & $vpy -c "import secrets; print(secrets.token_urlsafe(32))" }
if (-not $Token -and -not $GenToken) { $Token = Get-SerenReusedToken -Path $CfgPath }
if (-not $Token -and $LyceumHost -notmatch '^(127\.|localhost$|::1$)') {
  Warn "-LyceumHost $LyceumHost with no bearer: SerenLyceum will REFUSE TO START. Re-run with -GenToken (or -Token)."
}
if (Test-Path $CfgPath) {
  $bak = "$CfgPath.bak.$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
  Copy-Item $CfgPath $bak; (Get-Item $bak).LastWriteTime = Get-Date
  Warn "Existing config backed up to $(Split-Path $bak -Leaf)"
}
$stateDir = if ($layout.Data) { $layout.Data } else { "$env:USERPROFILE\.seren-lyceum" }
@"
# SerenLyceum config - generated by seren-lyceum-setup.ps1
server:
  host: $LyceumHost
  port: $Port
  bearer_token: "$Token"

storage:
  state_dir: '$stateDir'

local:
  python: '$TrainPython'
  llama_cpp: '$LlamaCpp'
  hf_home: '$HfHome'
  label: "$Label"
  max_parallel: 1
"@ | Write-SerenTextFile -Path $CfgPath

if ($HippocampusUrl) {
    @"

hippocampus:
  url: $HippocampusUrl
$hipTokenLines
"@ | Add-SerenTextFile -Path $CfgPath
}
if ($NoUpdates) {
    @"

updates:
  enabled: false
"@ | Add-SerenTextFile -Path $CfgPath
    Ok "Update checking disabled in config"
}
Ok "Config written"

$launcher = Write-Launcher -AppDir $AppDir -ServiceName "seren-lyceum" -Vpy $vpy -Module "seren_lyceum" -CfgPath $CfgPath

if ($Token -or $hipTokenLines) { Protect-SerenConfig -Path $CfgPath -ServiceUser $ServiceUser }
if ($Service) { Setup-Autostart -ScriptDir $ScriptDir -ServiceName "seren-lyceum" -AppDir $AppDir -Token $Token -VenvDir $VenvDir -ServiceUser $ServiceUser -LocalSystem:$LocalSystem }

$connectHost = if ($LyceumHost -eq "0.0.0.0") { "127.0.0.1" } else { $LyceumHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenLyceum is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) { Write-Host "  Start it:        $launcher" -ForegroundColor Blue }
Write-Host "  Viewer:          http://${connectHost}:$Port/viewer" -ForegroundColor Blue
Write-Host "  Health:          http://${connectHost}:$Port/health" -ForegroundColor Blue
if ($TrainPython) { Write-Host "  Trains with:     $TrainPython" -ForegroundColor Blue }
Write-Host ""
Write-Host "  We just train: you bring the data, you pick the model." -ForegroundColor Yellow
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green

$doneArgs = @{
    Service     = 'seren-lyceum'
    ConnectHost = $connectHost
    Port        = $Port
    Autostart   = ([bool] $Service)
    Token       = $Token
    Mcp         = $false
    Corp        = $false
    Vector      = $false
    Venv        = $VenvDir
    Config      = $CfgPath
}
$doneArgs["Bound"] = $PSBoundParameters
Send-SerenDone @doneArgs
