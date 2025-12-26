#requires -Version 5.1
Set-StrictMode -Version Latest

function Invoke-TaskFinalize {
  param([Parameter(Mandatory)]$Context)
  Write-LogInfo "=== Phase: Finalize ==="
  Write-LogOk "Finalize done."
}

Export-ModuleMember -Function Invoke-TaskFinalize
