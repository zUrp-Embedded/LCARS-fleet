#!/usr/bin/env bats
# SOURCE: fleet/test/bin/lcars_publish_run.bats
# AUTHOR: bob
# STARDATE: 2026-08-20
# STATUS: bats tests for `lcars publish run` — phase 2's human door
#
# WHY THIS VERB EXISTS AT ALL. `publish-rail.sh` is a host-side, self-contained, executable script,
# and the BEAM was the ONLY thing able to trigger it (`project_publish.ex` was its single caller in
# the entire repository). Phase 1 IS a verb (`lcars approve`); phase 2 — the one that repeats — was
# not. An operator holding a `project_publish.failed` reason on the bus had no way to replay the
# gesture and look, and `publish status` diagnosed a publication it could not run.
#
# WHAT THESE PIN: that the verb reads the SAME binding the runtime reads, hands the rail the SAME
# arguments, refuses rather than guesses when the binding is incomplete, and honours the one exit
# code that must leave its clone behind. The rail is a stub here — what is under test is the door,
# not the rail (`test/bin/publish-rail.bats` covers that one).

setup() {
  HOMEDIR="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOMEDIR/.lcars/publish"
  export HOME="$HOMEDIR"

  # The verb resolves its rail next to ITSELF, so the subject is a copy with a stub beside it.
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  cp "$BATS_TEST_DIRNAME/../../bin/lcars" "$BIN/lcars"
  SUT="$BIN/lcars"
  RAILLOG="$BATS_TEST_TMPDIR/raillog"

  cat > "$BIN/publish-rail.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$RAILLOG"
work=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "--work" ]] && work="\$2"; shift; done
mkdir -p "\$work"
exit \${LCARS_TEST_RAIL_EXIT:-0}
EOF
  chmod +x "$BIN/publish-rail.sh"

  # The box env the verb needs before it will call anything.
  #
  # ⚠ `FORGE_TOKEN_FILE` A QUITTE CE FICHIER D'ENV, ET C'EST LE CHANTIER, PAS LA FIXTURE. Le jeton
  # systeme vivait en `0640 root:fleet`, lisible par l'humain a travers un groupe qui n'etait qu'une
  # projection de l'equipe `humans` de la forge. `publish run` le DEMANDE maintenant au service
  # d'autorite. Ce que la boite ecrit encore ici est le nom du COMPTE, pas un chemin vers un secret.
  printf 'FORGE_BASE_URL=http://forge.invalid\nFORGE_BOT_LOGIN=system_starfleet\n' \
    > "$HOMEDIR/fleet_v2.env"
  export LCARS_FLEET_V2_ENV="$HOMEDIR/fleet_v2.env"

  # La doublure du client d'autorite : elle rend un jeton, comme le vrai quand la forge dit oui.
  export LCARS_AUTHORITY_ASK_BIN="$BATS_TEST_TMPDIR/ask"
  printf '#!/usr/bin/env bash\nprintf "t\\n"\n' > "$LCARS_AUTHORITY_ASK_BIN"
  chmod +x "$LCARS_AUTHORITY_ASK_BIN"
}

_bind() { # _bind <json>
  printf '%s' "$1" > "$HOMEDIR/.lcars/publish/fleet__demo.json"
}

_full_binding='{"host":"github","dest_host":"ghe.example.com","dest_repo":"acme/widget","base":"master"}'

# ─── the door itself ───────────────────────────────────────────────────────────────────────────

@test "publish with no subcommand names BOTH of them" {
  run "$SUT" publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"run"* ]]
  [[ "$output" == *"status"* ]]
}

@test "publish run without a repo -> usage" {
  run "$SUT" publish run
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]]
}

@test "publish run on an unlinked project names the gesture that links it" {
  run "$SUT" publish run fleet/demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"n'est pas lie"* ]]
  [[ "$output" == *"lcars approve"* ]]
}

# ─── an incomplete binding is REFUSED, never completed by a guess ──────────────────────────────

