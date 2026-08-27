#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/services_units.bats
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

load refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  MOD="$BATS_TEST_DIRNAME/../modules.d/64-services.sh"
  [ -f "$MOD" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export PROVISION_MODULE=64-services
  export LCARS_SYSTEMD_DIR="$BATS_TEST_TMPDIR/etc/systemd/system"
  export LCARS_SERVICES_ENV="$BATS_TEST_TMPDIR/etc/lcars/services.env"
  export LCARS_HELPERS_DIR="$BATS_TEST_TMPDIR/opt/lcars"
  export LCARS_SERVICES_OWNER="$(id -un):$(id -gn)"
  # La fenetre qui separe « forke » de « debout » dure douze secondes sur une vraie machine. Ce qui
  # se mesure ici est la DECISION prise a ses deux bords, jamais le temps qui passe.
  export LCARS_SERVICES_SETTLE=0
  export PROV_SUBSTRATE=linux
  export PROV_HUMAN="$(id -un)"
  # ⚠ POSE PAR `deploy/provision`, COMME LES `PROV_*` AU-DESSUS — pas par ce module. Le runner derive
  # l'uid du SIEGE (l'appelant de l'installeur) avant tout module, et six lecteurs l'attendent :
  # GUARD B, son miroir BEAM, `is_fleet_human`, `45-sudoers-toolchain`, `console-humans.sh` et le
  # plancher `uid_floor` du convergeur. Un decor qui l'omet ne decrit aucune machine reelle — et le
  # temoin d'a cote mesure precisement ce que le module fait quand elle manque VRAIMENT.
  export LCARS_SYSADMIN_UID="$(id -u)"
  export PROV_FLEET_GROUP="$(id -gn)"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
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
  cat > "$BINDIR/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$CALLS"
[[ "\$1" == "is-active" ]] && exit "\$(cat "$ACTIVE")"
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
  grep -q "^PROV_FORGE_ORG=" "$LCARS_SERVICES_ENV"
  grep -q "^PROV_HUMANS_TEAM=" "$LCARS_SERVICES_ENV"
  grep -q "^LCARS_PROVISION=$LCARS_HELPERS_DIR/fleet/deploy/provision$" "$LCARS_SERVICES_ENV"
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
  # `User=nobody` retirerait au script le droit de faire son `setpriv`, et surtout le groupe
  # `lcars-console` : la page s'ouvrirait sur une liste vide en annoncant que tout va bien.
  mod apply
  # ⚠ `refute`, PAS `! grep` — ET LA PREMIERE DES DEUX ETAIT INERTE. Mutation du 2026-08-26 :
  # `User=nobody` reinjecte dans la SEULE unite `lcars-landing` laissait ce temoin VERT, parce que
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
  ! grep -q "daemon-reload" "$CALLS"
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
  refute grep -qE 'PROV_FORGE_ORG=\$\{PROV_FORGE_ORG:-' "$MOD"
  refute grep -qE 'PROV_HUMANS_TEAM=\$\{PROV_HUMANS_TEAM:-' "$MOD"
  grep -q 'echo "PROV_FORGE_ORG=\$PROV_FORGE_ORG"' "$MOD"
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
  ! grep -q '20999' "$LCARS_SERVICES_ENV"
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

@test "un service qui BOUCLE sur son echec fait echouer l'apply" {
  : > "$LOOP"
  mod apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"redémarre en boucle"* ]]
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

  export PROV_DECK_PORT="$(cat "$BATS_TEST_TMPDIR/port")"
  : > "$LOOP"
  mod apply
  kill "$squatter" 2>/dev/null || true

  [ "$status" -ne 0 ]
  [[ "$output" == *"le port $PROV_DECK_PORT est DEJA PRIS"* ]]
  [[ "$output" == *"--port-deck"* ]]
}

# ⚠ CONTRE-TEMOIN, ET C'EST LUI QUI TIENT LE PRECEDENT : sans lui, un module qui collerait la phrase
# « port deja pris » a TOUTE unite en boucle passerait. Le convergeur n'ecoute sur rien.
@test "une unite qui n'ecoute sur rien renvoie au journal, pas au port" {
  : > "$LOOP"
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
  grep -q '^PROV_HUMANS_TEAM=' "$CONV_ENV"
  grep -q '^FORGE_BASE_URL=http://127.0.0.1:3000$' "$CONV_ENV"
  grep -q "^LCARS_PROVISION=$LCARS_HELPERS_DIR/fleet/deploy/provision$" "$CONV_ENV"
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
  ! printf '%s\n' "$output" | grep -qE '^POSÉ .*(déjà présent|lcars.*matérialis)'
}

