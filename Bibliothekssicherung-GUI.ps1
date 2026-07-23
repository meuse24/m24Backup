<#
Grafische Oberfläche für Bibliothekssicherung.ps1.
Die Sicherung läuft in einem separaten PowerShell-Prozess. Ein Timer liest
den aktuellen Status aus einer temporären Datei, damit das Fenster bedienbar
bleibt und nicht auf frei formulierte Konsolenausgaben angewiesen ist.
#>
param([switch]$SilentStartup)

$ErrorActionPreference = 'Stop'

$sharedScript = Join-Path $PSScriptRoot 'M24Backup.Shared.ps1'
if (Test-Path -LiteralPath $sharedScript -PathType Leaf) {
    . $sharedScript
} else {
    throw "Shared helper script not found: $sharedScript"
}

$script:isGerman = Test-M24GermanUiCulture
function L {
    param([string]$German, [string]$English)
    if ($script:isGerman) { return $German }
    return $English
}

<#
DPI-Strategie (dokumentiert, siehe plan.md Arbeitspaket 1):
Die GUI laeuft unter Windows PowerShell 5.1 (.NET Framework). Der dafuer von
Microsoft dokumentierte PerMonitorV2-Weg erfordert eine App-Konfiguration
(app.config) des Hostprozesses; powershell.exe.config kann eine portable App
nicht setzen. Ohne diese Konfiguration wuerde reines API-PerMonitorV2 zwar den
Prozess umstellen, WinForms wuerde Fenster bei DPI-Wechseln aber nicht neu
skalieren - das Layout waere auf dem Zweitmonitor defekt. Deshalb wird der
Prozess frueh und vor dem ersten Fensterhandle explizit System-DPI-aware
gesetzt: Beim Start skaliert WinForms das Layout ueber AutoScaleMode.Dpi
scharf auf die System-DPI; beim Verschieben auf einen Monitor mit anderer
Skalierung streckt Windows die fertige Darstellung (unscharf, aber korrekt
und vollstaendig). Der Aufruf ist idempotent: Ist die Awareness bereits durch
das Manifest des Hosts gesetzt, schlagen die APIs folgenlos fehl.
#>
function Initialize-M24DpiAwareness {
    try {
        Add-Type -Namespace M24Backup -Name DpiNative -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shcore.dll")]
public static extern int SetProcessDpiAwareness(int value);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
'@ -ErrorAction Stop
    } catch { return }
    try {
        # 1 = PROCESS_SYSTEM_DPI_AWARE. shcore.dll existiert ab Windows 8.1;
        # aeltere Systeme nutzen den user32-Fallback.
        if ([M24Backup.DpiNative]::SetProcessDpiAwareness(1) -ne 0) {
            [void][M24Backup.DpiNative]::SetProcessDPIAware()
        }
    } catch {
        try { [void][M24Backup.DpiNative]::SetProcessDPIAware() } catch {
            # Ohne API bleibt die Manifest-Voreinstellung des Hosts wirksam.
        }
    }
}
Initialize-M24DpiAwareness

function Open-HelpTopic {
    param([string]$Anchor)

    $htmlHelpPath = @($helpFile, $helpBuildFile) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
        Select-Object -First 1

    if ($htmlHelpPath) {
        $helpPath = (Resolve-Path -LiteralPath $htmlHelpPath).Path
        $uriBuilder = New-Object System.UriBuilder -ArgumentList (New-Object System.Uri($helpPath))
        if ($Anchor) { $uriBuilder.Fragment = $Anchor }
        Start-Process -FilePath $uriBuilder.Uri.AbsoluteUri
        return
    }

    if (Test-Path -LiteralPath $helpFallbackFile -PathType Leaf) {
        Start-Process -FilePath $helpFallbackFile
        return
    }

    [System.Windows.Forms.MessageBox]::Show(
        ((L "Die Hilfedatei wurde nicht gefunden:`r`n{0}" "The help file was not found:`r`n{0}") -f $helpFile),
        (L "Hilfe" "Help"),
        "OK",
        "Error"
    ) | Out-Null
}

$coreScript = Join-Path $PSScriptRoot "Bibliothekssicherung.ps1"
$helpFile = Join-Path $PSScriptRoot $(if ($script:isGerman) { 'Hilfe\index.de.html' } else { 'Hilfe\index.en.html' })
$helpBuildFile = Join-Path $PSScriptRoot $(if ($script:isGerman) { 'build\staging\Hilfe\index.de.html' } else { 'build\staging\Hilfe\index.en.html' })
$helpFallbackFile = Join-Path $PSScriptRoot $(if ($script:isGerman) { 'docs\help.de.md' } else { 'docs\help.en.md' })
$versionFile = Join-Path $PSScriptRoot 'version.txt'
$appVersion = if (Test-Path -LiteralPath $versionFile -PathType Leaf) { (Get-Content -LiteralPath $versionFile -Raw).Trim() } else { '' }
$logoFile = Join-Path $PSScriptRoot 'logo.jpg'
$script:splashForm = $null
$script:splashLogoImage = $null
$script:splashStatusLabel = $null
$script:splashProgress = $null
$script:mainWindowShown = $false
$script:fatalGuiError = $false
# Der Splash erscheint erst, wenn der Start messbar laenger dauert. Schnelle
# Starts bleiben dadurch ohne kurz aufblitzendes Zwischenfenster (plan.md,
# Arbeitspaket 7).
$script:startupStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:splashDelayMilliseconds = 400
$script:driveDiscoveryActive = $false
$script:dpiLayoutReady = $false
$script:contentLayoutUpdating = $false

function New-StartupSplashForm {
    # Ein optionaler Splashscreen darf den eigentlichen Programmstart nie
    # verhindern, etwa wenn das Logo auf einem langsamen Medium nicht lesbar ist.
    try {
        $splash = New-Object System.Windows.Forms.Form
        $splash.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $splash.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
        $splash.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
        $splash.ClientSize = New-Object System.Drawing.Size(430, 144)
        $splash.BackColor = [System.Drawing.Color]::White
        $splash.ShowInTaskbar = $false
        # Kein TopMost: Der Splash soll andere Anwendungen nicht verdecken.
        $splash.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual

        $splashLogoBox = New-Object System.Windows.Forms.PictureBox
        # Das Logo ist im Hauptfenster bewusst nicht mehr Teil des Workflows.
        # Im selten sichtbaren Splash darf die Marke deshalb prominent sein.
        $splashLogoBox.Location = New-Object System.Drawing.Point(16, 16)
        $splashLogoBox.Size = New-Object System.Drawing.Size(112, 112)
        $splashLogoBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $splashLogoBox.BackColor = [System.Drawing.Color]::White
        if (Test-Path -LiteralPath $logoFile -PathType Leaf) {
            $splashLogoStream = [System.IO.File]::Open($logoFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $splashLogoSource = [System.Drawing.Image]::FromStream($splashLogoStream)
                try { $script:splashLogoImage = New-Object System.Drawing.Bitmap($splashLogoSource) } finally { $splashLogoSource.Dispose() }
            } finally { $splashLogoStream.Dispose() }
            $splashLogoBox.Image = $script:splashLogoImage
        }
        $splash.Controls.Add($splashLogoBox)

        $script:splashStatusLabel = New-Object System.Windows.Forms.Label
        $script:splashStatusLabel.Text = L 'Bibliothekssicherung wird gestartet ...' 'Library Backup is starting ...'
        $script:splashStatusLabel.AccessibleName = L 'Startstatus' 'Startup status'
        $script:splashStatusLabel.Location = New-Object System.Drawing.Point(148, 42)
        $script:splashStatusLabel.Size = New-Object System.Drawing.Size(266, 28)
        $script:splashStatusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $script:splashStatusLabel.AutoEllipsis = $true
        $script:splashStatusLabel.Font = New-Object System.Drawing.Font($semiboldFontName, 10)
        $script:splashStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(31, 55, 74)
        $splash.Controls.Add($script:splashStatusLabel)

        $script:splashProgress = New-Object System.Windows.Forms.ProgressBar
        $script:splashProgress.Location = New-Object System.Drawing.Point(148, 84)
        $script:splashProgress.Size = New-Object System.Drawing.Size(266, 8)
        $script:splashProgress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $script:splashProgress.MarqueeAnimationSpeed = 24
        $script:splashProgress.AccessibleName = L 'Startfortschritt' 'Startup progress'
        $splash.Controls.Add($script:splashProgress)

        # Explizite DPI-Skalierung wie beim Hauptfenster; erst danach laesst
        # sich die endgueltige Fenstergroesse fuer die Zentrierung auf dem
        # Monitor mit dem Mauszeiger verwenden.
        $splash.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
        $splash.PerformAutoScale()
        $cursorArea = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
        $splash.Location = New-Object System.Drawing.Point(
            ($cursorArea.Left + [int](($cursorArea.Width - $splash.Width) / 2)),
            ($cursorArea.Top + [int](($cursorArea.Height - $splash.Height) / 2)))

        $script:splashForm = $splash
        $script:splashForm.Show()
        $script:splashForm.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
        Close-StartupSplash
    }
}

function Set-StartupSplashStatus {
    param([string]$Text)
    if (-not $script:splashForm) {
        # Verzögerte Anzeige: Erst wenn der Start laenger als die Schwelle
        # dauert, lohnt sich ein eigenes Feedback-Fenster.
        if ($script:startupStopwatch.ElapsedMilliseconds -lt $script:splashDelayMilliseconds) { return }
        if ($script:mainWindowShown) { return }
        New-StartupSplashForm
    }
    if (-not $script:splashForm -or $script:splashForm.IsDisposed) { return }
    $script:splashStatusLabel.Text = $Text
    $script:splashForm.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

function Close-StartupSplash {
    if ($script:splashForm) {
        try { $script:splashForm.Close() } catch {}
        try { $script:splashForm.Dispose() } catch {}
        $script:splashForm = $null
    }
    if ($script:splashLogoImage) {
        try { $script:splashLogoImage.Dispose() } catch {}
        $script:splashLogoImage = $null
    }
    $script:splashStatusLabel = $null
    $script:splashProgress = $null
}

# Der Login-Pfad zweigt vor WinForms, Splashscreen und Laufwerkserkennung ab.
# Ist keine Erinnerung faellig, beschraenkt er sich auf Shared-Funktionen und
# das direkte Lesen der kleinen lokalen Settings-Datei.
if ($SilentStartup) {
    $script:silentReminderLaunchRequested = $false
    $silentMutexHandle = $null
    $silentNotifyIcon = $null
    $silentIcon = $null
    $silentTimer = $null
    $silentContext = $null
    try {
        $silentSettingsDirectory = [Environment]::GetFolderPath('LocalApplicationData')
        if ([string]::IsNullOrWhiteSpace($silentSettingsDirectory)) { exit 0 }
        $silentSettingsFile = Join-Path (Join-Path $silentSettingsDirectory 'M24Backup') 'settings.json'
        if (-not (Test-Path -LiteralPath $silentSettingsFile -PathType Leaf)) { exit 0 }
        $silentSettings = Get-Content -LiteralPath $silentSettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $silentSettings.PSObject.Properties['ReminderEnabled'] -or -not [bool]$silentSettings.ReminderEnabled) { exit 0 }
        $reminderDays = 14
        $parsedReminderDays = 0
        if ($silentSettings.PSObject.Properties['ReminderDays'] -and
            [int]::TryParse([string]$silentSettings.ReminderDays, [ref]$parsedReminderDays) -and
            $parsedReminderDays -ge 1 -and $parsedReminderDays -le 3650) {
            # Migrate the original, non-configurable seven-day default.
            $reminderDays = if ($parsedReminderDays -eq 7) { 14 } else { $parsedReminderDays }
        }
        $lastSuccessfulBackup = if ($silentSettings.PSObject.Properties['LastSuccessfulBackup']) { [string]$silentSettings.LastSuccessfulBackup } else { '' }
        $reminderState = Get-M24BackupReminderState -LastSuccessfulBackup $lastSuccessfulBackup -ThresholdDays $reminderDays
        if (-not $reminderState.IsDue) { exit 0 }

        $silentMutexHandle = Enter-M24SingleInstance -Name (Get-M24GuiMutexName)
        if (-not $silentMutexHandle.Acquired) { exit 0 }

        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $silentNotifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $silentIconPath = Join-Path $PSScriptRoot 'app.ico'
        if (Test-Path -LiteralPath $silentIconPath -PathType Leaf) {
            $silentIcon = New-Object System.Drawing.Icon($silentIconPath)
            $silentNotifyIcon.Icon = $silentIcon
        } else {
            $silentNotifyIcon.Icon = [System.Drawing.SystemIcons]::Information
        }
        $silentNotifyIcon.Text = L 'Bibliothekssicherung' 'Library Backup'
        $silentNotifyIcon.Visible = $true
        $silentContext = New-Object System.Windows.Forms.ApplicationContext
        $silentTimer = New-Object System.Windows.Forms.Timer
        $silentTimer.Interval = 30000
        $silentTimer.Add_Tick({
            $silentTimer.Stop()
            $silentContext.ExitThread()
        })
        $silentNotifyIcon.Add_BalloonTipClicked({
            $script:silentReminderLaunchRequested = $true
            $silentContext.ExitThread()
        })
        $silentNotifyIcon.Add_BalloonTipClosed({ $silentContext.ExitThread() })
        $reminderText = if ($reminderState.NeverBackedUp) {
            L 'Es wurde noch keine Sicherung erstellt. Bitte schließen Sie Ihr Sicherungslaufwerk an.' 'No backup has been created yet. Connect your backup drive.'
        } else {
            (L 'Ihr letztes Backup ist {0} Tage alt. Bitte schließen Sie Ihr Sicherungslaufwerk an.' 'Your last backup is {0} days old. Connect your backup drive.') -f $reminderState.DaysSinceBackup
        }
        $silentNotifyIcon.ShowBalloonTip(10000, (L 'Backup-Erinnerung' 'Backup reminder'), $reminderText, [System.Windows.Forms.ToolTipIcon]::Warning)
        $silentTimer.Start()
        [System.Windows.Forms.Application]::Run($silentContext)
    } catch {
        # Autostart-Erinnerungen sind best effort und zeigen niemals Fehlerdialoge.
    } finally {
        if ($silentTimer) { try { $silentTimer.Stop(); $silentTimer.Dispose() } catch { # Best-effort cleanup.
            } }
        if ($silentNotifyIcon) { try { $silentNotifyIcon.Visible = $false; $silentNotifyIcon.Dispose() } catch { # Best-effort cleanup.
            } }
        if ($silentIcon) { try { $silentIcon.Dispose() } catch { # Best-effort cleanup.
            } }
        if ($silentContext) { try { $silentContext.Dispose() } catch { # Best-effort cleanup.
            } }
        Exit-M24SingleInstance -Handle $silentMutexHandle
    }
    if ($script:silentReminderLaunchRequested) {
        try {
            $silentLauncher = Join-Path $PSScriptRoot 'Bibliothekssicherung starten.vbs'
            $silentWscript = Join-Path ([Environment]::SystemDirectory) 'wscript.exe'
            Start-Process -FilePath $silentWscript -ArgumentList (ConvertTo-M24ProcessArgument $silentLauncher) -WindowStyle Hidden
        } catch {
            # A notification click must not surface launcher errors.
        }
    }
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$installedFontNames = @([System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name })
$textFontName = if ($installedFontNames -contains 'Segoe UI Variable Text') { 'Segoe UI Variable Text' } else { 'Segoe UI' }
$semiboldFontName = if ($installedFontNames -contains 'Segoe UI Variable Text Semibold') { 'Segoe UI Variable Text Semibold' } else { 'Segoe UI Semibold' }
$displayFontName = if ($installedFontNames -contains 'Segoe UI Variable Display Semib') { 'Segoe UI Variable Display Semib' } else { 'Segoe UI Semibold' }

$script:guiInstanceHandle = $null
try {
    $script:guiInstanceHandle = Enter-M24SingleInstance -Name (Get-M24GuiMutexName)
    if (-not $script:guiInstanceHandle.Acquired) {
        [System.Windows.Forms.MessageBox]::Show(
            (L 'Bibliothekssicherung ist bereits geöffnet.' 'Library Backup is already open.'),
            (L 'Bereits geöffnet' 'Already open'), 'OK', 'Information') | Out-Null
        Exit-M24SingleInstance -Handle $script:guiInstanceHandle
        $script:guiInstanceHandle = $null
        exit 0
    }
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        ((L "Die Einzelinstanz-Sperre konnte nicht eingerichtet werden:`r`n{0}" "The single-instance guard could not be initialized:`r`n{0}") -f $_.Exception.Message),
        (L 'Start fehlgeschlagen' 'Startup failed'), 'OK', 'Error') | Out-Null
    exit 1
}

# Das Hauptfenster erscheint erst nach Laufwerks- und Metadatenabfragen.
# Dauert diese Startphase spuerbar (siehe $script:splashDelayMilliseconds),
# blendet Set-StartupSplashStatus einen kleinen Status-Splash ein; schnelle
# Starts kommen ganz ohne Zwischenfenster aus.

