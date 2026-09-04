#!/usr/bin/env bash
# SOURCE: deploy/modules.d/64-services.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: PROTO-V2 — ce qui doit être DEBOUT sur un poste natif : la landing et le convergeur d'humains
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
# AFTER: 21-service-accounts 25-directories 48-forge-host 62-runtime-helpers
#
# Le convergeur a besoin de `useradd` : il n'y a pas de version non privilégiée de créer un humain.
# La landing démarre en root et se DÉPOSE elle-même — `console-landing.sh` fait
# `setpriv --reuid lcars-system --regid lcars-system --groups lcars-console`, exactement comme dans
# l'image. Ne PAS mettre `User=` dans l'unité : ça retirerait au script le droit de faire ce drop,
# et surtout ça lui retirerait le groupe `lcars-console`, sans lequel il ne traverse aucune socket
# de console — la page s'ouvrirait sur une liste vide en annonçant que tout va bien.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

SYSTEMD_DIR="${LCARS_SYSTEMD_DIR:-/etc/systemd/system}"
SERVICES_ENV="${LCARS_SERVICES_ENV:-/etc/lcars/services.env}"
# ⚠ LE FICHIER QUE LIT GUARD B, ET IL N'EST PAS DANS `services.env`. Celui-ci sert les DAEMONS par
# `EnvironmentFile=` ; la garde, elle, tourne dans le shell d'un HUMAIN, qui n'herite d'aucun des
# deux. Et surtout : une garde ne peut pas prendre sa clef dans l'environnement de ce qu'elle garde
SEAT_UID_FILE="${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}"
SYSTEMCTL="${LCARS_SYSTEMCTL:-systemctl}"
HELPERS_DIR="${LCARS_HELPERS_DIR:-$PROV_ROOT}"
SERVICES_OWNER="${LCARS_SERVICES_OWNER:-root:root}"
AUTHORITY_USER="$PROV_AUTHORITY_USER"
SETTLE_SECS="${LCARS_SERVICES_SETTLE:-12}"

UNITS=(lcars-landing lcars-converger lcars-catalogue lcars-privileged)

# LA CORRESPONDANCE PROGRAMME -> UNITE, ET ELLE SERT AUX DEUX SUBSTRATS : `UNITS` nomme ce que
# systemd pose sur un poste, `STARTERS` nomme le PROGRAMME derriere chaque unite — c'est par lui
# que la boite verifie, puisqu'elle n'a pas d'unites. `driven-by` marque ce qui est lance par un
# autre service et n'a donc pas d'existence propre a sonder.
# (Elle a porte un `shellcheck disable=SC2034` tant qu'elle n'etait lue que par `process_iso.bats`.)
STARTERS=(
  "human-converger.sh:unit:lcars-converger"
  "console-landing.sh:unit:lcars-landing"
  "console.sh:driven-by:lcars-converger"
  "catalogue-executor.py:unit:lcars-catalogue"
  "privileged-executor.py:unit:lcars-privileged"
)

# ⚠ LA PRESENCE DES FICHIERS N'EST PAS LA PRESENCE DU GESTIONNAIRE. `systemctl` s'installe comme
# dependance de paquet et `/etc/systemd/system` est cree par le paquet : les deux existent dans une
# image ou PID 1 est `tini` et ou systemd ne pilote rien. Cette sonde repondait donc OUI dans la
# boite, le check depassait sa propre porte de sortie, ne trouvait aucune unite, rendait un drift —
# et `apply:check:*` le convertissait en ECHEC que nul `apply` ne pouvait reparer.
# `/run/systemd/system` est le test canonique (sd_booted(3)) : il n'existe QUE si systemd est
# l'init. Dans la boite : systemctl PRESENT, /etc/systemd/system PRESENT,
# /run/systemd/system absent, PID 1 = tini.
have_systemd() { [[ -d /run/systemd/system ]] && command -v "$SYSTEMCTL" >/dev/null 2>&1; }

