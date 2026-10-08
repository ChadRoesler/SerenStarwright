<#
# ═══════════════════════════════════════════════════════════════════════════
#  seren-carabiner-setup.ps1  -  clip a model's harness onto Seren (Windows)
#
#  Twin of seren-carabiner-setup.sh. A carabiner (.kbh, SerenCarabiners) is
#  one standalone file per harness - claude.kbh for Claude Code - that answers
#  register, wake, bookmark, due and belay. This card puts one on THIS box,
#  the box the harness runs on, and configures it from what Starwright knows:
#  the Workbench (the one MCP door), Margin (the bookmark), the model's
#  working folder, the python that runs it from hooks.
#
#  Not a service: no venv, no port, no unit. Writes <into>\<carabiner>.kbh,
#  <into>\<carabiner>.yaml, <into>\framing.md, <into>\connections\*.yaml,
#  then runs register apply, bookmark install and belay.
#
#  USAGE
#    powershell -ExecutionPolicy Bypass -File .\seren-carabiner-setup.ps1 -Project D:\work -WorkbenchConfig C:\...\seren-workbench.yaml
#    powershell -ExecutionPolicy Bypass -File .\seren-carabiner-setup.ps1 -Kbh .\dist\claude.kbh -Into C:\Users\me\seren\kbh -Project D:\work
# ═══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [ValidateSet("claude")]
  [string]   $Carabiner       = "claude",
  # The folder the model works in; wakes run there (default: the home folder).
  [string]   $Project         = "",
  # The python that runs the .kbh from hooks and ripples (default: the one found here).
  [string]   $Python          = "",
  # Where the clip lives (default: <Root>\kbh, or ~\seren-kbh).
  [string]   $Into            = "",
  # The Workbench on another box: its url, dropped into the clip's yaml as a
  # ROUTE; the token comes from $env:SEREN_WORKBENCH_TOKEN, never a parameter.
  [string]   $WorkbenchUrl    = "",
  # Margin on another box, the same way; token from $env:SEREN_MARGIN_TOKEN.
  [string]   $MarginUrl       = "",
  # The Workbench ON THIS BOX: its own config, read for the route.
  [string]   $WorkbenchConfig = "",
  # Margin on this box, the same way.
  [string]   $MarginConfig    = "",
  # The host those services are reached at FROM THIS BOX, when their configs
  # came from another box (a config says 0.0.0.0; this box must dial a name).
  [string]   $CarabinerHost   = "",
  # Another server to register: NAME=FILE, the file already in <into>\connections.
  [string[]] $Server          = @(),
  [string]   $Kbh             = "",
  # A dev wheelhouse (seren-dev-publish) that holds <carabiner>.kbh beside the wheels.
  [string]   $Local           = "",
  [string]   $Ref             = "",
  [string]   $Repo            = "",
  [string]   $RepoDir         = "",
  [switch]   $DryWake,
  [string]   $Instance        = "",
  [string]   $Root            = "",
  [switch]   $Describe,
  [switch]   $Json
)

$ErrorActionPreference = "Stop"

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

