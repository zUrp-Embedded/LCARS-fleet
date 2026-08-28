# syntax=docker/dockerfile:1.7-labs
# SOURCE: fleet/deploy/docker/Dockerfile
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — image LCARS fleet v2 : build multi-stage (mix release) + runtime slim (sshd login-manager)
#
# ISO structurelle avec le chemin WSL : le stage build exécute LE MÊME etc/install.sh (l'autorité
# build+pose, modèle 3 zones), le stage runtime reçoit LE MÊME layout (/opt/lcars/runtime RO
# root:fleet, /usr/local/bin câblé) que le module 60-deploy pose sur WSL. Ce qui converge au
# runtime (humain, forge, claude per-humain) est fait par LE MÊME `provision` à l'entrypoint —
# et vérifiable par LE MÊME doctor. Deux substrats, une seule vérité.
#
# ⚠ UNE SEULE BASE POUR LES DEUX ÉTAGES, ET C'EST LA CIBLE DU RAIL POSTE (⚖ user 2026-08-28).
# L'image bâtissait sur `hexpm/elixir:…-debian-bookworm-slim` et tournait sur `debian:bookworm-slim`
# — une distro que rien ne déployait. Ce que bookworm coûtait était payé en corrections de bookworm,
# et chacune est nommée là où elle vivait : un dépôt `bookworm-backports` pour un git assez récent
# (2.39 < 2.42, `git worktree add --orphan`), ttyd téléchargé en binaire avec deux sha256 épinglés
# (« pas dans bookworm : no installation candidate »), une mesure PEP 668 faite sur `libpython3.11`.
# Sur Ubuntu 26.04 les trois tombent : git 2.53, `ttyd 1.7.7-4build1` — la version qui était
# épinglée — et l'apt qui sert `erlang 1:27.3.4.6` (OTP 27) et `elixir 1.18.3`.
#
# ⚠ ET LE PIN DE TOOLCHAIN PART AVEC LA BASE. `hexpm/elixir` était une SECONDE autorité sur la
# version d'Elixir, en face de `provision-lib.sh` — le Dockerfile écrivait « les deux bougent
# ENSEMBLE » et c'était une convention de PROCESSUS, que `provision_lib.bats` a fini par garder.
# Deux autorités qu'un mur surveille valent mieux qu'une divergence muette, mais moins qu'UNE
# autorité : les deux rails demandent maintenant leur toolchain au même apt, celui de la même
# image de base. Le mur reste, et il compare ce qui subsiste — la base, pas deux versions.
#
# Pins par DIGEST (l'imutabilité ne se déclare pas, elle s'épingle) : bump = nouveau digest ICI,
# les deux ensemble, nulle part ailleurs.
ARG BUILD_IMAGE=ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b
ARG RUNTIME_IMAGE=ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

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
# ⚠ LA TOOLCHAIN ENTRE ICI PAR APT, ET C'EST LE MÊME GESTE QUE `15-toolchain` SUR UN POSTE.
# Elle venait de l'image de base (`hexpm/elixir`), qui la pinnait à un cran que le rail poste
# pinnait de son côté. Une seule base sert maintenant les deux, et `erlang`+`elixir` s'y demandent
# comme partout ailleurs — mêmes paquets, même distro, même OTP. Le plancher qui juge cette paire
# vit dans `provision-lib.sh` (`PROV_ELIXIR_OTP_MAJOR`, `PROV_ELIXIR_MIN`) ; il n'est pas recopié
# ici, il est VÉRIFIÉ en face par `provision doctor` sur la machine qui déploie.
#
# ⚠ UN DÉPÔT `bookworm-backports` VIVAIT SUR CETTE LIGNE, POUR GIT SEUL. Un fixture du gate
# construit un worktree orphelin avec `git worktree add --orphan`, option apparue en git 2.42, et
# bookworm servait 2.39 — sans le backport, exit 129 et un test rouge qui ne parle pas du code.
# Ubuntu 26.04 sert git 2.53 : le dépôt supplémentaire, son fichier dans `sources.list.d` et le
# second `apt-get install -t` partent tous les trois.
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
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       erlang elixir \
       tmux bubblewrap git curl jq unzip ca-certificates python3 python3-pytest bats procps \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 2000 fleet \
    && useradd -m -u 1000 -g fleet builder \
    && install -d -o builder -g fleet /opt/lcars /src /src/fleet /src/fleet \
    && install -d -o builder -g fleet /home/projects.ops /home/projects.workshop \
    && install -d -m 0755 /run/user \
    && install -d -m 0700 -o builder -g fleet /run/user/1000

