#!/bin/bash
#
# Baut je Identitaet eine Datei unter /etc/ssh/authorized_keys/<name> UND
# legt die noetigen Unix-Accounts + Home-/Datenverzeichnisse an, aus
# /users/<uid>-<name>/keys/{backup,admin}/*.pub. Laeuft bei jedem
# Container-Start (entrypoint.sh) UND kann jederzeit bei laufendem
# Container erneut angestossen werden, um jemanden auszutragen, ohne einen
# laufenden Backup-Transfer eines ANDEREN Clients zu unterbrechen:
#
#   docker compose exec -T borg-server /usr/local/bin/build-authorized-keys.sh
#
# Layout pro Identitaet:
#
#   /users/<uid>-<name>/keys/backup/<key>.pub   - Backup-Client: append-only,
#                                                  nur /data/<name>
#   /users/<uid>-<name>/keys/admin/<key>.pub    - Admin: voller Zugriff auf
#                                                  ganz /data
#   <key>.version   (optional, neben <key>.pub) - feste Borg-Version fuer
#                                                  GENAU diesen einen Key
#   <key>.from      (optional, neben <key>.pub) - "from="-Pattern-Liste
#                                                  (IP/Netzbereich/Hostmask),
#                                                  siehe ssh authorized_keys(5)
#
# Mehrere *.pub-Dateien im selben keys/backup/ bzw. keys/admin/ sind
# mehrere gleichzeitig gueltige Keys fuer DIESELBE Identitaet - z.B. fuer
# Rotation (alten und neuen Key parallel eintragen, alten Key danach
# entfernen) oder mehrere Admins/Geraete, die sich alle unter demselben
# Namen einloggen sollen.
#
# <uid> im Verzeichnisnamen ist bewusst explizit vorgegeben, nicht vom
# Container gewuerfelt: /data/<name> ist ein persistentes Volume - eine bei
# jedem Neustart neu vergebene UID wuerde die Ownership-Zuordnung nach
# einer Neuerstellung des Containers zerreissen. Wer <uid>-<name> anlegt
# (add-backup-key.sh/add-admin-key.sh oder von Hand), legt die UID damit
# einmalig und dauerhaft fest.
#
# ZWEI PHASEN, bewusst getrennt (siehe validate_all/apply_all unten):
# Phase 1 liest nur und veraendert nichts. Findet sich dabei auch nur EIN
# harter Fehler, wird GAR NICHTS angewendet - weder ein neuer Unix-Account
# angelegt noch eine bestehende authorized_keys-Datei veraendert. Laeuft
# der Container schon, bleibt der zuletzt gueltige Stand vollstaendig
# unangetastet (ein Tippfehler bei einer Identitaet legt nicht den Zugriff
# aller anderen lahm). Laeuft der Container gerade erst hoch, verhindert
# "set -e" in entrypoint.sh in diesem Fall den Start komplett, statt mit
# einer kaputten/unvollstaendigen Konfiguration hochzufahren.

set -euo pipefail

USERS_DIR="/users"
DATA_DIR="/data"
AUTH_KEYS_DIR="/etc/ssh/authorized_keys"
# Bewusst nicht per Env konfigurierbar (anders als SSHD_*): das ist eine
# feste Sicherheitsgrenze, kein Deployment-Tuning-Parameter - siehe
# add-backup-key.sh/add-admin-key.sh, die dieselben Grenzen beim Vergeben
# neuer UIDs anwenden. sshd selbst kennt KEINE Direktive fuer einen
# UID-Zahlenbereich (AllowUsers/AllowGroups/Match arbeiten nur mit Namen/
# Gruppenmustern) - die eigentliche Durchsetzung passiert deshalb hier,
# beim Anlegen der Accounts: nur wer hier einen Unix-Account bekommt, kommt
# ueberhaupt in die Gruppe "borgusers" und damit an sshd's "AllowGroups"
# vorbei (siehe sshd_config.template).
MIN_UID=1000
MAX_UID=2000

shopt -s nullglob

declare -A NAME_OF_UID=()
declare -A UID_OF_NAME=()
declare -A ROLE_OF_NAME=()
declare -A PUBFILES_OF_NAME=()
ERRORS=()

