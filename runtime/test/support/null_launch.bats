#!/usr/bin/env bats
# SOURCE: runtime/test/support/null_launch.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-11
# STATUS: la preuve de la frontiere N0/N1 — le gate echoue si le contrat bouge sans que le double suive
#
# Ce que ce fichier epingle : la frontiere vendor n'est pas une intention verifiee a la lecture. Un
# launcher qui ne lance AUCUN vendor honore le meme contrat qu'un launcher vendor, donc le contrat
# est bien N0 — et le troisieme test le rend mecanique : il DERIVE la liste des variables requises
# depuis `bin/claude_launch.sh` et exige que le double les porte aussi.

setup() {
  NULL="${BATS_TEST_DIRNAME}/null_launch.sh"
  CLAUDE="${BATS_TEST_DIRNAME}/../../bin/claude_launch.sh"
  export LCARS_POD_SESSION_ID="00000000-0000-4000-8000-000000000001"
  export LCARS_POD_SESSION_NAME_PREFIX="lcars-pod"
}

@test "contrat honore : argv + env requis -> transcript deterministe" {
  run env LCARS_POD_RESUME=0 bash "$NULL" engineer pod-42 /tmp/pods/pod-42
  [ "$status" -eq 0 ]
  [[ "$output" == *"role=engineer"* ]]
  [[ "$output" == *"pod_id=pod-42"* ]]
  [[ "$output" == *"mode=create"* ]]
  [[ "$output" == *"vendor=none"* ]]
  # Le pod_dir sort en NOM DE BASE : un transcript qui porte le home de qui l'a joue n'est pas
  # rejouable d'une machine a l'autre.
  [[ "$output" == *"pod_dir=pod-42"* ]]
  [[ "$output" != *"/tmp/pods"* ]]
}

@test "deterministe : deux executions identiques rendent le MEME octet" {
  run env LCARS_POD_RESUME=1 bash "$NULL" reviewer pod-7 /tmp/pods/pod-7
  first="$output"
  run env LCARS_POD_RESUME=1 bash "$NULL" reviewer pod-7 /tmp/pods/pod-7
  [ "$output" = "$first" ]
  [[ "$output" == *"mode=resume"* ]]
}

@test "LE VERROU : toute variable requise par le launcher vendor est requise ici aussi" {
  # Derivee du VRAI launcher, pas recopiee : si `claude_launch.sh` gagne un `${LCARS_*:?}`, ce test
  # tombe tant que le double ne le porte pas. C'est ce qui fait de la frontiere une propriete
  # verifiee a chaque run plutot qu'une phrase dans un moduledoc.
  required="$(grep -o '\${LCARS_[A-Z_]*:?' "$CLAUDE" | sed 's/.*{//;s/:?//' | sort -u)"
  [ -n "$required" ]
  for var in $required; do
    grep -q "\${$var:?" "$NULL" || {
      echo "le launcher vendor exige $var, le double ne l'exige pas" >&3
      false
    }
  done
}

@test "une variable requise absente est un ECHEC, pas un defaut comble" {
  run env -u LCARS_POD_SESSION_ID LCARS_POD_RESUME=0 bash "$NULL" engineer pod-1 /tmp/pods/pod-1
  [ "$status" -ne 0 ]
}

@test "argv incomplet -> refus" {
  run bash "$NULL" engineer pod-1
  [ "$status" -eq 64 ]
}

@test "un LCARS_POD_RESUME hors vocabulaire est refuse, jamais interprete" {
  run env LCARS_POD_RESUME=2 bash "$NULL" engineer pod-1 /tmp/pods/pod-1
  [ "$status" -eq 64 ]
}
