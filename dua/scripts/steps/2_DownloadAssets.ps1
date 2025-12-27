param()

$ErrorActionPreference = "Stop"
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"

Import-Module (Join-Path $ModulesPath "Common.psm1")        -Force
Import-Module (Join-Path $ModulesPath "PartnerCenter.psm1") -Force

Write-Log "Step 2: Download Assets"

$productId    = $env:PRODUCT_ID
$submissionId = $env:SUBMISSION_ID

if (-not $productId -or -not $submissionId) { throw "Missing ProductID or SubmissionID env vars." }

$pcToken = Get-PartnerCenterToken `
    -ClientId     $env:PARTNER_CENTER_CLIENT_ID `
    -ClientSecret $env:PARTNER_CENTER_CLIENT_SECRET `
    -TenantId     $env:PARTNER_CENTER_TENANT_ID

# Use a fixed temp dir in workspace for sharing across steps (if needed) or just download to a known path
# Gitea Actions / GitHub Actions work in ${{ github.workspace }}
$workspace = $env:GITHUB_WORKSPACE
if (-not $workspace) { $workspace = Get-Location }

$downloadDir = Join-Path $workspace "downloads"
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

$downloads = Get-SubmissionPackage -ProductId $productId -SubmissionId $submissionId -Token $pcToken -DownloadPath $downloadDir

$driverZip = $downloads.Driver
$hlkxPath  = $downloads.DuaShell

if (-not (Test-Path $driverZip)) { throw "Driver zip not found: $driverZip" }
if (-not (Test-Path $hlkxPath))  { throw "HLKX not found: $hlkxPath" }

"DRIVER_ZIP_PATH=$driverZip" | Out-File -FilePath $env:GITHUB_ENV -Append
"HLKX_PATH=$hlkxPath" | Out-File -FilePath $env:GITHUB_ENV -Append

Write-Log "Assets downloaded to $downloadDir"
