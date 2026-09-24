<#
==========================================================================
  seren-dev-publish.ps1  -  every checkout in SerenCore, built into ONE folder

  The quick revision loop. Edit any Seren project, run this, and every card
  (bash or PowerShell, in the TUI or by hand) can install what is on disk
  right now instead of a release:

      .\seren-dev-publish.ps1                  # build all, into the house
      .\seren-dev-publish.ps1 -Serve           # ...and serve it on :8765
      .\seren-memory-setup.ps1 -Local ..\..\.dev-wheelhouse
      bash seren-memory-setup.sh --local http://devbox:8765     # from a node

  Mirror of seren-dev-publish.sh; see it for what a "house" is and why the
  versions are whatever setuptools-scm says.

  FLAGS
    -Core DIR        The folder holding the checkouts   (default: ..\..)
    -House DIR       Where to publish                    (default: CORE\.dev-wheelhouse)
    -Only A,B        Build only these repos (SerenMemory,SerenLoci,... or starwright)
    -Skip A,B        Build everything except these
    -NoIsolation     python -m build --no-isolation (needs setuptools-scm installed)
    -Clean           Empty the house first
    -Serve           After building, serve the house on 0.0.0.0:Port
    -Port N          Port for -Serve (default 8765)

  WINDOWS POWERSHELL 5.1-SAFE. ASCII-only on purpose.
==========================================================================
#>
[CmdletBinding()]
param(
  [string]   $Core = "",
  [string]   $House = "",
  [string[]] $Only = @(),
  [string[]] $Skip = @(),
  [switch]   $NoIsolation,
  [switch]   $Clean,
  [switch]   $Serve,
  [int]      $Port = 8765
)
# Continue, not Stop: every native call below checks $LASTEXITCODE itself, and
# under Windows PowerShell 5.1 a Stop preference turns a native command's
# redirected stderr into a terminating error - `py -3.12` saying "no such
# runtime" would end the script instead of moving to the next candidate.
$ErrorActionPreference = "Continue"
$ScriptDir = $PSScriptRoot
# `-Only A,B` is a real array from a PowerShell prompt and ONE string "A,B"
# when the script is run with -File from cmd or bash; accept both.
$Only = @($Only | ForEach-Object { $_ -split "," } | Where-Object { $_ })
$Skip = @($Skip | ForEach-Object { $_ -split "," } | Where-Object { $_ })
if (-not $Core) { $Core = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path }
else { $Core = (Resolve-Path $Core).Path }
if (-not $House) { $House = Join-Path $Core ".dev-wheelhouse" }

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Blue }
function Ok($m)   { Write-Host "  + $m"   -ForegroundColor Green }
function Warn($m) { Write-Host "  ! $m"   -ForegroundColor Yellow }
function Die($m)  { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
$utf8 = New-Object System.Text.UTF8Encoding $false
function Write-Lf([string] $Path, [string] $Text) { [System.IO.File]::WriteAllText($Path, $Text, $utf8) }

if (-not (Test-Path (Join-Path $Core "SerenMeninges\SerenMeninges\pyproject.toml"))) {
  Die "$Core does not look like SerenCore (no SerenMeninges\SerenMeninges\pyproject.toml). Point -Core at the folder holding the checkouts."
}

# -- a Python with `build` ------------------------------------------------------
$Py = $null
foreach ($c in @("py -3.12", "py -3.11", "py -3.10", "python", "py -3")) {
  $exe, $args_ = $c.Split(" ", 2)
  $pyArgs = @(); if ($args_) { $pyArgs = @($args_) }
  try {
    $v = & $exe @pyArgs -c "import sys; print('%d.%d.%d' % sys.version_info[:3]); sys.exit(0 if sys.version_info >= (3, 10) else 1)" 2>$null
    if ($LASTEXITCODE -eq 0 -and $v) { $Py = @{ Exe = $exe; Args = $pyArgs; Ver = ($v | Select-Object -Last 1) }; break }
  } catch { }
}
if (-not $Py) { Die "no Python 3.10+ found" }
$null = & $Py.Exe @($Py.Args) -c "import build" 2>&1
if ($LASTEXITCODE -ne 0) { Die "the 'build' module is missing:  $($Py.Exe) $($Py.Args) -m pip install build" }
if ($NoIsolation) {
  $null = & $Py.Exe @($Py.Args) -c "import setuptools_scm, wheel" 2>&1
  if ($LASTEXITCODE -ne 0) { Die "-NoIsolation needs setuptools-scm and wheel:  $($Py.Exe) $($Py.Args) -m pip install setuptools setuptools-scm wheel" }
}
Ok "Building with $($Py.Exe) $($Py.Args) ($($Py.Ver))"

# -- which projects -----------------------------------------------------------
function Wanted([string] $n) {
  if ($Only.Count -gt 0 -and ($Only -notcontains $n)) { return $false }
  if ($Skip -contains $n) { return $false }
  return $true
}
$projects = @()
foreach ($d in (Get-ChildItem -Path $Core -Directory -Filter "Seren*")) {
  if (-not (Test-Path (Join-Path $d.FullName "$($d.Name)\pyproject.toml"))) { continue }
  if (Wanted $d.Name) { $projects += $d.Name }
}
$buildTui = Wanted "starwright"
if ($projects.Count -eq 0 -and -not $buildTui) { Die "nothing selected (check -Only / -Skip)" }

New-Item -ItemType Directory -Path $House -Force | Out-Null
if ($Clean) {
  Step "Emptying $House"
  Get-ChildItem -Path $House -File | Where-Object { $_.Name -like "*.whl" -or $_.Name -like "*.pyz" -or $_.Name -in @("SHA256SUMS", "MANIFEST") } | Remove-Item -Force
}
$manifestPath = Join-Path $House "MANIFEST"
if (-not (Test-Path $manifestPath)) { Write-Lf $manifestPath "# file`tversion`tgit`tbuilt`n" }

# MANIFEST is keyed by file name: a rebuilt project replaces its own row, a
# project left alone keeps the row from the run that built it, and a file
# that is no longer in the house loses its row at the end.
function Record([string] $File, [string] $Version, [string] $Git) {
  $rows = @(Get-Content $manifestPath | Where-Object { -not $_.StartsWith("$File`t") })
  $rows += "$File`t$Version`t$Git`t$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
  Write-Lf $manifestPath (($rows -join "`n") + "`n")
}
function GitDescribe([string] $Dir) {
  try {
    $d = (& git -C $Dir describe --tags --dirty --always 2>$null)
    if ($LASTEXITCODE -eq 0 -and $d) { return ($d | Select-Object -Last 1) }
  } catch { }
  return "no-git"
}

# -- build each project ----------------------------------------------------------
$built = 0; $failed = @()
foreach ($n in $projects) {
  $pkg = Join-Path $Core "$n\$n"
  Step $n
  $out = Join-Path ([System.IO.Path]::GetTempPath()) ("seren_build_" + [System.IO.Path]::GetRandomFileName().Replace(".", ""))
  New-Item -ItemType Directory -Path $out -Force | Out-Null
  $bargs = @("-m", "build", "--wheel", "--outdir", $out)
  if ($NoIsolation) { $bargs += "--no-isolation" }
  $bargs += $pkg
  $log = Join-Path $out "build.log"
  & $Py.Exe @($Py.Args) @bargs 2>&1 | Out-File -FilePath $log -Encoding utf8
  $whl = Get-ChildItem -Path $out -Filter "*.whl" | Select-Object -First 1
  if ($LASTEXITCODE -ne 0 -or -not $whl) {
    Warn "$n failed to build - see $log"
    Get-Content $log -Tail 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    $failed += $n; continue
  }
  $parts = $whl.Name.Split("-")
  $dist = $parts[0]; $ver = $parts[1]
  # one wheel per project in the house: the old build of THIS project goes
  Get-ChildItem -Path $House -Filter "$dist-*.whl" | Remove-Item -Force
  Move-Item -Path $whl.FullName -Destination (Join-Path $House $whl.Name) -Force
  Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
  $g = GitDescribe (Join-Path $Core $n)
  Record $whl.Name $ver $g
  Ok "$($whl.Name)   ($g)"
  $built++
}

# -- Starwright itself ------------------------------------------------------------
if ($buildTui) {
  Step "starwright.pyz"
  $pyz = Join-Path $House "starwright.pyz"
  $log = Join-Path $House ".starwright-build.log"
  $hostExe = (Get-Process -Id $PID).Path
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir "build-starwright.ps1") -Out $pyz 2>&1 | Out-File -FilePath $log -Encoding utf8
  if ($LASTEXITCODE -eq 0 -and (Test-Path $pyz)) {
    $g = GitDescribe $ScriptDir
    Record "starwright.pyz" $g $g
    Ok "starwright.pyz   ($g)"
    Remove-Item -Force $log -ErrorAction SilentlyContinue
  } else {
    Warn "starwright.pyz failed to build - see $log"
    $failed += "starwright"
  }
}

