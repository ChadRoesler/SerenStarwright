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
              "package","default_host","default_port","extras","flags",
              "requires","recommends")

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
        # -- recommends -------------------------------------------------------
        # Wired when present, never pulled (the callosum's Memory and Loci).
        # Drift here would make Windows pull what Linux only warns about, or
        # the other way round.
        $bRec = @($b.recommends | Where-Object { $_ }) | Sort-Object
        $pRec = @($p.recommends | Where-Object { $_ }) | Sort-Object
        if (($bRec -join ',') -ne ($pRec -join ',')) {
            Bad ("{0} : recommends differs (bash [{1}] vs ps [{2}])" -f `
                 $name, ($bRec -join ' '), ($pRec -join ' '))
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

        Good ("{0,-24} port, group, requires, recommends, flags, switches agree" -f $name)
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
        -Token "s3cret-do-not-write-me" -Mcp $true -St $true -Venv "C:\nope\venv" -Config "C:\nope\seren-memory\seren-memory.yaml"
    $recPath = Join-Path $ledgerTmp "seren-memory@wren.json"
    if (Test-Path $recPath) { Good "record written as <service>@<instance>.json" } else { Bad "no record at $recPath" }
    $raw = Get-Content $recPath -Raw
    $rec = $raw | ConvertFrom-Json
    if ($rec.service -eq "seren-memory" -and $rec.instance -eq "wren" -and $rec.port -eq 7267) { Good "service / instance / port recorded" } else { Bad "fields wrong: $raw" }
    if ($rec.url -eq "http://127.0.0.1:7267" -and $rec.app_dir -eq "C:\nope\seren-memory") { Good "url and app_dir derived" } else { Bad "url/app_dir wrong: $($rec.url) $($rec.app_dir)" }
    if ($rec.source -eq "wheel" -and $rec.source_ref -like "*seren_memory-3.1.0*") { Good "source is the wheel" } else { Bad "source wrong: $($rec.source) $($rec.source_ref)" }
    if ($rec.has_token -eq $true -and $raw -notmatch "s3cret") { Good "has_token true, token itself never written" } else { Bad "token leaked or has_token wrong" }
    if ($rec.extras.mcp -eq $true -and $rec.derived -eq $false) { Good "extras and derived flag" } else { Bad "extras/derived wrong" }
    # Memory's -St (torch) was recorded as false whatever was ticked, so a reinstall unticked it (28 Sept 2026).
    if ($rec.extras.st -eq $true -and $rec.extras.vector -eq $false) { Good "the st extra is recorded as ticked" } else { Bad "st extra lost: $($rec.extras | ConvertTo-Json -Compress)" }
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

# -- -Root: one folder per named install (26 Sept 2026) --------------------------
# Two clusters on one host must not share a Lodestar, an Observatory, Probe's
# results or Theatre's archive. And the wren set's configs said ~/.seren-...,
# the services ran as LocalSystem, and all of Wren's memory lived in the
# Windows system profile. Under a root every path is absolute.
Section "-Root: a named install in one folder"
$rootTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sw-root-" + [guid]::NewGuid().ToString("N"))
try {
    . (Join-Path $ScriptDir "services\lib\seren-install-lib.ps1")
    $l = Get-SerenLayout -Root (Join-Path $rootTmp "wren") -Short "memory" -Instance "wren" -VenvDir "x" -AppDir "y"
    $r = Join-Path $rootTmp "wren"
    if ($l.Venv -eq "$r\venvs\memory" -and $l.App -eq "$r\apps\memory" -and $l.Data -eq "$r\stores\memory" -and $l.Logs -eq "$r\logs") {
        Good "venvs, apps, stores, logs under the root" } else { Bad "layout: $($l | Out-String)" }
    if ($l.Suffix -eq "-wren" -and $global:SerenSvcSuffix -eq "-wren") { Good "the service name suffix is -wren (SerenMemory-wren)" } else { Bad "suffix: $($l.Suffix)" }
    $d = Get-SerenLayout -Root (Join-Path $rootTmp "default") -Short "loci" -Instance "" -VenvDir "x" -AppDir "y"
    if ($d.Suffix -eq "") { Good "the default install keeps the plain service name" } else { Bad "default suffix: $($d.Suffix)" }
    $h = Get-SerenLayout -Root "~\seren-verify-tilde" -Short "loci" -Instance "" -VenvDir "x" -AppDir "y"
    if ($h.Root -eq (Join-Path $env:USERPROFILE "seren-verify-tilde")) { Good "~ is this user's profile, made absolute" } else { Bad "tilde: $($h.Root)" }
    Remove-Item -Recurse -Force (Join-Path $env:USERPROFILE "seren-verify-tilde") -ErrorAction SilentlyContinue
    $o = Get-SerenLayout -Root "" -Short "memory" -Instance "Test" -VenvDir "C:\v\memory" -AppDir "C:\a\seren-memory"
    if ($o.Venv -eq "C:\v\memoryTest" -and $o.App -eq "C:\a\seren-memoryTest" -and -not $o.Data -and $o.Suffix -eq "Test") {
        Good "no root: the old layout and the old suffix" } else { Bad "legacy layout: $($o | Out-String)" }

    foreach ($f in Get-ChildItem (Join-Path $ScriptDir "services\powershell\seren-*-setup.ps1")) {
        $src = [System.IO.File]::ReadAllText($f.FullName)
        $card = $f.BaseName -replace "-setup$", ""
        if ($src -match '\[string\]\s+\$Root\s+=' -and $src -match 'Get-SerenLayout -Root \$Root') { Good "$($card): -Root and Get-SerenLayout" }
        else { Bad "$($card): no -Root / layout" }
        $m = [regex]::Match($src, '(?m)^\$storePath = if \(\$layout\.Data\) \{ "(?<root>[^"]*)" \} else \{ "(?<bare>[^"]*)" \}')
        if ($m.Success) {
            if ($m.Groups["root"].Value -like "'`$(`$layout.Data)\*'") { Good "$($card): store path absolute and quoted under a root" } else { Bad "$($card): rooted store path $($m.Groups['root'].Value)" }
            if ($m.Groups["bare"].Value -like "~/*") { Good "$($card): the old ~ path without one" } else { Bad "$($card): legacy store path $($m.Groups['bare'].Value)" }
            $at = $src.IndexOf('$storePath = if')
            $db = $src.IndexOf('$dbInstance = $Instance')
            if ($db -lt 0 -or $db -lt $at) { Good "$($card): the store path sees the instance" } else { Bad "$($card): storePath built before `$dbInstance is set" }
        }
    }

    # autostart: the suffixed instance, the app dir, the root's logs
    $fake = Join-Path $rootTmp "cards"; New-Item -ItemType Directory -Force -Path $fake | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $fake "setup-memory-service.ps1"),
        'param([string]$Instance,[string]$AppDir,[string]$VenvDir,[string]$LogDir,[string]$ServiceUser,[switch]$RunAsLocalSystem) "WRAPPER|$Instance|$AppDir|$LogDir"')
    $null = Get-SerenLayout -Root (Join-Path $rootTmp "wren") -Short "memory" -Instance "wren" -VenvDir "x" -AppDir "y"
    $said = Setup-Autostart -ScriptDir $fake -ServiceName "seren-memory" -AppDir "$r\apps\memory" -Token "" -VenvDir "$r\venvs\memory" 6>$null
    $said = ($said | Where-Object { "$_" -like "WRAPPER*" }) -join ""
    if ($said -eq "WRAPPER|-wren|$r\apps\memory|$r\logs") { Good "the wrapper gets -Instance -wren, the app dir and the root's logs" }
    else { Bad "wrapper call: $said" }
} catch {
    Bad "-Root checks threw: $($_.Exception.Message)"
} finally {
    Remove-Item -Recurse -Force $rootTmp -ErrorAction SilentlyContinue
    $global:SerenRoot = $null; $global:SerenSvcSuffix = $null; $global:SerenLogDir = $null
}

