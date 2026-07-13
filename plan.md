# Implementierungsplan: Backup-Komfortfunktionen

## Ziel

Drei Funktionen sollen in die bestehende Windows-Forms/PowerShell-Anwendung integriert werden:

1. Dry-Run-Modus fuer Backups per Robocopy `/L`
2. Frei waehlbare Zusatzordner per `FolderBrowserDialog`
3. Optionales sicheres Auswerfen des Sicherungslaufwerks nach erfolgreichem Backup

Die Umsetzung betrifft vor allem `Bibliothekssicherung-GUI.ps1` fuer UI, Prozessargumente und Ergebnisbehandlung sowie `Bibliothekssicherung.ps1` fuer Worker-Parameter, Ordnerdefinitionen und Robocopy-Aufruf.

## Vorabentscheidungen

- Dry-Run gilt nur fuer `Mode = Backup`, nicht fuer Restore.
- Ein Dry-Run erzeugt Logdateien, darf aber keine Metadaten als erfolgreiche echte Sicherung speichern und soll das bekannte Sicherungslaufwerk nicht neu merken.
- Eigene Ordner werden zunaechst fuer die aktuelle Sitzung hinzugefuegt. Persistenz in `settings.json` ist optional und kann spaeter separat ergänzt werden.
- Eigene Ordner werden im Backup-Ziel unter einem stabilen, eindeutigen Namen abgelegt, damit Namenskollisionen mit Standardordnern oder weiteren Zusatzordnern vermieden werden.
- Auto-Auswurf wird nur nach erfolgreichem echtem Backup versucht, nicht nach Restore und nicht nach Dry-Run.

## 0. Voraussetzung: UI-Layout und Fensterhoehe

Das Fenster wurde erst kuerzlich bewusst fixiert (`Bibliothekssicherung-GUI.ps1:265-274`: `ClientSize = 720x734`, `FormBorderStyle = FixedSingle`, `MaximizeBox = $false`, `MinimumSize = 736x600`). Alle Controls sind auf feste Pixelkoordinaten gesetzt, und zwischen den vorhandenen Flaechen ist praktisch kein Platz mehr frei:

- `targetSurface` 100-218, `folderSurface` 226-456 (Luecke dazwischen: 8 px)
- `folderSurface` 226-456, `activitySurface` 466-622 (Luecke: 10 px)
- `footerSurface` 632-734 ist bereits vollstaendig mit vier Buttons in einer Reihe belegt (30-690 horizontal)

Fuer die drei neuen Funktionen muss deshalb vor der eigentlichen Umsetzung ein Platz geschaffen werden:

- **Zusatzordner-Button**: passt ohne Fensteraenderung neben `allButton`/`noneButton` (`Location 384,260` bzw. `384,297`), z. B. bei `384,334` mit Breite ~140-180 px – dort ist innerhalb von `folderSurface` bis y=456 noch Platz.
- **Dry-Run- und Auto-Auswurf-Checkbox**: dafuer gibt es keinen freien Platz. Empfehlung: eine neue, kompakte `optionsSurface`-Flaeche zwischen `folderSurface` und `activitySurface` einfuegen (z. B. bei y=466, Hoehe ~40 px, beide Checkboxen nebeneinander oder als kompakte Zeile). Anschliessend `activitySurface` (bisher y=466) und `footerSurface` (bisher y=632) um denselben Betrag nach unten verschieben und `$form.ClientSize.Height` sowie `$form.MinimumSize.Height` um denselben Betrag erhoehen (z. B. je +48 px). Die automatische Verkleinerung bei kleinen Bildschirmen (`$form.Height`-Anpassung ans `WorkingArea` am Skriptende) bleibt davon unberuehrt, weil sie bereits nach der finalen Hoehe rechnet.
- Alternative, falls eine Fensteraenderung vermieden werden soll: Checkboxen sehr kompakt in die bestehende `targetSurface`- oder `activitySurface`-Zeile integrieren (z. B. rechts neben `driveInfoLabel`/`healthPanel`). Das ist enger und sollte nur gewaehlt werden, wenn eine Vergroesserung explizit unerwuenscht ist.

