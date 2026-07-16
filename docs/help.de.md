# M24 Backup - Hilfe und Informationen

Version: {{VERSION}}
Stand: {{BUILD_DATE}}

## Bedienungsanleitung

Diese Hilfe beschreibt die Sicherung, Wiederherstellung und die wichtigsten
technischen Hintergründe von M24 Backup.

## Zweck des Programms

M24 Backup kopiert persönliche Windows-Ordner auf einen USB-Stick, eine
externe Festplatte oder ein anderes ausgewähltes Laufwerk. Die Sicherung ist
eine fortlaufende Sicherheitskopie, kein versioniertes Archiv mit mehreren
historischen Dateiständen.

Unterstützte Standardordner:

- Desktop
- Dokumente
- Downloads
- Bilder
- Musik
- Videos
- Favoriten
- Gespeicherte Spiele
- Kontakte

AppData, temporäre Dateien und Cache-Verzeichnisse werden bewusst nicht
gesichert.

## Programm starten

Starten Sie die App normalerweise mit `Bibliothekssicherung starten.vbs`.
Die Datei `Bibliothekssicherung starten.bat` ist für Diagnosefälle gedacht,
wenn ein sichtbares Konsolenfenster hilfreich ist.

## Sicherung erstellen

1. Oben den Modus **Sichern** wählen.
2. USB-Stick oder externe Festplatte anschließen.
3. Warten, bis das Laufwerk in der Liste erscheint, oder **Aktualisieren** klicken.
4. Ziellaufwerk auswählen.
5. Gewünschte Ordner markieren.
6. Optional weitere Ordner hinzufügen.
7. Optional Dry-Run, sicheren Auswurf oder Prüfsummen-Option anpassen.
8. **Sicherung starten** klicken.
9. Warten, bis der Status den Abschluss meldet.

Sicherungsordner und vorhandene technische Protokolle können direkt nach der
Laufwerkswahl aus der App geöffnet werden. Die Ergebnisübersicht lässt sich
über ihr Kontextmenü kopieren. Die Laufwerksliste aktualisiert sich automatisch;
ein Laufwerk mit vorhandener Sicherung für dieses Profil wird bevorzugt
ausgewählt. `F5` erzwingt eine sofortige Aktualisierung. `F1` öffnet die Hilfe,
`Strg+L` öffnet das Protokoll und `Strg+O` den Sicherungsordner.
Entfernen Sie das Ziellaufwerk niemals, solange der Vorgang läuft.

Ein Stern (`★`) kennzeichnet das zuletzt erfolgreich verwendete
Sicherungslaufwerk. Die App erkennt es anhand seiner Datenträger-ID wieder. Vor
einer Sicherung auf ein anderes Laufwerk fragt sie nach; erst nach einem
erfolgreichen Lauf wird das neue Laufwerk für die künftige Wiedererkennung
gespeichert.

Die App merkt sich die gewählten Standard- und Zusatzordner für den nächsten
Start. **Verlauf** zeigt die letzten zehn vorhandenen Protokolle. Mit **Backup
prüfen** wird jede Nutzdatei vollständig gelesen und ihre SHA-256-Prüfsumme mit
`_Pruefsummen.tsv` verglichen. Dadurch werden nicht lesbare, fehlende und
inhaltlich veränderte Dateien erkannt. Wenn das Fenster im Hintergrund liegt,
meldet Windows Abschluss, Fehler oder Abbruch zusätzlich als Benachrichtigung.

Das Manifest enthält eine Prüfsumme pro Datei und wird nach einem erfolgreichen
Backup im Worker aktualisiert, bevor die Sicherung als erfolgreich markiert
wird. Unveränderte Einträge werden über relativen Pfad, Größe und den exakten
Zeitstempel des Backup-Ziels wiederverwendet; neue oder geänderte Dateien werden
erneut gelesen. Alte Einträge bleiben passend zur No-Delete-Strategie erhalten.
Bei einer älteren Sicherung ohne Manifest bietet **Backup prüfen** an, den
aktuellen Inhalt einmalig als Ausgangszustand zu erfassen. Diese erstmalige
Erfassung kann bereits vorher vorhandene Beschädigungen naturgemäß nicht
erkennen. Ausgeschlossene temporäre Dateien werden weder gesichert noch in das
Manifest aufgenommen.

