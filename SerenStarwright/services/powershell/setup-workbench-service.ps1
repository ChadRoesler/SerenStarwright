<#
══════════════════════════════════════════════════════════════════════════
  setup-workbench-service.ps1  -  SerenWorkbench pointed wrapper (Windows/NSSM)

  Was setup-mcp-service.ps1 (.NET) — renamed when mcp → workbench on PyPI.
  Now a Python service using the shared NSSM core (setup-seren-service.ps1).

  RUN IT: elevated PowerShell, as yourself.
    powershell -ExecutionPolicy Bypass -File .\setup-workbench-service.ps1
    powershell -ExecutionPolicy Bypass -File .\setup-workbench-service.ps1 -Instance Test
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
$ServiceName = "SerenWorkbench$Instance"
$ModuleName  = "seren_workbench"
if (-not $VenvDir)    { $VenvDir    = "$env:USERPROFILE\seren-venvs\workbench$Instance" }
if (-not $AppDir)     { $AppDir     = "$env:USERPROFILE\seren-workbench$Instance" }
if (-not $ConfigPath) { $ConfigPath = "$AppDir\seren-workbench.yaml" }

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
  -DisplayName $ServiceName `
  -Description "SerenWorkbench$Instance - user-facing MCP/IDE" `
  -RunAsLocalSystem:$RunAsLocalSystem
