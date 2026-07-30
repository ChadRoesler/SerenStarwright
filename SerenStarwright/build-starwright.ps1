<#
==========================================================================
  build-starwright.ps1  -  bundle Seren Starwright into ONE runnable file

  Produces dist\starwright.pyz - a ~2.4MB zipapp (PEP 441) with textual,
  rich and their whole dependency tree inside it. Runs on any box with a
  python3 and nothing else installed:

      python starwright.pyz
      python starwright.pyz --dump

  Mirror of build-starwright.sh. Same archive format, so a .pyz built on
  Windows runs on the Jetsons and vice versa - it's pure Python, there is
  nothing platform-specific in it.

  WHY THIS WORKS, AND WHEN IT WOULDN'T:
  zipapp can only bundle PURE PYTHON. Python cannot load a C extension from
  inside a zip archive, so a single .pyd/.so anywhere in the tree breaks it.
  Starwright's tree (textual -> rich, markdown-it-py, pygments, platformdirs,
  linkify-it-py, mdurl, uc-micro-py, typing_extensions) is pure Python end to
  end. The guard below FAILS THE BUILD if that ever changes, rather than
  shipping an archive that explodes on someone's box.

  If it does change, reach for shiv or pex - same single-file shape, but they
  unpack to a cache dir on first run so native bits land on a real filesystem.

  WHAT THIS IS NOT:
  Unlike `dotnet publish --self-contained`, this does NOT bundle the Python
  runtime; the target needs a python3. That costs nothing here - every seren-*
  installer already requires Python 3.10-3.12, so a box without Python can't
  install anything anyway. A true zero-runtime binary means PyInstaller or
  Nuitka, at the price of a separate build per platform and 15-40MB apiece.

  THE INSTALLERS ARE BUNDLED. Starwright RUNS the scripts under services\ and
  nodes\, so the archive carries a copy plus a generated layout marker. An
  on-disk checkout still WINS when one is present, so a dev keeps editing live
  scripts; the bundled copy is the fallback for a bare box, and it extracts to
  real files at a printed path so they stay readable and patchable at 2am.

  USAGE
    powershell -ExecutionPolicy Bypass -File .\build-starwright.ps1
    powershell -ExecutionPolicy Bypass -File .\build-starwright.ps1 -Out C:\tmp\starwright.pyz

  WINDOWS POWERSHELL 5.1-SAFE. ASCII-only on purpose (see starwright.ps1).
==========================================================================
#>
[CmdletBinding()]
param(
  [string] $Out = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$Src       = Join-Path $ScriptDir "seren_starwright\seren-starwright.py"
if (-not $Out) { $Out = Join-Path $ScriptDir "dist\starwright.pyz" }

function Ok   ($m) { Write-Host "  + $m" -ForegroundColor Green }
function Info ($m) { Write-Host "$m"     -ForegroundColor Blue }
function Die  ($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $Src)) { Die "seren-starwright.py not found at $Src" }

# -- locate the repo root and read its declared layout ------------------------
# Walk UP for the marker rather than assuming it sits beside this script. The
# repo uses the nested Visual Studio layout, so .starwright-root is a level
# ABOVE build-starwright.ps1 - and this file used to look only in $PSScriptRoot,
# which is why a local build died with "not found" while the bash builder (which
# already walked up) was perfectly happy. Mirror of build-starwright.sh.
$RepoRoot = $null
$dir = $ScriptDir
while ($dir) {
    if (Test-Path (Join-Path $dir ".starwright-root")) { $RepoRoot = $dir; break }
    $parent = Split-Path $dir -Parent
    if ($parent -eq $dir) { break }     # UNC / drive-root guard
    $dir = $parent
}
if (-not $RepoRoot) {
    Die "no .starwright-root found at or above $ScriptDir"
}
Ok "repo root: $RepoRoot"

