#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/authority_walls.bats
# AUTHOR: bob
# STARDATE: 2026-08-25
# STATUS: actif — les invariants du service d'autorite, tenus par une mesure et non par la discipline

# shellcheck disable=SC2016

setup() {
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/etc/lcars/seat.uid"
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

@test "MUR 1 bis: les QUATRE ecrivains du repertoire sont la, et ils posent le MEME mode" {
  local f
  for f in "$REPO/runtime/services/provision-role-tokens.sh" "$REPO/runtime/services/forge-gestures.sh"; do
    grep -qE 'install -d -m 0710' "$f" \
      || { echo "$f ne pose plus le repertoire des secrets en 0710" >&2; return 1; }
    # Et il ne reste AUCUN 0700 sur cet objet : deux modes dans un meme fichier, c'est celui qu'on
    # n'a pas relu qui gagne.
    local n
    n="$(sed 's/#.*//' "$f" | grep -cE 'install -d -m 0700.*(PRIVATE_DIR|TOKENS_DIR)' || true)"
    [ "$n" -eq 0 ] || { echo "$f pose ENCORE 0700 sur le repertoire des secrets" >&2; return 1; }
  done
  grep -qE 'PROV_TOKENS_DIR 0710' "$REPO/deploy/modules.d/25-directories.sh"
  grep -qE "^dir[[:space:]]+${TOKENS_DIR}[[:space:]]+0710" "$MANIFEST"
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
  local f
  while read -r f; do
    absent 'chgrp' "$f"
    absent '(chown|install).*(:|-g )(fleet|\$PROV_FLEET_GROUP|\$\{PROV_FLEET_GROUP\})' "$f"
  done < <(secret_writers)
}

@test "MUR 2 ter: les cinq ecrivains de secret existent — sinon le mur ci-dessus lit le vide" {
  local f n=0
  while read -r f; do
    [ -f "$f" ] || { echo "ecrivain de secret introuvable : $f" >&2; return 1; }
    n=$((n + 1))
  done < <(secret_writers)
  [ "$n" -eq 5 ]
}

@test "MUR 2 bis: le manifeste declare la racine des jetons au detenteur, traversable et non listable" {
  local row
  row="$(grep -E "^dir[[:space:]]+${TOKENS_DIR}[[:space:]]" "$MANIFEST")"
  [ -n "$row" ] || { echo "« $TOKENS_DIR » n'est plus declare dans le manifeste" >&2; return 1; }
  [[ "$row" == *0710* ]] || { echo "mode attendu 0710 (le groupe traverse, il ne liste pas) : $row" >&2; return 1; }
  [[ "$row" == *lcars-authority:fleet* ]] \
    || { echo "attendu « lcars-authority:fleet » — le service detient, le groupe traverse : $row" >&2; return 1; }
}


@test "MUR 3: aucun FORGE_TOKEN_FILE construit depuis le repertoire des secrets ne part vers une porte" {
  local f
  for f in "${CODE[@]}"; do
    absent 'FORGE_TOKEN_FILE=.*(PRIVATE_DIR|TOKENS_DIR|/opt/lcars/var/tokens)' "$f"
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

@test "MUR 7: le jeton master n'est ni memoise ni lu au chargement du module" {
  local svc="$REPO/runtime/services/catalogue-executor.py"
  [ -f "$svc" ] || { echo "executeur introuvable : $svc" >&2; return 1; }
  # Les formes explicites de cache.
  absent '(lru_cache|functools\.cache|@cache)' "$svc"
  # Une seule ouverture du fichier, et elle est dans la fonction — pas au niveau module.
  local n
  n="$(sed 's/#.*//' "$svc" | grep -cE 'open\(MASTER_TOKEN_FILE' || true)"
  [ "$n" -eq 2 ] || {
    echo "MUR 7: $n ouverture(s) de MASTER_TOKEN_FILE — attendu 2 (le garde de main, et master_token)" >&2
    sed 's/#.*//' "$svc" | grep -nE 'open\(MASTER_TOKEN_FILE' >&2
    return 1
  }
  # Et aucune affectation de module qui garderait la valeur.
  n="$(sed 's/#.*//' "$svc" | grep -cE '^[A-Z_]*(MASTER|TOKEN)[A-Z_]* *= *master_token' || true)"
  [ "$n" -eq 0 ]
}

@test "MUR 7 bis: le temoin FONCTIONNEL de 6d existe — le mur textuel ne suffit pas" {
  local banc="$REPO/runtime/test/services/catalogue-executor_test.py"
  [ -f "$banc" ] || { echo "banc de l'executeur introuvable : $banc" >&2; return 1; }
  grep -q 'jeton-rotatif' "$banc"
  grep -q '6d: RELU a chaque appel' "$banc"
}


@test "MUR 4: le minteur VERIFIE le proprietaire de ce qu'il vient d'ecrire" {
  local src="$REPO/runtime/services/provision-role-tokens.sh"
  grep -qE 'chown "\$OWNER:\$OWNER"' "$src"
  grep -qE 'stat -c %U' "$src"
  absent 'stat -c %G' "$src"
  absent 'chgrp' "$src"
}
