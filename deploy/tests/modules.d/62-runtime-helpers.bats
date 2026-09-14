#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/62-runtime-helpers.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de 62-runtime-helpers — les auxiliaires, les binaires du PATH, les arbres embarqués et leurs exclusions, le tampon de révision, les réglages de shell, les modes relus

load ../refute
load ../support/decor

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
  decor_pose
  HELPERS="$LCARS_DECOR_ROOT/opt/lcars"
  TOOLCHAIN_BIN="$LCARS_DECOR_ROOT/usr/local/bin/lcars-toolchain-converge"
  ASK_BIN="$LCARS_DECOR_ROOT/usr/local/bin/lcars-authority-ask"
  SKEL="$LCARS_DECOR_ROOT/etc/skel/.bashrc"
  # /etc/skel est dans toute image ; le décor le porte comme elle
  mkdir -p "$(dirname "$SKEL")"
  BASH_BASHRC="$LCARS_DECOR_ROOT/etc/bash.bashrc"
  BASHRC_LCARS="$LCARS_DECOR_ROOT/etc/lcars/lcars.bashrc"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"
  BINDIR="$DECOR_BIN"
  printf '#!/usr/bin/env bash\necho "ttyd version 1.7.7-stub"\n' > "$BINDIR/ttyd"; chmod 0755 "$BINDIR/ttyd"
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
helpers() { sed -n 's/^PROV_HELPERS=//p' "$BATS_TEST_DIRNAME/../../installer-constants.env" | tr ' ' '\n'; }
# le corpus se joue depuis un checkout (le kit ne l'emporte pas) : ces cas lisent la révision du dépôt
need_git_checkout() { git -C "$BATS_TEST_DIRNAME" rev-parse --git-dir >/dev/null 2>&1; }
racine_paquet() { # racine_paquet → une racine de source qui se déclare paquet ; lib et modules copiés, le reste lié
  local src="$BATS_TEST_TMPDIR/paquet"
  mkdir -p "$src/deploy" "$src/runtime"
  cp -a "$BATS_TEST_DIRNAME/../../lib"       "$src/deploy/lib"
  cp -a "$BATS_TEST_DIRNAME/../../modules.d" "$src/deploy/modules.d"
  cp "$BATS_TEST_DIRNAME/../../installer-constants.env" "$BATS_TEST_DIRNAME/../../system.manifest" "$src/deploy/"
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
  [[ "$output" == *"arbre embarqué absent ($HELPERS/assets)"*"arbre embarqué absent ($HELPERS/catalogues)"* ]]
  [[ "$output" == *"$BASH_BASHRC sans le bloc PATH"* ]]
  [[ "$output" == *"$SKEL sans le raccord"* ]]
}

@test "check : ttyd absent du PATH se dit avec sa conséquence" {
  local d sans=""
  rm -f "$BINDIR/ttyd"
  # le PATH du décor garde tout sauf les dossiers qui portent un ttyd
  while IFS= read -r d; do [[ -x "$d/ttyd" ]] || sans+="${sans:+:}$d"; done < <(tr ':' '\n' <<<"$PATH")
  PATH="$sans" mod check
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
    [ -x "$HELPERS/$n" ]
    cmp -s "$SRC_DIR/$n" "$HELPERS/$n"
  done < <(helpers)
}

@test "apply pose le convergeur de toolchain et le client d'autorité à leur chemin, identiques à leur source" {
  mod apply
  [ -x "$TOOLCHAIN_BIN" ]
  cmp -s "$BIN_SRC_DIR/lcars-toolchain-converge" "$TOOLCHAIN_BIN"
  [ -x "$ASK_BIN" ]
  cmp -s "$BIN_SRC_DIR/lcars-authority-ask" "$ASK_BIN"
}

@test "check dit l'absence du client d'autorité" {
  mod check
  [[ "$output" == *"$ASK_BIN absent — « lcars publish run », « lcars approve » et le skill system-issues"* ]]
}

@test "apply pose le provisionnement en forme de dépôt, sans ses témoins, et les arbres etc et bin ; vendor, sans lecteur, reste dans le dépôt" {
  mod apply
  [ -x "$HELPERS/deploy/provision" ]
  [ -d "$HELPERS/deploy/modules.d" ]
  [ ! -d "$HELPERS/deploy/tests" ]
  [ -d "$HELPERS/etc" ]
  [ -d "$HELPERS/bin" ]
  [ ! -e "$HELPERS/vendor" ]
  [ -d "$HELPERS/assets/avatars" ]
  [ -d "$HELPERS/catalogues" ]
  mod check
  [[ "$output" == *"arbre embarqué $HELPERS/assets"*"arbre embarqué $HELPERS/catalogues"*"arbre embarqué $HELPERS/deploy"* ]]
}

