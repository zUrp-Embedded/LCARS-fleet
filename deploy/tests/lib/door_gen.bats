#!/usr/bin/env bats
# SOURCE: deploy/tests/lib/door_gen.bats
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: bats tests for deploy/lib/door-gen.sh — la porte d'une version : constantes remplies, table complete, sha juste
#
# CE QUI EST EN JEU. La porte d'une release porte EN DUR les sha256 de SES artefacts (curl_bash_2026
# § 07.2) : une table qui en oublie un laisse la porte refuser un artefact legitime — ou, pire, un
# generateur qui recopie mal une constante tend la table de personne. Ces temoins mesurent le
# generateur sur un tiroir factice : ce qu'il ecrit, ce qu'il ecarte, ce qu'il refuse.
#
# ⚠ SC2016 : ces temoins LISENT du code ; leurs motifs portent des `$VAR` qui doivent atteindre l'outil.
# shellcheck disable=SC2016

load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  GEN="$BATS_TEST_DIRNAME/../../lib/door-gen.sh"
  TEMPLATE="$BATS_TEST_DIRNAME/../../../install.sh"
  [ -f "$GEN" ] && [ -f "$TEMPLATE" ]
  DIST="$BATS_TEST_TMPDIR/dist"; mkdir -p "$DIST"
  printf 'kit\n'  > "$DIST/lcars-fleet-0.9.0-otp27-x86_64.tar.gz"
  printf 'deb1\n' > "$DIST/lcars_0.9.0_amd64.deb"
  printf 'deb2\n' > "$DIST/lcars-workstation_0.9.0_amd64.deb"
  # les derives : ecartes de la table, jamais des artefacts
  printf 'x  y\n' > "$DIST/lcars_0.9.0_amd64.deb.sha256"
  printf 'sig\n'  > "$DIST/lcars_0.9.0_amd64.deb.minisig"
}

gen() { run env LCARS_MINISIGN_PUBKEY="${PUB-RWQcle}" bash "$GEN" 0.9.0 https://forge.test/o/r/releases/download/0.9.0 "$DIST"; }
sums_of() { # sums_of <porte> -> la table, telle que la porte la rend
  # ⚠ UN SAUT DE LIGNE, PAS UN `;` : la derniere ligne de la fonction porte un commentaire (le
  # marqueur), et `}  # …; sums` appellerait sums DANS le commentaire — c'est-a-dire jamais.
  bash -c "$(sed -n '/^sums() {/,/^}/p' "$1")"$'\nsums'
}

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  run head -8 "$GEN"
  [[ "$output" == *"SOURCE:"* ]]; [[ "$output" == *"AUTHOR:"* ]]; [[ "$output" == *"STARDATE:"* ]]; [[ "$output" == *"STATUS:"* ]]
}

@test "il est EXECUTABLE dans l index git" {
  run git -C "$BATS_TEST_DIRNAME/../../.." ls-files -s deploy/lib/door-gen.sh
  [ "$status" -eq 0 ]
  [[ "$output" == 100755* ]]
}

@test "la TABLE couvre TOUS les artefacts du tiroir, avec leur sha256 juste — et rien d'autre" {
  gen; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$DIST/install.sh" ]
  local table; table="$(sums_of "$DIST/install.sh")"
  # chaque artefact y est, et sa somme est celle du fichier (sha256sum -c relit la table)
  ( cd "$DIST" && printf '%s\n' "$table" | sha256sum -c --quiet --strict )
  [ "$(printf '%s\n' "$table" | grep -c .)" -eq 3 ]
  local a; for a in lcars-fleet-0.9.0-otp27-x86_64.tar.gz lcars_0.9.0_amd64.deb lcars-workstation_0.9.0_amd64.deb; do
    [ "$(grep -c "  $a\$" <<<"$table")" -eq 1 ] || { echo "$a manque a la table"; return 1; }
  done
  # les derives et la porte elle-meme n'y sont PAS
  refute_out 'sha256|minisig|install\.sh' <<<"$table"
}

@test "les CONSTANTES sont remplies : --version dit le tag (pipee), BASE et la cle sont ecrites sur leurs lignes marquees" {
  gen; [ "$status" -eq 0 ]
  local porte="$DIST/install.sh"
  run bash -c "cat '$porte' | bash -s -- --version"
  [ "$output" = "0.9.0" ]
  grep -qE '^DOOR_BASE="https://forge\.test/o/r/releases/download/0\.9\.0" +# @@DOOR_BASE@@' "$porte"
  grep -qE '^MINISIGN_PUBKEY="RWQcle" +# @@DOOR_PUBKEY@@' "$porte"
  grep -qE '^LCARS_DOOR_VERSION="0\.9\.0" +# @@DOOR_VERSION@@' "$porte"
  # chaque marqueur survit, une fois : la porte generee reste un gabarit lisible
  local m; for m in DOOR_VERSION DOOR_BASE DOOR_PUBKEY DOOR_SUMS_BEGIN DOOR_SUMS_END; do
    [ "$(grep -c "@@$m@@" "$porte")" -eq 1 ]
  done
  [ -x "$porte" ]
}

