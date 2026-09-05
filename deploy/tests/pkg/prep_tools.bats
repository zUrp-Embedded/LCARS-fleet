#!/usr/bin/env bats
# SOURCE: deploy/tests/pkg/prep_tools.bats
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: temoins de l'outillage du pack — prep-nfpm.sh et prep-tofu.sh (les pins, le refus sur
#         ecart, la reprise d'un outil deja la) et la place des .deb dans pack.sh
#
# ⚠ AUCUN TELECHARGEMENT ICI : curl est double (LCARS_CURL_BIN) et rend ce que le decor lui dicte.
# Ce qui se mesure est la DECISION — un sha qui ne colle pas refuse, un outil deja a la bonne
# version ne se retelecharge pas, les pins de tofu sont LUS dans 46-tofu et non recopies.

# shellcheck disable=SC2016
load ../refute

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PKG="$REPO/deploy/pkg"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/tools" "$T/bin"
  # un curl de decor : il ecrit un fichier dont le sha ne colle a rien
  printf '#!/usr/bin/env bash\nfor a in "$@"; do :; done\nout="${*: -2:1}"\n[[ "$out" != -o ]] || out="${*: -1}"\nprintf "pas le bon binaire" > "$out"\necho "curl $*" >> "$T_LOG"\n' > "$T/bin/curl"
  chmod +x "$T/bin/curl"
  export LCARS_CURL_BIN="$T/bin/curl" T_LOG="$T/curl.log"; : > "$T_LOG"
}

@test "prep-nfpm : un sha256 qui ne colle pas est REFUSE, rien n'est pose" {
  run bash "$PKG/prep-nfpm.sh" --tools "$T/tools"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256 MISMATCH"* ]]
  [ ! -e "$T/tools/nfpm" ]
  grep -q 'github.com/goreleaser/nfpm/releases/download/v2.47.0/nfpm_2.47.0_Linux_' "$T_LOG"
  grep -q -- "--proto =https" "$T_LOG"
}

@test "prep-nfpm : un nfpm deja la, a la version epinglee, n'est pas retelecharge — et son chemin s'imprime" {
  printf '#!/usr/bin/env bash\necho "GitVersion:    2.47.0"\n' > "$T/tools/nfpm"; chmod +x "$T/tools/nfpm"
  run bash "$PKG/prep-nfpm.sh" --tools "$T/tools"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$T/tools/nfpm" ]
  [ ! -s "$T_LOG" ]
  # une autre version : il retelecharge (et le decor refuse)
  printf '#!/usr/bin/env bash\necho "GitVersion:    2.40.0"\n' > "$T/tools/nfpm"
  run bash "$PKG/prep-nfpm.sh" --tools "$T/tools"
  [ "$status" -eq 1 ]
  [ -s "$T_LOG" ]
}

@test "prep-nfpm : les deux pins sont ceux du mandat (checksums.txt v2.47.0), et ils ne vivent PAS dans pack.sh" {
  grep -q '^NFPM_VERSION=2.47.0$' "$PKG/prep-nfpm.sh"
  grep -q '^NFPM_SHA256_X86_64=0660ca602b2d2d2ae4781a06c692b3eeb9d437ffea05b831d76e41f4a3188783$' "$PKG/prep-nfpm.sh"
  grep -q '^NFPM_SHA256_ARM64=1c0f5f2999b9a974bfb04fdb0cc3306096de530ac5dbb25d739cc5f5219c919c$' "$PKG/prep-nfpm.sh"
  grep -vE '^\s*#' "$REPO/pack.sh" | refute_out '[0-9a-f]{40}'
}

stage_decor() { # un stage minimal pour prep-tofu : le module 46 (les pins), la table, la recette
  mkdir -p "$T/stage/deploy/modules.d" "$T/stage/runtime/services/forge-recipe/instance"
  cp "$REPO/deploy/modules.d/46-tofu.sh" "$T/stage/deploy/modules.d/"
  cp "$REPO/deploy/system.manifest" "$T/stage/deploy/"
  echo 'x' > "$T/stage/runtime/services/forge-recipe/main.tf"
  echo 'y' > "$T/stage/runtime/services/forge-recipe/instance/main.tf"
}

