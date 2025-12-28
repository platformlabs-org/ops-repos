param(
    [Parameter(Mandatory)]
    [string]$Repository,
    [Parameter(Mandatory)]
    [string]$IssueNumber,
    [Parameter(Mandatory)]
    [string]$AccessToken,
    [Parameter(Mandatory)]
    [string]$HlkxRootPath
)

$ErrorActionPreference = 'Stop'

# Import Modules
Import-Module (Join-Path $PSScriptRoot 'modules/Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'modules/OpsApi.psm1')
Import-Module (Join-Path $PSScriptRoot 'modules/WhqlCommon.psm1')

function Get-DriverFolderFromArchive {
    param([string]$ArchivePath)

    $tempRoot = Join-Path -Path (Get-Location) -ChildPath "temp"
    if (-not (Test-Path $tempRoot)) {
        New-Item -Path $tempRoot -ItemType Directory | Out-Null
    }

    $extractFolderName = [IO.Path]::GetFileNameWithoutExtension($ArchivePath)
    $extractPath = Join-Path $tempRoot $extractFolderName

    if (Test-Path $extractPath) {
        Remove-Item -Path $extractPath -Recurse -Force
    }

    Write-Host "[Prepare] Extracting driver archive to $extractPath"
    Expand-Archive -Path $ArchivePath -DestinationPath $extractPath -Force

    $infFiles = Get-ChildItem -Path $extractPath -Recurse -Filter *.inf
    if (-not $infFiles) {
        throw "No .inf files found in extracted driver archive."
    }

    $driverFolder = $infFiles[0].DirectoryName
    Write-Host "[Prepare] Driver folder resolved to $driverFolder"
    return $driverFolder
}

# -------- Main --------

Write-Host "[Prepare] Starting PrepareHlkJob.ps1"

$config = Get-WhqlConfig
$issue = Get-OpsIssue -Repo $Repository -Number $IssueNumber -Token $AccessToken
$bodyText = $issue.body

# 1. Parse Fields
$driverProject = Get-FormFieldValue -Body $bodyText -Heading "Driver Project"
$architecture  = Get-FormFieldValue -Body $bodyText -Heading "Architecture"
$driverVersion = Get-FormFieldValue -Body $bodyText -Heading "Driver Version"

Write-Host "[Prepare] Parsed issue fields:"
Write-Host "  Driver Project : $driverProject"
Write-Host "  Architecture   : $architecture"
Write-Host "  Driver Version : $driverVersion"

# 2. Determine Mode
$mode = "WHQL"
$signOption = if ($config.SignRequestOption) { $config.SignRequestOption } else { "HLKX Sign Request" }

if ($driverProject -eq $signOption) {
    $mode = "SIGN"
}

Write-Host "[Prepare] Determined Mode: $mode"

# 3. Validate Inputs & Attachments
$attachments = $issue.assets
if (-not $attachments -or $attachments.Count -eq 0) {
    throw "[Prepare] No attachments found. Please upload files."
}

$hlkxTemplateFolder = ""
$driverFolder       = ""
$inputHlkxFile      = ""
$tempDownloadDir    = Join-Path (Get-Location) "temp\downloads"
if (-not (Test-Path $tempDownloadDir)) {
    New-Item -Path $tempDownloadDir -ItemType Directory -Force | Out-Null
}

if ($mode -eq 'SIGN') {
    # SIGN Mode Validation
    $hlkxAsset = $attachments | Where-Object { $_.name -like '*.hlkx' } | Select-Object -First 1
    if (-not $hlkxAsset) {
        throw "[Prepare] Validation Failed: 'HLKX Sign Request' selected but no .hlkx file found. Please upload an .hlkx file."
    }

    # Download HLKX
    $localHlkxPath = Join-Path $tempDownloadDir $hlkxAsset.name
    Invoke-OpsDownloadFile -Url $hlkxAsset.browser_download_url -TargetPath $localHlkxPath -Token $AccessToken
    $inputHlkxFile = $localHlkxPath
    Write-Host "[Prepare] HLKX file downloaded: $inputHlkxFile"

} else {
    # WHQL Mode Validation
    $driverAsset = $attachments | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    if (-not $driverAsset) {
        throw "[Prepare] Validation Failed: Project '$driverProject' selected but no .zip file found. Please upload a driver package (.zip)."
    }

    if (-not $config.DriverProjectMap.$driverProject) {
        throw "[Prepare] Validation Failed: Unknown project '$driverProject'. Available: $($config.DriverProjectMap | ConvertTo-Json -Depth 1)"
    }
    $mappedProject = $config.DriverProjectMap.$driverProject

    if (-not $config.ArchitectureMap.$architecture) {
        throw "[Prepare] Validation Failed: Unsupported architecture '$architecture'. Available: $($config.ArchitectureMap | ConvertTo-Json -Depth 1)"
    }
    $archFolder = $config.ArchitectureMap.$architecture

    # Download Driver
    $localArchivePath = Join-Path $tempDownloadDir $driverAsset.name
    Invoke-OpsDownloadFile -Url $driverAsset.browser_download_url -TargetPath $localArchivePath -Token $AccessToken

    $driverFolder = Get-DriverFolderFromArchive -ArchivePath $localArchivePath

    # Resolve Template Path (Relative to Repo Root)
    # HlkxRootPath passed from Workflow is likely ".\HLKX"
    $hlkxTemplateFolder = Join-Path $HlkxRootPath (Join-Path $mappedProject $archFolder)
    # Resolve to absolute path to be safe
    $hlkxTemplateFolder = [System.IO.Path]::GetFullPath($hlkxTemplateFolder)

    Write-Host "[Prepare] HLKX template folder: $hlkxTemplateFolder"

    if (-not (Test-Path $hlkxTemplateFolder)) {
        throw "[Prepare] HLKX template folder does not exist: $hlkxTemplateFolder. Please check repo structure."
    }

    $hlkxFiles = Get-ChildItem -Path $hlkxTemplateFolder -Filter *.hlkx
    if (-not $hlkxFiles) {
        throw "[Prepare] No .hlkx files found in template folder: $hlkxTemplateFolder"
    }
}

# 4. Set Outputs
$ghOutput = $env:GITHUB_OUTPUT
if (-not $ghOutput) {
    Write-Host "[Prepare] GITHUB_OUTPUT not set, printing values to console only."
    Write-Host "mode=$mode"
    Write-Host "driver_project=$driverProject"
    Write-Host "architecture=$architecture"
    Write-Host "driver_version=$driverVersion"
    Write-Host "hlkx_template_folder=$hlkxTemplateFolder"
    Write-Host "driver_folder=$driverFolder"
    Write-Host "input_hlkx_file=$inputHlkxFile"
} else {
    @(
        "mode=$mode"
        "driver_project=$driverProject"
        "architecture=$architecture"
        "driver_version=$driverVersion"
        "hlkx_template_folder=$hlkxTemplateFolder"
        "driver_folder=$driverFolder"
        "input_hlkx_file=$inputHlkxFile"
    ) | Out-File -FilePath $ghOutput -Encoding utf8 -Append
}

Write-Host "[Prepare] PrepareHlkJob.ps1 finished."
