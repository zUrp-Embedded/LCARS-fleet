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
  export PROV_SUBSTRATE=linux
  export PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP="$(id -gn)"
  export PROV_ADMIN_GROUP="$(id -gn)"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  mkdir -p "$LCARS_SYSTEMD_DIR" "$PROV_TOKENS_DIR"
  echo "http://127.0.0.1:3000" > "$PROV_TOKENS_DIR/forge.url"

  # `systemctl` : une doublure qui JOURNALISE ce qu'on lui demande, et dont on pilote le verdict de
  # `is-active`. Une doublure qui se contenterait d'exit 0 laisserait passer une regression sur
  # l'ordre des gestes — et l'ordre est le sujet (daemon-reload AVANT enable).
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/systemctl.calls"
  ACTIVE="$BATS_TEST_TMPDIR/active"; echo 1 > "$ACTIVE"   # 1 = is-active repond NON
  cat > "$BINDIR/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$CALLS"
[[ "\$1" == "is-active" ]] && exit "\$(cat "$ACTIVE")"
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
  [[ "$output" == *"APPLY-ON: linux"* ]]
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
