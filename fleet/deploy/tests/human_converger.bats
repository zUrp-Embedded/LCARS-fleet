#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/human_converger.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for docker/human-converger.sh — l'ADMISSION, et elle seule
#
# CE QUI EST EPINGLE, ET POURQUOI CE N'EST PAS DE LA PARANOIA. Ce convergeur cree des users Linux a
# partir de noms choisis par des inconnus sur une page d'inscription ouverte. Les deux alphabets ne
# coincident pas, et c'est MESURE le 2026-08-12 sur l'image et sur Gitea 1.26.1 :
#
#   · `useradd` est BEAUCOUP plus permissif qu'on ne l'imagine — `Bob`, `1bob`, `bob@x`, `bob.`,
#     `bob$` passent tous. Il ne refuse que : > 32 caracteres, un espace, et un `-` initial — et ce
#     dernier ne part meme pas en refus de nom mais en PARSING D'OPTION (`useradd -bob` a rendu
#     « invalid base directory 'ob' »). C'est une injection d'argument, pas une coquille.
#   · Gitea refuse `_bob`, `bob$`, `bob@x`, `-bob`, `bob.`, `bob..x` — mais ACCEPTE `admin`, `b`,
#     `1bob`, et un nom de 33 caracteres que `useradd` refusera.
#
# Le danger n'est donc pas que Linux soit etroit : c'est que la forge laisse passer des noms qui
# COLLISIONNENT avec des comptes systeme, et des noms trop longs pour aboutir. Ces tests sont le
# verrou de cette frontiere. Ils sourcent le script (garde de sourcing) : aucune boucle, aucun
# reseau, aucun user cree.

setup() {
  SUT="$BATS_TEST_DIRNAME/../docker/human-converger.sh"
  export SUT
  [ -f "$SUT" ]
  PASSWD_FILE="$BATS_TEST_TMPDIR/passwd"
  PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  cat > "$PASSWD_FILE" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
sshd:x:100:65534::/run/sshd:/usr/sbin/nologin
lcars:x:1000:1000::/home/lcars:/bin/bash
EOF
  echo "UID_MIN			 1000" > "$PASSWD_DEFS"
  export PASSWD_FILE PASSWD_DEFS
}

# Helper: source the SUT in a fresh shell and run a predicate on <login>.
admits() { # admits <login>  -> exit 0 if the converger would create that user
  run bash -c "
    set -euo pipefail
    export PASSWD_FILE='$PASSWD_FILE' PASSWD_DEFS='$PASSWD_DEFS'
    source '$SUT'
    reserved '$1' && exit 1
    valid_login '$1' || exit 1
    exit 0"
}

# ─── le garde de sourcing ───────────────────────────────────────────────────────────────────────

@test "sourcer le convergeur ne lance NI preflight NI boucle (sinon ces tests pendraient)" {
  run bash -c "set -euo pipefail; source '$SUT'; type -t valid_login; type -t reserved"
  [ "$status" -eq 0 ]
  [[ "$output" == *function*function* ]]
}

# ─── ce qui passe ───────────────────────────────────────────────────────────────────────────────

@test "les logins ordinaires passent" {
  for n in bob zoe bob-x bob_x bob.dupont 1bob b Z9; do
    admits "$n"
    [ "$status" -eq 0 ] || { echo "refuse a tort: $n"; return 1; }
  done
}

@test "la casse est conservee VERBATIM — le deck compare preferred_username a /etc/passwd" {
  # Minusculiser ici casserait la jointure : Gitea rend le login tel qu'il a ete saisi, et
  # `Bob` cote forge doit trouver `Bob` cote passwd. (Gitea etant insensible a la casse a
  # l'inscription, deux comptes ne peuvent pas differer que par elle.)
  admits "Bob"
  [ "$status" -eq 0 ]
}

# ─── ce qui est REFUSE, et chaque refus a sa raison mesuree ──────────────────────────────────────

@test "un `-` initial est refuse : useradd le lirait comme une OPTION, pas comme un nom" {
  admits -- "-bob"
  [ "$status" -eq 1 ]
}

@test "les caracteres hors alphabet Gitea sont refuses (useradd, lui, les accepterait)" {
  for n in 'bob$' 'bob@x' '_bob' 'bo b' 'bob;rm' 'bob/x' 'bob*'; do
    admits "$n"
    [ "$status" -eq 1 ] || { echo "accepte a tort: $n"; return 1; }
  done
}

@test "un point final ou double est refuse (Gitea les refuse deja, useradd non)" {
  admits "bob."
  [ "$status" -eq 1 ]
  admits "bob..x"
  [ "$status" -eq 1 ]
}

@test "au-dela de 32 caracteres : Gitea accepte, useradd refuse — on refuse AVANT" {
  admits "$(printf 'a%.0s' $(seq 1 32))"
  [ "$status" -eq 0 ]
  admits "$(printf 'a%.0s' $(seq 1 33))"
  [ "$status" -eq 1 ]
}

@test "un login vide est refuse" {
  admits ""
  [ "$status" -eq 1 ]
}

# ─── les noms reserves : la denylist se CALCULE ──────────────────────────────────────────────────

@test "un compte systeme (uid < UID_MIN) n'est JAMAIS adopte" {
  # `admin` est accepte par Gitea (mesure) ; si un jour l'image porte un compte `admin`, l'adopter
  # lui donnerait un home et un shell fleet. La liste vient de /etc/passwd, pas d'un tableau en dur.
  for n in root daemon sshd; do
    admits "$n"
    [ "$status" -eq 1 ] || { echo "adopte a tort: $n"; return 1; }
  done
}

@test "un humain deja present (uid >= UID_MIN) n'est PAS reserve — il est juste deja converge" {
  admits "lcars"
  [ "$status" -eq 0 ]
}

@test "le compte SYSTEME de la fleet est refuse — il EST membre de la team humans (mesure)" {
  admits "lcars-system"
  [ "$status" -eq 1 ]
}

@test "les comptes de ROLE sont refuses, quelle que soit la casse" {
  for n in fleet_qualifier system_architect FLEET_SCRIBE; do
    admits "$n"
    [ "$status" -eq 1 ] || { echo "adopte a tort: $n"; return 1; }
  done
}

# ─── fail-closed a l'execution ──────────────────────────────────────────────────────────────────

@test "sans FORGE_BASE_URL : exit 2 et un message, jamais une boucle muette" {
  run env -u FORGE_BASE_URL bash "$SUT" --once
  [ "$status" -eq 2 ]
  [[ "$output" == *"FORGE_BASE_URL"* ]]
}

@test "token systeme illisible : exit 2, et le message nomme le fichier" {
  run env FORGE_BASE_URL=http://forge:3000 FORGE_TOKEN_FILE=/nope/nothing bash "$SUT" --once
  [ "$status" -eq 2 ]
  [[ "$output" == *"/nope/nothing"* ]]
}
