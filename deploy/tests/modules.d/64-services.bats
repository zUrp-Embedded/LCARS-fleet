#!/usr/bin/env bats
# SOURCE: deploy/tests/modules.d/64-services.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: bats tests for 64-services — la landing et le convergeur TENUS, pas seulement poses
#
# ⚖ USER 2026-08-21 : « l'installeur doit livrer un systeme qui fonctionne. » Et D2 : ce que
# l'humain voit et utilise, c'est la landing — c'est elle qui doit etre up 100 % du temps.
#
# CE QUE CES TEMOINS FERMENT. Les deux scripts existaient sur le disque et RIEN ne les demarrait sur
# un poste natif. Mesure du 2026-08-21 : la landing tournait en `nohup setsid`, orpheline, sans
# superviseur, invisible d'un `systemctl status`, et morte au premier reboot.
#
# ⚠ CE QUI NE SE MESURE PAS ICI : que systemd demarre reellement les unites. `systemctl` est une
# doublure — ce qui se mesure est la DERIVATION (contenu des unites, ordre des gestes) et le fait
# que « posee » ne soit jamais lu comme « debout ».

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# ⚠ SC2030/SC2031 : CHAQUE `@test` DE BATS EST UN SOUS-SHELL, et c'est la propriete qu'on veut —
# un test ne teinte pas le suivant. Que les variables posees dans un test soient « locales » est
# l'isolation, pas une fuite.
# shellcheck disable=SC2016,SC2030,SC2031

# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC2034 — variable posee pour un sous-processus ou lue par un helper, pas par ce fichier
# shellcheck disable=SC2034

load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  MOD="$BATS_TEST_DIRNAME/../../modules.d/64-services.sh"
  [ -f "$MOD" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=64-services
  export LCARS_SYSTEMD_DIR="$BATS_TEST_TMPDIR/etc/systemd/system"
  export LCARS_SERVICES_ENV="$BATS_TEST_TMPDIR/etc/lcars/services.env"
  # Le fichier que lisent les DEUX moities de GUARD B. Couture de chemin, jamais de valeur.
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/etc/lcars/seat.uid"
  export LCARS_HELPERS_DIR="$BATS_TEST_TMPDIR/opt/lcars"
  export LCARS_SERVICES_OWNER
  LCARS_SERVICES_OWNER="$(id -un):$(id -gn)"
  # La fenetre qui separe « forke » de « debout » dure douze secondes sur une vraie machine. Ce qui
  # se mesure ici est la DECISION prise a ses deux bords, jamais le temps qui passe.
  export LCARS_SERVICES_SETTLE=0
  export PROV_SUBSTRATE=linux
  export PROV_HUMAN
  PROV_HUMAN="$(id -un)"
  # ⚠ POSE PAR `deploy/provision`, COMME LES `PROV_*` AU-DESSUS — pas par ce module. Le runner derive
  # l'uid du SIEGE (l'appelant de l'installeur) avant tout module, et six lecteurs l'attendent :
  # GUARD B, son miroir BEAM, `is_fleet_human`, `45-sudoers-toolchain`, `console-humans.sh` et le
  # plancher `uid_floor` du convergeur. Un decor qui l'omet ne decrit aucune machine reelle — et le
  # temoin d'a cote mesure precisement ce que le module fait quand elle manque VRAIMENT.
  export LCARS_SYSADMIN_UID
  LCARS_SYSADMIN_UID="$(id -u)"
  export PROV_FLEET_GROUP
  PROV_FLEET_GROUP="$(id -gn)"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  # ⚠ LA POPULATION EST UNE DONNEE DU DECOR, POUR TOUS LES TEMOINS — pas seulement ceux du
  # convergeur (`humans_are`, plus bas). `probe_fleet_humans` tourne a chaque `check` : sans decor,
  # il lit le /etc/passwd de la machine qui joue le test, et un « check CONFORME » ne l'est que si
  # elle heberge deja un humain hors siege. Mesure du 2026-08-30, gate de 60-deploy sur un poste
  # neuf (un seul compte, uid 1000, le siege) : deux temoins nominaux rouges, verts partout
  # ailleurs par coincidence. Le siege reste celui qui joue le test — `getent` le resout pour de
  # vrai — et un humain de decor l'accompagne.
  export PASSWD_FILE="$BATS_TEST_TMPDIR/passwd"
  printf 'root:x:0:0:root:/root:/bin/bash\n%s:x:%s:%s::%s:/bin/bash\nzoe:x:4242:4242::/home/zoe:/bin/bash\n' \
    "$(id -un)" "$(id -u)" "$(id -g)" "$HOME" > "$PASSWD_FILE"
  # ⚠ ET SES BORNES AVEC ELLE (lot 15). `fleet_humans` lit `login.defs` par `prov_uid_bounds` : une
  # population de decor sans ses bornes decrit une machine a moitie — ce decor lisait le
  # `/etc/login.defs` de la machine qui joue le test. Sur un poste dont UID_MIN vaut 5000, ou dont
  # login.defs est illisible, `zoe` cesse d'etre un humain de fleet et « check CONFORME » rougit
  # pour un code identique. Le plancher est une DONNEE du systeme, donc il se pose ici (modele :
  # 22-fleet-human.bats) ; MUR I18 (idiom_walls) tient la regle pour tout temoin qui pose une population.
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  printf 'UID_MIN 1000\nUID_MAX 60000\n' > "$PASSWD_DEFS"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  mkdir -p "$LCARS_SYSTEMD_DIR" "$PROV_TOKENS_DIR"
  echo "http://127.0.0.1:3000" > "$PROV_TOKENS_DIR/forge.url"

  # `systemctl` : une doublure qui JOURNALISE ce qu'on lui demande, et dont on pilote le verdict de
  # `is-active`. Une doublure qui se contenterait d'exit 0 laisserait passer une regression sur
  # l'ordre des gestes — et l'ordre est le sujet (daemon-reload AVANT enable).
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/systemctl.calls"
  # 0 = is-active repond OUI. Le decor par defaut decrit une machine SAINE : depuis qu'`apply` verifie
  # la liveness, un defaut « mort » ferait echouer tout apply qui ne parle pas du sujet. Les deux
  # temoins qui veulent un service tombe le posent eux-memes.
  ACTIVE="$BATS_TEST_TMPDIR/active"; echo 0 > "$ACTIVE"
  # Le compteur de redemarrages, et le marqueur qui le fait monter APRES l'enable — comme `Restart=`
  # sur une vraie machine. C'est LUI qui distingue « demarre » de « debout ».
  RESTARTS="$BATS_TEST_TMPDIR/restarts.d"; mkdir -p "$RESTARTS"
  LOOP="$BATS_TEST_TMPDIR/looping"
  SPIN="$BATS_TEST_TMPDIR/spinning"
  cat > "$BINDIR/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$CALLS"
[[ "\$1" == "is-active" ]] && exit "\$(cat "$ACTIVE")"
# ⚠ DEUX DECORS DISTINCTS, ET LE PREMIER NE MODELISAIT PAS CE QUE SON TEMOIN NOMMAIT.
#   $LOOP    -> le compteur SAUTE une fois puis se fige : un REBOND (le service a attendu quelque
#               chose, puis a tenu). C'est ce que le decor faisait deja, sous le nom « boucle ».
#   $SPIN    -> le compteur grimpe a CHAQUE lecture : une vraie BOUCLE.
[[ "\$1" == "show" && -f "$SPIN" ]] && { u="\${@: -1}"; f="$RESTARTS/\${u%.service}"; v=\$(cat "\$f" 2>/dev/null || echo 0); echo \$((v+1)) > "\$f"; echo "\$v"; exit 0; }
[[ "\$1" == "show" ]] && { u="\${@: -1}"; cat "$RESTARTS/\${u%.service}" 2>/dev/null || echo 0; exit 0; }
[[ "\$1" == "enable" && -f "$LOOP" ]] && { u="\${@: -1}"; echo 9 > "$RESTARTS/\${u%.service}"; }
exit 0
EOF
  chmod 0755 "$BINDIR/systemctl"
  export LCARS_SYSTEMCTL="$BINDIR/systemctl"
  export PATH="$BINDIR:$PATH"
}

