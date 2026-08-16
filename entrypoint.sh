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

/usr/local/bin/build-authorized-keys.sh

# /data gehoert dem borg-User, damit "borg serve" darin schreiben kann -
# das Volume selbst gehoert nach dem ersten Mount sonst root.
chown borg:borg /data

exec /usr/sbin/sshd -D -e
