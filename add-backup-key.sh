#!/bin/bash
#
# Registriert einen neuen Backup-Client-Key unter
# users/<uid>-<name>/keys/backup/<dateiname>.pub. build-authorized-keys.sh
# (laeuft bei jedem Container-Start und bei jedem reload-keys.sh) generiert
# daraus einen Eintrag in /etc/ssh/authorized_keys/<name> mit Forced
# Command auf "<borg-binary> serve --append-only --restrict-to-repository
# /data/<name>" - der Client kann also nur in genau dieses Repo schreiben,
# nichts endgueltig loeschen, und keine Shell bekommen.
#
# Existiert der Name schon (egal mit welcher UID), wird der neue Key als
# ZUSAETZLICHER Key derselben Identitaet abgelegt - so laesst sich z.B.
# waehrend einer Key-Rotation der alte und der neue Key parallel gueltig
# halten (alten danach einfach loeschen + reload-keys.sh).
#
# Ruft am Ende automatisch reload-keys.sh auf, damit der Key sofort aktiv
# wird - ohne den Container neu zu starten und ohne laufende Sessions
# anderer Clients zu unterbrechen. Laeuft der Container noch nicht (z.B. bei
# der Ersteinrichtung), ist das kein Fehler, siehe reload-keys.sh.
#
# Usage: ./add-backup-key.sh <name> <pubkey-datei> [--uid N] [--version V] [--from PATTERN]
#
#   --uid N       feste UID fuer eine NEUE Identitaet (sonst automatisch:
#                 hoechste bereits vergebene UID + 1, mindestens 1000).
#                 Bei einer bereits existierenden Identitaet wird die
#                 vorhandene UID weiterverwendet, --uid muss dann (falls
#                 angegeben) dazu passen.
#   --version V   siehe README "Mehrere Borg-Versionen" - bindet NUR diesen
#                 einen Key an eine bestimmte, im Image installierte
#                 Borg-Version.
#   --from PATTERN  ssh authorized_keys(5) "from="-Pattern-Liste (z.B. eine
#                 IP oder ein CIDR-Bereich) - bindet NUR diesen einen Key an
#                 eine Quelladresse.

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: add-backup-key.sh <name> <pubkey-datei> [--uid N] [--version V] [--from PATTERN]" >&2
    exit 1
}

[ $# -ge 2 ] || usage
NAME="$1"
PUBKEY_FILE="$2"
shift 2

# Muss zu MIN_UID/MAX_UID in build-authorized-keys.sh passen - dort die
# massgebliche Stelle (und die Begruendung, warum ueberhaupt eine feste
# Grenze), hier nur dieselben Werte, damit ein zugewiesener UID nicht erst
# beim naechsten reload-keys.sh als harter Fehler auffaellt.
UID_MIN=1000
UID_MAX=2000

UID_OPT=""
BORG_VERSION=""
FROM_PATTERN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --uid) UID_OPT="${2:?--uid braucht einen Wert}"; shift 2 ;;
        --version) BORG_VERSION="${2:?--version braucht einen Wert}"; shift 2 ;;
        --from) FROM_PATTERN="${2:?--from braucht einen Wert}"; shift 2 ;;
        *) echo "ERROR: unbekanntes Argument '$1'." >&2; usage ;;
    esac
done

