$ErrorActionPreference = "Stop"

function Get-GiteaApiBase {
    # Prefer explicit API base
    $base = $env:GITEA_API_URL
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:GITHUB_API_URL }

    # If only server url exists, derive api base
    if ([string]::IsNullOrWhiteSpace($base)) {
        $server = $env:GITEA_SERVER_URL
        if ([string]::IsNullOrWhiteSpace($server)) { $server = $env:GITHUB_SERVER_URL }
        if (-not [string]::IsNullOrWhiteSpace($server)) {
            $base = $server.TrimEnd('/') + "/api/v1"
        }
    }

    if ([string]::IsNullOrWhiteSpace($base)) {
        throw "Gitea API base URL is missing. Set env GITEA_API_URL (recommended) or GITEA_SERVER_URL. Expected like: https://<host>/api/v1"
    }

    $base = $base.TrimEnd('/')

    # Ensure /api/v1 suffix for Gitea
    if ($base -notmatch "/api/v\d+$") {
        $base = $base + "/api/v1"
    }

    return $base
}

function New-GiteaHeaders {
    param([Parameter(Mandatory)][string]$Token)
    return @{
        "Authorization" = "token $Token"
        "Accept"        = "application/json"
    }
}

function Get-Issue {
    param(
        [string]$Owner,
        [string]$Repo,
        [int]$IssueNumber,
        [string]$Token
    )

    $api = Get-GiteaApiBase
    $uri = "$api/repos/$Owner/$Repo/issues/$IssueNumber"
    Write-Host "[Gitea] GET $uri"

    $headers = New-GiteaHeaders -Token $Token
    return Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
}

function Post-Comment {
    param(
        [string]$Owner,
        [string]$Repo,
        [int]$IssueNumber,
        [string]$Body,
        [string]$Token
    )

    $api = Get-GiteaApiBase
    # Gitea: POST /repos/{owner}/{repo}/issues/{index}/comments
    $uri = "$api/repos/$Owner/$Repo/issues/$IssueNumber/comments"
    Write-Host "[Gitea] POST $uri"

    $headers = New-GiteaHeaders -Token $Token
    $headers["Content-Type"] = "application/json"

    $payload = @{ body = $Body } | ConvertTo-Json

    try {
        return Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $payload
    } catch {
        throw "Post-Comment failed. URI=$uri :: $($_.Exception.Message)"
    }
}

function Get-Comments {
    param(
        [string]$Owner,
        [string]$Repo,
        [int]$IssueNumber,
        [string]$Token
    )

    $api = Get-GiteaApiBase
    $uri = "$api/repos/$Owner/$Repo/issues/$IssueNumber/comments"
    Write-Host "[Gitea] GET $uri"

    $headers = New-GiteaHeaders -Token $Token
    return Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
}

# (可选) Issue级别附件：POST /repos/{owner}/{repo}/issues/{index}/assets
function Upload-IssueAttachment {
    param(
        [string]$Owner,
        [string]$Repo,
        [int]$IssueNumber,
        [string]$FilePath,
        [string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($FilePath)) { throw "Upload-IssueAttachment: FilePath is empty." }
    if (-not (Test-Path -LiteralPath $FilePath)) { throw "Upload-IssueAttachment: File not found: $FilePath" }

    $api = Get-GiteaApiBase
    $uri = "$api/repos/$Owner/$Repo/issues/$IssueNumber/assets"
    Write-Host "[Gitea] POST (issue asset) $uri"
    Write-Host "[Gitea]   file: $FilePath"

    $headers = New-GiteaHeaders -Token $Token

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $form = @{ attachment = Get-Item -LiteralPath $FilePath }
        return Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Form $form
    }

    # PS 5.1 fallback
    Add-Type -AssemblyName System.Net.Http

    $client = [System.Net.Http.HttpClient]::new()
    $client.DefaultRequestHeaders.Add("Authorization", "token $Token")
    $client.DefaultRequestHeaders.Add("Accept", "application/json")

    $content = [System.Net.Http.MultipartFormDataContent]::new()

    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    # 关键：用 ::new 或 -ArgumentList (, $bytes) 避免数组展开
    $fileContent = [System.Net.Http.ByteArrayContent]::new($bytes)

    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $content.Add($fileContent, "attachment", $fileName)

    $resp = $client.PostAsync($uri, $content).GetAwaiter().GetResult()
    $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()

    if (-not $resp.IsSuccessStatusCode) {
        throw "Upload-IssueAttachment failed: HTTP $([int]$resp.StatusCode) $($resp.ReasonPhrase) :: $body"
    }
    return ($body | ConvertFrom-Json)

}

