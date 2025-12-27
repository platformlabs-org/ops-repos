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
$submissionId = ""

if ($body -match "(?ms)###\s*Project Name\s*\r?\n\s*(.+?)\s*(\r?\n|$)")  { $projectName  = $matches[1].Trim() }
if ($body -match "(?ms)###\s*Product ID\s*\r?\n\s*(.+?)\s*(\r?\n|$)")    { $productId    = $matches[1].Trim() }
if ($body -match "(?ms)###\s*Submission ID\s*\r?\n\s*(.+?)\s*(\r?\n|$)") { $submissionId = $matches[1].Trim() }

Write-Log "Parsed: Project=$projectName, ProductId=$productId, SubmissionId=$submissionId"

if (-not $projectName) { throw "Missing Project Name." }
if (-not $productId -or -not $submissionId) { throw "Missing required fields." }

# Determine Strategy
$pcToken = Get-PartnerCenterToken `
    -ClientId     $env:PARTNER_CENTER_CLIENT_ID `
    -ClientSecret $env:PARTNER_CENTER_CLIENT_SECRET `
    -TenantId     $env:PARTNER_CENTER_TENANT_ID

$productRoutingPath = Join-Path $RepoRoot "config\mapping\product_routing.json"
$infRulesPath       = Join-Path $RepoRoot "config\inf_patch_rules.json"

$infRules = if (Test-Path -LiteralPath $infRulesPath) { Get-Content -Raw -LiteralPath $infRulesPath | ConvertFrom-Json } else { $null }
$infStrategy = $null

if ($infRules -and $infRules.project -and $infRules.project."$projectName") {
    Write-Log "Project '$projectName' found in inf_patch_rules. Fetching Submission Name."
    $meta = Get-DriverMetadata -ProductId $productId -SubmissionId $submissionId -Token $pcToken
    $submissionName = $meta.name
    Write-Log "Submission Name: $submissionName"
    $infStrategy = Select-Pipeline -ProductName $submissionName -MappingFile $productRoutingPath
} else {
    $infStrategy = Select-Pipeline -ProductName $projectName -MappingFile $productRoutingPath
}

Write-Log "Selected Strategy: $infStrategy"
if ([string]::IsNullOrWhiteSpace($infStrategy)) { throw "Strategy selection failed." }

# Export to Env
"PROJECT_NAME=$projectName" | Out-File -FilePath $env:GITHUB_ENV -Append
"PRODUCT_ID=$productId" | Out-File -FilePath $env:GITHUB_ENV -Append
"SUBMISSION_ID=$submissionId" | Out-File -FilePath $env:GITHUB_ENV -Append
"INF_STRATEGY=$infStrategy" | Out-File -FilePath $env:GITHUB_ENV -Append

Write-Log "Environment variables set."
