#!/bin/bash
#
# Funktionstest für ein gebautes borg-server-Image: startet den Container
# wirklich (echter sshd, echtes "borg serve"), verbindet sich per SSH von
# außen und prüft nicht nur "kommt eine Verbindung zustande", sondern die
# eigentliche Sicherheitsgrenze:
#   - Backup-Key kann schreiben/lesen, aber "compact" nach "delete" gibt
#     tatsächlich keinen Platz frei (Append-Only greift wirklich).
#   - Backup-Key kommt NICHT an ein fremdes, existierendes Repo unter /data
#     (restrict-to-repository greift, nicht nur "Verzeichnis fehlt").
#   - Backup-Key bekommt KEINE Shell (Forced Command überschreibt jedes
#     angeforderte Kommando).
#   - Admin-Key darf compacten - UND das trotz eines eigenen Unix-Accounts
#     (nicht mehr derselbe User wie der Backup-Client!), also nur möglich,
#     wenn die Gruppenrechte auf /data/<name> (Owner=Client, Gruppe=
#     borgadmins, Modus 770) UND StrictModes tatsächlich zusammenspielen -
#     genau die Annahme, die dieser Test empirisch verifiziert statt sie nur
#     zu behaupten.
#   - Mehrere Keys für dieselbe Identität (Rotation) sind gleichzeitig
#     gültig.
#   - Ein Key mit eigener <key>.version-Datei benutzt wirklich die dort
#     angegebene Borg-Version.
#   - SSHD_PUBKEY_ALGORITHMS als Env-Override erlaubt wirklich einen
#     zusätzlichen Key-Typ (RSA).
#   - Ein Key lässt sich hinzufügen UND entziehen, ohne den Container neu
#     zu starten (reload-keys.sh-Mechanismus).
#   - Ein harter Fehler in users/ (z.B. doppelt vergebene UID) verhindert
#     jede Änderung – der zuletzt gültige Stand bleibt vollständig aktiv.
#
# Aufruf:
#   .github/scripts/functional-test.sh <image-ref>

set -euo pipefail

IMAGE="${1:?Usage: functional-test.sh <image-ref>}"

WORKDIR="$(mktemp -d)"
CONTAINER=""
CONTAINER2=""

