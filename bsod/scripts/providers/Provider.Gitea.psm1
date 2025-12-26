#requires -Version 5.1
Set-StrictMode -Version Latest

function Resolve-GiteaPath {
  param([Parameter(Mandatory)][string]$Template,[Parameter(Mandatory)][string]$Repo,[Parameter(Mandatory)][int]$IssueId)
  return ($Template -replace '\{repo\}',$Repo -replace '\{issue\}',$IssueId)
}

function Get-GiteaIssue {
  param(
    [Parameter(Mandatory)]$Settings,
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][int]$IssueId,
    [Parameter(Mandatory)][string]$OpsToken
  )
  $base = Ensure-HttpsBase $Settings.Endpoints.OpsBaseUrl
  $path = Resolve-GiteaPath -Template $Settings.Endpoints.GiteaApiPaths.Issue -Repo $RepoPath -IssueId $IssueId
  $url  = Ensure-HttpsUrl -Url "$base$path" -Base $base
  Invoke-HttpJson -Method GET -Url $url -Headers (New-BearerHeaders -Token $OpsToken) -TimeoutSec $Settings.General.HttpTimeoutSec
}

function Get-GiteaIssueAttachments {
  param(
    [Parameter(Mandatory)]$Settings,
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][int]$IssueId,
    [Parameter(Mandatory)][string]$OpsToken
  )
  $issue = Get-GiteaIssue -Settings $Settings -RepoPath $RepoPath -IssueId $IssueId -OpsToken $OpsToken
  if ($null -eq $issue) { return @() }

  $names = @($issue.PSObject.Properties.Name)
  if ($names -contains 'attachments' -and $issue.attachments) { return $issue.attachments }
  if ($names -contains 'assets' -and $issue.assets) { return $issue.assets }
  return @()
}

function Add-GiteaIssueComment {
  param(
    [Parameter(Mandatory)]$Settings,
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][int]$IssueId,
    [Parameter(Mandatory)][string]$OpsToken,
    [Parameter(Mandatory)][string]$Markdown
  )
  $base = Ensure-HttpsBase $Settings.Endpoints.OpsBaseUrl
  $path = Resolve-GiteaPath -Template $Settings.Endpoints.GiteaApiPaths.IssueComments -Repo $RepoPath -IssueId $IssueId
  $url  = Ensure-HttpsUrl -Url "$base$path" -Base $base
  Invoke-HttpJson -Method POST -Url $url -Headers (New-BearerHeaders -Token $OpsToken) -Body @{ body=$Markdown } -TimeoutSec $Settings.General.HttpTimeoutSec
}

function Update-GiteaIssueTitle {
  param(
    [Parameter(Mandatory)]$Settings,
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][int]$IssueId,
    [Parameter(Mandatory)][string]$OpsToken,
    [Parameter(Mandatory)][string]$Title
  )
  $base = Ensure-HttpsBase $Settings.Endpoints.OpsBaseUrl
  $path = Resolve-GiteaPath -Template $Settings.Endpoints.GiteaApiPaths.UpdateIssue -Repo $RepoPath -IssueId $IssueId
  $url  = Ensure-HttpsUrl -Url "$base$path" -Base $base
  Invoke-HttpJson -Method PATCH -Url $url -Headers (New-BearerHeaders -Token $OpsToken) -Body @{ title=$Title } -TimeoutSec $Settings.General.HttpTimeoutSec
}

Export-ModuleMember -Function Get-GiteaIssue,Get-GiteaIssueAttachments,Add-GiteaIssueComment,Update-GiteaIssueTitle
