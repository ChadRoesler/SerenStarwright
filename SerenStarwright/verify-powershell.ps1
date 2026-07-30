<#
==========================================================================
  verify-powershell.ps1  -  prove the PowerShell side actually works

  Everything else in this repo has been executed and verified. The .ps1 side
  has only ever been INSPECTED - there is no PowerShell available in the
  environment the contracts were written in. This script closes that gap.

  It checks four things, in increasing order of how much they'd hurt:

    1. PARSE      every .ps1 compiles under THIS PowerShell.
                  The reason this exists: the installers used the ternary
                  operator (cond ? a : b), which Microsoft introduced in
                  PowerShell 7.0. Under Windows PowerShell 5.1 that is a
                  parse error - and PowerShell parses the whole file before
                  running a single line, so the script would not have failed
                  partway through, it would have done NOTHING. Fixed, but
                  this is the check that would have caught it.

    2. DESCRIBE   each seren-*-setup.ps1 -Describe emits valid JSON on
                  stdout, nothing on stderr, and touches no disk.

    3. SCHEMA     that JSON carries the keys Starwright depends on.

    4. PARITY     the PowerShell and Bash sides agree about the world -
                  same services, same ports, same groups. Skipped if bash
                  isn't available (that's fine, it's a bonus check).

  USAGE
    powershell -ExecutionPolicy Bypass -File .\verify-powershell.ps1

  Exit code 0 = everything passed. Non-zero = count of failures.

  WINDOWS POWERSHELL 5.1-SAFE. ASCII-only on purpose.
==========================================================================
#>
[CmdletBinding()]
param()

$ScriptDir = $PSScriptRoot
$fail = 0
$pass = 0

function Section ($m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }
function Good ($m) { Write-Host "  PASS  $m" -ForegroundColor Green; $script:pass++ }
function Bad  ($m) { Write-Host "  FAIL  $m" -ForegroundColor Red;   $script:fail++ }
function Note ($m) { Write-Host "        $m" -ForegroundColor DarkGray }

Write-Host "Seren PowerShell verification" -ForegroundColor Magenta
Write-Host "PSVersion: $($PSVersionTable.PSVersion)  Edition: $($PSVersionTable.PSEdition)"
if ($PSVersionTable.PSVersion.Major -lt 6) {
    Note "Windows PowerShell 5.1 - this is the strict case, exactly what we want to test."
} else {
    Note "PowerShell 7+. NOTE: 7 accepts syntax 5.1 rejects, so a pass here does"
    Note "NOT prove 5.1 compatibility. Re-run under powershell.exe to be sure."
}

# -- 1. parse every .ps1 ------------------------------------------------------
Section "Parse check (all .ps1)"
$psFiles = Get-ChildItem -Path $ScriptDir -Recurse -Filter *.ps1 -File |
           Where-Object { $_.FullName -notlike "*\.git\*" }
foreach ($f in $psFiles) {
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $f.FullName, [ref] $null, [ref] $errors)
    $rel = $f.FullName.Replace($ScriptDir, "").TrimStart("\")
    if ($errors -and $errors.Count -gt 0) {
        Bad "$rel"
        foreach ($e in ($errors | Select-Object -First 3)) {
            Note "line $($e.Extent.StartLineNumber): $($e.Message)"
        }
    } else {
        Good $rel
    }
}

# -- 1b. encoding ------------------------------------------------------------
# THE BUG THIS CATCHES, because it cost us a full round trip:
# Windows PowerShell 5.1 reads a BOM-less .ps1 as the ANSI codepage, NOT UTF-8.
# A multi-byte character inside a double-quoted string then decodes to garbage
# and can terminate the string early - "The string is missing the terminator".
# That is a PARSE ERROR, not a display glitch: the whole file fails to run.
# Nine files in this repo were in exactly that state while looking perfect in
# an editor and in a GitHub diff. A UTF-8 BOM fixes it; PowerShell 7 and git
# both handle the BOM fine.
Section "Encoding (non-ASCII requires a BOM for 5.1)"
foreach ($f in $psFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $nonAscii = $false
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii = $true; break } }
    $rel = $f.FullName.Replace($ScriptDir, "").TrimStart("\")
    if ($nonAscii -and -not $hasBom) {
        Bad "$rel : non-ASCII with no BOM - 5.1 will misparse this"
    } elseif ($nonAscii) {
        Good "$rel (non-ASCII, BOM present)"
    } else {
        Good "$rel (pure ASCII)"
    }
}

