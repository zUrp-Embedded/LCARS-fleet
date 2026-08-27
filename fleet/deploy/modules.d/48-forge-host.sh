#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/48-forge-host.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — la forge du POSTE DE TRAVAIL : un conteneur Gitea, amorcé et structuré
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
#
# ⚖ ARBITRAGE USER 2026-08-18 : « soit on fait rien, l'user clone et monte des bancs docker ; soit
# on installe et on crée la forge dans le pack ». C'est la seconde.
#
# ⚠ `wsl linux` ET PAS `wsl` : le terrain de ce module est LE RAIL POSTE, pas un noyau. Il a porté
# `wsl` seul pendant deux jours, et rien dans son corps ne le justifiait — `docker_endpoint` est
# déjà substrat-conscient (il choisit son refus selon le terrain), l'adresse est `127.0.0.1`, le
# compose vient du dépôt. Ses pré-requis réels sont un daemon docker (pour la Gitea) et `tofu`
# (pour la structure) — le second est posé par `46-tofu`, et son absence est une dérive NOMMÉE.
#
# CE QUE LE GATE `wsl` A COÛTÉ, mesuré le 2026-08-20 : une install native s'est faite à la main —
# conteneur Gitea, compte d'administration, jeton master, amorçage en deux passes — c'est-à-dire
# que les gestes de ce fichier ont été rejoués un par un par un opérateur qui le croyait absent.
# Un module qui refuse un terrain où il fonctionne n'économise rien : il déplace le travail vers
# quelqu'un qui le fera moins bien, et sans convergence.
#
# POURQUOI CE MODULE EXISTE. Le rail poste-de-travail installe un LCARS qui TOURNE — release posée,
# `fleet_v2` câblé. Un LCARS qui tourne a besoin d'une forge : c'est là que vivent les projets, les
# tickets, les PR et les comptes de rôle. Sans elle, `50-forge` et `55-deck-oidc` restent en dérive
# et leurs consignes nomment `box`, c'est-à-dire la BOÎTE — reconstruire et relancer un
# LCARS en conteneur pour tester celui qu'on vient d'installer nativement. Absurde, et mesuré tel
# quel le 2026-08-18 : 11 modules sur 13 convergés, ces deux-là seuls, pour cette seule raison.
#
# CE QU'IL N'EST PAS : un second chemin de forge. Il n'y a QU'UNE forge dans ce dépôt, et c'est un
# conteneur — `bench-up.sh` monte exactement la même. Ce module joue les mêmes gestes, sans boîte.
#
# ⚠ LA STRUCTURE EST POSÉE PAR UN `tofu` DE LA MACHINE, et rejouable parce que l'état de tofu est
# JETABLE PAR CONSTRUCTION : la recette reconstruit ce qui existe par ses blocs `import` (cf.
# forge-gestures.sh, et c'est pourquoi `--tofu-dir` est devenu un argument ignoré). Chaque passage
# part donc d'un tfstate vide, ce qui est le cas nominal et non un pis-aller.
#
# ⚠ LA RECETTE SE JOUE AVEC LE `tofu` DE LA MACHINE, jamais dans un conteneur monté pour l'occasion.
# Bâtir 1,2 Go d'image pour exécuter 100 ko de recette est un coût d'inventaire — « tofu n'est
# installé nulle part ailleurs » — déguisé en choix d'architecture. `46-tofu` l'installe ; ce module
# l'utilise.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

: "${PROV_FORGE_PROJECT:=lcars-forge}"          # projet compose de la forge du poste
# ─── LE PORT : 21000, COMME LE BANC ─────────────────────────────────────────────────────────────
#
# ⚖ USER 2026-08-22 : « pour le mode bench, on pose 21000 comme port pour notre forge […] poste
# aussi doit passer sur 21000 par défaut. »
#
# ⚠ CE DÉFAUT ÉTAIT `3000`, ET C'EST LE PORT LE PLUS DISPUTÉ D'UN POSTE DE DÉVELOPPEMENT — React,
# Rails, Vite, Grafana le prennent tous par défaut. Un rail qui s'installe SUR le poste de quelqu'un
# ne peut pas revendiquer ce port-là : il gagne la course ou il la perd, et dans les deux cas
# quelqu'un perd quelque chose.
#
# `bench-up.sh` avait déjà tranché pour `21000` — c'est la plage haute, choisie pour être
# improbable, la même logique que `20999` pour le deck. Le poste s'aligne : **un seul port de forge
# dans le produit**, et deux défauts pour un même fait ne restent d'accord que tant que personne
# n'en touche un.
#
# Le geste reste possible pour qui le veut : `PROV_FORGE_HOST_PORT=<port>`.
: "${PROV_FORGE_HOST_PORT:=21000}"              # le port qu'elle publie (aligné sur bench-up.sh)
# ─── QUI ADMINISTRE LA FORGE D'UN POSTE ─────────────────────────────────────────────────────────
# ⚖ USER 2026-08-21 : « l'user qui installe devient admin, et son login remonte sur la forge. »
# C'est D7 appliqué à ce rail : au poste, l'autorité est l'UNIX, pas la forge — le siège est celui
# qui possède la machine, et son compte #1 sur la forge porte SON nom.
#
# Ce défaut valait `admiral` en dur. Deux conséquences, mesurées le 2026-08-21 sur un poste natif :
# le propriétaire de la machine n'était PAS administrateur de sa propre forge, et le compte qui
# l'était portait un nom que personne n'avait choisi, avec un mot de passe généré puis JETÉ — donc
# un compte d'administration où personne ne pouvait entrer.
#
# `admiral` reste le nom du siège DANS LA BOÎTE, où l'entrypoint crée un uid 1000 qu'aucun humain
# n'a nommé. Ici il y a quelqu'un pour le nommer : c'est lui.
: "${PROV_FORGE_ADMIN:=$PROV_HUMAN}"            # le compte qui ADMINISTRE la forge — l'opérateur
: "${PROV_DOCKER_BIN:=docker}"

# ─── DEUX ADRESSES, ET LES CONFONDRE CASSE LA MOITIÉ DES LIENS ─────────────────────────────────
# `bench-up.sh` a déjà payé cette leçon et l'a écrite : « LE RECAP DIT L'ADRESSE QU'ON COMPOSE, PAS
# CELLE SUR LAQUELLE ON ECOUTE. » Ce module n'avait ni l'une ni l'autre — il câblait `127.0.0.1`
# aux deux endroits.
#
#   PROV_FORGE_BIND       l'interface sur laquelle docker PUBLIE le port. C'est une décision de
#                         sécurité : `127.0.0.1` = cette machine seule, `0.0.0.0` = le réseau.
#   PROV_FORGE_ADVERTISE  l'adresse qu'on ÉCRIT dans `ROOT_URL`. Gitea s'en sert pour tous ses
#                         liens, ses URLs de clone et ses retours OAuth. Ouvrir le bind sans la
#                         bouger donne une UI joignable dont chaque lien pointe sur la loopback du
#                         visiteur — cassée depuis toute autre machine.
#
# ⚖ LE DÉFAUT EST OUVERT, ET LE CONTRAIRE ÉTAIT UN DÉFAUT CASSÉ (user 2026-08-21 : « un container
# docker inaccessible sur le réseau ET MÊME PAR SON RUNNER, ça sert à quoi ? »).
#
# Ce module a publié en loopback seul pendant trois jours, sous couvert de prudence. Or la carte
# canon déclare `ci: required` : sans runner, chaque PR attend un statut 45 min puis ESCALADE, et
# rien ne se livre. Et un runner n'atteint PAS une forge en loopback — ses conteneurs de job vivent
# sur un réseau par job, où `127.0.0.1` les désigne eux-mêmes ; un port publié sur la loopback de
# l'hôte n'est pas routable depuis la passerelle du bridge. Une forge fermée n'est donc pas une
# forge prudente : c'est une forge qui ne peut pas faire son travail.
#
# Fermer reste possible — `PROV_FORGE_BIND=127.0.0.1` — mais c'est le geste, pas le défaut, et il
# prive la machine de sa CI.
#
# ⚠ ET LE BIND N'EST PAS LE LEVIER DE L'EXPOSITION, ce qui est la raison de fond. Ce qu'une forge
# publiée expose, c'est une Gitea dont **l'inscription est OUVERTE par conception** et dont les
# comptes ne sont pas restreints (⚖ user 2026-08-17, cf. `50-forge.sh` : « on livre un DÉFAUT »).
# N'importe qui sur le réseau peut donc s'y créer un compte. Fermer le bind ne retire pas cette
# exposition — il retire la CI, et laisse l'exposition intacte le jour où on rouvre. Le levier, s'il
# faut en tirer un, est `DISABLE_REGISTRATION`, et le rail a déjà tranché ce qu'il en fait : il
# SONDE et ANNONCE, il ne mute pas, « parce qu'un admin qui a décidé quelque chose ne doit pas se le
# faire reprendre en silence ».
#
# Le défaut fermé qui vivait ici ne protégeait donc de rien de nommé : c'était la FORME d'un défaut
# sûr — `bench-up.sh` a un `--bind`, donc on a supposé qu'il fallait fermer — sans modèle de menace
# derrière, et au prix du seul usage que la machine a.
#
# ⚠ ET SOUS WSL L'OUVERTURE NE DONNE RIEN SUR LE LAN, ce qui compte pour ne pas la promettre : en
# NAT — le défaut de WSL et de Docker Desktop — publier sur `0.0.0.0` ouvre le port DANS la VM, pas
# sur la machine Windows. ⚖ user 2026-08-18, porté mot pour mot par `bench-up.sh` ; on ne le
# re-découvre pas ici. Le runner, lui, tourne dans cette même VM : il y atteint la forge.
: "${PROV_FORGE_BIND:=0.0.0.0}"
# ─── UNE SEULE DÉRIVATION DE « QUELLE ADRESSE UN TIERS PEUT COMPOSER » ──────────────────────────
#
# ⚠ CE BLOC AVAIT LA SIENNE, ET ELLE IGNORAIT LE NAT. Il faisait `lan_addr` directement ; sous WSL
# en NAT — le défaut de WSL et de Docker Desktop — ça rend l'adresse INTERNE de la VM, qui n'est
# routée depuis aucune autre machine, Windows compris. Mesuré le 2026-08-22 sur une instance
# fraîche : `forge.public.url` valait `http://172.25.115.129:3000`, une adresse que le navigateur de
# l'hôte ne peut pas atteindre.
#
# ⚠ ET LE VOISIN SAVAIT DÉJÀ. `55-deck-oidc` appelle `advertise_addr`, qui connaît le NAT et rend
# `localhost` AVEC son motif. Deux dérivations d'un même fait, et c'est celle qui ignorait le NAT
# qui écrivait le fichier que `50-forge`, `55-deck-oidc` et le deck relisent. C'est exactement le
# symptôme signalé le 2026-08-21 sur .63, dans l'autre sens : le bouton « s'identifier sur la forge »
# envoyait sur une adresse que le visiteur ne pouvait pas composer.
#
# ⚠ LE MOTIF REMONTE AVEC L'ADRESSE. `advertise_addr` pose `PROV_ADVERTISE_WHY` — vide quand
# l'adresse vaut quelque chose, une phrase quand elle ne vaut que localement. Le jeter reviendrait à
# annoncer sans savoir ce qu'on annonce, et la lib le dit en toutes lettres.
#
# ⚠ ON LUI PASSE LE CHOIX ENTIER, PAS SEULEMENT L'ABSENCE — et la première écriture de ce bloc s'y
# est trompée. Elle ne dérivait que si `PROV_FORGE_ADVERTISE` était VIDE, donc un opérateur qui
# posait explicitement `0.0.0.0` obtenait `http://0.0.0.0:21000` : une adresse que personne ne peut
# taper, quelle que soit la main qui l'a posée. Un joker d'écoute n'est pas une adresse, et ça ne
# dépend pas de qui l'a écrit.
#
# `advertise_addr` traite déjà les trois cas dans un seul endroit : un bind PRÉCIS est l'adresse, un
# JOKER se dérive, et la dérivation connaît le NAT. Lui passer `${ADVERTISE:-$BIND}` fait porter les
# trois par la lib — c'est ce que « une seule dérivation » veut dire.
: "${PROV_FORGE_ADVERTISE:=}"
advertise_addr "${PROV_FORGE_ADVERTISE:-$PROV_FORGE_BIND}"
PROV_FORGE_ADVERTISE="$PROV_ADVERTISE"
PROV_FORGE_ADVERTISE_WHY="$PROV_ADVERTISE_WHY"

