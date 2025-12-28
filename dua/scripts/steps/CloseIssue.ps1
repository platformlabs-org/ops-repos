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

Write-Log "Closing Issue #$IssueNumber..."

$token = $env:GITHUB_TOKEN
if (-not $token) { $token = $env:GITEA_TOKEN }
if (-not $token) { $token = $env:BOTTOKEN }

if (-not $IssueNumber) {
    Write-Warning "No Issue Number provided. Skipping closure."
    exit 0
}

try {
    # Check current state first? API seems to allow idempotent close.
    Set-IssueState -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -State "closed" -Token $token | Out-Null
    Write-Log "Issue #$IssueNumber closed successfully."
} catch {
    Write-Error "Failed to close issue #$IssueNumber : $_"
    # Don't fail the build just because closing issue failed
}
