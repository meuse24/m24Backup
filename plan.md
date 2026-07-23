# Umsetzungsplan: Fremdsicherungen öffnen und wiederherstellen

## Ziel

Eine Sicherung soll auch dann nutzbar sein, wenn sie von einem anderen
Computer oder Windows-Benutzer stammt. Typischer Anwendungsfall ist ein neu
eingerichteter PC.

Die Bedienung bleibt bewusst einfach:

1. Sicherung auswählen.
2. Wiederherstellungsziel auswählen.
3. Gewünschte Ordner auswählen.
4. Wiederherstellung prüfen und starten.

Computer- und Benutzername der Sicherung werden angezeigt, verhindern die
Wiederherstellung aber nicht mehr. Technische Entscheidungen wie die Zuordnung
von Windows-Bibliotheken, sichere Zielpfade und die Behandlung zusätzlicher
Ordner übernimmt die Anwendung.

## Bedienkonzept

### Sicherungen auswählen

Nach Auswahl eines Laufwerks zeigt die Anwendung alle gültigen Sicherungen im
Verzeichnis `Bibliothekssicherung` an. Jeder Eintrag enthält:

- Computer und Benutzer der Sicherung
- Datum der letzten erfolgreichen Sicherung
- Zustand: vollständig, unvollständig oder Metadaten nicht lesbar
- Zustand der Prüfsummen

Die Sicherung des aktuellen Profils wird vorausgewählt, sofern sie vorhanden
und verwendbar ist. Andernfalls wird, falls genau eine verwendbare Sicherung
existiert, diese automatisch ausgewählt. Die Ordnernamen auf dem Datenträger
müssen vom Benutzer nicht interpretiert werden.

### Zwei verständliche Zielarten

Die Oberfläche bietet genau zwei Zielarten:

1. **In mein Benutzerprofil wiederherstellen**  
   Desktop, Dokumente, Downloads, Bilder, Musik, Videos und weitere bekannte
   Windows-Ordner werden automatisch den entsprechenden Ordnern des aktuell
   angemeldeten Benutzers zugeordnet.

2. **In einen anderen Ordner kopieren**  
   Der Benutzer wählt einen Zielordner. Darin wird ein Unterordner mit dem
   Namen der Sicherung erstellt. Die gesicherten Ordner bleiben darunter
   getrennt erhalten.

Die erste Option ist der Standard für eine vollständige Sicherung. Bei einer
unvollständigen oder nicht eindeutig lesbaren Sicherung ist nur die zweite,
risikoarme Option verfügbar.

### Ordnerauswahl

Angezeigt werden nur Ordner, die tatsächlich in der gewählten Sicherung
vorhanden sind. Standardmäßig sind alle verwendbaren Ordner ausgewählt.

Standardbibliotheken werden ohne weitere Nachfrage automatisch zugeordnet.
Benutzerdefinierte Ordner werden bei der Profilwiederherstellung einer
**fremden** Sicherung (abweichender Computer oder Benutzer) gesammelt unter:

`Dokumente\Wiederhergestellte Ordner\<Name der Sicherung>\<Ordnername>`

abgelegt. „Name der Sicherung“ entspricht dem `DisplayName` aus dem
Sicherungsinventar (siehe „Modell einer gefundenen Sicherung“). Dadurch muss
der Benutzer keine alten Laufwerksbuchstaben oder Originalpfade verstehen und
es werden keine möglicherweise unpassenden Pfade des alten Computers
wiederverwendet.

Beim Restore der Sicherung des **aktuellen** Profils (`IsCurrentProfile =
true`) ändert sich nichts: Benutzerdefinierte Ordner werden wie bisher an
ihren protokollierten `OriginalPath` zurückgeschrieben. So bleibt der
bestehende Restore-Ablauf für das eigene Profil unverändert kompatibel.

Bei „In einen anderen Ordner kopieren“ werden alle ausgewählten Ordner direkt
unterhalb des neu angelegten Sicherungs-Unterordners abgelegt.