# -- index -----------------------------------------------------------------------
Step "Indexing $House"
$files = @(Get-ChildItem -Path $House -File | Where-Object { $_.Name -like "*.whl" -or $_.Name -like "*.pyz" } | Sort-Object Name)
$sums = @()
foreach ($f in $files) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $h = ([System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($f.FullName)))).Replace("-", "").ToLower()
  $sums += "$h  $($f.Name)"
}
Write-Lf (Join-Path $House "SHA256SUMS") ((($sums -join "`n") + "`n").TrimStart())
# drop MANIFEST rows for files that are gone
$rows = @(Get-Content $manifestPath | Where-Object { $_.StartsWith("#") -or (Test-Path (Join-Path $House $_.Split("`t")[0])) })
Write-Lf $manifestPath (($rows -join "`n") + "`n")
Ok "$($files.Count) file(s) indexed, $built built this run"
if ($failed.Count -gt 0) { Warn "did not build: $($failed -join ', ')" }

Write-Host ""
Write-Host "Install from it:"
Write-Host "  .\services\powershell\seren-memory-setup.ps1 -Local $House"
Write-Host "  (or fill in 'dev wheelhouse' on Starwright's options screen)"

# -- serve ------------------------------------------------------------------------
if ($Serve) {
  $ip = $null
  try {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
           Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.PrefixOrigin -ne "WellKnown" } |
           Select-Object -First 1).IPAddress
  } catch { }
  if (-not $ip) { $ip = $env:COMPUTERNAME }
  Write-Host ""
  Write-Host "Serving $House on port $Port. From a node:"
  Write-Host "  --local http://${ip}:$Port"
  Write-Host "  curl -fsSLO http://${ip}:$Port/starwright.pyz && python3 starwright.pyz"
  Write-Host "Ctrl-C stops it. (Windows Firewall may ask once - it is python.exe listening.)"
  & $Py.Exe @($Py.Args) -m http.server $Port --bind 0.0.0.0 --directory $House
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