# consequence_of <unite> — ce que coute son absence, dit une seule fois pour les deux substrats.
consequence_of() {
  case "$1" in
    lcars-landing)    echo "personne ne peut entrer" ;;
    lcars-converger)  echo "personne ne sera enrole" ;;
    lcars-catalogue)  echo "« lcars catalogue install » refusera, en nommant ce service" ;;
    lcars-privileged) echo "les gestes privilegies de la boite n'ont plus d'executant" ;;
    *)                echo "consequence NON DECLAREE pour cette unite — ajoute-la ici" ;;
  esac
}

# ─── LA BOITE TIENT SES SERVICES AUTREMENT, ET C'EST UN ETAT-CIBLE, PAS UNE ABSENCE ──────────────
# Le rail poste pose des unites `Restart=always` ; la boite lance `supervise.sh` depuis l'entrypoint.
# Meme promesse — un service qui tombe revient — deux mecaniques. Verifier CELLE DU POSTE sur les
# deux substrats ne mesurait rien ici et refusait le banc ; verifier celle de la boite mesure
# exactement la meme chose.
#
# La table STARTERS porte deja la correspondance programme -> unite : elle cesse d'etre decorative.
#
# ⚠ CE QUE `pgrep -f` PROUVE, ET CE QU'IL NE PROUVE PAS : le motif matche le service OU le
# superviseur qui le porte dans son argv. La promesse verifiee est donc « ce service est TENU »,
# pas « il repond a cette seconde » — c'est le pendant exact de `is-active` sur une unite
# `Restart=`, qui rend vrai pendant un RestartSec.
check_box_services() {
  local dir="${LCARS_HELPERS_DIR:-$PROV_ROOT}" sup
  local e prog rel unit sup_vivant=0
  sup="${LCARS_SUPERVISE_BIN:-$dir/supervise.sh}"
  if [[ -x "$sup" ]]; then
    p_ok "superviseur posé ($sup) — ce que « Restart= » fait sur le rail poste"
  else
    p_drift "superviseur absent ($sup) — un service qui tombe ne reviendrait pas"
  fi

  # ⚠ LA CONVERGENCE TOURNE AVANT LES SERVICES, ET C'EST L'ORDRE VOULU PAR L'ENTRYPOINT : il
  # converge, publie son verdict, PUIS lance les daemons. Exiger ici qu'ils tournent, c'est exiger
  # un etat que ce moment precis ne peut pas avoir — le check se serait refuse lui-meme a chaque
  # boot. Le superviseur vivant est donc le discriminant : absent, on est DANS le boot et l'etat
  # verifiable est « en place » ; present, on est apres, et un programme muet est un vrai drift.
  pgrep -f "$(prov_pgrep_pattern "$sup")" >/dev/null 2>&1 && sup_vivant=1

  for e in "${STARTERS[@]}"; do
    IFS=: read -r prog rel unit <<<"$e"
    [[ "$rel" == "unit" ]] || continue
    if [[ ! -x "$dir/$prog" ]]; then
      p_drift "$unit : « $prog » absent ou pas exécutable ($dir/$prog) — $(consequence_of "$unit")"
    elif pgrep -f "$(prov_pgrep_pattern "$prog")" >/dev/null 2>&1; then
      p_ok "$unit : « $prog » tenu par le superviseur"
    elif [[ "$sup_vivant" -eq 1 ]]; then
      p_drift "$unit : « $prog » en place mais MUET alors que le superviseur tourne — $(consequence_of "$unit")"
    else
      p_ok "$unit : « $prog » en place — l'entrypoint le démarre après cette convergence"
    fi
  done
}

# Le compteur de redemarrages automatiques du service — la seule mesure qu'un fork reussi ne fausse pas.
restarts_of() { "$SYSTEMCTL" show -p NRestarts --value "$1.service" 2>/dev/null; }


