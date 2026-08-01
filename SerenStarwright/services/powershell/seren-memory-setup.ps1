<#
# ══════════════════════════════════════════════════════════════════════════
#  seren-memory-setup.ps1  -  one-shot SerenMemory installer (Windows)
#
#  Refactored to dot-source seren-install-lib.ps1 (shared installer library).
#  Identity lines + config are the only unique parts.
#
#  USAGE (same flags as before)
#    powershell -ExecutionPolicy Bypass -File .\seren-memory-setup.ps1
#    powershell -ExecutionPolicy Bypass -File .\seren-memory-setup.ps1 -GenToken -Service
#    powershell -ExecutionPolicy Bypass -File .\seren-memory-setup.ps1 -Wheel .\seren_memory-0.1.0-py3-none-any.whl
#    powershell -ExecutionPolicy Bypass -File .\seren-memory-setup.ps1 -Mcp -Corp
#    powershell -ExecutionPolicy Bypass -File .\seren-memory-setup.ps1 -Updates   # update checking
# ══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]    $Port       = 7420,
  [string] $MemoryHost = "127.0.0.1",
  [string] $Token      = "",
  [switch] $GenToken,
  [string] $Wheel      = "",
  [string] $Ref        = "",
  [string] $Repo       = "",
  [switch] $Service,
  [switch] $Mcp,
  [switch] $Corp,
  [switch] $Updates,
  [string] $Instance   = "",
  [string] $VenvDir    = "",
  [string] $LoggingDir = "",
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
        Name        = 'seren-memory'
        Display     = 'Seren Memory'
        Description = 'Episodic short, near, and long term memory'
        Group       = 'brain'
        Package     = 'seren-memory'
        Accent      = '#ff6e8a'
        DefaultHost = $MemoryHost
        DefaultPort = $Port
    }
    Get-SerenDescribe @describeArgs
    exit 0
}
if ($Json) { Enable-SerenJson }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\memory" }
$VenvDir = "$VenvDir$Instance"
$AppDir  = "$env:USERPROFILE\seren-memory$Instance"
$CfgPath = "$AppDir\seren-memory.yaml"
$global:Instance = $Instance
if ($Instance -and $Port -eq 7420) {
  Warn "Instance '$Instance' uses default port 7420 — may collide."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenMemory setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find Python (3.10-3.12; chromadb can't build on 3.13) -----------------
$pyInfo = Find-Python
$global:pyInfo = $pyInfo

if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenMemory" }

# -- 2. resolve wheel ----------------------------------------------------------
$wr = Resolve-Wheel -Wheel $Wheel -Ref $Ref -Repo $Repo -Package "seren-memory"

# -- 3. venv + install ---------------------------------------------------------
$vpy = Create-Venv -VenvDir $VenvDir -PyExe $pyInfo.Exe -PyArgs $pyInfo.Args
$extras = Get-Extras-Suffix -Mcp:$Mcp -Corp:$Corp -Updates:$Updates
Install-Package -Vpy $vpy -WheelSrc $wr.Src -Extras $extras -Label " (chromadb$(if ($Mcp) { ' + MCP SDK' } else { '' })$(if ($Corp) { ' + truststore' } else { '' }))"
if ($wr.Cleanup) { Remove-Item -Force $wr.Src -ErrorAction SilentlyContinue }

# -- 4. sanity check (import + viewer/halls.html) -----------------------------
Sanity-Check -Vpy $vpy -Module "seren_memory" -AssetRelPath "viewer/ui/body.html" -AssetLabel "viewer"

# -- 5. config --------------------------------------------------------------
Step "Writing config at $CfgPath"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if ($GenToken) { $Token = & $vpy -c "import secrets; print(secrets.token_urlsafe(32))" }
if (Test-Path $CfgPath) {
  $bak = "$CfgPath.bak.$([int][double]::Parse((Get-Date -UFormat %s)))"
  Copy-Item $CfgPath $bak
  Warn "Existing config backed up to $(Split-Path $bak -Leaf)"
}
$dbInstance = $Instance
@"
# SerenMemory config - generated by seren-memory-setup.ps1
# Full reference: see seren-memory.yaml.sample in the repo.
server:
  host: $MemoryHost
  port: $Port
  bearer_token: "$Token"

storage:
  persist_dir: ~/.seren-memory$dbInstance/chroma$(if ($Corp) {"`ntls:`n  trust_system_store: true"})
"@ | Set-Content -Path $CfgPath -Encoding UTF8
Ok "Config written"

# -- 5b. launcher -----------------------------------------------------------
$launcher = Write-Launcher -AppDir $AppDir -ServiceName "seren-memory" -Vpy $vpy -Module "seren_memory" -CfgPath $CfgPath

# -- 6. optional autostart ----------------------------------------------------
if ($Service) { Setup-Autostart -ScriptDir $ScriptDir -ServiceName "seren-memory" -AppDir $AppDir -Token $Token -VenvDir $VenvDir }

# -- done -------------------------------------------------------------------
$connectHost = if ($MemoryHost -eq "0.0.0.0") { "127.0.0.1" } else { $MemoryHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenMemory is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) {
  Write-Host "  Start it:        $launcher" -ForegroundColor Blue
}
Write-Host "  Viewer:          http://${connectHost}:$Port/viewer" -ForegroundColor Blue
Write-Host "  VSCode plugin:   set serenMemory.endpoint to http://${connectHost}:$Port" -ForegroundColor Blue
if ($Token) { Write-Host "  Bearer token:    $Token" -ForegroundColor Yellow }
if ($Mcp)   { Write-Host "  MCP endpoint:    http://${connectHost}:$Port/mcp/" -ForegroundColor Blue }
if ($Corp)  { Write-Host "  TLS:             OS trust store" -ForegroundColor Blue }
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green

# -- Starwright contract: structured completion event -------------------------
# Human banner above, machine-readable twin here. No-op without -Json.
$doneArgs = @{
    Service     = 'seren-memory'
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
