<#
# ==========================================================================
#  seren-hippocampus-setup.ps1  -  one-shot SerenHippocampus installer (Windows)
#
#  The sleep cycle for SerenMemory, split out. Holds no store: it reads
#  short-terms from Memory, writes dockets to Memory, purges what was flagged.
#  Needs a running SerenMemory and the bearer that Memory requires.
#
#  USAGE
#    powershell -ExecutionPolicy Bypass -File .\seren-hippocampus-setup.ps1 -MemoryToken <memory's token>
#    powershell -ExecutionPolicy Bypass -File .\seren-hippocampus-setup.ps1 -Service -GenToken -MemoryToken ...
#    powershell -ExecutionPolicy Bypass -File .\seren-hippocampus-setup.ps1 -Local D:\serenDaemon\SerenCore\.dev-wheelhouse
#    powershell -ExecutionPolicy Bypass -File .\seren-hippocampus-setup.ps1 -ModelUrl ""   # mechanical mode
# ==========================================================================
#>
[CmdletBinding()]
param(
  [int]    $Port        = 7424,
  [string] $HippoHost   = "127.0.0.1",
  [string] $Token       = "",
  [switch] $GenToken,
  [string] $MemoryUrl   = "http://127.0.0.1:7420",
  [string] $MemoryToken = "",
  [string] $MemoryConfig = "",   # Memory's own config: its url AND its bearer, read from the file
  [string] $ModelUrl    = "http://localhost:8090/v1",
  # Bedtime (a sleep still waits for a brief): a wall-clock HH:MM, or every N
  # hours after the last sleep. And the draft cap: attempts per chain, 1-10.
  [string] $SleepAt     = "",
  [double] $SleepEvery  = 0,
  [int]    $MaxAttempts = 0,
  # The tend cycle: redraft denied operations on a timer (on, the default), or
  # only at sleep time - bedtime passing, or a new brief (off). Off is for a box
  # where the small model and the main model share memory. ValidateSet is what
  # -Describe reads to offer it as a choice.
  [ValidateSet("on", "off")]
  [string] $TendCycle   = "",
  [int]    $TendEvery   = 0,      # with the cycle on: seconds between redrafts (default 600)
  # The model the hippocampus starts when a sleep needs it: the server and the
  # .gguf it serves (both, or neither). Host and port come from -ModelUrl.
  [string] $ModelServer = "",
  [string] $ModelPath   = "",
  [string] $ModelArgs   = "",
  # How long a started model stays up after its last call before the hippocampus
  # stops it (default 300s; a review and a redraft reuse it).
  [int]    $KeepWarm    = 0,
  # The cap on one answer from the small model (default 2000). Too low and
  # answers are cut off mid-operation; keep it under the server's context.
  [int]    $ModelMaxTokens = 0,
  # Ask the model at bedtime and when drafts wait. ValidateSet is what
  # Starwright reads to offer a dropdown (-Describe's `choices`).
  [ValidateSet("script", "endpoint", "off")]
  [string] $Ripple        = "",
  [string] $RippleCommand = "",
  [string] $RippleUrl     = "",
  # The endpoint's bearer: the model box's Observatory token.
  [string] $RippleToken   = "",
  # Whose account a script ripple runs as. Default: you, the person running
  # this - a LocalSystem service borrows your logged-on session.
  [string] $RippleRunAs   = "",
  # The message goes on stdin, not as {message}: for `ssh desktop claude -p`
  # when there is neither Lodestar nor an Observatory.
  [switch] $RippleStdin,
  # Turn on the voice card (opt in): a short text the main model writes about
  # itself, carried by every draft prompt. The model writes it (set_voice_card).
  [switch] $VoiceCard,
  # Wake Claude Code as the model: `claude -p` run in this project folder (where
  # its memory MCP servers are registered) with those servers' tools
  # pre-approved - read from ~/.claude.json. A script ripple; implies -Ripple script.
  [string] $RippleClaude  = "",
  [string] $Wheel       = "",
  [string] $Local       = "",
  [string] $Ref         = "",
  [string] $Repo        = "",
  [string] $RepoDir     = "",
  [switch] $Pypi,
  [switch] $Mcp,        # [mcp] extra: the sleep's tools at /mcp for the main model
  # Register with Claude Code at user scope (every folder) as <instance>-hippocampus; the bearer
  # is read from this config when Claude connects. Implies -Mcp.
  [switch] $ClaudeMcp,
  [switch] $Corp,
  [switch] $NoUpdates,
  [string] $ServiceUser = "",
  [switch] $LocalSystem,
  [switch] $Service,
  [string] $Instance    = "",
  # Starwright's install root (~/seren/<install>): venvs, apps, stores, logs
  # under one folder, absolute paths. Empty = the old layout.
  [string] $Root        = "",
  [string] $VenvDir     = "",
  [switch] $Describe,
  [switch] $Json
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

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

$lib = Find-Upward "services\lib\seren-install-lib.ps1"
if (-not $lib) { Write-Host "ERROR: seren-install-lib.ps1 not found. Keep services/lib/ with shared scripts." -ForegroundColor Red; exit 1 }
. $lib

# -- Starwright contracts -----------------------------------------------------
if ($Describe) {
    $describeArgs = @{
        ScriptPath  = $PSCommandPath
        Name        = 'seren-hippocampus'
        Display     = 'Seren Hippocampus'
        Description = 'The sleep cycle for SerenMemory'
        Group       = 'brain'
        Package     = 'seren-hippocampus'
        Accent      = '#c9a0dc'
        DefaultHost = $HippoHost
        DefaultPort = $Port
        Requires    = @('seren-memory')
    }
    Get-SerenDescribe @describeArgs
    exit 0
}
if ($Json) { Enable-SerenJson }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\hippocampus" }
# Checked here so a typo fails the install with its reason instead of a
# service that quietly falls back to defaults.
if ($SleepAt -and $SleepAt -notmatch '^([01]?[0-9]|2[0-3]):[0-5][0-9]$') { Die "-SleepAt wants HH:MM (local time), got '$SleepAt'" }
if ($SleepEvery -ne 0 -and ($SleepEvery * 3600) -lt 600) { Die "-SleepEvery wants hours (at least 0.17, ten minutes), got '$SleepEvery'" }
if ($MaxAttempts -ne 0 -and ($MaxAttempts -lt 1 -or $MaxAttempts -gt 10)) { Die "-MaxAttempts wants 1-10, got '$MaxAttempts'" }
if ($TendEvery -ne 0 -and $TendEvery -lt 60) { Die "-TendEvery wants seconds, 60 or more, got '$TendEvery'" }
if ($TendCycle -eq "off" -and $TendEvery -ne 0) { Die "-TendEvery is how often the tend cycle redrafts; with -TendCycle off there is no timer" }
if ($Ripple -eq "endpoint" -and -not $RippleUrl) { Die "-Ripple endpoint needs -RippleUrl" }
if ($RippleClaude) {
    if (-not $Ripple) { $Ripple = "script" }
    if ($Ripple -ne "script") {
        Die "-RippleClaude wakes Claude Code on THIS box (a script ripple). For a model on another box, point -Ripple endpoint at its Observatory or Lodestar and give that card -RippleClaude"
    }
}
if ($ModelMaxTokens -ne 0 -and $ModelMaxTokens -lt 256) { Die "-ModelMaxTokens wants a number of tokens, 256 or more, got '$ModelMaxTokens'" }
if (($ModelServer -or $ModelPath) -and -not ($ModelServer -and $ModelPath)) {
    Die "-ModelServer and -ModelPath go together (the server and the .gguf it serves)"
}
if ($ClaudeMcp) { $Mcp = [switch]$true }
$layout  = Get-SerenLayout -Root $Root -Short "hippocampus" -Instance $Instance -VenvDir $VenvDir -AppDir "$env:USERPROFILE\seren-hippocampus"
$VenvDir = $layout.Venv
$AppDir  = $layout.App
$CfgPath = "$AppDir\seren-hippocampus.yaml"
$global:Instance = $Instance
if ($Instance -and $Port -eq 7424) { Warn "Instance '$Instance' uses default port 7424 - may collide." }
$memoryTokenLines = ""
if ($MemoryConfig) {
    $sib = Read-SerenSiblingConfig -Path $MemoryConfig
    if ($sib.Url) { $MemoryUrl = $sib.Url }
    if (-not $MemoryToken -and $sib.Token) { $MemoryToken = $sib.Token }
    $memoryTokenLines = Get-SerenSiblingTokenLines -Sib $sib -Indent "  "
    Ok "Memory: $MemoryUrl (from $MemoryConfig$(if ($memoryTokenLines) { ', with its bearer' } else { '' }))"
}
if ($MemoryToken) { $memoryTokenLines = "  bearer_token: `"$MemoryToken`"`n" }
if (-not $memoryTokenLines) { Warn "No -MemoryToken / -MemoryConfig: fine if Memory has no bearer; a Memory installed with -GenToken answers 401 to every sleep." }

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenHippocampus setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find Python -----------------------------------------------------------
$pyInfo = Find-Python
$global:pyInfo = $pyInfo
if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenHippocampus" }

# -- 2. resolve what to install ------------------------------------------------
# Precedence: -Wheel > -Local (dev wheelhouse) > -Repo/-Ref (GitHub) > -Pypi > local build (default)
$wheelSrc = $null
$cleanupWheel = $false
$pyExe = $pyInfo.Exe
$pyArgs = $pyInfo.Args
if ($Wheel) {
  if (-not (Test-Path $Wheel)) { Die "wheel not found: $Wheel" }
  $wheelSrc = (Resolve-Path $Wheel).Path
  Ok "Installing from local wheel: $(Split-Path $wheelSrc -Leaf)"
} elseif ($Local -or $Repo) {
  $wr = Resolve-Wheel -Wheel $Wheel -Local $Local -Ref $Ref -Repo $Repo -Package "seren-hippocampus"
  $wheelSrc = $wr.Src
  $cleanupWheel = $wr.Cleanup
} elseif ($Pypi) {
  $wheelSrc = "seren-hippocampus"
  Ok "Installing the latest seren-hippocampus from PyPI"
} else {
  Step "Building a wheel from the SerenHippocampus checkout"
  if (-not $RepoDir) { $RepoDir = Find-Upward "SerenHippocampus" }
  $pkgDir = Join-Path $RepoDir "SerenHippocampus"
  if (-not (Test-Path (Join-Path $pkgDir "pyproject.toml"))) {
    Die "SerenHippocampus checkout not found at $pkgDir. Use -RepoDir, -Wheel, -Local, -Pypi, or -Ref."
  }
  $buildVenv = Join-Path ([System.IO.Path]::GetTempPath()) "build-venv-hippocampus"
  & $pyExe $pyArgs -m venv $buildVenv
  & "$buildVenv\Scripts\pip" install -q --upgrade pip build
  Remove-Item -Force (Join-Path $pkgDir "dist\*.whl") -ErrorAction SilentlyContinue
  & "$buildVenv\Scripts\python" -m build --wheel $pkgDir
  Remove-Item -Recurse -Force $buildVenv -ErrorAction SilentlyContinue
  $wheelSrc = Get-ChildItem (Join-Path $pkgDir "dist\*.whl") | Select-Object -First 1
  if (-not $wheelSrc) { Die "build completed but no wheel in $pkgDir\dist\" }
  $wheelSrc = $wheelSrc.FullName
  Ok "Built $(Split-Path $wheelSrc -Leaf)"
}

# -- 3. venv + install ---------------------------------------------------------
$vpy = Create-Venv -VenvDir $VenvDir -PyExe $pyExe -PyArgs $pyArgs
$extras = Get-Extras-Suffix -Mcp:$Mcp -Corp:$Corp
Install-Package -Vpy $vpy -WheelSrc $wheelSrc -Extras $extras -Label "$(if ($Mcp) { ' (+ MCP SDK)' } else { '' })$(if ($Corp) { ' (+ truststore)' } else { '' })"
if ($cleanupWheel) { Remove-Item -Force $wheelSrc -ErrorAction SilentlyContinue }

# -- 4. sanity check ----------------------------------------------------------
Sanity-Check -Vpy $vpy -Module "seren_hippocampus"

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
$serverToken = if ($Token) { "  bearer_token: `"$Token`"`n" } else { "" }
$memoryToken = $memoryTokenLines
# The model lifecycle and the ripple, built before the config so an unset flag
# writes nothing (seren-keep-config.py then carries the old block forward).
# YAML single-quoted: backslashes stay literal, a ' is written ''.
function ConvertTo-SerenYamlQuoted([string] $v) { "'" + ($v -replace "'", "''") + "'" }
$lifecycleLines = ""
if ($ModelServer -and $ModelPath) {
    $lifecycleLines = "  lifecycle:`n" +
        "    # Started when a sleep needs it, stopped when idle: <server> -m <model_path>`n" +
        "    # --host/--port (from url) <server_args>.`n" +
        "    server: $(ConvertTo-SerenYamlQuoted $ModelServer)`n" +
        "    model_path: $(ConvertTo-SerenYamlQuoted $ModelPath)"
    if ($ModelArgs) { $lifecycleLines += "`n    server_args: $(ConvertTo-SerenYamlQuoted $ModelArgs)" }
    if ($KeepWarm -gt 0) { $lifecycleLines += "`n    keep_warm_seconds: $KeepWarm" }
}
$rippleLines = ""
switch ($Ripple) {
    "off"      { $rippleLines = "`nripple:`n  type: `"`"                  # off; -Ripple script|endpoint turns it back on" }
    "script"   {
        $cmd = if ($RippleCommand) { $RippleCommand } else { 'claude -p "{message}"' }
        # Inferred at setup (Chad, 28 Sept 2026): the person running the install
        # is whose login the command needs.
        $who = if ($RippleRunAs) { $RippleRunAs } else { $env:USERNAME }
        if ($RippleClaude) {
            # Claude Code, read off this box: run in the project, memory tools
            # pre-approved (seren-claude-ripple.py prints the two yaml lines).
            $claudeLines = Get-SerenClaudeRippleLines -Vpy $vpy -Dir $RippleClaude -Indent 2 -Who $who
            $rippleLines = "`nripple:`n  # At bedtime and when drafts wait, the hippocampus wakes Claude Code.`n  type: script`n$claudeLines`n  run_as: $(ConvertTo-SerenYamlQuoted $who)"
        } else {
            $rippleLines = "`nripple:`n  # At bedtime and when drafts wait, the hippocampus asks the model.`n  type: script`n  command: $(ConvertTo-SerenYamlQuoted $cmd)`n  run_as: $(ConvertTo-SerenYamlQuoted $who)"
        }
        if ($RippleStdin) { $rippleLines += "`n  stdin: true" }
    }
    "endpoint" {
        # The model lives on another box: its Observatory receives the ripple.
        $rippleLines = "`nripple:`n  type: endpoint`n  url: $(ConvertTo-SerenYamlQuoted $RippleUrl)"
        if ($RippleToken) { $rippleLines += "`n  bearer_token: $(ConvertTo-SerenYamlQuoted $RippleToken)" }
    }
}
$storePath = if ($layout.Data) { "'$($layout.Data)\state.json'" } else { "~/.seren-hippocampus$Instance/state.json" }
@"
# SerenHippocampus config - generated by seren-hippocampus-setup.ps1
# Full reference: see seren-hippocampus.yaml.sample in the repo.
server:
  host: $HippoHost
  port: $Port
$serverToken
memory:
  url: $MemoryUrl
$memoryToken
model:
  url: "$ModelUrl"
$(if ($ModelMaxTokens -gt 0) { "  max_tokens: $ModelMaxTokens" } else { '  # max_tokens: 2000            # the cap on one answer; too low and answers are cut off' })
$lifecycleLines

sleep:
  mode: thread
  state_path: $storePath
  # BEDTIME, not a timer: a sleep fires whenever the main model has left a
  # brief, any hour. Bedtime is when the hippocampus starts counting checks
  # that find none and, after enough, asks for one. Either a wall-clock time
  # (local HH:MM)...
$(if ($SleepAt) { "  at: `"$SleepAt`"" } else { '  # at: "03:30"' })
  # ...or every N hours after the last sleep (the default, ~20h: not 24, so it drifts through the day).
$(if ($SleepEvery -gt 0) { "  interval_seconds: $([int]($SleepEvery * 3600))" } else { '  # interval_seconds: 72000' })
  # The draft cap: attempts per chain before the last is terminal (the reviewer
  # may then edit on approve; a denial ends the chain). 1-10.
$(if ($MaxAttempts -gt 0) { "  max_attempts: $MaxAttempts" } else { '  # max_attempts: 3' })
  # The tend cycle: redrafting what the reviewer denied starts the small model.
  # true = on a timer (tend_interval_seconds). false = only at sleep time
  # (bedtime passing, or a new brief) - for a box where the small model and the
  # main model share memory.
$(if ($TendCycle) { "  tend_cycle: $(if ($TendCycle -eq 'off') { 'false' } else { 'true' })" } else { '  # tend_cycle: true' })
$(if ($TendEvery -gt 0) { "  tend_interval_seconds: $TendEvery" } else { '  # tend_interval_seconds: 600' })
"@ | Write-SerenTextFile -Path $CfgPath
if ($rippleLines) { $rippleLines | Add-SerenTextFile -Path $CfgPath }
# The voice card is opt in, and the model writes it; the config only turns it on.
if ($VoiceCard) { "`nvoice:`n  # The voice card: the model writes it (set_voice_card); every version is kept.`n  enabled: true" | Add-SerenTextFile -Path $CfgPath }
Ok "Config written"

if ($NoUpdates) {
    @"

# ── Update checking ───────────────────────────────────────────────────
# Turned OFF at install time by -NoUpdates. Flip to true to re-enable, or set
# SEREN_HIPPOCAMPUS_UPDATES_ENABLED=true in the service environment.
updates:
  enabled: false
"@ | Add-SerenTextFile -Path $CfgPath
    Ok "Update checking disabled in config"
}

# -- 5b. launcher -----------------------------------------------------------
$launcher = Write-Launcher -AppDir $AppDir -ServiceName "seren-hippocampus" -Vpy $vpy -Module "seren_hippocampus" -CfgPath $CfgPath

# -- 6. optional autostart ----------------------------------------------------
if ($Service) { Setup-Autostart -ScriptDir $ScriptDir -ServiceName "seren-hippocampus" -AppDir $AppDir -Token $Token -VenvDir $VenvDir -ServiceUser $ServiceUser -LocalSystem:$LocalSystem }

# -- done -------------------------------------------------------------------
$connectHost = if ($HippoHost -eq "0.0.0.0") { "127.0.0.1" } else { $HippoHost }
if ($ClaudeMcp) { Register-SerenClaudeMcp -Short "hippocampus" -Vpy $vpy -AppDir $AppDir -CfgPath $CfgPath -Url "http://${connectHost}:$Port/mcp" -Instance $Instance }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenHippocampus is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) { Write-Host "  Start it:        $launcher" -ForegroundColor Blue }
Write-Host "  Health:          http://${connectHost}:$Port/health" -ForegroundColor Blue
Write-Host "  Status:          http://${connectHost}:$Port/status" -ForegroundColor Blue
Write-Host "  Sleep now:       POST http://${connectHost}:$Port/sleep" -ForegroundColor Blue
Write-Host "  Memory:          $MemoryUrl" -ForegroundColor Blue
if ($ModelUrl) { Write-Host "  Model:           $ModelUrl" -ForegroundColor Blue } else { Write-Host "  Model:           none - mechanical mode" -ForegroundColor Yellow }
if ($Token) { Write-Host "  Bearer token:    $Token" -ForegroundColor Yellow }
if ($Mcp)   { Write-Host "  MCP endpoint:    http://${connectHost}:$Port/mcp/" -ForegroundColor Blue }
Write-Host ""
Write-Host "  Sleeps every ~20h; tends denied operations every 5 minutes." -ForegroundColor Yellow
Write-Host "Rip it and win." -ForegroundColor Green

$doneArgs = @{
    Service     = 'seren-hippocampus'
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
$doneArgs["Bound"] = $PSBoundParameters
Send-SerenDone @doneArgs