Die Option **Prüfsummen** ist standardmäßig aktiv. Wenn sie abgeschaltet wird,
läuft die Sicherung schneller, das Manifest bleibt aber auf dem vorherigen
Stand. **Backup prüfen** kann danach fehlende oder veraltete Prüfsummeneinträge
melden, bis wieder eine Sicherung mit aktivierten Prüfsummen abgeschlossen wurde.

Der erste Backup-Lauf nach Einführung des Manifests liest den gesamten
vorhandenen Zielbestand zusätzlich. Spätere Läufe hashen nur Dateien erneut,
deren Größe oder exakter Zielzeitstempel sich geändert hat. **Backup prüfen**
liest unabhängig davon immer alle Dateien vollständig, weil nur so der aktuelle
Inhalt sicher verglichen werden kann. Die laufende Prüfung lässt sich über
**Prüfung abbrechen** beenden. Bei einer abgebrochenen Initialisierung wird kein
unvollständiges Manifest gespeichert.

Die Prüfsummen erkennen zufällige Beschädigungen und unerwartete Änderungen.
Sie sind nicht kryptografisch signiert; ein Angreifer mit Schreibzugriff auf
Backup und Manifest könnte deshalb beide passend verändern.

<a id="dry-run"></a>
## Dry-Run: Sicherung nur simulieren

Die Option **Nur simulieren (Dry-Run)** führt Robocopy mit `/L` aus. Dadurch
erstellt die App ein normales Protokoll der geplanten Kopiervorgänge, kopiert
aber keine Nutzdaten und aktualisiert keine erfolgreichen Sicherungsmetadaten.

Ein Dry-Run eignet sich, wenn Sie vorab prüfen möchten, welche Dateien
kopiert oder überschrieben würden.

<a id="custom-folders"></a>
## Eigene Ordner hinzufügen

Mit **Hinzufügen** können Sie Arbeitsordner außerhalb der
Windows-Standardordner in die Sicherung aufnehmen. Die App verhindert
überlappende Ordner und reservierte interne Namen.

Zusatzordner werden im Sicherungsziel unter einem eindeutigen Namen abgelegt.
Die Datei `_Ordner.json` speichert den Originalpfad, damit diese Ordner bei
einer späteren Wiederherstellung wieder angeboten werden können.

<a id="safe-eject"></a>
## Laufwerk sicher auswerfen

Wenn **Laufwerk nach Erfolg sicher auswerfen** aktiv ist, versucht die App
nach einem erfolgreichen echten Backup auf einem Wechseldatenträger den
Windows-Auswurf. Der Auswurf wird kurz verzögert und bei Bedarf wiederholt,
damit Windows letzte Datei- und Prozesszugriffe schließen kann.

Scheitert der automatische Auswurf, bleibt die Sicherung trotzdem erfolgreich.
Entfernen Sie das Laufwerk dann manuell über Windows.

<a id="backup-health"></a>
## Backup-Ampel

Die Anzeige neben dem Ziellaufwerk bewertet die zuletzt erfolgreiche Sicherung
für diesen Computer und Benutzer:

- Grün: aktuelle Sicherung, höchstens 7 Tage alt.
- Gelb: Sicherung bald fällig, 8 bis 14 Tage alt.
- Rot: keine, fehlgeschlagene, abgebrochene oder veraltete Sicherung.

Die Details enthalten Datum, Anzahl der gesicherten Ordner und die Laufzeit,
sofern diese aus den Metadaten ermittelt werden kann.

<a id="delete-backup"></a>
## Backup löschen

Mit **Backup löschen** kann die Sicherung des aktuellen Computers und
Benutzers vom ausgewählten Laufwerk vollständig entfernt werden. Die Funktion
löscht weder das Laufwerk noch Sicherungen anderer Computer oder Benutzer.