@test "prep-tofu : la version et les sha256 sont LUS dans 46-tofu — et un sha qui ne colle pas refuse" {
  stage_decor
  run bash "$PKG/prep-tofu.sh" --tools "$T/tools" --stage "$T/stage" --arch amd64
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256 MISMATCH"* ]]
  local v; v="$(sed -n 's/^TOFU_VERSION="${LCARS_TOFU_VERSION:-\(.*\)}"$/\1/p' "$REPO/deploy/modules.d/46-tofu.sh")"
  [ -n "$v" ]
  grep -q "opentofu/releases/download/v$v/tofu_${v}_linux_amd64.zip" "$T_LOG"
  local want; want="$(sed -n 's/^TOFU_SHA256_AMD64=//p' "$REPO/deploy/modules.d/46-tofu.sh")"
  [[ "$output" == *"attendu : $want"* ]]
  [ ! -e "$T/tools/tofu/tofu" ]
  # aucun pin recopie dans le script
  grep -vE '^\s*#' "$PKG/prep-tofu.sh" | refute_out '[0-9a-f]{64}'
}

@test "prep-tofu : un tofu deja la bâtit le miroir sur une COPIE de la recette (instance puis .), prouve par un init, et ecrit le tofurc au chemin de la TABLE" {
  stage_decor
  mkdir -p "$T/tools/tofu"
  local v; v="$(sed -n 's/^TOFU_VERSION="${LCARS_TOFU_VERSION:-\(.*\)}"$/\1/p' "$REPO/deploy/modules.d/46-tofu.sh")"
  cat > "$T/tools/tofu/tofu" <<TOFU
#!/usr/bin/env bash
case "\$1" in
  version) echo "OpenTofu v$v" ;;
  providers|init) echo "\$(basename "\$PWD") \$*" >> "$T/tofu.log" ;;
esac
TOFU
  chmod +x "$T/tools/tofu/tofu"; : > "$T/tofu.log"
  run bash "$PKG/prep-tofu.sh" --tools "$T/tools" --stage "$T/stage" --arch arm64
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ ! -s "$T_LOG" ]                                              # rien telecharge
  [ "${lines[-1]}" = "$T/tools/tofu" ]
  # l'ordre de 46 : instance puis la racine, mirror puis init
  [ "$(sed -n 1p "$T/tofu.log")" = "instance providers mirror -platform=linux_arm64 $T/tools/tofu/providers" ]
  [[ "$(sed -n 2p "$T/tofu.log")" == *"providers mirror -platform=linux_arm64"* ]]
  [[ "$(sed -n 3p "$T/tofu.log")" == "instance init"* ]]
  [ "$(wc -l < "$T/tofu.log")" -eq 4 ]
  # le tofurc du POSTE vise le chemin declare par la table, pas le tiroir
  local dst; dst="$(awk '$1=="dir" && $2 ~ /\/tofu\/providers$/ {print $2; exit}' "$REPO/deploy/system.manifest")"
  grep -q "path    = \"$dst\"" "$T/tools/tofu/tofurc"
  refute grep -q "$T/tools" "$T/tools/tofu/tofurc"
  # et la copie de travail ne survit pas
  [ -z "$(ls -d "${TMPDIR:-/tmp}"/lcars-pack-recipe.* 2>/dev/null)" ]
}

@test "prep-tofu : le tofurc a la forme que 46-tofu ecrit — les deux blocs s'accordent" {
  # le heredoc de 46, avec $TOFU_DIR/providers a la place du chemin ; le meme texte sort d'ici
  local ref; ref="$(sed -n '/^provider_installation {$/,/^}$/p' "$REPO/deploy/modules.d/46-tofu.sh" | sed 's|\$TOFU_DIR/providers|X|')"
  local mine; mine="$(sed -n '/^provider_installation {$/,/^}$/p' "$PKG/prep-tofu.sh" | sed 's|\$PROVIDERS_DST|X|')"
  [ -n "$ref" ]; [ "$ref" = "$mine" ]
}

