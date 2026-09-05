#!/usr/bin/env bats
# SOURCE: runtime/test/services/forge.d/tokens_probes.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-17
# STATUS: bats tests for 63-forge-tokens — les deux sondes de REGLAGE D'INSTANCE, et leur troisieme etat
#
# POURQUOI CE FICHIER. `63-forge-tokens` porte deux sondes qui ne mutent rien : elles lisent un reglage que
# LCARS livre par defaut, qu'un admin peut changer chez lui, et elles lui disent ce que son choix
# coute. Aucune n'etait sous test — et l'une d'elles porte un piege jq qui a DEJA mordu ailleurs.
#
# LE PIEGE, ET C'EST LA RAISON PRINCIPALE DE CE FICHIER : `.restricted // "?"` traite `false` comme
# absent. Un compte correctement NON restreint serait alors lu « non mesurable », et la sonde se
# tairait exactement la ou elle doit dire OK. Le meme operateur avait produit le meme defaut dans
# `forge_is_admin` (human-converger.sh), ou il empechait toute DEMOTION de se declencher — corrige
# la-bas par `has()`, et epingle ici pour que la forme ne revienne pas par cette porte.
#
# LA SONDE TOURNE SANS AUCUN JETON : `GET /users/<login>` expose `restricted` en anonyme (mesure du
# 2026-08-17). C'est ce qui la rend jouable au meme rang que `probe_registration`, avant tout mint —
# et c'est ce que le stub reproduit : il ne verifie aucun en-tete d'autorisation.
#
# ON EXECUTE LE MODULE, on ne le source pas : c'est le patron des autres temoins de `deploy/`
# (`forge_charte.bats`), et il mesure la chaine reelle module -> lib -> sortie plutot qu'une
# fonction isolee de son cablage.

load ../../support/refute

setup() {
  MODULE="$BATS_TEST_DIRNAME/../../../services/forge.d/tokens.sh"
  [ -f "$MODULE" ]

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN" "$BATS_TEST_TMPDIR/tokens"

  export LCARS_MODULE_PROTOCOL="$BATS_TEST_DIRNAME/../../../services/lib/module-protocol.sh"
  export LCARS_MODULE_TAG=63-forge-tokens
  # le roster vient du release par « lcars tool » : ici, une CLI de doublure qui rend un roster fixe
  mkdir -p "$BIN"; printf '%s\n' '#!/usr/bin/env bash' '[[ "$1" == tool ]] && shift' '[[ "$1" == roles-tfvars ]] && echo "{\"roles\":[\"fleet_engineer\"],\"system_roles\":[\"system_architect\"]}"' 'exit 0' > "$BIN/lcars"; chmod +x "$BIN/lcars"; export LCARS_CLI="$BIN/lcars"
  export FORGE_BASE_URL="http://forge.test"
  export LCARS_LOGIN="zoe"
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/tokens"
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/nocat"
  export PATH="$BIN:$PATH"
}

# Le stub AIGUILLE sur le chemin demande. Un stub qui rendrait la meme chose a tout le monde
# ferait passer la sonde d'inscription pour une reponse de la sonde restricted, et le temoin
# mesurerait sa propre mise en scene.
stub_curl() { # stub_curl <corps json pour /users/zoe>
  cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
case "\$url" in
  */api/v1/version)      printf '{"version":"1.26.1"}' ;;
  */user/sign_up)        printf '<form><input name="user_name"></form>' ;;
  */api/v1/users/zoe)    printf '%s' '$1' ;;
  *)                     exit 22 ;;
esac
exit 0
EOF
  chmod +x "$BIN/curl"
}

@test "restricted=false -> OK explicite (et c'est le piege jq: false n'est pas une non-reponse)" {
  stub_curl '{"login":"zoe","restricted":false}'
  run bash "$MODULE" check

  [[ "$output" == *"zoe non restreint"* ]]
  # LE COEUR DU TEMOIN : `false` ne doit JAMAIS produire le message de non-lecture.
  [[ "$output" != *"drapeau restricted de zoe non lisible"* ]]
}

