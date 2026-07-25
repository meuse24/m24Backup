# Benchmarks der Prüfsummenverarbeitung

Diese Skripte belegen die Zahlen aus `checksum-optimization-plan.md`. Ohne sie
wären die dort genannten Faktoren später nicht nachvollziehbar.

## Verwendung

```powershell
# Testbaum erzeugen (Small, Medium, Large oder WideFolder)
.\New-M24BenchmarkTree.ps1 -Scenario Small -Path D:\bench\small

# Aktuelle Fassung messen
.\Measure-M24Checksums.ps1 -Path D:\bench\small -Runs 5

# Gegen eine ältere Fassung vergleichen
git show HEAD:M24Backup.Shared.ps1 > alt.ps1
.\Measure-M24Checksums.ps1 -Path D:\bench\small -Runs 5 -SharedScript .\alt.ps1
```

Gemessen werden drei Läufe: Erstlauf, Folgelauf mit Wiederverwendung und
vollständige Verifikation. Neben den Zeiten werden die Sammlungen der
Generationen 0, 1 und 2 ausgewiesen — ohne diese Zähler bleibt die
Allokationswirkung unsichtbar, die bei kleinen Dateien der wichtigste
Kostenfaktor ist.

Mit `-ChangedPercent 1` wird ein realistischer Folgelauf gemessen, bei dem ein
Teil der Dateien verändert wurde.

## Messumgebung der dokumentierten Rohwerte

- Intel Xeon E-2176M, 6 Kerne / 12 logische Prozessoren, lokale SSD
- Windows PowerShell 5.1.26100 auf .NET Framework 4.8
- warmer Dateisystemcache, Echtzeit-Virenschutz aktiv
- Szenario `Small`: 20.000 Dateien zu 1–32 KiB, 322,6 MiB, 40 Ordner, plus die
  Markerdatei `.m24-checksum-benchmark` (daher 20.001 verarbeitete Dateien)
- Median und Spannweite aus je fünf Läufen

## Rohwerte: Wirkung der Umstellung

Verglichen wurde Commit `3b27438` (Stand vor der Optimierung) gegen die
aktuelle Fassung, beide über denselben Testbaum.

| Lauf | vorher | nachher | Faktor |
| --- | --- | --- | --- |
| Erstlauf | 37.914 ms (Spannweite 15.109) | 12.116 ms (Spannweite 1.440) | 3,1 |
| Folgelauf, 0 % geändert | 5.483 ms (Spannweite 70) | 5.083 ms (Spannweite 109) | 1,1 |
| Verifikation | 49.178 ms (Spannweite 3.566) | 13.483 ms (Spannweite 124) | 3,6 |

Median der Sammlungen der Generation 2:

| Lauf | vorher | nachher |
| --- | --- | --- |
| Erstlauf | 1.061 | 0 |
| Folgelauf | 1 | 1 |
| Verifikation | 889 | 1 |

Die deutlich kleinere Spannweite der neuen Fassung ist kein Zufall: Die alte
Implementierung legte je Datei einen 1-MiB-Puffer im Large Object Heap an, und
die daraus folgenden Gen-2-Sammlungen streuten die Laufzeit stark.

Aufschlüsselung des Erstlaufs in der neuen Fassung:

```
Verzeichnisaufzählung 16 ms | Hashen 7.984 ms für 323 MiB (40,4 MiB/s)
Manifest lesen 0 ms, schreiben 59 ms | sonstiger Aufwand 4.027 ms
```

`Verzeichnisaufzählung` misst ausschließlich das Durchlaufen der
Verzeichnisstruktur — bei 40 Ordnern entsprechend wenig. Der `sonstige Aufwand`
enthält die Dateiaufzählung innerhalb der Verzeichnisse, Metadatenvergleich,
Ausschlussfilter, die Konsistenzprüfung nach dem Hashen und die Manifestpflege.

Der Folgelauf profitiert erwartungsgemäß kaum, weil dort keine Prüfsummen
berechnet werden und Manifest-Ein-/Ausgabe sowie Aufzählung dominieren.

### Preis der Konsistenzprüfung

Nach dem Hashen werden Größe und Zeitstempel erneut gelesen, damit ein
Manifesteintrag nie aus nicht zusammengehörigem Hash und Metadaten besteht. Der
zusätzliche Metadatenzugriff kostet rund 800 ms auf 20.000 Dateien.

Eine erste Fassung kapselte diese Prüfung in einer eigenen Funktion je Datei und
kostete 4.500 ms statt 800 ms — der PowerShell-Funktionsaufruf samt Rückgabe
eines `[pscustomobject]` war fünfmal teurer als der Dateisystemzugriff, den er
umschloss. Die Prüfung ist deshalb bewusst in die Schleife eingebettet.

## Grenzen dieser Messungen

Die Werte gelten für einen schnellen lokalen Datenträger mit warmem Cache. Sie
belegen **nicht** das Verhalten auf USB-, Netzwerk- und HDD-Zielen, bei kaltem
Cache oder den Nutzen einer Parallelisierung bei echtem Datei-I/O. Für diese
Fragen sind Messungen auf realer Zielhardware nötig.

Beim Vergleich zweier Fassungen ist auf gleiche Bedingungen zu achten: gleiche
Einstellung des Echtzeit-Virenschutzes, gleicher Cache-Zustand und derselbe
Testbaum. Beim Öffnen sehr vieler kleiner Dateien dominiert der Virenschutz die
Zugriffszeit häufig deutlicher als jede hier gemessene Änderung.
