param()

$ErrorActionPreference = "Stop"
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"
$RepoRoot    = Resolve-Path (Join-Path $ScriptRoot "..\..") | Select-Object -ExpandProperty Path

Import-Module (Join-Path $ModulesPath "Common.psm1")   -Force
Import-Module (Join-Path $ModulesPath "Artifact.psm1") -Force
Import-Module (Join-Path $ModulesPath "Metadata.psm1") -Force

Write-Log "Step 5: Package Results"

$driverRootPath = $env:DRIVER_ROOT_PATH
$outputHlkxPath = $env:OUTPUT_HLKX_PATH
$projectName    = $env:PROJECT_NAME
$submissionName = $env:SUBMISSION_NAME
$productId      = $env:PRODUCT_ID

if (-not $driverRootPath) { throw "Missing DRIVER_ROOT_PATH." }

$pipelineConfigPath = Join-Path $RepoRoot "config\pipeline.json"
$pipelineConfig = Get-Content -Raw -LiteralPath $pipelineConfigPath | ConvertFrom-Json

$workspace = $env:GITHUB_WORKSPACE
if (-not $workspace) { $workspace = Get-Location }

# Determine naming components
$targetProject = if ($projectName) { $projectName } else { $submissionName }
# Sanitize Project Name: Trim and remove invalid chars
$targetProject = $targetProject.Trim() -replace '[<>:"/\\|?*]', '_'

$version = "0000"
if ($submissionName) {
    $version = Get-ShortVersion -Name $submissionName
}

# 1. Package Driver Zip
$outputDriverZip = Join-Path $workspace "modified_driver.zip"
$finalArtifacts = @()

if ($pipelineConfig.actions -contains "PackageArtifacts") {
    Create-ArtifactPackage -SourcePath $driverRootPath -DestinationPath $outputDriverZip

    # Rename/Move to target name
    if (Test-Path $outputDriverZip) {
        $targetDriverName = "${targetProject}-${version}-${productId}-replaced-driver.zip"
        $targetDriverPath = Join-Path $workspace $targetDriverName

        Move-Item -LiteralPath $outputDriverZip -Destination $targetDriverPath -Force
        Write-Log "Created Replaced Driver: $targetDriverPath"
        $finalArtifacts += $targetDriverPath
    }
} else {
    Write-Log "PackageArtifacts not in actions. Skipping Driver Zip."
}

# 2. Rename/Copy HLKX
if ($outputHlkxPath -and (Test-Path $outputHlkxPath)) {
    # Target 1: dua-shell.hlkx
    $duaShellName = "${targetProject}-${version}-${productId}-dua-shell.hlkx"
    $duaShellPath = Join-Path $workspace $duaShellName
    Copy-Item -LiteralPath $outputHlkxPath -Destination $duaShellPath -Force
    Write-Log "Created DuaShell: $duaShellPath"
    $finalArtifacts += $duaShellPath

    # Target 2: replaced.hlkx
    $replacedShellName = "${targetProject}-${version}-${productId}-replaced.hlkx"
    $replacedShellPath = Join-Path $workspace $replacedShellName
    Move-Item -LiteralPath $outputHlkxPath -Destination $replacedShellPath -Force
    Write-Log "Created Replaced Shell: $replacedShellPath"
    $finalArtifacts += $replacedShellPath
}

# Export Artifact List
if ($finalArtifacts.Count -gt 0) {
    $artifactsStr = $finalArtifacts -join ";"
    "OUTPUT_ARTIFACTS=$artifactsStr" | Out-File -FilePath $env:GITHUB_ENV -Append
    Write-Log "Output Artifacts: $artifactsStr"
}
