<#
.SYNOPSIS
    Erzeugt reproduzierbare Testbaeume fuer die Pruefsummen-Benchmarks.

.DESCRIPTION
    Die Szenarien entsprechen dem Optimierungsplan checksum-optimization-plan.md.
    Alle Dateien werden aus einem festen Zufallskeim erzeugt, damit zwei Laeufe
    denselben Inhalt und damit dieselben Pruefsummen liefern.

.PARAMETER Scenario
    Small       20.000 Dateien zu 1-32 KiB in 40 Ordnern (rund 320 MiB)
    Medium      1.000 Dateien zu je 1 MiB
    Large       8 Dateien zu je 256 MiB (rund 2 GiB)
    WideFolder  100.000 Dateien zu 1 KiB in einem einzigen Ordner

.PARAMETER Path
    Zielverzeichnis. Ein vorhandenes Verzeichnis wird nur dann geloescht, wenn
    es die Markerdatei .m24-checksum-benchmark enthaelt, also von diesem Skript
    angelegt wurde. Jedes andere vorhandene Verzeichnis wird nicht angetastet.

.EXAMPLE
    .\New-M24BenchmarkTree.ps1 -Scenario Small -Path D:\bench\small
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Small', 'Medium', 'Large', 'WideFolder')][string]$Scenario,
    [Parameter(Mandatory)][string]$Path
)

$ErrorActionPreference = 'Stop'

$markerName = '.m24-checksum-benchmark'