@test "restricted=true -> DRIFT qui NOMME la consequence, pas seulement l'etat" {
  stub_curl '{"login":"zoe","restricted":true}'
  run bash "$MODULE" check

  [[ "$output" == *"RESTREINT"* ]]
  # Un drift qui dit « restricted=true » et s'arrete envoie l'operateur chercher pourquoi c'est
  # grave. La consequence MESUREE est la seule chose qui rend le message actionnable.
  [[ "$output" == *"AUCUNE org de catalogue"* ]]
  [[ "$output" == *"DEFAULT_USER_IS_RESTRICTED"* ]]
}

@test "champ ABSENT -> non mesure, jamais un verdict invente" {
  stub_curl '{"login":"zoe"}'
  run bash "$MODULE" check

  [[ "$output" == *"non lisible"* ]]
  [[ "$output" != *"non restreint"* ]]
  [[ "$output" != *"RESTREINT"* ]]
}

@test "forge muette sur ce compte -> non mesure (et le module continue)" {
  # `curl -fsS` sort 22 sur 404 : le corps est vide, et un corps vide n'est pas un `false`.
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */api/v1/version) printf '{"version":"1.26.1"}'; exit 0 ;;
  */user/sign_up)   printf '<form><input name="user_name"></form>'; exit 0 ;;
  *)                exit 22 ;;
esac
EOF
  chmod +x "$BIN/curl"
  run bash "$MODULE" check

  [[ "$output" == *"non lisible"* ]]
  # LE TEMOIN NEGATIF DE LA CONTINUITE : une sonde qui n'a pas su lire ne doit pas emporter le
  # module. La sonde d'inscription, jouee juste avant, doit avoir rendu son verdict.
  [[ "$output" == *"inscription OUVERTE"* ]]
}

@test "l'inscription FERMEE est un drift, et il nomme le reglage d'instance" {
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */api/v1/version)   printf '{"version":"1.26.1"}'; exit 0 ;;
  */user/sign_up)     printf 'Registration is disabled'; exit 0 ;;
  */api/v1/users/zoe) printf '{"login":"zoe","restricted":false}'; exit 0 ;;
  *)                  exit 22 ;;
esac
EOF
  chmod +x "$BIN/curl"
  run bash "$MODULE" check

  [[ "$output" == *"inscription FERMÉE"* ]]
  [[ "$output" == *"DISABLE_REGISTRATION"* ]]
}

# ─── LE MODE APPLY NE DOIT PAS MOURIR SUR UNE BOITE DEJA CONVERGEE ──────────────────────────────
#
# ⚠ CE TEMOIN EXISTE PARCE QUE L'ABSENCE D'UN `return 0` A TUE UN BANC ENTIER (2026-08-17).
# `converge_authority_modes` finissait sur `[[ "$LCARS_MODULE_MODE" == "check" ]] && p_ok …`. En mode APPLY
# ce test est FAUX, donc la fonction rendait 1, donc `set -e` tuait le module juste apres — sans un
# mot, en annoncant seulement « echecs: 1 ».
#
# ET IL NE MORD QUE SUR UNE BOITE DEJA CONVERGEE : au premier apply les modes sont a corriger, la
# branche qui chgrp/chmod rend 0. C'est au SECOND que ca casse. Conséquence mesurée sur `lcars-l6` :
# aucun jeton de role minte, deck OIDC non pose, convergeur aveugle, AUCUN humain materialise.
#
# CE QUE LE TEMOIN MESURE : que l'apply ATTEINT l'etape suivante. Pas un succes d'apply — il en
# faudrait une forge entiere — mais le franchissement de la ligne qui tuait.
apply_stubs() { # $1 = mode rendu par `stat` sur les fichiers d'autorite
  cat > "$BIN/getent" <<'EOF2'
#!/usr/bin/env bash
[[ "$1" == "group" ]] && { printf 'lcars-admin:x:3000:\n'; exit 0; }
exit 2
EOF2
  cat > "$BIN/stat" <<EOF2
#!/usr/bin/env bash
printf '%s' '$1'
EOF2
  cat > "$BIN/curl" <<'EOF2'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */api/v1/version)   printf '{"version":"1.26.1"}'; exit 0 ;;
  */user/sign_up)     printf '<form><input name="user_name"></form>'; exit 0 ;;
  */api/v1/users/zoe) printf '{"login":"zoe","restricted":false}'; exit 0 ;;
  # Aucun compte de role n'existe : l'apply doit atteindre le drift « structure absente ».
  *)                  exit 22 ;;