@test "un client de terminal non conforme à son pin n'est pas posé, l'apply échoue" {
  stub_curl "ceci n'est pas xterm.js"
  mod apply
  [ "$status" -eq 1 ]
  [ ! -e "$HELPERS/deck-static/xterm.js" ]
}

@test "rejoué : un auxiliaire déjà identique n'est pas reposé" {
  mod apply
  local before; before="$(stat -c %Y "$HELPERS/console.sh")"
  mod apply
  [ "$(stat -c %Y "$HELPERS/console.sh")" = "$before" ]
}

@test "rejoué sans rien de neuf : aucune ligne POSÉ, ni pour les arbres embarqués ni pour les binaires du PATH" {
  mod apply
  [[ "$output" == *"POSÉ  62-runtime-helpers: arbre embarqué $HELPERS/deploy"* ]]
  mod apply
  refute_out '^POSÉ' <<<"$output"
}

@test "un arbre dont la source a changé est seul rebasculé, et compté" {
  local src; src="$(racine_avec_artefacts)"
  mod_depuis "$src" apply
  printf '# retouche\n' >> "$src/runtime/services/console.tmux.conf"
  mod_depuis "$src" apply
  [[ "$output" == *"POSÉ  62-runtime-helpers: arbre embarqué $HELPERS/services"* ]]
  [ "$(grep -c '^POSÉ  62-runtime-helpers: arbre embarqué' <<<"$output")" -eq 1 ]
  cmp -s "$src/runtime/services/console.tmux.conf" "$HELPERS/services/console.tmux.conf"
}

@test "les données sont posées à leur destination en 0644, identiques à la source, non exécutables" {
  mod apply
  cmp -s "$SRC_DIR/console.tmux.conf" "$HELPERS/console.tmux.conf"
  [ "$(stat -c %a "$HELPERS/console.tmux.conf")" = 644 ]
  cmp -s "$SRC_DIR/lcars.bashrc" "$BASHRC_LCARS"
  [ "$(stat -c %a "$BASHRC_LCARS")" = 644 ]
}

@test "le tampon de révision est posé là où repo_root() de la copie le retrouve, et il n'est pas le discriminant de livraison" {
  need_git_checkout
  mod apply
  local lu
  lu="$(PROVISION_LIB="$HELPERS/deploy/lib/provision-lib.sh" bash -c '. "$PROVISION_LIB" >/dev/null 2>&1; repo_root')"
  [ -s "$lu/.helpers-revision" ]
  [ "$(cat "$HELPERS/.helpers-revision")" = "$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD)$(cd "$BATS_TEST_DIRNAME" && git diff --quiet HEAD -- || echo '+local')" ]
  [ ! -e "$HELPERS/.source-revision" ]
}

@test "la copie d'une livraison binaire porte le discriminant, séparé du tampon" {
  local src; src="$(racine_paquet)"
  mod_depuis "$src" apply
  [ "$(cat "$HELPERS/.source-revision")" = cafe1234 ]
  [ -s "$HELPERS/.helpers-revision" ]
}

@test "la racine du décor est vue comme un paquet, pas comme le dépôt" {
  local src; src="$(racine_paquet)"
  run env PROVISION_LIB="$src/deploy/lib/provision-lib.sh" bash -c '. "$PROVISION_LIB"; printf "%s %s\n" "$(repo_root)" "$(prov_delivery)"'
  [ "$output" = "$src binary" ]
}

@test "embarqué : la recette arrive, mais ni le cache de providers, ni l'état tofu, ni ses variables — aucun jeton sous le prefix" {
  local src; src="$(racine_avec_artefacts)"
  mod_depuis "$src" apply
  local pose="$HELPERS/services/forge-recipe"
  [ -s "$pose/charte.tf" ]
  [ ! -e "$pose/.terraform" ]
  [ ! -e "$pose/terraform.tfstate" ]
  [ ! -e "$pose/secrets.tfvars" ]
  refute grep -rq 'JETON-DE-FORGE' "$HELPERS"
}

