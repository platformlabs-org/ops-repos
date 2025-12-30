# archive-output.ps1
# 打包签名后的driver目录，归档至OUTPUT_DIR，文件名自动带时间戳

Import-Module "$PSScriptRoot/../modules/OpsApi.psm1" -Force

$outputDir = $env:OUTPUT_DIR
$infDir    = $env:INF_DIR
$workDir   = $env:WORK_DIR
$attachmentName = $env:ATTACHMENT_NAME

if (-not $outputDir) { throw "OUTPUT_DIR env not set!" }
if (-not $attachmentName) { throw "ATTACHMENT_NAME env not set!" }

# 1. 优先INF_DIR，否则WORK_DIR
$sourceDir = $infDir
if ([string]::IsNullOrWhiteSpace($sourceDir)) {
    $sourceDir = $workDir
    if (-not $sourceDir) {
        $sourceDir = "$PSScriptRoot/../../unzipped"
    }
}
if (-not $sourceDir -or -not (Test-Path $sourceDir)) {
    throw "No valid source dir to archive! Neither INF_DIR nor WORK_DIR is set or exist."
}

if (!(Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }

# 2. 归档名
#$timestamp = Get-Date -Format "MMdd-HHmm"
$baseName  = [System.IO.Path]::GetFileNameWithoutExtension($attachmentName)
$zipName   = "${baseName}_Signed.zip"
$zipPath   = Join-Path $outputDir $zipName

Write-Host "Archiving $sourceDir into $zipPath ..."

# 3. 清理旧文件
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# 4. 压缩归档
Compress-Archive -Path (Join-Path $sourceDir '*') -DestinationPath $zipPath

if (!(Test-Path $zipPath)) {
    throw "❌ Failed to create archive: $zipPath"
}

Write-Host "✅ Archive created: $zipPath"

# 5. 输出到环境变量
if ($env:GITHUB_ENV) {
    Add-Content -Path $env:GITHUB_ENV -Value "SIGNED_ARCHIVE=$zipPath"
}
