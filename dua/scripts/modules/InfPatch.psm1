
function Identify-InfType {
    param([string]$Content)

    if ($Content -match "npu_extension.cat") { return "npu.extension" }
    if ($Content -match "extinf_i.cat") { return "gfx.extension" }
    if ($Content -match "igdlh.cat") { return "gfx.base" }

    return $null
}

function Format-Binary {
    param([string]$HexStr)

    $clean = $HexStr -replace " ", "" -replace "0x", ""
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

    $devIds = if ($Config.dev_id) { $Config.dev_id } else { @() }
    $subsysIds = if ($Config.subsys_id) { $Config.subsys_id } else { @() }
    $extId = $Config.extension_id
    $regFuncs = $Config.register_function

    $installSectionPatterns = @("PTL_.*IG$", "NPU_.*_Install$", "PTL_IG$")

    foreach ($line in $lines) {
        $stripped = $line.Trim()

        # Identify Section
        if ($stripped -match "^\[.*\]$") {
            $currentSection = $stripped.Trim("[", "]").Split(" ")[0]
        }

        # 1. Replace ExtensionId
        if ($currentSection -eq "Version" -and $line -match "ExtensionId" -and $extId) {
            $output += "ExtensionId = {$extId}"
            continue
        }

        # 2. Replace Hardware ID (SUBSYS)
        if ($line -match "PCI\\VEN_8086&DEV_") {
            $matched = $false
            foreach ($dId in $devIds) {
                # If dId is empty/null, match all. Else match specific DEV_ID
                if ([string]::IsNullOrEmpty($dId) -or $line -match "DEV_$dId") {
                    foreach ($sId in $subsysIds) {
                        if ($line -match "SUBSYS_[a-zA-Z0-9]+") {
                            $newLine = $line -replace "SUBSYS_[a-zA-Z0-9]+", "SUBSYS_$sId"
                        } else {
                            $newLine = $line.TrimEnd() + "&SUBSYS_$sId"
                        }
                        $output += $newLine
                    }
                    $matched = $true
                    break
                }
            }
            if ($matched) { continue }
        }

        # 3. Inject AddReg references
        # Check if current section matches any install pattern
        $isInstallSec = $false
        foreach ($p in $installSectionPatterns) {
            if ($currentSection -match $p) { $isInstallSec = $true; break }
        }

        if ($isInstallSec -and $stripped -eq "" -and $regFuncs) {
            foreach ($key in $regFuncs.PSObject.Properties.Name) {
                $output += "AddReg = $key"
            }
        }

        $output += $line
    }

    # 4. Append Registry Sections
    if ($regFuncs) {
        $output += ""
        $output += "; --- Generated Registry Sections ---"

        foreach ($fName in $regFuncs.PSObject.Properties.Name) {
            $output += "[$fName]"
            $items = $regFuncs.$fName
            foreach ($item in $items) {
                # item is [Key, Type, Value]
                # In PS, logic depends on how JSON is parsed (array of arrays or objects)
                # Assuming simple array structure from JSON:
                # ["Key", "d", 1]

                $key = $item[0]
                $valType = $item[1]
                $val = $item[2]

                $regType = if ($valType -eq "d") { "%REG_DWORD%" } else { "%REG_BINARY%" }
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

    # Allow auto-detection (for UTF-16LE BOM) instead of forcing UTF8
    $content = Get-Content $InfPath -Raw

    $infType = Identify-InfType -Content $content
    if (-not $infType) {
        Write-Warning "Could not identify INF type from content catalogs. Defaulting to generic patching or skipping type-specific logic."
        # Fallback logic could go here, but for now we error or warn.
    }
    Write-Host "Identified INF Type: $infType"

    # Traverse config based on type (e.g. "gfx.extension" -> projectConfig.gfx.extension)
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

    # Save as UTF-16 LE (standard for INF)
    $newContent | Out-File -FilePath $InfPath -Encoding Unicode -Force
    Write-Host "INF Patched successfully."
}

Export-ModuleMember -Function Patch-Inf-Advanced
