param()

$ErrorActionPreference = "Stop"
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"
$RepoRoot    = Resolve-Path (Join-Path $ScriptRoot "..\..") | Select-Object -ExpandProperty Path

Import-Module (Join-Path $ModulesPath "Common.psm1")   -Force
Import-Module (Join-Path $ModulesPath "InfPatch.psm1") -Force
Import-Module (Join-Path $ModulesPath "Gitea.psm1")    -Force

Write-Log "Step 3: Process Driver (Prepare Phase)"

$driverZip    = $env:DRIVER_ZIP_PATH
$infStrategy  = $env:INF_STRATEGY
$projectName  = $env:PROJECT_NAME
$issueNumber  = $env:ISSUE_NUMBER
$repoOwner    = $env:REPO_OWNER
$repoName     = $env:REPO_NAME
$token        = $env:GITHUB_TOKEN

if (-not $driverZip -or -not $infStrategy -or -not $issueNumber) { throw "Missing input env vars." }

# 1. Setup Fixed Work Directory in Repo
$workDir = Join-Path $RepoRoot "dua\driver_src"
if (Test-Path $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

# 2. Extract ONLY INFs from Driver Zip to Work Dir
Write-Log "Extracting INFs from $driverZip to $workDir"
$tempExtract = Join-Path $env:GITHUB_WORKSPACE "temp_extract_all"
New-Item -ItemType Directory -Force -Path $tempExtract | Out-Null
Expand-Archive-Force -Path $driverZip -DestinationPath $tempExtract

# Move INFs to workDir
$infs = Get-ChildItem -Path $tempExtract -Recurse -Filter "*.inf"
foreach ($inf in $infs) {
    $basePath = $tempExtract
    if (-not $basePath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $basePath += [System.IO.Path]::DirectorySeparatorChar
    }

    $fullPath = $inf.FullName
    if ($fullPath.StartsWith($basePath)) {
        $relPath  = $fullPath.Substring($basePath.Length)
        $destPath = Join-Path $workDir $relPath
        $destDir  = Split-Path -Parent $destPath
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        Copy-Item -LiteralPath $inf.FullName -Destination $destPath -Force
    } else {
        Write-Warning "Path mismatch: '$fullPath' not under '$basePath'"
    }
}

# Normalize INFs to UTF-16LE (BOM) to ensure Gitea diffs work correctly with .gitattributes
$workDirInfs = Get-ChildItem -Path $workDir -Recurse -Filter "*.inf"
foreach ($wdInf in $workDirInfs) {
    # Read with detection (default) and write back as UTF-16LE (Unicode)
    $content = Get-Content -LiteralPath $wdInf.FullName -Raw
    $content | Out-File -FilePath $wdInf.FullName -Encoding Unicode -Force
}

# (Optional) Create .gitattributes to ensure INFs are treated as text in PR
Set-Content -Path (Join-Path $workDir ".gitattributes") -Value "*.inf text working-tree-encoding=UTF-16LE"

# 3. Git Operations
Write-Log "Initializing Git operations..."
# $uid = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
$branchBase  = "dua/issue-$issueNumber/base"
$branchPatch = "dua/issue-$issueNumber/patch"

# Git Config
git config --global user.email "bot@lnvpe.com"
git config --global user.name "DUA Bot"

# Create/Switch to Base Branch
Write-Log "Creating Base Branch: $branchBase"
git checkout -b $branchBase
git add $workDir
git commit -m "Add original INFs for Issue #$issueNumber"
git push origin $branchBase --force

# Create/Switch to Patch Branch
Write-Log "Creating Patch Branch: $branchPatch"
git checkout -b $branchPatch

# 4. Patch INFs
$locatorConfigPath = Join-Path $RepoRoot "config\mapping\inf_locator.json"
$locatorConfig = Get-Content -Raw -LiteralPath $locatorConfigPath | ConvertFrom-Json
$infPattern = $locatorConfig.locators.$infStrategy.filename_pattern
if (-not $infPattern) { throw "inf_locator.json missing filename_pattern for '$infStrategy'" }

$infFile = Get-ChildItem -Path $workDir -Recurse -File -Filter $infPattern -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $infFile) {
    $infFile = Get-ChildItem -Path $workDir -Recurse -File | Where-Object { $_.Name -match $infPattern } | Select-Object -First 1
}

if ($infFile) {
    Write-Log "Patching INF: $($infFile.FullName)"
    $infRulesPath = Join-Path $RepoRoot "config\inf_patch_rules.json"
    if (Test-Path -LiteralPath $infRulesPath) {
        Patch-Inf-Advanced -InfPath $infFile.FullName -ConfigPath $infRulesPath -ProjectName $projectName
    } else {
        Write-Warning "Rules not found. Skipping Patch-Inf-Advanced."
    }
} else {
    Write-Warning "Target INF matching '$infPattern' not found in extracted INFs. Skipping patch."
}

# 5. Commit and Push Patch
Write-Log "Committing changes to Patch Branch..."
git add $workDir
git commit -m "Apply DUA patches for Issue #$issueNumber"
git push origin $branchPatch --force

# 6. Create Pull Request
Write-Log "Creating Pull Request..."

$issue = Get-Issue -Owner $repoOwner -Repo $repoName -IssueNumber $issueNumber -Token $token
$creator = $issue.user.login
Write-Log "Assigning PR to issue creator: $creator"

$prTitle = "DUA Patch Review for Issue #$issueNumber"
$prBody  = "Automated DUA Patch.`n`nOriginal Issue: #$issueNumber`n`nPlease review the INF changes. Merging this PR will trigger the final packaging."

$pr = New-PullRequest `
    -Owner $repoOwner `
    -Repo $repoName `
    -Head $branchPatch `
    -Base $branchBase `
    -Title $prTitle `
    -Body $prBody `
    -Assignees @($creator) `
    -Token $token

Write-Log "PR Created: $($pr.html_url)"
"PR_URL=$($pr.html_url)" | Out-File -FilePath $env:GITHUB_ENV -Append