### Bestehende Dateien

Die Anwendung verwendet eine feste, sichere Standardregel:

- Neuere lokale Dateien bleiben erhalten.
- Gleich alte, aber unterschiedlich große Dateien werden aus der Sicherung
  übernommen.
- Es wird nichts am Ziel gelöscht.

Es gibt im Hauptablauf keine Auswahl komplizierter Konfliktstrategien. Die
Konfliktvorschau nennt lediglich, wie viele Dateien ergänzt, ersetzt oder als
neuere lokale Version geschützt werden.

### Sicherheitsabfrage

Vor dem Start erscheint eine kompakte Zusammenfassung:

- Herkunft der Sicherung
- gewählte Zielart und Zielpfad
- ausgewählte Ordner
- Anzahl und Größe der zu kopierenden Dateien
- Anzahl ersetzter und geschützter Dateien
- Ergebnis der Integritätsprüfung

Bei einer fremden Sicherung, die **in das aktuelle Benutzerprofil**
übernommen wird, lautet der zusätzliche Hinweis sinngemäß:

> Diese Sicherung stammt von „ALTER-PC\walter“. Die ausgewählten Daten werden
> in das aktuelle Benutzerprofil übernommen.

Es ist keine Eingabe eines Computer- oder Benutzernamens erforderlich. Bei
„In einen anderen Ordner kopieren“ entfällt dieser zusätzliche Hinweis; die
Herkunft der Sicherung ist dort bereits Teil der regulären
Zusammenfassungspunkte oben (siehe auch Umsetzungsschritt 7).

### Sicherung im Explorer öffnen

Der Button **Sicherungsordner öffnen** öffnet immer die aktuell ausgewählte
Sicherung. Das gilt auch für fremde, unvollständige oder nur teilweise lesbare
Sicherungen. Diese rein lesende Funktion ist nicht von einer
Identitätsprüfung abhängig.

## Technisches Zielmodell

### Trennung von Laufwerk, Sicherungsquelle und Ziel

Die bisherige Annahme

`ausgewähltes Laufwerk + aktueller Computer + aktueller Benutzer = Sicherung`

wird aufgelöst. Künftig werden drei Werte getrennt verwaltet:

- ausgewähltes Laufwerk
- explizit ausgewählter Sicherungsordner
- explizit ermittelte Wiederherstellungsziele

Der Worker erhält den kanonisch aufgelösten Sicherungsordner über einen neuen
Parameter, beispielsweise `-BackupSource`. Bei Sicherungen wird der bestehende
Zielpfad weiterhin aus aktuellem Computer und Benutzer gebildet.

### Modell einer gefundenen Sicherung

Die GUI verwendet für jeden gefundenen Eintrag ein Objekt mit mindestens:

- `RootPath`
- `Computer`
- `User`
- `DisplayName`
- `LastResult`
- `LastCompletedAt`
- `IsComplete`
- `ChecksumManifestExists`
- `ChecksumsVerifiedAt`
- `MetadataReadable`
- `IsCurrentProfile`
- `AvailableFolders`

Pfade werden ausschließlich aus der überprüften Verzeichnisstruktur
übernommen. Angaben aus Metadatendateien dürfen nicht als frei verwendbare
Quellpfade interpretiert werden.

### Zielzuordnung

Für Standardordner verwendet der Worker
`Get-M24StandardFolderDefinitions` auf dem aktuellen Computer. Damit werden
auch OneDrive-Umleitungen und geänderte Windows-Bibliothekspfade
berücksichtigt.

Für benutzerdefinierte Ordner gilt:

- Alte `OriginalPath`-Werte werden nur angezeigt und protokolliert.
- Sie werden auf einem fremden Profil niemals automatisch als Ziel verwendet.
- Das Ziel wird nach der oben beschriebenen festen Regel unter „Dokumente“
  beziehungsweise unter dem frei gewählten Sammelordner erzeugt.

