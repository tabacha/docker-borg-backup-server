#!/bin/bash
# Baut alle Accounts/Zugaenge im laufenden Container neu, ohne Neustart -
# noetig nach manuellen Aenderungen unter users/ (add-backup-key.sh/
# add-admin-key.sh rufen das selbst auf). Details: ./reload-keys.sh --help

set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<'EOF'
Usage: reload-keys.sh

Baut authorized_keys/Accounts im laufenden Container neu, ohne Neustart -
laufende Sessions anderer Clients bleiben unangetastet (sshd liest
authorized_keys ohnehin bei jeder neuen Verbindung frisch). Nach jeder
manuellen Aenderung unter users/ aufrufen.

Enthaelt users/ einen harten Fehler (siehe image/build-authorized-keys.sh),
bricht dieser Aufruf ab - der bisherige Stand bleibt dabei vollstaendig
unangetastet.

SSHD_PUBKEY_ALGORITHMS/SSHD_KEX_ALGORITHMS/SSHD_CIPHERS/SSHD_MACS/
SSHD_MAX_AUTH_TRIES in der .env brauchen stattdessen "docker compose up -d"
(siehe README).
EOF
    exit 0
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${BASE_DIR}"

if [ -z "$(docker compose ps -q borg-server 2>/dev/null)" ]; then
    echo "Server laeuft noch nicht - kein Reload noetig, der naechste 'docker compose up -d' baut alles frisch."
    exit 0
fi

docker compose exec -T borg-server /usr/local/bin/build-authorized-keys.sh
