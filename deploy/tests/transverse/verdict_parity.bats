#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/transverse/verdict_parity.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests — le protocole du produit et la lib de l'installeur rendent les MEMES codes de verdict

load ../refute

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  INSTALLER="$REPO/deploy/lib/provision-lib.sh"
  PRODUCT="$REPO/runtime/services/lib/module-protocol.sh"
  [ -f "$INSTALLER" ]
  [ -f "$PRODUCT" ]
}

# verdict <lib> <verbe> <failed> <drift> -> le code rendu
verdict_installer() { bash -c "set +e; . '$INSTALLER' >/dev/null 2>&1; PROV_FAILED=$2; PROV_DRIFT=$3; verdict_$1" 2>/dev/null; echo $?; }
verdict_product()   { bash -c "set +e; . '$PRODUCT' >/dev/null 2>&1; LCARS_FAILED=$2; LCARS_DRIFT=$3; verdict_$1" 2>/dev/null; echo $?; }

@test "apply : 0 converge · 2 drift · 1 echec — identiques des deux cotes, l'echec gagne sur le drift" {
  local f d i p
  for f in 0 1; do for d in 0 1; do
    i="$(verdict_installer apply $f $d)"; p="$(verdict_product apply $f $d)"
    [ "$i" = "$p" ] || { echo "apply failed=$f drift=$d : installeur=$i produit=$p" >&2; return 1; }
  done; done
  [ "$(verdict_product apply 0 0)" = 0 ]
  [ "$(verdict_product apply 0 1)" = 2 ]
  [ "$(verdict_product apply 1 0)" = 1 ]
  [ "$(verdict_product apply 1 1)" = 1 ]
}

@test "check : 0 conforme · 1 drift · 2 echec — identiques des deux cotes, l'echec gagne sur le drift" {
  local f d i p
  for f in 0 1; do for d in 0 1; do
    i="$(verdict_installer check $f $d)"; p="$(verdict_product check $f $d)"
    [ "$i" = "$p" ] || { echo "check failed=$f drift=$d : installeur=$i produit=$p" >&2; return 1; }
  done; done
  [ "$(verdict_product check 0 1)" = 1 ]
  [ "$(verdict_product check 1 0)" = 2 ]
  [ "$(verdict_product check 1 1)" = 2 ]
}

@test "3 n'est le verdict d'aucun dialecte : armées, les deux gardes le rendent à une mort sous set -e" {
  run env PROVISION_RUN=1 bash -c "set -e; . '$INSTALLER' >/dev/null 2>&1; false"
  [ "$status" -eq 3 ]
  [[ "$output" == *"mort avant de rendre son verdict"* ]]
  run env LCARS_MODULE_RUN=1 bash -c "set -e; . '$PRODUCT' >/dev/null 2>&1; false"
  [ "$status" -eq 3 ]
  [[ "$output" == *"mort avant de rendre son verdict"* ]]
}

@test "la garde ne se pose QUE si le lanceur l'arme, et elle ne s'hérite pas" {
  run bash -c "set -e; . '$PRODUCT' >/dev/null 2>&1; false"
  [ "$status" -eq 1 ]
  run bash -c "set -e; . '$INSTALLER' >/dev/null 2>&1; false"
  [ "$status" -eq 1 ]
  # ⚠ ARMÉE PUIS DÉSARMÉE, ET L'ENFANT DOIT SOURCER LE PROTOCOLE POUR QUE ÇA VEUILLE DIRE QUELQUE
  # CHOSE : un enfant qui ne le source pas ne pose aucune garde de toute façon, et le cas serait
  # vert sans rien mesurer. Ici l'enfant le source : s'il héritait de LCARS_MODULE_RUN, son `exit 2`
  # deviendrait 3.
  run env LCARS_MODULE_RUN=1 bash -c "set -e; . '$PRODUCT' >/dev/null 2>&1; LCARS_VERDICT_RENDERED=1; bash -c \". '$PRODUCT' >/dev/null 2>&1; exit 2\""
  [ "$status" -eq 2 ] || { echo "$output" >&2; return 1; }
  refute_out "mort avant de rendre son verdict" <<<"$output"
  # le même pour l'installeur
  run env PROVISION_RUN=1 bash -c "set -e; . '$INSTALLER' >/dev/null 2>&1; PROV_VERDICT_RENDERED=1; bash -c \". '$INSTALLER' >/dev/null 2>&1; exit 2\""
  [ "$status" -eq 2 ] || { echo "$output" >&2; return 1; }
}

