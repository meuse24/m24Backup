<#
Sichert die persoenlichen Windows-Bibliotheksordner des angemeldeten Benutzers
mit Robocopy auf einen USB-Stick oder ein anderes ausgewaehltes Laufwerk.

Beispiele:
  .\Bibliothekssicherung.ps1
  .\Bibliothekssicherung.ps1 -UsbDrive E:
  .\Bibliothekssicherung.ps1 -UsbDrive E: -Silent
  .\Bibliothekssicherung.ps1 -UsbDrive E: -Silent -SuperFast
#>
param(
    [ValidateSet('Backup', 'Restore')]
    [string]$Mode = 'Backup',
    # GUI-Prozess fuer einen Restore-Handshake ohne starren Timeout.
    [int]$ParentProcessId = 0,
    # Exakte Prozessidentitaet; verhindert, dass eine wiederverwendete PID als
    # weiterhin laufende GUI akzeptiert wird.
    [int64]$ParentProcessStartTimeUtcTicks = 0,
    # Optionales Ziellaufwerk. Akzeptiert zum Beispiel E, E: oder E:\.
    [string]$UsbDrive,
    # Unterdrueckt Auswahl und Rueckfrage; -UsbDrive sollte dann angegeben sein.
    [switch]$Silent,
    # Optionaler Kommunikationskanal fuer die grafische Oberflaeche.
    [string]$StatusFile,
    # Strukturierte Zusammenfassung fuer die grafische Oberflaeche.
    [string]$ResultFile,
    # Wird diese Datei angelegt, endet die Sicherung sauber nach dem aktuellen Ordner.
    [string]$CancelFile,
    # Vorschau bzw. Warnungen und Freigabe fuer die GUI (Restore-Vorschau
    # sowie Scan-Warnungen der Sicherungs-Vorpruefung).
    [string]$PreviewFile,
    [string]$ApprovalFile,
    # Optional: mit | getrennte Anzeigenamen der zu sichernden Ordner.
    [string]$SelectedFolders,
    # Optional: JSON-Datei mit ausgewaehlten Ordnern inkl. benutzerdefinierter Pfade.
    [string]$SelectedFoldersFile,
    # Explizite Sicherungsquelle fuer Wiederherstellungen. Muss ein direkter
    # Unterordner von <Laufwerk>\Bibliothekssicherung sein.
    [string]$BackupSource,
    # Profil: in die Ordner des aktuellen Benutzers; Folder: gesammelt unter
    # RestoreTargetRoot\<Sicherungsname>.
    [ValidateSet('Profile', 'Folder')]
    [string]$RestoreTargetMode = 'Profile',
    [string]$RestoreTargetRoot,
    # Simuliert ein Backup mit Robocopy /L, ohne Nutzdaten oder Metadaten zu schreiben.
    [switch]$DryRun,
    # Ueberspringt die automatische Aktualisierung des SHA-256-Pruefsummenmanifests.
    [switch]$SkipChecksums,
    # Superschnelle Sicherung: keine Vorpruefung, keine Pruefsummen, keine
    # BitLocker-Abfrage, keine Kopierwiederholungen; Thread-Standard 32.
    # Nur fuer -Mode Backup und nicht zusammen mit -DryRun zulaessig.
    [switch]$SuperFast,
    # CLI bleibt kompatibel; die GUI verwendet den sicheren Verify-Standard.
    [ValidateSet('Verify', 'RequireVerified', 'Warn')]
    [string]$RestoreIntegrityPolicy = 'Warn',
    # Anzahl der parallelen Robocopy-Threads.
    [int]$Threads = 8
)

# Behandelt auch Fehler ausserhalb einzelner Funktionen als Abbruch.
$ErrorActionPreference = 'Stop'
$script:backupMetadataStarted = $false
$script:cancellationMonitor = $null
$script:lastCancellationReason = $null
$sharedScript = Join-Path $PSScriptRoot 'M24Backup.Shared.ps1'
if (Test-Path -LiteralPath $sharedScript -PathType Leaf) {
    . $sharedScript
} else {
    throw "Shared helper script not found: $sharedScript"
}

# M bleibt der gewohnte Kurzname fuer zweisprachige Texte, verweist aber auf
# die gemeinsame Implementierung in M24Backup.Shared.ps1.
$script:isGerman = Initialize-M24Localization
Set-Alias -Name M -Value Get-M24Text -Scope Script

function Write-AtomicJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]$Value,
        [string]$Path,
        [int]$Depth = 4
    )
    process {
        $json = $Value | ConvertTo-Json -Depth $Depth
        Write-M24AtomicTextFile -Path $Path -Content ($json + [Environment]::NewLine)
    }
}

function New-BackupResultRecord {
    # Einheitlicher Ergebnisvertrag: Jeder Exitpfad erhaelt dieselben
    # Basisfelder; pfadspezifische Werte ergaenzen oder ueberschreiben sie.
    # Die Funktion muss auch in der Trap funktionieren, wenn Policy oder
    # Vorpruefung noch gar nicht existieren.
    param([hashtable]$Values)

    $policy = Get-Variable -Name runPolicy -ValueOnly -ErrorAction SilentlyContinue
    $performed = [bool](Get-Variable -Name preflightPerformed -ValueOnly -ErrorAction SilentlyContinue)
    $scan = Get-Variable -Name preflight -ValueOnly -ErrorAction SilentlyContinue
    $record = [ordered]@{
        Success = $false
        Cancelled = $false
        CancellationReason = $script:lastCancellationReason
        Mode = $Mode
        DryRun = $DryRun.IsPresent
        SuperFast = $SuperFast.IsPresent
        PreflightSkipped = [bool]($policy -and $policy.SkipPreflight)
        ChecksumSkipped = [bool]($Mode -eq 'Backup' -and -not $DryRun -and $policy -and $policy.SkipChecksums)
        # $null bedeutet "nicht ermittelt" (z. B. Superschnell-Modus oder
        # Abbruch vor der Vorpruefung); 0 wuerde faelschlich einen ermittelten
        # leeren Kopierumfang behaupten.
        ScannedFiles = $(if ($performed -and $scan) { $scan.FileCount } else { $null })
        PlannedFiles = $(if ($performed -and $scan) { $scan.RequiredFileCount } else { $null })
        PlannedBytes = $(if ($performed -and $scan) { $scan.RequiredBytes } else { $null })
        IntegrityPolicy = $(if ($Mode -eq 'Restore') { $RestoreIntegrityPolicy } else { $null })
        IntegrityVerified = [bool](Get-Variable -Name restoreIntegrityVerified -ValueOnly -ErrorAction SilentlyContinue)
        IntegrityOverride = [bool](Get-Variable -Name restoreIntegrityOverride -ValueOnly -ErrorAction SilentlyContinue)
        IntegrityVerificationPerformed = [bool](Get-Variable -Name restoreIntegrityVerificationPerformed -ValueOnly -ErrorAction SilentlyContinue)
        SourceComputer = [string](Get-Variable -Name restoreSourceComputer -ValueOnly -ErrorAction SilentlyContinue)
        SourceUser = [string](Get-Variable -Name restoreSourceUser -ValueOnly -ErrorAction SilentlyContinue)
        SourcePath = $(if ($Mode -eq 'Restore') { [string](Get-Variable -Name destination -ValueOnly -ErrorAction SilentlyContinue) } else { $null })
        RestoreTargetMode = $(if ($Mode -eq 'Restore') { $RestoreTargetMode } else { $null })
        RestoreTargetRoot = [string](Get-Variable -Name resolvedRestoreTargetRoot -ValueOnly -ErrorAction SilentlyContinue)
        IsMigration = [bool](Get-Variable -Name restoreIsMigration -ValueOnly -ErrorAction SilentlyContinue)
        FinishedAt = (Get-Date).ToString('o')
    }
    foreach ($key in $Values.Keys) { $record[$key] = $Values[$key] }
    return [pscustomobject]$record
}

function Exit-OperationLock {
    if ($script:operationLockStream) {
        try { $script:operationLockStream.Dispose() } catch {}
        $script:operationLockStream = $null
    }
    if ($script:operationLockFile) {
        Remove-Item -LiteralPath $script:operationLockFile -Force -ErrorAction SilentlyContinue
        $script:operationLockFile = $null
    }
}

trap {
    $trapLogFile = $null
    $logVariable = Get-Variable -Name logFile -ErrorAction SilentlyContinue
    if ($logVariable -and $logVariable.Value) {
        $trapLogFile = [string]$logVariable.Value
        try {
            $trapLogDir = Split-Path -Path $trapLogFile -Parent
            if ($trapLogDir) { New-Item -ItemType Directory -Path $trapLogDir -Force | Out-Null }
            @(
                "Start: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
                "Vorgang: $Mode",
                "Fehler vor oder waehrend des Kopiervorgangs.",
                "Grund: $($_.Exception.Message)",
                ""
            ) | Add-Content -LiteralPath $trapLogFile -Encoding Unicode
        } catch {
            $trapLogFile = $null
        }
    }
    if ($StatusFile) {
        try {
            Write-M24AtomicTextFile -Path $StatusFile -Content (Format-M24StatusMessage -Type 'FEHLER' -Fields @($_.Exception.Message))
        } catch {
            # Ein Fehler beim optionalen GUI-Status darf den Originalfehler nicht verdecken.
        }
    }
    if ($ResultFile) {
        try {
            New-BackupResultRecord -Values @{ Message = $_.Exception.Message; LogFile = $trapLogFile } |
                Write-AtomicJsonFile -Path $ResultFile
        } catch {}
    }
    if ($Mode -eq 'Backup' -and -not $DryRun -and $script:backupMetadataStarted) {
        # Auch Fehler nach einem erfolgreichen Robocopy-Lauf (zum Beispiel bei
        # der Manifestpflege) muessen einen alten Erfolgsstatus entwerten.
        try {
            $metadataVariable = Get-Variable -Name metadataFile -ErrorAction SilentlyContinue
            if ($metadataVariable -and $metadataVariable.Value -and (Test-Path -LiteralPath $metadataVariable.Value -PathType Leaf)) {
                Set-BackupResultMetadata -Path $metadataVariable.Value -Result 'Mit Fehlern beendet'
            }
        } catch {
            # Der urspruengliche Fehler bleibt fuer Status und Exitcode massgeblich.
        }
    }
    Write-Host ""
    Write-Host (M "Der Vorgang konnte nicht abgeschlossen werden." "The operation could not be completed.")
    Write-Host ((M "Grund: {0}" "Reason: {0}") -f $_.Exception.Message)
    Write-Host (M "Bitte pruefen Sie Laufwerk und Auswahl und starten Sie den Vorgang erneut." "Check the drive and selection, then start the operation again.")
    Exit-OperationLock
    exit 10
}

if (-not $Silent) {
    Clear-Host
}

