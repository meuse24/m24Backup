# Implementierungsplan: Lokales HTML-Hilfesystem

## Ziel

Die bisherige reine Textdatei-Hilfe (`Hilfe-und-Info.txt` / `Help-and-Info.txt`,
geoeffnet per `Start-Process` ueber den Hilfe-Button) wird durch ein lokales,
im Browser angezeigtes HTML-Hilfesystem ersetzt:

1. Markdown als Pflegequelle (`docs/help.de.md`, `docs/help.en.md`).
2. Ein selbstgebauter Build-Schritt erzeugt daraus je eine in sich
   geschlossene HTML-Datei (`Hilfe/index.de.html`, `Hilfe/index.en.html`).
3. Die GUI verlinkt kontextsensitiv auf einzelne Abschnitte per Anchor
   (`#dry-run`, `#safe-eject`, `#custom-folders`, `#restore`,
   `#backup-health`) zusaetzlich zum bestehenden globalen Hilfe-Button.

Betroffen sind vor allem `build.ps1` (neuer HTML-Erzeugungsschritt),
`Bibliothekssicherung-GUI.ps1` (Hilfe-Button-Logik, neue kontextsensitive
Hilfe-Schaltflaechen), die beiden Markdown-Quellen (neu, ersetzen die
`.txt`-Dateien inhaltlich) sowie `installer/Bibliothekssicherung.iss`
(vermutlich keine Aenderung noetig, siehe unten).

## Vorabentscheidungen

- **Keine neue Laufzeitabhaengigkeit.** Kein WebView2, kein Pandoc-Zwang zur
  Laufzeit. Die HTML-Erzeugung passiert ausschliesslich beim Build; die
  ausgelieferte App enthaelt nur fertiges HTML plus die PowerShell-Skripte,
  genau wie heute.
- **Markdown-zu-HTML-Konvertierung als kleiner, selbstgeschriebener
  PowerShell-Konverter**, kein Pandoc-Zwang. Begruendung: `build.ps1` schreibt
  bereits einen eigenen ICO-Encoder in PowerShell, um keine externe
  Abhaengigkeit zu brauchen (`New-AppIcon` in `build.ps1`). Ein Pandoc-Zwang
  waere ein Bruch mit diesem etablierten Stil und macht den Build auf
  Rechnern ohne Pandoc-Installation kaputt. Der benoetigte Markdown-Umfang ist
  klein und stabil (Ueberschriften mit Ankern, Absaetze, nummerierte/
  Aufzaehlungslisten, Fettschrift, einfache Tabellen, horizontale Trenner) und
  laesst sich mit einem kleinen handgeschriebenen Parser zuverlaessig
  abdecken. Pandoc bleibt als Alternative dokumentiert, falls spaeter mehr
  Markdown-Funktionsumfang noetig wird.
- **Ein Dokument pro Sprache, keine Trennung von Anwender- und
  Technikteil.** Die heutige Datei enthaelt bewusst sowohl eine Anwender-
  Anleitung (Teil 1) als auch technische Hintergrundinformation (Teil 2:
  Komponenten, Tech-Stack, Prozessarchitektur, Robocopy-Parameter,
  Exit-Codes). Diese Struktur bleibt erhalten (geringster Migrationsaufwand,
  Teil 2 dient erkennbar auch der Fehlerdiagnose durch versierte Nutzer).
  Alternative (spaeter moeglich, nicht Teil dieses Plans): Teil 2 in ein
  separates `ARCHITECTURE.md` fuer Entwickler auslagern und die Hilfe rein
  anwenderorientiert halten.
