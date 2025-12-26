# Submit.ps1

param(
    [string]$IssueNumber,
    [string]$RepoOwner,
    [string]$RepoName
)

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"

Import-Module (Join-Path $ModulesPath "Common.psm1")
Import-Module (Join-Path $ModulesPath "Gitea.psm1")
Import-Module (Join-Path $ModulesPath "PartnerCenter.psm1")
Import-Module (Join-Path $ModulesPath "Hlkx.psm1")

Write-Log "Starting Submit Workflow for Issue #$IssueNumber"

$token = $env:GITHUB_TOKEN

# Need to re-parse issue to get Product ID and Submission ID
$issue = Get-Issue -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Token $token
$body = $issue.body
$productId = ""
$submissionId = ""
if ($body -match "### Product ID\s*\n\s*(.*)") { $productId = $matches[1].Trim() }
if ($body -match "### Submission ID\s*\n\s*(.*)") { $submissionId = $matches[1].Trim() }

if (-not $productId) { Write-Error "Product ID not found in issue."; exit 1 }

# Find latest HLKX
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
    Write-Error "No HLKX attachment found in comments."
    exit 1
}

Write-Log "Found HLKX: $hlkxUrl"

$tempDir = Get-TempDirectory
$hlkxPath = Join-Path $tempDir "submission.hlkx"
Invoke-WebRequest -Uri $hlkxUrl -OutFile $hlkxPath

# Submit
$pcToken = Get-PartnerCenterToken -ClientId $env:PARTNER_CENTER_CLIENT_ID -ClientSecret $env:PARTNER_CENTER_CLIENT_SECRET -TenantId $env:PARTNER_CENTER_TENANT_ID

Submit-Hlkx -HlkxPath $hlkxPath -Token $pcToken -ProductId $productId -SubmissionId $submissionId

Post-Comment -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Body "Submission uploaded to Partner Center." -Token $token

Write-Log "Submit Workflow Completed."