Vor dem Löschen zeigt die App den vollständigen Pfad, Computer, Benutzer,
letztes Sicherungsergebnis, enthaltene Ordner, letzte Prüfsummenprüfung,
Datei- und Ordnerzahl sowie den belegten Speicherplatz an. Anschließend sind
zwei Bestätigungen erforderlich:

1. Die angezeigten Backup-Informationen müssen ausdrücklich bestätigt werden.
2. Der angezeigte Backup-Name `<Computer>_<Benutzer>` muss exakt eingegeben
   werden.

Erst danach werden Nutzdaten, Metadaten, Prüfsummen und Protokolle dieses
Profil-Backups endgültig gelöscht. Der Vorgang kann nicht rückgängig gemacht
werden. Während einer Sicherung, Wiederherstellung oder Backup-Prüfung ist die
Funktion gesperrt. Fehlende oder nicht zum aktuellen Profil passende Metadaten
verhindern die Löschung ebenfalls.

Ältere Sicherungen können vereinzelt Dateien oder Ordner mit reservierten
Windows-Gerätenamen wie `NUL` enthalten. Die App traversiert und entfernt diese
über erweiterte Windows-Pfade. Falls Windows ein solches Artefakt trotzdem
nicht löschen kann, werden alle übrigen Backup-Inhalte weiter entfernt und das
verbliebene Artefakt ausdrücklich gemeldet.

## Verhalten der Sicherung

- Neue und geänderte Dateien werden kopiert.
- Für noch vorhandene Quellpfade entspricht die gesicherte Dateiversion nach
  einem erfolgreichen Lauf dem aktuellen Quellbestand: Geänderte Quelldateien
  ersetzen ihre vorhandene Kopie im Backup auch dann, wenn ihr Zeitstempel
  älter ist. In der Quelle gelöschte Dateien bleiben im Backup erhalten.
- Dateien werden im Sicherungsziel nicht automatisch gelöscht.
- Robocopy `/MIR` und `/PURGE` werden nicht verwendet.
- Geöffnete oder gesperrte Dateien können übersprungen werden.
- Hinweise und Fehler werden im Protokoll festgehalten.

## Speicherplatz und FAT32

Vor dem Kopieren prüft die App den voraussichtlich benötigten Speicherplatz.
Reicht der freie Platz nicht aus, wird der Vorgang nicht gestartet.

FAT32 kann keine einzelne Datei ab 4 GB speichern. Für ein Sicherungslaufwerk
werden NTFS oder exFAT empfohlen. Beim Formatieren eines Laufwerks werden
dessen vorhandene Daten gelöscht.

<a id="restore"></a>
## Dateien wiederherstellen

1. Laufwerk mit der Sicherung anschließen.
2. Modus **Wiederherstellen** wählen.
3. Sicherungslaufwerk auswählen.
4. Gewünschte Backup-Ordner markieren.
5. **Wiederherstellung prüfen** klicken.
6. Konfliktvorschau lesen.
7. Wiederherstellung nur bestätigen, wenn die Angaben plausibel sind.

Die Konfliktvorschau zeigt lokal fehlende Dateien, mögliche
Überschreibungen, geschützte neuere lokale Dateien, Datenmenge und
Beispielpfade. Zusätzlich zeigt sie den Integritätsstatus des Backups: wann
die SHA-256-Prüfsummen zuletzt vollständig geprüft wurden oder ob diese
Prüfung noch aussteht. Vor einer wichtigen Wiederherstellung wird empfohlen,
zuerst **Backup prüfen** auszuführen. Ohne ausdrückliche Bestätigung werden
keine Dateien wiederhergestellt.

## Schutz bei der Wiederherstellung

- Neuere lokale Dateien bleiben durch Robocopy `/XO` geschützt.
- Lokal vorhandene Dateien werden nicht gelöscht.
- Die Rücksicherung verwendet weder `/MIR` noch `/PURGE`.
- Das Backup muss anhand seiner Metadaten zum aktuellen Computer und Benutzer
  passen.
