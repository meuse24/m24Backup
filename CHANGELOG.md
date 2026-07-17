# Änderungsprotokoll

Alle wesentlichen Änderungen dieses Projekts werden in dieser Datei
dokumentiert. Die Versionierung orientiert sich an
[Semantic Versioning](https://semver.org/lang/de/).

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
