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

$filesEnsured = @()
if (-not (Test-Path -Path $configPath)) {
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
Write-Host "HTTP prefix: $prefix"

$userAccount = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { "$env:COMPUTERNAME\$env:USERNAME" }
$netshOutput = & netsh http add urlacl url=$prefix user="$userAccount" 2>&1
if ($LASTEXITCODE -ne 0) {
  $netshMessage = ($netshOutput | Out-String).Trim()
  if ($netshMessage -notmatch 'already.*(exists|registered)') {
    throw "Failed to add URLACL: $netshMessage"
  }
}
Write-Host "Configured URLACL for prefix: $prefix."

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
    [switch]$IncludeUnlockTrigger
  )
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($task) { return $false }
  $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$configPath`""
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
  $triggers = @()
  $triggers += New-ScheduledTaskTrigger -AtLogOn -User $userAccount
  if ($IncludeUnlockTrigger) {
    $triggers += New-ScheduledTaskTrigger -AtUnlock
  }
  $principal = New-ScheduledTaskPrincipal -UserId $userAccount -LogonType Interactive
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal -Description $Description | Out-Null
  return $true
}

$registered = @()
if (Register-AutohubTask -TaskName 'Autohub Listener' -ScriptPath $listenerScript -Description 'Start the AutoHub listener at logon.') {
  $registered += 'Autohub Listener'
}
if (Register-AutohubTask -TaskName 'Autohub Sync On Logon' -ScriptPath $syncScript -Description 'Sync usbip ports with the Pi at logon and unlock.' -IncludeUnlockTrigger) {
  $registered += 'Autohub Sync On Logon'
}
if ($registered.Count -gt 0) {
  Write-Host "Registered scheduled tasks: $($registered -join ', ')."
} else {
  Write-Host 'Scheduled tasks already in place: Autohub Listener, Autohub Sync On Logon.'
}

Write-Host 'Installation complete.'
