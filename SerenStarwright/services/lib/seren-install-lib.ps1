<#
# ════════════════════════════════════════════════════════════════════════
#  seren-install-lib.ps1  -  shared installer library for Seren services
#
#  Dot-source this in any seren-*-setup.ps1 installer:
#    . (Join-Path $PSScriptRoot "..\services\lib\seren-install-lib.ps1")
#    (or use Find-Upward to locate it from any subfolder)
#
#  Provides:
#    Step / Ok / Warn / Die         - colored output helpers
#    Find-Upward                    - reorg-robust file locator
#    Find-Python                    - locate Python 3.10-3.12 (default)
#    Find-Python-NoUpper            - locate Python 3.10+ (SCC)
#    Resolve-Wheel                  - resolve -Wheel / -Local / -Repo / PyPI
#    Resolve-LocalWheel             - the dev wheelhouse (seren-dev-publish)
#    Get-SerenSha256                - file digest without Get-FileHash
#    Create-Venv                    - create or reuse a venv
#    Get-Extras-Suffix              - build "[mcp,corp]" from switches
#    Get-Corp-Args                  - --use-feature=truststore if pip≥24.2
#    Install-Package                - pip install with extras + corp
#    Sanity-Check                   - generic import + asset check
#    Write-Launcher                 - drop a run-*.ps1 launcher
#    Setup-Autostart                - NSSM service via wrapper
# ════════════════════════════════════════════════════════════════════════
#>

# ══════════════════════════════════════════════════════════════════════════
#  Machine-readable contracts (Seren Starwright) - PowerShell side
# ══════════════════════════════════════════════════════════════════════════
#
#  Mirrors the -Describe / -Json contracts in seren-install-lib.sh. Same
#  promise to a consumer: stdout is JSON Lines or empty, stderr is for
#  humans, exit code means what it always did.
#
#  WHY THIS IS NOT THE SAME TRICK AS BASH:
#
#  The bash side stashes fd 1 on fd 3 and points fd 1 at stderr, which
#  redirects every existing `echo` in every installer without editing one.
#  PowerShell has no fd table to juggle - and there are 110 Write-Host
#  calls across these installers, every one of which would land on stdout
#  and corrupt the stream.
#
#  So we use PowerShell's own equivalent lever: command resolution order
#  puts FUNCTIONS ahead of CMDLETS. Defining a global function named
#  Write-Host shadows the real cmdlet, so all 110 existing calls - in this
#  library, in the installers, and in any wrapper .ps1 they invoke with &
#  - route to stderr instead. Same outcome, no edits, and a Write-Host
#  added later can't break the stream either.
#
#  Only active when -Json is passed. Interactive runs keep their colors and
#  behave exactly as before.
#
#  EVERYTHING BELOW IS WINDOWS POWERSHELL 5.1-SAFE. No ternary, no ??, no
#  pipeline chain operators. [ordered]@{}, ConvertTo-Json -Compress and
#  [Console]::Error are all v3+ / .NET and fine on 5.1.
# ══════════════════════════════════════════════════════════════════════════

$script:SerenJson = $false
$script:SerenJsonWriter = $null

# -- Enable-SerenJson - flip on the event stream (called by -Json) -------------
function Enable-SerenJson {
    $script:SerenJson = $true

    # A DEDICATED stdout writer. Every clause below is load-bearing; this
    # took two bugs to arrive at, so do not "simplify" it back.
    #
    #   OpenStandardOutput  - the raw handle, NOT PowerShell's success stream.
    #     Write-Output would put events on the success stream, which is the
    #     same stream a function's return value travels on. Every helper that
    #     emits an event AND returns something (Find-Python, Resolve-Wheel,
    #     Create-Venv, Write-Launcher) then handed its caller
    #     @(json, json, value), and `& $vpy` tried to execute all three joined
    #     into one command name. That is the CommandNotFoundException where
    #     the "command" is two JSON objects followed by a path.
    #
    #   AutoFlush           - the reason a plain [Console]::Out.WriteLine was
    #     abandoned once already. The handle was never the problem; BUFFERING
    #     was. Unflushed output printed perfectly to a console and produced
    #     nothing at all for a parent process reading a redirected pipe - a
    #     contract that worked for humans and silently failed for programs.
    #
    #   UTF8Encoding($false) - no BOM. A BOM would prefix the first event and
    #     make line one unparseable for a strict JSON Lines consumer. Explicit
    #     because the StreamWriter default is not identical across Windows
    #     PowerShell 5.1 and PowerShell 7.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $script:SerenJsonWriter = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8NoBom)
    $script:SerenJsonWriter.AutoFlush = $true
    # Shadow the Write-Host cmdlet so every existing human-facing call in every
    # installer lands on stderr. stdout is reserved for events from here on.
    function global:Write-Host {
        param(
            [Parameter(Position = 0, ValueFromPipeline = $true)] $Object,
            $ForegroundColor,
            $BackgroundColor,
            $Separator,
            [switch] $NoNewline
        )
        process {
            if ($NoNewline) { [Console]::Error.Write([string] $Object) }
            else            { [Console]::Error.WriteLine([string] $Object) }
        }
    }
}