loop_hint() { # loop_hint <unite> — pourquoi elle boucle, dans les termes de l'operateur
  case "$1" in
    lcars-landing)
      if port_taken "$PROV_DECK_PORT"; then
        echo "le port $PROV_DECK_PORT est DEJA PRIS sur cette machine — relance avec « --port-deck <autre port> »"
        return 0
      fi ;;
  esac
  echo "« journalctl -u $1.service » dit pourquoi"
}

# ─── unit_cause <unite> — LA CAUSE, RECOPIEE, PAS DELEGUEE ──────────────────────────────────────
#
# ⚠ « status dit pourquoi » EST UN REMEDE QU'ON NE PEUT PAS TOUJOURS JOUER. Sur un rail lance en
# fond, ou depuis un log qu'on relit le lendemain, le second geste n'est plus possible : le journal
# a tourne, le conteneur est parti, la session est fermee. Le verdict doit PORTER la cause.
#
# ⚠ ET IL Y AVAIT DEJA `loop_hint`, MAIS SUR UNE SEULE BRANCHE. Un service qui a epuise son plafond
# de redemarrages n'est plus `is-active` ET son compteur ne monte plus : ni « boucle » ni « debout ».
# Il tombait donc dans la branche muette. Cas vu : le landing ne montait
# pas, cause reelle « Address already in use » sur le port du deck — que `loop_hint` savait nommer,
# et que personne ne lui demandait.
unit_cause() { # unit_cause <unite> -> " — <cause>", vide si on ne sait rien dire
  local u="$1" hint line
  hint="$(loop_hint "$u")"
  # La derniere ligne d'erreur du journal, quand systemd la garde. `|| true` : un journal absent
  # (conteneur, machine sans persistance) est une REPONSE, pas une panne de ce module.
  line="$($SYSTEMCTL --version >/dev/null 2>&1 \
    && journalctl -u "$u.service" -n 30 --no-pager 2>/dev/null \
       | grep -oE '(OSError|Error|error|Errno [0-9]+)[^"]*' | tail -1 || true)"
  if [[ -n "$line" ]]; then
    printf ' — %s (journal : %s)' "$hint" "$line"
  else
    printf ' — %s' "$hint"
  fi
}

forge_url() { # vide tant que 48-forge-host n'a pas annonce d'adresse — ce n'est pas un echec
  local f="$PROV_TOKENS_DIR/forge.url"
  if [[ -r "$f" ]]; then head -n1 "$f" | tr -d '[:space:]'; fi
}

