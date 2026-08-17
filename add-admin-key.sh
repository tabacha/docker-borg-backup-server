#!/bin/bash
# Registriert einen Admin-Key. Details: ./add-admin-key.sh --help

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UID_MIN=1000 # muss zu MIN_UID/MAX_UID in image/build-authorized-keys.sh passen
UID_MAX=2000

usage() {
    cat <<'EOF'
Usage: add-admin-key.sh <name> <pubkey-datei> [--uid N] [--version V] [--from PATTERN]

Legt users/<uid>-<name>/keys/admin/<datei>.pub an und ruft reload-keys.sh -
voller Zugriff (prune/delete/compact), aber NUR auf das eine Repo dieser
Identitaet (/data/<name>), nie auf ein fremdes. Existiert <name> schon,
wird der Key als zusaetzlicher Key derselben Identitaet ergaenzt (mehrere
Admins/Geraete/Rotation). Ist <name> schon eine Backup-Identitaet, bekommt
sie zusaetzlich die Admin-Rolle - beide Forced Commands gelten dann
parallel fuer diese eine Identitaet, weiterhin beschraenkt auf ihr eigenes
Repo. Um mehrere Repos zu verwalten, denselben Pubkey mehrfach registrieren
- einmal je Ziel-Identitaet.

  --uid N         feste UID fuer eine neue Identitaet (sonst automatisch,
                   Bereich 1000-2000)
  --version V     bindet diesen einen Key an eine bestimmte Borg-Version
  --from PATTERN  bindet diesen einen Key an eine ssh "from="-Pattern-Liste

Admin-Keys nie als Datei auf einem gesicherten Host ablegen - nur im
eigenen SSH-Agent (idealerweise Hardware-Token), siehe README 'Sicherheit'
in docker-borg-backup.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
[ $# -ge 2 ] || { usage >&2; exit 1; }
NAME="$1"
PUBKEY_FILE="$2"
shift 2

UID_OPT=""
BORG_VERSION=""
FROM_PATTERN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --uid) UID_OPT="${2:?--uid braucht einen Wert}"; shift 2 ;;
        --version) BORG_VERSION="${2:?--version braucht einen Wert}"; shift 2 ;;
        --from) FROM_PATTERN="${2:?--from braucht einen Wert}"; shift 2 ;;
        *) echo "ERROR: unbekanntes Argument '$1'." >&2; usage >&2; exit 1 ;;
    esac
done

