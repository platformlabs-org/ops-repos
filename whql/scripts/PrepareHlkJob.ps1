param(
    [Parameter(Mandatory)]
    [string]$Mode,                # WHQL or SIGN
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
Write-Host "[Prepare] Mode: $Mode"

$normalizedMode = $Mode.ToUpperInvariant()
$config = Get-WhqlConfig

$issue = Get-OpsIssue -Repo $Repository -Number $IssueNumber -Token $AccessToken

$bodyText = $issue.body
$driverProject = Get-FormFieldValue -Body $bodyText -Heading "Driver Project"
if ([string]::IsNullOrWhiteSpace($driverProject)) {
    $driverProject = Get-FormFieldValue -Body $bodyText -Heading "filetype"
}
$architecture = Get-FormFieldValue -Body $bodyText -Heading "Architecture"
if ([string]::IsNullOrWhiteSpace($architecture)) {
    $architecture = Get-FormFieldValue -Body $bodyText -Heading "Architecture Type"
}
$driverVersion = Get-FormFieldValue -Body $bodyText -Heading "Driver Version"

Write-Host "[Prepare] Parsed issue fields:"
Write-Host "  Driver Project : $driverProject"
Write-Host "  Architecture   : $architecture"
Write-Host "  Driver Version : $driverVersion"

$attachments = $issue.assets
if (-not $attachments -or $attachments.Count -eq 0) {
    throw "No attachments found in issue. Please upload a driver package or HLKX file."
}

$hlkxTemplateFolder = ""
$driverFolder       = ""
$inputHlkxFile      = ""

$tempDownloadDir = Join-Path (Get-Location) "temp\downloads"
if (-not (Test-Path $tempDownloadDir)) {
    New-Item -Path $tempDownloadDir -ItemType Directory -Force | Out-Null
}

switch ($normalizedMode) {
    'SIGN' {
        $hlkxAsset = $attachments | Where-Object { $_.name -like '*.hlkx' } | Select-Object -First 1
        if (-not $hlkxAsset) {
            throw "[Prepare] SIGN mode requires at least one HLKX attachment."
        }

        $localHlkxPath = Join-Path $tempDownloadDir $hlkxAsset.name
        Invoke-OpsDownloadFile -Url $hlkxAsset.browser_download_url -TargetPath $localHlkxPath -Token $AccessToken
        $inputHlkxFile = $localHlkxPath

        Write-Host "[Prepare] MODE = SIGN"
        Write-Host "[Prepare] HLKX file: $inputHlkxFile"
    }
    'WHQL' {
        if ([string]::IsNullOrWhiteSpace($driverProject) -or [string]::IsNullOrWhiteSpace($architecture)) {
            throw "[Prepare] Driver project and architecture are required for WHQL mode."
        }

        $driverAsset = $attachments | Where-Object { $_.name -notlike '*.hlkx' } | Select-Object -First 1
        if (-not $driverAsset) {
            throw "[Prepare] WHQL mode requires a driver package attachment (non-HLKX)."
        }

        $localArchivePath = Join-Path $tempDownloadDir $driverAsset.name
        Invoke-OpsDownloadFile -Url $driverAsset.browser_download_url -TargetPath $localArchivePath -Token $AccessToken

        $driverFolder = Get-DriverFolderFromArchive -ArchivePath $localArchivePath

        # Use Config Mappings
        if (-not $config.DriverProjectMap.$driverProject) {
            throw "Unknown driver project: $driverProject. Available: $($config.DriverProjectMap | ConvertTo-Json -Depth 1)"
        }
        $mappedProject = $config.DriverProjectMap.$driverProject

        if (-not $config.ArchitectureMap.$architecture) {
            throw "Unsupported architecture: $architecture. Available: $($config.ArchitectureMap | ConvertTo-Json -Depth 1)"
        }
        $archFolder = $config.ArchitectureMap.$architecture

        $hlkxTemplateFolder = Join-Path $HlkxRootPath (Join-Path $mappedProject $archFolder)
        Write-Host "[Prepare] MODE = WHQL"
        Write-Host "[Prepare] HLKX template folder: $hlkxTemplateFolder"

        if (-not (Test-Path $hlkxTemplateFolder)) {
            throw "HLKX template folder does not exist: $hlkxTemplateFolder"
        }

        $hlkxFiles = Get-ChildItem -Path $hlkxTemplateFolder -Filter *.hlkx
        if (-not $hlkxFiles) {
            throw "No .hlkx files found in template folder: $hlkxTemplateFolder"
        }
    }
    default {
        throw "[Prepare] Unsupported Mode: $Mode. Use WHQL or SIGN."
    }
}

$ghOutput = $env:GITHUB_OUTPUT
if (-not $ghOutput) {
    Write-Host "[Prepare] GITHUB_OUTPUT not set, printing values to console only."
    Write-Host "mode=$normalizedMode"
    Write-Host "driver_project=$driverProject"
    Write-Host "architecture=$architecture"
    Write-Host "driver_version=$driverVersion"
    Write-Host "hlkx_template_folder=$hlkxTemplateFolder"
    Write-Host "driver_folder=$driverFolder"
    Write-Host "input_hlkx_file=$inputHlkxFile"
} else {
    @(
        "mode=$normalizedMode"
        "driver_project=$driverProject"
        "architecture=$architecture"
        "driver_version=$driverVersion"
        "hlkx_template_folder=$hlkxTemplateFolder"
        "driver_folder=$driverFolder"
        "input_hlkx_file=$inputHlkxFile"
    ) | Out-File -FilePath $ghOutput -Encoding utf8 -Append
}

Write-Host "[Prepare] PrepareHlkJob.ps1 finished."
