[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IssueNumber,
    [Parameter(Mandatory)][string]$RepoOwner,
    [Parameter(Mandatory)][string]$RepoName
)

$ErrorActionPreference = "Stop"

function Resolve-FilePath {
    param([object]$InputObject)
    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [string]) {
        if ([string]::IsNullOrWhiteSpace($InputObject)) { return $null }
        try { return (Resolve-Path -LiteralPath $InputObject).Path } catch { return $InputObject }
    }

    $names = $InputObject.PSObject.Properties.Name
    foreach ($k in @("FullName","Path","FilePath","Value")) {
        if ($names -contains $k) {
            $v = $InputObject.$k
            if (-not [string]::IsNullOrWhiteSpace($v)) { return [string]$v }
        }
    }
    return [string]$InputObject
}

function Assert-FileExists([string]$Path, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Name path is empty." }
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Name not found: $Path" }
}

function Assert-DirExists([string]$Path, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Name path is empty." }
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Name not found: $Path" }
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "JSON file not found: $Path" }
    Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

# ---- Paths ----
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"
$RepoRoot    = Resolve-Path (Join-Path $ScriptRoot "..\..") | Select-Object -ExpandProperty Path

# ---- Import Modules ----
Import-Module (Join-Path $ModulesPath "Common.psm1")        -Force -ErrorAction Stop
Import-Module (Join-Path $ModulesPath "Gitea.psm1")         -Force -ErrorAction Stop
Import-Module (Join-Path $ModulesPath "PartnerCenter.psm1") -Force -ErrorAction Stop
Import-Module (Join-Path $ModulesPath "DriverPipeline.psm1")-Force -ErrorAction Stop
Import-Module (Join-Path $ModulesPath "InfPatch.psm1")      -Force -ErrorAction Stop
Import-Module (Join-Path $ModulesPath "DuaShell.psm1")      -Force -ErrorAction Stop
Import-Module (Join-Path $ModulesPath "Artifact.psm1")      -Force -ErrorAction Stop

Write-Log "Starting Prepare Workflow for Issue #$IssueNumber"

# ---- Token ----
$token = $env:GITHUB_TOKEN
if (-not $token) { $token = $env:GITEA_TOKEN }
if (-not $token) { $token = $env:BOTTOKEN }
if (-not $token) { throw "Missing API token. Set env GITHUB_TOKEN/GITEA_TOKEN/BOTTOKEN." }

# 1) Get Issue
$issue = Get-Issue -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Token $token

# 2) Parse Body (support \r\n)
$body = $issue.body
if (-not $body) { $body = $issue.Body }
if (-not $body) { $body = "" }

$projectName  = ""
$productId    = ""
$submissionId = ""

if ($body -match "(?ms)###\s*Project Name\s*\r?\n\s*(.+?)\s*(\r?\n|$)")  { $projectName  = $matches[1].Trim() }
if ($body -match "(?ms)###\s*Product ID\s*\r?\n\s*(.+?)\s*(\r?\n|$)")    { $productId    = $matches[1].Trim() }
if ($body -match "(?ms)###\s*Submission ID\s*\r?\n\s*(.+?)\s*(\r?\n|$)") { $submissionId = $matches[1].Trim() }

Write-Log "Parsed: Project=$projectName, ProductId=$productId, SubmissionId=$submissionId"

if (-not $projectName) { throw "Missing Project Name." }
if (-not $productId -or -not $submissionId) { throw "Missing required fields (ProductId/SubmissionId)." }

