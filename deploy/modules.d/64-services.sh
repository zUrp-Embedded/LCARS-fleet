#!/usr/bin/env bash
# SOURCE: deploy/modules.d/64-services.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: les services de la machine — l'environnement des daemons, l'uid du siège, les unités systemd (ou, en conteneur, le superviseur), une passe du convergeur d'humains
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
# AFTER: 62-runtime-helpers

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

SYSTEMD_DIR="${LCARS_SYSTEMD_DIR:-/etc/systemd/system}"
SERVICES_ENV="${LCARS_SERVICES_ENV:-/etc/lcars/services.env}"
# ce que lit la garde du siège dans le shell d'un humain : hors de services.env, que seuls les daemons chargent
SEAT_UID_FILE="${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}"
SYSTEMCTL="${LCARS_SYSTEMCTL:-systemctl}"
HELPERS_DIR="${LCARS_HELPERS_DIR:-$PROV_ROOT}"
SERVICES_OWNER="${LCARS_SERVICES_OWNER:-root:root}"
AUTHORITY_USER="$PROV_AUTHORITY_USER"
SETTLE_SECS="${LCARS_SERVICES_SETTLE:-12}"

UNITS=(lcars-landing lcars-converger lcars-catalogue lcars-privileged)
# programme → unité ; en conteneur, sans unités, c'est le programme que le superviseur tient qui se sonde
STARTERS=(
  "human-converger.sh:unit:lcars-converger"
  "console-landing.sh:unit:lcars-landing"
  "console.sh:driven-by:lcars-converger"
  "catalogue-executor.py:unit:lcars-catalogue"
  "privileged-executor.py:unit:lcars-privileged"
)

# /run/systemd/system n'existe que si systemd est l'init (sd_booted) : systemctl et /etc/systemd/system existent aussi dans une image sans lui
SYSTEMD_RUN="${LCARS_SYSTEMD_RUN:-/run/systemd/system}"
have_systemd() { [[ -d "$SYSTEMD_RUN" ]] && command -v "$SYSTEMCTL" >/dev/null 2>&1; }

consequence_of() { # consequence_of <unité> — ce que coûte son absence
  case "$1" in
    lcars-landing)    echo "personne ne peut entrer" ;;
    lcars-converger)  echo "personne ne sera enrôlé" ;;
    lcars-catalogue)  echo "« lcars catalogue install » refusera, en nommant ce service" ;;
    lcars-privileged) echo "les gestes privilégiés du conteneur n'ont plus d'exécutant" ;;
    *)                echo "conséquence non déclarée pour cette unité" ;;
  esac
}

# le conteneur tient ses services par supervise.sh ; pendant le boot (superviseur absent) l'état vérifiable est « en place »
check_container_services() {
  local dir="${LCARS_HELPERS_DIR:-$PROV_ROOT}" sup
  local e prog rel unit sup_vivant=0
  sup="${LCARS_SUPERVISE_BIN:-$dir/supervise.sh}"
  if [[ -x "$sup" ]]; then
    p_ok "superviseur posé ($sup) — ce que « Restart= » fait sur un poste"
  else
    p_drift "superviseur absent ($sup) — un service qui tombe ne reviendrait pas"
  fi
  pgrep -f "$(prov_pgrep_pattern "$sup")" >/dev/null 2>&1 && sup_vivant=1
  for e in "${STARTERS[@]}"; do
    IFS=: read -r prog rel unit <<<"$e"
    [[ "$rel" == "unit" ]] || continue
    if [[ ! -x "$dir/$prog" ]]; then
      p_drift "$unit : « $prog » absent ou pas exécutable ($dir/$prog) — $(consequence_of "$unit")"
    elif pgrep -f "$(prov_pgrep_pattern "$prog")" >/dev/null 2>&1; then
      p_ok "$unit : « $prog » tenu par le superviseur"
    elif [[ "$sup_vivant" -eq 1 ]]; then
      p_drift "$unit : « $prog » en place mais muet alors que le superviseur tourne — $(consequence_of "$unit")"
    else
      p_ok "$unit : « $prog » en place — l'entrypoint le démarre après cette convergence"
    fi
  done
}

restarts_of() { "$SYSTEMCTL" show -p NRestarts --value "$1.service" 2>/dev/null; }

