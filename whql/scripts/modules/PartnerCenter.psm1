
function Invoke-RestMethodWithRetry {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [hashtable]$Headers = @{},
        [string]$Body = $null,
        [string]$ContentType = "application/json",
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 2
    )

    $currentRetry = 0
    while ($true) {
        try {
            $params = @{
                Uri         = $Uri
                Method      = $Method
                Headers     = $Headers
                ContentType = $ContentType
                ErrorAction = "Stop"
            }
            if ($Body) { $params.Body = $Body }

            return Invoke-RestMethod @params
        }
        catch {
            $currentRetry++
            if ($currentRetry -ge $MaxRetries) {
                Write-Host "ERROR: Request to $Uri failed after $MaxRetries retries. Error: $_"
                throw $_
            }
            Write-Host "WARN: Request failed ($currentRetry/$MaxRetries). Retrying in $RetryDelaySeconds seconds... Error: $($_.Exception.Message)"
            Start-Sleep -Seconds $RetryDelaySeconds
            $RetryDelaySeconds *= 2 # Exponential backoff
        }
    }
}

function Invoke-TransferWithRetry {
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [Parameter(Mandatory)]
        [string]$LocalFilePath,
        [string]$Method = "GET", # GET = Download, PUT = Upload
        [hashtable]$Headers = @{},
        [int]$TimeoutMinutes = 30
    )

    $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastProgressTime = [DateTime]::MinValue

    # Loop until timeout
    while ($stopWatch.Elapsed.TotalMinutes -lt $TimeoutMinutes) {
        try {
            if ($Method -eq "GET") {
                # --- Download Logic (HttpClient) ---
                $client = New-Object System.Net.Http.HttpClient
                $client.Timeout = [TimeSpan]::FromMinutes($TimeoutMinutes)

                foreach ($key in $Headers.Keys) {
                    $client.DefaultRequestHeaders.Add($key, $Headers[$key])
                }

                # Start request, only read headers first
                $responseTask = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
                try {
                    $responseTask.Wait()
                } catch {
                    throw "Connection failed: $_"
                }
                $response = $responseTask.Result

                if (-not $response.IsSuccessStatusCode) {
                    throw "Http Status $($response.StatusCode)"
                }

                $totalBytes = $response.Content.Headers.ContentLength
                if ($null -eq $totalBytes) { $totalBytes = -1 }

                $remoteStream = $response.Content.ReadAsStreamAsync().Result
                $localStream  = [System.IO.File]::Create($LocalFilePath)

                $buffer = New-Object byte[] 81920 # 80KB buffer
                $totalRead = 0
                $startTime = [DateTime]::Now

                # Read Loop
                while (($read = $remoteStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $localStream.Write($buffer, 0, $read)
                    $totalRead += $read

                    # Progress Report every 5 seconds
                    $now = [DateTime]::Now
                    if (($now - $lastProgressTime).TotalSeconds -ge 5) {
                        $elapsed = ($now - $startTime).TotalSeconds
                        if ($elapsed -gt 0) {
                            $speed = $totalRead / $elapsed
                            $speedMB = "{0:N2} MB/s" -f ($speed / 1MB)

                            if ($totalBytes -gt 0) {
                                $percent = "{0:P1}" -f ($totalRead / $totalBytes)
                                $remainingBytes = $totalBytes - $totalRead
                                $etaSeconds = if ($speed -gt 0) { $remainingBytes / $speed } else { 0 }
                                $eta = [TimeSpan]::FromSeconds($etaSeconds).ToString("hh\:mm\:ss")
                                Write-Host "Downloading... $percent ($speedMB) ETA: $eta"
                            } else {
                                Write-Host "Downloading... {0:N2} MB ($speedMB)" -f ($totalRead / 1MB)
                            }
                        }
                        $lastProgressTime = $now
                    }
                }

                # Cleanup
                $localStream.Close()
                $remoteStream.Close()
                $client.Dispose()

                Write-Host "Download complete: $LocalFilePath"
                return # Success, exit loop
            }
            elseif ($Method -eq "PUT") {
                # --- Upload Logic (HttpWebRequest) ---
                # HttpWebRequest is used here to easily access the RequestStream for progress reporting

                $request = [System.Net.HttpWebRequest]::Create($Url)
                $request.Method = "PUT"
                $request.Timeout = $TimeoutMinutes * 60 * 1000
                $request.ReadWriteTimeout = 300 * 1000
                # KeepAlive is true by default, which is good

                foreach ($key in $Headers.Keys) {
                    $request.Headers.Add($key, $Headers[$key])
                }

                $fileInfo = Get-Item $LocalFilePath
                $totalBytes = $fileInfo.Length
                $request.ContentLength = $totalBytes

                # Open file and request stream
                $fileStream = [System.IO.File]::OpenRead($LocalFilePath)
                try {
                    $requestStream = $request.GetRequestStream()
                } catch {
                    $fileStream.Close()
                    throw "Failed to open request stream: $_"
                }

                $buffer = New-Object byte[] 81920
                $totalWritten = 0
                $startTime = [DateTime]::Now

                # Write Loop
                while (($read = $fileStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $requestStream.Write($buffer, 0, $read)
                    $totalWritten += $read

                    # Progress Report every 5 seconds
                    $now = [DateTime]::Now
                    if (($now - $lastProgressTime).TotalSeconds -ge 5) {
                        $elapsed = ($now - $startTime).TotalSeconds
                        if ($elapsed -gt 0) {
                            $speed = $totalWritten / $elapsed
                            $speedMB = "{0:N2} MB/s" -f ($speed / 1MB)
                            $percent = "{0:P1}" -f ($totalWritten / $totalBytes)

                            $remainingBytes = $totalBytes - $totalWritten
                            $etaSeconds = if ($speed -gt 0) { $remainingBytes / $speed } else { 0 }
                            $eta = [TimeSpan]::FromSeconds($etaSeconds).ToString("hh\:mm\:ss")

                            Write-Host "Uploading... $percent ($speedMB) ETA: $eta"
                        }
                        $lastProgressTime = $now
                    }
                }

                $fileStream.Close()
                $requestStream.Close()

                # Get Response to ensure completion
                try {
                    $response = $request.GetResponse()
                    $response.Close()
                } catch {
                     throw "Upload finished sending but server returned error: $_"
                }

                Write-Host "Upload complete: $LocalFilePath"
                return # Success
            }
        }
        catch {
            Write-Host "Transfer failed. Retrying... Error: $_"
            # Basic cleanup if variables exist
            if ($null -ne $localStream) { $localStream.Close(); $localStream = $null }
            if ($null -ne $remoteStream) { $remoteStream.Close(); $remoteStream = $null }
            if ($null -ne $client) { $client.Dispose(); $client = $null }
            if ($null -ne $fileStream) { $fileStream.Close(); $fileStream = $null }
            if ($null -ne $requestStream) { $requestStream.Close(); $requestStream = $null }

            Start-Sleep -Seconds 5
        }
    }

    throw "Transfer operation ($Method $Url) failed after $TimeoutMinutes minutes."
}

function Get-PartnerCenterToken {
    param(
        $ClientId,
        $ClientSecret,
        $TenantId,
        $Scope = "https://manage.devcenter.microsoft.com/.default"
    )
    $body = "grant_type=client_credentials&client_id=$ClientId&client_secret=$ClientSecret&resource=https://manage.devcenter.microsoft.com"
    $uri = "https://login.microsoftonline.com/$TenantId/oauth2/token"

    $response = Invoke-RestMethodWithRetry -Uri $uri -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
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
    return Invoke-RestMethodWithRetry -Uri $uri -Method Get -Headers $headers
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
    return Invoke-RestMethodWithRetry -Uri $uri -Method Get -Headers $headers
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
    return Invoke-RestMethodWithRetry -Uri $uri -Method Get -Headers $headers
}

function Get-Products {
    param(
        [Parameter(Mandatory)] $Token
    )
    # GET https://manage.devcenter.microsoft.com/v2.0/my/hardware/products
    $uri = "https://manage.devcenter.microsoft.com/v2.0/my/hardware/products"
    $headers = @{
        "Authorization" = "Bearer $Token"
    }

    $allProducts = @()
    $nextLink = $uri

    while ($nextLink) {
        $response = Invoke-RestMethodWithRetry -Uri $nextLink -Method Get -Headers $headers
        if ($response.items) {
            $allProducts += $response.items
        }
        $nextLink = if ($response.nextLink) { $response.nextLink } else { $null }
    }
    return $allProducts
}

function New-Product {
    param(
        [Parameter(Mandatory)] $Name,
        [Parameter(Mandatory)] $Token,
        $SelectedProductTypes,
        $RequestedSignatures,
        $DeviceMetadataCategory,
        $MarketingNames,
        $DeviceType = "external",
        $IsTestSign = $false,
        $IsFlightSign = $false
    )
    $uri = "https://manage.devcenter.microsoft.com/v2.0/my/hardware/products"
    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type"  = "application/json"
    }

    $bodyObj = @{
        productName = $Name
        deviceType = $DeviceType
        isTestSign = $IsTestSign
        isFlightSign = $IsFlightSign
        deviceMetadataIds = @()
        marketingNames = @()
        additionalAttributes = @{}
    }

    if ($SelectedProductTypes) { $bodyObj["selectedProductTypes"] = $SelectedProductTypes }
    if ($RequestedSignatures)  { $bodyObj["requestedSignatures"] = $RequestedSignatures }
    if ($MarketingNames)       { $bodyObj["marketingNames"] = $MarketingNames }

    $body = $bodyObj | ConvertTo-Json -Depth 10

    return Invoke-RestMethodWithRetry -Uri $uri -Method Post -Headers $headers -Body $body
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
    Invoke-TransferWithRetry -Url $driverAsset.url -LocalFilePath $driverPath -Method "GET"

    Write-Host "Downloading DuaShell => $shellPath"
    Invoke-TransferWithRetry -Url $shellAsset.url -LocalFilePath $shellPath -Method "GET"

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

    return Invoke-RestMethodWithRetry -Uri $uri -Method Post -Headers $headers -Body $body
}

function Upload-FileToBlob {
    param(
        $SasUrl,
        $FilePath
    )
    $headers = @{
        "x-ms-blob-type" = "BlockBlob"
    }

    Write-Host "Uploading $FilePath to Blob Storage..."
    Invoke-TransferWithRetry -Url $SasUrl -LocalFilePath $FilePath -Method "PUT" -Headers $headers
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
    return Invoke-RestMethodWithRetry -Uri $uri -Method Post -Headers $headers -Body "{}"
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
    return Invoke-RestMethodWithRetry -Uri $uri -Method Get -Headers $headers
}

Export-ModuleMember -Function Get-PartnerCenterToken, Get-DriverMetadata, Get-ProductSubmissions, Get-SubmissionPackage, New-Submission, Upload-FileToBlob, Commit-Submission, Get-SubmissionStatus, Get-Product, New-Product, Get-Products
