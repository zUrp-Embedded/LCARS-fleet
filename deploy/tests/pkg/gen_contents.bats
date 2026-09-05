#!/usr/bin/env bats
# SOURCE: deploy/tests/pkg/gen_contents.bats
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: temoins du generateur de `contents:` (deploy/pkg/gen-contents.sh) et des huit YAML nFPM,
#         sur un STAGE DE DECOR — et, quand nfpm est la, des .deb qu'ils produisent
#
# ─── CE QUE CES TEMOINS TIENNENT ────────────────────────────────────────────────────────────────
#
# Le .deb de `lcars` porte EXACTEMENT ce que le rail pose depuis un kit : la table dit les modes
# des objets nommes, les poseurs (60, 62, 44) disent ceux des arbres. Le temoin central est donc
# une egalite stricte — `dpkg-deb -c` du paquet = la liste que le generateur attend, ni un chemin
# de plus, ni un de moins. Un generateur qui oublierait un arbre, ou nFPM qui ajouterait un parent
# qu'on n'a pas prevu, rougit ici.
#
# ⚠ LE DECOR EST BATI DEPUIS LES VRAIS ARBRES DU DEPOT (runtime/{etc,services,bin}, deploy sans
# tests, assets, catalogues) : ce sont les listes de 62-runtime-helpers et de release.manifest qui
# decident de ce qui doit etre la, et un decor a la main les recopierait — deux sources. Ce qui est
# FABRIQUE : la release (trois fichiers et un lien), la doc batie, le tampon de revision, et
# l'outillage tofu du tiroir. Rien ici ne touche la machine ni le reseau.
#
# ⚠ nfpm N'EST PAS UN PAQUET APT : les temoins qui en dependent se SAUTENT quand il manque, en le
# disant. Il se cherche dans le tiroir des paquets (`../lcars-packs/.tools/nfpm`, ce que pack.sh
# pose) puis dans le PATH. lintian pareil.

load ../refute