loop_hint() { # loop_hint <unité> — pourquoi elle boucle, dans les termes de l'opérateur
  case "$1" in
    lcars-landing)
      if port_taken "$PROV_DECK_PORT"; then
        echo "le port $PROV_DECK_PORT est déjà pris sur cette machine — relancer avec « --port-deck <autre port> »"
        return 0
      fi ;;
  esac
  echo "« journalctl -u $1.service » dit pourquoi"
}

unit_cause() { # unit_cause <unité> → « — <cause> », la dernière erreur du journal quand systemd la garde
  local u="$1" hint line
  hint="$(loop_hint "$u")"
  line="$($SYSTEMCTL --version >/dev/null 2>&1 \
    && journalctl -u "$u.service" -n 30 --no-pager 2>/dev/null \
       | grep -oE '(OSError|Error|error|Errno [0-9]+)[^"]*' | tail -1 || true)"
  if [[ -n "$line" ]]; then
    printf ' — %s (journal : %s)' "$hint" "$line"
  else
    printf ' — %s' "$hint"
  fi
}

forge_url() { # forge_url → vide tant que 48-forge-host n'a pas annoncé d'adresse
  local f="$PROV_TOKENS_DIR/forge.url"
  if [[ -r "$f" ]]; then head -n1 "$f" | tr -d '[:space:]'; fi
}

# tout ce qu'un daemon lit et que l'installateur décide voyage par ici ; aucun défaut : la lib pose ces variables avant tout module
services_env_body() {
  echo "# Généré par 64-services.sh — l'environnement des services LCARS de cette machine."
  echo "# Un daemon n'hérite d'aucun shell : ce qu'il lui faut est ici, dérivé du provisionnement."
  echo "FORGE_BASE_URL=$(forge_url)"
  echo "LCARS_FORGE_ORG=$PROV_FORGE_ORG"
  echo "LCARS_HUMANS_TEAM=$PROV_HUMANS_TEAM"
  echo "LCARS_FLEET_GROUP=$PROV_FLEET_GROUP"
  echo "LCARS_SYSADMIN_UID=$LCARS_SYSADMIN_UID"
  echo "LCARS_LANDING_PORT=$PROV_DECK_PORT"
  echo "LCARS_MASTER_TOKEN_FILE=$PROV_MASTER_TOKEN_FILE"
  # Le jeton du compte SYSTEME voyage lui aussi : la porte de dépôt écrit sur la forge avec lui,
  # pendant que le master ne sert qu'aux questions d'autorité. Deux jetons, deux usages, un seul
  # chemin déclaré de chaque côté.
  echo "LCARS_SYSTEM_TOKEN_FILE=$PROV_SYSTEM_TOKEN_FILE"
  # La boîte de dépôt : le deck écrit dans la zone de transit, la porte y lit et cherche l'org du
  # projet parmi les catalogues installés. Deux daemons, une seule valeur pour chaque chemin.
  echo "LCARS_DEPOSIT_SPOOL=$PROV_DEPOSIT_SPOOL"
  echo "LCARS_CATALOGUES_DIR=$PROV_CATALOGUES_DIR"
  echo "LCARS_UID_MAP_FILE=$PROV_UID_MAP_FILE"
  echo "LCARS_CONSOLE_GROUP=$PROV_CONSOLE_GROUP"
  echo "LCARS_SYSTEM_ACCOUNT=$PROV_SYSTEM_ACCOUNT"
  echo "LCARS_ROLES=\"$PROV_ROLES\""
}

# pas de User= : la landing se dépose elle-même (setpriv) et garde ainsi le groupe lcars-console qui traverse les sockets
unit_body() { # unit_body <nom sans .service>
  case "$1" in
    lcars-landing)
      cat <<EOF
[Unit]
Description=LCARS — l'accueil web (deck) sur :$PROV_DECK_PORT
Documentation=file://$HELPERS_DIR/console-landing.sh
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5
[Service]
Type=simple
EnvironmentFile=-$SERVICES_ENV
ExecStart=$HELPERS_DIR/console-landing.sh --foreground
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
      ;;
    lcars-converger)
      cat <<EOF
[Unit]
Description=LCARS — la team humans de la forge vers les comptes Unix de cette machine
Documentation=file://$HELPERS_DIR/human-converger.sh
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5
[Service]
Type=simple
EnvironmentFile=-$SERVICES_ENV
ExecStart=$HELPERS_DIR/human-converger.sh
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
      ;;
    lcars-catalogue)
      cat <<EOF
