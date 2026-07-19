# M24 Backup – Bibliothekssicherung

[English](README.md) | **Deutsch**

<p align="center">
  <img src="logo.jpg" alt="M24-Backup-Logo" width="220">
</p>

Eine kompakte Windows-Anwendung zum sicheren Sichern und Wiederherstellen der
persönlichen Ordner des angemeldeten Benutzers. Die Oberfläche erscheint auf
deutschsprachigen Windows-Systemen auf Deutsch und auf allen anderen Systemen
auf Englisch.

## Funktionen

- Erinnert standardmäßig beim Windows-Start, wenn das letzte erfolgreiche
  GUI-Backup mindestens 14 Tage zurückliegt – ohne
  Dienst und ohne Administratorrechte.
- Sichert Desktop, Dokumente, Downloads, Bilder, Musik, Videos, Favoriten,
  gespeicherte Spiele und weitere erkannte Benutzerordner.
- Nutzt Robocopy und löscht keine Dateien aus dem Sicherungsziel.
- Prüft Ziel, freien Speicherplatz und FAT32-Einschränkungen vor dem Start.
- Kann eine Sicherung per Dry-Run simulieren und die geplanten Änderungen im
  Protokoll anzeigen, ohne Nutzdaten zu kopieren.
- Bietet einen Schnellmodus (ohne Vorprüfung, früher „Superschnell“), der
  Vorprüfung, Prüfsummenaktualisierung und Kopierwiederholungen weglässt, wenn
  maximale Geschwindigkeit wichtiger ist als Vorabkontrollen.
- Kann zusätzliche frei gewählte Ordner in die Sicherung aufnehmen und über
  gespeicherte Metadaten wiederherstellen.
- Kann ein erfolgreich verwendetes USB-Sicherungslaufwerk anschließend sicher
  auswerfen.
- Zeigt Fortschritt und ein verständliches Ergebnis direkt im Fenster an.
- Zeigt für jeden Ordner Dateianzahl und Platzbedarf sowie für die markierte
  Auswahl eine Gesamtsumme an; die Ermittlung läuft im Hintergrund.
- Öffnet vorhandene Protokolle und Sicherungsordner direkt nach der
  Laufwerkswahl und kann die Ergebnisübersicht kopieren.
- Merkt sich die Ordnerauswahl, zeigt einen Verlauf und prüft gesicherte Dateien
  vollständig gegen dateiweise SHA-256-Prüfsummen. Jede Prüfung erhält ein
  dauerhaftes Protokoll mit Ergebnis und Fehlerdetails.
- Kann die Sicherung des aktuellen Computers und Benutzers auf dem ausgewählten
  Laufwerk nach einer Detailanzeige und zweistufigen Sicherheitsabfrage
  vollständig löschen.
- Informiert nach Vorgängen über eine Windows-Benachrichtigung, wenn die App im
  Hintergrund liegt.
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

## Wichtige Einschränkungen

- **Die Sicherungsdaten liegen unverschlüsselt** auf dem Ziellaufwerk. Das
  Laufwerk sollte sicher aufbewahrt oder z. B. mit BitLocker To Go geschützt
  werden.
- **Geöffnete oder gesperrte Dateien können fehlen.** Es wird kein
  Volume-Schattenkopie-Dienst (VSS) verwendet; solche Dateien werden
  übersprungen und im Protokoll vermerkt.
- **Keine Versionierung:** Die Sicherung ist eine fortlaufende
  Sicherheitskopie mit genau einem aktuellen Wiederherstellungsstand, kein
  Archiv mit historischen Dateiversionen.

Details stehen im Abschnitt „Sicherheitsgrenzen" der [Hilfe](docs/help.de.md).

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
3. Zu sichernde Ordner markieren, bei Bedarf **Hinzufügen** nutzen
   oder **Simulation** aktivieren.
4. Optional **Nach Erfolg auswerfen** oder für maximale Geschwindigkeit ohne
   Vorabkontrollen **Schnellmodus (ohne Vorprüfung)** aktivieren.
