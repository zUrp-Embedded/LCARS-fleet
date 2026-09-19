#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/pack.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de deploy/pack.sh — le refus d'un arbre modifié, le kit et son nom, la porte de la version, le tiroir, ce que la publication dit du jeton

load refute
load support/minisign_double

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  SRC="$BATS_TEST_DIRNAME/../pack.sh"; [ -f "$SRC" ]
  RACINE_REELLE="$BATS_TEST_DIRNAME/../.."
  R="$BATS_TEST_TMPDIR/depot"
  mkdir -p "$R/deploy/lib" "$R/deploy/modules.d" "$R/deploy/docker" "$R/runtime/etc" "$R/runtime/bin" "$R/runtime/services" \
           "$R/assets/avatars" "$R/assets/favicon" "$R/assets/github.io"
  cp "$SRC" "$R/deploy/pack.sh"
  cp "$RACINE_REELLE"/deploy/lib/*.sh "$R/deploy/lib/"
  cp "$RACINE_REELLE/deploy/system.manifest" "$RACINE_REELLE/deploy/installer-constants.env" "$R/deploy/"
  cp "$RACINE_REELLE/install.sh" "$R/install.sh"
  cp "$RACINE_REELLE/runtime/etc/release.manifest" "$RACINE_REELLE/runtime/etc/fleet.env.template" "$R/runtime/etc/"
  local n
  while read -r n _; do [[ -n "$n" && "$n" != \#* ]] || continue; cp "$RACINE_REELLE/runtime/bin/$n" "$R/runtime/bin/"; done < "$R/runtime/etc/release.manifest"
  cp "$RACINE_REELLE"/runtime/bin/lcars-toolchain-converge "$RACINE_REELLE"/runtime/bin/lcars-authority-ask "$R/runtime/bin/"
  for n in $(sed -n 's/^PROV_HELPERS\(_DATA\)\{0,1\}=//p' "$R/deploy/installer-constants.env") lcars.bashrc; do
    cp "$RACINE_REELLE/runtime/services/$n" "$R/runtime/services/"
  done
  # ⚖ décision 3 : les FAITS de la machine et leur lecteur shell voyagent par PROV_EMBEDDED, donc
  # hors des deux listes ci-dessus — et `kit-verify` les exige, parce qu'un kit sans eux ne démarre
  # ni l'installeur ni un geste du produit.
  mkdir -p "$R/runtime/services/lib"
  cp "$RACINE_REELLE/runtime/etc/facts.env" "$R/runtime/etc/"
  cp "$RACINE_REELLE/runtime/services/lib/facts.sh" "$RACINE_REELLE/runtime/services/lib/uid-bounds.sh" "$R/runtime/services/lib/"
  printf 'png' > "$R/assets/avatars/a.png"; printf 'ico' > "$R/assets/favicon/f.ico"
  printf '{"name":"doc"}\n' > "$R/assets/github.io/package.json"
  cp "$RACINE_REELLE/deploy/docker/docker-compose.yml" "$R/deploy/docker/"; printf '{}\n' > "$R/deploy/docker/lcars-hardened-seccomp.json"
  printf 'dist\n_build\n' > "$R/.gitignore"
  export GATE_LOG="$BATS_TEST_TMPDIR/gate.log"
  printf '#!/usr/bin/env bash\necho gate >> "$GATE_LOG"\nexit "${STUB_GATE_RC:-0}"\n' > "$R/deploy/gate.sh"; chmod 0755 "$R/deploy/gate.sh"
  git -C "$R" init -q; git -C "$R" add -A; git -C "$R" -c user.email=t@t -c user.name=t commit -qm décor
  HEAD_SHA="$(git -C "$R" rev-parse --short HEAD)"; HEAD8="$(git -C "$R" rev-parse --short=8 HEAD)"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  printf '#!/usr/bin/env bash\nprintf 27\n' > "$BIN/erl"
  cat > "$BIN/mix" <<'EOF'
#!/usr/bin/env bash
echo "mix $*" >> "$CALLS"
if [[ "$1" == release ]]; then
  rel=_build/prod/rel/lcars_fleet
  mkdir -p "$rel/bin" "$rel/lib/lcars_fleet-0.9.0/priv/api"
  printf '#!/bin/sh\nexit 0\n' > "$rel/bin/lcars_fleet"; chmod 0755 "$rel/bin/lcars_fleet"
  printf 'sha=%s\n' "${STUB_MIX_SHA:-$(git rev-parse --short HEAD)}" > "$rel/lib/lcars_fleet-0.9.0/priv/api/build_info.txt"
fi
exit 0
EOF
  cat > "$BIN/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >> "$CALLS"
[[ "$1 $2" == "run build" ]] && { mkdir -p dist; printf '<html>doc</html>' > dist/index.html; }
exit 0
EOF
  printf '#!/usr/bin/env bash\necho "CURL $*" >> "$CALLS"; cat >/dev/null; printf 000\n' > "$BIN/curl"
  chmod 0755 "$BIN"/*
  export LCARS_PACK_DIR="$BATS_TEST_TMPDIR/packs"
  ARCH="$(uname -m)"
}

teardown() {
  [[ -z "${SRV_PID:-}" ]] || { kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true; }
}

pack() { run bash "$R/deploy/pack.sh" "$@"; }

forge_qui_repond() { # une forge Gitea doublée : le tag n'existe pas (ou FORGE_TAG_CODE), le commit est là, la release se crée
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
out=""; m=GET; url=""; prev=""; entete=""
for a in "$@"; do case "$prev" in -o) out="$a" ;; -X) m="$a" ;; -H) [[ "$a" != @- ]] || entete="$(cat)" ;; esac; [[ "$a" == http* ]] && url="$a"; prev="$a"; done
echo "CURL $m $url" >> "$CALLS"
# ce que curl reçoit du jeton : son entrée, son argv, son environnement
printf '%s\n' "$entete" >> "$CALLS.entetes"
printf '%s\n' "$*" >> "$CALLS.argv"
env >> "$CALLS.env"
case "$m $url" in
  "GET "*/releases/tags/*) printf '{}' > "$out"; printf '%s' "${FORGE_TAG_CODE:-404}" ;;
  "GET "*/git/commits/*)   printf '{}' > "$out"; printf 200 ;;
  "POST "*/releases)       printf '{"id":1}' > "$out"; printf 201 ;;
  "POST "*/assets*)        : > "$out"; printf 201 ;;
  "PATCH "*)               : > "$out"; printf 200 ;;
  *) printf 599 ;;
