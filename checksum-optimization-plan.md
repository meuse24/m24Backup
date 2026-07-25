# Optimierungsplan für die Prüfsummenberechnung

## Ziel

Die SHA-256-Prüfsummen sollen ohne GPU-Unterstützung schneller erstellt und
geprüft werden. Integrität, Abbruchfähigkeit, Kompatibilität vorhandener
Manifeste und das sichere Verhalten bei Dateisystemfehlern dürfen sich dabei
nicht verschlechtern.

Dieser Plan basiert auf der aktuellen Implementierung in
`M24Backup.Shared.ps1`, den Aufrufen im Worker
`Bibliothekssicherung.ps1` und der manuellen Prüfung in
`Bibliothekssicherung-GUI.ps1`.

Alle Aussagen zur Wirksamkeit einzelner Maßnahmen sind gemessen, nicht
geschätzt. Die Messgrundlage steht im Abschnitt „Messgrundlage“. Wo eine
Messung eine Aussage nur teilweise trägt, ist das ausdrücklich vermerkt.

## Umsetzungsstand

| Phase | Stand |
| --- | --- |
| 1 Messbarkeit | umgesetzt; Benchmarkskripte unter `tests/benchmarks/` |
| 2 Puffer und Aufzählung | umgesetzt |
| 3 Validierung wiederverwendeter Manifestwerte | umgesetzt |
| 4 Fortschrittsanzeige | umgesetzt |
| 5 Parallelisierung | **zurückgestellt**, wie geplant nicht umgesetzt |
| 6 Inkrementelle Verfeinerung | umgesetzt: `ReusedBytes` und Konsistenzprüfung zwischen Metadaten und Hash |

Gemessenes Ergebnis über 20.000 kleine Dateien (322,6 MiB), Median aus fünf
Läufen unter Windows PowerShell 5.1:

| Lauf | vorher | nachher | Faktor |
| --- | --- | --- | --- |
| Erstlauf | 37.914 ms | 12.116 ms | 3,1 |
| Folgelauf ohne Änderungen | 5.483 ms | 5.083 ms | 1,1 |
| Verifikation | 49.178 ms | 13.483 ms | 3,6 |

Sammlungen der Generation 2 beim Erstlauf: 1.061 vorher, 0 nachher.

Drei Erkenntnisse aus der Umsetzung, die in den Messungen dieses Plans noch
nicht enthalten waren:

- PowerShell entrollt ein Array, das als Rückgabewert einer Funktion oder als
  Wert eines `if`-Ausdrucks zurückkommt. Der Aufrufer erhält dann ein
  `object[]` mit einzeln geboxten Bytes. Beide Fälle traten beim Durchreichen
  des Puffers auf und verlangsamten das Hashen um Größenordnungen, ohne ein
  falsches Ergebnis zu erzeugen. Ein Test sichert das jetzt ab.
- Ein Abbruch während der Verzeichnisaufzählung muss explizit gemeldet werden.
  Eine bloß unvollständige Ergebnisliste hätte der Aufrufer für einen
  vollständigen Scan gehalten und ein verkürztes Manifest geschrieben.
- Ein PowerShell-Funktionsaufruf je Datei ist teurer als ein
  Dateisystemzugriff. Die Konsistenzprüfung nach dem Hashen kostete als
  ausgelagerte Funktion 4.500 ms, in die Schleife eingebettet 800 ms. Prüfungen
  auf Dateiebene gehören deshalb in die Schleife, nicht in eine Hilfsfunktion.

Die ursprünglich als Phase 6 offen gelassene Wettlaufsituation ist geschlossen:
Nach dem Hashen werden Größe und Zeitstempel erneut gelesen. Weichen sie ab,
wird die Datei ein zweites Mal gehasht; bleibt sie instabil, bricht der Lauf mit
einer verständlichen Meldung ab, statt einen Manifesteintrag aus nicht
zusammengehörigem Hash und Metadaten zu schreiben.

## Ist-Zustand

### Hashing

`Get-M24FileSha256` (`M24Backup.Shared.ps1:840`):

- öffnet jede Datei einzeln mit `FileShare.ReadWrite`
- erzeugt pro Datei eine neue SHA-256-Instanz
- **reserviert pro Datei einen neuen Puffer von 1 MiB**
- liest synchron in 1-MiB-Blöcken
- verwendet `TransformBlock` mit dem Eingabepuffer als Ausgabepuffer
- prüft den Abbruch nach jedem gelesenen Block

Die hervorgehobene Zeile ist der mit Abstand teuerste Einzelposten der
gesamten Prüfsummenverarbeitung. Ein 1-MiB-Array liegt oberhalb der Grenze von
85 KiB und wird daher im Large Object Heap angelegt. Dieser wird nicht
kompaktiert und löst Sammlungen der Generation 2 aus.

### Manifest-Aktualisierung nach einer Sicherung

`Update-M24ChecksumManifest` (`M24Backup.Shared.ps1:910`):

- liest das bestehende Manifest
- durchläuft den gesamten additiven Backup-Bestand
- verwendet eine vorhandene Prüfsumme erneut, wenn Dateigröße und
  `LastWriteTimeUtc.Ticks` exakt übereinstimmen
- hasht nur neue oder anhand dieser Metadaten geänderte Dateien
- schreibt das Manifest erst nach einem vollständigen erfolgreichen Scan

Diese Wiederverwendung ist bereits die wichtigste Optimierung für regelmäßige
Sicherungsläufe und muss erhalten bleiben.

### Vollständige Integritätsprüfung

`Test-M24ChecksumManifest` (`M24Backup.Shared.ps1:970`):

- enumeriert alle gesicherten Dateien
- liest und hasht jede Datei vollständig
- erkennt zusätzliche, fehlende und inhaltlich veränderte Dateien

