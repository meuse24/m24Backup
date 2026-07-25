# Quelltext-Invarianten, die sich nur am geparsten Code pruefen lassen.
#
# Hintergrund: PowerShell behandelt die typografischen Anfuehrungszeichen
# „ (U+201E), “ (U+201C) und ” (U+201D) wie ein doppeltes Anfuehrungszeichen
# sowie ‘ (U+2018) und ’ (U+2019) wie ein einfaches. Steht ein solches Zeichen
# in einem mit " gesetzten String, endet der String dort - der Text zerfaellt
# in mehrere Argumente. Das faellt weder beim Parsen noch in der Syntaxpruefung
# auf, sondern erst, wenn genau diese Zeile zur Laufzeit ausgefuehrt wird.
#
# Ein deutschsprachiges Projekt verwendet solche Zeichen zwangslaeufig; diese
# Tests stellen sicher, dass sie ausschliesslich in einfach gesetzten Strings
# stehen.

BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    $script:sourceFiles = @(
        'Bibliothekssicherung-GUI.ps1',
        'Bibliothekssicherung.ps1',
        'M24Backup.Shared.ps1',
        'build.ps1',
        'release.ps1'
    ) | ForEach-Object { Join-Path $script:repoRoot $_ } | Where-Object { Test-Path -LiteralPath $_ }

    # Zeichen, die PowerShell als String-Begrenzer akzeptiert.
    $script:smartQuotes = @([char]0x201E, [char]0x201C, [char]0x201D, [char]0x2018, [char]0x2019)

    function Get-ParsedFile {
        param([string]$Path)
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
        return [pscustomobject]@{ Ast = $ast; Tokens = $tokens; Errors = $parseErrors }
    }
}

Describe 'Source files parse cleanly' {
    It 'has no parse errors in <_>' -ForEach @(
        'Bibliothekssicherung-GUI.ps1', 'Bibliothekssicherung.ps1', 'M24Backup.Shared.ps1'
    ) {
        $parsed = Get-ParsedFile -Path (Join-Path $script:repoRoot $_)
        @($parsed.Errors).Count | Should -Be 0
    }
}

Describe 'Typographic quotes stay inside string literals' {
    It 'never places a smart quote outside a string or comment' {
        $findings = @()
        foreach ($path in $script:sourceFiles) {
            $text = [System.IO.File]::ReadAllText($path)
            $parsed = Get-ParsedFile -Path $path

            # Zeichenbereiche, in denen ein solches Zeichen unbedenklich ist.
            $safeRanges = @($parsed.Tokens |
                Where-Object { $_.Kind -in @('StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable', 'Comment') } |
                ForEach-Object { @{ Start = $_.Extent.StartOffset; End = $_.Extent.EndOffset } })

            for ($index = 0; $index -lt $text.Length; $index++) {
                if ($script:smartQuotes -notcontains $text[$index]) { continue }
                $inside = $false
                foreach ($range in $safeRanges) {
                    if ($index -ge $range.Start -and $index -lt $range.End) { $inside = $true; break }
                }
                if (-not $inside) {
                    $line = ($text.Substring(0, $index) -split "`n").Count
                    $findings += ("{0}:{1} enthaelt '{2}' ausserhalb eines Strings" -f (Split-Path $path -Leaf), $line, $text[$index])
                }
            }
        }
        $findings -join "`n" | Should -BeNullOrEmpty -Because 'ein solches Zeichen wuerde den Text an dieser Stelle zerreissen'
    }
}

Describe 'Localization calls receive exactly two texts' {
    It 'passes a German and an English text to every call' {
        # Faengt denselben Fehler von der anderen Seite: Zerfaellt ein Text,
        # entstehen zusaetzliche Argumente, die die Funktion nicht annimmt.
        $findings = @()
        foreach ($path in $script:sourceFiles) {
            $parsed = Get-ParsedFile -Path $path
            $calls = @($parsed.Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -in @('L', 'M', 'Get-M24Text')
            }, $true))

            foreach ($call in $calls) {
                # Kommandoname plus genau zwei Argumente.
                if ($call.CommandElements.Count -ne 3) {
                    $findings += ("{0}:{1} uebergibt {2} Argument(e) statt 2" -f `
                        (Split-Path $path -Leaf), $call.Extent.StartLineNumber, ($call.CommandElements.Count - 1))
                }
            }
        }
        $findings -join "`n" | Should -BeNullOrEmpty
    }

    It 'finds the localization calls it claims to check' {
        # Schutz vor einem stillschweigend wirkungslosen Test.
        $guiParsed = Get-ParsedFile -Path (Join-Path $script:repoRoot 'Bibliothekssicherung-GUI.ps1')
        $guiCalls = @($guiParsed.Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in @('L', 'M', 'Get-M24Text')
        }, $true))
        $guiCalls.Count | Should -BeGreaterThan 100
    }
}

Describe 'Restore preview texts survive formatting' {
    BeforeAll {
        . (Join-Path $script:repoRoot 'M24Backup.Shared.ps1')
        [void](Initialize-M24Localization -IsGerman $true)
        Set-Alias -Name L -Value Get-M24Text -Scope Script
    }

    It 'keeps the checksum recommendation intact' {
        # Genau der Textbaustein, an dem die Restore-Vorschau scheiterte:
        # Er wird nur erreicht, wenn ein Manifest existiert, aber seit der
        # letzten Sicherung nicht geprueft wurde.
        $text = L 'Integrität: Prüfsummen seit der letzten Sicherung nicht geprüft – Empfehlung: zuerst „Backup prüfen“ ausführen.' 'Integrity: checksums not verified since the last backup – recommendation: run “Verify backup” first.'
        $text | Should -Match 'Empfehlung'
        $text | Should -Match 'ausführen\.$' -Because 'der Text darf nicht am Anfuehrungszeichen abbrechen'
    }

    It 'keeps the migration notice intact and formattable' {
        $text = (L ("`r`n`r`n" + 'Diese Sicherung stammt von „{0}“. Die ausgewählten Daten werden in das aktuelle Benutzerprofil übernommen.') ("`r`n`r`n" + 'This backup originates from “{0}”. The selected data will be restored to the current user profile.')) -f 'PC\benutzer'
        $text | Should -Match 'PC\\benutzer'
        $text | Should -Match 'übernommen\.$'
    }
}
