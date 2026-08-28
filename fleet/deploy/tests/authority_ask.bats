#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/authority_ask.bats
# AUTHOR: bob
# STARDATE: 2026-08-25
# SUT: fleet/bin/lcars-authority-ask
#
# ─── CE QUI SE PROUVE ICI ───────────────────────────────────────────────────────────────────────
#
# Ce client est la SEULE voie par laquelle trois gestes d'operateur obtiennent un jeton de forge —
# `lcars publish run`, `lcars approve`, la boite de reception du siege. Son contrat tient en deux
# lignes, et les deux comptent autant :
#
#   sortie 0 : le jeton, SEUL, sur stdout
#   sortie 1 : RIEN sur stdout, une cause sur stderr
#
# ⚠ LA SECONDE MOITIE EST CELLE QUI CASSE EN SILENCE. Ses appelants font `… > "$fichier"` : une
# cause imprimee sur stdout deviendrait un « jeton » de trente mots, envoye a la forge, refuse en
# 401, et diagnostique comme une revocation. Chaque temoin de refus verifie donc que stdout est VIDE,
# pas seulement que le code de sortie est 1.
#
# Le double sert des reponses en dur : il ne simule pas la forge, il joue le PROTOCOLE. Ce qui se
# mesure est la lecture de la reponse par le client, pas la decision du service — celle-la a ses
# propres temoins, cote python.

# ⚠ `run --separate-stderr` EXIGE CETTE DECLARATION, ET SANS ELLE LES TEMOINS SONT FAUX PLUTOT QUE
# ROUGES. Par defaut, `run` FUSIONNE stderr dans `$output` : une assertion « stdout est vide » y
# lirait la cause imprimee sur stderr et rougirait sur un client parfaitement correct — ou, pire,
# passerait au vert sur un client qui imprime bien la cause sur stdout. Le contrat teste ici est
# precisement la SEPARATION des deux flux ; le harnais doit donc les separer aussi.
# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC2154 — `$stderr` est pose par `run --separate-stderr`, invisible a l'analyse statique
# shellcheck disable=SC2154

bats_require_minimum_version 1.5.0

setup() {
  SUT="${BATS_TEST_DIRNAME}/../../bin/lcars-authority-ask"
  [[ -x "$SUT" ]] || skip "SUT absent ou non executable: $SUT"
  command -v socat >/dev/null 2>&1 || command -v nc >/dev/null 2>&1 \
    || skip "ni socat ni nc sur cette machine — le client n'a aucun transport"

  SOCK="$BATS_TEST_TMPDIR/roles.sock"
  REPLY_FILE="$BATS_TEST_TMPDIR/reply"
}

teardown() {
  [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null
  wait "${SRV_PID:-}" 2>/dev/null
  return 0
}

# Le double. Une connexion, une reponse, puis il rend la main. La reponse vit dans un fichier pour
# que chaque temoin la pose lui-meme, sans avoir a reecrire le serveur.
#
# ⚠ `SILENCE` FERME SANS RIEN ECRIRE, ET CE CAS N'EST PAS DECORATIF : c'est exactement ce que fait
# un `socat` qui coupe avant la reponse — sortie VIDE, code de retour ZERO. Un succes muet, mesure
# au chantier precedent. Sans ce temoin, rien ne prouve que le client ne le lit pas comme un oui.
start_double() {
  printf '%s' "$1" > "$REPLY_FILE"
  python3 - "$SOCK" "$REPLY_FILE" <<'PY' &
import os, socket, sys
path, reply_file = sys.argv[1], sys.argv[2]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(4)
os.chmod(path, 0o666)
sys.stderr.write("READY\n"); sys.stderr.flush()
while True:
    conn, _ = srv.accept()
    conn.recv(4096)
    with open(reply_file) as fh:
        reply = fh.read()
    if reply != "SILENCE":
        conn.sendall((reply + "\n").encode())
    conn.close()
PY
  SRV_PID=$!
  # ATTENTE SUR LA SOCKET, PAS SUR UNE DUREE : un `sleep 0.2` est vert sur une machine au repos et
  # rouge sous charge, et le temoin qui rougirait ne serait pas celui qui a le defaut.
  local i=0
  while [[ ! -S "$SOCK" && $i -lt 100 ]]; do i=$((i + 1)); sleep 0.05; done
  [[ -S "$SOCK" ]] || { echo "le double n'a pas ouvert $SOCK" >&2; return 1; }
}

ask() { run --separate-stderr env LCARS_ROLES_SOCKET="$SOCK" "$SUT" "$@"; }

# ─── LE CHEMIN HEUREUX ──────────────────────────────────────────────────────────────────────────

@test "un jeton servi ressort SEUL sur stdout, en sortie 0" {
  start_double "gto_abc123"
  ask system_starfleet
  [ "$status" -eq 0 ]
  [ "$output" = "gto_abc123" ]
}

@test "le compte demande est bien celui qui part sur le fil" {
  # Sans ce temoin, un client qui enverrait toujours le meme nom passerait tous les autres.
  local seen="$BATS_TEST_TMPDIR/seen"
  python3 - "$SOCK" "$seen" <<'PY' &
import os, socket, sys
path, seen = sys.argv[1], sys.argv[2]
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path); srv.listen(4); os.chmod(path, 0o666)
conn, _ = srv.accept()
data = conn.recv(4096).decode()
open(seen, "w").write(data)
conn.sendall(b"tok\n"); conn.close()
PY
  SRV_PID=$!
  local i=0; while [[ ! -S "$SOCK" && $i -lt 100 ]]; do i=$((i + 1)); sleep 0.05; done

  ask fleet_reviewer
  [ "$status" -eq 0 ]
  [ "$(cat "$seen")" = "fleet_reviewer" ]
  # UNE LIGNE, ET RIEN DE PLUS : 14 caracteres + le saut. Le compte d'octets est ce qui distingue
  # « le bon nom a ete envoye » de « le bon nom a ete envoye, cadre correctement ».
  [ "$(wc -c < "$seen")" -eq 15 ]
}

