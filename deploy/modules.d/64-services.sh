#!/usr/bin/env bash
# SOURCE: deploy/modules.d/64-services.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: les services de la machine — l'environnement des daemons, l'uid du siège, les unités systemd (ou, en conteneur, le superviseur), une passe du convergeur d'humains
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
# AFTER: 10-packages 20-groups 21-service-accounts 25-directories 48-forge-host 60-deploy 62-runtime-helpers 63-forge-tokens

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

SYSTEMD_DIR="$(prov_decor /etc/systemd/system)"
SERVICES_ENV="$PROV_SERVICES_ENV"
# ce que lit la garde du siège dans le shell d'un humain : hors de services.env, que seuls les daemons chargent
SEAT_UID_FILE="$PROV_SEAT_UID_FILE"
SERVICES_OWNER=root:root

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
SYSTEMD_RUN="$(prov_decor /run/systemd/system)"
have_systemd() { [[ -d "$SYSTEMD_RUN" ]] && command -v systemctl >/dev/null 2>&1; }
SANS_SYSTEMD="pas de systemd ici (systemctl absent, ou systemd n'est pas l'init : /run/systemd/system) — aucune unité n'est posée. Sur WSL, « wsl --shutdown » puis un nouvel onglet l'active (30-wsl)"

consequence_of() { # consequence_of <unité> — ce que coûte son absence
  case "$1" in
    lcars-landing)    echo "personne ne peut entrer" ;;
    lcars-converger)  echo "personne ne sera enrôlé" ;;
    lcars-catalogue)  echo "« lcars catalogue install » refusera, en nommant ce service" ;;
    lcars-privileged) echo "les gestes privilégiés du conteneur n'ont plus d'exécutant" ;;
  esac
}

# le conteneur tient ses services par supervise.sh ; pendant son boot (superviseur absent) l'état vérifiable est « en place »
check_container_services() {
  local sup="$PROV_ROOT/supervise.sh"
  local e prog rel unit sup_vivant=0
  if [[ -x "$sup" ]]; then
    p_ok "superviseur posé ($sup) — ce que « Restart= » fait sur un poste"
  else
    p_drift "superviseur absent ($sup) — un service qui tombe ne reviendrait pas"
  fi
  pgrep -f "$(prov_pgrep_pattern "$sup")" >/dev/null 2>&1 && sup_vivant=1
  for e in "${STARTERS[@]}"; do
    IFS=: read -r prog rel unit <<<"$e"
    [[ "$rel" == "unit" ]] || continue
    if [[ ! -x "$PROV_ROOT/$prog" ]]; then
      p_drift "$unit : « $prog » absent ou pas exécutable ($PROV_ROOT/$prog) — $(consequence_of "$unit")"
    elif pgrep -f "$(prov_pgrep_pattern "$prog")" >/dev/null 2>&1; then
      p_ok "$unit : « $prog » tenu par le superviseur"
    elif [[ "$sup_vivant" -eq 1 ]]; then
      p_drift "$unit : « $prog » en place mais muet alors que le superviseur tourne — $(consequence_of "$unit")"
    else
      p_ok "$unit : « $prog » en place — le boot du conteneur le lance sous son superviseur"
    fi
  done
}

restarts_of() { systemctl show -p NRestarts --value "$1.service" 2>/dev/null; }

loop_hint() { # loop_hint <unité> — pourquoi elle boucle, dans les termes de l'opérateur
  if [[ "$1" == lcars-landing ]] && port_taken "$PROV_DECK_PORT"; then
    echo "le port $PROV_DECK_PORT est déjà pris sur cette machine — relancer avec « --port-deck <autre port> »"
    return 0
  fi
  echo "« journalctl -u $1.service » dit pourquoi"
}

unit_cause() { # unit_cause <unité> → « — <cause> », la dernière erreur du journal quand systemd la garde
  local u="$1" hint line
  hint="$(loop_hint "$u")"
  line="$(journalctl -u "$u.service" -n 30 --no-pager 2>/dev/null \
       | grep -oE '(OSError|Error|error|Errno [0-9]+)[^"]*' | tail -1 || true)"
  if [[ -n "$line" ]]; then
    printf ' — %s (journal : %s)' "$hint" "$line"
  else
    printf ' — %s' "$hint"
  fi
}