# Gibt die zu verwendende Borg-Binary auf stdout aus. Verlangt <key>.version
# eine nicht installierte Version, wird das als harter Fehler in ERRORS
# vermerkt (Rueckgabewert 1) - der Aufrufer in validate_all() ignoriert den
# Rueckgabewert bewusst (Fehler sammeln statt beim ersten Treffer abbrechen),
# apply_all() erreicht diese Zeile nur noch fehlerfrei, weil es erst nach
# einer erfolgreichen validate_all()-Runde laeuft.
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
            echo "WARNUNG: users/${base} passt nicht auf das Schema '<uid>-<name>' (nur Ziffern, dann '-', dann Buchstaben/Ziffern/_/-), wird uebersprungen." >&2
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
            ERRORS+=("users/${base}: Unix-Account '${name}' existiert schon mit UID ${existing_uid}, verlangt wird aber ${uid_num} - eine UID wird nicht stillschweigend geaendert.")
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

        if [ "${#backup_pubs[@]}" -gt 0 ] && [ "${#admin_pubs[@]}" -gt 0 ]; then
            ERRORS+=("users/${base}: hat Keys sowohl unter keys/backup/ als auch keys/admin/ - die Rolle einer Identitaet muss eindeutig sein.")
            continue
        fi
        if [ "${#backup_pubs[@]}" -eq 0 ] && [ "${#admin_pubs[@]}" -eq 0 ]; then
            echo "WARNUNG: users/${base} hat weder unter keys/backup/ noch keys/admin/ einen Key, wird uebersprungen." >&2
            continue
        fi

        if [ "${#backup_pubs[@]}" -gt 0 ]; then
            role="backup"
            PUBFILES_OF_NAME[${name}]="$(printf '%s\n' "${backup_pubs[@]}")"
        else
            role="admin"
            PUBFILES_OF_NAME[${name}]="$(printf '%s\n' "${admin_pubs[@]}")"
        fi

        while IFS= read -r pf; do
            [ -n "${pf}" ] || continue
            resolve_borg_binary "${pf}" >/dev/null || true
        done <<< "${PUBFILES_OF_NAME[${name}]}"

        NAME_OF_UID[${uid_num}]="${name}"
        UID_OF_NAME[${name}]="${uid_num}"
        ROLE_OF_NAME[${name}]="${role}"
    done

    if [ "${#ERRORS[@]}" -gt 0 ]; then
        echo "ERROR: ${#ERRORS[@]} harte(r) Fehler in ${USERS_DIR}/ gefunden - KEINE Aenderung wird uebernommen, der bisherige Stand bleibt aktiv:" >&2
        local e
        for e in "${ERRORS[@]}"; do
            echo "  - ${e}" >&2
        done
        exit 1
    fi
}

