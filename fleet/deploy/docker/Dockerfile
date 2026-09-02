# syntax=docker/dockerfile:1.7-labs
# SOURCE: fleet/deploy/docker/Dockerfile
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — image LCARS fleet v2 : build multi-stage (mix release) + runtime slim (sshd login-manager)
# ISO structurelle avec le chemin WSL : le stage build exécute LE MÊME etc/deploy-release.sh (l'autorité
# build+pose, modèle 3 zones), le stage runtime reçoit LE MÊME layout (/opt/lcars/runtime RO
# root:fleet, /usr/local/bin câblé) que le module 60-deploy pose sur WSL. Ce qui converge au
# runtime (humain, forge, claude per-humain) est fait par LE MÊME `provision` à l'entrypoint —
# et vérifiable par LE MÊME doctor. Deux substrats, une seule vérité.
# Pins par DIGEST (l'imutabilité ne se déclare pas, elle s'épingle) : bump = nouveau digest ICI,
# les deux ensemble, nulle part ailleurs.
ARG BUILD_IMAGE=ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b
ARG RUNTIME_IMAGE=ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

FROM ${BUILD_IMAGE} AS build

ENV MIX_ENV=prod LANG=C.UTF-8
# Posé par BuildKit (`amd64`/`arm64`). Déclaré ICI parce qu'un ARG ne traverse pas les stages, et
# que les caches ci-dessous s'en servent pour ne pas se mélanger entre plateformes.
ARG TARGETARCH
# install.sh fait un chgrp fleet best-effort sur le prefix : le groupe doit exister au build
# (le runtime stage le recrée avec le MÊME gid — contrat entre stages).
# (Contrat entre stages : uid 1000 = l'uid par défaut de l'humain du conteneur ; gid 2000 = fleet.)
# Outillage du GATE : etc/deploy-release.sh lance `mix gate`, dont shell_gate exige python3 (test du
# bridge MCP), bats + git (tests hors-mix) — et REFUSE de les sauter en silence
# (BATS_MISSING_FATAL=1 posé par mix.exs). S'y ajoute LE MONDE QUE CES TESTS EXERCENT : les bats
# des launchers vérifient les refus de bwrap_launch dans l'ordre (bwrap → tmux → vendor → …), donc
# un stage sans tmux/bubblewrap fait échouer le script trop TÔT et rougit 62 cas qui n'ont rien à
# voir. Un stage build qui ne peut pas jouer le gate entier ne doit pas produire d'image : on
# outille le stage plutôt que d'affaiblir le gate. (Liste = celle de 10-packages + les 2 du gate.)
# ⚠ LA TOOLCHAIN ENTRE ICI PAR APT, ET C'EST LE MÊME GESTE QUE `15-toolchain` SUR UN POSTE.
# ⚠ ET L'UID 1000 EST DÉJÀ PRIS DANS LA BASE : `ubuntu:26.04` y pose un humain « ubuntu ». Cet uid
# est le contrat déclaré au-dessus, et les caches BuildKit du stage suivant le montent EN DUR
# (`uid=1000`) — renuméroter `builder` casserait les trois `--mount` et le défaut de `LCARS_UID`
# côté compose. On LIBÈRE l'uid, on ne renumérote pas. Sans ce geste le stage est INCONSTRUCTIBLE
# (« useradd: UID 1000 is not unique ») : le défaut ne se voit qu'au premier build sur une machine
# qui n'a pas déjà l'image, jamais sur celles qui la portent depuis une base antérieure.
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       erlang elixir \
       tmux bubblewrap git curl jq unzip ca-certificates python3 python3-pytest bats procps \
    && rm -rf /var/lib/apt/lists/* \
    && { userdel -r "$(getent passwd 1000 | cut -d: -f1)" 2>/dev/null || true; } \
    && groupadd -g 2000 fleet \
    && useradd -m -u 1000 -g fleet builder \
    && install -d -o builder -g fleet /opt/lcars /src /src/fleet /src/fleet \
    && install -d -o builder -g fleet /home/projects.ops /home/projects.workshop \
    && install -d -m 0755 /run/user \
    && install -d -m 0700 -o builder -g fleet /run/user/1000

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
# INCLURE PAR DEFAUT, EXCLURE PAR NOM — et pas l'inverse. Une liste de COPY explicites est un
# INVENTAIRE du perimetre de build, et un inventaire derive : la premiere version de ce bloc
# nommait nine chemins et oubliait `README.md`, que `mix lcars.topology` LIT (il y projette le
# diagramme mermaid et refuse toute divergence). Le gate est mort dessus au troisieme build
# clean-room, apres avoir passe compile, 2371 tests et 30 contrats — trois minutes pour apprendre
# qu'il manquait un fichier de 4 Ko.
# `--exclude` (syntaxe `1.7-labs`) plutot qu'un COPY suivi d'un `rm -rf` : meme resultat dans
# l'image, mais les arbres exclus ne sont PAS dans le layer — donc editer un compose, ce Dockerfile
# ou un hook N'INVALIDE PAS le cache et ne relance pas le gate. Mesure du 2026-08-07 : un build vert
# coute ~10 min, domine par le gate joue ici ; avec le `rm -rf`, toucher un fichier de `deploy/`
# les payait en entier pour rien. La correction (inclure par defaut) est conservee, son cout
# d'iteration ne l'est pas.
COPY --chown=builder:fleet --exclude=deploy --exclude=git-hooks --exclude=system-prompt \
     fleet /src/fleet

# LE PATTERN EST OPTIONNEL, ET LA FORME EST L'IDIOME, PAS UNE COQUETTERIE. `.source-revisio[n]` est
# un glob : depuis un checkout ordinaire il ne matche RIEN, et un `COPY` dont aucun terme ne matche
# ECHOUE. `LICENSE` est la pour cela — il est dans le contexte par construction (`.dockerignore`
# l'inclut), donc le COPY a toujours au moins une source, et l'attestation entre quand elle existe.
# Elle a sa place a cote : le kit de `pack.sh` porte les deux a la racine.
COPY --chown=builder:fleet LICENSE .source-revisio[n] /src/

# LES CACHES SONT SCOPÉS PAR ARCH, ET CE N'EST PAS DU CONFORT. Un cache BuildKit sans `id` est
# partagé par TOUS les builds de ce Dockerfile — donc entre plateformes. Un `.mix`/`.hex` rempli
# par un build amd64, remonté dans un build arm64, sert des artefacts et des binaires de la
# mauvaise machine : mesuré 2026-08-04, premier build arm64 mort en compilant `:file_system` sur
# un `:gen_server.call` dont le destinataire était un pid SÉRIALISÉ (`<<131, 88, …>>`) — un terme
# écrit par l'autre arch. L'erreur ne parle ni d'arch ni de cache : elle accuse une dépendance
# tierce, et on la cherche pendant une heure du mauvais côté.
# ⚠ CE `unknown` N'EST PAS UN DEFAUT DEFENSIF, C'EST L'ETAT NOMINAL TANT QUE L'APPELANT SE TAIT.
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown
ENV LCARS_GIT_SHA=${GIT_SHA} LCARS_BUILD_DATE=${BUILD_DATE}

# ⚠ LE JUMEAU AUSSI PORTE SA REVISION. Ce LABEL n'existait que dans le stage `runtime` : l'image
# `lcars-build:<tag>` — celle que le runner CI sert au label `elixir` — sortait donc MUETTE sur son
# origine. Mesure du 2026-08-19 : `lcars-2231:build` porte `6694a417`, `lcars-build:build` une
# chaine vide. Consequence : on ne peut pas dire de quel commit vient le toolchain qui a juge un
# verdict, alors que c'est exactement la question qu'on pose au runtime. Un stage jete n'a pas
# besoin d'etiquette ; celui-ci ne l'est pas, il est PUBLIE sous un tag et consomme par la CI.
LABEL org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}"

# Le `|| [ "$?" -eq 3 ]` de ce RUN : 3 = release posee mais symlinks PATH refuses (pas de droit sur
# /usr/local/bin dans ce stage) — sans gravite, le stage runtime les pose lui-meme.
RUN --mount=type=cache,id=lcars-hex-$TARGETARCH,target=/home/builder/.hex,uid=1000,gid=2000 \
    --mount=type=cache,id=lcars-mix-$TARGETARCH,target=/home/builder/.mix,uid=1000,gid=2000 \
    --mount=type=cache,id=lcars-cache-$TARGETARCH,target=/home/builder/.cache,uid=1000,gid=2000 \
    if [ -f /src/.source-revision ]; then \
      echo "image: PAQUET — .source-revision $(cat /src/.source-revision) : la release vient de pack.sh, ni gate ni compilation ici"; \
    else \
      echo "image: CHECKOUT NU — aucun .source-revision : la release est COMPILEE dans ce stage, et le gate n'est PAS rejoue (l'attestation vient du paquet, ce build n'en a pas)"; \
    fi \
    && mix local.hex --force && mix local.rebar --force \
    && { LCARS_INSTALL_SKIP_GATE=1 LCARS_INSTALL_PREFIX=/opt/lcars/runtime bash etc/deploy-release.sh \
         || [ "$?" -eq 3 ]; }

# La plaquette (`assets/github.io`) se genere DEPUIS le code du produit : les cartes, les sieges,
# les verbes de la console, les arbres d'un catalogue. Sur GitHub elle est publiee par Pages ; ici
# elle part dans l'image pour que la boite serve sa PROPRE doc — celle de la version qu'elle fait
# tourner, pas la derniere en ligne, pas une copie a resynchroniser.
# ⚠ L'ARBORESCENCE EST LE CONTRAT. Les lecteurs du site remontent quatre crans depuis
# `src/lib/` pour trouver la racine du depot (`fleet/`, `assets/`), et `collect-assets.mjs` remonte
# deux crans pour trouver `assets/`. Le stage reproduit donc la MEME forme : `/src/assets/github.io`
# avec `/src/fleet` et `/src/assets/*` a cote. Un raccourci de chemin ici ferait echouer le build
# sur un `illisible` qui accuserait le code.
# `LCARS_SITE_BASE=/doc/` : le deck la sert sous ce chemin, et tout lien interne se compose depuis
# cette base (`src/lib/href.js`). Batie a la racine, la copie locale s'afficherait et tous ses liens
# partiraient a la racine du deck — cassee en silence.
FROM node:24-slim@sha256:ba849c60be29959425b8734d57b8b4b7d56f98edd9504c9af091d5281095a71e AS site
# La provenance vient de l'APPELANT : ce stage n'a ni git ni `.git`, et la plaquette affiche le sha
# en pied de page. Sans cet argument elle imprime « unknown », ce qui est honnete et visible.
ARG GIT_SHA=unknown
ENV LCARS_GIT_SHA=${GIT_SHA}
WORKDIR /src/assets/github.io
COPY assets/github.io/package.json assets/github.io/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY assets/github.io ./
COPY assets/avatars ../avatars
COPY assets/favicon ../favicon
COPY fleet /src/fleet
# ⚠ LE SITE DÉRIVE SES SIÈGES DE TROIS CATALOGUES, ET LE TROISIÈME N'EST PAS SOUS `fleet/`.
COPY catalogues /src/catalogues
ENV LCARS_SITE_BASE=/doc/
RUN npm run build

FROM ${RUNTIME_IMAGE} AS runtime

ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown
ARG VERSION=2.0
# ⚠ LA REVISION EST DEJA CONNUE ICI, ET ELLE DOIT L'ETRE DES DEUX COTES. `62-runtime-helpers`
# compare l'estampille posee (`/opt/lcars/.source-revision`) a la revision de la SOURCE — sur un
# poste, le git du clone. Une image n'a ni `.git` ni clone : la source rendait « inconnue »,
# l'estampille etait absente, et le drift devenait un ECHEC PERMANENT (APPLY-ON=wsl linux, donc
# rien a reparer sur ce substrat). L'ARG qui remplit le LABEL OCI est la MEME verite : on la donne
# au module par `PROV_SOURCE_REV`, et le fichier est ecrit plus bas depuis le meme ARG. Une seule
# origine pour les deux, sinon elles divergent — c'est exactement ce que ce module mesure.
ENV PROV_SOURCE_REV=${GIT_SHA}
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
# util-linux-extra = runuser (B4) : absent d'une base ubuntu minimale, et TOUT le per-humain du provision
# convergent (as_human) passe par lui — sans ce paquet l'entrypoint casse au premier module humain.
# python3 = l'interpréteur du bridge MCP des pods (fleet_mcp_stdio_bridge.py, lancé « python3
# <path> » dans le sanctuaire, qui projette CE /usr) — absent, AUCUN pod n'a ses outils
# mcp__fleet__* (premier pod réel : « exec: python3: not found », canal nominal mort).
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       tmux bubblewrap git curl jq unzip ca-certificates openssh-server tini procps util-linux-extra python3 \
       `# sudo = le root du sysadmin (admiral, uid 1000). Modele identite-v2 : la forge fait autorite` \
       `# sur les personnes, le proprietaire de la boite (le master, materialise en admiral) a root sur` \
       `# SA machine via le groupe sudo. Threat model homelab/LAN sur : on protege la fleet, pas la` \
       `# machine contre son proprietaire. Absent jusqu'ici (aucun humain n'avait de sudo).` \
       sudo \
       `# socat = le relais d'egress du pod. Le sanctuaire n'a AUCUN namespace reseau : socat est ce` \
       `# qui transforme localhost:<port> dans le bac en la socket unix que le proxy CONNECT sert.` \
       `# Absent, un pod est scelle et ne joint meme pas son vendor — bwrap_launch refuse (exit 2).` \
       socat \
       less bash-completion \
       `# ─── L'EXPORT VERS UN MIROIR EXTERNE, ET SES DEUX OUTILS ───────────────────────────────` \
       `# git-filter-repo est la reecriture d'historique de bin/publish-transform.sh, qui REFUSE de` \
       `# tourner sans elle (exit 1) en imprimant une recette de venv a taper — une dependance` \
       `# nommee par le produit lui-meme n'a rien a faire hors de l'image. gh est l'outil du` \
       `# DERNIER pas : le script ne pousse jamais (contrainte dure), il imprime le geste, et le` \
       `# geste s'appelle gh. La liste native (10-packages.sh) porte les deux, et le temoin` \
       `# deploy_manifest.bats exige l'egalite des deux rails.` \
       git-filter-repo gh \
       `# ─── BASELINE D'OUTILLAGE (lot 1 du rail toolchain) ────────────────────────────────────` \
       `# CE QUI EST DEJA LA NE SE DEMANDE PAS. Sans ces paquets un pod ne produit que du bash, du` \
       `# HTML et du python NU : ni venv, ni pip, ni compilateur. Chaque dependance de projet` \
       `# devrait alors passer par une approbation humaine — six mois a faire signer ce qui aurait` \
       `# du etre dans l'image. Les voici une fois, pour tous les pods (le /usr du bac est CELUI-CI).` \
       `#` \
       `# python3-venv N'EST PAS UN CONFORT, c'est le seul chemin. MESURE sur ubuntu 26.04 :` \
       `# libpython3.14-stdlib livre /usr/lib/python3.14/EXTERNALLY-MANAGED, donc PEP 668 est` \
       `# ACTIF et un pip install hors venv ECHOUE PAR CONCEPTION. python3-pip seul ne suffit pas.` \
       `# Effet de bord favorable : le chemin sans privilege devient obligatoire cote pod, gratis.` \
       python3-venv python3-pip \
       `# La longue traine des builds natifs, et la raison de chaque ligne :` \
       `#  - la plupart des paquets python populaires livrent des wheels manylinux -> RIEN ne compile.` \
       `#    build-essential + python3-dev sont pour la QUEUE : le paquet sans wheel pour cette` \
       `#    plateforme, qui compile ses extensions C.` \
       `#  - les modules npm natifs (node-gyp) veulent python3 + make + g++ -> build-essential.` \
       `#  - les crates rust en -sys veulent cc + pkg-config + le -dev de la lib C visee.` \
       `# Une baseline unique fait tomber les trois. Cout mesure : +119 paquets sur la liste` \
       `# ci-dessus, dont 60 pour build-essential seul. C'est le prix d'un compilateur, et une boite` \
       `# qui n'en a pas envoie CHAQUE build natif par la garde humaine.` \
       build-essential pkg-config python3-dev libssl-dev \
       `# ─── LA CONSOLE WEB, ET ELLE ARRIVE ENFIN PAR LE MEME CHEMIN QUE SUR UN POSTE ──────────` \
       `# Il est desormais dans PACKAGES (10-packages.sh), donc sur le rail natif : c'est ce qui` \
       `# autorise sa presence ici sans exemption dans deploy_manifest.bats.` \
       ttyd \
    && rm -rf /var/lib/apt/lists/* \
    `# ⚠ L'UID 1000 EST PRIS DANS LA BASE, ET C'EST CELUI QUE L'ENTRYPOINT DONNE AU SIEGE (LCARS_UID) :` \
    `# ubuntu:26.04 y pose un humain « ubuntu ». Le stage build fait le meme geste pour builder — meme` \
    `# base, meme piege aux deux etages, et le corriger a un seul ne corrige rien. Sans ca l'entrypoint` \
    `# BOUCLE sur « useradd: UID 1000 is not unique » et la boite ne devient jamais healthy : elle` \
    `# demarre, elle repond, elle ne converge pas — le mode de defaillance le plus cher a lire.` \
    && { userdel -r "$(getent passwd 1000 | cut -d: -f1)" 2>/dev/null || true; } \
    && groupadd -g 2000 fleet \
    `# LE GROUPE QUI PORTE EXACTEMENT UN POUVOIR : traverser les repertoires de socket des consoles.` \
    `# Il existe parce que le producteur (ttyd, sous l'humain) et le consommateur (le deck, sous` \
    `# nobody) doivent se rencontrer SANS que ni l'un ni l'autre ne change d'identite. Le repertoire` \
    `# de chaque humain est 2710 <human>:lcars-console : le setgid fait heriter ce groupe a la` \
    `# socket que ttyd cree, et le --x du groupe donne la traversee sans le listage.` \
    `#` \
    `# ⚠ PAS le groupe fleet (gid 2000), ET C'EST LE PIEGE A EVITER : celui-la porte deja la lecture de` \
    `# /opt/lcars/runtime et d'ailleurs. Le reutiliser aurait ete plus court et aurait accorde tout le` \
    `# reste par la meme occasion. Un pouvoir qu'on ne sait pas dire en une phrase est trop large.` \
    && groupadd -g 2001 lcars-console \
    `# LE COMPTE DU SERVICE D'AUTORITE, MIROIR DE 21-service-accounts DU RAIL POSTE. Sans lui,` \
    `# l'entrypoint ne peut pas deposer le service et le geste catalogue est injouable dans la boite.` \
    `#` \
    `# ⚠ MEMBRE DE fleet POUR TRAVERSER /opt/lcars/runtime (0750 root:fleet), JAMAIS POUR DECIDER.` \
    `# Il DETIENT les secrets de la forge et n'a AUCUN privilege noyau — l'inverse exact du` \
    `# convergeur d'humains, qui a useradd et ne detient rien.` \
    && useradd --system --no-create-home --shell /usr/sbin/nologin -g fleet lcars-authority \
    `# LE COMPTE DE LA LANDING, MIROIR DE 21-service-accounts DU RAIL POSTE. Il N'EST QUE quelqu'un :` \
    `# le deck ne detient rien de durable et n'a aucun privilege, il a seulement besoin de ne PAS` \
    `# etre nobody. Le prix de nobody se lit sur son GROUPE : deck-oidc.json porte le client_secret` \
    `# OAuth2 et se posait 0640 root:nogroup — or nogroup (gid 65534) est le groupe PRIMAIRE de` \
    `# sync, _apt, nobody et dhcpcd sur une Debian/Ubuntu ordinaire (releve du 2026-08-27). Un demon` \
    `# reseau lisait le secret. Un groupe a lui, et le fichier ne nomme plus qu'un lecteur.` \
    `#` \
    `# ⚠ PAS MEMBRE DE fleet, ET C'EST LA DIFFERENCE AVEC SON VOISIN CI-DESSUS. Le deck ne lit RIEN` \
    `# sous /opt/lcars/runtime : sa doc a ete deplacee en /opt/lcars/share/doc precisement parce qu'il` \
    `# ne pouvait pas l'y lire. Lui rendre le groupe annulerait le motif de ce deplacement.` \
    `#` \
    `# ⚠ ET PAS MEMBRE DE lcars-console NON PLUS. Ce groupe-la lui est accorde PAR PROCESSUS a` \
    `# l'exec (setpriv --groups, dans console-landing.sh), jamais par une adhesion : c'est ce qui` \
    `# lui garde zero membre, donc un ensemble de detenteurs vide entre deux lancements.` \
    && groupadd --system lcars-system \
    && useradd --system --no-create-home --shell /usr/sbin/nologin -g lcars-system lcars-system \
    && mkdir -p /run/sshd

# Le runtime déployé, tel que bâti par install.sh — puis le verrou RO du module 60-deploy :
# owner root (personne ne remplace un runtime déployé), groupe fleet r-x, autres rien.
# /usr/local/bin ne reçoit QUE les 2 symlinks-pointeurs (D3) : les launchers pod vivent dans
# $PREFIX/bin, fleet_v2 pose LCARS_*_LAUNCH_PATH dessus — une copie serait une seconde vérité.
COPY --from=build /opt/lcars/runtime /opt/lcars/runtime
RUN chown -R root:fleet /opt/lcars/runtime \
    && chmod -R u=rwX,g=rX,o= /opt/lcars/runtime \
    && ln -sf /opt/lcars/runtime/bin/fleet_v2 /usr/local/bin/fleet_v2 \
    && ln -sf /opt/lcars/runtime/bin/lcars    /usr/local/bin/lcars

COPY --from=site /src/assets/github.io/dist /opt/lcars/share/doc

# `assets/` est la source, et la SEULE chose editee a la main : `<role>.svg` pour l'affichage
# vectoriel, `<role>.png` (256) parce que Gitea decode png/jpeg/gif et PAS le svg — les deux formats
# sont de la matiere, pas un derive l'un de l'autre, et aucun rasteriseur n'a a exister ici.
COPY assets/avatars  /opt/lcars/share/avatars
COPY assets/favicon  /opt/lcars/share/favicon

# Lisible par tous, delibere : la porte n'est pas ici. Le deck sert `/doc/` DERRIERE sa session OIDC
# (`console-deck.py`), et c'est la seule frontiere qui compte. Un mode restrictif de plus ici
# n'ajouterait aucune protection — il rendrait juste le 404 d'un utilisateur non prevu.
RUN chmod -R a+rX /opt/lcars/share

# MEME RANG QUE ttyd, ET C'EST DELIBERE : recupere au BUILD et epingle par sha256, pas commite. Le
# depot garde zero fichier JS tiers ; ce qu'il porte est une reference verifiee, exactement comme le
# binaire au-dessus. Un blob minifie de 290 Ko dans l'historique serait illisible en revue et
# indistinguable d'un blob modifie.
ARG XTERM_VERSION=5.5.0
ARG XTERM_FIT_VERSION=0.10.0
ARG XTERM_JS_SHA256=1f991ac3b4b283ebf96e60ae23a00a52765dd3a2e46fa6fdda9f1aab032f7495
ARG XTERM_CSS_SHA256=ba8e6985669488981ccf40c0cefe3aba80722cb6c92de7ad628b0bd717faf2b6
ARG XTERM_FIT_SHA256=bdaefa370b1bfc42ee88d46fe6072400902a4d4b2d45cd93438dda9b23c97089
RUN set -eu; \
    d=/opt/lcars/deck-static; install -d -m 0755 "$d"; \
    fetch() { \
      curl -fsSL --proto '=https' -m 120 -o "$d/$2" "$1" \
        && echo "$3  $d/$2" | sha256sum -c - >/dev/null \
        || { echo "deck-static: $2 non conforme au pin (URL: $1)" >&2; exit 1; }; \
    }; \
    fetch "https://cdn.jsdelivr.net/npm/@xterm/xterm@${XTERM_VERSION}/lib/xterm.js" \
          xterm.js "${XTERM_JS_SHA256}"; \
    fetch "https://cdn.jsdelivr.net/npm/@xterm/xterm@${XTERM_VERSION}/css/xterm.css" \
          xterm.css "${XTERM_CSS_SHA256}"; \
    fetch "https://cdn.jsdelivr.net/npm/@xterm/addon-fit@${XTERM_FIT_VERSION}/lib/addon-fit.js" \
          addon-fit.js "${XTERM_FIT_SHA256}"; \
    chmod 0644 "$d"/*; \
    ls -l "$d"

# Le provisioning embarqué EN FORME DE REPO (/opt/lcars/fleet/…) : repo_root() de la lib résout
# les chemins inter-arbre (le module 50-forge délègue à fleet/etc/provision-role-tokens.sh).
COPY fleet/deploy /opt/lcars/fleet/deploy
COPY fleet/etc     /opt/lcars/fleet/etc
# ⚠ LA RECETTE ARRIVE ICI, ET PAS AVEC LE RESTE DE `fleet/services` — parce que le bloc `tofu` juste
# en dessous JOUE dedans (`providers mirror` puis `init`), et que `COPY fleet/services` vit 70 lignes
# plus bas. Le jour ou la recette a quitte `fleet/deploy/deps` pour `fleet/services/forge-recipe`,
# elle est passee du COPY d'au-dessus a celui d'en-dessous sans que le bloc tofu bouge : l'image
# mourait sur « No such file or directory » a un endroit dont le chemin venait d'etre corrige
# partout. Un renommage textuel deplace des chemins, jamais des ORDRES.
# Le `COPY fleet/services` plus bas repasse dessus sans dommage : il porte les memes octets, et le
# `.terraform` que `tofu init` cree ici ne figure pas dans le contexte de build (`.dockerignore`).
COPY fleet/services/forge-recipe /opt/lcars/fleet/services/forge-recipe

# Meme discipline que ttyd et le precompile Elixir : version + sha256 epingles ICI, nulle part
# ailleurs, et l'arch vient de `TARGETARCH` (BuildKit) et jamais d'un `uname -m`, qui repondrait
# pour la machine de BUILD — faux des le premier cross-build, et invisible jusqu'au boot sur cible.
ARG TOFU_VERSION=1.12.3
ARG TOFU_SHA256_AMD64=46b48c3438c65cf479fc076c9281422ffa2f493548d1e813d154c835c5986a08
ARG TOFU_SHA256_ARM64=b2110d1ce46e366ce861b7f53d293dad99080075629aed7fb50d7328916d91c2
ARG TARGETARCH
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) tofu_sha="${TOFU_SHA256_AMD64}" ;; \
      arm64) tofu_sha="${TOFU_SHA256_ARM64}" ;; \
      *) echo "tofu: arch de build non supportee: '${TARGETARCH}' (attendu amd64 ou arm64)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --proto '=https' -m 300 -o /tmp/tofu.zip \
      "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${TARGETARCH}.zip" \
    && echo "${tofu_sha}  /tmp/tofu.zip" | sha256sum -c - \
    && unzip -q -o -d /tmp/tofu /tmp/tofu.zip \
    && install -m 0755 /tmp/tofu/tofu /usr/local/bin/tofu \
    && rm -rf /tmp/tofu /tmp/tofu.zip \
    && tofu version

# LES PROVIDERS SONT VENDORES AU BUILD, et c'est un choix, pas une contrainte : `tofu init` au
# runtime FONCTIONNERAIT (le dossier est inscriptible), mais il ferait dependre le premier apply du
# reseau et du registre OpenTofu — au moment precis ou l'operateur monte sa boite. Le miroir de
# fichiers supprime cette dependance, comme le pin sha256 la supprime pour ttyd et Elixir.
# `direct { exclude = ["*/*"] }` FERME la porte reseau, et ce n'est pas de la ceinture : sans lui,
# un provider absent du miroir serait telecharge en silence au premier init, et l'image cesserait
# d'etre reproductible sans que personne ne le voie. Avec, elle echoue en nommant ce qui manque.
# LE TEMOIN DU LOT est le `tofu init` en fin de RUN : il ne peut PAS atteindre le reseau. S'il
# passe, le miroir est complet et les deux lock files sont satisfaits par lui. S'il echoue, l'image
# NE SE BATIT PAS — plutot que de livrer une boite qui decouvre le manque chez l'operateur.
# ⚠ AUCUN COMMENTAIRE EN BACKTICKS ENTRE DEUX INSTRUCTIONS de ce RUN. La forme `# … ` marche dans
# une LISTE D'ARGUMENTS (cf. le apt-get plus haut) et casse ici : la substitution vide precede
# `for … ; do`, le shell lit `for` comme un nom de commande et rend « Syntax error: do unexpected ».
ENV TF_CLI_CONFIG_FILE=/opt/lcars/tofu/tofurc
RUN set -eu; \
    mkdir -p /opt/lcars/tofu/providers; \
    for m in /opt/lcars/fleet/services/forge-recipe /opt/lcars/fleet/services/forge-recipe/instance; do \
      (cd "$m" && tofu providers mirror -platform="linux_${TARGETARCH}" /opt/lcars/tofu/providers); \
    done; \
    { echo 'provider_installation {'; \
      echo '  filesystem_mirror {'; \
      echo '    path    = "/opt/lcars/tofu/providers"'; \
      echo '    include = ["*/*"]'; \
      echo '  }'; \
      echo '  direct {'; \
      echo '    exclude = ["*/*"]'; \
      echo '  }'; \
      echo '}'; } > /opt/lcars/tofu/tofurc; \
    chmod -R a+rX /opt/lcars/tofu; \
    for m in /opt/lcars/fleet/services/forge-recipe /opt/lcars/fleet/services/forge-recipe/instance; do \
      (cd "$m" && tofu init -input=false -no-color >/dev/null) || { echo "tofu: init hors-ligne en echec dans $m" >&2; exit 1; }; \
    done; \
    echo "tofu: miroir de providers complet, init hors-ligne OK"
