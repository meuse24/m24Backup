function Test-M24GermanUiCulture {
    try {
        $culture = [System.Globalization.CultureInfo]::CurrentUICulture
        return [bool]($culture -and $culture.TwoLetterISOLanguageName -eq 'de')
    } catch {
        return $false
    }
}

function Get-ReservedBackupNames {
    return @('_logs', '_Sicherungsinfo.txt', '_Ordner.json', '_Pruefsummen.tsv')
}

function Get-M24ChecksumManifestName {
    return '_Pruefsummen.tsv'
}

function Get-M24DefaultExcludedFiles {
    return @('thumbs.db', 'desktop.ini', '*.tmp', '*.temp', '~$*')
}

function Test-M24ExcludedFileName {
    param([string]$Name, [string[]]$Patterns)
    foreach ($pattern in $Patterns) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Get-M24FileSha256 {
    param([string]$Path, [scriptblock]$CancelCallback)
    $stream = $null
    $sha = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $buffer = New-Object byte[] (1MB)
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($CancelCallback -and (& $CancelCallback)) { return $null }
            [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
        }
        [void]$sha.TransformFinalBlock($buffer, 0, 0)
        return ([System.BitConverter]::ToString($sha.Hash)).Replace('-', '')
    } finally {
        if ($sha) { $sha.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Read-M24ChecksumManifest {
    param([string]$Path)
    $entries = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Entries = $entries }
    }
    $reader = $null
    try {
        $reader = New-Object System.IO.StreamReader($Path, [System.Text.Encoding]::UTF8, $true)
        $header = $reader.ReadLine()
        if ($header -ne "M24BACKUP-CHECKSUMS`t1`tSHA256") { throw "Unsupported checksum manifest format." }
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line.Split([char]9)
            if ($parts.Count -ne 4) { throw "Invalid checksum manifest entry." }
            $relativePath = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[0]))
            $entries[$relativePath] = [pscustomobject]@{
                Path = $relativePath
                Length = [int64]$parts[1]
                LastWriteUtcTicks = [int64]$parts[2]
                Sha256 = [string]$parts[3]
            }
        }
    } finally { if ($reader) { $reader.Dispose() } }
    return [pscustomobject]@{ Exists = $true; Entries = $entries }
}

function Write-M24ChecksumManifest {
    param([string]$Path, $Entries)
    $temporaryFile = "{0}.{1}.tmp" -f $Path, [guid]::NewGuid().ToString('N')
    $backupFile = "{0}.{1}.bak" -f $Path, [guid]::NewGuid().ToString('N')
    $writer = $null
    try {
        $writer = New-Object System.IO.StreamWriter($temporaryFile, $false, (New-Object System.Text.UTF8Encoding($false)), 1MB)
        $writer.WriteLine("M24BACKUP-CHECKSUMS`t1`tSHA256")
        foreach ($entry in $Entries.Values) {
            $encodedPath = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$entry.Path))
            $writer.WriteLine(("{0}`t{1}`t{2}`t{3}" -f $encodedPath, $entry.Length, $entry.LastWriteUtcTicks, $entry.Sha256))
        }
        $writer.Dispose(); $writer = $null
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($temporaryFile, $Path, $backupFile, $true) }
        else { [System.IO.File]::Move($temporaryFile, $Path) }
    } finally {
        if ($writer) { $writer.Dispose() }
        Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupFile -Force -ErrorAction SilentlyContinue
    }
}