@test "check : une source absente n'est pas une divergence — rien n'est conclu, et c'est dit sans drift" {
  local src; src="$(racine_avec_artefacts)"
  mod_depuis "$src" apply
  rm -f "$src/runtime/services/console.sh"
  mod_depuis "$src" check
  [[ "$output" == *"WARN  62-runtime-helpers: $HELPERS/console.sh : rien n'est conclu — la source est absente ou illisible ici"* ]]
  [[ "$output" != *"console.sh diverge"* ]]
}

@test "embarqué : node_modules de la racine n'est pas recopié, dist l'est" {
  local src; src="$(racine_paquet)"
  rm -f "$src/assets"; mkdir -p "$src/assets/github.io/node_modules/x" "$src/assets/github.io/dist"
  printf 'x' > "$src/assets/github.io/node_modules/x/index.js"; printf '<html>' > "$src/assets/github.io/dist/index.html"
  mod_depuis "$src" apply
  [ -f "$HELPERS/assets/github.io/dist/index.html" ]
  [ ! -e "$HELPERS/assets/github.io/node_modules" ]
}

@test "migration : un discriminant périmé est retiré en livraison source" {
  need_git_checkout
  mkdir -p "$HELPERS"; echo vieux1234 > "$HELPERS/.source-revision"
  mod apply
  [ ! -e "$HELPERS/.source-revision" ]
}

@test "check sans tampon dit qu'il ne sait pas d'où sortent les auxiliaires" {
  mod check
  [[ "$output" == *"impossible de dire de quelle révision"* ]]
}

@test "une source en retard sur ce qui est posé : le check dit le retour en arrière que l'apply fera, l'apply l'annonce et le fait" {
  need_git_checkout
  # un ancêtre réel du dépôt
  git -C "$BATS_TEST_DIRNAME" rev-parse --verify -q HEAD~1 >/dev/null
  mod apply
  local head prev
  head="$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD)"
  prev="$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD~1)"
  echo "$head" > "$HELPERS/.helpers-revision"
  PROV_SOURCE_REV="$prev" mod check
  # un FAIL au check serait un état que l'apply ne refuse pas
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 62-runtime-helpers: retour en arrière : posé depuis $head, cet arbre est $prev, qui en est un ancêtre"* ]]
  rm -f "$HELPERS/console.sh"
  PROV_SOURCE_REV="$prev" mod apply
  [[ "$output" == *"WARN  62-runtime-helpers: retour en arrière : $HELPERS sort de $head, cet arbre est $prev"* ]]
  [ -x "$HELPERS/console.sh" ]
}

@test "une parenté indéterminable se dit, ni à jour ni en retard" {
  mod apply
  echo deadbeef > "$HELPERS/.helpers-revision"
  mod check
  [[ "$output" == *"parenté indéterminable"* ]]
}

@test "squelette : le .bashrc de la distribution est préservé, le raccord teste avant de sourcer et reste inerte sans l'installation" {
  mkdir -p "$(dirname "$SKEL")"
  printf '# .bashrc de la distribution\nexport MARQUEUR_DISTRIBUTION=intact\nalias ll="ls -alF"\n' > "$SKEL"
  local avant; avant="$(cat "$SKEL")"
  mod apply
  [ "$(head -3 "$SKEL")" = "$avant" ]
  grep -qF "if [ -r $BASHRC_LCARS ]; then . $BASHRC_LCARS; fi" "$SKEL"
  rm -f "$BASHRC_LCARS"
  run bash -c "set -e; . '$SKEL'; echo OK-INERTE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK-INERTE"* ]]
  mod apply
  [ "$(grep -c 'lcars:skel >>>' "$SKEL")" -eq 1 ]
}

@test "bash.bashrc : le bloc PATH met ~/.local/bin devant pour un shell interactif, une fois, en préservant le fichier" {
  mkdir -p "$(dirname "$BASH_BASHRC")"
  printf '# bash.bashrc de la distribution\nshopt -s checkwinsize\n' > "$BASH_BASHRC"
  mod apply
  [ "$(head -2 "$BASH_BASHRC")" = "$(printf '# bash.bashrc de la distribution\nshopt -s checkwinsize')" ]
  local home="$BATS_TEST_TMPDIR/home"; mkdir -p "$home/.local/bin"
  run env -i HOME="$home" PATH=/usr/bin:/bin bash -c ". '$BASH_BASHRC'; . '$BASH_BASHRC'; echo \"\$PATH\""
  [ "$output" = "$home/.local/bin:/usr/bin:/bin" ]
  run env -i HOME="$BATS_TEST_TMPDIR/sans" PATH=/usr/bin:/bin bash -c ". '$BASH_BASHRC'; echo \"\$PATH\""
  [ "$output" = "/usr/bin:/bin" ]
  mod check
  [[ "$output" == *"PATH des shells interactifs : ~/.local/bin ($BASH_BASHRC)"* ]]
  mod apply
  [ "$(grep -c 'lcars:path >>>' "$BASH_BASHRC")" -eq 1 ]
}

