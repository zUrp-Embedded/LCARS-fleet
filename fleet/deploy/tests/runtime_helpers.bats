#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/runtime_helpers.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: bats tests for 62-runtime-helpers — ce que le `COPY` du Dockerfile pose, et que le rail poste ne posait pas
#
# ⚖ USER 2026-08-21 : « l'installeur doit livrer un système qui fonctionne. »
#
# CE QUE CES TEMOINS FERMENT. La console web, la landing, le convergeur d'humains et le convergeur
# de toolchain n'etaient poses QUE par le Dockerfile. Sur une machine native ils n'existaient nulle
# part — et le provisionnement rendait VERT, parce qu'aucun module ne peut constater ce qu'aucun
# module ne pose.
#
# ⚠ AUCUN TEMOIN ICI NE VA SUR LE RESEAU. Le client de terminal se recupere par `fetch_verify`
# (pin sha256) : ce qui se mesure ici est la TABLE, l'egalite des pins avec le Dockerfile, et le
# REFUS d'un contenu non conforme — pas la capacite de jsdelivr a repondre.

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  MOD="$BATS_TEST_DIRNAME/../modules.d/62-runtime-helpers.sh"
  DOCKERFILE="$BATS_TEST_DIRNAME/../docker/Dockerfile"
  SRC_DIR="$BATS_TEST_DIRNAME/../docker"
  [ -f "$MOD" ] && [ -f "$DOCKERFILE" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export PROVISION_MODULE=62-runtime-helpers
  export LCARS_HELPERS_DIR="$BATS_TEST_TMPDIR/opt/lcars"
  export LCARS_TOOLCHAIN_CONVERGE_BIN="$BATS_TEST_TMPDIR/usr/local/bin/lcars-toolchain-converge"
  export LCARS_HELPERS_OWNER="$(id -un):$(id -gn)"
  export PROV_SUBSTRATE=linux
  export PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP="$(id -gn)"
  export PROV_ADMIN_GROUP="$(id -gn)"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  # ttyd : une doublure sur le PATH. Sans elle le module irait vers `apt`, qui exige root — et ce
  # n'est pas apt qu'on mesure, c'est la branche « il est deja la ».
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  printf '#!/usr/bin/env bash\necho "ttyd version 1.7.7-stub"\n' > "$BINDIR/ttyd"
  chmod 0755 "$BINDIR/ttyd"
  export PATH="$BINDIR:$PATH"
}

mod() { run bash "$MOD" "$1"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS + les trois en-tetes de module" {
  run head -9 "$MOD"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
  [[ "$output" == *"APPLY-ON: wsl linux"* ]]
  [[ "$output" == *"CHECK-ON: any"* ]]
  [[ "$output" == *"NEEDS: root"* ]]
}

@test "sur une machine nue, le check DERIVE et nomme chaque manque" {
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"console.sh absent"* ]]
  [[ "$output" == *"human-converger.sh absent"* ]]
  [[ "$output" == *"client de terminal absent"* ]]
  [[ "$output" == *"lcars-toolchain-converge absent"* ]]
  [[ "$output" == *"provisionnement embarqué absent"* ]]
}

@test "le manque de ttyd se DIT avec sa consequence — une socket sans serveur derriere" {
  rm -f "$BINDIR/ttyd"
  mod check
  [[ "$output" == *"ttyd absent"* ]]
  [[ "$output" == *"page noire"* ]]
}

# ─── LA POSE ────────────────────────────────────────────────────────────────────────────────────
#
# `fetch_verify` est neutralise par une doublure de `curl` : le sujet ici est ce qui se pose depuis
# l'ARBRE (les auxiliaires, le binaire de toolchain, le provisionnement embarque), pas le reseau.

