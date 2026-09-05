#!/usr/bin/env bats
# SOURCE: deploy/tests/wsl_module.bats
# AUTHOR: bob
# STARDATE: 2026-08-30
# STATUS: temoins de 30-wsl.sh — le module n'avait aucune suite

load refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  MOD="$BATS_TEST_DIRNAME/../modules.d/30-wsl.sh"
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export PROVISION_MODULE=30-wsl
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
  # ⚠ UNE DOUBLURE DE `cat`, PAS `ulimit -f 0` — MEME LECON QUE `provision_lib`, ET ELLE A COUTE
  # HUIT HEURES. Une limite de taille de fichier posee dans un decor de temoin ne s arrete pas au
  # code audite : elle atteint tout ce que le harnais ecrit ensuite, et un `bats-exec-suite` qui ne
  # peut plus ecrire PEND au lieu d echouer. Ici la limite etait confinee a un bash fils, donc sans
  # doute inoffensive — mais « sans doute inoffensif » n est pas une mesure, et la version
  # deterministe ne coute rien de plus.
  mkdir -p "$BATS_TEST_TMPDIR/bin-cat"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/bin-cat/cat"
  chmod 0755 "$BATS_TEST_TMPDIR/bin-cat/cat"
  harnais_wsl_tmp '[boot]
systemd=true
' 'PATH="$TMPDIR/bin-cat:$PATH"'
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

# ─── LE credsStore QUE LA COUPURE DE L INTEROP REND MORT ────────────────────────────────────────
#
# ⚠ CE MODULE CASSE DOCKER, ET CE BLOC EST SA REPARATION. `/usr/bin/docker-credential-desktop.exe`
# est un LIEN vers un binaire Windows ; un `.exe` ne s execute sous WSL que par binfmt, que
# `wsl.conf` coupe quelques lignes plus bas. Apres le redemarrage, tout `docker pull`/`build` meurt
# sur « error getting credentials » — un message qui ne nomme ni l interop, ni le helper, ni le
# geste qui l a coupe.
#
# ⚠ ET LE DEFAUT NE SE VOIT PAS PENDANT L INSTALL : `wsl.conf` ne prend effet qu au redemarrage, qui
# vient APRES. La passe qui casse docker se termine en vert ; c est la SUIVANTE qui echoue. Mesure
# du 2026-09-02 : contourne A LA MAIN deux fois, sur deux bancs, avant d etre instruit — et le
# commentaire de contournement affirmait « c est l environnement, pas le code ».
#
# ⚠ EDITER UN FICHIER DE L HUMAIN EST LEGITIME ICI, ET SEULEMENT ICI : ce module est `APPLY-ON: wsl`,
# et une instance WSL est du CATTLE. Le meme geste sur un linux natif dedie demanderait la prudence
# appliquee a `/etc/skel/.bashrc`.
harnais_creds() { # harnais_creds <contenu de config.json | VIDE pour aucun fichier>
  sed -n '/^  local dcfg=/,/^  fi$/p' "$MOD" > "$BATS_TEST_TMPDIR/frag-creds.sh"
  [ -s "$BATS_TEST_TMPDIR/frag-creds.sh" ] || { echo "extraction du fragment ratee"; return 1; }
  local h="$BATS_TEST_TMPDIR/home"; rm -rf "$h"; mkdir -p "$h/.docker"
  [ -n "$1" ] && printf '%s' "$1" > "$h/.docker/config.json"
  cat > "$BATS_TEST_TMPDIR/h-creds.sh" <<HARNAIS
set -euo pipefail
. "\$PROVISION_LIB"
p_fail() { echo "FAIL \$*"; }
p_warn() { echo "WARN \$*"; }
verdict_apply() { exit 9; }
PROV_HUMAN="\$(id -un)"
home="$h"
enveloppe() {
  source "\$BATS_TEST_TMPDIR/frag-creds.sh"
}
enveloppe
echo "APRES:\$(cat "$h/.docker/config.json" 2>/dev/null || echo '<pas de fichier>')"
HARNAIS
  run env BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" PROVISION_LIB="$PROVISION_LIB" \
    bash "$BATS_TEST_TMPDIR/h-creds.sh"
}

@test "credsStore : retire quand il designe le helper Windows" {
  harnais_creds '{"credsStore":"desktop.exe"}'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'APRES:{}'* ]] || { echo "pas retire : $output"; return 1; }
  [[ "$output" == *"credsStore retiré"* ]]
  [[ "$output" == *"docker login"* ]]   # le refus NOMME la consequence et la sortie
}

@test "credsStore : les AUTRES cles survivent — on retire une cle, pas un fichier" {
  harnais_creds '{"auths":{"reg.example":{"auth":"eyJ="}},"credsStore":"desktop.exe"}'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'"auths"'* ]] || { echo "les auths ont ete perdues : $output"; return 1; }
  [[ "$output" == *'reg.example'* ]]
  # ⚠ ON VISE LA LIGNE `APRES:`, PAS LA SORTIE ENTIERE : le message du module CONTIENT le mot
  # « credsStore » — le chercher partout faisait rougir le temoin sur la propre annonce du geste.
  local apres; apres="$(printf '%s' "$output" | sed -n 's/^APRES://p')"
  [[ "$apres" != *credsStore* ]] || { echo "credsStore survit dans le fichier : $apres"; return 1; }
}

@test "credsStore : rien a faire si la cle n y est pas — le fichier n est pas touche" {
  harnais_creds '{"auths":{}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'APRES:{"auths":{}}'* ]]
  [[ "$output" != *"credsStore retiré"* ]] || { echo "geste annonce sans objet : $output"; return 1; }
}

@test "credsStore : aucun fichier, aucun geste — on n en fabrique pas un" {
  harnais_creds ''
  [ "$status" -eq 0 ]
  [[ "$output" == *'<pas de fichier>'* ]] || { echo "un config.json a ete invente : $output"; return 1; }
}

@test "canal deb : snapd present se DIT avec le geste, apt n'est JAMAIS appele (le postinst tourne sous le verrou)" {
  export LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/channel"; printf 'deb\n' > "$LCARS_CHANNEL_FILE"
  local bin="$BATS_TEST_TMPDIR/bin-deb"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\n[[ "$1" == -s && "$2" == snapd ]] && exit 0\nexit 1\n' > "$bin/dpkg"
  printf '#!/usr/bin/env bash\necho "APT $*" >> "%s"\nexit 0\n' "$BATS_TEST_TMPDIR/apt-deb.trace" > "$bin/apt-get"
  chmod 0755 "$bin"/*
  local mod_sans_case="$BATS_TEST_TMPDIR/30-sans-case.sh"; sed '/^case "${1:?usage/,$d' "$MOD" > "$mod_sans_case"
  run bash -c "set -uo pipefail; export PATH=\"$bin:$PATH\" PROV_HUMAN=temoin; source '$mod_sans_case' >/dev/null 2>&1; prov_channel_or_verdict apply; PROV_CHANGED=0; dpkg -s snapd >/dev/null 2>&1 && poseur_is_dpkg && echo DEB-SNAPD"
  [[ "$output" == *"DEB-SNAPD"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/apt-deb.trace" ]
  # et la branche du module dit le geste
  grep -q 'sous canal deb ce module ne l.enl' "$MOD"
  grep -q 'apt remove --purge snapd' "$MOD"
}
