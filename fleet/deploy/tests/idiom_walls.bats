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

@test "MUR I6: comm ne se lit dans aucun module — set_diff trie lui-meme" {
  # `comm` exige des entrees triees et, sur GNU, ne le verifie pas : deux listes dans le mauvais
  # ordre rendent un resultat faux sans un mot. Sur uutils il le verifie — l instrument de la machine
  # de dev ne dit pas ce que fait la cible. Une seule table de difference, dans la lib.
  local f hits=0
  for f in "$DEPLOY"/modules.d/*.sh; do
    if code "$f" | grep -qE '\bcomm -'; then echo "MUR I6 rompu — $f" >&2; hits=$((hits+1)); fi
  done
  [ "$hits" -eq 0 ]
  code "$DEPLOY/lib/provision-lib.sh" | grep -qE '^set_diff\(\)'
}

@test "MUR I7: une valeur d un fichier d environnement se lit par env_field, jamais par un sed nu" {
  # `x="$(sed -n 's/^CLE=//p' "$f" | tail -n1)"` : sur un fichier absent sed rend 2, pipefail le
  # propage, l affectation echoue et set -e tue la fonction AVANT le if qui savait dire l absence.
  # Trois sites portaient la forme ; un seul avait son `|| true`.
  local f hits=0
  for f in "$DEPLOY"/modules.d/*.sh; do
    if code "$f" | grep -qE "sed -n ['\"]s/\^[A-Z_]+=//p['\"]"; then echo "MUR I7 rompu — $f" >&2; hits=$((hits+1)); fi
  done
  [ "$hits" -eq 0 ]
  echo '  x="$(sed -n '"'"'s/^LCARS_X=//p'"'"' "$f" | tail -n1)"' | grep -qE "sed -n ['\"]s/\^[A-Z_]+=//p['\"]"
}

@test "MUR I8: un fichier de jeton se lit par read_token ou forge_curl — jamais par une redirection nue" {
  # `tr < "$X_TOKEN_FILE" 2>/dev/null` : la redirection d'entree est appliquee AVANT le detournement
  # de stderr, et quand le fichier manque c'est le shell qui crie « No such file » sur le vrai
  # stderr. `{ …; } 2>/dev/null` le tait, mais cette forme ne tient que par un commentaire.
  local hits=0 f
  for f in "$BATS_TEST_DIRNAME"/../modules.d/*.sh; do
    if code "$f" | grep -qE '<[[:space:]]*"?\$[A-Za-z_]*TOKEN_FILE' || code "$f" | grep -qF "tr -d '[:space:]' <"; then echo "MUR I8 rompu — $f" >&2; hits=$((hits+1)); fi
  done
  [ "$hits" -eq 0 ]
}

@test "MUR I9: un temoin dont le code nomme une fonction du siege pose LCARS_SEAT_UID_FILE — il ne lit jamais celui de la machine" {
  # `prov_seat_uid` lit `/etc/lcars/seat.uid` AVANT `LCARS_SYSADMIN_UID`, et ce fichier existe sur
  # toute machine provisionnee. Un temoin sans decor y lit le siege reel — celui qui joue le gate —
  # et tout ce qu'il attend d'un humain « qui passe GUARD B » rougit au second run (banc .63,
  # 2026-08-30 : vert a l'install, rouge au re-run). Le scrub du shell_gate ne peut rien : c'est un
  # DEFAUT de chemin, pas une variable. Perimetre : le CODE des temoins (une ligne `#` ne lit rien).
  local f bad=0
  for f in "$BATS_TEST_DIRNAME"/*.bats; do
    [[ "$f" == */idiom_walls.bats ]] && continue
    grep -vE '^[[:space:]]*#' "$f" | grep -qE 'is_fleet_human|prov_seat_uid|fleet_humans|uid_floor' || continue
    grep -qE '^[[:space:]]*export LCARS_SEAT_UID_FILE=' "$f" || { echo "${f##*/} nomme une fonction du siege sans poser LCARS_SEAT_UID_FILE"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

@test "MUR I10: qui LIT PROV_DOCKER_BIN joue la sonde — sinon il passe une CLI VIDE a son delegue" {
  # `PROV_DOCKER_BIN` vaut la CHAINE VIDE tant que `docker_endpoint` n'a pas tourne
  # (`docker-endpoint.sh` la declare ainsi). Un module qui la lit sans sonder passe `DOCKER_BIN=""`,
  # son delegue retombe sur `${DOCKER_BIN:-docker}` — un `docker` nu, introuvable dans une VM WSL ou
  # rien n'installe de CLI. Banc WSL, 2026-08-30 : `49-forge-runner` refusait trois images
  # PRESENTES sur le daemon, et son propre commentaire promettait « la CLI RESOLUE ». Sur un Linux
  # natif le PATH porte `docker` (pose par le rail) : le defaut y est invisible.
  local f bad=0
  for f in "$BATS_TEST_DIRNAME"/../modules.d/*.sh "$BATS_TEST_DIRNAME"/../box "$BATS_TEST_DIRNAME"/../accept; do
    [[ -f "$f" ]] || continue
    code "$f" | grep -q 'PROV_DOCKER_BIN' || continue
    code "$f" | grep -qE 'docker_endpoint' \
      || { echo "${f##*/} lit PROV_DOCKER_BIN sans jouer docker_endpoint"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}
