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
# `setpriv --reuid lcars-system --regid lcars-system --groups lcars-console`, exactement comme dans
# l'image. Ne PAS mettre `User=` dans l'unité : ça retirerait au script le droit de faire ce drop,
# et surtout ça lui retirerait le groupe `lcars-console`, sans lequel il ne traverse aucune socket
# de console — la page s'ouvrirait sur une liste vide en annonçant que tout va bien.
#
# ⚠ `lcars-system` EXISTE DEPUIS LE 2026-08-27, ET CE PARAGRAPHE ANNONÇAIT LE CONTRAIRE. Il disait
# « un durcissement à venir ; tant qu'il n'existe pas, on fait ce que fait l'image ». Ce qui l'a fait
# poser n'est pas le principe mais une mesure : `nobody` n'est pas une identité, et son groupe
# `nogroup` (gid 65534) est le groupe PRIMAIRE de `sync`, `_apt`, `nobody` et `dhcpcd` sur une
# Debian/Ubuntu ordinaire. Le fichier d'identification du deck — qui porte le `client_secret`
# OAuth2 — s'y posait `0640 root:nogroup` : un démon réseau le lisait. Il est désormais
# `0640 root:lcars-system`, et le groupe nomme exactement un lecteur.
#
# ⚠ CE QUE CE COMPTE NE FERME PAS : le deck reçoit toujours `lcars-console` à l'exec, et ce groupe
# est à un `connect()` d'un shell sous n'importe quel humain. On a rangé QUI partage son identité,
# pas ce qu'il peut faire.
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
# ⚠ LE FICHIER QUE LIT GUARD B, ET IL N'EST PAS DANS `services.env`. Celui-ci sert les DAEMONS par
# `EnvironmentFile=` ; la garde, elle, tourne dans le shell d'un HUMAIN, qui n'herite d'aucun des
# deux. Et surtout : une garde ne peut pas prendre sa clef dans l'environnement de ce qu'elle garde
# — `LCARS_SYSADMIN_UID=99999 fleet_v2 start` la desarmait (mesure du 2026-08-27). D'ou un fichier
# `root:root` que le garde ne peut pas reecrire, et qui GAGNE sur la variable chez ses deux lecteurs
# (`bin/fleet_v2` et son miroir `config/runtime.exs`).
SEAT_UID_FILE="${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}"
SYSTEMCTL="${LCARS_SYSTEMCTL:-systemctl}"
HELPERS_DIR="${LCARS_HELPERS_DIR:-/opt/lcars}"
# Seam de test, même idiome que 05-host-consent et 62-runtime-helpers : un témoin ne peut pas
# `chown root`, et ce qui doit être épinglé ici est justement ce qui s'écrit.
SERVICES_OWNER="${LCARS_SERVICES_OWNER:-root:root}"
# Le compte du service d'autorite. Il se LIT dans `provision-lib.sh`, il ne s'y recopie plus : le
# `:-lcars-authority` qui vivait ici etait une branche morte (la lib est sourcee au-dessus) et un
# litteral de plus a faire suivre. Meme geste dans `21-service-accounts`, le meme jour.
AUTHORITY_USER="$PROV_AUTHORITY_USER"
# La fenetre d'observation qui separe « forke » de « debout ». Seam de temoin : un bats mesure la
# DECISION (le compteur a-t-il bouge), jamais l'ecoulement du temps.
SETTLE_SECS="${LCARS_SERVICES_SETTLE:-12}"

UNITS=(lcars-landing lcars-converger lcars-catalogue lcars-privileged)

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
  "catalogue-executor.py:unit:lcars-catalogue"
  "privileged-executor.py:unit:lcars-privileged"
)

have_systemd() { command -v "$SYSTEMCTL" >/dev/null 2>&1 && [[ -d "$SYSTEMD_DIR" ]]; }

# Le compteur de redemarrages automatiques du service — la seule mesure qu'un fork reussi ne fausse pas.
restarts_of() { "$SYSTEMCTL" show -p NRestarts --value "$1.service" 2>/dev/null; }