services_env_body() {
  echo "# Genere par 64-services.sh — l'environnement des services LCARS de cette machine."
  echo "# Un daemon n'herite d'aucun shell : ce qu'il lui faut est ICI, derive du provisionnement."
  echo "FORGE_BASE_URL=$(forge_url)"
  # ⚠ PAS DE `:-` ICI, ET C'EST UNE CORRECTION. `provision-lib.sh` pose ces deux variables avant tout
  # module (`: "${PROV_FORGE_ORG:=fleet}"`), donc un défaut écrit ici ne peut PAS s'exécuter : il se
  # lit comme une décision et n'en est pas une. Pire, il ferait un cinquième littéral `fleet` pour un
  # nom qui en a déjà quatre — et le jour où l'org est renommée, c'est le nombre de copies qui décide
  # combien de lecteurs suivent.
  echo "LCARS_FORGE_ORG=$PROV_FORGE_ORG"
  echo "LCARS_HUMANS_TEAM=$PROV_HUMANS_TEAM"
  echo "LCARS_FLEET_GROUP=$PROV_FLEET_GROUP"
  echo "LCARS_SYSADMIN_UID=$LCARS_SYSADMIN_UID"
  # ⚠ LE PORT DU DECK PASSE PAR ICI, ET C'EST SON SEUL CHEMIN JUSQU'AU DAEMON. `console-landing.sh`
  # lit `LCARS_LANDING_PORT` ; `PROV_DECK_PORT` ne décrivait, lui, que les URL de callback OIDC. Une
  # valeur qui ne déplace QUE les callbacks produit une identification qui revient sur un port où
  # personne n'écoute — la panne tombe au RETOUR du login, là où elle est le moins lisible.
  echo "LCARS_LANDING_PORT=$PROV_DECK_PORT"
  # ⚠ MUR 7 (variable_walls.bats) : tout ce qu'un daemon LIT et que l'installeur DECIDE (jumeau
  # PROV_) voyage par ici — sinon le daemon vit sur son defaut code en dur et ne suit pas une
  # installation qui a deplace le magasin des jetons, renomme le compte systeme ou le groupe de
  # traversee. Les cinq ci-dessous etaient lus (catalogue-executor, console-landing, human-converger)
  # avec un defaut chacun, et absents d'ici : cinq copies d'une decision, aucune qui la suive.
  echo "LCARS_MASTER_TOKEN_FILE=$PROV_MASTER_TOKEN_FILE"
  echo "LCARS_UID_MAP_FILE=$PROV_UID_MAP_FILE"
  echo "LCARS_CONSOLE_GROUP=$PROV_CONSOLE_GROUP"
  echo "LCARS_SYSTEM_ACCOUNT=$PROV_SYSTEM_ACCOUNT"
  echo "LCARS_ROLES=\"$PROV_ROLES\""   # espaces : cite pour systemd (EnvironmentFile) ET pour un `. services.env`
}

unit_body() { # unit_body <nom sans .service>
  case "$1" in
    lcars-landing)
      cat <<EOF
[Unit]
Description=LCARS — la porte d'entree web (deck) sur :$PROV_DECK_PORT
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
      # ⚠ AUCUN `FORGE_TOKEN` N'EST POSE ICI. Le depot d'ops est public par construction (`/branches/tool_request` et
      # `/contents/ops` repondent 200 en anonyme), et un
      # service qui saurait ou trouver un secret aurait le droit de le lire. Une boite dont la forge
      # exige une session en lecture l'ajoute a `$SERVICES_ENV`, explicitement.
      cat <<EOF
[Unit]
Description=LCARS — l'unique geste privilegie de la machine, et il ne detient aucun secret
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

unit_current() { # 0 si l'unite posee est identique a ce qu'on genererait
  local u="$1"
  [[ -f "$(unit_path "$u")" ]] || return 1
  diff -q <(unit_body "$u") "$(unit_path "$u")" >/dev/null 2>&1
}

# ⚠ ELLE DIT, ELLE NE COMPTE PAS — ET LA DIFFERENCE EST TOUTE LA DOCTRINE. Aucun deploiement de
# travail ne fabrique d'humain : le rail pose les AUTORITES (le siege, l'admin de forge, le master
# token), et les personnes s'enrolent par la page d'inscription de la forge. Une machine neuve n'a
# donc AUCUN humain, et c'est son etat nominal jusqu'a la premiere inscription — pas une derive.
#
# Compter cette absence comme un drift la transformait en ECHEC de convergence sur docker (D6 :
# module hors-substrat, `apply:check`), ce qui rendait toute boite non convergee a son premier boot
# et, sur une boite de production ou personne ne s'est encore inscrit, DEFINITIVEMENT. Le meme
# entrypoint publiait alors `provision.rc=1` a cote de `humans.rc=0` — deux verdicts contradictoires
# sur le meme fait, ecrits au meme instant.
#
# Ce que la sonde doit continuer de faire, et qui est son unique raison d'exister : le DIRE. En
# docker, `22-fleet-human` et `48-forge-host` ne sont meme pas selectionnes (`CHECK-ON: wsl linux`) ;
# sans cette ligne, un `doctor` de boite annonce « 0 faute » pendant que GUARD B refuse tout
# « fleet start ». Un WARN dit exactement cela sans pretendre que quelque chose a devie.
probe_fleet_humans() {
  local found; found="$(fleet_humans | paste -sd' ' -)"
  # LE FAIT, pour qui doit decider : l'entrypoint de la boite publie « quelqu'un peut lancer une
  # fleet » et lisait pour cela le CODE DE RETOUR de ce module — qui vaut 0 sur une boite conforme
  # SANS humain, puisque l'absence est un WARN. « humain(s) present(s) » etait donc toujours vrai.
  # Une boite ou seul le siege existe rendait « present(s) ». Meme canal que `00-preflight`.
  p_fact fleet_humans "$found"
  if [[ -n "$found" ]]; then
    p_ok "humain(s) de fleet sur cette machine : $found"
  else
    p_warn "aucun humain de fleet sur cette machine — « fleet start » n'aura personne pour le lancer tant que quelqu'un ne s'est pas enrolé sur la forge (team « $PROV_HUMANS_TEAM », le convergeur le matérialise au tour suivant). Ce n'est pas une dérive : un déploiement neuf attend son premier inscrit"
  fi
}

