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
  # le mode se joue (modules.d/48-forge-host.bats) ; le propriétaire, qu'un décor rend à qui le joue,
  # ne se lit que dans le code : chaque propriétaire écrit est « compte:compte », le groupe éponyme du détenteur
  local secrets
  secrets="$(sed -nE 's#^PROV_(MASTER_TOKEN_FILE|FORGE_SEED_FILE)=.*/##p' "$REPO/deploy/installer-constants.env" | sed 's/\./\\./g' | paste -sd'|')"
  [[ "$secrets" == *'|'* ]] || { echo "MUR 1 — les deux secrets d'autorité ne se lisent plus dans installer-constants.env : « $secrets »" >&2; return 1; }
  local motif="MASTER_TOKEN_FILE|FORGE_SEED_FILE|$secrets"

  local f ligne mode proprio proprios poses=0
  for f in "${CODE[@]}"; do
    while IFS= read -r ligne; do
      [[ -n "$ligne" ]] || continue
      poses=$((poses + 1))
      for mode in $(grep -oE '0[0-7]{3}' <<<"$ligne"); do
        [[ "$mode" == "0600" ]] || { echo "MUR 1 rompu — $f pose un secret d'autorite en $mode :" >&2; echo "  $ligne" >&2; return 1; }
      done
      proprios="$(grep -oE '"?(\$\{?[A-Za-z_]+\}?|[a-z][a-z0-9_-]*):(\$\{?[A-Za-z_]+\}?|[a-z][a-z0-9_-]*)"?' <<<"$ligne" | grep -v '^[a-z]*://' || true)"
      # une pose qui nomme un propriétaire sans « compte:compte » laisse le groupe à ce qui était là : elle se refuse
      [[ -n "$proprios" ]] || ! grep -qE 'chown|chgrp|write_atomic|install -m' <<<"$ligne" || {
        echo "MUR 1 rompu — $f pose un secret d'autorite sans propriétaire « compte:compte » :" >&2; echo "  $ligne" >&2; return 1; }
      while read -r proprio; do
        [[ -n "$proprio" ]] || continue
        proprio="${proprio//\"/}"
        [[ "${proprio%%:*}" == "${proprio#*:}" ]] || {
          echo "MUR 1 rompu — $f donne un secret d'autorite au groupe « ${proprio#*:} » :" >&2; echo "  $ligne" >&2; return 1; }
      done <<<"$proprios"
    done < <(code_of "$f" | grep -E "$motif" | grep -E 'chmod|chown|chgrp|write_atomic|install -m')
  done
  # GARDE D'INSTRUMENT : les deux poses de 48-forge-host au moins
  [ "$poses" -ge 2 ] || { echo "MUR 1 — $poses pose(s) de secret d'autorite lue(s) : l'instrument ne voit plus les ecrivains" >&2; return 1; }
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


@test "MUR 5: le deck ne se depose pas sur une identite partagee — ni nobody, ni nogroup" {
  # son compte, le défaut de ce compte et le groupe de son secret : service_accounts.bats et le MUR 13 de variable_walls.bats
  local landing="$REPO/runtime/services/console-landing.sh"
  [ -r "$landing" ]
  code_of "$landing" | grep -q 'setpriv'
  absent 'reuid nobody' "$landing"
  absent 'regid nogroup' "$landing"
}

@test "MUR 5 ter: lcars-console n'a AUCUN membre declare — il s'accorde a l'exec, jamais par adhesion" {
  local f
  for f in "${CODE[@]}"; do
    absent 'ensure_member.*(lcars-console|PROV_CONSOLE_GROUP)' "$f"
    absent 'usermod.*-aG.*(lcars-console|PROV_CONSOLE_GROUP)' "$f"
  done
}

@test "MUR 4: le detenteur des secrets n'a AUCUN privilege noyau dans le conteneur — le service y est depose par setpriv" {
  # sur le poste, l'unité porte User= et son compte est posé : modules.d/64-services.bats et service_accounts.bats le jouent
  local entry="$REPO/runtime/services/container/boot.sh"
  [ -r "$entry" ]
  # la commande lancée, continuations jointes : le setpriv vers le détenteur porte l'exécuteur lui-même
  code_of "$entry" | sed -e :a -e '/\\$/N; s/\\\n//; ta' \
    | grep -qE 'setpriv[^;|&]*--reuid "\$LCARS_AUTHORITY_USER"[^;|&]*catalogue-executor\.py'
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
