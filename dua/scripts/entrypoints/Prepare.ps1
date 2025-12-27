# Prepare.ps1

param(
    [string]$IssueNumber,
    [string]$RepoOwner,
    [string]$RepoName
)

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"
$RepoRoot = Join-Path $ScriptRoot "..\.."

Import-Module (Join-Path $ModulesPath "Common.psm1")
Import-Module (Join-Path $ModulesPath "Gitea.psm1")
Import-Module (Join-Path $ModulesPath "PartnerCenter.psm1")
Import-Module (Join-Path $ModulesPath "DriverPipeline.psm1")
Import-Module (Join-Path $ModulesPath "InfPatch.psm1")
Import-Module (Join-Path $ModulesPath "DuaShell.psm1")
Import-Module (Join-Path $ModulesPath "Artifact.psm1")

Write-Log "Starting Prepare Workflow for Issue #$IssueNumber"

# 1. Get Issue Details
$token = $env:GITHUB_TOKEN
$issue = Get-Issue -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Token $token

# Parse Body
$body = $issue.body
$projectName = ""
$productId = ""
$submissionId = ""

if ($body -match "### Project Name\s*\n\s*(.*)") { $projectName = $matches[1].Trim() }
if ($body -match "### Product ID\s*\n\s*(.*)") { $productId = $matches[1].Trim() }
if ($body -match "### Submission ID\s*\n\s*(.*)") { $submissionId = $matches[1].Trim() }

Write-Log "Parsed: Project=$projectName, ProductId=$productId, SubmissionId=$submissionId"

if (-not $productId -or -not $submissionId) {
    Write-Error "Missing required fields."
    exit 1
}

# 2. Authenticate & Determine Pipeline
$pcToken = Get-PartnerCenterToken -ClientId $env:PARTNER_CENTER_CLIENT_ID -ClientSecret $env:PARTNER_CENTER_CLIENT_SECRET -TenantId $env:PARTNER_CENTER_TENANT_ID

$productRoutingPath = Join-Path $RepoRoot "config\mapping\product_routing.json"
$infRulesPath = Join-Path $RepoRoot "config\inf_patch_rules.json"

$pipelineName = $null

# Load INF rules if available
$infRules = if (Test-Path $infRulesPath) { Get-Content $infRulesPath | ConvertFrom-Json } else { $null }

# Check if project has specific INF patch rules
if ($infRules -and $infRules.project -and $infRules.project."$projectName") {
    Write-Log "Project '$projectName' found in inf_patch_rules. Fetching Submission Name to determine pipeline."
    try {
        $meta = Get-DriverMetadata -ProductId $productId -SubmissionId $submissionId -Token $pcToken
        $submissionName = $meta.name
        Write-Log "Submission Name: $submissionName"

        # Route based on Submission Name
        $pipelineName = Select-Pipeline -ProductName $submissionName -MappingFile $productRoutingPath
    } catch {
        Write-Error "Failed to determine pipeline from submission metadata: $_"
        exit 1
    }
} else {
    # Fallback to Project Name routing
    $pipelineName = Select-Pipeline -ProductName $projectName -MappingFile $productRoutingPath
}

Write-Log "Selected Pipeline: $pipelineName"

# 3. Download Driver & DuaShell
$tempDir = Get-TempDirectory
$downloads = Get-SubmissionPackage -ProductId $productId -SubmissionId $submissionId -Token $pcToken -DownloadPath $tempDir

# Load Pipeline Config
$pipelineConfigPath = Join-Path $ScriptRoot "..\pipelines\$pipelineName\pipeline.json"
$pipelineConfig = Get-Content $pipelineConfigPath | ConvertFrom-Json

# Unzip Driver (Prerequisite)
$driverExtractPath = Join-Path $tempDir "driver_extracted"
Expand-Archive-Force -Path $downloads.Driver -DestinationPath $driverExtractPath
$driverInfPath = $null

# 4. Execute Pipeline Actions
foreach ($action in $pipelineConfig.actions) {
    Write-Log "Executing action: $action"
    switch ($action) {
        "PatchInf" {
            # Locate INF
            $locatorConfigPath = Join-Path $RepoRoot "config\mapping\inf_locator.json"
            $locatorConfig = Get-Content $locatorConfigPath | ConvertFrom-Json
            $infStrategy = $pipelineConfig.infStrategy
            $infPattern = $locatorConfig.locators.$infStrategy.filename_pattern

            $infFile = Get-ChildItem -Path $driverExtractPath -Recurse -Filter $infPattern | Select-Object -First 1
            if (-not $infFile) { Throw "INF file matching $infPattern not found." }
            $driverInfPath = $infFile.FullName

            # Use Advanced Patching
            if (Test-Path $infRulesPath) {
                 Patch-Inf-Advanced -InfPath $infFile.FullName -ConfigPath $infRulesPath -ProjectName $projectName
            } else {
                 Write-Warning "Advanced config not found at $infRulesPath. Skipping patch."
            }
        }
        "ReplaceDriverInShell" {
             # Unzip DUA Shell
            $shellZip = $downloads.DuaShell
            $shellExtractPath = Join-Path $tempDir "shell_extracted"
            Expand-Archive-Force -Path $shellZip -DestinationPath $shellExtractPath
            $hlkxFile = Get-ChildItem -Path $shellExtractPath -Recurse -Filter *.hlkx | Select-Object -First 1

            if (-not $hlkxFile) {
                if ($shellZip -match "\.hlkx$") {
                    $hlkxFile = Get-Item $shellZip
                } else {
                     $hlkxFile = Join-Path $tempDir "dummy.hlkx"
                     Set-Content $hlkxFile "dummy content"
                }
            }

            $outputHlkx = Join-Path $tempDir "modified.hlkx"
            Update-DuaShell -ShellPath $hlkxFile.FullName -NewDriverPath $driverExtractPath -OutputPath $outputHlkx

            # Track artifact
            $global:outputHlkx = $outputHlkx
        }
        "PackageArtifacts" {
            $outputDriverZip = Join-Path $tempDir "modified_driver.zip"
            Create-ArtifactPackage -SourcePath $driverExtractPath -DestinationPath $outputDriverZip

            # Track artifact
            $global:outputDriverZip = $outputDriverZip
        }
        Default {
            Write-Log "Unknown action: $action"
        }
    }
}

# 5. Upload Results
Write-Log "Uploading results..."
if ($global:outputDriverZip) {
    Upload-Attachment -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -FilePath $global:outputDriverZip -Token $token
}
if ($global:outputHlkx) {
    Upload-Attachment -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -FilePath $global:outputHlkx -Token $token
}

Post-Comment -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Body "Processing complete for $pipelineName. Please check attachments." -Token $token

Write-Log "Prepare Workflow Completed."
