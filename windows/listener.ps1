Param(
  [string]$Pi = "192.168.1.2",
  [string]$Prefix = "http://+:59876/usb-event/",
  [string]$AllowListPath = "C:\\Autohub\\clients.allow"
)

Add-Type -AssemblyName System.Net.HttpListener
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Clear()
$listener.Prefixes.Add($Prefix)
$listener.Start()
Write-Host "[listener] listening on $Prefix for Pi $Pi"

function Get-AllowList {
  if (-not (Test-Path -Path $AllowListPath)) { return @() }
  return Get-Content -Path $AllowListPath | Where-Object { $_ -and $_ -notmatch '^#' } | ForEach-Object { $_.Trim() }
}

function Attach-Busid {
  param([string]$BusId)
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
    $allowed = Get-AllowList
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
      'add'    { if ($busId) { Attach-Busid -BusId $busId } }
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
