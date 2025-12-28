param(
    [Parameter(Mandatory)]
    [string]$Repository,
    [Parameter(Mandatory)]
    [string]$IssueNumber,
    [Parameter(Mandatory)]
    [string]$AccessToken
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules/OpsApi.psm1')
Import-Module (Join-Path $PSScriptRoot 'modules/WhqlCommon.psm1')
# Import Config to map General Name -> Formal Name
Import-Module (Join-Path $PSScriptRoot 'modules/Config.psm1')

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
        $comments = Get-OpsIssueComments -Repo $Repository -Number $IssueNumber -Token $AccessToken
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

    # Use Formal Name here
    $driverNameArg = "$formalName $driverVersion"
    $argLine = @(
        "submit"
        "--hlkx",        (Quote-Arg $localHlkxPath)
        "--to",          (Quote-Arg $submitterEmail)
        "--driver-name", (Quote-Arg $driverNameArg)
        "--driver-type", "WHQL"
        "--fw",          (Quote-Arg $driverVersion)
        "--yes"
        "--non-interactive"
    ) -join ' '

    Write-Host "[Submit] Running: $hlkxTool $argLine"

    $stdoutFile = Join-Path $tempDir "hlkxtool_stdout.txt"
    $stderrFile = Join-Path $tempDir "hlkxtool_stderr.txt"
    if (Test-Path $stdoutFile) { Remove-Item $stdoutFile -Force }
    if (Test-Path $stderrFile) { Remove-Item $stderrFile -Force }

    $p = Start-Process -FilePath $hlkxTool `
                       -ArgumentList $argLine `
                       -NoNewWindow `
                       -PassThru `
                       -RedirectStandardOutput $stdoutFile `
                       -RedirectStandardError  $stderrFile

    Write-Host "[Submit] HlkxTool started. Waiting..."

    while (-not $p.HasExited) {
        Start-Sleep -Seconds 10
        Write-Host "[Submit] ...still running (pid=$($p.Id))"
    }

    $exitCode = $p.ExitCode
    $stdout = if (Test-Path $stdoutFile) { Get-Content -Raw $stdoutFile } else { "" }
    $stderr = if (Test-Path $stderrFile) { Get-Content -Raw $stderrFile } else { "" }
    $fullOutput = "STDOUT:`n$stdout`nSTDERR:`n$stderr"

    if ($exitCode -eq 0) {
        $message = @"
✅ **Submission Succeeded**

Driver: $formalName $driverVersion
HLKX: $selectedHlkxName (from $selectedFrom)

$stdout
"@
        Write-Host "[Submit] HlkxTool completed successfully."
        New-OpsIssueComment -Repo $Repository -Number $IssueNumber -Token $AccessToken -BodyText $message | Out-Null
    } else {
        throw "HlkxTool submit failed with exit code {0}.{1}{2}" -f $exitCode, [Environment]::NewLine, $fullOutput
    }
}
catch {
    $errorMsg = $_.Exception.Message
    Write-Host "::error::$errorMsg"
    try {
        $failMessage = "❌ **Submission Failed**`n`nError: $errorMsg"
        New-OpsIssueComment -Repo $Repository -Number $IssueNumber -Token $AccessToken -BodyText $failMessage | Out-Null
    } catch {
        Write-Host "Failed to post error comment: $($_.Exception.Message)"
    }
    exit 1
}
