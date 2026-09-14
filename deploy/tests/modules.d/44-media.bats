#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/44-media.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de 44-media — les deux arbres de médias, la doc bâtie puis posée une fois, les modes relus contre la table

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  MOD="$BATS_TEST_DIRNAME/../../modules.d/44-media.sh"; [ -f "$MOD" ]
  # un arbre de source : la lib et ses tables, les médias et le site sous assets/ — le module les lit sous la racine de la lib
  ARBRE="$BATS_TEST_TMPDIR/source"
  mkdir -p "$ARBRE/deploy"
  cp -r "$BATS_TEST_DIRNAME/../../lib" "$ARBRE/deploy/lib"
  cp "$BATS_TEST_DIRNAME/../../installer-constants.env" "$BATS_TEST_DIRNAME/../../system.manifest" "$ARBRE/deploy/"
  export PROVISION_LIB="$ARBRE/deploy/lib/provision-lib.sh"
  export PROVISION_MODULE=44-media PROV_SUBSTRATE=linux PROV_HUMAN=root
  export PROV_SOURCE_REV=abc12345
  decor_pose
  SHARE="$LCARS_DECOR_ROOT/opt/lcars/share"
  MEDIAS="$ARBRE/assets"
  SITE="$ARBRE/assets/github.io"
  mkdir -p "$MEDIAS/avatars" "$MEDIAS/favicon" "$SITE"
  printf 'png' > "$MEDIAS/avatars/admiral.png"; printf 'png' > "$MEDIAS/avatars/lcars.png"
  printf 'ico' > "$MEDIAS/favicon/favicon.ico"
  printf 'dist\nnode_modules\n' > "$SITE/.gitignore"; printf '{}' > "$SITE/package.json"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export NPM_TRACE="$BATS_TEST_TMPDIR/npm.trace"; : > "$NPM_TRACE"
  cat > "$DECOR_BIN/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >> "$NPM_TRACE"
if [[ "$1 $2" == "run build" ]]; then
  echo "base=${LCARS_SITE_BASE:-<vide>}" >> "$NPM_TRACE"
  mkdir -p dist && printf '<html>doc %s</html>' "$LCARS_SITE_BASE" > dist/index.html && printf 'body{}' > dist/style.css
fi
EOF
  chmod 0755 "$DECOR_BIN/npm"
}

mod() { run unshare -Ur bash "$MOD" "$@"; }
site_git() { # le site est un dépôt propre : la révision devient comparable
  git -C "$SITE" init -q && git -C "$SITE" add -A \
    && git -C "$SITE" -c user.email=t@t -c user.name=t commit -qm décor
}
fn() { run bash -c "set -uo pipefail; source <(sed '/^case \"\${1:?usage/,\$d' '$MOD') >/dev/null 2>&1; $1"; }

@test "check : arbres et doc absents — trois drifts qui disent la conséquence" {
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 44-media: $SHARE/avatars absent — la charte de forge échoue dessus, et le deck sert des icônes génériques"* ]]
  [[ "$output" == *"$SHARE/favicon absent"* ]]
  [[ "$output" == *"$SHARE/doc absente — l'onglet Doc du deck rendra 404"* ]]
}

@test "check : un arbre vide est incomplet, un doc/ sans index.html est absent" {
  mkdir -p "$SHARE/avatars" "$SHARE/favicon" "$SHARE/doc"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"$SHARE/avatars incomplet (0 fichiers) — la source en porte plus"* ]]
  [[ "$output" == *"$SHARE/doc absente"* ]]
}

@test "apply : les deux arbres posés (leur contenu, pas avatars/avatars), la doc bâtie sous la base /doc/ et posée, le tampon à côté de doc/, le check vert" {
  site_git
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$SHARE/avatars/admiral.png" ]
  [ ! -e "$SHARE/avatars/avatars" ]
  [ -f "$SHARE/favicon/favicon.ico" ]
  [ "$(cat "$SHARE/doc/index.html")" = "<html>doc /doc/</html>" ]
  grep -qx 'base=/doc/' "$NPM_TRACE"
  grep -q '^rev abc12345$' "$SHARE/.doc-revision"
  grep -q '^base /doc/$' "$SHARE/.doc-revision"
  [ ! -e "$SHARE/doc/.doc-revision" ]
  [ ! -e "$SHARE/doc.partial" ]
  [ "$(stat -c '%a %U' "$SHARE/avatars")" = "755 $(id -un)" ]
  [[ "$output" == *"POSÉ  44-media: doc du deck posée ($SHARE/doc, base /doc/)"* ]]
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"avatars posé (2 fichiers)"*"doc posée (2 fichiers)"* ]]
}

