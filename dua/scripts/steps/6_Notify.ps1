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
Import-Module (Join-Path $ModulesPath "Teams.psm1")    -Force

Write-Log "Step 6: Notify User"

$outputArtifacts = $env:OUTPUT_ARTIFACTS
$infStrategy     = $env:INF_STRATEGY
$projectName     = $env:PROJECT_NAME
$submissionName  = $env:SUBMISSION_NAME

$files = @()

# Load artifacts from the new variable
if ($outputArtifacts) {
    $artifactList = $outputArtifacts -split ";"
    foreach ($path in $artifactList) {
        if (Test-Path $path) {
            $files += $path
        }
    }
}

# Fallback/Legacy: Check old variables if OUTPUT_ARTIFACTS was empty or didn't catch everything
# (Though step 5 moves them, so these original paths likely don't exist anymore, but good for safety)
if ($env:OUTPUT_DRIVER_ZIP_PATH -and (Test-Path $env:OUTPUT_DRIVER_ZIP_PATH)) {
    if ($files -notcontains $env:OUTPUT_DRIVER_ZIP_PATH) { $files += $env:OUTPUT_DRIVER_ZIP_PATH }
}
if ($env:OUTPUT_HLKX_PATH -and (Test-Path $env:OUTPUT_HLKX_PATH)) {
    if ($files -notcontains $env:OUTPUT_HLKX_PATH) { $files += $env:OUTPUT_HLKX_PATH }
}

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

# Teams Notification (Complete)
if ($submissionName -and $projectName) {
    # Need issue creator for ToUpn
    $issue = Get-Issue -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Token $token
    $creatorEmail = $issue.user.email
    if (-not $creatorEmail) { $creatorEmail = $issue.user.login }

    $ver = Get-ShortVersion -Name $submissionName
    Send-TeamsNotification `
        -EventType "DUA_REQUEST_PROCESS_COMPLETE" `
        -ToUpn $creatorEmail `
        -Project $projectName `
        -Version $ver `
        -IssueUrl $issue.html_url `
        -Message "替换完成，可查看 Issue 记录。可进一步submit"
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
    # Set-IssueState -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -State "closed" -Token $token | Out-Null
    # Write-Log "Issue #$IssueNumber closed."
} else {
    Write-Warning "Missing SubmissionName or ProjectName. Skipping metadata update."
}
