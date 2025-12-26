#requires -Version 5.1
Set-StrictMode -Version Latest

function New-CanonicalReport {
  param(
    [Parameter(Mandatory)][string]$Uid,
    [Parameter(Mandatory)]$Context
  )
  return @{
    uid = $Uid
    source = @{
      type = $Context.Source.Type
      method = $Context.Source.Method
      issue_id = $Context.Run.IssueId
      repo_path = $Context.Run.RepoPath
    }
    artifacts = @{
      dump_path = $Context.Artifacts.DumpPath
      msinfo_dir = $Context.Artifacts.MsinfoDir
      output_dir = $Context.Paths.OutputDir
    }
    crash = @{
      timestamp_utc = $null
      bugcheck = @{ code=$null; name=$null; parameters=@() }
      faulting = @{ module=$null; file_version=$null; path=$null }
      stack = @{ fingerprint=$null; summary=$null }
      signatures = @{ signature_hash=$null }
    }
    ownership = @{
      primary_owner=$null; secondary_owner=$null; escalation_level=$null; support_ticket=$null
    }
    root_cause = @{
      category=$null; probable_cause=$null; confidence=$null; severity=$null; evidence=@()
    }
    analysis_reports = @{
      summary = @{ generated_utc=$null; analyst=$null; report_version=$null }
      brief = @{ title=$null; markdown=$null }
      detailed = @{ title=$null; markdown=$null }
      verbose = @{ raw=$null }
    }
    meta = @{
      analyzer = @{ name="bsod-pipeline"; version="3.0.0"; ran=@() }
      timings = @{}
    }
    systemInfo = $null
  }
}

function Merge-HashtableDeep {
  param(
    [Parameter(Mandatory)][hashtable]$Base,
    [Parameter(Mandatory)][hashtable]$Patch
  )
  foreach ($k in $Patch.Keys) {
    $pv = $Patch[$k]
    if ($null -eq $pv) { continue }

    if ($Base.ContainsKey($k)) {
      $bv = $Base[$k]
      if ($bv -is [hashtable] -and $pv -is [hashtable]) {
        Merge-HashtableDeep -Base $bv -Patch $pv
      } elseif (($bv -is [System.Collections.IList]) -and ($pv -is [System.Collections.IList])) {
        # 默认：优先级覆盖（也可改成 concat）
        $Base[$k] = $pv
      } else {
        # 标量：仅当 Base 为空时写入；否则保持 Base（更高优先级）
        if ($null -eq $bv -or ([string]$bv -eq '')) { $Base[$k] = $pv }
      }
    } else {
      $Base[$k] = $pv
    }
  }
}


