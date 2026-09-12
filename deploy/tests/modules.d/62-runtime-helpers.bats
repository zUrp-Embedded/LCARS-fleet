#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/62-runtime-helpers.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de 62-runtime-helpers — les auxiliaires, les binaires du PATH, les arbres embarqués et leurs exclusions, le tampon de révision, les réglages de shell, les modes relus
#
# Le module se joue entier ; tout ce qu'il pose va sous des chemins de décor (LCARS_*), curl et ttyd
# sont des doublures. Les cas qui lisent la révision du dépôt sautent sur un arbre sans git.

load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  MOD="$BATS_TEST_DIRNAME/../../modules.d/62-runtime-helpers.sh"; [ -f "$MOD" ]
  SRC_DIR="$BATS_TEST_DIRNAME/../../../runtime/services"
  BIN_SRC_DIR="$BATS_TEST_DIRNAME/../../../runtime/bin"
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=62-runtime-helpers PROV_SUBSTRATE=linux
  export PROV_HUMAN; PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP; PROV_FLEET_GROUP="$(id -gn)"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  export LCARS_HELPERS_DIR="$BATS_TEST_TMPDIR/opt/lcars"
  export LCARS_HELPERS_OWNER; LCARS_HELPERS_OWNER="$(id -un):$(id -gn)"
  export LCARS_TOOLCHAIN_CONVERGE_BIN="$BATS_TEST_TMPDIR/usr/local/bin/lcars-toolchain-converge"
  export LCARS_AUTHORITY_ASK_BIN="$BATS_TEST_TMPDIR/usr/local/bin/lcars-authority-ask"
  export LCARS_SKEL_FILE="$BATS_TEST_TMPDIR/etc/skel/.bashrc"
  export LCARS_BASH_BASHRC="$BATS_TEST_TMPDIR/etc/bash.bashrc"
  export LCARS_BASHRC_FILE="$BATS_TEST_TMPDIR/etc/lcars/lcars.bashrc"
  export LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/etc/lcars/channel"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"; export PATH="$BINDIR:$PATH"
  printf '#!/usr/bin/env bash\necho "ttyd version 1.7.7-stub"\n' > "$BINDIR/ttyd"; chmod 0755 "$BINDIR/ttyd"
  export LCARS_TTYD_BIN="$BINDIR/ttyd"
  stub_curl "peu importe"
}

mod() { run bash "$MOD" "$1"; }
stub_curl() { # stub_curl <contenu rendu par curl dans -o>
  cat > "$BINDIR/curl" <<EOF
#!/usr/bin/env bash
dest=""
while [[ \$# -gt 0 ]]; do case "\$1" in -o) dest="\$2"; shift 2 ;; *) shift ;; esac; done
printf '%s' '$1' > "\$dest"
EOF
  chmod 0755 "$BINDIR/curl"
}
helpers() { sed -n '/^HELPERS=(/,/^)/p' "$MOD" | sed '1d;$d;s/#.*//' | tr -d ' \t' | grep -v '^$'; }
need_git_checkout() {
  git -C "$BATS_TEST_DIRNAME" rev-parse --git-dir >/dev/null 2>&1 \
    || skip "pas de checkout git (arbre livré par tarball) — ce témoin lit la révision du dépôt"
}
racine_paquet() { # racine_paquet → une racine de source qui se déclare paquet ; lib et modules copiés, le reste lié
  local src="$BATS_TEST_TMPDIR/paquet"
  mkdir -p "$src/deploy" "$src/runtime"
  cp -a "$BATS_TEST_DIRNAME/../../lib"       "$src/deploy/lib"
  cp -a "$BATS_TEST_DIRNAME/../../modules.d" "$src/deploy/modules.d"
  ln -s "$BATS_TEST_DIRNAME/../../../runtime/etc"      "$src/runtime/etc"
  ln -s "$BATS_TEST_DIRNAME/../../../runtime/services" "$src/runtime/services"
  ln -s "$BATS_TEST_DIRNAME/../../../runtime/bin"      "$src/runtime/bin"
  ln -s "$BATS_TEST_DIRNAME/../../../runtime/vendor"   "$src/runtime/vendor"
  ln -s "$BATS_TEST_DIRNAME/../../../assets"     "$src/assets"
  ln -s "$BATS_TEST_DIRNAME/../../../catalogues" "$src/catalogues"
  echo "cafe1234" > "$src/.source-revision"
  printf '%s\n' "$src"
}
racine_avec_artefacts() { # racine_avec_artefacts → la racine paquet avec services copié (on y écrit) et les artefacts locaux d'une recette jouée
  local src; src="$(racine_paquet)"
  rm -f "$src/runtime/services"
  cp -a "$BATS_TEST_DIRNAME/../../../runtime/services" "$src/runtime/services"
  [ ! -L "$src/runtime/services" ]
  mkdir -p "$src/runtime/services/forge-recipe/.terraform/providers"
  head -c 4096 /dev/zero > "$src/runtime/services/forge-recipe/.terraform/providers/gros.bin"
  printf '{"outputs":{"admin_token":{"value":"JETON-DE-FORGE"}}}\n' > "$src/runtime/services/forge-recipe/terraform.tfstate"
  printf 'admin_token = "JETON-DE-FORGE"\n' > "$src/runtime/services/forge-recipe/secrets.tfvars"
  printf 'resource "gitea_org" "x" {}\n' > "$src/runtime/services/forge-recipe/charte.tf"
  printf '%s\n' "$src"
}
mod_depuis() { run env PROVISION_LIB="$1/deploy/lib/provision-lib.sh" bash "$1/deploy/modules.d/62-runtime-helpers.sh" "$2"; }

@test "check sur une machine nue : chaque manque est un drift nommé" {
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"console.sh absent"*"human-converger.sh absent"* ]]
  [[ "$output" == *"client de terminal absent"* ]]
  [[ "$output" == *"lcars-toolchain-converge absent"* ]]
  [[ "$output" == *"provisionnement embarqué absent"* ]]
  [[ "$output" == *"arbre embarqué absent ($LCARS_HELPERS_DIR/assets)"*"arbre embarqué absent ($LCARS_HELPERS_DIR/catalogues)"* ]]
  [[ "$output" == *"$LCARS_BASH_BASHRC sans le bloc PATH"* ]]
  [[ "$output" == *"$LCARS_SKEL_FILE sans le raccord"* ]]
}

