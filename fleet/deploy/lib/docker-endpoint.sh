#!/usr/bin/env bash
# SOURCE: fleet/deploy/lib/docker-endpoint.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-19
# STATUS: PROTO-V2 — la sonde docker, partagee par le rail ET par le script d'entree
#
# POURQUOI CE FICHIER EXISTE SEPAREMENT DE `provision-lib.sh`. La sonde est le premier geste du
# script d'entree a la racine du depot — c'est lui qui doit dire « docker ne repond pas » avant
# qu'on clone ou qu'on construise quoi que ce soit. Or `provision-lib.sh` pose ~40 defauts au
# source (chemins d'install, groupe fleet, org de la forge) et LIT `/home/private/forge.url` : rien
# de tout ca n'a de sens cote hote, et un script d'entree qui les traine ment sur ce qu'il est.
#
# Ce fichier n'a AUCUN effet de bord : des fonctions, et trois variables qu'elles remplissent. Il
# est sourcable depuis n'importe ou, y compris avant qu'un depot soit clone.
#
# `provision-lib.sh` le source ; il n'en garde pas de copie. Une sonde en deux exemplaires, c'est
# la garantie que la machine sera jugee par deux regards differents selon la porte empruntee.

[[ -n "${LCARS_DOCKER_ENDPOINT_LOADED:-}" ]] && return 0
LCARS_DOCKER_ENDPOINT_LOADED=1

# ─── detect_substrate — ou tourne-t-on ? ─────────────────────────────────────────────────────────
# Ici et pas dans provision-lib parce que la sonde en depend pour choisir le libelle de son refus
# (sur WSL, « demarre Docker Desktop » ; sur linux, « le service tourne-t-il »). Cinq lignes, aucune
# dependance : la deplacer coute moins qu'un second exemplaire.
detect_substrate() {
  if [[ -f /.dockerenv || "${LCARS_DOCKER:-}" == "1" ]]; then echo docker
  elif grep -qi microsoft /proc/version 2>/dev/null; then echo wsl
  else echo linux
  fi
}

