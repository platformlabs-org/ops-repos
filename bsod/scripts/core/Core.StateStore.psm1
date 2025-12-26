#requires -Version 5.1
Set-StrictMode -Version Latest

function Get-RunStatePath {
  param(
    [Parameter(Mandatory)][string]$ScriptsRoot,
    [Parameter(Mandatory)]$Settings
  )
  $relative = $Settings.General.RunStateFile
  if ([string]::IsNullOrWhiteSpace($relative)) { $relative = "scripts/run_state.json" }

  if ([System.IO.Path]::IsPathRooted($relative)) { return $relative }

  # relative path is relative to repo root by convention; but ScriptsRoot is scripts/
  $repoRoot = Split-Path -Parent $ScriptsRoot
  return (Join-Path $repoRoot $relative)
}

function Load-RunState {
  param(
    [Parameter(Mandatory)][string]$StatePath
  )
  $state = Read-JsonFile -Path $StatePath
  if ($null -eq $state) { return @{} }
  return $state
}

function Save-RunState {
  param(
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)]$State
  )
  Write-JsonFile -Path $StatePath -Object $State -Depth 60
}

function Set-RunStateValue {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)][string]$Key,
    [Parameter(Mandatory)]$Value
  )
  # dot path: e.g. Init.WorkDir
  $segments = $Key -split '\.'
  $cur = $State
  for ($i=0; $i -lt $segments.Length; $i++) {
    $seg = $segments[$i]
    if ($i -eq $segments.Length - 1) {
      $cur[$seg] = $Value
      return
    }
    if (-not $cur.ContainsKey($seg) -or ($cur[$seg] -isnot [hashtable])) {
      $cur[$seg] = @{}
    }
    $cur = $cur[$seg]
  }
}

function Get-RunStateValue {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)][string]$Key,
    $Default = $null
  )
  $segments = $Key -split '\.'
  $cur = $State
  foreach ($seg in $segments) {
    if ($null -eq $cur) { return $Default }
    if ($cur -is [System.Collections.IDictionary]) {
      if (-not $cur.Contains($seg)) { return $Default }
      $cur = $cur[$seg]
      continue
    }
    if ($cur.PSObject) {
      $p = $cur.PSObject.Properties[$seg]
      if ($null -eq $p) { return $Default }
      $cur = $p.Value
      continue
    }
    return $Default
  }
  return $cur
}

Export-ModuleMember -Function `
  Get-RunStatePath,Load-RunState,Save-RunState,Set-RunStateValue,Get-RunStateValue
