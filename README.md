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
| `Dockerfile`                | Zweistufiger Build: Builder-Stage kompiliert Borg in venvs, Runtime-Stage (`openssh-server` + nur Laufzeit-Bibliotheken) enthält keinen Compiler/Header mehr. |
| `sshd_config.template`       | Minimal-Config: nur Pubkey-Auth, kein PAM, kein Shell-Zugriff für irgendeinen User. Krypto-Platzhalter, siehe "SSH-Härtung". |
| `compose.yml`                | Ein Service `borg-server`. Image kommt vorgebaut von GHCR, `build: .` ist Fallback. |
| `entrypoint.sh`              | Rendert `sshd_config` aus dem Template, baut beim Start `authorized_keys`, leitet den Hostkey-Public-Part ab, startet `sshd`. |
| `build-authorized-keys.sh`   | Erzeugt `authorized_keys` aus `keys/backup/*.pub` + `keys/admin/*.pub`, je mit passendem Forced Command (oder übernimmt `keys/manual/authorized_keys` 1:1, siehe "Manueller Modus"). Läuft beim Start UND bei Bedarf erneut im laufenden Container, siehe `reload-keys.sh`. |
| `setup-secrets.sh`           | Erzeugt einmalig `secrets/ssh_host_ed25519_key` (idempotent). |
| `add-backup-key.sh`          | Registriert einen neuen Backup-Client: `./add-backup-key.sh <name> <pubkey-datei>`. Ruft am Ende automatisch `reload-keys.sh` auf. |
| `add-admin-key.sh`           | Registriert einen neuen Admin-Key: `./add-admin-key.sh <name> <pubkey-datei>`. Ruft am Ende automatisch `reload-keys.sh` auf. |
| `reload-keys.sh`             | Baut `authorized_keys` im laufenden Container neu, ohne Neustart — unterbricht keine laufenden Sessions anderer Clients. Nach dem *manuellen* Löschen einer `.pub`-Datei selbst aufrufen. |
| `.env` / `.env.example`      | `SSH_PORT`, optionale `SSHD_*`-Krypto-Overrides. |
| `secrets/`                   | SSH-Hostkey dieses Servers. Pro Deployment eigen, nicht committen. |
| `keys/backup/`, `keys/admin/`| Public Keys der Clients/Admins. Pro Deployment eigen, nicht committen. |
| `keys/manual/`               | Optional: fertige `authorized_keys` von außen, siehe "Manueller Modus". Pro Deployment eigen, nicht committen. |
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
   direkt die passenden `.env`-Werte für den Client aus. Der Hinweis
   "Server läuft noch nicht" an dieser Stelle ist bei der Ersteinrichtung
   normal (Schritt 6 startet den Container erst) — kein Fehler.

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

   Jeder weitere `add-backup-key.sh`/`add-admin-key.sh`-Aufruf baut
   `authorized_keys` danach automatisch neu (`reload-keys.sh` wird am Ende
   der beiden Skripte selbst aufgerufen) — **ohne** den Container neu zu
   starten (wichtig, wenn gerade ein laufender Backup-Transfer eines
   anderen Clients nicht unterbrochen werden soll, siehe
   "Key-Rotation/-Entzug" unten). Nur beim *manuellen* Löschen einer
   `.pub`-Datei `./reload-keys.sh` selbst aufrufen.

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

### SSH-Härtung

`sshd_config.template` schränkt die Kryptografie in den Defaults bewusst eng
ein — dieser Server und der einzige erwartete Client (`docker-borg-backup`)
laufen auf demselben Debian/OpenSSH-Unterbau, es muss also keine Rücksicht
auf alte/fremde Clients genommen werden. `entrypoint.sh` rendert daraus bei
jedem Container-Start das echte `/etc/ssh/sshd_config` und lässt vier Werte
per Env überschreiben (`.env`, siehe `.env.example`):

