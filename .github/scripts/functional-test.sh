#!/bin/bash
#
# Funktionstest für ein gebautes borg-server-Image: startet den Container
# wirklich (echter sshd, echtes "borg serve"), verbindet sich per SSH von
# außen und prüft nicht nur "kommt eine Verbindung zustande", sondern die
# eigentliche Sicherheitsgrenze:
#   - Backup-Key kann schreiben/lesen, aber "compact" nach "delete" gibt
#     tatsächlich keinen Platz frei (Append-Only greift wirklich - das
#     Kommando läuft mit Exit 0 durch, das ist korrektes Borg-Verhalten,
#     siehe borgbackup.readthedocs.io/en/stable/usage/notes.html unter
#     "append-only mode (forbid compaction)"; erst der Admin-Key darf
#     tatsächlich Platz freigeben).
#   - Backup-Key kommt NICHT an ein fremdes, existierendes Repo unter /data
#     (restrict-to-repository greift, nicht nur "Verzeichnis fehlt").
#   - Backup-Key bekommt KEINE Shell (Forced Command überschreibt jedes
#     angeforderte Kommando).
#   - Admin-Key darf compacten (restrict-to-path erlaubt Unterverzeichnisse).
#   - Ein Key mit eigener <name>.version-Datei benutzt wirklich die dort
#     angegebene Borg-Version (nicht die Default-Version des Images).
#   - SSHD_PUBKEY_ALGORITHMS als Env-Override erlaubt wirklich einen
#     zusätzlichen Key-Typ (RSA, z.B. für einen YubiKey über das
#     PIV-Applet), der mit den Defaults abgelehnt würde.
#
# Aufruf:
#   .github/scripts/functional-test.sh <image-ref>
#
# Braucht nur Docker + einen "ssh"/"ssh-keygen" auf dem Host (für die
# Test-Keypaare und den direkten Forced-Command-Check) - als Borg-CLIENT
# wird dasselbe Image nochmal per "docker run --entrypoint borg" benutzt,
# kein separat installierter Borg-Client auf dem Host nötig.

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

mkdir -p "${WORKDIR}/secrets" "${WORKDIR}/keys/backup" "${WORKDIR}/keys/admin"

echo "=== Test-Keys erzeugen ==="
ssh-keygen -q -t ed25519 -f "${WORKDIR}/secrets/ssh_host_ed25519_key" -C "" -N ""
ssh-keygen -q -t ed25519 -f "${WORKDIR}/backup_client" -C "backup-client" -N ""
ssh-keygen -q -t ed25519 -f "${WORKDIR}/backup_client_other" -C "backup-client-other" -N ""
ssh-keygen -q -t ed25519 -f "${WORKDIR}/admin" -C "admin" -N ""
cp "${WORKDIR}/backup_client.pub" "${WORKDIR}/keys/backup/testclient.pub"
cp "${WORKDIR}/backup_client_other.pub" "${WORKDIR}/keys/backup/otherclient.pub"
cp "${WORKDIR}/admin.pub" "${WORKDIR}/keys/admin/admin1.pub"
echo "hello from functional-test" > "${WORKDIR}/testfile.txt"
# Braucht genug Inhalt, damit ein "compact" messbar Platz freigibt (siehe
# Append-Only-Check unten) - Zufallsdaten, damit Kompression nichts wegkürzt.
head -c 1000000 /dev/urandom > "${WORKDIR}/bigfile.bin"

echo "=== Server-Container starten ==="
CONTAINER=$(docker run -d \
    -p 127.0.0.1::22 \
    -v "${WORKDIR}/secrets/ssh_host_ed25519_key:/etc/ssh/ssh_host_ed25519_key:ro" \
    -v "${WORKDIR}/keys/backup:/keys/backup:ro" \
    -v "${WORKDIR}/keys/admin:/keys/admin:ro" \
    "${IMAGE}")

PORT=$(docker port "${CONTAINER}" 22/tcp | head -n1 | cut -d: -f2)

wait_for_sshd() {
    for _ in $(seq 1 30); do
        if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
            exec 3>&- 3<&-
            return
        fi
        sleep 1
    done
    echo "FAIL: sshd auf Port ${PORT} kam nicht hoch." >&2
    exit 1
}

echo "=== Warte auf sshd auf Port ${PORT} ==="
wait_for_sshd

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
BORG_REPO="ssh://borg@127.0.0.1:${PORT}/data/testclient"