Hier ist keine Wiederverwendung alter Hashes zulässig: Eine echte
Integritätsprüfung muss jedes Byte des Backup-Bestands erneut lesen.

## Messgrundlage

Alle Zahlen dieses Plans wurden auf folgender Umgebung erhoben:

- Intel Xeon E-2176M, 6 Kerne / 12 logische Prozessoren, lokale SSD
- Windows PowerShell 5.1.26100 auf .NET Framework 4.8
- **warmer Dateisystemcache**, Median-nahe Einzelläufe
- Testbaum: 20.000 Dateien zu 1–32 KiB, insgesamt 320,6 MiB, 40 Ordner
- Einzeldatei: 512 MiB

### Reichweite dieser Messungen

Die Werte belegen Größenordnungen und Rangfolgen für CPU- und
Laufzeitverhalten auf einem schnellen lokalen Datenträger mit warmem Cache.
Sie belegen **nicht**:

- das Verhalten auf USB-, Netzwerk- und HDD-Zielen
- das Verhalten bei kaltem Cache
- den Einfluss des Echtzeit-Virenschutzes
- den End-to-End-Nutzen von Parallelisierung bei echtem Datei-I/O

Für diese Fragen sind Messungen auf realer Zielhardware erforderlich. Sie sind
Liefergegenstand von Phase 1.

### Reproduzierbarkeit

Die Benchmarkskripte, mit denen die folgenden Tabellen entstanden sind, werden
unter `tests/benchmarks/` im Repository abgelegt, zusammen mit den Rohwerten
und der genauen Variantenbeschreibung. Ohne Skript und Rohdaten sind die
Ergebnisse später nicht nachvollziehbar, und der Plan verlöre seine Grundlage.

### Verfügbarkeit der geplanten APIs unter Windows PowerShell 5.1

| API | Verfügbar | Bemerkung |
| --- | --- | --- |
| `IncrementalHash` | ja | ab .NET Framework 4.6.1 |
| `System.Buffers.ArrayPool<byte>` | **nein** | nicht Teil des .NET Framework |
| `SHA256Cng` | ja | unter PowerShell 7 dagegen nicht vorhanden |
| `SHA256.Create()` | ja | liefert unter 5.1 `SHA256Managed` |

Ein Plan, der `ArrayPool` als Hauptweg vorsieht, ist auf der Ziellaufzeit nicht
umsetzbar.

### Durchsatz des SHA-256-Kerns (512 MiB, reine CPU, kein Datei-I/O)

| Variante | Dauer | Durchsatz |
| --- | --- | --- |
| `SHA256Managed`, `TransformBlock` mit Ausgabepuffer (Ist) | 1.806 ms | 283 MiB/s |
| `SHA256Managed`, `TransformBlock` ohne Ausgabepuffer | 1.788 ms | 286 MiB/s |
| `SHA256Cng` | 1.806 ms | 283 MiB/s |
| `IncrementalHash.AppendData` | 1.816 ms | 282 MiB/s |
| `SHA256CryptoServiceProvider` | 1.807 ms | 283 MiB/s |

**Alle SHA-256-Implementierungen sind gleich schnell.** Unter PowerShell 7.6
ergibt sich derselbe Wert. Der Kern ist rechenbegrenzt bei rund 283 MiB/s pro
Kern; die Wahl der Programmierschnittstelle ändert daran nichts.

### Blockgröße und `SequentialScan` (512 MiB, eine Datei)

Alle acht geprüften Kombinationen aus 256 KiB, 1 MiB, 4 MiB und 8 MiB mit und
ohne `FileOptions.SequentialScan` liegen zwischen 262 und 268 MiB/s. Die
Streuung entspricht dem Messrauschen. Bei großen Dateien auf lokaler SSD ist
die Verarbeitung vollständig durch den Hash-Kern begrenzt.

### Isolierte Wirkung der Pufferallokation (20.000 Dateien, 320,6 MiB)

Diese Messung variiert **ausschließlich den Pufferlebenszyklus**. Lesepfad,
Hash-Instanzierung und `TransformBlock`-Aufruf ohne Ausgabepuffer sind in
beiden Varianten identisch:

| Variante | Dauer | Gen-0 | Gen-1 | Gen-2 |
| --- | --- | --- | --- | --- |
| neuer 1-MiB-Puffer je Datei | 27.056 ms | 2.558 | 2.558 | **2.558** |
| ein gemeinsamer Puffer für den ganzen Lauf | 5.512 ms | 51 | 1 | **0** |

Damit ist die Ursache eindeutig belegt: Faktor 4,9 bei sonst gleichem Code, und
2.558 Sammlungen der Generation 2 gegen null. Jede Gen-2-Sammlung durchsucht
den gesamten verwalteten Heap. Der Vergleich zur Ist-Implementierung mit
Ausgabepuffer (26.928 ms) zeigt zugleich, dass der Ausgabepuffer selbst
wirkungslos ist.

Die Hashwerte beider Varianten wurden über 200 Dateien auf Gleichheit geprüft.

### Schneller Pfad für kleine Dateien (20.000 Dateien, 320,6 MiB)

| Variante | Dauer |
| --- | --- |
| gemeinsamer Puffer, `TransformBlock`-Schleife | 5.512 ms |
| gemeinsamer Puffer, Lesen bis Dateiende, dann `ComputeHash(buf, 0, n)` | 5.580 ms |

Ein gesonderter Pfad für kleine Dateien bringt **keinen Vorteil**, sobald er
korrekt implementiert ist, also mit einer Leseschleife statt eines einzelnen
`Read()`-Aufrufs und ohne `ReadAllBytes`. Der in einer früheren Fassung
genannte Gewinn von 8 % stammte ausschließlich aus `ReadAllBytes`, das je
Datei erneut alloziert und damit die eben beseitigte Ursache zurückbringt.

