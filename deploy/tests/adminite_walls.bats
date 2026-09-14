#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/adminite_walls.bats
# AUTHOR: bob
# STARDATE: 2026-08-23
# STATUS: actif — les deux invariants de l'adminite, tenus par une mesure et non par la discipline

# shellcheck disable=SC2016

# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC2013 — lecture mot a mot VOULUE : le champ mesure ne contient pas d'espace
# shellcheck disable=SC2013

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # la RACINE du depot — `deploy/` et `runtime/` y sont FRERES
  ARBRES=("$REPO/deploy" "$REPO/runtime/services" "$REPO/runtime/bin" "$REPO/runtime/priv")
  mapfile -t CODE < <(
    find "${ARBRES[@]}" -type f \
      \( -name '*.sh' -o -name '*.py' -o -name '*.yaml' -o -name 'lcars' -o -name 'container' \
         -o -name 'accept' -o -name 'provision' -o -name 'Dockerfile' -o -name '*.manifest' \) \
      -not -path '*/tests/*' 2>/dev/null | sort
  )
}

code_of() { sed 's/#.*//' "$1"; }

absent() { # absent <motif etendu> <fichier> — echoue si le CODE du fichier porte le motif
  local n; n="$(code_of "$2" | grep -cE -- "$1" || true)"
  [ "$n" -eq 0 ] || {
    echo "MUR rompu — « $1 » present $n fois dans le CODE de $2 :" >&2
    code_of "$2" | grep -nE -- "$1" >&2
    return 1
  }
}

@test "MUR: le perimetre n'est pas VIDE — un balayage casse compte zero, comme un sans-faute" {
  local a
  for a in "${ARBRES[@]}"; do
    printf '%s\n' "${CODE[@]}" | grep -q "^$a/" || {
      echo "MUR 0 rompu — l'arbre « ${a#"$REPO"/} » ne contribue AUCUN fichier au perimetre" >&2
      return 1
    }
  done
  # Le plancher reste, un cran sous la mesure : il attrape la perte massive qu'un arbre encore
  # represente par un seul fichier laisserait passer.
  [ "${#CODE[@]}" -ge 100 ]
  printf '%s\n' "${CODE[@]}" | grep -q 'forge-gestures.sh'
  printf '%s\n' "${CODE[@]}" | grep -q 'catalogue-executor.py'
  printf '%s\n' "${CODE[@]}" | grep -q 'bin/lcars'
}

@test "MUR 1: le jeton master et le seed ne sont poses QUE pour leur detenteur, sans groupe" {
  local trouvees=0 f mode
  for f in "${CODE[@]}"; do
    trouvees=$((trouvees + $(code_of "$f" \
      | grep -cE 'MASTER_TOKEN_FILE|forge-master\.token|SEED_FILE|forge-seed\.pass' \
      | head -1) ))
  done
  [ "$trouvees" -ge 3 ] || {
    echo "MUR 1 INSTRUMENT CASSE — seulement $trouvees ligne(s) parlent des secrets d'autorite." >&2
    echo "  Ce mur ne mesure plus rien : les ecrivains ont bouge, ou le balayage est faux." >&2
    return 1
  }

  for f in "${CODE[@]}"; do
    # Les lignes de CODE qui posent un mode sur l'un des deux secrets.
    while IFS= read -r ligne; do
      [[ -z "$ligne" ]] && continue
      # Tout mode octal a quatre chiffres cite sur cette ligne doit etre 0600.
      for mode in $(grep -oE '0[0-7]{3}' <<<"$ligne"); do
        [[ "$mode" == "0600" ]] || {
          echo "MUR 1 rompu — $f pose un secret d'autorite en $mode :" >&2
          echo "  $ligne" >&2
          return 1
        }
      done
      # Et aucun groupe ne s'y attache.
      grep -qE 'root:(root)?$|root:root' <<<"$ligne" || grep -qv 'root:' <<<"$ligne" || {
        echo "MUR 1 rompu — $f attache un groupe a un secret d'autorite :" >&2
        echo "  $ligne" >&2
        return 1
      }
    done < <(code_of "$f" | grep -E 'MASTER_TOKEN_FILE|forge-master\.token|SEED_FILE|forge-seed\.pass' \
                          | grep -E 'chmod|chown|chgrp|write_atomic|install -m|0[0-7]{3}')
  done
}

