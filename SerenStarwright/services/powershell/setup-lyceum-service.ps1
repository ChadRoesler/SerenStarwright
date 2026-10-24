<#
══════════════════════════════════════════════════════════════════════════
  setup-lyceum-service.ps1  -  SerenLyceum pointed wrapper (Windows/NSSM)

  The CONVENTION half of the generic-core / pointed-wrapper split. Knows what
  a SerenLyceum install looks like and hands it to setup-seren-service.ps1,
  which does the NSSM mechanics.

  INSTANCE CONVENTION (mirrors seren-lyceum-setup.ps1):
    -Instance "Test" suffixes everything:
      Service:  SerenLyceumTest
      Venv:     %USERPROFILE%\seren-venvs\lyceumTest
      AppDir:   %USERPROFILE%\seren-lyceumTest
      Config:   %USERPROFILE%\seren-lyceumTest\seren-lyceum.yaml

  -KeepChildren: the service forks the trainer, detached, and NSSM stops a
  service by killing its whole process tree. Restarting the service (an
  upgrade, a config change) must not kill a run mid-epoch; the runner finds
  the trainer again by its pid when it comes back.

  RUN IT: elevated PowerShell, as yourself.
    powershell -ExecutionPolicy Bypass -File .\setup-lyceum-service.ps1
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

$ServiceName = "SerenLyceum$Instance"
$ModuleName  = "seren_lyceum"
if (-not $VenvDir)    { $VenvDir    = "$env:USERPROFILE\seren-venvs\lyceum$Instance" }
if (-not $AppDir)     { $AppDir     = "$env:USERPROFILE\seren-lyceum$Instance" }
if (-not $ConfigPath) { $ConfigPath = "$AppDir\seren-lyceum.yaml" }

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
  -Description "SerenLyceum$Instance - train a model: a dataset in, a model out" `
  -ExtraEnv    @("PYTHONUTF8=1") `
  -KeepChildren `
  -ServiceUser $ServiceUser `
  -RunAsLocalSystem:$RunAsLocalSystem
