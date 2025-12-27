param(
    [string]$IssueNumber,
    [string]$BaseBranch,
    [string]$PatchBranch
)

$ErrorActionPreference = "Stop"

if (-not $IssueNumber) {
    # Try to get from Env
    $IssueNumber = $env:ISSUE_NUMBER
}

if (-not $IssueNumber) {
    Write-Warning "No Issue Number provided. Skipping cache cleanup."
} else {
    Write-Host "Starting Cache Cleanup for Issue #$IssueNumber"
    # 1. Cleanup Cache
    $cacheDir = "\\nas\labs\RUNNER\tmp\issue-$IssueNumber"
    if (Test-Path $cacheDir) {
        Write-Host "Cleaning up cache: $cacheDir"
        Remove-Item -LiteralPath $cacheDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Cache not found or already deleted: $cacheDir"
    }
}

# 2. Cleanup Branches
if (-not $BaseBranch -and -not $PatchBranch) {
    Write-Warning "No branch names provided. Skipping branch cleanup."
    exit 0
}

# Needs git authentication
git config --global user.email "bot@example.com"
git config --global user.name "DUA Bot"

Write-Host "Deleting branches..."

if ($BaseBranch) {
    Write-Host "Deleting Base Branch: $BaseBranch"
    try {
        git push origin --delete $BaseBranch --force 2>&1 | Write-Host
    } catch {
        Write-Warning "Failed to delete $BaseBranch (maybe already deleted?)"
    }
}

if ($PatchBranch) {
    Write-Host "Deleting Patch Branch: $PatchBranch"
    try {
        git push origin --delete $PatchBranch --force 2>&1 | Write-Host
    } catch {
        Write-Warning "Failed to delete $PatchBranch (maybe already deleted?)"
    }
}

Write-Host "Cleanup complete."
