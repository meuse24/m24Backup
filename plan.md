# Umsetzungsplan: Intelligente Backup-Erinnerung (Smart Reminders)

## Bewertung: Ja, das Feature ist die Umsetzung wert

**Nutzen:** Die Zielgruppe der App sind ausdrücklich technisch nicht versierte
Anwender mit externem USB-Laufwerk. Das größte verbleibende Risiko ist ein
schlicht vergessenes Backup — genau das adressiert dieses Feature. Es ist
standardmäßig aktiviert, aber jederzeit abschaltbar, benötigt keinen Dienst,
keine Admin-Rechte und nutzt ausschließlich
bereits vorhandene Mechanismen (per-User-Registry-Run-Key,
`%LOCALAPPDATA%\M24Backup\settings.json`, `NotifyIcon`-Benachrichtigung).

**Aufwand:** Gering (grob ein Entwicklungstag inkl. Tests und Doku).
**Risiko:** Gering — rein additiv, keine Änderung am Sicherungs-Workflow.

### Korrekturen gegenüber dem Vorschlag

1. **„Check dauert Millisekunden" stimmt nicht.** Ein
   `powershell.exe`-Start mit Skript braucht 1–3 s. Das ist beim Login
   unsichtbar und unkritisch, aber der Silent-Pfad muss **vor** dem Laden von
   WinForms, Splashscreen und Laufwerksabfragen abzweigen und sich im
   Normalfall (Backup aktuell) beenden, ohne irgendetwas Schweres zu laden.
2. **Es gibt bereits eine Benachrichtigung, aber keinen eigenen Toast-Stack.** Die App
   nutzt `NotifyIcon.ShowBalloonTip` (`Show-CompletionNotification`,
   `Bibliothekssicherung-GUI.ps1:783`) — Windows 10/11 stellt das über die
   native Benachrichtigungsoberfläche dar. Diesen Mechanismus wiederverwenden
   statt BurntToast o. Ä. einzuführen. Der bestehende Completion-Pfad besitzt
   jedoch keinen Klick-Handler; der Silent-Pfad erhält deshalb einen eigenen.
3. **`settings.json` speichert bislang kein Backup-Datum.**
   `KnownBackupDrive.SavedAt` wird zwar bei jedem erfolgreichen Backup
   aktualisiert, ist aber semantisch die Laufwerks-Identität und wird durch
   `Clear-KnownBackupDrive` gelöscht. Ein explizites Feld
   `LastSuccessfulBackup` ist nötig.
4. **Portabilitäts-Falle:** Wird der portable Ordner verschoben/umbenannt,
   zeigt der Run-Key ins Leere. Gegenmaßnahme: Selbstheilung bei jedem
   normalen GUI-Start (Eintrag prüfen und ggf. neu schreiben) plus
   Uninstaller-Bereinigung im Inno-Setup.

---

## Architektur-Entscheidungen

- **Silent-Modus:** Neuer Schalter `-SilentStartup` für
  `Bibliothekssicherung-GUI.ps1` (kein separates Skript — vermeidet Duplikate
  und hält den Run-Key-Befehl einfach).
- **Autostart:** `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run`,
  Wertname `M24Backup`, Befehl:
  `"C:\Windows\System32\wscript.exe" "<Pfad>\Bibliothekssicherung starten.vbs" /SilentStartup`
  (tatsächlich über `[Environment]::SystemDirectory` erzeugt). Ein nicht
  expandierter `%SystemRoot%`-Platzhalter wäre bei einem normalen `REG_SZ`
  nicht zuverlässig.
- **Schwelle:** fest 14 Tage. In `settings.json` als
  `ReminderDays` abgelegt, damit später konfigurierbar, aber ohne UI dafür.
- **Prüf- und Kommandologik** kommt als reine Funktionen in
  `M24Backup.Shared.ps1`, damit sie Pester-testbar ist.

---

## Schritt 1: Shared-Funktionen (`M24Backup.Shared.ps1`)

Neue Funktionen (reine Logik, testbar, keine UI):

```
Get-M24BackupReminderState
  param([string]$LastSuccessfulBackup, [DateTimeOffset]$Now, [int]$ThresholdDays = 14)
  → [pscustomobject]@{ IsDue; NeverBackedUp; DaysSinceBackup }
  - $LastSuccessfulBackup leer/nicht parsbar (ISO-8601 'o') → IsDue = $true,
    NeverBackedUp = $true
  - sonst IsDue = (Now - Last).TotalDays >= ThresholdDays

Get-M24StartupReminderCommand
  param([string]$VbsPath)
  → erwarteter Registry-Befehlsstring (korrekt gequotet, wscript.exe mit
    vollem System32-Pfad)
```

