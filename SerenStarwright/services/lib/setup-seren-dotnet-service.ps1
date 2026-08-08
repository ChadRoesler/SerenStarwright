<#
══════════════════════════════════════════════════════════════════════════
  setup-seren-dotnet-service.ps1  -  GENERIC NSSM installer for any
  .NET-published seren service (SerenRuntimeHost, SerenMcpServer, ...).

  The MECHANISM half (.NET edition, Windows). Sibling to
  setup-seren-service.ps1 (the Python/NSSM edition). The Python core is
  untouched on purpose - .NET has no venv and no `-m module`, so two clean
  cores beat one overloaded one.

  What it does:
    1. (optional) publishes the project self-contained single-file for a RID
    2. deploys the publish output to a target dir (robocopy mirror)
    3. installs an NSSM service running AS YOU (so ~ and caches resolve to
       your profile, same hard-won reason as the Python core)
    4. waits for health on the service's OWN health path

  The wrapper supplies the launch shape (it differs per service - RuntimeHost
  takes a POSITIONAL config path, MCP is env-driven):
       -ExecName   the published binary filename (e.g. SerenRuntimeHost.exe)
       -ExecArgs   everything after the binary (positional config, flags)
       -EnvVars    hashtable of KEY=VALUE wired into the service env

  RUN IT: elevated PowerShell, as yourself.
══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]    $ServiceName,
  [Parameter(Mandatory)] [string]    $ExecName,     # e.g. SerenRuntimeHost.exe
  [Parameter(Mandatory)] [string]    $DeployDir,
  [string]    $ExecArgs       = "",
  [string]    $ProjectDir     = "",                 # required unless -NoPublish
  [string]    $PublishProfile = "SelfContained",
  [string]    $Rid            = "win-x64",
  [string]    $PublishDir     = "",                 # default <proj>/bin/Release/<tfm>/<rid>/publish
  [string]    $Tfm            = "net10.0",
  [switch]    $NoPublish,
  [switch]    $NoDeploy,
  [hashtable] $EnvVars        = @{},
  [string]    $Description    = "",
  [string]    $LogDir         = "$env:USERPROFILE\seren-logs",
  [int]       $HealthPort     = 0,
  [string]    $HealthPath     = "/health",
  [switch]    $NoHealthCheck,
  [string]    $DotnetBin      = "dotnet",
  [switch]    $RunAsLocalSystem,
  # Who the service logs on as. Blank means ".\<you>". The PASSWORD is
  # deliberately not a parameter - it arrives in $env:SEREN_SERVICE_PASSWORD.
  # Same contract as the Python core; see the identity section there for why.
  [string]    $ServiceUser    = ""
)

$ErrorActionPreference = "Stop"
function Step($m){ Write-Host "`n==> $m" -ForegroundColor Blue }
function Ok($m)  { Write-Host "  + $m"   -ForegroundColor Green }
function Warn($m){ Write-Host "  ! $m"   -ForegroundColor Yellow }
function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

if (-not $Description) { $Description = "$ServiceName - seren constellation service" }

# -- must be elevated --------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal]`
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Die "Run this in an ELEVATED PowerShell, but as your own user." }

