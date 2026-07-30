<#
==========================================================================
  starwright.ps1  -  launch Seren Starwright (the TUI installer) on Windows

  Bootstraps its own venv, installs textual into it, then runs the TUI.
  Mirror of starwright.sh.

  WHY A VENV: Starwright is meant to be the FIRST thing you run, so it can't
  assume a usable Python environment exists. It does what every other
  installer in this repo does - its own venv under seren-venvs - rather than
  dirtying the system interpreter.

  Idempotent. Re-run whenever; it reuses the venv if present.

  USAGE
    powershell -ExecutionPolicy Bypass -File .\starwright.ps1
    powershell -ExecutionPolicy Bypass -File .\starwright.ps1 -Dump
    powershell -ExecutionPolicy Bypass -File .\starwright.ps1 -Recreate

  TERMINAL NOTE: Textual wants a modern terminal. Windows Terminal is fine;
  the legacy conhost window (the blue-ish one from cmd.exe) renders boxes and
  colors poorly. If it looks like garbage, that's the terminal, not the app.

  WINDOWS POWERSHELL 5.1-SAFE. No ternary, no ??, no pipeline chain ops.
  Deliberately ASCII-only: a BOM-less .ps1 is read as the ANSI codepage by
  5.1, so box-drawing characters would render as mojibake.
==========================================================================
#>
[CmdletBinding()]
param(
  [switch] $Dump,       # print discovered services as text, no TUI
  [switch] $Recreate    # delete and rebuild the venv
)

$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$Tui       = Join-Path $ScriptDir "starwright\seren-starwright.py"

$VenvRoot = $env:SEREN_STARWRIGHT_VENV
if (-not $VenvRoot) { $VenvRoot = Join-Path $env:USERPROFILE "seren-venvs\starwright" }

function Ok   ($m) { Write-Host "  + $m" -ForegroundColor Green }
function Info ($m) { Write-Host "$m"     -ForegroundColor Blue }
function Die  ($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $Tui)) { Die "seren-starwright.py not found at $Tui" }

if ($Recreate -and (Test-Path $VenvRoot)) {
    Remove-Item -Recurse -Force $VenvRoot
    Ok "removed $VenvRoot"
}

# -- find a Python ------------------------------------------------------------
# The py launcher is the idiomatic Windows way and knows about every installed
# version; fall back to whatever `python` resolves to. Same 3.10+ floor as the
# service installers.
$PyExe  = $null
$PyArgs = @()
foreach ($v in @("3.12", "3.11", "3.10", "3")) {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        & py "-$v" -c "import sys" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $PyExe = "py"; $PyArgs = @("-$v"); break }
    }
}
if (-not $PyExe) {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { $PyExe = $cmd.Source; $PyArgs = @() }
}
if (-not $PyExe) {
    Die "No Python found. Install 3.10-3.12 from python.org or:  winget install Python.Python.3.12"
}

# -- create the venv ----------------------------------------------------------
$VPy = Join-Path $VenvRoot "Scripts\python.exe"
if (-not (Test-Path $VPy)) {
    Info "Bootstrapping Starwright into $VenvRoot ..."
    & $PyExe @PyArgs -m venv $VenvRoot
    if ($LASTEXITCODE -ne 0) { Die "venv creation failed" }
    Ok "venv created"
}

# -- install textual ----------------------------------------------------------
& $VPy -c "import textual" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Info "Installing textual ..."
    & $VPy -m pip install -q --upgrade pip
    & $VPy -m pip install -q textual
    if ($LASTEXITCODE -ne 0) { Die "could not install textual (no network?)" }
    Ok "textual installed"
}

# -- run ----------------------------------------------------------------------
$RunArgs = @($Tui)
if ($Dump) { $RunArgs += "--dump" }
& $VPy @RunArgs
exit $LASTEXITCODE