@test "check : ttyd absent se dit avec sa conséquence" {
  rm -f "$BINDIR/ttyd"
  mod check
  [[ "$output" == *"ttyd absent — la console web n'a aucun serveur derrière sa socket (page noire)"* ]]
}

@test "la liste des auxiliaires du module n'est pas vide" {
  [ "$(helpers | wc -l)" -ge 8 ]
  helpers | grep -qx 'console-deck.py'
}

@test "apply pose les auxiliaires identiques à leur source, exécutables" {
  mod apply
  local n
  while read -r n; do
    [ -x "$LCARS_HELPERS_DIR/$n" ]
    cmp -s "$SRC_DIR/$n" "$LCARS_HELPERS_DIR/$n"
  done < <(helpers)
}

@test "apply pose le convergeur de toolchain et le client d'autorité à leur chemin, identiques à leur source" {
  mod apply
  [ -x "$LCARS_TOOLCHAIN_CONVERGE_BIN" ]
  cmp -s "$BIN_SRC_DIR/lcars-toolchain-converge" "$LCARS_TOOLCHAIN_CONVERGE_BIN"
  [ -x "$LCARS_AUTHORITY_ASK_BIN" ]
  cmp -s "$BIN_SRC_DIR/lcars-authority-ask" "$LCARS_AUTHORITY_ASK_BIN"
}

@test "check dit l'absence du client d'autorité" {
  mod check
  [[ "$output" == *"$LCARS_AUTHORITY_ASK_BIN absent — « lcars publish run », « lcars approve » et le skill system-issues"* ]]
}

@test "apply pose le provisionnement en forme de dépôt, sans ses témoins, et les arbres etc, bin et vendor" {
  mod apply
  [ -x "$LCARS_HELPERS_DIR/deploy/provision" ]
  [ -d "$LCARS_HELPERS_DIR/deploy/modules.d" ]
  [ ! -d "$LCARS_HELPERS_DIR/deploy/tests" ]
  [ -d "$LCARS_HELPERS_DIR/etc" ]
  [ -d "$LCARS_HELPERS_DIR/bin" ]
  [ -f "$LCARS_HELPERS_DIR/vendor/token_saver/lcars_hook.py" ]
  [ -d "$LCARS_HELPERS_DIR/assets/avatars" ]
  [ -d "$LCARS_HELPERS_DIR/catalogues" ]
  mod check
  [[ "$output" == *"arbre embarqué $LCARS_HELPERS_DIR/assets"*"arbre embarqué $LCARS_HELPERS_DIR/catalogues"*"arbre embarqué $LCARS_HELPERS_DIR/deploy"* ]]
}

