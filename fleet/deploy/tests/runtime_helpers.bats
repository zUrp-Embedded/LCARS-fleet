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
  # ⚠ LE BINAIRE SE NOMME, IL NE SE CHERCHE PAS DANS LE PATH — sinon le temoin « ttyd absent »
  # mesure la MACHINE. Mesure du 2026-08-21, passe a froid : retirer la doublure du PATH ne prouve
  # rien apres que `10-packages` a pose /usr/bin/ttyd, donc vert sur un poste de dev et ROUGE dans
  # l'install. Un temoin ne peut pas desinstaller ttyd ; il peut viser un chemin qu'il possede.
  export LCARS_TTYD_BIN="$BINDIR/ttyd"
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
  for n in console.sh console-humans.sh console-status.sh console-landing.sh console-deck.py console-pod.sh human-converger.sh forge-gestures.sh; do
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
  for n in console.sh console-humans.sh console-status.sh console-landing.sh console-deck.py console-pod.sh human-converger.sh forge-gestures.sh; do
    grep -q "COPY fleet/deploy/docker/$n */opt/lcars/$n" "$DOCKERFILE"
  done
  ! grep -qE '^\s+entrypoint\.sh$' "$MOD"
}

# ─── LA REVISION VOYAGE AVEC LA COPIE ───────────────────────────────────────────────────────────
#
# ⚖ USER 2026-08-21, apres la panne : « le rail natif se met a jour depuis un clone git, et rien ne
# dit a quel commit ce clone est. Un provision apply sur un checkout en retard reinstalle
# silencieusement l'etat d'avant. Aucun verdict ne le voit. »
#
# CE QUE CA A COUTE, MESURE LE MEME JOUR : un correctif d'allocation d'uid pose et verifie sur une
# machine, puis un apply depuis un clone reste six commits en arriere qui REMET l'ancienne formule.
# Le service systemd tournait dessus. La collision d'uid suivante etait mecanique, et rien nulle
# part ne pouvait la relier a un arbre en retard — le module avait fait exactement son travail.

@test "apply TAMPONNE la revision, a la racine que repo_root() de la copie retrouve" {
  # `repo_root()` remonte trois crans depuis `<...>/fleet/deploy/lib` : pour la copie, la racine est
  # $HELPERS_DIR, pas $HELPERS_DIR/fleet. Un tampon un cran plus bas ne serait lu par personne.
  stub_curl "peu importe"
  mod apply
  # ⚠ ON EPINGLE LA RELATION, PAS LE CHEMIN. Le tampon doit se poser LA OU `repo_root()` de la copie
  # ira le chercher — trois crans au-dessus de `<copie>/fleet/deploy/lib`. Aujourd'hui ca tombe sur
  # `$LCARS_HELPERS_DIR`, mais par COINCIDENCE arithmetique : deplacer la copie d'un cran
  # (`libexec/fleet`) ferait diverger les deux, le tampon serait pose a cote, lu par personne — et un
  # temoin qui epingle le chemin litteral resterait VERT.
  local lu; lu="$(cd "$LCARS_HELPERS_DIR/fleet/deploy/lib" && readlink -f ../../..)"
  [ -s "$lu/.source-revision" ]
  [ -s "$LCARS_HELPERS_DIR/.source-revision" ]
  [ "$(cat "$LCARS_HELPERS_DIR/.source-revision")" = "$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD)$(cd "$BATS_TEST_DIRNAME" && git diff --quiet HEAD -- || echo '+local')" ]
}

@test "sans tampon, le check DIT qu'il ne sait pas — il ne suppose pas que c'est a jour" {
  mod check
  [[ "$output" == *"impossible de dire de quelle révision"* ]]
}

@test "une source EN RETARD sur ce qui est pose est un ECHEC, pas une note de bas de page" {
  # Le cas exact de la panne : le tampon porte un descendant, l'arbre est son ancetre.
  stub_curl "peu importe"
  mod apply
  # HEAD~1 est un ancetre de HEAD : on fait donc croire que la source est en retard d'un commit.
  local head; head="$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD)"
  local prev; prev="$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD~1)"
  echo "$head" > "$LCARS_HELPERS_DIR/.source-revision"

  PROV_SOURCE_REV="$prev" mod check
  [ "$status" -eq 2 ]
  [[ "$output" == *"LA SOURCE EST EN RETARD"* ]]
  [[ "$output" == *"ANCÊTRE"* ]]
}

@test "apply ANNONCE le retour en arriere AVANT de l'ecrire — apres, plus rien ne le dira" {
  stub_curl "peu importe"
  mod apply
  local head; head="$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD)"
  local prev; prev="$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD~1)"
  echo "$head" > "$LCARS_HELPERS_DIR/.source-revision"

  rm -f "$LCARS_HELPERS_DIR/console.sh"
  PROV_SOURCE_REV="$prev" mod apply
  [[ "$output" == *"RETOUR EN ARRIÈRE"* ]]
  # Il ne REFUSE pas : un retour en arriere delibere est un geste legitime, il ne peut simplement
  # plus etre silencieux. La preuve qu'il a continue, c'est que la pose a EU LIEU — le code de
  # sortie, lui, appartient au client de terminal, que la doublure de `curl` fait toujours echouer.
  [ -x "$LCARS_HELPERS_DIR/console.sh" ]
}

@test "une parente INDETERMINABLE se dit — elle ne se lit ni comme a jour ni comme en retard" {
  stub_curl "peu importe"
  mod apply
  echo "deadbeef" > "$LCARS_HELPERS_DIR/.source-revision"
  mod check
  [[ "$output" == *"parenté indéterminable"* ]]
}