setup_file() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; export REPO
  export GEN="$REPO/deploy/pkg/gen-contents.sh"
  export DECOR="$BATS_FILE_TMPDIR/decor"
  export STAGE="$DECOR/lcars_install" TOOLS="$DECOR/tools" OUT="$DECOR/out" DEBS="$DECOR/debs"
  mkdir -p "$STAGE" "$TOOLS/tofu/providers/registry.opentofu.org/decor" "$TOOLS/deck-static" "$OUT" "$DEBS"
  # le client de console, tel que prep-deck-static.sh le prepare (trois fichiers aux pins de 62)
  printf 'js' > "$TOOLS/deck-static/xterm.js"; printf 'css' > "$TOOLS/deck-static/xterm.css"; printf 'fit' > "$TOOLS/deck-static/addon-fit.js"

  # le tampon, la release, la doc — ce que pack.sh ajoute au `git archive`
  printf 'decor123\n' > "$STAGE/.source-revision"
  local rel="$STAGE/runtime/_build/prod/rel/lcars_fleet"
  mkdir -p "$rel/bin" "$rel/lib/lcars_fleet-0.9.0/priv/api" "$rel/releases/0.9.0"
  printf '#!/bin/sh\necho fleet\n' > "$rel/bin/lcars_fleet"; chmod +x "$rel/bin/lcars_fleet"
  echo "sha=decor123" > "$rel/lib/lcars_fleet-0.9.0/priv/api/build_info.txt"
  echo "27 0.9.0" > "$rel/releases/start_erl.data"
  ln -s ../lib/lcars_fleet-0.9.0 "$rel/releases/lien"
  mkdir -p "$STAGE/assets/github.io/dist/assets" "$STAGE/assets/github.io/node_modules/junk"
  echo '<html>doc</html>' > "$STAGE/assets/github.io/dist/index.html"
  echo 'x' > "$STAGE/assets/github.io/dist/assets/a.js"
  echo 'junk' > "$STAGE/assets/github.io/node_modules/junk/j.js"

  # les vrais arbres, tels que `git archive` les donne — sans les tests de deploy (Q2)
  cp -a "$REPO/runtime/etc" "$REPO/runtime/bin" "$REPO/runtime/services" "$STAGE/runtime/"
  cp -a "$REPO/assets/avatars" "$REPO/assets/favicon" "$STAGE/assets/"
  cp -a "$REPO/catalogues" "$STAGE/"
  mkdir -p "$STAGE/deploy/tests"
  ( cd "$REPO/deploy" && tar -cf - --exclude=./tests . ) | ( cd "$STAGE/deploy" && tar -xf - )
  echo 'decor' > "$STAGE/deploy/tests/decor.bats"
  # ce que la copie de 62 n'emporte pas, present dans le stage pour prouver qu'il est ecarte
  mkdir -p "$STAGE/runtime/services/forge-recipe/.terraform"
  echo 't' > "$STAGE/runtime/services/forge-recipe/.terraform/lock"
  echo 's' > "$STAGE/runtime/services/forge-recipe/terraform.tfstate"

  # l'outillage tofu du tiroir (ce que prep-tofu.sh y pose)
  printf '#!/bin/sh\necho tofu\n' > "$TOOLS/tofu/tofu"; chmod +x "$TOOLS/tofu/tofu"
  echo 'provider_installation {}' > "$TOOLS/tofu/tofurc"
  echo 'p' > "$TOOLS/tofu/providers/registry.opentofu.org/decor/tofu-provider"; chmod +x "$TOOLS/tofu/providers/registry.opentofu.org/decor/tofu-provider"

  run bash "$GEN" --stage "$STAGE" --out "$OUT" --tools "$TOOLS"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }

  # nfpm : le tiroir des paquets d'abord (pack.sh l'y pose), le PATH ensuite
  NFPM="$REPO/../lcars-packs/.tools/nfpm"
  [[ -x "$NFPM" ]] || NFPM="$(command -v nfpm || true)"
  export NFPM
  if [[ -n "$NFPM" ]]; then
    export LCARS_ARCH=amd64 LCARS_VERSION=0.9.0 LCARS_DEB_RELEASE=1.decor
    local p
    while read -r p; do
      ( cd "$REPO/deploy/pkg" && "$NFPM" package -f "$OUT/$p.yaml" -p deb -t "$DEBS" >/dev/null 2>&1 ) \
        || { echo "nfpm a refuse $p.yaml" >&2; return 1; }
    done < "$OUT/packages.list"
  fi
}

setup() {
  # les variables du gate sont neutralisees ; celles du decor viennent de setup_file
  :
}

need_nfpm() { [[ -n "${NFPM:-}" ]] || skip "nfpm absent — pose-le dans ../lcars-packs/.tools (pack.sh le fait) ou dans le PATH"; }
deb_of() { ls "$DEBS/$1"_*.deb | head -1; }
seen_paths() { # seen_paths <paquet> -> les chemins que dpkg-deb -c montre, normalises et tries
  dpkg-deb -c "$(deb_of "$1")" | awk '{p=$6; sub(/^\.\//,"/",p); sub(/\/$/,"",p); print p}' | LC_ALL=C sort -u
}
tar_line() { dpkg-deb --fsys-tarfile "$(deb_of "$1")" | tar -tv | grep -E " \./${2#/}( |$| -> )"; }

@test "GARDE : le generateur produit huit YAML, une liste de chemins par paquet, et la liste des paquets" {
  local p
  for p in lcars lcars-workstation lcars-container lcars-forge lcars-bench lcars-demo lcars-tofu lcars-docker-desktop; do
    [ -s "$OUT/$p.yaml" ]
    [ -f "$OUT/$p.paths" ]
    grep -q "^name: $p\$" "$OUT/$p.yaml"
  done
  [ "$(wc -l < "$OUT/packages.list")" -eq 8 ]
  # les gestes et meta-paquets n'ont AUCUN contenu, et le YAML le dit
  for p in lcars-workstation lcars-bench lcars-demo lcars-docker-desktop; do
    [ ! -s "$OUT/$p.paths" ]
    grep -q 'aucun contenu' "$OUT/$p.yaml"
  done
}