try {
$appIcon = $null
$script:backupProcess = $null
$script:statusFile = $null
$script:resultFile = $null
$script:cancelFile = $null
$script:previewFile = $null
$script:approvalFile = $null
$script:selectedFoldersFile = $null
$script:restorePreviewShown = $false
$script:scanWarningShown = $false
$script:lastLogDir = $null
$script:lastLogFile = $null
$script:lastDestination = $null
$script:backupStartedAt = $null
$script:backupCancelled = $false
$script:driveMap = @{}
$script:driveSnapshot = ''
$script:driveLogicalSnapshot = ''
$script:driveDeviceIds = @()
# Nach einem Fehlschlag der Laufwerkserkennung pausiert das automatische
# Polling bis zu diesem UTC-Zeitpunkt, damit eine haengende CIM-Abfrage die
# GUI nicht alle 2,5 Sekunden erneut blockiert. Manuelles Aktualisieren
# (-Force) umgeht die Pause.
$script:driveRetryAfterUtc = [DateTime]::MinValue
$script:activeDrive = $null
$script:activeMode = $null
$script:activeDryRun = $false
$script:activeSuperFast = $false
# Verhindert Ereignis-Rekursion, wenn Update-BackupOptionState selbst
# Checkbox-Zustaende setzt und dadurch CheckedChanged ausloest.
$script:optionStateUpdating = $false
# Merkt sich den Pruefsummen-Haken vor dem Aktivieren des Superschnell-Modus,
# damit das blosse Ausprobieren der Option keine dauerhafte Aenderung bewirkt.
$script:checksumBeforeSuperFast = $null
$script:autoEjectRequested = $false
$script:pendingEjectDrive = $null
$script:ejectAttemptsRemaining = 0
$script:ejectDialogOpen = $false
$script:verificationPowerShell = $null
$script:verificationAsyncResult = $null
$script:verificationCancelFile = $null
$script:deletionPowerShell = $null
$script:deletionAsyncResult = $null
$script:deletionInfo = $null
$script:deletionDisk = $null
$script:lastProgressCurrent = 0
$script:lastProgressTotal = 1
$script:preCancelStatusText = $null
$script:preCancelResultText = $null
$script:customFolders = @()
$script:folderCheckStates = @{}
$script:backupSelectionSnapshot = $null
$script:artifactCache = @{}
$script:suppressArtifactRetarget = $false
$script:backupInventory = @()
$script:backupInventoryMap = @{}
$script:selectedBackup = $null
$script:restoreTargetFolder = $null
# Ordnergroessen (Dateianzahl und Bytes) werden je Pfad einmal pro Sitzung in
# einem Hintergrund-Runspace ermittelt. Cache und Warteschlange sind
# synchronisiert, weil GUI-Thread und Scanner gleichzeitig darauf zugreifen.
$script:folderSizeCache = [hashtable]::Synchronized(@{})
$script:folderSizeQueue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$script:folderSizeRetriedKeys = [hashtable]::Synchronized(@{})
$script:folderSizePowerShell = $null
$script:folderSizeAsyncResult = $null
$settingsDirectory = Join-Path $env:LOCALAPPDATA 'M24Backup'
$settingsFile = Join-Path $settingsDirectory 'settings.json'
$script:knownDrive = $null
$script:settingsWritable = $true
$script:settings = $null
$script:reminderSettingInitializing = $false
$script:settingsNeedSave = $false
$startupReminderVbsPath = Join-Path $PSScriptRoot 'Bibliothekssicherung starten.vbs'
$startupReminderCommand = Get-M24StartupReminderCommand -VbsPath $startupReminderVbsPath

function Get-LibraryNames {
    param([switch]$IncludeMissing)
    return @(Get-LibraryDefinitions -IncludeMissing:$IncludeMissing | ForEach-Object { $_.Name })
}

function Get-LibraryDefinitions {
    param([switch]$IncludeMissing)
    return @(Get-M24StandardFolderDefinitions | Where-Object { $IncludeMissing -or (Test-Path -LiteralPath $_.Path) })
}

function Get-FolderSizeKey {
    param([string]$Path)
    try { return [System.IO.Path]::GetFullPath($Path).TrimEnd('\').ToLowerInvariant() } catch { return $Path.ToLowerInvariant() }
}

function Format-FolderSizeText {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N1} KB' -f ($Bytes / 1KB) }
    return (L '{0} Bytes' '{0} bytes') -f $Bytes
}

function Format-FolderFileCountText {
    param([int64]$Files)
    if ($Files -eq 1) { return L '1 Datei' '1 file' }
    return (L '{0:N0} Dateien' '{0:N0} files') -f $Files
}

function Get-FolderSizeCaption {
    param([string]$SizePath)
    if ([string]::IsNullOrWhiteSpace($SizePath)) { return '' }
    $entry = $script:folderSizeCache[(Get-FolderSizeKey $SizePath)]
    if ($null -eq $entry) { return '' }
    if ($entry -is [string]) { return L 'wird ermittelt …' 'calculating …' }
    if ($entry.PSObject.Properties['State'] -and [string]$entry.State -eq 'Failed') { return L 'nicht ermittelbar' 'unavailable' }
    if ([int64]$entry.Files -eq 0) { return L 'leer' 'empty' }
    return '{0}, {1}' -f (Format-FolderFileCountText -Files ([int64]$entry.Files)), (Format-FolderSizeText -Bytes ([int64]$entry.Bytes))
}

# Summiert die bereits ermittelten Groessen aller angehakten Ordner.
# Pending meldet, ob noch Messungen ausstehen; Known, ob mindestens ein
# Ergebnis vorliegt (ohne beides bleibt die Ergebnisuebersicht unveraendert).
function Get-CheckedFolderSizeTotal {
    $files = [int64]0
    $bytes = [int64]0
    $pending = $false
    $failed = $false
    $known = $false
    foreach ($item in $libraryList.CheckedItems) {
        if (-not $item -or -not $item.PSObject.Properties['SizePath']) { continue }
        $sizePath = [string]$item.SizePath
        if ([string]::IsNullOrWhiteSpace($sizePath)) { continue }
        $entry = $script:folderSizeCache[(Get-FolderSizeKey $sizePath)]
        if ($null -eq $entry) { continue }
        if ($entry -is [string]) { $pending = $true; continue }
        if ($entry.PSObject.Properties['State'] -and [string]$entry.State -eq 'Failed') { $failed = $true; continue }
        $files += [int64]$entry.Files
        $bytes += [int64]$entry.Bytes
        $known = $true
    }
    return [pscustomobject]@{ Files = $files; Bytes = $bytes; Pending = $pending; Failed = $failed; Known = $known }
}

function New-FolderListItem {
    param(
        [string]$Name,
        [string]$DisplayName,
        [string]$Path,
        [bool]$IsCustom,
        [bool]$Checked = $true,
        [string]$SizePath
    )

    $item = [pscustomobject]@{
        Name = $Name
        DisplayName = $DisplayName
        Path = $Path
        IsCustom = $IsCustom
        Checked = $Checked
        # Im Sichern-Modus wird der Quellordner vermessen, im
        # Wiederherstellen-Modus der zugehoerige Ordner im Backup.
        SizePath = if ([string]::IsNullOrWhiteSpace($SizePath)) { $Path } else { $SizePath }
    }
    $item | Add-Member -MemberType ScriptMethod -Name ToString -Value {
        $caption = Get-FolderSizeCaption -SizePath $this.SizePath
        if ($caption) { return "{0}  —  {1}" -f $this.DisplayName, $caption }
        return $this.DisplayName
    } -Force
    return $item
}

function Get-FolderItemDisplayName {
    param($Item)
    if ($Item -and $Item.PSObject.Properties['DisplayName']) { return [string]$Item.DisplayName }
    if ($Item -and $Item.PSObject.Properties['Name']) { return Get-M24FolderDisplayName ([string]$Item.Name) $script:isGerman }
    return [string]$Item
}

# Stellt noch nicht vermessene Ordner in die Warteschlange und startet bei
# Bedarf den Hintergrund-Scanner. Bereits ermittelte Groessen bleiben fuer die
# Sitzung im Cache; erneute Aufrufe (Moduswechsel, Laufwerkswechsel) messen
# also nur neue Pfade.
function Request-FolderSizeScan {
    param($Items)
    $queued = $false
    foreach ($item in @($Items)) {
        if (-not $item -or -not $item.PSObject.Properties['SizePath']) { continue }
        $sizePath = [string]$item.SizePath
        if ([string]::IsNullOrWhiteSpace($sizePath)) { continue }
        $key = Get-FolderSizeKey $sizePath
        if ($script:folderSizeCache.ContainsKey($key)) { continue }
        if (-not (Test-Path -LiteralPath $sizePath -PathType Container)) { continue }
        $script:folderSizeCache[$key] = 'pending'
        $script:folderSizeQueue.Enqueue([pscustomobject]@{ Key = $key; Path = $sizePath })
        $queued = $true
    }
    if ($queued) { Start-FolderSizeScanner }
}

function Start-FolderSizeScanner {
    if ($script:folderSizeAsyncResult -and -not $script:folderSizeAsyncResult.IsCompleted) {
        # Der laufende Scanner arbeitet die Warteschlange von selbst ab; der
        # Timer stellt sicher, dass ein Rest nach dessen Ende erneut startet.
        $folderSizeTimer.Start()
        return
    }
    if ($script:folderSizePowerShell) {
        try { $script:folderSizePowerShell.Dispose() } catch {}
        $script:folderSizePowerShell = $null
        $script:folderSizeAsyncResult = $null
    }
    if ($script:folderSizeQueue.Count -eq 0) { return }
    $scanScript = {
        param($queue, $cache)
        while ($true) {
            $entry = $null
            # Dequeue wirft bei leerer Warteschlange; das beendet den Scanner.
            try { $entry = $queue.Dequeue() } catch { break }
            $result = $null
            try {
                $files = [int64]0
                $bytes = [int64]0
                $stack = New-Object System.Collections.Generic.Stack[object]
                # Der Stammordner wird immer vermessen, auch wenn er selbst eine
                # Junction oder ein Symlink ist: Robocopy kopiert den Inhalt des
                # gewaehlten Quellordners unabhaengig von dessen Link-Typ.
                $stack.Push([pscustomobject]@{ Path = [string]$entry.Path; Depth = 0 })
                while ($stack.Count -gt 0) {
                    $current = $stack.Pop()
                    # Tiefenbegrenzung als Schutz vor Symlink-Zyklen: Der Anzeige-
                    # Scan darf niemals endlos laufen; echte Ordnerbaeume bleiben
                    # weit unterhalb dieser Grenze.
                    if ([int]$current.Depth -ge 64) { continue }
                    # Get-ChildItem wie in der Vorpruefung des Workers: LinkType
                    # unterscheidet Junction und Symlink, Lesefehler einzelner
                    # Ordner brechen die Aufzaehlung nicht ab.
                    foreach ($child in @(Get-ChildItem -LiteralPath ([string]$current.Path) -Force -ErrorAction SilentlyContinue)) {
                        if ($child.PSIsContainer) {
                            # Wie Robocopy /XJ und die Vorpruefung: Junctions nicht
                            # verfolgen (Schleifengefahr), Verzeichnis-Symlinks
                            # dagegen schon - sie werden auch gesichert.
                            if ([string]$child.LinkType -ne 'Junction') {
                                $stack.Push([pscustomobject]@{ Path = $child.FullName; Depth = ([int]$current.Depth + 1) })
                            }
                        } else {
                            $files++
                            $bytes += [int64]$child.Length
                        }
                    }
                }
                $result = [pscustomobject]@{ State = 'Complete'; Files = $files; Bytes = $bytes; Error = '' }
            } catch {
                $result = [pscustomobject]@{ State = 'Failed'; Files = [int64]0; Bytes = [int64]0; Error = $_.Exception.Message }
            } finally {
                # Jeder dequeuete Marker erhaelt garantiert einen Endzustand.
                # Dadurch kann ein einzelner problematischer Ordner den Cache
                # nicht dauerhaft als 'pending' vergiften.
                if ($null -eq $result) {
                    $result = [pscustomobject]@{ State = 'Failed'; Files = [int64]0; Bytes = [int64]0; Error = 'Folder size scan ended without a result.' }
                }
                $cache[[string]$entry.Key] = $result
            }
        }
    }
    $script:folderSizePowerShell = [System.Management.Automation.PowerShell]::Create()
    [void]$script:folderSizePowerShell.AddScript($scanScript.ToString()).AddArgument($script:folderSizeQueue).AddArgument($script:folderSizeCache)
    $script:folderSizeAsyncResult = $script:folderSizePowerShell.BeginInvoke()
    $folderSizeTimer.Start()
}

function Get-FolderMetadataFile {
    param([string]$BackupRoot)
    return Join-Path $BackupRoot '_Ordner.json'
}

function Get-RestoreCustomFolders {
    param([string]$BackupRoot)
    $metadataFile = Get-FolderMetadataFile -BackupRoot $BackupRoot
    if (-not (Test-Path -LiteralPath $metadataFile -PathType Leaf)) { return @() }
    try {
        $metadata = @(Get-Content -LiteralPath $metadataFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
        return @($metadata | Where-Object {
            $_.Name -and $_.OriginalPath -and (Test-Path -LiteralPath (Join-Path $BackupRoot $_.Name) -PathType Container)
        } | ForEach-Object {
            New-FolderListItem -Name ([string]$_.Name) -DisplayName ("{0} ({1})" -f $_.Name, $_.OriginalPath) -Path ([string]$_.OriginalPath) -IsCustom $true -Checked $true -SizePath (Join-Path $BackupRoot ([string]$_.Name))
        })
    } catch {
        return @()
    }
}

function Get-ExistingCustomFolderMetadataForSelectedDrive {
    if (-not $driveCombo.SelectedItem) { return @() }
    try {
        $disk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
        $backupRoot = Get-BackupRoot -Drive $disk.DeviceID
        $metadataFile = Get-FolderMetadataFile -BackupRoot $backupRoot
        if (-not (Test-Path -LiteralPath $metadataFile -PathType Leaf)) { return @() }
        return @(Get-Content -LiteralPath $metadataFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop | Where-Object { $_.Name -and $_.OriginalPath })
    } catch {
        return @()
    }
}

function Get-SafeCustomFolderName {
    param([string]$Path)

    # Split-Path -LiteralPath kann unter Windows PowerShell 5.1 nicht mit
    # -Leaf kombiniert werden (mehrdeutiger Parametersatz); .NET-API nutzen.
    $baseName = [System.IO.Path]::GetFileName($Path.TrimEnd('\'))
    if ([string]::IsNullOrWhiteSpace($baseName)) { $baseName = ($Path -replace '[:\\\/]+', '').Trim() }
    foreach ($invalidChar in [System.IO.Path]::GetInvalidFileNameChars()) {
        $baseName = $baseName.Replace([string]$invalidChar, '_')
    }
    $baseName = $baseName.Trim()
    if ([string]::IsNullOrWhiteSpace($baseName) -or $baseName.StartsWith('_')) {
        $baseName = "Zusatzordner"
    }

    $reserved = Get-ReservedBackupNames
    $existingNames = @()
    $existingNames += @(Get-LibraryDefinitions -IncludeMissing | ForEach-Object { $_.Name })
    $existingNames += @($script:customFolders | ForEach-Object { $_.Name })
    $existingNames += @(Get-ExistingCustomFolderMetadataForSelectedDrive | ForEach-Object { $_.Name })
    $candidate = $baseName
    $index = 2
    while (
        ($candidate.StartsWith('_')) -or
        ($reserved -contains $candidate) -or
        (@($existingNames | Where-Object { $_.Equals($candidate, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
    ) {
        $candidate = "{0} ({1})" -f $baseName, $index
        $index++
    }
    return $candidate
}

function Sync-FolderCheckState {
    for ($i = 0; $i -lt $libraryList.Items.Count; $i++) {
        $item = $libraryList.Items[$i]
        if ($item.PSObject.Properties['Name']) {
            $script:folderCheckStates[[string]$item.Name] = $libraryList.GetItemChecked($i)
        }
    }
    foreach ($customFolder in $script:customFolders) {
        if ($script:folderCheckStates.ContainsKey([string]$customFolder.Name)) {
            $customFolder.Checked = [bool]$script:folderCheckStates[[string]$customFolder.Name]
        }
    }
}

function Get-CheckedFolderItems {
    $items = @()
    for ($i = 0; $i -lt $libraryList.Items.Count; $i++) {
        if ($libraryList.GetItemChecked($i)) {
            $items += $libraryList.Items[$i]
        }
    }
    return $items
}

function Start-BusyProgress {
    if ($progressBar.Style -ne [System.Windows.Forms.ProgressBarStyle]::Marquee) {
        $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    }
    if ($progressBar.MarqueeAnimationSpeed -ne 35) {
        $progressBar.MarqueeAnimationSpeed = 35
    }
}

function Stop-BusyProgress {
    $progressBar.MarqueeAnimationSpeed = 0
    if ($progressBar.Style -ne [System.Windows.Forms.ProgressBarStyle]::Blocks) {
        $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
    }
}

function Reset-ProgressIndicator {
    param([int]$Maximum)

    Stop-BusyProgress
    $progressBar.Minimum = 0
    $progressBar.Maximum = [math]::Max(1, $Maximum)
    $progressBar.Value = 0
    $script:lastProgressCurrent = 0
    $script:lastProgressTotal = $progressBar.Maximum
}

function Set-ProgressFromLastStatus {
    Stop-BusyProgress
    $progressBar.Maximum = [math]::Max(1, $script:lastProgressTotal)
    $progressBar.Value = [math]::Min([math]::Max(0, $script:lastProgressCurrent - 1), $progressBar.Maximum)
}

function Format-ElapsedDuration {
    param([TimeSpan]$Elapsed)

    if ($Elapsed.TotalHours -ge 1) { return ("{0:hh\:mm\:ss}" -f $Elapsed) }
    return ("{0:mm\:ss}" -f $Elapsed)
}

function Update-ElapsedDuration {
    if ($script:backupStartedAt) {
        $durationLabel.Text = Format-ElapsedDuration ((Get-Date) - $script:backupStartedAt)
    } else {
        $durationLabel.Text = "--:--"
    }
}

function Set-CancellationPendingOverview {
    $resultBox.Text = if ($restoreRadio.Checked) {
        L "Wiederherstellung wird abgebrochen. Robocopy wird gestoppt; die zuletzt aktive Datei kann unvollständig sein." "Restore is being cancelled. Robocopy is being stopped; the last active file may be incomplete."
    } elseif ($script:activeDryRun) {
        L "Simulation wird abgebrochen. Der laufende Robocopy-Vorgang wird gestoppt." "Simulation is being cancelled. The current Robocopy operation is being stopped."
    } else {
        L "Sicherung wird abgebrochen. Robocopy wird gestoppt; die zuletzt aktive Datei kann unvollständig im Ziel liegen." "Backup is being cancelled. Robocopy is being stopped; the last active file may be incomplete at the destination."
    }
}

function Format-RobocopyWarningSummary {
    param($Warnings)

    $items = @($Warnings | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    if ($items.Count -eq 0) { return "" }

    $shown = @($items | Select-Object -First 3)
    $prefix = if ($items.Count -eq 1) { L " Robocopy-Hinweis:" " Robocopy note:" } else { L " Robocopy-Hinweise:" " Robocopy notes:" }
    $suffix = if ($items.Count -gt $shown.Count) {
        " " + ((L "Weitere {0} Hinweis(e) im Protokoll." "See log for {0} more note(s).") -f ($items.Count - $shown.Count))
    } else { "" }
    return "{0} {1}.{2}" -f $prefix, ($shown -join ' | '), $suffix
}

function Get-NewestLogFile {
    if ($script:lastLogFile -and (Test-Path -LiteralPath $script:lastLogFile -PathType Leaf)) {
        return Get-Item -LiteralPath $script:lastLogFile -ErrorAction SilentlyContinue
    }
    if (-not $script:lastLogDir -or -not (Test-Path -LiteralPath $script:lastLogDir)) {
        return $null
    }

    $logs = Get-ChildItem -LiteralPath $script:lastLogDir -Filter "*.log" -File -ErrorAction SilentlyContinue
    if ($script:backupStartedAt) {
        $startedAt = $script:backupStartedAt.AddSeconds(-2)
        $logs = @($logs | Where-Object { $_.LastWriteTime -ge $startedAt })
    }
    return $logs |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-BackupRoot {
    param([string]$Drive)
    return Get-M24BackupRoot -Drive $Drive
}

function Get-BackupMetadataIdentity {
    param([string[]]$Lines)
    return Get-M24BackupMetadataIdentity -Lines $Lines
}

function Test-BackupMetadataMatchesCurrentProfile {
    param([string[]]$Lines)

    return Test-M24BackupMetadataIdentity -Lines $Lines
}

function Test-BackupMetadataHasSuccessfulResult {
    param([string[]]$Lines)
    return [bool](Get-M24BackupResultInfo -Lines $Lines).IsComplete
}

function Test-DriveHasCurrentProfileBackup {
    param($Disk)

    if (-not $Disk -or -not $Disk.DeviceID) { return $false }

    $metadataFile = Join-Path (Get-BackupRoot -Drive $Disk.DeviceID) '_Sicherungsinfo.txt'
    if (-not (Test-Path -LiteralPath $metadataFile -PathType Leaf)) { return $false }

    try {
        $lines = @(Get-Content -LiteralPath $metadataFile -ErrorAction Stop)
        return (Test-BackupMetadataMatchesCurrentProfile -Lines $lines) -and
            (Test-BackupMetadataHasSuccessfulResult -Lines $lines)
    } catch {
        return $false
    }
}

function Get-SelectedBackupInventoryItem {
    if (-not $backupSourceCombo.SelectedItem) { return $null }
    $key = [string]$backupSourceCombo.SelectedItem
    if (-not $script:backupInventoryMap.ContainsKey($key)) { return $null }
    return $script:backupInventoryMap[$key]
}

function Update-RestoreTargetState {
    $isRestore = $restoreRadio.Checked
    $selectedBackup = Get-SelectedBackupInventoryItem
    $backupSourceLabel.Visible = $isRestore
    $backupSourceCombo.Visible = $isRestore
    $backupSourceInfoLabel.Visible = $isRestore
    $restoreTargetPanel.Visible = $isRestore
    if (-not $isRestore) { return }

    $isIdle = -not $script:backupProcess -and -not $script:pendingEjectDrive -and
        -not $script:verificationAsyncResult -and -not $script:deletionAsyncResult
    $hasInventoryEntries = $backupSourceCombo.Items.Count -gt 0
    $hasCopyableSelection = [bool]($selectedBackup -and $selectedBackup.CanCopyToFolder)
    $backupSourceCombo.Enabled = $isIdle -and $hasInventoryEntries
    $profileAllowed = $isIdle -and $hasCopyableSelection -and [bool]$selectedBackup.IsUsable
    $folderAllowed = $isIdle -and $hasCopyableSelection
    $backupSourceInfoLabel.Text = if (-not $selectedBackup) {
        L 'Auf diesem Laufwerk wurde keine Sicherung gefunden.' 'No backup was found on this drive.'
    } else {
        $origin = if ($selectedBackup.MetadataReadable) { "{0}\{1}" -f $selectedBackup.Computer, $selectedBackup.User } else { L 'Herkunft unbekannt' 'Origin unknown' }
        $state = if ($selectedBackup.IsComplete) {
            L 'vollständig' 'complete'
        } elseif ($selectedBackup.MetadataReadable) {
            L 'unvollständig – nur Kopieren in einen anderen Ordner möglich' 'incomplete — only copying to another folder is available'
        } else {
            L 'Metadaten nicht lesbar – nur Kopieren in einen anderen Ordner möglich' 'metadata unreadable — only copying to another folder is available'
        }
        (L 'Herkunft: {0} · Zustand: {1}' 'Origin: {0} · Status: {1}') -f $origin, $state
    }
    $restoreProfileRadio.Enabled = $profileAllowed
    $restoreFolderRadio.Enabled = $folderAllowed
    if ($hasCopyableSelection -and -not $profileAllowed) { $restoreFolderRadio.Checked = $true }
    $needsFolder = $hasCopyableSelection -and $restoreFolderRadio.Checked
    $restoreFolderButton.Enabled = $folderAllowed
    $restoreFolderButton.Visible = $needsFolder
    $restoreFolderLabel.Visible = $needsFolder
    $restoreFolderLabel.Text = if ($script:restoreTargetFolder) {
        $script:restoreTargetFolder
    } else {
        L 'Noch kein Zielordner gewählt' 'No destination folder selected'
    }
}

function Update-RestoreSourceList {
    $previousRoot = if ($script:selectedBackup) { [string]$script:selectedBackup.RootPath } else { '' }
    $script:backupInventory = @()
    $script:backupInventoryMap = @{}
    $script:selectedBackup = $null
    $backupSourceCombo.Items.Clear()

    if (-not $restoreRadio.Checked -or -not $driveCombo.SelectedItem) {
        Update-RestoreTargetState
        return
    }

    $disk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
    $script:backupInventory = @(Get-M24BackupInventory -Drive $disk.DeviceID)
    $currentUsableIndex = -1
    $singleUsableIndex = -1
    $usableCount = 0
    $previousIndex = -1
    for ($inventoryIndex = 0; $inventoryIndex -lt $script:backupInventory.Count; $inventoryIndex++) {
        $item = $script:backupInventory[$inventoryIndex]
        $identityText = if ($item.MetadataReadable) { "{0}\{1}" -f $item.Computer, $item.User } else { L 'Identität unbekannt' 'Identity unknown' }
        $dateText = if ($item.LastCompletedAt) { ([datetime]$item.LastCompletedAt).ToString('dd.MM.yyyy HH:mm') } else { L 'kein Abschlussdatum' 'no completion date' }
        $stateText = if ($item.IsComplete) { L 'vollständig' 'complete' } elseif ($item.MetadataReadable) { L 'unvollständig' 'incomplete' } else { L 'Metadaten nicht lesbar' 'metadata unreadable' }
        $display = "{0} — {1} — {2} — {3}" -f $item.DisplayName, $identityText, $dateText, $stateText
        # DisplayName ist der direkte und damit innerhalb des Inventarstamms
        # eindeutige Ordnername. Die Anzeige benoetigt keinen technischen Index.
        $key = $display
        $script:backupInventoryMap[$key] = $item
        [void]$backupSourceCombo.Items.Add($key)
        if ($item.IsUsable) {
            $usableCount++
            $singleUsableIndex = $inventoryIndex
            if ($item.IsCurrentProfile) { $currentUsableIndex = $inventoryIndex }
        }
        if ($previousRoot -and [string]$item.RootPath -eq $previousRoot) { $previousIndex = $inventoryIndex }
    }

    $selectedIndex = if ($currentUsableIndex -ge 0) {
        $currentUsableIndex
    } elseif ($usableCount -eq 1) {
        $singleUsableIndex
    } elseif ($previousIndex -ge 0) {
        $previousIndex
    } elseif ($backupSourceCombo.Items.Count -gt 0) {
        0
    } else {
        -1
    }
    if ($selectedIndex -ge 0) { $backupSourceCombo.SelectedIndex = $selectedIndex }
    Update-RestoreTargetState
}

function Update-BackupArtifactActions {
    if (-not $driveCombo.SelectedItem) {
        $script:lastDestination = $null
        $script:lastLogDir = $null
        $script:lastLogFile = $null
        $script:backupStartedAt = $null
        $logButton.Enabled = $false
        $destinationButton.Enabled = $false
        $historyButton.Enabled = $false
        $verifyButton.Enabled = $false
        $deleteBackupButton.Enabled = $false
        return
    }

    $disk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
    $selectedBackup = if ($restoreRadio.Checked) { Get-SelectedBackupInventoryItem } else { $null }
    $script:lastDestination = if ($restoreRadio.Checked) {
        if ($selectedBackup) { [string]$selectedBackup.RootPath } else { $null }
    } else {
        Get-BackupRoot -Drive $disk.DeviceID
    }
    if (-not $script:lastDestination) {
        $script:lastLogDir = $null
        $script:lastLogFile = $null
        $logButton.Enabled = $false
        $destinationButton.Enabled = $false
        $historyButton.Enabled = $false
        $verifyButton.Enabled = $false
        $deleteBackupButton.Enabled = $false
        return
    }
    $script:lastLogDir = Join-Path $script:lastDestination '_logs'
    $script:lastLogFile = $null
    $script:backupStartedAt = $null
    $cacheKey = "{0}|{1}|{2}" -f $disk.DeviceID, (Get-NormalizedVolumeSerial -Disk $disk), $script:lastDestination
    if (-not $script:artifactCache.ContainsKey($cacheKey)) {
        $destinationExists = Test-Path -LiteralPath $script:lastDestination -PathType Container
        $newestLog = if ($destinationExists) { Get-NewestLogFile } else { $null }
        $script:artifactCache[$cacheKey] = [pscustomobject]@{ DestinationExists = $destinationExists; LogFile = if ($newestLog) { $newestLog.FullName } else { $null } }
    }
    $artifactState = $script:artifactCache[$cacheKey]
    $script:lastLogFile = [string]$artifactState.LogFile
    $destinationButton.Enabled = [bool]$artifactState.DestinationExists
    $logButton.Enabled = -not [string]::IsNullOrWhiteSpace([string]$artifactState.LogFile)
    $historyButton.Enabled = $logButton.Enabled
    $verifyButton.Enabled = $destinationButton.Enabled
    $deleteBackupButton.Enabled = $destinationButton.Enabled -and
        (-not $restoreRadio.Checked -or ($selectedBackup -and $selectedBackup.IsCurrentProfile))
}

function Get-NormalizedVolumeSerial {
    param($Disk)
    if (-not $Disk -or -not $Disk.VolumeSerialNumber) { return '' }
    return ([string]$Disk.VolumeSerialNumber).Trim().Replace('-', '').ToUpperInvariant()
}

function Get-AppSettings {
    if (-not (Test-Path -LiteralPath $settingsFile -PathType Leaf)) {
        $script:settingsNeedSave = $true
        return [ordered]@{ Version = 4; KnownBackupDrive = $null; FolderSelection = $null; LastSuccessfulBackup = $null; ReminderEnabled = $true; ReminderDays = 14 }
    }
    try {
        $parsed = Get-Content -LiteralPath $settingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $parsedVersion = 0
        if ($parsed.PSObject.Properties['Version']) { [void][int]::TryParse([string]$parsed.Version, [ref]$parsedVersion) }
        $migrateReminderDefaults = $parsedVersion -lt 4
        $reminderDays = 14
        $parsedDays = 0
        if ($parsed.PSObject.Properties['ReminderDays'] -and [int]::TryParse([string]$parsed.ReminderDays, [ref]$parsedDays) -and $parsedDays -ge 1 -and $parsedDays -le 3650) {
            # Version 3 originally emitted 7 as a fixed default. Preserve any
            # other valid value in case it was deliberately customized.
            $reminderDays = if ($migrateReminderDefaults -or $parsedDays -eq 7) { 14 } else { $parsedDays }
        }
        $hasReminderEnabled = [bool]$parsed.PSObject.Properties['ReminderEnabled']
        $hasReminderDays = [bool]$parsed.PSObject.Properties['ReminderDays']
        if ($migrateReminderDefaults -or -not $hasReminderEnabled -or -not $hasReminderDays -or $parsedDays -eq 7) {
            $script:settingsNeedSave = $true
        }
        return [ordered]@{
            Version = 4
            KnownBackupDrive = $parsed.KnownBackupDrive
            FolderSelection = $parsed.FolderSelection
            LastSuccessfulBackup = $(if ($parsed.PSObject.Properties['LastSuccessfulBackup']) { [string]$parsed.LastSuccessfulBackup } else { $null })
            ReminderEnabled = $(if ($migrateReminderDefaults -or -not $hasReminderEnabled) { $true } else { [bool]$parsed.ReminderEnabled })
            ReminderDays = $reminderDays
        }
    } catch {
        # Eine nur voruebergehend nicht lesbare Datei darf nicht ueberschrieben werden.
        $script:settingsWritable = $false
        return [ordered]@{ Version = 4; KnownBackupDrive = $null; FolderSelection = $null; LastSuccessfulBackup = $null; ReminderEnabled = $false; ReminderDays = 14 }
    }
}

function Save-AppSettings {
    if (-not $script:settingsWritable) { throw (L 'Die vorhandenen Einstellungen konnten nicht sicher gelesen werden.' 'Existing settings could not be read safely.') }
    $json = $script:settings | ConvertTo-Json -Depth 6
    New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
    Write-M24AtomicTextFile -Path $settingsFile -Content $json
}

function Get-KnownBackupDrive {
    $known = $script:settings.KnownBackupDrive
    if (-not $known) { return $null }
    $legacySerial = if ($known.PSObject.Properties['VolumeSerialNumber']) { [string]$known.VolumeSerialNumber } else { [string]$known.SerialNumber }
    if (-not $legacySerial -and -not $known.VolumeGuid -and -not $known.DiskUniqueId) { return $null }
    return [pscustomobject]@{
        VolumeGuid = [string]$known.VolumeGuid
        VolumeSerialNumber = $legacySerial.Trim().Replace('-', '').ToUpperInvariant()
        DiskUniqueId = [string]$known.DiskUniqueId
        DiskSerialNumber = [string]$known.DiskSerialNumber
        SizeBytes = $(if ($known.SizeBytes) { [int64]$known.SizeBytes } else { $null })
        FileSystem = [string]$known.FileSystem
        VolumeName = [string]$known.VolumeName
        LastDeviceId = [string]$known.LastDeviceId
        SavedAt = [string]$known.SavedAt
    }
}

function Get-SavedFolderSelection { return $script:settings.FolderSelection }

function Test-IsKnownBackupDrive {
    param($Disk)
    if ($Disk -and $Disk.PSObject.Properties['M24IsKnownBackupDrive']) { return [bool]$Disk.M24IsKnownBackupDrive }
    return [bool](Compare-M24DriveFingerprint -Known $script:knownDrive -Candidate $Disk).IsMatch
}

function Save-KnownBackupDrive {
    param($Disk)

    $serial = Get-NormalizedVolumeSerial -Disk $Disk
    if (-not $serial -and -not $Disk.M24VolumeGuid -and -not $Disk.M24DiskUniqueId) {
        throw (L 'Die Datenträger-ID konnte nicht gelesen werden.' 'The drive identifier could not be read.')
    }

    $knownDrive = [pscustomobject]@{
        VolumeGuid = [string]$Disk.M24VolumeGuid
        VolumeSerialNumber = $serial
        DiskUniqueId = [string]$Disk.M24DiskUniqueId
        DiskSerialNumber = [string]$Disk.M24DiskSerialNumber
        SizeBytes = [int64]$Disk.Size
        FileSystem = [string]$Disk.FileSystem
        VolumeName = [string]$Disk.VolumeName
        LastDeviceId = [string]$Disk.DeviceID
        SavedAt = (Get-Date).ToString('o')
    }
    $script:knownDrive = $knownDrive
    $script:settings.KnownBackupDrive = $knownDrive
    Save-AppSettings
}

function Clear-KnownBackupDrive {
    $script:knownDrive = $null
    $script:settings.KnownBackupDrive = $null
    Save-AppSettings
}

function Save-FolderSelection {
    if ($backupRadio.Checked) { Update-BackupSelectionSnapshot }
    if (-not $script:backupSelectionSnapshot) { return }
    $script:settings.FolderSelection = $script:backupSelectionSnapshot
    Save-AppSettings
}

function Dismount-BackupDriveSafely {
    param([string]$Drive)

    $driveRoot = "{0}\" -f $Drive.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $driveRoot)) {
        return [pscustomobject]@{ Success = $true; Method = 'AlreadyEjected'; Message = L 'Das Laufwerk ist nicht mehr eingebunden und kann entfernt werden.' 'The drive is no longer mounted and can be removed.' }
    }

    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $driveItem = $shell.Namespace(17).ParseName($driveRoot)
        if ($driveItem) {
            $driveItem.InvokeVerb('Eject')
            for ($attempt = 0; $attempt -lt 8; $attempt++) {
                Start-Sleep -Milliseconds 250
                if (-not (Test-Path -LiteralPath $driveRoot)) {
                    return [pscustomobject]@{ Success = $true; Method = 'Eject'; Message = L 'Laufwerk wurde sicher ausgeworfen und kann entfernt werden.' 'The drive was safely ejected and can be removed.' }
                }
            }
        }
    } catch {
        # Fallback unten versuchen.
    } finally {
        if ($shell) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }

    # Der Shell-Auswurf kann unmittelbar nach der Wartefrist fertig werden.
    if (-not (Test-Path -LiteralPath $driveRoot)) {
        return [pscustomobject]@{ Success = $true; Method = 'Eject'; Message = L 'Laufwerk wurde sicher ausgeworfen und kann entfernt werden.' 'The drive was safely ejected and can be removed.' }
    }

    try {
        $volume = Get-CimInstance Win32_Volume -Filter ("DriveLetter='{0}'" -f $Drive.TrimEnd('\')) -ErrorAction Stop
        $result = Invoke-CimMethod -InputObject $volume -MethodName Dismount -Arguments @{ Force = $false; Permanent = $false } -ErrorAction Stop
        if ($result.ReturnValue -eq 0) {
            return [pscustomobject]@{ Success = $true; Method = 'Dismount'; Message = L 'Laufwerk wurde ausgehängt und kann entfernt werden.' 'The drive was dismounted and can be removed.' }
        }
        throw "WMI ReturnValue $($result.ReturnValue)"
    } catch {
        return [pscustomobject]@{ Success = $false; Method = 'None'; Message = $_.Exception.Message }
    }
}

function Get-BackupHealth {
    param(
        [string]$Drive,
        [string]$BackupRoot
    )

    $backupDirectory = if ($BackupRoot) { $BackupRoot } else { Get-BackupRoot -Drive $Drive }
    $metadataFile = Join-Path $backupDirectory '_Sicherungsinfo.txt'
    if (-not (Test-Path -LiteralPath $metadataFile -PathType Leaf)) {
        return [pscustomobject]@{
            Level = 'Red'
            Text = L 'Keine Sicherung für dieses Profil' 'No backup for this profile'
            Details = L 'Auf diesem Laufwerk wurde noch keine Sicherung für diesen Computer und Benutzer gefunden.' 'No backup for this computer and user was found on this drive.'
        }
    }

    try {
        $lines = @(Get-Content -LiteralPath $metadataFile -ErrorAction Stop)
        if (-not $BackupRoot -and -not (Test-BackupMetadataMatchesCurrentProfile -Lines $lines)) {
            throw (L 'Die Sicherungsmetadaten gehören zu einem anderen Profil.' 'The backup metadata belongs to a different profile.')
        }

        $startLine = $lines | Where-Object { $_ -like 'Letzter Sicherungsversuch:*' } | Select-Object -First 1
        $resultLine = $lines | Where-Object { $_ -like 'Ergebnis:*' } | Select-Object -Last 1
        $folderLine = $lines | Where-Object { $_ -like 'Ordner:*' } | Select-Object -First 1
        if (-not $resultLine -or $resultLine -notmatch '^Ergebnis:\s*(.+?)\s+am\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.?$') {
            return [pscustomobject]@{
                Level = 'Red'
                Text = L 'Letzte Sicherung nicht vollständig' 'Last backup is incomplete'
                Details = L 'Der letzte Sicherungsversuch enthält keinen gültigen Abschlussstatus.' 'The last backup attempt has no valid completion status.'
            }
        }

        $outcome = $matches[1]
        $finishedAt = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($matches[2], 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$finishedAt)) {
            throw (L 'Der Abschlusszeitpunkt ist ungültig.' 'The completion time is invalid.')
        }

        $folders = @()
        if ($folderLine) {
            $folderText = ($folderLine -replace '^Ordner:\s*', '').Trim()
            if ($folderText) { $folders = @($folderText -split '\s*,\s*' | Where-Object { $_ }) }
        }

        $durationText = $null
        if ($startLine) {
            $startedAt = [datetime]::MinValue
            $startText = ($startLine -replace '^Letzter Sicherungsversuch:\s*', '').Trim()
            if ([datetime]::TryParseExact($startText, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$startedAt) -and $finishedAt -ge $startedAt) {
                $elapsed = $finishedAt - $startedAt
                $durationText = Format-ElapsedDuration $elapsed
            }
        }

        $dateText = if ($finishedAt.Date -eq (Get-Date).Date) {
            (L 'heute, {0:HH:mm}' 'today, {0:HH:mm}') -f $finishedAt
        } else {
            $finishedAt.ToString((L 'dd.MM.yyyy, HH:mm' 'yyyy-MM-dd, HH:mm'))
        }
        $folderText = if ($folders.Count -eq 1) { L '1 Ordner' '1 folder' } else { (L '{0} Ordner' '{0} folders') -f $folders.Count }
        $detailsParts = @($dateText, $folderText)
        if ($durationText) { $detailsParts += (L "Dauer $durationText" "duration $durationText") }
        $details = $detailsParts -join ' · '

        if ($outcome -eq 'Erfolgreich abgeschlossen') {
            $ageDays = [math]::Floor(((Get-Date) - $finishedAt).TotalDays)
            if ($ageDays -le 7) {
                $level = 'Green'
                $caption = L 'Aktuell' 'Up to date'
            } elseif ($ageDays -le 14) {
                $level = 'Yellow'
                $caption = L 'Bald fällig' 'Due soon'
            } else {
                $level = 'Red'
                $caption = L 'Veraltet' 'Out of date'
            }
            return [pscustomobject]@{ Level = $level; Text = "$caption · $details"; Details = $details }
        }

        $caption = if ($outcome -like 'Vom Benutzer abgebrochen*') {
            L 'Letzte Sicherung abgebrochen' 'Last backup was cancelled'
        } else {
            L 'Letzte Sicherung fehlgeschlagen' 'Last backup failed'
        }
        return [pscustomobject]@{ Level = 'Red'; Text = "$caption · $dateText"; Details = "$caption · $details" }
    } catch {
        return [pscustomobject]@{
            Level = 'Red'
            Text = L 'Sicherungsstatus nicht lesbar' 'Backup status unavailable'
            Details = $_.Exception.Message
        }
    }
}

<#
Theme-Strategie (dokumentiert, siehe plan.md Arbeitspaket 6):
Die Oberflaeche verwendet eine zentrale semantische Palette statt verstreuter
RGB-Literale. Bei aktivem Windows-Hochkontrastmodus werden ausschliesslich
Systemfarben und die Systemdarstellung der Buttons verwendet, damit das
gewaehlte Kontrastschema vollstaendig wirksam bleibt. Ein eigener Dark Mode
wird bewusst nicht ausgeliefert: WinForms unter .NET Framework rendert
ComboBox-Listen, Scrollbalken und Menues weiterhin hell; statt eines
inkonsistenten dunklen Themes bleibt ein konsistentes, kontrastgeprueftes
helles Theme erhalten (Risikoabwaegung aus plan.md).
#>
# Der Hochkontrastzustand wird bewusst nur einmal beim Start gelesen; ein
# Schemawechsel bei laufender Anwendung greift nach einem Neustart (die von
# plan.md erlaubte Neustart-Variante fuer Themenwechsel).
$script:highContrast = [System.Windows.Forms.SystemInformation]::HighContrast
if ($script:highContrast) {
    $formBackColor = [System.Drawing.SystemColors]::Control
    $surfaceColor = [System.Drawing.SystemColors]::Control
    $listBackColor = [System.Drawing.SystemColors]::Window
    $buttonBorderColor = [System.Drawing.SystemColors]::ControlText
    $secondaryTextColor = [System.Drawing.SystemColors]::ControlText
    $hoverBackColor = [System.Drawing.SystemColors]::Control
    $dangerTextColor = [System.Drawing.SystemColors]::ControlText
    $dangerHoverBackColor = [System.Drawing.SystemColors]::Control
    $successTextColor = [System.Drawing.SystemColors]::ControlText
    $warningTextColor = [System.Drawing.SystemColors]::ControlText
    $errorTextColor = [System.Drawing.SystemColors]::ControlText
    $healthProblemTextColor = [System.Drawing.SystemColors]::ControlText
    $infoBackColor = [System.Drawing.SystemColors]::Info
    $infoTextColor = [System.Drawing.SystemColors]::InfoText
} else {
    $formBackColor = [System.Drawing.Color]::FromArgb(243, 246, 249)
    $surfaceColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
    $listBackColor = [System.Drawing.Color]::White
    $buttonBorderColor = [System.Drawing.Color]::FromArgb(185, 193, 202)
    # 82,89,96 auf Weiss erreicht rund 5,9:1 und erfuellt damit die geforderte
    # Mindestkontrastrate von 4,5:1 fuer normalen Text.
    $secondaryTextColor = [System.Drawing.Color]::FromArgb(82, 89, 96)
    $hoverBackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
    $dangerTextColor = [System.Drawing.Color]::FromArgb(164, 38, 44)
    $dangerHoverBackColor = [System.Drawing.Color]::FromArgb(253, 239, 240)
    $successTextColor = [System.Drawing.Color]::DarkGreen
    $warningTextColor = [System.Drawing.Color]::FromArgb(157, 93, 0)
    $errorTextColor = [System.Drawing.Color]::FromArgb(164, 38, 44)
    $healthProblemTextColor = [System.Drawing.Color]::FromArgb(153, 27, 27)
    $infoBackColor = [System.Drawing.Color]::FromArgb(255, 247, 224)
    $infoTextColor = [System.Drawing.Color]::FromArgb(128, 72, 0)
}
$accentColor = [System.Drawing.SystemColors]::Highlight
$accentTextColor = [System.Drawing.SystemColors]::HighlightText
$accentHoverColor = [System.Windows.Forms.ControlPaint]::Dark($accentColor)
$captionFont = New-Object System.Drawing.Font($semiboldFontName, 9.5)
$footerButtonFont = New-Object System.Drawing.Font($semiboldFontName, 10)

<#
Interaktionsziele (plan.md Arbeitspaket 4): Alle Befehle entstehen ueber eine
gemeinsame Fabrik mit einheitlichen Zustaenden. Regulaere Befehle sind
mindestens 32 logische Pixel hoch, die Hauptaktionen im Fussbereich 40.
Im Hochkontrastmodus rendert die Systemdarstellung Rahmen und Fokus.
#>
function New-M24Button {
    param(
        [string]$Text,
        [int]$Width = 100,
        [int]$Height = 32,
        [ValidateSet('Primary', 'Secondary', 'Danger')][string]$Kind = 'Secondary',
        [System.Drawing.Font]$Font
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object System.Drawing.Size($Width, $Height)
    if ($Font) { $button.Font = $Font }
    if ($script:highContrast) {
        $button.FlatStyle = [System.Windows.Forms.FlatStyle]::System
        return $button
    }
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    switch ($Kind) {
        'Primary' {
            $button.BackColor = $accentColor
            $button.ForeColor = $accentTextColor
            $button.FlatAppearance.BorderSize = 0
            $button.FlatAppearance.MouseOverBackColor = $accentHoverColor
        }
        'Danger' {
            $button.BackColor = $surfaceColor
            $button.ForeColor = $dangerTextColor
            $button.FlatAppearance.BorderSize = 1
            $button.FlatAppearance.BorderColor = $dangerTextColor
            $button.FlatAppearance.MouseOverBackColor = $dangerHoverBackColor
        }
        default {
            $button.BackColor = $surfaceColor
            $button.FlatAppearance.BorderSize = 1
            $button.FlatAppearance.BorderColor = $buttonBorderColor
            $button.FlatAppearance.MouseOverBackColor = $hoverBackColor
        }
    }
    return $button
}

$form = New-Object System.Windows.Forms.Form
$form.Text = L "Bibliothekssicherung" "Library Backup"
if ($appVersion) { $form.Text = "{0} {1}" -f $form.Text, $appVersion }
$form.StartPosition = "CenterScreen"
# AutoScaleMode.Dpi skaliert das komplette logisch definierte Layout beim
# Start einmalig scharf auf die tatsaechliche System-DPI (siehe DPI-Strategie
# am Skriptanfang). Alle Masse in dieser Datei sind 96-DPI-Logikpixel.
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
# Breit genug, damit die vier Vorgangsoptionen bei deutschen Beschriftungen
# normalerweise in einer Zeile stehen; bei schmaleren Fenstern brechen sie um.
$form.ClientSize = New-Object System.Drawing.Size(840, 810)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.KeyPreview = $true
$form.Font = New-Object System.Drawing.Font($textFontName, 9.5)
$form.BackColor = $formBackColor
$appIconFile = Join-Path $PSScriptRoot 'app.ico'
if (Test-Path -LiteralPath $appIconFile -PathType Leaf) {
    try {
        $iconStream = [System.IO.File]::Open($appIconFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sourceIcon = New-Object System.Drawing.Icon($iconStream)
            try { $appIcon = [System.Drawing.Icon]$sourceIcon.Clone() } finally { $sourceIcon.Dispose() }
        } finally { $iconStream.Dispose() }
    } catch { $appIcon = $null }
}
$form.Icon = if ($appIcon) { $appIcon } else { [System.Drawing.SystemIcons]::Shield }
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $form.Icon
$notifyIcon.Text = L 'Bibliothekssicherung' 'Library Backup'
$notificationTimer = New-Object System.Windows.Forms.Timer
$notificationTimer.Interval = 6500
$notificationTimer.Add_Tick({ $notificationTimer.Stop(); $notifyIcon.Visible = $false })

function Show-CompletionNotification {
    param([string]$Title, [string]$Text, [System.Windows.Forms.ToolTipIcon]$Icon)
    if ($form.ContainsFocus -and $form.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized) { return }
    $notifyIcon.Visible = $true
    $notifyIcon.ShowBalloonTip(5000, $Title, $Text, $Icon)
    $notificationTimer.Stop()
    $notificationTimer.Start()
}
<#
Responsives Layout (plan.md Arbeitspaket 2): Ein aeusseres TableLayoutPanel
stapelt die Funktionsbereiche vertikal. Kopf-, Ziel-, Options-, Aktivitaets-
und Fussbereich bemessen sich selbst; der Ordnerbereich erhaelt die restliche
Hoehe und waechst beim Vergroessern oder Maximieren des Fensters mit. Die
Bereichsflaechen sind zugleich die Eltern ihrer Steuerelemente; separate
dekorative Panels samt SendToBack-Reparatur entfallen.
#>
$layoutRoot = New-Object System.Windows.Forms.TableLayoutPanel
$contentHost = New-Object System.Windows.Forms.Panel
$contentHost.Dock = [System.Windows.Forms.DockStyle]::Fill
$contentHost.AutoScroll = $false
$contentHost.BackColor = [System.Drawing.Color]::Transparent
$contentHost.TabIndex = 0
$form.Controls.Add($contentHost)

$layoutRoot.Dock = [System.Windows.Forms.DockStyle]::Top
$layoutRoot.AutoSize = $false
$layoutRoot.Margin = New-Object System.Windows.Forms.Padding(0)
$layoutRoot.BackColor = [System.Drawing.Color]::Transparent
$layoutRoot.ColumnCount = 1
[void]$layoutRoot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$layoutRoot.RowCount = 5
[void]$layoutRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$layoutRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$layoutRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$layoutRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$layoutRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$contentHost.Controls.Add($layoutRoot)

$headerPanel = New-Object System.Windows.Forms.TableLayoutPanel
$headerPanel.AutoSize = $true
$headerPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$headerPanel.BackColor = [System.Drawing.Color]::Transparent
$headerPanel.ColumnCount = 2
[void]$headerPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$headerPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
$headerPanel.RowCount = 1
$headerPanel.Margin = New-Object System.Windows.Forms.Padding(16, 12, 16, 4)
$headerPanel.Anchor = 'Top, Left, Right'
$headerPanel.TabIndex = 0
$layoutRoot.Controls.Add($headerPanel, 0, 0)

$headerTextFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$headerTextFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$headerTextFlow.WrapContents = $false
$headerTextFlow.AutoSize = $true
$headerTextFlow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$headerTextFlow.BackColor = [System.Drawing.Color]::Transparent
$headerTextFlow.Margin = New-Object System.Windows.Forms.Padding(0)
$headerTextFlow.Anchor = 'Top, Left'
$headerPanel.Controls.Add($headerTextFlow, 0, 0)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = L "Dateien sichern" "Back up files"
$titleLabel.Font = New-Object System.Drawing.Font($displayFontName, 18)
$titleLabel.AutoSize = $true
$titleLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 2)
$headerTextFlow.Controls.Add($titleLabel)

$descriptionLabel = New-Object System.Windows.Forms.Label
# Voller Wortlaut wie in Update-LibraryList, das den Text bei jedem
# Moduswechsel ohnehin neu setzt; die Kopfzeile bricht bei Platzmangel um.
$descriptionLabel.Text = L "Wählen Sie Ziel und Ordner. Vorhandene Dateien werden nicht gelöscht." "Choose a destination and folders. Existing files are not deleted."
$descriptionLabel.AutoSize = $true
$descriptionLabel.ForeColor = $secondaryTextColor
$descriptionLabel.Margin = New-Object System.Windows.Forms.Padding(2, 0, 0, 0)
$headerTextFlow.Controls.Add($descriptionLabel)

$headerCommandFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$headerCommandFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$headerCommandFlow.WrapContents = $false
$headerCommandFlow.AutoSize = $true
$headerCommandFlow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$headerCommandFlow.BackColor = [System.Drawing.Color]::Transparent
$headerCommandFlow.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
$headerCommandFlow.Anchor = 'Top, Right'
$headerPanel.Controls.Add($headerCommandFlow, 1, 0)

$helpButton = New-M24Button -Text (L "Hilfe" "Help") -Width 76 -Height 36
$helpButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$helpButton.TabIndex = 0
$headerCommandFlow.Controls.Add($helpButton)

# Der Modus-Umschalter liegt auf einer eigenen umrahmten Flaeche, damit er
# sich vom Formularhintergrund abhebt und nicht gedrungen wirkt. Seine Breite
# ergibt sich aus der Textlaenge der jeweiligen Sprache.
$modePanel = New-Object System.Windows.Forms.Panel
$modePanel.BackColor = $surfaceColor
$modePanel.Margin = New-Object System.Windows.Forms.Padding(0)
$modePanel.TabIndex = 1
$modePanel.Add_Paint({
    param($sender, $eventArgs)
    $borderPen = New-Object System.Drawing.Pen($buttonBorderColor)
    try {
        $eventArgs.Graphics.DrawRectangle($borderPen, 0, 0, $sender.ClientSize.Width - 1, $sender.ClientSize.Height - 1)
    } finally { $borderPen.Dispose() }
})
$headerCommandFlow.Controls.Add($modePanel)

$backupRadio = New-Object System.Windows.Forms.RadioButton
$backupRadio.Text = L "Sichern" "Back up"
$backupRadio.AutoSize = $true
$backupRadio.Location = New-Object System.Drawing.Point(14, 8)
$backupRadio.Checked = $true
$backupRadio.TabIndex = 0
$modePanel.Controls.Add($backupRadio)

$restoreRadio = New-Object System.Windows.Forms.RadioButton
$restoreRadio.Text = L "Wiederherstellen" "Restore"
$restoreRadio.AutoSize = $true
$restoreRadio.TabIndex = 1
$modePanel.Controls.Add($restoreRadio)
$restoreRadio.Location = New-Object System.Drawing.Point(($backupRadio.Left + $backupRadio.GetPreferredSize([System.Drawing.Size]::Empty).Width + 14), 8)

$modePanel.Size = New-Object System.Drawing.Size(($restoreRadio.Left + $restoreRadio.GetPreferredSize([System.Drawing.Size]::Empty).Width + 14), 36)

$targetSurface = New-Object System.Windows.Forms.TableLayoutPanel
$targetSurface.BackColor = $surfaceColor
$targetSurface.AutoSize = $true
$targetSurface.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$targetSurface.ColumnCount = 3
[void]$targetSurface.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$targetSurface.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$targetSurface.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
$targetSurface.RowCount = 5
for ($targetRowIndex = 0; $targetRowIndex -lt 5; $targetRowIndex++) {
    [void]$targetSurface.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
}
$targetSurface.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 8)
$targetSurface.Margin = New-Object System.Windows.Forms.Padding(16, 4, 16, 4)
$targetSurface.Dock = [System.Windows.Forms.DockStyle]::Top
$targetSurface.TabIndex = 1
$layoutRoot.Controls.Add($targetSurface, 0, 1)

$driveLabel = New-Object System.Windows.Forms.Label
$driveLabel.Text = L "Ziellaufwerk:" "Destination drive:"
$driveLabel.AutoSize = $true
$driveLabel.Font = $captionFont
$driveLabel.BackColor = $surfaceColor
$driveLabel.Margin = New-Object System.Windows.Forms.Padding(4, 8, 12, 0)
$driveLabel.Anchor = 'Left'
$targetSurface.Controls.Add($driveLabel, 0, 0)

$driveCombo = New-Object System.Windows.Forms.ComboBox
$driveCombo.DropDownStyle = "DropDownList"
$driveCombo.Dock = [System.Windows.Forms.DockStyle]::Fill
$driveCombo.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)
$driveCombo.AccessibleName = L 'Ziellaufwerk' 'Destination drive'
$driveCombo.TabIndex = 0
$targetSurface.Controls.Add($driveCombo, 1, 0)

$driveToolTip = New-Object System.Windows.Forms.ToolTip

$refreshButton = New-M24Button -Text (L "Aktualisieren" "Refresh") -Width 120 -Height 32
$refreshButton.Margin = New-Object System.Windows.Forms.Padding(0, 2, 4, 2)
$refreshButton.Anchor = 'Right'
$refreshButton.TabIndex = 1
$targetSurface.Controls.Add($refreshButton, 2, 0)

$backupSourceLabel = New-Object System.Windows.Forms.Label
$backupSourceLabel.Text = L 'Gefundene Sicherung:' 'Backup:'
$backupSourceLabel.AutoSize = $true
$backupSourceLabel.Font = $captionFont
$backupSourceLabel.Margin = New-Object System.Windows.Forms.Padding(4, 8, 12, 0)
$backupSourceLabel.Anchor = 'Left'
$backupSourceLabel.Visible = $false
$targetSurface.Controls.Add($backupSourceLabel, 0, 1)

$backupSourceCombo = New-Object System.Windows.Forms.ComboBox
$backupSourceCombo.DropDownStyle = 'DropDownList'
$backupSourceCombo.Dock = [System.Windows.Forms.DockStyle]::Fill
$backupSourceCombo.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)
$backupSourceCombo.AccessibleName = L 'Gefundene Sicherung' 'Backup'
$backupSourceCombo.Visible = $false
$targetSurface.Controls.Add($backupSourceCombo, 1, 1)
$targetSurface.SetColumnSpan($backupSourceCombo, 2)

$backupSourceInfoLabel = New-Object System.Windows.Forms.Label
$backupSourceInfoLabel.AutoSize = $true
$backupSourceInfoLabel.ForeColor = $secondaryTextColor
$backupSourceInfoLabel.Margin = New-Object System.Windows.Forms.Padding(4, 0, 4, 4)
$backupSourceInfoLabel.Visible = $false
$targetSurface.Controls.Add($backupSourceInfoLabel, 0, 2)
$targetSurface.SetColumnSpan($backupSourceInfoLabel, 3)

$restoreTargetPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$restoreTargetPanel.AutoSize = $true
$restoreTargetPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$restoreTargetPanel.WrapContents = $true
$restoreTargetPanel.Margin = New-Object System.Windows.Forms.Padding(4, 0, 4, 4)
$restoreTargetPanel.Visible = $false
$targetSurface.Controls.Add($restoreTargetPanel, 0, 3)
$targetSurface.SetColumnSpan($restoreTargetPanel, 3)

$restoreProfileRadio = New-Object System.Windows.Forms.RadioButton
$restoreProfileRadio.Text = L 'In mein Benutzerprofil' 'Restore to my user profile'
$restoreProfileRadio.AutoSize = $true
$restoreProfileRadio.Checked = $true
$restoreProfileRadio.Margin = New-Object System.Windows.Forms.Padding(0, 6, 16, 0)
$restoreTargetPanel.Controls.Add($restoreProfileRadio)

$restoreFolderRadio = New-Object System.Windows.Forms.RadioButton
$restoreFolderRadio.Text = L 'In einen anderen Ordner kopieren' 'Copy to another folder'
$restoreFolderRadio.AutoSize = $true
$restoreFolderRadio.Margin = New-Object System.Windows.Forms.Padding(0, 6, 8, 0)
$restoreTargetPanel.Controls.Add($restoreFolderRadio)

$restoreFolderButton = New-M24Button -Text (L 'Ordner wählen …' 'Choose folder…') -Width 126 -Height 30
$restoreFolderButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$restoreFolderButton.Visible = $false
$restoreTargetPanel.Controls.Add($restoreFolderButton)

$restoreFolderLabel = New-Object System.Windows.Forms.Label
$restoreFolderLabel.AutoSize = $true
$restoreFolderLabel.AutoEllipsis = $true
$restoreFolderLabel.ForeColor = $secondaryTextColor
$restoreFolderLabel.Margin = New-Object System.Windows.Forms.Padding(0, 7, 0, 0)
$restoreFolderLabel.Visible = $false
$restoreTargetPanel.Controls.Add($restoreFolderLabel)

$driveStatusPanel = New-Object System.Windows.Forms.Panel
$driveStatusPanel.BackColor = $surfaceColor
# Breite vor dem Hinzufuegen der verankerten Kinder setzen: Die Anker-Deltas
# von healthPanel und fat32Label beziehen sich auf diese Ausgangsbreite.
$driveStatusPanel.Size = New-Object System.Drawing.Size(716, 28)
$driveStatusPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$driveStatusPanel.Margin = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
$targetSurface.Controls.Add($driveStatusPanel, 0, 4)
$targetSurface.SetColumnSpan($driveStatusPanel, 3)

$driveInfoLabel = New-Object System.Windows.Forms.Label
$driveInfoLabel.AutoSize = $true
$driveInfoLabel.ForeColor = $secondaryTextColor
$driveInfoLabel.Location = New-Object System.Drawing.Point(0, 4)
$driveInfoLabel.BackColor = $surfaceColor
$driveStatusPanel.Controls.Add($driveInfoLabel)

$healthPanel = New-Object System.Windows.Forms.Panel
$healthPanel.Location = New-Object System.Drawing.Point(164, 0)
$healthPanel.Size = New-Object System.Drawing.Size(552, 25)
$healthPanel.Anchor = 'Top, Left, Right'
$healthPanel.BackColor = $surfaceColor
$driveStatusPanel.Controls.Add($healthPanel)

$healthDot = New-Object System.Windows.Forms.Panel
$healthDot.Location = New-Object System.Drawing.Point(0, 6)
$healthDot.Size = New-Object System.Drawing.Size(12, 12)
$healthDot.BackColor = $surfaceColor
$healthDot.Tag = [System.Drawing.Color]::FromArgb(196, 43, 28)
$healthDot.Add_Paint({
    param($sender, $eventArgs)
    $eventArgs.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]$sender.Tag)
    try { $eventArgs.Graphics.FillEllipse($brush, 0, 0, $sender.Width - 1, $sender.Height - 1) } finally { $brush.Dispose() }
})
$healthPanel.Controls.Add($healthDot)

$healthLabel = New-Object System.Windows.Forms.Label
$healthLabel.AutoEllipsis = $true
$healthLabel.Location = New-Object System.Drawing.Point(20, 2)
$healthLabel.Size = New-Object System.Drawing.Size(512, 21)
$healthLabel.Anchor = 'Top, Left, Right'
$healthLabel.Text = L 'Keine Sicherung für dieses Profil' 'No backup for this profile'
$healthLabel.AccessibleName = L 'Sicherungsstatus' 'Backup status'
$healthPanel.Controls.Add($healthLabel)

$healthToolTip = New-Object System.Windows.Forms.ToolTip
function Update-BackupHealth {
    $fat32Label.Visible = $false
    $driveInfoLabel.Visible = $true
    if (-not $driveCombo.SelectedItem) {
        $healthPanel.Visible = $false
        return
    }

    $disk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
    $showFat32Warning = $backupRadio.Checked -and ([string]$disk.FileSystem).Equals('FAT32', [System.StringComparison]::OrdinalIgnoreCase)
    $fat32Label.Visible = $showFat32Warning
    $driveInfoLabel.Visible = -not $showFat32Warning
    if ($showFat32Warning) {
        $healthPanel.Visible = $false
        return
    }
    $selectedBackup = if ($restoreRadio.Checked) { Get-SelectedBackupInventoryItem } else { $null }
    $health = if ($restoreRadio.Checked -and -not $selectedBackup) {
        [pscustomobject]@{
            Level = 'Red'
            Text = L 'Keine Sicherung auf diesem Laufwerk' 'No backup on this drive'
            Details = L 'Für eine Wiederherstellung wurde auf diesem Laufwerk keine verwendbare Sicherung gefunden.' 'No usable backup was found on this drive for restore.'
        }
    } else {
        Get-BackupHealth -Drive $disk.DeviceID -BackupRoot $(if ($selectedBackup) { [string]$selectedBackup.RootPath } else { $null })
    }
    $healthDot.Tag = switch ($health.Level) {
        'Green' { [System.Drawing.Color]::FromArgb(16, 124, 16) }
        'Yellow' { [System.Drawing.Color]::FromArgb(202, 143, 0) }
        default { [System.Drawing.Color]::FromArgb(196, 43, 28) }
    }
    $healthLabel.Text = $health.Text
    $healthLabel.ForeColor = if ($health.Level -eq 'Red') { $healthProblemTextColor } else { $secondaryTextColor }
    $healthToolTip.SetToolTip($healthPanel, $health.Details)
    $healthToolTip.SetToolTip($healthLabel, $health.Details)
    $healthToolTip.SetToolTip($healthDot, $health.Details)
    $healthPanel.Visible = $true
    $healthDot.Invalidate()
}

$fat32Label = New-Object System.Windows.Forms.Label
$fat32Label.Text = L "Hinweis: FAT32 kann keine Dateien über 4 GB speichern. exFAT oder NTFS wird empfohlen." "FAT32 cannot store files of 4 GB or larger. exFAT or NTFS is recommended."
$fat32Label.ForeColor = $infoTextColor
$fat32Label.BackColor = $infoBackColor
$fat32Label.AutoSize = $false
$fat32Label.TextAlign = 'MiddleLeft'
$fat32Label.Location = New-Object System.Drawing.Point(0, 0)
$fat32Label.Size = New-Object System.Drawing.Size(716, 25)
$fat32Label.Anchor = 'Top, Left, Right'
$fat32Label.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
$fat32Label.Visible = $false
$driveStatusPanel.Controls.Add($fat32Label)

<#
Ordnerbereich (plan.md Arbeitspaket 3): Die Ordnerliste ist der dominante
Inhalt und waechst mit dem Fenster. Direkt wirkende Auswahlbefehle stehen
rechts neben der Liste; Befehle, die ein vorhandenes Backup betreffen,
bilden eine eigene beschriftete Gruppe am unteren Rand. "Backup loeschen"
steht dort bewusst zuletzt und raeumlich getrennt von den haeufig genutzten
Auswahlbefehlen. Das grosse Logo wurde aus dem Arbeitsbereich entfernt;
Branding verbleibt in Fenstersymbol, Titel und Splash.
#>
$folderSurface = New-Object System.Windows.Forms.TableLayoutPanel
$folderSurface.BackColor = $surfaceColor
$folderSurface.ColumnCount = 2
[void]$folderSurface.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$folderSurface.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
$folderSurface.RowCount = 3
[void]$folderSurface.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$folderSurface.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$folderSurface.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$folderSurface.Padding = New-Object System.Windows.Forms.Padding(12, 4, 12, 6)
$folderSurface.Margin = New-Object System.Windows.Forms.Padding(16, 4, 16, 4)
$folderSurface.Dock = [System.Windows.Forms.DockStyle]::Fill
# Die flexible Listenzeile darf nie niedriger als das danebenliegende
# 2x2-Raster der Auswahlbefehle werden. 156 Logikpixel fuer den gesamten
# Abschnitt lassen nach Ueberschrift, Innenabstaenden und Backupverwaltung
# mindestens die benoetigten 72 Pixel fuer Alle/Keine/Hinzufuegen/Entfernen.
$folderSurface.MinimumSize = New-Object System.Drawing.Size(0, 156)
$folderSurface.TabIndex = 2
$layoutRoot.Controls.Add($folderSurface, 0, 2)

$libraryLabel = New-Object System.Windows.Forms.Label
$libraryLabel.Text = L "Diese Ordner werden gesichert:" "These folders will be backed up:"
$libraryLabel.AutoSize = $true
$libraryLabel.Font = $captionFont
$libraryLabel.BackColor = $surfaceColor
$libraryLabel.Margin = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
$libraryLabel.Anchor = 'Top, Left'
$folderSurface.Controls.Add($libraryLabel, 0, 0)
$folderSurface.SetColumnSpan($libraryLabel, 2)

# Die Liste fuellt ihre Zelle vollstaendig; zusaetzlicher Platz beim
# Vergroessern oder Maximieren des Fensters kommt direkt ihr zugute.
$libraryList = New-Object System.Windows.Forms.CheckedListBox
$libraryList.Dock = [System.Windows.Forms.DockStyle]::Fill
$libraryList.Margin = New-Object System.Windows.Forms.Padding(4, 2, 12, 2)
$libraryList.CheckOnClick = $true
$libraryList.IntegralHeight = $false
$libraryList.BackColor = $listBackColor
$libraryList.AccessibleName = L 'Ordnerauswahl' 'Folder selection'
$libraryList.TabIndex = 0
$folderSurface.Controls.Add($libraryList, 0, 1)

foreach ($folder in Get-LibraryDefinitions) {
    $item = New-FolderListItem -Name $folder.Name -DisplayName (Get-M24FolderDisplayName $folder.Name $script:isGerman) -Path $folder.Path -IsCustom $false -Checked $true
    [void]$libraryList.Items.Add($item, $true)
}

# Auswahlbefehle als kompaktes 2x2-Raster rechts neben der Liste.
$folderCommandPanel = New-Object System.Windows.Forms.TableLayoutPanel
$folderCommandPanel.AutoSize = $true
$folderCommandPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$folderCommandPanel.BackColor = $surfaceColor
$folderCommandPanel.ColumnCount = 2
[void]$folderCommandPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$folderCommandPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
$folderCommandPanel.RowCount = 2
[void]$folderCommandPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$folderCommandPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$folderCommandPanel.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$folderCommandPanel.Anchor = 'Top, Right'
$folderCommandPanel.TabIndex = 1
$folderSurface.Controls.Add($folderCommandPanel, 1, 1)

$allButton = New-M24Button -Text (L "Alle" "All") -Width 88
$allButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 8)
$allButton.TabIndex = 0
$folderCommandPanel.Controls.Add($allButton, 0, 0)

$noneButton = New-M24Button -Text (L "Keine" "None") -Width 88
$noneButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
$noneButton.TabIndex = 1
$folderCommandPanel.Controls.Add($noneButton, 1, 0)

$addFolderButton = New-M24Button -Text (L "Hinzufügen" "Add folder") -Width 88
$addFolderButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$addFolderButton.TabIndex = 2
$folderCommandPanel.Controls.Add($addFolderButton, 0, 1)

$removeFolderButton = New-M24Button -Text (L "Entfernen" "Remove") -Width 88
$removeFolderButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
$removeFolderButton.Enabled = $false
$removeFolderButton.TabIndex = 3
$folderCommandPanel.Controls.Add($removeFolderButton, 1, 1)

# Backupverwaltung: Befehle, die ein vorhandenes Backup betreffen, bilden
# eine eigene beschriftete Zeile. "Backup loeschen" steht zuletzt und wird
# durch die flexible Leerspalte raeumlich von den Routinebefehlen getrennt.
$manageRow = New-Object System.Windows.Forms.TableLayoutPanel
$manageRow.AutoSize = $true
$manageRow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$manageRow.BackColor = $surfaceColor
$manageRow.ColumnCount = 5
[void]$manageRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$manageRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$manageRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$manageRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$manageRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
$manageRow.RowCount = 1
$manageRow.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$manageRow.Anchor = 'Top, Left, Right'
$manageRow.TabIndex = 2
$folderSurface.Controls.Add($manageRow, 0, 2)
$folderSurface.SetColumnSpan($manageRow, 2)

$manageLabel = New-Object System.Windows.Forms.Label
$manageLabel.Text = L 'Backupverwaltung:' 'Backup management:'
$manageLabel.AutoSize = $true
$manageLabel.Font = $captionFont
$manageLabel.BackColor = $surfaceColor
$manageLabel.Margin = New-Object System.Windows.Forms.Padding(4, 9, 12, 0)
$manageLabel.Anchor = 'Left'
$manageRow.Controls.Add($manageLabel, 0, 0)

$historyButton = New-M24Button -Text (L 'Verlauf' 'History') -Width 110
$historyButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$historyButton.Enabled = $false
$historyButton.TabIndex = 0
$manageRow.Controls.Add($historyButton, 1, 0)

$verifyButton = New-M24Button -Text (L 'Backup prüfen' 'Verify backup') -Width 130
$verifyButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$verifyButton.Enabled = $false
$verifyButton.TabIndex = 1
$manageRow.Controls.Add($verifyButton, 2, 0)

# Exakt so breit wie die beiden 88-Pixel-Spalten der Listenbefehle plus
# deren 8-Pixel-Zwischenraum: Dadurch entsteht rechts eine klare Fluchtlinie.
$deleteBackupButton = New-M24Button -Text (L 'Backup löschen' 'Delete backup') -Width 184 -Kind 'Danger'
$deleteBackupButton.Margin = New-Object System.Windows.Forms.Padding(24, 0, 0, 0)
$deleteBackupButton.Enabled = $false
$deleteBackupButton.TabIndex = 2
$manageRow.Controls.Add($deleteBackupButton, 4, 0)

<#
Optionen (plan.md Arbeitspaket 5): Vorgangsbezogene Optionen und die
dauerhafte Erinnerungs-Einstellung stehen in getrennten, beschrifteten
Zeilen. Die Optionszeile bricht bei schmalen Fenstern oder grosser Schrift
um, statt abgeschnitten zu werden. Der fruehere Name "Superschnell" heisst
jetzt "Schnellmodus (ohne Vorprüfung)", damit die Sicherheitsfolge sichtbar
ist und nicht allein im Tooltip steht.
#>
$optionsSurface = New-Object System.Windows.Forms.TableLayoutPanel
$optionsSurface.BackColor = $surfaceColor
$optionsSurface.AutoSize = $false
$optionsSurface.Size = New-Object System.Drawing.Size(748, 78)
$optionsSurface.ColumnCount = 2
[void]$optionsSurface.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$optionsSurface.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$optionsSurface.RowCount = 2
[void]$optionsSurface.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
[void]$optionsSurface.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32)))
$optionsSurface.Padding = New-Object System.Windows.Forms.Padding(12, 6, 12, 6)
$optionsSurface.Margin = New-Object System.Windows.Forms.Padding(16, 4, 16, 4)
$optionsSurface.Anchor = 'Top, Left, Right'
$optionsSurface.TabIndex = 3
$layoutRoot.Controls.Add($optionsSurface, 0, 3)

$optionsCaption = New-Object System.Windows.Forms.Label
$optionsCaption.Text = L 'Optionen:' 'Options:'
$optionsCaption.AutoSize = $true
$optionsCaption.Font = $captionFont
$optionsCaption.BackColor = $surfaceColor
$optionsCaption.Margin = New-Object System.Windows.Forms.Padding(4, 9, 12, 0)
$optionsCaption.Anchor = 'Top, Left'
$optionsSurface.Controls.Add($optionsCaption, 0, 0)

$operationOptionsFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$operationOptionsFlow.AutoSize = $true
$operationOptionsFlow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$operationOptionsFlow.WrapContents = $true
$operationOptionsFlow.BackColor = $surfaceColor
$operationOptionsFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
$operationOptionsFlow.Margin = New-Object System.Windows.Forms.Padding(0)
$operationOptionsFlow.TabIndex = 0
$optionsSurface.Controls.Add($operationOptionsFlow, 1, 0)

function New-M24OptionCheckBox {
    param([string]$Text, [int]$TabIndex)
    # Padding vergroessert die klickbare Flaeche der gesamten Optionszeile
    # ueber das reine Kaestchen hinaus (plan.md Arbeitspaket 4).
    $checkBox = New-Object System.Windows.Forms.CheckBox
    $checkBox.Text = $Text
    $checkBox.AutoSize = $true
    $checkBox.BackColor = $surfaceColor
    $checkBox.Margin = New-Object System.Windows.Forms.Padding(0, 2, 16, 2)
    $checkBox.Padding = New-Object System.Windows.Forms.Padding(2, 3, 2, 3)
    $checkBox.TabIndex = $TabIndex
    return $checkBox
}

$dryRunCheckBox = New-M24OptionCheckBox -Text (L "Simulation" "Dry run") -TabIndex 0
$operationOptionsFlow.Controls.Add($dryRunCheckBox)

$ejectCheckBox = New-M24OptionCheckBox -Text (L "Nach Erfolg auswerfen" "Eject after success") -TabIndex 1
$operationOptionsFlow.Controls.Add($ejectCheckBox)

$checksumCheckBox = New-M24OptionCheckBox -Text (L "Prüfsummen" "Checksums") -TabIndex 2
$checksumCheckBox.Checked = $true
$operationOptionsFlow.Controls.Add($checksumCheckBox)

$superFastCheckBox = New-M24OptionCheckBox -Text (L "Schnellmodus (ohne Vorprüfung)" "Fast mode (no preflight checks)") -TabIndex 3
$operationOptionsFlow.Controls.Add($superFastCheckBox)

$optionsToolTip = New-Object System.Windows.Forms.ToolTip
$optionsToolTip.AutoPopDelay = 20000
$superFastDetails = L `
    "Maximale Geschwindigkeit: keine Datei-Vorprüfung, keine Speicherplatz- und 4-GB-Dateiprüfung, keine Prüfsummenaktualisierung, keine BitLocker-Abfrage, keine Kopierwiederholungen. Fehler (z. B. volles Ziel) fallen ggf. erst beim Kopieren auf." `
    "Maximum speed: no file preflight, no disk-space or 4 GB file check, no checksum update, no BitLocker query, no copy retries. Errors (e.g. a full destination) may only surface while copying."
$optionsToolTip.SetToolTip($superFastCheckBox, $superFastDetails)
$superFastCheckBox.AccessibleDescription = $superFastDetails

$settingCaption = New-Object System.Windows.Forms.Label
$settingCaption.Text = L 'Einstellung:' 'Setting:'
$settingCaption.AutoSize = $true
$settingCaption.Font = $captionFont
$settingCaption.BackColor = $surfaceColor
$settingCaption.Margin = New-Object System.Windows.Forms.Padding(4, 9, 12, 0)
$settingCaption.Anchor = 'Top, Left'
$optionsSurface.Controls.Add($settingCaption, 0, 1)

# Dauerhafte Anwendungs-Einstellung, kein Vorgangs-Schalter: gilt ueber
# Programmstarts hinweg und registriert bzw. entfernt den Login-Autostart.
$reminderCheckBox = New-M24OptionCheckBox -Text (L 'Beim Windows-Login an fällige Sicherungen erinnern' 'Remind me at Windows sign-in when a backup is due') -TabIndex 1
$reminderCheckBox.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
$reminderCheckBox.Anchor = 'Top, Left'
$optionsSurface.Controls.Add($reminderCheckBox, 1, 1)
$reminderDetails = L `
    'Beim Windows-Login wird nach 14 Tagen ohne erfolgreiches GUI-Backup erinnert. Es wird kein Hintergrunddienst installiert.' `
    'At Windows login, a reminder appears after 14 days without a successful GUI backup. No background service is installed.'
$optionsToolTip.SetToolTip($reminderCheckBox, $reminderDetails)
$reminderCheckBox.AccessibleDescription = $reminderDetails

# Die Absolute-Zeilenhoehen des Optionsbereichs wachsen mit, sobald die
# umbruchfaehige Optionszeile oder der Erinnerungstext bei schmalen Fenstern
# (z. B. 200 % Skalierung auf 1366 Pixel Arbeitsbreite) mehrzeilig wird.
# Feste Zeilen plus explizite Nachberechnung umgehen die unzuverlaessige
# Wunschhoehen-Messung verschachtelter AutoSize-TableLayoutPanels.
function Update-OptionsSurfaceHeight {
    $scaleFactor = $form.CurrentAutoScaleDimensions.Width / 96
    if ($scaleFactor -le 0) { $scaleFactor = 1 }
    $contentWidth = $optionsSurface.ClientSize.Width - $optionsSurface.Padding.Horizontal -
        [math]::Max($optionsCaption.Width + $optionsCaption.Margin.Horizontal, $settingCaption.Width + $settingCaption.Margin.Horizontal)
    $contentWidth = [math]::Max([int](120 * $scaleFactor), $contentWidth)
    # MaximumSize laesst den langen Erinnerungstext bei Platzmangel im
    # Kontrollkaestchen selbst umbrechen, statt rechts abgeschnitten zu werden.
    $reminderCheckBox.MaximumSize = New-Object System.Drawing.Size($contentWidth, 0)
    $flowPreferred = $operationOptionsFlow.GetPreferredSize((New-Object System.Drawing.Size($contentWidth, 0)))
    $reminderPreferred = $reminderCheckBox.GetPreferredSize((New-Object System.Drawing.Size($contentWidth, 0)))
    $optionsRowHeight = [math]::Max([int](34 * $scaleFactor), $flowPreferred.Height + [int](2 * $scaleFactor))
    $settingRowHeight = [math]::Max([int](32 * $scaleFactor), $reminderPreferred.Height + [int](4 * $scaleFactor))
    # Nur bei echten Aenderungen schreiben: Die Hoehenzuweisung loest erneut
    # Resize aus; identische Werte beenden die Rekursion sofort.
    if ([int]$optionsSurface.RowStyles[0].Height -ne $optionsRowHeight) { $optionsSurface.RowStyles[0].Height = $optionsRowHeight }
    if ([int]$optionsSurface.RowStyles[1].Height -ne $settingRowHeight) { $optionsSurface.RowStyles[1].Height = $settingRowHeight }
    $surfaceHeight = $optionsRowHeight + $settingRowHeight + $optionsSurface.Padding.Vertical
    if ($optionsSurface.Height -ne $surfaceHeight) { $optionsSurface.Height = $surfaceHeight }
    if (Test-Path Function:\Update-ContentLayoutHeight) { Update-ContentLayoutHeight }
}
$optionsSurface.Add_Resize({ Update-OptionsSurfaceHeight })

$activitySurface = New-Object System.Windows.Forms.Panel
$activitySurface.BackColor = $surfaceColor
$activitySurface.Size = New-Object System.Drawing.Size(748, 142)
$activitySurface.Margin = New-Object System.Windows.Forms.Padding(16, 4, 16, 4)
$activitySurface.Anchor = 'Top, Left, Right'
$activitySurface.TabIndex = 4
$layoutRoot.Controls.Add($activitySurface, 0, 4)

$statusCaption = New-Object System.Windows.Forms.Label
$statusCaption.Text = "Status:"
$statusCaption.AutoSize = $true
$statusCaption.Font = $captionFont
$statusCaption.Location = New-Object System.Drawing.Point(16, 12)
$statusCaption.BackColor = $surfaceColor
$activitySurface.Controls.Add($statusCaption)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = L "Bereit." "Ready."
$statusLabel.AutoEllipsis = $true
$statusLabel.Location = New-Object System.Drawing.Point(70, 12)
$statusLabel.Size = New-Object System.Drawing.Size(540, 22)
$statusLabel.BackColor = $surfaceColor
$statusLabel.Anchor = "Top, Left, Right"
$statusLabel.AccessibleName = L 'Status' 'Status'
$activitySurface.Controls.Add($statusLabel)

$durationCaption = New-Object System.Windows.Forms.Label
$durationCaption.Text = L "Dauer:" "Elapsed:"
$durationCaption.AutoSize = $true
$durationCaption.Font = $captionFont
$durationCaption.Location = New-Object System.Drawing.Point(618, 12)
$durationCaption.BackColor = $surfaceColor
$durationCaption.Anchor = "Top, Right"
$activitySurface.Controls.Add($durationCaption)

$durationLabel = New-Object System.Windows.Forms.Label
$durationLabel.Text = "--:--"
$durationLabel.Location = New-Object System.Drawing.Point(674, 12)
$durationLabel.Size = New-Object System.Drawing.Size(58, 22)
$durationLabel.TextAlign = 'TopRight'
$durationLabel.BackColor = $surfaceColor
$durationLabel.Anchor = "Top, Right"
$durationLabel.AccessibleName = L 'Dauer' 'Elapsed time'
$activitySurface.Controls.Add($durationLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(16, 42)
$progressBar.Size = New-Object System.Drawing.Size(716, 8)
$progressBar.Anchor = "Top, Left, Right"
$progressBar.Style = "Blocks"
$progressBar.MarqueeAnimationSpeed = 0
$progressBar.AccessibleName = L 'Fortschritt' 'Progress'
$activitySurface.Controls.Add($progressBar)

$resultLabel = New-Object System.Windows.Forms.Label
$resultLabel.Text = L "Ergebnisübersicht:" "Summary:"
$resultLabel.AutoSize = $true
$resultLabel.Font = $captionFont
$resultLabel.Location = New-Object System.Drawing.Point(16, 58)
$resultLabel.BackColor = $surfaceColor
$activitySurface.Controls.Add($resultLabel)

$resultBox = New-Object System.Windows.Forms.TextBox
$resultBox.Location = New-Object System.Drawing.Point(16, 80)
$resultBox.Size = New-Object System.Drawing.Size(716, 48)
$resultBox.Anchor = "Top, Left, Right"
$resultBox.Multiline = $true
$resultBox.ReadOnly = $true
$resultBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$resultBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$resultBox.BackColor = $surfaceColor
# Bewusst fokussierbar: Tastatur- und Screenreader-Nutzer erreichen die
# Ergebnisuebersicht damit direkt (plan.md Arbeitspaket 6).
$resultBox.TabStop = $true
$resultBox.TabIndex = 0
$resultBox.AccessibleName = L 'Ergebnisübersicht' 'Summary'
$script:resultSummary = L "Noch keine Sicherung ausgeführt." "No backup has been run yet."
$resultBox.Text = $script:resultSummary
$activitySurface.Controls.Add($resultBox)

# Scrollen wird erst nach dem expliziten DPI-Durchlauf bewertet. Die benoetigte
# Mindesthoehe stammt ausschliesslich aus den real gelayouteten Tabellenzeilen;
# GetPreferredSize ist bei verschachtelten AutoSize-/Prozent-Layouts in
# .NET-Framework-WinForms nicht stabil genug fuer diese Entscheidung.
function Update-ContentLayoutHeight {
    if (-not $script:dpiLayoutReady -or $script:contentLayoutUpdating -or
        -not $contentHost -or -not $layoutRoot -or $contentHost.ClientSize.Height -le 0) { return }

    $script:contentLayoutUpdating = $true
    try {
        $scaleFactor = $form.CurrentAutoScaleDimensions.Width / 96
        if ($scaleFactor -le 0) { $scaleFactor = 1 }
        # MinimumSize wird unter dem PowerShell/.NET-Framework-Host nicht
        # verlaesslich von PerformAutoScale erfasst; deshalb explizit setzen.
        $folderMinimumHeight = [int][math]::Round(156 * $scaleFactor)
        $folderSurface.MinimumSize = New-Object System.Drawing.Size(0, $folderMinimumHeight)

        # Erst den virtuellen Scrollzustand vollstaendig beseitigen, dann bei
        # der echten Viewportgroesse layouten und reale Row-Heights abfragen.
        $contentHost.AutoScroll = $false
        $contentHost.AutoScrollMinSize = [System.Drawing.Size]::Empty
        $contentHost.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
        $layoutRoot.Height = $contentHost.ClientSize.Height
        $contentHost.PerformLayout()
        $layoutRoot.PerformLayout()

        $rowHeights = @($layoutRoot.GetRowHeights())
        if ($rowHeights.Count -lt 5) { return }
        $currentTotalHeight = ($rowHeights | Measure-Object -Sum).Sum
        $folderMinimumRowHeight = $folderMinimumHeight + $folderSurface.Margin.Vertical
        $minimumContentHeight = [int]($currentTotalHeight - $rowHeights[2] + $folderMinimumRowHeight)

        if ($minimumContentHeight -le $contentHost.ClientSize.Height) {
            # Passt-Fall: hart ohne Scrollen. Die Prozentzeile bekommt exakt
            # den Rest, und ein frueheres DisplayRectangle kann nicht bleiben.
            $layoutRoot.Height = $contentHost.ClientSize.Height
            $contentHost.AutoScroll = $false
        } else {
            $layoutRoot.Height = $minimumContentHeight
            $contentHost.AutoScrollMinSize = New-Object System.Drawing.Size(0, $minimumContentHeight)
            $contentHost.AutoScroll = $true
        }
        $contentHost.PerformLayout()
        $layoutRoot.PerformLayout()
    } finally {
        $script:contentLayoutUpdating = $false
    }
}
$contentHost.Add_SizeChanged({ Update-ContentLayoutHeight })

# Die rechten Kanten von Dauer, Fortschritt und Ergebnis folgen derselben
# 12-Pixel-Innenkante wie Aktualisieren, Keine/Entfernen und Backup loeschen.
# Eine explizite Nachberechnung ist hier verlaesslicher als Anchor, weil das
# Panel erst nach dem Aufbau durch TableLayout und DPI-Skalierung verbreitert
# wird und WinForms sonst die urspruengliche Designbreite beibehalten kann.
function Update-ActivitySurfaceLayout {
    $scaleFactor = $form.CurrentAutoScaleDimensions.Width / 96
    if ($scaleFactor -le 0) { $scaleFactor = 1 }
    $leftInset = [int](16 * $scaleFactor)
    $rightInset = [int](12 * $scaleFactor)
    $gap = [int](12 * $scaleFactor)
    $rightEdge = $activitySurface.ClientSize.Width - $rightInset
    if ($rightEdge -le $leftInset) { return }

    $durationLabel.Left = $rightEdge - $durationLabel.Width
    $durationCaption.Left = $durationLabel.Left - $gap - $durationCaption.Width
    $statusLabel.Width = [math]::Max(40, $durationCaption.Left - $gap - $statusLabel.Left)
    $progressBar.Width = [math]::Max(40, $rightEdge - $progressBar.Left)
    $resultBox.Width = [math]::Max(40, $rightEdge - $resultBox.Left)
}
$activitySurface.Add_Resize({ Update-ActivitySurfaceLayout })

$resultContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$copyResultMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$copyResultMenuItem.Text = L 'Ergebnis kopieren' 'Copy summary'
$copyResultMenuItem.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($resultBox.Text)) {
        try { [System.Windows.Forms.Clipboard]::SetText($resultBox.Text) } catch {}
    }
})
[void]$resultContextMenu.Items.Add($copyResultMenuItem)
$resultBox.ContextMenuStrip = $resultContextMenu

