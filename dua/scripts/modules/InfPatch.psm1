
function Patch-Inf {
    param(
        $InfPath,
        $Rules # array of { "Find": "...", "Replace": "..." }
    )
    $content = Get-Content $InfPath -Raw
    foreach ($rule in $Rules) {
        $content = $content -replace $rule.Find, $rule.Replace
    }
    Set-Content -Path $InfPath -Value $content
}
Export-ModuleMember -Function Patch-Inf