# ⚠ LA CAUSE LA PLUS FREQUENTE SE NOMME, SINON LE DIAGNOSTIC COUTE DEUX SAUTS. « redemarre en
# boucle » puis `journalctl` puis un traceback Python : trois lectures pour apprendre qu'un port est
# pris. La sonde ne tourne QU'APRES l'echec — sur le chemin nominal il n'y a rien a payer, et elle
# n'a aucun faux positif : notre propre service, lui, n'arrive justement pas a se lier.

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
  # ⚠ MÊME RÈGLE QUE LES DEUX LIGNES AU-DESSUS, ET ELLE N'ÉTAIT PAS APPLIQUÉE ICI. Le `:-1000` qui
  # vivait là était le SEUL écrivain d'une variable que six lecteurs attendent — et il recopiait leur
  # défaut au lieu de le remplacer. Un poseur qui repose le défaut ne pose rien : il rend seulement
  # impossible de voir que personne n'a décidé. `deploy/provision` dérive la valeur du siège avant
  # tout module ; son absence est refusée en tête d'`apply`, pas ici (cf. la cicatrice là-bas).
  echo "LCARS_SYSADMIN_UID=$LCARS_SYSADMIN_UID"
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
    lcars-catalogue)
      # ⚠ CE SERVICE TIENT L'AUTORITÉ TOTALE DE LA FORGE, et c'est le seul de la machine dans ce cas.
      # Il ne fait pas d'escalade pour un appelant : il RÉPOND à une demande, après avoir demandé à
      # la forge si le pair — dont le noyau lui donne l'uid — y porte `is_admin`.
      #
      # ⚠ `User=` ET PAS root, ET C'ETAIT L'INVERSE PENDANT DEUX JOURS. Ce service ne demandait root
      # que pour POSSEDER quatre chemins — le jeton, le seed, l'etat tofu, son repertoire de socket.
      # Aucun appel privilegie dans sa chaine : `forge-gestures.sh` n'exige root nulle part, et
      # `tofu` parle HTTP. Un compte dedie possede les quatre et fait le meme travail.
      #
      # Ce qu'on gagne n'est pas cosmetique : le detenteur des secrets de la forge n'a plus AUCUN
      # privilege noyau, et le seul service qui en garde un (`lcars-converger`, pour `useradd`) ne
      # detient rien. Celui qui detient ne peut pas escalader ; celui qui escalade n'a rien a voler.
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
      # ⚠ L'UNIQUE SERVICE ROOT DE CETTE MACHINE, ET IL NE DETIENT RIEN. C'est l'inverse exact de
      # `lcars-catalogue` juste au-dessus : celui-la detient les secrets de la forge et n'a AUCUN
      # privilege noyau ; celui-ci porte le seul geste privilege et n'ouvre AUCUN secret. Celui qui
      # detient ne peut pas escalader, celui qui escalade n'a rien a voler.
      #
      # ⚠ PAS DE `User=` — ET C'EST LA SEULE UNITE DE CE FICHIER OU L'ABSENCE EST LE CONTRAT. Il
      # remplace `%fleet ALL=(root) NOPASSWD:` : le privilege ne disparait pas, il cesse d'etre
      # accessible par un GROUPE que la forge repeuple toutes les 30 s.
      #
      # ⚠ AUCUN `FORGE_TOKEN` N'EST POSE ICI. Le depot d'ops est public par construction (mesure du
      # 2026-08-25 : `/branches/tool_request` et `/contents/ops` repondent 200 en anonyme), et un
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

# ─── QUI PEUT LANCER UNE FLEET ICI — LA SONDE QUE PERSONNE NE PORTAIT SUR UNE BOÎTE ─────────────
#
# ⚠ SUR UNE BOÎTE DE PRODUCTION, AUCUN MODULE NE VÉRIFIAIT QU'IL EXISTE UN HUMAIN. `22-fleet-human`
# et `48-forge-host` portent `CHECK-ON: wsl linux` : en docker ils ne sont même pas SÉLECTIONNÉS.
# Ce module-ci est `CHECK-ON: any` — donc le seul à tourner là-bas — et il sortait en `p_warn` dès
# l'absence de systemd, avant toute sonde. Un `provision doctor` sur une boîte annonçait donc 0
# faute pendant que GUARD B (`bin/fleet_v2`) aurait refusé tout `fleet_v2 start`, faute de compte.
#
# La sonde passe donc AVANT la branche systemd : c'est précisément le chemin où il n'y en a pas.
# Elle ne mesure pas les services — elle mesure la seule chose dont dépend leur utilité.
probe_fleet_humans() {
  local found; found="$(fleet_humans | paste -sd' ' -)"
  if [[ -n "$found" ]]; then
    p_ok "humain(s) de fleet sur cette machine : $found"
  else
    p_drift "aucun humain de fleet sur cette machine — GUARD B refusera tout « fleet_v2 start » (le siège en est exclu par construction). Enrôle quelqu'un sur la forge et ajoute-le à la team « $PROV_HUMANS_TEAM » : le convergeur le matérialise au tour suivant"
  fi
}

