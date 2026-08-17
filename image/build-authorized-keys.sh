#!/bin/bash
# Baut aus /users/<uid>-<name>/keys/{backup,admin}/*.pub je Identitaet einen
# Unix-Account, /data/<name> und /etc/ssh/authorized_keys/<name>. Laeuft bei
# jedem Container-Start (entrypoint.sh) und via reload-keys.sh im laufenden
# Container. Layout, Rationale und empirische Gotchas: siehe README.md
# ("Verzeichnisstruktur") und CLAUDE.md ("Ein Unix-Account pro Identität").
#
# Zwei Phasen: validate_all() liest nur und sammelt Fehler; findet sich
# EIN harter Fehler, wendet apply_all() GAR NICHTS an (bisheriger Stand
# bleibt aktiv bzw. der Container startet gar nicht erst).

set -euo pipefail

USERS_DIR="/users"
DATA_DIR="/data"
AUTH_KEYS_DIR="/etc/ssh/authorized_keys"
# Muss zu UID_MIN/UID_MAX in add-backup-key.sh/add-admin-key.sh passen.
# sshd kennt keine Direktive fuer UID-Bereiche, daher die Durchsetzung hier.
MIN_UID=1000
MAX_UID=2000

shopt -s nullglob

declare -A NAME_OF_UID=()
declare -A UID_OF_NAME=()
declare -A ROLE_OF_NAME=()
declare -A BACKUP_PUBFILES_OF_NAME=()
declare -A ADMIN_PUBFILES_OF_NAME=()
ERRORS=()

# Borg-Binary fuer einen Key: "borg" oder "borg-<version>" aus <key>.version.
# Nicht installierte Version -> Eintrag in ERRORS, Rueckgabewert 1.
resolve_borg_binary() {
    local pubkey_file="$1"
    local version_file="${pubkey_file%.pub}.version"

    if [ ! -f "${version_file}" ]; then
        echo "borg"
        return 0
    fi

    local version binary
    version="$(tr -d '[:space:]' < "${version_file}")"
    binary="borg-${version}"

    if ! command -v "${binary}" >/dev/null 2>&1; then
        ERRORS+=("${version_file}: verlangt Borg-Version '${version}', aber '${binary}' ist in diesem Image nicht installiert.")
        echo "borg"
        return 1
    fi

    echo "${binary}"
}

