param()

$ErrorActionPreference = "Stop"
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"
$RepoRoot    = Resolve-Path (Join-Path $ScriptRoot "..\..") | Select-Object -ExpandProperty Path

Import-Module (Join-Path $ModulesPath "Common.psm1") -Force

Write-Log "Step 3 (Finish): Restore Driver"

$issueNumber = $env:ISSUE_NUMBER
if (-not $issueNumber) { throw "Missing ISSUE_NUMBER env var." }

# 1. Locate Cached Assets
$cacheDir = "\\nas\labs\RUNNER\tmp\issue-$issueNumber"
if (-not (Test-Path $cacheDir)) { throw "Cache not found at $cacheDir. Cannot restore driver." }

$cachedDriver = Get-ChildItem -Path $cacheDir -Filter "*.zip" | Select-Object -First 1
$cachedHlkx   = Get-ChildItem -Path $cacheDir -Filter "*.hlkx" | Select-Object -First 1

if (-not $cachedDriver -or -not $cachedHlkx) { throw "Missing cached assets in $cacheDir" }

Write-Log "Found Cached Driver: $($cachedDriver.FullName)"
Write-Log "Found Cached HLKX:   $($cachedHlkx.FullName)"

# 2. Extract Full Driver
$workspace = $env:GITHUB_WORKSPACE
if (-not $workspace) { $workspace = Get-Location }
$restoreDir = Join-Path $workspace "driver_restored"
New-Item -ItemType Directory -Force -Path $restoreDir | Out-Null

Write-Log "Extracting original driver to $restoreDir"
Expand-Archive-Force -Path $cachedDriver.FullName -DestinationPath $restoreDir

# 3. Overlay Modified INFs from Repo
$repoWorkDir = Join-Path $RepoRoot "dua\driver_src"
if (-not (Test-Path $repoWorkDir)) { throw "Modified INFs not found in repo at $repoWorkDir" }

Write-Log "Overlaying modified INFs from $repoWorkDir"
$modInfs = Get-ChildItem -Path $repoWorkDir -Recurse -File

$basePath = $repoWorkDir.FullName
if (-not $basePath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $basePath += [System.IO.Path]::DirectorySeparatorChar
}

foreach ($file in $modInfs) {
    # Calculate relative path
    $fullPath = $file.FullName
    if ($fullPath.StartsWith($basePath)) {
        $relPath = $fullPath.Substring($basePath.Length)
        $destPath = Join-Path $restoreDir $relPath

        if (Test-Path $destPath) {
            Write-Log "Overwriting $relPath"
            Copy-Item -LiteralPath $file.FullName -Destination $destPath -Force
        } else {
            Write-Warning "Modified file $relPath does not exist in original structure. Copying anyway."
            $destParent = Split-Path -Parent $destPath
            if (-not (Test-Path $destParent)) { New-Item -ItemType Directory -Force -Path $destParent | Out-Null }
            Copy-Item -LiteralPath $file.FullName -Destination $destPath -Force
        }
    } else {
        Write-Warning "Path mismatch: '$fullPath' not under '$basePath'"
    }
}

# 4. Export Env Vars for Next Steps
"DRIVER_ROOT_PATH=$restoreDir" | Out-File -FilePath $env:GITHUB_ENV -Append
"HLKX_PATH=$($cachedHlkx.FullName)" | Out-File -FilePath $env:GITHUB_ENV -Append

Write-Log "Driver restored and patched successfully."