# 3) PartnerCenter Token + Pipeline
$pcToken = Get-PartnerCenterToken `
    -ClientId     $env:PARTNER_CENTER_CLIENT_ID `
    -ClientSecret $env:PARTNER_CENTER_CLIENT_SECRET `
    -TenantId     $env:PARTNER_CENTER_TENANT_ID

$productRoutingPath = Join-Path $RepoRoot "config\mapping\product_routing.json"
$infRulesPath       = Join-Path $RepoRoot "config\inf_patch_rules.json"

$infRules = if (Test-Path -LiteralPath $infRulesPath) { Get-Content -Raw -LiteralPath $infRulesPath | ConvertFrom-Json } else { $null }
$pipelineName = $null

if ($infRules -and $infRules.project -and $infRules.project."$projectName") {
    Write-Log "Project '$projectName' found in inf_patch_rules. Fetching Submission Name to determine pipeline."
    $meta = Get-DriverMetadata -ProductId $productId -SubmissionId $submissionId -Token $pcToken
    $submissionName = $meta.name
    Write-Log "Submission Name: $submissionName"
    $pipelineName = Select-Pipeline -ProductName $submissionName -MappingFile $productRoutingPath
} else {
    $pipelineName = Select-Pipeline -ProductName $projectName -MappingFile $productRoutingPath
}

Write-Log "Selected Pipeline: $pipelineName"
if ([string]::IsNullOrWhiteSpace($pipelineName)) { throw "Pipeline selection failed." }

# 4) Download packages
$tempDir = Get-TempDirectory
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

$downloads = Get-SubmissionPackage -ProductId $productId -SubmissionId $submissionId -Token $pcToken -DownloadPath $tempDir

$driverZip = Resolve-FilePath $downloads.Driver
$hlkxPath  = Resolve-FilePath $downloads.DuaShell

Assert-FileExists $driverZip "Driver package"
Assert-FileExists $hlkxPath  "DuaShell/HLKX"

# 5) Load pipeline config
$pipelineConfigPath = Join-Path $ScriptRoot "..\pipelines\$pipelineName\pipeline.json"
$pipelineConfig = Read-JsonFile $pipelineConfigPath

# 6) Unzip driver
$driverExtractPath = Join-Path $tempDir "driver_extracted"
New-Item -ItemType Directory -Force -Path $driverExtractPath | Out-Null

try {
    Expand-Archive -LiteralPath $driverZip -DestinationPath $driverExtractPath -Force
} catch {
    if (Get-Command Expand-Archive-Force -ErrorAction SilentlyContinue) {
        Expand-Archive-Force -Path $driverZip -DestinationPath $driverExtractPath
    } else {
        throw
    }
}

# ✅ Requirement: delete iigd_ext_d.inf if exists (anywhere under extracted dir)
$badInfs = Get-ChildItem -Path $driverExtractPath -Recurse -File -Filter "iigd_ext_d.inf" -ErrorAction SilentlyContinue
if ($badInfs) {
    foreach ($f in $badInfs) {
        Write-Log "Deleting unwanted INF: $($f.FullName)"
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
    }
}

# Prepare shared state
$script:DriverInfFile   = $null
$script:DriverRootPath  = $null
$script:outputHlkx      = $null
$script:outputDriverZip = $null

# 7) Execute actions
foreach ($action in $pipelineConfig.actions) {
    Write-Log "Executing action: $action"

    switch ($action) {

        "PatchInf" {
            $locatorConfigPath = Join-Path $RepoRoot "config\mapping\inf_locator.json"
            $locatorConfig = Read-JsonFile $locatorConfigPath

            $infStrategy = $pipelineConfig.infStrategy
            if ([string]::IsNullOrWhiteSpace($infStrategy)) { throw "pipeline.json missing infStrategy" }

            $infPattern = $locatorConfig.locators.$infStrategy.filename_pattern
            if ([string]::IsNullOrWhiteSpace($infPattern)) { throw "inf_locator.json missing filename_pattern for '$infStrategy'" }

            # find INF
            $infFile = Get-ChildItem -Path $driverExtractPath -Recurse -File -Filter $infPattern -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $infFile) {
                $infFile = Get-ChildItem -Path $driverExtractPath -Recurse -File |
                    Where-Object { $_.Name -match $infPattern } |
                    Select-Object -First 1
            }
            if (-not $infFile) { throw "INF file matching '$infPattern' not found under $driverExtractPath" }

            $script:DriverInfFile  = $infFile
            $script:DriverRootPath = $infFile.Directory.FullName

            Write-Log "Resolved INF: $($script:DriverInfFile.FullName)"
            Write-Log "Resolved DriverRoot (INF directory): $($script:DriverRootPath)"

            Assert-DirExists $script:DriverRootPath "DriverRoot"

            # patch
            if (Test-Path -LiteralPath $infRulesPath) {
                Patch-Inf-Advanced -InfPath $script:DriverInfFile.FullName -ConfigPath $infRulesPath -ProjectName $projectName
            } else {
                Write-Warning "Advanced config not found at $infRulesPath. Skipping patch."
            }
        }

        "ReplaceDriverInShell" {
            # ✅ IMPORTANT: Driver path must be INF所在目录
            if (-not $script:DriverRootPath) {
                throw "DriverRootPath is not resolved. Ensure PatchInf runs before ReplaceDriverInShell."
            }

            $outputHlkx = Join-Path $tempDir "modified.hlkx"
            Update-DuaShell -ShellPath $hlkxPath -NewDriverPath $script:DriverRootPath -OutputPath $outputHlkx
            $script:outputHlkx = $outputHlkx
        }

        "PackageArtifacts" {
            if (-not $script:DriverRootPath) {
                throw "DriverRootPath is not resolved. Ensure PatchInf runs before PackageArtifacts."
            }

            $outputDriverZip = Join-Path $tempDir "modified_driver.zip"
            Create-ArtifactPackage -SourcePath $script:DriverRootPath -DestinationPath $outputDriverZip
            $script:outputDriverZip = $outputDriverZip
        }

        Default {
            Write-Log "Unknown action: $action"
        }
    }
}

$files = @()
if ($script:outputDriverZip) { $files += $script:outputDriverZip }
if ($script:outputHlkx)      { $files += $script:outputHlkx }

Post-CommentWithAttachments `
  -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber `
  -Body "✅ Processing complete for $pipelineName. Attachments are uploaded to this comment." `
  -FilePaths $files `
  -Token $token | Out-Null

