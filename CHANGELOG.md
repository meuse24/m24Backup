# Änderungsprotokoll

Alle wesentlichen Änderungen dieses Projekts werden in dieser Datei
dokumentiert. Die Versionierung orientiert sich an
[Semantic Versioning](https://semver.org/lang/de/).

## [Unreleased]

### Geändert

- Der Wiederherstellungsmodus erkennt nun alle Sicherungen auf dem gewählten
  Laufwerk. Vollständige Sicherungen anderer Computer oder Benutzer können in
  das aktuelle Profil übernommen oder in einen frei gewählten Ordner kopiert
  werden. Windows-Bibliotheken werden automatisch den aktuellen Pfaden
  zugeordnet; zusätzliche Ordner fremder Sicherungen landen sicher gesammelt
  unter „Wiederhergestellte Ordner“. Unvollständige oder metadatenlose
  Sicherungen lassen sich nur separat kopieren, aber jederzeit im Explorer
  öffnen. Der bestehende Restore der eigenen Profilsicherung und die streng
  profilgebundene Löschfunktion bleiben erhalten.
- Erwartete Zugriffsfehler geschützter Windows-Kompatibilitätsjunctions wie
  „Eigene Bilder“, „Eigene Musik“ und „Eigene Videos“ lösen in der Vorprüfung
  keinen Bestätigungsdialog mehr aus. Da Robocopy diese Verknüpfungen mit `/XJ`
  ohnehin auslässt, werden sie stattdessen mit einer erklärenden Anmerkung im
  Sicherungsprotokoll festgehalten. Andere Lesefehler bleiben Warnungen.

## [1.9.1] – 2026-07-20

### Geändert

- Vor dem Sichern werden alle angehakten System- und Zusatzordner auf identische
  oder verschachtelte Quellpfade geprüft. Dadurch wird etwa ein nach
  `Dokumente\Downloads` umgeleiteter Download-Ordner nicht zusätzlich zu
  `Dokumente` doppelt gesichert. GUI und Worker brechen mit einer verständlichen
  Konfliktmeldung ab; Wiederherstellungen bleiben davon unberührt.
- Die Ergebnisübersicht übernimmt nach Abschluss der Ordnergrößenmessung
  zuverlässig den finalen Gesamtwert und bleibt nicht mehr dauerhaft bei
  „Gesamtgröße wird ermittelt …“ stehen. Jeder Messauftrag erhält garantiert
  einen Abschlusszustand; verwaiste Cachemarker werden einmal wiederholt und
  anschließend gegebenenfalls als „nicht ermittelbar“ ausgewiesen. Scanner-
  und Cachezustände werden im lokalen GUI-Diagnoseprotokoll festgehalten.

## [1.9.0] – 2026-07-19

### Hinzugefügt

- „Backup prüfen“ schreibt für erfolgreiche, fehlgeschlagene und abgebrochene
  Prüfungen ein dauerhaftes Protokoll unter `_logs`. Es enthält Prüfart,
  SHA-256-Algorithmus, Beginn, Ende, Dauer, Datenumfang, Ergebnis und
  Fehlerdetails und ist anschließend über „Protokoll“ und „Verlauf“ erreichbar.
- Die Ordnerliste zeigt hinter jedem Ordner Dateianzahl und Platzbedarf an
  (z. B. „Dokumente — 249 Dateien, 4,94 GB“). Die Ermittlung läuft im
  Hintergrund und blockiert die Oberfläche nicht; im Modus
  **Wiederherstellen** wird der Inhalt des Backups vermessen. Die Zählung
  folgt der Vorprüfung der Sicherung: Der gewählte Ordner selbst wird immer
  vermessen, untergeordnete Junctions werden wie bei Robocopy `/XJ` nicht
  verfolgt, Verzeichnis-Symlinks dagegen schon; unzugängliche Unterordner
  werden übersprungen. Die Werte sind einmal je Sitzung ermittelte
  Näherungen.
- Die Ergebnisübersicht ergänzt „x Ordner ausgewählt“ um die Gesamtzahl der
  Dateien und den Gesamtplatzbedarf der angehakten Ordner (z. B. „9 Ordner
  ausgewählt (7.455 Dateien, 11,42 GB).“). Solange Messungen laufen, steht
  dort „Gesamtgröße wird ermittelt …“.

### Geändert

- Modernisierte Windows-11-Oberfläche: Das Hauptfenster ist jetzt frei in der
  Größe veränderbar und maximierbar; die Ordnerliste nutzt zusätzlichen Platz.
  Das Layout basiert auf flexiblen Layout-Containern statt fester Koordinaten.
- Die Anwendung ist explizit System-DPI-aware und skaliert ihr Layout scharf
  auf die Anzeigeskalierung (100–200 %). PerMonitorV2 ist unter dem
  Windows-PowerShell-Host ohne App-Konfiguration nicht zuverlässig verfügbar;
  die gewählte Strategie ist im GUI-Skript dokumentiert.
- Ordnerauswahl und Backupverwaltung sind klar getrennt: **Verlauf**,
  **Backup prüfen** und **Backup löschen** bilden eine eigene beschriftete
  Gruppe; **Backup löschen** steht räumlich abgesetzt. Das große Logo wurde
  aus dem Arbeitsbereich entfernt (Branding verbleibt in Symbol und Splash).
- Einheitliche, größere Bedienziele: Sekundärbefehle sind mindestens
  32 logische Pixel hoch, die Hauptaktionen im Fußbereich 40.
- Die Option **Superschnell** heißt jetzt **Schnellmodus (ohne Vorprüfung)**,
  damit die Sicherheitsfolge sichtbar ist. Die Erinnerung beim Windows-Login
  ist als dauerhafte Einstellung (**Beim Windows-Login an fällige Sicherungen
  erinnern**) von den Vorgangsoptionen getrennt.
- Bei aktivem Windows-Hochkontrastmodus verwendet die Oberfläche durchgehend
  Systemfarben und die Systemdarstellung der Schaltflächen; wichtige
  Steuerelemente besitzen jetzt Namen für die UI-Automatisierung (Narrator).
- Der Splashscreen erscheint nur noch bei messbar langsamen Starts (ab etwa
  0,4 s), ist deutlich kleiner, nicht mehr immer im Vordergrund und hält den
  Start nicht mehr künstlich um 300 ms auf.
- Die Kurzanleitung nennt die Windows-Start-Erinnerung nun ausdrücklich bei
  den Optionen einer Sicherung, damit der vorhandene ausführliche Hilfeabschnitt
  leichter auffindbar ist.

## [1.8.0] – 2026-07-18

### Hinzugefügt

- Standardmäßig aktivierte Backup-Erinnerung beim Windows-Start: Nach 14 Tagen ohne
  erfolgreiches GUI-Backup erscheint für den aktuellen Benutzer eine native
  Windows-Benachrichtigung. Die Funktion benötigt weder Dienst noch
  Administratorrechte, ist über die GUI abschaltbar und repariert ihren
  Autostartpfad nach einem Verschieben der portablen App selbst.
- GUI-Worker überwachen jetzt die exakte Eigentümerinstanz per PID und
  Prozessstartzeit. Verschwindet die GUI, beendet sich der Worker über den
  kontrollierten Abbruchpfad; Ergebnisdateien unterscheiden `User` und
  `GuiExited`.
- Die GUI ist pro Windows-Benutzersitzung auf eine Instanz begrenzt.
- Restores aus der GUI prüfen ein vorhandenes SHA-256-Manifest automatisch,
  wenn seit dem letzten Backup noch keine erfolgreiche Vollprüfung vorliegt.
  Ohne Manifest ist eine zweite ausdrückliche Risikobestätigung erforderlich.
- Die Erkennung des bekannten Sicherungslaufwerks verwendet einen gestuften
  Fingerprint aus Volume-GUID, Datenträger-ID, Volume-Seriennummer, Größe und
  Dateisystem und akzeptiert mehrdeutige Treffer nicht automatisch.
- CI führt Pester mit Windows PowerShell 5.1 und PowerShell 7 aus und baut das
  portable Paket als nicht signierten Smoke-Test.

### Geändert

- Die kompakte Option **Erinnern** ist standardmäßig aktiv und weist beim
  Windows-Start nach 14 Tagen ohne erfolgreiches GUI-Backup auf die fällige
  Sicherung hin. Bestehende Einstellungen werden einmalig auf das neue
  Standardverhalten migriert; eine anschließende Deaktivierung bleibt erhalten.
- Der Splashscreen zeigt vor dem Öffnen des Hauptfensters kurz den vollständig
  gefüllten Fortschrittsbalken und den Status **Bereit** an.

### Behoben

- Das Registrieren der Backup-Erinnerung aktualisiert ausschließlich den
  anwendungseigenen Autostartwert `M24Backup`. Andere Werte im gemeinsamen
  Windows-Run-Key bleiben vollständig erhalten.

## [1.7.0] – 2026-07-18

### Hinzugefügt

- Lokales GUI-Diagnoseprotokoll unter `%LOCALAPPDATA%\M24Backup\Logs\gui.log`:
  Fehler der Oberfläche selbst (z. B. ein fehlgeschlagener Start des
  Worker-Prozesses) werden mit Zeitstempel, Ereignis-ID, Exception und
  Skript-Stack lokal festgehalten – unabhängig vom Sicherungslaufwerk und
  damit auch ohne angeschlossenes Ziel verfügbar. Das Protokoll rotiert
  automatisch (`gui.1.log` bis `gui.4.log`, insgesamt etwa 10 MB) und darf
  den ursprünglichen Fehler nie überdecken.
- Verwaiste temporäre Kommunikationsdateien früherer Sitzungen (Status-,
  Ergebnis-, Abbruch-, Vorschau-, Freigabe- und Ordnerlisten-Dateien samt
  atomarer `.tmp`-/`.bak`-Reste sowie Verify-Abbruchmarker) werden beim
  GUI-Start still aus dem Temp-Verzeichnis entfernt. Gelöscht wird bewusst
  konservativ: nur exakt erkannte, anwendungseigene Dateinamen, die älter
  als sieben Tage sind – auch wenn sie schreibgeschützt sind. Frische
  Dateien – etwa einer zweiten GUI-Instanz oder eines noch laufenden
  Workers – sowie Verzeichnisse, Symlinks und ähnlich benannte
  Fremddateien bleiben unangetastet; Fehler bei der Bereinigung
  beeinflussen den Programmstart nicht.

### Geändert

- Die Laufwerkserkennung begrenzt die Windows-Systemabfrage (WMI/CIM) auf
  acht Sekunden und pausiert nach einem Fehlschlag 30 Sekunden, bevor sie
  automatisch erneut abfragt; manuelles Aktualisieren fragt weiterhin sofort
  ab. Die Oberfläche bleibt dadurch auch bei einer hängenden Systemabfrage
  bedienbar, und die bestehende Fehlermeldung bleibt sichtbar.

### Behoben

- Schlägt der Start einer Sicherung oder Wiederherstellung unmittelbar nach
  dem Anlegen des Worker-Prozesses fehl, wird dieser jetzt kontrolliert
  beendet (kooperative Abbruchanforderung, danach erzwungenes Ende mit hart
  begrenzten Wartezeiten) statt unbeobachtet weiterzulaufen. Die temporären
  Kommunikationsdateien werden nur nach bestätigtem Prozessende sofort
  entfernt; andernfalls bleibt die Abbruchdatei für den Worker wirksam und
  die Reste übernimmt später die Temp-Bereinigung.

## [1.6.0] – 2026-07-18

### Hinzugefügt

- Neuer Superschnell-Modus (`-SuperFast` bzw. Checkbox **Superschnell (ohne
  Prüfungen)**): Er überspringt die Datei-Vorprüfung samt
  Speicherplatz-/4-GB-Prüfung, die Aktualisierung des Prüfsummenmanifests und
  die BitLocker-Abfrage und kopiert mit `/R:0 /W:1` sowie standardmäßig 32
  Robocopy-Threads. Ein explizit gesetzter `-Threads`-Wert hat Vorrang. Der
  Modus gilt nur für Sicherungen, ist nicht mit Dry-Run kombinierbar, ist nach
  jedem App-Start wieder abgeschaltet und ändert keine Schutzgrenzen: Am Ziel
  wird weiterhin nichts gelöscht; Sperrdatei, Metadaten und Protokoll bleiben
  aktiv.
- Die Ergebnisdatei des Workers enthält jetzt `SuperFast` und
  `PreflightSkipped`; ohne Vorprüfung werden `ScannedFiles`, `PlannedFiles` und
  `PlannedBytes` als `null` („nicht ermittelt“) statt fälschlich als `0`
  gemeldet. GUI und Protokoll weisen den Modus und die tatsächlich verwendeten
  Robocopy-Parameter aus.
- Ein Splashscreen mit dem M24-Backup-Logo zeigt den Programmstart sowie das
  Laden der Einstellungen und die Laufwerksprüfung an, bis das Hauptfenster
  vollständig dargestellt ist.
- Die integrierte Hilfe dokumentiert den direkten Worker-Aufruf samt öffentlichen
  Kommandozeilenparametern, Kombinationsregeln und Beispielen und enthält einen
  zweisprachigen Autor- und Credits-Abschnitt.

### Behoben

- Externe USB-HDDs und -SSDs, die Windows als festen lokalen Datenträger
  meldet, werden anhand ihres physischen USB-Bus-Typs erkannt. Dadurch erscheint
  keine falsche Warnung vor einem internen Sicherungsziel mehr und der sichere
  Auswurf bleibt auch für externe USB-Laufwerke mit `DriveType 3` verfügbar.
- Unbehandelte Fehler beim Programmstart werden auch beim unsichtbaren
  VBS-/PowerShell-Start in einem sichtbaren, lokalisierten Fehlerdialog erklärt,
  statt Splashscreen und Prozess kommentarlos zu beenden.

## [1.5.1] – 2026-07-17

### Behoben

- Die Speicherplatz-Vorprüfung zählte Dateien, die am Ziel bereits vorhanden
  sind und nur überschrieben werden müssen (z. B. wegen abweichender
  Zeitstempel), mit ihrer vollen Größe als zusätzlichen Platzbedarf.
  Folgesicherungen auf einen Datenträger mit weitgehend aktuellem Backup brachen
  dadurch fälschlich mit „Nicht genug freier Speicherplatz“ ab. Geprüft wird
  jetzt der Netto-Mehrbedarf: fehlende Dateien mit voller Größe, zu
  überschreibende Dateien nur mit der Größendifferenz (mindestens 0 Byte).
- Die Fehlermeldung bei zu wenig Speicherplatz nennt jetzt den tatsächlich
  verglichenen Wert inklusive Reserve (5 %, mindestens 200 MB). Bisher wurde
  der Bedarf ohne Reserve angezeigt, wodurch die Meldung scheinbar
  widersprüchlich einen kleineren Bedarf als den freien Speicher auswies.

## [1.5.0] – 2026-07-16

### Hinzugefügt

- Ausgewählte Profil-Backups können nach einer Detailanzeige und zweistufigen
  Sicherheitsabfrage vollständig gelöscht werden. Pfad-, Metadaten- und
  Sperrprüfungen schützen andere Backups und laufende Vorgänge.
- Alte Dateien und Ordner namens `NUL` oder mit ähnlichen reservierten
  Windows-Gerätenamen werden bei der Backup-Löschung über erweiterte Pfade
  traversiert und entfernt oder, falls Windows dies verweigert, gemeldet und
  übersprungen, ohne die übrige Löschung abzubrechen.

## [1.4.2] – 2026-07-16

### Geändert

- Dateien mit reservierten Windows-Gerätenamen (z. B. `nul`) brechen die
  Prüfsummenphase auch dann nicht mehr ab, wenn sie sich nicht lesen lassen:
  Sie werden dann ohne Prüfsumme übersprungen und im Protokoll vermerkt.
  Auch bei der Integritätsprüfung zählen solche Dateien nie als Fehler

## [1.4.1] – 2026-07-16

### Behoben

- Die Prüfsummenberechnung scheiterte an Dateien mit reservierten
  Windows-Gerätenamen (z. B. `nul`, `con`, `com1`) und brach die Sicherung
  nach erfolgreichem Kopieren ab. SHA-256-Hashing verwendet jetzt das
  erweiterte Pfadpräfix `\\?\` und verarbeitet solche Dateien wie Robocopy

## [1.4.0] – 2026-07-16

Sammelrelease: enthält auch die seit v1.0.0 in den Zwischenreleases
v1.1.0 bis v1.3.0 veröffentlichten Änderungen.

### Behoben

- Sicherungen verwenden Robocopy `/XO` nicht mehr: Inhaltlich geänderte
  Quelldateien mit älterem Zeitstempel werden jetzt zuverlässig gesichert.
  `/XO` schützt weiterhin neuere lokale Dateien bei der Wiederherstellung.
- Die Hilfe beschreibt den Abbruch jetzt korrekt: Robocopy wird sofort
  gestoppt und die zuletzt übertragene Datei kann unvollständig im Ziel
  zurückbleiben.

### Hinzugefügt

- Integritätsstatus vor der Wiederherstellung: Die Konfliktvorschau zeigt an,
  wann die SHA-256-Prüfsummen zuletzt vollständig geprüft wurden bzw. dass
  die Prüfung noch aussteht; eine erfolgreiche Vollprüfung wird in
  `_Sicherungsinfo.txt` vermerkt und durch jede neue Sicherung entwertet
- Verlauf bietet das Öffnen des Protokollordners an; die Ergebnisübersicht
  hat eine Scrollleiste
- Abschnitt „Wichtige Einschränkungen" (unverschlüsselte Sicherungsdaten,
  kein VSS, keine Versionierung) in beiden READMEs
- Veröffentlichung unter der MIT-Lizenz; die Lizenzdatei ist Teil des
  Repositorys und aller Distributionen
- Release-Build-Workflow, der die Artefakte nachvollziehbar in GitHub Actions
  baut, eine vorbereitete SignPath-Signierung enthält und bei einem Tag-Push
  das GitHub-Release ausschließlich aus den CI-Artefakten veröffentlicht;
  dazu die Code-Signing-Richtlinie in beiden READMEs und eine
  Antragsanleitung unter `docs/signpath-application.md`
- Windows-Benachrichtigungen für abgeschlossene, fehlgeschlagene und
  abgebrochene Vorgänge im Hintergrund
- Dauerhaft gespeicherte Auswahl von Standard- und Zusatzordnern
- Verlauf der letzten zehn Protokolle und vollständige Integritätsprüfung gegen
  dateiweise SHA-256-Prüfsummen mit Initialisierung bestehender Sicherungen
- Backup-Ampel für das ausgewählte Laufwerk mit Abschlussstatus, Alter,
  Laufzeit und Anzahl der zuletzt erfolgreich gesicherten Ordner
- Wiedererkennung und automatische Auswahl des zuletzt erfolgreich verwendeten
  Sicherungslaufwerks über seine Datenträger-ID
- Sicherheitsabfrage vor dem Wechsel auf ein anderes Sicherungslaufwerk
- Dry-Run-Modus fuer Sicherungen mit Robocopy `/L`, sichtbarer Datei- und
  Ordnerliste im Protokoll und ohne Veraenderung echter Sicherungsmetadaten
- Frei waehlbare Zusatzordner per Ordnerauswahl, inklusive Metadaten fuer eine
  spaetere Wiederherstellung an den Originalpfad
- Option zum sicheren Auswerfen eines erfolgreich verwendeten
  USB-Sicherungslaufwerks
- Animierte Fortschrittsanzeige während laufender Sicherungs-, Simulations-
  und Wiederherstellungsvorgänge
- Laufzeitanzeige für laufende Vorgänge und klarer Zwischenstatus während
  eines angeforderten Abbruchs
- Automatischer Auswurf wird nach erfolgreicher Sicherung kurz verzögert
  und mit Wiederholungsversuchen gestartet, damit Windows letzte Datei- und
  Prozesszugriffe schließen kann
- Lokales HTML-Hilfesystem mit Markdown-Quellen, Inhaltsverzeichnis und
  kontextsensitiven Hilfe-Schaltflaechen in der GUI
- Release-Orchestrator `release.ps1` mit automatischer SemVer-Erhöhung,
  Schutzprüfungen, lokalem Verifikations-Build sowie Git-Tag und Push; das
  GitHub-Release veröffentlicht anschließend der Release-Build-Workflow,
  lokal gebaute Artefakte werden nie veröffentlicht

### Geändert

- Speicherarme, iterative Vorprüfung großer Ordnerstrukturen mit derselben
  Junction-/Symlink-Semantik wie Robocopy
- Atomare UTF-8-BOM-Kommunikationsdateien und präzisere Kennzeichnung
  unvollständiger Robocopy-Läufe
- Ressourcenschonenderes Status-Polling und sofortiger BitLocker-Fallback bei
  nicht erhöht gestarteten Prozessen
- Neues M24-Backup-Logo und daraus neu erzeugtes Mehrgrößen-App-/Installer-Icon
- Icon-Hintergrundentfernung bewahrt eingeschlossene weiße Motivflächen und
  funktioniert dadurch auch auf dunklen Windows-Hintergründen korrekt
- Fenstergröße gegen manuelles Verändern gesperrt und Maximieren entfernt;
  automatische Höhenanpassung und Scrollen auf kleinen Bildschirmen bleiben
  erhalten

## [1.0.0] – 2026-07-12

Erste öffentliche, releasefähige Version.

### Enthalten

- Zweisprachige Windows-Forms-Oberfläche (Deutsch/Englisch)
- Sicherung persönlicher Windows-Ordner mit Robocopy
- Ziel-, Speicherplatz- und FAT32-Prüfungen
- Atomare Statuskommunikation zwischen Oberfläche und Worker
- Kooperativer Abbruch mit strukturiertem Ergebnis
- Protokollierung und Sicherungsmetadaten
- Defensive Rücksicherung mit Profilvalidierung und Konfliktvorschau
- Responsive, scrollbar erreichbare Oberfläche für kleinere Bildschirme
- Relative Batch- und VBS-Starter
- Portables ZIP und per-user Inno-Setup-Installer
- Versionsanzeige und SHA-256-Prüfsummen für Release-Artefakte

[1.4.2]: https://github.com/meuse24/m24Backup/releases/tag/v1.4.2
[1.4.1]: https://github.com/meuse24/m24Backup/releases/tag/v1.4.1
[1.4.0]: https://github.com/meuse24/m24Backup/releases/tag/v1.4.0
[1.0.0]: https://github.com/meuse24/m24Backup/releases/tag/v1.0.0