@test "un client de terminal non conforme à son pin n'est pas posé, l'apply échoue" {
  stub_curl "ceci n'est pas xterm.js"
  mod apply
  [ "$status" -eq 1 ]
  [ ! -e "$LCARS_HELPERS_DIR/deck-static/xterm.js" ]
}

@test "rejoué : un auxiliaire déjà identique n'est pas reposé" {
  mod apply
  local before; before="$(stat -c %Y "$LCARS_HELPERS_DIR/console.sh")"
  mod apply
  [ "$(stat -c %Y "$LCARS_HELPERS_DIR/console.sh")" = "$before" ]
}

@test "les données sont posées à leur destination en 0644, identiques à la source, non exécutables" {
  mod apply
  cmp -s "$SRC_DIR/console.tmux.conf" "$LCARS_HELPERS_DIR/console.tmux.conf"
  [ "$(stat -c %a "$LCARS_HELPERS_DIR/console.tmux.conf")" = 644 ]
  cmp -s "$SRC_DIR/lcars.bashrc" "$LCARS_BASHRC_FILE"
  [ "$(stat -c %a "$LCARS_BASHRC_FILE")" = 644 ]
}

@test "le tampon de révision est posé là où repo_root() de la copie le retrouve, et il n'est pas le discriminant de livraison" {
  need_git_checkout
  mod apply
  local lu
  lu="$(PROVISION_LIB="$LCARS_HELPERS_DIR/deploy/lib/provision-lib.sh" bash -c '. "$PROVISION_LIB" >/dev/null 2>&1; repo_root')"
  [ -s "$lu/.helpers-revision" ]
  [ "$(cat "$LCARS_HELPERS_DIR/.helpers-revision")" = "$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD)$(cd "$BATS_TEST_DIRNAME" && git diff --quiet HEAD -- || echo '+local')" ]
  [ ! -e "$LCARS_HELPERS_DIR/.source-revision" ]
}

@test "la copie d'une livraison binaire porte le discriminant, séparé du tampon" {
  local src; src="$(racine_paquet)"
  mod_depuis "$src" apply
  [ "$(cat "$LCARS_HELPERS_DIR/.source-revision")" = cafe1234 ]
  [ -s "$LCARS_HELPERS_DIR/.helpers-revision" ]
}

@test "la racine du décor est vue comme un paquet, pas comme le dépôt" {
  local src; src="$(racine_paquet)"
  run env PROVISION_LIB="$src/deploy/lib/provision-lib.sh" bash -c '. "$PROVISION_LIB"; printf "%s %s\n" "$(repo_root)" "$(prov_delivery)"'
  [ "$output" = "$src binary" ]
}

@test "embarqué : la recette arrive, mais ni le cache de providers, ni l'état tofu, ni ses variables — aucun jeton sous le prefix" {
  local src; src="$(racine_avec_artefacts)"
  mod_depuis "$src" apply
  local pose="$LCARS_HELPERS_DIR/services/forge-recipe"
  [ -s "$pose/charte.tf" ]
  [ ! -e "$pose/.terraform" ]
  [ ! -e "$pose/terraform.tfstate" ]
  [ ! -e "$pose/secrets.tfvars" ]
  refute grep -rq 'JETON-DE-FORGE' "$LCARS_HELPERS_DIR"
}

@test "check : une source absente n'est pas une divergence — rien n'est conclu, et c'est dit sans drift" {
  local src; src="$(racine_avec_artefacts)"
  mod_depuis "$src" apply
  rm -f "$src/runtime/services/console.sh"
  mod_depuis "$src" check
  [[ "$output" == *"WARN  62-runtime-helpers: $LCARS_HELPERS_DIR/console.sh : rien n'est conclu — la source est absente ou illisible ici"* ]]
  [[ "$output" != *"console.sh diverge"* ]]
}

@test "embarqué : node_modules de la racine n'est pas recopié, dist l'est" {
  local src; src="$(racine_paquet)"
  rm -f "$src/assets"; mkdir -p "$src/assets/github.io/node_modules/x" "$src/assets/github.io/dist"
  printf 'x' > "$src/assets/github.io/node_modules/x/index.js"; printf '<html>' > "$src/assets/github.io/dist/index.html"
  mod_depuis "$src" apply
  [ -f "$LCARS_HELPERS_DIR/assets/github.io/dist/index.html" ]
  [ ! -e "$LCARS_HELPERS_DIR/assets/github.io/node_modules" ]
}