Zusätzlich `Get-M24GuiMutexName` als gemeinsame reine Funktion verwenden,
damit normaler Start und Silent-Pfad garantiert dieselbe SID-basierte
Einzelinstanz-Sperre adressieren.

Registry-Zugriff (dünner Wrapper; echte Zugriffs-/Schreibfehler werden an den
GUI-Aufrufer gemeldet und dort abgefangen, Remove ist bei bereits fehlendem
Wert idempotent):

```
Set-M24StartupReminderRegistration    # schreibt/aktualisiert den Run-Wert
Remove-M24StartupReminderRegistration # löscht den Run-Wert (fehlertolerant)
Get-M24StartupReminderRegistration    # liest aktuellen Wert oder $null
```

## Schritt 2: `settings.json` erweitern

`Get-AppSettings` / `Save-AppSettings` (`Bibliothekssicherung-GUI.ps1:525`)
um drei Felder ergänzen (abwärtskompatibel — fehlende Felder → Defaults):

```json
{
  "Version": 4,
  "KnownBackupDrive": { ... },
  "FolderSelection": { ... },
  "LastSuccessfulBackup": "2026-07-18T20:15:00.0000000+02:00",
  "ReminderEnabled": true,
  "ReminderDays": 14
}
```

`LastSuccessfulBackup` wird im Erfolgspfad gesetzt: im Completion-Handler
neben `Save-KnownBackupDrive` (`Bibliothekssicherung-GUI.ps1:2508`), nur bei
`$script:activeMode -eq 'Backup'` und nicht bei Dry-Run. Ein einzelner
`Save-AppSettings`-Aufruf genügt (erfolgt bereits in `Save-KnownBackupDrive`,
Feld vorher setzen). Das Datum wird notfalls mit einem separaten
`Save-AppSettings` persistiert, falls das Aktualisieren des bekannten
Laufwerks scheitert. Fehler beim Schreiben dürfen den Erfolgsstatus des
Backups nicht überdecken (bestehendes Warn-MessageBox-Muster nutzen).

## Schritt 3: Silent-Startup-Pfad in der GUI

1. Ganz oben in `Bibliothekssicherung-GUI.ps1` einen `param`-Block einfügen
   (muss erstes Statement sein):
   ```powershell
   param([switch]$SilentStartup)
   ```
