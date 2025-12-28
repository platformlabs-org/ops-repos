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
Import-Module (Join-Path $ModulesPath "Metadata.psm1") -Force

Write-Log "Step 6: Notify User"

$outputHlkx      = $env:OUTPUT_HLKX_PATH
$outputDriverZip = $env:OUTPUT_DRIVER_ZIP_PATH
$infStrategy     = $env:INF_STRATEGY
$projectName     = $env:PROJECT_NAME
$submissionName  = $env:SUBMISSION_NAME

$files = @()
if ($outputDriverZip -and (Test-Path $outputDriverZip)) { $files += $outputDriverZip }
if ($outputHlkx -and (Test-Path $outputHlkx))          { $files += $outputHlkx }

$token = $env:GITHUB_TOKEN
if (-not $token) { $token = $env:GITEA_TOKEN }
if (-not $token) { $token = $env:BOTTOKEN }

if ($files.Count -gt 0) {
    Post-CommentWithAttachments `
      -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber `
      -Body "✅ Processing complete for $infStrategy. Attachments are uploaded to this comment." `
      -FilePaths $files `
      -Token $token | Out-Null
    Write-Log "Comment posted with attachments."
} else {
    Write-Warning "No output files to upload."
    Post-Comment `
      -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber `
      -Body "⚠️ Processing complete for $infStrategy, but no artifacts were generated." `
      -Token $token | Out-Null
}

# Update Issue Metadata (Complete)
if ($submissionName -and $projectName) {
    Update-IssueMetadata `
        -IssueNumber $IssueNumber `
        -RepoOwner $RepoOwner `
        -RepoName $RepoName `
        -Token $token `
        -ProjectName $projectName `
        -SubmissionName $submissionName `
        -Status "Complete" `
        -InfStrategy $infStrategy

    # Close the Issue as well, since PR was merged and process is complete.
    Set-IssueState -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -State "closed" -Token $token | Out-Null
    Write-Log "Issue #$IssueNumber closed."
} else {
    Write-Warning "Missing SubmissionName or ProjectName. Skipping metadata update."
}