| Env-Variable | Default | Bedeutung |
|---|---|---|
| `SSHD_PUBKEY_ALGORITHMS` | `ssh-ed25519,sk-ssh-ed25519@openssh.com` | Welche Client-Key-Typen akzeptiert werden. |
| `SSHD_KEX_ALGORITHMS` | `mlkem768x25519-sha256,curve25519-sha256` | Key-Exchange. |
| `SSHD_CIPHERS` | `chacha20-poly1305@openssh.com` | Verschlüsselung. |
| `SSHD_MACS` | `hmac-sha2-256-etm@openssh.com` | Nur relevant, falls `SSHD_CIPHERS` um eine Nicht-AEAD-Cipher erweitert wird. |

- **Nur Ed25519 in den Defaults** — alle Skripte in beiden Repos erzeugen
  ausschließlich Ed25519-Schlüssel. `sk-ssh-ed25519@openssh.com` ist
  zusätzlich erlaubt für FIDO2/Hardware-Token-Admin-Keys (siehe
  `docker-borg-backup`'s README-Empfehlung, den Admin-Key auf einem YubiKey
  zu halten).
- **RSA-YubiKey (PIV-Applet statt FIDO2) zulassen:** ein solcher Key taucht
  als normaler `ssh-rsa`-Typ auf, authentisiert aber über die moderneren
  SHA2-Signaturvarianten — dafür `SSHD_PUBKEY_ALGORITHMS` in der `.env` um
  `rsa-sha2-512,rsa-sha2-256` erweitern:
  ```bash
  SSHD_PUBKEY_ALGORITHMS=ssh-ed25519,sk-ssh-ed25519@openssh.com,rsa-sha2-512,rsa-sha2-256
  ```
  Danach `docker compose up -d` (Env-Änderungen brauchen einen echten
  Neustart, nicht nur `restart`, da Compose sonst ggf. die alte Umgebung
  weiterverwendet). Bewusst NICHT das legacy `ssh-rsa` (SHA1-Signatur aus
  alten OpenSSH-Zeiten) — nur die SHA2-Varianten.
  `add-backup-key.sh`/`add-admin-key.sh` prüfen beim Registrieren
  informativ (Warnung, kein Abbruch — die Zuordnung Algorithmus↔Key-Typ ist
  bei RSA nicht 1:1) gegen `SSHD_PUBKEY_ALGORITHMS` aus der `.env`.
- **Kex:** ML-KEM-Hybrid zuerst (Post-Quantum, seit OpenSSH 9.9), Curve25519
  als klassischer Fallback.
- **Cipher:** Default absichtlich nur `chacha20-poly1305@openssh.com` — ein
  AEAD-Cipher, kleinstmögliche Angriffsfläche, aber auch kein Fallback (siehe
  Kommentar in `sshd_config.template`, falls das mal geändert werden soll).
- **Kein fail2ban nötig:** OpenSSH bringt seit 9.8 mit `PerSourcePenalties`
  einen eingebauten Schutz gegen wiederholte Auth-Fehler pro Quelle mit,
  ganz ohne externen Daemon oder Firewall-Zugriff aus dem Container heraus.
- Außerdem u.a. `LoginGraceTime 20`, `MaxAuthTries 3`, `MaxSessions 2`,
  `Compression no`, `LogLevel VERBOSE` (protokolliert den Key-Fingerprint
  pro Login — bei nur einem System-User `borg` sonst die einzige
  Möglichkeit, Verbindungen im Log auseinanderzuhalten).

Jede Zeile ist mit `sshd -t`/`sshd -T` gegen die tatsächlich im Image
laufende OpenSSH-Version geprüft (nicht nur aus einer Anleitung übernommen)
— wer einen Override setzt oder die Defaults ändert, sollte das genauso
verifizieren, bevor der Container damit deployed wird (`entrypoint.sh` ruft
`sshd -t` selbst schon beim Start auf und bricht bei einem ungültigen Wert
klar ab, statt den Container in einem kaputten Zustand hochzufahren).

