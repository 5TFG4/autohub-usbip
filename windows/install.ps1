#Requires -RunAsAdministrator
[CmdletBinding()]
Param()

$ErrorActionPreference = 'Stop'

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$adminPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isAdmin = $adminPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Error 'This script must be run from an elevated PowerShell session (Run as administrator).'
  return
}

# ---- Pre-flight: ensure usbip.exe client is available ----
function Test-UsbipInstalled {
  try {
    $cmd = Get-Command usbip.exe -ErrorAction Stop
    Write-Host "[usbip] Found usbip.exe at: $($cmd.Source)"
    return $true
  } catch {
    return $false
  }
}

if (-not (Test-UsbipInstalled)) {
  Write-Host ''
  Write-Host '============================================' -ForegroundColor Yellow
  Write-Host '  usbip.exe not found. AutoHub cannot continue.' -ForegroundColor Yellow
  Write-Host '============================================' -ForegroundColor Yellow
  Write-Host ''
  Write-Host 'Please install the Windows USB/IP client (usbip-win2 0.9.7.3) and re-run install.ps1.' -ForegroundColor Yellow
  Write-Host ''
  Write-Host 'Quick install steps:'
  Write-Host '  1. Open this release page (clickable in PowerShell):'
  Write-Host '     https://github.com/vadimgrn/usbip-win2/releases/tag/V.0.9.7.3' -ForegroundColor Cyan
  Write-Host '  2. Download the Windows x64 installer (.exe) from the Assets section.'
  Write-Host '  3. Right-click the installer → "Run as administrator" and finish the wizard.'
  Write-Host '  4. Close and reopen an elevated PowerShell, then run:'
  Write-Host '       usbip.exe help'
  Write-Host '     Seeing the help text confirms the CLI is installed and on PATH.'
  Write-Host ''
  Write-Host 'After completing those steps, run:'
  Write-Host '  .\install.ps1' -ForegroundColor Green
  Write-Host ''

  return
}

function Import-AutohubConfig {
  param([string]$Path)
  $map = @{}
  if (-not (Test-Path -Path $Path)) { return $map }
  foreach ($line in Get-Content -Path $Path) {
    $trim = $line.Trim()
    if (-not $trim -or $trim.StartsWith('#')) { continue }
    $parts = $trim -split '=', 2
    if ($parts.Length -eq 2) {
      $map[$parts[0].Trim()] = $parts[1].Trim()
    }
  }
  return $map
}

function New-AutohubSyncTriggers {
  param([string]$UserId)

  $logonParams = @{}
  if ($UserId) { $logonParams['User'] = $UserId }
  $logonTrigger = New-ScheduledTaskTrigger -AtLogOn @logonParams

  # TASK_SESSION_UNLOCK = 8 per MSFT_TaskSessionStateChangeTrigger docs
  $stateChangeClass = Get-CimClass -Namespace 'root\Microsoft\Windows\TaskScheduler' -ClassName 'MSFT_TaskSessionStateChangeTrigger'
  $unlockTrigger = New-CimInstance -CimClass $stateChangeClass -Property @{
    Enabled     = $true
    StateChange = 8
  } -ClientOnly

  return @($logonTrigger, $unlockTrigger)
}

function Ensure-UrlAcl {
  param(
    [Parameter(Mandatory = $true)] [string] $Prefix,
    [Parameter(Mandatory = $true)] [string] $User
  )

  Write-Host "HTTP prefix: $Prefix"

  $deleteOutput = & netsh http delete urlacl url=$Prefix 2>&1
  $deleteCode = $LASTEXITCODE
  if ($deleteCode -eq 0) {
    Write-Host "Removed existing URLACL for prefix: $Prefix"
  } else {
    Write-Host 'No existing URLACL to remove (or delete failed benignly):'
    Write-Host "  netsh http delete urlacl url=$Prefix"
    Write-Host "  -> ExitCode=$deleteCode, Message: $deleteOutput"
  }

  $addOutput = & netsh http add urlacl url=$Prefix user="$User" 2>&1
  $addCode = $LASTEXITCODE
  if ($addCode -eq 0) {
    Write-Host "Configured URLACL for prefix: $Prefix."
    return
  }

  if ($addOutput -match '183' -or $addOutput -match 'already.*exists') {
    Write-Host "URLACL for prefix $Prefix already exists; keeping existing reservation."
    return
  }

  throw "Failed to add URLACL: $addOutput"
}