# -- the hippocampus card: bedtime and the draft cap (26 Sept 2026) ---------------
# They existed in the config and no card wrote them. A bad value must be
# refused with its reason before anything is installed.
Section "hippocampus card: bedtime and the draft cap"
$card = Join-Path $ScriptDir "services\powershell\seren-hippocampus-setup.ps1"
$d = & $card -Describe | ConvertFrom-Json
foreach ($f in "sleep-at", "sleep-every", "max-attempts") {
    if ($d.flags -contains $f) { Good "-Describe advertises $f" } else { Bad "-Describe is missing $f" }
}
foreach ($case in @(@{a = @("-SleepAt", "25:00"); w = "HH:MM"}, @{a = @("-SleepEvery", "0.05"); w = "ten minutes"},
                    @{a = @("-MaxAttempts", "11"); w = "1-10"})) {
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $card) + $case.a
    # the engine running this check, so 5.1 is tested by 5.1 and 7 by 7
    # Continue, not Stop, for this one call: GitHub's `shell: powershell` runs with
    # $ErrorActionPreference = stop, and under Windows PowerShell 5.1 a native
    # command's stderr through 2>&1 becomes error records - a card that refuses
    # with a ValidateSet message (stderr, not Die's stdout) aborted the whole run.
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $out = & (Get-Process -Id $PID).Path @argList 2>&1 | Out-String } finally { $ErrorActionPreference = $prevEap }
    if ($LASTEXITCODE -ne 0 -and $out -match [regex]::Escape($case.w)) { Good "$($case.a -join ' ') is refused ($($case.w))" }
    else { Bad "$($case.a -join ' ') was not refused: $out" }
}
$src = [System.IO.File]::ReadAllText($card)
if ($src -match "# at: ""03:30""" -and $src -match "# max_attempts: 3" -and $src -match "# interval_seconds: 72000") {
    Good "the sleep block shows all three, commented with their defaults when not given" } else { Bad "sleep block defaults missing" }

