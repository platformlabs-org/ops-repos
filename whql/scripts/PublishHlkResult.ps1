param(
    [Parameter(Mandatory)]
    [string]$Repository,
    [Parameter(Mandatory)]
    [string]$IssueNumber,
    [Parameter(Mandatory)]
    [string]$AccessToken,
    [Parameter(Mandatory)]
    [string]$FilePath
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules/OpsApi.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'modules/WhqlCommon.psm1') -Force

if (-not (Test-Path $FilePath)) {
    throw "[Publish] File not found: $FilePath"
}

Write-Host "[Publish] Starting PublishHlkResult.ps1"

$commentText = "HLKX package generated successfully. See attached file."

# 1. Create Comment
$comment = New-OpsIssueComment -Repo $Repository -Number $IssueNumber -Token $AccessToken -BodyText $commentText
if (-not $comment -or -not $comment.id) {
    throw "[Publish] Failed to create comment on issue #$IssueNumber"
}

# 2. Upload Attachment
Upload-OpsCommentAttachment -Repo $Repository -CommentId $comment.id -Token $AccessToken -Path $FilePath

Write-Host "[Publish] Attachment uploaded, updating issue title..."

# 3. Update Title to Done
$issue = Get-OpsIssue -Repo $Repository -Number $IssueNumber -Token $AccessToken
if (-not $issue) {
    throw "[Publish] Failed to load issue #$IssueNumber for title update"
}

$currentTitle   = [string]$issue.title
$builtBaseName  = [IO.Path]::GetFileNameWithoutExtension([string]$FilePath)
$builtBaseName  = $builtBaseName.Trim()

if ([string]::IsNullOrWhiteSpace($builtBaseName)) {
    Write-Host "[Publish] Built file base name is empty, skip title update."
}
else {
    $newTitle     = $null
    $trimmedTitle = $currentTitle.Trim()

    if ($trimmedTitle.StartsWith('[HLKX Sign Request]:', [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($trimmedTitle.StartsWith('[HLKX Done]:', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "[Publish] Title already in 'HLKX Done' state, skip."
        }
        else {
            $newTitle = "[HLKX Done]: $builtBaseName"
        }
    }
    elseif ($trimmedTitle.StartsWith('[Driver WHQL Request]:', [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($trimmedTitle.StartsWith('[WHQL Done]:', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "[Publish] Title already in 'WHQL Done' state, skip."
        }
        else {
            $newTitle = "[WHQL Done]:$builtBaseName"
        }
    }
    else {
        Write-Host "[Publish] Title does not match known request patterns, skip updating."
    }

    if ($null -ne $newTitle -and $newTitle -ne $currentTitle) {
        Set-OpsIssueTitle -Repo $Repository -Number $IssueNumber -Token $AccessToken -Title $newTitle
    }
}

Write-Host "[Publish] PublishHlkResult.ps1 finished."
