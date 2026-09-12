#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/46-tofu.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de 46-tofu — le binaire épinglé, le miroir hors-ligne refait sur le verdict d'un init, la copie jetable
#
# tofu est une doublure : `version` répond la version demandée, `init` réussit dès qu'un miroir a été
# posé, `providers mirror` pose le miroir. Rien ne part sur le réseau ; curl et dpkg sont doublés.

load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  MOD="$BATS_TEST_DIRNAME/../../modules.d/46-tofu.sh"; [ -f "$MOD" ]
  RECETTE="$BATS_TEST_DIRNAME/../../../runtime/services/forge-recipe"; [ -d "$RECETTE/instance" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=46-tofu PROV_SUBSTRATE=linux
  export PROV_HUMAN; PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP; PROV_FLEET_GROUP="$(id -gn)"
  export LCARS_TOFU_BIN="$BATS_TEST_TMPDIR/usr/tofu"
  export LCARS_TOFU_DIR="$BATS_TEST_TMPDIR/opt/tofu"
  export LCARS_TOFU_OWNER; LCARS_TOFU_OWNER="$(id -un):$(id -gn)"
  export LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/channel"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export STUB_STATE="$BATS_TEST_TMPDIR/state"; mkdir -p "$STUB_STATE"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/usr/bin/env bash\necho "${STUB_ARCH:-amd64}"\n' > "$BIN/dpkg"
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "CURL $*" >> "$CALLS"
while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && { printf 'pas un zip' > "$2"; exit 0; }; shift; done
exit 1
EOF
  chmod 0755 "$BIN"/*
  export PATH="$BIN:$PATH"
}

tofu_double() { # tofu_double [version] — la doublure au chemin de l'ancre
  mkdir -p "$(dirname "$LCARS_TOFU_BIN")"
  cat > "$LCARS_TOFU_BIN" <<EOF
#!/usr/bin/env bash
echo "\$PWD \$*" >> "\$CALLS"
case "\${1:-}" in
  version) echo "OpenTofu v${1:-1.12.3}" ;;
  init) [[ -e "\$STUB_STATE/mirrored" && -z "\${STUB_INIT_KO:-}" ]] ;;
  providers) [[ -z "\${STUB_MIRROR_KO:-}" ]] || { echo "mirror: registre injoignable" >&2; exit 1; }
             mkdir -p "\${@: -1}/registry.opentofu.org/x" && touch "\$STUB_STATE/mirrored" ;;
esac
EOF
  chmod 0755 "$LCARS_TOFU_BIN"
}
mod() { run bash "$MOD" "$@"; }
copies_restantes() { find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'lcars-tofu-recipe.*'; }

@test "check : tofu et miroir absents — deux drifts qui disent la conséquence" {
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 46-tofu: $LCARS_TOFU_BIN absent — la structure de la forge se pose avec tofu"* ]]
  [[ "$output" == *"DRIFT 46-tofu: miroir de providers absent ($LCARS_TOFU_DIR) — tofu irait les chercher sur le réseau"* ]]
}

@test "check : une autre version est un drift contre l'épingle" {
  tofu_double 1.6.0
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"tofu 1.6.0 ≠ version épinglée 1.12.3 ($LCARS_TOFU_BIN)"* ]]
}

@test "check : la version épinglée est posée" {
  tofu_double
  mod check
  [[ "$output" == *"OK    46-tofu: tofu 1.12.3 posé ($LCARS_TOFU_BIN)"* ]]
  [[ "$output" != *"version épinglée"* ]]
}

@test "check : l'ancre, tofu/ et tofu/providers se relisent contre la table — 0700 est un drift nommé, 0755 est conforme" {
  local me; me="$(id -un):$(id -gn)"
  tofu_double; chmod 0700 "$LCARS_TOFU_BIN"
  mkdir -p "$LCARS_TOFU_DIR/providers"; printf 'x\n' > "$LCARS_TOFU_DIR/tofurc"
  chmod 0755 "$LCARS_TOFU_DIR"; chmod 0700 "$LCARS_TOFU_DIR/providers"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"$LCARS_TOFU_BIN : 700 $me ≠ 755 $me (deploy/system.manifest)"* ]]
  [[ "$output" == *"$LCARS_TOFU_DIR/providers : 700 $me ≠ 755 $me"* ]]
  [[ "$output" == *"$LCARS_TOFU_DIR 755 $me (table)"* ]]
  chmod 0755 "$LCARS_TOFU_BIN" "$LCARS_TOFU_DIR/providers"
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "apply : au premier passage l'init hors-ligne échoue, le miroir est posé pour les deux modules de la recette et l'init rejoué ; au second, rien ne se refait" {
  tofu_double
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c ' providers mirror -platform=linux_amd64 ' "$CALLS")" -eq 2 ]
  [ "$(grep -c ' init -input=false' "$CALLS")" -eq 4 ]
  grep -q "^ *path *= \"$LCARS_TOFU_DIR/providers\"" "$LCARS_TOFU_DIR/tofurc"
  [ -d "$LCARS_TOFU_DIR/providers/registry.opentofu.org" ]
  [[ "$output" == *"POSÉ  46-tofu: miroir de providers hors-ligne ($LCARS_TOFU_DIR/providers)"* ]]
  : > "$CALLS"
  mod apply
  [ "$status" -eq 0 ]
  refute grep -q 'providers mirror' "$CALLS"
  [[ "$output" == *"OK    46-tofu: miroir de providers complet (init hors-ligne OK)"* ]]
  [[ "$output" != *"POSÉ"* ]]
}

@test "apply : la recette se joue sur une copie jetable, jamais dans l'arbre du produit, et la copie est effacée" {
  tofu_double
  mod apply
  [ "$status" -eq 0 ]
  local cwd
  while read -r cwd _; do
    [[ "$cwd" == "$TMPDIR/lcars-tofu-recipe."* ]] || { echo "tofu joué dans $cwd"; return 1; }
  done < <(grep -E ' (init|providers) ' "$CALLS")
  [ -z "$(copies_restantes)" ]
  [ ! -e "$RECETTE/.terraform" ]
  [ ! -e "$RECETTE/instance/.terraform" ]
}

@test "apply : un miroir en échec est un échec nommé, la copie part" {
  tofu_double
  STUB_MIRROR_KO=1 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  46-tofu: miroir de providers : échec sur $TMPDIR/lcars-tofu-recipe."* ]]
  [ -z "$(copies_restantes)" ]
}

@test "apply : un init encore en échec après miroir est un échec nommé, la copie part" {
  tofu_double
  STUB_INIT_KO=1 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"init hors-ligne en échec dans $TMPDIR/lcars-tofu-recipe."*"après miroir — le miroir ne couvre pas la recette"* ]]
  [ -z "$(copies_restantes)" ]
}

@test "apply : recette absente — échec nommé avec son verdict, tofu n'est pas lancé" {
  tofu_double
  LCARS_FORGE_RECIPE="$BATS_TEST_TMPDIR/nulle-part" mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  46-tofu: recette absente : $BATS_TEST_TMPDIR/nulle-part"* ]]
  [[ "$output" != *"MORT"* ]]
  refute grep -qE ' (init|providers) ' "$CALLS"
}

@test "apply : les modes de l'ancre et du miroir convergent à ceux de la table" {
  tofu_double; chmod 0700 "$LCARS_TOFU_BIN"
  mkdir -p "$LCARS_TOFU_DIR/providers"; chmod 0700 "$LCARS_TOFU_DIR" "$LCARS_TOFU_DIR/providers"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(stat -c %a "$LCARS_TOFU_BIN")" = 755 ]
  [ "$(stat -c %a "$LCARS_TOFU_DIR")" = 755 ]
  [ "$(stat -c %a "$LCARS_TOFU_DIR/providers")" = 755 ]
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "apply : une architecture non épinglée est refusée en se nommant, tofu absent — rien n'est téléchargé" {
  STUB_ARCH=riscv64 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  46-tofu: arch non épinglée pour tofu : « riscv64 » (attendu amd64 ou arm64)"* ]]
  refute grep -q CURL "$CALLS"
}

@test "apply : une architecture non épinglée est refusée même avec tofu déjà à la version épinglée — aucun miroir n'est bâti" {
  tofu_double
  STUB_ARCH=riscv64 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"arch non épinglée pour tofu : « riscv64 »"* ]]
  refute grep -q 'providers mirror' "$CALLS"
}

@test "apply : un téléchargement dont le sha256 ne correspond pas n'est pas posé" {
  mod apply
  [ "$status" -eq 1 ]
  grep -q 'CURL .*tofu_1.12.3_linux_amd64.zip' "$CALLS"
  [ ! -e "$LCARS_TOFU_BIN" ]
  [[ "$output" == *"FAIL"* ]]
}
