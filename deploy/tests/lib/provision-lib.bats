#!/usr/bin/env bats
# SOURCE: deploy/tests/lib/provision-lib.bats
# AUTHOR: consultant
# STARDATE: 2026-07-30
# STATUS: bats tests for lib/provision-lib.sh — the lib's one promise is "never lie green"
#

# shellcheck disable=SC2016

load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export LIB
  [ -f "$LIB" ]

  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"

  unset PROV_SUBSTRATE LCARS_WSL_NETWORKING_MODE

  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/aucun-siege-pose/seat.uid"
}

module_sh() {
  run bash -c "set -euo pipefail; export PROVISION_MODULE=test-mod; source \"\$LIB\"; $1"
}

@test "B1: run_quiet failure increments PROV_FAILED and keeps the command's rc" {
  module_sh '
    rc=0
    run_quiet bash -c "echo boom-output; exit 3" || rc=$?
    [ "$rc" -eq 3 ]
    [ "$PROV_FAILED" -eq 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *boom-output* ]]
}

@test "B1: run_quiet x || verdict_apply exits 1 (the green lie is dead)" {
  module_sh '
    run_quiet false || verdict_apply
    verdict_apply
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *FAIL* ]]
}

@test "B1: run_quiet success stays silent and counts nothing" {
  module_sh '
    run_quiet true
    [ "$PROV_FAILED" -eq 0 ]
    [ "$PROV_CHANGED" -eq 0 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
}

@test "B3: managed block success is SEEN by the caller (PROV_CHANGED > 0)" {
  module_sh '
    f="$BATS_TEST_TMPDIR/target.conf"
    printf "human line\n" > "$f"
    ensure_managed_block "$f" testmark 0644 <<< "managed-line-a"
    [ "$PROV_CHANGED" -ge 1 ]
    grep -q "managed-line-a" "$f"
    grep -q "human line" "$f"
  '
  [ "$status" -eq 0 ]
}

@test "B3: managed block failure is SEEN by the caller (PROV_FAILED > 0, verdict red)" {
  module_sh '
    ensure_managed_block "$BATS_TEST_TMPDIR/no-such-dir/x.conf" testmark 0644 <<< "y" || true
    [ "$PROV_FAILED" -ge 1 ]
    verdict_apply
  '
  [ "$status" -eq 1 ]
}

@test "B3: managed block converges to the CURRENT source (replaced, not append-once)" {
  module_sh '
    f="$BATS_TEST_TMPDIR/target.conf"
    printf "human line\n" > "$f"
    ensure_managed_block "$f" testmark 0644 <<< "old-content"
    ensure_managed_block "$f" testmark 0644 <<< "new-content"
    grep -q "new-content" "$f"
    grep -q "old-content" "$f" && { echo "l ancien contenu a SURVECU a la convergence"; exit 1; }
    [ "$(grep -c "lcars:testmark" "$f")" -eq 2 ]
  '
  [ "$status" -eq 0 ]
}

@test "B3: managed block is idempotent (second identical run changes nothing)" {
  module_sh '
    f="$BATS_TEST_TMPDIR/target.conf"
    printf "human line\n" > "$f"
    ensure_managed_block "$f" testmark 0644 <<< "stable"
    before="$PROV_CHANGED"
    ensure_managed_block "$f" testmark 0644 <<< "stable"
    [ "$PROV_CHANGED" -eq "$before" ]
  '
  [ "$status" -eq 0 ]
}

@test "B5: human_home on unknown user returns empty under set -euo pipefail (no abort)" {
  module_sh '
    export PROV_HUMAN=no-such-user-b5-probe
    home="$(human_home)"
    [ -z "$home" ]
    echo survived
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *survived* ]]
}

@test "B5: as_human on unknown user reaches its p_fail guard (counted, not aborted)" {
  module_sh '
    export PROV_HUMAN=no-such-user-b5-probe
    as_human true || true
    [ "$PROV_FAILED" -ge 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"user inconnu"* ]]
}

@test "as_human POSE LE CWD, pas seulement HOME — un cwd illisible casse tout chemin relatif" {
  local lib="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  grep -qE '^\s*\( cd "\$home" && runuser -u "\$PROV_HUMAN"' "$lib"
  grep -qE '^\s*\( cd .* \)$' "$lib"
}

_bin_groupes() { # _bin_groupes — doublures de getent/groupadd/id/usermod, pilotees par des marqueurs
  local b="$BATS_TEST_TMPDIR/bin-groupes"; mkdir -p "$b"
  cat > "$b/getent" <<'STUB'
#!/usr/bin/env bash
[[ -e "$BATS_TEST_TMPDIR/groupe-$2" ]] || exit 2
printf '%s:x:4242:\n' "$2"
STUB
  cat > "$b/groupadd" <<'STUB'
#!/usr/bin/env bash
echo "GROUPADD:$*" >> "$BATS_TEST_TMPDIR/trace"
: > "$BATS_TEST_TMPDIR/groupe-${*: -1}"
STUB
  cat > "$b/id" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -nG) cat "$BATS_TEST_TMPDIR/membres" 2>/dev/null || echo "rien" ;;
  *)   printf 'uid=4242\n' ;;
esac
STUB
  cat > "$b/usermod" <<'STUB'
