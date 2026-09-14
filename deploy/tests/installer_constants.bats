#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/installer_constants.bats
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: mur — une valeur de deploy/installer-constants.env ne s'écrit nulle part ailleurs dans le code de deploy/ ni dans install.sh

load refute

setup() {
  R="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CONSTANTES="$R/deploy/installer-constants.env"
  [ -r "$CONSTANTES" ]
}

# Ce que le mur ne lit pas, chaque fois pour une raison :
#   deploy/tests/            les témoins posent leurs valeurs attendues
#   *.md                     la prose ; elle se relit à la main
#   system.manifest          la table déclare mode et propriétaire de chaque chemin canonique, par son chemin
#   *.json                   le profil seccomp de l'image
code_de_deploy() { # code_de_deploy <racine> → les fichiers de code balayés
  { find "$1/deploy" -type f ! -path "$1/deploy/tests/*" ! -name '*.md' ! -name installer-constants.env \
         ! -name system.manifest ! -name '*.json'
    echo "$1/install.sh"; } | sort
}

# Les tolérances, chacune pour sa raison ; « fichier|* » soustrait le fichier entier :
#   Dockerfile|*                        l'image se bâtit et se lance sans le fichier des constantes : ses chemins et sa sonde de santé sont écrits
#   64-services.sh|PROV_LINK_DIR        le PATH d'un daemon nomme /usr/local/bin comme dossier du système, pas comme dossier des liens
EXCEPTIONS='deploy/docker/Dockerfile|*
deploy/modules.d/64-services.sh|PROV_LINK_DIR'

# une constante de racine est un dossier, et son nom le dit : un chemin écrit sous elle la recopie
RACINE='_(ROOT|PREFIX|DIR|WORK)$'

# une ligne de commentaire, ou un commentaire en fin de ligne, est de la prose
sans_commentaires() { sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]+#[[:space:]].*$//' "$1"; }