### Dateiaufzählung (20.000 Dateien, mit Größe und UTC-Zeitstempel)

| Variante | Dauer |
| --- | --- |
| `Get-ChildItem -File -Recurse -Force` mit `ForEach-Object` (Ist) | 1.242 ms |
| `Directory.GetFiles` + `New-Object System.IO.FileInfo` | 3.076 ms |
| `Directory.EnumerateFiles` + `New-Object System.IO.FileInfo` | 3.128 ms |
| `DirectoryInfo`-Stapel mit `.GetFiles()` | 102 ms |
| `DirectoryInfo`-Stapel mit `.EnumerateFiles()` | 77 ms |
| **wie oben, zusätzlich mit Ausschlussfilter, Reparse-Point-Prüfung und relativem Pfad** | **245 ms** |

Zwei Punkte sind hier entscheidend:

Der naheliegende Weg über `Directory.GetFiles` mit anschließendem
`New-Object System.IO.FileInfo` ist **zweieinhalbmal langsamer als der
Ist-Zustand**. Nur der `DirectoryInfo`-Weg ist schnell, weil er
`FileInfo`-Objekte mit bereits gefüllten Metadaten aus einem einzigen
Verzeichnisdurchlauf liefert und den teuren `New-Object`-Pfad von PowerShell
vermeidet.

Die maßgebliche Zahl ist **245 ms, nicht 77 ms**. Erst diese Variante leistet,
was die Produktivfunktion leisten muss: Ausschlussmuster prüfen, Reparse Points
erkennen, den relativen Manifestpfad bilden sowie Länge und
`LastWriteTimeUtc` jeder Datei lesen. Der realistische Gewinn gegenüber dem
Ist-Zustand beträgt damit Faktor 5,1, nicht 8,9.

`EnumerateFiles()` wird `GetFiles()` vorgezogen. Es ist in der Messung sogar
etwas schneller und gibt kein vollständiges Array zurück. Bei einem einzelnen
Verzeichnis mit sehr vielen Dateien vermeidet das eine große Sammelallokation —
genau die Klasse von Problem, die dieser Plan an anderer Stelle beseitigt.

Das ist zugleich entscheidend für Phase 2: Die vorhandene Funktion
`Get-M24DirectoryEntries` (`M24Backup.Shared.ps1:818`) verwendet genau das
langsame Muster aus `GetFileSystemEntries`, `ForEach-Object`,
`New-Object FileInfo` und `[pscustomobject]` pro Eintrag. Sie taugt als Vorbild
für Korrektheit bei erweiterten Pfaden, **nicht** als Vorbild für Durchsatz.

### Parallele Skalierung — nur CPU, ohne Datei-I/O

| Worker | Durchsatz gesamt |
| --- | --- |
| 1 | 283 MiB/s |
| 2 | 566 MiB/s |
| 4 | 802 MiB/s |
| 8 | 1.290 MiB/s |

**Diese Messung hasht einen Puffer im Arbeitsspeicher und öffnet keine
einzige Datei.** Sie belegt ausschließlich, dass der SHA-256-Kern rechnerisch
bis zwei Worker linear skaliert. Sie belegt **nicht**, dass paralleles
Datei-Hashing ähnlich skaliert: Bei warmem Cache liefert Windows die Daten aus
dem Arbeitsspeicher, was weder einer USB-HDD noch zwingend einer realen
SSD-Prüfung entspricht. Der End-to-End-Nutzen auf echten Backup-Datenträgern
ist offen.

## Bewertete Optimierungspotenziale

### 1. Pufferallokation je Datei (größter Einzelposten)

Isoliert belegt mit Faktor 4,9 und 2.558 vermiedenen Gen-2-Sammlungen bei
kleinen Dateien. Umsetzung ist einfach und ohne Risiko für die Hashwerte.
Höchste Priorität.

### 2. Dateiaufzählung über `DirectoryInfo.EnumerateFiles()`

Belegt mit Faktor 5,1 gegenüber dem Ist-Zustand bei kleinen Dateien,
einschließlich aller fachlich notwendigen Prüfungen. Der Aufwand liegt nicht in
der Geschwindigkeit, sondern darin, das bestehende Sicherheitsverhalten exakt
zu erhalten. Hohe Priorität, aber sorgfältig.

### 3. Validierung wiederverwendeter Manifestwerte

Ein beschädigter Hash-Eintrag im Manifest wird derzeit bei jedem Folgelauf
unverändert übernommen und dadurch dauerhaft konserviert. Die Prüfung auf
gültiges SHA-256-Hexformat kostet nichts und gehört zeitlich nach vorn, nicht
in eine späte Phase.

### 4. Parallelisierung bei schnellen Zielen — offen

Rechnerisch wirksam nur dann, wenn das Ziel mehr als etwa 283 MiB/s liefert.
Ob das in der Praxis eintritt, ist mangels End-to-End-Messung unbekannt.
Bleibt zurückgestellt.

### 5. Nicht wirksam: Wahl der Hash-Schnittstelle

`IncrementalHash`, `SHA256Cng` und `SHA256CryptoServiceProvider` sind
gemessen gleich schnell wie der Ist-Zustand. Auch das Weglassen des
Ausgabepuffers in `TransformBlock` bringt nichts Messbares. Die ursprüngliche
Annahme, `TransformBlock` verursache über die `ICryptoTransform`-Schnittstelle
relevanten Kopieraufwand, ist widerlegt.

### 6. Nicht wirksam: Blockgröße, `SequentialScan`, Sonderpfad für kleine Dateien

Kein messbarer Effekt auf lokaler SSD. Ein Restnutzen von `SequentialScan` bei
langsamen USB-Zielen ist denkbar, aber unbelegt und rechtfertigt keine
Benchmark-Matrix.