FORGE_NET="${PROV_FORGE_PROJECT}_default"
FORGE_CONTAINER="${PROV_FORGE_PROJECT}-forge-1"
MASTER_TOKEN_FILE="$PROV_TOKENS_DIR/forge-master.token"
SEED_FILE="$PROV_TOKENS_DIR/forge-seed.pass"
COMPOSE_FILE="$(repo_root)/fleet/deploy/docker/forge-compose.yml"
# ⚠ DEUX URLS, ET CHACUNE A UN SEUL LECTEUR LÉGITIME.
#   LOCAL_URL   par où CE module et ses voisins parlent à la forge — toujours la loopback, parce
#               qu'ils tournent sur la machine. C'est elle qui va dans `forge.url`, lue par
#               `50-forge` et `55-deck-oidc`, et c'est elle que sonde `forge_up`. Elle ne dépend pas
#               de ce qu'on publie : une forge ouverte au réseau reste joignable en local.
#   PUBLIC_URL  ce que Gitea écrit dans ses liens, ses URLs de clone et ses retours OAuth. C'est
#               l'adresse qu'un TIERS compose — un navigateur, un `git clone`, un conteneur de job.
LOCAL_URL="http://127.0.0.1:${PROV_FORGE_HOST_PORT}"
PUBLIC_URL="http://${PROV_FORGE_ADVERTISE}:${PROV_FORGE_HOST_PORT}"

d() { "$PROV_DOCKER_BIN" "$@"; }
forge_up() { curl -fsS -m 5 -o /dev/null "$LOCAL_URL/api/v1/version" 2>/dev/null; }

# Le port sur lequel la forge de CE projet publie AUJOURD'HUI, ou vide si elle ne tourne pas.
#
# ⚠ ON DEMANDE A DOCKER, PAS AU PORT. `forge_up` sonde l'adresse qu'on VEUT ; elle ne dit rien de
# celle qu'on a. Les deux questions se confondent tant que le port ne change pas, et divergent
# exactement quand il change — c'est-a-dire quand la reponse compte.
forge_running_port() {
  d ps --filter "label=com.docker.compose.project=$PROV_FORGE_PROJECT" \
       --filter "label=com.docker.compose.service=forge" \
       --format '{{.Ports}}' 2>/dev/null \
    | sed -n 's/.*:\([0-9]\{1,5\}\)->3000\/tcp.*/\1/p' | head -n1
}

# ⚠ « QUELQUE CHOSE RÉPOND » N'EST PAS « NOTRE FORGE RÉPOND », et la nuance a coûté une install
# entière. Sur un hôte qui porte plusieurs boîtes — un seul daemon Docker Desktop pour toutes les
# distributions WSL, donc un seul espace de ports — le port par défaut était servi par la forge d'une
# AUTRE instance. `forge_up` disait oui, ce module concluait « déjà vivante », et la passe créait ses
# comptes d'administration dans la forge du voisin en écrivant son adresse dans `forge.url`. Rien ne
# le disait. La PROPRIÉTÉ se demande à docker, exactement comme le port juste au-dessus.
forge_is_ours() { [[ "$(forge_running_port)" == "$PROV_FORGE_HOST_PORT" ]]; }

# ⚠ ET LA QUESTION N'A DE SENS QUE SI DOCKER PARLE. Sans lui `forge_running_port` rend vide, ce qui
# est indiscernable de « la forge n'est pas à nous » : refuser là ferait échouer un rail sain sur une
# sonde muette.
docker_answers() { d ps --format '{{.ID}}' >/dev/null 2>&1; }

foreign_forge_refusal() {
  p_fail "une forge répond sur $LOCAL_URL, mais AUCUN conteneur du projet « $PROV_FORGE_PROJECT » ne publie $PROV_FORGE_HOST_PORT — ce n'est pas la forge de cette machine"
  p_fail "  monte la tienne : « --port-forge <autre port> » (ajoute « --forge-project <nom> » si le nom est pris lui aussi)"
}

# ─── LE RUNNER CI — UNE FORGE QUE RIEN NE PEUT SERVIR N'EST PAS UNE FORGE ────────────────────────
#
# Le runner est un etat-cible de ce rail, pas un supplement : une forge sans lui accepte un ticket,
# depense un producteur, ouvre une PR — et la CI attend une machine qui n'existe pas. Il se pose
# donc ici, apres la forge, sous la meme identite et avec la meme CLI qu'elle.
#
# ⚠ UN SEUL MECANISME D'ENROLEMENT. `forge-runner.sh` le porte en entier — jeton d'enregistrement
# par l'API admin, config des jobs, montage du compose — avec ses cicatrices (portee du jeton,
# reseau des jobs, `docker cp` plutot que bind). Il est entierement parametre : on l'APPELLE. Un
# second exemplaire divergerait du premier sur la premiere cicatrice qu'on ne recopierait pas.
#
# ⚠ LE RUNNER REJOINT LE RESEAU DE LA FORGE, il ne compose pas son adresse publiee : depuis un
# conteneur, `127.0.0.1:21000` designe ce conteneur-la. `FORGE_NET` le met sur le bridge de la
# forge, ou elle repond a `http://forge:3000`.
: "${PROV_RUNNER_PROJECT:=${PROV_FORGE_PROJECT}-runner}"

# ⚠ TROIS LABELS, TOUS PUBLICS, ET C'EST CE QUI REND CE RAIL AUTONOME. Ils couvrent les `runs-on`
# des workflows livrés — `shell` (deps-upstream, template projet), `dood` (publish, qui fait du
# docker), `ubuntu-latest` (le gate, et le `runs-on` que tout workflow importé écrit). Le runner
# tire chaque image lui-même : rien à bâtir, rien à semer.
#
# ⚠ PAS DE LABEL `elixir`, ET C'EST DÉLIBÉRÉ. Le servir honnêtement exigerait `lcars-build`, une
# image LOCALE que ce rail ne construit pas ; le servir avec l'image Elixir de base donnerait un
# runner qui prend le job du gate et meurt sur `git` introuvable — vert à l'écran, faux au fond.
# Le gate n'en a plus besoin : il s'installe son BEAM dans le job (`erlef/setup-beam`).
# Annoncer un label qu'on ne sait pas servir est pire que ne pas l'annoncer.
: "${PROV_RUNNER_LABELS:=shell:docker://alpine:3.20,dood:docker://docker:cli,ubuntu-latest:docker://catthehacker/ubuntu:act-latest}"

ci_runner_count() { # rend le nombre de runners, ou vide si la forge ne repond pas
  local tok body
  tok="$( { tr -d '[:space:]' < "$MASTER_TOKEN_FILE" || true; } 2>/dev/null )"
  [[ -n "$tok" ]] || return 1
  body="$(printf 'header = "Authorization: token %s"\n' "$tok" \
          | curl -K - -s -m 10 "$LOCAL_URL/api/v1/admin/actions/runners" 2>/dev/null || true)"
  [[ -n "$body" ]] || return 1
  printf '%s' "$body" | jq -r '.total_count // empty' 2>/dev/null
}

