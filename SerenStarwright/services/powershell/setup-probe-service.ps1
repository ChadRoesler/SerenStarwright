<#
# ══════════════════════════════════════════════════════════════════════════
#  setup-probe-service.ps1  -  SerenProbe pointed wrapper (Windows/NSSM)
#
#  Local-only probe — no bearer token, no env vars. Follows the Margin
#  pattern (private, localhost-only).
#
#  INSTANCE CONVENTION (mirrors seren-probe-setup.ps1):
#    -Instance "Test" suffixes everything:
#      Service:  SerenProbeTest
#      Venv:     %USERPROFILE%\seren-venvs\probeTest
#      AppDir:   %USERPROFILE%\seren-probeTest
#      Config:   %USERPROFILE%\seren-probeTest\seren-probe.yaml
#    Run the installer with -Instance Test FIRST, then this with the same.
#
#  RUN IT: elevated PowerShell, as yourself.
#    powershell -ExecutionPolicy Bypass -File .\setup-probe-service.ps1
#    powershell -ExecutionPolicy Bypass -File .\setup-probe-service.ps1 -Instance Test
# ══════════════════════════════════════════════════════════════════════════
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


# -- locate a file by walking UP the tree (reorg-robust) -----------------------
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

# -- the four identity lines ------------------------------------------------
$ServiceName = "SerenProbe$Instance"
$ModuleName  = "seren_probe"
if (-not $VenvDir)    { $VenvDir    = "$env:USERPROFILE\seren-venvs\probe$Instance" }
if (-not $AppDir)     { $AppDir     = "$env:USERPROFILE\seren-probe$Instance" }
if (-not $ConfigPath) { $ConfigPath = "$AppDir\seren-probe.yaml" }

# -- delegate to the shared generic core --------------------------------------
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
  -Description "SerenProbe$Instance local health and telemetry probe"
