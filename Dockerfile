# syntax=docker/dockerfile:1

# ---- Builder-Stage: Compiler/Header/pip nur hier, nie im Endergebnis ----
FROM python:3.14-slim AS builder

# ARG-Werte werden von Docker bei jedem "FROM" zurueckgesetzt - ein "ARG"
# VOR der ersten FROM-Zeile waere nur in FROM-Zeilen selbst sichtbar, nicht
# in RUN-Befehlen einer Stage. Deshalb steht diese Zeile zwangsweise ZWEI
# MAL im Dockerfile (hier und nochmal unten bei der Runtime-Stage, mit
# identischem Default) - keine Kopierpanne, sondern Docker-Mechanik. Ein
# einzelnes "docker build --build-arg BORG_VERSIONS=..." reicht trotzdem:
# das gilt automatisch fuer alle gleichnamigen ARGs in allen Stages. Nur
# die hartcodierten DEFAULTS hier und unten muessen von Hand synchron
# gehalten werden, wenn man sie dauerhaft (nicht nur per --build-arg)
# aendern will.
ARG BORG_VERSIONS="1.4.5 1.2.8"

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      pkg-config \
      libssl-dev \
      libacl1-dev \
      liblz4-dev \
      libzstd-dev \
 && rm -rf /var/lib/apt/lists/*

# Jede Borg-Version in ihr eigenes venv (pip kann pro Umgebung nur eine
# Version eines Pakets halten). Das venv-eigene python3-Binary ist ein
# Symlink auf die Basis dieses Images (kein "--copies") - funktioniert nur,
# weil die Runtime-Stage unten exakt dieselbe Basis (python:3.14-slim) hat.
RUN set -e \
 && for VERSION in ${BORG_VERSIONS}; do \
        python3 -m venv "/opt/borg-${VERSION}"; \
        "/opt/borg-${VERSION}/bin/pip" install --no-cache-dir --quiet "borgbackup==${VERSION}"; \
    done

# ---- Runtime-Stage: nur was sshd/borg zur Laufzeit tatsaechlich braucht ----
FROM python:3.14-slim

# BORG_VERSIONS hier erneut deklariert (identischer Default wie oben in der
# Builder-Stage) - notwendig, kein Copy-Paste-Versehen, siehe Kommentar dort.
#
# BORG_DEFAULT_VERSION bekommt zusaetzlich den Symlink ohne Suffix ("borg") -
# das ist die Version, die Keys OHNE eigene <name>.version-Datei benutzen
# (siehe build-authorized-keys.sh). Muss Teil von BORG_VERSIONS sein.
ARG BORG_VERSIONS="1.4.5 1.2.8"
ARG BORG_DEFAULT_VERSION=1.4.5

# Nur Laufzeit-Bibliotheken (kein "-dev", kein Compiler, kein pip-Cache) -
# per "ldd" gegen die tatsaechlich gebauten Borg-Extensions verifiziert
# (libacl/libcrypto/liblz4/libxxhash/libz/libzstd), nicht geraten. Kein
# ca-certificates mehr noetig - HTTPS (pip) passiert nur in der
# Builder-Stage, hier wird nichts mehr heruntergeladen.
#
# openssh-server zieht openssh-client als Dependency automatisch mit (auch
# mit --no-install-recommends, das blendet nur Recommends/Suggests aus,
# keine Depends) - wichtig, denn entrypoint.sh braucht "ssh-keygen" daraus.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server \
      libssl3t64 \
      libacl1 \
      liblz4-1 \
      libxxhash0 \
      libzstd1 \
      zlib1g \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/ssh/ssh_host_*
# Das openssh-server-Paket erzeugt beim Installieren automatisch
# Default-Hostkeys (inkl. .pub). Die muessen weg: entrypoint.sh mountet zur
# Laufzeit den echten privaten Hostkey rein (persistent, aus secrets/ auf
# dem Host) und leitet den public part jedes Mal frisch davon ab - ein
# liegen gebliebener alter .pub wuerde dann nicht mehr zum neuen privaten
# Key passen und sshd verweigert mit "Public key ... does not match
# private key" den Start.

COPY --from=builder /opt /opt

RUN set -e \
 && for VERSION in ${BORG_VERSIONS}; do \
        ln -s "/opt/borg-${VERSION}/bin/borg" "/usr/local/bin/borg-${VERSION}"; \
    done \
 && test -x "/usr/local/bin/borg-${BORG_DEFAULT_VERSION}" \
 && ln -s "/usr/local/bin/borg-${BORG_DEFAULT_VERSION}" /usr/local/bin/borg \
 && borg --version

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

COPY sshd_config.template /etc/ssh/sshd_config.template
COPY build-authorized-keys.sh /usr/local/bin/build-authorized-keys.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/build-authorized-keys.sh /usr/local/bin/entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