function Assert-SafeBenchmarkPath {
    # Dieses Skript loescht rekursiv. Ein Tippfehler wie "D:\" oder ein
    # versehentlich angegebenes Arbeitsverzeichnis darf deshalb niemals
    # ausreichen, um Daten zu verlieren.
    param([string]$Candidate, [string]$MarkerName)

    if ([string]::IsNullOrWhiteSpace($Candidate)) { throw 'Es wurde kein Zielpfad angegeben.' }

    $full = [System.IO.Path]::GetFullPath($Candidate)
    $normalized = $full.TrimEnd('\')

    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized -eq $root.TrimEnd('\')) {
        throw "Der Benchmark-Pfad darf keine Laufwerkswurzel sein: $full"
    }

    # Das Temp-Verzeichnis ist fuer wegwerfbare Daten gedacht und liegt unter
    # Windows unterhalb des Benutzerprofils. Es bleibt deshalb von der
    # Profilsperre ausgenommen; die Markerpruefung gilt dort trotzdem.
    $temporaryRoot = ([System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())).TrimEnd('\')
    $insideTemporary = $normalized.StartsWith($temporaryRoot + '\', [StringComparison]::OrdinalIgnoreCase)

    # Verzeichnisse, unter denen ein Benchmark-Baum niemals liegen soll.
    $protectedRoots = @(
        [Environment]::GetFolderPath('UserProfile')
        [Environment]::GetFolderPath('Windows')
        [Environment]::GetFolderPath('ProgramFiles')
        [Environment]::GetFolderPath('ProgramFilesX86')
        [Environment]::GetFolderPath('CommonApplicationData')
        (Split-Path (Split-Path $PSCommandPath -Parent) -Parent)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($protected in $protectedRoots) {
        $protectedFull = ([System.IO.Path]::GetFullPath($protected)).TrimEnd('\')
        if ($normalized.Equals($protectedFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Der Benchmark-Pfad darf kein geschuetztes Verzeichnis sein: $full"
        }
        if ($normalized.StartsWith($protectedFull + '\', [StringComparison]::OrdinalIgnoreCase) -and -not $insideTemporary) {
            throw "Der Benchmark-Pfad darf nicht unterhalb von $protectedFull liegen: $full"
        }
    }

    if (Test-Path -LiteralPath $full -PathType Container) {
        # Nur ein Verzeichnis, das dieses Skript selbst angelegt hat, darf
        # rekursiv geloescht werden.
        if (-not (Test-Path -LiteralPath (Join-Path $full $MarkerName) -PathType Leaf)) {
            throw ("Das Verzeichnis existiert bereits und traegt keine Benchmark-Markierung: {0}`nLoeschen Sie es bei Bedarf selbst oder waehlen Sie einen neuen Pfad." -f $full)
        }
    } elseif (Test-Path -LiteralPath $full) {
        throw "Der Benchmark-Pfad zeigt auf eine Datei: $full"
    }

    return $full
}

$Path = Assert-SafeBenchmarkPath -Candidate $Path -MarkerName $markerName

if (Test-Path -LiteralPath $Path -PathType Container) {
    Write-Host "Loesche vorhandenen Benchmark-Baum $Path ..."
    Remove-Item -LiteralPath $Path -Recurse -Force
}
[void][System.IO.Directory]::CreateDirectory($Path)
Set-Content -LiteralPath (Join-Path $Path $markerName) -Value 'M24 checksum benchmark tree - dieses Verzeichnis darf vom Benchmark-Skript geloescht werden.' -Encoding ASCII

$random = New-Object Random 20260725
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

function New-BenchmarkFile {
    param([string]$FilePath, [int]$Size, $Random)
    $bytes = New-Object byte[] $Size
    if ($Size -gt 0) { $Random.NextBytes($bytes) }
    [System.IO.File]::WriteAllBytes($FilePath, $bytes)
}

switch ($Scenario) {
    'Small' {
        for ($folder = 0; $folder -lt 40; $folder++) {
            $folderPath = Join-Path $Path ("dir{0:D3}" -f $folder)
            [void][System.IO.Directory]::CreateDirectory($folderPath)
            for ($file = 0; $file -lt 500; $file++) {
                New-BenchmarkFile -FilePath (Join-Path $folderPath ("f{0:D4}.bin" -f $file)) -Size $random.Next(1024, 32768) -Random $random
            }
        }
    }
    'Medium' {
        for ($folder = 0; $folder -lt 10; $folder++) {
            $folderPath = Join-Path $Path ("dir{0:D2}" -f $folder)
            [void][System.IO.Directory]::CreateDirectory($folderPath)
            for ($file = 0; $file -lt 100; $file++) {
                New-BenchmarkFile -FilePath (Join-Path $folderPath ("m{0:D3}.bin" -f $file)) -Size 1MB -Random $random
            }
        }
    }
    'Large' {
        # Blockweise schreiben, damit kein 256-MiB-Array im Speicher entsteht.
        $block = New-Object byte[] (16MB)
        $random.NextBytes($block)
        for ($file = 0; $file -lt 8; $file++) {
            $stream = [System.IO.File]::Create((Join-Path $Path ("large{0:D2}.bin" -f $file)))
            try {
                for ($chunk = 0; $chunk -lt 16; $chunk++) {
                    $block[0] = [byte]($file * 16 + $chunk)
                    $stream.Write($block, 0, $block.Length)
                }
            } finally { $stream.Dispose() }
        }
    }
    'WideFolder' {
        # Prueft das Speicherverhalten der Aufzaehlung in einem einzelnen sehr
        # grossen Verzeichnis.
        for ($file = 0; $file -lt 100000; $file++) {
            New-BenchmarkFile -FilePath (Join-Path $Path ("w{0:D6}.bin" -f $file)) -Size 1024 -Random $random
        }
    }
}

$stopwatch.Stop()
# Die Markerdatei gehoert nicht zu den Nutzdaten des Szenarios.
$files = @([System.IO.Directory]::GetFiles($Path, '*', [System.IO.SearchOption]::AllDirectories) |
        Where-Object { [System.IO.Path]::GetFileName($_) -ne $markerName })
[int64]$bytes = 0
foreach ($file in $files) { $bytes += (New-Object System.IO.FileInfo $file).Length }

Write-Host ("Szenario {0}: {1:N0} Dateien, {2:N1} MiB, erzeugt in {3:N1} s" -f $Scenario, $files.Count, ($bytes / 1MB), $stopwatch.Elapsed.TotalSeconds)
Write-Host ("Pfad: {0}" -f $Path)
