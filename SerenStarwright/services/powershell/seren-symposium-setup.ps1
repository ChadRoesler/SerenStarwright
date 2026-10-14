<#
# ══════════════════════════════════════════════════════════════════════════
#  seren-symposium-setup.ps1  -  one-shot SerenSymposium installer (Windows)
#
#  The desktop front door: one window, chat in the first tab and the other
#  services' own pages in the rest. A CLIENT, not a service - it serves its
#  own UI on 127.0.0.1, talks to Lodestar, and installs no autostart. A chat
#  is answered by a local model through Lodestar, or (voice: claude) by the
#  claude CLI on this box.
#
#  Lodestar: -LodestarConfig (Starwright hands over a sibling's config path;
#  url and bearer are read from it) or -LodestarUrl for one on another box,
#  its token from $env:SEREN_LODESTAR_TOKEN - never a parameter, because any
#  process can read a Windows command line. Neither: the config keeps the
#  Lodestar it had (or the default, 127.0.0.1:6361, on a first install).
#
#  USAGE
#    powershell -ExecutionPolicy Bypass -File .\seren-symposium-setup.ps1 -LodestarConfig C:\...\seren-lodestar.yaml
#    $env:SEREN_LODESTAR_TOKEN = "..."; powershell -ExecutionPolicy Bypass -File .\seren-symposium-setup.ps1 -LodestarUrl http://node-a:6361
#    powershell -ExecutionPolicy Bypass -File .\seren-symposium-setup.ps1 -Voice claude -ClaudeName alice -ClaudeTools "mcp__workbench__*"
#    powershell -ExecutionPolicy Bypass -File .\seren-symposium-setup.ps1 -Local D:\work\project\.dev-wheelhouse   # dev builds from seren-dev-publish.ps1
# ══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]    $Port           = 7426,
  # Loopback. Symposium has no inbound auth and holds the Lodestar bearer:
  # past loopback it refuses to start unless ui.allow_open_lan says so.
  [string] $SymposiumHost  = "127.0.0.1",
  # The Lodestar on THIS box: its own config, read for the url and the bearer.
  [string] $LodestarConfig = "",
  # A Lodestar on another box; its token from $env:SEREN_LODESTAR_TOKEN.
  [string] $LodestarUrl    = "",
  # Who answers in the starter project (a first install only; after that the
  # projects are yours and a reinstall keeps them).
  [ValidateSet("lodestar", "claude")]
  [string] $Voice          = "lodestar",
  # The claude voice: what its answers are signed as, the folder the CLI runs
  # in (which project settings and MCP servers it loads), and the tools it may
  # use without asking, comma-separated ("mcp__workbench__*"). Blank = keep
  # what the config has.
  [string] $ClaudeName     = "",
  [string] $ClaudeCwd      = "",
  [string] $ClaudeTools    = "",
  # No native window: Symposium serves its UI to a browser instead (headless
  # boxes, CI). Without it the [desktop] extra (pywebview) is installed.
  [switch] $NoWindow,
  [switch] $NoShortcut,
  [string] $Wheel          = "",
  [string] $Local          = "",
  [string] $Ref            = "",
  [string] $Repo           = "",
  [switch] $Corp,
  [switch] $NoUpdates,
  [string] $Instance       = "",
  # Starwright's install root (~/seren/<install>): venvs, apps, stores, logs
  # under one folder, absolute paths. Empty = the old layout.
  [string] $Root           = "",
  [string] $VenvDir        = "",
  [switch] $Describe,
  [switch] $Json
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

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

# -- source the shared installer library ---------------------------------------
$lib = Find-Upward "services\lib\seren-install-lib.ps1"
if (-not $lib) { Write-Host "ERROR: seren-install-lib.ps1 not found. Keep services/lib/ with shared scripts." -ForegroundColor Red; exit 1 }
. $lib

