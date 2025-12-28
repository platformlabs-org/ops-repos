
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

function Get-ProductSubmissions {
    param(
        [Parameter(Mandatory)] $ProductId,
        [Parameter(Mandatory)] $Token
    )
    $uri = "https://manage.devcenter.microsoft.com/v2.0/my/hardware/products/$ProductId/submissions"
    $headers = @{
        "Authorization" = "Bearer $Token"
    }
    return Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
}

function Get-Product {
    param(
        [Parameter(Mandatory)] $ProductId,
        [Parameter(Mandatory)] $Token
    )
    $uri = "https://manage.devcenter.microsoft.com/v2.0/my/hardware/products/$ProductId"
    $headers = @{
        "Authorization" = "Bearer $Token"
    }
    return Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
}

function New-Product {
    param(
        [Parameter(Mandatory)] $Name,
        [Parameter(Mandatory)] $Token
    )
    $uri = "https://manage.devcenter.microsoft.com/v2.0/my/hardware/products"
    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type"  = "application/json"
    }
    $body = @{
        name = $Name
    } | ConvertTo-Json

    return Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
}

function Get-FileNameFromUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    # 解析 URL query
    $uri = [System.Uri]$Url
    $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)

    # rscd 里一般是: attachment; filename=XXX
    $rscd = $query["rscd"]
    if ([string]::IsNullOrWhiteSpace($rscd)) {
        return $null
    }

    # 解码 rscd
    $rscdDecoded = [System.Uri]::UnescapeDataString($rscd)

    # 1) filename*=UTF-8''xxx（更标准）
    if ($rscdDecoded -match 'filename\*\s*=\s*([^;]+)') {
        $v = $matches[1].Trim()
        # 常见格式：UTF-8''<urlencoded>
        if ($v -match "UTF-8''(.+)$") {
            return [System.Uri]::UnescapeDataString($matches[1])
        }
        return $v.Trim('"')
    }

    # 2) filename=xxx
    if ($rscdDecoded -match 'filename\s*=\s*([^;]+)') {
        return $matches[1].Trim().Trim('"')
    }

    return $null
}

function Get-SubmissionPackage {
    param(
        $ProductId,
        $SubmissionId,
        $Token,
        $DownloadPath
    )

    $meta = Get-DriverMetadata -ProductId $ProductId -SubmissionId $SubmissionId -Token $Token

    $driverAsset = $meta.downloads.items | Where-Object { $_.type -eq 'signedPackage' }
    $shellAsset  = $meta.downloads.items | Where-Object { $_.type -eq 'derivedPackage' }

    if (-not $driverAsset) { throw "Driver asset (signedPackage) not found for Submission $SubmissionId" }
    if (-not $shellAsset)  { throw "DuaShell asset (derivedPackage) not found for Submission $SubmissionId" }

    # 从 URL 提取文件名；提取不到就用默认名兜底
    $driverName = if ($null -ne ($tmp = Get-FileNameFromUrl -Url $driverAsset.url) -and $tmp.Trim() -ne "") { $tmp } else { "driver.zip" }
    $shellName  = if ($null -ne ($tmp = Get-FileNameFromUrl -Url $shellAsset.url)  -and $tmp.Trim() -ne "") { $tmp } else { "duashell.hlkx" }

    $driverPath = Join-Path $DownloadPath $driverName
    $shellPath  = Join-Path $DownloadPath $shellName

    Write-Host "Downloading Driver => $driverPath"
    Invoke-WebRequest -Uri $driverAsset.url -OutFile $driverPath

    Write-Host "Downloading DuaShell => $shellPath"
    Invoke-WebRequest -Uri $shellAsset.url -OutFile $shellPath

    return @{ Driver = $driverPath; DuaShell = $shellPath }
}


# New Submission Functions (Hardware API)

function New-Submission {
    param(
        $ProductId,
        $Token,
        $Name,
        $Type = "derived"
    )
    # POST https://manage.devcenter.microsoft.com/v2.0/my/hardware/products/{productID}/submissions
    $uri = "https://manage.devcenter.microsoft.com/v2.0/my/hardware/products/$ProductId/submissions"
    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type"  = "application/json"
    }

    $bodyObj = @{
        type = $Type
    }
    if ($Name) {
        $bodyObj["name"] = $Name
    }

    $body = $bodyObj | ConvertTo-Json

    return Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
}

function Upload-FileToBlob {
    param(
        $SasUrl,
        $FilePath
    )
    # Simple BlockBlob PUT
    $headers = @{
        "x-ms-blob-type" = "BlockBlob"
    }

    Write-Host "Uploading $FilePath to Blob Storage..."
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
    # POST https://manage.devcenter.microsoft.com/v2.0/my/hardware/products/{productID}/submissions/{submissionID}/commit
    $uri = "https://manage.devcenter.microsoft.com/v2.0/my/hardware/products/$ProductId/submissions/$SubmissionId/commit"
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

Export-ModuleMember -Function Get-PartnerCenterToken, Get-DriverMetadata, Get-ProductSubmissions, Get-SubmissionPackage, New-Submission, Upload-FileToBlob, Commit-Submission, Get-SubmissionStatus, Get-Product, New-Product
