#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/install_journal.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: bats tests — le JOURNAL : ce qui a ete pose sur CETTE machine

# shellcheck disable=SC2016

load refute
load support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  [ -f "$LIB" ]

  export PROVISION_LIB="$LIB"
  export PROVISION_MODULE=test-journal
  decor_pose
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  ACC="$BATS_TEST_TMPDIR/acc"
}

# Sourcer la lib et jouer une expression dedans.
lib() { run bash -c "set -euo pipefail; . '$LIB' >/dev/null 2>&1; $1"; }

@test "MUET sans accumulateur — un appelant n'a jamais a savoir si le journal existe" {
  # `doctor`, un module joue nu, un temoin : aucun n'ouvre d'accumulateur. La note doit alors etre
  # sans effet ET sans echec. Une fonction de tracage qui fait tomber son appelant est un piege.
  lib 'prov_journal_note apt_installed socat && echo ok'
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "la note s'ecrit : une ligne, une clef, ses valeurs" {
  lib "PROV_JOURNAL_ACC='$ACC'; prov_journal_note apt_installed socat jq"
  [ "$status" -eq 0 ]
  grep -qx 'apt_installed socat jq' "$ACC"
}

@test "un accumulateur illisible ne fait PAS tomber l'appelant" {
  # Le journal RACONTE, il ne decide pas. Une perte de trace se dit ; elle ne renverse pas un
  # verdict que vingt-cinq modules viennent de rendre.
  lib "PROV_JOURNAL_ACC='/proc/nonexistent/acc'; prov_journal_note apt_installed socat && echo survecu"
  [ "$status" -eq 0 ]
  [ "$output" = "survecu" ]
}

apt_decor() { # -> pose bin/dpkg + bin/apt-get, exporte APT_TRACE, APT_POSED_DIR et APT_BIN
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  cat > "$bin/dpkg" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --print-architecture) echo amd64; exit 0 ;;
  -s) case "$2" in
        git|curl) exit 0 ;;
        *) [[ -f "${APT_POSED_DIR:-/nonexistent}/$2" || -f "${APT_POSED_DIR:-/nonexistent}/$2.rc" ]] && exit 0 || exit 1 ;;
      esac ;;
  *) exit 0 ;;
esac
SH
  # `dpkg-query -W -f='${db:Status-Status}'` : l'etat REEL, celui que `pkg_installed` lit.
  cat > "$bin/dpkg-query" <<'SH'
#!/usr/bin/env bash
pkg="${!#}"
case "$pkg" in
  git|curl) echo installed; exit 0 ;;
esac
if [[ -f "${APT_POSED_DIR:-/nonexistent}/$pkg" ]]; then echo installed
elif [[ -f "${APT_POSED_DIR:-/nonexistent}/$pkg.rc" ]]; then echo config-files
else echo not-installed; exit 1
fi
SH
  # `apt-get` ne doit jamais tourner pour de vrai : s'il est appele, il TRACE, pose ses marqueurs et
  # ment sur le succes. `APT_FAIL=1` le fait echouer SANS rien poser — le depot injoignable.
  cat > "$bin/apt-get" <<'SH'
#!/usr/bin/env bash
echo "apt-get $*" >> "${APT_TRACE:?}"
# `APT_FAIL=1` : l'`update` passe, l'`install` echoue. C'est la forme reelle d'un depot qui
# refuse un paquet — et la seule qui laisse `apt_ensure` aller jusqu'a la ligne qu'on mesure.
[[ "${APT_FAIL:-0}" == 1 && "${1:-}" == "install" ]] && exit 100
if [[ "${1:-}" == "install" ]]; then
  for a in "$@"; do
    case "$a" in install|-y|--no-install-recommends) continue ;; esac
    : > "${APT_POSED_DIR:?}/$a"
  done
fi
exit 0
SH
  chmod +x "$bin/dpkg" "$bin/dpkg-query" "$bin/apt-get"
  export APT_TRACE="$BATS_TEST_TMPDIR/apt.trace"; : > "$APT_TRACE"
  export APT_POSED_DIR="$BATS_TEST_TMPDIR/posed"; mkdir -p "$APT_POSED_DIR"
  APT_BIN="$bin"
}

@test "apt_ensure n'installe et ne revendique que ce qui manquait avant l'install" {
  # On double `dpkg` : `git` et `curl` sont deja la, `socat` non.
  local bin; apt_decor; bin="$APT_BIN"

  run bash -c "set -euo pipefail
    export PATH=\"$bin:\$PATH\" PROV_JOURNAL_ACC='$ACC' APT_TRACE='$APT_TRACE' APT_POSED_DIR='$APT_POSED_DIR'
    . '$LIB' >/dev/null 2>&1
    apt_ensure git socat curl >/dev/null 2>&1 || true
    cat '$ACC'"
  [ "$output" = "apt_installed socat" ]
  refute grep -q 'install.*git' "$APT_TRACE"
}

