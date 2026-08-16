#!/bin/bash
#
# Registriert einen neuen Backup-Client: legt dessen Public Key unter
# keys/backup/<name>.pub ab. build-authorized-keys.sh (laeuft bei jedem
# Container-Start) generiert daraus einen Eintrag in authorized_keys mit
# Forced Command auf "borg serve --append-only --restrict-to-repository
# /data/<name>" - der Client kann also nur in genau dieses Repo schreiben,
# nichts endgueltig loeschen, und keine Shell bekommen.
#
# Usage: ./add-backup-key.sh <name> <pubkey-datei>

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="${1:?Usage: add-backup-key.sh <name> <pubkey-datei>}"
PUBKEY_FILE="${2:?Usage: add-backup-key.sh <name> <pubkey-datei>}"

if [[ ! "${NAME}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: <name> darf nur Buchstaben, Ziffern, '_' und '-' enthalten (wird als Verzeichnisname unter /data verwendet)." >&2
    exit 1
fi

KEYS_DIR="${BASE_DIR}/keys/backup"
mkdir -p "${KEYS_DIR}"

if [ -f "${KEYS_DIR}/${NAME}.pub" ]; then
    echo "ERROR: keys/backup/${NAME}.pub existiert schon - erst loeschen, wenn der Key ersetzt werden soll." >&2
    exit 1
fi

cp "${PUBKEY_FILE}" "${KEYS_DIR}/${NAME}.pub"

echo "Backup-Key '${NAME}' hinzugefuegt (keys/backup/${NAME}.pub)."
echo "Container neu starten, damit er aktiv wird: docker compose restart"
echo
echo "Werte fuer die .env des Clients (docker-borg-backup):"
echo "  BORG_SSH_HOST=<Hostname/IP dieses Servers>"
echo "  BORG_SSH_PORT=<SSH_PORT aus der .env hier, Default 2222>"
echo "  BORG_SSH_USER=borg"
echo "  BORG_REPO_PATH=/data/${NAME}"
echo "  BORG_REMOTE_PATH=borg"
