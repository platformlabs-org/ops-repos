#requires -Version 5.1
Set-StrictMode -Version Latest

function Resolve-KdExe {
  param(
    [Parameter(Mandatory)]$Settings,
    [Parameter(Mandatory)][string]$RepoRoot
  )
  $kdDir = $Settings.Paths.KD_DIR
  if ([string]::IsNullOrWhiteSpace($kdDir)) { throw "settings.psd1.Paths.KD_DIR 未配置" }
  $kdPath = Join-Path (Join-Path $RepoRoot $kdDir) 'kd.exe'
  if (-not (Test-Path $kdPath)) { throw "kd.exe 未找到：$kdPath" }
  return (Resolve-Path $kdPath).Path
}

function Parse-KdAnalyzeOutput {
  param([Parameter(Mandatory)][string]$Raw)

  $bugcheckCode = $null
  $bugcheckName = $null

  if ($Raw -match '(?m)^(?<name>[A-Z0-9_]+)\s*\((?<code>[0-9A-Fa-f]+)\)') {
    $bugcheckName = $Matches['name']
    $codeClean = ($Matches['code'] -replace '^(0x|0X)', '')
    $codeInt = [Convert]::ToInt32($codeClean, 16)
    $bugcheckCode = ("0x{0:X8}" -f $codeInt)
  } elseif ($Raw -match '(?m)^BUGCHECK_CODE:\s*([0-9A-Fa-f]+)') {
    $codeClean = ($Matches[1] -replace '^(0x|0X)', '')
    $codeInt = [Convert]::ToInt32($codeClean, 16)
    $bugcheckCode = ("0x{0:X8}" -f $codeInt)
    if ($Raw -match '(?m)^(?<name>[A-Z0-9_]+)\s*\(') { $bugcheckName = $Matches['name'] }
  } elseif ($Raw -match 'BugCheck\s+([0-9A-Fa-f]{1,8})') {
    $codeClean = ($Matches[1] -replace '^(0x|0X)', '')
    $codeInt = [Convert]::ToInt32($codeClean, 16)
    $bugcheckCode = ("0x{0:X8}" -f $codeInt)
    if ($Raw -match '(?m)^(?<name>[A-Z0-9_]+)\s*\(') { $bugcheckName = $Matches['name'] }
  }

  if (-not $bugcheckCode) { $bugcheckCode = "UNKNOWN" }
  if (-not $bugcheckName) { $bugcheckName = "UNKNOWN" }

  # Try to find MODULE_NAME or IMAGE_NAME
  $imageName = $null
  if ($Raw -match '(?m)^IMAGE_NAME:\s*(.+)$') { $imageName = $Matches[1].Trim() }
  elseif ($Raw -match '(?m)^MODULE_NAME:\s*(.+)$') { $imageName = $Matches[1].Trim() }

  # Try to find FAILURE_BUCKET_ID or similar for signature
  $bucket = $null
  if ($Raw -match '(?m)^FAILURE_BUCKET_ID:\s*(.+)$') { $bucket = $Matches[1].Trim() }

  return @{
    bugcheck_code = $bugcheckCode
    bugcheck_name = $bugcheckName
    image_name    = $imageName
    bucket        = $bucket
  }
}

