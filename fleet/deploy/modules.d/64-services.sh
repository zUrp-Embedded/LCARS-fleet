#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/64-services.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: PROTO-V2 — ce qui doit être DEBOUT sur un poste natif : la landing et le convergeur d'humains
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
#
# ─── DEUX PROCESSUS QUE PERSONNE NE LANÇAIT ─────────────────────────────────────────────────────
#
# ⚖ USER 2026-08-21 : « l'installeur doit livrer un système qui fonctionne. » Et D2, posé la veille :
# ce que l'humain voit et utilise, c'est la LANDING — c'est elle qui doit être up 100 % du temps,
# tenue par systemd ou par docker.
#
# Dans la boîte, l'entrypoint lance les deux et `tini` les tient. Sur un poste natif il n'y a pas
# d'entrypoint : les deux scripts existaient sur le disque (depuis `62-runtime-helpers`) et RIEN ne
# les démarrait. Mesuré le 2026-08-21 : la landing tournait parce que je l'avais lancée à la main en
# `nohup setsid` — un processus orphelin, sans superviseur, qui ne survit pas au reboot et dont
# personne ne peut dire l'état.
#
# ⚠ LA DIFFÉRENCE ENTRE CES DEUX-LÀ ET LA FLEET EST UNE DÉCISION, PAS UN OUBLI (D11). La fleet
# d'un humain démarre quand SON humain le décide — une unité par personne, activée par elle. Ces
# deux services-ci sont l'INFRASTRUCTURE de la machine : sans landing personne n'entre, sans
# convergeur personne n'est enrôlé. Ils s'activent à l'install.
#
# ─── LES DEUX TOURNENT EN root, ET CHACUN LAISSE TOMBER CE QU'IL PEUT ───────────────────────────
#
# Le convergeur a besoin de `useradd` : il n'y a pas de version non privilégiée de créer un humain.
# La landing démarre en root et se DÉPOSE elle-même — `console-landing.sh` fait
# `setpriv --reuid nobody --regid nogroup --groups lcars-console`, exactement comme dans l'image.
# Ne PAS mettre `User=nobody` dans l'unité : ça retirerait au script le droit de faire ce drop, et
# surtout ça lui retirerait le groupe `lcars-console`, sans lequel il ne traverse aucune socket de
# console — la page s'ouvrirait sur une liste vide en annonçant que tout va bien.
#
# (Le compte système dédié `lcars-system` du Lot 5 est un durcissement à venir : il remplacerait
# `nobody`, partagé par tout le système. Tant qu'il n'existe pas, on fait ce que fait l'image.)
#
# ─── POURQUOI `wsl` AUSSI, ET CE MODULE A PORTÉ `linux` SEUL PENDANT UNE JOURNÉE ────────────────
#
# ⚠ `APPLY-ON: linux` + `CHECK-ON: any` FAISAIT UN ÉCHEC STRUCTUREL SUR LE RAIL WSL. Le module y
# était SÉLECTIONNÉ (check) mais NON APPLICABLE — et le runner traduit cet état, à raison, par un
# FAIL : « état-cible non tenu sur wsl et inapplicable ici — rebuild l'image qui le fournit ». Sur
# un poste WSL il n'y a aucune image à rebuilder, donc le verdict était juste dans sa forme et
# ininterprétable dans son geste, et il faisait sortir `install.sh` en erreur.
#
# Le garde `p_warn` qui protège la boîte ne rattrapait rien : `30-wsl` écrit lui-même
# `[boot] systemd=true`, donc `have_systemd()` répond OUI sous WSL2.
#
# Et le fond suit la forme : sur WSL, tout le reste du runtime natif est déjà posé — les scripts de
# console et `ttyd` par `62-runtime-helpers` (`wsl linux`), les dossiers de socket par
# `25-directories`, la release par `60-deploy`, l'humain de fleet par `22-fleet-human`. Tout existe
# SAUF ce qui démarre. Un poste WSL avait donc une fleet et pas de porte.
#
# L'INVARIANT QUE CE MODULE VIOLAIT, ET QU'UN TÉMOIN TIENT DÉSORMAIS : un module n'est légitimement
# en check-seul que sur `docker`, où l'IMAGE fournit l'état. Sur `wsl` ou `linux`, « check-seul »
# signifie « personne ici ne peut jamais converger ça » — ce qui n'est pas un état-cible, c'est une
# impasse. (Trouvé par le reverse d'alice, 2026-08-21 : « une case déclarée `any` sur un axe et
# `linux` sur l'autre, sans que personne ait joué la combinaison `wsl` ».)

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

