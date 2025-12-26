Describe "InfPatch" {
    Context "Patching" {
        It "Should replace text" {
            $content = "DriverVer=1.0"
            $path = "test.inf"
            Set-Content $path $content

            Import-Module "$PSScriptRoot/../../scripts/modules/InfPatch.psm1" -Force

            $rules = @(@{ Find="1.0"; Replace="2.0" })
            Patch-Inf -InfPath $path -Rules $rules

            $newContent = Get-Content $path
            $newContent | Should -Be "DriverVer=2.0"

            Remove-Item $path
        }
    }
}