function Parse-KdXmlOutput {
  param([Parameter(Mandatory)][string]$XmlPath)

  if (-not (Test-Path $XmlPath)) { return $null }

  $xml = [xml](Get-Content -Path $XmlPath -Raw)
  $analysis = $xml.DocumentElement
  if (-not $analysis) { return $null }

  # Helper to safely retrieve node text without triggering strict mode missing property error
  function Get-Val {
    param($Node, $Name)
    if ($null -eq $Node) { return $null }
    $x = $Node.SelectSingleNode($Name)
    if ($x) { return $x.InnerText }
    return $null
  }

  $osName = $null
  $osNode = $analysis.SelectSingleNode("OS")
  if ($osNode -and $osNode.HasAttribute("Name")) {
    $osName = $osNode.GetAttribute("Name")
  }

  $imageName = Get-Val $analysis "IMAGE_NAME"
  if (-not $imageName) { $imageName = Get-Val $analysis "PROCESS_NAME" }

  $bucketId = Get-Val $analysis "FAILURE_BUCKET_ID"
  if (-not $bucketId) { $bucketId = Get-Val $analysis "BUCKET_ID" }

  # Stack Parsing
  $stackFrames = @()
  $faultingThreadId = Get-Val $analysis "FAULTING_THREAD"

  $flpCtx = $analysis.SelectSingleNode("FLP_CTX")
  if ($flpCtx) {
      $frms = $flpCtx.SelectSingleNode("FRMS")
      if ($frms) {
          foreach ($frm in $frms.SelectNodes("FRM")) {
              $frame = @{
                  num = Get-Val $frm "NUM"
                  sym = Get-Val $frm "SYM"
                  img = Get-Val $frm "IMG"
                  mod = Get-Val $frm "MOD"
                  off = Get-Val $frm "OFF"
                  fnc = Get-Val $frm "FNC"
              }
              $stackFrames += $frame
          }
      }
  }

  return @{
    bugcheck_code = Get-Val $analysis "BUGCHECK_CODE"
    bugcheck_str  = Get-Val $analysis "BUGCHECK_STR"
    bugcheck_p1   = Get-Val $analysis "BUGCHECK_P1"
    bugcheck_p2   = Get-Val $analysis "BUGCHECK_P2"
    bugcheck_p3   = Get-Val $analysis "BUGCHECK_P3"
    bugcheck_p4   = Get-Val $analysis "BUGCHECK_P4"
    image_name    = $imageName
    bucket_id     = $bucketId
    stack_command = Get-Val $analysis "STACK_COMMAND"
    faulting_thread = $faultingThreadId
    stack_frames  = $stackFrames

    system = @{
      manufacturer = Get-Val $analysis "SYSTEM_MANUFACTURER"
      product      = Get-Val $analysis "SYSTEM_PRODUCT_NAME"
      sku          = Get-Val $analysis "SYSTEM_SKU"
      version      = Get-Val $analysis "SYSTEM_VERSION"
      os_name      = $osName
      os_version   = Get-Val $analysis "OS_VERSION"
      os_build     = Get-Val $analysis "OS_BUILD_STRING"
    }
    bios = @{
      vendor   = Get-Val $analysis "BIOS_VENDOR"
      version  = Get-Val $analysis "BIOS_VERSION"
      date     = Get-Val $analysis "BIOS_DATE"
      revision = Get-Val $analysis "BIOS_REVISION"
    }
    cpu = @{
      name   = Get-Val $analysis "CPU_MODEL"
      count  = Get-Val $analysis "CPU_COUNT"
      mhz    = Get-Val $analysis "CPU_MHZ"
      vendor = Get-Val $analysis "CPU_VENDOR"
      family = Get-Val $analysis "CPU_FAMILY"
    }
    analysis_session = @{
      time = Get-Val $analysis "ANALYSIS_SESSION_TIME"
      elapsed = Get-Val $analysis "ANALYSIS_SESSION_ELAPSED_TIME"
    }
  }
}

function Parse-SysinfoMachineId {
    param([Parameter(Mandatory)][string]$Raw)

    $info = @{}
    $lines = $Raw -split "`n"
    foreach($line in $lines) {
        if($line -match '^\s*([^=]+?)\s*=\s*(.*)$') {
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim()
            $info[$key] = $val
        }
    }
    return $info
}

