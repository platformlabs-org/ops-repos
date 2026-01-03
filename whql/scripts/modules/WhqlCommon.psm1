$ErrorActionPreference = 'Stop'

function Get-FormFieldValue {
    param(
        [string]$Body,
        [string]$Heading
    )
    # Matches patterns like:
    # ### Driver Project
    # Dispatcher
    # (Matches untill next ### or end of string)
    $pattern = "###\s+$Heading\s+(.+?)(\r?\n###|\r?\n$)"
    $match = [regex]::Match($Body, $pattern, 'Singleline')
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }
    return ""
}

function Get-SafeFileName {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    $invalidChars = [IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) {
        if ($invalidChars -contains $ch) { [void]$sb.Append('_') } else { [void]$sb.Append($ch) }
    }
    $result = $sb.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($result)) { return "HLKX" }
    return $result
}

function Quote-Arg {
    param([string]$s)
    if ($null -eq $s) { return '""' }
    if ($s -match '[\s"]') {
        return '"' + ($s -replace '"','\"') + '"'
    }
    return $s
}

function Get-HlkxToolPath {
    # Check env var first, then common locations
    if ($env:HLKX_TOOL_PATH -and (Test-Path $env:HLKX_TOOL_PATH)) {
        return [System.IO.Path]::GetFullPath($env:HLKX_TOOL_PATH)
    }

    # Check relative to script root (assuming this module is in whql/scripts/modules)
    # HlkxTool is typically in whql/HlkxTool/HlkxTool.exe
    # So from whql/scripts/modules, it is ../../HlkxTool/HlkxTool.exe
    $candidates = @(
        (Join-Path $PSScriptRoot "../../HlkxTool/HlkxTool.exe"),
        (Join-Path $PSScriptRoot "../../HlkxTool/HlkxTool") # Linux/Mac without extension?
    )

    foreach ($p in $candidates) {
        if (Test-Path $p) {
            return [System.IO.Path]::GetFullPath($p)
        }
    }

    throw "HlkxTool not found. Please set HLKX_TOOL_PATH or ensure it is in ../HlkxTool/"
}

function Get-LatestHlkxFromIssueAssets {
    param([object]$Issue)
    $attachments = $Issue.assets
    if (-not $attachments -or $attachments.Count -eq 0) { return $null }
    $hlkxAssets = $attachments | Where-Object { $_.name -like "*.hlkx" }
    if (-not $hlkxAssets -or $hlkxAssets.Count -eq 0) { return $null }

    return ($hlkxAssets | Sort-Object { if ($_.created_at) { [DateTime]$_.created_at } else { [DateTime]::MinValue } } -Descending | Select-Object -First 1)
}

function Get-LatestSubmitCommand {
    param([object[]]$Comments)
    if (-not $Comments -or $Comments.Count -eq 0) { return $null }
    $submitComments = $Comments | Where-Object { $_.body -match '^\s*/submit(\s|$)' }
    if (-not $submitComments -or $submitComments.Count -eq 0) { return $null }
    return ($submitComments | Sort-Object { [DateTime]$_.created_at } -Descending | Select-Object -First 1)
}

function Get-LatestSubmitCommandTime {
    param([object[]]$Comments)
    $cmd = Get-LatestSubmitCommand -Comments $Comments
    if ($cmd) { return $cmd.created_at }
    return $null
}

function Get-LatestHlkxFromComments {
    param(
        [object[]]$Comments
    )

    if (-not $Comments -or $Comments.Count -eq 0) { return $null }

    $candidates = @()
    foreach ($comment in $Comments) {
        if ($comment.assets) {
            foreach ($asset in $comment.assets) {
                if ($asset.name -like "*.hlkx") {
                    $assetTime = $null
                    if ($asset.created_at) { try { $assetTime = [DateTime]$asset.created_at } catch { } }
                    if ($assetTime -eq $null) { try { $assetTime = [DateTime]$comment.created_at } catch { $assetTime = [DateTime]::MinValue } }

                    $candidates += [PSCustomObject]@{
                        Name = $asset.name
                        Url = $asset.browser_download_url
                        Created = $assetTime
                        CommentId = $comment.id
                        AssetId = $asset.id
                        CommentBody = $comment.body
                    }
                }
            }
        }
    }

    if ($candidates.Count -eq 0) { return $null }
    return ($candidates | Sort-Object Created -Descending | Select-Object -First 1)
}

Export-ModuleMember -Function `
    Get-FormFieldValue, `
    Get-SafeFileName, `
    Quote-Arg, `
    Get-HlkxToolPath, `
    Get-LatestHlkxFromIssueAssets, `
    Get-LatestSubmitCommand, `
    Get-LatestSubmitCommandTime, `
    Get-LatestHlkxFromComments