litteraux() { # litteraux <racine> <fichier des constantes> → « fichier|clé|ligne » par valeur écrite en dur
  local racine="$1" l k v motif suite f rel
  while IFS= read -r l || [[ -n "$l" ]]; do
    k="${l%%=*}"; v="${l#*=}"
    [[ "$k" != "$l" && "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    # un mot nu ou un petit nombre se confond avec la prose (fleet, humans, lcars, 27), et une valeur vide ne se recopie pas : ils ne sont pas balayés
    [[ -z "$v" || "$v" =~ ^[a-z]+$ || "$v" =~ ^[0-9]{1,3}$ ]] && continue
    motif="$(printf '%s' "$v" | sed 's/[][\.*^$/+?(){}|]/\\&/g')"
    suite='[^A-Za-z0-9_./-]'
    [[ ! "$k" =~ $RACINE ]] || suite='[^A-Za-z0-9_.-]'
    while read -r f; do
      rel="${f#"$racine"/}"
      grep -qxF -e "$rel|$k" -e "$rel|*" <<<"$EXCEPTIONS" && continue
      sans_commentaires "$f" | grep -nE "(^|[^A-Za-z0-9_.-])${motif}(\$|${suite})" | sed "s#^#$rel|$k|#" || true
    done < <(code_de_deploy "$racine")
  done < "$2"
}

@test "GARDE D'INSTRUMENT : le balayage lit deploy/ et install.sh, voit une valeur plantée et un sous-chemin d'une racine, et soustrait une exception" {
  local faux="$BATS_TEST_TMPDIR/arbre"
  mkdir -p "$faux/deploy/lib" "$faux/deploy/tests" "$faux/deploy/docker"
  printf 'PROV_X_ROOT=/opt/exemple/var\nPROV_Y_FILE=/opt/exemple/fichier\nPROV_Z=lcars\n' > "$faux/deploy/installer-constants.env"
  printf '#!/usr/bin/env bash\nD=/opt/exemple/var\n# /opt/exemple/var/prose en prose\nE="$C:/opt/exemple/var/sous"\nF=/opt/exemple/fichier/x\nG=/opt/exemple/var.d\n' > "$faux/deploy/lib/a.sh"
  printf 'x=/opt/exemple/var/sous\n' > "$faux/deploy/tests/b.bats"
  printf 'VOLUME ["/opt/exemple/var/sous"]\n' > "$faux/deploy/docker/Dockerfile"
  printf '#!/usr/bin/env bash\necho "lcars"\n' > "$faux/install.sh"
  run litteraux "$faux" "$faux/deploy/installer-constants.env"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' 'deploy/lib/a.sh|PROV_X_ROOT|2:D=/opt/exemple/var' 'deploy/lib/a.sh|PROV_X_ROOT|4:E="$C:/opt/exemple/var/sous"')" ]
}

@test "aucune valeur des constantes n'est écrite en dur dans le code de deploy/ ni dans install.sh" {
  local trouves
  trouves="$(litteraux "$R" "$CONSTANTES")"
  [ -z "$trouves" ] || {
    echo "valeurs recopiées — elles se lisent dans les constantes (la lib, --env-file, ou prov_canon pour un chemin du conteneur) :" >&2
    printf '  %s\n' "$trouves" >&2
    return 1
  }
}

@test "le fichier se lit comme une donnée : CLE=valeur, une clé une fois, sans guillemet ni expansion" {
  local lignes cles
  lignes="$(grep -vE '^[[:space:]]*(#|$)' "$CONSTANTES")"
  [ -n "$lignes" ]
  refute_out -v '^[A-Z][A-Z0-9_]*=[^"'"'"'$`]*$' <<<"$lignes"
  cles="$(cut -d= -f1 <<<"$lignes")"
  [ "$(sort <<<"$cles" | uniq -d)" = "" ]
}

@test "les valeurs composées du fichier s'accordent avec leurs racines — le fichier n'expanse rien, il se tient d'accord" {
  c() { sed -n "s/^$1=//p" "$CONSTANTES"; }
  local racine jetons k
  racine="$(c PROV_ROOT)"; jetons="$(c PROV_TOKENS_DIR)"
  [ -n "$racine" ]
  [ -n "$jetons" ]
  for k in PROV_PREFIX PROV_TOFU_DIR PROV_MEDIA_ROOT PROV_CATALOGUES_DIR PROV_CATALOGUES_WORK PROV_JOURNAL_FILE PROV_TOKENS_DIR; do
    [[ "$(c "$k")" == "$racine"/* ]] || { echo "$k=$(c "$k") n'est pas sous PROV_ROOT=$racine" >&2; return 1; }
  done
  for k in PROV_MASTER_TOKEN_FILE PROV_FORGE_SEED_FILE PROV_UID_MAP_FILE PROV_FORGE_URL_FILE PROV_FORGE_PUBLIC_URL_FILE PROV_SYSTEM_TOKEN_FILE; do
    [ "$(dirname "$(c "$k")")" = "$jetons" ] || { echo "$k=$(c "$k") n'est pas dans PROV_TOKENS_DIR=$jetons" >&2; return 1; }
  done
  [ "$(c PROV_SYSTEM_TOKEN_FILE)" = "$jetons/$(c PROV_SYSTEM_ACCOUNT).gitea_token" ]
  [ "$(c PROV_TOFU_BIN)" = "$(c PROV_LINK_DIR)/tofu" ]
  [ "$(dirname "$(c PROV_TOFU_RC)")" = "$(c PROV_TOFU_DIR)" ]
  [ "$(dirname "$(c PROV_FORGE_STATE_DIR)")" = "$(c PROV_TOFU_DIR)" ]
}

@test "qui source la lib ne pose avant elle aucun nom de constante — la lib l'écraserait sans un mot" {
  local noms f src hits=""
  noms="$(sed -nE 's/^([A-Z][A-Z0-9_]*)=.*/\1/p' "$CONSTANTES" | sort -u)"
  [ -n "$noms" ]
  while read -r f; do
    src="$(grep -nE '^[[:space:]]*(\.|source)[[:space:]].*(PROVISION_LIB|provision-lib\.sh)' "$f" | head -1 | cut -d: -f1)"
    [ -n "$src" ] || continue
    hits+="$(awk -v lim="$src" -v noms="$(tr '\n' ' ' <<<"$noms")" '
      BEGIN { n = split(noms, t, " "); for (i = 1; i <= n; i++) connu[t[i]] = 1 }
      NR < lim && match($0, /^[[:space:]]*(export[[:space:]]+)?[A-Z_][A-Z0-9_]*=/) {
        nom = $0; sub(/^[[:space:]]*(export[[:space:]]+)?/, "", nom); sub(/=.*/, "", nom)
        if (nom in connu) print FILENAME ":" NR ": " nom
      }' "$f")"
  done < <(grep -rlE '(PROVISION_LIB|provision-lib\.sh)' "$R/deploy" "$R/install.sh" --exclude-dir=tests)
  [ -z "$hits" ] || { echo "posés avant la lib, donc écrasés ou masqués par elle :" >&2; printf '%s\n' "$hits" >&2; return 1; }
}
