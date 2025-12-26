#requires -Version 5.1
Set-StrictMode -Version Latest

function Invoke-TaskInit {
  param([Parameter(Mandatory)]$Context)

  Write-LogInfo "=== Phase: Init ==="

  if (-not $Context.Secrets.OpsToken) {
    if ($Context.Options.LocalFile) {
      Write-LogWarn "OPS_TOKEN 未设置，但检测到 LocalFile 模式，跳过 token 检查"
    } else {
      throw "OPS_TOKEN 未设置（用于 Gitea/OPS）"
    }
  }

  try {
    Initialize-ApiTokenFromKeycloak -Context $Context
  } catch {
    if ($Context.Options.LocalFile) {
      Write-LogWarn "API Token 初始化失败，但检测到 LocalFile 模式，继续执行: $($_.Exception.Message)"
    } else {
      throw
    }
  }

  $issueId = if ($env:ISSUE_ID) { [int]$env:ISSUE_ID } elseif ($Context.Options.MockIssueId) { [int]$Context.Options.MockIssueId } else {
    if ($Context.Options.LocalFile) { 0 } else { throw "ISSUE_ID 未设置" }
  }

  $repoPath = if ($env:REPO_PATH) { $env:REPO_PATH } elseif ($Context.Options.MockRepoPath) { $Context.Options.MockRepoPath } else {
    if ($Context.Options.LocalFile) { "local/debug" } else { throw "REPO_PATH 未设置" }
  }

  $runId = "$issueId-" + (Get-Date -Format "yyyyMMddHHmmss")
  $workRoot = $Context.Settings.General.WorkRoot
  $repoRoot = $Context.RepoRoot

  $workDir = Join-Path $workRoot "$issueId\$runId"
  $outputDir = Join-Path $workDir $Context.Settings.General.OutputDirName
  $logsDir = Join-Path $workRoot $Context.Settings.General.LogsDir

  Ensure-Directory $workDir
  Ensure-Directory $outputDir
  Ensure-Directory $logsDir

  $Context.Run.IssueId = $issueId
  $Context.Run.RepoPath = $repoPath
  $Context.Run.RunId = $runId

  $Context.Paths.WorkDir = (Resolve-Path $workDir).Path
  $Context.Paths.OutputDir = (Resolve-Path $outputDir).Path
  $Context.Paths.LogsDir = (Resolve-Path $logsDir).Path

  # 对外暴露 env：兼容现有 CI
  Export-EnvironmentVariables -Variables @{
    ISSUE_ID   = $issueId
    REPO_PATH  = $repoPath
    RUN_ID     = $runId
    WORK_DIR   = $Context.Paths.WorkDir
    OUTPUT_DIR = $Context.Paths.OutputDir
    LOGS_DIR   = $Context.Paths.LogsDir
  }

  # 写 state（不含 token）
  Set-RunStateValue -State $Context.State -Key 'Init' -Value @{
    IssueId   = $issueId
    RepoPath  = $repoPath
    RunId     = $runId
    WorkDir   = $Context.Paths.WorkDir
    OutputDir = $Context.Paths.OutputDir
    LogsDir   = $Context.Paths.LogsDir
  }

  Write-LogOk "Init done."
}

Export-ModuleMember -Function Invoke-TaskInit
