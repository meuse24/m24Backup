# Tests fuer den Statusprotokoll-Vertrag zwischen Worker und Oberflaeche.
# Sender (Format-M24StatusMessage) und Empfaenger (ConvertFrom-M24StatusMessage)
# muessen exakt zueinander passen; frueher waren beide Seiten unabhaengig
# voneinander als Literale kodiert.

BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:repoRoot 'M24Backup.Shared.ps1')

    function Get-AstForFile {
        param([string]$Path)
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "Parse errors in ${Path}: $($parseErrors.Count)" }
        return $ast
    }
}

Describe 'Status message contract' {
    It 'declares every type the user interface has to handle' {
        $types = Get-M24StatusMessageTypes
        foreach ($expected in @(
            'VORSCHAU', 'SCANWARNUNG', 'STATUS', 'FERTIG', 'FEHLER', 'ABGEBROCHEN',
            'PRUEFUNG', 'PRUEFSUMME', 'KOPIERVORGANG', 'ABBRUCHLAEUFT', 'FORTSCHRITT',
            'ABBRUCHWARTET', 'HASHFORTSCHRITT', 'RESTOREPRUEFUNG')) {
            $types | Should -Contain $expected
        }
    }

    It 'recognises known and unknown types' {
        Test-M24StatusMessageType -Type 'FORTSCHRITT' | Should -BeTrue
        Test-M24StatusMessageType -Type 'GIBTESNICHT' | Should -BeFalse
    }
}

Describe 'Format-M24StatusMessage' {
    It 'builds a progress line in the documented order' {
        Format-M24StatusMessage -Type 'FORTSCHRITT' -Fields @('2', '5', 'Dokumente') |
            Should -Be 'FORTSCHRITT|2|5|Dokumente'
    }

    It 'builds a plain text line' {
        Format-M24StatusMessage -Type 'STATUS' -Fields @('Sicherung wird vorbereitet ...') |
            Should -Be 'STATUS|Sicherung wird vorbereitet ...'
    }

    It 'rejects an unknown message type' {
        { Format-M24StatusMessage -Type 'TIPPFEHLER' -Fields @('x') } | Should -Throw '*Unknown status message type*'
    }

    It 'rejects a wrong field count' {
        { Format-M24StatusMessage -Type 'FORTSCHRITT' -Fields @('1', '2') } | Should -Throw '*expects*field*'
        { Format-M24StatusMessage -Type 'HASHFORTSCHRITT' -Fields @('1', '2', '3') } | Should -Throw '*expects*field*'
    }

    It 'rejects a separator inside a leading field' {
        { Format-M24StatusMessage -Type 'FORTSCHRITT' -Fields @('1|2', '5', 'Bilder') } |
            Should -Throw "*must not contain*"
    }

    It 'accepts both documented forms of the restore verification message' {
        Format-M24StatusMessage -Type 'RESTOREPRUEFUNG' -Fields @('Pruefung laeuft') |
            Should -Be 'RESTOREPRUEFUNG|Pruefung laeuft'
        Format-M24StatusMessage -Type 'RESTOREPRUEFUNG' -Fields @('1', '3', 'Musik') |
            Should -Be 'RESTOREPRUEFUNG|1|3|Musik'
    }
}