# ─── docker_endpoint — LE BINAIRE N'EST PAS LA PORTE D'ENTRÉE ────────────────────────────────────
#
# POSE TROIS GLOBALES, N'IMPRIME RIEN (même piège de sous-shell qu'`advertise_addr`) :
#   PROV_DOCKER_BIN    la CLI à appeler
#   PROV_DOCKER_HOST   l'endpoint retenu, vide s'il vient déjà de l'environnement
#   PROV_DOCKER_WHY    vide si docker répond ; sinon la phrase qui dit ce qui manque
# Rend 0 si un daemon a répondu, 1 sinon.
#
# ⚠ `command -v docker` SE TROMPE DANS LES DEUX SENS, ET LA SECONDE ERREUR EST LA PLUS COÛTEUSE.
#
#   1. Sa présence ne prouve rien : le binaire peut être là et le daemon éteint.
#   2. Son ABSENCE ne prouve rien non plus. Sur WSL, le daemon vit dans la VM Docker Desktop et
#      s'expose par un MONTAGE partagé par toutes les distros — CLI comprise. Une distro peut donc
#      n'avoir aucun binaire installé et joindre docker parfaitement.
#
# MESURE, SUR UNE INSTANCE VIERGE (Ubuntu 26.04 neuve, aucun geste manuel — c'est la seule mesure
# qui vaille : un poste de travail porte des annees de cablage a la main et ne dit rien du cas
# general) : aucun `docker` dans le PATH, pas de `/var/run/docker.sock`, et le daemon repond a
# travers la socket du montage. Une sonde qui refuse sur l'absence du binaire refuse cette
# machine-la, qui a pourtant docker.
#
# D'ou : on cherche une PAIRE — une CLI et un endpoint — et la seule preuve est qu'elle reponde.
#
# ⚠ CE QUE CETTE SONDE NE PROUVE PAS : que les commandes à FLUX ATTACHÉ (`exec`, `cp`, `run`)
# rendent quelque chose. Un relais peut répondre parfaitement à `version` et rendre ZÉRO OCTET avec
# EXIT 0 sur un `exec` — cf. `docker_stream_ok`, la sonde des appelants qui CAPTURENT.
PROV_DOCKER_BIN=""
PROV_DOCKER_HOST=""
PROV_DOCKER_WHY=""
# 1 quand le daemon repond mais refuse CET utilisateur — un fait different de « injoignable ».
PROV_DOCKER_DENIED=0
PROV_DOCKER_SOCK=""
# LE PREFIXE D'ESCALADE : vide, ou de quoi joindre un daemon dont la socket appartient a root.
#
# ⚠ POURQUOI IL EXISTE, ET POURQUOI CE N'EST PAS UNE REGRESSION DE LA PROMESSE. Sur WSL la socket
# Docker Desktop est `root:root 755` : le daemon repond, et pas a l'utilisateur qui lance. Deux
# sorties etaient possibles, et la moins invasive n'est pas celle qu'on croit :
#
#   - `chgrp` sur la socket : elle vit sous `/mnt/wsl`, PARTAGE PAR TOUTES LES DISTROS de la VM. Le
#     geste ouvre donc la socket bien au-dela de l'instance dediee — et il faut le re-poser a chaque
#     demarrage de Docker Desktop, qui recree la socket. Deux defauts pour un confort ;
#   - `sudo` sur l'APPEL : ne modifie RIEN, n'a rien a converger, et laisse intacte la promesse
#     auditee du rail boite — « rien hors de ton clone et de docker ».
#
# ⚖ USER : « si l'installeur promet "jamais sudo" et ne peut pas faire son job parce qu'il faut
# sudo, la seule conclusion logique c'est que l'installeur a besoin de sudo. » La promesse porte sur
# ce qu'on MODIFIE, jamais sur l'uid qui appelle — les confondre a fait epingler le mauvais
# invariant par un temoin, et surtout a fait poser le sudo A LA MAIN, en dehors du code, pendant que
# celui-ci pretendait ne pas en avoir besoin.
#
# ⚠ TROIS PIEGES, TOUS DEJA PAYES ICI. (1) `sudo` remet l'environnement a zero : `DOCKER_HOST` meurt
# en traversant, d'ou les assignations EN TETE de commande — jamais `sudo -E`, refuse sans `SETENV`.
# (2) `sudo` impose `secure_path` : une CLI hors des chemins systeme devient introuvable, d'ou le
# chemin ABSOLU. (3) L'escalade est PAR COMMANDE : un re-exec global ferait tourner `git` en root sur
# le clone de l'humain (« dubious ownership ») et estamperait l'image `unknown`.
PROV_DOCKER_SUDO=""

_docker_mount_cli() { echo "/mnt/wsl/docker-desktop/cli-tools/usr/bin/docker"; }
_docker_mount_sock() { echo "/mnt/wsl/docker-desktop/shared-sockets/guest-services/docker.proxy.sock"; }

# ─── LES ADRESSES DU DAEMON, PAR SUBSTRAT — ON NE CHERCHE PAS, ON SAIT ───────────────────────────
#
# ⚠ LA REGLE : l'adresse du daemon est FIXE pour un substrat donne. Sur WSL, Docker Desktop expose
# toujours sa socket au meme endroit du montage partage, et `/var/run/docker.sock` s'y ajoute quand
# l'integration est activee pour la distro. Sur linux, `/var/run/docker.sock`. Ce sont des chemins
# CONNUS, pas des trouvailles.
#
# Une sonde qui PARCOURT des chemins « au cas ou » finit toujours par y mettre ceux de la machine
# de son auteur — et fait alors juger toutes les autres a travers son cablage particulier. Si un
# operateur a une topologie a lui, il pose `DOCKER_HOST` : c'est une DECISION, honoree avant tout
# le reste. Ce n'est pas a la sonde de la deviner en fouillant.
_docker_sockets() {
  case "$(detect_substrate)" in
    wsl) printf '%s\n%s\n' /var/run/docker.sock "$(_docker_mount_sock)" ;;
    *)   printf '%s\n' /var/run/docker.sock ;;
  esac
}

