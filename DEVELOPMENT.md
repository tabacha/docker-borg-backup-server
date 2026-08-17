# Development

Für alle, die an diesem Repo selbst arbeiten (Skripte, `Dockerfile`,
CI/Release-Pipeline). Für Aufbau und Betrieb siehe [README.md](README.md).

## Workflow

- Nie direkt auf `main` pushen. Immer einen Branch erstellen, darauf
  committen/pushen, PR öffnen.
- Branch-Namen immer mit vorangestelltem Datum: `YYYY-MM-DD_Kurzbeschreibung`.

## Lokal testen

Kein klassisches Unit-Test-Framework, dafür ein echter Funktionstest
(`.github/scripts/functional-test.sh`), der den Container wirklich startet
(echter `sshd`, echtes `borg serve`) und die eigentliche Sicherheitsgrenze
prüft, nicht nur "Verbindung klappt":

```bash
# Shell-Syntax + Lint:
bash -n *.sh image/*.sh .github/scripts/*.sh
shellcheck --severity=warning -- *.sh image/*.sh .github/scripts/*.sh

# Dockerfile-Lint (Konfiguration in .hadolint.yaml, DL3008 ist bewusst
# ignoriert - siehe Kommentar dort). Ohne gemountete Config meldet hadolint
# DL3008 trotzdem (kann .hadolint.yaml beim reinen Stdin-Input nicht finden -
# das ist auch beim Original docker-borg-backup so), für einen Check inkl.
# Ignore-Liste die Config mitmounten:
docker run --rm -v "$(pwd):/repo" -w /repo hadolint/hadolint:v2.15.1 hadolint Dockerfile

# Workflow-YAML (inkl. Shellcheck der run:-Blöcke) - braucht ein Git-Repo im
# gemounteten Verzeichnis:
docker run --rm -v "$(pwd):/repo" -w /repo rhysd/actionlint:1.7.12 -color

# compose.yml (NICHT gegen eine echte .env mit Produktivdaten laufen lassen,
# hier gibt's aber ohnehin nur SSH_PORT, kein Geheimnis):
cp .env.example .env
docker compose config

# Image + kompletter sshd/borg-serve-Zyklus (Forced Command, Restrict-to-
# Path, Append-Only - jeweils an der tatsächlichen Wirkung geprüft, nicht
# nur am Exit-Code):
docker build -t ci-test:local .
.github/scripts/functional-test.sh ci-test:local
```

CI-Läufe beobachten: `gh run list --repo tabacha/docker-borg-backup-server`,
`gh run watch <id> --repo tabacha/docker-borg-backup-server --exit-status`.

## CI & Releases

Zwei Workflows unter `.github/workflows/`, analog zu `docker-borg-backup`:

- **`ci.yml`** — läuft bei jedem Push auf `main` und jedem Pull Request:
  Job `lint` (`shellcheck`, `hadolint`, `actionlint`, `docker compose
  config`), Job `build-and-test` (Image bauen + `functional-test.sh`
  drüberlaufen lassen).
