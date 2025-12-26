param (
    [Parameter(Mandatory = $true)]
    [string]$repoPath,

    [Parameter(Mandatory = $true)]
    [string]$issueId,

    [Parameter(Mandatory = $true)]
    [string]$accessToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-OutputVar {
    param(
        [string]$Name,
        [string]$Value
    )

    if ($env:GITHUB_OUTPUT) {
        # GitHub / 兼容写法
        "$Name=$Value" >> $env:GITHUB_OUTPUT
    } else {
        # 兼容 Gitea Actions 旧写法
        Write-Host "::set-output name=$Name::$Value"
    }
}

function Update-Issue {
    param(
        [string]$RepoPath,
        [string]$IssueId,
        [string]$AccessToken,
        [string]$DriverProject,
        [string]$DriverVersion,
        [string]$AttachmentName
    )

    $updateUrl = "https://ops.platformlabs.lenovo.com/api/v1/repos/$RepoPath/issues/$IssueId"
    $headers = @{
        'accept'        = 'application/json'
        'Authorization' = "token $AccessToken"
        'Content-Type'  = 'application/json'
    }

    $updatedTitle = "[Driver DUA] [$DriverProject] [$DriverVersion] $AttachmentName"
    $body = @{ "title" = $updatedTitle } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri $updateUrl -Headers $headers -Method Patch -Body $body | Out-Null
        Write-Host "[INFO] Issue title updated to: $updatedTitle"
    } catch {
        throw "[ERROR] Failed to update issue title: $($_.Exception.Message)"
    }
}

function Download-File-Fast {
    param (
        [string]$url,
        [string]$outputPath
    )

    Add-Type -AssemblyName "System.Net.Http"

    $httpClient = [System.Net.Http.HttpClient]::new()
    $httpClient.DefaultRequestHeaders.Add("User-Agent", "PowerShell")

    try {
        $request  = [System.Net.Http.HttpRequestMessage]::new('GET', $url)
        $response = $httpClient.SendAsync(
            $request,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).Result

        if (-not $response.IsSuccessStatusCode) {
            throw "Download request failed with status code: $($response.StatusCode)"
        }

        $contentLength = $response.Content.Headers.ContentLength
        if (-not $contentLength) {
            throw "Content-Length header is missing. Cannot show progress."
        }

        $stream     = $response.Content.ReadAsStreamAsync().Result
        $fileStream = [System.IO.File]::Create($outputPath)

        $buffer    = New-Object byte[] 8192
        $totalRead = 0L
        $lastTime  = Get-Date
        $lastBytes = 0L

        Write-Host "[INFO] Starting download: $url"
        Write-Host "[INFO] Total size: $([math]::Round($contentLength/1MB,2)) MB"

        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
            $totalRead += $read

            $now     = Get-Date
            $elapsed = ($now - $lastTime).TotalSeconds
            if ($elapsed -ge 1) {
                $speed          = ($totalRead - $lastBytes) / $elapsed / 1MB
                $percent        = [math]::Round(($totalRead / $contentLength) * 100, 2)
                $remainingBytes = $contentLength - $totalRead
                $estimatedTime  = if ($speed -gt 0) {
                    [timespan]::FromSeconds($remainingBytes / ($speed * 1MB))
                } else {
                    "-"
                }

                Write-Host "[INFO] Progress: $percent% | Speed: $([math]::Round($speed,2)) MB/s | Remaining: $estimatedTime"

                $lastTime  = $now
                $lastBytes = $totalRead
            }
        }

        $fileStream.Close()
        $stream.Close()

        Write-Host "[SUCCESS] Downloaded file: $outputPath"
    } catch {
        throw "[ERROR] Download failed: $($_.Exception.Message)"
    } finally {
        $httpClient.Dispose()
    }
}

function Get-IssueDetails {
    param (
        [string]$repoPath,
        [string]$issueId,
        [string]$accessToken
    )

    $baseUrl = "https://ops.platformlabs.lenovo.com/api/v1/repos/$repoPath/issues/$issueId"
    $headers = @{
        'accept'        = 'application/json'
        'Authorization' = "token $accessToken"
    }

    try {
        $response = Invoke-WebRequest -Uri $baseUrl -Headers $headers -Method Get
    } catch {
        throw "[ERROR] Error fetching issue details: $($_.Exception.Message)"
    }

    $issueData  = $response.Content | ConvertFrom-Json
    $attachments = $issueData.assets
    if (-not $attachments) {
        throw "[ERROR] No attachments found in the issue."
    }

    $zipAttachment = $attachments |
        Where-Object { $_.name -like "*.zip" } |
        Select-Object -First 1

    if (-not $zipAttachment) {
        throw "[ERROR] No zip attachment found in the issue."
    }

    # Prepare temp directory
    if (-not (Test-Path "temp")) {
        New-Item -ItemType Directory -Path "temp" | Out-Null
    }

    $zipUrl      = "$($zipAttachment.browser_download_url)?access_token=$accessToken"
    $zipFilePath = "temp\$($zipAttachment.name)"

    # Download zip
    Download-File-Fast -url $zipUrl -outputPath $zipFilePath

    # Extract zip
    $extractRoot = "temp\$([System.IO.Path]::GetFileNameWithoutExtension($zipAttachment.name))"
    Expand-Archive -Path $zipFilePath -DestinationPath $extractRoot -Force

    # Locate .hlkx file
    $hlkxFile = Get-ChildItem -Path $extractRoot -Recurse -Filter *.hlkx | Select-Object -First 1
    if (-not $hlkxFile) {
        throw "[ERROR] No .hlkx file found after extraction."
    }

    $hlkxDir = $hlkxFile.DirectoryName

    # Check .inf file exists (确保 zip 包是“hlkx+driver”的结构)
    $infFile = Get-ChildItem -Path $hlkxDir -Recurse -Filter *.inf | Select-Object -First 1
    if (-not $infFile) {
        throw "[ERROR] No .inf file found in extracted files."
    }

    # Extract project name and version from issue body
    $bodyText      = $issueData.body
    $driverProject = [regex]::Match($bodyText, "### Project Name\s+(.*)").Groups[1].Value.Trim()
    $driverVersion = [regex]::Match($bodyText, "### Driver Version\s+(.*)").Groups[1].Value.Trim()

    if (-not $driverProject -or -not $driverVersion) {
        throw "[ERROR] Failed to extract project name or version from issue body."
    }

    # Update issue title
    Update-Issue -RepoPath $repoPath -IssueId $issueId -AccessToken $accessToken `
        -DriverProject $driverProject -DriverVersion $driverVersion -AttachmentName $zipAttachment.name

    # Output hlkx folder 给后续步骤（AutoDUA.ps1）
    Write-OutputVar -Name "hlkx_folder" -Value $hlkxDir
    Write-Host "[INFO] Precheck completed successfully. HLKX Folder: $hlkxDir"
}

try {
    Get-IssueDetails -repoPath $repoPath -issueId $issueId -accessToken $accessToken
} catch {
    Write-Host $_
    exit 1
}
