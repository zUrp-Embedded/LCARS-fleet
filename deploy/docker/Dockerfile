# SOURCE: deploy/docker/Dockerfile
# AUTHOR: bob
# STARDATE: 2026-09-11
# STATUS: PROTO-V2 — l'image LCARS fleet v2, BATIE PAR LE RAIL : le kit de pack.sh, pose par les memes modules que le poste
#
# ─── UN SEUL PIPELINE, ET C'EST TOUT CE QUE CE FICHIER A A DIRE ──────────────────────────────────
#
# Jusqu'au 2026-09-11 ce fichier etait un JUMEAU : 700 lignes qui reposaient a la main ce que les
# modules de deploy/modules.d posent sur un poste — les memes paquets, les memes comptes, les memes
# arbres, les memes pins (tofu, xterm, elixir), avec un temoin par paire pour tenir les deux copies
# egales. ⚖ user 2026-09-09 : « le pipeline le plus teste et rode, c'est WSL ; si on peut construire
# l'image docker avec ce pipeline… ». Le spike du 2026-09-10 a repondu oui (02-CIBLE § 3). L'image
# se pose en trois gestes :
#   1. le socle que la base n'a pas pour jouer le rail (curl, git, sudo, ca-certificates), tini pour
#      le PID 1 et sshd pour la porte d'entree — ce que seule une image demande ;
#   2. le KIT de `pack.sh` (l'arbre, la release et la doc deja baties : livraison binaire, rien ne se
#      compile ici) copie dans /src, et `provision apply --substrate docker` qui le pose sous
#      /opt/lcars — les modules selectionnes par leur en-tete APPLY-ON, jamais par une liste ici ;
#   3. ce que seule l'image porte : volumes, port, healthcheck, l'entrypoint du produit.
# Le stage `verify` rejoue le doctor sur l'image posee ; `final` en garde la preuve.
#
# CE QUI N'EST PLUS ICI, ET OU C'EST : les paquets (10-packages), la toolchain (15 — non requise sur
# un kit, la release embarque son ERTS), node (16, idem : la doc arrive batie), la doc et les medias
# (44), tofu et son miroir (46), la release et les liens du PATH (60), les auxiliaires, les arbres
# embarques, le client de console et le raccord du squelette (62), les comptes et groupes de service
# (20, 21), les repertoires (25, par la table system.manifest).
#
# LE CONTEXTE DE BUILD EST LE KIT, PAS LE CHECKOUT : `pack.sh` batit l'image depuis son stage
# verifie (`docker build … "$STAGE/$ROOT"`). Un `docker build` depuis un checkout nu n'a plus de
# sens — il n'y a plus de stage qui compile, et c'est voulu : une image dont le gate n'a pas vu les
# bits n'existe pas (pack.sh refuse un arbre modifie, joue le gate, puis scelle).
#
# ⚠ LES SONDES NOYAU SONT DESARMEES AU BUILD (PROV_KERNEL_PROBES=0) : le noyau du builder n'est pas
# celui de la cible — bwrap se sonde au boot, cote produit (services/container/boot.sh).
# ⚠ L'UID 1000 EST PRIS DANS LA BASE (ubuntu:26.04 y pose « ubuntu ») et c'est celui que le boot
# donne au siege (LCARS_UID) : on le libere AVANT le rail, et l'humain de build — celui que 10 et
# 15 sondent (`--human`) — est retire APRES. Un boot qui trouve l'uid pris BOUCLE sur
# « useradd: UID 1000 is not unique » et le conteneur ne devient jamais healthy.
# Pin par DIGEST (l'immutabilite ne se declare pas, elle s'epingle) : bump = nouveau digest ICI.
ARG BASE_IMAGE=ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