forge_url() { # forge_url → vide tant que 48-forge-host n'a pas annoncé d'adresse
  if [[ -r "$PROV_FORGE_URL_FILE" ]]; then head -n1 "$PROV_FORGE_URL_FILE" | tr -d '[:space:]'; fi
}

# tout ce qu'un daemon lit et que l'installateur décide voyage par ici ; aucun défaut : la lib pose ces variables avant tout module
services_env_body() {
  echo "# Généré par 64-services.sh — l'environnement des services LCARS de cette machine."
  echo "# Un daemon n'hérite d'aucun shell : ce qu'il lui faut est ici, dérivé du provisionnement."
  echo "FORGE_BASE_URL=$(forge_url)"
  echo "LCARS_FORGE_ORG=$PROV_FORGE_ORG"
  echo "LCARS_OPS_REPO=$PROV_OPS_REPO"
  echo "LCARS_HUMANS_TEAM=$PROV_HUMANS_TEAM"
  echo "LCARS_FLEET_GROUP=$PROV_FLEET_GROUP"
  echo "LCARS_SYSADMIN_UID=$LCARS_SYSADMIN_UID"
  echo "LCARS_LANDING_PORT=$PROV_DECK_PORT"
  echo "LCARS_MASTER_TOKEN_FILE=$PROV_MASTER_TOKEN_FILE"
  echo "LCARS_UID_MAP_FILE=$PROV_UID_MAP_FILE"
  echo "LCARS_CONSOLE_GROUP=$PROV_CONSOLE_GROUP"
  echo "LCARS_SYSTEM_ACCOUNT=$PROV_SYSTEM_ACCOUNT"
  echo "LCARS_ROLES=\"$PROV_ROLES\""
  echo "LCARS_CATALOGUES_WORK=$PROV_CATALOGUES_WORK"
  echo "LCARS_STORE_ROOT=$PROV_STORE_ROOT"
  echo "TF_CLI_CONFIG_FILE=$PROV_TOFU_RC"
}

# une unité est un gabarit : chaque bras pose ce qui la distingue. Pas de User= pour la landing : elle se
# dépose elle-même (setpriv) et garde ainsi le groupe lcars-console qui traverse les sockets
unit_body() { # unit_body <nom sans .service>
  local desc exec restart=5 borne=1 user="" doc
  case "$1" in
    lcars-landing)
      desc="l'accueil web (deck) sur :$PROV_DECK_PORT"
      exec="ExecStart=$PROV_ROOT/console-landing.sh --foreground"
      ;;
    lcars-converger)
      desc="la team humans de la forge vers les comptes Unix de cette machine"
      exec="ExecStart=$PROV_ROOT/human-converger.sh"; restart=10
      ;;
    lcars-catalogue)
      desc="installe un catalogue pour un admin de la forge, sans jamais lui donner le jeton"
      exec="ExecStart=/usr/bin/env python3 $PROV_ROOT/catalogue-executor.py"; borne=0; user="User=$PROV_AUTHORITY_USER"
      ;;
    lcars-privileged)
      desc="l'unique geste privilégié de la machine, et il ne détient aucun secret"
      exec="ExecStart=/usr/bin/env python3 $PROV_ROOT/privileged-executor.py"; borne=0
      ;;
  esac
  doc="${exec##*/}"; doc="${doc%% *}"
  printf '[Unit]\nDescription=LCARS — %s\nDocumentation=file://%s/%s\nAfter=network-online.target\nWants=network-online.target\n' \
    "$desc" "$PROV_ROOT" "$doc"
  [[ "$borne" -eq 0 ]] || printf 'StartLimitIntervalSec=60\nStartLimitBurst=5\n'
  printf '[Service]\nType=simple\nEnvironmentFile=-%s\n' "$SERVICES_ENV"
  [[ -z "$user" ]] || printf '%s\n' "$user"
  printf '%s\nRestart=always\nRestartSec=%s\n[Install]\nWantedBy=multi-user.target\n' "$exec" "$restart"
}
unit_current() { # unit_current <unité> → 0 si l'unité posée est identique à ce qui serait généré
  [[ -f "$SYSTEMD_DIR/$1.service" ]] || return 1
  diff -q <(unit_body "$1") "$SYSTEMD_DIR/$1.service" >/dev/null 2>&1
}

