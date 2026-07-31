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
#
# Le build tourne sous `builder`, PAS sous root : etc/install.sh REFUSE root, et il a raison —
# le gate n'est pas valide sous root (il outrepasse les permissions que des tests vérifient) et
# un build root sème des artefacts root dans l'arbre source. Un stage Docker est root par défaut :
# c'est au Dockerfile de se conformer à l'invariant, pas à l'invariant de plier pour Docker.
# (Contrat entre stages : uid 1000 = l'uid par défaut de l'humain du conteneur ; gid 2000 = fleet.)
# Outillage du GATE : etc/install.sh lance `mix gate`, dont shell_gate exige python3 (test du
# bridge MCP), bats + git (tests hors-mix) — et REFUSE de les sauter en silence
# (BATS_MISSING_FATAL=1 posé par mix.exs). S'y ajoute LE MONDE QUE CES TESTS EXERCENT : les bats
# des launchers vérifient les refus de bwrap_launch dans l'ordre (bwrap → tmux → vendor → …), donc
# un stage sans tmux/bubblewrap fait échouer le script trop TÔT et rougit 62 cas qui n'ont rien à
# voir. Un stage build qui ne peut pas jouer le gate entier ne doit pas produire d'image : on
# outille le stage plutôt que d'affaiblir le gate. (Liste = celle de 10-packages + les 2 du gate.)
# git vient de BACKPORTS (bookworm = 2.39) : un fixture du gate construit un worktree orphelin
# avec `git worktree add --orphan`, option apparue en git 2.42 — sans elle, exit 129 et un test
# rouge qui ne parle pas du code. C'est un besoin du GATE seul : le runtime, lui, crée ses
# worktrees en `add -f -B` (vérifié dans pilot/conflict_apply + project_onboard), donc l'image
# finale garde le git de bookworm sans rien perdre.
RUN echo 'deb http://deb.debian.org/debian bookworm-backports main' > /etc/apt/sources.list.d/backports.list \
    && apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       tmux bubblewrap curl jq unzip ca-certificates python3 bats procps \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -t bookworm-backports git \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 2000 fleet \
    && useradd -m -u 1000 -g fleet builder \
    && install -d -o builder -g fleet /local /src /src/fleet /src/fleet/runtime

# HOME suit l'utilisateur — `USER` ne le change PAS (il resterait /root, et mix/hex écriraient
# leurs caches dans un dossier interdit à builder).
ENV HOME=/home/builder
USER builder

# Le binaire vendor, POUR LE GATE : Fleet.Spawner.PodTest résout l'env de lancement d'un pod
# (`~/.local/bin/claude` de l'utilisateur courant) et échoue fail-loud s'il manque — 49 tests
# rouges sans lui, dont l'échec ne dit rien du code. Ce layer est AVANT le COPY du source :
# il ne s'invalide pas à chaque changement de code, et le stage entier est jeté à la fin (aucun
# poids sur l'image finale). Version = la courante de l'installeur officiel (frontière vendor N1).
RUN curl -fsSL --proto '=https' -m 300 -o /tmp/claude-install.sh https://claude.ai/install.sh \
    && bash /tmp/claude-install.sh >/dev/null 2>&1 \
    && rm -f /tmp/claude-install.sh \
    && "$HOME/.local/bin/claude" --version

WORKDIR /src/fleet/runtime
# Le source runtime seul (contexte = racine repo, taillé par .dockerignore). Pas de .git : depuis
# un worktree c'est un pointeur mort — build_info.txt dégrade proprement (sha=unknown) et la
# vérité de révision est portée par le label OCI org.opencontainers.image.revision (build-arg).
# La destination est PRÉ-CRÉÉE au bon owner ci-dessus : `--chown` ne couvre que le contenu copié,
# jamais les dossiers que COPY crée en chemin (ils naîtraient root, et `mix deps.get` — qui écrit
# `deps/` DANS ce dossier — mourrait en :eacces).
COPY --chown=builder:fleet fleet/runtime /src/fleet/runtime

