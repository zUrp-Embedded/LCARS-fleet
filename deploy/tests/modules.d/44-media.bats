#!/usr/bin/env bats
# SOURCE: deploy/tests/modules.d/44-media.bats
# AUTHOR: bob
# STARDATE: 2026-09-08
# STATUS: bats tests for 44-media.sh — le tampon de la doc, et ce qu'il autorise a NE PAS refaire
#
# CE QUE CES TEMOINS FERMENT. Le tampon `.doc-revision` a ete pose le 2026-09-08 pour rendre ce
# module idempotent — il rebatissait (`npm ci` + build) et reposait l'arbre `doc/` ENTIER a chaque
# apply. Il est arrive SANS AUCUN TEMOIN : trois fonctions neuves (`doc_stamp`, `doc_a_jour`,
# `doc_empreinte`) et deux court-circuits, mesures une fois a la main sur un banc, jamais rejoues.
# Un correctif d'idempotence sans temoin est une regression en attente : le prochain qui deplace le
# tampon ou change son format ne verra rien rougir, et le module se remettra a tout reposer en
# silence — le defaut est INVISIBLE, c'est toute sa difficulte.
#
# ⚠ CE CORPUS NE JOUE NI `check` NI `apply` EN ENTIER : les deux veulent `$PROV_ROOT/share`, root et
# npm. Ce qui se mesure ici est le TAMPON et les deux court-circuits — la seule partie du module ou
# une faute est silencieuse. Le reste (modes, proprietaires, formes de copie) est tenu par
# `poseurs.bats` et `delivery_form.bats`, qui lisent la SOURCE.

