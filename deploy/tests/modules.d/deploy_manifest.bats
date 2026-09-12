#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/deploy_manifest.bats
# AUTHOR: consultant
# STARDATE: 2026-07-30
# STATUS: bats tests for 60-deploy check — manifest-driven, source-independent

# shellcheck disable=SC2016

# shellcheck disable=SC1003,SC2020

load ../refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../.."
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/deploy/lib" "$ROOT/runtime/etc"
  # ⚠ `provision-lib.sh` SOURCE `docker-endpoint.sh` : le decor doit porter les DEUX, sinon
  # toute la suite tombe sur un « No such file » dont la cause est cette ligne de setup.
  cp "$SRC/lib/provision-lib.sh" "$ROOT/deploy/lib/"
  cp "$SRC/lib/docker-endpoint.sh" "$ROOT/deploy/lib/"
  cp "$SRC/modules.d/60-deploy.sh" "$BATS_TEST_TMPDIR/60-deploy.sh"

  cat > "$ROOT/runtime/etc/release.manifest" <<'EOF'
# test manifest
fleet         exec   link
bwrap_launch.sh  exec
bridge.py        noexec
EOF

  export PROV_PREFIX="$BATS_TEST_TMPDIR/prefix"
  export PROV_LINK_DIR="$BATS_TEST_TMPDIR/linkdir"
  export PROVISION_LIB="$ROOT/deploy/lib/provision-lib.sh"
  export PROVISION_MODULE=60-deploy
  # Le CANAL est a nous : ce decor EXECUTE 60-deploy, dont le dispatch lit /etc/lcars/channel.
  # Absent = « aucun », le module mesure comme aujourd'hui (MUR I21).
  export LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/etc/lcars/channel"

  # a "deployed" prefix: release marker + every manifest entry posed correctly
  mkdir -p "$PROV_PREFIX/rel/lcars_fleet/bin" "$PROV_PREFIX/bin" "$PROV_LINK_DIR"
  printf '#!/bin/sh\n' > "$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  chmod +x "$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  printf 'x\n' > "$PROV_PREFIX/bin/fleet";        chmod +x "$PROV_PREFIX/bin/fleet"
  printf 'x\n' > "$PROV_PREFIX/bin/bwrap_launch.sh"; chmod +x "$PROV_PREFIX/bin/bwrap_launch.sh"
  printf 'x\n' > "$PROV_PREFIX/bin/bridge.py"
  ln -s "$PROV_PREFIX/bin/fleet" "$PROV_LINK_DIR/fleet"
}

run_check() { run bash "$BATS_TEST_TMPDIR/60-deploy.sh" check; }

@test "manifest-driven check: fully posed prefix has zero bin/link drift" {
  run_check
  [[ "$output" == *"bin/fleet"* ]]
  [[ "$output" == *"bin/bridge.py"* ]]
  [[ "$output" == *"symlink $PROV_LINK_DIR/fleet"* ]]
  [[ "$output" != *"DRIFT 60-deploy: bin/"* ]]
  [[ "$output" != *"symlink vers"* ]]
}

@test "manifest-driven check: a missing exec entry drifts by name" {
  rm "$PROV_PREFIX/bin/bwrap_launch.sh"
  run_check
  [[ "$output" == *"DRIFT"* ]]
  [[ "$output" == *"bin/bwrap_launch.sh absent"* ]]
}

@test "manifest-driven check: a noexec entry only needs to be readable" {
  chmod -x "$PROV_PREFIX/bin/bridge.py"
  run_check
  [[ "$output" != *"bridge.py absent"* ]]
}

@test "manifest-driven check: a wrong link target drifts" {
  ln -sfn /somewhere/else "$PROV_LINK_DIR/fleet"
  run_check
  [[ "$output" == *"$PROV_LINK_DIR/fleet ≠ symlink vers"* ]]
}

@test "source-independence: check runs WITHOUT mix.exs (only etc/ ships in the image)" {
  # setup() never created mix.exs — a green-path check proves no source-tree dependency
  run_check
  [[ "$output" != *"introuvable"* ]]
}

