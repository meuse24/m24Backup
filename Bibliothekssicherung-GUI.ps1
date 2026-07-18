<#
Grafische Oberfläche für Bibliothekssicherung.ps1.
Die Sicherung läuft in einem separaten PowerShell-Prozess. Ein Timer liest
den aktuellen Status aus einer temporären Datei, damit das Fenster bedienbar
bleibt und nicht auf frei formulierte Konsolenausgaben angewiesen ist.
#>

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

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

$installedFontNames = @([System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name })
$textFontName = if ($installedFontNames -contains 'Segoe UI Variable Text') { 'Segoe UI Variable Text' } else { 'Segoe UI' }
$semiboldFontName = if ($installedFontNames -contains 'Segoe UI Variable Text Semibold') { 'Segoe UI Variable Text Semibold' } else { 'Segoe UI Semibold' }
$displayFontName = if ($installedFontNames -contains 'Segoe UI Variable Display Semib') { 'Segoe UI Variable Display Semib' } else { 'Segoe UI Semibold' }

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
$script:mainWindowShown = $false
$script:fatalGuiError = $false

function Set-StartupSplashStatus {
    param([string]$Text)
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
}

$script:guiInstanceHandle = $null
try {
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sidBytes = [System.Text.Encoding]::UTF8.GetBytes($currentSid)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { $sidHash = ([BitConverter]::ToString($sha256.ComputeHash($sidBytes))).Replace('-', '').Substring(0, 16) } finally { $sha256.Dispose() }
    $script:guiInstanceHandle = Enter-M24SingleInstance -Name ("Local\M24Backup.GUI.{0}" -f $sidHash)
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

# Das Hauptfenster erscheint erst nach Laufwerks- und Metadatenabfragen. Der
# Splashscreen gibt waehrend dieser Startphase sofort sichtbares Feedback.
try {
    $script:splashForm = New-Object System.Windows.Forms.Form
    $script:splashForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $script:splashForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $script:splashForm.ClientSize = New-Object System.Drawing.Size(390, 285)
    $script:splashForm.BackColor = [System.Drawing.Color]::White
    $script:splashForm.ShowInTaskbar = $false
    $script:splashForm.TopMost = $true

    $splashLogoBox = New-Object System.Windows.Forms.PictureBox
    $splashLogoBox.Location = New-Object System.Drawing.Point(45, 18)
    $splashLogoBox.Size = New-Object System.Drawing.Size(300, 205)
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
    $script:splashForm.Controls.Add($splashLogoBox)

    $script:splashStatusLabel = New-Object System.Windows.Forms.Label
    $script:splashStatusLabel.Text = L 'Bibliothekssicherung wird gestartet ...' 'Library Backup is starting ...'
    $script:splashStatusLabel.Location = New-Object System.Drawing.Point(30, 229)
    $script:splashStatusLabel.Size = New-Object System.Drawing.Size(330, 24)
    $script:splashStatusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:splashStatusLabel.Font = New-Object System.Drawing.Font($semiboldFontName, 10)
    $script:splashStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(31, 55, 74)
    $script:splashForm.Controls.Add($script:splashStatusLabel)

    $splashProgress = New-Object System.Windows.Forms.ProgressBar
    $splashProgress.Location = New-Object System.Drawing.Point(45, 262)
    $splashProgress.Size = New-Object System.Drawing.Size(300, 8)
    $splashProgress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $splashProgress.MarqueeAnimationSpeed = 24
    $script:splashForm.Controls.Add($splashProgress)

    $script:splashForm.Show()
    $script:splashForm.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
} catch {
    # Ein optionaler Splashscreen darf den eigentlichen Programmstart nie
    # verhindern, etwa wenn das Logo auf einem langsamen Medium nicht lesbar ist.
    Close-StartupSplash
}

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
$settingsDirectory = Join-Path $env:LOCALAPPDATA 'M24Backup'
$settingsFile = Join-Path $settingsDirectory 'settings.json'
$script:knownDrive = $null
$script:settingsWritable = $true
$script:settings = $null

function Get-LibraryNames {
    param([switch]$IncludeMissing)
    return @(Get-LibraryDefinitions -IncludeMissing:$IncludeMissing | ForEach-Object { $_.Name })
}

function Get-LibraryDefinitions {
    param([switch]$IncludeMissing)
    return @(Get-M24StandardFolderDefinitions | Where-Object { $IncludeMissing -or (Test-Path -LiteralPath $_.Path) })
}

function New-FolderListItem {
    param(
        [string]$Name,
        [string]$DisplayName,
        [string]$Path,
        [bool]$IsCustom,
        [bool]$Checked = $true
    )

    $item = [pscustomobject]@{
        Name = $Name
        DisplayName = $DisplayName
        Path = $Path
        IsCustom = $IsCustom
        Checked = $Checked
    }
    $item | Add-Member -MemberType ScriptMethod -Name ToString -Value { return $this.DisplayName } -Force
    return $item
}

function Get-FolderItemDisplayName {
    param($Item)
    if ($Item -and $Item.PSObject.Properties['DisplayName']) { return [string]$Item.DisplayName }
    if ($Item -and $Item.PSObject.Properties['Name']) { return Get-M24FolderDisplayName ([string]$Item.Name) $script:isGerman }
    return [string]$Item
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
            New-FolderListItem -Name ([string]$_.Name) -DisplayName ("{0} ({1})" -f $_.Name, $_.OriginalPath) -Path ([string]$_.OriginalPath) -IsCustom $true -Checked $true
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

    $baseName = Split-Path -LiteralPath $Path -Leaf
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

    $resultLine = $Lines | Where-Object { $_ -like 'Ergebnis:*' } | Select-Object -Last 1
    return $resultLine -and $resultLine -match '^Ergebnis:\s*Erfolgreich abgeschlossen\s+am\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.?$'
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
    $script:lastDestination = Get-BackupRoot -Drive $disk.DeviceID
    $script:lastLogDir = Join-Path $script:lastDestination '_logs'
    $script:lastLogFile = $null
    $script:backupStartedAt = $null
    $cacheKey = "{0}|{1}" -f $disk.DeviceID, (Get-NormalizedVolumeSerial -Disk $disk)
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
    $deleteBackupButton.Enabled = $destinationButton.Enabled
}

function Get-NormalizedVolumeSerial {
    param($Disk)
    if (-not $Disk -or -not $Disk.VolumeSerialNumber) { return '' }
    return ([string]$Disk.VolumeSerialNumber).Trim().Replace('-', '').ToUpperInvariant()
}

function Get-AppSettings {
    if (-not (Test-Path -LiteralPath $settingsFile -PathType Leaf)) {
        return [ordered]@{ Version = 3; KnownBackupDrive = $null; FolderSelection = $null }
    }
    try {
        $parsed = Get-Content -LiteralPath $settingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return [ordered]@{ Version = 3; KnownBackupDrive = $parsed.KnownBackupDrive; FolderSelection = $parsed.FolderSelection }
    } catch {
        # Eine nur voruebergehend nicht lesbare Datei darf nicht ueberschrieben werden.
        $script:settingsWritable = $false
        return [ordered]@{ Version = 3; KnownBackupDrive = $null; FolderSelection = $null }
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
    param([string]$Drive)

    $backupDirectory = Get-BackupRoot -Drive $Drive
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
        if (-not (Test-BackupMetadataMatchesCurrentProfile -Lines $lines)) {
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

$form = New-Object System.Windows.Forms.Form
$form.Text = L "Bibliothekssicherung" "Library Backup"
if ($appVersion) { $form.Text = "{0} {1}" -f $form.Text, $appVersion }
$form.StartPosition = "CenterScreen"
$form.ClientSize = New-Object System.Drawing.Size(720, 698)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.SizeGripStyle = [System.Windows.Forms.SizeGripStyle]::Hide
# Kleine Bildschirme (z. B. 1366x768): Das Fenster darf niedriger werden als
# das Layout; der Inhalt wird dann gescrollt. Nach oben ist die Hoehe auf die
# Layouthoehe begrenzt. Die feste Rahmenart verhindert eine manuelle
# Groessenaenderung, die automatische Anpassung bleibt aber moeglich.
$form.MinimumSize = New-Object System.Drawing.Size(736, 560)
$form.AutoScroll = $true
$form.KeyPreview = $true
$form.Font = New-Object System.Drawing.Font($textFontName, 9.5)
$form.BackColor = [System.Drawing.Color]::FromArgb(243, 246, 249)
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
$surfaceColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$borderColor = [System.Drawing.Color]::FromArgb(222, 226, 230)
$buttonBorderColor = [System.Drawing.Color]::FromArgb(185, 193, 202)
$secondaryTextColor = [System.Drawing.Color]::FromArgb(82, 89, 96)
$accentColor = [System.Drawing.SystemColors]::Highlight
$accentTextColor = [System.Drawing.SystemColors]::HighlightText
$accentHoverColor = [System.Windows.Forms.ControlPaint]::Dark($accentColor)

function New-SurfacePanel {
    param(
        [System.Drawing.Point]$Location,
        [System.Drawing.Size]$Size,
        [string]$Anchor = 'Top, Left, Right'
    )
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = $Location
    $panel.Size = $Size
    $panel.Anchor = $Anchor
    $panel.BackColor = $surfaceColor
    $form.Controls.Add($panel)
    return $panel
}

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = L "Dateien sichern" "Back up files"
$titleLabel.Font = New-Object System.Drawing.Font($displayFontName, 18)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(30, 16)
$form.Controls.Add($titleLabel)

$descriptionLabel = New-Object System.Windows.Forms.Label
$descriptionLabel.Text = L "Wählen Sie Ziel und Ordner. Vorhandene Dateien werden nicht gelöscht." "Choose a destination and folders. Existing files are not deleted."
$descriptionLabel.AutoSize = $true
$descriptionLabel.ForeColor = $secondaryTextColor
$descriptionLabel.Location = New-Object System.Drawing.Point(30, 52)
$form.Controls.Add($descriptionLabel)

$helpButton = New-Object System.Windows.Forms.Button
$helpButton.Text = L "Hilfe" "Help"
$helpButton.Location = New-Object System.Drawing.Point(398, 12)
$helpButton.Size = New-Object System.Drawing.Size(64, 36)
$helpButton.Anchor = 'Top, Right'
$helpButton.BackColor = $surfaceColor
$helpButton.FlatStyle = 'Flat'
$helpButton.FlatAppearance.BorderSize = 1
$helpButton.FlatAppearance.BorderColor = $buttonBorderColor
$helpButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$helpButton.TabIndex = 2
$form.Controls.Add($helpButton)

# Der Modus-Umschalter liegt auf einer eigenen umrahmten Flaeche, damit er
# sich vom Formularhintergrund abhebt und nicht gedrungen wirkt. Breite und
# Position ergeben sich aus der Textlaenge der jeweiligen Sprache.
$modePanel = New-Object System.Windows.Forms.Panel
$modePanel.BackColor = $surfaceColor
$modePanel.Anchor = 'Top, Right'
$modePanel.Add_Paint({
    param($sender, $eventArgs)
    $borderPen = New-Object System.Drawing.Pen($buttonBorderColor)
    try {
        $eventArgs.Graphics.DrawRectangle($borderPen, 0, 0, $sender.ClientSize.Width - 1, $sender.ClientSize.Height - 1)
    } finally { $borderPen.Dispose() }
})
$form.Controls.Add($modePanel)

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
$modePanel.Location = New-Object System.Drawing.Point((690 - $modePanel.Width), 12)
$helpButton.Location = New-Object System.Drawing.Point(($modePanel.Left - $helpButton.Width - 8), $modePanel.Top)
$targetSurface = New-SurfacePanel -Location (New-Object System.Drawing.Point(14, 86)) -Size (New-Object System.Drawing.Size(692, 92))

$driveLabel = New-Object System.Windows.Forms.Label
$driveLabel.Text = L "Ziellaufwerk:" "Destination drive:"
$driveLabel.AutoSize = $true
$driveLabel.Font = New-Object System.Drawing.Font($semiboldFontName, 9.5)
$driveLabel.Location = New-Object System.Drawing.Point(30, 104)
$driveLabel.BackColor = $surfaceColor
$form.Controls.Add($driveLabel)

$driveCombo = New-Object System.Windows.Forms.ComboBox
$driveCombo.DropDownStyle = "DropDownList"
$driveCombo.Location = New-Object System.Drawing.Point(145, 98)
$driveCombo.Size = New-Object System.Drawing.Size(434, 27)
$driveCombo.Anchor = "Top, Left, Right"
$driveCombo.TabIndex = 3
$form.Controls.Add($driveCombo)

$driveToolTip = New-Object System.Windows.Forms.ToolTip

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = L "Aktualisieren" "Refresh"
$refreshButton.Location = New-Object System.Drawing.Point(587, 98)
$refreshButton.Size = New-Object System.Drawing.Size(103, 27)
$refreshButton.BackColor = $surfaceColor
$refreshButton.FlatStyle = 'Flat'
$refreshButton.FlatAppearance.BorderColor = $buttonBorderColor
$refreshButton.Anchor = "Top, Right"
$refreshButton.TabIndex = 4
$form.Controls.Add($refreshButton)

$driveInfoLabel = New-Object System.Windows.Forms.Label
$driveInfoLabel.AutoSize = $true
$driveInfoLabel.ForeColor = $secondaryTextColor
$driveInfoLabel.Location = New-Object System.Drawing.Point(30, 133)
$driveInfoLabel.BackColor = $surfaceColor
$form.Controls.Add($driveInfoLabel)

$healthPanel = New-Object System.Windows.Forms.Panel
$healthPanel.Location = New-Object System.Drawing.Point(180, 129)
$healthPanel.Size = New-Object System.Drawing.Size(510, 25)
$healthPanel.Anchor = 'Top, Left, Right'
$healthPanel.BackColor = $surfaceColor
$form.Controls.Add($healthPanel)

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
$healthLabel.Size = New-Object System.Drawing.Size(462, 21)
$healthLabel.Anchor = 'Top, Left, Right'
$healthLabel.Text = L 'Keine Sicherung für dieses Profil' 'No backup for this profile'
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
    $health = Get-BackupHealth -Drive $disk.DeviceID
    $healthDot.Tag = switch ($health.Level) {
        'Green' { [System.Drawing.Color]::FromArgb(16, 124, 16) }
        'Yellow' { [System.Drawing.Color]::FromArgb(202, 143, 0) }
        default { [System.Drawing.Color]::FromArgb(196, 43, 28) }
    }
    $healthLabel.Text = $health.Text
    $healthLabel.ForeColor = if ($health.Level -eq 'Red') { [System.Drawing.Color]::FromArgb(153, 27, 27) } else { $secondaryTextColor }
    $healthToolTip.SetToolTip($healthPanel, $health.Details)
    $healthToolTip.SetToolTip($healthLabel, $health.Details)
    $healthToolTip.SetToolTip($healthDot, $health.Details)
    $healthPanel.Visible = $true
    $healthDot.Invalidate()
}

$fat32Label = New-Object System.Windows.Forms.Label
$fat32Label.Text = L "Hinweis: FAT32 kann keine Dateien über 4 GB speichern. exFAT oder NTFS wird empfohlen." "FAT32 cannot store files of 4 GB or larger. exFAT or NTFS is recommended."
$fat32Label.ForeColor = [System.Drawing.Color]::FromArgb(128, 72, 0)
$fat32Label.BackColor = [System.Drawing.Color]::FromArgb(255, 247, 224)
$fat32Label.AutoSize = $false
$fat32Label.TextAlign = 'MiddleLeft'
$fat32Label.Location = New-Object System.Drawing.Point(30, 129)
$fat32Label.Size = New-Object System.Drawing.Size(660, 25)
$fat32Label.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
$fat32Label.Visible = $false
$form.Controls.Add($fat32Label)

$folderSurface = New-SurfacePanel -Location (New-Object System.Drawing.Point(14, 186)) -Size (New-Object System.Drawing.Size(692, 224))

$libraryLabel = New-Object System.Windows.Forms.Label
$libraryLabel.Text = L "Diese Ordner werden gesichert:" "These folders will be backed up:"
$libraryLabel.AutoSize = $true
$libraryLabel.Font = New-Object System.Drawing.Font($semiboldFontName, 9.5)
$libraryLabel.Location = New-Object System.Drawing.Point(30, 195)
$libraryLabel.BackColor = $surfaceColor
$form.Controls.Add($libraryLabel)
$libraryList = New-Object System.Windows.Forms.CheckedListBox
# Die Ordnernamen sind kurz; eine schmale, dafuer hoehere Liste zeigt alle
# Eintraege ohne Scrollbalken. Alle/Keine und der Auswahlzaehler nutzen den
# frei gewordenen Platz rechts daneben.
$libraryList.Location = New-Object System.Drawing.Point(30, 218)
$libraryList.Size = New-Object System.Drawing.Size(340, 184)
$libraryList.Anchor = "Top, Left"
$libraryList.CheckOnClick = $true
$libraryList.BackColor = [System.Drawing.Color]::White
$libraryList.TabIndex = 5
$form.Controls.Add($libraryList)

foreach ($folder in Get-LibraryDefinitions) {
    $item = New-FolderListItem -Name $folder.Name -DisplayName (Get-M24FolderDisplayName $folder.Name $script:isGerman) -Path $folder.Path -IsCustom $false -Checked $true
    [void]$libraryList.Items.Add($item, $true)
}

$allButton = New-Object System.Windows.Forms.Button
$allButton.Text = L "Alle" "All"
$allButton.Location = New-Object System.Drawing.Point(384, 218)
$allButton.Size = New-Object System.Drawing.Size(50, 27)
$allButton.FlatStyle = 'Flat'
$allButton.FlatAppearance.BorderSize = 1
$allButton.FlatAppearance.BorderColor = $buttonBorderColor
$allButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$allButton.BackColor = $surfaceColor
$allButton.TabIndex = 6
$form.Controls.Add($allButton)

$noneButton = New-Object System.Windows.Forms.Button
$noneButton.Text = L "Keine" "None"
$noneButton.Location = New-Object System.Drawing.Point(440, 218)
$noneButton.Size = New-Object System.Drawing.Size(50, 27)
$noneButton.FlatStyle = 'Flat'
$noneButton.FlatAppearance.BorderSize = 1
$noneButton.FlatAppearance.BorderColor = $buttonBorderColor
$noneButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$noneButton.BackColor = $surfaceColor
$noneButton.TabIndex = 7
$form.Controls.Add($noneButton)

$addFolderButton = New-Object System.Windows.Forms.Button
$addFolderButton.Text = L "Hinzufügen" "Add folder"
$addFolderButton.Location = New-Object System.Drawing.Point(384, 255)
$addFolderButton.Size = New-Object System.Drawing.Size(106, 27)
$addFolderButton.TextAlign = 'MiddleCenter'
$addFolderButton.FlatStyle = 'Flat'
$addFolderButton.FlatAppearance.BorderSize = 1
$addFolderButton.FlatAppearance.BorderColor = $buttonBorderColor
$addFolderButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$addFolderButton.BackColor = $surfaceColor
$addFolderButton.TabIndex = 8
$form.Controls.Add($addFolderButton)

$removeFolderButton = New-Object System.Windows.Forms.Button
$removeFolderButton.Text = L "Entfernen" "Remove"
$removeFolderButton.Location = New-Object System.Drawing.Point(384, 292)
$removeFolderButton.Size = New-Object System.Drawing.Size(106, 27)
$removeFolderButton.FlatStyle = 'Flat'
$removeFolderButton.FlatAppearance.BorderSize = 1
$removeFolderButton.FlatAppearance.BorderColor = $buttonBorderColor
$removeFolderButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$removeFolderButton.BackColor = $surfaceColor
$removeFolderButton.Enabled = $false
$removeFolderButton.TabIndex = 9
$form.Controls.Add($removeFolderButton)

$historyButton = New-Object System.Windows.Forms.Button
$historyButton.Text = L 'Verlauf' 'History'
$historyButton.Location = New-Object System.Drawing.Point(384, 329)
$historyButton.Size = New-Object System.Drawing.Size(106, 27)
$historyButton.FlatStyle = 'Flat'
$historyButton.FlatAppearance.BorderColor = $buttonBorderColor
$historyButton.BackColor = $surfaceColor
$historyButton.Enabled = $false
$historyButton.TabIndex = 10
$form.Controls.Add($historyButton)

$verifyButton = New-Object System.Windows.Forms.Button
$verifyButton.Text = L 'Backup prüfen' 'Verify backup'
$verifyButton.Location = New-Object System.Drawing.Point(384, 366)
$verifyButton.Size = New-Object System.Drawing.Size(106, 27)
$verifyButton.FlatStyle = 'Flat'
$verifyButton.FlatAppearance.BorderColor = $buttonBorderColor
$verifyButton.BackColor = $surfaceColor
$verifyButton.Enabled = $false
$verifyButton.TabIndex = 11
$form.Controls.Add($verifyButton)

$deleteBackupButton = New-Object System.Windows.Forms.Button
$deleteBackupButton.Text = L 'Backup löschen' 'Delete backup'
$deleteBackupButton.Location = New-Object System.Drawing.Point(503, 366)
$deleteBackupButton.Size = New-Object System.Drawing.Size(187, 27)
$deleteBackupButton.FlatStyle = 'Flat'
$deleteBackupButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(164, 38, 44)
$deleteBackupButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(253, 239, 240)
$deleteBackupButton.BackColor = $surfaceColor
$deleteBackupButton.ForeColor = [System.Drawing.Color]::FromArgb(164, 38, 44)
$deleteBackupButton.Enabled = $false
$deleteBackupButton.TabIndex = 12
$form.Controls.Add($deleteBackupButton)

# Das Logo nutzt den freien Bereich rechts neben Ordnerliste und Buttons
# in voller Hoehe von Beschriftung und Liste.
# Es ist optional: Fehlt die Datei, bleibt die Flaeche einfach leer.
$logoBox = New-Object System.Windows.Forms.PictureBox
$logoBox.Location = New-Object System.Drawing.Point(503, 195)
$logoBox.Size = New-Object System.Drawing.Size(187, 164)
$logoBox.SizeMode = 'Zoom'
$logoBox.BackColor = $surfaceColor
$logoBox.Anchor = 'Top, Right'
if (Test-Path -LiteralPath $logoFile -PathType Leaf) {
    # Ueber einen Stream laden und in ein unabhaengiges Bitmap kopieren,
    # damit die Datei nicht fuer die Prozesslaufzeit gesperrt bleibt.
    try {
        $logoStream = New-Object System.IO.FileStream($logoFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
        try {
            $logoSource = [System.Drawing.Image]::FromStream($logoStream)
            try {
                $logoBox.Image = New-Object System.Drawing.Bitmap($logoSource)
            } finally { $logoSource.Dispose() }
        } finally { $logoStream.Dispose() }
    } catch {}
}
$form.Controls.Add($logoBox)

# Kurze Bezeichnungen halten alle vier Optionen in einer Zeile; ausfuehrliche
# Erklaerungen stehen bei den nicht selbsterklaerenden Modi im Tooltip.
$optionsSurface = New-SurfacePanel -Location (New-Object System.Drawing.Point(14, 418)) -Size (New-Object System.Drawing.Size(692, 34))

$dryRunCheckBox = New-Object System.Windows.Forms.CheckBox
$dryRunCheckBox.Text = L "Simulation" "Dry run"
$dryRunCheckBox.AutoSize = $true
$dryRunCheckBox.Location = New-Object System.Drawing.Point(30, 426)
$dryRunCheckBox.BackColor = $surfaceColor
$dryRunCheckBox.TabIndex = 12
$form.Controls.Add($dryRunCheckBox)
$ejectCheckBox = New-Object System.Windows.Forms.CheckBox
$ejectCheckBox.Text = L "Nach Erfolg auswerfen" "Eject after success"
$ejectCheckBox.AutoSize = $true
$ejectCheckBox.Location = New-Object System.Drawing.Point(155, 426)
$ejectCheckBox.BackColor = $surfaceColor
$ejectCheckBox.TabIndex = 13
$form.Controls.Add($ejectCheckBox)

$checksumCheckBox = New-Object System.Windows.Forms.CheckBox
$checksumCheckBox.Text = L "Prüfsummen" "Checksums"
$checksumCheckBox.AutoSize = $true
$checksumCheckBox.Location = New-Object System.Drawing.Point(385, 426)
$checksumCheckBox.BackColor = $surfaceColor
$checksumCheckBox.Checked = $true
$checksumCheckBox.TabIndex = 14
$checksumCheckBox.Anchor = "Top, Right"
$form.Controls.Add($checksumCheckBox)

$superFastCheckBox = New-Object System.Windows.Forms.CheckBox
$superFastCheckBox.Text = L "Superschnell" "Super fast"
$superFastCheckBox.AutoSize = $true
$superFastCheckBox.Location = New-Object System.Drawing.Point(535, 426)
$superFastCheckBox.BackColor = $surfaceColor
$superFastCheckBox.TabIndex = 15
$form.Controls.Add($superFastCheckBox)
$optionsToolTip = New-Object System.Windows.Forms.ToolTip
$optionsToolTip.AutoPopDelay = 20000
$optionsToolTip.SetToolTip($superFastCheckBox, (L `
    "Maximale Geschwindigkeit: keine Datei-Vorprüfung, keine Speicherplatz- und 4-GB-Dateiprüfung, keine Prüfsummenaktualisierung, keine BitLocker-Abfrage, keine Kopierwiederholungen. Fehler (z. B. volles Ziel) fallen ggf. erst beim Kopieren auf." `
    "Maximum speed: no file preflight, no disk-space or 4 GB file check, no checksum update, no BitLocker query, no copy retries. Errors (e.g. a full destination) may only surface while copying."))
$activitySurface = New-SurfacePanel -Location (New-Object System.Drawing.Point(14, 460)) -Size (New-Object System.Drawing.Size(692, 148))

$statusCaption = New-Object System.Windows.Forms.Label
$statusCaption.Text = "Status:"
$statusCaption.AutoSize = $true
$statusCaption.Font = New-Object System.Drawing.Font($semiboldFontName, 9.5)
$statusCaption.Location = New-Object System.Drawing.Point(30, 470)
$statusCaption.BackColor = $surfaceColor
$form.Controls.Add($statusCaption)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = L "Bereit." "Ready."
$statusLabel.AutoEllipsis = $true
$statusLabel.Location = New-Object System.Drawing.Point(82, 470)
$statusLabel.Size = New-Object System.Drawing.Size(480, 22)
$statusLabel.BackColor = $surfaceColor
$statusLabel.Anchor = "Top, Left, Right"
$form.Controls.Add($statusLabel)

$durationCaption = New-Object System.Windows.Forms.Label
$durationCaption.Text = L "Dauer:" "Elapsed:"
$durationCaption.AutoSize = $true
$durationCaption.Font = New-Object System.Drawing.Font($semiboldFontName, 9.5)
$durationCaption.Location = New-Object System.Drawing.Point(574, 470)
$durationCaption.BackColor = $surfaceColor
$durationCaption.Anchor = "Top, Right"
$form.Controls.Add($durationCaption)

$durationLabel = New-Object System.Windows.Forms.Label
$durationLabel.Text = "--:--"
$durationLabel.Location = New-Object System.Drawing.Point(632, 470)
$durationLabel.Size = New-Object System.Drawing.Size(58, 22)
$durationLabel.TextAlign = 'TopRight'
$durationLabel.BackColor = $surfaceColor
$durationLabel.Anchor = "Top, Right"
$form.Controls.Add($durationLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(30, 496)
$progressBar.Size = New-Object System.Drawing.Size(660, 8)
$progressBar.Anchor = "Top, Left, Right"
$progressBar.Style = "Blocks"
$progressBar.MarqueeAnimationSpeed = 0
$form.Controls.Add($progressBar)

$resultLabel = New-Object System.Windows.Forms.Label
$resultLabel.Text = L "Ergebnisübersicht:" "Summary:"
$resultLabel.AutoSize = $true
$resultLabel.Font = New-Object System.Drawing.Font($semiboldFontName, 9.5)
$resultLabel.Location = New-Object System.Drawing.Point(30, 512)
$resultLabel.BackColor = $surfaceColor
$form.Controls.Add($resultLabel)

$resultBox = New-Object System.Windows.Forms.TextBox
$resultBox.Location = New-Object System.Drawing.Point(30, 532)
$resultBox.Size = New-Object System.Drawing.Size(660, 64)
$resultBox.Anchor = "Top, Left, Right"
$resultBox.Multiline = $true
$resultBox.ReadOnly = $true
$resultBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$resultBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$resultBox.BackColor = $surfaceColor
$resultBox.TabStop = $false
$script:resultSummary = L "Noch keine Sicherung ausgeführt." "No backup has been run yet."
$resultBox.Text = $script:resultSummary
$form.Controls.Add($resultBox)

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

$footerSurface = New-SurfacePanel -Location (New-Object System.Drawing.Point(0, 616)) -Size (New-Object System.Drawing.Size(720, 82)) -Anchor 'Top, Left, Right'

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = L "Sicherung starten" "Start backup"
$startButton.Location = New-Object System.Drawing.Point(30, 636)
$startButton.Size = New-Object System.Drawing.Size(175, 40)
$startButton.BackColor = $accentColor
$startButton.ForeColor = $accentTextColor
$startButton.FlatStyle = "Flat"
$startButton.FlatAppearance.BorderSize = 0
$startButton.FlatAppearance.MouseOverBackColor = $accentHoverColor
$startButton.Font = New-Object System.Drawing.Font($semiboldFontName, 10)
$startButton.Anchor = "Top, Left"
$startButton.TabIndex = 16
$form.Controls.Add($startButton)
$form.AcceptButton = $startButton

$logButton = New-Object System.Windows.Forms.Button
$logButton.Text = L "Protokoll öffnen" "Open log"
$logButton.Location = New-Object System.Drawing.Point(213, 636)
$logButton.Size = New-Object System.Drawing.Size(145, 40)
$logButton.BackColor = [System.Drawing.Color]::White
$logButton.FlatStyle = "Flat"
$logButton.FlatAppearance.BorderSize = 1
$logButton.FlatAppearance.BorderColor = $buttonBorderColor
$logButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$logButton.Font = New-Object System.Drawing.Font($semiboldFontName, 10)
$logButton.Enabled = $false
$logButton.Anchor = "Top, Left"
$logButton.TabIndex = 17
$form.Controls.Add($logButton)

$closeButton = New-Object System.Windows.Forms.Button
$destinationButton = New-Object System.Windows.Forms.Button
$destinationButton.Text = L "Sicherungsordner öffnen" "Open backup folder"
$destinationButton.Location = New-Object System.Drawing.Point(366, 636)
$destinationButton.Size = New-Object System.Drawing.Size(181, 40)
$destinationButton.BackColor = [System.Drawing.Color]::White
$destinationButton.FlatStyle = "Flat"
$destinationButton.FlatAppearance.BorderSize = 1
$destinationButton.FlatAppearance.BorderColor = $buttonBorderColor
$destinationButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$destinationButton.Font = New-Object System.Drawing.Font($semiboldFontName, 10)
$destinationButton.Enabled = $false
$destinationButton.Anchor = "Top, Left"
$destinationButton.TabIndex = 18
$form.Controls.Add($destinationButton)

$closeButton.Text = L "Schließen" "Close"
$closeButton.Location = New-Object System.Drawing.Point(555, 636)
$closeButton.Size = New-Object System.Drawing.Size(135, 40)
$closeButton.BackColor = [System.Drawing.Color]::White
$closeButton.FlatStyle = "Flat"
$closeButton.FlatAppearance.BorderSize = 1
$closeButton.FlatAppearance.BorderColor = $buttonBorderColor
$closeButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$closeButton.Font = New-Object System.Drawing.Font($semiboldFontName, 10)
$closeButton.TabIndex = 19
$closeButton.Anchor = "Top, Right"
$form.Controls.Add($closeButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = L "Sicherung abbrechen" "Cancel backup"
$cancelButton.Location = New-Object System.Drawing.Point(30, 636)
$cancelButton.Size = New-Object System.Drawing.Size(175, 40)
$cancelButton.BackColor = [System.Drawing.Color]::White
$cancelButton.ForeColor = [System.Drawing.Color]::FromArgb(164, 38, 44)
$cancelButton.FlatStyle = "Flat"
$cancelButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(164, 38, 44)
$cancelButton.FlatAppearance.BorderSize = 1
$cancelButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(253, 239, 240)
$cancelButton.Font = New-Object System.Drawing.Font($semiboldFontName, 10)
# Der Abbrechen-Button ersetzt den Start-Button an derselben Position und
# muss deshalb auch gleich verankert sein.
$cancelButton.Anchor = "Top, Left"
$cancelButton.TabIndex = 16
$cancelButton.Visible = $false
$form.Controls.Add($cancelButton)

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
    foreach ($control in @($startButton, $driveCombo, $refreshButton, $backupRadio, $restoreRadio, $libraryList, $allButton, $noneButton, $historyButton, $logButton, $destinationButton, $deleteBackupButton, $closeButton)) {
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
    $selectionLine = if ($script:isGerman) {
        if ($count -eq 1) { "1 Ordner ausgewählt." } else { "$count Ordner ausgewählt." }
    } else {
        if ($count -eq 1) { "1 folder selected." } else { "$count folders selected." }
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
    $startButton.Enabled = ($count -gt 0 -and $null -ne $driveCombo.SelectedItem -and -not $script:backupProcess -and -not $script:pendingEjectDrive -and -not $script:verificationAsyncResult)
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
    Update-SelectionState
}

function Update-LibraryList {
    $libraryList.Items.Clear()
    $items = @()
    if ($restoreRadio.Checked) {
        if ($driveCombo.SelectedItem) {
            $disk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
            $backupRoot = Get-BackupRoot -Drive $disk.DeviceID
            $items += @(Get-LibraryDefinitions -IncludeMissing | Where-Object { Test-Path -LiteralPath (Join-Path $backupRoot $_.Name) -PathType Container } | ForEach-Object {
                $checked = if ($script:folderCheckStates.ContainsKey([string]$_.Name)) { [bool]$script:folderCheckStates[[string]$_.Name] } else { $true }
                New-FolderListItem -Name $_.Name -DisplayName (Get-M24FolderDisplayName $_.Name $script:isGerman) -Path $_.Path -IsCustom $false -Checked $checked
            })
            $items += @(Get-RestoreCustomFolders -BackupRoot $backupRoot)
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
    Update-BackupOptionState
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

    # Waehrend eines aktiven Retry-Backoffs nach einem Erkennungsfehler wird
    # nur automatisch uebersprungen; eine ausdrueckliche Aktualisierung
    # (-Force) fragt immer sofort ab.
    if (-not $Force -and [DateTime]::UtcNow -lt $script:driveRetryAfterUtc) {
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
        $drives = @(Get-CimInstance Win32_LogicalDisk -OperationTimeoutSec 8 -ErrorAction Stop |
            Where-Object { $_.DriveType -in 2, 3 -and $_.DeviceID -ne $systemDrive -and $_.Size -gt 0 } |
            Sort-Object DriveType, DeviceID)

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
    if ($backupRadio.Checked) { Update-LibraryList; Update-BackupOptionState; Update-BackupHealth }
})
$restoreRadio.Add_CheckedChanged({
    if ($restoreRadio.Checked) { Update-BackupSelectionSnapshot -CaptureCurrentList; Update-LibraryList; Update-BackupOptionState; Update-BackupHealth }
})
$dryRunCheckBox.Add_CheckedChanged({ Update-BackupOptionState })
$superFastCheckBox.Add_CheckedChanged({ Update-BackupOptionState })

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
    if ($libraryList.CheckedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show((L "Bitte wählen Sie mindestens einen Ordner aus." "Please select at least one folder."), $form.Text, "OK", "Warning") | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $coreScript)) {
        [System.Windows.Forms.MessageBox]::Show(((L "Das Sicherungsskript wurde nicht gefunden:`r`n{0}" "The backup script was not found:`r`n{0}") -f $coreScript), (L "Fehler" "Error"), "OK", "Error") | Out-Null
        return
    }

    $disk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
    if ($backupRadio.Checked -and $disk.M24KnownMatchAmbiguous) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            (L 'Mehrere angeschlossene Laufwerke passen zur gespeicherten Laufwerkskennung. Aus Sicherheitsgründen wurde keines automatisch als bekannt akzeptiert. Haben Sie die Auswahl geprüft und möchten trotzdem fortfahren?' 'Multiple connected drives match the saved drive identity. For safety, none was accepted automatically. Have you verified the selection and still want to continue?'),
            (L 'Laufwerk nicht eindeutig' 'Ambiguous drive identity'), 'YesNo', 'Warning')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    $artifactCacheKey = "{0}|{1}" -f $disk.DeviceID, (Get-NormalizedVolumeSerial -Disk $disk)
    [void]$script:artifactCache.Remove($artifactCacheKey)
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
    $script:lastLogDir = Join-Path (Get-BackupRoot -Drive $drive) '_logs'
    $script:lastLogFile = $null
    $script:lastDestination = Get-BackupRoot -Drive $drive
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
        L "Superschnelle Sicherung ohne Vorprüfung wird gestartet ..." "Starting super fast backup without preflight checks ..."
    } else {
        L "Vorprüfung wird gestartet ..." "Starting preflight checks ..."
    }
    $statusLabel.ForeColor = [System.Drawing.SystemColors]::ControlText
    $statusLabel.Text = if ($restoreRadio.Checked) {
        L "Wiederherstellung wird geprüft ..." "Checking restore ..."
    } elseif ($script:activeDryRun) {
        L "Simulation wird gestartet ..." "Starting simulation ..."
    } elseif ($script:activeSuperFast) {
        L "Superschnelle Sicherung wird gestartet ..." "Starting super fast backup ..."
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
        if ($mode -eq 'Restore') { $argumentList += @('-RestoreIntegrityPolicy', 'Verify') }
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
        $libraryList.Enabled = $true
        $allButton.Enabled = $true
        $noneButton.Enabled = $true
        Update-BackupOptionState
        $closeButton.Visible = $true
        $startButton.Visible = $true
        $cancelButton.Visible = $false
        $form.AcceptButton = $startButton
        $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
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
                                $message = if ($script:isGerman) {
                                    "Konfliktvorschau:`r`n`r`nFehlende Dateien: $($preview.MissingFiles)`r`nLokale Dateien, die ersetzt werden: $($preview.OverwriteFiles)`r`nNeuere lokale Dateien, die geschützt bleiben: $($preview.ProtectedNewerFiles)`r`nZu kopieren: $($preview.PlannedFiles) Dateien / $previewGb GB`r`n`r`n$integrityText$exampleText`r`n`r`nWiederherstellung jetzt starten?"
                                } else {
                                    "Conflict preview:`r`n`r`nMissing files: $($preview.MissingFiles)`r`nLocal files to be replaced: $($preview.OverwriteFiles)`r`nNewer local files that remain protected: $($preview.ProtectedNewerFiles)`r`nTo be copied: $($preview.PlannedFiles) files / $previewGb GB`r`n`r`n$integrityText$exampleText`r`n`r`nStart the restore now?"
                                }
                                $answer = [System.Windows.Forms.MessageBox]::Show($message, (L "Wiederherstellung prüfen" "Review restore"), "YesNo", "Warning")
                                if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                                    $approvalValue = if (-not $manifestExists) {
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
            $statusLabel.ForeColor = [System.Drawing.Color]::DarkOrange
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
            $deleteBackupButton.Enabled = $destinationButton.Enabled

            $resultCancellationReason = if ($result -and $result.PSObject.Properties['CancellationReason']) { [string]$result.CancellationReason } else { $null }
            $operationWasCancelled = $script:backupCancelled -or ($result -and $result.PSObject.Properties['Cancelled'] -and [bool]$result.Cancelled)
            if ($operationWasCancelled) {
                $statusLabel.ForeColor = [System.Drawing.Color]::DarkOrange
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
                $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
                $statusLabel.Text = L "Worker ohne Ergebnis beendet." "Worker exited without a result."
                $resultBox.Text = L "Der Hintergrundprozess wurde beendet, hat aber keine Ergebnisdatei geschrieben. Bitte prüfen Sie das Protokoll und starten Sie den Vorgang erneut." "The background process exited but did not write a result file. Review the log and run the operation again."
            } elseif ($exitCode -eq 0) {
                $elapsed = (Get-Date) - $script:backupStartedAt
                $duration = Format-ElapsedDuration $elapsed
                $statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
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
                if ($script:activeMode -eq 'Backup' -and -not $isDryRun -and $script:activeDrive) {
                    try {
                        Save-KnownBackupDrive -Disk $script:activeDrive
                        $driveToolTip.SetToolTip($driveCombo, (L 'Dieses Laufwerk ist jetzt als bekanntes Sicherungslaufwerk gespeichert.' 'This drive is now remembered as the backup drive.'))
                    } catch {
                        [System.Windows.Forms.MessageBox]::Show(
                            ((L "Die Sicherung war erfolgreich, das Laufwerk konnte aber nicht für die automatische Wiedererkennung gespeichert werden:`r`n{0}" "The backup succeeded, but the drive could not be saved for automatic recognition:`r`n{0}") -f $_.Exception.Message),
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
                $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
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
        $kind = if ($_.BaseName -like 'restore_*') { L 'Wiederherstellung' 'Restore' } else { L 'Sicherung' 'Backup' }
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
    $dialog.ClientSize = New-Object System.Drawing.Size(560, 190)
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
    $dialog.Controls.Add($confirmationInput)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = L 'Abbrechen' 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(311, 143)
    $cancel.Size = New-Object System.Drawing.Size(95, 31)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)
    $dialog.CancelButton = $cancel

    $confirm = New-Object System.Windows.Forms.Button
    $confirm.Text = L 'Endgültig löschen' 'Delete permanently'
    $confirm.Location = New-Object System.Drawing.Point(412, 143)
    $confirm.Size = New-Object System.Drawing.Size(130, 31)
    $confirm.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $confirm.Enabled = $false
    $confirm.ForeColor = [System.Drawing.Color]::FromArgb(164, 38, 44)
    $dialog.Controls.Add($confirm)

    $confirmationInput.Add_TextChanged({
        # Statische Equals-Variante verwenden: WinForms kann beim Schließen
        # noch ein TextChanged-Ereignis mit bereits freigegebenem Textwert
        # zustellen. Das darf keine unbehandelte Null-Ausnahme auslösen.
        $confirm.Enabled = [string]::Equals([string]$confirmationInput.Text, [string]$Info.ConfirmationText, [System.StringComparison]::Ordinal)
        $dialog.AcceptButton = if ($confirm.Enabled) { $confirm } else { $null }
    })

    try {
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
    $resultLine = if (Test-Path -LiteralPath $metadataFile -PathType Leaf) {
        Get-Content -LiteralPath $metadataFile -ErrorAction SilentlyContinue | Where-Object { $_ -like 'Ergebnis:*' } | Select-Object -Last 1
    }
    if (-not $resultLine -or $resultLine -notmatch '^Ergebnis:\s*Erfolgreich abgeschlossen') {
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
        $dataFolders = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop | Where-Object { -not $_.Name.StartsWith('_') })
        if ($dataFolders.Count -eq 0) {
            return [pscustomobject]@{ Initialized = $initialize; Files = 0; Bytes = 0; ErrorCount = 1; Errors = @($missingFoldersMessage) }
        }
        $folders = @($dataFolders | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.FullName } })
        $excluded = @(Get-M24DefaultExcludedFiles)
        $lockFile = Join-Path $root '_backup.lock'; $lockStream = $null; $lockAcquired = $false
        try {
            $lockStream = [System.IO.File]::Open($lockFile, 'OpenOrCreate', 'ReadWrite', 'None'); $lockAcquired = $true
            if ($initialize) {
                $created = Update-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles $excluded -ForceRehash `
                    -CancelCallback { Test-Path -LiteralPath $cancelFile }
                return [pscustomobject]@{ Initialized = $true; Cancelled = $created.Cancelled; Files = $created.Files; Bytes = $created.Bytes; ErrorCount = 0; Errors = @() }
            }
            $checked = Test-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles $excluded `
                -CancelCallback { Test-Path -LiteralPath $cancelFile }
            if (-not $checked.Cancelled -and [int]$checked.ErrorCount -eq 0) {
                # Erfolgreiche Vollpruefung in den Metadaten vermerken; die
                # Restore-Vorschau zeigt diesen Stand als Integritaetsstatus an.
                Set-M24ChecksumVerifiedMetadata -MetadataFile (Join-Path $root '_Sicherungsinfo.txt')
            }
            return [pscustomobject]@{ Initialized = $false; Cancelled = $checked.Cancelled; Files = $checked.Files; Bytes = $checked.Bytes; ErrorCount = $checked.ErrorCount; Errors = @($checked.Errors) }
        } finally {
            if ($lockStream) { $lockStream.Dispose() }
            if ($lockAcquired) { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
        }
    }
    $script:verificationPowerShell = [System.Management.Automation.PowerShell]::Create()
    [void]$script:verificationPowerShell.AddScript($verificationScript.ToString()).AddArgument($script:lastDestination).AddArgument($sharedScript).AddArgument($manifestPath).AddArgument($initializeManifest).AddArgument($script:verificationCancelFile).AddArgument((L 'Keine Sicherungsordner mit Nutzdaten gefunden.' 'No backup data folders were found.'))
    $script:verificationAsyncResult = $script:verificationPowerShell.BeginInvoke()
    $verificationTimer.Start()
})

$destinationButton.Add_Click({
    if ($script:lastDestination -and (Test-Path -LiteralPath $script:lastDestination)) {
        Start-Process -FilePath "explorer.exe" -ArgumentList $script:lastDestination
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
    $statusLabel.ForeColor = [System.Drawing.Color]::DarkOrange
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
    try { Save-FolderSelection } catch {}
})

# Beim Start liegt der Fokus auf "Sicherung starten", damit die Sicherung
# direkt mit Enter beginnen kann.
$form.Add_Shown({
    $script:mainWindowShown = $true
    $driveWatchTimer.Start()
    if ($startButton.Enabled) { $startButton.Select() }
})

# WinForms kann die Z-Reihenfolge von Panels bei der ersten echten Anzeige
# anders behandeln als DrawToBitmap. Die dekorativen Flächen muessen deshalb
# ausdruecklich hinter allen interaktiven Steuerelementen liegen.
foreach ($surface in @($targetSurface, $folderSurface, $optionsSurface, $activitySurface, $footerSurface)) {
    $surface.SendToBack()
}

# Verwaiste Kommunikationsdateien frueherer Sitzungen (aelter als sieben
# Tage) still entfernen, bevor diese Instanz eigene Dateien anlegt. Frische
# Dateien koennen einer zweiten GUI-Instanz oder einem noch laufenden Worker
# gehoeren und bleiben deshalb unangetastet. Die Funktion faengt alle Fehler
# selbst ab und darf den Start nicht beeinflussen.
Remove-M24StaleTempArtifacts

Set-StartupSplashStatus (L 'Einstellungen werden geladen ...' 'Loading settings ...')
$script:settings = Get-AppSettings
$script:knownDrive = Get-KnownBackupDrive
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

# Auf Bildschirmen mit wenig Arbeitshoehe startet das Fenster verkleinert;
# der Inhalt ist dann ueber die Bildlaufleiste erreichbar.
$workingArea = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
if ($form.Height -gt $workingArea.Height) {
    $form.Height = $workingArea.Height
}

# Der Splash muss vor ShowDialog vollstaendig geschlossen sein. Andernfalls
# kann WinForms das modale Hauptfenster implizit dem noch aktiven Splash als
# Owner zuordnen; dessen Schliessen wuerde dann auch die Haupt-GUI schliessen.
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
    if ($logoBox -and $logoBox.Image) { try { $logoBox.Image.Dispose() } catch {} }
    if ($notifyIcon) { try { $notifyIcon.Visible = $false; $notifyIcon.Dispose() } catch {} }
    foreach ($resource in @($appIcon, $healthToolTip, $driveToolTip, $optionsToolTip, $resultContextMenu, $timer, $driveWatchTimer, $ejectTimer, $notificationTimer, $verificationTimer, $deletionTimer)) {
        if ($resource) { try { $resource.Dispose() } catch {} }
    }
    if ($form) { try { $form.Dispose() } catch {} }
    Exit-M24SingleInstance -Handle $script:guiInstanceHandle
    $script:guiInstanceHandle = $null
}
if ($script:fatalGuiError) { exit 1 }
