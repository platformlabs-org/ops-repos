#requires -Version 5.1
Set-StrictMode -Version Latest

function Test-CiEnvironment {
  return (
    ($env:CI -match '^(1|true)$') -or
    ($env:GITHUB_ACTIONS -eq 'true') -or
    ($env:GITLAB_CI -eq 'true') -or
    ($env:TF_BUILD -eq 'True') -or
    ($env:TEAMCITY_VERSION)
  )
}

function Export-EnvironmentVariables {
  param([Parameter(Mandatory)][hashtable]$Variables)

  foreach ($key in $Variables.Keys) {
    $value = [string]$Variables[$key]
    try { Set-Item -Path ("Env:{0}" -f $key) -Value $value -ErrorAction Stop } catch {
      Write-LogWarn "设置进程环境变量失败：$key = $value；$($_.Exception.Message)"
    }

    if ($env:GITHUB_ENV) {
      try {
        if ($value -match "`r?`n") {
          $eof = "EOF_$([guid]::NewGuid().ToString('N'))"
          @("{0}<<{1}" -f $key,$eof; $value; $eof) | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
        } else {
          "{0}={1}" -f $key,$value | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
        }
      } catch {
        Write-LogWarn "写入 GITHUB_ENV 失败：$key；$($_.Exception.Message)"
      }
    }
  }
}

Export-ModuleMember -Function Test-CiEnvironment,Export-EnvironmentVariables