Diese Entscheidung sollte vor Beginn der Detailarbeiten getroffen werden, da sie mehrere feste Y-Koordinaten im Skript verkettet.

### Gemeinsame Codestellen fuer alle drei Funktionen

Neue Controls (Dry-Run-Checkbox, Zusatzordner-Button, Auto-Auswurf-Checkbox) muessen an zwei bereits bestehenden Stellen konsistent ein- und ausgeblendet werden, sonst bleiben sie waehrend eines laufenden Vorgangs bedienbar:
- Sperren beim Start: `startButton.Add_Click`, Block ab `Bibliothekssicherung-GUI.ps1:876` (`$driveCombo.Enabled = $false` usw.) sowie der Fehlerpfad ab Zeile 909.
- Freigeben nach Abschluss: Timer-Tick-Handler, Block ab Zeile 1036.

Ebenso muss die neue temporaere `SelectedFoldersFile`-Datei an beiden Stellen behandelt werden, an denen bereits `statusFile`/`resultFile`/`cancelFile`/`previewFile`/`approvalFile` aufgeraeumt werden:
- Fehlerpfad direkt nach dem fehlgeschlagenen Prozessstart (Zeile 924).
- Regulaerer Abschluss im Timer-Tick (Zeile 1119-1135).

## 1. Dry-Run-Modus

### UI

- In `Bibliothekssicherung-GUI.ps1` eine Checkbox im Optionsbereich oder nahe dem Startbutton ergaenzen:
  - Deutsch: `Nur simulieren (Dry-Run)`
  - Englisch: `Simulate only (dry run)`
- Checkbox nur im Backup-Modus anzeigen bzw. aktivieren.
- Beim Wechsel auf Restore deaktivieren und abwaehlen.
- Waehrend eines laufenden Vorgangs zusammen mit den anderen Eingaben sperren und danach wieder freigeben.
- Start- und Status-Texte im Dry-Run unterscheidbar machen, z. B. `Simulation wird gestartet ...`.

### Worker-Parameter

- In `Bibliothekssicherung.ps1` einen Switch ergaenzen:
  - `[switch]$DryRun`
- Validieren:
  - Wenn `$DryRun` und `$Mode -ne 'Backup'`, abbrechen oder ignorieren. Besser: mit klarer Meldung abbrechen, weil Restore-Simulation bereits ueber die vorhandene Konfliktvorschau abgedeckt ist.

### Prozessargumente

- In `Bibliothekssicherung-GUI.ps1` beim Zusammenbau von `$arguments` (aktuell ein einzelner `-f`-Formatstring, `Bibliothekssicherung-GUI.ps1:895`) den Schalter `-DryRun` nur anhaengen, wenn die Checkbox aktiv ist und Backup ausgewaehlt ist.
- Wichtige technische Einschraenkung: Die App laeuft unter Windows PowerShell 5.1 / .NET Framework (siehe Kommentar in `build.ps1:122`), nicht unter PowerShell 7/.NET. `System.Diagnostics.ProcessStartInfo.ArgumentList` existiert dort nicht; `StartInfo.Arguments` bleibt ein einzelner String. Ein "Array" kann also nur intern zur Konstruktion dienen und muss am Ende wieder zu einem korrekt gequoteten String zusammengefuegt werden (z. B. ueber eine kleine Hilfsfunktion `ConvertTo-QuotedArgument`, die jedes Element in `"..."` einschliesst). Windows-Pfade duerfen ohnehin kein `"` enthalten, wodurch das Escaping einfach bleibt; die bestehende Praxis, jeden Wert einzeln in Anfuehrungszeichen zu setzen, ist bereits sicher genug fuer Pfade mit Leerzeichen.
- Die eigentliche Antwort auf "quoting-anfaellige Zusatzordner" ist ohnehin die JSON-Datei aus Abschnitt 2 (`-SelectedFoldersFile`), nicht die Kommandozeile – dorthin gehoeren beliebige Pfade, nicht in den Argumentstring.

### Robocopy

