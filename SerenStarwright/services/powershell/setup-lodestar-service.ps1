<#
══════════════════════════════════════════════════════════════════════════
  setup-lodestar-service.ps1  -  SerenLodestar pointed wrapper (Windows/NSSM)

  Was setup-runtimehost-service.ps1 (.NET) — renamed when runtimehost → lodestar
  on PyPI. Now a Python service using the shared NSSM core.

  RUN IT: elevated PowerShell, as yourself.
    powershell -ExecutionPolicy Bypass -File .\setup-lodestar-service.ps1
    powershell -ExecutionPolicy Bypass -File .\setup-lodestar-service.ps1 -Instance Test
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
  [switch] $RunAsLocalSystem
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

# -- identity lines ------------------------------------------------------------
$ServiceName = "SerenLodestar$Instance"
$ModuleName  = "seren_lodestar"
if (-not $VenvDir)    { $VenvDir    = "$env:USERPROFILE\seren-venvs\lodestar$Instance" }
if (-not $AppDir)     { $AppDir     = "$env:USERPROFILE\seren-lodestar$Instance" }
if (-not $ConfigPath) { $ConfigPath = "$AppDir\seren-lodestar.yaml" }

# -- delegate to the shared generic core ----------------------------------------
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
  -HealthPath  "/api/v1/system/ping" `
  -DisplayName $ServiceName `
  -Description "SerenLodestar$Instance - cluster head / orchestrator" `
  -RunAsLocalSystem:$RunAsLocalSystem