SYSTEMD_DIR="${LCARS_SYSTEMD_DIR:-/etc/systemd/system}"
SERVICES_ENV="${LCARS_SERVICES_ENV:-/etc/lcars/services.env}"
SYSTEMCTL="${LCARS_SYSTEMCTL:-systemctl}"
HELPERS_DIR="${LCARS_HELPERS_DIR:-/opt/lcars}"
# Seam de test, même idiome que 05-host-consent et 62-runtime-helpers : un témoin ne peut pas
# `chown root`, et ce qui doit être épinglé ici est justement ce qui s'écrit.
SERVICES_OWNER="${LCARS_SERVICES_OWNER:-root:root}"
# La fenetre d'observation qui separe « forke » de « debout ». Seam de temoin : un bats mesure la
# DECISION (le compteur a-t-il bouge), jamais l'ecoulement du temps.
SETTLE_SECS="${LCARS_SERVICES_SETTLE:-12}"

UNITS=(lcars-landing lcars-converger)

# ─── QUI DÉMARRE QUOI — LA TABLE, PARCE QU'UNE PROSE NE SE VÉRIFIE PAS ──────────────────────────
#
# ⚠ LE RAIL NATIF RE-DÉRIVE LE CONTRAT DE DÉMARRAGE DE LA BOÎTE, ET IL EN AVAIT PERDU UN TIERS.
# `deploy/docker/entrypoint.sh` lance TROIS composants persistants au boot ; ce module posait DEUX
# unités. Le troisième — `console.sh --all` — n'avait aucun démarreur, et le deck offrait donc des
# consoles que personne n'ouvrait (`[Errno 2]` sur la socket, mesuré le 2026-08-22).
#
# ⚖ USER 2026-08-22 : « 2 on aligne ». Pas de troisième unité — le convergeur appelle `--all` une
# fois par tour (`ensure_all_consoles`). Une unité de plus AJOUTERAIT un démarreur là où le défaut
# était d'en avoir deux qui ne s'accordent pas.
#
# ⚠ D'OÙ CETTE TABLE. Sans elle, le témoin ISO des processus devrait accepter une exemption en
# prose — « celui-là est démarré ailleurs, crois-moi » — c'est-à-dire devenir décoratif. La règle
# qu'elle rend vérifiable est : **chaque composant persistant de l'entrypoint a un démarreur DÉCLARÉ
# sur ce rail**, unité ou pilote, et la correspondance est lisible par une machine.
#
# Format : <composant de l'entrypoint>:<unit|driven-by>:<nom>
STARTERS=(
  "human-converger.sh:unit:lcars-converger"
  "console-landing.sh:unit:lcars-landing"
  "console.sh:driven-by:lcars-converger"
)

have_systemd() { command -v "$SYSTEMCTL" >/dev/null 2>&1 && [[ -d "$SYSTEMD_DIR" ]]; }

# Le compteur de redemarrages automatiques du service — la seule mesure qu'un fork reussi ne fausse pas.
restarts_of() { "$SYSTEMCTL" show -p NRestarts --value "$1.service" 2>/dev/null; }

# ─── L'ENVIRONNEMENT DES DEUX SERVICES, DÉRIVÉ ─────────────────────────────────────────────────
# Un daemon n'hérite de RIEN : ni du shell de l'opérateur, ni des `PROV_*` que `provision` exporte
# le temps d'un apply. Ce qu'il lui faut se pose donc sur le disque, une fois, dérivé de ce que le
# provisionnement vient d'établir — et jamais recopié à la main dans deux unités.
#
# `FORGE_BASE_URL` vient du fichier que `48-forge-host` écrit en annonçant l'adresse de la forge
# (les modules sont des processus : aucun ne peut exporter vers un autre).
forge_url() {
  local f="$PROV_TOKENS_DIR/forge.url"
  [[ -r "$f" ]] && head -n1 "$f" | tr -d '[:space:]'
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
  echo "PROV_FORGE_ORG=$PROV_FORGE_ORG"
  echo "PROV_HUMANS_TEAM=$PROV_HUMANS_TEAM"
  echo "PROV_FLEET_GROUP=$PROV_FLEET_GROUP"
  echo "PROV_ADMIN_GROUP=$PROV_ADMIN_GROUP"
  echo "LCARS_SYSADMIN_UID=${LCARS_SYSADMIN_UID:-1000}"
  # ⚠ LE PORT DU DECK PASSE PAR ICI, ET C'EST SON SEUL CHEMIN JUSQU'AU DAEMON. `console-landing.sh`
  # lit `LCARS_LANDING_PORT` ; `PROV_DECK_PORT` ne décrivait, lui, que les URL de callback OIDC. Une
  # valeur qui ne déplace QUE les callbacks produit une identification qui revient sur un port où
  # personne n'écoute — la panne tombe au RETOUR du login, là où elle est le moins lisible.
  echo "LCARS_LANDING_PORT=$PROV_DECK_PORT"
  echo "LCARS_PROVISION=$HELPERS_DIR/fleet/deploy/provision"
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
    *) return 1 ;;
  esac
}

unit_path() { echo "$SYSTEMD_DIR/$1.service"; }

unit_current() { # 0 si l'unite posee est identique a ce qu'on genererait
  local u="$1"
  [[ -f "$(unit_path "$u")" ]] || return 1
  diff -q <(unit_body "$u") "$(unit_path "$u")" >/dev/null 2>&1
}

