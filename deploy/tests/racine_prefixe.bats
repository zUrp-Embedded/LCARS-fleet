#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/racine_prefixe.bats
# AUTHOR: alice
# STARDATE: 2026-08-28
# STATUS: mur — le prefixe d'install RO a une valeur, celle des constantes de l'installeur, et le runtime la dit

load refute

setup() {
  R="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # la RACINE du depot — `deploy/` et `runtime/` y sont FRERES
  LIB="$R/deploy/lib/provision-lib.sh"

  ATTENDU="$(env -i PATH="$PATH" bash -c ". '$LIB' >/dev/null 2>&1; printf '%s' \"\$PROV_PREFIX\"")"
  BIN_REL="$ATTENDU/rel/lcars_fleet/bin/lcars_fleet"
}

# Tout chemin absolu du fichier qui se termine par le binaire de release.
bins_de() { grep -ohE '/[A-Za-z0-9_./-]*/rel/lcars_fleet/bin/lcars_fleet' "$1" 2>/dev/null; }
porteurs_de_release() {
  grep -rlE '/rel/lcars_fleet/bin/lcars_fleet' "$R/deploy" "$R/runtime" \
    --exclude-dir=tests --exclude-dir=test --exclude-dir=_build --exclude-dir=deps \
    --exclude-dir=node_modules --exclude-dir=tmp --exclude-dir=.git --exclude='*.md' \
    --exclude=pack.sh 2>/dev/null | sort
}

@test "GARDE D'INSTRUMENT : la SSoT rend un prefixe absolu de profondeur >= 2" {
  [[ "$ATTENDU" == /*/* ]] || { echo "prefixe inexploitable : « $ATTENDU »" >&2; return 1; }
  [ -n "$BIN_REL" ]
}


@test "LES DEUX chemins de binaire de release sont le MEME, derive du prefixe" {
  local f n=0 nb=0 b porteur=""
  while IFS= read -r f; do
    while read -r b; do
      [ -n "$b" ] || continue
      case "$b" in
        */_build/prod/rel/lcars_fleet/bin/lcars_fleet)
          nb=$(( nb + 1 ))
          # La release BATIE se derive de la racine de l arbre, jamais du prefixe d install : un
          # chemin absolu en dur ici designerait la machine de celui qui a ecrit la ligne.
          [ "$b" = "/runtime/_build/prod/rel/lcars_fleet/bin/lcars_fleet" ] \
            || { echo "$f : chemin de release BATIE non derive de la racine : « $b »" >&2; return 1; } ;;
        *)
          n=$(( n + 1 )); porteur="${f#"$R/"}"
          [ "$b" = "$BIN_REL" ] || { echo "$f : « $b » au lieu de « $BIN_REL »" >&2; return 1; } ;;
      esac
    done < <(bins_de "$f")
  done < <(porteurs_de_release)
  [ "$n" -eq 1 ] || { echo "UN chemin de release POSEE attendu (bin/lcars), $n trouve(s) — le corpus a bouge, ce mur aussi doit bouger" >&2; return 1; }
  [ "$porteur" = runtime/bin/lcars ] || { echo "le chemin de release POSEE vit dans « $porteur », pas dans runtime/bin/lcars" >&2; return 1; }
  [ "$nb" -eq 0 ] || { echo "AUCUN chemin de release BATIE attendu, $nb trouve(s) — la devinette entre paquet et prefixe est revenue" >&2; return 1; }
}

@test "LE DOCKERFILE ne construit, ne copie ni ne cable RIEN sous le prefixe — c'est le rail qui le pose" {
  local d="$R/deploy/docker/Dockerfile"
  grep -vE '^\s*#' "$d" | grep -q 'provision apply --substrate docker' \
    || { echo "le Dockerfile ne joue plus le rail (provision apply --substrate docker)" >&2; return 1; }
  grep -vE '^\s*#' "$d" | grep -qE "$ATTENDU([[:space:]/]|\$)" \
    && { echo "le Dockerfile nomme le prefixe « $ATTENDU » — un geste sur la release hors du rail :" >&2; grep -nE "$ATTENDU" "$d" >&2; return 1; }
  return 0
}

@test "LA TABLE declare ce prefixe, et c'est le meme" {
  grep -qE "^prefix[[:space:]]+${ATTENDU}[[:space:]]" "$R/deploy/system.manifest" \
    || { echo "« $ATTENDU » n'est pas declare en classe \`prefix\` dans le manifeste" >&2; return 1; }
}
