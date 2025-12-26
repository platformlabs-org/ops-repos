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
    [string]$NasRootPath
)

$ErrorActionPreference = 'Stop'

# 导入封装好的 HTTP 模块
Import-Module (Join-Path $PSScriptRoot 'OpsApi.psm1') -Force

function Get-FormFieldValue {
    param(
        [string]$Body,
        [string]$Heading
    )
    # 匹配类似：
    # ### Driver Project
    # Dispatcher
    $pattern = "###\s+$Heading\s+(.+?)(\r?\n###|\r?\n$)"
    $match = [regex]::Match($Body, $pattern, 'Singleline')
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }
    else {
        return ""
    }
}

function Map-DriverProjectName {
    param([string]$Project)

    $map = @{
        'Dispatcher'         = 'Dispatcher3.1.x'
        'SensorFusion'       = 'SensorFusion2.0.0.x'
        'DisplayEnhancement' = 'DisplayEnhancement0.1.0.x'
        'HDRDisplay'         = 'HDRDisplay'
        'AIFW'               = 'AIFW'
        'Tap-to-X'           = 'Tap-to-X'
        'VirtualDisplay'     = 'VirtualDisplay'
    }

    if ($map.ContainsKey($Project)) {
        return $map[$Project]
    }

    throw "Unknown driver project: $Project"
}

function Map-ArchitectureFolder {
    param([string]$Architecture)

    $map = @{
        'AMD64' = 'amd64'
        'ARM64' = 'arm64'
    }

    if ($map.ContainsKey($Architecture)) {
        return $map[$Architecture]
    }

    throw "Unsupported architecture: $Architecture"
}

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

# 使用模块的 HTTP 封装
$issue = Get-OpsIssue -Repo $Repository -Number $IssueNumber -Token $AccessToken

$bodyText = $issue.body
$driverProject = Get-FormFieldValue -Body $bodyText -Heading "Driver Project"
if ([string]::IsNullOrWhiteSpace($driverProject)) {
    # 兼容旧模板的字段名
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
$driverFolder        = ""
$inputHlkxFile       = ""

$tempDownloadDir = Join-Path (Get-Location) "temp\downloads"
if (-not (Test-Path $tempDownloadDir)) {
    New-Item -Path $tempDownloadDir -ItemType Directory -Force | Out-Null
}

switch ($normalizedMode) {
    'SIGN' {
        # SIGN 模式：只接受 HLKX
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
        # WHQL 模式：需要项目/架构 + driver 包
        if ([string]::IsNullOrWhiteSpace($driverProject) -or [string]::IsNullOrWhiteSpace($architecture)) {
            throw "[Prepare] Driver project and architecture are required for WHQL mode."
        }

        # 选第一个非 HLKX 附件作为 driver 包
        $driverAsset = $attachments | Where-Object { $_.name -notlike '*.hlkx' } | Select-Object -First 1
        if (-not $driverAsset) {
            throw "[Prepare] WHQL mode requires a driver package attachment (non-HLKX)."
        }

        $localArchivePath = Join-Path $tempDownloadDir $driverAsset.name
        Invoke-OpsDownloadFile -Url $driverAsset.browser_download_url -TargetPath $localArchivePath -Token $AccessToken

        $driverFolder   = Get-DriverFolderFromArchive -ArchivePath $localArchivePath
        $mappedProject  = Map-DriverProjectName   -Project $driverProject
        $archFolder     = Map-ArchitectureFolder  -Architecture $architecture

        $hlkxTemplateFolder = Join-Path $NasRootPath (Join-Path $mappedProject $archFolder)
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

# 输出给 Workflow
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