FROM ${BASE_IMAGE} AS runtime

ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown
ARG VERSION=2.0
# La revision, des deux cotes : le LABEL OCI pour le daemon, l'ENV pour l'interieur (un conteneur ne
# lit pas son propre label), et PROV_SOURCE_REV pour le rail — 62 estampille
# /opt/lcars/.source-revision avec elle ; sans elle une image sans .git rendrait « inconnue » et le
# doctor un drift permanent. Une seule origine pour les trois, sinon elles divergent.
ENV PROV_SOURCE_REV=${GIT_SHA} LCARS_IMAGE_REVISION=${GIT_SHA} LANG=C.UTF-8 LCARS_DOCKER=1
LABEL org.opencontainers.image.title="LCARS fleet v2" \
      org.opencontainers.image.description="Control plane pour workloads agentiques faillibles — runtime Elixir/OTP, pods bwrap, forge-state-machine. L'humain SSH dans le conteneur et lance sa fleet." \
      org.opencontainers.image.source="https://github.com/lordzurp/LCARS-fleet" \
      org.opencontainers.image.licenses="AGPL-3.0" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.authors="lordzurp"

# ─── 1. LE SOCLE DE L'IMAGE — ce que le rail ne pose pas parce qu'il en a besoin, ou qu'un poste n'a pas ─
# curl/git/sudo/ca-certificates : ce que la porte exige avant de jouer le rail (install.sh les sonde,
# 10-packages les tient). tini : le PID 1. openssh-server : la porte d'entree de l'humain, que seule
# une image porte (sur un poste, sshd est celui de la distro).
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       ca-certificates curl git sudo tini openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && { userdel -r "$(getent passwd 1000 | cut -d: -f1)" 2>/dev/null || true; } \
    && useradd -m -u 1000 -s /bin/bash builder \
    && mkdir -p /run/sshd

# ─── 2. LE KIT, ET LE RAIL QUI LE POSE ────────────────────────────────────────────────────────────
# Le contexte EST le kit (`lcars_install/` de pack.sh) : deploy/, la release sous
# runtime/_build/prod/rel, la doc sous assets/github.io/dist, `.source-revision` a la racine —
# c'est ce tampon qui fait dire « binaire » a prov_delivery, donc « rien a batir » a 15 et 16.
COPY --chown=builder:builder . /src/lcars_install
RUN cd /src/lcars_install \
    && PROV_KERNEL_PROBES=0 PROV_COLOR=0 DEBIAN_FRONTEND=noninteractive \
       deploy/provision apply --substrate docker --human builder \
    && cd / && rm -rf /src \
    && rm -rf /var/lib/apt/lists/*

# ─── 3. CE QUE SEULE L'IMAGE PORTE ────────────────────────────────────────────────────────────────
# tofu lit sa config a cet endroit (46 pose tofurc et le miroir de providers) ; sur un poste c'est
# services.env qui le dit aux unites.
ENV TF_CLI_CONFIG_FILE=/opt/lcars/tofu/tofurc
VOLUME ["/home", "/opt/lcars/var"]
EXPOSE 22

HEALTHCHECK --interval=30s --timeout=5s --start-period=300s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/22 && { [ \"${LCARS_LANDING:-1}\" = 1 ] || exit 0; exec 4<>/dev/tcp/127.0.0.1/\"${LCARS_LANDING_PORT:-20999}\"; }"]

ENTRYPOINT ["/usr/bin/tini", "--", "bash", "/opt/lcars/services/container/boot.sh"]

# ─── verify : LE DOCTOR SUR L'IMAGE POSEE, PUIS LA PREUVE ─────────────────────────────────────────
# Le meme `provision doctor` qu'un poste — depuis la copie que 62 embarque (/opt/lcars/deploy), sur
# la selection que les en-tetes CHECK-ON decident, sans `--only`. Une image dont le doctor n'est pas
# vert ne devient pas `final` : `/verified` est ce que `final` copie, et rien d'autre.
FROM runtime AS verify
ARG GIT_SHA=unknown
RUN PROV_SOURCE_REV="${GIT_SHA}" PROV_KERNEL_PROBES=0 PROV_COLOR=0 \
      /opt/lcars/deploy/provision doctor --substrate docker --human builder \
    && printf '%s\n' "${GIT_SHA}" > /verified

# builder a servi de siège au rail et à son doctor ; le siège réel (uid 1000) se dérive au boot
FROM runtime AS final
RUN userdel -r builder
COPY --from=verify /verified /opt/lcars/.verified