#!/usr/bin/env bash
echo "USERMOD:$*" >> "$BATS_TEST_TMPDIR/trace"
echo "$2" >> "$BATS_TEST_TMPDIR/membres"
STUB
  chmod 0755 "$b"/*
  export BIN_GROUPES="$b"

}

@test "ensure_group : la branche qui CREE — groupadd joue, le compteur bouge" {
  _bin_groupes
  module_sh '
    PATH="$BIN_GROUPES:$PATH"
    ensure_group groupe-decor 4242
    [ "$PROV_CHANGED" -eq 1 ]
    grep -q "GROUPADD:-g 4242 groupe-decor" "$BATS_TEST_TMPDIR/trace"
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "ensure_group : un groupe DEJA la ne se recree pas, et le gid divergent est un DRIFT" {
  _bin_groupes
  module_sh '
    PATH="$BIN_GROUPES:$PATH"
    : > "$BATS_TEST_TMPDIR/groupe-groupe-decor"
    ensure_group groupe-decor 4242
    [ "$PROV_CHANGED" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/trace" ]
    ensure_group groupe-decor 9999
    [ "$PROV_DRIFT" -ge 1 ]
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"une machine ne se renumérote pas"* ]]
}

@test "ensure_member : la branche qui ECRIT — usermod joue, et l adhesion est RE-SONDEE apres" {
  _bin_groupes
  module_sh '
    PATH="$BIN_GROUPES:$PATH"
    ensure_member humain-decor groupe-decor
    [ "$PROV_CHANGED" -eq 1 ]
    grep -q "USERMOD:-aG groupe-decor humain-decor" "$BATS_TEST_TMPDIR/trace"
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "ensure_member : un usermod qui MENT est attrape par la re-sonde" {
  _bin_groupes
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN_GROUPES/usermod"; chmod 0755 "$BIN_GROUPES/usermod"
  module_sh '
    PATH="$BIN_GROUPES:$PATH"
    rc=0; ensure_member humain-decor groupe-decor || rc=$?
    [ "$rc" -eq 1 ]
    [ "$PROV_FAILED" -ge 1 ]
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"toujours hors de"* ]]
}

@test "write_atomic: identical content is a no-op (no change counted, mtime preserved)" {
  module_sh '
    f="$BATS_TEST_TMPDIR/wa.conf"
    printf "same\n" > "$f"; chmod 0644 "$f"
    mt_before="$(stat -c %Y "$f")"
    write_atomic "$f" 0644 <<< "same"
    [ "$PROV_CHANGED" -eq 0 ]
    [ "$(stat -c %Y "$f")" = "$mt_before" ]
  '
  [ "$status" -eq 0 ]
}

@test "write_atomic: une ecriture qui RATE ne bascule rien, et ne s annonce pas POSEE" {
  local b="$BATS_TEST_TMPDIR/bin-cat"; mkdir -p "$b"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$b/cat"; chmod 0755 "$b/cat"
  export BIN_CAT="$b"
  module_sh '
    PATH="$BIN_CAT:$PATH"
    src="$BATS_TEST_TMPDIR/source"; printf "contenu\n" > "$src"
    f="$BATS_TEST_TMPDIR/plein.conf"
    write_atomic "$f" 0644 < "$src" || true
    [ ! -e "$f" ]                 # rien na bascule
    [ "$PROV_CHANGED" -eq 0 ]     # rien nest compte comme pose
    [ "$PROV_FAILED" -ge 1 ]      # et lechec est COMPTE, pas avale
  ' 2>/dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"écriture du tampon ratée"* ]]
  refute_out "POSE" <<<"$output"
}

@test "write_atomic: missing parent dir fails loud (PROV_FAILED counted)" {
  module_sh '
    write_atomic "$BATS_TEST_TMPDIR/absent-dir/f" 0644 <<< "x" || true
    [ "$PROV_FAILED" -ge 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"dossier absent"* ]]
}

@test "6-131: ensure_dir REFUSE un symlink-vers-dossier au lieu de converger sa cible" {
  module_sh '
    victime="$BATS_TEST_TMPDIR/victime"; mkdir -p "$victime"; chmod 0755 "$victime"
    ln -s "$victime" "$BATS_TEST_TMPDIR/piege"
    ensure_dir "$BATS_TEST_TMPDIR/piege" 0700 || true
    [ "$PROV_FAILED" -ge 1 ]
    [ "$(stat -c %a "$victime")" = "755" ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"composant symlink"* ]]
}

@test "6-131: un symlink AU MILIEU du chemin est refuse aussi — c est celui de l attaque" {
  module_sh '
    victime="$BATS_TEST_TMPDIR/etc"; mkdir -p "$victime/systemd"; chmod 0755 "$victime/systemd"
    ln -s "$victime" "$BATS_TEST_TMPDIR/config"
    ensure_dir "$BATS_TEST_TMPDIR/config/systemd" 0700 || true
    [ "$PROV_FAILED" -ge 1 ]
    [ "$(stat -c %a "$victime/systemd")" = "755" ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"composant symlink"* ]]
}

@test "ensure_mode: la forme « user: » est IDEMPOTENTE — sinon le rejeu rechowne a l'infini" {
  module_sh '
    f="$BATS_TEST_TMPDIR/idem"; : > "$f"
    ensure_mode "$f" 0644 "$(id -un):" >/dev/null 2>&1
    avant="$PROV_CHANGED"
    out="$(ensure_mode "$f" 0644 "$(id -un):" 2>&1)"
    [ "$PROV_CHANGED" -eq "$avant" ]
    [ -z "$out" ]
  '
  [ "$status" -eq 0 ]
}

@test "ensure_mode, write_atomic, prov_scaffold_dir : « user: » est passé à chown avec le groupe de connexion nommé — les coreutils uutils ignorent la forme nue" {
  local faux="$BATS_TEST_TMPDIR/bin"; mkdir -p "$faux"
  printf '#!/usr/bin/env bash\nfor a; do [[ "$a" == -* ]] || { printf "%%s\\n" "$a" >> "%s"; break; }; done\nexec /usr/bin/chown "$@"\n' "$BATS_TEST_TMPDIR/chown.argv" > "$faux/chown"
  chmod +x "$faux/chown"
  PATH="$faux:$PATH" module_sh '
    f="$BATS_TEST_TMPDIR/f"; : > "$f"
    ensure_mode "$f" 0644 "$(id -un):" >/dev/null 2>&1
    printf x | write_atomic "$BATS_TEST_TMPDIR/w" 0644 "$(id -un):" >/dev/null 2>&1
    prov_scaffold_dir "$BATS_TEST_TMPDIR/d" 0755 "$(id -un):" >/dev/null 2>&1
    [ "$(sort -u "$BATS_TEST_TMPDIR/chown.argv")" = "$(id -un):$(id -gn)" ]
    [ "$(prov_owner "$(id -un):")" = "$(id -un):$(id -gn)" ]
    [ "$(prov_owner root:fleet)" = root:fleet ]
    [ -z "$(prov_owner "")" ]
  '
  [ "$status" -eq 0 ] || { echo "$output"; cat "$BATS_TEST_TMPDIR/chown.argv"; return 1; }
}

@test "ensure_mode: TEMOIN — un groupe NOMME se compare toujours en entier" {
  module_sh '
    f="$BATS_TEST_TMPDIR/nomme"; : > "$f"
    ensure_mode "$f" 0644 "$(id -un):$(id -gn)" >/dev/null 2>&1
    avant="$PROV_CHANGED"
    out="$(ensure_mode "$f" 0644 "$(id -un):$(id -gn)" 2>&1)"
    [ "$PROV_CHANGED" -eq "$avant" ]
    [ -z "$out" ]
    [ "$(stat -c "%U:%G" "$f")" = "$(id -un):$(id -gn)" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-131: ensure_mode dit LIEN et non « absent » sur un lien casse" {
  module_sh '
    ln -s "$BATS_TEST_TMPDIR/nulle-part" "$BATS_TEST_TMPDIR/casse"
    ensure_mode "$BATS_TEST_TMPDIR/casse" 0600 || true
    [ "$PROV_FAILED" -ge 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"composant symlink"* ]]
  [[ "$output" != *"ensure_mode: absent"* ]]
}

@test "6-131: write_atomic refuse d ecrire a travers un parent symlink" {
  module_sh '
    reel="$BATS_TEST_TMPDIR/reel"; mkdir -p "$reel"
    ln -s "$reel" "$BATS_TEST_TMPDIR/lien"
    write_atomic "$BATS_TEST_TMPDIR/lien/f" 0644 <<< "x" || true
    [ "$PROV_FAILED" -ge 1 ]
    [ ! -e "$reel/f" ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"composant symlink"* ]]
}

@test "6-131: TEMOIN — un chemin sans lien converge normalement (la garde ne mure rien)" {
  module_sh '
    ensure_dir "$BATS_TEST_TMPDIR/vrai/imbrique" 0700
    [ "$PROV_FAILED" -eq 0 ]
    [ "$(stat -c %a "$BATS_TEST_TMPDIR/vrai/imbrique")" = "700" ]
    write_atomic "$BATS_TEST_TMPDIR/vrai/imbrique/f" 0600 <<< "contenu"
    [ "$PROV_FAILED" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/vrai/imbrique/f")" = "contenu" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-131: ensure_symlink garde son droit de POSER un lien (la garde vise le parent)" {
  module_sh '
    ensure_symlink "$BATS_TEST_TMPDIR/lien-legitime" /dev/null
    [ "$PROV_FAILED" -eq 0 ]
    [ "$(readlink "$BATS_TEST_TMPDIR/lien-legitime")" = "/dev/null" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-130: prov_lock_path ignore TMPDIR — un verrou dont l appelant choisit l emplacement n en est pas un" {
  module_sh '
    export TMPDIR="$BATS_TEST_TMPDIR/pirate"; mkdir -p "$TMPDIR"
    lock="$(prov_lock_path)" || true
    [[ "$lock" != "$TMPDIR"* ]]
  '
  [ "$status" -eq 0 ]
}

@test "verrou: deux humains ont deux verrous DISTINCTS — les serialiser ne protegeait rien" {
  module_sh '
    a="$(prov_lock_path alice)"
    b="$(prov_lock_path bob)"
    [[ "$a" != "$b" ]]
  '
  [ "$status" -eq 0 ]
}

@test "verrou: le per-humain et le GLOBAL coexistent — c est le defaut qui a casse l install" {
  module_sh '
    g="$(prov_lock_path)"
    h="$(prov_lock_path lcars)"
    exec 8>"$g"; flock -n 8 || exit 1
    exec 7>"$h"; flock -n 7 || exit 2
    exec 7>&-; exec 8>&-
  '
  [ "$status" -eq 0 ]
}

@test "verrou: le MEME humain deux fois se bloque quand meme — la portee n a pas supprime le verrou" {
  module_sh '
    exec 8>"$(prov_lock_path lcars)"; flock -n 8 || exit 1
    exec 7>"$(prov_lock_path lcars)"
    flock -n 7 && exit 2
    exec 7>&-; exec 8>&-
  '
  [ "$status" -eq 0 ]
}

@test "verrou: une portee qui s evade du dossier prouve est REFUSEE" {
  module_sh 'prov_lock_path "../evade" >/dev/null 2>&1 && exit 1; :'
  [ "$status" -eq 0 ]
  module_sh 'prov_lock_path "a/b" >/dev/null 2>&1 && exit 1; :'
  [ "$status" -eq 0 ]
}

@test "6-130: le verrou vit dans un dossier 0700 possede par l appelant" {
  module_sh '
    lock="$(prov_lock_path)"
    dir="$(dirname "$lock")"
    [ "$(stat -c %a "$dir")" = "700" ]
    [ "$(stat -c %u "$dir")" = "$(id -u)" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-130: sans dossier runtime, c'est un REFUS qui NOMME le parent — jamais un repli" {
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/absent/xdg"
  module_sh 'prov_lock_path'
  [ "$status" -ne 0 ]
  [[ "$output" == *"$BATS_TEST_TMPDIR/absent"* ]]
  [[ "$output" == *"pas d'emplacement sûr"* ]]
}

@test "6-109: l URL de l attaque de la fiche ne rend PAS l autorite attendue" {
  module_sh '
    got="$(prov_parse_remote "https://hote-attaquant/attaquant/fleet/lcars-malware.git")" || got=REFUS
    [ "$got" != "forge.example.org/fleet/lcars" ]
    [ "$got" = "REFUS" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-109: un suffixe sur le nom du depot ne passe plus" {
  module_sh '
    got="$(prov_parse_remote "https://forge.example.org/fleet/lcars-malware.git")"
    [ "$got" = "forge.example.org/fleet/lcars-malware" ]
    [ "$got" != "forge.example.org/fleet/lcars" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-109: le MEME depot sur un AUTRE hote est un autre triplet" {
  module_sh '
    a="$(prov_parse_remote "https://forge.example.org/fleet/lcars.git")"
    b="$(prov_parse_remote "https://hote-attaquant/fleet/lcars.git")"
    [ "$a" = "forge.example.org/fleet/lcars" ]
    [ "$b" = "hote-attaquant/fleet/lcars" ]
    [ "$a" != "$b" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-109: les trois formes admises rendent le MEME triplet" {
  module_sh '
    h="$(prov_parse_remote "https://forge.example.org/fleet/lcars.git")"
    s="$(prov_parse_remote "ssh://git@forge.example.org:2222/fleet/lcars.git")"
    p="$(prov_parse_remote "git@forge.example.org:fleet/lcars.git")"
    [ "$h" = "forge.example.org/fleet/lcars" ]
    [ "$s" = "forge.example.org/fleet/lcars" ]
    [ "$p" = "forge.example.org/fleet/lcars" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-109: un remote qui porte un CREDENTIAL est refuse (l utilisateur nu, lui, passe)" {
  module_sh '
    prov_parse_remote "https://user:token@forge.example.org/fleet/lcars.git" && exit 1
    prov_parse_remote "ssh://git@forge.example.org/fleet/lcars.git" >/dev/null || exit 1
    exit 0
  '
  [ "$status" -eq 0 ]
}

@test "6-109: une URL qui MIME l autorite dans son userinfo rend l hote REEL" {
  module_sh '
    got="$(prov_parse_remote "https://fleet/lcars@hote-attaquant/x/y.git")"
    [ "$got" = "hote-attaquant/x/y" ]
    [ "$got" != "forge.example.org/fleet/lcars" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-109: une forme inconnue est REFUSEE, jamais devinee" {
  module_sh '
    prov_parse_remote "/chemin/local/fleet/lcars" && exit 1
    prov_parse_remote "fleet/lcars" && exit 1
    prov_parse_remote "https://forge.example.org/juste-un-segment" && exit 1
    exit 0
  '
  [ "$status" -eq 0 ]
}

@test "6-109: TEMOIN — l hote est insensible a la casse, le chemin NON" {
  module_sh '
    [ "$(prov_parse_remote "https://Forge.Example.ORG/fleet/lcars.git")" = "forge.example.org/fleet/lcars" ]
    [ "$(prov_parse_remote "https://forge.example.org/Fleet/LCARS.git")" = "forge.example.org/Fleet/LCARS" ]
  '
  [ "$status" -eq 0 ]
}

@test "advertise_addr: un bind PRECIS est l'adresse — rien a deriver" {
  module_sh '
    advertise_addr 127.0.0.5
    [ "$PROV_ADVERTISE" = "127.0.0.5" ]
    [ -z "$PROV_ADVERTISE_WHY" ]
  '
  [ "$status" -eq 0 ]
}

@test "advertise_addr: WSL en NAT annonce localhost, et DIT pourquoi" {
  module_sh '
    PROV_SUBSTRATE=wsl
    wsl_networking_mode() { echo nat; }
    lan_addr() { echo 172.25.115.129; }
    advertise_addr 0.0.0.0
    [ "$PROV_ADVERTISE" = "localhost" ]
    [ -n "$PROV_ADVERTISE_WHY" ]
  '
  [ "$status" -eq 0 ]
}

@test "advertise_addr: WSL en MIROIR n'est pas un cas a part — l'adresse de sortie est vraie" {
  module_sh '
    PROV_SUBSTRATE=wsl
    wsl_networking_mode() { echo mirrored; }
    lan_addr() { echo 198.51.100.63; }
    advertise_addr 0.0.0.0
    [ "$PROV_ADVERTISE" = "198.51.100.63" ]
    [ -z "$PROV_ADVERTISE_WHY" ]
  '
  [ "$status" -eq 0 ]
}

@test "advertise_addr: aucune adresse de sortie = loopback ANNONCEE COMME TELLE" {
  module_sh '
    PROV_SUBSTRATE=linux
    lan_addr() { echo ""; }
    advertise_addr 0.0.0.0
    [ "$PROV_ADVERTISE" = "127.0.0.1" ]
    [ -n "$PROV_ADVERTISE_WHY" ]
  '
  [ "$status" -eq 0 ]
}

@test "advertise_addr: n'imprime RIEN — la capture \$( ) perdrait le second fait" {
  module_sh '
    PROV_SUBSTRATE=linux
    lan_addr() { echo 198.51.100.63; }
    out="$(advertise_addr 0.0.0.0)"
    [ -z "$out" ]
    [ -z "$PROV_ADVERTISE" ]
    advertise_addr 0.0.0.0
    [ "$PROV_ADVERTISE" = "198.51.100.63" ]
  '
  [ "$status" -eq 0 ]
}

@test "run_step: la reconnaissance de phase est une fonction pure — aucune horloge, aucune course" {
  local f="$BATS_TEST_TMPDIR/out"
  module_sh '
    f="'"$f"'"
    printf "Compiling 3 files\n"                         > "$f"; _prov_phase_of "$f"
    printf "Compiling 3 files\nRunning ExUnit\n"         > "$f"; _prov_phase_of "$f"
    printf "Running ExUnit\nFinished in 12.0s\n"         > "$f"; _prov_phase_of "$f"
    printf "=== shell_gate\n"                            > "$f"; _prov_phase_of "$f"
    printf "Release created at _build\n"                 > "$f"; _prov_phase_of "$f"
    printf "rien de reconnaissable\n"                    > "$f"; _prov_phase_of "$f"
    : > "$f"                                                   ; _prov_phase_of "$f"
    _prov_phase_of "/nonexistent/pas-de-fichier"
  '
  [ "$status" -eq 0 ]
  local -a lines; mapfile -t lines <<< "$output"
  [ "${lines[0]}" = "compilation" ]
  [ "${lines[1]}" = "suite ExUnit (3000+ temoins)" ]
  [ "${lines[2]}" = "suite ExUnit terminee" ]
  [ "${lines[3]}" = "gate shell (python + bats)" ]
  [ "${lines[4]}" = "release posee" ]
  [ "${lines[5]}" = "demarrage" ]
  [ "${lines[6]}" = "demarrage" ]
  [ "${lines[7]}" = "demarrage" ]
}

@test "run_step: une ligne par CHANGEMENT de phase — pas une par seconde" {
  module_sh '
    run_step "build" -- bash -c "echo Compiling 3 files; sleep 4"
  '
  [ "$status" -eq 0 ]
  local n; n="$(printf '%s\n' "$output" | grep -c '>>')"
  [ "$n" -ge 1 ]
  [ "$n" -lt 4 ]
  [ "$(printf '%s\n' "$output" | grep '>>' | sort -u | wc -l)" -eq "$n" ]
  [[ "$output" == *"build · compilation"* ]]
}

@test "run_step: le rc de l'enfant TRAVERSE la boucle de sonde" {
  module_sh '
    run_step "build" -- bash -c "echo Compiling 3 files; exit 3" || echo "RC=$?"
  '
  [[ "$output" == *"RC=3"* ]]
}

@test "run_step: l'echec garde le rc, COMPTE, borne l'ecran et CONSERVE le fichier" {
  module_sh '
    export PROV_DUMP_LINES=3
    rc=0
    run_step "etape" -- bash -c "for i in \$(seq 1 200); do echo ligne-\$i; done; sleep 1.1; exit 7" || rc=$?
    [ "$rc" -eq 7 ]
    [ "$PROV_FAILED" -eq 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"ligne-200"* ]]
  [[ "$output" != *"ligne-100"* ]]
  [[ "$output" == *"sortie COMPLÈTE conservée"* ]]
  f="$(printf '%s\n' "$output" | sed -n 's/.*conservée : \([^ ]*\).*/\1/p' | tail -n1)"
  [ -s "$f" ]
  [ "$(wc -l < "$f")" -eq 200 ]
  rm -f "$f"
}