@test "lcars : la TABLE decide des repertoires — mode et proprietaire de chaque dir/prefix d'un poste" {
  # chaque `dir`/`prefix` de la table (any, wsl, linux ; sans joker, hors /home et /root) est un chemin
  # du paquet lcars ou de lcars-tofu, avec exactement le mode et le proprietaire de sa ligne
  local n=0 cls obj mode owner sub c yaml
  while read -r cls obj mode owner sub; do
    c="${cls%%:*}"
    case "$c" in prefix|dir) ;; *) continue ;; esac
    [[ "$obj" != *"<"* ]] || continue
    case "$obj" in /home*|/root*) continue ;; esac
    case ",${sub//+/,}," in *,any,*|*,wsl,*|*,linux,*) ;; *) continue ;; esac
    if [[ "$obj" == /opt/lcars/tofu* ]]; then yaml="$OUT/lcars-tofu.yaml"; else yaml="$OUT/lcars.yaml"; fi
    grep -qx "$obj" "${yaml%.yaml}.paths" || { echo "absent du paquet : $obj" >&2; return 1; }
    grep -A4 "^  - dst: \"$obj\"\$" "$yaml" | grep -q "mode: $mode" || { echo "mode faux : $obj $mode" >&2; return 1; }
    grep -A5 "^  - dst: \"$obj\"\$" "$yaml" | grep -q "owner: ${owner%%:*}" || { echo "owner faux : $obj $owner" >&2; return 1; }
    n=$((n + 1))
  done < <(grep -vE '^\s*#|^\s*$' "$REPO/deploy/system.manifest")
  [ "$n" -ge 12 ]
}

@test "lcars : ce que la table ECARTE est dit dans le YAML, pas tu — unites, seat.uid, /home, docker" {
  grep -q '/etc/systemd/system/lcars-landing.service (ancre derivee' "$OUT/lcars.yaml"
  grep -q '/etc/lcars/seat.uid (ancre derivee' "$OUT/lcars.yaml"
  grep -q '/etc/skel/.bashrc (merge' "$OUT/lcars.yaml"
  grep -q '/root/.terraform.d (hors perimetre' "$OUT/lcars.yaml"
  grep -q '/opt/node-<version> (joker)' "$OUT/lcars.yaml"
  grep -q 'multi-user.target.wants/lcars-landing.service (lien pose par un autre geste)' "$OUT/lcars.yaml"
  # et aucun d'eux n'est un chemin du paquet
  refute grep -qE 'systemd|seat.uid|/home/|/root/|/run/' "$OUT/lcars.paths"
}

@test "lcars : les ANCRES qui ont une source voyagent — tampons, deux binaires de /usr/local/bin, le bashrc en conffile" {
  grep -qx '/opt/lcars/.source-revision' "$OUT/lcars.paths"
  grep -qx '/opt/lcars/.helpers-revision' "$OUT/lcars.paths"
  grep -qx '/usr/local/bin/lcars-toolchain-converge' "$OUT/lcars.paths"
  grep -qx '/usr/local/bin/lcars-authority-ask' "$OUT/lcars.paths"
  grep -qx '/etc/lcars/lcars.bashrc' "$OUT/lcars.paths"
  grep -A2 '^  - src: .*/helpers-revision"$' "$OUT/lcars.yaml" | grep -q 'dst: "/opt/lcars/.helpers-revision"'
  [ "$(cat "$OUT/helpers-revision")" = "decor123" ]
  grep -A2 'dst: "/etc/lcars/lcars.bashrc"' "$OUT/lcars.yaml" | grep -q 'type: config'
}

@test "lcars : les LIENS de PATH sont ceux de release.manifest — fleet et lcars, pas node ni npm" {
  grep -A2 'dst: "/usr/local/bin/fleet"' "$OUT/lcars.yaml" | grep -q 'type: symlink'
  grep -B1 'dst: "/usr/local/bin/fleet"' "$OUT/lcars.yaml" | grep -q 'src: "/opt/lcars/runtime/bin/fleet"'
  grep -qx '/usr/local/bin/lcars' "$OUT/lcars.paths"
  refute grep -qE '^/usr/local/bin/(node|npm|npx)$' "$OUT/lcars.paths"
}

