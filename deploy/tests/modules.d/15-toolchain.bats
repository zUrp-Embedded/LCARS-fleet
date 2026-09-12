#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/15-toolchain.bats
# AUTHOR: bob
# STARDATE: 2026-09-06
# STATUS: PROTO-V2 — 15-toolchain sous le plancher 1.20 : le pin d'Elixir, UNE source, et la pose a blanc
load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  ROOT="$BATS_TEST_DIRNAME/../../.."
  MOD="$ROOT/deploy/modules.d/15-toolchain.sh"; LIB="$ROOT/deploy/lib/provision-lib.sh"
  DF="$ROOT/deploy/docker/Dockerfile"; MIX="$ROOT/runtime/mix.exs"
  [ -f "$MOD" ]
  [ -f "$LIB" ]
  [ -f "$DF" ]
  [ -f "$MIX" ]
  export PROVISION_LIB="$LIB" PROVISION_MODULE=15-toolchain
  export PROV_LINK_DIR="$BATS_TEST_TMPDIR/bin" LCARS_ELIXIR_PREFIX="$BATS_TEST_TMPDIR/opt/elixir-"
  export PROV_ROOT="$BATS_TEST_TMPDIR/lcars" PROV_JOURNAL_ACC="$BATS_TEST_TMPDIR/journal"
  # Meme garde que dans delivery_form.bats : `apply` retire des arbres, il ne doit jamais tirer hors
  # du tmp du test (cicatrice du 2026-09-07 — une couture renommee visait /opt/elixir-1.18.4).
  [[ "$LCARS_ELIXIR_PREFIX" == "$BATS_TEST_TMPDIR"/* ]] \
    || { echo "couture Elixir hors du tmp du test : $LCARS_ELIXIR_PREFIX"; return 1; }
  mkdir -p "$PROV_LINK_DIR" "$BATS_TEST_TMPDIR/opt" "$PROV_ROOT/var"
  PIN="$(sed -n 's/^: "${PROV_ELIXIR_PIN:=\([^}]*\)}".*/\1/p' "$LIB")"
  MIN="$(sed -n 's/^: "${PROV_ELIXIR_MIN:=\([^}]*\)}".*/\1/p' "$LIB")"
  OTP="$(sed -n 's/^: "${PROV_ELIXIR_OTP_MAJOR:=\([^}]*\)}".*/\1/p' "$LIB")"
  SHA="$(sed -n 's/^: "${PROV_ELIXIR_PIN_SHA256:=\([^}]*\)}".*/\1/p' "$LIB")"
}