- **CSS wird inline in jede generierte HTML-Datei eingebettet**, kein
  separates `help.css` als eigene Datei. Die generierten Dateien sind damit
  je in sich geschlossen (ein Artefakt pro Sprache) und robust gegen
  Kopiervorgaenge (portables ZIP, Installer-Staging), ohne von einem korrekt
  mitkopierten `assets`-Ordner abzuhaengen. Bilder sind fuer Version 1 nicht
  vorgesehen; falls spaeter Screenshots noetig werden, werden sie beim Build
  als Base64-Data-URIs eingebettet, damit die Selbstgeschlossenheit erhalten
  bleibt.
- **Kein separates `.txt`-Fallback-Duplikat.** Statt `Hilfe-und-Info.txt`
  als eigenstaendig gepflegte dritte Kopie weiterzufuehren, dient die
  Markdown-Quelldatei selbst als Laufzeit-Fallback, falls die generierte
  HTML-Datei zur Laufzeit fehlt (z. B. bei einer beschaedigten Installation).
  Rohes Markdown mit einfachen `#`-Ueberschriften ist in einem Texteditor gut
  lesbar; eine dritte, staendig zu synchronisierende Textkopie entfaellt
  damit vollstaendig. Wenn eine huebschere Fallback-Darstellung gewuenscht
  ist, kann `Hilfe-und-Info.txt`/`Help-and-Info.txt` fuer eine
  Uebergangszeit zusaetzlich weitergefuehrt werden (siehe Abschnitt
  "Alternativen").
- **Abschnittsparitaet zwischen Deutsch und Englisch ist Pflicht.**
  Kontextsensitive Anchors muessen unabhaengig von der Anzeigesprache
  funktionieren. Heute weicht die Struktur ab: `Hilfe-und-Info.txt` hat 20
  nummerierte Abschnitte (u. a. eigene Abschnitte "Häufige Probleme",
  "Inter-Prozess-Kommunikation", "Preflight und Konflikterkennung"),
  `Help-and-Info.txt` nur 17. Beim Uebertragen nach Markdown werden beide
  Sprachversionen auf dieselbe Abschnittsstruktur und dieselben (englischen,
  sprachneutralen) Anchor-Slugs gebracht; fehlende Abschnitte werden in der
  jeweils anderen Sprache ergaenzt, nicht stillschweigend weggelassen.
- **Neuer Inhalt: Backup-Ampel/Health-Anzeige.** Diese bestehende Funktion
  (siehe README, `Get-BackupHealth`/`Update-BackupHealth` in der GUI) ist in
  der heutigen Hilfe ueberhaupt nicht dokumentiert. Ein kurzer neuer
  Abschnitt (Anchor `backup-health`) wird beim Migrieren ergaenzt, nicht nur
  verlinkt.

## 1. Markdown-Quellstruktur

```
docs/
  help.de.md
  help.en.md
```

- Beide Dateien uebernehmen die heutige Zweiteilung (Anwenderteil /
  Technikteil) als Markdown-Ueberschriften (`#`, `##`).
- Jede Ueberschrift, die als Sprungziel fuer kontextsensitive Hilfe dient,
  bekommt einen expliziten, sprachneutralen HTML-Anker direkt vor der
  Ueberschrift, z. B. `<a id="dry-run"></a>`. Diese Syntax funktioniert auch
  in normalen Markdown-Viewern wie GitHub oder VS Code und bleibt im
  Markdown-Fallback sichtbar nachvollziehbar. Ohne expliziten Anker erzeugt
  der Konverter automatisch einen Slug aus dem Ueberschriftentext
  (Kleinschreibung, Leerzeichen zu `-`).
- Feste Anchor-Slugs fuer die fuenf angefragten Themen (identisch in beiden
  Sprachdateien):
  - `dry-run`
  - `safe-eject`
  - `custom-folders`
  - `restore`
  - `backup-health`
- Versionsplatzhalter: ein einzelnes `{{VERSION}}` in jeder Markdown-Datei
  (ersetzt die heutigen drei verschiedenen Ersetzungen in `build.ps1`, siehe
  Abschnitt 3), sowie ein `{{BUILD_DATE}}` fuer das Versionsdatum, falls
  weiterhin gewuenscht.