# -- Send-SerenEvent - write one JSON Lines event ------------------------------
# ConvertTo-Json does the escaping, so no hand-rolled quoting to get wrong.
# [ordered] keeps 'event' first for readability when a human tails the stream.
function Send-SerenEvent {
    param([string] $EventName, [hashtable] $Data)
    if (-not $script:SerenJson) { return }
    $obj = [ordered] @{ event = $EventName }
    if ($Data) {
        foreach ($k in $Data.Keys) { $obj[$k] = $Data[$k] }
    }
    $json = ($obj | ConvertTo-Json -Compress -Depth 5)
    if ($script:SerenJsonWriter) {
        $script:SerenJsonWriter.WriteLine($json)
    } else {
        # DEFENSIVE ONLY. Enable-SerenJson always builds the writer, so getting
        # here means something set $script:SerenJson without it - a bug, and one
        # worth being noisy about rather than silently papering over.
        #
        # Deliberately NOT Write-Output: that is the exact defect this function
        # was rewritten to remove (success-stream pollution corrupting every
        # value-returning helper). [Console]::Out with an explicit Flush stays
        # off the success stream and still survives redirection, so it is the
        # safe degraded path rather than a trapdoor back to the old bug.
        [Console]::Error.WriteLine("seren: JSON writer uninitialised - Enable-SerenJson was skipped")
        [Console]::Out.WriteLine($json)
        [Console]::Out.Flush()
    }
}

# -- ConvertTo-SerenFlagName - PascalCase param -> canonical flag name ----------
# Starwright should speak ONE vocabulary regardless of which platform's
# installer it drives, so PowerShell parameter names are normalized to the bash
# flag names. Every installer picked a different host param to dodge the
# collision with PowerShell's automatic $Host variable (SccHost, LociHost,
# MarginHost, ObsHost, WbHost, LodeHost, MemoryHost) - they all mean 'host'.
function ConvertTo-SerenFlagName {
    param([string] $ParamName)
    if ($ParamName -match 'Host$') { return 'host' }
    if ($ParamName -eq 'VenvDir')  { return 'venv' }
    # PascalCase -> kebab-case: GenToken -> gen-token, RepoDir -> repo-dir
    return ($ParamName -creplace '(?<!^)([A-Z])', '-$1').ToLower()
}

# -- Get-SerenFlagsFromSelf - read the caller's OWN declared parameters --------
# The param() block is the only thing that actually decides which flags exist,
# so ask it rather than maintaining a second list that drifts. Mirrors
# seren_flags_from_self on the bash side.
function Get-SerenFlagsFromSelf {
    param([string] $ScriptPath)
    if (-not $ScriptPath) { return @() }
    try {
        $cmd = Get-Command -Name $ScriptPath -CommandType ExternalScript -ErrorAction Stop
        $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
                  @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
        $out = @()
        foreach ($p in $cmd.Parameters.Keys) {
            if ($common -contains $p) { continue }
            $out += (ConvertTo-SerenFlagName $p)
        }
        return @($out | Sort-Object -Unique)
    } catch {
        return @()
    }
}