@test "lcars : le PREFIXE est celui de deploy-release.sh — rel/, bin/ (release.manifest), etc/fleet.env.template, en 0750/0640 root:fleet" {
  local name mode _
  while read -r name mode _; do
    grep -qx "/opt/lcars/runtime/bin/$name" "$OUT/lcars.paths" || { echo "bin/$name absent" >&2; return 1; }
    if [[ "$mode" == exec ]]; then
      grep -A4 "dst: \"/opt/lcars/runtime/bin/$name\"" "$OUT/lcars.yaml" | grep -q 'mode: 0750'
    else
      grep -A4 "dst: \"/opt/lcars/runtime/bin/$name\"" "$OUT/lcars.yaml" | grep -q 'mode: 0640'
    fi
  done < <(awk 'NF && $1 !~ /^#/ { print $1, $2 }' "$REPO/runtime/etc/release.manifest")
  grep -qx '/opt/lcars/runtime/etc/fleet.env.template' "$OUT/lcars.paths"
  grep -qx '/opt/lcars/runtime/rel/lcars_fleet/bin/lcars_fleet' "$OUT/lcars.paths"
  grep -A4 'dst: "/opt/lcars/runtime/rel/lcars_fleet/bin/lcars_fleet"' "$OUT/lcars.yaml" | grep -q 'mode: 0750'
  grep -A5 'dst: "/opt/lcars/runtime/rel/lcars_fleet/bin/lcars_fleet"' "$OUT/lcars.yaml" | grep -q 'group: fleet'
  # un lien DANS la release reste un lien
  grep -A2 'dst: "/opt/lcars/runtime/rel/lcars_fleet/releases/lien"' "$OUT/lcars.yaml" | grep -q 'type: symlink'
}

@test "lcars : la RACINE est celle de 62 — chaque HELPER a plat, DATA, et les arbres EMBEDDED / EMBEDDED_ROOT" {
  # les tableaux se lisent dans le module, pas dans une copie du temoin
  local mod="$REPO/deploy/modules.d/62-runtime-helpers.sh" h n
  local -a helpers
  mapfile -t helpers < <(sed -n '/^HELPERS=(/,/^)/p' "$mod" | grep -vE '^(HELPERS=\(|\)|\s*#)' | tr -d ' ')
  [ "${#helpers[@]}" -ge 10 ]
  for h in "${helpers[@]}"; do
    grep -qx "/opt/lcars/$h" "$OUT/lcars.paths" || { echo "auxiliaire absent : $h" >&2; return 1; }
    grep -A4 "dst: \"/opt/lcars/$h\"" "$OUT/lcars.yaml" | grep -q 'mode: 0755'
  done
  grep -qx '/opt/lcars/console.tmux.conf' "$OUT/lcars.paths"
  for n in etc services bin assets catalogues deploy; do
    grep -qx "/opt/lcars/$n" "$OUT/lcars.paths" || { echo "arbre absent : $n" >&2; return 1; }
  done
  grep -qx '/opt/lcars/deploy/provision' "$OUT/lcars.paths"
  grep -qx '/opt/lcars/deploy/system.manifest' "$OUT/lcars.paths"
  grep -qx '/opt/lcars/services/forge-gestures.sh' "$OUT/lcars.paths"
}

@test "lcars : ce que la copie N'EMPORTE PAS n'est pas dans le paquet — node_modules, .terraform, tfstate, deploy/tests" {
  refute grep -q 'node_modules' "$OUT/lcars.paths"
  refute grep -qE '/\.terraform(/|$)' "$OUT/lcars.paths"
  refute grep -q 'tfstate' "$OUT/lcars.paths"
  refute grep -q '/opt/lcars/deploy/tests' "$OUT/lcars.paths"
  # mais la doc batie, elle, voyage deux fois : dans assets/ (62) ET sous share/doc (44)
  grep -qx '/opt/lcars/assets/github.io/dist/index.html' "$OUT/lcars.paths"
  grep -qx '/opt/lcars/share/doc/index.html' "$OUT/lcars.paths"
  grep -qx '/opt/lcars/share/avatars' "$OUT/lcars.paths"
  grep -qx '/opt/lcars/share/favicon' "$OUT/lcars.paths"
}

