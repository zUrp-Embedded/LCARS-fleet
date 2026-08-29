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