# -- Get-SerenDescribe - the -Describe payload ---------------------------------
# ZERO side effects: no venv, no network, no Python. Call it before anything
# else runs. Emits the same schema as the bash seren_describe, plus a
# native-parameter map so a front-end can build the real command line.
function Get-SerenDescribe {
    param(
        [string] $ScriptPath,
        [string] $Name, [string] $Display, [string] $Description,
        [string] $Group = "core", [string] $Package,
        [string] $DefaultHost = "127.0.0.1", [int] $DefaultPort = 0,
        # Hex colour for the service's card in Seren Starwright. Taken from the
        # service's OWN viewer accent where it has one, so the card you tick is
        # the colour of the UI you land on afterwards.
        [string] $Accent = "",
        # Explicit override for the derived extras list. The derivation below is a
        # family-wide allowlist, so it cannot know that a given package declares
        # mcp as a CORE dep rather than an extra (lodestar, workbench). Those
        # installers pass Extras to say what they actually publish.
        [string[]] $Extras = @(),
        # Service names this one needs ALREADY INSTALLED.
        #
        # DECLARED, never derived - the only honest source is the config the
        # installer writes, and no amount of parsing $ScriptPath can see that.
        #
        # This parameter did not exist, and its absence was not cosmetic: the
        # emitted object simply had no `requires` key, so on Windows every
        # service looked dependency-free. Starwright feeds `requires` into
        # resolve_dependencies and install_order, so selecting Corpus Callosum
        # on a Windows box installed a bridge to nothing - the exact failure the
        # bash side declares SVC_REQUIRES to prevent, and which the test suite
        # names as its reason for existing.
        [string[]] $Requires = @()
    )
    $flags  = @(Get-SerenFlagsFromSelf -ScriptPath $ScriptPath)
    if ($Extras.Count -gt 0) {
        $extras = @($Extras)
    } else {
        $extras = @()
        foreach ($f in $flags) {
            if ($f -eq 'mcp' -or $f -eq 'corp' -or $f -eq 'vector' -or $f -eq 'st') { $extras += $f }
        }
    }
    # canonical flag -> the actual PowerShell parameter to pass
    $params = [ordered] @{}
    # Flags that take NO value ([switch] parameters). The front-end renders
    # these as check boxes; anything else is a text box. Mirrors
    # seren_switches_from_self on the bash side.
    $switches = @()
    if ($ScriptPath) {
        try {
            $cmd = Get-Command -Name $ScriptPath -CommandType ExternalScript -ErrorAction Stop
            $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
                      @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
            foreach ($p in $cmd.Parameters.Keys) {
                if ($common -contains $p) { continue }
                $params[(ConvertTo-SerenFlagName $p)] = $p
                if ($cmd.Parameters[$p].ParameterType -eq [switch]) {
                    $switches += (ConvertTo-SerenFlagName $p)
                }
            }
            $switches = @($switches | Sort-Object -Unique)
        } catch { }
    }
    $obj = [ordered] @{
        schema_version = 1
        name           = $Name
        display        = $Display
        description    = $Description
        group          = $Group
        package        = $Package
        platform       = "powershell"
        default_host   = $DefaultHost
        default_port   = $DefaultPort
        accent         = $Accent
        extras         = $extras
        flags          = $flags
        # @() forces an ARRAY through ConvertTo-Json. Without it a single
        # requirement serialises as a bare string and a one-dependency service
        # would hand the TUI "seren-memory" where it iterates a list - which
        # walks the characters.
        switches       = @($switches)
        requires       = @($Requires)
        params         = $params
    }
    # Write-Output is CORRECT here, unlike in Send-SerenEvent, and the
    # difference is worth stating rather than cross-referencing:
    #
    # --describe runs BEFORE Enable-SerenJson (the installers answer it ahead
    # of their arg loop so it has zero side effects), so the dedicated stdout
    # writer does not exist yet. And this is a terminal one-shot write - the
    # caller emits this object and immediately exits, so nothing captures a
    # return value and there is nothing for the success stream to corrupt.
    #
    # Send-SerenEvent is the opposite case: it fires from inside helpers whose
    # return values ARE captured, which is why it needs its own writer.
    Write-Output ($obj | ConvertTo-Json -Compress -Depth 5)
}

# -- Read-SerenSiblingConfig - a card reads another service's config ----------
# Twin of seren_read_sibling_config. A token never crosses a command line: the
# card is handed the sibling's config PATH and reads host, port and the bearer
# (inline, env var name, or keyring ref) itself.
function Read-SerenSiblingConfig {
    param([Parameter(Mandatory)] [string] $Path)
    $out = @{ Url = ""; Token = ""; TokenEnv = ""; TokenKeyring = "" }
    if (-not (Test-Path $Path)) { Warn "sibling config not readable: $Path"; return $out }
    # The SERVER block only: a hippocampus or callosum config also carries the
    # bearer it presents to Memory, which is not its own.
    $lines = @()
    $inServer = $false
    foreach ($l in (Get-Content $Path)) {
        if ($l -match '^server:\s*(#.*)?$') { $inServer = $true; continue }
        if ($l -match '^[^\s#]') { $inServer = $false }
        if ($inServer) { $lines += $l }
    }
    function _first($pattern) {
        foreach ($l in $lines) {
            if ($l -match $pattern) {
                $v = $Matches[1].Trim()
                $v = ($v -replace '\s*#.*$', '')
                return $v.Trim('"').Trim("'")
            }
        }
        return ""
    }
    $sHost = _first '^\s+host:\s*(.*)$'
    $sPort = _first '^\s+port:\s*(.*)$'
    if (-not $sHost -or $sHost -eq "0.0.0.0") { $sHost = "127.0.0.1" }
    if ($sPort) { $out.Url = "http://${sHost}:${sPort}" }
    $out.Token        = _first '^\s+bearer_token:\s*(.*)$'
    $out.TokenEnv     = _first '^\s+bearer_token_env:\s*(.*)$'
    $out.TokenKeyring = _first '^\s+bearer_token_keyring:\s*(.*)$'
    return $out
}

# -- Get-SerenReusedToken - keep the bearer a reinstall would otherwise wipe ----
# Twin of seren_reuse_token: with neither -Token nor -GenToken, the existing
# config's own bearer is kept instead of being overwritten with nothing.
function Get-SerenReusedToken {
    param([string] $Path)
    if (-not $Path -or -not (Test-Path $Path)) { return "" }
    $sib = Read-SerenSiblingConfig -Path $Path
    if ($sib.Token) {
        Ok "Keeping the existing bearer token (-GenToken rotates it, -Token sets one)"
        return $sib.Token
    }
    if ($sib.TokenEnv -or $sib.TokenKeyring) {
        Warn "The existing config presents its bearer through a pointer ($($sib.TokenEnv)$($sib.TokenKeyring)); the new config does not carry that line - add it back (the old file is kept as a .bak)"
    }
    return ""
}

