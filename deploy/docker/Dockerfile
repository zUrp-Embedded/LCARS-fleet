# SOURCE: deploy/docker/Dockerfile
# AUTHOR: bob
# STARDATE: 2026-09-11
# STATUS: l'image LCARS fleet — le kit de pack.sh, posé par les modules de l'installeur comme sur un poste
#
# Le contexte de build est le kit que pack.sh vérifie et scelle, jamais un checkout : l'image se bâtit
# par pack.sh. Paquets, comptes, arbres et épingles viennent des modules ; ce fichier ne porte que ce
# qu'une image seule demande.
# Le noyau du builder n'est pas celui de la cible : les sondes noyau se désarment au build, bwrap se
# sonde au boot (services/container/boot.sh).
# L'uid 1000 de la base est libéré avant le rail et builder part au stage final : le boot donne cet uid
# au siège, et un uid déjà pris le fait boucler sur « useradd: UID 1000 is not unique ».
ARG BASE_IMAGE=ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

FROM ${BASE_IMAGE} AS runtime

ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown
ARG VERSION=2.0
# une révision, trois lecteurs : le label pour le daemon, LCARS_IMAGE_REVISION dans le conteneur, et
# PROV_SOURCE_REV pour 62, qui en estampille la copie posée (une image n'a pas de .git)
ENV PROV_SOURCE_REV=${GIT_SHA} LCARS_IMAGE_REVISION=${GIT_SHA} LANG=C.UTF-8 LCARS_DOCKER=1
LABEL org.opencontainers.image.title="LCARS fleet v2" \
      org.opencontainers.image.description="Control plane pour workloads agentiques faillibles — runtime Elixir/OTP, pods bwrap, forge-state-machine. L'humain SSH dans le conteneur et lance sa fleet." \
      org.opencontainers.image.source="https://github.com/zurp-embedded/LCARS-fleet" \
      org.opencontainers.image.licenses="AGPL-3.0" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.authors="lordzurp"

# ─── 1. le socle : ce que le rail exige avant de tourner, tini pour le PID 1, sshd pour la porte ────
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       ca-certificates curl git sudo tini openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && { userdel -r "$(getent passwd 1000 | cut -d: -f1)" 2>/dev/null || true; } \
    && useradd -m -u 1000 -s /bin/bash builder \
    && mkdir -p /run/sshd

# ─── 2. le kit, posé par le rail ; son .source-revision en fait une livraison binaire ──────────────
COPY --chown=builder:builder . /src/lcars_install
RUN cd /src/lcars_install \
    && PROV_KERNEL_PROBES=0 PROV_COLOR=0 DEBIAN_FRONTEND=noninteractive \
       deploy/provision apply --substrate docker --human builder \
    && cd / && rm -rf /src \
    && rm -rf /var/lib/apt/lists/*

# ─── 3. ce que seule l'image porte ─────────────────────────────────────────────────────────────────
# sur un poste, services.env nomme ce fichier aux unités
ENV TF_CLI_CONFIG_FILE=/opt/lcars/tofu/tofurc
VOLUME ["/home", "/opt/lcars/var"]
EXPOSE 22

HEALTHCHECK --interval=30s --timeout=5s --start-period=300s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/22 && { [ \"${LCARS_LANDING:-1}\" = 1 ] || exit 0; exec 4<>/dev/tcp/127.0.0.1/\"${LCARS_LANDING_PORT:-20999}\"; }"]

ENTRYPOINT ["/usr/bin/tini", "--", "bash", "/opt/lcars/services/container/boot.sh"]

# ─── verify : le doctor du poste sur l'image posée ; final ne copie que sa preuve ─────────────────
FROM runtime AS verify
ARG GIT_SHA=unknown
RUN PROV_KERNEL_PROBES=0 PROV_COLOR=0 \
      /opt/lcars/deploy/provision doctor --substrate docker --human builder \
    && printf '%s\n' "${GIT_SHA}" > /verified

# builder a servi de siège au rail et à son doctor ; le siège réel (uid 1000) se dérive au boot
FROM runtime AS final
RUN userdel -r builder
COPY --from=verify /verified /opt/lcars/.verified
