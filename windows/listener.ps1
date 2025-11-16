Param(
  [string]$ConfigPath = "C:\\Autohub\\autohub.config"
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
$listenerPort = if ($config.ContainsKey('LISTENER_PORT')) { [int]$config['LISTENER_PORT'] } else { 59876 }
$listenerPath = if ($config.ContainsKey('LISTENER_PATH')) { $config['LISTENER_PATH'] } else { '/usb-event/' }
if (-not $listenerPath.StartsWith('/')) { $listenerPath = '/' + $listenerPath }
$prefix = if ($config.ContainsKey('LISTENER_PREFIX')) { $config['LISTENER_PREFIX'] } else { "http://+:${listenerPort}${listenerPath}" }
$allowListPath = if ($config.ContainsKey('ALLOW_LIST_PATH')) { $config['ALLOW_LIST_PATH'] } else { 'C:\\Autohub\\clients.allow' }

Add-Type -AssemblyName System.Net.HttpListener
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Clear()
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "[listener] config=$ConfigPath | prefix=$prefix | pi=$piHost"

function Get-AllowList {
  param([string]$Path)
  if (-not (Test-Path -Path $Path)) { return @() }
  return Get-Content -Path $Path | Where-Object { $_ -and $_ -notmatch '^#' } | ForEach-Object { $_.Trim() }
}

function Attach-Busid {
  param([string]$BusId, [string]$Pi)
  & usbip attach -r $Pi -b $BusId | Out-Null
}

function Detach-Busid {
  param([string]$BusId)
  $ports = (& usbip port) -join "`n"
  $regex = "^Port\s+(\d+):.*busid\s=\s$([regex]::Escape($BusId))"
  if ($ports -match $regex) {
    $portNum = $Matches[1]
    & usbip detach -p $portNum | Out-Null
  }
}

while ($true) {
  $ctx = $listener.GetContext()
  try {
    $allowed = Get-AllowList -Path $allowListPath
    $remote = $ctx.Request.RemoteEndPoint.Address.ToString()
    if ($allowed.Count -gt 0 -and ($allowed -notcontains $remote)) {
      $ctx.Response.StatusCode = 403
      $ctx.Response.Close()
      continue
    }

    if ($ctx.Request.HttpMethod -ne 'POST') {
      $ctx.Response.StatusCode = 405
      $ctx.Response.Close()
      continue
    }

    $reader = [System.IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
    $body = $reader.ReadToEnd()
    $reader.Close()

    $pairs = @{}
    foreach ($pair in ($body -split '&')) {
      if ($pair -match '=') {
        $k,$v = $pair -split '=',2
        $pairs[$k] = [System.Uri]::UnescapeDataString($v)
      }
    }

    $action = $pairs['action']
    $busId = $pairs['busid']

    switch ($action) {
      'add'    { if ($busId) { Attach-Busid -BusId $busId -Pi $piHost } }
      'remove' { if ($busId) { Detach-Busid -BusId $busId } }
      default  { }
    }

    $responseBytes = [System.Text.Encoding]::UTF8.GetBytes('ok')
    $ctx.Response.StatusCode = 200
    $ctx.Response.OutputStream.Write($responseBytes,0,$responseBytes.Length)
    $ctx.Response.Close()
  }
  catch {
    try {
      $ctx.Response.StatusCode = 500
      $ctx.Response.Close()
    } catch {}
  }
}
