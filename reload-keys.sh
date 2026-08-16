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
# Nach dem Anlegen/Loeschen einer Datei unter keys/backup/ bzw. keys/admin/
# (z.B. add-backup-key.sh oder manuell "rm keys/backup/<name>.pub"):
#
#   ./reload-keys.sh
#
# Fuer SSHD_PUBKEY_ALGORITHMS/SSHD_KEX_ALGORITHMS/SSHD_CIPHERS/SSHD_MACS in
# der .env reicht das NICHT - die werden nur beim Container-Erstellen
# gelesen, dafuer braucht es "docker compose up -d" (siehe README).

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${BASE_DIR}"

docker compose exec -T borg-server /usr/local/bin/build-authorized-keys.sh