esac
EOF
  chmod 0755 "$BIN/curl"
}

docker_double() { # un daemon doublé qui journalise ; STUB_MANIFEST=absent|present|injoignable, STUB_PUSH_RC, STUB_ANONYME=public|prive, STUB_REGISTRE_REV
  cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
# anonyme : un magasin de configuration nommé qui ne porte aucun identifiant
anonyme=""; [[ -n "${DOCKER_CONFIG:-}" && ! -e "$DOCKER_CONFIG/config.json" ]] && anonyme=" (anonyme)"
echo "DOCKER $*$anonyme" >> "$CALLS"
case "$1" in
  version) exit 0 ;;
  # le tag local du registre porte la révision du kit (le tag d'une passe précédente) ; tiré, il porte celle du registre
  pull)    : > "$CALLS.tire" ;;
  image)   if [[ -e "$CALLS.tire" ]]; then printf '%s\n' "${STUB_REGISTRE_REV:-$(git rev-parse --short=8 HEAD)}"; else git rev-parse --short=8 HEAD; fi ;;
  login)   cat >/dev/null ;;
  manifest)
    if [[ -n "$anonyme" ]]; then
      [[ "${STUB_ANONYME:-public}" == public ]] && exit 0
      echo "unauthorized: authentication required" >&2; exit 1
    fi
    case "${STUB_MANIFEST:-absent}" in
      present) exit 0 ;;
      absent) echo "no such manifest: $3" >&2; exit 1 ;;
      *) echo "Get https://registre: dial tcp: i/o timeout" >&2; exit 1 ;;
    esac ;;
  push) exit "${STUB_PUSH_RC:-0}" ;;
  buildx) [[ -z "${STUB_SANS_BUILDX:-}" ]] || { echo "docker: 'buildx' is not a docker command." >&2; exit 1; } ;;
esac
exit 0
EOF
  chmod 0755 "$BIN/docker"
  export DOCKER_HOST=unix:///daemon-double
}

publier() { # publier — une publication complète vers une forge https doublée, le jeton de l'opérateur dans un fichier ; les doublures se règlent par l'environnement de l'appel
  JETON="jeton-du-fichier-de-l-operateur"
  printf '%s\n' "$JETON" > "$BATS_TEST_TMPDIR/jeton-operateur"
  run env LCARS_PACK_TAG=v9.9 LCARS_PACK_FORGE=https://forge.decor LCARS_PACK_OWNER=fleet \
    LCARS_PACK_TOKEN_FILE="$BATS_TEST_TMPDIR/jeton-operateur" bash "$R/deploy/pack.sh" --publish
}