# HOME suit l'utilisateur — `USER` ne le change PAS (il resterait /root, et mix/hex écriraient
# leurs caches dans un dossier interdit à builder).
# LE DOSSIER RUNTIME PAR UTILISATEUR, ET IL EST LOAD-BEARING POUR LE GATE (6-130 / banc rouge du
# 2026-08-14). `prov_lock_path` pose le verrou de `provision apply` dans un dossier 0700 possede par
# l'appelant : `/run/lock/lcars` en root, `${XDG_RUNTIME_DIR:-/run/user/<uid>}/lcars` sinon. Il
# EXIGE que le parent preexiste — le fabriquer au umask courant rouvrirait, un cran plus haut, le
# trou que 6-130 vient de fermer. Sur une machine systemd, pam_systemd pose `/run/user/<uid>` a
# l'ouverture de session ; dans une image il n'y a pas de session, donc personne ne le pose. Le
# stage runtime tourne en root et trouve `/run/lock` (fourni par l'image de base) : LUI n'a jamais
# rien vu. Ce stage-ci tourne en `builder` (uid 1000) — donc toute la famille `apply` de la suite
# bats echouait ICI, et NULLE PART ailleurs.
#
# ⚠ C'est le meme defaut que `python3-pytest` vingt lignes plus haut, dans l'autre sens : la boite
# de dev a `/run/user/<uid>`, l'image ne l'avait pas — et cette fois le gate en image etait ROUGE
# sur du code sain, pendant que le gate local restait vert. Un ecart d'environnement ne se lit pas
# dans le code qu'il fait rougir.
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
# ⚠ `deploy` EST RESSORTI DE CET ETAGE, ET LE DETOUR VAUT D'ETRE DIT. Il en avait ete RETIRE de la
# liste d'exclusion quelques heures plus tot, parce que le gate tournait ici et lisait
# `deploy/modules.d/45-catalogues.sh` — sans l'arbre, le temoin mourait sur `File.Error` au lieu de
# juger sa propriete. Correctif juste pour la question posee ; la question a change.
#
# CE QUE LA MESURE A MONTRE ENSUITE : le gate n'est pas un gate de `fleet/`, c'est un gate de DEPOT.
# Une fois `deploy/tests` present, il a echoue plus loin — sur `bash /src/install.sh` (exit 127 :
# l'entree est a la RACINE, pas sous `fleet/`), sur `assets/` (meme raison), et sa decouverte
# shellcheck part d'un `git ls-files` qui n'a pas de `.git` ici. Aucun `COPY fleet` ne repare ca ;
# seul un `COPY .` du depot entier le ferait, en invalidant le layer a chaque edition.
#
# ⚖ ARBITRAGE USER 2026-08-28 : l'image NE REJOUE PAS le gate, elle fait confiance au paquet. C'est
# l'intention deja ecrite dans `pack.sh` — « le gate tournait DEUX FOIS sur le meme commit, et la
# premiere ne produisait rien ». L'etage ne porte donc que ce qu'il COMPILE, et `deploy/` n'en est
# pas : l'exclusion revient, et son benefice de cache avec elle.
#
# LE COUT EST NOMME, PAS MASQUE : une image batie depuis un checkout BRUT n'est attestee par
# personne. `etc/install.sh` l'imprime — « la release n'est PAS attestee par le gate de ce commit ».
# Le paquet, lui, porte son attestation : `pack.sh` joue le gate complet sur le depot avant de tarer.
COPY --chown=builder:fleet --exclude=deploy --exclude=git-hooks --exclude=system-prompt \
     fleet /src/fleet

# ─── L'ATTESTATION DU PAQUET, SI LE CONTEXTE EN EST UN ──────────────────────────────────────────
#
# ⚠ CE STAGE RECOMPILAIT CE QUI VENAIT D'ETRE COMPILE, ET LE MECANISME POUR NE PAS LE FAIRE EXISTE
# DEPUIS `f36593757`. `etc/install.sh` (`build_release`) lit `<parent>/.source-revision` : present a
# cote d'une release dans `_build/prod/rel`, il DIT « paquet — release batie par pack.sh (gate joue
# la-bas) » et rend 0 sans rien rejouer. C'est ce chemin que le rail poste emprunte, et c'est
# pourquoi une install y roule en trente secondes. Ici, deux lignes du `.dockerignore` le
# rendaient inatteignable : `fleet/_build` emportait la release, le `*` de tete emportait le stamp.
#
# LE PATTERN EST OPTIONNEL, ET LA FORME EST L'IDIOME, PAS UNE COQUETTERIE. `.source-revisio[n]` est
# un glob : depuis un checkout ordinaire il ne matche RIEN, et un `COPY` dont aucun terme ne matche
# ECHOUE. `LICENSE` est la pour cela — il est dans le contexte par construction (`.dockerignore`
# l'inclut), donc le COPY a toujours au moins une source, et l'attestation entre quand elle existe.
# Elle a sa place a cote : le kit de `pack.sh` porte les deux a la racine.
COPY --chown=builder:fleet LICENSE .source-revisio[n] /src/

