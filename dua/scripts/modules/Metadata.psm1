
function Get-ShortVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    # Regex to find sequences of 4 or more digits
    $pattern = "\b\d{4,}\b"
    $matches = [Regex]::Matches($Name, $pattern)

    if ($matches.Count -gt 0) {
        # Take the last match found
        $lastMatch = $matches[$matches.Count - 1].Value
        # Return the last 4 characters of that match
        return $lastMatch.Substring($lastMatch.Length - 4)
    }

    # Fallback: if no 4+ digit sequence found, return "Unknown" or similar?
    # Or try finding any digits?
    return "0000"
}

function Get-StrategyLabel {
    param(
        [string]$InfStrategy
    )

    switch -Regex ($InfStrategy) {
        "^graphic-base" { return "Gfx-Base" }
        "^graphic-ext"  { return "Gfx-Ext" }
        "^npu-ext"      { return "NPU-Ext" }
        Default         { return $null }
    }
}

function Update-IssueMetadata {
    param(
        [Parameter(Mandatory)][string]$IssueNumber,
        [Parameter(Mandatory)][string]$RepoOwner,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$SubmissionName,
        [Parameter(Mandatory)][string]$Status,
        [string]$InfStrategy
    )

    Write-Host "Updating Issue Metadata for #$IssueNumber..."

    # 1. Determine Version
    $version = Get-ShortVersion -Name $SubmissionName

    # 2. Determine Label
    $labelToAdd = $null
    if (-not [string]::IsNullOrWhiteSpace($InfStrategy)) {
        $labelToAdd = Get-StrategyLabel -InfStrategy $InfStrategy
    }

    # 3. Construct Title
    # Format: [Status][Project Name][Version] Full Submission Name
    $newTitle = "[$Status][$ProjectName][$version] $SubmissionName"

    # 4. Update Title
    Set-IssueTitle -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Title $newTitle -Token $Token | Out-Null
    Write-Host "Updated Title: $newTitle"

    # 5. Add Label (if applicable)
    if ($labelToAdd) {
        Add-IssueLabels -Owner $RepoOwner -Repo $RepoName -IssueNumber $IssueNumber -Labels @($labelToAdd) -Token $Token | Out-Null
        Write-Host "Added Label: $labelToAdd"
    }
}

Export-ModuleMember -Function Get-ShortVersion, Get-StrategyLabel, Update-IssueMetadata
