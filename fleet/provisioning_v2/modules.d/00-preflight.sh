#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/modules.d/00-preflight.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — préflight fail-fast : plancher OS/arch/RAM/disque/WSL2, messages actionnables
# SUBSTRATE: any
# NEEDS: human
#
# AUCUNE mutation — ce module ne fait que sonder (apply = check). Chaque échec dit : le problème
# précis, l'état DÉTECTÉ, et le geste pour réparer — jamais un « failed » nu.
# Doctrine plancher (leçon mail-in-a-box, leur faiblesse #3) : des contraintes `>=`, jamais une
# égalité de version exacte qui casse au premier bump distro.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

check() {
  # ── Famille OS : il nous faut dpkg/apt (les modules paquets sont apt-only, assumé) ──────────────
  if command -v dpkg >/dev/null && command -v apt-get >/dev/null; then
    p_ok "OS famille Debian/Ubuntu (dpkg + apt présents)"
  else
    p_drift "OS non-Debian : dpkg/apt absents — ce provisioning cible Debian/Ubuntu (WSL, Docker, natif)"
  fi

  # ── bash plancher 4.4 (arrays vides sous set -u, ${var@Q}…) ─────────────────────────────────────
  if [[ "${BASH_VERSINFO[0]}" -gt 4 || ( "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -ge 4 ) ]]; then
    p_ok "bash ${BASH_VERSION} (plancher 4.4)"
  else
    p_drift "bash ${BASH_VERSION} < 4.4 — détecté : $(command -v bash) ; installe un bash récent"
  fi

  # ── Arch ────────────────────────────────────────────────────────────────────────────────────────
  local arch; arch="$(uname -m)"
  case "$arch" in
    x86_64|aarch64) p_ok "arch $arch" ;;
    *) p_drift "arch non supportée : $arch (détecté par uname -m) — cibles : x86_64, aarch64" ;;
  esac

  # ── RAM 3 paliers (le build mix release est le pic ; le BEAM au run est modeste) ────────────────
  local ram_mb
  ram_mb="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ "$ram_mb" -lt 1536 ]]; then
    p_drift "RAM ${ram_mb}MB < 1536MB — le build de la release échouera ; ajoute de la RAM (WSL: .wslconfig [wsl2] memory=)"
  elif [[ "$ram_mb" -lt 3072 ]]; then
    p_warn "RAM ${ram_mb}MB < 3072MB — build lent possible (pas bloquant)"
    p_ok "RAM ${ram_mb}MB (plancher dur 1536MB)"
  else
    p_ok "RAM ${ram_mb}MB"
  fi

  # ── Disque sur le FS de PROV_PREFIX (release ~100MB, _build ~2GB au build) ──────────────────────
  local disk_mb probe_dir
  probe_dir="$(dirname "$PROV_PREFIX")"
  [[ -d "$probe_dir" ]] || probe_dir="/"
  disk_mb="$(df -Pm "$probe_dir" | awk 'NR==2 {print $4}')"
  if [[ "$disk_mb" -lt 2048 ]]; then
    p_drift "disque ${disk_mb}MB libres sur $probe_dir < 2048MB — libère de l'espace avant le deploy"
  elif [[ "$disk_mb" -lt 5120 ]]; then
    p_warn "disque ${disk_mb}MB libres sur $probe_dir < 5120MB — juste (pas bloquant)"
    p_ok "disque ${disk_mb}MB libres ($probe_dir)"
  else
    p_ok "disque ${disk_mb}MB libres ($probe_dir)"
  fi

  # ── WSL : version 2 obligatoire (WSL1 = pas de vrai kernel → pas de namespaces → pas de bwrap) ──
  if [[ "$PROV_SUBSTRATE" == "wsl" ]]; then
    if grep -qi 'WSL2\|microsoft-standard' /proc/version 2>/dev/null; then
      p_ok "WSL2 (kernel $(uname -r))"
    else
      p_drift "WSL1 détecté ($(uname -r)) — bwrap exige WSL2 : « wsl --set-version <distro> 2 » côté Windows"
    fi
  fi

  # ── Namespaces user non-privilégiés (le substrat du sandbox bwrap) ──────────────────────────────
  # Sonde des KNOBS ici (info early) ; la sonde RÉELLE (bwrap qui tourne) vit dans 10-packages,
  # une fois bwrap installé. Ubuntu ≥23.10 restreint les userns par AppArmor — dit explicitement.
  local knob
  knob="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo absent)"
  case "$knob" in
    0)      p_ok "kernel.apparmor_restrict_unprivileged_userns=0" ;;
    absent) p_ok "pas de restriction AppArmor userns (knob absent)" ;;
    *)      p_warn "kernel.apparmor_restrict_unprivileged_userns=$knob — bwrap peut être bloqué ; la sonde réelle est dans 10-packages (fix : sysctl kernel.apparmor_restrict_unprivileged_userns=0 ou profil AppArmor bwrap)" ;;
  esac

  # ── Outils de bootstrap (avant même 10-packages : il faut de quoi l'exécuter) ───────────────────
  local tool
  for tool in curl git; do
    if command -v "$tool" >/dev/null; then
      p_ok "$tool présent"
    else
      p_drift "$tool absent — installe-le d'abord : apt-get install -y $tool"
    fi
  done

  verdict_check
}

case "${1:?usage: 00-preflight.sh <check|apply>}" in
  check) check ;;
  apply) check ;;   # module read-only : converger = constater (aucune mutation à faire ici)
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