# hex/rebar + build + pose sous /opt/lcars/runtime — le cache BuildKit évite de re-télécharger
# hex/deps à chaque build (le layer, lui, se rebuild à chaque changement de source : voulu,
# c'est une release). Les caches appartiennent à builder (uid/gid explicites : un cache root
# serait illisible pour lui). Gate complet + warnings-as-errors : un build rouge NE produit PAS
# d'image. Les symlinks PATH échouent ici (pas de droit sur /usr/local/bin) et c'est SANS gravité :
# le stage runtime les pose lui-même.
#
# ⚠ « NON-FATALEMENT » A CESSÉ D'ÊTRE VRAI, ET CE COMMENTAIRE L'A SURVÉCU DE PLUSIEURS HEURES.
# `install.sh` rendait 0 en annonçant `OK` alors que ses commandes PATH étaient absentes — ou pire,
# pointaient encore sur la version précédente. 6-110 lui a donné le code **3** : *« RELEASE POSÉE,
# LIENS PATH INCOMPLETS »*, un FAIT et non un verdict, que son en-tête dit explicitement
# acceptable pour un appelant qui câble les liens lui-même. Il nommait `deploy/modules.d/60-deploy.sh`
# comme cet appelant. **Ce stage-ci en est un SECOND, et il n'a pas été mis à jour** : le `&&` a
# transformé un échec attendu et documenté ici même en build cassé, invisible tant que personne ne
# reconstruisait l'image. Le `|| [ "$?" -eq 3 ]` accepte ce fait-là **et lui seul** — un 1 (échec
# dur, rien d'utilisable) reste fatal.
#
# La leçon est plus large que la ligne : changer le code de sortie d'un script, c'est changer le
# contrat de TOUS ses appelants, y compris ceux qui ne sont pas des scripts.
# LES CACHES SONT SCOPÉS PAR ARCH, ET CE N'EST PAS DU CONFORT. Un cache BuildKit sans `id` est
# partagé par TOUS les builds de ce Dockerfile — donc entre plateformes. Un `.mix`/`.hex` rempli
# par un build amd64, remonté dans un build arm64, sert des artefacts et des binaires de la
# mauvaise machine : mesuré 2026-08-04, premier build arm64 mort en compilant `:file_system` sur
# un `:gen_server.call` dont le destinataire était un pid SÉRIALISÉ (`<<131, 88, …>>`) — un terme
# écrit par l'autre arch. L'erreur ne parle ni d'arch ni de cache : elle accuse une dépendance
# tierce, et on la cherche pendant une heure du mauvais côté.
# LA REVISION DOIT TRAVERSER JUSQU'A LA RELEASE, PAS SEULEMENT JUSQU'AUX LABELS OCI.
# Mesure du 2026-08-07, depuis l'interieur d'une boite de banc : `fleet_v2 status` rendait
# « build unknown ref= (source=release) ». Le SHA etait declare UNIQUEMENT dans le stage runtime,
# pour le LABEL. Or c'est ICI que la release est estampillee, et `BuildInfo.write_release_file`
# interrogeait `git` — que ce stage n'a pas, deliberement (pas de .git dans le contexte). Le SHA
# voyageait, et s'arretait a l'etage d'a cote.
# Un label OCI se lit du dehors ; l'operateur, lui, regarde depuis DEDANS.
#
# ⚠ CE `unknown` N'EST PAS UN DEFAUT DEFENSIF, C'EST L'ETAT NOMINAL TANT QUE L'APPELANT SE TAIT.
# Il n'existe AUCUN producteur de LCARS_GIT_SHA dans ce depot (mesure 2026-08-14) : le compose le
# lit en `${LCARS_GIT_SHA:-unknown}`, donc toute image construite sans le poser A LA MAIN sort
# aveugle sur son propre code, et rien dans la chaine de build ne le signale. Le seul garde-fou
# vit en aval — `bench-up.sh` lit le label `image.revision` et l'annonce dans son bloc de verdict.
# Poser le SHA fait donc partie du geste de build, ce n'est pas une option de confort.
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

