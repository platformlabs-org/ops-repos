
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

function Get-TempDirectory {
    $path = Join-Path $env:TEMP ([Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Expand-Archive-Force {
    param(
        [string]$Path,
        [string]$DestinationPath
    )
    if (Test-Path $DestinationPath) {
        Remove-Item $DestinationPath -Recurse -Force
    }
    Expand-Archive -Path $Path -DestinationPath $DestinationPath -Force
}

function Compress-Archive-Force {
    param(
        [string]$Path,
        [string]$DestinationPath
    )
    if (Test-Path $DestinationPath) {
        Remove-Item $DestinationPath -Force
    }
    Compress-Archive -Path $Path -DestinationPath $DestinationPath -Force
}

Export-ModuleMember -Function Write-Log, Get-TempDirectory, Expand-Archive-Force, Compress-Archive-Force