# ⚠ ON NE COMPARE PAS AU RE-DERIVE. Rejouer `${SUDO_USER:-$(id -un)}` ici rendrait la meme valeur
# qu'a l'apply dans le cas nominal et une DERIVE FAUSSE des qu'un second sudoer passe le doctor.
# Ce qui se verifie sans ambiguite, c'est que l'uid declare designe quelqu'un : une garde qui
# reserve un uid que personne ne porte ne reserve rien, et elle a l'air posee.
probe_seat_uid() {
  local declared name
  declared="$(env_field "$SERVICES_ENV" LCARS_SYSADMIN_UID)"
  if [[ -z "$declared" ]]; then
    # ⚠ « AUCUN » A DEUX CAUSES, ET UNE SEULE EST UN DRIFT. `services.env` est `0640 root:fleet` :
    # un compte hors du groupe rend un champ vide sans avoir lu une ligne du fichier. Le declarer
    # « aucun LCARS_SYSADMIN_UID » est alors un fait sur le LECTEUR, pas sur la machine — et il
    # disparait sous sudo, sur la meme machine a la meme seconde.
    local _st; _st="$(prov_file_state "$SERVICES_ENV")"
    if [[ "$_st" != "present" && "$_st" != "absent" ]]; then
      p_warn "LCARS_SYSADMIN_UID non sondable — $SERVICES_ENV $(prov_state_why "$_st" "$SERVICES_ENV")"
      return 0
    fi
    p_drift "aucun LCARS_SYSADMIN_UID dans $SERVICES_ENV — sans siege declare, is_fleet_human repond non a tout le monde et le convergeur refuse de demarrer (GUARD B, lui, lit $SEAT_UID_FILE et refuse s'il manque) : aucun repli, un refus qui ne se voit qu'au boot"
    return 0
  fi
  # ⚠ `|| true` PARCE QU'UN UID ABSENT EST UNE REPONSE, PAS UNE PANNE. `getent` sort en 2 quand la
  # cle est introuvable ; sous le `pipefail` du module, la substitution echouait et `set -e` tuait la
  # sonde — un DRIFT parfaitement nommable devenait un code 2 « erreur de sonde », et le check
  # s'arretait la. Meme regle que le 404 de la forge ailleurs dans ce depot : une reponse negative
  # PROUVEE se distingue d'une absence de reponse, et seule la seconde est une panne.
  name="$(getent passwd "$declared" 2>/dev/null | cut -d: -f1 || true)"
  if [[ -z "$name" ]]; then
    p_drift "LCARS_SYSADMIN_UID=$declared ne correspond a AUCUN compte de cette machine — GUARD B reserve un uid que personne ne porte, donc il ne reserve rien"
  else
    p_ok "siege : « $name » (uid $declared) — GUARD B lui interdit de lancer une fleet"
  fi
}

