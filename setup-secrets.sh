#!/bin/bash
# Erzeugt secrets/ssh_host_ed25519_key (+.pub), idempotent.
# Details: ./setup-secrets.sh --help

set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<'EOF'
Usage: setup-secrets.sh

Erzeugt einmalig secrets/ssh_host_ed25519_key (+.pub) - der SSH-Hostkey,
über den sich Clients diesen Server merken (known_hosts). Existiert der
Key schon, wird nichts angefasst.

Muss über Container-Neustarts hinweg stabil bleiben (sonst "REMOTE HOST
IDENTIFICATION HAS CHANGED" bei jedem Client) - liegt deshalb auf dem Host
und wird nur read-only in den Container gemountet, statt dort erzeugt zu
werden.
EOF
    exit 0
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="${BASE_DIR}/secrets"

mkdir -p "${SECRETS_DIR}"

if [ -f "${SECRETS_DIR}/ssh_host_ed25519_key" ]; then
    echo "secrets/ssh_host_ed25519_key existiert schon, überspringe."
else
    echo "Erzeuge secrets/ssh_host_ed25519_key ..."
    ssh-keygen -t ed25519 -f "${SECRETS_DIR}/ssh_host_ed25519_key" -C "" -N ""
    chmod 600 "${SECRETS_DIR}/ssh_host_ed25519_key"
    chmod 644 "${SECRETS_DIR}/ssh_host_ed25519_key.pub"
fi

echo
echo "Fingerprint für secrets/known_hosts auf jedem Client
(ssh-keyscan -p <SSH_PORT> <host> beim Client, oder direkt hieraus ableiten):"
ssh-keygen -lf "${SECRETS_DIR}/ssh_host_ed25519_key.pub"

echo
echo "secrets/ ist bereit:"
ls -la "${SECRETS_DIR}"
