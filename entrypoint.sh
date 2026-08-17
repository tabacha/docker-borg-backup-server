#!/bin/bash
set -euo pipefail

if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    echo "ERROR: /etc/ssh/ssh_host_ed25519_key fehlt." >&2
    echo "secrets/ssh_host_ed25519_key (per setup-secrets.sh erzeugt) muss gemountet sein." >&2
    exit 1
fi
# Wird read-only gemountet (compose.yml) - Rechte kommen schon vom Host
# (setup-secrets.sh setzt 600), hier also NICHT chmod versuchen, das
# scheitert sonst am read-only Mount.

# Public Key frisch vom (gemounteten) privaten Hostkey ableiten - im Image
# liegt bewusst kein .pub, siehe Kommentar im Dockerfile.
ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key > /etc/ssh/ssh_host_ed25519_key.pub

# sshd_config aus dem Template rendern - Krypto-Algorithmen per Env
# ueberschreibbar (z.B. fuer einen RSA-YubiKey als Admin-Key, siehe README
# "SSH-Haertung"), sonst die engen Defaults aus sshd_config.template.
SSHD_PUBKEY_ALGORITHMS="${SSHD_PUBKEY_ALGORITHMS:-ssh-ed25519,sk-ssh-ed25519@openssh.com}"
SSHD_KEX_ALGORITHMS="${SSHD_KEX_ALGORITHMS:-mlkem768x25519-sha256,curve25519-sha256}"
SSHD_CIPHERS="${SSHD_CIPHERS:-chacha20-poly1305@openssh.com}"
SSHD_MACS="${SSHD_MACS:-hmac-sha2-256-etm@openssh.com}"
SSHD_MAX_AUTH_TRIES="${SSHD_MAX_AUTH_TRIES:-3}"

sed \
    -e "s|__PUBKEY_ALGORITHMS__|${SSHD_PUBKEY_ALGORITHMS}|" \
    -e "s|__KEX_ALGORITHMS__|${SSHD_KEX_ALGORITHMS}|" \
    -e "s|__CIPHERS__|${SSHD_CIPHERS}|" \
    -e "s|__MACS__|${SSHD_MACS}|" \
    -e "s|__MAX_AUTH_TRIES__|${SSHD_MAX_AUTH_TRIES}|" \
    /etc/ssh/sshd_config.template > /etc/ssh/sshd_config

# Config-Fehler (z.B. Tippfehler in einer der SSHD_*-Variablen) jetzt klar
# melden, statt sshd erst beim eigentlichen Start scheitern zu lassen.
sshd -t

# /data selbst bleibt root:root, 755 - die einzelnen /data/<name>-
# Unterverzeichnisse (jeweils einer eigenen, dynamisch angelegten
# Identitaet gehoerend) setzt build-authorized-keys.sh selbst, siehe dort.
chown root:root /data
chmod 755 /data

# Legt fuer jede Identitaet unter /users/ den Unix-Account, das Home-
# Verzeichnis und die authorized_keys-Datei an (oder bricht mit "exit 1"
# hart ab, siehe Kommentar dort - dann startet sshd bewusst gar nicht erst).
/usr/local/bin/build-authorized-keys.sh

exec /usr/sbin/sshd -D -e
