# syntax=docker/dockerfile:1.7-labs
# SOURCE: fleet/deploy/docker/Dockerfile
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
# Posé par BuildKit (`amd64`/`arm64`). Déclaré ICI parce qu'un ARG ne traverse pas les stages, et
# que les caches ci-dessous s'en servent pour ne pas se mélanger entre plateformes.
ARG TARGETARCH
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
# LES RACINES DE FACE SONT DES CONSTANTES DE COMPILATION, DONC DES DÉPENDANCES DU STAGE.
# `Fleet.Layout` fige `@work_root "/home/projects.ops"` et `@doc_root "/home/projects.workshop"` ; le
# test d'admission du poller crée son répertoire de
# projet LÀ où le code ira le lire — c'est le point du test, il refuse de mesurer un stub de
# lui-même. Sous `builder`, `/home` appartient à root : `mkdir_p` échoue et le test rougit sans
# rien dire du code (mesuré 2026-08-04, premier build après le commit qui pose ce test). Même
# règle que les paquets ci-dessus : on outille le stage, on n'affaiblit pas le gate.
# `python3-pytest` A ÉTÉ AJOUTÉ POUR LA MÊME RAISON, et il a coûté un build entier pour être vu
# (2026-08-07, premier clean-room après le déménagement) : shell_gate joue les `lcars_tests` de
# token-saver — LE mur d'ancrage amont, celui qui dit ce qui se rouvre à chaque update du vendor —
# et il REFUSE de les sauter en silence si pytest manque. La boîte de dev l'a, l'image ne l'avait
# pas : le gate en image était donc vert sur une suite de moins, jusqu'à ce que ce refus le dise.
RUN echo 'deb http://deb.debian.org/debian bookworm-backports main' > /etc/apt/sources.list.d/backports.list \
    && apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       tmux bubblewrap curl jq unzip ca-certificates python3 python3-pytest bats procps \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -t bookworm-backports git \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 2000 fleet \
    && useradd -m -u 1000 -g fleet builder \
    && install -d -o builder -g fleet /local /src /src/fleet /src/fleet \
    && install -d -o builder -g fleet /home/projects.ops /home/projects.workshop

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

WORKDIR /src/fleet
# Le source runtime seul (contexte = racine repo, taillé par .dockerignore). Pas de .git : depuis
# un worktree c'est un pointeur mort — build_info.txt dégrade proprement (sha=unknown) et la
# vérité de révision est portée par le label OCI org.opencontainers.image.revision (build-arg).
# La destination est PRÉ-CRÉÉE au bon owner ci-dessus : `--chown` ne couvre que le contenu copié,
# jamais les dossiers que COPY crée en chemin (ils naîtraient root, et `mix deps.get` — qui écrit
# `deps/` DANS ce dossier — mourrait en :eacces).
# COPY EXPLICITE, jamais `COPY fleet /src/fleet` (piege P4 du plan de demenagement). Depuis que
# `fleet/` EST la racine Mix, un COPY du repertoire entier embarquerait `deploy/`, `git-hooks/` et
# `system-prompt/` dans l'etage de compilation Elixir — des arbres qui n'y etaient jamais avant le
# demenagement (l'ancien `COPY fleet/runtime` ne voyait que le runtime). La liste ci-dessous EST
# l'ancien perimetre, nomme.
#
# Elle contient plus que lib+priv+config parce que CE STAGE JOUE LE GATE COMPLET : `test/` porte la
# suite et `test/shell_gate.sh`, `vendor/` porte la brique token-saver dont le gate joue la suite
# d'ancrage amont, et les quatre dotfiles portent format/credo/dialyzer. Retirer l'un d'eux ne
# casse pas le COPY : il rend le gate vert sur moins, ce qui ne se voit pas.
# INCLURE PAR DEFAUT, EXCLURE PAR NOM — et pas l'inverse. Une liste de COPY explicites est un
# INVENTAIRE du perimetre de build, et un inventaire derive : la premiere version de ce bloc
# nommait nine chemins et oubliait `README.md`, que `mix lcars.topology` LIT (il y projette le
# diagramme mermaid et refuse toute divergence). Le gate est mort dessus au troisieme build
# clean-room, apres avoir passe compile, 2371 tests et 30 contrats — trois minutes pour apprendre
# qu'il manquait un fichier de 4 Ko.
#
# Les deux formes echouent, mais PAS de la meme facon : un inventaire incomplet retire une entree
# du build (defaut de CORRECTION, et le meilleur cas est un gate rouge — le pire, une suite qui ne
# tourne plus sans le dire) ; un `rm -rf` qui oublie une exclusion laisse un arbre en trop (defaut
# de TAILLE, visible et sans consequence sur ce qui est atteste). On choisit la forme dont le mode
# de defaillance est benin.
#
# Les trois exclus n'ont jamais fait partie du perimetre : avant le demenagement, `COPY fleet/runtime`
# ne les voyait pas — ils sont frere, pas enfant. `deploy/` est copie tel quel dans le stage runtime
# plus bas ; `git-hooks/` n'a pas de hooks a installer dans une image ; `system-prompt/` porte le
# protocole d'interaction, qui ne compile rien.
# `--exclude` (syntaxe `1.7-labs`) plutot qu'un COPY suivi d'un `rm -rf` : meme resultat dans
# l'image, mais les arbres exclus ne sont PAS dans le layer — donc editer un compose, ce Dockerfile
# ou un hook N'INVALIDE PAS le cache et ne relance pas le gate. Mesure du 2026-08-07 : un build vert
# coute ~10 min, domine par le gate joue ici ; avec le `rm -rf`, toucher un fichier de `deploy/`
# les payait en entier pour rien. La correction (inclure par defaut) est conservee, son cout
# d'iteration ne l'est pas.
COPY --chown=builder:fleet --exclude=deploy --exclude=git-hooks --exclude=system-prompt \
     fleet /src/fleet

