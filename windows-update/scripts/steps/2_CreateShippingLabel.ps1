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
Import-Module (Join-Path $ModulesPath "PartnerCenter.psm1") -Force

Write-Log "Step 2: Create Shipping Label"

$productId = $env:PRODUCT_ID
$submissionId = $env:SUBMISSION_ID
$jsonPath = $env:REQUEST_BODY_PATH

if (-not $productId -or -not $submissionId -or -not $jsonPath) {
    throw "Missing environment variables. Step 1 must run first."
}

$jsonBody = Get-Content -Path $jsonPath -Raw

# 1. Authenticate
$clientId = $env:PARTNER_CENTER_CLIENT_ID
$clientSecret = $env:PARTNER_CENTER_CLIENT_SECRET
$tenantId = $env:PARTNER_CENTER_TENANT_ID

if (-not $clientId -or -not $clientSecret -or -not $tenantId) {
    throw "Missing Partner Center credentials."
}

Write-Log "Authenticating with Partner Center..."
$pcToken = Get-PartnerCenterToken -ClientId $clientId -ClientSecret $clientSecret -TenantId $tenantId

# 2. Call API
Write-Log "Creating Shipping Label for Product $productId, Submission $submissionId..."
try {
    $response = New-ShippingLabel -ProductId $productId -SubmissionId $submissionId -Token $pcToken -Body $jsonBody
    $responseJson = $response | ConvertTo-Json -Depth 10

    $message = "### Shipping Label Created Successfully`n`n```json`n$responseJson`n```"
    Write-Log "Success."
} catch {
    $errorMsg = $_.Exception.Message
    $message = "### Shipping Label Creation Failed`n`nError: $errorMsg"
    Write-Log "Failed: $errorMsg" "ERROR"
    # We don't throw here to ensure we can post the failure comment.
}

# 3. Post Comment
$giteaToken = $env:GITHUB_TOKEN
if (-not $giteaToken) { $giteaToken = $env:GITEA_TOKEN }
if (-not $giteaToken) { $giteaToken = $env:BOTTOKEN }

Post-Comment -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Body $message -Token $giteaToken

if ($message -match "Failed") {
    exit 1
}
