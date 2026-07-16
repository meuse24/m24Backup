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

function Get-M24UserShellFolder {
    param(
        [string]$Name,
        [string]$Fallback
    )

    # Beruecksichtigt auch Ordner, die beispielsweise nach OneDrive umgeleitet wurden.
    $registryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    $value = (Get-ItemProperty -Path $registryPath -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($value) {
        return [Environment]::ExpandEnvironmentVariables($value)
    }

    return $Fallback
}

function Get-M24StandardFolderDefinitions {
    $folders = @(
        [pscustomobject]@{ Name = 'Desktop'; Path = [Environment]::GetFolderPath('Desktop') },
        [pscustomobject]@{ Name = 'Dokumente'; Path = [Environment]::GetFolderPath('MyDocuments') },
        [pscustomobject]@{ Name = 'Downloads'; Path = Get-M24UserShellFolder -Name '{374DE290-123F-4565-9164-39C4925E467B}' -Fallback (Join-Path $env:USERPROFILE 'Downloads') },
        [pscustomobject]@{ Name = 'Bilder'; Path = [Environment]::GetFolderPath('MyPictures') },
        [pscustomobject]@{ Name = 'Musik'; Path = [Environment]::GetFolderPath('MyMusic') },
        [pscustomobject]@{ Name = 'Videos'; Path = [Environment]::GetFolderPath('MyVideos') },
        [pscustomobject]@{ Name = 'Favoriten'; Path = [Environment]::GetFolderPath('Favorites') },
        [pscustomobject]@{ Name = 'Gespeicherte Spiele'; Path = Join-Path $env:USERPROFILE 'Saved Games' },
        [pscustomobject]@{ Name = 'Kontakte'; Path = Join-Path $env:USERPROFILE 'Contacts' }
    )

    $profilePath = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
    return @($folders | Where-Object {
        $_.Path -and [System.IO.Path]::GetFullPath($_.Path).TrimEnd('\') -ne $profilePath
    })
}

function Get-M24FolderDisplayName {
    param([string]$CanonicalName, [bool]$German = (Test-M24GermanUiCulture))

    if ($German) { return $CanonicalName }
    $englishNames = @{
        'Desktop' = 'Desktop'; 'Dokumente' = 'Documents'; 'Downloads' = 'Downloads'
        'Bilder' = 'Pictures'; 'Musik' = 'Music'; 'Videos' = 'Videos'
        'Favoriten' = 'Favorites'; 'Gespeicherte Spiele' = 'Saved Games'; 'Kontakte' = 'Contacts'
    }
    if ($englishNames.ContainsKey($CanonicalName)) { return $englishNames[$CanonicalName] }
    return $CanonicalName
}

function ConvertTo-M24ProcessArgument {
    param([string]$Argument)

    if ($null -eq $Argument) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Write-M24AtomicTextFile {
    param(
        [string]$Path,
        [string]$Content,
        [bool]$Utf8Bom = $true
    )

    $temporaryFile = "{0}.{1}.tmp" -f $Path, [guid]::NewGuid().ToString('N')
    $backupFile = "{0}.{1}.bak" -f $Path, [guid]::NewGuid().ToString('N')
    try {
        [System.IO.File]::WriteAllText($temporaryFile, $Content, (New-Object System.Text.UTF8Encoding($Utf8Bom)))
        if ([System.IO.File]::Exists($Path)) {
            [System.IO.File]::Replace($temporaryFile, $Path, $backupFile, $true)
        } else {
            [System.IO.File]::Move($temporaryFile, $Path)
        }
    } finally {
        Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-M24ExcludedFileName {
    param([string]$Name, [string[]]$Patterns)
    foreach ($pattern in $Patterns) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function ConvertTo-M24ExtendedLengthPath {
    # Erweitertes Pfadpraefix \\?\ fuer absolute Pfade. Dadurch lassen sich
    # auch Dateien mit reservierten Geraetenamen (z. B. "nul", "con") oder
    # abschliessendem Punkt/Leerzeichen als normale Dateien oeffnen, die
    # Robocopy kopieren kann, .NET ueber den normalen Pfadweg aber nicht.
    param([string]$Path)
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path -match '^[A-Za-z]:\\') { return "\\?\$Path" }
    if ($Path.StartsWith('\\')) { return "\\?\UNC$($Path.Substring(1))" }
    return $Path
}

function Get-M24FileSha256 {
    param([string]$Path, [scriptblock]$CancelCallback)
    $stream = $null
    $sha = $null
    try {
        $stream = [System.IO.File]::Open((ConvertTo-M24ExtendedLengthPath $Path), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
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
        $cancelled = $false
        Get-ChildItem -LiteralPath $folder.Path -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +scanErrors | ForEach-Object {
            $file = $_
            if ($cancelled) { return }
            if ($CancelCallback -and (& $CancelCallback)) { $cancelled = $true; return }
            if (Test-M24ExcludedFileName -Name $file.Name -Patterns $ExcludedFiles) { return }
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
                if ($null -eq $hash) { $cancelled = $true; return }
                $hashedFiles++
            }
            $entries[$entryPath] = [pscustomobject]@{ Path = $entryPath; Length = [int64]$file.Length; LastWriteUtcTicks = [int64]$file.LastWriteTimeUtc.Ticks; Sha256 = $hash }
            $fileCount++; $totalBytes += $file.Length
        }
        # Ein unvollstaendiger Scan darf niemals als neues gueltiges Manifest
        # geschrieben werden. Der Worker markiert den gesamten Lauf als Fehler.
        if ($scanErrors.Count) { throw $scanErrors[0].Exception }
        if ($cancelled) { return [pscustomobject]@{ Cancelled = $true } }
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
        $cancelled = $false
        Get-ChildItem -LiteralPath $folder.Path -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +scanErrors | ForEach-Object {
            $file = $_
            if ($cancelled) { return }
            if ($CancelCallback -and (& $CancelCallback)) {
                $cancelled = $true
                return
            }
            if (Test-M24ExcludedFileName -Name $file.Name -Patterns $ExcludedFiles) { return }
            $relative = $file.FullName.Substring($folder.Path.TrimEnd('\').Length).TrimStart('\')
            $path = "{0}\{1}" -f $folder.Name, $relative
            [void]$seen.Add($path)
            try {
                $hash = Get-M24FileSha256 -Path $file.FullName -CancelCallback $CancelCallback
                if ($null -eq $hash) {
                    $cancelled = $true
                    return
                }
                $files++; $bytes += $file.Length
                if (-not $manifest.Entries.ContainsKey($path)) { throw "Checksum entry missing: $path" }
                if (-not $hash.Equals([string]$manifest.Entries[$path].Sha256, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Checksum mismatch: $path" }
            } catch {
                $errorCount++; if ($errors.Count -lt 10) { $errors += $_.Exception.Message }
            }
        }
        if ($cancelled) {
            return [pscustomobject]@{ Cancelled = $true; MissingManifest = $false; Files = $files; Bytes = $bytes; ErrorCount = $errorCount; Errors = @($errors) }
        }
        foreach ($scanError in $scanErrors) { $errorCount++; if ($errors.Count -lt 10) { $errors += $scanError.Exception.Message } }
    }
    foreach ($entry in $manifest.Entries.Values) {
        if (-not $seen.Contains([string]$entry.Path)) { $errorCount++; if ($errors.Count -lt 10) { $errors += "File missing: $($entry.Path)" } }
    }
    return [pscustomobject]@{ Cancelled = $false; MissingManifest = $false; Files = $files; Bytes = $bytes; ErrorCount = $errorCount; Errors = @($errors) }
}

function Get-M24ChecksumVerifiedDate {
    # Liefert den Zeitpunkt der letzten erfolgreichen vollstaendigen
    # Pruefsummenpruefung aus den Sicherungsmetadaten oder $null.
    param([string]$MetadataFile)
    if (-not (Test-Path -LiteralPath $MetadataFile -PathType Leaf)) { return $null }
    $line = Get-Content -LiteralPath $MetadataFile -ErrorAction SilentlyContinue |
        Where-Object { $_ -like 'Pruefsummen-Pruefung:*' } |
        Select-Object -Last 1
    if ($line -and $line -match '^Pruefsummen-Pruefung:\s*Erfolgreich am\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.?$') {
        return $matches[1]
    }
    return $null
}

function Set-M24ChecksumVerifiedMetadata {
    # Vermerkt eine erfolgreiche vollstaendige Pruefsummenpruefung in den
    # Sicherungsmetadaten. Ein neuer Sicherungslauf schreibt die Metadaten
    # komplett neu und entwertet den Vermerk damit automatisch.
    param(
        [string]$MetadataFile,
        [datetime]$VerifiedAt = (Get-Date)
    )
    if (-not (Test-Path -LiteralPath $MetadataFile -PathType Leaf)) { return }
    $lines = @(Get-Content -LiteralPath $MetadataFile -ErrorAction Stop | Where-Object { $_ -notlike 'Pruefsummen-Pruefung:*' })
    $content = (@($lines) + ("Pruefsummen-Pruefung: Erfolgreich am {0}." -f $VerifiedAt.ToString('yyyy-MM-dd HH:mm:ss'))) -join [Environment]::NewLine
    Write-M24AtomicTextFile -Path $MetadataFile -Content ($content + [Environment]::NewLine)
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
