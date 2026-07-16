# Pester 5+: Top-Level-Code laeuft nur in der Discovery-Phase. Das
# Dot-Sourcing muss deshalb in BeforeAll stehen, damit die Funktionen
# waehrend der Testausfuehrung verfuegbar sind.
BeforeAll {
    $sharedScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'M24Backup.Shared.ps1'
    . $sharedScript
}

Describe 'ConvertTo-M24ProcessArgument' {
    It 'leaves a simple argument unquoted' {
        ConvertTo-M24ProcessArgument 'simple' | Should -Be 'simple'
    }

    It 'quotes whitespace' {
        ConvertTo-M24ProcessArgument 'two words' | Should -Be '"two words"'
    }

    It 'escapes a trailing backslash before the closing quote' {
        ConvertTo-M24ProcessArgument 'C:\path with space\' | Should -Be '"C:\path with space\\"'
    }

    It 'escapes an embedded quote' {
        ConvertTo-M24ProcessArgument 'say"hello' | Should -Be '"say\"hello"'
    }
}

Describe 'Shared folder metadata' {
    It 'translates canonical folder names without changing stored names' {
        Get-M24FolderDisplayName 'Dokumente' $false | Should -Be 'Documents'
        Get-M24FolderDisplayName 'Dokumente' $true | Should -Be 'Dokumente'
        Get-M24FolderDisplayName 'Custom' $false | Should -Be 'Custom'
    }

    It 'returns every canonical standard folder name once' {
        $names = @(Get-M24StandardFolderDefinitions | ForEach-Object Name)
        $names.Count | Should -Be 9
        @($names | Select-Object -Unique).Count | Should -Be 9
        ($names -contains 'Downloads') | Should -Be $true
        ($names -contains 'Gespeicherte Spiele') | Should -Be $true
    }
}

Describe 'Path overlap validation' {
    It 'recognizes equal and nested paths in both argument orders' {
        Test-IsSameOrNestedPath 'C:\Data' 'c:\data' | Should -Be $true
        Test-IsSameOrNestedPath 'C:\Data\Child' 'C:\Data' | Should -Be $true
        Test-IsSameOrNestedPath 'C:\Data' 'C:\Data\Child' | Should -Be $true
    }

    It 'does not confuse sibling path prefixes' {
        Test-IsSameOrNestedPath 'C:\Data' 'C:\Database' | Should -Be $false
    }
}

Describe 'Checksum manifest lifecycle' {
    It 'creates, reads, verifies, and detects a changed file' {
        $source = Join-Path $TestDrive 'source'
        $manifestPath = Join-Path $TestDrive '_Pruefsummen.tsv'
        New-Item -ItemType Directory -Path $source | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $source 'sample.txt'), 'original')
        $folders = @([pscustomobject]@{ Name = 'Dokumente'; Path = $source })

        $updated = Update-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles @()
        $updated.Cancelled | Should -Be $false
        $updated.Files | Should -Be 1
        (Read-M24ChecksumManifest -Path $manifestPath).Entries.Count | Should -Be 1

        $verified = Test-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles @()
        $verified.ErrorCount | Should -Be 0

        [System.IO.File]::WriteAllText((Join-Path $source 'sample.txt'), 'changed')
        $changed = Test-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles @()
        $changed.ErrorCount | Should -Be 1
        $changed.Errors[0] | Should -Match 'Checksum mismatch'
    }

    It 'detects a file that is missing from the backup' {
        $source = Join-Path $TestDrive 'missing-source'
        $manifestPath = Join-Path $TestDrive 'missing.tsv'
        New-Item -ItemType Directory -Path $source | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $source 'keep.txt'), 'keep')
        [System.IO.File]::WriteAllText((Join-Path $source 'gone.txt'), 'gone')
        $folders = @([pscustomobject]@{ Name = 'Dokumente'; Path = $source })

        Update-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles @() | Out-Null
        Remove-Item -LiteralPath (Join-Path $source 'gone.txt') -Force

        $verified = Test-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles @()
        $verified.ErrorCount | Should -Be 1
        $verified.Errors[0] | Should -Match 'File missing'
    }

    It 'reports a missing manifest instead of passing verification' {
        $source = Join-Path $TestDrive 'no-manifest-source'
        New-Item -ItemType Directory -Path $source | Out-Null
        $folders = @([pscustomobject]@{ Name = 'Dokumente'; Path = $source })

        $verified = Test-M24ChecksumManifest -Folders $folders -ManifestPath (Join-Path $TestDrive 'does-not-exist.tsv') -ExcludedFiles @()
        $verified.MissingManifest | Should -Be $true
        $verified.ErrorCount | Should -Be 1
    }

    It 'rejects a manipulated manifest header' {
        $manifestPath = Join-Path $TestDrive 'tampered.tsv'
        [System.IO.File]::WriteAllText($manifestPath, "TAMPERED`t1`tSHA256`r`n")
        { Read-M24ChecksumManifest -Path $manifestPath } | Should -Throw '*Unsupported checksum manifest format*'
    }

    It 'does not write a manifest after cancellation' {
        $source = Join-Path $TestDrive 'cancelled-source'
        $manifestPath = Join-Path $TestDrive 'cancelled.tsv'
        New-Item -ItemType Directory -Path $source | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $source 'sample.txt'), 'content')
        $folders = @([pscustomobject]@{ Name = 'Dokumente'; Path = $source })

        $result = Update-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles @() -CancelCallback { $true }
        $result.Cancelled | Should -Be $true
        Test-Path -LiteralPath $manifestPath | Should -Be $false
    }
}

