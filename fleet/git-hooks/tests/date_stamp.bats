#!/usr/bin/env bats
# SOURCE: fleet/git-hooks/tests/date_stamp.bats
# AUTHOR: drdree
# STARDATE: 2026-08-14
# STATUS: bats tests for pre-commit pass 1 — 6-116, le tampon de date ne publie plus le hors-index
#
# CE QUE CE HOOK FAISAIT. La passe 1 met a jour un tampon de date. Elle le faisait par `sed -i` sur
# le fichier de l'ARBRE DE TRAVAIL, puis `git add "$file"` — et `git add` ne restage pas la ligne de
# date, il remplace l'entree d'index par TOUT le contenu courant. Un fichier partiellement stage qui
# portait aussi du travail non stage voyait donc ce travail partir dans le commit, en silence.
#
# Le hook alterait la selection explicite de l'humain. Ce n'est pas un tampon de metadonnee : c'est
# publier du travail incomplet en croyant tamponner une date.
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
  mkdir -p "$REPO/fleet"
  # `hook-config.sh` decide du format de date par la PRESENCE de ce fichier. Il doit lui-meme
  # passer la passe 2, sinon le commit de mise en scene echoue pour une autre raison que la sienne.
  printf '#!/bin/bash\n# SOURCE: fleet/fleet-env.sh\n# AUTHOR: test\n# STARDATE: 2020.001\n# STATUS: actif\n' \
    > "$REPO/fleet/fleet-env.sh"
  git -C "$REPO" add fleet/fleet-env.sh
  git -C "$REPO" commit -q -m "repo lcars"

  mkdir -p "$REPO/bin"
  printf '#!/bin/bash\n# SOURCE: bin/x.sh\n# STARDATE: 2020.001\n# STATUS: actif\necho stable\n' \
    > "$REPO/bin/x.sh"
  git -C "$REPO" add bin/x.sh
  git -C "$REPO" commit -q -m base

  printf '#!/bin/bash\n# SOURCE: bin/x.sh\n# STARDATE: 2020.001\n# STATUS: actif\necho stable\necho STAGE\n' \
    > "$REPO/bin/x.sh"
  git -C "$REPO" add bin/x.sh
  printf '#!/bin/bash\n# SOURCE: bin/x.sh\n# STARDATE: 2020.001\n# STATUS: actif\necho stable\necho STAGE\necho NON-STAGE\n' \
    > "$REPO/bin/x.sh"

  run git -C "$REPO" commit -q -m "tampon"
  [ "$status" -eq 0 ]

  committe="$(git -C "$REPO" show HEAD:bin/x.sh)"
  [[ "$committe" == *"echo STAGE"* ]]
  [[ "$committe" != *"NON-STAGE"* ]]
  [[ "$committe" == *"STARDATE: $(date '+%Y.%j')"* ]]
}
