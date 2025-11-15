Param(
  [string]$RuleName = "Autohub listener 59876",
  [string]$AllowListPath = "C:\\Autohub\\clients.allow"
)

if (-not (Test-Path -Path $AllowListPath)) {
  Write-Error "Allow-list file not found: $AllowListPath"
  exit 1
}

$addresses = Get-Content -Path $AllowListPath | Where-Object { $_ -and $_ -notmatch '^#' } | ForEach-Object { $_.Trim() }
if ($addresses.Count -eq 0) {
  Write-Warning "Allow-list empty; firewall rule will block all sources"
}

Set-NetFirewallRule -DisplayName $RuleName -RemoteAddress ($addresses -join ",") | Out-Null
Write-Host "Updated $RuleName with $($addresses.Count) entries"