# Zentrale Lauf-Policy: lehnt unzulaessige Superfast-Kombinationen vor jeder
# Laufwerksaufloesung ab und liefert die effektiven Kopierparameter
# (Threads, Wiederholungen) sowie die zu ueberspringenden Pruefschritte.
$runPolicy = Get-M24BackupRunPolicy -Mode $Mode -SuperFast:$SuperFast -DryRun:$DryRun -SkipChecksums:$SkipChecksums `
    -ExplicitThreads $(if ($PSBoundParameters.ContainsKey('Threads')) { [int]$Threads } else { $null })
$Threads = $runPolicy.Threads

function Set-BackupResultMetadata {
    param(
        [string]$Path,
        [string]$Result
    )

    $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop | Where-Object { $_ -notlike 'Ergebnis:*' })
    $content = (@($lines) + "Ergebnis: $Result am $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss').") -join [Environment]::NewLine
    Write-M24AtomicTextFile -Path $Path -Content ($content + [Environment]::NewLine)
}
if ($DryRun -and $Mode -ne 'Backup') {
    throw (M "Dry-Run ist nur fuer Sicherungen verfuegbar." "Dry run is only available for backups.")
}

function Write-BackupStatus {
    # -Text ist die Kurzform fuer Meldungen mit einem einzigen Textfeld;
    # -Fields uebergibt mehrteilige Nachrichten. Typ und Feldanzahl prueft
    # Format-M24StatusMessage gegen den gemeinsamen Vertrag in
    # M24Backup.Shared.ps1.
    param(
        [string]$Type,
        [string]$Text,
        [string[]]$Fields
    )

    if (-not $StatusFile) { return }

    $payload = if ($PSBoundParameters.ContainsKey('Fields')) { @($Fields) } else { @($Text) }
    # Bewusst ausserhalb des catch: Ein Vertragsbruch ist ein Programmierfehler
    # und darf nicht als vermeintliches Dateiproblem untergehen.
    $line = Format-M24StatusMessage -Type $Type -Fields $payload
    try {
        Write-M24AtomicTextFile -Path $StatusFile -Content $line
    } catch {
        # Die Sicherung laeuft weiter, falls nur die GUI-Statusdatei nicht schreibbar ist.
    }
}

$script:cancellationMonitor = New-M24CancellationMonitor

function Get-WorkerCancellationState {
    param([switch]$ForceOwnerCheck)
    return Get-M24CancellationState -CancelFile $CancelFile -ParentProcessId $ParentProcessId `
        -ParentProcessStartTimeUtcTicks $ParentProcessStartTimeUtcTicks -Monitor $script:cancellationMonitor `
        -MinimumOwnerCheckIntervalMilliseconds $(if ($ForceOwnerCheck) { 0 } else { 2000 })
}

function Get-WorkerFinalCancellationState {
    $state = Get-WorkerCancellationState
    if (-not $state.Requested -and $ParentProcessId -gt 0 -and [int]$script:cancellationMonitor.ConsecutiveOwnerFailures -gt 0) {
        # Nur im Verdachtsfall warten: Ein Erfolg darf nicht zwischen dem
        # ersten fehlgeschlagenen Owner-Check und dessen Entprellung festgeschrieben werden.
        Start-Sleep -Milliseconds 2000
        $state = Get-WorkerCancellationState -ForceOwnerCheck
    }
    return $state
}

function Get-WorkerCancellationMessage {
    param([string]$Reason)
    if ($Reason -eq 'GuiExited') {
        return M 'Die Bedienoberflaeche wurde unerwartet geschlossen; der Vorgang wurde kontrolliert beendet.' 'The user interface closed unexpectedly; the operation was stopped safely.'
    }
    return (Get-OperationLabels -OperationMode $Mode -DryRun ([bool]$DryRun)).Cancelled
}

function Stop-M24CancelledOperation {
    param(
        $State,
        [string]$InterruptedFolder,
        [bool]$HardStopped = $false
    )
    if (-not $State -or -not $State.Requested) { return }
    $script:lastCancellationReason = [string]$State.Reason
    $message = Get-WorkerCancellationMessage -Reason $script:lastCancellationReason
    Write-BackupStatus -Type 'ABGEBROCHEN' -Text $message

    $metadata = Get-Variable -Name metadataFile -ValueOnly -ErrorAction SilentlyContinue
    if ($Mode -eq 'Backup' -and -not $DryRun -and $script:backupMetadataStarted -and $metadata) {
        try { Set-BackupResultMetadata -Path $metadata -Result $(if ($script:lastCancellationReason -eq 'GuiExited') { 'Nach Schliessen der Bedienoberflaeche abgebrochen' } else { 'Vom Benutzer abgebrochen' }) } catch {}
    }
    $log = Get-Variable -Name logFile -ValueOnly -ErrorAction SilentlyContinue
    if ($log) {
        try { Add-Content -LiteralPath $log -Encoding Unicode -Value ("Abbruchgrund: {0}. {1}" -f $script:lastCancellationReason, $message) } catch {}
    }
    if ($ResultFile) {
        try {
            $values = @{
                Cancelled = $true; CancellationReason = $script:lastCancellationReason; Message = $message
                Destination = $(Get-Variable -Name destination -ValueOnly -ErrorAction SilentlyContinue)
                LogFile = $log; InterruptedFolder = $InterruptedFolder
                HardStopped = $HardStopped; PartialFilesMayRemain = $HardStopped
            }
            $started = Get-Variable -Name backupStartedAt -ValueOnly -ErrorAction SilentlyContinue
            if ($started) { $values.StartedAt = $started.ToString('o') }
            foreach ($resultArray in @('successfulFolders', 'foldersWithHints', 'failedFolders', 'robocopyWarnings')) {
                $resultArrayValue = Get-Variable -Name $resultArray -ValueOnly -ErrorAction SilentlyContinue
                if ($null -ne $resultArrayValue) {
                    $resultName = switch ($resultArray) {
                        'successfulFolders' { 'SuccessfulFolders' }
                        'foldersWithHints' { 'HintFolders' }
                        'failedFolders' { 'FailedFolders' }
                        'robocopyWarnings' { 'RobocopyWarnings' }
                    }
                    $values[$resultName] = @($resultArrayValue)
                }
            }
            New-BackupResultRecord -Values $values | Write-AtomicJsonFile -Path $ResultFile -Depth 4
        } catch {}
    }
    Exit-OperationLock
    exit 20
}

function Set-ProcessArguments {
    param(
        [System.Diagnostics.ProcessStartInfo]$StartInfo,
        [string[]]$Arguments
    )

    $argumentListProperty = $StartInfo.PSObject.Properties['ArgumentList']
    if ($argumentListProperty -and $null -ne $StartInfo.ArgumentList) {
        foreach ($argument in $Arguments) {
            [void]$StartInfo.ArgumentList.Add([string]$argument)
        }
    } else {
        $StartInfo.Arguments = ($Arguments | ForEach-Object { ConvertTo-M24ProcessArgument ([string]$_) }) -join ' '
    }
}

function Invoke-RobocopyWithCancel {
    param(
        [string[]]$Arguments,
        [string]$CancelFile,
        [int]$CurrentFolder,
        [int]$TotalFolders,
        [string]$FolderName
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'robocopy.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    Set-ProcessArguments -StartInfo $startInfo -Arguments $Arguments

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $lastStatusAt = [datetime]::MinValue
    try {
        if (-not $process.Start()) {
            throw (M 'Robocopy konnte nicht gestartet werden.' 'Robocopy could not be started.')
        }

        while (-not $process.WaitForExit(500)) {
            $cancellation = Get-WorkerCancellationState
            if ($cancellation.Requested) {
                Write-BackupStatus -Type 'ABBRUCHLAEUFT' -Fields $CurrentFolder, $TotalFolders, $FolderName
                try {
                    if (-not $process.HasExited) { $process.Kill() }
                } catch {
                    # Der Worker behandelt den Abbruch auch dann als angefordert,
                    # wenn Robocopy zwischen Pruefung und Kill bereits beendet wurde.
                }
                $waitedSeconds = 0
                while (-not $process.WaitForExit(1000)) {
                    $waitedSeconds++
                    if (($waitedSeconds % 5) -eq 0) {
                        try {
                            if (-not $process.HasExited) { $process.Kill() }
                        } catch {}
                    }
                    Write-BackupStatus -Type 'ABBRUCHWARTET' -Fields $CurrentFolder, $TotalFolders, $FolderName, $waitedSeconds
                }
                return [pscustomobject]@{ Cancelled = $true; CancellationState = $cancellation; ExitCode = 20; HardStopped = $true }
            }

            $now = Get-Date
            if (($now - $lastStatusAt).TotalSeconds -ge 2) {
                Write-BackupStatus -Type 'KOPIERVORGANG' -Fields $CurrentFolder, $TotalFolders, $FolderName
                $lastStatusAt = $now
            }
        }

        return [pscustomobject]@{ Cancelled = $false; ExitCode = $process.ExitCode; HardStopped = $false }
    } finally {
        if ($process) { try { $process.Dispose() } catch {} }
    }
}

function Wait-GuiApproval {
    param(
        [string]$CancelMessage,
        [string]$ClosedMessage,
        [string[]]$AllowedValues = @('continue')
    )

    # Wartet auf die Freigabedatei der GUI. Abbruchsignal und ein Ende des
    # GUI-Prozesses beenden den Worker kontrolliert; ohne GUI-Prozess-ID
    # gilt ein Zeitlimit von zehn Minuten.
    $approvalDeadline = (Get-Date).AddMinutes(10)
    while (-not (Test-Path -LiteralPath $ApprovalFile)) {
        $cancellation = Get-WorkerCancellationState
        if ($cancellation.Requested) { Stop-M24CancelledOperation -State $cancellation }
        if ($ParentProcessId -le 0 -and (Get-Date) -gt $approvalDeadline) {
            throw (M 'Die Freigabe ist abgelaufen.' 'The approval timed out.')
        }
        Start-Sleep -Milliseconds 200
    }
    $approvalValue = (Get-Content -LiteralPath $ApprovalFile -Raw -ErrorAction Stop).Trim()
    if ($AllowedValues -cnotcontains $approvalValue) { throw (M 'Die Freigabedatei enthaelt keine gueltige Bestaetigung.' 'The approval file does not contain a valid confirmation.') }
    return $approvalValue
}

function Get-BackupPreflight {
    param(
        [array]$Folders,
        [string[]]$ExcludedFiles,
        [ValidateSet('Backup', 'Restore')]
        [string]$OperationMode = 'Backup',
        [scriptblock]$CancelCallback
    )

    [int64]$totalBytes = 0
    [int64]$requiredBytes = 0
    [int64]$fileCount = 0
    [int64]$requiredFileCount = 0
    $largeFiles = @()
    $scanWarnings = @()
    $scanNotices = @()
    $requiredByRoot = @{}
    $additionalByRoot = @{}
    [int64]$missingFileCount = 0
    [int64]$overwriteFileCount = 0
    [int64]$protectedNewerFileCount = 0
    $overwriteExamples = @()
    $index = 0

    foreach ($folder in $Folders) {
        if ($CancelCallback) {
            $cancelState = & $CancelCallback
            if ($cancelState.Requested) { return [pscustomobject]@{ Cancelled = $true; CancellationState = $cancelState } }
        }
        $index++
        Write-BackupStatus -Type 'PRUEFUNG' -Fields $index, @($Folders).Count, $folder.Name
        try {
            $folderScanWarnings = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            $folderScanNotices = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            $sourceRoot = [string]$folder.Path
            $sourceRootLength = $sourceRoot.TrimEnd('\').Length
            $targetRootPath = [string]$folder.TargetPath
            $targetDriveRoot = [System.IO.Path]::GetPathRoot($targetRootPath).TrimEnd('\')
            # Pro Verzeichnis wird nur die unmittelbare Ebene materialisiert.
            # Das bleibt speicherarm, laesst den PowerShell-Provider aber nach
            # einzelnen Lesefehlern weiterarbeiten. /XJ schliesst nur Junctions
            # aus; symbolische Verzeichnislinks werden wie von Robocopy verfolgt.
            $pendingDirectories = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
            $pendingDirectories.Push((New-Object System.IO.DirectoryInfo($folder.Path)))
            while ($pendingDirectories.Count -gt 0) {
                if ($CancelCallback) {
                    $cancelState = & $CancelCallback
                    if ($cancelState.Requested) { return [pscustomobject]@{ Cancelled = $true; CancellationState = $cancelState } }
                }
                $directory = $pendingDirectories.Pop()
                $directoryErrors = @()
                $entries = @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue -ErrorVariable +directoryErrors)
                foreach ($directoryError in $directoryErrors) {
                    if (Test-M24SkippedJunctionAccessError -ErrorRecord $directoryError) {
                        [void]$folderScanNotices.Add($directoryError.Exception.Message)
                    } else {
                        [void]$folderScanWarnings.Add($directoryError.Exception.Message)
                    }
                }
                foreach ($entry in $entries) {
                    if ($CancelCallback) {
                        $cancelState = & $CancelCallback
                        if ($cancelState.Requested) { return [pscustomobject]@{ Cancelled = $true; CancellationState = $cancelState } }
                    }
                    if ($entry.PSIsContainer) {
                        if ([string]$entry.LinkType -ne 'Junction') {
                            $pendingDirectories.Push([System.IO.DirectoryInfo]$entry)
                        }
                        continue
                    }
                    $file = [System.IO.FileInfo]$entry
                    try {
                        if (Test-M24ExcludedFileName -Name $file.Name -Patterns $ExcludedFiles) { continue }

                        $fileCount++
                        $totalBytes += $file.Length
                        if ($file.Length -ge 4GB) { $largeFiles += $file.FullName }

                        $relative = $file.FullName.Substring($sourceRootLength).TrimStart('\')
                        $targetFile = Join-Path $targetRootPath $relative
                        $needsCopy = $true
                        # Netto-Mehrbedarf am Ziel: Eine zu ueberschreibende Zieldatei
                        # gibt ihren Platz wieder frei, es zaehlt nur die Differenz.
                        [int64]$additionalLength = $file.Length
                        if ([System.IO.File]::Exists($targetFile)) {
                            try {
                                $existing = New-Object System.IO.FileInfo($targetFile)
                                $timeDifference = ($file.LastWriteTimeUtc - $existing.LastWriteTimeUtc).TotalSeconds
                                if ($OperationMode -eq 'Restore') {
                                    # Beim Restore schuetzt /XO neuere lokale Dateien.
                                    $needsCopy = ($timeDifference -gt 2) -or (([math]::Abs($timeDifference) -le 2) -and ($file.Length -ne $existing.Length))
                                    if (-not $needsCopy -and $timeDifference -lt -2) {
                                        $protectedNewerFileCount++
                                    }
                                } else {
                                    # Beim Backup gewinnt der aktuelle Quellbestand: Auch eine
                                    # Quelldatei mit aelterem Zeitstempel wird kopiert, wenn sie
                                    # von der Zieldatei abweicht (Robocopy ohne /XO).
                                    $needsCopy = ([math]::Abs($timeDifference) -gt 2) -or ($file.Length -ne $existing.Length)
                                }
                                if ($needsCopy) {
                                    $overwriteFileCount++
                                    if ($overwriteExamples.Count -lt 10) { $overwriteExamples += $targetFile }
                                    $additionalLength = [math]::Max([int64]0, [int64]$file.Length - [int64]$existing.Length)
                                }
                            } catch { $needsCopy = $true }
                        } else {
                            $missingFileCount++
                        }
                        if ($needsCopy) {
                            $requiredFileCount++
                            $requiredBytes += $file.Length
                            if (-not $requiredByRoot.ContainsKey($targetDriveRoot)) { $requiredByRoot[$targetDriveRoot] = [int64]0 }
                            $requiredByRoot[$targetDriveRoot] = [int64]$requiredByRoot[$targetDriveRoot] + $file.Length
                            if (-not $additionalByRoot.ContainsKey($targetDriveRoot)) { $additionalByRoot[$targetDriveRoot] = [int64]0 }
                            $additionalByRoot[$targetDriveRoot] = [int64]$additionalByRoot[$targetDriveRoot] + $additionalLength
                        }
                    } catch {
                        [void]$folderScanWarnings.Add($_.Exception.Message)
                    }
                }
            }
            foreach ($scanWarning in $folderScanWarnings) {
                $scanWarnings += ("{0}: {1}" -f $folder.Name, $scanWarning)
            }
            foreach ($scanNotice in $folderScanNotices) {
                $scanNotices += ("{0}: {1}" -f $folder.Name, $scanNotice)
            }
        } catch {
            $scanWarnings += ("{0}: {1}" -f $folder.Name, $_.Exception.Message)
        }
    }

    [pscustomobject]@{
        FileCount = $fileCount
        TotalBytes = $totalBytes
        RequiredFileCount = $requiredFileCount
        RequiredBytes = $requiredBytes
        LargeFiles = @($largeFiles)
        ScanWarnings = @($scanWarnings)
        ScanNotices = @($scanNotices)
        RequiredByRoot = $requiredByRoot
        AdditionalByRoot = $additionalByRoot
        MissingFileCount = $missingFileCount
        OverwriteFileCount = $overwriteFileCount
        ProtectedNewerFileCount = $protectedNewerFileCount
        OverwriteExamples = @($overwriteExamples)
    }
}

function Resolve-UsbDrive {
    param(
        [string]$Drive,
        [switch]$Silent
    )

    if ($Drive) {
        # Unterschiedliche Schreibweisen auf einen Laufwerksbuchstaben normalisieren.
        $normalized = $Drive.Trim()
        if ($normalized -notmatch '^[A-Za-z](?::)?[\\/]?$') {
            throw ((M "Ungueltiges Ziellaufwerk '{0}'. Bitte einen Laufwerksbuchstaben wie E, E: oder E:\ angeben." "Invalid drive '{0}'. Specify a drive letter such as E, E:, or E:\.") -f $Drive)
        }
        $normalized = "{0}:" -f $normalized.Substring(0, 1)
        if ($normalized -eq $env:SystemDrive) {
            throw ((M "Das Systemlaufwerk '{0}' darf nicht als Sicherungsziel verwendet werden." "The system drive '{0}' cannot be used as a backup destination.") -f $normalized)
        }
        if (Test-Path "$normalized\") {
            return $normalized.ToUpperInvariant()
        }
        throw ((M "Das Laufwerk '{0}\' wurde nicht gefunden." "Drive '{0}\' was not found.") -f $normalized)
    }

    $systemDrive = $env:SystemDrive
    $driveTypeNames = @{
        2 = "Wechseldatentraeger"
        3 = "Lokaler Datentraeger"
    }

    # Das Systemlaufwerk wird nie angeboten. Interne Datenlaufwerke bleiben
    # moeglich, werden im Gegensatz zu einem einzelnen USB-Laufwerk aber nicht
    # automatisch ausgewaehlt.
    $candidates = @(Get-CimInstance Win32_LogicalDisk |
        Where-Object {
            $_.DriveType -in 2, 3 -and
            $_.DeviceID -ne $systemDrive -and
            $_.Size -gt 0
        } |
        Sort-Object DriveType, DeviceID)

    if (-not $candidates) {
        throw (M "Kein geeignetes Ziel-Laufwerk gefunden. Bitte USB-Stick oder externe Platte anschliessen und erneut starten." "No suitable drive was found. Connect a USB flash drive or external disk and try again.")
    }

    # Ein einzelner Wechseldatentraeger ist als Ziel eindeutig genug.
    if (@($candidates).Count -eq 1 -and $candidates[0].DriveType -eq 2) {
        if (-not $Silent) {
            Write-Host ""
            Write-Host "Geeignete Ziel-Laufwerke:"
            Write-Host ""
            Write-Host ("{0,-4} {1,-6} {2,-24} {3,10} {4,10}  {5}" -f "Nr.", "Lw.", "Name", "Frei", "Gesamt", "Typ")
            Write-Host ("{0,-4} {1,-6} {2,-24} {3,10} {4,10}  {5}" -f "---", "---", "----", "----", "------", "---")
            $disk = $candidates[0]
            $freeGb = [math]::Round($disk.FreeSpace / 1GB, 1)
            $sizeGb = [math]::Round($disk.Size / 1GB, 1)
            $label = if ($disk.VolumeName) { $disk.VolumeName } else { "(ohne Namen)" }
            $type = $driveTypeNames[[int]$disk.DriveType]
            Write-Host ("[{0,-2}] {1,-6} {2,-24} {3,8} GB {4,8} GB  {5}" -f 1, $disk.DeviceID, $label, $freeGb, $sizeGb, $type)
            Write-Host ""
            Write-Host "Hinweis: Das Systemlaufwerk $systemDrive wird absichtlich nicht als Ziel angeboten."
            Write-Host ""
            Write-Host ("Ziellaufwerk automatisch ausgewaehlt: {0}" -f $candidates[0].DeviceID)
        }
        return $candidates[0].DeviceID
    }

    if ($Silent) {
        throw (M "Das Ziellaufwerk konnte nicht eindeutig automatisch bestimmt werden. Bitte im Silent-Modus -UsbDrive angeben." "The destination drive could not be determined unambiguously. Specify -UsbDrive in silent mode.")
    }

    Write-Host ""
    Write-Host "Geeignete Ziel-Laufwerke:"
    Write-Host ""
    Write-Host ("{0,-4} {1,-6} {2,-24} {3,10} {4,10}  {5}" -f "Nr.", "Lw.", "Name", "Frei", "Gesamt", "Typ")
    Write-Host ("{0,-4} {1,-6} {2,-24} {3,10} {4,10}  {5}" -f "---", "---", "----", "----", "------", "---")

    for ($i = 0; $i -lt @($candidates).Count; $i++) {
        $disk = $candidates[$i]
        $freeGb = [math]::Round($disk.FreeSpace / 1GB, 1)
        $sizeGb = [math]::Round($disk.Size / 1GB, 1)
        $label = if ($disk.VolumeName) { $disk.VolumeName } else { "(ohne Namen)" }
        $type = $driveTypeNames[[int]$disk.DriveType]
        Write-Host ("[{0,-2}] {1,-6} {2,-24} {3,8} GB {4,8} GB  {5}" -f ($i + 1), $disk.DeviceID, $label, $freeGb, $sizeGb, $type)
    }

    Write-Host ""
    Write-Host "Hinweis: Das Systemlaufwerk $systemDrive wird absichtlich nicht als Ziel angeboten."
    Write-Host ""

    $numberOptions = 1..@($candidates).Count -join ", "

    while ($true) {
        $choice = Read-Host ("Ziellaufwerk waehlen [{0}] Enter = 1" -f $numberOptions)
        if ([string]::IsNullOrWhiteSpace($choice)) {
            $choice = "1"
        }

        if ($choice -match '^\d+$') {
            $index = [int]$choice - 1
            if ($index -ge 0 -and $index -lt @($candidates).Count) {
                return $candidates[$index].DeviceID
            }
        }

        Write-Host "Ungueltige Auswahl. Bitte nur eine angezeigte Zahl eingeben."
    }
}

function Get-BitLockerStatusText {
    param([string]$Drive)

    $unknownStatus = M 'BitLocker-Status konnte nicht ermittelt werden. Dies bedeutet nicht, dass BitLocker deaktiviert ist.' 'BitLocker status could not be determined. This does not mean that BitLocker is disabled.'
    $identity = $null
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
            return $unknownStatus
        }
    } catch {
        return $unknownStatus
    } finally {
        if ($identity) { $identity.Dispose() }
    }

    $cmd = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
    if (-not $cmd) {
        return $unknownStatus
    }

    # Die Abfrage kann trotz Admin-Konto scheitern, wenn PowerShell nicht
    # erhoeht gestartet wurde. Deshalb wird daraus kein Sicherungsfehler.
    try {
        $volume = Get-BitLockerVolume -MountPoint $Drive -ErrorAction Stop
        return "BitLocker: $($volume.ProtectionStatus)"
    } catch {
        return $unknownStatus
    }
}

function Test-IsReservedBackupName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }
    if ($Name.StartsWith('_')) { return $true }
    return (Get-ReservedBackupNames) -contains $Name
}

function Assert-ValidBackupFolderName {
    param([string]$Name)
    if (Test-IsReservedBackupName -Name $Name) {
        throw ((M "Der Ordnername '{0}' ist fuer interne Sicherungsdateien reserviert." "Folder name '{0}' is reserved for internal backup files.") -f $Name)
    }
    foreach ($invalidChar in [System.IO.Path]::GetInvalidFileNameChars()) {
        if ($Name.IndexOf($invalidChar) -ge 0) {
            throw ((M "Der Ordnername '{0}' enthaelt ungueltige Zeichen." "Folder name '{0}' contains invalid characters.") -f $Name)
        }
    }
}

function Assert-SafeRestoreTargetPath {
    param(
        [string]$Name,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathRooted($Path)) {
        throw ((M "Der Wiederherstellungspfad fuer '{0}' ist ungueltig." "The restore path for '{0}' is invalid.") -f $Name)
    }

    $normalized = Get-NormalizedFullPath $Path
    $blockedTrees = @(
        $env:APPDATA,
        $env:LOCALAPPDATA,
        $env:WINDIR,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Get-NormalizedFullPath $_ }

    if (Test-M24IsPathRoot $normalized) {
        throw ((M "Das Laufwerk '{0}' darf nicht als Wiederherstellungsziel verwendet werden." "Drive '{0}' cannot be used as a restore target.") -f $normalized)
    }
    $profileRoot = Get-NormalizedFullPath $env:USERPROFILE
    if ($normalized.Equals($profileRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (M 'Das gesamte Benutzerprofil darf nicht als Wiederherstellungsziel verwendet werden.' 'The whole user profile cannot be used as a restore target.')
    }
    foreach ($blockedPath in $blockedTrees) {
        if ($normalized.Equals($blockedPath, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalized.StartsWith("$blockedPath\", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ((M "Der Wiederherstellungspfad fuer '{0}' liegt in einem geschuetzten System- oder Profilbereich: {1}" "The restore path for '{0}' is in a protected system or profile location: {1}") -f $Name, $normalized)
        }
    }
    return $normalized
}

function Read-SelectedFolderSpecs {
    if ($SelectedFoldersFile) {
        if (-not (Test-Path -LiteralPath $SelectedFoldersFile -PathType Leaf)) {
            throw ((M "Die Auswahldatei wurde nicht gefunden: {0}" "The selection file was not found: {0}") -f $SelectedFoldersFile)
        }
        $parsedSelection = Get-Content -LiteralPath $SelectedFoldersFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return @($parsedSelection)
    }
    if ($SelectedFolders) {
        return @($SelectedFolders -split '\|' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
            [pscustomobject]@{ Name = $_; Path = $null; IsCustom = $false }
        })
    }
    return @()
}

function Read-CustomFolderMetadata {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try {
        return @(Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop | Where-Object { $_.Name -and $_.OriginalPath })
    } catch {
        return @()
    }
}

function Test-IsCustomFolderSpec {
    param($Spec)
    if (-not $Spec -or -not $Spec.PSObject.Properties['IsCustom']) { return $false }
    $value = $Spec.IsCustom
    if ($value -is [bool]) { return $value }
    if ($null -eq $value) { return $false }
    return ([string]$value).Trim().Equals('true', [System.StringComparison]::OrdinalIgnoreCase)
}

# --- Ordneraufloesung -------------------------------------------------------
#
# Backup und Restore ermitteln ihre Ordnerliste auf grundverschiedene Weise.
# Frueher stand beides als zwei grosse if-Bloecke im Hauptablauf; die
# Zuordnungsregeln sind jetzt je Betriebsart in einer eigenen Funktion
# gebuendelt und ohne kompletten Lauf pruefbar.

function Read-RestoreSourceIdentity {
    # Wer hat diese Sicherung erstellt und ist sie vollstaendig? Nicht lesbare
    # Metadaten sind kein Fehler, sondern schraenken nur die Zielwahl ein.
    param([string]$MetadataFile)

    $identity = [pscustomobject]@{
        Computer         = ''
        User             = ''
        MetadataReadable = $false
        IsMigration      = $false
        IsComplete       = $false
    }
    if (-not (Test-Path -LiteralPath $MetadataFile -PathType Leaf)) { return $identity }

    try {
        $lines = @(Get-Content -LiteralPath $MetadataFile -ErrorAction Stop)
        $sourceIdentity = Get-M24BackupMetadataIdentity -Lines $lines
        $identity.Computer = [string]$sourceIdentity.Computer
        $identity.User = [string]$sourceIdentity.User
        $identity.MetadataReadable = -not [string]::IsNullOrWhiteSpace($identity.Computer) -and
            -not [string]::IsNullOrWhiteSpace($identity.User)
        $identity.IsMigration = $identity.MetadataReadable -and
            -not (Test-M24BackupMetadataIdentity -Lines $lines)
        $identity.IsComplete = [bool](Get-M24BackupResultInfo -Lines $lines).IsComplete
    } catch {
        $identity.MetadataReadable = $false
    }
    return $identity
}

function Resolve-RestoreTargetRoot {
    # Prueft die Zielwahl und liefert bei 'Folder' die validierte Zielwurzel.
    # Fuer 'Profile' gibt es keine Wurzel; dort entscheidet je Ordner die
    # Zuordnung in Resolve-RestoreFolderDefinitions.
    param(
        [ValidateSet('Profile', 'Folder')][string]$TargetMode,
        [string]$TargetRoot,
        [string]$BackupSourcePath,
        [string]$BackupDisplayName,
        $SourceIdentity
    )

    if ($TargetMode -eq 'Profile') {
        if (-not $SourceIdentity.MetadataReadable) {
            throw (M 'Die Sicherungsmetadaten sind nicht lesbar. Diese Sicherung kann nur in einen separaten Ordner kopiert werden.' 'The backup metadata is not readable. This backup can only be copied to a separate folder.')
        }
        if (-not $SourceIdentity.IsComplete) {
            throw (M 'Die Sicherung ist nicht vollständig. Sie kann nur in einen separaten Ordner kopiert werden.' 'The backup is incomplete. It can only be copied to a separate folder.')
        }
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
        throw (M 'Für das Kopieren ist ein Zielordner erforderlich.' 'A destination folder is required for copying.')
    }
    $selectedTargetRoot = Assert-SafeRestoreTargetPath -Name (M 'Zielordner' 'Destination folder') -Path $TargetRoot
    Assert-ValidBackupFolderName -Name $BackupDisplayName
    $resolved = Assert-SafeRestoreTargetPath -Name $BackupDisplayName -Path (Join-Path $selectedTargetRoot $BackupDisplayName)
    if (Test-IsSameOrNestedPath -FirstPath $BackupSourcePath -SecondPath $resolved) {
        throw (M 'Sicherungsquelle und Wiederherstellungsziel dürfen nicht ineinander liegen.' 'Backup source and restore destination must not overlap.')
    }
    return $resolved
}

function Resolve-RestoreFolderDefinitions {
    # Ordnet jedem Ordner der Sicherung sein Wiederherstellungsziel zu.
    # Reihenfolge der Regeln: separater Zielordner, Standardbibliothek,
    # eigener Zusatzordner am Originalpfad, sonst gesammelt unter
    # "Wiederhergestellte Ordner".
    param(
        [string]$BackupSourcePath,
        $StandardDefinitions,
        [string]$FolderMetadataFile,
        [ValidateSet('Profile', 'Folder')][string]$TargetMode,
        [string]$ResolvedTargetRoot,
        [bool]$IsMigration,
        [string]$BackupDisplayName
    )

    $standardByName = @{}
    foreach ($definition in $StandardDefinitions) { $standardByName[[string]$definition.Name] = $definition }
    $customMetadataByName = @{}
    foreach ($customMetadata in @(Read-CustomFolderMetadata -Path $FolderMetadataFile)) {
        if ($customMetadata.Name) { $customMetadataByName[[string]$customMetadata.Name] = $customMetadata }
    }

    $sourceDirectories = @(Get-ChildItem -LiteralPath $BackupSourcePath -Directory -Force -ErrorAction Stop |
        Where-Object {
            -not $_.Name.StartsWith('_') -and
            ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0
        })

    $restoreDefinitions = @()
    foreach ($sourceDirectory in $sourceDirectories) {
        $restoreName = [string]$sourceDirectory.Name
        Assert-ValidBackupFolderName -Name $restoreName
        $isStandard = $standardByName.ContainsKey($restoreName)
        if ($TargetMode -eq 'Folder') {
            $restorePath = Assert-SafeRestoreTargetPath -Name $restoreName -Path (Join-Path $ResolvedTargetRoot $restoreName)
        } elseif ($isStandard) {
            $restorePath = Assert-SafeRestoreTargetPath -Name $restoreName -Path ([string]$standardByName[$restoreName].Path)
        } elseif (-not $IsMigration -and $customMetadataByName.ContainsKey($restoreName) -and $customMetadataByName[$restoreName].OriginalPath) {
            # Bestehendes Verhalten fuer die eigene Profilsicherung.
            $restorePath = Assert-SafeRestoreTargetPath -Name $restoreName -Path ([string]$customMetadataByName[$restoreName].OriginalPath)
        } else {
            $documentsDefinition = $standardByName['Dokumente']
            if (-not $documentsDefinition -or [string]::IsNullOrWhiteSpace([string]$documentsDefinition.Path)) {
                throw (M 'Der aktuelle Dokumente-Ordner konnte nicht ermittelt werden.' 'The current Documents folder could not be resolved.')
            }
            $migrationRoot = Join-Path ([string]$documentsDefinition.Path) (Join-Path (M 'Wiederhergestellte Ordner' 'Restored folders') $BackupDisplayName)
            $restorePath = Assert-SafeRestoreTargetPath -Name $restoreName -Path (Join-Path $migrationRoot $restoreName)
        }
        $restoreDefinitions += [pscustomobject]@{
            Name     = $restoreName
            Path     = $restorePath
            IsCustom = [bool](-not $isStandard)
        }
    }
    return @($restoreDefinitions)
}

function New-FolderCopyPlan {
    # Verbindet jede Ordnerdefinition mit ihrem Kopierziel und wendet die
    # Auswahl des Benutzers an. Beim Backup ist die Definition die Quelle und
    # das Ziel liegt im Sicherungsordner; beim Restore ist es umgekehrt.
    param(
        [ValidateSet('Backup', 'Restore')][string]$OperationMode,
        $FolderDefinitions,
        [string]$BackupRootPath,
        $SelectedFolderSpecs = @()
    )

    if ($OperationMode -eq 'Backup') {
        $plan = @($FolderDefinitions |
            Where-Object { Test-Path -LiteralPath $_.Path -PathType Container } |
            ForEach-Object {
                [pscustomobject]@{
                    Name       = $_.Name
                    Path       = $_.Path
                    TargetPath = Join-Path $BackupRootPath $_.Name
                    IsCustom   = [bool]$_.IsCustom
                }
            })
    } else {
        $backupRoot = Get-NormalizedFullPath $BackupRootPath
        $plan = @($FolderDefinitions | ForEach-Object {
            $restoreSource = Get-NormalizedFullPath (Join-Path $BackupRootPath $_.Name)
            if (-not $restoreSource.StartsWith("$backupRoot\", [System.StringComparison]::OrdinalIgnoreCase)) {
                throw ((M "Der Sicherungsordner '{0}' liegt ausserhalb des erwarteten Sicherungsverzeichnisses." "Backup folder '{0}' is outside the expected backup directory.") -f $_.Name)
            }
            if (Test-Path -LiteralPath $restoreSource -PathType Container) {
                [pscustomobject]@{
                    Name       = $_.Name
                    Path       = $restoreSource
                    TargetPath = $_.Path
                    IsCustom   = [bool]$_.IsCustom
                }
            }
        })
    }

    $selected = @($SelectedFolderSpecs)
    if ($selected.Count -gt 0) {
        $selectedNames = @($selected | ForEach-Object { [string]$_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $plan = @($plan | Where-Object { $selectedNames -contains $_.Name })
    }
    return @($plan)
}

function Assert-FolderCopyPlanIsSafe {
    # Buendelt alle Plausibilitaetspruefungen des fertigen Kopierplans.
    # Sie liefen frueher als vier getrennte Mode-Bloecke im Hauptablauf.
    param(
        [ValidateSet('Backup', 'Restore')][string]$OperationMode,
        $FolderPlan,
        [string]$BackupRootPath
    )

    $folders = @($FolderPlan)
    if (-not $folders) {
        throw (M "Es wurden keine passenden ausgewaehlten Ordner gefunden." "No matching selected folders were found.")
    }

    if ($OperationMode -eq 'Restore') {
        foreach ($folder in $folders) {
            if (Test-IsSameOrNestedPath -FirstPath $folder.Path -SecondPath $folder.TargetPath) {
                throw ((M "Sicherungsquelle und Wiederherstellungsziel fuer '{0}' duerfen nicht ineinander liegen." "Backup source and restore destination for '{0}' must not overlap.") -f $folder.Name)
            }
        }
        for ($first = 0; $first -lt $folders.Count; $first++) {
            for ($second = $first + 1; $second -lt $folders.Count; $second++) {
                if (Test-IsSameOrNestedPath -FirstPath $folders[$first].TargetPath -SecondPath $folders[$second].TargetPath) {
                    throw ((M "Wiederherstellungsziele ueberschneiden sich: '{0}' und '{1}'." "Restore destinations overlap: '{0}' and '{1}'.") -f $folders[$first].Name, $folders[$second].Name)
                }
            }
        }
    } else {
        $folderConflicts = @(Get-M24FolderPathConflicts -Folders $folders)
        if ($folderConflicts.Count -gt 0) {
            $conflict = $folderConflicts[0]
            $parentName = [string]$conflict.Parent.Name
            $childName = [string]$conflict.Child.Name
            if ($conflict.Relationship -eq 'Same') {
                throw ((M "Die ausgewaehlten Sicherungsordner '{0}' und '{1}' verwenden denselben Quellpfad '{2}'. Bitte waehlen Sie einen Eintrag ab." "The selected backup folders '{0}' and '{1}' use the same source path '{2}'. Please clear one entry.") -f $parentName, $childName, $conflict.FirstPath)
            }
            throw ((M "Der ausgewaehlte Sicherungsordner '{0}' ({1}) liegt innerhalb von '{2}' ({3}) und wuerde doppelt gesichert. Bitte waehlen Sie einen Eintrag ab." "The selected backup folder '{0}' ({1}) is inside '{2}' ({3}) and would be backed up twice. Please clear one entry.") -f $childName, $conflict.Child.Path, $parentName, $conflict.Parent.Path)
        }

        # Verhindert, dass das Sicherungsziel innerhalb einer Quelle liegt und
        # Robocopy dadurch seine eigenen Ausgabedateien erneut einliest.
        $destinationFullPath = [System.IO.Path]::GetFullPath($BackupRootPath).TrimEnd('\')
        foreach ($folder in $folders) {
            $sourceFullPath = [System.IO.Path]::GetFullPath($folder.Path).TrimEnd('\')
            if ($destinationFullPath -eq $sourceFullPath -or
                $destinationFullPath.StartsWith("$sourceFullPath\", [System.StringComparison]::OrdinalIgnoreCase)) {
                throw ((M "Das Sicherungsziel liegt innerhalb des Quellordners '{0}'. Bitte ein anderes Ziellaufwerk waehlen." "The backup destination is inside source folder '{0}'. Select a different destination drive.") -f $folder.Path)
            }
        }
    }

    # Zielordner ohne Laufwerksbuchstaben (z. B. auf eine Netzwerkfreigabe
    # umgeleitete Bibliotheken) werden abgelehnt, weil ihr freier Speicherplatz
    # nicht ueber Win32_LogicalDisk geprueft werden kann.
    foreach ($folder in $folders) {
        $targetRootCheck = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($folder.TargetPath)).TrimEnd('\')
        if ($targetRootCheck -notmatch '^[A-Za-z]:$') {
            throw ((M "Der Ordner '{0}' ist nach '{1}' umgeleitet. Ziele ohne Laufwerksbuchstaben (z. B. Netzwerkfreigaben) werden nicht unterstuetzt." "Folder '{0}' is redirected to '{1}'. Destinations without a drive letter (such as network shares) are not supported.") -f $folder.Name, $folder.TargetPath)
        }
    }
}

function New-OperationLogHeader {
    # Die Kopfzeilen der Protokolldatei. Die Restore-Angaben stehen als Block
    # beisammen, statt einzeln im Ablauf abgefragt zu werden.
    param(
        [ValidateSet('Backup', 'Restore')][string]$OperationMode,
        [string]$OperationName,
        [string]$BackupRootPath,
        [double]$FreeSpaceGb,
        [string]$FileSystem,
        [string]$BitLockerStatus,
        [int]$Threads,
        $RunPolicy,
        [bool]$DryRun,
        [string[]]$PreflightNotices = @(),
        # Nur fuer Wiederherstellungen ausgewertet:
        [string]$IntegrityPolicy,
        [bool]$IntegrityVerified,
        [bool]$IntegrityOverride,
        [bool]$IntegrityVerificationPerformed,
        [string]$SourceComputer,
        [string]$SourceUser,
        [string]$TargetMode,
        [bool]$IsMigration,
        [string]$TargetRoot,
        $FolderPlan = @()
    )

    $header = @(
        "Start: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Vorgang: $OperationName",
        "Sicherungsordner: $BackupRootPath",
        ("Freier Platz beim Start: {0:N1} GB" -f $FreeSpaceGb),
        "Dateisystem: $FileSystem",
        $BitLockerStatus,
        "Hinweis: Geoeffnete/gesperrte Dateien werden ohne VSS ggf. uebersprungen.",
        "Threads: $Threads",
        ("Robocopy-Wiederholungen: /R:{0} /W:{1}" -f $RunPolicy.RetryCount, $RunPolicy.RetryWaitSeconds),
        ("Superschnell-Modus: {0}" -f $(if ($RunPolicy.SuperFast) { 'Ja - Vorpruefung, Pruefsummen und BitLocker-Abfrage uebersprungen.' } else { 'Nein' })),
        ("Dry-Run: {0}" -f $(if ($DryRun) { 'Ja - es werden keine Nutzdaten kopiert.' } else { 'Nein' }))
    )
    $header += @($PreflightNotices)

    if ($OperationMode -eq 'Restore') {
        $header += @(
            "Restore-Integritaetsrichtlinie: $IntegrityPolicy",
            "Restore-Integritaet bestaetigt: $IntegrityVerified; ungepruefte Ausnahme: $IntegrityOverride; Pruefung in diesem Lauf: $IntegrityVerificationPerformed",
            "Quellidentitaet: $SourceComputer\$SourceUser",
            "Wiederherstellungsart: $TargetMode; Migration: $IsMigration; Zielwurzel: $TargetRoot",
            'Ordnerzuordnungen:'
        )
        $header += @($FolderPlan | ForEach-Object { "  $($_.Path) -> $($_.TargetPath)" })
    }
    $header += ''
    return @($header | Where-Object { $null -ne $_ })
}

function Write-OperationSummary {
    # Die Uebersicht vor der Bestaetigung. Buendelt alle betriebsartabhaengigen
    # Textvarianten an einer Stelle, statt sie ueber den Ablauf zu verteilen.
    param(
        [ValidateSet('Backup', 'Restore')][string]$OperationMode,
        $FolderPlan,
        [string]$BackupRootPath,
        [double]$FreeSpaceGb,
        [string]$FileSystem,
        [string]$BitLockerStatus,
        [bool]$PreflightPerformed,
        $Preflight,
        [bool]$Fat32Warning,
        [bool]$ManifestExists,
        $ChecksumsVerifiedAt,
        [bool]$IsGerman
    )

    $isRestore = $OperationMode -eq 'Restore'

    Write-Host ""
    Write-Host $(if ($isRestore) {
        M 'Wiederhergestellt werden diese Benutzerordner:' 'These user folders will be restored:'
    } else {
        M 'Gesichert werden nur diese Benutzerordner:' 'Only these user folders will be backed up:'
    })
    foreach ($folder in $FolderPlan) {
        Write-Host ("- {0}" -f (Get-M24FolderDisplayName $folder.Name $IsGerman))
    }
    Write-Host ""
    Write-Host $(if ($isRestore) {
        (M "Sicherungsquelle: {0}" "Backup source: {0}") -f $BackupRootPath
    } else {
        (M "Ziel:   {0}" "Destination: {0}") -f $BackupRootPath
    })
    Write-Host ((M "USB-Laufwerk: {0:N1} GB frei (Dateisystem: {1})" "USB drive: {0:N1} GB free (file system: {1})") -f $FreeSpaceGb, $FileSystem)
    if ($PreflightPerformed) {
        Write-Host ((M "Voraussichtlich zu kopieren: {0} Dateien, {1:N2} GB" "Expected copy volume: {0} files, {1:N2} GB") -f $Preflight.RequiredFileCount, ($Preflight.RequiredBytes / 1GB))
    } else {
        Write-Host (M "Superschnell-Modus: Vorpruefung uebersprungen; das Kopiervolumen wird nicht vorab ermittelt." "Super fast mode: preflight skipped; the copy volume is not estimated in advance.")
    }
    Write-Host $BitLockerStatus
    Write-Host ""

    if (-not $isRestore -and $Fat32Warning) {
        Write-Host (M "WARNUNG: FAT32 kann keine Dateien ab 4 GB speichern. Fuer Sicherungen sind exFAT oder NTFS besser geeignet." "WARNING: FAT32 cannot store files of 4 GB or larger. exFAT or NTFS is better suited for backups.")
        Write-Host ""
    }

    if ($isRestore) {
        Write-Host (M "Es wird nichts in den lokalen Ordnern geloescht." "Nothing is deleted from local folders.")
        Write-Host (M "Neuere lokale Dateien bleiben durch /XO geschuetzt." "Newer local files remain protected by /XO.")
        Write-Host ((M "Konflikte: {0} lokale Datei(en) werden ersetzt; {1} neuere lokale Datei(en) bleiben erhalten." "Conflicts: {0} local file(s) will be replaced; {1} newer local file(s) will remain protected.") -f $Preflight.OverwriteFileCount, $Preflight.ProtectedNewerFileCount)
        if (-not $ManifestExists) {
            Write-Host (M "WARNUNG: Fuer dieses Backup ist kein SHA-256-Pruefsummenmanifest vorhanden. Beschaedigte Dateien wuerden nicht erkannt." "WARNING: This backup has no SHA-256 checksum manifest. Corrupted files would not be detected.")
        } elseif ($ChecksumsVerifiedAt) {
            Write-Host ((M "Integritaet: Pruefsummen zuletzt erfolgreich geprueft am {0}." "Integrity: checksums last verified successfully on {0}.") -f $ChecksumsVerifiedAt)
        } else {
            Write-Host (M "Hinweis: Die Pruefsummen dieses Backups wurden seit der letzten Sicherung nicht geprueft. Empfehlung: vorher 'Backup pruefen' ausfuehren." "Note: The checksums of this backup have not been verified since the last backup. Recommendation: run 'Verify backup' first.")
        }
    } else {
        Write-Host (M "Es wird nichts im Backup-Ziel geloescht." "Nothing is deleted from the backup destination.")
        Write-Host (M "Geaenderte Quelldateien ersetzen ihre vorhandene Kopie im Backup, auch bei aelterem Zeitstempel der Quelle." "Changed source files replace their existing copy in the backup, even when the source timestamp is older.")
    }
    Write-Host (M "AppData, Temp- und Cache-Verzeichnisse werden nicht kopiert." "AppData, temporary, and cache folders are not copied.")
    Write-Host (M "Hinweis: Geoeffnete/gesperrte Dateien koennen uebersprungen werden; Details stehen im Log." "Note: Open or locked files may be skipped; see the log for details.")
    Write-Host ""
}

function Get-OperationLabels {
    # Die Bezeichnungen eines Laufs an einer Stelle. Eine Sicherungssimulation
    # ist sprachlich weder Sicherung noch Wiederherstellung.
    param(
        [ValidateSet('Backup', 'Restore')][string]$OperationMode,
        [bool]$DryRun
    )

    $isRestore = $OperationMode -eq 'Restore'
    return [pscustomobject]@{
        Operation = $(if ($isRestore) { M 'Wiederherstellung' 'Restore' } elseif ($DryRun) { M 'Sicherungssimulation' 'Backup simulation' } else { M 'Sicherung' 'Backup' })
        Success   = $(if ($isRestore) { M 'Wiederherstellung erfolgreich abgeschlossen.' 'Restore completed successfully.' } elseif ($DryRun) { M 'Simulation erfolgreich abgeschlossen.' 'Simulation completed successfully.' } else { M 'Sicherung erfolgreich abgeschlossen.' 'Backup completed successfully.' })
        Failure   = $(if ($isRestore) { M 'Wiederherstellung mit Fehlern beendet.' 'Restore finished with errors.' } else { M 'Sicherung mit Fehlern beendet.' 'Backup finished with errors.' })
        Cancelled = $(if ($isRestore) { M 'Wiederherstellung wurde auf Wunsch beendet.' 'Restore was cancelled by request.' } else { M 'Sicherung wurde auf Wunsch beendet.' 'Backup was cancelled by request.' })
    }
}

function Confirm-OperationStart {
    # Interaktive Rueckfrage. Eine Sicherung ist additiv und deshalb per Enter
    # bestaetigt; eine Wiederherstellung veraendert lokale Dateien und wird
    # deshalb per Enter abgelehnt.
    param([ValidateSet('Backup', 'Restore')][string]$OperationMode)

    $isRestore = $OperationMode -eq 'Restore'
    $answer = Read-Host $(if ($isRestore) {
        M 'Wiederherstellung starten? j/N' 'Start restore? y/N'
    } else {
        M 'Sicherung starten? J/n' 'Start backup? Y/n'
    })
    if ([string]::IsNullOrWhiteSpace($answer)) {
        $answer = if ($isRestore) { 'n' } else { 'j' }
    }
    return [bool]($answer -match '^(j|ja|y|yes)$')
}

function New-RobocopyArgument {
    # Baut die Robocopy-Argumentliste fuer einen Ordner.
    #
    # /E        kopiert auch leere Unterordner.
    # /XJ       folgt keinen Junctions und verhindert Schleifen.
    # /FFT      toleriert groebere Zeitstempel externer Dateisysteme.
    # /COPY:DAT kopiert Daten, Attribute und Zeitstempel, aber keine NTFS-ACLs.
    # Weder /MIR noch /PURGE: Am Ziel wird grundsaetzlich nichts geloescht.
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [ValidateSet('Backup', 'Restore')][string]$OperationMode,
        [int]$Threads,
        [int]$RetryCount,
        [int]$RetryWaitSeconds,
        [string]$LogFile,
        [bool]$DryRun,
        [string[]]$ExcludedFiles = @()
    )

    $arguments = @(
        $SourcePath,
        $TargetPath,
        '/E',
        '/XJ',
        '/FFT',
        "/MT:$Threads",
        "/R:$RetryCount",
        "/W:$RetryWaitSeconds",
        '/COPY:DAT',
        '/DCOPY:DAT',
        '/NP',
        "/UNILOG+:$LogFile"
    )
    if ($OperationMode -eq 'Restore') {
        # /XO nur beim Restore: neuere lokale Dateien bleiben geschuetzt.
        # Beim Backup wuerde /XO inhaltlich geaenderte Quelldateien mit
        # aelterem Zeitstempel ueberspringen; dort gewinnt die Quelle.
        $arguments += '/XO'
    }
    if ($DryRun) {
        $arguments += '/L'
    } else {
        $arguments += @('/NFL', '/NDL')
    }
    return @($arguments + @('/XF') + @($ExcludedFiles))
}

function New-RestorePreviewRecord {
    # Die Vorschau, die der Oberflaeche die Freigabeentscheidung ermoeglicht.
    # Reine Datenaufbereitung - das Schreiben bleibt beim Aufrufer.
    param(
        $Preflight,
        $FolderPlan,
        [bool]$ManifestExists,
        $ChecksumsVerifiedAt,
        [string]$IntegrityPolicy,
        [string]$SourceComputer,
        [string]$SourceUser,
        [string]$SourcePath,
        [string]$SourceDisplayName,
        [bool]$SourceComplete,
        [string]$TargetMode,
        [string]$TargetRoot,
        [bool]$IsMigration
    )

    return [pscustomobject]@{
        MissingFiles           = $Preflight.MissingFileCount
        OverwriteFiles         = $Preflight.OverwriteFileCount
        ProtectedNewerFiles    = $Preflight.ProtectedNewerFileCount
        PlannedFiles           = $Preflight.RequiredFileCount
        PlannedBytes           = $Preflight.RequiredBytes
        OverwriteExamples      = @($Preflight.OverwriteExamples)
        ChecksumManifestExists = $ManifestExists
        ChecksumsVerifiedAt    = $ChecksumsVerifiedAt
        RestoreIntegrityPolicy = $IntegrityPolicy
        SourceComputer         = $SourceComputer
        SourceUser             = $SourceUser
        SourcePath             = $SourcePath
        SourceDisplayName      = $SourceDisplayName
        SourceComplete         = $SourceComplete
        TargetMode             = $TargetMode
        TargetRoot             = $TargetRoot
        IsMigration            = $IsMigration
        FolderMappings         = @($FolderPlan | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Source = $_.Path; Target = $_.TargetPath; IsCustom = [bool]$_.IsCustom }
        })
    }
}

function Resolve-UnattendedRestoreIntegrity {
    # Integritaetsentscheidung ohne Oberflaeche (Kommandozeilenbetrieb).
    # Mit Oberflaeche entscheidet stattdessen Resolve-M24RestoreApproval
    # anhand der Freigabedatei.
    param(
        [ValidateSet('Profile', 'Folder')][string]$TargetMode,
        [ValidateSet('Verify', 'RequireVerified', 'Warn')][string]$Policy,
        [bool]$ManifestExists,
        [bool]$AlreadyVerified
    )

    $decision = [pscustomobject]@{ VerificationRequired = $false; IntegrityOverride = $false }

    # Ein separater Zielordner laesst den vorhandenen Bestand unberuehrt; eine
    # ungepruefte Kopie ist dort vertretbar und wird nur vermerkt.
    if ($TargetMode -eq 'Folder') {
        $decision.IntegrityOverride = -not $AlreadyVerified
        return $decision
    }
    if ($AlreadyVerified) { return $decision }

    switch ($Policy) {
        'RequireVerified' {
            throw (M 'Die Wiederherstellung erfordert ein bereits erfolgreich geprueftes Backup.' 'Restore requires a backup that has already passed verification.')
        }
        'Verify' {
            if (-not $ManifestExists) {
                throw (M 'Die Wiederherstellung kann nicht geprueft werden, weil kein Pruefsummenmanifest vorhanden ist.' 'Restore cannot be verified because no checksum manifest exists.')
            }
            $decision.VerificationRequired = $true
        }
        'Warn' {
            $decision.IntegrityOverride = $true
        }
    }
    return $decision
}

function Assert-SufficientFreeSpace {
    # Vergleicht je Zielwurzel den Netto-Mehrbedarf mit dem freien Platz.
    # Zu ueberschreibende Zieldateien geben ihren Platz wieder frei und zaehlen
    # nur mit der Groessendifferenz; die Reserve deckt Protokolle, Manifest und
    # Metadaten ab.
    param($AdditionalBytesByRoot)

    foreach ($targetRoot in $AdditionalBytesByRoot.Keys) {
        $spaceDisk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $targetRoot) -ErrorAction Stop
        $additionalBytes = [int64]$AdditionalBytesByRoot[$targetRoot]
        $reserveBytes = [int64][math]::Max($additionalBytes * 0.05, 200MB)
        $requiredWithReserve = $additionalBytes + $reserveBytes
        if ($requiredWithReserve -gt [int64]$spaceDisk.FreeSpace) {
            throw ((M "Nicht genug freier Speicherplatz auf {0}. Benoetigt werden voraussichtlich {1:N1} GB zusaetzlich (inkl. Reserve), frei sind {2:N1} GB." "Not enough free space on {0}. Approximately {1:N1} GB of additional space is required (including reserve); {2:N1} GB is available.") -f $targetRoot, ($requiredWithReserve / 1GB), ([int64]$spaceDisk.FreeSpace / 1GB))
        }
    }
}

function Add-CustomBackupFolderDefinitions {
    # Ergaenzt die Standardbibliotheken um gepruefte Zusatzordner. Ein
    # Zusatzordner darf weder reserviert sein noch einen bereits vergebenen
    # Namen oder Pfad einer anderen Auswahl ueberdecken.
    param(
        $StandardDefinitions,
        $SelectedFolderSpecs,
        [string]$FolderMetadataFile
    )

    $definitions = @($StandardDefinitions)
    $customSpecs = @($SelectedFolderSpecs | Where-Object { Test-IsCustomFolderSpec $_ })
    if ($customSpecs.Count -eq 0) { return $definitions }

    $existingCustomMetadata = @(Read-CustomFolderMetadata -Path $FolderMetadataFile)
    foreach ($customSpec in $customSpecs) {
        $customName = [string]$customSpec.Name
        $customPath = [string]$customSpec.Path
        Assert-ValidBackupFolderName -Name $customName
        if ([string]::IsNullOrWhiteSpace($customPath) -or -not (Test-Path -LiteralPath $customPath -PathType Container)) {
            throw ((M "Der Zusatzordner '{0}' wurde nicht gefunden." "The additional folder '{0}' was not found.") -f $customName)
        }
        $customPath = Get-NormalizedFullPath $customPath
        if ($customPath.Equals((Get-NormalizedFullPath $env:USERPROFILE), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw (M "Das gesamte Benutzerprofil kann nicht als Zusatzordner gesichert werden." "The whole user profile cannot be backed up as an additional folder.")
        }
        foreach ($existingCustom in $existingCustomMetadata) {
            if ($existingCustom.Name.Equals($customName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $existingPath = Get-NormalizedFullPath ([string]$existingCustom.OriginalPath)
                if (-not $existingPath.Equals($customPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw ((M "Der Zusatzordnername '{0}' ist im vorhandenen Backup bereits fuer '{1}' vergeben." "The additional folder name '{0}' is already used in the existing backup for '{1}'.") -f $customName, $existingPath)
                }
            }
        }
        foreach ($existingDefinition in $definitions) {
            if ($existingDefinition.Name.Equals($customName, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw ((M "Der Zusatzordnername '{0}' ist bereits vergeben." "The additional folder name '{0}' is already in use.") -f $customName)
            }
            if ($existingDefinition.Path -and (Test-IsSameOrNestedPath -FirstPath $customPath -SecondPath $existingDefinition.Path)) {
                throw ((M "Der Zusatzordner '{0}' ueberschneidet sich mit '{1}'." "The additional folder '{0}' overlaps with '{1}'.") -f $customName, $existingDefinition.Name)
            }
        }
        $definitions = @($definitions) + [pscustomobject]@{ Name = $customName; Path = $customPath; IsCustom = $true }
    }
    return @($definitions)
}

# AppData ist bewusst nicht Teil der Sicherung. Ein Pfad, der direkt dem
# gesamten Benutzerprofil entspricht, wird ebenfalls ausgeschlossen.
$folderDefinitions = @(Get-M24StandardFolderDefinitions)

$drive = Resolve-UsbDrive -Drive $UsbDrive -Silent:$Silent
# Jeder Computer und Benutzer erhaelt am Ziel einen eigenen Sicherungsordner.
$currentProfileBackupRoot = Get-M24BackupRoot -Drive $drive
$destination = if ($Mode -eq 'Restore') {
    $requestedSource = if ([string]::IsNullOrWhiteSpace($BackupSource)) { $currentProfileBackupRoot } else { $BackupSource }
    Resolve-M24RestoreSource -Drive $drive -BackupSource $requestedSource
} else {
    $currentProfileBackupRoot
}
$metadataFile = Join-Path $destination '_Sicherungsinfo.txt'
$folderMetadataFile = Join-Path $destination '_Ordner.json'
$checksumManifestFile = Join-Path $destination (Get-M24ChecksumManifestName)
$logDir = Join-Path $destination "_logs"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logInstance = "{0}_{1}" -f $PID, [guid]::NewGuid().ToString('N').Substring(0, 8)
$logPrefix = if ($Mode -eq 'Restore') { 'restore' } else { 'robocopy' }
$logFile = Join-Path $logDir ("{0}_{1}_{2}.log" -f $logPrefix, $stamp, $logInstance)
$selectedFolderSpecs = @(Read-SelectedFolderSpecs)
$restoreSourceComputer = ''
$restoreSourceUser = ''
$restoreIsMigration = $false
$resolvedRestoreTargetRoot = $null
$restoreSourceDisplayName = Split-Path -Path $destination -Leaf
$restoreSourceComplete = $false

if ($Mode -eq 'Restore') {
    $sourceIdentity = Read-RestoreSourceIdentity -MetadataFile $metadataFile
    $restoreSourceComputer = $sourceIdentity.Computer
    $restoreSourceUser = $sourceIdentity.User
    $restoreIsMigration = $sourceIdentity.IsMigration
    $restoreSourceComplete = $sourceIdentity.IsComplete

    $resolvedRestoreTargetRoot = Resolve-RestoreTargetRoot -TargetMode $RestoreTargetMode -TargetRoot $RestoreTargetRoot `
        -BackupSourcePath $destination -BackupDisplayName $restoreSourceDisplayName -SourceIdentity $sourceIdentity

    $folderDefinitions = Resolve-RestoreFolderDefinitions -BackupSourcePath $destination `
        -StandardDefinitions $folderDefinitions -FolderMetadataFile $folderMetadataFile `
        -TargetMode $RestoreTargetMode -ResolvedTargetRoot $resolvedRestoreTargetRoot `
        -IsMigration $restoreIsMigration -BackupDisplayName $restoreSourceDisplayName
} elseif ($selectedFolderSpecs.Count -gt 0) {
    $folderDefinitions = Add-CustomBackupFolderDefinitions -StandardDefinitions $folderDefinitions `
        -SelectedFolderSpecs $selectedFolderSpecs -FolderMetadataFile $folderMetadataFile
}

