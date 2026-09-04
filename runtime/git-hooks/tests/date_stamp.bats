#!/usr/bin/env bats
# SOURCE: runtime/git-hooks/tests/date_stamp.bats
# AUTHOR: drdree
# STARDATE: 2026-08-14
# STATUS: bats tests for pre-commit pass 1 — 6-116, le tampon de date ne publie plus le hors-index
#
# CE QUE CE HOOK NE DOIT PAS FAIRE. La passe 1 met a jour un tampon de date. Un `sed -i` sur le
# fichier de l'ARBRE DE TRAVAIL suivi de `git add "$file"` embarquerait TOUT le contenu courant —
# `git add` ne restage pas la ligne de date, il remplace l'entree d'index — et un fichier
# partiellement stage verrait son travail non stage partir dans le commit, en silence.
#
# Ce serait alterer la selection explicite de l'humain : pas un tampon de metadonnee, publier du
# travail incomplet en croyant tamponner une date.
#
# Git REEL de bout en bout : ce qui est mesure est le CONTENU DU COMMIT, jamais le texte du hook.

setup() {
  HOOKS_SRC="$BATS_TEST_DIRNAME/.."
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git init -q --initial-branch main "$REPO"
  git -C "$REPO" config user.email a@b.c
  git -C "$REPO" config user.name a

  cp "$HOOKS_SRC/pre-commit" "$REPO/.git/hooks/pre-commit"
  [[ -f "$HOOKS_SRC/hook-config.sh" ]] && cp "$HOOKS_SRC/hook-config.sh" "$REPO/.git/hooks/hook-config.sh"
  chmod 0755 "$REPO/.git/hooks/pre-commit"

  HIER="2026-01-01"
  AUJOURDHUI="$(date '+%Y-%m-%d')"
}

# Un .md conforme GO-7 (la passe 2 refuse un fichier sans en-tete declaratif).
doc_with_date() {
  local path="$1" date="$2" corps="${3:-}"
  mkdir -p "$(dirname "$REPO/$path")"
  {
    printf '# Titre\n\n'
    printf '**Date** : %s\n' "$date"
    printf '**Dernière révision** : %s\n' "$date"
    printf '**Statut** : actif\n\n'
    printf 'corps stable\n'
    # `|| true` : dernier statut du bloc, et un corps vide rendrait 1 sous le `set -e` de bats —
    # la fonction echouerait alors pour la mise en scene, pas pour ce qu'elle mesure.
    { [[ -n "$corps" ]] && printf '%s\n' "$corps"; } || true
  } > "$REPO/$path"
}

@test "6-116: le travail laisse HORS INDEX ne part pas dans le commit" {
  # L'humain stage une version, puis continue a travailler sans stager. Le tampon de date ne doit
  # embarquer ni cette suite, ni rien d'autre qu'il n'a pas choisi.
  doc_with_date "doc.md" "$HIER"
  git -C "$REPO" add doc.md
  git -C "$REPO" commit -q -m base

  doc_with_date "doc.md" "$HIER" "LIGNE-STAGEE"
  git -C "$REPO" add doc.md
  doc_with_date "doc.md" "$HIER" "LIGNE-STAGEE
TRAVAIL-NON-STAGE"

  run git -C "$REPO" commit -q -m "tampon"
  [ "$status" -eq 0 ]

  committe="$(git -C "$REPO" show HEAD:doc.md)"
  [[ "$committe" == *LIGNE-STAGEE* ]]
  [[ "$committe" != *TRAVAIL-NON-STAGE* ]]
  # Et la date A BIEN ete tamponnee — sinon le test passerait en cassant la fonction.
  [[ "$committe" == *"**Dernière révision** : $AUJOURDHUI"* ]]
}

@test "6-116: le travail non stage RESTE dans l'arbre de travail" {
  # Corollaire : ne pas publier ne veut pas dire detruire. Le hook ne doit rien retirer a l'humain.
  doc_with_date "doc.md" "$HIER"
  git -C "$REPO" add doc.md
  git -C "$REPO" commit -q -m base

  doc_with_date "doc.md" "$HIER"
  git -C "$REPO" add doc.md
  doc_with_date "doc.md" "$HIER" "TRAVAIL-NON-STAGE"

  run git -C "$REPO" commit -q -m "tampon"
  [ "$status" -eq 0 ]

  grep -q "TRAVAIL-NON-STAGE" "$REPO/doc.md"
}