# ⚠ DEUX CHEMINS, ET C'EST `etc/install.sh` QUI TRANCHE — PAS CE FICHIER (⚖ user 2026-08-28).
# Depuis un KIT (`.source-revision` copié juste au-dessus), `build_release` voit la release attestée
# par `pack.sh` et rend 0 : ni gate, ni compilation, la pose seule. Depuis un CHECKOUT NU, il
# compile — et il le DIT, comme il dit déjà que le gate est sauté. L'option de REFUSER de bâtir sans
# kit a été écartée : une image qui ne se bâtit plus depuis un clone est un outil de moins, et le
# trou qu'elle fermerait est déjà nommé à l'écran. Le `echo` ci-dessous met les deux chemins dans le
# log de build, à l'endroit où on les cherche quand un build est trop long ou trop court.
RUN --mount=type=cache,id=lcars-hex-$TARGETARCH,target=/home/builder/.hex,uid=1000,gid=2000 \
    --mount=type=cache,id=lcars-mix-$TARGETARCH,target=/home/builder/.mix,uid=1000,gid=2000 \
    --mount=type=cache,id=lcars-cache-$TARGETARCH,target=/home/builder/.cache,uid=1000,gid=2000 \
    if [ -f /src/.source-revision ]; then \
      echo "image: PAQUET — .source-revision $(cat /src/.source-revision) : la release vient de pack.sh, ni gate ni compilation ici"; \
    else \
      echo "image: CHECKOUT NU — aucun .source-revision : la release est COMPILEE dans ce stage, et le gate n'est PAS rejoue (l'attestation vient du paquet, ce build n'en a pas)"; \
    fi \
    && mix local.hex --force && mix local.rebar --force \
    && { LCARS_INSTALL_SKIP_GATE=1 LCARS_INSTALL_PREFIX=/opt/lcars/runtime bash etc/install.sh \
         || [ "$?" -eq 3 ]; }