if ($Describe) {
    Get-SerenDescribe -ScriptPath $PSCommandPath -Name 'seren-carabiner' -Display 'Seren Carabiner' `
        -Description "Clip a model's harness (Claude Code) onto Seren" -Group 'carabiners' -Package 'seren-carabiners' `
        -Accent '#2f6fb3' -DefaultHost '127.0.0.1' -DefaultPort 0 -Extras @() -Requires @() `
        -Recommends @('seren-workbench', 'seren-margin')
    exit 0
}
if ($Json) { Enable-SerenJson }
$global:Instance = $Instance

if (-not $Into) {
    if ($Root) { $Into = Join-Path $Root "kbh" } else { $Into = Join-Path $env:USERPROFILE "seren-kbh" }
}
if (-not $Project) { $Project = $env:USERPROFILE }
if (-not (Test-Path $Project -PathType Container)) { Die "-Project is not a folder: $Project" }
$Connections = Join-Path $Into "connections"
$CfgPath = Join-Path $Into "$Carabiner.yaml"

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Seren Carabiner setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. python -------------------------------------------------------------------
if (-not $Python) { $pyInfo = Find-Python; $Python = $pyInfo.Exe }
if (-not (Get-Command $Python -ErrorAction SilentlyContinue)) { Die "python not found: $Python" }
$Python = (Get-Command $Python).Source
Ok "Python: $Python"

# -- 2. the .kbh ------------------------------------------------------------------
Step "Resolving $Carabiner.kbh"
New-Item -ItemType Directory -Force -Path $Into, $Connections | Out-Null
$kbhSrc = ""
if ($Kbh) {
    if (-not (Test-Path $Kbh)) { Die ".kbh not found: $Kbh" }
    $kbhSrc = (Resolve-Path $Kbh).Path
    Ok "From file: $Kbh"
} elseif ($Local) {
    if ($Local -match '^https?://') {
        $kbhSrc = Join-Path ([System.IO.Path]::GetTempPath()) "$Carabiner.kbh"
        try { Invoke-WebRequest -Uri "$($Local.TrimEnd('/'))/$Carabiner.kbh" -OutFile $kbhSrc -UseBasicParsing } catch { Die "no $Carabiner.kbh at $Local" }
    } else {
        $kbhSrc = Join-Path ($Local -replace '^file://', '') "$Carabiner.kbh"
        if (-not (Test-Path $kbhSrc)) { Die "no $Carabiner.kbh in the wheelhouse $Local" }
    }
    Ok "From the dev wheelhouse at $Local"
} elseif ($Ref) {
    if (-not $Repo) { $Repo = "ChadRoesler/SerenCarabiners" }
    $url = "https://github.com/$Repo/releases/download/$Ref/$Carabiner.kbh"
    $kbhSrc = Join-Path ([System.IO.Path]::GetTempPath()) "$Carabiner.kbh"
    try { Invoke-WebRequest -Uri $url -OutFile $kbhSrc -UseBasicParsing } catch { Die "could not fetch $url" }
    Ok "From release $Ref of $Repo"
} else {
    if (-not $RepoDir) { $RepoDir = Find-Upward "SerenCarabiners" }
    if (-not $RepoDir -or -not (Test-Path (Join-Path $RepoDir "build.py"))) {
        Die "no SerenCarabiners checkout found (-RepoDir), and no -Kbh or -Ref given"
    }
    $buildOut = Join-Path ([System.IO.Path]::GetTempPath()) ("kbh-build-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $env:KBH_DIST = $buildOut
    try { Push-Location $RepoDir; & $Python build.py $Carabiner | Out-Null } finally { Pop-Location; Remove-Item Env:\KBH_DIST -ErrorAction SilentlyContinue }
    $kbhSrc = Join-Path $buildOut "$Carabiner.kbh"
    if (-not (Test-Path $kbhSrc)) { Die "building $Carabiner.kbh from $RepoDir failed" }
    Ok "Built from $RepoDir"
}
$KbhPath = Join-Path $Into "$Carabiner.kbh"
Copy-Item $kbhSrc $KbhPath -Force
& $Python $KbhPath list | Out-Null
if ($LASTEXITCODE -ne 0) { Die "$KbhPath does not run with $Python" }
Ok "Installed $KbhPath"

# -- 3. routes ------------------------------------------------------------------------
# A route is a url and a token written INTO the clip's yaml; nothing copied
# from the brain box. From -<Svc>Url (token in $env:SEREN_<SVC>_TOKEN, passed on
# to the clip as $env:KBH_TOKEN_<NAME>, environment to environment) or from a
# config on this box (-<Svc>Config, read for the route; -CarabinerHost names the
# host this box dials when the config says 0.0.0.0). A keyring-kept token
# cannot be a route, so that case stays a connection file.
function Resolve-Route([string] $Label, [string] $Name, [string] $Url, [string] $Cfg, [string] $TokenVar) {
    $token = ""; $pointer = ""
    if ($Url) {
        $token = [Environment]::GetEnvironmentVariable($TokenVar)
    } elseif ($Cfg) {
        $sib = Read-SerenSiblingConfig -Path $Cfg
        if (-not $sib.Url) { Warn "${Label}: $Cfg names no port"; return $null }
        $u = [uri] $sib.Url
        $hostName = if ($CarabinerHost) { $CarabinerHost } else { $u.Host }
        $Url = "http://${hostName}:$($u.Port)"
        $token = $sib.Token; $pointer = $sib.TokenEnv
        if (-not $token -and -not $pointer -and $sib.TokenKeyring) {
            $file = Join-Path $Connections "$Name.yaml"
            @("# A Seren connection file for $Label, written by seren-carabiner-setup from $Cfg", "server:", "  url: $Url",
              "  bearer_token_keyring: `"$($sib.TokenKeyring)`"") -join "`n" | Write-SerenTextFile -Path $file
            Ok "${Label}: $Url -> $file (its bearer is a keyring reference, so a file, not a route)"
            return @{ Value = "$Name.yaml"; Pointer = "" }
        }
    } else { return $null }
    $envName = "KBH_TOKEN_" + (($Name -replace '[^A-Za-z0-9]', '_').ToUpper())
    if ($token) { [Environment]::SetEnvironmentVariable($envName, $token) }
    $how = if ($token) { ", token embedded" } elseif ($pointer) { ", token from `$$pointer" } else { ", no token" }
    Ok "${Label}: $Url -> a route in the clip's yaml$how"
    return @{ Value = $Url; Pointer = $pointer }
}
Step "Routes"
$serverArgs = @()
$bookmarkArgs = @()
$prefix = if ($Instance) { "$Instance-" } else { "seren-" }
$wbName = "${prefix}workbench"
$wb = Resolve-Route "Workbench" $wbName $WorkbenchUrl $WorkbenchConfig "SEREN_WORKBENCH_TOKEN"
if ($wb) {
    $serverArgs += @("--server", "$wbName=$($wb.Value)")
    if ($wb.Pointer) { $serverArgs += @("--server-token-env", "$wbName=$($wb.Pointer)") }
} else {
    Warn "No Workbench (-WorkbenchUrl or -WorkbenchConfig): nothing is registered with the harness. Add one and re-run, or kbh $Carabiner register add later."
}
$mg = Resolve-Route "Margin" "bookmark" $MarginUrl $MarginConfig "SEREN_MARGIN_TOKEN"
if ($mg) {
    $bookmarkArgs = @("--bookmark", $mg.Value)
    if ($mg.Pointer) { $bookmarkArgs += @("--bookmark-token-env", $mg.Pointer) }
} else {
    Warn "No Margin (-MarginUrl or -MarginConfig): no bookmark at session start."
}
foreach ($s in $Server) {
    if ($s -notmatch "=") { Die "-Server wants NAME=FILE|URL: $s" }
    $v = $s.Split("=", 2)[1]
    if ($v -notmatch '^https?://' -and -not (Test-Path (Join-Path $Connections $v))) { Warn "-Server ${s}: the connection file does not exist yet" }
    $serverArgs += @("--server", $s)
}

