
function Send-TeamsNotification {
    param(
        [Parameter(Mandatory)][string]$EventType,
        [Parameter(Mandatory)][string]$ToUpn,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Version,
        [string]$IssueUrl,
        [string]$PrUrl,
        [string]$PartnerCenterUrl,
        [string]$Message
    )

    $webhookUrl = $env:DUA_TEAMS_WEBHOOK_URL
    if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
        Write-Warning "DUA_TEAMS_WEBHOOK_URL is not set. Skipping Teams notification."
        return
    }

    $payload = @{
        eventType = $EventType
        toUpn     = $ToUpn
        project   = $Project
        version   = $Version
    }

    if ($IssueUrl) { $payload["issueUrl"] = $IssueUrl }
    if ($PrUrl)    { $payload["prUrl"]    = $PrUrl }
    if ($PartnerCenterUrl) { $payload["partnerCenterUrl"] = $PartnerCenterUrl }
    if ($Message)  { $payload["message"]  = $Message }

    $jsonPayload = $payload | ConvertTo-Json -Depth 5 -Compress

    Write-Host "Sending Teams Notification: $EventType for $ToUpn"

    try {
        $response = Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $jsonPayload -ContentType "application/json"
        Write-Host "Notification sent successfully."
    } catch {
        Write-Warning "Failed to send Teams notification: $_"
    }
}

Export-ModuleMember -Function Send-TeamsNotification
