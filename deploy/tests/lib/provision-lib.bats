#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/lib/provision-lib.bats
# AUTHOR: consultant
# STARDATE: 2026-09-14
# STATUS: témoins de lib/provision-lib.sh — verdicts, primitives convergentes, constantes et décor, sondes de la machine, adresse de la forge

# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  unset FORGE_BASE_URL FORGE_PUBLIC_URL DOCKER_HOST

  LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export LIB
  [ -f "$LIB" ]

  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"

  decor_pose
  # le wslinfo de la machine ne répond jamais à un témoin
  printf '#!/usr/bin/env bash\n[[ "$1" != --networking-mode ]] || printf "%%s\\n" "${WSLINFO_MODE:-}"\n' > "$DECOR_BIN/wslinfo"
  chmod +x "$DECOR_BIN/wslinfo"
}

teardown() { [[ -z "${LISTENER:-}" ]] || kill "$LISTENER" 2>/dev/null || true; }

module_sh() {
  run bash -c "set -euo pipefail; export PROVISION_MODULE=test-mod; source \"\$LIB\"; $1"
}

@test "run_quiet : un échec compte un FAIL et rend le code de la commande" {
  module_sh '
    rc=0
    run_quiet bash -c "echo boom-output; exit 3" || rc=$?
    [ "$rc" -eq 3 ]
    [ "$PROV_FAILED" -eq 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *boom-output* ]]
}

@test "run_quiet puis verdict_apply : un échec rend 1" {
  module_sh '
    run_quiet false || verdict_apply
    verdict_apply
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *FAIL* ]]
}

