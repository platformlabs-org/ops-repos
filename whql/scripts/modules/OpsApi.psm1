$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -Force

# -------- Private Helpers --------

function Get-BaseUrl {
    try {
        $cfg = Get-WhqlConfig
        return $cfg.BaseUrl
    } catch {
        return "https://ops.platformlabs.lenovo.com/api/v1/repos"
    }
}

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

function Invoke-WithRetry {
    param(
        [ScriptBlock]$Action,
        [int]$MaxRetries = 3,
        [int]$DelaySeconds = 2
    )

    $attempt = 0
    while ($true) {
        try {
            return & $Action
        }
        catch {
            $attempt++
            $msg = $_.Exception.Message
            if ($attempt -ge $MaxRetries) {
                Write-Host "::error::[OpsApi] Failed after $MaxRetries attempts: $msg"
                throw $_
            }
            Write-Host "[OpsApi] Attempt $attempt failed: $msg. Retrying in $DelaySeconds seconds..."
            Start-Sleep -Seconds $DelaySeconds
            $DelaySeconds *= 2
        }
    }
}

# -------- Public Functions --------

function Get-OpsIssue {
    param(
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] [string]$Number,
        [Parameter(Mandatory)] [string]$Token
    )

    $baseUrl = Get-BaseUrl
    $url = "$baseUrl/$Repo/issues/$Number"
    $headers = New-OpsAuthHeader -Token $Token

    Write-Host "[OpsApi] GET issue $url"

    Invoke-WithRetry -Action {
        $response = Invoke-WebRequest -Uri $url -Headers $headers -Method Get
        return $response.Content | ConvertFrom-Json
    }
}

function Get-OpsIssueComments {
    param(
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] [string]$Number,
        [Parameter(Mandatory)] [string]$Token
    )

    $baseUrl = Get-BaseUrl
    $url = "$baseUrl/$Repo/issues/$Number/comments"
    $headers = New-OpsAuthHeader -Token $Token

    Write-Host "[OpsApi] GET comments for issue $Number"

    Invoke-WithRetry -Action {
        $response = Invoke-WebRequest -Uri $url -Headers $headers -Method Get
        return $response.Content | ConvertFrom-Json
    }
}

function Invoke-OpsDownloadFile {
    param(
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$TargetPath,
        [Parameter(Mandatory)] [string]$Token
    )

    $headers = New-OpsAuthHeader -Token $Token -Accept 'application/octet-stream'
    Write-Host "[OpsApi] Downloading $Url -> $TargetPath"

    # Invoke-WebRequest -OutFile doesn't return content, so we just run it.
    Invoke-WithRetry -Action {
        Invoke-WebRequest -Uri $Url -Headers $headers -OutFile $TargetPath
    }
}

function New-OpsIssueComment {
    param(
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] [string]$Number,
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$BodyText
    )

    $baseUrl = Get-BaseUrl
    $url = "$baseUrl/$Repo/issues/$Number/comments"
    $headers = New-OpsAuthHeader -Token $Token
    $body = @{ body = $BodyText } | ConvertTo-Json

    Write-Host "[OpsApi] POST comment on issue #$Number"

    Invoke-WithRetry -Action {
        Invoke-RestMethod -Uri $url -Headers $headers -Method Post -Body $body -ContentType "application/json"
    }
}

function Upload-OpsCommentAttachment {
    param(
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] [int]$CommentId,
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "[OpsApi] File not found: $Path"
    }

    $baseUrl = Get-BaseUrl
    $uploadUrl = "$baseUrl/$Repo/issues/comments/$CommentId/assets"

    Write-Host "[OpsApi] Uploading attachment $([IO.Path]::GetFileName($Path)) to comment $CommentId"

    Invoke-WithRetry -Action {
        # Using .NET HttpClient for multipart upload
        Add-Type -AssemblyName System.Net.Http
        $client = New-Object System.Net.Http.HttpClient
        $client.DefaultRequestHeaders.Add("User-Agent", "PowerShellUploader")
        $client.DefaultRequestHeaders.Authorization = "token $Token"

        try {
            $fileStream = [IO.File]::OpenRead($Path)
            $content = New-Object System.Net.Http.MultipartFormDataContent
            $fileContent = New-Object System.Net.Http.StreamContent($fileStream)
            $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/octet-stream")
            $content.Add($fileContent, "attachment", [IO.Path]::GetFileName($Path))

            $response = $client.PostAsync($uploadUrl, $content).Result
            if (-not $response.IsSuccessStatusCode) {
                throw "Upload failed with status code $($response.StatusCode)"
            }
            $result = $response.Content.ReadAsStringAsync().Result
            Write-Host "[OpsApi] Upload success: $result"
            return $result
        }
        finally {
            if ($fileStream) { $fileStream.Dispose() }
            if ($client) { $client.Dispose() }
        }
    }
}

function Set-OpsIssueTitle {
    param(
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] [string]$Number,
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$Title
    )

    $baseUrl = Get-BaseUrl
    $url = "$baseUrl/$Repo/issues/$Number"
    $headers = New-OpsAuthHeader -Token $Token
    $body = @{ title = $Title } | ConvertTo-Json

    Write-Host "[OpsApi] PATCH issue #$Number title -> $Title"

    Invoke-WithRetry -Action {
        Invoke-RestMethod -Uri $url -Headers $headers -Method Patch -Body $body -ContentType "application/json"
    }
}

Export-ModuleMember -Function `
    Get-OpsIssue, `
    Get-OpsIssueComments, `
    Invoke-OpsDownloadFile, `
    New-OpsIssueComment, `
    Upload-OpsCommentAttachment, `
    Set-OpsIssueTitle
