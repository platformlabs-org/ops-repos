
function Create-ArtifactPackage {
    param(
        $SourcePath,
        $DestinationPath
    )
    Write-Host "Creating artifact package at $DestinationPath from $SourcePath"

    if (Test-Path $DestinationPath) {
        Remove-Item $DestinationPath -Force
    }
    Compress-Archive -Path "$SourcePath\*" -DestinationPath $DestinationPath -Force

    return $DestinationPath
}

Export-ModuleMember -Function Create-ArtifactPackage
