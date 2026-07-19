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

Describe 'Drive connection classification' {
    It 'recognizes a fixed disk on the USB bus as external and ejectable' {
        $info = Get-M24DriveConnectionInfo -DriveType 3 -BusType USB
        $info.ConnectionKind | Should -Be 'Usb'
        $info.IsExternal | Should -Be $true
        $info.IsInternal | Should -Be $false
        $info.CanEject | Should -Be $true
    }

    It 'recognizes fixed SATA and NVMe disks as internal' {
        foreach ($busType in @('SATA', 'NVMe')) {
            $info = Get-M24DriveConnectionInfo -DriveType 3 -BusType $busType
            $info.ConnectionKind | Should -Be 'Internal'
            $info.IsInternal | Should -Be $true
            $info.IsExternal | Should -Be $false
            $info.CanEject | Should -Be $false
        }
    }

    It 'does not claim that a fixed disk is internal when its bus is unknown' {
        $info = Get-M24DriveConnectionInfo -DriveType 3 -BusType $null
        $info.ConnectionKind | Should -Be 'Unknown'
        $info.IsInternal | Should -Be $false
        $info.IsExternal | Should -Be $false
        $info.CanEject | Should -Be $false
    }

    It 'keeps removable logical drives ejectable without physical bus data' {
        $info = Get-M24DriveConnectionInfo -DriveType 2 -BusType $null
        $info.ConnectionKind | Should -Be 'Removable'
        $info.IsExternal | Should -Be $true
        $info.CanEject | Should -Be $true
    }
}

Describe 'Shared folder metadata' {
    It 'translates canonical folder names without changing stored names' {
        Get-M24FolderDisplayName 'Dokumente' $false | Should -Be 'Documents'
        Get-M24FolderDisplayName 'Dokumente' $true | Should -Be 'Dokumente'
        Get-M24FolderDisplayName 'Custom' $false | Should -Be 'Custom'
    }

    It 'returns every available canonical standard folder name once' {
        $names = @(Get-M24StandardFolderDefinitions | ForEach-Object Name)
        # Windows may redirect a known folder to the profile root. The
        # production helper deliberately excludes that unsafe broad target,
        # so the available count is environment-dependent. Uniqueness and the
        # explicitly resolved non-known-folder entries are the stable contract.
        $names.Count | Should -BeGreaterOrEqual 7
        @($names | Select-Object -Unique).Count | Should -Be $names.Count
        ($names -contains 'Downloads') | Should -Be $true
        ($names -contains 'Gespeicherte Spiele') | Should -Be $true
        ($names -contains 'Kontakte') | Should -Be $true
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
        try {
            {
                Get-M24BackupDeletionInfo -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'
            } | Should -Throw '*symbolic link or junction*'
        } finally {
            # Die Junction ist nur Testdaten und darf die folgenden Tests nicht
            # beeinflussen. Directory.Delete entfernt den Reparse-Point selbst.
            [System.IO.Directory]::Delete((ConvertTo-M24ExtendedLengthPath $junction), $false)
        }
    }

    It 'rechecks junction safety after the preview and removes its lock on refusal' {
        Get-M24BackupDeletionInfo -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser' | Out-Null
        $junction = Join-Path $script:deletionRoot 'late-linked-content'
        New-Item -ItemType Junction -Path $junction -Target $TestDrive | Out-Null
        try {
            {
                Remove-M24BackupSafely -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'
            } | Should -Throw '*symbolic link or junction*'
            Test-Path -LiteralPath (Join-Path $script:deletionRoot '_backup.lock') | Should -Be $false
            Test-Path -LiteralPath (Join-Path $script:deletionRoot '_Sicherungsinfo.txt') | Should -Be $true
        } finally {
            # Auch diese absichtlich nach der Vorschau angelegte Junction darf
            # nicht in die nachfolgenden Loeschtests durchschlagen.
            [System.IO.Directory]::Delete((ConvertTo-M24ExtendedLengthPath $junction), $false)
        }
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

    It 'removes read-only backup directories after deleting their files' {
        $nestedDirectory = Join-Path $script:deletionRoot 'Dokumente\Schreibgeschuetzt'
        New-Item -ItemType Directory -Path $nestedDirectory -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $nestedDirectory 'inside.txt'), 'backup data')
        [System.IO.File]::SetAttributes($nestedDirectory, ([System.IO.File]::GetAttributes($nestedDirectory) -bor [System.IO.FileAttributes]::ReadOnly))
        [System.IO.File]::SetAttributes((Join-Path $script:deletionRoot 'Dokumente'), ([System.IO.File]::GetAttributes((Join-Path $script:deletionRoot 'Dokumente')) -bor [System.IO.FileAttributes]::ReadOnly))
        [System.IO.File]::SetAttributes($script:deletionRoot, ([System.IO.File]::GetAttributes($script:deletionRoot) -bor [System.IO.FileAttributes]::ReadOnly))

        $result = Remove-M24BackupSafely -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'

        $result.BackupRootRemoved | Should -Be $true
        Test-Path -LiteralPath $script:deletionRoot | Should -Be $false
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
        Mock Remove-M24FileEntry {
            param([string]$Path)
            if ($Path -like '*sample.txt') { throw 'simulated file lock' }
            return $true
        }
        {
            Remove-M24BackupSafely -BackupRoot $script:deletionRoot -Drive $TestDrive -Computer 'TEST-PC' -User 'TestUser'
        } | Should -Throw '*simulated file lock*'
        Test-Path -LiteralPath (Join-Path $script:deletionRoot '_backup.lock') | Should -Be $false
        Test-Path -LiteralPath (Join-Path $script:deletionRoot '_Sicherungsinfo.txt') | Should -Be $true
    }
}