cleanup() {
    if [ -n "${CONTAINER}" ]; then
        docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    fi
    if [ -n "${CONTAINER2}" ]; then
        docker rm -f "${CONTAINER2}" >/dev/null 2>&1 || true
    fi
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${WORKDIR}/secrets" "${WORKDIR}/users"

echo "=== Test-Keys erzeugen ==="
ssh-keygen -q -t ed25519 -f "${WORKDIR}/secrets/ssh_host_ed25519_key" -C "" -N ""
ssh-keygen -q -t ed25519 -f "${WORKDIR}/backup_client" -C "backup-client" -N ""
ssh-keygen -q -t ed25519 -f "${WORKDIR}/backup_client_other" -C "backup-client-other" -N ""
ssh-keygen -q -t ed25519 -f "${WORKDIR}/admin" -C "admin" -N ""
mkdir -p "${WORKDIR}/users/1000-testclient/keys/backup" \
         "${WORKDIR}/users/1001-otherclient/keys/backup" \
         "${WORKDIR}/users/2000-admin1/keys/admin"
cp "${WORKDIR}/backup_client.pub" "${WORKDIR}/users/1000-testclient/keys/backup/key1.pub"
cp "${WORKDIR}/backup_client_other.pub" "${WORKDIR}/users/1001-otherclient/keys/backup/key1.pub"
cp "${WORKDIR}/admin.pub" "${WORKDIR}/users/2000-admin1/keys/admin/key1.pub"
echo "hello from functional-test" > "${WORKDIR}/testfile.txt"
# Braucht genug Inhalt, damit ein "compact" messbar Platz freigibt (siehe
# Append-Only-Check unten) - Zufallsdaten, damit Kompression nichts wegkürzt.
head -c 1000000 /dev/urandom > "${WORKDIR}/bigfile.bin"

echo "=== Server-Container starten ==="
CONTAINER=$(docker run -d \
    -p 127.0.0.1::22 \
    -v "${WORKDIR}/secrets/ssh_host_ed25519_key:/etc/ssh/ssh_host_ed25519_key:ro" \
    -v "${WORKDIR}/users:/users:ro" \
    "${IMAGE}")

PORT=$(docker port "${CONTAINER}" 22/tcp | head -n1 | cut -d: -f2)

wait_for_sshd() {
    # Bewusst mehr als ein bloßer TCP-Connect: sshd nimmt den Connect schon
    # entgegen, kurz bevor es wirklich bereit ist, eine komplette
    # Protokoll-Verhandlung abzuschließen (leerer TCP-Connect-Test war hier
    # flackrig - "Connection reset by peer" mitten in kex_exchange_identification
    # bei der allerersten echten Verbindung nach einem frischen "docker run").
    # Ein "Permission denied (publickey)" beweist dagegen, dass sshd Kex +
    # Authentifizierungsanfrage tatsächlich bis zum Ende durchgespielt hat.
    # "-o IdentitiesOnly=yes -o IdentityFile=/dev/null" ist hier Pflicht,
    # nicht nur Stil: ohne das probiert ssh bei einem lokal laufenden
    # ssh-agent mit mehreren Keys ALLE davon durch, läuft in sshd's
    # MaxAuthTries und bekommt "Too many authentication failures" statt
    # "Permission denied" - das Skript würde dann faelschlich "sshd kam
    # nicht hoch" melden, siehe CLAUDE.md.
    local port="$1" out
    for _ in $(seq 1 30); do
        # "|| true": ssh soll hier erwartbar mit Exit != 0 scheitern
        # (Permission denied) - unter "pipefail" (siehe Skriptkopf) würde
        # eine Pipe zu "grep -q" das faelschlich als Fehlschlag der
        # GESAMTEN Zeile werten, obwohl grep den Treffer findet (pipefail
        # kippt bei JEDEM nicht-null Exit-Code in der Kette, nicht nur beim
        # letzten Glied) - deshalb Ausgabe erst einfangen, dann separat
        # pruefen.
        out="$(ssh -p "${port}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o BatchMode=yes -o ConnectTimeout=3 -o IdentitiesOnly=yes -o IdentityFile=/dev/null \
            "probe@127.0.0.1" true 2>&1 || true)"
        if echo "${out}" | grep -q "Permission denied"; then
            return
        fi
        sleep 1
    done
    echo "FAIL: sshd auf Port ${port} kam nicht hoch." >&2
    exit 1
}

echo "=== Warte auf sshd auf Port ${PORT} ==="
wait_for_sshd "${PORT}"

# Borg-Client: dasselbe Image, "--entrypoint borg" statt sshd, im Host-
# Netzwerk (damit es den published Port unter 127.0.0.1 erreicht) und mit
# WORKDIR als /work gemountet (Keys, Testdatei).
borg() {
    docker run --rm \
        --network host \
        -v "${WORKDIR}:/work" \
        -e BORG_PASSPHRASE="functional-test-not-a-real-secret" \
        -e BORG_REPO="${BORG_REPO}" \
        -e BORG_RSH="${BORG_RSH}" \
        --entrypoint borg \
        "${IMAGE}" "$@"
}