@test "les sources se lisent sous l'arbre de la lib : un environnement qui nomme d'autres médias ou un autre site ne les déplace pas" {
  site_git
  local piege="$BATS_TEST_TMPDIR/piege"
  mkdir -p "$piege/avatars" "$piege/favicon" "$piege/site/dist"
  printf 'piège' > "$piege/avatars/piege.png"; printf 'piège' > "$piege/favicon/piege.ico"
  printf '<html>piège</html>' > "$piege/site/dist/index.html"
  LCARS_MEDIA_SRC_ROOT="$piege" LCARS_SITE_SRC="$piege/site" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$SHARE/avatars/admiral.png" ]
  [ ! -e "$SHARE/avatars/piege.png" ]
  [ "$(cat "$SHARE/doc/index.html")" = "<html>doc /doc/</html>" ]
  [ "$(cat "$piege/site/dist/index.html")" = "<html>piège</html>" ]
  refute_out 'piege' <<<"$output"
}

@test "apply rejoué sur un site propre : la doc n'est pas rebâtie, rien n'est reposé" {
  site_git
  mod apply; [ "$status" -eq 0 ]
  : > "$NPM_TRACE"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -s "$NPM_TRACE" ]
  [[ "$output" == *"doc du deck à jour ($SHARE/doc, révision abc12345) — rien à rebâtir"* ]]
  [[ "$output" != *"POSÉ"* ]]
}

@test "apply : une mise à jour des médias est posée et dite, l'arbre voisin inchangé ne l'est pas ; un fichier en plus sous le posé ne compte pas" {
  site_git
  mod apply; [ "$status" -eq 0 ]
  [[ "$output" == *"POSÉ  44-media: médias posés ($SHARE/avatars)"*"POSÉ  44-media: médias posés ($SHARE/favicon)"* ]]
  printf 'png v2' > "$MEDIAS/avatars/admiral.png"
  printf 'posé à la main' > "$SHARE/favicon/local.ico"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"POSÉ  44-media: médias posés ($SHARE/avatars)"* ]]
  [[ "$output" != *"médias posés ($SHARE/favicon)"* ]]
  [ "$(cat "$SHARE/avatars/admiral.png")" = "png v2" ]
}

@test "apply : une autre base, ou un fichier nouveau dans les sources du site, rebâtit la doc" {
  site_git
  mod apply; [ "$status" -eq 0 ]
  : > "$NPM_TRACE"
  LCARS_SITE_BASE=/autre/ mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'base=/autre/' "$NPM_TRACE"
  [ "$(cat "$SHARE/doc/index.html")" = "<html>doc /autre/</html>" ]
  : > "$NPM_TRACE"
  printf 'brouillon' > "$SITE/nouveau.md"
  LCARS_SITE_BASE=/autre/ mod apply
  [ "$status" -eq 0 ]
  grep -q 'npm run build' "$NPM_TRACE"
}

@test "apply : npm absent du PATH — échec nommé, la doc n'est pas posée" {
  local d sans=""
  rm -f "$DECOR_BIN/npm"
  # le PATH du décor garde tout sauf les dossiers qui portent un npm
  while IFS= read -r d; do [[ -x "$d/npm" ]] || sans+="${sans:+:}$d"; done < <(tr ':' '\n' <<<"$PATH")
  PATH="$sans" mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  44-media: npm absent — 16-node pose le précompilé épinglé"* ]]
  [ ! -e "$SHARE/doc" ]
}

@test "apply : source des médias absente — échec nommé, l'arbre n'est pas posé" {
  rm -rf "$MEDIAS/favicon"
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  44-media: source absente : $MEDIAS/favicon"* ]]
  [ ! -e "$SHARE/favicon" ]
}

@test "modes : un objet de la table au mauvais mode est un drift nommé, l'apply le ramène" {
  site_git
  mod apply; [ "$status" -eq 0 ]
  chmod 0700 "$SHARE/avatars"; chmod 2755 "$SHARE/doc"; chmod 0750 "$SHARE"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"$SHARE/avatars : 700 root:root ≠ 755 root:root (deploy/system.manifest) — l'apply le repose"* ]]
  [[ "$output" == *"$SHARE/doc : 2755 root:root ≠ 755 root:root"*"$SHARE : 750 root:root ≠ 755 root:root"* ]]
  mod apply
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$SHARE/avatars")" = 755 ]
  [ "$(stat -c %a "$SHARE/doc")" = 755 ]
  [ "$(stat -c %a "$SHARE")" = 755 ]
}