[Unit]
Description=LCARS — installe un catalogue pour un admin de la forge, sans jamais lui donner le jeton
Documentation=file://$HELPERS_DIR/catalogue-executor.py
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
EnvironmentFile=-$SERVICES_ENV
User=$AUTHORITY_USER
ExecStart=/usr/bin/env python3 $HELPERS_DIR/catalogue-executor.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
      ;;
    lcars-privileged)
      cat <<EOF
[Unit]
Description=LCARS — l'unique geste privilégié de la machine, et il ne détient aucun secret
Documentation=file://$HELPERS_DIR/privileged-executor.py
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
EnvironmentFile=-$SERVICES_ENV
ExecStart=/usr/bin/env python3 $HELPERS_DIR/privileged-executor.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
      ;;
    *) return 1 ;;
  esac
}
unit_path() { echo "$SYSTEMD_DIR/$1.service"; }
unit_current() { # unit_current <unité> → 0 si l'unité posée est identique à ce qui serait généré
  local u="$1"
  [[ -f "$(unit_path "$u")" ]] || return 1
  diff -q <(unit_body "$u") "$(unit_path "$u")" >/dev/null 2>&1
}

# une machine neuve n'a aucun humain, et c'est nominal : les gens s'enrôlent sur la forge — dit, pas compté
probe_fleet_humans() {
  local found; found="$(fleet_humans | paste -sd' ' -)"
  p_fact fleet_humans "$found"
  if [[ -n "$found" ]]; then
    p_ok "humain(s) de fleet sur cette machine : $found"
  else
    p_warn "aucun humain de fleet sur cette machine — « fleet start » n'aura personne pour le lancer tant que quelqu'un ne s'est pas enrôlé sur la forge (team « $PROV_HUMANS_TEAM », le convergeur le matérialise au tour suivant). Ce n'est pas une dérive : un déploiement neuf attend son premier inscrit"
  fi
}

# l'uid déclaré se vérifie contre les comptes, pas contre une re-dérivation (un second sudoer rendrait une dérive fausse)
probe_seat_uid() {
  local declared name
  declared="$(env_field "$SERVICES_ENV" LCARS_SYSADMIN_UID)"
  if [[ -z "$declared" ]]; then
    local _st; _st="$(prov_file_state "$SERVICES_ENV")"
    if [[ "$_st" != "present" && "$_st" != "absent" ]]; then
      p_warn "LCARS_SYSADMIN_UID non sondable — $SERVICES_ENV $(prov_state_why "$_st" "$SERVICES_ENV")"
      return 0
    fi
    p_drift "aucun LCARS_SYSADMIN_UID dans $SERVICES_ENV — sans siège déclaré, is_fleet_human répond non à tout le monde et le convergeur refuse de démarrer (la garde du siège, lui, lit $SEAT_UID_FILE et refuse s'il manque)"
    return 0
  fi
  name="$(getent passwd "$declared" 2>/dev/null | cut -d: -f1 || true)"
  if [[ -z "$name" ]]; then
    p_drift "LCARS_SYSADMIN_UID=$declared ne correspond a AUCUN compte de cette machine — la garde du siège réserve un uid que personne ne porte, donc il ne réserve rien"
  else
    p_ok "siege : « $name » (uid $declared) — la garde du siège lui interdit de lancer une fleet"
  fi
}

probe_seat_file() {
  local v name
  if [[ ! -r "$SEAT_UID_FILE" ]]; then
    p_drift "$SEAT_UID_FILE absent — la garde du siège (« $PROV_LINK_DIR/fleet » et son miroir BEAM) refusera tout lancement : sans ce fichier, aucun des deux ne peut établir le siège"
    return 0
  fi
  v="$(head -n1 -- "$SEAT_UID_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ ! "$v" =~ ^[0-9]+$ ]]; then
    p_drift "$SEAT_UID_FILE ne porte pas un uid (« $v ») — les deux gardes refuseront un lancement qu'ils ne peuvent pas vérifier"
    return 0
  fi
  local declared
  declared="$(env_field "$SERVICES_ENV" LCARS_SYSADMIN_UID)"
  if [[ -n "$declared" && "$declared" != "$v" ]]; then
    p_fail "$SEAT_UID_FILE dit $v et $SERVICES_ENV dit $declared — la garde du siège et uid_floor ne réservent pas le même uid ; le convergeur créerait des humains sur celui que la garde refuse"
    return 0
  fi
  name="$(getent passwd "$v" 2>/dev/null | cut -d: -f1 || true)"
  if [[ -n "$name" ]]; then
    p_ok "la garde du siège lit $SEAT_UID_FILE → uid $v (« $name »)"
  else
    p_drift "$SEAT_UID_FILE dit $v, uid qu'aucun compte ne porte — la garde réserve un siège absent"
  fi
}

