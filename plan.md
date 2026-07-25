# Plan und Umsetzungsergebnis: Pfadanzeige der Ordnerauswahl

## Ziel

Beim Markieren eines Eintrags in der Ordnerliste soll verständlich erkennbar
sein, woher die Daten gelesen beziehungsweise wohin sie geschrieben werden.
Die Anzeige darf die bestehende Fensterhöhe und die Höhe der Ordnerliste nicht
vergrößern oder verkleinern.

## Bedienkonzept

Die Pfadinformation steht im bisher ungenutzten Bereich unter den Schaltflächen
`Alle`, `Keine`, `Hinzufügen` und `Entfernen`.

Die Anzeige unterscheidet bewusst nach Vorgang:

- Im Sicherungsmodus lautet die Überschrift `Quellordner:`.
- Im Wiederherstellungsmodus lautet die Überschrift `Zielordner:`.
- Ohne markierten Listeneintrag fordert ein kurzer Hinweis zur Auswahl auf.
- Ist beim Kopieren noch kein Ziel gewählt, wird kein möglicherweise falscher
  Pfad gezeigt, sondern zur Wahl eines Zielordners aufgefordert.

Der Pfad wird mehrzeilig dargestellt. Unsichtbare Umbruchmöglichkeiten nach
Verzeichnistrennern erlauben WinForms sinnvolle Zeilenumbrüche, ohne den
eigentlichen Pfad zu verändern. Reicht der verfügbare Platz trotzdem nicht,
kürzt die Anzeige mit Auslassungszeichen. Ein Tooltip und die barrierefreie
Beschreibung enthalten immer den vollständigen, unveränderten Text.

Zusätzlich erscheint beim Verweilen mit der Maus über einem Listeneintrag ein
Tooltip direkt an dieser Zeile. Er verwendet dieselbe kontextabhängige
Pfadermittlung wie die feste Anzeige. Die feste Anzeige bleibt erhalten, damit
der Speicherort auch per Tastatur zugänglich und dauerhaft sichtbar ist.

## Zielermittlung

### Sicherung

Angezeigt wird der tatsächliche Quellpfad des markierten Standard- oder
Zusatzordners.

### Wiederherstellung in einen anderen Ordner

Das angezeigte Ziel entspricht der Worker-Zuordnung:

`<gewählter Zielordner>\<Name der Sicherung>\<Ordnername>`

Solange kein Zielordner gewählt wurde, erscheint ein entsprechender Hinweis.

### Wiederherstellung der eigenen Profilsicherung

- Standardordner zeigen ihr Ziel im aktuellen Benutzerprofil.
- Zusatzordner zeigen den gespeicherten `OriginalPath`, an den auch der Worker
  zurückschreibt.

### Migration einer fremden Profilsicherung

- Standardordner zeigen ihr Ziel im aktuellen Benutzerprofil.
- Zusatzordner zeigen das sichere Migrationsziel:

  `Dokumente\Wiederhergestellte Ordner\<Name der Sicherung>\<Ordnername>`

Historische Pfade des fremden Rechners werden nicht als Ziel ausgegeben.

## Technische Umsetzung

### Layout

`$folderCommandPanel` besitzt jetzt drei Zeilen:

1. `Alle` und `Keine`
2. `Hinzufügen` und `Entfernen`
3. die Pfadanzeige über beide Spalten

Das Panel füllt weiterhin nur seine bestehende Zelle rechts neben der
Ordnerliste. Die dritte Zeile erhält ausschließlich den dort verbleibenden
Platz. Es wurde keine zusätzliche Zeile in `$folderSurface` angelegt; dadurch
bleiben Fenster- und Listenhöhe unverändert.

### Logik

`Get-SelectedFolderLocationDetails` ermittelt kontextabhängig Überschrift,
vollständigen Pfad oder Hinweistext. Die Funktion berücksichtigt:

- Sicherungs- und Wiederherstellungsmodus
- Profilziel und separates Ordnerziel
- eigenes und fremdes Sicherungsprofil
- Standard- und Zusatzordner
- fehlende Sicherungs- oder Zielauswahl

`Update-FolderLocationDisplay` übernimmt Darstellung, Zeilenumbruch,
vollständigen Tooltip sowie `AccessibleName` und `AccessibleDescription`.

Die Anzeige wird über den bestehenden Auswahlzustand aktualisiert. Damit
funktioniert sie sowohl mit der Maus als auch beim Navigieren per Tastatur und
wird ebenfalls nach Modus-, Sicherungs- oder Zielwechsel neu berechnet.

Für die Hover-Anzeige ermittelt `IndexFromPoint` den Eintrag unter dem
Mauszeiger. Der zuletzt angezeigte Index wird gespeichert, sodass der Tooltip
nicht bei jeder Mausbewegung innerhalb derselben Zeile neu geöffnet wird. Beim
Verlassen oder Neubefüllen der Liste wird er ausgeblendet und der Index
zurückgesetzt.

## Geänderte Dateien

- `Bibliothekssicherung-GUI.ps1`
- `tests/M24Backup.Shared.Tests.ps1`
- `plan.md`

Die bereits zuvor ergänzten Restore-Transparenz- und Sicherheitsänderungen in
`Bibliothekssicherung.ps1` und
`tests/Bibliothekssicherung.Worker.Tests.ps1` bleiben Bestandteil des
Arbeitsstands.

## Testabdeckung

Ergänzte Vertragstests prüfen:

- Nutzung der dritten Zeile im vorhandenen Buttonpanel
- mehrzeiliges, die Zelle ausfüllendes Label über beide Spalten
- Unterscheidung zwischen `Quellordner` und `Zielordner`
- Berücksichtigung beider Restore-Zielarten
- sichere Migrationszuordnung unter `Wiederhergestellte Ordner`
- Aktualisierung bei geänderter Listenauswahl
- vollständigen Tooltip und barrierefreie Beschreibung
- Hover-Ermittlung über `IndexFromPoint`
- Wiederverwendung derselben Pfadlogik für feste und schwebende Anzeige
- Flackerschutz durch Index-Tracking
- Ausblenden bei `MouseLeave` und vor dem Neubefüllen der Liste

## Prüfergebnis

- PowerShell-Syntax der GUI: fehlerfrei
- Pester: 199 Tests bestanden, 0 fehlgeschlagen
- 1 Test wurde umgebungsbedingt übersprungen, weil symbolische Links in der
  Testumgebung nicht erstellt werden können

## Ergebnis

Das Feature ist umgesetzt. Die Pfadanzeige nutzt den freien Platz unter den
Auswahlbuttons, bleibt mehrzeilig und verändert die Listenhöhe nicht. Sie zeigt
im Sicherungsmodus die Quelle und im Wiederherstellungsmodus ausschließlich das
tatsächliche oder noch zu wählende Ziel. Mausnutzer erhalten denselben Inhalt
zusätzlich beim Überfahren eines Listeneintrags als Tooltip.