if [[ ! "${NAME}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: <name> darf nur Buchstaben, Ziffern, '_' und '-' enthalten (wird als Unix-Username und Verzeichnisname unter /data verwendet)." >&2
    exit 1
fi

USERS_DIR="${BASE_DIR}/users"
mkdir -p "${USERS_DIR}"

# Best-Effort-Check gegen SSHD_PUBKEY_ALGORITHMS (aus .env, sonst der
# Default aus sshd_config.template) - nur eine Warnung, kein hartes
# Abbrechen: bei RSA ist die Zuordnung nicht 1:1 (rsa-sha2-512/-256 sind
# SIGNATUR-Algorithmen fuer den Key-TYP "ssh-rsa", tauchen also nie
# woertlich in einer .pub-Datei auf), ein perfekter Check waere mehr
# Komplexitaet als er wert ist.
PUBKEY_ALGORITHMS="ssh-ed25519,sk-ssh-ed25519@openssh.com"
if [ -f "${BASE_DIR}/.env" ]; then
    # "|| true": grep findet in der weit ueberwiegenden Mehrheit der Faelle
    # NICHTS (SSHD_PUBKEY_ALGORITHMS ist standardmaessig auskommentiert) -
    # ohne "|| true" wuerde grep's Exit-Code 1 unter "set -euo pipefail"
    # das ganze Skript an dieser Stelle abbrechen (Bug, real aufgetreten).
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
    echo "WARNUNG: '${PUBKEY_FILE}' ist vom Typ '${KEY_TYPE}', taucht aber nicht erkennbar in" >&2
    echo "SSHD_PUBKEY_ALGORITHMS='${PUBKEY_ALGORITHMS}' auf - die Verbindung koennte mit" >&2
    echo "'Permission denied (publickey)' scheitern. Siehe README 'SSH-Haertung', ggf." >&2
    echo "SSHD_PUBKEY_ALGORITHMS in der .env anpassen." >&2
fi

# Existiert der Name schon (egal welche Rolle/UID), diese Identitaet
# wiederverwenden statt eine zweite mit demselben Namen anzulegen -
# build-authorized-keys.sh wuerde das ohnehin als harten Fehler ablehnen
# (doppelt vergebener Name), hier direkt eine klare Meldung statt erst beim
# naechsten reload-keys.sh.
EXISTING_DIR=""
EXISTING_UID=""
EXISTING_ROLE=""
for entry in "${USERS_DIR}"/*/; do
    [ -d "${entry}" ] || continue
    base="$(basename "${entry}")"
    [[ "${base}" =~ ^([0-9]+)-([a-zA-Z0-9_-]+)$ ]] || continue
    if [ "${BASH_REMATCH[2]}" = "${NAME}" ]; then
        EXISTING_DIR="${entry}"
        EXISTING_UID="${BASH_REMATCH[1]}"
        if [ -n "$(compgen -G "${entry}keys/admin/*.pub")" ]; then
            EXISTING_ROLE="admin"
        fi
        break
    fi
done

if [ -n "${EXISTING_ROLE}" ]; then
    echo "ERROR: '${NAME}' ist schon als Admin-Identitaet registriert (${EXISTING_DIR}keys/admin/) - kann nicht gleichzeitig Backup-Rolle bekommen." >&2
    exit 1
fi

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
            echo "ERROR: UID-Bereich ${UID_MIN}-${UID_MAX} ist ausgeschoepft - neue Identitaet braucht --uid mit einer noch freien Nummer in diesem Bereich (falls eine frei wurde) oder der Bereich muss in build-authorized-keys.sh/add-backup-key.sh/add-admin-key.sh erweitert werden." >&2
            exit 1
        fi
    fi
    TARGET_DIR="${USERS_DIR}/${TARGET_UID}-${NAME}/"
fi

KEYS_DIR="${TARGET_DIR}keys/backup"
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

REMOTE_PATH="borg"
if [ -n "${BORG_VERSION}" ]; then
    echo "${BORG_VERSION}" > "${KEYS_DIR}/${KEY_FILE_NAME%.pub}.version"
    REMOTE_PATH="borg-${BORG_VERSION}"
fi
if [ -n "${FROM_PATTERN}" ]; then
    echo "${FROM_PATTERN}" > "${KEYS_DIR}/${KEY_FILE_NAME%.pub}.from"
fi

echo "Backup-Key '${NAME}' hinzugefuegt (${KEYS_DIR}/${KEY_FILE_NAME}, uid ${TARGET_UID})."
echo
"${BASE_DIR}/reload-keys.sh"
echo
echo "Werte fuer die .env des Clients (docker-borg-backup):"
echo "  BORG_SSH_HOST=<Hostname/IP dieses Servers>"
echo "  BORG_SSH_PORT=<SSH_PORT aus der .env hier, Default 2222>"
echo "  BORG_SSH_USER=${NAME}"
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
