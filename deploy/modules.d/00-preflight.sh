#!/usr/bin/env bash
# SOURCE: deploy/modules.d/00-preflight.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: le préflight des deux terrains : système, substrat, docker, forge, ports, instance
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
# Ce module mesure et ne pose rien. Il parle deux fois : des lignes OK/WARN/DRIFT/FAIL pour un humain,
# et des faits `nom=valeur` (`p_fact`, dans PROV_FACTS_FILE) pour l'installeur, qui décide dessus.
# Chaque fait se pose au point de mesure, jamais dans un récapitulatif.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

# apt_installs_depuis <epoch> — les paquets installés à la main après cette date, hors mises à
# jour et dépendances automatiques, sous la forme « nom (date) », une par ligne.
apt_installs_depuis() {
  local depuis="$1" f
  for f in "${LCARS_APT_HISTORY:-/var/log/apt/history.log}"*; do
    [[ -r "$f" ]] || continue
    case "$f" in *.gz) zcat "$f" ;; *) cat "$f" ;; esac
  done 2>/dev/null | awk -v depuis="$depuis" '
    /^Start-Date:/ {
      ok = 0; jour = $2; t = 0
      if ($2 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ && $3 ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/) {
        cmd = "date -d \"" $2 " " $3 "\" +%s"; cmd | getline t; close(cmd)
      }
      ok = (t > depuis)
    }
    ok && /^Install:/ {
      s = $0; sub(/^Install: /, "", s)
      while (match(s, /[^ ,]+ \([^)]*\)/)) {
        item = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        if (item !~ /automatic\)$/) { p = item; sub(/:.*/, "", p); print p " (" jour ")" }
      }
    }'
}

