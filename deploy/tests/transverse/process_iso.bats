#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/transverse/process_iso.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: bats tests — l'ISO des PROCESSUS : ce qui TOURNE apres le boot, des deux cotes

# shellcheck disable=SC2016

load ../refute

setup() {
  ENTRY="$BATS_TEST_DIRNAME/../../../runtime/services/container/boot.sh"
  SERVICES="$BATS_TEST_DIRNAME/../../modules.d/64-services.sh"
  CONVERGER="$BATS_TEST_DIRNAME/../../../runtime/services/human-converger.sh"
  [ -f "$ENTRY" ]
  [ -f "$SERVICES" ]
  [ -f "$CONVERGER" ]
}

code() { grep -vE '^\s*#' "$1"; }

# La table declarative de `64-services` : <composant>:<unit|driven-by>:<nom>
starters() { code "$SERVICES" | sed -n '/^STARTERS=(/,/^)/p' | grep -oE '"[^"]+"' | tr -d '"'; }

@test "la table STARTERS existe, et sa forme est du vocabulaire" {
  # ⚠ SANS TABLE, CE TEMOIN NE PEUT QUE CROIRE UNE PROSE. « celui-la est demarre ailleurs » n'est
  # pas verifiable ; une ligne `console.sh:driven-by:lcars-converger` l'est.
  local n s
  n="$(starters | wc -l)"
  [ "$n" -ge 3 ]
  while read -r s; do
    [[ "$s" =~ ^[a-z0-9._-]+:(unit|driven-by):[a-z0-9-]+$ ]] || { echo "entree malformee : $s"; return 1; }
  done < <(starters)
}

joined() { code "$1" | sed -e :a -e '/\\$/N; s/\\\n//; ta'; }
launch_body() { code "$ENTRY" | sed -n '/^launch() {/,/^}/p'; }

@test "ISO supervision : autant de sites d'appel a launch que d'unites declarees" {
  local units sites
  units="$(starters | grep -c ':unit:')"
  sites="$(joined "$ENTRY" | grep -cE '^[[:space:]]*launch ')"
  [ "$units" -ge 4 ]
  [ "$units" -eq "$sites" ] || {
    echo "$units composants ont une unite sur le rail poste, mais $sites passent par launch dans le conteneur"
    joined "$ENTRY" | grep -E '^[[:space:]]*launch ' | cut -c1-80
    return 1
  }
}

@test "ISO supervision : setsid ne vit QUE dans launch — rien ne se lance nu a cote" {
  local total inside
  total="$(code "$ENTRY" | grep -c 'setsid')"
  inside="$(launch_body | grep -c 'setsid')"
  [ "$inside" -ge 2 ]
  [ "$total" -eq "$inside" ] || {
    echo "setsid apparait $total fois dans le code, dont $inside dans launch() — un composant se lance hors de la seule porte qui supervise"
    return 1
  }
}

@test "la landing passe par launch AVEC --foreground — sans lui, la relance boucle" {
  joined "$ENTRY" | grep -qE "^[[:space:]]*launch .*console-landing\.sh --foreground" || {
    echo "la landing n'est pas lancee par launch avec --foreground :"
    joined "$ENTRY" | grep -n 'console-landing' | cut -c1-100
    return 1
  }
}

@test "ISO : chaque composant persistant de l'entrypoint a un DEMARREUR DECLARE" {
  local comp bad=0
  for comp in human-converger.sh console-landing.sh console.sh; do
    code "$ENTRY" | grep -q "$comp" || { echo "$comp n'est PAS lance par l'entrypoint — table perimee ?"; bad=1; continue; }
    starters | grep -q "^$comp:" || { echo "LANCE PAR L'ENTRYPOINT, AUCUN DEMARREUR DECLARE : $comp"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

@test "ISO inverse : chaque demarreur declare designe une unite POSEE, ou un pilote qui existe" {
  # Le sens qui attrape une table morte. Une ligne qui nomme une unite que `UNITS` ne pose pas est
  # aussi fausse qu'un composant sans demarreur — et elle se lit comme une garantie.
  local s comp kind name bad=0
  while IFS=: read -r comp kind name; do
    case "$kind" in
      unit)
        code "$SERVICES" | grep -qE "UNITS=\(.*$name" \
          || { echo "$comp declare l'unite $name, absente de UNITS"; bad=1; } ;;
      driven-by)
        code "$SERVICES" | grep -qE "UNITS=\(.*$name" \
          || { echo "$comp declare le pilote $name, absent de UNITS"; bad=1; } ;;
    esac
  done < <(starters)
  [ "$bad" -eq 0 ]
}

@test "le pilote APPELLE vraiment ce qu'il est cense piloter" {
  code "$CONVERGER" | grep -q 'ensure_all_consoles'
  code "$CONVERGER" | grep -qE '"\$CONSOLE" --all'
  # et il est appele PAR TOUR, pas seulement a l'enrolement
  code "$CONVERGER" | sed -n '/^converge_once()/,/^}/p' | grep -q 'ensure_all_consoles'
}

@test "l'alignement suit le LECTEUR du deck, pas l'equipe forge" {
  local console="$BATS_TEST_DIRNAME/../../../runtime/services/console.sh"
  local deck="$BATS_TEST_DIRNAME/../../../runtime/services/console-deck.py"
  code "$console" | grep -qE 'LCARS_CONSOLE_HUMANS:-.*console-humans\.sh'
  grep -qE 'LCARS_CONSOLE_HUMANS", "[^"]*console-humans\.sh' "$deck"
}

@test "le pilote est IDEMPOTENT — sinon il empile un ttyd par tour" {
  local console="$BATS_TEST_DIRNAME/../../../runtime/services/console.sh"
  code "$console" | grep -q 'console_alive'
  # et l'appel par tour ne contourne pas cette garde en retirant la socket
  code "$CONVERGER" | refute_out 'rm -f.*console\.sock'
}

@test "sshd n'est PAS dans la table : l'entrypoint le lance par exec, hors de la supervision" {
  code "$ENTRY" | grep -qE 'exec .*sshd'
  starters | refute_out '^sshd:'
}