# hex/rebar + build + pose sous /local/LCARS_v2 — le cache BuildKit évite de re-télécharger
# hex/deps à chaque build (le layer, lui, se rebuild à chaque changement de source : voulu,
# c'est une release). Les caches appartiennent à builder (uid/gid explicites : un cache root
# serait illisible pour lui). Gate complet + warnings-as-errors : un build rouge NE produit PAS
# d'image. Les symlinks PATH échouent ici (pas de droit sur /usr/local/bin) et c'est SANS gravité :
# install.sh les rapporte non-fatalement, et le stage runtime les pose lui-même.
# LES CACHES SONT SCOPÉS PAR ARCH, ET CE N'EST PAS DU CONFORT. Un cache BuildKit sans `id` est
# partagé par TOUS les builds de ce Dockerfile — donc entre plateformes. Un `.mix`/`.hex` rempli
# par un build amd64, remonté dans un build arm64, sert des artefacts et des binaires de la
# mauvaise machine : mesuré 2026-08-04, premier build arm64 mort en compilant `:file_system` sur
# un `:gen_server.call` dont le destinataire était un pid SÉRIALISÉ (`<<131, 88, …>>`) — un terme
# écrit par l'autre arch. L'erreur ne parle ni d'arch ni de cache : elle accuse une dépendance
# tierce, et on la cherche pendant une heure du mauvais côté.
# LA REVISION DOIT TRAVERSER JUSQU'A LA RELEASE, PAS SEULEMENT JUSQU'AUX LABELS OCI.
# Mesure du 2026-08-07, depuis l'interieur d'une boite de banc : `fleet_v2 status` rendait
# « build unknown ref= (source=release) ». La chaine etait complete a un maillon pres — docker.sh
# exporte LCARS_GIT_SHA, le compose le passe en `args`, et le Dockerfile le declarait UNIQUEMENT
# dans le stage runtime, pour le LABEL. Or c'est ICI que la release est estampillee, et
# `BuildInfo.write_release_file` interrogeait `git` — que ce stage n'a pas, deliberement (pas de
# .git dans le contexte). Le SHA existait, voyageait, et s'arretait a l'etage d'a cote.
# Un label OCI se lit du dehors ; l'operateur, lui, regarde depuis DEDANS.
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown
ENV LCARS_GIT_SHA=${GIT_SHA} LCARS_BUILD_DATE=${BUILD_DATE}

RUN --mount=type=cache,id=lcars-hex-$TARGETARCH,target=/home/builder/.hex,uid=1000,gid=2000 \
    --mount=type=cache,id=lcars-mix-$TARGETARCH,target=/home/builder/.mix,uid=1000,gid=2000 \
    --mount=type=cache,id=lcars-cache-$TARGETARCH,target=/home/builder/.cache,uid=1000,gid=2000 \
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

