<#
# ══════════════════════════════════════════════════════════════════════════
#  seren-corpus-callosum-setup.ps1  -  one-shot SCC installer (Windows)
#
#  Refactored to dot-source seren-install-lib.ps1 (shared installer library).
#  Identity lines + config are the only unique parts.
#
#  USAGE (same flags as before)
#    powershell -ExecutionPolicy Bypass -File .\seren-corpus-callosum-setup.ps1
#    powershell -ExecutionPolicy Bypass -File .\seren-corpus-callosum-setup.ps1 -Mcp
#    powershell -ExecutionPolicy Bypass -File .\seren-corpus-callosum-setup.ps1 -GenToken -Service
#    powershell -ExecutionPolicy Bypass -File .\seren-corpus-callosum-setup.ps1 -Corp
#    powershell -ExecutionPolicy Bypass -File .\seren-corpus-callosum-setup.ps1 -NoUpdates  # turn update checking off
# ══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]    $Port      = 7423,
  [string] $SccHost  = "127.0.0.1",   # NOT $Host
  [string] $Token     = "",
  [switch] $GenToken,
  [string] $Wheel     = "",
  [string] $Local     = "",
  [string] $Ref       = "",
  [string] $Repo      = "",
  [switch] $Service,
  [switch] $Mcp,
  [switch] $Corp,
  [switch] $NoUpdates,
  # -- service identity (only meaningful alongside -Service) -------------------
  # Forwarded to the NSSM wrapper. The password is NOT a parameter - it rides
  # in $env:SEREN_SERVICE_PASSWORD, because on Windows a command line is
  # readable by any other process.
  [string] $ServiceUser = "",
  [switch] $LocalSystem,
  # The stores it fans. A URL says where; a CONFIG PATH says where AND presents
  # that service's bearer, read from its own file - a token never crosses argv.
  [string] $MemoryUrl    = "http://127.0.0.1:7420",
  [string] $MemoryConfig = "",
  [string] $LociUrl      = "http://127.0.0.1:7422",
  [string] $LociConfig   = "",
  [string] $Instance  = "",
  [string] $VenvDir   = "",
  [switch] $Describe,   # print service metadata as JSON and exit (no side effects)
  [switch] $Json        # stream JSON Lines events on stdout; humans go to stderr
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

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

# -- source the shared installer library ---------------------------------------
$lib = Find-Upward "services\lib\seren-install-lib.ps1"
if (-not $lib) { Write-Host "ERROR: seren-install-lib.ps1 not found. Keep services/lib/ with shared scripts." -ForegroundColor Red; exit 1 }
. $lib