check() {
  # ─── Le système ───────────────────────────────────────────────────────────────────────────────
  if command -v dpkg >/dev/null && command -v apt-get >/dev/null; then
    p_fact os debian
    p_ok "OS de la famille Debian (dpkg et apt présents)"
  else
    p_fact os autre
    p_drift "OS hors famille Debian : dpkg ou apt absent — ce provisionnement cible Debian et Ubuntu"
  fi

  local distro="" distro_version=""
  if [[ -r /etc/os-release ]]; then
    distro="$(. /etc/os-release 2>/dev/null; printf '%s' "${NAME:-}")"
    distro_version="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-}")"
  fi
  p_fact distro "$distro"
  p_fact distro_version "$distro_version"
  p_fact noyau "$(uname -r)"
  p_fact cpu "$(nproc 2>/dev/null || echo 1)"
  if [[ -d "${LCARS_SYSTEMD_RUN:-/run/systemd/system}" ]]; then p_fact systemd oui; else p_fact systemd non; fi

  p_fact bash "$BASH_VERSION"
  if [[ "${BASH_VERSINFO[0]}" -gt 4 || ( "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -ge 4 ) ]]; then
    p_ok "bash ${BASH_VERSION} (plancher 4.4)"
  else
    p_drift "bash ${BASH_VERSION} < 4.4 — un bash récent est requis"
  fi

  local arch; arch="$(uname -m)"
  p_fact arch "$arch"
  case "$arch" in
    x86_64|aarch64) p_ok "arch $arch" ;;
    *) p_drift "arch non supportée : $arch — cibles : x86_64, aarch64" ;;
  esac

  local ram_mb
  ram_mb="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
  p_fact ram_mb "$ram_mb"
  if [[ "$ram_mb" -lt 1536 ]]; then
    p_drift "RAM ${ram_mb} Mo < 1536 Mo — la release ne se construira pas (WSL : .wslconfig, [wsl2] memory=)"
  elif [[ "$ram_mb" -lt 3072 ]]; then
    p_warn "RAM ${ram_mb} Mo < 3072 Mo — construction lente possible"
    p_ok "RAM ${ram_mb} Mo (plancher 1536 Mo)"
  else
    p_ok "RAM ${ram_mb} Mo"
  fi

  local disk_mb probe_dir
  probe_dir="$(dirname "$PROV_PREFIX")"
  [[ -d "$probe_dir" ]] || probe_dir="/"
  disk_mb="$(df -Pm "$probe_dir" | awk 'NR==2 {print $4}')"
  p_fact disque_mb "$disk_mb"
  if [[ "$disk_mb" -lt 2048 ]]; then
    p_drift "disque ${disk_mb} Mo libres sur $probe_dir < 2048 Mo — libérer de l'espace avant l'installation"
  elif [[ "$disk_mb" -lt 5120 ]]; then
    p_warn "disque ${disk_mb} Mo libres sur $probe_dir < 5120 Mo — juste"
    p_ok "disque ${disk_mb} Mo libres ($probe_dir)"
  else
    p_ok "disque ${disk_mb} Mo libres ($probe_dir)"
  fi

  local humain; humain="${SUDO_USER:-$(id -un)}"
  p_fact utilisateur "$humain"
  p_fact groupes "$(id -Gn "$humain" 2>/dev/null | tr ' ' ',')"

  # ─── Le substrat ──────────────────────────────────────────────────────────────────────────────
  p_fact substrat "$PROV_SUBSTRATE"

  if [[ "$PROV_SUBSTRATE" == "linux" ]]; then
    if [[ -n "${LCARS_ALLOW_ANY_HOST:-}" ]]; then
      p_fact consent env
      p_warn "Linux natif déclaré dédié (LCARS_ALLOW_ANY_HOST) — ce provisionnement possède la machine et n'a pas de désinstalleur"
    else
      p_fact consent none
      p_fail "Linux natif sans déclaration : LCARS s'installe sur un terrain dédié, qu'il possède (/etc, /opt/lcars, groupes, comptes) et qui se refait plutôt qu'il ne se désinstalle. Pour déclarer cette machine dédiée : LCARS_ALLOW_ANY_HOST=1. Sinon : une distribution WSL2, ou le conteneur (bash install.sh)"
    fi
  else
    p_fact consent sans-objet
  fi

  if [[ "$PROV_SUBSTRATE" == "wsl" ]]; then
    if grep -qi 'WSL2\|microsoft-standard' /proc/version 2>/dev/null; then
      p_fact wsl2 oui
      p_ok "WSL2 (noyau $(uname -r))"
    else
      p_fact wsl2 non
      p_drift "WSL1 ($(uname -r)) — bwrap exige WSL2 : « wsl --set-version <distro> 2 » côté Windows"
    fi
  else
    p_fact wsl2 sans-objet
  fi

  local knob
  knob="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo absent)"
  p_fact userns_knob "$knob"
  case "$knob" in
    0)      p_ok "kernel.apparmor_restrict_unprivileged_userns=0" ;;
    absent) p_ok "pas de restriction AppArmor sur les user namespaces" ;;
    *)      p_warn "kernel.apparmor_restrict_unprivileged_userns=$knob — bwrap peut être bloqué ; la sonde réelle est dans 10-packages" ;;
  esac

  # ─── Docker, sur tout substrat ────────────────────────────────────────────────────────────────
  # Le fait est mesuré partout ; le refus ne vaut que sous WSL, où la forge n'a pas d'autre forme.
  # Les faits de ce bloc sont tous posés dans les deux états, vides quand ils n'ont pas d'objet.
  local docker_repond=0 serveur=""
  if docker_endpoint; then
    docker_repond=1
    serveur="$("$PROV_DOCKER_BIN" version --format '{{.Server.Version}}|{{.Server.Platform.Name}}' 2>/dev/null || true)"
    p_fact docker oui
    p_fact docker_bin "$PROV_DOCKER_BIN"
    p_fact docker_host "${PROV_DOCKER_HOST:-${DOCKER_HOST:-}}"
    p_fact docker_server "${serveur%%|*}"
    p_fact docker_flavor "${serveur#*|}"
    p_fact docker_why ""
    p_ok "docker répond (serveur ${serveur%%|*}, ${PROV_DOCKER_HOST:-${DOCKER_HOST:-endpoint par défaut}})"
  else
    if [[ "${PROV_DOCKER_DENIED:-0}" == "1" ]]; then p_fact docker refuse; else p_fact docker absent; fi
    p_fact docker_bin ""
    p_fact docker_host ""
    p_fact docker_server ""
    p_fact docker_flavor ""
    p_fact docker_why "$PROV_DOCKER_WHY"
    if [[ "$PROV_SUBSTRATE" == "wsl" ]]; then
      p_fail "$PROV_DOCKER_WHY — sans docker la forge de LCARS n'a aucune forme : 63-forge-tokens et 66-deck-oidc ne convergeront pas"
    else
      p_warn "$PROV_DOCKER_WHY"
    fi
  fi

  if [[ "$docker_repond" -eq 0 ]]; then
    p_fact compose sans-objet
    p_fact compose_why ""
  elif docker_compose_cmd "$PROV_DOCKER_BIN"; then
    p_fact compose oui
    p_fact compose_why ""
    p_ok "docker compose répond ($PROV_COMPOSE_CMD)"
  else
    p_fact compose non
    p_fact compose_why "$PROV_COMPOSE_WHY"
    p_warn "$PROV_COMPOSE_WHY"
  fi

  # ─── La forge : fournie, ou montée par l'installeur ───────────────────────────────────────────
  if [[ -n "${FORGE_BASE_URL:-}" && "${PROV_FORGE_MONTEE:-}" == "1" ]]; then
    p_fact forge_fournie ""
    p_fact forge_joignable sans-objet
    p_warn "FORGE_BASE_URL ($FORGE_BASE_URL) est ignorée : la forge est montée par l'installeur (--bench), tous les modules s'adressent à celle du poste"
  elif [[ -n "${FORGE_BASE_URL:-}" ]]; then
    p_fact forge_fournie "$FORGE_BASE_URL"
    if curl -fsS -m 5 -o /dev/null "${FORGE_BASE_URL%/}/api/v1/version" 2>/dev/null; then
      p_fact forge_joignable oui
      p_ok "forge fournie et joignable ($FORGE_BASE_URL)"
    else
      p_fact forge_joignable non
      p_warn "FORGE_BASE_URL est définie ($FORGE_BASE_URL) mais l'API ne répond pas"
    fi
  else
    p_fact forge_fournie ""
    p_fact forge_joignable sans-objet
  fi

  # ─── Les ports et le projet compose ───────────────────────────────────────────────────────────
  local base="$PROV_FORGE_BASE" nom port etat landing
  local -a miens=("$PROV_FORGE_PROJECT" "$base-fleet" "$PROV_RUNNER_PROJECT")
  landing="$(env_field "${LCARS_SERVICES_ENV:-/etc/lcars/services.env}" LCARS_LANDING_PORT)"
  for nom in forge:"$PROV_FORGE_HOST_PORT" deck:"$PROV_DECK_PORT" ssh:"$PROV_SSH_PORT"; do
    port="${nom#*:}"
    etat="$(port_state "$port" "${miens[@]}")"
    [[ "$etat" != pris* || "$nom" != deck:* || "$port" != "$landing" ]] || etat="nous lcars-landing (service)"
    p_fact "port_${nom%%:*}" "$port $etat"
    [[ "$etat" != pris* ]] || p_warn "port $port (${nom%%:*}) $etat"
  done
  p_fact projet "$base"
  local pris=""
  if [[ "$docker_repond" -eq 1 ]]; then
    for nom in "${miens[@]}"; do
      [[ -z "$("$PROV_DOCKER_BIN" ps -a --filter "label=com.docker.compose.project=$nom" -q 2>/dev/null)" ]] || pris="${pris:+$pris,}$nom"
    done
  fi
  p_fact projet_pris "$pris"
  [[ -z "$pris" ]] || p_warn "projet compose déjà présent sur ce daemon : $pris"

  # ─── L'instance : ce qu'elle porte déjà ───────────────────────────────────────────────────────
  if [[ "$PROV_SUBSTRATE" == "docker" ]]; then
    p_fact apt_installs sans-objet
  else
    local naissance; naissance="${LCARS_INSTANCE_BIRTH:-$(stat -c %W / 2>/dev/null || true)}"
    if [[ "$naissance" =~ ^[1-9][0-9]*$ ]]; then
      p_fact apt_installs "$(apt_installs_depuis "$naissance" | paste -sd, -)"
    else
      p_fact apt_installs inconnu
    fi
  fi
  p_fact comptes_humains "$(awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" {print $1}' "${LCARS_PASSWD_FILE:-/etc/passwd}" 2>/dev/null | paste -sd, -)"

  # ─── sudo ─────────────────────────────────────────────────────────────────────────────────────
  if [[ "$EUID" -eq 0 ]]; then
    p_fact sudo root
  elif command -v sudo >/dev/null 2>&1; then
    p_fact sudo oui
  else
    p_fact sudo absent
  fi

  # ─── Le canal : qui a posé le produit, et ce que cet arbre poserait ───────────────────────────
  p_fact channel_tree "$(prov_channel_here)"
  # appel nu : le p_fail d'un canal illisible doit compter dans le verdict
  if prov_channel >/dev/null; then
    p_fact channel "$PROV_CHANNEL"
    if [[ "$PROV_CHANNEL" == "aucun" ]]; then
      p_ok "aucun canal d'installation ($PROV_CHANNEL_FILE absent) — machine jamais posée ; cet arbre poserait « $(prov_channel_here) »"
    elif [[ "$PROV_CHANNEL" == "inconnu" ]]; then
      p_warn "canal d'installation inconnu : un produit est posé ($PROV_PREFIX) sans tampon ($PROV_CHANNEL_FILE) ; un kit ou une source le reprend et l'écrit"
    else
      p_ok "canal d'installation : $PROV_CHANNEL ($PROV_CHANNEL_FILE) — cet arbre poserait « $(prov_channel_here) »"
    fi
  else
    p_fact channel invalide
  fi

  # ─── Les outils d'amorçage ────────────────────────────────────────────────────────────────────
  local tool
  for tool in curl git; do
    if command -v "$tool" >/dev/null; then
      p_fact "$tool" oui
      p_ok "$tool présent"
    else
      p_fact "$tool" absent
      p_drift "$tool absent — apt-get install -y $tool"
    fi
  done

}

# le préflight ne pose rien : les deux verbes sondent, chacun rend le verdict de son contrat
case "${1:?usage: 00-preflight.sh <check|apply>}" in
  check) check; verdict_check ;;
  apply) check; verdict_apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