# The model lifecycle and the ripple (28 Sept 2026): the server + .gguf that the
# hippocampus starts itself, and the bedtime question, offered as a dropdown.
foreach ($f in "model-server", "model-path", "model-args", "model-max-tokens", "ripple", "ripple-command", "ripple-url") {
    if ($d.flags -contains $f) { Good "-Describe advertises $f" } else { Bad "-Describe is missing $f" }
}
if ((@($d.choices.ripple) -join ",") -eq "script,endpoint,off") { Good "-Describe offers -Ripple as a choice (from its ValidateSet)" }
else { Bad "ripple choices wrong: $($d.choices | ConvertTo-Json -Compress)" }
# The tend cycle (30 Sept 2026): a redraft starts the small model, so on a box
# where it shares memory with the main model it must not run on a timer.
if ((@($d.choices.'tend-cycle') -join ",") -eq "on,off") { Good "-Describe offers -TendCycle as a choice: on | off" }
else { Bad "tend-cycle choices wrong: $($d.choices | ConvertTo-Json -Compress)" }
if ($d.flags -contains "tend-every") { Good "-Describe advertises tend-every" } else { Bad "-Describe is missing tend-every" }
foreach ($case in @(@{a = @("-TendEvery", "5"); w = "60 or more"}, @{a = @("-TendCycle", "off", "-TendEvery", "600"); w = "there is no timer"},
                    @{a = @("-TendCycle", "maybe"); w = "on"})) {
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $card) + $case.a
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $out = & (Get-Process -Id $PID).Path @argList 2>&1 | Out-String } finally { $ErrorActionPreference = $prevEap }
    if ($LASTEXITCODE -ne 0 -and $out -match [regex]::Escape($case.w)) { Good "$($case.a -join ' ') is refused ($($case.w))" }
    else { Bad "$($case.a -join ' ') was not refused: $out" }
}
if ($src -match [regex]::Escape("tend_cycle: `$(if (`$TendCycle -eq 'off') { 'false' } else { 'true' })") -and
    $src -match [regex]::Escape('tend_interval_seconds: $TendEvery')) { Good "-TendCycle / -TendEvery write tend_cycle and tend_interval_seconds" }
