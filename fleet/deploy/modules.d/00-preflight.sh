#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/00-preflight.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — préflight fail-fast : plancher OS/arch/RAM/disque/WSL2, messages actionnables
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

check() {
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

  local arch; arch="$(uname -m)"
  case "$arch" in
    x86_64|aarch64) p_ok "arch $arch" ;;
    *) p_drift "arch non supportée : $arch (détecté par uname -m) — cibles : x86_64, aarch64" ;;
  esac

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

  local consent_file="${LCARS_HOST_CONSENT_FILE:-/etc/lcars/host-consent}"
  if [[ "$PROV_SUBSTRATE" == "linux" ]]; then
    if [[ -n "${LCARS_ALLOW_ANY_HOST:-}" ]]; then
      p_warn "Linux natif, et tu l'as explicitement accepté (LCARS_ALLOW_ANY_HOST) — hors cible : rien ici n'est mesuré sur ce substrat, et il n'y a pas de désinstalleur"
    elif [[ -s "$consent_file" ]]; then
      p_warn "Linux natif, accepté une fois sur cette machine ($consent_file) — hors cible : rien ici n'est mesuré sur ce substrat, et il n'y a pas de désinstalleur"
    else
      p_fail "HORS CIBLE : le poste de travail LCARS, c'est WSL2 (substrat mesuré : linux). Ce provisionnement possède /etc, crée un groupe système, pose /opt/lcars, et n'a aucun désinstalleur — on ne le lâche pas sur une machine dont on ne sait pas si c'est celle de quelqu'un. Sous Windows : « wsl --install -d Ubuntu-24.04 », puis relance ici. Sur du Linux natif, clone le dépôt et sers-toi de ce que tu veux — ou LCARS_ALLOW_ANY_HOST=1 si tu sais ce que tu fais"
    fi
  fi

  if [[ "$PROV_SUBSTRATE" == "wsl" ]]; then
    if docker_endpoint; then
      p_ok "docker répond ($PROV_DOCKER_BIN) — la forge du poste peut être montée (fleet/deploy/docker/bench/bench-up.sh)"
    else
      p_fail "$PROV_DOCKER_WHY — et sans docker la forge de LCARS n'a AUCUNE autre forme (c'est un conteneur) : 50-forge et 55-deck-oidc ne convergeront JAMAIS sur cette machine, le poste aurait un runtime qui ne peut pas travailler"
    fi
  fi

  if [[ "$PROV_SUBSTRATE" == "wsl" ]]; then
    if grep -qi 'WSL2\|microsoft-standard' /proc/version 2>/dev/null; then
      p_ok "WSL2 (kernel $(uname -r))"
    else
      p_drift "WSL1 détecté ($(uname -r)) — bwrap exige WSL2 : « wsl --set-version <distro> 2 » côté Windows"
    fi
  fi

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
