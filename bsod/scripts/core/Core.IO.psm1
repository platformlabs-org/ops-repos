#requires -Version 5.1
Set-StrictMode -Version Latest

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Sanitize-FileName {
  param([Parameter(Mandatory)][string]$Name)
  return ($Name -replace '[^\w\.\-]+','_')
}

function Truncate-Text {
  param([string]$Text,[int]$Max = 120)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
  if ($Text.Length -le $Max) { return $Text }
  return $Text.Substring(0, [Math]::Max(0,$Max-1)) + '…'
}

function Read-JsonFile {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path $Path)) { return $null }
  $raw = Get-Content -Raw -Path $Path -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  return ($raw | ConvertFrom-Json -ErrorAction Stop)
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)]$Object,
    [int]$Depth = 40
  )
  $dir = Split-Path -Parent $Path
  if ($dir) { Ensure-Directory $dir }
  $json = $Object | ConvertTo-Json -Depth $Depth -Compress
  Set-Content -Path $Path -Value $json -Encoding UTF8
}

function Format-Size {
  param([long]$Bytes)
  if ($Bytes -lt 1KB) { return "$Bytes B" }
  elseif ($Bytes -lt 1MB) { return ("{0:N2} KB" -f ($Bytes/1KB)) }
  elseif ($Bytes -lt 1GB) { return ("{0:N2} MB" -f ($Bytes/1MB)) }
  else { return ("{0:N2} GB" -f ($Bytes/1GB)) }
}

function Format-Speed {
  param([double]$BytesPerSec)
  if ($BytesPerSec -lt 1KB) { return ("{0:N0} B/s" -f $BytesPerSec) }
  elseif ($BytesPerSec -lt 1MB) { return ("{0:N2} KB/s" -f ($BytesPerSec/1KB)) }
  elseif ($BytesPerSec -lt 1GB) { return ("{0:N2} MB/s" -f ($BytesPerSec/1MB)) }
  else { return ("{0:N2} GB/s" -f ($BytesPerSec/1GB)) }
}

function Format-Duration {
  param([int]$Seconds)
  if ($Seconds -lt 0) { return "-" }
  $ts = [TimeSpan]::FromSeconds($Seconds)
  if ($ts.TotalHours -ge 1) { return "{0:%h}h {0:%m}m {0:%s}s" -f $ts }
  else { return "{0:%m}m {0:%s}s" -f $ts }
}

function Resolve-SevenZipExe {
  param(
    [Parameter(Mandatory)]$Settings,
    [Parameter(Mandatory)][string]$RepoRoot
  )
  $candidates = @()
  if ($Settings.Paths.SevenZipExeCandidates) { $candidates += @($Settings.Paths.SevenZipExeCandidates) }

  foreach ($c in $candidates) {
    $p = $c
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $RepoRoot $p }
    if (Test-Path $p) { return (Resolve-Path $p).Path }
  }
  throw "7z.exe 未找到：请在 settings.psd1.Paths.SevenZipExeCandidates 配置，或安装 7-Zip"
}

function Expand-ArchiveWith7z {
  param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)]$Settings,
    [Parameter(Mandatory)][string]$RepoRoot
  )
  Ensure-Directory $Destination
  $sevenZip = Resolve-SevenZipExe -Settings $Settings -RepoRoot $RepoRoot
  Write-LogInfo "解压：$ArchivePath -> $Destination (7z: $sevenZip)"
  & $sevenZip 'x' '-y' ("-o$Destination") "--" "$ArchivePath" | Out-Null
}

Export-ModuleMember -Function `
  Ensure-Directory,Sanitize-FileName,Truncate-Text,Read-JsonFile,Write-JsonFile, `
  Format-Size,Format-Speed,Format-Duration,Resolve-SevenZipExe,Expand-ArchiveWith7z
