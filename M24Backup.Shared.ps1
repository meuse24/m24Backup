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

function Get-M24DriveConnectionInfo {
    # Win32_LogicalDisk.DriveType unterscheidet nur "removable" von "fixed".
    # Externe USB-HDDs und -SSDs werden deshalb meist als DriveType 3 gemeldet.
    # Erst der physische Bus-Typ erlaubt eine belastbare Einordnung.
    param(
        [int]$DriveType,
        [AllowNull()]
        [string]$BusType
    )

    $normalizedBusType = if ([string]::IsNullOrWhiteSpace($BusType)) { '' } else { $BusType.Trim() }
    $externalBusTypes = @('USB', 'SD', 'MMC', '1394')
    $internalBusTypes = @('ATA', 'SATA', 'SAS', 'NVMe', 'RAID', 'Storage Spaces')
    $isExternalBus = $externalBusTypes -contains $normalizedBusType
    $isRemovable = $DriveType -eq 2
    $isInternal = $DriveType -eq 3 -and $internalBusTypes -contains $normalizedBusType
    $connectionKind = if ($normalizedBusType -eq 'USB') {
        'Usb'
    } elseif ($isExternalBus) {
        'External'
    } elseif ($isRemovable) {
        'Removable'
    } elseif ($isInternal) {
        'Internal'
    } else {
        # Ohne physischen Bus-Typ darf ein Fixed Disk nicht als intern
        # behauptet werden. Das vermeidet Fehlwarnungen bei USB-Bridges.
        'Unknown'
    }

    return [pscustomobject]@{
        BusType = $normalizedBusType
        ConnectionKind = $connectionKind
        IsExternal = [bool]($isExternalBus -or $isRemovable)
        IsInternal = [bool]$isInternal
        CanEject = [bool]($isExternalBus -or $isRemovable)
    }
}

function Get-M24BackupRunPolicy {
    # Zentrale Lauf-Policy fuer den Sicherungs-Worker: validiert die
    # Superfast-Kombinationen und liefert die effektiven Kopierparameter.
    # ExplicitThreads ist $null, wenn -Threads nicht explizit angegeben wurde;
    # nur dann darf der Superfast-Standard von 32 Threads greifen.
    param(
        [ValidateSet('Backup', 'Restore')]
        [string]$Mode = 'Backup',
        [switch]$SuperFast,
        [switch]$DryRun,
        [switch]$SkipChecksums,
        [Nullable[int]]$ExplicitThreads = $null
    )

    $german = Test-M24GermanUiCulture
    if ($SuperFast -and $Mode -ne 'Backup') {
        throw $(if ($german) { 'Der Superschnell-Modus ist nur fuer Sicherungen verfuegbar.' } else { 'Super fast mode is only available for backups.' })
    }
    if ($SuperFast -and $DryRun) {
        throw $(if ($german) { 'Der Superschnell-Modus kann nicht mit Dry-Run kombiniert werden.' } else { 'Super fast mode cannot be combined with dry run.' })
    }
    $threads = if ($null -ne $ExplicitThreads) { [int]$ExplicitThreads } elseif ($SuperFast) { 32 } else { 8 }
    if ($threads -lt 1 -or $threads -gt 128) {
        throw $(if ($german) { 'Der Parameter -Threads muss zwischen 1 und 128 liegen.' } else { 'The -Threads parameter must be between 1 and 128.' })
    }
    return [pscustomobject]@{
        SuperFast = [bool]$SuperFast
        Threads = $threads
        RetryCount = $(if ($SuperFast) { 0 } else { 1 })
        RetryWaitSeconds = $(if ($SuperFast) { 1 } else { 3 })
        SkipPreflight = [bool]$SuperFast
        SkipChecksums = [bool]($SkipChecksums -or $SuperFast)
        SkipBitLockerStatus = [bool]$SuperFast
    }
}