apply_all() {
    mkdir -p "${AUTH_KEYS_DIR}"
    chown root:root "${AUTH_KEYS_DIR}"
    chmod 755 "${AUTH_KEYS_DIR}"

    local name uid_num role home_dir tmp_file pf pubkey binary from_file from_value command_str prefix

    for name in "${!UID_OF_NAME[@]}"; do
        uid_num="${UID_OF_NAME[${name}]}"
        role="${ROLE_OF_NAME[${name}]}"
        home_dir="${DATA_DIR}/${name}"

        if ! id "${name}" >/dev/null 2>&1; then
            if [ "${role}" = "admin" ]; then
                useradd --no-create-home --home-dir "${home_dir}" --uid "${uid_num}" \
                    --shell /bin/bash --groups borgusers,borgadmins "${name}"
            else
                useradd --no-create-home --home-dir "${home_dir}" --uid "${uid_num}" \
                    --shell /bin/bash --groups borgusers "${name}"
            fi
            # useradd ohne "-p" legt den Account mit gesperrtem Passwort-Hash
            # an - mit PAM aktiv (siehe "UsePAM no" in sshd_config.template,
            # das hier als Absicherung falls das je wieder aktiviert wird)
            # lehnt sshd trotz reiner Pubkey-Auth sonst mit "account is
            # locked" ab.
            usermod -p '*' "${name}"
        fi

        mkdir -p "${home_dir}"
        if [ "${role}" = "admin" ]; then
            chown "${name}:${name}" "${home_dir}"
            chmod 700 "${home_dir}"
        else
            # Gruppe "borgadmins" statt der privaten Gruppe des Clients:
            # jeder Admin-Account ist Mitglied davon (s.o.) und braucht
            # Lese-/Schreibzugriff auf JEDES /data/<name>, sonst wuerde
            # "--restrict-to-path /data" im Forced Command zwar vom
            # SSH/Borg-Protokoll her erlaubt, aber am Dateisystem selbst
            # scheitern. Andere Backup-Clients bleiben trotzdem aussen vor -
            # die sind nicht Mitglied von "borgadmins".
            chown "${name}:borgadmins" "${home_dir}"
            # 2770, nicht nur 770: das Setgid-Bit (2xxx) sorgt dafuer, dass
            # NEUE Dateien/Verzeichnisse, die "borg serve" hier anlegt, die
            # GRUPPE des Verzeichnisses (borgadmins) erben statt der
            # primaeren Gruppe des erzeugenden Prozesses (die private
            # Gruppe des jeweiligen Clients) - ohne das waeren einzelne
            # Repo-Dateien fuer einen Admin trotz gruppen-lesbarem
            # Verzeichnis selbst nicht zugreifbar. Reicht alleine aber noch
            # nicht: Borgs eigener Default-Umask (0077) wuerde Gruppen-Bits
            # bei jeder neuen Datei ohnehin sofort wieder wegstreichen -
            # siehe "--umask 0007" im Forced Command unten.
            chmod 2770 "${home_dir}"
        fi

        tmp_file="$(mktemp "${AUTH_KEYS_DIR}/.${name}.XXXXXX")"
        while IFS= read -r pf; do
            [ -n "${pf}" ] || continue
            pubkey="$(cat "${pf}")"
            binary="$(resolve_borg_binary "${pf}")"
            # --umask 0007 (statt Borgs Default 0077): neue Dateien
            # innerhalb eines Repos bleiben damit gruppen-lesbar/-schreibbar
            # - notwendig, damit ein Admin (Mitglied der Gruppe
            # "borgadmins", siehe apply_all()) ueberhaupt an Dateien
            # herankommt, die urspruenglich vom Backup-Client selbst
            # angelegt wurden. Das Setgid-Bit auf /data/<name> (ebenfalls
            # apply_all()) sorgt dafuer, dass diese Dateien ueberhaupt der
            # richtigen GRUPPE gehoeren - beides zusammen erst ergibt
            # tatsaechlichen Gruppenzugriff.
            if [ "${role}" = "admin" ]; then
                command_str="${binary} --umask 0007 serve --restrict-to-path ${DATA_DIR}"
            else
                command_str="${binary} --umask 0007 serve --append-only --restrict-to-repository ${home_dir}"
            fi
            prefix=""
            from_file="${pf%.pub}.from"
            if [ -f "${from_file}" ]; then
                from_value="$(tr -d '[:space:]' < "${from_file}")"
                [ -n "${from_value}" ] && prefix="from=\"${from_value}\","
            fi
            echo "${prefix}command=\"${command_str}\",restrict ${pubkey}" >> "${tmp_file}"
        done <<< "${PUBFILES_OF_NAME[${name}]}"

        chown root:root "${tmp_file}"
        # 644, nicht 600: sshd oeffnet eine authorized_keys-Datei AUSSERHALB
        # von "~/.ssh" (unser Fall - siehe AuthorizedKeysFile in
        # sshd_config.template) im unprivilegierten Preauth-Prozess, der
        # dafuer auf die UID der einloggenden Identitaet fallen kann - root-
        # only (600) fuehrt dann trotz root:root-Ownership zu "Permission
        # denied", weil dieser Prozess eben NICHT mehr root ist (empirisch
        # verifiziert, nicht nur eine Vermutung aus der Doku). Kein
        # Sicherheitsproblem: der Inhalt ist ein Public Key + ein Forced
        # Command, beides nicht geheim - waehrend root:root SCHREIBZUGRIFF
        # (die eigentlich schuetzenswerte Eigenschaft) weiterhin exklusiv
        # root vorbehalten bleibt.
        chmod 644 "${tmp_file}"
        mv "${tmp_file}" "${AUTH_KEYS_DIR}/${name}"
        echo "Identitaet '${name}' (uid ${uid_num}, ${role}) -> $(wc -l < "${AUTH_KEYS_DIR}/${name}") Key(s)."
    done

    # Entzug: Dateien fuer Identitaeten, die es unter /users/ nicht mehr
    # gibt (oder deren letzter Key entfernt wurde), verschwinden hier -
    # der Unix-Account und /data/<name> selbst werden NIE automatisch
    # angefasst. Ein geloeschtes Verzeichnis unter /users/ soll niemals
    # implizit zu geloeschten Backup-Daten fuehren; wer einen Account
    # wirklich stilllegen will, macht das bewusst separat.
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
