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

Write-Log "Step 1: Parse Request Info"

$token = $env:GITHUB_TOKEN
if (-not $token) { $token = $env:GITEA_TOKEN }
if (-not $token) { $token = $env:BOTTOKEN }
if (-not $token) { throw "Missing API token." }

$issue = Get-Issue -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Token $token
$body = $issue.body

$productId = ""
$submissionId = ""
$jsonBody = ""

# Parse Markdown from Template
# Template output is like:
# ### Product ID
# <value>

if ($body -match "(?ms)###\s*Product ID\s*\r?\n\s*(.+?)\s*(\r?\n|###|$)") { $productId = $matches[1].Trim() }
if ($body -match "(?ms)###\s*Submission ID\s*\r?\n\s*(.+?)\s*(\r?\n|###|$)") { $submissionId = $matches[1].Trim() }
if ($body -match "(?ms)###\s*Request Body \(JSON\)\s*\r?\n\s*(.+?)\s*(\r?\n|###|$)") { $jsonBody = $matches[1].Trim() }

# Fallback: Try to find standalone JSON block if template parsing fails or user just pasted JSON
if (-not $jsonBody -and $body -match "(?ms)```json\s*(.+?)\s*```") {
    $jsonBody = $matches[1].Trim()
}

Write-Log "Product ID: $productId"
Write-Log "Submission ID: $submissionId"

if (-not $productId) { throw "Product ID not found." }
if (-not $submissionId) { throw "Submission ID not found." }
if (-not $jsonBody) { throw "Request Body JSON not found." }

# Validate JSON
try {
    $null = $jsonBody | ConvertFrom-Json
} catch {
    throw "Invalid JSON format in Request Body: $_"
}

# Export to ENV
"PRODUCT_ID=$productId" | Out-File -FilePath $env:GITHUB_ENV -Append
"SUBMISSION_ID=$submissionId" | Out-File -FilePath $env:GITHUB_ENV -Append

# For multiline JSON, we need to be careful exporting to ENV in Actions.
# We will save it to a file and pass the path.
# Since we need it in the next step, using a fixed temp location or workspace file is best.
# We'll use a file in the workspace or a temp dir that persists (if same runner).
# But separate steps might not share temp unless defined.
# Gitea Actions (like GH Actions) share the workspace.
# Let's write to a file in the current directory (workspace).
$jsonPath = "request_body.json"
$jsonBody | Out-File -FilePath $jsonPath -Encoding utf8
"REQUEST_BODY_PATH=$jsonPath" | Out-File -FilePath $env:GITHUB_ENV -Append

Write-Log "Parsed successfully. JSON body saved to $jsonPath"