$footerSurface = New-Object System.Windows.Forms.FlowLayoutPanel
$footerSurface.BackColor = $surfaceColor
$footerSurface.AutoSize = $true
$footerSurface.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$footerSurface.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$footerSurface.WrapContents = $true
$footerSurface.Padding = New-Object System.Windows.Forms.Padding(24, 12, 24, 12)
$footerSurface.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$footerSurface.Dock = [System.Windows.Forms.DockStyle]::Bottom
$footerSurface.TabIndex = 5
$form.Controls.Add($footerSurface)
# Das Fill-gedockte Inhalts-Panel muss vorn in der Z-Reihenfolge stehen:
# WinForms dockt Kinder von hinten nach vorn, der Footer reserviert also
# zuerst die Unterkante und der Inhalt erhaelt danach den Rest. Andernfalls
# laege der Inhalt unter dem Footer und seine letzten Zeilen waeren verdeckt.
$contentHost.BringToFront()

$startButton = New-M24Button -Text (L "Sicherung starten" "Start backup") -Width 200 -Height 40 -Kind 'Primary' -Font $footerButtonFont
$startButton.Dock = [System.Windows.Forms.DockStyle]::Fill
$startButton.TabIndex = 0
$primaryActionHost = New-Object System.Windows.Forms.Panel
$primaryActionHost.Size = New-Object System.Drawing.Size(200, 40)
$primaryActionHost.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$primaryActionHost.Controls.Add($startButton)
$footerSurface.Controls.Add($primaryActionHost)
$form.AcceptButton = $startButton