@test "a binding without 'base' is refused BY NAME — the runtime used to fall back to main" {
  # THE DEFECT THIS FORBIDS had two independent entry points: `approve` assumed `main` when writing,
  # and `rail_args/5` did `Map.get(b, "base") || "main"` when reading. Closing one alone left the
  # rail broken by the other. A binding that does not say WHERE it publishes is not a binding.
  _bind '{"host":"github","dest_host":"github.com","dest_repo":"acme/widget"}'
  run "$SUT" publish run fleet/demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"base"* ]]
  [ ! -f "$RAILLOG" ]   # and nothing was launched
}

@test "a binding without 'dest_repo' is refused BY NAME too" {
  _bind '{"host":"github","dest_host":"github.com","base":"main"}'
  run "$SUT" publish run fleet/demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"dest_repo"* ]]
}

# ─── the rail receives the binding's values, not defaults ──────────────────────────────────────

@test "the rail is handed the binding's host, dest-host, dest-repo and base" {
  # A second implementation of the argument list would drift from the runtime's. What is pinned is
  # that every value comes FROM the binding — in particular `base`, which used to be assumed `main`
  # on both sides while the destination's default branch was `master`.
  _bind "$_full_binding"
  run "$SUT" publish run fleet/demo
  [ "$status" -eq 0 ]
  grep -q -- "--host github" "$RAILLOG"
  grep -q -- "--dest-host ghe.example.com" "$RAILLOG"
  grep -q -- "--dest-repo acme/widget" "$RAILLOG"
  grep -q -- "--base master" "$RAILLOG"
  grep -q -- "--project fleet/demo" "$RAILLOG"
}

@test "the rail gets a FRESH --work path (it refuses one that already exists)" {
  _bind "$_full_binding"
  run "$SUT" publish run fleet/demo
  [ "$status" -eq 0 ]
  grep -q -- "--work " "$RAILLOG"
}

# ─── the work directory: swept, except for the one failure that must be inspected ──────────────

@test "a normal outcome leaves no clone behind" {
  _bind "$_full_binding"
  run "$SUT" publish run fleet/demo
  [ "$status" -eq 0 ]
  work="$(sed -n 's/.*--work \([^ ]*\).*/\1/p' "$RAILLOG")"
  [ -n "$work" ]
  [ ! -e "$work" ]
  # AND its parent: the verb allocates `mktemp -d` then works in `$tmp/clone`, so sweeping only the
  # clone would leave one empty temp directory per publication — the same leak, one level up.
  [ ! -e "$(dirname "$work")" ]
}

@test "exit 6 KEEPS the clone and prints where it is" {
  # Exit 6 means the rewrite lost its determinism — the one failure that cannot be reproduced from a
  # message. Sweeping it would erase the only evidence.
  _bind "$_full_binding"
  LCARS_TEST_RAIL_EXIT=6 run "$SUT" publish run fleet/demo
  [ "$status" -eq 6 ]
  work="$(sed -n 's/.*--work \([^ ]*\).*/\1/p' "$RAILLOG")"
  [ -d "$work" ]
  [[ "$output" == *"conserve pour inspection"* ]]
  rm -rf "$(dirname "$work")"
}

# ─── le jeton : demande, materialise, et retire meme sur le chemin d'erreur ─────────────────────

