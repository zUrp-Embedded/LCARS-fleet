#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/10-packages.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — paquets runtime (apt) + sonde bwrap RÉELLE (le sandbox tourne, pas « le paquet est là »)
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
# (CHECK-ON any, APPLY-ON sans docker : les paquets sont des layers de l'image — mais bwrap
# opérationnel et l'outillage présent doivent être VRAIS en conteneur, et le doctor les y sonde.)
#
# Le strict nécessaire au RUNTIME v2 (le contrat vit dans fleet/runtime/etc/README.md) :
#   tmux        — sessions pod (host_launch/bwrap_launch) + le daemon fleet_v2
#   bubblewrap  — containment des pods (bwrap_launch.sh, sanctuaire)
#   git         — push per-step-run vers la forge
#   curl, jq    — clients HTTP forge + parse JSON (deps dures des scripts bin/ et etc/)
#   unzip       — dépose du précompilé Elixir (module 15-toolchain)
#   ca-certificates — TLS sortant (installer claude, forge https éventuelle)
# En Docker ces paquets sont des LAYERS de l'image (docker/Dockerfile) — même liste, autre
# mécanisme, ISO vérifiée par le même doctor sur place (d'où APPLY-ON sans docker, CHECK-ON any).
#
# PAS de yq (la donnée v2 est plate : env + listes — le blueprint YAML v1 meurt avec les
# users-par-rôle), PAS de gh (la forge est Gitea, parlée en curl). python3 EST requis — pas
# pour du patch-json (mort), mais comme interpréteur du bridge MCP des pods
# (fleet_mcp_stdio_bridge.py) : l'ancien « PAS de python » ici mentait au sanctuaire.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

PACKAGES=(tmux bubblewrap git curl jq unzip ca-certificates python3)

# Sonde RÉELLE du containment : un bwrap minimal DOIT tourner sous un user NON-root (les pods
# tournent comme l'humain). Lire une config ou un dpkg -s ne prouve rien — Ubuntu ≥23.10 peut
# avoir bwrap installé ET bloqué par AppArmor (userns restreints). On sonde en tant que
# PROV_HUMAN : c'est LUI qui spawnera des pods.
probe_bwrap() {
  # stderr NON étouffé : l'échec réel de bwrap doit être verbeux (doctrine), et surtout un
  # as_human impossible (doctor lancé par un user tiers) doit dire SA cause — le 2>/dev/null
  # transformait « je ne peux pas sonder » en faux « le sandbox échoue ».
  as_human bwrap --ro-bind / / --unshare-all --die-with-parent /bin/true
}

check() {
  # (nommé pkg_absent, pas « missing » : la lib a un array `missing` dans apt_ensure, et
  # l'analyse -x confond les deux scopes — SC2178 parasite.)
  local pkg pkg_absent=0
  for pkg in "${PACKAGES[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      p_ok "paquet $pkg"
    else
      p_drift "paquet $pkg absent"
      pkg_absent=1
    fi
  done
  if [[ "$pkg_absent" -eq 0 ]]; then
    if probe_bwrap; then
      p_ok "bwrap sandbox opérationnel (sonde réelle, user $PROV_HUMAN)"
    else
      p_drift "bwrap installé mais un sandbox minimal ÉCHOUE (user $PROV_HUMAN) — userns restreints ? (sysctl kernel.apparmor_restrict_unprivileged_userns, profil AppArmor bwrap) ; sans ça, AUCUN pod ne spawnera"
    fi
  fi
  verdict_check
}

apply() {
  apt_ensure "${PACKAGES[@]}" || verdict_apply
  if probe_bwrap; then
    p_ok "bwrap sandbox opérationnel (sonde réelle, user $PROV_HUMAN)"
  else
    # On n'auto-flippe PAS un sysctl de sécurité système : c'est un arbitrage humain
    # (assouplir AppArmor vs poser un profil dédié). On échoue en le disant précisément.
    p_fail "bwrap installé mais le sandbox minimal ÉCHOUE (user $PROV_HUMAN) — arbitrage requis : sysctl kernel.apparmor_restrict_unprivileged_userns=0 OU profil AppArmor pour bwrap ; re-lance ensuite"
  fi
  verdict_apply
}

case "${1:?usage: 10-packages.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