@test "un arbre modifié est refusé avant tout — ni gate, ni release" {
  printf 'x\n' >> "$R/install.sh"
  pack --no-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"pack: ERREUR — arbre modifié"* ]]
  [ ! -s "$GATE_LOG" ]
  [ ! -s "$CALLS" ]
}

@test "un fichier non suivi est refusé avant tout : le gate le lirait, le kit ne l'emporterait pas" {
  printf 'defmodule Neuf do end\n' > "$R/runtime/neuf.ex"
  pack --no-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"fichiers non suivis"* ]]
  [ ! -s "$GATE_LOG" ]
}

@test "un tag mal formé est refusé avant le gate" {
  LCARS_PACK_TAG='v1/2' pack --no-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"tag « v1/2 »"* ]]
  [ ! -s "$GATE_LOG" ]
}

@test "un tag qui nomme une tête (main, master, latest, une branche du dépôt) est refusé avant le gate : le compose du kit ne rafraîchirait jamais son image" {
  local t
  git -C "$R" branch release-courante
  for t in main master latest HEAD release-courante; do
    : > "$GATE_LOG"
    LCARS_PACK_TAG="$t" pack --no-image
    [ "$status" -eq 1 ] || { echo "$t : $output"; return 1; }
    [[ "$output" == *"tag « $t » : c'est un nom de tête"*"pull_policy: missing"*"LCARS_PACK_TAG=<version>"* ]]
    [ ! -s "$GATE_LOG" ]
  done
  # un tag git posé sur HEAD sous un nom de branche est refusé de même
  git -C "$R" tag release-courante
  pack --no-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"tag « release-courante » : c'est un nom de tête"* ]]
  [ ! -s "$GATE_LOG" ]
  # une version passe le refus et atteint le gate
  git -C "$R" tag -d release-courante >/dev/null
  STUB_GATE_RC=1 LCARS_PACK_TAG=v9.7 pack --no-image
  [ -s "$GATE_LOG" ]
}

@test "lancé en root : refus avant le gate" {
  run unshare -Ur bash "$R/deploy/pack.sh" --no-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"ne se lance pas en root"* ]]
  [ ! -s "$GATE_LOG" ]
}

@test "origin https avec identifiants et suffixe .git : la base de l'installeur n'emporte ni l'un ni l'autre" {
  git -C "$R" remote add origin https://utilisateur:jeton-secret@forge.example/Flotte/Depot.git
  LCARS_PACK_TAG=v9.9 pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^DOOR_BASE="https://forge.example/Flotte/Depot/releases/download/v9.9" ' "$LCARS_PACK_DIR/dist/v9.9/install.sh"
  refute grep -q 'jeton-secret' "$LCARS_PACK_DIR/dist/v9.9/install.sh"
  [[ "$output" != *"jeton-secret"* ]]
}

@test "origin en http : --publish est refusé avant le gate, et un tiroir local le dit sans refuser" {
  git -C "$R" remote add origin http://10.42.0.118:80/fleet/lcars
  LCARS_PACK_TAG=v9.9 pack --no-image --publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"n'est pas en https"*"LCARS_PACK_FORGE=https://"* ]]
  [ ! -s "$GATE_LOG" ]
  LCARS_PACK_TAG=v9.9 pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"base de l'installeur en clair"*"LCARS_DOOR_INSECURE_HTTP=1"* ]]
}

@test "LCARS_DOOR_BASE avec --publish est refusée : l'installeur publié chercherait son kit ailleurs" {
  LCARS_DOOR_BASE=http://banc.local:28090 LCARS_PACK_TAG=v9.9 LCARS_PACK_FORGE=https://forge.decor LCARS_PACK_OWNER=fleet pack --no-image --publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"LCARS_DOOR_BASE est posée"* ]]
  [ ! -s "$GATE_LOG" ]
}

@test "un second pack du même tag vide le tiroir de la version : aucun artefact d'avant n'y reste" {
  LCARS_PACK_TAG=v9.9 pack --no-image
  [ "$status" -eq 0 ]
  printf 'vieux\n' > "$LCARS_PACK_DIR/dist/v9.9/lcars-fleet-v9.9-otp26-$ARCH.tar.gz"
  LCARS_PACK_TAG=v9.9 pack --no-image
  [ "$status" -eq 0 ]
  [ ! -e "$LCARS_PACK_DIR/dist/v9.9/lcars-fleet-v9.9-otp26-$ARCH.tar.gz" ]
  refute grep -q 'otp26' "$LCARS_PACK_DIR/dist/v9.9/install.sh"
}

