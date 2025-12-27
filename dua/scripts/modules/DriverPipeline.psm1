
function Select-Pipeline {
    param(
        $ProductName,
        $MappingFile
    )
    $mapping = Get-Content $MappingFile | ConvertFrom-Json
    foreach ($rule in $mapping.rules) {
        if ($ProductName -match $rule.pattern) {
            return $rule.infStrategy
        }
    }
    throw "No pipeline/strategy matched for product: $ProductName"
}
Export-ModuleMember -Function Select-Pipeline