- In `Bibliothekssicherung.ps1` beim Aufbau von `$robocopyArgs` (bereits ein Array, `Bibliothekssicherung.ps1:656-673`) fuer Backup und `$DryRun` den Schalter `"/L"` anhaengen.
- Wichtig: Die aktuellen Robocopy-Argumente enthalten `/NFL` (No File List) und `/NDL` (No Directory List, `Bibliothekssicherung.ps1:668-669`). Mit `/L` kombiniert wuerde das Log dann nur eine Zusammenfassung ohne Dateinamen zeigen – der eigentliche Zweck einer Simulation (sehen, was kopiert wuerde) ginge verloren. Bei `$DryRun` sollten `/NFL` und `/NDL` deshalb weggelassen werden, damit das Log die betroffenen Dateien/Ordner tatsaechlich auflistet.
- Im Logkopf explizit festhalten:
  - `Dry-Run: Ja/Nein`
  - bei Dry-Run: Hinweis, dass keine Dateien kopiert wurden.
- Ergebnis-JSON um `DryRun = $DryRun.IsPresent` ergaenzen.
- Ergebnis- und GUI-Texte anpassen:
  - Deutsch: `Simulation erfolgreich abgeschlossen`
  - Englisch: `Simulation completed successfully`

### Metadaten und Health

- Aktuell wird `_Sicherungsinfo.txt` vor dem Robocopy-Lauf geschrieben und am Ende als erfolgreich markiert. Fuer Dry-Run sollte keine echte Sicherung als erfolgreich markiert werden.
- Umsetzung:
  - Logordner darf angelegt werden.
  - `_Sicherungsinfo.txt` im Dry-Run nicht anlegen oder nicht veraendern.
  - `Save-KnownBackupDrive` in der GUI bei Dry-Run nicht ausfuehren (Bedingung ergaenzen bei `Bibliothekssicherung-GUI.ps1:1085`, wo aktuell nur `$script:activeMode -eq 'Backup'` geprueft wird).
  - `Update-BackupHealth` kann nach einem Dry-Run unveraendert aufgerufen werden: Solange `_Sicherungsinfo.txt` im Dry-Run nicht angefasst wird, liest die Funktion ohnehin nur den Stand der letzten echten Sicherung neu ein. Es ist also keine zusaetzliche Sonderbehandlung noetig, wenn der erste Punkt korrekt umgesetzt ist.

## 2. Eigene Ordner Hinzufuegen

### Datenmodell in der GUI

- Statt nur `CanonicalName` und `DisplayName` sollte jedes Listenelement folgende Felder tragen:
  - `Name`: stabiler Zielordnername
  - `DisplayName`: Anzeige in der Liste
  - `Path`: Quellpfad, bei Standardbibliotheken optional oder gesetzt
  - `IsCustom`: Boolean
- Fuer Standardbibliotheken kann `Path` aus derselben Logik wie `Get-LibraryNames` kommen oder leer bleiben, solange der Worker sie anhand des Namens aufloesen kann.
- Fuer Zusatzordner wird `Path` immer gesetzt.

### Kritisch: Persistenz der Zusatzordner ueber `Update-LibraryList` hinweg

`Update-LibraryList` (`Bibliothekssicherung-GUI.ps1:699-732`) leert `$libraryList.Items` bei **jedem** Aufruf vollstaendig und baut die Liste ausschliesslich aus `Get-LibraryNames` neu auf. Aufgerufen wird die Funktion bei jedem Laufwerkswechsel (`driveCombo.Add_SelectedIndexChanged`, Zeile 788-805) und bei jedem Wechsel zwischen Sichern/Wiederherstellen (Zeilen 809-814). Ohne Gegenmassnahme wuerden vom Benutzer hinzugefuegte Zusatzordner beim naechsten Laufwerks- oder Moduswechsel kommentarlos verschwinden – ein leicht ausloesbarer Datenverlust mitten in der Auswahl.

