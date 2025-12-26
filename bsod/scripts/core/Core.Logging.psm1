#requires -Version 5.1
Set-StrictMode -Version Latest

function Write-LogInfo { param([Parameter(Mandatory)][string]$Message) Write-Host "ℹ️  $Message" }
function Write-LogOk   { param([Parameter(Mandatory)][string]$Message) Write-Host "✅ $Message" }
function Write-LogWarn { param([Parameter(Mandatory)][string]$Message) Write-Warning $Message }
function Write-LogErr  { param([Parameter(Mandatory)][string]$Message) Write-Error $Message }

Export-ModuleMember -Function Write-LogInfo,Write-LogOk,Write-LogWarn,Write-LogErr