setup() {
  SRC="$BATS_TEST_DIRNAME/../../modules.d/44-media.sh"
  [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=44-media
  export PROV_HUMAN=temoin
  export PROV_FLEET_GROUP=fleet
  export PROV_SUBSTRATE=linux

  # Le decor : une racine de medias, une source de site avec son `dist/`, et le proprietaire du
  # temoin — jamais root, un temoin ne chown pas.
  export LCARS_MEDIA_ROOT="$BATS_TEST_TMPDIR/share"
  LCARS_MEDIA_OWNER="$(id -un):$(id -gn)"; export LCARS_MEDIA_OWNER   # SC2155 : le rc de `id` ne se masque pas
  export LCARS_MEDIA_SRC_ROOT="$BATS_TEST_TMPDIR/assets"
  export LCARS_SITE_SRC="$BATS_TEST_TMPDIR/assets/github.io"
  export LCARS_SITE_BASE="/doc/"
  mkdir -p "$LCARS_MEDIA_ROOT" "$LCARS_SITE_SRC/dist"
  printf '<html>la doc</html>' > "$LCARS_SITE_SRC/dist/index.html"
  printf 'body{}' > "$LCARS_SITE_SRC/dist/style.css"

  # Le corps du module SANS son dispatch final : on appelle ses fonctions, on ne le lance pas.
  MOD="$BATS_TEST_TMPDIR/mod.sh"
  sed '/^case "${1:?usage/,$d' "$SRC" > "$MOD"
}

# mod <expression> — joue une expression dans le module source
mod() { run bash -c "set -uo pipefail; source '$MOD' >/dev/null 2>&1; $1"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  head -8 "$SRC" | grep -q '^# SOURCE:'
  head -8 "$SRC" | grep -q '^# AUTHOR:'
  head -8 "$SRC" | grep -q '^# STARDATE:'
  head -8 "$SRC" | grep -q '^# STATUS:'
}

@test "EMPREINTE : la BASE en fait partie — le meme dist sous deux bases n'est pas le meme site" {
  # ⚠ SANS CA, LE TAMPON DECLARE « A JOUR » UNE DOC BATIE POUR UNE AUTRE BASE. `LCARS_SITE_BASE`
  # decide du prefixe de chaque URL d'asset ; servi sous « / » au lieu de « /doc/ », le site charge
  # zero feuille de style et personne ne le voit avant d'ouvrir la page.
  mod 'doc_empreinte'; [ "$status" -eq 0 ]
  local a="$output"
  LCARS_SITE_BASE=/ mod 'doc_empreinte'; [ "$status" -eq 0 ]
  [ "$output" != "$a" ] || { echo "l'empreinte ignore la base : $a"; return 1; }
}

@test "EMPREINTE : un fichier du dist qui change change l'empreinte" {
  mod 'doc_empreinte'; local a="$output"
  printf 'body{color:red}' > "$LCARS_SITE_SRC/dist/style.css"
  mod 'doc_empreinte'
  [ "$output" != "$a" ] || { echo "l'empreinte ne voit pas le contenu du dist"; return 1; }
}

@test "EMPREINTE : sans dist, elle n'invente rien — elle REFUSE" {
  rm -rf "$LCARS_SITE_SRC/dist"
  mod 'doc_empreinte'
  [ "$status" -ne 0 ] || { echo "une empreinte a ete rendue sans dist : « $output »"; return 1; }
}

@test "POSE : la seconde pose ne repose RIEN — c'est tout l'objet du tampon" {
  # La mesure du 2026-09-08 sur le banc 2005 : trois apply de suite, douze objets « POSÉ » stables,
  # dont `share/doc/index.html` dont le mtime changeait a chaque passage.
  run bash -c "set -uo pipefail; source '$MOD' >/dev/null 2>&1
    PROV_CHANGED=0; poser_doc; echo \"---1 changed=\$PROV_CHANGED\"
    PROV_CHANGED=0; poser_doc; echo \"---2 changed=\$PROV_CHANGED\""
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # ⚠ « > 0 », PAS « == 1 » : la pose compte DEUX changements (le tampon par `write_atomic`, puis la
  # pose elle-meme). Pinner le nombre exact, c'est pinner la mecanique interne — ce qui se mesure
  # ici est que la premiere pose COMPTE et que la seconde ne compte RIEN.
  [[ "$output" =~ ---1\ changed=([1-9][0-9]*) ]] || { echo "la PREMIERE pose n'a rien compte : $output"; return 1; }
  [[ "$output" == *"---2 changed=0"* ]] || { echo "la SECONDE pose a repose l'arbre : $output"; return 1; }
  [[ "$output" == *"rien à poser"* ]] || { echo "la seconde pose ne DIT pas qu'elle n'a rien fait : $output"; return 1; }
}

@test "POSE : un dist qui a change est repose — le court-circuit n'est pas un mur" {
  # LE TEMOIN DU TEMOIN. Sans lui, un `poser_doc` qui ne poserait JAMAIS passerait celui du dessus.
  run bash -c "set -uo pipefail; source '$MOD' >/dev/null 2>&1
    PROV_CHANGED=0; poser_doc >/dev/null
    printf 'nouveau' > '$LCARS_SITE_SRC/dist/index.html'
    PROV_CHANGED=0; poser_doc; echo \"---changed=\$PROV_CHANGED\""
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" =~ ---changed=([1-9][0-9]*) ]] || { echo "un dist modifie n'a PAS ete repose : $output"; return 1; }
  [ "$(cat "$LCARS_MEDIA_ROOT/doc/index.html")" = nouveau ] \
    || { echo "l'arbre pose ne porte pas le nouveau contenu"; return 1; }
}

@test "TAMPON : il vit A COTE de doc/, jamais dedans — prov_promote_dir l'emporterait" {
  mod 'poser_doc >/dev/null; doc_stamp'
  [ "$status" -eq 0 ]
  [[ "$output" == "$LCARS_MEDIA_ROOT/.doc-revision" ]] || { echo "tampon a $output"; return 1; }
  [ -f "$LCARS_MEDIA_ROOT/.doc-revision" ] || { echo "le tampon n'a pas ete ecrit par poser_doc"; return 1; }
  [ ! -e "$LCARS_MEDIA_ROOT/doc/.doc-revision" ] || { echo "un tampon a ete pose DANS doc/ : promote l'emportera"; return 1; }
}

@test "TAMPON : il porte l'empreinte du dist, et la base quand la revision est comparable" {
  mod 'poser_doc >/dev/null'
  local t="$LCARS_MEDIA_ROOT/.doc-revision"
  grep -q '^dist ' "$t" || { echo "pas de champ « dist » dans le tampon :"; cat "$t"; return 1; }
  # `rev`/`base` ne s'ecrivent que si la revision est comparable — ici l'arbre du depot est celui du
  # temoin, donc le champ peut manquer ; ce qui NE doit jamais arriver, c'est l'un sans l'autre.
  if grep -q '^rev ' "$t"; then
    grep -q '^base ' "$t" || { echo "« rev » sans « base » : le court-circuit du build ne pourrait pas juger"; return 1; }
  fi
}

@test "A JOUR : une base differente de celle du tampon REBATIT" {
  mod 'poser_doc >/dev/null'
  # on force un tampon comparable, la ou le depot du temoin n'en donne pas
  printf 'rev abc12345\nbase /doc/\ndist %s\n' "$(cd "$BATS_TEST_TMPDIR" && bash -c "source '$MOD' >/dev/null 2>&1; doc_empreinte")" \
    > "$LCARS_MEDIA_ROOT/.doc-revision"
  run bash -c "set -uo pipefail; source '$MOD' >/dev/null 2>&1; PROV_SOURCE_REV=abc12345 LCARS_SITE_BASE=/autre/ doc_a_jour"
  [ "$status" -ne 0 ] || { echo "une doc batie pour « /doc/ » est declaree a jour sous « /autre/ »"; return 1; }
}

@test "A JOUR : un fichier NON SUIVI dans les sources refuse le court-circuit" {
  # ⚠ « +local » NE PARLE QUE DES FICHIERS SUIVIS. Un fichier neuf laisse la revision propre : sans
  # cette garde, le module saute un build qu'il fallait faire, et sert une doc d'avant le fichier.
  git -C "$LCARS_SITE_SRC" init -q 2>/dev/null || skip "git indisponible"
  git -C "$LCARS_SITE_SRC" add -A >/dev/null 2>&1
  git -C "$LCARS_SITE_SRC" -c user.email=t@t -c user.name=t commit -qm decor >/dev/null 2>&1
  mod 'poser_doc >/dev/null'
  printf 'rev abc12345\nbase /doc/\ndist %s\n' "$(bash -c "source '$MOD' >/dev/null 2>&1; doc_empreinte")" \
    > "$LCARS_MEDIA_ROOT/.doc-revision"
  run bash -c "set -uo pipefail; source '$MOD' >/dev/null 2>&1; PROV_SOURCE_REV=abc12345 doc_a_jour"
  [ "$status" -eq 0 ] || { echo "arbre propre et tampon conforme : le court-circuit devrait s'appliquer — $output"; return 1; }
  printf 'brouillon' > "$LCARS_SITE_SRC/nouveau-fichier.md"
  run bash -c "set -uo pipefail; source '$MOD' >/dev/null 2>&1; PROV_SOURCE_REV=abc12345 doc_a_jour"
  [ "$status" -ne 0 ] || { echo "un fichier non suivi n'empeche pas le court-circuit"; return 1; }
}

# ─── LES MODES : LE FILTRE DOIT SÉLECTIONNER EXACTEMENT CE QUE LE GESTE CHANGERAIT ──────────────
#
# ⚠ UN FILTRE TROP ÉTROIT SAUTE UN GESTE UTILE EN SILENCE, un filtre trop large repose tout à chaque
# apply. Les deux fautes sont invisibles à la lecture, et le correctif d'idempotence du 2026-09-08 a
# commis la première : `! -perm -a=r` ne voit que l'absence de LECTURE, alors que `a+rX` pose aussi
# le `x` dès qu'un `x` existe quelque part. Six modes passaient au travers.

@test "LES MODES : un fichier qu'il faut corriger l'EST — les six modes que l'ancien filtre ratait" {
  local d="$BATS_TEST_TMPDIR/arbre/sous" m
  mkdir -p "$d"
  for m in 744 754 764 774 654 745 700 750 604; do printf x > "$d/f$m"; chmod "$m" "$d/f$m"; done
  run bash -c "set -uo pipefail; source '$MOD' >/dev/null 2>&1; media_modes '$BATS_TEST_TMPDIR/arbre'"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local bad=()
  for m in 744 754 764 774 654 745 700 750 604; do
    # ce que `chmod a+rX` rend depuis ce mode, mesuré sur un temoin jetable
    printf x > "$BATS_TEST_TMPDIR/ref"; chmod "$m" "$BATS_TEST_TMPDIR/ref"; chmod a+rX "$BATS_TEST_TMPDIR/ref"
    local attendu; attendu="$(stat -c %a "$BATS_TEST_TMPDIR/ref")"
    [ "$(stat -c %a "$d/f$m")" = "$attendu" ] || bad+=("$m → $(stat -c %a "$d/f$m"), attendu $attendu")
  done
  [ "${#bad[@]}" -eq 0 ] || { printf '  le filtre a saute : %s\n' "${bad[@]}"; return 1; }
}

@test "LES MODES : un arbre DÉJÀ conforme n'appelle AUCUN chmod — c'est le coût, pas le ctime" {
  # ⚠ LE CTIME NE PEUT PAS SERVIR D'INSTRUMENT ICI, ET C'EST UNE MESURE, PAS UNE OPINION. Remesuré
  # le 2026-09-08 : un `chmod` dont le mode est déjà conforme laisse le ctime INCHANGÉ (alors qu'un
  # `chown` vers le même propriétaire le change — c'est lui, et `cp -a "$src/."`, qui cassaient
  # l'idempotence). Un témoin bâti sur le ctime resterait donc vert avec un geste inconditionnel :
  # il ne mesurerait rien. Ce que le filtre achète est le COÛT — n'exécuter aucun chmod sur un arbre
  # conforme — et c'est cela qu'on interpose pour compter.
  local d="$BATS_TEST_TMPDIR/arbre/a/b"
  mkdir -p "$d"; chmod 755 "$BATS_TEST_TMPDIR/arbre" "$BATS_TEST_TMPDIR/arbre/a" "$d"
  printf x > "$d/f"; chmod 644 "$d/f"
  local faux="$BATS_TEST_TMPDIR/bin"; mkdir -p "$faux"
  cat > "$faux/chmod" <<'SH'
#!/usr/bin/env bash
echo "chmod $*" >> "$FAUX_TRACE"
exec /usr/bin/chmod "$@"
SH
  chmod +x "$faux/chmod"
  FAUX_TRACE="$BATS_TEST_TMPDIR/chmod.trace"; : > "$FAUX_TRACE"
  run env FAUX_TRACE="$FAUX_TRACE" PATH="$faux:$PATH" \
    bash -c "set -uo pipefail; source '$MOD' >/dev/null 2>&1; media_modes '$BATS_TEST_TMPDIR/arbre'"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -s "$FAUX_TRACE" ] \
    || { echo "un arbre conforme a fait exécuter des chmod :"; cat "$FAUX_TRACE"; return 1; }
}

