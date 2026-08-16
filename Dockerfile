FROM python:3.14-slim

ARG BORG_VERSION=1.4.5

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server \
      ca-certificates \
      build-essential \
      pkg-config \
      libssl-dev \
      libacl1-dev \
      liblz4-dev \
      libzstd-dev \
 && pip install --no-cache-dir "borgbackup==${BORG_VERSION}" \
 && apt-get purge -y \
      ca-certificates \
      build-essential \
      pkg-config \
      libssl-dev \
      libacl1-dev \
      liblz4-dev \
      libzstd-dev \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* \
 && borg --version \
 && rm -f /etc/ssh/ssh_host_*
# Das openssh-server-Paket erzeugt beim Installieren automatisch
# Default-Hostkeys (inkl. .pub). Die muessen weg: entrypoint.sh mountet zur
# Laufzeit den echten privaten Hostkey rein (persistent, aus secrets/ auf
# dem Host) und leitet den public part jedes Mal frisch davon ab - ein
# liegen gebliebener alter .pub wuerde dann nicht mehr zum neuen privaten
# Key passen und sshd verweigert mit "Public key ... does not match
# private key" den Start.

# "borg" ist ein normaler User mit echter Shell (kein /usr/sbin/nologin!) -
# sshd fuehrt Forced Commands aus authorized_keys ueber die Login-Shell des
# Users aus, "nologin" wuerde also auch den erzwungenen "borg serve"-Aufruf
# verhindern, nicht nur einen interaktiven Login. Die eigentliche
# Einschraenkung passiert nicht ueber die Shell, sondern ueber "restrict" +
# "command=" pro Key in authorized_keys (siehe build-authorized-keys.sh).
#
# usermod -p '*': useradd legt den Account ohne -p standardmaessig mit
# gesperrtem Passwort-Hash ("!") an. Selbst bei reiner Pubkey-Auth prueft
# sshd (UsePAM yes, Default) per PAM zusaetzlich den Account-Status und
# verweigert dann mit "account is locked" - "*" ist ein Hash, der nie
# matcht, aber PAM nicht als gesperrt gilt.
RUN useradd --create-home --shell /bin/bash borg \
 && usermod -p '*' borg \
 && mkdir -p /home/borg/.ssh /data /run/sshd \
 && chmod 700 /home/borg/.ssh \
 && chown borg:borg /home/borg/.ssh /data

COPY sshd_config /etc/ssh/sshd_config
COPY build-authorized-keys.sh /usr/local/bin/build-authorized-keys.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/build-authorized-keys.sh /usr/local/bin/entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
