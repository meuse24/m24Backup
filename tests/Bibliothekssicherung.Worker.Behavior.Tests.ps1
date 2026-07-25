# Verhaltenstests fuer den Sicherungs-Worker.
#
# Im Gegensatz zu den Vertragstests in Bibliothekssicherung.Worker.Tests.ps1
# pruefen diese Tests keine Quelltextmuster, sondern beobachtbares Verhalten:
# Der Worker laeuft als echter Windows-PowerShell-Prozess gegen ein per subst
# erzeugtes Ziellaufwerk und wird ueber seine Artefakte bewertet (kopierte
# Dateien, Metadaten, Manifest, Ergebnisdatei, Statusdatei, Exitcode).
#
# Damit sind die Tests unabhaengig von der inneren Struktur des Workers und
# ueberleben eine Aufteilung des Skripts in Funktionen.
#
# Voraussetzungen: Windows, subst.exe, robocopy.exe.
# Die Tests fassen ausschliesslich eigene Testordner an; die echten
# Bibliotheksordner des Benutzers werden ueber -SelectedFoldersFile
# ausgeschlossen.

BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:repoRoot 'M24Backup.Shared.ps1')
    $script:workerScript = Join-Path $script:repoRoot 'Bibliothekssicherung.ps1'
    $script:windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    # --- Testlaufwerk -----------------------------------------------------

    function New-TestBackupDrive {
        # Legt ein virtuelles Laufwerk auf einem realen Verzeichnis an.
        # Ein subst-Laufwerk erscheint in Win32_LogicalDisk mit korrektem
        # FreeSpace und ist damit ein vollwertiges Sicherungsziel.
        param([Parameter(Mandatory = $true)][string]$BackingFolder)

        New-Item -ItemType Directory -Path $BackingFolder -Force | Out-Null
        $used = @((Get-PSDrive -PSProvider FileSystem).Name)
        # Von hinten waehlen: Z, Y, X ... kollidieren am seltensten.
        $letter = @(90..68 | ForEach-Object { [char]$_ } | Where-Object { $used -notcontains "$_" }) |
            Select-Object -First 1
        if (-not $letter) { throw 'Kein freier Laufwerksbuchstabe fuer den Test verfuegbar.' }

        $result = & subst "${letter}:" $BackingFolder 2>&1
        if ($LASTEXITCODE -ne 0) { throw "subst fehlgeschlagen: $result" }

        # Der Bereitstellungsvorgang ist asynchron; kurz auf Sichtbarkeit warten.
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath "${letter}:\") { break }
            Start-Sleep -Milliseconds 100
        }
        if (-not (Test-Path -LiteralPath "${letter}:\")) {
            & subst "${letter}:" /D 2>&1 | Out-Null
            throw "Das Testlaufwerk ${letter}: wurde nicht bereitgestellt."
        }
        return "${letter}:"
    }

    function Remove-TestBackupDrive {
        param([string]$Drive)
        if (-not $Drive) { return }
        & subst $Drive /D 2>&1 | Out-Null
    }

    # --- Testdaten --------------------------------------------------------

    function New-TestSourceTree {
        # Erzeugt einen kleinen, deterministischen Quellbaum mit Unterordner.
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [int]$FileCount = 3
        )
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        $subFolder = Join-Path $Path 'Unterordner'
        New-Item -ItemType Directory -Path $subFolder -Force | Out-Null
        for ($i = 1; $i -le $FileCount; $i++) {
            Set-Content -LiteralPath (Join-Path $Path "datei$i.txt") -Value "Inhalt $i" -Encoding UTF8
        }
        Set-Content -LiteralPath (Join-Path $subFolder 'tief.txt') -Value 'Tiefer Inhalt' -Encoding UTF8
        return $Path
    }

    function New-SelectionFile {
        # Schreibt die Auswahldatei des Workers. Ein einzelner Eintrag muss
        # trotzdem als JSON-Array ankommen, sonst liest der Worker kein Array.
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][hashtable[]]$Folders
        )
        $specs = @($Folders | ForEach-Object {
            [pscustomobject]@{
                Name     = [string]$_.Name
                Path     = [string]$_.Path
                IsCustom = $true
            }
        })
        $json = ConvertTo-Json -InputObject $specs -Depth 4
        if ($specs.Count -eq 1 -and -not $json.TrimStart().StartsWith('[')) {
            $json = "[$json]"
        }
        Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
        return $Path
    }

    # --- Worker-Aufruf ----------------------------------------------------

    function Invoke-Worker {
        param(
            [string[]]$WorkerArguments,
            [int]$TimeoutSeconds = 240
        )
        $stdOutFile = [System.IO.Path]::GetTempFileName()
        $stdErrFile = [System.IO.Path]::GetTempFileName()
        try {
            $allArguments = @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $script:workerScript
            ) + $WorkerArguments

            $process = Start-Process -FilePath $script:windowsPowerShell -ArgumentList $allArguments `
                -NoNewWindow -PassThru -RedirectStandardOutput $stdOutFile -RedirectStandardError $stdErrFile

            # Das Prozesshandle muss angefasst werden, solange der Prozess
            # laeuft. Sonst verwirft .NET beim Beenden den Exitcode und
            # $process.ExitCode bleibt unter Windows PowerShell 5.1 leer.
            $null = $process.Handle

            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                try { $process.Kill() } catch {}
                throw "Der Worker hat das Zeitlimit von $TimeoutSeconds s ueberschritten."
            }
            # WaitForExit(int) garantiert nicht, dass die umgeleiteten Streams
            # vollstaendig geschrieben sind; der parameterlose Aufruf schon.
            $process.WaitForExit()

            $stdOut = if (Test-Path -LiteralPath $stdOutFile) { Get-Content -LiteralPath $stdOutFile -Raw } else { '' }
            $stdErr = if (Test-Path -LiteralPath $stdErrFile) { Get-Content -LiteralPath $stdErrFile -Raw } else { '' }
            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                Output   = "$stdOut`n$stdErr"
            }
        } finally {
            Remove-Item -LiteralPath $stdOutFile, $stdErrFile -Force -ErrorAction SilentlyContinue
        }
    }

    function Get-ResultRecord {
        param([string]$Path)
        Test-Path -LiteralPath $Path | Should -BeTrue -Because "der Worker muss die Ergebnisdatei '$Path' schreiben"
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
}

