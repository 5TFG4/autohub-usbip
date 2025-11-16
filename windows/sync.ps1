Param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'autohub.config')
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
$piHost = if ($config.ContainsKey('PI_HOST')) { $config['PI_HOST'] } else { '192.168.1.2' }

function Get-ExportedBusIds {
  param([string]$Pi)
  $output = & usbip list -r $Pi
  $ids = @()
  foreach ($line in $output) {
    if ($line -match '^\s*-\s*busid\s+([0-9\.-]+)\s+\(') {
      $ids += $Matches[1]
    }
  }
  return $ids | Sort-Object -Unique
}

function Get-AttachedPorts {
  $ports = @()
  $output = & usbip port
  foreach ($line in $output) {
    if ($line -match '^Port\s+(\d+):\s+.*busid\s=\s([0-9\.-]+)') {
      $ports += [pscustomobject]@{ Port = $Matches[1]; BusId = $Matches[2] }
    }
  }
  return $ports
}

$serverBusIds = Get-ExportedBusIds -Pi $piHost
$attached = Get-AttachedPorts

if (-not $serverBusIds -or $serverBusIds.Count -eq 0) {
  Write-Warning "No exported bus IDs found on Pi $piHost; skipping detach to avoid dropping existing connections."
  return
}

foreach ($busId in $serverBusIds) {
  if (-not ($attached | Where-Object { $_.BusId -eq $busId })) {
    & usbip attach -r $piHost -b $busId | Out-Null
  }
}

foreach ($port in $attached) {
  if ($serverBusIds -notcontains $port.BusId) {
    & usbip detach -p $port.Port | Out-Null
  }
}
