# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Bash-Skripte + ein `Dockerfile`, die zusammen einen minimalen SSH-Server für
[Borg](https://borgbackup.org/) bilden: `borg serve` hinter `sshd`, gedacht
als selbst gehosteter Backup-Zielserver (statt z.B. einer Hetzner Storage
Box). Gegenstück zu [docker-borg-backup](https://github.com/tabacha/docker-borg-backup)
(dessen Client-Seite) — beide Repos setzen zusammen dessen "Sicherheit: zwei
Schlüssel gegen Ransomware"-Modell um, dieses Repo den serverseitigen Teil
davon (Forced Commands / Append-Only-Durchsetzung). Vollständige Doku in
`README.md`, Entwickler-Doku (lokale Checks, CI/Release-Pipeline) in
`DEVELOPMENT.md`.

## Git-Workflow

- **Nie direkt auf `main` pushen.** Immer einen Branch erstellen, darauf
  committen/pushen, PR öffnen.
- Branch-Namen immer mit vorangestelltem Datum: `YYYY-MM-DD_Kurzbeschreibung`.

## Validating changes

Kein klassisches Unit-Test-Framework, aber `.github/scripts/functional-test.sh`
ist ein echter Funktionstest — startet den Container wirklich (echter
`sshd`, echtes `borg serve`), verbindet sich per SSH von außen und prüft die
tatsächliche Sicherheitsgrenze (Forced Command, `--restrict-to-repository`
vs. `--restrict-to-path`, Append-Only), nicht nur "Verbindung klappt". Details
und alle Einzelbefehle (shellcheck/hadolint/actionlint/compose config) in
`DEVELOPMENT.md`.

Wichtige, beim Debuggen schon aufgetretene Stolperfallen:

- **`docker run -v "$(pwd):/ziel"`** kann in manchen Sandbox-Setups mit
  "mkdir ... file exists" fehlschlagen (Bind-Mount-Quirk) — betroffene
  Dateien dann in ein Scratch-Verzeichnis kopieren und von dort mounten.
- **hadolint gegen reines Stdin** (`docker run ... hadolint < Dockerfile`)
  findet `.hadolint.yaml` nicht und meldet DL3008 trotzdem — für einen Check
  inkl. Ignore-Liste die Config mitmounten (siehe `DEVELOPMENT.md`). Ist auch
  im ursprünglichen `docker-borg-backup` so, kein Bug hier.
- **Lokaler `ssh-agent` mit vielen Keys** lässt `functional-test.sh`s
  `ssh`-Aufrufe ohne `-o IdentitiesOnly=yes` in sshd's `MaxAuthTries` laufen,
  bevor der eigentliche Test-Key angeboten wird ("Too many authentication
  failures" statt einer aussagekräftigen Fehlermeldung).

## Architecture

### SSH-Kryptografie eng eingeschränkt, per Env überschreibbar, empirisch verifiziert

`sshd_config.template` ist kein fertiges Config-File, sondern hat vier
Platzhalter (`__PUBKEY_ALGORITHMS__`, `__KEX_ALGORITHMS__`, `__CIPHERS__`,
`__MACS__`), die `entrypoint.sh` bei jedem Container-Start per `sed` durch
`SSHD_PUBKEY_ALGORITHMS`/`SSHD_KEX_ALGORITHMS`/`SSHD_CIPHERS`/`SSHD_MACS`
(Env, Default falls unset) ersetzt und als `/etc/ssh/sshd_config`
rausschreibt - direkt danach `sshd -t`, damit ein Tippfehler in einem
Override den Start klar abbricht statt den Container kaputt hochzufahren.
`HostKeyAlgorithms` bleibt dagegen hart auf `ssh-ed25519` (nicht per Env
konfigurierbar) - das betrifft den eigenen Hostkey dieses Servers, der
immer Ed25519 ist (`setup-secrets.sh`), unabhängig davon, welche Client-Key-
Typen akzeptiert werden.

Defaults: nur Ed25519 (`ssh-ed25519,sk-ssh-ed25519@openssh.com` - Letzteres
für FIDO2-Admin-Keys, siehe `docker-borg-backup`-README-Empfehlung), Kex nur
`mlkem768x25519-sha256,curve25519-sha256`, und genau EIN Cipher
(`chacha20-poly1305@openssh.com`, bewusst ohne Fallback - siehe Kommentar in
`sshd_config.template`). Vertretbar eng, weil dieser Server und der einzige
erwartete Client (`docker-borg-backup`) auf demselben Debian/OpenSSH-Unterbau
laufen. `SSHD_PUBKEY_ALGORITHMS` existiert als Override primär für einen
RSA-YubiKey (PIV-Applet statt FIDO2) als Admin-Key - der taucht als
Key-TYP `ssh-rsa` auf, akzeptiert werden muss aber die SIGNATUR-Algorithmen
`rsa-sha2-512`/`rsa-sha2-256` (nicht 1:1 zum Key-Typ-String, siehe unten).

Wichtig beim Ändern der Defaults im Template: Nicht aus einer Anleitung
übernehmen ohne gegenzuprüfen, dass die konkret im Image laufende
OpenSSH-Version die Direktive überhaupt kennt - sonst startet `sshd` gar
nicht mehr. Verifizieren mit (Host-Key-Datei nötig, sonst bricht `sshd -T`
vorher mit "no hostkeys available" ab):

```bash
docker run --rm --entrypoint sh <image> -c '
  ssh-keygen -q -t ed25519 -f /tmp/k -N ""
  sshd -t -f /etc/ssh/sshd_config -o HostKey=/tmp/k   # oder: sshd -T -o HostKey=/tmp/k
'
```

`add-backup-key.sh`/`add-admin-key.sh` prüfen den Key-Typ beim Registrieren
(erstes Feld der `.pub`-Datei) gegen `SSHD_PUBKEY_ALGORITHMS` aus der
lokalen `.env` (Fallback: derselbe Default wie oben) - nur eine WARNUNG,
kein Abbruch, weil die Zuordnung Algorithmus↔Key-Typ bei RSA nicht 1:1 ist
(s.o.) und ein perfekter Check mehr Komplexität wäre als er wert ist. Ziel
ist nur, den häufigsten Fehler (z.B. ein RSA-Key ohne passenden
`SSHD_PUBKEY_ALGORITHMS`-Override) vor dem Neustart sichtbar zu machen.

Kein fail2ban: OpenSSH 9.8+ (dieses Image: 10.0p2) bringt mit
`PerSourcePenalties` einen äquivalenten, in `sshd` eingebauten Schutz gegen
wiederholte Auth-Fehler pro Quelle mit - kein externer Daemon, keine
Firewall-Capabilities im Container nötig.

### Env-Overrides brauchen Recreate, nicht nur Restart

`SSHD_*`-Variablen werden beim Container-Erstellen fixiert (Docker-Env ist
kein Live-Reload) - nach einer `.env`-Änderung braucht es `docker compose up
-d` (Compose erkennt die geänderte Konfiguration und recreated den
Container), ein reines `docker compose restart` reicht dafür NICHT. Für
Key-Änderungen (`keys/backup/`, `keys/admin/`) reicht `restart` dagegen aus,
weil die als Bind-Mount kommen und bei jedem Start neu von
`build-authorized-keys.sh` eingelesen werden - zwei Mechanismen, zwei
unterschiedliche "wie wende ich das an"-Antworten, nicht verwechseln.

### Kein Shell-Zugriff, für niemanden

Jeder Key in `authorized_keys` (egal ob Backup oder Admin) bekommt ein
Forced Command (`command="borg serve ..."`) plus `restrict`. Es gibt keine
interaktive Shell auf diesem Server — auch der Admin-Key bekommt keine.
`restrict` deaktiviert nebenbei Port-/Agent-Forwarding, PTY, X11. Die
Unterscheidung Backup- vs. Admin-Key passiert komplett über die Flags im
Forced Command, nicht über unterschiedliche User oder Container.

### `--restrict-to-repository` (Backup) vs. `--restrict-to-path` (Admin)

Leicht zu verwechseln, semantisch unterschiedlich:

- `--restrict-to-repository PATH`: erlaubt **exakt** `PATH`, keine
  Unterverzeichnisse. Für Backup-Keys — genau ein Repo pro Key.
- `--restrict-to-path PATH`: erlaubt `PATH` **und** Unterverzeichnisse. Für
  Admin-Keys — ein Admin muss mehrere Client-Repos unter `/data/<name1>`,
  `/data/<name2>`, ... erreichen können.

Wer hier `--restrict-to-repository /data` für den Admin-Key einsetzt (statt
`--restrict-to-path`), bricht den Mehrere-Clients-Anwendungsfall komplett —
das Admin-Serve würde dann nur noch exakt `/data` selbst als Repo erlauben,
kein `/data/<name>` mehr. Siehe `build-authorized-keys.sh`.

### Host-Key: kein `.pub` im Image, wird zur Laufzeit abgeleitet

Das `openssh-server`-Paket erzeugt beim Bauen automatisch Default-Hostkeys
inkl. `.pub` unter `/etc/ssh/`. Die werden im Dockerfile explizit gelöscht
(`rm -f /etc/ssh/ssh_host_*`) — sonst mountet `entrypoint.sh` zur Laufzeit
zwar den echten privaten Hostkey rein (aus `secrets/` auf dem Host,
persistent über Neustarts), der alte `.pub` aus dem Image passt dann aber
nicht mehr dazu und `sshd` verweigert mit "Public key ... does not match
private key" den Start. `entrypoint.sh` leitet den Public Part deshalb bei
jedem Start frisch per `ssh-keygen -y` vom (read-only gemounteten) privaten
Key ab, statt ein zweites File zu verteilen/mounten.

### `UsePAM no` + `usermod -p '*'`

`useradd` ohne `-p` legt den `borg`-User mit gesperrtem Passwort-Hash (`!`)
an. Mit PAM aktiv (sshd-Default) prüft `sshd` trotz reiner Pubkey-Auth
zusätzlich den Account-Status und lehnt mit "account is locked" ab — selbst
wenn die Public-Key-Prüfung selbst erfolgreich wäre. Fix ist zweifach:
`UsePAM no` in `sshd_config` (PAM komplett aus, unnötig für einen
Container ohne Passwort-Login) und zusätzlich `usermod -p '*'` im
Dockerfile als Absicherung, falls PAM doch mal wieder aktiviert wird.

### Mehrere Borg-Versionen (`BORG_VERSIONS` im Dockerfile)

Wie Hetzners Storage Box (mehrere Server-Binaries wie `borg-1.4`): das Image
installiert mehrere Borg-Versionen parallel, je in einem eigenen venv unter
`/opt/borg-<version>` (pip kann pro Umgebung nur eine Version eines Pakets
halten), verlinkt als `/usr/local/bin/borg-<version>`.
`BORG_DEFAULT_VERSION` bekommt zusätzlich den Symlink ohne Suffix (`borg`).
Welche Version ein Key benutzt, wird NICHT vom Client zur Verbindungszeit
bestimmt (das würde den Sinn des Forced Command unterlaufen), sondern vom
Admin beim Registrieren (`add-backup-key.sh <name> <pubkey> [version]`) fest
verdrahtet — landet in `keys/backup/<name>.version`,
`build-authorized-keys.sh` liest das und traegt für genau diesen Key
`command="borg-<version> serve ..."` statt `command="borg serve ..."` ein.
Eine angeforderte Version, die nicht installiert ist, lässt
`build-authorized-keys.sh` (und damit den Container-Start) mit klarer
Fehlermeldung abbrechen statt still auf die Default-Version umzufallen.

### Datenhaltung: `/data` als eigenes (nicht `external:`) Volume

Anders als `docker-borg-backup`s Cache/Config-Volumes (dort `external: true`,
weil der Client sie nur zwischenspeichert) besitzt dieses Repo die
Backup-Daten selbst — `/data` ist ein normales, von Compose verwaltetes
Volume.

### Ein Compose-Service, Keys per Bind-Mount

`compose.yml` definiert nur den Service `borg-server`. `keys/backup/` und
`keys/admin/` werden read-only in den Container gemountet;
`build-authorized-keys.sh` baut daraus `authorized_keys` komplett neu — beim
Container-Start (via `entrypoint.sh`) UND jederzeit erneut im laufenden
Container (`reload-keys.sh`, siehe nächster Abschnitt).

### `reload-keys.sh`: Key-Rotation ohne Container-Neustart

`sshd` liest `authorized_keys` bei jeder neuen Verbindung frisch von der
Platte (kein In-Memory-Cache über die Laufzeit des Daemons) - ein
Container-Neustart war für einen Key-Reload nie technisch nötig, hätte aber
jeden gerade laufenden Backup-Transfer eines ANDEREN Clients mitten drin
abgewürgt (`docker compose restart` killt den Container-Prozess und damit
jede offene `borg serve`-Session, nicht nur neue Verbindungsversuche).
`reload-keys.sh` ruft stattdessen `build-authorized-keys.sh` per `docker
compose exec` im laufenden Container erneut auf - kein Signal an `sshd`,
kein Prozess-Neustart, nur die Datei wird aktualisiert.

Deshalb schreibt `build-authorized-keys.sh` NICHT mehr direkt in
`authorized_keys`, sondern über `mktemp` in eine Tmp-Datei im selben
Verzeichnis + abschließendes `mv` (atomares `rename(2)`, da gleiches
Dateisystem) - ohne das könnte eine zeitgleich eintreffende SSH-Verbindung
mitten im Neuschreiben eine leere oder unvollständige Datei lesen. Ein
`trap ... EXIT` räumt die Tmp-Datei auf, falls das Skript vorher abbricht
(z.B. `resolve_borg_binary()` mit `exit 1` bei einer nicht installierten
Borg-Version).

Wichtig: das entfernt nur die Möglichkeit, sich NEU zu verbinden - eine
bereits laufende Session des ausgetragenen Keys läuft weiter, bis sie von
selbst endet. Ein hartes Kappen (Prozess im Container gezielt killen) deckt
`reload-keys.sh` bewusst nicht ab.

`SSHD_PUBKEY_ALGORITHMS`/`SSHD_KEX_ALGORITHMS`/`SSHD_CIPHERS`/`SSHD_MACS`
(siehe Env-Overrides oben) sind davon UNABHÄNGIG - die werden nur beim
Container-*Erstellen* gelesen, dafür bleibt `docker compose up -d` nötig,
`reload-keys.sh`/`restart` reichen dafür nicht.

### Zweistufiger Dockerfile-Build (Builder/Runtime getrennt)

Motivation: Compiler/Header/pip-Cache sollen nicht im ausgelieferten Image
landen (Angriffsfläche für "living off the land" nach einer Kompromittierung
reduzieren). Ein Single-Stage-Image mit nachträglichem `apt-get purge` lässt
sich nicht sauber davon befreien - `dpkg` verweigert, sich selbst zu
entfernen, und gelöschte Dateien bleiben ohnehin in früheren Layern
erhalten. Multi-Stage ist der korrekte Weg: nur was per `COPY --from=builder`
explizit rübergeholt wird, landet im Endergebnis.

- **Builder-Stage** (`FROM python:3.14-slim AS builder`): installiert
  `build-essential`/`pkg-config`/die `-dev`-Header, baut pro `BORG_VERSIONS`-
  Eintrag ein eigenes venv unter `/opt/borg-<version>`. Das venv-eigene
  `python3`-Binary ist ein SYMLINK auf die Basis dieses Images (kein
  `python3 -m venv --copies`) - funktioniert nur, weil die Runtime-Stage
  exakt dieselbe Basis (`python:3.14-slim`, dieselbe Tag-Version) hat. Ein
  Wechsel der Runtime-Stage auf eine andere Basis (z.B. `debian:trixie-slim`
  ohne Python) würde die kopierten venvs kaputt machen, weil der
  symlink-Zielpfad dann fehlt - deshalb bewusst NICHT gemacht, obwohl das
  nochmal Platz sparen würde (siehe unten).
- **Runtime-Stage** (`FROM python:3.14-slim`, frisch, keine Builder-Historie):
  installiert nur `openssh-server` + die per `ldd` gegen die tatsächlich
  gebauten `.so`-Extensions ermittelten Laufzeit-Bibliotheken (`libssl3t64`,
  `libacl1`, `liblz4-1`, `libxxhash0`, `libzstd1`, `zlib1g`) - NICHT geraten,
  sondern empirisch verifiziert (`find /opt -name '*.so' -exec ldd {} \;`).
  `openssh-server` zieht `openssh-client` automatisch als Depends mit (auch
  mit `--no-install-recommends`, das blendet nur Recommends/Suggests aus) -
  wichtig, weil `entrypoint.sh` `ssh-keygen` daraus braucht.
- **`apt`/`dpkg`/`perl-base`/`systemd` bleiben trotzdem im Image** - die sind
  Teil der `python:3.14-slim`-Basis selbst (jedes Debian-basierte Image
  braucht seinen eigenen Paketmanager), nicht etwas, das WIR zusätzlich
  installiert haben. Sie ganz loszuwerden bräuchte eine komplett andere
  (nicht-Debian-)Basis für die Runtime-Stage - dann bricht aber der
  venv-Symlink-Mechanismus (s.o.), müsste also gegen ein `--copies`-venv
  oder ein manuelles Kopieren der Python-Stdlib eingetauscht werden. Bewusst
  nicht gemacht: deutlich größerer, riskanterer Schritt für vergleichsweise
  wenig zusätzlichen Gewinn (gemessen: 220 MB -> 204 MB durch das
  Entfernen von Compiler/Headern allein).

### CI/Release-Pipeline

Analog zu `docker-borg-backup` (`ci.yml` bei jedem Push/PR, `release.yml` bei
Tags der Form `vX.Y.Z`, pusht nach `ghcr.io/tabacha/docker-borg-backup-server`).
Details in `DEVELOPMENT.md`.

## Sprache

Kommentare, Doku (README, Skript-Ausgaben, Commit-Messages, Release-Notes)
sind durchgehend Deutsch — dabei bleiben.