function Update-M24ChecksumManifest {
    param(
        [array]$Folders,
        [string]$ManifestPath,
        [string[]]$ExcludedFiles,
        [switch]$ForceRehash,
        [scriptblock]$StatusCallback,
        [scriptblock]$CancelCallback
    )
    $manifest = Read-M24ChecksumManifest -Path $ManifestPath
    $entries = $manifest.Entries
    [int64]$fileCount = 0; [int64]$hashedFiles = 0; [int64]$reusedFiles = 0; [int64]$totalBytes = 0
    $folderIndex = 0
    foreach ($folder in $Folders) {
        $folderIndex++
        if ($StatusCallback) { & $StatusCallback $folderIndex @($Folders).Count $folder.Name }
        $scanErrors = @()
        $files = Get-ChildItem -LiteralPath $folder.Path -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +scanErrors
        # Ein unvollstaendiger Scan darf niemals als neues gueltiges Manifest
        # geschrieben werden. Der Worker markiert den gesamten Lauf als Fehler.
        if ($scanErrors.Count) { throw $scanErrors[0].Exception }
        foreach ($file in $files) {
            if ($CancelCallback -and (& $CancelCallback)) { return [pscustomobject]@{ Cancelled = $true } }
            if (Test-M24ExcludedFileName -Name $file.Name -Patterns $ExcludedFiles) { continue }
            $relative = $file.FullName.Substring($folder.Path.TrimEnd('\').Length).TrimStart('\')
            $entryPath = "{0}\{1}" -f $folder.Name, $relative
            $existing = if ($entries.ContainsKey($entryPath)) { $entries[$entryPath] } else { $null }
            $hash = $null
            # Zielmetadaten werden exakt verglichen. Eine Zeit-Toleranz koennte
            # gleich grosse, innerhalb des FAT/exFAT-Fensters geaenderte Dateien uebersehen.
            if (-not $ForceRehash -and $existing -and $existing.Length -eq $file.Length -and $existing.LastWriteUtcTicks -eq $file.LastWriteTimeUtc.Ticks) {
                $hash = $existing.Sha256; $reusedFiles++
            } else {
                $hash = Get-M24FileSha256 -Path $file.FullName -CancelCallback $CancelCallback
                if ($null -eq $hash) { return [pscustomobject]@{ Cancelled = $true } }
                $hashedFiles++
            }
            $entries[$entryPath] = [pscustomobject]@{ Path = $entryPath; Length = [int64]$file.Length; LastWriteUtcTicks = [int64]$file.LastWriteTimeUtc.Ticks; Sha256 = $hash }
            $fileCount++; $totalBytes += $file.Length
        }
    }
    Write-M24ChecksumManifest -Path $ManifestPath -Entries $entries
    return [pscustomobject]@{ Cancelled = $false; Files = $fileCount; HashedFiles = $hashedFiles; ReusedFiles = $reusedFiles; Bytes = $totalBytes }
}

function Test-M24ChecksumManifest {
    param(
        [array]$Folders,
        [string]$ManifestPath,
        [string[]]$ExcludedFiles,
        [scriptblock]$StatusCallback,
        [scriptblock]$CancelCallback
    )
    $manifest = Read-M24ChecksumManifest -Path $ManifestPath
    if (-not $manifest.Exists) {
        return [pscustomobject]@{ Cancelled = $false; MissingManifest = $true; Files = 0; Bytes = 0; ErrorCount = 1; Errors = @('Checksum manifest missing.') }
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    [int64]$files = 0; [int64]$bytes = 0; [int]$errorCount = 0; $errors = @(); $folderIndex = 0
    foreach ($folder in $Folders) {
        $folderIndex++
        if ($StatusCallback) { & $StatusCallback $folderIndex @($Folders).Count $folder.Name }
        $scanErrors = @()
        foreach ($file in @(Get-ChildItem -LiteralPath $folder.Path -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +scanErrors)) {
            if ($CancelCallback -and (& $CancelCallback)) {
                return [pscustomobject]@{ Cancelled = $true; MissingManifest = $false; Files = $files; Bytes = $bytes; ErrorCount = $errorCount; Errors = @($errors) }
            }
            if (Test-M24ExcludedFileName -Name $file.Name -Patterns $ExcludedFiles) { continue }
            $relative = $file.FullName.Substring($folder.Path.TrimEnd('\').Length).TrimStart('\')
            $path = "{0}\{1}" -f $folder.Name, $relative
            [void]$seen.Add($path)
            try {
                $hash = Get-M24FileSha256 -Path $file.FullName -CancelCallback $CancelCallback
                if ($null -eq $hash) {
                    return [pscustomobject]@{ Cancelled = $true; MissingManifest = $false; Files = $files; Bytes = $bytes; ErrorCount = $errorCount; Errors = @($errors) }
                }
                $files++; $bytes += $file.Length
                if (-not $manifest.Entries.ContainsKey($path)) { throw "Checksum entry missing: $path" }
                if (-not $hash.Equals([string]$manifest.Entries[$path].Sha256, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Checksum mismatch: $path" }
            } catch {
                $errorCount++; if ($errors.Count -lt 10) { $errors += $_.Exception.Message }
            }
        }
        foreach ($scanError in $scanErrors) { $errorCount++; if ($errors.Count -lt 10) { $errors += $scanError.Exception.Message } }
    }
    foreach ($entry in $manifest.Entries.Values) {
        if (-not $seen.Contains([string]$entry.Path)) { $errorCount++; if ($errors.Count -lt 10) { $errors += "File missing: $($entry.Path)" } }
    }
    return [pscustomobject]@{ Cancelled = $false; MissingManifest = $false; Files = $files; Bytes = $bytes; ErrorCount = $errorCount; Errors = @($errors) }
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
