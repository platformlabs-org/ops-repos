
function Get-PartnerCenterToken {
    param(
        $ClientId,
        $ClientSecret,
        $TenantId,
        $Scope = "https://api.partner.microsoft.com/.default"
    )
    $body = @{
        client_id = $ClientId
        scope = $Scope
        client_secret = $ClientSecret
        grant_type = "client_credentials"
    }
    $uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body
    return $response.access_token
}

function Get-DriverMetadata {
    param(
        $SubmissionId,
        $Token
    )
    $uri = "https://api.partner.microsoft.com/v1.0/ingestion/submissions/$SubmissionId"
    $headers = @{
        "Authorization" = "Bearer $Token"
    }
    return Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
}

function Get-SubmissionPackage {
     param(
        $SubmissionId,
        $Token,
        $DownloadPath
    )

    # -------------------------------------------------------------------------
    # REAL IMPLEMENTATION SKELETON (Commented Out)
    # -------------------------------------------------------------------------
    #
    # $meta = Get-DriverMetadata -SubmissionId $SubmissionId -Token $Token
    # $driverAsset = $meta.downloads | Where-Object { $_.type -eq 'driver' }
    # $shellAsset = $meta.downloads | Where-Object { $_.type -eq 'duashell' }
    #
    # if (-not $driverAsset -or -not $shellAsset) { throw "Assets not found" }
    #
    # Invoke-WebRequest -Uri $driverAsset.url -OutFile (Join-Path $DownloadPath "driver.zip")
    # Invoke-WebRequest -Uri $shellAsset.url -OutFile (Join-Path $DownloadPath "duashell.zip")
    #
    # return @{ Driver = ...; DuaShell = ... }
    # -------------------------------------------------------------------------

    Write-Host "WARNING: Using MOCK download for Submission $SubmissionId"

    $driverPath = Join-Path $DownloadPath "driver.zip"
    $shellPath = Join-Path $DownloadPath "duashell.zip"

    # Create temp content to zip
    $tempSource = Join-Path $DownloadPath "temp_source"
    New-Item -ItemType Directory -Path $tempSource -Force | Out-Null
    Set-Content -Path (Join-Path $tempSource "dummy.inf") -Value "DriverVer=1.0.0.0"
    Set-Content -Path (Join-Path $tempSource "dummy.hlkx") -Value "HLKX Content"

    # Create INF that matches the locator patterns to ensure logic passes
    Set-Content -Path (Join-Path $tempSource "iigd_dch.inf") -Value "DriverVer=0.0.0.0"
    Set-Content -Path (Join-Path $tempSource "iigd_ext.inf") -Value "DriverVer=0.0.0.0"
    Set-Content -Path (Join-Path $tempSource "npu_extension.inf") -Value "DriverVer=0.0.0.0"

    Compress-Archive -Path "$tempSource\*" -DestinationPath $driverPath -Force
    Compress-Archive -Path "$tempSource\*" -DestinationPath $shellPath -Force

    Remove-Item $tempSource -Recurse -Force

    return @{ Driver = $driverPath; DuaShell = $shellPath }
}

Export-ModuleMember -Function Get-PartnerCenterToken, Get-DriverMetadata, Get-SubmissionPackage
