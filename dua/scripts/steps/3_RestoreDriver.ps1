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

# 2. Locate Git Source (The current checkout of the PR merge)
# When the workflow runs on PR merge, the current directory contains the merged files (Base + Patch).
# However, the checkout might be at root. The INFs are in their relative paths.
# But wait, in 3_ProcessDriver.ps1, we committed the INFs *relative to the root of work_git*.
# In `work_git`, we preserved the relative structure from `temp_extract` (flat or nested?).
# We did: `$relPath = [System.IO.Path]::GetRelativePath($tempExtract, $inf.FullName)`
# So if driver structure was `Driver/Display/file.inf`, `work_git` has `Driver/Display/file.inf`.
# And `extractDir` has `Driver/Display/file.inf`.

# In this new workflow (`dua_finish.yml`), we will checkout the *Base Branch* (target of PR) which now contains the merged changes.
# But `dua_finish.yml` needs to checkout the *scripts* too.
# If we checkout the PR branch, we get the INFs but maybe not the scripts if the scripts weren't in the branch?
# In 3_ProcessDriver.ps1, we `git init` or `git clone`? We `git clone`.
# So the branch `dua/issue-x/base` contains *everything* from the original repo PLUS the modified INFs?
# NO.
# In `3_ProcessDriver.ps1`:
# `git clone $cloneUrl .` -> Clones the whole repo.
# `git checkout -b $baseBranch` -> Branches off current (main/scripts included).
# Then we `Copy-Item ...` INFs.
# So the branch *does* contain the scripts (inherited from main) AND the overwritten INFs.
# So checking out the branch gives us everything we need.

Write-Log "Overwriting INFs with versions from Git (Current Workspace)"
# The current workspace (checked out branch) has the modified INFs in place of the original source INFs?
# Wait. In `3_ProcessDriver.ps1`, we copied INFs to `work_git` using relative paths.
# If the original repo structure didn't have those INF paths, they are new files.
# If the original repo had `dua/scripts/...`, the driver files are likely *not* in the repo normally.
# So `work_git` has `dua/scripts/...` AND `Driver/Display/file.inf`.
# So when we checkout this branch in `dua_finish`, we have `Driver/Display/file.inf` on disk.
# We need to copy these `Driver/Display/file.inf` to `$extractDir` (which also has them, but original versions).

# We need to find all INFs in the Workspace that seem to belong to the driver and copy them to $extractDir.
# How do we distinguish repo INFs (if any) from Driver INFs?
# The driver INFs were added in `3_ProcessDriver`.
# We can walk the `$extractDir` and for every INF there, look for a corresponding one in `$workspace`.
# Since we preserved relative paths, this should match.

$driverInfs = Get-ChildItem -Path $extractDir -Recurse -Filter "*.inf"
foreach ($origInf in $driverInfs) {
    $relPath = [System.IO.Path]::GetRelativePath($extractDir, $origInf.FullName)
    $gitInfPath = Join-Path $workspace $relPath

    if (Test-Path $gitInfPath) {
        Write-Log "Restoring $relPath from Git..."
        Copy-Item -LiteralPath $gitInfPath -Destination $origInf.FullName -Force
    } else {
        Write-Warning "INF $relPath not found in Git workspace. Keeping original."
    }
}

# 3. Locate Driver Root (for 4_UpdateHlkx)
# Same logic as original ProcessDriver
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