$logButton = New-M24Button -Text (L "Protokoll öffnen" "Open log") -Width 150 -Height 40 -Font $footerButtonFont
$logButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$logButton.Enabled = $false
$logButton.TabIndex = 1
$footerSurface.Controls.Add($logButton)

$destinationButton = New-M24Button -Text (L "Sicherungsordner öffnen" "Open backup folder") -Width 190 -Height 40 -Font $footerButtonFont
$destinationButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$destinationButton.Enabled = $false
$destinationButton.TabIndex = 2
$footerSurface.Controls.Add($destinationButton)

$closeButton = New-M24Button -Text (L "Schließen" "Close") -Width 135 -Height 40 -Font $footerButtonFont
$closeButton.Margin = New-Object System.Windows.Forms.Padding(0)
$closeButton.TabIndex = 3
$footerSurface.Controls.Add($closeButton)

$cancelButton = New-M24Button -Text (L "Sicherung abbrechen" "Cancel backup") -Width 200 -Height 40 -Kind 'Danger' -Font $footerButtonFont
# Der Abbrechen-Button ersetzt den Start-Button an derselben Position und
# muss deshalb auch gleich verankert sein.
$cancelButton.Dock = [System.Windows.Forms.DockStyle]::Fill
$cancelButton.TabIndex = 0
$cancelButton.Visible = $false
$primaryActionHost.Controls.Add($cancelButton)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500

$driveWatchTimer = New-Object System.Windows.Forms.Timer
$driveWatchTimer.Interval = 2500
$driveWatchTimer.Add_Tick({
    if ($script:backupProcess -or $script:pendingEjectDrive -or $script:verificationAsyncResult -or $script:deletionAsyncResult) { return }
    if (-not $form.Visible -or $form.IsDisposed -or -not $form.IsHandleCreated) { return }
    if ($driveCombo.DroppedDown) { return }
    Update-DriveList
})

# Zeigt waehrend des Groessen-Scans laufend neue Ergebnisse an und raeumt den
# Scanner-Runspace nach Abschluss auf. Bleiben Eintraege in der Warteschlange
# zurueck (Wettlauf zwischen Enqueue und Scanner-Ende), startet er neu.
$folderSizeTimer = New-Object System.Windows.Forms.Timer
$folderSizeTimer.Interval = 400
$folderSizeTimer.Add_Tick({
    if ($form.IsDisposed -or -not $form.IsHandleCreated) { $folderSizeTimer.Stop(); return }
    if ($script:folderSizeAsyncResult -and $script:folderSizeAsyncResult.IsCompleted) {
        try {
            [void]$script:folderSizePowerShell.EndInvoke($script:folderSizeAsyncResult)
        } catch {
            Write-M24DiagnosticLog -EventId 'GUI.FolderSizeScan' -Message 'Folder-size scanner runspace failed during completion.' -Exception $_
        }
        foreach ($scanError in @($script:folderSizePowerShell.Streams.Error)) {
            Write-M24DiagnosticLog -EventId 'GUI.FolderSizeScan' -Severity 'Warning' -Message 'Folder-size scanner reported an error.' -Exception $scanError
        }
        try { $script:folderSizePowerShell.Dispose() } catch {}
        $script:folderSizePowerShell = $null
        $script:folderSizeAsyncResult = $null

        # Erfolgreiche Abschlusslaeufe ebenfalls mit dem konkreten Cachezustand
        # dokumentieren. Das erlaubt die Unterscheidung zwischen einem realen
        # Pending-Marker und einer lediglich veralteten Ergebniszeile, ohne den
        # GUI-Runspace interaktiv debuggen zu muessen.
        $folderSizeStates = @()
        for ($itemIndex = 0; $itemIndex -lt $libraryList.Items.Count; $itemIndex++) {
            $sizeItem = $libraryList.Items[$itemIndex]
            $sizeKey = Get-FolderSizeKey ([string]$sizeItem.SizePath)
            $sizeEntry = $script:folderSizeCache[$sizeKey]
            $sizeState = if ($null -eq $sizeEntry) { 'Missing' } elseif ($sizeEntry -is [string]) { [string]$sizeEntry } elseif ($sizeEntry.PSObject.Properties['State']) { [string]$sizeEntry.State } else { 'CompleteLegacy' }
            $folderSizeStates += ('{0}|Checked={1}|State={2}|Path={3}' -f $sizeItem.Name, $libraryList.GetItemChecked($itemIndex), $sizeState, $sizeItem.SizePath)
        }
        Write-M24DiagnosticLog -EventId 'GUI.FolderSizeScanCompleted' -Severity 'Info' -Message 'Folder-size scanner completed.' -Context (('Queue={0}; Items={1}' -f $script:folderSizeQueue.Count, ($folderSizeStates -join '; ')))

        # Nach einem unerwarteten Runspace-Abbruch koennen Marker uebrig sein,
        # deren Queue-Eintrag bereits entnommen wurde. Verwaist ist ein
        # String-Marker aber nur, wenn er nicht mehr in der Queue steht:
        # Eintraege, die waehrend des Scanner-Endes regulaer eingereiht wurden,
        # verarbeitet der Neustart unten unveraendert und ohne Retry-Verbrauch.
        $queuedKeys = @{}
        foreach ($queuedEntry in @($script:folderSizeQueue.ToArray())) { $queuedKeys[[string]$queuedEntry.Key] = $true }
        $stalePendingKeys = @($script:folderSizeCache.Keys | Where-Object { $script:folderSizeCache[$_] -is [string] -and -not $queuedKeys.ContainsKey([string]$_) })
        if ($stalePendingKeys.Count -gt 0) {
            foreach ($staleKey in $stalePendingKeys) {
                if ($script:folderSizeRetriedKeys.ContainsKey($staleKey)) {
                    $script:folderSizeCache[$staleKey] = [pscustomobject]@{ State = 'Failed'; Files = [int64]0; Bytes = [int64]0; Error = 'Folder size scanner aborted repeatedly.' }
                } else {
                    $script:folderSizeRetriedKeys[$staleKey] = $true
                    $script:folderSizeCache.Remove($staleKey)
                }
            }
            # Entfernte Marker werden ueber den normalen Anforderungsweg neu
            # eingereiht; noch wartende Queue-Eintraege bleiben unberuehrt.
            Request-FolderSizeScan -Items @($libraryList.Items)
        }
        if ($script:folderSizeQueue.Count -gt 0) { Start-FolderSizeScanner }
    }
    $libraryList.Invalidate()
    Update-ResultOverview
    if (-not $script:folderSizeAsyncResult -and $script:folderSizeQueue.Count -eq 0) {
        $folderSizeTimer.Stop()
    }
})

$ejectTimer = New-Object System.Windows.Forms.Timer
$ejectTimer.Interval = 3500
$ejectTimer.Add_Tick({
    $ejectTimer.Stop()
    Complete-DelayedAutoEject
})

$verificationTimer = New-Object System.Windows.Forms.Timer
$verificationTimer.Interval = 500
$verificationTimer.Add_Tick({
    if (-not $script:verificationAsyncResult -or -not $script:verificationAsyncResult.IsCompleted) { return }
    $verificationTimer.Stop()
    try {
        $output = @($script:verificationPowerShell.EndInvoke($script:verificationAsyncResult))
        $verification = $output | Select-Object -Last 1
        if ($verification.LogFile -and (Test-Path -LiteralPath ([string]$verification.LogFile) -PathType Leaf)) {
            $script:lastLogFile = [string]$verification.LogFile
            if ($driveCombo.SelectedItem) {
                $verificationDisk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
                if ($verificationDisk) {
                    $verificationCacheKey = "{0}|{1}" -f $verificationDisk.DeviceID, (Get-NormalizedVolumeSerial -Disk $verificationDisk)
                    $script:artifactCache[$verificationCacheKey] = [pscustomobject]@{ DestinationExists = $true; LogFile = $script:lastLogFile }
                }
            }
            $logButton.Enabled = $true
            $historyButton.Enabled = $true
        }
        $gb = [math]::Round(([double]$verification.Bytes / 1GB), 2)
        if ($verification.Cancelled) {
            $statusLabel.Text = L 'Backup-Prüfung abgebrochen.' 'Backup verification cancelled.'
            $resultBox.Text = L 'Die Prüfsummenprüfung wurde auf Wunsch beendet.' 'Checksum verification was cancelled by request.'
        } elseif ([int]$verification.ErrorCount -eq 0) {
            if ($verification.Initialized) {
                $statusLabel.Text = L 'Prüfsummen-Manifest erstellt.' 'Checksum manifest created.'
                $resultBox.Text = (L 'Prüfsummen für {0} Dateien ({1:N2} GB) wurden erstellt.' 'Checksums were created for {0} files ({1:N2} GB).') -f $verification.Files, $gb
            } else {
                $statusLabel.Text = L 'Backup erfolgreich geprüft.' 'Backup verified successfully.'
                $resultBox.Text = (L '{0} Dateien ({1:N2} GB) stimmen mit ihren SHA-256-Prüfsummen überein.' '{0} files ({1:N2} GB) match their SHA-256 checksums.') -f $verification.Files, $gb
            }
            Show-CompletionNotification -Title (L 'Backup geprüft' 'Backup verified') -Text $resultBox.Text -Icon Info
        } elseif ($verification.UnexpectedError) {
            $statusLabel.Text = L 'Backup-Prüfung fehlgeschlagen.' 'Backup verification failed.'
            $resultBox.Text = L 'Die Backup-Prüfung konnte nicht abgeschlossen werden. Details stehen im Protokoll.' 'Backup verification could not be completed. See the log for details.'
            [System.Windows.Forms.MessageBox]::Show(([string]$verification.UnexpectedError), $form.Text, 'OK', 'Error') | Out-Null
        } else {
            $statusLabel.Text = L 'Backup-Prüfung mit Integritätsfehlern beendet.' 'Backup verification found integrity errors.'
            $resultBox.Text = (L '{0} Integritätsfehler gefunden.' '{0} integrity errors found.') -f $verification.ErrorCount
            [System.Windows.Forms.MessageBox]::Show(($verification.Errors -join [Environment]::NewLine), $form.Text, 'OK', 'Warning') | Out-Null
        }
    } catch {
        $verificationError = $_
        Write-M24DiagnosticLog -EventId 'GUI.Verification' -Message 'Checksum verification failed in the GUI completion handler.' -Exception $verificationError
        $statusLabel.Text = L 'Backup-Prüfung fehlgeschlagen.' 'Backup verification failed.'
        [System.Windows.Forms.MessageBox]::Show($verificationError.Exception.Message, $form.Text, 'OK', 'Error') | Out-Null
    } finally {
        if ($script:verificationPowerShell) { $script:verificationPowerShell.Dispose() }
        $script:verificationPowerShell = $null
        $script:verificationAsyncResult = $null
        if ($script:verificationCancelFile) { Remove-Item -LiteralPath $script:verificationCancelFile -Force -ErrorAction SilentlyContinue }
        $script:verificationCancelFile = $null
        Stop-BusyProgress
        $closeButton.Visible = $true
        $startButton.Visible = $true
        $cancelButton.Visible = $false
        $form.AcceptButton = $closeButton
        Set-VerificationControlsEnabled -Enabled $true
    }
})