check() {
  local u

  if ! have_systemd; then
    # Un fichier d'unite pour un init qui n'existe pas n'est pas une garde, c'est un decor — meme
    # regle que le `tmpfiles.d` de 25-directories.
    p_warn "pas de systemd ici ($SYSTEMCTL absent ou $SYSTEMD_DIR introuvable) — aucune unite posee ; la landing et le convergeur doivent etre tenus autrement"
    verdict_check
  fi

  [[ -s "$SERVICES_ENV" ]] \
    && p_ok "environnement des services posé ($SERVICES_ENV)" \
    || p_drift "environnement des services absent ($SERVICES_ENV) — les deux daemons démarreraient sans savoir où est la forge"

  for u in "${UNITS[@]}"; do
    if ! unit_current "$u"; then
      p_drift "$(unit_path "$u") absente ou divergente"
      continue
    fi
    # « POSÉE » N'EST PAS « DEBOUT », et c'est toute la raison de ce module. Une unité présente et
    # désactivée décrit un service que personne ne lance — exactement l'état d'avant.
    if "$SYSTEMCTL" is-active --quiet "$u.service" 2>/dev/null; then
      p_ok "$u.service actif"
    else
      p_drift "$u.service posé mais PAS actif — $( [[ "$u" == lcars-landing ]] && echo 'personne ne peut entrer' || echo 'personne ne sera enrole' )"
    fi
  done

  verdict_check
}

apply() {
  local u

  if ! have_systemd; then
    p_warn "pas de systemd ici ($SYSTEMCTL absent ou $SYSTEMD_DIR introuvable) — rien à poser, et c'est dit plutôt que fait à moitié"
    verdict_apply
  fi

  ensure_dir "$(dirname "$SERVICES_ENV")" 0755 "$SERVICES_OWNER" || verdict_apply
  # 0640 root:$PROV_FLEET_GROUP : ce n'est pas un secret (une URL, des noms de groupes), mais il n'a
  # aucune raison d'être lisible par tout le monde, et le groupe fleet doit pouvoir le lire pour
  # diagnostiquer sans sudo.
  write_atomic "$SERVICES_ENV" 0640 "${SERVICES_OWNER%%:*}:$PROV_FLEET_GROUP" < <(services_env_body) \
    || { p_fail "environnement des services non posé ($SERVICES_ENV)"; verdict_apply; }
  # (pas de `p_chg` ici : `write_atomic` émet déjà sa ligne POSÉ avec le chemin — la répéter fait
  # lire deux écritures là où il n'y en a qu'une.)

  local reload=0
  for u in "${UNITS[@]}"; do
    unit_current "$u" && continue
    write_atomic "$(unit_path "$u")" 0644 "$SERVICES_OWNER" < <(unit_body "$u") \
      || { p_fail "unité non posée: $(unit_path "$u")"; verdict_apply; }
    reload=1
  done

  # ⚠ `daemon-reload` AVANT `enable`, TOUJOURS : systemd sert l'unité qu'il a en mémoire, pas celle
  # qui est sur le disque. Sans ce rechargement, un `enable --now` qui suit une réécriture démarre
  # l'ANCIENNE — et la mesure d'après lit un service actif qui n'est pas celui qu'on vient d'écrire.
  [[ "$reload" -eq 1 ]] && { "$SYSTEMCTL" daemon-reload || p_warn "daemon-reload en échec"; }

  # ⚠ « DÉMARRÉ » N'EST PAS « DEBOUT ». `enable --now` rend 0 dès que systemd a forké le processus :
  # un service qui meurt à sa première ligne — port déjà pris, fichier absent — passe pour démarré,
  # et `Restart=` le relève ensuite en boucle, si bien qu'une mesure prise au bon instant le lit même
  # ACTIF. Ce qui ne ment pas est le COMPTEUR DE REDÉMARRAGES : lu avant, relu après une fenêtre plus
  # longue que le `RestartSec` le plus long du lot. S'il a bougé, le service boucle sur son échec.
  local -a was=()
  local i n
  for u in "${UNITS[@]}"; do
    was+=("$(restarts_of "$u")")
    "$SYSTEMCTL" enable --now "$u.service" >/dev/null 2>&1 \
      || p_fail "$u.service n'a pas démarré — « $SYSTEMCTL status $u.service » et « journalctl -u $u.service » disent pourquoi"
  done

  if [[ "$SETTLE_SECS" -gt 0 ]]; then sleep "$SETTLE_SECS"; fi
  for i in "${!UNITS[@]}"; do
    u="${UNITS[$i]}"
    n="$(restarts_of "$u")"
    if [[ "${n:-0}" -gt "${was[$i]:-0}" ]]; then
      p_fail "$u.service redémarre en boucle — « journalctl -u $u.service » dit pourquoi"
    elif "$SYSTEMCTL" is-active --quiet "$u.service"; then
      p_chg "$u.service activé et debout"
    else
      p_fail "$u.service posé mais pas debout — « $SYSTEMCTL status $u.service » dit pourquoi"
    fi
  done
  verdict_apply
}

case "${1:?usage: 64-services.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