### 7. Fehlende getrennte Laufzeitmessung

Der Code protokolliert Datei- und Wiederverwendungszahlen, trennt aber nicht
Aufzählung, Metadatenvergleich, gehashte Bytes, reine Hashdauer sowie
Manifestlesen und -schreiben. Ohne diese Werte lässt sich im Feld nicht
unterscheiden, ob Datenträger, Aufzählung oder CPU die Laufzeit begrenzt.

### 8. Doppelte Datenträgerdurchläufe sind teilweise unvermeidbar

Neu kopierte Dateien werden nach Robocopy noch einmal am Ziel gelesen. Das ist
teuer, stellt aber sicher, dass die Prüfsumme tatsächlich den gespeicherten
Backup-Inhalt beschreibt. Ein Hash der Quelle vor oder während des Kopierens
wäre bei gleichzeitig veränderten Dateien kein gleichwertiger Nachweis.

Robocopy liefert selbst keine kryptografische Zielprüfung. Diese zweite
Leseoperation darf daher nicht ohne eine eigene, atomare Kopierimplementierung
entfernt werden.

### 9. Manifestgröße bei sehr großen Beständen

`Read-M24ChecksumManifest` erzeugt je Zeile ein `[pscustomobject]` und
dekodiert einen Base64-Pfad; `Write-M24ChecksumManifest` kodiert wieder. Bei
einigen hunderttausend Einträgen wird das relevant, sowohl für Laufzeit als
auch für Arbeitsspeicher. Ferner wachsen Manifeste im additiven Betrieb
monoton, weil gelöschte Zieldateien keinen Eintrag entfernen. Dieser Posten ist
erst zu bewerten, wenn Phase 1 ihn tatsächlich als relevant ausweist.

## Umsetzungsplan

Die Reihenfolge folgt dem gemessenen Nutzen je Aufwand, nicht der
thematischen Gliederung.

## Phase 1: Messbarkeit herstellen

### Änderungen

Die Ergebnisobjekte von `Update-M24ChecksumManifest` und
`Test-M24ChecksumManifest` werden ergänzt. Die bestehenden Felder `Files`,
`HashedFiles`, `ReusedFiles`, `Bytes`, `SkippedDeviceFiles`, `Cancelled`,
`ErrorCount` und `Errors` bleiben unverändert erhalten, damit Worker und GUI
nicht angepasst werden müssen. Neu hinzu kommen:

- `HashedBytes`
- `ReusedBytes`
- `EnumerationMilliseconds`
- `HashMilliseconds`
- `ManifestReadMilliseconds`
- `ManifestWriteMilliseconds`
- `TotalMilliseconds`
- `AverageHashMegabytesPerSecond`

`EnumeratedFiles` und `EnumeratedBytes` entfallen bewusst: `Files` und `Bytes`
decken das bereits ab, und zwei ähnlich benannte Felder mit leicht anderer
Bedeutung laden zu Fehlinterpretationen im Protokoll ein.

`AverageHashMegabytesPerSecond` ist ausdrücklich ein **Diagnosewert für
Protokolle**, keine Steuergröße. Siehe dazu die Begründung in Phase 4.

Die Zeitmessung erfolgt über wenige langlebige `Stopwatch`-Instanzen, die je
Datei nur gestartet und gestoppt werden. Ein `New-Object` je Datei ist zu
vermeiden, weil genau dieses Muster laut Messung selbst zum Kostenfaktor wird.

Worker- und Prüfprotokoll schreiben diese Werte in lesbarer Form. Die GUI muss
nicht mit technischen Details überladen werden; dort genügt weiterhin die
Gesamtdauer und Dateimenge.

### Benchmarkskripte ins Repository

Unter `tests/benchmarks/` entstehen ein Erzeugungsskript für die Testbäume, ein
Messskript je Szenario und eine Datei mit den Rohwerten samt Umgebungsangaben.
Jede in diesem Plan genannte Zahl muss darüber reproduzierbar sein. Die
Messskripte geben zusätzlich zu den Zeiten die Zähler aus
`[GC]::CollectionCount(0|1|2)` aus, weil die Allokationswirkung sonst nicht
sichtbar wird.

### Benchmark-Szenarien

1. 20.000 kleine Dateien zwischen 1 und 32 KiB
2. 1.000 mittlere Dateien von ungefähr 1 MiB
3. 8 große Dateien von jeweils mindestens 256 MiB
4. ein einzelnes Verzeichnis mit sehr vielen Dateien, mindestens 100.000, zur
   Prüfung des Speicherverhaltens der Aufzählung
5. ein unveränderter Folgelauf mit vollständiger Manifest-Wiederverwendung
6. ein Folgelauf mit 1 % geänderten Dateien
7. eine vollständige Verifikation

Die Szenarien sollen auf lokaler SSD und einem typischen USB-Ziel gemessen
werden, jeweils mit kaltem und warmem Dateisystemcache. Zeiten aus CI oder
virtuellen Testlaufwerken sind nur für Regressionen, nicht für
Produktentscheidungen geeignet.

Der Echtzeit-Virenschutz ist als Störgröße zu behandeln. Beim Öffnen sehr
vieler kleiner Dateien dominiert er die Zugriffszeit häufig deutlicher als
jede hier geplante Änderung. Jedes Szenario ist daher einmal mit aktivem
Schutz und einmal mit einem Ausschluss für den Testbaum zu messen, und beide
Werte sind getrennt auszuweisen. Verglichen werden nur Läufe mit gleicher
Schutzeinstellung.

### Abnahmekriterium

Spätere Optimierungen werden nur übernommen, wenn sie in mindestens einem
realistischen Szenario messbar helfen und kein wichtiges Szenario
verschlechtern. Als „messbar“ gilt eine Abweichung, die größer ist als die
beobachtete Streuung: Es werden fünf Läufe je Szenario gemessen, ausgewertet
werden Median und Spannweite. Änderungen unterhalb der Spannweite gelten als
wirkungslos, nicht als Verbesserung.

