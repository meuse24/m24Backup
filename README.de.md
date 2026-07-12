# M24 Backup – Bibliothekssicherung

[English](README.md) | **Deutsch**

Eine kompakte Windows-Anwendung zum sicheren Sichern und Wiederherstellen der
persönlichen Ordner des angemeldeten Benutzers. Die Oberfläche erscheint auf
deutschsprachigen Windows-Systemen auf Deutsch und auf allen anderen Systemen
auf Englisch.

## Funktionen

- Sichert Desktop, Dokumente, Downloads, Bilder, Musik, Videos, Favoriten,
  gespeicherte Spiele und weitere erkannte Benutzerordner.
- Nutzt Robocopy und löscht keine Dateien aus dem Sicherungsziel.
- Prüft Ziel, freien Speicherplatz und FAT32-Einschränkungen vor dem Start.
- Zeigt Fortschritt und ein verständliches Ergebnis direkt im Fenster an.
- Zeigt eine Backup-Ampel mit Alter, Dauer und Ordnerzahl der letzten Sicherung
  auf dem ausgewählten Laufwerk.
- Erkennt das zuletzt erfolgreich verwendete Sicherungslaufwerk anhand seiner
  Datenträger-ID wieder, auch wenn Windows den Laufwerksbuchstaben ändert.
- Erstellt ein lesbares Protokoll und `_Sicherungsinfo.txt` auf dem Ziel.
- Unterstützt kooperatives Abbrechen zwischen den Ordnern.
- Bietet eine defensive Rücksicherung mit Metadatenprüfung, Vorschau und
  ausdrücklicher Bestätigung.
- Läuft ohne Administratorrechte und ohne zusätzliche Laufzeitinstallation.

> [!IMPORTANT]
> Eine Sicherung ist erst verlässlich, wenn eine Rücksicherung stichprobenartig
> geprüft wurde. Während der Wiederherstellung werden neuere lokale Dateien
> geschützt; die Vorschau sollte trotzdem aufmerksam kontrolliert werden.

## Installation

Die empfohlene Variante ist die Setup-Datei aus den
[GitHub Releases](https://github.com/meuse24/m24Backup/releases). Der Installer
installiert die Anwendung ohne Administratorrechte pro Benutzer unter
`%LocalAppData%\Programs\Bibliothekssicherung`, legt einen Startmenüeintrag an
und kann optional eine Desktop-Verknüpfung erstellen.

Alternativ kann das portable ZIP vollständig entpackt und
`Bibliothekssicherung starten.vbs` ausgeführt werden. Die Anwendung darf auch
direkt auf einem Sicherungslaufwerk liegen.

## Bedienung in Kürze

1. Sicherungslaufwerk anschließen und die Anwendung starten.
2. Modus **Sichern** und das gewünschte Ziellaufwerk auswählen.
3. Zu sichernde Ordner markieren und **Sicherung starten** wählen.
4. Den Abschlussstatus prüfen und bei Bedarf das Protokoll öffnen.

Für eine Rücksicherung den Modus **Wiederherstellen** wählen. Die Anwendung
akzeptiert nur eine Sicherung, deren Computer- und Benutzerinformationen zum
aktuellen Profil passen. Vor Änderungen erscheint eine Konfliktvorschau.

Die ausführliche Anleitung ist im Projekt und in jeder Distribution enthalten:

- [`Hilfe-und-Info.txt`](Hilfe-und-Info.txt) – Deutsch
- [`Help-and-Info.txt`](Help-and-Info.txt) – English

## Systemvoraussetzungen

- Windows 10 ab Version 1809 oder Windows 11
- Windows PowerShell 5.1
- .NET Framework mit Windows Forms
- Robocopy

Diese Komponenten sind in unterstützten Windows-Versionen bereits enthalten.

## Datenschutz und Sicherheitsmodell

Die Anwendung arbeitet lokal. Sie überträgt keine Dateien und keine
Nutzungsdaten ins Internet. Sicherungen werden nach Computer und Benutzer
getrennt abgelegt. Bei einer Rücksicherung werden die Sicherungsmetadaten
validiert, bevor lokale Dateien verändert werden. Robocopy-Rückgabecodes werden
ausgewertet; echte Kopierfehler führen nicht zu einem falschen Erfolgshinweis.

Die Skripte werden mit `ExecutionPolicy Bypass` in einem separaten
PowerShell-Prozess gestartet, damit lokale Richtlinien den Start nicht unnötig
verhindern. Das ändert keine systemweite Ausführungsrichtlinie. Release-Dateien
sollten nur aus einer vertrauenswürdigen Quelle bezogen und anhand von
`SHA256SUMS.txt` geprüft werden.

## Entwicklung

Die Anwendung besteht aus Windows PowerShell 5.1, Windows Forms und Robocopy.
Oberfläche und Sicherungs-Worker laufen in getrennten Prozessen und tauschen
atomar geschriebene Status- und JSON-Ergebnisdateien aus.

Lokaler Start:

```powershell
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass `
  -File ".\Bibliothekssicherung-GUI.ps1"
```

Die relativen Starter sind ebenfalls nutzbar:

- `Bibliothekssicherung starten.vbs` – normaler Start ohne Konsolenfenster
- `Bibliothekssicherung starten.bat` – Start für Diagnosezwecke

### Release bauen

Für den Installer wird [Inno Setup 6](https://jrsoftware.org/isinfo.php)
benötigt:

```powershell
winget install --id JRSoftware.InnoSetup -e --scope user
```

Nach dem Erstellen eines Versions-Tags baut das Skript Installer, portables ZIP
und SHA-256-Prüfsummen:

```powershell
git tag -a v1.0.0 -m "M24 Backup 1.0.0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\build.ps1" -RequireInstaller
```

Die Version wird aus `git describe --tags --always --dirty` abgeleitet. Ein
Build aus einem veränderten Arbeitsbaum erhält daher bewusst den Zusatz
`-dirty`. Die fertigen Artefakte liegen in `dist\`.

Nur das portable Paket bauen:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\build.ps1" -SkipInstaller
```

## Hinweise zur Veröffentlichung

Die erzeugten Pakete sind derzeit nicht digital signiert. Windows SmartScreen
kann deshalb bei Downloads aus dem Internet warnen. Für eine breitere
öffentliche Verteilung sollten Setup-Datei und Skripte mit einem
vertrauenswürdigen Code-Signing-Zertifikat signiert werden.

Dieses Repository enthält derzeit keine Open-Source-Lizenz. Eine öffentliche
Lesbarkeit des Quellcodes erteilt daher nicht automatisch Nutzungs-, Änderungs-
oder Weiterverteilungsrechte.
