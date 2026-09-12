#!/usr/bin/env bash
# les réponses sortent par des globales PROV_* que l'appelant lit : shellcheck les voit inutilisées
# shellcheck disable=SC2034
# SOURCE: deploy/lib/docker-endpoint.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: le substrat (docker, wsl, linux) et le daemon docker — une CLI du PATH, une socket, un verdict qui nomme le geste
#
# Sourcée par provision-lib.sh. Rend ses réponses par PROV_DOCKER_* ; docker_endpoint exporte
# DOCKER_HOST quand un daemon répond.

[[ -n "${LCARS_DOCKER_ENDPOINT_LOADED:-}" ]] && return 0
LCARS_DOCKER_ENDPOINT_LOADED=1

detect_substrate() { # detect_substrate → docker | wsl | linux ; LCARS_SUBSTRATE_ROOT est un décor
  local r="${LCARS_SUBSTRATE_ROOT:-}"
  if [[ -f "$r/.dockerenv" || "${LCARS_DOCKER:-}" == "1" ]]; then echo docker
  elif grep -qi microsoft "$r/proc/version" 2>/dev/null; then echo wsl
  else echo linux
  fi
}

PROV_DOCKER_BIN="${PROV_DOCKER_BIN:-}"
PROV_DOCKER_HOST=""
PROV_DOCKER_WHY=""
PROV_DOCKER_DENIED=0
PROV_DOCKER_SOCK=""

docker_denied_geste() { # docker_denied_geste <socket> → le geste qui rend l'accès, selon que la session porte déjà le groupe ou non
  local sock="${1:?}" grp me
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
  local sock="${1:?}" real _num _ref _proto flags _type _st _inode path
  [[ -r /proc/net/unix ]] || return 2
  real="$(readlink -f "$sock" 2>/dev/null || printf '%s' "$sock")"
  while read -r _num _ref _proto flags _type _st _inode path; do
    [[ "$path" == "$sock" || "$path" == "$real" ]] || continue
    [[ "$flags" == "00010000" ]] && return 0
  done < /proc/net/unix
  return 1
}

# le montage de Docker Desktop : une sonde de sa présence (30-wsl), pas une CLI de repli — l'intégration WSL pose docker sur le PATH
_docker_mount_cli() { echo "${LCARS_DOCKER_MOUNT_CLI:-/mnt/wsl/docker-desktop/cli-tools/usr/bin/docker}"; }

_docker_sockets() {
  if [[ -n "${LCARS_DOCKER_SOCKETS:-}" ]]; then
    printf '%s\n' "$LCARS_DOCKER_SOCKETS"
    return 0
  fi
  printf '%s\n' /var/run/docker.sock
}

