#!/bin/bash
#
# Erzeugt secrets/ssh_host_ed25519_key (+.pub) fuer die Ersteinrichtung -
# der SSH-Hostkey, ueber den sich Clients diesen Server merken (known_hosts).
# Idempotent: existiert der Key schon, wird er nicht angefasst.
#
# WICHTIG: Dieser Key muss über Container-Neustarts hinweg stabil bleiben,
# sonst sehen alle Clients bei jedem Neustart eine
# "REMOTE HOST IDENTIFICATION HAS CHANGED"-Warnung. Deshalb liegt er in
# secrets/ auf dem Host und wird nur read-only in den Container gemountet
# (siehe compose.yml), statt vom Container selbst erzeugt zu werden.

set -euo pipefail

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
