<#
══════════════════════════════════════════════════════════════════════════
  setup-theatre-service.ps1  -  SerenTheatre pointed wrapper (Windows/NSSM)

  The CONVENTION half of the generic-core / pointed-wrapper split. Knows what
  a SerenTheatre install looks like and hands it to setup-seren-service.ps1,
  which does the NSSM mechanics. Lives alongside the core in
  the SerenStarwright repo.

  INSTANCE CONVENTION (mirrors seren-theatre-setup.ps1):
    -Instance "Test" suffixes everything:
      Service:  SerenTheatreTest
      Venv:     %USERPROFILE%\seren-venvs\theatreTest
      AppDir:   %USERPROFILE%\seren-theatreTest
      Config:   %USERPROFILE%\seren-theatreTest\seren-theatre.yaml
    Run the installer with -Instance Test FIRST, then this with the same.

  Theatre holds no bearer token (localhost-only, read-only, nothing to
  authorise) and its memory profile is FastAPI plus however much of a log tail
  it was told to read - 256 KiB by default. Same shape as Margin.

  RUN IT: elevated PowerShell, as yourself.
    powershell -ExecutionPolicy Bypass -File .\setup-theatre-service.ps1
    powershell -ExecutionPolicy Bypass -File .\setup-theatre-service.ps1 -Instance Test
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
  # Pass-through only. The core owns the credential logic; this wrapper just
  # refuses to be the reason a non-interactive install can't name its account.
  [string] $ServiceUser = ""
)


# -- locate a file by walking UP the tree (reorg-robust; injected by fixup) ---
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

# -- the four identity lines (the whole point of this wrapper) ----------------
$ServiceName = "SerenTheatre$Instance"
$ModuleName  = "seren_theatre"
if (-not $VenvDir)    { $VenvDir    = "$env:USERPROFILE\seren-venvs\theatre$Instance" }
if (-not $AppDir)     { $AppDir     = "$env:USERPROFILE\seren-theatre$Instance" }
if (-not $ConfigPath) { $ConfigPath = "$AppDir\seren-theatre.yaml" }

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
  -Description "SerenTheatre$Instance - watch a model being made (read-only viewer over training logs)" `
  -ServiceUser $ServiceUser `
  -RunAsLocalSystem:$RunAsLocalSystem