@test "AUCUN humain a materialiser n'est PAS une faute — zero et vide se distinguent" {
  # ⚖ USER 2026-08-25 : « en prod (le mode boite), on peut se passer de pre-seed un user (…) et
  # l'inscription reste ouverte sur la forge. » Une team `humans` vide est donc un etat legitime.
  # Un DRIFT ici ferait rougir toute install de production qui n'a pre-seme personne.
  humans_are
  stub_converger 0
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"aucun humain à matérialiser"* ]]
  # ⚠ LA SEVERITE SE MESURE AUSSI. Une mutation `p_ok`→`p_warn` sur cette branche laissait les
  # trente temoins verts : en production, une forge dont la team se remplit encore verrait un WARN
  # a chaque apply — du bruit permanent sur un etat normal.
  [[ "$output" != *"WARN"*"aucun humain"* ]]
}

@test "un humain NOMME que rien n'a materialise est un DRIFT — pas « la team est vide »" {
  # ⚠ « ce n'est pas une faute » EST VRAI QUAND PERSONNE N'A RIEN DEMANDE, et devient un mensonge
  # des que l'operateur a tape `--fleet-human bob` : il a nomme, et il repart sans bob.
  #
  # Le cas qui mord n'est pas exotique : `48-forge-host` derive si `tofu` manque, mais la forge est
  # DEBOUT (le compose a reussi). Le convergeur l'interroge, obtient une team vide, rend 0 — et sans
  # cette garde le module concluait « ce n'est pas une faute » alors que la cause est vingt rangs
  # plus haut. Une cause fausse coute plus cher a celui qui debugge que pas de cause du tout.
  humans_are
  stub_converger 0
  PROV_FLEET_HUMAN=bob mod apply
  [ "$status" -eq 2 ]     # applique, drift residuel
  [[ "$output" == *"« bob » a été NOMMÉ et rien ne l'a matérialisé"* ]]
  [[ "$output" == *"48-forge-host"* ]]
}

@test "un humain NOMME et BIEN materialise ne derive pas — le pendant du precedent" {
  # Sans lui, une garde qui deriverait TOUJOURS des qu'un nom est pose passerait le temoin ci-dessus.
  humans_are
  stub_converger 0 'bob:x:1001:1001::/home/bob:/bin/bash'
  PROV_FLEET_HUMAN=bob mod apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"a été NOMMÉ et rien"* ]]
}

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
# ⚠ SUR UNE BOITE DE PRODUCTION, AUCUN MODULE NE VERIFIAIT QU'IL EXISTE UN HUMAIN. `22-fleet-human`
# et `48-forge-host` portent `CHECK-ON: wsl linux` : en docker ils ne sont meme pas SELECTIONNES.
# Ce module-ci est `CHECK-ON: any` — le seul a tourner la-bas — et il sortait en `p_warn` des
# l'absence de systemd, AVANT toute sonde. Un `provision doctor` sur une boite annoncait donc 0
# faute pendant que GUARD B aurait refuse tout `fleet_v2 start`, faute de compte.

@test "check SANS systemd sonde quand meme la population — le cas exact de la boite" {
  # Le decor coupe systemd : c'est le chemin de la boite, et c'est celui ou la sonde manquait.
  humans_are
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  mod check
  [ "$status" -eq 1 ]     # check : 1 = DRIFT
  [[ "$output" == *"aucun humain de fleet sur cette machine"* ]]
  [[ "$output" == *"GUARD B"* ]]
}

@test "check SANS systemd et SANS humain : le doctor d'une boite DERIVE, il ne rend pas OK" {
  # ⚠ LE PENDANT MANQUAIT, ET C'EST LE CAS QUI COMPTE EN PRODUCTION. Le temoin voisin mesure la
  # branche saine ; sans celui-ci, une regression de `probe_fleet_humans` qui cesserait de deriver
  # passerait inapercue — et `provision doctor --substrate docker` redirait « tout va bien » sur une
  # boite ou GUARD B refuse tout `fleet_v2 start`. C'est exactement l'etat d'avant ce lot.
  humans_are
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
  mod check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qE '^DRIFT .*aucun humain de fleet sur cette machine'
}

@test "check SANS systemd et AVEC un humain : la sonde le nomme et ne derive pas" {
  # ⚠ LE PENDANT, ET SANS LUI LA SONDE POURRAIT DERIVER TOUJOURS. Elle sort avant la branche
  # systemd : si elle rougissait sur une machine saine, tout doctor de boite deviendrait rouge.
  humans_are 'lcars:x:1001:1001::/home/lcars:/bin/bash'
  export LCARS_SYSTEMCTL="$BATS_TEST_TMPDIR/bin/pas-de-systemctl"
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