@test "missing manifest is a probe ERROR (rc 2), not a silent pass" {
  rm "$BATS_TEST_TMPDIR/repo/runtime/etc/release.manifest"
  run_check
  [ "$status" -eq 2 ]
  [[ "$output" == *"manifest introuvable"* ]]
}


@test "le rail natif n'installe PLUS d'outillage de gate — l'install ne re-atteste pas la source (DI-07)" {
  MOD="$BATS_TEST_DIRNAME/../../modules.d/60-deploy.sh"
  [ -f "$MOD" ]
  local code; code="$(grep -vE '^\s*#' "$MOD")"
  refute grep -q 'GATE_PACKAGES' <<<"$code"
  refute grep -qE 'shellcheck|ruff' <<<"$code"
  grep -q 'LCARS_INSTALL_SKIP_GATE=1' <<<"$code"
  # et `procps`, qui vivait dans cette liste pour le gate, est un besoin RUNTIME : il a rejoint 10-packages
  PKG="$BATS_TEST_DIRNAME/../../modules.d/10-packages.sh"
  [[ " $(native_list 'PACKAGES' "$PKG") " == *" procps "* ]]
}


native_list() { # native_list <NOM_DU_TABLEAU> <fichier> — le contenu, commentaires retires
  awk -v n="$1" '
    !inside && $0 ~ "^[[:space:]]*" n "=\\(" { inside = 1; sub("^[[:space:]]*" n "=\\(", "") }
    inside {
      line = $0
      sub(/#.*/, "", line)
      if (line ~ /\)[[:space:]]*$/) { sub(/\)[[:space:]]*$/, "", line); print line; exit }
      print line
    }
  ' "$2" | tr '\n' ' '
}

@test "l'image ne pose par apt qu'un SOCLE — chaque paquet est sur le rail (10-packages), ou image-only et NOMME" {
  DOCKERFILE="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  PKG="$BATS_TEST_DIRNAME/../../modules.d/10-packages.sh"

  local image
  image="$(grep -vE '^\s*#' "$DOCKERFILE" \
    | sed -n '/apt-get install/,/rm -rf \/var\/lib\/apt/p' \
    | tr ' \\' '\n\n' \
    | grep -vE '^$|apt-get|install|-y|--no-install-recommends|DEBIAN_FRONTEND|&&|^rm$|-rf|/var/lib/apt' \
    | sort -u)"
  [ -n "$image" ] || { echo "aucune liste apt lue dans le Dockerfile — l'instrument est casse"; return 1; }
  [ "$(printf '%s\n' "$image" | grep -c .)" -le 8 ] || { echo "l'image pose $(printf '%s\n' "$image" | grep -c .) paquets : ce n'est plus un socle" >&2; printf '%s\n' "$image" >&2; return 1; }

  local native; native=" $(native_list 'PACKAGES' "$PKG") "
  # tini — PID 1 d'un conteneur, c'est systemd sur une machine ; openssh-server — la porte d'admin du conteneur, hors du poste
  local exempt=" tini openssh-server "
  local miss=""
  for p in $image; do
    [[ "$native" == *" $p "* || "$exempt" == *" $p "* ]] || miss+=" $p"
  done
  [ -z "$miss" ] || { echo "dans le socle de l'image mais ni sur le rail ni image-only nomme :$miss" >&2; return 1; }
  # et le rail, lui, ne demande AUCUN paquet image-only
  for p in tini openssh-server; do
    [[ "$native" != *" $p "* ]] || { echo "$p est sur le rail poste — il n'a rien a y faire" >&2; return 1; }
  done
}

@test "les exemptions sont NOMMEES dans le temoin, pas glissees dans une liste" {
  # Une exclusion sans motif ecrit devient l'endroit ou l'on range ce qu'on ne veut pas traiter.
  local f="$BATS_TEST_DIRNAME/deploy_manifest.bats"
  grep -q 'tini *— PID 1' "$f"
  grep -q 'openssh-server *— la porte' "$f"
}