else { Bad "the tend flags are not written into the sleep block" }
# The voice card (29 Sept 2026): opt in, a checkbox; the model writes the card.
if ($d.switches -contains "voice-card") { Good "-VoiceCard is a switch (opt in)" } else { Bad "-VoiceCard missing or not a switch" }
if ($src -match [regex]::Escape('if ($VoiceCard) {') -and $src -match 'enabled: true') { Good "-VoiceCard writes voice.enabled true" }
else { Bad "-VoiceCard does not write the voice block" }
foreach ($case in @(@{a = @("-Ripple", "carrier-pigeon"); w = "script"}, @{a = @("-Ripple", "endpoint"); w = "needs -RippleUrl"},
                    @{a = @("-ModelServer", "C:\llama\llama-server.exe"); w = "go together"},
                    @{a = @("-ModelMaxTokens", "12"); w = "256 or more"})) {
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $card) + $case.a
    # Continue, not Stop, for this one call: GitHub's `shell: powershell` runs with
    # $ErrorActionPreference = stop, and under Windows PowerShell 5.1 a native
    # command's stderr through 2>&1 becomes error records - a card that refuses
    # with a ValidateSet message (stderr, not Die's stdout) aborted the whole run.
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $out = & (Get-Process -Id $PID).Path @argList 2>&1 | Out-String } finally { $ErrorActionPreference = $prevEap }
    if ($LASTEXITCODE -ne 0 -and $out -match [regex]::Escape($case.w)) { Good "$($case.a -join ' ') is refused ($($case.w))" }
    else { Bad "$($case.a -join ' ') was not refused: $out" }
}
$qdef = [regex]::Match($src, "function ConvertTo-SerenYamlQuoted[^\r\n]*").Value
if ($qdef) {
    Invoke-Expression $qdef
    $q = ConvertTo-SerenYamlQuoted "C:\models\it's-q5.gguf"
    if ($q -eq "'C:\models\it''s-q5.gguf'") { Good "a Windows path with a quote is written as valid single-quoted YAML" }
    else { Bad "yaml quoting wrong: $q" }
} else { Bad "ConvertTo-SerenYamlQuoted not found in the card" }

