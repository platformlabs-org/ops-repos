param (
    [string]$repository,    # Gitea repository
    [string]$issueNumber,   # Gitea issue number
    [string]$accessToken    # Access token
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseUrl = "https://ops.platformlabs.lenovo.com/api/v1/repos"

function Add-Comment {
    param (
        [string]$repo,
        [string]$issueNumber,
        [string]$commentBody
    )

    $url = "$baseUrl/$repo/issues/$issueNumber/comments"
    $headers = @{
        'accept'        = 'application/json'
        'Authorization' = "token $accessToken"
    }
    $body = @{ "body" = $commentBody } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body -ContentType "application/json"
        Write-Host "[SUCCESS] Comment added to issue #$issueNumber."
        return $response
    } catch {
        Write-Host "[ERROR] Failed to add comment: $($_.Exception.Message)"
        return $null
    }
}

function Upload-Attachment {
    param (
        [string]$repo,
        [string]$commentId,
        [string]$filePath
    )

    $url      = "$baseUrl/$repo/issues/comments/$commentId/assets?access_token=$accessToken"
    $boundary = [System.Guid]::NewGuid().ToString()
    $headers  = @{
        'accept'       = 'application/json'
        'Content-Type' = "multipart/form-data; boundary=$boundary"
    }

    try {
        $fileName = [System.IO.Path]::GetFileName($filePath)

        # build multipart body
        $boundaryBytes          = [System.Text.Encoding]::ASCII.GetBytes("--$boundary`r`n")
        $contentDispositionBytes = [System.Text.Encoding]::ASCII.GetBytes("Content-Disposition: form-data; name=`"attachment`"; filename=`"$fileName`"`r`n")
        $contentTypeBytes       = [System.Text.Encoding]::ASCII.GetBytes("Content-Type: application/octet-stream`r`n`r`n")
        $endBoundaryBytes       = [System.Text.Encoding]::ASCII.GetBytes("`r`n--$boundary--`r`n")

        $fileStream   = [System.IO.File]::OpenRead($filePath)
        $memoryStream = New-Object System.IO.MemoryStream

        $memoryStream.Write($boundaryBytes, 0, $boundaryBytes.Length)
        $memoryStream.Write($contentDispositionBytes, 0, $contentDispositionBytes.Length)
        $memoryStream.Write($contentTypeBytes, 0, $contentTypeBytes.Length)
        $fileStream.CopyTo($memoryStream)
        $memoryStream.Write($endBoundaryBytes, 0, $endBoundaryBytes.Length)

        $memoryStream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
        $bodyBytes = $memoryStream.ToArray()

        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $bodyBytes -ContentType "multipart/form-data; boundary=$boundary"

        $fileStream.Close()
        $memoryStream.Close()

        Write-Host "[SUCCESS] Uploaded file: $fileName"
        return $response
    } catch {
        Write-Host "[ERROR] Failed to upload file: $filePath - $($_.Exception.Message)"
        return $null
    }
}

Write-Host "[INFO] Start uploading repackaged HLKX files..."

$commentText     = "DUA package generation completed by AutoHLK. Please manually upload HLKX files to Microsoft..."
$commentResponse = Add-Comment -repo $repository -issueNumber $issueNumber -commentBody $commentText

if (-not ($commentResponse -and $commentResponse.id)) {
    Write-Host "[ERROR] Failed to add initial comment. Aborting uploads."
    exit 1
}

$commentId = $commentResponse.id

# 扫描 temp 下面所有子目录的 *_repackaged.hlkx
$hlkxFiles = Get-ChildItem -Path ".\temp" -Recurse -Filter *_repackaged.hlkx

if (-not $hlkxFiles) {
    Write-Host "[ERROR] No _repackaged.hlkx files found under '.\temp'."
    exit 1
}

foreach ($file in $hlkxFiles) {
    Write-Host "[INFO] Uploading file: $($file.FullName)"

    $maxRetry = 3
    $success  = $false

    for ($i = 1; $i -le $maxRetry; $i++) {
        $uploadResponse = Upload-Attachment -repo $repository -commentId $commentId -filePath $file.FullName
        if ($uploadResponse) {
            $success = $true
            break
        } else {
            Write-Host "[WARNING] Attempt $i failed for file: $($file.Name)"
            Start-Sleep -Seconds 2
        }
    }

    if (-not $success) {
        Write-Host "[ERROR] Upload failed after $maxRetry attempts for file: $($file.Name)"
    }
}

Write-Host "[INFO] All uploads completed."
