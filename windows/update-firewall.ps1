Param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'autohub.config'),
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
try {
  $configFullPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).ProviderPath
} catch {
  $configFullPath = [System.IO.Path]::GetFullPath($ConfigPath)
}
$configDir = Split-Path -Parent $configFullPath
$listenerPort = if ($config.ContainsKey('LISTENER_PORT')) { [int]$config['LISTENER_PORT'] } else { 59876 }
if ($config.ContainsKey('ALLOW_LIST_PATH')) {
  $allowListPath = $config['ALLOW_LIST_PATH']
} else {
  $allowListPath = 'clients.allow'
}
if (-not [System.IO.Path]::IsPathRooted($allowListPath)) {
  $allowListPath = Join-Path $configDir $allowListPath
}
if (-not $RuleName) { $RuleName = "Autohub listener ${listenerPort}" }

if (-not (Test-Path -Path $allowListPath)) {
  Write-Error "Allow-list file not found: $allowListPath"
  exit 1
}

$addresses = Get-Content -Path $allowListPath | Where-Object { $_ -and $_ -notmatch '^#' } | ForEach-Object { $_.Trim() }
if ($addresses.Count -eq 0) {
  Write-Warning "Allow-list empty; firewall rule will block all sources"
}

Set-NetFirewallRule -DisplayName $RuleName -RemoteAddress $addresses | Out-Null
Write-Host "Updated $RuleName with $($addresses.Count) entries"