$backupFolders = New-FolderCopyPlan -OperationMode $Mode -FolderDefinitions $folderDefinitions `
    -BackupRootPath $destination -SelectedFolderSpecs $selectedFolderSpecs
Write-BackupStatus -Type 'STATUS' -Text $(if ($Mode -eq 'Restore') {
    M 'Wiederherstellung wird vorbereitet ...' 'Preparing restore ...'
} else {
    M 'Sicherung wird vorbereitet ...' 'Preparing backup ...'
})

Assert-FolderCopyPlanIsSafe -OperationMode $Mode -FolderPlan $backupFolders -BackupRootPath $destination

# Nur schnell verfuegbare Laufwerksinformationen abfragen. Die Bibliotheken
# werden vorher nicht komplett gescannt, damit die Sicherung zuegig startet.
$targetDisk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive) -ErrorAction Stop
$freeSpace = [int64]$targetDisk.FreeSpace
$freeSpaceGb = [math]::Round($freeSpace / 1GB, 1)
$fileSystem = if ($targetDisk.FileSystem) { $targetDisk.FileSystem } else { "unbekannt" }
$fat32Warning = $fileSystem -eq "FAT32"

# Unwichtige Windows-Metadaten und typische temporaere Dateien auslassen.
$excludedFiles = @(Get-M24DefaultExcludedFiles)

# Im Superschnell-Modus entfaellt die dateibasierte Vorpruefung vollstaendig;
# Robocopy bleibt dann die alleinige Instanz fuer den Kopierumfang. Restore
# und normale Sicherungen laufen unveraendert mit Vorpruefung.
$preflightPerformed = -not $runPolicy.SkipPreflight
$preflight = $null
$initialCancellation = Get-WorkerCancellationState
if ($initialCancellation.Requested) { Stop-M24CancelledOperation -State $initialCancellation }
if ($preflightPerformed) {
    $preflight = Get-BackupPreflight -Folders $backupFolders -ExcludedFiles $excludedFiles -OperationMode $Mode -CancelCallback { Get-WorkerCancellationState }
    if ($preflight.Cancelled) { Stop-M24CancelledOperation -State $preflight.CancellationState }
}
$postPreflightCancellation = Get-WorkerCancellationState
if ($postPreflightCancellation.Requested) { Stop-M24CancelledOperation -State $postPreflightCancellation }
if ($preflightPerformed -and $preflight.ScanWarnings.Count -gt 0) {
    # Bei einer Wiederherstellung deuten Lesefehler auf dem Sicherungsmedium
    # auf einen Defekt hin; hier bleibt der Abbruch bestehen. Bei einer
    # Sicherung (z. B. gesperrte Datei) entscheidet der Benutzer.
    if ($Mode -eq 'Restore') {
        $firstWarning = $preflight.ScanWarnings | Select-Object -First 1
        throw ((M "Die Vorpruefung konnte nicht alle Dateien der Sicherung lesen. Bitte den Sicherungsdatentraeger pruefen. Erstes Problem: {0}" "The preflight check could not read every file in the backup. Check the backup drive. First issue: {0}") -f $firstWarning)
    }
    Write-Host ""
    Write-Host ((M "WARNUNG: Die Vorpruefung konnte {0} Eintrag/Eintraege nicht lesen. Nicht lesbare Dateien koennen uebersprungen werden und die Speicherplatzschaetzung kann zu niedrig ausfallen." "WARNING: The preflight check could not read {0} item(s). Unreadable files may be skipped and the disk-space estimate may be too low.") -f $preflight.ScanWarnings.Count)
    foreach ($scanWarning in @($preflight.ScanWarnings | Select-Object -First 5)) {
        Write-Host ("  - {0}" -f $scanWarning)
    }
    if ($Silent) {
        if (-not $ApprovalFile -or -not $PreviewFile) {
            # Ohne GUI-Freigabekanal gilt weiterhin das alte, strenge Verhalten.
            throw ((M "Die Vorpruefung konnte nicht alle Dateien lesen. Der Speicherbedarf waere dadurch unzuverlaessig. Erstes Problem: {0}" "The preflight check could not read every file, making the disk-space estimate unreliable. First issue: {0}") -f ($preflight.ScanWarnings | Select-Object -First 1))
        }
        [pscustomobject]@{
            WarningCount = $preflight.ScanWarnings.Count
            Warnings = @($preflight.ScanWarnings | Select-Object -First 10)
        } | Write-AtomicJsonFile -Path $PreviewFile -Depth 3
        Write-BackupStatus -Type 'SCANWARNUNG' -Text (M 'Warnungen der Vorpruefung warten auf Freigabe.' 'Preflight warnings are awaiting approval.')
        Wait-GuiApproval -CancelMessage (M 'Sicherung vor dem Kopieren abgebrochen.' 'Backup cancelled before copying.') -ClosedMessage (M 'Die Bedienoberflaeche wurde geschlossen.' 'The user interface was closed.')
    } else {
        $confirmWarnings = Read-Host (M 'Trotzdem fortfahren? j/N' 'Continue anyway? y/N')
        if ($confirmWarnings -notmatch '^(j|ja|y|yes)$') {
            Write-Host (M "Abgebrochen." "Cancelled.")
            exit 1
        }
    }
}
if (-not $DryRun -and $preflightPerformed) {
    # Die Zielwurzeln sind oben bereits als Laufwerksbuchstaben validiert.
    Assert-SufficientFreeSpace -AdditionalBytesByRoot $preflight.AdditionalByRoot
}
if ($Mode -eq 'Backup' -and $fat32Warning -and $preflightPerformed -and $preflight.LargeFiles.Count -gt 0) {
    $examples = @($preflight.LargeFiles | Select-Object -First 3) -join '; '
    throw ((M "FAT32 kann {0} ausgewaehlte Datei(en) ab 4 GB nicht speichern. Verwenden Sie exFAT oder NTFS. Beispiele: {1}" "FAT32 cannot store {0} selected file(s) of 4 GB or larger. Use exFAT or NTFS. Examples: {1}") -f $preflight.LargeFiles.Count, $examples)
}

$restoreIntegrityVerified = $false
$restoreIntegrityOverride = $false
$restoreIntegrityVerificationPerformed = $false
$restoreVerificationRequired = $false
if ($Mode -eq 'Restore') {
    # Integritaetsstatus fuer die Freigabeentscheidung: Gibt es ein
    # Pruefsummenmanifest und wann wurde es zuletzt vollstaendig geprueft?
    $checksumManifestExists = Test-Path -LiteralPath $checksumManifestFile -PathType Leaf
    $checksumsVerifiedAt = if ($checksumManifestExists) { Get-M24ChecksumVerifiedDate -MetadataFile $metadataFile } else { $null }
    $restoreIntegrityVerified = [bool]$checksumsVerifiedAt
    if ($PreviewFile) {
        New-RestorePreviewRecord -Preflight $preflight -FolderPlan $backupFolders `
            -ManifestExists $checksumManifestExists -ChecksumsVerifiedAt $checksumsVerifiedAt `
            -IntegrityPolicy $RestoreIntegrityPolicy `
            -SourceComputer $restoreSourceComputer -SourceUser $restoreSourceUser `
            -SourcePath $destination -SourceDisplayName $restoreSourceDisplayName `
            -SourceComplete ([bool]$restoreSourceComplete) `
            -TargetMode $RestoreTargetMode `
            -TargetRoot $(if ($RestoreTargetMode -eq 'Folder') { $resolvedRestoreTargetRoot } else { $env:USERPROFILE }) `
            -IsMigration ([bool]$restoreIsMigration) |
            Write-AtomicJsonFile -Path $PreviewFile -Depth 4
    }
    if ($Silent) {
        if (-not $ApprovalFile) { throw (M 'Im stillen Restore-Modus ist eine Freigabedatei erforderlich.' 'Silent restore mode requires an approval file.') }
        Write-BackupStatus -Type 'VORSCHAU' -Text (M 'Konfliktvorschau ist bereit.' 'Conflict preview is ready.')
        $approvalValue = Wait-GuiApproval -CancelMessage (M 'Wiederherstellung vor dem Kopieren abgebrochen.' 'Restore cancelled before copying.') -ClosedMessage (M 'Die Bedienoberflaeche wurde geschlossen.' 'The user interface was closed.') `
            -AllowedValues @('continue-verified', 'verify-then-continue', 'continue-unverified', 'continue', 'cancel')
        if ($approvalValue -eq 'cancel') {
            Stop-M24CancelledOperation -State ([pscustomobject]@{ Requested = $true; Reason = 'User' })
        }
        if ($RestoreTargetMode -eq 'Folder') {
            $restoreIntegrityOverride = -not $restoreIntegrityVerified
        } else {
            $approvalDecision = Resolve-M24RestoreApproval -Policy $RestoreIntegrityPolicy -ApprovalValue $approvalValue `
                -ManifestExists $checksumManifestExists -AlreadyVerified $restoreIntegrityVerified
            if ($approvalDecision.Cancelled) {
                Stop-M24CancelledOperation -State ([pscustomobject]@{ Requested = $true; Reason = 'User' })
            }
            if (-not $approvalDecision.Allowed) {
                throw (M 'Die Restore-Freigabe entspricht nicht der gewaehlten Integritaetsrichtlinie.' 'The restore approval does not satisfy the selected integrity policy.')
            }
            $restoreVerificationRequired = [bool]$approvalDecision.RequiresVerification
            $restoreIntegrityOverride = [bool]$approvalDecision.UnverifiedOverride
        }
    } else {
        $integrityDecision = Resolve-UnattendedRestoreIntegrity -TargetMode $RestoreTargetMode `
            -Policy $RestoreIntegrityPolicy -ManifestExists $checksumManifestExists `
            -AlreadyVerified $restoreIntegrityVerified
        $restoreVerificationRequired = [bool]$integrityDecision.VerificationRequired
        $restoreIntegrityOverride = [bool]$integrityDecision.IntegrityOverride
    }
}

$bitLockerStatus = if ($runPolicy.SkipBitLockerStatus) {
    M 'BitLocker-Status: uebersprungen (Superschnell-Modus).' 'BitLocker status: skipped (super fast mode).'
} else {
    Get-BitLockerStatusText -Drive $drive
}

Write-OperationSummary -OperationMode $Mode -FolderPlan $backupFolders -BackupRootPath $destination `
    -FreeSpaceGb $freeSpaceGb -FileSystem $fileSystem -BitLockerStatus $bitLockerStatus `
    -PreflightPerformed $preflightPerformed -Preflight $preflight -Fat32Warning ([bool]$fat32Warning) `
    -ManifestExists ([bool]$checksumManifestExists) -ChecksumsVerifiedAt $checksumsVerifiedAt `
    -IsGerman ([bool]$script:isGerman)

if (-not $Silent) {
    if (-not (Confirm-OperationStart -OperationMode $Mode)) {
        Write-Host (M "Abgebrochen." "Cancelled.")
        exit 1
    }
}

$beforeLockCancellation = Get-WorkerCancellationState
if ($beforeLockCancellation.Requested) { Stop-M24CancelledOperation -State $beforeLockCancellation }

# Ab der Bestaetigung stabilisiert die Sperre den gesamten Bestand - auch
# waehrend einer vorgeschalteten Restore-Integritaetspruefung.
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$script:operationLockFile = Join-Path $destination '_backup.lock'
try {
    $script:operationLockStream = [System.IO.File]::Open(
        $script:operationLockFile,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    $lockText = [System.Text.Encoding]::UTF8.GetBytes("PID=$PID`r`nStarted=$(Get-Date -Format 'o')`r`n")
    $script:operationLockStream.SetLength(0)
    $script:operationLockStream.Write($lockText, 0, $lockText.Length)
    $script:operationLockStream.Flush($true)
} catch {
    Exit-OperationLock
    throw (M 'Fuer dieses Sicherungsziel laeuft bereits ein anderer Sicherungs- oder Wiederherstellungsvorgang.' 'Another backup or restore operation is already running for this destination.')
}

if ($Mode -eq 'Restore' -and $restoreVerificationRequired) {
    Write-BackupStatus -Type 'RESTOREPRUEFUNG' -Text (M 'Backup-Integritaet wird vor der Wiederherstellung geprueft.' 'Backup integrity is being verified before restore.')
    $restoreIntegrityVerificationPerformed = $true
    # Das Manifest beschreibt den gesamten Backup-Bestand. Auch bei einer
    # Teilwiederherstellung muss deshalb das komplette Backup geprüft werden;
    # andernfalls würden Manifest-Einträge nicht ausgewählter Ordner fälschlich
    # als fehlend gelten.
    $restoreIntegrityFolders = @(Get-ChildItem -LiteralPath $destination -Directory -Force -ErrorAction Stop |
        Where-Object { -not $_.Name.StartsWith('_') } |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.FullName } })
    $verification = Test-M24ChecksumManifest -Folders $restoreIntegrityFolders -ManifestPath $checksumManifestFile -ExcludedFiles $excludedFiles `
        -StatusCallback { param($current, $total, $name) Write-BackupStatus -Type 'RESTOREPRUEFUNG' -Fields $current, $total, $name } `
        -ProgressCallback { param($files, $bytes, $folder) Write-BackupStatus -Type 'HASHFORTSCHRITT' -Fields $files, $bytes } `
        -CancelCallback { return (Get-WorkerCancellationState).Requested }
    if ($verification.Cancelled) {
        $verificationCancellation = Get-WorkerCancellationState
        if (-not $verificationCancellation.Requested) { $verificationCancellation = [pscustomobject]@{ Requested = $true; Reason = 'User' } }
        Stop-M24CancelledOperation -State $verificationCancellation
    }
    if ($verification.MissingManifest -or [int]$verification.ErrorCount -gt 0) {
        $firstIntegrityError = @($verification.Errors | Select-Object -First 1)
        throw ((M 'Die Integritaetspruefung ist fehlgeschlagen. Die Wiederherstellung wurde nicht gestartet. Erstes Problem: {0}' 'Integrity verification failed. Restore was not started. First problem: {0}') -f $firstIntegrityError)
    }
    Set-M24ChecksumVerifiedMetadata -MetadataFile $metadataFile
    $restoreIntegrityVerified = $true
    $checksumsVerifiedAt = Get-M24ChecksumVerifiedDate -MetadataFile $metadataFile
}
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
if ($Mode -eq 'Backup' -and -not $DryRun) {
    $metadataContent = @(
        'Bibliothekssicherung', '', "Computer: $env:COMPUTERNAME", "Benutzer: $env:USERNAME",
        "Letzter Sicherungsversuch: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "Quelle: $env:USERPROFILE",
        "Ziel: $destination", "Ordner: $($backupFolders.Name -join ', ')",
        'Sicherungsart: Fortlaufende Sicherheitskopie; am Ziel werden keine Dateien geloescht.'
    ) -join [Environment]::NewLine
    Write-M24AtomicTextFile -Path $metadataFile -Content ($metadataContent + [Environment]::NewLine)
    $script:backupMetadataStarted = $true
}