# ─── LE SIEGE EST-IL CELUI QUE LES GARDES RESERVENT ? ──────────────────────────────────────────
#
# ⚠ CE QUI EST SONDE ICI EST LA VALEUR QUE LES DAEMONS LIRONT, pas celle que ce module vient de
# calculer. Les deux peuvent diverger — un `apply` joue sous un operateur, la machine en change, ou
# quelqu'un reinstalle depuis un autre compte — et c'est precisement l'ecart qu'aucun verdict ne
# voyait quand la variable n'avait aucun poseur.
#
# ⚠ ON NE COMPARE PAS AU RE-DERIVE. Rejouer `${SUDO_USER:-$(id -un)}` ici rendrait la meme valeur
# qu'a l'apply dans le cas nominal et une DERIVE FAUSSE des qu'un second sudoer passe le doctor.
# Ce qui se verifie sans ambiguite, c'est que l'uid declare designe quelqu'un : une garde qui
# reserve un uid que personne ne porte ne reserve rien, et elle a l'air posee.
probe_seat_uid() {
  local declared name
  declared="$(sed -n 's/^LCARS_SYSADMIN_UID=//p' "$SERVICES_ENV" 2>/dev/null | head -n1)"
  if [[ -z "$declared" ]]; then
    p_drift "aucun LCARS_SYSADMIN_UID dans $SERVICES_ENV — is_fleet_human et uid_floor retomberont sur le litteral 1000, qui n'est le siege que par coincidence (GUARD B, lui, lit $SEAT_UID_FILE et refuse s'il manque)"
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

# ─── LE FICHIER QUE LISENT LES DEUX MOITIES DE GUARD B ─────────────────────────────────────────
#
# Absent, les deux gardes REFUSENT : le siege ne se devine pas, et une machine sans ce fichier n'est
# pas provisionnee. Ce module est le seul a le poser sur ce rail.
probe_seat_file() {
  local v name
  if [[ ! -r "$SEAT_UID_FILE" ]]; then
    p_drift "$SEAT_UID_FILE absent — GUARD B (« $HELPERS_DIR/fleet_v2 » et son miroir BEAM) refusera tout lancement : sans ce fichier, aucun des deux ne peut établir le siège"
    return 0
  fi
  v="$(head -n1 -- "$SEAT_UID_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ ! "$v" =~ ^[0-9]+$ ]]; then
    p_drift "$SEAT_UID_FILE ne porte pas un uid (« $v ») — les deux gardes refuseront un lancement qu'ils ne peuvent pas vérifier"
    return 0
  fi
  # ⚠ LES DEUX ARTEFACTS DOIVENT S'ACCORDER, ET ILS VIENNENT DE LA MEME DERIVATION. `services.env`
  # sert `uid_floor` (le plancher de creation des humains), ce fichier sert GUARD B (le refus de
  # lancement). Deux valeurs differentes creeraient des humains sur l'uid que la garde reserve.
  local declared
  declared="$(sed -n 's/^LCARS_SYSADMIN_UID=//p' "$SERVICES_ENV" 2>/dev/null | head -n1 || true)"
  if [[ -n "$declared" && "$declared" != "$v" ]]; then
    p_fail "$SEAT_UID_FILE dit $v et $SERVICES_ENV dit $declared — GUARD B et uid_floor ne réservent pas le même uid ; le convergeur créerait des humains sur celui que la garde refuse"
    return 0
  fi
  name="$(getent passwd "$v" 2>/dev/null | cut -d: -f1 || true)"
  [[ -n "$name" ]] \
    && p_ok "GUARD B lit $SEAT_UID_FILE → uid $v (« $name »)" \
    || p_drift "$SEAT_UID_FILE dit $v, uid qu'aucun compte ne porte — la garde réserve un siège absent"
}