@test "DECOUPAGE : le rail conteneur a lcars-container, la forge du poste a lcars-forge, tofu a lcars-tofu — et lcars n'a rien d'eux" {
  grep -qx '/opt/lcars/deploy/container' "$OUT/lcars-container.paths"
  grep -qx '/opt/lcars/deploy/docker/Dockerfile' "$OUT/lcars-container.paths"
  grep -qx '/opt/lcars/deploy/docker/docker-compose.secrets.yml' "$OUT/lcars-container.paths"
  grep -qx '/opt/lcars/deploy/docker/forge-compose.yml' "$OUT/lcars-forge.paths"
  grep -qx '/opt/lcars/deploy/docker/runner-compose.yml' "$OUT/lcars-forge.paths"
  grep -qx '/opt/lcars/deploy/docker/forge-runner.sh' "$OUT/lcars-forge.paths"
  refute grep -q 'forge-compose' "$OUT/lcars-container.paths"
  grep -qx '/usr/local/bin/tofu' "$OUT/lcars-tofu.paths"
  grep -qx '/opt/lcars/tofu/tofurc' "$OUT/lcars-tofu.paths"
  grep -qx '/opt/lcars/tofu/providers/registry.opentofu.org/decor/tofu-provider' "$OUT/lcars-tofu.paths"
  refute grep -qE '^/opt/lcars/deploy/(container|docker)' "$OUT/lcars.paths"
  refute grep -qE '^/opt/lcars/tofu(/|$)|^/usr/local/bin/tofu$' "$OUT/lcars.paths"   # (var/tofu et 46-tofu.sh sont a lcars)
  # un chemin n'appartient qu'a UN paquet
  [ -z "$(cat "$OUT"/*.paths | grep -vE '^/(opt|usr|etc|var)(/lcars|/local|/local/bin|/lib|/tmp|/lcars/deploy|/lcars/deploy/docker)?$' | sort | uniq -d)" ]
}

@test "REFUS : sans .source-revision le generateur s'arrete — l'install se croirait SOURCE" {
  local s2="$BATS_TEST_TMPDIR/s2"; mkdir -p "$s2"
  cp -a "$STAGE/." "$s2/"; rm -f "$s2/.source-revision"
  run bash "$GEN" --stage "$s2" --out "$BATS_TEST_TMPDIR/o2"
  [ "$status" -ne 0 ]
  [[ "$output" == *".source-revision"* ]]
}

@test "REFUS : sans release dans le stage, rien n'est genere" {
  local s2="$BATS_TEST_TMPDIR/s2"; mkdir -p "$s2"
  cp -a "$STAGE/." "$s2/"; rm -rf "$s2/runtime/_build"
  run bash "$GEN" --stage "$s2" --out "$BATS_TEST_TMPDIR/o2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"release"* ]]
}

