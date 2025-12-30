# precheck.ps1
# 依赖 OpsApi.psm1

Import-Module "$PSScriptRoot/../modules/OpsApi.psm1" -Force

function Remove-SpecialChars {
    param([string]$Str)
    # 保留字母、数字、下划线、点、横杠
    return ($Str -replace '[^a-zA-Z0-9_\.\-]', '_')
}

# 1. 基本参数
$issueId = $env:ISSUE_ID
if (-not $issueId) { throw "ISSUE_ID env not set!" }
$repo = $env:GITEA_REPO
if (-not $repo) { $repo = "PE/SIGN" }

# 2. 获取 Issue 详情
$issueDetail = Get-IssueDetail -RepoPath $repo -IssueID $issueId

if (-not $issueDetail) { throw "Failed to fetch issue detail." }
$body = $issueDetail.body
if (-not $body) { throw "Issue body is empty!" }

# 3. 解析字段
function Parse-SectionValue($body, $sectionTitle) {
    $pattern = "(?ms)### $sectionTitle\s*([\s\S]+?)(?:\n### |\Z)"
    $m = [regex]::Match($body, $pattern)
    return ($m.Groups[1].Value.Trim() -replace '\r','')
}

$signType = Parse-SectionValue $body 'Driver Sign Type'
$needCab  = Parse-SectionValue $body 'Do you need CAB packaging\?'
$archType = Parse-SectionValue $body 'Architecture Type'
$drvVer   = Parse-SectionValue $body 'Driver Version'

if (-not $signType) { $signType = "Lenovo Driver" }
if (-not $archType) { $archType = "AMD64" }
if (-not $needCab)  { $needCab = "No" }

Add-Content -Path $env:GITHUB_ENV -Value "SIGN_TYPE=$signType"
Add-Content -Path $env:GITHUB_ENV -Value "NEED_CAB=$needCab"
Add-Content -Path $env:GITHUB_ENV -Value "ARCH_TYPE=$archType"
Add-Content -Path $env:GITHUB_ENV -Value "DRIVER_VERSION=$drvVer"

Write-Host "Parsed SIGN_TYPE: $signType"
Write-Host "Parsed NEED_CAB: $needCab"
Write-Host "Parsed ARCH_TYPE: $archType"
Write-Host "Parsed DRIVER_VERSION: $drvVer"

# 4. 附件检查与名称提示
if (-not $issueDetail.assets -or $issueDetail.assets.Count -eq 0) {
    throw "No attachment found in the issue!"
}
$asset = $issueDetail.assets | Select-Object -First 1
$oriName = $asset.name
$cleanName = Remove-SpecialChars $oriName

if (-not $cleanName.ToLower().EndsWith(".zip")) {
    throw "Attachment is not a zip file: $oriName"
}
if ($cleanName -ne $oriName) {
    Write-Warning "Attachment file name contains special characters: $oriName"
    Write-Host    "Suggested file name: $cleanName"
} else {
    Write-Host    "Attachment file name is valid: $oriName"
}

Add-Content -Path $env:GITHUB_ENV -Value "ATTACHMENT_NAME=$cleanName"

Write-Host "Attachment precheck passed."