docker_endpoint() { # docker_endpoint → 0 et DOCKER_HOST exporté, ou 1 et PROV_DOCKER_WHY
  local want="${PROV_DOCKER_BIN:-}"
  PROV_DOCKER_BIN=""; PROV_DOCKER_HOST=""; PROV_DOCKER_WHY=""; PROV_DOCKER_DENIED=0; PROV_DOCKER_SOCK=""
  local cli sock
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
    [[ "$(detect_substrate)" != "wsl" ]] \
      || PROV_DOCKER_WHY+=". Sur WSL, c'est l'intégration Docker Desktop qui la pose : Docker Desktop démarré côté Windows, l'intégration WSL activée pour cette distribution (Settings > Resources > WSL integration), puis rouvrir la session"
    return 1
  fi
  local _envhost="" _dh=""
  if [[ -n "${DOCKER_HOST:-}" ]]; then
    if "$PROV_DOCKER_BIN" version --format '{{.Server.Version}}' >/dev/null 2>&1; then return 0; fi
    _dh="${DOCKER_HOST#unix://}"
    if [[ -S "$_dh" ]]; then
      _envhost=" ${DOCKER_HOST}[env,$([[ -w "$_dh" ]] && echo "accessible" || echo "refusé à $(id -un)")]"
    else
      _envhost=" ${DOCKER_HOST}[env,rien à cette adresse]"
    fi
    unset DOCKER_HOST   # dans l'environnement de l'appelant, à dessein : un DOCKER_HOST qui ne répond pas ne doit pas descendre aux modules
  fi
  while read -r sock; do
    [[ -S "$sock" ]] || continue
    if DOCKER_HOST="unix://$sock" "$PROV_DOCKER_BIN" version --format '{{.Server.Version}}' >/dev/null 2>&1; then
      PROV_DOCKER_HOST="unix://$sock"
      export DOCKER_HOST="$PROV_DOCKER_HOST"
      return 0
    fi
    [[ -w "$sock" ]] || { PROV_DOCKER_DENIED=1; : "${PROV_DOCKER_SOCK:=$sock}"; }   # la première refusée est celle qu'on nomme : la dernière a déjà fait accuser le mauvais objet
  done < <(_docker_sockets)
  # « refusé » n'est pas « répond » : une socket orpheline ne met pas le groupe en cause
  local _orpheline="" _ecoute=""
  if [[ "${PROV_DOCKER_DENIED:-0}" == "1" ]]; then
    _docker_sock_listening "$PROV_DOCKER_SOCK"; case "$?" in
      0) ;;
      1) PROV_DOCKER_DENIED=0
         _orpheline=" · la socket $PROV_DOCKER_SOCK refuse l'accès à « $(id -un) » ($(stat -Lc '%U:%G %a' "$PROV_DOCKER_SOCK" 2>/dev/null)) mais aucun processus n'y écoute (/proc/net/unix) : daemon arrêté ou socket orpheline — daemon vivant non établi, le groupe n'est pas la question" ;;
      *) _ecoute=" (écoute non vérifiable : /proc/net/unix illisible — daemon vivant présumé, pas établi)" ;;
    esac
  fi
  if [[ "${PROV_DOCKER_DENIED:-0}" == "1" ]]; then
    local abs; abs="$(command -v "$PROV_DOCKER_BIN" 2>/dev/null || echo "$PROV_DOCKER_BIN")"
    PROV_DOCKER_WHY="le daemon docker répond$_ecoute, mais pas à « $(id -un) » : la socket $PROV_DOCKER_SOCK est $(stat -Lc '%U:%G %a' "$PROV_DOCKER_SOCK" 2>/dev/null) · $(docker_denied_geste "$PROV_DOCKER_SOCK") · CLI retenue : $abs"
    return 1
  fi
  local resolved tried="$_orpheline"
  resolved="$(command -v "$PROV_DOCKER_BIN" 2>/dev/null || echo "$PROV_DOCKER_BIN")"
  while read -r sock; do
    if [[ -S "$sock" ]]; then tried+=" ${sock}[socket$([[ -w "$sock" ]] && echo ",accessible" || echo ",non accessible")]"
    elif [[ -e "$sock" ]]; then tried+=" ${sock}[existe, pas une socket]"
    else tried+=" ${sock}[absent]"
    fi
  done < <(_docker_sockets)
  if [[ "$(detect_substrate)" == "wsl" ]]; then
    PROV_DOCKER_WHY="aucun daemon docker joignable. CLI retenue : $resolved · sockets essayées :$_envhost$tried. Sur WSL, deux choses, dans cet ordre : Docker Desktop démarré côté Windows, et l'intégration WSL activée pour cette distribution (Settings > Resources > WSL integration). C'est elle qui pose /var/run/docker.sock ici"
  else
    PROV_DOCKER_WHY="aucun daemon docker joignable. CLI retenue : $resolved · sockets essayées :$_envhost$tried. Le service tourne-t-il, et ce compte est-il dans le groupe docker ?"
  fi
  return 1
}

docker_stream_ok() { # docker_stream_ok <conteneur> → 0 si un exec rend sa sortie (un relais amputé rend du vide)
  local ctr="${1:?docker_stream_ok: nom ou id de conteneur requis}" out
  out="$("${PROV_DOCKER_BIN:-docker}" exec "$ctr" printf 'lcars-stream-ok' 2>/dev/null || true)"
  [[ "$out" == "lcars-stream-ok" ]]
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
  if command -v docker-compose >/dev/null 2>&1; then
    PROV_COMPOSE_CMD="docker-compose"
    return 0
  fi
  PROV_COMPOSE_WHY="docker répond, mais compose est absent (ni le plugin « docker compose », ni « docker-compose »)"
  return 1
}