Notwendige Aenderung:
- Zusatzordner in einer eigenen, von `Update-LibraryList` unabhaengigen Liste halten, z. B. `$script:customFolders` (Array der oben definierten Objekte inkl. Checked-Zustand).
- `Update-LibraryList` so anpassen, dass sie im Backup-Modus nach dem Befuellen mit den Standardordnern zusaetzlich die Eintraege aus `$script:customFolders` anhaengt (inkl. ihres zuletzt bekannten Checked-Zustands) und im Restore-Modus die aus dem Sicherungsziel gelesenen Zusatzordner (siehe unten, `_Ordner.json`) anzeigt.
- Der `Add_ItemCheck`-Handler (Zeile 744-750) oder das Auslesen beim Start (`startButton.Add_Click`, Zeile 851-853) muss den Checked-Zustand von Zusatzordnern nach `$script:customFolders` zurueckschreiben, damit er einen Rebuild uebersteht.
- Die Objekterzeugung an den zwei bestehenden Stellen (Zeilen 497-501 fuer die Erstbefuellung und 726-730 innerhalb von `Update-LibraryList`) muss auf das neue Feldschema (`Name` statt `CanonicalName`) umgestellt werden; ebenso die Auswertung in `startButton.Add_Click` (Zeile 851-853, aktuell `$_.CanonicalName`).

### UI

- Unter `allButton`/`noneButton` einen weiteren Button einfuegen, z. B. bei `Location 384,334` (in `folderSurface` ist bis y=456 noch Platz frei, siehe Abschnitt 0):
  - Deutsch: `Weiteren Ordner hinzufuegen...`
  - Englisch: `Add folder...`
- Button nur im Backup-Modus aktivieren. Im Restore-Modus ausblenden oder deaktivieren, weil Restore nur aus vorhandenen Backup-Ordnern erfolgen sollte.
- Eine Moeglichkeit zum Entfernen eines versehentlich hinzugefuegten Zusatzordners ergaenzen (z. B. Entf-Taste auf dem markierten Zusatzordner-Eintrag oder ein kleines Kontextmenü), da Abwaehlen den Eintrag nur aus der Sicherung ausschliesst, ihn aber dauerhaft in der Liste belaesst.
- Bei Klick:
  - `System.Windows.Forms.FolderBrowserDialog` oeffnen.
  - `Description` lokalisieren.
  - `ShowNewFolderButton = $false`, da ein existierender Quellordner ausgewaehlt werden soll.
  - Ausgewaehlten Pfad normalisieren.
  - Duplikate gegen bestehende Standard- und Zusatzordner verhindern.
  - Den Benutzerprofilordner selbst weiterhin ablehnen, analog zur Worker-Logik.
  - Ziel innerhalb Quelle bzw. Quelle innerhalb Ziel spaeter weiterhin vom Worker pruefen lassen.

### Zielnamen fuer Zusatzordner

- Eigene Ordner brauchen einen eindeutigen Backup-Zielnamen. Vorschlag:
  - Basis: letzter Pfadbestandteil, z. B. `Projekte`
  - Kollisionen: `Projekte`, `Projekte (2)`, `Projekte (3)`
  - Alternativ robuster: Prefix `Benutzerordner - Projekte`
- Der gewaehlte Name wird als `Name` an den Worker uebergeben und im Ziel unter `$destination\<Name>` verwendet.
- Zusaetzlich zu Kollisionen mit Standard- und weiteren Zusatzordnern muessen auch die vom Tool selbst genutzten Namen reserviert bleiben, da sie nicht Teil von `$folderDefinitions` sind und deshalb von der bestehenden Kollisionspruefung nicht erfasst wuerden: `_logs`, `_Sicherungsinfo.txt`, ein kuenftiges `_Ordner.json` sowie generell jeder mit `_` beginnende Name. Diese Pruefung gehoert sowohl in die GUI (beim Hinzufuegen) als auch in den Worker (`Bibliothekssicherung.ps1`, siehe unten) als zweite Absicherung.

### Uebergabe an den Worker

- Die aktuelle Pipe-Liste `-SelectedFolders "Desktop|Dokumente"` reicht fuer Pfade nicht aus.
- Neuer Parameter in `Bibliothekssicherung.ps1`: `[string]$SelectedFoldersFile` (Pfad zu einer temporaeren JSON-Datei, siehe unten – kein Roh-JSON als Kommandozeilenargument, damit Pfade und Sonderzeichen nicht ueber die Kommandozeile escaped werden muessen).
  - GUI erzeugt `$script:selectedFoldersFile`
  - Inhalt: Array aus Objekten `{ Name, Path, IsCustom }`
  - Worker-Parameter: `-SelectedFoldersFile "<tempfile>"`
  - Cleanup zusammen mit Status-, Result-, Preview- und Approval-Dateien.