Describe 'Write-M24DiagnosticLog' {
    BeforeEach {
        # Eigenes Unterverzeichnis pro Test, damit Rotationstests nicht von
        # Rueckstaenden anderer Tests abhaengen. Alles bleibt unter $TestDrive.
        $script:diagnosticDirectory = Join-Path $TestDrive ("DiagLogs_{0}" -f [guid]::NewGuid().ToString('N'))
        $script:diagnosticLog = Join-Path $script:diagnosticDirectory 'gui.log'
    }

    It 'creates a missing log directory and the active log file' {
        Test-Path -LiteralPath $script:diagnosticDirectory | Should -Be $false
        Write-M24DiagnosticLog -EventId 'GUI.Test' -Message 'directory creation' -LogDirectory $script:diagnosticDirectory
        Test-Path -LiteralPath $script:diagnosticLog -PathType Leaf | Should -Be $true
    }

    It 'writes timestamp, severity, event id, process id, and message' {
        Write-M24DiagnosticLog -EventId 'GUI.Test' -Message 'Something failed.' -LogDirectory $script:diagnosticDirectory
        $content = Get-Content -LiteralPath $script:diagnosticLog -Raw -Encoding UTF8
        $content | Should -Match '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2} \[ERROR\] \[GUI\.Test\]'
        $content | Should -Match ('PID: {0}' -f $PID)
        $content | Should -Match ([regex]::Escape('Message: Something failed.'))
    }

    It 'records the exception type and the script stack trace from an error record' {
        $errorRecord = try { throw 'diagnostic sample failure' } catch { $_ }
        Write-M24DiagnosticLog -EventId 'GUI.Test' -Message 'wrapper message' -Exception $errorRecord -LogDirectory $script:diagnosticDirectory
        $content = Get-Content -LiteralPath $script:diagnosticLog -Raw -Encoding UTF8
        $content | Should -Match ([regex]::Escape('Exception: System.Management.Automation.RuntimeException'))
        $content | Should -Match ([regex]::Escape('ExceptionMessage: diagnostic sample failure'))
        $content | Should -Match 'Stack: '
    }

    It 'appends entries without overwriting earlier ones' {
        Write-M24DiagnosticLog -EventId 'GUI.First' -Message 'first entry' -LogDirectory $script:diagnosticDirectory
        Write-M24DiagnosticLog -EventId 'GUI.Second' -Message 'second entry' -LogDirectory $script:diagnosticDirectory
        $content = Get-Content -LiteralPath $script:diagnosticLog -Raw -Encoding UTF8
        $content | Should -Match '\[GUI\.First\]'
        $content | Should -Match '\[GUI\.Second\]'
    }

    It 'rotates the active log when it reaches the size limit' {
        Write-M24DiagnosticLog -EventId 'GUI.First' -Message ('x' * 512) -LogDirectory $script:diagnosticDirectory -MaxBytes 200 -FileCount 3
        Write-M24DiagnosticLog -EventId 'GUI.Second' -Message 'after rotation' -LogDirectory $script:diagnosticDirectory -MaxBytes 200 -FileCount 3
        $activeContent = Get-Content -LiteralPath $script:diagnosticLog -Raw -Encoding UTF8
        $archiveContent = Get-Content -LiteralPath (Join-Path $script:diagnosticDirectory 'gui.1.log') -Raw -Encoding UTF8
        $activeContent | Should -Match '\[GUI\.Second\]'
        $activeContent | Should -Not -Match '\[GUI\.First\]'
        $archiveContent | Should -Match '\[GUI\.First\]'
    }

    It 'retains no more than the configured number of files' {
        for ($writeIndex = 1; $writeIndex -le 6; $writeIndex++) {
            Write-M24DiagnosticLog -EventId ('GUI.Write{0}' -f $writeIndex) -Message ('x' * 64) -LogDirectory $script:diagnosticDirectory -MaxBytes 1 -FileCount 3
        }
        $logFiles = @(Get-ChildItem -LiteralPath $script:diagnosticDirectory -File | ForEach-Object Name | Sort-Object)
        $logFiles.Count | Should -Be 3
        $logFiles | Should -Be @('gui.1.log', 'gui.2.log', 'gui.log')
    }

    It 'keeps archives ordered from newest to oldest across repeated rotations' {
        # MaxBytes 1 erzwingt eine Rotation vor jedem weiteren Eintrag.
        foreach ($eventId in @('GUI.A', 'GUI.B', 'GUI.C')) {
            Write-M24DiagnosticLog -EventId $eventId -Message 'ordering' -LogDirectory $script:diagnosticDirectory -MaxBytes 1 -FileCount 3
        }
        (Get-Content -LiteralPath $script:diagnosticLog -Raw -Encoding UTF8) | Should -Match '\[GUI\.C\]'
        (Get-Content -LiteralPath (Join-Path $script:diagnosticDirectory 'gui.1.log') -Raw -Encoding UTF8) | Should -Match '\[GUI\.B\]'
        (Get-Content -LiteralPath (Join-Path $script:diagnosticDirectory 'gui.2.log') -Raw -Encoding UTF8) | Should -Match '\[GUI\.A\]'
    }

    It 'suppresses errors for an unusable log location' {
        $blockingFile = Join-Path $TestDrive ("blocker_{0}.txt" -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $blockingFile -Value 'occupied'
        { Write-M24DiagnosticLog -EventId 'GUI.Test' -Message 'blocked' -LogDirectory $blockingFile } | Should -Not -Throw
        { Write-M24DiagnosticLog -EventId 'GUI.Test' -Message 'invalid' -LogDirectory 'Q:\<invalid>|path' } | Should -Not -Throw
    }

    It 'returns no pipeline output' {
        $output = Write-M24DiagnosticLog -EventId 'GUI.Test' -Message 'no output expected' -LogDirectory $script:diagnosticDirectory
        $output | Should -BeNullOrEmpty
    }

    It 'stores special characters and multiline exception messages intact' {
        $errorRecord = try { throw "Zeile eins`r`nZeile zwei mit ä ö ü ß €" } catch { $_ }
        Write-M24DiagnosticLog -EventId 'GUI.Test' -Message 'Umlaute: äöüß €' -Exception $errorRecord -LogDirectory $script:diagnosticDirectory
        $content = Get-Content -LiteralPath $script:diagnosticLog -Raw -Encoding UTF8
        $content | Should -Match ([regex]::Escape('Umlaute: äöüß €'))
        $content | Should -Match ([regex]::Escape('Zeile zwei mit ä ö ü ß €'))
    }
}

Describe 'Remove-M24StaleTempArtifacts' {
    BeforeAll {
        # Legt eine Kandidatendatei mit definiertem Alter an. Alle Pfade
        # liegen unter $TestDrive; das echte %TEMP% wird nie beruehrt.
        function New-M24CleanupTestFile {
            param([string]$Directory, [string]$Name, [double]$AgeDays)
            $path = Join-Path $Directory $Name
            Set-Content -LiteralPath $path -Value 'x' -NoNewline
            (Get-Item -LiteralPath $path -Force).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-$AgeDays)
            return $path
        }
        $script:validGuid = '0123456789abcdef0123456789abcdef'
    }

    BeforeEach {
        # Eigenes Verzeichnis pro Test, damit sich Kandidaten verschiedener
        # Tests nicht gegenseitig beeinflussen.
        $script:cleanupDirectory = Join-Path $TestDrive ("StaleTemp_{0}" -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:cleanupDirectory | Out-Null
    }

    It 'deletes an old <Extension> communication file' -TestCases @(
        @{ Extension = 'status' }
        @{ Extension = 'result.json' }
        @{ Extension = 'cancel' }
        @{ Extension = 'preview.json' }
        @{ Extension = 'approve' }
        @{ Extension = 'folders.json' }
    ) {
        param($Extension)
        $path = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ("Bibliothekssicherung_{0}.{1}" -f $script:validGuid, $Extension) -AgeDays 10
        Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
        Test-Path -LiteralPath $path | Should -Be $false
    }

    It 'deletes old atomic-write .tmp and .bak remnants' {
        $tmpRemnant = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ("Bibliothekssicherung_{0}.result.json.{0}.tmp" -f $script:validGuid) -AgeDays 10
        $bakRemnant = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ("Bibliothekssicherung_{0}.status.{0}.bak" -f $script:validGuid) -AgeDays 10
        Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
        Test-Path -LiteralPath $tmpRemnant | Should -Be $false
        Test-Path -LiteralPath $bakRemnant | Should -Be $false
    }

    It 'deletes an old checksum-verification cancellation marker' {
        $marker = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ("M24Backup.verify-cancel.4242.{0}.tmp" -f $script:validGuid) -AgeDays 10
        Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
        Test-Path -LiteralPath $marker | Should -Be $false
    }

    It 'preserves fresh matching files including an active cancellation request' {
        $status = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ("Bibliothekssicherung_{0}.status" -f $script:validGuid) -AgeDays 0
        $cancel = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ("Bibliothekssicherung_{0}.cancel" -f $script:validGuid) -AgeDays 0
        Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
        Test-Path -LiteralPath $status | Should -Be $true
        Test-Path -LiteralPath $cancel | Should -Be $true
    }

    It 'preserves a fresh verification-cancel marker' {
        $marker = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ("M24Backup.verify-cancel.4242.{0}.tmp" -f $script:validGuid) -AgeDays 0
        Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
        Test-Path -LiteralPath $marker | Should -Be $true
    }

    It 'preserves a file just newer than the cutoff' {
        # Grosszuegiger Abstand von einem Tag zur Sieben-Tage-Grenze, damit
        # der Test nicht von Zeitpraezision abhaengt.
        $path = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ("Bibliothekssicherung_{0}.status" -f $script:validGuid) -AgeDays 6
        Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
        Test-Path -LiteralPath $path | Should -Be $true
    }

    It 'deletes a file just older than the cutoff' {
        # Knapp jenseits der Grenze (rund 15 Minuten), aber weit genug fuer
        # normale Dateisystem-Zeitstempelpraezision.
        $path = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ("Bibliothekssicherung_{0}.status" -f $script:validGuid) -AgeDays 7.01
        Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
        Test-Path -LiteralPath $path | Should -Be $false
    }

    It 'preserves the similar but invalid name <Name>' -TestCases @(
        @{ Name = 'Bibliothekssicherung_0123456789abcdef0123456789abcde.status' }
        @{ Name = 'Bibliothekssicherung_0123456789abcdef0123456789abcdeg.status' }
        @{ Name = 'Bibliothekssicherung_0123456789abcdef0123456789abcdef.status.txt' }
        @{ Name = 'Bibliothekssicherung_0123456789abcdef0123456789abcdef.log' }
        @{ Name = 'Bibliothekssicherung_0123456789abcdef0123456789abcdef.status.0123456789abcdef0123456789abcdef.tmp2' }
        @{ Name = 'Bibliothekssicherung_0123456789abcdef0123456789abcdef.status.0123456789abcdef0123456789abcde.tmp' }
        @{ Name = 'XBibliothekssicherung_0123456789abcdef0123456789abcdef.status' }
        @{ Name = 'M24Backup.verify-cancel.notapid.0123456789abcdef0123456789abcdef.tmp' }
        @{ Name = 'M24Backup.verify-cancel.4242.0123456789abcdef0123456789abcdef.tmp.old' }
    ) {
        param($Name)
        $path = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name $Name -AgeDays 10
        Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
        Test-Path -LiteralPath $path | Should -Be $true
    }

    It 'preserves a file symbolic link with a matching name' {
        # Symlink-Erstellung braucht unter Windows Adminrechte oder Developer
        # Mode. Ist beides nicht verfuegbar, wird der Test uebersprungen
        # statt falsch fehlzuschlagen.
        $linkTarget = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name 'symlink-target.txt' -AgeDays 10
        $linkPath = Join-Path $script:cleanupDirectory ("Bibliothekssicherung_{0}.status" -f $script:validGuid)
        try {
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $linkTarget -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because 'symbolic links cannot be created in this environment'
            return
        }
        (Get-Item -LiteralPath $linkPath -Force).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-10)
        Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
        Test-Path -LiteralPath $linkPath | Should -Be $true
        Test-Path -LiteralPath $linkTarget | Should -Be $true
    }

    It 'preserves a directory with a matching name' {
        $directoryPath = Join-Path $script:cleanupDirectory ("Bibliothekssicherung_{0}.status" -f $script:validGuid)
        New-Item -ItemType Directory -Path $directoryPath | Out-Null
        (Get-Item -LiteralPath $directoryPath -Force).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-10)
        Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
        Test-Path -LiteralPath $directoryPath -PathType Container | Should -Be $true
    }

    It 'does not inspect files in subdirectories' {
        $subdirectory = Join-Path $script:cleanupDirectory 'Unterordner'
        New-Item -ItemType Directory -Path $subdirectory | Out-Null
        $nested = New-M24CleanupTestFile -Directory $subdirectory -Name ("Bibliothekssicherung_{0}.status" -f $script:validGuid) -AgeDays 10
        Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
        Test-Path -LiteralPath $nested | Should -Be $true
    }

    It 'does not throw for a missing directory' {
        { Remove-M24StaleTempArtifacts -TempDirectory (Join-Path $script:cleanupDirectory 'DoesNotExist') } | Should -Not -Throw
    }

    It 'does not throw for an unusable directory path' {
        $blockingFile = Join-Path $script:cleanupDirectory 'blocker.txt'
        Set-Content -LiteralPath $blockingFile -Value 'occupied'
        { Remove-M24StaleTempArtifacts -TempDirectory $blockingFile } | Should -Not -Throw
        { Remove-M24StaleTempArtifacts -TempDirectory 'Q:\<invalid>|path' } | Should -Not -Throw
    }

    It 'deletes nothing for a zero or negative MinimumAge' {
        $path = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ("Bibliothekssicherung_{0}.status" -f $script:validGuid) -AgeDays 10
        Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory -MinimumAge ([TimeSpan]::Zero)
        Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory -MinimumAge ([TimeSpan]::FromDays(-1))
        Test-Path -LiteralPath $path | Should -Be $true
    }

    It 'returns no pipeline output' {
        New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ("Bibliothekssicherung_{0}.status" -f $script:validGuid) -AgeDays 10 | Out-Null
        $output = Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
        $output | Should -BeNullOrEmpty
    }

    It 'deletes an old read-only communication file' {
        $path = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ("Bibliothekssicherung_{0}.status" -f $script:validGuid) -AgeDays 10
        Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $true
        try {
            Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
            Test-Path -LiteralPath $path | Should -Be $false
        } finally {
            # Attribut zuruecksetzen, falls die Loeschung fehlschlug, damit
            # Pester $TestDrive zuverlaessig aufraeumen kann.
            if (Test-Path -LiteralPath $path) { Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $false }
        }
    }

    It 'deletes an old read-only atomic remnant' {
        $path = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ("Bibliothekssicherung_{0}.result.json.{0}.tmp" -f $script:validGuid) -AgeDays 10
        Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $true
        try {
            Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
            Test-Path -LiteralPath $path | Should -Be $false
        } finally {
            if (Test-Path -LiteralPath $path) { Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $false }
        }
    }

    It 'deletes an old hidden read-only communication file' {
        $path = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ("Bibliothekssicherung_{0}.status" -f $script:validGuid) -AgeDays 10
        [System.IO.File]::SetAttributes($path, ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::ReadOnly))
        try {
            Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
            Test-Path -LiteralPath $path | Should -Be $false
        } finally {
            if (Test-Path -LiteralPath $path) { [System.IO.File]::SetAttributes($path, [System.IO.FileAttributes]::Normal) }
        }
    }

    It 'preserves a fresh read-only file and keeps it read-only' {
        $path = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ("Bibliothekssicherung_{0}.status" -f $script:validGuid) -AgeDays 0
        Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $true
        try {
            Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
            Test-Path -LiteralPath $path | Should -Be $true
            (Get-Item -LiteralPath $path -Force).IsReadOnly | Should -Be $true
        } finally {
            if (Test-Path -LiteralPath $path) { Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $false }
        }
    }

    It 'preserves an old read-only file with an invalid name and keeps it read-only' {
        $path = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name 'Bibliothekssicherung_0123456789abcdef0123456789abcde.status' -AgeDays 10
        Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $true
        try {
            Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory
            Test-Path -LiteralPath $path | Should -Be $true
            (Get-Item -LiteralPath $path -Force).IsReadOnly | Should -Be $true
        } finally {
            if (Test-Path -LiteralPath $path) { Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $false }
        }
    }

    It 'refreshes metadata and rejects reparse points before any attribute mutation' {
        # Struktureller Vertragstest: Refresh() -> ReparsePoint-Ablehnung ->
        # ReadOnly-Behandlung -> Delete muessen in dieser Reihenfolge stehen.
        $sharedScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'M24Backup.Shared.ps1'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($sharedScript, [ref]$tokens, [ref]$parseErrors)
        $cleanupFunction = $ast.Find({
                param($node)
                ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
                $node.Name -eq 'Remove-M24StaleTempArtifacts'
            }, $true)
        $cleanupFunction | Should -Not -BeNullOrEmpty
        $text = $cleanupFunction.Extent.Text
        $refreshIndex = $text.IndexOf('.Refresh()')
        $reparseIndex = $text.IndexOf('::ReparsePoint')
        $setAttributesIndex = $text.IndexOf('::SetAttributes')
        $deleteIndex = $text.IndexOf('[System.IO.File]::Delete')
        $refreshIndex | Should -BeGreaterThan -1
        $reparseIndex | Should -BeGreaterThan $refreshIndex
        $setAttributesIndex | Should -BeGreaterThan $reparseIndex
        $deleteIndex | Should -BeGreaterThan $setAttributesIndex
    }

    It 'continues after a candidate cannot be removed' {
        # Der gesperrte Kandidat liegt alphabetisch vor dem zweiten, wird
        # also zuerst enumeriert; die Bereinigung muss trotzdem fortfahren.
        $lockedPath = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ('Bibliothekssicherung_{0}.status' -f ('a' * 32)) -AgeDays 10
        $otherPath = New-M24CleanupTestFile -Directory $script:cleanupDirectory -Name ('Bibliothekssicherung_{0}.cancel' -f ('b' * 32)) -AgeDays 10
        $handle = [System.IO.File]::Open($lockedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try {
            { Remove-M24StaleTempArtifacts -TempDirectory $script:cleanupDirectory } | Should -Not -Throw
        } finally {
            $handle.Dispose()
        }
        Test-Path -LiteralPath $lockedPath | Should -Be $true
        Test-Path -LiteralPath $otherPath | Should -Be $false
    }

    It 'is called exactly once by the GUI script' {
        $guiScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Bibliothekssicherung-GUI.ps1'
        $content = Get-Content -LiteralPath $guiScript -Raw
        ([regex]::Matches($content, 'Remove-M24StaleTempArtifacts')).Count | Should -Be 1
    }
}

