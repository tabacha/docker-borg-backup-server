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

# Best-Effort-Check gegen SSHD_PUBKEY_ALGORITHMS (aus .env, sonst der
# Default aus sshd_config.template) - nur eine Warnung, kein hartes
# Abbrechen: bei RSA ist die Zuordnung nicht 1:1 (rsa-sha2-512/-256 sind
# SIGNATUR-Algorithmen fuer den Key-TYP "ssh-rsa", tauchen also nie
# woertlich in einer .pub-Datei auf, z.B. bei einem RSA-YubiKey ueber das
# PIV-Applet), ein perfekter Check waere mehr Komplexitaet als er wert ist.
# Ziel ist nur, den haeufigsten Fehler VOR dem "docker compose restart"
# sichtbar zu machen statt erst beim naechsten fehlschlagenden
# Verbindungsversuch.
PUBKEY_ALGORITHMS="ssh-ed25519,sk-ssh-ed25519@openssh.com"
if [ -f "${BASE_DIR}/.env" ]; then
    ENV_VALUE="$(grep -E '^SSHD_PUBKEY_ALGORITHMS=' "${BASE_DIR}/.env" | tail -n1 | cut -d= -f2-)"
    [ -n "${ENV_VALUE}" ] && PUBKEY_ALGORITHMS="${ENV_VALUE}"
fi

KEY_TYPE="$(awk '{print $1; exit}' "${PUBKEY_FILE}")"
ACCEPTED=0
case ",${PUBKEY_ALGORITHMS}," in
    *",${KEY_TYPE},"*) ACCEPTED=1 ;;
esac
if [ "${KEY_TYPE}" = "ssh-rsa" ]; then
    case ",${PUBKEY_ALGORITHMS}," in
        *",rsa-sha2-512,"*|*",rsa-sha2-256,"*) ACCEPTED=1 ;;
    esac
fi

if [ "${ACCEPTED}" -eq 0 ]; then
    echo "WARNUNG: '${PUBKEY_FILE}' ist vom Typ '${KEY_TYPE}', taucht aber nicht erkennbar in" >&2
    echo "SSHD_PUBKEY_ALGORITHMS='${PUBKEY_ALGORITHMS}' auf - die Verbindung koennte mit" >&2
    echo "'Permission denied (publickey)' scheitern. Siehe README 'SSH-Haertung', ggf." >&2
    echo "SSHD_PUBKEY_ALGORITHMS in der .env anpassen." >&2
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