if [[ ! "${NAME}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: <name> darf nur Buchstaben, Ziffern, '_' und '-' enthalten." >&2
    exit 1
fi

USERS_DIR="${BASE_DIR}/users"
mkdir -p "${USERS_DIR}"

# Best-Effort-Warnung, kein Abbruch - siehe add-backup-key.sh.
PUBKEY_ALGORITHMS="ssh-ed25519,sk-ssh-ed25519@openssh.com"
if [ -f "${BASE_DIR}/.env" ]; then
    ENV_VALUE="$(grep -E '^SSHD_PUBKEY_ALGORITHMS=' "${BASE_DIR}/.env" | tail -n1 | cut -d= -f2- || true)"
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
    echo "WARNUNG: '${PUBKEY_FILE}' (Typ '${KEY_TYPE}') taucht nicht erkennbar in" >&2
    echo "SSHD_PUBKEY_ALGORITHMS='${PUBKEY_ALGORITHMS}' auf - Verbindung koennte" >&2
    echo "mit 'Permission denied (publickey)' scheitern, siehe README 'SSH-Haertung'." >&2
fi

# Existierende Identitaet mit demselben Namen wiederverwenden statt eine
# zweite anzulegen. Hat sie schon Backup-Keys, bekommt sie damit zusaetzlich
# zur Backup- auch die Admin-Rolle - beide bleiben auf GENAU ihr eigenes
# Repo beschraenkt (restrict-to-repository), build-authorized-keys.sh traegt
# beide Forced Commands parallel ein, siehe CLAUDE.md.
EXISTING_DIR=""
EXISTING_UID=""
for entry in "${USERS_DIR}"/*/; do
    [ -d "${entry}" ] || continue
    base="$(basename "${entry}")"
    [[ "${base}" =~ ^([0-9]+)-([a-zA-Z0-9_-]+)$ ]] || continue
    if [ "${BASH_REMATCH[2]}" = "${NAME}" ]; then
        EXISTING_DIR="${entry}"
        EXISTING_UID="${BASH_REMATCH[1]}"
        break
    fi
done

if [ -n "${EXISTING_DIR}" ]; then
    if [ -n "${UID_OPT}" ] && [ "${UID_OPT}" != "${EXISTING_UID}" ]; then
        echo "ERROR: '${NAME}' existiert schon mit UID ${EXISTING_UID} - --uid ${UID_OPT} passt nicht dazu." >&2
        exit 1
    fi
    TARGET_UID="${EXISTING_UID}"
    TARGET_DIR="${EXISTING_DIR}"
    echo "Identitaet '${NAME}' existiert schon (uid ${TARGET_UID}) - Key wird ergaenzt."
else
    if [ -n "${UID_OPT}" ]; then
        if [[ ! "${UID_OPT}" =~ ^[0-9]+$ ]] || [ "${UID_OPT}" -lt "${UID_MIN}" ] || [ "${UID_OPT}" -gt "${UID_MAX}" ]; then
            echo "ERROR: --uid muss eine Zahl zwischen ${UID_MIN} und ${UID_MAX} sein." >&2
            exit 1
        fi
        if compgen -G "${USERS_DIR}/${UID_OPT}-*" >/dev/null; then
            echo "ERROR: UID ${UID_OPT} ist schon vergeben (users/${UID_OPT}-*)." >&2
            exit 1
        fi
        TARGET_UID="${UID_OPT}"
    else
        HIGHEST_UID=$((UID_MIN - 1))
        for entry in "${USERS_DIR}"/*/; do
            [ -d "${entry}" ] || continue
            base="$(basename "${entry}")"
            [[ "${base}" =~ ^([0-9]+)-([a-zA-Z0-9_-]+)$ ]] || continue
            [ "${BASH_REMATCH[1]}" -gt "${HIGHEST_UID}" ] && HIGHEST_UID="${BASH_REMATCH[1]}"
        done
        TARGET_UID=$((HIGHEST_UID < UID_MIN ? UID_MIN : HIGHEST_UID + 1))
        if [ "${TARGET_UID}" -gt "${UID_MAX}" ]; then
            echo "ERROR: UID-Bereich ${UID_MIN}-${UID_MAX} ist ausgeschoepft - --uid mit einer freien Nummer angeben oder den Bereich erweitern." >&2
            exit 1
        fi
    fi
    TARGET_DIR="${USERS_DIR}/${TARGET_UID}-${NAME}/"
fi

KEYS_DIR="${TARGET_DIR}keys/admin"
mkdir -p "${KEYS_DIR}"

SRC_BASENAME="$(basename "${PUBKEY_FILE}")"
case "${SRC_BASENAME}" in
    *.pub) KEY_FILE_NAME="${SRC_BASENAME}" ;;
    *) KEY_FILE_NAME="${SRC_BASENAME}.pub" ;;
esac

if [ -f "${KEYS_DIR}/${KEY_FILE_NAME}" ]; then
    echo "ERROR: ${KEYS_DIR}/${KEY_FILE_NAME} existiert schon - erst loeschen, wenn der Key ersetzt werden soll." >&2
    exit 1
fi

cp "${PUBKEY_FILE}" "${KEYS_DIR}/${KEY_FILE_NAME}"

if [ -n "${BORG_VERSION}" ]; then
    echo "${BORG_VERSION}" > "${KEYS_DIR}/${KEY_FILE_NAME%.pub}.version"
fi
if [ -n "${FROM_PATTERN}" ]; then
    echo "${FROM_PATTERN}" > "${KEYS_DIR}/${KEY_FILE_NAME%.pub}.from"
fi

echo "Admin-Key '${NAME}' hinzugefuegt (${KEYS_DIR}/${KEY_FILE_NAME}, uid ${TARGET_UID})."
echo
"${BASE_DIR}/reload-keys.sh"
echo
echo "Hinweis: Admin-Keys nie als Datei auf einem gesicherten Host ablegen -"
echo "nur im eigenen SSH-Agent (idealerweise Hardware-Token)."
