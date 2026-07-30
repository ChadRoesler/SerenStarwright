<#
══════════════════════════════════════════════════════════════════════════
  setup-observatory-service.ps1  -  SerenObservatory pointed wrapper (Windows/NSSM)

  Was setup-agent-service.ps1 — renamed when agent → observatory on PyPI.
  Follows the Memory/Loci service-wrapper pattern.

  RUN IT: elevated PowerShell, as yourself.
    powershell -ExecutionPolicy Bypass -File .\setup-observatory-service.ps1
    powershell -ExecutionPolicy Bypass -File .\setup-observatory-service.ps1 -Instance Test
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
$ServiceName = "SerenObservatory$Instance"
$ModuleName  = "seren_observatory"
if (-not $VenvDir)    { $VenvDir    = "$env:USERPROFILE\seren-venvs\observatory$Instance" }
if (-not $AppDir)     { $AppDir     = "$env:USERPROFILE\seren-observatory$Instance" }
if (-not $ConfigPath) { $ConfigPath = "$AppDir\seren-observatory.yaml" }

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
  -Description "SerenObservatory$Instance - per-node management plane" `
  -RunAsLocalSystem:$RunAsLocalSystem