@test "--publish : une release du tag déjà là est vue avant l'image — rien n'est poussé" {
  forge_qui_repond; docker_double
  FORGE_TAG_CODE=200 publier
  [ "$status" -eq 1 ]
  [[ "$output" == *"existe déjà"* ]]
  refute grep -q '^DOCKER push' "$CALLS"
  refute grep -q '^CURL POST' "$CALLS"
}

@test "--publish : un registre qui ne dit pas si l'image existe est un refus, et le jeton est retiré du daemon" {
  forge_qui_repond; docker_double
  STUB_MANIFEST=injoignable publier
  [ "$status" -eq 1 ]
  [[ "$output" == *"le registre ne dit pas si"* ]]
  refute grep -q '^DOCKER push' "$CALLS"
  grep -q '^DOCKER logout forge.decor' "$CALLS"
}

@test "--publish : un push refusé laisse la release non créée, et le jeton est retiré du daemon" {
  forge_qui_repond; docker_double
  STUB_PUSH_RC=1 publier
  [ "$status" -eq 1 ]
  [[ "$output" == *"push de forge.decor/fleet/lcars-fleet:v9.9 refusé"* ]]
  refute grep -q '^CURL POST' "$CALLS"
  grep -q '^DOCKER logout forge.decor' "$CALLS"
}

@test "--publish complet : l'image poussée puis la release créée sur le commit, le jeton jamais imprimé" {
  forge_qui_repond; docker_double
  publier
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^DOCKER push forge.decor/fleet/lcars-fleet:v9.9$' "$CALLS"
  local l_push l_post
  l_push="$(grep -n '^DOCKER push' "$CALLS" | cut -d: -f1)"; l_post="$(grep -n '^CURL POST .*/releases$' "$CALLS" | cut -d: -f1)"
  [ "$l_push" -lt "$l_post" ]
  [[ "$output" != *"$JETON"* ]]
  grep -q '^DOOR_IMAGE="forge.decor/fleet/lcars-fleet:v9.9"' "$LCARS_PACK_DIR/dist/v9.9/install.sh"
  # l'image se bâtit depuis le kit posé dans l'étage : son Dockerfile, et l'arbre du kit pour contexte
  local build; build="$(grep '^DOCKER build ' "$CALLS")"
  [[ "$build" =~ ^DOCKER\ build\ -f\ (/[^\ ]+)/lcars_install/deploy/docker/Dockerfile\ .*\ ([^\ ]+)$ ]] || { echo "$build"; return 1; }
  [ "${BASH_REMATCH[2]}" = "${BASH_REMATCH[1]}/lcars_install" ] || { echo "contexte ${BASH_REMATCH[2]}, étage ${BASH_REMATCH[1]}"; return 1; }
  [[ "$build" == *" --build-arg GIT_SHA=$HEAD8 "*" -t lcars-fleet:v9.9 -t lcars-fleet:local "* ]]
  # ni provenance ni sbom : l'image publiée est un manifeste simple, pas un index OCI
  [[ "$build" == *" --provenance=false --sbom=false "* ]]
  # le compose du kit et celui du tiroir nomment l'image publiée de la version, celui du checkout reste local
  local x="$BATS_TEST_TMPDIR/x"; mkdir -p "$x"; tar -xzf "$LCARS_PACK_DIR/lcars-fleet-v9.9-otp27-$ARCH.tar.gz" -C "$x"
  grep -qF 'image: "${LCARS_IMAGE:-forge.decor/fleet/lcars-fleet:v9.9}"' "$x/lcars_install/deploy/docker/docker-compose.yml"
  grep -qF 'image: "${LCARS_IMAGE:-forge.decor/fleet/lcars-fleet:v9.9}"' "$LCARS_PACK_DIR/dist/v9.9/docker-compose.yml"
  grep -qF 'image: "${LCARS_IMAGE:-lcars-fleet:local}"' "$R/deploy/docker/docker-compose.yml"
}

