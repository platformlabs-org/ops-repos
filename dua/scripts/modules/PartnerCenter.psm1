
function Get-PartnerCenterToken {
    param(
        $ClientId,
        $ClientSecret,
        $TenantId,
        $Scope = "https://manage.devcenter.microsoft.com/.default"
    )
    $body = @{
        client_id = $ClientId
        scope = $Scope
        client_secret = $ClientSecret
        grant_type = "client_credentials"
        resource = "https://manage.devcenter.microsoft.com"
    }
    $uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body
    return $response.access_token
}

function Get-DriverMetadata {
    param(
        $ProductId,
        $SubmissionId,
        $Token
    )
    $uri = "https://manage.devcenter.microsoft.com/v2.0/my/hardware/products/$ProductId/submissions/$SubmissionId/"
    $headers = @{
        "Authorization" = "Bearer $Token"
    }
    return Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
}

function Get-SubmissionPackage {
     param(
        $ProductId,
        $SubmissionId,
        $Token,
        $DownloadPath
    )

    $meta = Get-DriverMetadata -ProductId $ProductId -SubmissionId $SubmissionId -Token $Token

    $driverAsset = $meta.downloads.items | Where-Object { $_.type -eq 'initialPackage' }
    $shellAsset = $meta.downloads.items | Where-Object { $_.type -eq 'derivedPackage' }

    if (-not $driverAsset) { throw "Driver asset (initialPackage) not found for Submission $SubmissionId" }
    if (-not $shellAsset) { throw "DuaShell asset (derivedPackage) not found for Submission $SubmissionId" }

    $driverPath = Join-Path $DownloadPath "driver.zip"
    $shellPath = Join-Path $DownloadPath "duashell.zip"

    Write-Host "Downloading Driver from $($driverAsset.url) ..."
    Invoke-WebRequest -Uri $driverAsset.url -OutFile $driverPath -ProgressAction SilentlyContinue

    Write-Host "Downloading DuaShell from $($shellAsset.url) ..."
    Invoke-WebRequest -Uri $shellAsset.url -OutFile $shellPath -ProgressAction SilentlyContinue

    return @{ Driver = $driverPath; DuaShell = $shellPath }
}

# New Submission Functions (Hardware Ingestion API)

function New-Submission {
    param(
        $ProductId,
        $Token
    )
    # https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/ingestion-api-dashboard-submission#create-a-new-submission
    $uri = "https://api.partner.microsoft.com/v1.0/ingestion/products/$ProductId/submissions"
    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type"  = "application/json"
    }
    # Body is typically empty to create a new one, or contains name?
    # Usually empty to create a draft.
    return Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body "{}"
}

function Upload-FileToBlob {
    param(
        $SasUrl,
        $FilePath
    )
    # Simple BlockBlob PUT
    # For large files, we should use blocks, but for HLKX usually < 100MB it might be fine directly?
    # Actually, Azure Blob PUT Blob has a limit (256MB formerly, now higher).
    # We will use simple PUT with x-ms-blob-type: BlockBlob

    $headers = @{
        "x-ms-blob-type" = "BlockBlob"
    }

    # Check file size. If > 256MB, block upload is safer, but simpler logic here for now.
    Write-Host "Uploading $FilePath to Blob Storage..."
    $content = Get-Content $FilePath -Raw -Encoding Byte # PowerShell 5.1
    # In PowerShell Core (PWSH), -AsByteStream is needed or -Raw isn't byte?
    # PWSH: Get-Content $Path -AsByteStream
    # Since we run on windows-latest (PWSH), we use AsByteStream logic or System.IO.File

    try {
        # Using WebRequest for better stream handling
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("x-ms-blob-type", "BlockBlob")
        $wc.UploadFile($SasUrl, "PUT", $FilePath)
    }
    catch {
        Throw "Failed to upload file to blob: $_"
    }
}

function Commit-Submission {
    param(
        $ProductId,
        $SubmissionId,
        $Token
    )
    $uri = "https://api.partner.microsoft.com/v1.0/ingestion/products/$ProductId/submissions/$SubmissionId/commit"
    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type"  = "application/json"
    }
    return Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body "{}"
}

function Get-SubmissionStatus {
     param(
        $ProductId,
        $SubmissionId,
        $Token
    )
    $uri = "https://manage.devcenter.microsoft.com/v2.0/my/hardware/products/$ProductId/submissions/$SubmissionId/"
    $headers = @{
        "Authorization" = "Bearer $Token"
    }
    return Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
}

Export-ModuleMember -Function Get-PartnerCenterToken, Get-DriverMetadata, Get-SubmissionPackage, New-Submission, Upload-FileToBlob, Commit-Submission, Get-SubmissionStatus
