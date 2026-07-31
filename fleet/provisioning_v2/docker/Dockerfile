# syntax=docker/dockerfile:1.7
# SOURCE: fleet/provisioning_v2/docker/Dockerfile
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — image LCARS fleet v2 : build multi-stage (mix release) + runtime slim (sshd login-manager)
#
# ISO structurelle avec le chemin WSL : le stage build exécute LE MÊME etc/install.sh (l'autorité
# build+pose, modèle 3 zones), le stage runtime reçoit LE MÊME layout (/local/LCARS_v2 RO
# root:fleet, /usr/local/bin câblé) que le module 60-deploy pose sur WSL. Ce qui converge au
# runtime (humain, forge, claude per-humain) est fait par LE MÊME `provision` à l'entrypoint —
# et vérifiable par LE MÊME doctor. Deux substrats, une seule vérité.
#
# Pins par DIGEST (l'imutabilité ne se déclare pas, elle s'épingle) :
#   - build   : hexpm/elixir 1.18.4 + Erlang/OTP 25.3.2.8 — EXACTEMENT la toolchain du chemin
#     WSL (apt erlang 25.3.2.8 + précompilé Elixir 1.18.4, cf. modules.d/15-toolchain.sh).
#   - runtime : debian bookworm-slim — même base que l'image build (l'ERTS bundlé y est chez lui).
# Bump = nouvelle paire tag+digest ICI (et le pin 15-toolchain en face) — nulle part ailleurs.
ARG BUILD_IMAGE=hexpm/elixir:1.18.4-erlang-25.3.2.8-debian-bookworm-20260610-slim@sha256:8cae38d9bfbe3d14fc73b687cf36a9a7d5ebd6aea894dc294f35e708320d06e1
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:60eac759739651111db372c07be67863818726f754804b8707c90979bda511df

# ─── Stage 1 : build — la release self-contained, par l'autorité etc/install.sh ─────────────────
FROM ${BUILD_IMAGE} AS build

ENV MIX_ENV=prod LANG=C.UTF-8
# install.sh fait un chgrp fleet best-effort sur le prefix : le groupe doit exister au build
# (le runtime stage le recrée avec le MÊME gid — contrat entre stages).
RUN groupadd -g 2000 fleet

WORKDIR /src/fleet/runtime
# Le source runtime seul (contexte = racine repo, taillé par .dockerignore). Pas de .git : depuis
# un worktree c'est un pointeur mort — build_info.txt dégrade proprement (sha=unknown) et la
# vérité de révision est portée par le label OCI org.opencontainers.image.revision (build-arg).
COPY fleet/runtime /src/fleet/runtime

# hex/rebar + build + pose sous /local/LCARS_v2 — le cache BuildKit évite de re-télécharger
# hex/deps à chaque build (le layer, lui, se rebuild à chaque changement de source : voulu,
# c'est une release). Verrou contracts + warnings-as-errors : un build rouge NE produit PAS d'image.
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.cache \
    mix local.hex --force && mix local.rebar --force \
    && LCARS_INSTALL_PREFIX=/local/LCARS_v2 bash etc/install.sh

# ─── Stage 2 : runtime — slim, sshd = login-manager, tini = PID 1 ────────────────────────────────
FROM ${RUNTIME_IMAGE} AS runtime

ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown
ARG VERSION=2.0
LABEL org.opencontainers.image.title="LCARS fleet v2" \
      org.opencontainers.image.description="Control plane pour workloads agentiques faillibles — runtime Elixir/OTP, pods bwrap, forge-state-machine. L'humain SSH dans le conteneur et lance sa fleet (bin/fleet_v2 start)." \
      org.opencontainers.image.source="https://github.com/lordzurp/LCARS-fleet" \
      org.opencontainers.image.licenses="AGPL-3.0" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.authors="lordzurp"

ENV LANG=C.UTF-8 LCARS_DOCKER=1
# Paquets du RUNTIME (la liste miroir de modules.d/10-packages.sh + le substrat conteneur :
# openssh-server = le login-manager du modèle « l'humain SSH en tant que lui », tini = PID 1
# (reaper + signaux), procps = sondes pgrep du provisioning. Un seul layer apt, cache purgé.
# util-linux-extra = runuser (B4) : absent de bookworm-slim, et TOUT le per-humain du provision
# convergent (as_human) passe par lui — sans ce paquet l'entrypoint casse au premier module humain.
# python3 = l'interpréteur du bridge MCP des pods (fleet_mcp_stdio_bridge.py, lancé « python3
# <path> » dans le sanctuaire, qui projette CE /usr) — absent, AUCUN pod n'a ses outils
# mcp__fleet__* (premier pod réel : « exec: python3: not found », canal nominal mort).
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       tmux bubblewrap git curl jq unzip ca-certificates openssh-server tini procps util-linux-extra python3 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 2000 fleet \
    && mkdir -p /run/sshd

# Le runtime déployé, tel que bâti par install.sh — puis le verrou RO du module 60-deploy :
# owner root (personne ne remplace un runtime déployé), groupe fleet r-x, autres rien.
# /usr/local/bin ne reçoit QUE les 2 symlinks-pointeurs (D3) : les launchers pod vivent dans
# $PREFIX/bin, fleet_v2 pose LCARS_*_LAUNCH_PATH dessus — une copie serait une seconde vérité.
COPY --from=build /local/LCARS_v2 /local/LCARS_v2
RUN chown -R root:fleet /local/LCARS_v2 \
    && chmod -R u=rwX,g=rX,o= /local/LCARS_v2 \
    && ln -sf /local/LCARS_v2/bin/fleet_v2 /usr/local/bin/fleet_v2 \
    && ln -sf /local/LCARS_v2/bin/lcars    /usr/local/bin/lcars

# Le provisioning embarqué EN FORME DE REPO (/opt/lcars/fleet/…) : repo_root() de la lib résout
# les chemins inter-arbre (le module 50-forge délègue à fleet/runtime/etc/provision-role-tokens.sh).
COPY fleet/provisioning_v2 /opt/lcars/fleet/provisioning_v2
COPY fleet/runtime/etc     /opt/lcars/fleet/runtime/etc
COPY fleet/provisioning_v2/docker/entrypoint.sh /opt/lcars/entrypoint.sh
RUN chmod 0755 /opt/lcars/entrypoint.sh /opt/lcars/fleet/provisioning_v2/provision \
               /opt/lcars/fleet/provisioning_v2/modules.d/*.sh \
               /opt/lcars/fleet/runtime/etc/provision-role-tokens.sh

# /home = LE volume d'état (les humains : ~/.lcars, ~/.claude, ~/pods ; /home/private : tokens ;
# les clés d'hôte sshd y persistent aussi — un conteneur recréé garde son identité SSH).
VOLUME ["/home"]
EXPOSE 22

# sshd répond = le conteneur tient sa promesse (login-manager). Sonde TCP réelle, pas un pgrep
# d'un process que personne ne lance (le healthcheck-tmux menteur de la v1).
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/22"]

# root : requis par sshd (login-manager qui drop vers l'humain) et par l'entrypoint convergent.
# Les fleets, elles, tournent sous l'UID de CHAQUE humain (le drop est le métier de sshd).
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/lcars/entrypoint.sh"]