echo "=== borg init (Backup-Key) ==="
borg init --encryption=repokey-blake2

# Erst JETZT prüfen, dass der Key keine Shell bekommt - vorher steht schon
# fest, dass der Key wirklich authentifiziert (borg init hat geklappt),
# ein "Permission denied" hier wäre also eindeutig kein falsches "OK".
echo "=== Forced Command greift: Backup-Key bekommt keine Shell ==="
OUT=$(ssh "${SSH_OPTS[@]}" -i "${WORKDIR}/backup_client" borg@127.0.0.1 whoami 2>&1) && RC=0 || RC=$?
if [ "${RC}" -eq 0 ] && [ "${OUT}" = "borg" ]; then
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
    echo "FAIL: backup_client_other konnte auf /data/testclient zugreifen." >&2
    cat "${WORKDIR}/other-key-out" >&2
    exit 1
fi
echo "OK (Zugriff verweigert)"

echo "=== ... und umgekehrt: testclient-Key kommt NICHT an ein fremdes, existierendes Repo ==="
OTHER_REPO="ssh://borg@127.0.0.1:${PORT}/data/otherclient"
BORG_REPO="${OTHER_REPO}" BORG_RSH="${OTHER_BACKUP_RSH}" borg init --encryption=repokey-blake2
if BORG_REPO="${OTHER_REPO}" borg list >"${WORKDIR}/other-repo-out" 2>&1; then
    echo "FAIL: testclient-Backup-Key konnte auf /data/otherclient zugreifen, obwohl dessen Repo existiert." >&2
    cat "${WORKDIR}/other-repo-out" >&2
    exit 1
fi
echo "OK (Zugriff verweigert, obwohl /data/otherclient existiert)"

echo "=== Mehrere Borg-Versionen: Key mit <name>.version bekommt die richtige Binary ==="
OLD_VERSION="1.2.8"
ssh-keygen -q -t ed25519 -f "${WORKDIR}/backup_client_old" -C "backup-client-old" -N ""
cp "${WORKDIR}/backup_client_old.pub" "${WORKDIR}/keys/backup/oldversion.pub"
echo "${OLD_VERSION}" > "${WORKDIR}/keys/backup/oldversion.version"
# .version-Datei wird nur beim Container-START gelesen (build-authorized-keys.sh
# läuft nicht bei laufendem Container neu) - Neustart nötig, genau wie im
# echten Betrieb nach add-backup-key.sh. Der published Port ist dynamisch
# (-p 127.0.0.1::22 ohne festen Host-Port) und kann sich beim Neustart
# ändern - danach neu abfragen statt den alten Wert weiterzubenutzen.
docker restart "${CONTAINER}" >/dev/null
PORT=$(docker port "${CONTAINER}" 22/tcp | head -n1 | cut -d: -f2)
CONTAINER_SSH_OPTS="-p ${PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes"
wait_for_sshd
# Alle *_RSH-Strings hängen vom (jetzt neuen) Port ab - neu bauen, sonst
# reden die folgenden Schritte noch mit dem Port von vor dem Neustart.
BACKUP_RSH="ssh ${CONTAINER_SSH_OPTS} -i /work/backup_client"
OTHER_BACKUP_RSH="ssh ${CONTAINER_SSH_OPTS} -i /work/backup_client_other"
ADMIN_RSH="ssh ${CONTAINER_SSH_OPTS} -i /work/admin"
BORG_RSH="${BACKUP_RSH}"
BORG_REPO="ssh://borg@127.0.0.1:${PORT}/data/testclient"

OLD_RSH="ssh ${CONTAINER_SSH_OPTS} -i /work/backup_client_old"
OLD_REPO="ssh://borg@127.0.0.1:${PORT}/data/oldversion"
BORG_REPO="${OLD_REPO}" BORG_RSH="${OLD_RSH}" borg init --encryption=repokey-blake2
BORG_REPO="${OLD_REPO}" BORG_RSH="${OLD_RSH}" borg create ::functional-test /work/testfile.txt
BORG_REPO="${OLD_REPO}" BORG_RSH="${OLD_RSH}" borg list

if ! docker logs "${CONTAINER}" 2>&1 | grep -qF "Backup-Key 'oldversion' -> /data/oldversion (append-only, borg-${OLD_VERSION})"; then
    echo "FAIL: Log zeigt nicht, dass 'oldversion' wirklich borg-${OLD_VERSION} zugewiesen bekam." >&2
    docker logs "${CONTAINER}" 2>&1 | tail -20 >&2
    exit 1
