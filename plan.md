# Plan: Superfast-Modus („Superschnell“)

## Ziel und feste Grenzen

Ein optionaler Modus beschleunigt ausschließlich Sicherungen, indem er die teuren
Vor- und Nachprüfungen auslässt und Robocopy aggressiver konfiguriert. Der Modus
ist standardmäßig aus und wird in der GUI durch genau eine nicht persistierte
Checkbox **„Superschnell (ohne Prüfungen)“** / **“Super fast (skip checks)”**
aktiviert.

Der Modus darf weder Daten am Ziel löschen noch bestehende Schutzgrenzen
aufweichen. Unverändert bleiben insbesondere:

- Laufwerks-, Profil- und Ordnerauswahlvalidierung,
- Schutz gegen ein Sicherungsziel innerhalb einer Quelle,
- Ausschluss von Junctions sowie temporären und Systemdateien,
- `_backup.lock`, Metadaten, Status-/Ergebnisdatei und Robocopy-Log,
- die additive Robocopy-Strategie ohne `/MIR` oder `/PURGE`,
- Restore, Backup-Prüfung und Backup-Löschung.

`-SuperFast` ist nur mit `-Mode Backup` und nie zusammen mit `-DryRun`
zulässig. Eine explizite CLI-Angabe `-Threads` hat Vorrang vor dem
Superfast-Standardwert.

## Tatsächliche Zeitersparnis

Im Superfast-Modus entfallen:

1. der vollständige Aufruf von `Get-BackupPreflight` für das Backup und damit
   rekursiver Quellscan, Datei-für-Datei-Zielvergleich und Scanwarnungsfreigabe;
2. die darauf basierende Netto-Speicherplatzberechnung und die Prüfung auf
   ausgewählte Dateien ab 4 GB bei FAT32;
3. die Aktualisierung von `_Pruefsummen.tsv`;
4. der Aufruf von `Get-BitLockerStatusText`;
5. Robocopy-Retries durch `/R:0` statt `/R:1`; `/W:1` kann aus Konsistenzgründen
   gesetzt bleiben, ist bei null Wiederholungen praktisch wirkungslos;
6. der konservative Thread-Standardwert 8: Ohne explizites `-Threads` wird
   `/MT:32` verwendet.

Die bereits vorhandene schnelle `Win32_LogicalDisk`-Abfrage bleibt bestehen. Sie
liefert Laufwerksvalidierung, freien Platz und Dateisystem für Anzeige und Log;
sie ist nicht die ausgelassene dateibasierte Speicherplatzschätzung. Die
allgemeine FAT32-Warnung darf daher weiterhin erscheinen, nur die Aussage
„konkret ausgewählte Dateien >= 4 GB gefunden“ entfällt.

Robocopy bleibt die Wahrheitsquelle für den Kopiererfolg. Im bestehenden Worker
sind Rückgabecodes 0 bis 7 Erfolg bzw. Erfolg mit Hinweisen; erst Codes ab 8
sind Kopierfehler. Der Plan darf daher nicht behaupten, gesperrte Dateien würden
stets als Code >= 2 oder immer als Fehler erscheinen. Maßgeblich bleiben die
vorhandene Codeauswertung, Warnungen und das Robocopy-Log.

## Umsetzung

### 1. Worker: `Bibliothekssicherung.ps1`

#### Parameter und frühe Invarianten

- `[switch]$SuperFast` neben `DryRun`/`SkipChecksums` ergänzen.
- Nach dem Laden der Shared-Funktionen und der Definition von `M`, aber vor jeder
  Laufwerksauflösung oder sonstigen Arbeit, folgende Kombinationen lokalisiert
  ablehnen:
  - `SuperFast` mit einem Modus ungleich `Backup`;
  - `SuperFast` zusammen mit `DryRun`.
- Vor der bestehenden Bereichsprüfung von `Threads`:
  `if ($SuperFast -and -not $PSBoundParameters.ContainsKey('Threads')) {
  $Threads = 32 }`. Anschließend weiterhin 1 bis 128 validieren.
