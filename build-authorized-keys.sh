#!/bin/bash
#
# Baut /home/borg/.ssh/authorized_keys komplett neu aus /keys/backup/*.pub
# und /keys/admin/*.pub. Laeuft bei jedem Container-Start (siehe
# entrypoint.sh) - Keys hinzufuegen/entfernen heisst also nur: Datei unter
# keys/ auf dem Host anlegen/loeschen, Container neu starten.
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

set -euo pipefail

AUTHORIZED_KEYS="/home/borg/.ssh/authorized_keys"
DATA_DIR="/data"

: > "${AUTHORIZED_KEYS}"

shopt -s nullglob

for pubkey_file in /keys/backup/*.pub; do
    name="$(basename "${pubkey_file}" .pub)"
    repo_dir="${DATA_DIR}/${name}"
    mkdir -p "${repo_dir}"
    chown borg:borg "${repo_dir}"
    pubkey="$(cat "${pubkey_file}")"
    echo "command=\"borg serve --append-only --restrict-to-repository ${repo_dir}\",restrict ${pubkey}" >> "${AUTHORIZED_KEYS}"
    echo "Backup-Key '${name}' -> ${repo_dir} (append-only)"
done

for pubkey_file in /keys/admin/*.pub; do
    name="$(basename "${pubkey_file}" .pub)"
    pubkey="$(cat "${pubkey_file}")"
    echo "command=\"borg serve --restrict-to-path ${DATA_DIR}\",restrict ${pubkey}" >> "${AUTHORIZED_KEYS}"
    echo "Admin-Key '${name}' -> voller Zugriff auf ${DATA_DIR}"
done

if [ ! -s "${AUTHORIZED_KEYS}" ]; then
    echo "WARNUNG: keine Keys in keys/backup/ oder keys/admin/ gefunden - niemand kann sich verbinden." >&2
fi

chown borg:borg "${AUTHORIZED_KEYS}"
chmod 600 "${AUTHORIZED_KEYS}"