probe_seat_file() {
  local v name
  if [[ ! -r "$SEAT_UID_FILE" ]]; then
    p_drift "$SEAT_UID_FILE absent — GUARD B (« $PROV_LINK_DIR/fleet » et son miroir BEAM) refusera tout lancement : sans ce fichier, aucun des deux ne peut établir le siège"
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
    p_fail "$SEAT_UID_FILE dit $v et $SERVICES_ENV dit $declared — GUARD B et uid_floor ne réservent pas le même uid ; le convergeur créerait des humains sur celui que la garde refuse"
    return 0
  fi
  name="$(getent passwd "$v" 2>/dev/null | cut -d: -f1 || true)"
  if [[ -n "$name" ]]; then
    p_ok "GUARD B lit $SEAT_UID_FILE → uid $v (« $name »)"
  else
    p_drift "$SEAT_UID_FILE dit $v, uid qu'aucun compte ne porte — la garde réserve un siège absent"
  fi
}

check() {
  local u

  # ⚠ LA SONDE D'HUMAINS PASSE AVANT LA PORTE DE SORTIE, ET C'EST UN ACQUIS : `22-fleet-human` et
  # `48-forge-host` sont `CHECK-ON: wsl linux`, donc en docker ils ne sont meme pas SELECTIONNES.
  # Ce module est le seul a y tourner. Sortir avant de sonder faisait annoncer « 0 faute » a un
  # `doctor` de boite pendant que GUARD B aurait refuse tout `fleet start`, faute de compte.
  # Trois temoins de `services_units.bats` tiennent ce contrat — ne pas le deplacer sous pretexte
  # qu'un humain manque forcement au premier boot : c'est un DRIFT, et un drift se dit.
  probe_fleet_humans

  # ⚠ LE SUBSTRAT CHOISIT LA MECANIQUE, `have_systemd` DIT SEULEMENT SI ELLE EST UTILISABLE. Ces
  # deux questions se confondent facilement, et la confusion vise le rail WSL en plein : `30-wsl`
  # pose `systemd=true` dans `wsl.conf`, mais il ne prend effet qu'apres un `wsl --shutdown`. Au
  # PREMIER apply d'un WSL vierge, `/run/systemd/system` n'existe donc pas — et une branche
  # conditionnee a la seule absence de systemd aurait fait chercher `supervise.sh` sur un poste,
  # ou il n'y en a pas. La boite tient ses services par un superviseur ; le poste, par systemd,
  # meme quand systemd n'est pas encore la.
  if [[ "${PROV_SUBSTRATE:-}" == "docker" ]]; then
    check_box_services
    verdict_check
  fi

  if ! have_systemd; then
    p_warn "pas de systemd ici ($SYSTEMCTL absent, ou systemd n'est pas l'init : /run/systemd/system) — aucune unite posee. Sur WSL, « wsl --shutdown » puis un nouvel onglet l'active (cf. 30-wsl)"
    verdict_check
  fi

  if [[ -s "$SERVICES_ENV" ]]; then
    p_ok "environnement des services posé ($SERVICES_ENV)"
  else
    p_drift "environnement des services absent ($SERVICES_ENV) — les deux daemons démarreraient sans savoir où est la forge"
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
      p_drift "$u.service posé mais PAS actif — $(consequence_of "$u")"
    fi
  done

  verdict_check
}