- Die Robocopy-Parameterliste (heute eine feste Textausrichtung mit
  Leerzeichen) wird als Markdown-Tabelle abgebildet, damit der Konverter sie
  sauber in eine `<table>` uebersetzen kann.

## 2. Markdown-zu-HTML-Konverter

Neue Funktion in `build.ps1` (oder eine ausgelagerte `ConvertTo-HelpHtml.ps1`,
falls das uebersichtlicher ist), die den unterstuetzten Markdown-Ausschnitt in
HTML uebersetzt:

- Unterstuetzt: `#`/`##`/`###`-Ueberschriften, explizite
  `<a id="..."></a>`-Anker,
  Absaetze, nummerierte und Aufzaehlungslisten, `**fett**`, `` `code` ``,
  einfache Tabellen (`| a | b |`), horizontale Trenner (`---`).
- Nicht unterstuetzt (bewusst, weil im aktuellen Inhalt nicht benoetigt):
  verschachtelte Listen ueber zwei Ebenen, Bilder, Links auf externe
  Zwischenueberschriften-Ebenen jenseits `###`.
- Erzeugt eine vollstaendige, in sich geschlossene HTML-Seite: `<html>`,
  eingebettetes `<style>` (siehe Abschnitt 4), ein Inhaltsverzeichnis am
  Seitenanfang (automatisch aus den `##`-Ueberschriften erzeugt, mit Links
  auf die jeweiligen Anchors), danach der eigentliche Inhalt.
- Wird analog zu `New-AppIcon` als eigene Funktion mit klarem Vertrag
  geschrieben (Eingabe: Markdown-Text und Zielsprache; Ausgabe: HTML-String),
  damit sie unabhaengig getestet werden kann (siehe Testabschnitt).

## 3. Build-Integration (`build.ps1`)

- Der bestehende Block, der `{{VERSION}}` und die beiden hartcodierten
  Versions-Ersetzungen in `Hilfe-und-Info.txt`/`Help-and-Info.txt` durchfuehrt,
  wird ersetzt durch:
  1. `docs/help.de.md` und `docs/help.en.md` einlesen.
  2. `{{VERSION}}` (und ggf. `{{BUILD_DATE}}`) ersetzen.
  3. Beide Male den neuen Markdown-zu-HTML-Konverter aufrufen.
  4. Ergebnis nach `$stageDir\Hilfe\index.de.html` bzw.
     `$stageDir\Hilfe\index.en.html` schreiben.
- Wie bei den bestehenden Pruefungen (`if (-not (Test-Path ... )) { throw ... }`
  fuer `logo.jpg`/das Installer-Skript) bricht der Build hart ab, wenn eine
  Markdown-Quelldatei fehlt oder der Konverter einen Fehler wirft. Eine
  fehlerhafte Hilfe wird nicht stillschweigend ausgeliefert.
- Die Markdown-Quellen werden als `docs/help.de.md` und `docs/help.en.md`
  mit in das Staging-Verzeichnis kopiert. Das weicht von der ersten
  Skizze ab, ist aber fuer den geplanten Laufzeit-Fallback notwendig:
  Fehlt die generierte HTML-Datei in einer beschaedigten Installation, kann
  die App dieselbe Markdown-Quelle direkt oeffnen, statt eine dritte
  `.txt`-Kopie pflegen zu muessen.
- Kein Aenderungsbedarf in `installer/Bibliothekssicherung.iss`: Die
  `[Files]`-Sektion kopiert bereits `{#SourceDir}\*` mit
  `recursesubdirs createallsubdirs` (Zeile 51) — ein neuer `Hilfe`-Unterordner
  in `$stageDir` wird automatisch mit ausgeliefert, sowohl im Installer als
  auch im portablen ZIP (`Compress-Archive -Path $portableRoot ...`).
