
function Submit-Hlkx {
    param(
        $HlkxPath,
        $Token,
        $ProductId,
        $SubmissionId
    )

    $exe = Join-Path $PSScriptRoot "..\tools\hlk\HlkxTool.exe"
    $exe = [System.IO.Path]::GetFullPath($exe)

    $argList = @("submit", "--driver-type", "DUA", "--hlkx", "`"$HlkxPath`"")

    if ($ProductId) {
        $argList += "--product-id"
        $argList += $ProductId
    }

    if ($SubmissionId) {
        $argList += "--submission-id"
        $argList += $SubmissionId
    }

    $argList += "--non-interactive"

    # Pass the token as an environment variable to the process if provided
    $envParams = @{}
    if ($Token) {
        # Assuming HlkxTool uses this env var for pre-acquired token
        $env:PARTNER_CENTER_ACCESS_TOKEN = $Token
    }

    Write-Host "Running HlkxTool submit..."
    $p = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -PassThru -Wait

    if ($p.ExitCode -ne 0) {
        Throw "HlkxTool submit failed with exit code $($p.ExitCode)"
    }
}
Export-ModuleMember -Function Submit-Hlkx
