# Unit-Tests fuer die Ablauf-Funktionen des Workers.
#
# Der Worker ist ein Skript, das sich per exit beendet und deshalb nicht
# dot-gesourct werden kann. Die Tests laden stattdessen nur seine
# Funktionsdefinitionen ueber den AST in den Testscope. So sind die aus dem
# frueheren Fliesstext extrahierten Funktionen direkt pruefbar, ohne dass ein
# vollstaendiger Sicherungslauf noetig ist.

BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:repoRoot 'M24Backup.Shared.ps1')
    # Der Worker verwendet den Kurznamen M fuer zweisprachige Texte.
    Set-Alias -Name M -Value Get-M24Text -Scope Script

    # Nur die Funktionsdefinitionen uebernehmen, nicht den Ablauf des Skripts.
    # Das Dot-Sourcing muss hier direkt stehen: Innerhalb einer Hilfsfunktion
    # landeten die Definitionen in deren eigenem Scope und waeren fuer die
    # Testfaelle unsichtbar.
    $script:workerPath = Join-Path $script:repoRoot 'Bibliothekssicherung.ps1'
    $workerTokens = $null
    $workerParseErrors = $null
    $workerAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:workerPath, [ref]$workerTokens, [ref]$workerParseErrors)
    if ($workerParseErrors.Count) { throw "Parse errors in worker: $($workerParseErrors.Count)" }
    $workerFunctionText = (@($workerAst.FindAll({
        param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $false)) | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine + [Environment]::NewLine
    . ([scriptblock]::Create($workerFunctionText))

    # Wiederherstellungsziele duerfen nicht unterhalb von %LOCALAPPDATA%
    # liegen - genau dort liegt aber Pesters $TestDrive. Ein subst-Laufwerk
    # liefert deshalb einen zulaessigen Ort fuer alle Zielpfade.
    #
    # Hinweis: Laufwerkszuordnung ist ein systemweiter Vorgang. Wird waehrend
    # des Testlaufs von aussen subst aufgerufen, kann das Anlegen hier
    # blockieren. Diese Datei nicht parallel zu anderen subst-Nutzern starten.
    $script:safeBacking = Join-Path ([System.IO.Path]::GetTempPath()) ("m24-fn-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:safeBacking -Force | Out-Null
    $usedDriveLetters = @((Get-PSDrive -PSProvider FileSystem).Name)
    $script:safeDriveLetter = @(90..68 | ForEach-Object { [char]$_ } | Where-Object { $usedDriveLetters -notcontains "$_" }) |
        Select-Object -First 1
    if (-not $script:safeDriveLetter) { throw 'Kein freier Laufwerksbuchstabe fuer den Test verfuegbar.' }
    & subst "$($script:safeDriveLetter):" $script:safeBacking | Out-Null
    $script:safeRoot = "$($script:safeDriveLetter):"

    function New-BackupTree {
        # Baut eine Sicherungsstruktur nach: je Ordner ein Verzeichnis,
        # dazu die Metadatendateien des Workers.
        param(
            [string]$Root,
            [string[]]$Folders = @(),
            [string]$Computer = $env:COMPUTERNAME,
            [string]$User = $env:USERNAME,
            [string]$Result = 'Erfolgreich abgeschlossen',
            $CustomMetadata = $null
        )
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        foreach ($folder in $Folders) {
            New-Item -ItemType Directory -Path (Join-Path $Root $folder) -Force | Out-Null
        }
        # Das Ergebnisformat muss dem entsprechen, das der Worker schreibt:
        # "Ergebnis: <Text> am <yyyy-MM-dd HH:mm:ss>." - ohne Zeitstempel
        # gilt eine Sicherung nicht als vollstaendig.
        $lines = @(
            'Bibliothekssicherung', '', "Computer: $Computer", "Benutzer: $User",
            "Letzter Sicherungsversuch: 2026-01-01 10:00:00", "Ergebnis: $Result am 2026-01-01 10:05:00."
        )
        Set-Content -LiteralPath (Join-Path $Root '_Sicherungsinfo.txt') -Value $lines -Encoding UTF8
        if ($CustomMetadata) {
            $json = ConvertTo-Json -InputObject @($CustomMetadata) -Depth 4
            if (@($CustomMetadata).Count -eq 1 -and -not $json.TrimStart().StartsWith('[')) { $json = "[$json]" }
            Set-Content -LiteralPath (Join-Path $Root '_Ordner.json') -Value $json -Encoding UTF8
        }
        return $Root
    }
}

AfterAll {
    if ($script:safeDriveLetter) { & subst "$($script:safeDriveLetter):" /D 2>&1 | Out-Null }
    if ($script:safeBacking) { Remove-Item -LiteralPath $script:safeBacking -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Read-RestoreSourceIdentity' {
    It 'reads computer and user from the backup metadata' {
        $root = New-BackupTree -Root (Join-Path $TestDrive 'eigen') -Folders @('Dokumente')
        $identity = Read-RestoreSourceIdentity -MetadataFile (Join-Path $root '_Sicherungsinfo.txt')

        $identity.Computer | Should -Be $env:COMPUTERNAME
        $identity.User | Should -Be $env:USERNAME
        $identity.MetadataReadable | Should -BeTrue
        $identity.IsComplete | Should -BeTrue
        $identity.IsMigration | Should -BeFalse -Because 'die Sicherung stammt vom aktuellen Profil'
    }

    It 'flags a backup from another computer or user as a migration' {
        $root = New-BackupTree -Root (Join-Path $TestDrive 'fremd') -Folders @('Dokumente') `
            -Computer 'ANDERER-PC' -User 'anderer'
        $identity = Read-RestoreSourceIdentity -MetadataFile (Join-Path $root '_Sicherungsinfo.txt')

        $identity.MetadataReadable | Should -BeTrue
        $identity.IsMigration | Should -BeTrue
    }

    It 'reports an incomplete backup' {
        $root = New-BackupTree -Root (Join-Path $TestDrive 'unvollstaendig') -Folders @('Dokumente') `
            -Result 'Mit Fehlern beendet'
        (Read-RestoreSourceIdentity -MetadataFile (Join-Path $root '_Sicherungsinfo.txt')).IsComplete | Should -BeFalse
    }

    It 'returns an unreadable identity instead of throwing when metadata is missing' {
        $identity = Read-RestoreSourceIdentity -MetadataFile (Join-Path $TestDrive 'gibt-es-nicht.txt')
        $identity.MetadataReadable | Should -BeFalse
        $identity.IsMigration | Should -BeFalse
        $identity.Computer | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-RestoreTargetRoot' {
    BeforeAll {
        $script:readableIdentity = [pscustomobject]@{
            Computer = 'PC'; User = 'u'; MetadataReadable = $true; IsMigration = $false; IsComplete = $true
        }
    }

    It 'returns no root for a restore into the user profile' {
        Resolve-RestoreTargetRoot -TargetMode 'Profile' -TargetRoot '' `
            -BackupSourcePath 'X:\Bibliothekssicherung\PC_u' -BackupDisplayName 'PC_u' `
            -SourceIdentity $script:readableIdentity | Should -BeNullOrEmpty
    }

    It 'refuses a profile restore when the metadata is unreadable' {
        $identity = [pscustomobject]@{ MetadataReadable = $false; IsComplete = $true }
        { Resolve-RestoreTargetRoot -TargetMode 'Profile' -TargetRoot '' `
            -BackupSourcePath 'X:\b' -BackupDisplayName 'b' -SourceIdentity $identity } |
            Should -Throw '*nicht lesbar*'
    }

    It 'refuses a profile restore from an incomplete backup' {
        $identity = [pscustomobject]@{ MetadataReadable = $true; IsComplete = $false }
        { Resolve-RestoreTargetRoot -TargetMode 'Profile' -TargetRoot '' `
            -BackupSourcePath 'X:\b' -BackupDisplayName 'b' -SourceIdentity $identity } |
            Should -Throw '*nicht vollständig*'
    }

    It 'appends the backup name to the chosen destination folder' {
        $target = Join-Path $script:safeRoot 'ziel'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $resolved = Resolve-RestoreTargetRoot -TargetMode 'Folder' -TargetRoot $target `
            -BackupSourcePath 'X:\Bibliothekssicherung\PC_u' -BackupDisplayName 'PC_u' `
            -SourceIdentity $script:readableIdentity

        $resolved | Should -Be (Join-Path $target 'PC_u')
    }

    It 'requires a destination folder in folder mode' {
        { Resolve-RestoreTargetRoot -TargetMode 'Folder' -TargetRoot '' `
            -BackupSourcePath 'X:\b' -BackupDisplayName 'b' -SourceIdentity $script:readableIdentity } |
            Should -Throw '*Zielordner*'
    }

    It 'refuses a destination that overlaps the backup source' {
        $source = Join-Path $script:safeRoot 'quelle-ueberlappt'
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        { Resolve-RestoreTargetRoot -TargetMode 'Folder' -TargetRoot $source `
            -BackupSourcePath $source -BackupDisplayName 'Sicherung' `
            -SourceIdentity $script:readableIdentity } | Should -Throw '*ineinander liegen*'
    }

    It 'refuses a destination inside a protected profile location' {
        { Resolve-RestoreTargetRoot -TargetMode 'Folder' -TargetRoot $env:LOCALAPPDATA `
            -BackupSourcePath 'X:\b' -BackupDisplayName 'b' `
            -SourceIdentity $script:readableIdentity } | Should -Throw '*geschuetzten System- oder Profilbereich*'
    }
}

Describe 'Resolve-RestoreFolderDefinitions' {
    BeforeAll {
        $script:standardDefinitions = @(Get-M24StandardFolderDefinitions)
        $script:documentsPath = [string]($script:standardDefinitions | Where-Object { $_.Name -eq 'Dokumente' }).Path
    }

    It 'maps every folder below the destination root in folder mode' {
        $root = New-BackupTree -Root (Join-Path $TestDrive 'fm-quelle') -Folders @('Dokumente', 'EigenerOrdner')
        $targetRoot = Join-Path $script:safeRoot 'fm-ziel\Sicherung'

        $definitions = Resolve-RestoreFolderDefinitions -BackupSourcePath $root `
            -StandardDefinitions $script:standardDefinitions -FolderMetadataFile (Join-Path $root '_Ordner.json') `
            -TargetMode 'Folder' -ResolvedTargetRoot $targetRoot -IsMigration $false -BackupDisplayName 'Sicherung'

        @($definitions).Count | Should -Be 2
        ($definitions | Where-Object { $_.Name -eq 'Dokumente' }).Path | Should -Be (Join-Path $targetRoot 'Dokumente')
        ($definitions | Where-Object { $_.Name -eq 'EigenerOrdner' }).Path | Should -Be (Join-Path $targetRoot 'EigenerOrdner')
    }

    It 'classifies standard libraries and additional folders' {
        $root = New-BackupTree -Root (Join-Path $TestDrive 'fm-klasse') -Folders @('Dokumente', 'Projektarchiv')
        $definitions = Resolve-RestoreFolderDefinitions -BackupSourcePath $root `
            -StandardDefinitions $script:standardDefinitions -FolderMetadataFile (Join-Path $root '_Ordner.json') `
            -TargetMode 'Folder' -ResolvedTargetRoot (Join-Path $script:safeRoot 'fm-klasse-ziel') `
            -IsMigration $false -BackupDisplayName 'Sicherung'

        ($definitions | Where-Object { $_.Name -eq 'Dokumente' }).IsCustom | Should -BeFalse
        ($definitions | Where-Object { $_.Name -eq 'Projektarchiv' }).IsCustom | Should -BeTrue
    }

    It 'restores a standard library to its current profile location' {
        $root = New-BackupTree -Root (Join-Path $TestDrive 'fm-profil') -Folders @('Dokumente')
        $definitions = Resolve-RestoreFolderDefinitions -BackupSourcePath $root `
            -StandardDefinitions $script:standardDefinitions -FolderMetadataFile (Join-Path $root '_Ordner.json') `
            -TargetMode 'Profile' -ResolvedTargetRoot $null -IsMigration $false -BackupDisplayName 'Sicherung'

        ($definitions | Where-Object { $_.Name -eq 'Dokumente' }).Path |
            Should -Be (Get-NormalizedFullPath $script:documentsPath)
    }

    It 'returns an own additional folder to its recorded original path' {
        $originalPath = Join-Path $script:safeRoot 'fm-original'
        New-Item -ItemType Directory -Path $originalPath -Force | Out-Null
        $root = New-BackupTree -Root (Join-Path $TestDrive 'fm-eigen') -Folders @('Projektarchiv') `
            -CustomMetadata @([pscustomobject]@{ Name = 'Projektarchiv'; OriginalPath = $originalPath; BackedUpAt = '2026-01-01' })

        $definitions = Resolve-RestoreFolderDefinitions -BackupSourcePath $root `
            -StandardDefinitions $script:standardDefinitions -FolderMetadataFile (Join-Path $root '_Ordner.json') `
            -TargetMode 'Profile' -ResolvedTargetRoot $null -IsMigration $false -BackupDisplayName 'Sicherung'

        ($definitions | Where-Object { $_.Name -eq 'Projektarchiv' }).Path |
            Should -Be (Get-NormalizedFullPath $originalPath)
    }

    It 'collects a foreign additional folder safely below Documents instead of its original path' {
        # Bei einer Migration darf der Originalpfad eines fremden Profils nicht
        # verwendet werden; er koennte auf beliebige Orte dieses Rechners zeigen.
        $foreignPath = Join-Path $TestDrive 'fm-fremd-original'
        New-Item -ItemType Directory -Path $foreignPath -Force | Out-Null
        $root = New-BackupTree -Root (Join-Path $TestDrive 'fm-fremd') -Folders @('Projektarchiv') `
            -Computer 'ANDERER-PC' -User 'anderer' `
            -CustomMetadata @([pscustomobject]@{ Name = 'Projektarchiv'; OriginalPath = $foreignPath; BackedUpAt = '2026-01-01' })

        $definitions = Resolve-RestoreFolderDefinitions -BackupSourcePath $root `
            -StandardDefinitions $script:standardDefinitions -FolderMetadataFile (Join-Path $root '_Ordner.json') `
            -TargetMode 'Profile' -ResolvedTargetRoot $null -IsMigration $true -BackupDisplayName 'ANDERER-PC_anderer'

        $resolved = ($definitions | Where-Object { $_.Name -eq 'Projektarchiv' }).Path
        $resolved | Should -Not -Be (Get-NormalizedFullPath $foreignPath)
        $resolved | Should -BeLike (Join-Path $script:documentsPath '*')
        $resolved | Should -BeLike '*ANDERER-PC_anderer*'
    }

    It 'ignores internal backup files and reparse points' {
        $root = New-BackupTree -Root (Join-Path $TestDrive 'fm-intern') -Folders @('Dokumente', '_logs')
        $definitions = Resolve-RestoreFolderDefinitions -BackupSourcePath $root `
            -StandardDefinitions $script:standardDefinitions -FolderMetadataFile (Join-Path $root '_Ordner.json') `
            -TargetMode 'Folder' -ResolvedTargetRoot (Join-Path $script:safeRoot 'fm-intern-ziel') `
            -IsMigration $false -BackupDisplayName 'Sicherung'

        @($definitions).Name | Should -Not -Contain '_logs'
        @($definitions).Name | Should -Contain 'Dokumente'
    }
}

Describe 'New-FolderCopyPlan' {
    BeforeAll {
        # Join-Path prueft, ob das Laufwerk existiert; fiktive Buchstaben
        # wuerden hier scheitern. Deshalb das bereitgestellte Testlaufwerk.
        $script:planBackupRoot = Join-Path $script:safeRoot 'Bibliothekssicherung\PC_u'
    }

    It 'pairs each backup source with its destination below the backup root' {
        $source = Join-Path $TestDrive 'plan-quelle'
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        $definitions = @([pscustomobject]@{ Name = 'Dokumente'; Path = $source; IsCustom = $false })

        $plan = New-FolderCopyPlan -OperationMode 'Backup' -FolderDefinitions $definitions `
            -BackupRootPath $script:planBackupRoot

        @($plan).Count | Should -Be 1
        $plan[0].Path | Should -Be $source
        $plan[0].TargetPath | Should -Be (Join-Path $script:planBackupRoot 'Dokumente')
    }

    It 'skips backup sources that no longer exist' {
        $definitions = @([pscustomobject]@{ Name = 'Weg'; Path = (Join-Path $TestDrive 'gibt-es-nicht'); IsCustom = $false })
        $plan = New-FolderCopyPlan -OperationMode 'Backup' -FolderDefinitions $definitions `
            -BackupRootPath $script:planBackupRoot
        @($plan).Count | Should -Be 0
    }

    It 'reverses source and destination for a restore' {
        $backupRoot = Join-Path $TestDrive 'plan-backup'
        New-Item -ItemType Directory -Path (Join-Path $backupRoot 'Dokumente') -Force | Out-Null
        $restoreTarget = Join-Path $script:safeRoot 'plan-restore-ziel\Dokumente'
        $definitions = @([pscustomobject]@{ Name = 'Dokumente'; Path = $restoreTarget; IsCustom = $false })

        $plan = New-FolderCopyPlan -OperationMode 'Restore' -FolderDefinitions $definitions -BackupRootPath $backupRoot

        @($plan).Count | Should -Be 1
        $plan[0].Path | Should -Be (Get-NormalizedFullPath (Join-Path $backupRoot 'Dokumente'))
        $plan[0].TargetPath | Should -Be $restoreTarget
    }

    It 'keeps only the folders the user selected' {
        $first = Join-Path $TestDrive 'plan-a'
        $second = Join-Path $TestDrive 'plan-b'
        New-Item -ItemType Directory -Path $first, $second -Force | Out-Null
        $definitions = @(
            [pscustomobject]@{ Name = 'A'; Path = $first; IsCustom = $false }
            [pscustomobject]@{ Name = 'B'; Path = $second; IsCustom = $false }
        )
        $specs = @([pscustomobject]@{ Name = 'B'; Path = $null; IsCustom = $false })

        $plan = New-FolderCopyPlan -OperationMode 'Backup' -FolderDefinitions $definitions `
            -BackupRootPath $script:planBackupRoot -SelectedFolderSpecs $specs

        @($plan).Name | Should -Be @('B')
    }

    It 'ignores a conflict between selected and unselected folders' {
        # Die Auswahl muss vor der Ueberschneidungspruefung greifen: Zwei
        # verschachtelte Ordner sind unkritisch, solange nur einer gesichert
        # wird. Frueher sicherte das ein Quelltext-Reihenfolgetest ab.
        $parent = Join-Path $TestDrive 'plan-eltern'
        $child = Join-Path $parent 'kind'
        New-Item -ItemType Directory -Path $child -Force | Out-Null
        $definitions = @(
            [pscustomobject]@{ Name = 'Eltern'; Path = $parent; IsCustom = $false }
            [pscustomobject]@{ Name = 'Kind'; Path = $child; IsCustom = $true }
        )
        $specs = @([pscustomobject]@{ Name = 'Kind'; Path = $child; IsCustom = $true })

        $plan = New-FolderCopyPlan -OperationMode 'Backup' -FolderDefinitions $definitions `
            -BackupRootPath $script:planBackupRoot -SelectedFolderSpecs $specs

        @($plan).Name | Should -Be @('Kind')
        { Assert-FolderCopyPlanIsSafe -OperationMode 'Backup' -FolderPlan $plan `
            -BackupRootPath $script:planBackupRoot } | Should -Not -Throw
    }
}

Describe 'Assert-FolderCopyPlanIsSafe' {
    It 'accepts a plain backup plan' {
        $source = Join-Path $TestDrive 'safe-quelle'
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        $plan = @([pscustomobject]@{ Name = 'A'; Path = $source; TargetPath = 'X:\b\A'; IsCustom = $false })
        { Assert-FolderCopyPlanIsSafe -OperationMode 'Backup' -FolderPlan $plan -BackupRootPath 'X:\b' } |
            Should -Not -Throw
    }

    It 'refuses an empty plan' {
        { Assert-FolderCopyPlanIsSafe -OperationMode 'Backup' -FolderPlan @() -BackupRootPath 'X:\b' } |
            Should -Throw '*keine passenden*'
    }

    It 'refuses a backup whose destination lies inside one of its sources' {
        # Robocopy wuerde sonst seine eigenen Ausgabedateien erneut einlesen.
        $source = Join-Path $TestDrive 'safe-ueberlappend'
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        $destination = Join-Path $source 'Sicherung'
        $plan = @([pscustomobject]@{ Name = 'A'; Path = $source; TargetPath = (Join-Path $destination 'A'); IsCustom = $false })

        { Assert-FolderCopyPlanIsSafe -OperationMode 'Backup' -FolderPlan $plan -BackupRootPath $destination } |
            Should -Throw '*innerhalb des Quellordners*'
    }

    It 'refuses two backup folders that use the same source path' {
        $source = Join-Path $TestDrive 'safe-doppelt'
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        $plan = @(
            [pscustomobject]@{ Name = 'A'; Path = $source; TargetPath = 'X:\b\A'; IsCustom = $false }
            [pscustomobject]@{ Name = 'B'; Path = $source; TargetPath = 'X:\b\B'; IsCustom = $false }
        )
        { Assert-FolderCopyPlanIsSafe -OperationMode 'Backup' -FolderPlan $plan -BackupRootPath 'X:\b' } |
            Should -Throw '*denselben Quellpfad*'
    }

    It 'refuses a backup folder nested inside another selected folder' {
        $parent = Join-Path $TestDrive 'safe-eltern'
        $child = Join-Path $parent 'kind'
        New-Item -ItemType Directory -Path $child -Force | Out-Null
        $plan = @(
            [pscustomobject]@{ Name = 'Eltern'; Path = $parent; TargetPath = 'X:\b\Eltern'; IsCustom = $false }
            [pscustomobject]@{ Name = 'Kind'; Path = $child; TargetPath = 'X:\b\Kind'; IsCustom = $false }
        )
        { Assert-FolderCopyPlanIsSafe -OperationMode 'Backup' -FolderPlan $plan -BackupRootPath 'X:\b' } |
            Should -Throw '*doppelt gesichert*'
    }

    It 'refuses a restore whose source and destination overlap' {
        $shared = Join-Path $script:safeRoot 'safe-restore'
        New-Item -ItemType Directory -Path $shared -Force | Out-Null
        $plan = @([pscustomobject]@{ Name = 'A'; Path = $shared; TargetPath = (Join-Path $shared 'innen'); IsCustom = $false })

        { Assert-FolderCopyPlanIsSafe -OperationMode 'Restore' -FolderPlan $plan -BackupRootPath 'X:\b' } |
            Should -Throw '*ineinander liegen*'
    }

    It 'refuses two restore folders that target the same location' {
        $target = Join-Path $script:safeRoot 'safe-ziel-doppelt'
        $plan = @(
            [pscustomobject]@{ Name = 'A'; Path = 'X:\b\A'; TargetPath = $target; IsCustom = $false }
            [pscustomobject]@{ Name = 'B'; Path = 'X:\b\B'; TargetPath = $target; IsCustom = $false }
        )
        { Assert-FolderCopyPlanIsSafe -OperationMode 'Restore' -FolderPlan $plan -BackupRootPath 'X:\b' } |
            Should -Throw '*ueberschneiden sich*'
    }

    It 'refuses a destination without a drive letter in both modes' {
        # Fuer UNC-Ziele laesst sich der freie Speicherplatz nicht pruefen.
        foreach ($operationMode in @('Backup', 'Restore')) {
            $source = Join-Path $TestDrive ("safe-unc-{0}" -f $operationMode)
            New-Item -ItemType Directory -Path $source -Force | Out-Null
            $plan = @([pscustomobject]@{
                Name = 'A'; Path = $source; TargetPath = '\\server\freigabe\A'; IsCustom = $false
            })
            { Assert-FolderCopyPlanIsSafe -OperationMode $operationMode -FolderPlan $plan -BackupRootPath 'X:\b' } |
                Should -Throw '*umgeleitet*' -Because "im Modus $operationMode"
        }
    }
}

Describe 'New-RobocopyArgument' {
    BeforeAll {
        $script:baseArguments = @{
            SourcePath = 'C:\Quelle'; TargetPath = 'X:\Ziel'; Threads = 8
            RetryCount = 1; RetryWaitSeconds = 3; LogFile = 'X:\log.txt'
            ExcludedFiles = @('thumbs.db', '*.tmp')
        }
    }

    It 'never passes a deleting switch' {
        # Die Sicherung ist additiv: /MIR, /PURGE oder /MOVE wuerden am Ziel
        # loeschen und duerfen unter keinen Umstaenden auftauchen.
        foreach ($operationMode in @('Backup', 'Restore')) {
            foreach ($dryRun in @($true, $false)) {
                $arguments = New-RobocopyArgument @script:baseArguments -OperationMode $operationMode -DryRun $dryRun
                foreach ($forbidden in @('/MIR', '/PURGE', '/MOVE', '/MOV')) {
                    $arguments | Should -Not -Contain $forbidden `
                        -Because "$forbidden wuerde Daten loeschen (Modus $operationMode, DryRun $dryRun)"
                }
            }
        }
    }

    It 'puts source and destination first, in that order' {
        $arguments = New-RobocopyArgument @script:baseArguments -OperationMode 'Backup' -DryRun $false
        $arguments[0] | Should -Be 'C:\Quelle'
        $arguments[1] | Should -Be 'X:\Ziel'
    }

    It 'protects newer local files only when restoring' {
        (New-RobocopyArgument @script:baseArguments -OperationMode 'Restore' -DryRun $false) |
            Should -Contain '/XO' -Because 'beim Restore bleiben neuere lokale Dateien geschuetzt'
        (New-RobocopyArgument @script:baseArguments -OperationMode 'Backup' -DryRun $false) |
            Should -Not -Contain '/XO' -Because 'beim Backup gewinnt die Quelle, auch mit aelterem Zeitstempel'
    }

    It 'lists only in dry run mode and copies otherwise' {
        $dry = New-RobocopyArgument @script:baseArguments -OperationMode 'Backup' -DryRun $true
        $dry | Should -Contain '/L'
        $dry | Should -Not -Contain '/NFL'

        $wet = New-RobocopyArgument @script:baseArguments -OperationMode 'Backup' -DryRun $false
        $wet | Should -Not -Contain '/L'
        $wet | Should -Contain '/NFL'
        $wet | Should -Contain '/NDL'
    }

    It 'carries the copy policy switches' {
        $arguments = New-RobocopyArgument @script:baseArguments -OperationMode 'Backup' -DryRun $false
        foreach ($expected in @('/E', '/XJ', '/FFT', '/COPY:DAT', '/DCOPY:DAT', '/NP')) {
            $arguments | Should -Contain $expected
        }
    }

    It 'applies threads, retries and the log file from the run policy' {
        # Werte in einer Kopie ersetzen: Windows PowerShell 5.1 lehnt einen
        # Parameter ab, der zugleich im Splat und einzeln angegeben wird.
        $fastArguments = $script:baseArguments.Clone()
        $fastArguments.Threads = 32
        $fastArguments.RetryCount = 0
        $fastArguments.RetryWaitSeconds = 1
        $fastArguments.LogFile = 'X:\anderes.log'

        $arguments = New-RobocopyArgument @fastArguments -OperationMode 'Backup' -DryRun $false
        $arguments | Should -Contain '/MT:32'
        $arguments | Should -Contain '/R:0'
        $arguments | Should -Contain '/W:1'
        $arguments | Should -Contain '/UNILOG+:X:\anderes.log'
    }

    It 'appends every excluded file pattern after /XF' {
        $arguments = New-RobocopyArgument @script:baseArguments -OperationMode 'Backup' -DryRun $false
        $excludeIndex = [array]::IndexOf($arguments, '/XF')
        $excludeIndex | Should -BeGreaterThan -1
        $arguments[($excludeIndex + 1)] | Should -Be 'thumbs.db'
        $arguments[($excludeIndex + 2)] | Should -Be '*.tmp'
    }
}

Describe 'New-OperationLogHeader' {
    BeforeAll {
        $script:headerArguments = @{
            OperationName = 'Sicherung'; BackupRootPath = 'X:\b'; FreeSpaceGb = 12.5
            FileSystem = 'NTFS'; BitLockerStatus = 'BitLocker: On'; Threads = 8
            RunPolicy = [pscustomobject]@{ RetryCount = 1; RetryWaitSeconds = 3; SuperFast = $false }
            DryRun = $false
        }
    }

    It 'records the run parameters for later diagnosis' {
        $header = New-OperationLogHeader @script:headerArguments -OperationMode 'Backup'
        ($header -join "`n") | Should -Match 'Vorgang: Sicherung'
        ($header -join "`n") | Should -Match 'Threads: 8'
        ($header -join "`n") | Should -Match '/R:1 /W:3'
        ($header -join "`n") | Should -Match 'Dateisystem: NTFS'
        ($header -join "`n") | Should -Match 'Superschnell-Modus: Nein'
        ($header -join "`n") | Should -Match 'Dry-Run: Nein'
    }

    It 'omits the restore block for a backup' {
        $header = New-OperationLogHeader @script:headerArguments -OperationMode 'Backup' `
            -IntegrityPolicy 'Verify' -SourceComputer 'PC' -SourceUser 'u'
        ($header -join "`n") | Should -Not -Match 'Restore-Integritaetsrichtlinie'
        ($header -join "`n") | Should -Not -Match 'Ordnerzuordnungen'
    }

    It 'documents integrity state and folder mapping for a restore' {
        $plan = @([pscustomobject]@{ Name = 'Dokumente'; Path = 'X:\b\Dokumente'; TargetPath = 'C:\U\Dokumente' })
        $header = New-OperationLogHeader @script:headerArguments -OperationMode 'Restore' `
            -IntegrityPolicy 'Verify' -IntegrityVerified $true -IntegrityOverride $false `
            -IntegrityVerificationPerformed $true -SourceComputer 'PC' -SourceUser 'u' `
            -TargetMode 'Profile' -IsMigration $false -TargetRoot 'C:\U' -FolderPlan $plan

        $text = $header -join "`n"
        $text | Should -Match 'Restore-Integritaetsrichtlinie: Verify'
        $text | Should -Match 'Restore-Integritaet bestaetigt: True'
        $text | Should -Match 'Quellidentitaet: PC\\u'
        $text | Should -Match 'Wiederherstellungsart: Profile'
        $text | Should -Match 'Ordnerzuordnungen:'
        $text | Should -Match 'X:\\b\\Dokumente -> C:\\U\\Dokumente'
    }

    It 'includes preflight notices and never yields null entries' {
        $header = New-OperationLogHeader @script:headerArguments -OperationMode 'Backup' `
            -PreflightNotices @('Hinweis: eine Junction uebersprungen.')
        ($header -join "`n") | Should -Match 'Junction uebersprungen'
        # Null-Eintraege wuerden beim Schreiben leere Zeilen erzeugen.
        @($header | Where-Object { $null -eq $_ }).Count | Should -Be 0
    }

    It 'marks super fast and dry run in the log' {
        # Werte in einer Kopie ersetzen, siehe New-RobocopyArgument.
        $fastArguments = $script:headerArguments.Clone()
        $fastArguments.RunPolicy = [pscustomobject]@{ RetryCount = 0; RetryWaitSeconds = 1; SuperFast = $true }
        $fastArguments.DryRun = $true

        $header = New-OperationLogHeader @fastArguments -OperationMode 'Backup'
        ($header -join "`n") | Should -Match 'Superschnell-Modus: Ja'
        ($header -join "`n") | Should -Match 'Dry-Run: Ja'
    }
}

Describe 'Get-OperationLabels' {
    It 'names a backup, a restore and a simulation differently' {
        $backup = Get-OperationLabels -OperationMode 'Backup' -DryRun $false
        $restore = Get-OperationLabels -OperationMode 'Restore' -DryRun $false
        $simulation = Get-OperationLabels -OperationMode 'Backup' -DryRun $true

        $backup.Operation | Should -Not -Be $restore.Operation
        $simulation.Operation | Should -Not -Be $backup.Operation
        $backup.Success | Should -Not -Be $restore.Success
        $simulation.Success | Should -Not -Be $backup.Success
    }

    It 'provides a non-empty label for every outcome' {
        foreach ($operationMode in @('Backup', 'Restore')) {
            foreach ($dryRun in @($true, $false)) {
                $labels = Get-OperationLabels -OperationMode $operationMode -DryRun $dryRun
                foreach ($field in @('Operation', 'Success', 'Failure', 'Cancelled')) {
                    $labels.$field | Should -Not -BeNullOrEmpty `
                        -Because "$field fehlt fuer $operationMode (DryRun $dryRun)"
                }
            }
        }
    }

    It 'keeps the restore wording out of a dry run backup' {
        $simulation = Get-OperationLabels -OperationMode 'Backup' -DryRun $true
        $simulation.Failure | Should -Not -Match 'Wiederherstellung|Restore'
    }
}

Describe 'Confirm-OperationStart' {
    It 'treats a bare Enter as yes for a backup' {
        # Eine Sicherung ist additiv und daher per Enter bestaetigt.
        Mock Read-Host { return '' }
        Confirm-OperationStart -OperationMode 'Backup' | Should -BeTrue
    }

    It 'treats a bare Enter as no for a restore' {
        # Eine Wiederherstellung veraendert lokale Dateien; hier darf ein
        # unbedachtes Enter den Vorgang nicht starten.
        Mock Read-Host { return '' }
        Confirm-OperationStart -OperationMode 'Restore' | Should -BeFalse
    }

    It 'accepts the documented confirmations in both languages' {
        foreach ($answer in @('j', 'ja', 'y', 'yes', 'J', 'YES')) {
            Mock Read-Host { return $answer }.GetNewClosure()
            Confirm-OperationStart -OperationMode 'Restore' | Should -BeTrue -Because "'$answer' bestaetigt"
        }
    }

    It 'rejects anything else' {
        foreach ($answer in @('n', 'nein', 'no', 'x', 'jain')) {
            Mock Read-Host { return $answer }.GetNewClosure()
            Confirm-OperationStart -OperationMode 'Backup' | Should -BeFalse -Because "'$answer' bestaetigt nicht"
        }
    }
}

Describe 'Resolve-UnattendedRestoreIntegrity' {
    It 'requires no verification for an already verified backup' {
        $decision = Resolve-UnattendedRestoreIntegrity -TargetMode 'Profile' -Policy 'Verify' `
            -ManifestExists $true -AlreadyVerified $true
        $decision.VerificationRequired | Should -BeFalse
        $decision.IntegrityOverride | Should -BeFalse
    }

    It 'verifies before restoring into the profile when the policy demands it' {
        $decision = Resolve-UnattendedRestoreIntegrity -TargetMode 'Profile' -Policy 'Verify' `
            -ManifestExists $true -AlreadyVerified $false
        $decision.VerificationRequired | Should -BeTrue
        $decision.IntegrityOverride | Should -BeFalse
    }

    It 'refuses the Verify policy without a manifest' {
        { Resolve-UnattendedRestoreIntegrity -TargetMode 'Profile' -Policy 'Verify' `
            -ManifestExists $false -AlreadyVerified $false } | Should -Throw '*kein Pruefsummenmanifest*'
    }

    It 'refuses an unverified backup under RequireVerified' {
        { Resolve-UnattendedRestoreIntegrity -TargetMode 'Profile' -Policy 'RequireVerified' `
            -ManifestExists $true -AlreadyVerified $false } | Should -Throw '*bereits erfolgreich geprueftes*'
    }

    It 'records an override instead of failing under Warn' {
        $decision = Resolve-UnattendedRestoreIntegrity -TargetMode 'Profile' -Policy 'Warn' `
            -ManifestExists $false -AlreadyVerified $false
        $decision.VerificationRequired | Should -BeFalse
        $decision.IntegrityOverride | Should -BeTrue
    }

    It 'never blocks a copy into a separate folder' {
        # Ein separater Zielordner laesst vorhandene Daten unberuehrt, deshalb
        # gilt dort auch die strengste Richtlinie nicht.
        foreach ($policy in @('Verify', 'RequireVerified', 'Warn')) {
            $decision = Resolve-UnattendedRestoreIntegrity -TargetMode 'Folder' -Policy $policy `
                -ManifestExists $false -AlreadyVerified $false
            $decision.VerificationRequired | Should -BeFalse -Because "Richtlinie $policy"
            $decision.IntegrityOverride | Should -BeTrue -Because "Richtlinie $policy vermerkt die fehlende Pruefung"
        }
    }
}

Describe 'New-RestorePreviewRecord' {
    It 'carries the conflict counts and folder mapping to the user interface' {
        $preflight = [pscustomobject]@{
            MissingFileCount = 5; OverwriteFileCount = 2; ProtectedNewerFileCount = 1
            RequiredFileCount = 7; RequiredBytes = 1024; OverwriteExamples = @('a.txt')
        }
        $plan = @(
            [pscustomobject]@{ Name = 'Dokumente'; Path = 'X:\b\Dokumente'; TargetPath = 'C:\U\Dokumente'; IsCustom = $false }
            [pscustomobject]@{ Name = 'Extra'; Path = 'X:\b\Extra'; TargetPath = 'C:\U\Extra'; IsCustom = $true }
        )

        $preview = New-RestorePreviewRecord -Preflight $preflight -FolderPlan $plan `
            -ManifestExists $true -ChecksumsVerifiedAt '2026-01-01' -IntegrityPolicy 'Verify' `
            -SourceComputer 'PC' -SourceUser 'u' -SourcePath 'X:\b' -SourceDisplayName 'PC_u' `
            -SourceComplete $true -TargetMode 'Profile' -TargetRoot 'C:\U' -IsMigration $false

        $preview.MissingFiles | Should -Be 5
        $preview.OverwriteFiles | Should -Be 2
        $preview.ProtectedNewerFiles | Should -Be 1
        $preview.PlannedFiles | Should -Be 7
        $preview.ChecksumManifestExists | Should -BeTrue
        $preview.ChecksumsVerifiedAt | Should -Be '2026-01-01'

        @($preview.FolderMappings).Count | Should -Be 2
        ($preview.FolderMappings | Where-Object { $_.Name -eq 'Extra' }).IsCustom | Should -BeTrue
        ($preview.FolderMappings | Where-Object { $_.Name -eq 'Dokumente' }).IsCustom | Should -BeFalse
        ($preview.FolderMappings | Where-Object { $_.Name -eq 'Dokumente' }).Target | Should -Be 'C:\U\Dokumente'
    }
}

Describe 'Add-CustomBackupFolderDefinitions' {
    BeforeAll {
        $script:baseDefinitions = @(
            [pscustomobject]@{ Name = 'Dokumente'; Path = (Join-Path $TestDrive 'lib\Dokumente'); IsCustom = $false }
        )
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'lib\Dokumente') -Force | Out-Null
    }

    It 'returns the standard definitions unchanged without custom entries' {
        $specs = @([pscustomobject]@{ Name = 'Dokumente'; Path = $null; IsCustom = $false })
        $result = Add-CustomBackupFolderDefinitions -StandardDefinitions $script:baseDefinitions `
            -SelectedFolderSpecs $specs -FolderMetadataFile (Join-Path $TestDrive 'kein-ordner.json')
        @($result).Count | Should -Be 1
    }

    It 'appends a valid custom folder with its normalised path' {
        $customPath = Join-Path $TestDrive 'zusatz'
        New-Item -ItemType Directory -Path $customPath -Force | Out-Null
        $specs = @([pscustomobject]@{ Name = 'Zusatz'; Path = $customPath; IsCustom = $true })

        $result = Add-CustomBackupFolderDefinitions -StandardDefinitions $script:baseDefinitions `
            -SelectedFolderSpecs $specs -FolderMetadataFile (Join-Path $TestDrive 'kein-ordner.json')

        @($result).Count | Should -Be 2
        $added = $result | Where-Object { $_.Name -eq 'Zusatz' }
        $added.IsCustom | Should -BeTrue
        $added.Path | Should -Be (Get-NormalizedFullPath $customPath)
    }

    It 'refuses a custom folder that does not exist' {
        $specs = @([pscustomobject]@{ Name = 'Fehlt'; Path = (Join-Path $TestDrive 'gibt-es-nicht'); IsCustom = $true })
        { Add-CustomBackupFolderDefinitions -StandardDefinitions $script:baseDefinitions `
            -SelectedFolderSpecs $specs -FolderMetadataFile (Join-Path $TestDrive 'kein-ordner.json') } |
            Should -Throw '*wurde nicht gefunden*'
    }

    It 'refuses the whole user profile as a custom folder' {
        $specs = @([pscustomobject]@{ Name = 'Profil'; Path = $env:USERPROFILE; IsCustom = $true })
        { Add-CustomBackupFolderDefinitions -StandardDefinitions $script:baseDefinitions `
            -SelectedFolderSpecs $specs -FolderMetadataFile (Join-Path $TestDrive 'kein-ordner.json') } |
            Should -Throw '*gesamte Benutzerprofil*'
    }

    It 'refuses a reserved folder name' {
        $customPath = Join-Path $TestDrive 'zusatz2'
        New-Item -ItemType Directory -Path $customPath -Force | Out-Null
        $specs = @([pscustomobject]@{ Name = '_logs'; Path = $customPath; IsCustom = $true })
        { Add-CustomBackupFolderDefinitions -StandardDefinitions $script:baseDefinitions `
            -SelectedFolderSpecs $specs -FolderMetadataFile (Join-Path $TestDrive 'kein-ordner.json') } |
            Should -Throw '*reserviert*'
    }

    It 'refuses a name that a standard library already uses' {
        $customPath = Join-Path $TestDrive 'zusatz3'
        New-Item -ItemType Directory -Path $customPath -Force | Out-Null
        $specs = @([pscustomobject]@{ Name = 'Dokumente'; Path = $customPath; IsCustom = $true })
        { Add-CustomBackupFolderDefinitions -StandardDefinitions $script:baseDefinitions `
            -SelectedFolderSpecs $specs -FolderMetadataFile (Join-Path $TestDrive 'kein-ordner.json') } |
            Should -Throw '*bereits vergeben*'
    }

    It 'refuses a custom folder that overlaps a selected library' {
        $nested = Join-Path $TestDrive 'lib\Dokumente\Unterordner'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        $specs = @([pscustomobject]@{ Name = 'Verschachtelt'; Path = $nested; IsCustom = $true })
        { Add-CustomBackupFolderDefinitions -StandardDefinitions $script:baseDefinitions `
            -SelectedFolderSpecs $specs -FolderMetadataFile (Join-Path $TestDrive 'kein-ordner.json') } |
            Should -Throw '*ueberschneidet sich*'
    }

    It 'refuses reusing a custom name that the backup recorded for another path' {
        $customPath = Join-Path $TestDrive 'zusatz4'
        $otherPath = Join-Path $TestDrive 'zusatz4-anders'
        New-Item -ItemType Directory -Path $customPath, $otherPath -Force | Out-Null
        $metadataFile = Join-Path $TestDrive 'vorhandene-ordner.json'
        Set-Content -LiteralPath $metadataFile -Encoding UTF8 -Value (
            ConvertTo-Json -Depth 4 -InputObject @(
                [pscustomobject]@{ Name = 'Zusatz'; OriginalPath = $otherPath; BackedUpAt = '2026-01-01' }
            ))

        $specs = @([pscustomobject]@{ Name = 'Zusatz'; Path = $customPath; IsCustom = $true })
        { Add-CustomBackupFolderDefinitions -StandardDefinitions $script:baseDefinitions `
            -SelectedFolderSpecs $specs -FolderMetadataFile $metadataFile } |
            Should -Throw '*bereits fuer*'
    }

    It 'accepts a custom name that keeps its recorded path' {
        $customPath = Join-Path $TestDrive 'zusatz5'
        New-Item -ItemType Directory -Path $customPath -Force | Out-Null
        $metadataFile = Join-Path $TestDrive 'gleiche-ordner.json'
        Set-Content -LiteralPath $metadataFile -Encoding UTF8 -Value (
            ConvertTo-Json -Depth 4 -InputObject @(
                [pscustomobject]@{ Name = 'Zusatz5'; OriginalPath = $customPath; BackedUpAt = '2026-01-01' }
            ))

        $specs = @([pscustomobject]@{ Name = 'Zusatz5'; Path = $customPath; IsCustom = $true })
        $result = Add-CustomBackupFolderDefinitions -StandardDefinitions $script:baseDefinitions `
            -SelectedFolderSpecs $specs -FolderMetadataFile $metadataFile
        @($result).Name | Should -Contain 'Zusatz5'
    }
}