# Honour the layout the marker declares instead of hardcoding it. The whole
# point of the marker is that a reorg costs two lines in ONE file; a builder
# that assumes the shape re-introduces exactly the coupling it removed.
function Get-LayoutValue([string] $Key, [string] $Fallback) {
    $result = $Fallback
    foreach ($line in (Get-Content -LiteralPath (Join-Path $RepoRoot ".starwright-root"))) {
        $stripped = ($line -split '#', 2)[0]
        if ($stripped -match "^\s*$Key\s*=\s*(.+?)\s*$") { $result = $Matches[1]; break }
    }
    return $result
}
# Marker values use forward slashes; make them Windows paths.
$ServicesRel = (Get-LayoutValue "services" "services").Replace("/", "\")
$NodesRel    = (Get-LayoutValue "nodes"    "nodes").Replace("/", "\")

# -- find a Python ------------------------------------------------------------
$PyExe  = $null
$PyArgs = @()
foreach ($v in @("3.12", "3.11", "3.10", "3")) {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        & py "-$v" -c "import sys" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $PyExe = "py"; $PyArgs = @("-$v"); break }
    }
}
if (-not $PyExe) {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { $PyExe = $cmd.Source; $PyArgs = @() }
}
if (-not $PyExe) { Die "No Python found. winget install Python.Python.3.12" }

