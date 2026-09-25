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
    # EVERY INSTALLER IN services/ IS A SERVICE, so every one of them binds
    # something and must say which parameter carries the host.
    #
    # A portless rule briefly lived here for ms-moe-maker, which is a CLI rather
    # than a service. It belongs in nodes/ instead - a node component is where a
    # per-platform CUDA torch gets staged, which is the thing it actually needs -
    # so the exemption was removed rather than left standing for a case that can
    # no longer occur. If a genuine portless SERVICE ever appears, this is where
    # the argument goes back in.
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
        # DERIVED FROM THE NAME IN --describe, not from the .ps1 filename, so
        # the two files have to agree with the name. ms-moe-maker is spelled
        # `seren-ms-moe-maker-setup.*` for exactly this reason.
        $sh = Join-Path $bashDir "seren-$short-setup.sh"
        if (-not (Test-Path $sh)) { Bad "$name : no bash counterpart"; continue }
        $j = & bash $sh --describe 2>$null
        if (-not $j) { Bad "$name : bash --describe gave nothing"; continue }
        $b = $j | ConvertFrom-Json
        $p = $psServices[$name]
        if ($b.default_port -ne $p.default_port) {
            Bad "$name : port differs (bash $($b.default_port) vs ps $($p.default_port))"
            continue
        }
        if ($b.group -ne $p.group) {
            Bad "$name : group differs (bash '$($b.group)' vs ps '$($p.group)')"
            continue
        }

        # -- requires ---------------------------------------------------------
        # CHECKED BECAUSE IT WAS SILENTLY ABSENT. Get-SerenDescribe had no
        # Requires parameter at all, so every PowerShell service reported no
        # dependencies. Starwright feeds `requires` into resolve_dependencies and
        # install_order, so Corpus Callosum on Windows installed a bridge to
        # nothing while the bash side got it right. Port and group agreeing told
        # us nothing about that, which is why this check now exists.
        $bReq = @($b.requires | Where-Object { $_ }) | Sort-Object
        $pReq = @($p.requires | Where-Object { $_ }) | Sort-Object
        if (($bReq -join ',') -ne ($pReq -join ',')) {
            Bad ("{0} : requires differs (bash [{1}] vs ps [{2}])" -f `
                 $name, ($bReq -join ' '), ($pReq -join ' '))
            continue
        }

        # -- flags ------------------------------------------------------------
        # Pinned rather than demanded equal. Some asymmetry is REAL and must not
        # be papered over, so the two kinds are separated:
        #
        #   ALLOWED  - a flag that only makes sense on one OS. `local-system` is
        #              the NSSM service logon; there is no such thing on Linux.
        #   KNOWN    - a genuine feature gap, printed on every run so it stays
        #              visible instead of decaying into folklore. Fix the gap and
        #              delete the line; it will then be enforced like anything else.
        #
        # Anything NOT in either list fails. That is the point: this pins today's
        # shape so tomorrow's drift is loud.
        $allowedPsOnly = @('local-system')
        $knownGaps = @{
            'seren-memory'      = @{ ps = @('logging-dir');       bash = @() }
        }
        $bFlags = @($b.flags | Where-Object { $_ })
        $pFlags = @($p.flags | Where-Object { $_ })
        $psOnly   = @($pFlags | Where-Object { $bFlags -notcontains $_ })
        $bashOnly = @($bFlags | Where-Object { $pFlags -notcontains $_ })

        $gap = $knownGaps[$name]
        $expectedPsOnly   = @($allowedPsOnly) + @(if ($gap) { $gap.ps })
        $expectedBashOnly = @(if ($gap) { $gap.bash })

        $unexpectedPs   = @($psOnly   | Where-Object { $expectedPsOnly   -notcontains $_ })
        $unexpectedBash = @($bashOnly | Where-Object { $expectedBashOnly -notcontains $_ })

        if ($unexpectedPs.Count -or $unexpectedBash.Count) {
            Bad ("{0} : unexpected flag drift - ps-only [{1}] bash-only [{2}]" -f `
                 $name, ($unexpectedPs -join ' '), ($unexpectedBash -join ' '))
            continue
        }

        # -- switches ---------------------------------------------------------
        # Which flags take no value. Same allowed asymmetry as the flags
        # (local-system is a PowerShell switch with no Linux counterpart).
        $bSw = @($b.switches | Where-Object { $_ })
        $pSw = @($p.switches | Where-Object { $_ })
        $swPsOnly   = @($pSw | Where-Object { $bSw -notcontains $_ -and $allowedPsOnly -notcontains $_ -and $expectedPsOnly -notcontains $_ })
        $swBashOnly = @($bSw | Where-Object { $pSw -notcontains $_ -and $expectedBashOnly -notcontains $_ })
        if ($swPsOnly.Count -or $swBashOnly.Count) {
            Bad ("{0} : switch drift - ps-only [{1}] bash-only [{2}]" -f `
                 $name, ($swPsOnly -join ' '), ($swBashOnly -join ' '))
            continue
        }
        if ($bSw -notcontains 'no-updates' -or $pSw -notcontains 'no-updates') {
            Bad ("{0} : --no-updates is not reported as a switch (bash [{1}] ps [{2}])" -f `
                 $name, ($bSw -join ' '), ($pSw -join ' '))
            continue
        }

        Good ("{0,-24} port, group, requires, flags, switches agree" -f $name)
        if ($gap) {
            $g = @()
            if ($gap.ps.Count)   { $g += "ps-only: $($gap.ps -join ' ')" }
            if ($gap.bash.Count) { $g += "bash-only: $($gap.bash -join ' ')" }
            Note ("known feature gap - {0}" -f ($g -join '; '))
        }
    }
}