$maxCode = 0
$failedFolders = @()
$successfulFolders = @()
$foldersWithHints = @()
$robocopyWarnings = @()
$filesCopiedThisRun = $false
$folderNumber = 0
$folderCount = @($backupFolders).Count
$backupStartedAt = Get-Date
# Alle betriebsartabhaengigen Bezeichnungen dieses Laufs an einer Stelle.
$operationLabels = Get-OperationLabels -OperationMode $Mode -DryRun ([bool]$DryRun)
$operationName = $operationLabels.Operation
$successMessage = $operationLabels.Success
$failureMessage = $operationLabels.Failure
$preflightNoticeLogLines = @()
if ($preflightPerformed -and $preflight.ScanNotices.Count -gt 0) {
    $preflightNoticeLogLines += ((M "Hinweis: Die Vorpruefung hat {0} nicht lesbare Junction(s) erkannt. Sie werden wie beim Kopieren mit Robocopy /XJ absichtlich uebersprungen; es ist keine Benutzeraktion erforderlich." "Note: The preflight check found {0} unreadable junction(s). They are intentionally skipped, as they are during copying with Robocopy /XJ; no user action is required.") -f $preflight.ScanNotices.Count)
    foreach ($scanNotice in $preflight.ScanNotices) {
        $preflightNoticeLogLines += ("  - {0}" -f $scanNotice)
    }
}