# hex/rebar + build + pose sous /local/LCARS_v2 — le cache BuildKit évite de re-télécharger
# hex/deps à chaque build (le layer, lui, se rebuild à chaque changement de source : voulu,
# c'est une release). Les caches appartiennent à builder (uid/gid explicites : un cache root
# serait illisible pour lui). Gate complet + warnings-as-errors : un build rouge NE produit PAS
# d'image. Les symlinks PATH échouent ici (pas de droit sur /usr/local/bin) et c'est SANS gravité :
# install.sh les rapporte non-fatalement, et le stage runtime les pose lui-même.
RUN --mount=type=cache,target=/home/builder/.hex,uid=1000,gid=2000 \
    --mount=type=cache,target=/home/builder/.mix,uid=1000,gid=2000 \
    --mount=type=cache,target=/home/builder/.cache,uid=1000,gid=2000 \
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
       less bash-completion \
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

# ─── La console web : ttyd, binaire STATIQUE pinné par sha256 ────────────────────────────────────
# La porte d'entrée demandée : une page web avec un shell SOUS L'IDENTITÉ DE L'HUMAIN, dans lequel
# il lance `claude`. ttyd n'est PAS dans bookworm (vérifié : « no installation candidate ») ; on
# prend l'officiel statique — même discipline que le précompilé Elixir de 15-toolchain : version +
# sha256 épinglés ICI, nulle part ailleurs. Bump = changer la paire.
ARG TTYD_VERSION=1.7.7
ARG TTYD_SHA256=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
RUN curl -fsSL --proto '=https' -m 120 -o /tmp/ttyd \
      "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
    && echo "${TTYD_SHA256}  /tmp/ttyd" | sha256sum -c - \
    && install -m 0755 /tmp/ttyd /usr/local/bin/ttyd \
    && rm -f /tmp/ttyd \
    && ttyd --version

# Le provisioning embarqué EN FORME DE REPO (/opt/lcars/fleet/…) : repo_root() de la lib résout
# les chemins inter-arbre (le module 50-forge délègue à fleet/runtime/etc/provision-role-tokens.sh).
COPY fleet/provisioning_v2 /opt/lcars/fleet/provisioning_v2
COPY fleet/runtime/etc     /opt/lcars/fleet/runtime/etc
COPY fleet/provisioning_v2/docker/entrypoint.sh /opt/lcars/entrypoint.sh
COPY fleet/provisioning_v2/docker/console.sh         /opt/lcars/console.sh
COPY fleet/provisioning_v2/docker/console-humans.sh  /opt/lcars/console-humans.sh
COPY fleet/provisioning_v2/docker/console-status.sh  /opt/lcars/console-status.sh
COPY fleet/provisioning_v2/docker/console-landing.sh /opt/lcars/console-landing.sh
COPY fleet/provisioning_v2/docker/console.tmux.conf  /opt/lcars/console.tmux.conf
# Le SQUELETTE de home : `useradd -m` le copie A LA CREATION de chaque humain, jamais ensuite —
# donc l'humain reste maitre de SON .bashrc, la boite ne le rattrape pas au boot suivant. Contenu :
# le Debian etendu (ll/la/l, couleurs, completion, lesspipe) que bookworm-slim n'a PAS, plus le
# prompt maison de l'humain. `less` et `bash-completion` sont installes plus haut POUR LUI :
# sans eux, deux blocs de ce fichier seraient des no-op silencieux.
COPY fleet/provisioning_v2/docker/skel.bashrc      /etc/skel/.bashrc
RUN chmod 0755 /opt/lcars/entrypoint.sh /opt/lcars/console.sh /opt/lcars/console-humans.sh \
               /opt/lcars/console-status.sh /opt/lcars/console-landing.sh \
               /opt/lcars/fleet/provisioning_v2/provision \
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