@test "un apt EN ECHEC ne fait revendiquer AUCUN paquet au journal" {
  local bin; apt_decor; bin="$APT_BIN"
  run bash -c "set -euo pipefail
    export PATH=\"$bin:\$PATH\" PROV_JOURNAL_ACC='$ACC' APT_TRACE='$APT_TRACE' APT_POSED_DIR='$APT_POSED_DIR' APT_FAIL=1
    . '$LIB' >/dev/null 2>&1
    apt_ensure socat jq >/dev/null 2>&1 || true
    cat '$ACC' 2>/dev/null || true"
  # GARDE D'INSTRUMENT : sans elle, un `apt_ensure` qui n'aurait meme pas tourne rendrait ce
  # temoin vert. On exige la PREUVE que l'install a ete tentee.
  grep -q 'install' "$APT_TRACE" || { echo "apt-get install n'a jamais ete appele — le decor est casse, pas le code"; return 1; }
  refute grep -q 'apt_installed' <<<"$output"
}

@test "apt rend 0 mais un paquet MANQUE : seul le pose entre au journal, et le verdict echoue" {
  # `apt-get install` peut rendre 0 en ayant servi moins que la liste. C'est `dpkg -s`, paquet par
  # paquet, qui dit ce qui est la — et le journal ne doit porter que ceux-la.
  local bin; apt_decor; bin="$APT_BIN"
  # `jq` est pose par la doublure, `socat` non : on remplace `apt-get` par une version qui ne pose que lui.
  cat > "$bin/apt-get" <<'SH'
#!/usr/bin/env bash
echo "apt-get $*" >> "${APT_TRACE:?}"
if [[ "${1:-}" == "install" ]]; then : > "${APT_POSED_DIR:?}/jq"; fi
exit 0
SH
  chmod +x "$bin/apt-get"
  run bash -c "set -euo pipefail
    export PATH=\"$bin:\$PATH\" PROV_JOURNAL_ACC='$ACC' APT_TRACE='$APT_TRACE' APT_POSED_DIR='$APT_POSED_DIR'
    . '$LIB' >/dev/null 2>&1
    rc=0; apt_ensure socat jq >/dev/null 2>&1 || rc=\$?; echo \"rc=\$rc\"
    cat '$ACC' 2>/dev/null || true"
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"apt_installed jq"* ]]
  # et `socat`, qui n'a pas repondu, n'est revendique nulle part
  refute grep -qE 'apt_installed.*socat' <<<"$output"
}

@test "un paquet RETIRE (etat rc) est REINSTALLE — dpkg -s le croit la, et le rail se coupait la scie" {
  apt_decor
  : > "$APT_POSED_DIR/docker-ce.rc"          # retire, config conservee
  : > "$APT_POSED_DIR/tmux"                  # celui-la est VRAIMENT pose
  run env PATH="$APT_BIN:$PATH" bash -c ". '$LIB'; apt_ensure docker-ce tmux"
  [ "$status" -eq 0 ]
  grep -q 'apt-get install.*docker-ce' "$APT_TRACE"
  refute grep -qE 'apt-get install.*\btmux\b' "$APT_TRACE"
}


@test "M8 : prov_scaffold_dir puis prov_promote_dir — l'echafaudage disparait, le final est la" {
  lib "PROV_JOURNAL_ACC='$ACC'; prov_scaffold_dir '$BATS_TEST_TMPDIR/final.partial' 0755 >/dev/null; : > '$BATS_TEST_TMPDIR/final.partial/x'; prov_promote_dir '$BATS_TEST_TMPDIR/final.partial' '$BATS_TEST_TMPDIR/final'"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ -f "$BATS_TEST_TMPDIR/final/x" ]
  [ ! -e "$BATS_TEST_TMPDIR/final.partial" ]
}

@test "M8 : prov_promote_dir REMPLACE un final existant" {
  mkdir -p "$BATS_TEST_TMPDIR/final/vieux"
  lib "prov_scaffold_dir '$BATS_TEST_TMPDIR/final.new' 0755 >/dev/null; prov_promote_dir '$BATS_TEST_TMPDIR/final.new' '$BATS_TEST_TMPDIR/final'"
  [ "$status" -eq 0 ]
  [ -d "$BATS_TEST_TMPDIR/final" ]
  [ ! -e "$BATS_TEST_TMPDIR/final/vieux" ]
}

# bats test_tags=structure
@test "M8 : aucun module ne cree son echafaudage par ensure_dir — et trois au moins passent par la primitive" {
  local hits n_scaffold n_promote
  hits="$(grep -nE 'ensure_dir "[^"]*\.(partial|new)"' "$BATS_TEST_DIRNAME"/../modules.d/*.sh || true)"
  [ -z "$hits" ] || { echo "echafaudage journalise :" >&2; printf '%s\n' "$hits" >&2; return 1; }
  n_scaffold="$(cat "$BATS_TEST_DIRNAME"/../modules.d/*.sh | grep -vE '^\s*#' | grep -c 'prov_scaffold_dir ')"
  n_promote="$(cat "$BATS_TEST_DIRNAME"/../modules.d/*.sh | grep -vE '^\s*#' | grep -c 'prov_promote_dir ')"
  [ "$n_scaffold" -ge 3 ]
  [ "$n_promote" -ge 3 ]
  # le motif voit bien la forme interdite
  grep -qE 'ensure_dir "[^"]*\.(partial|new)"' <<<'  ensure_dir "${NODE_HOME}.partial" 0755 root:root || verdict_apply'
}
