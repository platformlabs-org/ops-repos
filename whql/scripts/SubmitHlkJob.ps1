param(
    [Parameter(Mandatory)]
    [string]$Repository,
    [Parameter(Mandatory)]
    [string]$IssueNumber,
    [Parameter(Mandatory)]
    [string]$AccessToken
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'OpsApi.psm1') -Force

function Get-FormFieldValue {
    param(
        [string]$Body,
        [string]$Heading
    )
    # 与 PrepareHlkJob.ps1 保持一致
    $pattern = "###\s+$Heading\s+(.+?)(\r?\n###|\r?\n$)"
    $match = [regex]::Match($Body, $pattern, 'Singleline')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return ""
}

function Get-LatestHlkxFromIssueAssets {
    param([object]$Issue)

    $attachments = $Issue.assets
    if (-not $attachments -or $attachments.Count -eq 0) { return $null }

    $hlkxAssets = $attachments | Where-Object { $_.name -like "*.hlkx" }
    if (-not $hlkxAssets -or $hlkxAssets.Count -eq 0) { return $null }

    # 若 created_at 存在则取最新；否则取第一个
    $hasCreatedAt = $false
    try { if ($hlkxAssets[0].created_at) { $hasCreatedAt = $true } } catch { $hasCreatedAt = $false }

    if ($hasCreatedAt) {
        return ($hlkxAssets | Sort-Object { [DateTime]$_.created_at } -Descending | Select-Object -First 1)
    }
    return ($hlkxAssets | Select-Object -First 1)
}

function Get-LatestSubmitCommandTime {
    param([object[]]$Comments)

    if (-not $Comments -or $Comments.Count -eq 0) { return $null }

    $submitComments = $Comments | Where-Object {
        $_.body -match '^\s*/submit(\s|$)'
    }

    if (-not $submitComments -or $submitComments.Count -eq 0) { return $null }

    return ($submitComments | Sort-Object { [DateTime]$_.created_at } -Descending | Select-Object -First 1).created_at
}

function Get-LatestHlkxFromBotComments {
    param(
        [object[]]$Comments,
        [Nullable[DateTime]]$CutoffTime = $null   # 只取某时间之后的 HLKX（比如最后一次 /submit 之后）
    )

    if (-not $Comments -or $Comments.Count -eq 0) { return $null }

    $candidates = @()

    foreach ($comment in $Comments) {
        # 适配你提供的格式：user.login / user.username
        $login = $comment.user.login
        $uname = $comment.user.username

        $isBot = ($login -eq "bot") -or ($uname -eq "bot") -or ($login -match "bot") -or ($uname -match "bot")
        if (-not $isBot) { continue }

        # cutoff：按 comment.created_at 过滤（因为 assets.created_at 一般 >= comment.created_at）
        if ($CutoffTime -ne $null) {
            $commentTime = $null
            try { $commentTime = [DateTime]$comment.created_at } catch { $commentTime = $null }
            if ($commentTime -ne $null -and $commentTime -lt $CutoffTime.Value) {
                continue
            }
        }

        if ($comment.assets) {
            foreach ($asset in $comment.assets) {
                if ($asset.name -like "*.hlkx") {
                    # 关键：以 asset.created_at 为准（你给的格式里 assets 有 created_at）
                    $assetTime = $null
                    if ($asset.created_at) {
                        try { $assetTime = [DateTime]$asset.created_at } catch { $assetTime = $null }
                    }
                    if ($assetTime -eq $null -and $comment.created_at) {
                        try { $assetTime = [DateTime]$comment.created_at } catch { $assetTime = [DateTime]::MinValue }
                    }
                    if ($assetTime -eq $null) { $assetTime = [DateTime]::MinValue }

                    $candidates += [PSCustomObject]@{
                        Name          = $asset.name
                        Url           = $asset.browser_download_url
                        Created       = $assetTime
                        CommentId     = $comment.id
                        CommentBody   = $comment.body
                        CommentTime   = [DateTime]$comment.created_at
                        AssetId       = $asset.id
                    }
                }
            }
        }
    }

    if ($candidates.Count -eq 0) { return $null }

    return ($candidates | Sort-Object Created -Descending | Select-Object -First 1)
}

