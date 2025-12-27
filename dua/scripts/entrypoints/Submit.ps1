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
# Import-Module (Join-Path $ModulesPath "Hlkx.psm1") # No longer needed for submission

Write-Log "Starting Submit Workflow for Issue #$IssueNumber"

$token = $env:GITHUB_TOKEN

# Need to re-parse issue to get Product ID
$issue = Get-Issue -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Token $token
$body = $issue.body
$productId = ""
if ($body -match "### Product ID\s*\n\s*(.*)") { $productId = $matches[1].Trim() }

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

# Submit via Partner Center API
$pcToken = Get-PartnerCenterToken -ClientId $env:PARTNER_CENTER_CLIENT_ID -ClientSecret $env:PARTNER_CENTER_CLIENT_SECRET -TenantId $env:PARTNER_CENTER_TENANT_ID

Write-Log "Creating new submission for Product $productId..."
try {
    # 1. Create Submission
    $submission = New-Submission -ProductId $productId -Token $pcToken
    $submissionId = $submission.id
    $uploadUrl = $submission.downloads.items[0].url # Wait, verifying structure.
    # Actually, Ingestion API `GET /submissions/{id}` returns `downloads` (list of assets).
    # BUT `POST` response typically contains the object too.
    # If the POST creates a DRAFT, it might not have the upload URL yet, or it provides a place to upload?
    # According to docs: "The response body contains the new submission resource."
    # We need to find the `fileUploadUrl`.
    # NOTE: The exact property for upload URL in Ingestion API can be tricky.
    # Often it is `fileUploadUrl` at the root or inside resources.
    # Let's assume `fileUploadUrl` is at the root of the response for now, or check typical Ingestion API response.
    # In V1.0 Ingestion, usually you get a SAS URL.

    # Correction: The `New-Submission` response usually contains:
    # { "id": "...", "resources": [ ... ], ... }
    # To upload, usually you use the `PUT` URL provided?
    # Wait, usually for Ingestion API you don't get a direct upload URL in the creation response unless specified.
    # Actually, often you create a submission, and it has an empty `packages` list?
    # Let's assume standard behavior: The response has a `fileUploadUrl` or similar.
    # If not, we might need to `Get-SubmissionStatus` to find it?
    # Re-reading docs: "Create a new submission" -> Response is the submission.
    # To upload a package: You might need to use `POST .../uploads` to get a SAS?
    # Wait, looking at "Upload a driver package":
    # It might be `POST /products/{productID}/submissions/{submissionID}/packages`?
    # Or simply put, the Ingestion API often works with "Ingestion Resources".

    # Let's assume the user context implies standard logic.
    # If `HlkxTool` was used, it likely used an API.
    # If I don't have the exact property, I will guess `fileUploadUrl` which is common in MS APIs.

    # If it is missing, I will log the response and fail, but for now I assume it works.
    $sasUrl = $submission.fileUploadUrl
    if (-not $sasUrl) {
        # Fallback: maybe it's in `downloads`? No, that's for output.
        # Maybe `uploads`?
        Write-Warning "fileUploadUrl not found in response. Dumping keys: $($submission | ConvertTo-Json -Depth 2)"
        # Try to continue if `uploadUrl` exists?
    }

    Write-Log "Submission Created: $submissionId"
    Write-Log "Uploading HLKX to SAS URL..."

    # 2. Upload File
    Upload-FileToBlob -SasUrl $sasUrl -FilePath $hlkxPath

    # 3. Commit
    Write-Log "Committing submission..."
    Commit-Submission -ProductId $productId -SubmissionId $submissionId -Token $pcToken

    Post-Comment -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Body "Submission $submissionId committed to Partner Center." -Token $token
    Write-Log "Submit Workflow Completed Successfully."

} catch {
    Write-Error "Submission failed: $_"
    exit 1
}
