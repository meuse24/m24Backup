function Test-M24GermanUiCulture {
    try {
        $culture = [System.Globalization.CultureInfo]::CurrentUICulture
        return [bool]($culture -and $culture.TwoLetterISOLanguageName -eq 'de')
    } catch {
        return $false
    }
}

# Zweisprachige Oberflaechentexte. GUI und Worker verwendeten dafuer frueher je
# eine eigene, identische Funktion (L bzw. M). Die Auswahl liegt jetzt einmal
# hier; beide Skripte binden ihren gewohnten Kurznamen per Alias daran.
$script:m24IsGerman = $null

function Initialize-M24Localization {
    # Legt die Sprache einmalig fest und gibt sie zurueck, damit der Aufrufer
    # sie in einem Durchgang auch fuer eigene Abfragen uebernehmen kann.
    param([Nullable[bool]]$IsGerman = $null)

    $script:m24IsGerman = if ($null -eq $IsGerman) { Test-M24GermanUiCulture } else { [bool]$IsGerman }
    return $script:m24IsGerman
}

function Get-M24Text {
    param(
        [Parameter(Position = 0)][string]$German,
        [Parameter(Position = 1)][string]$English
    )

    # Ohne vorherige Initialisierung greift die Kultur des laufenden Prozesses.
    if ($null -eq $script:m24IsGerman) { $script:m24IsGerman = Test-M24GermanUiCulture }
    if ($script:m24IsGerman) { return $German }
    return $English
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

function Test-M24SkippedJunctionAccessError {
    # Get-ChildItem kann beim Auflisten alter, absichtlich gesperrter
    # Windows-Kompatibilitaetsjunctions (z. B. "Eigene Bilder" unter
    # "Dokumente") einen Zugriffsfehler melden. Robocopy folgt wegen /XJ
    # ohnehin keinen Junctions. Nur wenn das Fehlerziel tatsaechlich als
    # Junction identifiziert werden kann, darf der Fehler daher zu einem
    # reinen Protokollhinweis herabgestuft werden.
    param([AllowNull()]$ErrorRecord)

    if (-not $ErrorRecord) { return $false }

    $candidates = @()
    if ($ErrorRecord.PSObject.Properties['TargetObject'] -and $null -ne $ErrorRecord.TargetObject) {
        $targetObject = $ErrorRecord.TargetObject
        if ($targetObject.PSObject.Properties['FullName'] -and $targetObject.FullName) {
            $candidates += [string]$targetObject.FullName
        } else {
            $candidates += [string]$targetObject
        }
    }
    if ($ErrorRecord.PSObject.Properties['CategoryInfo'] -and $ErrorRecord.CategoryInfo) {
        $targetName = [string]$ErrorRecord.CategoryInfo.TargetName
        if (-not [string]::IsNullOrWhiteSpace($targetName)) { $candidates += $targetName }
    }
    if ($ErrorRecord.PSObject.Properties['Exception'] -and $ErrorRecord.Exception -and
        $ErrorRecord.Exception.PSObject.Properties['ItemName']) {
        $itemName = [string]$ErrorRecord.Exception.ItemName
        if (-not [string]::IsNullOrWhiteSpace($itemName)) { $candidates += $itemName }
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
            if ([string]$item.LinkType -eq 'Junction') { return $true }
        } catch {
            # Kann selbst die Link-Metainfo nicht sicher gelesen werden, bleibt
            # der urspruengliche Fehler eine echte Vorpruefungswarnung.
        }
    }
    return $false
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

# --- Statusprotokoll zwischen Worker und Oberflaeche ------------------------
#
# Der Worker schreibt seinen Fortschritt als eine Zeile "<TYP>|<Feld>|<Feld>"
# in die Statusdatei, die Oberflaeche liest sie per Timer. Frueher waren Typen
# und Feldpositionen auf beiden Seiten als Literale hinterlegt; eine Aenderung
# fiel erst zur Laufzeit auf. Der Vertrag steht deshalb jetzt einmal hier und
# wird von beiden Seiten benutzt.

function Get-M24StatusMessageContract {
    # Zulaessige Feldformen je Nachrichtentyp, in Uebertragungsreihenfolge.
    # Mehrere Formen bedeuten: Die Feldanzahl entscheidet, welche gilt.
    return [ordered]@{
        'VORSCHAU'        = @(, @('Text'))
        'SCANWARNUNG'     = @(, @('Text'))
        'STATUS'          = @(, @('Text'))
        'FERTIG'          = @(, @('Text'))
        'FEHLER'          = @(, @('Text'))
        'ABGEBROCHEN'     = @(, @('Text'))
        'PRUEFUNG'        = @(, @('Current', 'Total', 'FolderName'))
        'PRUEFSUMME'      = @(, @('Current', 'Total', 'FolderName'))
        'KOPIERVORGANG'   = @(, @('Current', 'Total', 'FolderName'))
        'ABBRUCHLAEUFT'   = @(, @('Current', 'Total', 'FolderName'))
        'FORTSCHRITT'     = @(, @('Current', 'Total', 'FolderName'))
        'ABBRUCHWARTET'   = @(, @('Current', 'Total', 'FolderName', 'WaitedSeconds'))
        'HASHFORTSCHRITT' = @(, @('Files', 'Bytes'))
        # Die Integritaetspruefung meldet zuerst nur eine Ankuendigung und
        # danach den Ordnerfortschritt.
        'RESTOREPRUEFUNG' = @(@('Text'), @('Current', 'Total', 'FolderName'))
    }
}

function Get-M24StatusMessageTypes {
    return @((Get-M24StatusMessageContract).Keys)
}

function Test-M24StatusMessageType {
    param([string]$Type)
    return [bool]((Get-M24StatusMessageContract).Contains($Type))
}

function Format-M24StatusMessage {
    # Baut eine Protokollzeile und prueft dabei Typ und Feldanzahl gegen den
    # Vertrag. Ein unbekannter Typ oder eine falsche Feldzahl ist ein
    # Programmierfehler und wird sofort gemeldet, nicht stillschweigend
    # uebertragen.
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [string[]]$Fields = @()
    )

    $contract = Get-M24StatusMessageContract
    if (-not $contract.Contains($Type)) {
        throw "Unknown status message type '$Type'."
    }
    $forms = @($contract[$Type])
    $matchingForm = @($forms | Where-Object { $_.Count -eq $Fields.Count })
    if ($matchingForm.Count -eq 0) {
        $expected = ($forms | ForEach-Object { $_.Count }) -join ' or '
        throw "Status message '$Type' expects $expected field(s), but $($Fields.Count) were supplied."
    }
    # Trennzeichen in Feldern wuerden die Empfaengerseite verschieben. Nur das
    # letzte Textfeld darf sie enthalten, weil der Parser dort den Rest nimmt.
    for ($index = 0; $index -lt $Fields.Count - 1; $index++) {
        if ([string]$Fields[$index] -match '\|') {
            throw "Status message '$Type' field $index must not contain '|'."
        }
    }
    return (@($Type) + @($Fields)) -join '|'
}