converge_ci_runner() {
  local n
  n="$(ci_runner_count || true)"
  if [[ "${n:-0}" -gt 0 ]]; then
    p_ok "$n runner(s) CI déjà enregistré(s) — la CI de cette forge a une machine"
    return 0
  fi
  # On teste la LISIBILITÉ du fichier, on n'en lit pas le contenu : le délégué le lira lui-même.
  # Un secret qu'on ne met pas dans une variable ne peut être recopié nulle part par accident.
  [[ -s "$MASTER_TOKEN_FILE" && -r "$MASTER_TOKEN_FILE" ]] \
    || { p_warn "runner CI non enrôlable : aucun jeton master lisible ($MASTER_TOKEN_FILE)"; return 0; }

  p_step "forge du poste : enrôlement du runner CI (projet $PROV_RUNNER_PROJECT, réseau $FORGE_NET)"

  # ⚠ PAS `run_quiet` ICI, ET POUR DEUX RAISONS QUI SE CUMULENT. (1) Il imprime la COMMANDE quand
  # elle échoue — donc tout secret passé en argument ressort dans la trace et dans le fichier de
  # capture qu'il conserve. (2) Il émet déjà `p_fail`, ce qui ferait DEUX verdicts pour un seul
  # fait et rendrait l'apply en `1` (échec) là où le contrat veut `2` (appliqué, drift résiduel).
  #
  # Le jeton part par CHEMIN (`--admin-token-file`) : `/proc` de l'hôte ne le voit pas pendant
  # l'appel, et rien ne peut le recopier dans une trace.
  local out rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/forge-runner.XXXXXX")"
  # `DOCKER_BIN` porte la CLI RÉSOLUE — sur ce substrat elle vit dans le montage Docker Desktop et
  # peut être un shim d'escalade. Laisser le délégué chercher « docker » dans le PATH le ferait
  # échouer sur une machine parfaitement saine : rien n'installe docker dans une VM WSL.
  DOCKER_BIN="$PROV_DOCKER_BIN" \
    bash "$(repo_root)/fleet/deploy/docker/forge-runner.sh" \
      --forge-api "$LOCAL_URL/api/v1" --admin-token-file "$MASTER_TOKEN_FILE" \
      --network "$FORGE_NET" --project "$PROV_RUNNER_PROJECT" \
      ${PROV_RUNNER_LABELS:+--labels "$PROV_RUNNER_LABELS"} \
      ${PROV_RUNNER_ACCEPT_GENERIC:+--accept-generic} \
      >"$out" 2>&1 || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    rm -f "$out"
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "runner CI enrôlé — la forge du poste peut faire tourner sa CI"
    return 0
  fi

  # La sortie du délégué SANS la ligne de commande : c'est elle qui dit pourquoi, et elle seule.
  sed 's/^/     /' "$out" >&2
  rm -f "$out"
  # PAS un échec du module : la forge est debout et utilisable, et le verdict de `50-forge` dira
  # que la CI n'a pas de machine. Un apply qui MEURT ici rendrait une forge saine inatteignable.
  p_drift "runner CI NON enrôlé (rc=$rc — le refus du délégué est au-dessus) — la CI restera en attente"
}

# LE VERDICT DIT SUR QUOI ELLE ÉCOUTE, parce que c'est la seule chose qu'un opérateur ne peut pas
# deviner en la voyant répondre en local. Une forge ouverte au réseau et une forme fermée rendent
# le même `200` sur la loopback.
forge_reach_note() {
  case "$PROV_FORGE_BIND" in
    127.0.0.1|localhost|::1) printf ' — cette machine SEULE' ;;
    *) printf ' — OUVERTE sur %s, composable en %s' "$PROV_FORGE_BIND" "$PUBLIC_URL"
       # ⚠ ET QUAND L'ADRESSE NE VAUT QUE LOCALEMENT, ON LE DIT ICI. Sans cette ligne, le verdict
       # annonce « OUVERTE sur 0.0.0.0 » sous WSL en NAT — vrai du bind, faux de ce qu'un tiers
       # peut atteindre. `advertise_addr` a déjà écrit pourquoi ; le jeter serait annoncer sans
       # savoir ce qu'on annonce.
       [[ -n "${PROV_FORGE_ADVERTISE_WHY:-}" ]] && printf ' (%s)' "$PROV_FORGE_ADVERTISE_WHY"
       return 0 ;;
  esac
}

# ─── LE MOT DE PASSE DU #1 SE GARDE, IL NE SE JETTE PAS ─────────────────────────────────────────
# ⚖ D7 (user, 2026-08-21) : l'administrateur DOIT pouvoir entrer dans le webGUI de Gitea. Ce module
# générait un mot de passe de 20 caractères et ne l'affichait NULLE PART — le compte d'administration
# de la forge d'un poste était donc, dès sa création, un compte où personne ne pouvait se connecter.
# La seule porte restante était `gitea admin user change-password` dans le conteneur, ce que rien
# n'indiquait à l'écran.
#
# Random 10 alphabétiques : assez pour n'être pas devinable sur un LAN, assez court pour être RECOPIÉ
# À LA MAIN sans se tromper — c'est un mot de passe qu'un humain note sur un papier, une fois.
#
# ⚠ `tr -dc` SUR UN FLUX INFINI TUE LE SCRIPT. `/dev/urandom` ne se termine pas : `tr -dc … | head`
# ferme le tube et `tr` meurt sur SIGPIPE, ce que `set -o pipefail` remonte en échec de la commande
# entière. On borne la SOURCE, pas la sortie.
new_password() { head -c 200 /dev/urandom | tr -dc 'A-Za-z' | head -c 10; }

# ⚠ L'AFFICHAGE N'A PLUS LIEU ICI, ET S'ARRÊTER ICI ÉTAIT LA FAUTE. Ce module tourne au rang 48 :
# l'encadré était suivi de quarante modules de sortie, donc il avait défilé avant que quiconque
# regarde. Pire, la pause `read` bloquait un installeur au milieu de son travail pour un secret
# qu'on ne pouvait de toute façon plus relire à la fin. Le seul endroit où un opérateur lit
# vraiment, c'est le banner final — `prov_announce_credential` l'y porte.
announce_password() { # announce_password <login> <mot de passe>
  prov_announce_credential "forge du poste — compte d'administration" "$1" "$2"
}

# ─── LE MOT DE PASSE FORGE DE L'HUMAIN INTÉGRÉ — SON PROPRE SECRET, PAS CELUI DE DIX COMPTES ────
#
# ⚠ LE SEED N'EST PAS UN MOT DE PASSE D'HUMAIN, ET IL EN TENAIT LIEU. La recette pose
# `password = var.seed_password` sur TOUT ce qu'elle crée : les comptes de rôle, le compte système,
# et l'humain intégré (`deps/instance/accounts.tf:121`). Le credential avec lequel une personne se
# connecte à la forge était donc le MÊME que celui du compte qui signe les marqueurs système —
# le communiquer, c'était ouvrir les dix.
#
# Les rôles s'en sont affranchis : `provision-role-tokens.sh` pose un password neuf par le jeton
# master, minte avec, et l'oublie. Personne ne faisait ce geste pour l'humain. On le fait ici, avec
# exactement la même mécanique — un `PATCH /admin/users/<u>`, que Gitea accepte du jeton master.
#
# ⚠ ET SEULEMENT QUAND SON COMPTE VIENT D'ÊTRE CRÉÉ, c'est-à-dire dans la passe qui pose la
# structure. Le refaire à chaque apply changerait le mot de passe d'une personne derrière son dos,
# à chaque convergence, sans qu'aucune ligne ne le rattache à un geste qu'elle aurait demandé.
# ⚠ POSÉ UNE FOIS, PAS À CHAQUE CONVERGENCE. La recette est idempotente et rend 0 au second tour :
# son code de sortie ne distingue pas « je viens de créer ce compte » de « il était déjà là ». Sans
# marqueur, chaque apply reposait donc le mot de passe d'une personne derrière son dos, et invalidait
# celui qu'elle avait noté au run précédent.
#
# Le marqueur porte le LOGIN, pas un booléen : si l'humain intégré change de nom, c'est un autre
# compte, et il a droit au sien. `PROV_FORGE_ADMIN_RESET` passe outre — c'est la porte par laquelle
# un opérateur qui a perdu ses identifiants en redemande.
BUILTIN_PW_MARK="$PROV_TOKENS_DIR/forge-builtin-human.posed"

announce_builtin_human_password() {
  local login tok pw code
  # ⚠ ON DEMANDE LE NOM, ON NE LE DEVINE NI NE LE RECOPIE. Sans humain de fleet nommé, c'est le
  # défaut de `forge-gestures.sh` qui a été appliqué à la recette : ce module doit poser un mot de
  # passe sur CE compte-là. Un littéral ici en ferait un second défaut ; sortir en silence — ce que
  # faisait la première écriture — rendait la fonction morte dans le cas NOMINAL, c'est-à-dire
  # exactement quand elle sert. Le verbe `builtin-human` est la porte : une autorité, interrogée.
  login="${PROV_FLEET_HUMAN:-}"
  [[ -n "$login" ]] || login="$(bash "$(repo_root)/fleet/services/forge-gestures.sh" builtin-human 2>/dev/null || true)"
  [[ -n "$login" ]] || { p_warn "mot de passe forge de l'humain intégré NON posé : son nom est indéterminable"; return 0; }

  if [[ -z "${PROV_FORGE_ADMIN_RESET:-}" ]] \
     && [[ "$(cat "$BUILTIN_PW_MARK" 2>/dev/null || true)" == "$login" ]]; then
    p_ok "mot de passe forge de « $login » déjà posé — non rejoué (« PROV_FORGE_ADMIN_RESET=1 » en repose un)"
    return 0
  fi

  tok="$(tr -d '[:space:]' < "$MASTER_TOKEN_FILE" 2>/dev/null || true)"
  [[ -n "$tok" ]] || { p_warn "mot de passe forge de « $login » NON posé : aucun jeton master lisible"; return 0; }

  pw="$(new_password)"
  # ⚠ RIEN NE PASSE PAR ARGV, NI LE JETON NI LE MOT DE PASSE — `-d` les mettrait dans la ligne de
  # commande, lisible dans /proc de tout l'hôte pendant l'appel. Cicatrice 6-141, déjà payée deux
  # fois sur des credentials moins puissants ; le fichier de config de curl accepte `header =` ET
  # `data =`, donc les deux voyagent par stdin.
  code="$(printf 'header = "Authorization: token %s"\nheader = "Content-Type: application/json"\nrequest = "PATCH"\ndata = "{\\"login_name\\":\\"%s\\",\\"source_id\\":0,\\"password\\":\\"%s\\",\\"must_change_password\\":false}"\n' \
            "$tok" "$login" "$pw" \
          | curl -K - -s -o /dev/null -m 15 -w '%{http_code}' "$LOCAL_URL/api/v1/admin/users/$login" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    prov_announce_credential "forge du poste — humain de fleet" "$login" "$pw"
    # Le marqueur s'écrit APRÈS la pose, jamais avant : posé d'avance, il ferait sauter la pose au
    # run suivant sur la foi d'un geste qui a échoué.
    write_atomic "$BUILTIN_PW_MARK" 0600 "root:root" <<<"$login" \
      || p_warn "marqueur non écrit ($BUILTIN_PW_MARK) — le prochain apply reposera ce mot de passe"
  else
    p_warn "mot de passe forge de « $login » NON posé (HTTP ${code:-aucune réponse}) — son compte garde celui de la création"
  fi
}