## Phase 2: Puffer und Aufzählung — der belegte Hauptgewinn

Diese Phase enthält die beiden einzigen Maßnahmen mit belegter Wirkung im
sequenziellen Betrieb. Sie werden gemeinsam umgesetzt, weil sie sich denselben
Aufzählungspfad teilen.

### 2.1 Puffer wiederverwenden (höchste Priorität)

`Get-M24FileSha256` erhält einen optionalen Parameter für einen von außen
bereitgestellten Puffer. `Update-M24ChecksumManifest` und
`Test-M24ChecksumManifest` legen je Lauf genau einen 1-MiB-Puffer an und
reichen ihn durch. Ohne übergebenen Puffer legt die Funktion wie bisher selbst
einen an, damit vorhandene Aufrufer und Tests unverändert funktionieren.

`ArrayPool` wird nicht verwendet. Der Typ existiert unter Windows
PowerShell 5.1 nicht, und ein einzelner langlebiger Puffer je Lauf erreicht
denselben Effekt ohne Abhängigkeit.

Ein Löschen des Puffers zwischen Dateien ist nicht erforderlich: Er wird
ausschließlich prozessintern verwendet und niemals persistiert. Bei
Parallelisierung erhält jeder Worker einen eigenen Puffer; ein geteilter Puffer
wäre ein Korrektheitsfehler.

Belegter Gewinn: Faktor 4,9 bei kleinen und mittleren Dateien, kein Effekt bei
sehr großen Dateien.

### 2.2 Verbindliche Regeln für den Lesepfad

Diese Regeln gelten für jede Änderung am Hash-Kern:

- Die Leseschleife bleibt eine Schleife. `FileStream.Read()` darf jederzeit
  weniger Bytes liefern als angefordert, auch bei lokalen Dateien und auch
  wenn die Datei kleiner als der Puffer ist. Ein einzelner `Read()`-Aufruf
  darf niemals als vollständig vorausgesetzt werden.
- Gehasht werden ausschließlich die tatsächlich gelesenen Bytes, also
  `TransformBlock(buffer, 0, read, ...)` mit dem Rückgabewert, nie mit
  `buffer.Length`. Andernfalls fließen Reste der vorherigen Datei in den Hash
  ein — das zentrale Risiko der Pufferwiederverwendung.
- `ReadAllBytes` wird nicht verwendet. Es alloziert je Datei erneut und macht
  den Gewinn aus 2.1 teilweise zunichte.
- Ein Sonderpfad für kleine Dateien wird nicht eingeführt. Er ist gemessen
  nicht schneller (5.580 ms gegen 5.512 ms) und vergrößert nur die Zahl der
  Codepfade, die korrekt sein müssen.
- Das Dateiende ist erreicht, wenn `Read()` null zurückgibt, nicht wenn eine
  erwartete Länge erreicht ist.

### 2.3 Aufzählung auf `DirectoryInfo.EnumerateFiles()` umstellen

Eine gemeinsame interne Aufzählungsfunktion für Aktualisierung und Prüfung
arbeitet iterativ über einen Stapel von `DirectoryInfo`-Objekten und gibt die
`FileInfo`-Objekte direkt weiter. Verboten sind in diesem Pfad:

- `New-Object System.IO.FileInfo` je Datei
- `[pscustomobject]` je Datei
- `ForEach-Object` in der inneren Schleife
- ein zweiter Dateisystemzugriff für Größe oder Zeitstempel

Diese vier Punkte sind der Unterschied zwischen Faktor 5,1 schneller und
Faktor 2,5 langsamer. `Get-M24DirectoryEntries` bleibt als eigenständige
Funktion für erweiterte Pfade unverändert bestehen und wird hier nicht
nachgebildet.

`EnumerateFiles()` und `EnumerateDirectories()` werden `GetFiles()` und
`GetDirectories()` vorgezogen: gleiche oder bessere Geschwindigkeit ohne
vollständige Array-Rückgabe. Szenario 4 aus Phase 1 prüft das Speicherverhalten
bei einem Verzeichnis mit sehr vielen Dateien ausdrücklich nach.

### Sicherheitsanforderungen der neuen Aufzählung

Die neue Aufzählung muss das bestehende Verhalten exakt bewahren:

- Junctions nicht verfolgen
- unterstützte Verzeichnis-Symlinks entsprechend der bestehenden
  Backup-Policy behandeln
- ausgeschlossene Dateien identisch filtern
- Aufzählungs- und Zugriffsfehler nicht verschlucken, sondern wie heute über
  eine Fehlerliste melden, die einen unvollständigen Scan verhindert
- Abbruch auch während großer Verzeichnisbäume prüfen
- reservierte Gerätenamen weiterhin gesondert behandeln
- keine internen Ordner oder Manifestdateien aufnehmen

`DirectoryInfo.EnumerateFiles()` wirft bei einem unzugänglichen Verzeichnis
eine Ausnahme, während `Get-ChildItem -ErrorAction SilentlyContinue` den Fehler
in `$scanErrors` sammelt und weiterläuft. Jeder Verzeichnisschritt wird daher
einzeln abgesichert, der Fehler in dieselbe Liste eingetragen und die
Aufzählung fortgesetzt. Andernfalls würde ein einzelner geschützter Unterordner
den gesamten Lauf abbrechen statt ihn als fehlerhaft zu markieren.

Bei einer verzögerten Aufzählung kann die Ausnahme auch erst während der
Iteration auftreten, nicht nur beim Aufruf. Die Absicherung muss die Schleife
umschließen, nicht nur den Aufzählungsstart.

