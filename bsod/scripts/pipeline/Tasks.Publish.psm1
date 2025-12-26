#requires -Version 5.1
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '..\providers\Provider.Gitea.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\normalize\Normalize.Report.psm1') -Force -DisableNameChecking

function Invoke-TaskPublish {
  param([Parameter(Mandatory)]$Context)

  Write-LogInfo "=== Phase: Publish ==="

  $enable = [bool]$Context.Settings.Pipeline.Publish.Enable
  if (-not $enable) {
    Write-LogWarn "Publish 已禁用（settings.Pipeline.Publish.Enable = false）"
    return
  }

  if (-not $Context.Report) {
    Write-LogWarn "没有 CanonicalReport（请先 Phase=Analyze），Publish 跳过"
    return
  }

  $recordId = (Get-RunStateValue -State $Context.State -Key 'Persist.RecordId')
  $md = Build-IssueMarkdownReport -CanonicalReport $Context.Report -Context $Context -RecordId $recordId

  $maxLen = [int]$Context.Settings.General.CommentMaxLen
  if ($md.Length -gt $maxLen) {
    $md = $md.Substring(0, $maxLen - 1) + "`n`n…（已截断，完整见后端或输出目录）"
  }

  $resp = Add-GiteaIssueComment -Settings $Context.Settings -RepoPath $Context.Run.RepoPath -IssueId $Context.Run.IssueId -OpsToken $Context.Secrets.OpsToken -Markdown $md
  $commentId = if ($resp -and $resp.PSObject.Properties['id']) { [string]$resp.id } else { "" }

  # 标题后缀
  $suffix =
    if ($Context.Source.Type -eq 'restapi' -and $Context.Source.Uid) { $Context.Source.Uid }
    elseif ($Context.Artifacts.DumpPath) { Split-Path -Leaf $Context.Artifacts.DumpPath }
    else { "dump" }

  $title = Build-IssueTitle -CanonicalReport $Context.Report -Suffix $suffix -MaxLen ([int]$Context.Settings.General.TitleMaxLen)
  Update-GiteaIssueTitle -Settings $Context.Settings -RepoPath $Context.Run.RepoPath -IssueId $Context.Run.IssueId -OpsToken $Context.Secrets.OpsToken -Title $title | Out-Null

  Set-RunStateValue -State $Context.State -Key 'Publish' -Value @{ CommentId=$commentId; Title=$title }

  Export-EnvironmentVariables -Variables @{ COMMENT_ID = $commentId }

  Write-LogOk "Publish done. CommentId=$commentId"
}

Export-ModuleMember -Function Invoke-TaskPublish