# ─── LA REPOSE DU MOT DE PASSE ADMIN — UN GESTE DEMANDÉ, JAMAIS UN EFFET DE BORD ────────────────
#
# La forge ne garde qu'un HASH : un mot de passe perdu ne se relit pas, il se remplace. Mais le
# remplacer d'office à chaque apply casserait tout ce qui s'authentifie avec — sans le dire, et sur
# le compte qui administre. Le geste se demande donc explicitement, et il n'a de sens que quand le
# compte EXISTE DÉJÀ (une création vient d'afficher le sien).
#
# `PROV_FORGE_ADMIN_RESET` doit être ajouté à `REEXEC_ENV` d'`install.sh` pour survivre à l'escalade
# sudo : sans ça l'opérateur pose le drapeau, `sudo` le mange, et rien ne se passe — sans un mot.
reset_admin_password_if_asked() { # <rc de la création : 0 = compte tout juste créé>
  [[ -n "${PROV_FORGE_ADMIN_RESET:-}" ]] || return 0
  [[ "${1:-1}" -ne 0 ]] || return 0
  local npw; npw="$(new_password)"
  if d exec -u git "$FORGE_CONTAINER" gitea admin user change-password \
       --username "$PROV_FORGE_ADMIN" --password "$npw" --must-change-password=false \
       >/dev/null 2>&1; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    announce_password "$PROV_FORGE_ADMIN" "$npw"
  else
    p_fail "repose du mot de passe de « $PROV_FORGE_ADMIN » en échec — le compte garde l'ancien"
  fi

  # ⚠ LES DEUX COMPTES SE PERDENT ENSEMBLE, DONC ILS SE REPOSENT ENSEMBLE. L'annonce de l'humain
  # intégré est liée à la passe qui POSE la structure : sur une machine déjà provisionnée elle est
  # sautée, et l'opérateur qui a perdu ses identifiants n'avait de recours que pour l'admin. Une
  # porte qui ne rouvre que la moitié de ce qu'on a perdu n'est pas une porte.
  #
  # Elle exige le nom, et ce n'est pas une lacune : le compte intégré tient son nom du défaut de
  # `forge-gestures.sh`, et le recopier ici en ferait un second. « --fleet-human <nom> » le NOMME,
  # et nommer est déjà le geste par lequel ce rail autorise ce qui touche à un humain.
  if [[ -n "${PROV_FLEET_HUMAN:-}" ]]; then
    announce_builtin_human_password
  else
    p_warn "seul « $PROV_FORGE_ADMIN » a été reposé — pour l'humain de fleet aussi, nomme-le : « --fleet-human <nom> »"
  fi
}

# ─── L'ADMINITÉ SE MESURE SUR LA FORGE, ET SEULE LA FORGE PEUT LA CHANGER ───────────────────────
# Rend `admin`, `plain`, `absent`, ou `unknown` — quatre états, parce que « pas admin » et « pas de
# compte » appellent deux gestes différents, et « je n'ai pas pu demander » n'en appelle aucun.
forge_admin_state() { # forge_admin_state <login>
  local tok body
  # ⚠ `|| true` OBLIGATOIRE : sous `set -e` + `pipefail`, un fichier absent fait échouer la
  # substitution ET le script qui la contient. Un jeton manquant est une RÉPONSE ici, pas une panne.
  # (la redirection englobe le GROUPE : `< fichier 2>/dev/null` laisse le shell crier lui-même
  #  l'absence du fichier, sur un stderr qui n'a pas encore été détourné.)
  tok="$( { tr -d '[:space:]' < "$MASTER_TOKEN_FILE" || true; } 2>/dev/null )"
  [[ -n "$tok" ]] || { echo unknown; return 0; }
  body="$(printf 'header = "Authorization: token %s"\n' "$tok" \
          | curl -K - -fsS -m 10 "$LOCAL_URL/api/v1/users/$1" 2>/dev/null)" || {
    # 404 = pas de compte ; tout le reste (forge muette, jeton périmé) n'est pas une réponse sur
    # l'adminité, et se dire « absent » là-dessus ferait créer un compte qui existe peut-être.
    if curl -fsS -m 10 -o /dev/null "$LOCAL_URL/api/v1/version" 2>/dev/null; then echo absent; else echo unknown; fi
    return 0
  }
  case "$body" in
    *'"is_admin":true'*|*'"is_admin": true'*) echo admin ;;
    *) echo plain ;;
  esac
}

forge_promote_admin() { # forge_promote_admin <login>
  local tok
  # ⚠ `|| true` OBLIGATOIRE : sous `set -e` + `pipefail`, un fichier absent fait échouer la
  # substitution ET le script qui la contient. Un jeton manquant est une RÉPONSE ici, pas une panne.
  # (la redirection englobe le GROUPE : `< fichier 2>/dev/null` laisse le shell crier lui-même
  #  l'absence du fichier, sur un stderr qui n'a pas encore été détourné.)
  tok="$( { tr -d '[:space:]' < "$MASTER_TOKEN_FILE" || true; } 2>/dev/null )"
  [[ -n "$tok" ]] || return 1
  # `login_name` et `source_id` sont EXIGÉS par l'endpoint (Gitea les relit pour la source
  # d'authentification) : les omettre rend 422 sur un corps qui a l'air complet.
  # ⚠ NI LE JETON NI LE CORPS PAR `argv` (6-141) : `-K -` fait lire à curl son en-tête ET sa donnée
  # sur stdin. `-H`/`-d` les mettraient dans la ligne de commande, lisible dans `/proc` de tout
  # l'hôte pendant l'appel. La même forme est déjà en place trois fonctions plus haut.
  printf 'header = "Authorization: token %s"\nheader = "Content-Type: application/json"\nrequest = "PATCH"\ndata = "{\\"admin\\":true,\\"login_name\\":\\"%s\\",\\"source_id\\":0}"\n' \
    "$tok" "$1" \
    | curl -K - -fsS -m 15 "$LOCAL_URL/api/v1/admin/users/$1" >/dev/null 2>&1
}

# ─── LE SIEGE : le #1 de la forge et l'admin unix sont le MEME acteur ───────────────────────────
#
# ⚠ AUCUNE LIGNE `forge_id=1` N'EXISTAIT SUR CE RAIL. La boite enregistre son siege au boot ; le
# poste, lui, nommait son admin forge (`PROV_FORGE_ADMIN := PROV_HUMAN`) et n'enregistrait rien. Le
# lien n'etait donc ecrit nulle part, et la quatrieme branche — les deux cotes nomment deux acteurs
# — n'avait aucun controle.
#
# La derivation est celle de la lib, la MEME que la boite appelle : une seule autorite sur « qui est
# le siege », donc pas de second cadran a tenir accorde.
#
# UNE SEULE FONCTION POUR LES DEUX VERBES, et le mode ne change QUE l'ecriture. Deux blocs auraient
# diverge : le doctor aurait fini par mesurer autre chose que ce que l'apply converge.
seat_binding_report() { # seat_binding_report <check|apply>
  local mode="${1:?}"
  prov_seat_binding "$PROV_FORGE_ADMIN"

  case "$PROV_SEAT_BINDING" in
    diverge)
      # Le desaccord ne se repare pas ici : renommer un compte unix ou un compte forge est une
      # decision d'operateur, pas une convergence. On le NOMME, et le module derive.
      p_drift "siège : « $PROV_FORGE_ADMIN » côté unix, « $PROV_SEAT_LOGIN » côté $PROV_SEAT_SOURCE — deux acteurs pour un rôle, et le lien n'est PAS enregistré tant qu'ils ne s'accordent pas"
      return 0
      ;;
    unknown)
      p_warn "siège : ni compte unix nommé, ni #1 lisible sur la forge — le lien n'est pas mesurable"
      return 0
      ;;
  esac

  # ⚠ L'UID SE LIT, IL NE SE SUPPOSE PAS — la regle est celle du convergeur, qui enregistre APRES le
  # `useradd` : « on note l'uid QUE LE SYSTEME A DONNE, pas celui qu'on esperait ». Aucun repli ici :
  # sur ce rail `PROV_FORGE_ADMIN` vaut `PROV_HUMAN`, donc le candidat n'est jamais vide, donc les
  # trois verdicts atteignables portent un login qui A un compte unix — ou n'enregistrent rien
  # (`diverge`). Un `|| 1000` n'aurait servi aucun etat reel, et aurait ecrit l'uid de quelqu'un
  # d'autre dans la table que le convergeur relit.
  if [[ -n "$(prov_seat_from_map)" ]]; then
    p_ok "siège : « $PROV_SEAT_LOGIN » enregistré ($PROV_UID_MAP_FILE, forge_id 1)"
  elif [[ "$mode" != "apply" ]]; then
    p_drift "siège : « $PROV_SEAT_LOGIN » connu ($PROV_SEAT_SOURCE) mais NON enregistré — l'apply pose la ligne"
  elif prov_seat_record "$PROV_SEAT_LOGIN" "$(id -u "$PROV_SEAT_LOGIN")"; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "siège : « $PROV_SEAT_LOGIN » enregistré ($PROV_UID_MAP_FILE, forge_id 1)"
  else
    p_drift "siège : « $PROV_SEAT_LOGIN » NON enregistré dans $PROV_UID_MAP_FILE"
  fi
}

