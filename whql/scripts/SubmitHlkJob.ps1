param(
    [Parameter(Mandatory)]
    [string]$Repository,
    [Parameter(Mandatory)]
    [string]$IssueNumber,
    [Parameter(Mandatory)]
    [string]$AccessToken
)

$ErrorActionPreference = 'Stop'

# 导入封装好的 HTTP 模块
Import-Module (Join-Path $PSScriptRoot 'OpsApi.psm1') -Force

function Get-FormFieldValue {
    param(
        [string]$Body,
        [string]$Heading
    )
    # 匹配类似：
    # ### Driver Project
    # Dispatcher
    $pattern = "###\s+$Heading\s+(.+?)(\r?\n###|\r?\n$)"
    $match = [regex]::Match($Body, $pattern, 'Singleline')
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }
    else {
        return ""
    }
}

try {
    Write-Host "[Submit] Starting SubmitHlkJob.ps1"

    # 获取 Issue 信息
    $issue = Get-OpsIssue -Repo $Repository -Number $IssueNumber -Token $AccessToken

    # 1. 获取 Submitter Email
    # 注意: Gitea API 返回的 user 对象可能包含 email，但也可能隐藏。
    # 这里假设 API 返回中有 email 字段。如果 user.email 为空，尝试寻找其他途径或报错。
    $submitterEmail = $issue.user.email
    if ([string]::IsNullOrWhiteSpace($submitterEmail)) {
        throw "Could not determine submitter email from issue author ($($issue.user.login))."
    }
    Write-Host "[Submit] Submitter Email: $submitterEmail"

    # 2. 解析 Driver Project 和 Driver Version
    $bodyText = $issue.body
    $driverProject = Get-FormFieldValue -Body $bodyText -Heading "Driver Project"
    if ([string]::IsNullOrWhiteSpace($driverProject)) {
        $driverProject = Get-FormFieldValue -Body $bodyText -Heading "filetype"
    }
    $driverVersion = Get-FormFieldValue -Body $bodyText -Heading "Driver Version"

    Write-Host "[Submit] Driver Project: $driverProject"
    Write-Host "[Submit] Driver Version: $driverVersion"

    if ([string]::IsNullOrWhiteSpace($driverProject)) {
        throw "Driver Project is required."
    }
    if ([string]::IsNullOrWhiteSpace($driverVersion)) {
        throw "Driver Version is required."
    }

    # 3. 查找最新的 Bot 评论中的 HLKX 附件
    $comments = Get-OpsIssueComments -Repo $Repository -Number $IssueNumber -Token $AccessToken

    # 过滤条件：
    # - 包含附件
    # - 附件名以 .hlkx 结尾
    # - 评论作者看起来是 Bot (这里简单判断 username 包含 bot，或者 type 为 Bot)
    #   注意: 实际 Gitea 中 actions-user 或者 bot 用户的 user.type 通常是 'Bot' (或 'User' 但名字特殊)

    $hlkxAttachments = @()

    foreach ($comment in $comments) {
        # 简单判断是否是 Bot 发的
        # 这里为了稳健，假设 username 包含 "bot" 或者 user.type == "Bot"
        # 实际情况可能需要根据 ops 环境调整
        $isBot = ($comment.user.username -match "bot") -or ($comment.user.type -eq "Bot")

        if (-not $isBot) { continue }

        if ($comment.assets) {
            foreach ($asset in $comment.assets) {
                if ($asset.name -like "*.hlkx") {
                    # 记录对象：附件信息 + 评论时间 (以便排序)
                    $hlkxAttachments += [PSCustomObject]@{
                        Name        = $asset.name
                        Url         = $asset.browser_download_url
                        Created     = [DateTime]$comment.created_at
                        AssetObject = $asset
                    }
                }
            }
        }
    }

    if ($hlkxAttachments.Count -eq 0) {
        throw "No HLKX attachments found in bot comments."
    }

    # 按时间降序排列，取最新的
    $latestHlkx = $hlkxAttachments | Sort-Object Created -Descending | Select-Object -First 1

    Write-Host "[Submit] Found latest HLKX: $($latestHlkx.Name) from comment at $($latestHlkx.Created)"

    # 4. 下载附件
    $tempDir = Join-Path (Get-Location) "temp\submit_downloads"
    if (-not (Test-Path $tempDir)) {
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    }
    $localHlkxPath = Join-Path $tempDir $latestHlkx.Name

    Invoke-OpsDownloadFile -Url $latestHlkx.Url -TargetPath $localHlkxPath -Token $AccessToken

    # 5. 构造 HlkxTool 命令
    # 优先使用相对脚本路径寻找工具，确保路径稳健
    # 脚本在 whql/scripts/，工具在 whql/HlkxTool/HlkxTool.exe
    $toolPath = Join-Path $PSScriptRoot "..\HlkxTool\HlkxTool.exe"
    $hlkxTool = [System.IO.Path]::GetFullPath($toolPath)

    if (-not (Test-Path $hlkxTool)) {
        # 如果找不到，尝试当前目录下的 HlkxTool/HlkxTool.exe (兼容调试)
        $cwdPath = ".\HlkxTool\HlkxTool.exe"
        if (Test-Path $cwdPath) {
            $hlkxTool = [System.IO.Path]::GetFullPath($cwdPath)
        } else {
             throw "HlkxTool.exe not found at $hlkxTool or $cwdPath"
        }
    }

    $hlkxArgs = @(
        "submit",
        "--hlkx", "`"$localHlkxPath`"",
        "--to", "$submitterEmail",
        "--driver-name", "`"$driverProject`"",
        "--driver-type", "WHQL",
        "--fw", "`"$driverVersion`"",
        "--yes"
    )

    Write-Host "[Submit] Running: $hlkxTool $($hlkxArgs -join ' ')"

    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = $hlkxTool
    $pinfo.Arguments = $hlkxArgs -join ' '
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.UseShellExecute = $false

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $pinfo
    $p.Start() | Out-Null

    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()

    $p.WaitForExit()

    $exitCode = $p.ExitCode
    $fullOutput = "STDOUT:`n$stdout`nSTDERR:`n$stderr"

    if ($exitCode -eq 0) {
        $message = "✅ **Submission Successful!**`n`n````n$stdout`n```"
        New-OpsIssueComment -Repo $Repository -Number $IssueNumber -Token $AccessToken -BodyText $message | Out-Null
    }
    else {
        throw "HlkxTool submit failed with exit code $exitCode.`n$fullOutput"
    }

} catch {
    $errorMsg = $_.Exception.Message
    Write-Host "::error::$errorMsg"

    # 尝试在 Issue 中回复错误信息
    try {
        $failMessage = "❌ **Submission Failed**`n`nError: $errorMsg"
        New-OpsIssueComment -Repo $Repository -Number $IssueNumber -Token $AccessToken -BodyText $failMessage | Out-Null
    } catch {
        Write-Host "Failed to post error comment: $($_.Exception.Message)"
    }

    exit 1
}
