param(
    [string]$IssueNumber,
    [string]$RepoOwner,
    [string]$RepoName
)

$ErrorActionPreference = "Stop"
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"

Import-Module (Join-Path $ModulesPath "Common.psm1") -Force
Import-Module (Join-Path $ModulesPath "Gitea.psm1")  -Force

Write-Log "Step 1: Parse Submission Info"

$token = $env:GITHUB_TOKEN
if (-not $token) { $token = $env:GITEA_TOKEN }
if (-not $token) { $token = $env:BOTTOKEN }
if (-not $token) { throw "Missing API token." }

# 1. Get Product ID from Issue Body
$issue = Get-Issue -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Token $token
$body = $issue.body
$productId = ""
if ($body -match "### Product ID\s*\r?\n\s*(.+?)\s*(\r?\n|$)") { $productId = $matches[1].Trim() }

if (-not $productId) { throw "Product ID not found in issue." }
Write-Log "Product ID: $productId"

# 2. Find latest HLKX in comments
$comments = Get-Comments -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Token $token

$hlkxUrl = $null
foreach ($comment in $comments) {
    if ($comment.assets) {
        foreach ($asset in $comment.assets) {
            if ($asset.name -match "\.hlkx$") {
                $hlkxUrl = $asset.browser_download_url
            }
        }
    }
}

if (-not $hlkxUrl) {
    throw "No HLKX attachment found in comments."
}

Write-Log "Found HLKX URL: $hlkxUrl"

"PRODUCT_ID=$productId" | Out-File -FilePath $env:GITHUB_ENV -Append
"HLKX_URL=$hlkxUrl" | Out-File -FilePath $env:GITHUB_ENV -Append
