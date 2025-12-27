param(
    [string]$IssueNumber
)

$ErrorActionPreference = "Stop"

if (-not $IssueNumber) {
    # Try to get from Env
    $IssueNumber = $env:ISSUE_NUMBER
}

if (-not $IssueNumber) {
    Write-Warning "No Issue Number provided. Skipping cleanup."
    exit 0
}

Write-Host "Starting Cleanup for Issue #$IssueNumber"

# 1. Cleanup Cache
$cacheDir = "\\nas\labs\RUNNER\tmp\issue-$IssueNumber"
if (Test-Path $cacheDir) {
    Write-Host "Cleaning up cache: $cacheDir"
    Remove-Item -LiteralPath $cacheDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "Cache not found or already deleted: $cacheDir"
}

# 2. Cleanup Branches
# Needs git authentication
git config --global user.email "bot@example.com"
git config --global user.name "DUA Bot"

$baseBranch = "dua/issue-$IssueNumber/base"
$patchBranch = "dua/issue-$IssueNumber/patch"

Write-Host "Deleting branches: $baseBranch, $patchBranch"

# Push delete to origin
try {
    git push origin --delete $baseBranch --force 2>&1 | Write-Host
} catch {
    Write-Warning "Failed to delete $baseBranch (maybe already deleted?)"
}

try {
    git push origin --delete $patchBranch --force 2>&1 | Write-Host
} catch {
    Write-Warning "Failed to delete $patchBranch (maybe already deleted?)"
}

Write-Host "Cleanup complete."
