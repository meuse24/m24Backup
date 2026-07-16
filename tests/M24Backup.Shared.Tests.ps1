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

Describe 'ConvertTo-M24ExtendedLengthPath' {
    It 'prefixes local absolute paths' {
        ConvertTo-M24ExtendedLengthPath 'C:\Data\nul' | Should -Be '\\?\C:\Data\nul'
    }

    It 'converts UNC paths to the extended UNC form' {
        ConvertTo-M24ExtendedLengthPath '\\server\share\file.txt' | Should -Be '\\?\UNC\server\share\file.txt'
    }

    It 'leaves already prefixed and relative paths unchanged' {
        ConvertTo-M24ExtendedLengthPath '\\?\C:\Data\nul' | Should -Be '\\?\C:\Data\nul'
        ConvertTo-M24ExtendedLengthPath 'relative\file.txt' | Should -Be 'relative\file.txt'
    }
}

Describe 'Reserved device file names' {
    It 'recognizes reserved device names with and without extensions' {
        foreach ($name in @('nul', 'NUL', 'con.txt', 'com1.bak', 'lpt9', 'aux.tar.gz')) {
            Test-M24ReservedDeviceFileName -Name $name | Should -Be $true -Because $name
        }
        foreach ($name in @('null', 'console.log', 'com10', 'nul2.txt', 'normal.txt')) {
            Test-M24ReservedDeviceFileName -Name $name | Should -Be $false -Because $name
        }
    }

    It 'skips a device-name file whose hashing fails instead of aborting' {
        Mock Get-M24FileSha256 { throw 'FileStream was asked to open a device' } -ParameterFilter { $Path -like '*\nul' }
        $source = Join-Path $TestDrive 'device-fail-source'
        $manifestPath = Join-Path $TestDrive 'device-fail.tsv'
        New-Item -ItemType Directory -Path $source | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $source 'normal.txt'), 'inhalt')
        $devicePath = Join-Path $source 'nul'
        [System.IO.File]::WriteAllText("\\?\$devicePath", 'x')
        $folders = @([pscustomobject]@{ Name = 'Downloads'; Path = $source })
        try {
            $updated = Update-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles @()
            $updated.Cancelled | Should -Be $false
            $updated.Files | Should -Be 1
            $updated.SkippedDeviceFiles | Should -Be 1

            $verified = Test-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles @()
            $verified.ErrorCount | Should -Be 0
        } finally {
            [System.IO.File]::Delete("\\?\$devicePath")
        }
    }

    It 'does not report a manifest-only device entry as a missing file' {
        $source = Join-Path $TestDrive 'device-missing-source'
        $manifestPath = Join-Path $TestDrive 'device-missing.tsv'
        New-Item -ItemType Directory -Path $source | Out-Null
        $devicePath = Join-Path $source 'nul'
        [System.IO.File]::WriteAllText("\\?\$devicePath", 'x')
        $folders = @([pscustomobject]@{ Name = 'Downloads'; Path = $source })
        try {
            Update-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles @() | Out-Null
        } finally {
            [System.IO.File]::Delete("\\?\$devicePath")
        }
        $verified = Test-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles @()
        $verified.ErrorCount | Should -Be 0
    }

    It 'hashes and verifies a file named after a reserved device' {
        $source = Join-Path $TestDrive 'device-source'
        $manifestPath = Join-Path $TestDrive 'device.tsv'
        New-Item -ItemType Directory -Path $source | Out-Null
        $devicePath = Join-Path $source 'nul'
        [System.IO.File]::WriteAllText("\\?\$devicePath", 'device-name-content')
        $folders = @([pscustomobject]@{ Name = 'Downloads'; Path = $source })
        try {
            $updated = Update-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles @()
            $updated.Files | Should -Be 1

            $verified = Test-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles @()
            $verified.ErrorCount | Should -Be 0
            $verified.Files | Should -Be 1
        } finally {
            # Pester raeumt TestDrive mit normalen Pfad-APIs auf; die
            # Geraetenamen-Datei muss deshalb hier explizit geloescht werden.
            [System.IO.File]::Delete("\\?\$devicePath")
        }
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

Describe 'Shared backup identity' {
    It 'builds the profile backup path in one shared helper' {
        Get-M24BackupRoot -Drive $TestDrive -Computer 'PC' -User 'User' |
            Should -Be (Join-Path $TestDrive 'Bibliothekssicherung\PC_User')
    }

    It 'reads and validates computer and user metadata case-insensitively' {
        $lines = @('Computer: TEST-PC', 'Benutzer: TestUser')
        $identity = Get-M24BackupMetadataIdentity -Lines $lines
        $identity.Computer | Should -Be 'TEST-PC'
        $identity.User | Should -Be 'TestUser'
        Test-M24BackupMetadataIdentity -Lines $lines -Computer 'test-pc' -User 'testuser' | Should -Be $true
    }
}

Describe 'Safe backup deletion' {
    BeforeEach {
        $drive = $TestDrive
        $computer = 'TEST-PC'
        $user = 'TestUser'
        $container = Join-Path $drive 'Bibliothekssicherung'
        $script:deletionRoot = Join-Path $container ("{0}_{1}" -f $computer, $user)
        New-Item -ItemType Directory -Path (Join-Path $script:deletionRoot 'Dokumente') -Force | Out-Null
        Write-M24AtomicTextFile -Path (Join-Path $script:deletionRoot '_Sicherungsinfo.txt') -Content @"
Bibliothekssicherung

Computer: $computer
Benutzer: $user
Ordner: Dokumente
Ergebnis: Erfolgreich abgeschlossen am 2026-07-16 08:00:00.
"@
        [System.IO.File]::WriteAllText((Join-Path $script:deletionRoot 'Dokumente\sample.txt'), 'backup data')
    }

    It 'returns identity, content size, and confirmation text for a valid backup' {
        $info = Get-M24BackupDeletionInfo -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'
        $info.Computer | Should -Be 'TEST-PC'
        $info.User | Should -Be 'TestUser'
        $info.Files | Should -Be 2
        $info.Bytes | Should -BeGreaterThan 0
        $info.ConfirmationText | Should -Be 'TEST-PC_TestUser'
    }

    It 'refuses a parent folder or differently named target' {
        {
            Get-M24BackupDeletionInfo -BackupRoot (Split-Path $script:deletionRoot -Parent) -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'
        } | Should -Throw '*expected profile folder*'
    }

    It 'refuses metadata belonging to another user' {
        (Get-Content -LiteralPath (Join-Path $script:deletionRoot '_Sicherungsinfo.txt') -Raw).Replace('Benutzer: TestUser', 'Benutzer: OtherUser') |
            Set-Content -LiteralPath (Join-Path $script:deletionRoot '_Sicherungsinfo.txt')
        {
            Get-M24BackupDeletionInfo -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'
        } | Should -Throw '*does not match*'
    }

    It 'refuses a backup containing a directory junction' {
        $junction = Join-Path $script:deletionRoot 'linked-content'
        New-Item -ItemType Junction -Path $junction -Target $TestDrive | Out-Null
        {
            Get-M24BackupDeletionInfo -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'
        } | Should -Throw '*symbolic link or junction*'
    }

    It 'rechecks junction safety after the preview and removes its lock on refusal' {
        Get-M24BackupDeletionInfo -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser' | Out-Null
        $junction = Join-Path $script:deletionRoot 'late-linked-content'
        New-Item -ItemType Junction -Path $junction -Target $TestDrive | Out-Null
        {
            Remove-M24BackupSafely -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'
        } | Should -Throw '*symbolic link or junction*'
        Test-Path -LiteralPath (Join-Path $script:deletionRoot '_backup.lock') | Should -Be $false
        Test-Path -LiteralPath (Join-Path $script:deletionRoot '_Sicherungsinfo.txt') | Should -Be $true
    }

    It 'refuses deletion while the operation lock is held' {
        $lockPath = Join-Path $script:deletionRoot '_backup.lock'
        $lock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            {
                Remove-M24BackupSafely -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'
            } | Should -Throw '*using this backup*'
            Test-Path -LiteralPath $script:deletionRoot | Should -Be $true
        } finally {
            $lock.Dispose()
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'deletes only the validated profile backup folder' {
        $sibling = Join-Path (Split-Path $script:deletionRoot -Parent) 'OTHER-PC_OtherUser'
        New-Item -ItemType Directory -Path $sibling -Force | Out-Null
        Remove-M24BackupSafely -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser' | Out-Null
        Test-Path -LiteralPath $script:deletionRoot | Should -Be $false
        Test-Path -LiteralPath $sibling | Should -Be $true
    }

    It 'deletes a NUL device-name artifact through its extended path' {
        $devicePath = Join-Path $script:deletionRoot 'Dokumente\nul'
        [System.IO.File]::WriteAllText("\\?\$devicePath", 'device artifact')
        try {
            $result = Remove-M24BackupSafely -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'
            $result.IgnoredDeviceFiles | Should -Be 0
            $result.BackupRootRemoved | Should -Be $true
        } finally {
            if ([System.IO.File]::Exists("\\?\$devicePath")) { [System.IO.File]::Delete("\\?\$devicePath") }
        }
    }

    It 'continues deleting the backup when a NUL artifact cannot be removed' {
        $devicePath = Join-Path $script:deletionRoot 'Dokumente\nul'
        [System.IO.File]::WriteAllText("\\?\$devicePath", 'device artifact')
        Mock Remove-M24ReservedDeviceFile { return $false }
        try {
            $result = Remove-M24BackupSafely -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'
            $result.IgnoredDeviceFiles | Should -Be 1
            $result.BackupRootRemoved | Should -Be $false
            Test-Path -LiteralPath (Join-Path $script:deletionRoot '_Sicherungsinfo.txt') | Should -Be $false
            Test-Path -LiteralPath (Join-Path $script:deletionRoot 'Dokumente\sample.txt') | Should -Be $false
        } finally {
            if ([System.IO.File]::Exists("\\?\$devicePath")) { [System.IO.File]::Delete("\\?\$devicePath") }
        }
    }

    It 'enumerates and deletes a directory named NUL through extended paths' {
        $deviceDirectory = Join-Path $script:deletionRoot 'Dokumente\nul'
        [System.IO.Directory]::CreateDirectory((ConvertTo-M24ExtendedLengthPath $deviceDirectory)) | Out-Null
        [System.IO.File]::WriteAllText((ConvertTo-M24ExtendedLengthPath (Join-Path $deviceDirectory 'inside.txt')), 'inside')
        try {
            $info = Get-M24BackupDeletionInfo -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'
            $info.Files | Should -Be 3
            $result = Remove-M24BackupSafely -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'
            $result.IgnoredDeviceFiles | Should -Be 0
            $result.BackupRootRemoved | Should -Be $true
        } finally {
            if ([System.IO.Directory]::Exists((ConvertTo-M24ExtendedLengthPath $deviceDirectory))) {
                [System.IO.Directory]::Delete((ConvertTo-M24ExtendedLengthPath $deviceDirectory), $true)
            }
        }
    }

    It 'continues when an empty NUL directory itself cannot be removed' {
        $deviceDirectory = Join-Path $script:deletionRoot 'Dokumente\nul'
        [System.IO.Directory]::CreateDirectory((ConvertTo-M24ExtendedLengthPath $deviceDirectory)) | Out-Null
        [System.IO.File]::WriteAllText((ConvertTo-M24ExtendedLengthPath (Join-Path $deviceDirectory 'inside.txt')), 'inside')
        Mock Remove-M24DirectoryEntry {
            if ((Split-Path -Path $Path -Leaf) -eq 'nul') { return $false }
            try {
                [System.IO.Directory]::Delete((ConvertTo-M24ExtendedLengthPath $Path), $false)
                return -not [System.IO.Directory]::Exists((ConvertTo-M24ExtendedLengthPath $Path))
            } catch {
                return $false
            }
        }
        try {
            $result = Remove-M24BackupSafely -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'
            $result.IgnoredDeviceFiles | Should -Be 1
            $result.BackupRootRemoved | Should -Be $false
            [System.IO.File]::Exists((ConvertTo-M24ExtendedLengthPath (Join-Path $deviceDirectory 'inside.txt'))) | Should -Be $false
            Test-Path -LiteralPath (Join-Path $script:deletionRoot '_Sicherungsinfo.txt') | Should -Be $false
        } finally {
            if ([System.IO.Directory]::Exists((ConvertTo-M24ExtendedLengthPath $deviceDirectory))) {
                [System.IO.Directory]::Delete((ConvertTo-M24ExtendedLengthPath $deviceDirectory), $true)
            }
        }
    }

    It 'preserves metadata and cleans up the lock after a mid-deletion failure' {
        Mock Remove-Item {
            if ($LiteralPath -like '*sample.txt') { throw 'simulated file lock' }
            Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
        }
        {
            Remove-M24BackupSafely -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'
        } | Should -Throw '*simulated file lock*'
        Test-Path -LiteralPath (Join-Path $script:deletionRoot '_backup.lock') | Should -Be $false
        Test-Path -LiteralPath (Join-Path $script:deletionRoot '_Sicherungsinfo.txt') | Should -Be $true
    }
}