Alle Ziele durchlaufen weiterhin `Assert-SafeRestoreTargetPath`. Zusätzlich
wird geprüft, dass:

- kein Ziel innerhalb der Sicherungsquelle liegt,
- keine zwei ausgewählten Ordner dasselbe oder verschachtelte Ziele erhalten,
- kein Laufwerksstamm und kein komplettes Benutzerprofil Ziel ist,
- geschützte System-, Programm- und AppData-Bereiche ausgeschlossen bleiben.

### Identitätsrichtlinie

`Assert-BackupIdentity` wird für Restores durch eine Quellenvalidierung
ersetzt:

- Metadaten müssen für eine Profilwiederherstellung lesbar sein.
- Eine abweichende Identität ist zulässig und wird als Migration markiert.
- Die tatsächliche Quellidentität wird in Vorschau, Ergebnis und Log
  festgehalten.
- Für „In einen anderen Ordner kopieren“ darf auch eine Sicherung mit fehlenden
  Identitätsmetadaten geöffnet werden, sofern der Quellordner strukturell
  sicher validiert werden kann. Der Zustand wird deutlich angezeigt.

Die strenge Identitätsprüfung für das Löschen von Sicherungen bleibt
unverändert. Die neue Quellenauswahl darf die Löschfunktion nicht automatisch
auf fremde Sicherungen erweitern.

### Vollständigkeit und Integrität

- Vollständige Sicherungen können ins aktuelle Profil oder in einen anderen
  Ordner wiederhergestellt werden.
- Unvollständige Sicherungen können nur in einen separaten Ordner kopiert
  werden.
- Vor einer Profilwiederherstellung wird ein vorhandenes
  Prüfsummenmanifest entsprechend der bestehenden Richtlinie geprüft.
- Bei fehlendem Manifest bleibt die bestehende ausdrückliche Warnung erhalten.
- Eine fehlgeschlagene Prüfsummenprüfung verhindert die automatische
  Profilwiederherstellung.
- Das Öffnen im Explorer bleibt immer möglich.

## Umsetzungsschritte

### 1. Sicherungsinventar einführen

- Gemeinsame Funktion zum Auflisten von
  `<Laufwerk>\Bibliothekssicherung\*` implementieren.
- Nur direkte Unterordner untersuchen; keine beliebige rekursive Suche.
- Metadaten, Abschlussstatus, Prüfsummenstatus und vorhandene Datenordner
  defensiv einlesen.
- Ungültige oder nicht lesbare Einträge als solche zurückgeben, statt die
  gesamte Laufwerksauswahl scheitern zu lassen.
- Pfade normalisieren und sicherstellen, dass jeder Treffer unmittelbar unter
  dem erwarteten Sicherungsstamm liegt.
- Tests für mehrere Profile, fehlende Metadaten, unvollständige Sicherungen,
  reservierte Ordner und manipulierte Pfade ergänzen.

### 2. Quellenauswahl in der GUI ergänzen

- Unterhalb der Laufwerksauswahl ein Feld **Gefundene Sicherung** einfügen.
- Aktuelles Profil bevorzugen, ansonsten eine einzelne gültige Sicherung
  automatisch auswählen.
- Herkunft, Datum und Zustand kompakt unter dem Auswahlfeld anzeigen.
- Bibliotheksliste, Größenmessung, Zustandsanzeige und Aktionsbuttons auf die
  ausgewählte Quelle statt auf den aktuellen Profilpfad beziehen.
- Auswahl beim Laufwerkswechsel zuverlässig zurücksetzen.
- Leere, fehlerhafte und gemischte Laufwerke verständlich darstellen.

### 3. Explorer-Zugriff entkoppeln

- **Sicherungsordner öffnen** auf den ausgewählten Inventareintrag umstellen.
- Das Öffnen nicht von Profilidentität, erfolgreichem Abschluss oder
  Prüfsummenstatus abhängig machen.
