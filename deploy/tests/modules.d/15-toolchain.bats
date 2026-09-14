#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/15-toolchain.bats
# AUTHOR: bob
# STARDATE: 2026-09-06
# STATUS: témoins de 15-toolchain — le pin d'Elixir des constantes, sa pose sous le décor, ses reliquats
load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  local src="$BATS_TEST_DIRNAME/../.."
  CONSTANTES="$src/installer-constants.env"; MIX="$src/../runtime/mix.exs"
  [ -f "$CONSTANTES" ]
  [ -f "$MIX" ]
  PIN="$(sed -n 's/^PROV_ELIXIR_PIN=//p' "$CONSTANTES")"
  OTP="$(sed -n 's/^PROV_ELIXIR_OTP_MAJOR=//p' "$CONSTANTES")"
  SHA="$(sed -n 's/^PROV_ELIXIR_PIN_SHA256=//p' "$CONSTANTES")"

  # un arbre de l'installeur dont les constantes portent le sha du zip de décor : le pin ne se règle pas
  # par l'environnement, il se lit dans ce fichier
  ARBRE="$BATS_TEST_TMPDIR/arbre"
  mkdir -p "$ARBRE/deploy/lib" "$ARBRE/deploy/modules.d"
  cp "$src"/lib/*.sh "$ARBRE/deploy/lib/"
  cp "$src/system.manifest" "$ARBRE/deploy/"
  cp "$src/modules.d/15-toolchain.sh" "$ARBRE/deploy/modules.d/"
  export PROV_JOURNAL_ACC="$BATS_TEST_TMPDIR/journal"

  decor_pose
  LINKS="$LCARS_DECOR_ROOT/usr/local/bin"
  HOME_PIN="$LCARS_DECOR_ROOT/opt/elixir-$PIN"
  CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  FAKE_ZIP="$BATS_TEST_TMPDIR/fake.zip"
  printf '#!/usr/bin/env bash\nout=""; prev=""; for a in "$@"; do [[ "$prev" == -o ]] && out="$a"; prev="$a"; done\necho "${@: -1}" >> "%s"\ncp "%s" "$out"\n' "$CURL_LOG" "$FAKE_ZIP" > "$DECOR_BIN/curl"
  printf '#!/usr/bin/env bash\nprintf "%s"\n' "$OTP" > "$DECOR_BIN/erl"
  printf '#!/usr/bin/env bash\necho "APT $*" >> "%s"; exit 0\n' "$BATS_TEST_TMPDIR/apt.trace" > "$DECOR_BIN/apt-get"
  chmod 0755 "$DECOR_BIN"/*
}

constantes() { # constantes <sha du zip> — les constantes réelles, le sha du pin remplacé
  { grep -v '^PROV_ELIXIR_PIN_SHA256=' "$CONSTANTES"; printf 'PROV_ELIXIR_PIN_SHA256=%s\n' "$1"; } > "$ARBRE/deploy/installer-constants.env"
}

# un faux zip d'Elixir : bin/elixir répond la version voulue
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

zip_du_pin() { _fake_zip "$PIN" "$FAKE_ZIP"; constantes "$(sha256sum "$FAKE_ZIP" | cut -c1-64)"; }

# mod <check|apply> — le module entier ; DEVANT, s'il est posé, passe avant les liens dans le PATH
mod() {
  [ -f "$ARBRE/deploy/installer-constants.env" ] || constantes "$SHA"
  run env PATH="${DEVANT:+$DEVANT:}$LINKS:$DECOR_BIN:$PATH" PROVISION_LIB="$ARBRE/deploy/lib/provision-lib.sh" \
    PROVISION_MODULE=15-toolchain PROV_SUBSTRATE=linux bash "$ARBRE/deploy/modules.d/15-toolchain.sh" "$1"
}

@test "le pin d'Elixir des constantes satisfait ce que mix.exs exige" {
  [ -n "$PIN" ]
  [ -n "$OTP" ]
  [[ "$SHA" =~ ^[0-9a-f]{64}$ ]]
  local mixreq; mixreq="$(sed -n 's/.*elixir: "~> \([0-9.]*\)".*/\1/p' "$MIX")"
  [ -n "$mixreq" ] || { echo "mix.exs ne déclare plus de requirement elixir — l'accord n'a plus de sujet"; return 1; }
  local rmaj rmin pmaj pmin
  rmaj="${mixreq%%.*}"; rmin="${mixreq#*.}"; rmin="${rmin%%.*}"
  pmaj="${PIN%%.*}";    pmin="${PIN#*.}";    pmin="${pmin%%.*}"
  # `~> M.m` = >= M.m et < (M+1).0 : le pin doit tomber dedans
  [[ "$pmaj" -eq "$rmaj" && "$pmin" -ge "$rmin" ]] \
    || { echo "le pin $PIN ne satisfait pas « ~> $mixreq » de mix.exs"; return 1; }
}

