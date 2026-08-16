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

sed \
    -e "s|__PUBKEY_ALGORITHMS__|${SSHD_PUBKEY_ALGORITHMS}|" \
    -e "s|__KEX_ALGORITHMS__|${SSHD_KEX_ALGORITHMS}|" \
    -e "s|__CIPHERS__|${SSHD_CIPHERS}|" \
    -e "s|__MACS__|${SSHD_MACS}|" \
    /etc/ssh/sshd_config.template > /etc/ssh/sshd_config

# Config-Fehler (z.B. Tippfehler in einer der SSHD_*-Variablen) jetzt klar
# melden, statt sshd erst beim eigentlichen Start scheitern zu lassen.
sshd -t

/usr/local/bin/build-authorized-keys.sh

# /data gehoert dem borg-User, damit "borg serve" darin schreiben kann -
# das Volume selbst gehoert nach dem ersten Mount sonst root.
chown borg:borg /data

exec /usr/sbin/sshd -D -e
