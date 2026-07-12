<#
Sichert die persoenlichen Windows-Bibliotheksordner des angemeldeten Benutzers
mit Robocopy auf einen USB-Stick oder ein anderes ausgewaehltes Laufwerk.

Beispiele:
  .\Bibliothekssicherung.ps1
  .\Bibliothekssicherung.ps1 -UsbDrive E:
  .\Bibliothekssicherung.ps1 -UsbDrive E: -Silent
#>
param(
    [ValidateSet('Backup', 'Restore')]
    [string]$Mode = 'Backup',
    # GUI-Prozess fuer einen Restore-Handshake ohne starren Timeout.
    [int]$ParentProcessId = 0,
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
    # Anzahl der parallelen Robocopy-Threads.
    [int]$Threads = 8
)

# Behandelt auch Fehler ausserhalb einzelner Funktionen als Abbruch.
$ErrorActionPreference = 'Stop'
$script:isGerman = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'de'
function M {
    param([string]$German, [string]$English)
    if ($script:isGerman) { return $German }
    return $English
}

function Get-LocalizedFolderName {
    param([string]$Name)
    if ($script:isGerman) { return $Name }
    $names = @{
        'Desktop'='Desktop'; 'Dokumente'='Documents'; 'Downloads'='Downloads'; 'Bilder'='Pictures'
        'Musik'='Music'; 'Videos'='Videos'; 'Favoriten'='Favorites'; 'Gespeicherte Spiele'='Saved Games'; 'Kontakte'='Contacts'
    }
    if ($names.ContainsKey($Name)) { return $names[$Name] }
    return $Name
}