# -- staging dir --------------------------------------------------------------
$Build = Join-Path ([System.IO.Path]::GetTempPath()) ("starwright-build-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $Build -Force | Out-Null

try {
    Info "Bundling with $PyExe $PyArgs ..."
    & $PyExe @PyArgs -m pip install --quiet --target $Build textual
    if ($LASTEXITCODE -ne 0) { Die "pip install failed" }

    Copy-Item $Src (Join-Path $Build "__main__.py") -Force

    # -- bundle the installers themselves -------------------------------------
    # Starwright RUNS these; without them the archive is a UI with nothing
    # behind it. Unpacked at runtime to ~/.seren-starwright\<archive>-<stamp>\
    # ONLY when no real checkout is found - on-disk always wins, so a dev in a
    # checkout keeps editing live scripts. The fallback extracts to real files
    # at a printed path, so they stay readable and patchable in the field.
    $bundle = Join-Path $Build "_seren_scripts"
    New-Item -ItemType Directory -Path $bundle -Force | Out-Null
    $bundled = 0
    # Source path (as the repo arranges it) -> bundle path (always flat).
    $pairs = @(
        @{ From = (Join-Path $ServicesRel "bash");       To = "services\bash" },
        @{ From = (Join-Path $ServicesRel "powershell"); To = "services\powershell" },
        @{ From = (Join-Path $ServicesRel "lib");        To = "services\lib" },
        @{ From = $NodesRel;                             To = "nodes" },
        @{ From = (Join-Path $NodesRel "lib");           To = "nodes\lib" },
        @{ From = (Join-Path $NodesRel "xavier");        To = "nodes\xavier" },
        @{ From = (Join-Path $NodesRel "nano");          To = "nodes\nano" },
        @{ From = (Join-Path $NodesRel "spark");         To = "nodes\spark" }
    )
    foreach ($p in $pairs) {
        $srcDir = Join-Path $RepoRoot $p.From
        if (-not (Test-Path $srcDir)) { continue }
        $dstDir = Join-Path $bundle $p.To
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        # Only the installer surface, and only the top level of each dir.
        Get-ChildItem $srcDir -File | Where-Object {
            ($_.Extension -eq ".sh" -or $_.Extension -eq ".ps1")
        } | ForEach-Object {
            Copy-Item $_.FullName $dstDir -Force
            $bundled++
        }
    }
    if ($bundled -eq 0) { Die "bundled zero scripts - is $RepoRoot the repo root?" }

    # The bundle gets its OWN marker, GENERATED - not a copy of the repo's.
    #
    # This is the subtle one, and it is why fixing only the walk-up above would
    # have produced a BUILD THAT SUCCEEDS AND AN ARCHIVE THAT DOESN'T WORK. The
    # repo nests its project, so its marker reads
    #     services = SerenStarwright/SerenStarwright/services
    # but the bundle lays everything out FLAT. Copying that marker verbatim
    # ships an archive that extracts cleanly and then discovers nothing. The
    # bundle's layout is this script's decision, so this script declares it.
    $flatMarker = @(
        "# Generated by build-starwright.ps1 for the bundled copy of the installers.",
        "# The bundle layout is always flat, whatever shape the source repo is in.",
        "services = services",
        "nodes    = nodes"
    ) -join "`n"
    Set-Content -Path (Join-Path $bundle ".starwright-root") -Value $flatMarker -Encoding ASCII
    Ok "bundled $bundled script(s) + a generated flat-layout marker"

    # -- version stamp ----------------------------------------------------
    # A .pyz on a Jetson has no repo to interrogate, so the answer to "which
    # build is this?" has to travel inside the archive. Env var (CI passes the
    # tag) -> git describe -> timestamp, so the field is never empty.
    $stamp = $env:SEREN_STARWRIGHT_VERSION
    if (-not $stamp) {
        $stamp = (& git -C $RepoRoot describe --tags --always --dirty 2>$null)
    }
    if (-not $stamp) { $stamp = "untagged-" + (Get-Date -Format "yyyyMMddTHHmmssZ") }
    Set-Content -Path (Join-Path $Build "_starwright_version.txt") `
                -Value $stamp -Encoding UTF8 -NoNewline
    Ok "version stamp: $stamp"

    # Trim install-time-only metadata; keeps the archive ~2.4MB not ~11MB.
    Get-ChildItem $Build -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*.dist-info" -or $_.Name -eq "__pycache__" -or $_.Name -eq "tests" } |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    # -- the guard that keeps this honest -------------------------------------
    $native = Get-ChildItem $Build -Recurse -File -ErrorAction SilentlyContinue |
              Where-Object { $_.Extension -eq ".pyd" -or $_.Extension -eq ".so" } |
              Select-Object -First 5
    if ($native) {
        foreach ($n in $native) { Write-Host "    $($n.Name)" -ForegroundColor Red }
        Die @"
compiled extension(s) in the dependency tree - zipapp cannot load these from
  inside an archive. Switch to shiv or pex, which unpack to a cache dir:
      pip install shiv
      shiv -c seren-starwright -o starwright.pyz textual
"@
    }
    Ok "dependency tree is pure Python (no .pyd/.so)"

    $outDir = Split-Path $Out -Parent
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    & $PyExe @PyArgs -m zipapp $Build -o $Out -p "/usr/bin/env python3" -c
    if ($LASTEXITCODE -ne 0) { Die "zipapp failed" }

    $OutFull = (Resolve-Path -LiteralPath $Out).Path
    $sizeMb  = [math]::Round((Get-Item $OutFull).Length / 1MB, 1)
    Ok "built $OutFull ($sizeMb MB)"

    # -- prove it runs, rather than assuming ----------------------------------
    # FROM A NEUTRAL DIRECTORY, WITH THE ROOT OVERRIDES CLEARED. An on-disk
    # checkout always beats the bundled copy, so running --dump from inside the
    # repo proves the REPO works and says nothing at all about the archive - it
    # would pass just as happily with a bundle that discovers nothing. This is
    # what let a bad marker ship looking healthy. Same neutral-dir shape the
    # release workflow uses, and fatal for the same reason: an artifact that
    # can't find its own scripts is not an artifact.
    $smokeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("starwright-smoke-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $smokeDir -Force | Out-Null
    $savedRoot   = $env:SEREN_STARWRIGHT_ROOT
    $savedOldRoot= $env:SEREN_SHIPWRIGHT_ROOT
    $savedLegacy = $env:SEREN_SETUP_SCRIPTS
    Push-Location $smokeDir
    try {
        $env:SEREN_STARWRIGHT_ROOT = $null
        $env:SEREN_SHIPWRIGHT_ROOT = $null
        $env:SEREN_SETUP_SCRIPTS   = $null
        # MATCH A SERVICE ROW, NOT THE STRING "seren-". The failure path prints
        #   no installers found under ~\.seren-starwright\<key>\_seren_scripts
        # which contains "seren-" itself, so testing for that substring passes
        # on the error message and calls a broken archive healthy.
        # A real row is:  brain      seren-memory    :7420   extras=[...]
        $dump = (& $PyExe @PyArgs $OutFull --dump 2>$null | Out-String)
        if ($LASTEXITCODE -ne 0 -or $dump -notmatch "(?m)^\s*[a-z]+\s+seren-[a-z-]+\s+:\d+") {
            Die @"
the built archive discovered no services when run outside a checkout.
  The bundled scripts or the generated .starwright-root marker are wrong -
  this .pyz would be dead on a bare Jetson. Not shipping it.
"@
        }
        Ok "smoke test passed (bundled scripts found with no checkout present)"
    }
    finally {
        Pop-Location
        $env:SEREN_STARWRIGHT_ROOT = $savedRoot
        $env:SEREN_SHIPWRIGHT_ROOT = $savedOldRoot
        $env:SEREN_SETUP_SCRIPTS   = $savedLegacy
        Remove-Item $smokeDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "Run it:  python $Out" -ForegroundColor Green
    Write-Host "Rip it and win." -ForegroundColor Green
}
finally {
    Remove-Item $Build -Recurse -Force -ErrorAction SilentlyContinue
}