@test "le rail POSTE fait TRAVERSER ses reglages a l'escalade sudo" {
  SH="$BATS_TEST_DIRNAME/../../workstation"
  [ -f "$SH" ]
  grep -q 'ESCALADE_ENV=(' "$SH"
  grep -q 'exec sudo "${env_args\[@\]}"' "$SH"
  for v in PROV_COLOR NO_COLOR PROV_VERBOSE; do
    grep -q "$v" "$SH" || { echo "reglage $v non transmis a travers sudo" >&2; false; }
  done
  # ET LA PORTE N'ESCALADE PLUS : sinon il y aurait deux listes, dont une que personne ne relit.
  local door="$BATS_TEST_DIRNAME/../../../install.sh"
  refute grep -q 'exec sudo' <<<"$(grep -vE '^\s*#' "$door")"
}


pkg_mod()    { echo "$BATS_TEST_DIRNAME/../../modules.d/10-packages.sh"; }
engine_mod() { echo "$BATS_TEST_DIRNAME/../../modules.d/12-docker-engine.sh"; }

@test "docker n'est PAS dans la liste des deux rails — il n'a rien a faire dans l'image" {
  run native_list 'PACKAGES' "$(pkg_mod)"
  [ -n "$output" ]
  [[ "$output" != *"docker"* ]]
}

@test "docker-ce vit dans 12-docker-engine, sur le substrat linux seul ; 10-packages n'en parle plus" {
  grep -q '^# APPLY-ON: linux$' "$(engine_mod)"
  grep -q '^# CHECK-ON: linux$' "$(engine_mod)"
  grep -q 'docker-ce' "$(engine_mod)"
  grep -q '^PACKAGES=(' "$(pkg_mod)"
  grep -vE '^\s*#' "$(pkg_mod)" | refute_out 'docker-ce|ensure_docker_repo|LINUX_PACKAGES'
}

@test "check et apply lisent la MEME liste — deux derivations repondraient differemment" {
  # `check` iterait sur `PACKAGES`, `apply` aussi : ajouter une liste conditionnelle a un seul des
  # deux ferait sonder autre chose que ce qu'on installe.
  grep -q 'done < <(effective_packages)' "$(pkg_mod)"
  grep -q 'mapfile -t pkgs < <(effective_packages)' "$(pkg_mod)"
}

@test "UN FAIT, DEUX RENDUS : le prefixe de la lib EGALE celui de l'installeur de release" {
  local lib="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  local inst="$BATS_TEST_DIRNAME/../../lib/deploy-release.sh"
  local from_lib from_inst
  from_lib="$(env -i PATH="$PATH" bash -c ". '$lib' >/dev/null 2>&1; printf '%s' \"\$PROV_PREFIX\"")"
  from_inst="$(grep -oE '\$\{LCARS_INSTALL_PREFIX:-[^}]+\}' "$inst" | head -1 | sed 's/.*:-//; s/}$//')"
  [ -n "$from_lib" ]
  [ -n "$from_inst" ]
  [ "$from_lib" = "$from_inst" ]
}

@test "UN FAIT, DEUX RENDUS : le repertoire de liens aussi" {
  # Meme classe, meme piege : `PROV_LINK_DIR` se dit « miroir de LCARS_INSTALL_LINK_DIR ».
  local lib="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  local inst="$BATS_TEST_DIRNAME/../../lib/deploy-release.sh"
  local from_lib from_inst
  from_lib="$(env -i PATH="$PATH" bash -c ". '$lib' >/dev/null 2>&1; printf '%s' \"\$PROV_LINK_DIR\"")"
  from_inst="$(grep -oE '\$\{LCARS_INSTALL_LINK_DIR:-[^}]+\}' "$inst" | head -1 | sed 's/.*:-//; s/}$//')"
  [ -n "$from_lib" ]
  [ -n "$from_inst" ]
  [ "$from_lib" = "$from_inst" ]
}

