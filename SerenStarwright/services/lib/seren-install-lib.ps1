<#
# ════════════════════════════════════════════════════════════════════════
#  seren-install-lib.ps1  -  shared installer library for Seren services
#
#  Dot-source this in any seren-*-setup.ps1 installer:
#    . (Join-Path $PSScriptRoot "..\services\lib\seren-install-lib.ps1")
#    (or use Find-Upward to locate it from any subfolder)
#
#  Provides:
#    Step / Ok / Warn / Die         — colored output helpers
#    Find-Upward                    — reorg-robust file locator
#    Find-Python                    — locate Python 3.10-3.12 (default)
#    Find-Python-NoUpper            — locate Python 3.10+ (SCC)
#    Resolve-Wheel                  — resolve --wheel / --repo / PyPI
#    Create-Venv                    — create or reuse a venv
#    Get-Extras-Suffix              — build "[mcp,corp]" from switches
#    Get-Corp-Args                  — --use-feature=truststore if pip≥24.2
#    Install-Package                — pip install with extras + corp
#    Sanity-Check                   — generic import + asset check
#    Write-Launcher                 — drop a run-*.ps1 launcher
#    Setup-Autostart                — NSSM service via wrapper
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

# -- Enable-SerenJson - flip on the event stream (called by -Json) -------------
function Enable-SerenJson {
    $script:SerenJson = $true
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
    # Write-Output, NOT [Console]::Out.WriteLine.
    #
    # [Console]::Out writes straight to the process's console handle, which
    # bypasses PowerShell's success stream. That sounds like a feature here
    # (nothing else can pollute the JSON) and it works fine on screen - but it
    # does not reliably reach a REDIRECTED stdout when powershell.exe is
    # launched as a child process with -File, which is precisely how Starwright
    # and every other consumer runs these. The result was a contract that
    # printed perfectly for a human and produced nothing at all for a program.
    #
    # The success stream is safe to use because Enable-SerenJson has already
    # shadowed Write-Host to stderr - so in --json mode nothing else is writing
    # here anyway.
    Write-Output ($obj | ConvertTo-Json -Compress -Depth 5)
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
        [string[]] $Extras = @()
    )
    $flags  = @(Get-SerenFlagsFromSelf -ScriptPath $ScriptPath)
    if ($Extras.Count -gt 0) {
        $extras = @($Extras)
    } else {
        $extras = @()
        foreach ($f in $flags) {
            if ($f -eq 'mcp' -or $f -eq 'corp' -or $f -eq 'vector' -or $f -eq 'updates') { $extras += $f }
        }
    }
    # canonical flag -> the actual PowerShell parameter to pass
    $params = [ordered] @{}
    if ($ScriptPath) {
        try {
            $cmd = Get-Command -Name $ScriptPath -CommandType ExternalScript -ErrorAction Stop
            $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
                      @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
            foreach ($p in $cmd.Parameters.Keys) {
                if ($common -contains $p) { continue }
                $params[(ConvertTo-SerenFlagName $p)] = $p
            }
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
        params         = $params
    }
    # See Send-SerenEvent for why this is Write-Output rather than
    # [Console]::Out.WriteLine - the short version is that the latter does not
    # survive being redirected into a pipe by a parent process.
    Write-Output ($obj | ConvertTo-Json -Compress -Depth 5)
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

# -- resolve wheel source (local / GitHub / PyPI) -----------------------------
function Resolve-Wheel {
    param(
        [string] $Wheel,
        [string] $Ref,
        [string] $Repo,
        [string] $Package
    )
    if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/$Package" }
    $wheelSrc = $null
    $cleanupWheel = $false
    $pyInfo = $global:pyInfo
    if ($Wheel) {
        if (-not (Test-Path $Wheel)) { Die "wheel not found: $Wheel" }
        $wheelSrc = (Resolve-Path $Wheel).Path
        Ok "Installing from local wheel: $(Split-Path $wheelSrc -Leaf)"
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
    param([switch] $Mcp, [switch] $Corp, [switch] $Vector, [switch] $Updates)
    $list = @()
    if ($Mcp)     { $list += "mcp" }
    if ($Corp)    { $list += "corp" }
    if ($Vector)  { $list += "vector" }
    if ($Updates) { $list += "updates" }
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
    & $Vpy -m pip install -q --upgrade $corpArgs $installSpec
    if ($LASTEXITCODE -ne 0) { Die "pip install failed - see output above" }
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

# -- write launcher script ----------------------------------------------------
function Write-Launcher {
    param([string] $AppDir, [string] $ServiceName, [string] $Vpy, [string] $Module, [string] $CfgPath)
    $launcher = "$AppDir\run-$ServiceName.ps1"
    "& `"$Vpy`" -m $Module --config `"$CfgPath`"" | Set-Content -Path $launcher -Encoding UTF8
    Ok "Launcher written: $launcher"
    return $launcher
}

# -- setup autostart via NSSM wrapper -----------------------------------------
function Setup-Autostart {
    param([string] $ScriptDir, [string] $ServiceName, [string] $AppDir, [string] $Token, [string] $VenvDir = "")
    Step "Installing the autostart service"
    $shortName = $ServiceName -replace "^seren-", ""
    $wrapper = Join-Path $ScriptDir "setup-$shortName-service.ps1"
    $core = Find-Upward "services\lib\setup-seren-service.ps1"
    if ((Test-Path $wrapper) -and $core -and (Test-Path $core)) {
        $venvArg = if ($VenvDir) { @{VenvDir = $VenvDir} } else { @{} }
        & $wrapper -Instance $Instance @venvArg
    } else {
        Warn "setup-$shortName-service.ps1 + setup-seren-service.ps1 not found."
        Warn "Keep the shared setup scripts together and run (elevated):"
        Warn "  .\setup-$shortName-service.ps1 -Instance '$Instance'"
    }
}
