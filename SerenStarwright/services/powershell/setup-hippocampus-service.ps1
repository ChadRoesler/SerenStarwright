<#
==========================================================================
  setup-hippocampus-service.ps1  -  SerenHippocampus pointed wrapper (Windows/NSSM)

  The CONVENTION half of the generic-core / pointed-wrapper split. Knows what
  a SerenHippocampus install looks like and hands it to setup-seren-service.ps1,
  which does the NSSM mechanics.

  INSTANCE CONVENTION (mirrors seren-hippocampus-setup.ps1):
    -Instance "Test" suffixes everything:
      Service:  SerenHippocampusTest
      Venv:     %USERPROFILE%\seren-venvs\hippocampusTest
      AppDir:   %USERPROFILE%\seren-hippocampusTest
      Config:   %USERPROFILE%\seren-hippocampusTest\seren-hippocampus.yaml

  RUN IT: elevated PowerShell, as yourself.
    powershell -ExecutionPolicy Bypass -File .\setup-hippocampus-service.ps1
==========================================================================
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

$ServiceName = "SerenHippocampus$Instance"
$ModuleName  = "seren_hippocampus"
if (-not $VenvDir)    { $VenvDir    = "$env:USERPROFILE\seren-venvs\hippocampus$Instance" }
if (-not $AppDir)     { $AppDir     = "$env:USERPROFILE\seren-hippocampus$Instance" }
if (-not $ConfigPath) { $ConfigPath = "$AppDir\seren-hippocampus.yaml" }

$core = Find-Upward "services\lib\setup-seren-service.ps1"
if (-not $core -or -not (Test-Path $core)) {
  Write-Host "ERROR: setup-seren-service.ps1 not found walking up from this script." -ForegroundColor Red
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
  -Description "SerenHippocampus$Instance - the sleep cycle for SerenMemory" `
  -ServiceUser $ServiceUser `
  -RunAsLocalSystem:$RunAsLocalSystem