- Den Trap-Ergebnisdatensatz um `SuperFast = $SuperFast.IsPresent` ergänzen, damit
  auch frühe Fehler einen konsistenten Moduskontext liefern.

#### Preflight sauber überspringen

- `Get-BackupPreflight` für Restore und normale Backups unverändert ausführen.
  Nur beim Superfast-Backup wird der Aufruf vollständig übersprungen.
- Einen expliziten Zustand verwenden, z. B. `$preflightPerformed = -not
  $SuperFast`. Keinen echten Scan durch ein scheinbar erfolgreiches
  Null-Ergebnis vortäuschen.
- Scanwarnungsfreigabe, dateibasierte Speicherplatzprüfung und 4-GB-Dateiprüfung
  nur ausführen, wenn `$preflightPerformed` wahr ist. Restore muss dadurch
  bytegleich in seinem bisherigen Ablauf bleiben.
- Alle späteren Ausgaben und Ergebniszugriffe absichern. Im Superfast-Fall:
  - Konsole: „Superfast: Vorprüfung übersprungen.“;
  - strukturierte Ergebnisse: `PreflightSkipped = $true` und
    `ScannedFiles`, `PlannedFiles`, `PlannedBytes` jeweils `$null`, nicht `0`.
    Null bedeutet „nicht ermittelt“; 0 würde fälschlich „ermittelt, keine Datei“
    behaupten.
- Für normale Backups und Restore `PreflightSkipped = $false` sowie die bisherigen
  Zahlen unverändert ausgeben.

#### BitLocker, Robocopy und Prüfsummen

- `Get-BitLockerStatusText` nur ohne Superfast aufrufen. Andernfalls einen
  lokalisierten Anzeige-/Logtext wie „BitLocker-Status: übersprungen
  (Superfast)“ setzen.
- Robocopy-Argumente über klar benannte effektive Werte aufbauen:
  `retryCount = 0/1`, `retryWait = 1/3`, `Threads = 32/8 bzw. explizit`.
  Restore und normale Backups behalten `/R:1 /W:3 /MT:8` beziehungsweise den
  expliziten Threadwert.
- Die Prüfsummenbedingung auf `($SkipChecksums -or $SuperFast)` erweitern und im
  Log zwischen „vom Benutzer übersprungen“ und „wegen Superfast übersprungen“
  unterscheiden.
- Das vorhandene Metadaten-Neuschreiben zu Beginn eines echten Backups muss
  bleiben: Es entfernt den früheren Vermerk `Pruefsummen-Pruefung` und markiert
  damit auch nach einem Superfast-Lauf eine frühere Vollprüfung nicht mehr als
  aktuell. Ein vorhandenes Manifest bleibt bewusst auf altem Stand; „Backup
  prüfen“ kann anschließend fehlende oder veraltete Einträge melden.
- Logkopf um `Superfast: Ja/Nein` ergänzen und die tatsächlich effektiven Werte
  für Threads, Retry und Wartezeit protokollieren.

#### Einheitlicher Ergebnisvertrag

Jeder Ergebnisdatensatz, nicht nur der Erfolgsfall, erhält soweit anwendbar:

- `SuperFast` (Boolean),
- `PreflightSkipped` (Boolean),
- `ChecksumSkipped` (bei echtem Superfast-Backup `true`),
- die Preflight-Zahlen oder `$null`, wenn nicht ermittelt.

Das betrifft Trap, Abbruch vor einem Ordner, Abbruch während Robocopy, Abbruch
nach der Schleife, Prüfsummenabbruch, Erfolg und Kopierfehler. Dadurch muss die
GUI nicht aus Prozesszustand oder fehlenden Feldern raten. Bestehende Felder und
Exitcodes bleiben kompatibel.

### 2. GUI: `Bibliothekssicherung-GUI.ps1`

#### Layout und Erklärung

- Die Optionsfläche ist aktuell nur 34 Pixel hoch und mit drei Optionen belegt.
  Für die vierte Checkbox die Fläche und die darunterliegenden Controls bewusst
  neu anordnen bzw. eine zweite Optionszeile schaffen; nicht lediglich eine
  weitere absolute X-Position in die bestehende Zeile quetschen. Fenstergröße,
  Scrollbarkeit, Tab-Reihenfolge sowie deutsche und englische Textbreiten prüfen.