# La révision, LISIBLE DEPUIS L'INTÉRIEUR. Le label OCI ci-dessus la porte déjà, mais un
# conteneur ne peut pas lire son propre label : il faudrait interroger le daemon, et il n'a pas
# de socket (c'est voulu). Cette ENV est la voie par laquelle l'entrypoint compare ce qui TOURNE
# avec la source qu'il clone.
ENV LCARS_IMAGE_REVISION="${GIT_SHA}"
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
       `# socat = le relais d'egress du pod. Le sanctuaire n'a AUCUN namespace reseau : socat est ce` \
       `# qui transforme localhost:<port> dans le bac en la socket unix que le proxy CONNECT sert.` \
       `# Absent, un pod est scelle et ne joint meme pas son vendor — bwrap_launch refuse (exit 2).` \
       socat \
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
#
# DEUX ARCHS, DEUX PINS, ET LE CHOIX N'EST PAS DEVINÉ. `TARGETARCH` est posé par BuildKit (`amd64`,
# `arm64`) : c'est la seule source qui sait pour quelle plateforme on construit, y compris en
# cross-build. Un `uname -m` répondrait pour la machine de BUILD, ce qui est faux dès qu'on bâtit
# une image arm64 depuis un poste x86 — et l'erreur ne se verrait qu'au premier boot sur la cible.
# Une arch inconnue ÉCHOUE ici, avec son nom : mieux vaut refuser de bâtir que livrer une image
# dont la console web ne démarre pas.
ARG TTYD_VERSION=1.7.7
ARG TTYD_SHA256_AMD64=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
ARG TTYD_SHA256_ARM64=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165
ARG TARGETARCH
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) ttyd_asset="ttyd.x86_64";  ttyd_sha="${TTYD_SHA256_AMD64}" ;; \
      arm64) ttyd_asset="ttyd.aarch64"; ttyd_sha="${TTYD_SHA256_ARM64}" ;; \
      *) echo "ttyd: arch de build non supportee: '${TARGETARCH}' (attendu amd64 ou arm64)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --proto '=https' -m 120 -o /tmp/ttyd \
      "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${ttyd_asset}" \
    && echo "${ttyd_sha}  /tmp/ttyd" | sha256sum -c - \
    && install -m 0755 /tmp/ttyd /usr/local/bin/ttyd \
    && rm -f /tmp/ttyd \
    && ttyd --version

# Le provisioning embarqué EN FORME DE REPO (/opt/lcars/fleet/…) : repo_root() de la lib résout
# les chemins inter-arbre (le module 50-forge délègue à fleet/etc/provision-role-tokens.sh).
COPY fleet/deploy /opt/lcars/fleet/deploy
COPY fleet/etc     /opt/lcars/fleet/etc
# P11 — LA BRIQUE token-saver DOIT ETRE DANS L'IMAGE. Sans ce COPY le shim la cherche, ne la trouve
# pas et s'efface : fail-open, AUCUN symptome, et la compression annoncee ne tourne jamais. C'est le
# seul defaut du lot dont personne ne peut s'apercevoir en regardant tourner la fleet.
COPY fleet/vendor/token_saver /opt/lcars/fleet/vendor/token_saver
# Les catalogues METIER autres que la reference. Le release embarque `priv/catalogue` et lui seul
# (mix release ne prend que priv/), donc un catalogue alternatif n'atteint l'image que par ici. Il
# n'est LU par personne tant qu'aucun LCARS_CATALOGUE_ROOT ne le designe : le poser dans l'image ne
# change pas quel metier tourne, ca rend seulement le choix possible sans remonter une image.
COPY fleet/catalogues /opt/lcars/catalogues
COPY fleet/deploy/docker/entrypoint.sh /opt/lcars/entrypoint.sh
COPY fleet/deploy/docker/console.sh         /opt/lcars/console.sh
COPY fleet/deploy/docker/console-humans.sh  /opt/lcars/console-humans.sh
COPY fleet/deploy/docker/console-status.sh  /opt/lcars/console-status.sh
COPY fleet/deploy/docker/console-landing.sh /opt/lcars/console-landing.sh
COPY fleet/deploy/docker/console-deck.py    /opt/lcars/console-deck.py
COPY fleet/deploy/docker/console-pod.sh     /opt/lcars/console-pod.sh
COPY fleet/deploy/docker/console.tmux.conf  /opt/lcars/console.tmux.conf
# Le SQUELETTE de home : `useradd -m` le copie A LA CREATION de chaque humain, jamais ensuite —
# donc l'humain reste maitre de SON .bashrc, la boite ne le rattrape pas au boot suivant. Contenu :
# le Debian etendu (ll/la/l, couleurs, completion, lesspipe) que bookworm-slim n'a PAS, plus le
# prompt maison de l'humain. `less` et `bash-completion` sont installes plus haut POUR LUI :
# sans eux, deux blocs de ce fichier seraient des no-op silencieux.
COPY fleet/deploy/docker/skel.bashrc      /etc/skel/.bashrc

