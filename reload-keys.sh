#!/bin/bash
#
# Baut authorized_keys im laufenden Container neu, OHNE ihn neu zu starten -
# wichtig, wenn gerade ein laengerer Backup-Transfer eines ANDEREN Clients
# laeuft: ein "docker compose restart" wuerde den mitten drin abwuergen, nur
# um z.B. jemanden auszutragen. sshd liest authorized_keys ohnehin bei jeder
# neuen Verbindung frisch von der Platte (kein In-Memory-Cache über die
# Laufzeit des Daemons) - ein Reload heisst also nur "Datei aktualisieren",
# kein Signal an sshd noetig, und bereits laufende Sessions sind davon nicht
# betroffen (siehe build-authorized-keys.sh).
#
# Nach dem Anlegen/Loeschen einer Datei unter users/<uid>-<name>/keys/
# (z.B. add-backup-key.sh oder manuell "rm users/1000-toolsserver/keys/backup/*.pub"):
#
#   ./reload-keys.sh
#
# add-backup-key.sh/add-admin-key.sh rufen das am Ende automatisch mit auf -
# laeuft der Container noch nicht (z.B. bei der Ersteinrichtung, vor dem
# ersten "docker compose up -d"), ist das kein Fehler: der naechste Start
# baut authorized_keys ohnehin frisch aus dem aktuellen Inhalt von users/.
#
# Enthaelt users/ einen harten Fehler (siehe build-authorized-keys.sh, z.B.
# eine doppelt vergebene UID), bricht dieser Aufruf mit einem entsprechenden
# Fehler ab - der bisherige Stand im Container bleibt dabei vollstaendig
# unangetastet, es wird NICHTS Halbfertiges uebernommen.
#
# Fuer SSHD_PUBKEY_ALGORITHMS/SSHD_KEX_ALGORITHMS/SSHD_CIPHERS/SSHD_MACS in
# der .env reicht das NICHT - die werden nur beim Container-Erstellen
# gelesen, dafuer braucht es "docker compose up -d" (siehe README).

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${BASE_DIR}"

if [ -z "$(docker compose ps -q borg-server 2>/dev/null)" ]; then
    echo "Server laeuft noch nicht - kein Reload noetig, der naechste 'docker compose up -d' baut authorized_keys frisch."
    exit 0
fi

docker compose exec -T borg-server /usr/local/bin/build-authorized-keys.sh
