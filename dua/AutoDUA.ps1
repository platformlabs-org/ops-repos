param (
    [Parameter(Mandatory = $true)]
    [string]$hlkxDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-OutputVar {
    param(
        [string]$Name,
        [string]$Value
    )

    if ($env:GITHUB_OUTPUT) {
        "$Name=$Value" >> $env:GITHUB_OUTPUT
    } else {
        Write-Host "::set-output name=$Name::$Value"
    }
}

# 检查 HlkxTool.exe 是否存在
$exe = ".\HlkxTool\HlkxTool.exe"
if (-not (Test-Path $exe)) {
    throw "[ERROR] HlkxTool.exe not found at path: $exe"
}

# 检查 HLKX 目录
if (-not (Test-Path $hlkxDir)) {
    throw "[ERROR] Specified HLKX directory does not exist: $hlkxDir"
}

# 准备输出目录
$outputDir = Join-Path $hlkxDir "repackaged"
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

# 查找 hlkx 文件
$hlkxFiles = Get-ChildItem -Path $hlkxDir -Recurse -Filter *.hlkx
if (-not $hlkxFiles) {
    throw "[ERROR] No .hlkx files found in '$hlkxDir'."
}

$savedFiles  = @()
$failedFiles = @()

Write-Host ""
Write-Host "[INFO] Starting to process HLKX files using HlkxTool (DUA)..."

foreach ($hlkx in $hlkxFiles) {
    $hlkxPath  = $hlkx.FullName
    $baseName  = [System.IO.Path]::GetFileNameWithoutExtension($hlkx.Name)
    $parentDir = $hlkx.DirectoryName
    $driverPath = Join-Path $parentDir $baseName

    Write-Host ""
    Write-Host "[INFO] Processing HLKX: $hlkxPath"
    Write-Host "[INFO] Expect driver folder: $driverPath"

    if (-not (Test-Path $driverPath)) {
        Write-Host "[WARNING] Skipped - Driver folder not found: $driverPath"
        $failedFiles += $hlkxPath
        continue
    }

    $infFiles = Get-ChildItem -Path $driverPath -Filter *.inf
    if (-not $infFiles) {
        Write-Host "[WARNING] Skipped - No .inf file found in driver folder: $driverPath"
        $failedFiles += $hlkxPath
        continue
    }

    $updatedName = "${baseName}_repackaged.hlkx"
    $savePath    = Join-Path $outputDir $updatedName

    # 构造命令：HlkxTool.exe DUA "<hlkx>" "<driverPath>" "<savePath>"
    $args = @(
        "DUA",
        "`"$hlkxPath`"",
        "`"$driverPath`"",
        "`"$savePath`""
    )

    Write-Host "[INFO] Running HlkxTool.exe with arguments:"
    Write-Host "[INFO] $exe $($args -join ' ')"

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $exe
        $psi.Arguments              = $args -join ' '
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        $process.Start() | Out-Null

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()

        $process.WaitForExit()

        if ($process.ExitCode -ne 0) {
            Write-Host "[ERROR] HlkxTool.exe exited with code $($process.ExitCode)"
            if ($stdout) { Write-Host "[ERROR] StdOut:`n$stdout" }
            if ($stderr) { Write-Host "[ERROR] StdErr:`n$stderr" }
            $failedFiles += $hlkxPath
            continue
        }

        if (Test-Path $savePath) {
            Write-Host "[SUCCESS] Repackaged (and signed) file: $savePath"
            $savedFiles += $savePath
        } else {
            Write-Host "[ERROR] Output file not found after HlkxTool execution: $savePath"
            if ($stdout) { Write-Host "[ERROR] StdOut:`n$stdout" }
            if ($stderr) { Write-Host "[ERROR] StdErr:`n$stderr" }
            $failedFiles += $hlkxPath
        }
    }
    catch {
        Write-Host "[ERROR] Exception occurred while running HlkxTool.exe: $($_.Exception.Message)"
        $failedFiles += $hlkxPath
    }
}

# 总结输出
Write-Host ""
Write-Host "[INFO] Processing Summary:"
Write-Host "[INFO] Successful files: $($savedFiles.Count)"
Write-Host "[INFO] Failed files:     $($failedFiles.Count)"

if ($savedFiles.Count -gt 0) {
    $outputString = $savedFiles -join ","
    Write-OutputVar -Name "hlkx_saved" -Value $outputString
} else {
    throw "[ERROR] All hlkx files failed to process or none were valid."
}