@test "APPLY pose le pin : zip téléchargé et vérifié, arbre sous le décor, quatre liens" {
  zip_du_pin
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -x "$HOME_PIN/bin/elixir" ]
  local b; for b in elixir elixirc mix iex; do
    [ "$(readlink -f "$LINKS/$b")" = "$(readlink -f "$HOME_PIN/bin/$b")" ] || { echo "lien $b faux"; return 1; }
  done
  [[ "$output" == *"Elixir $PIN ($HOME_PIN ; plancher OTP $OTP)"* ]]
  [ ! -e "$LCARS_DECOR_ROOT/opt/.elixir-${PIN}.zip" ]
  # erlang déjà au plancher : apt n'est pas appelé, le journal dit « trouvé »
  [ ! -e "$BATS_TEST_TMPDIR/apt.trace" ]
  grep -q 'apt_already erlang' "$PROV_JOURNAL_ACC"
}

@test "l'URL du zip est celle du pin officiel — un LCARS_ELIXIR_ZIP_URL exporté n'y change rien" {
  zip_du_pin
  LCARS_ELIXIR_ZIP_URL=https://ailleurs.invalid/elixir.zip mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$CURL_LOG")" = "https://github.com/elixir-lang/elixir/releases/download/v${PIN}/elixir-otp-${OTP}.zip" ]
}

@test "l'arbre du pin vit sous /opt/elixir-<pin> du décor — LCARS_ELIXIR_HOME et LCARS_ELIXIR_PREFIX exportés n'y changent rien" {
  zip_du_pin
  LCARS_ELIXIR_HOME="$BATS_TEST_TMPDIR/ailleurs" LCARS_ELIXIR_PREFIX="$BATS_TEST_TMPDIR/ailleurs-" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -x "$HOME_PIN/bin/elixir" ]
  refute compgen -G "$BATS_TEST_TMPDIR/ailleurs*"
}

@test "un sha256 qui ne correspond pas : rien n'est gardé, ni zip ni arbre ni lien — et l'apply est rouge" {
  _fake_zip "$PIN" "$FAKE_ZIP"; constantes 0000000000000000000000000000000000000000000000000000000000000000
  mod apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"sha256 différent"* ]]
  [ ! -e "$HOME_PIN" ]
  [ ! -e "$LINKS/elixir" ]
  [ -z "$(find "$LCARS_DECOR_ROOT/opt" -mindepth 1 -maxdepth 1 ! -name lcars)" ] || { echo "reste dans opt : $(ls -A "$LCARS_DECOR_ROOT/opt")"; return 1; }
}