@test "pack.sh : --no-deb est instruit, et la chaine deb suit l'ordre nfpm -> tofu -> contents -> nfpm package, APRES le tar" {
  local u; u="$(sed -n '/^# USAGE/,/^# EXIT/p' "$REPO/pack.sh")"
  grep -q -- '--no-deb' <<<"$u"
  grep -q -- '--no-push' <<<"$u"
  grep -q -- '--publish' <<<"$u"
  grep -q 'LCARS_DEB_RELEASE' <<<"$u"
  local code; code="$(grep -vE '^\s*#' "$REPO/pack.sh")"
  local n_tar n_nfpm n_tofu n_gen n_pkg n_push
  n_tar="$(grep -n 'tar -czf "\$OUT"' <<<"$code" | head -1 | cut -d: -f1)"
  n_nfpm="$(grep -n 'prep-nfpm.sh' <<<"$code" | head -1 | cut -d: -f1)"
  n_tofu="$(grep -n 'prep-tofu.sh' <<<"$code" | head -1 | cut -d: -f1)"
  n_gen="$(grep -n 'gen-contents.sh' <<<"$code" | head -1 | cut -d: -f1)"
  n_pkg="$(grep -n 'package -f' <<<"$code" | head -1 | cut -d: -f1)"
  n_push="$(grep -n 'PUBLISH" -eq 1' <<<"$code" | head -1 | cut -d: -f1)"
  [ "$n_tar" -lt "$n_nfpm" ] && [ "$n_nfpm" -lt "$n_tofu" ] && [ "$n_tofu" -lt "$n_gen" ] && [ "$n_gen" -lt "$n_pkg" ] && [ "$n_pkg" -lt "$n_push" ]
  # les .deb sortent du STAGE du tar, et les YAML generes vont a cote du stage, pas dedans
  grep -q -- '--stage "\$STAGE/\$ROOT"' <<<"$code"
  grep -q -- '--out "\$STAGE/.pkg"' <<<"$code"
  # la version vient de mix.exs, l'arch est traduite en nom Debian
  grep -q 'runtime/mix.exs' <<<"$code"
  grep -q 'DEB_ARCH=amd64' <<<"$code"
  # et --no-deb est cable
  grep -qE '^\s+--no-deb\)\s+DEB=0' <<<"$code"
}

@test "pack.sh --publish (lot 5) : rien ne sort sans le drapeau, l'etage vient APRES la porte, le geste est celui de forge-publish.sh, le jeton n'est jamais imprime" {
  local code; code="$(grep -vE '^\s*#' "$REPO/pack.sh")"
  # le defaut ne publie pas ; --no-push est l'ancien nom du defaut, encore accepte
  grep -qE '^PUBLISH=0$' <<<"$code"
  grep -qE '^\s+--publish\)\s+PUBLISH=1' <<<"$code"
  grep -qE '^\s+--no-push\)\s+PUBLISH=0' <<<"$code"
  # la porte de la version est generee AVANT l'etage, et l'etage s'arrete la sans --publish
  local n_door n_gate n_lib n_call
  n_door="$(grep -n 'door-gen.sh' <<<"$code" | head -1 | cut -d: -f1)"
  n_gate="$(grep -n 'PUBLISH" -eq 1' <<<"$code" | head -1 | cut -d: -f1)"
  n_lib="$(grep -n '^\. deploy/lib/forge-publish.sh' <<<"$code" | head -1 | cut -d: -f1)"
  n_call="$(grep -n 'fp_publish_dist "\$FORGE" "\$OWNER" "\$REPO" "\$TAG" "\$DIST"' <<<"$code" | head -1 | cut -d: -f1)"
  [ -n "$n_door" ] && [ -n "$n_gate" ] && [ -n "$n_lib" ] && [ -n "$n_call" ]
  [ "$n_door" -lt "$n_gate" ] && [ "$n_gate" -lt "$n_lib" ] && [ "$n_lib" -lt "$n_call" ]
  # le jeton : environnement ou fichier, passe a la lib par FP_TOKEN — jamais en argv de curl ici, jamais dans un echo/say
  grep -q 'FP_TOKEN="\$TOKEN" fp_publish_dist' <<<"$code"
  ! grep -E '(say|echo|printf) .*\$TOKEN' <<<"$code"
  ! grep -E 'curl .*\$TOKEN' <<<"$code"
  # le tag de la version : celui de git a HEAD quand il y en a un, sinon VERSION-SHA ; la base de la porte le porte
  grep -q 'git describe --tags --exact-match' <<<"$code"
  grep -qE '^TAG="\$\{LCARS_PACK_TAG:-' <<<"$code"
  grep -q 'releases/download/\$TAG' <<<"$code"
  # le depot est derive d origin comme la forge et l owner, et la porte l emploie (plus de lcars-fleet grave seul)
  grep -qE '^_REPO="\$\{LCARS_PACK_REPO:-' <<<"$code"
  grep -q '/${_REPO:-lcars-fleet}/releases/download/' <<<"$code"
  # l ancien paquet generic n existe plus : la Release le remplace
  ! grep -q 'generic/lcars-fleet' <<<"$code"
}
