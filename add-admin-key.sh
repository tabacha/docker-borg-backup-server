#!/bin/bash
#
# Registriert einen neuen Admin-Key: legt dessen Public Key unter
# keys/admin/<name>.pub ab. build-authorized-keys.sh (laeuft bei jedem
# Container-Start) generiert daraus einen Eintrag in authorized_keys mit
# Forced Command auf "<borg-binary> serve --restrict-to-path /data" - voller
# Zugriff (prune/delete/compact) auf jedes Repo unter /data, aber weiterhin
# keine Shell und kein Ausbruch aus /data.
#
# Usage: ./add-admin-key.sh <name> <pubkey-datei> [borg-version]
#
# [borg-version] ist optional (z.B. "1.2.8") - siehe README "Mehrere
# Borg-Versionen". Braucht man in der Regel nur, wenn dieser Admin-Key
# gezielt ein aelteres Repo verwaltet, dessen Client noch auf einer alten
# Version haengt.

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="${1:?Usage: add-admin-key.sh <name> <pubkey-datei> [borg-version]}"
PUBKEY_FILE="${2:?Usage: add-admin-key.sh <name> <pubkey-datei> [borg-version]}"
BORG_VERSION="${3:-}"

if [[ ! "${NAME}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: <name> darf nur Buchstaben, Ziffern, '_' und '-' enthalten." >&2
    exit 1
fi

KEYS_DIR="${BASE_DIR}/keys/admin"
mkdir -p "${KEYS_DIR}"

if [ -f "${KEYS_DIR}/${NAME}.pub" ]; then
    echo "ERROR: keys/admin/${NAME}.pub existiert schon - erst loeschen, wenn der Key ersetzt werden soll." >&2
    exit 1
fi

cp "${PUBKEY_FILE}" "${KEYS_DIR}/${NAME}.pub"

if [ -n "${BORG_VERSION}" ]; then
    echo "${BORG_VERSION}" > "${KEYS_DIR}/${NAME}.version"
fi

echo "Admin-Key '${NAME}' hinzugefuegt (keys/admin/${NAME}.pub)."
echo "Container neu starten, damit er aktiv wird: docker compose restart"
echo
echo "Dieser Key sollte NIE als Datei auf einem gesicherten Host liegen -"
echo "nur im eigenen SSH-Agent des Admins (idealerweise Hardware-Token), siehe"
echo "README 'Sicherheit' in docker-borg-backup."