- Tooltip mit den konkreten Folgen: kein Datei-Preflight, keine
  Speicherplatz-/4-GB-Dateiprüfung, keine Manifestaktualisierung, keine
  BitLocker-Abfrage, keine Kopierwiederholung. Zusätzlich klarstellen: Fehler
  fallen gegebenenfalls erst beim Kopieren auf.
- Checkbox standardmäßig aus und nicht in gespeicherten Einstellungen ablegen.

#### Deterministische Optionslogik

- `$script:activeSuperFast = $false` analog zu `activeDryRun` einführen, beim
  Start aus der UI erfassen und in allen Abschluss-/Fehlerpfaden zurücksetzen.
- `Update-BackupOptionState` und `Set-VerificationControlsEnabled` um die neue
  Checkbox ergänzen. Sie ist nur im Backup-Modus und nur im Leerlauf aktiv;
  laufendes Backup, Auswurf, Prüfung und Löschung dürfen keine Änderung zulassen.
- Dry-Run und Superfast gegenseitig ausschließen. Event-Rekursion mit einem
  kleinen Update-Guard verhindern. Die zuletzt bewusst aktivierte Option gewinnt
  und deaktiviert/entfernt die andere.
- Bei Superfast die Prüfsummencheckbox deaktivieren und sichtbar abwählen. Den
  vorherigen Prüfsummenwert zwischenspeichern und beim Abschalten von Superfast
  wiederherstellen, damit das bloße Ausprobieren der Option keine stille
  dauerhafte Optionsänderung bewirkt.
- Der sichere Auswurf bleibt zulässig; er findet erst nach erfolgreichem Lauf
  statt und ist kein Prüffeature des Kopiermodus.

#### Prozessstart und Statusanzeige

- Beim Start `activeSuperFast` festhalten und `-SuperFast` an die Workerargumente
  anhängen. Nicht zusätzlich `-SkipChecksums` anhängen; der Worker erzwingt das
  Verhalten selbst.
- Initialer Ergebnis- und Statustext muss im Superfast-Fall „Superschnelle
  Sicherung wird gestartet …“ statt „Vorprüfung wird gestartet …“ anzeigen.
  Normale Backups, Dry-Run und Restore bleiben unverändert.
- Erfolgsausgabe anhand von `result.SuperFast`/`result.PreflightSkipped`
  verzweigen: „Ohne Vorprüfung; Kopiervolumen nicht vorab ermittelt“ statt
  „Geplant: 0 Dateien / 0 GB“. Den vorhandenen Hinweis „Prüfsummen übersprungen“
  beibehalten.
- Fehler- und Abbruchanzeigen müssen mit älteren Worker-Ergebnisdateien ohne die
  neuen Properties kompatibel bleiben (`PSObject.Properties` prüfen).

### 3. Tests

#### Pester-Vertragstests

Eine neue Datei `tests/Bibliothekssicherung.Worker.Tests.ps1` anlegen; die
Shared-Tests nicht mit Worker-Vertragstests vermischen.

- Worker in einem separaten Windows-PowerShell-Prozess starten, weil das Skript
  selbst `exit` verwendet. Prüfen:
  - `-Mode Restore -SuperFast` endet vor Laufwerksauflösung mit Exitcode 10 und
    passender Fehlermeldung;
  - `-Mode Backup -SuperFast -DryRun` ebenso;
  - ein explizit ungültiger Threadwert wird weiterhin abgelehnt.
- Per PowerShell-AST bzw. durch eine kleine testbare Policy-Hilfsfunktion prüfen:
  - Parameter `SuperFast` existiert;
  - impliziter Superfast-Wert ergibt 32 Threads, explizites `-Threads 5` bleibt 5;
  - Superfast ergibt `/R:0 /W:1`, normal und Restore weiterhin `/R:1 /W:3`;
  - Superfast impliziert übersprungene Prüfsummen.
