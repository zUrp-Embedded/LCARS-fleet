#!/usr/bin/env bats
# SOURCE: runtime/git-hooks/tests/go7_exemptions_alive.bats
# AUTHOR: drdree
# STARDATE: 2026-08-14
# STATUS: bats tests for pre-commit GO-7 exemptions — aucune clause d'exemption ne survit a son sujet
#
# CE QUE CE MUR GARDE. `is_ipc_exception` porte les clauses qui exemptent un fichier de l'en-tete
# GO-7. Une clause qui ne matche AUCUN fichier suivi n'exempte rien : elle se lit comme couvrant une
# classe que le mur refuse en fait, et elle pourrit SANS BRUIT — rien n'echoue quand son sujet
# demenage ou disparait (mesure : deux clauses de ce genre, reparees a la main, ont chacune refuse
# pendant des semaines ce qu'elles etaient ecrites pour laisser passer).
#
# C'est la garde `measured_nothing?` des contrats, transposee : une population vide n'est pas un
# vert, c'est un instrument qui a cesse de voir son sujet.
#
# CE QUI EST MESURE : les motifs sont LUS dans le hook et joues avec le matcher du hook (glob bash,
# basename ou chemin complet) contre le vrai `git ls-files`. Le test ne recopie aucune liste — une
# liste recopiee derive de son sujet, et c'est exactement le defaut sous test.

# ⚠ CE MUR JOUE LES CLAUSES CONTRE `git ls-files` : SANS DEPOT, LA POPULATION EST VIDE. Et une
# population vide, ce fichier le dit lui-meme quinze lignes plus haut, n'est pas un vert — c'est un
# instrument qui a cesse de voir son sujet. Un tarball n'emporte pas `.git` (`git archive` n'en
# produit jamais), donc chaque clause y paraitrait morte et les quatre temoins rougiraient sur un
# hook parfaitement sain (mesure du 2026-08-22 : douze temoins de ce genre tuant `60-deploy` sur
# toute install depuis un tarball).
need_git_checkout() {
  git -C "$BATS_TEST_DIRNAME" rev-parse --git-dir >/dev/null 2>&1 \
    || skip "pas de checkout git (arbre livre par tarball) — ce temoin mesure un depot"
}

load ../../test/support/refute

setup() {
  need_git_checkout
  HOOK="$BATS_TEST_DIRNAME/../pre-commit"
  ROOT="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  mapfile -t FILES < <(git -C "$ROOT" ls-files)
}

# Lit les clauses de `is_ipc_exception` dans le hook. Emet `kind<TAB>glob`, kind = base|path.
# Les deux familles sont extraites separement parce qu'elles ne matchent pas le meme sujet : le
# `case` juge le basename, les `[[ ]]` jugent le chemin complet.
extract_patterns() {
  local hook="$1" body
  body=$(awk '/^is_ipc_exception\(\) \{/,/^\}/' "$hook")
  printf '%s\n' "$body" \
    | sed -n 's/^[[:space:]]*\([^[:space:]]*\)) return 0 ;;.*/\1/p' \
    | tr '|' '\n' | sed '/^$/d' | awk '{print "base\t" $0}'
  printf '%s\n' "$body" \
    | sed -n 's/^[[:space:]]*\[\[ \(.*\) \]\] \&\& return 0.*/\1/p' \
    | sed 's/ || /\n/g' | sed 's/^"[$]1" == //' | tr -d '"' \
    | sed '/^$/d' | awk '{print "path\t" $0}'
}

# Emet les clauses a zero correspondance. `$pat` est volontairement NON quote : c'est un glob, et le
# citer le rendrait litteral — le test mesurerait alors une egalite de chaines, jamais le mur.
dead_patterns() {
  local kind pat f b hit
  while IFS=$'\t' read -r kind pat; do
    hit=0
    # shellcheck disable=SC2254,SC2053  # `$pat` DOIT globber : c'est un motif extrait du `case` du
    #   hook (`*-handoff.md`, `*/skills/*/SKILL.md`) et cette fonction reproduit son matching. Le
    #   quoter ferait echouer toute comparaison — `dead_patterns` declarerait alors MORTES les
    #   clauses vivantes, et le temoin passerait au vert sur un detecteur devenu aveugle.
    if [[ "$kind" == base ]]; then
      for f in "${FILES[@]}"; do b="${f##*/}"; case "$b" in $pat) hit=1; break ;; esac; done
    else
      for f in "${FILES[@]}"; do [[ "$f" == $pat ]] && { hit=1; break; }; done
    fi
    (( hit == 0 )) && printf '%s\t%s\n' "$kind" "$pat"
  done < <(extract_patterns "$1")
  return 0
}