Describe 'Stop-M24WorkerProcess' {
    BeforeAll {
        # Kindprozesse laufen immer unter Windows PowerShell, wie der echte
        # Worker; das haelt die Tests unter PS7 und PS5.1 identisch.
        $script:windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        function Start-M24TestChild {
            param([string]$Command)
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $script:windowsPowerShell
            $markedCommand = "# M24Backup.PesterChild`r`n{0}" -f $Command
            $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command ' + (ConvertTo-M24ProcessArgument $markedCommand)
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $child = New-Object System.Diagnostics.Process
            $child.StartInfo = $startInfo
            if (-not $child.Start()) { throw 'Test child process could not be started.' }
            return $child
        }

        # Sicherheitsnetz: Kein Test darf einen Kindprozess zuruecklassen,
        # auch nicht nach einer fehlgeschlagenen Assertion.
        function Stop-M24TestChildById {
            param([int]$ProcessId)
            try { Stop-Process -Id $ProcessId -Force -ErrorAction Stop } catch {}
        }
    }

    It 'kills a worker that ignores the cancellation request' {
        $child = Start-M24TestChild -Command 'Start-Sleep -Seconds 120'
        $childId = $child.Id
        try {
            $cancelFile = Join-Path $TestDrive ("cancel_{0}.txt" -f [guid]::NewGuid().ToString('N'))
            $confirmed = Stop-M24WorkerProcess -Process $child -CancelFile $cancelFile -GracefulWaitMilliseconds 250 -KillWaitMilliseconds 10000
            $confirmed | Should -BeTrue
            Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Test-Path -LiteralPath $cancelFile | Should -Be $true
        } finally {
            Stop-M24TestChildById -ProcessId $childId
        }
    }

    It 'lets a cancel-aware worker exit gracefully without killing it' {
        $cancelFile = Join-Path $TestDrive ("cancel_{0}.txt" -f [guid]::NewGuid().ToString('N'))
        $doneFile = Join-Path $TestDrive ("done_{0}.txt" -f [guid]::NewGuid().ToString('N'))
        # Der Kindprozess wartet auf die Cancel-Datei und hinterlaesst nur bei
        # freiwilligem Ende die Done-Datei; ein Kill wuerde sie verhindern.
        $childCommand = "while (-not (Test-Path -LiteralPath '{0}')) {{ Start-Sleep -Milliseconds 100 }}; Set-Content -LiteralPath '{1}' -Value ok" -f $cancelFile, $doneFile
        $child = Start-M24TestChild -Command $childCommand
        $childId = $child.Id
        try {
            $confirmed = Stop-M24WorkerProcess -Process $child -CancelFile $cancelFile -GracefulWaitMilliseconds 20000 -KillWaitMilliseconds 2000
            $confirmed | Should -BeTrue
            Test-Path -LiteralPath $doneFile | Should -Be $true
            Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        } finally {
            Stop-M24TestChildById -ProcessId $childId
        }
    }

    It 'confirms the exit for a process object that was never started' {
        $unstarted = New-Object System.Diagnostics.Process
        $confirmed = Stop-M24WorkerProcess -Process $unstarted
        $confirmed | Should -BeTrue
    }

    It 'confirms the exit for a missing process' {
        $confirmed = Stop-M24WorkerProcess -Process $null
        $confirmed | Should -BeTrue
    }

    It 'handles an already exited process without cancel marker and confirms the exit' {
        $cancelFile = Join-Path $TestDrive ("cancel_{0}.txt" -f [guid]::NewGuid().ToString('N'))
        $child = Start-M24TestChild -Command 'exit 0'
        $childId = $child.Id
        try {
            [void]$child.WaitForExit(30000)
            $output = @(Stop-M24WorkerProcess -Process $child -CancelFile $cancelFile)
            # Genau die Bestaetigung, keine weitere Pipeline-Ausgabe.
            $output.Count | Should -Be 1
            $output[0] | Should -BeTrue
            Test-Path -LiteralPath $cancelFile | Should -Be $false
        } finally {
            Stop-M24TestChildById -ProcessId $childId
        }
    }

    It 'reports an unconfirmed exit without throwing when the process cannot be killed' {
        # Prozess-Attrappe, deren Ende sich weder abwarten noch erzwingen
        # laesst. Der untypisierte Process-Parameter macht das moeglich, ohne
        # einen echten unbeendbaren Prozess zu benoetigen.
        $stubborn = [pscustomobject]@{ HasExited = $false }
        $stubborn | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds) return $false }
        $stubborn | Add-Member -MemberType ScriptMethod -Name Kill -Value { throw 'access denied' }
        $stubborn | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        $cancelFile = Join-Path $TestDrive ("cancel_{0}.txt" -f [guid]::NewGuid().ToString('N'))
        { $script:confirmed = Stop-M24WorkerProcess -Process $stubborn -CancelFile $cancelFile } | Should -Not -Throw
        $script:confirmed | Should -BeFalse
        # Das Abbruchsignal wurde trotzdem hinterlegt.
        Test-Path -LiteralPath $cancelFile | Should -Be $true
    }

    It 'caps graceful and kill waits inside the function body' {
        $sharedScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'M24Backup.Shared.ps1'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($sharedScript, [ref]$tokens, [ref]$parseErrors)
        $stopFunction = $ast.Find({
                param($node)
                ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
                $node.Name -eq 'Stop-M24WorkerProcess'
            }, $true)
        $stopFunction | Should -Not -BeNullOrEmpty
        ([regex]::Matches($stopFunction.Extent.Text, [regex]::Escape('[Math]::Min(10000, [Math]::Max(0,'))).Count | Should -Be 2
    }
}

