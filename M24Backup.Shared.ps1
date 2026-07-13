function Get-ReservedBackupNames {
    return @('_logs', '_Sicherungsinfo.txt', '_Ordner.json')
}

function Get-NormalizedFullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-IsSameOrNestedPath {
    param([string]$FirstPath, [string]$SecondPath)
    $first = Get-NormalizedFullPath $FirstPath
    $second = Get-NormalizedFullPath $SecondPath
    return $first.Equals($second, [System.StringComparison]::OrdinalIgnoreCase) -or
        $first.StartsWith("$second\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $second.StartsWith("$first\", [System.StringComparison]::OrdinalIgnoreCase)
}