@test "migration : un discriminant périmé est retiré en livraison source" {
  need_git_checkout
  mkdir -p "$LCARS_HELPERS_DIR"; echo vieux1234 > "$LCARS_HELPERS_DIR/.source-revision"
  mod apply
  [ ! -e "$LCARS_HELPERS_DIR/.source-revision" ]
}

@test "check sans tampon dit qu'il ne sait pas d'où sortent les auxiliaires" {
  mod check
  [[ "$output" == *"impossible de dire de quelle révision"* ]]
}

@test "une source en retard sur ce qui est posé est un échec au check, et l'apply l'annonce avant d'écrire" {
  need_git_checkout
  mod apply
  local head prev
  head="$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD)"
  prev="$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD~1)"
  echo "$head" > "$LCARS_HELPERS_DIR/.helpers-revision"
  PROV_SOURCE_REV="$prev" mod check
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL  62-runtime-helpers: la source est en retard : posé depuis $head, cet arbre est $prev, qui en est un ancêtre"* ]]
  rm -f "$LCARS_HELPERS_DIR/console.sh"
  PROV_SOURCE_REV="$prev" mod apply
  [[ "$output" == *"WARN  62-runtime-helpers: retour en arrière : $LCARS_HELPERS_DIR sort de $head, cet arbre est $prev"* ]]
  [ -x "$LCARS_HELPERS_DIR/console.sh" ]
}

@test "une parenté indéterminable se dit, ni à jour ni en retard" {
  mod apply
  echo deadbeef > "$LCARS_HELPERS_DIR/.helpers-revision"
  mod check
  [[ "$output" == *"parenté indéterminable"* ]]
}

@test "squelette : le .bashrc de la distribution est préservé, le raccord teste avant de sourcer et reste inerte sans l'installation" {
  mkdir -p "$(dirname "$LCARS_SKEL_FILE")"
  printf '# .bashrc de la distribution\nexport MARQUEUR_DISTRIBUTION=intact\nalias ll="ls -alF"\n' > "$LCARS_SKEL_FILE"
  local avant; avant="$(cat "$LCARS_SKEL_FILE")"
  mod apply
  [ "$(head -3 "$LCARS_SKEL_FILE")" = "$avant" ]
  grep -qF "if [ -r $LCARS_BASHRC_FILE ]; then . $LCARS_BASHRC_FILE; fi" "$LCARS_SKEL_FILE"
  rm -f "$LCARS_BASHRC_FILE"
  run bash -c "set -e; . '$LCARS_SKEL_FILE'; echo OK-INERTE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK-INERTE"* ]]
  mod apply
  [ "$(grep -c 'lcars:skel >>>' "$LCARS_SKEL_FILE")" -eq 1 ]
}

@test "bash.bashrc : le bloc PATH met ~/.local/bin devant pour un shell interactif, une fois, en préservant le fichier" {
  mkdir -p "$(dirname "$LCARS_BASH_BASHRC")"
  printf '# bash.bashrc de la distribution\nshopt -s checkwinsize\n' > "$LCARS_BASH_BASHRC"
  mod apply
  [ "$(head -2 "$LCARS_BASH_BASHRC")" = "$(printf '# bash.bashrc de la distribution\nshopt -s checkwinsize')" ]
  local home="$BATS_TEST_TMPDIR/home"; mkdir -p "$home/.local/bin"
  run env -i HOME="$home" PATH=/usr/bin:/bin bash -c ". '$LCARS_BASH_BASHRC'; . '$LCARS_BASH_BASHRC'; echo \"\$PATH\""
  [ "$output" = "$home/.local/bin:/usr/bin:/bin" ]
  run env -i HOME="$BATS_TEST_TMPDIR/sans" PATH=/usr/bin:/bin bash -c ". '$LCARS_BASH_BASHRC'; echo \"\$PATH\""
  [ "$output" = "/usr/bin:/bin" ]
  mod check
  [[ "$output" == *"PATH des shells interactifs : ~/.local/bin ($LCARS_BASH_BASHRC)"* ]]
  mod apply
  [ "$(grep -c 'lcars:path >>>' "$LCARS_BASH_BASHRC")" -eq 1 ]
}