# -- Get-SerenSiblingTokenLines - the yaml lines that present a sibling's bearer
function Get-SerenSiblingTokenLines {
    param([hashtable] $Sib, [string] $Indent = "  ")
    $t = ""
    if ($Sib.Token)        { $t += "${Indent}bearer_token: `"$($Sib.Token)`"`n" }
    if ($Sib.TokenEnv)     { $t += "${Indent}bearer_token_env: $($Sib.TokenEnv)`n" }
    if ($Sib.TokenKeyring) { $t += "${Indent}bearer_token_keyring: `"$($Sib.TokenKeyring)`"`n" }
    return $t
}

# -- Write-SerenInstallRecord - the install ledger -----------------------------
# Twin of seren_record_install in the bash library. One record per install in
# $env:USERPROFILE\.seren\installed\<service>[@<instance>].json (or
# $env:SEREN_INSTALLED_DIR), derived from what was installed. Never the token.
function Write-SerenInstallRecord {
    param(
        [string] $Service, [string] $ConnectHost, [int] $Port,
        [bool] $Autostart, [string] $Token,
        [bool] $Mcp = $false, [bool] $Corp = $false, [bool] $Vector = $false,
        [string] $Venv = "", [string] $Config = "", [string] $Package = ""
    )
    $dir = $env:SEREN_INSTALLED_DIR
    if (-not $dir) { $dir = Join-Path $env:USERPROFILE ".seren\installed" }
    try { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    catch { Warn "Couldn't write $dir - this install is not in the ledger"; return }
    $inst = ""
    $iv = Get-Variable -Name Instance -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($iv) { $inst = [string] $iv }
    $name = $Service
    if ($inst) { $name = "$Service@$inst" }
    $path = Join-Path $dir "$name.json"
    if (-not $Package) { $Package = $Service }
    $appDir = ""
    if ($Config) { $appDir = Split-Path -Parent $Config }
    $version = ""
    $vpy = ""
    if ($Venv -and (Test-Path (Join-Path $Venv "Scripts\python.exe"))) { $vpy = Join-Path $Venv "Scripts\python.exe" }
    if ($vpy) {
        try { $version = [string] (& $vpy -c "import importlib.metadata as m, sys; print(m.version(sys.argv[1]))" $Package 2>$null) } catch { $version = "" }
        if (-not $version) { $version = "" }
        $version = $version.Trim()
    }
    $source = "pypi"; $sourceRef = ""
    $rv = Get-Variable -Name Ref   -ValueOnly -ErrorAction SilentlyContinue
    $lv = Get-Variable -Name Local -ValueOnly -ErrorAction SilentlyContinue
    $wv = Get-Variable -Name Wheel -ValueOnly -ErrorAction SilentlyContinue
    if ($rv) { $source = "release"; $sourceRef = [string] $rv }
    if ($lv) { $source = "local";   $sourceRef = [string] $lv }
    if ($wv) { $source = "wheel";   $sourceRef = [string] $wv }
    $hasToken = $false
    if ($Token) { $hasToken = $true }
    $launcher = ""
    if ($appDir) { $launcher = Join-Path $appDir "run-$Service.ps1" }
    $rec = [ordered] @{
        schema_version = 1
        service        = $Service
        instance       = $inst
        package        = $Package
        version        = $version
        host           = $ConnectHost
        port           = $Port
        url            = "http://${ConnectHost}:${Port}"
        venv           = $Venv
        config         = $Config
        app_dir        = $appDir
        launcher       = $launcher
        autostart      = $Autostart
        service_user   = [string] (Get-Variable -Name ServiceUser -ValueOnly -ErrorAction SilentlyContinue)
        local_system   = [bool] (Get-Variable -Name LocalSystem -ValueOnly -ErrorAction SilentlyContinue)
        has_token      = $hasToken
        extras         = [ordered] @{ mcp = $Mcp; corp = $Corp; vector = $Vector; st = $false }
        source         = $source
        source_ref     = $sourceRef
        installed_at   = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        setup          = [string] $env:SEREN_SETUP
        installer      = (Split-Path -Leaf $MyInvocation.PSCommandPath)
        platform       = "Windows"
        derived        = $false
    }
    $json = ($rec | ConvertTo-Json -Depth 4)
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))
    Ok "Recorded in the install ledger: $path"
    Send-SerenEvent -EventName "installed" -Data @{ path = $path; service = $Service; instance = $inst; version = $version }
}

# -- Send-SerenDone - the structured completion event --------------------------
function Send-SerenDone {
    param(
        [string] $Service, [string] $ConnectHost, [int] $Port,
        [bool] $Autostart, [string] $Token,
        [bool] $Mcp = $false, [bool] $Corp = $false, [bool] $Vector = $false,
        [string] $Venv = "", [string] $Config = ""
    )
    $hasToken = $false
    if ($Token) { $hasToken = $true }
    # The ledger first: written whether or not anyone asked for -Json.
    Write-SerenInstallRecord -Service $Service -ConnectHost $ConnectHost -Port $Port -Autostart $Autostart `
        -Token $Token -Mcp $Mcp -Corp $Corp -Vector $Vector -Venv $Venv -Config $Config
    Send-SerenEvent -EventName "done" -Data @{
        ok        = $true
        service   = $Service
        host      = $ConnectHost
        port      = $Port
        url       = "http://${ConnectHost}:${Port}"
        autostart = $Autostart
        mcp       = $Mcp
        corp      = $Corp
        vector    = $Vector
        venv      = $Venv
        config    = $Config
        has_token = $hasToken
    }
}

# -- output helpers -----------------------------------------------------------
# Human text unchanged (colors intact for interactive runs); structured twin on
# stdout when -Json is on. One edit here covers every installer.
function Step($m){ Write-Host "`n==> $m" -ForegroundColor Blue;  Send-SerenEvent -EventName "step"  -Data @{ msg = $m } }
function Ok($m)  { Write-Host "  + $m"   -ForegroundColor Green; Send-SerenEvent -EventName "ok"    -Data @{ msg = $m } }
function Warn($m){ Write-Host "  ! $m"   -ForegroundColor Yellow;Send-SerenEvent -EventName "warn"  -Data @{ msg = $m } }
function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red;  Send-SerenEvent -EventName "error" -Data @{ msg = $m }; exit 1 }

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

# -- find a usable Python 3.10-3.12 -------------------------------------------
function Find-Python {
    param([switch] $NoUpper)   # $NoUpper → allow 3.13 (SCC)
    Step "Finding a usable Python$(if ($NoUpper) { ' (3.10+)' } else { ' (3.10-3.12)' })"
    $candidates = @("python", "py -3.12", "py -3.11", "py -3.10")
    if ($NoUpper) { $candidates = @("python", "py -3.13", "py -3.12", "py -3.11", "py -3.10") }
    $pyBin = $null
    foreach ($cand in $candidates) {
        $parts = $cand.Split(" ")
        $exe = $parts[0]
        if (Get-Command $exe -ErrorAction SilentlyContinue) {
            try {
                $ver = & $exe $parts[1..($parts.Length-1)] -c "import sys; print('%d.%d'%sys.version_info[:2])" 2>$null
            } catch { $ver = "" }
            if ($NoUpper) {
                if ($ver -match '^3\.(10|11|12|13)$') { $pyBin = $cand; break }
            } else {
                if ($ver -match '^3\.(10|11|12)$') { $pyBin = $cand; break }
            }
        }
    }
    if (-not $pyBin) { Die "No suitable Python found. Install from python.org or 'winget install Python.Python.3.12'." }
    $pyArr = $pyBin.Split(" ")
    $pyExe = $pyArr[0]; $pyArgs = $pyArr[1..($pyArr.Length-1)]
    $pyVer = & $pyExe $pyArgs -c "import sys; print('%d.%d.%d'%sys.version_info[:3])"
    Ok "Using '$pyBin' (Python $pyVer)"
    return @{ Exe = $pyExe; Args = $pyArgs; Bin = $pyBin; Ver = $pyVer }
}

# -- the dev wheelhouse (-Local DIR|URL) -------------------------------------
# A wheelhouse is what seren-dev-publish.ps1 writes: one wheel per project plus
# SHA256SUMS in sha256sum's format. It is a folder, or an http(s) URL where the
# same folder is served (python -m http.server, which is what -Serve does).
#
# Returns @{ Src; Cleanup } like Resolve-Wheel, and leaves the pip arguments
# that make the house count (--find-links + a constraints file) in
# $global:serenPipArgs for Install-Package to pick up.
#
# WHY A CONSTRAINTS FILE: a dev build of seren-meninges is a pre-release
# (2.4.1.dev3+g...), and pip never picks a pre-release to satisfy a plain
# `seren-meninges>=2.4.0` unless told to. `--pre` would say so for EVERY
# package in the tree. An exact `==` pin on the pre-release version says it
# for that one package only, so every seren-* wheel in the house is pinned by
# name and pip takes the dev copy - with its dependencies - and nothing else
# changes.
# -- Get-SerenSha256 - hex digest of a file, on every PowerShell edition ------
# Not Get-FileHash: it is a module cmdlet, and a Windows PowerShell whose
# Microsoft.PowerShell.Utility is damaged (seen in the wild) has no such
# command, while the .NET class is always there.
function Get-SerenSha256 {
    param([string] $Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { $bytes = $sha.ComputeHash($fs) } finally { $fs.Dispose(); $sha.Dispose() }
    return ([System.BitConverter]::ToString($bytes)).Replace("-", "").ToLower()
}

$global:serenPipArgs = @()
function Resolve-LocalWheel {
    param([string] $House, [string] $Package)
    $pkgUs = $Package -replace '-', '_'
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ("seren_local_" + [System.IO.Path]::GetRandomFileName().Replace('.', ''))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $isUrl = $House -match '^https?://'
    if ($House -match '^file://') { $House = $House -replace '^file://', '' }
    if ($isUrl) {
        $House = $House.TrimEnd('/')
        $findLinks = "$House/"
        Step "Reading the dev wheelhouse at $House"
        $index = Join-Path $stage "SHA256SUMS"
        try { Invoke-WebRequest -Uri "$House/SHA256SUMS" -OutFile $index -UseBasicParsing }
        catch { Die "no SHA256SUMS at $House - is seren-dev-publish.ps1 -Serve running there?" }
    } else {
        Step "Reading the dev wheelhouse at $House"
        if (-not (Test-Path $House -PathType Container)) { Die "wheelhouse not found: $House" }
        $findLinks = (Resolve-Path $House).Path
        $index = Join-Path $findLinks "SHA256SUMS"
        if (-not (Test-Path $index)) { Die "no SHA256SUMS in $House - run seren-dev-publish.ps1 first" }
    }

    # Newest wheel per seren-* project, from the index alone. Numeric runs are
    # zero-padded so 3.0.1.dev2 sorts after 3.0.0 and .dev3 after .dev2 - the
    # same order the bash side gets from `sort -V`.
    $hashes = @{}
    foreach ($line in Get-Content $index) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(\S+)$') {
            $n = $Matches[2]
            if ($n -like 'seren_*.whl' -and $n -notmatch '/') { $hashes[$n] = $Matches[1].ToLower() }
        }
    }
    $latest = @{}
    foreach ($n in $hashes.Keys) {
        $parts = $n.Split('-')
        $dist = $parts[0]; $ver = $parts[1]
        $key = [regex]::Replace($ver, '\d+', { param($m) $m.Value.PadLeft(8, '0') })
        if (-not $latest.ContainsKey($dist) -or ([string]::CompareOrdinal($key, $latest[$dist].Key) -gt 0)) {
            $latest[$dist] = @{ Name = $n; Ver = $ver; Key = $key }
        }
    }
    $constraints = Join-Path $stage "constraints.txt"
    $lines = @()
    $best = $null
    foreach ($dist in ($latest.Keys | Sort-Object)) {
        $lines += "$($dist -replace '_', '-')==$($latest[$dist].Ver)"
        if ($dist -eq $pkgUs) { $best = $latest[$dist].Name }
    }
    [System.IO.File]::WriteAllText($constraints, ($lines -join "`n") + "`n", (New-Object System.Text.UTF8Encoding $false))
    if (-not $best) { Die "no $pkgUs-*.whl in the wheelhouse index ($($latest.Count) seren wheels listed)" }

    # Fetch (or locate) the one wheel this card installs, and verify it either
    # way - a folder can be edited by hand too.
    if ($isUrl) {
        $wheelSrc = Join-Path $stage $best
        try { Invoke-WebRequest -Uri "$House/$([uri]::EscapeDataString($best))" -OutFile $wheelSrc -UseBasicParsing }
        catch { Die "download failed: $best" }
    } else {
        $wheelSrc = Join-Path $findLinks $best
        if (-not (Test-Path $wheelSrc)) { Die "index lists $best but the file is not in $House" }
    }
    $have = Get-SerenSha256 -Path $wheelSrc
    if ($have -ne $hashes[$best]) {
        if ($isUrl) { Remove-Item -Force $wheelSrc -ErrorAction SilentlyContinue }
        Die "$best failed verification against the wheelhouse index (republish, or check what is serving it)"
    }
    $global:serenPipArgs = @('--find-links', $findLinks, '-c', $constraints)
    Ok "Dev wheel $best  (+ $($latest.Count - 1) other seren wheel(s) pinned from the house)"
    return @{ Src = $wheelSrc; Cleanup = $false }
}