- Rueckwaertskompatibilitaet:
  - `-SelectedFolders` fuer CLI/alte Aufrufe behalten.
  - Wenn `-SelectedFoldersFile` gesetzt ist, hat es Vorrang.

### Worker-Ordnerdefinitionen

- In `Bibliothekssicherung.ps1` die Standardordner weiterhin in `$folderDefinitions` (Zeile 399-412) aufbauen.
- Danach Zusatzordner aus `SelectedFoldersFile` hinzufuegen:
  - Nur bei Backup.
  - Pfad muss existierender Container sein.
  - Pfad darf nicht direkt dem Benutzerprofil entsprechen.
  - Name muss gueltig als Ordnername sein, keine ungueltigen Dateinamenszeichen.
  - Name darf keinem reservierten internen Namen entsprechen (siehe oben: `_logs`, `_Sicherungsinfo.txt`, `_Ordner.json`, `_`-Praefix).
  - Namenskollisionen mit vorhandenen Definitionen verhindern oder eindeutig aufloesen.
  - Zusaetzlich pruefen, ob der gewaehlte Pfad identisch mit, uebergeordnet zu oder untergeordnet von einem bereits ausgewaehlten Ordner (Standard oder Zusatz) ist. Das verursacht keinen Fehler in Robocopy, fuehrt aber zu redundantem Kopieren und verwirrenden Ergebnissen; im Zweifel ablehnen oder den Unterordner automatisch abwaehlen.
- Die bestehende Pruefung "Ziel liegt innerhalb der Quelle" (Zeile 452-460) laeuft bereits ueber alle `$backupFolders`, also automatisch auch ueber Zusatzordner – hier ist keine Aenderung noetig.

### Restore-Unterstuetzung fuer Zusatzordner (Teil dieses Plans, nicht "spaeter")

Ohne gespeicherten Originalpfad kann ein Zusatzordner beim Restore nicht wiederhergestellt werden, weil `$folderDefinitions` im Restore-Zweig (Zeile 433-438) nur die neun fest bekannten Namen durchsucht. Damit die Funktion "Zusatzordner" nicht nur sichern, aber nie wiederherstellen kann, gehoert die Metadatendatei und ihr Auslesen in den Umfang dieses Plans:

- Der Worker schreibt im echten (nicht Dry-Run-) Backup pro Zusatzordner einen Eintrag in eine strukturierte Metadatei, z. B. `_Ordner.json` im Sicherungsziel:
  - `Name` (Zielordnername)
  - `OriginalPath`
  - `BackedUpAt`
- Im Restore-Zweig (`Mode -eq 'Restore'`, nach `Assert-BackupIdentity`) liest der Worker `_Ordner.json`, falls vorhanden, und ergaenzt `$folderDefinitions` um Eintraege `{ Name = ...; Path = OriginalPath }`, bevor die bestehende Existenzpruefung (`Test-Path $restoreSource`) laeuft. Damit fuegen sich Zusatzordner ohne Sonderfall in die vorhandene Restore-Logik ein.
- Die GUI muss `Update-LibraryList` im Restore-Zweig (Zeile 702-713) ebenfalls erweitern: Zusaetzlich zu `Get-LibraryNames -IncludeMissing` auch `_Ordner.json` aus `$backupRoot` lesen (falls vorhanden) und deren Eintraege als Zusatzordner-Items anzeigen, damit sie ueberhaupt anwaehlbar sind.
- Fehlt `_Ordner.json` (z. B. Sicherung vor diesem Update erstellt), bleibt das Verhalten wie bisher: Zusatzordner sind beim Restore schlicht nicht sichtbar, ohne Fehler.

## 3. Laufwerk Nach Erfolg Sicher Auswerfen

### UI

- Checkbox in `Bibliothekssicherung-GUI.ps1` ergaenzen:
  - Deutsch: `Laufwerk nach Erfolg sicher auswerfen`
  - Englisch: `Safely eject drive after success`
