#!/bin/bash
#
# Baut /home/borg/.ssh/authorized_keys komplett neu aus /keys/backup/*.pub
# und /keys/admin/*.pub. Laeuft bei jedem Container-Start (siehe
# entrypoint.sh) UND kann jederzeit bei laufendem Container erneut
# angestossen werden, um jemanden auszutragen, ohne einen laufenden Backup-
# Transfer eines ANDEREN Clients zu unterbrechen (siehe reload-keys.sh):
#
#   docker compose exec -T borg-server /usr/local/bin/build-authorized-keys.sh
#
# sshd liest authorized_keys ohnehin bei JEDER Verbindung neu vom Datei-
# system (kein In-Memory-Cache ueber die Laufzeit des Daemons) - ein Reload
# heisst also nur "Datei aktualisieren", kein Signal an sshd noetig. Bereits
# laufende Sessions (offene "borg serve"-Prozesse) sind davon nicht
# betroffen, weil authorized_keys nur bei der Authentifizierung NEUER
# Verbindungen gelesen wird - ein entfernter Key beendet also keine gerade
# laufende Übertragung desselben oder eines anderen Clients, verhindert nur
# neue Logins damit.
#
# Wegen des moeglichen Reloads bei laufendem Betrieb wird NICHT direkt in
# authorized_keys geschrieben (siehe unten "atomar ersetzen") - sonst
# koennte eine zeitgleich eintreffende SSH-Verbindung sshd mitten im
# Neuschreiben eine leere oder unvollstaendige Datei lesen lassen.
#
# Backup-Keys bekommen ein Forced Command, das sie auf genau ein Repo unter
# /data/<name> UND auf Append-Only einschraenkt (koennen schreiben, aber
# nichts endgueltig loeschen - siehe README "Sicherheit"). Dafuer
# --restrict-to-repository: erlaubt exakt den einen angegebenen Pfad, keine
# Unterverzeichnisse.
#
# Admin-Keys bekommen volle Rechte (kein --append-only), aber per
# --restrict-to-path auf den /data-Baum begrenzt (im Unterschied zu
# --restrict-to-repository ERLAUBT --restrict-to-path Unterverzeichnisse -
# genau das braucht der Admin, um wahlweise auf /data/<name1>,
# /data/<name2>, ... zuzugreifen), damit ein kompromittierter Admin-Key
# trotzdem keine Shell auf dem Server bekommt.
#
# "restrict" (statt einzelner no-*-Optionen) deaktiviert nebenbei
# Port-/Agent-Forwarding, PTY, X11 - alles, was ueber reines "borg serve"
# hinausgeht.
#
# Borg-Version pro Key: liegt neben <name>.pub eine <name>.version-Datei
# (per add-backup-key.sh/add-admin-key.sh optional erzeugt), wird deren
# Inhalt als Versions-Suffix benutzt (z.B. "1.2.8" -> Binary "borg-1.2.8",
# muss im Image installiert sein, siehe Dockerfile BORG_VERSIONS). Ohne
# eine solche Datei kommt die Default-Version ("borg" ohne Suffix) zum
# Einsatz - aehnlich wie Hetzners Storage Box mehrere Server-Binaries
# parallel anbietet, damit alte Clients nicht zwangsweise mitziehen muessen.

set -euo pipefail

AUTHORIZED_KEYS="/home/borg/.ssh/authorized_keys"
AUTHORIZED_KEYS_TMP="$(mktemp "${AUTHORIZED_KEYS}.XXXXXX")"
DATA_DIR="/data"

# Aufraeumen, falls das Skript vor dem abschliessenden "mv" abbricht (z.B.
# resolve_borg_binary() weiter unten mit "exit 1") - sonst sammeln sich bei
# wiederholten fehlgeschlagenen Reloads Tmp-Dateien im .ssh-Verzeichnis an.
trap 'rm -f "${AUTHORIZED_KEYS_TMP}"' EXIT

resolve_borg_binary() {
    local pubkey_file="$1"
    local version_file="${pubkey_file%.pub}.version"

    if [ ! -f "${version_file}" ]; then
        echo "borg"
        return
    fi

    local version binary
    version="$(tr -d '[:space:]' < "${version_file}")"
    binary="borg-${version}"

    if ! command -v "${binary}" >/dev/null 2>&1; then
        echo "ERROR: ${version_file} verlangt Borg-Version '${version}', aber '${binary}' ist in diesem Image nicht installiert." >&2
        echo "Installierte Versionen:" >&2
        compgen -c borg- | sort >&2
        exit 1
    fi

    echo "${binary}"
}

shopt -s nullglob

for pubkey_file in /keys/backup/*.pub; do
    name="$(basename "${pubkey_file}" .pub)"
    repo_dir="${DATA_DIR}/${name}"
    mkdir -p "${repo_dir}"
    chown borg:borg "${repo_dir}"
    pubkey="$(cat "${pubkey_file}")"
    binary="$(resolve_borg_binary "${pubkey_file}")"
    echo "command=\"${binary} serve --append-only --restrict-to-repository ${repo_dir}\",restrict ${pubkey}" >> "${AUTHORIZED_KEYS_TMP}"
    echo "Backup-Key '${name}' -> ${repo_dir} (append-only, ${binary})"
done

for pubkey_file in /keys/admin/*.pub; do
    name="$(basename "${pubkey_file}" .pub)"
    pubkey="$(cat "${pubkey_file}")"
    binary="$(resolve_borg_binary "${pubkey_file}")"
    echo "command=\"${binary} serve --restrict-to-path ${DATA_DIR}\",restrict ${pubkey}" >> "${AUTHORIZED_KEYS_TMP}"
    echo "Admin-Key '${name}' -> voller Zugriff auf ${DATA_DIR} (${binary})"
done

if [ ! -s "${AUTHORIZED_KEYS_TMP}" ]; then
    echo "WARNUNG: keine Keys in keys/backup/ oder keys/admin/ gefunden - niemand kann sich verbinden." >&2
fi

chown borg:borg "${AUTHORIZED_KEYS_TMP}"
chmod 600 "${AUTHORIZED_KEYS_TMP}"

# Atomar ersetzen (gleiches Verzeichnis/Dateisystem -> "mv" ist ein reines
# rename(2), kein Kopieren) - sshd sieht die Datei nie in einem
# Zwischenzustand, egal wann genau eine Verbindung waehrend eines Reloads
# hereinkommt.
mv "${AUTHORIZED_KEYS_TMP}" "${AUTHORIZED_KEYS}"