mod() { run bash "$MOD" "$1"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS + les trois en-tetes de module" {
  run head -9 "$MOD"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
  # ⚠ `wsl` EST DANS L'EN-TETE, ET CE TEMOIN A GRAVE `linux` SEUL PENDANT UNE JOURNEE. Sur un poste
  # WSL le module etait alors SELECTIONNE (CHECK-ON: any) et NON APPLICABLE — un echec structurel que
  # le runner nomme « rebuild l'image », sur un rail qui n'a pas d'image. Le fond suit : `ttyd`, les
  # scripts de console, les dossiers de socket et la release y sont tous poses ; seul le demarrage
  # manquait. (Trouve par le reverse d'alice, 2026-08-21.)
  [[ "$output" == *"APPLY-ON: wsl linux"* ]]
  [[ "$output" == *"CHECK-ON: any"* ]]
  [[ "$output" == *"NEEDS: root"* ]]
}

@test "sans systemd, on ne pose RIEN et on le DIT — un fichier d'unite sans init est un decor" {
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"pas de systemd"* ]]
  [ ! -e "$LCARS_SYSTEMD_DIR/lcars-landing.service" ]
}

@test "apply POSE les deux unites et l'environnement" {
  mod apply
  [ -f "$LCARS_SYSTEMD_DIR/lcars-landing.service" ]
  [ -f "$LCARS_SYSTEMD_DIR/lcars-converger.service" ]
  [ -s "$LCARS_SERVICES_ENV" ]
  grep -q "^FORGE_BASE_URL=http://127.0.0.1:3000$" "$LCARS_SERVICES_ENV"
}

@test "l'environnement porte ce qu'un DAEMON ne peut pas heriter" {
  # Un service n'a ni le shell de l'operateur ni les PROV_* que `provision` exporte le temps d'un
  # apply. Le convergeur lit ces noms-la : s'ils manquent, il converge une autre org, en silence.
  mod apply
  # lot 8 : les daemons sont le PRODUIT, leur env parle LCARS_*
  grep -q "^LCARS_FORGE_ORG=" "$LCARS_SERVICES_ENV"
  grep -q "^LCARS_HUMANS_TEAM=" "$LCARS_SERVICES_ENV"
  refute grep -q "^PROV_" "$LCARS_SERVICES_ENV"
}

@test "l'uid du SIEGE traverse jusqu'a l'environnement des daemons" {
  # ⚠ CE N'ETAIT PAS LE CAS, ET LA LIGNE AVAIT POURTANT L'AIR D'UN POSEUR. Elle s'ecrivait
  # `LCARS_SYSADMIN_UID=${LCARS_SYSADMIN_UID:-1000}` : le SEUL ecrivain d'une variable que six
  # lecteurs attendent recopiait leur defaut au lieu de le remplacer. Les daemons lisaient donc 1000
  # quel que soit le siege — d'accord avec lui par COINCIDENCE, sur une machine ou l'operateur est
  # le premier uid, et faux partout ailleurs.
  export LCARS_SYSADMIN_UID=1007
  mod apply
  [ "$status" -eq 0 ]
  grep -qx 'LCARS_SYSADMIN_UID=1007' "$LCARS_SERVICES_ENV"
  refute grep -q 'LCARS_SYSADMIN_UID=1000' "$LCARS_SERVICES_ENV"
}

@test "l'uid du siege est POSE dans un fichier que le garde ne peut pas reecrire" {
  # ⚠ POURQUOI UN FICHIER ET PAS LA VARIABLE : mesure du 2026-08-27,
  # `LCARS_SYSADMIN_UID=99999 fleet start` desarmait GUARD B. L'environnement d'un processus
  # appartient a ce processus ; une garde ne peut pas y prendre sa politique. `0644` parce que le
  # lecteur est le shell d'un humain quelconque, `root:root` parce que c'est ce qui l'empeche de le
  # reecrire — les deux moities du mode portent chacune la moitie du contrat.
  export LCARS_SYSADMIN_UID=1007
  mod apply
  [ "$status" -eq 0 ]
  [ -f "$LCARS_SEAT_UID_FILE" ]
  [ "$(cat "$LCARS_SEAT_UID_FILE")" = "1007" ]
  [ "$(stat -c '%a' "$LCARS_SEAT_UID_FILE")" = "644" ]
}

@test "le check DERIVE quand le fichier de siege manque — le garde y retombe sur son litteral" {
  mod apply
  rm -f "$LCARS_SEAT_UID_FILE"
  mod check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qE '^DRIFT .*seat\.uid absent'
}

@test "un fichier de siege qui CONTREDIT services.env est un ECHEC, pas une derive" {
  # ⚠ LES DEUX ARTEFACTS SORTENT DE LA MEME DERIVATION, donc un desaccord n'est pas un retard : il
  # veut dire que `uid_floor` (le plancher de creation des humains) et GUARD B (le refus de
  # lancement) ne reservent pas le meme uid. Le convergeur creerait alors des humains sur l'uid que
  # la garde refuse — une machine qui se contredit elle-meme, en silence.
  export LCARS_SYSADMIN_UID=1007
  mod apply
  echo 2008 > "$LCARS_SEAT_UID_FILE"
  mod check
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qE '^FAIL .*ne réservent pas le même uid'
}