@test "sans --publish ni forge, le compose du kit nomme l'image bâtie de la version ; sans image, il garde l'image locale" {
  docker_double
  git -C "$R" remote remove origin 2>/dev/null || true
  LCARS_PACK_TAG=v9.9 pack
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qF 'image: "${LCARS_IMAGE:-lcars-fleet:v9.9}"' "$LCARS_PACK_DIR/dist/v9.9/docker-compose.yml"
  LCARS_PACK_TAG=v9.8 pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qF 'image: "${LCARS_IMAGE:-lcars-fleet:local}"' "$LCARS_PACK_DIR/dist/v9.8/docker-compose.yml"
}

@test "--publish rejoué : l'image du tag déjà publiée à la révision du kit est reprise sans push, tirée sans identifiants, et la release suit" {
  forge_qui_repond; docker_double
  STUB_MANIFEST=present publier
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute grep -q '^DOCKER push' "$CALLS"
  grep -q '^DOCKER pull -q forge.decor/fleet/lcars-fleet:v9.9$' "$CALLS"
  [[ "$output" == *"image déjà publiée à la révision $HEAD8 : forge.decor/fleet/lcars-fleet:v9.9 est reprise, rien n'est poussé"* ]]
  local l_anon l_post
  l_anon="$(grep -n '^DOCKER manifest inspect .* (anonyme)$' "$CALLS" | cut -d: -f1)"
  l_post="$(grep -n '^CURL POST .*/releases$' "$CALLS" | cut -d: -f1)"
  [ -n "$l_anon" ]
  [ "$l_anon" -lt "$l_post" ]
}

@test "--publish : une image du tag déjà publiée à une autre révision est un refus qui nomme les deux révisions, sans push ni release" {
  forge_qui_repond; docker_double
  STUB_MANIFEST=present STUB_REGISTRE_REV=0badc0de publier
  [ "$status" -eq 1 ]
  [[ "$output" == *"forge.decor/fleet/lcars-fleet:v9.9 existe déjà, à la révision « 0badc0de » et non $HEAD8"* ]]
  refute grep -q '^DOCKER push' "$CALLS"
  refute grep -q '^CURL POST' "$CALLS"
  grep -q '^DOCKER logout forge.decor' "$CALLS"
}

@test "--help rend l'usage, les prérequis et les codes de sortie, sans rien jouer" {
  pack --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy/pack.sh --publish"*"PRÉ-REQUIS"*"bats et shellcheck"*"EXIT"* ]]
  [ ! -s "$GATE_LOG" ]
  [ ! -s "$CALLS" ]
}

@test "--publish : l'image poussée est tirée sans identifiants avant la release — privée, la release n'est pas créée et le geste est dit ; publique, la release suit" {
  forge_qui_repond; docker_double
  STUB_ANONYME=prive publier
  [ "$status" -eq 1 ]
  grep -q '^DOCKER push forge.decor/fleet/lcars-fleet:v9.9$' "$CALLS"
  grep -q '^DOCKER manifest inspect forge.decor/fleet/lcars-fleet:v9.9 (anonyme)$' "$CALLS"
  [[ "$output" == *"un tirage anonyme est refusé (unauthorized: authentication required)"*"la release n'est pas créée"* ]]
  [[ "$output" == *"sur GHCR, un paquet est privé à sa première publication, il se passe public dans ses réglages"* ]]
  refute grep -q '^CURL POST' "$CALLS"
  grep -q '^DOCKER logout forge.decor' "$CALLS"
  : > "$CALLS"
  STUB_ANONYME=public publier
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local l_push l_anon l_post
  l_push="$(grep -n '^DOCKER push' "$CALLS" | cut -d: -f1)"
  l_anon="$(grep -n '^DOCKER manifest inspect .* (anonyme)$' "$CALLS" | cut -d: -f1)"
  l_post="$(grep -n '^CURL POST .*/releases$' "$CALLS" | cut -d: -f1)"
  [ "$l_push" -lt "$l_anon" ]
  [ "$l_anon" -lt "$l_post" ]
  [[ "$output" == *"image tirable sans identifiants : forge.decor/fleet/lcars-fleet:v9.9"* ]]
}

@test "--publish : chaque appel à la forge reçoit le jeton par l'entrée de curl, le registre par celle de docker login ; ni argv ni environnement" {
  forge_qui_repond; docker_double
  sed -i 's/^  login)   cat >\/dev\/null ;;$/  login)   cat >> "$CALLS.login" ;;/' "$BIN/docker"
  publier
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c '^CURL' "$CALLS")" -gt 0 ]
  [ "$(grep -cx "Authorization: token $JETON" "$CALLS.entetes")" -eq "$(grep -c '^CURL' "$CALLS")" ]
  [ "$(cat "$CALLS.login")" = "$JETON" ]
  refute grep -q "$JETON" "$CALLS.argv"
  refute grep -q "$JETON" "$CALLS.env"
  refute grep -q "$JETON" "$CALLS"
}