@test "run_step: un succes ne laisse AUCUN fichier derriere lui" {
  local container="$BATS_TEST_TMPDIR/tmp-run-step"; mkdir -p "$container"
  before="$(find "$container" -maxdepth 1 -name 'prov-out.*' 2>/dev/null | wc -l)"
  TMPDIR="$container" module_sh 'run_step "ok" -- bash -c "echo rien; sleep 1.1"'
  [ "$status" -eq 0 ]
  after="$(find "$container" -maxdepth 1 -name 'prov-out.*' 2>/dev/null | wc -l)"
  [ "$after" -eq "$before" ] \
    || { echo "run_step a laisse $((after - before)) fichier(s) dans son propre TMPDIR :"; find "$container" -maxdepth 1 -name 'prov-out.*'; return 1; }
}

@test "run_step --ok N : un code tolere n'est pas un echec, et il NE TUE PAS l'appelant" {
  module_sh '
    run_step --ok 3 "etape" -- bash -c "sleep 1.1; exit 3"
    [ "$PROV_LAST_RC" -eq 3 ]
    [ "$PROV_FAILED" -eq 0 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"code attendu"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "run_step --ok N : un code NON tolere reste un echec entier" {
  module_sh '
    rc=0
    run_step --ok 3 "etape" -- bash -c "echo boum; sleep 1.1; exit 4" || rc=$?
    [ "$rc" -eq 4 ]
    [ "$PROV_FAILED" -eq 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "run_step --ok N : la tolerance survit a --verbose — un mode d'affichage ne change pas un verdict" {
  module_sh '
    export PROV_VERBOSE=1
    run_step --ok 3 "etape" -- bash -c "exit 3"
    [ "$PROV_LAST_RC" -eq 3 ]
    [ "$PROV_FAILED" -eq 0 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"code attendu"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "run_step --verbose : PLUSIEURS --ok sont tous tolérés, pas seulement le premier" {
  module_sh '
    export PROV_VERBOSE=1
    run_step --ok 1 --ok 2 "etape" -- bash -c "exit 2"
    [ "$PROV_LAST_RC" -eq 2 ]
    [ "$PROV_FAILED" -eq 0 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"code attendu"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "run_step --verbose : un code NON tolere reste un echec entier, et PROV_LAST_RC le dit" {
  module_sh '
    export PROV_VERBOSE=1
    rc=0
    run_step --ok 3 "etape" -- bash -c "exit 4" || rc=$?
    [ "$rc" -eq 4 ]
    [ "$PROV_LAST_RC" -eq 4 ]
    [ "$PROV_FAILED" -eq 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "lan_addr tient son contrat « vide si indeterminable » — meme sans \`ip\`" {
  module_sh '
    a="$(PATH=/nonexistent lan_addr)"
    [ -z "$a" ]
    PATH=/nonexistent advertise_addr 0.0.0.0
    [ -n "$PROV_ADVERTISE" ]
  '
  [ "$status" -eq 0 ]
}

@test "siege: la table et le candidat unix s'accordent -> agree" {
  module_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/map"
    printf "1\t1000\tamiral\n" > "$PROV_UID_MAP_FILE"
    prov_seat_binding amiral
    [ "$PROV_SEAT_BINDING" = agree ]
    [ "$PROV_SEAT_LOGIN" = amiral ]
    [ "$PROV_SEAT_SOURCE" = table ]
  '
  [ "$status" -eq 0 ]
}

@test "siege: la table et le candidat unix DIVERGENT -> diverge, et la table fait foi" {
  module_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/map"
    printf "1\t1000\tamiral\n" > "$PROV_UID_MAP_FILE"
    prov_seat_binding quelquun-dautre
    [ "$PROV_SEAT_BINDING" = diverge ]
    [ "$PROV_SEAT_LOGIN" = amiral ]
  '
  [ "$status" -eq 0 ]
}

@test "siege: le cote durable nomme, unix n'a pas de candidat -> derived, source NOMMEE" {
  module_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/map"
    printf "1\t1000\tamiral\n" > "$PROV_UID_MAP_FILE"
    prov_seat_binding
    [ "$PROV_SEAT_BINDING" = derived ]
    [ "$PROV_SEAT_SOURCE" = table ]
    [ "$PROV_SEAT_LOGIN" = amiral ]
  '
  [ "$status" -eq 0 ]
}

@test "siege: unix nomme, le cote durable est muet -> seeded" {
  module_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/absente"
    export PROV_MASTER_TOKEN_FILE="$BATS_TEST_TMPDIR/pas-de-jeton"
    export PROV_FORGE_URL=""
    prov_seat_binding loperateur
    [ "$PROV_SEAT_BINDING" = seeded ]
    [ "$PROV_SEAT_SOURCE" = candidat ]
    [ "$PROV_SEAT_LOGIN" = loperateur ]
  '
  [ "$status" -eq 0 ]
}

@test "siege: ni l un ni l autre -> unknown, et AUCUN nom n est pose" {
  module_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/absente"
    export PROV_MASTER_TOKEN_FILE="$BATS_TEST_TMPDIR/pas-de-jeton"
    export PROV_FORGE_URL=""
    prov_seat_binding
    [ "$PROV_SEAT_BINDING" = unknown ]
    [ -z "$PROV_SEAT_LOGIN" ]
  '
  [ "$status" -eq 0 ]
}

@test "siege: l enregistrement ECRIT UNE FOIS et ne se re-ecrit jamais" {
  module_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/map"
    prov_seat_record amiral 1000
    prov_seat_record quelquun-dautre 1000
    [ "$(prov_seat_from_map)" = amiral ]
    [ "$(grep -c . "$PROV_UID_MAP_FILE")" -eq 1 ]
  '
  [ "$status" -eq 0 ]
}

@test "siege: la table PASSE AVANT la forge — un redemarrage tient sans reseau" {
  module_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/map"
    printf "1\t1000\tamiral\n" > "$PROV_UID_MAP_FILE"
    export PROV_MASTER_TOKEN_FILE="$BATS_TEST_TMPDIR/pas-de-jeton"
    export PROV_FORGE_URL=""
    prov_seat_binding amiral
    [ "$PROV_SEAT_BINDING" = agree ]
  '
  [ "$status" -eq 0 ]
}

stub_curl() { # enregistre argv et stdin de l appel, repond 200
  export STUB_BIN="$BATS_TEST_TMPDIR/bin" STUB_ARGV="$BATS_TEST_TMPDIR/argv" STUB_STDIN="$BATS_TEST_TMPDIR/stdin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_ARGV"
cat > "$STUB_STDIN"
echo 200
STUB
  chmod +x "$STUB_BIN/curl"
}

@test "forge_curl : le jeton part sur STDIN (-K -), jamais dans argv" {
  stub_curl
  printf 'SECRET-TOKEN\n' > "$BATS_TEST_TMPDIR/tok"
  module_sh '
    PATH="$STUB_BIN:$PATH"
    out="$(forge_curl "$BATS_TEST_TMPDIR/tok" -s -m 10 http://forge.test/api/v1/x)"
    [ "$out" = 200 ]
  '
  [ "$status" -eq 0 ]
  refute grep -q 'SECRET-TOKEN' "$STUB_ARGV"
  grep -qx -- '-K' "$STUB_ARGV"
  grep -qx 'http://forge.test/api/v1/x' "$STUB_ARGV"
  grep -qx 'header = "Authorization: token SECRET-TOKEN"' "$STUB_STDIN"
}

@test "forge_curl sans jeton : requete ANONYME — stdin vide, aucun Authorization nulle part" {
  stub_curl
  module_sh '
    PATH="$STUB_BIN:$PATH"
    forge_curl "$BATS_TEST_TMPDIR/absent" -s http://forge.test/api/v1/x >/dev/null
    forge_curl "" -s http://forge.test/api/v1/y >/dev/null
  '
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_STDIN" ]
  refute grep -qi 'authorization' "$STUB_ARGV" "$STUB_STDIN"
}

stub_dpkg() { # stub_dpkg <arch> — un dpkg qui repond <arch> ; vide = pas de dpkg du tout
  export STUB_BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUB_BIN"; rm -f "$STUB_BIN/dpkg"
  [[ -n "$1" ]] || return 0
  printf '#!/usr/bin/env bash\n[ "$1" = --print-architecture ] && echo %s\n' "$1" > "$STUB_BIN/dpkg"
  chmod +x "$STUB_BIN/dpkg"
}

@test "arch_tag : amd64 se dit x64 chez node, amd64 chez debian, et raw rend dpkg tel quel" {
  stub_dpkg amd64
  module_sh 'PATH="$STUB_BIN:$PATH"; [ "$(arch_tag node)" = x64 ] && [ "$(arch_tag debian)" = amd64 ] && [ "$(arch_tag raw)" = amd64 ]'
  [ "$status" -eq 0 ]
  stub_dpkg arm64
  module_sh 'PATH="$STUB_BIN:$PATH"; [ "$(arch_tag node)" = arm64 ] && [ "$(arch_tag debian)" = arm64 ]'
  [ "$status" -eq 0 ]
}

@test "arch_tag : une arch non epinglee rend VIDE — jamais un repli, jamais uname" {
  stub_dpkg riscv64
  module_sh 'PATH="$STUB_BIN:$PATH"; [ -z "$(arch_tag node)" ] && [ -z "$(arch_tag debian)" ] && [ "$(arch_tag raw)" = riscv64 ]'
  [ "$status" -eq 0 ]
  stub_dpkg ""
  module_sh 'PATH="$STUB_BIN"; [ -z "$(arch_tag node)" ] && [ -z "$(arch_tag raw)" ]'
  [ "$status" -eq 0 ]
}

@test "set_diff : les lignes de b absentes de a — trie, dedoublonne, ignore le vide" {
  module_sh '
    out="$(set_diff $'"'"'b\na\n\nc'"'"' $'"'"'c\nd\na\nd\n'"'"')"
    [ "$out" = d ]
    [ -z "$(set_diff $'"'"'x\ny'"'"' $'"'"'y\nx'"'"')" ]
    [ "$(set_diff "" $'"'"'z\nz'"'"')" = z ]
  '
  [ "$status" -eq 0 ]
}

@test "env_field : fichier absent = vide et 0 ; cle repetee = la DERNIERE, comme un source" {
  printf 'A=1\nB=premier\nB=dernier\n' > "$BATS_TEST_TMPDIR/e.env"
  module_sh '
    [ -z "$(env_field /nonexistent/x.env A)" ]
    [ "$(env_field "$BATS_TEST_TMPDIR/e.env" A)" = 1 ]
    [ "$(env_field "$BATS_TEST_TMPDIR/e.env" B)" = dernier ]
    [ -z "$(env_field "$BATS_TEST_TMPDIR/e.env" C)" ]
  '
  [ "$status" -eq 0 ]
}

@test "read_token : absent = vide, rc 0 et AUCUN message — le shell ne crie pas l absence du fichier" {
  printf '  jeton \n' > "$BATS_TEST_TMPDIR/t"
  module_sh '
    out="$(read_token /nonexistent/jeton 2>&1)"; [ -z "$out" ]
    out="$(read_token "" 2>&1)"; [ -z "$out" ]
    [ "$(read_token "$BATS_TEST_TMPDIR/t")" = jeton ]
  '
  [ "$status" -eq 0 ]
}

@test "p_fact : SANS le fichier, il n ecrit rien et ne dit rien — un module reste lisible seul" {
  module_sh '
    out="$(p_fact substrat wsl 2>&1)"
    [ -z "$out" ]
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "p_fact : AVEC le fichier, une ligne nom=valeur par fait, dans l ordre" {
  module_sh "
    export PROV_FACTS_FILE='$BATS_TEST_TMPDIR/facts'
    p_fact substrat wsl
    p_fact docker oui
  "
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/facts"
  [ "${lines[0]}" = "substrat=wsl" ]
  [ "${lines[1]}" = "docker=oui" ]
}

@test "p_fact : la valeur garde ses espaces — une raison de refus est une phrase" {
  module_sh "
    export PROV_FACTS_FILE='$BATS_TEST_TMPDIR/facts'
    p_fact docker_why 'le daemon repond mais pas a cet utilisateur'
    p_fact docker_why2 le daemon repond pas
  "
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/facts"
  [ "${lines[0]}" = "docker_why=le daemon repond mais pas a cet utilisateur" ]
  [ "${lines[1]}" = "docker_why2=le daemon repond pas" ]
}

@test "p_fact : un appel a UN seul argument n ecrit rien et ne tue pas l appelant" {
  module_sh "
    export PROV_FACTS_FILE='$BATS_TEST_TMPDIR/facts'
    p_fact orphelin
    p_fact substrat wsl
  "
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/facts"
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "substrat=wsl" ]
}

@test "LE PIEGE : un fichier de faits INECRIVABLE ne tue pas le module et ne crie pas" {
  module_sh "
    export PROV_FACTS_FILE='/nonexistent/repertoire/facts'
    out=\$(p_fact substrat wsl 2>&1)
    [ -z \"\$out\" ]
    p_ok 'le module continue apres'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"le module continue apres"* ]]
}

@test "p_fact ne renverse JAMAIS le verdict qu il rapporte" {
  module_sh "
    export PROV_FACTS_FILE='$BATS_TEST_TMPDIR/facts'
    p_ok 'conforme'
    p_fact substrat wsl
    verdict_check
  "
  [ "$status" -eq 0 ]
}

@test "prov_dans_la_copie : vrai quand le rail tourne DEPUIS la racine qu il a posee" {
  module_sh '
    D="$BATS_TEST_TMPDIR/copie"; mkdir -p "$D"
    repo_root() { echo "$D"; }
    PROV_ROOT="$D"
    prov_dans_la_copie
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "prov_dans_la_copie : faux depuis l arbre de travail — c est la ou l on batit" {
  module_sh '
    mkdir -p "$BATS_TEST_TMPDIR/travail" "$BATS_TEST_TMPDIR/opt"
    repo_root() { echo "$BATS_TEST_TMPDIR/travail"; }
    PROV_ROOT="$BATS_TEST_TMPDIR/opt"
    rc=0; prov_dans_la_copie || rc=$?
    [ "$rc" -eq 1 ]
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "prov_dans_la_copie : faux depuis un SOUS-repertoire de la racine — c est l egalite qui compte" {
  module_sh '
    mkdir -p "$BATS_TEST_TMPDIR/opt"
    repo_root() { echo "$BATS_TEST_TMPDIR/opt-voisin"; }
    PROV_ROOT="$BATS_TEST_TMPDIR/opt"
    rc=0; prov_dans_la_copie || rc=$?
    [ "$rc" -eq 1 ]
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "ensure_mode : un setgid herite est RETIRE quand le mode demande ne le porte pas — et POSE quand il le porte" {
  local d="$BATS_TEST_TMPDIR/parent"
  mkdir -p "$d/enfant"; chmod 2775 "$d/enfant"
  [ "$(stat -c %a "$d/enfant")" = 2775 ]
  run bash -c ". '$LIB'; PROV_MODULE_TAG=t; ensure_mode '$d/enfant' 0755"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$d/enfant")" = 755 ]
  [[ "$output" == *"POSÉ"* ]]
  run bash -c ". '$LIB'; PROV_MODULE_TAG=t; ensure_mode '$d/enfant' 2775"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$d/enfant")" = 2775 ]
}

pt_root() { # pt_root <racine> -> ce que product_tree rend avec une lib copiee sous <racine>/deploy/lib
  mkdir -p "$1/deploy/lib"; cp "$LIB" "$1/deploy/lib/provision-lib.sh"; cp "$BATS_TEST_DIRNAME/../../lib/docker-endpoint.sh" "$1/deploy/lib/"
  PROVISION_LIB="$1/deploy/lib/provision-lib.sh" bash -c '. "$PROVISION_LIB" >/dev/null 2>&1; product_tree'
}
@test "product_tree : un checkout (runtime/ present, pas de services/ a la racine) → runtime/" {
  local r="$BATS_TEST_TMPDIR/co"; mkdir -p "$r/runtime/etc"
  [ "$(pt_root "$r")" = "$r/runtime" ]
}
@test "product_tree : une machine posee (services/ a plat, runtime/ = la release) → la racine" {
  local r="$BATS_TEST_TMPDIR/posee"; mkdir -p "$r/runtime/rel/lcars_fleet" "$r/services/human.d" "$r/etc"
  [ "$(pt_root "$r")" = "$r" ]
}
@test "product_tree : la release ILLISIBLE (0750 root:fleet, lecteur hors du groupe) ne change pas la reponse" {
  [ "$(id -u)" -ne 0 ] || skip "root lit tout"
  local r="$BATS_TEST_TMPDIR/posee2"; mkdir -p "$r/runtime/rel/lcars_fleet" "$r/services/human.d"
  chmod 0000 "$r/runtime"
  local got; got="$(pt_root "$r")"; chmod 0755 "$r/runtime"
  [ "$got" = "$r" ]
}

@test "prov_in_group : membre de son groupe primaire → 0 ; d'un groupe qui n'existe pas → 1" {
  module_sh 'prov_in_group "$(id -un)" "$(id -gn)" && echo DEDANS'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEDANS"* ]]
  module_sh 'prov_in_group "$(id -un)" "groupe-decor-inexistant-di13" || echo DEHORS'
  [[ "$output" == *"DEHORS"* ]]
}

@test "prov_in_group : un groupe dont le nom est un PREFIXE d'un autre n'est pas pris pour lui" {
  module_sh 'id() { echo "fleet-console fleet_bis"; }; prov_in_group x fleet || echo DEHORS; prov_in_group x fleet_bis && echo DEDANS'
  [[ "$output" == *"DEHORS"* ]]
  [[ "$output" == *"DEDANS"* ]]
}

@test "prov_in_group : un compte inconnu → 1, sans bruit sur stderr" {
  module_sh 'if prov_in_group compte-decor-inexistant-di13 fleet; then echo DEDANS; else echo DEHORS; fi'
  [ "$output" = "DEHORS" ]
}

@test "prov_pgrep_pattern : le motif matche la cible et JAMAIS la commande qui le porte" {
  local m; m="$(bash -c "source '$LIB' >/dev/null 2>&1; prov_pgrep_pattern zorglub-$$")"
  [ "$m" = "[z]orglub-$$" ]
  run bash -c "pgrep -f '$m' >/dev/null && echo VU || echo PAS-VU"
  [[ "$output" == *"PAS-VU"* ]]
  run bash -c "pgrep -f 'zorglub-$$' >/dev/null && echo VU || echo PAS-VU"
  [[ "$output" == "VU" ]]
}

uid_rule_decor() {
  export LCARS_SYSADMIN_UID=1000
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  printf 'UID_MIN\t1000\nUID_MAX\t60000\n' > "$PASSWD_DEFS"
  export PASSWD_FILE="$BATS_TEST_TMPDIR/passwd"
  printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' 'svc:x:999:999::/nonexistent:/usr/sbin/nologin' \
    'admiral:x:1000:1000::/home/admiral:/bin/bash' 'zoe:x:1001:1001::/home/zoe:/bin/bash' \
    'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin' > "$PASSWD_FILE"
  UBIN="$BATS_TEST_TMPDIR/ubin"; mkdir -p "$UBIN"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *zoe*) echo 1001 ;; *admiral*) echo 1000 ;; *svc*) echo 999 ;; *nobody*) echo 65534 ;; *) exit 1 ;; esac' \
    > "$UBIN/id"
  chmod 0755 "$UBIN/id"
  PROTO="$BATS_TEST_DIRNAME/../../../runtime/services/lib/human-protocol.sh"
  [ -f "$PROTO" ] || { echo "protocole du produit introuvable : $PROTO" >&2; return 1; }
}

lib_verdict() { # lib_verdict <login> -> "rc|remede" selon la lib de l'installeur
  bash -c "set -uo pipefail; export PATH='$UBIN:$PATH' PROVISION_MODULE=test-mod; source '$LIB' >/dev/null 2>&1
    is_fleet_human '$1' 2>/dev/null; rc=\$?; printf '%s|%s' \"\$rc\" \"\$PROV_UID_BOUNDS_WHY\""
}

proto_verdict() { # proto_verdict <login> -> "rc|remede" selon le protocole du produit
  bash -c "set -uo pipefail; export PATH='$UBIN:$PATH' LCARS_HUMAN_PROTOCOL_HOST=1
    export LCARS_MODULE_PROTOCOL='$(dirname "$PROTO")/module-protocol.sh' LCARS_PRIVATE_DIR='$BATS_TEST_TMPDIR'
    . '$PROTO'
    is_fleet_human '$1' 2>/dev/null; rc=\$?; printf '%s|%s' \"\$rc\" \"\$UID_BOUNDS_WHY\""
}

@test "uid: zoe est un humain ; svc (sous UID_MIN), nobody (au-dessus de UID_MAX) et le siege ne le sont pas" {
  uid_rule_decor
  [ "$(lib_verdict zoe)" = "0|" ]
  [ "$(lib_verdict svc)" = "1|" ]
  [ "$(lib_verdict nobody)" = "1|" ]
  [ "$(lib_verdict admiral)" = "1|" ]
}

@test "uid: bornes ILLISIBLES — is_fleet_human rend non a tout le monde, fleet_humans ne rend personne, le remede est dit UNE FOIS" {
  uid_rule_decor
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/nulle-part/login.defs"
  run bash -c "set -uo pipefail; export PATH='$UBIN:$PATH' PROVISION_MODULE=test-mod; source '$LIB' >/dev/null 2>&1
    is_fleet_human zoe && echo ZOE_OUI
    echo \"pop=[\$(fleet_humans | paste -sd, -)]\"
    fleet_humans; fleet_humans
    echo FIN"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ZOE_OUI"* ]]
  [[ "$output" == *"pop=[]"* ]]
  [[ "$output" == *"FIN"* ]]
  [[ "$output" == *"UID_MIN illisible dans $PASSWD_DEFS"* ]]
  [[ "$output" == *"repare $PASSWD_DEFS"* ]]
  [ "$(grep -c "n'est pas etablie" <<<"$output")" -eq 1 ]
  refute grep -qE '(^|[^0-9])1000([^0-9]|$)' <<<"$output"
}

@test "uid: UID_MAX absent du fichier n'etablit pas la frontiere non plus — nobody ne passe jamais par un defaut" {
  uid_rule_decor
  printf 'UID_MIN\t1000\n' > "$PASSWD_DEFS"
  [ "$(lib_verdict nobody)" = "1|la frontiere systeme/humain n'est pas etablie (UID_MAX illisible dans $PASSWD_DEFS) — la borne est declaree par le systeme, pas par ce processus : repare $PASSWD_DEFS" ]
}

@test "uid: LA REGLE EST CELLE DU PROTOCOLE DU PRODUIT — meme matrice, memes verdicts, meme phrase" {
  uid_rule_decor
  local variant login lib proto bad=0
  for variant in lisible absent sans-max plancher-2000; do
    case "$variant" in
      lisible)       printf 'UID_MIN\t1000\nUID_MAX\t60000\n' > "$BATS_TEST_TMPDIR/login.defs"; export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs" ;;
      absent)        export PASSWD_DEFS="$BATS_TEST_TMPDIR/nulle-part/login.defs" ;;
      sans-max)      printf 'UID_MIN\t1000\n' > "$BATS_TEST_TMPDIR/login.defs"; export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs" ;;
      plancher-2000) printf 'UID_MIN\t2000\nUID_MAX\t60000\n' > "$BATS_TEST_TMPDIR/login.defs"; export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs" ;;
    esac
    for login in zoe svc nobody admiral; do
      lib="$(lib_verdict "$login")"; proto="$(proto_verdict "$login")"
      [ "$lib" = "$proto" ] || { echo "$variant/$login : lib=« $lib » protocole=« $proto »" >&2; bad=1; }
    done
  done
  [ "$bad" -eq 0 ]
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/nulle-part/login.defs"
  [[ "$(lib_verdict zoe)" == "1|la frontiere"* ]]
  printf 'UID_MIN\t1000\nUID_MAX\t60000\n' > "$BATS_TEST_TMPDIR/login.defs"; export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  [ "$(lib_verdict zoe)" = "0|" ]
}