function ConvertFrom-M24StatusMessage {
    # Zerlegt eine Protokollzeile in benannte Felder. Das Ergebnis traegt
    # immer alle bekannten Feldnamen, damit die Oberflaeche ohne
    # Existenzpruefungen darauf zugreifen kann.
    param([string]$Line)

    $result = [pscustomobject]@{
        Type          = ''
        IsKnownType   = $false
        Text          = ''
        Current       = $null
        Total         = $null
        FolderName    = ''
        Files         = $null
        Bytes         = $null
        WaitedSeconds = $null
        Raw           = [string]$Line
    }
    if ([string]::IsNullOrWhiteSpace($Line)) { return $result }

    $trimmed = ([string]$Line).Trim()
    $separatorIndex = $trimmed.IndexOf('|')
    $result.Type = if ($separatorIndex -lt 0) { $trimmed } else { $trimmed.Substring(0, $separatorIndex) }

    $contract = Get-M24StatusMessageContract
    if (-not $contract.Contains($result.Type)) { return $result }
    $result.IsKnownType = $true

    $payload = if ($separatorIndex -lt 0) { '' } else { $trimmed.Substring($separatorIndex + 1) }
    $forms = @($contract[$result.Type])
    $rawFields = @($payload -split '\|')

    # Passende Form ueber die Feldanzahl waehlen; sonst die laengste, die
    # vollstaendig belegt ist.
    $form = @($forms | Where-Object { $_.Count -eq $rawFields.Count } | Select-Object -First 1)
    if (-not $form) {
        $form = @($forms | Where-Object { $_.Count -le $rawFields.Count } | Sort-Object { $_.Count } -Descending | Select-Object -First 1)
    }
    if (-not $form) { $form = @($forms | Sort-Object { $_.Count } | Select-Object -First 1) }
    $fieldNames = @($form[0])

    for ($index = 0; $index -lt $fieldNames.Count; $index++) {
        $name = [string]$fieldNames[$index]
        if ($index -ge $rawFields.Count) { break }
        # Das letzte Textfeld nimmt den gesamten Rest auf, damit eine
        # Fehlermeldung mit '|' nicht abgeschnitten wird.
        $value = if ($name -eq 'Text' -and $index -eq $fieldNames.Count - 1) {
            ($rawFields[$index..($rawFields.Count - 1)]) -join '|'
        } else {
            [string]$rawFields[$index]
        }

        switch ($name) {
            { $_ -in @('Current', 'Total', 'WaitedSeconds') } {
                $parsed = 0
                if ([int]::TryParse($value, [ref]$parsed)) { $result.$name = $parsed }
                break
            }
            { $_ -in @('Files', 'Bytes') } {
                $parsed = [int64]0
                if ([int64]::TryParse($value, [ref]$parsed)) { $result.$name = $parsed }
                break
            }
            default { $result.$name = $value }
        }
    }
    return $result
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
        # Bewusst kein ValidateSet: Die Parameterbindung laeuft vor dem try
        # und wuerde bei einem unbekannten Wert werfen. Unbekannte Werte
        # werden stattdessen im Funktionskoerper auf 'Info' abgebildet.
        [string]$Severity = 'Error',
        [string]$Context,
        [string]$LogDirectory,
        [int64]$MaxBytes = 2MB,
        [int]$FileCount = 5
    )

    try {
        if (@('Info', 'Warning', 'Error') -notcontains $Severity) { $Severity = 'Info' }
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

function Get-M24GuiMutexName {
    param([string]$UserSid)

    if ([string]::IsNullOrWhiteSpace($UserSid)) {
        $UserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $sidBytes = [System.Text.Encoding]::UTF8.GetBytes($UserSid)
        $sidHash = ([BitConverter]::ToString($sha256.ComputeHash($sidBytes))).Replace('-', '').Substring(0, 16)
    } finally {
        $sha256.Dispose()
    }
    return "Local\M24Backup.GUI.$sidHash"
}

function Get-M24BackupReminderState {
    param(
        [AllowNull()][string]$LastSuccessfulBackup,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now,
        [int]$ThresholdDays = 14
    )

    $effectiveThreshold = [Math]::Max(1, [Math]::Min(3650, $ThresholdDays))
    $lastBackup = [DateTimeOffset]::MinValue
    $parsed = -not [string]::IsNullOrWhiteSpace($LastSuccessfulBackup) -and
        [DateTimeOffset]::TryParse(
            $LastSuccessfulBackup,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$lastBackup)
    if (-not $parsed) {
        return [pscustomobject]@{
            IsDue = $true
            NeverBackedUp = $true
            DaysSinceBackup = $null
            ThresholdDays = $effectiveThreshold
        }
    }

    $age = $Now.ToUniversalTime() - $lastBackup.ToUniversalTime()
    $ageDays = [Math]::Max(0, [int][Math]::Floor($age.TotalDays))
    return [pscustomobject]@{
        IsDue = [bool]($age.TotalDays -ge $effectiveThreshold)
        NeverBackedUp = $false
        DaysSinceBackup = $ageDays
        ThresholdDays = $effectiveThreshold
    }
}

function Get-M24StartupReminderCommand {
    param(
        [Parameter(Mandatory = $true)][string]$VbsPath,
        [string]$WscriptPath
    )

    if ([string]::IsNullOrWhiteSpace($WscriptPath)) {
        $WscriptPath = Join-Path ([Environment]::SystemDirectory) 'wscript.exe'
    }
    $fullVbsPath = [System.IO.Path]::GetFullPath($VbsPath)
    $fullWscriptPath = [System.IO.Path]::GetFullPath($WscriptPath)
    return ('"{0}" "{1}" /SilentStartup' -f $fullWscriptPath, $fullVbsPath)
}

function Get-M24StartupReminderRegistration {
    param(
        [string]$RegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        [string]$ValueName = 'M24Backup'
    )

    try {
        if (-not (Test-Path -LiteralPath $RegistryPath -ErrorAction Stop)) { return $null }
        $item = Get-ItemProperty -LiteralPath $RegistryPath -Name $ValueName -ErrorAction Stop
        return [string]$item.$ValueName
    } catch [System.Management.Automation.PSArgumentException] {
        return $null
    } catch [System.Management.Automation.ItemNotFoundException] {
        return $null
    }
}

function Set-M24StartupReminderRegistration {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$RegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        [string]$ValueName = 'M24Backup'
    )

    # The Windows Run key is shared with other applications. Recreating an
    # existing registry key with New-Item -Force can discard its other values.
    if (-not (Test-Path -LiteralPath $RegistryPath -ErrorAction Stop)) {
        [void](New-Item -Path $RegistryPath -ErrorAction Stop)
    }
    [void](New-ItemProperty -LiteralPath $RegistryPath -Name $ValueName -Value $Command -PropertyType String -Force -ErrorAction Stop)
}