@test "--publish : un jeton donné par l'environnement est refusé avant le gate, et le refus nomme le fichier qui le remplace" {
  printf '#!/usr/bin/env bash\nenv >> "$CALLS.env-npm"\n' > "$BIN/npm"
  LCARS_PACK_TOKEN=jeton-par-environnement LCARS_PACK_TAG=v9.9 LCARS_PACK_FORGE=https://forge.decor LCARS_PACK_OWNER=fleet pack --no-image --publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"LCARS_PACK_TOKEN n'est pas lu"*"LCARS_PACK_TOKEN_FILE=<fichier>"* ]]
  [ ! -s "$GATE_LOG" ]
  [ ! -e "$CALLS.env-npm" ]
}

@test "l'image demandée sans buildx sur le daemon : refus avant le gate qui le nomme ; --no-image passe" {
  docker_double
  STUB_SANS_BUILDX=1 LCARS_PACK_TAG=v9.9 pack
  [ "$status" -eq 1 ]
  [[ "$output" == *"docker buildx absent"*"--no-image"* ]]
  [ ! -s "$GATE_LOG" ]
  refute grep -q '^DOCKER build ' "$CALLS"
  STUB_SANS_BUILDX=1 LCARS_PACK_TAG=v9.9 pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "le tiroir produit par pack, servi, est retrouvé par son propre installeur : kit nommé, téléchargé, sha256 vérifié" {
  mkdir -p "$LCARS_PACK_DIR/dist"
  local port; port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  python3 -m http.server --bind 127.0.0.1 "$port" --directory "$LCARS_PACK_DIR/dist" >/dev/null 2>&1 3>&- &
  SRV_PID=$!
  LCARS_DOOR_BASE="http://127.0.0.1:$port/v9.9" LCARS_PACK_TAG=v9.9 pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run env HOME="$BATS_TEST_TMPDIR/home" LCARS_DOOR_INSECURE_HTTP=1 PATH=/usr/bin:/bin \
    bash -c "cat '$LCARS_PACK_DIR/dist/v9.9/install.sh' | bash -s -- --workstation"
  [[ "$output" == *"lcars-fleet-v9.9-otp27-$ARCH.tar.gz : téléchargé, sha256 vérifié"* ]]
}

@test "clés minisign : le kit est signé dans le tiroir de la version, et son installeur, servi, vérifie la signature avec la clé qu'il porte" {
  minisign_double "$BATS_TEST_TMPDIR/minisign-bin"
  minisign_cle "$BATS_TEST_TMPDIR/cle-secrete" RWQclepack
  mkdir -p "$LCARS_PACK_DIR/dist/v9.9"
  printf 'untrusted comment: signature doublée\nRWQancienne 0\n' > "$LCARS_PACK_DIR/dist/v9.9/lcars-fleet-v9.9-otp27-$ARCH.tar.gz.minisig"
  local port; port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  python3 -m http.server --bind 127.0.0.1 "$port" --directory "$LCARS_PACK_DIR/dist" >/dev/null 2>&1 3>&- &
  SRV_PID=$!
  PATH="$BATS_TEST_TMPDIR/minisign-bin:$PATH" LCARS_MINISIGN_PUBKEY=RWQclepack LCARS_MINISIGN_SECKEY="$BATS_TEST_TMPDIR/cle-secrete" \
    LCARS_DOOR_BASE="http://127.0.0.1:$port/v9.9" LCARS_PACK_TAG=v9.9 pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local kit="$LCARS_PACK_DIR/dist/v9.9/lcars-fleet-v9.9-otp27-$ARCH.tar.gz"
  [[ "$output" == *"pack: kit signé : $kit.minisig"* ]]
  PATH="$BATS_TEST_TMPDIR/minisign-bin:$PATH" minisign -Vq -P RWQclepack -m "$kit"
  grep -qE '^MINISIGN_PUBKEY="RWQclepack" +# @@DOOR_PUBKEY@@' "$LCARS_PACK_DIR/dist/v9.9/install.sh"
  run env HOME="$BATS_TEST_TMPDIR/home" LCARS_DOOR_INSECURE_HTTP=1 PATH="$BATS_TEST_TMPDIR/minisign-bin:/usr/bin:/bin" \
    bash -c "cat '$LCARS_PACK_DIR/dist/v9.9/install.sh' | bash -s -- --workstation"
  [[ "$output" == *"lcars-fleet-v9.9-otp27-$ARCH.tar.gz : signature vérifiée (minisign)"* ]]
}

@test "clés minisign : l'une sans l'autre, une clé secrète illisible ou minisign absent sont refusés avant le gate" {
  LCARS_MINISIGN_PUBKEY=RWQclepack LCARS_PACK_TAG=v9.9 pack --no-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"LCARS_MINISIGN_PUBKEY et LCARS_MINISIGN_SECKEY vont ensemble"* ]]
  LCARS_MINISIGN_SECKEY="$BATS_TEST_TMPDIR/cle-secrete" LCARS_PACK_TAG=v9.9 pack --no-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"vont ensemble"* ]]
  LCARS_MINISIGN_PUBKEY=RWQclepack LCARS_MINISIGN_SECKEY="$BATS_TEST_TMPDIR/absente" LCARS_PACK_TAG=v9.9 pack --no-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"clé secrète minisign illisible : $BATS_TEST_TMPDIR/absente"* ]]
  minisign_cle "$BATS_TEST_TMPDIR/cle-secrete" RWQclepack
  run env PATH="$BIN:/usr/bin:/bin" LCARS_MINISIGN_PUBKEY=RWQclepack LCARS_MINISIGN_SECKEY="$BATS_TEST_TMPDIR/cle-secrete" LCARS_PACK_TAG=v9.9 \
    bash "$R/deploy/pack.sh" --no-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"minisign absent"* ]]
  [ ! -s "$GATE_LOG" ]
}