@test "TEMOIN 6-116: sur un fichier ENTIEREMENT stage, la date est posee des DEUX cotes" {
  # Sans ce temoin, un correctif qui ne toucherait plus rien du tout passerait le premier test.
  # Le cas nominal doit rester propre : pas de derive entre l'index et l'arbre de travail.
  doc_with_date "doc.md" "$HIER"
  git -C "$REPO" add doc.md
  git -C "$REPO" commit -q -m base

  doc_with_date "doc.md" "$HIER" "CHANGEMENT"
  git -C "$REPO" add doc.md

  run git -C "$REPO" commit -q -m "tampon"
  [ "$status" -eq 0 ]

  [[ "$(git -C "$REPO" show HEAD:doc.md)" == *"**Dernière révision** : $AUJOURDHUI"* ]]
  grep -q "\*\*Dernière révision\*\* : $AUJOURDHUI" "$REPO/doc.md"
  # Rien ne reste a stager : l'arbre de travail et l'index disent la meme chose.
  run git -C "$REPO" status --porcelain
  [ -z "$output" ]
}

@test "6-116: la derniere ligne vide SURVIT a la reecriture du blob" {
  # `$(git show :f)` mange les sauts de ligne finaux : reecrire le blob par substitution de commande
  # tronquerait CHAQUE fichier d'une ligne. Le piege est invisible tant qu'on ne le mesure pas.
  doc_with_date "doc.md" "$HIER"
  printf '\n\n' >> "$REPO/doc.md"
  git -C "$REPO" add doc.md
  git -C "$REPO" commit -q -m base

  doc_with_date "doc.md" "$HIER" "CHANGEMENT"
  printf '\n\n' >> "$REPO/doc.md"
  attendu="$(wc -c < "$REPO/doc.md")"
  git -C "$REPO" add doc.md

  run git -C "$REPO" commit -q -m "tampon"
  [ "$status" -eq 0 ]

  # Meme taille, a la difference de longueur de la date pres (ici nulle : deux dates ISO).
  obtenu="$(git -C "$REPO" show HEAD:doc.md | wc -c)"
  [ "$obtenu" -eq "$attendu" ]
}

@test "6-116: le tampon STARDATE ne publie pas davantage le hors-index" {
  # La fiche note que le chemin ISO repete la sequence du chemin stardate. Les deux se mesurent.
  mkdir -p "$REPO/runtime"
  # ⚠ LA MISE EN SCENE POSE L'IDENTITE DE L'APP, celle que `hook-config.sh` lit vraiment (6-117) —
  # pas un marqueur (`fleet/fleet-env.sh`) qui N'EXISTE NULLE PART dans le depot reel : ce serait
  # exercer la branche stardate par un monde qui ne se produit jamais, un vert sur une fixture
  # impossible.
  # Un `.exs` n'est pas soumis a l'en-tete de la passe 2 : rien a mettre en scene de ce cote.
  printf 'def project do\n  [\n    app: :lcars_fleet\n  ]\nend\n' > "$REPO/runtime/mix.exs"
  git -C "$REPO" add runtime/mix.exs
  git -C "$REPO" commit -q -m "repo lcars"

  # ⚠ LA VIEILLE STARDATE PASSE PAR UNE VARIABLE, ET C'EST LOAD-BEARING. Ce fichier de test est
  # lui-meme commite dans LCARS, et la branche stardate du hook est VIVANTE (6-117) : ecrite en
  # clair, une vieille stardate se ferait tamponner a la date du jour DANS LA FIXTURE, le temoin
  # deviendrait egal a l'attendu et le test passerait sans rien mesurer. Le motif du hook exige des
  # chiffres (`[0-9]{4}\.[0-9]{3}`), donc `%s` lui echappe — y compris dans ce commentaire, qu'un
  # exemple ecrit en clair ferait reecrire au prochain commit.
  local vieux="2020.001"
  mkdir -p "$REPO/bin"
  printf '#!/bin/bash\n# SOURCE: bin/x.sh\n# STARDATE: %s\n# STATUS: actif\necho stable\n' \
    "$vieux" > "$REPO/bin/x.sh"
  git -C "$REPO" add bin/x.sh
  git -C "$REPO" commit -q -m base

  printf '#!/bin/bash\n# SOURCE: bin/x.sh\n# STARDATE: %s\n# STATUS: actif\necho stable\necho STAGE\n' \
    "$vieux" > "$REPO/bin/x.sh"
  git -C "$REPO" add bin/x.sh
  printf '#!/bin/bash\n# SOURCE: bin/x.sh\n# STARDATE: %s\n# STATUS: actif\necho stable\necho STAGE\necho NON-STAGE\n' \
    "$vieux" > "$REPO/bin/x.sh"

  run git -C "$REPO" commit -q -m "tampon"
  [ "$status" -eq 0 ]

  committe="$(git -C "$REPO" show HEAD:bin/x.sh)"
  [[ "$committe" == *"echo STAGE"* ]]
  [[ "$committe" != *"NON-STAGE"* ]]
  [[ "$committe" == *"STARDATE: $(date '+%Y.%j')"* ]]
}
