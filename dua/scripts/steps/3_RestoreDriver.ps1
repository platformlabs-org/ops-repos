param()

$ErrorActionPreference = "Stop"
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"

Import-Module (Join-Path $ModulesPath "Common.psm1") -Force

Write-Log "Step 3 (Restore): Restore Driver from Git"

$driverZip    = $env:DRIVER_ZIP_PATH
$infStrategy  = $env:INF_STRATEGY
$issueNumber  = $env:ISSUE_NUMBER
$workspace    = $env:GITHUB_WORKSPACE

if (-not $driverZip -or -not $issueNumber) { throw "Missing input env vars." }

# 1. Unzip Original Driver
$extractDir = Join-Path $workspace "driver_extracted"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

Write-Log "Extracting Original $driverZip to $extractDir"
Expand-Archive-Force -Path $driverZip -DestinationPath $extractDir

# 2. Sync INFs from Git Workspace to Driver Extract
# The workspace (current dir) contains the merged INFs (and scripts, etc).
# We assume the relative directory structure of INFs in Git matches the Driver structure.
# But Git also contains scripts/ etc. We must only sync INFs that "belong" to the driver.
# How do we know which INFs belong to the driver?
# In 3_ProcessDriver, we copied ALL INFs from the driver to Git.
# So if a file is an *.inf in Git, it *likely* belongs to the driver (unless it's a script INF, do we have those?)
# We should filter out repo-specific INFs if any. `dua/scripts` shouldn't have INFs?
# Just in case, we can rely on the fact that we preserved relative paths.
# But if the driver has `Driver/Display/foo.inf`, Git has `Driver/Display/foo.inf`.
# Git also has `dua/scripts/...`.
# So we can walk the Git workspace, look for `*.inf`.
# If the path looks like it belongs to the driver (i.e., not in `.gitea` or `dua/scripts`), we copy/sync it.
# Actually, strict sync:
# A. Update/Add: For every *.inf in Git that is NOT in excluded paths:
#    Copy to $extractDir using relative path.
# B. Delete: For every *.inf in $extractDir:
#    If it does NOT exist in Git, delete it.

Write-Log "Syncing INFs from Git Workspace to Extraction Directory..."

$gitInfs = Get-ChildItem -Path $workspace -Recurse -Filter "*.inf"
$excludePatterns = @(".git", ".gitea", "dua\scripts", "dua\config") # Adjust as needed

foreach ($gitInf in $gitInfs) {
    $relPath = [System.IO.Path]::GetRelativePath($workspace, $gitInf.FullName)

    # Check exclusions
    $skip = $false
    foreach ($p in $excludePatterns) {
        if ($relPath.StartsWith($p) -or $relPath -match "\\$p\\") { $skip = $true; break }
    }
    if ($skip) { continue }

    $destPath = Join-Path $extractDir $relPath
    $destDir = Split-Path -Parent $destPath

    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

    # Copy (Overwrite or Add)
    Copy-Item -LiteralPath $gitInf.FullName -Destination $destPath -Force
    # Write-Host "Synced: $relPath"
}

# Handle Deletions
# We need to find INFs in ExtractDir that are NOT in Git (and weren't excluded).
# Since we only put INFs in Git in Step 3, if an INF is in ExtractDir but not Git, it means it was deleted in the PR (or filtered out initially?)
# In Step 3, we copied ALL INFs. So it must have been deleted.

$extractedInfs = Get-ChildItem -Path $extractDir -Recurse -Filter "*.inf"
foreach ($exInf in $extractedInfs) {
    $relPath = [System.IO.Path]::GetRelativePath($extractDir, $exInf.FullName)
    $gitPath = Join-Path $workspace $relPath

    if (-not (Test-Path $gitPath)) {
        # It's missing in Git. Was it excluded?
        $skip = $false
        foreach ($p in $excludePatterns) {
            if ($relPath.StartsWith($p) -or $relPath -match "\\$p\\") { $skip = $true; break }
        }

        if (-not $skip) {
            Write-Warning "INF $relPath missing in Git. Deleting from driver package."
            Remove-Item -LiteralPath $exInf.FullName -Force
        }
    }
}

# 3. Locate Driver Root (for 4_UpdateHlkx)
$repoRoot = Resolve-Path (Join-Path $ScriptRoot "..\..") | Select-Object -ExpandProperty Path
$locatorConfigPath = Join-Path $repoRoot "config\mapping\inf_locator.json"
$locatorConfig = Get-Content -Raw -LiteralPath $locatorConfigPath | ConvertFrom-Json
$infPattern = $locatorConfig.locators.$infStrategy.filename_pattern

$infFile = Get-ChildItem -Path $extractDir -Recurse -File -Filter $infPattern -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $infFile) {
    $infFile = Get-ChildItem -Path $extractDir -Recurse -File | Where-Object { $_.Name -match $infPattern } | Select-Object -First 1
}

$driverRootPath = $extractDir
if ($infFile) {
    $driverRootPath = $infFile.Directory.FullName
}

Write-Log "Resolved DriverRoot: $driverRootPath"
"DRIVER_ROOT_PATH=$driverRootPath" | Out-File -FilePath $env:GITHUB_ENV -Append
