param(
    [Parameter(Mandatory)]
    [string]$Mode,                # WHQL or SIGN
    [string]$TemplateFolder,      # WHQL 时必需：模板 HLKX 目录
    [string]$InputHlkxFile,       # SIGN 时必需：要签名的 HLKX
    [string]$DriverFolder,        # WHQL 时必需：驱动文件所在目录（含 .inf）
    [string]$DriverProject,
    [string]$Architecture,
    [string]$DriverVersion
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules/WhqlCommon.psm1')

Write-Host "[Run] Starting RunHlkJob.ps1"
Write-Host "[Run] Mode          : $Mode"
Write-Host "[Run] TemplateFolder: $TemplateFolder"
Write-Host "[Run] InputHlkxFile : $InputHlkxFile"
Write-Host "[Run] DriverFolder  : $DriverFolder"
Write-Host "[Run] DriverProject : $DriverProject"
Write-Host "[Run] Architecture  : $Architecture"
Write-Host "[Run] DriverVersion : $DriverVersion"

$outDir = Join-Path (Get-Location) "output"
if (-not (Test-Path $outDir)) {
    New-Item -Path $outDir -ItemType Directory | Out-Null
}

$timestamp = Get-Date -Format "MMddHHmmss"

$outputFileName  = ""
$outputFullPath  = $null
$hlkxToolArgs    = @()

switch ($Mode.ToUpperInvariant()) {
    'WHQL' {
        if (-not (Test-Path $TemplateFolder)) { throw "[Run] TemplateFolder does not exist: $TemplateFolder" }
        if (-not (Test-Path $DriverFolder))   { throw "[Run] DriverFolder does not exist: $DriverFolder" }

        if ([string]::IsNullOrWhiteSpace($DriverProject)) { $DriverProject = "UnknownProject" }
        if ([string]::IsNullOrWhiteSpace($Architecture))  { $Architecture  = "UnknownArch" }

        $useVersion = $true
        if ([string]::IsNullOrWhiteSpace($DriverVersion) -or $DriverVersion -eq '_No response_') {
            $useVersion = $false
        }

        if ($useVersion) {
            $rawName = "$DriverProject-$DriverVersion-$Architecture-$timestamp"
        } else {
            $rawName = "$DriverProject-$Architecture-$timestamp"
        }

        $safeName       = Get-SafeFileName -Name $rawName
        $outputFileName = "$safeName.hlkx"
        $outputFullPath = Join-Path $outDir $outputFileName

        $hlkxToolArgs = @('WHQL', '--package', $TemplateFolder, '--driver', $DriverFolder, '--out', $outputFullPath)
    }
    'SIGN' {
        if (-not (Test-Path $InputHlkxFile)) { throw "[Run] InputHlkxFile does not exist: $InputHlkxFile" }

        $baseName     = [IO.Path]::GetFileNameWithoutExtension($InputHlkxFile)
        $safeBaseName = Get-SafeFileName -Name $baseName

        $outputFileName = "${safeBaseName}_Signed.hlkx"
        $outputFullPath = Join-Path $outDir $outputFileName

        $hlkxToolArgs = @('SIGN', '--package', $InputHlkxFile, '--out', $outputFullPath)
    }
    default {
        throw "[Run] Unsupported mode: $Mode"
    }
}

Write-Host "[Run] Output HLKX file: $outputFullPath"
$hlkxTool = Get-HlkxToolPath

Write-Host "[Run] Running $hlkxTool $($hlkxToolArgs -join ' ')"

& $hlkxTool @hlkxToolArgs
if ($LASTEXITCODE -ne 0) {
    throw "[Run] HlkxTool.exe failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path $outputFullPath)) {
    throw "[Run] Expected output file not found: $outputFullPath"
}

$ghOutput = $env:GITHUB_OUTPUT
if ($ghOutput) {
    "built_hlkx_path=$outputFullPath" | Out-File -FilePath $ghOutput -Encoding utf8 -Append
} else {
    Write-Host "[Run] GITHUB_OUTPUT not set, built_hlkx_path=$outputFullPath"
}

Write-Host "[Run] RunHlkJob.ps1 finished."
