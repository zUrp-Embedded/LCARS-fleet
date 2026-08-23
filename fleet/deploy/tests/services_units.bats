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

@test "la landing demarre EN PREMIER PLAN — sinon systemd lit un service mort en une seconde" {
  mod apply
  grep -q -- "ExecStart=$LCARS_HELPERS_DIR/console-landing.sh --foreground" "$LCARS_SYSTEMD_DIR/lcars-landing.service"
  grep -q "^Restart=always$" "$LCARS_SYSTEMD_DIR/lcars-landing.service"
}

@test "AUCUNE unite ne pose User= — la landing se depose ELLE-MEME, avec son groupe de console" {
  # `User=nobody` retirerait au script le droit de faire son `setpriv`, et surtout le groupe
  # `lcars-console` : la page s'ouvrirait sur une liste vide en annoncant que tout va bien.
  mod apply
  ! grep -q "^User=" "$LCARS_SYSTEMD_DIR/lcars-landing.service"
  ! grep -q "^User=" "$LCARS_SYSTEMD_DIR/lcars-converger.service"
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
  ! grep -qE 'PROV_FORGE_ORG=\$\{PROV_FORGE_ORG:-' "$MOD"
  ! grep -qE 'PROV_HUMANS_TEAM=\$\{PROV_HUMANS_TEAM:-' "$MOD"
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