- Nur im Backup-Modus aktivieren.
- Bei internem Laufwerk (`DriveType = 3`) die Checkbox fest deaktivieren und abwaehlen (nicht nur warnen), analog zur bestehenden Warnung fuer interne Sicherungsziele (`Bibliothekssicherung-GUI.ps1:841-849`) – ein Warndialog fuer eine Aktion, die ohnehin sinnlos ist, verwirrt nur.
- Waehrend des Vorgangs sperren und danach wieder freigeben.

### Auswurfzeitpunkt

- In der GUI nach Prozessende ausfuehren, nicht im Worker.
- Bedingungen:
  - Exit-Code `0`
  - Ergebnis `Success = true`
  - `result.Mode = 'Backup'`
  - kein Dry-Run
  - Checkbox aktiv
  - aktives Laufwerk vorhanden und bevorzugt `DriveType = 2`

### Auswurffunktion

- Funktion `Dismount-BackupDriveSafely` in `Bibliothekssicherung-GUI.ps1` anlegen.
- Primaerer Ansatz per Shell-COM (fuehrt einen echten Geraete-Auswurf durch, nicht nur ein Aushaengen des Dateisystems):
  - `$shell = New-Object -ComObject Shell.Application`
  - `$shell.Namespace(17).ParseName("$Drive\")` liefert das Laufwerk-Item (Namespace 17 = Arbeitsplatz; der kanonische Verb-Name `Eject` funktioniert sprachunabhaengig, unabhaengig von der UI-Sprache).
  - `.InvokeVerb('Eject')` aufrufen.
  - Anschliessend das COM-Objekt explizit freigeben (`[System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)`), da COM-RCWs von `Shell.Application` sonst bis zur naechsten GC im Prozess haengen bleiben.
- Fallback, falls der Shell-Verb-Aufruf fehlschlaegt oder das Item nicht gefunden wird:
  - WMI/CIM `Win32_Volume` mit `DriveLetter`, `Dismount($false, $false)`.
  - Wichtiger Unterschied zum primaeren Ansatz: `Dismount` haengt nur das Dateisystem aus, ohne das Geraet elektrisch abzumelden/anzuhalten. Das ist meist ausreichend, damit das Laufwerk gefahrlos gezogen werden kann, aber kein vollwertiger "Sicher entfernen"-Vorgang. Die Erfolgsmeldung sollte das widerspiegeln (z. B. "Laufwerk wurde ausgehaengt" statt "Laufwerk wurde ausgeworfen"), falls nur dieser Fallback gegriffen hat.
- Fehler abfangen und nur als Warnung anzeigen:
  - Backup bleibt erfolgreich, auch wenn Auswurf fehlschlaegt.
  - Status/Resultbox ergaenzen: `Sicherung erfolgreich, Auswurf konnte nicht abgeschlossen werden.`

### UX

- Nach erfolgreichem Auswurf:
  - Status: `Sicherung erfolgreich abgeschlossen. Laufwerk kann entfernt werden.`
  - Drive-Liste aktualisieren, weil das Laufwerk danach verschwunden sein kann.
- Wenn Auswurf fehlschlaegt:
  - MessageBox mit kurzer Ursache und Hinweis, das Laufwerk manuell auszuwerfen.

## Tests und Pruefung

### Manuelle Tests

1. Backup normal starten und bestaetigen, dass kein Dry-Run-Schalter im Log steht.
2. Dry-Run aktivieren:
   - Robocopy-Log enthaelt bei aktiviertem `/L` weiterhin Datei-/Ordnernamen (also `/NFL`/`/NDL` tatsaechlich entfernt).
   - Es werden keine Nutzdateien auf das Ziel geschrieben.
   - `_Sicherungsinfo.txt` wird nicht als erfolgreiche Sicherung aktualisiert.
   - GUI zeigt Simulation statt Sicherung.