# -- the install record carries the card's options (30 Sept 2026) --------------
# Every flag the card was invoked with, minus secrets, so a reinstall starts
# from them (Chad's smoke: a ripple, a bookmark hook and a voice card all
# opened blank on reinstall). Written through the real lib into a scratch ledger.
Section "install record: options, minus secrets"
& {
    . (Join-Path $ScriptDir "services\lib\seren-install-lib.ps1")
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sw-opt-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $prev = $env:SEREN_INSTALLED_DIR; $env:SEREN_INSTALLED_DIR = $tmp
    try {
        $bound = @{ Port = 7421; ClaudeBookmark = [switch]$true; VoiceCard = [switch]$true; Token = "s3cret-no"; RippleToken = "s3cret-no2"
                    ServicePassword = "pw-no"; Json = [switch]$true; Instance = "wren"; RippleRunAs = "Caesar"; KeepWarm = 600; MarginHost = "127.0.0.1" }
        Write-SerenInstallRecord -Service "seren-margin" -ConnectHost "127.0.0.1" -Port 7421 -Autostart $true -Token "s3cret-no" -Bound $bound *> $null
        $raw = Get-Content (Join-Path $tmp "seren-margin.json") -Raw
        $o = ($raw | ConvertFrom-Json).options
        if ($o.'claude-bookmark' -eq $true -and $o.'voice-card' -eq $true) { Good "a switch records true" } else { Bad "switches: $($o | ConvertTo-Json -Compress)" }
        if ($o.'ripple-run-as' -eq "Caesar" -and $o.'keep-warm' -eq "600" -and $o.host -eq "127.0.0.1" -and $o.port -eq "7421") { Good "value flags record their values, under canonical names (MarginHost -> host)" }
        else { Bad "values: $($o | ConvertTo-Json -Compress)" }
        if (-not ($raw -match "s3cret|pw-no") -and $null -eq $o.token -and $null -eq $o.'ripple-token' -and $null -eq $o.json) { Good "no token, no password, no plumbing in the record" }
        else { Bad "secret or plumbing leaked: $raw" }
    } catch { Bad "options record failed: $_" }
    finally { $env:SEREN_INSTALLED_DIR = $prev; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
$hipD = & (Join-Path $ScriptDir "services\powershell\seren-hippocampus-setup.ps1") -Describe | ConvertFrom-Json
if ($hipD.flags -contains "keep-warm") { Good "hippocampus -Describe advertises keep-warm" } else { Bad "keep-warm missing" }
$svcCore = [System.IO.File]::ReadAllText((Join-Path $ScriptDir "services\lib\setup-seren-service.ps1"))
if ($svcCore -notmatch 'LogDir\s*=\s*"\$env:USERPROFILE\seren-logs"') { Good "the service core no longer defaults logs to ~\seren-logs" } else { Bad "logs still default to ~\seren-logs" }

# A failed service step is said (30 Sept 2026): five cards reported success while
# the core had refused to change the account. And a service that already runs
# as the account asked for needs no password.
$libSrc = [System.IO.File]::ReadAllText((Join-Path $ScriptDir "services\lib\seren-install-lib.ps1"))
if ($libSrc -match "THE SERVICE STEP FAILED" -and $libSrc -match [regex]::Escape('if ($LASTEXITCODE -ne 0) {')) { Good "Setup-Autostart reports a failed service step" }
else { Bad "Setup-Autostart does not check the service step" }
$coreSrc = [System.IO.File]::ReadAllText((Join-Path $ScriptDir "services\lib\setup-seren-service.ps1"))
if ($coreSrc -match "its logon is left as it is" -and $coreSrc -match [regex]::Escape('if (-not $plain -and $already)')) { Good "the service core leaves a logon that is already the account asked for" }
else { Bad "the service core still needs a password for an unchanged account" }
$bareLine = ($coreSrc -split "`n" | Where-Object { $_ -match '^\s*\$bare = ' } | Select-Object -First 1)
if ($bareLine) {
    Invoke-Expression $bareLine.Trim()
    if (((& $bare ".\caesar") -ieq (& $bare "Caesar")) -and ((& $bare "$env:COMPUTERNAME\Caesar") -ieq "caesar") -and -not ((& $bare "LocalSystem") -ieq "caesar")) { Good "the account comparison treats .\user, BOX\user and user as one" }
    else { Bad "the account comparison is wrong: $bareLine" }
} else { Bad "no account comparison in the service core" }

# The record says what Windows says, and a backup carries its own time (30 Sept
# 2026, the second dev install): five records said service_user 'Caesar' while
# the services ran as LocalSystem, and a hand-set max_tokens was dropped because
# Copy-Item keeps the config's modified time and keep-config read the backup's
# age from it.
Section "install record: the account Windows says; backups: their own time"
& {
    . (Join-Path $ScriptDir "services\lib\seren-install-lib.ps1")
    $global:Instance = "wren"; $global:SerenSvcSuffix = "-wren"
    if ((Get-SerenServiceName "seren-corpus-callosum") -eq "SerenCorpusCallosum-wren") { Good "the service name is the wrappers' (SerenCorpusCallosum-wren)" }
    else { Bad "service name wrong: $(Get-SerenServiceName 'seren-corpus-callosum')" }
    if ((Test-SerenSameAccount ".\caesar" "Caesar") -and (Test-SerenSameAccount "$env:COMPUTERNAME\Caesar" "caesar") -and -not (Test-SerenSameAccount "LocalSystem" "Caesar")) { Good "accounts compare by who they are, not how they are spelled" }
    else { Bad "Test-SerenSameAccount is wrong" }
    if ((Get-SerenServiceAccount "seren-no-such-service-here") -eq "") { Good "no such service: no account, no error" } else { Bad "a missing service returned an account" }
    Remove-Variable -Name Instance, SerenSvcSuffix -Scope Global -ErrorAction SilentlyContinue
}
if ($libSrc -match "ASKED TO RUN AS" -and $libSrc -match [regex]::Escape('service_user   = $recUser')) { Good "the record takes the account from Windows and says when it is not what was asked" }
else { Bad "the record still writes the account that was asked for" }
if ($coreSrc -match [regex]::Escape('if ($account -notmatch ''[\\@]'') { $account = ".\$account" }')) { Good "a bare account name gets its .\ prefix" }
else { Bad "a bare account name is passed to nssm as it is" }
$unstamped = @(Get-ChildItem (Join-Path $ScriptDir "services\powershell\seren-*-setup.ps1") | Where-Object {
    $t = [System.IO.File]::ReadAllText($_.FullName)
    ($t -match 'Copy-Item \$CfgPath \$bak') -and -not ($t -match [regex]::Escape('(Get-Item $bak).LastWriteTime = Get-Date')) })
if ($unstamped.Count -eq 0) { Good "every card stamps its config backup with the time it was made" }
else { Bad "backups keep the config's modified time in: $($unstamped.Name -join ', ')" }
$tmpB = Join-Path ([System.IO.Path]::GetTempPath()) ("sw-bak-" + [Guid]::NewGuid().ToString("N") + ".yaml")
"a: 1" | Set-Content $tmpB; (Get-Item $tmpB).LastWriteTime = (Get-Date).AddHours(-3)
$CfgPath = $tmpB; $bak = "$CfgPath.bak.test"
Copy-Item $CfgPath $bak; (Get-Item $bak).LastWriteTime = Get-Date
if (((Get-Date) - (Get-Item $bak).LastWriteTime).TotalSeconds -lt 60) { Good "a backup of a config last edited three hours ago is seconds old" } else { Bad "the backup kept the config's age" }
Remove-Item $tmpB, $bak -Force -ErrorAction SilentlyContinue

# -- the observatory card receives ripples (28 Sept 2026) ---------------------
# The hippocampus moves to the Nano, the model stays on the desktop: the ripple
# crosses boxes, and this card turns the receiving end on.
Section "observatory card: receiving a ripple"
$obs = & (Join-Path $ScriptDir "services\powershell\seren-observatory-setup.ps1") -Describe | ConvertFrom-Json
foreach ($f in "ripple", "ripple-command", "ripple-run-as") {
    if ($obs.flags -contains $f) { Good "-Describe advertises $f" } else { Bad "-Describe is missing $f" }
}
if ($obs.switches -contains "ripple") { Good "-Ripple is a switch (a checkbox in the TUI)" } else { Bad "-Ripple is not a switch" }
$osrc = [System.IO.File]::ReadAllText((Join-Path $ScriptDir "services\powershell\seren-observatory-setup.ps1"))
if ($osrc -match [regex]::Escape('$rwho = if ($RippleRunAs) { $RippleRunAs } else { $env:USERNAME }')) {
    Good "run_as defaults to the person running the install" } else { Bad "no run_as default in the observatory card" }

# -RippleClaude on the receiving cards (28 Sept 2026): the model on this box is
# Claude Code. The command and cwd come from seren-claude-ripple.py
# (services/tests/test-claude-ripple.sh); here, that the flag is offered and a
# conflicting pair is refused before anything installs.
Section "observatory + lodestar cards: -RippleClaude"
$lode = & (Join-Path $ScriptDir "services\powershell\seren-lodestar-setup.ps1") -Describe | ConvertFrom-Json
if ($obs.flags -contains "ripple-claude") { Good "observatory -Describe advertises ripple-claude" } else { Bad "observatory -Describe is missing ripple-claude" }
if ($lode.flags -contains "ripple-claude") { Good "lodestar -Describe advertises ripple-claude" } else { Bad "lodestar -Describe is missing ripple-claude" }
foreach ($case in @(
        @{c = "seren-observatory-setup.ps1"; a = @("-RippleClaude", $env:TEMP, "-RippleCommand", "x"); w = "drop -RippleCommand"},
        @{c = "seren-lodestar-setup.ps1"; a = @("-RippleClaude", $env:TEMP, "-RippleTarget", "desktop"); w = "give that node's Observatory card -RippleClaude"},
        @{c = "seren-lodestar-setup.ps1"; a = @("-RippleClaude", $env:TEMP, "-RippleCommand", "x"); w = "drop -RippleCommand"})) {
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $ScriptDir "services\powershell\$($case.c)")) + $case.a
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $out = & (Get-Process -Id $PID).Path @argList 2>&1 | Out-String } finally { $ErrorActionPreference = $prevEap }
    if ($LASTEXITCODE -ne 0 -and $out -match [regex]::Escape($case.w)) { Good "$($case.c) $($case.a[0]) $($case.a[2]) is refused ($($case.w))" }
    else { Bad "$($case.c) $($case.a -join ' ') was not refused: $out" }
}

