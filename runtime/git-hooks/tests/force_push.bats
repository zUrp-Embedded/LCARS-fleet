#!/usr/bin/env bats
# SOURCE: runtime/git-hooks/tests/force_push.bats
# AUTHOR: drdree
# STARDATE: 2026-08-14
# STATUS: bats tests for pre-push — 6-073, la face OPS n'etait pas protegee du force-push
#
# CE QUE CE MUR DOIT COUVRIR (6-073). Un `PROTECTED_BRANCH="main"` unique, avec `continue` sur tout
# le reste AVANT meme le test d'ancestralite, laisserait la face OPS nue.
#
# `work/ops` n'est pas une branche de travail ordinaire dans ce systeme : c'est le support de
# l'AUDITABILITE. Y vivent les briefs materialises et epingles, les attestations de provenance
# in-toto, les verdicts de gate, les rapports de conflit. Toute cette chaine de preuve repose sur des
# pointeurs `<ref> @ <sha>` qui designent des commits. Un force-push y fait disparaitre les objets
# vises et les preuves pendent dans le vide — SANS qu'aucune erreur ne se leve, contrairement a un
# `main` reecrit qu'on remarque au premier `pull`.
#
# GIT REEL DE BOUT EN BOUT : ce qui est mesure est le code de retour de `git push` contre un depot
# distant, jamais le texte du hook.

setup() {
  HOOKS_SRC="$BATS_TEST_DIRNAME/.."
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  WORK="$BATS_TEST_TMPDIR/work"

  git init -q --bare --initial-branch main "$REMOTE"
  git init -q --initial-branch main "$WORK"
  git -C "$WORK" config user.email a@b.c
  git -C "$WORK" config user.name a
  git -C "$WORK" remote add origin "$REMOTE"

  cp "$HOOKS_SRC/pre-push" "$WORK/.git/hooks/pre-push"
  cp "$HOOKS_SRC/hook-config.sh" "$WORK/.git/hooks/hook-config.sh"
  chmod +x "$WORK/.git/hooks/pre-push"
}

# Marque le depot de travail comme LCARS (l'identite lue par `hook-config.sh`).
as_lcars() {
  mkdir -p "$WORK/runtime"
  printf 'def project do\n  [\n    app: :lcars_fleet\n  ]\nend\n' > "$WORK/runtime/mix.exs"
  git -C "$WORK" add runtime/mix.exs
  git -C "$WORK" commit -qm "identite"
}

# Deux commits sur `$1`, pousses ; puis l'historique est REECRIT localement (amend).
publish_then_rewrite() {
  local branch="$1"
  git -C "$WORK" checkout -q -B "$branch"
  echo un > "$WORK/f.txt"
  git -C "$WORK" add f.txt
  git -C "$WORK" commit -qm "un"
  git -C "$WORK" push -q origin "$branch"
  echo deux > "$WORK/f.txt"
  git -C "$WORK" commit -qam "deux reecrit" --amend
}

@test "6-073: force-push sur work/ops est REFUSE (depot LCARS)" {
  as_lcars
  publish_then_rewrite work/ops

  run git -C "$WORK" push --force origin work/ops
  [ "$status" -ne 0 ]
  [[ "$output" == *"Force-push blocked on 'work/ops'"* ]]
}

@test "6-073: TEMOIN — main reste protege, la regression n'a rien casse" {
  as_lcars
  publish_then_rewrite main

  run git -C "$WORK" push --force origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Force-push blocked on 'main'"* ]]
}

@test "6-073: TEMOIN — une branche de travail ordinaire reste FORCABLE" {
  # La garde doit se prouver sur ce qu'elle LAISSE PASSER : le hook annonce lui-meme
  # « --force-with-lease on a feature branch is allowed ». Un mur qui bloque tout tient les deux
  # tests ci-dessus sans rien garder de vrai.
  as_lcars
  publish_then_rewrite chantier/quelconque

  run git -C "$WORK" push --force origin chantier/quelconque
  [ "$status" -eq 0 ]
}

@test "6-073: un push EN AVANT sur work/ops passe — seule la REECRITURE est bloquee" {
  # Le mur teste l'ancestralite, pas le drapeau `--force`. Un `--force` sur une avance normale ne
  # reecrit rien et ne doit pas etre refuse, sinon la protection devient un interdit de pousser.
  as_lcars
  git -C "$WORK" checkout -q -B work/ops
  echo un > "$WORK/f.txt"
  git -C "$WORK" add f.txt
  git -C "$WORK" commit -qm "un"
  git -C "$WORK" push -q origin work/ops
  echo deux >> "$WORK/f.txt"
  git -C "$WORK" commit -qam "deux, en avant"

  run git -C "$WORK" push --force origin work/ops
  [ "$status" -eq 0 ]
}

@test "6-073: dans un depot PROJET, la face protegee est ops, pas work/ops" {
  # Le nom de la face depend du depot (cf. `Fleet.Layout`) : un projet onboarde porte les branches
  # orphelines `ops`/`workshop`. Sans le passage par `hook-config.sh`, une seule des deux
  # conventions aurait ete couverte — et c'est l'autre qui aurait ete nue.
  publish_then_rewrite ops

  run git -C "$WORK" push --force origin ops
  [ "$status" -ne 0 ]
  [[ "$output" == *"Force-push blocked on 'ops'"* ]]
}

@test "6-073: dans un depot PROJET, workshop est protege aussi" {
  publish_then_rewrite workshop

  run git -C "$WORK" push --force origin workshop
  [ "$status" -ne 0 ]
}

@test "6-073: TEMOIN CROISE — work/ops n est PAS protege dans un depot projet" {
  # L'inverse du cas LCARS, et il vaut d'etre epingle : une liste unique couvrant les deux
  # conventions protegerait dans chaque depot un nom qui n'y designe rien. C'est la meme faute que
  # les exemptions GO-7 mortes — une clause qui ne matche jamais se lit comme une couverture.
  publish_then_rewrite work/ops

  run git -C "$WORK" push --force origin work/ops
  [ "$status" -eq 0 ]
}