# -- Starwright contracts -----------------------------------------------------
# -Describe answers with ZERO side effects, so it runs before anything else.
if ($Describe) {
    $describeArgs = @{
        ScriptPath  = $PSCommandPath
        Name        = 'seren-corpus-callosum'
        Display     = 'Seren Corpus Callosum'
        Description = 'The bridge between Loci and Memory'
        Group       = 'brain'
        Package     = 'seren-corpus-callosum'
        Accent      = '#9d7cff'
        DefaultHost = $SccHost
        DefaultPort = $Port
        # Mirrors SVC_REQUIRES in seren-corpus-callosum-setup.sh. The config
        # written below is pre-wired to memory:7420 and loci:7422, so this
        # genuinely cannot work without both - installing it alone builds a
        # bridge to nothing.
        Requires    = @('seren-memory', 'seren-loci')
    }
    Get-SerenDescribe @describeArgs
    exit 0
}
if ($Json) { Enable-SerenJson }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\callosum" }
$VenvDir = "$VenvDir$Instance"
$AppDir  = "$env:USERPROFILE\seren-corpus-callosum$Instance"
$CfgPath = "$AppDir\seren-corpus-callosum.yaml"
$global:Instance = $Instance
if ($Instance -and $Port -eq 7423) {
  Warn "Instance '$Instance' uses default port 7423 - may collide."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenCorpusCallosum setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find Python (3.10+; no upper cap - SCC never pulls torch) ------------
$pyInfo = Find-Python -NoUpper
$global:pyInfo = $pyInfo

if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenCorpusCallosum" }

# -- 2. resolve wheel ----------------------------------------------------------
$wr = Resolve-Wheel -Wheel $Wheel -Local $Local -Ref $Ref -Repo $Repo -Package "seren-corpus-callosum"

# -- 3. venv + install ---------------------------------------------------------
$vpy = Create-Venv -VenvDir $VenvDir -PyExe $pyInfo.Exe -PyArgs $pyInfo.Args
$extras = Get-Extras-Suffix -Mcp:$Mcp -Corp:$Corp
Install-Package -Vpy $vpy -WheelSrc $wr.Src -Extras $extras -Label " (web stack$(if ($Mcp) { ' + MCP SDK' } else { '' })$(if ($Corp) { ' + truststore' } else { '' }))"
if ($wr.Cleanup) { Remove-Item -Force $wr.Src -ErrorAction SilentlyContinue }

# -- 4. sanity check (import; verify MCP extra if --Mcp) ----------------------
Step "Sanity-checking the install"
$wantMcp = if ($Mcp) { 1 } else { 0 }
$check = & $vpy -c @"
import sys
want_mcp = $wantMcp
try:
    import seren_corpus_callosum
except Exception as e:
    print(f'IMPORT_FAILED: {e}'); raise SystemExit
if want_mcp:
    try:
        import mcp
    except Exception:
        print('MCP_MISSING'); raise SystemExit
    print('OK_MCP')
else:
    print('OK')
"@
switch -Wildcard ($check) {
  "OK"     { Ok "Package imports cleanly" }
  "OK_MCP" { Ok "Package imports + the MCP SDK is present (/mcp surface will mount)" }
  "MCP_MISSING" { Die "Package installed but [mcp] extra didn't land. Re-run with -Mcp." }
  default  { Die "Install looks broken: $check" }
}

# -- 5. config --------------------------------------------------------------
Step "Writing config at $CfgPath"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if ($GenToken) { $Token = & $vpy -c "import secrets; print(secrets.token_urlsafe(32))" }
# A reinstall keeps the existing bearer unless -Token / -GenToken say otherwise.
if (-not $Token -and -not $GenToken) { $Token = Get-SerenReusedToken -Path $CfgPath }
if (Test-Path $CfgPath) {
  $bak = "$CfgPath.bak.$([int][double]::Parse((Get-Date -UFormat %s)))"
  Copy-Item $CfgPath $bak
  Warn "Existing config backed up to $(Split-Path $bak -Leaf)"
}
$memoryTokenLines = ""; $lociTokenLines = ""
if ($MemoryConfig) {
    $sib = Read-SerenSiblingConfig -Path $MemoryConfig
    if ($sib.Url) { $MemoryUrl = $sib.Url }
    $memoryTokenLines = Get-SerenSiblingTokenLines -Sib $sib -Indent "      "
    Ok "Memory: $MemoryUrl (from $MemoryConfig$(if ($memoryTokenLines) { ', with its bearer' } else { '' }))"
}
if ($LociConfig) {
    $sib = Read-SerenSiblingConfig -Path $LociConfig
    if ($sib.Url) { $LociUrl = $sib.Url }
    $lociTokenLines = Get-SerenSiblingTokenLines -Sib $sib -Indent "      "
    Ok "Loci: $LociUrl (from $LociConfig$(if ($lociTokenLines) { ', with its bearer' } else { '' }))"
}
$tlsBlock = if ($Corp) {
  "`ntls:`n  trust_system_store: true"
} else { "" }
@"
# SerenCorpusCallosum config - generated by seren-corpus-callosum-setup.ps1
# Full reference: see seren-corpus-callosum.yaml.sample in the repo.
server:
  host: $SccHost
  port: $Port
  bearer_token: "$Token"

federation:
  stores:
    - name: memory
      type: seren_memory
      url: $MemoryUrl
$memoryTokenLines    - name: loci
      type: seren_loci
      url: $LociUrl
$lociTokenLines$tlsBlock
"@ | Write-SerenTextFile -Path $CfgPath
Ok "Config written (fanning $MemoryUrl + $LociUrl)"

if ($NoUpdates) {
    # Update checking is ON by default across the Seren family: it asks the
    # package index whether a newer release exists and reports it on the info
    # route. It NEVER upgrades anything. -NoUpdates writes the off switch.
    @"

# ── Update checking ───────────────────────────────────────────────────
# Turned OFF at install time by -NoUpdates. Flip to true to re-enable, or set
# SEREN_<SERVICE>_UPDATES_ENABLED=true in the service environment.
updates:
  enabled: false
"@ | Add-SerenTextFile -Path $CfgPath
    Ok "Update checking disabled in config"
}

# -- 5b. launcher -----------------------------------------------------------
$launcher = Write-Launcher -AppDir $AppDir -ServiceName "seren-corpus-callosum" -Vpy $vpy -Module "seren_corpus_callosum" -CfgPath $CfgPath

# -- 6. optional autostart ----------------------------------------------------
if ($Service) { Setup-Autostart -ScriptDir $ScriptDir -ServiceName "seren-corpus-callosum" -AppDir $AppDir -Token $Token -VenvDir $VenvDir -ServiceUser $ServiceUser -LocalSystem:$LocalSystem }

# -- done -------------------------------------------------------------------
$connectHost = if ($SccHost -eq "0.0.0.0") { "127.0.0.1" } else { $SccHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenCorpusCallosum is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) {
  Write-Host "  Start it:        $launcher" -ForegroundColor Blue
}
Write-Host "  Fan/search:      POST http://${connectHost}:$Port/search" -ForegroundColor Blue
Write-Host "  Health:          http://${connectHost}:$Port/health" -ForegroundColor Blue
Write-Host "  VSCode plugin:   set endpoint to http://${connectHost}:$Port" -ForegroundColor Blue
if ($Token) { Write-Host "  Bearer token:    $Token" -ForegroundColor Yellow }
Write-Host ""
if ($Mcp)  { Write-Host "  MCP endpoint:    http://${connectHost}:$Port/mcp/ (tool: search)" -ForegroundColor Blue }
if ($Corp) { Write-Host "  TLS:             OS trust store" -ForegroundColor Blue }
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green

# -- Starwright contract: structured completion event -------------------------
# Human banner above, machine-readable twin here. No-op without -Json.
$doneArgs = @{
    Service     = 'seren-corpus-callosum'
    ConnectHost = $connectHost
    Port        = $Port
    Autostart   = ([bool] $Service)
    Token       = $Token
    Mcp         = ([bool] $Mcp)
    Corp        = ([bool] $Corp)
    Vector      = $false
    Venv        = $VenvDir
    Config      = $CfgPath
}
Send-SerenDone @doneArgs
