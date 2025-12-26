#requires -Version 5.1
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '..\providers\Provider.BsodApi.psm1') -Force -DisableNameChecking

function Invoke-TaskPersist {
  param([Parameter(Mandatory)]$Context)

  Write-LogInfo "=== Phase: Persist ==="

  $enable = [bool]$Context.Settings.Pipeline.Persist.Enable
  if (-not $enable) {
    Write-LogWarn "Persist 已禁用（settings.Pipeline.Persist.Enable = false）"
    return
  }

  if (-not $Context.Report) {
    Write-LogWarn "没有 CanonicalReport（请先 Phase=Analyze），Persist 跳过"
    return
  }

  $requireRest = [bool]$Context.Settings.Pipeline.Persist.RequireRestApi
  if ($requireRest -and $Context.Source.Type -ne 'restapi') {
    Write-LogWarn "非 REST API 模式，按配置 RequireRestApi=true 跳过后端上报"
    Set-RunStateValue -State $Context.State -Key 'Persist' -Value @{ Mode='skipped'; Reason='not restapi' }
    return
  }

  $uid = $Context.Report.uid
  if (-not $uid) { throw "CanonicalReport.uid 为空" }

  # 保存一份 payload 便于排查
  $payloadPath = Join-Path $Context.Paths.OutputDir ("payload_report_{0}.json" -f $uid)
  Write-JsonFile -Path $payloadPath -Object $Context.Report -Depth 80
  Write-LogInfo "Saved canonical report payload: $payloadPath"

  $resp = Submit-BsodCanonicalReport -Settings $Context.Settings -ApiToken $Context.Secrets.ApiToken -Uid $uid -CanonicalReport $Context.Report
  $Context.Persist.RecordId = $uid

  Set-RunStateValue -State $Context.State -Key 'Persist' -Value @{
    Mode='canonical'
    RecordId=$uid
    Response=$resp
  }

  Write-LogOk "Persist done. RecordId: $uid"
}

Export-ModuleMember -Function Invoke-TaskPersist
