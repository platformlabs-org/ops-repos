param(
    [string]$IssueNumber,
    [string]$RepoOwner,
    [string]$RepoName
)

$ErrorActionPreference = "Stop"
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"
$RepoRoot    = Resolve-Path (Join-Path $ScriptRoot "..\..") | Select-Object -ExpandProperty Path

Import-Module (Join-Path $ModulesPath "Common.psm1")        -Force
Import-Module (Join-Path $ModulesPath "Gitea.psm1")         -Force
Import-Module (Join-Path $ModulesPath "PartnerCenter.psm1") -Force
Import-Module (Join-Path $ModulesPath "DriverPipeline.psm1")-Force

Write-Log "Step 1: Parse Issue & Configuration"

# Token
$token = $env:GITHUB_TOKEN
if (-not $token) { $token = $env:GITEA_TOKEN }
if (-not $token) { $token = $env:BOTTOKEN }
if (-not $token) { throw "Missing API token." }

# Get Issue
$issue = Get-Issue -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Token $token
$body = $issue.body
if (-not $body) { $body = "" }

$projectName  = ""
$productId    = ""

if ($body -match "(?ms)###\s*Project Name\s*\r?\n\s*(.+?)\s*(\r?\n|$)")  { $projectName  = $matches[1].Trim() }
if ($body -match "(?ms)###\s*Product ID\s*\r?\n\s*(.+?)\s*(\r?\n|$)")    { $productId    = $matches[1].Trim() }

Write-Log "Parsed Input: Project='$projectName', ProductId='$productId'"

if (-not $productId) { throw "Missing required field: Product ID." }

# Authenticate PC
$pcToken = Get-PartnerCenterToken `
    -ClientId     $env:PARTNER_CENTER_CLIENT_ID `
    -ClientSecret $env:PARTNER_CENTER_CLIENT_SECRET `
    -TenantId     $env:PARTNER_CENTER_TENANT_ID

$submissionName = ""

# Auto-Fetch Submission if ID is missing
if (-not $submissionId) {
    Write-Log "Submission ID not provided. Auto-fetching submissions for Product ID: $productId..."
    $subs = Get-ProductSubmissions -ProductId $productId -Token $pcToken

    # Filter for type == "initial"
    $initialSub = $subs.value | Where-Object { $_.type -eq "initial" } | Select-Object -First 1

    if (-not $initialSub) {
        throw "Could not find any submission with type='initial' for Product $productId."
    }

    $submissionId   = $initialSub.id
    $submissionName = $initialSub.name
    Write-Log "Found Initial Submission: ID=$submissionId, Name='$submissionName'"
} else {
    # If ID was provided, we still need the Name for routing if project name logic fails
    $meta = Get-DriverMetadata -ProductId $productId -SubmissionId $submissionId -Token $pcToken
    $submissionName = $meta.name
    Write-Log "Using provided Submission: ID=$submissionId, Name='$submissionName'"
}

# Determine Strategy
$productRoutingPath = Join-Path $RepoRoot "config\mapping\product_routing.json"
$infRulesPath       = Join-Path $RepoRoot "config\inf_patch_rules.json"
$infRules = if (Test-Path -LiteralPath $infRulesPath) { Get-Content -Raw -LiteralPath $infRulesPath | ConvertFrom-Json } else { $null }

$infStrategy = $null

# Legacy logic relies on Project Name (Codename). If user provided it, use it.
if ($projectName -and $infRules -and $infRules.project -and $infRules.project."$projectName") {
    Write-Log "Project '$projectName' found in inf_patch_rules. Using Submission Name for routing."
    $infStrategy = Select-Pipeline -ProductName $submissionName -MappingFile $productRoutingPath
} else {
    # Fallback/Default: Route based on Submission Name directly if Project Name is missing or not in rules
    # If ProjectName is missing, we treat SubmissionName as the primary identifier for routing
    if (-not $projectName) {
        Write-Log "Project Name not provided. Using Submission Name '$submissionName' for routing."
        $infStrategy = Select-Pipeline -ProductName $submissionName -MappingFile $productRoutingPath
    } else {
        # Project Name provided but not in rules? Route by Project Name (original fallback) or Submission Name?
        # Original code: Select-Pipeline -ProductName $projectName
        # But if user input is simplified, reliance on Project Name is weak.
        # Let's try Project Name first as per original logic, but if that fails, try Submission Name?
        # Original logic was strictly: "else { $pipelineName = Select-Pipeline -ProductName $projectName ... }"
        # If I change this, I change behavior. But user wants simplified input.
        # If user gives ONLY Product ID, then $projectName is empty.
        # So we cover that case above.

        # If user GIVES Project Name, we respect it:
        $infStrategy = Select-Pipeline -ProductName $projectName -MappingFile $productRoutingPath
    }
}

Write-Log "Selected Strategy: $infStrategy"
if ([string]::IsNullOrWhiteSpace($infStrategy)) { throw "Strategy selection failed." }

# Export to Env
"PROJECT_NAME=$projectName" | Out-File -FilePath $env:GITHUB_ENV -Append
"PRODUCT_ID=$productId" | Out-File -FilePath $env:GITHUB_ENV -Append
"SUBMISSION_ID=$submissionId" | Out-File -FilePath $env:GITHUB_ENV -Append
"SUBMISSION_NAME=$submissionName" | Out-File -FilePath $env:GITHUB_ENV -Append
"INF_STRATEGY=$infStrategy" | Out-File -FilePath $env:GITHUB_ENV -Append
"ISSUE_NUMBER=$IssueNumber" | Out-File -FilePath $env:GITHUB_ENV -Append
"REPO_OWNER=$RepoOwner" | Out-File -FilePath $env:GITHUB_ENV -Append
"REPO_NAME=$RepoName" | Out-File -FilePath $env:GITHUB_ENV -Append

Write-Log "Environment variables set."
