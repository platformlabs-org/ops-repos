# inf2cat.ps1
# 环境变量：ARCH_TYPE, INF_DIR

Import-Module "$PSScriptRoot/../modules/OpsApi.psm1" -Force

$inf2catPath = "\\nas\labs\KITS\WDK\x86\inf2cat.exe"

$architecture = $env:ARCH_TYPE
$infDir = $env:INF_DIR

if (-not $architecture) { throw "ARCH_TYPE env not set!" }
if (-not $infDir) { throw "INF_DIR env not set!" }
if (!(Test-Path $inf2catPath)) { throw "inf2cat.exe not found: $inf2catPath" }
if (!(Test-Path $infDir)) { throw "INF_DIR does not exist: $infDir" }

switch ($architecture.ToUpper()) {
    "AMD64" { $osArgument = "/os:10_NI_X64,10_GE_X64" }
    "ARM64" { $osArgument = "/os:10_NI_ARM64,10_GE_ARM64" }
    default {
        Write-Host "::error::Unknown architecture: $architecture. Exiting..."
        exit 1
    }
}

# ==== 1. 查找所有 inf 并去重父目录 ====
$infFiles = Get-ChildItem -LiteralPath $infDir -Recurse -Filter *.inf -File
if (-not $infFiles -or $infFiles.Count -eq 0) {
    throw "No .inf files found in $infDir"
}
# 只取唯一的inf父目录
$uniqueFolders = $infFiles | ForEach-Object { $_.Directory.FullName } | Select-Object -Unique

# ==== 2. 逐目录 inf2cat ====
foreach ($folder in $uniqueFolders) {
    Write-Host "Running inf2cat for: $folder"
    $inf2catCmd = "& `"$inf2catPath`" /driver:`"$folder`" $osArgument /v"
    Write-Host $inf2catCmd

    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = $inf2catPath
    $pinfo.Arguments = "/driver:`"$folder`" $osArgument /v"
    $pinfo.UseShellExecute = $false
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $pinfo
    $process.Start() | Out-Null
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    Write-Host $stdout
    if ($process.ExitCode -ne 0) {
        Write-Host "::error::inf2cat failed for $folder"
        Write-Host $stderr
        exit 1
    }
}

# ==== 3. 签名所有cat ====
$certificate = Get-ChildItem -Path Cert:\CurrentUser\My |
    Where-Object { $_.HasPrivateKey -eq $true -and $_.Subject -match "Lenovo" } |
    Select-Object -First 1

if (-not $certificate) {
    throw "❌ No valid code signing certificate"
}
Write-Host "✔️  Using certificate: $($certificate.Subject)"

$catFiles = Get-ChildItem -LiteralPath $infDir -Recurse -Filter *.cat -File
if (-not $catFiles -or $catFiles.Count -eq 0) {
    throw "No .cat files found to sign in $infDir"
}

foreach ($cat in $catFiles) {
    Write-Host "🔏 Signing CAT: $($cat.FullName)"
    try {
        $result = Set-AuthenticodeSignature -FilePath $cat.FullName -Certificate $certificate -TimestampServer "http://timestamp.digicert.com"
        if ($result.Status -eq 'Valid') {
            Write-Host "✅ Signed: $($cat.FullName)"
        } else {
            Write-Warning "❗ Sign result not valid for: $($cat.FullName). Status: $($result.Status)"
        }
    } catch {
        Write-Host "❌ Failed to sign: $($cat.FullName) - $_"
        throw
    }
}

Write-Host "inf2cat and CAT signing complete."


# ==== 4. 归档已签名driver（含cat）到 OUTPUT_DIR ====

# 环境变量准备
$outputDir = $env:OUTPUT_DIR
$attachmentName = $env:ATTACHMENT_NAME  # 上游已写入环境
if (-not $outputDir) { throw "OUTPUT_DIR env not set!" }
if (-not $attachmentName) { throw "ATTACHMENT_NAME env not set!" }
if (!(Test-Path $outputDir)) { New-Item -Path $outputDir -ItemType Directory | Out-Null }