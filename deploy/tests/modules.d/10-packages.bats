#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/10-packages.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins des paquets du runtime — présence mesurée par dpkg, pose par apt, sonde bwrap réelle

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  SRC="$BATS_TEST_DIRNAME/../../modules.d/10-packages.sh"; [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=10-packages PROV_SUBSTRATE=wsl
  export PROV_HUMAN; PROV_HUMAN="$(id -un)"
  decor_pose
  export INSTALLES="$BATS_TEST_TMPDIR/installes"; : > "$INSTALLES"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  BIN="$DECOR_BIN"
  cat > "$BIN/dpkg-query" <<'EOF'
#!/usr/bin/env bash
pkg="${@: -1}"
grep -qx "$pkg" "$INSTALLES" && printf 'installed' || printf 'not-installed'
EOF
  cat > "$BIN/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "APT:$*" >> "$CALLS"
[[ "${STUB_APT_RC:-0}" -eq 0 ]] || exit "$STUB_APT_RC"
if [[ "$1" == install ]]; then shift; for a in "$@"; do [[ "$a" == -* ]] || echo "$a" >> "$INSTALLES"; done; fi
exit 0
EOF
  cat > "$BIN/bwrap" <<'EOF'
#!/usr/bin/env bash
echo "BWRAP:$*" >> "$CALLS"
exit "${STUB_BWRAP_RC:-0}"
EOF
  chmod 0755 "$BIN"/*
}

mod() { run bash "$SRC" "$@"; }
liste() { sed -n '/^PACKAGES=(/,/^)/p' "$SRC" | grep -vE '^PACKAGES=\(|^\)|^\s*#' | tr -s ' \n' '\n' | grep -v '^$'; }

@test "check : tout installé et un sandbox qui tourne, conforme — chaque paquet nommé, la baseline des pods comprise" {
  liste > "$INSTALLES"
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    10-packages: paquet tmux"*"paquet python3-venv"*"paquet build-essential"*"bwrap sandbox opérationnel (sonde réelle, user $PROV_HUMAN)"* ]]
  grep -q 'BWRAP:--ro-bind / / --unshare-all --die-with-parent /bin/true' "$CALLS"
}

@test "check : un paquet absent est un drift nommé, et la sonde bwrap n'est pas jouée" {
  liste | grep -v '^gh$' > "$INSTALLES"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 10-packages: paquet gh absent"* ]]
  refute grep -q 'BWRAP:' "$CALLS"
}

@test "check : un sandbox qui échoue est un drift ; sans sonde du noyau (PROV_KERNEL_PROBES=0) c'est un avertissement, pas un drift" {
  liste > "$INSTALLES"
  STUB_BWRAP_RC=1 mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 10-packages: bwrap installé mais un sandbox minimal ÉCHOUE"*"aucun pod ne spawnera"* ]]
  : > "$CALLS"
  PROV_KERNEL_PROBES=0 mod check
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN  10-packages: sonde bwrap NON jouée"*"se joue au boot"* ]]
  refute grep -q 'BWRAP:' "$CALLS"
}

@test "apply : rien d'installé — apt update puis install de la liste entière, sans recommends, puis la sonde ; sortie 0" {
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^APT:update' "$CALLS"
  local ligne; ligne="$(grep '^APT:install' "$CALLS")"
  [[ "$ligne" == *"-y --no-install-recommends"* ]]
  local p; while read -r p; do [[ "$ligne" == *" $p"* ]] || { echo "$p manque dans l'install"; return 1; }; done < <(liste)
  [[ "$output" == *"apt: install tmux"*"bwrap sandbox opérationnel"* ]]
  [ "$(grep -n 'APT:install' "$CALLS" | cut -d: -f1)" -lt "$(grep -n 'BWRAP:' "$CALLS" | cut -d: -f1)" ]
}

@test "apply : tout déjà là — aucun apt, la sonde seule, sortie 0" {
  liste > "$INSTALLES"
  mod apply
  [ "$status" -eq 0 ]
  refute grep -q '^APT:' "$CALLS"
  grep -q 'BWRAP:' "$CALLS"
}

@test "apply : un sandbox qui échoue est un échec qui nomme l'arbitrage, sortie 1" {
  liste > "$INSTALLES"
  STUB_BWRAP_RC=1 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  10-packages: bwrap installé mais un sandbox minimal ÉCHOUE"*"apparmor_restrict_unprivileged_userns=0"* ]]
}

@test "xz-utils est dans la liste : 16-node détare le précompilé de node, un .tar.xz" {
  grep -qE 'fetch_verify "https://nodejs\.org/[^"]*\.tar\.xz"' "$BATS_TEST_DIRNAME/../../modules.d/16-node.sh" \
    || { echo "16-node ne télécharge plus un .tar.xz — ce cas n'a plus de sujet"; return 1; }
  liste | grep -qx xz-utils
}

# ⚠ SANS `zstd`, L'INSTALLEUR OFFICIEL DE CLAUDE TÉLÉCHARGE 230 Mo DE BINAIRE NU. Il prend
# l'artefact COMPRESSÉ quand zstd est là, et le brut sinon. Mesure du 2026-09-17 sur LCARS-beta,
# zstd absent et lien à ~540 ko/s : le téléchargement n'aboutissait jamais, et l'échec se présentait
# comme une somme de contrôle fausse sur un fichier qui n'existe pas. AUCUN humain n'avait `claude`.
@test "zstd est dans la liste : l'installeur de claude prend l'artefact compressé quand il est là" {
  local claude="$BATS_TEST_DIRNAME/../../../runtime/services/human.d/40-claude-bin.sh"
  grep -q 'claude.ai/install.sh' "$claude" \
    || { echo "40-claude-bin ne joue plus l'installeur officiel — ce cas n'a plus de sujet"; return 1; }
  liste | grep -qx zstd
}

@test "apply : apt qui refuse est un échec, sans sonde derrière" {
  STUB_APT_RC=100 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"* ]]
  refute grep -q 'BWRAP:' "$CALLS"
}