$deletionTimer = New-Object System.Windows.Forms.Timer
$deletionTimer.Interval = 350
$deletionTimer.Add_Tick({
    if (-not $script:deletionAsyncResult -or -not $script:deletionAsyncResult.IsCompleted) { return }
    $deletionTimer.Stop()
    try {
        $output = @($script:deletionPowerShell.EndInvoke($script:deletionAsyncResult))
        $deleted = $output | Select-Object -Last 1
        if (-not $deleted -or -not $deleted.BackupRoot) { throw (L 'Der Löschvorgang lieferte kein gültiges Ergebnis.' 'The deletion operation returned no valid result.') }

        $settingsWarning = $null
        if ($script:deletionDisk -and (Test-IsKnownBackupDrive -Disk $script:deletionDisk)) {
            try {
                Clear-KnownBackupDrive
            } catch {
                $settingsWarning = L ' Das gespeicherte bekannte Laufwerk konnte nicht zurückgesetzt werden.' ' The remembered backup drive could not be reset.'
                $script:knownDrive = $null
                $script:settings.KnownBackupDrive = $null
            }
        }
        $script:artifactCache.Clear()
        $freedSize = Format-BackupDeletionSize $script:deletionInfo.Bytes
        $deviceWarning = ''
        if ([int]$deleted.IgnoredDeviceFiles -gt 0) {
            $deviceWarningGerman = " {0} nicht löschbare(s) Windows-Geräteartefakt(e), beispielsweise NUL, wurde(n) ignoriert; dadurch kann ein leerer Restordner bestehen bleiben."
            $deviceWarningEnglish = " {0} undeletable Windows device-name artifact(s), such as NUL, were ignored; an otherwise empty residual folder may remain."
            $deviceWarning = (L $deviceWarningGerman $deviceWarningEnglish) -f [int]$deleted.IgnoredDeviceFiles
        }
        $script:resultSummary = ((L "Backup-Inhalte erfolgreich gelöscht: {0} ({1} freigegeben)." "Backup contents deleted successfully: {0} ({1} freed).") -f $deleted.BackupRoot, $freedSize) + $deviceWarning + $settingsWarning
        $statusLabel.Text = if ([int]$deleted.IgnoredDeviceFiles -gt 0) {
            L 'Backup gelöscht; nicht löschbares Geräteartefakt wurde ignoriert.' 'Backup deleted; an undeletable device-name artifact was ignored.'
        } else {
            L 'Backup erfolgreich gelöscht.' 'Backup deleted successfully.'
        }
        Reset-ProgressIndicator -Maximum 1
        Update-DriveList -Force
        Update-BackupArtifactActions
        Update-BackupHealth
        Update-LibraryList
        [System.Windows.Forms.MessageBox]::Show($script:resultSummary, $form.Text, 'OK', 'Information') | Out-Null
    } catch {
        $deletionError = $_
        Write-M24DiagnosticLog -EventId 'GUI.Deletion' -Message 'Backup deletion failed in the GUI completion handler.' -Exception $deletionError
        $statusLabel.Text = L 'Backup konnte nicht gelöscht werden.' 'Backup could not be deleted.'
        [System.Windows.Forms.MessageBox]::Show(
            ((L "Das Backup wurde nicht vollständig gelöscht:`r`n{0}" "The backup was not completely deleted:`r`n{0}") -f $deletionError.Exception.Message),
            $form.Text, 'OK', 'Error') | Out-Null
    } finally {
        if ($script:deletionPowerShell) { $script:deletionPowerShell.Dispose() }
        $script:deletionPowerShell = $null
        $script:deletionAsyncResult = $null
        $script:deletionInfo = $null
        $script:deletionDisk = $null
        Stop-BusyProgress
        $form.UseWaitCursor = $false
        Set-VerificationControlsEnabled -Enabled $true
        Update-ResultOverview
    }
})

function Set-VerificationControlsEnabled {
    param([bool]$Enabled)
    foreach ($control in @($startButton, $driveCombo, $backupSourceCombo, $restoreProfileRadio, $restoreFolderRadio, $restoreFolderButton, $refreshButton, $backupRadio, $restoreRadio, $libraryList, $allButton, $noneButton, $historyButton, $logButton, $destinationButton, $deleteBackupButton, $closeButton)) {
        $control.Enabled = $Enabled
    }
    if ($Enabled) {
        Update-BackupArtifactActions
        Update-BackupOptionState
        Update-SelectionState
    } else {
        $addFolderButton.Enabled = $false
        $removeFolderButton.Enabled = $false
        $dryRunCheckBox.Enabled = $false
        $ejectCheckBox.Enabled = $false
        $checksumCheckBox.Enabled = $false
        $superFastCheckBox.Enabled = $false
        $verifyButton.Enabled = $false
        $deleteBackupButton.Enabled = $false
    }
}

function Update-ResultOverview {
    # Ergaenzt die Ergebnisuebersicht im Leerlauf um die aktuelle Auswahl.
    # Waehrend eines laufenden Vorgangs gehoert die Anzeige dem Fortschritt.
    if ($script:backupProcess) { return }
    $count = $libraryList.CheckedItems.Count
    # Gesamtgroesse der angehakten Ordner anfuegen, sobald der Hintergrund-
    # Scan Ergebnisse liefert; solange Messungen ausstehen, wird das kenntlich
    # gemacht statt eine zu niedrige Zwischensumme zu zeigen.
    $sizeSuffix = ''
    if ($count -gt 0) {
        $total = Get-CheckedFolderSizeTotal
        if ($total.Pending) {
            $sizeSuffix = L ' (Gesamtgröße wird ermittelt …)' ' (calculating total size …)'
        } elseif ($total.Failed) {
            $sizeSuffix = if ($total.Known) {
                (L ' (Gesamtgröße unvollständig: {0}, {1})' ' (partial total: {0}, {1})') -f (Format-FolderFileCountText -Files $total.Files), (Format-FolderSizeText -Bytes $total.Bytes)
            } else {
                L ' (Gesamtgröße nicht ermittelbar)' ' (total size unavailable)'
            }
        } elseif ($total.Known) {
            $sizeSuffix = ' ({0}, {1})' -f (Format-FolderFileCountText -Files $total.Files), (Format-FolderSizeText -Bytes $total.Bytes)
        }
    }
    $selectionLine = if ($script:isGerman) {
        if ($count -eq 1) { "1 Ordner ausgewählt$sizeSuffix." } else { "$count Ordner ausgewählt$sizeSuffix." }
    } else {
        if ($count -eq 1) { "1 folder selected$sizeSuffix." } else { "$count folders selected$sizeSuffix." }
    }
    $resultBox.Text = "{0}{1}{2}" -f $script:resultSummary, [Environment]::NewLine, $selectionLine
}

function Add-ResultLine {
    param([string]$Text)

    if (-not $Text) { return }
    if ($script:backupProcess) {
        $resultBox.Text = "{0}{1}{2}" -f $resultBox.Text, [Environment]::NewLine, $Text
        $script:resultSummary = $resultBox.Text
    } else {
        $script:resultSummary = "{0}{1}{2}" -f $script:resultSummary, [Environment]::NewLine, $Text
        Update-ResultOverview
    }
}

function Request-DelayedAutoEject {
    param([string]$Drive)

    if (-not $Drive) { return }
    $script:pendingEjectDrive = $Drive
    $script:ejectAttemptsRemaining = 3
    $statusLabel.Text = L "Sicherung erfolgreich. Automatischer Auswurf wird vorbereitet ..." "Backup completed. Preparing automatic eject ..."
    Add-ResultLine (L "Automatischer Auswurf wird in wenigen Sekunden versucht." "Automatic eject will be attempted in a few seconds.")
    $startButton.Enabled = $false
    $refreshButton.Enabled = $false
    $driveCombo.Enabled = $false
    $backupSourceCombo.Enabled = $false
    $restoreProfileRadio.Enabled = $false
    $restoreFolderRadio.Enabled = $false
    $restoreFolderButton.Enabled = $false
    $backupRadio.Enabled = $false
    $restoreRadio.Enabled = $false
    $libraryList.Enabled = $false
    $allButton.Enabled = $false
    $noneButton.Enabled = $false
    $deleteBackupButton.Enabled = $false
    Update-BackupOptionState
    $ejectTimer.Stop()
    $ejectTimer.Start()
}

function Complete-DelayedAutoEject {
    if (-not $script:pendingEjectDrive) { return }

    $driveToEject = $script:pendingEjectDrive
    $statusLabel.Text = L "Laufwerk wird sicher ausgeworfen ..." "Safely ejecting drive ..."

    $ejectResult = Dismount-BackupDriveSafely -Drive $driveToEject
    if ($ejectResult.Success) {
        $script:pendingEjectDrive = $null
        $script:ejectAttemptsRemaining = 0
        $statusLabel.Text = L "Sicherung erfolgreich abgeschlossen. Laufwerk kann entfernt werden." "Backup completed successfully. The drive can be removed."
        Add-ResultLine $ejectResult.Message
        $script:suppressArtifactRetarget = $true
        try { Update-DriveList } finally { $script:suppressArtifactRetarget = $false }
        $script:lastDestination = $null
        $script:lastLogDir = $null
        $script:lastLogFile = $null
        $logButton.Enabled = $false
        $destinationButton.Enabled = $false
        $historyButton.Enabled = $false
        $verifyButton.Enabled = $false
        $deleteBackupButton.Enabled = $false
    } else {
        $script:ejectAttemptsRemaining--
        if ($script:ejectAttemptsRemaining -gt 0) {
            $statusLabel.Text = L "Laufwerk ist noch beschäftigt. Auswurf wird erneut versucht ..." "Drive is still busy. Retrying eject ..."
            Add-ResultLine (L "Auswurf war noch nicht möglich. Neuer Versuch folgt." "Eject was not possible yet. Retrying.")
            $ejectTimer.Start()
            return
        }
        $script:pendingEjectDrive = $null
        $statusLabel.Text = L "Sicherung erfolgreich, Auswurf konnte nicht abgeschlossen werden." "Backup succeeded, but eject could not be completed."
        Add-ResultLine (L "Auswurf fehlgeschlagen. Bitte Laufwerk manuell sicher entfernen." "Eject failed. Safely remove the drive manually.")
        if (-not $script:ejectDialogOpen) {
            $script:ejectDialogOpen = $true
            try {
                [System.Windows.Forms.MessageBox]::Show(
                    ((L "Die Sicherung war erfolgreich, aber das Laufwerk konnte nicht automatisch ausgeworfen werden:`r`n{0}" "The backup succeeded, but the drive could not be ejected automatically:`r`n{0}") -f $ejectResult.Message),
                    $form.Text,
                    'OK',
                    'Warning'
                ) | Out-Null
            } finally {
                $script:ejectDialogOpen = $false
            }
        }
    }
    $refreshButton.Enabled = $true
    $driveCombo.Enabled = $true
    $backupSourceCombo.Enabled = $true
    $restoreFolderRadio.Enabled = $true
    $restoreFolderButton.Enabled = $true
    $backupRadio.Enabled = $true
    $restoreRadio.Enabled = $true
    $libraryList.Enabled = $true
    $allButton.Enabled = $true
    $noneButton.Enabled = $true
    Update-SelectionState
    Update-BackupOptionState
}

function Update-SelectionState {
    $count = $libraryList.CheckedItems.Count
    $restoreReady = -not $restoreRadio.Checked -or (
        $null -ne (Get-SelectedBackupInventoryItem) -and
        ($restoreProfileRadio.Checked -or ($restoreFolderRadio.Checked -and -not [string]::IsNullOrWhiteSpace($script:restoreTargetFolder)))
    )
    $startButton.Enabled = ($count -gt 0 -and $null -ne $driveCombo.SelectedItem -and $restoreReady -and -not $script:backupProcess -and -not $script:pendingEjectDrive -and -not $script:verificationAsyncResult)
    $selectedItem = $libraryList.SelectedItem
    $removeFolderButton.Enabled = $backupRadio.Checked -and $selectedItem -and
        $selectedItem.PSObject.Properties['IsCustom'] -and $selectedItem.IsCustom -and -not $script:backupProcess -and -not $script:pendingEjectDrive -and -not $script:verificationAsyncResult
    if ($backupRadio.Checked) { Update-BackupSelectionSnapshot }
    Update-ResultOverview
}

function Update-BackupSelectionSnapshot {
    param([switch]$CaptureCurrentList)
    if (-not $backupRadio.Checked -and -not $CaptureCurrentList) { return }
    Sync-FolderCheckState
    $selectedNames = @($libraryList.CheckedItems | ForEach-Object { [string]$_.Name })
    $savedCustomFolders = @($script:customFolders | ForEach-Object {
        [ordered]@{ Name = [string]$_.Name; Path = [string]$_.Path; Checked = $selectedNames -contains [string]$_.Name }
    })
    $script:backupSelectionSnapshot = [ordered]@{ SelectedNames = $selectedNames; CustomFolders = $savedCustomFolders }
}

function Update-BackupOptionState {
    # Der Guard verhindert Ereignis-Rekursion: Diese Funktion setzt selbst
    # Checkbox-Zustaende und wuerde sich sonst ueber CheckedChanged erneut rufen.
    if ($script:optionStateUpdating) { return }
    $script:optionStateUpdating = $true
    try {
        $isBackup = $backupRadio.Checked
        $isInternalDrive = $false
        if ($driveCombo.SelectedItem) {
            $selectedDisk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
            $isInternalDrive = $selectedDisk -and $selectedDisk.M24IsInternal
        }
        $isIdle = -not $script:backupProcess -and -not $script:pendingEjectDrive -and
            -not $script:verificationAsyncResult -and -not $script:deletionAsyncResult

        if (-not $isBackup) {
            $dryRunCheckBox.Checked = $false
            $superFastCheckBox.Checked = $false
        }

        # Dry-Run und Superschnell schliessen sich gegenseitig aus: Solange die
        # eine Option angehakt ist, bleibt die andere deaktiviert.
        $dryRunCheckBox.Enabled = $isBackup -and $isIdle -and -not $superFastCheckBox.Checked
        $superFastCheckBox.Enabled = $isBackup -and $isIdle -and -not $dryRunCheckBox.Checked

        $ejectCheckBox.Enabled = $isBackup -and -not $dryRunCheckBox.Checked -and -not $isInternalDrive -and $isIdle
        if (-not $isBackup -or $dryRunCheckBox.Checked -or $isInternalDrive) { $ejectCheckBox.Checked = $false }

        # Superschnell erzwingt abgewaehlte Pruefsummen; der vorige Haken wird
        # beim Abschalten wiederhergestellt, damit das Ausprobieren der Option
        # keine stille dauerhafte Aenderung hinterlaesst.
        if ($superFastCheckBox.Checked) {
            if ($null -eq $script:checksumBeforeSuperFast) { $script:checksumBeforeSuperFast = $checksumCheckBox.Checked }
            $checksumCheckBox.Checked = $false
        } elseif ($null -ne $script:checksumBeforeSuperFast) {
            $checksumCheckBox.Checked = [bool]$script:checksumBeforeSuperFast
            $script:checksumBeforeSuperFast = $null
        }
        $checksumCheckBox.Enabled = $isBackup -and -not $dryRunCheckBox.Checked -and -not $superFastCheckBox.Checked -and $isIdle

        $addFolderButton.Enabled = $isBackup -and $isIdle
        $removeFolderButton.Visible = $isBackup
        $addFolderButton.Visible = $isBackup
    } finally {
        $script:optionStateUpdating = $false
    }
    Update-RestoreTargetState
    Update-SelectionState
}

function Update-LibraryList {
    $libraryList.Items.Clear()
    $items = @()
    if ($restoreRadio.Checked) {
        $selectedBackup = Get-SelectedBackupInventoryItem
        if ($selectedBackup) {
            $backupRoot = [string]$selectedBackup.RootPath
            $items += @(Get-LibraryDefinitions -IncludeMissing | Where-Object { Test-Path -LiteralPath (Join-Path $backupRoot $_.Name) -PathType Container } | ForEach-Object {
                $checked = if ($script:folderCheckStates.ContainsKey([string]$_.Name)) { [bool]$script:folderCheckStates[[string]$_.Name] } else { $true }
                New-FolderListItem -Name $_.Name -DisplayName (Get-M24FolderDisplayName $_.Name $script:isGerman) -Path $_.Path -IsCustom $false -Checked $checked -SizePath (Join-Path $backupRoot ([string]$_.Name))
            })
            $items += @(Get-RestoreCustomFolders -BackupRoot $backupRoot)
            # Auch ohne lesbare _Ordner.json muessen vorhandene fremde
            # Datenordner beim sicheren Kopieren auswählbar bleiben.
            $knownNames = @($items | ForEach-Object { [string]$_.Name })
            $items += @(Get-ChildItem -LiteralPath $backupRoot -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object {
                    -not $_.Name.StartsWith('_') -and
                    $knownNames -notcontains $_.Name -and
                    ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0
                } |
                ForEach-Object {
                    New-FolderListItem -Name $_.Name -DisplayName $_.Name -Path $null -IsCustom $true -Checked $true -SizePath $_.FullName
                })
        }
        $titleLabel.Text = L "Dateien wiederherstellen" "Restore files"
        $descriptionLabel.Text = L "Neuere lokale Dateien bleiben erhalten; es wird nichts gelöscht." "Newer local files are kept; nothing is deleted."
        $driveLabel.Text = L "Sicherungslaufwerk:" "Backup drive:"
        $libraryLabel.Text = L "Diese Ordner sind in der Sicherung verfügbar:" "These folders are available in the backup:"
        $startButton.Text = L "Wiederherstellung prüfen" "Review restore"
    } else {
        $items += @(Get-LibraryDefinitions | ForEach-Object {
            $checked = if ($script:folderCheckStates.ContainsKey([string]$_.Name)) { [bool]$script:folderCheckStates[[string]$_.Name] } else { $true }
            New-FolderListItem -Name $_.Name -DisplayName (Get-M24FolderDisplayName $_.Name $script:isGerman) -Path $_.Path -IsCustom $false -Checked $checked
        })
        $items += @($script:customFolders)
        $titleLabel.Text = L "Dateien sichern" "Back up files"
        $descriptionLabel.Text = L "Wählen Sie Ziel und Ordner. Vorhandene Dateien werden nicht gelöscht." "Choose a destination and folders. Existing files are not deleted."
        $driveLabel.Text = L "Ziellaufwerk:" "Destination drive:"
        $libraryLabel.Text = L "Diese Ordner werden gesichert:" "These folders will be backed up:"
        $startButton.Text = L "Sicherung starten" "Start backup"
    }
    foreach ($item in $items) {
        [void]$libraryList.Items.Add($item, [bool]$item.Checked)
    }
    Request-FolderSizeScan -Items $items
    Update-BackupOptionState
    Update-RestoreTargetState
    Update-SelectionState
}

$allButton.Add_Click({
    for ($i = 0; $i -lt $libraryList.Items.Count; $i++) { $libraryList.SetItemChecked($i, $true) }
    Update-SelectionState
})

$noneButton.Add_Click({
    for ($i = 0; $i -lt $libraryList.Items.Count; $i++) { $libraryList.SetItemChecked($i, $false) }
    Update-SelectionState
})

$addFolderButton.Add_Click({
    Update-BackupSelectionSnapshot
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = L "Weiteren Ordner für die Sicherung auswählen" "Select another folder to back up"
    $dialog.ShowNewFolderButton = $false
    try {
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $selectedPath = [System.IO.Path]::GetFullPath($dialog.SelectedPath).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $selectedPath -PathType Container)) {
            [System.Windows.Forms.MessageBox]::Show((L "Der ausgewählte Ordner wurde nicht gefunden." "The selected folder was not found."), $form.Text, "OK", "Warning") | Out-Null
            return
        }

        $profilePath = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
        if ($selectedPath.Equals($profilePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            [System.Windows.Forms.MessageBox]::Show((L "Das gesamte Benutzerprofil kann nicht als Zusatzordner ausgewählt werden." "The whole user profile cannot be selected as an additional folder."), $form.Text, "OK", "Warning") | Out-Null
            return
        }

        $existingFolders = @()
        $existingFolders += @(Get-LibraryDefinitions | ForEach-Object { $_.Path })
        $existingFolders += @($script:customFolders | ForEach-Object { $_.Path })
        $existingFolders += @(Get-ExistingCustomFolderMetadataForSelectedDrive | ForEach-Object { $_.OriginalPath })
        foreach ($existingPath in @($existingFolders | Where-Object { $_ })) {
            if (Test-IsSameOrNestedPath -FirstPath $selectedPath -SecondPath $existingPath) {
                [System.Windows.Forms.MessageBox]::Show((L "Der ausgewählte Ordner ist bereits enthalten oder überschneidet sich mit einem vorhandenen Eintrag." "The selected folder is already included or overlaps an existing entry."), $form.Text, "OK", "Warning") | Out-Null
                return
            }
        }

        $name = Get-SafeCustomFolderName -Path $selectedPath
        $displayName = "{0} ({1})" -f $name, $selectedPath
        $script:customFolders += (New-FolderListItem -Name $name -DisplayName $displayName -Path $selectedPath -IsCustom $true -Checked $true)
        Update-LibraryList
    } finally {
        $dialog.Dispose()
    }
})

$removeFolderButton.Add_Click({
    $selectedItem = $libraryList.SelectedItem
    if (-not $selectedItem -or -not $selectedItem.PSObject.Properties['IsCustom'] -or -not $selectedItem.IsCustom) { return }
    $script:customFolders = @($script:customFolders | Where-Object { $_.Name -ne $selectedItem.Name })
    Update-LibraryList
})

$libraryList.Add_ItemCheck({
    # Beim initialen Befüllen existiert das Fensterhandle noch nicht. In diesem
    # Fall aktualisiert Update-LibraryList den Zustand nach dem Befüllen selbst.
    if ($form.IsHandleCreated -and -not $form.IsDisposed) {
        $form.BeginInvoke([Action]{ Update-SelectionState }) | Out-Null
    }
})

$libraryList.Add_SelectedIndexChanged({ Update-SelectionState })