# ✅ Comment级别附件：POST /repos/{owner}/{repo}/issues/comments/{id}/assets
function Upload-CommentAttachment {
    param(
        [string]$Owner,
        [string]$Repo,
        [int]$CommentId,
        [string]$FilePath,
        [string]$Token
    )

    if ($CommentId -le 0) { throw "Invalid CommentId: $CommentId" }
    if ([string]::IsNullOrWhiteSpace($FilePath)) { throw "Upload-CommentAttachment: FilePath is empty." }
    if (-not (Test-Path -LiteralPath $FilePath)) { throw "Upload-CommentAttachment: File not found: $FilePath" }

    $api = Get-GiteaApiBase
    $uri = "$api/repos/$Owner/$Repo/issues/comments/$CommentId/assets"
    Write-Host "[Gitea] POST (comment asset) $uri"
    Write-Host "[Gitea]   file: $FilePath"

    $headers = New-GiteaHeaders -Token $Token

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        # multipart/form-data: field name = attachment
        $form = @{ attachment = Get-Item -LiteralPath $FilePath }
        return Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Form $form
    }

    # PS 5.1 fallback
    Add-Type -AssemblyName System.Net.Http

    $client = [System.Net.Http.HttpClient]::new()
    $client.DefaultRequestHeaders.Add("Authorization", "token $Token")
    $client.DefaultRequestHeaders.Add("Accept", "application/json")
    
    $content = [System.Net.Http.MultipartFormDataContent]::new()
    
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $fileContent = [System.Net.Http.ByteArrayContent]::new($bytes)
    
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $content.Add($fileContent, "attachment", $fileName)
    
    $resp = $client.PostAsync($uri, $content).GetAwaiter().GetResult()
    $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    
    if (-not $resp.IsSuccessStatusCode) {
        throw "Upload-CommentAttachment failed: HTTP $([int]$resp.StatusCode) $($resp.ReasonPhrase) :: $body"
    }
    return ($body | ConvertFrom-Json)

}

# ✅ 一步：先建comment，再把文件作为该comment附件上传
function Post-CommentWithAttachments {
    param(
        [string]$Owner,
        [string]$Repo,
        [int]$IssueNumber,
        [string]$Body,
        [string[]]$FilePaths,
        [string]$Token
    )

    $comment = Post-Comment -Owner $Owner -Repo $Repo -IssueNumber $IssueNumber -Body $Body -Token $Token
    if (-not $comment) { throw "Post-CommentWithAttachments: comment creation returned empty response." }

    $commentId = 0
    if ($comment.PSObject.Properties.Name -contains "id") { $commentId = [int]$comment.id }
    if ($commentId -le 0) { throw "Post-CommentWithAttachments: missing/invalid comment.id in response." }

    $paths = @()
    foreach ($p in $FilePaths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Warning "[Gitea] skip missing file: $p"
            continue
        }
        $paths += $p
    }

    $uploads = @()
    foreach ($p in $paths) {
        $uploads += Upload-CommentAttachment -Owner $Owner -Repo $Repo -CommentId $commentId -FilePath $p -Token $Token
    }

    return [pscustomobject]@{
        Comment   = $comment
        CommentId = $commentId
        Uploads   = $uploads
    }
}

Export-ModuleMember -Function `
    Get-Issue, Post-Comment, Get-Comments, `
    Upload-IssueAttachment, Upload-CommentAttachment, Post-CommentWithAttachments