# ─── A FAIRE — token-saver n'est PAS embarque, et le hook s'efface donc ─────────────────────────
#
# La brique de compression d'output (fleet/vendor/token_saver/, Apache-2.0 + glue LCARS)
# est cablee cote hooks — mais AUCUN pod ne peut executer un hook (sanctuaire : ni `hooks/` monte,
# ni cle `hooks` dans les settings du pod ; mesure 2026-08-07) et AUCUN
# COPY ne l'amene ici. Le shim la cherche parmi une liste de candidats, ne la trouve pas, et passe
# la commande intacte : fail-open. Rien ne casse, rien ne compresse. AUCUN SYMPTOME VISIBLE —
# c'est precisement pourquoi cette note est dans ce fichier et pas seulement dans un plan.
#
# A ajouter quand ce fichier sera rouvert (demenagement d'arborescence) :
#
#     COPY fleet/vendor/token_saver /opt/lcars/fleet/vendor/token_saver
#
# Le chemin de destination doit figurer dans les candidats de .claude/hooks/token-saver-hook.sh
# (/opt/lcars/fleet/vendor/token_saver y est deja) ou etre passe par LCARS_TOKEN_SAVER_HOME.
# python3 est deja installe plus haut — la brique est stdlib pure, aucune dependance a ajouter.
# Le switch reste LCARS_TOKEN_SAVER=off, sans rebuild.
#
# Ref : fleet/vendor/token_saver/VENDOR.md
#       work/beyond_#6/chantier-demenagement-arbo-2026-08-04/02-PLAN.md
# ───────────────────────────────────────────────────────────────────────────────────────────────

# ─── ~/.local/bin SUR LE PATH DE TOUT SHELL INTERACTIF, PAS SEULEMENT DES SHELLS DE LOGIN ───────
# `~/.profile` (Debian) pose deja cette regle, mais il n'est lu QUE par un shell de login. Or la
# boite a PLUSIEURS PORTES et elles ne sont pas toutes des logins : sshd et la console web en
# ouvrent un ; `su <humain>` (sans tiret) et `docker exec` n'en ouvrent pas. Sans cette ligne, ce
# qui est installe sous ~/.local/bin est visible ou non SELON LA PORTE empruntee.
#
# ICI ET PAS DANS skel.bashrc : le squelette n'est copie qu'a la CREATION de l'humain
# (`useradd -m`), jamais ensuite — une boite deja installee ne le verrait jamais. `/etc/bash.bashrc`
# est lu par tout bash interactif, vit dans l'IMAGE (donc suit les mises a jour) et ne touche pas
# au `.bashrc` de l'humain, qui reste le sien.
#
# Ce n'est pas une copie concurrente de la regle de `.profile` : c'est la MEME regle, rendue vraie
# pour les shells que `.profile` ne voit jamais. Le test d'appartenance evite d'empiler le chemin
# a chaque relecture (shell imbrique, tmux, screen).
RUN printf '%s\n' \
    '' \
    '# LCARS : ~/.local/bin pour TOUT shell interactif — cf. le Dockerfile pour le pourquoi.' \
    'case ":$PATH:" in' \
    '  *":$HOME/.local/bin:"*) ;;' \
    '  *) [ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH" ;;' \
    'esac' \
    >> /etc/bash.bashrc

RUN chmod 0755 /opt/lcars/entrypoint.sh /opt/lcars/console.sh /opt/lcars/console-humans.sh \
               /opt/lcars/console-status.sh /opt/lcars/console-landing.sh \
               /opt/lcars/console-deck.py /opt/lcars/console-pod.sh \
               /opt/lcars/fleet/deploy/provision \
               /opt/lcars/fleet/deploy/modules.d/*.sh \
               /opt/lcars/fleet/etc/provision-role-tokens.sh

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
