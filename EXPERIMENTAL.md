# Experimentelles

Ideen, die diskutiert und teilweise **rudimentär von Hand angetestet**,
aber **nicht implementiert** sind — kein Code in diesem Repo erzeugt oder
pflegt das hier, kein automatisierter Funktionstest deckt es ab. Nichts
hier ist Teil des unterstützten Betriebs (README.md). Ein einzelner
manueller Test (unten dokumentiert) ersetzt nicht den echten, wiederholbaren
`.github/scripts/functional-test.sh`-Ansatz, den der Rest des Repos hat
(siehe CLAUDE.md → "Validating changes") — vor produktivem Einsatz braucht
es mehr als das.

## Modus ohne dauerhaften Container: Forced Command startet `docker run` direkt

**Idee:** Statt eines dauerhaft laufenden `borg-server`-Containers mit
eigenem `sshd` (aktueller Ansatz, siehe README) läuft `sshd` direkt auf dem
Docker-*Host* (das System-`sshd`, das es dort ohnehin schon gibt). Jeder Key
in dessen `authorized_keys` bekommt statt `borg serve ...` ein Forced
Command, das `docker run` aufruft und darin `borg serve` startet — pro
SSH-Verbindung ein frischer, kurzlebiger Container, kein Dauerprozess.

Beispiel-Zeilen für die **System**-`authorized_keys` (nicht die von diesem
Repo verwaltete!), unter Wiederverwendung des ohnehin schon vorhandenen
`docker-borg-backup`-Client-Images (das hat bereits `ENTRYPOINT ["borg"]`,
extra Image für den Server-Zweck wäre nicht nötig):

```
# Backup-Key, ein Repo, append-only:
command="docker run --rm -i -v borg-data:/data ghcr.io/tabacha/docker-borg-backup:latest serve --append-only --restrict-to-repository /data/hostA",restrict ssh-ed25519 AAAA... hostA

# Admin-Key, voller Zugriff auf alle Repos:
command="docker run --rm -i -v borg-data:/data ghcr.io/tabacha/docker-borg-backup:latest serve --restrict-to-path /data",restrict ssh-ed25519 AAAA... admin1
```

- `-i` (kein `-t`): Stdin offen halten, damit das Borg-Protokoll durchgereicht
  wird, aber keine PTY (passt zu `restrict`, das PTY ohnehin verbietet).
- `--rm`: Container nach Verbindungsende wieder wegräumen, sonst sammeln
  sich pro Backup-Lauf verwaiste, gestoppte Container an.
- `-v borg-data:/data`: dasselbe benannte Volume wie im aktuellen Ansatz.

### Rudimentär angetestet (manuell, einmalig, 2026-08-16)

Mit einem frisch erzeugten Test-Key als zusätzliche (nicht ersetzende!)
Zeile in einer echten `~/.ssh/authorized_keys`, gegen den echten System-`sshd`
auf `localhost`, hinterher wieder restlos entfernt (Backup vorher, Diff
hinterher verifiziert `IDENTISCH`). Ergebnis: **funktioniert grundsätzlich.**

- `borg init`/`create`/`list` liefen über die per Forced-Command gestartete
  `docker run ... serve`-Instanz erfolgreich durch.
- Append-Only hält: `delete`+`compact` mit dem (Backup-)Key gab keinen Platz
  frei (608K → 636K, sogar leicht gewachsen statt geschrumpft) — dieselbe
  Prüfung wie in `functional-test.sh`.
- Forced Command überschreibt tatsächlich jedes angeforderte Kommando (kein
  `whoami`, sondern `borg serve` lief).
- Zielverzeichnis (`/data/<name>`) wird von `borg init` selbst angelegt,
  keine vorherige `mkdir` nötig — die offene Frage von oben ist damit
  beantwortet.
- **Neuer Fund, der oben noch nicht auf dem Schirm war:** Existiert das
  Image lokal auf dem Host noch nicht, lädt `docker run` es beim ERSTEN
  Connect automatisch nach — inklusive Pull-Fortschritt, der (je nachdem,
  was der Client mitschneidet) im SSH-Kanal auftaucht. Für einen
  unbeaufsichtigten Cron-Backup-Lauf potenziell ein böses Erwachen (Timeout,
  unerwartete Verzögerung). Müsste durch ein explizites `docker pull` als
  Teil der Ersteinrichtung abgefangen werden, ist aber nirgends dokumentiert
  oder automatisiert.
- **Nicht getestet:** Admin-Key mit `--restrict-to-path` gegen mehrere
  Repos, Verhalten bei parallelen Verbindungen, tatsächliche Latenz pro
  Verbindung, das Docker-Rechte-Problem unten (der Test lief mit einem User,
  der ohnehin schon in der `docker`-Gruppe ist — die eigentliche Sicherheits-
  frage wurde dadurch nicht geprüft, nur die Funktionalität).

### Warum das reizvoll wäre

