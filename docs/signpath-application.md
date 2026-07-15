# SignPath Foundation – Antrag und Einrichtung

Diese Anleitung beschreibt, wie M24 Backup kostenloses Code-Signing über die
[SignPath Foundation](https://signpath.org) erhält und wie die vorbereitete
GitHub-Actions-Integration danach aktiviert wird.

## 1. Voraussetzungen (Status)

| Anforderung | Status |
| --- | --- |
| OSI-anerkannte Open-Source-Lizenz ohne kommerzielle Doppellizenzierung | Erfüllt (MIT, siehe `LICENSE`) |
| Öffentliches Repository mit aktiver Pflege und vorhandenen Releases | Erfüllt (GitHub, Release v1.0.0) |
| Binärdateien werden nachvollziehbar aus dem Quellcode gebaut | Erfüllt (`.github/workflows/release-build.yml`) |
| Abschnitt „Code signing policy" mit Attribution, Teamrollen und Datenschutzerklärung | Erfüllt (README.md und README.de.md) |
| Multi-Faktor-Authentifizierung für alle Teammitglieder | Erfüllt für GitHub (`meuse24`: Passkey und Authenticator-App); nach der Zusage auch im SignPath-Konto aktivieren |

## 2. Antrag stellen

Der Antrag wird über das Formular auf <https://signpath.org> eingereicht
(Menüpunkt für Open-Source-Projekte / „Apply"). Sinnvolle Angaben:

- **Projektname:** M24 Backup (Bibliothekssicherung)
- **Repository:** <https://github.com/meuse24/m24Backup>
- **Lizenz:** MIT
- **Beschreibung:** Windows-Anwendung (PowerShell 5.1 / Windows Forms /
  Robocopy) zum Sichern und Wiederherstellen persönlicher Benutzerordner auf
  USB-Laufwerke, mit SHA-256-Integritätsprüfung und defensiver Rücksicherung.
- **Zu signierende Artefakte:**
  - `Bibliothekssicherung-Setup-<Version>.exe` – Inno-Setup-Installer
    (Authenticode)
  - `Bibliothekssicherung-Portable-<Version>.zip` – portable Distribution;
    darin die PowerShell-Skripte `Bibliothekssicherung-GUI.ps1`,
    `Bibliothekssicherung.ps1`, `M24Backup.Shared.ps1` (Authenticode für
    Skripte)
- **Build-System:** GitHub Actions, Workflow
  `.github/workflows/release-build.yml` (baut bei Tag-Push `v*` aus dem
  Quellcode und lädt die Artefakte als `dist-unsigned` hoch)

Die Foundation prüft Reputation und Kontrolle über das Projekt; Rückfragen
kommen per E-Mail.

## 3. Nach der Zusage: SignPath-Projekt einrichten

1. SignPath-Konto anlegen (mit aktivierter MFA); die Foundation verknüpft die
   Organisation mit dem Zertifikat.
2. **Projekt** anlegen (z. B. Slug `m24backup`) und das GitHub-Repository als
   Quelle verknüpfen.
3. **Artifact Configuration** anlegen, die dem Inhalt des GitHub-Artefakts
   `dist-unsigned` entspricht: ein ZIP-Container mit dem Setup-EXE
   (Authenticode-Signatur), dem portablen ZIP (darin die drei `.ps1`-Dateien
   per Deep-Signing) und `SHA256SUMS.txt` (unsigniert; wird nach dem Signieren
   vom Workflow neu berechnet).
4. **Signing Policy** anlegen (z. B. Slug `release-signing`) mit dir als
   Approver.
5. **API-Token** für einen CI-Benutzer mit Submitter-Rechten erzeugen.

## 4. GitHub-Repository konfigurieren

Unter *Settings → Secrets and variables → Actions*:

| Typ | Name | Wert |
| --- | --- | --- |
| Secret | `SIGNPATH_API_TOKEN` | API-Token aus Schritt 3.5 |
| Variable | `SIGNPATH_ORGANIZATION_ID` | Organisations-ID aus dem SignPath-Portal |
| Variable | `SIGNPATH_PROJECT_SLUG` | z. B. `m24backup` |
| Variable | `SIGNPATH_SIGNING_POLICY_SLUG` | z. B. `release-signing` |

Der `sign`-Job im Release-Workflow ist über
`if: vars.SIGNPATH_ORGANIZATION_ID != ''` geschaltet: Solange die Variable
fehlt, baut der Workflow nur; sobald sie gesetzt ist, wird nach jedem Build
automatisch eine Signieranfrage eingereicht und das signierte Ergebnis als
Artefakt `dist-signed` (inklusive neu berechneter `SHA256SUMS.txt`)
bereitgestellt.

## 5. Release-Ablauf mit Signierung

1. `release.ps1` wie gewohnt ausführen; es erstellt und pusht den Tag.
2. Der Tag-Push startet `release-build.yml`; nach Freigabe der Signieranfrage
   im SignPath-Portal liegt `dist-signed` als Workflow-Artefakt bereit.
3. Die signierten Dateien herunterladen und die Assets des GitHub-Releases
   damit ersetzen (`gh release upload <tag> <dateien> --clobber`).

Wichtig: Nur die in der CI gebauten und über SignPath signierten Binärdateien
veröffentlichen – lokal gebaute Artefakte dürfen laut den
Foundation-Bedingungen nicht signiert werden. Nach dem ersten signierten
Release den Abschnitt „Hinweise zur Veröffentlichung" in beiden READMEs
aktualisieren.
