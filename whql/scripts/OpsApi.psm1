# OpsApi.psm1
$ErrorActionPreference = 'Stop'

# 统一的 base url
$Script:BaseUrl = "https://ops.platformlabs.lenovo.com/api/v1/repos"

function New-OpsAuthHeader {
    param(
        [Parameter(Mandatory)]
        [string]$Token,
        [string]$Accept = 'application/json'
    )

    return @{
        'accept'        = $Accept
        'Authorization' = "token $Token"
    }
}

function Get-OpsIssue {
    param(
        [Parameter(Mandatory)]
        [string]$Repo,
        [Parameter(Mandatory)]
        [string]$Number,
        [Parameter(Mandatory)]
        [string]$Token
    )

    $url = "$Script:BaseUrl/$Repo/issues/$Number"
    $headers = New-OpsAuthHeader -Token $Token

    Write-Host "[OpsApi] GET issue $url"
    $response = Invoke-WebRequest -Uri $url -Headers $headers -Method Get
    return $response.Content | ConvertFrom-Json
}

function Invoke-OpsDownloadFile {
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [Parameter(Mandatory)]
        [string]$TargetPath,
        [Parameter(Mandatory)]
        [string]$Token
    )

    $headers = New-OpsAuthHeader -Token $Token -Accept 'application/octet-stream'

    Write-Host "[OpsApi] Downloading $Url -> $TargetPath"
    Invoke-WebRequest -Uri $Url -Headers $headers -OutFile $TargetPath
}

function New-OpsIssueComment {
    param(
        [Parameter(Mandatory)]
        [string]$Repo,
        [Parameter(Mandatory)]
        [string]$Number,
        [Parameter(Mandatory)]
        [string]$Token,
        [Parameter(Mandatory)]
        [string]$BodyText
    )

    $url = "$Script:BaseUrl/$Repo/issues/$Number/comments"
    $headers = New-OpsAuthHeader -Token $Token

    $body = @{ body = $BodyText } | ConvertTo-Json

    Write-Host "[OpsApi] POST comment on issue #$Number"
    $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Post -Body $body -ContentType "application/json"
    return $resp
}

function Upload-OpsCommentAttachment {
    param(
        [Parameter(Mandatory)]
        [string]$Repo,
        [Parameter(Mandatory)]
        [int]$CommentId,
        [Parameter(Mandatory)]
        [string]$Token,
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "[OpsApi] File not found: $Path"
    }

    Add-Type -AssemblyName System.Net.Http

    $client = New-Object System.Net.Http.HttpClient
    $client.DefaultRequestHeaders.Add("User-Agent", "PowerShellUploader")
    $client.DefaultRequestHeaders.Authorization = "token $Token"

    $uploadUrl = "$Script:BaseUrl/$Repo/issues/comments/$CommentId/assets"

    $fileName   = [IO.Path]::GetFileName($Path)
    $fileStream = [IO.File]::OpenRead($Path)

    $content      = New-Object System.Net.Http.MultipartFormDataContent
    $fileContent  = New-Object System.Net.Http.StreamContent($fileStream)
    $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/octet-stream")
    $content.Add($fileContent, "attachment", $fileName)

    Write-Host "[OpsApi] Uploading attachment $fileName to comment $CommentId"

    try {
        $response = $client.PostAsync($uploadUrl, $content).Result
        $result   = $response.Content.ReadAsStringAsync().Result
        Write-Host "[OpsApi] Upload response status: $($response.StatusCode)"
        Write-Host "[OpsApi] Upload response body  : $result"
    }
    finally {
        $fileStream.Dispose()
        $client.Dispose()
    }
}

function Set-OpsIssueTitle {
    param(
        [Parameter(Mandatory)]
        [string]$Repo,
        [Parameter(Mandatory)]
        [string]$Number,
        [Parameter(Mandatory)]
        [string]$Token,
        [Parameter(Mandatory)]
        [string]$Title
    )

    $url = "$Script:BaseUrl/$Repo/issues/$Number"
    $headers = New-OpsAuthHeader -Token $Token

    $body = @{ title = $Title } | ConvertTo-Json

    Write-Host "[OpsApi] PATCH issue #$Number title -> $Title"
    Invoke-RestMethod -Uri $url -Headers $headers -Method Patch -Body $body -ContentType "application/json" | Out-Null
}

Export-ModuleMember -Function `
    Get-OpsIssue, `
    Invoke-OpsDownloadFile, `
    New-OpsIssueComment, `
    Upload-OpsCommentAttachment, `
    Set-OpsIssueTitle
