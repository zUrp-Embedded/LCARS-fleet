#!/usr/bin/env bash
# SOURCE: deploy/modules.d/12-docker-engine.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: docker-ce sur une machine Linux dédiée : posé une fois si aucun daemon ne répond
# APPLY-ON: linux
# CHECK-ON: linux
# NEEDS: root
# AFTER: 10-packages
#
# Sous WSL le daemon vient de Docker Desktop, dans le conteneur on est déjà dedans : ce module ne
# vit que sur le substrat linux. Il pose docker-ce par confort, une fois. Un daemon qui répond est
# conforme ; un daemon qui refuse l'utilisateur, ou un docker-ce posé dont le service est arrêté,
# se disent sans que rien ne soit reposé.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

ENGINE_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

DOCKER_KEYRING="${LCARS_DOCKER_KEYRING:-/etc/apt/keyrings/docker.asc}"
DOCKER_LIST="${LCARS_DOCKER_LIST:-/etc/apt/sources.list.d/docker.list}"
# la même clé sert les dépôts ubuntu et debian (même sha256 aux deux URL)
DOCKER_GPG_SHA256="${LCARS_DOCKER_GPG_SHA256:-1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570}"

os_field() { # os_field <clef de /etc/os-release>
  [[ -r /etc/os-release ]] || return 1
  ( . /etc/os-release 2>/dev/null; printf '%s' "${!1:-}" )
}

engine_installed() { pkg_installed docker-ce; }

# ensure_docker_repo — la source apt de Docker, dérivée de la distribution, posée une fois.
# Un dépôt docker que la machine portait déjà est celui d'un opérateur : sur échec d'`apt-get
# update`, il est restauré tel quel, et seul ce que cette passe a écrit est retiré.
ensure_docker_repo() {
  local id codename arch url
  id="$(os_field ID || true)"; codename="$(os_field VERSION_CODENAME || true)"
  case "$id" in
    ubuntu|debian) ;;
    *) p_fail "dépôt docker : distribution « ${id:-inconnue} » — l'upstream ne publie que pour ubuntu et debian"; return 1 ;;
  esac
  [[ -n "$codename" ]] || { p_fail "dépôt docker : /etc/os-release ne donne pas VERSION_CODENAME — la suite apt est indérivable"; return 1; }

  url="https://download.docker.com/linux/$id"
  local rc=0 cerr; cerr="$(mktemp)"
  curl -fsIL --max-redirs 3 -m 20 -o /dev/null "$url/dists/$codename/Release" 2>"$cerr" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$rc" -eq 22 ]]; then
      p_fail "dépôt docker : la suite « $codename » n'existe pas chez Docker ($url/dists/) — rien n'est posé ; installer docker autrement, l'installeur sonde un daemon, pas un paquet"
    else
      p_fail "dépôt docker : $url injoignable (curl rc=$rc — $(tr -d '\n' < "$cerr")) — réseau, proxy ou DNS ; rien n'est posé"
    fi
    rm -f "$cerr"; return 1
  fi
  rm -f "$cerr"

  local list_avant=0 key_avant=0 sauve=""
  [[ -f "$DOCKER_LIST" ]]    && list_avant=1
  [[ -f "$DOCKER_KEYRING" ]] && key_avant=1
  if [[ "$list_avant" -eq 1 || "$key_avant" -eq 1 ]]; then
    sauve="$(mktemp -d)"
    [[ "$list_avant" -eq 1 ]] && cp -p "$DOCKER_LIST"    "$sauve/list" 2>/dev/null
    [[ "$key_avant"  -eq 1 ]] && cp -p "$DOCKER_KEYRING" "$sauve/key"  2>/dev/null
  fi

  ensure_dir "$(dirname "$DOCKER_KEYRING")" 0755 root:root || return 1
  if [[ "$(sha256sum "$DOCKER_KEYRING" 2>/dev/null | awk '{print $1}')" != "$DOCKER_GPG_SHA256" ]]; then
    fetch_verify "$url/gpg" "$DOCKER_GPG_SHA256" "$DOCKER_KEYRING" 0644 || return 1
  fi

  arch="$(arch_tag debian)"
  [[ -n "$arch" ]] || { p_fail "arch non épinglée pour le dépôt docker : « $(arch_tag raw) » (attendu amd64 ou arm64)"; return 1; }
  write_atomic "$DOCKER_LIST" 0644 "root:root" <<EOF || return 1
