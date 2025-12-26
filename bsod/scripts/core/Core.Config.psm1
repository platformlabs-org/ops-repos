#requires -Version 5.1
Set-StrictMode -Version Latest

function Import-PipelineSettings {
  param([Parameter(Mandatory)][string]$SettingsPath)
  if (-not (Test-Path $SettingsPath)) { throw "settings.psd1 不存在：$SettingsPath" }
  return (Import-PowerShellDataFile -Path $SettingsPath)
}

function Resolve-RepoRoot {
  param(
    [Parameter(Mandatory)][string]$StartDir,
    [Parameter(Mandatory)]$Settings
  )
  # 1) 明确提供 REPO_ROOT 则优先
  if ($env:REPO_ROOT -and (Test-Path $env:REPO_ROOT)) { return (Resolve-Path $env:REPO_ROOT).Path }

  # 2) 从 StartDir 向上找 marker（默认 .git）
  $marker = $Settings.Paths.RepoRootMarker
  if (-not $marker) { $marker = ".git" }

  $cur = (Resolve-Path $StartDir).Path
  while ($true) {
    if (Test-Path (Join-Path $cur $marker)) { return $cur }
    $parent = Split-Path -Parent $cur
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cur) { break }
    $cur = $parent
  }

  # 3) 兜底：StartDir 的父目录
  return (Resolve-Path (Split-Path -Parent $StartDir)).Path
}

Export-ModuleMember -Function Import-PipelineSettings,Resolve-RepoRoot