# -- 5. the dev wheelhouse (-Local) -------------------------------------------
# Resolve-LocalWheel is the PowerShell half of --local. It never opens a wheel,
# so plain files with the right names stand in for wheels here; what is under
# test is the index reading, the newest-per-project pick, the pins, and the
# refusals. The bash half has the same fixture with a real pip behind it
# (services/tests/test-local-wheelhouse.sh).
Section "Dev wheelhouse (-Local)"
$house = Join-Path ([System.IO.Path]::GetTempPath()) ("seren_verify_house_" + [System.IO.Path]::GetRandomFileName().Replace('.', ''))
New-Item -ItemType Directory -Path $house -Force | Out-Null
try {
    $fake = @(
        "seren_meninges-2.4.0-py3-none-any.whl",
        "seren_meninges-2.4.1.dev3+gabc1234-py3-none-any.whl",
        "seren_memory-3.0.1.dev2+gdef5678-py3-none-any.whl",
        "seren_loci-2.2.0+d20260923-py3-none-any.whl"
    )
    $sums = @()
    foreach ($n in $fake) {
        [System.IO.File]::WriteAllText((Join-Path $house $n), "fake $n", (New-Object System.Text.UTF8Encoding $false))
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash([System.IO.File]::ReadAllBytes((Join-Path $house $n)))
        $sums += (([System.BitConverter]::ToString($bytes)).Replace("-", "").ToLower() + "  " + $n)
    }
    $sums += ("deadbeef" * 8) + "  old/seren_memory-9.9.9-py3-none-any.whl"
    [System.IO.File]::WriteAllText((Join-Path $house "SHA256SUMS"), (($sums -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))

    # The library's Die exits the process; here it has to throw instead.
    . (Join-Path $ScriptDir "services\lib\seren-install-lib.ps1")
    function Die($m) { throw $m }
    function Step($m) { }
    function Ok($m) { }

    $r = Resolve-LocalWheel -House $house -Package "seren-memory"
    if ((Split-Path $r.Src -Leaf) -eq "seren_memory-3.0.1.dev2+gdef5678-py3-none-any.whl") { Good "newest seren_memory wheel picked" }
    else { Bad "picked $($r.Src)" }
    $pins = @()
    if ($global:serenPipArgs.Count -eq 4 -and $global:serenPipArgs[0] -eq "--find-links") {
        Good "pip gets --find-links + a constraints file"
        $pins = @(Get-Content $global:serenPipArgs[3])
    } else { Bad "pip args: $($global:serenPipArgs -join ' ')" }
    if ($pins -contains "seren-meninges==2.4.1.dev3+gabc1234" -and $pins -notcontains "seren-meninges==2.4.0") { Good "the dev meninges is pinned, not the release beside it" }
    else { Bad "pins: $($pins -join ' ')" }
    if ($pins -contains "seren-loci==2.2.0+d20260923") { Good "every seren wheel in the house is pinned" } else { Bad "loci not pinned" }
    if (-not ($pins -join ' ').Contains("9.9.9")) { Good "the old/ subdirectory entry is ignored" } else { Bad "subdirectory entry leaked" }

    $r2 = Resolve-LocalWheel -House ("file://" + $house) -Package "seren-loci"
    if ((Split-Path $r2.Src -Leaf) -like "seren_loci-*") { Good "file:// house behaves like a folder" } else { Bad "file:// pick: $($r2.Src)" }

    [System.IO.File]::WriteAllText((Join-Path $house "seren_loci-2.2.0+d20260923-py3-none-any.whl"), "tampered", (New-Object System.Text.UTF8Encoding $false))
    $refused = $false
    try { Resolve-LocalWheel -House $house -Package "seren-loci" | Out-Null } catch { $refused = ("$_" -like "*failed verification*") }
    if ($refused) { Good "a wheel that does not match the index is refused" } else { Bad "tampered wheel accepted" }

    $refused = $false
    try { Resolve-LocalWheel -House $house -Package "seren-probe" | Out-Null } catch { $refused = ("$_" -like "*no seren_probe-*") }
    if ($refused) { Good "a house without this card's wheel says so" } else { Bad "missing package not refused" }

    Remove-Item -Force (Join-Path $house "SHA256SUMS")
    $refused = $false
    try { Resolve-LocalWheel -House $house -Package "seren-memory" | Out-Null } catch { $refused = ("$_" -like "*seren-dev-publish.ps1*") }
    if ($refused) { Good "a house with no index is refused, naming the publisher" } else { Bad "indexless house accepted" }

    $wr = Resolve-Wheel -Wheel (Join-Path $house "seren_memory-3.0.1.dev2+gdef5678-py3-none-any.whl") -Local $house -Package "seren-memory"
    if ($global:serenPipArgs.Count -eq 0) { Good "-Wheel still beats -Local, and carries no house args" } else { Bad "-Wheel with -Local left pip args behind" }
} catch {
    Bad "wheelhouse section threw: $_"
} finally {
    Remove-Item -Recurse -Force $house -ErrorAction SilentlyContinue
}

# -- 6. the install ledger (Write-SerenInstallRecord) -------------------------
Section "Install ledger (Write-SerenInstallRecord)"
$ledgerTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sw-ledger-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $ledgerTmp | Out-Null
$env:SEREN_INSTALLED_DIR = $ledgerTmp
try {
    . (Join-Path $ScriptDir "services\lib\seren-install-lib.ps1")
    $global:Instance = "wren"
    $Wheel = "C:\wheels\seren_memory-3.1.0-py3-none-any.whl"
    Write-SerenInstallRecord -Service "seren-memory" -ConnectHost "127.0.0.1" -Port 7267 -Autostart $false `
        -Token "s3cret-do-not-write-me" -Mcp $true -Venv "C:\nope\venv" -Config "C:\nope\seren-memory\seren-memory.yaml"
    $recPath = Join-Path $ledgerTmp "seren-memory@wren.json"
    if (Test-Path $recPath) { Good "record written as <service>@<instance>.json" } else { Bad "no record at $recPath" }
    $raw = Get-Content $recPath -Raw
    $rec = $raw | ConvertFrom-Json
    if ($rec.service -eq "seren-memory" -and $rec.instance -eq "wren" -and $rec.port -eq 7267) { Good "service / instance / port recorded" } else { Bad "fields wrong: $raw" }
    if ($rec.url -eq "http://127.0.0.1:7267" -and $rec.app_dir -eq "C:\nope\seren-memory") { Good "url and app_dir derived" } else { Bad "url/app_dir wrong: $($rec.url) $($rec.app_dir)" }
    if ($rec.source -eq "wheel" -and $rec.source_ref -like "*seren_memory-3.1.0*") { Good "source is the wheel" } else { Bad "source wrong: $($rec.source) $($rec.source_ref)" }
    if ($rec.has_token -eq $true -and $raw -notmatch "s3cret") { Good "has_token true, token itself never written" } else { Bad "token leaked or has_token wrong" }
    if ($rec.extras.mcp -eq $true -and $rec.derived -eq $false) { Good "extras and derived flag" } else { Bad "extras/derived wrong" }
} catch {
    Bad "Write-SerenInstallRecord threw: $($_.Exception.Message)"
} finally {
    Remove-Item Env:SEREN_INSTALLED_DIR -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $ledgerTmp -ErrorAction SilentlyContinue
    Remove-Variable -Name Instance -Scope Global -ErrorAction SilentlyContinue
}

# -- 7. a card reads a sibling's config (Read-SerenSiblingConfig) -------------
Section "Sibling config (Read-SerenSiblingConfig)"
$sibTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sw-sib-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $sibTmp | Out-Null
try {
    . (Join-Path $ScriptDir "services\lib\seren-install-lib.ps1")
    $memYaml = Join-Path $sibTmp "memory.yaml"
    [System.IO.File]::WriteAllText($memYaml, "server:`n  host: 0.0.0.0   # LAN`n  port: 7267`n  bearer_token: `"s3cret-inline`"   # the token`nstorage:`n  x: 1`n")
    $sib = Read-SerenSiblingConfig -Path $memYaml
    if ($sib.Url -eq "http://127.0.0.1:7267") { Good "url from host/port (0.0.0.0 -> 127.0.0.1)" } else { Bad "url wrong: $($sib.Url)" }
    if ($sib.Token -eq "s3cret-inline") { Good "inline token, quotes and comment stripped" } else { Bad "token wrong: $($sib.Token)" }
    $lines = Get-SerenSiblingTokenLines -Sib $sib -Indent "      "
    if ($lines -eq "      bearer_token: `"s3cret-inline`"`n") { Good "token line indented as asked" } else { Bad "token line wrong: [$lines]" }
    $lociYaml = Join-Path $sibTmp "loci.yaml"
    [System.IO.File]::WriteAllText($lociYaml, "server:`n  host: '127.0.0.1'`n  port: '7266'`n  bearer_token_env: SEREN_LOCI_TOKEN`n")
    $sib2 = Read-SerenSiblingConfig -Path $lociYaml
    if ($sib2.Url -eq "http://127.0.0.1:7266" -and $sib2.TokenEnv -eq "SEREN_LOCI_TOKEN" -and -not $sib2.Token) { Good "quoted values and an env pointer" } else { Bad "env pointer wrong: $($sib2.Url) $($sib2.TokenEnv)" }
    $hipYaml = Join-Path $sibTmp "hippo.yaml"
    [System.IO.File]::WriteAllText($hipYaml, "server:`n  host: 127.0.0.1`n  port: 7269`nmemory:`n  url: http://127.0.0.1:7267`n  bearer_token: `"memorys-token-not-mine`"`n")
    $sibH = Read-SerenSiblingConfig -Path $hipYaml
    if ($sibH.Url -eq "http://127.0.0.1:7269" -and -not $sibH.Token) { Good "only the server block counts (Memory's bearer is not its own)" } else { Bad "server scoping wrong: $($sibH.Url) [$($sibH.Token)]" }
    $reused = Get-SerenReusedToken -Path $memYaml
    if ($reused -eq "s3cret-inline") { Good "a reinstall keeps the existing bearer" } else { Bad "reuse wrong: [$reused]" }
    $none = Get-SerenReusedToken -Path $hipYaml
    if (-not $none) { Good "no server token: nothing reused" } else { Bad "reused a token that is not the server's: [$none]" }
    $fresh = Get-SerenReusedToken -Path (Join-Path $sibTmp "nope.yaml")
    if (-not $fresh) { Good "fresh install: nothing reused" } else { Bad "fresh install reused [$fresh]" }
    $sib3 = Read-SerenSiblingConfig -Path (Join-Path $sibTmp "nope.yaml") 3>$null
    if (-not $sib3.Url -and -not $sib3.Token) { Good "missing file: nothing set" } else { Bad "missing file set something" }
} catch {
    Bad "Read-SerenSiblingConfig threw: $($_.Exception.Message)"
} finally {
    Remove-Item -Recurse -Force $sibTmp -ErrorAction SilentlyContinue
}

# -- 8. a reinstall keeps what the card does not write (Write-Launcher) ------
Section "Keep the previous config (Write-Launcher -> seren-keep-config.py)"
$keepTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sw-keep-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $keepTmp | Out-Null
try {
    . (Join-Path $ScriptDir "services\lib\seren-install-lib.ps1")
    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $py) { Note "no python on PATH - skipped" } else {
        $cfg = Join-Path $keepTmp "seren-hippocampus.yaml"
        [System.IO.File]::WriteAllText("$cfg.bak.1", "server:`n  port: 7269`nmodel:`n  url: x`n  lifecycle:`n    manage: true`n")
        [System.IO.File]::WriteAllText($cfg, "server:`n  port: 7270`nmodel:`n  url: y`n")
        $null = Write-Launcher -AppDir $keepTmp -ServiceName "seren-hippocampus" -Vpy $py -Module "seren_hippocampus" -CfgPath $cfg
        $t = [System.IO.File]::ReadAllText($cfg)
        if ($t -match "lifecycle:" -and $t -match "manage: true") { Good "the lifecycle block is carried forward" } else { Bad "lifecycle not kept: $t" }
        if ($t -match "port: 7270" -and $t -notmatch "port: 7269") { Good "what the card wrote wins" } else { Bad "card values lost: $t" }
    }
} catch {
    Bad "Write-Launcher keep threw: $($_.Exception.Message)"
} finally {
    Remove-Item -Recurse -Force $keepTmp -ErrorAction SilentlyContinue
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