check() {
  local u
  probe_fleet_humans
  if [[ "${PROV_SUBSTRATE:-}" == "docker" ]]; then
    check_container_services
    verdict_check
  fi
  if ! have_systemd; then
    p_warn "pas de systemd ici ($SYSTEMCTL absent, ou systemd n'est pas l'init : /run/systemd/system) — aucune unité posée. Sur WSL, « wsl --shutdown » puis un nouvel onglet l'active (30-wsl)"
    verdict_check
  fi
  if [[ -s "$SERVICES_ENV" ]]; then
    p_ok "environnement des services posé ($SERVICES_ENV)"
  else
    p_drift "environnement des services absent ($SERVICES_ENV) — les daemons démarreraient sans savoir où est la forge"
  fi
  probe_seat_uid
  probe_seat_file
  for u in "${UNITS[@]}"; do
    if ! unit_current "$u"; then
      p_drift "$(unit_path "$u") absente ou divergente"
      continue
    fi
    if "$SYSTEMCTL" is-active --quiet "$u.service" 2>/dev/null; then
      p_ok "$u.service actif"
    else
      p_drift "$u.service posé mais pas actif — $(consequence_of "$u")"
    fi
  done
  verdict_check
}

apply() {
  local u
  [[ -n "${LCARS_SYSADMIN_UID:-}" ]] || {
    p_fail "LCARS_SYSADMIN_UID non posé — « deploy/provision » le dérive du siège avant tout module. Sans lui, l'environnement des daemons s'écrirait sans la clé que lisent is_fleet_human et le convergeur"
    verdict_apply
  }
  # le siège et l'environnement se posent avant la porte systemd : au premier apply d'un WSL vierge, systemd n'est pas encore l'init
  ensure_dir "$(dirname "$SERVICES_ENV")" 0755 "$SERVICES_OWNER" || verdict_apply
  local env_body env_avant env_change=0
  env_body="$(services_env_body)" \
    || { p_fail "environnement des services non calculable — l'écriture est abandonnée, pas tronquée"; verdict_apply; }
  env_avant="$(cat "$SERVICES_ENV" 2>/dev/null || true)"
  [[ "$env_avant" == "$env_body" ]] || env_change=1
  write_atomic "$SERVICES_ENV" 0640 "${SERVICES_OWNER%%:*}:$PROV_FLEET_GROUP" <<<"$env_body" \
    || { p_fail "environnement des services non posé ($SERVICES_ENV)"; verdict_apply; }
  write_atomic "$SEAT_UID_FILE" 0644 "$SERVICES_OWNER" <<<"$LCARS_SYSADMIN_UID" \
    || { p_fail "uid du siège non posé ($SEAT_UID_FILE) — la garde du siège refusera tout lancement sur cette machine"; verdict_apply; }
  if ! have_systemd; then
    p_warn "pas de systemd ici ($SYSTEMCTL absent, ou systemd n'est pas l'init : /run/systemd/system) — le siège et l'environnement sont posés, aucune unité ne l'est. Sur WSL, « wsl --shutdown » puis un nouvel onglet l'active (30-wsl)"
    verdict_apply
  fi

  local reload=0 body
  local -a reecrites=()
  for u in "${UNITS[@]}"; do
    # un daemon debout garde l'environnement de son démarrage : un services.env changé le relance aussi
    if unit_current "$u"; then
      [[ "$env_change" -eq 1 ]] && "$SYSTEMCTL" is-active --quiet "$u.service" 2>/dev/null && reecrites+=("$u")
      continue
    fi
    body="$(unit_body "$u")" \
      || { p_fail "unité inconnue: $u — aucun fichier écrit"; verdict_apply; }
    if [[ -f "$(unit_path "$u")" ]] && "$SYSTEMCTL" is-active --quiet "$u.service" 2>/dev/null; then reecrites+=("$u"); fi
    write_atomic "$(unit_path "$u")" 0644 "$SERVICES_OWNER" <<<"$body" \
      || { p_fail "unité non posée: $(unit_path "$u")"; verdict_apply; }
    reload=1
  done
  [[ "$reload" -eq 1 ]] && { "$SYSTEMCTL" daemon-reload || p_warn "daemon-reload en échec"; }
  local -a was=()
  local i n n2
  for u in "${UNITS[@]}"; do
    was+=("$(restarts_of "$u")")
    "$SYSTEMCTL" enable --now "$u.service" >/dev/null 2>&1 \
      || p_fail "$u.service n'a pas démarré — « $SYSTEMCTL status $u.service » et « journalctl -u $u.service » disent pourquoi"
  done
  for u in "${reecrites[@]}"; do
    if "$SYSTEMCTL" try-restart "$u.service" >/dev/null 2>&1 && "$SYSTEMCTL" is-active --quiet "$u.service" 2>/dev/null; then
      p_chg "$u.service relancé sur l'unité ou l'environnement réécrit"
    else
      p_warn "$u.service : relance sur l'unité réécrite sans service debout derrière — le verdict ci-dessous le mesure"
    fi
  done
  if [[ "$SETTLE_SECS" -gt 0 ]]; then sleep "$SETTLE_SECS"; fi
  for i in "${!UNITS[@]}"; do
    u="${UNITS[$i]}"
    n="$(restarts_of "$u")"
    if [[ "$SETTLE_SECS" -gt 0 ]]; then sleep 2; fi
    n2="$(restarts_of "$u")"
    if [[ "${n2:-0}" -gt "${n:-0}" ]]; then
      p_fail "$u.service redémarre en boucle — $(loop_hint "$u")"
    elif "$SYSTEMCTL" is-active --quiet "$u.service"; then
      if [[ "${n2:-0}" -gt "${was[$i]:-0}" ]]; then
        p_chg "$u.service debout, après $(( ${n2:-0} - ${was[$i]:-0} )) redémarrage(s) — il a attendu quelque chose"
      else
        p_chg "$u.service activé et debout"
      fi
    else
      p_fail "$u.service posé mais pas debout$(unit_cause "$u")"
    fi
  done
  converge_humans_now
  verdict_apply
}