check() {
  local u

  probe_fleet_humans

  if ! have_systemd; then
    # Un fichier d'unite pour un init qui n'existe pas n'est pas une garde, c'est un decor — meme
    # regle que le `tmpfiles.d` de 25-directories.
    p_warn "pas de systemd ici ($SYSTEMCTL absent ou $SYSTEMD_DIR introuvable) — aucune unite posee ; la landing et le convergeur doivent etre tenus autrement"
    verdict_check
  fi

  [[ -s "$SERVICES_ENV" ]] \
    && p_ok "environnement des services posé ($SERVICES_ENV)" \
    || p_drift "environnement des services absent ($SERVICES_ENV) — les deux daemons démarreraient sans savoir où est la forge"

  # ⚠ ICI ET PAS AVANT LA BRANCHE SYSTEMD, et le témoin voisin porte la raison : `probe_fleet_humans`
  # sort AVANT elle parce que la population est un fait de la machine, vrai sur les deux rails.
  # Celle-ci lit `$SERVICES_ENV`, qui est un artefact du rail POSTE — la boîte n'en a pas, son
  # environnement vient du conteneur. Sondée trop tôt, elle rendait ROUGE tout doctor de boîte.
  probe_seat_uid
  probe_seat_file

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
      # ⚠ UNE CONSEQUENCE PAR UNITE, ET LA TABLE EST LA POUR QU'ON NE PUISSE PAS EN OUBLIER UNE.
      # Ce message a ete un ternaire sur `lcars-landing`, donc TOUTE autre unite heritait de
      # « personne ne sera enrole ». L'ajout de `lcars-catalogue` a fait dire a un service de
      # catalogue qu'il empechait l'enrolement des humains : la mauvaise porte, au moment ou
      # l'operateur en cherche une.
      local quoi
      case "$u" in
        lcars-landing)   quoi="personne ne peut entrer" ;;
        lcars-converger) quoi="personne ne sera enrole" ;;
        lcars-catalogue) quoi="« lcars catalogue install » refusera, en nommant ce service" ;;
        *)               quoi="consequence NON DECLAREE pour cette unite — ajoute-la ici" ;;
      esac
      p_drift "$u.service posé mais PAS actif — $quoi"
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

  # ⚠ LE REFUS EST ICI, ET IL Y A ÉTÉ DÉPLACÉ APRÈS MESURE. Écrit dans `services_env_body` sous la
  # forme `${LCARS_SYSADMIN_UID:?…}`, il ne refusait RIEN : cette fonction est lue par une
  # substitution de processus (`< <(…)`, plus bas), donc elle tourne dans un SOUS-SHELL dont le
  # parent ne voit jamais le code de sortie. Mesuré : le fichier sortait TRONQUÉ à cette ligne —
  # `LCARS_LANDING_PORT` et `LCARS_PROVISION` disparus, et l'apply rendait 0. Un refus qui produit un
  # succès amputé est pire que le littéral qu'il remplaçait.
  [[ -n "${LCARS_SYSADMIN_UID:-}" ]] || {
    p_fail "LCARS_SYSADMIN_UID non posé — « deploy/provision » le dérive du siège avant tout module. Sans lui, l'environnement des daemons s'écrirait sans la clé que lisent is_fleet_human et uid_floor, qui retomberaient sur le littéral 1000"
    verdict_apply
  }

  ensure_dir "$(dirname "$SERVICES_ENV")" 0755 "$SERVICES_OWNER" || verdict_apply
  # 0640 root:$PROV_FLEET_GROUP : ce n'est pas un secret (une URL, des noms de groupes), mais il n'a
  # aucune raison d'être lisible par tout le monde, et le groupe fleet doit pouvoir le lire pour
  # diagnostiquer sans sudo.
  # ⚠ `$( )` ET PAS `< <( )`, ET C'EST LA CLASSE ENTIÈRE QUI SE FERME. Une substitution de processus
  # jette le code de sortie du corps : n'importe quelle panne à l'intérieur (une variable absente
  # sous `set -u`, `forge_url` qui meurt) produisait un fichier COUPÉ à cette ligne-là et un apply
  # VERT. Le témoin qui l'a montré est celui du port du deck — il lit une ligne écrite après.
  # Une substitution de commande, elle, porte le rc, donc l'échec se dit au lieu de s'écrire à moitié.
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
      p_fail "$u.service redémarre en boucle — $(loop_hint "$u")"
    elif "$SYSTEMCTL" is-active --quiet "$u.service"; then
      p_chg "$u.service activé et debout"
    else
      p_fail "$u.service posé mais pas debout — « $SYSTEMCTL status $u.service » dit pourquoi"
    fi
  done

  converge_humans_now
  verdict_apply
}

