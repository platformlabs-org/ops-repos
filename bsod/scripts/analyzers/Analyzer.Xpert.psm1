#requires -Version 5.1
Set-StrictMode -Version Latest

function Resolve-XpertExe {
  param([Parameter(Mandatory)]$Settings,[Parameter(Mandatory)][string]$RepoRoot)
  $p = [string]$Settings.Paths.XpertExe
  if ([string]::IsNullOrWhiteSpace($p)) { throw "settings.psd1.Paths.XpertExe 未配置" }
  if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $RepoRoot $p }
  if (-not (Test-Path $p)) { throw "xpert.exe 不存在：$p" }
  return (Resolve-Path $p).Path
}

function Invoke-XpertAnalyzer {
  param([Parameter(Mandatory)]$Context)

  $dumpPath = $Context.Artifacts.DumpPath
  if (-not (Test-Path $dumpPath)) { throw "Dump 不存在：$dumpPath" }

  $outDir = Join-Path $Context.Paths.OutputDir "xpert"
  Ensure-Directory $outDir

  $xpertExe = Resolve-XpertExe -Settings $Context.Settings -RepoRoot $Context.RepoRoot
  $timeoutSec = [int]$Context.Settings.General.XpertTimeoutSec

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = $xpertExe
  $psi.Arguments              = "--dump `"$dumpPath`" --out `"$outDir`""
  $psi.WorkingDirectory       = $outDir
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true

  Write-LogInfo ("xpert cmd: `"{0}`" {1}" -f $psi.FileName, $psi.Arguments)

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()

  $stdout = New-Object System.Text.StringBuilder
  $stderr = New-Object System.Text.StringBuilder

  $outTask = [System.Threading.Tasks.Task]::Run([Action]{
    while(-not $p.HasExited){
      $line = $p.StandardOutput.ReadLine()
      if ($null -ne $line) { [void]$stdout.AppendLine($line) }
    }
    $tail = $p.StandardOutput.ReadToEnd()
    if ($tail) { [void]$stdout.Append($tail) }
  })
  $errTask = [System.Threading.Tasks.Task]::Run([Action]{
    while(-not $p.HasExited){
      $line = $p.StandardError.ReadLine()
      if ($null -ne $line) { [void]$stderr.AppendLine($line) }
    }
    $tail = $p.StandardError.ReadToEnd()
    if ($tail) { [void]$stderr.Append($tail) }
  })

  $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1,$timeoutSec))
  while (-not $p.HasExited) {
    if ([DateTime]::UtcNow -gt $deadline) { try { $p.Kill() } catch {}; throw "xpert 超时：$timeoutSec 秒" }
    Start-Sleep -Milliseconds 150
  }
  [void]$outTask.Wait(1000); [void]$errTask.Wait(1000)

  $logDir = Join-Path $outDir "logs"
  Ensure-Directory $logDir
  $stdoutLog = Join-Path $logDir "xpert_stdout.log"
  $stderrLog = Join-Path $logDir "xpert_stderr.log"
  Set-Content -Path $stdoutLog -Value $stdout.ToString() -Encoding UTF8
  Set-Content -Path $stderrLog -Value $stderr.ToString() -Encoding UTF8

  $analysisJson = Get-ChildItem -Path $outDir -Recurse -Filter 'analysis.json' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName -ErrorAction SilentlyContinue
  $systemInfoJson = Get-ChildItem -Path $outDir -Recurse -Filter 'systemInfo.json' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName -ErrorAction SilentlyContinue

  $exitCode = $p.ExitCode
  if ($exitCode -ne 0 -and -not $analysisJson -and -not $systemInfoJson) {
    $head = ($stderr.ToString() -split "`r?`n" | Select-Object -First 20) -join "`n"
    throw "xpert 退出码 $exitCode；stderr 前20行：`n$head"
  }
  if ($exitCode -ne 0) { Write-LogWarn "xpert 退出码 $exitCode，但已产出文件（继续）" }

  $analysisObj = if ($analysisJson) { Read-JsonFile $analysisJson } else { $null }
  $sysObj = if ($systemInfoJson) { Read-JsonFile $systemInfoJson } else { $null }

  # PartialReport（原始对象先放 meta，归一化在 Normalize 层做）
  return @{
    meta = @{
      analyzers = @('xpert')
      xpert = @{
        output_dir = $outDir
        analysis_json = $analysisJson
        systeminfo_json = $systemInfoJson
        stdout_log = $stdoutLog
        stderr_log = $stderrLog
        exit_code  = $exitCode
      }
      raw = @{
        analysis = $analysisObj
        systemInfo = $sysObj
      }
    }
  }
}

Export-ModuleMember -Function Invoke-XpertAnalyzer