# -- Starwright contracts -----------------------------------------------------
if ($Describe) {
    $describeArgs = @{
        ScriptPath  = $PSCommandPath
        Name        = 'seren-symposium'
        Display     = 'Seren Symposium'
        Description = 'The desktop front door: chat, projects, the viewers'
        Group       = 'desktop'
        Package     = 'seren-symposium'
        Accent      = '#a3b18a'
        DefaultHost = $SymposiumHost
        DefaultPort = $Port
        # [desktop] is not a pick-list extra: it is on unless -NoWindow.
        Extras      = @('corp')
        Recommends  = @('seren-lodestar')
        # A Lodestar on another box presents a token; it rides in the
        # environment, never on a command line.
        Secrets     = @{ 'lodestar-token' = 'SEREN_LODESTAR_TOKEN' }
    }
    Get-SerenDescribe @describeArgs
    exit 0
}
if ($Json) { Enable-SerenJson }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\symposium" }
$layout  = Get-SerenLayout -Root $Root -Short "symposium" -Instance $Instance -VenvDir $VenvDir -AppDir "$env:USERPROFILE\seren-symposium"
$VenvDir = $layout.Venv
$AppDir  = $layout.App
$CfgPath = "$AppDir\seren-symposium.yaml"
$global:Instance = $Instance
if ($SymposiumHost -notin @("127.0.0.1", "localhost", "::1")) {
  Warn "-SymposiumHost $SymposiumHost is past loopback: Symposium will refuse to start unless ui.allow_open_lan is true in its config (it has no inbound auth)"
}
if ($Instance -and $Port -eq 7426) {
  Warn "Instance '$Instance' uses default port 7426 - may collide."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenSymposium setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find Python (3.10+) -----------------------------------------------------
$pyInfo = Find-Python
$global:pyInfo = $pyInfo

if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenSymposium" }

# -- 2. resolve wheel ----------------------------------------------------------
$wr = Resolve-Wheel -Wheel $Wheel -Local $Local -Ref $Ref -Repo $Repo -Package "seren-symposium"

# -- 3. venv + install ---------------------------------------------------------
$vpy = Create-Venv -VenvDir $VenvDir -PyExe $pyInfo.Exe -PyArgs $pyInfo.Args
$extraList = @()
if (-not $NoWindow) { $extraList += "desktop" }
if ($Corp)          { $extraList += "corp" }
$extras = if ($extraList.Count) { "[$($extraList -join ',')]" } else { "" }
Install-Package -Vpy $vpy -WheelSrc $wr.Src -Extras $extras -Label ""
if ($wr.Cleanup) { Remove-Item -Force $wr.Src -ErrorAction SilentlyContinue }

# -- 4. sanity check (import + the shell's page) -------------------------------
Sanity-Check -Vpy $vpy -Module "seren_symposium" -AssetRelPath "ui/index.html" -AssetLabel "shell"

# -- 5. config --------------------------------------------------------------
# Written whole, like every card's; what it leaves out on purpose - the
# Lodestar it was not told about, the claude settings it was not given, the
# projects - seren-keep-config.py (run by Write-Launcher) carries forward
# from the backup, so a reinstall never costs a project or a token.
Step "Writing config at $CfgPath"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
$firstInstall = -not (Test-Path $CfgPath)
if (-not $firstInstall) {
  $bak = "$CfgPath.bak.$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
  Copy-Item $CfgPath $bak; (Get-Item $bak).LastWriteTime = Get-Date   # its own time: Copy-Item keeps the config's, and keep-config reads a backup's age from it
  Warn "Existing config backed up to $(Split-Path $bak -Leaf)"
}

$lodestarBlock = ""
$lodestarUrlForViewer = ""
if ($LodestarConfig) {
  $sib = Read-SerenSiblingConfig -Path $LodestarConfig
  if ($sib.Url) {
    $lodestarBlock = "lodestar:`n  url: $($sib.Url)`n" + (Get-SerenSiblingTokenLines -Sib $sib)
    $lodestarUrlForViewer = $sib.Url
    Ok "Lodestar: $($sib.Url) (from its config)"
  }
} elseif ($LodestarUrl) {
  $lodestarBlock = "lodestar:`n  url: $LodestarUrl`n"
  if ($env:SEREN_LODESTAR_TOKEN) {
    $lodestarBlock += "  bearer_token: `"$($env:SEREN_LODESTAR_TOKEN)`"`n"
  } else {
    Warn "SEREN_LODESTAR_TOKEN is not set, so Symposium will call $LodestarUrl without a bearer (fine for an open Lodestar; in Starwright, Configure > lodestar-token)"
  }
  $lodestarUrlForViewer = $LodestarUrl.TrimEnd('/')
  Ok "Lodestar: $LodestarUrl"
} elseif ($firstInstall) {
  Warn "No -LodestarConfig or -LodestarUrl: Symposium will look for Lodestar at 127.0.0.1:6361"
}

$claudeBlock = ""
if ($ClaudeName)  { $claudeBlock += "  name: `"$ClaudeName`"`n" }
if ($ClaudeCwd)   { $claudeBlock += "  cwd: '$ClaudeCwd'`n" }
if ($ClaudeTools) {
  # -p has nobody to answer a permission prompt: with a list, the CLI asks
  # (and so refuses) for everything not on it.
  $tools = @($ClaudeTools -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $claudeBlock += "  permission_mode: `"default`"`n  allowed_tools: [" + (($tools | ForEach-Object { "`"$_`"" }) -join ", ") + "]`n"
}
if ($claudeBlock) { $claudeBlock = "claude:`n$claudeBlock" }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Warn "No claude CLI on this box's PATH: the claude voice will show as unavailable (install Claude Code to use it)"
}