# -- resolve wheel source (wheel / dev house / GitHub / PyPI) -----------------
# Precedence: -Wheel > -Local > -Repo/-Ref > PyPI
function Resolve-Wheel {
    param(
        [string] $Wheel,
        [string] $Ref,
        [string] $Repo,
        [string] $Package,
        [string] $Local = ""
    )
    if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/$Package" }
    $wheelSrc = $null
    $cleanupWheel = $false
    $global:serenPipArgs = @()
    $pyInfo = $global:pyInfo
    if ($Wheel) {
        if (-not (Test-Path $Wheel)) { Die "wheel not found: $Wheel" }
        $wheelSrc = (Resolve-Path $Wheel).Path
        Ok "Installing from local wheel: $(Split-Path $wheelSrc -Leaf)"
    } elseif ($Local) {
        return Resolve-LocalWheel -House $Local -Package $Package
    } elseif ($Repo) {
        Step "Resolving the $Package release from GitHub ($Repo)"
        $api = if ($Ref) { "https://api.github.com/repos/$Repo/releases/tags/$Ref" }
               else      { "https://api.github.com/repos/$Repo/releases/latest" }
        try { $rel = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "seren-setup" } }
        catch { Die "GitHub API request failed ($api). Check the repo/tag and your network." }
        $asset = $rel.assets | Where-Object { $_.name -like "*.whl" } | Select-Object -First 1
        if (-not $asset) { Die "No .whl asset in release '$($rel.tag_name)'. Use -Wheel instead." }
        Ok "Release $($rel.tag_name)  ($($asset.name))"
        $wheelSrc = Join-Path $env:TEMP $asset.name
        $cleanupWheel = $true
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $wheelSrc -UseBasicParsing
        Ok "Downloaded"
    } else {
        $wheelSrc = $Package   # latest from PyPI
        Ok "No wheel or GitHub ref specified - will install the latest from PyPI"
    }
    return @{ Src = $wheelSrc; Cleanup = $cleanupWheel }
}