# ─── Stage 1bis : la DOC, batie depuis le meme arbre ─────────────────────────────────────────────
#
# La plaquette (`assets/github.io`) se genere DEPUIS le code du produit : les cartes, les sieges,
# les verbes de la console, les arbres d'un catalogue. Sur GitHub elle est publiee par Pages ; ici
# elle part dans l'image pour que la boite serve sa PROPRE doc — celle de la version qu'elle fait
# tourner, pas la derniere en ligne, pas une copie a resynchroniser.
#
# UN STAGE A ELLE, ET NODE N'ENTRE JAMAIS DANS LE RUNTIME. Meme patron que le stage `build` : on ne
# copie que le resultat, ~300 Ko de HTML statique. Le runtime reste Elixir/Ubuntu, sans node, sans
# npm, sans node_modules.
#
# ⚠ L'ARBORESCENCE EST LE CONTRAT. Les lecteurs du site remontent quatre crans depuis
# `src/lib/` pour trouver la racine du depot (`fleet/`, `assets/`), et `collect-assets.mjs` remonte
# deux crans pour trouver `assets/`. Le stage reproduit donc la MEME forme : `/src/assets/github.io`
# avec `/src/fleet` et `/src/assets/*` a cote. Un raccourci de chemin ici ferait echouer le build
# sur un `illisible` qui accuserait le code.
#
# `LCARS_SITE_BASE=/doc/` : le deck la sert sous ce chemin, et tout lien interne se compose depuis
# cette base (`src/lib/href.js`). Batie a la racine, la copie locale s'afficherait et tous ses liens
# partiraient a la racine du deck — cassee en silence.
FROM node:24-slim AS site
# La provenance vient de l'APPELANT : ce stage n'a ni git ni `.git`, et la plaquette affiche le sha
# en pied de page. Sans cet argument elle imprime « unknown », ce qui est honnete et visible.
ARG GIT_SHA=unknown
ENV LCARS_GIT_SHA=${GIT_SHA}
WORKDIR /src/assets/github.io
# Les manifestes d'abord : leur couche se cache tant qu'ils ne bougent pas.
COPY assets/github.io/package.json assets/github.io/package-lock.json ./
RUN npm ci --no-audit --no-fund
# Le site, puis CE QU'IL LIT. Le build echoue si l'un manque, et c'est voulu : une plaquette qui ne
# trouve plus ce qu'elle decrit doit casser, pas servir la version d'avant.
COPY assets/github.io ./
COPY assets/avatars ../avatars
COPY assets/favicon ../favicon
COPY fleet /src/fleet
# ⚠ LE SITE DÉRIVE SES SIÈGES DE TROIS CATALOGUES, ET LE TROISIÈME N'EST PAS SOUS `fleet/`.
# `catalogue.js:48-52` nomme `catalogue-system`, `catalogue` (tous deux dans `fleet/priv/`) et
# `web-demo`, qui vit à la racine du dépôt. Sans cette ligne, `existsSync` est faux, la page
# `equipage` LÈVE, et `npm run build` tue le build de l'IMAGE — pas seulement de la doc.
#
# Mesuré le 2026-08-23 : l'image était inconstructible depuis `ce90419f6` (la veille, 02:01), qui a
# ajouté `web-demo` à la liste du site sans étendre celle-ci. Rien ne l'a vu parce que le site ne se
# bâtit qu'ici — `mix gate` ne touche pas ce stage, `shell_gate` ignore son existence. Un gate
# entièrement vert et un produit qu'on ne peut pas construire.
COPY catalogues /src/catalogues
ENV LCARS_SITE_BASE=/doc/
RUN npm run build

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
       `# ttyd etait recupere en binaire STATIQUE, deux sha256 epingles, un layer et un fetch pour` \
       `# lui seul — parce qu'il n'est pas empaquete par Debian (« no installation candidate »).` \
       `# Ubuntu 26.04 sert ttyd 1.7.7-4build1 dans universe : EXACTEMENT la version qui etait` \
       `# epinglee. Le pin, les deux ARG de sha, le case sur TARGETARCH et le curl partent ensemble.` \
       `# Il est desormais dans PACKAGES (10-packages.sh), donc sur le rail natif : c'est ce qui` \
       `# autorise sa presence ici sans exemption dans deploy_manifest.bats.` \
       ttyd \
    && rm -rf /var/lib/apt/lists/* \
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

# LA DOC DE CETTE VERSION, ET ELLE EST HORS DU PREFIXE DE RELEASE — c'est le fond de l'affaire, pas
# du rangement. Elle a vecu en `/opt/lcars/runtime/doc`, « meme prefixe, meme verrou RO que le reste ».
# Ce verrou est `750 root:fleet` (fichiers `640`), pose deux lignes plus haut, et le deck largue ses
# privileges vers `nobody:nogroup` : il ne pouvait ni traverser le repertoire ni ouvrir un fichier.
# Son `open()` levait, et le handler rendait 404 — un 404 honnete sur « je n'ai pas pu lire », muet
# sur la raison, qui ne distingue pas l'absent de l'interdit. Mesure du 2026-08-20 sur banc neuf,
# session authentifiee reelle : les 9 pages presentes dans l'image, `/doc/` `/doc/manuel/`
# `/doc/outils/` tous en 404.
#
# Affaiblir le verrou du prefixe pour un fichier HTML serait le mauvais echange : ce qu'il protege
# est le runtime deploye. La doc n'est pas du binaire livre, c'est de l'actif statique pour le deck —
# elle sort donc de l'arbre de release, et le `chmod` du runtime ne la touche plus (il est AU-DESSUS
# de ce COPY, et ce n'est pas un hasard d'ordre : c'est lui qui retirait `o`).
#
# Ce qu'elle garde de l'ancien emplacement, parce que c'etait le vrai motif : le MEME COMMIT produit
# le runtime et sa doc, donc la boite ne peut pas servir la doc d'une autre version qu'elle-meme.
COPY --from=site /src/assets/github.io/dist /opt/lcars/share/doc

# ─── LES MEDIAS DE MARQUE — UNE SOURCE, POSEE UNE FOIS, LUE PAR TOUS ────────────────────────────
# ⚠ IL Y EN AVAIT TROIS EXEMPLAIRES, ET ILS AVAIENT DERIVE. Les memes avatars vivaient dans
# `assets/avatars/` (marque, svg), `fleet/deploy/deps/avatars/` (png, pour la charte forge) et
# `fleet/priv/observation/static/assets/` (svg, pour le deck d'observation). Mesure du 2026-08-20 :
# sept des neuf roles communs DIVERGEAIENT entre la marque et le deck — non pas par choix, mais
# parce qu'une mise a jour touchait un dossier et pas les autres. Trois copies d'un meme fait
# derivent ; celle qu'on regarde n'est jamais celle qu'on a corrigee.
#
# `assets/` est la source, et la SEULE chose editee a la main : `<role>.svg` pour l'affichage
# vectoriel, `<role>.png` (256) parce que Gitea decode png/jpeg/gif et PAS le svg — les deux formats
# sont de la matiere, pas un derive l'un de l'autre, et aucun rasteriseur n'a a exister ici.
#
# Le favicon ne se recopie pas non plus : `deps/avatars/favicon.png` etait l'octet pour octet le
# meme fichier que `assets/favicon/favicon-512.png` (md5 identique), sous un autre nom, pour servir
# l'avatar de l'org.
COPY assets/avatars  /opt/lcars/share/avatars
COPY assets/favicon  /opt/lcars/share/favicon

# Lisible par tous, delibere : la porte n'est pas ici. Le deck sert `/doc/` DERRIERE sa session OIDC
# (`console-deck.py`), et c'est la seule frontiere qui compte. Un mode restrictif de plus ici
# n'ajouterait aucune protection — il rendrait juste le 404 d'un utilisateur non prevu.
RUN chmod -R a+rX /opt/lcars/share

# ─── La console web : ttyd, ET IL N'A PLUS DE BLOC A LUI ────────────────────────────────────────
# La porte d'entrée demandée reste la même : une page web avec un shell SOUS L'IDENTITÉ DE L'HUMAIN,
# dans lequel il lance `claude`. Ce qui a changé, c'est d'où vient le binaire.
#
# CE QUI VIVAIT ICI, ET POURQUOI PLUS RIEN N'Y VIT. `ttyd n'est PAS dans bookworm (vérifié : « no
# installation candidate ») ; on prend l'officiel statique — version + sha256 épinglés ICI. » Suivait
# un `case` sur `TARGETARCH`, deux sha256, un `curl`, un `sha256sum -c` et un `install` : dix-sept
# lignes pour ce qu'Ubuntu 26.04 livre sous le nom `ttyd 1.7.7-4build1` — la version exacte qui était
# épinglée. Le paquet est monté dans le `apt-get install` du runtime, et il est entré dans
# `PACKAGES` (10-packages.sh) du même geste : les deux rails le posent maintenant pareil.
#
# ⚠ LE BINAIRE A CHANGÉ DE CHEMIN, ET RIEN NE LE CODE EN DUR. Il était installé en
# `/usr/local/bin/ttyd`, le paquet le pose en `/usr/bin/ttyd`. Le seul consommateur est
# `62-runtime-helpers`, dont la couture (`TTYD_BIN="${LCARS_TTYD_BIN:-ttyd}"`) nomme la COMMANDE et
# pas son chemin — le PATH tranche, et il tranchait déjà avant.

# ─── LE CLIENT DE TERMINAL, ET C'EST LA PREMIERE DEPENDANCE FRONTEND DE CE DEPOT ────────────────
# ⚠ CA SE DIT, CA NE SE GLISSE PAS DANS UN COMMIT. Ce depot ne portait AUCUN JS tiers : tout le
# statique tient en 80 Ko de CSS ecrit a la main et de SVG, et tout le JS est inline. Une premiere
# occurrence est une doctrine, pas un detail — la seconde sera un detail.
#
# POURQUOI IL N'Y A PAS D'ALTERNATIVE SERIEUSE. Le deck rend desormais le terminal dans SON PROPRE
# DOM (plus d'iframe, donc plus de seconde origine). Il lui faut donc un emulateur VT. Mesure du
# 2026-08-14 sur le binaire pinne : ttyd ne livre RIEN a emprunter — client soude dans un binaire
# statique de 1,36 Mo, une seule page de 730 Ko tout inline, 404 sur /xterm.js, /index.js, /main.js,
# /bundle.js et /xterm.css. Les deux autres formes seraient l'iframe same-origin (qu'on vient de
# retirer) ou l'ecriture d'un parseur VT, qui n'est pas serieuse.
#
# MEME RANG QUE ttyd, ET C'EST DELIBERE : recupere au BUILD et epingle par sha256, pas commite. Le
# depot garde zero fichier JS tiers ; ce qu'il porte est une reference verifiee, exactement comme le
# binaire au-dessus. Un blob minifie de 290 Ko dans l'historique serait illisible en revue et
# indistinguable d'un blob modifie.
#
# Les trois pins ont ete calcules le 2026-08-14 sur ces URLs exactes. `Terminal` est le global
# exporte par le bundle UMD (verifie en L'EXECUTANT, pas en le lisant) ; `FitAddon` est celui de
# l'addon, dont l'UMD se lie a `self` — donc navigateur uniquement, ce qui est son emploi.
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

# ─── OpenTofu : LE BINAIRE ET SES PROVIDERS, DANS L'IMAGE ───────────────────────────────────────
# LA RECETTE ETAIT LA DEPUIS TOUJOURS, ET RIEN NE POUVAIT LA JOUER. `/opt/lcars/fleet/deploy/deps`
# est copie juste au-dessus, la structure de la forge est indispensable, et c'est tofu qui la pose
# — or tofu n'etait installe NULLE PART : ni dans cette image, ni par un module de `provision`, ni
# par `install.sh`. La boucle etait fermee : `50-forge` sonde, ne trouve pas la structure, renvoie a
# `box forge-check`, qui imprime une commande exigeant un binaire que rien ne pose. Un
# operateur qui clone et lance obtenait `tofu: command not found`, sans qu'aucun fichier du produit
# ne dise ce qu'est OpenTofu ni ou l'obtenir.
#
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
#
# `direct { exclude = ["*/*"] }` FERME la porte reseau, et ce n'est pas de la ceinture : sans lui,
# un provider absent du miroir serait telecharge en silence au premier init, et l'image cesserait
# d'etre reproductible sans que personne ne le voie. Avec, elle echoue en nommant ce qui manque.
#
# LE TEMOIN DU LOT est le `tofu init` en fin de RUN : il ne peut PAS atteindre le reseau. S'il
# passe, le miroir est complet et les deux lock files sont satisfaits par lui. S'il echoue, l'image
# NE SE BATIT PAS — plutot que de livrer une boite qui decouvre le manque chez l'operateur.
#
# ⚠ AUCUN COMMENTAIRE EN BACKTICKS ENTRE DEUX INSTRUCTIONS de ce RUN. La forme `# … ` marche dans
# une LISTE D'ARGUMENTS (cf. le apt-get plus haut) et casse ici : la substitution vide precede
# `for … ; do`, le shell lit `for` comme un nom de commande et rend « Syntax error: do unexpected ».
ENV TF_CLI_CONFIG_FILE=/opt/lcars/tofu/tofurc
RUN set -eu; \
    mkdir -p /opt/lcars/tofu/providers; \
    for m in /opt/lcars/fleet/deploy/deps /opt/lcars/fleet/deploy/deps/instance; do \
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
    for m in /opt/lcars/fleet/deploy/deps /opt/lcars/fleet/deploy/deps/instance; do \
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
COPY fleet/deploy/admiral/skills /opt/lcars/admiral-skills
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
# LE SUPERVISEUR — ce que `Restart=always` fait sur le rail poste, et que ce rail-ci n'avait PAS.
# `entrypoint.sh` lancait `setsid <cmd> &` : tini recolte les orphelins, il n'en relance aucun. Un
# convergeur mort restait mort jusqu'au prochain `box restart`, sur une boite qui reste *healthy*
# (son healthcheck ne sonde que des ports : ssh + le deck). Il ne peut pas vivre DANS l'entrypoint, qui finit sur
# `exec sshd` — le shell y est remplace, et toute boucle qu'il porterait disparaitrait la.
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
COPY fleet/services/skel.bashrc      /etc/skel/.bashrc

