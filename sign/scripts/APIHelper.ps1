### ==========================================
### 🔐 获取 Token（优先环境变量，其次桌面 token.json）
### ==========================================
function Get-Tokens {
    $gitea = $env:GITEA_TOKEN
    $deepseek = $env:DEEPSEEK_TOKEN
    if ($gitea -and $deepseek) {
        return @{
            GiteaToken    = $gitea
            DeepSeekToken = $deepseek
        }
    }
    # fallback: 桌面 token.json
    $tokenPath = [System.IO.Path]::Combine([Environment]::GetFolderPath("Desktop"), "token.json")
    if (Test-Path $tokenPath) {
        $tokens = Get-Content -Raw -Path $tokenPath | ConvertFrom-Json
        return @{
            GiteaToken    = $tokens.bottoken
            DeepSeekToken = $tokens.dstoken
        }
    }
    throw "❌ 未设置环境变量 GITEA_TOKEN/DEEPSEEK_TOKEN，且未找到 token.json"
}

# 统一 Gitea API 地址（支持自定义）
function Get-GiteaApiUrl {
    $apiBase = $env:GITEA_API_URL
    if (-not $apiBase) {
        $apiBase = "https://ops.platformlabs.lenovo.com/api/v1"
    }
    return $apiBase.TrimEnd('/')
}

### ==========================================
### 1️⃣ Gitea API: Issue & 评论 & 附件管理
### ==========================================

function Get-IssueDetail {
    param (
        [string]$RepoPath,
        [string]$IssueID
    )
    $tokens = Get-Tokens
    $GiteaToken = $tokens.GiteaToken
    $apiBase = Get-GiteaApiUrl
    $url = "$apiBase/repos/$RepoPath/issues/$IssueID"
    $headers = @{
        'accept'        = 'application/json'
        'Authorization' = "token $GiteaToken"
    }
    try {
        $response = Invoke-RestMethod -Method GET -Uri $url -Headers $headers
        return $response
    } catch {
        throw "Failed to fetch issue detail: $_"
    }
}


function Get-CommentContent {
    param(
        [string]$RepoPath,
        [string]$CommentId
    )
    $tokens = Get-Tokens
    $GiteaToken = $tokens.GiteaToken
    $apiBase = Get-GiteaApiUrl
    $url = "$apiBase/repos/$RepoPath/issues/comments/$CommentId"
    $headers = @{
        'accept'        = 'application/json'
        'Authorization' = "token $GiteaToken"
    }
    try {
        $response = Invoke-RestMethod -Method "Get" -Uri $url -Headers $headers
        return $response.body
    } catch {
        throw "Failed to fetch comment content: $_"
    }
}

function Get-IssueAttachments {
    param (
        [string]$RepoPath,
        [string]$IssueID
    )
    $tokens = Get-Tokens
    $GiteaToken = $tokens.GiteaToken
    $apiBase = Get-GiteaApiUrl
    $Url = "$apiBase/repos/$RepoPath/issues/$IssueID/assets"
    $Headers = @{
        'Accept'        = 'application/json'
        'Authorization' = "token $GiteaToken"
    }
    return Invoke-API -Method "GET" -Url $Url -Headers $Headers
}

function Add-Comment {
    param (
        [string]$RepoPath,
        [string]$IssueID,
        [string]$Comment
    )
    $tokens = Get-Tokens
    $GiteaToken = $tokens.GiteaToken
    $apiBase = Get-GiteaApiUrl
    $Url = "$apiBase/repos/$RepoPath/issues/$IssueID/comments"
    $Headers = @{
        'Content-Type'  = "application/json"
        'Authorization' = "token $GiteaToken"
    }
    $Payload = @{ "body" = $Comment } | ConvertTo-Json
    return Invoke-API -Method "POST" -Url $Url -Headers $Headers -Body $Payload
}

function Add-Attachment {
    param(
        [Parameter(Mandatory)] [string]$RepoPath,
        [Parameter(Mandatory)] [int]$IssueID,
        [Parameter(Mandatory)] [int]$CommentID,
        [Parameter(Mandatory)] [string]$FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Error "❌ 文件不存在: $FilePath"
        return $false
    }

    $tokens = Get-Tokens
    $GiteaToken = $tokens.GiteaToken
    $apiBase = Get-GiteaApiUrl

    $headers = @{ Authorization = "token $GiteaToken" }

    # 1) 先尝试传到评论
    $urlComment = "$apiBase/repos/$RepoPath/issues/comments/$CommentID/assets"
    try {
        $form = @{ attachment = Get-Item -LiteralPath $FilePath }
        $resp = Invoke-RestMethod -Method Post -Uri $urlComment -Headers $headers -Form $form
        Write-Host "✅ 成功上传到评论附件: $FilePath"
        return $true
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        $body   = ""
        try { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $body = $sr.ReadToEnd() } catch {}
        Write-Warning "⚠️ 传评论失败 ($status)。服务器返回: $body"
        if ($status -ne 404) { return $false }  # 非 404 就别回退了
    }

    # 2) 回退：传到 issue 本体
    $urlIssue = "$apiBase/repos/$RepoPath/issues/$IssueID/assets"
    try {
        $form = @{ attachment = Get-Item -LiteralPath $FilePath }
        $resp = Invoke-RestMethod -Method Post -Uri $urlIssue -Headers $headers -Form $form
        Write-Host "✅ 成功上传到 Issue 附件: $FilePath"
        return $true
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        $body   = ""
        try { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $body = $sr.ReadToEnd() } catch {}
        Write-Error "❌ 上传附件失败 ($status): $body"
        return $false
    }
}