- `Hilfe-und-Info.txt`/`Help-and-Info.txt` als eigenstaendig gepflegte
  Dateien entfallen (siehe Vorabentscheidung); die bisherigen
  Versions-Ersetzungen fuer diese beiden Dateien werden aus `build.ps1`
  entfernt.

## 4. Aussehen / CSS

- Schlichtes, gut lesbares Stylesheet inline im `<style>`-Tag: proportionale
  Schrift, maximale Textbreite (~760px) fuer Lesbarkeit, sichtbare
  Ueberschriften-Hierarchie, dezente Trennlinien, druckfreundliche Faerbung
  (schwarz auf weiss, keine dunklen Flaechen, die beim Ausdrucken viel Tinte
  verbrauchen), da eine gedruckte Kopie fuer eine Backup-Anleitung ein
  realistischer Anwendungsfall ist.
- Kein Dark-Mode-Zwang noetig (lokale Hilfeseite, kein Web-Artefakt mit
  Erwartungshaltung); optional per `@media (prefers-color-scheme: dark)`,
  aber nicht Teil des Kernumfangs.
- Anchor-Ziele bekommen etwas `scroll-margin-top`, damit die feste
  Inhaltsverzeichnis-Kopfzeile (falls als sticky Header umgesetzt) die
  Ueberschrift beim Anspringen nicht verdeckt.

## 5. GUI-Integration

### Hilfe-Button (bestehend)

- `$helpFile` (`Bibliothekssicherung-GUI.ps1:46`) zeigt kuenftig auf
  `Hilfe\index.de.html` bzw. `Hilfe\index.en.html` statt auf die `.txt`-Datei.
- Fuer lokale Entwicklung prueft die GUI zusaetzlich
  `build\staging\Hilfe\index.*.html`, wenn die ausgelieferte
  `Hilfe\index.*.html` im Projektordner noch nicht existiert. Dadurch oeffnet
  ein Quellbaum nach einem Build ebenfalls die formatierte HTML-Hilfe statt
  direkt auf den Markdown-Fallback zu fallen.
- `$helpButton.Add_Click` (Zeile 1723) bleibt inhaltlich fast gleich
  (`Test-Path` + `Start-Process`), oeffnet aber eine HTML-Datei, die vom
  Standardbrowser dargestellt wird.
- Fallback: Existiert die HTML-Datei nicht (z. B. defekte Installation),
  faellt der Button auf `docs\help.de.md`/`docs\help.en.md` zurueck, sofern
  diese mit ausgeliefert werden (siehe Entscheidung: als Fallback im
  Installationsverzeichnis behalten, nicht nur im Repo). Nur wenn auch das
  fehlt, erscheint die heutige Fehlermeldung.

### Kontextsensitive Hilfe

- Neue Hilfsfunktion `Open-HelpTopic -Anchor '<slug>'` in
  `Bibliothekssicherung-GUI.ps1`:
  - Ermittelt die aktuell passende Sprachdatei wie `$helpFile`.
  - Baut daraus eine korrekte `file://`-URI **mit Fragment**, statt den
    Pfad naiv mit `#anchor` zu verketten. Wichtig: `Start-Process` uebergibt
    den Dateinamen an ShellExecute; ein simples
    `"$helpFile#$anchor"` wird von Windows als (nicht existierender)
    Dateiname interpretiert und schlaegt fehl, weil lokale Pfade technisch
    `#` enthalten duerfen. Stattdessen: `[System.Uri]`-Konstruktion aus dem
    absoluten Pfad (kuemmert sich um Leerzeichen/Sonderzeichen im Pfad,
    z. B. `C:\Program Files\...`) plus manuell angehaengtem `#anchor`, und
    das Ergebnis als `-FilePath` an `Start-Process` uebergeben.
  - Faellt wie der Haupt-Hilfe-Button auf die Markdown-Datei zurueck, wenn
    die HTML-Datei fehlt (dann ohne Anchor-Sprung, da einfache Texteditoren
    keine Fragmente unterstuetzen; das ist ein akzeptabler Komfortverlust
    im Fallback-Fall).
