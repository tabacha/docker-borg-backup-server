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
`build-authorized-keys.sh` baut daraus bei **jedem** Container-Start
`authorized_keys` komplett neu — Key-Rotation heißt also: Datei unter
`keys/` anlegen/löschen, `docker compose restart`.

### CI/Release-Pipeline

Analog zu `docker-borg-backup` (`ci.yml` bei jedem Push/PR, `release.yml` bei
Tags der Form `vX.Y.Z`, pusht nach `ghcr.io/tabacha/docker-borg-backup-server`).
Details in `DEVELOPMENT.md`.

## Sprache

Kommentare, Doku (README, Skript-Ausgaben, Commit-Messages, Release-Notes)
sind durchgehend Deutsch — dabei bleiben.
