
function Get-WhqlConfig {
    $configPath = Join-Path $PSScriptRoot '../../config/config.json'
    $resolvedPath = [System.IO.Path]::GetFullPath($configPath)

    if (-not (Test-Path $resolvedPath)) {
        throw "Config file not found at $resolvedPath"
    }
    return Get-Content -Path $resolvedPath -Raw | ConvertFrom-Json
}

Export-ModuleMember -Function Get-WhqlConfig