- Neue kleine Hilfe-Schaltflaechen ("?", z. B. 18x18px, flach, wie die
  uebrigen Buttons gestylt) neben:
  - `dryRunCheckBox` (Anchor `dry-run`)
  - `ejectCheckBox` (Anchor `safe-eject`)
  - `addFolderButton`/`removeFolderButton`-Bereich (Anchor `custom-folders`)
  - `restoreRadio` oder dem "Wiederherstellung pruefen"-Startbutton im
    Restore-Modus (Anchor `restore`)
  - `healthPanel`/`healthDot` (Anchor `backup-health`)
- Platzierung: Das Fenster ist bewusst fixiert (`FormBorderStyle =
  FixedSingle`, siehe `$form.ClientSize`/`MinimumSize`, bereits einmal bei
  den Dry-Run/Zusatzordner/Auswurf-Funktionen als enger Platz identifiziert).
  Die "?"-Buttons sind aber deutlich kleiner als die vorherigen Checkboxen/
  Buttons und werden **dynamisch** direkt hinter der jeweils tatsaechlich
  gerenderten Breite des Nachbar-Controls positioniert (z. B.
  `$dryRunCheckBox.Left + $dryRunCheckBox.GetPreferredSize([System.Drawing.Size]::Empty).Width + 6`),
  genau wie es `$restoreRadio`/`$modePanel` heute schon fuer variable
  Textbreiten macht (`Bibliothekssicherung-GUI.ps1:613,615`). Das vermeidet
  hartcodierte Pixel-Offsets, die bei Sprachwechsel (unterschiedliche
  Textlaenge von "Nur simulieren (Dry-Run)" vs. "Simulate only (dry run)")
  kollidieren wuerden. Freier Platz in der bestehenden `optionsSurface`-Zeile
  (`$dryRunCheckBox`/`$ejectCheckBox`, Breite 692px insgesamt) reicht nach
  grober Schaetzung fuer die zwei "?"-Buttons dort aus; fuer
  `addFolderButton`/`healthPanel`/`restoreRadio` ist die tatsaechlich freie
  Breite bei der Umsetzung nachzumessen, bevor final positioniert wird.
- Ergaenzend, nicht ersetzend: Die bestehenden `ToolTip`-Komponenten
  (`$driveToolTip`, `$healthToolTip`) bleiben fuer kurze Hover-Hinweise
  erhalten. Die neuen "?"-Buttons sind fuer den Sprung zur ausfuehrlichen
  Dokumentation gedacht (kurzer Hover-Hinweis plus Klick-Option = etabliertes,
  professionelles Muster), nicht als Ersatz fuer die Tooltips.

## 6. Migration der bestehenden Inhalte

- Inhalte aus `Help-and-Info.txt`/`Hilfe-und-Info.txt` werden inhaltlich nach
  `docs/help.en.md`/`docs/help.de.md` uebertragen und fuer das neue
  Hilfesystem verdichtet (nummerierte Abschnitte zu `##`-Ueberschriften,
  Bindestrich-Listen zu Markdown-Listen, die Robocopy-Parameter zu einer
  Markdown-Tabelle).
- Fehlende Abschnitte werden ergaenzt, damit beide Sprachen dieselbe
  Abschnittsstruktur haben (siehe Vorabentscheidung zur Abschnittsparitaet):
  mindestens "Häufige Probleme"/"Common issues",
  "Inter-Prozess-Kommunikation"/"Inter-process communication",
  "Preflight und Konflikterkennung"/"Preflight and conflict detection" fehlen
  heute in der englischen Datei und muessen uebersetzt ergaenzt werden.