# un faux zip d'Elixir : bin/elixir repond la version voulue
_fake_zip() { # _fake_zip <version> <fichier zip> — python (zip n'est pas dans le socle, python3 oui)
  local d; d="$(mktemp -d)"; mkdir -p "$d/bin"
  printf '#!/usr/bin/env bash\ncase "$1" in --short-version) echo "%s" ;; --version) echo "Elixir %s (compiled with Erlang/OTP %s)" ;; esac\n' "$1" "$1" "$OTP" > "$d/bin/elixir"
  for b in elixirc mix iex; do printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/$b"; done
  chmod 0755 "$d/bin"/*
  python3 - "$d" "$2" <<'PYZ'
import sys, os, zipfile
root, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for name in sorted(os.listdir(os.path.join(root, "bin"))):
        path = os.path.join(root, "bin", name)
        info = zipfile.ZipInfo("bin/" + name); info.external_attr = 0o755 << 16
        with open(path, "rb") as f: z.writestr(info, f.read())
PYZ
  rm -rf "$d"
}

# les doublures : curl sert $FAKE_ZIP ; erl repond OTP ; apt-get trace ; elixir/erl reels absents du PATH
_doubles() {
  local bin="$BATS_TEST_TMPDIR/doubles"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nout=""; prev=""; for a in "$@"; do [[ "$prev" == -o ]] && out="$a"; prev="$a"; done; cp "%s" "$out"\n' "$FAKE_ZIP" > "$bin/curl"
  printf '#!/usr/bin/env bash\nprintf "%s"\n' "$OTP" > "$bin/erl"
  printf '#!/usr/bin/env bash\necho "APT $*" >> "%s"; exit 0\n' "$BATS_TEST_TMPDIR/apt.trace" > "$bin/apt-get"
  # chown root:root n'est pas a la portee d'un temoin : la propriete n'est pas ce qu'on mesure ici
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/chown"
  chmod 0755 "$bin"/*; echo "$bin"
}

_run_apply() {
  local bin; bin="$(_doubles)"
  run bash -c "set -uo pipefail; export PATH=\"$PROV_LINK_DIR:$bin:\$PATH\" PROV_ELIXIR_PIN_SHA256='$FAKE_SHA'; source <(sed '/^case \"\${1:?usage/,\$d' '$MOD'); prov_delivery_is_binary() { return 1; }; apt_ensure() { echo \"APT-ENSURE \$*\"; }; apply 2>&1"
}

@test "UNE SOURCE : le pin et le plancher s'accordent — et le pin SATISFAIT ce que mix.exs exige" {
  [ -n "$PIN" ]
  [ -n "$MIN" ]
  [ -n "$OTP" ]
  [[ "$SHA" =~ ^[0-9a-f]{64}$ ]]
  [ "${PIN%.*}" = "$MIN" ] || { echo "pin $PIN et plancher $MIN : pas la meme minor"; return 1; }
  local mixreq; mixreq="$(sed -n 's/.*elixir: "~> \([0-9.]*\)".*/\1/p' "$MIX")"
  [ -n "$mixreq" ] || { echo "mix.exs ne declare plus de requirement elixir — l'accord n'a plus de sujet"; return 1; }
  local rmaj rmin pmaj pmin fmaj fmin
  rmaj="${mixreq%%.*}"; rmin="${mixreq#*.}"; rmin="${rmin%%.*}"
  pmaj="${PIN%%.*}";    pmin="${PIN#*.}";    pmin="${pmin%%.*}"
  fmaj="${MIN%%.*}";    fmin="${MIN#*.}";    fmin="${fmin%%.*}"
  # `~> M.m` = >= M.m et < (M+1).0 : le pin doit tomber dedans, et le plancher ne doit pas exiger
  # MOINS que le projet (une machine au plancher doit pouvoir batir).
  [ "$pmaj" -eq "$rmaj" ] && [ "$pmin" -ge "$rmin" ] \
    || { echo "le pin $PIN ne satisfait pas « ~> $mixreq » de mix.exs"; return 1; }
  [ "$fmaj" -eq "$rmaj" ] && [ "$fmin" -ge "$rmin" ] \
    || { echo "le plancher $MIN est SOUS « ~> $mixreq » de mix.exs : une machine au plancher ne batirait pas"; return 1; }
}

@test "APPLY pose le pin : zip telecharge et verifie, arbre sous le prefixe, quatre liens" {
  FAKE_ZIP="$BATS_TEST_TMPDIR/fake.zip"; _fake_zip "$PIN" "$FAKE_ZIP"; FAKE_SHA="$(sha256sum "$FAKE_ZIP" | cut -c1-64)"
  _run_apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -x "${LCARS_ELIXIR_PREFIX}${PIN}/bin/elixir" ]
  local b; for b in elixir elixirc mix iex; do
    [ "$(readlink -f "$PROV_LINK_DIR/$b")" = "$(readlink -f "${LCARS_ELIXIR_PREFIX}${PIN}/bin/$b")" ] || { echo "lien $b faux"; return 1; }
  done
  [[ "$output" == *"Elixir $PIN (${LCARS_ELIXIR_PREFIX}${PIN} ; planchers $OTP / $MIN)"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/opt/.elixir-${PIN}.zip" ]
  # erlang deja au plancher : apt n'est pas appele, le journal dit « trouve »
  refute_out 'APT-ENSURE' <<<"$output"
  grep -q 'apt_already erlang' "$PROV_JOURNAL_ACC"
}

@test "un sha256 qui ne correspond pas : RIEN n'est garde, ni zip ni arbre ni lien — et l'apply est rouge" {
  FAKE_ZIP="$BATS_TEST_TMPDIR/fake.zip"; _fake_zip "$PIN" "$FAKE_ZIP"; FAKE_SHA="0000000000000000000000000000000000000000000000000000000000000000"
  _run_apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"sha256 différent"* ]]
  [ ! -e "${LCARS_ELIXIR_PREFIX}${PIN}" ]
  [ ! -e "$PROV_LINK_DIR/elixir" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/opt")" ] || { echo "reste dans opt : $(ls -A "$BATS_TEST_TMPDIR/opt")"; return 1; }
}