@test "SANS OUTILLAGE TOFU : lcars-tofu n'est pas genere, et c'est dit — les sept autres le sont" {
  run bash "$GEN" --stage "$STAGE" --out "$BATS_TEST_TMPDIR/o3"
  [ "$status" -eq 0 ]
  [[ "$output" == *"lcars-tofu"*"NON genere"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/o3/lcars-tofu.yaml" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/o3/packages.list")" -eq 7 ]
}

@test "LES SCRIPTS sont resolus depuis deploy/pkg, en absolu — nfpm ne depend pas de son cwd" {
  grep -qE '^\s+postinstall: /.*/deploy/pkg/lcars/postinst$' "$OUT/lcars.yaml"
  grep -qE '^\s+preinstall: /.*/deploy/pkg/lcars/preinst$' "$OUT/lcars.yaml"
  refute grep -qE 'install: \./' "$OUT/lcars.yaml"
}

# ─── AVEC nfpm : les .deb eux-memes ─────────────────────────────────────────────────────────────

@test "nfpm : les huit YAML donnent huit .deb" {
  need_nfpm
  [ "$(ls "$DEBS"/*.deb | wc -l)" -eq 8 ]
}

@test "dpkg-deb -c : lcars porte EXACTEMENT les chemins attendus — ni plus, ni moins" {
  need_nfpm
  diff <(LC_ALL=C sort -u "$OUT/lcars.paths") <(seen_paths lcars)
  [ "$(seen_paths lcars | wc -l)" -ge 300 ]
}

@test "dpkg-deb -c : lcars-container, lcars-forge et lcars-tofu aussi" {
  need_nfpm
  local p
  for p in lcars-container lcars-forge lcars-tofu; do
    diff <(LC_ALL=C sort -u "$OUT/$p.paths") <(seen_paths "$p") || { echo "ecart sur $p" >&2; return 1; }
  done
}

@test "dpkg-deb -I : lcars depend du SOCLE et recommande un rail ; docker en alternatives sur container et forge ; demo = les trois" {
  need_nfpm
  local ctl; ctl="$(dpkg-deb -I "$(deb_of lcars)")"
  [[ "$ctl" == *"Depends: tmux, bubblewrap, git, curl, jq, unzip, ca-certificates, python3, socat, git-filter-repo, gh, util-linux-extra, sudo, ttyd"* ]]
  [[ "$ctl" == *"Recommends: lcars-workstation | lcars-container"* ]]
  [[ "$ctl" == *"Architecture: amd64"* ]]
  refute grep -qE 'Depends:.*(erlang|elixir|nodejs|build-essential|docker)' <<<"$ctl"
  ctl="$(dpkg-deb -I "$(deb_of lcars-container)")"
  [[ "$ctl" == *"Depends: lcars, docker.io (>= 26) | docker-ce | lcars-docker-desktop, docker-compose-v2 | docker-compose-plugin"* ]]
  [[ "$ctl" == *"Architecture: all"* ]]
  ctl="$(dpkg-deb -I "$(deb_of lcars-forge)")"
  [[ "$ctl" == *"Depends: lcars, lcars-tofu, docker.io (>= 26) | docker-ce | lcars-docker-desktop, docker-compose-v2 | docker-compose-plugin"* ]]
  ctl="$(dpkg-deb -I "$(deb_of lcars-bench)")"
  [[ "$ctl" == *"Depends: lcars-forge, lcars-workstation | lcars-container"* ]]
  ctl="$(dpkg-deb -I "$(deb_of lcars-demo)")"
  [[ "$ctl" == *"Depends: lcars-workstation, lcars-forge, lcars-bench"* ]]
  ctl="$(dpkg-deb -I "$(deb_of lcars-workstation)")"
  [[ "$ctl" == *"Depends: lcars, systemd"* ]]
  ctl="$(dpkg-deb -I "$(deb_of lcars-tofu)")"
  [[ "$ctl" == *"Provides: opentofu"* ]]
  refute grep -q 'Depends:' <<<"$ctl"
  ctl="$(dpkg-deb -I "$(deb_of lcars-docker-desktop)")"
  refute grep -q 'Depends:' <<<"$ctl"
  [ "$(dpkg-deb -c "$(deb_of lcars-docker-desktop)" | wc -l)" -eq 0 ]
  [ "$(dpkg-deb -c "$(deb_of lcars-demo)" | wc -l)" -eq 0 ]
}

@test "dpkg-deb -I : les maintainer scripts sont dans le control, et seulement ceux que le YAML nomme" {
  need_nfpm
  # les lignes du control ARCHIVE (« N bytes, N lines * postinst »), pas la prose de la description
  scripts_of() { dpkg-deb -I "$(deb_of "$1")" | grep -oE '^\s+[0-9]+ bytes,\s+[0-9]+ lines\s+\*\s+(pre|post)(inst|rm)' | awk '{print $NF}' | sort | paste -sd' ' -; }
  [ "$(scripts_of lcars)" = "postinst postrm preinst prerm" ]
  [ "$(scripts_of lcars-demo)" = "" ]
  [ "$(scripts_of lcars-container)" = "postrm" ]
  [ "$(scripts_of lcars-forge)" = "postinst postrm prerm" ]
  [ "$(scripts_of lcars-tofu)" = "" ]
}

@test "tar : les modes et proprietaires du paquet sont ceux de la table et des poseurs" {
  need_nfpm
  tar_line lcars /opt/lcars/runtime/ | grep -q '^drwxr-x--- root/fleet'
  tar_line lcars /opt/lcars/runtime/rel/lcars_fleet/bin/lcars_fleet | grep -q '^-rwxr-x--- root/fleet'
  tar_line lcars /opt/lcars/runtime/etc/fleet.env.template | grep -q '^-rw-r----- root/fleet'
  tar_line lcars /opt/lcars/var/tokens/ | grep -q '^drwx--x--- lcars-authority/fleet'
  tar_line lcars /opt/lcars/var/catalogues/ | grep -q '^drwxr-x--- root/fleet'
  tar_line lcars /opt/lcars/console.sh | grep -q '^-rwxr-xr-x root/root'
  tar_line lcars /opt/lcars/share/doc/index.html | grep -q '^-rw-r--r-- root/root'
  tar_line lcars /etc/lcars/lcars.bashrc | grep -q '^-rw-r--r-- root/root'
  tar_line lcars /usr/local/bin/fleet | grep -q -- '-> /opt/lcars/runtime/bin/fleet'
  tar_line lcars-tofu /usr/local/bin/tofu | grep -q '^-rwxr-xr-x root/root'
  tar_line lcars-tofu /opt/lcars/tofu/ | grep -q '^drwxr-xr-x root/root'
}

@test "conffiles : /etc/lcars/lcars.bashrc est un conffile de lcars — garde au remove, retire au purge" {
  need_nfpm
  local d="$BATS_TEST_TMPDIR/ctl"; mkdir -p "$d"
  dpkg-deb -e "$(deb_of lcars)" "$d"
  [ "$(cat "$d/conffiles")" = "/etc/lcars/lcars.bashrc" ]
}

@test "lintian, s'il est la : tolere dir-or-file-in-opt (assume), rien d'autre en erreur" {
  need_nfpm
  command -v lintian >/dev/null 2>&1 || skip "lintian absent sur ce poste — la mesure se fera au banc (apt install lintian)"
  run lintian --suppress-tags dir-or-file-in-opt --no-tag-display-limit "$(deb_of lcars)"
  refute grep -qE '^E:' <<<"$output"
}

@test "deck-static : le client de console (pins de 62) est EMBARQUE par lcars — sans le tiroir prepare, le manque est DIT" {
  # le decor de ce fichier pose TOOLS/deck-static (trois fichiers) : lcars les porte
  grep -q '/opt/lcars/deck-static/xterm.js' "$OUT/lcars.paths"
  grep -q '/opt/lcars/deck-static/addon-fit.js' "$OUT/lcars.paths"
  grep -qE '^if \[\[ -n "\$TOOLS" && -d "\$TOOLS/deck-static" \]\]; then' "$BATS_TEST_DIRNAME/../../pkg/gen-contents.sh"
  grep -q 'client de console ABSENT du tiroir' "$BATS_TEST_DIRNAME/../../pkg/gen-contents.sh"
  grep -q 'emit_dir "$ROOT/deck-static" 0755' "$BATS_TEST_DIRNAME/../../pkg/gen-contents.sh"
  grep -q 'deck-static/\$(basename "\$_f")" 0644' "$BATS_TEST_DIRNAME/../../pkg/gen-contents.sh"
  # pack.sh prepare le tiroir AVANT gen-contents
  local pk="$BATS_TEST_DIRNAME/../../../pack.sh"
  local l_prep l_gen; l_prep="$(grep -n 'prep-deck-static.sh --tools' "$pk" | head -1 | cut -d: -f1)"; l_gen="$(grep -n 'gen-contents.sh --stage' "$pk" | head -1 | cut -d: -f1)"
  [ -n "$l_prep" ] && [ -n "$l_gen" ] && [ "$l_prep" -lt "$l_gen" ]
}
