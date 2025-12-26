#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptsRoot = Split-Path -Parent $here

# tasks
Import-Module (Join-Path $scriptsRoot 'pipeline/Tasks.Init.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $scriptsRoot 'pipeline/Tasks.Fetch.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $scriptsRoot 'pipeline/Tasks.Analyze.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $scriptsRoot 'pipeline/Tasks.Persist.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $scriptsRoot 'pipeline/Tasks.Publish.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $scriptsRoot 'pipeline/Tasks.Finalize.psm1') -Force -DisableNameChecking

function New-PipelineContext {
  param(
    [Parameter(Mandatory)][string]$ScriptsRoot,
    [Parameter(Mandatory)][string]$SettingsPath,
    [string]$LocalFile,
    [string]$MockIssueId,
    [string]$MockRepoPath
  )

  $settings = Import-PipelineSettings -SettingsPath $SettingsPath
  $repoRoot = Resolve-RepoRoot -StartDir $ScriptsRoot -Settings $settings
  $statePath = Get-RunStatePath -ScriptsRoot $ScriptsRoot -Settings $settings
  $state = Load-RunState -StatePath $statePath

  return @{
    ScriptsRoot = $ScriptsRoot
    RepoRoot    = $repoRoot
    Settings    = $settings
    StatePath   = $statePath
    State       = $state

    Options = @{
      LocalFile = $LocalFile
      MockIssueId = $MockIssueId
      MockRepoPath = $MockRepoPath
    }

    Secrets = @{
      OpsToken = $env:OPS_TOKEN
      ApiToken = $null
    }


    Run = @{
      IssueId  = $null
      RepoPath = $null
      RunId    = $null
    }

    Paths = @{
      WorkDir   = $null
      OutputDir = $null
      LogsDir   = $null
    }

    Source = @{
      Type   = $null
      Method = $null
      Uid    = $null
    }

    Artifacts = @{
      DumpPath   = $null
      MsinfoDir  = $null
      AttachDir  = $null
      ExtractDir = $null
    }

    Report = $null   # CanonicalReport
    Persist = @{
      RecordId = $null
    }
  }
}

function Save-ContextState {
  param([Parameter(Mandatory)]$Context)

  Save-RunState -StatePath $Context.StatePath -State $Context.State
}

function Invoke-Pipeline {
  param(
    [Parameter(Mandatory)]$Context,
    [ValidateSet('All','Init','Fetch','Analyze','Persist','Publish','Finalize')]
    [string]$Phase
  )

  $phases = if ($Phase -eq 'All') { @('Init','Fetch','Analyze','Persist','Publish','Finalize') } else { @($Phase) }

  foreach ($p in $phases) {
    try {
      switch ($p) {
        'Init'     { Invoke-TaskInit     -Context $Context }
        'Fetch'    { Invoke-TaskFetch    -Context $Context }
        'Analyze'  { Invoke-TaskAnalyze  -Context $Context }
        'Persist'  { Invoke-TaskPersist  -Context $Context }
        'Publish'  { Invoke-TaskPublish  -Context $Context }
        'Finalize' { Invoke-TaskFinalize -Context $Context }
      }
      Save-ContextState -Context $Context
    } catch {
      Write-LogErr "❌ Phase [$p] 失败：$($_.Exception.Message)"
      throw
    }
  }
}

Export-ModuleMember -Function New-PipelineContext,Invoke-Pipeline