function Test-M24ReservedDeviceFileName {
    # Erkennt Dateinamen, die reservierten Windows-Geraetenamen entsprechen
    # (z. B. "nul", "con.txt"). Solche Dateien sind fast immer versehentlich
    # erzeugte Artefakte; scheitert ihr Zugriff, darf das einen Sicherungs-
    # oder Pruefvorgang nicht zum Abbruch bringen.
    param([string]$Name)
    return [bool]($Name -match '^(?i)(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$')
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

function Write-M24DiagnosticLog {
    # Lokales GUI-Diagnoseprotokoll unter %LOCALAPPDATA%\M24Backup\Logs.
    # Es dokumentiert ausschliesslich GUI-Fehler und ist unabhaengig vom
    # Betriebsprotokoll auf dem Sicherungsziel; es funktioniert deshalb auch
    # ohne angeschlossenes Sicherungslaufwerk. Die Funktion ist bewusst
    # ausfallsicher: Ein Fehler beim Schreiben oder Rotieren darf niemals den
    # urspruenglichen Fehler des Aufrufers ueberdecken. Sie wirft daher nie
    # und liefert keinerlei Pipeline-Ausgabe.
    param(
        [string]$EventId,
        [string]$Message,
        # ErrorRecord (typisch: $_ im catch-Block) oder Exception. Nur aus
        # einem ErrorRecord laesst sich der PowerShell-Skript-Stack gewinnen.
        $Exception,
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Severity = 'Error',
        [string]$Context,
        [string]$LogDirectory,
        [int64]$MaxBytes = 2MB,
        [int]$FileCount = 5
    )

    try {
        # Der Standardpfad wird erst hier innerhalb des try aufgeloest. Ein
        # Default-Ausdruck im param-Block wuerde bei fehlendem Profilpfad
        # schon waehrend der Parameterbindung werfen und damit die
        # Ausfallsicherheits-Zusage der Funktion brechen.
        if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
            $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
            if ([string]::IsNullOrWhiteSpace($localAppData)) { return }
            $LogDirectory = Join-Path $localAppData 'M24Backup\Logs'
        }
        if (-not [System.IO.Directory]::Exists($LogDirectory)) {
            [void][System.IO.Directory]::CreateDirectory($LogDirectory)
        }
        $activeLog = Join-Path $LogDirectory 'gui.log'

        # Rotation vor dem naechsten Schreibvorgang: gui.log -> gui.1.log,
        # bestehende Archive ruecken um eine Position auf, das aelteste
        # Archiv (gui.<FileCount-1>.log) entfaellt.
        if ($FileCount -ge 2 -and [System.IO.File]::Exists($activeLog) -and
            (New-Object System.IO.FileInfo($activeLog)).Length -ge $MaxBytes) {
            $oldestArchive = Join-Path $LogDirectory ("gui.{0}.log" -f ($FileCount - 1))
            if ([System.IO.File]::Exists($oldestArchive)) { [System.IO.File]::Delete($oldestArchive) }
            for ($index = $FileCount - 2; $index -ge 1; $index--) {
                $source = Join-Path $LogDirectory ("gui.{0}.log" -f $index)
                if ([System.IO.File]::Exists($source)) {
                    [System.IO.File]::Move($source, (Join-Path $LogDirectory ("gui.{0}.log" -f ($index + 1))))
                }
            }
            [System.IO.File]::Move($activeLog, (Join-Path $LogDirectory 'gui.1.log'))
        }

        $errorRecord = $null
        $exceptionObject = $null
        if ($Exception -is [System.Management.Automation.ErrorRecord]) {
            $errorRecord = $Exception
            $exceptionObject = $Exception.Exception
        } elseif ($Exception -is [System.Exception]) {
            $exceptionObject = $Exception
        }

        $timestamp = [System.DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', [System.Globalization.CultureInfo]::InvariantCulture)
        $builder = New-Object System.Text.StringBuilder
        [void]$builder.AppendLine(('{0} [{1}] [{2}]' -f $timestamp, $Severity.ToUpperInvariant(), $EventId))
        [void]$builder.AppendLine(('PID: {0}' -f $PID))
        if (-not [string]::IsNullOrWhiteSpace($Message)) {
            [void]$builder.AppendLine(('Message: {0}' -f $Message))
        }
        if ($exceptionObject) {
            [void]$builder.AppendLine(('Exception: {0}' -f $exceptionObject.GetType().FullName))
            if (-not [string]::IsNullOrWhiteSpace($exceptionObject.Message) -and $exceptionObject.Message -cne $Message) {
                [void]$builder.AppendLine(('ExceptionMessage: {0}' -f $exceptionObject.Message))
            }
        }
        $stackText = if ($errorRecord -and -not [string]::IsNullOrWhiteSpace($errorRecord.ScriptStackTrace)) {
            $errorRecord.ScriptStackTrace
        } elseif ($exceptionObject -and -not [string]::IsNullOrWhiteSpace($exceptionObject.StackTrace)) {
            $exceptionObject.StackTrace
        } else {
            $null
        }
        if ($stackText) { [void]$builder.AppendLine(('Stack: {0}' -f $stackText)) }
        if (-not [string]::IsNullOrWhiteSpace($Context)) { [void]$builder.AppendLine(('Context: {0}' -f $Context)) }
        [void]$builder.AppendLine()

        [System.IO.File]::AppendAllText($activeLog, $builder.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # Diagnose-Logging ist reine Zusatzinformation. Jeder interne Fehler
        # wird verschluckt, damit der Aufrufer seinen Originalfehler behaelt.
    }
}

function Remove-M24StaleTempArtifacts {
    # Best-effort-Bereinigung verwaister Kommunikationsdateien dieser
    # Anwendung im Temp-Verzeichnis. Ein passender Dateiname allein beweist
    # keine Verwaisung: Eine zweite GUI-Instanz oder ein nach GUI-Ende
    # weiterlaufender Worker kann frische Dateien besitzen. Geloescht wird
    # deshalb nur, was exakt einem bekannten Namensformat entspricht UND
    # mindestens MinimumAge (Standard: sieben Tage) alt ist. Die Funktion
    # wirft nie und liefert keine Pipeline-Ausgabe; ein Bereinigungsproblem
    # darf den GUI-Start weder blockieren noch sichtbar werden.
    param(
        [string]$TempDirectory,
        [TimeSpan]$MinimumAge = [TimeSpan]::FromDays(7)
    )

    try {
        # Null oder negativ wuerde frische, moeglicherweise aktiv genutzte
        # Kommunikationsdateien zur Loeschung freigeben.
        if ($MinimumAge -le [TimeSpan]::Zero) { return }

        # Der Standardpfad wird erst hier im try aufgeloest, damit auch ein
        # Fehler der Pfadaufloesung von der Ausfallsicherheit gedeckt ist.
        if ([string]::IsNullOrWhiteSpace($TempDirectory)) {
            $TempDirectory = [System.IO.Path]::GetTempPath()
        }
        if ([string]::IsNullOrWhiteSpace($TempDirectory)) { return }
        if (-not [System.IO.Directory]::Exists($TempDirectory)) { return }

        $cutoffUtc = [DateTime]::UtcNow.Subtract($MinimumAge)

        # Nur diese exakten, verankerten Muster autorisieren eine Loeschung.
        # <GUID> ist das N-Format von [guid]: exakt 32 Hexadezimalzeichen.
        # Das erste Muster deckt die normalen GUI/Worker-Dateien sowie die
        # .tmp/.bak-Reste von Write-M24AtomicTextFile ab, das zweite die
        # Abbruchmarker der Pruefsummen-Verifikation (PID + GUID).
        $ownedNamePatterns = @(
            '^Bibliothekssicherung_[0-9a-f]{32}\.(?:status|result\.json|cancel|preview\.json|approve|folders\.json)(?:\.[0-9a-f]{32}\.(?:tmp|bak))?$',
            '^M24Backup\.verify-cancel\.\d+\.[0-9a-f]{32}\.tmp$'
        )

        # Die Wildcard-Vorfilter sind nur eine Enumerationsoptimierung, damit
        # nicht das gesamte Temp-Verzeichnis durch die Pipeline laeuft. Sie
        # sind ausdruecklich keine Loeschautorisierung. Es wird nur die
        # oberste Ebene betrachtet, keine Unterverzeichnisse.
        $candidates = @()
        foreach ($prefilter in @('Bibliothekssicherung_*', 'M24Backup.verify-cancel.*.tmp')) {
            $candidates += @(Get-ChildItem -LiteralPath $TempDirectory -Filter $prefilter -File -Force -ErrorAction SilentlyContinue)
        }

        foreach ($candidate in $candidates) {
            try {
                $isOwnedName = $false
                foreach ($pattern in $ownedNamePatterns) {
                    if ($candidate.Name -match $pattern) { $isOwnedName = $true; break }
                }
                if (-not $isOwnedName) { continue }

                # Metadaten unmittelbar vor der Entscheidung auffrischen,
                # damit weder die Reparse-Point- noch die Alterspruefung auf
                # veralteten Enumerationsdaten basiert.
                $candidate.Refresh()
                if (-not $candidate.Exists) { continue }

                # Reparse-Points (Symlinks u. ae.) werden nie geloescht, auch
                # wenn der Name passt.
                if (($candidate.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if ($candidate.LastWriteTimeUtc -le $cutoffUtc) {
                    # Erst nach allen Autorisierungspruefungen: Ein gesetztes
                    # ReadOnly-Bit wuerde File.Delete scheitern lassen und den
                    # Kandidaten bei jedem Start erneut anfallen lassen. Nur
                    # dieses eine Bit wird entfernt; alle uebrigen Attribute
                    # bleiben unveraendert.
                    $attributes = $candidate.Attributes
                    if (($attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                        [System.IO.File]::SetAttributes(
                            $candidate.FullName,
                            ($attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
                    }
                    [System.IO.File]::Delete($candidate.FullName)
                }
            } catch {
                # Eine unzugreifbare Datei darf die Bereinigung der uebrigen
                # Kandidaten nicht stoppen.
            }
        }
    } catch {
        # Best effort: Aufloesungs- und Enumerationsfehler werden bewusst
        # verschluckt.
    }
}

function Stop-M24WorkerProcess {
    # Best-effort-Beendigung eines gestarteten Worker-Prozesses nach einem
    # teilweise fehlgeschlagenen GUI-Start. Ablauf: kooperativen Abbruch per
    # Cancel-Datei anfordern, begrenzt auf ein freiwilliges Ende warten,
    # andernfalls Kill() mit begrenzter Bestaetigungswartezeit. Beide
    # Wartezeiten werden im Funktionskoerper hart auf 0 bis 10 Sekunden
    # begrenzt, damit der GUI-Thread unabhaengig von Aufruferwerten nie
    # unbegrenzt blockiert. Die Funktion wirft nie und darf den
    # urspruenglichen Startfehler des Aufrufers nicht ueberdecken. Das
    # Process-Objekt wird abschliessend immer freigegeben.
    #
    # Rueckgabe: $true, wenn das Prozessende bestaetigt ist (nie gestartet,
    # bereits beendet oder Ende nach Cancel/Kill beobachtet), sonst $false.
    # Bei $false soll der Aufrufer die Cancel-Datei NICHT loeschen, damit
    # das Abbruchsignal fuer den weiterlaufenden Worker wirksam bleibt.
    #
    # Grenze: Unter .NET Framework (Windows PowerShell 5.1) gibt es keine
    # Kill(entireProcessTree)-Ueberladung; bereits gestartete Kindprozesse
    # des Workers werden nicht garantiert mitbeendet.
    param(
        $Process,
        [string]$CancelFile,
        [int]$GracefulWaitMilliseconds = 1000,
        [int]$KillWaitMilliseconds = 2000
    )

    $exitConfirmed = $false
    try {
        # Obergrenze bewusst im Koerper statt per ValidateRange, damit
        # ungewoehnliche Aufruferwerte nicht schon bei der Parameterbindung
        # werfen. 10 Sekunden je Phase lassen auch langsamen Kaltstarts von
        # Kindprozessen genug Spielraum.
        $gracefulWait = [Math]::Min(10000, [Math]::Max(0, $GracefulWaitMilliseconds))
        $killWait = [Math]::Min(10000, [Math]::Max(0, $KillWaitMilliseconds))

        if (-not $Process) {
            # Kein Prozessobjekt: Es gibt nichts, das weiterlaufen koennte.
            $exitConfirmed = $true
        } else {
            # Bewusst WaitForExit(0) statt HasExited: Ein Methodenaufruf
            # wirft bei einem nie verknuepften Prozessobjekt (Start() kam
            # nicht zustande) immer eine abfangbare Ausnahme - unabhaengig
            # von der ErrorActionPreference des Aufrufers. Der Getter
            # HasExited liefert bei 'Continue' stattdessen $null und wuerde
            # den Fehlstart faelschlich als laufenden Prozess einstufen.
            $isRunning = $false
            try { $isRunning = -not $Process.WaitForExit(0) } catch { $isRunning = $false }

            if ($isRunning -and -not [string]::IsNullOrWhiteSpace($CancelFile)) {
                try { [System.IO.File]::WriteAllText($CancelFile, 'cancel') } catch {}
            }
            if ($isRunning) {
                try { if ($Process.WaitForExit($gracefulWait)) { $isRunning = $false } } catch {}
            }
            if ($isRunning) {
                try { $Process.Kill() } catch {}
                try { if ($Process.WaitForExit($killWait)) { $isRunning = $false } } catch {}
            }
            $exitConfirmed = -not $isRunning
        }
    } catch {
        # Best effort: Kein Fehler dieser Aufraeumfunktion darf den
        # ausloesenden Startfehler ersetzen. Ohne Bestaetigung bleibt die
        # Rueckgabe $false.
    } finally {
        if ($Process) {
            try { $Process.Dispose() } catch {}
        }
    }
    return $exitConfirmed
}

function New-M24CancellationMonitor {
    return [pscustomobject]@{
        ConsecutiveOwnerFailures = 0
        LastOwnerCheckUtc = [datetime]::MinValue
        LastOwnerAlive = $true
    }
}

function Get-M24CancellationState {
    # Einheitliche, gedrosselte Auswertung des Cancel-Markers und der exakten
    # GUI-Prozessidentitaet. Ein Startzeit-Mismatch ist definitive PID-
    # Wiederverwendung; fehlende oder voruebergehend nicht lesbare Prozesse
    # werden dagegen entprellt.
    param(
        [string]$CancelFile,
        [int]$ParentProcessId = 0,
        [int64]$ParentProcessStartTimeUtcTicks = 0,
        $Monitor,
        [int]$OwnerFailureThreshold = 2,
        [int]$MinimumOwnerCheckIntervalMilliseconds = 2000
    )

    if (-not $Monitor) { $Monitor = New-M24CancellationMonitor }
    $threshold = [Math]::Max(1, [Math]::Min(10, $OwnerFailureThreshold))
    $interval = [Math]::Max(0, [Math]::Min(30000, $MinimumOwnerCheckIntervalMilliseconds))

    if ($CancelFile -and [System.IO.File]::Exists($CancelFile)) {
        return [pscustomobject]@{ Requested = $true; Reason = 'User'; Message = 'Cancellation was requested by the user.' }
    }
    if ($ParentProcessId -le 0) {
        return [pscustomobject]@{ Requested = $false; Reason = 'None'; Message = '' }
    }

    $now = [datetime]::UtcNow
    if ($Monitor.LastOwnerCheckUtc -ne [datetime]::MinValue -and
        ($now - [datetime]$Monitor.LastOwnerCheckUtc).TotalMilliseconds -lt $interval) {
        if (-not $Monitor.LastOwnerAlive -and [int]$Monitor.ConsecutiveOwnerFailures -ge $threshold) {
            return [pscustomobject]@{ Requested = $true; Reason = 'GuiExited'; Message = 'The owning user interface is no longer running.' }
        }
        return [pscustomobject]@{ Requested = $false; Reason = 'None'; Message = '' }
    }

    $Monitor.LastOwnerCheckUtc = $now
    $owner = $null
    try { $owner = Get-Process -Id $ParentProcessId -ErrorAction Stop } catch {}
    if ($owner) {
        if ($ParentProcessStartTimeUtcTicks -gt 0) {
            try {
                $actualTicks = [int64]$owner.StartTime.ToUniversalTime().Ticks
                if ($actualTicks -ne $ParentProcessStartTimeUtcTicks) {
                    $Monitor.LastOwnerAlive = $false
                    $Monitor.ConsecutiveOwnerFailures = $threshold
                    return [pscustomobject]@{ Requested = $true; Reason = 'GuiExited'; Message = 'The owning user interface process identity no longer matches.' }
                }
            } catch {
                $owner = $null
            }
        }
    }

    if ($owner) {
        $Monitor.LastOwnerAlive = $true
        $Monitor.ConsecutiveOwnerFailures = 0
        return [pscustomobject]@{ Requested = $false; Reason = 'None'; Message = '' }
    }

    $Monitor.LastOwnerAlive = $false
    $Monitor.ConsecutiveOwnerFailures = [int]$Monitor.ConsecutiveOwnerFailures + 1
    if ([int]$Monitor.ConsecutiveOwnerFailures -ge $threshold) {
        return [pscustomobject]@{ Requested = $true; Reason = 'GuiExited'; Message = 'The owning user interface is no longer running.' }
    }
    return [pscustomobject]@{ Requested = $false; Reason = 'None'; Message = '' }
}

function Enter-M24SingleInstance {
    param([Parameter(Mandatory = $true)][string]$Name)

    $mutex = $null
    $acquired = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, $Name)
        try { $acquired = $mutex.WaitOne(0, $false) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        return [pscustomobject]@{ Acquired = [bool]$acquired; Mutex = $mutex; Name = $Name }
    } catch {
        if ($mutex) { try { $mutex.Dispose() } catch {} }
        throw
    }
}

function Exit-M24SingleInstance {
    param($Handle)
    if (-not $Handle -or -not $Handle.Mutex) { return }
    if ($Handle.Acquired) { try { $Handle.Mutex.ReleaseMutex() } catch {} }
    try { $Handle.Mutex.Dispose() } catch {}
}

function Compare-M24DriveFingerprint {
    # Pure Vergleichslogik. Die GUI entscheidet erst nach dem Vergleich aller
    # sichtbaren Laufwerke, ob ein Treffer eindeutig ist.
    param($Known, $Candidate)

    if (-not $Known -or -not $Candidate) {
        return [pscustomobject]@{ IsMatch = $false; Confidence = 'None'; Score = 0; Reason = 'MissingFingerprint' }
    }
    $value = {
        param($Object, [string]$Name)
        $property = $Object.PSObject.Properties[$Name]
        if (-not $property -or $null -eq $property.Value) { return '' }
        return ([string]$property.Value).Trim().ToUpperInvariant()
    }
    $knownVolumeGuid = & $value $Known 'VolumeGuid'
    $candidateVolumeGuid = & $value $Candidate 'VolumeGuid'
    $knownDiskId = & $value $Known 'DiskUniqueId'
    $candidateDiskId = & $value $Candidate 'DiskUniqueId'
    if ($knownVolumeGuid -and $candidateVolumeGuid) {
        if ($knownVolumeGuid -eq $candidateVolumeGuid) { return [pscustomobject]@{ IsMatch = $true; Confidence = 'Strong'; Score = 100; Reason = 'VolumeGuid' } }
        return [pscustomobject]@{ IsMatch = $false; Confidence = 'None'; Score = 0; Reason = 'VolumeGuidMismatch' }
    }
    if ($knownDiskId -and $candidateDiskId) {
        $knownDiskVolumeSerial = & $value $Known 'VolumeSerialNumber'
        $candidateDiskVolumeSerial = & $value $Candidate 'VolumeSerialNumber'
        if ($knownDiskId -eq $candidateDiskId -and $knownDiskVolumeSerial -and $knownDiskVolumeSerial -eq $candidateDiskVolumeSerial) {
            return [pscustomobject]@{ IsMatch = $true; Confidence = 'Strong'; Score = 90; Reason = 'DiskUniqueIdAndVolumeSerial' }
        }
        return [pscustomobject]@{ IsMatch = $false; Confidence = 'None'; Score = 0; Reason = 'DiskUniqueIdMismatch' }
    }

    $knownPhysicalSerial = & $value $Known 'DiskSerialNumber'
    $candidatePhysicalSerial = & $value $Candidate 'DiskSerialNumber'
    if ($knownPhysicalSerial -and $candidatePhysicalSerial) {
        $knownPhysicalVolumeSerial = & $value $Known 'VolumeSerialNumber'
        $candidatePhysicalVolumeSerial = & $value $Candidate 'VolumeSerialNumber'
        if ($knownPhysicalSerial -eq $candidatePhysicalSerial -and $knownPhysicalVolumeSerial -and $knownPhysicalVolumeSerial -eq $candidatePhysicalVolumeSerial) {
            return [pscustomobject]@{ IsMatch = $true; Confidence = 'Strong'; Score = 80; Reason = 'DiskSerialAndVolumeSerial' }
        }
        return [pscustomobject]@{ IsMatch = $false; Confidence = 'None'; Score = 0; Reason = 'DiskSerialMismatch' }
    }

    $knownSerial = & $value $Known 'VolumeSerialNumber'
    if (-not $knownSerial) { $knownSerial = & $value $Known 'SerialNumber' }
    $candidateSerial = & $value $Candidate 'VolumeSerialNumber'
    if (-not $candidateSerial) { $candidateSerial = & $value $Candidate 'SerialNumber' }
    if (-not $knownSerial -or $knownSerial -ne $candidateSerial) {
        return [pscustomobject]@{ IsMatch = $false; Confidence = 'None'; Score = 0; Reason = 'VolumeSerialMismatch' }
    }

    $knownSize = & $value $Known 'SizeBytes'
    $candidateSize = & $value $Candidate 'SizeBytes'
    $knownFs = & $value $Known 'FileSystem'
    $candidateFs = & $value $Candidate 'FileSystem'
    if ($knownSize -and $candidateSize -and $knownFs -and $candidateFs) {
        if ($knownSize -eq $candidateSize -and $knownFs -eq $candidateFs) {
            return [pscustomobject]@{ IsMatch = $true; Confidence = 'Fallback'; Score = 60; Reason = 'VolumeSerialSizeFileSystem' }
        }
        return [pscustomobject]@{ IsMatch = $false; Confidence = 'None'; Score = 0; Reason = 'FallbackMismatch' }
    }
    return [pscustomobject]@{ IsMatch = $true; Confidence = 'Legacy'; Score = 20; Reason = 'LegacyVolumeSerial' }
}

function Resolve-M24RestoreApproval {
    param(
        [ValidateSet('Verify', 'RequireVerified', 'Warn')][string]$Policy,
        [string]$ApprovalValue,
        [bool]$ManifestExists,
        [bool]$AlreadyVerified
    )

    $value = ([string]$ApprovalValue).Trim().ToLowerInvariant()
    if ($value -eq 'cancel') { return [pscustomobject]@{ Allowed = $false; Cancelled = $true; RequiresVerification = $false; UnverifiedOverride = $false; Reason = 'Cancelled' } }
    if ($Policy -eq 'RequireVerified') {
        $allowed = $AlreadyVerified -and $value -eq 'continue-verified'
        return [pscustomobject]@{ Allowed = $allowed; Cancelled = $false; RequiresVerification = $false; UnverifiedOverride = $false; Reason = $(if ($allowed) { 'Verified' } else { 'VerificationRequired' }) }
    }
    if ($value -eq 'continue-verified' -and $AlreadyVerified) {
        return [pscustomobject]@{ Allowed = $true; Cancelled = $false; RequiresVerification = $false; UnverifiedOverride = $false; Reason = 'Verified' }
    }
    if ($value -eq 'verify-then-continue' -and $ManifestExists) {
        return [pscustomobject]@{ Allowed = $true; Cancelled = $false; RequiresVerification = $true; UnverifiedOverride = $false; Reason = 'Verify' }
    }
    if ($value -eq 'continue-unverified' -and -not $ManifestExists -and $Policy -in @('Verify', 'Warn')) {
        return [pscustomobject]@{ Allowed = $true; Cancelled = $false; RequiresVerification = $false; UnverifiedOverride = $true; Reason = 'MissingManifestOverride' }
    }
    if ($Policy -eq 'Warn' -and $value -eq 'continue') {
        return [pscustomobject]@{ Allowed = $true; Cancelled = $false; RequiresVerification = $false; UnverifiedOverride = $true; Reason = 'LegacyWarnApproval' }
    }
    return [pscustomobject]@{ Allowed = $false; Cancelled = $false; RequiresVerification = $false; UnverifiedOverride = $false; Reason = 'InvalidApproval' }
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

function ConvertFrom-M24ExtendedLengthPath {
    param([string]$Path)
    if ($Path.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return "\\$($Path.Substring(8))"
    }
    if ($Path.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring(4)
    }
    return $Path
}

function Get-M24DirectoryEntries {
    # Verwendet ausschließlich .NET mit erweitertem Pfad. PowerShells
    # FileSystem-Provider kann Verzeichnisse wie "nul" zwar vom Elternordner
    # auflisten, anschließend aber nicht mehr betreten.
    param([string]$Path)
    $extendedDirectory = ConvertTo-M24ExtendedLengthPath $Path
    return @([System.IO.Directory]::GetFileSystemEntries($extendedDirectory) | ForEach-Object {
        $extendedPath = [string]$_
        $attributes = [System.IO.File]::GetAttributes($extendedPath)
        $isDirectory = ($attributes -band [System.IO.FileAttributes]::Directory) -ne 0
        $normalPath = ConvertFrom-M24ExtendedLengthPath $extendedPath
        [pscustomobject]@{
            Name = [System.IO.Path]::GetFileName($normalPath.TrimEnd('\'))
            FullName = $normalPath
            ExtendedFullName = $extendedPath
            PSIsContainer = $isDirectory
            Attributes = $attributes
            Length = if ($isDirectory) { [int64]0 } else { [int64](New-Object System.IO.FileInfo($extendedPath)).Length }
        }
    })
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
    [int64]$skippedDeviceFiles = 0
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
                try {
                    $hash = Get-M24FileSha256 -Path $file.FullName -CancelCallback $CancelCallback
                } catch {
                    # Nur Dateien mit reservierten Geraetenamen (z. B. "nul")
                    # duerfen bei einem Zugriffsfehler stillschweigend ohne
                    # Pruefsumme bleiben; echte Lesefehler brechen weiter ab.
                    if (Test-M24ReservedDeviceFileName -Name $file.Name) {
                        $skippedDeviceFiles++
                        return
                    }
                    throw
                }
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
    return [pscustomobject]@{ Cancelled = $false; Files = $fileCount; HashedFiles = $hashedFiles; ReusedFiles = $reusedFiles; Bytes = $totalBytes; SkippedDeviceFiles = $skippedDeviceFiles }
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
                # Dateien mit reservierten Geraetenamen (z. B. "nul") gelten
                # nie als Integritaetsfehler; sie sind Artefakte ohne Nutzwert.
                if (Test-M24ReservedDeviceFileName -Name $file.Name) { return }
                $errorCount++; if ($errors.Count -lt 10) { $errors += $_.Exception.Message }
            }
        }
        if ($cancelled) {
            return [pscustomobject]@{ Cancelled = $true; MissingManifest = $false; Files = $files; Bytes = $bytes; ErrorCount = $errorCount; Errors = @($errors) }
        }
        foreach ($scanError in $scanErrors) { $errorCount++; if ($errors.Count -lt 10) { $errors += $scanError.Exception.Message } }
    }
    foreach ($entry in $manifest.Entries.Values) {
        $entryLeafName = Split-Path -Path ([string]$entry.Path) -Leaf
        if (Test-M24ReservedDeviceFileName -Name $entryLeafName) { continue }
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

function Get-M24BackupRoot {
    param(
        [string]$Drive,
        [string]$Computer = $env:COMPUTERNAME,
        [string]$User = $env:USERNAME
    )
    return Join-Path $Drive ("Bibliothekssicherung\{0}_{1}" -f $Computer, $User)
}

function Get-M24BackupMetadataIdentity {
    param([string[]]$Lines)
    return [pscustomobject]@{
        Computer = (($Lines | Where-Object { $_ -like 'Computer:*' } | Select-Object -First 1) -replace '^Computer:\s*', '').Trim()
        User = (($Lines | Where-Object { $_ -like 'Benutzer:*' } | Select-Object -First 1) -replace '^Benutzer:\s*', '').Trim()
    }
}

function Test-M24BackupMetadataIdentity {
    param(
        [string[]]$Lines,
        [string]$Computer = $env:COMPUTERNAME,
        [string]$User = $env:USERNAME
    )
    $identity = Get-M24BackupMetadataIdentity -Lines $Lines
    return $identity.Computer.Equals($Computer, [System.StringComparison]::OrdinalIgnoreCase) -and
        $identity.User.Equals($User, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-M24BackupDeletionTarget {
    param(
        [string]$BackupRoot,
        [string]$Drive,
        [string]$Computer,
        [string]$User
    )
    $expectedRoot = Get-NormalizedFullPath (Get-M24BackupRoot -Drive $Drive -Computer $Computer -User $User)
    $normalizedRoot = Get-NormalizedFullPath $BackupRoot
    if (-not $normalizedRoot.Equals($expectedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Backup deletion target does not match the expected profile folder: $expectedRoot"
    }
    if (-not (Test-Path -LiteralPath $normalizedRoot -PathType Container)) {
        throw "Backup deletion target was not found: $normalizedRoot"
    }
    $rootItem = Get-Item -LiteralPath $normalizedRoot -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Backup deletion target is a symbolic link or junction. Deletion was refused.'
    }
    $metadataFile = Join-Path $normalizedRoot '_Sicherungsinfo.txt'
    if (-not (Test-Path -LiteralPath $metadataFile -PathType Leaf)) {
        throw 'Backup metadata is missing. Deletion was refused.'
    }
    $metadataLines = @(Get-Content -LiteralPath $metadataFile -ErrorAction Stop)
    if (-not (Test-M24BackupMetadataIdentity -Lines $metadataLines -Computer $Computer -User $User)) {
        throw 'Backup metadata does not match the current computer and user. Deletion was refused.'
    }
    return [pscustomobject]@{ BackupRoot = $normalizedRoot; MetadataFile = $metadataFile; MetadataLines = $metadataLines }
}

function Remove-M24ReservedDeviceFile {
    param([string]$Path)
    try {
        return Remove-M24FileEntry -Path $Path
    } catch {
        return $false
    }
}

function Remove-M24FileEntry {
    param([string]$Path)
    $extendedPath = ConvertTo-M24ExtendedLengthPath $Path
    $attributes = [System.IO.File]::GetAttributes($extendedPath)
    if (($attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
        [System.IO.File]::SetAttributes($extendedPath, ($attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
    }
    [System.IO.File]::Delete($extendedPath)
    return -not [System.IO.File]::Exists($extendedPath)
}

function Remove-M24DirectoryEntry {
    param([string]$Path)
    try {
        $extendedPath = ConvertTo-M24ExtendedLengthPath $Path
        $attributes = [System.IO.File]::GetAttributes($extendedPath)
        if (($attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
            [System.IO.File]::SetAttributes($extendedPath, ($attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
        }
        [System.IO.Directory]::Delete($extendedPath, $false)
        return -not [System.IO.Directory]::Exists($extendedPath)
    } catch {
        return $false
    }
}

function Get-M24BackupDeletionInfo {
    param(
        [string]$BackupRoot,
        [string]$Drive,
        [string]$Computer,
        [string]$User
    )

    if ([string]::IsNullOrWhiteSpace($BackupRoot) -or [string]::IsNullOrWhiteSpace($Drive) -or
        [string]::IsNullOrWhiteSpace($Computer) -or [string]::IsNullOrWhiteSpace($User)) {
        throw 'Backup deletion validation requires a path, drive, computer, and user.'
    }

    $target = Assert-M24BackupDeletionTarget -BackupRoot $BackupRoot -Drive $Drive -Computer $Computer -User $User
    $normalizedDrive = Get-NormalizedFullPath ("{0}\" -f $Drive.TrimEnd('\'))
    $normalizedRoot = $target.BackupRoot
    $metadataFile = $target.MetadataFile
    $metadataLines = $target.MetadataLines
    $identity = Get-M24BackupMetadataIdentity -Lines $metadataLines

    $items = New-Object System.Collections.Generic.List[object]
    $pendingDirectories = New-Object 'System.Collections.Generic.Stack[string]'
    $pendingDirectories.Push($normalizedRoot)
    while ($pendingDirectories.Count -gt 0) {
        $currentDirectory = $pendingDirectories.Pop()
        foreach ($item in @(Get-M24DirectoryEntries -Path $currentDirectory)) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Backup contains a symbolic link or junction. Deletion was refused: $($item.FullName)"
            }
            $items.Add($item)
            if ($item.PSIsContainer) { $pendingDirectories.Push($item.FullName) }
        }
    }
    [int64]$bytes = 0
    [int64]$files = 0
    [int64]$directories = 0
    foreach ($item in $items) {
        if ($item.PSIsContainer) { $directories++ } else { $files++; $bytes += [int64]$item.Length }
    }

    $resultLine = $metadataLines | Where-Object { $_ -like 'Ergebnis:*' } | Select-Object -Last 1
    $folderLine = $metadataLines | Where-Object { $_ -like 'Ordner:*' } | Select-Object -First 1
    return [pscustomobject]@{
        BackupRoot = $normalizedRoot
        Drive = $normalizedDrive
        Computer = $identity.Computer
        User = $identity.User
        Result = if ($resultLine) { ($resultLine -replace '^Ergebnis:\s*', '').Trim() } else { '' }
        Folders = if ($folderLine) { ($folderLine -replace '^Ordner:\s*', '').Trim() } else { '' }
        ChecksumVerifiedAt = Get-M24ChecksumVerifiedDate -MetadataFile $metadataFile
        Files = $files
        Directories = $directories
        Bytes = $bytes
        ConfirmationText = ("{0}_{1}" -f $Computer, $User)
    }
}

function Remove-M24BackupSafely {
    param(
        [string]$BackupRoot,
        [string]$Drive,
        [string]$Computer,
        [string]$User
    )

    $normalizedRoot = Get-NormalizedFullPath $BackupRoot
    $expectedRoot = Get-NormalizedFullPath (Get-M24BackupRoot -Drive $Drive -Computer $Computer -User $User)
    if (-not $normalizedRoot.Equals($expectedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $normalizedRoot -PathType Container)) {
        throw "Backup deletion target does not match an existing expected profile folder: $expectedRoot"
    }
    $lockFile = Join-Path $normalizedRoot '_backup.lock'
    $lockStream = $null
    $target = $null
    $deletionError = $null
    $ignoredDeviceFiles = New-Object System.Collections.Generic.List[string]
    $directoriesToRemove = @()
    try {
        try {
            $lockStream = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch {
            throw 'Another backup, restore, verification, or deletion operation is using this backup.'
        }

        # Die endgültige Pfad-, Identitäts- und Reparse-Prüfung findet erst
        # unter dem exklusiven Lock statt. Der Baum wird vollständig geprüft,
        # bevor die erste Nutzdatei entfernt wird.
        $target = Assert-M24BackupDeletionTarget -BackupRoot $normalizedRoot -Drive $Drive -Computer $Computer -User $User
        $allItems = New-Object System.Collections.Generic.List[object]
        $pendingDirectories = New-Object 'System.Collections.Generic.Stack[string]'
        $pendingDirectories.Push($target.BackupRoot)
        while ($pendingDirectories.Count -gt 0) {
            $currentDirectory = $pendingDirectories.Pop()
            foreach ($item in @(Get-M24DirectoryEntries -Path $currentDirectory)) {
                if ($item.FullName.Equals($lockFile, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Backup contains a symbolic link or junction. Deletion was refused: $($item.FullName)"
                }
                $allItems.Add($item)
                if ($item.PSIsContainer) { $pendingDirectories.Push($item.FullName) }
            }
        }

        # Dateien zuerst, Verzeichnisse von innen nach außen. Die Metadatendatei
        # bleibt bis zuletzt bestehen, damit ein Teilfehler weiter sicher
        # diagnostiziert und erneut bearbeitet werden kann.
        foreach ($item in @($allItems | Where-Object { -not $_.PSIsContainer -and -not $_.FullName.Equals($target.MetadataFile, [System.StringComparison]::OrdinalIgnoreCase) })) {
            if (Test-M24ReservedDeviceFileName -Name $item.Name) {
                if (-not (Remove-M24ReservedDeviceFile -Path $item.FullName)) {
                    $ignoredDeviceFiles.Add($item.FullName)
                }
                continue
            }
            $currentAttributes = [System.IO.File]::GetAttributes((ConvertTo-M24ExtendedLengthPath $item.FullName))
            if (($currentAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Backup item became a symbolic link before deletion: $($item.FullName)"
            }
            if (-not (Remove-M24FileEntry -Path $item.FullName)) {
                throw "Backup file could not be deleted: $($item.FullName)"
            }
        }
        $directoriesToRemove = @($allItems | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending)
        foreach ($item in $directoriesToRemove) {
            $currentAttributes = [System.IO.File]::GetAttributes((ConvertTo-M24ExtendedLengthPath $item.FullName))
            if (($currentAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Backup directory became a symbolic link or junction before deletion: $($item.FullName)"
            }
            if (-not (Remove-M24DirectoryEntry -Path $item.FullName)) {
                if (Test-M24ReservedDeviceFileName -Name $item.Name) {
                    $ignoredDeviceFiles.Add($item.FullName)
                }
                # Ein nicht entfernbarer reservierter Gerätename kann seine
                # Elternverzeichnisse blockieren. Nach dem Durchlauf wird
                # geprüft, ob wirklich ausschließlich solche Artefakte übrig sind.
            }
        }

        $pendingResidualDirectories = New-Object 'System.Collections.Generic.Stack[string]'
        $pendingResidualDirectories.Push($target.BackupRoot)
        while ($pendingResidualDirectories.Count -gt 0) {
            $residualDirectory = $pendingResidualDirectories.Pop()
            foreach ($residual in @(Get-M24DirectoryEntries -Path $residualDirectory)) {
                if ($residual.FullName.Equals($lockFile, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $residual.FullName.Equals($target.MetadataFile, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                if (($residual.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Backup contents changed to a symbolic link or junction during deletion: $($residual.FullName)"
                }
                if ($residual.PSIsContainer) {
                    $pendingResidualDirectories.Push($residual.FullName)
                    if ((Test-M24ReservedDeviceFileName -Name $residual.Name) -and
                        -not $ignoredDeviceFiles.Contains($residual.FullName)) {
                        $ignoredDeviceFiles.Add($residual.FullName)
                    }
                } elseif (Test-M24ReservedDeviceFileName -Name $residual.Name) {
                    if (-not $ignoredDeviceFiles.Contains($residual.FullName)) { $ignoredDeviceFiles.Add($residual.FullName) }
                } else {
                    throw "Backup contents changed during deletion. Metadata was preserved and deletion stopped."
                }
            }
        }
        Remove-Item -LiteralPath $target.MetadataFile -Force -ErrorAction Stop
    } catch {
        $deletionError = $_
    } finally {
        if ($lockStream) { $lockStream.Dispose() }
        Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
    }

    if ($deletionError) { throw $deletionError }
    foreach ($directory in $directoriesToRemove) {
        $directoryPath = [string]$directory.FullName
        if (-not [string]::IsNullOrWhiteSpace($directoryPath) -and
            [System.IO.Directory]::Exists((ConvertTo-M24ExtendedLengthPath $directoryPath))) {
            [void](Remove-M24DirectoryEntry -Path $directoryPath)
        }
    }
    [void](Remove-M24DirectoryEntry -Path $normalizedRoot)
    $backupRootRemoved = -not [System.IO.Directory]::Exists((ConvertTo-M24ExtendedLengthPath $normalizedRoot))
    if (-not $backupRootRemoved -and $ignoredDeviceFiles.Count -eq 0) {
        throw "Backup directories could not be deleted completely: $normalizedRoot"
    }
    return [pscustomobject]@{
        BackupRoot = $normalizedRoot
        BackupRootRemoved = $backupRootRemoved
        IgnoredDeviceFiles = $ignoredDeviceFiles.Count
        IgnoredDevicePaths = @($ignoredDeviceFiles)
    }
}
