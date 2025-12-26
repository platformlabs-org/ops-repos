#requires -Version 5.1
Set-StrictMode -Version Latest

function Get-BsodApiBase {
  param([Parameter(Mandatory)]$Settings)
  $base = Ensure-HttpsBase $Settings.Endpoints.ApiBaseUrl
  $prefix = $Settings.Endpoints.ApiApiPrefix
  if (-not $prefix) { $prefix = '/v1' }
  if (-not $prefix.StartsWith('/')) { $prefix = "/$prefix" }
  return "$base$prefix"
}

function Invoke-BsodApi {
  param(
    [Parameter(Mandatory)]$Settings,
    [Parameter(Mandatory)][string]$ApiToken,
    [Parameter(Mandatory)][ValidateSet('GET','POST','PATCH','PUT','DELETE')][string]$Method,
    [Parameter(Mandatory)][string]$Path,
    $Body = $null
  )
  $apiBase = Get-BsodApiBase -Settings $Settings
  $url = Ensure-HttpsUrl -Url "$apiBase$Path" -Base $Settings.Endpoints.ApiBaseUrl
  Invoke-HttpJson -Method $Method -Url $url -Headers (New-BearerHeaders -Token $ApiToken) -Body $Body `
    -TimeoutSec $Settings.General.HttpTimeoutSec -RetryCount $Settings.General.RetryCount -BackoffMs $Settings.General.RetryBackoffMs
}

function Get-BsodEventInfo {
  param([Parameter(Mandatory)]$Settings,[Parameter(Mandatory)][string]$ApiToken,[Parameter(Mandatory)][string]$Uid)
  $path = ($Settings.Endpoints.ApiPaths.BsodEventInfo -replace '\{uid\}',$Uid)
  Invoke-BsodApi -Settings $Settings -ApiToken $ApiToken -Method GET -Path $path
}

function Get-BsodEventFiles {
  param([Parameter(Mandatory)]$Settings,[Parameter(Mandatory)][string]$ApiToken,[Parameter(Mandatory)][string]$Uid)
  $path = ($Settings.Endpoints.ApiPaths.BsodEventFiles -replace '\{uid\}',$Uid)
  Invoke-BsodApi -Settings $Settings -ApiToken $ApiToken -Method GET -Path $path
}

function Download-BsodEventBestFile {
  param(
    [Parameter(Mandatory)]$Settings,
    [Parameter(Mandatory)][string]$ApiToken,
    [Parameter(Mandatory)][string]$Uid,
    [Parameter(Mandatory)][string]$OutDir
  )
  Ensure-Directory $OutDir

  $list = Get-BsodEventFiles -Settings $Settings -ApiToken $ApiToken -Uid $Uid
  if (-not $list -or -not $list.files -or $list.files.Count -eq 0) { throw "事件 $Uid 没有可下载的文件" }

  $pick = ($list.files | Where-Object { $_.original_name -match '\.zip$' } | Select-Object -First 1)
  if (-not $pick) { $pick = ($list.files | Where-Object { $_.original_name -match '\.7z$' } | Select-Object -First 1) }
  if (-not $pick) { $pick = ($list.files | Where-Object { $_.original_name -match '\.dmp$' } | Select-Object -First 1) }
  if (-not $pick) { $pick = ($list.files | Select-Object -First 1) }

  $fileId = [string]$pick.file_id
  if ([string]::IsNullOrWhiteSpace($fileId)) { throw "文件缺少 file_id" }

  $dlPath = (($Settings.Endpoints.ApiPaths.BsodEventFileDownload -replace '\{uid\}',$Uid) -replace '\{fileId\}',$fileId)
  $apiBase = Get-BsodApiBase -Settings $Settings
  $dlUrl = Ensure-HttpsUrl -Url "$apiBase$dlPath" -Base $Settings.Endpoints.ApiBaseUrl

  $name = Sanitize-FileName ([string]$pick.original_name)
  $outFile = Join-Path $OutDir $name

  $headers = New-BearerHeaders -Token $ApiToken -Accept '*/*'
  $expected = -1; try { if ($pick.size_bytes) { $expected = [int64]$pick.size_bytes } } catch {}
  $etag = $null; try { if ($pick.etag) { $etag = [string]$pick.etag } } catch {}

  $res = Download-FileResumable -Url $dlUrl -OutFile $outFile -Headers $headers -ExpectedSize $expected -ETag $etag
  Write-LogOk ("已下载：{0}（{1}，{2}，平均{3}；重试 {4}）" -f $res.Path,(Format-Size $res.Bytes),(Format-Duration $res.DurationSec),(Format-Speed $res.AvgBytesPerSec),$res.Attempts)
  return $res.Path
}

function Submit-BsodCanonicalReport {
  param(
    [Parameter(Mandatory)]$Settings,
    [Parameter(Mandatory)][string]$ApiToken,
    [Parameter(Mandatory)][string]$Uid,
    [Parameter(Mandatory)]$CanonicalReport
  )
  $path = ($Settings.Endpoints.ApiPaths.BsodReportUpsert -replace '\{uid\}',$Uid)
  # 统一上报：不再套 analysisData，直接发 CanonicalReport（后端会自动识别为 mode=new）
  $body = $CanonicalReport
  Invoke-BsodApi -Settings $Settings -ApiToken $ApiToken -Method POST -Path $path -Body $body
}

Export-ModuleMember -Function `
  Get-BsodApiBase,Get-BsodEventInfo,Get-BsodEventFiles,Download-BsodEventBestFile,Submit-BsodCanonicalReport