esac
EOF2
  chmod +x "$BIN/getent" "$BIN/stat" "$BIN/curl"
  : > "$BATS_TEST_TMPDIR/tokens/forge-master.token"
  : > "$BATS_TEST_TMPDIR/tokens/forge-seed.pass"
}

# ⚠ LES DEUX FIXTURES CI-DESSOUS ONT ETE ECHANGEES PAR LA CIBLE, PAS PAR UNE EDITION. L'etat
# convergé était `640 root:<groupe admin>` ; il est `600 root:root` depuis que le geste vit dans un
# service root et que plus aucun humain n'a besoin de lire ces secrets. Les noms des deux temoins
# sont donc restes attaches a l'ANCIENNE cible : chacun annonçait la branche que l'autre exerce.
# Les deux passaient — c'est bien le probleme. Un nom de test est ce qu'un lecteur croit sur parole
# pour savoir quelle branche est couverte ; faux, il est pire qu'un commentaire perime.
@test "apply : modes DEJA convergés → le module ne meurt pas, il atteint l'étape suivante" {
  apply_stubs "600 root:root"
  run bash "$MODULE" apply

  # L'etape d'apres est la sonde de structure. Si elle parle, la ligne mortelle a ete franchie.
  [[ "$output" == *"structure absente"* ]]
}

@test "apply : modes À CORRIGER → même chemin, et c'est le cas qui MASQUAIT le défaut" {
  # Ici la branche chgrp/chmod rend 0, donc le module survivait meme sans `return 0`. Le garder
  # comme temoin nomme le pourquoi : sans lui, on croirait que le premier test suffit.
  # La fixture est un mode QUI N'EST PLUS LA CIBLE — donc le module doit le corriger.
  apply_stubs "640 root:lcars-admin"
  run bash "$MODULE" apply

  [[ "$output" == *"structure absente"* ]]
}

# ─── LES DEUX REGIMES DE PROPRIETE DU REPERTOIRE PRIVE (M13) ET LE DRAPEAU DU JETON MASTER (M8) ────
#
# Relecture hostile 2026-09-04. Sur le banc : master et seed en 0600 lcars-authority (le service
# d'autorite les ouvre), et `forge-role-passwords.json` — le SEED EN CLAIR pour chaque compte de
# role — en 0600 root:root, sans que rien ne mesure son mode : `converge_authority_modes` ne le
# portait pas. Et le drapeau `--master-token-file` partait TOUJOURS vers le minteur : le protocole
# pose toujours le NOM du fichier, donc `${VAR:+…}` etait toujours vrai, fichier absent compris.
#
# `stat` est double PAR FICHIER : un stub qui rend la meme chose a tous ferait passer le mode du
# passwords-file pour celui du jeton master, et le temoin mesurerait sa propre mise en scene.
stub_stat_per_file() { # <mode du passwords-file> <mode des fichiers d'autorite>
  cat > "$BIN/stat" <<EOF2
#!/usr/bin/env bash
f="\${@: -1}"
case "\$f" in
  *forge-role-passwords.json) printf '%s' '$1' ;;
  *)                          printf '%s' '$2' ;;
esac
EOF2
  chmod +x "$BIN/stat"
}

@test "check : le passwords-file (seed en clair par compte) est MESURE — 600 root:root, sinon DRIFT qui le nomme (M13)" {
  stub_curl '{"login":"zoe","restricted":false}'
  stub_stat_per_file "644 root:root" "600 lcars-authority:lcars-authority"
  : > "$BATS_TEST_TMPDIR/tokens/forge-master.token"
  : > "$BATS_TEST_TMPDIR/tokens/forge-seed.pass"
  : > "$BATS_TEST_TMPDIR/tokens/forge-role-passwords.json"
  run bash "$MODULE" check
  [[ "$output" == *"forge-role-passwords.json est 644 root:root"* ]]
  [[ "$output" == *"attendu 600 root:root"* ]]
  # et les fichiers d'autorite, eux, sont a leur cible : OK, pas drift
  [[ "$output" == *"forge-master.token (0600 lcars-authority:lcars-authority)"* ]]
}

