# Änderungsprotokoll

Alle wesentlichen Änderungen dieses Projekts werden in dieser Datei
dokumentiert. Die Versionierung orientiert sich an
[Semantic Versioning](https://semver.org/lang/de/).

## [Unveröffentlicht]

### Hinzugefügt

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
- Release-Orchestrator mit automatischer SemVer-Erhöhung, Schutzprüfungen,
  Build, Git-Tag, Push und Veröffentlichung der Artefakte als GitHub-Release
- Automatische Wiederholungsversuche bei vorübergehenden GitHub-API- und
  Netzwerkfehlern während der Release-Veröffentlichung

### Geändert

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

[1.0.0]: https://github.com/meuse24/m24Backup/releases/tag/v1.0.0
