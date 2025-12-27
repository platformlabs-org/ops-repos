param()

$ErrorActionPreference = "Stop"
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"

Import-Module (Join-Path $ModulesPath "Common.psm1")        -Force
Import-Module (Join-Path $ModulesPath "PartnerCenter.psm1") -Force

Write-Log "Step 2: Download Assets"

$productId    = $env:PRODUCT_ID
$submissionId = $env:SUBMISSION_ID
$issueNumber  = $env:ISSUE_NUMBER

if (-not $productId -or -not $submissionId) { throw "Missing ProductID or SubmissionID env vars." }

# Setup Workspace
$workspace = $env:GITHUB_WORKSPACE
if (-not $workspace) { $workspace = Get-Location }
$downloadDir = Join-Path $workspace "downloads"
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# Setup Cache
$useCache = $false
$cacheDir = ""
if ($issueNumber) {
    $cacheDir = "\\nas\labs\RUNNER\tmp\issue-$issueNumber"
    if (Test-Path $cacheDir) {
        Write-Log "Cache found at $cacheDir. Checking contents..."
        $cachedDriver = Get-ChildItem -Path $cacheDir -Filter "*.zip" | Select-Object -First 1
        $cachedHlkx   = Get-ChildItem -Path $cacheDir -Filter "*.hlkx" | Select-Object -First 1

        if ($cachedDriver -and $cachedHlkx) {
            Write-Log "Cached assets found. Copying to workspace..."
            Copy-Item -LiteralPath $cachedDriver.FullName -Destination $downloadDir -Force
            Copy-Item -LiteralPath $cachedHlkx.FullName   -Destination $downloadDir -Force

            $driverZip = Join-Path $downloadDir $cachedDriver.Name
            $hlkxPath  = Join-Path $downloadDir $cachedHlkx.Name
            $useCache  = $true
        }
    }
}

if (-not $useCache) {
    Write-Log "Cache not found or invalid. Downloading from Partner Center..."

    $pcToken = Get-PartnerCenterToken `
        -ClientId     $env:PARTNER_CENTER_CLIENT_ID `
        -ClientSecret $env:PARTNER_CENTER_CLIENT_SECRET `
        -TenantId     $env:PARTNER_CENTER_TENANT_ID

    $downloads = Get-SubmissionPackage -ProductId $productId -SubmissionId $submissionId -Token $pcToken -DownloadPath $downloadDir

    $driverZip = $downloads.Driver
    $hlkxPath  = $downloads.DuaShell

    # Save to Cache
    if ($issueNumber) {
        if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null }
        Write-Log "Saving assets to cache: $cacheDir"
        Copy-Item -LiteralPath $driverZip -Destination $cacheDir -Force
        Copy-Item -LiteralPath $hlkxPath  -Destination $cacheDir -Force
    }
}

if (-not (Test-Path $driverZip)) { throw "Driver zip not found: $driverZip" }
if (-not (Test-Path $hlkxPath))  { throw "HLKX not found: $hlkxPath" }

"DRIVER_ZIP_PATH=$driverZip" | Out-File -FilePath $env:GITHUB_ENV -Append
"HLKX_PATH=$hlkxPath" | Out-File -FilePath $env:GITHUB_ENV -Append

Write-Log "Assets ready at $downloadDir"
