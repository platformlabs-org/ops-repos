#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-KeycloakAccessToken {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TokenUrl,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$Username,
    [Parameter(Mandatory)][string]$Password,
    [string]$Scope
  )

  if ([string]::IsNullOrWhiteSpace($TokenUrl)) { throw "Keycloak TokenUrl 为空" }
  if ([string]::IsNullOrWhiteSpace($ClientId)) { throw "Keycloak ClientId 为空" }
  if ([string]::IsNullOrWhiteSpace($Username)) { throw "Keycloak Username 为空" }
  if ([string]::IsNullOrWhiteSpace($Password)) { throw "Keycloak Password 为空" }

  $body = @{
    grant_type = 'password'
    client_id  = $ClientId
    username   = $Username
    password   = $Password
  }
  if ($Scope) { $body.scope = $Scope }

  Write-LogInfo "requesting API access token"

  try {
    $resp = Invoke-RestMethod -Method POST -Uri $TokenUrl `
      -ContentType 'application/x-www-form-urlencoded' `
      -Body $body -TimeoutSec 60 -ErrorAction Stop
  } catch {
    throw "Keycloak 获取 API token 失败：$($_.Exception.Message)"
  }

  $token = $null
  try { $token = [string]$resp.access_token } catch {}
  if ([string]::IsNullOrWhiteSpace($token)) { throw "Keycloak 响应缺少 access_token" }

  return $token
}

function Initialize-ApiTokenFromKeycloak {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Context)

  # OpsToken 仍然走外部注入（env:OPS_TOKEN），这里只初始化 ApiToken
  $kc = $Context.Settings.Auth.Keycloak
  if (-not $kc) { throw "settings.psd1 缺少 Auth.Keycloak 配置" }

  $tokenUrl = $env:KEYCLOAK_TOKEN_URL
  if (-not $tokenUrl) { $tokenUrl = $kc.TokenUrl }
  if (-not $tokenUrl) { throw "Keycloak TokenUrl 未配置（KEYCLOAK_TOKEN_URL 或 settings.Auth.Keycloak.TokenUrl）" }

  $clientId = $env:KEYCLOAK_CLIENT_ID
  if (-not $clientId) { $clientId = $kc.ClientId }
  if (-not $clientId) { throw "Keycloak ClientId 未配置（KEYCLOAK_CLIENT_ID 或 settings.Auth.Keycloak.ClientId）" }

  $username = $env:KEYCLOAK_USERNAME
  if (-not $username) { $username = $kc.Username }

  $password = $env:KEYCLOAK_PASSWORD
  if (-not $password) { $password = $kc.Password }

  $scope = $kc.Scope

  $apiToken = Get-KeycloakAccessToken -TokenUrl $tokenUrl -ClientId $clientId -Username $username -Password $password -Scope $scope

  $Context.Secrets.ApiToken = $apiToken
  # Write-LogOk "Keycloak API token ready"
}

Export-ModuleMember -Function Get-KeycloakAccessToken,Initialize-ApiTokenFromKeycloak