@test "modes : le mode vient de la table — une table à 0750 pour avatars est lue telle quelle, au check et à l'apply" {
  site_git
  sed 's#^\(dir  *\)/opt/lcars/share/avatars  *0755#\1/opt/lcars/share/avatars  0750#' \
    "$BATS_TEST_DIRNAME/../../system.manifest" > "$ARBRE/deploy/system.manifest"
  grep -qE '^dir +/opt/lcars/share/avatars +0750 ' "$ARBRE/deploy/system.manifest"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(stat -c %a "$SHARE/avatars")" = 750 ]
  [ "$(stat -c %a "$SHARE/favicon")" = 755 ]
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "modes : l'arbre profond est ramené en 755/644 sans bits spéciaux, y compris les modes qu'un filtre sur la seule lecture manquait" {
  local d="$BATS_TEST_TMPDIR/arbre/sous" m
  mkdir -p "$d/g" "$d/s"; chmod 775 "$d/g"; chmod 2755 "$d/s"
  for m in 744 754 764 774 654 745 700 750 604; do printf x > "$d/f$m"; chmod "$m" "$d/f$m"; done
  fn "media_modes '$BATS_TEST_TMPDIR/arbre'"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(stat -c %a "$d/g")" = 755 ]
  [ "$(stat -c %a "$d/s")" = 755 ]
  for m in 744 754 764 774 654 745 700 750 604; do
    printf x > "$BATS_TEST_TMPDIR/ref"; chmod "$m" "$BATS_TEST_TMPDIR/ref"; chmod a+rX "$BATS_TEST_TMPDIR/ref"
    [ "$(stat -c %a "$d/f$m")" = "$(stat -c %a "$BATS_TEST_TMPDIR/ref")" ] || { echo "f$m → $(stat -c %a "$d/f$m")"; return 1; }
  done
}

@test "modes : un arbre conforme n'exécute aucun chmod, un dossier qui dévie en exécute un" {
  local d="$BATS_TEST_TMPDIR/arbre/a/b"
  mkdir -p "$d"; chmod 755 "$BATS_TEST_TMPDIR/arbre" "$BATS_TEST_TMPDIR/arbre/a" "$d"
  printf x > "$d/f"; chmod 644 "$d/f"
  printf '#!/usr/bin/env bash\necho "chmod $*" >> "$CHMOD_TRACE"\nexec /usr/bin/chmod "$@"\n' > "$BIN/chmod"; chmod +x "$BIN/chmod"
  export CHMOD_TRACE="$BATS_TEST_TMPDIR/chmod.trace"; : > "$CHMOD_TRACE"
  PATH="$BIN:$PATH" fn "media_modes '$BATS_TEST_TMPDIR/arbre'"
  [ "$status" -eq 0 ]
  [ ! -s "$CHMOD_TRACE" ] || { cat "$CHMOD_TRACE"; return 1; }
  chmod 775 "$d"
  PATH="$BIN:$PATH" fn "media_modes '$BATS_TEST_TMPDIR/arbre'"
  [ -s "$CHMOD_TRACE" ]
  [ "$(stat -c %a "$d")" = 755 ]
}

@test "pose de la doc sous un décor, au compte qui joue : la seconde pose du même dist ne compte rien, un dist qui a changé est reposé" {
  mkdir -p "$SHARE" "$SITE/dist"; printf 'v1' > "$SITE/dist/index.html"
  fn "PROV_CHANGED=0; poser_doc; echo \"c1=\$PROV_CHANGED\"; PROV_CHANGED=0; poser_doc; echo \"c2=\$PROV_CHANGED\"
      [ -e '$SHARE/doc.partial' ] && echo 'partiel-laissé'
      printf v2 > '$SITE/dist/index.html'; PROV_CHANGED=0; poser_doc; echo \"c3=\$PROV_CHANGED\""
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" =~ c1=[1-9] ]]
  [[ "$output" == *"c2=0"* ]]
  # un dossier doc.partial laissé par la pose « déjà posée » serait un objet que le manifeste ne déclare pas
  [[ "$output" != *"partiel-laissé"* ]]
  [[ "$output" =~ c3=[1-9] ]]
  [[ "$output" == *"doc du deck déjà posée"* ]]
  [ "$(cat "$SHARE/doc/index.html")" = v2 ]
  [ "$(stat -c %U:%G "$SHARE/.doc-revision")" = "$(id -un):$(id -gn)" ]
  [ ! -e "$SHARE/doc/.doc-revision" ]
}
