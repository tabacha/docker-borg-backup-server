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
  failures" statt einer aussagekräftigen Fehlermeldung). Betrifft nicht nur
  Tests: ein echter Admin mit vielen Keys im Agent kann sich real
  aussperren, siehe `SSHD_MAX_AUTH_TRIES` weiter unten.
- **`AuthorizedKeysFile` außerhalb von `~/.ssh` muss weltlesbar sein
  (644), nicht `600`** — empirisch gefunden, nicht aus einer Anleitung:
  sshd öffnet eine `authorized_keys`-Datei, die NICHT unter dem Home-
  Verzeichnis des `%u` liegt, über einen unprivilegierten Preauth-Prozess,
  der auf die UID der einloggenden Identität fallen kann. Root:root + 600
  ergibt dann "Could not open ... Permission denied", obwohl `docker exec
  cat` dieselbe Datei problemlos liest (der läuft ja tatsächlich als root).
  Kein Sicherheitsproblem: Inhalt ist Pubkey + Forced Command, nicht
  geheim; root:root-Ownership (also root-exklusives SCHREIBEN) bleibt
  unverändert. Siehe `build-authorized-keys.sh`.
- **`pipefail` + `grep -q` auf eine ERWARTET fehlschlagende Pipe**: ein
  Muster wie `ssh ... | grep -q "Permission denied"` als `if`-Bedingung
  liefert unter `set -o pipefail` fälschlich "kein Treffer", selbst wenn
  `grep` den Treffer findet — `pipefail` kippt die Pipeline, sobald
  IRGENDEIN Glied nicht-null exitet (hier: `ssh` selbst, exit 255, by
  design), nicht nur wenn das letzte Glied (`grep`) fehlschlägt. Fix:
  Ausgabe erst in eine Variable einfangen (`out="$(ssh ... 2>&1 || true)"`),
  dann separat `grep` drauf. Siehe `functional-test.sh`s `wait_for_sshd()`.
- **Gruppenbasierter Zugriff (z.B. `borgadmins` auf `/data/<name>`) braucht
  Setgid UND einen passenden `--umask`, nicht nur `chmod g+...` auf dem
  Verzeichnis selbst**: ein Verzeichnis kann `770`/Gruppe `borgadmins` sein
  — neue DATEIEN darin erben trotzdem nur die primäre Gruppe des
  erzeugenden Prozesses (nicht automatisch die Verzeichnisgruppe) UND
  Borgs Standard-`--umask` (`0077`) streicht Gruppen-Bits bei jeder neuen
  Datei ohnehin sofort weg. Erst Setgid (`chmod 2770`) PLUS `--umask 0007`
  im Forced Command zusammen ergeben tatsächlichen Gruppenzugriff auf
  einzelne Repo-Dateien, nicht nur aufs Verzeichnis selbst.

## Architecture

### SSH-Kryptografie eng eingeschränkt, per Env überschreibbar, empirisch verifiziert

`sshd_config.template` ist kein fertiges Config-File, sondern hat fünf
Platzhalter (`__PUBKEY_ALGORITHMS__`, `__KEX_ALGORITHMS__`, `__CIPHERS__`,
`__MACS__`, `__MAX_AUTH_TRIES__`), die `entrypoint.sh` bei jedem
Container-Start per `sed` durch
`SSHD_PUBKEY_ALGORITHMS`/`SSHD_KEX_ALGORITHMS`/`SSHD_CIPHERS`/`SSHD_MACS`/
`SSHD_MAX_AUTH_TRIES` (Env, Default falls unset) ersetzt und als
`/etc/ssh/sshd_config` rausschreibt - direkt danach `sshd -t`, damit ein
Tippfehler in einem Override den Start klar abbricht statt den Container
kaputt hochzufahren. `HostKeyAlgorithms` bleibt dagegen hart auf
`ssh-ed25519` (nicht per Env konfigurierbar) - das betrifft den eigenen
Hostkey dieses Servers, der immer Ed25519 ist (`setup-secrets.sh`),
unabhängig davon, welche Client-Key-Typen akzeptiert werden.