3. Zusatzordner hinzufuegen:
   - Ordner erscheint angehakt in der Liste.
   - **Laufwerk wechseln oder zwischen Sichern/Wiederherstellen umschalten und pruefen, dass der Zusatzordner weiterhin in der Liste steht** (Regressionstest fuer den `Update-LibraryList`-Rebuild).
   - Backup kopiert ihn unter eindeutigem Zielnamen.
   - Duplikat-Auswahl wird verhindert, ebenso ein Name, der einem reservierten internen Namen entspricht (`_logs` o. ae.).
   - Pfade mit Leerzeichen funktionieren.
   - Ein bereits ausgewaehlter Zusatzordner laesst sich wieder aus der Liste entfernen.
4. Restore nach Backup mit Zusatzordner:
   - Standardordner bleiben unveraendert funktionsfaehig.
   - Zusatzordner aus `_Ordner.json` erscheinen im Restore-Modus in der Liste und werden mit Originalpfad wiederhergestellt.
   - Eine aeltere Sicherung ohne `_Ordner.json` funktioniert weiterhin fehlerfrei fuer die Standardordner.
5. Auto-Auswurf:
   - Bei erfolgreichem Backup auf USB-Stick wird Auswurf versucht.
   - Bei Dry-Run wird nicht ausgeworfen.
   - Bei Restore wird nicht ausgeworfen.
   - Bei Robocopy-Fehlercode ab 8 wird nicht ausgeworfen.
   - Checkbox ist bei internem Ziellaufwerk (`DriveType = 3`) deaktiviert.
6. Layout: Fenster auf einem kleinen Bildschirm (z. B. 1366x768) starten und pruefen, dass alle neuen Controls sichtbar bzw. ueber die Bildlaufleiste erreichbar sind und sich nicht ueberlappen.

### Statische Pruefung

- PowerShell-Parserlauf fuer beide Skripte:
  - `[System.Management.Automation.PSParser]::Tokenize((Get-Content .\Bibliothekssicherung-GUI.ps1 -Raw), [ref]$null)`
  - `[System.Management.Automation.PSParser]::Tokenize((Get-Content .\Bibliothekssicherung.ps1 -Raw), [ref]$null)`
- Falls lokal moeglich: GUI starten und die Controls in Backup/Restore-Modus pruefen.

## Empfohlene Umsetzungsreihenfolge

1. Fensterlayout klaeren (Abschnitt 0): neue Flaeche/Zeile fuer die Checkboxen einplanen, Fensterhoehe und abhaengige Y-Koordinaten anpassen.
2. Datenmodell fuer Ordnerlistenelemente auf `Name/DisplayName/Path/IsCustom` umstellen und `$script:customFolders` als persistente Zusatzordner-Liste einfuehren; `Update-LibraryList` entsprechend erweitern und mit einem Laufwerks-/Moduswechsel-Test absichern, bevor weitere Funktionen darauf aufbauen.
3. Zusatzordner-Button, `FolderBrowserDialog`, Zielnamensvergabe (inkl. reservierter Namen) und Entfernen-Moeglichkeit in der GUI einfuehren.
4. Temporaere JSON-Datei (`SelectedFoldersFile`) fuer die Ordnerauswahl einfuehren und in die bestehenden Sperr-/Cleanup-Stellen eintragen (siehe "Gemeinsame Codestellen").
5. Worker so erweitern, dass er `SelectedFoldersFile` lesen kann, alte `SelectedFolders`-Logik aber beibehaelt; Validierung inkl. verschachtelter/reservierter Pfade ergaenzen.
6. `_Ordner.json`-Metadatei beim echten Backup schreiben und im Restore-Zweig (Worker und GUI) lesen, damit Zusatzordner auch wiederhergestellt werden koennen.
7. Dry-Run-Checkbox, Worker-Parameter und Robocopy `/L` implementieren (inkl. Entfernen von `/NFL`/`/NDL` im Dry-Run).
8. Dry-Run-Metadaten- und Ergebnislogik absichern.
9. Auto-Auswurf-Checkbox und `Dismount-BackupDriveSafely` (COM-Eject primaer, WMI-Dismount als Fallback) implementieren.
10. Hilfe/README/Changelog aktualisieren.
11. Parserpruefung und manuelle Tests durchfuehren (inkl. der neuen Regressionstests aus dem Testabschnitt).

## Fortschritt