@test "install.sh.sha256 est JUSTE — c'est ce que quelqu'un compare a ce qui lui est servi (§ 07.8)" {
  gen; [ "$status" -eq 0 ]
  [ -f "$DIST/install.sh.sha256" ]
  ( cd "$DIST" && sha256sum -c --quiet --strict install.sh.sha256 )
  [[ "$output" == *"sha256 de la porte : $(cut -d' ' -f1 < "$DIST/install.sh.sha256")"* ]]
  # regenerer change la porte ? non : meme entree, meme sortie, meme sha (reproductible)
  local avant; avant="$(cat "$DIST/install.sh.sha256")"
  gen; [ "$status" -eq 0 ]
  [ "$(cat "$DIST/install.sh.sha256")" = "$avant" ]
}

@test "SANS cle publique : la porte est generee AVEC une cle vide, et le generateur le DIT — jamais en silence" {
  PUB="" gen; [ "$status" -eq 0 ]
  [[ "$output" == *"AUCUNE cle publique"*"NON verifiee"* ]]
  grep -qE '^MINISIGN_PUBKEY="" +# @@DOOR_PUBKEY@@' "$DIST/install.sh"
  # un minisign.pub dans le tiroir suffit : sa seconde ligne est la cle
  printf 'untrusted comment: minisign public key\nRWQdepuisfichier\n' > "$DIST/minisign.pub"
  PUB="" gen; [ "$status" -eq 0 ]
  grep -qE '^MINISIGN_PUBKEY="RWQdepuisfichier"' "$DIST/install.sh"
  refute_out 'AUCUNE cle' <<<"$output"
  # et minisign.pub n'entre pas dans la table
  refute_out 'minisign\.pub' <<<"$(sums_of "$DIST/install.sh")"
}

@test "REFUS : un tiroir vide, un gabarit sans marqueur, un tag ou une base mal formes — rien n'est ecrit" {
  rm -f "$DIST"/*
  gen; [ "$status" -eq 1 ]; [[ "$output" == *"aucun artefact"* ]]; [ ! -f "$DIST/install.sh" ]
  printf 'kit\n' > "$DIST/k.tar.gz"
  local mutile="$BATS_TEST_TMPDIR/gabarit-mutile.sh"
  grep -v '@@DOOR_PUBKEY@@' "$TEMPLATE" > "$mutile"
  run env LCARS_DOOR_TEMPLATE="$mutile" bash "$GEN" 0.9.0 https://f/x "$DIST"
  [ "$status" -eq 1 ]; [[ "$output" == *"0 fois @@DOOR_PUBKEY@@"* ]]; [ ! -f "$DIST/install.sh" ]
  run bash "$GEN" 'v0.9.0; rm -rf /' https://f/x "$DIST"
  [ "$status" -eq 1 ]; [[ "$output" == *"tag"* ]]; [ ! -f "$DIST/install.sh" ]
  run bash "$GEN" 0.9.0 ftp://f/x "$DIST"
  [ "$status" -eq 1 ]; [[ "$output" == *"http(s)"* ]]; [ ! -f "$DIST/install.sh" ]
}

@test "le generateur ne SUBSTITUE pas, il rebatit : une base qui porte & ou \\ est recopiee telle quelle" {
  run env LCARS_MINISIGN_PUBKEY="" bash "$GEN" 0.9.0 'https://f/x?a=1&b=2' "$DIST"
  [ "$status" -eq 0 ]
  grep -qF 'DOOR_BASE="https://f/x?a=1&b=2"' "$DIST/install.sh"
}

@test "pack.sh : la porte de la version est generee APRES les artefacts, dans un tiroir PAR VERSION (dist/<tag>) par liens durs" {
  local pk="$BATS_TEST_DIRNAME/../../pack.sh"
  local body; body="$(grep -vE '^\s*#' "$pk")"
  grep -qE '^DIST="\$PACK_DIR/dist/\$TAG"' <<<"$body"
  grep -qE 'ln -f "\$_f" "\$DIST/' <<<"$body"
  grep -qE 'door-gen.sh "\$TAG" "\$DOOR_BASE" "\$DIST"' <<<"$body"
  local l_deb l_door; l_deb="$(grep -nE '"\$NFPM" package' <<<"$body" | head -1 | cut -d: -f1)"; l_door="$(grep -nE 'door-gen.sh "\$TAG"' <<<"$body" | cut -d: -f1)"
  [ "$l_deb" -lt "$l_door" ]
  # LCARS_DOOR_BASE surcharge la base (les bancs servent en local)
  grep -qE 'DOOR_BASE="\$\{LCARS_DOOR_BASE:-' <<<"$body"
}
