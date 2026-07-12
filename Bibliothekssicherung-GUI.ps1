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

$script:isGerman = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'de'
function L {
    param([string]$German, [string]$English)
    if ($script:isGerman) { return $German }
    return $English
}

function Get-FolderDisplayName {
    param([string]$CanonicalName)
    if ($script:isGerman) { return $CanonicalName }
    $englishNames = @{
        'Desktop' = 'Desktop'; 'Dokumente' = 'Documents'; 'Downloads' = 'Downloads'
        'Bilder' = 'Pictures'; 'Musik' = 'Music'; 'Videos' = 'Videos'
        'Favoriten' = 'Favorites'; 'Gespeicherte Spiele' = 'Saved Games'; 'Kontakte' = 'Contacts'
    }
    if ($englishNames.ContainsKey($CanonicalName)) { return $englishNames[$CanonicalName] }
    return $CanonicalName
}

$installedFontNames = @([System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name })
$textFontName = if ($installedFontNames -contains 'Segoe UI Variable Text') { 'Segoe UI Variable Text' } else { 'Segoe UI' }
$semiboldFontName = if ($installedFontNames -contains 'Segoe UI Variable Text Semibold') { 'Segoe UI Variable Text Semibold' } else { 'Segoe UI Semibold' }
$displayFontName = if ($installedFontNames -contains 'Segoe UI Variable Display Semib') { 'Segoe UI Variable Display Semib' } else { 'Segoe UI Semibold' }

$coreScript = Join-Path $PSScriptRoot "Bibliothekssicherung.ps1"
$helpFile = Join-Path $PSScriptRoot $(if ($script:isGerman) { 'Hilfe-und-Info.txt' } else { 'Help-and-Info.txt' })
$versionFile = Join-Path $PSScriptRoot 'version.txt'
$appVersion = if (Test-Path -LiteralPath $versionFile -PathType Leaf) { (Get-Content -LiteralPath $versionFile -Raw).Trim() } else { '' }
$appIcon = $null
$script:backupProcess = $null
$script:statusFile = $null
$script:resultFile = $null
$script:cancelFile = $null
$script:previewFile = $null
$script:approvalFile = $null
$script:restorePreviewShown = $false
$script:scanWarningShown = $false
$script:lastLogDir = $null
$script:lastDestination = $null
$script:backupStartedAt = $null
$script:backupCancelled = $false
$script:driveMap = @{}
$script:activeDrive = $null
$script:activeMode = $null
$settingsDirectory = Join-Path $env:LOCALAPPDATA 'M24Backup'
$settingsFile = Join-Path $settingsDirectory 'settings.json'
$script:knownDrive = $null

function Get-UserShellFolder {
    param(
        [string]$Name,
        [string]$Fallback
    )

    $registryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    $value = (Get-ItemProperty -Path $registryPath -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($value) {
        return [Environment]::ExpandEnvironmentVariables($value)
    }
    return $Fallback
}

function Get-LibraryNames {
    param([switch]$IncludeMissing)
    $folders = @(
        [pscustomobject]@{ Name = "Desktop"; Path = [Environment]::GetFolderPath("Desktop") },
        [pscustomobject]@{ Name = "Dokumente"; Path = [Environment]::GetFolderPath("MyDocuments") },
        [pscustomobject]@{ Name = "Downloads"; Path = Get-UserShellFolder -Name "{374DE290-123F-4565-9164-39C4925E467B}" -Fallback (Join-Path $env:USERPROFILE "Downloads") },
        [pscustomobject]@{ Name = "Bilder"; Path = [Environment]::GetFolderPath("MyPictures") },
        [pscustomobject]@{ Name = "Musik"; Path = [Environment]::GetFolderPath("MyMusic") },
        [pscustomobject]@{ Name = "Videos"; Path = [Environment]::GetFolderPath("MyVideos") },
        [pscustomobject]@{ Name = "Favoriten"; Path = [Environment]::GetFolderPath("Favorites") },
        [pscustomobject]@{ Name = "Gespeicherte Spiele"; Path = Join-Path $env:USERPROFILE "Saved Games" },
        [pscustomobject]@{ Name = "Kontakte"; Path = Join-Path $env:USERPROFILE "Contacts" }
    )

    return @($folders | Where-Object { $_.Path -and ($IncludeMissing -or (Test-Path -LiteralPath $_.Path)) } | ForEach-Object { $_.Name })
}

function Get-NewestLogFile {
    if (-not $script:lastLogDir -or -not (Test-Path -LiteralPath $script:lastLogDir)) {
        return $null
    }

    return Get-ChildItem -LiteralPath $script:lastLogDir -Filter "*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-NormalizedVolumeSerial {
    param($Disk)
    if (-not $Disk -or -not $Disk.VolumeSerialNumber) { return '' }
    return ([string]$Disk.VolumeSerialNumber).Trim().Replace('-', '').ToUpperInvariant()
}

function Get-KnownBackupDrive {
    if (-not (Test-Path -LiteralPath $settingsFile -PathType Leaf)) { return $null }
    try {
        $settings = Get-Content -LiteralPath $settingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $settings.KnownBackupDrive -or -not $settings.KnownBackupDrive.SerialNumber) { return $null }
        return [pscustomobject]@{
            SerialNumber = ([string]$settings.KnownBackupDrive.SerialNumber).Trim().Replace('-', '').ToUpperInvariant()
            VolumeName = [string]$settings.KnownBackupDrive.VolumeName
            LastDeviceId = [string]$settings.KnownBackupDrive.LastDeviceId
            SavedAt = [string]$settings.KnownBackupDrive.SavedAt
        }
    } catch {
        # Eine defekte Komforteinstellung darf Sicherung und Restore nie blockieren.
        return $null
    }
}

