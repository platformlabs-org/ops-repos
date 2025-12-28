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

Write-Log "Checking for Open PRs related to Issue #$IssueNumber..."

$token = $env:GITHUB_TOKEN
if (-not $token) { $token = $env:BOTTOKEN }

# Expected branch pattern
# dua/issue-$IssueNumber/patch
# Or even checking if 'dua/issue-$IssueNumber' is in the branch name

$prs = Get-PullRequests -Owner $RepoOwner -Repo $RepoName -State "open" -Token $token

foreach ($pr in $prs) {
    # Check if PR head or base branch relates to this issue
    # HEAD: dua/issue-123-xxxxx/patch
    # BASE: dua/issue-123-xxxxx/base

    $head = $pr.head.ref
    $base = $pr.base.ref

    if ($head -match "dua/issue-$IssueNumber" -or $base -match "dua/issue-$IssueNumber") {
        Write-Log "Found related Open PR: #$($pr.number) ($($pr.title)) - Closing it."

        # Post Comment
        Post-Comment `
            -Owner $RepoOwner -Repo $RepoName -IssueNumber $pr.number `
            -Body "Auto-closing PR because the linked Issue #$IssueNumber was closed." `
            -Token $token | Out-Null

        # Close PR
        Set-PullRequestState -Owner $RepoOwner -Repo $RepoName -Index $pr.number -State "closed" -Token $token | Out-Null
        Write-Log "PR #$($pr.number) closed."
    }
}