@test "sans uid de siege, l'ecriture est ABANDONNEE — jamais tronquee" {
  # ⚠ LE TEMOIN DE LA CICATRICE, ET ELLE EST DE MOI. Le refus a d'abord ete ecrit DANS
  # `services_env_body`, sous la forme `${LCARS_SYSADMIN_UID:?…}`. Cette fonction est lue par une
  # substitution de processus : elle tourne dans un sous-shell dont le parent ignore le code de
  # sortie. Mesure : le fichier sortait COUPE a cette ligne — `LCARS_LANDING_PORT` et
  # `LCARS_PROVISION` absents — et l'apply rendait 0. Un refus qui produit un succes ampute est pire
  # que le litteral qu'il remplacait.
  #
  # Ce temoin garde les DEUX moities : l'apply echoue, ET rien de partiel n'est pose.
  unset LCARS_SYSADMIN_UID
  mod apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"LCARS_SYSADMIN_UID non posé"* ]]
  [ ! -e "$LCARS_SERVICES_ENV" ]
}

@test "le check NOMME le siege qu'il reserve, au lieu de le supposer" {
  mod apply
  mod check
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE "^OK .*siege : « $(id -un) » \(uid $(id -u)\)"
}

@test "un uid de siege que PERSONNE ne porte est un DRIFT — une garde qui ne garde rien" {
  # 4294967294 : hors de toute plage d'uid attribuable. Une garde posee sur un uid inexistant a
  # l'air posee et ne reserve rien — c'est exactement l'etat que le litteral 1000 produisait sur
  # une machine dont le siege n'est pas le premier uid.
  export LCARS_SYSADMIN_UID=4294967294
  mod apply
  mod check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qE '^DRIFT .*ne correspond a AUCUN compte'
}

@test "un environnement SANS ligne de siege derive — le champ absent n'est pas un champ vert" {
  mod apply
  sed -i '/^LCARS_SYSADMIN_UID=/d' "$LCARS_SERVICES_ENV"
  mod check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qE '^DRIFT .*aucun LCARS_SYSADMIN_UID'
}

@test "la landing demarre EN PREMIER PLAN — sinon systemd lit un service mort en une seconde" {
  mod apply
  grep -q -- "ExecStart=$LCARS_HELPERS_DIR/console-landing.sh --foreground" "$LCARS_SYSTEMD_DIR/lcars-landing.service"
  grep -q "^Restart=always$" "$LCARS_SYSTEMD_DIR/lcars-landing.service"
}

@test "AUCUNE unite ne pose User= — la landing se depose ELLE-MEME, avec son groupe de console" {
  # Un `User=` retirerait au script le droit de faire son `setpriv` vers `lcars-system`, et surtout
  # le groupe `lcars-console` : la page s'ouvrirait sur une liste vide en annoncant que tout va bien.
  mod apply
  # ⚠ `refute`, PAS `! grep` — ET LA PREMIERE DES DEUX ETAIT INERTE. Mutation du 2026-08-26 :
  # un `User=` reinjecte dans la SEULE unite `lcars-landing` laissait ce temoin VERT, parce que
  # bash exempte d'`errexit` une commande niee par `!` et que la seconde ligne, elle, reussissait.
  # La regle porte sur les DEUX unites ; une seule des deux etait gardee. Detail : `refute.bash`.
  refute grep -q "^User=" "$LCARS_SYSTEMD_DIR/lcars-landing.service"
  refute grep -q "^User=" "$LCARS_SYSTEMD_DIR/lcars-converger.service"
}

@test "daemon-reload passe AVANT enable — systemd sert l'unite qu'il a en memoire" {
  mod apply
  local reload enable
  reload="$(grep -n "daemon-reload" "$CALLS" | head -1 | cut -d: -f1)"
  enable="$(grep -n "enable --now" "$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$reload" ]
  [ -n "$enable" ]
  [ "$reload" -lt "$enable" ]
}

@test "les deux services sont ACTIVES — ce sont l'infrastructure, pas un choix par humain (D11)" {
  mod apply
  grep -q -- "systemctl enable --now lcars-landing.service" "$CALLS"
  grep -q -- "systemctl enable --now lcars-converger.service" "$CALLS"
}

@test "rejoue : une unite deja identique n'est pas re-ecrite, donc pas de daemon-reload" {
  mod apply
  : > "$CALLS"
  mod apply
  refute grep -q "daemon-reload" "$CALLS"
}

@test "POSEE n'est pas DEBOUT : le check DERIVE sur une unite presente mais inactive" {
  mod apply
  echo 1 > "$ACTIVE"    # is-active : non
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"PAS actif"* ]]
  [[ "$output" == *"personne ne peut entrer"* ]]
  [[ "$output" == *"personne ne sera enrole"* ]]
}

@test "check CONFORME quand les deux unites sont posees ET actives" {
  mod apply
  echo 0 > "$ACTIVE"    # is-active : oui
  mod check
  [ "$status" -eq 0 ]
  [[ "$output" == *"lcars-landing.service actif"* ]]
  [[ "$output" == *"lcars-converger.service actif"* ]]
}

@test "une unite modifiee A LA MAIN est un DRIFT — la source de verite est le module" {
  mod apply
  echo "# bricolage" >> "$LCARS_SYSTEMD_DIR/lcars-converger.service"
  echo 0 > "$ACTIVE"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"lcars-converger.service absente ou divergente"* ]]
}

@test "l'environnement ne REDIT pas les defauts de la lib — un littéral mort se lit comme une décision" {
  # `provision-lib.sh` pose `PROV_FORGE_ORG` et `PROV_HUMANS_TEAM` avant tout module : un `:-fleet`
  # ecrit ici ne peut PAS s'executer. Et il ferait un cinquieme littéral `fleet` pour un nom qui en a
  # deja quatre — le jour d'un renommage, c'est le nombre de copies qui decide combien de lecteurs
  # suivent.
  #
  # ⚠ LES DEUX INTERDICTIONS ETAIENT INERTES, et c'est la troisieme ligne qui portait le verdict.
  # Mutation du 2026-08-26 : un `PROV_FORGE_ORG=${PROV_FORGE_ORG:-fleet}` reinjecte laissait ce
  # temoin VERT — les deux `!` s'executaient, echouaient, et bash les exempte d'`errexit`. Seule la
  # ligne `grep -q 'echo …'` comptait, et elle ne verifie pas ce que le titre promet.
  refute grep -qE 'LCARS_FORGE_ORG=\$\{PROV_FORGE_ORG:-' "$MOD"
  refute grep -qE 'LCARS_HUMANS_TEAM=\$\{PROV_HUMANS_TEAM:-' "$MOD"
  grep -q 'echo "LCARS_FORGE_ORG=\$PROV_FORGE_ORG"' "$MOD"
}

