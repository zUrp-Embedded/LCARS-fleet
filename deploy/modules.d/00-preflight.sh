#!/usr/bin/env bash
# SOURCE: deploy/modules.d/00-preflight.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-14
# STATUS: le préflight des deux terrains : système, substrat, docker, forge, ports, instance
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
# Ce module mesure et ne pose rien. Il parle deux fois : des lignes OK/WARN/DRIFT/FAIL pour un humain,
# et des faits `nom=valeur` (`p_fact`, dans PROV_FACTS_FILE) pour l'installeur, qui décide dessus.
# Chaque fait se pose au point de mesure, jamais dans un récapitulatif.
#
# Deux phases, que « provision mesure » choisit (PROV_PHASE). Sans privilège, ce que le compte de
# l'opérateur lit, avant sudo : de quoi montrer la grille et refuser tôt. En root, les refus qui
# protègent la machine se décident sans rien reprendre de la première : la déclaration d'un Linux
# dédié, le canal, chaque port de ce projet et les projets compose présents, plus l'écriture sous la
# racine. Joué par apply ou doctor, le préflight prend les deux phases à la suite.

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

port_de() { # port_de <deck|forge|ssh> → le port que ce projet publie sous ce nom
  case "$1" in deck) echo "$PROV_DECK_PORT" ;; forge) echo "$PROV_FORGE_HOST_PORT" ;; ssh) echo "$PROV_SSH_PORT" ;; esac
}

# le processus principal que ce systemd donne à lcars-landing : sous WSL, un processus d'une autre
# distribution n'est pas nommé par ss, et un pid de cette machine ne le confond pas
landing_tient() { # landing_tient <processus nommé par port_process> → 0 si c'est le processus principal de lcars-landing
  local pid
  pid="$(systemctl show -p MainPID --value lcars-landing.service 2>/dev/null)" || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$1" =~ \(pid\ ([0-9]+) && "${BASH_REMATCH[1]}" == "$pid" ]]
}

MIENS=("$PROV_FORGE_PROJECT" "$PROV_FORGE_BASE-fleet" "$PROV_RUNNER_PROJECT")
DOCKER_REPOND=0

