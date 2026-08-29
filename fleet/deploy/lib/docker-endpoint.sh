#!/usr/bin/env bash
# SC2034 AU NIVEAU DU FICHIER, ET C'EST LE CONTRAT DE CETTE LIB QUI LE JUSTIFIE. Ses fonctions
# rendent leurs resultats par des GLOBALES que l'APPELANT lit — `docker_endpoint` pose les
# `PROV_DOCKER_*`, `docker_compose_cmd` les `PROV_COMPOSE_*` — et aucune n'est relue ici, donc elles
# sont toutes vues inutilisees. La directive doit preceder TOUTE commande, `set -` compris, sinon
# elle est inerte.
# shellcheck disable=SC2034
# SOURCE: fleet/deploy/lib/docker-endpoint.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-19
# STATUS: PROTO-V2 — la sonde docker, partagee par le rail ET par le script d'entree
#
# POURQUOI CE FICHIER EXISTE SEPAREMENT DE `provision-lib.sh` : la sonde est le premier geste du
# script d'entree a la racine du depot — c'est lui qui doit dire « docker ne repond pas » avant
# qu'on clone ou qu'on construise quoi que ce soit. `provision-lib.sh`, lui, pose des defauts
# d'INSTALLATION au source et lit des fichiers de la machine provisionnee : un script d'entree qui
# les traine ment sur ce qu'il est.
#
# Ce fichier n'a donc AUCUN effet de bord : des fonctions, et les globales qu'elles remplissent. Il
# est sourcable depuis n'importe ou, y compris avant qu'un depot soit clone. `provision-lib.sh` le
# source et n'en garde pas de copie — deux sondes, ce serait deux verdicts selon la porte empruntee.

[[ -n "${LCARS_DOCKER_ENDPOINT_LOADED:-}" ]] && return 0
LCARS_DOCKER_ENDPOINT_LOADED=1

# ─── detect_substrate — ou tourne-t-on ? ─────────────────────────────────────────────────────────
# Ici parce que la sonde en depend pour choisir le libelle de son refus : sur WSL « demarre Docker
# Desktop », sur linux « le service tourne-t-il ».
detect_substrate() {
  if [[ -f /.dockerenv || "${LCARS_DOCKER:-}" == "1" ]]; then echo docker
  elif grep -qi microsoft /proc/version 2>/dev/null; then echo wsl
  else echo linux
  fi
}

# ─── docker_endpoint — LE BINAIRE N'EST PAS LA PORTE D'ENTRÉE ────────────────────────────────────
#
# POSE SES RÉSULTATS EN GLOBALES ET N'IMPRIME RIEN — l'appeler dans `$( )` ne rend donc RIEN :
#   PROV_DOCKER_BIN     la CLI à appeler — c'est AUSSI une entrée, cf. la déclaration plus bas
#   PROV_DOCKER_HOST    l'endpoint retenu, vide s'il vient déjà de l'environnement
#   PROV_DOCKER_WHY     vide si docker répond ; sinon la phrase qui dit ce qui manque
#   PROV_DOCKER_DENIED  1 quand le daemon répond mais REFUSE cet utilisateur
#   PROV_DOCKER_SUDO    le préfixe d'escalade retenu, vide s'il n'en a pas fallu
#   PROV_DOCKER_SOCK    la socket qui a refusé — interne au diagnostic
# Rend 0 si un daemon a répondu, 1 sinon.
#
# ⚠ `command -v docker` SE TROMPE DANS LES DEUX SENS : sa présence n'exclut pas un daemon éteint, et
# son ABSENCE ne prouve rien du tout — sur WSL le daemon vit dans la VM Docker Desktop et s'expose
# par un MONTAGE partagé, CLI comprise, donc une distro sans aucun binaire joint docker. On cherche
# une PAIRE, CLI et endpoint, et la seule preuve est qu'elle réponde.
#
# CE QUE CETTE SONDE NE PROUVE PAS : que les commandes à FLUX ATTACHÉ rendent quelque chose —
# cf. `docker_stream_ok`.
# ⚠ LA FORME `${VAR:-}` EST DELIBEREE, ET `=""` CASSERAIT LA COUTURE D'ENTREE : la fonction lit
# `want="${PROV_DOCKER_BIN:-}"` pour honorer une CLI imposee — un shim, une doublure de test — et
# cette initialisation-ci s'execute AVANT elle.
PROV_DOCKER_BIN="${PROV_DOCKER_BIN:-}"
PROV_DOCKER_HOST=""
PROV_DOCKER_WHY=""
PROV_DOCKER_DENIED=0
PROV_DOCKER_SOCK=""
# LE PREFIXE D'ESCALADE : vide, ou de quoi joindre un daemon dont la socket appartient a root.
#
# POURQUOI IL EXISTE. Sur WSL la socket Docker Desktop est `root:root 755` : le daemon repond, et
# pas a l'utilisateur qui lance. `chgrp` dessus l'ouvrirait a TOUTES les distros de la VM (elle vit
# sous `/mnt/wsl`) et serait a re-poser a chaque demarrage de Docker Desktop, qui la recree. `sudo`
# sur l'APPEL ne modifie RIEN : la promesse auditee du rail boite porte sur ce qu'on MODIFIE, jamais
# sur l'uid qui appelle.
#
# ⚠ L'ESCALADE EST PAR COMMANDE, JAMAIS UN RE-EXEC GLOBAL : celui-ci ferait tourner `git` en root
# sur le clone de l'humain (« dubious ownership ») et estamperait l'image `unknown`.
PROV_DOCKER_SUDO=""