stub_curl() { # <contenu rendu par curl>
  cat > "$BINDIR/curl" <<EOF
#!/usr/bin/env bash
# -o <dest> est le seul argument qui nous interesse
dest=""
while [[ \$# -gt 0 ]]; do case "\$1" in -o) dest="\$2"; shift 2 ;; *) shift ;; esac; done
printf '%s' '$1' > "\$dest"
EOF
  chmod 0755 "$BINDIR/curl"
}

@test "apply POSE les sept auxiliaires, identiques a leur source" {
  stub_curl "peu importe"
  mod apply

  local n
  for n in console.sh console-humans.sh console-status.sh console-landing.sh console-deck.py console-pod.sh human-converger.sh; do
    [ -x "$LCARS_HELPERS_DIR/$n" ]
    cmp -s "$SRC_DIR/$n" "$LCARS_HELPERS_DIR/$n"
  done
}

@test "apply POSE le convergeur de toolchain au chemin que le sudoers etroit designe" {
  # `45-sudoers-toolchain` accorde `%fleet ALL=(root) NOPASSWD: /usr/local/bin/lcars-toolchain-converge`.
  # Sur le rail poste ce binaire n'etait pose par RIEN : la regle designait une absence.
  stub_curl "peu importe"
  mod apply
  [ -x "$LCARS_TOOLCHAIN_CONVERGE_BIN" ]
  cmp -s "$SRC_DIR/toolchain-converger.sh" "$LCARS_TOOLCHAIN_CONVERGE_BIN"
}

@test "apply POSE le provisionnement EN FORME DE REPO — repo_root() doit s'y retrouver" {
  # Le convergeur appelle `/opt/lcars/fleet/deploy/provision`, et `repo_root()` de la lib remonte
  # trois crans depuis `fleet/deploy/lib/` : la forme de l'arbre EST le contrat.
  stub_curl "peu importe"
  mod apply
  [ -x "$LCARS_HELPERS_DIR/fleet/deploy/provision" ]
  [ -d "$LCARS_HELPERS_DIR/fleet/deploy/modules.d" ]
  [ -d "$LCARS_HELPERS_DIR/fleet/etc" ]
}

@test "un client de terminal NON CONFORME a son pin est REFUSE — rien n'est pose" {
  stub_curl "ceci nest pas xterm.js"
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256 MISMATCH"* ]]
  [ ! -e "$LCARS_HELPERS_DIR/deck-static/xterm.js" ]
}

@test "rejoue : un auxiliaire deja identique n'est pas re-pose" {
  stub_curl "peu importe"
  mod apply
  local before; before="$(stat -c %Y "$LCARS_HELPERS_DIR/console.sh")"
  mod apply
  [ "$(stat -c %Y "$LCARS_HELPERS_DIR/console.sh")" = "$before" ]
}

# ─── LES DEUX RAILS DISENT LA MEME VERSION ──────────────────────────────────────────────────────

@test "les pins du client de terminal sont IDENTIQUES a ceux du Dockerfile" {
  # Deux rails, deux mecanismes, UNE version. Un bump joue d'un seul cote donnerait deux consoles
  # qui ne se comportent pas pareil, et c'est le genre d'ecart qu'on ne voit qu'a l'usage.
  local k
  for k in XTERM_JS_SHA256 XTERM_CSS_SHA256 XTERM_FIT_SHA256; do
    local from_mod from_docker
    from_mod="$(grep -oE "^${k}=[0-9a-f]+" "$MOD" | cut -d= -f2)"
    from_docker="$(grep -oE "ARG ${k}=[0-9a-f]+" "$DOCKERFILE" | cut -d= -f2)"
    [ -n "$from_mod" ]
    [ -n "$from_docker" ]
    [ "$from_mod" = "$from_docker" ]
  done
}

@test "la liste des auxiliaires est le MIROIR du COPY de l'image — sans entrypoint.sh" {
  # Chaque nom pose ici doit avoir son `COPY … /opt/lcars/<nom>` dans le Dockerfile, et
  # reciproquement — sauf `entrypoint.sh`, qui n'a pas de sens hors conteneur.
  local n
  for n in console.sh console-humans.sh console-status.sh console-landing.sh console-deck.py console-pod.sh human-converger.sh; do
    grep -q "COPY fleet/deploy/docker/$n */opt/lcars/$n" "$DOCKERFILE"
  done
  ! grep -qE '^\s+entrypoint\.sh$' "$MOD"
}