function Convert-KdPartialToCanonicalPatch {
  param([Parameter(Mandatory)]$Partial)

  $patch = @{
    crash = @{
      bugcheck = @{
        code = $Partial.crash.bugcheck.code
        name = $Partial.crash.bugcheck.name
      }
      faulting = @{
        module = $Partial.crash.faulting.module
      }
      signatures = @{
        signature_hash = $Partial.crash.signatures.signature_hash
      }
      stack = @{}
    }
    analysis_reports = @{
      verbose = @{
        raw = $Partial.reports.verbose_raw
      }
    }
    meta = @{
      analyzer = @{
        ran = @('kd')
      }
    }
  }

  if ($Partial.xml_data) {
    # If XML data is available, enrich the patch with more fields
    $xml = $Partial.xml_data

    # Bugcheck Parameters
    $params = @()
    if ($xml.bugcheck_p1) { $params += $xml.bugcheck_p1 }
    if ($xml.bugcheck_p2) { $params += $xml.bugcheck_p2 }
    if ($xml.bugcheck_p3) { $params += $xml.bugcheck_p3 }
    if ($xml.bugcheck_p4) { $params += $xml.bugcheck_p4 }

    $patch.crash.bugcheck.parameters = $params

    # Overwrite basic fields if XML has them (usually XML is more reliable)
    if ($xml.bugcheck_code) { $patch.crash.bugcheck.code = $xml.bugcheck_code }
    if ($xml.bugcheck_str) { $patch.crash.bugcheck.name = $xml.bugcheck_str }
    if ($xml.image_name) { $patch.crash.faulting.module = $xml.image_name }
    if ($xml.bucket_id) { $patch.crash.signatures.signature_hash = $xml.bucket_id }

    # Stack Summary & Frames
    # We use deep merge manually here to ensure we don't wipe out other stack info if present
    if ($xml.stack_command) {
        if (-not $patch.crash.ContainsKey('stack')) { $patch.crash.stack = @{} }
        $patch.crash.stack.summary = $xml.stack_command
    }

    if ($xml.stack_frames) {
        if (-not $patch.crash.ContainsKey('stack')) { $patch.crash.stack = @{} }

        # Build normalized_frames from stack frames
        $normalized = @()
        foreach ($f in $xml.stack_frames) {
            # Format: module!symbol or just symbol
            $s = if ($f.mod -and $f.fnc) { "$($f.mod)!$($f.fnc)" } elseif ($f.sym) { $f.sym } else { $null }
            if ($s) { $normalized += $s.ToLower() }
        }
        $patch.crash.stack.normalized_frames = $normalized

        # Build callstacks object
        # We assume one callstack for the faulting thread
        $tid = if ($xml.faulting_thread) { $xml.faulting_thread } else { 0 }

        # CanonicalReport expects frames as strings in the callstack object too?
        # Checking Report-Structure.json: callstacks is array of objects { thread_id, frames: [string] }
        $rawFrames = @()
        foreach ($f in $xml.stack_frames) {
             # Use full symbol with offset if available or just sym
             if ($f.sym -and $f.off) { $rawFrames += "$($f.sym)+$($f.off)" }
             elseif ($f.sym) { $rawFrames += $f.sym }
        }

        $patch.crash.stack.callstacks = @(
            @{
                thread_id = $tid
                frames = $rawFrames
            }
        )
        $patch.crash.stack.crashing_thread_id = $tid
    }

    # System Info
    # We map xml data to systemInfo, but we should be careful if we have existing data
    # In this context (creating a patch from KD partial), $patch.systemInfo starts empty.

    $patch.systemInfo = @{
      system = $xml.system
      bios = $xml.bios
      cpu = $xml.cpu
    }
  }

  # Map machine_id_data if available
  if ($Partial.machine_id_data) {
      if (-not $patch.ContainsKey('systemInfo')) { $patch.systemInfo = @{ system = @{}; motherboard = @{} } }

      $mid = $Partial.machine_id_data
      # Map to system (machine_id from inventory structure)

      # We merge into existing systemInfo sub-tables if they exist
      if (-not $patch.systemInfo.ContainsKey('system')) { $patch.systemInfo.system = @{} }
      if (-not $patch.systemInfo.ContainsKey('motherboard')) { $patch.systemInfo.motherboard = @{} }

      # Mapping from parsed KD output keys to Canonical keys
      if ($mid.SystemManufacturer) { $patch.systemInfo.system.manufacturer = $mid.SystemManufacturer }
      if ($mid.SystemProductName) { $patch.systemInfo.system.product = $mid.SystemProductName }
      if ($mid.SystemSKU) { $patch.systemInfo.system.sku = $mid.SystemSKU }
      if ($mid.SystemVersion) { $patch.systemInfo.system.version = $mid.SystemVersion }
      if ($mid.SystemFamily) { $patch.systemInfo.system.family = $mid.SystemFamily }

      # Motherboard info
      if ($mid.BaseBoardManufacturer) { $patch.systemInfo.motherboard.vendor = $mid.BaseBoardManufacturer }
      if ($mid.BaseBoardProduct) { $patch.systemInfo.motherboard.product = $mid.BaseBoardProduct }
      if ($mid.BaseBoardVersion) { $patch.systemInfo.motherboard.version = $mid.BaseBoardVersion }

      # Bios info (override or fill if missing)
      if (-not $patch.systemInfo.ContainsKey('bios')) { $patch.systemInfo.bios = @{} }
      if ($mid.BiosVendor) { $patch.systemInfo.bios.vendor = $mid.BiosVendor }
      if ($mid.BiosVersion) { $patch.systemInfo.bios.version = $mid.BiosVersion }
      if ($mid.BiosReleaseDate) { $patch.systemInfo.bios.date = $mid.BiosReleaseDate }
  }

  return $patch
}