Describe 'GUI owner cancellation policy' {
    It 'does not request cancellation for a direct CLI run' {
        $state = Get-M24CancellationState -ParentProcessId 0 -Monitor (New-M24CancellationMonitor) -MinimumOwnerCheckIntervalMilliseconds 0
        $state.Requested | Should -BeFalse
        $state.Reason | Should -Be 'None'
    }

    It 'accepts the matching current process identity' {
        $process = [System.Diagnostics.Process]::GetCurrentProcess()
        $state = Get-M24CancellationState -ParentProcessId $PID -ParentProcessStartTimeUtcTicks $process.StartTime.ToUniversalTime().Ticks `
            -Monitor (New-M24CancellationMonitor) -MinimumOwnerCheckIntervalMilliseconds 0
        $state.Requested | Should -BeFalse
    }

    It 'rejects a reused PID immediately when the start time differs' {
        $state = Get-M24CancellationState -ParentProcessId $PID -ParentProcessStartTimeUtcTicks 1 `
            -Monitor (New-M24CancellationMonitor) -MinimumOwnerCheckIntervalMilliseconds 0
        $state.Requested | Should -BeTrue
        $state.Reason | Should -Be 'GuiExited'
    }

    It 'debounces a missing owner but eventually reports GUI exit' {
        $monitor = New-M24CancellationMonitor
        (Get-M24CancellationState -ParentProcessId 2147483000 -Monitor $monitor -MinimumOwnerCheckIntervalMilliseconds 0).Requested | Should -BeFalse
        $state = Get-M24CancellationState -ParentProcessId 2147483000 -Monitor $monitor -MinimumOwnerCheckIntervalMilliseconds 0
        $state.Requested | Should -BeTrue
        $state.Reason | Should -Be 'GuiExited'
    }

    It 'gives an explicit cancel marker precedence over owner loss' {
        $cancel = Join-Path $TestDrive 'cancel.marker'
        Set-Content -LiteralPath $cancel -Value cancel
        $state = Get-M24CancellationState -CancelFile $cancel -ParentProcessId 2147483000 -ParentProcessStartTimeUtcTicks 1 `
            -Monitor (New-M24CancellationMonitor) -MinimumOwnerCheckIntervalMilliseconds 0
        $state.Reason | Should -Be 'User'
    }
}

Describe 'Restore integrity approval policy' {
    It 'accepts a current verified marker without rehashing' {
        $decision = Resolve-M24RestoreApproval -Policy Verify -ApprovalValue continue-verified -ManifestExists $true -AlreadyVerified $true
        $decision.Allowed | Should -BeTrue
        $decision.RequiresVerification | Should -BeFalse
    }

    It 'requires verification for an existing unverified manifest' {
        $decision = Resolve-M24RestoreApproval -Policy Verify -ApprovalValue verify-then-continue -ManifestExists $true -AlreadyVerified $false
        $decision.Allowed | Should -BeTrue
        $decision.RequiresVerification | Should -BeTrue
    }

    It 'allows only the explicit override when the manifest is missing' {
        (Resolve-M24RestoreApproval -Policy Verify -ApprovalValue verify-then-continue -ManifestExists $false -AlreadyVerified $false).Allowed | Should -BeFalse
        $override = Resolve-M24RestoreApproval -Policy Verify -ApprovalValue continue-unverified -ManifestExists $false -AlreadyVerified $false
        $override.Allowed | Should -BeTrue
        $override.UnverifiedOverride | Should -BeTrue
    }

    It 'does not let RequireVerified create or bypass verification' {
        (Resolve-M24RestoreApproval -Policy RequireVerified -ApprovalValue verify-then-continue -ManifestExists $true -AlreadyVerified $false).Allowed | Should -BeFalse
        (Resolve-M24RestoreApproval -Policy RequireVerified -ApprovalValue continue-unverified -ManifestExists $false -AlreadyVerified $false).Allowed | Should -BeFalse
    }

    It 'keeps legacy continue limited to Warn' {
        (Resolve-M24RestoreApproval -Policy Warn -ApprovalValue continue -ManifestExists $false -AlreadyVerified $false).Allowed | Should -BeTrue
        (Resolve-M24RestoreApproval -Policy Verify -ApprovalValue continue -ManifestExists $true -AlreadyVerified $false).Allowed | Should -BeFalse
    }
}

Describe 'Layered known-drive fingerprint' {
    It 'prefers an exact volume GUID' {
        $known = [pscustomobject]@{ VolumeGuid = '\\?\Volume{11111111-1111-1111-1111-111111111111}\'; VolumeSerialNumber = 'AAAA' }
        $candidate = [pscustomobject]@{ VolumeGuid = $known.VolumeGuid; VolumeSerialNumber = 'BBBB' }
        $match = Compare-M24DriveFingerprint -Known $known -Candidate $candidate
        $match.IsMatch | Should -BeTrue
        $match.Confidence | Should -Be 'Strong'
    }

    It 'rejects a conflicting strong identifier' {
        $known = [pscustomobject]@{ DiskUniqueId = 'DISK-A'; VolumeSerialNumber = 'AAAA' }
        $candidate = [pscustomobject]@{ DiskUniqueId = 'DISK-B'; VolumeSerialNumber = 'AAAA' }
        (Compare-M24DriveFingerprint -Known $known -Candidate $candidate).IsMatch | Should -BeFalse
    }

    It 'uses serial size and file system as a fallback' {
        $known = [pscustomobject]@{ VolumeSerialNumber = 'ABCD'; SizeBytes = 1000; FileSystem = 'NTFS' }
        $candidate = [pscustomobject]@{ VolumeSerialNumber = 'ABCD'; SizeBytes = 1000; FileSystem = 'ntfs' }
        (Compare-M24DriveFingerprint -Known $known -Candidate $candidate).Confidence | Should -Be 'Fallback'
    }

    It 'recognizes legacy serial records without overstating confidence' {
        $known = [pscustomobject]@{ SerialNumber = 'AB-CD' }
        $candidate = [pscustomobject]@{ VolumeSerialNumber = 'AB-CD' }
        (Compare-M24DriveFingerprint -Known $known -Candidate $candidate).Confidence | Should -Be 'Legacy'
    }
}

Describe 'Single-instance mutex lifecycle' {
    It 'acquires, releases, and reacquires a unique mutex' {
        $name = 'Local\M24Backup.Test.{0}' -f [guid]::NewGuid().ToString('N')
        $first = Enter-M24SingleInstance -Name $name
        try { $first.Acquired | Should -BeTrue } finally { Exit-M24SingleInstance -Handle $first }
        $second = Enter-M24SingleInstance -Name $name
        try { $second.Acquired | Should -BeTrue } finally { Exit-M24SingleInstance -Handle $second }
    }

    It 'rejects the same mutex while another process owns it' {
        $name = 'Local\M24Backup.Test.{0}' -f [guid]::NewGuid().ToString('N')
        $ready = Join-Path $TestDrive 'mutex-ready.txt'
        $release = Join-Path $TestDrive 'mutex-release.txt'
        $shared = Join-Path (Split-Path $PSScriptRoot -Parent) 'M24Backup.Shared.ps1'
        $escape = { param([string]$text) $text.Replace("'", "''") }
        $childCommand = "# M24Backup.PesterChild`r`n. '{0}'; `$h=Enter-M24SingleInstance -Name '{1}'; try {{ if(`$h.Acquired){{[IO.File]::WriteAllText('{2}','ready'); while(-not [IO.File]::Exists('{3}')){{Start-Sleep -Milliseconds 50}}}} }} finally {{ Exit-M24SingleInstance -Handle `$h }}" -f `
            (& $escape $shared), (& $escape $name), (& $escape $ready), (& $escape $release)
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $startInfo.Arguments = (@('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $childCommand) |
            ForEach-Object { ConvertTo-M24ProcessArgument ([string]$_) }) -join ' '
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $child = New-Object System.Diagnostics.Process
        $child.StartInfo = $startInfo
        try {
            [void]$child.Start()
            $deadline = [datetime]::UtcNow.AddSeconds(5)
            while (-not (Test-Path -LiteralPath $ready) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
            Test-Path -LiteralPath $ready | Should -BeTrue
            $contender = Enter-M24SingleInstance -Name $name
            try { $contender.Acquired | Should -BeFalse } finally { Exit-M24SingleInstance -Handle $contender }
        } finally {
            [System.IO.File]::WriteAllText($release, 'release')
            if (-not $child.WaitForExit(2000)) { $child.Kill(); [void]$child.WaitForExit(2000) }
            $child.Dispose()
        }
    }
}

Describe 'Backup reminder policy' {
    It 'treats a missing or invalid successful-backup date as never backed up and due' {
        foreach ($value in @($null, '', 'not-a-date')) {
            $state = Get-M24BackupReminderState -LastSuccessfulBackup $value -Now ([DateTimeOffset]'2026-07-18T12:00:00Z') -ThresholdDays 7
            $state.IsDue | Should -BeTrue
            $state.NeverBackedUp | Should -BeTrue
            $state.DaysSinceBackup | Should -BeNullOrEmpty
        }
    }

    It 'is due exactly at the default fourteen-day boundary across time zones' {
        $state = Get-M24BackupReminderState -LastSuccessfulBackup '2026-07-03T10:00:00.0000000+02:00' `
            -Now ([DateTimeOffset]'2026-07-17T08:00:00Z')
        $state.IsDue | Should -BeTrue
        $state.NeverBackedUp | Should -BeFalse
        $state.DaysSinceBackup | Should -Be 14
        $state.ThresholdDays | Should -Be 14
    }

    It 'is not due just before fourteen days or for a future timestamp' {
        (Get-M24BackupReminderState -LastSuccessfulBackup '2026-07-03T10:00:00Z' -Now ([DateTimeOffset]'2026-07-17T09:59:59Z')).IsDue | Should -BeFalse
        $future = Get-M24BackupReminderState -LastSuccessfulBackup '2026-07-20T10:00:00Z' -Now ([DateTimeOffset]'2026-07-18T10:00:00Z')
        $future.IsDue | Should -BeFalse
        $future.DaysSinceBackup | Should -Be 0
    }

    It 'builds a fully quoted startup command for paths with spaces' {
        $command = Get-M24StartupReminderCommand -VbsPath 'C:\Program Files\M24 Backup\Bibliothekssicherung starten.vbs' -WscriptPath 'C:\Windows\System32\wscript.exe'
        $command | Should -Be '"C:\Windows\System32\wscript.exe" "C:\Program Files\M24 Backup\Bibliothekssicherung starten.vbs" /SilentStartup'
    }

    It 'derives a stable user-specific GUI mutex name' {
        $first = Get-M24GuiMutexName -UserSid 'S-1-5-21-1000'
        $second = Get-M24GuiMutexName -UserSid 'S-1-5-21-1000'
        $other = Get-M24GuiMutexName -UserSid 'S-1-5-21-2000'
        $first | Should -Be $second
        $first | Should -Match '^Local\\M24Backup\.GUI\.[0-9A-F]{16}$'
        $other | Should -Not -Be $first
    }

    It 'round-trips reminder registration only in an isolated HKCU test key' {
        $testRegistryRoot = 'HKCU:\Software\M24BackupReminderTests_{0}' -f [guid]::NewGuid().ToString('N')
        $testRegistryPath = Join-Path $testRegistryRoot 'Run'
        try {
            [void](New-Item -Path $testRegistryRoot -Force)
            Get-M24StartupReminderRegistration -RegistryPath $testRegistryPath | Should -BeNullOrEmpty
            Set-M24StartupReminderRegistration -RegistryPath $testRegistryPath -Command 'test-command'
            Get-M24StartupReminderRegistration -RegistryPath $testRegistryPath | Should -Be 'test-command'
            Remove-M24StartupReminderRegistration -RegistryPath $testRegistryPath
            Get-M24StartupReminderRegistration -RegistryPath $testRegistryPath | Should -BeNullOrEmpty
            { Remove-M24StartupReminderRegistration -RegistryPath $testRegistryPath } | Should -Not -Throw
        } finally {
            if (Test-Path -LiteralPath $testRegistryRoot) { Remove-Item -LiteralPath $testRegistryRoot -Recurse -Force }
        }
    }

    It 'preserves unrelated values in an existing registry key' {
        $testRegistryRoot = 'HKCU:\Software\M24BackupReminderTests_{0}' -f [guid]::NewGuid().ToString('N')
        $testRegistryPath = Join-Path $testRegistryRoot 'Run'
        try {
            [void](New-Item -Path $testRegistryRoot -Force)
            [void](New-Item -Path $testRegistryPath -Force)
            [void](New-ItemProperty -LiteralPath $testRegistryPath -Name 'ForeignStartupEntry' -Value 'keep-me' -PropertyType String -Force)

            Set-M24StartupReminderRegistration -RegistryPath $testRegistryPath -Command 'm24-command'

            $values = Get-ItemProperty -LiteralPath $testRegistryPath
            $values.ForeignStartupEntry | Should -Be 'keep-me'
            $values.M24Backup | Should -Be 'm24-command'
        } finally {
            if (Test-Path -LiteralPath $testRegistryRoot) { Remove-Item -LiteralPath $testRegistryRoot -Recurse -Force }
        }
    }
}

Describe 'GUI worker launch and drive discovery contract' {
    BeforeAll {
        # AST-basierte Vertragstests: Sie pruefen Struktur und Reihenfolge der
        # gehaerteten GUI-Ablaeufe, ohne die WinForms-Anwendung auszufuehren
        # und ohne auf Zeilennummern angewiesen zu sein.
        $guiScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Bibliothekssicherung-GUI.ps1'
        $tokens = $null
        $parseErrors = $null
        $script:guiAst = [System.Management.Automation.Language.Parser]::ParseFile($guiScript, [ref]$tokens, [ref]$parseErrors)
        $script:guiParseErrorCount = @($parseErrors).Count
        $script:guiText = $script:guiAst.Extent.Text

        $script:launchTry = $script:guiAst.Find({
                param($node)
                ($node -is [System.Management.Automation.Language.TryStatementAst]) -and
                @($node.CatchClauses | Where-Object { $_.Extent.Text -match "'GUI\.WorkerStart'" }).Count -gt 0
            }, $true)
        $script:launchTryText = if ($script:launchTry) { $script:launchTry.Body.Extent.Text } else { '' }
        $script:launchCatchText = if ($script:launchTry) {
            @($script:launchTry.CatchClauses | Where-Object { $_.Extent.Text -match "'GUI\.WorkerStart'" })[0].Extent.Text
        } else { '' }

        $script:updateDriveList = $script:guiAst.Find({
                param($node)
                ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
                $node.Name -eq 'Update-DriveList'
            }, $true)
        $script:updateDriveListText = if ($script:updateDriveList) { $script:updateDriveList.Extent.Text } else { '' }
    }

    It 'parses the GUI script and locates launch try and Update-DriveList' {
        $script:guiParseErrorCount | Should -Be 0
        $script:launchTry | Should -Not -BeNullOrEmpty
        $script:updateDriveList | Should -Not -BeNullOrEmpty
    }

    It 'starts the polling timer exactly once, before the worker process start' {
        ([regex]::Matches($script:guiText, [regex]::Escape('$timer.Start()'))).Count | Should -Be 1
        $timerIndex = $script:launchTryText.IndexOf('$timer.Start()')
        $processIndex = $script:launchTryText.IndexOf('$script:backupProcess.Start()')
        $timerIndex | Should -BeGreaterThan (-1)
        $processIndex | Should -BeGreaterThan $timerIndex
    }

    It 'stops the polling timer inside the launch catch' {
        $script:launchCatchText.Contains('$timer.Stop()') | Should -Be $true
    }

    It 'terminates the worker via Stop-M24WorkerProcess before cleaning communication files' {
        $stopIndex = $script:launchCatchText.IndexOf('Stop-M24WorkerProcess')
        $cleanupIndex = $script:launchCatchText.IndexOf('Remove-Item')
        $stopIndex | Should -BeGreaterThan (-1)
        $cleanupIndex | Should -BeGreaterThan $stopIndex
        $script:launchCatchText.Contains('-CancelFile') | Should -Be $true
    }

    It 'cleans communication files only after a confirmed worker exit' {
        # Ohne Bestaetigung muss die Cancel-Datei erhalten bleiben, damit das
        # Abbruchsignal fuer einen weiterlaufenden Worker wirksam bleibt.
        $script:launchCatchText.Contains('$workerExitConfirmed = Stop-M24WorkerProcess') | Should -Be $true
        $script:launchCatchText.Contains('if ($workerExitConfirmed)') | Should -Be $true
        $guardIndex = $script:launchCatchText.IndexOf('if ($workerExitConfirmed)')
        $cleanupIndex = $script:launchCatchText.IndexOf('Remove-Item')
        $cleanupIndex | Should -BeGreaterThan $guardIndex
    }

    It 'bounds the Win32_LogicalDisk query with an 8 second timeout and terminating errors' {
        # The CIM command intentionally lives inside the script passed to a
        # background runspace, so inspect the function text rather than only
        # the outer PowerShell AST.
        $updateText = $script:updateDriveList.Extent.Text
        $updateText | Should -Match 'Get-CimInstance Win32_LogicalDisk'
        $updateText | Should -Match '-OperationTimeoutSec 8'
        $updateText | Should -Match '-ErrorAction Stop'
        $updateText | Should -Match ([regex]::Escape('$driveProbe.BeginInvoke()'))
        $updateText | Should -Match ([regex]::Escape('Set-StartupSplashStatus'))
    }

    It 'skips automatic refresh during retry backoff but lets Force bypass it' {
        $backoffIf = $script:updateDriveList.Find({
                param($node)
                ($node -is [System.Management.Automation.Language.IfStatementAst]) -and
                $node.Clauses[0].Item1.Extent.Text -match 'driveRetryAfterUtc'
            }, $true)
        $backoffIf | Should -Not -BeNullOrEmpty
        $backoffIf.Clauses[0].Item1.Extent.Text | Should -Match '-not \$Force'
        $backoffIf.Clauses[0].Item2.Extent.Text | Should -Match 'return'
    }

    It 'resets the backoff after a successful query, before the snapshot early return' {
        $resetIndex = $script:updateDriveListText.IndexOf('$script:driveRetryAfterUtc = [DateTime]::MinValue')
        $snapshotIndex = $script:updateDriveListText.IndexOf('$script:driveSnapshot -eq $currentSnapshot')
        $resetIndex | Should -BeGreaterThan (-1)
        $snapshotIndex | Should -BeGreaterThan $resetIndex
    }

    It 'sets a 30 second backoff and keeps the visible drive error in the catch' {
        $driveCatch = $script:updateDriveList.Find({
                param($node)
                $node -is [System.Management.Automation.Language.CatchClauseAst]
            }, $true)
        $driveCatch | Should -Not -BeNullOrEmpty
        $driveCatch.Extent.Text | Should -Match ([regex]::Escape('[DateTime]::UtcNow.AddSeconds(30)'))
        $driveCatch.Extent.Text | Should -Match ([regex]::Escape('$driveInfoLabel.Text'))
    }

    It 'invalidates both drive snapshots after discovery failure' {
        $driveCatch = $script:updateDriveList.Find({
                param($node)
                $node -is [System.Management.Automation.Language.CatchClauseAst]
            }, $true)
        $driveCatch | Should -Not -BeNullOrEmpty
        $driveCatch.Extent.Text | Should -Match ([regex]::Escape('$script:driveSnapshot = $null'))
        $driveCatch.Extent.Text | Should -Match ([regex]::Escape("`$script:driveLogicalSnapshot = ''"))
    }

    It 'uses expandable strings for line breaks in the mutex failure dialog' {
        $script:guiText | Should -Match 'L\s+"Die Einzelinstanz-Sperre[^\r\n]+`r`n\{0\}"\s+"The single-instance guard[^\r\n]+`r`n\{0\}"'
        $script:guiText | Should -Not -Match "L\s+'Die Einzelinstanz-Sperre[^']*`r`n"
    }

    It 'passes exact GUI ownership and the Verify policy to restore workers' {
        $script:launchTryText | Should -Match ([regex]::Escape("'-ParentProcessStartTimeUtcTicks'"))
        $script:launchTryText | Should -Match ([regex]::Escape("@('-RestoreIntegrityPolicy', 'Verify')"))
    }

    It 'uses distinct restore approval values while retaining scan-warning continue' {
        $script:guiText | Should -Match 'continue-verified'
        $script:guiText | Should -Match 'verify-then-continue'
        $script:guiText | Should -Match 'continue-unverified'
        $script:guiText | Should -Match "SCANWARNUNG[\s\S]+-Value 'continue'"
    }

    It 'acquires and releases the per-user GUI mutex' {
        $script:guiText | Should -Match 'Enter-M24SingleInstance'
        $script:guiText | Should -Match 'Get-M24GuiMutexName'
        $script:guiText | Should -Match 'Exit-M24SingleInstance'
    }

    It 'branches SilentStartup before loading WinForms or constructing the splash' {
        $silentBranch = $script:guiAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -eq '$SilentStartup'
            }, $true)
        $silentBranch | Should -Not -BeNullOrEmpty
        $silentIndex = $script:guiText.IndexOf('if ($SilentStartup)')
        $firstAddTypeIndex = $script:guiText.IndexOf('Add-Type -AssemblyName System.Windows.Forms')
        $silentIndex | Should -BeGreaterThan (-1)
        $firstAddTypeIndex | Should -BeGreaterThan $silentIndex
        $silentBranch.Extent.Text | Should -Match 'Get-M24BackupReminderState'
        $silentBranch.Extent.Text | Should -Match '\[int\]::TryParse'
        $silentBranch.Extent.Text | Should -Match 'ShowBalloonTip'
        $silentBranch.Extent.Text | Should -Match 'BalloonTipClicked'
        $silentBranch.Extent.Text | Should -Not -Match 'MessageBox'
        $silentBranch.Extent.Text | Should -Not -Match 'Update-DriveList'
        $fontProbeIndex = $script:guiText.IndexOf('$installedFontNames =')
        $fontProbeIndex | Should -BeGreaterThan $silentBranch.Extent.EndOffset
    }

    It 'shows the splash only for measurably slow starts and closes it before ShowDialog' {
        # Der Splash entsteht verzoegert in Set-StartupSplashStatus, ist nie
        # TopMost und wird ohne kuenstliche Wartezeit vor ShowDialog
        # geschlossen (plan.md Arbeitspaket 7).
        $script:guiText | Should -Match ([regex]::Escape('$script:startupStopwatch.ElapsedMilliseconds -lt $script:splashDelayMilliseconds'))
        $script:guiText | Should -Match 'Close-StartupSplash\s+\[void\]\$form\.ShowDialog'
        $script:guiText | Should -Not -Match 'Complete-StartupSplash'
        $script:guiText | Should -Not -Match 'Start-Sleep -Milliseconds 300'
        $script:guiText | Should -Not -Match '\$splash\w*\.TopMost\s*=\s*\$true'
        $script:guiText | Should -Match ([regex]::Escape('$splashLogoBox.Size = New-Object System.Drawing.Size(112, 112)'))
    }

    It 'persists reminder settings and successful GUI backup time' {
        foreach ($field in @('LastSuccessfulBackup', 'ReminderEnabled', 'ReminderDays')) {
            $script:guiText | Should -Match $field
        }
        $script:guiText | Should -Match ([regex]::Escape("`$script:settings.LastSuccessfulBackup = (Get-Date).ToString('o')"))
        $script:guiText | Should -Match 'GUI\.ReminderSelfHeal'
    }

    It 'presents the reminder as a persistent setting separate from operation options' {
        # Die Erinnerung ist eine dauerhafte Anwendungs-Einstellung und steht
        # in einer eigenen beschrifteten Zeile unterhalb der Vorgangsoptionen
        # (plan.md Arbeitspaket 5).
        $script:guiText | Should -Match '\$reminderCheckBox = New-M24OptionCheckBox'
        $script:guiText | Should -Match ([regex]::Escape("L 'Beim Windows-Login an fällige Sicherungen erinnern' 'Remind me at Windows sign-in when a backup is due'"))
        $script:guiText | Should -Match ([regex]::Escape("L 'Einstellung:' 'Setting:'"))
        $script:guiText | Should -Match ([regex]::Escape('$optionsSurface.Controls.Add($reminderCheckBox, 1, 1)'))
    }

    It 'uses wrapping layouts for options and footer commands' {
        $script:guiText | Should -Match ([regex]::Escape('$contentHost.AutoScroll = $false'))
        $script:guiText | Should -Match ([regex]::Escape('$layoutRoot.AutoSize = $false'))
        $script:guiText | Should -Match 'function Update-ContentLayoutHeight'
        $script:guiText | Should -Match ([regex]::Escape('$rowHeights = @($layoutRoot.GetRowHeights())'))
        $script:guiText | Should -Match ([regex]::Escape('$minimumContentHeight = [int]($currentTotalHeight - $rowHeights[2] + $folderMinimumRowHeight)'))
        $script:guiText | Should -Match ([regex]::Escape('$folderMinimumHeight = [int][math]::Round(156 * $scaleFactor)'))
        $script:guiText | Should -Not -Match '\$headerPanel\.GetPreferredSize'
        $script:guiText | Should -Not -Match '\$targetSurface\.GetPreferredSize'
        $script:guiText | Should -Match ([regex]::Escape('$contentHost.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)'))
        $script:guiText | Should -Match ([regex]::Escape('$targetSurface = New-Object System.Windows.Forms.TableLayoutPanel'))
        $script:guiText | Should -Match ([regex]::Escape('$operationOptionsFlow.WrapContents = $true'))
        $script:guiText | Should -Match ([regex]::Escape('$optionsSurface.AutoSize = $false'))
        $script:guiText | Should -Match ([regex]::Escape('$folderSurface.MinimumSize = New-Object System.Drawing.Size(0, 156)'))
        $script:guiText | Should -Match ([regex]::Escape("`$deleteBackupButton = New-M24Button -Text (L 'Backup löschen' 'Delete backup') -Width 184"))
        $script:guiText | Should -Match 'function Update-OptionsSurfaceHeight'
        $script:guiText | Should -Match ([regex]::Escape('$optionsSurface.Add_Resize({ Update-OptionsSurfaceHeight })'))
        $script:guiText | Should -Match ([regex]::Escape('$footerSurface = New-Object System.Windows.Forms.FlowLayoutPanel'))
        $script:guiText | Should -Match ([regex]::Escape('$footerSurface.WrapContents = $true'))
        $script:guiText | Should -Match ([regex]::Escape('$form.Controls.Add($footerSurface)'))
        # Das Fill-gedockte Inhalts-Panel muss zuletzt gedockt werden, damit
        # der Footer den Inhalt nicht verdeckt.
        $script:guiText | Should -Match ([regex]::Escape('$contentHost.BringToFront()'))
        $script:guiText | Should -Match 'function Update-ActivitySurfaceLayout'
        $script:guiText | Should -Match ([regex]::Escape('$activitySurface.Add_Resize({ Update-ActivitySurfaceLayout })'))
        $script:guiText | Should -Not -Match ([regex]::Escape('$footerSurface.BringToFront()'))
        $script:guiText | Should -Not -Match ([regex]::Escape('$closeButton.Location = New-Object System.Drawing.Point(621, 16)'))
    }

    It 'enables reminders by default and migrates the original seven-day default to fourteen days' {
        $script:guiText | Should -Match 'Version = 4;.*ReminderEnabled = \$true; ReminderDays = 14'
        $script:guiText | Should -Match '\$migrateReminderDefaults = \$parsedVersion -lt 4'
        $script:guiText | Should -Match '\$parsedDays -eq 7\) \{ 14 \}'
        $script:guiText | Should -Match 'GUI\.ReminderMigration'
    }

    It 'collects layered identity and refuses ambiguous automatic matches' {
        $script:updateDriveListText | Should -Match 'M24VolumeGuid'
        $script:updateDriveListText | Should -Match 'M24DiskUniqueId'
        $script:updateDriveListText | Should -Match 'knownCandidates\.Count -eq 1'
        $script:updateDriveListText | Should -Match 'M24KnownMatchAmbiguous'
    }
}

Describe 'Dual-runtime CI process cleanup contract' {
    It 'checks command-line-marked Pester children after both runtime runs' {
        $workflow = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) '.github\workflows\powershell.yml') -Raw
        ([regex]::Matches($workflow, 'Check test child cleanup \(')).Count | Should -Be 2
        ([regex]::Matches($workflow, [regex]::Escape("CommandLine -match 'M24Backup\.PesterChild'"))).Count | Should -Be 2
        $workflow | Should -Match '\$_.ProcessId -ne \$PID'
        $testSource = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'tests\M24Backup.Shared.Tests.ps1') -Raw
        ([regex]::Matches($testSource, 'M24Backup\.PesterChild')).Count | Should -BeGreaterOrEqual 2
    }
}

Describe 'Reminder launcher and installer contract' {
    It 'forwards only the recognized silent-startup switch through VBS' {
        $vbs = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Bibliothekssicherung starten.vbs') -Raw
        $vbs | Should -Match 'For Each argument In WScript\.Arguments'
        $vbs | Should -Match '/silentstartup'
        $vbs | Should -Match 'command = command & " -SilentStartup"'
    }

    It 'removes the per-user Run value during uninstall without creating it at install time' {
        $installer = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'installer\Bibliothekssicherung.iss') -Raw
        $installer | Should -Match '\[Registry\]'
        $installer | Should -Match 'ValueName: "M24Backup"'
        $installer | Should -Match 'Flags: uninsdeletevalue dontcreatekey'
    }
}