@test "un verdict rendu gagne sur la garde, des deux côtés — y compris le FATAL, qui reste 1" {
  run env LCARS_MODULE_RUN=1 bash -c "set -e; . '$PRODUCT' >/dev/null 2>&1; LCARS_DRIFT=1; verdict_apply"
  [ "$status" -eq 2 ]
  run env PROVISION_RUN=1 bash -c "set -e; . '$INSTALLER' >/dev/null 2>&1; PROV_DRIFT=1; verdict_apply"
  [ "$status" -eq 2 ]
  run env LCARS_MODULE_RUN=1 bash -c "set -e; . '$PRODUCT' >/dev/null 2>&1; p_die 'refus'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL"* ]]
  refute_out "mort avant de rendre son verdict" <<<"$output"
}

# Les gestes du produit portent le MEME dispatch, et ils sont joués sous la garde (LCARS_MODULE_RUN) :
# un `exit 2` nu au lieu du FATAL y deviendrait 3, « mort avant verdict », pour un verbe mal tapé.
@test "un mode inconnu est refusé par chaque GESTE du produit, en FATAL (1) — jamais une mort, jamais un verdict" {
  local g name
  for g in "$REPO"/runtime/services/forge.d/*.sh; do
    name="$(basename "$g" .sh)"
    run env LCARS_MODULE_PROTOCOL="$PRODUCT" LCARS_MODULE_TAG="$name" LCARS_MODULE_RUN=1 \
        LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR" bash "$g" verbe-qui-n-existe-pas
    [ "$status" -eq 1 ] || { echo "$name : rc=$status — $output" >&2; return 1; }
    [[ "$output" == *"FATAL $name: mode inconnu"* ]] || { echo "$name : $output" >&2; return 1; }
    refute_out "mort avant de rendre son verdict" <<<"$output"
  done
}

@test "un mode inconnu est refusé par chaque module qui porte son dispatch, en FATAL avant toute mesure : jamais une fonction de la lib jouée sous son nom" {
  local m
  for m in "$REPO"/deploy/modules.d/*.sh; do
    # les appelants de prov_geste confient le verbe au lanceur de la lib
    ! grep -q '^prov_geste ' "$m" || continue
    m="$(basename "$m" .sh)"
    run env LCARS_DECOR_ROOT="$BATS_TEST_TMPDIR/decor" PROVISION_LIB="$INSTALLER" PROVISION_MODULE="$m" PROVISION_RUN=1 \
        PROV_SUBSTRATE=linux bash "$REPO/deploy/modules.d/$m.sh" p_ok
    [ "$status" -eq 1 ] || { echo "$m : rc=$status — $output" >&2; return 1; }
    [[ "$output" == *"mode inconnu"* ]] || { echo "$m : $output" >&2; return 1; }
    [[ "$output" != *"OK    "* ]] || { echo "$m a mesuré avant de refuser : $output" >&2; return 1; }
  done
}

# ─── `run_quiet` : DEUX CORPS, ET LA DIVERGENCE QUI COMPTE EST CELLE DU VERDICT ────────────────
#
# ⚖ PHASE 6, ETAPE 2 (mesure du 2026-09-20). `run_quiet` reste dans la liste des copies de
# `homonymes.bats`, et sa ligne disait seulement « l'installeur CAPTURE et dumpe ». C'est vrai et
# c'est le moins important. Remesure des deux corps :
#
#   |                        | produit                        | installeur                     |
#   |------------------------|--------------------------------|--------------------------------|
#   | code rendu sur echec   | 1, APLATI                      | le code reel de la commande    |
#   | qui leve le verdict    | L'APPELANT — rien n'est compte | `p_fail`, donc PROV_FAILED     |
#   | ce qui est imprime     | la sortie de la commande       | + « commande en echec (rc=…) » |
#
# LA SECONDE LIGNE EST UN PIEGE, et c'est pour ca qu'elle est epinglee ici plutot que decrite
# ailleurs : cote installeur, un `run_quiet` qui echoue REND LE MODULE ROUGE tout seul ; cote
# produit, il ne rend rien rouge du tout. Les deux appelants du produit (`human.d/40-claude-bin.sh`)
# font `p_fail` puis `verdict_apply` eux-memes — c'est sain, et c'est ce que ces temoins figent.
# Un troisieme appelant ecrit par quelqu'un qui connait l'installeur aurait un echec MUET.

@test "run_quiet : le produit ne compte RIEN — l'appelant possede son verdict" {
  run bash -c "set +e; . '$PRODUCT' >/dev/null 2>&1
    run_quiet bash -c 'echo boum; exit 3'; rc=\$?
    printf 'rc=%s failed=%s' \"\$rc\" \"\$LCARS_FAILED\""
  [ "$status" -eq 0 ]
  # Le code est APLATI a 1, la ou l'installeur rend 3 (son temoin l'epingle dans provision-lib.bats).
  [[ "$output" == *"rc=1"* ]] || { echo "$output" >&2; return 1; }
  [[ "$output" == *"failed=0"* ]] || { echo "le produit s'est mis a compter : $output" >&2; return 1; }
  [[ "$output" == *boum* ]] || { echo "la sortie de la commande n'est pas remontee : $output" >&2; return 1; }
}

@test "run_quiet : l'installeur COMPTE, et rend le code reel — l'ecart est assume, pas subi" {
  run bash -c "set +e; . '$INSTALLER' >/dev/null 2>&1
    PROVISION_MODULE=temoin
    run_quiet bash -c 'echo boum; exit 3'; rc=\$?
    printf 'rc=%s failed=%s' \"\$rc\" \"\$PROV_FAILED\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=3"* ]] || { echo "$output" >&2; return 1; }
  [[ "$output" == *"failed=1"* ]] || { echo "$output" >&2; return 1; }
}

@test "MUR : tout appelant produit de run_quiet possede son verdict — sinon l'echec est MUET" {
  # La propriete que la divergence ci-dessus rend necessaire. Elle se lit dans le code : un
  # `run_quiet` du produit doit etre suivi, dans sa branche d'echec, d'un `p_fail` ou d'un `p_die`.
  local f n bloc manquants=""
  while IFS= read -r f; do
    while IFS= read -r n; do
      # les dix lignes qui suivent l'appel : la branche d'echec y est, ou elle n'existe pas.
      # ⚠ COMMENTAIRES RETIRES AVANT LE GREP. Premiere ecriture de ce mur : il cherchait « p_fail »
      # dans le texte brut, donc un verdict COMMENTE le satisfaisait. Mesure du 2026-09-20 : deux
      # tentatives de falsification l'ont laisse vert d'affilee, parce que chacune laissait le mot
      # dans la ligne qu'elle neutralisait. Un mur qui accepte sa propre mise hors service ne mesure
      # rien — meme lecon que la premiere version de `facts.readers_wired`.
      bloc="$(sed -n "${n},$((n + 10))p" "$f" | sed 's/#.*//')"
      grep -qE 'p_fail|p_die' <<<"$bloc" || manquants="$manquants ${f#"$REPO"/}:$n"
    done < <(grep -nE '(^|[^_[:alnum:]])run_quiet ' "$f" | grep -v 'run_quiet() {' | cut -d: -f1)
  done < <(grep -rlE '(^|[^_[:alnum:]])run_quiet ' "$REPO/runtime/services" --include='*.sh' | grep -v '/lib/module-protocol.sh')

  [ -z "${manquants// /}" ] || {
    echo "appel(s) de run_quiet sans verdict cote produit :$manquants" >&2
    echo "→ cote produit run_quiet ne compte RIEN : sans p_fail/p_die dans la branche d'echec, le" >&2
    echo "  module rend 0 sur une commande ratee. Cote installeur le meme nom compte tout seul." >&2
    return 1
  }
}
