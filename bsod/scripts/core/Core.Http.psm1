#requires -Version 5.1
Set-StrictMode -Version Latest

function Ensure-HttpsBase {
  param([Parameter(Mandatory)][string]$Base)
  $b = $Base.Trim()
  if ($b -notmatch '^\w+://') { $b = "https://$b" }
  $b = $b -replace '^(?i)http://', 'https://'
  try { $u = [Uri]$b } catch { throw "无效 BaseUrl：$b" }
  if ($u.Scheme -ne 'https') { throw "只允许 https：$b" }
  return $u.GetLeftPart([System.UriPartial]::Authority).TrimEnd('/')
}

function Ensure-HttpsUrl {
  param([Parameter(Mandatory)][string]$Url,[string]$Base)
  $u = $Url.Trim()
  if ($u -match '^(?i)https://') { return $u }
  if ($u -match '^(?i)http://') { return ($u -replace '^(?i)http://','https://') }
  if ($u.StartsWith('//')) { return 'https:' + $u }
  if ($u.StartsWith('/')) {
    if (-not $Base) { throw "相对路径缺少 Base" }
    $b = Ensure-HttpsBase $Base
    return "$b$u"
  }
  if ($u -notmatch '^\w+://') {
    if (-not $Base) { throw "相对路径缺少 Base" }
    $b = Ensure-HttpsBase $Base
    return "$b/$u".Replace('https:/','https://')
  }
  throw "不支持的 URL：$u"
}

function New-BearerHeaders {
  param([string]$Token,[string]$Accept='application/json')
  if ([string]::IsNullOrWhiteSpace($Token)) { return @{ Accept=$Accept } }
  return @{ Authorization="Bearer $Token"; Accept=$Accept }
}

function Start-BackoffSleep {
  param([int]$Attempt,[int]$BaseMs=800)
  $ms = [math]::Min(5000, $BaseMs * [math]::Pow(2, $Attempt-1))
  Start-Sleep -Milliseconds ([int]$ms)
}

function Invoke-HttpJson {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','PATCH','DELETE')][string]$Method,
    [Parameter(Mandatory)][string]$Url,
    [hashtable]$Headers,
    $Body,
    [int]$TimeoutSec = 120,
    [int]$RetryCount = 3,
    [int]$BackoffMs = 800
  )
  $attempt = 0
  while ($true) {
    $attempt++
    try {
      $p = @{
        Method     = $Method
        Uri        = $Url
        Headers    = ($Headers ?? @{})
        TimeoutSec = $TimeoutSec
        ErrorAction= 'Stop'
      }
      if ($null -ne $Body -and $Method -ne 'GET') {
        $p.ContentType = 'application/json'
        $p.Body        = ($Body | ConvertTo-Json -Depth 60 -Compress)
      }
      return (Invoke-RestMethod @p)
    } catch {
      if ($attempt -ge $RetryCount) { throw }
      Write-LogWarn "HTTP $Method 失败 ($attempt/$RetryCount)：$($_.Exception.Message)"
      Start-BackoffSleep -Attempt $attempt -BaseMs $BackoffMs
    }
  }
}

function New-HttpClient {
  param([hashtable]$Headers,[int]$TimeoutSec=3600)
  try {
    $handler = New-Object System.Net.Http.SocketsHttpHandler
    $handler.PooledConnectionLifetime = [TimeSpan]::FromMinutes(2)
  } catch {
    $handler = New-Object System.Net.Http.HttpClientHandler
  }
  $client = [System.Net.Http.HttpClient]::new($handler)
  $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  if ($Headers) {
    foreach ($k in $Headers.Keys) {
      $v = [string]$Headers[$k]
      if ($k -ieq 'Accept') { $client.DefaultRequestHeaders.Accept.ParseAdd($v) }
      else { [void]$client.DefaultRequestHeaders.TryAddWithoutValidation($k, $v) }
    }
  }
  return $client
}

