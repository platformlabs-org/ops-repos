function Identify-InfType {
    param([string]$Content)

    if ($Content -match "npu_extension\.cat") { return "npu.extension" }
    if ($Content -match "extinf_i\.cat") { return "gfx.extension" }
    if ($Content -match "igdlh\.cat") { return "gfx.base" }

    return $null
}

function Format-Binary {
    param([string]$HexStr)

    $clean = $HexStr -replace "\s+", "" -replace "0x", ""
    $bytes = @()
    for ($i = 0; $i -lt $clean.Length; $i += 2) {
        if ($i + 1 -lt $clean.Length) {
            $bytes += $clean.Substring($i, 2)
        }
    }
    return $bytes -join ", "
}

function Process-Inf {
    param(
        [string]$InfContent,
        [object]$Config,    # The specific config node (e.g., config.project.kailash.gfx.extension)
        [string]$InfType    # e.g., "gfx.extension"
    )

    $lines = $InfContent -split "\r?\n"
    $output = @()
    $currentSection = ""

    # 强制将配置项转换为数组，避免单项解析为字符串的坑
    $devIds = @()
    if ($null -ne $Config.dev_id) { $devIds = @($Config.dev_id) }
    
    $subsysIds = @()
    if ($null -ne $Config.subsys_id) { $subsysIds = @($Config.subsys_id) }
    
    $extId = $Config.extension_id
    $regFuncs = $Config.register_function

    $dynamicInstallSections = @()

    # =========================================================================
    # 第一遍扫描 (Pass 1): 精准锁定目标 Hardware ID 映射的 Install Sections
    # =========================================================================
    foreach ($line in $lines) {
        # 匹配 PCI\VEN_8086&DEV_XXXX
        if ($line -match "PCI\\VEN_8086&DEV_([0-9A-Fa-f]{4})") {
            $currentDevId = $Matches[1]
            $isTargetDev = ($devIds.Count -eq 0) -or ($devIds -contains $currentDevId)

            if ($isTargetDev) {
                # 严谨正则：开头允许空格，接着是 %变量% = 目标Section名,
                if ($line -match "^\s*%[^%]+%\s*=\s*([^,]+),") {
                    $sec = $Matches[1].Trim()
                    if ($sec -and $dynamicInstallSections -notcontains $sec) {
                        $dynamicInstallSections += $sec
                    }
                }
            }
        }
    }

    # =========================================================================
    # 第二遍扫描 (Pass 2): 生成最终 INF 内容
    # =========================================================================
    foreach ($line in $lines) {
        $stripped = $line.Trim()

        # 1. 识别并处理 Section 头部 (例如 [ARLS_IG])
        if ($stripped -match "^\[(.*)\]$") {
            $currentSection = $Matches[1].Trim()
            $output += $line # 写入 Section 标题行
            
            # 关键修复：只要进入了目标 Section，紧随其后立刻注入 AddReg，不再依赖空行
            if ($dynamicInstallSections -contains $currentSection -and $null -ne $regFuncs) {
                foreach ($key in $regFuncs.PSObject.Properties.Name) {
                    $output += "AddReg = $key"
                }
            }
            continue
        }

        # 2. 替换 ExtensionId
        if ($currentSection -eq "Version" -and $line -match "^\s*ExtensionId\s*=" -and $extId) {
            $output += "ExtensionId = {$extId}"
            continue
        }

        # 3. 替换/保留 Hardware ID (SUBSYS)
        if ($line -match "PCI\\VEN_8086&DEV_([0-9A-Fa-f]{4})") {
            $currentDevId = $Matches[1]
            $isTargetDev = ($devIds.Count -eq 0) -or ($devIds -contains $currentDevId)

            if ($isTargetDev) {
                if ($subsysIds.Count -gt 0) {
                    # 如果提供了 subsys_id，则生成替换行
                    foreach ($sId in $subsysIds) {
                        if ($line -match "SUBSYS_[a-zA-Z0-9]+") {
                            $output += ($line -replace "SUBSYS_[a-zA-Z0-9]+", "SUBSYS_$sId")
                        } else {
                            $output += ($line.TrimEnd() + "&SUBSYS_$sId")
                        }
                    }
                    continue # 替换完毕，跳过原始行
                } else {
                    # 关键修复：如果没有提供 subsys_id，必须保留原始行！
                    $output += $line
                    continue
                }
            }
        }

        # 默认：原样输出当前行
        $output += $line
    }

    # =========================================================================
    # 尾部追加 Registry Block
    # =========================================================================
    if ($null -ne $regFuncs) {
        $output += ""
        $output += "; --- Generated Brightness Registry Sections ---"

        foreach ($fName in $regFuncs.PSObject.Properties.Name) {
            $output += "[$fName]"
            $items = $regFuncs.$fName
            foreach ($item in $items) {
                $key = $item[0]
                $valType = $item[1]
                $val = $item[2]

                # 增加对 REG_SZ 的后备支持以提高兼容性
                $regType = "%REG_SZ%"
                if ($valType -eq "d") { $regType = "%REG_DWORD%" }
                elseif ($valType -eq "b") { $regType = "%REG_BINARY%" }

                $finalVal = if ($valType -eq "b") { Format-Binary -HexStr ([string]$val) } else { $val }

                $output += "HKR,, $key, $regType, $finalVal"
            }
            $output += ""
        }
    }

    return $output -join "`r`n"
}

function Patch-Inf-Advanced {
    param(
        [string]$InfPath,
        [string]$ConfigPath,
        [string]$ProjectName
    )

    Write-Host "Starting Advanced INF Patching for $ProjectName on $InfPath"

    if (-not (Test-Path $ConfigPath)) { Throw "Config not found: $ConfigPath" }
    $fullConfig = Get-Content $ConfigPath | ConvertFrom-Json

    if (-not $fullConfig.project.$ProjectName) { Throw "Project '$ProjectName' not found in config." }
    $projectConfig = $fullConfig.project.$ProjectName

    # 允许自动检测 BOM 而非强制 UTF8
    $content = Get-Content $InfPath -Raw

    $infType = Identify-InfType -Content $content
    if (-not $infType) {
        Write-Warning "Could not identify INF type from content catalogs. Defaulting to generic patching or skipping type-specific logic."
    } else {
        Write-Host "Identified INF Type: $infType"
    }

    $targetConfig = $projectConfig
    if ($infType) {
        $parts = $infType.Split('.')
        foreach ($part in $parts) {
            if ($targetConfig.$part) {
                $targetConfig = $targetConfig.$part
            } else {
                Write-Warning "Config path '$part' not found for project $ProjectName."
                return
            }
        }
    }

    $newContent = Process-Inf -InfContent $content -Config $targetConfig -InfType $infType

    # 使用 utf8BOM 防止 Windows 下某些驱动签名工具报错
    $newContent | Out-File -FilePath $InfPath -Encoding utf8 -Force
    Write-Host "INF Patched successfully."
}

Export-ModuleMember -Function Patch-Inf-Advanced