# P11 — LA BRIQUE token-saver DOIT ETRE DANS L'IMAGE. Sans ce COPY le shim la cherche, ne la trouve
# pas et s'efface : fail-open, AUCUN symptome, et la compression annoncee ne tourne jamais. C'est le
# seul defaut du lot dont personne ne peut s'apercevoir en regardant tourner la fleet.
COPY fleet/vendor/token_saver /opt/lcars/fleet/vendor/token_saver
# Les catalogues METIER autres que la reference. Le release embarque `priv/catalogue` et lui seul
# (mix release ne prend que priv/), donc un catalogue alternatif n'atteint l'image que par ici. Il
# n'est LU par personne tant qu'aucun LCARS_CATALOGUE_ROOT ne le designe : le poser dans l'image ne
# change pas quel metier tourne, ca rend seulement le choix possible sans remonter une image.
COPY catalogues /opt/lcars/catalogues
# ⚠ LA SOURCE DES AUXILIAIRES, ET PAS SEULEMENT LEUR COPIE POSEE. `62-runtime-helpers` compare
# `/opt/lcars/<helper>` a `$(repo_root)/fleet/services/<helper>` — soit `/opt/lcars/fleet/services/`
# ici. Sans ce repertoire, `cmp` echoue sur une source ABSENTE et le module rend « diverge de la
# source » pour chaque auxiliaire : sur docker il ne peut pas s'appliquer (APPLY-ON=wsl linux),
# donc ce drift devenait un ECHEC PERMANENT et la boite ne convergeait jamais.
# Les COPY unitaires plus bas restent : ce sont les auxiliaires POSES, que l'apply du rail poste
# installerait lui-meme et que l'image doit fournir deja en place.
COPY fleet/services /opt/lcars/fleet/services
COPY fleet/deploy/docker/entrypoint.sh /opt/lcars/entrypoint.sh
COPY fleet/services/console.sh         /opt/lcars/console.sh
COPY fleet/services/console-humans.sh  /opt/lcars/console-humans.sh
COPY fleet/services/console-status.sh  /opt/lcars/console-status.sh
COPY fleet/services/console-landing.sh /opt/lcars/console-landing.sh
COPY fleet/services/console-deck.py    /opt/lcars/console-deck.py
COPY fleet/services/console-pod.sh     /opt/lcars/console-pod.sh
COPY fleet/services/human-converger.sh /opt/lcars/human-converger.sh
# L'UNIQUE GESTE PRIVILEGIE DU RAIL TOOLCHAIN — au chemin que le sudoers etroit (45-sudoers) et le
# reconciliateur (`toolchain_reconciler.ex` : `sudo -n <bin> <sha>`) attendent. Dans /usr/local/bin
# et pas /opt : c'est un binaire d'exploitation, pas un composant de boot.
COPY fleet/bin/lcars-toolchain-converge /usr/local/bin/lcars-toolchain-converge
# Le skill du SIEGE (05 §7) — pose par 45-sudoers-toolchain dans le ~/.claude d'admiral, JAMAIS
# par le catalogue : il ne doit pouvoir atteindre aucun pod.
COPY fleet/services/admiral/skills /opt/lcars/fleet/services/admiral/skills
# Les gestes forge, DANS l'image : `box` et le banc les jouent par la meme porte, au lieu
# d'en porter chacun une copie (le banc ne peut pas appeler `box` — sa boite vient d'un autre
# couple de fichiers compose, et `box` refuse a raison d'agir sur un projet qu'il n'a pas cree).
COPY fleet/services/forge-gestures.sh /opt/lcars/forge-gestures.sh
# L'executeur de catalogue, a cote du geste qu'il appelle : les deux atterrissent ENSEMBLE, ou le
# service demarre et refuse chaque demande sur un fichier absent.
COPY fleet/services/catalogue-executor.py /opt/lcars/catalogue-executor.py
# Le module de socket voisin : `catalogue-executor.py` l'importe depuis son repertoire.
COPY fleet/services/lcars_socket.py /opt/lcars/lcars_socket.py
# L'UNIQUE SERVICE ROOT DE LA MACHINE, ET IL NE DETIENT RIEN. Il remplace la regle sudoers
# `%fleet ALL=(root) NOPASSWD:` — le seul chemin `groupe -> root` qui restait, sur un groupe que le
# convergeur repeuple depuis la forge toutes les 30 s. A cote du convergeur qu'il appelle.
COPY fleet/services/privileged-executor.py /opt/lcars/privileged-executor.py
COPY fleet/services/supervise.sh          /opt/lcars/supervise.sh
# LE CLIENT SHELL DE `roles.sock`, DANS /usr/local/bin ET PAS /opt — meme raison que le convergeur
# de toolchain : c'est un outil d'EXPLOITATION, appele par des gestes d'operateur qui vivent dans
# trois arbres qui ne se voient pas (`fleet/bin`, le skill du siege, le release). Un nom sur le PATH
# est le seul rendez-vous qu'aucun des trois n'a a deviner. Il ne DETIENT rien : il demande, et
# c'est la socket qui decide, sur un uid atteste par le noyau.
COPY fleet/bin/lcars-authority-ask /usr/local/bin/lcars-authority-ask
COPY fleet/services/console.tmux.conf  /opt/lcars/console.tmux.conf
# Le SQUELETTE de home : `useradd -m` le copie A LA CREATION de chaque humain, jamais ensuite —
# donc l'humain reste maitre de SON .bashrc, la boite ne le rattrape pas au boot suivant. Contenu :
# le bashrc etendu (ll/la/l, couleurs, completion, lesspipe) qu'une base ubuntu minimale n'a PAS, plus le
# prompt maison de l'humain. `less` et `bash-completion` sont installes plus haut POUR LUI :
# sans eux, deux blocs de ce fichier seraient des no-op silencieux.
#
# ⚠ `--chmod` EST OBLIGATOIRE, ET SON ABSENCE ETAIT UN ECART POSTE/BOITE. Un `COPY` nu PRESERVE le
# mode du fichier dans le contexte de build : `skel.bashrc` est `0664` dans le depot, donc l'image
# le portait en 664 quand la table declare `0644` et que `62-runtime-helpers` le pose bien en 0644
# sur un poste. Le meme objet, deux modes, selon le rail — trouve par le releve croise du rang D
# (bancs 2001 et 2002, 2026-09-01), et invisible autrement : rien ne compare les deux substrats.
# ⚠ LE RACCORD, ET NON PLUS LE REMPLACEMENT — meme geste que `62-runtime-helpers` cote poste.
# L image ecrasait `/etc/skel/.bashrc` par une copie de 117 lignes de la distribution dont trois
# etaient a nous. Elle pose desormais le seul reglage LCARS, et raccorde le squelette de la
# distribution par un bloc qui teste avant de sourcer.
COPY --chmod=0644 fleet/services/lcars.bashrc /etc/lcars/lcars.bashrc
RUN printf "%s\n%s\n%s\n" \
      "# >>> lcars:skel >>> (bloc géré par deploy — édition manuelle écrasée au prochain apply)" \
      "if [ -r /etc/lcars/lcars.bashrc ]; then . /etc/lcars/lcars.bashrc; fi" \
      "# <<< lcars:skel <<<" >> /etc/skel/.bashrc

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