# ─── LES REFUS : CODE 1, STDOUT VIDE, CAUSE SUR STDERR ──────────────────────────────────────────

@test "not_a_worker : stdout VIDE, et la cause parle de l'equipe humans" {
  start_double "FAIL:not_a_worker"
  ask system_starfleet
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"humans"* ]]
}

# ⚠ LE COUPLE DE TEMOINS QUI COMPTE LE PLUS, ET IL EST ICI. `no_authority` et `forge_unreachable`
# ont des remedes OPPOSES : le premier demande un geste d'admin et aucun reessai ne le repose ; le
# second se reessaie tel quel. Un client qui rendrait « pas de jeton » pour les deux enverrait la
# moitie des cas au mauvais geste — et c'est la separation de causes que tout le chantier defend.
@test "no_authority : stdout VIDE, et le remede n'est PAS « reessaie »" {
  start_double "FAIL:no_authority"
  ask system_starfleet
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"Aucun reessai"* ]]
  [[ "$stderr" != *"le geste se reessaie"* ]]
}

@test "forge_unreachable : stdout VIDE — une absence de reponse n'est pas un refus" {
  start_double "FAIL:forge_unreachable"
  ask system_starfleet
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"se reessaie"* ]]
  [[ "$stderr" == *"pas un refus"* ]]
}

@test "no_role_token : stdout VIDE, et la cause nomme le geste qui le repose" {
  start_double "FAIL:no_role_token"
  ask system_starfleet
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"provision apply"* ]]
}

# ⚠ LE CAS QUI SEPARE UN CLIENT D'UN TUYAU. Une cause que ce client ne connait pas vient d'un
# service d'un autre lot. La ranger dans une cause voisine ferait un diagnostic faux ; la laisser
# passer sur stdout en ferait un jeton.
@test "une cause INCONNUE est refusee, jamais rendue comme un jeton" {
  start_double "FAIL:cause_du_futur"
  ask system_starfleet
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # La cause brute est RENDUE a l'operateur, pas avalee : c'est la seule chose qui lui permettra de
  # rapprocher ce shell du service qui a parle.
  [[ "$stderr" == *"cause_du_futur"* ]]
  [[ "$stderr" == *"meme lot"* ]]
}

# ─── LES DEUX SILENCES ──────────────────────────────────────────────────────────────────────────

@test "une reponse VIDE n'est pas un oui — refus, stdout vide" {
  start_double ""
  ask system_starfleet
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"AUCUNE reponse"* ]]
}

@test "un service qui FERME sans repondre n'est pas un oui — le code de sortie du transport ne prouve rien" {
  start_double "SILENCE"
  ask system_starfleet
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"AUCUNE reponse"* ]]
}

@test "socket ABSENTE : la porte fermee se dit, et se distingue d'un refus" {
  run --separate-stderr env LCARS_ROLES_SOCKET="$BATS_TEST_TMPDIR/jamais.sock" "$SUT" system_starfleet
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # « Ce n'est pas un refus » EST l'assertion : sans elle, ce temoin ne distingue pas une unite
  # arretee d'une forge qui dit non, et l'operateur va chercher une autorisation manquante alors
  # qu'il lui manque un service.
  [[ "$stderr" == *"n'ecoute pas"* ]]
  [[ "$stderr" == *"pas un refus"* ]]
}

# ─── LE CADRAGE DU FIL ──────────────────────────────────────────────────────────────────────────
#
# ⚠ CE TEMOIN GARDE UNE FRONTIERE, PAS UN CONFORT. Un nom qui porte un saut de ligne enverrait DEUX
# lignes sur la socket, dont la seconde serait lue par le service comme une requete distincte. Le
# service revalide de son cote — il ne s'appuie sur personne — mais un client qui laisse l'appelant
# decider du cadrage du protocole est casse quoi qu'en fasse le serveur.
@test "un compte qui porte un saut de ligne est refuse AVANT d'atteindre la socket" {
  start_double "gto_abc123"
  ask $'system\nfleet_reviewer'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "un compte vide est refuse (usage), et ne rend pas 1 par accident" {
  run --separate-stderr env LCARS_ROLES_SOCKET="$SOCK" "$SUT" ""
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "zero argument est un usage, pas une demande" {
  run --separate-stderr env LCARS_ROLES_SOCKET="$SOCK" "$SUT"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}
