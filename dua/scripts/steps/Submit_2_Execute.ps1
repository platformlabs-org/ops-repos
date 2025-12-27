param(
    [string]$IssueNumber,
    [string]$RepoOwner,
    [string]$RepoName
)

$ErrorActionPreference = "Stop"
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"

Import-Module (Join-Path $ModulesPath "Common.psm1")        -Force
Import-Module (Join-Path $ModulesPath "Gitea.psm1")         -Force
Import-Module (Join-Path $ModulesPath "PartnerCenter.psm1") -Force

Write-Log "Step 2: Execute Submission"

$productId = $env:PRODUCT_ID
$hlkxUrl   = $env:HLKX_URL

if (-not $productId -or -not $hlkxUrl) { throw "Missing input env vars." }

# 1. Download HLKX
$workspace = $env:GITHUB_WORKSPACE
if (-not $workspace) { $workspace = Get-Location }
$tempDir = Join-Path $workspace "submission_temp"
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

$hlkxPath = Join-Path $tempDir "submission.hlkx"
Write-Log "Downloading HLKX to $hlkxPath"
Invoke-WebRequest -Uri $hlkxUrl -OutFile $hlkxPath

# 2. Submit to Partner Center
$pcToken = Get-PartnerCenterToken `
    -ClientId     $env:PARTNER_CENTER_CLIENT_ID `
    -ClientSecret $env:PARTNER_CENTER_CLIENT_SECRET `
    -TenantId     $env:PARTNER_CENTER_TENANT_ID

Write-Log "Creating new submission for Product $productId..."

try {
    # Create
    $submission = New-Submission -ProductId $productId -Token $pcToken
    $submissionId = $submission.id

    # Check for upload URL (sasUrl)
    # Based on PC API, 'fileUploadUrl' is usually in the response for new ingestion submission
    $sasUrl = $submission.fileUploadUrl
    if (-not $sasUrl) {
         Write-Warning "fileUploadUrl not found immediately. Response: $($submission | ConvertTo-Json -Depth 2)"
    }

    if (-not $sasUrl) { throw "Cannot upload: Missing SAS URL." }

    Write-Log "Submission Created: $submissionId"

    # Upload
    Upload-FileToBlob -SasUrl $sasUrl -FilePath $hlkxPath
    Write-Log "HLKX Uploaded."

    # Commit
    Commit-Submission -ProductId $productId -SubmissionId $submissionId -Token $pcToken
    Write-Log "Submission Committed."

    # Notify
    $token = $env:GITHUB_TOKEN
    if (-not $token) { $token = $env:GITEA_TOKEN }
    if (-not $token) { $token = $env:BOTTOKEN }

    Post-Comment `
        -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber `
        -Body "✅ Submission **$submissionId** committed to Partner Center successfully." `
        -Token $token | Out-Null

} catch {
    Write-Error "Submission process failed: $_"
    throw
}