function Build-IssueMarkdownReport {
  param(
    [Parameter(Mandatory)]$CanonicalReport,
    [Parameter(Mandatory)]$Context,
    [string]$RecordId
  )

  $bugCode = $CanonicalReport.crash.bugcheck.code ?? 'N/A'
  $bugName = $CanonicalReport.crash.bugcheck.name ?? 'N/A'
  $image   = $CanonicalReport.crash.faulting.module ?? 'UnknownImage'
  $team    = $CanonicalReport.ownership.primary_owner ?? 'Unassigned'

  $bodyMd = $CanonicalReport.analysis_reports.detailed.markdown
  if ([string]::IsNullOrWhiteSpace($bodyMd)) { $bodyMd = $CanonicalReport.analysis_reports.brief.markdown }
  if ([string]::IsNullOrWhiteSpace($bodyMd)) {
      if (-not [string]::IsNullOrWhiteSpace($CanonicalReport.analysis_reports.verbose.raw)) {
          $bodyMd = "<details><summary>Verbose Raw Analysis</summary>`n`n```text`n" +
                    (Truncate-Text $CanonicalReport.analysis_reports.verbose.raw 60000) +
                    "`n````n</details>"
      } else {
          $bodyMd = "_(无详细报告内容，可能分析器未产出 markdown)_"
      }
  }

  $sysInfoMd = ""
  if ($CanonicalReport.systemInfo) {
    $sys = $CanonicalReport.systemInfo.system
    $cpu = $CanonicalReport.systemInfo.cpu
    $bios = $CanonicalReport.systemInfo.bios
    $mb  = $CanonicalReport.systemInfo.motherboard

    $osStr = if ($sys.os_name) { "$($sys.os_name) " } else { "" }
    $osStr += "$($sys.os_version)"

    $sysInfoMd = @"
<details>
<summary>系统信息（节选）</summary>

- OS：$osStr ($($sys.os_build))
- BIOS：$($bios.vendor) $($bios.version) (Date: $($bios.date))
- 机器：$($sys.manufacturer) $($sys.product) (SKU: $($sys.sku))
- 主板：$($mb.vendor) $($mb.product)
- CPU：$($cpu.name) (Count: $($cpu.count), MHz: $($cpu.mhz))

</details>
"@
  } else {
      $sysInfoMd = "<details><summary>系统信息</summary>`n`n_(无系统信息)_`n</details>"
  }

@"
### BSOD 自动分析报告

**Issue #$($Context.Run.IssueId)** · **Run** `$($Context.Run.RunId)`  
来源：`$($Context.Source.Type)`$(
  if([string]::IsNullOrWhiteSpace($Context.Source.Uid)) { '' } else { ' (' + $Context.Source.Uid + ')' }
)

| 项目 | 值 |
|-----:|:---|
| BugCheck | $bugCode |
| StopCode | $bugName |
| Image | $image |
| 建议团队 | $team |
| DB记录ID | $(if($RecordId){$RecordId}else{'（无）'}) |

$bodyMd

$sysInfoMd
"@
}

function Build-IssueTitle {
  param([Parameter(Mandatory)]$CanonicalReport,[Parameter(Mandatory)][string]$Suffix,[int]$MaxLen=120)

  $team = $CanonicalReport.ownership.primary_owner ?? 'Unassigned'
  $bug  = $CanonicalReport.crash.bugcheck.name
  if ([string]::IsNullOrWhiteSpace($bug)) { $bug = $CanonicalReport.crash.bugcheck.code ?? 'UnknownBugcheck' }
  $img  = $CanonicalReport.crash.faulting.module
  if ([string]::IsNullOrWhiteSpace($img)) { $img = 'UnknownImage' }

  $att  = Truncate-Text (Sanitize-FileName $Suffix) 40
  return Truncate-Text ("[$team] [$bug] [$img] $att") $MaxLen
}

Export-ModuleMember -Function `
  New-CanonicalReport,Merge-HashtableDeep,Convert-KdPartialToCanonicalPatch, `
  Build-IssueMarkdownReport,Build-IssueTitle