function Build-ProcessStartInfo {
    param(
        [string]$ExePath,
        [string[]]$Args
    )

    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = $ExePath
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError  = $true
    $pinfo.UseShellExecute        = $false

    # 优先用 ArgumentList（pwsh/.NET Core 环境更稳），否则退回 Arguments 字符串
    $useArgList = $false
    try {
        $null = $pinfo.ArgumentList
        $useArgList = $true
    } catch {
        $useArgList = $false
    }

    if ($useArgList) {
        foreach ($a in $Args) { [void]$pinfo.ArgumentList.Add($a) }
    } else {
        # 退回：构造命令行字符串（对包含空格/引号的参数做保护）
        $quote = {
            param([string]$s)
            if ($null -eq $s) { return '""' }
            if ($s -match '[\s"]') {
                return '"' + ($s -replace '"','\"') + '"'
            }
            return $s
        }
        $pinfo.Arguments = ($Args | ForEach-Object { & $quote $_ }) -join ' '
    }

    return $pinfo
}

try {
    Write-Host "[Submit] Starting SubmitHlkJob.ps1"

    # 1) 获取 Issue
    $issue = Get-OpsIssue -Repo $Repository -Number $IssueNumber -Token $AccessToken

    # 2) Submitter Email
    $submitterEmail = $issue.user.email
    if ([string]::IsNullOrWhiteSpace($submitterEmail)) {
        throw "Could not determine submitter email from issue author ($($issue.user.login))."
    }
    Write-Host "[Submit] Submitter Email: $submitterEmail"

    # 3) 解析字段（跟 Prepare 一致）
    $bodyText = $issue.body
    $driverProject = Get-FormFieldValue -Body $bodyText -Heading "Driver Project"
    if ([string]::IsNullOrWhiteSpace($driverProject)) {
        $driverProject = Get-FormFieldValue -Body $bodyText -Heading "filetype"
    }
    $driverVersion = Get-FormFieldValue -Body $bodyText -Heading "Driver Version"

    Write-Host "[Submit] Driver Project: $driverProject"
    Write-Host "[Submit] Driver Version: $driverVersion"

    if ([string]::IsNullOrWhiteSpace($driverProject)) { throw "Driver Project is required." }
    if ([string]::IsNullOrWhiteSpace($driverVersion)) { throw "Driver Version is required." }

    # 4) 选择 HLKX：优先 issue.assets
    $selectedHlkxName = $null
    $selectedHlkxUrl  = $null
    $selectedFrom     = $null

    $issueHlkx = Get-LatestHlkxFromIssueAssets -Issue $issue
    if ($issueHlkx) {
        $selectedHlkxName = $issueHlkx.name
        $selectedHlkxUrl  = $issueHlkx.browser_download_url
        $selectedFrom     = "issue.assets"
        Write-Host "[Submit] HLKX selected from issue.assets: $selectedHlkxName"
    } else {
        # 5) 回退：从 comments 里找（按你给的格式：user.login + assets.created_at）
        $comments = Get-OpsIssueComments -Repo $Repository -Number $IssueNumber -Token $AccessToken

        # 关键：只取最后一次 /submit 之后的 HLKX，避免拿到旧包
        $submitAtRaw = Get-LatestSubmitCommandTime -Comments $comments
        $cutoff = $null
        if ($submitAtRaw) {
            try { $cutoff = [DateTime]$submitAtRaw } catch { $cutoff = $null }
        }
        if ($cutoff) {
            Write-Host "[Submit] Latest /submit at: $cutoff (will only consider bot HLKX after this time)"
        } else {
            Write-Host "[Submit] No /submit found, will consider any bot HLKX."
        }

        $latestBotHlkx = Get-LatestHlkxFromBotComments -Comments $comments -CutoffTime $cutoff
        if ($latestBotHlkx) {
            $selectedHlkxName = $latestBotHlkx.Name
            $selectedHlkxUrl  = $latestBotHlkx.Url
            $selectedFrom     = "bot comments (commentId=$($latestBotHlkx.CommentId), assetId=$($latestBotHlkx.AssetId), assetTime=$($latestBotHlkx.Created))"
            Write-Host "[Submit] HLKX selected from $selectedFrom : $selectedHlkxName"
        }
    }

    if ([string]::IsNullOrWhiteSpace($selectedHlkxName) -or [string]::IsNullOrWhiteSpace($selectedHlkxUrl)) {
        throw "No HLKX found. Please attach a .hlkx to the issue OR ensure the workflow posts it as a bot comment attachment."
    }

    # 6) 下载 HLKX
    $tempDir = Join-Path (Get-Location) "temp\submit_downloads"
    if (-not (Test-Path $tempDir)) {
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    }
    $localHlkxPath = Join-Path $tempDir $selectedHlkxName

    Write-Host "[Submit] Downloading HLKX ($selectedFrom) => $localHlkxPath"
    Invoke-OpsDownloadFile -Url $selectedHlkxUrl -TargetPath $localHlkxPath -Token $AccessToken

    # 7) HlkxTool 路径
    $toolPath = Join-Path $PSScriptRoot "..\HlkxTool\HlkxTool.exe"
    $hlkxTool = [System.IO.Path]::GetFullPath($toolPath)

    if (-not (Test-Path $hlkxTool)) {
        $cwdPath = ".\HlkxTool\HlkxTool.exe"
        if (Test-Path $cwdPath) {
            $hlkxTool = [System.IO.Path]::GetFullPath($cwdPath)
        } else {
            throw "HlkxTool.exe not found at $hlkxTool or $cwdPath"
        }
    }

    # 8) 执行 submit（替换原来的 ProcessStartInfo + ReadToEnd 那一段）

    $hlkxArgs = @(
        "submit"
        "--hlkx", $localHlkxPath
        "--to", $submitterEmail
        "--driver-name", "$driverProject $driverVersion"
        "--driver-type", "WHQL"
        "--fw", $driverVersion
        "--yes"
        "--non-interactive"
    )

    Write-Host "[Submit] Running: $hlkxTool $($hlkxArgs -join ' ')"

    $stdoutFile = Join-Path $tempDir "hlkxtool_stdout.txt"
    $stderrFile = Join-Path $tempDir "hlkxtool_stderr.txt"

    # 清理旧文件
    if (Test-Path $stdoutFile) { Remove-Item $stdoutFile -Force }
    if (Test-Path $stderrFile) { Remove-Item $stderrFile -Force }

    $p = Start-Process -FilePath $hlkxTool `
                       -ArgumentList $hlkxArgs `
                       -NoNewWindow `
                       -PassThru `
                       -RedirectStandardOutput $stdoutFile `
                       -RedirectStandardError  $stderrFile

    Write-Host "[Submit] HlkxTool started. Waiting..."

    # 心跳等待（避免看起来“卡死”）
    while (-not $p.HasExited) {
        Start-Sleep -Seconds 10
        Write-Host "[Submit] ...still running (pid=$($p.Id))"
    }

    $exitCode = $p.ExitCode
    $stdout = if (Test-Path $stdoutFile) { Get-Content -Raw $stdoutFile } else { "" }
    $stderr = if (Test-Path $stderrFile) { Get-Content -Raw $stderrFile } else { "" }

    $fullOutput = "STDOUT:`n$stdout`nSTDERR:`n$stderr"

    if ($exitCode -eq 0) {
        $message = "✅ **Submission Succeeded**`n`nDriver: $driverProject $driverVersion`nHLKX: $selectedHlkxName (from $selectedFrom)`n`n$stdout"
        Write-Host "[Submit] HlkxTool completed successfully."
        New-OpsIssueComment -Repo $Repository -Number $IssueNumber -Token $AccessToken -BodyText $message | Out-Null
    } else {
        $msg = "HlkxTool submit failed with exit code {0}.{1}{2}" -f $exitCode, [Environment]::NewLine, $fullOutput
        throw $msg
    }
}
catch {
    $errorMsg = $_.Exception.Message
    Write-Host "::error::$errorMsg"

    try {
        $failMessage = "❌ **Submission Failed**`n`nError: $errorMsg"
        New-OpsIssueComment -Repo $Repository -Number $IssueNumber -Token $AccessToken -BodyText $failMessage | Out-Null
    } catch {
        Write-Host "Failed to post error comment: $($_.Exception.Message)"
    }

    exit 1
}
