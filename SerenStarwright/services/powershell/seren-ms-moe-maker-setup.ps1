<#
# ══════════════════════════════════════════════════════════════════════════
#  seren-ms-moe-maker-setup.ps1  -  one-shot Ms.MoE Maker installer (Windows)
#
#  Builds a targeted Mixture of Experts from a recipe. Not a coding model - a
#  coding model shaped like your stack.
#
#  THIS IS A CLI, NOT A SERVICE. No port, no daemon, no config file to write and
#  nothing to autostart. It lives here because this is where Starwright looks,
#  and Starwright is the right place to install it FROM.
#
#  AND MS-MOE-MAKER KNOWS NOTHING ABOUT SEREN. No seren-* dependency, no
#  assumption that Lodestar exists, no Seren in its own name. This installer is
#  the Seren side of an opt-in connection: the tool gains nothing by being
#  installed this way, and a stranger installs it with pip having never heard of
#  any of this. That asymmetry is deliberate - mandate is not ethos.
#
#  ON THE FILENAME. `seren-ms-moe-maker-setup.ps1`, not `-msmoemaker-`, because
#  verify-powershell.ps1 finds the bash counterpart by deriving it from the name
#  in -Describe: it strips a leading `seren-` and looks for
#  `seren-<rest>-setup.sh`. The name is `ms-moe-maker`, so the file has to spell
#  it the same way or the parity check reports "no bash counterpart".
#
#  USAGE
#    powershell -ExecutionPolicy Bypass -File .\seren-ms-moe-maker-setup.ps1
#    powershell -ExecutionPolicy Bypass -File .\seren-ms-moe-maker-setup.ps1 -Train
#    powershell -ExecutionPolicy Bypass -File .\seren-ms-moe-maker-setup.ps1 -Wheel .\ms_moe_maker-0.1.0-py3-none-any.whl
# ══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  # The [train] extra: torch, transformers, datasets. OFF by default on purpose -
  # `validate`, `describe` and `corpus` all work without it, which is what lets
  # you check a recipe on a laptop with no GPU and no CUDA.
  [switch] $Train,
  [string] $Wheel    = "",
  [string] $Ref      = "",
  [string] $Repo     = "",
  [string] $Instance = "",
  [string] $VenvDir  = "",
  # NO -Port AND NO -*Host, and their absence is the contract rather than an
  # omission: Get-SerenFlagsFromSelf reads THIS block to build the flags list,
  # so a parameter that does not exist is a flag Starwright will not offer. A
  # pipeline has nothing to bind to.
  [switch] $Describe,   # print metadata as JSON and exit (no side effects)
  [switch] $Json        # stream JSON Lines events on stdout; humans go to stderr
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
        # THE TOOL'S REAL NAME, not a seren- one. Starwright does not tie the
        # name to the installer's filename, so the grid can say what the thing
        # is actually called - and calling it `seren-msmoemaker` would be this
        # repo renaming somebody else's project on screen.
        Name        = 'ms-moe-maker'
        Display     = 'Ms.MoE Maker'
        Description = 'Build a mixture of experts from deliberately chosen specialists.'
        # A GROUP OF ITS OWN, and this is safe: GROUPS in seren-starwright.py
        # controls order and pretty names only, it is NOT an allowlist -
        # _ordered_groups renders an unknown group under its own heading.
        # seren-probe learned that by shipping group "infra" and not appearing.
        Group       = 'tools'
        Package     = 'ms-moe-maker'
        Accent      = '#c98b3e'
        # PORT 0 MEANS "there is no port". Get-SerenDescribe already defaults it
        # to 0, so the contract has had room for this and nothing used it yet.
        DefaultPort = 0
        # EXPLICIT, because the derivation is a family-wide allowlist of
        # mcp|corp|vector and structurally cannot know about `train`. Left to
        # derive, -Describe would advertise extras:[] while -Train quietly
        # worked, so Starwright would never render the checkbox.
        #
        # `dev` is NOT offered: it is for working ON ms-moe-maker, not with it.
        Extras      = @('train')
    }
    Get-SerenDescribe @describeArgs
    exit 0
}
if ($Json) { Enable-SerenJson }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\msmoemaker" }
$VenvDir = "$VenvDir$Instance"
$AppDir  = "$env:USERPROFILE\msMoEMaker$Instance"
$global:Instance = $Instance

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Ms.MoE Maker setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find Python (3.10-3.12) -----------------------------------------------
$pyInfo = Find-Python
$global:pyInfo = $pyInfo

if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/MsMoEMaker" }

# -- 2. resolve wheel ----------------------------------------------------------
$wr = Resolve-Wheel -Wheel $Wheel -Ref $Ref -Repo $Repo -Package "ms-moe-maker"

# -- 3. venv + install ---------------------------------------------------------
$vpy = Create-Venv -VenvDir $VenvDir -PyExe $pyInfo.Exe -PyArgs $pyInfo.Args
# Get-Extras-Suffix only knows the family allowlist (-Mcp/-Corp/-Vector), so the
# suffix is built here. Same reason Extras is passed explicitly above.
$extras = ""
if ($Train) { $extras = "[train]" }
Install-Package -Vpy $vpy -WheelSrc $wr.Src -Extras $extras -Label ""
if ($wr.Cleanup) { Remove-Item -Force $wr.Src -ErrorAction SilentlyContinue }

