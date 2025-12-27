param()

$ErrorActionPreference = "Stop"
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"
$RepoRoot    = Resolve-Path (Join-Path $ScriptRoot "..\..") | Select-Object -ExpandProperty Path

Import-Module (Join-Path $ModulesPath "Common.psm1")   -Force
Import-Module (Join-Path $ModulesPath "Artifact.psm1") -Force

Write-Log "Step 5: Package Results"

$driverRootPath = $env:DRIVER_ROOT_PATH

if (-not $driverRootPath) { throw "Missing DRIVER_ROOT_PATH." }

$pipelineConfigPath = Join-Path $RepoRoot "config\pipeline.json"
$pipelineConfig = Get-Content -Raw -LiteralPath $pipelineConfigPath | ConvertFrom-Json

if ($pipelineConfig.actions -contains "PackageArtifacts") {
    $workspace = $env:GITHUB_WORKSPACE
    if (-not $workspace) { $workspace = Get-Location }

    $outputDriverZip = Join-Path $workspace "modified_driver.zip"
    Create-ArtifactPackage -SourcePath $driverRootPath -DestinationPath $outputDriverZip

    "OUTPUT_DRIVER_ZIP_PATH=$outputDriverZip" | Out-File -FilePath $env:GITHUB_ENV -Append
} else {
    Write-Log "PackageArtifacts not in actions. Skipping."
}
