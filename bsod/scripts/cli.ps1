#requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('All','Init','Fetch','Analyze','Persist','Publish','Finalize')]
  [string]$Phase = 'All',

  [string]$LocalFile,
  [string]$MockIssueId,
  [string]$MockRepoPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Import-Module (Join-Path $here 'core/Core.Bootstrap.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'pipeline/Pipeline.Orchestrator.psm1') -Force -DisableNameChecking

$ctx = New-PipelineContext -ScriptsRoot $here -SettingsPath (Join-Path $here 'settings.psd1') `
    -LocalFile $LocalFile -MockIssueId $MockIssueId -MockRepoPath $MockRepoPath

Invoke-Pipeline -Context $ctx -Phase $Phase