mesure_sans_privilege() {
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

  # la racine se pose sur le système de fichiers de son ancêtre existant : l'espace se mesure là
  local sous disk_mb
  sous="$(ancetre_existant "$PROV_ROOT")"
  disk_mb="$(df -Pm "$sous" | awk 'NR==2 {print $4}')"
  p_fact racine "$(prov_canon "$PROV_ROOT")"
  p_fact disque_mb "$disk_mb"
  if [[ "$disk_mb" -lt 2048 ]]; then
    p_drift "disque ${disk_mb} Mo libres sur $sous < 2048 Mo — libérer de l'espace avant l'installation"
  elif [[ "$disk_mb" -lt 5120 ]]; then
    p_warn "disque ${disk_mb} Mo libres sur $sous < 5120 Mo — juste"
  else
    p_ok "disque ${disk_mb} Mo libres ($sous)"
  fi

  # les groupes que la base donne à l'humain servi : c'est root qui travaille, pas la session qui mesure
  p_fact utilisateur "$PROV_HUMAN"
  p_fact groupes "$(id -Gn -- "$PROV_HUMAN" 2>/dev/null | tr ' ' ',')"

  # ─── Le substrat ──────────────────────────────────────────────────────────────────────────────
  p_fact substrat "$PROV_SUBSTRATE"
  local noyau_wsl=""
  [[ "$PROV_SUBSTRATE" != wsl ]] || noyau_wsl="$(cat "$(prov_decor /proc/version)" 2>/dev/null || true)"
  if [[ -n "$noyau_wsl" && ! "${noyau_wsl,,}" =~ wsl2|microsoft-standard ]]; then
    p_drift "WSL1 ($(uname -r)) — bwrap exige WSL2 : « wsl --set-version <distro> 2 » côté Windows"
  fi

  # ─── Docker, sur tout substrat ────────────────────────────────────────────────────────────────
  # Le fait est mesuré partout ; le refus ne vaut que sous WSL, où la forge n'a pas d'autre forme.
  local docker=absent serveur="" saveur=""
  if docker_endpoint; then
    docker=oui DOCKER_REPOND=1
    serveur="$("$PROV_DOCKER_BIN" version --format '{{.Server.Version}}|{{.Server.Platform.Name}}' 2>/dev/null || true)"
    saveur="${serveur#*|}"
    # le paquet docker.io ne nomme pas sa plateforme : le paquet propriétaire d'un dockerd local la donne
    local dockerd; dockerd="$(command -v dockerd || true)"
    if [[ -z "$saveur" && -n "$dockerd" ]] && faits_attendus; then
      saveur="$(dpkg-query -S "$(readlink -f "$dockerd")" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
    fi
    p_ok "docker répond (serveur ${serveur%%|*}, $PROV_DOCKER_HOST)"
    [[ -z "$PROV_DOCKER_ECARTE" ]] \
      || p_warn "DOCKER_HOST=$PROV_DOCKER_ECARTE ne répond pas : le daemon retenu est celui de la socket par défaut, $PROV_DOCKER_HOST"
  else
    [[ "$PROV_DOCKER_DENIED" != "1" ]] || docker=refuse
    if [[ "$PROV_SUBSTRATE" == "wsl" ]]; then
      p_fail "$PROV_DOCKER_WHY — sans docker la forge de LCARS n'a aucune forme : 63-forge-tokens et 66-deck-oidc ne convergeront pas"
    else
      p_warn "$PROV_DOCKER_WHY"
    fi
  fi
  p_fact docker "$docker"
  p_fact docker_bin "$PROV_DOCKER_BIN"
  p_fact docker_host "$PROV_DOCKER_HOST"
  p_fact docker_host_ecarte "$PROV_DOCKER_ECARTE"
  p_fact docker_server "${serveur%%|*}"
  p_fact docker_flavor "$saveur"
  p_fact docker_why "$PROV_DOCKER_WHY"

  local compose=sans-objet
  if [[ "$docker" == oui ]]; then
    if docker_compose_cmd "$PROV_DOCKER_BIN"; then
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

  # ─── L'instance : ce qu'elle porte déjà ───────────────────────────────────────────────────────
  if [[ "$PROV_SUBSTRATE" == "docker" ]]; then
    p_fact apt_installs sans-objet
  elif faits_attendus; then
    local naissance; naissance="$(stat -c %W / 2>/dev/null || true)"
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
}

# ─── La déclaration d'un Linux dédié ────────────────────────────────────────────────────────────
mesure_declaration() {
  if [[ "$PROV_SUBSTRATE" != "linux" ]]; then
    p_fact consent sans-objet
  elif [[ -n "${LCARS_ALLOW_ANY_HOST:-}" ]]; then
    p_fact consent env
    p_warn "Linux natif déclaré dédié (LCARS_ALLOW_ANY_HOST) — ce provisionnement possède la machine et n'a pas de désinstalleur"
  elif [[ -e "$PROV_CHANNEL_FILE" ]]; then
    # la déclaration a été faite à la pose : une machine posée est dédiée
    p_fact consent posee
    p_ok "Linux natif posé par LCARS ($PROV_CHANNEL_FILE) — la machine a été déclarée dédiée à sa pose"
  else
    p_fact consent none
    p_fail "Linux natif sans déclaration : LCARS s'installe sur un terrain dédié, qu'il possède (/etc, $PROV_ROOT, groupes, comptes) et qui se refait plutôt qu'il ne se désinstalle. Pour déclarer cette machine dédiée : LCARS_ALLOW_ANY_HOST=1. Sinon : une distribution WSL2, ou le conteneur (bash install.sh)"
  fi
}