Describe 'Checksum verification metadata' {
    It 'stores and reads back the verification timestamp' {
        $metadataFile = Join-Path $TestDrive '_Sicherungsinfo.txt'
        Write-M24AtomicTextFile -Path $metadataFile -Content "Bibliothekssicherung`r`nComputer: PC`r`nErgebnis: Erfolgreich abgeschlossen am 2026-07-16 08:00:00.`r`n"

        $verifiedAt = Get-Date '2026-07-16 09:30:00'
        Set-M24ChecksumVerifiedMetadata -MetadataFile $metadataFile -VerifiedAt $verifiedAt

        Get-M24ChecksumVerifiedDate -MetadataFile $metadataFile | Should -Be '2026-07-16 09:30:00'
        # Die uebrigen Metadatenzeilen bleiben unveraendert erhalten.
        (Get-Content -LiteralPath $metadataFile) -contains 'Computer: PC' | Should -Be $true
    }

    It 'replaces an existing verification line instead of appending' {
        $metadataFile = Join-Path $TestDrive '_Sicherungsinfo_replace.txt'
        Write-M24AtomicTextFile -Path $metadataFile -Content "Bibliothekssicherung`r`n"
        Set-M24ChecksumVerifiedMetadata -MetadataFile $metadataFile -VerifiedAt (Get-Date '2026-07-15 10:00:00')
        Set-M24ChecksumVerifiedMetadata -MetadataFile $metadataFile -VerifiedAt (Get-Date '2026-07-16 11:00:00')

        @(Get-Content -LiteralPath $metadataFile | Where-Object { $_ -like 'Pruefsummen-Pruefung:*' }).Count | Should -Be 1
        Get-M24ChecksumVerifiedDate -MetadataFile $metadataFile | Should -Be '2026-07-16 11:00:00'
    }

    It 'returns null when no verification has been recorded' {
        $metadataFile = Join-Path $TestDrive '_Sicherungsinfo_none.txt'
        Write-M24AtomicTextFile -Path $metadataFile -Content "Bibliothekssicherung`r`n"
        Get-M24ChecksumVerifiedDate -MetadataFile $metadataFile | Should -Be $null
        Get-M24ChecksumVerifiedDate -MetadataFile (Join-Path $TestDrive 'fehlt.txt') | Should -Be $null
    }
}

Describe 'Write-M24AtomicTextFile' {
    It 'replaces content and leaves no temporary files behind' {
        $path = Join-Path $TestDrive 'atomic.txt'
        Write-M24AtomicTextFile -Path $path -Content 'first'
        Write-M24AtomicTextFile -Path $path -Content 'second'

        Get-Content -LiteralPath $path -Raw | Should -Be 'second'
        @(Get-ChildItem -LiteralPath $TestDrive | Where-Object { $_.Name -like 'atomic.txt.*' }).Count | Should -Be 0
    }
}
