<#
══════════════════════════════════════════════════════════════════════════
  setup-psycheion-service.ps1  -  SerenPsycheion pointed wrapper (Windows/NSSM)

  The CONVENTION half of the generic-core / pointed-wrapper split. Knows what
  a SerenPsycheion install looks like and hands it to setup-seren-service.ps1,
  which does the NSSM mechanics.

  INSTANCE CONVENTION (mirrors seren-psycheion-setup.ps1):
    -Instance "Test" suffixes everything:
      Service:  SerenPsycheionTest
      Venv:     %USERPROFILE%\seren-venvs\psycheionTest
      AppDir:   %USERPROFILE%\seren-psycheionTest
      Config:   %USERPROFILE%\seren-psycheionTest\seren-psycheion.yaml
    Run the installer with -Instance Test FIRST, then this with the same.

  RUN IT: elevated PowerShell, as yourself.
    powershell -ExecutionPolicy Bypass -File .\setup-psycheion-service.ps1
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
$ServiceName = "SerenPsycheion$Instance"
$ModuleName  = "seren_psycheion"
if (-not $VenvDir)    { $VenvDir    = "$env:USERPROFILE\seren-venvs\psycheion$Instance" }
if (-not $AppDir)     { $AppDir     = "$env:USERPROFILE\seren-psycheion$Instance" }
if (-not $ConfigPath) { $ConfigPath = "$AppDir\seren-psycheion.yaml" }

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
  -Description "SerenPsycheion$Instance - the mind's workshop for a Seren body" `
  -ExtraEnv    @("PYTHONUTF8=1") `
  -ServiceUser $ServiceUser `
  -RunAsLocalSystem:$RunAsLocalSystem