- Der freie Platz wird für jedes betroffene lokale Laufwerk separat geprüft.

## Sicherung oder Wiederherstellung abbrechen

Der laufende Vorgang kann über **Sicherung abbrechen** beziehungsweise
**Wiederherstellung abbrechen** beendet werden. Der laufende Kopiervorgang
wird dabei sofort gestoppt; die gerade übertragene Datei kann dadurch
unvollständig im Ziel zurückbleiben. Bereits vollständig kopierte Dateien
bleiben erhalten. Nach einem Abbruch sollte die Sicherung erneut ausgeführt
oder das Backup mit **Backup prüfen** kontrolliert werden; ein abgebrochener
Lauf gilt nicht als erfolgreiche Sicherung.

## Speicherort der Sicherung

Die Daten werden nach diesem Schema abgelegt:

`<Laufwerk>:\Bibliothekssicherung\<Computer>_<Benutzer>\`

In diesem Ordner befinden sich:

- `_Sicherungsinfo.txt`: Zuordnung und Angaben zur Sicherung.
- `_Ordner.json`: Originalpfade frei hinzugefügter Ordner.
- `_Pruefsummen.tsv`: SHA-256-Prüfsummen der gesicherten Dateien.
- `_logs\`: technische Backup- und Restore-Protokolle.

## Protokolle

Backup-Protokolle heißen `robocopy_JJJJMMTT_HHMMSS.log`.
Restore-Protokolle heißen `restore_JJJJMMTT_HHMMSS.log`.

Robocopy-Codes von 0 bis 7 gelten als Erfolg oder Erfolg mit Hinweisen. Ab
Code 8 liegt ein Kopierfehler vor.

## Häufige Probleme

| Problem | Empfehlung |
| --- | --- |
| Kein Laufwerk sichtbar | Laufwerk anschließen, kurz warten oder **Aktualisieren** klicken. |
| Nicht genügend Speicherplatz | Daten auf dem Zielmedium entfernen oder größeres Laufwerk verwenden. |
| FAT32-Warnung | NTFS oder exFAT für das Sicherungslaufwerk verwenden. |
| Datei kann nicht gelesen werden | Prüfen, ob sie in einem anderen Programm geöffnet ist. |
| Ordner fehlt im Restore-Modus | Prüfen, ob `_Ordner.json` vorhanden ist und ob das Backup zum Profil passt. |

## Empfehlungen

- Regelmäßig sichern.
- Backup-Laufwerk nach Abschluss sicher entfernen.
- Backup-Laufwerk nicht dauerhaft angeschlossen lassen.
- Für unersetzliche Daten eine zweite Sicherung aufbewahren.
- Gelegentlich eine unkritische Datei testweise wiederherstellen.
- Protokolle mit Fehlern nicht ignorieren.

## Technikteil

Die folgenden Abschnitte dienen der Diagnose und Nachvollziehbarkeit.

## Komponenten

- `Bibliothekssicherung-GUI.ps1`: Windows-Forms-Oberfläche, Sprache, Modus,
  Laufwerks- und Ordnerauswahl, Status, Vorschauen, Abbruch und Hilfe.
- `Bibliothekssicherung.ps1`: Worker für Sicherung und Wiederherstellung,
  Validierung, Vorprüfung und Robocopy-Aufrufe.
- `M24Backup.Shared.ps1`: gemeinsame Helfer für reservierte Namen und
  Pfadverschachtelung.

## Tech-Stack

- Windows PowerShell 5.1
- .NET Framework mit `System.Windows.Forms` und `System.Drawing`
- Robocopy
- CIM/WMI `Win32_LogicalDisk`
- `Shell.Application` COM und `Win32_Volume` für optionalen Auswurf
- JSON für strukturierte Auswahl-, Vorschau- und Ergebnisdaten

## Prozessarchitektur

Die GUI startet einen separaten PowerShell-Worker. Statusmeldungen,
Vorschauen, Freigaben und Abbruchsignale werden über temporäre Dateien
ausgetauscht, damit die Oberfläche bedienbar bleibt.

## Inter-Prozess-Kommunikation

Die GUI übergibt die ausgewählten Ordner in einer temporären JSON-Datei.
Der Worker schreibt Status- und Ergebnisdateien atomar. Die GUI pollt diese
Dateien in kurzen Intervallen.

## Preflight und Konflikterkennung

Vor dem Kopieren prüft der Worker Ordner, Speicherplatz, FAT32-Grenzen und
bei Restore die Konfliktvorschau. Warnungen müssen bestätigt werden, bevor
Daten geschrieben werden.

## Robocopy-Parameter

| Parameter | Bedeutung |
| --- | --- |
| `/E` | Unterordner einschließlich leerer Ordner kopieren. |
| `/XJ` | Junctions nicht verfolgen, damit keine Schleifen entstehen. |
| `/FFT` | Zwei-Sekunden-Zeitstempeltoleranz für externe Dateisysteme. |
| `/XO` | Nur bei der Wiederherstellung: neuere lokale Dateien nicht durch ältere Sicherungsdateien ersetzen. Bei der Sicherung wird `/XO` nicht verwendet, damit auch geänderte Quelldateien mit älterem Zeitstempel gesichert werden. |
| `/MT:<Threads>` | Mehrere Kopierthreads verwenden. |
| `/R:1` | Einen Wiederholungsversuch bei Fehlern. |
| `/W:3` | Drei Sekunden Wartezeit zwischen Wiederholungen. |
| `/COPY:DAT` | Daten, Attribute und Zeitstempel kopieren, aber keine NTFS-ACLs. |
| `/DCOPY:DAT` | Verzeichnisdaten, Attribute und Zeitstempel erhalten. |
| `/NP` | Prozentfortschritt nicht ins Robocopy-Protokoll schreiben. |
| `/UNILOG+` | Unicode-Protokoll an die Logdatei anhängen. |
| `/NFL` / `/NDL` | Datei- und Verzeichnislisten im normalen Backup reduzieren. |
| `/XF` | Interne Metadaten- und Systemdateien ausschließen. |
| `/L` | Dry-Run: nur auflisten, nicht kopieren. |

Bei Dry-Run werden `/NFL` und `/NDL` absichtlich weggelassen, damit das
Protokoll die geplanten Dateien und Ordner zeigt. `/MIR` und `/PURGE` werden
absichtlich nie verwendet.

## Sicherheitsgrenzen

- Es wird keine Volume Shadow Copy erstellt; geöffnete oder gesperrte Dateien
  können übersprungen werden.
- Die Sicherung ist kein vollständiges Windows-Systemabbild.
- Programme, AppData und Systemeinstellungen werden nicht vollständig
  gesichert.
- Historische Dateiversionen werden nicht bereitgestellt.
- Bibliotheksordner, die auf Netzwerkfreigaben ohne Laufwerksbuchstaben
  umgeleitet sind, werden nicht unterstützt.
- Hardwaredefekte können weiterhin Lese- oder Schreibfehler verursachen.

## Exit-Codes

| Code | Bedeutung |
| --- | --- |
| `0` | Vorgang erfolgreich abgeschlossen. |
| `1` | Interaktiver Vorgang wurde vor dem Start abgelehnt. |
| `8` und höher | Robocopy hat mindestens einen Kopierfehler gemeldet. |
| `10` | Validierung, Vorprüfung, Freigabe oder allgemeiner Skriptfehler. |
| `20` | Vorgang wurde durch den Benutzer oder die GUI abgebrochen. |

Da der Robocopy-Rohwert unverändert zurückgegeben wird, kann Code `10` auch
von Robocopy stammen. Ergebnisdatei und Protokoll zeigen, in welcher Phase der
Fehler auftrat.

## Datenschutz und Sicherheit

Die App sendet keine Daten an externe Dienste. Einstellungen werden lokal im
Benutzerprofil gespeichert. Die Sicherungsdaten liegen unverschlüsselt auf
dem gewählten Laufwerk; schützen Sie das Laufwerk entsprechend.