## Mehrere Clients

Ein Server kann mehrere Backup-Hosts bedienen — einfach für jeden einen
eigenen `add-backup-key.sh <name> ...` mit eindeutigem `<name>`, jeder landet
in seinem eigenen `/data/<name>`, `--restrict-to-repository` verhindert
strikt, dass ein Backup-Key auf das Repo eines anderen Clients zugreifen
kann (selbst wenn beide Repos existieren). Ein Admin-Key sieht dagegen alle.

## Manueller Modus: fertige `authorized_keys` von außen reinreichen

`add-backup-key.sh`/`add-admin-key.sh` decken den normalen Fall ab (ein Key
= ein Repo, append-only oder voller Zugriff). Für alles, was darüber
hinausgeht — mehrere Forced-Command-Varianten für denselben Key, eigene
`restrict`-Flags, eine bestehende `authorized_keys` von einem anderen Setup
übernehmen, Kommandos jenseits von `borg serve` — legt eine fertige Datei
unter `keys/manual/authorized_keys` ab:

```bash
mkdir -p keys/manual
cat > keys/manual/authorized_keys <<'EOF'
command="borg serve --append-only --restrict-to-repository /data/hostA",restrict ssh-ed25519 AAAA... hostA
command="borg serve --restrict-to-path /data",restrict ssh-ed25519 AAAA... admin1
EOF
./reload-keys.sh
```

**Sobald diese Datei existiert, wird sie 1:1 als `authorized_keys`
übernommen — `keys/backup/*.pub` und `keys/admin/*.pub` werden komplett
ignoriert.** `add-backup-key.sh`/`add-admin-key.sh` warnen davor, wenn der
manuelle Modus aktiv ist (der neu registrierte Key würde sonst wirkungslos
in `keys/backup/`/`keys/admin/` liegen bleiben). Zurück in den generierten
Modus: `keys/manual/authorized_keys` löschen, dann `./reload-keys.sh`.

`build-authorized-keys.sh` kopiert die Datei nur (kein Parsing, keine
Prüfung der Forced-Command-Syntax) — für Inhalt und Syntax bist du in
diesem Modus selbst verantwortlich; ein Tippfehler dort schlägt erst beim
tatsächlichen Verbindungsversuch fehl, nicht beim Reload selbst.

