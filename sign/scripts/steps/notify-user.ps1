Import-Module "$PSScriptRoot/../modules/OpsApi.psm1" -Force

$repo = $env:GITEA_REPO
if (-not $repo) { $repo = "PE/SIGN" }
$issueId = $env:ISSUE_ID
$fileUrl = $env:SIGNED_FILE_URL
$fileName = $env:SIGNED_FILE_NAME

# Placeholder URL as requested
$notifyUrl = "http://placeholder-notification-url"

if (-not $issueId) {
    Write-Warning "ISSUE_ID not set, skipping notification."
    exit 0
}

if (-not $fileUrl) {
    Write-Warning "SIGNED_FILE_URL not set, skipping notification."
    exit 0
}

Write-Host "Fetching issue details for ID: $issueId"
try {
    $issue = Get-IssueDetail -RepoPath $repo -IssueID $issueId
    $userEmail = $issue.user.email
    $username = $issue.user.login

    # If email is null or empty, try to fetch user profile
    if (-not $userEmail) {
        Write-Host "Email not found in issue detail. Fetching user profile for: $username"

        $tokens = Get-Tokens
        $apiBase = Get-GiteaApiUrl
        $userUrl = "$apiBase/users/$username"
        $headers = @{
            'accept'        = 'application/json'
            'Authorization' = "token $($tokens.GiteaToken)"
        }
        try {
            $userProfile = Invoke-RestMethod -Uri $userUrl -Headers $headers
            $userEmail = $userProfile.email
        } catch {
            Write-Warning "Failed to fetch user profile: $_"
        }
    }

    if (-not $userEmail) {
        Write-Warning "Could not determine user email for user '$username'. Skipping notification."
        exit 0
    }

    Write-Host "Sending notification to: $userEmail"

    $payload = @{
        to = $userEmail
        url = $fileUrl
        issue = $issueId
        fileName = $fileName
    } | ConvertTo-Json

    Write-Host "Payload: $payload"

    try {
        Invoke-RestMethod -Method Post -Uri $notifyUrl -Body $payload -ContentType "application/json"
        Write-Host "✅ Notification sent."
    } catch {
        Write-Warning "⚠️ Failed to send notification (likely due to placeholder URL): $_"
    }

} catch {
    Write-Error "❌ Error in notification step: $_"
    exit 1
}