# une passe du convergeur dans l'environnement du daemon (env -i + services.env), pas celui de l'apply ; --once rend 1 sur dépendance absente, 2 sur configuration absente
converge_humans_now() {
  local conv="${LCARS_HUMAN_CONVERGER:-$HELPERS_DIR/human-converger.sh}"
  [[ -x "$conv" ]] || { p_warn "convergeur d'humains absent ($conv) — aucun humain ne sera matérialisé par cette passe"; return 0; }
  local avant apres nouveaux
  avant="$(fleet_humans | sort -u)"
  local rc=0
  # shellcheck disable=SC2016 # $1 et $2 sont les arguments du bash interne
  run_step --ok 1 --ok 2 "convergence des humains (une passe)" -- \
    env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
    bash -c 'set -a; . "$1"; set +a; exec "$2" --once' _ "$SERVICES_ENV" "$conv" || rc=$?
  [[ "$rc" -eq 0 ]] || return 0
  case "$PROV_LAST_RC" in
    0) ;;
    2) p_drift "convergeur d'humains : configuration absente (forge ou jeton système) — aucun humain n'est matérialisé, et « fleet start » n'aura personne à lancer"
       return 0 ;;
    *) p_drift "convergeur d'humains : passe en échec (rc=$PROV_LAST_RC) — « journalctl -u lcars-converger » dit pourquoi"
       return 0 ;;
  esac
  apres="$(fleet_humans | sort -u)"
  nouveaux="$(set_diff "$avant" "$apres")"
  local liste_new liste_all
  liste_new="$(printf '%s' "$nouveaux" | paste -sd' ' -)"
  liste_all="$(printf '%s' "$apres" | paste -sd' ' -)"
  if [[ -n "$liste_new" ]]; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "humain(s) de fleet matérialisé(s) par cette passe : $liste_new"
  elif [[ -n "$liste_all" ]]; then
    p_ok "humain(s) de fleet déjà présent(s) : $liste_all — cette passe n'en a matérialisé aucun de plus"
  else
    p_ok "aucun humain à matérialiser — la team « $PROV_HUMANS_TEAM » de la forge est vide. Ce n'est pas une faute : les gens s'enrôlent sur la forge, un propriétaire les ajoute à la team, et le convergeur les matérialise au tour suivant"
  fi
}

case "${1:?usage: 64-services.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