`AuthorizedKeysFile` zeigt bewusst NICHT auf `~/.ssh/authorized_keys`,
sondern auf `/etc/ssh/authorized_keys/%u` (root-verwaltet, siehe
`build-authorized-keys.sh` weiter unten) - `$HOME` ist bei Backup-Clients
`/data/<name>`, also derselbe Baum, den `borg serve` für diese Identität
beschreiben darf; eine authorized_keys-Datei dort läge unnötig nah an dem,
was ein kompromittierter Client ohnehin schon anfassen kann.
`AllowGroups borgusers` ersetzt das frühere `AllowUsers borg` - Identitäten
entstehen jetzt dynamisch, eine feste Namensliste geht nicht mehr. Die
Gruppe wird ausschließlich von `build-authorized-keys.sh` befüllt (nie von
irgendwo sonst), das ist der eigentliche Durchsetzungspunkt, nicht die
Gruppe selbst.

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
Änderungen unter `users/` reicht sogar `reload-keys.sh` (nicht mal ein
`restart`), weil die als Bind-Mount kommen und jederzeit neu von
`build-authorized-keys.sh` eingelesen werden können - zwei Mechanismen,
zwei unterschiedliche "wie wende ich das an"-Antworten, nicht verwechseln.

### Kein Shell-Zugriff, für niemanden

Jeder Key in jeder `authorized_keys/<name>`-Datei (egal ob Backup- oder
Admin-Rolle) bekommt ein Forced Command (`command="borg serve ..."`) plus
`restrict`. Es gibt keine interaktive Shell auf diesem Server — auch kein
Admin-Account bekommt eine. `restrict` deaktiviert nebenbei
Port-/Agent-Forwarding, PTY, X11. Die Unterscheidung Backup- vs.
Admin-Rolle passiert über die Flags im Forced Command (jede Identität hat
GENAU eine Rolle, siehe unten) - seit der Multi-User-Isolation zusätzlich
über unterschiedliche Unix-Accounts, nicht mehr nur über den Inhalt eines
gemeinsamen Forced Command wie frueher.

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

### Ein Unix-Account pro Identität (`users/<uid>-<name>/`)

Ursprünglich (vor der Multi-User-Isolation) gab es genau einen Unix-User
`borg` für alle Backup- und Admin-Keys, Isolation lief ausschließlich über
`--restrict-to-repository` im Forced Command. Jetzt bekommt jede Identität
(Backup-Client ODER Admin) einen eigenen Unix-Account, dynamisch von
`build-authorized-keys.sh` bei jedem Start/Reload angelegt - Defense in
Depth: selbst ein kompromittierter `borg serve`-Prozess eines Clients kommt
mangels Unix-Rechten nicht an ein fremdes `/data/<name>` heran, unabhängig
davon, ob die SSH/Borg-Protokoll-Ebene (`--restrict-to-repository`) selbst
fehlerfrei ist.

**Layout:** `users/<uid>-<name>/keys/{backup,admin}/<key>.pub` (+ optional
`<key>.version`, `<key>.from` daneben). `<uid>` steht bewusst EXPLIZIT im
Verzeichnisnamen, nicht vom Container gewürfelt - `/data/<name>` ist ein
persistentes Volume, eine bei jedem Neustart neu vergebene UID würde die
Ownership-Zuordnung nach einer Neuerstellung des Containers zerreißen. Wer
`<uid>-<name>` anlegt (`add-backup-key.sh`/`add-admin-key.sh` oder von
Hand), legt die UID damit einmalig und dauerhaft fest. Erlaubter Bereich
**1000–2000** (`MIN_UID`/`MAX_UID` in `build-authorized-keys.sh`,
gespiegelt in beiden `add-*-key.sh`-Skripten) - kein sshd-natives Äquivalent
zu "nur UID-Bereich X-Y darf sich verbinden" vorhanden (Allow/Deny-
Direktiven kennen nur Namen-/Gruppenmuster), die Grenze wird deshalb
ausschließlich dort durchgesetzt, wo Accounts entstehen.