- Vor dem Öffnen erneut prüfen, dass der Pfad noch existiert und innerhalb des
  erwarteten Sicherungsstamms liegt.
- Protokoll- und Verlaufsbuttons ebenfalls auf die gewählte Sicherung
  beziehen.

### 4. Wiederherstellungsziel modellieren

- In der GUI die beiden Zielarten „mein Benutzerprofil“ und „anderer Ordner“
  ergänzen.
- Für „anderer Ordner“ einen Ordnerdialog und eine eindeutige Zielvorschau
  anbieten.
- Ein Übergabeformat für Quelle, Zielart und Zielzuordnungen definieren. Die
  bestehende JSON-Auswahldatei kann dafür erweitert werden.
- Im Worker `-BackupSource` und die Zielart getrennt vom Sicherungslaufwerk
  verarbeiten.
- Den bisherigen fest berechneten Restore-Quellpfad entfernen; der
  Sicherungsmodus behält seinen bisherigen Zielpfad.

### 5. Fremdsicherung ins aktuelle Profil migrieren

- Standardordner anhand ihrer kanonischen Namen den aktuellen Windows-Pfaden
  zuordnen.
- Fehlende, aber sicher auflösbare Standardordner durch Robocopy anlegen
  lassen.
- Zusatzordner automatisch unter
  `Dokumente\Wiederhergestellte Ordner\<Sicherungsname>` einordnen.
- Identitätsabweichung nicht mehr als Fehler behandeln.
- Migration in Status, Vorschau, Ergebnisdatei und Restore-Protokoll
  kennzeichnen.
- Weiterhin `/XO`, `/XJ`, `/COPY:DAT` und den Verzicht auf `/MIR` und `/PURGE`
  verwenden.

### 6. Kopieren in einen separaten Ordner

- Unter dem gewählten Ziel automatisch einen sicheren, eindeutigen
  Unterordner anlegen.
- Standard- und Zusatzordner mit ihrer Sicherungsstruktur darunter kopieren.
- Kollisionen bei bereits vorhandenem Unterordner eindeutig anzeigen; keine
  zweite verschachtelte Kopie und kein stilles Umleiten erzeugen.
- Neuere Zieldateien wie beim normalen Restore schützen und nichts löschen.
- Diese Zielart auch für unvollständige Sicherungen zulassen, aber den
  unvollständigen Zustand in Vorschau, Log und Ergebnis deutlich nennen.

### 7. Vorschau und Freigabe anpassen

- Quellcomputer, Quellbenutzer, Zielart und Zielpfad in die Preview-JSON-Datei
  aufnehmen.
- Konfliktzählung mit den tatsächlich aufgelösten Zielen durchführen.
- Den bestehenden Restore-Dialog sprachlich auf Migration und separates
  Kopieren erweitern.
- Für eine Profilwiederherstellung aus fremder Quelle eine einzige klare
  Bestätigung verlangen, keine Texteingabe.
- Bei separatem Kopieren keine zusätzliche Identitätswarnung anzeigen.

### 8. Ergebnisse, Protokolle und Dokumentation

- Ergebnisvertrag um Quellidentität, Quellpfad, Zielart und Migrationsstatus
  erweitern.
- Restore-Protokoll um eine Zuordnungsliste `Quellordner -> Zielordner`
  ergänzen.
- README, Hilfe und Änderungsprotokoll aktualisieren.
- Screenshots beziehungsweise UI-Texte für deutschen und englischen Betrieb
  prüfen.
- Klar dokumentieren, dass AppData, Programme und Systemeinstellungen nicht
  Teil der Migration sind.

## Tests

### Gemeinsame Logik