_docker_mount_cli() { echo "/mnt/wsl/docker-desktop/cli-tools/usr/bin/docker"; }
_docker_mount_sock() { echo "/mnt/wsl/docker-desktop/shared-sockets/guest-services/docker.proxy.sock"; }
_docker_mount_plugins() { echo "/mnt/wsl/docker-desktop/cli-tools/usr/local/lib/docker/cli-plugins"; }

# ─── _docker_plugin_config [<dir>] — UN `DOCKER_CONFIG` QUI VOIT LES PLUGINS DU MONTAGE ─────────
#
# Rend le chemin d'un repertoire `DOCKER_CONFIG` dont le `config.json` pointe `cliPluginsExtraDirs`
# vers les plugins de la CLI du montage. Sans lui, `docker compose` N'EXISTE PAS : `compose` est un
# PLUGIN, pas une sous-commande, et la CLI du montage range les siens dans un repertoire qui n'est
# dans aucune liste par defaut — le mot `compose` tombe et `-f` devient un drapeau global
# (« unknown shorthand flag: 'f' »).
#
# ⚠ `DOCKER_CLI_PLUGIN_EXTRA_DIRS` NE SUFFIT PAS : pas honore par cette version de la CLI (mesure).
# Le detour par `DOCKER_CONFIG` + `cliPluginsExtraDirs` n'est pas une complication gratuite, c'est
# la seule voie qui marche.
#
# ⚠ ON PART DE LA CONFIG DE L'HUMAIN QUAND ELLE EXISTE. Elle porte ses credentials de registry
# (`auths`, `credHelpers`, `credsStore`) ; forcer un repertoire vide les rendrait invisibles, et un
# `pull` d'image privee echouerait en accusant le reseau. Le repli qui ecrit un `config.json` reduit
# aux seuls `cliPluginsExtraDirs` EFFACE ces clefs : il ne sert que quand il n'y a rien a preserver.
# python3 est un prerequis DECLARE de ce rail (`10-packages`), jq ne l'est pas.
_docker_plugin_config() {
  local dir="${1:-}" plug src
  plug="$(_docker_mount_plugins)"
  [[ -d "$plug" ]] || return 1
  if [[ -z "$dir" ]]; then
    dir="$(mktemp -d "${TMPDIR:-/tmp}/lcars-dockercfg.XXXXXX")" || return 1
    chmod 0700 "$dir"
  fi
  mkdir -p "$dir"
  src="${HOME:-}/.docker/config.json"
  if [[ -r "$src" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$src" "$plug" > "$dir/config.json" <<'PYCFG' 2>/dev/null || \
      printf '{"cliPluginsExtraDirs":["%s"]}\n' "$plug" > "$dir/config.json"
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
d["cliPluginsExtraDirs"] = [sys.argv[2]]
json.dump(d, sys.stdout)
PYCFG
  else
    printf '{"cliPluginsExtraDirs":["%s"]}\n' "$plug" > "$dir/config.json"
  fi
  chmod 0600 "$dir/config.json"
  printf '%s' "$dir"
}

# ─── LES ADRESSES DU DAEMON, PAR SUBSTRAT — ON NE CHERCHE PAS, ON SAIT ───────────────────────────
#
# AUCUN CHEMIN « AU CAS OU » : une sonde qui fouille finit par porter le cablage de la machine de
# son auteur, et juge toutes les autres a travers lui. L'operateur qui a sa topologie pose
# `DOCKER_HOST`, honore avant tout le reste.
# Sur WSL, `/var/run/docker.sock` ne s'ajoute que si l'integration est activee pour la distro.
#
# COUTURE DE DECOR, MEME IDIOME QUE `LCARS_HOST_CONSENT_FILE` ET `LCARS_SYSADMIN_UID` : les
# chemins sont des litteraux, et `DOCKER_HOST` n'est plus un levier — pointer une socket absente
# fait CONTINUER la resolution. Sans cette couture, « rien ne repond » n'est mesurable que sur une
# machine sans docker, c'est-a-dire nulle part ou ce contrat compte.
_docker_sockets() {
  if [[ -n "${LCARS_DOCKER_SOCKETS:-}" ]]; then
    printf '%s\n' "$LCARS_DOCKER_SOCKETS"
    return 0
  fi
  case "$(detect_substrate)" in
    wsl) printf '%s\n%s\n' /var/run/docker.sock "$(_docker_mount_sock)" ;;
    *)   printf '%s\n' /var/run/docker.sock ;;
  esac
}

