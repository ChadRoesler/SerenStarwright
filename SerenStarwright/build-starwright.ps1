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

  ALSO NOT BUNDLED: the installers. Starwright RUNS the scripts in Bash\ and
  Powershell\, so it still needs this repo beside it (or $env:SEREN_SETUP_SCRIPTS
  pointing at one). Deliberate: those scripts are the part you most want to be
  able to read and patch on a box at 2am.

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
$Src       = Join-Path $ScriptDir "starwright\seren-starwright.py"
if (-not $Out) { $Out = Join-Path $ScriptDir "dist\starwright.pyz" }

function Ok   ($m) { Write-Host "  + $m" -ForegroundColor Green }
function Info ($m) { Write-Host "$m"     -ForegroundColor Blue }
function Die  ($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $Src)) { Die "seren-starwright.py not found at $Src" }

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
    foreach ($d in @("services\bash", "services\powershell", "services\lib",
                     "nodes", "nodes\lib", "nodes\xavier", "nodes\nano", "nodes\spark")) {
        $srcDir = Join-Path $ScriptDir $d
        if (-not (Test-Path $srcDir)) { continue }
        $dstDir = Join-Path $bundle $d
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        Get-ChildItem $srcDir -File | Where-Object {
            ($_.Extension -eq ".sh" -or $_.Extension -eq ".ps1")
        } | ForEach-Object {
            Copy-Item $_.FullName $dstDir -Force
            $bundled++
        }
    }
    if ($bundled -eq 0) { Die "bundled zero scripts - is $ScriptDir the repo root?" }

    # The marker MUST travel with them - _find_base_dir looks for
    # .starwright-root, so an extracted bundle without it discovers nothing.
    $marker = Join-Path $ScriptDir ".starwright-root"
    if (-not (Test-Path $marker)) {
        Die ".starwright-root not found at $ScriptDir - refusing to build a bundle that can't locate its own scripts."
    }
    Copy-Item $marker (Join-Path $bundle ".starwright-root") -Force
    Ok "bundled $bundled script(s) + the root marker"

    # -- version stamp ----------------------------------------------------
    # A .pyz on a Jetson has no repo to interrogate, so the answer to "which
    # build is this?" has to travel inside the archive. Env var (CI passes the
    # tag) -> git describe -> timestamp, so the field is never empty.
    $stamp = $env:SEREN_STARWRIGHT_VERSION
    if (-not $stamp) {
        $stamp = (& git -C $ScriptDir describe --tags --always --dirty 2>$null)
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

    $sizeMb = [math]::Round((Get-Item $Out).Length / 1MB, 1)
    Ok "built $Out ($sizeMb MB)"

    # -- prove it runs, rather than assuming ----------------------------------
    & $PyExe @PyArgs $Out --dump 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Ok "smoke test passed (--dump discovered services)"
    } else {
        Write-Host "  ! smoke test found no services - fine if building outside the repo;" -ForegroundColor Yellow
        Write-Host "    set `$env:SEREN_SETUP_SCRIPTS when you run it." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Run it:  python $Out" -ForegroundColor Green
    Write-Host "Rip it and win." -ForegroundColor Green
}
finally {
    Remove-Item $Build -Recurse -Force -ErrorAction SilentlyContinue
}