function Invoke-KdAnalyzer {
  param(
    [Parameter(Mandatory)]$Context
  )
  $dumpPath = $Context.Artifacts.DumpPath
  if (-not (Test-Path $dumpPath)) { throw "Dump 不存在：$dumpPath" }

  $kdExe = Resolve-KdExe -Settings $Context.Settings -RepoRoot $Context.RepoRoot
  $outDir = $Context.Paths.OutputDir
  Ensure-Directory $outDir

  $logPath = Join-Path $outDir "kd-analyze.log"
  $xmlPath = Join-Path $outDir "analyze.xml"
  $tmpPath = Join-Path $outDir "tmp.log"
  $machineIdLogPath = Join-Path $outDir "kd-machineid.log"
  $symbolPath = "srv*C:\symbols*https://msdl.microsoft.com/download/symbols"

  Write-LogInfo "KD 分析：$kdExe"

  # Run !analyze -v; !analyze -vv -xml; !sysinfo machineid in one session
  # Updated command to include -xcs for callstacks
  # $cmd = "!analyze -v; !analyze -vv -xml -xmi -xcs -xmf `"$xmlPath`"; .echo ---MACHINEID_START---; !sysinfo machineid; .echo ---MACHINEID_END---; q"

  # & $kdExe -z $dumpPath -y $symbolPath -c $cmd -logo $logPath | Out-Null



  # 阶段1：先获取崩溃进程名
  $phase1 = "!analyze -v;.echo ---QUICK_DONE---;"
  $phase1 += ".echo ---DUMP_HEADER_START---;.dumpdebug;.echo ---DUMP_HEADER_END---;"
  # 系统信息
  $phase1 += ".echo ---MACHINEID_START---;!sysinfo machineid;.echo ---MACHINEID_END---;q"

  & $kdExe -z $dumpPath -y $symbolPath -c $phase1 -logo $tmpPath  | Out-Null
  $target = (Select-String -Path $tmpPath -Pattern 'PROCESS_NAME:\s+(\S+)').Matches.Groups[1].Value
  $match = Select-String -Path $tmpPath -Pattern 'BUGCHECK_CODE:\s+([A-F0-9]{1,8})\b' -CaseSensitive:$false

  if ($match) {
      $bugCheckCode = $match.Matches.Groups[1].Value.PadLeft(8, '0').ToUpper()
      Write-Host "BugCheck: 0x$bugCheckCode" 
  } else {
      throw "Extrate BugCheck Failed"
  }
  # 阶段2：主分析（无开头分号！）
  $phase2 = "!analyze -v;"
  $phase2 += ".dumpdebug;"


  switch -Regex ($bugcheckCode) {
      "101" { $phase2 += "!cpuinfo;!running;" }
      "133" { $phase2 += "!dpcs;" }
      "124" { $phase2 += "!errrec;" }
      # "9F"  { $phase2 += "!!popowertriage;" }
      "E1|EA|C4" { $phase2 += "!locks -v 20;" } 
      "A|1A|1E|3B|3D|50|EF"{  
        if ($target) {
            $cmd += "!process 0 7 $target;"
        }
    }
  }

  $phase2 += "q"
  




  
  & $kdExe -z $dumpPath -y $symbolPath -c $phase2 -logo $logPath | Out-Null

  & $kdExe -z $dumpPath -y $symbolPath -c "!analyze -vv -xml -xmi -xcs -xmf ""$xmlPath"";q" | Out-Null



  if ($LASTEXITCODE -ne 0) { throw "kd.exe 返回错误码 $LASTEXITCODE" }
  if (-not (Test-Path $logPath)) { throw "kd 日志未生成：$logPath" }

  $machine_inforation = Get-Content -Raw -Path $tmpPath
  $analysis_log = Get-Content -Raw -Path $logPath
  $parsed = Parse-KdAnalyzeOutput -Raw $machine_inforation
  $xmlParsed = Parse-KdXmlOutput -XmlPath $xmlPath

  # Extract machine id part
  $machineIdInfo = $null
  if ($machine_inforation -match '[\s\S]*---MACHINEID_START---([\s\S]*?)---MACHINEID_END---') {
      $machineIdInfo = Parse-SysinfoMachineId -Raw $Matches[1]
  }

  # PartialReport：只负责自己产出的字段
  # Ensure all intermediate properties are safely initialized if missing from XML
  # The parser already handles missing XML values by returning $null via Get-Val

  return @{
    crash = @{
      bugcheck = @{
        code = $parsed.bugcheck_code
        name = $parsed.bugcheck_name
      }
      faulting = @{
        module = $parsed.image_name
      }
      signatures = @{
        signature_hash = $parsed.bucket
      }
    }
    reports = @{
      verbose_raw = $analysis_log
    }
    xml_data = $xmlParsed
    machine_id_data = $machineIdInfo
    meta = @{
      analyzers = @('kd')
      kd = @{ log_path = $logPath; xml_path = $xmlPath }
    }
  }
}

Export-ModuleMember -Function Invoke-KdAnalyzer