function Write-AtomicTextFile {
    param([string]$Path, [string]$Content)

    $temporaryFile = "{0}.{1}.tmp" -f $Path, [guid]::NewGuid().ToString('N')
    $backupFile = "{0}.{1}.bak" -f $Path, [guid]::NewGuid().ToString('N')
    try {
        [System.IO.File]::WriteAllText($temporaryFile, $Content, (New-Object System.Text.UTF8Encoding($true)))
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

trap {
    if ($StatusFile) {
        try {
            Write-AtomicTextFile -Path $StatusFile -Content ("FEHLER|{0}" -f $_.Exception.Message)
        } catch {
            # Ein Fehler beim optionalen GUI-Status darf den Originalfehler nicht verdecken.
        }
    }
    if ($ResultFile) {
        try {
            [pscustomobject]@{ Success = $false; Cancelled = $false; Mode = $Mode; Message = $_.Exception.Message; FinishedAt = (Get-Date).ToString('o') } |
                ConvertTo-Json | Set-Content -LiteralPath $ResultFile -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch {}
    }
    Write-Host ""
    Write-Host (M "Der Vorgang konnte nicht abgeschlossen werden." "The operation could not be completed.")
    Write-Host ((M "Grund: {0}" "Reason: {0}") -f $_.Exception.Message)
    Write-Host (M "Bitte pruefen Sie Laufwerk und Auswahl und starten Sie den Vorgang erneut." "Check the drive and selection, then start the operation again.")
    exit 10
}

if (-not $Silent) {
    Clear-Host
}

if ($Threads -lt 1 -or $Threads -gt 128) {
    throw (M "Der Parameter -Threads muss zwischen 1 und 128 liegen." "The -Threads parameter must be between 1 and 128.")
}

function Write-BackupStatus {
    param(
        [string]$Type,
        [string]$Text
    )

    if ($StatusFile) {
        try {
            Write-AtomicTextFile -Path $StatusFile -Content ("{0}|{1}" -f $Type, $Text)
        } catch {
            # Die Sicherung laeuft weiter, falls nur die GUI-Statusdatei nicht schreibbar ist.
        }
    }
}

function Wait-GuiApproval {
    param(
        [string]$CancelMessage,
        [string]$ClosedMessage
    )

    # Wartet auf die Freigabedatei der GUI. Abbruchsignal und ein Ende des
    # GUI-Prozesses beenden den Worker kontrolliert; ohne GUI-Prozess-ID
    # gilt ein Zeitlimit von zehn Minuten.
    $approvalDeadline = (Get-Date).AddMinutes(10)
    while (-not (Test-Path -LiteralPath $ApprovalFile)) {
        if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) {
            if ($ResultFile) {
                [pscustomobject]@{ Success = $false; Cancelled = $true; Mode = $Mode; Message = $CancelMessage } |
                    ConvertTo-Json | Set-Content -LiteralPath $ResultFile -Encoding UTF8
            }
            Write-BackupStatus -Type 'ABGEBROCHEN' -Text $CancelMessage
            exit 20
        }
        if ($ParentProcessId -gt 0) {
            if (-not (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)) {
                if ($ResultFile) {
                    [pscustomobject]@{ Success = $false; Cancelled = $true; Mode = $Mode; Message = $ClosedMessage } |
                        ConvertTo-Json | Set-Content -LiteralPath $ResultFile -Encoding UTF8
                }
                Write-BackupStatus -Type 'ABGEBROCHEN' -Text $ClosedMessage
                exit 20
            }
        } elseif ((Get-Date) -gt $approvalDeadline) {
            throw (M 'Die Freigabe ist abgelaufen.' 'The approval timed out.')
        }
        Start-Sleep -Milliseconds 200
    }
    $approvalValue = (Get-Content -LiteralPath $ApprovalFile -Raw -ErrorAction Stop).Trim()
    if ($approvalValue -cne 'continue') { throw (M 'Die Freigabedatei enthaelt keine gueltige Bestaetigung.' 'The approval file does not contain a valid confirmation.') }
}

function Get-BackupPreflight {
    param(
        [array]$Folders,
        [string[]]$ExcludedFiles
    )

    [int64]$totalBytes = 0
    [int64]$requiredBytes = 0
    [int64]$fileCount = 0
    [int64]$requiredFileCount = 0
    $largeFiles = @()
    $scanWarnings = @()
    $requiredByRoot = @{}
    [int64]$missingFileCount = 0
    [int64]$overwriteFileCount = 0
    [int64]$protectedNewerFileCount = 0
    $overwriteExamples = @()
    $index = 0

    foreach ($folder in $Folders) {
        $index++
        Write-BackupStatus -Type 'PRUEFUNG' -Text ("{0}|{1}|{2}" -f $index, @($Folders).Count, $folder.Name)
        try {
            $scanErrors = @()
            $files = Get-ChildItem -LiteralPath $folder.Path -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +scanErrors
            foreach ($file in $files) {
                $excluded = $false
                foreach ($pattern in $ExcludedFiles) {
                    if ($file.Name -like $pattern) { $excluded = $true; break }
                }
                if ($excluded) { continue }

                $fileCount++
                $totalBytes += $file.Length
                if ($file.Length -ge 4GB) { $largeFiles += $file.FullName }

                $relative = $file.FullName.Substring($folder.Path.TrimEnd('\').Length).TrimStart('\')
                $targetFile = Join-Path $folder.TargetPath $relative
                $needsCopy = $true
                if (Test-Path -LiteralPath $targetFile -PathType Leaf) {
                    try {
                        $existing = Get-Item -LiteralPath $targetFile -Force
                        $timeDifference = ($file.LastWriteTimeUtc - $existing.LastWriteTimeUtc).TotalSeconds
                        $needsCopy = ($timeDifference -gt 2) -or (([math]::Abs($timeDifference) -le 2) -and ($file.Length -ne $existing.Length))
                        if ($needsCopy) {
                            $overwriteFileCount++
                            if ($overwriteExamples.Count -lt 10) { $overwriteExamples += $targetFile }
                        } elseif ($timeDifference -lt -2) {
                            $protectedNewerFileCount++
                        }
                    } catch { $needsCopy = $true }
                } else {
                    $missingFileCount++
                }
                if ($needsCopy) {
                    $requiredFileCount++
                    $requiredBytes += $file.Length
                    $targetRoot = [System.IO.Path]::GetPathRoot($folder.TargetPath).TrimEnd('\')
                    if (-not $requiredByRoot.ContainsKey($targetRoot)) { $requiredByRoot[$targetRoot] = [int64]0 }
                    $requiredByRoot[$targetRoot] = [int64]$requiredByRoot[$targetRoot] + $file.Length
                }
            }
            foreach ($scanError in $scanErrors) {
                $scanWarnings += ("{0}: {1}" -f $folder.Name, $scanError.Exception.Message)
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
        RequiredByRoot = $requiredByRoot
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

    $cmd = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
    if (-not $cmd) {
        return "BitLocker-Status konnte nicht ermittelt werden. Dies bedeutet nicht, dass BitLocker deaktiviert ist."
    }

    # Die Abfrage kann trotz Admin-Konto scheitern, wenn PowerShell nicht
    # erhoeht gestartet wurde. Deshalb wird daraus kein Sicherungsfehler.
    try {
        $volume = Get-BitLockerVolume -MountPoint $Drive -ErrorAction Stop
        return "BitLocker: $($volume.ProtectionStatus)"
    } catch {
        return "BitLocker-Status konnte nicht ermittelt werden. Dies bedeutet nicht, dass BitLocker deaktiviert ist."
    }
}

function Get-UserShellFolder {
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

function Assert-BackupIdentity {
    param([string]$MetadataFile)

    if (-not (Test-Path -LiteralPath $MetadataFile -PathType Leaf)) {
        throw (M "Die Sicherungsmetadaten fehlen. Eine sichere Zuordnung zu Computer und Benutzer ist nicht moeglich." "Backup metadata is missing. The backup cannot be safely matched to this computer and user.")
    }
    $metadataLines = @(Get-Content -LiteralPath $MetadataFile -ErrorAction Stop)
    $metadataComputerLine = $metadataLines | Where-Object { $_ -like 'Computer:*' } | Select-Object -First 1
    $metadataUserLine = $metadataLines | Where-Object { $_ -like 'Benutzer:*' } | Select-Object -First 1
    $metadataComputer = if ($metadataComputerLine) { ($metadataComputerLine -replace '^Computer:\s*', '').Trim() } else { '' }
    $metadataUser = if ($metadataUserLine) { ($metadataUserLine -replace '^Benutzer:\s*', '').Trim() } else { '' }
    if (-not $metadataComputer.Equals($env:COMPUTERNAME, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $metadataUser.Equals($env:USERNAME, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ((M "Die Sicherung gehoert zu Computer '{0}' und Benutzer '{1}', nicht zu diesem Profil." "The backup belongs to computer '{0}' and user '{1}', not to this profile.") -f $metadataComputer, $metadataUser)
    }
}

# AppData ist bewusst nicht Teil der Sicherung. Ein Pfad, der direkt dem
# gesamten Benutzerprofil entspricht, wird ebenfalls ausgeschlossen.
$folderDefinitions = @(
    [pscustomobject]@{ Name = "Desktop";   Path = [Environment]::GetFolderPath("Desktop") },
    [pscustomobject]@{ Name = "Dokumente"; Path = [Environment]::GetFolderPath("MyDocuments") },
    [pscustomobject]@{ Name = "Downloads"; Path = Get-UserShellFolder -Name "{374DE290-123F-4565-9164-39C4925E467B}" -Fallback (Join-Path $env:USERPROFILE "Downloads") },
    [pscustomobject]@{ Name = "Bilder";    Path = [Environment]::GetFolderPath("MyPictures") },
    [pscustomobject]@{ Name = "Musik";     Path = [Environment]::GetFolderPath("MyMusic") },
    [pscustomobject]@{ Name = "Videos";    Path = [Environment]::GetFolderPath("MyVideos") },
    [pscustomobject]@{ Name = "Favoriten"; Path = [Environment]::GetFolderPath("Favorites") },
    [pscustomobject]@{ Name = "Gespeicherte Spiele"; Path = Join-Path $env:USERPROFILE "Saved Games" },
    [pscustomobject]@{ Name = "Kontakte"; Path = Join-Path $env:USERPROFILE "Contacts" }
) | Where-Object {
    $_.Path -and
    ([System.IO.Path]::GetFullPath($_.Path).TrimEnd('\') -ne [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\'))
}

$drive = Resolve-UsbDrive -Drive $UsbDrive -Silent:$Silent
# Jeder Computer und Benutzer erhaelt am Ziel einen eigenen Sicherungsordner.
$destination = Join-Path $drive ("Bibliothekssicherung\{0}_{1}" -f $env:COMPUTERNAME, $env:USERNAME)
$metadataFile = Join-Path $destination '_Sicherungsinfo.txt'
$logDir = Join-Path $destination "_logs"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logPrefix = if ($Mode -eq 'Restore') { 'restore' } else { 'robocopy' }
$logFile = Join-Path $logDir ("{0}_{1}.log" -f $logPrefix, $stamp)

if ($Mode -eq 'Backup') {
    $backupFolders = @($folderDefinitions | Where-Object { Test-Path -LiteralPath $_.Path -PathType Container } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Path = $_.Path; TargetPath = Join-Path $destination $_.Name }
    })
    Write-BackupStatus -Type 'STATUS' -Text (M 'Sicherung wird vorbereitet ...' 'Preparing backup ...')
} else {
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        throw ((M "Auf dem Laufwerk wurde keine Sicherung fuer diesen Computer und Benutzer gefunden: {0}" "No backup for this computer and user was found on the drive: {0}") -f $destination)
    }
    Assert-BackupIdentity -MetadataFile $metadataFile
    $backupFolders = @($folderDefinitions | ForEach-Object {
        $restoreSource = Join-Path $destination $_.Name
        if (Test-Path -LiteralPath $restoreSource -PathType Container) {
            [pscustomobject]@{ Name = $_.Name; Path = $restoreSource; TargetPath = $_.Path }
        }
    })
    Write-BackupStatus -Type 'STATUS' -Text (M 'Wiederherstellung wird vorbereitet ...' 'Preparing restore ...')
}

if ($SelectedFolders) {
    $selectedNames = @($SelectedFolders -split '\|' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $backupFolders = @($backupFolders | Where-Object { $selectedNames -contains $_.Name })
}
if (-not $backupFolders) {
    throw (M "Es wurden keine passenden ausgewaehlten Ordner gefunden." "No matching selected folders were found.")
}

# Verhindert, dass das Sicherungsziel innerhalb einer Quelle liegt und Robocopy
# dadurch seine eigenen Ausgabedateien erneut einliest.
if ($Mode -eq 'Backup') {
    $destinationFullPath = [System.IO.Path]::GetFullPath($destination).TrimEnd('\')
    foreach ($folder in $backupFolders) {
        $sourceFullPath = [System.IO.Path]::GetFullPath($folder.Path).TrimEnd('\')
        if ($destinationFullPath -eq $sourceFullPath -or $destinationFullPath.StartsWith("$sourceFullPath\", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ((M "Das Sicherungsziel liegt innerhalb des Quellordners '{0}'. Bitte ein anderes Ziellaufwerk waehlen." "The backup destination is inside source folder '{0}'. Select a different destination drive.") -f $folder.Path)
        }
    }
}

# Zielordner ohne Laufwerksbuchstaben (z. B. auf eine Netzwerkfreigabe
# umgeleitete Bibliotheken) werden abgelehnt, weil ihr freier Speicherplatz
# nicht ueber Win32_LogicalDisk geprueft werden kann.
foreach ($folder in $backupFolders) {
    $targetRootCheck = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($folder.TargetPath)).TrimEnd('\')
    if ($targetRootCheck -notmatch '^[A-Za-z]:$') {
        throw ((M "Der Ordner '{0}' ist nach '{1}' umgeleitet. Ziele ohne Laufwerksbuchstaben (z. B. Netzwerkfreigaben) werden nicht unterstuetzt." "Folder '{0}' is redirected to '{1}'. Destinations without a drive letter (such as network shares) are not supported.") -f $folder.Name, $folder.TargetPath)
    }
}

# Nur schnell verfuegbare Laufwerksinformationen abfragen. Die Bibliotheken
# werden vorher nicht komplett gescannt, damit die Sicherung zuegig startet.
$targetDisk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive) -ErrorAction Stop
$freeSpace = [int64]$targetDisk.FreeSpace
$freeSpaceGb = [math]::Round($freeSpace / 1GB, 1)
$fileSystem = if ($targetDisk.FileSystem) { $targetDisk.FileSystem } else { "unbekannt" }
$fat32Warning = $fileSystem -eq "FAT32"

# Unwichtige Windows-Metadaten und typische temporaere Dateien auslassen.
$excludedFiles = @(
    "thumbs.db",
    "desktop.ini",
    "*.tmp",
    "*.temp",
    "~$*"
)

$preflight = Get-BackupPreflight -Folders $backupFolders -ExcludedFiles $excludedFiles
if ($preflight.ScanWarnings.Count -gt 0) {
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
        } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $PreviewFile -Encoding UTF8
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
foreach ($targetRoot in $preflight.RequiredByRoot.Keys) {
    # Die Zielwurzeln sind oben bereits als Laufwerksbuchstaben validiert.
    $spaceDisk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $targetRoot) -ErrorAction Stop
    $requiredWithReserve = [int64]([int64]$preflight.RequiredByRoot[$targetRoot] * 1.05)
    if ($requiredWithReserve -gt [int64]$spaceDisk.FreeSpace) {
        throw ((M "Nicht genug freier Speicherplatz auf {0}. Benoetigt werden voraussichtlich {1:N1} GB, frei sind {2:N1} GB." "Not enough free space on {0}. Approximately {1:N1} GB is required; {2:N1} GB is available.") -f $targetRoot, ([int64]$preflight.RequiredByRoot[$targetRoot] / 1GB), ([int64]$spaceDisk.FreeSpace / 1GB))
    }
}
if ($Mode -eq 'Backup' -and $fat32Warning -and $preflight.LargeFiles.Count -gt 0) {
    $examples = @($preflight.LargeFiles | Select-Object -First 3) -join '; '
    throw ((M "FAT32 kann {0} ausgewaehlte Datei(en) ab 4 GB nicht speichern. Verwenden Sie exFAT oder NTFS. Beispiele: {1}" "FAT32 cannot store {0} selected file(s) of 4 GB or larger. Use exFAT or NTFS. Examples: {1}") -f $preflight.LargeFiles.Count, $examples)
}

if ($Mode -eq 'Restore') {
    if ($PreviewFile) {
        [pscustomobject]@{
            MissingFiles = $preflight.MissingFileCount
            OverwriteFiles = $preflight.OverwriteFileCount
            ProtectedNewerFiles = $preflight.ProtectedNewerFileCount
            PlannedFiles = $preflight.RequiredFileCount
            PlannedBytes = $preflight.RequiredBytes
            OverwriteExamples = @($preflight.OverwriteExamples)
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $PreviewFile -Encoding UTF8
    }
    if ($Silent) {
        if (-not $ApprovalFile) { throw (M 'Im stillen Restore-Modus ist eine Freigabedatei erforderlich.' 'Silent restore mode requires an approval file.') }
        Write-BackupStatus -Type 'VORSCHAU' -Text (M 'Konfliktvorschau ist bereit.' 'Conflict preview is ready.')
        Wait-GuiApproval -CancelMessage (M 'Wiederherstellung vor dem Kopieren abgebrochen.' 'Restore cancelled before copying.') -ClosedMessage (M 'Die Bedienoberflaeche wurde geschlossen.' 'The user interface was closed.')
    }
}

$bitLockerStatus = Get-BitLockerStatusText -Drive $drive

Write-Host ""
Write-Host $(if ($Mode -eq 'Restore') { M 'Wiederhergestellt werden diese Benutzerordner:' 'These user folders will be restored:' } else { M 'Gesichert werden nur diese Benutzerordner:' 'Only these user folders will be backed up:' })
foreach ($folder in $backupFolders) {
    Write-Host ("- {0}" -f (Get-LocalizedFolderName $folder.Name))
}
Write-Host ""
Write-Host $(if ($Mode -eq 'Restore') { (M "Sicherungsquelle: {0}" "Backup source: {0}") -f $destination } else { (M "Ziel:   {0}" "Destination: {0}") -f $destination })
Write-Host ((M "USB-Laufwerk: {0:N1} GB frei (Dateisystem: {1})" "USB drive: {0:N1} GB free (file system: {1})") -f $freeSpaceGb, $fileSystem)
Write-Host ((M "Voraussichtlich zu kopieren: {0} Dateien, {1:N2} GB" "Expected copy volume: {0} files, {1:N2} GB") -f $preflight.RequiredFileCount, ($preflight.RequiredBytes / 1GB))
Write-Host $bitLockerStatus
Write-Host ""
if ($Mode -eq 'Backup' -and $fat32Warning) {
    Write-Host (M "WARNUNG: FAT32 kann keine Dateien ab 4 GB speichern. Fuer Sicherungen sind exFAT oder NTFS besser geeignet." "WARNING: FAT32 cannot store files of 4 GB or larger. exFAT or NTFS is better suited for backups.")
    Write-Host ""
}
if ($Mode -eq 'Restore') {
    Write-Host (M "Es wird nichts in den lokalen Ordnern geloescht." "Nothing is deleted from local folders.")
    Write-Host (M "Neuere lokale Dateien bleiben durch /XO geschuetzt." "Newer local files remain protected by /XO.")
    Write-Host ((M "Konflikte: {0} lokale Datei(en) werden ersetzt; {1} neuere lokale Datei(en) bleiben erhalten." "Conflicts: {0} local file(s) will be replaced; {1} newer local file(s) will remain protected.") -f $preflight.OverwriteFileCount, $preflight.ProtectedNewerFileCount)
} else {
    Write-Host (M "Es wird nichts im Backup-Ziel geloescht." "Nothing is deleted from the backup destination.")
    Write-Host (M "Neuere Dateien ueberschreiben aeltere Dateien im Backup." "Newer files replace older files in the backup.")
}
Write-Host (M "AppData, Temp- und Cache-Verzeichnisse werden nicht kopiert." "AppData, temporary, and cache folders are not copied.")
Write-Host (M "Hinweis: Geoeffnete/gesperrte Dateien koennen uebersprungen werden; Details stehen im Log." "Note: Open or locked files may be skipped; see the log for details.")
Write-Host ""

if (-not $Silent) {
    $confirm = Read-Host $(if ($Mode -eq 'Restore') { M 'Wiederherstellung starten? j/N' 'Start restore? y/N' } else { M 'Sicherung starten? J/n' 'Start backup? Y/n' })
    if ([string]::IsNullOrWhiteSpace($confirm)) {
        $confirm = if ($Mode -eq 'Restore') { 'n' } else { 'j' }
    }
    if ($confirm -notmatch '^(j|ja|y|yes)$') {
            Write-Host (M "Abgebrochen." "Cancelled.")
        exit 1
    }
}

# Erst nach der Bestaetigung wird auf das Ziellaufwerk geschrieben. Ein
# abgelehnter Vorgang hinterlaesst so weder Ordner noch veraenderte Metadaten.
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
if ($Mode -eq 'Backup') {
    @(
        'Bibliothekssicherung', '', "Computer: $env:COMPUTERNAME", "Benutzer: $env:USERNAME",
        "Letzter Sicherungsversuch: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "Quelle: $env:USERPROFILE",
        "Ziel: $destination", "Ordner: $($backupFolders.Name -join ', ')",
        'Sicherungsart: Fortlaufende Sicherheitskopie; am Ziel werden keine Dateien geloescht.'
    ) | Set-Content -LiteralPath $metadataFile -Encoding UTF8
}

$maxCode = 0
$failedFolders = @()
$successfulFolders = @()
$foldersWithHints = @()
$folderNumber = 0
$folderCount = @($backupFolders).Count
$backupStartedAt = Get-Date
$operationName = if ($Mode -eq 'Restore') { M 'Wiederherstellung' 'Restore' } else { M 'Sicherung' 'Backup' }
$successMessage = if ($Mode -eq 'Restore') { M 'Wiederherstellung erfolgreich abgeschlossen.' 'Restore completed successfully.' } else { M 'Sicherung erfolgreich abgeschlossen.' 'Backup completed successfully.' }
$failureMessage = if ($Mode -eq 'Restore') { M 'Wiederherstellung mit Fehlern beendet.' 'Restore finished with errors.' } else { M 'Sicherung mit Fehlern beendet.' 'Backup finished with errors.' }
$cancelMessage = if ($Mode -eq 'Restore') { M 'Wiederherstellung wurde auf Wunsch beendet.' 'Restore was cancelled by request.' } else { M 'Sicherung wurde auf Wunsch beendet.' 'Backup was cancelled by request.' }

# Allgemeine Angaben vor den Robocopy-Ausgaben in dieselbe Logdatei schreiben.
@(
    "Start: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "Vorgang: $operationName",
    "Sicherungsordner: $destination",
    ("Freier Platz beim Start: {0:N1} GB" -f $freeSpaceGb),
    "Dateisystem: $fileSystem",
    $bitLockerStatus,
    "Hinweis: Geoeffnete/gesperrte Dateien werden ohne VSS ggf. uebersprungen.",
    "Threads: $Threads",
    ""
) | Add-Content -LiteralPath $logFile -Encoding Unicode

foreach ($folder in $backupFolders) {
    if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) {
        Write-BackupStatus -Type 'ABGEBROCHEN' -Text (M 'Vorgang wurde auf Wunsch beendet.' 'Operation was cancelled by request.')
        if ($Mode -eq 'Backup') { Add-Content -LiteralPath $metadataFile -Value "Ergebnis: Vom Benutzer abgebrochen am $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')." -Encoding UTF8 }
        if ($ResultFile) {
            [pscustomobject]@{
                Success = $false; Cancelled = $true; Mode = $Mode; Message = $cancelMessage
                Destination = $destination; LogFile = $logFile
                StartedAt = $backupStartedAt.ToString('o'); FinishedAt = (Get-Date).ToString('o')
                SuccessfulFolders = @($successfulFolders); HintFolders = @($foldersWithHints); FailedFolders = @()
            } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
        }
        exit 20
    }
    $folderNumber++
    $target = $folder.TargetPath
    $displayFolderName = Get-LocalizedFolderName $folder.Name
    Write-Host $(if ($Mode -eq 'Restore') { (M "Stelle {0} wieder her..." "Restoring {0}...") -f $displayFolderName } else { (M "Sichere {0}..." "Backing up {0}...") -f $displayFolderName })
    Write-BackupStatus -Type "FORTSCHRITT" -Text ("{0}|{1}|{2}" -f $folderNumber, $folderCount, $folder.Name)

    # /E       kopiert auch leere Unterordner.
    # /XJ      folgt keinen Junctions und verhindert Schleifen.
    # /FFT     toleriert groebere Zeitstempel externer Dateisysteme.
    # /XO      ersetzt keine neuere Datei im Sicherungsziel durch eine aeltere.
    # /COPY:DAT kopiert Daten, Attribute und Zeitstempel, aber keine NTFS-ACLs.
    # Es wird absichtlich weder /MIR noch /PURGE verwendet: Am Ziel wird nichts geloescht.
    $robocopyArgs = @(
        $folder.Path,
        $target,
        "/E",
        "/XJ",
        "/FFT",
        "/XO",
        "/MT:$Threads",
        "/R:1",
        "/W:3",
        "/COPY:DAT",
        "/DCOPY:DAT",
        "/NFL",
        "/NDL",
        "/NP",
        "/UNILOG+:$logFile",
        "/XF"
    ) + $excludedFiles

    $null = & robocopy @robocopyArgs
    $code = $LASTEXITCODE

    # Robocopy verwendet die Codes 0 bis 7 fuer erfolgreiche Laeufe bzw.
    # Ergebnisse mit Hinweisen. Erst ab Code 8 liegt ein Kopierfehler vor.
    if ($code -le 7) {
        $successfulFolders += $folder.Name
        if ($code -ge 2) {
            $foldersWithHints += $folder.Name
            Write-Host ((M "  OK mit Hinweisen ({0}), Robocopy-Code {1}" "  OK with notes ({0}), Robocopy code {1}") -f $displayFolderName, $code)
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

if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) {
    Write-BackupStatus -Type 'ABGEBROCHEN' -Text (M 'Vorgang wurde auf Wunsch beendet.' 'Operation was cancelled by request.')
    if ($Mode -eq 'Backup') { Add-Content -LiteralPath $metadataFile -Value "Ergebnis: Vom Benutzer abgebrochen am $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')." -Encoding UTF8 }
    if ($ResultFile) {
        [pscustomobject]@{
            Success = $false; Cancelled = $true; Mode = $Mode; Message = $cancelMessage
            Destination = $destination; LogFile = $logFile
            StartedAt = $backupStartedAt.ToString('o'); FinishedAt = (Get-Date).ToString('o')
            SuccessfulFolders = @($successfulFolders); HintFolders = @($foldersWithHints); FailedFolders = @($failedFolders)
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
    }
    exit 20
}

Write-Host ""
if ($maxCode -le 7) {
    $finishedAt = Get-Date
    $remainingDisk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive) -ErrorAction SilentlyContinue
    if ($Mode -eq 'Backup') { Add-Content -LiteralPath $metadataFile -Value "Ergebnis: Erfolgreich abgeschlossen am $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')." -Encoding UTF8 }
    Write-BackupStatus -Type "FERTIG" -Text $successMessage
    Write-Host $successMessage
    $folderSummaryLabel = if ($Mode -eq 'Restore') { M 'Wiederhergestellte Ordner' 'Restored folders' } else { M 'Gesicherte Ordner' 'Backed-up folders' }
    $localizedSuccessfulFolders = @($successfulFolders | ForEach-Object { Get-LocalizedFolderName $_ })
    Write-Host ("{0}: {1}" -f $folderSummaryLabel, ($localizedSuccessfulFolders -join ", "))
    if ($foldersWithHints) {
        $localizedHintFolders = @($foldersWithHints | ForEach-Object { Get-LocalizedFolderName $_ })
        Write-Host ((M "Ordner mit Hinweisen: {0}" "Folders with notes: {0}") -f ($localizedHintFolders -join ", "))
    }
    Write-Host $(if ($Mode -eq 'Restore') { (M "Sicherungsquelle: {0}" "Backup source: {0}") -f $destination } else { (M "Ziel: {0}" "Destination: {0}") -f $destination })
    Write-Host "Log:  $logFile"
    if ($ResultFile) {
        [pscustomobject]@{
            Success = $true
            Cancelled = $false
            Mode = $Mode
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
            ScannedFiles = $preflight.FileCount
            PlannedFiles = $preflight.RequiredFileCount
            PlannedBytes = $preflight.RequiredBytes
            RemainingBytes = if ($remainingDisk) { [int64]$remainingDisk.FreeSpace } else { $null }
            ScanWarnings = @($preflight.ScanWarnings)
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
    }
    exit 0
}

Write-Host $failureMessage
if ($Mode -eq 'Backup') { Add-Content -LiteralPath $metadataFile -Value "Ergebnis: Mit Fehlern beendet am $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')." -Encoding UTF8 }
Write-BackupStatus -Type "FEHLER" -Text ((M "Fehler in: {0}" "Errors in: {0}") -f ($failedFolders -join ", "))
$localizedFailedFolders = @($failedFolders | ForEach-Object { Get-LocalizedFolderName $_ })
Write-Host ((M "Betroffene Ordner: {0}" "Affected folders: {0}") -f ($localizedFailedFolders -join ", "))
Write-Host ((M "Bitte Log pruefen: {0}" "Review the log: {0}") -f $logFile)
if ($ResultFile) {
    [pscustomobject]@{
        Success = $false
        Cancelled = $false
        Mode = $Mode
        Message = (M 'Vorgang mit Kopierfehlern beendet.' 'Operation finished with copy errors.')
        Destination = $destination
        LogFile = $logFile
        StartedAt = $backupStartedAt.ToString('o')
        FinishedAt = (Get-Date).ToString('o')
        SuccessfulFolders = @($successfulFolders)
        HintFolders = @($foldersWithHints)
        FailedFolders = @($failedFolders)
        ScannedFiles = $preflight.FileCount
        PlannedFiles = $preflight.RequiredFileCount
        PlannedBytes = $preflight.RequiredBytes
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
}
exit $maxCode