# ─── LE PORT DU DECK — une valeur, les deux bouts ───────────────────────────────────────────────
#
# ⚠ UN PORT CHOISI QUI N'ATTEINT QU'UNE MOITIE DE SES LECTEURS EST PIRE QU'UN PORT FIXE. Mesure du
# 2026-08-23, install a froid : `PROV_DECK_PORT` decrivait les `redirect_uris` OIDC et RIEN d'autre,
# alors que le daemon lit `LCARS_LANDING_PORT`. `--port-deck 20997` deplacait donc l'identification
# vers un port ou personne n'ecoutait pendant que le deck restait sur 20999 — et la panne tombait au
# RETOUR du login, la ou elle se lit comme un probleme d'identite.

@test "le port du deck choisi atteint le DAEMON, pas seulement les callbacks OIDC" {
  export PROV_DECK_PORT=20997
  mod apply
  grep -qx 'LCARS_LANDING_PORT=20997' "$LCARS_SERVICES_ENV"
  grep -q 'sur :20997' "$LCARS_SYSTEMD_DIR/lcars-landing.service"
}

@test "sans choix, le deck garde son port par defaut" {
  mod apply
  grep -qx 'LCARS_LANDING_PORT=20999' "$LCARS_SERVICES_ENV"
}

# ⚠ CONTRE-TEMOIN, ET IL EST LA RAISON D'ETRE DES DEUX PRECEDENTS : seuls, ils passeraient sur un
# module qui ecrirait `LCARS_LANDING_PORT=20999` en dur. Ce qui se prouve ici est que la valeur
# TRAVERSE, pas qu'une ligne existe.
@test "un port arbitraire TRAVERSE jusqu'au fichier d'environnement" {
  export PROV_DECK_PORT=31337
  mod apply
  grep -qx 'LCARS_LANDING_PORT=31337' "$LCARS_SERVICES_ENV"
  refute grep -q '20999' "$LCARS_SERVICES_ENV"
}

# ─── DEBOUT N'EST PAS DEMARRE ───────────────────────────────────────────────────────────────────
#
# ⚠ `enable --now` REND 0 DES QUE SYSTEMD A FORKE. Le bind echoue une milliseconde plus tard, et
# `Restart=` releve le service a chaque cycle : l'install imprimait POSE sur un deck qui n'avait
# jamais servi une seule requete (113 redemarrages mesures sur l'install du 2026-08-23).

@test "l'echec devient TERMINAL — sans borne, aucun observateur ne peut voir un service echouer" {
  mod apply
  grep -q '^StartLimitIntervalSec=' "$LCARS_SYSTEMD_DIR/lcars-landing.service"
  grep -q '^StartLimitBurst=' "$LCARS_SYSTEMD_DIR/lcars-landing.service"
  grep -q '^StartLimitBurst=' "$LCARS_SYSTEMD_DIR/lcars-converger.service"
}

# ⚠ CE TEMOIN NOMMAIT « BOUCLE » UN DECOR QUI MODELISAIT UN REBOND. Son stub posait `NRestarts=9`
# UNE fois, puis le compteur ne bougeait plus — c'est-a-dire un service qui a redemarre en attendant
# quelque chose, puis a tenu. MESURE SUR BANC le 2026-08-28 : `lcars-catalogue` et `lcars-privileged`
# rendus FAIL « redemarre en boucle » avec `NRestarts=33` et `is-active` = OUI, tous deux debout et
# servant — ils avaient attendu la forge, montee pendant la passe. Le verbe accusait un service sain.
#
# Le discriminant n'est ni le compteur seul ni `is-active` seul : une vraie boucle est `active` par
# intermittence, et un rebond laisse un compteur eleve. C'est de savoir s'il GRIMPE ENCORE.

@test "un service qui BOUCLE VRAIMENT (le compteur grimpe encore) fait echouer l'apply" {
  : > "$SPIN"
  mod apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"redémarre en boucle"* ]]
}

@test "un service qui a REBONDI puis tient rend un apply vert — et le rebond est DIT" {
  : > "$LOOP"
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"redemarrage(s)"* ]]
  refute_out 'redémarre en boucle' <<<"$output"
}

@test "un service stable ET actif rend un apply vert" {
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"activé et debout"* ]]
}

# ⚠ CONTRE-TEMOIN du precedent : un service qui ne boucle pas mais ne repond pas non plus doit
# echouer aussi. Sans lui, le compteur de redemarrages serait la seule sonde — et un service mort
# du premier coup, jamais releve, passerait pour debout.
@test "un service pose mais MORT fait echouer l'apply" {
  echo 1 > "$ACTIVE"
  mod apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"pas debout"* ]]
}

# ─── POURQUOI ELLE BOUCLE, DANS LES TERMES DE L'OPERATEUR ──────────────────────────────────────
#
# ⚠ MESURE DU 2026-08-23, DEUXIEME INSTALL : « redemarre en boucle » puis `journalctl` puis un
# traceback Python, pour apprendre qu'un port etait pris. Trois lectures. La cause la plus frequente
# se nomme, et elle nomme le geste qui repare. La sonde ne tourne QU'APRES l'echec : rien a payer sur
# le chemin nominal, et aucun faux positif possible — notre propre service n'arrive justement pas a
# se lier.

@test "un port DEJA PRIS se dit, et nomme --port-deck" {
  # Un squatter reel : il demande le port 0, le noyau en choisit un libre, et il le GARDE le temps
  # du temoin. Epingler un numero en dur ferait dependre le verdict de ce qui tourne sur la machine.
  python3 -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
time.sleep(120)
' "$BATS_TEST_TMPDIR/port" &
  local squatter=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$BATS_TEST_TMPDIR/port" ] && break; sleep 0.2; done
  [ -s "$BATS_TEST_TMPDIR/port" ]

  export PROV_DECK_PORT
  PROV_DECK_PORT="$(cat "$BATS_TEST_TMPDIR/port")"
  : > "$SPIN"   # une VRAIE boucle : ces deux temoins veulent atteindre `loop_hint`
  mod apply
  kill "$squatter" 2>/dev/null || true

  [ "$status" -ne 0 ]
  [[ "$output" == *"le port $PROV_DECK_PORT est DEJA PRIS"* ]]
  [[ "$output" == *"--port-deck"* ]]
}

# ⚠ CONTRE-TEMOIN, ET C'EST LUI QUI TIENT LE PRECEDENT : sans lui, un module qui collerait la phrase
# « port deja pris » a TOUTE unite en boucle passerait. Le convergeur n'ecoute sur rien.
@test "une unite qui n'ecoute sur rien renvoie au journal, pas au port" {
  : > "$SPIN"   # une VRAIE boucle : ces deux temoins veulent atteindre `loop_hint`
  mod apply
  [[ "$output" == *"lcars-converger.service redémarre en boucle — « journalctl"* ]]
  [[ "$output" != *"lcars-converger.service redémarre en boucle — le port"* ]]
}