@test "REJEU : le pin deja pose n'est pas retelecharge ; un arbre d'une AUTRE version est retire, un lien vers lui remplace" {
  FAKE_ZIP="$BATS_TEST_TMPDIR/fake.zip"; _fake_zip "$PIN" "$FAKE_ZIP"; FAKE_SHA="$(sha256sum "$FAKE_ZIP" | cut -c1-64)"
  _run_apply; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # un ancien arbre, et le lien elixir pointe dessus
  mkdir -p "${LCARS_ELIXIR_PREFIX}1.18.4/bin"; : > "${LCARS_ELIXIR_PREFIX}1.18.4/bin/elixir"
  ln -sf "${LCARS_ELIXIR_PREFIX}1.18.4/bin/elixir" "$PROV_LINK_DIR/elixir"
  rm -f "$BATS_TEST_TMPDIR/doubles/curl"; FAKE_ZIP=/nonexistent
  _run_apply; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"déjà posé"* ]]
  [ ! -e "${LCARS_ELIXIR_PREFIX}1.18.4" ]
  [ "$(readlink -f "$PROV_LINK_DIR/elixir")" = "$(readlink -f "${LCARS_ELIXIR_PREFIX}${PIN}/bin/elixir")" ]
  [[ "$output" == *"retiré : ${LCARS_ELIXIR_PREFIX}1.18.4"* ]]
}

@test "CHECK : pin absent = drift qui nomme l'apply ; un elixir d'apt devant PROV_LINK_DIR = drift qui le nomme" {
  local bin; bin="$BATS_TEST_TMPDIR/doubles"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nprintf "%s"\n' "$OTP" > "$bin/erl"; chmod 0755 "$bin/erl"
  run bash -c "set -uo pipefail; export PATH=\"$PROV_LINK_DIR:$bin:\$PATH\"; source <(sed '/^case \"\${1:?usage/,\$d' '$MOD'); prov_delivery_is_binary() { return 1; }; check 2>&1"
  [[ "$output" == *"DRIFT"*"Elixir $PIN non posé"*"l'apply le télécharge"* ]]
  # le pin est pose, mais un elixir d'ailleurs repond en premier dans le PATH
  mkdir -p "${LCARS_ELIXIR_PREFIX}${PIN}/bin"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$PIN" > "${LCARS_ELIXIR_PREFIX}${PIN}/bin/elixir"; chmod 0755 "${LCARS_ELIXIR_PREFIX}${PIN}/bin/elixir"
  local apt="$BATS_TEST_TMPDIR/aptbin"; mkdir -p "$apt"; printf '#!/usr/bin/env bash\necho "1.18.3"\n' > "$apt/elixir"; chmod 0755 "$apt/elixir"
  run bash -c "set -uo pipefail; export PATH=\"$apt:$PROV_LINK_DIR:$bin:\$PATH\"; source <(sed '/^case \"\${1:?usage/,\$d' '$MOD'); prov_delivery_is_binary() { return 1; }; check 2>&1"
  [[ "$output" == *"DRIFT"*"« elixir » répond 1.18.3"*"$apt/elixir"* ]]
}

