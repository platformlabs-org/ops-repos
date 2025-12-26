#requires -Version 5.1
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '..\analyzers\Analyzer.Kd.psm1')    -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\normalize\Normalize.Report.psm1') -Force -DisableNameChecking

function Resolve-UidForContext {
  param([Parameter(Mandatory)]$Context)

  # Source.Uid > state.Source.Uid > dump filename > random
  $uid = $Context.Source.Uid
  if (-not $uid) { $uid = Get-RunStateValue -State $Context.State -Key 'Source.Uid' }
  if (-not $uid -and $Context.Artifacts.DumpPath) {
    try { $uid = [System.IO.Path]::GetFileNameWithoutExtension($Context.Artifacts.DumpPath) } catch {}
  }
  if (-not $uid) { $uid = [guid]::NewGuid().ToString('N') }
  return $uid
}

function Invoke-TaskAnalyze {
  param([Parameter(Mandatory)]$Context)

  Write-LogInfo "=== Phase: Analyze ==="

  if (-not $Context.Artifacts.DumpPath) {
    $Context.Artifacts.DumpPath = Get-RunStateValue -State $Context.State -Key 'Fetch.Dump'
  }
  if (-not $Context.Artifacts.DumpPath) { throw "DumpPath 缺失（请先 Phase=Fetch）" }

  $uid = Resolve-UidForContext -Context $Context

  $canonical = New-CanonicalReport -Uid $uid -Context $Context

  $partials = @()
  foreach ($an in @($Context.Settings.Pipeline.Analyzers)) {
    switch ($an.ToLowerInvariant()) {
      'kd' {
        $partials += (Invoke-KdAnalyzer -Context $Context)
      }
      default {
        Write-LogWarn "未知分析器：$an（跳过）"
      }
    }
  }

  # 归一化并 merge：优先级=配置顺序（前者更权威）
  foreach ($p in $partials) {
    if ($p.reports -and $p.reports.verbose_raw) {
      $patch = Convert-KdPartialToCanonicalPatch -Partial $p
      Merge-HashtableDeep -Base $canonical -Patch $patch
      $canonical.meta.analyzer.ran += 'kd'
    }
  }

  $Context.Report = $canonical
  Set-RunStateValue -State $Context.State -Key 'Analyze' -Value @{
    Uid = $uid
    AnalyzersRan = @($canonical.meta.analyzer.ran)
  }

  Write-LogOk ("Analyze done. UID={0}; Ran={1}" -f $uid, (($canonical.meta.analyzer.ran | Select-Object -Unique) -join ','))
}

Export-ModuleMember -Function Invoke-TaskAnalyze