# Allgemeine Angaben vor den Robocopy-Ausgaben in dieselbe Logdatei schreiben.
New-OperationLogHeader -OperationMode $Mode -OperationName $operationName -BackupRootPath $destination `
    -FreeSpaceGb $freeSpaceGb -FileSystem $fileSystem -BitLockerStatus $bitLockerStatus `
    -Threads $Threads -RunPolicy $runPolicy -DryRun ([bool]$DryRun) `
    -PreflightNotices $preflightNoticeLogLines `
    -IntegrityPolicy $RestoreIntegrityPolicy -IntegrityVerified ([bool]$restoreIntegrityVerified) `
    -IntegrityOverride ([bool]$restoreIntegrityOverride) `
    -IntegrityVerificationPerformed ([bool]$restoreIntegrityVerificationPerformed) `
    -SourceComputer $restoreSourceComputer -SourceUser $restoreSourceUser `
    -TargetMode $RestoreTargetMode -IsMigration ([bool]$restoreIsMigration) `
    -TargetRoot $(if ($RestoreTargetMode -eq 'Folder') { $resolvedRestoreTargetRoot } else { $env:USERPROFILE }) `
    -FolderPlan $backupFolders |
    Add-Content -LiteralPath $logFile -Encoding Unicode

foreach ($folder in $backupFolders) {
    $folderCancellation = Get-WorkerCancellationState
    if ($folderCancellation.Requested) { Stop-M24CancelledOperation -State $folderCancellation }
    $folderNumber++
    $target = $folder.TargetPath
    $displayFolderName = Get-M24FolderDisplayName $folder.Name $script:isGerman
    Write-Host $(if ($Mode -eq 'Restore') { (M "Stelle {0} wieder her..." "Restoring {0}...") -f $displayFolderName } else { (M "Sichere {0}..." "Backing up {0}...") -f $displayFolderName })
    Write-BackupStatus -Type 'FORTSCHRITT' -Fields $folderNumber, $folderCount, $folder.Name

    $robocopyArgs = New-RobocopyArgument -SourcePath $folder.Path -TargetPath $target `
        -OperationMode $Mode -Threads $Threads -RetryCount $runPolicy.RetryCount `
        -RetryWaitSeconds $runPolicy.RetryWaitSeconds -LogFile $logFile `
        -DryRun ([bool]$DryRun) -ExcludedFiles $excludedFiles

    $robocopyResult = Invoke-RobocopyWithCancel -Arguments $robocopyArgs -CancelFile $CancelFile -CurrentFolder $folderNumber -TotalFolders $folderCount -FolderName $folder.Name
    if ($robocopyResult.Cancelled) {
        Add-Content -LiteralPath $logFile -Encoding Unicode -Value ((M "Abbruch: Robocopy wurde waehrend '{0}' beendet." "Cancellation: Robocopy was stopped while processing '{0}'.") -f $displayFolderName)
        if ($robocopyResult.HardStopped) {
            Add-Content -LiteralPath $logFile -Encoding Unicode -Value (M "Warnung: Die zuletzt aktive Datei kann unvollstaendig im Ziel liegen. Starten Sie die Sicherung erneut oder pruefen Sie das Backup." "Warning: The last active file may remain incomplete at the destination. Run the backup again or verify the backup.")
        }
        Stop-M24CancelledOperation -State $robocopyResult.CancellationState -InterruptedFolder $folder.Name -HardStopped ([bool]$robocopyResult.HardStopped)
    }
    $code = [int]$robocopyResult.ExitCode
    if (($code -band 1) -ne 0) { $filesCopiedThisRun = $true }

    # Robocopy verwendet die Codes 0 bis 7 fuer erfolgreiche Laeufe bzw.
    # Ergebnisse mit Hinweisen. Erst ab Code 8 liegt ein Kopierfehler vor.
    if ($code -le 7) {
        $successfulFolders += $folder.Name
        if ($code -ge 2) {
            $foldersWithHints += $folder.Name
            Write-Host ((M "  OK mit Hinweisen ({0}), Robocopy-Code {1}" "  OK with notes ({0}), Robocopy code {1}") -f $displayFolderName, $code)
            if (($code -band 4) -ne 0) {
                $warning = (M "Robocopy meldet nicht uebereinstimmende Dateien in '{0}'. Moeglicherweise waren Dateien geoeffnet oder wurden waehrend des Kopierens geaendert." "Robocopy reported mismatched files in '{0}'. Files may have been open or changed during copying.") -f $displayFolderName
                $robocopyWarnings += $warning
                Write-Host ("  {0}" -f $warning)
            }
        } else {
            Write-Host ("  OK ({0})" -f $displayFolderName)
        }
    } else {
        Write-Host ((M "  FEHLER ({0}), Robocopy-Code {1}" "  ERROR ({0}), Robocopy code {1}") -f $displayFolderName, $code)
        $failedFolders += $folder.Name
    }
    if ($code -gt $maxCode) {
        $maxCode = $code
    }
}

$afterFoldersCancellation = Get-WorkerCancellationState
if ($afterFoldersCancellation.Requested) { Stop-M24CancelledOperation -State $afterFoldersCancellation }

Write-Host ""
if ($maxCode -le 7) {
    $checksumResult = $null
    if ($Mode -eq 'Backup' -and -not $DryRun) {
        if ($runPolicy.SkipChecksums) {
            $checksumSkipNote = if ($runPolicy.SuperFast) {
                M "Pruefsummen: wegen Superschnell-Modus uebersprungen." "Checksums: skipped because of super fast mode."
            } else {
                M "Pruefsummen: uebersprungen." "Checksums: skipped."
            }
            Add-Content -LiteralPath $logFile -Encoding Unicode -Value $checksumSkipNote
        } else {
            # Das Manifest beschreibt den gesamten additiven Zielbestand, nicht nur
            # die in diesem Lauf ausgewaehlten Ordner.
            $checksumFolders = @(Get-ChildItem -LiteralPath $destination -Directory -Force -ErrorAction Stop |
                Where-Object { -not $_.Name.StartsWith('_') } |
                ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.FullName } })
            $checksumResult = Update-M24ChecksumManifest `
                -Folders $checksumFolders `
                -ManifestPath $checksumManifestFile `
                -ExcludedFiles $excludedFiles `
                -StatusCallback { param($current, $total, $name) Write-BackupStatus -Type 'PRUEFSUMME' -Fields $current, $total, $name } `
                -ProgressCallback { param($files, $bytes, $folder) Write-BackupStatus -Type 'HASHFORTSCHRITT' -Fields $files, $bytes } `
                -CancelCallback { return (Get-WorkerCancellationState).Requested }
            if ($checksumResult.Cancelled) {
                $checksumCancellation = Get-WorkerCancellationState
                if (-not $checksumCancellation.Requested) { $checksumCancellation = [pscustomobject]@{ Requested = $true; Reason = 'User' } }
                Stop-M24CancelledOperation -State $checksumCancellation
            }
            Add-Content -LiteralPath $logFile -Encoding Unicode -Value ((M "Pruefsummen: {0} Dateien; {1} neu berechnet; {2} wiederverwendet." "Checksums: {0} files; {1} recalculated; {2} reused.") -f $checksumResult.Files, $checksumResult.HashedFiles, $checksumResult.ReusedFiles)
            # Getrennte Laufzeiten machen im Nachhinein erkennbar, ob Datentraeger,
            # Verzeichnisaufzaehlung oder CPU den Lauf begrenzt hat.
            Add-Content -LiteralPath $logFile -Encoding Unicode -Value ((M "Pruefsummen-Laufzeit: {0:N1} s gesamt; Verzeichnisaufzaehlung {1:N1} s; Hashen {2:N1} s fuer {3:N0} MiB ({4:N1} MiB/s); Manifest lesen {5:N1} s, schreiben {6:N1} s; sonstiger Aufwand {7:N1} s; wiederverwendet {8:N0} MiB." "Checksum runtime: {0:N1} s total; directory enumeration {1:N1} s; hashing {2:N1} s for {3:N0} MiB ({4:N1} MiB/s); manifest read {5:N1} s, write {6:N1} s; other overhead {7:N1} s; reused {8:N0} MiB.") -f `
                ([double]$checksumResult.TotalMilliseconds / 1000), `
                ([double]$checksumResult.EnumerationMilliseconds / 1000), `
                ([double]$checksumResult.HashMilliseconds / 1000), `
                ([double]$checksumResult.HashedBytes / 1MB), `
                ([double]$checksumResult.AverageHashMegabytesPerSecond), `
                ([double]$checksumResult.ManifestReadMilliseconds / 1000), `
                ([double]$checksumResult.ManifestWriteMilliseconds / 1000), `
                ([double]$checksumResult.OverheadMilliseconds / 1000), `
                ([double]$checksumResult.ReusedBytes / 1MB))
            if ([int64]$checksumResult.SkippedDeviceFiles -gt 0) {
                Add-Content -LiteralPath $logFile -Encoding Unicode -Value ((M "Hinweis: {0} Datei(en) mit reserviertem Geraetenamen (z. B. 'nul') wurden ohne Pruefsumme uebersprungen." "Note: {0} file(s) with reserved device names (e.g. 'nul') were skipped without a checksum.") -f $checksumResult.SkippedDeviceFiles)
            }
        }
    }
    $beforeSuccessCancellation = Get-WorkerFinalCancellationState
    if ($beforeSuccessCancellation.Requested) { Stop-M24CancelledOperation -State $beforeSuccessCancellation }
    $finishedAt = Get-Date
    $remainingDisk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive) -ErrorAction SilentlyContinue
    if ($Mode -eq 'Backup' -and -not $DryRun) {
        $customBackupFolders = @($backupFolders | Where-Object { $_.IsCustom })
        if ($customBackupFolders.Count -gt 0 -or (Test-Path -LiteralPath $folderMetadataFile -PathType Leaf)) {
            $mergedMetadata = @{}
            foreach ($existingCustom in Read-CustomFolderMetadata -Path $folderMetadataFile) {
                $mergedMetadata[[string]$existingCustom.Name] = [pscustomobject]@{
                    Name = [string]$existingCustom.Name
                    OriginalPath = [string]$existingCustom.OriginalPath
                    BackedUpAt = [string]$existingCustom.BackedUpAt
                }
            }
            foreach ($customFolder in $customBackupFolders) {
                $mergedMetadata[[string]$customFolder.Name] = [pscustomobject]@{
                    Name = [string]$customFolder.Name
                    OriginalPath = [string]$customFolder.Path
                    BackedUpAt = $finishedAt.ToString('o')
                }
            }
            $folderMetadataJson = @($mergedMetadata.Values | Sort-Object Name) | ConvertTo-Json -Depth 4
            Write-M24AtomicTextFile -Path $folderMetadataFile -Content ($folderMetadataJson + [Environment]::NewLine)
        }
    }
    if ($Mode -eq 'Backup' -and -not $DryRun) { Set-BackupResultMetadata -Path $metadataFile -Result 'Erfolgreich abgeschlossen' }
    Write-BackupStatus -Type "FERTIG" -Text $successMessage
    Write-Host $successMessage
    $folderSummaryLabel = if ($Mode -eq 'Restore') { M 'Wiederhergestellte Ordner' 'Restored folders' } else { M 'Gesicherte Ordner' 'Backed-up folders' }
    $localizedSuccessfulFolders = @($successfulFolders | ForEach-Object { Get-M24FolderDisplayName $_ $script:isGerman })
    Write-Host ("{0}: {1}" -f $folderSummaryLabel, ($localizedSuccessfulFolders -join ", "))
    if ($foldersWithHints) {
        $localizedHintFolders = @($foldersWithHints | ForEach-Object { Get-M24FolderDisplayName $_ $script:isGerman })
        Write-Host ((M "Ordner mit Hinweisen: {0}" "Folders with notes: {0}") -f ($localizedHintFolders -join ", "))
    }
    Write-Host $(if ($Mode -eq 'Restore') { (M "Sicherungsquelle: {0}" "Backup source: {0}") -f $destination } else { (M "Ziel: {0}" "Destination: {0}") -f $destination })
    Write-Host "Log:  $logFile"
    if ($ResultFile) {
        New-BackupResultRecord -Values @{
            Success = $true
            Message = $successMessage
            Destination = $destination
            LogFile = $logFile
            StartedAt = $backupStartedAt.ToString('o')
            FinishedAt = $finishedAt.ToString('o')
            DurationSeconds = [math]::Round(($finishedAt - $backupStartedAt).TotalSeconds, 1)
            SelectedFolders = @($backupFolders.Name)
            SuccessfulFolders = @($successfulFolders)
            HintFolders = @($foldersWithHints)
            FailedFolders = @()
            RobocopyWarnings = @($robocopyWarnings)
            RemainingBytes = $(if ($remainingDisk) { [int64]$remainingDisk.FreeSpace } else { $null })
            # Array-Subexpression statt $(...): Letztere wuerde ein leeres
            # Array zu AutomationNull entrollen und im JSON "{}" erzeugen.
            ScanWarnings = @(if ($preflightPerformed) { $preflight.ScanWarnings })
            ChecksumFiles = $(if ($checksumResult) { $checksumResult.Files } else { 0 })
            HashedFiles = $(if ($checksumResult) { $checksumResult.HashedFiles } else { 0 })
            ReusedChecksums = $(if ($checksumResult) { $checksumResult.ReusedFiles } else { 0 })
        } | Write-AtomicJsonFile -Path $ResultFile -Depth 4
    }
    Exit-OperationLock
    exit 0
}