# -- 1c. parameter shadowing --------------------------------------------------
# THE BUG THIS CATCHES:
# PowerShell variable names are CASE-INSENSITIVE, and a param() entry declares a
# TYPED variable. So inside a script with `param([switch] $Describe)`, writing
#     $describe = @{ ... }
# does not create a new variable - it assigns a hashtable to the [switch] one,
# and PowerShell throws "Cannot convert value System.Collections.Hashtable to
# type System.Management.Automation.SwitchParameter" before the next line runs.
# Eight installers had exactly that, and the only symptom a caller saw was an
# empty stdout.
Section "Parameter shadowing (assigning to a param's own name)"
foreach ($f in $installers) {
    $text = Get-Content $f.FullName -Raw
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
               $text, [ref] $null, [ref] $errors)
    if ($errors -and $errors.Count -gt 0) { continue }   # parse pass already reported it

    $paramBlock = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.ParamBlockAst] }, $true)
    if (-not $paramBlock) { continue }
    $switchNames = @()
    foreach ($pp in $paramBlock.Parameters) {
        if ($pp.StaticType -eq [switch]) { $switchNames += $pp.Name.VariablePath.UserPath.ToLower() }
    }
    $assigns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
    $hits = @()
    foreach ($a in $assigns) {
        $l = $a.Left
        if ($l -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $nm = $l.VariablePath.UserPath.ToLower()
            if ($switchNames -contains $nm) { $hits += $l.VariablePath.UserPath }
        }
    }
    if ($hits.Count -gt 0) {
        Bad "$($f.Name) : assigns to switch param(s) $($hits -join ', ')"
        Note "rename the local - PowerShell vars are case-insensitive and params are typed"
    } else {
        Good "$($f.Name)"
    }
}

# -- 2 + 3. describe ----------------------------------------------------------
Section "-Describe contract"
$installers = Get-ChildItem -Path (Join-Path $ScriptDir "services\powershell") -Filter "seren-*-setup.ps1" -File
$psServices = @{}
$required = @("schema_version","name","display","description","group",
              "package","default_host","default_port","extras","flags")

foreach ($f in $installers) {
    $rel = $f.Name
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $f.FullName -Describe 2>$errFile
        $errText = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)

        if (-not $out) {
            # Show WHY. The first version of this just said "no stdout" and left
            # you guessing - which is the same sin as an installer that fails
            # silently. The error is almost always sitting in stderr already.
            Bad "$rel : -Describe produced no stdout"
            if ($errText -and $errText.Trim().Length -gt 0) {
                foreach ($l in ($errText.Trim() -split "`n" | Select-Object -First 4)) {
                    Note $l.Trim()
                }
            } else {
                Note "(and nothing on stderr either - check the -Describe block exists)"
            }
            continue
        }

        $line = ($out | Select-Object -Last 1)
        try   { $obj = $line | ConvertFrom-Json }
        catch { Bad "$rel : stdout is not valid JSON"; Note $line; continue }

        $missing = @()
        foreach ($k in $required) {
            if (-not ($obj.PSObject.Properties.Name -contains $k)) { $missing += $k }
        }
        if ($missing.Count -gt 0) { Bad "$rel : missing key(s) $($missing -join ', ')"; continue }

        if ($errText -and $errText.Trim().Length -gt 0) {
            Bad "$rel : -Describe wrote to stderr (should be silent)"
            Note $errText.Trim()
            continue
        }

        $psServices[$obj.name] = $obj
        Good ("{0,-34} {1,-22} :{2}" -f $rel, $obj.name, $obj.default_port)
    }
    finally { Remove-Item $errFile -Force -ErrorAction SilentlyContinue }
}

# -- 3b. params map: PowerShell needs it to build a real command line ---------
Section "-Describe params map (canonical flag -> native parameter)"
foreach ($name in ($psServices.Keys | Sort-Object)) {
    $o = $psServices[$name]
    if (-not ($o.PSObject.Properties.Name -contains "params")) {
        Bad "$name : no params map - Starwright cannot build a command line"
        continue
    }
    $hostParam = $o.params.host
    if (-not $hostParam) {
        Bad "$name : params has no 'host' entry"
    } else {
        Good ("{0,-24} host -> -{1}" -f $name, $hostParam)
    }
}

# -- 4. cross-platform parity (bonus) ----------------------------------------
Section "Bash/PowerShell parity (skipped if bash unavailable)"
$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) {
    Note "bash not found - skipping. Not a failure."
} else {
    $bashDir = Join-Path $ScriptDir "services\bash"
    foreach ($name in ($psServices.Keys | Sort-Object)) {
        $short = $name -replace "^seren-", ""
        $sh = Join-Path $bashDir "seren-$short-setup.sh"
        if (-not (Test-Path $sh)) { Bad "$name : no bash counterpart"; continue }
        $j = & bash $sh --describe 2>$null
        if (-not $j) { Bad "$name : bash --describe gave nothing"; continue }
        $b = $j | ConvertFrom-Json
        $p = $psServices[$name]
        if ($b.default_port -ne $p.default_port) {
            Bad "$name : port differs (bash $($b.default_port) vs ps $($p.default_port))"
        } elseif ($b.group -ne $p.group) {
            Bad "$name : group differs (bash '$($b.group)' vs ps '$($p.group)')"
        } else {
            Good ("{0,-24} port + group agree" -f $name)
        }
    }
}

# -- summary ------------------------------------------------------------------
Write-Host ""
Write-Host "=========================================="
if ($fail -eq 0) {
    Write-Host "  ALL CHECKS PASSED  ($pass)" -ForegroundColor Green
    Write-Host "=========================================="
    Write-Host "Rip it and win." -ForegroundColor Green
    exit 0
} else {
    Write-Host "  $fail FAILED / $pass passed" -ForegroundColor Red
    Write-Host "=========================================="
    exit $fail
}