# ce qu'un daemon garde de son démarrage, sous PROV_ROOT : son programme et ce qu'il source ou importe ;
# ce qu'il lance à chaque tour (console.sh, forge-gestures.sh, human.d) se relit sans relance
unit_charge() { # unit_charge <unité>
  case "$1" in
    lcars-landing)    echo console-landing.sh console-deck.py ;;
    lcars-converger)  echo human-converger.sh services/lib ;;
    lcars-catalogue)  echo catalogue-executor.py lcars_socket.py ;;
    lcars-privileged) echo privileged-executor.py lcars_socket.py ;;
  esac
}

# charge_reposee_depuis <unité> → 0 si 62 a posé, après le démarrage de l'unité, un objet qu'elle charge (62 date ce qu'il change, un objet reposé à l'identique garde sa date)
charge_reposee_depuis() {
  local debut n
  # en UTC : un fuseau local se relit mal (CST, HKT, WIB) et aucune relance n'aurait lieu
  debut="$(TZ=UTC systemctl show -p ActiveEnterTimestamp --value "$1.service" 2>/dev/null)" || return 1
  # un horodatage vide se lirait « aujourd'hui à minuit »
  [[ -n "$debut" ]] && debut="$(TZ=UTC date -d "$debut" +%s 2>/dev/null)" || return 1
  for n in $(unit_charge "$1"); do
    [[ -z "$(find "$PROV_ROOT/$n" -newermt "@$debut" -print -quit 2>/dev/null)" ]] || return 0
  done
  return 1
}

# une machine neuve n'a aucun humain, et c'est nominal : les gens s'enrôlent sur la forge — dit, pas compté
probe_fleet_humans() {
  local found pourquoi
  # une population illisible (siège ou bornes d'uid) se dit en drift avec sa cause, elle ne fait pas mourir la sonde
  if ! pourquoi="$(fleet_humans 2>&1 >/dev/null)"; then
    p_drift "humains de fleet non mesurables : ${pourquoi#fleet_humans: }"
    return 0
  fi
  found="$(fleet_humans | paste -sd' ' -)"
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
  if [[ "$PROV_SUBSTRATE" == "docker" ]]; then
    check_container_services
    verdict_check
  fi
  # le siège et l'environnement se posent sans systemd : ils se sondent sans lui
  if [[ -s "$SERVICES_ENV" ]]; then
    p_ok "environnement des services posé ($SERVICES_ENV)"
  else
    p_drift "environnement des services absent ($SERVICES_ENV) — les daemons démarreraient sans savoir où est la forge"
  fi
  probe_seat_uid
  probe_seat_file
  if ! have_systemd; then
    p_warn "$SANS_SYSTEMD"
    verdict_check
  fi
  for u in "${UNITS[@]}"; do
    if ! unit_current "$u"; then
      p_drift "$SYSTEMD_DIR/$u.service absente ou divergente"
      continue
    fi
    if systemctl is-active --quiet "$u.service" 2>/dev/null; then
      p_ok "$u.service actif"
    else
      p_drift "$u.service posé mais pas actif — $(consequence_of "$u")"
    fi
  done
  verdict_check
}

