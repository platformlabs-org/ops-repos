param()

$ErrorActionPreference = "Stop"
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"
$RepoRoot    = Resolve-Path (Join-Path $ScriptRoot "..\..") | Select-Object -ExpandProperty Path

Import-Module (Join-Path $ModulesPath "Common.psm1")   -Force
Import-Module (Join-Path $ModulesPath "InfPatch.psm1") -Force

Write-Log "Step 3: Process Driver"

$driverZip    = $env:DRIVER_ZIP_PATH
$infStrategy  = $env:INF_STRATEGY
$projectName  = $env:PROJECT_NAME

if (-not $driverZip -or -not $infStrategy) { throw "Missing input env vars." }

# Pipeline Config (Global/Default)
$pipelineConfigPath = Join-Path $RepoRoot "config\pipeline.json"
if (-not (Test-Path $pipelineConfigPath)) { throw "Pipeline config not found: $pipelineConfigPath" }
$pipelineConfig = Get-Content -Raw -LiteralPath $pipelineConfigPath | ConvertFrom-Json

# Unzip
$workspace = $env:GITHUB_WORKSPACE
if (-not $workspace) { $workspace = Get-Location }
$extractDir = Join-Path $workspace "driver_extracted"
New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

Write-Log "Extracting $driverZip to $extractDir"
Expand-Archive-Force -Path $driverZip -DestinationPath $extractDir

# Delete unwanted
$badInfs = Get-ChildItem -Path $extractDir -Recurse -File -Filter "iigd_ext_d.inf" -ErrorAction SilentlyContinue
if ($badInfs) {
    foreach ($f in $badInfs) {
        Write-Log "Deleting unwanted INF: $($f.FullName)"
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
    }
}

# Check if we need to patch (Action: PatchInf)
if ($pipelineConfig.actions -contains "PatchInf") {
    $locatorConfigPath = Join-Path $RepoRoot "config\mapping\inf_locator.json"
    $locatorConfig = Get-Content -Raw -LiteralPath $locatorConfigPath | ConvertFrom-Json

    $infPattern = $locatorConfig.locators.$infStrategy.filename_pattern
    if (-not $infPattern) { throw "inf_locator.json missing filename_pattern for '$infStrategy'" }

    # Find INF
    $infFile = Get-ChildItem -Path $extractDir -Recurse -File -Filter $infPattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $infFile) {
        $infFile = Get-ChildItem -Path $extractDir -Recurse -File |
            Where-Object { $_.Name -match $infPattern } |
            Select-Object -First 1
    }
    if (-not $infFile) { throw "INF file matching '$infPattern' not found." }

    $driverRootPath = $infFile.Directory.FullName
    Write-Log "Resolved INF: $($infFile.FullName)"
    Write-Log "Resolved DriverRoot: $driverRootPath"

    # Patch
    $infRulesPath = Join-Path $RepoRoot "config\inf_patch_rules.json"
    if (Test-Path -LiteralPath $infRulesPath) {
        Patch-Inf-Advanced -InfPath $infFile.FullName -ConfigPath $infRulesPath -ProjectName $projectName
    } else {
        Write-Warning "Advanced config not found at $infRulesPath. Skipping patch."
    }
} else {
    $driverRootPath = $extractDir
    Write-Warning "No PatchInf action. Using extract root as DriverRoot: $driverRootPath"
}

"DRIVER_ROOT_PATH=$driverRootPath" | Out-File -FilePath $env:GITHUB_ENV -Append