docker_endpoint() {
  # `PROV_DOCKER_BIN` est À LA FOIS L'ENTRÉE ET LA SORTIE, et c'est délibéré : un second nom pour
  # « la CLI que l'appelant veut » ferait deux variables pour un objet, et c'est celle qu'on ne lit
  # pas qui gagne. On capture donc la valeur entrante d'abord.
  local want="${PROV_DOCKER_BIN:-}"
  PROV_DOCKER_BIN=""; PROV_DOCKER_HOST=""; PROV_DOCKER_WHY=""; PROV_DOCKER_DENIED=0; PROV_DOCKER_SOCK=""
  PROV_DOCKER_SUDO=""
  local cli sock

  # 1. La CLI.
  #
  # ⚠ SUR WSL, LA CLI DU MONTAGE PASSE AVANT LE PATH : docker est installé côté Windows, ce qu'un
  # PATH offre dans la distro est une copie ou un wrapper, jamais « le » docker — le préférer risque
  # une CLI qui ne correspond pas au daemon. Le PATH ne fait autorité que sur un linux natif.
  local -a candidats
  if [[ "$(detect_substrate)" == "wsl" ]]; then
    candidats=("$want" "$(_docker_mount_cli)" docker)
  else
    candidats=("$want" docker "$(_docker_mount_cli)")
  fi
  # ⚠ UN NOM NU ET UN CHEMIN NE SE TESTENT PAS PAREIL : `[[ -x docker ]]` est VRAI dès que le CWD
  # contient un DOSSIER `docker` — un dossier est exécutable, c'est-à-dire traversable. Un nom nu
  # n'a de sens que par le PATH ; un chemin doit être un fichier.
  for cli in "${candidats[@]}"; do
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

  # LE CHEMIN DES PLUGINS SE POSE ICI, PARCE QU'IL DEPEND DE LA CLI CHOISIE ET DE RIEN D'AUTRE.
  # Accroche au shim d'escalade plus bas, il ne couvrirait que les appelants NON-ROOT : le module
  # qui a besoin de `compose` tourne en root, ou l'escalade n'a pas lieu, et recevrait la CLI du
  # montage toute nue.
  #
  # UN `DOCKER_CONFIG` POSE PAR L'OPERATEUR EST UNE DECISION : on ne l'ecrase pas.
  if [[ "$(detect_substrate)" == "wsl" && "$PROV_DOCKER_BIN" == "$(_docker_mount_cli)" \
        && -z "${DOCKER_CONFIG:-}" ]]; then
    local _pcfg; _pcfg="$(_docker_plugin_config)" && [[ -n "$_pcfg" ]] && export DOCKER_CONFIG="$_pcfg"
  fi

  # 2. L'endpoint.
  #
  # ⚠ UN `DOCKER_HOST` PRESENT N'EST PAS TOUJOURS UNE DECISION : l'integration WSL de Docker Desktop
  # l'INJECTE dans le shell de la distro, et cette socket-la appartient a root. Traiter l'injection
  # comme un choix humain et s'arreter sur son echec refuse des machines saines.
  local _envhost="" _dh=""
  if [[ -n "${DOCKER_HOST:-}" ]]; then
    if "$PROV_DOCKER_BIN" version --format '{{.Server.Version}}' >/dev/null 2>&1; then return 0; fi
    _dh="${DOCKER_HOST#unix://}"
    #
    # Le FAIT rejoint l'enumeration du message final plutot que `PROV_DOCKER_WHY`, qui est
    # contractuellement VIDE quand docker repond : une phrase posee ici serait perimee sur succes,
    # et le message final l'ecraserait sur echec.
    if [[ -S "$_dh" ]]; then
      _envhost=" ${DOCKER_HOST}[env,$([[ -w "$_dh" ]] && echo "accessible" || echo "REFUSE $(id -un)")]"
    else
      _envhost=" ${DOCKER_HOST}[env,rien-a-cette-adresse]"
    fi
    # Sans cet `unset`, chaque essai du balayage re-heriterait la valeur qui vient d'echouer.
    unset DOCKER_HOST
  fi
  # ⚠ « REFUSE » ET « INJOIGNABLE » NE SONT PAS LE MEME FAIT, et les confondre refuse des machines
  # saines : le rail poste escalade en root juste apres et s'en moque, le rail boite tourne sous
  # l'humain et ne peut pas travailler. Un verdict unique serait faux dans un cas sur deux — la
  # sonde rend le FAIT, chaque branche en tire sa conclusion.
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
    [[ -w "$sock" ]] || { PROV_DOCKER_DENIED=1; PROV_DOCKER_SOCK="$sock"; }
  done < <(_docker_sockets)

  if [[ "${PROV_DOCKER_DENIED:-0}" == "1" ]]; then
    # ⚠ `sudo -n` : une sonde ne bloque JAMAIS sur une invite de mot de passe. Sans NOPASSWD, on
    # rend le fait tel quel et l'appelant decide d'escalader lui-meme.
    # ⚠ CHEMIN ABSOLU : `sudo` impose `secure_path`, ou une CLI hors des repertoires systeme — celle
    # du montage Docker Desktop, par exemple — devient introuvable.
    local abs; abs="$(command -v "$PROV_DOCKER_BIN" 2>/dev/null || echo "$PROV_DOCKER_BIN")"
    if [[ "$EUID" -ne 0 ]] && command -v sudo >/dev/null 2>&1 \
       && sudo -n DOCKER_HOST="unix://$PROV_DOCKER_SOCK" "$abs" version --format '{{.Server.Version}}' >/dev/null 2>&1; then
      PROV_DOCKER_HOST="unix://$PROV_DOCKER_SOCK"
      PROV_DOCKER_SUDO="sudo DOCKER_HOST=unix://$PROV_DOCKER_SOCK"
      # L'ESCALADE PREND LA FORME D'UN SHIM, ET C'EST CE QUI PRESERVE TOUS LES CONTRATS : les
      # appelants recoivent un BINAIRE et composent `"$DOCKER_BIN" <verbe>`. Rendre ici une LIGNE DE
      # COMMANDE ferait chercher un executable dont le nom contient des espaces, avec un diagnostic
      # qui accuserait docker. Le shim est un fichier, et tout le rail ne manipule qu'un chemin.
      #
      # 0700 dans un repertoire 0700 : ce fichier invoque sudo, il ne doit etre modifiable par
      # personne d'autre. Il n'est pas nettoye — il ne porte aucun secret, seulement un chemin, et
      # sa duree de vie est celle de l'arbre de processus qui s'en sert.
      local shim_dir; shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/lcars-docker.XXXXXX")" || return 1
      chmod 0700 "$shim_dir"

      # ET LE SHIM PORTE SON PROPRE `DOCKER_CONFIG` — cf. `_docker_plugin_config`. Sous `sudo`,
      # `HOME` devient celui de root : meme les plugins ranges chez l'humain cessent d'etre
      # regardes, et `docker compose` n'existe plus.
      local cfg; cfg="$(_docker_plugin_config "$shim_dir/config")" || cfg="$shim_dir/config"

      # ⚠ `sudo` REMET L'ENVIRONNEMENT A ZERO, et le rail conduit compose PAR DES VARIABLES : un
      # port demande en tete de commande se perd, le compose monte son DEFAUT, et le banc meurt en
      # accusant la forge. `-E` exigerait un `SETENV` que personne n'a pose dans le sudoers.
      #
      # ⚠ JAMAIS UN SECRET : `sudo VAR=valeur` vit dans la LIGNE DE COMMANDE, que
      # `/proc/<pid>/cmdline` expose a tout l'hote pendant l'appel — cicatrice 6-141. Denylist large
      # a dessein : un faux positif coute une variable, un faux negatif un secret. Valeur a saut de
      # ligne SAUTEE — `sudo VAR=val` ne sait pas la representer.
      cat > "$shim_dir/docker" <<'SHIM'
#!/usr/bin/env bash
declare -a keep=()
while IFS= read -r -d '' kv; do
  k="${kv%%=*}"; v="${kv#*=}"
  case "$k" in
    *TOKEN*|*PASSWORD*|*SECRET*|*CREDENTIAL*|*PASSWD*|*_PW|*_KEY|*_AUTH) continue ;;
    LCARS_*|FORGE_*|COMPOSE_*|PROV_*) [[ "$v" == *$'\n'* ]] || keep+=("$k=$v") ;;
  esac