# -- create or reuse a venv ---------------------------------------------------
function Create-Venv {
    param([string] $VenvDir, [string] $PyExe, [array] $PyArgs)
    Step "Creating venv at $VenvDir"
    if (Test-Path "$VenvDir\Scripts\python.exe") {
        Warn "venv already exists - reusing it (will upgrade the package)"
    } else {
        & $PyExe $PyArgs -m venv $VenvDir
        if (-not (Test-Path "$VenvDir\Scripts\python.exe")) { Die "venv creation failed" }
        Ok "venv created"
    }
    return "$VenvDir\Scripts\python.exe"
}

# -- build extras suffix from switches ----------------------------------------
function Get-Extras-Suffix {
    param([switch] $Mcp, [switch] $Corp, [switch] $Vector, [switch] $St)
    $list = @()
    if ($Mcp)     { $list += "mcp" }
    if ($Corp)    { $list += "corp" }
    if ($Vector)  { $list += "vector" }
    if ($St)      { $list += "st" }      # seren-memory: sentence-transformers for a named embedding_model
    if ($list.Count -eq 0) { return "" }
    return "[$($list -join ',')]"
}

# -- get pip corp args (truststore) -------------------------------------------
function Get-Corp-Args {
    param([string] $Vpy)
    $corpArgs = @()
    if ($Corp) {
        $pipVerRaw = ((& $Vpy -m pip --version) 2>$null) -join "`n"
        if ($pipVerRaw -match '(\d+)\.(\d+)') {
            $maj = [int]$Matches[1]; $min = [int]$Matches[2]
            if ($maj -gt 24 -or ($maj -eq 24 -and $min -ge 2)) { $corpArgs += '--use-feature=truststore' }
        }
    }
    return $corpArgs
}

