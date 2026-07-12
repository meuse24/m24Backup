# Änderungsprotokoll

Alle wesentlichen Änderungen dieses Projekts werden in dieser Datei
dokumentiert. Die Versionierung orientiert sich an
[Semantic Versioning](https://semver.org/lang/de/).

## [Unveröffentlicht]

### Hinzugefügt

- Backup-Ampel für das ausgewählte Laufwerk mit Abschlussstatus, Alter,
  Laufzeit und Anzahl der zuletzt erfolgreich gesicherten Ordner
- Wiedererkennung und automatische Auswahl des zuletzt erfolgreich verwendeten
  Sicherungslaufwerks über seine Datenträger-ID
- Sicherheitsabfrage vor dem Wechsel auf ein anderes Sicherungslaufwerk
- Release-Orchestrator mit automatischer SemVer-Erhöhung, Schutzprüfungen,
  Build, Git-Tag, Push und Veröffentlichung der Artefakte als GitHub-Release

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