repo_sh() { # repo_sh <corps a jouer apres la source> — decor complet, machine jamais mesuree
  local head="$BATS_TEST_TMPDIR/repo-head.sh"
  sed '/^check() {/,$d' "$(engine_mod)" > "$head"
  run env PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh" \
          LCARS_DOCKER_KEYRING="$BATS_TEST_TMPDIR/keyrings/docker.asc" \
          LCARS_DOCKER_LIST="$BATS_TEST_TMPDIR/docker.list" \
      bash -c 'source "$1" >/dev/null 2>&1; shift; eval "$@"' _ "$head" "$1"
}

@test "depot docker : une distro que l'upstream ne publie pas est REFUSEE, et rien n'est pose" {
  repo_sh 'os_field() { case "$1" in ID) echo arch ;; VERSION_CODENAME) echo rolling ;; esac; }
           ensure_docker_repo'
  [ "$status" -ne 0 ]
  [[ "$output" == *"arch"* ]]
  [[ "$output" == *"ubuntu et debian"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/docker.list" ]
  [ ! -e "$BATS_TEST_TMPDIR/keyrings/docker.asc" ]
}

@test "depot docker : sans VERSION_CODENAME la suite est INDERIVABLE — on le dit, on ne devine pas" {
  repo_sh 'os_field() { case "$1" in ID) echo ubuntu ;; VERSION_CODENAME) echo "" ;; esac; }
           ensure_docker_repo'
  [ "$status" -ne 0 ]
  [[ "$output" == *"VERSION_CODENAME"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/docker.list" ]
}

@test "depot docker : une suite ABSENTE chez Docker refuse AVANT de poser quoi que ce soit" {
  # Le coeur du temoin : la sonde reseau passe AVANT la cle et la source. Un refus qui laisserait la
  # source derriere lui armerait la panne differee decrite en tete de section.
  repo_sh 'os_field() { case "$1" in ID) echo ubuntu ;; VERSION_CODENAME) echo suite-qui-nexiste-pas ;; esac; }
           curl() { return 22; }
           fetch_verify() { echo "FETCH NE DOIT PAS ETRE APPELE"; return 0; }
           ensure_docker_repo'
  [ "$status" -ne 0 ]
  [[ "$output" == *"suite-qui-nexiste-pas"* ]]
  [[ "$output" != *"FETCH NE DOIT PAS ETRE APPELE"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/docker.list" ]
  [ ! -e "$BATS_TEST_TMPDIR/keyrings/docker.asc" ]
}

@test "depot docker : la source est DERIVEE — id, codename et architecture, aucun litteral" {
  repo_sh 'os_field() { case "$1" in ID) echo debian ;; VERSION_CODENAME) echo trixie ;; esac; }
           curl() { return 0; }
           ensure_dir() { mkdir -p "$1"; }
           write_atomic() { mkdir -p "$(dirname "$1")"; cat > "$1"; }
           fetch_verify() { : > "$3"; }
           dpkg() { echo arm64; }
           run_quiet() { return 0; }
           ensure_docker_repo'
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/docker.list"
  [[ "$output" == *"https://download.docker.com/linux/debian trixie stable"* ]]
  [[ "$output" == *"arch=arm64"* ]]
  [[ "$output" == *"signed-by=$BATS_TEST_TMPDIR/keyrings/docker.asc"* ]]
}

@test "depot docker : REJOUER ne repose rien — la cle n'est pas re-telechargee" {
  local head="$BATS_TEST_TMPDIR/repo-head.sh"
  sed '/^check() {/,$d' "$(engine_mod)" > "$head"
  run env PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh" \
          LCARS_DOCKER_KEYRING="$BATS_TEST_TMPDIR/keyrings/docker.asc" \
          LCARS_DOCKER_LIST="$BATS_TEST_TMPDIR/docker.list" \
          LCARS_DOCKER_GPG_SHA256="$(printf '' | sha256sum | awk '{print $1}')" \
      bash -c 'source "$1" >/dev/null 2>&1
        os_field() { case "$1" in ID) echo ubuntu ;; VERSION_CODENAME) echo resolute ;; esac; }
        curl() { return 0; }
        ensure_dir() { mkdir -p "$1"; }
        write_atomic() { mkdir -p "$(dirname "$1")"; cat > "$1"; }
        # La cle posee est VIDE, et le pin ci-dessus est le sha256 du vide : la garde doit donc
        # reconnaitre au second tour que ce qui est en place EST ce qui etait attendu.
        fetch_verify() { echo "FETCH"; : > "$3"; }
        dpkg() { echo amd64; }
        run_quiet() { return 0; }
        ensure_docker_repo
        ensure_docker_repo' _ "$head"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^FETCH$' <<< "$output")" -eq 1 ]
}


repo_echec() { # repo_echec — le decor ou `apt-get update` REFUSE la source
  local head="$BATS_TEST_TMPDIR/repo-head.sh"
  sed '/^check() {/,$d' "$(engine_mod)" > "$head"
  run env PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh" \
          LCARS_DOCKER_KEYRING="$BATS_TEST_TMPDIR/keyrings/docker.asc" \
          LCARS_DOCKER_LIST="$BATS_TEST_TMPDIR/docker.list" \
          PROV_JOURNAL_ACC="$BATS_TEST_TMPDIR/install.journal" \
      bash -c 'source "$1" >/dev/null 2>&1
        os_field() { case "$1" in ID) echo debian ;; VERSION_CODENAME) echo trixie ;; esac; }
        curl() { return 0; }
        ensure_dir() { mkdir -p "$1"; }
        write_atomic() { mkdir -p "$(dirname "$1")"; cat > "$1"; }
        fetch_verify() { mkdir -p "$(dirname "$3")"; echo "CLE-LCARS" > "$3"; }
        dpkg() { echo amd64; }
        run_quiet() { return 1; }        # « apt-get update » refuse
        ensure_docker_repo' _ "$head"
}

@test "depot docker : un depot QUI EXISTAIT DEJA est RESTAURE sur echec, jamais efface" {
  mkdir -p "$BATS_TEST_TMPDIR/keyrings"
  echo "deb LE-DEPOT-DE-L-OPERATEUR" > "$BATS_TEST_TMPDIR/docker.list"
  echo "CLE-DE-L-OPERATEUR"          > "$BATS_TEST_TMPDIR/keyrings/docker.asc"

  repo_echec
  [ "$status" -ne 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/docker.list")" = "deb LE-DEPOT-DE-L-OPERATEUR" ]
  [ "$(cat "$BATS_TEST_TMPDIR/keyrings/docker.asc")" = "CLE-DE-L-OPERATEUR" ]
  [[ "$output" == *"restauré"* ]]
}

@test "depot docker : ce qui EXISTAIT DEJA est RESTAURE tel quel sur echec, jamais efface" {
  mkdir -p "$BATS_TEST_TMPDIR/keyrings"
  echo "deb LE-DEPOT-DE-L-OPERATEUR" > "$BATS_TEST_TMPDIR/docker.list"
  echo "CLE-DE-L-OPERATEUR"          > "$BATS_TEST_TMPDIR/keyrings/docker.asc"

  repo_echec
  # le depot de l'operateur est remis tel quel — un objet que LCARS n'a jamais pose ne s'efface pas
  [ "$(cat "$BATS_TEST_TMPDIR/docker.list")" = "deb LE-DEPOT-DE-L-OPERATEUR" ]
  [ "$(cat "$BATS_TEST_TMPDIR/keyrings/docker.asc")" = "CLE-DE-L-OPERATEUR" ]
  [[ "$output" == *"restauré"* ]]
}

@test "depot docker : ce que NOUS avons posé est bien retiré sur echec, et le refus le dit" {
  # Le sens qui manquait : sans lui, un module qui ne toucherait plus JAMAIS a rien passerait les
  # deux temoins ci-dessus en ayant cesse de nettoyer derriere lui.
  rm -f "$BATS_TEST_TMPDIR/docker.list" "$BATS_TEST_TMPDIR/keyrings/docker.asc"
  repo_echec
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/docker.list" ]
  [ ! -e "$BATS_TEST_TMPDIR/keyrings/docker.asc" ]
  [[ "$output" == *"n'était là avant"* ]]
}