# ─── Le canal : qui a posé le produit, et ce que cet arbre poserait ─────────────────────────────
# le fichier de canal est 0644 dans /etc/lcars 0755 (system.manifest) : le compte de l'opérateur le lit
mesure_canal() {
  local ici; ici="$(prov_channel_here)"
  p_fact channel_tree "$ici"
  p_fact revision "$PROV_SOURCE_REV"
  # appel nu : le p_fail d'un canal illisible doit compter dans le verdict
  local canal=invalide
  if prov_channel >/dev/null; then canal="$PROV_CHANNEL"; fi
  p_fact channel "$canal"
  case "$canal" in
    aucun)    p_ok "aucun canal d'installation ($PROV_CHANNEL_FILE absent) — machine jamais posée ; cet arbre poserait « $ici »" ;;
    "$ici")   p_ok "canal d'installation : $canal ($PROV_CHANNEL_FILE)" ;;
    invalide) ;;
    *)        p_fail "cette machine est installée par « $canal », et cet arbre poserait « $ici » — un canal ne se pose pas sur un autre : mise à jour par le même canal ($([[ "$canal" == kit ]] && echo "deploy/workstation up --from <kit.tar.gz>" || echo "deploy/workstation up, depuis un checkout")), ou refaire le terrain, il est jetable" ;;
  esac
}

# ─── Les ports ──────────────────────────────────────────────────────────────────────────────────
# le deck est toujours à ce projet, la forge quand elle est celle du poste ; le port SSH n'est publié que par le conteneur
port_du_projet() { [[ "$1" == deck || ( "$1" == forge && "$PROV_FORGE_DU_POSTE" -eq 1 ) ]]; }

# en root, seul ce projet tient ses ports : ses conteneurs, que docker dit « nous », et le deck par la
# landing de cette machine
ETAT_VERIFIE=""
verifier_port() { # verifier_port <nom> <port> → ETAT_VERIFIE ; un FAIL si un autre que ce projet tient le port
  local nom="$1" port="$2" tenant
  ETAT_VERIFIE="$(port_state "$port" "${MIENS[@]}")"
  case "$ETAT_VERIFIE" in
    libre|nous*) return 0 ;;
    pris)
      ETAT_VERIFIE="pris sans processus visible"
      if [[ "$PROV_SUBSTRATE" == wsl ]]; then
        p_fail "port $port ($nom) écouté sans processus visible, même pour root : sous WSL2 le réseau est partagé, une autre distribution ou Windows le tient — relancer avec --port-$nom <autre port>, ou arrêter ce qui l'écoute dans l'autre distribution"
      else
        p_fail "port $port ($nom) écouté sans processus visible, même pour root — relancer avec --port-$nom <autre port>"
      fi
      return 0 ;;
  esac
  tenant="${ETAT_VERIFIE#pris par }"
  if [[ "$nom" == deck ]] && landing_tient "$tenant"; then
    ETAT_VERIFIE="nous lcars-landing (service)"
    return 0
  fi
  p_fail "port $port ($nom) tenu par $tenant — ce projet doit être seul à le tenir : relancer avec --port-$nom <autre port>, ou arrêter ce qui le tient"
}

# sans privilège, ss ne nomme pas le processus d'un autre compte : ce port est tenu, son propriétaire attend root
mesure_ports() {
  local nom port etat
  for nom in forge deck ssh; do
    port="$(port_de "$nom")"
    if [[ "$PROV_PHASE" != sans-privilege ]] && port_du_projet "$nom"; then
      verifier_port "$nom" "$port"; etat="$ETAT_VERIFIE"
    elif [[ "$PROV_PHASE" == root ]]; then
      continue
    else
      etat="$(port_state "$port" "${MIENS[@]}")"
      if [[ "$PROV_PHASE" == sans-privilege && "$etat" == pris ]]; then
        etat=tenu
      elif [[ "$etat" == pris* ]]; then
        p_warn "port $port ($nom) $etat"
      fi
    fi
    p_fact "port_$nom" "$port $etat"
  done
}