- Neuer Abschnitt "Backup-Ampel/Backup health indicator" (Anchor
  `backup-health`) wird in beiden Sprachen neu geschrieben (Ampelfarben Rot/
  Gelb/Gruen, Aktualitaetsgrenzen 7/14 Tage aus `Get-BackupHealth`,
  Tooltip-Details).
- Die alten `.txt`-Dateien werden aus dem Repository-Root geloescht, sobald
  die Migration abgeschlossen und geprueft ist (nicht vorher, um einen
  Vergleich waehrend der Migration zu erleichtern).

## Alternativen (bewusst nicht gewaehlt)

- **CHM-Hilfedateien**: klassisches Windows-Format, aber durch
  Sicherheitszonen-Blockierung bei aus dem Internet heruntergeladenen
  Dateien beim Endnutzer oft nur nach manuellem Entsperren nutzbar; keine
  moderne Bearbeitung ohne Zusatztools.
- **Eingebetteter WebView2-Hilfe-Viewer**: professionelles In-App-Erlebnis,
  aber WebView2-Runtime-Abhaengigkeit (auf ungepflegten Windows-Installationen
  ggf. nicht vorhanden) und deutlich mehr UI-Code fuer den Nutzen bei dieser
  App-Groesse nicht gerechtfertigt.
- **Nur Online-Dokumentation**: fuer eine Backup-Anwendung ungeeignet, weil
  Hilfe gerade dann verfuegbar sein muss, wenn kein Internetzugang besteht
  (z. B. Wiederherstellung auf einem frisch aufgesetzten Rechner).
- **Pandoc als Build-Abhaengigkeit statt eigenem Konverter**: reduziert
  eigenen Code, bricht aber mit dem bestehenden "keine externen
  Build-Tools ausser optional Inno Setup"-Stil des Projekts und macht den
  Build auf Rechnern ohne Pandoc-Installation kaputt, sofern nicht dieselbe
  weiche Fallback-Logik wie fuer Inno Setup (`Get-InnoCompiler`,
  `-SkipInstaller`) nachgebaut wird. Bleibt als Option, falls der
  Markdown-Funktionsumfang spaeter deutlich waechst (z. B. Bilder mit
  Bildunterschriften, verschachtelte Tabellen).
- **`.txt`-Dateien parallel dauerhaft weiterfuehren**: vermeidet jede
  Aenderung am Fallback-Verhalten, bedeutet aber eine dritte, staendig von
  Hand synchron zu haltende Kopie derselben Inhalte. Nur empfohlen, falls
  die rohe Markdown-Datei als Fallback-Darstellung als zu unschoen
  empfunden wird.

## Tests und Pruefung

### Manuelle Tests

1. Build ausfuehren (`build.ps1`), pruefen dass `Hilfe\index.de.html` und
   `Hilfe\index.en.html` im Staging-Ordner, im portablen ZIP und im
   Installer-Ausgabeverzeichnis vorhanden sind.
2. Beide HTML-Dateien im Standardbrowser oeffnen: Inhaltsverzeichnis,
   Ueberschriften-Hierarchie, Tabellen, Listen korrekt dargestellt; Drucken
   ergibt ein lesbares Layout.
3. Hilfe-Button in der App (Deutsch und Englisch, ggf. ueber
   `CurrentUICulture` simuliert) oeffnet die jeweils passende Sprachdatei.
4. Jede der fuenf neuen "?"-Schaltflaechen oeffnet die HTML-Datei und
   springt sichtbar zum richtigen Abschnitt (Anchor), in beiden Sprachen.
5. HTML-Datei versehentlich loeschen/umbenennen, pruefen dass Hilfe-Button
   und "?"-Buttons korrekt auf die Markdown-Datei zurueckfallen bzw. bei
   deren Fehlen die bestehende Fehlermeldung zeigen.
6. Version im generierten HTML pruefen (`{{VERSION}}` korrekt ersetzt,
   entspricht `$buildVersion`).