function Download-FileResumable {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$OutFile,
    [hashtable]$Headers,
    [long]$ExpectedSize = -1,
    [string]$ETag = $null
  )

  $bytesDone = 0L
  if (Test-Path $OutFile) { try { $bytesDone = (Get-Item $OutFile).Length } catch {} }
  else { Ensure-Directory (Split-Path -Parent $OutFile) }

  $attempt = 0
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $useCi = Test-CiEnvironment

  while ($true) {
    $attempt++
    $client = $null
    $fs = $null
    $stream = $null

    try {
      $client = New-HttpClient -Headers $Headers -TimeoutSec 3600
      $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
      if ($bytesDone -gt 0) {
        $req.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new($bytesDone, $null)
        if ($ETag) { $req.Headers.TryAddWithoutValidation("If-Range", '"' + $ETag + '"') | Out-Null }
      }

      $resp = $client.SendAsync($req,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
      $code = [int]$resp.StatusCode
      if (-not $resp.IsSuccessStatusCode -and $code -ne 206) {
        $txt = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        throw "GET failed: $code $($resp.ReasonPhrase)`n$txt"
      }

      # 如果服务端忽略 Range：删除重下
      $serverIgnoredRange = $false
      try {
        $hasRangeReq = ($bytesDone -gt 0)
        $hasCR = ($resp.Content.Headers.ContentRange -ne $null)
        if ($hasRangeReq -and $code -eq 200 -and -not $hasCR) { $serverIgnoredRange = $true }
      } catch {}
      if ($serverIgnoredRange) {
        try { Remove-Item -Force $OutFile -ErrorAction SilentlyContinue } catch {}
        $bytesDone = 0L
        Write-LogWarn "服务器不支持断点续传，重新开始下载"
      }

      $fs = [System.IO.File]::Open(
        $OutFile,
        $(if ($bytesDone -gt 0) {[System.IO.FileMode]::Append} else {[System.IO.FileMode]::Create}),
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
      )
      $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()

      $buffer = New-Object byte[] 81920
      $lastTick = [DateTime]::UtcNow
      $lastBytes = $bytesDone

      while ($true) {
        $read = $stream.Read($buffer,0,$buffer.Length)
        if ($read -le 0) { break }
        $fs.Write($buffer,0,$read)
        $bytesDone += $read

        $now = [DateTime]::UtcNow
        if (($now - $lastTick).TotalMilliseconds -ge 600) {
          $instBps = ($bytesDone - $lastBytes) / [math]::Max(0.001, ($now - $lastTick).TotalSeconds)
          if ($useCi) {
            Write-Host ("{0} | 下载中 | {1} @ {2}" -f (Get-Date).ToString('HH:mm:ss'), (Format-Size $bytesDone), (Format-Speed $instBps))
          } else {
            Write-Progress -Activity "下载中" -Status ("{0} @ {1}" -f (Format-Size $bytesDone),(Format-Speed $instBps))
          }
          $lastTick = $now
          $lastBytes = $bytesDone
        }
      }

      if ($ExpectedSize -ge 0 -and $bytesDone -lt $ExpectedSize) {
        Write-LogWarn ("连接结束但未到预期大小（{0}/{1}），续传重试..." -f (Format-Size $bytesDone),(Format-Size $ExpectedSize))
        Start-Sleep -Seconds 2
        continue
      }
      break
    } catch {
      Write-LogWarn ("下载中断：{0}，已收 {1}，续传重试..." -f $_.Exception.Message,(Format-Size $bytesDone))
      Start-Sleep -Seconds 2
      continue
    } finally {
      try { if ($stream) { $stream.Dispose() } } catch {}
      try { if ($fs) { $fs.Flush(); $fs.Close() } } catch {}
      try { if ($client) { $client.Dispose() } } catch {}
    }
  }

  if (-not $useCi) { Write-Progress -Activity "下载中" -Completed }

  $elapsed = [int][math]::Round($sw.Elapsed.TotalSeconds)
  $avgBps = if ($elapsed -gt 0) { $bytesDone / $elapsed } else { 0 }
  return @{
    Path=$OutFile; Bytes=$bytesDone; DurationSec=$elapsed; AvgBytesPerSec=$avgBps; Attempts=$attempt
  }
}

Export-ModuleMember -Function `
  Ensure-HttpsBase,Ensure-HttpsUrl,New-BearerHeaders,Invoke-HttpJson,Download-FileResumable