function Test-IsKnownBackupDrive {
    param($Disk)
    $serial = Get-NormalizedVolumeSerial -Disk $Disk
    return $script:knownDrive -and $serial -and
        $serial.Equals($script:knownDrive.SerialNumber, [System.StringComparison]::OrdinalIgnoreCase)
}

function Save-KnownBackupDrive {
    param($Disk)

    $serial = Get-NormalizedVolumeSerial -Disk $Disk
    if (-not $serial) {
        throw (L 'Die Datenträger-ID konnte nicht gelesen werden.' 'The drive identifier could not be read.')
    }

    $knownDrive = [pscustomobject]@{
        SerialNumber = $serial
        VolumeName = [string]$Disk.VolumeName
        LastDeviceId = [string]$Disk.DeviceID
        SavedAt = (Get-Date).ToString('o')
    }
    $settings = [ordered]@{ Version = 1; KnownBackupDrive = $knownDrive }
    $json = $settings | ConvertTo-Json -Depth 4
    New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
    $temporaryFile = Join-Path $settingsDirectory ("settings.{0}.tmp" -f [guid]::NewGuid().ToString('N'))
    $backupFile = Join-Path $settingsDirectory ("settings.{0}.bak" -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($temporaryFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        if ([System.IO.File]::Exists($settingsFile)) {
            [System.IO.File]::Replace($temporaryFile, $settingsFile, $backupFile, $true)
        } else {
            [System.IO.File]::Move($temporaryFile, $settingsFile)
        }
        $script:knownDrive = $knownDrive
    } finally {
        Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-BackupHealth {
    param([string]$Drive)

    $backupDirectory = Join-Path $Drive ("Bibliothekssicherung\{0}_{1}" -f $env:COMPUTERNAME, $env:USERNAME)
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
        $computer = (($lines | Where-Object { $_ -like 'Computer:*' } | Select-Object -First 1) -replace '^Computer:\s*', '').Trim()
        $user = (($lines | Where-Object { $_ -like 'Benutzer:*' } | Select-Object -First 1) -replace '^Benutzer:\s*', '').Trim()
        if (-not $computer.Equals($env:COMPUTERNAME, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not $user.Equals($env:USERNAME, [System.StringComparison]::OrdinalIgnoreCase)) {
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
                $durationText = if ($elapsed.TotalHours -ge 1) { $elapsed.ToString('hh\:mm\:ss') } else { $elapsed.ToString('mm\:ss') }
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
$form.ClientSize = New-Object System.Drawing.Size(720, 734)
# Kleine Bildschirme (z. B. 1366x768): Das Fenster darf niedriger werden als
# das Layout; der Inhalt wird dann gescrollt. Nach oben ist die Hoehe auf die
# Layouthoehe begrenzt, damit unter der Fussleiste kein Leerraum entsteht.
$form.MinimumSize = New-Object System.Drawing.Size(736, 600)
$form.MaximumSize = New-Object System.Drawing.Size(10000, $form.Height)
$form.AutoScroll = $true
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
$titleLabel.Text = L "Persönliche Dateien sichern" "Back up personal files"
$titleLabel.Font = New-Object System.Drawing.Font($displayFontName, 18)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(30, 20)
$form.Controls.Add($titleLabel)

$descriptionLabel = New-Object System.Windows.Forms.Label
$descriptionLabel.Text = L "Wählen Sie Ziel und Ordner. Vorhandene Dateien werden nicht gelöscht." "Choose a destination and folders. Existing files are not deleted."
$descriptionLabel.AutoSize = $true
$descriptionLabel.ForeColor = $secondaryTextColor
$descriptionLabel.Location = New-Object System.Drawing.Point(30, 58)
$form.Controls.Add($descriptionLabel)

$helpButton = New-Object System.Windows.Forms.Button
$helpButton.Text = L "Hilfe" "Help"
$helpButton.Location = New-Object System.Drawing.Point(626, 62)
$helpButton.Size = New-Object System.Drawing.Size(64, 28)
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
$modePanel.Location = New-Object System.Drawing.Point((690 - $modePanel.Width), 16)

$targetSurface = New-SurfacePanel -Location (New-Object System.Drawing.Point(14, 100)) -Size (New-Object System.Drawing.Size(692, 118))

$driveLabel = New-Object System.Windows.Forms.Label
$driveLabel.Text = L "Ziellaufwerk:" "Destination drive:"
$driveLabel.AutoSize = $true
$driveLabel.Font = New-Object System.Drawing.Font($semiboldFontName, 9.5)
$driveLabel.Location = New-Object System.Drawing.Point(30, 110)
$driveLabel.BackColor = $surfaceColor
$form.Controls.Add($driveLabel)

$driveCombo = New-Object System.Windows.Forms.ComboBox
$driveCombo.DropDownStyle = "DropDownList"
$driveCombo.Location = New-Object System.Drawing.Point(30, 132)
$driveCombo.Size = New-Object System.Drawing.Size(549, 27)
$driveCombo.Anchor = "Top, Left, Right"
$driveCombo.TabIndex = 3
$form.Controls.Add($driveCombo)

$driveToolTip = New-Object System.Windows.Forms.ToolTip

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = L "Aktualisieren" "Refresh"
$refreshButton.Location = New-Object System.Drawing.Point(587, 130)
$refreshButton.Size = New-Object System.Drawing.Size(103, 31)
$refreshButton.BackColor = $surfaceColor
$refreshButton.FlatStyle = 'Flat'
$refreshButton.FlatAppearance.BorderColor = $buttonBorderColor
$refreshButton.Anchor = "Top, Right"
$refreshButton.TabIndex = 4
$form.Controls.Add($refreshButton)

$driveInfoLabel = New-Object System.Windows.Forms.Label
$driveInfoLabel.AutoSize = $true
$driveInfoLabel.ForeColor = $secondaryTextColor
$driveInfoLabel.Location = New-Object System.Drawing.Point(30, 167)
$driveInfoLabel.BackColor = $surfaceColor
$form.Controls.Add($driveInfoLabel)

$healthPanel = New-Object System.Windows.Forms.Panel
$healthPanel.Location = New-Object System.Drawing.Point(180, 163)
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
$healthLabel.Size = New-Object System.Drawing.Size(490, 21)
$healthLabel.Anchor = 'Top, Left, Right'
$healthLabel.Text = L 'Keine Sicherung für dieses Profil' 'No backup for this profile'
$healthPanel.Controls.Add($healthLabel)

$healthToolTip = New-Object System.Windows.Forms.ToolTip

function Update-BackupHealth {
    if (-not $driveCombo.SelectedItem) {
        $healthPanel.Visible = $false
        return
    }

    $disk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
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
$fat32Label.Location = New-Object System.Drawing.Point(30, 191)
$fat32Label.Size = New-Object System.Drawing.Size(660, 25)
$fat32Label.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
$fat32Label.Visible = $false
$form.Controls.Add($fat32Label)

$folderSurface = New-SurfacePanel -Location (New-Object System.Drawing.Point(14, 226)) -Size (New-Object System.Drawing.Size(692, 230))

$libraryLabel = New-Object System.Windows.Forms.Label
$libraryLabel.Text = L "Diese Ordner werden gesichert:" "These folders will be backed up:"
$libraryLabel.AutoSize = $true
$libraryLabel.Font = New-Object System.Drawing.Font($semiboldFontName, 9.5)
$libraryLabel.Location = New-Object System.Drawing.Point(30, 237)
$libraryLabel.BackColor = $surfaceColor
$form.Controls.Add($libraryLabel)

$libraryList = New-Object System.Windows.Forms.CheckedListBox
# Die Ordnernamen sind kurz; eine schmale, dafuer hoehere Liste zeigt alle
# Eintraege ohne Scrollbalken. Alle/Keine und der Auswahlzaehler nutzen den
# frei gewordenen Platz rechts daneben.
$libraryList.Location = New-Object System.Drawing.Point(30, 260)
$libraryList.Size = New-Object System.Drawing.Size(340, 184)
$libraryList.Anchor = "Top, Left"
$libraryList.CheckOnClick = $true
$libraryList.BackColor = [System.Drawing.Color]::White
$libraryList.TabIndex = 5
$form.Controls.Add($libraryList)

foreach ($name in Get-LibraryNames) {
    $item = [pscustomobject]@{ CanonicalName = $name; DisplayName = Get-FolderDisplayName $name }
    $item | Add-Member -MemberType ScriptMethod -Name ToString -Value { return $this.DisplayName } -Force
    [void]$libraryList.Items.Add($item, $true)
}

$allButton = New-Object System.Windows.Forms.Button
$allButton.Text = L "Alle" "All"
$allButton.Location = New-Object System.Drawing.Point(384, 260)
$allButton.Size = New-Object System.Drawing.Size(76, 27)
$allButton.FlatStyle = 'Flat'
$allButton.FlatAppearance.BorderSize = 1
$allButton.FlatAppearance.BorderColor = $buttonBorderColor
$allButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$allButton.BackColor = $surfaceColor
$allButton.TabIndex = 6
$form.Controls.Add($allButton)

$noneButton = New-Object System.Windows.Forms.Button
$noneButton.Text = L "Keine" "None"
$noneButton.Location = New-Object System.Drawing.Point(384, 297)
$noneButton.Size = New-Object System.Drawing.Size(76, 27)
$noneButton.FlatStyle = 'Flat'
$noneButton.FlatAppearance.BorderSize = 1
$noneButton.FlatAppearance.BorderColor = $buttonBorderColor
$noneButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$noneButton.BackColor = $surfaceColor
$noneButton.TabIndex = 7
$form.Controls.Add($noneButton)

# Das Logo nutzt den freien Bereich rechts neben Ordnerliste und Buttons
# in voller Hoehe von Beschriftung und Liste.
# Es ist optional: Fehlt die Datei, bleibt die Flaeche einfach leer.
$logoBox = New-Object System.Windows.Forms.PictureBox
$logoBox.Location = New-Object System.Drawing.Point(503, 237)
$logoBox.Size = New-Object System.Drawing.Size(187, 207)
$logoBox.SizeMode = 'Zoom'
$logoBox.BackColor = $surfaceColor
$logoBox.Anchor = 'Top, Right'
$logoFile = Join-Path $PSScriptRoot 'logo.jpg'
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

$activitySurface = New-SurfacePanel -Location (New-Object System.Drawing.Point(14, 466)) -Size (New-Object System.Drawing.Size(692, 156))

$statusCaption = New-Object System.Windows.Forms.Label
$statusCaption.Text = "Status:"
$statusCaption.AutoSize = $true
$statusCaption.Font = New-Object System.Drawing.Font($semiboldFontName, 9.5)
$statusCaption.Location = New-Object System.Drawing.Point(30, 478)
$statusCaption.BackColor = $surfaceColor
$form.Controls.Add($statusCaption)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = L "Bereit." "Ready."
$statusLabel.AutoEllipsis = $true
$statusLabel.Location = New-Object System.Drawing.Point(82, 478)
$statusLabel.Size = New-Object System.Drawing.Size(608, 22)
$statusLabel.BackColor = $surfaceColor
$statusLabel.Anchor = "Top, Left, Right"
$form.Controls.Add($statusLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(30, 506)
$progressBar.Size = New-Object System.Drawing.Size(660, 8)
$progressBar.Anchor = "Top, Left, Right"
$progressBar.Style = "Blocks"
$form.Controls.Add($progressBar)

$resultLabel = New-Object System.Windows.Forms.Label
$resultLabel.Text = L "Ergebnisübersicht:" "Summary:"
$resultLabel.AutoSize = $true
$resultLabel.Font = New-Object System.Drawing.Font($semiboldFontName, 9.5)
$resultLabel.Location = New-Object System.Drawing.Point(30, 524)
$resultLabel.BackColor = $surfaceColor
$form.Controls.Add($resultLabel)

$resultBox = New-Object System.Windows.Forms.TextBox
$resultBox.Location = New-Object System.Drawing.Point(30, 546)
$resultBox.Size = New-Object System.Drawing.Size(660, 64)
$resultBox.Anchor = "Top, Left, Right"
$resultBox.Multiline = $true
$resultBox.ReadOnly = $true
$resultBox.BackColor = [System.Drawing.Color]::White
$resultBox.TabStop = $false
$script:resultSummary = L "Noch keine Sicherung ausgeführt." "No backup has been run yet."
$resultBox.Text = $script:resultSummary
$form.Controls.Add($resultBox)

$footerSurface = New-SurfacePanel -Location (New-Object System.Drawing.Point(0, 632)) -Size (New-Object System.Drawing.Size(720, 102)) -Anchor 'Top, Left, Right'

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = L "Sicherung starten" "Start backup"
$startButton.Location = New-Object System.Drawing.Point(30, 654)
$startButton.Size = New-Object System.Drawing.Size(175, 46)
$startButton.BackColor = $accentColor
$startButton.ForeColor = $accentTextColor
$startButton.FlatStyle = "Flat"
$startButton.FlatAppearance.BorderSize = 0
$startButton.FlatAppearance.MouseOverBackColor = $accentHoverColor
$startButton.Font = New-Object System.Drawing.Font($semiboldFontName, 10)
$startButton.Anchor = "Top, Left"
$startButton.TabIndex = 8
$form.Controls.Add($startButton)
$form.AcceptButton = $startButton

$logButton = New-Object System.Windows.Forms.Button
$logButton.Text = L "Protokoll öffnen" "Open log"
$logButton.Location = New-Object System.Drawing.Point(213, 654)
$logButton.Size = New-Object System.Drawing.Size(145, 46)
$logButton.BackColor = [System.Drawing.Color]::White
$logButton.FlatStyle = "Flat"
$logButton.FlatAppearance.BorderSize = 1
$logButton.FlatAppearance.BorderColor = $buttonBorderColor
$logButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$logButton.Font = New-Object System.Drawing.Font($semiboldFontName, 10)
$logButton.Enabled = $false
$logButton.Anchor = "Top, Left"
$logButton.TabIndex = 9
$form.Controls.Add($logButton)

$closeButton = New-Object System.Windows.Forms.Button
$destinationButton = New-Object System.Windows.Forms.Button
$destinationButton.Text = L "Sicherungsordner öffnen" "Open backup folder"
$destinationButton.Location = New-Object System.Drawing.Point(366, 654)
$destinationButton.Size = New-Object System.Drawing.Size(181, 46)
$destinationButton.BackColor = [System.Drawing.Color]::White
$destinationButton.FlatStyle = "Flat"
$destinationButton.FlatAppearance.BorderSize = 1
$destinationButton.FlatAppearance.BorderColor = $buttonBorderColor
$destinationButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$destinationButton.Font = New-Object System.Drawing.Font($semiboldFontName, 10)
$destinationButton.Enabled = $false
$destinationButton.Anchor = "Top, Left"
$destinationButton.TabIndex = 10
$form.Controls.Add($destinationButton)

$closeButton.Text = L "Schließen" "Close"
$closeButton.Location = New-Object System.Drawing.Point(555, 654)
$closeButton.Size = New-Object System.Drawing.Size(135, 46)
$closeButton.BackColor = [System.Drawing.Color]::White
$closeButton.FlatStyle = "Flat"
$closeButton.FlatAppearance.BorderSize = 1
$closeButton.FlatAppearance.BorderColor = $buttonBorderColor
$closeButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$closeButton.Font = New-Object System.Drawing.Font($semiboldFontName, 10)
$closeButton.TabIndex = 11
$closeButton.Anchor = "Top, Right"
$form.Controls.Add($closeButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = L "Sicherung abbrechen" "Cancel backup"
$cancelButton.Location = New-Object System.Drawing.Point(30, 654)
$cancelButton.Size = New-Object System.Drawing.Size(175, 46)
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
$cancelButton.TabIndex = 8
$cancelButton.Visible = $false
$form.Controls.Add($cancelButton)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 350

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

function Update-SelectionState {
    $count = $libraryList.CheckedItems.Count
    $startButton.Enabled = ($count -gt 0 -and $null -ne $driveCombo.SelectedItem -and -not $script:backupProcess)
    Update-ResultOverview
}

function Update-LibraryList {
    $libraryList.Items.Clear()
    $names = @()
    if ($restoreRadio.Checked) {
        if ($driveCombo.SelectedItem) {
            $disk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
            $backupRoot = Join-Path $disk.DeviceID ("Bibliothekssicherung\{0}_{1}" -f $env:COMPUTERNAME, $env:USERNAME)
            $names = @(Get-LibraryNames -IncludeMissing | Where-Object { Test-Path -LiteralPath (Join-Path $backupRoot $_) -PathType Container })
        }
        $titleLabel.Text = L "Persönliche Dateien wiederherstellen" "Restore personal files"
        $descriptionLabel.Text = L "Neuere lokale Dateien bleiben erhalten; es wird nichts gelöscht." "Newer local files are kept; nothing is deleted."
        $driveLabel.Text = L "Sicherungslaufwerk:" "Backup drive:"
        $libraryLabel.Text = L "Diese Ordner sind in der Sicherung verfügbar:" "These folders are available in the backup:"
        $startButton.Text = L "Wiederherstellung prüfen" "Review restore"
        $fat32Label.Visible = $false
    } else {
        $names = @(Get-LibraryNames)
        $titleLabel.Text = L "Persönliche Dateien sichern" "Back up personal files"
        $descriptionLabel.Text = L "Wählen Sie Ziel und Ordner. Vorhandene Dateien werden nicht gelöscht." "Choose a destination and folders. Existing files are not deleted."
        $driveLabel.Text = L "Ziellaufwerk:" "Destination drive:"
        $libraryLabel.Text = L "Diese Ordner werden gesichert:" "These folders will be backed up:"
        $startButton.Text = L "Sicherung starten" "Start backup"
        if ($driveCombo.SelectedItem) {
            $selectedDisk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
            $fat32Label.Visible = $selectedDisk.FileSystem -eq 'FAT32'
        }
    }
    foreach ($name in $names) {
        $item = [pscustomobject]@{ CanonicalName = $name; DisplayName = Get-FolderDisplayName $name }
        $item | Add-Member -MemberType ScriptMethod -Name ToString -Value { return $this.DisplayName } -Force
        [void]$libraryList.Items.Add($item, $true)
    }
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

$libraryList.Add_ItemCheck({
    # Beim initialen Befüllen existiert das Fensterhandle noch nicht. In diesem
    # Fall aktualisiert Update-LibraryList den Zustand nach dem Befüllen selbst.
    if ($form.IsHandleCreated -and -not $form.IsDisposed) {
        $form.BeginInvoke([Action]{ Update-SelectionState }) | Out-Null
    }
})

function Update-DriveList {
    $driveCombo.Items.Clear()
    $script:driveMap.Clear()
    $systemDrive = $env:SystemDrive

    try {
        $drives = @(Get-CimInstance Win32_LogicalDisk |
            Where-Object { $_.DriveType -in 2, 3 -and $_.DeviceID -ne $systemDrive -and $_.Size -gt 0 } |
            Sort-Object DriveType, DeviceID)

        $preferredIndex = -1
        foreach ($disk in $drives) {
            $label = if ($disk.VolumeName) { $disk.VolumeName } else { L "ohne Namen" "unnamed" }
            $type = if ($disk.DriveType -eq 2) { L "Wechseldatenträger" "Removable drive" } else { L "Lokaler Datenträger" "Local drive" }
            $freeGb = [math]::Round($disk.FreeSpace / 1GB, 1)
            $display = "{0}  -  {1}  ({2:N1} GB frei, {3})" -f $disk.DeviceID, $label, $freeGb, $type
            if (Test-IsKnownBackupDrive -Disk $disk) {
                $display = "★ {0}" -f $display
                $preferredIndex = $driveCombo.Items.Count
            }
            $script:driveMap[$display] = $disk
            [void]$driveCombo.Items.Add($display)
        }

        if ($driveCombo.Items.Count -gt 0) {
            $driveCombo.SelectedIndex = if ($preferredIndex -ge 0) { $preferredIndex } else { 0 }
        } else {
            $driveInfoLabel.Text = L "Kein geeignetes Ziellaufwerk gefunden." "No suitable drive was found."
            $startButton.Enabled = $false
        }
    } catch {
        $driveInfoLabel.Text = (L "Laufwerke konnten nicht ermittelt werden: {0}" "Drives could not be detected: {0}") -f $_.Exception.Message
        $startButton.Enabled = $false
    }
}

$driveCombo.Add_SelectedIndexChanged({
    if ($driveCombo.SelectedItem) {
        $disk = $script:driveMap[$driveCombo.SelectedItem.ToString()]
        $sizeGb = [math]::Round($disk.Size / 1GB, 1)
        $fileSystem = if ($disk.FileSystem) { $disk.FileSystem } else { L "unbekannt" "unknown" }
        $driveInfoLabel.Text = (L "{0:N1} GB gesamt · {1}" "{0:N1} GB total · {1}") -f $sizeGb, $fileSystem
        $fat32Label.Visible = $fileSystem -eq "FAT32"
        if ($restoreRadio.Checked) { $fat32Label.Visible = $false }
        $driveToolTip.SetToolTip($driveCombo, $(if (Test-IsKnownBackupDrive -Disk $disk) {
            L 'Bekanntes Sicherungslaufwerk – wird automatisch ausgewählt.' 'Known backup drive — selected automatically.'
        } else {
            L 'Dieses Laufwerk ist noch nicht als Sicherungslaufwerk gespeichert.' 'This drive is not currently remembered as the backup drive.'
        }))
        Update-BackupHealth
        Update-LibraryList
        Update-SelectionState
    }
})

$refreshButton.Add_Click({ Update-DriveList })

$backupRadio.Add_CheckedChanged({
    if ($backupRadio.Checked) { Update-LibraryList }
})
$restoreRadio.Add_CheckedChanged({
    if ($restoreRadio.Checked) { Update-LibraryList }
})

$startButton.Add_Click({
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
    if ($backupRadio.Checked -and $script:knownDrive -and -not (Test-IsKnownBackupDrive -Disk $disk)) {
        $knownName = if ($script:knownDrive.VolumeName) { $script:knownDrive.VolumeName } else { $script:knownDrive.LastDeviceId }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            ((L "Das ausgewählte Laufwerk ist nicht das bekannte Sicherungslaufwerk '{0}'.`r`n`r`nWenn die Sicherung erfolgreich ist, wird künftig dieses Laufwerk wiedererkannt. Trotzdem fortfahren?" "The selected drive is not the known backup drive '{0}'.`r`n`r`nIf the backup succeeds, this drive will be remembered instead. Continue anyway?") -f $knownName),
            (L 'Anderes Sicherungslaufwerk' 'Different backup drive'),
            'YesNo',
            'Warning'
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    if ($backupRadio.Checked -and $disk.DriveType -eq 3) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            (L "Das ausgewählte Ziel ist ein internes Laufwerk. Eine Sicherung auf einem externen USB-Laufwerk schützt besser vor Defekten und Schadsoftware.`r`n`r`nTrotzdem fortfahren?" "The selected destination is an internal drive. An external USB drive offers better protection against hardware failure and malware.`r`n`r`nContinue anyway?"),
            (L "Internes Sicherungsziel" "Internal backup destination"),
            "YesNo",
            "Warning"
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    $drive = $disk.DeviceID
    $selectedFolders = @($libraryList.CheckedItems | ForEach-Object {
        if ($_.PSObject.Properties['CanonicalName']) { $_.CanonicalName } else { $_.ToString() }
    })
    $script:statusFile = Join-Path $env:TEMP ("Bibliothekssicherung_{0}.status" -f [guid]::NewGuid().ToString("N"))
    $script:resultFile = Join-Path $env:TEMP ("Bibliothekssicherung_{0}.result.json" -f [guid]::NewGuid().ToString("N"))
    $script:cancelFile = Join-Path $env:TEMP ("Bibliothekssicherung_{0}.cancel" -f [guid]::NewGuid().ToString("N"))
    $script:previewFile = Join-Path $env:TEMP ("Bibliothekssicherung_{0}.preview.json" -f [guid]::NewGuid().ToString("N"))
    $script:approvalFile = Join-Path $env:TEMP ("Bibliothekssicherung_{0}.approve" -f [guid]::NewGuid().ToString("N"))
    $script:lastLogDir = Join-Path $drive ("Bibliothekssicherung\{0}_{1}\_logs" -f $env:COMPUTERNAME, $env:USERNAME)
    $script:lastDestination = Join-Path $drive ("Bibliothekssicherung\{0}_{1}" -f $env:COMPUTERNAME, $env:USERNAME)
    $script:backupStartedAt = Get-Date
    $script:backupCancelled = $false
    $script:activeDrive = $disk
    $script:restorePreviewShown = $false
    $script:scanWarningShown = $false
    $cancelButton.Text = if ($restoreRadio.Checked) { L "Wiederherstellung abbrechen" "Cancel restore" } else { L "Sicherung abbrechen" "Cancel backup" }
    $logButton.Enabled = $false
    $destinationButton.Enabled = $false
    $resultBox.Text = L "Vorprüfung wird gestartet ..." "Starting preflight checks ..."
    $statusLabel.ForeColor = [System.Drawing.SystemColors]::ControlText
    $statusLabel.Text = if ($restoreRadio.Checked) { L "Wiederherstellung wird geprüft ..." "Checking restore ..." } else { L "Sicherung wird gestartet ..." "Starting backup ..." }
    $progressBar.Style = "Blocks"
    $progressBar.Minimum = 0
    $progressBar.Maximum = [math]::Max(1, $selectedFolders.Count)
    $progressBar.Value = 0
    $startButton.Enabled = $false
    $refreshButton.Enabled = $false
    $backupRadio.Enabled = $false
    $restoreRadio.Enabled = $false
    $driveCombo.Enabled = $false
    $libraryList.Enabled = $false
    $allButton.Enabled = $false
    $noneButton.Enabled = $false
    $closeButton.Visible = $false
    $startButton.Visible = $false
    $cancelButton.Enabled = $true
    $cancelButton.Visible = $true
    $form.AcceptButton = $null

    try {
        $powershellExe = Join-Path $PSHOME "powershell.exe"
        $selectedArgument = $selectedFolders -join '|'
        $mode = if ($restoreRadio.Checked) { 'Restore' } else { 'Backup' }
        $script:activeMode = $mode
        $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode "{1}" -ParentProcessId "{2}" -UsbDrive "{3}" -Silent -StatusFile "{4}" -ResultFile "{5}" -CancelFile "{6}" -PreviewFile "{7}" -ApprovalFile "{8}" -SelectedFolders "{9}"' -f $coreScript, $mode, $PID, $drive, $script:statusFile, $script:resultFile, $script:cancelFile, $script:previewFile, $script:approvalFile, $selectedArgument
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $powershellExe
        $startInfo.Arguments = $arguments
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true

        $script:backupProcess = New-Object System.Diagnostics.Process
        $script:backupProcess.StartInfo = $startInfo
        if (-not $script:backupProcess.Start()) {
            throw (L "Der Sicherungsprozess konnte nicht gestartet werden." "The worker process could not be started.")
        }
        $timer.Start()
    } catch {
        $progressBar.Style = "Blocks"
        $startButton.Enabled = $true
        $refreshButton.Enabled = $true
        $backupRadio.Enabled = $true
        $restoreRadio.Enabled = $true
        $driveCombo.Enabled = $true
        $libraryList.Enabled = $true
        $allButton.Enabled = $true
        $noneButton.Enabled = $true
        $closeButton.Visible = $true
        $startButton.Visible = $true
        $cancelButton.Visible = $false
        $form.AcceptButton = $startButton
        $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
        $statusLabel.Text = L "Start fehlgeschlagen." "Failed to start."
        foreach ($temporaryFile in @($script:statusFile, $script:resultFile, $script:cancelFile, $script:previewFile, $script:approvalFile)) {
            if ($temporaryFile) { Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue }
        }
        $script:statusFile = $null
        $script:resultFile = $null
        $script:cancelFile = $null
        $script:previewFile = $null
        $script:approvalFile = $null
        $script:activeDrive = $null
        $script:activeMode = $null
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, (L "Fehler" "Error"), "OK", "Error") | Out-Null
    }
})

$timer.Add_Tick({
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
                                $message = if ($script:isGerman) {
                                    "Konfliktvorschau:`r`n`r`nFehlende Dateien: $($preview.MissingFiles)`r`nLokale Dateien, die ersetzt werden: $($preview.OverwriteFiles)`r`nNeuere lokale Dateien, die geschützt bleiben: $($preview.ProtectedNewerFiles)`r`nZu kopieren: $($preview.PlannedFiles) Dateien / $previewGb GB$exampleText`r`n`r`nWiederherstellung jetzt starten?"
                                } else {
                                    "Conflict preview:`r`n`r`nMissing files: $($preview.MissingFiles)`r`nLocal files to be replaced: $($preview.OverwriteFiles)`r`nNewer local files that remain protected: $($preview.ProtectedNewerFiles)`r`nTo be copied: $($preview.PlannedFiles) files / $previewGb GB$exampleText`r`n`r`nStart the restore now?"
                                }
                                $answer = [System.Windows.Forms.MessageBox]::Show($message, (L "Wiederherstellung prüfen" "Review restore"), "YesNo", "Warning")
                                if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                                    Set-Content -LiteralPath $script:approvalFile -Value 'continue' -Encoding ASCII
                                    $statusLabel.Text = L "Wiederherstellung wird gestartet ..." "Starting restore ..."
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
                        $displayFolder = Get-FolderDisplayName $parts[3]
                        $statusLabel.Text = if ($script:isGerman) { "Prüfe Ordner $($parts[1]) von $($parts[2]): $displayFolder" } else { "Checking folder $($parts[1]) of $($parts[2]): $displayFolder" }
                        $resultBox.Text = L "Dateien und benötigter Speicherplatz werden geprüft ..." "Checking files and required disk space ..."
                    }
                    "FORTSCHRITT" {
                        $current = [int]$parts[1]
                        $total = [int]$parts[2]
                        $name = Get-FolderDisplayName $parts[3]
                        $progressBar.Maximum = [math]::Max(1, $total)
                        $progressBar.Value = [math]::Min($current - 1, $progressBar.Maximum)
                        $statusLabel.Text = if ($restoreRadio.Checked) {
                            if ($script:isGerman) { "Ordner $current von $total wird wiederhergestellt: $name" } else { "Restoring folder $current of $total`: $name" }
                        } else {
                            if ($script:isGerman) { "Ordner $current von $total wird gesichert: $name" } else { "Backing up folder $current of $total`: $name" }
                        }
                    }
                    "STATUS" { $statusLabel.Text = if ($restoreRadio.Checked) { L "Wiederherstellung wird vorbereitet ..." "Preparing restore ..." } else { L "Sicherung wird vorbereitet ..." "Preparing backup ..." } }
                    "FERTIG" { $statusLabel.Text = if ($restoreRadio.Checked) { L "Wiederherstellung erfolgreich abgeschlossen." "Restore completed successfully." } else { L "Sicherung erfolgreich abgeschlossen." "Backup completed successfully." } }
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
        if ($script:backupProcess.HasExited) {
            $exitCode = $script:backupProcess.ExitCode
            $timer.Stop()
            $progressBar.Style = "Blocks"
            $startButton.Enabled = $true
            $refreshButton.Enabled = $true
            $backupRadio.Enabled = $true
            $restoreRadio.Enabled = $true
            $driveCombo.Enabled = $true
            $libraryList.Enabled = $true
            $allButton.Enabled = $true
            $noneButton.Enabled = $true
            $closeButton.Visible = $true
            $startButton.Visible = $true
            $cancelButton.Visible = $false
            $form.AcceptButton = $closeButton

            $newestLog = Get-NewestLogFile
            $logButton.Enabled = $null -ne $newestLog
            $destinationButton.Enabled = $script:lastDestination -and (Test-Path -LiteralPath $script:lastDestination)

            $result = $null
            if ($script:resultFile -and (Test-Path -LiteralPath $script:resultFile)) {
                try { $result = Get-Content -LiteralPath $script:resultFile -Raw | ConvertFrom-Json } catch {}
            }

            if ($script:backupCancelled) {
                $statusLabel.ForeColor = [System.Drawing.Color]::DarkOrange
                $statusLabel.Text = L "Vorgang wurde abgebrochen." "Operation was cancelled."
                $resultBox.Text = L "Vom Benutzer abgebrochen. Bereits kopierte Dateien bleiben erhalten." "Cancelled by the user. Files already copied remain in place."
            } elseif ($exitCode -eq 0) {
                $elapsed = (Get-Date) - $script:backupStartedAt
                $duration = if ($elapsed.TotalHours -ge 1) { "{0:hh\:mm\:ss}" -f $elapsed } else { "{0:mm\:ss}" -f $elapsed }
                $statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
                $isRestore = $result -and $result.Mode -eq 'Restore'
                $statusLabel.Text = if ($isRestore) {
                    (L "Wiederherstellung erfolgreich abgeschlossen ({0})." "Restore completed successfully ({0}).") -f $duration
                } else {
                    (L "Erfolgreich abgeschlossen ({0}). Ziel: {1}" "Completed successfully ({0}). Destination: {1}") -f $duration, $script:lastDestination
                }
                $progressBar.Value = $progressBar.Maximum
                if ($result) {
                    $plannedGb = [math]::Round(([double]$result.PlannedBytes / 1GB), 2)
                    $displayHints = @($result.HintFolders | ForEach-Object { Get-FolderDisplayName $_ })
                    $hints = if ($displayHints.Count) { (L " Hinweise: {0}." " Notes: {0}.") -f ($displayHints -join ', ') } else { "" }
                    $resultBox.Text = if ($script:isGerman) {
                        "$(if ($isRestore) { 'Wiederhergestellt' } else { 'Gesichert' }): $(@($result.SuccessfulFolders).Count) Ordner. Geplant: $($result.PlannedFiles) Dateien / $plannedGb GB. Dauer: $duration.$hints"
                    } else {
                        "$(if ($isRestore) { 'Restored' } else { 'Backed up' }): $(@($result.SuccessfulFolders).Count) folders. Planned: $($result.PlannedFiles) files / $plannedGb GB. Duration: $duration.$hints"
                    }
                } else {
                    $resultBox.Text = L "Vorgang erfolgreich abgeschlossen." "Operation completed successfully."
                }
                if ($script:activeMode -eq 'Backup' -and $script:activeDrive) {
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
            } else {
                $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
                $statusLabel.Text = (L "Vorgang mit Fehlern beendet (Exit-Code {0})." "Operation finished with errors (exit code {0}).") -f $exitCode
                $resultBox.Text = if ($result -and $result.Message) { $result.Message } else { L "Details finden Sie im Protokoll." "See the log for details." }
                $errorText = (L "Der Vorgang wurde mit Fehlern beendet.`r`nExit-Code: {0}`r`nBitte prüfen Sie die Logdatei." "The operation finished with errors.`r`nExit code: {0}`r`nPlease review the log file.") -f $exitCode
                [System.Windows.Forms.MessageBox]::Show($errorText, (L "Fehler" "Error"), "OK", "Error") | Out-Null
            }

            # Nach dem Abschluss genuegt ein Enter zum Beenden: "Schliessen"
            # erhaelt Default-Status und den Tastaturfokus.
            if ($closeButton.Visible -and $closeButton.Enabled) { $closeButton.Select() }

            # Das Ergebnis bleibt als erste Zeile stehen; darunter zeigt die
            # Uebersicht wieder die aktuelle Ordnerauswahl an.
            $script:resultSummary = $resultBox.Text
            $script:backupProcess.Dispose()
            $script:backupProcess = $null
            Update-BackupHealth
            $script:activeDrive = $null
            $script:activeMode = $null
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
            foreach ($temporaryName in @('previewFile', 'approvalFile')) {
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
    if (Test-Path -LiteralPath $helpFile -PathType Leaf) {
        Start-Process -FilePath $helpFile
    } else {
        [System.Windows.Forms.MessageBox]::Show(((L "Die Hilfedatei wurde nicht gefunden:`r`n{0}" "The help file was not found:`r`n{0}") -f $helpFile), (L "Hilfe" "Help"), "OK", "Error") | Out-Null
    }
})

$destinationButton.Add_Click({
    if ($script:lastDestination -and (Test-Path -LiteralPath $script:lastDestination)) {
        Start-Process -FilePath "explorer.exe" -ArgumentList $script:lastDestination
    }
})

$cancelButton.Add_Click({
    if (-not $script:backupProcess -or $script:backupProcess.HasExited) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        (L "Möchten Sie den laufenden Vorgang wirklich abbrechen?`r`n`r`nBereits kopierte Dateien bleiben erhalten." "Do you really want to cancel the current operation?`r`n`r`nFiles already copied will remain in place."),
        (L "Vorgang abbrechen" "Cancel operation"),
        "YesNo",
        "Warning"
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $script:backupCancelled = $true
    $cancelButton.Enabled = $false
    $statusLabel.ForeColor = [System.Drawing.Color]::DarkOrange
    $statusLabel.Text = L "Abbruch angefordert – der aktuelle Ordner wird noch sicher beendet ..." "Cancellation requested — the current folder will finish safely ..."
    try {
        Set-Content -LiteralPath $script:cancelFile -Value 'cancel' -Encoding ASCII -ErrorAction Stop
    } catch {
        $script:backupCancelled = $false
        $cancelButton.Enabled = $true
        [System.Windows.Forms.MessageBox]::Show((L "Der Abbruch konnte nicht angefordert werden." "Cancellation could not be requested."), $form.Text, "OK", "Error") | Out-Null
    }
})

$closeButton.Add_Click({ $form.Close() })

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:backupProcess -and -not $script:backupProcess.HasExited) {
        $eventArgs.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show((L "Der Vorgang läuft noch. Bitte warten Sie bis zum Abschluss." "The operation is still running. Please wait until it finishes."), $form.Text, "OK", "Warning") | Out-Null
    }
})

# Das Logo-Bitmap gehoert dem Formular und wird mit ihm entsorgt.
$form.Add_FormClosed({
    if ($logoBox.Image) { $logoBox.Image.Dispose() }
    if ($appIcon) { $appIcon.Dispose() }
    if ($healthToolTip) { $healthToolTip.Dispose() }
    if ($driveToolTip) { $driveToolTip.Dispose() }
})

# Beim Start liegt der Fokus auf "Sicherung starten", damit die Sicherung
# direkt mit Enter beginnen kann.
$form.Add_Shown({
    if ($startButton.Enabled) { $startButton.Select() }
})

# WinForms kann die Z-Reihenfolge von Panels bei der ersten echten Anzeige
# anders behandeln als DrawToBitmap. Die dekorativen Flächen muessen deshalb
# ausdruecklich hinter allen interaktiven Steuerelementen liegen.
foreach ($surface in @($targetSurface, $folderSurface, $activitySurface, $footerSurface)) {
    $surface.SendToBack()
}

$script:knownDrive = Get-KnownBackupDrive
Update-DriveList
Update-SelectionState

# Auf Bildschirmen mit wenig Arbeitshoehe startet das Fenster verkleinert;
# der Inhalt ist dann ueber die Bildlaufleiste erreichbar.
$workingArea = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
if ($form.Height -gt $workingArea.Height) {
    $form.Height = $workingArea.Height
}

[void]$form.ShowDialog()