function Get-PhysicalDriveConnectionInfo {
    param($LogicalDisk)

    $busType = $null
    $volumeGuid = ''
    $diskUniqueId = ''
    $diskSerialNumber = ''
    try {
        $driveLetter = ([string]$LogicalDisk.DeviceID).TrimEnd(':', '\')
        if ($driveLetter -match '^[A-Za-z]$') {
            $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop | Select-Object -First 1
            $storageDisk = $partition | Get-Disk -ErrorAction Stop | Select-Object -First 1
            if ($storageDisk) {
                $busType = [string]$storageDisk.BusType
                $diskUniqueId = [string]$storageDisk.UniqueId
                $diskSerialNumber = [string]$storageDisk.SerialNumber
            }
            $volumeGuid = @($partition.AccessPaths | Where-Object { $_ -match '^\\\\\?\\Volume\{[0-9A-Fa-f-]+\}\\$' } | Select-Object -First 1)
            if ($volumeGuid.Count) { $volumeGuid = [string]$volumeGuid[0] } else { $volumeGuid = '' }
        }
    } catch {
        # Die GUI bleibt auch auf Systemen ohne Storage-Cmdlets nutzbar. Ohne
        # physischen Bus-Typ wird ein Fixed Disk bewusst nicht als intern
        # behauptet und deshalb auch keine falsche Warnung angezeigt.
    }
    $connection = Get-M24DriveConnectionInfo -DriveType ([int]$LogicalDisk.DriveType) -BusType $busType
    return [pscustomobject]@{
        BusType = $connection.BusType
        ConnectionKind = $connection.ConnectionKind
        IsExternal = $connection.IsExternal
        IsInternal = $connection.IsInternal
        CanEject = $connection.CanEject
        VolumeGuid = $volumeGuid
        DiskUniqueId = $diskUniqueId.Trim()
        DiskSerialNumber = $diskSerialNumber.Trim()
    }
}

function Update-DriveList {
    param([switch]$Force)

    # The CIM call can legitimately take several seconds. Run only that
    # blocking query in a background runspace. During startup the UI is pumped
    # so the 400 ms splash threshold is honored. Once the main window is shown,
    # waiting deliberately remains briefly blocking to prevent interaction with
    # a partially refreshed drive state. The guard prevents re-entry through a
    # timer or another Refresh click.
    if ($script:driveDiscoveryActive) { return }
    $script:driveDiscoveryActive = $true

    # Waehrend eines aktiven Retry-Backoffs nach einem Erkennungsfehler wird
    # nur automatisch uebersprungen; eine ausdrueckliche Aktualisierung
    # (-Force) fragt immer sofort ab.
    if (-not $Force -and [DateTime]::UtcNow -lt $script:driveRetryAfterUtc) {
        $script:driveDiscoveryActive = $false
        return
    }

    $systemDrive = $env:SystemDrive
    $selectedDeviceId = $null
    if ($driveCombo.SelectedItem) {
        $selectedDisk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
        if ($selectedDisk) { $selectedDeviceId = [string]$selectedDisk.DeviceID }
    }

    try {
        # OperationTimeoutSec begrenzt eine haengende WMI/CIM-Abfrage, damit
        # der GUI-Thread nicht unbegrenzt blockiert.
        $driveProbe = [powershell]::Create()
        try {
            [void]$driveProbe.AddScript(@'
param($SystemDrive)
Get-CimInstance Win32_LogicalDisk -OperationTimeoutSec 8 -ErrorAction Stop |
    Where-Object { $_.DriveType -in 2, 3 -and $_.DeviceID -ne $SystemDrive -and $_.Size -gt 0 } |
    Sort-Object DriveType, DeviceID
'@).AddArgument($systemDrive)
            $driveProbeResult = $driveProbe.BeginInvoke()
            while (-not $driveProbeResult.IsCompleted) {
                if ($script:mainWindowShown) {
                    # Nach dem Fensterstart wird bewusst ohne DoEvents gewartet:
                    # Eine Nachrichtenpumpe mitten in der Laufwerkssuche wuerde
                    # Klicks (z. B. "Sicherung starten") in einen halb
                    # aktualisierten Zustand einschleusen. Das kurze Blockieren
                    # entspricht dem bisherigen Verhalten.
                    [void]$driveProbeResult.AsyncWaitHandle.WaitOne(250)
                } else {
                    # Startphase: Statusaktualisierung pumpt die Nachrichten-
                    # schleife und laesst den Splash nach Ueberschreiten der
                    # 400-ms-Schwelle zuverlaessig erscheinen, auch wenn die
                    # CIM-Abfrage bis zu ihrem 8-Sekunden-Timeout haengt.
                    Set-StartupSplashStatus (L 'Sicherungslaufwerke werden geprüft ...' 'Checking backup drives ...')
                    [System.Threading.Thread]::Sleep(40)
                }
            }
            $drives = @($driveProbe.EndInvoke($driveProbeResult))
            if ($driveProbe.HadErrors -and $driveProbe.Streams.Error.Count -gt 0) {
                throw $driveProbe.Streams.Error[0]
            }
        } finally {
            if ($driveProbe) { $driveProbe.Dispose() }
        }

        # Reset direkt nach der erfolgreichen CIM-Abfrage - noch vor dem
        # Early-Return bei unveraendertem Snapshot, der ihn sonst ueberspringen
        # wuerde.
        $script:driveRetryAfterUtc = [DateTime]::MinValue

        $knownDriveSnapshot = if ($script:knownDrive) { $script:knownDrive | ConvertTo-Json -Compress -Depth 3 } else { '' }
        $logicalSnapshot = @($drives | ForEach-Object {
            "{0}|{1}|{2}|{3}|{4}|{5}" -f $_.DeviceID, $_.DriveType, $_.Size, $_.VolumeSerialNumber, $_.VolumeName, $_.FileSystem
        }) -join "`n"
        $logicalSnapshot = "{0}`n{1}" -f $knownDriveSnapshot, $logicalSnapshot
        if (-not $Force -and $script:driveLogicalSnapshot -eq $logicalSnapshot) { return }

        foreach ($disk in $drives) {
            Set-StartupSplashStatus ((L 'Laufwerk {0} wird geprüft ...' 'Checking drive {0} ...') -f $disk.DeviceID)
            $connection = Get-PhysicalDriveConnectionInfo -LogicalDisk $disk
            $disk | Add-Member -NotePropertyName M24BusType -NotePropertyValue $connection.BusType -Force
            $disk | Add-Member -NotePropertyName M24ConnectionKind -NotePropertyValue $connection.ConnectionKind -Force
            $disk | Add-Member -NotePropertyName M24IsExternal -NotePropertyValue $connection.IsExternal -Force
            $disk | Add-Member -NotePropertyName M24IsInternal -NotePropertyValue $connection.IsInternal -Force
            $disk | Add-Member -NotePropertyName M24CanEject -NotePropertyValue $connection.CanEject -Force
            $disk | Add-Member -NotePropertyName M24VolumeGuid -NotePropertyValue $connection.VolumeGuid -Force
            $disk | Add-Member -NotePropertyName M24DiskUniqueId -NotePropertyValue $connection.DiskUniqueId -Force
            $disk | Add-Member -NotePropertyName M24DiskSerialNumber -NotePropertyValue $connection.DiskSerialNumber -Force
        }

        $currentSnapshot = @($drives | ForEach-Object {
            "{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}" -f $_.DeviceID, $_.DriveType, $_.Size, $_.VolumeSerialNumber, $_.VolumeName, $_.FileSystem, $_.M24VolumeGuid, $_.M24DiskUniqueId
        }) -join "`n"
        $currentSnapshot = "{0}`n{1}" -f $knownDriveSnapshot, $currentSnapshot

        $script:driveLogicalSnapshot = $logicalSnapshot
        if (-not $Force -and $script:driveSnapshot -eq $currentSnapshot) { return }

        $knownCandidates = @()
        foreach ($disk in $drives) {
            $candidateFingerprint = [pscustomobject]@{
                VolumeGuid = [string]$disk.M24VolumeGuid
                VolumeSerialNumber = Get-NormalizedVolumeSerial -Disk $disk
                DiskUniqueId = [string]$disk.M24DiskUniqueId
                DiskSerialNumber = [string]$disk.M24DiskSerialNumber
                SizeBytes = [int64]$disk.Size
                FileSystem = [string]$disk.FileSystem
            }
            $match = Compare-M24DriveFingerprint -Known $script:knownDrive -Candidate $candidateFingerprint
            $disk | Add-Member -NotePropertyName M24KnownMatchConfidence -NotePropertyValue $match.Confidence -Force
            $disk | Add-Member -NotePropertyName M24KnownMatchReason -NotePropertyValue $match.Reason -Force
            if ($match.IsMatch) { $knownCandidates += $disk }
        }
        $knownMatchIsUnique = $knownCandidates.Count -eq 1
        foreach ($disk in $drives) {
            $isKnown = $knownMatchIsUnique -and $knownCandidates[0].DeviceID -eq $disk.DeviceID
            $disk | Add-Member -NotePropertyName M24IsKnownBackupDrive -NotePropertyValue $isKnown -Force
            $disk | Add-Member -NotePropertyName M24KnownMatchAmbiguous -NotePropertyValue ($knownCandidates.Count -gt 1) -Force
        }

        $previousDeviceIds = @($script:driveDeviceIds)
        $currentDeviceIds = @($drives | ForEach-Object { [string]$_.DeviceID })

        $driveCombo.Items.Clear()
        $script:driveMap.Clear()
        $script:driveSnapshot = $currentSnapshot
        $script:driveDeviceIds = $currentDeviceIds

        $preferredIndex = -1
        $backupIndex = -1
        $newBackupIndex = -1
        $selectedIndex = -1
        $selectedHasBackup = $false
        foreach ($disk in $drives) {
            Set-StartupSplashStatus ((L 'Sicherungsstatus auf {0} wird geladen ...' 'Loading backup status on {0} ...') -f $disk.DeviceID)
            $label = if ($disk.VolumeName) { $disk.VolumeName } else { L "ohne Namen" "unnamed" }
            $type = switch ($disk.M24ConnectionKind) {
                'Usb' { L "Externes USB-Laufwerk" "External USB drive" }
                'External' { L "Externes Laufwerk" "External drive" }
                'Removable' { L "Wechseldatenträger" "Removable drive" }
                'Internal' { L "Internes Laufwerk" "Internal drive" }
                default { L "Lokaler Datenträger (Verbindung unbekannt)" "Local drive (connection unknown)" }
            }
            $freeGb = [math]::Round($disk.FreeSpace / 1GB, 1)
            $display = "{0}  -  {1}  ({2:N1} GB frei, {3})" -f $disk.DeviceID, $label, $freeGb, $type
            $isKnownBackupDrive = Test-IsKnownBackupDrive -Disk $disk
            $hasCurrentProfileBackup = Test-DriveHasCurrentProfileBackup -Disk $disk
            if ($isKnownBackupDrive) {
                $display = "★ {0}" -f $display
                $preferredIndex = $driveCombo.Items.Count
                if ($disk.M24KnownMatchConfidence -eq 'Legacy') {
                    $display = "{0} ({1})" -f $display, (L 'Kennung wird nach erfolgreicher Sicherung aktualisiert' 'identity will be refreshed after a successful backup')
                }
            }
            if ($disk.M24KnownMatchAmbiguous) {
                $display = "? {0} ({1})" -f $display, (L 'bekanntes Laufwerk nicht eindeutig' 'known-drive match is ambiguous')
            }
            if ($backupIndex -lt 0 -and $hasCurrentProfileBackup) {
                $backupIndex = $driveCombo.Items.Count
            }
            if ($newBackupIndex -lt 0 -and $hasCurrentProfileBackup -and $previousDeviceIds -notcontains [string]$disk.DeviceID) {
                $newBackupIndex = $driveCombo.Items.Count
            }
            if ($selectedDeviceId -and $disk.DeviceID -eq $selectedDeviceId) {
                $selectedIndex = $driveCombo.Items.Count
                $selectedHasBackup = $hasCurrentProfileBackup -or $isKnownBackupDrive
            }
            $script:driveMap[$display] = $disk
            [void]$driveCombo.Items.Add($display)
        }

        if ($driveCombo.Items.Count -gt 0) {
            if ($selectedIndex -ge 0 -and $selectedHasBackup) {
                $driveCombo.SelectedIndex = $selectedIndex
            } elseif ($selectedIndex -ge 0 -and $newBackupIndex -ge 0) {
                $driveCombo.SelectedIndex = $newBackupIndex
            } elseif ($selectedIndex -ge 0) {
                $driveCombo.SelectedIndex = $selectedIndex
            } elseif ($preferredIndex -ge 0) {
                $driveCombo.SelectedIndex = $preferredIndex
            } elseif ($backupIndex -ge 0) {
                $driveCombo.SelectedIndex = $backupIndex
            } else {
                $driveCombo.SelectedIndex = 0
            }
        } else {
            $driveInfoLabel.Text = L "Kein geeignetes Ziellaufwerk gefunden." "No suitable drive was found."
            Update-BackupArtifactActions
            Update-BackupHealth
            Update-LibraryList
            Update-BackupOptionState
            Update-SelectionState
            $startButton.Enabled = $false
        }
    } catch {
        # 30 Sekunden Backoff fuer das automatische Polling, damit eine
        # wiederholt haengende oder fehlschlagende Abfrage die GUI nicht im
        # 2,5-Sekunden-Takt erneut pausieren laesst.
        $script:driveRetryAfterUtc = [DateTime]::UtcNow.AddSeconds(30)
        $script:driveSnapshot = $null
        # Auch den vorgeschalteten Logical-Snapshot entwerten. Andernfalls
        # würde die erste erfolgreiche Abfrage nach dem Backoff vor dem
        # Wiederaufbau der zuvor geleerten Liste zurückkehren.
        $script:driveLogicalSnapshot = ''
        $script:driveDeviceIds = @()
        $driveCombo.Items.Clear()
        $script:driveMap.Clear()
        $driveInfoLabel.Text = (L "Laufwerke konnten nicht ermittelt werden: {0}" "Drives could not be detected: {0}") -f $_.Exception.Message
        Update-BackupArtifactActions
        Update-BackupHealth
        Update-LibraryList
        Update-BackupOptionState
        Update-SelectionState
        $startButton.Enabled = $false
    } finally {
        $script:driveDiscoveryActive = $false
    }
}

$driveCombo.Add_SelectedIndexChanged({
    if ($script:pendingEjectDrive) { return }
    if ($driveCombo.SelectedItem) {
        $disk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
        $sizeGb = [math]::Round($disk.Size / 1GB, 1)
        $fileSystem = if ($disk.FileSystem) { $disk.FileSystem } else { L "unbekannt" "unknown" }
        $driveInfoLabel.Text = (L "{0:N1} GB gesamt · {1}" "{0:N1} GB total · {1}") -f $sizeGb, $fileSystem
        $driveToolTip.SetToolTip($driveCombo, $(if (Test-IsKnownBackupDrive -Disk $disk) {
            L 'Bekanntes Sicherungslaufwerk – wird automatisch ausgewählt.' 'Known backup drive — selected automatically.'
        } else {
            L 'Dieses Laufwerk ist noch nicht als Sicherungslaufwerk gespeichert.' 'This drive is not currently remembered as the backup drive.'
        }))
        Update-RestoreSourceList
        if (-not $script:suppressArtifactRetarget) { Update-BackupArtifactActions }
        Update-BackupHealth
        Update-LibraryList
        Update-BackupOptionState
        Update-SelectionState
    }
})

$refreshButton.Add_Click({
    if ($script:pendingEjectDrive) { return }
    $script:artifactCache.Clear()
    Update-DriveList -Force
})

$backupRadio.Add_CheckedChanged({
    if ($backupRadio.Checked) { Update-RestoreSourceList; Update-LibraryList; Update-BackupArtifactActions; Update-BackupOptionState; Update-BackupHealth }
})
$restoreRadio.Add_CheckedChanged({
    if ($restoreRadio.Checked) { Update-BackupSelectionSnapshot -CaptureCurrentList; Update-RestoreSourceList; Update-LibraryList; Update-BackupArtifactActions; Update-BackupOptionState; Update-BackupHealth }
})
$backupSourceCombo.Add_SelectedIndexChanged({
    $script:selectedBackup = Get-SelectedBackupInventoryItem
    if ($script:selectedBackup -and -not $script:selectedBackup.IsUsable) {
        $restoreFolderRadio.Checked = $true
    }
    Update-RestoreTargetState
    Update-BackupArtifactActions
    Update-BackupHealth
    Update-LibraryList
    Update-SelectionState
})
$restoreProfileRadio.Add_CheckedChanged({ if ($restoreProfileRadio.Checked) { Update-RestoreTargetState; Update-SelectionState } })
$restoreFolderRadio.Add_CheckedChanged({ if ($restoreFolderRadio.Checked) { Update-RestoreTargetState; Update-SelectionState } })
$restoreFolderButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = L 'Zielordner für die wiederhergestellten Daten auswählen' 'Choose a destination folder for the restored data'
    $dialog.ShowNewFolderButton = $true
    try {
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:restoreTargetFolder = [string]$dialog.SelectedPath
            Update-RestoreTargetState
            Update-SelectionState
        }
    } finally {
        $dialog.Dispose()
    }
})
$dryRunCheckBox.Add_CheckedChanged({ Update-BackupOptionState })
$superFastCheckBox.Add_CheckedChanged({ Update-BackupOptionState })
$reminderCheckBox.Add_CheckedChanged({
    if ($script:reminderSettingInitializing -or -not $script:settings) { return }
    $newEnabled = [bool]$reminderCheckBox.Checked
    $oldEnabled = [bool]$script:settings.ReminderEnabled
    if ($newEnabled -eq $oldEnabled) { return }
    $oldRegistration = $null
    try {
        $oldRegistration = Get-M24StartupReminderRegistration
        if ($newEnabled) {
            Set-M24StartupReminderRegistration -Command $startupReminderCommand
        } else {
            Remove-M24StartupReminderRegistration
        }
        $script:settings.ReminderEnabled = $newEnabled
        Save-AppSettings
    } catch {
        $reminderError = $_
        $script:settings.ReminderEnabled = $oldEnabled
        try {
            if ($oldEnabled) {
                Set-M24StartupReminderRegistration -Command $(if ($oldRegistration) { $oldRegistration } else { $startupReminderCommand })
            } else {
                Remove-M24StartupReminderRegistration
            }
        } catch {
            # Preserve the original settings/registry error for the user.
        }
        $script:reminderSettingInitializing = $true
        try { $reminderCheckBox.Checked = $oldEnabled } finally { $script:reminderSettingInitializing = $false }
        Write-M24DiagnosticLog -EventId 'GUI.ReminderSetting' -Message 'Failed to update the startup reminder setting.' -Exception $reminderError -Context ('Requested={0}' -f $newEnabled)
        [System.Windows.Forms.MessageBox]::Show(
            ((L "Die Backup-Erinnerung konnte nicht geändert werden:`r`n{0}" "The backup reminder could not be changed:`r`n{0}") -f $reminderError.Exception.Message),
            $form.Text, 'OK', 'Warning') | Out-Null
    }
})