# -- 4. sanity check -----------------------------------------------------------
# WHAT IS INVARIANT for this package and nothing more: it imports, its card
# answers, and the console script exists. torch is NOT checked - a base install
# without it is the common and correct case, and a warning that fires on working
# software teaches people to ignore warnings.
Step "Sanity-checking the install"
$check = & $vpy -c @"
try:
    import ms_moe_maker
    from ms_moe_maker import DESCRIBE
except Exception as e:
    print('IMPORT_FAILED: %s' % e); raise SystemExit
missing = [k for k in ('name', 'commands', 'stages', 'requires') if k not in DESCRIBE]
print('DESCRIBE_INCOMPLETE: ' + ','.join(missing) if missing else 'OK')
"@ 2>&1
switch -Wildcard ($check) {
    "OK"                   { Ok "Package imports and --describe answers" }
    "DESCRIBE_INCOMPLETE*" { Warn "Installed but $check - a front-end reading the card will find gaps" }
    default                { Die "Install looks broken: $check" }
}

$cli = Join-Path $VenvDir "Scripts\ms-moe-maker.exe"
if (Test-Path $cli) {
    Ok "CLI at $cli"
} else {
    Die "the ms-moe-maker console script is missing from $VenvDir\Scripts - the wheel installed but its entry point did not"
}

# -- 5. NO CONFIG IS WRITTEN, deliberately -------------------------------------
# Every other installer in this folder writes a seren-*.yaml. This one must not.
#
# ms-moe-maker is configured by a RECIPE you wrote, plus an optional
# ~/.msmoe/defaults.yaml describing the box. Generating either from here would
# be Seren imposing configuration on a tool that does not know Seren exists -
# and a defaults file invented by an installer is a set of numbers nobody chose,
# which is exactly the shape that made `rungs:` a bug in seren-theatre.
#
# `ms-moe-maker init` writes a recipe the user then edits. That is the right
# moment for it: after they have seen the machine, not during an install.
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
Ok "Workspace at $AppDir (no config generated - see below)"

# -- 6. how seren-theatre finds it ---------------------------------------------
# The one genuinely Seren-shaped thing worth saying out loud. Theatre's
# [stagehand] extra forks this CLI, and WHICH install it forks is configuration
# on Theatre's side, not something this script should reach over and set.
Step "If you are pairing this with SerenTheatre"
Write-Host "  Point Theatre at this venv, in its seren-theatre.yaml:" -ForegroundColor Gray
Write-Host ""
Write-Host "  pipeline:" -ForegroundColor Blue
Write-Host "    venv: $VenvDir" -ForegroundColor Blue
Write-Host ""
Write-Host "  Theatre RAISES rather than falling back to PATH if that is wrong," -ForegroundColor Gray
Write-Host "  which is the point: a silent downgrade to a different install is" -ForegroundColor Gray
Write-Host "  how you end up watching one box and building on another." -ForegroundColor Gray

# -- done ---------------------------------------------------------------------
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Ms.MoE Maker is set up" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Describe it:     $cli --describe" -ForegroundColor Blue
Write-Host "  Start a recipe:  $cli init" -ForegroundColor Blue
Write-Host "  Check a recipe:  $cli validate recipe.yaml   (no GPU needed)" -ForegroundColor Blue
Write-Host "  Build:           $cli build recipe.yaml --json" -ForegroundColor Blue
if (-not $Train) {
  Write-Host "  Installed WITHOUT [train] - validate/describe/corpus work;" -ForegroundColor Yellow
  Write-Host "  building needs -Train (torch, transformers, datasets)." -ForegroundColor Yellow
}
Write-Host "Rip it and win." -ForegroundColor Green

# -- Starwright contract: structured completion event -------------------------
# Port 0 and the url derived from it are meaningless for a CLI. Emitted anyway,
# because Starwright's -Json consumer waits for a `done` event and an install
# that never sends one reads as an install that never finished. The honest fix
# is a `kind` in the describe contract so a front-end can tell a command from a
# service; filed rather than smuggled in here.
# SPLATTED, and the parameter is `Autostart` - NOT `InstallService`. Written
# from the lib's actual signature rather than from the bash script's variable
# name, which is what the first draft of this line did: `-InstallService $false`
# is a parameter that does not exist, and PowerShell would have thrown on the
# very last line of an otherwise successful install.
$doneArgs = @{
    Service     = 'ms-moe-maker'
    ConnectHost = '127.0.0.1'
    Port        = 0
    Autostart   = $false     # nothing to autostart; a CLI is not a daemon
    Token       = ""
    Mcp         = $false
    Corp        = $false
    Vector      = $false
    Venv        = $VenvDir
    Config      = ""         # deliberately none written; see section 5
}
Send-SerenDone @doneArgs