apply() {
  local u

  # ⚠ LE SIEGE ET L'ENVIRONNEMENT SE POSENT AVANT LA PORTE SYSTEMD, ET L'ORDRE EST LE CORRECTIF.
  # `seat.uid` est ce que lit GUARD B (`bin/fleet`, `runtime.exs`) ; il ne depend d'aucune
  # unite. Pose apres le test de systemd, il manquait sur un WSL vierge au premier apply — `30-wsl`
  # vient d'ecrire `systemd=true`, qui n'agit qu'apres `wsl --shutdown` — et `fleet start`
  # refusait entre les deux passes pendant que le verdict de ce module etait vert (« rien a poser »).
  # `services.env` suit pour la meme raison : les unites le liront quand elles existeront.
  [[ -n "${LCARS_SYSADMIN_UID:-}" ]] || {
    p_fail "LCARS_SYSADMIN_UID non posé — « deploy/provision » le dérive du siège avant tout module. Sans lui, l'environnement des daemons s'écrirait sans la clé que lisent is_fleet_human et le convergeur : le premier répondrait non à tout le monde, le second refuserait de démarrer (aucun repli, par décision)"
    verdict_apply
  }

  ensure_dir "$(dirname "$SERVICES_ENV")" 0755 "$SERVICES_OWNER" || verdict_apply
  local env_body
  env_body="$(services_env_body)" \
    || { p_fail "environnement des services non calculable — l'écriture est ABANDONNÉE, pas tronquée"; verdict_apply; }
  write_atomic "$SERVICES_ENV" 0640 "${SERVICES_OWNER%%:*}:$PROV_FLEET_GROUP" <<<"$env_body" \
    || { p_fail "environnement des services non posé ($SERVICES_ENV)"; verdict_apply; }

  # ⚠ `0644 root:root`, ET LES DEUX MOITIES DU MODE COMPTENT. Le `644` parce que le lecteur est le
  # shell d'un humain quelconque : un fichier que le garde ne peut pas ouvrir ne garde rien. Le
  # `root:root` parce que c'est ce qui empeche ce meme humain de le REECRIRE — c'est toute la
  # difference avec la variable qu'il remplace. Ce n'est pas un secret, c'est un fait de machine.
  write_atomic "$SEAT_UID_FILE" 0644 "$SERVICES_OWNER" <<<"$LCARS_SYSADMIN_UID" \
    || { p_fail "uid du siège non posé ($SEAT_UID_FILE) — GUARD B refusera tout lancement sur cette machine"; verdict_apply; }

  if ! have_systemd; then
    p_warn "pas de systemd ici ($SYSTEMCTL absent, ou systemd n'est pas l'init : /run/systemd/system) — le siege et l'environnement sont poses, AUCUNE unite ne l'est, et c'est dit plutôt que fait à moitié. Sur WSL, « wsl --shutdown » puis un nouvel onglet l'active (cf. 30-wsl)"
    verdict_apply
  fi

  local reload=0 body
  for u in "${UNITS[@]}"; do
    unit_current "$u" && continue
    body="$(unit_body "$u")" \
      || { p_fail "unite inconnue: $u — aucun fichier ecrit"; verdict_apply; }
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
        p_chg "$u.service debout, apres $(( ${n2:-0} - ${was[$i]:-0} )) redemarrage(s) — il a attendu quelque chose"
      else
        p_chg "$u.service activé et debout"
      fi
    else
      # ⚠ LE VERDICT PORTE LA CAUSE, IL NE DÉLÈGUE PAS SA LECTURE. « status dit pourquoi » est un
      # diagnostic juste dont l'action demande un SECOND geste — et sur un rail joué en fond, ou
      # depuis un log qu'on relit le lendemain, ce second geste n'est plus possible : le journal a
      # tourné. Cas vu : le landing ne montait pas, cause réelle
      # « Address already in use » sur le port du deck, invisible dans la ligne du rail.
      #
      # C'est le motif que ce rail combat partout ailleurs — un remède nommé qu'on ne peut pas jouer
      # (chemin publié inexistant, `docker exec` sur un conteneur qui redémarre). Ici il suffit de
      # RECOPIER ce que le journal dit déjà.
      p_fail "$u.service posé mais pas debout$(unit_cause "$u")"
    fi
  done

  converge_humans_now
  verdict_apply
}