### Kein Ausbau der Langpfad-Unterstützung in diesem Projekt

`Get-ChildItem` überspringt unter Windows PowerShell 5.1 ohne aktivierte
Langpfad-Unterstützung Pfade jenseits von 260 Zeichen. Eine Aufzählung mit
erweitertem Pfadpräfix würde solche Dateien erstmals erfassen.

Das ist inhaltlich eine Verbesserung, aber ein Verhaltenswechsel mit einer
konkreten Nebenwirkung: `Test-M24ChecksumManifest` (`M24Backup.Shared.ps1:1007`)
meldet für jede gefundene Datei ohne Manifesteintrag `Checksum entry missing`.
Eine Verifikation gegen ein älteres Manifest meldete dann Integritätsfehler,
obwohl sich am Backup nichts geändert hat.

Eine Staffelung über zwei aufeinanderfolgende Versionen löst das **nicht**
zuverlässig. Benutzer können Versionen überspringen und unmittelbar nach dem
Update „Backup prüfen“ wählen, ohne dass dazwischen je ein
`Update-M24ChecksumManifest`-Lauf stattgefunden hat.

Deshalb gilt für dieses Optimierungsprojekt:

- Die neue Aufzählung behält exakt dasselbe Pfadverhalten wie `Get-ChildItem`.
  Es werden keine zusätzlichen Dateien sichtbar.
- Der Ausbau der Langpfad-Unterstützung ist **kein Bestandteil dieses Plans**
  und wird als eigenes Vorhaben geführt.

Falls dieses Vorhaben später angegangen wird, sind mindestens erforderlich:

- eine neue Manifestversion im Header, deren Nummer die Aufzählungssemantik
  dokumentiert, statt des heutigen `M24BACKUP-CHECKSUMS<TAB>1<TAB>SHA256`
- eine Erkennung, dass ein Manifest der alten Semantik gegen die neue
  Aufzählung geprüft wird
- in diesem Fall ein verständlicher Abbruch mit der Meldung, dass das Manifest
  zuerst aktualisiert werden muss, statt einer Liste vermeintlicher
  Integritätsfehler
- eine kontrollierte, protokollierte Migration statt einer stillen Übernahme

### Rollout

Zuerst wird die neue Aufzählung hinter einem internen Schalter parallel zur
alten Implementierung getestet. Vertragstests vergleichen für denselben
Testbaum sortierte Pfade und Metadaten beider Varianten und müssen exakte
Gleichheit nachweisen. Erst danach ersetzt sie `Get-ChildItem`.

### Abnahmekriterien für Phase 2

- Hashwerte stimmen bytegenau mit der bisherigen Implementierung und
  `Get-FileHash -Algorithm SHA256` überein.
- Abbruch bleibt spätestens nach einem gelesenen Block wirksam.
- Dateien mit langen Pfaden und reservierten Gerätenamen behalten ihr
  bestehendes Verhalten.
- Die Menge der aufgezählten Dateien ist identisch zur alten Implementierung.
- Keine Puffer oder Streams bleiben nach Erfolg, Fehler oder Abbruch offen.

## Phase 3: Validierung wiederverwendeter Manifestwerte

Vor der Wiederverwendung wird geprüft, ob der gespeicherte Wert ein gültiger
SHA-256-Hexwert aus 64 Zeichen ist. Schlägt die Prüfung fehl, wird die Datei
neu gehasht statt den Eintrag zu übernehmen.

Diese Änderung ist klein, unabhängig von Phase 2 und schließt eine Lücke, durch
die ein beschädigter Eintrag heute unbegrenzt fortgeschrieben würde. Sie steht
deshalb bewusst vor den Komfortverbesserungen.

## Phase 4: Fortschrittsanzeige und Status

Die Oberfläche soll während längerer Prüfungen zusätzlich anzeigen:

- aktueller Ordner
- bereits geprüfte Dateien
- bereits gelesene Datenmenge
- optional aktueller Lesedurchsatz

Aktualisierungen werden zeitlich gedrosselt, höchstens vier pro Sekunde. Nach
Phase 2 verarbeitet der Lauf bis zu 3.600 kleine Dateien pro Sekunde; ein
Statusereignis je Datei würde den erreichten Gewinn direkt wieder aufzehren.

Die Abbruchfunktion bleibt sichtbar und muss sowohl bei Aufzählung als auch
beim Hashing zeitnah reagieren.

## Phase 5: Begrenzte Parallelisierung — zurückgestellt

### Stand der Erkenntnis

Belegt ist ausschließlich, dass der SHA-256-Kern **rechnerisch** bis zwei
Worker linear skaliert. Diese Messung fand vollständig im Arbeitsspeicher
statt. Der End-to-End-Nutzen auf realen Backup-Datenträgern ist nicht belegt.

Der Standard bleibt daher **ein Worker**. Parallelisierung wird nicht auf
Grundlage der bisherigen Messungen umgesetzt.

### Warum keine automatische Workerwahl über den Durchsatzwert

Eine Steuerung anhand von `AverageHashMegabytesPerSecond` wäre unzuverlässig.
Ein niedriger Wert entsteht ebenso durch viele kleine Dateien, den
Echtzeit-Virenschutz, Dateisystemlatenz oder CPU-Drosselung wie durch einen
langsamen Datenträger. Die Ursachen sind aus dem Wert nicht unterscheidbar, die
angemessene Reaktion aber gegensätzlich. Der Wert bleibt eine Diagnosegröße im
Protokoll.

### Voraussetzungen für eine spätere Freigabe

- getrennte End-to-End-Messungen mit echtem Datei-I/O, mit kaltem und warmem
  Cache, auf mindestens einer internen SSD, einem USB-Ziel und einer HDD
- Nachweis von mindestens 15 % Ersparnis der Gesamtdauer auf einem
  realistischen schnellen Ziel
