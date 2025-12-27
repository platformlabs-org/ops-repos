
function Get-Issue {
    param(
        [string]$Owner,
        [string]$Repo,
        [int]$IssueNumber,
        [string]$Token
    )
    $uri = "$($env:GITHUB_API_URL)/repos/$Owner/$Repo/issues/$IssueNumber"

    $headers = @{
        "Authorization" = "token $Token"
        "Content-Type" = "application/json"
    }

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
    $uri = "$($env:GITHUB_API_URL)/repos/$Owner/$Repo/issues/$IssueNumber/comments"
    $headers = @{
        "Authorization" = "token $Token"
        "Content-Type" = "application/json"
    }
    $payload = @{
        body = $Body
    } | ConvertTo-Json

    return Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $payload
}

function Get-Comments {
     param(
        [string]$Owner,
        [string]$Repo,
        [int]$IssueNumber,
        [string]$Token
    )
    $uri = "$($env:GITHUB_API_URL)/repos/$Owner/$Repo/issues/$IssueNumber/comments"
    $headers = @{
        "Authorization" = "token $Token"
        "Content-Type" = "application/json"
    }
    return Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
}

function Upload-Attachment {
    param(
        [string]$Owner,
        [string]$Repo,
        [int]$IssueNumber,
        [string]$FilePath,
        [string]$Token
    )

    $uri = "$($env:GITHUB_API_URL)/repos/$Owner/$Repo/issues/$IssueNumber/assets"

    # PowerShell 7+ supports -Form
    # We must ensure we are running on PWSH 7+. Windows-latest usually has it.

    $form = @{
        attachment = Get-Item -Path $FilePath
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers @{"Authorization" = "token $Token"} -Form $form
        return $response
    }
    catch {
        Write-Error "Failed to upload attachment: $_"
        throw
    }
}


Export-ModuleMember -Function Get-Issue, Post-Comment, Get-Comments, Upload-Attachment
