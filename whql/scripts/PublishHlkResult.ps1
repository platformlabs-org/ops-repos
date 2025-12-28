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

Import-Module (Join-Path $PSScriptRoot 'modules/OpsApi.psm1')
Import-Module (Join-Path $PSScriptRoot 'modules/WhqlCommon.psm1')

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

    # Check current label to decide title format
    # But issue labels are arrays, let's look at issue state.
    # Actually, we can infer mode from the filename or just apply the logic requested.

    # User Request:
    # [WHQL Done]:Lenovo Dispatcher-3.2.100.5-AMD64-1228014244
    # [HLKX Signed]{OriginalFileName}

    # RunHlkJob names:
    # WHQL: "$DriverProject-$DriverVersion-$Architecture-$timestamp"
    # SIGN: "${safeBaseName}_Signed.hlkx"

    # If it ends with _Signed, it's SIGN mode (heuristic)
    if ($builtBaseName.EndsWith("_Signed")) {
        # Extract Original Name: Remove _Signed
        $originalName = $builtBaseName.Substring(0, $builtBaseName.Length - 7)
        $newTitle = "[HLKX Signed] $originalName"
    }
    else {
        # WHQL Mode
        # The filename IS the format we want: "Lenovo Dispatcher-3.2.100.5-AMD64-1228014244"
        # We just need to prepend "[WHQL Done]:"
        $newTitle = "[WHQL Done]:$builtBaseName"
    }

    if ($null -ne $newTitle -and $newTitle -ne $currentTitle) {
        Set-OpsIssueTitle -Repo $Repository -Number $IssueNumber -Token $AccessToken -Title $newTitle
    }
}

Write-Host "[Publish] PublishHlkResult.ps1 finished."