apply() {
  local u env_body env_change=0
  # le siège et l'environnement se posent avant la porte systemd : au premier apply d'un WSL vierge, systemd n'est pas encore l'init
  env_body="$(services_env_body)"
  [[ "$(cat "$SERVICES_ENV" 2>/dev/null || true)" == "$env_body" ]] || env_change=1
  write_atomic "$SERVICES_ENV" 0640 "${SERVICES_OWNER%%:*}:$PROV_FLEET_GROUP" <<<"$env_body" || verdict_apply
  write_atomic "$SEAT_UID_FILE" 0644 "$SERVICES_OWNER" <<<"$LCARS_SYSADMIN_UID" || verdict_apply
  if ! have_systemd; then
    p_warn "$SANS_SYSTEMD — le siège et l'environnement sont posés"
    verdict_apply
  fi

  local reload=0
  local -a relancer=()
  for u in "${UNITS[@]}"; do
    if systemctl is-active --quiet "$u.service" 2>/dev/null; then
      # un daemon debout garde l'unité, l'environnement et le code de son démarrage
      if ! unit_current "$u" || [[ "$env_change" -eq 1 ]] || charge_reposee_depuis "$u"; then relancer+=("$u"); fi
    fi
    unit_current "$u" && continue
    write_atomic "$SYSTEMD_DIR/$u.service" 0644 "$SERVICES_OWNER" <<<"$(unit_body "$u")" || verdict_apply
    reload=1
  done
  [[ "$reload" -eq 1 ]] && { systemctl daemon-reload || p_warn "daemon-reload en échec"; }
  # la passe précède le daemon : deux convergeurs ne tournent jamais ensemble
  converge_humans_now
  consoles_sans_locale_relancees
  for u in "${UNITS[@]}"; do
    systemctl enable --now "$u.service" >/dev/null 2>&1 \
      || p_fail "$u.service n'a pas démarré — « systemctl status $u.service » et « journalctl -u $u.service » disent pourquoi"
  done
  for u in "${relancer[@]}"; do
    if systemctl try-restart "$u.service" >/dev/null 2>&1 && systemctl is-active --quiet "$u.service" 2>/dev/null; then
      p_chg "$u.service relancé sur son unité, son environnement ou ses auxiliaires reposés"
    else
      p_warn "$u.service : relance sans service debout derrière — le verdict ci-dessous le mesure"
    fi
  done
  # un service qui boucle a le temps d'y retomber, et son compteur de relances de monter
  sleep 12
  local n
  for u in "${UNITS[@]}"; do
    n="$(restarts_of "$u")"
    sleep 2
    if [[ "$(restarts_of "$u")" -gt "${n:-0}" ]]; then
      p_fail "$u.service redémarre en boucle — $(loop_hint "$u")"
    elif systemctl is-active --quiet "$u.service"; then
      p_ok "$u.service debout"
    else
      p_fail "$u.service posé mais pas debout$(unit_cause "$u")"
    fi
  done
  probe_fleet_humans
  verdict_apply
}

# une console vivante n'est pas relancée par le convergeur : celle que la passe de l'installeur a fait naître sans
# locale (console.sh ne la posait pas encore) garde des « _ » à la place des accents ; retirée, le convergeur la relance
consoles_sans_locale_relancees() {
  local pid n=0
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    grep -qz '^LANG=' "$(prov_decor /proc)/$pid/environ" 2>/dev/null && continue
    kill "$pid" 2>/dev/null && n=$((n + 1))
  done < <(pgrep -x ttyd 2>/dev/null || true)
  [[ "$n" -eq 0 ]] || p_chg "$n console(s) nées sans locale retirée(s) — le convergeur les relance au tour suivant, avec la leur"
}

# une passe du convergeur dans l'environnement du daemon (env -i + services.env), pas celui de l'apply ; --once rend 1 sur dépendance absente, 2 sur configuration absente
converge_humans_now() {
  local conv="$PROV_ROOT/human-converger.sh"
  if systemctl is-active --quiet lcars-converger.service 2>/dev/null; then
    p_ok "convergeur d'humains debout (lcars-converger) — il réconcilie lui-même, aucune passe de plus"
    return 0
  fi
  [[ -x "$conv" ]] || { p_warn "convergeur d'humains absent ($conv) — aucun humain ne sera matérialisé par cette passe"; return 0; }
  # shellcheck disable=SC2016 # $1 et $2 sont les arguments du bash interne
  run_step --ok 1 --ok 2 "convergence des humains (une passe)" -- \
    env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
    bash -c 'set -a; . "$1"; set +a; exec "$2" --once' _ "$SERVICES_ENV" "$conv" || return 0
  case "$PROV_LAST_RC" in
    0) ;;
    2) p_drift "convergeur d'humains : configuration absente (forge ou jeton système) — aucun humain n'est matérialisé, et « fleet start » n'aura personne à lancer" ;;
    *) p_drift "convergeur d'humains : dépendance absente (rc=$PROV_LAST_RC : curl, jq, ou une passe hors root) — aucun humain n'est matérialisé par cette passe" ;;
  esac
}

case "${1:-}" in check|apply) "$1" ;; *) p_die "mode inconnu: ${1:-} (check|apply)" ;; esac