@test "run_capture : un échec rend le code sans verdict, sa sortie attend dans PROV_LAST_OUT" {
  module_sh '
    rc=0
    run_capture bash -c "echo boom-output; exit 3" || rc=$?
    [ "$rc" -eq 3 ]
    [ "$PROV_LAST_RC" -eq 3 ]
    [ "$PROV_FAILED" -eq 0 ]
    [ "$(cat "$PROV_LAST_OUT")" = boom-output ]
    rm -f "$PROV_LAST_OUT"
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "run_capture : un succès ne garde rien" {
  module_sh '
    run_capture bash -c "echo rien"
    [ -z "$PROV_LAST_OUT" ]
    [ "$PROV_LAST_RC" -eq 0 ]
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "run_capture verbeux : la sortie passe à l'écran, rien n'est capturé, le code reste" {
  module_sh '
    export PROV_VERBOSE=1
    rc=0
    run_capture bash -c "echo sortie-directe; exit 5" || rc=$?
    [ "$rc" -eq 5 ]
    [ "$PROV_LAST_RC" -eq 5 ]
    [ -z "$PROV_LAST_OUT" ]
  '
  [ "$status" -eq 0 ]
  [ "$output" = sortie-directe ]
}

@test "prov_dump_last : les dernières lignes de la sortie capturée, le fichier conservé" {
  module_sh '
    export PROV_DUMP_LINES=2
    run_capture bash -c "echo ligne-premiere; echo ligne-deuxieme; echo ligne-troisieme; exit 1" || true
    prov_dump_last
    [ -s "$PROV_LAST_OUT" ]
    rm -f "$PROV_LAST_OUT"
  '
  [ "$status" -eq 0 ]
  # des lignes qu'aucun nom de fichier temporaire ne contient : le chemin conservé est affiché aussi
  [[ "$output" == *"ligne-deuxieme"*"ligne-troisieme"*"conservée"* ]]
  [[ "$output" != *"ligne-premiere"* ]]
}

@test "run_quiet : un succès se tait et ne compte rien" {
  module_sh '
    run_quiet true
    [ "$PROV_FAILED" -eq 0 ]
    [ "$PROV_CHANGED" -eq 0 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
}

@test "ensure_managed_block : un bloc posé compte un changement et garde les lignes humaines" {
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

@test "ensure_managed_block : un échec compte un FAIL et le verdict rougit" {
  module_sh '
    ensure_managed_block "$BATS_TEST_TMPDIR/no-such-dir/x.conf" testmark 0644 <<< "y" || true
    [ "$PROV_FAILED" -ge 1 ]
    verdict_apply
  '
  [ "$status" -eq 1 ]
}

@test "ensure_managed_block : le bloc converge vers la source courante, l'ancien contenu part" {
  module_sh '
    f="$BATS_TEST_TMPDIR/target.conf"
    printf "human line\n" > "$f"
    ensure_managed_block "$f" testmark 0644 <<< "old-content"
    ensure_managed_block "$f" testmark 0644 <<< "new-content"
    grep -q "new-content" "$f"
    grep -q "old-content" "$f" && { echo "l ancien contenu a survécu à la convergence"; exit 1; }
    [ "$(grep -c "lcars:testmark" "$f")" -eq 2 ]
  '
  [ "$status" -eq 0 ]
}

@test "ensure_managed_block : un second passage identique ne change rien" {
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

@test "human_home : un compte inconnu rend vide sous set -euo pipefail, sans arrêter l'appelant" {
  module_sh '
    export PROV_HUMAN=no-such-user-b5-probe
    home="$(human_home)"
    [ -z "$home" ]
    echo survived
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *survived* ]]
}

@test "as_human : un compte inconnu est un FAIL compté, pas un arrêt" {
  module_sh '
    export PROV_HUMAN=no-such-user-b5-probe
    as_human true || true
    [ "$PROV_FAILED" -ge 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"user inconnu"* ]]
}

@test "as_human : root joue la commande depuis le home de l'humain, avec son environnement" {
  local home="$LCARS_DECOR_ROOT/home/zoe"
  mkdir -p "$home"
  printf '#!/usr/bin/env bash\nprintf "zoe:x:1001:1001::%s:/bin/bash\\n"\n' "$home" > "$DECOR_BIN/getent"
  printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$PWD" "$*"\n' > "$DECOR_BIN/runuser"
  chmod +x "$DECOR_BIN/getent" "$DECOR_BIN/runuser"
  run unshare -Ur bash -c 'cd /; . "$LIB" >/dev/null 2>&1; PROV_HUMAN=zoe; as_human pwd'
  [ "$status" -eq 0 ]
  [ "$output" = "$home|-u zoe -- env HOME=$home USER=zoe LOGNAME=zoe pwd" ]
}

_bin_groupes() { # _bin_groupes — doublures de getent/groupadd/id/usermod, pilotées par des marqueurs
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

@test "ensure_group : le groupe absent est créé au gid de la table, et sans gid quand la table n'en fixe pas" {
  _bin_groupes
  module_sh '
    PATH="$BIN_GROUPES:$PATH"
    ensure_group fleet
    ensure_group lcars-authority
    [ "$PROV_CHANGED" -eq 2 ]
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(sed -n 1p "$BATS_TEST_TMPDIR/trace")" = "GROUPADD:-g 2000 fleet" ]
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/trace")" = "GROUPADD:lcars-authority" ]
}

@test "ensure_group : un groupe présent ne se recrée pas, et un gid qui s'écarte de la table est un DRIFT" {
  _bin_groupes
  : > "$BATS_TEST_TMPDIR/groupe-fleet"
  module_sh '
    PATH="$BIN_GROUPES:$PATH"
    ensure_group fleet
    [ "$PROV_CHANGED" -eq 0 ]
    [ "$PROV_DRIFT" -eq 1 ]
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$BATS_TEST_TMPDIR/trace" ]
  [[ "$output" == *"groupe fleet : gid 4242, la table déclare 2000"* ]]
}

@test "ensure_member : un compte hors du groupe y entre par usermod, et le changement est compté" {
  _bin_groupes
  module_sh '
    PATH="$BIN_GROUPES:$PATH"
    ensure_member humain-decor groupe-decor
    [ "$PROV_CHANGED" -eq 1 ]
    grep -q "USERMOD:-aG groupe-decor humain-decor" "$BATS_TEST_TMPDIR/trace"
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "write_atomic : un contenu identique ne change rien, mtime compris" {
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

@test "write_atomic : une écriture qui rate ne bascule rien et ne s'annonce pas posée" {
  local b="$BATS_TEST_TMPDIR/bin-cat"; mkdir -p "$b"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$b/cat"; chmod 0755 "$b/cat"
  export BIN_CAT="$b"
  module_sh '
    PATH="$BIN_CAT:$PATH"
    src="$BATS_TEST_TMPDIR/source"; printf "contenu\n" > "$src"
    f="$BATS_TEST_TMPDIR/plein.conf"
    write_atomic "$f" 0644 < "$src" || true
    [ ! -e "$f" ]
    [ "$PROV_CHANGED" -eq 0 ]
    [ "$PROV_FAILED" -ge 1 ]
  ' 2>/dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"écriture du tampon ratée"* ]]
  refute_out "POSÉ" <<<"$output"
}

@test "write_atomic : un dossier parent absent est un FAIL compté" {
  module_sh '
    write_atomic "$BATS_TEST_TMPDIR/absent-dir/f" 0644 <<< "x" || true
    [ "$PROV_FAILED" -ge 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"dossier absent"* ]]
}

@test "ensure_dir : un lien vers un dossier est refusé, sa cible garde son mode" {
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

@test "ensure_dir : un lien au milieu du chemin est refusé aussi" {
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

@test "ensure_mode : la forme « user: » est idempotente, le second passage ne rechowne pas" {
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

@test "prov_promote_dir : un final existant est remplacé par l'échafaudage, rien ne reste à côté, et un final absent est simplement posé" {
  module_sh '
    mkdir -p "$BATS_TEST_TMPDIR/p/final" "$BATS_TEST_TMPDIR/p/final.new"
    echo ancien > "$BATS_TEST_TMPDIR/p/final/x"; echo nouveau > "$BATS_TEST_TMPDIR/p/final.new/x"
    prov_promote_dir "$BATS_TEST_TMPDIR/p/final.new" "$BATS_TEST_TMPDIR/p/final"
    [ "$(cat "$BATS_TEST_TMPDIR/p/final/x")" = nouveau ]
    [ ! -e "$BATS_TEST_TMPDIR/p/final.new" ]
    [ "$(ls "$BATS_TEST_TMPDIR/p" | tr "\n" " ")" = "final " ]
    mkdir -p "$BATS_TEST_TMPDIR/q/final.new"; echo seul > "$BATS_TEST_TMPDIR/q/final.new/x"
    prov_promote_dir "$BATS_TEST_TMPDIR/q/final.new" "$BATS_TEST_TMPDIR/q/final"
    [ "$(cat "$BATS_TEST_TMPDIR/q/final/x")" = seul ]
    [ "$(ls "$BATS_TEST_TMPDIR/q" | tr "\n" " ")" = "final " ]
  '
  [ "$status" -eq 0 ]
}

@test "prov_promote_dir : une bascule refusée laisse l'ancien final en place, dit, rc 1" {
  module_sh '
    mkdir -p "$BATS_TEST_TMPDIR/r/final" "$BATS_TEST_TMPDIR/r/final.new"
    echo ancien > "$BATS_TEST_TMPDIR/r/final/x"
    mv() { if [[ "$*" == *final.new* ]]; then return 1; fi; command mv "$@"; }
    rc=0; prov_promote_dir "$BATS_TEST_TMPDIR/r/final.new" "$BATS_TEST_TMPDIR/r/final" || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(cat "$BATS_TEST_TMPDIR/r/final/x")" = ancien ]
    [ "$(ls "$BATS_TEST_TMPDIR/r" | tr "\n" " ")" = "final final.new " ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"bascule refusée"* ]]
}

@test "hors décor, « user: » arrive à chown avec le groupe de connexion nommé — les coreutils uutils ignorent la forme nue" {
  local faux="$BATS_TEST_TMPDIR/bin"; mkdir -p "$faux"
  printf '#!/usr/bin/env bash\nfor a; do [[ "$a" == -* ]] || { printf "%%s\\n" "$a" >> "%s"; break; }; done\nexec /usr/bin/chown "$@"\n' "$BATS_TEST_TMPDIR/chown.argv" > "$faux/chown"
  chmod +x "$faux/chown"
  PATH="$faux:$PATH" module_sh '
    unset LCARS_DECOR_ROOT
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

@test "prov_owner sous un décor : tout propriétaire nommé devient le compte qui joue le cas, un propriétaire vide reste vide" {
  module_sh 'printf "%s|%s|[%s]\n" "$(prov_owner root:fleet)" "$(prov_owner lcars-authority:)" "$(prov_owner "")"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(id -un):$(id -gn)|$(id -un):$(id -gn)|[]" ]
}

@test "ensure_mode : un groupe nommé se compare en entier, le second passage ne change rien" {
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

@test "ensure_mode : le propriétaire est relu après chown — un chown qui rend 0 sans rien changer est un échec" {
  local bin="$BATS_TEST_TMPDIR/bin-chown"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/chown"; chmod 0755 "$bin/chown"
  module_sh '
    PATH="'"$bin"':$PATH"
    unset LCARS_DECOR_ROOT   # sous le décor, tout appartient à qui joue : le propriétaire demandé ne serait jamais root
    f="$BATS_TEST_TMPDIR/proprio"; : > "$f"; chmod 0644 "$f"
    ensure_mode "$f" 0644 root:root || true
    [ "$PROV_FAILED" -eq 1 ]
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL  test-mod: ensure_mode: propriétaire $(id -un):$(id -gn) ≠ root:root après chown"* ]]
}

@test "ensure_mode : un lien cassé se dit lien, pas absent" {
  module_sh '
    ln -s "$BATS_TEST_TMPDIR/nulle-part" "$BATS_TEST_TMPDIR/casse"
    ensure_mode "$BATS_TEST_TMPDIR/casse" 0600 || true
    [ "$PROV_FAILED" -ge 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"composant symlink"* ]]
  [[ "$output" != *"ensure_mode: absent"* ]]
}

@test "write_atomic : refuse d'écrire à travers un parent lien" {
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

@test "ensure_dir et write_atomic : un chemin sans lien converge normalement" {
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

@test "ensure_symlink : pose le lien, la garde ne vise que le parent" {
  module_sh '
    ensure_symlink "$BATS_TEST_TMPDIR/lien-legitime" /dev/null
    [ "$PROV_FAILED" -eq 0 ]
    [ "$PROV_CHANGED" -eq 1 ]
    [ "$(readlink "$BATS_TEST_TMPDIR/lien-legitime")" = "/dev/null" ]
  '
  [ "$status" -eq 0 ]
}

@test "prov_lock_path : ignore TMPDIR" {
  module_sh '
    export TMPDIR="$BATS_TEST_TMPDIR/pirate"; mkdir -p "$TMPDIR"
    lock="$(prov_lock_path)" || true
    [[ "$lock" != "$TMPDIR"* ]]
  '
  [ "$status" -eq 0 ]
}

@test "prov_lock_path : le verrou pris deux fois se bloque" {
  module_sh '
    exec 8>"$(prov_lock_path)"; flock -n 8 || exit 1
    exec 7>"$(prov_lock_path)"
    flock -n 7 && exit 2
    exec 7>&-; exec 8>&-
  '
  [ "$status" -eq 0 ]
}

@test "prov_lock_path : le verrou vit dans un dossier 0700 possédé par l'appelant" {
  module_sh '
    lock="$(prov_lock_path)"
    dir="$(dirname "$lock")"
    [ "$(stat -c %a "$dir")" = "700" ]
    [ "$(stat -c %u "$dir")" = "$(id -u)" ]
  '
  [ "$status" -eq 0 ]
}

@test "prov_lock_path : sans dossier runtime, un refus qui nomme le parent" {
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/absent/xdg"
  module_sh 'prov_lock_path'
  [ "$status" -ne 0 ]
  [[ "$output" == *"$BATS_TEST_TMPDIR/absent"* ]]
  [[ "$output" == *"pas d'emplacement sûr"* ]]
}

@test "advertise_addr : un bind précis est l'adresse" {
  module_sh '
    advertise_addr 127.0.0.5
    [ "$PROV_ADVERTISE" = "127.0.0.5" ]
    [ -z "$PROV_ADVERTISE_WHY" ]
  '
  [ "$status" -eq 0 ]
}

@test "advertise_addr : WSL en NAT annonce localhost et dit pourquoi" {
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

@test "advertise_addr : WSL en miroir annonce l'adresse de sortie" {
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

@test "advertise_addr : sans adresse de sortie, la loopback annoncée comme telle" {
  module_sh '
    PROV_SUBSTRATE=linux
    lan_addr() { echo ""; }
    advertise_addr 0.0.0.0
    [ "$PROV_ADVERTISE" = "127.0.0.1" ]
    [ -n "$PROV_ADVERTISE_WHY" ]
  '
  [ "$status" -eq 0 ]
}

@test "advertise_addr : n'imprime rien, les réponses sortent par les globales" {
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

@test "wsl_networking_mode : le mode que wslinfo dit, nat quand il ne dit rien" {
  WSLINFO_MODE=mirrored module_sh 'wsl_networking_mode'
  [ "$output" = mirrored ]
  module_sh 'wsl_networking_mode'
  [ "$output" = nat ]
}

@test "_prov_phase_of : compilation, release posée, et démarrage pour tout le reste" {
  local f="$BATS_TEST_TMPDIR/out"
  module_sh '
    f="'"$f"'"
    printf "Compiling 3 files\n"                         > "$f"; _prov_phase_of "$f"
    printf "Compiling 3 files\nRelease created at _build\n" > "$f"; _prov_phase_of "$f"
    printf "Running ExUnit\n"                            > "$f"; _prov_phase_of "$f"
    : > "$f"                                                   ; _prov_phase_of "$f"
    _prov_phase_of "/nonexistent/pas-de-fichier"
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "compilation" ]
  [ "${lines[1]}" = "release posée" ]
  [ "${lines[2]}" = "démarrage" ]
  [ "${lines[3]}" = "démarrage" ]
  [ "${lines[4]}" = "démarrage" ]
}

@test "run_step : une ligne par changement de phase, pas une par seconde" {
  module_sh '
    run_step "build" -- bash -c "echo Compiling 3 files; sleep 3.5"
  '
  [ "$status" -eq 0 ]
  local n; n="$(printf '%s\n' "$output" | grep -c '>>')"
  [ "$n" -ge 1 ]
  [ "$n" -lt 3 ]
  [ "$(printf '%s\n' "$output" | grep '>>' | sort -u | wc -l)" -eq "$n" ]
  [[ "$output" == *"build · compilation"* ]]
}

@test "run_step : le code de l'enfant traverse la boucle de sonde" {
  module_sh '
    run_step "build" -- bash -c "echo Compiling 3 files; exit 3" || echo "RC=$?"
  '
  [[ "$output" == *"RC=3"* ]]
}

@test "run_step : un échec garde le code, compte, borne l'écran et conserve le fichier" {
  module_sh '
    export PROV_DUMP_LINES=3
    rc=0
    run_step "etape" -- bash -c "for i in \$(seq 1 200); do echo ligne-\$i; done; sleep 1.1; exit 7" || rc=$?
    [ "$rc" -eq 7 ]
    [ "$PROV_FAILED" -eq 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAIL  test-mod: commande en échec (rc=7) : etape"* ]]
  [[ "$output" == *"ligne-200"* ]]
  [[ "$output" != *"ligne-100"* ]]
  [[ "$output" == *"sortie COMPLÈTE conservée"* ]]
  f="$(printf '%s\n' "$output" | sed -n 's/.*conservée : \([^ ]*\).*/\1/p' | tail -n1)"
  [ -s "$f" ]
  [ "$(wc -l < "$f")" -eq 200 ]
  rm -f "$f"
}

@test "run_step : un succès ne laisse aucun fichier derrière lui" {
  local container="$BATS_TEST_TMPDIR/tmp-run-step"; mkdir -p "$container"
  TMPDIR="$container" module_sh 'run_step "ok" -- bash -c "echo rien; sleep 1.1"'
  [ "$status" -eq 0 ]
  [ -z "$(find "$container" -maxdepth 1 -name 'prov-out.*')" ]
}

@test "run_step --ok N : un code toléré rend 0 sans verdict et sans fichier" {
  module_sh '
    run_step --ok 3 "etape" -- bash -c "sleep 1.1; exit 3"
    [ "$PROV_LAST_RC" -eq 3 ]
    [ "$PROV_FAILED" -eq 0 ]
    [ -z "$PROV_LAST_OUT" ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"OK    test-mod:"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "run_step --ok N : un code non toléré reste un échec entier" {
  module_sh '
    rc=0
    run_step --ok 3 "etape" -- bash -c "echo boum; sleep 1.1; exit 4" || rc=$?
    [ "$rc" -eq 4 ]
    [ "$PROV_FAILED" -eq 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "run_step verbeux : le libellé à l'écran, chaque --ok toléré, sans verdict" {
  module_sh '
    export PROV_VERBOSE=1
    run_step --ok 1 --ok 2 "etape" -- bash -c "exit 2"
    [ "$PROV_LAST_RC" -eq 2 ]
    [ "$PROV_FAILED" -eq 0 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *">>    test-mod: etape"* ]]
  [[ "$output" != *"OK    test-mod:"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "run_step verbeux : un code non toléré reste un échec entier, et PROV_LAST_RC le dit" {
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

@test "lan_addr : vide sans ip, et advertise_addr annonce quand même une adresse" {
  module_sh '
    a="$(PATH=/nonexistent lan_addr)"
    [ -z "$a" ]
    PATH=/nonexistent advertise_addr 0.0.0.0
    [ -n "$PROV_ADVERTISE" ]
  '
  [ "$status" -eq 0 ]
}

@test "prov_seat_binding : la table et le candidat unix s'accordent → agree" {
  printf '1\t1000\tamiral\n' > "$LCARS_DECOR_ROOT/opt/lcars/var/tokens/forge-uid.map"
  module_sh 'prov_seat_binding amiral; echo "$PROV_SEAT_BINDING|$PROV_SEAT_LOGIN|$PROV_SEAT_SOURCE"'
  [ "$status" -eq 0 ]
  [ "$output" = "agree|amiral|table" ]
}

@test "prov_seat_binding : la table et le candidat divergent → diverge, et la table fait foi" {
  printf '1\t1000\tamiral\n' > "$LCARS_DECOR_ROOT/opt/lcars/var/tokens/forge-uid.map"
  module_sh 'prov_seat_binding quelquun-dautre; echo "$PROV_SEAT_BINDING|$PROV_SEAT_LOGIN|$PROV_SEAT_SOURCE"'
  [ "$status" -eq 0 ]
  [ "$output" = "diverge|amiral|table" ]
}

@test "prov_seat_binding : ni table ni jeton master → seeded, le candidat est le siège" {
  module_sh 'prov_seat_binding loperateur; echo "$PROV_SEAT_BINDING|$PROV_SEAT_LOGIN|$PROV_SEAT_SOURCE"'
  [ "$status" -eq 0 ]
  [ "$output" = "seeded|loperateur|candidat" ]
}

@test "prov_seat_binding : la table passe avant la forge, aucune requête ne part" {
  printf '1\t1000\tamiral\n' > "$LCARS_DECOR_ROOT/opt/lcars/var/tokens/forge-uid.map"
  printf 'jeton-master\n' > "$LCARS_DECOR_ROOT/opt/lcars/var/tokens/forge-master.token"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 7\n' "$BATS_TEST_TMPDIR/curl.appels" > "$DECOR_BIN/curl"
  chmod +x "$DECOR_BIN/curl"
  module_sh 'prov_seat_binding amiral; echo "$PROV_SEAT_BINDING|$PROV_SEAT_SOURCE"'
  [ "$output" = "agree|table" ]
  [ ! -e "$BATS_TEST_TMPDIR/curl.appels" ]
}

@test "prov_seat_record : la ligne du siège s'ajoute à la carte, mode 0640, et prov_seat_from_map la relit" {
  module_sh 'prov_seat_record amiral 1000; prov_seat_from_map'
  [ "$status" -eq 0 ]
  [ "$output" = amiral ]
  [ "$(cat "$LCARS_DECOR_ROOT/opt/lcars/var/tokens/forge-uid.map")" = "$(printf '1\t1000\tamiral')" ]
  [ "$(stat -c %a "$LCARS_DECOR_ROOT/opt/lcars/var/tokens/forge-uid.map")" = 640 ]
}

stub_dpkg() { # stub_dpkg <arch> — un dpkg qui répond <arch>
  printf '#!/usr/bin/env bash\n[ "$1" = --print-architecture ] && echo %s\n' "$1" > "$DECOR_BIN/dpkg"
  chmod +x "$DECOR_BIN/dpkg"
}

@test "arch_tag : amd64 se dit x64 chez node, amd64 chez debian, et raw rend dpkg tel quel" {
  stub_dpkg amd64
  module_sh 'printf "%s|%s|%s\n" "$(arch_tag node)" "$(arch_tag debian)" "$(arch_tag raw)"'
  [ "$output" = "x64|amd64|amd64" ]
  stub_dpkg arm64
  module_sh 'printf "%s|%s\n" "$(arch_tag node)" "$(arch_tag debian)"'
  [ "$output" = "arm64|arm64" ]
}

@test "arch_tag : une arch non épinglée rend vide, et sans dpkg tout est vide" {
  stub_dpkg riscv64
  module_sh 'printf "[%s|%s|%s]\n" "$(arch_tag node)" "$(arch_tag debian)" "$(arch_tag raw)"'
  [ "$output" = "[||riscv64]" ]
  rm -f "$DECOR_BIN/dpkg"
  module_sh 'PATH="$DECOR_BIN"; printf "[%s|%s]\n" "$(arch_tag node)" "$(arch_tag raw)"'
  [ "$output" = "[|]" ]
}

@test "set_diff : les lignes de b absentes de a — trie, dédoublonne, ignore le vide" {
  module_sh '
    out="$(set_diff $'"'"'b\na\n\nc'"'"' $'"'"'c\nd\na\nd\n'"'"')"
    [ "$out" = d ]
    [ -z "$(set_diff $'"'"'x\ny'"'"' $'"'"'y\nx'"'"')" ]
    [ "$(set_diff "" $'"'"'z\nz'"'"')" = z ]
  '
  [ "$status" -eq 0 ]
}

@test "env_field : fichier absent = vide et 0 ; clé répétée = la dernière, comme un source" {
  printf 'A=1\nB=premier\nB=dernier\n' > "$BATS_TEST_TMPDIR/e.env"
  module_sh '
    [ -z "$(env_field /nonexistent/x.env A)" ]
    [ "$(env_field "$BATS_TEST_TMPDIR/e.env" A)" = 1 ]
    [ "$(env_field "$BATS_TEST_TMPDIR/e.env" B)" = dernier ]
    [ -z "$(env_field "$BATS_TEST_TMPDIR/e.env" C)" ]
  '
  [ "$status" -eq 0 ]
}

@test "read_token : absent = vide, rc 0 et aucun message ; présent = le jeton sans blancs" {
  printf '  jeton \n' > "$BATS_TEST_TMPDIR/t"
  module_sh '
    out="$(read_token /nonexistent/jeton 2>&1)"; [ -z "$out" ]
    out="$(read_token "" 2>&1)"; [ -z "$out" ]
    [ "$(read_token "$BATS_TEST_TMPDIR/t")" = jeton ]
  '
  [ "$status" -eq 0 ]
}

@test "p_fact : sans fichier de faits, rien d'écrit et rien de dit" {
  module_sh '
    out="$(p_fact substrat wsl 2>&1)"
    [ -z "$out" ]
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "p_fact : une ligne nom=valeur par fait, dans l'ordre, la valeur garde ses espaces" {
  module_sh "
    export PROV_FACTS_FILE='$BATS_TEST_TMPDIR/facts'
    p_fact substrat wsl
    p_fact docker_why 'le daemon repond mais pas a cet utilisateur'
    p_fact docker_why2 le daemon repond pas
  "
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/facts"
  [ "${lines[0]}" = "substrat=wsl" ]
  [ "${lines[1]}" = "docker_why=le daemon repond mais pas a cet utilisateur" ]
  [ "${lines[2]}" = "docker_why2=le daemon repond pas" ]
}

@test "p_fact : un fichier de faits inécrivable n'arrête pas le module et ne dit rien" {
  module_sh "
    export PROV_FACTS_FILE='/nonexistent/repertoire/facts'
    out=\$(p_fact substrat wsl 2>&1)
    [ -z \"\$out\" ]
    p_ok 'le module continue apres'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"le module continue apres"* ]]
}

@test "p_fact : ne renverse pas le verdict qu'il rapporte" {
  module_sh "
    export PROV_FACTS_FILE='$BATS_TEST_TMPDIR/facts'
    p_ok 'conforme'
    p_fact substrat wsl
    verdict_check
  "
  [ "$status" -eq 0 ]
}

@test "prov_dans_la_copie : vrai quand le rail tourne depuis la racine posée" {
  module_sh '
    D="$BATS_TEST_TMPDIR/copie"; mkdir -p "$D"
    repo_root() { echo "$D"; }
    PROV_ROOT="$D"
    prov_dans_la_copie
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "prov_dans_la_copie : faux depuis l'arbre de travail" {
  module_sh '
    mkdir -p "$BATS_TEST_TMPDIR/travail" "$BATS_TEST_TMPDIR/opt"
    repo_root() { echo "$BATS_TEST_TMPDIR/travail"; }
    PROV_ROOT="$BATS_TEST_TMPDIR/opt"
    rc=0; prov_dans_la_copie || rc=$?
    [ "$rc" -eq 1 ]
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "prov_dans_la_copie : faux depuis un voisin dont le nom prolonge la racine" {
  module_sh '
    mkdir -p "$BATS_TEST_TMPDIR/opt"
    repo_root() { echo "$BATS_TEST_TMPDIR/opt-voisin"; }
    PROV_ROOT="$BATS_TEST_TMPDIR/opt"
    rc=0; prov_dans_la_copie || rc=$?
    [ "$rc" -eq 1 ]
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "ensure_mode : un setgid hérité est retiré quand le mode demandé ne le porte pas, et posé quand il le porte" {
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

pt_root() { # pt_root <racine> → ce que product_tree rend avec la lib copiée sous <racine>/deploy/lib
  mkdir -p "$1/deploy/lib"
  cp "$LIB" "$BATS_TEST_DIRNAME/../../lib/docker-endpoint.sh" "$1/deploy/lib/"
  cp "$BATS_TEST_DIRNAME/../../installer-constants.env" "$1/deploy/"
  PROVISION_LIB="$1/deploy/lib/provision-lib.sh" bash -c '. "$PROVISION_LIB" >/dev/null 2>&1; product_tree'
}

@test "product_tree : un checkout (runtime/ présent, pas de services/ à la racine) → runtime/" {
  local r="$BATS_TEST_TMPDIR/co"; mkdir -p "$r/runtime/etc"
  [ "$(pt_root "$r")" = "$r/runtime" ]
}

@test "product_tree : une machine posée (services/ à plat, runtime/ = la release) → la racine" {
  local r="$BATS_TEST_TMPDIR/posee"; mkdir -p "$r/runtime/rel/lcars_fleet" "$r/services/human.d" "$r/etc"
  [ "$(pt_root "$r")" = "$r" ]
}

@test "product_tree : une release illisible ne change pas la réponse" {
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

@test "prov_in_group : un groupe dont le nom est un préfixe d'un autre n'est pas pris pour lui" {
  module_sh 'id() { echo "fleet-console fleet_bis"; }; prov_in_group x fleet || echo DEHORS; prov_in_group x fleet_bis && echo DEDANS'
  [[ "$output" == *"DEHORS"* ]]
  [[ "$output" == *"DEDANS"* ]]
}

@test "prov_in_group : un compte inconnu → 1, sans bruit sur stderr" {
  module_sh 'if prov_in_group compte-decor-inexistant-di13 fleet; then echo DEDANS; else echo DEHORS; fi'
  [ "$output" = "DEHORS" ]
}

@test "prov_pgrep_pattern : le motif trouve la cible et jamais la commande qui le porte" {
  local m; m="$(bash -c "source '$LIB' >/dev/null 2>&1; prov_pgrep_pattern zorglub-$$")"
  [ "$m" = "[z]orglub-$$" ]
  run bash -c "pgrep -f '$m' >/dev/null && echo VU || echo PAS-VU"
  [[ "$output" == *"PAS-VU"* ]]
  run bash -c "pgrep -f 'zorglub-$$' >/dev/null && echo VU || echo PAS-VU"
  [[ "$output" == "VU" ]]
}

uid_decor() { # login.defs, passwd et siège sous le décor
  printf 'UID_MIN\t1000\nUID_MAX\t60000\n' > "$LCARS_DECOR_ROOT/etc/login.defs"
  printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' 'svc:x:999:999::/nonexistent:/usr/sbin/nologin' \
    'admiral:x:1000:1000::/home/admiral:/bin/bash' 'zoe:x:1001:1001::/home/zoe:/bin/bash' \
    'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin' > "$LCARS_DECOR_ROOT/etc/passwd"
  printf '1000\n' > "$LCARS_DECOR_ROOT/etc/lcars/seat.uid"
}

@test "fleet_humans : les comptes entre les bornes de login.defs, lus dans le passwd du décor, le siège exclu" {
  uid_decor
  module_sh 'fleet_humans'
  [ "$status" -eq 0 ]
  [ "$output" = zoe ]
}

@test "prov_uid_bounds : des bornes illisibles ne disent rien, le remède attend dans PROV_UID_BOUNDS_WHY" {
  module_sh 'rc=0; prov_uid_bounds || rc=$?; printf "%s|%s|%s\n" "$rc" "$PROV_UID_MIN" "$PROV_UID_BOUNDS_WHY" > "$BATS_TEST_TMPDIR/bornes"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$(cat "$BATS_TEST_TMPDIR/bornes")" == "1||la frontiere systeme/humain n'est pas etablie (UID_MIN illisible dans $LCARS_DECOR_ROOT/etc/login.defs)"* ]]
}

@test "prov_uid_bounds : UID_MAX absent n'établit pas la frontière, aucune borne n'est devinée" {
  printf 'UID_MIN\t1000\n' > "$LCARS_DECOR_ROOT/etc/login.defs"
  module_sh 'rc=0; prov_uid_bounds || rc=$?; printf "%s|%s|%s|%s\n" "$rc" "$PROV_UID_MIN" "$PROV_UID_MAX" "$PROV_UID_BOUNDS_WHY"'
  [ "$output" = "1|||la frontiere systeme/humain n'est pas etablie (UID_MAX illisible dans $LCARS_DECOR_ROOT/etc/login.defs) — la borne est declaree par le systeme, pas par ce processus : repare $LCARS_DECOR_ROOT/etc/login.defs" ]
}

@test "fleet_humans : sans bornes, personne sur stdout et le remède sur stderr" {
  uid_decor
  rm "$LCARS_DECOR_ROOT/etc/login.defs"
  run --separate-stderr bash -c '. "$LIB" >/dev/null 2>&1; fleet_humans'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == "fleet_humans: la frontiere systeme/humain n'est pas etablie (UID_MIN illisible dans $LCARS_DECOR_ROOT/etc/login.defs)"* ]]
}

@test "fleet_humans : sans siège, personne sur stdout et le siège manquant nommé sur stderr" {
  uid_decor
  rm "$LCARS_DECOR_ROOT/etc/lcars/seat.uid"
  run --separate-stderr bash -c '. "$LIB" >/dev/null 2>&1; fleet_humans'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == "fleet_humans: siège non établi (ni $LCARS_DECOR_ROOT/etc/lcars/seat.uid, ni LCARS_SYSADMIN_UID)"* ]]
}

@test "frontière des humains : la lib et le protocole du produit rendent la même population et la même phrase" {
  uid_decor
  local proto="$BATS_TEST_DIRNAME/../../../runtime/services/lib/human-protocol.sh" ubin="$BATS_TEST_TMPDIR/ubin"
  [ -f "$proto" ]
  mkdir -p "$ubin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *zoe*) echo 1001 ;; *admiral*) echo 1000 ;; *svc*) echo 999 ;; *nobody*) echo 65534 ;; *root*) echo 0 ;; *) exit 1 ;; esac' \
    > "$ubin/id"
  chmod 0755 "$ubin/id"
  local defs="$LCARS_DECOR_ROOT/etc/login.defs" variant lib_dit proto_dit bad=0
  for variant in lisible absent sans-max plancher-2000; do
    case "$variant" in
      lisible)       printf 'UID_MIN\t1000\nUID_MAX\t60000\n' > "$defs" ;;
      absent)        rm -f "$defs" ;;
      sans-max)      printf 'UID_MIN\t1000\n' > "$defs" ;;
      plancher-2000) printf 'UID_MIN\t2000\nUID_MAX\t60000\n' > "$defs" ;;
    esac
    lib_dit="$(bash -c '. "$LIB" >/dev/null 2>&1
      pop="$(fleet_humans 2>/dev/null | paste -sd, -)"; prov_uid_bounds || true
      printf "%s|%s" "$pop" "$PROV_UID_BOUNDS_WHY"')"
    proto_dit="$(PATH="$ubin:$PATH" LCARS_SYSADMIN_UID=1000 LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/absent" PASSWD_DEFS="$defs" \
      LCARS_HUMAN_PROTOCOL_HOST=1 LCARS_MODULE_PROTOCOL="$(dirname "$proto")/module-protocol.sh" LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR" \
      bash -c '. "$1"; pop=""
        for l in root svc admiral zoe nobody; do if is_fleet_human "$l" 2>/dev/null; then pop="${pop:+$pop,}$l"; fi; done
        printf "%s|%s" "$pop" "$UID_BOUNDS_WHY"' _ "$proto")"
    [ "$lib_dit" = "$proto_dit" ] || { echo "$variant : lib=« $lib_dit » protocole=« $proto_dit »" >&2; bad=1; }
  done
  [ "$bad" -eq 0 ]
  [[ "$lib_dit" == "|" ]]
}

@test "apt_ensure : apt-get reçoit un délai et des reprises, et un miroir mort en http se dit avec le remède https" {
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
  grep -qE '^update .*-o Acquire' "$b/argv"   # le verbe d'abord : les doublures lisent $1
  [[ "$output" == *"archive.ubuntu.com injoignable en http alors que https://archive.ubuntu.com répond"* ]]
  [[ "$output" == *"passer les sources apt en https"* ]]
}

@test "apt_ensure : miroir vivant mais apt en échec — le diagnostic ne met pas le réseau en cause" {
  local b="$BATS_TEST_TMPDIR/apt2"; mkdir -p "$b"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "not-installed"' > "$b/dpkg-query"
  printf '%s\n' '#!/usr/bin/env bash' 'case " $* " in *" indextargets "*) echo "http://archive.ubuntu.com/ubuntu/dists/x/InRelease"; exit 0;; esac' 'exit 100' > "$b/apt-get"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$b/curl"
  chmod 0755 "$b"/*
  run bash -c "set -uo pipefail; export PATH=\"$b:$PATH\"; . '$LIB' >/dev/null 2>&1; PROV_CHANGED=0 PROV_FAILED=0; apt_ensure jq; echo rc=\$?"
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"le miroir http://archive.ubuntu.com répond"* ]]
  refute_out 'injoignable' <<<"$output"
}

canal() { # canal <code bash> — la lib sourcée, verdicts à zéro, sous le décor
  run bash -c "set -euo pipefail; export PROVISION_MODULE=test-mod; . \"\$LIB\" >/dev/null 2>&1; PROV_CHANGED=0 PROV_FAILED=0 PROV_DRIFT=0; $1"
}

@test "prov_channel : les deux valeurs se lisent dans le canal du décor, et son absence dit « aucun »" {
  local f="$LCARS_DECOR_ROOT/etc/lcars/channel" v
  for v in source kit; do
    printf '%s\n' "$v" > "$f"
    canal 'prov_channel; echo "global=$PROV_CHANNEL"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$v" ]
    [ "${lines[1]}" = "global=$v" ]
  done
  rm -f "$f"
  canal 'prov_channel; echo "global=$PROV_CHANNEL"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "aucun" ]
  [ "${lines[1]}" = "global=aucun" ]
}

@test "prov_channel : une valeur hors vocabulaire est un FAIL qui nomme le fichier — rien sur stdout, rc 1, compté" {
  local f="$LCARS_DECOR_ROOT/etc/lcars/channel"
  printf 'snap\n' > "$f"
  canal 'prov_channel >/dev/null || echo "rc=$?"; echo "failed=$PROV_FAILED global=[$PROV_CHANNEL]"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAIL"*"canal d'installation illisible : $f porte « snap », attendu source ou kit"* ]]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"failed=1 global=[]"* ]]
  canal 'v="$(prov_channel 2>/dev/null)" || true; echo "v=[$v]"'
  [[ "$output" == *"v=[]"* ]]
}

@test "prov_channel_write : pose la valeur au mode de la table, atomique et idempotent" {
  local f="$LCARS_DECOR_ROOT/etc/lcars/channel"
  canal 'prov_channel_write kit; echo "changed=$PROV_CHANGED"'
  [ "$status" -eq 0 ]
  [ "$(cat "$f")" = "kit" ]
  [ "$(stat -c '%a' "$f")" = "644" ]
  [[ "$output" == *"POSÉ"*"changed=1"* ]]
  canal 'prov_channel_write kit; echo "changed=$PROV_CHANGED"'
  [[ "$output" == *"changed=0"* ]]
  canal 'prov_channel_write source'
  [ "$(cat "$f")" = "source" ]
  [ -z "$(find "$(dirname "$f")" -name '.prov.*')" ]
}

@test "prov_channel : un produit posé sans canal dit « inconnu », une machine vierge « aucun »" {
  mkdir -p "$LCARS_DECOR_ROOT/opt/lcars/runtime"
  canal 'prov_channel; echo "var=$PROV_CHANNEL"'
  [ "$output" = "$(printf 'inconnu\nvar=inconnu')" ]
  rmdir "$LCARS_DECOR_ROOT/opt/lcars/runtime"
  canal 'prov_channel'
  [ "$output" = "aucun" ]
}

@test "prov_substrate_satisfait : espace et + séparent la liste de la même façon, et « any » accueille tout" {
  run bash -c ". '$LIB'; prov_substrate_satisfait 'wsl linux' linux"
  [ "$status" -eq 0 ]
  run bash -c ". '$LIB'; prov_substrate_satisfait 'wsl+linux' linux"
  [ "$status" -eq 0 ]
  run bash -c ". '$LIB'; prov_substrate_satisfait 'wsl+linux' wsl"
  [ "$status" -eq 0 ]
  run bash -c ". '$LIB'; prov_substrate_satisfait any docker"
  [ "$status" -eq 0 ]
}

@test "prov_substrate_satisfait : un mot ne satisfait que lui-même" {
  run bash -c ". '$LIB'; prov_substrate_satisfait linux docker"
  [ "$status" -eq 1 ]
  run bash -c ". '$LIB'; prov_substrate_satisfait linux wsl"
  [ "$status" -eq 1 ]
  run bash -c ". '$LIB'; prov_substrate_satisfait 'wsl+linux' docker"
  [ "$status" -eq 1 ]
}

@test "prov_load_constants : un chemin absolu se lit sous le décor, une autre valeur reste telle quelle" {
  printf '%s\n' '# commentaire' 'CHEMIN=/etc/lcars/x' 'MOT=fleet' 'PHRASE=deux mots' 'minuscule=/ignoree' > "$BATS_TEST_TMPDIR/c.env"
  module_sh 'prov_load_constants "$BATS_TEST_TMPDIR/c.env"; printf "%s|%s|%s|[%s]\n" "$CHEMIN" "$MOT" "$PHRASE" "${minuscule:-}"'
  [ "$status" -eq 0 ]
  [ "$output" = "$LCARS_DECOR_ROOT/etc/lcars/x|fleet|deux mots|[]" ]
}

@test "prov_load_constants : la valeur est tout ce qui suit le premier « = », un « = » final compris, comme compose la lit" {
  printf 'A=u=\nB=a=b c\nC=\n' > "$BATS_TEST_TMPDIR/c.env"
  module_sh 'prov_load_constants "$BATS_TEST_TMPDIR/c.env"; printf "[%s][%s][%s]\n" "$A" "$B" "$C"'
  [ "$status" -eq 0 ]
  [ "$output" = "[u=][a=b c][]" ]
}

@test "prov_load_constants : la dernière ligne sans fin de ligne est lue" {
  printf 'A=1\nB=/etc/b' > "$BATS_TEST_TMPDIR/c.env"
  module_sh 'prov_load_constants "$BATS_TEST_TMPDIR/c.env"; echo "$A|${B:-}"'
  [ "$status" -eq 0 ]
  [ "$output" = "1|$LCARS_DECOR_ROOT/etc/b" ]
}

@test "prov_load_constants : une constante exportée par l'environnement est écrasée au chargement de la lib" {
  PROV_ROOT=/tmp/ailleurs PROV_TOKENS_DIR=/x module_sh 'printf "%s|%s\n" "$PROV_ROOT" "$PROV_TOKENS_DIR"'
  [ "$status" -eq 0 ]
  [ "$output" = "$LCARS_DECOR_ROOT/opt/lcars|$LCARS_DECOR_ROOT/opt/lcars/var/tokens" ]
}

@test "prov_load_constants : un fichier illisible arrête avec son nom" {
  module_sh 'prov_load_constants "$BATS_TEST_TMPDIR/absent.env"; echo ATTEINT'
  [ "$status" -eq 1 ]
  [ "$output" = "ÉCHEC : constantes de l'installeur illisibles : $BATS_TEST_TMPDIR/absent.env" ]
}

@test "prov_decor et prov_canon : un chemin système va sous le décor, et en revient" {
  module_sh 'printf "%s\n%s\n%s\n" "$(prov_decor /etc/passwd)" "$(prov_canon "$LCARS_DECOR_ROOT/etc/lcars/channel")" "$(prov_canon /etc/hosts)"'
  [ "${lines[0]}" = "$LCARS_DECOR_ROOT/etc/passwd" ]
  [ "${lines[1]}" = /etc/lcars/channel ]
  [ "${lines[2]}" = /etc/hosts ]
  run env -u LCARS_DECOR_ROOT bash -c '. "$LIB" >/dev/null 2>&1; prov_decor /etc/passwd'
  [ "$output" = /etc/passwd ]
}

@test "prov_params_line : rien quand chaque choix vaut son défaut" {
  module_sh 'prov_params_line'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prov_params_line : seul le choix qui s'écarte de son défaut est écrit" {
  PROV_DECK_PORT=21999 module_sh 'prov_params_line'
  [ "$status" -eq 0 ]
  [ "$output" = "PROV_DECK_PORT=21999" ]
}

@test "prov_announce_credential sans fichier d'annonce : l'encadré IDENTIFIANTS porte le libellé, le login et le secret" {
  module_sh 'prov_announce_credential "forge de la flotte" amiral s3cret-du-banc'
  [ "$status" -eq 0 ]
  [[ "$output" == *"│  IDENTIFIANTS — à noter maintenant"* ]]
  [[ "$output" == *"│  forge de la flotte"* ]]
  [[ "$output" == *"login        : amiral"* ]]
  [[ "$output" == *"mot de passe : s3cret-du-banc"* ]]
}

@test "prov_print_credentials : un secret long élargit l'encadré, chaque ligne garde la même largeur" {
  module_sh 'printf "compte\tamiral\t%s\n" "$(printf "x%.0s" {1..90})" | prov_print_credentials'
  [ "$status" -eq 0 ]
  local l largeurs=""
  while IFS= read -r l; do
    [[ "$l" == *[│┌└├]* ]] || continue
    largeurs+="${#l} "
  done <<<"$output"
  [ -n "$largeurs" ]
  [ "$(tr ' ' '\n' <<<"$largeurs" | sed '/^$/d' | sort -u | wc -l)" -eq 1 ]
}

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

listen_on() { # listen_on <port> — un processus python qui écoute ; pid dans $LISTENER, arrêté au teardown
  python3 -c 'import socket,sys,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(128); time.sleep(60)' "$1" 3>&- &
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

ss_dit() { # ss_dit <ligne> — un ss qui répond cette ligne
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$1" > "$DECOR_BIN/ss"
  chmod +x "$DECOR_BIN/ss"
}

@test "port_taken : un port libre rend 1, un port écouté rend 0" {
  export P; P="$(free_port)"
  module_sh '! port_taken "$P"'
  [ "$status" -eq 0 ]
  listen_on "$P"
  module_sh 'port_taken "$P"'
  [ "$status" -eq 0 ]
}

@test "port_holder nomme le conteneur qui publie le port, avec son projet" {
  docker_stub autre-forge-gitea-1 autre-forge
  module_sh 'port_holder 45678'
  [ "$status" -eq 0 ]
  [ "$output" = "autre-forge-gitea-1 (projet autre-forge)" ]
}

@test "port_holder nomme un conteneur hors compose tel quel" {
  docker_stub solitaire ""
  module_sh 'port_holder 45678'
  [ "$status" -eq 0 ]
  [ "$output" = "solitaire (projet <hors compose>)" ]
}

@test "port_holder retombe sur le processus que ss nomme quand docker ne publie rien" {
  docker_stub "" ""
  ss_dit 'LISTEN 0 128 127.0.0.1:45678 0.0.0.0:* users:(("python3",pid=4242,fd=3))'
  module_sh 'port_holder 45678'
  [ "$status" -eq 0 ]
  [ "$output" = '"python3",pid=4242' ]
}

@test "port_holder ne rend rien, et rc 0, quand ni docker ni ss ne nomment" {
  docker_stub "" ""
  ss_dit ''
  module_sh 'port_holder 45678'
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
  [ "$output" = "nous mien-forge-gitea-1 (projet mien-forge)" ]
}

@test "port_state : pris par, quand un autre conteneur ou un processus nommé publie le port" {
  docker_stub autre-forge-gitea-1 autre-forge
  module_sh 'port_state 45678 mien-forge'
  [ "$output" = "pris par autre-forge-gitea-1 (projet autre-forge)" ]
  docker_stub solitaire ""
  module_sh 'port_state 45678 mien-forge'
  [ "$output" = "pris par solitaire (projet <hors compose>)" ]
}

@test "port_state : pris, quand ça écoute et que ni docker ni ss ne savent nommer" {
  docker_stub "" ""
  export P; P="$(free_port)"
  ss_dit "LISTEN 0 4096 127.0.0.1:$P 0.0.0.0:*"
  listen_on "$P"
  module_sh 'port_state "$P" mien-forge'
  [ "$output" = "pris" ]
}

forge_adresse() { module_sh 'echo "$PROV_FORGE_DU_POSTE|$PROV_FORGE_URL|$PROV_FORGE_PUBLIC_URL"'; }

@test "adresse de la forge sous --bench : celle du poste, un FORGE_BASE_URL résiduel ne la remplace pas" {
  PROV_FORGE_MONTEE=1 PROV_FORGE_HOST_PORT=21055 FORGE_BASE_URL=http://ancienne-forge:9999 forge_adresse
  [ "$status" -eq 0 ]
  [ "$output" = "1|http://127.0.0.1:21055|http://127.0.0.1:21055" ]
}

@test "adresse d'une forge fournie : FORGE_BASE_URL sans barre finale, annoncée à FORGE_PUBLIC_URL ou à elle-même, jamais à forge.public.url" {
  echo "http://10.0.0.5:21000" > "$LCARS_DECOR_ROOT/opt/lcars/var/tokens/forge.public.url"
  FORGE_BASE_URL=https://forge.ext/ forge_adresse
  [ "$output" = "0|https://forge.ext|https://forge.ext" ]
  FORGE_BASE_URL=https://forge.ext FORGE_PUBLIC_URL=https://forge.lan/ forge_adresse
  [ "$output" = "0|https://forge.ext|https://forge.lan" ]
}

@test "adresse sans forge fournie hors conteneur : la forge du poste, annoncée à forge.public.url du décor, sinon à elle-même" {
  PROV_FORGE_URL=http://depuis-l-env:1 forge_adresse
  [ "$output" = "1|http://127.0.0.1:21000|http://127.0.0.1:21000" ]
  echo "http://198.51.100.63:21000" > "$LCARS_DECOR_ROOT/opt/lcars/var/tokens/forge.public.url"
  forge_adresse
  [ "$output" = "1|http://127.0.0.1:21000|http://198.51.100.63:21000" ]
}

@test "le mode gravé par une passe précédente décide : fournie relue dans forge.url, poste sur n'importe quel port" {
  local t="$LCARS_DECOR_ROOT/opt/lcars/var/tokens"
  echo "https://forge.ext" > "$t/forge.url"
  echo "https://forge.lan" > "$t/forge.public.url"
  echo fournie > "$t/forge.mode"
  forge_adresse
  [ "$output" = "0|https://forge.ext|https://forge.lan" ]
  echo "http://127.0.0.1:21500" > "$t/forge.url"
  echo poste > "$t/forge.mode"
  forge_adresse
  [ "$output" = "1|http://127.0.0.1:21000|https://forge.lan" ]
  echo fournie > "$t/forge.mode"
  PROV_FORGE_MONTEE=1 forge_adresse
  [[ "$output" == "1|http://127.0.0.1:21000|"* ]]
}

@test "la lib ne réécrit jamais FORGE_BASE_URL ni FORGE_PUBLIC_URL de son appelant" {
  local t="$LCARS_DECOR_ROOT/opt/lcars/var/tokens"
  echo "https://forge.ext" > "$t/forge.url"; echo fournie > "$t/forge.mode"
  module_sh 'echo "[${FORGE_BASE_URL-non posée}|${FORGE_PUBLIC_URL-non posée}]"'
  [ "$output" = "[non posée|non posée]" ]
}

@test "adresse dans un conteneur sans forge fournie : vide" {
  touch "$LCARS_DECOR_ROOT/.dockerenv"
  echo "http://198.51.100.63:21000" > "$LCARS_DECOR_ROOT/opt/lcars/var/tokens/forge.public.url"
  forge_adresse
  [ "$status" -eq 0 ]
  [ "$output" = "0||" ]
}
