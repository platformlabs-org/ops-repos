param(
    [string]$IssueNumber,
    [string]$RepoOwner,
    [string]$RepoName
)

$ErrorActionPreference = "Stop"
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"
$RepoRoot    = Resolve-Path (Join-Path $ScriptRoot "..\..") | Select-Object -ExpandProperty Path

Import-Module (Join-Path $ModulesPath "Common.psm1")        -Force
Import-Module (Join-Path $ModulesPath "Gitea.psm1")         -Force
Import-Module (Join-Path $ModulesPath "PartnerCenter.psm1") -Force
Import-Module (Join-Path $ModulesPath "DriverPipeline.psm1") -Force
Import-Module (Join-Path $ModulesPath "Metadata.psm1")       -Force
Import-Module (Join-Path $ModulesPath "Teams.psm1")          -Force

Write-Log "Step 2: Execute Submission"

$productId    = $env:PRODUCT_ID
$hlkxUrl      = $env:HLKX_URL
$projectName  = $env:PROJECT_NAME
$submissionId = $env:SUBMISSION_ID

if (-not $productId -or -not $hlkxUrl) { throw "Missing input env vars." }

# Get Token for Gitea/GitHub API
$token = $env:GITHUB_TOKEN
if (-not $token) { $token = $env:GITEA_TOKEN }
if (-not $token) { $token = $env:BOTTOKEN }

# 1. Download HLKX
$workspace = $env:GITHUB_WORKSPACE
if (-not $workspace) { $workspace = Get-Location }
$tempDir = Join-Path $workspace "submission_temp"
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

$hlkxPath = Join-Path $tempDir "submission.hlkx"
Write-Log "Downloading HLKX to $hlkxPath"

$headers = @{}
if ($token) {
    $headers["Authorization"] = "token $token"
}
Invoke-WebRequest -Uri $hlkxUrl -OutFile $hlkxPath -Headers $headers

# 2. Submit to Partner Center
$pcToken = Get-PartnerCenterToken `
    -ClientId     $env:PARTNER_CENTER_CLIENT_ID `
    -ClientSecret $env:PARTNER_CENTER_CLIENT_SECRET `
    -TenantId     $env:PARTNER_CENTER_TENANT_ID

Write-Log "Creating new submission for Product $productId..."

try {
    # 2a. Determine Submission Name
    # We need the original submission name.
    # If SUBMISSION_ID was provided, we can fetch it.
    # If not, we try to find the 'initial' submission.

    $originalSubmissionName = ""

    if ($submissionId) {
        $meta = Get-DriverMetadata -ProductId $productId -SubmissionId $submissionId -Token $pcToken
        $originalSubmissionName = $meta.name
    } else {
        # Fetch initial submission
        $subs = Get-ProductSubmissions -ProductId $productId -Token $pcToken
        $initialSub = $subs.value | Where-Object { $_.type -eq "initial" } | Select-Object -First 1
        if ($initialSub) {
            $originalSubmissionName = $initialSub.name
        } else {
            # Fallback if no initial? Just use project name or timestamp?
            # User requirement: "原submissionname拼合“_{projectname}”"
            # If we can't find original submission name, we might fail or default.
            Write-Warning "Could not find 'initial' submission to derive name."
            $originalSubmissionName = "Unknown"
        }
    }

    if (-not $projectName) { $projectName = "DriverUpdate" } # Fallback

    # Determine Strategy
    $mappingFile = Join-Path $RepoRoot "config\mapping\product_routing.json"
    $infStrategy = try { Select-Pipeline -ProductName $originalSubmissionName -MappingFile $mappingFile } catch { $null }

    Write-Log "Detected Strategy: $infStrategy (Based on '$originalSubmissionName')"

    $isExtTask = $infStrategy -match "-ext$"

    $submission = $null
    $newSubmissionName = ""

    if ($isExtTask) {
        Write-Log "Extension task detected. Skipping automatic submission due to API limitations."

        $dashboardUrl = "https://partner.microsoft.com/en-us/dashboard/hardware/driver/$productId"
        $msg = "⚠️ **无法自动提交**`n`n由于 API 限制，Extension 类型的驱动无法通过脚本自动创建新产品。`n请访问以下链接手动创建产品并提交：`n`n[前往 Partner Center]($dashboardUrl)"

        Post-Comment `
            -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber `
            -Body $msg `
            -Token $token | Out-Null

        return
    } else {
        # Standard Derived Submission
        $newSubmissionName = "${originalSubmissionName}_${projectName}"
        Write-Log "New Submission Name: $newSubmissionName"

        $submission = New-Submission -ProductId $productId -Token $pcToken -Name $newSubmissionName -Type "derived"
    }

    $newSubmissionId = $submission.id
    Write-Log "Submission Created: $newSubmissionId"

    # Check for upload URL (sasUrl)
    # Hardware API response: downloads.items where type == 'initialPackage' -> url
    $sasUrl = $null
    if ($submission.downloads -and $submission.downloads.items) {
        $initialPackage = $submission.downloads.items | Where-Object { $_.type -eq "initialPackage" } | Select-Object -First 1
        if ($initialPackage) {
            $sasUrl = $initialPackage.url
        }
    }

    if (-not $sasUrl) {
        # Fallback to fileUploadUrl if exists (legacy?)
        if ($submission.fileUploadUrl) {
            $sasUrl = $submission.fileUploadUrl
        }
    }

    if (-not $sasUrl) {
        Write-Warning "SAS URL not found. Response: $($submission | ConvertTo-Json -Depth 5)"
        throw "Cannot upload: Missing SAS URL."
    }

    # Upload
    Upload-FileToBlob -SasUrl $sasUrl -FilePath $hlkxPath
    Write-Log "HLKX Uploaded."

    # Commit
    Commit-Submission -ProductId $productId -SubmissionId $newSubmissionId -Token $pcToken
    Write-Log "Submission Committed."

    # Notify
    $dashboardUrl = "https://partner.microsoft.com/en-us/dashboard/hardware/driver/$productId"
    $msg = "✅ Submission **$newSubmissionId** committed successfully.`n`n[查看提交]($dashboardUrl)"

    Post-Comment `
        -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber `
        -Body $msg `
        -Token $token | Out-Null

    # Teams Notification (Submitted)
    if ($originalSubmissionName -ne "Unknown") {
        $issue = Get-Issue -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Token $token
        $creatorEmail = $issue.user.email
        if (-not $creatorEmail) { $creatorEmail = $issue.user.login }

        $ver = Get-ShortVersion -Name $originalSubmissionName

        Send-TeamsNotification `
            -EventType "DUA_REQUEST_SUBMITTED" `
            -ToUpn $creatorEmail `
            -Project $projectName `
            -Version $ver `
            -PartnerCenterUrl $dashboardUrl `
            -Message "已提交到 Partner Center。"
    }

    # Update Issue Metadata (submitted)
    if ($originalSubmissionName -ne "Unknown") {
         Update-IssueMetadata `
            -IssueNumber $IssueNumber `
            -RepoOwner $RepoOwner `
            -RepoName $RepoName `
            -Token $token `
            -ProjectName $projectName `
            -SubmissionName $originalSubmissionName `
            -Status "submitted" `
            -InfStrategy $infStrategy
    }

} catch {
    Write-Error "Submission process failed: $_"
    throw
}
