#!/usr/bin/env bats
# SOURCE: LCARS-bob
# AUTHOR: bob
# STARDATE: 2026-08-30
# STATUS: murs d'idiomes — la forme fragile ne revient pas une fois le code corrige
#
# Chaque mur remplace un commentaire qui defendait le code contre une simplification : le
# commentaire disait « ne fais pas ca », le mur le mesure. Il grep le CODE seul, jamais la prose.

load refute

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/.."
  mapfile -t SOURCES < <(ls "$DEPLOY"/modules.d/*.sh "$DEPLOY"/lib/*.sh "$DEPLOY"/provision)
  [ "${#SOURCES[@]}" -ge 28 ]
}

code() { grep -vE '^[[:space:]]*#' "$1"; }   # une ligne qui COMMENCE par # est de la prose

@test "MUR I1: write_atomic n'est jamais nourri par une substitution de processus" {
  # `write_atomic … < <(fn)` : si `fn` echoue, `cat` lit un flux vide, le fichier est ecrit vide et
  # le rc est 0. La forme sure capture d'abord : `body="$(fn)" || refus ; write_atomic … <<<"$body"`.
  local f hits=0
  for f in "${SOURCES[@]}"; do
    if code "$f" | grep -qE 'write_atomic[^|]*< <\('; then
      echo "MUR I1 rompu — $f : write_atomic nourri par < <( )" >&2; hits=$((hits+1))
    fi
  done
  [ "$hits" -eq 0 ]
  # le mur mord : la forme interdite, presentee au meme grep, est vue
  echo '  write_atomic "$f" 0644 root < <(body)' | grep -qE 'write_atomic[^|]*< <\('
}

@test "MUR I1bis: write_atomic n'est jamais la cible d'un pipe" {
  # `fn | write_atomic` : le dernier element d'un pipeline tourne dans un sous-shell, les compteurs
  # p_fail/p_chg de write_atomic y meurent. Redirection ou here-string, jamais un pipe.
  local f hits=0
  for f in "${SOURCES[@]}"; do
    if code "$f" | grep -qE '(^|[^|])\|[[:space:]]*write_atomic'; then
      echo "MUR I1bis rompu — $f : write_atomic en aval d'un pipe" >&2; hits=$((hits+1))
    fi
  done
  [ "$hits" -eq 0 ]
  echo '  body_fn | write_atomic "$f" 0644' | grep -qE '(^|[^|])\|[[:space:]]*write_atomic'
  # et un `||` (repli) n'est pas un pipe : le mur ne le prend pas pour tel
  refute grep -qE '(^|[^|])\|[[:space:]]*write_atomic' <<<'  x || write_atomic "$f" 0644'
}

@test "MUR I2: aucun jeton de forge ne passe par argv — forge_curl le porte sur stdin" {
  # `-H "Authorization: token $tok"` met le jeton dans la ligne de commande, lisible dans /proc de
  # tout l'hote pendant l'appel (cicatrice 6-141). La lib porte `forge_curl`, qui le passe par
  # `-K -`. Un module qui a besoin d'un en-tete d'autorisation l'appelle, il ne refait pas curl.
  local f hits=0
  for f in "${SOURCES[@]}"; do
    if code "$f" | grep -qE -- '-H ["'"'"']?Authorization: token'; then
      echo "MUR I2 rompu — $f : jeton en argv" >&2; hits=$((hits+1))
    fi
  done
  [ "$hits" -eq 0 ]
  echo '  curl -s -H "Authorization: token $tok" "$url"' | grep -qE -- '-H ["'"'"']?Authorization: token'
  # la forme sure — un en-tete ecrit dans une config lue sur stdin — n'est pas prise pour la fragile
  refute grep -qE -- '-H ["'"'"']?Authorization: token' <<<'  printf '"'"'header = "Authorization: token %s"\n'"'"' "$tok" | curl -K - "$url"'
}

# Derniere instruction d une fonction : `[[ … ]] && cmd` sans `||`. Sous set -e, le rc du test
# devient celui de la fonction, et un appelant qui capture par affectation — `x="$(f)"` — meurt sans
# verdict. Un PREDICAT (nom en `_ok`) est exempte : son rc EST son contrat, ses appelants sont des if.
I3_AWK='
  FNR==1 { fn="" }
  /^[a-z_][a-z0-9_]*\(\)[ \t]*\{/ { fn=$1; sub(/\(\).*/, "", fn); last=""; next }
  fn!="" && /^\}/ {
    if (last ~ /^[ \t]*\[\[.*\]\][ \t]*&&[ \t]/ && last !~ /\|\|/ && fn !~ /_ok$/) print FILENAME ": " fn
    fn=""; next
  }
  fn!="" && !/^[ \t]*(#|$)/ { last=$0 }
'

@test "MUR I3: aucune fonction ne finit sur [[ … ]] && cmd — son rc tuerait l appelant qui l affecte" {
  local hits
  hits="$(awk "$I3_AWK" "${SOURCES[@]}")"
  [ -z "$hits" ] || { echo "MUR I3 rompu —" >&2; echo "$hits" >&2; false; }
  # le mur mord : une fonction fautive est vue, un predicat _ok ne l est pas
  printf 'get_x() {\n  [[ -n "$x" ]] && echo "$x"\n}\nx_ok() {\n  [[ -x "$b" ]] && "$b" --version\n}\n' > "$BATS_TEST_TMPDIR/probe.sh"
  [ "$(awk "$I3_AWK" "$BATS_TEST_TMPDIR/probe.sh")" = "$BATS_TEST_TMPDIR/probe.sh: get_x" ]
}

@test "MUR I4: toute lecture de /dev/urandom est BORNEE par un head -c en tete de pipeline" {
  # `tr -dc … < /dev/urandom | head -c N` : tr lit un flux infini, head ferme le tuyau, tr meurt de
  # SIGPIPE — et sous pipefail c est le rc du pipeline. `head -c N /dev/urandom | …` en tete est la
  # seule forme qui termine par elle-meme. Et un `| head -c` EN AVAL d un flux fini peut encore
  # fermer le tuyau avant le dernier write de l amont — latent, il depend du buffer. La longueur se
  # borne par `cut -c1-N`, qui lit tout et ne ferme rien.
  local f l hits=0
  for f in "${SOURCES[@]}"; do
    while IFS= read -r l; do
      grep -qE 'head -c [0-9]+ /dev/urandom' <<<"$l" || { echo "MUR I4 rompu — $f : source non bornee : $l" >&2; hits=$((hits+1)); }
      grep -qE '\|[[:space:]]*head -c' <<<"$l" && { echo "MUR I4 rompu — $f : head -c en aval : $l" >&2; hits=$((hits+1)); }
    done < <(code "$f" | grep -E '(^|[[:space:]<])/dev/urandom' || true)   # une LECTURE, pas un message qui le cite
  done
  [ "$hits" -eq 0 ]
  refute grep -qE 'head -c [0-9]+ /dev/urandom' <<<'  tr -dc A-Z < /dev/urandom | head -c 10'
  grep -qE '\|[[:space:]]*head -c' <<<'  head -c 200 /dev/urandom | tr -dc A-Z | head -c 10'
}

@test "MUR I5: l architecture se demande a arch_tag — dpkg et uname -m ne se lisent dans aucun module" {
  # Trois modules mappaient dpkg vers le vocabulaire d une release, chacun a sa facon. Une seule
  # table, dans la lib. `00-preflight` garde son `uname -m` : il verifie le NOYAU (x86_64, aarch64),
  # pas le nom d un tarball — l exemption est nommee, pas devinee.
  local f hits=0
  for f in "$DEPLOY"/modules.d/*.sh; do
    if code "$f" | grep -q 'dpkg --print-architecture'; then echo "MUR I5 rompu — $f : dpkg" >&2; hits=$((hits+1)); fi
    [[ "$f" == */00-preflight.sh ]] && continue
    if code "$f" | grep -q 'uname -m'; then echo "MUR I5 rompu — $f : uname -m" >&2; hits=$((hits+1)); fi
  done
  [ "$hits" -eq 0 ]
  code "$DEPLOY/lib/provision-lib.sh" | grep -q 'dpkg --print-architecture'
}