# ─── Les projets compose ────────────────────────────────────────────────────────────────────────
# la forge et le runner que 48 et 49 ont montés pour ce poste ne sont pas ceux d'un autre déploiement ;
# le mode de la forge vit sous le dossier des jetons, que root seul traverse
mesure_projets() {
  local nom pris="" etrangers=""
  if [[ "$DOCKER_REPOND" -eq 1 ]]; then
    for nom in "${MIENS[@]}"; do
      [[ -z "$("$PROV_DOCKER_BIN" ps -a --filter "label=com.docker.compose.project=$nom" -q 2>/dev/null)" ]] || pris="${pris:+$pris,}$nom"
    done
  fi
  p_fact projet "$PROV_FORGE_BASE"
  p_fact projet_pris "$pris"
  [[ "$PROV_PHASE" != sans-privilege ]] || return 0
  for nom in ${pris//,/ }; do
    [[ "$(head -n1 "$PROV_FORGE_MODE_FILE" 2>/dev/null)" == poste \
       && ( "$nom" == "$PROV_FORGE_PROJECT" || "$nom" == "$PROV_RUNNER_PROJECT" ) ]] || etrangers="${etrangers:+$etrangers,}$nom"
  done
  p_fact projet_etranger "$etrangers"
  if [[ -n "$etrangers" ]]; then
    p_warn "projet compose déjà présent sur ce daemon, d'un autre déploiement : $etrangers"
  elif [[ -n "$pris" ]]; then
    p_ok "projet compose de la forge de ce poste présent : $pris"
  fi
}

# ─── L'écriture sous la racine ──────────────────────────────────────────────────────────────────
# les bascules de dossiers ont lieu sous PROV_ROOT : root écrit et échange deux dossiers sur son système
# de fichiers, sous son parent quand il est le même, pour que la date de la racine posée ne bouge pas
mesure_echange() {
  local sous echange="" ou
  sous="$(ancetre_existant "$PROV_ROOT")"
  if [[ "$sous" == "$PROV_ROOT" && "$(stat -c %d "$PROV_ROOT")" == "$(stat -c %d "$(dirname "$PROV_ROOT")")" ]]; then
    sous="$(dirname "$PROV_ROOT")"
  fi
  ou="$sous"; [[ "$sous" != "$PROV_ROOT" ]] || ou="$sous (point de montage : la sonde y écrit, sa date change)"
  if ! echange="$(mktemp -d "$sous/.prov-echange.XXXXXX" 2>/dev/null)"; then
    p_fact echange "$sous non-inscriptible"
    p_fail "$ou n'est pas inscriptible par root — la racine de LCARS ne s'y pose pas (système de fichiers en lecture seule ?)"
  elif mkdir "$echange/a" "$echange/b" && mv --exchange -T -- "$echange/a" "$echange/b" 2>/dev/null; then
    p_fact echange "$sous oui"
    p_ok "« mv --exchange » joué sous $ou : les bascules de dossiers ont une forme atomique"
  else
    p_fact echange "$sous non"
    p_fail "« mv --exchange » refusé sous $ou (coreutils 9.5, sur un système de fichiers qui sait échanger) — les bascules de dossiers n'ont pas de forme atomique"
  fi
  [[ -z "$echange" ]] || rm -rf -- "$echange"
}

check() {
  PROV_PHASE="${PROV_PHASE:-entier}"
  p_fact phase "$PROV_PHASE"
  if [[ "$PROV_PHASE" != root ]]; then
    mesure_sans_privilege
  elif docker_endpoint; then
    DOCKER_REPOND=1
  fi
  mesure_declaration
  mesure_canal
  mesure_ports
  mesure_projets
  [[ "$PROV_PHASE" == sans-privilege ]] || mesure_echange
}

# le préflight ne pose rien : les deux verbes sondent, chacun rend le verdict de son contrat
case "${1:-}" in check|apply) check; "verdict_$1" ;; *) p_die "mode inconnu: ${1:-} (check|apply)" ;; esac
