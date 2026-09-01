#!/usr/bin/env bats
# SOURCE: LCARS-bob
# AUTHOR: bob
# STARDATE: 2026-08-30
# STATUS: temoins de 30-wsl.sh — le module n'avait aucune suite

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  MOD="$BATS_TEST_DIRNAME/../modules.d/30-wsl.sh"
  [ -f "$MOD" ]
}

# ─── LE TAMPON DE wsl.conf — LA SECONDE COUCHE, ET ELLE N ETAIT PAS LUE ─────────────────────────
#
# ⚠ `desired_wsl_conf > "$wsl_tmp"` ETAIT NU. `write_atomic` garde desormais le rc de son propre
# `cat`, mais elle ne peut rien dire d un tampon qu un AUTRE geste a tronque avant elle : un contenu
# vide est un contenu valide de son point de vue.
#
# Et c est le seul objet du rail dont l echec silencieux ROUVRE une porte au lieu d en fermer une :
# un `/etc/wsl.conf` vide laisse `[interop] enabled` a son defaut, c est-a-dire OUVERT, sur une
# machine dont le module vient d annoncer la frontiere armee.
#
# ⚠ LE FRAGMENT EST EXTRAIT DU MODULE, PAS RECOPIE. Un temoin qui recopie le geste qu il mesure
# mesure sa copie — et reste vert quand l original derive.
# ⚠ `cat`, PAS `printf` — ET LA DIFFERENCE EST MESUREE. Le vrai `desired_wsl_conf` rend son contenu
# par `cat <<EOF`, donc un PROCESS EXTERNE : sous `ulimit -f 0` c est `cat` qui meurt sur SIGXFSZ et
# le shell lit son rc. Une doublure en `printf` (builtin) fait tuer LE SHELL LUI-MEME — rc 153, la
# garde jamais atteinte, et le temoin mesure alors le mode de mort de sa propre doublure au lieu du
# code audite.
harnais_wsl_tmp() { # harnais_wsl_tmp <contenu rendu par desired_wsl_conf> [ulimit]
  sed -n '/^  wsl_tmp="\$(mktemp/,/^  rm -f "\$wsl_tmp"$/p' "$MOD" > "$BATS_TEST_TMPDIR/frag.sh"
  [ -s "$BATS_TEST_TMPDIR/frag.sh" ] || { echo "extraction du fragment ratee"; return 1; }
  printf '%s' "$1" > "$BATS_TEST_TMPDIR/contenu"
  cat > "$BATS_TEST_TMPDIR/harnais.sh" <<HARNAIS
set -euo pipefail
p_fail() { echo "FAIL \$*"; }
p_warn() { :; }
p_ok()   { :; }
verdict_apply() { exit 9; }
write_atomic() { echo "WRITE_ATOMIC APPELE"; }
c_drive_open() { return 1; }
desired_wsl_conf() { command cat "\$TMPDIR/contenu"; }
WSL_CONF="\$TMPDIR/wsl.conf"
$2
source "\$TMPDIR/frag.sh"
echo "SUITE DU MODULE ATTEINTE"
HARNAIS
  run env TMPDIR="$BATS_TEST_TMPDIR" bash "$BATS_TEST_TMPDIR/harnais.sh"
}

@test "wsl.conf : un tampon dont l ecriture RATE ne devient jamais un wsl.conf pose" {
  # `ulimit -f 0` : aucun fichier ne peut grandir. `mktemp` cree son tampon de 0 octet, la
  # redirection meurt dessus. Le decor le plus proche du disque plein sans monter de FS.
  harnais_wsl_tmp '[boot]
systemd=true
' 'ulimit -f 0'
  [ "$status" -eq 9 ] || { echo "le module a CONTINUE (rc=$status) : $output"; return 1; }
  [[ "$output" != *"WRITE_ATOMIC APPELE"* ]] || { echo "un tampon rate a ete pose : $output"; return 1; }
  [[ "$output" != *"SUITE DU MODULE ATTEINTE"* ]]
}

@test "wsl.conf : un tampon VIDE est refuse — la frontiere ne s arme pas sur du vide" {
  # Distinct du precedent : ici la redirection REUSSIT, elle n ecrit simplement rien. C est le cas
  # que le rc seul ne peut pas voir.
  harnais_wsl_tmp '' ''
  [ "$status" -eq 9 ] || { echo "le module a CONTINUE (rc=$status) : $output"; return 1; }
  [[ "$output" == *"VIDE"* ]]
  [[ "$output" != *"WRITE_ATOMIC APPELE"* ]]
}

@test "wsl.conf : le chemin NOMINAL passe — les deux gardes n ont pas ferme la porte" {
  # ⚠ SANS CE TROISIEME, LES DEUX AUTRES SONT SATISFAITS PAR UN MODULE QUI NE POSE PLUS RIEN.
  harnais_wsl_tmp '[boot]
systemd=true
' ''
  [ "$status" -eq 0 ] || { echo "le chemin nominal ne passe plus (rc=$status) : $output"; return 1; }
  [[ "$output" == *"WRITE_ATOMIC APPELE"* ]]
  [[ "$output" == *"SUITE DU MODULE ATTEINTE"* ]]
}

@test "gpg_socket_mask_path : un humain SANS home rend vide et 0 — la sonde derive, elle ne meurt pas" {
  # `[[ -n "$home" ]] && echo …` rendait 1 sur un home vide ; check() fait `mask="$(…)"`, une
  # affectation, et set -e le tuait AVANT le if qui savait dire la derive. Mur I3 (idiom_walls).
  eval "$(sed -n '/^gpg_socket_mask_path()/,/^}/p' "$MOD")"
  human_home() { echo ""; }
  run gpg_socket_mask_path
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  human_home() { echo /home/x; }
  run gpg_socket_mask_path
  [ "$status" -eq 0 ]
  [ "$output" = "/home/x/.config/systemd/user/gpg-agent-ssh.socket" ]
}