Write-Host $failureMessage
if ($Mode -eq 'Backup' -and -not $DryRun) { Set-BackupResultMetadata -Path $metadataFile -Result 'Mit Fehlern beendet' }
Write-BackupStatus -Type "FEHLER" -Text ((M "Fehler in: {0}" "Errors in: {0}") -f ($failedFolders -join ", "))
$localizedFailedFolders = @($failedFolders | ForEach-Object { Get-M24FolderDisplayName $_ $script:isGerman })
Write-Host ((M "Betroffene Ordner: {0}" "Affected folders: {0}") -f ($localizedFailedFolders -join ", "))
Write-Host ((M "Bitte Log pruefen: {0}" "Review the log: {0}") -f $logFile)
if ($ResultFile) {
    $partialCopy = $filesCopiedThisRun
    $failureResultMessage = if ($partialCopy -and $Mode -eq 'Backup') {
        M 'Die Sicherung ist unvollständig: Ein Teil der Dateien wurde kopiert, mindestens eine Datei konnte jedoch nicht kopiert werden. Eine sichere Wiederherstellung ist erst nach einem erfolgreichen neuen Lauf möglich.' 'The backup is incomplete: Some files were copied, but at least one file could not be copied. Safe restore requires a new successful run.'
    } elseif ($partialCopy -and $Mode -eq 'Restore') {
        M 'Die Wiederherstellung ist unvollständig: Ein Teil der Dateien wurde wiederhergestellt, mindestens eine Datei konnte jedoch nicht kopiert werden.' 'The restore is incomplete: Some files were restored, but at least one file could not be copied.'
    } else {
        M 'Vorgang mit Kopierfehlern beendet.' 'Operation finished with copy errors.'
    }
    New-BackupResultRecord -Values @{
        Message = $failureResultMessage
        Destination = $destination
        LogFile = $logFile
        StartedAt = $backupStartedAt.ToString('o')
        SuccessfulFolders = @($successfulFolders)
        HintFolders = @($foldersWithHints)
        FailedFolders = @($failedFolders)
        RobocopyWarnings = @($robocopyWarnings)
        PartialCopy = $partialCopy
    } | Write-AtomicJsonFile -Path $ResultFile -Depth 4
}
Exit-OperationLock
exit $maxCode