deb [arch=$arch signed-by=$DOCKER_KEYRING] $url $codename stable
EOF

  if ! run_quiet apt-get update -o Dir::Etc::sourcelist="$DOCKER_LIST" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"; then
    local restaure=""
    if [[ "$list_avant" -eq 1 && -f "$sauve/list" ]]; then
      cp -p "$sauve/list" "$DOCKER_LIST" && restaure="$DOCKER_LIST"
    else
      rm -f "$DOCKER_LIST"
    fi
    if [[ "$key_avant" -eq 1 && -f "$sauve/key" ]]; then
      cp -p "$sauve/key" "$DOCKER_KEYRING" && restaure="${restaure:+$restaure }$DOCKER_KEYRING"
    else
      rm -f "$DOCKER_KEYRING"
    fi
    [[ -n "$sauve" ]] && rm -rf "$sauve"
    if [[ -n "$restaure" ]]; then
      p_fail "dépôt docker : « apt-get update » refuse la source — ce que cette passe a écrit est annulé, ce que la machine portait est restauré ($restaure)"
    else
      p_fail "dépôt docker : « apt-get update » refuse la source — retirée avec sa clé ($DOCKER_LIST, $DOCKER_KEYRING), ni l'une ni l'autre n'était là avant"
    fi
    return 1
  fi
  [[ -n "$sauve" ]] && rm -rf "$sauve"
  return 0
}

# etat_daemon — pose ETAT (repond | refuse | arrete | absent) et ETAT_WHY ; des globales, pas une
# sortie : la sonde pose elle-même des globales qu'un sous-shell perdrait
etat_daemon() {
  ETAT=""; ETAT_WHY=""
  if docker_endpoint >/dev/null 2>&1; then
    ETAT=repond
  elif [[ "${PROV_DOCKER_DENIED:-0}" == "1" ]]; then
    ETAT=refuse; ETAT_WHY="$PROV_DOCKER_WHY"
  elif engine_installed; then
    ETAT=arrete; ETAT_WHY="docker-ce est posé mais aucun daemon ne répond — démarrer le service : systemctl start docker"
  else
    ETAT=absent; ETAT_WHY="${PROV_DOCKER_WHY:-aucun daemon docker}"
  fi
}

endpoint() { printf '%s' "${PROV_DOCKER_HOST:-${DOCKER_HOST:-endpoint par défaut}}"; }

check() {
  etat_daemon
  case "$ETAT" in
    repond) p_ok "un daemon docker répond ($(endpoint))" ;;
    refuse) p_drift "un daemon docker répond mais refuse cet utilisateur : $ETAT_WHY" ;;
    arrete) p_drift "$ETAT_WHY" ;;
    absent) p_drift "aucun daemon docker — docker-ce sera posé depuis download.docker.com" ;;
  esac
  verdict_check
}

apply() {
  etat_daemon
  case "$ETAT" in
    repond) p_ok "un daemon docker répond ($(endpoint)) — rien à poser"; verdict_apply ;;
    refuse) p_fail "un daemon docker répond mais refuse cet utilisateur : $ETAT_WHY — rien n'est posé"; verdict_apply ;;
    arrete) p_fail "$ETAT_WHY — rien n'est reposé"; verdict_apply ;;
  esac
  ensure_docker_repo || verdict_apply
  apt_ensure "${ENGINE_PACKAGES[@]}" || verdict_apply
  # le postinst démarre le service sous systemd ; l'API peut mettre quelques secondes à écouter
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    docker_endpoint >/dev/null 2>&1 && break
    [[ "$i" -lt 10 ]] && sleep 2
  done
  if docker_endpoint >/dev/null 2>&1; then
    p_chg "docker-ce posé, le daemon répond ($(endpoint))"
  else
    p_fail "docker-ce posé mais aucun daemon ne répond — démarrer le service : systemctl start docker"
  fi
  verdict_apply
}

case "${1:?usage: 12-docker-engine.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