# -- pip install with extras + corp -------------------------------------------
function Install-Package {
    param([string] $Vpy, [string] $WheelSrc, [string] $Extras, [string] $Label)
    $installSpec = "$WheelSrc$Extras"
    $corpArgs = Get-Corp-Args -Vpy $Vpy
    Step "Installing seren-*${Extras}  $Label"
    & $Vpy -m pip install -q --upgrade pip
    # $global:serenPipArgs is set by Resolve-LocalWheel (--find-links +
    # constraints) and empty otherwise, so every card gets the house for free.
    & $Vpy -m pip install -q --upgrade $corpArgs $global:serenPipArgs $installSpec
    if ($LASTEXITCODE -ne 0) { Die "pip install failed - see output above" }
    # A wheel FILE can carry the same version as the installed build (a dirty
    # tree is stamped with its commit and the day only), and --upgrade then
    # installs nothing while reporting success. Reinstall the package itself
    # from the file, dependencies untouched.
    if ($WheelSrc -like "*.whl" -and (Test-Path $WheelSrc)) {
        & $Vpy -m pip install -q --force-reinstall --no-deps $corpArgs $WheelSrc
        if ($LASTEXITCODE -ne 0) { Die "pip could not reinstall $WheelSrc over the installed build" }
    }
    Ok "Installed"
}

# -- sanity check (import + optional asset) -----------------------------------
function Sanity-Check {
    param([string] $Vpy, [string] $Module, [string] $AssetRelPath, [string] $AssetLabel)
    Step "Sanity-checking the install"
    $script = @"
import pathlib
try:
    import $Module
except Exception as e:
    print(f'IMPORT_FAILED: {e}'); raise SystemExit
"@
    if ($AssetRelPath) {
        $script += "`n" + @"
v = pathlib.Path($Module.__file__).parent / '$AssetRelPath'
print('OK' if v.exists() else 'ASSET_MISSING')
"@
    } else {
        $script += "`nprint('OK')"
    }
    $check = & $Vpy -c $script
    switch -Wildcard ($check) {
        "OK"            { Ok "Package imports cleanly$(if ($AssetLabel) { " and the $AssetLabel asset is present" } else { '' })" }
        "ASSET_MISSING" { Warn "Installed but $AssetLabel is missing - check wheel packaging" }
        default         { Die "Install looks broken: $check" }
    }
}