check() {
  if ! docker_endpoint; then
    # Même mot que 00-preflight, et pour la même raison : ce rail ne PEUT pas tenir son état-cible
    # sans docker, donc ce n'est pas une dérive. Le préflight refuse déjà en amont ; si on arrive
    # ici quand même, on ne se contredit pas.
    p_fail "$PROV_DOCKER_WHY — la forge du poste est un CONTENEUR, il n'en existe aucune autre forme"
    verdict_check
  fi
  if forge_up && docker_answers && ! forge_is_ours; then
    foreign_forge_refusal
    verdict_check
  fi
  if forge_up; then
    p_ok "forge du poste vivante ($LOCAL_URL)$(forge_reach_note)"
    [[ -s "$MASTER_TOKEN_FILE" ]] && p_ok "autorité de création présente ($MASTER_TOKEN_FILE)" \
      || p_drift "forge vivante mais AUCUNE autorité ($MASTER_TOKEN_FILE) — l'apply la minte"
    # ⚖ D7 : le propriétaire de la machine administre sa forge. Ça se SONDE, sinon la dérive
    # n'existe que le jour où quelqu'un essaie d'ouvrir la page d'administration et se fait jeter.
    seat_binding_report check
    case "$(forge_admin_state "$PROV_FORGE_ADMIN")" in
      admin)   p_ok "« $PROV_FORGE_ADMIN » administre la forge" ;;
      plain)   p_drift "« $PROV_FORGE_ADMIN » n'est PAS administrateur de sa propre forge — l'apply le promeut" ;;
      absent)  p_drift "« $PROV_FORGE_ADMIN » n'a pas de compte sur cette forge — l'inscription est libre, elle se fait une fois" ;;
      *)       p_warn "adminité de « $PROV_FORGE_ADMIN » non mesurable (jeton absent ou forge muette)" ;;
    esac
  else
    p_drift "aucune forge sur $LOCAL_URL — l'apply monte le conteneur, l'amorce et pose sa structure"
  fi
  verdict_check
}