@test "LIVRAISON BINAIRE : rien n'est pose, et TOUT arbre Elixir est un reliquat retire" {
  mkdir -p "${LCARS_ELIXIR_PREFIX}${PIN}/bin"; : > "${LCARS_ELIXIR_PREFIX}${PIN}/bin/elixir"
  ln -sf "${LCARS_ELIXIR_PREFIX}${PIN}/bin/elixir" "$PROV_LINK_DIR/elixir"
  run bash -c "set -uo pipefail; export PATH=\"$PROV_LINK_DIR:\$PATH\"; source <(sed '/^case \"\${1:?usage/,\$d' '$MOD'); prov_delivery_is_binary() { return 0; }; apply 2>&1"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"livraison binaire, rien à bâtir ici"* ]]
  [ ! -e "${LCARS_ELIXIR_PREFIX}${PIN}" ]
  [ ! -e "$PROV_LINK_DIR/elixir" ]
}

@test "CHECK : les deux causes d'un « elixir » qui n'est pas le pin se distinguent — notre lien, ou quelqu'un devant nous" {
  local bin="$BATS_TEST_TMPDIR/doubles"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nprintf "%s"\n' "$OTP" > "$bin/erl"; chmod 0755 "$bin/erl"
  # le pin est pose
  mkdir -p "${LCARS_ELIXIR_PREFIX}${PIN}/bin"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$PIN" > "${LCARS_ELIXIR_PREFIX}${PIN}/bin/elixir"
  chmod 0755 "${LCARS_ELIXIR_PREFIX}${PIN}/bin/elixir"
  # CAS 1 : NOTRE lien pointe sur un autre arbre (le poste du 2026-09-07)
  mkdir -p "${LCARS_ELIXIR_PREFIX}1.18.4/bin"
  printf '#!/usr/bin/env bash\necho "1.18.4"\n' > "${LCARS_ELIXIR_PREFIX}1.18.4/bin/elixir"
  chmod 0755 "${LCARS_ELIXIR_PREFIX}1.18.4/bin/elixir"
  ln -sf "${LCARS_ELIXIR_PREFIX}1.18.4/bin/elixir" "$PROV_LINK_DIR/elixir"
  run bash -c "set -uo pipefail; export PATH=\"$PROV_LINK_DIR:$bin:\$PATH\"; source <(sed '/^case \"\${1:?usage/,\$d' '$MOD'); prov_delivery_is_binary() { return 1; }; check 2>&1"
  [[ "$output" == *"c'est NOTRE lien $PROV_LINK_DIR/elixir qui pointe sur un autre arbre"* ]]
  refute_out 'est devant .* dans le PATH ; c'"'"'est LUI qui compile' <<<"$output"
  # et le drift sur l'arbre dit ce que converger ferait
  [[ "$output" == *"${LCARS_ELIXIR_PREFIX}1.18.4"*"retire (rm -rf)"* ]]
  # CAS 2 : notre lien est bon, mais un elixir d'ailleurs passe avant
  ln -sf "${LCARS_ELIXIR_PREFIX}${PIN}/bin/elixir" "$PROV_LINK_DIR/elixir"
  local devant="$BATS_TEST_TMPDIR/devant"; mkdir -p "$devant"
  printf '#!/usr/bin/env bash\necho "1.18.3"\n' > "$devant/elixir"; chmod 0755 "$devant/elixir"
  run bash -c "set -uo pipefail; export PATH=\"$devant:$PROV_LINK_DIR:$bin:\$PATH\"; source <(sed '/^case \"\${1:?usage/,\$d' '$MOD'); prov_delivery_is_binary() { return 1; }; check 2>&1"
  [[ "$output" == *"$devant/elixir"*"est devant $PROV_LINK_DIR dans le PATH ; c'est LUI qui compile"* ]]
  refute_out 'NOTRE lien' <<<"$output"
}