2. Direkt nach dem Dot-Sourcing von `M24Backup.Shared.ps1` — **vor**
   `Add-Type WinForms`-Nutzung, Splash, Einzelinstanz-MessageBox und
   Laufwerksabfragen — den Silent-Zweig einschieben:
   - Gesamten Zweig in `try/catch` kapseln; im Silent-Modus wird **niemals**
     ein Dialog angezeigt, jeder Fehler → `exit 0`.
   - `settings.json` direkt lesen (nur `ConvertFrom-Json`). Nicht lesbar,
     `ReminderEnabled -ne $true` oder Reminder nicht fällig
     (`Get-M24BackupReminderState`) → `exit 0`.
   - Einzelinstanz-Mutex versuchen: läuft die GUI bereits → `exit 0`
     (ohne die bestehende „Bereits geöffnet"-MessageBox).
   - Fällig → minimal WinForms laden, `NotifyIcon` mit `app.ico` erzeugen,
     Balloon zeigen (lokalisiert über vorhandene `L`-Logik):
     - überfällig: „Ihr letztes Backup ist {0} Tage alt. Bitte schließen Sie
       Ihr Sicherungslaufwerk an." / engl. Pendant
     - noch nie: „Es wurde noch keine Sicherung erstellt. …"
   - `BalloonTipClicked` → Message-Loop beenden, NotifyIcon entsorgen und
     Mutex freigeben; erst danach GUI normal starten
     (`wscript.exe` + VBS ohne Argument) → `exit 0`.
   - `BalloonTipClosed`/Timeout (~30 s Message-Loop, z. B. `ApplicationContext`
     mit Timer) → `NotifyIcon` disposen, `exit 0`.

## Schritt 4: VBS-Starter erweitert Argumente durchreichen

`Bibliothekssicherung starten.vbs` reicht bislang keine Argumente durch.
Schleife über `WScript.Arguments` ergänzen; ausschließlich der bekannte
Schalter `/SilentStartup` (alternativ `-SilentStartup`) wird als
`-SilentStartup` an `powershell.exe -File` angehängt. Unbekannte Argumente
werden ignoriert, damit der Launcher keine freie Argument-Injection eröffnet.
Ohne Argumente bleibt das Verhalten unverändert.

## Schritt 5: Checkbox in der GUI

- Kurze Checkbox „Erinnern" / „Reminder"; der Tooltip erklärt Windows-Start
  und 14-Tage-Schwelle.
- Platzierung gemeinsam mit den vier Vorgangsoptionen in der bestehenden
  Optionszeile; Abstände der fünf kurzen Beschriftungen entsprechend anpassen.
- Zustand beim Start aus `ReminderEnabled` laden. Anders als die
  Vorgangs-Optionen ist dies eine **App-Einstellung**: `CheckedChanged`
  schreibt sofort `ReminderEnabled` + Registry:
  - Haken gesetzt → `Set-M24StartupReminderRegistration` + `Save-AppSettings`
  - Haken entfernt → `Remove-M24StartupReminderRegistration` + `Save-AppSettings`
  - Registry-Fehler → Warnhinweis, Checkbox zurücksetzen.
- ToolTip erklärt, dass kein Hintergrunddienst läuft und die Erinnerung nur
  bei überfälligem Backup erscheint.
- **Selbstheilung:** Beim normalen GUI-Start, wenn `ReminderEnabled` und der
  vorhandene Run-Wert nicht `Get-M24StartupReminderCommand` entspricht
  (z. B. Ordner verschoben) → Eintrag still neu schreiben.

## Schritt 6: Installer-Bereinigung (`installer/Bibliothekssicherung.iss`)

```ini
[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
  ValueName: "M24Backup"; Flags: uninsdeletevalue dontcreatekey
```

`dontcreatekey` + `uninsdeletevalue`: Setup legt nichts an, der Uninstaller
entfernt den von der GUI geschriebenen Wert.

## Schritt 7: Tests (`tests/M24Backup.Shared.Tests.ps1`)

- `Get-M24BackupReminderState`: nie gesichert, ungültiges Datum, genau an der
  14-Tage-Grenze (>= fällig), knapp darunter nicht fällig, Zeitzonen-Roundtrip
  über ISO-8601 `'o'`.
- `Get-M24StartupReminderCommand`: Quoting bei Pfaden mit Leerzeichen,
  `/SilentStartup`-Argument enthalten.
- Registry-Wrapper: Set/Get/Remove-Roundtrip ausschließlich gegen einen
  testbezogenen, zufälligen Unterpfad unter `HKCU:\Software\M24Backup\Tests`
  (idempotent, hinterlässt keinen Eintrag). Der produktive Run-Wert wird von
  Tests niemals verändert; Remove ohne vorhandenen Wert wirft nicht.

## Schritt 8: Doku

- `docs/help.de.md` / `docs/help.en.md`: neuer Abschnitt zur Erinnerung
  (was sie tut, dass kein Dienst läuft, wie man sie abschaltet — auch über
  Task-Manager → Autostart).
- `CHANGELOG.md`: Eintrag unter „Unreleased"/nächster Version.
- `README.md` / `README.de.md`: Feature-Liste ergänzen.

---

## Bekannte Grenzen (bewusst akzeptiert)

- **Fokus-Assist/Benachrichtigungen deaktiviert:** Windows unterdrückt dann
  den Balloon — kein Workaround nötig; die Funktion bleibt abschaltbar.
- **Windows-Autostart-Verwaltung:** Der Nutzer kann den Eintrag im
  Task-Manager deaktivieren (`StartupApproved`-Key); die App versucht das
  nicht zu erkennen oder zu übersteuern.
- **Portabler Betrieb auf Wechseldatenträger an fremden PCs:** Der Run-Key
  gilt nur auf dem PC/Benutzerkonto, auf dem der Haken gesetzt wurde —
  konsistent mit `settings.json`, das ebenfalls lokal liegt.
- **Backup auf anderem Weg** (direkt per `Bibliothekssicherung.ps1` in der
  Konsole) aktualisiert `LastSuccessfulBackup` nicht — die Erinnerung ist
  dann konservativ (meldet sich ggf. obwohl gesichert wurde). Für die
  GUI-Zielgruppe irrelevant; bei Bedarf später im Worker nachrüstbar.

## Reihenfolge & Verifikation

1. Schritt 1 + 7 (Logik + Tests, `Invoke-Pester`)
2. Schritt 2 + 3 + 4 (Silent-Pfad end-to-end: manuell
   `wscript.exe ".\Bibliothekssicherung starten.vbs" /SilentStartup` mit
   präpariertem `LastSuccessfulBackup` — alt/frisch/fehlend)
3. Schritt 5 (Checkbox, Registry-Eintrag mit `reg query` prüfen, Haken
   entfernen → Eintrag weg)
4. Schritt 6 + 8 (Installer-Build + Doku)
5. Abschluss: kompletter Zyklus — Haken setzen, `LastSuccessfulBackup` auf
   vor 20 Tagen setzen, ab-/anmelden → Toast erscheint, Klick öffnet GUI,
   Backup ausführen, ab-/anmelden → kein Toast.