@test "check : un bloc géré vidé de son corps est un drift, le marqueur seul ne suffit pas" {
  mod apply
  printf '# >>> lcars:path >>> (bloc géré par deploy — édition manuelle écrasée au prochain apply)\n# rien\n# <<< lcars:path <<<\n' > "$LCARS_BASH_BASHRC"
  printf '# >>> lcars:skel >>> (bloc géré par deploy — édition manuelle écrasée au prochain apply)\n# <<< lcars:skel <<<\n' > "$LCARS_SKEL_FILE"
  mod check
  [[ "$output" == *"DRIFT 62-runtime-helpers: $LCARS_BASH_BASHRC sans le bloc PATH attendu"* ]]
  [[ "$output" == *"DRIFT 62-runtime-helpers: $LCARS_SKEL_FILE sans le raccord attendu"* ]]
  mod apply
  mod check
  [[ "$output" == *"PATH des shells interactifs"*"squelette des humains raccordé"* ]]
}

@test "check : un arbre embarqué du runtime absent (vendor, bin, etc, services) est un drift" {
  mod apply
  rm -rf "${LCARS_HELPERS_DIR:?}/vendor" "${LCARS_HELPERS_DIR:?}/bin"
  mod check
  [[ "$output" == *"arbre embarqué absent ($LCARS_HELPERS_DIR/bin)"*"arbre embarqué absent ($LCARS_HELPERS_DIR/vendor)"* ]]
  [[ "$output" == *"arbre embarqué $LCARS_HELPERS_DIR/etc"*"arbre embarqué $LCARS_HELPERS_DIR/services"* ]]
}

@test "embarqué : aucun fichier ni répertoire posé n'est setgid ni inscriptible par le groupe ou les autres" {
  need_git_checkout
  mod apply
  [ -d "$LCARS_HELPERS_DIR/services" ]
  [ "$(find "$LCARS_HELPERS_DIR/services" "$LCARS_HELPERS_DIR/deploy" -perm /2022 2>/dev/null | wc -l)" -eq 0 ]
}

@test "modes : un auxiliaire g+w est un drift nommé, l'apply le ramène à 0755 sans le reposer" {
  mod apply
  local me; me="$(id -un):$(id -gn)"
  chmod 0775 "$LCARS_HELPERS_DIR/console.sh"
  mod check
  [[ "$output" == *"$LCARS_HELPERS_DIR/console.sh : 775 $me ≠ 755 $me"* ]]
  local before; before="$(stat -c %Y "$LCARS_HELPERS_DIR/console.sh")"
  mod apply
  [ "$(stat -c %a "$LCARS_HELPERS_DIR/console.sh")" = 755 ]
  [ "$(stat -c %Y "$LCARS_HELPERS_DIR/console.sh")" = "$before" ]
  mod check
  refute grep -qF "$LCARS_HELPERS_DIR/console.sh : " <<<"$output"
  [[ "$output" == *"modes et propriétaires relus"* ]]
}

@test "modes : une donnée en 0664 est un drift nommé, l'apply la ramène" {
  mod apply
  local me; me="$(id -un):$(id -gn)"
  chmod 0664 "$LCARS_HELPERS_DIR/console.tmux.conf"
  mod check
  [[ "$output" == *"$LCARS_HELPERS_DIR/console.tmux.conf : 664 $me ≠ 644 $me"* ]]
  mod apply
  [ "$(stat -c %a "$LCARS_HELPERS_DIR/console.tmux.conf")" = 644 ]
}

@test "modes : un arbre embarqué avec un objet g+w ou setgid est un drift compté, l'apply repose l'arbre ; ce que la copie n'emporte pas n'est pas jugé" {
  need_git_checkout
  mod apply
  chmod g+w "$LCARS_HELPERS_DIR/services/console.sh"
  mod check
  [[ "$output" == *"$LCARS_HELPERS_DIR/services : 1 objet(s) hors contrat (premier : $LCARS_HELPERS_DIR/services/console.sh, "* ]]
  mod apply
  mod check
  refute grep -qF "$LCARS_HELPERS_DIR/services : " <<<"$output"
  chmod g+s "$LCARS_HELPERS_DIR/services/human.d"; chmod o+w "$LCARS_HELPERS_DIR/services/console.sh"
  mod check
  [[ "$output" == *"$LCARS_HELPERS_DIR/services : 2 objet(s) hors contrat"* ]]
  mkdir -p "$LCARS_HELPERS_DIR/deploy/.terraform" "$LCARS_HELPERS_DIR/assets/node_modules"
  ln -s /nulle/part "$LCARS_HELPERS_DIR/deploy/.terraform/lien"; chmod 0777 "$LCARS_HELPERS_DIR/assets/node_modules"
  mod check
  refute grep -qF "$LCARS_HELPERS_DIR/deploy : " <<<"$output"
  refute grep -qF "$LCARS_HELPERS_DIR/assets : " <<<"$output"
}