$sessionsBlock = ""
if ($layout.Data) { $sessionsBlock = "sessions:`n  dir: '$($layout.Data)\sessions'`n" }

# The starter project, on a first install only. After that the projects are
# the operator's, and keep-config puts every one of them back.
$foldersBlock = ""
if ($firstInstall) {
  $foldersBlock = "folders:`n  - name: `"Main`"`n    voice: `"$Voice`"`n"
}

$viewerBlock = ""
if ($lodestarUrlForViewer) { $viewerBlock = "viewers:`n  cluster: `"$lodestarUrlForViewer/viewer`"`n" }

@"
# SerenSymposium config - generated by seren-symposium-setup.ps1
# Full reference: see seren-symposium.yaml.sample in the repo.
$lodestarBlock
ui:
  host: $SymposiumHost
  port: $Port
$(if ($Corp) { "tls:`n  trust_system_store: true`n" })
$sessionsBlock
$claudeBlock
$viewerBlock
$foldersBlock
"@ | Write-SerenTextFile -Path $CfgPath
Ok "Config written"

if ($NoUpdates) {
    @"

# ── Update checking ───────────────────────────────────────────────────
# Turned OFF at install time by -NoUpdates. Flip to true to re-enable, or set
# SEREN_SYMPOSIUM_UPDATES_ENABLED=true in the environment.
updates:
  enabled: false
"@ | Add-SerenTextFile -Path $CfgPath
    Ok "Update checking disabled in config"
}

# -- 5b. launcher -----------------------------------------------------------
$launcher = Write-Launcher -AppDir $AppDir -ServiceName "seren-symposium" -Vpy $vpy -Module "seren_symposium" -CfgPath $CfgPath
# Locked AFTER the launcher: keep-config (which it runs) may have put back a
# Lodestar bearer this run was never given, and a file holding one is a file
# only its owner reads, however the bearer got there.
if (Select-String -LiteralPath $CfgPath -Pattern '^\s+bearer_token:\s*"?[^"\s]' -Quiet) {
  Protect-SerenConfig -Path $CfgPath
}

# -- 6. a Start menu shortcut (the window, not a console) ---------------------
# pythonw: no console behind the window. Not an autostart - Symposium is
# something you open, not something that runs.
$shortcut = ""
if (-not $NoShortcut -and -not $NoWindow) {
  $pyw = Join-Path (Split-Path $vpy -Parent) "pythonw.exe"
  if (Test-Path $pyw) {
    $menu = Join-Path ([Environment]::GetFolderPath("Programs")) "Seren"
    New-Item -ItemType Directory -Force -Path $menu | Out-Null
    $label = "Seren Symposium"
    if ($Instance) { $label = "$label ($Instance)" }
    $shortcut = Join-Path $menu "$label.lnk"
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
    $lnk.TargetPath = $pyw
    $lnk.Arguments = "-m seren_symposium --config `"$CfgPath`""
    $lnk.WorkingDirectory = $AppDir
    $lnk.Description = "The Seren desktop front door"
    $lnk.Save()
    Ok "Start menu shortcut: $shortcut"
  } else {
    Warn "No pythonw.exe beside $vpy - no shortcut; use the launcher"
  }
}

# -- done -------------------------------------------------------------------
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenSymposium is set up ✓" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Open it:          $launcher" -ForegroundColor Blue
if ($shortcut) { Write-Host "  Or from Start:    Seren > $([System.IO.Path]::GetFileNameWithoutExtension($shortcut))" -ForegroundColor Blue }
if ($NoWindow) { Write-Host "  Then browse to:   http://127.0.0.1:$Port/" -ForegroundColor Blue }
Write-Host "  Config:           $CfgPath" -ForegroundColor Blue
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green

# -- Starwright contract: structured completion event -------------------------
$doneArgs = @{
    Service     = 'seren-symposium'
    ConnectHost = '127.0.0.1'
    Port        = $Port
    Autostart   = $false
    Token       = ""
    Corp        = ([bool] $Corp)
    Venv        = $VenvDir
    Config      = $CfgPath
}
$doneArgs["Bound"] = $PSBoundParameters
Send-SerenDone @doneArgs