@test "une option inconnue est refusée en se nommant" {
  pack --no-push
  [ "$status" -eq 1 ]
  [[ "$output" == *"option inconnue: --no-push"* ]]
}

@test "le kit porte le tag dans son nom, la révision à sa racine, la release et la doc bâties, et le tiroir de la version porte la porte qui le retrouve" {
  LCARS_PACK_TAG=v9.9 pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local tar="$LCARS_PACK_DIR/lcars-fleet-v9.9-otp27-$ARCH.tar.gz"
  [ -s "$tar" ]
  [ "$(cut -d' ' -f1 < "$tar.sha256")" = "$(sha256sum "$tar" | cut -d' ' -f1)" ]
  local x="$BATS_TEST_TMPDIR/x"; mkdir -p "$x"; tar -xzf "$tar" -C "$x"
  [ "$(cat "$x/lcars_install/.source-revision")" = "$HEAD8" ]
  [ -x "$x/lcars_install/runtime/_build/prod/rel/lcars_fleet/bin/lcars_fleet" ]
  [ -s "$x/lcars_install/assets/github.io/dist/index.html" ]
  [ -f "$x/lcars_install/deploy/pack.sh" ]
  [ ! -e "$x/lcars_install/runtime/_build/prod/rel/lcars_fleet/lib/lcars_fleet-0.1.0" ]
  local dist="$LCARS_PACK_DIR/dist/v9.9"
  [ "$(stat -c %i "$dist/lcars-fleet-v9.9-otp27-$ARCH.tar.gz")" = "$(stat -c %i "$tar")" ]
  [ -f "$dist/docker-compose.yml" ]
  [ -f "$dist/lcars-hardened-seccomp.json" ]
  [ "$(bash "$dist/install.sh" --version)" = v9.9 ]
  [ "$(cut -d' ' -f1 < "$dist/install.sh.sha256")" = "$(sha256sum "$dist/install.sh" | cut -d' ' -f1)" ]
  grep -q "  lcars-fleet-v9.9-otp27-$ARCH.tar.gz\$" "$dist/install.sh"
  grep -q "^DOOR_BASE=\"https://forge.invalid/lcars/lcars-fleet/releases/download/v9.9\"" "$dist/install.sh"
  grep -q '^mix deps.get$' "$CALLS"
  grep -q '^mix release$' "$CALLS"
  [[ "$output" == *"pack: --no-image : pas d'image"*"pack: sans --publish : le tar et l'installeur restent dans $dist"* ]]
}

@test "le tiroir de la version porte les constantes de l'installeur, que son compose lit" {
  LCARS_PACK_TAG=v9.9 pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  cmp "$R/deploy/installer-constants.env" "$LCARS_PACK_DIR/dist/v9.9/installer-constants.env"
}

