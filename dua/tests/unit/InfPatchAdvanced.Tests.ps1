
Describe "InfPatch Advanced" {
    Context "Patching Logic" {
        $mockInfContent = @"
[Version]
Signature="$WINDOWS NT$"
Class=Display
ClassGuid={4d36e968-e325-11ce-bfc1-08002be10318}
Provider=%Intel%
CatalogFile=iigd_dch.cat
DriverVer=1.0.0.0
[Intel.Mfg.NTamd64]
%iTGL% = iTGL_w10_DS, PCI\VEN_8086&DEV_9A49
%iTGL% = iTGL_w10_DS, PCI\VEN_8086&DEV_9A40
"@

        $mockConfig = @{
            project = @{
                test_project = @{
                    gfx = @{
                        base = @{
                            dev_id = @("9A49")
                            subsys_id = @("12345678")
                        }
                    }
                }
            }
        } | ConvertTo-Json -Depth 10

        $testDir = "dua/tests/mocks/inf_test"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $infPath = Join-Path $testDir "test.inf"
        $configPath = Join-Path $testDir "config.json"

        Set-Content -Path $infPath -Value $mockInfContent
        Set-Content -Path $configPath -Value $mockConfig

        It "Should replace SUBSYS for matching DEV_ID" {
            Import-Module "$PSScriptRoot/../../scripts/modules/InfPatch.psm1" -Force

            # Identify-InfType relies on CatalogFile matching known types.
            # Our mock content has 'iigd_dch.cat' which isn't in the switch yet?
            # The python script had 'igdlh.cat' for gfx.base. Let's update mock content.

            Set-Content -Path $infPath -Value ($mockInfContent -replace "iigd_dch.cat", "igdlh.cat")

            Patch-Inf-Advanced -InfPath $infPath -ConfigPath $configPath -ProjectName "test_project"

            $newContent = Get-Content $infPath -Raw
            $newContent | Should -Match "PCI\\VEN_8086&DEV_9A49&SUBSYS_12345678"
            $newContent | Should -Not -Match "PCI\\VEN_8086&DEV_9A40&SUBSYS_12345678" # 9A40 is not in dev_id list
        }

        Remove-Item $testDir -Recurse -Force
    }
}
