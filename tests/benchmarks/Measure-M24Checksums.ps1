<#
.SYNOPSIS
    Misst die Pruefsummenverarbeitung ueber einen Testbaum.

.DESCRIPTION
    Misst die drei Laeufe, die im Optimierungsplan als Szenarien 5 bis 7
    beschrieben sind:

      Erstlauf      alle Dateien werden gehasht
      Folgelauf     alle Pruefsummen werden aus dem Manifest wiederverwendet
      Verifikation  alle Dateien werden erneut vollstaendig gelesen

    Neben den Zeiten werden die Sammlungen der Generationen 0, 1 und 2
    ausgewiesen. Ohne diese Zaehler bleibt die Allokationswirkung unsichtbar,
    die bei kleinen Dateien der wichtigste Kostenfaktor ist.

    Mit -Baseline laesst sich eine aeltere Fassung von M24Backup.Shared.ps1
    gegen die aktuelle messen, zum Beispiel aus git:
        git show HEAD:M24Backup.Shared.ps1 > alt.ps1

.PARAMETER Path
    Testbaum, erzeugt mit New-M24BenchmarkTree.ps1.

.PARAMETER Runs
    Anzahl der Wiederholungen. Ausgewertet werden Median und Spannweite; der
    Plan verlangt mindestens fuenf Laeufe fuer belastbare Vergleiche.

.PARAMETER SharedScript
    Zu messende Fassung von M24Backup.Shared.ps1.

.PARAMETER ChangedPercent
    Anteil der Dateien, die vor dem Folgelauf veraendert werden. 0 misst die
    vollstaendige Wiederverwendung, 1 einen typischen Folgelauf.

.EXAMPLE
    .\Measure-M24Checksums.ps1 -Path D:\bench\small -Runs 5
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [int]$Runs = 5,
    [string]$SharedScript,
    [ValidateRange(0, 100)][int]$ChangedPercent = 0
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot steht in Standardwerten von Parametern nicht zuverlaessig zur
# Verfuegung, deshalb wird der Pfad erst hier aufgeloest.
if ([string]::IsNullOrWhiteSpace($SharedScript)) {
    $repositoryRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
    $SharedScript = Join-Path $repositoryRoot 'M24Backup.Shared.ps1'
}
. $SharedScript

$manifestPath = Join-Path ([System.IO.Path]::GetTempPath()) ("M24Backup.benchmark.{0}.tsv" -f [guid]::NewGuid().ToString('N'))
$folders = @([pscustomobject]@{ Name = 'Benchmark'; Path = $Path })