done < <(env -0)
exec sudo "${keep[@]+"${keep[@]}"}" DOCKER_HOST=__SOCK__ DOCKER_CONFIG=__CFG__ __CLI__ "$@"
SHIM
      sed -i "s|__SOCK__|unix://$PROV_DOCKER_SOCK|; s|__CFG__|$cfg|; s|__CLI__|$abs|" "$shim_dir/docker"
      chmod 0700 "$shim_dir/docker"
      PROV_DOCKER_BIN="$shim_dir/docker"

      # ON VERIFIE QUE LA PAIRE EST COMPLETE, PAS SEULEMENT QU'ELLE REPOND. Un shim qui rend
      # `version` et pas `compose` est pire qu'une absence : il passe le preflight et meurt trois
      # etapes plus loin, sur un message qui accuse un fichier compose.
      if ! "$PROV_DOCKER_BIN" compose version >/dev/null 2>&1; then
        PROV_DOCKER_WHY="le daemon repond via sudo, mais « docker compose » reste introuvable (plugins cherches dans $(_docker_mount_plugins))"
        return 1
      fi
      return 0
    fi
    PROV_DOCKER_WHY="le daemon docker REPOND, mais pas a « $(id -un) » : la socket $PROV_DOCKER_SOCK est $(stat -Lc '%U:%G %a' "$PROV_DOCKER_SOCK" 2>/dev/null) · CLI retenue : $abs"
    return 1
  fi

  # 3. Rien ne répond.
  #
  # LE MESSAGE NE DIT PAS « INSTALLE DOCKER » : sur WSL le montage prouverait le contraire, et sur
  # linux natif le paquet n'est pas forcément le geste juste.
  # ET IL PORTE LE CHEMIN RÉSOLU, PAS LE NOM. « CLI trouvée (docker) » ne se diagnostique pas —
  # deux environnements différents rendent le même refus, qu'il faut rejouer pour savoir ce qu'il a
  # vu.
  local resolved tried=""
  resolved="$(command -v "$PROV_DOCKER_BIN" 2>/dev/null || echo "$PROV_DOCKER_BIN")"
  while read -r sock; do
    if [[ -S "$sock" ]]; then tried+=" ${sock}[socket$([[ -w "$sock" ]] && echo ",accessible" || echo ",NON-ACCESSIBLE")]"
    elif [[ -e "$sock" ]]; then tried+=" ${sock}[existe,PAS-UNE-SOCKET]"
    else tried+=" ${sock}[absent]"
    fi
  done < <(_docker_sockets)
  if [[ "$(detect_substrate)" == "wsl" ]]; then
    PROV_DOCKER_WHY="aucun daemon docker joignable. CLI retenue : $resolved · sockets essayées :$_envhost$tried. Sur WSL c'est Docker Desktop qui porte le daemon : démarre-le côté Windows, puis relance"
  else
    PROV_DOCKER_WHY="aucun daemon docker joignable. CLI retenue : $resolved · sockets essayées :$_envhost$tried. Le service tourne-t-il, et suis-je dans le groupe docker ?"
  fi
  return 1
}

