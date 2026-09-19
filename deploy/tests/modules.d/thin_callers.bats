#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/thin_callers.bats
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: témoins des appelants des gestes de forge 50, 63, 65, 66 — le lanceur de la lib, ses codes, ses noms traduits

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  DEPLOY="$BATS_TEST_DIRNAME/../.."
  CALLERS=(50-catalogues:catalogues 63-forge-tokens:tokens 65-ops-repo:ops-repo 66-deck-oidc:deck-oidc)
  decor_pose
  export PROV_SUBSTRATE=linux PROV_HUMAN=humain-du-poste PROVISION_RUN=1
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"
  # aucun service n'écoute sur le port 1 : chaque geste réel lit une forge injoignable
  export PROV_FORGE_HOST_PORT=1
}

# une racine de dépôt dont les gestes sont des doublures ; lib, modules et protocole sont les vrais
racine_doublee() { # racine_doublee <corps du geste>
  ROOT="$BATS_TEST_TMPDIR/racine"
  mkdir -p "$ROOT/deploy" "$ROOT/runtime/services/forge.d" "$ROOT/runtime/services/lib" "$ROOT/runtime/etc"
  cp -a "$DEPLOY/lib" "$DEPLOY/modules.d" "$DEPLOY/installer-constants.env" "$DEPLOY/system.manifest" "$ROOT/deploy/"
  cp "$DEPLOY/../runtime/services/lib/module-protocol.sh" "$ROOT/runtime/services/lib/"
  # ⚖ décision 3 : le protocole SOURCE le lecteur des faits, et les faits vivent sous `runtime/etc`.
  # Une racine doublée qui n'emporte que le protocole ferait mourir chaque geste au sourcing.
  cp "$DEPLOY/../runtime/services/lib/facts.sh" "$ROOT/runtime/services/lib/"
  cp "$DEPLOY/../runtime/etc/facts.env" "$ROOT/runtime/etc/"
  local c
  for c in "${CALLERS[@]}"; do
    printf '#!/usr/bin/env bash\nset -euo pipefail\n. "$LCARS_MODULE_PROTOCOL"\n%s\n' "$1" > "$ROOT/runtime/services/forge.d/${c#*:}.sh"
  done
}
joue() { # joue <racine> <module> <verbe>
  run env PROVISION_MODULE="$2" PROVISION_LIB="$1/deploy/lib/provision-lib.sh" bash "$1/deploy/modules.d/$2.sh" "$3"
}

@test "chaque appelant joue son geste réel : forge injoignable, le drift du geste est le code du module, en check comme en apply" {
  local c
  for c in "${CALLERS[@]}"; do
    joue "$DEPLOY/.." "${c%%:*}" check
    [ "$status" -eq 1 ] || { echo "${c%%:*} check : rc=$status — $output" >&2; return 1; }
    [[ "$output" == *"DRIFT ${c%%:*}: "* ]]
    joue "$DEPLOY/.." "${c%%:*}" apply
    [ "$status" -eq 2 ] || { echo "${c%%:*} apply : rc=$status — $output" >&2; return 1; }
    [[ "$output" == *"DRIFT ${c%%:*}: "* ]]
  done
}

@test "un geste mort sous set -e avant son verdict rend 3, et la garde du module nomme le code brut" {
  racine_doublee 'p_drift "sonde partielle"; grep -q introuvable /dev/null; verdict_check'
  local c
  for c in "${CALLERS[@]}"; do
    joue "$ROOT" "${c%%:*}" check
    # sans la garde, le 1 de grep se lirait comme un drift
    [ "$status" -eq 3 ] || { echo "${c%%:*} : rc=$status — $output" >&2; return 1; }
    [[ "$output" == *"ERREUR ${c%%:*}: mort avant de rendre son verdict (rc=1)"* ]]
  done
}

@test "les sorties du protocole sont des verdicts : verdict_apply et p_die relaient leur code, sans erreur de garde" {
  racine_doublee 'case "$1" in apply) p_fail "geste raté"; verdict_apply ;; *) p_die "verbe refusé" ;; esac'
  joue "$ROOT" 66-deck-oidc apply
  [ "$status" -eq 1 ]
  refute_out 'mort avant' <<<"$output"
  joue "$ROOT" 65-ops-repo check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL 65-ops-repo: verbe refusé"* ]]
  refute_out 'mort avant' <<<"$output"
}

