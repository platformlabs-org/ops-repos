# sign-files.ps1
# 环境变量: SIGN_TYPE, WORKDIR, INF_DIR
# 使用 Set-AuthenticodeSignature + 当前用户第一个带私钥的证书

Import-Module "$PSScriptRoot/../modules/OpsApi.psm1" -Force

# ===== 1. 跳过的文件名列表（小写，不区分大小写）=====
$SkipFiles = @(
    "Diskinfo.dll", "DiskOperator.dll"
)

# ===== 2. 自动选择证书 =====
$certificate = Get-ChildItem -Path Cert:\CurrentUser\My |
    Where-Object { $_.HasPrivateKey -eq $true -and $_.Subject -match "Lenovo" } |
    Select-Object -First 1

if (-not $certificate) {
    throw "❌ No valid code signing certificate"
}
Write-Host "✔️  Using certificate: $($certificate.Subject)"


# ===== 3. 判断类型和目录 =====
$signType = $env:SIGN_TYPE
if (-not $signType) { throw "SIGN_TYPE env not set!" }

if ($signType -eq "Sign File") {
    $targetDir = $env:WORK_DIR
    if (-not $targetDir) {
        $targetDir = "$PSScriptRoot/../../unzipped"
        Write-Warning "WORKDIR env not set, defaulting to $targetDir"
    }
    Write-Host "Sign Type: Sign File"
}
elseif ($signType -eq "Lenovo Driver") {
    $targetDir = $env:INF_DIR
    if (-not $targetDir) { throw "INF_DIR env not set!" }
    Write-Host "Sign Type: Lenovo Driver"
}
else {
    throw "Unsupported SIGN_TYPE: $signType"
}

if (!(Test-Path $targetDir)) { throw "Target directory does not exist: $targetDir" }
Write-Host "🔍 Searching for files in: $targetDir"

# ===== 4. 查找目标文件 =====
$extensions = @('*.dll', '*.sys', '*.exe')
$files = Get-ChildItem -LiteralPath $targetDir -Recurse -Include $extensions -File
if ($files.Count -eq 0) {
    Write-Host "No target files found to sign in: $targetDir"
    exit 0
}

# ===== 5. 遍历签名 =====
foreach ($f in $files) {
    $fname = $f.Name.ToLower()
    if ($SkipFiles -contains $fname) {
        Write-Host "⏩ Skipped: $($f.FullName)"
        continue
    }

    Write-Host "🔏 Signing: $($f.FullName)"
    try {
        $result = Set-AuthenticodeSignature -FilePath $f.FullName -Certificate $certificate -TimestampServer "http://timestamp.digicert.com"
        if ($result.Status -eq 'Valid') {
            Write-Host "✅ Signed: $($f.FullName)"
        } else {
            Write-Warning "❗ Sign result not valid for: $($f.FullName). Status: $($result.Status)"
        }
    } catch {
        Write-Host "❌ Failed to sign: $($f.FullName) - $_"
        throw
    }
}

Write-Host "All eligible files signed (or skipped as needed)."
