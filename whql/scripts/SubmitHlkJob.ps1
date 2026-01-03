param(
    [Parameter(Mandatory)]
    [string]$Repository,
    [Parameter(Mandatory)]
    [string]$IssueNumber,
    [Parameter(Mandatory)]
    [string]$AccessToken,
    [Parameter(Mandatory)]
    [string]$ClientId,
    [Parameter(Mandatory)]
    [string]$ClientSecret,
    [Parameter(Mandatory)]
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules/OpsApi.psm1')
Import-Module (Join-Path $PSScriptRoot 'modules/WhqlCommon.psm1')
# Import Config to map General Name -> Formal Name
Import-Module (Join-Path $PSScriptRoot 'modules/Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'modules/PartnerCenter.psm1')

try {
    Write-Host "[Submit] Starting SubmitHlkJob.ps1"

    $config = Get-WhqlConfig
    $issue = Get-OpsIssue -Repo $Repository -Number $IssueNumber -Token $AccessToken

    $submitterEmail = $issue.user.email
    if ([string]::IsNullOrWhiteSpace($submitterEmail)) {
        throw "Could not determine submitter email from issue author ($($issue.user.login))."
    }
    Write-Host "[Submit] Submitter Email: $submitterEmail"

    $bodyText = $issue.body
    # This gets the "General Name" (e.g., "Lenovo Dispatcher")
    $driverProject = Get-FormFieldValue -Body $bodyText -Heading "Driver Project"
    if ([string]::IsNullOrWhiteSpace($driverProject)) {
        $driverProject = Get-FormFieldValue -Body $bodyText -Heading "filetype"
    }
    $driverVersion = Get-FormFieldValue -Body $bodyText -Heading "Driver Version"

    Write-Host "[Submit] Driver Project (General): $driverProject"
    Write-Host "[Submit] Driver Version: $driverVersion"

    if ([string]::IsNullOrWhiteSpace($driverProject)) { throw "Driver Project is required." }
    if ([string]::IsNullOrWhiteSpace($driverVersion)) { throw "Driver Version is required." }

    # Map General Name to Formal Submit Name
    $formalName = $driverProject
    if ($config.DriverSubmitMap -and $config.DriverSubmitMap.$driverProject) {
        $formalName = $config.DriverSubmitMap.$driverProject
    }

    # --- SIGN Request Override Logic ---
    $comments = $null
    $isSignRequest = $false
    $signRequestOption = $config.SignRequestOption
    if ([string]::IsNullOrWhiteSpace($signRequestOption)) { $signRequestOption = "hlkx_sign_request" }

    if ($driverProject -eq $signRequestOption) {
        $isSignRequest = $true
        Write-Host "[Submit] Detected SIGN Request Mode ($driverProject). Checking comments for override name..."
        $comments = Get-OpsIssueComments -Repo $Repository -Number $IssueNumber -Token $AccessToken

        $latestCmd = Get-LatestSubmitCommand -Comments $comments
        if ($latestCmd) {
            # Extract text after /submit
            $cmdBody = $latestCmd.body.Trim()
            $overrideName = ($cmdBody -replace '^\s*/submit\s*', '').Trim()

            if (-not [string]::IsNullOrWhiteSpace($overrideName)) {
                $formalName = $overrideName
                Write-Host "[Submit] Override Formal Name from comment: '$formalName'"
            } else {
                # Case 3: Fail if no submission name provided in SIGN mode
                Write-Host "[Submit] No override name found in comment."
                throw "MISSING_SIGN_NAME"
            }
        } else {
            # Case 3: Fail if no command found (unlikely here but safe)
             throw "MISSING_SIGN_NAME"
        }
    }

    Write-Host "[Submit] Driver Project (Formal/Submit): $formalName"

    $selectedHlkxName = $null
    $selectedHlkxUrl  = $null
    $selectedFrom     = $null

    $issueHlkx = Get-LatestHlkxFromIssueAssets -Issue $issue
    if ($issueHlkx) {
        $selectedHlkxName = $issueHlkx.name
        $selectedHlkxUrl  = $issueHlkx.browser_download_url
        $selectedFrom     = "issue.assets"
        Write-Host "[Submit] HLKX selected from issue.assets: $selectedHlkxName"
    } else {
        if ($null -eq $comments) {
            $comments = Get-OpsIssueComments -Repo $Repository -Number $IssueNumber -Token $AccessToken
        }
        $submitAtRaw = Get-LatestSubmitCommandTime -Comments $comments
        $cutoff = $null
        if ($submitAtRaw) {
            try { $cutoff = [DateTime]$submitAtRaw } catch { $cutoff = $null }
        }

        $latestBotHlkx = Get-LatestHlkxFromBotComments -Comments $comments -CutoffTime $cutoff
        if ($latestBotHlkx) {
            $selectedHlkxName = $latestBotHlkx.Name
            $selectedHlkxUrl  = $latestBotHlkx.Url
            $selectedFrom     = "bot comments (commentId=$($latestBotHlkx.CommentId), assetId=$($latestBotHlkx.AssetId))"
            Write-Host "[Submit] HLKX selected from $selectedFrom : $selectedHlkxName"
        }
    }

    if ([string]::IsNullOrWhiteSpace($selectedHlkxName) -or [string]::IsNullOrWhiteSpace($selectedHlkxUrl)) {
        throw "No HLKX found. Please attach a .hlkx to the issue OR ensure the workflow posts it as a bot comment attachment."
    }

    $tempDir = Join-Path (Get-Location) "temp\submit_downloads"
    if (-not (Test-Path $tempDir)) {
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    }
    $localHlkxPath = Join-Path $tempDir $selectedHlkxName

    Write-Host "[Submit] Downloading HLKX ($selectedFrom) => $localHlkxPath"
    Invoke-OpsDownloadFile -Url $selectedHlkxUrl -TargetPath $localHlkxPath -Token $AccessToken

    $hlkxTool = Get-HlkxToolPath

    # --- 1. Run HlkxTool parse ---
    Write-Host "[Submit] Parsing HLKX..."
    $argLine = "parse --hlkx " + (Quote-Arg $localHlkxPath)

    $p = Start-Process -FilePath $hlkxTool -ArgumentList $argLine -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $tempDir "parse.stdout") -RedirectStandardError (Join-Path $tempDir "parse.stderr")
    $p.WaitForExit()

    $parseStdout = Get-Content (Join-Path $tempDir "parse.stdout") -Raw
    $parseStderr = Get-Content (Join-Path $tempDir "parse.stderr") -Raw

    if ($p.ExitCode -ne 0) {
        throw "HlkxTool parse failed:`nSTDOUT:$parseStdout`nSTDERR:$parseStderr"
    }

    Write-Host "[Submit] Parse result:`n$parseStdout"
    $hlkxInfo = $parseStdout | ConvertFrom-Json

    # --- 2. Authenticate to Partner Center ---
    Write-Host "[Submit] Authenticating to Partner Center..."
    $pcToken = Get-PartnerCenterToken -ClientId $ClientId -ClientSecret $ClientSecret -TenantId $TenantId

    # --- 3. Create Product ---
    $fullName = ""
    if ($isSignRequest) {
        $fullName = $formalName
    } else {
        $fullName = "$formalName $driverVersion"
    }

    Write-Host "[Submit] Creating Product: $fullName"

    $newProduct = New-Product `
        -Name $fullName `
        -Token $pcToken `
        -TestHarness "hlk" `
        -SelectedProductTypes $hlkxInfo.selectedProductTypes `
        -RequestedSignatures $hlkxInfo.requestedSignatures `
        -DeviceMetadataCategory $hlkxInfo.deviceMetadataCategory

    $productId = $newProduct.id
    Write-Host "[Submit] Created new product: $($newProduct.name) ($productId)"

    # --- 4. Create Submission ---
    $submissionName = $fullName
    Write-Host "[Submit] Creating Submission: $submissionName"

    $submission = New-Submission -ProductId $productId -Token $pcToken -Name $submissionName -Type "initial"
    $submissionId = $submission.id
    Write-Host "[Submit] Created Submission ID: $submissionId"

    $fileUploadUrl = $submission.downloads.items[0].url
    if ([string]::IsNullOrWhiteSpace($fileUploadUrl)) {
        throw "Submission did not return a valid file upload URL (downloads.items[0].url)."
    }

    # --- 5. Upload HLKX ---
    Write-Host "[Submit] Uploading HLKX to SAS URL..."
    Upload-FileToBlob -SasUrl $fileUploadUrl -FilePath $localHlkxPath

    # --- 6. Commit Submission ---
    Write-Host "[Submit] Committing Submission..."
    Commit-Submission -ProductId $productId -SubmissionId $submissionId -Token $pcToken

    Write-Host "[Submit] Submission Committed Successfully."

    # --- 7. Notify Issue ---
    $message = @"
✅ **Submission Succeeded**

**Product:** $fullName (ID: $productId)
**Submission:** $submissionName (ID: $submissionId)
**HLKX:** $selectedHlkxName
**Status:** Committed (Processing started)

[View in Partner Center](https://partner.microsoft.com/en-us/dashboard/hardware/driver/$productId)
"@

    New-OpsIssueComment -Repo $Repository -Number $IssueNumber -Token $AccessToken -BodyText $message | Out-Null

}
catch {
    $errorMsg = $_.Exception.Message
    Write-Host "::error::$errorMsg"

    $failMessage = "❌ **Submission Failed**`n`nError: $errorMsg"

    if ($errorMsg -match "MISSING_SIGN_NAME") {
        $failMessage = "❌ **Submission Failed**`n`nWhen using `hlkx_sign_request`, you must provide a Submission Name in your command.`n`nExample: `/submit MyDriverName`"
    }

    try {
        New-OpsIssueComment -Repo $Repository -Number $IssueNumber -Token $AccessToken -BodyText $failMessage | Out-Null
    } catch {
        Write-Host "Failed to post error comment: $($_.Exception.Message)"
    }
    exit 1
}
