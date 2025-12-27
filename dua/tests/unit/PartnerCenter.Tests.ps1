
Describe "PartnerCenter" {
    Context "Download Logic" {
        It "Should create valid zip files in mock mode" {
             Import-Module "$PSScriptRoot/../../scripts/modules/PartnerCenter.psm1" -Force

             $tempDir = Join-Path $env:TEMP "pc_test"
             New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

             $result = Get-SubmissionPackage -ProductId "999" -SubmissionId "123" -Token "fake" -DownloadPath $tempDir

             $result.Driver | Should -Not -BeNullOrEmpty
             Test-Path $result.Driver | Should -Be $true

             # Verify it is a valid zip
             $extractPath = Join-Path $tempDir "extract"
             Expand-Archive -Path $result.Driver -DestinationPath $extractPath -Force
             Test-Path (Join-Path $extractPath "dummy.inf") | Should -Be $true

             Remove-Item $tempDir -Recurse -Force
        }
    }
}