# -- 4. install ------------------------------------------------------------------------
Step "kbh $Carabiner install"
& $Python $KbhPath $Carabiner install --into $Into --project $Project --python $Python --connections $Connections @serverArgs @bookmarkArgs
if ($LASTEXITCODE -ne 0) { Die "kbh $Carabiner install failed" }

# -- 5. register + bookmark ---------------------------------------------------------------
if ($serverArgs.Count -gt 0) {
    Step "kbh $Carabiner register apply"
    & $Python $KbhPath $Carabiner register apply --config $CfgPath
    if ($LASTEXITCODE -ne 0) { Warn "register apply did not finish; see above (the harness may not be installed for this account yet)" }
}
if ($bookmarkArgs.Count -gt 0) {
    Step "kbh $Carabiner bookmark install"
    & $Python $KbhPath $Carabiner bookmark install --config $CfgPath
    if ($LASTEXITCODE -ne 0) { Warn "bookmark install did not finish; see above" }
}

# -- 6. belay -----------------------------------------------------------------------------
Step "kbh $Carabiner belay"
$belayArgs = @("--config", $CfgPath)
if ($DryWake) { $belayArgs += "--dry-wake" }
& $Python $KbhPath $Carabiner belay @belayArgs
if ($LASTEXITCODE -eq 0) { Ok "climb on." } else { Warn "belay let go somewhere above - the clip is installed; fix what it names and run: $Python $KbhPath $Carabiner belay" }

# -- 7. done -------------------------------------------------------------------------------
Write-Host ""
Write-Host "  Seren Carabiner ($Carabiner) is clipped on." -ForegroundColor Green
Write-Host "  Clip:        $KbhPath"
Write-Host "  Config:      $CfgPath   (edit; a new .kbh never overwrites it)"
Write-Host "  Framing:     $(Join-Path $Into 'framing.md')   (the first words a woken session reads)"
Write-Host "  Connections: $Connections"
Send-SerenDone -Service 'seren-carabiner' -ConnectHost '127.0.0.1' -Port 0 -Autostart $false -Token '' `
    -Config $CfgPath -Bound $PSBoundParameters
