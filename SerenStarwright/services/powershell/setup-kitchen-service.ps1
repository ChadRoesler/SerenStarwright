<#
══════════════════════════════════════════════════════════════════════════
  setup-kitchen-service.ps1  -  SerenKitchen pointed wrapper (Windows/NSSM)

  The CONVENTION half of the generic-core / pointed-wrapper split. Knows what
  a SerenKitchen install looks like and hands it to setup-seren-service.ps1,
  which does the NSSM mechanics.

  INSTANCE CONVENTION (mirrors seren-kitchen-setup.ps1):
    -Instance "Test" suffixes everything:
      Service:  SerenKitchenTest
      Venv:     %USERPROFILE%\seren-venvs\kitchenTest
      AppDir:   %USERPROFILE%\seren-kitchenTest
      Config:   %USERPROFILE%\seren-kitchenTest\seren-kitchen.yaml
    Run the installer with -Instance Test FIRST, then this with the same.

  RUN IT: elevated PowerShell, as yourself.
    powershell -ExecutionPolicy Bypass -File .\setup-kitchen-service.ps1
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
$ServiceName = "SerenKitchen$Instance"
$ModuleName  = "seren_kitchen"
if (-not $VenvDir)    { $VenvDir    = "$env:USERPROFILE\seren-venvs\kitchen$Instance" }
if (-not $AppDir)     { $AppDir     = "$env:USERPROFILE\seren-kitchen$Instance" }
if (-not $ConfigPath) { $ConfigPath = "$AppDir\seren-kitchen.yaml" }

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
  -Description "SerenKitchen$Instance - the kitchen: a fridge per app, and the notes we leave each other" `
  -ExtraEnv    @("PYTHONUTF8=1") `
  -ServiceUser $ServiceUser `
  -RunAsLocalSystem:$RunAsLocalSystem