7. Sichtprüfung auf kleinen Bildschirmen: neue "?"-Buttons ueberlappen
   keine bestehenden Controls, auch bei der jeweils laengeren
   Sprachvariante der Nachbartexte.

### Statische Pruefung

- PowerShell-Parserlauf fuer `build.ps1` und `Bibliothekssicherung-GUI.ps1`
  nach Aenderung (`[System.Management.Automation.PSParser]::Tokenize(...)`).
- Der neue Markdown-Konverter bekommt, falls sinnvoll trennbar, ein kleines
  eigenstaendiges Test-Snippet (z. B. `build.ps1 -HelpOnly` oder eine
  separate Pester-freie Testfunktion), das ihn gegen beide
  `docs/help.*.md`-Dateien laufen laesst und auf HTML-Wohlgeformtheit prueft
  (z. B. per `[xml]`-Parse nach Normalisierung, oder zumindest auf
  Vorhandensein aller erwarteten Anchor-IDs und darauf, dass keine Absaetze
  innerhalb offener Listen erzeugt werden).

## Empfohlene Umsetzungsreihenfolge

1. `docs/help.de.md` und `docs/help.en.md` aus den bestehenden `.txt`-Dateien
   erstellen, Abschnittsparitaet herstellen, fehlende Abschnitte ergaenzen,
   neuen Backup-Ampel-Abschnitt schreiben, Anchor-Slugs fuer die fuenf
   Kontext-Themen setzen.
2. Markdown-zu-HTML-Konverter in `build.ps1` (oder ausgelagerter Datei)
   implementieren und isoliert gegen die beiden Quellen testen.
3. `build.ps1` um den HTML-Erzeugungsschritt erweitern, alte
   Versions-Ersetzungslogik fuer die `.txt`-Dateien entfernen, Staging/ZIP/
   Installer-Weg pruefen (Abschnitt 3).
4. `$helpFile`/`$helpButton.Add_Click` in der GUI auf die HTML-Datei
   umstellen, inkl. Fallback auf die Markdown-Datei.
5. `Open-HelpTopic`-Hilfsfunktion und die fuenf neuen "?"-Buttons in der GUI
   ergaenzen, Platzierung dynamisch ueber `GetPreferredSize` loesen.
6. Alte `.txt`-Dateien aus dem Repository-Root entfernen.
7. README/CHANGELOG aktualisieren (Hinweis auf neues Hilfeformat und
   kontextsensitive Hilfe).
8. Manuelle Tests und Parserpruefung durchfuehren (siehe Testabschnitt).

## Fortschritt

- [x] Plan bewertet und angepasst: Markdown-Dateien werden als Laufzeit-
  Fallback mit ausgeliefert.
- [x] Markdown-Quellen erstellen und alte Textduplikate entfernen.
- [x] Markdown-zu-HTML-Konverter und Build-Integration umsetzen.
- [x] GUI auf HTML-Hilfe plus kontextsensitive Hilfe-Buttons umstellen.
- [x] README/CHANGELOG aktualisieren.
- [x] Build, Parser und Artefakte pruefen.
  - `build.ps1 -Version 1.2.1-help-test -SkipInstaller` erfolgreich.
  - Generierte HTML-Dateien und Markdown-Fallbacks liegen im Staging und im
    portablen ZIP.
  - Anchors `dry-run`, `safe-eject`, `custom-folders`, `restore` und
    `backup-health` in beiden HTML-Dateien gefunden.
- [x] Review-Fixes nachgezogen.
  - Markdown-Quellen werden im Build explizit als UTF-8 gelesen.
  - Listenfortsetzungen werden korrekt in das vorherige `<li>` uebernommen.
  - Robocopy-Parameter, Sicherheitsgrenzen, Exit-Codes und Empfehlungen sind
    gegen den Worker und die alte Hilfe abgeglichen.
  - Proprietäre `{#anchor}`-Syntax wurde durch normale HTML-Anker ersetzt.