# ─── LA PASSE DE CONVERGENCE TIREE A LA MAIN, ET SA VERIFICATION ────────────────────────────────
#
# ⚠ L'INSTALL RENDAIT LA MAIN SANS SAVOIR SI UN HUMAIN AVAIT ETE MATERIALISE. Le convergeur poll a
# 30 s — cadence choisie pour ne pas marteler la forge, pas pour cadencer une install. Mesure du
# 2026-08-25 : son premier tour est TOMBE (verrou de provision tenu par la passe elle-meme), il a
# compte « 1 humain(s) converge(s) » quand meme, et `lcars` est reste sans `claude` pendant que
# l'install annoncait 0 echec. Le verrou est repare — mais rien ne VERIFIAIT, et c'est ca qui a
# rendu la panne muette.
#
# ⚖ USER 2026-08-25 : « le convergeur il poll a 30s par defaut pour pas spoof le reseau, mais ya quoi
# qui t'empeche de le declencher une fois a la main juste apres avoir seme l'user sur la forge ? et
# qu'est-ce qui t'empeche de verifier que l'user est cree cote unix avant de rendre la main ? »
# ⚠ LA DOUBLURE NE CREAIT PERSONNE, ET LE TEMOIN ASSERAIT « MATERIALISE ». Premiere version : elle
# journalisait son env et sortait. Le decor semait l'humain DEJA dans le passwd, puis le temoin
# verifiait que le message dit « materialise » — il fixait donc exactement l'etat que le defaut
# produit, et ne pouvait pas distinguer « cree par cette passe » de « la depuis un autre run ».
#
# Une doublure de convergeur doit pouvoir CREER : c'est son metier, et c'est la seule chose qui
# separe les deux phrases. Elle ecrit dans le `PASSWD_FILE` du decor — chemin cuit dans le script,
# parce que `env -i` coupe l'heritage et que la doublure ne le recevrait pas autrement.
stub_converger() { # stub_converger <rc> [<ligne passwd a creer>…]
  export LCARS_HUMAN_CONVERGER="$BATS_TEST_TMPDIR/conv.sh"
  CONV_ENV="$BATS_TEST_TMPDIR/conv.env"
  local rc="$1"; shift
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "env | sort > '$CONV_ENV'"
    printf '%s\n' "printf 'ARGS=%s\\n' \"\$*\" >> '$CONV_ENV'"
    local l; for l in "$@"; do printf '%s\n' "printf '%s\\n' '$l' >> '$PASSWD_FILE'"; done
    printf '%s\n' "exit $rc"
  } > "$LCARS_HUMAN_CONVERGER"
  chmod 0755 "$LCARS_HUMAN_CONVERGER"
}

# La population d'humains est une DONNEE du decor : sans ca ces temoins lisent le /etc/passwd de la
# machine qui les joue, et repondent sa composition au lieu de la regle.
humans_are() {
  export PASSWD_FILE="$BATS_TEST_TMPDIR/passwd"
  printf 'root:x:0:0:root:/root:/bin/bash\n' > "$PASSWD_FILE"
  printf 'siege:x:1000:1000::/home/siege:/bin/bash\n' >> "$PASSWD_FILE"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$PASSWD_FILE"; done
  export LCARS_SYSADMIN_UID=1000
}

# ⚠ `! grep -q …` N'EST PAS UNE ASSERTION TANT QU'IL N'EST PAS LA DERNIERE INSTRUCTION. Bash exempte
# d'`errexit` toute commande niee par `!` : la ligne s'execute, echoue, et le test continue jusqu'a
# la suivante. Mesure : `! grep -q '^PROV_TOKENS_DIR='` suivi d'un second `! grep` etait INERTE — en
# reinjectant `PROV_TOKENS_DIR` dans l'`env -i` du module, le temoin restait VERT alors que
# l'isolation qu'il garde etait violee. C'est le meme piege que dans `human_converger.bats`, et je
# l'avais ecrit dans le brief de relecture avant de le commettre ici.
#
# Un appel de fonction, lui, EST soumis a `errexit`. La negation vit donc dans la fonction.
absent_de_l_env() { # absent_de_l_env <motif ancre>
  if grep -q "$1" "$CONV_ENV"; then
    echo "FUITE : « $1 » present dans l'environnement de la passe, alors que le daemon ne l'aura jamais"
    return 1
  fi
  return 0
}

@test "convergeur ABSENT : on le DIT, et ce n'est pas un echec d'apply" {
  # Le cas d'un rail incomplet. Un `p_fail` ici ferait echouer une install pour un auxiliaire dont
  # `62-runtime-helpers` a deja la charge — et dont l'absence se voit la-bas.
  humans_are
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"convergeur d'humains absent"* ]]
}

@test "la passe est TIREE UNE FOIS, en --once — pas un daemon de plus" {
  humans_are 'lcars:x:1001:1001::/home/lcars:/bin/bash'
  stub_converger 0
  mod apply
  [ "$status" -eq 0 ]
  [ -f "$CONV_ENV" ]
  grep -qx 'ARGS=--once' "$CONV_ENV"
}

@test "L'ENVIRONNEMENT DE LA PASSE EST CELUI DU DAEMON, PAS CELUI DE L'APPLY" {
  # ⚠ LE TEMOIN QUI FERME LE VRAI TROU. L'unite charge `EnvironmentFile=-$SERVICES_ENV` et RIEN
  # d'autre ; cet apply, lui, a tous les `PROV_*` que `provision` exporte. Une premiere version
  # tirait la passe depuis notre propre environnement : elle aurait valide un chemin que le service
  # ne peut PAS reprendre au boot — vert a l'install, mort au premier redemarrage. C'est la classe
  # exacte que ce depot traque partout : mesurer le mecanisme au lieu de l'exigence.
  humans_are 'lcars:x:1001:1001::/home/lcars:/bin/bash'
  stub_converger 0
  mod apply
  [ "$status" -eq 0 ]
  # CE QUI VIENT DU FICHIER — donc ce que le daemon aura aussi.
  grep -q '^LCARS_HUMANS_TEAM=' "$CONV_ENV"
  grep -q '^FORGE_BASE_URL=http://127.0.0.1:3000$' "$CONV_ENV"
  # CE QUI N'EN VIENT PAS — et que le daemon n'aura jamais. `PROV_TOKENS_DIR` n'existe que le temps
  # d'un apply ; s'il fuit ici, la passe reussit pour une raison que le boot n'aura pas.
  absent_de_l_env '^PROV_TOKENS_DIR='
  absent_de_l_env '^PROV_SUBSTRATE='
}