# IdentitiesOnly=yes ist wichtig: ohne das probiert ssh erst alle Keys aus
# einem laufenden ssh-agent durch (falls einer laeuft), bevor der explizit
# per -i angegebene Testkey drankommt - bei einem vollen Agenten laeuft man
# damit in sshd's MaxAuthTries, bevor der eigentliche Test-Key ueberhaupt
# angeboten wird.
SSH_OPTS=(-p "${PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes)
CONTAINER_SSH_OPTS="-p ${PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes"
BACKUP_RSH="ssh ${CONTAINER_SSH_OPTS} -i /work/backup_client"
OTHER_BACKUP_RSH="ssh ${CONTAINER_SSH_OPTS} -i /work/backup_client_other"
ADMIN_RSH="ssh ${CONTAINER_SSH_OPTS} -i /work/admin"

BORG_RSH="${BACKUP_RSH}"
BORG_REPO="ssh://testclient@127.0.0.1:${PORT}/data/testclient"

echo "=== borg init (Backup-Key, eigener Unix-User 'testclient') ==="
borg init --encryption=repokey-blake2

# Erst JETZT prüfen, dass der Key keine Shell bekommt - vorher steht schon
# fest, dass der Key wirklich authentifiziert (borg init hat geklappt),
# ein "Permission denied" hier wäre also eindeutig kein falsches "OK".
echo "=== Forced Command greift: Backup-Key bekommt keine Shell ==="
OUT=$(ssh "${SSH_OPTS[@]}" -i "${WORKDIR}/backup_client" testclient@127.0.0.1 whoami 2>&1) && RC=0 || RC=$?
if [ "${RC}" -eq 0 ] && [ "${OUT}" = "testclient" ]; then
    echo "FAIL: Backup-Key konnte 'whoami' als echtes Kommando ausführen statt borg serve." >&2
    exit 1
fi
echo "OK (Kommando wurde nicht ausgeführt, Forced Command greift)"

echo "=== borg create (Backup-Key) ==="
borg create ::functional-test /work/testfile.txt /work/bigfile.bin

echo "=== borg list (Backup-Key) ==="
borg list

echo "=== Restrict-to-repository greift: fremder Backup-Key kommt NICHT an dieses Repo ==="
if BORG_RSH="${OTHER_BACKUP_RSH}" borg list >"${WORKDIR}/other-key-out" 2>&1; then
    echo "FAIL: otherclient konnte auf /data/testclient zugreifen." >&2
    cat "${WORKDIR}/other-key-out" >&2
    exit 1
fi
echo "OK (Zugriff verweigert)"

echo "=== ... und umgekehrt: testclient-Key kommt NICHT an ein fremdes, existierendes Repo ==="
OTHER_REPO="ssh://otherclient@127.0.0.1:${PORT}/data/otherclient"
BORG_REPO="${OTHER_REPO}" BORG_RSH="${OTHER_BACKUP_RSH}" borg init --encryption=repokey-blake2
if BORG_REPO="${OTHER_REPO}" borg list >"${WORKDIR}/other-repo-out" 2>&1; then
    echo "FAIL: testclient-Backup-Key konnte auf /data/otherclient zugreifen, obwohl dessen Repo existiert." >&2
    cat "${WORKDIR}/other-repo-out" >&2
    exit 1
fi
echo "OK (Zugriff verweigert, obwohl /data/otherclient existiert)"

echo "=== Mehrere Keys pro Identität (Rotation): zweiter Key für 'testclient' funktioniert parallel ==="
ssh-keygen -q -t ed25519 -f "${WORKDIR}/backup_client_rotated" -C "backup-client-rotated" -N ""
cp "${WORKDIR}/backup_client_rotated.pub" "${WORKDIR}/users/1000-testclient/keys/backup/key2.pub"
docker exec "${CONTAINER}" /usr/local/bin/build-authorized-keys.sh >/dev/null
ROTATED_RSH="ssh ${CONTAINER_SSH_OPTS} -i /work/backup_client_rotated"
BORG_RSH="${ROTATED_RSH}" borg list
BORG_RSH="${BACKUP_RSH}" borg list
echo "OK (alter UND neuer Key funktionieren gleichzeitig für dieselbe Identität)"

rm "${WORKDIR}/users/1000-testclient/keys/backup/key2.pub"
docker exec "${CONTAINER}" /usr/local/bin/build-authorized-keys.sh >/dev/null
if BORG_RSH="${ROTATED_RSH}" borg list >"${WORKDIR}/rotated-out" 2>&1; then
    echo "FAIL: rotierter Key funktionierte nach dem Entfernen noch." >&2
    exit 1
fi
echo "OK (rotierter Key nach Entfernen + Reload nicht mehr gültig)"

echo "=== Live-Reload ohne Neustart: neue Identität wirkt sofort, alter Port bleibt ==="
ssh-keygen -q -t ed25519 -f "${WORKDIR}/backup_client_live" -C "backup-client-live" -N ""
mkdir -p "${WORKDIR}/users/1002-liveclient/keys/backup"
cp "${WORKDIR}/backup_client_live.pub" "${WORKDIR}/users/1002-liveclient/keys/backup/key1.pub"
# KEIN "docker restart" - genau das ist der Punkt von reload-keys.sh: die
# Datei steht schon (Bind-Mount), nur der Container muss den Unix-Account
# + authorized_keys neu aufbauen.
docker exec "${CONTAINER}" /usr/local/bin/build-authorized-keys.sh >/dev/null

LIVE_RSH="ssh ${CONTAINER_SSH_OPTS} -i /work/backup_client_live"
LIVE_REPO="ssh://liveclient@127.0.0.1:${PORT}/data/liveclient"
BORG_REPO="${LIVE_REPO}" BORG_RSH="${LIVE_RSH}" borg init --encryption=repokey-blake2
BORG_REPO="${LIVE_REPO}" BORG_RSH="${LIVE_RSH}" borg list
echo "OK (neue Identität ohne Neustart nutzbar, weiterhin auf Port ${PORT})"

echo "=== ... und vollständiger Entzug (Verzeichnis weg) wirkt genauso ohne Neustart ==="
rm -rf "${WORKDIR}/users/1002-liveclient"
docker exec "${CONTAINER}" /usr/local/bin/build-authorized-keys.sh >/dev/null
if BORG_REPO="${LIVE_REPO}" BORG_RSH="${LIVE_RSH}" borg list >"${WORKDIR}/revoked-out" 2>&1; then
    echo "FAIL: liveclient konnte sich nach dem Entfernen + Reload noch verbinden." >&2
    cat "${WORKDIR}/revoked-out" >&2
    exit 1
fi
echo "OK (Zugriff nach Entzug + Reload verweigert, /data/liveclient selbst bleibt aber erhalten)"
docker exec "${CONTAINER}" test -d /data/liveclient
echo "OK (Daten von liveclient wurden NICHT gelöscht, nur der Zugriff)"

echo "=== Harter Fehler in users/: doppelt vergebene UID verhindert JEDE Änderung ==="
mkdir -p "${WORKDIR}/users/1000-duplicate/keys/backup"
ssh-keygen -q -t ed25519 -f "${WORKDIR}/backup_client_dup" -C "dup" -N ""
cp "${WORKDIR}/backup_client_dup.pub" "${WORKDIR}/users/1000-duplicate/keys/backup/key1.pub"
if docker exec "${CONTAINER}" /usr/local/bin/build-authorized-keys.sh >"${WORKDIR}/dup-out" 2>&1; then
    echo "FAIL: build-authorized-keys.sh hat eine doppelt vergebene UID (1000) akzeptiert." >&2
    cat "${WORKDIR}/dup-out" >&2
    exit 1
fi
echo "OK (harter Fehler erkannt, Skript brach mit Exit != 0 ab)"
# Der zuletzt gültige Stand muss trotzdem noch vollständig funktionieren -
# das ist der eigentliche Punkt des harten Fehlers, nicht nur "Skript meldet
# Exit-Code ungleich 0".
BORG_RSH="${BACKUP_RSH}" borg list
echo "OK (bisheriger Stand - testclient - funktioniert nach dem fehlgeschlagenen Reload unverändert weiter)"
rm -rf "${WORKDIR}/users/1000-duplicate"
docker exec "${CONTAINER}" /usr/local/bin/build-authorized-keys.sh >/dev/null

echo "=== Mehrere Borg-Versionen: Key mit <key>.version bekommt die richtige Binary ==="
OLD_VERSION="1.2.8"
ssh-keygen -q -t ed25519 -f "${WORKDIR}/backup_client_old" -C "backup-client-old" -N ""
mkdir -p "${WORKDIR}/users/1003-oldversion/keys/backup"
cp "${WORKDIR}/backup_client_old.pub" "${WORKDIR}/users/1003-oldversion/keys/backup/key1.pub"
echo "${OLD_VERSION}" > "${WORKDIR}/users/1003-oldversion/keys/backup/key1.version"
docker exec "${CONTAINER}" /usr/local/bin/build-authorized-keys.sh >/dev/null

OLD_RSH="ssh ${CONTAINER_SSH_OPTS} -i /work/backup_client_old"
OLD_REPO="ssh://oldversion@127.0.0.1:${PORT}/data/oldversion"
BORG_REPO="${OLD_REPO}" BORG_RSH="${OLD_RSH}" borg init --encryption=repokey-blake2
BORG_REPO="${OLD_REPO}" BORG_RSH="${OLD_RSH}" borg create ::functional-test /work/testfile.txt
BORG_REPO="${OLD_REPO}" BORG_RSH="${OLD_RSH}" borg list

if ! docker exec "${CONTAINER}" grep -qF "borg-${OLD_VERSION} --umask 0007 serve --append-only --restrict-to-repository /data/oldversion" /etc/ssh/authorized_keys/oldversion; then
    echo "FAIL: authorized_keys/oldversion zeigt nicht, dass 'oldversion' wirklich borg-${OLD_VERSION} zugewiesen bekam." >&2
    docker exec "${CONTAINER}" cat /etc/ssh/authorized_keys/oldversion >&2
    exit 1
fi
echo "OK (Identität 'oldversion' läuft über borg-${OLD_VERSION}, init/create/list funktionieren damit)"

echo "=== Append-Only greift: delete + compact mit Backup-Key gibt KEINEN Platz frei ==="
SIZE_BEFORE=$(docker exec "${CONTAINER}" du -sk /data/testclient | cut -f1)
BORG_RSH="${BACKUP_RSH}" BORG_REPO="ssh://testclient@127.0.0.1:${PORT}/data/testclient" borg delete ::functional-test
BORG_RSH="${BACKUP_RSH}" BORG_REPO="ssh://testclient@127.0.0.1:${PORT}/data/testclient" borg compact
SIZE_AFTER_BACKUP_COMPACT=$(docker exec "${CONTAINER}" du -sk /data/testclient | cut -f1)
if [ "${SIZE_AFTER_BACKUP_COMPACT}" -lt $(( SIZE_BEFORE * 9 / 10 )) ]; then
    echo "FAIL: 'borg compact' mit dem Append-Only-Backup-Key hat Platz freigegeben (${SIZE_BEFORE}K -> ${SIZE_AFTER_BACKUP_COMPACT}K), sollte es aber nicht." >&2
    exit 1
fi
echo "OK (Repo-Größe unverändert: ${SIZE_BEFORE}K -> ${SIZE_AFTER_BACKUP_COMPACT}K)"

echo "=== Admin-Key (eigener Unix-User 'admin1'): compact gibt den Platz tatsächlich frei ==="
echo "    (prüft dabei implizit, dass die borgadmins-Gruppenrechte auf /data/testclient"
echo "    UND StrictModes bei $HOME=/data/admin1 wirklich zusammenspielen)"
BORG_REPO="ssh://admin1@127.0.0.1:${PORT}/data/testclient" BORG_RSH="${ADMIN_RSH}" borg compact
SIZE_AFTER_ADMIN_COMPACT=$(docker exec "${CONTAINER}" du -sk /data/testclient | cut -f1)
if [ "${SIZE_AFTER_ADMIN_COMPACT}" -ge "${SIZE_AFTER_BACKUP_COMPACT}" ]; then
    echo "FAIL: 'borg compact' mit dem Admin-Key hat keinen Platz freigegeben (${SIZE_AFTER_BACKUP_COMPACT}K -> ${SIZE_AFTER_ADMIN_COMPACT}K)." >&2
    exit 1
fi
echo "OK (Repo geschrumpft: ${SIZE_AFTER_BACKUP_COMPACT}K -> ${SIZE_AFTER_ADMIN_COMPACT}K)"

echo "=== SSHD_PUBKEY_ALGORITHMS-Override: RSA-Key (z.B. YubiKey/PIV) zusätzlich erlauben ==="
ssh-keygen -q -t rsa -b 3072 -f "${WORKDIR}/admin_rsa" -C "admin-rsa" -N ""
ssh-keygen -q -t ed25519 -f "${WORKDIR}/backup_client_rsatest" -C "backup-client-rsatest" -N ""
mkdir -p "${WORKDIR}/users2/1500-rsaadmin/keys/admin" "${WORKDIR}/users2/1501-rsatest/keys/backup"
cp "${WORKDIR}/admin_rsa.pub" "${WORKDIR}/users2/1500-rsaadmin/keys/admin/key1.pub"
cp "${WORKDIR}/backup_client_rsatest.pub" "${WORKDIR}/users2/1501-rsatest/keys/backup/key1.pub"

CONTAINER2=$(docker run -d \
    -p 127.0.0.1::22 \
    -e SSHD_PUBKEY_ALGORITHMS="ssh-ed25519,sk-ssh-ed25519@openssh.com,rsa-sha2-512,rsa-sha2-256" \
    -v "${WORKDIR}/secrets/ssh_host_ed25519_key:/etc/ssh/ssh_host_ed25519_key:ro" \
    -v "${WORKDIR}/users2:/users:ro" \
    "${IMAGE}")
PORT2=$(docker port "${CONTAINER2}" 22/tcp | head -n1 | cut -d: -f2)
wait_for_sshd "${PORT2}"

# /data/rsatest existiert erst NACHDEM build-authorized-keys.sh die
# Identitaet "rsatest" verarbeitet hat (Registrierung, kein manuelles
# "borg init" durch einen Admin direkt unter /data - das ist im neuen
# Modell bewusst nicht mehr vorgesehen, jede Identitaet bekommt ihr
# Datenverzeichnis ausschliesslich ueber users/<uid>-<name>/).
RSATEST_RSH="ssh -p ${PORT2} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes -i /work/backup_client_rsatest"
BORG_REPO="ssh://rsatest@127.0.0.1:${PORT2}/data/rsatest" BORG_RSH="${RSATEST_RSH}" borg init --encryption=repokey-blake2
BORG_REPO="ssh://rsatest@127.0.0.1:${PORT2}/data/rsatest" BORG_RSH="${RSATEST_RSH}" borg create ::functional-test /work/testfile.txt /work/bigfile.bin
BORG_REPO="ssh://rsatest@127.0.0.1:${PORT2}/data/rsatest" BORG_RSH="${RSATEST_RSH}" borg delete ::functional-test
BORG_REPO="ssh://rsatest@127.0.0.1:${PORT2}/data/rsatest" BORG_RSH="${RSATEST_RSH}" borg compact
SIZE_BEFORE2=$(docker exec "${CONTAINER2}" du -sk /data/rsatest | cut -f1)

RSA_RSH="ssh -p ${PORT2} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes -i /work/admin_rsa"
BORG_REPO="ssh://rsaadmin@127.0.0.1:${PORT2}/data/rsatest" BORG_RSH="${RSA_RSH}" borg list
BORG_REPO="ssh://rsaadmin@127.0.0.1:${PORT2}/data/rsatest" BORG_RSH="${RSA_RSH}" borg compact
SIZE_AFTER2=$(docker exec "${CONTAINER2}" du -sk /data/rsatest | cut -f1)
if [ "${SIZE_AFTER2}" -ge "${SIZE_BEFORE2}" ]; then
    echo "FAIL: RSA-Admin-Key konnte /data/rsatest zwar lesen, aber 'compact' gab keinen Platz frei (${SIZE_BEFORE2}K -> ${SIZE_AFTER2}K)." >&2
    exit 1
fi
echo "OK (RSA-Key authentifiziert per Env-Override, kann fremdes Repo lesen UND compacten: ${SIZE_BEFORE2}K -> ${SIZE_AFTER2}K)"

echo
echo "Funktionstest erfolgreich: ${IMAGE}"