validate_all() {
    local entry base uid_num name role pf
    local backup_pubs admin_pubs
    local existing_uid existing_name

    for entry in "${USERS_DIR}"/*/; do
        base="$(basename "${entry}")"

        if [[ ! "${base}" =~ ^([0-9]+)-([a-zA-Z0-9_-]+)$ ]]; then
            echo "WARNUNG: users/${base} passt nicht auf das Schema '<uid>-<name>', wird uebersprungen." >&2
            continue
        fi
        uid_num="${BASH_REMATCH[1]}"
        name="${BASH_REMATCH[2]}"

        if [ "${uid_num}" -lt "${MIN_UID}" ] || [ "${uid_num}" -gt "${MAX_UID}" ]; then
            ERRORS+=("users/${base}: UID ${uid_num} ausserhalb des erlaubten Bereichs ${MIN_UID}-${MAX_UID}.")
            continue
        fi

        existing_uid="$(id -u "${name}" 2>/dev/null || true)"
        if [ -n "${existing_uid}" ] && [ "${existing_uid}" != "${uid_num}" ]; then
            ERRORS+=("users/${base}: Unix-Account '${name}' existiert schon mit UID ${existing_uid}, verlangt wird aber ${uid_num}.")
            continue
        fi
        existing_name="$(getent passwd "${uid_num}" 2>/dev/null | cut -d: -f1 || true)"
        if [ -n "${existing_name}" ] && [ "${existing_name}" != "${name}" ]; then
            ERRORS+=("users/${base}: UID ${uid_num} gehoert schon zu Account '${existing_name}'.")
            continue
        fi

        if [ -n "${NAME_OF_UID[${uid_num}]:-}" ] && [ "${NAME_OF_UID[${uid_num}]}" != "${name}" ]; then
            ERRORS+=("users/${base}: UID ${uid_num} ist doppelt vergeben (auch an '${NAME_OF_UID[${uid_num}]}').")
            continue
        fi
        if [ -n "${UID_OF_NAME[${name}]:-}" ] && [ "${UID_OF_NAME[${name}]}" != "${uid_num}" ]; then
            ERRORS+=("users/${base}: Name '${name}' ist doppelt vergeben (auch fuer UID ${UID_OF_NAME[${name}]}).")
            continue
        fi

        backup_pubs=("${entry}keys/backup/"*.pub)
        admin_pubs=("${entry}keys/admin/"*.pub)

        if [ "${#backup_pubs[@]}" -eq 0 ] && [ "${#admin_pubs[@]}" -eq 0 ]; then
            echo "WARNUNG: users/${base} hat keinen Key, wird uebersprungen." >&2
            continue
        fi

        # Eine Identitaet darf beide Rollen gleichzeitig haben (z.B. ein
        # Backup-Client, fuer dessen Repo zusaetzlich mehrere Admins vollen
        # Zugriff bekommen sollen) - pro Key entscheidet allein, unter
        # welchem keys/{backup,admin}/ er liegt, welches Forced Command er
        # bekommt (siehe append_key_lines() in apply_all()).
        if [ "${#backup_pubs[@]}" -gt 0 ] && [ "${#admin_pubs[@]}" -gt 0 ]; then
            role="backup+admin"
        elif [ "${#backup_pubs[@]}" -gt 0 ]; then
            role="backup"
        else
            role="admin"
        fi
        [ "${#backup_pubs[@]}" -gt 0 ] && BACKUP_PUBFILES_OF_NAME[${name}]="$(printf '%s\n' "${backup_pubs[@]}")"
        [ "${#admin_pubs[@]}" -gt 0 ] && ADMIN_PUBFILES_OF_NAME[${name}]="$(printf '%s\n' "${admin_pubs[@]}")"

        for pf in "${backup_pubs[@]}" "${admin_pubs[@]}"; do
            resolve_borg_binary "${pf}" >/dev/null || true
        done

        NAME_OF_UID[${uid_num}]="${name}"
        UID_OF_NAME[${name}]="${uid_num}"
        ROLE_OF_NAME[${name}]="${role}"
    done

    if [ "${#ERRORS[@]}" -gt 0 ]; then
        echo "ERROR: ${#ERRORS[@]} harte(r) Fehler in ${USERS_DIR}/ gefunden - KEINE Aenderung wird uebernommen:" >&2
        local e
        for e in "${ERRORS[@]}"; do
            echo "  - ${e}" >&2
        done
        exit 1
    fi
}

# Haengt fuer jeden Pubkey in $1 (newline-getrennte Liste, wie in
# BACKUP_PUBFILES_OF_NAME/ADMIN_PUBFILES_OF_NAME abgelegt) eine
# authorized_keys-Zeile mit Forced Command $2 an Datei $3 an. Gemeinsamer
# Kern fuer beide Rollen, weil eine Identitaet inzwischen Keys in BEIDEN
# Listen haben kann (siehe validate_all()).
append_key_lines() {
    local pubfiles="$1" command_suffix="$2" tmp_file="$3"
    local pf pubkey binary from_file from_value prefix
    while IFS= read -r pf; do
        [ -n "${pf}" ] || continue
        pubkey="$(cat "${pf}")"
        binary="$(resolve_borg_binary "${pf}")"
        prefix=""
        from_file="${pf%.pub}.from"
        if [ -f "${from_file}" ]; then
            from_value="$(tr -d '[:space:]' < "${from_file}")"
            [ -n "${from_value}" ] && prefix="from=\"${from_value}\","
        fi
        echo "${prefix}command=\"${binary} ${command_suffix}\",restrict ${pubkey}" >> "${tmp_file}"
    done <<< "${pubfiles}"
}

apply_all() {
    mkdir -p "${AUTH_KEYS_DIR}"
    chown root:root "${AUTH_KEYS_DIR}"
    chmod 755 "${AUTH_KEYS_DIR}"

    local name uid_num role home_dir tmp_file

    for name in "${!UID_OF_NAME[@]}"; do
        uid_num="${UID_OF_NAME[${name}]}"
        role="${ROLE_OF_NAME[${name}]}"
        home_dir="${DATA_DIR}/${name}"

        if ! id "${name}" >/dev/null 2>&1; then
            useradd --no-create-home --home-dir "${home_dir}" --uid "${uid_num}" \
                --shell /bin/bash --groups borgusers "${name}"
            # Gesperrtes Passwort (useradd-Default) reicht bei aktivem PAM
            # sshd nicht - "account is locked" trotz Pubkey-Auth. Absicherung
            # falls UsePAM je wieder aktiviert wird, siehe sshd_config.template.
            usermod -p '*' "${name}"
        fi

        # /data/<name> gehoert IMMER exklusiv dem eigenen Account (700) -
        # keine Gruppe, kein Setgid: kein Account soll je ueber Datei-
        # besitz an ein fremdes Repo kommen. Ein Admin-Key (unten) bekommt
        # deshalb bewusst NIE mehr Zugriff als der Backup-Key derselben
        # Identitaet - beide restrict-to-repository auf GENAU diesen
        # einen Pfad, nur ohne dessen --append-only.
        mkdir -p "${home_dir}"
        chown "${name}:${name}" "${home_dir}"
        chmod 700 "${home_dir}"

        tmp_file="$(mktemp "${AUTH_KEYS_DIR}/.${name}.XXXXXX")"
        [ -n "${BACKUP_PUBFILES_OF_NAME[${name}]:-}" ] && append_key_lines "${BACKUP_PUBFILES_OF_NAME[${name}]}" \
            "serve --append-only --restrict-to-repository ${home_dir}" "${tmp_file}"
        [ -n "${ADMIN_PUBFILES_OF_NAME[${name}]:-}" ] && append_key_lines "${ADMIN_PUBFILES_OF_NAME[${name}]}" \
            "serve --restrict-to-repository ${home_dir}" "${tmp_file}"

        chown root:root "${tmp_file}"
        # 644, nicht 600: sshd liest eine authorized_keys-Datei ausserhalb
        # von ~/.ssh ueber einen unprivilegierten Preauth-Prozess (faellt
        # auf die Ziel-UID) - root:root+600 ergibt sonst "Permission denied"
        # (empirisch gefunden, siehe CLAUDE.md). Inhalt ist nicht geheim,
        # nur Schreibzugriff bleibt root vorbehalten.
        chmod 644 "${tmp_file}"
        mv "${tmp_file}" "${AUTH_KEYS_DIR}/${name}"
        echo "Identitaet '${name}' (uid ${uid_num}, ${role}) -> $(wc -l < "${AUTH_KEYS_DIR}/${name}") Key(s)."
    done

    # Entzug: Datei fuer nicht mehr in /users/ vorhandene Identitaeten
    # loeschen - Account und /data/<name> bleiben immer erhalten.
    local existing base_name
    for existing in "${AUTH_KEYS_DIR}"/*; do
        [ -f "${existing}" ] || continue
        base_name="$(basename "${existing}")"
        if [ -z "${UID_OF_NAME[${base_name}]:-}" ]; then
            rm -f "${existing}"
            echo "Identitaet '${base_name}' nicht mehr in ${USERS_DIR}/ - Zugriff entzogen (Account/Daten bleiben erhalten)."
        fi
    done
}

if [ ! -d "${USERS_DIR}" ] || [ -z "$(find "${USERS_DIR}" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
    echo "WARNUNG: ${USERS_DIR} existiert nicht oder ist leer - niemand kann sich verbinden." >&2
fi

validate_all
apply_all
