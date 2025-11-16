Param(
  [string]$ConfigPath = "C:\\Autohub\\autohub.config",
  [string]$RuleName
)

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

$config = Import-AutohubConfig -Path $ConfigPath
$listenerPort = if ($config.ContainsKey('LISTENER_PORT')) { [int]$config['LISTENER_PORT'] } else { 59876 }
$allowListPath = if ($config.ContainsKey('ALLOW_LIST_PATH')) { $config['ALLOW_LIST_PATH'] } else { 'C:\\Autohub\\clients.allow' }
if (-not $RuleName) { $RuleName = "Autohub listener ${listenerPort}" }

if (-not (Test-Path -Path $allowListPath)) {
  Write-Error "Allow-list file not found: $allowListPath"
  exit 1
}

$addresses = Get-Content -Path $allowListPath | Where-Object { $_ -and $_ -notmatch '^#' } | ForEach-Object { $_.Trim() }
if ($addresses.Count -eq 0) {
  Write-Warning "Allow-list empty; firewall rule will block all sources"
}

Set-NetFirewallRule -DisplayName $RuleName -RemoteAddress ($addresses -join ",") | Out-Null
Write-Host "Updated $RuleName with $($addresses.Count) entries"
