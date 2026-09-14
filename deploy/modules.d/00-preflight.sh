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
  for f in "$(prov_decor /var/log/apt/history.log)"*; do
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

ancetre_existant() { # ancetre_existant <chemin> → le chemin s'il existe, sinon son ancêtre le plus proche qui existe
  local p="$1"
  while [[ ! -e "$p" ]]; do p="$(dirname "$p")"; done
  printf '%s\n' "$p"
}

# hors de l'installeur, PROV_FACTS_FILE est vide : un fait qui ne sert qu'à lui ne se calcule pas
faits_attendus() { [[ -n "${PROV_FACTS_FILE:-}" ]]; }

check() {
  # ─── Le système ───────────────────────────────────────────────────────────────────────────────
  if command -v dpkg >/dev/null && command -v apt-get >/dev/null; then
    p_ok "OS de la famille Debian (dpkg et apt présents)"
  else
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
  if [[ -d "$(prov_decor /run/systemd/system)" ]]; then p_fact systemd oui; else p_fact systemd non; fi

  # des faits sans verdict : l'installeur choisit ceux qu'il exige, 10-packages les pose dans ce système
  local tool
  for tool in curl git jq; do
    if command -v "$tool" >/dev/null; then p_fact "$tool" oui; else p_fact "$tool" absent; fi
  done

  # les bascules de dossiers ont lieu sous PROV_ROOT : échange et espace se mesurent sur son système de fichiers
  local sous echange
  sous="$(ancetre_existant "$PROV_ROOT")"
  if echange="$(mktemp -d "$sous/.prov-echange.XXXXXX" 2>/dev/null)"; then
    mkdir "$echange/a" "$echange/b"
    if mv --exchange -T -- "$echange/a" "$echange/b" 2>/dev/null; then
      p_ok "« mv --exchange » joué sous $sous : les bascules de dossiers ont une forme atomique"
    else
      p_fail "« mv --exchange » refusé sous $sous (coreutils 9.5, sur un système de fichiers qui sait échanger) — les bascules de dossiers n'ont pas de forme atomique"
    fi
    rm -rf -- "$echange"
  else
    p_warn "« mv --exchange » non sondé : $sous n'est pas inscriptible par $(id -un) — la sonde se joue sous root"
  fi

  local arch; arch="$(uname -m)"
  p_fact arch "$arch"
  case "$arch" in
    x86_64|aarch64) p_ok "arch $arch" ;;
    *) p_drift "arch non supportée : $arch — cibles : x86_64, aarch64" ;;
  esac

  local ram_mb
  ram_mb="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' "$(prov_decor /proc/meminfo)" 2>/dev/null || echo 0)"
  p_fact ram_mb "$ram_mb"
  if [[ "$ram_mb" -lt 1536 ]]; then
    p_drift "RAM ${ram_mb} Mo < 1536 Mo — la release ne se construira pas (WSL : .wslconfig, [wsl2] memory=)"
  elif [[ "$ram_mb" -lt 3072 ]]; then
    p_warn "RAM ${ram_mb} Mo < 3072 Mo — construction lente possible"
  else
    p_ok "RAM ${ram_mb} Mo"
  fi

  local disk_mb
  disk_mb="$(df -Pm "$sous" | awk 'NR==2 {print $4}')"
  p_fact disque_mb "$disk_mb"
  if [[ "$disk_mb" -lt 2048 ]]; then
    p_drift "disque ${disk_mb} Mo libres sur $sous < 2048 Mo — libérer de l'espace avant l'installation"
  elif [[ "$disk_mb" -lt 5120 ]]; then
    p_warn "disque ${disk_mb} Mo libres sur $sous < 5120 Mo — juste"
  else
    p_ok "disque ${disk_mb} Mo libres ($sous)"
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
      p_fail "Linux natif sans déclaration : LCARS s'installe sur un terrain dédié, qu'il possède (/etc, $PROV_ROOT, groupes, comptes) et qui se refait plutôt qu'il ne se désinstalle. Pour déclarer cette machine dédiée : LCARS_ALLOW_ANY_HOST=1. Sinon : une distribution WSL2, ou le conteneur (bash install.sh)"
    fi
  else
    p_fact consent sans-objet
  fi

  local noyau_wsl=""
  [[ "$PROV_SUBSTRATE" != wsl ]] || noyau_wsl="$(cat "$(prov_decor /proc/version)" 2>/dev/null || true)"
  if [[ -n "$noyau_wsl" && ! "${noyau_wsl,,}" =~ wsl2|microsoft-standard ]]; then
    p_drift "WSL1 ($(uname -r)) — bwrap exige WSL2 : « wsl --set-version <distro> 2 » côté Windows"
  fi

  # ─── Docker, sur tout substrat ────────────────────────────────────────────────────────────────
  # Le fait est mesuré partout ; le refus ne vaut que sous WSL, où la forge n'a pas d'autre forme.
  local docker=absent docker_bin="" serveur="" saveur=""
  if docker_endpoint; then
    docker=oui docker_bin="$PROV_DOCKER_BIN"
    serveur="$("$PROV_DOCKER_BIN" version --format '{{.Server.Version}}|{{.Server.Platform.Name}}' 2>/dev/null || true)"
    saveur="${serveur#*|}"
    # le paquet docker.io ne nomme pas sa plateforme : le paquet propriétaire d'un dockerd local la donne
    local dockerd; dockerd="$(command -v dockerd || true)"
    if [[ -z "$saveur" && -n "$dockerd" ]] && faits_attendus; then
      saveur="$(dpkg-query -S "$(readlink -f "$dockerd")" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
    fi
    p_ok "docker répond (serveur ${serveur%%|*}, $PROV_DOCKER_HOST)"
  else
    [[ "$PROV_DOCKER_DENIED" != "1" ]] || docker=refuse
    if [[ "$PROV_SUBSTRATE" == "wsl" ]]; then
      p_fail "$PROV_DOCKER_WHY — sans docker la forge de LCARS n'a aucune forme : 63-forge-tokens et 66-deck-oidc ne convergeront pas"
    else
      p_warn "$PROV_DOCKER_WHY"
    fi
  fi
  p_fact docker "$docker"
  p_fact docker_bin "$docker_bin"
  p_fact docker_host "$PROV_DOCKER_HOST"
  p_fact docker_server "${serveur%%|*}"
  p_fact docker_flavor "$saveur"
  p_fact docker_why "$PROV_DOCKER_WHY"

  local compose=sans-objet
  if [[ "$docker" == oui ]]; then
    if docker_compose_cmd "$docker_bin"; then
      compose=oui
      p_ok "docker compose répond ($PROV_COMPOSE_CMD)"
    else
      compose=non
      p_warn "$PROV_COMPOSE_WHY"
    fi
  fi
  p_fact compose "$compose"
  p_fact compose_why "$PROV_COMPOSE_WHY"

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
  landing="$(env_field "$PROV_SERVICES_ENV" LCARS_LANDING_PORT)"
  for nom in forge:"$PROV_FORGE_HOST_PORT" deck:"$PROV_DECK_PORT" ssh:"$PROV_SSH_PORT"; do
    port="${nom#*:}"
    etat="$(port_state "$port" "${miens[@]}")"
    [[ "$etat" != pris* || "$nom" != deck:* || "$port" != "$landing" ]] || etat="nous lcars-landing (service)"
    p_fact "port_${nom%%:*}" "$port $etat"
    [[ "$etat" != pris* ]] || p_warn "port $port (${nom%%:*}) $etat"
  done
  p_fact projet "$base"
  local pris=""
  if [[ "$docker" == oui ]]; then
    for nom in "${miens[@]}"; do
      [[ -z "$("$docker_bin" ps -a --filter "label=com.docker.compose.project=$nom" -q 2>/dev/null)" ]] || pris="${pris:+$pris,}$nom"
    done
  fi
  p_fact projet_pris "$pris"
  # la forge et le runner que 48 et 49 ont montés pour ce poste ne sont pas ceux d'un autre déploiement
  local etrangers=""
  for nom in ${pris//,/ }; do
    [[ "$(head -n1 "$PROV_FORGE_MODE_FILE" 2>/dev/null)" == poste \
       && ( "$nom" == "$PROV_FORGE_PROJECT" || "$nom" == "$PROV_RUNNER_PROJECT" ) ]] || etrangers="${etrangers:+$etrangers,}$nom"
  done
  if [[ -n "$etrangers" ]]; then
    p_warn "projet compose déjà présent sur ce daemon : $etrangers"
  elif [[ -n "$pris" ]]; then
    p_ok "projet compose de la forge de ce poste présent : $pris"
  fi

  # ─── L'instance : ce qu'elle porte déjà ───────────────────────────────────────────────────────
  if [[ "$PROV_SUBSTRATE" == "docker" ]]; then
    p_fact apt_installs sans-objet
  elif faits_attendus; then
    local naissance; naissance="${LCARS_INSTANCE_BIRTH:-$(stat -c %W / 2>/dev/null || true)}"
    if [[ "$naissance" =~ ^[1-9][0-9]*$ ]]; then
      p_fact apt_installs "$(apt_installs_depuis "$naissance" | paste -sd, -)"
    else
      p_fact apt_installs inconnu
    fi
  fi
  # la frontière système/humain est celle de la lib : login.defs, bornes comprises ; illisible, le fait reste vide
  local humains=""
  if prov_uid_bounds; then
    humains="$(awk -F: -v m="$PROV_UID_MIN" -v M="$PROV_UID_MAX" '$3+0 >= m && $3+0 <= M {print $1}' "$(prov_decor /etc/passwd)" 2>/dev/null | paste -sd, -)"
  fi
  p_fact comptes_humains "$humains"

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
  local canal=invalide
  if prov_channel >/dev/null; then canal="$PROV_CHANNEL"; fi
  p_fact channel "$canal"
  if [[ "$canal" == aucun ]]; then
    p_ok "aucun canal d'installation ($PROV_CHANNEL_FILE absent) — machine jamais posée ; cet arbre poserait « $(prov_channel_here) »"
  elif [[ "$canal" == inconnu ]]; then
    p_warn "canal d'installation inconnu : un produit est posé ($PROV_PREFIX) sans tampon ($PROV_CHANNEL_FILE) ; un kit ou une source le reprend et l'écrit"
  elif [[ "$canal" != invalide ]]; then
    p_ok "canal d'installation : $canal ($PROV_CHANNEL_FILE) — cet arbre poserait « $(prov_channel_here) »"
  fi
}

# le préflight ne pose rien : les deux verbes sondent, chacun rend le verdict de son contrat
case "${1:-}" in check|apply) check; "verdict_$1" ;; *) p_die "mode inconnu: ${1:-} (check|apply)" ;; esac