@test "check : les deux regimes sont DISTINCTS — un passwords-file a lcars-authority est un drift, pas une cible (M13)" {
  # Le minteur seul le lit, sous root ; le donner au service d'autorite elargirait qui peut lire
  # le seed en clair. La regle n'est pas « 0600 a quelqu'un », c'est « 0600 a root ».
  stub_curl '{"login":"zoe","restricted":false}'
  stub_stat_per_file "600 lcars-authority:lcars-authority" "600 lcars-authority:lcars-authority"
  : > "$BATS_TEST_TMPDIR/tokens/forge-master.token"
  : > "$BATS_TEST_TMPDIR/tokens/forge-role-passwords.json"
  run bash "$MODULE" check
  [[ "$output" == *"forge-role-passwords.json est 600 lcars-authority:lcars-authority"* ]]
  [[ "$output" == *"attendu 600 root:root"* ]]
}

# Le decor qui mene l'apply JUSQU'AU MINT : forge joignable, comptes presents, sonde A4 en echec,
# passwords-file complet (aucun seed necessaire), et un minteur double qui note son argv.
apply_jusquau_mint() {
  cat > "$BIN/getent" <<'EOF2'
#!/usr/bin/env bash
[[ "$1" == "group" ]] && { printf 'lcars-admin:x:3000:\n'; exit 0; }
exit 2
EOF2
  cat > "$BIN/curl" <<'EOF2'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */api/v1/version)   printf '{"version":"1.26.1"}'; exit 0 ;;
  */user/sign_up)     printf '<form><input name="user_name"></form>'; exit 0 ;;
  */api/v1/users/*)   exit 0 ;;   # `-o /dev/null` chez l'appelant : rien sur stdout, sinon le corps pollue `missing_accounts`
  *)                  exit 22 ;;
esac
EOF2
  chmod +x "$BIN/getent" "$BIN/curl"
  stub_stat_per_file "600 root:root" "600 lcars-authority:lcars-authority"
  printf '{"fleet_engineer":"s","system_architect":"s","system_starfleet":"s"}\n' > "$BATS_TEST_TMPDIR/tokens/forge-role-passwords.json"
  ARGV="$BATS_TEST_TMPDIR/a4.argv"
  export LCARS_ROLE_TOKENS_SCRIPT="$BATS_TEST_TMPDIR/a4.sh"
  cat > "$LCARS_ROLE_TOKENS_SCRIPT" <<EOF2
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == --check ]] && exit 1; done
printf '%s\n' "\$@" > '$ARGV'
exit 0
EOF2
  chmod +x "$LCARS_ROLE_TOKENS_SCRIPT"
}

@test "apply : sans jeton master LISIBLE, --master-token-file ne part PAS vers le minteur (M8)" {
  apply_jusquau_mint
  rm -f "$BATS_TEST_TMPDIR/tokens/forge-master.token"
  run bash "$MODULE" apply
  [ -f "$ARGV" ] || { echo "le minteur n'a pas ete atteint :"; echo "$output"; return 1; } >&2
  refute grep -q -- '--master-token-file' "$ARGV"
  grep -q -- '--passwords-file' "$ARGV"
}

@test "apply : avec un jeton master lisible, --master-token-file part, et il nomme le fichier (M8)" {
  apply_jusquau_mint
  : > "$BATS_TEST_TMPDIR/tokens/forge-master.token"
  run bash "$MODULE" apply
  [ -f "$ARGV" ] || { echo "le minteur n'a pas ete atteint :"; echo "$output"; return 1; } >&2
  grep -qx -- '--master-token-file' "$ARGV"
  grep -qx -- "$BATS_TEST_TMPDIR/tokens/forge-master.token" "$ARGV"
}
