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
#   1. Sa présence ne prouve rien : après un reboot Windows, la CLI est dans le PATH et Docker
#      Desktop est éteint. L'install avançait et mourait plus loin, sur un `compose up` qui accuse
#      autre chose.
#   2. Son ABSENCE ne prouve rien non plus. Mesuré le 2026-08-19 sur ce poste, intégration WSL
#      DÉSACTIVÉE : ni `/usr/bin/docker` ni `/var/run/docker.sock`, et pourtant
#      `/mnt/wsl/docker-desktop/…/docker.proxy.sock` rend « serveur 29.2.1 ». Sur WSL le donné est
#      un MONTAGE — présent pour toute distro, CLI comprise — pas un binaire installé. Une sonde
#      qui refuse sur l'absence du binaire refuse une machine qui a parfaitement docker.
#
# D'où : on cherche une PAIRE qui répond. Et la CLI du montage est en prime plus récente que les
# copies posées à la main (41 Mo/février contre 39 Mo) — la préférer au binaire trouvé dans le PATH
# serait un autre débat, mais la prendre EN DERNIER RECOURS est gratuit et correspond au daemon.
#
# ⚠ CE QUE CETTE SONDE NE PROUVE PAS : que les commandes à FLUX ATTACHÉ (`exec`, `cp`, `run`)
# rendent quelque chose. Un relais qui répond parfaitement à `version` peut rendre ZÉRO OCTET et
# EXIT 0 sur un `exec` — cf. `docker_stream_ok`, qui est la sonde des appelants qui CAPTURENT.
PROV_DOCKER_BIN=""
PROV_DOCKER_HOST=""
PROV_DOCKER_WHY=""
# 1 quand le daemon repond mais refuse CET utilisateur — un fait different de « injoignable ».
PROV_DOCKER_DENIED=0
PROV_DOCKER_SOCK=""

_docker_mount_cli() { echo "/mnt/wsl/docker-desktop/cli-tools/usr/bin/docker"; }
_docker_mount_sock() { echo "/mnt/wsl/docker-desktop/shared-sockets/guest-services/docker.proxy.sock"; }

docker_endpoint() {
  # ⚠ `PROV_DOCKER_BIN` est À LA FOIS L'ENTRÉE ET LA SORTIE, et c'est délibéré : le contrat existait
  # AVANT cette fonction (`48-forge-host.sh` le pose en tête, `: "${PROV_DOCKER_BIN:=docker}"`).
  # Introduire un second nom pour « la CLI que l'appelant veut » aurait fait deux variables pour un
  # objet, et c'est celle qu'on ne lit pas qui gagne. On capture donc la valeur entrante d'abord.
  local want="${PROV_DOCKER_BIN:-}"
  PROV_DOCKER_BIN=""; PROV_DOCKER_HOST=""; PROV_DOCKER_WHY=""; PROV_DOCKER_DENIED=0; PROV_DOCKER_SOCK=""
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
  # saines. Mesure du 2026-08-19 sur une WSL neuve : la socket du montage est `755 root:root`, donc
  # le daemon REPOND — mais pas a cet utilisateur-la. Le rail poste escalade en root juste apres et
  # s'en moque ; le rail boite, lui, tourne sous l'humain et ne peut pas travailler. Un seul verdict
  # pour les deux serait faux dans un cas sur deux, donc la sonde REND la distinction et laisse
  # l'appelant en tirer sa conclusion.
  local out
  for sock in /var/run/docker.sock /run/docker-fleet.sock "$(_docker_mount_sock)"; do
    [[ -S "$sock" ]] || continue
    out="$(DOCKER_HOST="unix://$sock" "$PROV_DOCKER_BIN" version --format '{{.Server.Version}}' 2>&1)" && {
      PROV_DOCKER_HOST="unix://$sock"
      export DOCKER_HOST="$PROV_DOCKER_HOST"
      return 0
    }
    case "$out" in
      *"permission denied"*|*"Permission denied"*)
        PROV_DOCKER_DENIED=1
        PROV_DOCKER_SOCK="$sock" ;;
    esac
  done

  if [[ "${PROV_DOCKER_DENIED:-0}" == "1" ]]; then
    PROV_DOCKER_WHY="le daemon docker REPOND, mais pas a « $(id -un) » : la socket $PROV_DOCKER_SOCK ne lui est pas ouverte ($(stat -Lc '%U:%G %a' "$PROV_DOCKER_SOCK" 2>/dev/null))"
    return 1
  fi

  # 3. Rien ne répond. LE MESSAGE NE DIT PAS « INSTALLE DOCKER » — sur WSL le montage prouverait le
  #    contraire, et sur linux natif le paquet n'est pas forcément le geste juste. Il dit ce qui a
  #    été essayé et ce que ça signifie.
  if [[ "$(detect_substrate)" == "wsl" ]]; then
    PROV_DOCKER_WHY="aucun daemon docker joignable — CLI trouvée ($PROV_DOCKER_BIN) mais aucune socket ne répond. Sur WSL c'est Docker Desktop qui le porte : démarre-le côté Windows, puis relance"
  else
    PROV_DOCKER_WHY="aucun daemon docker joignable — CLI trouvée ($PROV_DOCKER_BIN) mais aucune socket ne répond (/var/run/docker.sock). Le service tourne-t-il, et suis-je dans le groupe docker ?"
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