# ─── CREE PAR CETTE PASSE, OU DEJA LA : DEUX ETATS, DEUX PHRASES ────────────────────────────────
#
# ⚠ LE MODULE PROUVAIT LA PRESENCE ET ANNONCAIT LA CREATION. `fleet_humans` balaie `/etc/passwd` :
# il repond « qui peut lancer une fleet », une question VOISINE, vraie independamment de la passe.
# Sur un RE-ROLL — le cas normal — `lcars` survit d'une install precedente, et la ligne disait
# « materialise » meme si le convergeur n'avait rien fait.
#
# ⚖ USER 2026-08-25, la question exacte : « qu'est-ce qui t'empeche de verifier que l'user est CREE
# cote unix avant de rendre la main ? » — cree, pas present.
#
# ⚠ ET LES DEUX MESSAGES CONTIENNENT LE MOT « materialise ». Assertion sur le mot = tautologie ;
# c'est ce qui a laisse passer la premiere version. On assere le SEGMENT exact, et le PREFIXE de
# ligne — `POSÉ` pour une mutation, `OK` pour un constat — que rien ne mesurait non plus.

@test "un humain CREE PAR CETTE PASSE est annonce comme tel, et compte comme une mutation" {
  # Le decor part d'une machine SANS humain, et la doublure en cree un : c'est la seule forme qui
  # distingue les deux etats.
  humans_are
  stub_converger 0 'lcars:x:1001:1001::/home/lcars:/bin/bash'
  mod apply
  [ "$status" -eq 0 ]
  # ⚠ SUR LA LIGNE, PAS SUR TOUTE LA SORTIE. Un glob `*"POSÉ"*"lcars"*` traverse les sauts de ligne :
  # il serait vert grace a un `POSÉ` d'unite systemd et a un `lcars` de nom de service, sans que la
  # ligne qui nous interesse existe. `grep` ancre au debut de ligne mesure la BONNE ligne.
  # `POSÉ`, pas `OK` : un compte qui n'existait pas il y a trois secondes est une mutation, et une
  # mutation `p_chg`→`p_ok` laissait les trente temoins verts.
  printf '%s\n' "$output" | grep -qE '^POSÉ .*matérialisé\(s\) PAR CETTE PASSE : lcars'
}

@test "un humain DEJA LA n'est pas annonce comme cree — le cas du RE-ROLL" {
  # ⚠ LE TEMOIN QUI MANQUAIT, ET SANS LEQUEL LE PRECEDENT NE PROUVE RIEN. Le decor porte deja
  # l'humain, la doublure ne cree personne : si le module s'attribuait la population trouvee, c'est
  # ICI que ca se voit, et nulle part ailleurs.
  humans_are 'lcars:x:1001:1001::/home/lcars:/bin/bash'
  stub_converger 0
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"PAR CETTE PASSE"* ]]
  # Un CONSTAT, pas une mutation : la ligne porte `OK`, jamais `POSÉ`. Meme raison qu'au temoin
  # precedent — l'ancrage est sur la ligne, sinon un `POSÉ` d'unite systemd suffit a la rendre verte.
  printf '%s\n' "$output" | grep -qE '^OK .*déjà présent\(s\) : lcars'
  printf '%s\n' "$output" | refute_out '^POSÉ .*(déjà présent|lcars.*matérialis)'
}

@test "AUCUN humain a materialiser : la team vide est DITE, et ce n'est pas une derive" {
  # ⚖ USER 2026-08-25 : « en prod (le mode boite), on peut se passer de pre-seed un user (…) et
  # l'inscription reste ouverte sur la forge. » Une team `humans` vide est un etat legitime.
  #
  # ⚠ CE TEMOIN EXIGEAIT EN PLUS UNE DERIVE, ET C'EST SON PERIMETRE QUI A CHANGE (⚖ user
  # 2026-08-30). La phrase de 2026-08-25 disait « en prod (le mode boite) » parce qu'a cette date le
  # POSTE etait pense comme une demo — « le poste/bench c'est pour la demo », meme arbitrage. Le
  # poste est un deploiement de TRAVAIL : la meme doctrine s'y applique, et le rail n'y pre-seme
  # plus rien. Il ne reste donc aucun compte dont l'absence serait un manquement.
  #
  # La premiere phrase — celle qui EXPLIQUE pourquoi la population est vide — survit seule, et elle
  # se suffit : la cause est dite, et il n'y a plus de consequence a nommer.
  humans_are
  stub_converger 0
  mod apply
  # ⚠ 0 ET PLUS 2, ET C'EST TOUTE LA MESURE. Le drift residuel de ce decor, c'etait l'absence
  # d'humain elle-meme — il n'en reste aucun autre. Un apply qui CONVERGE sur une machine sans
  # personne est exactement ce que le canon affirme : un deploiement neuf est convergé, il attend
  # son premier inscrit. C'est cette ligne qui, seule, distingue « il attend » de « il a echoue ».
  [ "$status" -eq 0 ]
  [[ "$output" == *"aucun humain à matérialiser"* ]]
  # ⚠ LA SEVERITE SE MESURE AUSSI, DANS L'AUTRE SENS MAINTENANT : cette branche EXPLIQUE un etat,
  # elle ne le juge pas. Un `p_warn` ici ferait du bruit permanent sur une forge dont la team se
  # remplit encore, et un `p_drift` re-condamnerait tout deploiement neuf.
  [[ "$output" != *"WARN"*"aucun humain"* ]]
  [[ "$output" != *"DRIFT"*"aucun humain à matérialiser"* ]]
  # ET PLUS AUCUN COMPTE N'EST NOMME : ce rail n'en pre-seme plus, donc il n'en attend plus.
  [[ "$output" != *"pré-sème"* ]]
}

# ⚠ TROIS TEMOINS ONT DISPARU ICI AVEC LEUR SUJET (⚖ user 2026-08-30) — « la garde nomme le compte
# que L'AUTORITE declare », « le compte pre-seme BIEN materialise ne derive pas » et « AUTORITE
# MUETTE : on ne devine pas un nom ». Ils tenaient un bloc de `64-services` qui verifiait, apres la
# passe du convergeur, que « l'humain que ce rail pre-seme » avait bien ete materialise.
#
# Le rail ne pre-seme plus : il pose les AUTORITES, et les personnes s'inscrivent sur la forge sous
# leur nom. Il n'y a donc plus de compte attendu dont l'absence serait une derive — et le bloc
# contredisait deja son propre voisin, six lignes plus haut, qui disait « ce n'est pas une faute »
# du meme fait.
#
# CE QUI SURVIT, ET QUI ETAIT LE MOTIF LE PLUS FIN DES TROIS : « un nom indeterminable et un compte
# absent appellent deux gestes opposes ». Il n'a plus de porteur ici parce qu'aucun nom n'est plus
# demande — mais la regle vaut toujours partout ou une autorite est interrogee, et `fleet_human.bats`
# la mesure encore sur son propre terrain.
@test "un environnement de services NON POSE arrete l'apply AVANT la passe — pas de garde en double" {
  # ⚠ CE TEMOIN A FAILLI GARDER UNE GARDE INATTEIGNABLE. Une relecture demandait un `[[ -r ]]` avant
  # la passe, au motif qu'un fichier absent rend le meme rc=1 qu'une dependance manquante. Vrai en
  # soi — mais `apply()` ECRIT ce fichier plus haut et sort en `p_fail` si l'ecriture rate, donc
  # l'etat n'existe pas au moment de la passe. Ce qui se mesure est donc l'INVARIANT qui rend la
  # garde inutile : une ecriture ratee arrete l'apply, et la passe n'est jamais tiree.
  humans_are
  stub_converger 0
  # Le repertoire de l'environnement est remplace par un FICHIER : `ensure_dir` ne peut pas le creer.
  rm -rf "$BATS_TEST_TMPDIR/etc/lcars"
  : > "$BATS_TEST_TMPDIR/etc/lcars"
  mod apply
  [ "$status" -ne 0 ]
  # La passe n'a pas ete tiree : la doublure n'a jamais tourne.
  [ ! -f "$BATS_TEST_TMPDIR/conv.env" ]
}

