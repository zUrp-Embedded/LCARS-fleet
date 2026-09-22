#!/usr/bin/env bats
# SOURCE: runtime/test/services/human.d/human_protocol.bats
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: bats tests for services/lib/human-protocol.sh — la frontiere systeme/humain, fail-closed
#
# CE QUE CES TEMOINS FERMENT (⚖ user 2026-09-05, lot 14 : solution A + C + E de
# `17-DEUX-OUVERTS.md`). Sept lecteurs repondaient a « cet uid est-il un humain de fleet ? » ; le
# BEAM refuse de booter sur un login.defs illisible (runtime.exs, R-no-uid-min, « AUCUN REPLI SUR
# 1000, et c'est delibere »), `console-humans.sh` ne rend aucune liste — et ce protocole, le
# convergeur, `bin/fleet` et la lib de l'installeur devinaient 1000. Le protocole devient LA regle
# cote shell : UID_MIN <= uid <= UID_MAX, siege exclu ; bornes illisibles = personne n'est humain,
# et le remede — le fichier — est dit UNE FOIS.
#
# Le protocole est SOURCE (jamais execute), avec un `id` de decor : zoe 1001, admiral 1000 (le
# siege), svc 999, nobody 65534. Aucun compte de la machine n'est lu.

load ../../support/refute

setup() {
  PROTO="$BATS_TEST_DIRNAME/../../../services/lib/human-protocol.sh"
  [ -f "$PROTO" ]
  export LCARS_MODULE_PROTOCOL="$BATS_TEST_DIRNAME/../../../services/lib/module-protocol.sh"
  # Le protocole de module lit `forge.url` sous LCARS_PRIVATE_DIR : celui du decor, pas de la machine.
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/tokens"
  # Le siege : fichier absent (MUR I9), variable posee — admiral, 1000.
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/aucun-siege-pose/seat.uid"
  export LCARS_SYSADMIN_UID=1000
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  printf 'UID_MIN\t1000\nUID_MAX\t60000\n' > "$PASSWD_DEFS"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *zoe*) echo 1001 ;; *admiral*) echo 1000 ;; *svc*) echo 999 ;; *nobody*) echo 65534 ;; *) exit 1 ;; esac' \
    > "$BIN/id"
  chmod 0755 "$BIN/id"
}

proto() { # proto <script> — source le protocole (sujet : zoe) puis joue <script>, sous set -euo pipefail
  run bash -c "set -euo pipefail; export PATH='$BIN:$PATH' LCARS_LOGIN=zoe; . '$PROTO'; $1"
}

# ─── la regle, ses deux bornes et le siege ──────────────────────────────────────────────────────

@test "zoe (1001) est un humain de fleet ; svc (999) et admiral (le siege) ne le sont pas" {
  proto 'is_fleet_human zoe'
  [ "$status" -eq 0 ]
  proto 'is_fleet_human svc'
  [ "$status" -eq 1 ]
  proto 'is_fleet_human admiral'
  [ "$status" -eq 1 ]
}

@test "nobody (65534) n'est PAS un humain de fleet — la borne HAUTE est dans la regle (solution E)" {
  # Il est sur toute machine, superieur a UID_MIN et different du siege : la regle basse seule le
  # compte. `22-fleet-human.bats` le pinnait cote installeur ; le voici cote produit.
  proto 'is_fleet_human nobody'
  [ "$status" -eq 1 ]
  # Et c'est bien la BORNE qui l'ecarte, pas son nom : un UID_MAX au-dessus de lui le laisse passer.
  printf 'UID_MIN\t1000\nUID_MAX\t70000\n' > "$PASSWD_DEFS"
  proto 'is_fleet_human nobody'
  [ "$status" -eq 0 ]
}

@test "sans argument, le sujet est LCARS_LOGIN ; un login inconnu de id rend non" {
  proto 'is_fleet_human'
  [ "$status" -eq 0 ]
  proto 'is_fleet_human inconnu'
  [ "$status" -eq 1 ]
}

# ─── bornes illisibles : refus, dit UNE FOIS, avec le remede ────────────────────────────────────

@test "login.defs ILLISIBLE : is_fleet_human rend 1 pour TOUT le monde — jamais 1000 par defaut" {
  # Fail-closed, la politique du BEAM (R-no-uid-min). Avec 1000 devine, zoe passait ; elle ne
  # passe plus tant que la frontiere n'est pas etablie.
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/nulle-part/login.defs"
  proto 'is_fleet_human zoe'
  [ "$status" -eq 1 ]
  proto 'is_fleet_human nobody'
  [ "$status" -eq 1 ]
}