$root = $PSScriptRoot
$configPath = Join-Path $root 'autohub.config'
$clientsPath = Join-Path $root 'clients.allow'
Write-Host "Config path: $configPath"

$listenerScript = Join-Path $root 'listener.ps1'
$syncScript = Join-Path $root 'sync.ps1'
$updateFirewallScript = Join-Path $root 'update-firewall.ps1'

if (-not (Test-Path -Path $listenerScript)) { throw "listener.ps1 not found under $root" }
if (-not (Test-Path -Path $syncScript)) { throw "sync.ps1 not found under $root" }
if (-not (Test-Path -Path $updateFirewallScript)) { throw "update-firewall.ps1 not found under $root" }

try {
  $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
  Write-Host "Using pwsh.exe at: $pwsh"
} catch {
  throw 'PowerShell 7 (pwsh.exe) not found. Install it from https://aka.ms/powershell and re-run install.ps1.'
}

$filesEnsured = @()
  $action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
  $configSample = Join-Path $root 'autohub.config.sample'
  if (-not (Test-Path -Path $configSample)) { throw "autohub.config.sample missing under $root" }
  Copy-Item -LiteralPath $configSample -Destination $configPath
  $filesEnsured += 'autohub.config'
}
if (-not (Test-Path -Path $clientsPath)) {
  $clientsSample = Join-Path $root 'clients.allow.sample'
  if (-not (Test-Path -Path $clientsSample)) { throw "clients.allow.sample missing under $root" }
  Copy-Item -LiteralPath $clientsSample -Destination $clientsPath
  $filesEnsured += 'clients.allow'
}
if ($filesEnsured.Count -gt 0) {
  Write-Host "Created: $($filesEnsured -join ', ')."
}
Write-Host "Ensured autohub.config and clients.allow exist."

$config = Import-AutohubConfig -Path $configPath
$listenerPort = if ($config.ContainsKey('LISTENER_PORT')) { [int]$config['LISTENER_PORT'] } else { 59876 }
$listenerPath = if ($config.ContainsKey('LISTENER_PATH')) { $config['LISTENER_PATH'] } else { '/usb-event/' }
if (-not $listenerPath.StartsWith('/')) { $listenerPath = '/' + $listenerPath }
$prefix = "http://+:${listenerPort}${listenerPath}"

$userAccount = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { "$env:COMPUTERNAME\$env:USERNAME" }
Ensure-UrlAcl -Prefix $prefix -User $userAccount

$ruleName = "Autohub listener ${listenerPort}"
$existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if (-not $existingRule) {
  New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $listenerPort | Out-Null
}
Write-Host "Configured firewall rule: $ruleName."

& $updateFirewallScript -ConfigPath $configPath -RuleName $ruleName

function Register-AutohubTask {
  param(
    [string]$TaskName,
    [string]$ScriptPath,
    [string]$Description,
    [switch]$IncludeUnlockTrigger,
    [switch]$ForceReregister
  )
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($task -and $ForceReregister) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false | Out-Null
  } elseif ($task) {
    return $false
  }
  $arguments = "-NoProfile -File `"$ScriptPath`" -ConfigPath `"$configPath`""
  $action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
  $triggers = if ($IncludeUnlockTrigger) {
    New-AutohubSyncTriggers -UserId $userAccount
  } else {
    @(New-ScheduledTaskTrigger -AtLogOn -User $userAccount)
  }
  $principal = New-ScheduledTaskPrincipal -UserId $userAccount -LogonType Interactive
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal -Description $Description | Out-Null
  return $true
}

$registered = @()
if (Register-AutohubTask -TaskName 'Autohub Listener' -ScriptPath $listenerScript -Description 'Start the AutoHub listener at logon.') {
  $registered += 'Autohub Listener'
}
if (Register-AutohubTask -TaskName 'Autohub Sync On Logon' -ScriptPath $syncScript -Description 'Sync usbip ports with the Pi at logon and unlock.' -IncludeUnlockTrigger -ForceReregister) {
  $registered += 'Autohub Sync On Logon'
}
if ($registered.Count -gt 0) {
  Write-Host "Registered scheduled tasks: $($registered -join ', ')."
} else {
  Write-Host 'Scheduled tasks already in place: Autohub Listener, Autohub Sync On Logon.'
}

Write-Host 'Installation complete.'