# ══════════════════════════════════════════════════════════════════════════
#  Text file writers - UTF-8 with NO BOM, on every PowerShell edition
# ══════════════════════════════════════════════════════════════════════════
#
#  `Set-Content -Encoding UTF8` means UTF-8 WITH BOM on Windows PowerShell 5.1
#  and WITHOUT on PowerShell 7. Same flag, different bytes, no warning. That
#  cost a real outage: a BOM'd seren-memory.yaml made PyYAML throw
#  "unacceptable character #xfeff", the service's lenient config loader fell
#  back to defaults without a word, and the memory store came up looking EMPTY
#  while the real one sat untouched on disk. A silent fallback plus a silent
#  encoding change is an outage nobody can see.
#
#  Enable-SerenJson above already got this right for the event stream, for
#  exactly the same reason, and said so at length. The lesson just never
#  reached the config writer. It has now: nothing in this family writes a text
#  file any other way.
#
#  Both helpers ACCUMULATE and write once in `end`, rather than writing per
#  pipeline item. Set-Content joins an array of lines with newlines; a naive
#  process-block port would instead overwrite the file once per element and
#  leave only the last line. Every current caller pipes a single here-string,
#  so this costs nothing today and stops a future multi-line caller silently
#  losing its file.
function Write-SerenTextFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(ValueFromPipeline = $true)] $Content
    )
    begin { $lines = New-Object System.Collections.ArrayList }
    process { if ($null -ne $Content) { [void] $lines.Add([string] $Content) } }
    end {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Path, ($lines -join "`r`n"), $utf8NoBom)
    }
}

function Add-SerenTextFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(ValueFromPipeline = $true)] $Content
    )
    begin { $lines = New-Object System.Collections.ArrayList }
    process { if ($null -ne $Content) { [void] $lines.Add([string] $Content) } }
    end {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        # AppendAllText never emits a preamble, so an append cannot reintroduce
        # a BOM mid-file the way Add-Content -Encoding UTF8 can when it decides
        # it is creating rather than extending.
        [System.IO.File]::AppendAllText($Path, ($lines -join "`r`n"), $utf8NoBom)
    }
}

# -- write launcher script ----------------------------------------------------
function Write-Launcher {
    param([string] $AppDir, [string] $ServiceName, [string] $Vpy, [string] $Module, [string] $CfgPath)
    # The config is written by now and the service not yet started: put back
    # whatever the previous config had that this card does not write. See
    # seren-keep-config.py beside this library.
    $keep = Join-Path $PSScriptRoot 'seren-keep-config.py'
    if ((Test-Path $keep) -and $CfgPath) {
        $said = (& $Vpy $keep $CfgPath 2>&1) -join ' '
        if ($LASTEXITCODE -ne 0) { Warn "could not carry the previous config forward: $said" }
        elseif ($said -like 'kept*') { Ok ("K" + $said.Substring(1)) }
    }
    $launcher = "$AppDir\run-$ServiceName.ps1"
    "& `"$Vpy`" -m $Module --config `"$CfgPath`"" | Write-SerenTextFile -Path $launcher
    Ok "Launcher written: $launcher"
    return $launcher
}

# -- setup autostart via NSSM wrapper -----------------------------------------
# ServiceUser / LocalSystem ride through to the core so a NON-INTERACTIVE
# caller (Starwright, which spawns installers with piped stdout+stderr) can
# state the service identity up front, instead of the core trying to prompt at
# a console nobody is watching.
#
# The PASSWORD is deliberately absent from this signature. It travels in
# $env:SEREN_SERVICE_PASSWORD, which the core reads directly. A parameter would
# put it on a command line, and on Windows any process can read another
# process's command line - a redacted log wouldn't help.
function Setup-Autostart {
    param([string] $ScriptDir, [string] $ServiceName, [string] $AppDir, [string] $Token, [string] $VenvDir = "",
          [string] $ServiceUser = "", [switch] $LocalSystem)
    Step "Installing the autostart service"
    $shortName = $ServiceName -replace "^seren-", ""
    $wrapper = Join-Path $ScriptDir "setup-$shortName-service.ps1"
    $core = Find-Upward "services\lib\setup-seren-service.ps1"
    if ((Test-Path $wrapper) -and $core -and (Test-Path $core)) {
        $venvArg = if ($VenvDir) { @{VenvDir = $VenvDir} } else { @{} }
        $idArg = @{}
        if ($ServiceUser) { $idArg["ServiceUser"] = $ServiceUser }
        if ($LocalSystem) { $idArg["RunAsLocalSystem"] = $true }
        & $wrapper -Instance $Instance @venvArg @idArg
    } else {
        Warn "setup-$shortName-service.ps1 + setup-seren-service.ps1 not found."
        Warn "Keep the shared setup scripts together and run (elevated):"
        Warn "  .\setup-$shortName-service.ps1 -Instance '$Instance'"
    }
}