**Warum wird die Datei kopiert, statt `sshd` direkt auf den Mount zu
zeigen?** Das wäre naheliegend — sshd liest ohnehin bei jeder Verbindung
frisch, ein direkter Verweis bräuchte also nicht mal `./reload-keys.sh`.
Geht aber nicht: `sshd`s `StrictModes`-Prüfung verlangt, dass
`authorized_keys` dem Zieluser oder `root` gehört. Eine gemountete Datei
gehört aber dem UID, der sie auf dem *Host* angelegt hat — sshd verweigert
dann jede Anmeldung damit ("Authentication refused: bad ownership or modes
for file ..."), unabhängig vom Inhalt. Der Copy-Schritt (`chown`, `chmod
600`, atomar) übernimmt die Rechtekontrolle deshalb bewusst selbst,
unabhängig davon, wem die Quelldatei auf dem Host gehört — kostet dafür den
einen zusätzlichen `reload-keys.sh`-Aufruf nach jeder manuellen Änderung.

## Mehrere Borg-Versionen

Ähnlich wie Hetzners Storage Box mehrere Server-Binaries parallel anbietet
(dort z.B. `borg-1.4`), damit nicht jeder Client sofort auf die neueste
Server-Version migrieren muss, installiert das Image standardmäßig mehrere
Borg-Versionen nebeneinander (`BORG_VERSIONS` im `Dockerfile`, aktuell `1.4.5`
und `1.2.8`) — jede unter `/usr/local/bin/borg-<version>`, die
`BORG_DEFAULT_VERSION` zusätzlich ohne Suffix als `borg`.

Ohne weitere Angabe benutzt ein Key die Default-Version. Für eine bestimmte
Version stattdessen:

```bash
./add-backup-key.sh <name> /pfad/zu/pubkey 1.2.8
./add-admin-key.sh <name> /pfad/zu/pubkey 1.2.8
```

Das legt zusätzlich `keys/backup/<name>.version` (bzw. `keys/admin/...`) an —
`build-authorized-keys.sh` liest das beim nächsten Container-Start und trägt
für genau diesen Key `command="borg-1.2.8 serve ..."` statt `command="borg
serve ..."` ein. Eine angeforderte Version, die nicht installiert ist, lässt
den Container-Start mit einer klaren Fehlermeldung abbrechen (keine stille
falsche Version).

**Wichtig:** `BORG_REMOTE_PATH` in der `.env` des Clients ist dabei nur zur
Doku für Menschen gedacht — der Server ignoriert wegen des Forced Commands
ohnehin, was der Client tatsächlich anfragt, und benutzt immer die für den
jeweiligen Key hinterlegte Version. `add-backup-key.sh` gibt den passenden
`BORG_REMOTE_PATH`-Wert am Ende trotzdem mit aus, damit beide Seiten für
Menschen nachvollziehbar dieselbe Version nennen.

Zusätzliche Versionen bauen (compose.yml hat dafür keinen eigenen Build-Arg-
Mechanismus, direkt mit `docker build` arbeiten):

```bash
docker build --build-arg BORG_VERSIONS="1.4.5 1.2.8 1.1.18" -t <image-tag> .
```

Installierte Versionen in einem laufenden Container auflisten:

```bash
docker compose exec borg-server sh -c 'ls /usr/local/bin/borg-*'
```

## Key-Rotation/-Entzug ohne Unterbrechung laufender Sessions

Neuen Key eintragen: `add-backup-key.sh`/`add-admin-key.sh` rufen
`reload-keys.sh` am Ende automatisch selbst auf, kein weiterer Schritt
nötig. Nur beim *manuellen* Löschen/Ersetzen einer Datei unter
`keys/backup/` bzw. `keys/admin/` (z.B. `rm keys/backup/<name>.pub`)
danach selbst aufrufen:

```bash
./reload-keys.sh
```

Baut `authorized_keys` **im laufenden Container** neu, ganz ohne Neustart.
Das ist der Grund, warum es das Skript gibt: `sshd` liest `authorized_keys`
ohnehin bei jeder neuen Verbindung frisch von der Platte (kein
In-Memory-Cache über die Laufzeit des Daemons) — ein `docker compose
restart` war für diesen Zweck also nie nötig, hätte aber jeden gerade
laufenden Backup-Transfer eines *anderen*, weiterhin berechtigten Clients
mitten drin abgewürgt. `reload-keys.sh` betrifft nur *neue*
Verbindungsversuche; ein bereits laufender Transfer des soeben ausgetragenen
Clients läuft noch zu Ende (kein Kill bestehender Sessions) — für ein
sofortiges hartes Kappen müsste man den zugehörigen Prozess im Container
gezielt beenden, das deckt dieses Skript bewusst nicht ab.

`build-authorized-keys.sh` schreibt dafür in eine temporäre Datei und
ersetzt `authorized_keys` erst danach atomar (`mv` im selben Verzeichnis) —
sonst könnte eine zeitgleich eintreffende Verbindung mitten im Neuschreiben
eine leere Datei zu sehen bekommen.

Willst du am Repo selbst mitarbeiten (Skripte ändern, CI/Release-Pipeline)?
Siehe [DEVELOPMENT.md](DEVELOPMENT.md). Diskutierte, aber nicht
implementierte/nicht offiziell getestete Ideen (z.B. ein Modus ganz ohne
Dauercontainer) stehen in [EXPERIMENTAL.md](EXPERIMENTAL.md).