# ─── LA SONDE D'HUMAINS DU CHECK — LE TROU DE LA BOITE ──────────────────────────────────────────
#
# ─── LA SONDE D'HUMAINS DU CHECK — ELLE DIT, ELLE NE COMPTE PAS ─────────────────────────────────
#
# ⚠ SUR UNE BOITE DE PRODUCTION, AUCUN MODULE NE VERIFIAIT QU'IL EXISTE UN HUMAIN. `22-fleet-human`
# et `48-forge-host` portent `CHECK-ON: wsl linux` : en docker ils ne sont meme pas SELECTIONNES.
# Ce module-ci est `CHECK-ON: any` — le seul a tourner la-bas — et il sortait AVANT toute sonde des
# l'absence de systemd. Un `provision doctor` sur une boite annoncait donc 0 faute pendant que
# GUARD B aurait refuse tout `fleet start`, faute de compte. La sonde a ete ajoutee pour ca.
#
# ⚠ ELLE A D'ABORD DERIVE, ET C'ETAIT L'ERREUR SYMETRIQUE (⚖ arbitrage user 2026-08-30). Aucun
# deploiement de travail ne fabrique d'humain : le rail pose les AUTORITES, les personnes s'enrolent
# par la page d'inscription de la forge. Zero humain est donc l'etat NOMINAL d'une machine neuve,
# poste comme boite — pas une derive. Compte comme drift, il devenait un ECHEC de convergence sur
# docker (D6, `apply:check`), donc une boite de production jamais convergee tant que personne ne
# s'inscrit. Le meme entrypoint publiait `provision.rc=1` a cote de `humans.rc=0`.
#
# Les deux temoins ci-dessous tiennent les DEUX moities : la sonde parle, et elle ne compte pas.

@test "check SANS systemd sonde quand meme la population — le cas exact de la boite" {
  # Le decor coupe systemd : c'est le chemin de la boite, et c'est celui ou la sonde manquait.
  humans_are
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  box_services_present
  mod check
  [[ "$output" == *"aucun humain de fleet sur cette machine"* ]]
  [[ "$output" == *"fleet start"* ]]
}

@test "check SANS systemd et SANS humain : la sonde DIT l'absence sans la compter comme derive" {
  # ⚠ LES DEUX ASSERTIONS SONT LOAD-BEARING, ET ELLES DISENT DES CHOSES OPPOSEES. Le `grep` interdit
  # qu'on rende la sonde muette « puisqu'elle ne derive plus » — ce serait revenir au trou d'avant.
  # Le `status -eq 0` interdit qu'on la remette en drift — ce serait re-condamner toute boite neuve.
  # Une regression d'un cote OU de l'autre rougit ici.
  humans_are
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  box_services_present
  mod check
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^WARN .*aucun humain de fleet sur cette machine'
}

# LE DECOR DE LA MECANIQUE DE BOITE — sans systemd, le module ne verifie plus des unites mais
# `supervise.sh` et les programmes que nomme STARTERS. Un temoin qui mesure AUTRE CHOSE doit les
# poser, sinon il derive sur une cause etrangere a son sujet et son echec accuse la mauvaise ligne.
box_services_present() {
  local d="$BATS_TEST_TMPDIR/helpers" p
  mkdir -p "$d"
  for p in supervise.sh console-landing.sh human-converger.sh catalogue-executor.py privileged-executor.py; do
    printf '#!/bin/sh\n' > "$d/$p"
    chmod 0755 "$d/$p"
  done
  export LCARS_HELPERS_DIR="$d" LCARS_SUPERVISE_BIN="$d/supervise.sh"
}

@test "check SANS systemd et AVEC un humain : la sonde le nomme et ne derive pas" {
  # ⚠ LE PENDANT, ET SANS LUI LA SONDE POURRAIT DERIVER TOUJOURS. Elle sort avant la branche
  # systemd : si elle rougissait sur une machine saine, tout doctor de boite deviendrait rouge.
  humans_are 'lcars:x:1001:1001::/home/lcars:/bin/bash'
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  box_services_present
  mod check
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^OK .*humain\(s\) de fleet sur cette machine : lcars'
}

@test "rc 2 (configuration absente) : DRIFT residuel, JAMAIS un echec d'apply" {
  # ⚠ ET C'EST LA QUE LA PREMIERE VERSION MENTAIT. Elle passait par `run_quiet`, qui `p_fail`-e sur
  # tout rc non nul : les trois branches du `case` lisaient un code dont le verdict etait deja tombe
  # en ECHEC deux lignes plus haut. Ecrites, commentees, sans effet.
  humans_are
  stub_converger 2
  mod apply
  [ "$status" -eq 2 ]     # apply : 2 = applique, drift residuel — PAS 1
  [[ "$output" == *"configuration absente"* ]]
}

@test "rc 1 (dependance absente) : DRIFT residuel aussi — le daemon reessaiera" {
  humans_are
  stub_converger 1
  mod apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"journalctl"* ]]
}