# -- find nssm ---------------------------------------------------------------
$nssm = (Get-Command nssm -ErrorAction SilentlyContinue).Source
if (-not $nssm) { $nssm = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\nssm.exe" }
if (-not (Test-Path $nssm)) { Die "nssm not found. Install it: winget install nssm" }
Ok "nssm: $nssm"

# -- 1. publish --------------------------------------------------------------
if (-not $NoPublish) {
  if (-not $ProjectDir) { Die "-ProjectDir is required to publish (or pass -NoPublish)" }
  if (-not (Test-Path $ProjectDir)) { Die "project dir not found: $ProjectDir" }
  if (-not (Get-Command $DotnetBin -ErrorAction SilentlyContinue)) {
    Die "'$DotnetBin' not found. Install the .NET 10 SDK, or pass -NoPublish and deploy a prebuilt dir."
  }
  Step "Publishing $ServiceName ($PublishProfile, $Rid, self-contained single-file)"
  & $DotnetBin publish $ProjectDir -c Release -p:PublishProfile=$PublishProfile -r $Rid
  if ($LASTEXITCODE -ne 0) { Die "dotnet publish failed - see output above" }
  Ok "published"
  if (-not $PublishDir) { $PublishDir = Join-Path $ProjectDir "bin\Release\$Tfm\$Rid\publish" }
} else {
  Step "Skipping publish (-NoPublish)"
  if (-not $PublishDir) { $PublishDir = $DeployDir }
}

# -- 2. deploy ---------------------------------------------------------------
if (-not $NoDeploy) {
  if (-not (Test-Path $PublishDir)) { Die "publish output not found at $PublishDir (publish first, or fix -PublishDir)" }
  if (-not (Test-Path (Join-Path $PublishDir $ExecName))) {
    Warn "expected binary '$ExecName' not found in $PublishDir - check -ExecName"
  }
  Step "Deploying to $DeployDir"
  New-Item -ItemType Directory -Force -Path $DeployDir | Out-Null
  # robocopy /MIR mirrors (deletes extras). Exit codes 0-7 are success for
  # robocopy; 8+ is a real error. Don't let a "files copied" code (1) trip
  # $ErrorActionPreference.
  $rc = (Start-Process robocopy -ArgumentList "`"$PublishDir`" `"$DeployDir`" /MIR /NJH /NJS /NP /NDL" -Wait -PassThru -NoNewWindow).ExitCode
  if ($rc -ge 8) { Die "robocopy failed with exit code $rc" }
  Ok "deployed"
} else {
  Step "Skipping deploy (-NoDeploy); servicing $DeployDir as-is"
}

$ExecPath = Join-Path $DeployDir $ExecName
if (-not (Test-Path $ExecPath)) { Die "executable not found at $ExecPath after deploy" }
$ExecPath = (Resolve-Path $ExecPath).Path

# -- 3. install the service --------------------------------------------------
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$OutLog = Join-Path $LogDir "$ServiceName.out.log"
$ErrLog = Join-Path $LogDir "$ServiceName.err.log"

$exists = (& sc.exe query $ServiceName) 2>$null | Select-String "SERVICE_NAME"
if ($exists) {
  Step "Existing '$ServiceName' found - removing for a clean reinstall"
  & $nssm stop   $ServiceName 2>$null | Out-Null
  Start-Sleep -Seconds 2
  & $nssm remove $ServiceName confirm | Out-Null
  Start-Sleep -Seconds 2
  Ok "old service removed"
}

Step "Installing $ServiceName"
& $nssm install $ServiceName $ExecPath | Out-Null
if ($ExecArgs) { & $nssm set $ServiceName AppParameters $ExecArgs | Out-Null }
& $nssm set $ServiceName AppDirectory $DeployDir | Out-Null
& $nssm set $ServiceName AppStdout    $OutLog | Out-Null
& $nssm set $ServiceName AppStderr    $ErrLog | Out-Null
& $nssm set $ServiceName AppExit Default Restart | Out-Null
& $nssm set $ServiceName AppRestartDelay 3000 | Out-Null
& $nssm set $ServiceName Start SERVICE_AUTO_START | Out-Null
& $nssm set $ServiceName DisplayName $ServiceName | Out-Null
& $nssm set $ServiceName Description $Description | Out-Null

# Environment: NSSM wants a single newline-joined KEY=VALUE blob via AppEnvironmentExtra.
if ($EnvVars.Count -gt 0) {
  $envBlob = ($EnvVars.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"
  & $nssm set $ServiceName AppEnvironmentExtra $envBlob | Out-Null
  Ok "env: $($EnvVars.Keys -join ', ')"
}
Ok "configured"

# -- identity (run as you, same hard-won reason as the python core) -----------
# Credential resolution is deliberately IDENTICAL to setup-seren-service.ps1:
# LocalSystem, then the environment, then an interactive prompt, then a clear
# refusal. Two cores, one contract - a divergence here would mean a service
# installs from Starwright as a .NET job and hangs as a Python one, or vice
# versa, which is exactly the kind of asymmetry nobody debugs twice.
if ($RunAsLocalSystem) {
  Warn "Running as LocalSystem: '~' and caches resolve to the SYSTEM profile, not your user."
  & $nssm set $ServiceName ObjectName LocalSystem | Out-Null
  if ($LASTEXITCODE -ne 0) { Die "nssm could not set the service identity to LocalSystem." }
  Ok "service will run as LocalSystem"
} else {
  $account = $ServiceUser
  if (-not $account) { $account = ".\$env:USERNAME" }
  $plain = $env:SEREN_SERVICE_PASSWORD

  if (-not $plain) {
    # See the Python core for the full reasoning: IsOutputRedirected is true
    # exactly when a parent process is reading our stdout, which is exactly
    # when a prompt goes nowhere.
    $canPrompt = -not ([Console]::IsOutputRedirected -or $env:SEREN_NONINTERACTIVE)
    if ($canPrompt) {
      Step "Setting the service to run as you"
      Import-Module Microsoft.PowerShell.Security -ErrorAction SilentlyContinue
      $cred = Get-Credential -UserName $account `
                -Message "Your Windows password - stored as the service logon so it runs as you."
      if (-not $cred) { Die "No credential supplied - the service exists but has no logon identity." }
      $account = $cred.UserName
      $plain   = $cred.GetNetworkCredential().Password
    } else {
      Die ("Cannot prompt for a password from a non-interactive run, and none was supplied.`n" +
           "       Set SEREN_SERVICE_PASSWORD in the environment and pass -ServiceUser '$account',`n" +
           "       or pass -RunAsLocalSystem if this service reads nothing from under ~.")
    }
  } else {
    Step "Setting the service to run as $account (credential supplied by the environment)"
  }

  & $nssm set $ServiceName ObjectName "$account" "$plain" | Out-Null
  $rc = $LASTEXITCODE
  $plain = $null
  if ($rc -ne 0) {
    Die ("nssm could not set the logon identity for '$account'.`n" +
         "       Usually a wrong password, or the account lacks 'Log on as a service'.`n" +
         "       The service exists but will not start until this is fixed: nssm edit $ServiceName")
  }
  Ok "service will run as $account"
}

# -- start + health ----------------------------------------------------------
Step "Starting $ServiceName"
& $nssm start $ServiceName 2>$null | Out-Null
Start-Sleep -Seconds 6
if ($NoHealthCheck -or $HealthPort -eq 0) {
  Warn "Health check skipped. Eyeball it:"
  & sc.exe query $ServiceName | Select-String "STATE" | ForEach-Object { Write-Host "    $_" }
} else {
  try {
    $null = Invoke-WebRequest -Uri "http://127.0.0.1:$HealthPort$HealthPath" -TimeoutSec 10 -UseBasicParsing
    Ok "Up and healthy on http://127.0.0.1:$HealthPort$HealthPath"
  } catch {
    Warn "Health check didn't answer yet. Most recent stderr:"
    if (Test-Path $ErrLog) { Get-Content $ErrLog -Tail 25 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow } }
    & sc.exe query $ServiceName | Select-String "STATE" | ForEach-Object { Write-Host "    $_" }
  }
}

Write-Host "`nManage it:" -ForegroundColor Green
Write-Host "  nssm restart $ServiceName"
Write-Host "  Get-Content `"$ErrLog`" -Tail 40 -Wait"
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green