@test "LES MODES : TÉMOIN DU TÉMOIN — un arbre qui DÉVIE, lui, fait bien exécuter un chmod" {
  # Sans lui, celui du dessus passerait sur un `media_modes` qui ne ferait plus rien du tout.
  local d="$BATS_TEST_TMPDIR/arbre/a/b"
  mkdir -p "$d"; chmod 755 "$BATS_TEST_TMPDIR/arbre" "$BATS_TEST_TMPDIR/arbre/a"; chmod 775 "$d"
  local faux="$BATS_TEST_TMPDIR/bin"; mkdir -p "$faux"
  cat > "$faux/chmod" <<'SH'
#!/usr/bin/env bash
echo "chmod $*" >> "$FAUX_TRACE"
exec /usr/bin/chmod "$@"
SH
  chmod +x "$faux/chmod"
  FAUX_TRACE="$BATS_TEST_TMPDIR/chmod.trace"; : > "$FAUX_TRACE"
  run env FAUX_TRACE="$FAUX_TRACE" PATH="$faux:$PATH" \
    bash -c "set -uo pipefail; source '$MOD' >/dev/null 2>&1; media_modes '$BATS_TEST_TMPDIR/arbre'"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -s "$FAUX_TRACE" ] || { echo "un repertoire en 775 n'a declenche AUCUN chmod"; return 1; }
  [ "$(stat -c %a "$d")" = 755 ] || { echo "et il est reste en $(stat -c %a "$d")"; return 1; }
}

@test "LES MODES : un repertoire g+w ou setgid est ramene a 755" {
  local d="$BATS_TEST_TMPDIR/arbre/sous"
  mkdir -p "$d/g" "$d/s"; chmod 775 "$d/g"; chmod 2755 "$d/s"
  run bash -c "set -uo pipefail; source '$MOD' >/dev/null 2>&1; media_modes '$BATS_TEST_TMPDIR/arbre'"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$d/g")" = 755 ] || { echo "g+w garde : $(stat -c %a "$d/g")"; return 1; }
  [ "$(stat -c %a "$d/s")" = 755 ] || { echo "setgid garde : $(stat -c %a "$d/s")"; return 1; }
}
