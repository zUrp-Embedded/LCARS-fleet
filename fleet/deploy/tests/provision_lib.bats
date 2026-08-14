#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/provision_lib.bats
# AUTHOR: consultant
# STARDATE: 2026-07-30
# STATUS: bats tests for lib/provision-lib.sh — the lib's one promise is "never lie green"
#
# Every scenario runs in a FRESH bash process with `set -euo pipefail`, exactly like a module
# (modules are separate processes sourcing the lib — never a shared namespace). What is proven
# here is the counter/verdict CONTRACT, i.e. the three lies killed by the conformance pass:
#   B1  run_quiet failure without PROV_FAILED  → `run_quiet x || verdict_apply` exited 0 (green lie)
#   B3  write_atomic on the right side of a pipe → counters died in the subshell (green lie)
#   B5  human_home under pipefail on unknown user → silent abort BEFORE the caller's p_fail guard
# The real filesystem effects (atomic write, managed block replacement) are asserted on tmpdirs.

setup() {
  LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export LIB
  [ -f "$LIB" ]
}

# Helper: run a module-like snippet (fresh bash, module shell options, lib sourced).
module_sh() {
  run bash -c "set -euo pipefail; export PROVISION_MODULE=test-mod; source \"\$LIB\"; $1"
}

# ─── B1 — run_quiet failure MUST count ───────────────────────────────────────────────────────────

@test "B1: run_quiet failure increments PROV_FAILED and keeps the command's rc" {
  module_sh '
    rc=0
    run_quiet bash -c "echo boom-output; exit 3" || rc=$?
    [ "$rc" -eq 3 ]
    [ "$PROV_FAILED" -eq 1 ]
  '
  [ "$status" -eq 0 ]
  # failure is verbose: the command output is dumped, not swallowed
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
    [ "$PROV_FAILED" -eq 0 ] && [ "$PROV_CHANGED" -eq 0 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
}

# ─── B3 — ensure_managed_block: counters live in the CALLER shell ────────────────────────────────

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
    ! grep -q "old-content" "$f"
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

# ─── B5 — unknown human: empty answer, never a silent abort ──────────────────────────────────────

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

# ─── write_atomic — regression guards on the primitive itself ────────────────────────────────────

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

@test "write_atomic: missing parent dir fails loud (PROV_FAILED counted)" {
  module_sh '
    write_atomic "$BATS_TEST_TMPDIR/absent-dir/f" 0644 <<< "x" || true
    [ "$PROV_FAILED" -ge 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"dossier absent"* ]]
}

# ─── 6-131 — LA GARDE SYMLINK DES MUTATIONS PRIVILEGIEES ─────────────────────────────────────────
#
# L'attaque que ces tests epinglent : `ensure_dir` tenait un symlink-vers-dossier pour un dossier
# (`[[ -d ]]` suit les liens), puis `ensure_mode` chownait sa CIBLE. Le module WSL applique ces
# helpers EN ROOT a `$HOME/.config` de l'humain — donc `~/.config -> /etc`, et `sudo provision
# apply` donne `/etc` a cet humain.
#
# Ils tournent sans privileges : ce qui est mesure est le REFUS, pas l'effet root. Un test qui
# aurait besoin de root pour prouver une garde ne serait joue nulle part.

@test "6-131: ensure_dir REFUSE un symlink-vers-dossier au lieu de converger sa cible" {
  module_sh '
    victime="$BATS_TEST_TMPDIR/victime"; mkdir -p "$victime"; chmod 0755 "$victime"
    ln -s "$victime" "$BATS_TEST_TMPDIR/piege"
    ensure_dir "$BATS_TEST_TMPDIR/piege" 0700 || true
    [ "$PROV_FAILED" -ge 1 ]
    # LA cible n_a PAS bouge : c est tout l enjeu, pas le code de retour.
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

@test "6-131: ensure_mode dit LIEN et non « absent » sur un lien casse" {
  # `[[ -e ]]` est faux sur un lien casse : diagnostique « absent », le piege reste invisible.
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
  # Sans ce temoin, une garde qui refuserait TOUT passerait les quatre tests ci-dessus.
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

# ─── 6-130 — LE VERROU PRIVILEGIE N EST PLUS DANS UN DOSSIER PARTAGE ─────────────────────────────

@test "6-130: prov_lock_path ignore TMPDIR — un verrou dont l appelant choisit l emplacement n en est pas un" {
  module_sh '
    export TMPDIR="$BATS_TEST_TMPDIR/pirate"; mkdir -p "$TMPDIR"
    lock="$(prov_lock_path)" || true
    [[ "$lock" != "$TMPDIR"* ]]
  '
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

# ─── 6-109 — L AUTORITE DU SELF-UPDATE ROOT ETAIT UNE SOUS-CHAINE ────────────────────────────────
#
# `case "$REMOTE_URL" in *"$PROV_EXPECTED_REPO"*)`. Avec `fleet/lcars` attendu, l URL
# `https://hote-attaquant/attaquant/fleet/lcars-malware.git` la CONTIENT — donc pull, puis
# `exec "$SELF" apply` sur ce code, EN ROOT. Ni l hote, ni le proprietaire, ni la fin du nom.
#
# Aucun test ne couvrait `update` avant ceci.

@test "6-109: l URL de l attaque de la fiche ne rend PAS l autorite attendue" {
  module_sh '
    got="$(prov_parse_remote "https://hote-attaquant/attaquant/fleet/lcars-malware.git")" || got=REFUS
    [ "$got" != "forge.example.org/fleet/lcars" ]
    # Et ce quon lit dit POURQUOI : trois segments de chemin, ce nest pas <owner>/<repo>.
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
  # `user:token@` ferait de l autorite de mise a jour un porteur de secret. `git@`, en revanche,
  # est la syntaxe normale de SSH : la refuser serait un mur, pas une garde.
  module_sh '
    prov_parse_remote "https://user:token@forge.example.org/fleet/lcars.git" && exit 1
    prov_parse_remote "ssh://git@forge.example.org/fleet/lcars.git" >/dev/null || exit 1
    exit 0
  '
  [ "$status" -eq 0 ]
}

@test "6-109: une URL qui MIME l autorite dans son userinfo rend l hote REEL" {
  # `https://fleet/lcars@hote-attaquant/x/y.git` : la partie qui ressemble a l autorite attendue
  # est AVANT le `@`, donc elle ne dit rien de qui sera contacte. Le parse rend l hote reel, et
  # c est la comparaison exacte qui refuse — pas un filtre sur la forme.
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