@test "l'extracteur voit les DEUX familles de clauses du hook" {
  # Garde d'instrument. Sans elle, une reecriture de la forme de la fonction viderait l'extraction
  # et le test suivant serait vert sur zero motif — le mur declare conforme sans avoir ete ouvert.
  run extract_patterns "$HOOK"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  printf '%s\n' "$output" | grep -q "^base	" || {
    echo "aucune clause basename extraite — la forme du bloc case a change"; false
  }
  printf '%s\n' "$output" | grep -q "^path	" || {
    echo "aucune clause de chemin extraite — la forme des tests [[ ]] a change"; false
  }
}

@test "chaque clause d'exemption GO-7 matche au moins un fichier suivi" {
  run dead_patterns "$HOOK"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    echo "clauses a ZERO correspondance dans is_ipc_exception :"
    echo "$output"
    echo "--- une clause morte n'exempte rien et se lit comme si elle exemptait. Deux remedes :"
    echo "--- le sujet a DEMENAGE -> corriger le motif ; le sujet a ete RETIRE -> supprimer la clause."
    echo "--- pour un arbre a venir, le mecanisme est le marqueur .go7-exempt, pas une liste ici."
    false
  fi
}

@test "une clause morte est DETECTEE (le mur peut echouer)" {
  # Contre-preuve : sans elle, le test precedent serait indistinguable d'une extraction muette.
  local fake="$BATS_TEST_TMPDIR/pre-commit-fake"
  cat > "$fake" <<'EOF'
is_ipc_exception() {
    local base
    base=$(basename "$1")
    case "$base" in
        scratchpad.md|jamais-vu-ici.md) return 0 ;;
    esac
    [[ "$1" == *"/skills/"*"/SKILL.md" ]] && return 0
    [[ "$1" == *"aucun-repertoire-de-ce-nom/"* ]] && return 0
    return 1
}
EOF
  run dead_patterns "$fake"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "base	jamais-vu-ici.md"
  printf '%s\n' "$output" | grep -qxF "path	*aucun-repertoire-de-ce-nom/*"
  # ...et les clauses vivantes du meme fichier ne sont PAS signalees : un detecteur qui accuse tout
  # ne mesure rien.
  # `scratchpad.md`, une clause que le hook porte et qui VIT (2 fichiers) — pas `*-handoff.md`, dont
  # le depot ne porte AUCUN fichier : une fixture qui le donnerait en exemple de clause vivante
  # accuserait a tort un detecteur qui a raison de le signaler, et une negation `! …` non terminale
  # la laisserait passer verte.
  printf '%s\n' "$output" | refute_out 'scratchpad'
  printf '%s\n' "$output" | refute_out 'SKILL\.md'
}

@test "une clause a deux branches ||  est lue comme DEUX clauses" {
  # Une forme `[[ A || B ]]` peut porter deux branches mortes. Lire la ligne comme un seul motif
  # laisserait passer la branche non testee.
  local fake="$BATS_TEST_TMPDIR/pre-commit-or"
  cat > "$fake" <<'EOF'
is_ipc_exception() {
    local base
    base=$(basename "$1")
    case "$base" in
        *-handoff.md) return 0 ;;
    esac
    [[ "$1" == *"/skills/"* || "$1" == *"branche-morte/"* ]] && return 0
    return 1
}
EOF
  run extract_patterns "$fake"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "path	*/skills/*"
  printf '%s\n' "$output" | grep -qxF "path	*branche-morte/*"

  run dead_patterns "$fake"
  printf '%s\n' "$output" | grep -qxF "path	*branche-morte/*"
  printf '%s\n' "$output" | refute_out 'skills'
}
