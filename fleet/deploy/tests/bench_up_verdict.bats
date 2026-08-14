#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/bench_up_verdict.bats
# AUTHOR: drdree
# STARDATE: 2026-08-14
# STATUS: bats tests for bench-up.sh — 6-133, le verdict final et son code de retour
#
# CE QUE FAISAIT CE SCRIPT. Il construisait un `RUNNER_STATE` riche — « ABSENT », « BLOCAGE, pas
# degradation », « enregistrement rate » — puis imprimait `banc PRET` et rendait 0. Le DIAGNOSTIC
# etait deja juste ; le VERDICT disait le contraire, et c'est le verdict qu'on lit. Une automatisation
# acceptait donc un banc incapable de jouer le moindre workflow CI, et un test d'integration restait
# `pending` au lieu de reveler que son harnais etait incomplet.
#
# ⚠ POURQUOI CE HARNAIS EST PLUS LOURD QUE SON VOISIN. `bench_up_seed.bats` laisse volontairement le
# script mourir dans l'amorçage forge : ce qu'il mesure (l'ordre create→cp→start) est atteint avant.
# Le verdict, lui, est la DERNIERE ligne — il faut donc traverser tout le script. On copie
# `bench-up.sh` dans un faux arbre pour que ses voisins appeles par chemin (`bench-forge-bootstrap.sh`,
# `bench-runner.sh`) soient les notres : `HERE` derive de `BASH_SOURCE`, et `REPO_ROOT` de `HERE`.

setup() {
  ROOT="$BATS_TEST_TMPDIR/fake"
  DEV="$ROOT/fleet/deploy/docker/dev"
  mkdir -p "$DEV" "$ROOT/fleet/deploy/deps" "$ROOT/fleet/deploy/lib"
  cp "$BATS_TEST_DIRNAME/../docker/dev/bench-up.sh" "$DEV/bench-up.sh"
  SRC="$DEV/bench-up.sh"

  # Les composes ne sont jamais lus : docker est une doublure, et `-f <chemin>` lui est opaque.
  : > "$ROOT/fleet/deploy/deps/.keep"
  printf '#!/usr/bin/env bash\nPROV_CLAUDE_SEED=/local/claude\n' > "$ROOT/fleet/deploy/lib/provision-lib.sh"

  # L'amorçage forge : il REUSSIT et pose le master token la ou le script ira le chercher, parce que
  # c'est l'etat nominal — ce que ces tests font varier est le RUNNER, rien d'autre.
  cat > "$DEV/bench-forge-bootstrap.sh" <<'FAKE'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in --tofu-dir) printf 'MASTER\n' > "$2/.master-token"; shift 2 ;; *) shift ;; esac
done
exit 0
FAKE
  chmod 0755 "$DEV/bench-forge-bootstrap.sh"

  RUNNER_RC="$BATS_TEST_TMPDIR/runner.rc"
  echo 0 > "$RUNNER_RC"
  cat > "$DEV/bench-runner.sh" <<FAKE
#!/usr/bin/env bash
exit "\$(cat "$RUNNER_RC")"
FAKE
  chmod 0755 "$DEV/bench-runner.sh"

  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"

  # ⚠ SEULE L'IMAGE DE BUILD VARIE. Le script fait DEUX `image inspect` : l'image RUNTIME, tres tot
  # (il meurt si elle manque), et `lcars-build:<tag>` qui decide du label elixir. Une doublure qui
  # les traite pareil fait mourir le script bien AVANT le verdict — et le test mesure alors une
  # autre panne, avec un autre code, en croyant mesurer la sienne.
  BUILD_IMG_RC="$BATS_TEST_TMPDIR/build_img.rc"
  echo 0 > "$BUILD_IMG_RC"
  # ⚠ La doublure decide sur l'ARGV COMPLET, jamais sur `$1 $2` : les `exec` portent le nom de la
  # boite en second argument (`exec <box> cat …`), donc un motif sur les deux premiers mots rate
  # tous les `exec` — et le script meurt sur « token systeme absent » avant d'atteindre le verdict,
  # c'est-a-dire avant ce que ces tests mesurent.
  cat > "$BINDIR/dockerstub" <<FAKE
#!/usr/bin/env bash
argv="\$*"
case "\$1 \$2" in
  "run --rm")      echo flux-ok; exit 0 ;;
  "ps -a")         exit 0 ;;
  "inspect -f")    echo healthy; exit 0 ;;
  "image inspect")
     case "\$3" in
       lcars-build:*) exit "\$(cat "$BUILD_IMG_RC")" ;;
       *)             exit 0 ;;
     esac ;;
