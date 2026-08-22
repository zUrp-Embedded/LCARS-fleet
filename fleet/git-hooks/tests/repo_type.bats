#!/usr/bin/env bats
# SOURCE: fleet/git-hooks/tests/repo_type.bats
# AUTHOR: drdree
# STARDATE: 2026-08-14
# STATUS: bats tests for hook-config.sh — 6-117, la branche `lcars` du detecteur etait morte
#
# CE QUE CE DETECTEUR FAISAIT. `hook-config.sh` choisissait `HOOK_REPO_TYPE=lcars` si
# `fleet/fleet-env.sh` existait. Ce fichier n'est nulle part dans le depot et n'a aucun producteur :
# toute installation nominale des hooks DANS LCARS prenait donc la branche `project`. Le tampon
# STARDATE annonce par `pre-commit` ne s'executait jamais, et les variables de politique LCARS
# etaient inatteignables.
#
# Un detecteur qui ne detecte rien NE LEVE PAS : il repond l'autre branche, et le systeme tourne
# comme si le choix avait ete fait. C'est la meme famille que les exemptions GO-7 mortes, un cran
# plus haut : ici ce n'est pas une clause qui ne matche rien, c'est une IDENTITE.
#
# ⚠ LE DERNIER CAS LIT LE VRAI `fleet/mix.exs` DU DEPOT. C'est lui le verrou : une fixture ne
# saurait pas dire que le marqueur a derive. Le jour ou l'app est renommee, ce test le dit — au lieu
# d'un hook redevenu silencieusement `project`.

# ⚠ CES TEMOINS MESURENT UN CHECKOUT, PAS UN ARBRE LIVRE. Ils lisent le depot lui-meme — son
# toplevel, son `fleet/mix.exs` suivi — et un hook git n'a de sens que la ou il y a un `.git`.
# `git archive` n'en emporte jamais : une install depuis un tarball joue pourtant ce gate, sur un
# arbre ou l'objet mesure n'existe pas. Mesure du 2026-08-22 : DOUZE temoins rouges d'un coup,
# `60-deploy` mort sur « arbre source non atteste », et le rail tarball incapable de passer son
# propre gate — sur un code entierement sain.
#
# Le skip ne baisse pas la barre : il dit que la question ne se pose pas ici. Ce qui la baisserait,
# ce serait de faire croire qu'un depot a ete verifie la ou il n'y en a pas.
need_git_checkout() {
  git -C "$BATS_TEST_DIRNAME" rev-parse --git-dir >/dev/null 2>&1 \
    || skip "pas de checkout git (arbre livre par tarball) — ce temoin mesure un depot"
}

setup() {
  need_git_checkout
  HOOKS_SRC="$BATS_TEST_DIRNAME/.."
  REPO_ROOT="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
}

# Un depot git jetable dont on choisit le contenu de `fleet/mix.exs`.
make_repo() {
  local dir="$BATS_TEST_TMPDIR/$1" mix_content="${2-}"
  mkdir -p "$dir"
  git init -q --initial-branch main "$dir"
  if [[ -n "$mix_content" ]]; then
    mkdir -p "$dir/fleet"
    printf '%s\n' "$mix_content" > "$dir/fleet/mix.exs"
  fi
  printf '%s' "$dir"
}

# Source la config DEPUIS le depot cible, comme le fait un hook installe.
detect() {
  ( cd "$1" && source "$HOOKS_SRC/hook-config.sh" && printf '%s %s' "$HOOK_REPO_TYPE" "$HOOK_DATE_FORMAT" )
}

@test "6-117: un depot portant l'app lcars_fleet est detecte LCARS" {
  repo=$(make_repo lcars 'def project do
    [
      app: :lcars_fleet,
      version: "0.1.0"
    ]
  end')

  run detect "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "lcars stardate" ]
}

@test "6-117: un depot projet ordinaire reste PROJECT" {
  repo=$(make_repo projet)

  run detect "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "project iso" ]
}

@test "6-117: le CHEMIN seul ne suffit pas — un projet peut porter son propre fleet/mix.exs" {
  # Tester l'existence du fichier et pas son CONTENU rendrait LCARS de n'importe quel depot qui
  # s'organise avec un sous-projet `fleet/`. Le marqueur est l'identite de l'app, pas un dossier.
  repo=$(make_repo homonyme 'def project do
    [
      app: :une_autre_app,
      version: "0.1.0"
    ]
  end')

  run detect "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "project iso" ]
}

@test "6-117: l'ANCIEN sentinel ne ressuscite pas la branche — il ne veut plus rien dire" {
  # `fleet/fleet-env.sh` etait le marqueur mort. Le poser ne doit rien changer : sinon deux
  # marqueurs coexistent et le prochain lecteur ne sait pas lequel fait autorite.
  repo=$(make_repo ancien)
  mkdir -p "$repo/fleet"
  touch "$repo/fleet/fleet-env.sh"

  run detect "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "project iso" ]
}

@test "6-117: VERROU — le depot LCARS lui-meme est detecte LCARS" {
  # LE test de ce fichier. Les quatre precedents mesurent la logique sur des fixtures ; celui-ci
  # mesure le depot REEL. Un marqueur qui derive (app renommee, mix.exs deplace) rougit ICI, au lieu
  # de rendre le detecteur muet comme l'ancien.
  run detect "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "lcars stardate" ]
}