# ─── LA CONVERGENCE DES HUMAINS, TIRÉE UNE FOIS ET VÉRIFIÉE ─────────────────────────────────────
#
# ⚠ L'INSTALL RENDAIT LA MAIN SANS SAVOIR SI UN HUMAIN AVAIT ÉTÉ MATÉRIALISÉ. Le convergeur poll
# toutes les 30 s — cadence choisie pour ne pas marteler la forge, pas pour cadencer une install.
# Entre la fin de l'apply et son premier tour, la boîte n'a personne qui puisse lancer une fleet, et
# rien ne le dit.
#
# Pire, mesuré le 2026-08-25 : son premier tour est TOMBÉ (verrou de provision tenu par cette
# passe-là), il a compté « 1 humain(s) convergé(s) » quand même, et `lcars` est resté sans `claude`
# pendant que l'install annonçait 0 échec. Le verrou est réparé — mais rien ne VÉRIFIAIT, et c'est
# ça qui a rendu la panne muette.
#
# ⚠ ON NE FAIT PAS CONFIANCE AU CODE DE RETOUR SEUL. Le convergeur peut rendre 0 en n'ayant converti
# personne (une team vide EST un résultat valide). Ce qui se vérifie est le FAIT : un compte unix
# existe pour un humain de la team. `--once` est documenté en tête de ce script — « une passe, pour
# sonder ou tester » — et rend 1 sur dépendance absente, 2 sur configuration absente.
#
# ⚖ CE N'EST PAS UN ÉCHEC S'IL N'Y A PERSONNE À CONVERGER. Une forge sans membre dans `humans` est
# un état légitime (l'admin n'a pré-semé personne, les gens s'enrôlent eux-mêmes). On le DIT, on ne
# le compte pas comme une faute — la distinction est celle que ce rail applique partout.
converge_humans_now() {
  local conv="${LCARS_HUMAN_CONVERGER:-$HELPERS_DIR/human-converger.sh}"
  [[ -x "$conv" ]] || { p_warn "convergeur d'humains absent ($conv) — aucun humain ne sera matérialisé par cette passe"; return 0; }

  # ⚠ PAS DE GARDE `[[ -r "$SERVICES_ENV" ]]` ICI, ET C'EST DÉLIBÉRÉ. Une relecture a signalé que le
  # `.` du sous-shell échoue en rc=1 si le fichier manque — le MÊME code qu'une dépendance absente du
  # convergeur, donc le même diagnostic pour deux causes. Vrai en soi. Mais l'état est INATTEIGNABLE
  # ici : `apply()` écrit ce fichier trente lignes plus haut et sort en `p_fail`+`verdict_apply` si
  # l'écriture rate. Poser la garde quand même aurait ajouté trois lignes commentées que rien ne peut
  # exécuter — exactement la faute que ce lot corrige ailleurs (`391638668`), écrite en la corrigeant.
  # Si un jour ce bloc est appelé depuis un autre site, la garde redevient nécessaire : c'est la
  # condition, pas le code, qu'il faut relire.

  # ─── LA POPULATION AVANT, ET C'EST ELLE QUI REND LA PHRASE D'APRÈS VRAIE ───────────────────────
  #
  # ⚠ CE BLOC PROUVAIT LA PRÉSENCE ET ANNONÇAIT LA CRÉATION. Il lisait `fleet_humans` UNE fois,
  # après la passe, et imprimait « matérialisé(s) ». Or `fleet_humans` balaie `/etc/passwd` : il
  # répond « qui peut lancer une fleet », une question VOISINE, et vraie indépendamment de cette
  # passe. Sur un RE-ROLL — le cas normal, pas l'exotique — `lcars` survit d'une install précédente :
  # le convergeur pouvait ne rien faire du tout, la ligne disait quand même « matérialisé ».
  #
  # ⚖ USER 2026-08-25, la question exacte : « qu'est-ce qui t'empêche de vérifier que l'user est
  # CRÉÉ côté unix avant de rendre la main ? » — créé, pas présent. La première version répondait à
  # côté, et son témoin consacrait la confusion en semant l'humain DÉJÀ dans le passwd du décor.
  #
  # Une différence de population est la seule mesure qui distingue les deux. Trois états, trois
  # phrases : ce que CETTE passe a posé, ce qui était déjà là, et le vide.
  local avant apres nouveaux
  avant="$(fleet_humans | sort -u)"

  # ⚠ `run_step --ok`, PAS `run_quiet` — ET LA PREMIÈRE VERSION DE CE BLOC ÉTAIT DÉCORATIVE.
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
  run_step --ok 1 --ok 2 "convergence des humains (une passe)" -- \
    env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
    bash -c 'set -a; . "$1"; set +a; exec "$2" --once' _ "$SERVICES_ENV" "$conv" || rc=$?
  [[ "$rc" -eq 0 ]] || return 0   # rc non toléré : `run_step` a déjà compté l'échec et dit pourquoi
  case "$PROV_LAST_RC" in
    0) ;;
    2) p_drift "convergeur d'humains : configuration absente (forge ou jeton système) — aucun humain n'est matérialisé, et « fleet_v2 start » n'aura personne à lancer"
       return 0 ;;
    *) p_drift "convergeur d'humains : passe en échec (rc=$PROV_LAST_RC) — « journalctl -u lcars-converger » dit pourquoi"
       return 0 ;;
  esac

  # LA POPULATION APRÈS. `fleet_humans` applique la règle de GUARD B (`bin/fleet_v2`) : uid dans la
  # plage humaine, et pas le siège. Ce qu'on lit ici est donc exactement « qui peut lancer une fleet ».
  apres="$(fleet_humans | sort -u)"
  # `comm -13` : les lignes du SECOND seul — ceux qui n'étaient pas là avant. Les deux listes sont
  # triées et dédoublonnées juste au-dessus, ce que `comm` exige et ne vérifie pas.
  nouveaux="$(comm -13 <(printf '%s\n' "$avant") <(printf '%s\n' "$apres") | sed '/^$/d')"

  local liste_new liste_all
  liste_new="$(printf '%s' "$nouveaux" | paste -sd' ' -)"
  liste_all="$(printf '%s' "$apres" | paste -sd' ' -)"

  if [[ -n "$liste_new" ]]; then
    # `p_chg`, PAS `p_ok` : un compte qui n'existait pas il y a trois secondes est une MUTATION de
    # cette machine, et `PROV_CHANGED` est le compteur qui la porte. La distinction « posé
    # maintenant » / « constaté présent » n'était pas mesurée — une mutation `p_ok`→`p_chg` laissait
    # les trente témoins verts, parce qu'aucun ne regardait autre chose que le texte.
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "humain(s) de fleet matérialisé(s) PAR CETTE PASSE : $liste_new"
  elif [[ -n "$liste_all" ]]; then
    # LE RE-ROLL. Rien de neuf, mais quelqu'un peut lancer une fleet — l'exigence est tenue, et la
    # phrase ne s'attribue pas un geste qui n'a pas eu lieu.
    p_ok "humain(s) de fleet déjà présent(s) : $liste_all — cette passe n'en a matérialisé aucun de plus"
  else
    # ⚠ PAS DE `:-` SUR CE NOM — même règle que `services_env_body` trente lignes plus haut, et je
    # venais de l'enfreindre. `provision-lib.sh` pose `PROV_HUMANS_TEAM` avant tout module, donc un
    # défaut écrit ici ne peut PAS s'exécuter : il se lit comme une décision et n'en est pas une.
    p_ok "aucun humain à matérialiser — la team « $PROV_HUMANS_TEAM » de la forge est vide. Ce n'est pas une faute : les gens s'enrôlent sur la forge, un propriétaire les ajoute à la team, et le convergeur les matérialise au tour suivant"
  fi

  # ⚠ UN NOM DONNÉ QUE RIEN N'A MATÉRIALISÉ EST UNE DÉRIVE, ET ELLE N'AVAIT AUCUN LECTEUR.
  # « la team est vide, ce n'est pas une faute » est vrai quand personne n'a rien demandé. Ça devient
  # un mensonge dès que l'opérateur a tapé `--fleet-human bob` : il a nommé, et il repart sans bob.
  #
  # LE CAS QUI MORD N'EST PAS EXOTIQUE : `48-forge-host` dérive si `tofu` est absent, mais la forge
  # elle-même est DEBOUT (le compose a réussi). Le convergeur l'interroge, obtient une team vide,
  # rend 0 — et sans cette garde le module concluait « ce n'est pas une faute » alors que la vraie
  # cause est vingt rangs plus haut. Une cause fausse donnée à quelqu'un qui debugge coûte plus cher
  # que pas de cause du tout.
  if [[ -n "${PROV_FLEET_HUMAN:-}" ]] && ! grep -qxF -- "$PROV_FLEET_HUMAN" <<<"$apres"; then
    p_drift "« $PROV_FLEET_HUMAN » a été NOMMÉ et rien ne l'a matérialisé — regarde le verdict de « 48-forge-host » (la forge a-t-elle reçu le compte ?) avant celui du convergeur"
  fi
}

case "${1:?usage: 64-services.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