# ─── docker_stream_ok <conteneur> — UN ALLER-RETOUR RÉEL, AVANT DE CAPTURER UN `docker exec` ─────
#
# ⚠ Un relais docker peut répondre parfaitement à `version`/`ps` et rendre ZÉRO OCTET, EXIT 0, sur
# toute commande à flux attaché. La capture vide devient alors un fait, et le diagnostic accuse
# l'objet sain — la forge, pas le tuyau.
docker_stream_ok() {
  local ctr="${1:?docker_stream_ok: nom ou id de conteneur requis}" out
  out="$("${PROV_DOCKER_BIN:-docker}" exec "$ctr" printf 'lcars-stream-ok' 2>/dev/null || true)"
  [[ "$out" == "lcars-stream-ok" ]]
}


# ─── docker_compose_cmd — QUEL COMPOSE, DEMANDÉ UNE FOIS ────────────────────────────────────────
#
# Deux formes existent dans la nature — le plugin (`docker compose`) et l'autonome
# (`docker-compose`) — et une install récente n'a que la première. La question se pose donc
# vraiment ; ce qui ne doit pas se poser deux fois, c'est la RÉPONSE.
#
# ELLE SE NOMME AU DÉLÉGUÉ, ELLE NE SE REDÉCOUVRE PAS : chaque porte joue la sonde une fois, puis
# TRANSMET son résultat.
#
# ⚠ LE BINAIRE VIENT DE L'APPELANT, PAS DU PATH. Sur WSL la CLI vit dans le montage Docker Desktop,
# et sur une socket appartenant à root c'est un SHIM qui escalade : interroger `docker` nu ici
# contournerait l'un et l'autre pour échouer plus loin, sur une permission.
PROV_COMPOSE_CMD=""
PROV_COMPOSE_WHY=""
docker_compose_cmd() { # docker_compose_cmd [<binaire docker>] -> 0 et PROV_COMPOSE_CMD, ou 1 et _WHY
  local bin="${1:-${PROV_DOCKER_BIN:-docker}}"
  PROV_COMPOSE_CMD=""
  PROV_COMPOSE_WHY=""
  if "$bin" compose version >/dev/null 2>&1; then
    PROV_COMPOSE_CMD="$bin compose"
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    PROV_COMPOSE_CMD="docker-compose"
    return 0
  fi
  PROV_COMPOSE_WHY="docker répond, mais compose est absent (ni le plugin « docker compose », ni « docker-compose »)"
  return 1
}