Mehrere `*.pub`-Dateien im selben `keys/backup/`/`keys/admin/` sind mehrere
gleichzeitig gültige Keys für DIESELBE Identität (Rotation, mehrere Geräte)
- kein Sondermechanismus dafür nötig, ergibt sich einfach aus dem Layout.

**Zwei-Phasen-Ausführung, bewusst getrennt** (`validate_all()` /
`apply_all()` in `build-authorized-keys.sh`): Phase 1 liest nur, verändert
nichts, sammelt ALLE Fehler statt beim ersten abzubrechen. Findet sich
dabei auch nur EIN harter Fehler (doppelt vergebene UID/Name, UID außerhalb
1000-2000, eine Identität mit Keys in sowohl `keys/backup/` als auch
`keys/admin/`, eine nicht installierte Borg-Version), wird GAR NICHTS
angewendet - weder ein neuer Account angelegt noch eine bestehende
`authorized_keys/<name>`-Datei verändert. Läuft der Container schon, bleibt
der zuletzt gültige Stand vollständig unangetastet (ein Tippfehler bei
einer Identität legt nicht den Zugriff aller anderen lahm); startet der
Container gerade erst, verhindert das `set -e` in `entrypoint.sh` den Start
komplett. Erst wenn Phase 1 fehlerfrei durchläuft, legt Phase 2 fehlende
Accounts/`/data/<name>` an und schreibt die `authorized_keys/<name>`-Dateien
neu.

**Entzug löscht nie Daten:** verschwindet eine Identität komplett aus
`users/` (oder verliert ihren letzten Key), entfernt `apply_all()` nur ihre
`/etc/ssh/authorized_keys/<name>`-Datei - der Unix-Account und
`/data/<name>` bleiben unangetastet. Ein versehentlich gelöschtes
`users/`-Verzeichnis darf niemals zu verlorenen Backup-Daten führen.

**`AuthorizedKeysFile` außerhalb `~/.ssh` braucht 644, nicht 600** -
empirisch gefunden (siehe "Stolperfallen" oben unter "Validating changes"):
root:root + 600 ergibt "Permission denied", weil sshd eine solche Datei
über einen unprivilegierten, auf die Ziel-UID fallenden Preauth-Prozess
liest. Root:root bleibt trotzdem der Owner - nur SCHREIBZUGRIFF ist
exklusiv, der Inhalt (Pubkey + Forced Command) ist ohnehin nicht geheim.

**Admin-Zugriff auf fremde Repos (`borgadmins`-Gruppe):** `--restrict-to-path
/data` im Forced Command allein reicht nicht - ohne zusätzliche Unix-Rechte
würde ein Admin-Account an der Dateisystem-Berechtigung eines fremden,
700-geschützten `/data/<name>` scheitern. Jeder Admin-Account ist deshalb
zusätzlich Mitglied der Gruppe `borgadmins`; jedes Backup-Client-`/data/<name>`
gehört gruppenseitig `borgadmins` (Owner bleibt der Client selbst). Reicht
für sich allein aber noch nicht: **Setgid** (`chmod 2770`, nicht nur `770`)
ist nötig, damit NEUE Dateien darin die Verzeichnisgruppe erben (sonst
erben sie die private Gruppe des erzeugenden Prozesses), UND **`--umask
0007`** im Forced Command (statt Borgs Default `0077`), weil der Default-
Umask Gruppen-Bits bei jeder neu angelegten Datei sonst sofort wieder
wegstreicht. Erst alle drei Zutaten zusammen (Gruppenmitgliedschaft +
Setgid + Umask) ergeben tatsächlichen Admin-Zugriff auf einzelne
Repo-Dateien, nicht nur aufs Verzeichnis selbst - per
`.github/scripts/functional-test.sh` empirisch verifiziert (Admin
kompaktiert ein fremdes, vom Backup-Client selbst angelegtes Repo).

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