@test "login.defs ILLISIBLE : le remede est dit UNE FOIS par processus, et il nomme le fichier" {
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/nulle-part/login.defs"
  proto 'is_fleet_human zoe || true; is_fleet_human zoe || true; is_fleet_human nobody || true'
  [ "$status" -eq 0 ]
  [ "$(grep -c "n'est pas etablie" <<<"$output")" -eq 1 ]
  [[ "$output" == *"UID_MIN illisible dans $PASSWD_DEFS"* ]]
  [[ "$output" == *"pas par ce processus : repare $PASSWD_DEFS"* ]]
  # Le mot est celui du BEAM : « the bound is declared by the system, not by this process: fix … ».
  # Il vit dans GUARD B (Fleet.BootGuard), que config/runtime.exs appelle.
  local garde="$BATS_TEST_DIRNAME/../../../lib/fleet/boot_guard.ex"
  grep -q 'declared by the system, not by this process' "$garde"
  grep -q 'R-no-uid-min' "$garde"
}

@test "UID_MAX ABSENT du fichier : la frontiere n'est pas etablie non plus, et le message nomme UID_MAX" {
  # Une seule borne n'en fait pas deux : sans UID_MAX, `nobody` serait humain.
  printf 'UID_MIN\t1000\n' > "$PASSWD_DEFS"
  proto 'is_fleet_human zoe'
  [ "$status" -eq 1 ]
  [[ "$output" == *"UID_MAX illisible dans $PASSWD_DEFS"* ]]
}

@test "les bornes ne se lisent PAS dans l'environnement — UID_MIN=0 UID_MAX=99999 exportes ne desarment rien" {
  # « La frontiere obeirait a qui la franchit » (runtime.exs). Le protocole RE-ECRIT les deux
  # variables depuis le fichier a chaque lecture.
  export UID_MIN=0 UID_MAX=99999
  proto 'is_fleet_human svc'
  [ "$status" -eq 1 ]
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/nulle-part/login.defs"
  proto 'is_fleet_human zoe'
  [ "$status" -eq 1 ]
  [[ "$output" == *"n'est pas etablie"* ]]
}

@test "uid_bounds expose UID_MIN et UID_MAX a qui enumere — et ne pose RIEN quand elles manquent" {
  proto 'uid_bounds; echo "min=$UID_MIN max=$UID_MAX why=[$UID_BOUNDS_WHY]"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"min=1000 max=60000 why=[]"* ]]
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/nulle-part/login.defs"
  proto 'uid_bounds && exit 9; echo "min=[$UID_MIN] max=[$UID_MAX]"; [[ -n "$UID_BOUNDS_WHY" ]]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"min=[] max=[]"* ]]
}

@test "une borne NON NUMERIQUE est illisible — elle ne se compare pas, elle se refuse" {
  # `(( uid >= abc ))` lirait `abc` comme un NOM de variable — meme cicatrice que `seat_uid` dans
  # `bin/fleet`. Le protocole valide les deux bornes avant toute arithmetique.
  printf 'UID_MIN\tabc\nUID_MAX\t60000\n' > "$PASSWD_DEFS"
  proto 'is_fleet_human zoe'
  [ "$status" -eq 1 ]
  [[ "$output" == *"UID_MIN illisible"* ]]
}

# ─── le sujet : un module le nomme ou meurt, un hote le declare ─────────────────────────────────

@test "sans LCARS_LOGIN, un module meurt a la source — on ne devine pas l'utilisateur courant" {
  run bash -c "set -euo pipefail; . '$PROTO'; echo SOURCE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"LCARS_LOGIN non pose"* ]]
  [[ "$output" != *"SOURCE"* ]]
}

@test "un HOTE declare (LCARS_HUMAN_PROTOCOL_HOST=1) source sans sujet — et sans sujet, rien ne designe l'utilisateur courant" {
  # Le convergeur est l'hote : il emprunte la regle et nomme le login a chaque appel. Sans login
  # nomme, `is_fleet_human` rend non et `human_home` rien — jamais root, sous le convergeur.
  run bash -c "set -euo pipefail; export PATH='$BIN:$PATH'; LCARS_HUMAN_PROTOCOL_HOST=1; . '$PROTO'
    is_fleet_human zoe && echo ZOE_OUI
    is_fleet_human || echo SANS_SUJET_NON
    echo \"home=[\$(human_home)]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"ZOE_OUI"* ]]
  [[ "$output" == *"SANS_SUJET_NON"* ]]
  [[ "$output" == *"home=[]"* ]]
}

@test "siege NON DECLARE (ni fichier ni LCARS_SYSADMIN_UID) : personne n'est un humain, et le remede est dit UNE FOIS" {
  # Sans siege, on ne peut pas l'exclure : il passerait pour un humain. Meme politique que les bornes.
  unset LCARS_SYSADMIN_UID
  proto 'is_fleet_human zoe && echo OUI-zoe || echo NON-zoe; is_fleet_human zoe || true; is_fleet_human admiral && echo OUI-admiral || echo NON-admiral'
  [ "$status" -eq 0 ]
  [[ "$output" == *"NON-zoe"* ]]
  [[ "$output" == *"NON-admiral"* ]]
  refute_out 'OUI-' <<<"$output"
  [ "$(grep -c "le siège n'est pas déclaré" <<<"$output")" -eq 1 ]
  [[ "$output" == *"$LCARS_SEAT_UID_FILE"* ]]
  [[ "$output" == *"deploy/workstation up"* ]]
  [[ "$output" == *"deploy/container config"* ]]
}

@test "siege declare par LCARS_SYSADMIN_UID seul (fichier absent) : la regle s'applique, sans message" {
  proto 'is_fleet_human zoe && echo OUI-zoe; is_fleet_human admiral || echo NON-admiral'
  [ "$status" -eq 0 ]
  [[ "$output" == *"OUI-zoe"* ]]
  [[ "$output" == *"NON-admiral"* ]]
  refute_out 'siège' <<<"$output"
}