@test "seules les sorties du protocole marquent un verdict : un exit dans une fonction du geste nommée verdict_… n'en est pas un (3)" {
  racine_doublee 'verdict_resume() { p_drift "sonde partielle"; exit 0; }; verdict_resume'
  joue "$ROOT" 50-catalogues check
  [ "$status" -eq 3 ] || { echo "rc=$status — $output" >&2; return 1; }
  [[ "$output" == *"ERREUR 50-catalogues: mort avant de rendre son verdict (rc=0)"* ]]
}

@test "les noms du produit portent les valeurs de l'installeur, les mêmes pour les quatre gestes" {
  racine_doublee 'env | grep -E "^(LCARS|FORGE)_" | sort; printf "groupe du systeme=%s\n" "$LCARS_SYSTEM_GROUP"; verdict_check'
  local c systeme
  systeme="$(sed -n 's/^PROV_SYSTEM_USER=//p' "$DEPLOY/installer-constants.env")"
  for c in "${CALLERS[@]}"; do
    joue "$ROOT" "${c%%:*}" check
    [ "$status" -eq 0 ] || { echo "${c%%:*} : rc=$status — $output" >&2; return 1; }
    grep -qx "LCARS_MODULE_TAG=${c%%:*}" <<<"$output"
    grep -qx 'LCARS_LOGIN=humain-du-poste' <<<"$output"
    grep -qx 'FORGE_BASE_URL=http://127.0.0.1:1' <<<"$output"
    grep -qx "LCARS_SYSTEM_USER=$systeme" <<<"$output"
    # le groupe du compte système dérive de son compte dans le protocole du produit
    grep -qx "groupe du systeme=$systeme" <<<"$output"
    grep -qx "LCARS_MASTER_TOKEN_FILE=$LCARS_DECOR_ROOT/opt/lcars/var/tokens/forge-master.token" <<<"$output"
  done
  joue "$ROOT" 63-forge-tokens check
  grep -qx "LCARS_CLI=$LCARS_DECOR_ROOT/usr/local/bin/lcars" <<<"$output"
  # 66 annonce l'adresse du deck : celle qu'advertise_addr mesure dans le même environnement
  local annonce
  annonce="$(env -u PROVISION_RUN bash -c '. "$1"; advertise_addr; printf "%s" "$PROV_ADVERTISE"' _ "$ROOT/deploy/lib/provision-lib.sh")"
  [ -n "$annonce" ]
  joue "$ROOT" 66-deck-oidc check
  grep -qx "LCARS_ADVERTISE=$annonce" <<<"$output"
}

# ⚠ CE QUI MEURT AVANT LE PROTOCOLE N'A AUCUNE GARDE — et c'est le cas d'une release absente. Le
# geste sort alors en 127 (script introuvable) ou en 1 (protocole illisible) : deux codes que le
# lanceur relayait tels quels, donc lus « échec applicatif ». La lib refuse maintenant AVANT de
# lancer ce qu'elle ne peut pas lire, et sa propre garde rend 3 sur un code hors du vocabulaire.
@test "release absente : le lanceur refuse AVANT de lancer, en nommant les deux fichiers" {
  racine_doublee 'verdict_check'
  rm -f "$ROOT/runtime/services/forge.d/tokens.sh"
  joue "$ROOT" 63-forge-tokens apply
  [ "$status" -eq 1 ] || { echo "rc=$status — $output" >&2; return 1; }
  [[ "$output" == *"FAIL 63-forge-tokens: geste « tokens » injouable"* ]] || [[ "$output" == *"geste « tokens » injouable"* ]]
  [[ "$output" == *"tokens.sh"* ]]
  refute_out "ERREUR" <<<"$output"

  racine_doublee 'verdict_check'
  rm -f "$ROOT/runtime/services/lib/module-protocol.sh"
  joue "$ROOT" 63-forge-tokens check
  [ "$status" -eq 2 ] || { echo "rc=$status — $output" >&2; return 1; }
  [[ "$output" == *"injouable"*"module-protocol.sh"* ]]
}

@test "un code hors du vocabulaire du protocole (0-3) est une mort : la garde du module rend 3" {
  racine_doublee 'exit 127'
  joue "$ROOT" 63-forge-tokens apply
  [ "$status" -eq 3 ] || { echo "rc=$status — $output" >&2; return 1; }
  [[ "$output" == *"ERREUR 63-forge-tokens: mort avant de rendre son verdict (rc=127)"* ]]
}