- Falls die Policy nicht ohne Ausführung des gesamten Workers testbar ist, die
  reine Parameter-/Robocopy-Policy in eine kleine Funktion in
  `M24Backup.Shared.ps1` auslagern und dort direkt testen. Statische
  Textsuchen allein sind kein ausreichender Verhaltensnachweis.
- Bestehende Pester-Suite und PSScriptAnalyzer mit Severity `Error` müssen
  weiterhin bestehen.

#### Manueller Smoke-Test auf Windows

1. Normaler Backup-Lauf: Preflight, Standardparameter und Manifest unverändert.
2. Superfast-Lauf auf kleinem Testbestand: kein Preflight-/Prüfsummenstatus,
   Log enthält `/MT:32`, `/R:0` und übersprungene Prüfungen, Ergebnis enthält
   Null-Planwerte.
3. Superfast mit explizitem `-Threads 5`: Log/Robocopy verwenden 5.
4. Gesperrte Testdatei und zu kleines Testziel: kein Retry; tatsächlicher
   Robocopy-Code und Ergebnisstatus werden dokumentiert, ohne einen bestimmten
   Code vorwegzunehmen.
5. FAT32 oder geeignetes Testabbild mit >4-GB-Datei: keine Vorabblockade,
   Kopierfehler wird regulär als Fehlschlag behandelt.
6. Danach Restore-Vorschau und „Backup prüfen“: Restore-Ablauf unverändert;
   Prüfsummenstatus ist nicht fälschlich aktuell.
7. GUI-Wechsel zwischen Dry-Run, Superfast, Restore und Prüfsummen sowie Start,
   Abbruch, Prüfung und Löschung; Checkboxzustände und Layout in DE/EN prüfen.

### 4. Dokumentation und Release

- Worker-Kopfkommentar um ein `-SuperFast`-Beispiel ergänzen.
- `README.md`, `README.de.md`, `docs/help.de.md` und `docs/help.en.md` um Modus,
  Ausschlüsse, Risiken und den nicht aktualisierten Manifeststand ergänzen.
- `CHANGELOG.md` erhält einen Abschnitt für 1.6.0. Keine Versionskonstante in
  `build.ps1` oder im Installer ändern: Das Projekt leitet die Version aus dem
  Tag bzw. dem Release-Parameter ab.
- Nach vollständiger Prüfung ist der vorgesehene Releaseweg
  `release.ps1 -Bump Minor` (zunächst sinnvoll mit `-WhatIf` oder `-LocalOnly`).
  Build-Ausgaben in `build/staging`, `build/portable` und `dist` nicht manuell
  editieren.

## Akzeptanzkriterien

- Ohne `-SuperFast` ändern sich Workerargumente, Preflight, Restore und Ergebnisse
  nicht semantisch.
- Mit `-SuperFast` wird kein `Get-BackupPreflight`,
  `Get-BitLockerStatusText` oder `Update-M24ChecksumManifest` aufgerufen.
- Superfast verwendet ohne Thread-Override `/MT:32 /R:0 /W:1`; ein expliziter
  Threadwert bleibt erhalten.
- Kein Modus verwendet `/MIR` oder `/PURGE`; am Ziel wird nichts gelöscht.
- Robocopy-Code >= 8 führt weiterhin zu „Mit Fehlern beendet“ und einem
  nicht erfolgreichen strukturierten Ergebnis.
- GUI und JSON stellen „nicht vorab ermittelt“ niemals als null Dateien/null GB
  dar.
- Superfast ist nach jedem GUI-Neustart wieder aus, mit Dry-Run unvereinbar und
  für Restore nicht auswählbar.
- Pester, PSScriptAnalyzer und die manuellen Smoke-Tests sind erfolgreich.

## Empfohlene Reihenfolge

1. Testbare Worker-Policy und Parameterinvarianten.
2. Preflight-/BitLocker-/Manifest-Guards und vollständiger Ergebnisvertrag.
3. GUI-Layout, Optionszustände, Workerargumente und Ergebnisanzeige.
4. Automatisierte Tests und Smoke-Tests.
5. Dokumentation, Changelog und Releaseprüfung.