esac
case "\$argv" in
  *system.gitea_token*)   echo TOKEN-SYSTEME ;;
  *"*.gitea_token"*)      echo 9 ;;
  *credentials.json*)     echo oui ;;
esac
exit 0
FAKE
  chmod 0755 "$BINDIR/dockerstub"

  # La forge repond, et l'endpoint des runners rend une liste NON VIDE : l'etat nominal.
  RUNNERS_JSON="$BATS_TEST_TMPDIR/runners.json"
  printf '{"runners":[{"id":1}]}\n' > "$RUNNERS_JSON"
  cat > "$BINDIR/curl" <<FAKE
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *actions/runners) cat "$RUNNERS_JSON"; exit 0 ;;
    *api/v1/user)     printf '{"is_admin":true}\n'; exit 0 ;;
  esac
done
exit 0
FAKE
  chmod 0755 "$BINDIR/curl"

  export PATH="$BINDIR:$PATH"
  export DOCKER_BIN=dockerstub
  export DOCKER_HOST=unix:///dev/null
}

run_bench() {
  run bash "$SRC" --project bt --no-creds --no-human-admin --image lcars-fleet:9 "$@"
}

@test "TEMOIN 6-133: runner demande ET servi → « banc PRET », exit 0" {
  # Sans ce temoin, un correctif qui refuserait TOUJOURS passerait les tests d'echec (P-40).
  run_bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"banc PRET"* ]]
  [[ "$output" != *"PAS PRET"* ]]
}

@test "6-133: pas d'image pour le label elixir → PAS PRET, exit 6" {
  echo 1 > "$BUILD_IMG_RC"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"PAS PRET"* ]]
}

@test "6-133: bench-runner.sh en echec → PAS PRET, exit 6" {
  echo 1 > "$RUNNER_RC"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"PAS PRET"* ]]
}

@test "6-133: runner demarre mais AUCUN vu par la forge → PAS PRET, exit 6" {
  # L'etat le plus traitre : le processus tourne, et la forge ne le connait pas.
  printf '{"runners":[]}\n' > "$RUNNERS_JSON"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"PAS PRET"* ]]
}

@test "6-133bis: la branche « pas d'image » DIT quelque chose — elle mourait en 127, muette" {
  # TROUVE EN INSTRUMENTANT, et la fiche ne le voit pas. Son message contenait `ci: required` entre
  # BACKTICKS dans une chaine a guillemets DOUBLES : bash y lisait une substitution de commande,
  # executait `ci:`, echouait, et `set -euo pipefail` tuait le script — exit 127, pour seul message
  # « ci:: command not found ». Cette branche ne remplissait donc pas RUNNER_STATE : elle mourait
  # AVANT de l'ecrire. Le test epingle le DIAGNOSTIC, pas le code : un message reecrit sans
  # echappement ramenerait la panne en silence.
  echo 1 > "$BUILD_IMG_RC"
  run_bench
  [ "$status" -ne 127 ]
  [[ "$output" != *"command not found"* ]]
  [[ "$output" == *"lcars-build"* ]]
  [[ "$output" == *"ci: required"* ]]
}

@test "6-133bis: la branche « pas de master token » non plus" {
  # Meme defaut, meme ligne, deuxieme occurrence : la corriger a un seul endroit l'aurait laissee.
  rm -f "$DEV/bench-forge-bootstrap.sh"
  cat > "$DEV/bench-forge-bootstrap.sh" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  chmod 0755 "$DEV/bench-forge-bootstrap.sh"

  run_bench
  [ "$status" -ne 127 ]
  [[ "$output" != *"command not found"* ]]
  [[ "$output" == *"master token"* ]]
}

@test "6-133: le bloc de details est imprime AVANT le refus — on repare avec, pas sans" {
  echo 1 > "$BUILD_IMG_RC"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"runner    :"* ]]
  [[ "$output" == *"destruire :"* ]]
}

@test "6-133: --no-runner porte son PROPRE verdict, jamais celui du banc complet" {
  # Un mode degrade CHOISI et un mode degrade SUBI ne se disent pas du meme mot : celui qui lit un
  # journal doit distinguer « je n'ai pas voulu de CI » de « la CI n'a pas pu se poser ».
  echo 1 > "$BUILD_IMG_RC"
  run_bench --no-runner
  [ "$status" -eq 0 ]
  [[ "$output" == *"PRET_SANS_CI"* ]]
  [[ "$output" != *"PAS PRET"* ]]
}