- Kein Dauerprozess, der offen im Netz hängt.
- **Kein `reload-keys.sh` nötig** — das System-`sshd` des Hosts liest
  `authorized_keys` sowieso bei jeder neuen Verbindung frisch von der
  Platte. Der ganze Mechanismus, den dieses Repo für Live-Reload ohne
  Neustart gebaut hat (`build-authorized-keys.sh` mit atomarem
  `mktemp`+`mv`, `reload-keys.sh`, Auto-Aufruf aus `add-backup-key.sh`),
  wäre für dieses Szenario von vornherein überflüssig.
- Kein `StrictModes`-Problem (siehe README "Manueller Modus") — die Datei
  liegt nativ auf dem Host, kein Bind-Mount mit fremder Ownership.
- Kein eigenes Server-Image mit `sshd_config.template`, PAM-Workaround,
  Multi-Stage-Build nötig — das eigentliche `borg serve` läuft im ohnehin
  vorhandenen `docker-borg-backup`-Client-Image.

### Warum es (noch) nicht umgesetzt ist

- **Größte Sorge: Rechte.** Damit das Forced Command `docker run` ausführen
  kann, braucht der SSH-User auf dem Host entweder Mitgliedschaft in der
  `docker`-Gruppe — das ist praktisch äquivalent zu Root auf dem Host
  (Docker-Doku warnt selbst davor) — oder ein eng gefasstes `sudo`-Rule für
  exakt diesen einen `docker run`-Befehl (kein Wildcard). Das aktuelle
  Setup braucht dagegen NIRGENDS Docker-Rechte für den SSH-User, weil
  `sshd` selbst schon im Container läuft. Dieser Modus würde also genau die
  Art von Rechteausweitung einführen, die die ganze bisherige Härtung
  (eigener Container, `restrict`, minimales Image) vermeiden sollte — ohne
  ein sorgfältig geprüftes `sudo`-Rule wäre das ein Rückschritt, kein
  Fortschritt.
- **Host-`sshd` statt Container-`sshd`:** aktuell müsste ein Angreifer bei
  einem hypothetischen `sshd`-Bug erst aus dem Container ausbrechen, bevor
  er den Host erreicht. Mit Host-`sshd` fehlt diese zusätzliche Stufe -
  der Netzwerk-Listener selbst ist nicht mehr containerisiert (der
  eigentliche `borg serve`-Prozess bliebe es zwar weiterhin, aber `sshd`
  nicht).
- Verzeichnis-Anlage (`/data/<name>` inkl. Rechte) passiert aktuell
  automatisch in `build-authorized-keys.sh` — in diesem Modus übernimmt
  das `borg init` selbst (getestet, siehe oben), dafür fehlt aber die
  bewusste Rechtevergabe, die `build-authorized-keys.sh` heute macht
  (`chown borg:borg`) - im Test lief alles als root im Container, ungeprüft,
  ob/wie sich das mit einem eingeschränkteren User sauber abbilden ließe.
- Host-Key-Management entfiele (der Host hat schon einen eigenen), koppelt
  damit aber die Identität des Backup-Zugangs an dieselbe Host-Identität,
  über die vermutlich auch normaler Admin-Login läuft - vermischt zwei
  Zwecke, die aktuell bewusst getrennt sind.
- **Kein Funktionstest möglich mit dem aktuellen, hermetischen Ansatz**
  (`functional-test.sh` startet einen isolierten Container und testet
  dagegen). Für diesen Modus bräuchte es einen echten `sshd` auf dem
  Testrunner mit einer echten `authorized_keys` — ungleich fragiler in CI,
  wurde nicht versucht.
- Latenz pro Verbindung (`docker run`-Start) ungemessen — für einen
  nächtlichen Cron-Backup vermutlich irrelevant, aber nicht verifiziert.

### Falls das trotzdem jemand ausprobieren will

Nichts davon ist Teil dieses Repos oder wird von `add-backup-key.sh`/
`reload-keys.sh`/`build-authorized-keys.sh` erzeugt — die Zeilen oben
müssten von Hand in die System-`authorized_keys` des jeweiligen Host-Users
eingetragen werden, inklusive eigener Lösung fürs Docker-Rechte-Problem
oben. Die Funktionalität (`init`/`create`/`list`, Append-Only-Grenze) ist
zwar einmalig manuell verifiziert (siehe oben), aber vor produktivem
Einsatz braucht es mehr:

- `docker pull ghcr.io/tabacha/docker-borg-backup:latest` explizit als Teil
  der Ersteinrichtung einplanen, NICHT auf den impliziten Pull beim ersten
  Connect verlassen (siehe Fund oben).
- Das Docker-Rechte-Setup (`docker`-Gruppe vs. eng gefasstes `sudo`-Rule)
  von jemandem mit Security-Erfahrung gegenlesen lassen, bevor es an einem
  echten, aus dem Internet erreichbaren Host hängt.
- Admin-Key mit mehreren Repos unter `/data` durchspielen, parallele
  Verbindungen, tatsächliche Latenz messen.
- Einen wiederholbaren, automatisierten Test dafür bauen (nicht nur den
  einmaligen manuellen Lauf von oben), bevor irgendwer sich darauf verlässt.
