
function Update-DuaShell {
    param(
        $ShellPath,       # Path to the .hlkx file (DUA Shell)
        $NewDriverPath,   # Path to the directory containing the modified driver (inf, sys, etc.)
        $OutputPath       # Path where to save the new .hlkx
    )

    $exe = Join-Path $PSScriptRoot "..\tools\hlk\HlkxTool.exe"
    $exe = [System.IO.Path]::GetFullPath($exe)

    if (-not (Test-Path $exe)) {
        Throw "HlkxTool.exe not found at $exe"
    }

    Write-Host "Running HlkxTool DUA..."
    Write-Host "Shell: $ShellPath"
    Write-Host "Driver: $NewDriverPath"
    Write-Host "Output: $OutputPath"

    # Arguments as per AutoDUA.ps1: "DUA" "hlkx" "driver" "output"
    $argList = @("DUA", "`"$ShellPath`"", "`"$NewDriverPath`"", "`"$OutputPath`"")

    $p = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -PassThru -Wait

    if ($p.ExitCode -ne 0) {
        Throw "HlkxTool DUA failed with exit code $($p.ExitCode)"
    }

    if (-not (Test-Path $OutputPath)) {
        Throw "HlkxTool did not generate output at $OutputPath"
    }

    return $OutputPath
}
Export-ModuleMember -Function Update-DuaShell