@test "MUR 2: aucune porte n'interroge un groupe unix pour decider d'une adminite" {
  local f
  for f in "${CODE[@]}"; do
    absent 'lcars-admin|ADMIN_GROUP' "$f"
  done
}

@test "MUR 2 bis: les deux portes du geste ne lisent AUCUN groupe unix" {
  local porte
  for porte in "$REPO/runtime/bin/lcars" "$REPO/runtime/services/catalogue-executor.py"; do
    [ -r "$porte" ]
    absent 'id -nG|getent group|os\.getgroups|grp\.getgrall' "$porte"
  done
  local cible hors_bind
  for cible in "$REPO/runtime/services/catalogue-executor.py" "$REPO/runtime/services/lcars_socket.py"; do
    [ -r "$cible" ]
    hors_bind="$(code_of "$cible" | sed '/^def bind(/,/^def /d' \
                  | grep -cE 'grp\.|getgrnam|getgrall' || true)"
    [ "$hors_bind" -eq 0 ] || {
      echo "MUR 2 bis rompu — le groupe est consulte HORS de bind() dans $cible ($hors_bind fois)" >&2
      return 1
    }
  done
  # Garde d'instrument : si `bind()` cesse d'exister ou change de nom, la coupe ci-dessus ne
  # retirerait plus rien et le mur passerait au vert sur un fichier qu'il n'a pas lu.
  code_of "$REPO/runtime/services/lcars_socket.py" | grep -q '^def bind('
  # Et la consultation existe QUELQUE PART : un mur vert sur zero occurrence ne mesure rien.
  code_of "$REPO/runtime/services/lcars_socket.py" | grep -q 'getgrnam'
}

@test "MUR 3: le convergeur ne lit plus l'autorite du conteneur" {
  # Il PROVISIONNE — un compte unix ne se cree pas au moment ou quelqu'un tape. Il n'AUTORISE pas :
  # ca se demande a l'instant ou ca compte. Son unique usage du jeton master etait la projection.
  local c="$REPO/runtime/services/human-converger.sh"
  [ -r "$c" ]
  absent 'MASTER_TOKEN' "$c"
  absent 'forge-master' "$c"
  # Le garde d'instrument : il lit TOUJOURS le jeton systeme, sinon il ne converge rien.
  code_of "$c" | grep -q 'TOKEN_FILE='
}


@test "MUR 5: le deck ne se depose plus sur une identite partagee, et son compte existe — pose par 21 sur les deux terrains" {
  local landing="$REPO/runtime/services/console-landing.sh"
  local mod="$REPO/deploy/modules.d/21-service-accounts.sh"

  # Le drop ne nomme plus `nobody` : ni en uid, ni en gid.
  absent 'reuid nobody' "$landing"
  absent 'regid nogroup' "$landing"
  # ... et il nomme un compte, par une variable dont le defaut est lisible.
  code_of "$landing" | grep -q 'DECK_USER="\${LCARS_DECK_USER:-lcars-system}"'

  # LES DEUX RAILS POSENT LE COMPTE. En verifier un seul laisserait l'autre demarrer un `setpriv`
  # vers un nom que `/etc/passwd` ne connait pas — et `setpriv` echoue alors en parlant de lui-meme.
  code_of "$mod" | grep -q 'SYSTEM_USER="\$PROV_SYSTEM_USER"'
  grep -qx 'PROV_SYSTEM_USER=lcars-system' "$REPO/deploy/installer-constants.env"
  code_of "$mod" | grep -q -- '-g "\$SYSTEM_GROUP" -- "\$SYSTEM_USER"'
}