5. **Sicherung starten** wählen, den Abschlussstatus prüfen und bei Bedarf das
   Protokoll öffnen.

Für eine Rücksicherung den Modus **Wiederherstellen** wählen. Die Anwendung
akzeptiert nur eine Sicherung, deren Computer- und Benutzerinformationen zum
aktuellen Profil passen. Vor Änderungen erscheint eine Konfliktvorschau.

Die ausführliche Anleitung ist im Projekt und in jeder Distribution enthalten:

- [`docs/help.de.md`](docs/help.de.md) – deutsche Quelle der lokalen HTML-Hilfe
- [`docs/help.en.md`](docs/help.en.md) – englische Quelle der lokalen HTML-Hilfe

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
atomar geschriebene Status- und JSON-Ergebnisdateien aus. Gemeinsame
Validierungshelfer liegen in `M24Backup.Shared.ps1` und werden von GUI und
Worker geladen.

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

Das Release-Skript ermittelt die nächste semantische Version, baut die
Artefakte lokal zur Verifikation und erstellt und pusht den Git-Tag. Der
Tag-Push startet den Release-Build-Workflow, der die zu veröffentlichenden
Artefakte aus dem Quellcode baut, bei konfigurierter SignPath-Integration
signiert und das GitHub-Release veröffentlicht. Lokal gebaute Artefakte
werden nie veröffentlicht:

```powershell
.\release.ps1
```

Standardmäßig wird die Patch-Version erhöht (`1.0.0` → `1.0.1`). Für neue
Funktionen oder inkompatible Änderungen wird die Release-Art angegeben:

```powershell
.\release.ps1 -Bump Minor  # 1.0.0 -> 1.1.0
.\release.ps1 -Bump Major  # 1.1.0 -> 2.0.0
```

Den vollständigen Ablauf anzeigen, ohne zu bauen oder GitHub zu verändern:

```powershell
.\release.ps1 -Bump Minor -WhatIf
```

Nur lokal bauen, ohne Tag, Push oder GitHub-Release:

```powershell
.\release.ps1 -Bump Minor -LocalOnly
```

Mit `-Version 1.2.3` kann eine Version ausdrücklich vorgegeben werden. Das
Skript verweigert unsaubere Arbeitsbäume, doppelte Tags, detached HEADs und
Releases von einem Branch, der hinter GitHub liegt. Die fertigen Artefakte
liegen in `dist\`. `build.ps1` bleibt für technische oder rein portable Builds
verfügbar.

## Hinweise zur Veröffentlichung

Die Code-Signierung über die SignPath Foundation wird derzeit eingerichtet.
Bis zum ersten signierten Release kann Windows SmartScreen bei Downloads aus
dem Internet warnen. Downloads sollten anhand von `SHA256SUMS.txt` geprüft
werden.

## Code-Signing-Richtlinie

Free code signing provided by [SignPath.io](https://signpath.io), certificate
by [SignPath Foundation](https://signpath.org).

Rollen im Projekt:

- Committer und Reviewer: [Günther Meusburger (meuse24)](https://github.com/meuse24)
- Freigabe von Signaturen: [Günther Meusburger (meuse24)](https://github.com/meuse24)

Release-Binärdateien werden ausschließlich vom
[Release-Build-Workflow](.github/workflows/release-build.yml) aus dem
Quellcode gebaut und nur aus dieser Pipeline signiert.

Dieses Programm überträgt keine Informationen an andere vernetzte Systeme,
außer der Benutzer oder die installierende bzw. betreibende Person fordert
dies ausdrücklich an. Siehe auch den Abschnitt
[Datenschutz und Sicherheitsmodell](#datenschutz-und-sicherheitsmodell).

## Lizenz

M24 Backup ist Open Source und steht unter der [MIT-Lizenz](LICENSE).
Nutzung, Änderung und Weiterverteilung sind erlaubt; Copyright- und
Lizenzhinweis müssen erhalten bleiben.
