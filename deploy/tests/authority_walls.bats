#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/authority_walls.bats
# AUTHOR: bob
# STARDATE: 2026-08-25
# STATUS: actif — les invariants du service d'autorite, tenus par une mesure et non par la discipline

# shellcheck disable=SC2016

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # la RACINE du depot — `deploy/` et `runtime/` y sont FRERES
  ARBRES=("$REPO/deploy" "$REPO/runtime/services" "$REPO/runtime/bin")
  mapfile -t CODE < <(
    find "${ARBRES[@]}" -type f \
      \( -name '*.sh' -o -name '*.py' -o -name 'lcars' -o -name 'container' \
         -o -name 'provision' -o -name 'Dockerfile' \) \
      -not -path '*/tests/*' 2>/dev/null | sort
  )
  MANIFEST="$REPO/deploy/system.manifest"
  TOKENS_DIR="$(env -i PATH="$PATH" bash -c ". '$REPO/deploy/lib/provision-lib.sh' >/dev/null 2>&1; printf '%s' \"\$PROV_TOKENS_DIR\"")"
  [[ "$TOKENS_DIR" == /* ]] || { echo "la lib ne rend pas de racine de jetons absolue : « $TOKENS_DIR »" >&2; return 1; }
}

code_of() { sed 's/#.*//' "$1"; }

absent() { # absent <motif etendu> <fichier>
  local n; n="$(code_of "$2" | grep -cE -- "$1" || true)"
  [ "$n" -eq 0 ] || {
    echo "MUR rompu — « $1 » present $n fois dans le CODE de $2 :" >&2
    code_of "$2" | grep -nE -- "$1" >&2
    return 1
  }
}

@test "MUR 0: le perimetre n'est pas VIDE — un balayage casse compte zero, comme un sans-faute" {
  local a
  for a in "${ARBRES[@]}"; do
    printf '%s\n' "${CODE[@]}" | grep -q "^$a/" || {
      echo "MUR 0 rompu — l'arbre « ${a#"$REPO"/} » ne contribue AUCUN fichier au perimetre" >&2
      return 1
    }
  done
  [ "${#CODE[@]}" -gt 55 ] || { echo "perimetre a ${#CODE[@]} fichiers — le balayage est casse" >&2; return 1; }
  printf '%s\n' "${CODE[@]}" | grep -q 'services/forge-gestures.sh'
  printf '%s\n' "${CODE[@]}" | grep -q 'runtime/services/provision-role-tokens.sh'
  printf '%s\n' "${CODE[@]}" | grep -q 'modules.d/25-directories.sh'
}


@test "MUR 1: le groupe TRAVERSE le repertoire des secrets — il ne le lit ni ne l'ecrit, et « other » est ferme" {
  local mode='0o?[0-7][2-7][0-7]|0o?[0-7][0-7][1-7]'
  local lieu='PRIVATE_DIR|TOKENS_DIR|/home/private'
  local verbe='install -d|ensure_dir|chmod|makedirs|mkdir'
  local motif="($verbe).*(($mode).*($lieu)|($lieu).*($mode))"
  local f hits=0
  for f in "${CODE[@]}"; do
    if code_of "$f" | grep -qE -- "$motif"; then
      echo "MUR rompu — le groupe LIT le repertoire des secrets dans $f :" >&2
      code_of "$f" | grep -nE -- "$motif" >&2
      hits=$((hits + 1))
    fi
  done
  [ "$hits" -eq 0 ]
}

@test "MUR 1 bis: les deux ecrivains du produit posent le repertoire des secrets au mode que le manifeste declare" {
  # 25-directories le pose depuis la table, et modules.d/25-directories.bats le joue
  local mode f n
  mode="$(awk -v p="$TOKENS_DIR" '$1 == "dir" && $2 == p {print $3; exit}' "$MANIFEST")"
  [[ "$mode" =~ ^0[0-7]{3}$ ]] || { echo "« $TOKENS_DIR » sans mode au manifeste : « $mode »" >&2; return 1; }
  for f in "$REPO/runtime/services/provision-role-tokens.sh" "$REPO/runtime/services/forge-gestures.sh"; do
    grep -qE "install -d -m $mode" "$f" \
      || { echo "$f ne pose plus le repertoire des secrets en $mode" >&2; return 1; }
    # deux modes dans un même fichier : celui qu'on n'a pas relu gagne
    n="$(sed 's/#.*//' "$f" | grep -E 'install -d -m 0[0-7]{3}.*(PRIVATE_DIR|TOKENS_DIR)' | grep -cv -- "-m $mode" || true)"
    [ "$n" -eq 0 ] || { echo "$f pose un autre mode que $mode sur le repertoire des secrets" >&2; return 1; }
  done
}


secret_writers() {
  printf '%s\n' \
    "$REPO/runtime/services/provision-role-tokens.sh" \
    "$REPO/runtime/services/forge-gestures.sh" \
    "$REPO/deploy/modules.d/48-forge-host.sh" \
    "$REPO/runtime/services/forge.d/tokens.sh" \
    "$REPO/deploy/modules.d/25-directories.sh"
}

@test "MUR 2: aucun ecrivain de secret ne donne son objet a un groupe" {
  local f n=0
  while read -r f; do
    # GARDE D'INSTRUMENT : un écrivain absent se lirait comme un écrivain sans faute
    [ -f "$f" ] || { echo "ecrivain de secret introuvable : $f" >&2; return 1; }
    n=$((n + 1))
    absent 'chgrp' "$f"
    absent '(chown|install).*(:|-g )(fleet|\$PROV_FLEET_GROUP|\$\{PROV_FLEET_GROUP\})' "$f"
  done < <(secret_writers)
  [ "$n" -eq 5 ]
}

@test "MUR 2 bis: le manifeste declare la racine des jetons au detenteur, traversable et non listable" {
  local row
  row="$(awk -v p="$TOKENS_DIR" '$1 == "dir" && $2 == p' "$MANIFEST")"
  [ -n "$row" ] || { echo "« $TOKENS_DIR » n'est plus declare dans le manifeste" >&2; return 1; }
  local detenteur groupe
  detenteur="$(sed -n 's/^PROV_AUTHORITY_USER=//p' "$REPO/deploy/installer-constants.env")"
  groupe="$(sed -n 's/^PROV_FLEET_GROUP=//p' "$REPO/deploy/installer-constants.env")"
  [ -n "$detenteur" ]
  [ -n "$groupe" ]
  [ "$(awk '{print $3}' <<<"$row")" = 0710 ] || { echo "mode attendu 0710 (le groupe traverse, il ne liste pas) : $row" >&2; return 1; }
  [ "$(awk '{print $4}' <<<"$row")" = "$detenteur:$groupe" ] \
    || { echo "attendu « $detenteur:$groupe » — le service detient, le groupe traverse : $row" >&2; return 1; }
}


@test "MUR 3: aucun FORGE_TOKEN_FILE construit depuis le repertoire des secrets ne part vers une porte" {
  local f
  for f in "${CODE[@]}"; do
    absent "FORGE_TOKEN_FILE=.*(PRIVATE_DIR|TOKENS_DIR|$TOKENS_DIR)" "$f"
  done
}

@test "MUR 3 bis: l'entrypoint relaie bien la VALEUR — sinon la porte part sans credential" {
  grep -qE 'FORGE_TOKEN="\$\{FORGE_TOKEN:-\}"' "$REPO/runtime/bin/lcars"
  grep -qE 'FORGE_TOKEN="\$sys_tok_value"' "$REPO/runtime/services/forge-gestures.sh"
}



@test "MUR 5: aucune ligne de CODE n'accorde root a un groupe par sudoers" {
  local f
  for f in "${CODE[@]}"; do
    # `ALL=(root)` est la syntaxe d'une regle. La PROSE qui nomme la regle retiree est legitime —
    # c'est son metier — et `code_of` l'a deja retiree.
    absent 'ALL=\(root\)' "$f"
  done
}

@test "MUR 5 bis: le rail d'outillage ne passe plus par sudo" {
  local recon="$REPO/runtime/lib/fleet/admiral/toolchain_reconciler.ex"
  [ -f "$recon" ] || { echo "reconciliateur introuvable : $recon" >&2; return 1; }
  local n
  n="$(grep -cE 'System.cmd\("sudo"' "$recon" || true)"
  [ "$n" -eq 0 ] || { grep -nE 'System.cmd\("sudo"' "$recon" >&2; return 1; }
  grep -q 'toolchain.sock' "$recon"
}

@test "MUR 5 ter: le service privilegie n'OUVRE aucun secret" {
  local svc="$REPO/runtime/services/privileged-executor.py"
  [ -f "$svc" ] || { echo "service privilegie introuvable : $svc" >&2; return 1; }
  absent "$TOKENS_DIR" "$svc"
  absent '(MASTER_TOKEN|gitea_token|forge-master|forge-seed)' "$svc"
}


@test "MUR 6: la regle d'eligibilite ne lit AUCUN groupe" {
  local hum="$REPO/runtime/services/console-humans.sh"
  [ -f "$hum" ] || { echo "regle d'eligibilite introuvable : $hum" >&2; return 1; }
  absent '(getent group|LCARS_CONSOLE_GROUP|FLEET_MEMBERS|/etc/group)' "$hum"
}

@test "MUR 6 bis: l'eligibilite d'une console ne lit ni groupe ni siege — trois faits locaux" {
  local hum="$REPO/runtime/services/console-humans.sh"
  absent 'LCARS_SYSADMIN_UID|SEAT_UID_FILE' "$hum"
  sed 's/#.*//' "$hum" | grep -qE 'uid.*-lt.*UID_MIN'
  sed 's/#.*//' "$hum" | grep -qE '\-d "\$home"'
}

@test "MUR 4: le minteur VERIFIE le proprietaire de ce qu'il vient d'ecrire" {
  local src="$REPO/runtime/services/provision-role-tokens.sh"
  grep -qE 'chown "\$OWNER:\$OWNER"' "$src"
  grep -qE 'stat -c %U' "$src"
  absent 'stat -c %G' "$src"
  absent 'chgrp' "$src"
}