function Add-CommentWithAttachments {
    param(
        [Parameter(Mandatory)] [string]$RepoPath,
        [Parameter(Mandatory)] [int]$IssueID,
        [Parameter(Mandatory)] [string]$Comment,
        [Parameter(Mandatory)] [array]$FilePaths
    )

    $commentResponse = Add-Comment -RepoPath $RepoPath -IssueID $IssueID -Comment $Comment
    if (-not $commentResponse -or -not $commentResponse.id) {
        Write-Error "❌ 失败: 未能成功发布评论，附件未上传"
        return $null
    }
    $commentId = [int]$commentResponse.id
    Write-Host "✅ 成功发布评论: $commentId"

    $ok = 0; $fail = 0
    foreach ($file in $FilePaths) {
        Write-Host "🔄 正在上传文件: $file"
        if (Add-Attachment -RepoPath $RepoPath -IssueID $IssueID -CommentID $commentId -FilePath $file) {
            $ok++
        } else {
            $fail++
        }
    }

    if ($fail -eq 0) {
        Write-Host "✅ 所有附件上传成功（$ok/$($FilePaths.Count)）"
    } else {
        Write-Warning "⚠️ 附件上传完成：成功 $ok 个，失败 $fail 个"
    }
    return $commentId
}


function Update-IssueTitle {
    param(
        [string]$RepoPath,
        [string]$IssueId,
        [string]$NewTitle
    )
    $tokens = Get-Tokens
    $GiteaToken = $tokens.GiteaToken
    $apiBase = Get-GiteaApiUrl
    $updateUrl = "$apiBase/repos/$RepoPath/issues/$IssueId"
    $headers = @{
        'accept' = 'application/json'
        'Authorization' = "token $GiteaToken"
        'Content-Type' = 'application/json'
    }
    $body = @{
        "title" = $NewTitle
    } | ConvertTo-Json -Depth 10
    try {
        $TitleResponse = Invoke-RestMethod -Uri $updateUrl -Headers $headers -Method Patch -Body $body
        return $TitleResponse.title
    } catch {
        throw "Failed to update issue: $_"
    }
}

function Download-FileWithProgress {
    param (
        [string]$Url,
        [string]$OutputPath
    )
    $tokens = Get-Tokens
    $GiteaToken = $tokens.GiteaToken
    $startTime = Get-Date
    $lastUpdateTime = $startTime
    $totalBytesReceived = 0

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Headers.Add("Authorization", "token $GiteaToken")
    $response = $request.GetResponse()
    $stream = $response.GetResponseStream()
    $fileStream = [System.IO.File]::OpenWrite($OutputPath)
    $buffer = New-Object byte[] 262144  # 256KB buffer
    $totalBytes = $response.ContentLength
    $bytesRead = 0

    while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $fileStream.Write($buffer, 0, $bytesRead)
        $totalBytesReceived += $bytesRead

        $currentTime = Get-Date
        $timeElapsed = ($currentTime - $startTime).TotalSeconds

        if (($currentTime - $lastUpdateTime).TotalSeconds -ge 10 -or $totalBytesReceived -eq $totalBytes) {
            $downloadSpeed = [math]::Round(($totalBytesReceived / $timeElapsed) / 1MB, 1)
            $percentComplete = [math]::Round(($totalBytesReceived / $totalBytes) * 100, 1)
            $timeRemaining = if ($percentComplete -eq 0) { "未知" } else { [math]::Round((($totalBytes - $totalBytesReceived) / ($totalBytesReceived / $timeElapsed)) / 60, 1) }
            Write-Host "📥 下载进度: $percentComplete% | 速度: $downloadSpeed MB/s | 预计剩余: $timeRemaining 分钟"
            $lastUpdateTime = $currentTime
        }
    }
    $fileStream.Close(); $stream.Close(); $response.Close()
    Write-Host "✅ 下载完成: $OutputPath"
}

### ==========================================
### 3️⃣ 通用 API 方法: 统一封装 REST 请求
### ==========================================

function Invoke-API {
    param (
        [string]$Method,
        [string]$Url,
        [hashtable]$Headers,
        [string]$Body = $null
    )
    try {
        $Params = @{
            Uri         = $Url
            Headers     = $Headers
            Method      = $Method
            TimeoutSec  = 60
        }
        if ($Method -eq "POST" -or $Method -eq "PUT" -or $Method -eq "PATCH") {
            $Params["Body"] = $Body
        }
        return Invoke-RestMethod @Params
    } catch {
        Write-Error "❌ API 调用失败: $_"
        exit 1
    }
}
