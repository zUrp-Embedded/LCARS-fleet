#!/usr/bin/env bash
# les réponses sortent par des globales PROV_* que l'appelant lit : shellcheck les voit inutilisées
# shellcheck disable=SC2034
# SOURCE: deploy/lib/docker-endpoint.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: le substrat (docker, wsl, linux) et le daemon docker — une CLI, le DOCKER_HOST de l'environnement s'il répond, sinon la socket système, un verdict qui nomme le geste
#
# Sourcée par provision-lib.sh. Rend ses réponses par PROV_DOCKER_* ; docker_endpoint exporte
# DOCKER_HOST quand un daemon répond. Les chemins système se lisent sous LCARS_DECOR_ROOT.

detect_substrate() { # detect_substrate → docker | wsl | linux
  local r="${LCARS_DECOR_ROOT:-}"
  if [[ -f "$r/.dockerenv" || "${LCARS_DOCKER:-}" == "1" ]]; then echo docker
  elif grep -qi microsoft "$r/proc/version" 2>/dev/null; then echo wsl
  else echo linux
  fi
}

PROV_DOCKER_BIN="${PROV_DOCKER_BIN:-}"
PROV_DOCKER_HOST=""
PROV_DOCKER_WHY=""
PROV_DOCKER_DENIED=0
PROV_DOCKER_ECARTE=""

docker_denied_geste() { # docker_denied_geste <socket> → le geste qui rend l'accès, selon que la session porte déjà le groupe ou non
  local sock="$1" grp me
  grp="$(stat -Lc '%G' "$sock" 2>/dev/null)"
  me="$(id -un)"
  [[ -n "$grp" ]] || { echo "socket illisible — son propriétaire n'est pas lisible"; return 0; }
  if [[ " $(id -nG 2>/dev/null) " == *" $grp "* ]]; then
    echo "la session est dans « $grp » et l'accès est refusé quand même — la socket porte-t-elle le bit d'écriture pour son groupe ?"
  elif [[ ",$(getent group "$grp" 2>/dev/null | cut -d: -f4)," == *",$me,"* ]]; then
    echo "« $me » est dans « $grp » dans /etc/group mais pas dans cette session — les groupes sont fixés à l'ouverture : rouvrir la session, ou jouer « sg $grp -c '<commande>' »"
  else
    echo "ajouter le compte au groupe : « sudo usermod -aG $grp $me », puis rouvrir la session (un shell déjà ouvert ne recharge pas ses groupes)"
  fi
}

_docker_sock_listening() { # _docker_sock_listening <socket> → 0 écoute · 1 orpheline · 2 non mesurable
  local sock="$1" table real _num _ref _proto flags _type _st _inode path
  table="${LCARS_DECOR_ROOT:-}/proc/net/unix"
  [[ -r "$table" ]] || return 2
  real="$(readlink -f "$sock" 2>/dev/null || printf '%s' "$sock")"
  while read -r _num _ref _proto flags _type _st _inode path; do
    [[ "$path" == "$sock" || "$path" == "$real" ]] || continue
    [[ "$flags" == "00010000" ]] && return 0
  done < "$table"
  return 1
}

# la CLI que porte le montage de Docker Desktop : 30-wsl y lit la présence de Desktop
_docker_mount_cli() { echo "${LCARS_DECOR_ROOT:-}/mnt/wsl/docker-desktop/cli-tools/usr/bin/docker"; }