@test "MUR 5 bis: le groupe du secret OIDC est le compte du deck, et le MANIFESTE dit la meme chose" {
  local mod="$REPO/runtime/services/forge.d/deck-oidc.sh"
  local manifest="$REPO/deploy/system.manifest"
  local row group

  group="$(code_of "$mod" | sed -nE 's@^OIDC_GROUP=.*:-([a-z0-9-]+)\}+"$@\1@p')"
  [ -n "$group" ] || { echo "OIDC_GROUP illisible dans $mod" >&2; return 1; }

  row="$(grep -E '^anchor[[:space:]]+/etc/lcars/deck-oidc\.json[[:space:]]' "$manifest")"
  [ -n "$row" ] || { echo "deck-oidc.json n'est plus declare dans le manifeste" >&2; return 1; }
  [[ "$row" == *0640* ]] || { echo "mode attendu 0640 : $row" >&2; return 1; }
  [[ "$row" == *"root:$group"* ]] \
    || { echo "le module pose root:$group, le manifeste declare autre chose : $row" >&2; return 1; }
}

@test "MUR 5 ter: lcars-console n'a AUCUN membre declare — il s'accorde a l'exec, jamais par adhesion" {
  local f
  for f in "${CODE[@]}"; do
    absent 'ensure_member.*(lcars-console|PROV_CONSOLE_GROUP)' "$f"
    absent 'usermod.*-aG.*(lcars-console|PROV_CONSOLE_GROUP)' "$f"
  done
}

@test "MUR 4: le detenteur des secrets n'a AUCUN privilege noyau — le poste et le conteneur" {
  local unit="$REPO/deploy/modules.d/64-services.sh"
  local entry="$REPO/runtime/services/container/boot.sh"

  # RAIL POSTE : l'unite du service d'autorite porte un `User=`, celle du convergeur n'en porte PAS.
  code_of "$unit" | sed -n '/lcars-catalogue)/,/^      ;;/p' | grep -q 'User='
  run bash -c "sed 's/#.*//' '$unit' | sed -n '/lcars-converger)/,/^      ;;/p' | grep -c 'User=' || true"
  [ "$output" -eq 0 ]

  # RAIL CONTENEUR : le service est depose par setpriv, et le compte existe dans l'image.
  code_of "$entry" | grep -q 'setpriv .*catalogue-executor.py\|setpriv[^|]*\\$'
  code_of "$entry" | grep -q 'catalogue-executor.py'

  # LE COMPTE EST POSE PAR LE RAIL POSTE AUSSI — sinon `User=` designe un compte absent et l'unite
  # meurt au demarrage sur `failed to determine user credentials`.
  [ -r "$REPO/deploy/modules.d/21-service-accounts.sh" ]
  code_of "$REPO/deploy/modules.d/21-service-accounts.sh" | grep -q 'useradd'
}

@test "MUR 4 bis: le nom du compte est une COPIE, et les copies s'accordent" {
  local attendu
  attendu="$(sed -n 's/^PROV_AUTHORITY_USER=\([a-z-]*\)$/\1/p' "$REPO/deploy/installer-constants.env")"
  [ -n "$attendu" ] || { echo "MUR 4 bis — l'autorite est illisible dans installer-constants.env" >&2; return 1; }

  code_of "$REPO/runtime/services/container/boot.sh" \
    | grep -qE "LCARS_AUTHORITY_USER=\"\\\$\{LCARS_AUTHORITY_USER:-${attendu}\}\"" || {
      echo "MUR 4 bis rompu — l'entrypoint ne pose pas « $attendu » dans LCARS_AUTHORITY_USER" >&2
      code_of "$REPO/runtime/services/container/boot.sh" | grep -nE 'LCARS_AUTHORITY_USER=' >&2
      return 1
    }
}