Describe 'Worker backup end to end' {
    BeforeAll {
        $script:workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("m24-backup-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:backingFolder = Join-Path $script:workRoot 'ziel'
        $script:testDrive = New-TestBackupDrive -BackingFolder $script:backingFolder
        $script:backupRoot = Get-M24BackupRoot -Drive $script:testDrive

        $script:sourceFolder = New-TestSourceTree -Path (Join-Path $script:workRoot 'quelle')
        $script:selectionFile = New-SelectionFile -Path (Join-Path $script:workRoot 'auswahl.json') `
            -Folders @(@{ Name = 'M24TestOrdner'; Path = $script:sourceFolder })
    }

    AfterAll {
        Remove-TestBackupDrive -Drive $script:testDrive
        Remove-Item -LiteralPath $script:workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'copies the selected folder with its subtree and writes every artifact' {
        $resultFile = Join-Path $script:workRoot 'result-1.json'
        $result = Invoke-Worker @(
            '-Mode', 'Backup', '-UsbDrive', $script:testDrive, '-Silent',
            '-SelectedFoldersFile', $script:selectionFile, '-ResultFile', $resultFile
        )

        $result.ExitCode | Should -Be 0 -Because "der Lauf muss erfolgreich sein. Ausgabe:`n$($result.Output)"

        $targetFolder = Join-Path $script:backupRoot 'M24TestOrdner'
        Test-Path -LiteralPath (Join-Path $targetFolder 'datei1.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $targetFolder 'Unterordner\tief.txt') | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $targetFolder 'datei1.txt') -Raw | Should -Match 'Inhalt 1'

        # Metadaten, Manifest und Protokoll gehoeren zum Erfolgsvertrag.
        $metadataFile = Join-Path $script:backupRoot '_Sicherungsinfo.txt'
        Test-Path -LiteralPath $metadataFile | Should -BeTrue
        $metadata = @(Get-Content -LiteralPath $metadataFile)
        ($metadata -join "`n") | Should -Match ([regex]::Escape($env:COMPUTERNAME))
        ($metadata -join "`n") | Should -Match ([regex]::Escape($env:USERNAME))
        (Get-M24BackupResultInfo -Lines $metadata).IsComplete | Should -BeTrue

        Test-Path -LiteralPath (Join-Path $script:backupRoot (Get-M24ChecksumManifestName)) | Should -BeTrue
        @(Get-ChildItem -LiteralPath (Join-Path $script:backupRoot '_logs') -Filter 'robocopy_*.log').Count |
            Should -BeGreaterThan 0

        $record = Get-ResultRecord -Path $resultFile
        $record.Success | Should -BeTrue
        $record.Cancelled | Should -BeFalse
        $record.Mode | Should -Be 'Backup'
        @($record.SelectedFolders) | Should -Contain 'M24TestOrdner'
        @($record.SuccessfulFolders) | Should -Contain 'M24TestOrdner'
        @($record.FailedFolders).Count | Should -Be 0
        $record.ScannedFiles | Should -BeGreaterThan 0
        $record.ChecksumFiles | Should -BeGreaterThan 0
    }

    It 'records the custom folder origin so a later restore can find it' {
        $folderMetadata = Join-Path $script:backupRoot '_Ordner.json'
        Test-Path -LiteralPath $folderMetadata | Should -BeTrue
        $entries = @(Get-Content -LiteralPath $folderMetadata -Raw | ConvertFrom-Json)
        $entry = $entries | Where-Object { $_.Name -eq 'M24TestOrdner' }
        $entry | Should -Not -BeNullOrEmpty
        $entry.OriginalPath | Should -Be $script:sourceFolder
    }

    It 'reuses existing checksums on an unchanged second run' {
        $resultFile = Join-Path $script:workRoot 'result-2.json'
        $result = Invoke-Worker @(
            '-Mode', 'Backup', '-UsbDrive', $script:testDrive, '-Silent',
            '-SelectedFoldersFile', $script:selectionFile, '-ResultFile', $resultFile
        )
        $result.ExitCode | Should -Be 0 -Because "Ausgabe:`n$($result.Output)"

        $record = Get-ResultRecord -Path $resultFile
        $record.ReusedChecksums | Should -BeGreaterThan 0
        $record.HashedFiles | Should -Be 0 -Because 'unveraenderte Dateien duerfen nicht erneut gehasht werden'
    }

    It 'never deletes at the destination when a source file disappears' {
        # Additive Sicherung: Das Loeschen in der Quelle darf die vorhandene
        # Sicherungskopie nicht entfernen.
        $removedSource = Join-Path $script:sourceFolder 'datei3.txt'
        $removedTarget = Join-Path $script:backupRoot 'M24TestOrdner\datei3.txt'
        Test-Path -LiteralPath $removedTarget | Should -BeTrue
        Remove-Item -LiteralPath $removedSource -Force

        $resultFile = Join-Path $script:workRoot 'result-3.json'
        $result = Invoke-Worker @(
            '-Mode', 'Backup', '-UsbDrive', $script:testDrive, '-Silent',
            '-SelectedFoldersFile', $script:selectionFile, '-ResultFile', $resultFile
        )
        $result.ExitCode | Should -Be 0 -Because "Ausgabe:`n$($result.Output)"
        Test-Path -LiteralPath $removedTarget | Should -BeTrue -Because 'die Sicherung ist additiv und loescht am Ziel nichts'
    }

    It 'replaces a changed source file even when its timestamp is older' {
        # Beim Backup gewinnt die Quelle; /XO gilt bewusst nur beim Restore.
        $changedSource = Join-Path $script:sourceFolder 'datei1.txt'
        Set-Content -LiteralPath $changedSource -Value 'Geaenderter Inhalt' -Encoding UTF8
        [System.IO.File]::SetLastWriteTime($changedSource, (Get-Date).AddDays(-30))

        $resultFile = Join-Path $script:workRoot 'result-4.json'
        $result = Invoke-Worker @(
            '-Mode', 'Backup', '-UsbDrive', $script:testDrive, '-Silent',
            '-SelectedFoldersFile', $script:selectionFile, '-ResultFile', $resultFile
        )
        $result.ExitCode | Should -Be 0 -Because "Ausgabe:`n$($result.Output)"

        Get-Content -LiteralPath (Join-Path $script:backupRoot 'M24TestOrdner\datei1.txt') -Raw |
            Should -Match 'Geaenderter Inhalt'
    }

    It 'writes the status protocol for the user interface' {
        $statusFile = Join-Path $script:workRoot 'status.txt'
        $resultFile = Join-Path $script:workRoot 'result-5.json'
        $result = Invoke-Worker @(
            '-Mode', 'Backup', '-UsbDrive', $script:testDrive, '-Silent',
            '-SelectedFoldersFile', $script:selectionFile,
            '-StatusFile', $statusFile, '-ResultFile', $resultFile
        )
        $result.ExitCode | Should -Be 0 -Because "Ausgabe:`n$($result.Output)"

        Test-Path -LiteralPath $statusFile | Should -BeTrue
        # Die Statusdatei traegt immer den zuletzt geschriebenen Eintrag im
        # Format <TYP>|<Text>. Am Ende eines erfolgreichen Laufs ist das FERTIG.
        $status = (Get-Content -LiteralPath $statusFile -Raw).Trim()
        $status | Should -Match '^FERTIG\|'
    }
}

Describe 'Worker backup modes' {
    BeforeAll {
        $script:modeWorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("m24-mode-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:modeBacking = Join-Path $script:modeWorkRoot 'ziel'
        $script:modeDrive = New-TestBackupDrive -BackingFolder $script:modeBacking
        $script:modeBackupRoot = Get-M24BackupRoot -Drive $script:modeDrive
        $script:modeSource = New-TestSourceTree -Path (Join-Path $script:modeWorkRoot 'quelle')
        $script:modeSelection = New-SelectionFile -Path (Join-Path $script:modeWorkRoot 'auswahl.json') `
            -Folders @(@{ Name = 'M24TestOrdner'; Path = $script:modeSource })
    }

    AfterAll {
        Remove-TestBackupDrive -Drive $script:modeDrive
        Remove-Item -LiteralPath $script:modeWorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'copies no payload and writes no metadata in dry run mode' {
        $resultFile = Join-Path $script:modeWorkRoot 'dry.json'
        $result = Invoke-Worker @(
            '-Mode', 'Backup', '-UsbDrive', $script:modeDrive, '-Silent', '-DryRun',
            '-SelectedFoldersFile', $script:modeSelection, '-ResultFile', $resultFile
        )
        $result.ExitCode | Should -Be 0 -Because "Ausgabe:`n$($result.Output)"

        Test-Path -LiteralPath (Join-Path $script:modeBackupRoot 'M24TestOrdner\datei1.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:modeBackupRoot '_Sicherungsinfo.txt') | Should -BeFalse

        $record = Get-ResultRecord -Path $resultFile
        $record.Success | Should -BeTrue
        $record.DryRun | Should -BeTrue
        # Die Vorpruefung laeuft auch im Dry-Run und liefert echte Zahlen.
        $record.ScannedFiles | Should -BeGreaterThan 0
    }

    It 'skips preflight, checksums and estimates in super fast mode' {
        $resultFile = Join-Path $script:modeWorkRoot 'fast.json'
        $result = Invoke-Worker @(
            '-Mode', 'Backup', '-UsbDrive', $script:modeDrive, '-Silent', '-SuperFast',
            '-SelectedFoldersFile', $script:modeSelection, '-ResultFile', $resultFile
        )
        $result.ExitCode | Should -Be 0 -Because "Ausgabe:`n$($result.Output)"

        # Kopiert wird trotzdem vollstaendig.
        Test-Path -LiteralPath (Join-Path $script:modeBackupRoot 'M24TestOrdner\datei1.txt') | Should -BeTrue
        # Aber ohne Pruefsummenmanifest.
        Test-Path -LiteralPath (Join-Path $script:modeBackupRoot (Get-M24ChecksumManifestName)) | Should -BeFalse

        $record = Get-ResultRecord -Path $resultFile
        $record.SuperFast | Should -BeTrue
        $record.PreflightSkipped | Should -BeTrue
        $record.ChecksumSkipped | Should -BeTrue
        # "nicht ermittelt" muss null bleiben und darf nicht als 0 erscheinen.
        $record.ScannedFiles | Should -BeNullOrEmpty
        $record.PlannedFiles | Should -BeNullOrEmpty
        $record.PlannedBytes | Should -BeNullOrEmpty
    }
}

Describe 'Worker restore' {
    BeforeAll {
        $script:restoreWorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("m24-restore-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:restoreBacking = Join-Path $script:restoreWorkRoot 'ziel'
        $script:restoreDrive = New-TestBackupDrive -BackingFolder $script:restoreBacking
        $script:restoreBackupRoot = Get-M24BackupRoot -Drive $script:restoreDrive
        $script:restoreSource = New-TestSourceTree -Path (Join-Path $script:restoreWorkRoot 'quelle')
        $script:restoreSelection = New-SelectionFile -Path (Join-Path $script:restoreWorkRoot 'auswahl.json') `
            -Folders @(@{ Name = 'M24TestOrdner'; Path = $script:restoreSource })

        # Eine vollstaendige Sicherung als Ausgangspunkt fuer alle Restore-Tests.
        $prepare = Invoke-Worker @(
            '-Mode', 'Backup', '-UsbDrive', $script:restoreDrive, '-Silent',
            '-SelectedFoldersFile', $script:restoreSelection,
            '-ResultFile', (Join-Path $script:restoreWorkRoot 'prepare.json')
        )
        if ($prepare.ExitCode -ne 0) {
            throw "Die vorbereitende Sicherung ist fehlgeschlagen (Exit $($prepare.ExitCode)):`n$($prepare.Output)"
        }
    }

    AfterAll {
        Remove-TestBackupDrive -Drive $script:restoreDrive
        Remove-Item -LiteralPath $script:restoreWorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'restores into a separate destination folder after approval' {
        # Das Ziel liegt bewusst auf dem Testlaufwerk: Pfade unterhalb von
        # %LOCALAPPDATA% (und damit auch %TEMP%) lehnt der Worker als
        # geschuetzten Profilbereich ab.
        $targetRoot = Join-Path $script:restoreDrive 'Wiederhergestellt'
        New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null

        # Die Freigabedatei liegt bereits vor; der Worker liest sie sofort.
        $approvalFile = Join-Path $script:restoreWorkRoot 'approval.txt'
        Set-Content -LiteralPath $approvalFile -Value 'continue' -Encoding ASCII
        $previewFile = Join-Path $script:restoreWorkRoot 'preview.json'
        $resultFile = Join-Path $script:restoreWorkRoot 'restore.json'

        $result = Invoke-Worker @(
            '-Mode', 'Restore', '-UsbDrive', $script:restoreDrive, '-Silent',
            '-RestoreTargetMode', 'Folder', '-RestoreTargetRoot', $targetRoot,
            '-PreviewFile', $previewFile, '-ApprovalFile', $approvalFile,
            '-ResultFile', $resultFile
        )
        $result.ExitCode | Should -Be 0 -Because "Ausgabe:`n$($result.Output)"

        $backupName = Split-Path $script:restoreBackupRoot -Leaf
        $restoredFolder = Join-Path $targetRoot (Join-Path $backupName 'M24TestOrdner')
        Test-Path -LiteralPath (Join-Path $restoredFolder 'datei1.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $restoredFolder 'Unterordner\tief.txt') | Should -BeTrue

        $record = Get-ResultRecord -Path $resultFile
        $record.Success | Should -BeTrue
        $record.Mode | Should -Be 'Restore'
        $record.RestoreTargetMode | Should -Be 'Folder'
    }

    It 'writes a restore preview before asking for approval' {
        $targetRoot = Join-Path $script:restoreDrive 'Wiederhergestellt2'
        New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
        $approvalFile = Join-Path $script:restoreWorkRoot 'approval2.txt'
        Set-Content -LiteralPath $approvalFile -Value 'continue' -Encoding ASCII
        $previewFile = Join-Path $script:restoreWorkRoot 'preview2.json'

        $result = Invoke-Worker @(
            '-Mode', 'Restore', '-UsbDrive', $script:restoreDrive, '-Silent',
            '-RestoreTargetMode', 'Folder', '-RestoreTargetRoot', $targetRoot,
            '-PreviewFile', $previewFile, '-ApprovalFile', $approvalFile,
            '-ResultFile', (Join-Path $script:restoreWorkRoot 'restore2.json')
        )
        $result.ExitCode | Should -Be 0 -Because "Ausgabe:`n$($result.Output)"

        Test-Path -LiteralPath $previewFile | Should -BeTrue
        $preview = Get-Content -LiteralPath $previewFile -Raw | ConvertFrom-Json
        $preview.TargetMode | Should -Be 'Folder'
        $preview.SourceComputer | Should -Be $env:COMPUTERNAME
        $preview.SourceUser | Should -Be $env:USERNAME
        $preview.PlannedFiles | Should -BeGreaterThan 0
        @($preview.FolderMappings).Name | Should -Contain 'M24TestOrdner'
    }

    It 'refuses a restore into a folder without a destination root' {
        $result = Invoke-Worker @(
            '-Mode', 'Restore', '-UsbDrive', $script:restoreDrive, '-Silent',
            '-RestoreTargetMode', 'Folder',
            '-ApprovalFile', (Join-Path $script:restoreWorkRoot 'approval.txt')
        )
        $result.ExitCode | Should -Be 10
        $result.Output | Should -Match 'Zielordner|destination folder'
    }

    It 'refuses a silent restore without an approval file' {
        $targetRoot = Join-Path $script:restoreDrive 'Wiederhergestellt3'
        New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
        $result = Invoke-Worker @(
            '-Mode', 'Restore', '-UsbDrive', $script:restoreDrive, '-Silent',
            '-RestoreTargetMode', 'Folder', '-RestoreTargetRoot', $targetRoot
        )
        $result.ExitCode | Should -Be 10
        $result.Output | Should -Match 'Freigabedatei|approval file'
    }

    It 'refuses a restore destination inside a protected profile location' {
        # %TEMP% liegt unterhalb von %LOCALAPPDATA% und ist deshalb gesperrt.
        $approvalFile = Join-Path $script:restoreWorkRoot 'approval-protected.txt'
        Set-Content -LiteralPath $approvalFile -Value 'continue' -Encoding ASCII
        $result = Invoke-Worker @(
            '-Mode', 'Restore', '-UsbDrive', $script:restoreDrive, '-Silent',
            '-RestoreTargetMode', 'Folder', '-RestoreTargetRoot', $env:LOCALAPPDATA,
            '-ApprovalFile', $approvalFile
        )
        $result.ExitCode | Should -Be 10
        $result.Output | Should -Match 'geschuetzten System- oder Profilbereich|protected system or profile location'
    }

    It 'refuses a restore destination that overlaps the backup source' {
        $approvalFile = Join-Path $script:restoreWorkRoot 'approval-overlap.txt'
        Set-Content -LiteralPath $approvalFile -Value 'continue' -Encoding ASCII
        $result = Invoke-Worker @(
            '-Mode', 'Restore', '-UsbDrive', $script:restoreDrive, '-Silent',
            '-RestoreTargetMode', 'Folder', '-RestoreTargetRoot', $script:restoreBackupRoot,
            '-ApprovalFile', $approvalFile
        )
        $result.ExitCode | Should -Be 10
        $result.Output | Should -Match 'ineinander liegen|must not overlap'
    }
}

Describe 'Worker cancellation and locking' {
    BeforeAll {
        $script:cancelWorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("m24-cancel-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:cancelBacking = Join-Path $script:cancelWorkRoot 'ziel'
        $script:cancelDrive = New-TestBackupDrive -BackingFolder $script:cancelBacking
        $script:cancelBackupRoot = Get-M24BackupRoot -Drive $script:cancelDrive
        $script:cancelSource = New-TestSourceTree -Path (Join-Path $script:cancelWorkRoot 'quelle')
        $script:cancelSelection = New-SelectionFile -Path (Join-Path $script:cancelWorkRoot 'auswahl.json') `
            -Folders @(@{ Name = 'M24TestOrdner'; Path = $script:cancelSource })
    }

    AfterAll {
        Remove-TestBackupDrive -Drive $script:cancelDrive
        Remove-Item -LiteralPath $script:cancelWorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'stops with the cancellation exit code when the cancel marker exists' {
        $cancelFile = Join-Path $script:cancelWorkRoot 'cancel.txt'
        Set-Content -LiteralPath $cancelFile -Value 'cancel' -Encoding ASCII
        $resultFile = Join-Path $script:cancelWorkRoot 'cancel-result.json'
        $statusFile = Join-Path $script:cancelWorkRoot 'cancel-status.txt'

        $result = Invoke-Worker @(
            '-Mode', 'Backup', '-UsbDrive', $script:cancelDrive, '-Silent',
            '-SelectedFoldersFile', $script:cancelSelection,
            '-CancelFile', $cancelFile, '-StatusFile', $statusFile, '-ResultFile', $resultFile
        )

        $result.ExitCode | Should -Be 20 -Because "Abbrueche verwenden einen eigenen Exitcode. Ausgabe:`n$($result.Output)"

        $record = Get-ResultRecord -Path $resultFile
        $record.Cancelled | Should -BeTrue
        $record.Success | Should -BeFalse
        $record.CancellationReason | Should -Be 'User'

        (Get-Content -LiteralPath $statusFile -Raw).Trim() | Should -Match '^ABGEBROCHEN\|'
        Remove-Item -LiteralPath $cancelFile -Force
    }

    It 'refuses a second operation while the destination lock is held' {
        # Zuerst eine gueltige Sicherung, damit das Zielverzeichnis existiert.
        $prepare = Invoke-Worker @(
            '-Mode', 'Backup', '-UsbDrive', $script:cancelDrive, '-Silent',
            '-SelectedFoldersFile', $script:cancelSelection,
            '-ResultFile', (Join-Path $script:cancelWorkRoot 'lock-prepare.json')
        )
        $prepare.ExitCode | Should -Be 0 -Because "Ausgabe:`n$($prepare.Output)"

        $lockFile = Join-Path $script:cancelBackupRoot '_backup.lock'
        $stream = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $result = Invoke-Worker @(
                '-Mode', 'Backup', '-UsbDrive', $script:cancelDrive, '-Silent',
                '-SelectedFoldersFile', $script:cancelSelection,
                '-ResultFile', (Join-Path $script:cancelWorkRoot 'lock-result.json')
            )
            $result.ExitCode | Should -Be 10
            $result.Output | Should -Match 'bereits ein anderer|already running'
        } finally {
            $stream.Dispose()
            Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
        }
    }

    It 'releases the destination lock after a successful run' {
        $result = Invoke-Worker @(
            '-Mode', 'Backup', '-UsbDrive', $script:cancelDrive, '-Silent',
            '-SelectedFoldersFile', $script:cancelSelection,
            '-ResultFile', (Join-Path $script:cancelWorkRoot 'unlock.json')
        )
        $result.ExitCode | Should -Be 0 -Because "Ausgabe:`n$($result.Output)"
        Test-Path -LiteralPath (Join-Path $script:cancelBackupRoot '_backup.lock') | Should -BeFalse
    }
}

Describe 'Worker input validation' {
    BeforeAll {
        $script:validationWorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("m24-valid-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:validationBacking = Join-Path $script:validationWorkRoot 'ziel'
        $script:validationDrive = New-TestBackupDrive -BackingFolder $script:validationBacking
        $script:validationSource = New-TestSourceTree -Path (Join-Path $script:validationWorkRoot 'quelle')
    }

    AfterAll {
        Remove-TestBackupDrive -Drive $script:validationDrive
        Remove-Item -LiteralPath $script:validationWorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'refuses the system drive as a backup destination' {
        $result = Invoke-Worker @('-Mode', 'Backup', '-UsbDrive', $env:SystemDrive, '-Silent')
        $result.ExitCode | Should -Be 10
        $result.Output | Should -Match 'Systemlaufwerk|system drive'
    }

    It 'refuses a malformed drive specification' {
        $result = Invoke-Worker @('-Mode', 'Backup', '-UsbDrive', 'nicht-ein-laufwerk', '-Silent')
        $result.ExitCode | Should -Be 10
        $result.Output | Should -Match 'Ungueltiges Ziellaufwerk|Invalid drive'
    }

    It 'refuses a reserved folder name for a custom folder' {
        $selection = New-SelectionFile -Path (Join-Path $script:validationWorkRoot 'reserved.json') `
            -Folders @(@{ Name = '_logs'; Path = $script:validationSource })
        $result = Invoke-Worker @(
            '-Mode', 'Backup', '-UsbDrive', $script:validationDrive, '-Silent',
            '-SelectedFoldersFile', $selection
        )
        $result.ExitCode | Should -Be 10
        $result.Output | Should -Match 'reserviert|reserved'
    }

    It 'refuses a custom folder that does not exist' {
        $selection = New-SelectionFile -Path (Join-Path $script:validationWorkRoot 'missing.json') `
            -Folders @(@{ Name = 'M24Fehlt'; Path = (Join-Path $script:validationWorkRoot 'gibt-es-nicht') })
        $result = Invoke-Worker @(
            '-Mode', 'Backup', '-UsbDrive', $script:validationDrive, '-Silent',
            '-SelectedFoldersFile', $selection
        )
        $result.ExitCode | Should -Be 10
        $result.Output | Should -Match 'wurde nicht gefunden|was not found'
    }

    It 'refuses a selection file that does not exist' {
        $result = Invoke-Worker @(
            '-Mode', 'Backup', '-UsbDrive', $script:validationDrive, '-Silent',
            '-SelectedFoldersFile', (Join-Path $script:validationWorkRoot 'keine-auswahl.json')
        )
        $result.ExitCode | Should -Be 10
        $result.Output | Should -Match 'Auswahldatei|selection file'
    }
}