# ─── token-saver : EMBARQUE, et aucun pod ne l'execute — les deux moities comptent ──────────────
#
# La brique de compression d'output (fleet/vendor/token_saver/, Apache-2.0 + glue LCARS) est
# EMBARQUEE : le `COPY` est ~30 lignes plus haut, et le chemin qu'il pose figure bien dans les
# candidats du shim (`.claude/hooks/token-saver-hook.sh`). Ce qui manque n'est pas le transport.
#
# Ce qui manque est l'EXECUTANT : la brique est cablee cote hooks, et un pod n'a pas de hooks — le
# sanctuaire ne monte pas `hooks/` et ne pose pas de cle `hooks` dans ses settings, deliberement
# (`bwrap_launch.sh` : charger le `.claude` de l'humain lui ferait heriter SES hooks et bloquerait
# le boot). Le shim n'est donc jamais appele. Rien ne casse, rien ne compresse, AUCUN SYMPTOME
# VISIBLE — c'est pour ca que la note vit dans ce fichier.
#
# ⚠ CE BLOC A DIT L'INVERSE PENDANT DEUX SEMAINES. Il annoncait « AUCUN COPY ne l'amene ici » et
# proposait, en A FAIRE, d'ajouter la ligne qui existait deja 44 lignes plus haut — posee par le
# demenagement d'arborescence (`7177c9dc2`) sans que la note qui le reclamait soit relue. Deux
# sources contradictoires sur un meme fait, dans un meme fichier : celle qu'on lit n'est jamais
# celle qu'on a corrigee. Releve par une revue le 2026-08-20.
#
# Ce qu'il reste a decider, et ce n'est pas un COPY : par quel chemin un pod compresserait sa
# sortie, puisque les hooks lui sont fermes par construction. `LCARS_TOKEN_SAVER=off` reste le
# switch, python3 est deja la (la brique est stdlib pure).
#
# Ref : fleet/vendor/token_saver/VENDOR.md
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
               /opt/lcars/human-converger.sh \
               /opt/lcars/catalogue-executor.py \
               /opt/lcars/privileged-executor.py \
               /usr/local/bin/lcars-toolchain-converge \
               /usr/local/bin/lcars-authority-ask \
               /opt/lcars/fleet/deploy/provision \
               /opt/lcars/fleet/deploy/modules.d/*.sh \
               /opt/lcars/fleet/etc/provision-role-tokens.sh

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

# sshd répond = le conteneur tient sa promesse (login-manager). Sonde TCP réelle, pas un pgrep
# d'un process que personne ne lance (le healthcheck-tmux menteur de la v1).
#
# ⚠ `--start-period` A ETE ALLONGE DE 20 s A 300 s, ET C'EST UN CORRECTIF, PAS UN CONFORT. Depuis
# que l'entrypoint tire une premiere passe de convergence SYNCHRONE avant `exec sshd`, le port 22
# n'ouvre qu'apres elle — bornee a `LCARS_FIRST_PASS_TIMEOUT` (defaut 120 s), plus le doctor qui
# suit. Avec 20 s de grace, `--interval=30s` et `--retries=3`, docker declarait le conteneur
# *unhealthy* des T+80 s et le laissait dans cet etat jusqu'a l'ouverture du port : une phase rouge
# systematique de plusieurs minutes a CHAQUE demarrage, sur une boite parfaitement saine.
#
# Aucun compose n'a `condition: service_healthy` sur `lcars` aujourd'hui, donc rien ne se bloquait —
# mais tout ce qui observe la sante (un orchestrateur, une supervision, un operateur) lisait un
# mensonge. La grace couvre desormais le pire cas de la passe synchrone avec de la marge.
#
# ⚠ ET LA SONDE NE SUIVAIT PAS LA PROMESSE DE LA BOITE. Elle ne testait que sshd — vrai quand chaque
# console publiait son port, FAUX depuis qu'elles sont sur des sockets AF_UNIX : le deck est
# desormais le SEUL chemin vers elles (l'entrypoint le dit au moment de le lancer). Une boite dont
# le deck etait mort se declarait donc SAINE, parce que sshd, lui, repondait — et sshd n'est plus
# que la porte d'admin, pas celle par laquelle on entre.
#
# Le port du deck se sonde depuis L'ENV DU CONTENEUR, jamais depuis un litteral : `LCARS_LANDING` et
# `LCARS_LANDING_PORT` ne sont pas declares dans le bloc `environment:` du compose, donc ils sont
# ABSENTS par defaut — et presents exactement quand quelqu'un les pose, c'est-a-dire lisibles ici
# par la meme lecture que celle de l'entrypoint. Les deux cotes lisent la meme chose ou rien.
#
# ⚠ LE CAS DESACTIVE SORT VERT, ET CE N'EST PAS UNE COMPLAISANCE. `LCARS_LANDING=0` est une
# configuration supportee ; sonder son port quand meme rendrait une boite volontairement sans deck
# definitivement *unhealthy* — un reglage transforme en panne. Ce qui reste sonde alors est ce qui
# reste promis : sshd.
HEALTHCHECK --interval=30s --timeout=5s --start-period=300s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/22 && { [ \"${LCARS_LANDING:-1}\" = 1 ] || exit 0; exec 4<>/dev/tcp/127.0.0.1/\"${LCARS_LANDING_PORT:-20999}\"; }"]

# root : requis par sshd (login-manager qui drop vers l'humain) et par l'entrypoint convergent.
# Les fleets, elles, tournent sous l'UID de CHAQUE humain (le drop est le métier de sshd).
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/lcars/entrypoint.sh"]
