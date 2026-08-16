#!/bin/bash
#
# Registriert einen neuen Backup-Client: legt dessen Public Key unter
# keys/backup/<name>.pub ab. build-authorized-keys.sh (laeuft bei jedem
# Container-Start) generiert daraus einen Eintrag in authorized_keys mit
# Forced Command auf "<borg-binary> serve --append-only
# --restrict-to-repository /data/<name>" - der Client kann also nur in
# genau dieses Repo schreiben, nichts endgueltig loeschen, und keine Shell
# bekommen.
#
# Usage: ./add-backup-key.sh <name> <pubkey-datei> [borg-version]
#
# [borg-version] ist optional (z.B. "1.2.8") und waehlt eine im Image
# installierte, aeltere Borg-Version fuer diesen einen Client aus - siehe
# README "Mehrere Borg-Versionen". Ohne Angabe kommt die Default-Version
# des Images zum Einsatz.

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="${1:?Usage: add-backup-key.sh <name> <pubkey-datei> [borg-version]}"
PUBKEY_FILE="${2:?Usage: add-backup-key.sh <name> <pubkey-datei> [borg-version]}"
BORG_VERSION="${3:-}"

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

REMOTE_PATH="borg"
if [ -n "${BORG_VERSION}" ]; then
    echo "${BORG_VERSION}" > "${KEYS_DIR}/${NAME}.version"
    REMOTE_PATH="borg-${BORG_VERSION}"
fi

echo "Backup-Key '${NAME}' hinzugefuegt (keys/backup/${NAME}.pub)."
echo "Container neu starten, damit er aktiv wird: docker compose restart"
echo
echo "Werte fuer die .env des Clients (docker-borg-backup):"
echo "  BORG_SSH_HOST=<Hostname/IP dieses Servers>"
echo "  BORG_SSH_PORT=<SSH_PORT aus der .env hier, Default 2222>"
echo "  BORG_SSH_USER=borg"
echo "  BORG_REPO_PATH=/data/${NAME}"
echo "  BORG_REMOTE_PATH=${REMOTE_PATH}"
if [ -n "${BORG_VERSION}" ]; then
    echo
    echo "Hinweis: BORG_REMOTE_PATH wird hier nur informativ ausgegeben - der"
    echo "Server ignoriert, was der Client tatsaechlich anfragt (Forced"
    echo "Command), und benutzt so oder so fest '${REMOTE_PATH}' fuer diesen"
    echo "Key. BORG_REMOTE_PATH beim Client trotzdem passend setzen, damit"
    echo "beide Seiten fuer Menschen nachvollziehbar dieselbe Version nennen."
fi
