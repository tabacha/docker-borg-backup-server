# docker-borg-backup-server

> Dieses Projekt wurde mit KI-Unterstützung (Claude Code) erstellt. Ich habe
> alles grob gereviewt, aber nicht jede Zeile im Detail geprüft — bei
> sicherheitsrelevanten Teilen (SSH-Härtung, Forced Commands unten) selbst
> nochmal genau hinschauen, bevor du das produktiv einsetzt.

Gegenstück zu [docker-borg-backup](https://github.com/tabacha/docker-borg-backup):
ein Container, der NUR einen SSH-Server für [Borg](https://borgbackup.org/)
bereitstellt (`borg serve`), auf einem beliebigen Host als eigener
Backup-Zielserver — statt z.B. einer Hetzner Storage Box. Kein Shell-Zugriff
für irgendeinen Key, keine Anwendungslogik außer "Keys registrieren, Repos
verwalten". Die eigentlichen Backup-/Restore-/Wartungs-Skripte laufen auf der
Client-Seite (siehe `docker-borg-backup`).

## Warum ein eigenes Repo (statt in `docker-borg-backup` einzubauen)

- **Andere Maschine:** Dieses Repo läuft auf dem Backup-*Ziel*-Server,
  `docker-borg-backup` auf dem Host, der gesichert *wird*.
- **Anderes Bedrohungsmodell:** Hier geht es um eingehende, nicht
  vertrauenswürdige SSH-Verbindungen absichern (Forced Commands, Hostkey-
  Verwaltung), nicht um "Client greift kontrolliert nach draußen".
- Beide Repos halten sich an dieselbe Zwei-Schlüssel-Logik (siehe
  `docker-borg-backup`'s README → "Sicherheit: zwei Schlüssel gegen
  Ransomware") — dieses Repo ist die serverseitige Umsetzung davon.

## Verzeichnisstruktur

| Pfad                      | Zweck                                                              |
|-----------------------------|--------------------------------------------------------------------|
| `Dockerfile`                | Baut das Image: `openssh-server` + Borg (Client *und* Server-Teil, `borg serve` braucht denselben Binary). |
| `sshd_config`                | Minimal-Config: nur Pubkey-Auth, kein PAM, kein Shell-Zugriff für irgendeinen User. |
| `compose.yml`                | Ein Service `borg-server`. Image kommt vorgebaut von GHCR, `build: .` ist Fallback. |
| `entrypoint.sh`              | Baut beim Start `authorized_keys` neu, leitet den Hostkey-Public-Part ab, startet `sshd`. |
| `build-authorized-keys.sh`   | Erzeugt `authorized_keys` aus `keys/backup/*.pub` + `keys/admin/*.pub`, je mit passendem Forced Command. |
| `setup-secrets.sh`           | Erzeugt einmalig `secrets/ssh_host_ed25519_key` (idempotent). |
| `add-backup-key.sh`          | Registriert einen neuen Backup-Client: `./add-backup-key.sh <name> <pubkey-datei>`. |
| `add-admin-key.sh`           | Registriert einen neuen Admin-Key: `./add-admin-key.sh <name> <pubkey-datei>`. |
| `.env` / `.env.example`      | Nur `SSH_PORT`. |
| `secrets/`                   | SSH-Hostkey dieses Servers. Pro Deployment eigen, nicht committen. |
| `keys/backup/`, `keys/admin/`| Public Keys der Clients/Admins. Pro Deployment eigen, nicht committen. |
| `DEVELOPMENT.md`             | Für Mitarbeit am Repo selbst: lokale Checks, CI/Release-Pipeline. |

## Ersteinrichtung

1. **Repo klonen:**

   ```bash
   git clone git@github.com:tabacha/docker-borg-backup-server.git
   ```

2. **`.env` anlegen** (nur der Host-Port ist konfigurierbar):

   ```bash
   cp .env.example .env
   ```

3. **Hostkey erzeugen** — die SSH-Identität dieses Servers, muss über
   Neustarts hinweg stabil bleiben (sonst "REMOTE HOST IDENTIFICATION HAS
   CHANGED" bei jedem Client):

   ```bash
   ./setup-secrets.sh
   ```

   Den ausgegebenen Fingerprint auf jedem Client in `secrets/known_hosts`
   hinterlegen (siehe `docker-borg-backup` → `setup-secrets.sh`), oder direkt
   per `ssh-keyscan -p <SSH_PORT> <dieser-host>` vom Client aus abholen.

4. **Mindestens einen Backup-Key registrieren** — der Public Key kommt vom
   Client (`docker-borg-backup`'s `secrets/backup_ed25519.pub`, per
   `setup-secrets.sh` dort erzeugt):

   ```bash
   ./add-backup-key.sh <client-name> /pfad/zu/backup_ed25519.pub
   ```

   `<client-name>` wird zum Verzeichnisnamen unter `/data` (das Repo dieses
   Clients) — nur Buchstaben, Ziffern, `_`, `-`. Das Skript gibt am Ende
   direkt die passenden `.env`-Werte für den Client aus.

5. **Optional: einen Admin-Key registrieren** (für `admin-compact.sh` /
   `admin-shell.sh` aus `docker-borg-backup`, per Agent-Forwarding, NIE als
   Datei ablegen):

   ```bash
   ./add-admin-key.sh <name> /pfad/zu/admin_key.pub
   ```

6. **Docker-Volume + Image:**

   ```bash
   docker compose pull   # oder: docker compose build
   docker compose up -d
   ```

   Jeder weitere `add-backup-key.sh`/`add-admin-key.sh`-Aufruf braucht danach
   nur noch `docker compose restart`, damit `authorized_keys` neu gebaut
   wird.

## Sicherheitsmodell

Jeder Key — Backup wie Admin — bekommt in `authorized_keys` ein **Forced
Command** plus `restrict`. Es gibt für niemanden eine interaktive Shell auf
diesem Server, auch nicht für den Admin-Key: `restrict` schaltet nebenbei
Port-/Agent-Forwarding, PTY und X11 ab, egal was der Client anfragt.

| Key-Typ | Forced Command | Bedeutung |
|---|---|---|
| Backup (`keys/backup/<name>.pub`) | `borg serve --append-only --restrict-to-repository /data/<name>` | Nur dieses eine Repo, nur anhängen — nichts endgültig löschen (siehe `docker-borg-backup`'s README "Sicherheit: zwei Schlüssel gegen Ransomware"). `--restrict-to-repository` erlaubt exakt diesen einen Pfad, keine Unterverzeichnisse. |
| Admin (`keys/admin/<name>.pub`) | `borg serve --restrict-to-path /data` | Voller Zugriff (`prune`/`delete`/`compact`) auf jedes Repo unter `/data` — `--restrict-to-path` erlaubt (im Unterschied zu `--restrict-to-repository`) Unterverzeichnisse, genau das braucht ein Admin, der mehrere Client-Repos verwaltet. Trotzdem kein Ausbruch aus `/data`, keine Shell. |

Der Witz an Append-Only: `borg delete`/`borg prune` mit dem Backup-Key laufen
durch (Exit 0), hinterlassen aber nur einen Löschvermerk. `borg compact` mit
demselben Key läuft ebenfalls mit Exit 0 durch, gibt aber **keinen** Platz
frei — erst ein Aufruf mit dem Admin-Key kompaktiert wirklich (getestet in
`.github/scripts/functional-test.sh`, das genau diesen Unterschied an der
tatsächlichen Repo-Größe auf der Platte prüft, nicht nur am Exit-Code).

## Mehrere Clients

Ein Server kann mehrere Backup-Hosts bedienen — einfach für jeden einen
eigenen `add-backup-key.sh <name> ...` mit eindeutigem `<name>`, jeder landet
in seinem eigenen `/data/<name>`, `--restrict-to-repository` verhindert
strikt, dass ein Backup-Key auf das Repo eines anderen Clients zugreifen
kann (selbst wenn beide Repos existieren). Ein Admin-Key sieht dagegen alle.

## Sonstiges

- **`/data`** ist ein normales (nicht `external:`) Compose-Volume — dieses
  Repo besitzt die Backup-Daten selbst, anders als `docker-borg-backup`'s
  Cache/Config-Volumes.
- **FUSE (`borg mount`)** ist hier nicht relevant — das läuft ausschließlich
  clientseitig in `docker-borg-backup`, dieser Server spricht nur das
  Borg-Serve-Protokoll.
- **Key-Rotation/-Entzug:** Datei unter `keys/backup/` bzw. `keys/admin/`
  löschen oder ersetzen, dann `docker compose restart` — `authorized_keys`
  wird bei jedem Start komplett neu gebaut.

Willst du am Repo selbst mitarbeiten (Skripte ändern, CI/Release-Pipeline)?
Siehe [DEVELOPMENT.md](DEVELOPMENT.md).