Describe 'ConvertFrom-M24StatusMessage' {
    It 'parses a progress line into named fields' {
        $message = ConvertFrom-M24StatusMessage -Line 'FORTSCHRITT|2|5|Dokumente'
        $message.Type | Should -Be 'FORTSCHRITT'
        $message.IsKnownType | Should -BeTrue
        $message.Current | Should -Be 2
        $message.Total | Should -Be 5
        $message.FolderName | Should -Be 'Dokumente'
    }

    It 'parses the wait message including its seconds field' {
        $message = ConvertFrom-M24StatusMessage -Line 'ABBRUCHWARTET|1|2|Bilder|7'
        $message.Current | Should -Be 1
        $message.Total | Should -Be 2
        $message.FolderName | Should -Be 'Bilder'
        $message.WaitedSeconds | Should -Be 7
    }

    It 'parses hash progress as 64 bit numbers' {
        $message = ConvertFrom-M24StatusMessage -Line 'HASHFORTSCHRITT|1200|5368709120'
        $message.Files | Should -Be 1200
        $message.Bytes | Should -Be 5368709120
    }

    It 'keeps a separator inside a trailing text field' {
        # Fehlermeldungen duerfen '|' enthalten und wurden frueher abgeschnitten.
        $message = ConvertFrom-M24StatusMessage -Line 'FEHLER|Zugriff verweigert: a|b'
        $message.Text | Should -Be 'Zugriff verweigert: a|b'
    }

    It 'distinguishes both forms of the restore verification message' {
        $announcement = ConvertFrom-M24StatusMessage -Line 'RESTOREPRUEFUNG|Integritaet wird geprueft'
        $announcement.Text | Should -Be 'Integritaet wird geprueft'
        $announcement.FolderName | Should -BeNullOrEmpty

        $progress = ConvertFrom-M24StatusMessage -Line 'RESTOREPRUEFUNG|2|4|Videos'
        $progress.Current | Should -Be 2
        $progress.Total | Should -Be 4
        $progress.FolderName | Should -Be 'Videos'
    }

    It 'reports an unknown type without throwing' {
        $message = ConvertFrom-M24StatusMessage -Line 'GIBTESNICHT|1|2'
        $message.IsKnownType | Should -BeFalse
        $message.Type | Should -Be 'GIBTESNICHT'
    }

    It 'tolerates empty and malformed input' {
        (ConvertFrom-M24StatusMessage -Line '').IsKnownType | Should -BeFalse
        (ConvertFrom-M24StatusMessage -Line $null).IsKnownType | Should -BeFalse
        # Zu wenige Felder duerfen keinen Fehler ausloesen; fehlende bleiben leer.
        $short = ConvertFrom-M24StatusMessage -Line 'FORTSCHRITT|3'
        $short.Current | Should -Be 3
        $short.FolderName | Should -BeNullOrEmpty
    }

    It 'ignores surrounding whitespace written by the atomic file writer' {
        $message = ConvertFrom-M24StatusMessage -Line "  FERTIG|Sicherung erfolgreich abgeschlossen.`r`n"
        $message.Type | Should -Be 'FERTIG'
        $message.Text | Should -Be 'Sicherung erfolgreich abgeschlossen.'
    }
}

Describe 'Sender and receiver stay aligned with the contract' {
    # Diese Tests fangen genau den Fehler ab, der frueher erst zur Laufzeit
    # auffiel: ein Typ, den nur eine der beiden Seiten kennt.

    It 'sends only types that the contract declares' {
        $ast = Get-AstForFile -Path (Join-Path $script:repoRoot 'Bibliothekssicherung.ps1')
        $sentTypes = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Write-BackupStatus'
        }, $true) | ForEach-Object {
            $elements = $_.CommandElements
            for ($i = 0; $i -lt $elements.Count - 1; $i++) {
                if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $elements[$i].ParameterName -eq 'Type') {
                    $value = $elements[$i + 1]
                    if ($value -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                        $value.Value
                    }
                }
            }
        } | Sort-Object -Unique)

        $sentTypes.Count | Should -BeGreaterThan 0 -Because 'der Worker muss Statusmeldungen senden'
        foreach ($type in $sentTypes) {
            Test-M24StatusMessageType -Type $type | Should -BeTrue -Because "der Worker sendet '$type'"
        }
    }

    It 'handles every contract type in the user interface' {
        $guiText = Get-Content -LiteralPath (Join-Path $script:repoRoot 'Bibliothekssicherung-GUI.ps1') -Raw
        foreach ($type in Get-M24StatusMessageTypes) {
            $guiText | Should -Match ('"{0}"' -f [regex]::Escape($type)) `
                -Because "die Oberflaeche muss den Nachrichtentyp '$type' behandeln"
        }
    }

    It 'reads only field names that the parser actually produces' {
        # Faengt Tippfehler wie $message.Folder statt $message.FolderName ab,
        # die sonst still zu einer leeren Anzeige fuehren wuerden.
        $available = @((ConvertFrom-M24StatusMessage -Line 'FORTSCHRITT|1|2|Bilder').PSObject.Properties.Name)
        $ast = Get-AstForFile -Path (Join-Path $script:repoRoot 'Bibliothekssicherung-GUI.ps1')
        $used = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.MemberExpressionAst] -and
                $node.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $node.Expression.VariablePath.UserPath -eq 'statusMessage' -and
                $node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true) | ForEach-Object { $_.Member.Value } | Sort-Object -Unique)

        $used.Count | Should -BeGreaterThan 0 -Because 'die Oberflaeche muss die geparsten Felder verwenden'
        foreach ($field in $used) {
            $available | Should -Contain $field -Because "die Oberflaeche liest '`$statusMessage.$field'"
        }
    }

    It 'no longer decodes the protocol positionally in the user interface' {
        # Die Oberflaeche liest die Felder ueber ConvertFrom-M24StatusMessage;
        # ein Rueckfall auf $parts[n] waere ein Rueckschritt.
        $guiText = Get-Content -LiteralPath (Join-Path $script:repoRoot 'Bibliothekssicherung-GUI.ps1') -Raw
        $guiText | Should -Match 'ConvertFrom-M24StatusMessage'
        $guiText | Should -Not -Match '\$parts\['
    }
}