`useradd` ohne `-p` legt einen Account mit gesperrtem Passwort-Hash (`!`)
an. Mit PAM aktiv (sshd-Default) prüft `sshd` trotz reiner Pubkey-Auth
zusätzlich den Account-Status und lehnt mit "account is locked" ab — selbst
wenn die Public-Key-Prüfung selbst erfolgreich wäre. Fix ist zweifach:
`UsePAM no` in `sshd_config` (PAM komplett aus, unnötig für einen
Container ohne Passwort-Login) und zusätzlich `usermod -p '*'` als
Absicherung, falls PAM doch mal wieder aktiviert wird - seit der
Multi-User-Isolation nicht mehr einmalig im Dockerfile (kein statischer
User mehr im Image), sondern in `build-authorized-keys.sh` direkt nach
jedem dynamischen `useradd`.

### Mehrere Borg-Versionen (`BORG_VERSIONS` im Dockerfile)

Wie Hetzners Storage Box (mehrere Server-Binaries wie `borg-1.4`): das Image
installiert mehrere Borg-Versionen parallel, je in einem eigenen venv unter
`/opt/borg-<version>` (pip kann pro Umgebung nur eine Version eines Pakets
halten), verlinkt als `/usr/local/bin/borg-<version>`.
`BORG_DEFAULT_VERSION` bekommt zusätzlich den Symlink ohne Suffix (`borg`).
Welche Version ein Key benutzt, wird NICHT vom Client zur Verbindungszeit
bestimmt (das würde den Sinn des Forced Command unterlaufen), sondern beim
Registrieren fest verdrahtet (`add-backup-key.sh <name> <pubkey> --version
<v>`) — landet als `<key>.version` NEBEN der jeweiligen `.pub`-Datei unter
`users/<uid>-<name>/keys/.../`, `build-authorized-keys.sh`s
`resolve_borg_binary()` liest das pro KEY (nicht pro Identität - bei
mehreren Keys derselben Identität, z.B. während einer Rotation, kann jeder
seine eigene Version haben) und trägt `command="borg-<version> serve ..."`
statt `command="borg serve ..."` ein. Eine angeforderte Version, die nicht
installiert ist, ist ein harter Fehler in `validate_all()` (siehe oben) -
verhindert die GESAMTE Aktualisierung, nicht nur die eine Identität.

### Datenhaltung: `/data` als eigenes (nicht `external:`) Volume

Anders als `docker-borg-backup`s Cache/Config-Volumes (dort `external: true`,
weil der Client sie nur zwischenspeichert) besitzt dieses Repo die
Backup-Daten selbst — `/data` ist ein normales, von Compose verwaltetes
Volume.

### Ein Compose-Service, `users/` per Bind-Mount

`compose.yml` definiert nur den Service `borg-server`. `users/` wird
read-only in den Container gemountet; `build-authorized-keys.sh` baut
daraus alle Accounts + `authorized_keys/<name>`-Dateien komplett neu — beim
Container-Start (via `entrypoint.sh`) UND jederzeit erneut im laufenden
Container (`reload-keys.sh`, siehe nächster Abschnitt).

### `reload-keys.sh`: Key-Rotation ohne Container-Neustart