# -ClaudeMcp (28 Sept 2026): the five MCP cards register their service with
# Claude Code at user scope. The registration passes a JSON entry to claude.exe,
# and Windows PowerShell 5.1 hands embedded double quotes to a native command
# unescaped - so the lib quotes by the CommandLineToArgvW rules itself. Proven
# here through a real .exe (python) that prints what it received.
Section "-ClaudeMcp: registered at user scope, the JSON intact"
foreach ($c in "memory", "loci", "margin", "corpus-callosum", "hippocampus") {
    $cd = & (Join-Path $ScriptDir "services\powershell\seren-$c-setup.ps1") -Describe | ConvertFrom-Json
    if ($cd.switches -contains "claude-mcp") { Good "$c -Describe offers claude-mcp as a switch" } else { Bad "$c is missing the claude-mcp switch" }
}
$marg = & (Join-Path $ScriptDir "services\powershell\seren-margin-setup.ps1") -Describe | ConvertFrom-Json
if ($marg.switches -contains "claude-bookmark") { Good "margin -Describe offers claude-bookmark as a switch" } else { Bad "margin is missing the claude-bookmark switch" }
$py = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($py) { & {
    # -ClaudeBookmark writes the SessionStart hook through seren-claude-hook.py;
    # here into a scratch settings file, never the real one.
    . (Join-Path $ScriptDir "services\lib\seren-install-lib.ps1")
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sw-bm-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $prev = $env:SEREN_CLAUDE_SETTINGS; $env:SEREN_CLAUDE_SETTINGS = Join-Path $tmp "settings.json"
    try {
        Register-SerenClaudeBookmark -Vpy $py.Source -AppDir $tmp -CfgPath "C:\x y\seren-margin.yaml" *> $null
        $s = Get-Content (Join-Path $tmp "settings.json") -Raw | ConvertFrom-Json
        $c = $s.hooks.SessionStart[0].hooks[0].command
        if ($c -match 'seren-margin-bookmark\.py' -and $c -match [regex]::Escape('"C:\x y\seren-margin.yaml"') -and
            (Test-Path (Join-Path $tmp "seren-margin-bookmark.py"))) { Good "-ClaudeBookmark writes a SessionStart hook that runs the copied helper" }
        else { Bad "-ClaudeBookmark hook wrong: $c" }
    } catch { Bad "-ClaudeBookmark failed: $_" }
    finally { $env:SEREN_CLAUDE_SETTINGS = $prev; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
} }
if (-not $py) { Note "no python.exe on PATH - skipping the quoting round trip. Not a failure." }
else { & {
    . (Join-Path $ScriptDir "services\lib\seren-install-lib.ps1")
    $entry = '{"type":"http","url":"http://127.0.0.1:7267/mcp","headersHelper":"\"C:\\Program Files\\py\\python.exe\" \"C:\\s p\\seren-mcp-headers.py\" \"C:\\x\\seren-memory.yaml\""}'
    $sent = @("mcp", "add-json", "--scope", "user", "wren-memory", $entry, 'trailing\', "")
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $py.Source
    # Python compares (5.1's ConvertFrom-Json returns an array as one object).
    $psi.Arguments = (@("-c", "import json,os,sys; a=sys.argv[1:]; print('same' if a == json.loads(os.environ['SEREN_EXPECT']) else json.dumps(a))") + $sent |
                      ForEach-Object { ConvertTo-SerenNativeArg $_ }) -join " "
    $psi.EnvironmentVariables["SEREN_EXPECT"] = ConvertTo-Json -InputObject $sent -Compress
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true
    $p = [System.Diagnostics.Process]::Start($psi); $got = $p.StandardOutput.ReadToEnd().Trim(); $p.WaitForExit()
    if ($got -eq "same") { Good "a JSON entry with quotes, backslashes and spaces reaches the .exe byte for byte" }
    else { Bad "native quoting mangled the arguments: sent $(ConvertTo-Json -InputObject $sent -Compress) got $got" }
} }

# -- the callosum card: only the stores it was given (25 Sept 2026) ------------
# Chad: the callosum holds n stores, better with one of each, either alone
# works - "im a warning message not a cop." The card wrote memory:7420 AND
# loci:7422 whatever it was handed, so a Memory-only callosum reported a dead
# Loci on every search. This runs the REAL card from a scratch tree whose lib
# is the real one with Find-Python / Resolve-Wheel / Create-Venv /
# Install-Package stubbed: no venv, no pip, no network. The "venv" python is
# the real one, importing a stand-in package, so the import check and the
# keep-config step still run for real.
Section "callosum card: only the stores it was given"
$pyExe = $null
foreach ($c in @(Get-Command python -All -ErrorAction SilentlyContinue)) {
    try { if ((& $c.Source -c "print(7)" 2>$null) -eq "7") { $pyExe = $c.Source; break } } catch { }
}
if (-not $pyExe) {
    Note "no working python on PATH - skipping. Not a failure."
} else {
    $sccTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sw-scc-" + [Guid]::NewGuid().ToString("N"))
    $sccCard = Join-Path $sccTmp "services\powershell\seren-corpus-callosum-setup.ps1"
    New-Item -ItemType Directory -Force -Path (Split-Path $sccCard), (Join-Path $sccTmp "services\lib"),
        (Join-Path $sccTmp "pkg\seren_corpus_callosum") | Out-Null
    Copy-Item (Join-Path $ScriptDir "services\powershell\seren-corpus-callosum-setup.ps1") $sccCard
    [System.IO.File]::WriteAllText((Join-Path $sccTmp "pkg\seren_corpus_callosum\__init__.py"), "")
    $realLib = Join-Path $ScriptDir "services\lib\seren-install-lib.ps1"
    $stubLib = ". '$realLib'`n" +
               "function Find-Python { @{ Exe = '$pyExe'; Args = @() } }`n" +
               "function Resolve-Wheel { @{ Src = 'stub'; Cleanup = `$false } }`n" +
               "function Create-Venv { '$pyExe' }`n" +
               "function Install-Package { }`n"
    [System.IO.File]::WriteAllText((Join-Path $sccTmp "services\lib\seren-install-lib.ps1"), $stubLib)
    $memYaml = Join-Path $sccTmp "memory.yaml"
    [System.IO.File]::WriteAllText($memYaml, "server:`n  host: 0.0.0.0`n  port: 7267`n  bearer_token: `"memory-bearer`"`n")
    $oldPyPath = $env:PYTHONPATH
    $env:PYTHONPATH = Join-Path $sccTmp "pkg"
    $env:SEREN_INSTALLED_DIR = Join-Path $sccTmp "ledger"     # never the real ledger
    function Install-Scc([string] $Name, [string[]] $CardArgs) {
        $r = Join-Path $sccTmp "root-$Name"
        $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $sccCard, "-Root", $r) + $CardArgs
        # the engine running this check, so 5.1 is tested by 5.1 and 7 by 7
        # Continue, not Stop, for this one call: GitHub's `shell: powershell` runs with
    # $ErrorActionPreference = stop, and under Windows PowerShell 5.1 a native
    # command's stderr through 2>&1 becomes error records - a card that refuses
    # with a ValidateSet message (stderr, not Die's stdout) aborted the whole run.
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $out = & (Get-Process -Id $PID).Path @argList 2>&1 | Out-String } finally { $ErrorActionPreference = $prevEap }
        $cfg = Join-Path $r "apps\corpus-callosum\seren-corpus-callosum.yaml"
        $text = if (Test-Path $cfg) { [System.IO.File]::ReadAllText($cfg) } else { "" }
        return @{ Rc = $LASTEXITCODE; Out = $out; Cfg = $text }
    }
    try {
        $m = Install-Scc "mem" @("-MemoryConfig", $memYaml)
        if ($m.Rc -eq 0 -and $m.Cfg) { Good "a memory config only: it installs" } else { Bad "memory-only install failed (rc=$($m.Rc))"; Note $m.Out }
        if ($m.Cfg -match "url: http://127\.0\.0\.1:7267" -and $m.Cfg -match 'bearer_token: "memory-bearer"' -and $m.Cfg -match "name: memory") {
            Good "...the memory store, url and bearer read from its config" } else { Bad "memory store wrong: $($m.Cfg)" }
        if ($m.Cfg -notmatch "name: loci" -and $m.Cfg -notmatch "7422") { Good "...and no loci entry" } else { Bad "a loci nobody gave was written: $($m.Cfg)" }

        $l = Install-Scc "loci" @("-LociUrl", "http://127.0.0.1:7266")
        if ($l.Rc -eq 0 -and $l.Cfg -match "name: loci" -and $l.Cfg -notmatch "name: memory" -and $l.Cfg -notmatch "7420") {
            Good "a loci url only: one loci store, no memory entry" } else { Bad "loci-only wrong (rc=$($l.Rc)): $($l.Cfg)" }

        $n = Install-Scc "none" @()
        if ($n.Rc -eq 0 -and $n.Cfg) { Good "neither: it installs anyway (a warning, not a cop)" } else { Bad "neither: install failed (rc=$($n.Rc))"; Note $n.Out }
        if ($n.Out -match "No Memory or Loci was given") { Good "...and warns" } else { Bad "neither: no warning" }
        if ($n.Cfg -notmatch "(?m)^\s+stores:" -and $n.Cfg -notmatch "name: " -and $n.Cfg -match "(?m)^federation:") {
            Good "...with no stores: key under federation" } else { Bad "neither wrote stores: $($n.Cfg)" }
    } catch {
        Bad "callosum section threw: $($_.Exception.Message)"
    } finally {
        $env:PYTHONPATH = $oldPyPath
        Remove-Item Env:SEREN_INSTALLED_DIR -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $sccTmp -ErrorAction SilentlyContinue
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