- keine Verschlechterung auf HDD- und USB-Zielen
- Obergrenze höchstens die Hälfte der logischen Prozessoren und höchstens vier
  Worker
- Aktivierung ausschließlich über eine bewusste Einstellung, nicht über eine
  Heuristik

### Umsetzungsweg, falls freigegeben

`ForEach-Object -Parallel` steht unter Windows PowerShell 5.1 nicht zur
Verfügung. Möglich sind ein Runspace-Pool oder eine kleine, über `Add-Type`
kompilierte Hilfsklasse. Die zweite Variante ist einfacher korrekt zu bekommen,
kostet aber einmalig Kompilierzeit beim Start und muss unter beiden
Ziellaufzeiten gleich übersetzen.

Jeder Worker besitzt eigenen Stream, Puffer und Hashzustand. Worker liefern nur
fertige Ergebnisobjekte an einen einzelnen Sammler; ausschließlich der Sammler
verändert das Manifest. Dadurch bleiben Dictionary-Zugriffe, Fehlerzählung und
finales atomisches Schreiben deterministisch.

Für Abbruch und Fehler gilt: ein gemeinsames Abbruchsignal stoppt das Einreihen
neuer Dateien, aktive Worker prüfen nach jedem Block, nach dem ersten echten
Lesefehler wird kein Manifest geschrieben, und alle Worker werden vor Rückkehr
vollständig beendet und entsorgt.

## Phase 6: Inkrementelle Aktualisierung verfeinern

### Bereits korrekt

Die Kombination aus exakter Größe und exakten UTC-Ticks ist bewusst streng.
Eine FAT-/exFAT-Zeittoleranz würde das Risiko erhöhen, gleich große Änderungen
zu übersehen, und soll nicht eingeführt werden.

### Ergänzungen

- Wiederverwendungsstatistik zusätzlich nach Bytes ausweisen. Eine hohe
  Dateizahl allein kann irreführend sein.
- Manifest-Einträge weiterhin erst nach vollständigem, fehlerfreiem Scan
  atomisch ersetzen.
- Bekannte Wettlaufsituation prüfen: Länge und Zeitstempel stammen heute aus
  der Aufzählung, der Hash aus einem späteren Öffnen der Datei. Ändert sich die
  Datei dazwischen, beschreibt der Manifesteintrag eine Kombination, die es nie
  gab, und der nächste Lauf hält sie für unverändert. Zu bewerten ist, ob
  Länge und Zeitstempel nach dem Hashen aus dem noch offenen Handle gelesen und
  bei Abweichung die Datei erneut verarbeitet wird. Das betrifft die
  Korrektheit, nicht die Geschwindigkeit, und ist unabhängig vom Rest dieses
  Plans zu entscheiden.

### Zurückgestellt

Eine Priorisierung des Scans auf die von Robocopy berührten Zielordner ist
gestrichen. Der vollständige Bestandsabgleich muss ohnehin laufen, und die
Aufzählung kostet nach Phase 2 nur noch rund 245 ms je 20.000 Dateien. Der
Nutzen steht in keinem Verhältnis zur zusätzlichen Zustandskomplexität.

Optimierungen an `Read-M24ChecksumManifest` und `Write-M24ChecksumManifest`
werden erst umgesetzt, wenn `ManifestReadMilliseconds` beziehungsweise
`ManifestWriteMilliseconds` aus Phase 1 einen relevanten Anteil ausweisen.

### Nicht empfohlen

Nur anhand von Robocopy-Ausgaben eine Liste geänderter Dateien zu bilden, ist
nicht robust genug:

- die Ausgabe kann lokalisiert sein
- `/NFL` unterdrückt derzeit Dateinamen
- offene oder während des Kopierens geänderte Dateien erfordern weiterhin
  einen Zielabgleich
- der additive Altbestand muss im Manifest erhalten und validiert bleiben

## Gestrichene Maßnahmen

Die folgenden Punkte waren in früheren Fassungen dieses Plans enthalten und
wurden nach den Messungen entfernt. Sie sind hier dokumentiert, damit sie nicht
erneut vorgeschlagen werden.

| Maßnahme | Grund |
| --- | --- |
| `IncrementalHash` statt `TransformBlock` | gemessen 0 % Unterschied |
| `SHA256Cng` oder `SHA256CryptoServiceProvider` | gemessen 0 % Unterschied |
| `ArrayPool<byte>` | unter Windows PowerShell 5.1 nicht vorhanden |
| `FileOptions.SequentialScan` | kein messbarer Effekt |
| Blockgrößen-Matrix 256 KiB bis 8 MiB | alle Varianten im Messrauschen |
| Hash-Instanz über Dateien hinweg wiederverwenden | rund 3 % bei zusätzlichem Risiko der Zustandsvermischung |
| Sonderpfad für kleine Dateien | korrekt implementiert nicht schneller (5.580 gegen 5.512 ms) |
| `ReadAllBytes` im Hashpfad | alloziert je Datei erneut und hebt den Hauptgewinn teilweise auf |
| Aufzählung über `Directory.GetFiles` + `New-Object FileInfo` | 2,5-mal langsamer als der Ist-Zustand |
| Langpfad-Unterstützung als Teil dieses Projekts | Migrationsproblem nicht durch Versionsstaffelung lösbar |
| Automatische Workerwahl über `AverageHashMegabytesPerSecond` | Wert vermischt nicht unterscheidbare Ursachen |
| Scan-Priorisierung nach Robocopy-Zielordnern | Aufzählung ist nach Phase 2 kein Kostenfaktor mehr |

## Testplan

### Korrektheit

- leere und nicht leere Dateien
- bekannte SHA-256-Testvektoren
- Dateien kleiner, gleich und größer als der Puffer, insbesondere exakt bei
  1 MiB minus eins, 1 MiB und 1 MiB plus eins