@test "check : un bloc géré vidé de son corps est un drift, le marqueur seul ne suffit pas" {
  mod apply
  printf '# >>> lcars:path >>> (bloc géré par deploy — édition manuelle écrasée au prochain apply)\n# rien\n# <<< lcars:path <<<\n' > "$BASH_BASHRC"
  printf '# >>> lcars:skel >>> (bloc géré par deploy — édition manuelle écrasée au prochain apply)\n# <<< lcars:skel <<<\n' > "$SKEL"
  mod check
  [[ "$output" == *"DRIFT 62-runtime-helpers: $BASH_BASHRC sans le bloc PATH attendu"* ]]
  [[ "$output" == *"DRIFT 62-runtime-helpers: $SKEL sans le raccord attendu"* ]]
  mod apply
  mod check
  [[ "$output" == *"PATH des shells interactifs"*"squelette des humains raccordé"* ]]
}

@test "check : un arbre embarqué du runtime absent (bin, etc, services) est un drift" {
  mod apply
  rm -rf "${HELPERS:?}/bin"
  mod check
  [[ "$output" == *"arbre embarqué absent ($HELPERS/bin)"* ]]
  [[ "$output" == *"arbre embarqué $HELPERS/etc"*"arbre embarqué $HELPERS/services"* ]]
}

@test "embarqué : aucun fichier ni répertoire posé n'est setgid ni inscriptible par le groupe ou les autres" {
  need_git_checkout
  mod apply
  [ -d "$HELPERS/services" ]
  [ "$(find "$HELPERS/services" "$HELPERS/deploy" -perm /2022 2>/dev/null | wc -l)" -eq 0 ]
}

@test "modes : un auxiliaire g+w est un drift nommé, l'apply le ramène à 0755 sans le reposer" {
  mod apply
  local me; me="$(id -un):$(id -gn)"
  chmod 0775 "$HELPERS/console.sh"
  mod check
  [[ "$output" == *"$HELPERS/console.sh : 775 $me ≠ 755 $me"* ]]
  local before; before="$(stat -c %Y "$HELPERS/console.sh")"
  mod apply
  [ "$(stat -c %a "$HELPERS/console.sh")" = 755 ]
  [ "$(stat -c %Y "$HELPERS/console.sh")" = "$before" ]
  mod check
  refute grep -qF "$HELPERS/console.sh : " <<<"$output"
  [[ "$output" == *"modes et propriétaires relus"* ]]
}

@test "modes : une donnée en 0664 est un drift nommé, l'apply la ramène" {
  mod apply
  local me; me="$(id -un):$(id -gn)"
  chmod 0664 "$HELPERS/console.tmux.conf"
  mod check
  [[ "$output" == *"$HELPERS/console.tmux.conf : 664 $me ≠ 644 $me"* ]]
  mod apply
  [ "$(stat -c %a "$HELPERS/console.tmux.conf")" = 644 ]
}

@test "modes : un arbre embarqué avec un objet g+w ou setgid est un drift compté, l'apply repose l'arbre ; ce que la copie n'emporte pas n'est pas jugé" {
  need_git_checkout
  mod apply
  chmod g+w "$HELPERS/services/console.sh"
  mod check
  [[ "$output" == *"$HELPERS/services : 1 objet(s) hors contrat (premier : $HELPERS/services/console.sh, "* ]]
  mod apply
  mod check
  refute grep -qF "$HELPERS/services : " <<<"$output"
  chmod g+s "$HELPERS/services/human.d"; chmod o+w "$HELPERS/services/console.sh"
  mod check
  [[ "$output" == *"$HELPERS/services : 2 objet(s) hors contrat"* ]]
  mkdir -p "$HELPERS/deploy/.terraform" "$HELPERS/assets/node_modules"
  ln -s /nulle/part "$HELPERS/deploy/.terraform/lien"; chmod 0777 "$HELPERS/assets/node_modules"
  mod check
  refute grep -qF "$HELPERS/deploy : " <<<"$output"
  refute grep -qF "$HELPERS/assets : " <<<"$output"
}