`sshd` liest `authorized_keys` bei jeder neuen Verbindung frisch von der
Platte (kein In-Memory-Cache über die Laufzeit des Daemons) - ein
Container-Neustart war für einen Reload nie technisch nötig, hätte aber
jeden gerade laufenden Backup-Transfer eines ANDEREN Clients mitten drin
abgewürgt (`docker compose restart` killt den Container-Prozess und damit
jede offene `borg serve`-Session, nicht nur neue Verbindungsversuche).
`reload-keys.sh` ruft stattdessen `build-authorized-keys.sh` per `docker
compose exec` im laufenden Container erneut auf - kein Signal an `sshd`,
kein Prozess-Neustart, nur die Dateien werden aktualisiert. `add-backup-key.sh`/
`add-admin-key.sh` rufen `reload-keys.sh` am Ende selbst auf (kein manueller
Schritt mehr fürs Hinzufügen nötig) - läuft der Container noch nicht (z.B.
bei der Ersteinrichtung, vor dem ersten `docker compose up -d`), prüft
`reload-keys.sh` das per `docker compose ps -q borg-server` vorher und
druckt nur einen Hinweis statt eines Fehlers (der nächste reguläre Start
baut alles ohnehin frisch). Für *manuelle* Änderungen unter `users/` bleibt
`reload-keys.sh` weiterhin ein eigener Aufruf.

Deshalb schreibt `build-authorized-keys.sh`s `apply_all()` NICHT direkt in
`/etc/ssh/authorized_keys/<name>`, sondern über `mktemp` in eine Tmp-Datei
im selben Verzeichnis + abschließendes `mv` (atomares `rename(2)`, da
gleiches Dateisystem) - ohne das könnte eine zeitgleich eintreffende
SSH-Verbindung mitten im Neuschreiben eine leere oder unvollständige Datei
lesen. Eine Ebene darüber sorgt die Zwei-Phasen-Ausführung
(`validate_all()`/`apply_all()`, siehe "Ein Unix-Account pro Identität"
oben) zusätzlich dafür, dass Phase 2 bei IRGENDEINEM harten Fehler
irgendwo in `users/` gar nicht erst anläuft - nicht nur die einzelne Datei
ist atomar, der gesamte Reload ist es.

Wichtig: das Entfernen einer Identität/eines Keys aus `users/` entfernt nur
die Möglichkeit, sich NEU zu verbinden - eine bereits laufende Session des
ausgetragenen Keys läuft weiter, bis sie von selbst endet. Ein hartes
Kappen (Prozess im Container gezielt killen) deckt `reload-keys.sh` bewusst
nicht ab.

Beim Verdrahten von `reload-keys.sh` in `add-backup-key.sh`/`add-admin-key.sh`
ist ein echter, vorher unbemerkter Bug aufgefallen: der Best-Effort-Check
gegen `SSHD_PUBKEY_ALGORITHMS` liest den Wert per
`grep ... "${BASE_DIR}/.env" | tail -n1 | cut -d= -f2-` in einer Command-
Substitution. `SSHD_PUBKEY_ALGORITHMS` ist in `.env.example` standardmäßig
AUSKOMMENTIERT - `grep` findet in der weit überwiegenden Mehrheit der Fälle
also nichts und exitet mit 1. Unter `set -euo pipefail` bricht eine simple
Zuweisung wie `ENV_VALUE="$(...)"` das ganze Skript ab, wenn die Pipeline
darin (via `pipefail`) nicht-null exitet - selbst wenn das Nicht-Finden
völlig erwartet ist. Fix: `|| true` ans Ende der Pipeline. War vorher nie
aufgefallen, weil alle bisherigen manuellen Tests von `add-backup-key.sh`
im echten Repo-Verzeichnis liefen, wo nie eine `.env`-Datei lag (das Skript
übersprang den ganzen Block dann einfach via `[ -f "${BASE_DIR}/.env" ]`) -
erst ein Test mit einer echten, aus `.env.example` kopierten `.env` deckte
es auf. Lehre: Skripte, die `.env` lesen, mit einer echten (aus
`.env.example` kopierten) `.env` testen, nicht ohne.

`SSHD_PUBKEY_ALGORITHMS`/`SSHD_KEX_ALGORITHMS`/`SSHD_CIPHERS`/`SSHD_MACS`/
`SSHD_MAX_AUTH_TRIES` (siehe Env-Overrides oben) sind vom `users/`-Reload
UNABHÄNGIG - die werden nur beim Container-*Erstellen* gelesen, dafür
bleibt `docker compose up -d` nötig, `reload-keys.sh`/`restart` reichen
dafür nicht.

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
