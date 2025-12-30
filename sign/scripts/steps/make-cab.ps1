# make-cab.ps1
# 所有生成文件都放在 OUTPUT_DIR，CAB文件名来自 ATTACHMENT_NAME

Import-Module "$PSScriptRoot/../modules/OpsApi.psm1" -Force

$timestampServer = "http://timestamp.digicert.com"

# ==== 环境变量 ====
$needCab = $env:NEED_CAB
$infDir = $env:INF_DIR
$outputDir = $env:OUTPUT_DIR
$attachmentName = $env:ATTACHMENT_NAME

if (-not $infDir) { throw "INF_DIR env not set!" }
if (-not $outputDir) { throw "OUTPUT_DIR env not set!" }
if (-not $attachmentName) { throw "ATTACHMENT_NAME env not set!" }
if (-not (Test-Path $infDir)) { throw "INF_DIR does not exist: $infDir" }
if (!(Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory | Out-Null }
if ($needCab -ne "Yes") {
    Write-Host "NEED_CAB is not 'Yes', skipping CAB package step."
    exit 0
}

# ==== 使用 ATTACHMENT_NAME 作为 CAB 文件名（只改扩展名为.cab）====
$cabFileName = [System.IO.Path]::GetFileNameWithoutExtension($attachmentName) + ".cab"
$cabFilePath = Join-Path $outputDir $cabFileName
Write-Host "Creating CAB file: $cabFilePath"

# ==== 生成 DDF 文件（也在OUTPUT_DIR下）====
$ddfFileName = "makecab_" + [guid]::NewGuid().ToString() + ".ddf"
$ddfFilePath = Join-Path $outputDir $ddfFileName

$ddfContent = @"
.Set CabinetNameTemplate=$cabFileName
.Set DiskDirectory1=.
.Set CompressionType=MSZIP
.Set Cabinet=on
.Set Compress=on
.Set MaxCabinetSize=0
.Set MaxDiskFileCount=0
.Set MaxDiskSize=0
.Set FolderFileCountThreshold=0
"@
Set-Content -Path $ddfFilePath -Value $ddfContent

# ==== 追加所有文件到 DDF（driver前缀保持结构）====
$driverDir = $infDir.TrimEnd('\')
$relativePath = "driver"
Get-ChildItem -Path $driverDir -Recurse -File | ForEach-Object {
    $absolutePath = $_.FullName
    $relativeFilePath = $absolutePath.Substring($driverDir.Length).TrimStart('\')
    $relativeFilePathInCab = Join-Path $relativePath $relativeFilePath
    Add-Content -Path $ddfFilePath -Value "`"$absolutePath`" `"$relativeFilePathInCab`""
}

# ==== makecab: 在outputDir中运行 ====
Push-Location $outputDir
try {
    Write-Host "Running makecab in $outputDir..."
    Start-Process -FilePath "makecab" -ArgumentList "/F `"$ddfFileName`"" -NoNewWindow -Wait
}
finally {
    Pop-Location
}

# ==== 清理 DDF ====
Remove-Item -Path $ddfFilePath -Force

if (!(Test-Path $cabFilePath)) {
    throw "CAB file not created: $cabFilePath"
}
Write-Host "CAB file successfully created: $cabFilePath"

# ==== 签名 CAB 文件 ====
$certificate = Get-ChildItem -Path Cert:\CurrentUser\My |
    Where-Object { $_.HasPrivateKey -eq $true -and $_.Subject -match "Lenovo" } |
    Select-Object -First 1

if (-not $certificate) {
    throw "No Lenovo certificate with private key found in Cert:\CurrentUser\My"
}

Write-Host "Signing CAB file: $cabFilePath"
Set-AuthenticodeSignature -FilePath $cabFilePath -Certificate $certificate -HashAlgorithm SHA256 -TimestampServer $timestampServer
Write-Host "CAB file signed successfully."

# ==== 输出路径到 Actions 环境 ====
if ($env:GITHUB_ENV) {
    Add-Content -Path $env:GITHUB_ENV -Value "SIGNED_CAB=$cabFilePath"
}