- Keine, eine und mehrere Sicherungen auf einem Laufwerk
- aktuelle und fremde Computer-/Benutzeridentität
- fehlende, beschädigte und manipulierte Metadaten
- vollständiger und unvollständiger Abschlussstatus
- Pfadflucht, Junctions und symbolische Links im Sicherungsstamm
- sichere und blockierte Zielpfade
- Standardordner mit OneDrive-Umleitung
- kollidierende Standard- und Zusatzordner

### Worker

- bestehender Restore des aktuellen Profils bleibt funktionsfähig
- fremde vollständige Sicherung ins aktuelle Profil
- fremde Sicherung in separaten Ordner
- unvollständige Sicherung wird nicht ins Profil eingespielt
- Zusatzordner einer fremden Sicherung verwenden bei der Profilwiederherstellung
  nie ungefragt den alten Originalpfad; der Restore der eigenen aktuellen
  Sicherung schreibt weiterhin an `OriginalPath` zurück
- ausgewählte Teilmenge wird korrekt verarbeitet
- `/XO`, `/XJ`, Prüfsummenprüfung und Abbruchverhalten bleiben erhalten
- Quell- und Zielidentität erscheinen korrekt im Ergebnis

### GUI

- Backup-Auswahl reagiert auf Laufwerkswechsel
- sinnvolle Vorauswahl bei einem oder mehreren Treffern
- fremde Sicherung kann im Explorer geöffnet werden
- Zielart steuert sichtbare und aktivierte Bedienelemente
- Start ist ohne gültige Quelle oder Ziel gesperrt
- Ordnerliste zeigt nur tatsächlich vorhandene Sicherungsordner
- Vorschau ist auch bei anderem Computer- und Benutzernamen verständlich
- Löschen bleibt auf die bisher sicher validierte Profilsicherung beschränkt

### Manuelle Abnahmeszenarien

1. Sicherung auf PC A als Benutzer A erstellen und auf PC B als Benutzer B in
   das aktuelle Profil übernehmen.
2. Dieselbe Sicherung auf PC B in einen frei gewählten Ordner kopieren.
3. OneDrive für Dokumente auf PC B aktivieren und korrekte Zielzuordnung
   prüfen.
4. Vorhandene neuere Dateien auf PC B anlegen und sicherstellen, dass sie
   erhalten bleiben.
5. Eine unvollständige Sicherung auswählen und prüfen, dass nur separates
   Kopieren angeboten wird.
6. Einen benutzerdefinierten Ordner mit altem Laufwerkspfad sichern und
   sicherstellen, dass dieser Pfad auf PC B nicht verwendet wird.
7. Prüfsumme manipulieren und sicherstellen, dass keine Profilmigration
   startet.

## Akzeptanzkriterien

- Eine fremde Sicherung ist nach Auswahl des Laufwerks ohne manuelle
  Pfadeingabe sichtbar.
- Ihr Sicherungsordner lässt sich unabhängig von der Profilidentität öffnen.
- Eine vollständige fremde Sicherung lässt sich mit höchstens einer
  Sicherheitsbestätigung in die aktuellen Windows-Bibliotheken übernehmen.
- Alternativ lassen sich ausgewählte Ordner in einen einzigen frei gewählten
  Zielordner kopieren.
- Der Benutzer muss keine alten Pfade zuordnen und keine Konfliktstrategie
  auswählen.
- Neuere lokale Dateien bleiben erhalten und am Ziel wird nichts gelöscht.
- Bei der Profilwiederherstellung einer fremden Sicherung werden
  benutzerdefinierte Ordner niemals ungefragt an ihren alten Originalpfad des
  Ursprungscomputers zurückgeschrieben. Der Restore der eigenen aktuellen
  Sicherung schreibt wie bisher an `OriginalPath` zurück.
- Unvollständige oder beschädigte Sicherungen werden nicht automatisch in das
  aktuelle Profil eingespielt.
- Der bisherige Sicherungs- und Restore-Ablauf für das aktuelle Profil bleibt
  kompatibel.
- Automatisierte Tests und die beschriebenen manuellen Abnahmeszenarien sind
  erfolgreich.