- Dateigrößen über 4 GiB, sofern die Testumgebung dies erlaubt
- lange Pfade
- Unicode-Namen
- reservierte Gerätenamen
- geänderte, zusätzliche und fehlende Dateien
- exakt gleiche Größe bei verändertem Inhalt
- unveränderte und geänderte UTC-Zeitstempel

### Puffer-Wiederverwendung

Diese Tests sind neu und sichern das Kernrisiko von Phase 2.1 ab:

- zwei aufeinanderfolgende Dateien unterschiedlicher Länge im selben Puffer
  ergeben beide den korrekten Hash
- eine kurze Datei nach einer langen Datei übernimmt keine Restbytes; der
  erwartete Hash stammt aus einer unabhängigen Quelle, nicht aus derselben
  Implementierung
- ein Fehler beim Hashen einer Datei beeinflusst den Hash der nächsten nicht
- ein Abbruch mitten in einer Datei beeinflusst den nächsten Lauf nicht
- ein Datenstrom, der pro `Read()`-Aufruf absichtlich weniger Bytes liefert als
  angefordert, ergibt denselben Hash wie ein normaler Dateizugriff

Der letzte Punkt prüft die Regel aus 2.2 direkt und ist über einen
Test-Stream mit gedrosselter Rückgabemenge umsetzbar.

### Fehler und Abbruch

- Abbruch vor der ersten Datei
- Abbruch mitten in einer großen Datei
- Abbruch zwischen zwei Dateien
- Lesefehler
- Aufzählungsfehler, insbesondere ein unzugänglicher Unterordner mitten im
  Baum, sowohl beim Aufzählungsstart als auch während der Iteration
- Datei verschwindet zwischen Aufzählung und Öffnen
- Datei ändert sich während des Hashings
- kein Manifestwrite nach Fehler oder Abbruch
- alle Streams, Hashobjekte, Puffer und Worker werden freigegeben

### Kompatibilität

- vorhandene Manifestversion 1 bleibt lesbar
- neue und alte Implementierung erzeugen dieselben Hashwerte
- neue und alte Aufzählung liefern dieselbe Dateimenge, einschließlich
  identischem Verhalten bei Pfaden jenseits von 260 Zeichen
- Manifestformat und Header bleiben unverändert
- bestehende Restore- und Verifikationsrichtlinien bleiben unverändert
- Windows PowerShell 5.1 und die unterstützte moderne PowerShell-Laufzeit
  werden getrennt geprüft

### Performance

- Median und Spannweite aus mindestens fünf Läufen
- erster Lauf und warmer Dateisystemcache getrennt ausweisen
- mit und ohne Virenschutz-Ausschluss getrennt ausweisen
- CPU-Zeit, Gesamtdauer, effektive MiB/s und Gen-0/1/2-Sammlungen protokollieren
- kleine, mittlere und große Dateien getrennt bewerten
- SSD und USB-Ziel getrennt bewerten
- Update mit 0 %, 1 % und 100 % neu zu hashenden Dateien messen

## Priorisierung

1. Messinstrumentierung, Benchmarkskripte im Repository, Messungen auf realer
   Zielhardware
2. Pufferwiederverwendung und Aufzählung über `DirectoryInfo.EnumerateFiles()`
3. Validierung wiederverwendeter Manifestwerte
4. gedrosselte Fortschrittsdaten
5. Parallelisierung nur nach End-to-End-Nachweis auf echten Datenträgern

## Bewusst ausgeschlossene Änderungen

- kein Wechsel weg von SHA-256, da vorhandene Manifeste und externe
  Nachprüfbarkeit erhalten bleiben sollen
- kein Überspringen von Bytes bei einer vollständigen Integritätsprüfung
- kein Vertrauen allein auf Zeitstempel während einer Verifikation
- keine ungeprüfte Parallelisierung auf HDDs oder USB-Laufwerken
- kein Hashen ausschließlich der Quelle als Ersatz für die Prüfung des
  gespeicherten Zielbestands
- keine GPU-, CUDA- oder OpenCL-Abhängigkeit
- keine Zeittoleranz beim Metadatenvergleich
- keine Annahme, dass ein einzelner `Read()`-Aufruf einen Puffer füllt

## Erwartung

Für den Testbaum aus 20.000 kleinen Dateien (320,6 MiB) auf lokaler SSD mit
warmem Cache ergibt sich aus den Messungen:

| | Aufzählung | Hashing | Gesamt |
| --- | --- | --- | --- |
| Ist-Zustand | 1.242 ms | 26.928 ms | rund 28,2 s |
| nach Phase 2 | 245 ms | 5.512 ms | rund 5,8 s |

Das entspricht Faktor 4,9 bei Erstsicherungen, vollständigen Verifikationen und
Läufen mit vielen geänderten Dateien. Bei normalen Folgesicherungen bleibt der
Gewinn klein, weil unveränderte Hashes bereits heute wiederverwendet werden;
dort verbessert Phase 2 vor allem die Aufzählung.

Diese Zahlen gelten für die Messumgebung. Auf Zielen mit langsamerem Zugriff
verschiebt sich der Anteil zugunsten des Datenträgers, und der relative Gewinn
fällt geringer aus. Bestätigen müssen das die Messungen aus Phase 1.

Bei großen Dateien ändert Phase 2 nichts, weil die Verarbeitung dort schon
heute an der Kernrate von 283 MiB/s liegt. Für HDD- und langsame USB-Ziele
bleibt der Datenträger der Engpass; dort verbessern die Änderungen vor allem
CPU-Last, Speicherverhalten und Bedienreaktion. Ob Parallelisierung auf
schnellen Zielen zusätzlichen Nutzen bringt, ist offen und erst nach
End-to-End-Messungen zu entscheiden.