$startButton.Add_Click({
    if ($script:verificationAsyncResult) { return }
    if ($script:pendingEjectDrive) {
        [System.Windows.Forms.MessageBox]::Show((L "Der automatische Auswurf läuft noch. Bitte warten Sie einen Moment." "Automatic eject is still in progress. Please wait a moment."), $form.Text, "OK", "Information") | Out-Null
        return
    }
    if (-not $driveCombo.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show((L "Bitte wählen Sie ein Ziellaufwerk." "Please select a drive."), $form.Text, "OK", "Warning") | Out-Null
        return
    }
    if ($restoreRadio.Checked) {
        $selectedRestoreBackup = Get-SelectedBackupInventoryItem
        if (-not $selectedRestoreBackup -or -not $selectedRestoreBackup.CanCopyToFolder) {
            [System.Windows.Forms.MessageBox]::Show((L 'Bitte wählen Sie eine verwendbare Sicherung aus.' 'Select a usable backup.'), $form.Text, 'OK', 'Warning') | Out-Null
            return
        }
        if ($restoreProfileRadio.Checked -and -not $selectedRestoreBackup.IsUsable) {
            [System.Windows.Forms.MessageBox]::Show((L 'Diese Sicherung kann nur in einen separaten Ordner kopiert werden.' 'This backup can only be copied to a separate folder.'), $form.Text, 'OK', 'Warning') | Out-Null
            return
        }
        if ($restoreFolderRadio.Checked -and [string]::IsNullOrWhiteSpace($script:restoreTargetFolder)) {
            [System.Windows.Forms.MessageBox]::Show((L 'Bitte wählen Sie einen Zielordner aus.' 'Choose a destination folder.'), $form.Text, 'OK', 'Warning') | Out-Null
            return
        }
    }
    if ($libraryList.CheckedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show((L "Bitte wählen Sie mindestens einen Ordner aus." "Please select at least one folder."), $form.Text, "OK", "Warning") | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $coreScript)) {
        [System.Windows.Forms.MessageBox]::Show(((L "Das Sicherungsskript wurde nicht gefunden:`r`n{0}" "The backup script was not found:`r`n{0}") -f $coreScript), (L "Fehler" "Error"), "OK", "Error") | Out-Null
        return
    }

    if ($backupRadio.Checked) {
        try {
            $folderConflicts = @(Get-M24FolderPathConflicts -Folders @(Get-CheckedFolderItems))
        } catch {
            $invalidPathMessage = (L "Mindestens ein ausgewählter Ordnerpfad ist ungültig und kann nicht geprüft werden:`r`n`r`n{0}" "At least one selected folder path is invalid and cannot be checked:`r`n`r`n{0}") -f $_.Exception.Message
            [System.Windows.Forms.MessageBox]::Show($invalidPathMessage, $form.Text, "OK", "Warning") | Out-Null
            return
        }
        if ($folderConflicts.Count -gt 0) {
            $conflictLines = @()
            $shownConflictCount = [Math]::Min($folderConflicts.Count, 5)
            for ($conflictIndex = 0; $conflictIndex -lt $shownConflictCount; $conflictIndex++) {
                $conflict = $folderConflicts[$conflictIndex]
                $parentName = if ($conflict.Parent.PSObject.Properties['DisplayName']) { [string]$conflict.Parent.DisplayName } else { [string]$conflict.Parent.Name }
                $childName = if ($conflict.Child.PSObject.Properties['DisplayName']) { [string]$conflict.Child.DisplayName } else { [string]$conflict.Child.Name }
                if ($conflict.Relationship -eq 'Same') {
                    $conflictLines += (L ("• {0} und {1} verwenden denselben Pfad:`r`n  {2}" -f $parentName, $childName, $conflict.FirstPath) ("• {0} and {1} use the same path:`r`n  {2}" -f $parentName, $childName, $conflict.FirstPath))
                } else {
                    $conflictLines += (L ("• {0}:`r`n  {1}`r`n  liegt innerhalb von {2}:`r`n  {3}" -f $childName, $conflict.Child.Path, $parentName, $conflict.Parent.Path) ("• {0}:`r`n  {1}`r`n  is inside {2}:`r`n  {3}" -f $childName, $conflict.Child.Path, $parentName, $conflict.Parent.Path))
                }
            }
            if ($folderConflicts.Count -gt $shownConflictCount) {
                $conflictLines += (L ("… und {0} weitere Überschneidung(en)." -f ($folderConflicts.Count - $shownConflictCount)) ("… and {0} more overlap(s)." -f ($folderConflicts.Count - $shownConflictCount)))
            }
            $conflictMessage = (L "Einige ausgewählte Ordner werden bereits durch einen anderen ausgewählten Ordner erfasst:`r`n`r`n{0}`r`n`r`nBitte wählen Sie einen der jeweils überschneidenden Einträge ab." "Some selected folders are already covered by another selected folder:`r`n`r`n{0}`r`n`r`nPlease clear one of each pair of overlapping entries.") -f ($conflictLines -join "`r`n")
            $libraryList.SelectedItem = $folderConflicts[0].Child
            [System.Windows.Forms.MessageBox]::Show($conflictMessage, $form.Text, "OK", "Warning") | Out-Null
            return
        }
    }

    $disk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
    if ($backupRadio.Checked -and $disk.M24KnownMatchAmbiguous) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            (L 'Mehrere angeschlossene Laufwerke passen zur gespeicherten Laufwerkskennung. Aus Sicherheitsgründen wurde keines automatisch als bekannt akzeptiert. Haben Sie die Auswahl geprüft und möchten trotzdem fortfahren?' 'Multiple connected drives match the saved drive identity. For safety, none was accepted automatically. Have you verified the selection and still want to continue?'),
            (L 'Laufwerk nicht eindeutig' 'Ambiguous drive identity'), 'YesNo', 'Warning')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    $script:artifactCache.Clear()
    if ($backupRadio.Checked -and $script:knownDrive -and -not $disk.M24KnownMatchAmbiguous -and -not (Test-IsKnownBackupDrive -Disk $disk)) {
        $knownName = if ($script:knownDrive.VolumeName) { $script:knownDrive.VolumeName } else { $script:knownDrive.LastDeviceId }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            ((L "Das ausgewählte Laufwerk ist nicht das bekannte Sicherungslaufwerk '{0}'.`r`n`r`nWenn die Sicherung erfolgreich ist, wird künftig dieses Laufwerk wiedererkannt. Trotzdem fortfahren?" "The selected drive is not the known backup drive '{0}'.`r`n`r`nIf the backup succeeds, this drive will be remembered instead. Continue anyway?") -f $knownName),
            (L 'Anderes Sicherungslaufwerk' 'Different backup drive'),
            'YesNo',
            'Warning'
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    if ($backupRadio.Checked -and $disk.M24IsInternal) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            (L "Das ausgewählte Ziel ist ein internes Laufwerk. Eine Sicherung auf einem externen USB-Laufwerk schützt besser vor Defekten und Schadsoftware.`r`n`r`nTrotzdem fortfahren?" "The selected destination is an internal drive. An external USB drive offers better protection against hardware failure and malware.`r`n`r`nContinue anyway?"),
            (L "Internes Sicherungsziel" "Internal backup destination"),
            "YesNo",
            "Warning"
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    $drive = $disk.DeviceID
    $selectedFolders = @(Get-CheckedFolderItems | ForEach-Object {
        [pscustomobject]@{
            Name = [string]$_.Name
            Path = if ($_.Path) { [string]$_.Path } else { $null }
            IsCustom = [bool]$_.IsCustom
        }
    })
    $script:statusFile = Join-Path $env:TEMP ("Bibliothekssicherung_{0}.status" -f [guid]::NewGuid().ToString("N"))
    $script:resultFile = Join-Path $env:TEMP ("Bibliothekssicherung_{0}.result.json" -f [guid]::NewGuid().ToString("N"))
    $script:cancelFile = Join-Path $env:TEMP ("Bibliothekssicherung_{0}.cancel" -f [guid]::NewGuid().ToString("N"))
    $script:previewFile = Join-Path $env:TEMP ("Bibliothekssicherung_{0}.preview.json" -f [guid]::NewGuid().ToString("N"))
    $script:approvalFile = Join-Path $env:TEMP ("Bibliothekssicherung_{0}.approve" -f [guid]::NewGuid().ToString("N"))
    $script:selectedFoldersFile = Join-Path $env:TEMP ("Bibliothekssicherung_{0}.folders.json" -f [guid]::NewGuid().ToString("N"))
    $selectedRestoreBackup = if ($restoreRadio.Checked) { Get-SelectedBackupInventoryItem } else { $null }
    $operationBackupRoot = if ($selectedRestoreBackup) { [string]$selectedRestoreBackup.RootPath } else { Get-BackupRoot -Drive $drive }
    $script:lastLogDir = Join-Path $operationBackupRoot '_logs'
    $script:lastLogFile = $null
    $script:lastDestination = $operationBackupRoot
    $script:backupStartedAt = Get-Date
    $script:backupCancelled = $false
    $script:preCancelStatusText = $null
    $script:preCancelResultText = $null
    $script:activeDrive = $disk
    $script:activeDryRun = $backupRadio.Checked -and $dryRunCheckBox.Checked
    $script:activeSuperFast = $backupRadio.Checked -and $superFastCheckBox.Checked
    $script:autoEjectRequested = $backupRadio.Checked -and $ejectCheckBox.Checked -and $disk.M24CanEject
    $script:restorePreviewShown = $false
    $script:scanWarningShown = $false
    Update-ElapsedDuration
    $cancelButton.Text = if ($restoreRadio.Checked) { L "Wiederherstellung abbrechen" "Cancel restore" } else { L "Sicherung abbrechen" "Cancel backup" }
    $logButton.Enabled = $false
    $destinationButton.Enabled = $false
    $historyButton.Enabled = $false
    $verifyButton.Enabled = $false
    $deleteBackupButton.Enabled = $false
    $resultBox.Text = if ($script:activeSuperFast) {
        L "Sicherung im Schnellmodus ohne Vorprüfung wird gestartet ..." "Starting fast-mode backup without preflight checks ..."
    } else {
        L "Vorprüfung wird gestartet ..." "Starting preflight checks ..."
    }
    $statusLabel.ForeColor = [System.Drawing.SystemColors]::ControlText
    $statusLabel.Text = if ($restoreRadio.Checked) {
        L "Wiederherstellung wird geprüft ..." "Checking restore ..."
    } elseif ($script:activeDryRun) {
        L "Simulation wird gestartet ..." "Starting simulation ..."
    } elseif ($script:activeSuperFast) {
        L "Sicherung im Schnellmodus wird gestartet ..." "Starting fast-mode backup ..."
    } else {
        L "Sicherung wird gestartet ..." "Starting backup ..."
    }
    Reset-ProgressIndicator -Maximum $selectedFolders.Count
    Start-BusyProgress
    $startButton.Enabled = $false
    $refreshButton.Enabled = $false
    $backupRadio.Enabled = $false
    $restoreRadio.Enabled = $false
    $driveCombo.Enabled = $false
    $backupSourceCombo.Enabled = $false
    $restoreProfileRadio.Enabled = $false
    $restoreFolderRadio.Enabled = $false
    $restoreFolderButton.Enabled = $false
    $libraryList.Enabled = $false
    $allButton.Enabled = $false
    $noneButton.Enabled = $false
    $addFolderButton.Enabled = $false
    $removeFolderButton.Enabled = $false
    $dryRunCheckBox.Enabled = $false
    $ejectCheckBox.Enabled = $false
    $checksumCheckBox.Enabled = $false
    $superFastCheckBox.Enabled = $false
    $closeButton.Visible = $false
    $startButton.Visible = $false
    $cancelButton.Enabled = $true
    $cancelButton.Visible = $true
    $form.AcceptButton = $null

    try {
        Write-M24AtomicTextFile -Path $script:selectedFoldersFile -Content (($selectedFolders | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
        $powershellExe = Join-Path $PSHOME "powershell.exe"
        $mode = if ($restoreRadio.Checked) { 'Restore' } else { 'Backup' }
        $script:activeMode = $mode
        $argumentList = @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $coreScript,
            '-Mode', $mode,
            '-ParentProcessId', $PID,
            '-ParentProcessStartTimeUtcTicks', ([System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks),
            '-UsbDrive', $drive,
            '-Silent',
            '-StatusFile', $script:statusFile,
            '-ResultFile', $script:resultFile,
            '-CancelFile', $script:cancelFile,
            '-PreviewFile', $script:previewFile,
            '-ApprovalFile', $script:approvalFile,
            '-SelectedFoldersFile', $script:selectedFoldersFile
        )
        if ($mode -eq 'Restore') {
            $restoreTargetMode = if ($restoreFolderRadio.Checked) { 'Folder' } else { 'Profile' }
            $argumentList += @(
                '-RestoreIntegrityPolicy', 'Verify',
                '-BackupSource', ([string]$selectedRestoreBackup.RootPath),
                '-RestoreTargetMode', $restoreTargetMode
            )
            if ($restoreTargetMode -eq 'Folder') {
                $argumentList += @('-RestoreTargetRoot', $script:restoreTargetFolder)
            }
        }
        if ($script:activeDryRun) { $argumentList += '-DryRun' }
        if ($script:activeSuperFast) {
            # Der Worker erzwingt uebersprungene Pruefsummen selbst; ein
            # zusaetzliches -SkipChecksums ist hier bewusst nicht noetig.
            $argumentList += '-SuperFast'
        } elseif ($backupRadio.Checked -and -not $script:activeDryRun -and -not $checksumCheckBox.Checked) {
            $argumentList += '-SkipChecksums'
        }
        $arguments = ($argumentList | ForEach-Object { ConvertTo-M24ProcessArgument ([string]$_) }) -join ' '
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $powershellExe
        $startInfo.Arguments = $arguments
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true

        $script:backupProcess = New-Object System.Diagnostics.Process
        $script:backupProcess.StartInfo = $startInfo
        # Der Timer startet VOR dem externen Prozess: Ein WinForms-Tick kann
        # erst laufen, wenn dieser Click-Handler zur Nachrichtenschleife
        # zurueckkehrt - bis dahin ist der Start entweder gelungen oder der
        # catch hat den Timer wieder gestoppt. So kann eine Ausnahme nach
        # erfolgreichem Process.Start() keinen unueberwachten Worker
        # zuruecklassen.
        $timer.Start()
        if (-not $script:backupProcess.Start()) {
            throw (L "Der Sicherungsprozess konnte nicht gestartet werden." "The worker process could not be started.")
        }
    } catch {
        $workerStartError = $_
        Write-M24DiagnosticLog -EventId 'GUI.WorkerStart' -Message 'Failed while preparing or starting the backup or restore worker process.' -Exception $workerStartError -Context ('Mode={0}' -f $script:activeMode)
        # Timer als erster Aufraeumschritt stoppen: Die MessageBox am Ende
        # pumpt Nachrichten, ein laufender Timer koennte sonst mitten im
        # Aufraeumen ticken.
        try { $timer.Stop() } catch {}
        $workerExitConfirmed = $true
        if ($script:backupProcess) {
            # Ein eventuell doch schon gestarteter Worker wird kooperativ
            # (Cancel-Datei), sonst per Kill() beendet - mit begrenzten
            # Wartezeiten, damit der GUI-Thread nie haengen bleibt. Die
            # Funktion gibt das Process-Objekt abschliessend frei und meldet,
            # ob das Prozessende bestaetigt wurde.
            $workerExitConfirmed = Stop-M24WorkerProcess -Process $script:backupProcess -CancelFile $script:cancelFile
            $script:backupProcess = $null
        }
        Reset-ProgressIndicator -Maximum $selectedFolders.Count
        $startButton.Enabled = $true
        $refreshButton.Enabled = $true
        $backupRadio.Enabled = $true
        $restoreRadio.Enabled = $true
        $driveCombo.Enabled = $true
        $backupSourceCombo.Enabled = $true
        $restoreFolderRadio.Enabled = $true
        $restoreFolderButton.Enabled = $true
        $libraryList.Enabled = $true
        $allButton.Enabled = $true
        $noneButton.Enabled = $true
        Update-BackupOptionState
        $closeButton.Visible = $true
        $startButton.Visible = $true
        $cancelButton.Visible = $false
        $form.AcceptButton = $startButton
        $statusLabel.ForeColor = $errorTextColor
        $statusLabel.Text = L "Start fehlgeschlagen." "Failed to start."
        if ($workerExitConfirmed) {
            foreach ($temporaryFile in @($script:statusFile, $script:resultFile, $script:cancelFile, $script:previewFile, $script:approvalFile, $script:selectedFoldersFile)) {
                if ($temporaryFile) { Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue }
            }
        } else {
            # Unbestaetigtes Prozessende: Die Kommunikationsdateien bleiben
            # erhalten, damit die Cancel-Datei fuer den moeglicherweise
            # weiterlaufenden Worker wirksam bleibt. Die Sieben-Tage-
            # Bereinigung entfernt die Reste spaeter zuverlaessig.
            Write-M24DiagnosticLog -EventId 'GUI.WorkerStart' -Severity 'Warning' -Message 'Worker exit could not be confirmed; communication files were kept so the cancellation request stays effective.' -Context ('CancelFile={0}' -f $script:cancelFile)
        }
        $script:statusFile = $null
        $script:resultFile = $null
        $script:cancelFile = $null
        $script:previewFile = $null
        $script:approvalFile = $null
        $script:selectedFoldersFile = $null
        $script:activeDrive = $null
        $script:activeMode = $null
        $script:activeDryRun = $false
        $script:activeSuperFast = $false
        $script:autoEjectRequested = $false
        $script:backupStartedAt = $null
        Update-ElapsedDuration
        Update-BackupOptionState
        [System.Windows.Forms.MessageBox]::Show($workerStartError.Exception.Message, (L "Fehler" "Error"), "OK", "Error") | Out-Null
    }
})

$timer.Add_Tick({
    Update-ElapsedDuration

    if ($script:statusFile -and (Test-Path -LiteralPath $script:statusFile)) {
        try {
            $status = (Get-Content -LiteralPath $script:statusFile -Raw -ErrorAction Stop).Trim()
            if ($status) {
                $parts = $status -split '\|'
                switch ($parts[0]) {
                    "VORSCHAU" {
                        if (-not $script:restorePreviewShown -and $script:previewFile -and (Test-Path -LiteralPath $script:previewFile)) {
                            $script:restorePreviewShown = $true
                            try {
                                $preview = Get-Content -LiteralPath $script:previewFile -Raw | ConvertFrom-Json
                                $previewGb = [math]::Round(([double]$preview.PlannedBytes / 1GB), 2)
                                $examples = @($preview.OverwriteExamples)
                                $exampleText = if ($examples.Count) { (L "`r`n`r`nBeispiele für ersetzte Dateien:`r`n" "`r`n`r`nExamples of files to be replaced:`r`n") + ($examples -join "`r`n") } else { "" }
                                $manifestExists = $preview.PSObject.Properties['ChecksumManifestExists'] -and [bool]$preview.ChecksumManifestExists
                                $verifiedAt = if ($preview.PSObject.Properties['ChecksumsVerifiedAt']) { [string]$preview.ChecksumsVerifiedAt } else { '' }
                                $integrityText = if (-not $manifestExists) {
                                    L "Integrität: Kein SHA-256-Prüfsummenmanifest vorhanden – beschädigte Dateien würden nicht erkannt." "Integrity: no SHA-256 checksum manifest exists – corrupted files would not be detected."
                                } elseif ($verifiedAt) {
                                    (L "Integrität: Prüfsummen zuletzt erfolgreich geprüft am {0}." "Integrity: checksums last verified successfully on {0}.") -f $verifiedAt
                                } else {
                                    L "Integrität: Prüfsummen seit der letzten Sicherung nicht geprüft – Empfehlung: zuerst „Backup prüfen“ ausführen." "Integrity: checksums not verified since the last backup – recommendation: run “Verify backup” first."
                                }
                                $sourceIdentity = if ($preview.SourceComputer -or $preview.SourceUser) { "$($preview.SourceComputer)\$($preview.SourceUser)" } else { L 'unbekannt' 'unknown' }
                                $targetDescription = if ([string]$preview.TargetMode -eq 'Folder') {
                                    (L 'Separater Ordner: {0}' 'Separate folder: {0}') -f $preview.TargetRoot
                                } else {
                                    L 'Aktuelles Benutzerprofil' 'Current user profile'
                                }
                                $migrationNotice = if ([bool]$preview.IsMigration -and [string]$preview.TargetMode -eq 'Profile') {
                                    (L "`r`n`r`nDiese Sicherung stammt von „{0}“. Die ausgewählten Daten werden in das aktuelle Benutzerprofil übernommen." "`r`n`r`nThis backup originates from “{0}”. The selected data will be restored to the current user profile.") -f $sourceIdentity
                                } else { '' }
                                $message = if ($script:isGerman) {
                                    "Wiederherstellungsvorschau:`r`n`r`nHerkunft: $sourceIdentity`r`nZiel: $targetDescription`r`nFehlende Dateien: $($preview.MissingFiles)`r`nLokale Dateien, die ersetzt werden: $($preview.OverwriteFiles)`r`nNeuere lokale Dateien, die geschützt bleiben: $($preview.ProtectedNewerFiles)`r`nZu kopieren: $($preview.PlannedFiles) Dateien / $previewGb GB`r`n`r`n$integrityText$migrationNotice$exampleText`r`n`r`nWiederherstellung jetzt starten?"
                                } else {
                                    "Restore preview:`r`n`r`nOrigin: $sourceIdentity`r`nDestination: $targetDescription`r`nMissing files: $($preview.MissingFiles)`r`nLocal files to be replaced: $($preview.OverwriteFiles)`r`nNewer local files that remain protected: $($preview.ProtectedNewerFiles)`r`nTo be copied: $($preview.PlannedFiles) files / $previewGb GB`r`n`r`n$integrityText$migrationNotice$exampleText`r`n`r`nStart the restore now?"
                                }
                                $answer = [System.Windows.Forms.MessageBox]::Show($message, (L "Wiederherstellung prüfen" "Review restore"), "YesNo", "Warning")
                                if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                                    $approvalValue = if ([string]$preview.TargetMode -eq 'Folder') {
                                        'continue'
                                    } elseif (-not $manifestExists) {
                                        $overrideAnswer = [System.Windows.Forms.MessageBox]::Show(
                                            (L "Ohne Prüfsummenmanifest kann die Integrität des Backups nicht bestätigt werden. Beschädigte oder manipulierte Dateien könnten wiederhergestellt werden.`r`n`r`nTrotzdem ausdrücklich unbestätigt wiederherstellen?" "Without a checksum manifest, backup integrity cannot be confirmed. Corrupted or modified files could be restored.`r`n`r`nExplicitly continue with an unverified restore?"),
                                            (L 'Unbestätigte Wiederherstellung' 'Unverified restore'),
                                            'YesNo', 'Error', [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
                                        if ($overrideAnswer -eq [System.Windows.Forms.DialogResult]::Yes) { 'continue-unverified' } else { 'cancel' }
                                    } elseif ($verifiedAt) {
                                        'continue-verified'
                                    } else {
                                        'verify-then-continue'
                                    }
                                    if ($approvalValue -eq 'cancel') {
                                        $script:backupCancelled = $true
                                        Set-Content -LiteralPath $script:cancelFile -Value 'cancel' -Encoding ASCII
                                        $statusLabel.Text = L "Wiederherstellung wird abgebrochen ..." "Cancelling restore ..."
                                    } else {
                                        Set-Content -LiteralPath $script:approvalFile -Value $approvalValue -Encoding ASCII
                                        $statusLabel.Text = if ($approvalValue -eq 'verify-then-continue') { L 'Backup wird vor der Wiederherstellung geprüft ...' 'Verifying backup before restore ...' } else { L "Wiederherstellung wird gestartet ..." "Starting restore ..." }
                                    }
                                } else {
                                    $script:backupCancelled = $true
                                    Set-Content -LiteralPath $script:cancelFile -Value 'cancel' -Encoding ASCII
                                    $statusLabel.Text = L "Wiederherstellung wird abgebrochen ..." "Cancelling restore ..."
                                }
                            } catch {
                                $script:backupCancelled = $true
                                Set-Content -LiteralPath $script:cancelFile -Value 'cancel' -Encoding ASCII -ErrorAction SilentlyContinue
                                [System.Windows.Forms.MessageBox]::Show((L "Die Konfliktvorschau konnte nicht gelesen werden. Die Wiederherstellung wurde nicht gestartet." "The conflict preview could not be read. The restore was not started."), (L "Fehler" "Error"), "OK", "Error") | Out-Null
                            }
                        }
                    }
                    "SCANWARNUNG" {
                        if (-not $script:scanWarningShown -and $script:previewFile -and (Test-Path -LiteralPath $script:previewFile)) {
                            $script:scanWarningShown = $true
                            try {
                                $warningInfo = Get-Content -LiteralPath $script:previewFile -Raw | ConvertFrom-Json
                                $warningExamples = @($warningInfo.Warnings | Select-Object -First 5)
                                $warningText = if ($warningExamples.Count) { "`r`n`r`n" + ($warningExamples -join "`r`n") } else { "" }
                                $message = if ($script:isGerman) {
                                    "Die Vorprüfung konnte $($warningInfo.WarningCount) Datei(en) oder Ordner nicht lesen. Nicht lesbare Dateien können bei der Sicherung übersprungen werden und die Speicherplatzschätzung kann zu niedrig ausfallen.$warningText`r`n`r`nSicherung trotzdem fortsetzen?"
                                } else {
                                    "The preflight check could not read $($warningInfo.WarningCount) file(s) or folder(s). Unreadable files may be skipped during the backup and the disk-space estimate may be too low.$warningText`r`n`r`nContinue the backup anyway?"
                                }
                                $answer = [System.Windows.Forms.MessageBox]::Show($message, (L "Warnungen der Vorprüfung" "Preflight warnings"), "YesNo", "Warning")
                                if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                                    Set-Content -LiteralPath $script:approvalFile -Value 'continue' -Encoding ASCII
                                    $statusLabel.Text = L "Sicherung wird fortgesetzt ..." "Continuing backup ..."
                                } else {
                                    $script:backupCancelled = $true
                                    Set-Content -LiteralPath $script:cancelFile -Value 'cancel' -Encoding ASCII
                                    $statusLabel.Text = L "Sicherung wird abgebrochen ..." "Cancelling backup ..."
                                }
                            } catch {
                                $script:backupCancelled = $true
                                Set-Content -LiteralPath $script:cancelFile -Value 'cancel' -Encoding ASCII -ErrorAction SilentlyContinue
                                [System.Windows.Forms.MessageBox]::Show((L "Die Warnungen der Vorprüfung konnten nicht gelesen werden. Die Sicherung wurde nicht fortgesetzt." "The preflight warnings could not be read. The backup was not continued."), (L "Fehler" "Error"), "OK", "Error") | Out-Null
                            }
                        }
                    }
                    "PRUEFUNG" {
                        Start-BusyProgress
                        $displayFolder = Get-M24FolderDisplayName $parts[3] $script:isGerman
                        $statusLabel.Text = if ($script:isGerman) { "Prüfe Ordner $($parts[1]) von $($parts[2]): $displayFolder" } else { "Checking folder $($parts[1]) of $($parts[2]): $displayFolder" }
                        $resultBox.Text = L "Dateien und benötigter Speicherplatz werden geprüft ..." "Checking files and required disk space ..."
                    }
                    "PRUEFSUMME" {
                        Start-BusyProgress
                        $displayFolder = Get-M24FolderDisplayName $parts[3] $script:isGerman
                        $statusLabel.Text = if ($script:isGerman) { "Prüfsummen für Ordner $($parts[1]) von $($parts[2]): $displayFolder" } else { "Checksums for folder $($parts[1]) of $($parts[2]): $displayFolder" }
                        $resultBox.Text = L "Neue und geänderte Backup-Dateien werden mit SHA-256 erfasst ..." "New and changed backup files are being recorded with SHA-256 ..."
                    }
                    "RESTOREPRUEFUNG" {
                        Start-BusyProgress
                        if ($parts.Count -ge 4) {
                            $displayFolder = Get-M24FolderDisplayName $parts[3] $script:isGerman
                            $statusLabel.Text = if ($script:isGerman) { "Prüfe Backup-Integrität für Ordner $($parts[1]) von $($parts[2]): $displayFolder" } else { "Verifying backup integrity for folder $($parts[1]) of $($parts[2]): $displayFolder" }
                        } else {
                            $statusLabel.Text = L 'Backup-Integrität wird geprüft ...' 'Verifying backup integrity ...'
                        }
                        $resultBox.Text = L 'Vor dem Wiederherstellen werden alle vorhandenen Prüfsummen kontrolliert.' 'All existing checksums are being validated before restore.'
                    }
                    "KOPIERVORGANG" {
                        Start-BusyProgress
                        $current = [int]$parts[1]
                        $total = [int]$parts[2]
                        $script:lastProgressCurrent = $current
                        $script:lastProgressTotal = [math]::Max(1, $total)
                        $displayFolder = Get-M24FolderDisplayName $parts[3] $script:isGerman
                        $statusLabel.Text = if ($restoreRadio.Checked) {
                            if ($script:isGerman) { "Robocopy stellt Ordner $current von $total wieder her: $displayFolder" } else { "Robocopy is restoring folder $current of $total`: $displayFolder" }
                        } elseif ($script:activeDryRun) {
                            if ($script:isGerman) { "Robocopy simuliert Ordner $current von $total`: $displayFolder" } else { "Robocopy is simulating folder $current of $total`: $displayFolder" }
                        } else {
                            if ($script:isGerman) { "Robocopy sichert Ordner $current von $total`: $displayFolder" } else { "Robocopy is backing up folder $current of $total`: $displayFolder" }
                        }
                        $resultBox.Text = if ($script:isGerman) { "Aktiver Ordner: $displayFolder. Der Vorgang kann hier abgebrochen werden." } else { "Active folder: $displayFolder. The operation can be cancelled here." }
                    }
                    "ABBRUCHLAEUFT" {
                        Start-BusyProgress
                        $current = [int]$parts[1]
                        $total = [int]$parts[2]
                        $displayFolder = Get-M24FolderDisplayName $parts[3] $script:isGerman
                        $statusLabel.Text = if ($script:isGerman) { "Abbruch läuft für Ordner $current von $total`: $displayFolder" } else { "Cancelling folder $current of $total`: $displayFolder" }
                        $resultBox.Text = if ($restoreRadio.Checked) {
                            L "Robocopy wird gestoppt. Die zuletzt aktive Datei kann unvollständig sein." "Robocopy is being stopped. The last active file may be incomplete."
                        } elseif ($script:activeDryRun) {
                            L "Robocopy wird gestoppt. Die Simulation wird beendet." "Robocopy is being stopped. The simulation is ending."
                        } else {
                            L "Robocopy wird gestoppt. Die zuletzt aktive Datei kann unvollständig im Backup-Ziel liegen." "Robocopy is being stopped. The last active file may be incomplete in the backup destination."
                        }
                    }
                    "ABBRUCHWARTET" {
                        Start-BusyProgress
                        $current = [int]$parts[1]
                        $total = [int]$parts[2]
                        $displayFolder = Get-M24FolderDisplayName $parts[3] $script:isGerman
                        $seconds = if ($parts.Count -ge 5) { [int]$parts[4] } else { 0 }
                        $statusLabel.Text = if ($script:isGerman) { "Warte auf Robocopy-Ende für Ordner $current von $total`: $displayFolder" } else { "Waiting for Robocopy to exit for folder $current of $total`: $displayFolder" }
                        $resultBox.Text = if ($script:isGerman) {
                            "Robocopy wird beendet. Bitte Laufwerk nicht entfernen. Wartezeit: $seconds s."
                        } else {
                            "Robocopy is exiting. Do not remove the drive. Wait time: $seconds s."
                        }
                    }
                    "FORTSCHRITT" {
                        Start-BusyProgress
                        $current = [int]$parts[1]
                        $total = [int]$parts[2]
                        $script:lastProgressCurrent = $current
                        $script:lastProgressTotal = [math]::Max(1, $total)
                        $name = Get-M24FolderDisplayName $parts[3] $script:isGerman
                        $statusLabel.Text = if ($restoreRadio.Checked) {
                            if ($script:isGerman) { "Ordner $current von $total wird wiederhergestellt: $name" } else { "Restoring folder $current of $total`: $name" }
                        } elseif ($script:activeDryRun) {
                            if ($script:isGerman) { "Ordner $current von $total wird simuliert: $name" } else { "Simulating folder $current of $total`: $name" }
                        } else {
                            if ($script:isGerman) { "Ordner $current von $total wird gesichert: $name" } else { "Backing up folder $current of $total`: $name" }
                        }
                    }
                    "STATUS" {
                        Start-BusyProgress
                        $statusLabel.Text = if ($restoreRadio.Checked) { L "Wiederherstellung wird vorbereitet ..." "Preparing restore ..." } elseif ($script:activeDryRun) { L "Simulation wird vorbereitet ..." "Preparing simulation ..." } else { L "Sicherung wird vorbereitet ..." "Preparing backup ..." }
                    }
                    "FERTIG" {
                        Stop-BusyProgress
                        $statusLabel.Text = if ($restoreRadio.Checked) { L "Wiederherstellung erfolgreich abgeschlossen." "Restore completed successfully." } elseif ($script:activeDryRun) { L "Simulation erfolgreich abgeschlossen." "Simulation completed successfully." } else { L "Sicherung erfolgreich abgeschlossen." "Backup completed successfully." }
                    }
                    "FEHLER" { $statusLabel.Text = $parts[1] }
                    "ABGEBROCHEN" { $statusLabel.Text = L "Vorgang wurde abgebrochen." "Operation was cancelled." }
                }
            }
        } catch {
            # Beim ersten Anlegen oder Entfernen kann die Datei kurz fehlen.
        }
    }

    if ($script:backupProcess) {
        $script:backupProcess.Refresh()
        if ($script:backupCancelled -and -not $script:backupProcess.HasExited) {
            $statusLabel.ForeColor = $warningTextColor
            $statusLabel.Text = L "Abbruch läuft – bitte warten ..." "Cancellation in progress - please wait ..."
            Set-CancellationPendingOverview
        }
        if ($script:backupProcess.HasExited) {
            $exitCode = $script:backupProcess.ExitCode
            $timer.Stop()
            Set-ProgressFromLastStatus
            Update-ElapsedDuration
            $startButton.Enabled = $true
            $refreshButton.Enabled = $true
            $backupRadio.Enabled = $true
            $restoreRadio.Enabled = $true
            $driveCombo.Enabled = $true
            $backupSourceCombo.Enabled = $true
            $restoreFolderRadio.Enabled = $true
            $restoreFolderButton.Enabled = $true
            $libraryList.Enabled = $true
            $allButton.Enabled = $true
            $noneButton.Enabled = $true
            Update-BackupOptionState
            $closeButton.Visible = $true
            $startButton.Visible = $true
            $cancelButton.Visible = $false
            $form.AcceptButton = $closeButton

            $result = $null
            if ($script:resultFile -and (Test-Path -LiteralPath $script:resultFile)) {
                try { $result = Get-Content -LiteralPath $script:resultFile -Raw | ConvertFrom-Json } catch {}
            }
            if ($result -and $result.LogFile -and (Test-Path -LiteralPath ([string]$result.LogFile) -PathType Leaf)) {
                $script:lastLogFile = [string]$result.LogFile
            }

            $newestLog = Get-NewestLogFile
            $logButton.Enabled = $null -ne $newestLog
            $destinationButton.Enabled = $script:lastDestination -and (Test-Path -LiteralPath $script:lastDestination)
            $historyButton.Enabled = $logButton.Enabled
            $verifyButton.Enabled = $destinationButton.Enabled
            $completedSelectedBackup = if ($restoreRadio.Checked) { Get-SelectedBackupInventoryItem } else { $null }
            $deleteBackupButton.Enabled = $destinationButton.Enabled -and
                (-not $restoreRadio.Checked -or ($completedSelectedBackup -and $completedSelectedBackup.IsCurrentProfile))

            $resultCancellationReason = if ($result -and $result.PSObject.Properties['CancellationReason']) { [string]$result.CancellationReason } else { $null }
            $operationWasCancelled = $script:backupCancelled -or ($result -and $result.PSObject.Properties['Cancelled'] -and [bool]$result.Cancelled)
            if ($operationWasCancelled) {
                $statusLabel.ForeColor = $warningTextColor
                $statusLabel.Text = L "Vorgang wurde abgebrochen." "Operation was cancelled."
                $interruptedFolder = if ($result -and $result.PSObject.Properties['InterruptedFolder'] -and $result.InterruptedFolder) { Get-M24FolderDisplayName ([string]$result.InterruptedFolder) $script:isGerman } else { $null }
                $partialWarning = if ($result -and $result.PSObject.Properties['PartialFilesMayRemain'] -and [bool]$result.PartialFilesMayRemain) {
                    L " Die zuletzt aktive Datei kann unvollständig sein; starten Sie die Sicherung erneut oder prüfen Sie das Backup." " The last active file may be incomplete; run the backup again or verify the backup."
                } else { "" }
                $resultBox.Text = if ($resultCancellationReason -eq 'GuiExited') {
                    L 'Der Vorgang wurde beendet, weil die zugehörige Bedienoberfläche nicht mehr verfügbar war.' 'The operation stopped because its owning user interface was no longer available.'
                } elseif ($interruptedFolder) {
                    ((L "Vom Benutzer abgebrochen während: {0}." "Cancelled by the user while processing: {0}.") -f $interruptedFolder) + $partialWarning
                } else {
                    (L "Vom Benutzer abgebrochen." "Cancelled by the user.") + $partialWarning
                }
            } elseif ($exitCode -eq 0 -and -not $result) {
                $statusLabel.ForeColor = $errorTextColor
                $statusLabel.Text = L "Worker ohne Ergebnis beendet." "Worker exited without a result."
                $resultBox.Text = L "Der Hintergrundprozess wurde beendet, hat aber keine Ergebnisdatei geschrieben. Bitte prüfen Sie das Protokoll und starten Sie den Vorgang erneut." "The background process exited but did not write a result file. Review the log and run the operation again."
            } elseif ($exitCode -eq 0) {
                $elapsed = (Get-Date) - $script:backupStartedAt
                $duration = Format-ElapsedDuration $elapsed
                $statusLabel.ForeColor = $successTextColor
                $isRestore = $result -and $result.Mode -eq 'Restore'
                $isDryRun = $result -and $result.DryRun
                $statusLabel.Text = if ($isRestore) {
                    (L "Wiederherstellung erfolgreich abgeschlossen ({0})." "Restore completed successfully ({0}).") -f $duration
                } elseif ($isDryRun) {
                    (L "Simulation erfolgreich abgeschlossen ({0}). Log: {1}" "Simulation completed successfully ({0}). Log: {1}") -f $duration, $newestLog
                } else {
                    (L "Erfolgreich abgeschlossen ({0}). Ziel: {1}" "Completed successfully ({0}). Destination: {1}") -f $duration, $script:lastDestination
                }
                $progressBar.Value = $progressBar.Maximum
                if ($result) {
                    $displayHints = @($result.HintFolders | ForEach-Object { Get-M24FolderDisplayName $_ $script:isGerman })
                    $hints = if ($displayHints.Count) { (L " Hinweise: {0}." " Notes: {0}.") -f ($displayHints -join ', ') } else { "" }
                    $robocopyWarnings = if ($result.PSObject.Properties['RobocopyWarnings']) { @($result.RobocopyWarnings | Where-Object { $_ }) } else { @() }
                    $robocopyWarningText = Format-RobocopyWarningSummary -Warnings $robocopyWarnings
                    $checksumNote = if ($result.PSObject.Properties['ChecksumSkipped'] -and [bool]$result.ChecksumSkipped) { L " Prüfsummen übersprungen." " Checksums skipped." } else { "" }
                    # Ohne Vorpruefung (Superschnell-Modus) gibt es keine Planzahlen;
                    # "0 Dateien / 0 GB" waere eine falsche Aussage.
                    $preflightSkipped = $result.PSObject.Properties['PreflightSkipped'] -and [bool]$result.PreflightSkipped
                    $plannedText = if ($preflightSkipped) {
                        L "Ohne Vorprüfung; Kopiervolumen nicht vorab ermittelt." "No preflight; copy volume was not estimated in advance."
                    } else {
                        $plannedGb = [math]::Round(([double]$result.PlannedBytes / 1GB), 2)
                        if ($script:isGerman) { "Geplant: $($result.PlannedFiles) Dateien / $plannedGb GB." } else { "Planned: $($result.PlannedFiles) files / $plannedGb GB." }
                    }
                    $resultBox.Text = if ($script:isGerman) {
                        "$(if ($isRestore) { 'Wiederhergestellt' } elseif ($isDryRun) { 'Simuliert' } else { 'Gesichert' }): $(@($result.SuccessfulFolders).Count) Ordner. $plannedText Dauer: $duration.$hints$robocopyWarningText$checksumNote"
                    } else {
                        "$(if ($isRestore) { 'Restored' } elseif ($isDryRun) { 'Simulated' } else { 'Backed up' }): $(@($result.SuccessfulFolders).Count) folders. $plannedText Duration: $duration.$hints$robocopyWarningText$checksumNote"
                    }
                } else {
                    $resultBox.Text = L "Vorgang erfolgreich abgeschlossen." "Operation completed successfully."
                }
                if ($script:activeMode -eq 'Backup' -and -not $isDryRun) {
                    $script:settings.LastSuccessfulBackup = (Get-Date).ToString('o')
                    try {
                        if ($script:activeDrive) {
                            # Save-KnownBackupDrive persistiert den gesamten
                            # Settings-Vertrag einschließlich des neuen Datums.
                            Save-KnownBackupDrive -Disk $script:activeDrive
                            $driveToolTip.SetToolTip($driveCombo, (L 'Dieses Laufwerk ist jetzt als bekanntes Sicherungslaufwerk gespeichert.' 'This drive is now remembered as the backup drive.'))
                        } else {
                            Save-AppSettings
                        }
                    } catch {
                        $knownDriveSaveError = $_
                        $backupDateSaved = $false
                        try { Save-AppSettings; $backupDateSaved = $true } catch {
                            # The original persistence error remains the actionable cause.
                        }
                        $settingsWarning = if ($backupDateSaved) {
                            L "Die Sicherung war erfolgreich und ihr Datum wurde gespeichert. Das bekannte Sicherungslaufwerk konnte jedoch nicht aktualisiert werden:`r`n{0}" "The backup succeeded and its date was saved, but the known backup drive could not be updated:`r`n{0}"
                        } else {
                            L "Die Sicherung war erfolgreich, die lokalen App-Einstellungen konnten jedoch nicht gespeichert werden:`r`n{0}" "The backup succeeded, but the local app settings could not be saved:`r`n{0}"
                        }
                        [System.Windows.Forms.MessageBox]::Show(
                            ($settingsWarning -f $knownDriveSaveError.Exception.Message),
                            $form.Text,
                            'OK',
                            'Warning'
                        ) | Out-Null
                    }
                }
                if ($script:autoEjectRequested -and $script:activeDrive -and $script:activeDrive.M24CanEject -and -not $isDryRun -and -not $isRestore) {
                    Request-DelayedAutoEject -Drive $script:activeDrive.DeviceID
                }
            } else {
                $statusLabel.ForeColor = $errorTextColor
                $partialCopy = $result -and $result.PSObject.Properties['PartialCopy'] -and [bool]$result.PartialCopy
                $statusLabel.Text = if (-not $result) {
                    (L "Worker unerwartet beendet (Exit-Code {0})." "Worker exited unexpectedly (exit code {0}).") -f $exitCode
                } elseif ($partialCopy) {
                    (L "Vorgang unvollständig (Exit-Code {0})." "Operation incomplete (exit code {0}).") -f $exitCode
                } else {
                    (L "Vorgang mit Fehlern beendet (Exit-Code {0})." "Operation finished with errors (exit code {0}).") -f $exitCode
                }
                $resultBox.Text = if ($result -and $result.Message) {
                    $warnings = if ($result.PSObject.Properties['RobocopyWarnings']) { @($result.RobocopyWarnings | Where-Object { $_ }) } else { @() }
                    "$($result.Message)$(Format-RobocopyWarningSummary -Warnings $warnings)"
                } elseif (-not $result) {
                    L "Der Hintergrundprozess wurde beendet, ohne eine Ergebnisdatei zu schreiben. Das kann nach einem harten Prozessabbruch passieren; bitte prüfen Sie das Protokoll." "The background process exited without writing a result file. This can happen after a hard process termination; review the log."
                } elseif ($newestLog) {
                    L "Details finden Sie im Protokoll." "See the log for details."
                } else {
                    L "Es wurde keine Logdatei erstellt." "No log file was created."
                }
                $errorText = if ($newestLog) {
                    (L "Der Vorgang wurde mit Fehlern beendet.`r`nExit-Code: {0}`r`nBitte prüfen Sie die Logdatei." "The operation finished with errors.`r`nExit code: {0}`r`nPlease review the log file.") -f $exitCode
                } else {
                    $detail = if ($result -and $result.Message) { [string]$result.Message } else { L "Es wurde keine Logdatei erstellt." "No log file was created." }
                    (L "Der Vorgang wurde mit Fehlern beendet.`r`nExit-Code: {0}`r`n{1}" "The operation finished with errors.`r`nExit code: {0}`r`n{1}") -f $exitCode, $detail
                }
                [System.Windows.Forms.MessageBox]::Show($errorText, (L "Fehler" "Error"), "OK", "Error") | Out-Null
            }

            if ($operationWasCancelled) {
                Show-CompletionNotification -Title (L 'Vorgang abgebrochen' 'Operation cancelled') -Text $resultBox.Text -Icon Warning
            } elseif ($exitCode -eq 0) {
                Show-CompletionNotification -Title (L 'Vorgang abgeschlossen' 'Operation completed') -Text $resultBox.Text -Icon Info
            } else {
                Show-CompletionNotification -Title (L 'Vorgang fehlgeschlagen' 'Operation failed') -Text $resultBox.Text -Icon Error
            }

            # Nach dem Abschluss genuegt ein Enter zum Beenden: "Schliessen"
            # erhaelt Default-Status und den Tastaturfokus.
            if ($closeButton.Visible -and $closeButton.Enabled) { $closeButton.Select() }

            # Das Ergebnis bleibt als erste Zeile stehen; darunter zeigt die
            # Uebersicht wieder die aktuelle Ordnerauswahl an.
            $script:resultSummary = $resultBox.Text
            $script:backupProcess.Dispose()
            $script:backupProcess = $null
            if ($script:pendingEjectDrive) { Update-BackupHealth } else { Update-DriveList -Force }
            $script:activeDrive = $null
            $script:activeMode = $null
            $script:activeDryRun = $false
            $script:activeSuperFast = $false
            $script:autoEjectRequested = $false
            Update-BackupOptionState
            Update-ResultOverview
            if ($script:statusFile) {
                Remove-Item -LiteralPath $script:statusFile -Force -ErrorAction SilentlyContinue
                $script:statusFile = $null
            }
            if ($script:resultFile) {
                Remove-Item -LiteralPath $script:resultFile -Force -ErrorAction SilentlyContinue
                $script:resultFile = $null
            }
            if ($script:cancelFile) {
                Remove-Item -LiteralPath $script:cancelFile -Force -ErrorAction SilentlyContinue
                $script:cancelFile = $null
            }
            foreach ($temporaryName in @('previewFile', 'approvalFile', 'selectedFoldersFile')) {
                $temporaryPath = Get-Variable -Name $temporaryName -Scope Script -ValueOnly
                if ($temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
                Set-Variable -Name $temporaryName -Scope Script -Value $null
            }
        }
    }
})

$logButton.Add_Click({
    $logFile = Get-NewestLogFile
    if ($logFile) {
        Start-Process -FilePath $logFile.FullName
    } else {
        [System.Windows.Forms.MessageBox]::Show((L "Es wurde keine Logdatei gefunden." "No log file was found."), $form.Text, "OK", "Information") | Out-Null
    }
})

$helpButton.Add_Click({
    Open-HelpTopic
})

$historyButton.Add_Click({
    $logs = @(Get-ChildItem -LiteralPath $script:lastLogDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 10)
    if (-not $logs) { return }
    $lines = @($logs | ForEach-Object {
        $kind = if ($_.BaseName -like 'restore_*') { L 'Wiederherstellung' 'Restore' }
            elseif ($_.BaseName -like 'verify_*') { L 'Prüfung' 'Verification' }
            else { L 'Sicherung' 'Backup' }
        '{0}  ·  {1}  ·  {2:N1} KB' -f $_.LastWriteTime.ToString('dd.MM.yyyy HH:mm'), $kind, ($_.Length / 1KB)
    })
    $message = ($lines -join [Environment]::NewLine) + [Environment]::NewLine + [Environment]::NewLine +
        (L 'Protokollordner jetzt öffnen, um einzelne Protokolle anzusehen?' 'Open the log folder now to inspect individual logs?')
    $answer = [System.Windows.Forms.MessageBox]::Show($message, (L 'Letzte Vorgänge' 'Recent operations'), 'YesNo', 'Information')
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList $script:lastLogDir
    }
})

function Format-BackupDeletionSize {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return (L '{0:N2} GB' '{0:N2} GB') -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return (L '{0:N1} MB' '{0:N1} MB') -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return (L '{0:N1} KB' '{0:N1} KB') -f ($Bytes / 1KB) }
    return (L '{0} Bytes' '{0} bytes') -f $Bytes
}