# ⚠ UN MOTIF, PAS UNE LISTE, ET C'EST LA CORRECTION DE FOND. Cette ligne ENUMERAIT les auxiliaires
# un par un — donc elle doublait la liste `HELPERS` de `62-runtime-helpers`, et deux listes qui
# disent la meme chose divergent : `lcars_socket.py` est 100644 dans git, personne ne le chmodait
# ici, et le module le teste par `-x`. Il rendait « absent » sur un fichier PRESENT de 5130 octets,
# et ce drift devenait un echec permanent (APPLY-ON=wsl linux : rien a reparer sur ce substrat).
#
# Le glob supprime la possibilite meme de la divergence : tout auxiliaire depose a la racine de
# `/opt/lcars` est executable, qu'on ait pense a l'ajouter ou non. Ajouter un helper redevient un
# seul geste — le `COPY` — au lieu de deux dont le second ne se signale jamais.
RUN chmod 0755 /opt/lcars/*.sh /opt/lcars/*.py \
               /usr/local/bin/lcars-toolchain-converge \
               /usr/local/bin/lcars-authority-ask \
               /opt/lcars/fleet/deploy/provision \
               /opt/lcars/fleet/deploy/modules.d/*.sh \
               /opt/lcars/fleet/etc/provision-role-tokens.sh

# L'ESTAMPILLE DES AUXILIAIRES POSES — le pendant de ce que `62-runtime-helpers` ecrit sur un poste
# apres les avoir installes. Elle vient du MEME `ARG GIT_SHA` que le LABEL OCI et que
# `PROV_SOURCE_REV` (declare plus haut) : les trois ne peuvent donc pas diverger, et le module
# compare deux valeurs qui ont une seule origine.
RUN printf '%s\n' "${GIT_SHA}" > /opt/lcars/.source-revision

# DEUX volumes d'état, et ils portent deux choses différentes.
#
# /home           = les HUMAINS (~/.lcars, ~/.claude, ~/pods) et les clés d'hôte sshd — un conteneur
#                   recréé garde son identité SSH.
# /opt/lcars/var  = l'ÉTAT de l'installation : les jetons de forge (`PROV_TOKENS_DIR`) et l'état des
#                   recettes tofu (`PROV_CATALOGUES_WORK`).
#
# ⚠ LE SECOND EST UN CORRECTIF, PAS UN AJOUT DE CONFORT. Les jetons vivaient dans `/opt/lcars/var/tokens`,
# donc sur le premier volume ; l'état tofu, lui, était sous `/var/lib/lcars/tofu`, où AUCUN volume
# ne le portait — les quatre volumes du magasin sont `cache`, `toolchains`, `sysroots`, `state`, et
# `tofu` n'en fait pas partie. Il repartait donc à zéro à chaque échange d'image, sans un mot.
# Regrouper l'état sous la racine unique rend le trou visible et le ferme d'une seule ligne.
#
# Les deux composes le NOMMENT : une déclaration `VOLUME` non nommée donne un volume ANONYME, qu'un
# `recreate` orpheline (c'est le piège que `runner-compose.yml` paie déjà pour le magasin dind).
VOLUME ["/home", "/opt/lcars/var"]
EXPOSE 22

# Le port du deck se sonde depuis L'ENV DU CONTENEUR, jamais depuis un litteral : `LCARS_LANDING` et
# `LCARS_LANDING_PORT` ne sont pas declares dans le bloc `environment:` du compose, donc ils sont
# ABSENTS par defaut — et presents exactement quand quelqu'un les pose, c'est-a-dire lisibles ici
# par la meme lecture que celle de l'entrypoint. Les deux cotes lisent la meme chose ou rien.
# ⚠ LE CAS DESACTIVE SORT VERT, ET CE N'EST PAS UNE COMPLAISANCE. `LCARS_LANDING=0` est une
# configuration supportee ; sonder son port quand meme rendrait une boite volontairement sans deck
# definitivement *unhealthy* — un reglage transforme en panne. Ce qui reste sonde alors est ce qui
# reste promis : sshd.
HEALTHCHECK --interval=30s --timeout=5s --start-period=300s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/22 && { [ \"${LCARS_LANDING:-1}\" = 1 ] || exit 0; exec 4<>/dev/tcp/127.0.0.1/\"${LCARS_LANDING_PORT:-20999}\"; }"]

# root : requis par sshd (login-manager qui drop vers l'humain) et par l'entrypoint convergent.
# Les fleets, elles, tournent sous l'UID de CHAQUE humain (le drop est le métier de sshd).
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/lcars/entrypoint.sh"]