function Measure-Step {
    param([string]$Name, [scriptblock]$Action)
    [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers(); [System.GC]::Collect()
    $gen0 = [System.GC]::CollectionCount(0)
    $gen1 = [System.GC]::CollectionCount(1)
    $gen2 = [System.GC]::CollectionCount(2)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = & $Action
    $stopwatch.Stop()
    return [pscustomobject]@{
        Name         = $Name
        Milliseconds = $stopwatch.ElapsedMilliseconds
        Gen0         = [System.GC]::CollectionCount(0) - $gen0
        Gen1         = [System.GC]::CollectionCount(1) - $gen1
        Gen2         = [System.GC]::CollectionCount(2) - $gen2
        Result       = $result
    }
}

function Get-Median {
    param([object[]]$Values)
    $sorted = @($Values) | Sort-Object
    return $sorted[[int]([math]::Floor($sorted.Count / 2))]
}

function Show-Summary {
    param([string]$Name, [object[]]$Measurements)
    $times = @($Measurements | ForEach-Object { $_.Milliseconds })
    $median = Get-Median -Values $times
    $spread = (@($times) | Sort-Object)[-1] - (@($times) | Sort-Object)[0]
    # Auch die GC-Zaehler als Median, damit Zeit und Allokationsverhalten
    # denselben Lauf beschreiben und nicht Median gegen Einzelwert steht.
    $gen0 = Get-Median -Values @($Measurements | ForEach-Object { $_.Gen0 })
    $gen1 = Get-Median -Values @($Measurements | ForEach-Object { $_.Gen1 })
    $gen2 = Get-Median -Values @($Measurements | ForEach-Object { $_.Gen2 })
    Write-Host ("{0,-14} Median {1,8:N0} ms  Spannweite {2,7:N0} ms  Median Gen0={3,5} Gen1={4,5} Gen2={5,5}" -f $Name, $median, $spread, $gen0, $gen1, $gen2)
    return [pscustomobject]@{ Name = $Name; MedianMilliseconds = $median; SpreadMilliseconds = $spread; MedianGen2 = $gen2 }
}

try {
    $environment = "{0} auf .NET {1}, {2} logische Prozessoren" -f $PSVersionTable.PSVersion, [System.Environment]::Version, [System.Environment]::ProcessorCount
    Write-Host "Umgebung : $environment"
    Write-Host "Skript   : $SharedScript"
    Write-Host "Testbaum : $Path"
    Write-Host ""

    $firstRuns = @(); $secondRuns = @(); $verifyRuns = @()
    for ($run = 1; $run -le $Runs; $run++) {
        Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
        $firstRuns += Measure-Step -Name 'Erstlauf' -Action {
            Update-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles @()
        }

        if ($ChangedPercent -gt 0) {
            $files = @([System.IO.Directory]::GetFiles($Path, '*', [System.IO.SearchOption]::AllDirectories))
            $changeCount = [int][math]::Ceiling($files.Count * $ChangedPercent / 100)
            for ($index = 0; $index -lt $changeCount; $index++) {
                $target = $files[$index]
                $stream = [System.IO.File]::Open($target, 'Append', 'Write')
                try { $stream.WriteByte([byte]$run) } finally { $stream.Dispose() }
            }
        }

        $secondRuns += Measure-Step -Name 'Folgelauf' -Action {
            Update-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles @()
        }
        $verifyRuns += Measure-Step -Name 'Verifikation' -Action {
            Test-M24ChecksumManifest -Folders $folders -ManifestPath $manifestPath -ExcludedFiles @()
        }
    }

    $summary = @(
        Show-Summary -Name 'Erstlauf' -Measurements $firstRuns
        Show-Summary -Name ("Folgelauf {0}%" -f $ChangedPercent) -Measurements $secondRuns
        Show-Summary -Name 'Verifikation' -Measurements $verifyRuns
    )

    Write-Host ""
    $detail = $firstRuns[-1].Result
    Write-Host ("Erstlauf im Detail: {0:N0} Dateien, {1:N0} gehasht, {2:N0} wiederverwendet" -f $detail.Files, $detail.HashedFiles, $detail.ReusedFiles)
    # Aeltere Fassungen ohne Instrumentierung liefern diese Felder nicht.
    if ($null -ne $detail.TotalMilliseconds) {
        Write-Host ("  Verzeichnisaufzaehlung {0:N0} ms | Hashen {1:N0} ms fuer {2:N0} MiB ({3:N1} MiB/s)" -f `
                $detail.EnumerationMilliseconds, $detail.HashMilliseconds, ($detail.HashedBytes / 1MB), $detail.AverageHashMegabytesPerSecond)
        Write-Host ("  Manifest lesen {0:N0} ms, schreiben {1:N0} ms | sonstiger Aufwand {2:N0} ms" -f `
                $detail.ManifestReadMilliseconds, $detail.ManifestWriteMilliseconds, $detail.OverheadMilliseconds)
    } else {
        Write-Host "  (Die gemessene Fassung liefert keine getrennten Laufzeiten.)"
    }

    $verification = $verifyRuns[-1].Result
    if ([int]$verification.ErrorCount -ne 0) {
        Write-Warning ("Die Verifikation meldete {0} Fehler. Die Messung ist damit nicht aussagekraeftig." -f $verification.ErrorCount)
    }

    return $summary
} finally {
    Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
}
