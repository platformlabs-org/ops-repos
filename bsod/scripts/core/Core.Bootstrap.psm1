#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region TLS
try {
  [System.Net.ServicePointManager]::SecurityProtocol =
    [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.ServicePointManager]::SecurityProtocol
} catch {}
#endregion

# Core imports (order matters: Logging/IO first)
$moduleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $moduleRoot 'Core.Logging.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'Core.IO.psm1')      -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'Core.Env.psm1')     -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'Core.Config.psm1')  -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'Core.StateStore.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'Core.Http.psm1')    -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'Core.Auth.psm1')    -Force -DisableNameChecking

Export-ModuleMember -Function * -Alias *