docker_endpoint() {
  # ⚠ `PROV_DOCKER_BIN` est À LA FOIS L'ENTRÉE ET LA SORTIE, et c'est délibéré : le contrat existait
  # AVANT cette fonction (`48-forge-host.sh` le pose en tête, `: "${PROV_DOCKER_BIN:=docker}"`).
  # Introduire un second nom pour « la CLI que l'appelant veut » aurait fait deux variables pour un
  # objet, et c'est celle qu'on ne lit pas qui gagne. On capture donc la valeur entrante d'abord.
  local want="${PROV_DOCKER_BIN:-}"
  PROV_DOCKER_BIN=""; PROV_DOCKER_HOST=""; PROV_DOCKER_WHY=""; PROV_DOCKER_DENIED=0; PROV_DOCKER_SOCK=""
  PROV_DOCKER_SUDO=""
  local cli sock

  # 1. La CLI. Le choix de l'appelant l'emporte — c'est son droit, et il peut viser un shim.
  #
  # ⚠ UN NOM NU ET UN CHEMIN NE SE TESTENT PAS PAREIL, ET LA FORME NAÏVE RETIENT UN RÉPERTOIRE.
  # `[[ -x docker ]]` est VRAI dès que le CWD contient un dossier `docker` — un dossier est
  # exécutable, c'est-à-dire traversable. Mesuré ici même : lancée depuis `fleet/deploy/`, la sonde
  # retenait le RÉPERTOIRE `fleet/deploy/docker` comme CLI et annonçait « CLI trouvée » avec un
  # PATH vide. Un nom nu n'a de sens QUE par le PATH ; un chemin doit être un fichier.
  for cli in "$want" docker "$(_docker_mount_cli)"; do
    [[ -n "$cli" ]] || continue
    if [[ "$cli" == */* ]]; then
      [[ -f "$cli" && -x "$cli" ]] && { PROV_DOCKER_BIN="$cli"; break; }
    else
      command -v "$cli" >/dev/null 2>&1 && { PROV_DOCKER_BIN="$cli"; break; }
    fi
  done
  if [[ -z "$PROV_DOCKER_BIN" ]]; then
    PROV_DOCKER_WHY="aucune CLI docker : ni dans le PATH, ni dans le montage Docker Desktop ($(_docker_mount_cli))"
    return 1
  fi

  # 2. L'endpoint. Un DOCKER_HOST posé par l'opérateur est une DÉCISION : on ne la contourne pas,
  #    on la sonde telle quelle. Sinon on essaie les sockets connues, dans l'ordre du plus standard
  #    au plus spécifique à ce substrat.
  if [[ -n "${DOCKER_HOST:-}" ]]; then
    if "$PROV_DOCKER_BIN" version --format '{{.Server.Version}}' >/dev/null 2>&1; then return 0; fi
    PROV_DOCKER_WHY="DOCKER_HOST=$DOCKER_HOST est posé et aucun daemon ne répond dessus"
    return 1
  fi
  # ⚠ « REFUSE » ET « INJOIGNABLE » NE SONT PAS LE MEME FAIT, et les confondre refuse des machines
  # saines. Sur une instance vierge, la socket du montage est `root:root 755` : le daemon REPOND, et
  # pas a l'utilisateur qui lance. Le rail poste escalade en root juste apres et s'en moque ; le
  # rail boite tourne sous l'humain et ne peut pas travailler. Un verdict unique serait faux dans un
  # cas sur deux — la sonde rend donc le FAIT, chaque branche en tire sa conclusion.
  #
  # ⚠ ET ON LIT LE DROIT SUR LA SOCKET, JAMAIS UN MESSAGE. Un libelle d'erreur est une convention de
  # version, et le code de sortie ne discrimine pas : `docker version` rend 1 aussi bien sur une
  # socket qui refuse que sur un daemon absent (mesure du 2026-08-19). `-w` repond a la question
  # exacte — « puis-je m'en servir » — sans dependre de qui la formule.
  while read -r sock; do
    [[ -S "$sock" ]] || continue
    if DOCKER_HOST="unix://$sock" "$PROV_DOCKER_BIN" version --format '{{.Server.Version}}' >/dev/null 2>&1; then
      PROV_DOCKER_HOST="unix://$sock"
      export DOCKER_HOST="$PROV_DOCKER_HOST"
      return 0
    fi
    # Elle existe et je ne peux pas ecrire dedans : le daemon est la, la porte ne m'est pas ouverte.
    [[ -w "$sock" ]] || { PROV_DOCKER_DENIED=1; PROV_DOCKER_SOCK="$sock"; }
  done < <(_docker_sockets)

  if [[ "${PROV_DOCKER_DENIED:-0}" == "1" ]]; then
    # LA SOCKET REFUSE CET UTILISATEUR — on tente l'escalade AVANT de conclure. Elle ne modifie rien
    # (cf. l'en-tete de PROV_DOCKER_SUDO) et c'est le seul chemin vers un daemon dont la socket
    # appartient a root. `sudo -n` : on ne bloque JAMAIS sur une invite de mot de passe dans une
    # sonde — sans NOPASSWD, on rend le fait tel quel et l'appelant decide d'escalader lui-meme.
    local abs; abs="$(command -v "$PROV_DOCKER_BIN" 2>/dev/null || echo "$PROV_DOCKER_BIN")"
    if [[ "$EUID" -ne 0 ]] && command -v sudo >/dev/null 2>&1 \
       && sudo -n DOCKER_HOST="unix://$PROV_DOCKER_SOCK" "$abs" version --format '{{.Server.Version}}' >/dev/null 2>&1; then
      PROV_DOCKER_HOST="unix://$PROV_DOCKER_SOCK"
      PROV_DOCKER_SUDO="sudo DOCKER_HOST=unix://$PROV_DOCKER_SOCK"
      # ⚠ L'ESCALADE PREND LA FORME D'UN SHIM, ET C'EST CE QUI PRESERVE TOUS LES CONTRATS. Les
      # appelants recoivent un BINAIRE — `store_ensure_volumes` le documente en toutes lettres, et
      # `bench-up`/`48-forge-host` composent `"$DOCKER_BIN" <verbe>`. Rendre ici une LIGNE DE
      # COMMANDE ferait chercher un executable dont le nom contient des espaces, avec un diagnostic
      # qui accuserait docker. Le shim est donc un fichier, et tout le rail continue de ne
      # manipuler qu'un chemin.
      #
      # Il porte `DOCKER_HOST` EN TETE DE COMMANDE parce que `sudo` remet l'environnement a zero :
      # exporter la variable ne la ferait pas traverser. C'est le piege paye cinq fois aujourd'hui.
      #
      # 0700 dans un repertoire 0700 : ce fichier invoque sudo, il ne doit etre modifiable par
      # personne d'autre. Il n'est pas nettoye — il ne porte aucun secret, seulement un chemin, et
      # sa duree de vie est celle de l'arbre de processus qui s'en sert.
      local shim_dir; shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/lcars-docker.XXXXXX")" || return 1
      chmod 0700 "$shim_dir"
      printf '#!/usr/bin/env bash\nexec sudo DOCKER_HOST=%s %s "$@"\n' \
        "unix://$PROV_DOCKER_SOCK" "$abs" > "$shim_dir/docker"
      chmod 0700 "$shim_dir/docker"
      PROV_DOCKER_BIN="$shim_dir/docker"
      return 0
    fi
    PROV_DOCKER_WHY="le daemon docker REPOND, mais pas a « $(id -un) » : la socket $PROV_DOCKER_SOCK est $(stat -Lc '%U:%G %a' "$PROV_DOCKER_SOCK" 2>/dev/null) · CLI retenue : $abs"
    return 1
  fi

  # 3. Rien ne répond. LE MESSAGE NE DIT PAS « INSTALLE DOCKER » — sur WSL le montage prouverait le
  #    contraire, et sur linux natif le paquet n'est pas forcément le geste juste. Il dit ce qui a
  #    été essayé et ce que ça signifie.
  #
  # ⚠ ET IL DIT LE CHEMIN RÉSOLU, PAS LE NOM. « CLI trouvée (docker) » est un message qui ne se
  # diagnostique pas : il ne dit ni QUEL fichier a été retenu, ni quelles sockets ont été essayées.
  # Mesuré le 2026-08-19 : un run d'opérateur a rendu exactement ça sur une machine où, depuis une
  # autre session, aucun `docker` n'était trouvable — et rien dans la sortie ne permettait de savoir
  # lequel des deux environnements mentait. Un refus qui ne porte pas ses propres mesures oblige à
  # rejouer pour savoir ce qu'il a vu.
  local resolved tried=""
  resolved="$(command -v "$PROV_DOCKER_BIN" 2>/dev/null || echo "$PROV_DOCKER_BIN")"
  while read -r sock; do
    if [[ -S "$sock" ]]; then tried+=" ${sock}[socket$([[ -w "$sock" ]] && echo ",accessible" || echo ",NON-ACCESSIBLE")]"
    elif [[ -e "$sock" ]]; then tried+=" ${sock}[existe,PAS-UNE-SOCKET]"
    else tried+=" ${sock}[absent]"
    fi
  done < <(_docker_sockets)
  if [[ "$(detect_substrate)" == "wsl" ]]; then
    PROV_DOCKER_WHY="aucun daemon docker joignable. CLI retenue : $resolved · sockets essayées :$tried. Sur WSL c'est Docker Desktop qui porte le daemon : démarre-le côté Windows, puis relance"
  else
    PROV_DOCKER_WHY="aucun daemon docker joignable. CLI retenue : $resolved · sockets essayées :$tried. Le service tourne-t-il, et suis-je dans le groupe docker ?"
  fi
  return 1
}

# ─── docker_stream_ok <conteneur> — LA SONDE DES APPELANTS QUI CAPTURENT ──────────────────────────
#
# ⚠ UN INSTRUMENT QUI RÉPOND À MOITIÉ EST PIRE QU'UN INSTRUMENT ABSENT. Un relais docker peut
# répondre parfaitement aux commandes qui LISENT (`version`, `ps`, `inspect`) et rendre ZÉRO OCTET,
# EXIT 0, sur toute commande à flux attaché — `exec`, `cp`, `run`, `attach`. Le code prend alors une
# chaîne VIDE pour un fait, et le diagnostic qui en sort accuse l'objet sain : « la forge n'a rendu
# aucun jeton master », alors que la forge allait bien et que c'est le tuyau qui était muet.
#
# Tout appelant qui fait `x="$(docker exec …)"` doit passer par ici D'ABORD. La sonde est un
# aller-retour RÉEL sur un conteneur vivant — jamais une supposition sur la topologie.
docker_stream_ok() {
  local ctr="${1:?docker_stream_ok: nom ou id de conteneur requis}" out
  out="$("${PROV_DOCKER_BIN:-docker}" exec "$ctr" printf 'lcars-stream-ok' 2>/dev/null || true)"
  [[ "$out" == "lcars-stream-ok" ]]
}

