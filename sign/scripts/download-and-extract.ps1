# download_and_extract.ps1
# 依赖 APIHelper.ps1

. "$PSScriptRoot/APIHelper.ps1"

function Remove-SpecialChars {
    param([string]$Str)
    return ($Str -replace '[^a-zA-Z0-9_\.\-]', '_')
}

# === 1. 基本参数 ===
$issueId = $env:ISSUE_ID
if (-not $issueId) { throw "ISSUE_ID env not set!" }
$repo = $env:GITEA_REPO
if (-not $repo) { $repo = "PE/SIGN" }
$workDir = $env:WORK_DIR
if (-not $workDir) { $workDir = "$PSScriptRoot/../unzipped" }
if (!(Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

# === 2. 获取附件信息 ===
$issueDetail = Get-IssueDetail -RepoPath $repo -IssueID $issueId
if (-not $issueDetail.assets -or $issueDetail.assets.Count -eq 0) {
    throw "No attachment found in the issue!"
}
$asset   = $issueDetail.assets | Select-Object -First 1
$oriName = $asset.name
$dlUrl   = $asset.browser_download_url

if (-not $oriName.ToLower().EndsWith(".zip")) {
    throw "Attachment is not a zip file: $oriName"
}

$localName = Remove-SpecialChars ([System.IO.Path]::GetFileName($oriName))
if ([string]::IsNullOrWhiteSpace($localName) -or -not $localName.ToLower().EndsWith(".zip")) {
    throw "Attachment file name is invalid: $localName"
}

# === 3. 下载到临时目录 ===
$tempDir = [System.IO.Path]::GetTempPath()
if (!(Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }
$tempZip = Join-Path $tempDir $localName

if (Test-Path $tempZip) {
    if ((Get-Item $tempZip).PSIsContainer) {
        throw "Download target path is a directory, not a file: $tempZip"
    }
    Remove-Item $tempZip -Force
}

Write-Host "Downloading $dlUrl -> $tempZip"
try {
    Download-FileWithProgress -Url $dlUrl -OutputPath $tempZip
} catch {
    throw "Failed to download file: $_"
}
if (!(Test-Path $tempZip)) { throw "Downloaded zip file does not exist: $tempZip" }

# === 4. 解压到WORKDIR（只清空子内容）===
Get-ChildItem -Path $workDir -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
try {
    Expand-Archive -Path $tempZip -DestinationPath $workDir -Force
} catch {
    throw "Failed to extract"
}
Write-Host "Extracted to $workDir"

# === 5. INF相关（分类型处理）===
$signType = $env:SIGN_TYPE

if ($signType -eq "Sign File") {
    Write-Host "Sign Type is 'Sign File', skipping INF check."
} else {
    $allInf = Get-ChildItem -Path $workDir -Recurse -Filter *.inf -File
    if (-not $allInf -or $allInf.Count -eq 0) { throw "No .inf file found in attachment!" }

    $shallowInf = $allInf | Sort-Object {
        ($_.FullName.Substring($workDir.Length).TrimStart('\','/') -split '[\\\/]').Count
    } | Select-Object -First 1

    $infPath = $shallowInf.FullName
    $infDir  = Split-Path $infPath -Parent

    Write-Host "Shallowest INF: $infPath"
    Write-Host "INF_DIR: $infDir"

    # === 6. whosinf 检查（仅Lenovo Driver）===
    if ($signType -eq "Lenovo Driver") {
        $whosinfExe = Resolve-Path "$PSScriptRoot/../tools/whosinf.exe" -ErrorAction SilentlyContinue
        if (-not $whosinfExe) { throw "whosinf.exe not found in ../tools/." }
        $whoResult = & $whosinfExe $infPath 2>&1
        Write-Host "whosinf output: $whoResult"
        if ($whoResult.Trim().ToLower() -ne "lenovo") {
            throw "❌ The selected driver type is 'Lenovo Driver' but whosinf result is not 'Lenovo'. Please check your submission."
        }
    }

    # === 7. 设置INF_DIR到环境变量 ===
    $env:INF_DIR = $infDir
    if ($env:GITHUB_ENV) {
        Add-Content -Path $env:GITHUB_ENV -Value "INF_DIR=$infDir"
    }
    Write-Host "INF_DIR=$infDir"
}

Write-Host "Download and extract completed."
