param()

$ErrorActionPreference = "Stop"
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesPath = Join-Path $ScriptRoot "..\modules"
$RepoRoot    = Resolve-Path (Join-Path $ScriptRoot "..\..") | Select-Object -ExpandProperty Path

Import-Module (Join-Path $ModulesPath "Common.psm1")   -Force
Import-Module (Join-Path $ModulesPath "DuaShell.psm1") -Force

Write-Log "Step 4: Update HLKX"

$hlkxPath       = $env:HLKX_PATH
$driverRootPath = $env:DRIVER_ROOT_PATH

if (-not $hlkxPath -or -not $driverRootPath) { throw "Missing input env vars." }

$pipelineConfigPath = Join-Path $RepoRoot "config\pipeline.json"
$pipelineConfig = Get-Content -Raw -LiteralPath $pipelineConfigPath | ConvertFrom-Json

if ($pipelineConfig.actions -contains "ReplaceDriverInShell") {
    $workspace = $env:GITHUB_WORKSPACE
    if (-not $workspace) { $workspace = Get-Location }

    $outputHlkx = Join-Path $workspace "modified.hlkx"

    # Find the actual directory containing the INF file
    $infFile = Get-ChildItem -Path $driverRootPath -Filter "*.inf" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($infFile) {
        Write-Log "Found INF file at: $($infFile.FullName)"
        Write-Log "Updating Driver Path from '$driverRootPath' to '$($infFile.Directory.FullName)'"
        $driverRootPath = $infFile.Directory.FullName
    } else {
        Write-Warning "No INF file found in '$driverRootPath'. Using root path."
    }

    Update-DuaShell -ShellPath $hlkxPath -NewDriverPath $driverRootPath -OutputPath $outputHlkx

    "OUTPUT_HLKX_PATH=$outputHlkx" | Out-File -FilePath $env:GITHUB_ENV -Append
} else {
    Write-Log "ReplaceDriverInShell not in actions. Skipping."
}
