<#
══════════════════════════════════════════════════════════════════════════
  setup-soma-service.ps1  -  SerenSoma pointed wrapper (Windows/NSSM)

  The CONVENTION half of the generic-core / pointed-wrapper split. Knows what
  a SerenSoma install looks like and hands it to setup-seren-service.ps1,
  which does the NSSM mechanics.

  INSTANCE CONVENTION (mirrors seren-soma-setup.ps1):
    -Instance "Test" suffixes everything:
      Service:  SerenSomaTest
      Venv:     %USERPROFILE%\seren-venvs\somaTest
      AppDir:   %USERPROFILE%\seren-somaTest
      Config:   %USERPROFILE%\seren-somaTest\seren-soma.yaml
    Run the installer with -Instance Test FIRST, then this with the same.

  RUN IT: elevated PowerShell, as yourself.
    powershell -ExecutionPolicy Bypass -File .\setup-soma-service.ps1
══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [string] $Instance    = "",
  [string] $VenvDir     = "",
  [string] $AppDir      = "",
  [string] $ConfigPath  = "",
  [string] $LogDir      = "$env:USERPROFILE\seren-logs",
  [int]    $HealthPort  = 0,
  [switch] $RunAsLocalSystem,
  [string] $ServiceUser = ""
)

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

$ErrorActionPreference = "Stop"

# -- the identity lines (the whole point of this wrapper) ----------------------
$ServiceName = "SerenSoma$Instance"
$ModuleName  = "seren_soma"
if (-not $VenvDir)    { $VenvDir    = "$env:USERPROFILE\seren-venvs\soma$Instance" }
if (-not $AppDir)     { $AppDir     = "$env:USERPROFILE\seren-soma$Instance" }
if (-not $ConfigPath) { $ConfigPath = "$AppDir\seren-soma.yaml" }

$core = Find-Upward "services\lib\setup-seren-service.ps1"
if (-not $core -or -not (Test-Path $core)) {
  Write-Host "ERROR: setup-seren-service.ps1 not found walking up from this script." -ForegroundColor Red
  Write-Host "       The wrapper is just conventions - the core does the work. Keep the shared scripts together." -ForegroundColor Red
  exit 1
}

& $core `
  -ServiceName $ServiceName `
  -ModuleName  $ModuleName `
  -VenvDir     $VenvDir `
  -AppDir      $AppDir `
  -ConfigPath  $ConfigPath `
  -LogDir      $LogDir `
  -HealthPort  $HealthPort `
  -DisplayName $ServiceName `
  -Description "SerenSoma$Instance - the body's nervous system: a robot's voice, ears and touch" `
  -ExtraEnv    @("PYTHONUTF8=1") `
  -ServiceUser $ServiceUser `
  -RunAsLocalSystem:$RunAsLocalSystem
