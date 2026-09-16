#!/usr/bin/env bash
# SOURCE: deploy/modules.d/10-packages.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: paquets apt du runtime, et la sonde bwrap réelle (un sandbox tourne, pas seulement « le paquet est là »)
# APPLY-ON: wsl linux docker
# CHECK-ON: any
# NEEDS: root

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

# Une seule liste pour tous les terrains. `gh`, `git-filter-repo` et `ttyd` vivent dans `universe` :
# une image serveur qui ne l'active pas les verra « absents ». `sudo` : le rail s'escalade par lui.
# `procps` : pgrep/pkill, lus par 60, le convergeur et 64. `python3-venv` : PEP 668 est actif, pip
# hors venv échoue par conception ; build-essential, python3-dev, pkg-config, libssl-dev : les
# extensions C, node-gyp et les crates -sys que les pods compilent. `xz-utils` : 16-node détare un
# .tar.xz, et xz n'est que de priorité standard. `acl` : 30-wsl ouvre les projets au compte de
# Windows par une entrée nominative, et Ubuntu ne pose pas setfacl.
PACKAGES=(
  tmux bubblewrap git curl jq unzip xz-utils ca-certificates python3 socat acl
  git-filter-repo gh
  util-linux-extra sudo
  procps
  ttyd
  python3-venv python3-pip build-essential pkg-config python3-dev libssl-dev
  less bash-completion
)

# stderr non étouffé : un as_human impossible doit dire sa cause, pas passer pour un sandbox qui échoue
probe_bwrap() {
  as_human bwrap --ro-bind / / --unshare-all --die-with-parent /bin/true
}

# la sonde bwrap mesure le noyau, pas l'image : au build de l'image (BuildKit, sans userns) elle
# ne dit rien de la cible, PROV_KERNEL_PROBES=0 la reporte au boot
sonde_bwrap() { # sonde_bwrap <p_drift|p_fail> — le verdict d'un sandbox qui échoue dépend du verbe
  if [[ "${PROV_KERNEL_PROBES:-1}" == "0" ]]; then
    p_warn "sonde bwrap NON jouée (PROV_KERNEL_PROBES=0 : ce noyau n'est pas celui de la cible) — elle se joue au boot"
  elif probe_bwrap; then
    p_ok "bwrap sandbox opérationnel (sonde réelle, user $PROV_HUMAN)"
  else
    "$1" "bwrap installé mais un sandbox minimal ÉCHOUE (user $PROV_HUMAN) — userns restreints ? sysctl kernel.apparmor_restrict_unprivileged_userns=0 ou profil AppArmor pour bwrap ; sans ça, aucun pod ne spawnera"
  fi
}

check() {
  local pkg pkg_absent=0
  for pkg in "${PACKAGES[@]}"; do
    if pkg_installed "$pkg"; then
      p_ok "paquet $pkg"
    else
      p_drift "paquet $pkg absent"
      pkg_absent=1
    fi
  done
  [[ "$pkg_absent" -eq 1 ]] || sonde_bwrap p_drift
  verdict_check
}

apply() {
  apt_ensure "${PACKAGES[@]}" || verdict_apply
  sonde_bwrap p_fail
  verdict_apply
}

case "${1:-}" in check|apply) "$1" ;; *) p_die "mode inconnu: ${1:-} (check|apply)" ;; esac
