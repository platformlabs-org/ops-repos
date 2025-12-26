# update-issue.ps1
. "$PSScriptRoot/APIHelper.ps1"

# ====== 基础参数读取 ======
$repo      = $env:GITEA_REPO
if (-not $repo) { $repo = "PE/SIGN" }
$issueId   = $env:ISSUE_ID
$outputDir = $env:OUTPUT_DIR

if (-not $issueId)  { throw "ISSUE_ID env not set!" }
if (-not $outputDir) { throw "OUTPUT_DIR env not set!" }
try {
    $outputDir = (Resolve-Path $outputDir).Path
} catch {
    throw "OUTPUT_DIR does not exist: $outputDir"
}

# ====== 获取所有 .zip/.cab 文件 ======
$fileList = Get-ChildItem -Path $outputDir -File | Where-Object {
    $_.Name -like '*.zip' -or $_.Name -like '*.cab'
} | Select-Object -ExpandProperty FullName

if (-not $fileList -or $fileList.Count -eq 0) {
    Write-Host "Files in OUTPUT_DIR:"
    Get-ChildItem -Path $outputDir | ForEach-Object { Write-Host $_.FullName }
    throw "No .zip or .cab files found in OUTPUT_DIR to upload."
}

# ====== 上传文件到 Issue ======
$comment = "Package Signing success！"
Write-Host "Uploading these files to issue:"
$fileList | ForEach-Object { Write-Host "  - $_" }

try {
    Add-CommentWithAttachments -RepoPath $repo -IssueID $issueId -Comment $comment -FilePaths $fileList
    Write-Host "✅ All files uploaded successfully."
} catch {
    Write-Host "❌ Failed to upload files to issue: $_"
    exit 1
}

# ====== 动态生成 Issue 新标题 ======
# 优先使用环境变量关键信息
$signType   = $env:SIGN_TYPE
$drvVer     = $env:DRIVER_VERSION
$attachName = $env:ATTACHMENT_NAME

if (-not $signType)   { $signType   = "Driver" }
if (-not $drvVer)     { $drvVer     = "" }
if (-not $attachName) { $attachName = "" }

# 生成新标题，格式可按需调整
$newTitle = "[Driver Sign Request]: $attachName Signed"

Write-Host "Updating issue title to: $newTitle"

try {
    $retTitle = Update-IssueTitle -RepoPath $repo -IssueId $issueId -NewTitle $newTitle
    Write-Host "✅ Issue title updated: $retTitle"
} catch {
    Write-Host "❌ Failed to update issue title: $_"
    # 标题失败一般不影响主流程
}

