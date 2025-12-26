#requires -Version 5.1
Set-StrictMode -Version Latest

function Detect-InputSourceFromIssue {
  param(
    [Parameter(Mandatory)]$Settings,
    [Parameter(Mandatory)]$IssueObject
  )
  $body = [string]($IssueObject.body)
  $method = $null
  $uid = $null

  $rx = $Settings.General.UploadMethodPattern
  if ($rx) {
    try {
      if ($body -match $rx) {
        if ($Matches['method']) { $method = $Matches['method'].Trim() }
        if ($Matches['uid']) { $uid = $Matches['uid'].Trim() }
      }
    } catch {
      Write-LogWarn "UploadMethodPattern 无效：$($_.Exception.Message)；改用兜底匹配"
    }
  }

  if (-not $method) {
    if ($body -match '(?i)(?:Upload\s*Method|上传方式)[:：]\s*(\S+)') { $method = $Matches[1].Trim() }
    elseif ($body -match '(?m)^\s*上传方式[:：]\s*(.+)$') { $method = (($Matches[1].Trim()) -split '[（(]')[0].Trim() }
  }
  if (-not $uid) {
    if ($body -match '(?i)UID[:：]?\s*([A-Za-z0-9]{6,64})') { $uid = $Matches[1].Trim() }
  }

  $norm = if ($method) { ($method -replace '\s+','') } else { '' }
  $isApi = $false
  if ($uid) { $isApi = $true }
  elseif ($norm) {
    foreach ($k in @('API上传','auto','platformlabs','程序自动上传','平台程序自动上传','自动上传')) {
      if ($norm -like "*$k*" -or ($method -like "*$k*")) { $isApi = $true; break }
    }
  }

  if ($isApi) {
    return @{ Type='restapi'; Method=($method ?? 'API上传'); Uid=$uid }
  }

  if ($norm -eq '附件上传') {
    return @{ Type='attachment'; Method=($method ?? '附件上传'); Uid='' }
  }

  Write-LogWarn "未知上传方式‘$method’，回退附件模式"
  return @{ Type='attachment'; Method=($method ?? '附件上传'); Uid='' }
}

Export-ModuleMember -Function Detect-InputSourceFromIssue