@test "sans tag, la version est <AAAA-MM-JJ>-<révision du kit> et le kit se nomme d'elle" {
  pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local tars; tars="$(find "$LCARS_PACK_DIR" -maxdepth 1 -name "lcars-fleet-*-$HEAD8-otp27-$ARCH.tar.gz")"
  [ -n "$tars" ]
  [[ "$(basename "$tars")" =~ ^lcars-fleet-[0-9]{4}-[0-9]{2}-[0-9]{2}-$HEAD8-otp27-$ARCH\.tar\.gz$ ]]
  [ -d "$LCARS_PACK_DIR/dist/$(basename "$tars" | sed "s/^lcars-fleet-//; s/-otp27-$ARCH.tar.gz$//")" ]
}

@test "le tiroir : à côté du checkout par défaut, LCARS_PACK_DIR sinon, normalisé et absolu" {
  unset LCARS_PACK_DIR
  LCARS_PACK_TAG=v1 pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -s "$BATS_TEST_TMPDIR/lcars-packs/lcars-fleet-v1-otp27-$ARCH.tar.gz" ]
  LCARS_PACK_DIR="$BATS_TEST_TMPDIR/depot/../ailleurs/./tiroir" LCARS_PACK_TAG=v2 pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -s "$BATS_TEST_TMPDIR/ailleurs/tiroir/lcars-fleet-v2-otp27-$ARCH.tar.gz" ]
  [[ "$output" == *"pack: paquet : $BATS_TEST_TMPDIR/ailleurs/tiroir/lcars-fleet-v2-otp27-$ARCH.tar.gz"* ]]
}

@test "gate de l'installeur rouge : rien n'est empaqueté, la release n'est pas bâtie" {
  STUB_GATE_RC=1 pack --no-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"pack: ERREUR — gate de l'installeur rouge — rien n'est empaqueté"* ]]
  refute grep -q '^mix release' "$CALLS"
  [ ! -e "$LCARS_PACK_DIR" ]
}

@test "une release dont le tampon n'est pas HEAD n'est pas empaquetée ; l'abréviation courte de HEAD passe" {
  STUB_MIX_SHA=deadbee pack --no-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"le tampon de la release dit « deadbee », HEAD est $HEAD8"* ]]
  [ ! -e "$LCARS_PACK_DIR" ]
  STUB_MIX_SHA="$HEAD_SHA" pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"release attestée : build $HEAD_SHA"* ]]
}

@test "--publish : sans fichier de jeton, ou un fichier vide, refus qui le nomme ; avec un jeton, son état est dit et jamais sa valeur" {
  LCARS_PACK_TAG=v9.9 LCARS_PACK_FORGE=https://forge.decor LCARS_PACK_OWNER=fleet pack --no-image --publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"pack: ERREUR — --publish : aucun jeton — LCARS_PACK_TOKEN_FILE=<fichier>"* ]]
  refute grep -q '^CURL' "$CALLS"
  : > "$BATS_TEST_TMPDIR/vide"
  LCARS_PACK_TOKEN_FILE="$BATS_TEST_TMPDIR/vide" LCARS_PACK_TAG=v9.9 LCARS_PACK_FORGE=https://forge.decor LCARS_PACK_OWNER=fleet pack --no-image --publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun jeton"* ]]
  local sentinelle="s3cr3t-de-forge-a-ne-jamais-imprimer"
  printf '%s\n' "$sentinelle" > "$BATS_TEST_TMPDIR/jeton"
  : > "$CALLS"
  LCARS_PACK_TAG=v9.9 LCARS_PACK_FORGE=https://forge.decor LCARS_PACK_OWNER=fleet LCARS_PACK_TOKEN_FILE="$BATS_TEST_TMPDIR/jeton" pack --no-image --publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"jeton trouvé"*"publication refusée avant tout envoi"* ]]
  [[ "$output" != *"$sentinelle"* ]]
  refute grep -q "$sentinelle" "$CALLS"
}

@test "--publish : origin non http et rien de posé — refus qui nomme les variables" {
  LCARS_PACK_TAG=v9.9 pack --no-image --publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"--publish : forge ou owner indéterminables"*"LCARS_PACK_FORGE et LCARS_PACK_OWNER"* ]]
}

# bats test_tags=structure
@test "aucun secret ni chemin de machine n'est écrit dans le lanceur" {
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -qE '[0-9a-f]{40}' <<<"$code"
  refute grep -qE '/home/commons|/local/LCARS|/opt/lcars|/usr/share/lcars' <<<"$code"
}