apply() {
  if ! docker_endpoint; then
    p_fail "$PROV_DOCKER_WHY — forge NON montée, et elle ne peut pas l'être autrement"
    verdict_apply
  fi
  # ⚠ CE MODULE NE DÉPEND PLUS D'UNE IMAGE, IL DÉPEND DE `46-tofu`. Il exigeait ici la présence de
  # `lcars-fleet:2` — 1,18 Go bâtis pour exécuter 100 ko de recette dans un conteneur jetable, sur un
  # rail qui ne démarre jamais cette image. Ce qu'elle apportait de réel (une version figée, des
  # providers hors-ligne) est posé SUR la machine, deux crans plus tôt.
  #
  # On sonde le BINAIRE et non la version : `46-tofu` est l'autorité du pin, et re-juger ici en
  # ferait un second. Ce qui manque à ce module, c'est un tofu — pas un avis sur lequel.
  if [[ ! -x "${LCARS_TOFU_BIN:-/usr/local/bin/tofu}" ]]; then
    p_drift "tofu absent — la structure de la forge est son territoire : joue « 46-tofu » d'abord, puis relance"
    verdict_apply
  fi
  # ─── 1. LE CONTENEUR ───────────────────────────────────────────────────────────────────────────
  #
  # ⚠ CE BLOC A ÉTÉ NON IDEMPOTENT PENDANT TOUTE SA VIE, SOUS UN COMMENTAIRE QUI DISAIT LE
  # CONTRAIRE. Il portait « `compose up -d` est idempotent : il ne recrée que si la déclaration a
  # bougé » — vrai de `compose`, et parfaitement inutile puisque l'appel était enfermé dans un
  # `if ! forge_up`. Une forge VIVANTE n'atteignait donc jamais la seule commande capable de la
  # faire converger : le module sondait la LIVENESS et concluait sur la DÉCLARATION.
  #
  # MESURE DU 2026-08-21 : `PROV_FORGE_BIND` passe de `127.0.0.1` à `0.0.0.0`, apply rejoué, verdict
  # « forge du poste déjà vivante » — et le conteneur toujours publié sur la loopback. Il a fallu
  # taper `compose up -d` à la main. Le mode de défaillance est le pire de sa catégorie : le rail
  # affirme la conformité d'un état-cible qu'il n'a pas regardé.
  #
  # `compose up -d` est la convergence, pas le montage : sur une déclaration inchangée c'est un
  # no-op d'une seconde ; sur une déclaration modifiée il recrée. On l'appelle donc TOUJOURS, et
  # c'est `forge_up` AVANT qui dit si l'on a monté ou simplement reconvergé.
  local was_up=0; forge_up && was_up=1

  # ⚠ LE PORT EST SONDÉ AVANT LE MONTAGE, ET LE VERDICT NOMME L'OCCUPANT.
  #
  # ⚖ USER 2026-08-22 : « les ports que tu montes, ils sont testés pour voir si c'est dispo ? » —
  # non, et l'échec était MAL NOMMÉ, ce qui est pire que bruyant. `compose up -d` rendait
  # « port is already allocated » dans une sortie dumpée, et ce module concluait « la forge ne
  # converge pas » : l'opérateur cherche un défaut de LCARS quand le fait est « autre chose tient
  # 3000 ».
  #
  # ⚠ ET `3000` EST LE DÉFAUT DE LA MOITIÉ DE L'ÉCOSYSTÈME DE DEV — React, Rails, Vite, Grafana.
  # Mesuré sur le poste de l'auteur : il est tenu par la forge de LCARS elle-même, et les bancs sont
  # déjà décalés en 3001/3002. Le besoin de ports distincts est connu du produit ; il n'était pas
  # vérifié.
  #
  # ⚠ « PRIS PAR NOUS » N'EST PAS « PRIS PAR UN AUTRE ». `forge_up` vient de répondre : si NOTRE
  # forge écoute, le port est légitimement occupé et refuser ici casserait l'idempotence — c'est le
  # cas NOMINAL d'un second passage. On ne refuse que si le port est pris ET que la forge ne
  # répond pas.
  # ⚠ CHANGER LE PORT SANS CHANGER LE PROJET DÉPLACE LA FORGE, IL N'EN AJOUTE PAS UNE. `compose up`
  # sur le même projet RECRÉE le conteneur avec le nouveau mapping : les volumes suivent, donc rien
  # n'est perdu — mais l'ancienne adresse cesse de répondre, et tout ce qui la pointait devient
  # périmé jusqu'à la prochaine convergence (`forge.url`, la config du runner, le callback OIDC).
  #
  # Et rien ne le disait : `forge_up` sonde le port DEMANDÉ, n'y trouve rien, et le module conclut
  # « pas de forge » — puis en monte une, qui est l'ancienne, ailleurs.
  #
  # Les deux gestes sont nommés parce qu'ils sont deux INTENTIONS différentes, et que refuser sans
  # les distinguer laisserait l'opérateur deviner laquelle on lui refuse.
  if [[ "$was_up" -eq 1 ]] && docker_answers && ! forge_is_ours; then
    foreign_forge_refusal
    verdict_apply
  fi

  local _running; _running="$(forge_running_port)"
  if [[ -n "$_running" && "$_running" != "$PROV_FORGE_HOST_PORT" ]]; then
    p_fail "la forge du projet « $PROV_FORGE_PROJECT » tourne déjà sur le port $_running, et cette passe en demande $PROV_FORGE_HOST_PORT — je ne la déplace pas sans qu'on me le dise"
    p_fail "  une SECONDE forge      : « --forge-project <nom> » (conteneur, réseau, volumes et runner à elle)"
    p_fail "  DÉPLACER celle-ci      : « $PROV_DOCKER_BIN compose -p $PROV_FORGE_PROJECT down » d'abord, puis relance"
    verdict_apply
  fi

  if [[ "$was_up" -eq 0 ]] && port_taken "$PROV_FORGE_HOST_PORT"; then
    local holder; holder="$(port_holder "$PROV_FORGE_HOST_PORT")"
    p_fail "port $PROV_FORGE_HOST_PORT déjà pris${holder:+ par $holder}, et ce n'est PAS la forge de LCARS (elle ne répond pas sur $LOCAL_URL)"
    p_fail "choisis-en un autre : PROV_FORGE_HOST_PORT=<port> — ou libère celui-ci"
    verdict_apply
  fi

  [[ "$was_up" -eq 1 ]] \
    || p_step "forge du poste : montage du conteneur Gitea (projet $PROV_FORGE_PROJECT, port $PROV_FORGE_HOST_PORT)"
  LCARS_DEVFORGE_PORT="$PROV_FORGE_HOST_PORT" LCARS_DEVFORGE_BIND="$PROV_FORGE_BIND" \
  LCARS_DEVFORGE_ROOT_URL="$PUBLIC_URL/" \
    run_quiet d compose -f "$COMPOSE_FILE" -p "$PROV_FORGE_PROJECT" up -d \
    || { p_fail "la forge ne converge pas (compose -p $PROV_FORGE_PROJECT)"; verdict_apply; }
  local i
  for i in $(seq 1 60); do forge_up && break; sleep 2; done
  forge_up || { p_fail "forge montée mais muette sur $LOCAL_URL après 120 s"; verdict_apply; }
  if [[ "$was_up" -eq 1 ]]; then
    p_ok "forge du poste vivante et convergée ($LOCAL_URL)$(forge_reach_note)"
  else
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "forge du poste montée ($LOCAL_URL)$(forge_reach_note)"
  fi

  # 1-bis. ELLE ANNONCE SON ADRESSE, parce que personne d'autre ne peut le faire pour elle. Les
  #    modules sont des PROCESSUS : ce shell ne peut rien exporter vers `50-forge`. Sans ce fichier,
  #    une install qui vient de monter une forge vivante voit `50-forge` et `55-deck-oidc` dériver
  #    sur « FORGE_BASE_URL non posé » — mesuré le 2026-08-18. 0644 : c'est une ADRESSE, pas un
  #    secret, et le doctor d'un humain doit pouvoir la lire.
  write_atomic "$PROV_TOKENS_DIR/forge.url" 0644 "root:$PROV_FLEET_GROUP" <<<"$LOCAL_URL" \
    || { p_fail "adresse de la forge non posée ($PROV_TOKENS_DIR/forge.url)"; verdict_apply; }
  # ⚠ LES DEUX ADRESSES SE PERSISTENT, PAS UNE. Ce module dérive `PUBLIC_URL`, s'en sert pour le
  # `ROOT_URL` de Gitea — et ne l'écrivait NULLE PART. `provision-lib` défautait donc l'adresse
  # NAVIGATEUR sur l'adresse SERVEUR, et le deck envoyait ses visiteurs s'identifier sur LEUR propre
  # loopback : mesure du 2026-08-21, bouton « s'identifier sur la forge » →
  # `http://127.0.0.1:3000/login/oauth/authorize?…&redirect_uri=http://10.42.0.63:20999/…`, le retour
  # juste et l'aller nulle part. Le seul module qui connaissait l'adresse publique la jetait.
  write_atomic "$PROV_TOKENS_DIR/forge.public.url" 0644 "root:$PROV_FLEET_GROUP" <<<"$PUBLIC_URL" \
    || { p_fail "adresse publique de la forge non posée ($PROV_TOKENS_DIR/forge.public.url)"; verdict_apply; }

  # ⚠ LA REPOSE VIT HORS DE LA GARDE DU JETON MASTER, ET C'EST TOUT L'INTÉRÊT. Le bloc ci-dessous
  # ne s'exécute que sur une forge SANS jeton master — donc une seule fois dans la vie d'une
  # machine. Un opérateur qui a perdu son mot de passe est, par construction, toujours après ce
  # moment-là : une repose enfermée dedans serait inerte exactement quand on en a besoin.
  [[ -s "$MASTER_TOKEN_FILE" ]] && reset_admin_password_if_asked 1

  # 2. L'AUTORITÉ. Le compte d'administration et son jeton, mintés DANS le conteneur (`gitea admin`
  #    n'a pas besoin d'un jeton pour créer le premier). Le fichier est le même que celui que la
  #    boîte garde : `50-forge` le lit sans savoir qui l'a posé.
  if [[ ! -s "$MASTER_TOKEN_FILE" ]]; then
    p_step "forge du poste : compte d'administration « $PROV_FORGE_ADMIN » et jeton master"
    local pw err rc; pw="$(new_password)"
    err="$(mktemp "${TMPDIR:-/tmp}/forge-admin.XXXXXX")"
    rc=0
    d exec -u git "$FORGE_CONTAINER" gitea admin user create \
      --username "$PROV_FORGE_ADMIN" --password "$pw" \
      --email "$PROV_FORGE_ADMIN@lcars.local" --admin --must-change-password=false \
      >/dev/null 2>"$err" || rc=$?

    # ⚠ TROIS SORTIES, PAS DEUX, ET LA CONFUSION SE PAYAIT EN COMPTE INEXISTANT. Cette branche
    # traduisait TOUT code non nul en « déjà présent », `stderr` jeté. Une création refusée pour
    # une autre raison — politique de mot de passe, forge pas encore prête, nom invalide —
    # ressortait donc en `OK` sur un compte que personne n'avait créé, et l'opérateur découvrait
    # des semaines plus tard qu'il ne pouvait pas se connecter à sa propre forge. Un verdict vert
    # sur un fait faux ne se rattrape pas : il empêche de chercher.
    if [[ "$rc" -eq 0 ]]; then
      announce_password "$PROV_FORGE_ADMIN" "$pw"
    elif grep -qiE 'already exist|user already|login name.*taken' "$err" 2>/dev/null; then
      # Le compte est là et son mot de passe est un HASH : la forge ne peut pas le rendre, et nous
      # non plus. On ne le remplace pas au passage — des jetons et des sessions en dépendent. Mais
      # on ne laisse pas l'opérateur sans porte : le geste qui en repose un est NOMMÉ.
      p_ok "compte « $PROV_FORGE_ADMIN » déjà présent (son mot de passe est un hash, il n'est pas relisible)"
      p_warn "besoin d'un mot de passe pour t'y connecter ? « PROV_FORGE_ADMIN_RESET=1 » sur un apply en pose un neuf et l'affiche"
    else
      p_fail "création du compte « $PROV_FORGE_ADMIN » REFUSÉE par la forge : $(tr -d '\r' < "$err" | grep -v '^$' | tail -3 | tr '\n' ' ')"
      rm -f "$err"
      verdict_apply
    fi
    rm -f "$err"

    reset_admin_password_if_asked "$rc"
    # ⚠ SONDER LE FLUX AVANT DE CAPTURER — sinon le diagnostic accuse la forge, qui est saine.
    # Un relais docker peut répondre parfaitement à `version`/`ps`/`inspect` et rendre ZÉRO OCTET,
    # EXIT 0, sur `exec`. La capture ci-dessous devient alors une chaîne vide, et le refus juste en
    # dessous dit « la forge n'a rendu aucun jeton master » — un diagnostic faux, sur un objet sain,
    # exactement celui que `bench-up.sh` a payé et documenté. La sonde est un aller-retour RÉEL.
    docker_stream_ok "$FORGE_CONTAINER" || {
      p_fail "le daemon docker répond aux lectures mais rend du VIDE sur « exec » (relais amputé) — rien ne peut être capturé depuis $FORGE_CONTAINER, et la forge n'y est pour rien. Vise la socket Docker Desktop directement : DOCKER_HOST=unix://$(_docker_mount_sock)"
      verdict_apply
    }
    local tok
    tok="$(d exec -u git "$FORGE_CONTAINER" gitea admin user generate-access-token \
             --username "$PROV_FORGE_ADMIN" --token-name "poste-$(date +%s)" --scopes all --raw \
             2>/dev/null | tail -n1 | tr -d '[:space:]')"
    [[ -n "$tok" ]] || { p_fail "la forge n'a rendu aucun jeton master pour $PROV_FORGE_ADMIN"; verdict_apply; }
    # ⚠ `0600 root:root` DÈS LE MINT, ET C'ÉTAIT LE TROU. Ce jeton est l'autorité TOTALE de la
    # forge ; il naissait `0640 root:$PROV_FLEET_GROUP`, donc lisible par TOUT humain de la boîte,
    # et c'est `50-forge converge_authority_modes()` qui le refermait — plus tard, dans un AUTRE
    # module. Un secret dont la fermeture dépend d'un module qui n'a pas encore tourné est ouvert
    # pendant l'intervalle, et ouvert tout court le jour où ce module rend la main plus tôt.
    #
    # Le seul lecteur légitime est `catalogue-executor.py`, qui tourne sous `lcars-authority`
    # (`64-services`, `User=$AUTHORITY_USER`) : personne d'autre n'a besoin de ce fichier, donc
    # personne d'autre ne doit pouvoir l'ouvrir — root compris, qui n'en est que le dernier recours.
    write_atomic "$MASTER_TOKEN_FILE" 0600 "$PROV_AUTHORITY_USER:$PROV_AUTHORITY_USER" <<<"$tok" \
      || { p_fail "jeton master non posé ($MASTER_TOKEN_FILE)"; verdict_apply; }
    p_chg "autorité de création posée ($MASTER_TOKEN_FILE, $PROV_AUTHORITY_USER seul)"
  else
    p_ok "autorité de création déjà posée ($MASTER_TOKEN_FILE)"
  fi

  # 2-bis. SUR UNE FORGE DÉJÀ DEBOUT, L'OPÉRATEUR N'EST PEUT-ÊTRE PAS ENCORE ADMIN. Le bloc
  #    au-dessus ne s'exécute qu'au PREMIER passage ; une machine installée avant ce lot porte donc
  #    une forge dont l'administrateur est un autre compte, et le propriétaire de la machine y est
  #    un utilisateur ordinaire. Mesuré le 2026-08-21 : `admiral` admin, `lordzurp` pas admin, sur
  #    la machine de lordzurp.
  #
  #    ⚠ IL N'EXISTE PAS DE `gitea admin user set-admin` : la CLI sait CRÉER un admin, pas en
  #    promouvoir un. La promotion passe par l'API, avec le jeton master — donc elle n'est possible
  #    que s'il existe déjà une autorité, ce qui est exactement le cas de figure visé.
  case "$(forge_admin_state "$PROV_FORGE_ADMIN")" in
    admin)
      p_ok "« $PROV_FORGE_ADMIN » administre la forge" ;;
    absent)
      p_warn "« $PROV_FORGE_ADMIN » n'a pas de compte sur cette forge — l'inscription est libre, elle se fait une fois puis ce module le promeut" ;;
    plain)
      if forge_promote_admin "$PROV_FORGE_ADMIN"; then
        PROV_CHANGED=$((PROV_CHANGED + 1))
        p_chg "« $PROV_FORGE_ADMIN » promu administrateur de la forge (⚖ D7 : le siège, c'est celui qui installe)"
      else
        p_fail "« $PROV_FORGE_ADMIN » n'a pas pu être promu administrateur — le jeton master de $MASTER_TOKEN_FILE porte-t-il encore l'adminité ?"
      fi ;;
    *)
      p_warn "adminité de « $PROV_FORGE_ADMIN » non mesurable (forge muette ou jeton absent) — rien n'a été tenté" ;;
  esac

  # 3. LE SEED. Il ne se REGÉNÈRE pas : le provider n'écrit pas le password d'un compte existant
  #    (mesure 2026-08-16), donc un seed neuf donnerait un fichier qui ne correspond plus aux
  #    comptes et le mint des jetons de rôle partirait en 401.
  if [[ ! -s "$SEED_FILE" ]]; then
    # `|| true` : même classe que la dérivation du catalogue plus haut. `head -c 20` ferme le tuyau
    # dès qu'il a ses 20 octets, ce qui SIGPIPE l'amont ; sous `pipefail` le pipeline rend 141 et
    # `set -e` abat le module. Latent — il dépend du bufferisation — donc invisible jusqu'au jour où
    # il tombe, sur une machine, sans laisser de ligne.
    local seed; seed="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20 || true)"
    [[ -n "$seed" ]] || { p_fail "seed non générable (/dev/urandom illisible ?)"; verdict_apply; }
    # `0600 root:root`, comme le jeton master quelques lignes plus haut : les DEUX secrets d'autorité
    # se ferment ensemble, ou l'install casse entre les deux. Seul `catalogue-executor.py` les ouvre,
    # et il tourne en root.
    write_atomic "$SEED_FILE" 0600 "$PROV_AUTHORITY_USER:$PROV_AUTHORITY_USER" <<<"$seed" \
      || { p_fail "seed non posé ($SEED_FILE)"; verdict_apply; }
    p_chg "seed des comptes posé ($SEED_FILE, root seul)"
  else
    p_ok "seed des comptes déjà posé ($SEED_FILE)"
  fi

  # 4. LE ROSTER, dérivé du catalogue par `CatalogueRoles` — la MÊME autorité dans les deux cas,
  #    seul l'endroit où elle s'exécute change.
  #
  # ⚠ `--repo` ET NON `--image`, SUR CE RAIL ET LUI SEUL. Le script préfère `--image` et le dit :
  # « `--repo` compile l'arbre source : il exige un toolchain Elixir sur la machine qui appelle. Le
  # chemin de livraison n'en a pas — le banc est mort dessus sur la première machine neuve
  # (2026-08-22, `mix: ABSENT`). » C'est vrai de la BOÎTE, qui se livre sans toolchain. Le rail
  # POSTE, lui, a posé Elixir au module 15 — et c'est sa raison d'être : il BÂTIT le runtime.
  #
  # ⚠ ET « ELIXIR EST POSÉ » NE SUFFIT PAS — révision du 2026-08-22, à froid. `mix compile` exige
  # `deps/`, qui est GITIGNORÉ : sur un clone neuf il n'existe pas. Hex, rebar et `deps.get`
  # arrivaient au module 60, DOUZE CRANS PLUS LOIN. La première passe mourait donc ici, en accusant
  # le module 15 — qui avait fait son travail.
  #
  # C'est le prix de la bascule et il se paye ICI : ce module est devenu le PREMIER consommateur du
  # toolchain de build, donc c'est à lui de le rendre utilisable. `60-deploy` garde les siens : il
  # doit rester jouable seul (`--only 60-deploy`), et ces gestes sont idempotents.
  #
  # ⚠ ET TOUT PASSE PAR `as_human`, JAMAIS PAR root. `60-deploy` porte la raison : « un build root
  # polluerait le `_build` du checkout ». Un `mix` en root ici laisserait un `_build` et un `deps`
  # que l'humain ne peut plus écrire, et casserait le module 60 douze crans plus loin — en accusant
  # le module 60.
  local tree; tree="$(repo_root)/fleet"
  p_step "outillage mix pour dériver le roster ($PROV_HUMAN)"
  run_quiet as_human env -C "$tree" mix local.hex --force \
    || { p_fail "hex non installable pour $PROV_HUMAN — le roster ne peut pas se dériver"; verdict_apply; }
  run_quiet as_human env -C "$tree" mix local.rebar --force \
    || { p_fail "rebar non installable pour $PROV_HUMAN — le roster ne peut pas se dériver"; verdict_apply; }
  run_step "dépendances Elixir" -- as_human env -C "$tree" mix deps.get \
    || { p_fail "dépendances Elixir non récupérables ($tree) — sans elles l'arbre ne compile pas"; verdict_apply; }

  # LA RACINE DU CATALOGUE, DEMANDÉE À SON AUTORITÉ — et elle sert DEUX fois : au roster ci-dessous,
  # et au dépôt de référence après la structure.
  #
  # ⚠ `--catalogue` N'EST FACULTATIF QU'AVEC `--image`, et le script le dit : « une image porte le
  # sien ». Avec `--repo` il est REQUIS, et l'omettre échoue net — mesuré à froid le 2026-08-22 :
  # « ERREUR: --catalogue <root> requis ».
  #
  # ⚠ ET IL NE SE RECOMPOSE PAS À LA MAIN. L'image porte la raison mot pour mot : la porte
  # `catalogue-root` « existe pour que personne ne RECOMPOSE ce chemin […] un appelant shell qui le
  # globberait marcherait jusqu'au jour où la disposition du release change ». Même autorité ici —
  # `Fleet.Catalogue.root()` — simplement là où elle tourne.
  # ⚠ `|| true` OBLIGATOIRE, ET SON ABSENCE A TUÉ CE MODULE EN SILENCE. Le module tourne sous
  # `set -euo pipefail` : avec `pipefail`, un `mix` qui échoue fait échouer TOUT le pipeline, donc
  # l'affectation, donc `set -e` abat le shell — AVANT la garde juste en dessous, qui est
  # précisément là pour dire ce qui manque.
  #
  # Mesuré à froid sur .63 le 2026-08-22 : « ERREUR 48-forge-host: MORT avant de rendre son verdict
  # (rc=1) — aucune ligne ci-dessus ne le dit ». Le runner ne pouvait rien dire de plus : le module
  # était mort sans passer par un seul `p_fail`.
  #
  # La règle : une commande dont on VEUT lire l'échec ne doit pas pouvoir tuer le lecteur.
  # ⚠ ON ÉTIQUETTE LA RÉPONSE, ON NE DEVINE PAS QUELLE LIGNE C'EST. `mix` écrit son avancement sur
  # STDOUT — « Compiling 214 files », « Generated lcars_fleet app » — mêlé à ce que le script
  # imprime. Un `tail -n1` prend donc la dernière ligne de BAVARDAGE quand il y en a après, et rien
  # du tout quand la compilation échoue.
  #
  # Mesuré le 2026-08-22, les deux machines, la même ligne : .63 rendait « Generated lcars_fleet
  # app », la WSL rendait le vide. Deux symptômes, une cause — je lisais une position au lieu d'un
  # nom.
  #
  # ⚠ ET LA SORTIE NE SE JETTE PAS. `2>/dev/null` effaçait la seule chose qui aurait nommé la cause
  # du vide. On la garde, et l'échec en cite la fin : un module qui échoue doit dire POURQUOI, pas
  # seulement QUE.
  local ref_catalogue refout
  refout="$(mktemp "${TMPDIR:-/tmp}/prov-catroot.XXXXXX")" \
    || { p_fail "tmp impossible pour la dérivation du catalogue"; verdict_apply; }
  # ⚠ `LCARS_TOOL_EVAL=1` — SANS LUI, GUARD B REFUSE, ET IL A RAISON DE REFUSER.
  # `config/runtime.exs` refuse de démarrer sous le siège sysadmin (uid 1000) : « a fleet under the
  # seat would run sudo-capable pods, the exact inverse of the sandbox ». Or l'opérateur EST l'uid
  # 1000, et `as_human` lance sous lui. Le garde vise le DAEMON ; ici on POSE UNE QUESTION.
  #
  # Le seam est celui du produit, pas un contournement : `runtime.exs:47` le déclare, et la porte
  # `catalogue-root` de l'image l'emploie exactement ainsi — `env HOME=/tmp RELEASE_TMP=/tmp
  # LCARS_TOOL_EVAL=1 … eval 'IO.puts(Fleet.Catalogue.root())'`. J'avais cité cette porte dans un
  # commentaire sans en reprendre la forme.
  as_human env -C "$tree" LCARS_TOOL_EVAL=1 mix run --no-start \
    -e 'IO.puts("LCARS_CATALOGUE_ROOT=" <> Fleet.Catalogue.root())' >"$refout" 2>&1 || true
  ref_catalogue="$(grep -m1 '^LCARS_CATALOGUE_ROOT=' "$refout" | cut -d= -f2- || true)"
  if [[ ! -d "$ref_catalogue" ]]; then
    p_fail "catalogue de référence introuvable dans $tree (rendu : « ${ref_catalogue:-<rien>} »)"
    p_fail "dernières lignes de mix : $(tail -n3 "$refout" | tr '\n' '·')"
    rm -f "$refout"; verdict_apply
  fi
  rm -f "$refout"

  # Le dossier de sortie appartient à l'humain : c'est lui qui joue la dérivation.
  local enroll; enroll="$(mktemp -d "${TMPDIR:-/tmp}/prov-enroll.XXXXXX")"
  chown "$PROV_HUMAN" "$enroll" \
    || { p_fail "dossier de roster non cédé à $PROV_HUMAN ($enroll)"; rm -rf "$enroll"; verdict_apply; }
  # `LCARS_TOOL_EVAL=1` ici AUSSI : le script joue `mix lcars.catalogue.roles`, qui évalue la même
  # config runtime et se ferait refuser par le même garde. Mesuré sur .63 : sans le seam, la tâche
  # meurt ; avec, elle rend son JSON.
  run_step "roster du catalogue" -- as_human env LCARS_TOOL_EVAL=1 "$tree/etc/enroll-catalogue.sh" --tofu-dir "$enroll" --repo "$tree" --catalogue "$ref_catalogue" \
    || { p_fail "roster non dérivable de l'arbre ($tree) — relis la sortie, elle nomme l'étape"; rm -rf "$enroll"; verdict_apply; }
  [[ -s "$enroll/roles.auto.tfvars.json" ]] \
    || { p_fail "roster vide — la recette serait appliquée sans comptes"; rm -rf "$enroll"; verdict_apply; }
  # 5. LA STRUCTURE, jouée DIRECTEMENT — plus de conteneur, plus d'image.
  #
  # ⚖ USER 2026-08-22 : « tu build une image complète de 1,2 Go juste pour exécuter 100 ko de recette
  # tofu ? » puis « pourquoi tofu ne peut pas tourner directement ? »
  #
  # CE BLOC MONTAIT UN CONTENEUR TRANSITOIRE, et le commentaire qui l'expliquait décrivait un
  # problème RÉEL — « aucun bind d'un chemin de l'hôte : le daemon peut vivre ailleurs, sous Docker
  # Desktop il est dans une autre VM, et un chemin d'hôte lui est alors INVISIBLE ; il crée un
  # répertoire vide à sa place, EN SILENCE » (mesuré le 2026-08-18). D'où le volume nommé, les trois
  # `docker cp`, et l'image de 1,18 Go bâtie sur un rail qui ne la démarre jamais.
  #
  # ⚠ CE PROBLÈME N'EXISTAIT QUE PARCE QU'ON AVAIT CHOISI LE CONTENEUR. Un contournement était devenu
  # sa propre justification : on tourne en conteneur → le daemon peut être ailleurs → il faut un
  # volume et des `docker cp` → c'est compliqué → « on ne peut pas faire autrement ». Sur la machine,
  # les fichiers d'autorité sont déjà là, et il n'y a rien à traverser.
  #
  # Le script, lui, n'a JAMAIS eu d'hypothèse de conteneur : `PRIVATE_DIR` défaute sur
  # `/home/private`, `CATALOGUE_WORK` sur `/var/lib/lcars/tofu` — deux chemins d'hôte. C'est
  # l'appelant qui le forçait dans un `docker create`.
  #
  # CE QUI EST GARDÉ : l'hermétisme, par `46-tofu` — version épinglée et providers en miroir
  # hors-ligne. Le conteneur n'en était qu'un porteur possible, pas la source.
  p_step "forge du poste : pose de la structure (orgs, comptes de rôle, teams, dépôt modèle)"

  # LA RECETTE SE JOUE SUR UNE COPIE, JAMAIS DANS LE CHECKOUT. Le conteneur recevait le roster par
  # `docker cp` DANS sa recette ; ici on assemble le même couple (recette + roster) dans un dossier
  # jetable. Écrire `roles.auto.tfvars.json` dans l'arbre de l'opérateur salirait son clone avec un
  # fichier généré.
  local recipe; recipe="$(mktemp -d "${TMPDIR:-/tmp}/prov-recipe.XXXXXX")"
  cp -a "$(repo_root)/fleet/deploy/deps/." "$recipe/" \
    || { p_fail "recette non copiable ($(repo_root)/fleet/deploy/deps)"; rm -rf "$recipe" "$enroll"; verdict_apply; }
  cp "$enroll/roles.auto.tfvars.json" "$recipe/roles.auto.tfvars.json" \
    || { p_fail "roster non déposé dans la recette"; rm -rf "$recipe" "$enroll"; verdict_apply; }

  # ⚠ ET LE `.terraform/` DE L'ARBRE NE VIENT PAS AVEC. `46-tofu` en laisse un dans le dépôt — c'est
  # son témoin de miroir complet, et il est gitignoré — mais il décrit un répertoire À SON CHEMIN.
  # Le recopier ailleurs, c'est hériter d'un état dont on ne sait pas ce qu'il pointe. On repart
  # d'une init propre : hors-ligne, elle coûte une seconde.
  #
  # ⚠ ET IL FAUT L'INIT : `forge-gestures.sh apply` appelle `tofu apply` NU, sans init préalable —
  # dans l'image, le Dockerfile l'avait joué AU BUILD (« LE TEMOIN DU LOT est le `tofu init` en fin
  # de RUN »). En sortant du conteneur, on hérite de cette dette : sans ce geste, l'apply échoue sur
  # des providers non installés. Le geste n'est pas modifié — la boîte marche, et un init ajouté
  # là-bas irait sur le réseau si sa tofurc ne suivait pas.
  rm -rf "$recipe/.terraform" "$recipe/instance/.terraform"
  local m
  for m in instance .; do
    TF_CLI_CONFIG_FILE="${LCARS_TOFU_DIR:-/opt/lcars/tofu}/tofurc" \
      run_quiet env -C "$recipe/$m" tofu init -input=false -no-color \
      || { p_fail "recette non initialisable ($m) — le miroir de providers couvre-t-il cette recette ? (46-tofu)"; rm -rf "$recipe" "$enroll"; verdict_apply; }
  done

  # LES DEUX DÉPÔTS DE CATALOGUE, ET LEURS CHEMINS ÉTAIENT CEUX DE L'IMAGE.
  #
  # ⚠ RÉGRESSION SILENCIEUSE TROUVÉE EN REVUE (2026-08-22). `forge-gestures.sh` publie deux dépôts
  # après la structure : la DÉMO (`web-demo`) et le catalogue de RÉFÉRENCE, celui qu'on forke. Leurs
  # défauts sont des chemins de conteneur — `/opt/lcars/catalogues/web-demo` et l'entrypoint de
  # l'image pour la référence. Dans le conteneur ils existaient ; sur la machine, non.
  #
  # Et les deux échecs sont NON FATAUX par conception (une forge sans démo reste une forge). En
  # sortant du conteneur sans les recâbler, on obtenait donc une forge structurée mais VIDE des deux
  # dépôts, sans qu'aucun verdict ne baisse. C'est la forme d'échec la plus chère : un succès qui
  # dit vrai sur ce qu'il a fait, et rien sur ce qu'il n'a pas fait.

  local rc=0 tf_out
  tf_out="$(mktemp "${TMPDIR:-/tmp}/prov-tofu.XXXXXX")"
  run_step "structure de la forge" -- env \
    LCARS_PRIVATE_DIR="$PROV_TOKENS_DIR" \
    `# ⚠ LE DÉTENTEUR VOYAGE AVEC LE CHEMIN, ET LES SÉPARER LES FAIT DIVERGER. « put_secret » pose` \
    `# désormais un PROPRIÉTAIRE sur ce qu'il écrit ; sans cette ligne il retomberait sur son défaut` \
    `# compilé pendant que ce module, lui, suivrait PROV_AUTHORITY_USER. Sur une boîte dont le compte` \
    `# de service porte un autre nom, le secret naîtrait détenu par un compte qui n'existe pas — et` \
    `# le service refuserait de démarrer sur un fichier que la boîte vient d'écrire.` \
    LCARS_AUTHORITY_USER="$PROV_AUTHORITY_USER" \
    FORGE_BASE_URL="$LOCAL_URL" \
    LCARS_RECIPE_DIR="$recipe" \
    LCARS_DEMO_CATALOGUE="$(repo_root)/catalogues/web-demo" \
    LCARS_REFERENCE_CATALOGUE="$ref_catalogue" \
    TF_CLI_CONFIG_FILE="${LCARS_TOFU_DIR:-/opt/lcars/tofu}/tofurc" \
    `# ⚠ L'HUMAIN INTÉGRÉ N'EST PAS L'OPÉRATEUR, ET CETTE LIGNE LES CONFONDAIT.` \
    `# La recette le dit d'elle-même : « CE COMPTE N'EST PAS UNE PERSONNE : il tient le siège du` \
    `# compte que l'admin d'une forge crée à son installation […] Un déploiement réel ne "passe` \
    `# pas le sien" — les vraies personnes s'inscrivent seules et un admin les ajoute à humans ».` \
    `# Les deux autres rails le savent : forge-gestures.sh défaute sur "lcars", bench-forge-` \
    `# bootstrap passe l'humain de banc. Le rail poste était le seul à y mettre SUDO_USER.` \
    `#` \
    `# Ce que ça coûtait n'a été visible qu'à froid, et seulement depuis D7. La recette pose` \
    `# admin = false sur ce compte ; tant que le #1 de la forge était "admiral", l'opérateur` \
    `# était le #2 et personne ne s'en apercevait. Devenu #1 et admin, il est le DERNIER admin —` \
    `# et Gitea refuse net : « can not delete the last admin user [uid: 1] ». Structure NON posée,` \
    `# donc pas de jetons de rôle, donc pas d'OIDC ni de branche ops. Quatre modules pour une` \
    `# ligne qui visait le mauvais humain depuis le début.` \
    `#` \
    `# VIDE EST UNE RÉPONSE : sans humain de fleet nommé, on ne passe rien et forge-gestures.sh` \
    `# applique SON défaut. Un littéral "lcars" ici en ferait un second, et deux défauts pour un` \
    `# fait ne restent d'accord que tant que personne n'en touche un.` \
    LCARS_BUILTIN_HUMAN="${PROV_FLEET_HUMAN:-}" \
    bash "$(repo_root)/fleet/services/forge-gestures.sh" apply 2>&1 | tee "$tf_out" || rc="${PIPESTATUS[0]}"
  rm -rf "$recipe" "$enroll"
  [[ "$rc" -eq 0 ]] \
    || { rm -f "$tf_out"; p_fail "structure NON posée (rc=$rc) — relis la sortie, rien n'est supposé"; verdict_apply; }

  # ⚠ « APPLIQUÉ » N'EST PAS « CHANGÉ », ET LE CODE DE SORTIE NE LES DISTINGUE PAS. La recette est
  # idempotente : elle rend 0 aussi bien après avoir tout posé qu'après n'avoir rien eu à faire.
  # Compter un changement à chaque passage rendrait ce module non-idempotent AU BILAN — une
  # convergence stable annoncerait une mutation à chaque tour, et le compteur cesserait de
  # distinguer « on a agi » de « on a regardé ».
  #
  # `tofu` le DIT, et c'est la seule source qui le sache : « Apply complete! Resources: N added,
  # M changed, K destroyed », une ligne par module de la recette. Illisible (format changé, sortie
  # tronquée) → on n'invente pas : on ne compte rien et on le nomme.
  local moved
  moved="$(grep -c -E 'Apply complete!.*Resources: [1-9][0-9]* (added|changed|destroyed)|, [1-9][0-9]* (changed|destroyed)' "$tf_out" 2>/dev/null || true)"
  rm -f "$tf_out"
  if [[ "${moved:-0}" -gt 0 ]]; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "structure de la forge posée — 50-forge peut minter les jetons de rôle"
  else
    p_ok "structure de la forge déjà conforme — rien à poser"
  fi

  announce_builtin_human_password
  converge_ci_runner
  seat_binding_report apply
  verdict_apply
}

case "${1:?usage: 48-forge-host.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