fi
echo "OK (Key 'oldversion' läuft über borg-${OLD_VERSION}, init/create/list funktionieren damit)"

echo "=== Append-Only greift: delete + compact mit Backup-Key gibt KEINEN Platz frei ==="
SIZE_BEFORE=$(docker exec "${CONTAINER}" du -sk /data/testclient | cut -f1)
borg delete ::functional-test
borg compact
SIZE_AFTER_BACKUP_COMPACT=$(docker exec "${CONTAINER}" du -sk /data/testclient | cut -f1)
if [ "${SIZE_AFTER_BACKUP_COMPACT}" -lt $(( SIZE_BEFORE * 9 / 10 )) ]; then
    echo "FAIL: 'borg compact' mit dem Append-Only-Backup-Key hat Platz freigegeben (${SIZE_BEFORE}K -> ${SIZE_AFTER_BACKUP_COMPACT}K), sollte es aber nicht." >&2
    exit 1
fi
echo "OK (Repo-Größe unverändert: ${SIZE_BEFORE}K -> ${SIZE_AFTER_BACKUP_COMPACT}K)"

echo "=== Admin-Key: compact gibt den Platz tatsächlich frei ==="
BORG_RSH="${ADMIN_RSH}" borg compact
SIZE_AFTER_ADMIN_COMPACT=$(docker exec "${CONTAINER}" du -sk /data/testclient | cut -f1)
if [ "${SIZE_AFTER_ADMIN_COMPACT}" -ge "${SIZE_AFTER_BACKUP_COMPACT}" ]; then
    echo "FAIL: 'borg compact' mit dem Admin-Key hat keinen Platz freigegeben (${SIZE_AFTER_BACKUP_COMPACT}K -> ${SIZE_AFTER_ADMIN_COMPACT}K)." >&2
    exit 1
fi
echo "OK (Repo geschrumpft: ${SIZE_AFTER_BACKUP_COMPACT}K -> ${SIZE_AFTER_ADMIN_COMPACT}K)"

echo "=== SSHD_PUBKEY_ALGORITHMS-Override: RSA-Key (z.B. YubiKey/PIV) zusätzlich erlauben ==="
ssh-keygen -q -t rsa -b 3072 -f "${WORKDIR}/admin_rsa" -C "admin-rsa" -N ""
mkdir -p "${WORKDIR}/keys2/backup" "${WORKDIR}/keys2/admin"
cp "${WORKDIR}/admin_rsa.pub" "${WORKDIR}/keys2/admin/rsaadmin.pub"

CONTAINER2=$(docker run -d \
    -p 127.0.0.1::22 \
    -e SSHD_PUBKEY_ALGORITHMS="ssh-ed25519,sk-ssh-ed25519@openssh.com,rsa-sha2-512,rsa-sha2-256" \
    -v "${WORKDIR}/secrets/ssh_host_ed25519_key:/etc/ssh/ssh_host_ed25519_key:ro" \
    -v "${WORKDIR}/keys2/backup:/keys/backup:ro" \
    -v "${WORKDIR}/keys2/admin:/keys/admin:ro" \
    "${IMAGE}")
PORT2=$(docker port "${CONTAINER2}" 22/tcp | head -n1 | cut -d: -f2)
for _ in $(seq 1 30); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${PORT2}") 2>/dev/null; then
        exec 3>&- 3<&-
        break
    fi
    sleep 1
done

RSA_RSH="ssh -p ${PORT2} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes -i /work/admin_rsa"
BORG_REPO="ssh://borg@127.0.0.1:${PORT2}/data/rsatest" BORG_RSH="${RSA_RSH}" borg init --encryption=repokey-blake2
BORG_REPO="ssh://borg@127.0.0.1:${PORT2}/data/rsatest" BORG_RSH="${RSA_RSH}" borg create ::functional-test /work/testfile.txt
BORG_REPO="ssh://borg@127.0.0.1:${PORT2}/data/rsatest" BORG_RSH="${RSA_RSH}" borg list
echo "OK (RSA-Key konnte sich per Env-Override authentifizieren und init/create/list ausführen)"

echo
echo "Funktionstest erfolgreich: ${IMAGE}"