function Remove-M24StartupReminderRegistration {
    param(
        [string]$RegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        [string]$ValueName = 'M24Backup'
    )

    try {
        if (-not (Test-Path -LiteralPath $RegistryPath -ErrorAction Stop)) { return }
        Remove-ItemProperty -LiteralPath $RegistryPath -Name $ValueName -Force -ErrorAction Stop
    } catch [System.Management.Automation.PSArgumentException] {
        # An already missing value is the desired state.
    } catch [System.Management.Automation.ItemNotFoundException] {
        # An already missing key/value is the desired state.
    }
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

function New-M24HashBuffer {
    # Ein Puffer je Scan statt je Datei. 1 MiB liegt oberhalb der Grenze von
    # 85 KiB und landet damit im Large Object Heap, der nicht kompaktiert wird
    # und Sammlungen der Generation 2 ausloest. Eine Allokation pro Datei war
    # gemessen der groesste Einzelposten der Pruefsummenberechnung.
    #
    # Das fuehrende Komma ist zwingend: Ohne es entrollt PowerShell das Array
    # beim Rueckgeben und der Aufrufer erhaelt ein object[] mit einzeln
    # geboxten Bytes. Jeder Stream.Read() muesste dieses dann konvertieren,
    # was die Pruefsummenberechnung um Groessenordnungen verlangsamt.
    return , (New-Object byte[] (1MB))
}

function Get-M24FileSha256 {
    param([string]$Path, [scriptblock]$CancelCallback, [byte[]]$Buffer)
    $stream = $null
    $sha = $null
    try {
        $stream = [System.IO.File]::Open((ConvertTo-M24ExtendedLengthPath $Path), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        # Ohne uebergebenen Puffer verhaelt sich die Funktion wie bisher. Der
        # Aufrufer kann denselben Puffer ueber einen ganzen Scan wiederverwenden;
        # parallele Aufrufe muessen dann getrennte Puffer verwenden.
        #
        # Bewusst zwei Anweisungen statt einer if-Zuweisung: PowerShell entrollt
        # ein Array, das als Wert eines if-Ausdrucks zurueckkommt, und sammelt es
        # als object[] mit einzeln geboxten Bytes neu ein.
        $workBuffer = $Buffer
        if ($null -eq $workBuffer -or $workBuffer.Length -eq 0) { $workBuffer = New-M24HashBuffer }
        # Read() darf jederzeit weniger Bytes liefern als angefordert, auch bei
        # lokalen Dateien. Deshalb bleibt dies eine Schleife, und es werden
        # ausschliesslich die tatsaechlich gelesenen Bytes gehasht. Wuerde hier
        # $workBuffer.Length statt $read stehen, flossen bei einem geteilten
        # Puffer Reste der vorherigen Datei in den Hash ein.
        while (($read = $stream.Read($workBuffer, 0, $workBuffer.Length)) -gt 0) {
            if ($CancelCallback -and (& $CancelCallback)) { return $null }
            [void]$sha.TransformBlock($workBuffer, 0, $read, $null, 0)
        }
        [void]$sha.TransformFinalBlock($workBuffer, 0, 0)
        return ([System.BitConverter]::ToString($sha.Hash)).Replace('-', '')
    } finally {
        if ($sha) { $sha.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Test-M24Sha256HexValue {
    # Ein beschaedigter Manifestwert wuerde bei jeder Folgesicherung erneut
    # uebernommen und dadurch dauerhaft konserviert. Vor der Wiederverwendung
    # wird deshalb das Format geprueft.
    param([string]$Value)
    if ($null -eq $Value -or $Value.Length -ne 64) { return $false }
    return ($Value -match '^[0-9a-fA-F]{64}$')
}

function Get-M24ScanDirectories {
    # Liefert den Startordner und alle zu durchsuchenden Unterordner.
    #
    # Bewusst nicht ueber Get-ChildItem -Recurse: Der FileSystem-Provider
    # erzeugt pro Eintrag zusaetzliche Objekte und ist bei vielen kleinen
    # Dateien um ein Vielfaches langsamer als DirectoryInfo. EnumerateDirectories
    # liefert ausserdem kein vollstaendiges Array, was bei sehr grossen
    # Verzeichnissen eine Sammelallokation vermeidet.
    #
    # Reparse Points werden nicht betreten. Das entspricht exakt dem Verhalten
    # von Get-ChildItem -Recurse und verhindert, dass Junctions die Sicherung in
    # fremde Baeume oder in Schleifen fuehren.
    param(
        [string]$Path,
        [System.Collections.IList]$ErrorSink,
        [scriptblock]$CancelCallback
    )
    $directories = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
    $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $cancelled = $false
    try {
        $pending.Push((New-Object System.IO.DirectoryInfo $Path))
    } catch {
        [void]$ErrorSink.Add($_.Exception)
        return [pscustomobject]@{ Directories = $directories; Cancelled = $false }
    }
    while ($pending.Count -gt 0) {
        # Ein Abbruch waehrend der Aufzaehlung muss als Abbruch gemeldet werden.
        # Wuerde hier nur eine unvollstaendige Liste zurueckkommen, hielte der
        # Aufrufer den Scan faelschlich fuer vollstaendig und schriebe ein
        # verkuerztes Manifest.
        if ($CancelCallback -and (& $CancelCallback)) { $cancelled = $true; break }
        $current = $pending.Pop()
        $directories.Add($current)
        # Ein unzugaenglicher Unterordner darf den gesamten Lauf nicht
        # abbrechen; der Fehler wird gesammelt und der Aufrufer entscheidet.
        # Die Ausnahme kann bei einer verzoegerten Aufzaehlung auch erst
        # waehrend der Iteration auftreten, deshalb umschliesst der Schutz die
        # gesamte Schleife und nicht nur deren Beginn.
        try {
            foreach ($child in $current.EnumerateDirectories()) {
                if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $pending.Push($child)
            }
        } catch {
            [void]$ErrorSink.Add($_.Exception)
        }
    }
    return [pscustomobject]@{ Directories = $directories; Cancelled = $cancelled }
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

function Get-M24ChecksumMetrics {
    # EnumerationMilliseconds misst ausschliesslich das Durchlaufen der
    # Verzeichnisstruktur. OverheadMilliseconds ist der Rest: Metadatenvergleich,
    # Dateiaufzaehlung innerhalb eines Verzeichnisses, Ausschlussfilter,
    # Dictionary-Pflege, Fortschrittsmeldungen und Fehlerbehandlung. Beide
    # zusammen mit Hashen und Manifest-Ein-/Ausgabe ergeben die Gesamtdauer und
    # zeigen im Protokoll, ob Datentraeger, Aufzaehlung oder CPU begrenzt.
    param(
        [System.Diagnostics.Stopwatch]$TotalWatch,
        [System.Diagnostics.Stopwatch]$HashWatch,
        [System.Diagnostics.Stopwatch]$EnumerationWatch,
        [System.Diagnostics.Stopwatch]$ManifestReadWatch,
        [System.Diagnostics.Stopwatch]$ManifestWriteWatch,
        [int64]$HashedBytes
    )
    [int64]$total = $TotalWatch.ElapsedMilliseconds
    [int64]$hash = $HashWatch.ElapsedMilliseconds
    [int64]$enumeration = if ($EnumerationWatch) { $EnumerationWatch.ElapsedMilliseconds } else { 0 }
    [int64]$read = if ($ManifestReadWatch) { $ManifestReadWatch.ElapsedMilliseconds } else { 0 }
    [int64]$write = if ($ManifestWriteWatch) { $ManifestWriteWatch.ElapsedMilliseconds } else { 0 }
    [int64]$overhead = $total - $hash - $enumeration - $read - $write
    if ($overhead -lt 0) { $overhead = 0 }
    $hashSeconds = $HashWatch.Elapsed.TotalSeconds
    $throughput = if ($hashSeconds -gt 0) { [math]::Round((($HashedBytes / 1MB) / $hashSeconds), 1) } else { [double]0 }
    return [pscustomobject]@{
        EnumerationMilliseconds = $enumeration
        OverheadMilliseconds = $overhead
        HashMilliseconds = $hash
        ManifestReadMilliseconds = $read
        ManifestWriteMilliseconds = $write
        TotalMilliseconds = $total
        AverageHashMegabytesPerSecond = $throughput
    }
}

function Update-M24ChecksumManifest {
    param(
        [array]$Folders,
        [string]$ManifestPath,
        [string[]]$ExcludedFiles,
        [switch]$ForceRehash,
        [scriptblock]$StatusCallback,
        [scriptblock]$CancelCallback,
        [scriptblock]$ProgressCallback
    )
    $totalWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $hashWatch = New-Object System.Diagnostics.Stopwatch
    $enumerationWatch = New-Object System.Diagnostics.Stopwatch
    $manifestReadWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $manifest = Read-M24ChecksumManifest -Path $ManifestPath
    $manifestReadWatch.Stop()
    $entries = $manifest.Entries
    [int64]$fileCount = 0; [int64]$hashedFiles = 0; [int64]$reusedFiles = 0; [int64]$totalBytes = 0
    [int64]$hashedBytes = 0; [int64]$reusedBytes = 0
    [int64]$skippedDeviceFiles = 0
    # Ein Puffer fuer den gesamten Lauf statt einer Allokation je Datei.
    $buffer = New-M24HashBuffer
    $progressWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $progressReported = $false
    $folderIndex = 0
    foreach ($folder in $Folders) {
        $folderIndex++
        if ($StatusCallback) { & $StatusCallback $folderIndex @($Folders).Count $folder.Name }
        $scanErrors = New-Object 'System.Collections.Generic.List[object]'
        $cancelled = $false
        $fatalError = $null
        $rootLength = ([string]$folder.Path).TrimEnd('\').Length
        $enumerationWatch.Start()
        try {
            $scan = Get-M24ScanDirectories -Path $folder.Path -ErrorSink $scanErrors -CancelCallback $CancelCallback
        } finally {
            $enumerationWatch.Stop()
        }
        if ($scan.Cancelled) { $cancelled = $true }
        foreach ($directory in $scan.Directories) {
            if ($cancelled -or $fatalError) { break }
            try {
                foreach ($file in $directory.EnumerateFiles()) {
                    if ($CancelCallback -and (& $CancelCallback)) { $cancelled = $true; break }
                    if (Test-M24ExcludedFileName -Name $file.Name -Patterns $ExcludedFiles) { continue }
                    $relative = $file.FullName.Substring($rootLength).TrimStart('\')
                    $entryPath = "{0}\{1}" -f $folder.Name, $relative
                    $existing = if ($entries.ContainsKey($entryPath)) { $entries[$entryPath] } else { $null }
                    $hash = $null
                    # Zielmetadaten werden exakt verglichen. Eine Zeit-Toleranz koennte
                    # gleich grosse, innerhalb des FAT/exFAT-Fensters geaenderte Dateien uebersehen.
                    # Ein formal ungueltiger Altwert wird nicht uebernommen, sondern
                    # neu berechnet; sonst bliebe eine Beschaedigung dauerhaft erhalten.
                    [int64]$entryLength = $file.Length
                    [int64]$entryTicks = $file.LastWriteTimeUtc.Ticks
                    if (-not $ForceRehash -and $existing -and $existing.Length -eq $entryLength -and $existing.LastWriteUtcTicks -eq $entryTicks -and (Test-M24Sha256HexValue -Value ([string]$existing.Sha256))) {
                        $hash = $existing.Sha256; $reusedFiles++; $reusedBytes += $entryLength
                    } else {
                        # Die Metadaten stammen aus der Aufzaehlung, der Hash aus
                        # einem spaeteren Lesevorgang. Aendert sich die Datei
                        # dazwischen, beschriebe der Manifesteintrag eine
                        # Kombination, die es nie gab. Deshalb wird nach dem
                        # Hashen geprueft, ob Groesse und Zeitstempel noch
                        # stimmen; eine einmalige Aenderung fuehrt zu einem
                        # zweiten Versuch, anhaltende Instabilitaet zum Abbruch.
                        # Die Pruefung ist bewusst hier eingebettet: Eine eigene
                        # Funktion je Datei kostete in der Messung mehr als der
                        # zusaetzliche Metadatenzugriff selbst.
                        $hash = $null
                        $hashAttempts = 0
                        $hashStable = $false
                        $deviceSkipped = $false
                        while (-not $hashStable -and $hashAttempts -lt 2) {
                            $hashAttempts++
                            $entryLength = [int64]$file.Length
                            $entryTicks = [int64]$file.LastWriteTimeUtc.Ticks
                            $hashWatch.Start()
                            try {
                                $hash = Get-M24FileSha256 -Path $file.FullName -CancelCallback $CancelCallback -Buffer $buffer
                            } catch {
                                # Nur Dateien mit reservierten Geraetenamen (z. B. "nul")
                                # duerfen bei einem Zugriffsfehler stillschweigend ohne
                                # Pruefsumme bleiben; echte Lesefehler brechen weiter ab.
                                if (Test-M24ReservedDeviceFileName -Name $file.Name) { $deviceSkipped = $true }
                                else { $fatalError = $_.Exception }
                            } finally {
                                $hashWatch.Stop()
                            }
                            if ($deviceSkipped -or $fatalError) { break }
                            if ($null -eq $hash) { $cancelled = $true; break }
                            try {
                                $file.Refresh()
                                $hashStable = ([int64]$file.Length -eq $entryLength -and [int64]$file.LastWriteTimeUtc.Ticks -eq $entryTicks)
                            } catch {
                                $fatalError = New-Object System.IO.IOException ("File disappeared while it was being hashed: {0}" -f $file.FullName)
                                break
                            }
                        }
                        if ($deviceSkipped) { $skippedDeviceFiles++; continue }
                        if ($fatalError -or $cancelled) { break }
                        if (-not $hashStable) {
                            $fatalError = New-Object System.IO.IOException ("File kept changing while it was being hashed: {0}" -f $file.FullName)
                            break
                        }
                        $hashedFiles++; $hashedBytes += $entryLength
                    }
                    $entries[$entryPath] = [pscustomobject]@{ Path = $entryPath; Length = $entryLength; LastWriteUtcTicks = $entryTicks; Sha256 = $hash }
                    $fileCount++; $totalBytes += $entryLength
                    # Die erste Meldung kommt sofort, damit die Oberflaeche nicht
                    # stumm bleibt; danach gedrosselt, weil ein Ereignis je Datei
                    # bei kleinen Dateien selbst zum Leistungsproblem wuerde.
                    if ($ProgressCallback -and (-not $progressReported -or $progressWatch.ElapsedMilliseconds -ge 250)) {
                        $progressReported = $true
                        $progressWatch.Restart()
                        & $ProgressCallback $fileCount $totalBytes $directory.FullName
                    }
                }
            } catch {
                # Aufzaehlungsfehler werden gesammelt, nicht verschluckt.
                [void]$scanErrors.Add($_.Exception)
            }
        }
        # Ein unvollstaendiger Scan darf niemals als neues gueltiges Manifest
        # geschrieben werden. Der Worker markiert den gesamten Lauf als Fehler.
        if ($fatalError) { throw $fatalError }
        if ($scanErrors.Count) { throw $scanErrors[0] }
        if ($cancelled) { return [pscustomobject]@{ Cancelled = $true; Files = $fileCount; HashedFiles = $hashedFiles; ReusedFiles = $reusedFiles; Bytes = $totalBytes; SkippedDeviceFiles = $skippedDeviceFiles } }
    }
    $manifestWriteWatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-M24ChecksumManifest -Path $ManifestPath -Entries $entries
    $manifestWriteWatch.Stop()
    $totalWatch.Stop()
    $metrics = Get-M24ChecksumMetrics -TotalWatch $totalWatch -HashWatch $hashWatch -EnumerationWatch $enumerationWatch -ManifestReadWatch $manifestReadWatch -ManifestWriteWatch $manifestWriteWatch -HashedBytes $hashedBytes
    return [pscustomobject]@{
        Cancelled = $false
        Files = $fileCount
        HashedFiles = $hashedFiles
        ReusedFiles = $reusedFiles
        Bytes = $totalBytes
        HashedBytes = $hashedBytes
        ReusedBytes = $reusedBytes
        SkippedDeviceFiles = $skippedDeviceFiles
        EnumerationMilliseconds = $metrics.EnumerationMilliseconds
        OverheadMilliseconds = $metrics.OverheadMilliseconds
        HashMilliseconds = $metrics.HashMilliseconds
        ManifestReadMilliseconds = $metrics.ManifestReadMilliseconds
        ManifestWriteMilliseconds = $metrics.ManifestWriteMilliseconds
        TotalMilliseconds = $metrics.TotalMilliseconds
        AverageHashMegabytesPerSecond = $metrics.AverageHashMegabytesPerSecond
    }
}

function Test-M24ChecksumManifest {
    param(
        [array]$Folders,
        [string]$ManifestPath,
        [string[]]$ExcludedFiles,
        [scriptblock]$StatusCallback,
        [scriptblock]$CancelCallback,
        [scriptblock]$ProgressCallback
    )
    $totalWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $hashWatch = New-Object System.Diagnostics.Stopwatch
    $enumerationWatch = New-Object System.Diagnostics.Stopwatch
    $manifestReadWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $manifest = Read-M24ChecksumManifest -Path $ManifestPath
    $manifestReadWatch.Stop()
    if (-not $manifest.Exists) {
        return [pscustomobject]@{ Cancelled = $false; MissingManifest = $true; Files = 0; Bytes = 0; ErrorCount = 1; Errors = @('Checksum manifest missing.') }
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    [int64]$files = 0; [int64]$bytes = 0; [int]$errorCount = 0; $errors = @(); $folderIndex = 0
    # Ein Puffer fuer den gesamten Lauf statt einer Allokation je Datei.
    $buffer = New-M24HashBuffer
    $progressWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $progressReported = $false
    foreach ($folder in $Folders) {
        $folderIndex++
        if ($StatusCallback) { & $StatusCallback $folderIndex @($Folders).Count $folder.Name }
        $scanErrors = New-Object 'System.Collections.Generic.List[object]'
        $cancelled = $false
        $rootLength = ([string]$folder.Path).TrimEnd('\').Length
        $enumerationWatch.Start()
        try {
            $scan = Get-M24ScanDirectories -Path $folder.Path -ErrorSink $scanErrors -CancelCallback $CancelCallback
        } finally {
            $enumerationWatch.Stop()
        }
        if ($scan.Cancelled) { $cancelled = $true }
        foreach ($directory in $scan.Directories) {
            if ($cancelled) { break }
            try {
                foreach ($file in $directory.EnumerateFiles()) {
                    if ($CancelCallback -and (& $CancelCallback)) { $cancelled = $true; break }
                    if (Test-M24ExcludedFileName -Name $file.Name -Patterns $ExcludedFiles) { continue }
                    $relative = $file.FullName.Substring($rootLength).TrimStart('\')
                    $path = "{0}\{1}" -f $folder.Name, $relative
                    [void]$seen.Add($path)
                    try {
                        $hashWatch.Start()
                        try {
                            $hash = Get-M24FileSha256 -Path $file.FullName -CancelCallback $CancelCallback -Buffer $buffer
                        } finally {
                            $hashWatch.Stop()
                        }
                        if ($null -eq $hash) { $cancelled = $true; break }
                        $files++; $bytes += $file.Length
                        if (-not $manifest.Entries.ContainsKey($path)) { throw "Checksum entry missing: $path" }
                        if (-not $hash.Equals([string]$manifest.Entries[$path].Sha256, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Checksum mismatch: $path" }
                    } catch {
                        # Dateien mit reservierten Geraetenamen (z. B. "nul") gelten
                        # nie als Integritaetsfehler; sie sind Artefakte ohne Nutzwert.
                        if (Test-M24ReservedDeviceFileName -Name $file.Name) { continue }
                        $errorCount++; if ($errors.Count -lt 10) { $errors += $_.Exception.Message }
                    }
                    # Die erste Meldung kommt sofort, damit die Oberflaeche nicht
                    # stumm bleibt; danach gedrosselt, weil ein Ereignis je Datei
                    # bei kleinen Dateien selbst zum Leistungsproblem wuerde.
                    if ($ProgressCallback -and (-not $progressReported -or $progressWatch.ElapsedMilliseconds -ge 250)) {
                        $progressReported = $true
                        $progressWatch.Restart()
                        & $ProgressCallback $files $bytes $directory.FullName
                    }
                }
            } catch {
                # Aufzaehlungsfehler werden gesammelt, nicht verschluckt.
                [void]$scanErrors.Add($_.Exception)
            }
        }
        if ($cancelled) {
            return [pscustomobject]@{ Cancelled = $true; MissingManifest = $false; Files = $files; Bytes = $bytes; ErrorCount = $errorCount; Errors = @($errors) }
        }
        foreach ($scanError in $scanErrors) { $errorCount++; if ($errors.Count -lt 10) { $errors += $scanError.Message } }
    }
    foreach ($entry in $manifest.Entries.Values) {
        $entryLeafName = Split-Path -Path ([string]$entry.Path) -Leaf
        if (Test-M24ReservedDeviceFileName -Name $entryLeafName) { continue }
        if (-not $seen.Contains([string]$entry.Path)) { $errorCount++; if ($errors.Count -lt 10) { $errors += "File missing: $($entry.Path)" } }
    }
    $totalWatch.Stop()
    $metrics = Get-M24ChecksumMetrics -TotalWatch $totalWatch -HashWatch $hashWatch -EnumerationWatch $enumerationWatch -ManifestReadWatch $manifestReadWatch -ManifestWriteWatch $null -HashedBytes $bytes
    return [pscustomobject]@{
        Cancelled = $false
        MissingManifest = $false
        Files = $files
        Bytes = $bytes
        HashedBytes = $bytes
        ErrorCount = $errorCount
        Errors = @($errors)
        EnumerationMilliseconds = $metrics.EnumerationMilliseconds
        OverheadMilliseconds = $metrics.OverheadMilliseconds
        HashMilliseconds = $metrics.HashMilliseconds
        ManifestReadMilliseconds = $metrics.ManifestReadMilliseconds
        TotalMilliseconds = $metrics.TotalMilliseconds
        AverageHashMegabytesPerSecond = $metrics.AverageHashMegabytesPerSecond
    }
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
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($root -and $fullPath.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $root
    }
    return $fullPath.TrimEnd('\')
}

function Test-M24IsPathRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathRooted($Path)) { return $false }
    $normalized = Get-NormalizedFullPath $Path
    $root = [System.IO.Path]::GetPathRoot($normalized)
    if ([string]::IsNullOrWhiteSpace($root)) { return $false }
    $normalizedRoot = Get-NormalizedFullPath $root
    return $normalized.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-M24PathRelationship {
    param([string]$FirstPath, [string]$SecondPath)

    $first = Get-NormalizedFullPath $FirstPath
    $second = Get-NormalizedFullPath $SecondPath
    if ($first.Equals($second, [System.StringComparison]::OrdinalIgnoreCase)) { return 'Same' }

    $firstPrefix = if ($first.EndsWith('\')) { $first } else { "$first\" }
    $secondPrefix = if ($second.EndsWith('\')) { $second } else { "$second\" }
    if ($second.StartsWith($firstPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return 'FirstContainsSecond' }
    if ($first.StartsWith($secondPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return 'SecondContainsFirst' }
    return 'None'
}

function Test-IsSameOrNestedPath {
    param([string]$FirstPath, [string]$SecondPath)
    return (Get-M24PathRelationship -FirstPath $FirstPath -SecondPath $SecondPath) -ne 'None'
}

function Get-M24FolderPathConflicts {
    param([object[]]$Folders)

    $validFolders = @()
    foreach ($folder in @($Folders)) {
        if (-not $folder -or -not $folder.PSObject.Properties['Path'] -or [string]::IsNullOrWhiteSpace([string]$folder.Path)) { continue }
        try {
            [void](Get-NormalizedFullPath ([string]$folder.Path))
        } catch {
            $folderName = if ($folder.PSObject.Properties['Name'] -and $folder.Name) { [string]$folder.Name } else { '<unknown>' }
            throw (New-Object System.ArgumentException(("Folder path for '{0}' is invalid: {1}" -f $folderName, $folder.Path), $_.Exception))
        }
        $validFolders += $folder
    }
    $conflicts = @()
    for ($firstIndex = 0; $firstIndex -lt $validFolders.Count; $firstIndex++) {
        for ($secondIndex = $firstIndex + 1; $secondIndex -lt $validFolders.Count; $secondIndex++) {
            $firstFolder = $validFolders[$firstIndex]
            $secondFolder = $validFolders[$secondIndex]
            $relationship = Get-M24PathRelationship -FirstPath ([string]$firstFolder.Path) -SecondPath ([string]$secondFolder.Path)
            if ($relationship -eq 'None') { continue }

            $parent = $firstFolder
            $child = $secondFolder
            if ($relationship -eq 'SecondContainsFirst') {
                $parent = $secondFolder
                $child = $firstFolder
            }
            $conflicts += [pscustomobject]@{
                Relationship = $relationship
                First = $firstFolder
                Second = $secondFolder
                Parent = $parent
                Child = $child
                FirstPath = Get-NormalizedFullPath ([string]$firstFolder.Path)
                SecondPath = Get-NormalizedFullPath ([string]$secondFolder.Path)
            }
        }
    }
    return @($conflicts)
}

function Get-M24BackupRoot {
    param(
        [string]$Drive,
        [string]$Computer = $env:COMPUTERNAME,
        [string]$User = $env:USERNAME
    )
    return Join-Path $Drive ("Bibliothekssicherung\{0}_{1}" -f $Computer, $User)
}

function Test-M24BackupExistsOnDrive {
    # Wurde von diesem Computer und Benutzer schon einmal auf dieses Laufwerk
    # gesichert? Ausschlaggebend ist die Metadatendatei: Der Worker legt sie
    # vor dem ersten Kopiervorgang an, sie belegt also auch einen
    # abgebrochenen oder fehlgeschlagenen Versuch.
    #
    # Die Oberflaeche entscheidet daran, ob eine einmalige Rueckfrage zur
    # Laufwerkswahl noch angebracht ist. Ein Erfolg wird bewusst nicht
    # verlangt - die Wahl des Ziels war auch dann schon eine bewusste.
    param(
        [string]$Drive,
        [string]$Computer = $env:COMPUTERNAME,
        [string]$User = $env:USERNAME
    )

    if ([string]::IsNullOrWhiteSpace($Drive)) { return $false }
    # Lokal auf Stop: Ein abgezogenes Laufwerk laesst Join-Path scheitern.
    # Ohne diese Festlegung haengt es von der Aufrufumgebung ab, ob daraus
    # eine Ausnahme oder eine Ausgabe im Fehlerstrom wird.
    $ErrorActionPreference = 'Stop'
    try {
        $metadataFile = Join-Path (Get-M24BackupRoot -Drive $Drive -Computer $Computer -User $User) '_Sicherungsinfo.txt'
        return [bool](Test-Path -LiteralPath $metadataFile -PathType Leaf)
    } catch {
        # Ohne auswertbaren Pfad gilt die Sicherung als nicht vorhanden; die
        # Rueckfrage erscheint dann lieber einmal zu viel als zu wenig.
        return $false
    }
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

function Get-M24BackupResultInfo {
    param([string[]]$Lines)

    $resultLine = [string]($Lines | Where-Object { $_ -like 'Ergebnis:*' } | Select-Object -Last 1)
    $lastResult = ''
    $completedAt = $null
    if ($resultLine -match '^Ergebnis:\s*(.+?)\s+am\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.?$') {
        $lastResult = $matches[1].Trim()
        $parsedDate = [datetime]::MinValue
        if ([datetime]::TryParseExact($matches[2], 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsedDate)) {
            $completedAt = $parsedDate
        }
    } elseif ($resultLine -match '^Ergebnis:\s*(.+?)\.?$') {
        $lastResult = $matches[1].Trim().TrimEnd('.')
    }

    return [pscustomobject]@{
        Result = $lastResult
        CompletedAt = $completedAt
        IsComplete = [bool](
            $completedAt -and
            $lastResult.Equals('Erfolgreich abgeschlossen', [System.StringComparison]::OrdinalIgnoreCase)
        )
    }
}

function Resolve-M24RestoreSource {
    param(
        [string]$Drive,
        [string]$BackupSource
    )

    if ([string]::IsNullOrWhiteSpace($Drive)) { throw 'Backup drive is missing.' }
    if ([string]::IsNullOrWhiteSpace($BackupSource)) { throw 'Backup source is missing.' }

    $inventoryRoot = Get-NormalizedFullPath (Join-Path $Drive 'Bibliothekssicherung')
    $sourceRoot = Get-NormalizedFullPath $BackupSource
    if (-not (Test-Path -LiteralPath $inventoryRoot -PathType Container)) {
        throw "Backup inventory directory was not found: $inventoryRoot"
    }
    $inventoryItem = Get-Item -LiteralPath $inventoryRoot -Force -ErrorAction Stop
    if (($inventoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Backup inventory directory is a symbolic link or junction.'
    }
    $sourceParent = Get-NormalizedFullPath (Split-Path -Path $sourceRoot -Parent)
    if (-not $sourceParent.Equals($inventoryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Backup source is not a direct child of the expected backup directory.'
    }
    $sourceName = Split-Path -Path $sourceRoot -Leaf
    if ([string]::IsNullOrWhiteSpace($sourceName) -or $sourceName.StartsWith('_') -or (Get-ReservedBackupNames) -contains $sourceName) {
        throw 'Backup source has a reserved name.'
    }
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "Backup source was not found: $sourceRoot"
    }
    $sourceItem = Get-Item -LiteralPath $sourceRoot -Force -ErrorAction Stop
    if (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Backup source is a symbolic link or junction.'
    }
    return $sourceRoot
}

function Get-M24BackupInventory {
    param(
        [string]$Drive,
        [string]$Computer = $env:COMPUTERNAME,
        [string]$User = $env:USERNAME
    )

    $inventoryRoot = Join-Path $Drive 'Bibliothekssicherung'
    if (-not (Test-Path -LiteralPath $inventoryRoot -PathType Container)) { return @() }
    try {
        $inventoryItem = Get-Item -LiteralPath $inventoryRoot -Force -ErrorAction Stop
        if (($inventoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return @() }
    } catch {
        return @()
    }

    $items = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $inventoryRoot -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $metadataReadable = $false
        $metadataLines = @()
        $identity = [pscustomobject]@{ Computer = ''; User = '' }
        $lastResult = ''
        $lastCompletedAt = $null
        $isComplete = $false
        $rootPath = $null
        $structurallySafe = $false
        $availableFolders = @()
        try {
            $rootPath = Resolve-M24RestoreSource -Drive $Drive -BackupSource $directory.FullName
            $structurallySafe = $true
            $availableFolders = @(Get-ChildItem -LiteralPath $rootPath -Directory -Force -ErrorAction Stop |
                Where-Object {
                    -not $_.Name.StartsWith('_') -and
                    ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0
                } |
                ForEach-Object { [string]$_.Name } |
                Sort-Object -Unique)

            $metadataFile = Join-Path $rootPath '_Sicherungsinfo.txt'
            if (Test-Path -LiteralPath $metadataFile -PathType Leaf) {
                $metadataLines = @(Get-Content -LiteralPath $metadataFile -ErrorAction Stop)
                $identity = Get-M24BackupMetadataIdentity -Lines $metadataLines
                $metadataReadable = -not [string]::IsNullOrWhiteSpace($identity.Computer) -and
                    -not [string]::IsNullOrWhiteSpace($identity.User)
                $resultInfo = Get-M24BackupResultInfo -Lines $metadataLines
                $lastResult = [string]$resultInfo.Result
                $lastCompletedAt = $resultInfo.CompletedAt
                $isComplete = [bool]$resultInfo.IsComplete
            }
        } catch {
            $structurallySafe = $false
            $availableFolders = @()
        }

        $displayName = [string]$directory.Name
        $isCurrentProfile = $metadataReadable -and
            $identity.Computer.Equals($Computer, [System.StringComparison]::OrdinalIgnoreCase) -and
            $identity.User.Equals($User, [System.StringComparison]::OrdinalIgnoreCase)
        $manifestPath = if ($rootPath) { Join-Path $rootPath (Get-M24ChecksumManifestName) } else { $null }
        $metadataPath = if ($rootPath) { Join-Path $rootPath '_Sicherungsinfo.txt' } else { $null }
        $items += [pscustomobject]@{
            RootPath = $(if ($rootPath) { $rootPath } else { [string]$directory.FullName })
            Computer = [string]$identity.Computer
            User = [string]$identity.User
            DisplayName = $displayName
            LastResult = $lastResult
            LastCompletedAt = $lastCompletedAt
            IsComplete = [bool]$isComplete
            ChecksumManifestExists = [bool]($manifestPath -and (Test-Path -LiteralPath $manifestPath -PathType Leaf))
            ChecksumsVerifiedAt = $(if ($metadataReadable) { Get-M24ChecksumVerifiedDate -MetadataFile $metadataPath } else { $null })
            MetadataReadable = [bool]$metadataReadable
            StructurallySafe = [bool]$structurallySafe
            IsCurrentProfile = [bool]$isCurrentProfile
            IsUsable = [bool]($structurallySafe -and $metadataReadable -and $isComplete -and $availableFolders.Count -gt 0)
            CanCopyToFolder = [bool]($structurallySafe -and $availableFolders.Count -gt 0)
            AvailableFolders = @($availableFolders)
        }
    }
    return @($items)
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