@test "un rc INATTENDU reste un echec entier — la tolerance est bornee, pas generale" {
  # Sans ce pendant, tolerer TOUT passerait les deux temoins precedents (P-40). 1 et 2 sont des
  # etats que le convergeur DOCUMENTE ; 7 est une panne qu'on ne connait pas, donc un echec.
  humans_are
  stub_converger 7
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "unit_body sur une unite INCONNUE rend 1 sans rien ecrire — et l'apply capture ce rc" {
  # `write_atomic … < <(unit_body "$u")` laissait `cat` lire un flux vide sur un rc 1 : le fichier
  # d'unite etait ecrit VIDE et l'apply rendait 0. La forme sure capture d'abord, puis ecrit par
  # here-string. Le mur I1 (idiom_walls.bats) interdit l'ancienne forme dans tout deploy/.
  eval "$(sed -n '/^unit_body()/,/^}/p' "$MOD")"
  run unit_body lcars-nexistepas
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -vE '^[[:space:]]*#' "$MOD" | grep -qE 'body="\$\(unit_body "\$u"\)"'
  grep -vE '^[[:space:]]*#' "$MOD" | grep -qE 'write_atomic "\$\(unit_path "\$u"\)" [^<]*<<<"\$body"'
}

@test "forge_url : sans forge.url, vide et 0 — une adresse pas encore annoncee n'est pas un echec" {
  # `[[ -r "$f" ]] && head …` rendait 1 sur un fichier absent : tout appelant qui capture par
  # affectation sous set -e mourrait sans verdict. Mur I3 (idiom_walls).
  eval "$(sed -n '/^forge_url()/,/^}/p' "$MOD")"
  PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/tokens"
  run forge_url
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  mkdir -p "$PROV_TOKENS_DIR"; printf 'http://forge.test:3000\n' > "$PROV_TOKENS_DIR/forge.url"
  run forge_url
  [ "$status" -eq 0 ]
  [ "$output" = "http://forge.test:3000" ]
}

@test "probe_seat_uid : services.env ABSENT est une derive DITE, pas une mort de sed sous pipefail" {
  # `declared="$(sed -n … "$SERVICES_ENV" | head -n1)"` : sed rend 2 sur un fichier absent, pipefail
  # le propage, l affectation echoue et set -e tuait check() AVANT le p_drift qui savait le dire.
  # Le site voisin (probe_seat_file) avait son `|| true` ; celui-ci non. env_field ne meurt jamais.
  run bash -c 'set -euo pipefail; export PROVISION_MODULE=64-services; source "$PROVISION_LIB"
    SERVICES_ENV="$1"; SEAT_UID_FILE=/nonexistent/seat.uid
    eval "$(sed -n "/^probe_seat_uid()/,/^}/p" "$2")"; probe_seat_uid' _ "$BATS_TEST_TMPDIR/absent/services.env" "$MOD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT"*"LCARS_SYSADMIN_UID"* ]]
}

# ─── LE SUBSTRAT CHOISIT LA MECANIQUE, PAS L'ABSENCE DE SYSTEMD ─────────────────────────────────

@test "WSL sans systemd ACTIF : on ne cherche pas un superviseur de boite" {
  # ⚠ CE CAS EST LE PREMIER APPLY DE TOUT POSTE WSL, ET AUCUN TEMOIN NE LE COUVRAIT. `30-wsl` pose
  # `systemd=true` dans `wsl.conf`, mais il ne prend effet qu'apres un `wsl --shutdown` : a cet
  # instant `/run/systemd/system` n'existe pas encore. Une branche conditionnee a la seule absence
  # de systemd envoyait donc un POSTE chercher `supervise.sh` — la mecanique de la BOITE, qui n'est
  # pas la — et deriver sur son absence.
  #
  # Regression introduite et attrapee le meme jour (2026-08-30), en changeant `have_systemd` pour le
  # test canonique. Le correctif etait bon ; c'est la branche qui le suivait qui melangeait deux
  # questions : « quelle mecanique tient les services ici » (le SUBSTRAT) et « systemd est-il
  # utilisable » (la sonde).
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  PROV_SUBSTRATE=wsl mod check
  [[ "$output" == *"pas de systemd"* ]]
  [[ "$output" != *"superviseur"* ]]
}

@test "TEMOIN DU TEMOIN : sur DOCKER, c'est bien le superviseur qu'on regarde" {
  # Sans lui, rendre la branche boite inatteignable passerait le temoin ci-dessus.
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  PROV_SUBSTRATE=docker mod check
  [[ "$output" == *"superviseur"* ]]
}

@test "un service qui ne monte pas PORTE sa cause — il ne renvoie pas a un second geste" {
  # ⚠ « status dit pourquoi » EST UN REMEDE QU'ON NE PEUT PAS TOUJOURS JOUER. Sur un rail lance en
  # fond, ou depuis un log relu le lendemain, ce second geste n'existe plus : le journal a tourne, la
  # session est fermee. C'est le motif que ce rail combat partout ailleurs — un diagnostic juste dont
  # l'action est introuvable.
  #
  # ⚠ ET `loop_hint` SAVAIT DEJA NOMMER LA CAUSE, SUR UNE SEULE BRANCHE. Un service qui a epuise son
  # plafond de redemarrages n'est plus `is-active` ET son compteur ne monte plus : ni « boucle » ni
  # « debout ». Il tombait dans la branche muette. Mesure du banc 2004 (2026-08-31) : le landing ne
  # montait pas, cause reelle « Address already in use » sur le port du deck.
  local code; code="$(grep -vE '^\s*#' "$MOD")"
  # Les DEUX branches d'echec nomment la cause, et par la meme fonction.
  grep -q 'p_fail "$u.service redémarre en boucle — $(loop_hint' <<<"$code"
  grep -q 'p_fail "$u.service posé mais pas debout$(unit_cause' <<<"$code"
  refute grep -q 'pas debout — « \$SYSTEMCTL status' <<<"$code"
  # `unit_cause` s'appuie sur `loop_hint` : une seule table de causes, pas deux qui derivent.
  local corps; corps="$(sed -n '/^unit_cause()/,/^}/p' "$MOD")"
  grep -q 'loop_hint' <<<"$corps"
  # ⚠ UN JOURNAL ABSENT EST UNE REPONSE, PAS UNE PANNE : le module tourne aussi dans un conteneur
  # sans systemd persistant. La lecture ne doit pas pouvoir tuer le verdict qu'elle decrit.
  grep -q '|| true' <<<"$corps"
}

# ─── DI-09 (lot 11) : le siege se GRAVE meme sans systemd ─────────────────────────────────────
# `seat.uid` et `services.env` sont des FAITS de la machine (qui est le siege, ce que les daemons
# lisent) ; les unites systemd sont une MECANIQUE. Sans init, la mecanique s'abstient et le dit —
# les faits se posent quand meme, sinon GUARD B refuse tout lancement sur une machine sans systemd
# pour une raison qui n'a rien a voir avec systemd.
@test "sans systemd, seat.uid et services.env sont POSES quand meme — seules les unites s'abstiennent" {
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  export LCARS_SYSADMIN_UID=1007
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"pas de systemd"* ]]
  [ "$(cat "$LCARS_SEAT_UID_FILE")" = "1007" ]
  grep -q '^LCARS_SYSADMIN_UID=1007$' "$LCARS_SERVICES_ENV"
  [ ! -e "$LCARS_SYSTEMD_DIR/lcars-landing.service" ]
}