function Show-BackupDeletionTextConfirmation {
    param($Info)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = L 'Backup endgültig löschen' 'Permanently delete backup'
    $dialog.StartPosition = 'CenterParent'
    $dialog.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $dialog.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $dialog.ClientSize = New-Object System.Drawing.Size(560, 198)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.Font = $form.Font

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(18, 16)
    $label.Size = New-Object System.Drawing.Size(524, 78)
    $confirmationGerman = "Dieser Vorgang kann nicht rückgängig gemacht werden.`r`nGeben Sie zur Bestätigung exakt diesen Backup-Namen ein:`r`n`r`n{0}"
    $confirmationEnglish = "This action cannot be undone.`r`nTo confirm, enter this exact backup name:`r`n`r`n{0}"
    $label.Text = (L $confirmationGerman $confirmationEnglish) -f $Info.ConfirmationText
    $dialog.Controls.Add($label)

    $confirmationInput = New-Object System.Windows.Forms.TextBox
    $confirmationInput.Location = New-Object System.Drawing.Point(18, 101)
    $confirmationInput.Size = New-Object System.Drawing.Size(524, 27)
    $confirmationInput.AccessibleName = L 'Backup-Name zur Bestätigung' 'Backup name confirmation'
    $dialog.Controls.Add($confirmationInput)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = L 'Abbrechen' 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(295, 146)
    $cancel.Size = New-Object System.Drawing.Size(100, 36)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)
    $dialog.CancelButton = $cancel

    # Der destruktive Befehl erhaelt bewusst nie den Standardfokus; erst der
    # exakt eingegebene Backup-Name aktiviert ihn.
    $confirm = New-Object System.Windows.Forms.Button
    $confirm.Text = L 'Endgültig löschen' 'Delete permanently'
    $confirm.Location = New-Object System.Drawing.Point(403, 146)
    $confirm.Size = New-Object System.Drawing.Size(139, 36)
    $confirm.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $confirm.Enabled = $false
    $confirm.ForeColor = $dangerTextColor
    $dialog.Controls.Add($confirm)

    $confirmationInput.Add_TextChanged({
        # Statische Equals-Variante verwenden: WinForms kann beim Schließen
        # noch ein TextChanged-Ereignis mit bereits freigegebenem Textwert
        # zustellen. Das darf keine unbehandelte Null-Ausnahme auslösen.
        $confirm.Enabled = [string]::Equals([string]$confirmationInput.Text, [string]$Info.ConfirmationText, [System.StringComparison]::Ordinal)
        $dialog.AcceptButton = if ($confirm.Enabled) { $confirm } else { $null }
    })

    try {
        # Explizite DPI-Skalierung wie beim Hauptfenster (siehe Kommentar
        # vor ShowDialog des Hauptfensters).
        $dialog.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
        $dialog.PerformAutoScale()
        $confirmationInput.Select()
        return $dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK -and $confirm.Enabled
    } finally {
        $dialog.Dispose()
    }
}

$deleteBackupButton.Add_Click({
    if ($script:backupProcess -or $script:verificationAsyncResult -or $script:pendingEjectDrive) { return }
    if (-not $driveCombo.SelectedItem -or -not $script:lastDestination) { return }
    $disk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
    try {
        $info = Get-M24BackupDeletionInfo -BackupRoot $script:lastDestination -Drive $disk.DeviceID -Computer $env:COMPUTERNAME -User $env:USERNAME
        $verifiedText = if ($info.ChecksumVerifiedAt) { $info.ChecksumVerifiedAt } else { L 'nicht vermerkt' 'not recorded' }
        $foldersText = if ($info.Folders) { $info.Folders } else { L 'nicht vermerkt' 'not recorded' }
        $resultText = if ($info.Result) { $info.Result } else { L 'nicht vermerkt' 'not recorded' }
        $deletionGerman = "Folgendes Backup wird vollständig und endgültig gelöscht:`r`n`r`nPfad: {0}`r`nComputer: {1}`r`nBenutzer: {2}`r`nLetztes Ergebnis: {3}`r`nGesicherte Bibliotheken: {4}`r`nLetzte Prüfsummenprüfung: {5}`r`nInhalt auf Datenträger: {6} Dateien, {7} Verzeichnisse, {8}`r`n`r`nDabei werden alle Nutzdaten, Metadaten, Prüfsummen und Protokolle dieses Backups entfernt. Das Laufwerk und andere Backups bleiben unverändert.`r`n`r`nMöchten Sie zur letzten Sicherheitsabfrage weitergehen?"
        $deletionEnglish = "The following backup will be deleted completely and permanently:`r`n`r`nPath: {0}`r`nComputer: {1}`r`nUser: {2}`r`nLatest result: {3}`r`nBacked-up libraries: {4}`r`nLatest checksum verification: {5}`r`nOn-disk contents: {6} files, {7} directories, {8}`r`n`r`nAll user data, metadata, checksums, and logs in this backup will be removed. The drive and other backups remain unchanged.`r`n`r`nContinue to the final safety confirmation?"
        $message = (L $deletionGerman $deletionEnglish) -f
            $info.BackupRoot, $info.Computer, $info.User, $resultText, $foldersText, $verifiedText,
            $info.Files, $info.Directories, (Format-BackupDeletionSize $info.Bytes)
        $answer = [System.Windows.Forms.MessageBox]::Show($message, (L 'Backup löschen' 'Delete backup'), 'YesNo', 'Warning')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        if (-not (Show-BackupDeletionTextConfirmation -Info $info)) { return }

        Set-VerificationControlsEnabled -Enabled $false
        $form.UseWaitCursor = $true
        $statusLabel.Text = L 'Backup wird endgültig gelöscht ...' 'Permanently deleting backup ...'
        $resultBox.Text = L 'Die ausgewählte Sicherung wird entfernt. Das Laufwerk darf jetzt nicht getrennt werden.' 'The selected backup is being removed. Do not disconnect the drive.'
        Start-BusyProgress
        $script:deletionInfo = $info
        $script:deletionDisk = $disk
        $deletionScript = {
            param([string]$sharedScript, [string]$backupRoot, [string]$drive, [string]$computer, [string]$user)
            . $sharedScript
            Remove-M24BackupSafely -BackupRoot $backupRoot -Drive $drive -Computer $computer -User $user
        }
        $script:deletionPowerShell = [System.Management.Automation.PowerShell]::Create()
        [void]$script:deletionPowerShell.AddScript($deletionScript.ToString()).AddArgument($sharedScript).AddArgument($info.BackupRoot).AddArgument([string]$disk.DeviceID).AddArgument($env:COMPUTERNAME).AddArgument($env:USERNAME)
        $script:deletionAsyncResult = $script:deletionPowerShell.BeginInvoke()
        $deletionTimer.Start()
    } catch {
        $deletionStartError = $_
        Write-M24DiagnosticLog -EventId 'GUI.DeletionStart' -Message 'Failed while preparing or starting the backup deletion.' -Exception $deletionStartError
        $statusLabel.Text = L 'Backup konnte nicht gelöscht werden.' 'Backup could not be deleted.'
        [System.Windows.Forms.MessageBox]::Show(
            ((L "Das Backup wurde nicht vollständig gelöscht:`r`n{0}" "The backup was not completely deleted:`r`n{0}") -f $deletionStartError.Exception.Message),
            $form.Text, 'OK', 'Error') | Out-Null
        if ($script:deletionPowerShell) { $script:deletionPowerShell.Dispose() }
        $script:deletionPowerShell = $null
        $script:deletionAsyncResult = $null
        $script:deletionInfo = $null
        $script:deletionDisk = $null
        Stop-BusyProgress
        $form.UseWaitCursor = $false
        Set-VerificationControlsEnabled -Enabled $true
    }
})

$verifyButton.Add_Click({
    if ($script:backupProcess -or $script:verificationAsyncResult) { return }
    if (-not $script:lastDestination -or -not (Test-Path -LiteralPath $script:lastDestination -PathType Container)) { return }
    $metadataFile = Join-Path $script:lastDestination '_Sicherungsinfo.txt'
    $metadataLines = if (Test-Path -LiteralPath $metadataFile -PathType Leaf) {
        @(Get-Content -LiteralPath $metadataFile -ErrorAction SilentlyContinue)
    } else { @() }
    if (-not (Get-M24BackupResultInfo -Lines $metadataLines).IsComplete) {
        [System.Windows.Forms.MessageBox]::Show((L 'Nur eine erfolgreich abgeschlossene Sicherung kann geprüft werden.' 'Only a successfully completed backup can be verified.'), $form.Text, 'OK', 'Warning') | Out-Null
        return
    }

    $manifestPath = Join-Path $script:lastDestination (Get-M24ChecksumManifestName)
    $initializeManifest = -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)
    if ($initializeManifest) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            (L 'Diese ältere Sicherung besitzt noch keine Prüfsummen. Jetzt ein initiales SHA-256-Manifest aus dem aktuellen Backup-Inhalt erstellen?' 'This older backup has no checksums yet. Create an initial SHA-256 manifest from its current contents now?'),
            (L 'Prüfsummen initialisieren' 'Initialize checksums'), 'YesNo', 'Information')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    Set-VerificationControlsEnabled -Enabled $false
    $script:verificationCancelFile = Join-Path ([System.IO.Path]::GetTempPath()) ("M24Backup.verify-cancel.{0}.{1}.tmp" -f $PID, [guid]::NewGuid().ToString('N'))
    $statusLabel.Text = if ($initializeManifest) { L 'Prüfsummen werden initial erstellt ...' 'Creating initial checksums ...' } else { L 'SHA-256-Prüfsummen werden verglichen ...' 'Comparing SHA-256 checksums ...' }
    Start-BusyProgress
    $closeButton.Visible = $false
    $startButton.Visible = $false
    $cancelButton.Text = L 'Prüfung abbrechen' 'Cancel verification'
    $cancelButton.Enabled = $true
    $cancelButton.Visible = $true
    $form.AcceptButton = $null
    $verificationScript = {
        param([string]$root, [string]$sharedScript, [string]$manifestPath, [bool]$initialize, [string]$cancelFile, [string]$missingFoldersMessage)
        . $sharedScript
        $startedAt = Get-Date
        $logDir = Join-Path $root '_logs'
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null
        $logFile = Join-Path $logDir ("verify_{0}_{1}_{2}.log" -f $startedAt.ToString('yyyyMMdd_HHmmss'), $PID, [guid]::NewGuid().ToString('N').Substring(0, 8))
        $result = $null
        $unexpectedError = $null
        $lockFile = Join-Path $root '_backup.lock'; $lockStream = $null; $lockAcquired = $false
        try {
            $dataFolders = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop | Where-Object { -not $_.Name.StartsWith('_') })
            if ($dataFolders.Count -eq 0) {
                $result = [pscustomobject]@{ Initialized = $initialize; Cancelled = $false; Files = 0; Bytes = 0; ErrorCount = 1; Errors = @($missingFoldersMessage) }
            } else {
                $folders = @($dataFolders | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.FullName } })
                $excluded = @(Get-M24DefaultExcludedFiles)
                $lockStream = [System.IO.File]::Open($lockFile, 'OpenOrCreate', 'ReadWrite', 'None'); $lockAcquired = $true
                if ($initialize) {
                    $created = Update-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles $excluded -ForceRehash `
                        -CancelCallback { Test-Path -LiteralPath $cancelFile }
                    $result = [pscustomobject]@{ Initialized = $true; Cancelled = $created.Cancelled; Files = $created.Files; Bytes = $created.Bytes; ErrorCount = 0; Errors = @() }
                } else {
                    $checked = Test-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles $excluded `
                        -CancelCallback { Test-Path -LiteralPath $cancelFile }
                    if (-not $checked.Cancelled -and [int]$checked.ErrorCount -eq 0) {
                        # Erfolgreiche Vollpruefung in den Metadaten vermerken; die
                        # Restore-Vorschau zeigt diesen Stand als Integritaetsstatus an.
                        Set-M24ChecksumVerifiedMetadata -MetadataFile (Join-Path $root '_Sicherungsinfo.txt')
                    }
                    $result = [pscustomobject]@{ Initialized = $false; Cancelled = $checked.Cancelled; Files = $checked.Files; Bytes = $checked.Bytes; ErrorCount = $checked.ErrorCount; Errors = @($checked.Errors) }
                }
            }
        } catch {
            $unexpectedError = $_.Exception.Message
            $result = [pscustomobject]@{ Initialized = $initialize; Cancelled = $false; Files = 0; Bytes = 0; ErrorCount = 1; Errors = @($unexpectedError) }
        } finally {
            if ($lockStream) { $lockStream.Dispose() }
            if ($lockAcquired) { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
            $finishedAt = Get-Date
            $outcome = if ($unexpectedError) { 'Fehlgeschlagen' } elseif ($result.Cancelled) { 'Abgebrochen' } elseif ([int]$result.ErrorCount -gt 0) { 'Integritaetsfehler' } elseif ($initialize) { 'Pruefsummenmanifest erstellt' } else { 'Erfolgreich' }
            $lines = @(
                'M24 Backup-Pruefprotokoll',
                "Backup: $root",
                "Pruefart: $(if ($initialize) { 'SHA-256-Manifest initial erstellen' } else { 'SHA-256-Pruefsummen vergleichen' })",
                "Hashalgorithmus: SHA-256",
                "Beginn: $($startedAt.ToString('yyyy-MM-dd HH:mm:ss'))",
                "Ende: $($finishedAt.ToString('yyyy-MM-dd HH:mm:ss'))",
                ("Dauer: {0:N1} Sekunden" -f ($finishedAt - $startedAt).TotalSeconds),
                "Ergebnis: $outcome",
                "Dateien: $([int64]$result.Files)",
                "Bytes: $([int64]$result.Bytes)",
                "Integritaetsfehler: $([int]$result.ErrorCount)"
            )
            if (@($result.Errors).Count -gt 0) {
                $lines += ''
                $lines += 'Fehlerdetails:'
                $lines += @($result.Errors | ForEach-Object { "- $_" })
            }
            try { [System.IO.File]::WriteAllLines($logFile, [string[]]$lines, [System.Text.Encoding]::Unicode) } catch {}
        }
        return [pscustomobject]@{ Initialized = $result.Initialized; Cancelled = $result.Cancelled; Files = $result.Files; Bytes = $result.Bytes; ErrorCount = $result.ErrorCount; Errors = @($result.Errors); UnexpectedError = $unexpectedError; LogFile = $logFile }
    }
    $script:verificationPowerShell = [System.Management.Automation.PowerShell]::Create()
    [void]$script:verificationPowerShell.AddScript($verificationScript.ToString()).AddArgument($script:lastDestination).AddArgument($sharedScript).AddArgument($manifestPath).AddArgument($initializeManifest).AddArgument($script:verificationCancelFile).AddArgument((L 'Keine Sicherungsordner mit Nutzdaten gefunden.' 'No backup data folders were found.'))
    $script:verificationAsyncResult = $script:verificationPowerShell.BeginInvoke()
    $verificationTimer.Start()
})

$destinationButton.Add_Click({
    if ($script:lastDestination -and (Test-Path -LiteralPath $script:lastDestination)) {
        try {
            $pathToOpen = $script:lastDestination
            if ($restoreRadio.Checked -and $driveCombo.SelectedItem) {
                $selectedDisk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
                $pathToOpen = Resolve-M24RestoreSource -Drive $selectedDisk.DeviceID -BackupSource $script:lastDestination
            }
            Start-Process -FilePath "explorer.exe" -ArgumentList $pathToOpen
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                ((L "Der ausgewählte Sicherungsordner ist nicht mehr sicher verfügbar:`r`n{0}" "The selected backup folder is no longer safely available:`r`n{0}") -f $_.Exception.Message),
                $form.Text, 'OK', 'Warning') | Out-Null
        }
    }
})

$cancelButton.Add_Click({
    if ($script:verificationAsyncResult -and -not $script:verificationAsyncResult.IsCompleted) {
        $cancelButton.Enabled = $false
        $statusLabel.Text = L 'Abbruch der Backup-Prüfung angefordert ...' 'Cancelling backup verification ...'
        try {
            Set-Content -LiteralPath $script:verificationCancelFile -Value 'cancel' -Encoding ASCII -ErrorAction Stop
        } catch {
            $cancelButton.Enabled = $true
            [System.Windows.Forms.MessageBox]::Show((L 'Der Abbruch konnte nicht angefordert werden.' 'Cancellation could not be requested.'), $form.Text, 'OK', 'Error') | Out-Null
        }
        return
    }
    if (-not $script:backupProcess -or $script:backupProcess.HasExited) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        (L "Möchten Sie den laufenden Vorgang wirklich abbrechen?`r`n`r`nRobocopy wird gestoppt. Die zuletzt aktive Datei kann unvollständig im Ziel liegen. Starten Sie die Sicherung danach erneut oder prüfen Sie das Backup." "Do you really want to cancel the current operation?`r`n`r`nRobocopy will be stopped. The last active file may be incomplete at the destination. Run the backup again afterwards or verify the backup."),
        (L "Vorgang abbrechen" "Cancel operation"),
        "YesNo",
        "Warning"
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $script:backupCancelled = $true
    $script:preCancelStatusText = $statusLabel.Text
    $script:preCancelResultText = $resultBox.Text
    $cancelButton.Enabled = $false
    $statusLabel.ForeColor = $warningTextColor
    $statusLabel.Text = L "Abbruch angefordert - der aktuelle Ordner wird noch sicher beendet ..." "Cancellation requested - the current folder will finish safely ..."
    Set-CancellationPendingOverview
    try {
        Set-Content -LiteralPath $script:cancelFile -Value 'cancel' -Encoding ASCII -ErrorAction Stop
    } catch {
        $script:backupCancelled = $false
        $cancelButton.Enabled = $true
        if ($script:preCancelStatusText) { $statusLabel.Text = $script:preCancelStatusText }
        if ($script:preCancelResultText) { $resultBox.Text = $script:preCancelResultText }
        [System.Windows.Forms.MessageBox]::Show((L "Der Abbruch konnte nicht angefordert werden." "Cancellation could not be requested."), $form.Text, "OK", "Error") | Out-Null
    }
})

$form.Add_KeyDown({
    param($sender, $eventArgs)

    if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::F1) {
        Open-HelpTopic
        $eventArgs.SuppressKeyPress = $true
    } elseif ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::F5 -and $refreshButton.Enabled) {
        $refreshButton.PerformClick()
        $eventArgs.SuppressKeyPress = $true
    } elseif ($eventArgs.Control -and $eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::L -and $logButton.Enabled) {
        $logButton.PerformClick()
        $eventArgs.SuppressKeyPress = $true
    } elseif ($eventArgs.Control -and $eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::O -and $destinationButton.Enabled) {
        $destinationButton.PerformClick()
        $eventArgs.SuppressKeyPress = $true
    }
})

$closeButton.Add_Click({ $form.Close() })

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:ejectDialogOpen) {
        $eventArgs.Cancel = $true
    } elseif ($script:backupProcess -and -not $script:backupProcess.HasExited) {
        $eventArgs.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show((L "Der Vorgang läuft noch. Bitte warten Sie bis zum Abschluss." "The operation is still running. Please wait until it finishes."), $form.Text, "OK", "Warning") | Out-Null
    } elseif ($script:verificationAsyncResult -and -not $script:verificationAsyncResult.IsCompleted) {
        $eventArgs.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show((L 'Die Backup-Prüfung läuft noch. Bitte warten Sie bis zum Abschluss.' 'Backup verification is still running. Wait until it completes.'), $form.Text, 'OK', 'Information') | Out-Null
    } elseif ($script:deletionAsyncResult -and -not $script:deletionAsyncResult.IsCompleted) {
        $eventArgs.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show((L 'Das Backup wird gerade gelöscht. Bitte warten Sie bis zum Abschluss.' 'The backup is currently being deleted. Wait until it completes.'), $form.Text, 'OK', 'Information') | Out-Null
    } elseif ($script:pendingEjectDrive) {
        $eventArgs.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show((L "Der automatische Auswurf wird gerade vorbereitet. Bitte warten Sie einen Moment." "Automatic eject is being prepared. Please wait a moment."), $form.Text, "OK", "Information") | Out-Null
    }
})

$form.Add_FormClosed({
    $driveWatchTimer.Stop()
    $folderSizeTimer.Stop()
    # Der Groessen-Scan darf das Beenden nicht verzoegern; er wird abgebrochen.
    if ($script:folderSizePowerShell) {
        try { $script:folderSizePowerShell.Stop() } catch {}
        try { $script:folderSizePowerShell.Dispose() } catch {}
        $script:folderSizePowerShell = $null
        $script:folderSizeAsyncResult = $null
    }
    try { Save-FolderSelection } catch {}
})

# Beim Start liegt der Fokus auf "Sicherung starten", damit die Sicherung
# direkt mit Enter beginnen kann. Mindest- und Startgroesse werden erst hier
# festgelegt: Nach der automatischen DPI-Skalierung sind die Fenstermasse
# physisch, sodass sie direkt gegen die Arbeitsflaeche des Monitors geprueft
# werden koennen. Auf kleinen Bildschirmen schrumpft primaer der flexible
# Ordnerbereich (Liste erhaelt dann einen Scrollbalken).
$form.Add_Shown({
    $script:mainWindowShown = $true
    $scaleFactor = $form.CurrentAutoScaleDimensions.Width / 96
    if ($scaleFactor -le 0) { $scaleFactor = 1 }
    $workingArea = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    # 770 logische Pixel Mindestbreite halten die vier Fusszeilen-Befehle
    # einzeilig; wird das Fenster durch eine kleine Arbeitsflaeche schmaler
    # geklemmt, bricht die Fusszeile kontrolliert um statt zu ueberlappen.
    $form.MinimumSize = New-Object System.Drawing.Size(
        [math]::Min([int](770 * $scaleFactor), $workingArea.Width),
        [math]::Min([int](700 * $scaleFactor), $workingArea.Height))
    if ($form.Width -gt $workingArea.Width -or $form.Height -gt $workingArea.Height) {
        $form.Size = New-Object System.Drawing.Size(
            [math]::Min($form.Width, $workingArea.Width),
            [math]::Min($form.Height, $workingArea.Height))
        $form.Location = New-Object System.Drawing.Point(
            ($workingArea.Left + [int](($workingArea.Width - $form.Width) / 2)),
            ($workingArea.Top + [int](($workingArea.Height - $form.Height) / 2)))
    }
    Update-OptionsSurfaceHeight
    Update-ActivitySurfaceLayout
    Update-ContentLayoutHeight
    $driveWatchTimer.Start()
    if ($startButton.Enabled) { $startButton.Select() }
})

# Verwaiste Kommunikationsdateien frueherer Sitzungen (aelter als sieben
# Tage) still entfernen, bevor diese Instanz eigene Dateien anlegt. Frische
# Dateien koennen einer zweiten GUI-Instanz oder einem noch laufenden Worker
# gehoeren und bleiben deshalb unangetastet. Die Funktion faengt alle Fehler
# selbst ab und darf den Start nicht beeinflussen.
Remove-M24StaleTempArtifacts

Set-StartupSplashStatus (L 'Einstellungen werden geladen ...' 'Loading settings ...')
$script:settings = Get-AppSettings
$script:knownDrive = Get-KnownBackupDrive
if ($script:settingsNeedSave) {
    try {
        Save-AppSettings
        $script:settingsNeedSave = $false
    } catch {
        Write-M24DiagnosticLog -EventId 'GUI.ReminderMigration' -Message 'Failed to persist reminder defaults or migration.' -Exception $_
    }
}
$script:reminderSettingInitializing = $true
try { $reminderCheckBox.Checked = [bool]$script:settings.ReminderEnabled } finally { $script:reminderSettingInitializing = $false }
try {
    if ($script:settings.ReminderEnabled) {
        $registeredReminder = Get-M24StartupReminderRegistration
        if (-not $registeredReminder -or -not $registeredReminder.Equals($startupReminderCommand, [System.StringComparison]::OrdinalIgnoreCase)) {
            Set-M24StartupReminderRegistration -Command $startupReminderCommand
        }
    } else {
        Remove-M24StartupReminderRegistration
    }
} catch {
    Write-M24DiagnosticLog -EventId 'GUI.ReminderSelfHeal' -Message 'Failed to reconcile the startup reminder registration.' -Exception $_ -Context ('Enabled={0}' -f $script:settings.ReminderEnabled)
}
$savedSelection = Get-SavedFolderSelection
if ($savedSelection) {
    $savedNames = @($savedSelection.SelectedNames | ForEach-Object { [string]$_ })
    foreach ($definition in Get-LibraryDefinitions) {
        $script:folderCheckStates[[string]$definition.Name] = $savedNames -contains [string]$definition.Name
    }
    foreach ($savedCustom in @($savedSelection.CustomFolders)) {
        if ($savedCustom.Name -and $savedCustom.Path -and (Test-Path -LiteralPath ([string]$savedCustom.Path) -PathType Container)) {
            $script:customFolders += New-FolderListItem -Name ([string]$savedCustom.Name) -DisplayName ("{0} ({1})" -f $savedCustom.Name, $savedCustom.Path) -Path ([string]$savedCustom.Path) -IsCustom $true -Checked ([bool]$savedCustom.Checked)
            $script:folderCheckStates[[string]$savedCustom.Name] = [bool]$savedCustom.Checked
        }
    }
    $script:backupSelectionSnapshot = [ordered]@{ SelectedNames = $savedNames; CustomFolders = @($savedSelection.CustomFolders) }
}
$libraryList.Items.Clear()
Update-LibraryList
Set-StartupSplashStatus (L 'Sicherungslaufwerke werden geprüft ...' 'Checking backup drives ...')
Update-DriveList -Force
Update-BackupOptionState
Update-SelectionState

# WinForms unter Windows PowerShell fuehrt die DPI-Autoskalierung nicht
# implizit beim Handle-Aufbau aus (empirisch mit PowerShell 5.1 verifiziert:
# ohne diesen Aufruf bleiben alle Masse 96-dpi-Pixel, waehrend Schriften
# bereits DPI-skaliert rendern). Deshalb wird das fertig aufgebaute Layout
# hier einmalig explizit auf die System-DPI skaliert.
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.PerformAutoScale()
$script:dpiLayoutReady = $true
# Nach der Skalierung einmal initial nachrechnen, damit die Absolute-Zeilen
# des Optionsbereichs bereits vor der ersten Anzeige DPI-korrekt sind.
Update-OptionsSurfaceHeight
Update-ActivitySurfaceLayout
Update-ContentLayoutHeight

# Der Splash muss vor ShowDialog vollstaendig geschlossen sein. Andernfalls
# kann WinForms das modale Hauptfenster implizit dem noch aktiven Splash als
# Owner zuordnen; dessen Schliessen wuerde dann auch die Haupt-GUI schliessen.
# Ein kuenstliches Verweilen im "Bereit."-Zustand gibt es bewusst nicht mehr.
Close-StartupSplash
[void]$form.ShowDialog()
} catch {
    $script:fatalGuiError = $true
    $fatalError = $_
    $fatalMessage = $fatalError.Exception.Message
    Write-M24DiagnosticLog -EventId 'GUI.Fatal' -Message $(if ($script:mainWindowShown) { 'Unexpected top-level GUI failure.' } else { 'The GUI failed during startup.' }) -Exception $fatalError -Context ('MainWindowShown={0}' -f $script:mainWindowShown)
    # Der VBS-Starter startet PowerShell ohne sichtbare Konsole. Deshalb muss
    # ein unbehandelter Fehler als Dialog erscheinen, bevor der Prozess endet.
    Close-StartupSplash
    try {
        $fatalTitle = if ($script:mainWindowShown) {
            L 'Unerwarteter Fehler' 'Unexpected error'
        } else {
            L 'Start fehlgeschlagen' 'Startup failed'
        }
        $fatalText = if ($script:mainWindowShown) {
            (L "Die Anwendung musste wegen eines unerwarteten Fehlers beendet werden:`r`n`r`n{0}" "The application had to close because of an unexpected error:`r`n`r`n{0}") -f $fatalMessage
        } else {
            (L "Die Bibliothekssicherung konnte nicht gestartet werden:`r`n`r`n{0}" "Library Backup could not be started:`r`n`r`n{0}") -f $fatalMessage
        }
        [System.Windows.Forms.MessageBox]::Show($fatalText, $fatalTitle, 'OK', 'Error') | Out-Null
    } catch {
        # Selbst ein Fehler beim optionalen Dialog darf die abschliessende
        # Ressourcenfreigabe nicht verhindern.
    }
} finally {
    Close-StartupSplash
    if ($notifyIcon) { try { $notifyIcon.Visible = $false; $notifyIcon.Dispose() } catch {} }
    foreach ($resource in @($appIcon, $healthToolTip, $driveToolTip, $optionsToolTip, $resultContextMenu, $timer, $driveWatchTimer, $ejectTimer, $notificationTimer, $verificationTimer, $deletionTimer)) {
        if ($resource) { try { $resource.Dispose() } catch {} }
    }
    if ($form) { try { $form.Dispose() } catch {} }
    Exit-M24SingleInstance -Handle $script:guiInstanceHandle
    $script:guiInstanceHandle = $null
}
if ($script:fatalGuiError) { exit 1 }