@test "le jeton part au rail par un CHEMIN, jamais en argv — et le fichier est 0600" {
  # `publish-rail.sh` et `publish-transform.sh` prennent un chemin. Passer le jeton en argument le
  # mettrait dans `/proc/<pid>/cmdline`, lisible par tout le monde pendant toute la duree du
  # publish — ce qui annulerait, au moment ou il s'exerce, le geste de fermer le fichier `0640`.
  _bind "$_full_binding"
  # Le rail-doublure copie le fichier avant de rendre la main : apres coup il aura ete balaye.
  cat > "$BIN/publish-rail.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$RAILLOG"
tok=""; work=""
while [[ \$# -gt 0 ]]; do
  [[ "\$1" == "--forge-token-file" ]] && tok="\$2"
  [[ "\$1" == "--work" ]] && work="\$2"
  shift
done
stat -c '%a' "\$tok" > "$BATS_TEST_TMPDIR/tokmode"
cat "\$tok" > "$BATS_TEST_TMPDIR/tokvalue"
mkdir -p "\$work"
EOF
  chmod +x "$BIN/publish-rail.sh"

  run "$SUT" publish run fleet/demo
  [ "$status" -eq 0 ]
  # Le jeton demande au service est bien celui qui arrive au rail.
  [ "$(cat "$BATS_TEST_TMPDIR/tokvalue")" = "t" ]
  [ "$(cat "$BATS_TEST_TMPDIR/tokmode")" = "600" ]
  # Et il n'est PAS sur la ligne de commande.
  ! grep -q '\bt\b' <<< "$(sed 's/--forge-token-file [^ ]*//' "$RAILLOG")"
}

# ⚠ LE TEMOIN QUI GARDE LE CHEMIN D'ERREUR, ET C'EST CELUI QU'ON OUBLIE. La sortie 6 CONSERVE le
# repertoire pour inspection : sans un retrait explicite, le jeton y survivrait indefiniment, dans
# le repertoire temporaire de la machine, sur la branche que personne ne relit.
@test "sortie 6 : le clone est conserve, le JETON ne l'est pas" {
  _bind "$_full_binding"
  LCARS_TEST_RAIL_EXIT=6 run "$SUT" publish run fleet/demo
  [ "$status" -eq 6 ]
  work="$(sed -n 's/.*--work \([^ ]*\).*/\1/p' "$RAILLOG")"
  tok="$(sed -n 's/.*--forge-token-file \([^ ]*\).*/\1/p' "$RAILLOG")"
  [ -d "$work" ]          # le clone reste — c'est le contrat de la sortie 6
  [ -n "$tok" ]
  [ ! -e "$tok" ]         # le jeton, non
  rm -rf "$(dirname "$work")"
}

@test "le service refuse : rien n'est appele, et le repertoire de travail ne reste pas" {
  _bind "$_full_binding"
  printf '#!/usr/bin/env bash\necho "autorite: refus de fixture" >&2\nexit 1\n' \
    > "$LCARS_AUTHORITY_ASK_BIN"
  run "$SUT" publish run fleet/demo
  [ "$status" -ne 0 ]
  [[ "$output" == *"pas de jeton de forge"* ]]
  # LE RAIL N'A PAS ETE APPELE : un publish sans identite ne part pas a moitie.
  [ ! -s "$RAILLOG" ]
}

@test "--linearize reaches the rail — the flag used to be dropped on the floor" {
  # `linearize_first_parent` is written, documented (D2) and covered by three witnesses of its own,
  # and NO path could reach it: the transform is only invoked from `publish-rail.sh`, and that rail
  # relayed three passthroughs, not this one. A capability the code advertises and nobody can
  # exercise is a promise the code does not keep.
  _bind "$_full_binding"
  run "$SUT" publish run fleet/demo --linearize main
  [ "$status" -eq 0 ]
  grep -q -- "--linearize main" "$RAILLOG"
}

@test "without --linearize, the flag is absent — not passed empty" {
  # An empty `--linearize ''` would make the transform refuse on an unknown branch, turning an
  # option nobody asked for into a failure.
  _bind "$_full_binding"
  run "$SUT" publish run fleet/demo
  [ "$status" -eq 0 ]
  ! grep -q -- "--linearize" "$RAILLOG"
}

@test "an unknown option on publish run is refused" {
  _bind "$_full_binding"
  run "$SUT" publish run fleet/demo --flatten
  [ "$status" -eq 1 ]
  [[ "$output" == *"option inconnue"* ]]
}

@test "any other non-zero exit propagates AND sweeps" {
  _bind "$_full_binding"
  LCARS_TEST_RAIL_EXIT=4 run "$SUT" publish run fleet/demo
  [ "$status" -eq 4 ]
  work="$(sed -n 's/.*--work \([^ ]*\).*/\1/p' "$RAILLOG")"
  [ ! -e "$work" ]
}
