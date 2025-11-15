Param(
  [string]$Pi = "192.168.1.2"
)

function Get-ExportedBusIds {
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

$serverBusIds = Get-ExportedBusIds
$attached = Get-AttachedPorts

foreach ($busId in $serverBusIds) {
  if (-not ($attached | Where-Object { $_.BusId -eq $busId })) {
    & usbip attach -r $Pi -b $busId | Out-Null
  }
}

foreach ($port in $attached) {
  if ($serverBusIds -notcontains $port.BusId) {
    & usbip detach -p $port.Port | Out-Null
  }
}