@test "apt_ensure : apt-get recoit un DELAI et des reprises — un miroir mort se dit, il ne suspend pas l'installeur (banc 2003, 2026-09-05)" {
  local b="$BATS_TEST_TMPDIR/apt"; mkdir -p "$b"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "not-installed"' > "$b/dpkg-query"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "'"$b"'/argv"' \
    'case " $* " in *" indextargets "*) echo "http://archive.ubuntu.com/ubuntu/dists/x/InRelease"; exit 0;; esac' 'exit 100' > "$b/apt-get"
  printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in *https://archive.ubuntu.com*) exit 0;; *) exit 28;; esac' > "$b/curl"
  chmod 0755 "$b"/*
  run bash -c "set -uo pipefail; export PATH=\"$b:$PATH\"; . '$LIB' >/dev/null 2>&1; PROV_CHANGED=0 PROV_FAILED=0; apt_ensure jq; echo rc=\$?"
  [[ "$output" == *"rc=1"* ]]
  grep -qE 'Acquire::http::Timeout=30' "$b/argv"
  grep -qE 'Acquire::Retries=2' "$b/argv"
  grep -qE '^update .*-o Acquire' "$b/argv"   # le verbe d abord : les doublures lisent \$1
  [[ "$output" == *"archive.ubuntu.com injoignable en http alors que https://archive.ubuntu.com répond"* ]]
  [[ "$output" == *"passer les sources apt en https"* ]]
}

@test "apt_ensure : miroir vivant mais apt en echec — le diagnostic ne blame pas le reseau" {
  local b="$BATS_TEST_TMPDIR/apt2"; mkdir -p "$b"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "not-installed"' > "$b/dpkg-query"
  printf '%s\n' '#!/usr/bin/env bash' 'case " $* " in *" indextargets "*) echo "http://archive.ubuntu.com/ubuntu/dists/x/InRelease"; exit 0;; esac' 'exit 100' > "$b/apt-get"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$b/curl"
  chmod 0755 "$b"/*
  run bash -c "set -uo pipefail; export PATH=\"$b:$PATH\"; . '$LIB' >/dev/null 2>&1; PROV_CHANGED=0 PROV_FAILED=0; apt_ensure jq; echo rc=\$?"
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"le miroir http://archive.ubuntu.com répond"* ]]
  refute_out 'INJOIGNABLE' <<<"$output"
}

canal_decor() {
  export LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/etc/lcars/channel"
  export LCARS_CHANNEL_OWNER; LCARS_CHANNEL_OWNER="$(id -un):$(id -gn)"
  mkdir -p "$(dirname "$LCARS_CHANNEL_FILE")"
}
canal() { # canal <code bash> — la lib sourcee, verdicts a zero, sous le decor du canal
  run bash -c "set -euo pipefail; export PROVISION_MODULE=test-mod; . \"\$LIB\" >/dev/null 2>&1; PROV_CHANGED=0 PROV_FAILED=0 PROV_DRIFT=0; $1"
}

@test "prov_channel : les deux valeurs se lisent, et l absence du fichier dit « aucun »" {
  canal_decor
  local v
  for v in source kit; do
    printf '%s\n' "$v" > "$LCARS_CHANNEL_FILE"
    canal 'prov_channel; echo "global=$PROV_CHANNEL"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$v" ]
    [ "${lines[1]}" = "global=$v" ]
  done
  rm -f "$LCARS_CHANNEL_FILE"
  canal 'prov_channel; echo "global=$PROV_CHANNEL"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "aucun" ]
  [ "${lines[1]}" = "global=aucun" ]
}

@test "prov_channel : une valeur hors vocabulaire est un FAIL NOMME — rien sur stdout, rc 1, et il COMPTE en appel nu" {
  canal_decor
  printf 'snap\n' > "$LCARS_CHANNEL_FILE"
  canal 'prov_channel >/dev/null || echo "rc=$?"; echo "failed=$PROV_FAILED global=[$PROV_CHANNEL]"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAIL"*"canal d'installation illisible"*"« snap »"*"source ou kit"* ]]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"failed=1 global=[]"* ]]
  [[ "$output" == *"$LCARS_CHANNEL_FILE"* ]]
  canal 'v="$(prov_channel 2>/dev/null)" || true; echo "v=[$v]"'
  [[ "$output" == *"v=[]"* ]]
}

@test "prov_channel : le nom du fichier a UNE source, et elle se surcharge — sinon un decor lirait la machine" {
  canal_decor
  canal 'echo "$PROV_CHANNEL_FILE_CANON"'
  [ "$output" = "/etc/lcars/channel" ]
  run env -u LCARS_CHANNEL_FILE bash -c ". \"$LIB\" >/dev/null 2>&1; echo \"\$PROV_CHANNEL_FILE\""
  [ "$output" = "/etc/lcars/channel" ]
  grep -qE '^anchor[[:space:]]+/etc/lcars/channel[[:space:]]+0644[[:space:]]+root:root[[:space:]]+any' \
    "$BATS_TEST_DIRNAME/../../system.manifest"
}

@test "prov_channel_write : pose la valeur, au mode de la table, atomique et idempotent — et refuse hors vocabulaire" {
  canal_decor
  canal 'prov_channel_write kit; echo "changed=$PROV_CHANGED"'
  [ "$status" -eq 0 ]
  [ "$(cat "$LCARS_CHANNEL_FILE")" = "kit" ]
  [ "$(stat -c '%a' "$LCARS_CHANNEL_FILE")" = "644" ]
  [[ "$output" == *"POSÉ"*"changed=1"* ]]
  canal 'prov_channel_write kit; echo "changed=$PROV_CHANGED"'
  [[ "$output" == *"changed=0"* ]]
  canal 'prov_channel_write source'
  [ "$(cat "$LCARS_CHANNEL_FILE")" = "source" ]
  [ -z "$(find "$(dirname "$LCARS_CHANNEL_FILE")" -name '.prov.*')" ]
  canal 'prov_channel_write snap || echo "rc=$?"; echo "failed=$PROV_FAILED"'
  [[ "$output" == *"FAIL"*"n'est pas un canal"*"rc=1"*"failed=1"* ]]
  [ "$(cat "$LCARS_CHANNEL_FILE")" = "source" ]
}

dpkg_double() { # dpkg_double <statut> <lignes de -V…> — un `dpkg` sur le PATH qui repond ce qu'on lui dit
  local d="$BATS_TEST_TMPDIR/dpkgbin"; mkdir -p "$d"
  local st="$1"; shift
  {
    echo '#!/usr/bin/env bash'
    echo 'case "$1" in'
    echo "  -s) [[ -n '$st' ]] || exit 1; echo 'Package: lcars'; echo 'Status: $st'; exit 0 ;;"
    echo '  -V)'
    local l; for l in "$@"; do printf "    printf '%%s\\\\n' '%s'\n" "$l"; done
    echo '    exit 0 ;;'
    echo 'esac; exit 2'
  } > "$d/dpkg"
  chmod 0755 "$d/dpkg"
  export PATH="$d:$PATH"
}

@test "prov_channel : un produit POSE sans tampon = « inconnu » (pose avant le tampon) — ni aucun, ni un canal" {
  local etc="$BATS_TEST_TMPDIR/etc"; mkdir -p "$etc" "$BATS_TEST_TMPDIR/opt/lcars/runtime"
  run bash -c "set -uo pipefail; export LCARS_CHANNEL_FILE='$etc/channel' PROV_ROOT='$BATS_TEST_TMPDIR/opt/lcars' PROV_PREFIX='$BATS_TEST_TMPDIR/opt/lcars/runtime'; . '$LIB' >/dev/null 2>&1; prov_channel; echo \"var=\$PROV_CHANNEL\""
  [[ "$output" == *"inconnu"*"var=inconnu"* ]]
  rmdir "$BATS_TEST_TMPDIR/opt/lcars/runtime"
  run bash -c "set -uo pipefail; export LCARS_CHANNEL_FILE='$etc/channel' PROV_ROOT='$BATS_TEST_TMPDIR/opt/lcars' PROV_PREFIX='$BATS_TEST_TMPDIR/opt/lcars/runtime'; . '$LIB' >/dev/null 2>&1; prov_channel"
  [[ "$output" == "aucun" ]]
  printf 'kit\n' > "$etc/channel"; mkdir -p "$BATS_TEST_TMPDIR/opt/lcars/runtime"
  run bash -c "set -uo pipefail; export LCARS_CHANNEL_FILE='$etc/channel' PROV_ROOT='$BATS_TEST_TMPDIR/opt/lcars' PROV_PREFIX='$BATS_TEST_TMPDIR/opt/lcars/runtime'; . '$LIB' >/dev/null 2>&1; prov_channel"
  [[ "$output" == "kit" ]]
}

@test "RACINE : une surcharge de PROV_ROOT hors temoin est un REFUS, et le geste ne demarre pas" {
  run env -u BATS_TEST_TMPDIR PROV_ROOT=/tmp/ailleurs bash -c ". '$LIB'; echo ATTEINT"
  [ "$status" -ne 0 ] || { echo "une racine deplacee a ete acceptee hors temoin : $output"; return 1; }
  [[ "$output" != *ATTEINT* ]] || { echo "le refus n'a pas arrete le chargement de la lib"; return 1; }
}

@test "RACINE : le refus NOMME la racine posee, la racine vraie, et ce qu'une racine qui glisse coute" {
  run env -u BATS_TEST_TMPDIR PROV_ROOT=/tmp/ailleurs bash -c ". '$LIB'"
  [[ "$output" == *"/tmp/ailleurs"* ]] || { echo "le refus ne dit pas ce qui a ete pose : $output"; return 1; }
  [[ "$output" == *"/opt/lcars"* ]]    || { echo "le refus ne dit pas la racine vraie : $output"; return 1; }
  [[ "$output" == *"manifeste"* ]]     || { echo "le refus ne dit pas ce que ca coute : $output"; return 1; }
  [[ "$output" == *"terrain"* ]]       || { echo "le refus ne dit pas le geste juste : $output"; return 1; }
}

@test "RACINE : un TEMOIN peut toujours la deplacer — sinon ce verrou ferme le corpus entier" {
  run bash -c "export BATS_TEST_TMPDIR='$BATS_TEST_TMPDIR' PROV_ROOT='$BATS_TEST_TMPDIR/opt'; . '$LIB'; echo \"racine=\$PROV_ROOT\""
  [ "$status" -eq 0 ] || { echo "un temoin s'est fait refuser sa racine : $output"; return 1; }
  [[ "$output" == *"racine=$BATS_TEST_TMPDIR/opt"* ]] || { echo "la racine du temoin n'a pas ete honoree : $output"; return 1; }
}

@test "RACINE : sans surcharge, elle vaut /opt/lcars — et la valeur canon a UNE declaration" {
  run env -u BATS_TEST_TMPDIR -u PROV_ROOT bash -c ". '$LIB'; echo \"racine=\$PROV_ROOT canon=\$PROV_ROOT_CANON\""
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"racine=/opt/lcars canon=/opt/lcars"* ]] || { echo "$output"; return 1; }
  local n_lit; n_lit="$(grep -vE '^\s*#' "$LIB" | grep -c '/opt/lcars')"
  [ "$n_lit" -eq 1 ] \
    || { echo "le litteral /opt/lcars apparait $n_lit fois en CODE dans la lib — une racine a deux ecritures :"; \
         grep -vE '^\s*#' "$LIB" | grep -n '/opt/lcars' >&2; return 1; }
}

@test "SUBSTRAT/LISTE : les deux separateurs disent la meme chose, et « any » accueille tout" {
  run bash -c ". '$LIB'; prov_substrate_satisfait 'wsl linux' linux"
  [ "$status" -eq 0 ] || { echo "« wsl linux » n'accueille pas linux"; return 1; }
  run bash -c ". '$LIB'; prov_substrate_satisfait 'wsl+linux' linux"
  [ "$status" -eq 0 ] || { echo "« wsl+linux » n'accueille pas linux — 25 lignes du manifeste hors portee"; return 1; }
  run bash -c ". '$LIB'; prov_substrate_satisfait 'wsl+linux' wsl"
  [ "$status" -eq 0 ] || { echo "« wsl+linux » n'accueille pas wsl"; return 1; }
  run bash -c ". '$LIB'; prov_substrate_satisfait any docker"
  [ "$status" -eq 0 ] || { echo "« any » n'accueille pas docker"; return 1; }
}

@test "SUBSTRAT/LISTE : un mot ne satisfait que lui-meme — docker n'est pas dans « linux », ni wsl" {
  run bash -c ". '$LIB'; prov_substrate_satisfait linux docker"
  [ "$status" -ne 0 ] || { echo "docker se declare couvert par une liste « linux » — l'image pose, le rail non"; return 1; }
  run bash -c ". '$LIB'; prov_substrate_satisfait linux wsl"
  [ "$status" -ne 0 ] || { echo "WSL se declare couvert par une liste « linux »"; return 1; }
  run bash -c ". '$LIB'; prov_substrate_satisfait 'wsl+linux' docker"
  [ "$status" -ne 0 ] || { echo "docker se declare couvert par « wsl+linux »"; return 1; }
}

@test "SUBSTRAT/LISTE : le rail et la TABLE repondent par la MEME fonction, pas par deux copies" {
  local runner="$BATS_TEST_DIRNAME/../../provision" dirs="$BATS_TEST_DIRNAME/../../modules.d/25-directories.sh"
  grep -q 'prov_substrate_satisfait' "$runner" \
    || { echo "deploy/provision ne delegue plus la comparaison de substrat"; return 1; }
  grep -q 'prov_substrate_satisfait' "$dirs" \
    || { echo "25-directories ne delegue plus la comparaison de substrat"; return 1; }
  ! grep -qE 'case " \$1 " in \*" \$SUBSTRATE "\*' "$runner" \
    || { echo "substrate_in a retrouve sa comparaison locale"; return 1; }
  ! grep -qE 'case "\+\$col\+" in \*"\+\$sub\+"\*' "$dirs" \
    || { echo "prov_dir_scope a retrouve sa comparaison locale"; return 1; }
}

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

teardown() { [[ -z "${LISTENER:-}" ]] || kill "$LISTENER" 2>/dev/null || true; }

listen_on() { # listen_on <port> — un processus python qui écoute quelques secondes ; pid dans $LISTENER
  python3 -c 'import socket,sys,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(128); time.sleep(60)' "$1" &
  LISTENER=$!
  local n=0
  until timeout 1 bash -c "</dev/tcp/127.0.0.1/$1" 2>/dev/null; do n=$((n + 1)); [[ "$n" -lt 10 ]] || return 1; sleep 0.2; done
  return 0
}

docker_stub() { # docker_stub <conteneur> <projet> — un daemon qui répond et publie <conteneur> sur tout port
  cat > "$BATS_TEST_TMPDIR/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in
  version*)                echo "29.0.0" ;;
  "ps --filter publish="*) [[ -n "$1" ]] && echo "$1" ;;
  "inspect -f "*)          echo "$2" ;;
esac
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/docker"
  export PROV_DOCKER_BIN="$BATS_TEST_TMPDIR/docker"
}

ss_muet() { # un ss qui voit l'écoute sans nommer le processus, comme sous WSL ou pour un autre utilisateur
  mkdir -p "$BATS_TEST_TMPDIR/sbin"
  printf '#!/usr/bin/env bash\necho "LISTEN 0 4096 127.0.0.1:%s 0.0.0.0:*"\n' "$1" > "$BATS_TEST_TMPDIR/sbin/ss"
  chmod +x "$BATS_TEST_TMPDIR/sbin/ss"
  export PATH="$BATS_TEST_TMPDIR/sbin:$PATH"
}

@test "port_taken : un port libre rend 1, un port écouté rend 0" {
  export P; P="$(free_port)"
  module_sh '! port_taken "$P"'
  [ "$status" -eq 0 ]
  listen_on "$P"
  module_sh 'port_taken "$P"'
  kill "$LISTENER" 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "port_holder nomme le conteneur qui publie le port, avec son projet" {
  docker_stub autre-forge-gitea-1 autre-forge
  export P; P="$(free_port)"
  module_sh 'port_holder "$P"'
  [ "$status" -eq 0 ]
  [ "$output" = "autre-forge-gitea-1 (projet autre-forge)" ]
}

@test "port_holder nomme un conteneur hors compose tel quel" {
  docker_stub solitaire ""
  export P; P="$(free_port)"
  module_sh 'port_holder "$P"'
  [ "$status" -eq 0 ]
  [ "$output" = "solitaire (projet <hors compose>)" ]
}

@test "port_holder retombe sur le processus vu par ss quand docker ne publie rien" {
  command -v ss >/dev/null || skip "ss absent"
  docker_stub "" ""
  export P; P="$(free_port)"
  listen_on "$P"
  module_sh 'port_holder "$P"'
  kill "$LISTENER" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *python3* ]]
}

@test "port_holder ne rend rien, et rc 0, quand ni docker ni ss ne nomment" {
  docker_stub "" ""
  export P; P="$(free_port)"
  module_sh 'port_holder "$P"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "port_state : libre quand rien n'écoute" {
  docker_stub "" ""
  export P; P="$(free_port)"
  module_sh 'port_state "$P" mien-forge'
  [ "$output" = "libre" ]
}

@test "port_state : nous quand un de nos projets publie le port, même si ss voit l'écoute" {
  docker_stub mien-forge-gitea-1 mien-forge
  export P; P="$(free_port)"
  listen_on "$P"
  module_sh 'port_state "$P" mien-forge mien-fleet'
  kill "$LISTENER" 2>/dev/null || true
  [ "$output" = "nous mien-forge-gitea-1 (projet mien-forge)" ]
}

@test "port_state : pris par, quand un autre conteneur ou un processus nommé publie le port" {
  docker_stub autre-forge-gitea-1 autre-forge
  export P; P="$(free_port)"
  module_sh 'port_state "$P" mien-forge'
  [ "$output" = "pris par autre-forge-gitea-1 (projet autre-forge)" ]
  docker_stub solitaire ""
  module_sh 'port_state "$P" mien-forge'
  [ "$output" = "pris par solitaire (projet <hors compose>)" ]
}

@test "port_state : pris, quand ça écoute et que ni docker ni ss ne savent nommer" {
  docker_stub "" ""
  export P; P="$(free_port)"
  ss_muet "$P"
  listen_on "$P"
  module_sh 'port_state "$P" mien-forge'
  kill "$LISTENER" 2>/dev/null || true
  [ "$output" = "pris" ]
}

@test "PROV_FORGE_URL : l'environnement prime sur forge.url, et une chaîne vide explicite lit le fichier" {
  local d="$BATS_TEST_TMPDIR/tok"; mkdir -p "$d"; echo "http://depuis-le-fichier:3000" > "$d/forge.url"
  PROV_TOKENS_DIR="$d" FORGE_BASE_URL=http://depuis-l-env:9999 module_sh 'echo "$PROV_FORGE_URL"'
  [ "$output" = "http://depuis-l-env:9999" ]
  PROV_TOKENS_DIR="$d" module_sh 'echo "$PROV_FORGE_URL"'
  [ "$output" = "http://depuis-le-fichier:3000" ]
  PROV_TOKENS_DIR="$d" PROV_FORGE_URL="" module_sh 'echo "$PROV_FORGE_URL"'
  [ "$output" = "http://depuis-le-fichier:3000" ]
  mkdir -p "$BATS_TEST_TMPDIR/vide"
  PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/vide" PROV_FORGE_URL="" module_sh 'echo "[$PROV_FORGE_URL]"'
  [ "$output" = "[]" ]
}

@test "PROV_FORGE_PUBLIC_URL : forge.public.url, sinon l'adresse interne, et l'environnement prime" {
  local d="$BATS_TEST_TMPDIR/tok"; mkdir -p "$d"
  echo "http://127.0.0.1:3000" > "$d/forge.url"
  PROV_TOKENS_DIR="$d" module_sh 'echo "$PROV_FORGE_PUBLIC_URL"'
  [ "$output" = "http://127.0.0.1:3000" ]
  echo "http://198.51.100.63:3000" > "$d/forge.public.url"
  PROV_TOKENS_DIR="$d" module_sh 'echo "$PROV_FORGE_URL|$PROV_FORGE_PUBLIC_URL"'
  [ "$output" = "http://127.0.0.1:3000|http://198.51.100.63:3000" ]
  PROV_TOKENS_DIR="$d" FORGE_PUBLIC_URL=http://forge.exemple:3000 module_sh 'echo "$PROV_FORGE_PUBLIC_URL"'
  [ "$output" = "http://forge.exemple:3000" ]
}