- **`release.yml`** — baut das Image, lässt **dasselbe**
  `functional-test.sh` gegen den lokal geladenen Build laufen, pusht erst
  bei Erfolg nach [GHCR](https://ghcr.io/tabacha/docker-borg-backup-server),
  danach automatisch ein GitHub Release. Getriggert durch einen Tag der Form
  `vX.Y.Z`:

  ```bash
  git tag v1.0.0
  git push origin v1.0.0
  ```

  Damit `docker compose pull` ohne Login funktioniert, muss das GHCR-Package
  einmalig auf **Public** gestellt werden (Package Settings → Change
  visibility → Public) — dieselbe Falle wie bei `docker-borg-backup`.

## `image/` — Docker-Image-Interna

Alles unter `image/` wird nur beim Bau ins Image kopiert (`Dockerfile`s
`COPY image/... `) und läuft ausschließlich *im* Container — nichts davon
wird vom Betreiber des Servers je direkt aufgerufen (das steht so auch in
der README, hier nur mit Details für die Bearbeitung selbst). Das
`Dockerfile` selbst bleibt bewusst im Repo-Root (Konvention, `docker build
.` erwartet es dort per Default, `compose.yml`s `build: .` ebenso).

| Pfad | Läuft wann/wie | Zweck |
|---|---|---|
| `image/sshd_config.template` | Wird von `entrypoint.sh` bei JEDEM Container-Start gerendert (nicht beim Image-Bau) | Minimal-Config: nur Pubkey-Auth, kein PAM, kein Shell-Zugriff für irgendeine Identität. Fünf `__PLATZHALTER__` werden per `sed` durch `SSHD_*`-Env-Werte ersetzt (Default falls unset). |
| `image/entrypoint.sh` | `ENTRYPOINT` des Containers, läuft einmal pro Container-Start | Rendert `sshd_config`, leitet den Hostkey-Public-Part vom read-only gemounteten privaten Key ab, ruft `build-authorized-keys.sh` auf, startet `sshd -D -e`. |
| `image/build-authorized-keys.sh` | Von `entrypoint.sh` bei jedem Start UND von `reload-keys.sh` (per `docker compose exec`) bei Bedarf im laufenden Container | Liest `/users/<uid>-<name>/keys/{backup,admin}/*.pub`, legt Unix-Accounts + `/data/<name>` an, schreibt `/etc/ssh/authorized_keys/<name>`. Zwei Phasen (`validate_all()`/`apply_all()`) - bei irgendeinem harten Fehler wird nichts angewendet, siehe Kommentare im Skript. |

Wer an diesen drei Dateien etwas ändert: Image neu bauen
(`docker build -t ci-test:local .`) und danach den kompletten
`functional-test.sh`-Lauf (siehe "Lokal testen" oben) - das ist der
einzige verlässliche Weg, Änderungen hier zu verifizieren, da vieles davon
nur zur Laufzeit im Container sichtbar wird (z.B. ob `sshd -t` den
gerenderten Output noch akzeptiert).

## Sonstiges (intern)

- **Schlankes Image:** `Dockerfile` baut zweistufig — eine Builder-Stage mit
  Compiler/Headern (nur dort, für die Borg-C-Extensions nötig) und eine
  Runtime-Stage, die nur noch `openssh-server` plus die tatsächlich per
  `ldd` ermittelten Laufzeit-Bibliotheken (`libacl1`, `libssl3t64`,
  `liblz4-1`, `libxxhash0`, `libzstd1`, `zlib1g`) bekommt. Kein
  Compiler/Header/pip-Cache im ausgelieferten Image. `apt`/`dpkg` selbst
  bleiben trotzdem drin — die sind Teil der `python:3.14-slim`-Basis (jedes
  Debian-basierte Image braucht seinen eigenen Paketmanager, um überhaupt
  etwas installieren zu können) und ließen sich nur durch einen Wechsel auf
  eine komplett andere (nicht-Debian-)Basis entfernen — bewusst nicht
  gemacht, das wäre ein größerer, riskanterer Schritt für vergleichsweise
  wenig zusätzlichen Gewinn.
- `docker run -v "$(pwd):/ziel" ...` kann in manchen Sandbox-/CI-Setups mit
  "mkdir ... file exists" fehlschlagen (Bind-Mount-Quirk) — betroffene
  Dateien dann in ein Scratch-Verzeichnis kopieren und von dort aus mounten.
- `functional-test.sh` braucht keinen separat installierten Borg-Client auf
  dem Host: Es benutzt für den SSH-Client-Teil das gerade gebaute Image
  selbst (`docker run --entrypoint borg ...`), im Host-Netzwerk, um den
  published Port zu erreichen. Nur `ssh`/`ssh-keygen` müssen auf dem Host
  vorhanden sein (für die Test-Keypaare und den direkten
  Forced-Command-Check).
- Läuft ein lokaler `ssh-agent` mit vielen Keys, braucht jeder `ssh`-Aufruf
  im Test `-o IdentitiesOnly=yes` - sonst probiert `ssh` erst alle
  Agent-Keys durch und läuft in sshd's `MaxAuthTries`, bevor der eigentliche
  Test-Key überhaupt angeboten wird (schon mal passiert, sichtbar als
  "Too many authentication failures" statt einer echten Fehlermeldung).
