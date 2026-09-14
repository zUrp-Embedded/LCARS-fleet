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
# conforme ; un daemon qui refuse l'utilisateur, ou un moteur posé (docker-ce ou docker.io) dont le
# service est arrêté, se disent sans que rien ne soit reposé.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

ENGINE_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

DOCKER_KEYRING="$(prov_decor /etc/apt/keyrings/docker.asc)"
DOCKER_LIST="$(prov_decor /etc/apt/sources.list.d/docker.list)"
# la même clé sert les dépôts ubuntu et debian (même sha256 aux deux URL)
DOCKER_GPG_SHA256=1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570

os_field() { # os_field <clef de /etc/os-release>
  local f; f="$(prov_decor /etc/os-release)"
  [[ -r "$f" ]] || return 1
  # shellcheck source=/dev/null
  ( . "$f" 2>/dev/null; printf '%s' "${!1:-}" )
}

moteur_pose() { # moteur_pose → le paquet du moteur docker posé (docker-ce, ou docker.io de la distribution), rc 1 sans moteur
  local p
  for p in docker-ce docker.io; do
    pkg_installed "$p" && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

# ensure_docker_repo — la source apt de Docker, dérivée de la distribution ; un « apt-get update » qui la
# refuse (suite absente, réseau) la retire avec sa clé
ensure_docker_repo() {
  local id codename arch url
  id="$(os_field ID || true)"; codename="$(os_field VERSION_CODENAME || true)"
  case "$id" in
    ubuntu|debian) ;;
    *) p_fail "dépôt docker : distribution « ${id:-inconnue} » — l'upstream ne publie que pour ubuntu et debian"; return 1 ;;
  esac
  [[ -n "$codename" ]] || { p_fail "dépôt docker : /etc/os-release ne donne pas VERSION_CODENAME — la suite apt est indérivable"; return 1; }
  arch="$(arch_tag debian)"
  [[ -n "$arch" ]] || { p_fail "arch non épinglée pour le dépôt docker : « $(arch_tag raw) » (attendu amd64 ou arm64)"; return 1; }

  url="https://download.docker.com/linux/$id"
  ensure_dir "$(dirname "$DOCKER_KEYRING")" 0755 root:root || return 1
  if [[ "$(sha256sum "$DOCKER_KEYRING" 2>/dev/null | awk '{print $1}')" != "$DOCKER_GPG_SHA256" ]]; then
    fetch_verify "$url/gpg" "$DOCKER_GPG_SHA256" "$DOCKER_KEYRING" 0644 || return 1
  fi
  write_atomic "$DOCKER_LIST" 0644 "root:root" <<EOF || return 1
deb [arch=$arch signed-by=$DOCKER_KEYRING] $url $codename stable
EOF

  if ! run_capture apt-get update -o Dir::Etc::sourcelist="$DOCKER_LIST" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"; then
    rm -f "$DOCKER_LIST" "$DOCKER_KEYRING"
    p_fail "dépôt docker : « apt-get update » refuse la source « $url $codename » — retirée avec sa clé ($DOCKER_LIST, $DOCKER_KEYRING) ; la sortie d'apt dit pourquoi"
    prov_dump_last
    return 1
  fi
}

# etat_daemon — pose ETAT (repond | refuse | arrete | absent) et ETAT_WHY ; des globales, pas une
# sortie : la sonde pose elle-même des globales qu'un sous-shell perdrait
etat_daemon() {
  local moteur
  ETAT=""; ETAT_WHY=""
  if docker_endpoint; then
    ETAT=repond
  elif [[ "$PROV_DOCKER_DENIED" == "1" ]]; then
    ETAT=refuse; ETAT_WHY="$PROV_DOCKER_WHY"
  elif moteur="$(moteur_pose)"; then
    ETAT=arrete; ETAT_WHY="$moteur est posé mais aucun daemon ne répond — démarrer le service : systemctl start docker"
  else
    ETAT=absent; ETAT_WHY="$PROV_DOCKER_WHY"
  fi
}

check() {
  etat_daemon
  case "$ETAT" in
    repond) p_ok "un daemon docker répond ($PROV_DOCKER_HOST)" ;;
    refuse) p_drift "un daemon docker répond mais refuse cet utilisateur : $ETAT_WHY" ;;
    arrete) p_drift "$ETAT_WHY" ;;
    absent) p_drift "aucun daemon docker — docker-ce sera posé depuis download.docker.com" ;;
  esac
  verdict_check
}

apply() {
  etat_daemon
  case "$ETAT" in
    repond) p_ok "un daemon docker répond ($PROV_DOCKER_HOST) — rien à poser"; verdict_apply ;;
    refuse) p_fail "un daemon docker répond mais refuse cet utilisateur : $ETAT_WHY — rien n'est posé"; verdict_apply ;;
    arrete) p_fail "$ETAT_WHY — rien n'est reposé"; verdict_apply ;;
  esac
  ensure_docker_repo || verdict_apply
  apt_ensure "${ENGINE_PACKAGES[@]}" || verdict_apply
  # le postinst démarre le service sous systemd ; l'API peut mettre quelques secondes à écouter
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if docker_endpoint; then
      p_chg "docker-ce posé, le daemon répond ($PROV_DOCKER_HOST)"
      verdict_apply
    fi
    [[ "$i" -eq 10 ]] || sleep 2
  done
  p_fail "docker-ce posé mais aucun daemon ne répond — démarrer le service : systemctl start docker"
  verdict_apply
}

case "${1:-}" in check|apply) "$1" ;; *) p_die "mode inconnu: ${1:-} (check|apply)" ;; esac
