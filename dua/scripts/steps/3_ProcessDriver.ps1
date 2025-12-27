param()

$ErrorActionPreference = "Stop"
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"
$RepoRoot    = Resolve-Path (Join-Path $ScriptRoot "..\..") | Select-Object -ExpandProperty Path

Import-Module (Join-Path $ModulesPath "Common.psm1")   -Force
Import-Module (Join-Path $ModulesPath "InfPatch.psm1") -Force
Import-Module (Join-Path $ModulesPath "Gitea.psm1")    -Force

Write-Log "Step 3: Process Driver (Git Workflow)"

$driverZip    = $env:DRIVER_ZIP_PATH
$infStrategy  = $env:INF_STRATEGY
$projectName  = $env:PROJECT_NAME
$issueNumber  = $env:ISSUE_NUMBER
$repoOwner    = $env:REPO_OWNER
$repoName     = $env:REPO_NAME
$submitter    = $env:SUBMITTER
$token        = $env:GITHUB_TOKEN

if (-not $driverZip -or -not $infStrategy -or -not $issueNumber -or -not $token) {
    throw "Missing input env vars (DRIVER_ZIP_PATH, INF_STRATEGY, ISSUE_NUMBER, GITHUB_TOKEN)."
}

# Pipeline Config
$pipelineConfigPath = Join-Path $RepoRoot "config\pipeline.json"
if (-not (Test-Path $pipelineConfigPath)) { throw "Pipeline config not found: $pipelineConfigPath" }
$pipelineConfig = Get-Content -Raw -LiteralPath $pipelineConfigPath | ConvertFrom-Json

# Setup Work Git Repo
$workDir = Join-Path $env:GITHUB_WORKSPACE "work_git"
if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }
New-Item -ItemType Directory -Path $workDir | Out-Null

$serverUrl = $env:GITHUB_SERVER_URL
if (-not $serverUrl) { $serverUrl = "https://gitea.example.com" }
$cloneUrl = "$serverUrl/$repoOwner/$repoName.git".Replace("://", "://$($repoOwner):$($token)@")

Write-Log "Cloning repo to work_git..."
Set-Location $workDir
git clone $cloneUrl .
git config user.name "DUA Bot"
git config user.email "dua-bot@localhost"

# Branch Names
$baseBranch  = "dua/issue-$issueNumber/base"
$patchBranch = "dua/issue-$issueNumber/patch"

# 1. Prepare Base Branch (Original INFs)
Write-Log "Preparing Base Branch: $baseBranch"
git checkout -b $baseBranch

# Unzip Driver to a temp folder first to filter files
$tempExtract = Join-Path $env:GITHUB_WORKSPACE "temp_extract"
if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
Expand-Archive-Force -Path $driverZip -DestinationPath $tempExtract

# Copy ONLY INFs to work_git
$infFiles = Get-ChildItem -Path $tempExtract -Recurse -Filter "*.inf"
foreach ($inf in $infFiles) {
    $relPath = [System.IO.Path]::GetRelativePath($tempExtract, $inf.FullName)
    $destPath = Join-Path $workDir $relPath
    $destDir = Split-Path -Parent $destPath
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item -LiteralPath $inf.FullName -Destination $destPath -Force
}

# Delete unwanted
$badInfs = Get-ChildItem -Path $workDir -Recurse -File -Filter "iigd_ext_d.inf" -ErrorAction SilentlyContinue
if ($badInfs) {
    foreach ($f in $badInfs) { Remove-Item -LiteralPath $f.FullName -Force }
}

git add .
git commit -m "Original INFs for Issue #$issueNumber"
git push origin $baseBranch --force

# 2. Prepare Patch Branch (Modified INFs)
Write-Log "Preparing Patch Branch: $patchBranch"
git checkout -b $patchBranch

# Find INF to patch in work_git
$locatorConfigPath = Join-Path $RepoRoot "config\mapping\inf_locator.json"
$locatorConfig = Get-Content -Raw -LiteralPath $locatorConfigPath | ConvertFrom-Json
$infPattern = $locatorConfig.locators.$infStrategy.filename_pattern

if (-not $infPattern) { throw "inf_locator.json missing filename_pattern for '$infStrategy'" }

$infFile = Get-ChildItem -Path $workDir -Recurse -File -Filter $infPattern -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $infFile) {
    $infFile = Get-ChildItem -Path $workDir -Recurse -File | Where-Object { $_.Name -match $infPattern } | Select-Object -First 1
}
if (-not $infFile) { throw "INF file matching '$infPattern' not found in work_git." }

Write-Log "Patching INF: $($infFile.FullName)"
$infRulesPath = Join-Path $RepoRoot "config\inf_patch_rules.json"

if (Test-Path -LiteralPath $infRulesPath) {
    Patch-Inf-Advanced -InfPath $infFile.FullName -ConfigPath $infRulesPath -ProjectName $projectName
} else {
    Write-Warning "Advanced config not found. Skipping patch."
}

git add .
git commit -m "Modified INFs for Issue #$issueNumber"
git push origin $patchBranch --force

# 3. Create Pull Request
Write-Log "Creating Pull Request..."
$apiUrl = "$($env:GITHUB_API_URL)/repos/$repoOwner/$repoName/pulls"

$body = @{
    head      = $patchBranch
    base      = $baseBranch
    title     = "DUA: INF Modification for Issue #$issueNumber"
    body      = "Automated PR for DUA INF modifications.`n`nOriginal Issue: #$issueNumber`n`nPlease review and merge to proceed with HLKX submission."
    assignees = @($submitter)
}

$jsonBody = $body | ConvertTo-Json -Depth 10
$prUrl = ""

try {
    $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Body $jsonBody -ContentType "application/json" -Headers @{ "Authorization" = "token $token" }
    $prUrl = $response.html_url
    Write-Log "PR Created: $prUrl"
} catch {
    Write-Warning "Failed to create PR: $_"
    # Try to find existing PR? For now, we assume user can find it if it failed because it exists.
}

# 4. Notify User on Issue
if ($prUrl) {
    $commentBody = "### DUA Preparation Complete`n`nA Pull Request has been created with the proposed INF modifications.`n`n👉 **[Review and Merge PR]($prUrl)**`n`nOnce merged, the submission process will continue automatically."
    try {
        Post-Comment -Owner $repoOwner -Repo $repoName -IssueNumber $issueNumber -Body $commentBody -Token $token
        Write-Log "Posted notification to Issue #$issueNumber"
    } catch {
        Write-Warning "Failed to post comment to issue: $_"
    }
}

Write-Log "Step 3 Complete. Waiting for PR Merge."
