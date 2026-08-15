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

  # La doublure PARLE quand elle refuse — c'est la matiere du test « le refus remonte ». Un faux
  # sous-script muet ne pourrait pas distinguer « bench-up relaie » de « bench-up invente ».
  RUNNER_RC="$BATS_TEST_TMPDIR/runner.rc"
  echo 0 > "$RUNNER_RC"
  cat > "$DEV/bench-runner.sh" <<FAKE
#!/usr/bin/env bash
rc="\$(cat "$RUNNER_RC")"
[[ "\$rc" -eq 0 ]] || echo "REFUS-TEMOIN: image(s) introuvable(s) sur ce daemon: alpine:3.20" >&2
exit "\$rc"
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
  # La REVISION que l'image porte dans son label OCI. L'etat nominal est une image estampillee ; les
  # tests qui mesurent l'absence l'effacent. Sert la forme `image inspect -f <fmt> <image>`, qu'il
  # faut distinguer du `image inspect <image>` d'existence — meme deux premiers mots, autre question.
  IMAGE_REV_OUT="$BATS_TEST_TMPDIR/image_rev.out"
  echo "deadbeef1" > "$IMAGE_REV_OUT"
  # Le token OPERATEUR (`~/.gitea_token` du worker), exige par le verdict depuis 2026-08-15 : il peut
  # etre saute par les DEUX passes d'amorcage sans que rien ne le dise, donc le verdict le mesure.
  # Etat nominal « oui » ; le temoin de son absence l'ecrase.
  OP_TOKEN_OUT="$BATS_TEST_TMPDIR/op_token.out"
  echo "oui" > "$OP_TOKEN_OUT"
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
       -f)            cat "$IMAGE_REV_OUT"; exit 0 ;;
       lcars-build:*) exit "\$(cat "$BUILD_IMG_RC")" ;;
       *)             exit 0 ;;
     esac ;;
esac
case "\$argv" in
  *system.gitea_token*)   echo TOKEN-SYSTEME ;;
  *"*.gitea_token"*)      echo 9 ;;
  # Le token OPERATEUR, dans le home du worker — distinct du glob /home/private ci-dessus, qui vise
  # les tokens de ROLE. Deux fichiers homonymes, deux rails : celui-ci est la voie de la boite vers
  # la forge, et `bench-up.sh` l'EXIGE depuis 2026-08-15 (il pouvait etre saute par les deux passes).
  *"~/.gitea_token"*)     cat "$OP_TOKEN_OUT" ;;
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

@test "token operateur absent apres DEUX passes → refus, exit 6, et la CAUSE est nommee" {
  # Le geste que ce temoin garde : `bench-forge-bootstrap` ne peut pas poser `~/.gitea_token` a la
  # passe 1 — le worker vient de la FORGE et n'existe en unix qu'apres la relance que cette passe
  # demande. Il saute donc, en le disant, et la passe 2 pose. Mesure du 2026-08-15 : avant ce
  # saut, la passe 1 MOURAIT sur « unable to find user lcars » et le banc ne montait pas.
  #
  # Ce qui rend ce saut sur n'est PAS son message, c'est cette exigence : deux passes qui sautent
  # toutes les deux donneraient un banc vert dont la boite ne parle pas a la forge, sans un mot.
  # Le refus doit nommer la CAUSE (le worker manque) et pas seulement le symptome (le fichier manque).
  echo "non" > "$OP_TOKEN_OUT"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"token operateur absent"* ]]
  [[ "$output" == *"convergeur"* ]]
  [[ "$output" != *"banc PRET"* ]]
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

# 2026-08-14 — LE SEUL ECHEC QUE CE SCRIPT NE SAVAIT PAS EXPLIQUER ETAIT CELUI QU'IL FAISAIT TAIRE.
# L'appel a `bench-runner.sh` partait en `>/dev/null 2>&1`, donc le verdict se reduisait a « en echec
# (rejouable : bench-runner.sh --help) ». Le sous-script, lui, avait dit exactement quoi reparer —
# et le rejouer a la main demande de reconstruire ses six arguments, dont un token qui vit dans un
# `mktemp` que rien ne documente. Le test epingle la PROPAGATION, pas la formulation du relais.
@test "6-14: le refus de bench-runner.sh remonte MOT POUR MOT dans le verdict" {
  echo 1 > "$RUNNER_RC"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"REFUS-TEMOIN"* ]]
  [[ "$output" == *"alpine:3.20"* ]]
}

@test "6-14: TEMOIN — un runner qui REUSSIT ne deverse pas le journal du sous-script" {
  # Sans ce temoin, un correctif qui imprimerait la sortie dans TOUS les cas passerait le test
  # ci-dessus. Le silence au succes est la moitie du contrat : un banc vert n'a rien a raconter.
  run_bench
  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUS-TEMOIN"* ]]
}

# 2026-08-14 — LE BANC DEPLOYAIT UNE IMAGE MUETTE SUR SON PROPRE CODE, ET NE LE VOYAIT PAS. Mesure :
# une image batie a la main (docker build sans --build-arg GIT_SHA) a produit un banc entierement
# vert dont `/api/version` rendait `sha: "unknown"`. Aucun verdict rendu par ce banc n'etait donc
# attribuable a un commit — la seule chose qu'on lui demande. Le TAG ne prouve rien : c'est un nom,
# il s'ecrit a la main, et c'est precisement ce que j'avais fait.
@test "6-14: une image sans revision est ANNONCEE inconnue dans le bloc de verdict" {
  : > "$IMAGE_REV_OUT"
  run_bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"revision"* ]]
  [[ "$output" == *"INCONNUE"* ]]
}

@test "6-14: le litteral « unknown » du Dockerfile compte comme absence, pas comme revision" {
  # `ARG GIT_SHA=unknown` : une image non estampillee porte le mot, pas le vide. Un test qui ne
  # verifierait que la chaine vide laisserait passer le cas REEL, qui est celui-la.
  echo "unknown" > "$IMAGE_REV_OUT"
  run_bench
  [[ "$output" == *"INCONNUE"* ]]
}

@test "6-14: TEMOIN — une image estampillee montre SA revision, pas un avertissement" {
  run_bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"deadbeef1"* ]]
  [[ "$output" != *"INCONNUE"* ]]
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
