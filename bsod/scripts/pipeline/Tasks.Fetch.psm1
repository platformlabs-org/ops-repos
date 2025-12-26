#requires -Version 5.1
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '..\providers\Provider.Gitea.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\providers\Provider.BsodApi.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\providers\Provider.SourceDetect.psm1') -Force -DisableNameChecking

function Invoke-TaskFetch {
  param([Parameter(Mandatory)]$Context)

  Write-LogInfo "=== Phase: Fetch ==="

  $workDir = $Context.Paths.WorkDir
  if (-not $workDir) {
    $workDir = Get-RunStateValue -State $Context.State -Key 'Init.WorkDir'
    if ($workDir) { $Context.Paths.WorkDir = $workDir }
  }
  if (-not $workDir) { throw "WorkDir 未初始化（请先 Phase=Init）" }

  $attDir = Join-Path $workDir "attachments"
  $extractDir = Join-Path $workDir "extract"
  Ensure-Directory $attDir
  Ensure-Directory $extractDir

  $downloaded = @()
  $totalSize = 0L

  # === Branch: Local File Mode vs Normal Mode ===
  if ($Context.Options.LocalFile) {
    Write-LogInfo "Mode: LocalFile ($($Context.Options.LocalFile))"
    if (-not (Test-Path $Context.Options.LocalFile)) { throw "本地文件不存在：$($Context.Options.LocalFile)" }

    # Mock source
    $source = @{ Type='local'; Method='manual'; Uid='debug' }
    $Context.Source.Type = $source.Type
    $Context.Source.Method = $source.Method
    $Context.Source.Uid = $source.Uid
    Set-RunStateValue -State $Context.State -Key 'Source' -Value $source

    # Copy to attachments
    $fname = Split-Path -Leaf $Context.Options.LocalFile
    $dest = Join-Path $attDir $fname
    Copy-Item $Context.Options.LocalFile -Destination $dest -Force
    $downloaded += $dest
    Write-LogOk "已复制本地文件到：$dest"

  } else {
    # Normal Mode: Read Issue & Download

    # 读取 Issue
    $issue = Get-GiteaIssue -Settings $Context.Settings -RepoPath $Context.Run.RepoPath -IssueId $Context.Run.IssueId -OpsToken $Context.Secrets.OpsToken
    $source = Detect-InputSourceFromIssue -Settings $Context.Settings -IssueObject $issue

    $Context.Source.Type = $source.Type
    $Context.Source.Method = $source.Method
    $Context.Source.Uid = $source.Uid

    Set-RunStateValue -State $Context.State -Key 'Source' -Value $source

    if ($source.Type -eq 'restapi') {
      if ([string]::IsNullOrWhiteSpace($source.Uid)) { throw "REST 模式但 UID 为空，请在 Issue 正文提供（UID: XXXXXXXX）" }

      # 等待后端 ready（best-effort）
      try {
        $deadline = (Get-Date).AddSeconds(60)
        do {
          $stat = Get-BsodEventInfo -Settings $Context.Settings -ApiToken $Context.Secrets.ApiToken -Uid $source.Uid
          $st = $null
          try {
            if ($stat.task.status) { $st = [string]$stat.task.status }
            elseif ($stat.upload.status) { $st = [string]$stat.upload.status }
            elseif ($stat.status) { $st = [string]$stat.status }
          } catch {}
          Write-LogInfo "BSOD 后端状态：$st"
          if ($st -in @('ready','ready_for_analysis','analysis_complete','finalized')) { break }
          Start-Sleep -Seconds 2
        } while ((Get-Date) -lt $deadline)
      } catch {
        Write-LogWarn "查询状态失败（忽略）：$($_.Exception.Message)"
      }

      $path = Download-BsodEventBestFile -Settings $Context.Settings -ApiToken $Context.Secrets.ApiToken -Uid $source.Uid -OutDir $attDir
      $downloaded += $path
      $totalSize += (Get-Item $path).Length
    } else {
      # 附件模式：抓 zip/7z
      $atts = Get-GiteaIssueAttachments -Settings $Context.Settings -RepoPath $Context.Run.RepoPath -IssueId $Context.Run.IssueId -OpsToken $Context.Secrets.OpsToken
      if (-not $atts -or $atts.Count -eq 0) { throw "Issue 无附件" }

      $archives = $atts | Where-Object { $_.name -match '\.(zip|7z)$' }
      if (-not $archives -or $archives.Count -eq 0) { throw "附件模式但未发现 zip/7z 附件" }

      $base = Ensure-HttpsBase $Context.Settings.Endpoints.OpsBaseUrl
      foreach ($a in $archives) {
        $name = Sanitize-FileName $a.name
        $url = if ($a.browser_download_url) { $a.browser_download_url } elseif ($a.download_url) { $a.download_url } else { $a.url }
        if (-not $url) { continue }
        $url = Ensure-HttpsUrl -Url $url -Base $base

        $out = Join-Path $attDir $name
        Invoke-WebRequest -Uri $url -OutFile $out -Headers (New-BearerHeaders -Token $Context.Secrets.OpsToken -Accept '*/*') -UseBasicParsing `
          -TimeoutSec $Context.Settings.General.HttpTimeoutSec -ErrorAction Stop
        $downloaded += $out
        $totalSize += (Get-Item $out).Length
        Write-LogOk "附件已下载：$name"
      }
    }

    $limit = [int64]$Context.Settings.General.MaxTotalSizeGB * 1GB
    if ($totalSize -gt $limit) { throw "下载总量 $([math]::Round($totalSize/1GB,2))GB 超限（上限 $($Context.Settings.General.MaxTotalSizeGB)GB）" }
  }

  # 解压/寻找 dmp
  $dumpPath = $null
  $msinfoDir = Join-Path $extractDir "msinfo"
  Ensure-Directory $msinfoDir

  foreach ($p in $downloaded) {
    $ext = [System.IO.Path]::GetExtension($p).ToLowerInvariant()
    if ($ext -match '^\.(zip|7z|001|z01)$') {
      $target = Join-Path $extractDir ([System.IO.Path]::GetFileNameWithoutExtension($p))
      Expand-ArchiveWith7z -ArchivePath $p -Destination $target -Settings $Context.Settings -RepoRoot $Context.RepoRoot
    } elseif ($ext -eq '.dmp') {
      $dumpPath = $p
    }
  }

  if (-not $dumpPath) {
    $d = Get-ChildItem -Path $extractDir -Recurse -Filter *.dmp -ErrorAction SilentlyContinue |
      Sort-Object Length -Descending | Select-Object -First 1
    if ($d) { $dumpPath = $d.FullName }
  }
  if (-not $dumpPath) { throw "未找到 .dmp 文件" }

  # msinfo 收集（按 hint）
  $hint = $Context.Settings.General.MsinfoNameHint
  $cands = Get-ChildItem -Path $extractDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match $hint -and $_.Extension -match '^\.(txt|nfo|xml)$'
  }
  foreach ($c in $cands) { Copy-Item $c.FullName -Destination (Join-Path $msinfoDir $c.Name) -Force }

  $Context.Artifacts.DumpPath = $dumpPath
  $Context.Artifacts.MsinfoDir = $msinfoDir
  $Context.Artifacts.AttachDir = $attDir
  $Context.Artifacts.ExtractDir = $extractDir

  Export-EnvironmentVariables -Variables @{
    DUMP_PATH = $dumpPath
    MSINFO_DIR = $msinfoDir
  }

  Set-RunStateValue -State $Context.State -Key 'Fetch' -Value @{
    Dump = $dumpPath
    MsinfoDir = $msinfoDir
    AttachDir = $attDir
    ExtractDir = $extractDir
  }

  Write-LogOk "Fetch done. Dump: $dumpPath"
}

Export-ModuleMember -Function Invoke-TaskFetch
