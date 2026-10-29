# Autoping 2

Ein moderner Nachbau von **autoping 1.02** (Memset Ltd., 2013): eine Menüleisten-App,
die jede Sekunde einen Host anpingt und die Verbindungsqualität als Signalbalken anzeigt.

## Warum

Das Original ist ein reines Intel-Binary (x86_64, gebaut mit Xcode 6.1 für OS X 10.10)
und läuft auf Apple-Silicon-Macs nur über Rosetta 2, das mit macOS 28 wegfällt.
Weiterentwickelt wird es nicht mehr.

## Was das Original macht (aus dem Binary rekonstruiert)

- Pingt einen Host (Standard `memset.com`) jede Sekunde per ICMP an (Apples SimplePing, nur IPv4).
- **Bewertung** (`onHousekeepingTimer:`, jede Sekunde): Jeder Ping der letzten 30 s bekommt einen Score –
  1 bis zur „Slow ping threshold“ (Standard 100 ms), danach linear fallend auf 0 über weitere 900 ms
  und weiter bis −2,5; keine Antwort nach dem Timeout (4 s) = −2,5. Die Scores werden mit Gewicht
  ×1,2 pro neuerem Ping gemittelt; `floor(clamp(score, 0, 1) × 5)` wählt 1–5 Balken.
- **Watchdog:** keine Antwort seit Timeout + 4 Sekunden → „Failed“, Pinger wird neu gestartet (inkl. DNS).
- Menüleiste: Symbol und/oder Text („23ms“, optional mit Paketverlust), Tooltip mit Ping-Zeit und Verlust.
- Statistikfenster pro Host (Sitzung und gesamt: gesendet, verloren, Verlust %, Ø/min/max), in SQLite gespeichert.
- Einstellungen: Host, Schwelle (50–2000 ms), Anzeige, Paketverlust-Text, Up/Down-Mitteilungen, Start bei Anmeldung (über eine Helper-App).

`ConnectionScorer` in `Sources/AutopingCore` ist eine 1:1-Umsetzung dieses Algorithmus, abgesichert durch Unit-Tests.

## Was neu ist

- Nativ für Apple Silicon, Swift 6 mit strikter Nebenläufigkeitsprüfung, macOS 14+.
- **IPv4 und IPv6** (unprivilegierte ICMP-Sockets), wählbar oder automatisch mit Fallback.
- **Popover** statt Statistikfenster: Status, Latenz, Paketverlust, Live-Diagramm der letzten 5 Minuten
  (verlorene Pings rot markiert), Sitzungs- und Gesamtstatistik.
- **Schlaf/Aufwachen:** keine Pings im Ruhezustand, Schonfrist nach dem Aufwachen – keine falschen Ausfallmeldungen.
- **Netzwerkwechsel** (WLAN ↔ Ethernet, VPN) startet sofort neu mit frischer DNS-Auflösung; kein Netz → sofort „Offline“.
- Klare Fehlermeldungen (DNS-Fehler, „No route to host“).
- Start bei Anmeldung über `SMAppService` (keine Helper-App), Mitteilungen über das User-Notifications-Framework.
- Ping-Timeout einstellbar, Deutsch und Englisch, Hell-/Dunkelmodus, Rechtsklick-Menü.
- Standard-Host ist `1.1.1.1` (Cloudflare, sehr nah, beantwortet ICMP).

## Bauen

Es reichen die Command Line Tools (kein Xcode):

```bash
Scripts/test.sh               # Unit-Tests
Scripts/build.sh              # baut dist/Autoping.app
Scripts/build.sh --install    # baut, installiert und startet
```

`--install` legt die App nach `/Applications` – solange dort noch das alte `autoping.app` liegt,
nach `~/Applications` (die Namen würden auf dem Dateisystem kollidieren, Groß-/Kleinschreibung zählt nicht).

Zwei Eigenheiten der Toolchain, um die die Skripte herumarbeiten:

- SwiftPMs neues Standard-Buildsystem startet nicht, weil die Command Line Tools einen leeren Ordner
  `SDKs/MacOSX12.3.sdk` (ohne `SDKSettings.plist`) enthalten → `--build-system native`.
- Im macOS-27-SDK ist SwiftUIs `@State` ein Macro, dessen Plugin nur mit Xcode kommt → View-Zustand
  liegt in kleinen `@Observable`-Modellen (`PopoverState`, `SettingsModel`).

## Diagnose

```bash
dist/Autoping.app/Contents/MacOS/Autoping -SnapshotDirectory /tmp/autoping-snap -SnapshotDelay 10
log stream --predicate 'subsystem == "de.jonathanlang.Autoping"'
```

Der Snapshot-Modus rendert Menüleisten-Eintrag, Popover und Einstellungen (hell/dunkel) als PNG.
Alle Einstellungen lassen sich so auch testweise per Argument überschreiben, z. B. `-Hostname 192.0.2.1`.

## Daten

- Einstellungen: `defaults read de.jonathanlang.Autoping`
- Gesamtstatistik: `~/Library/Application Support/de.jonathanlang.Autoping/stats.json`

Die Einstellungen und Statistiken des Originals liegen in dessen Sandbox-Container und sind von außen
nicht lesbar; Host und Schwelle bitte einmal neu eintragen.