@test "REJEU : le pin déjà posé n'est pas retéléchargé ; un arbre d'une autre version est retiré, un lien vers lui remplacé" {
  zip_du_pin
  mod apply; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  mkdir -p "$LCARS_DECOR_ROOT/opt/elixir-1.18.4/bin"; : > "$LCARS_DECOR_ROOT/opt/elixir-1.18.4/bin/elixir"
  ln -sf "$LCARS_DECOR_ROOT/opt/elixir-1.18.4/bin/elixir" "$LINKS/elixir"
  : > "$CURL_LOG"
  mod apply; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"déjà posé"* ]]
  [ ! -s "$CURL_LOG" ]
  [ ! -e "$LCARS_DECOR_ROOT/opt/elixir-1.18.4" ]
  [ "$(readlink -f "$LINKS/elixir")" = "$(readlink -f "$HOME_PIN/bin/elixir")" ]
  [[ "$output" == *"retiré : $LCARS_DECOR_ROOT/opt/elixir-1.18.4"* ]]
}

@test "CHECK : pin absent = drift qui nomme l'apply" {
  mod check
  [[ "$output" == *"DRIFT"*"Elixir $PIN non posé"*"l'apply le télécharge"* ]]
}

@test "CHECK : un elixir d'apt devant PROV_LINK_DIR = drift qui le nomme" {
  mkdir -p "$HOME_PIN/bin"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$PIN" > "$HOME_PIN/bin/elixir"; chmod 0755 "$HOME_PIN/bin/elixir"
  local apt="$BATS_TEST_TMPDIR/aptbin"; mkdir -p "$apt"; printf '#!/usr/bin/env bash\necho "1.18.3"\n' > "$apt/elixir"; chmod 0755 "$apt/elixir"
  DEVANT="$apt" mod check
  [[ "$output" == *"DRIFT"*"« elixir » répond 1.18.3"*"$apt/elixir"* ]]
}

@test "LIVRAISON BINAIRE : rien n'est posé, et tout arbre Elixir est un reliquat retiré" {
  : > "$ARBRE/.source-revision"
  mkdir -p "$HOME_PIN/bin"; : > "$HOME_PIN/bin/elixir"
  ln -sf "$HOME_PIN/bin/elixir" "$LINKS/elixir"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"livraison binaire, rien à bâtir ici"* ]]
  [ ! -e "$HOME_PIN" ]
  [ ! -e "$LINKS/elixir" ]
}

@test "CHECK : notre lien qui pointe sur un autre arbre se dit tel, avec l'arbre à retirer" {
  mkdir -p "$HOME_PIN/bin"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$PIN" > "$HOME_PIN/bin/elixir"; chmod 0755 "$HOME_PIN/bin/elixir"
  local ancien="$LCARS_DECOR_ROOT/opt/elixir-1.18.4"
  mkdir -p "$ancien/bin"
  printf '#!/usr/bin/env bash\necho "1.18.4"\n' > "$ancien/bin/elixir"; chmod 0755 "$ancien/bin/elixir"
  ln -sf "$ancien/bin/elixir" "$LINKS/elixir"
  mod check
  [[ "$output" == *"c'est NOTRE lien $LINKS/elixir qui pointe sur un autre arbre"* ]]
  refute_out 'est devant .* dans le PATH ; c'"'"'est LUI qui compile' <<<"$output"
  [[ "$output" == *"$ancien"*"retire (rm -rf)"* ]]
}

@test "CHECK : un elixir d'ailleurs devant notre bon lien se dit tel — ce n'est pas notre lien" {
  mkdir -p "$HOME_PIN/bin"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$PIN" > "$HOME_PIN/bin/elixir"; chmod 0755 "$HOME_PIN/bin/elixir"
  ln -sf "$HOME_PIN/bin/elixir" "$LINKS/elixir"
  local devant="$BATS_TEST_TMPDIR/devant"; mkdir -p "$devant"
  printf '#!/usr/bin/env bash\necho "1.18.3"\n' > "$devant/elixir"; chmod 0755 "$devant/elixir"
  DEVANT="$devant" mod check
  [[ "$output" == *"$devant/elixir"*"est devant $LINKS dans le PATH ; c'est LUI qui compile"* ]]
  refute_out 'NOTRE lien' <<<"$output"
}