# ⚠ ON NE FAIT PAS CONFIANCE AU CODE DE RETOUR SEUL. Le convergeur peut rendre 0 en n'ayant converti
# personne (une team vide EST un résultat valide). Ce qui se vérifie est le FAIT : un compte unix
# existe pour un humain de la team. `--once` est documenté en tête de ce script — « une passe, pour
# sonder ou tester » — et rend 1 sur dépendance absente, 2 sur configuration absente.
converge_humans_now() {
  local conv="${LCARS_HUMAN_CONVERGER:-$HELPERS_DIR/human-converger.sh}"
  [[ -x "$conv" ]] || { p_warn "convergeur d'humains absent ($conv) — aucun humain ne sera matérialisé par cette passe"; return 0; }

  local avant apres nouveaux
  avant="$(fleet_humans | sort -u)"

  # `run_quiet` fait `p_fail` sur TOUT rc non nul, et `p_fail` incrémente `PROV_FAILED` : le `case`
  # qui suivait lisait un code dont le verdict était déjà tombé en ÉCHEC deux lignes plus haut. Trois
  # branches écrites, commentées, et sans effet — la classe exacte de `391638668`. `run_step --ok N`
  # est la primitive qui existe pour ça : le code toléré ne compte pas, et `PROV_LAST_RC` le garde.
  #
  # ⚠ ET L'ENVIRONNEMENT EST CELUI DU DAEMON, PAS CELUI DE L'APPLY. L'unité charge
  # `EnvironmentFile=-$SERVICES_ENV` et rien d'autre ; cet apply, lui, a tous les `PROV_*` exportés
  # par `provision`. Tirer la passe depuis notre propre environnement validerait un chemin que le
  # service ne peut PAS reprendre : ça marcherait ici et pas au premier boot. `env -i` coupe
  # l'héritage, le `PATH` est celui que systemd donne par défaut, et le reste vient du fichier qu'on
  # vient d'écrire — la même source, dans le même ordre.
  local rc=0
  # ⚠ quotes simples VOULUES plus bas : `$1` et `$2` sont les arguments du bash INTERNE, passes
  # juste apres — les developper ici les remplacerait par ceux de CE script.
  # shellcheck disable=SC2016
  run_step --ok 1 --ok 2 "convergence des humains (une passe)" -- \
    env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
    bash -c 'set -a; . "$1"; set +a; exec "$2" --once' _ "$SERVICES_ENV" "$conv" || rc=$?
  [[ "$rc" -eq 0 ]] || return 0   # rc non toléré : `run_step` a déjà compté l'échec et dit pourquoi
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
    p_chg "humain(s) de fleet matérialisé(s) PAR CETTE PASSE : $liste_new"
  elif [[ -n "$liste_all" ]]; then
    p_ok "humain(s) de fleet déjà présent(s) : $liste_all — cette passe n'en a matérialisé aucun de plus"
  else
    p_ok "aucun humain à matérialiser — la team « $PROV_HUMANS_TEAM » de la forge est vide. Ce n'est pas une faute : les gens s'enrôlent sur la forge, un propriétaire les ajoute à la team, et le convergeur les matérialise au tour suivant"
  fi

  # ⚠ UN BLOC A DISPARU ICI, ET IL CONTREDISAIT SON VOISIN DU DESSUS (⚖ user 2026-08-30). Il
  # verifiait que « l'humain que ce rail pre-seme » avait bien ete materialise. Or le rail ne
  # pre-seme plus personne : il pose les AUTORITES, et les gens s'enrolent sur la forge sous leur
  # nom. Le paragraphe ci-dessus le disait deja — « ce n'est pas une faute » — pendant que celui-ci
  # derivait sur l'absence du meme fait. Deux verdicts opposes sur une seule question, dans la meme
  # fonction, a six lignes d'ecart.
}

case "${1:?usage: 64-services.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