Describe 'Status protocol round trip' {
    It 'parses back every message the sender can produce' {
        $samples = @(
            @{ Type = 'STATUS';          Fields = @('Sicherung wird vorbereitet ...') }
            @{ Type = 'VORSCHAU';        Fields = @('Konfliktvorschau ist bereit.') }
            @{ Type = 'SCANWARNUNG';     Fields = @('Warnungen warten auf Freigabe.') }
            @{ Type = 'PRUEFUNG';        Fields = @('1', '3', 'Dokumente') }
            @{ Type = 'PRUEFSUMME';      Fields = @('2', '3', 'Bilder') }
            @{ Type = 'KOPIERVORGANG';   Fields = @('3', '3', 'Musik') }
            @{ Type = 'ABBRUCHLAEUFT';   Fields = @('1', '2', 'Videos') }
            @{ Type = 'ABBRUCHWARTET';   Fields = @('1', '2', 'Videos', '4') }
            @{ Type = 'FORTSCHRITT';     Fields = @('2', '4', 'Downloads') }
            @{ Type = 'HASHFORTSCHRITT'; Fields = @('99', '1048576') }
            @{ Type = 'RESTOREPRUEFUNG'; Fields = @('1', '2', 'Desktop') }
            @{ Type = 'FERTIG';          Fields = @('Fertig.') }
            @{ Type = 'FEHLER';          Fields = @('Fehler in: Dokumente') }
            @{ Type = 'ABGEBROCHEN';     Fields = @('Abgebrochen.') }
        )

        foreach ($sample in $samples) {
            $line = Format-M24StatusMessage -Type $sample.Type -Fields $sample.Fields
            $parsed = ConvertFrom-M24StatusMessage -Line $line
            $parsed.IsKnownType | Should -BeTrue -Because "'$($sample.Type)' muss wieder erkannt werden"
            $parsed.Type | Should -Be $sample.Type

            # Die uebertragenen Werte muessen feldweise zurueckkommen.
            $contract = Get-M24StatusMessageContract
            $form = @($contract[$sample.Type] | Where-Object { $_.Count -eq $sample.Fields.Count } | Select-Object -First 1)
            $fieldNames = @($form[0])
            for ($i = 0; $i -lt $fieldNames.Count; $i++) {
                [string]$parsed.($fieldNames[$i]) | Should -Be ([string]$sample.Fields[$i]) `
                    -Because "$($sample.Type).$($fieldNames[$i]) muss unveraendert ankommen"
            }
        }
    }
}