docker_endpoint() { # docker_endpoint → 0, PROV_DOCKER_HOST posé et DOCKER_HOST exporté ; ou 1 et PROV_DOCKER_WHY ; PROV_DOCKER_ECARTE, le DOCKER_HOST donné qui n'a pas répondu
  local want="${PROV_DOCKER_BIN:-}" cli sock
  sock="${LCARS_DECOR_ROOT:-}/var/run/docker.sock"
  PROV_DOCKER_BIN=""; PROV_DOCKER_HOST=""; PROV_DOCKER_WHY=""; PROV_DOCKER_DENIED=0; PROV_DOCKER_ECARTE=""
  local wsl_geste="Sur WSL, deux choses, dans cet ordre : Docker Desktop démarré côté Windows, et l'intégration WSL activée pour cette distribution (Settings > Resources > WSL integration), puis rouvrir la session"
  for cli in "$want" docker; do
    [[ -n "$cli" ]] || continue
    # un nom nu ne se teste pas comme un chemin : « [[ -x docker ]] » est vrai dès que le dossier courant porte un fichier de ce nom
    if [[ "$cli" == */* ]]; then
      [[ -f "$cli" && -x "$cli" ]] && { PROV_DOCKER_BIN="$cli"; break; }
    else
      command -v "$cli" >/dev/null 2>&1 && { PROV_DOCKER_BIN="$cli"; break; }
    fi
  done
  if [[ -z "$PROV_DOCKER_BIN" ]]; then
    PROV_DOCKER_WHY="aucune CLI docker dans le PATH${want:+ (ni en $want)}"
    [[ "$(detect_substrate)" != "wsl" ]] || PROV_DOCKER_WHY+=". $wsl_geste"
    return 1
  fi
  local envhost="" dh=""
  if [[ -n "${DOCKER_HOST:-}" ]]; then
    if "$PROV_DOCKER_BIN" version --format '{{.Server.Version}}' >/dev/null 2>&1; then
      PROV_DOCKER_HOST="$DOCKER_HOST"
      return 0
    fi
    PROV_DOCKER_ECARTE="$DOCKER_HOST"
    dh="${DOCKER_HOST#unix://}"
    if [[ -S "$dh" ]]; then
      envhost=" ${DOCKER_HOST}[env,$([[ -w "$dh" ]] && echo "accessible" || echo "refusé à $(id -un)")]"
    else
      envhost=" ${DOCKER_HOST}[env,rien à cette adresse]"
    fi
    unset DOCKER_HOST   # dans l'environnement de l'appelant, à dessein : un DOCKER_HOST qui ne répond pas ne doit pas descendre aux modules
  fi
  local orpheline="" ecoute=""
  if [[ -S "$sock" ]]; then
    if DOCKER_HOST="unix://$sock" "$PROV_DOCKER_BIN" version --format '{{.Server.Version}}' >/dev/null 2>&1; then
      PROV_DOCKER_HOST="unix://$sock"
      export DOCKER_HOST="$PROV_DOCKER_HOST"
      return 0
    fi
    # « refusé » n'est pas « répond » : une socket orpheline ne met pas le groupe en cause
    if [[ ! -w "$sock" ]]; then
      _docker_sock_listening "$sock"; case "$?" in
        0) PROV_DOCKER_DENIED=1 ;;
        1) orpheline=" · la socket $sock refuse l'accès à « $(id -un) » ($(stat -Lc '%U:%G %a' "$sock" 2>/dev/null)) mais aucun processus n'y écoute (/proc/net/unix) : daemon arrêté ou socket orpheline — daemon vivant non établi, le groupe n'est pas la question" ;;
        *) PROV_DOCKER_DENIED=1; ecoute=" (écoute non vérifiable : /proc/net/unix illisible — daemon vivant présumé, pas établi)" ;;
      esac
    fi
  fi
  local resolved; resolved="$(command -v "$PROV_DOCKER_BIN" 2>/dev/null || echo "$PROV_DOCKER_BIN")"
  if [[ "$PROV_DOCKER_DENIED" == "1" ]]; then
    PROV_DOCKER_WHY="le daemon docker répond$ecoute, mais pas à « $(id -un) » : la socket $sock est $(stat -Lc '%U:%G %a' "$sock" 2>/dev/null) · $(docker_denied_geste "$sock") · CLI retenue : $resolved"
    return 1
  fi
  local tried
  if [[ -S "$sock" ]]; then tried=" ${sock}[socket$([[ -w "$sock" ]] && echo ",accessible" || echo ",non accessible")]"
  elif [[ -e "$sock" ]]; then tried=" ${sock}[existe, pas une socket]"
  else tried=" ${sock}[absent]"
  fi
  if [[ "$(detect_substrate)" == "wsl" ]]; then
    PROV_DOCKER_WHY="aucun daemon docker joignable. CLI retenue : $resolved · sockets essayées :$envhost$tried$orpheline. $wsl_geste ; c'est l'intégration qui pose /var/run/docker.sock ici"
  else
    PROV_DOCKER_WHY="aucun daemon docker joignable. CLI retenue : $resolved · sockets essayées :$envhost$tried$orpheline. Le service tourne-t-il, et ce compte est-il dans le groupe docker ?"
  fi
  return 1
}

PROV_COMPOSE_CMD=""
PROV_COMPOSE_WHY=""
docker_compose_cmd() { # docker_compose_cmd [<binaire docker>] → 0 et PROV_COMPOSE_CMD, ou 1 et PROV_COMPOSE_WHY
  local bin="${1:-${PROV_DOCKER_BIN:-docker}}"
  PROV_COMPOSE_CMD=""
  PROV_COMPOSE_WHY=""
  if "$bin" compose version >/dev/null 2>&1; then
    PROV_COMPOSE_CMD="$bin compose"
    return 0
  fi
  PROV_COMPOSE_WHY="docker répond, mais le plugin « docker compose » est absent"
  return 1
}
