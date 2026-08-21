#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/fleet_human.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: bats tests for 65-fleet-human — l'humain de fleet du poste, et le plancher d'uid qui le definit
#
# CE QUE CES TEMOINS FERMENT. Le rail poste installait un runtime que personne ne pouvait lancer, et
# il se contredisait en le faisant. Mesure du 2026-08-21, install a froid sur machine dediee, humain
# = l'operateur (uid 1000) :
#
#     POSÉ  20-groups:   lordzurp ∈ fleet
#     POSÉ  70-human:    ~/.lcars, ~/pods, env  →  pour lordzurp
#     OK    75-projects: lordzurp n'est pas un humain de fleet (compte systeme ou sysadmin)
#
# GUARD B (`bin/fleet_v2`) et `is_fleet_human` appliquent la meme regle : `uid >= UID_MIN` ET
# `uid != LCARS_SYSADMIN_UID`. Or le premier utilisateur d'une Linux ou d'une WSL standard EST uid
# 1000. La regle « uid >= 1001 » n'etait ecrite que pour la BOITE.
#
# ⚠ CES TEMOINS NE CREENT AUCUN COMPTE, et c'est delibere : `useradd` demande root et laisserait
# des comptes derriere lui sur la machine qui joue les tests. Ce qui se mesure ici est le CALCUL —
# le plancher d'uid, le choix du premier libre, et les verdicts de `check` — c'est-a-dire tout ce
# qui, faux, serait silencieux. La creation elle-meme est un `useradd` nu, et un `useradd` qui
# echoue le DIT.

setup() {
  # Le decor possede l'environnement : ces temoins jugent ce que le module fait d'un environnement
  # DONNE (plancher d'uid, siege, groupe). L'heriter reviendrait a juger la machine qui les joue.
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)

  SRC="$BATS_TEST_DIRNAME/../modules.d/65-fleet-human.sh"
  [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export PROVISION_MODULE=65-fleet-human
  export PROV_FLEET_GROUP="$(id -gn)"

  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  # `login.defs` du decor : le plancher est une DONNEE du systeme, donc il se pose ici.
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  printf 'UID_MIN 1000\nUID_MAX 60000\n' > "$PASSWD_DEFS"

  MOD="$BATS_TEST_TMPDIR/mod.sh"
  sed '/^case "${1:?usage/,$d' "$SRC" > "$MOD"
}

mod() { run bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; $1"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  run head -8 "$SRC"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
}

@test "le plancher est JUSTE AU-DESSUS du siege — jamais l'uid du siege lui-meme" {
  # C'est toute la faute : `useradd` sans `-u` part de UID_MIN et rendrait 1000 s'il est libre,
  # c'est-a-dire exactement le compte que GUARD B refuse.
  LCARS_SYSADMIN_UID=1000 mod 'fleet_uid_floor'
  [ "$status" -eq 0 ]
  [ "$output" = "1001" ]
}

@test "le plancher SUIT le siege quand on le deplace — il n'est pas ecrit en dur" {
  LCARS_SYSADMIN_UID=1500 mod 'fleet_uid_floor'
  [ "$status" -eq 0 ]
  [ "$output" = "1501" ]
}

@test "un UID_MIN plus haut que le siege l'emporte — les deux regles valent, pas une" {
  # `is_fleet_human` exige les DEUX : `uid >= UID_MIN` ET `uid != SYSADMIN_UID`. Un plancher qui ne
  # regarderait que le siege rendrait un uid que le systeme classe encore comme systeme.
  printf 'UID_MIN 5000\n' > "$PASSWD_DEFS"
  LCARS_SYSADMIN_UID=1000 mod 'fleet_uid_floor'
  [ "$status" -eq 0 ]
  [ "$output" = "5000" ]
}

@test "login.defs ILLISIBLE ne tue pas le module — le plancher retombe sur le defaut, en silence sur" {
  # `|| true` load-bearing, meme motif que dans la lib : une garde qui s'evanouit sur une lecture
  # ratee est pire que pas de garde. Ici l'effet serait un module MORT avant son verdict (rc 3).
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/absent.defs"
  LCARS_SYSADMIN_UID=1000 mod 'fleet_uid_floor'
  [ "$status" -eq 0 ]
  [ "$output" = "1001" ]
}

@test "le premier uid LIBRE est cherche au-dessus du plancher, jamais en dessous" {
  # On ne mesure pas contre le /etc/passwd de la machine : on remplace `getent` par une doublure qui
  # declare 1001 et 1002 pris. Sinon ce temoin dirait la composition du poste qui le joue.
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  cat > "$BIN/getent" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == passwd ]] || exit 2
case "$2" in 1001|1002) exit 0 ;; *) exit 2 ;; esac
FAKE
  chmod 0755 "$BIN/getent"
  PATH="$BIN:$PATH" LCARS_SYSADMIN_UID=1000 mod 'first_free_uid'
  [ "$status" -eq 0 ]
  [ "$output" = "1003" ]
}

@test "check: humain ABSENT → drift, et il dit la CONSEQUENCE (personne pour lancer la fleet)" {
  # Le motif importe plus que le fait : « le compte manque » n'apprend rien, « le poste n'a personne
  # pour lancer la fleet » designe ce qu'on perd.
  PROV_FLEET_HUMAN="n-existe-pas-$$" mod 'check'
  [ "$status" -eq 1 ]     # check : 1 = DRIFT (le contrat INVERSE les codes entre check et apply)
  [[ "$output" == *"DRIFT"* ]]
  [[ "$output" == *"lancer la fleet"* ]]
}

@test "check: un humain que GUARD B REFUSE est un drift NOMMÉ, pas un compte qu'on deplace" {
  # Cas reel : quelqu'un cree le compte a la main sur l'uid du siege. Changer l'uid d'un compte
  # existant orphelinerait tout ce qu'il possede — on le DIT, on ne le repare pas dans son dos.
  LCARS_SYSADMIN_UID="$(id -u)" PROV_FLEET_HUMAN="$(id -un)" mod 'check'
  [ "$status" -eq 1 ]
  [[ "$output" == *"GUARD B refuse"* ]] || [[ "$output" == *"siège"* ]] || [[ "$output" == *"siege"* ]]
}

@test "TEMOIN: un humain qui PASSE GUARD B et porte le groupe est conforme" {
  # Sans ce pendant, un module qui deriverait TOUJOURS passerait les deux temoins ci-dessus (P-40).
  # Le compte qui joue les tests convient : uid >= UID_MIN, et on ecarte le siege de son uid.
  LCARS_SYSADMIN_UID=0 PROV_FLEET_HUMAN="$(id -un)" mod 'check'
  [ "$status" -eq 0 ]
  [[ "$output" == *"il peut lancer la fleet"* ]]
}