- [x] Plan geprueft und offene Architekturfragen entschieden:
  - Optionszeile wird durch eine moderate Fensterhoehen-Erweiterung umgesetzt.
  - Zusatzordner werden ueber eine temporaere JSON-Datei an den Worker uebergeben.
  - Zusatzordner-Restore gehoert zum Umfang und nutzt `_Ordner.json`.
  - Dry-Run darf `_Sicherungsinfo.txt`, `_Ordner.json` und bekannte-Laufwerk-Einstellungen nicht veraendern.
  - Auto-Auswurf wird nur nach echtem erfolgreichem Backup auf Wechseldatentraegern versucht.
- [x] Feature 1: Eigene Ordner hinzufuegen und wiederherstellen.
  - GUI nutzt ein einheitliches Ordner-Item-Modell (`Name`, `DisplayName`, `Path`, `IsCustom`, `Checked`).
  - Zusatzordner koennen per `FolderBrowserDialog` hinzugefuegt und wieder entfernt werden.
  - Zusatzordner bleiben bei Laufwerks- und Moduswechsel erhalten.
  - Ausgewaehlte Ordner werden als temporaere JSON-Datei an den Worker uebergeben.
  - Worker liest `SelectedFoldersFile`, validiert Zusatzordner und schreibt/liest `_Ordner.json` fuer Restore.
- [x] Feature 2: Dry-Run-Modus.
  - GUI bietet `Nur simulieren (Dry-Run)` nur im Backup-Modus an.
  - Worker unterstuetzt `-DryRun` und nutzt Robocopy `/L`.
  - Im Dry-Run werden `/NFL` und `/NDL` weggelassen, damit das Log die geplanten Dateien/Ordner zeigt.
  - Dry-Run schreibt keine echten Sicherungsmetadaten und merkt kein neues Sicherungslaufwerk.
- [x] Feature 3: Laufwerk nach Erfolg sicher auswerfen.
  - GUI bietet `Laufwerk nach Erfolg sicher auswerfen` nur fuer echte Backup-Laeufe auf Wechseldatentraegern an.
  - Erfolgszweig ruft `Dismount-BackupDriveSafely` nur bei echtem erfolgreichem Backup auf.
  - Primaerer Weg ist Shell-COM `Eject`, Fallback ist WMI/CIM `Win32_Volume.Dismount`.
  - Fehlschlag beim Auswurf wird als Warnung behandelt, ohne das erfolgreiche Backup nachtraeglich als Fehler zu markieren.
- [x] Dokumentation und Validierung abgeschlossen.
  - README, deutsche README, beide Hilfedateien und Changelog wurden aktualisiert.
  - PowerShell-Parserpruefung fuer GUI und Worker ist erfolgreich.
  - Dry-Run-Smoke-Test mit temporaerem SUBST-Laufwerk erfolgreich: keine Nutzdatei kopiert, Auswahlfilter korrekt.
  - Zusatzordner-Backup-Smoke-Test erfolgreich: Datei kopiert, `_Ordner.json` geschrieben, Auswahlfilter korrekt.
  - Zusatzordner-Restore-Smoke-Test erfolgreich: Datei anhand `_Ordner.json` an den Originalpfad wiederhergestellt.
- [x] Review-Fixes umgesetzt.
  - Fehlgeschlagener Worker-Start stellt Start-, Zusatzordner-, Dry-Run- und Auswurf-Controls wieder her.
  - `_Ordner.json` wird mit vorhandenen Zusatzordner-Metadaten gemerged statt ueberschrieben oder geloescht.
  - Standardordner-Abwahlen bleiben beim Hinzufuegen/Entfernen von Zusatzordnern erhalten.
  - Zusatzordner-Namen werden gegen vorhandene `_Ordner.json`-Eintraege geprueft.
  - Auto-Auswurf-Checkbox bleibt nach normalen Laufabschluessen erhalten, solange Modus und Laufwerk sie erlauben.
  - Auswurfpfad enthaelt keine feste UI-blockierende Wartezeit und keine `Test-Path`-Timing-Heuristik mehr.
  - Reservierte Namen und Pfadverschachtelungspruefung liegen in `M24Backup.Shared.ps1`; `build.ps1` paketiert die Datei mit.
