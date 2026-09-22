# SOURCE: deploy/tests/support/decor.bash
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: helper bats — le décor d'un témoin (une racine système sous le tmp du cas) et la forge HTTP locale
#
#   load ../support/decor
#   decor_pose                         LCARS_DECOR_ROOT, ses dossiers usuels, DECOR_BIN en tête du PATH
#   forge_double_start                 FORGE_DOUBLE_URL ; les routes s'ajoutent par forge_route
#   forge_route <MÉTHODE> <chemin> <code> [x<usages>] [corps]
#   forge_requests '<filtre jq>'       les requêtes reçues, filtrées ; forge_double_stop en teardown
#   espion_enfants <commande…>         chaque commande note « ARGV <nom> <argv> » et son environnement dans DECOR_ENFANTS
#   decor_comptes                      getent, id, groupadd, useradd et usermod sur le passwd et le group du décor,
#                                      chaque mutation notée dans DECOR_COMPTES ; DECOR_USERMOD_REFUS fait refuser usermod,
#                                      DECOR_USERADD_SHELL fait poser un autre shell que celui demandé
#
# La lib lit toute constante de chemin sous LCARS_DECOR_ROOT, et prov_owner y rend le compte qui
# joue le cas : un témoin pose des fichiers dans le décor, jamais une variable par fichier.

DECOR_SUPPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

decor_pose() {
  export LCARS_DECOR_ROOT="$BATS_TEST_TMPDIR/decor"
  export DECOR_BIN="$BATS_TEST_TMPDIR/decor-bin"
  # ⚠ LES PRIMITIVES DU PRODUIT SONT NOMMÉES ICI, ET C'EST UNE DETTE DE LA PHASE 6. Depuis que
  # `env_field`, `read_token`, `ensure_dir`, `ensure_mode` et `write_atomic` ne sont plus écrites
  # deux fois, `provision-lib.sh` source celles du PRODUIT — et un témoin qui recopie la lib dans un
  # faux arbre `deploy/` seul ne les y trouve pas. Le bouchon se déclenche alors, `read_token` rend
  # la chaîne VIDE, et la suite parle à la forge en ANONYME. Mesuré le 2026-09-20 : 89 cas de
  # `deploy/gate.sh` rouges pour cette seule cause, dont tout le banc, sur « le jeton master ne
  # s'authentifie pas ». Un décor recopie déjà la vraie lib de l'installeur : il désigne de la même
  # façon la vraie lib du produit, au lieu de fabriquer une copie de plus qui dériverait.
  export PROV_PRIMITIVES_SH="$DECOR_SUPPORT_DIR/../../../runtime/services/lib/primitives.sh"
  mkdir -p "$LCARS_DECOR_ROOT/opt/lcars/var/tokens" "$LCARS_DECOR_ROOT/etc/lcars" \
           "$LCARS_DECOR_ROOT/usr/local/bin" "$DECOR_BIN"
  export PATH="$DECOR_BIN:$PATH"
}

forge_double_start() {
  FORGE_DOUBLE_DIR="$BATS_TEST_TMPDIR/forge-double"
  mkdir -p "$FORGE_DOUBLE_DIR"
  : > "$FORGE_DOUBLE_DIR/routes"
  : > "$FORGE_DOUBLE_DIR/requests.jsonl"
  # fd 3 fermé : bats attend la fin de tout processus qui garde son descripteur
  python3 "$DECOR_SUPPORT_DIR/forge_double.py" "$FORGE_DOUBLE_DIR" 3>&- &
  FORGE_DOUBLE_PID=$!
  local _
  for _ in $(seq 1 50); do [[ -s "$FORGE_DOUBLE_DIR/port" ]] && break; sleep 0.1; done
  [[ -s "$FORGE_DOUBLE_DIR/port" ]] || { echo "forge_double : le serveur n'a pas écrit son port" >&2; return 1; }
  FORGE_DOUBLE_URL="http://127.0.0.1:$(cat "$FORGE_DOUBLE_DIR/port")"
  export FORGE_DOUBLE_URL
}

forge_route() { printf '%s\n' "$*" >> "$FORGE_DOUBLE_DIR/routes"; }

espion_enfants() {
  export DECOR_ENFANTS="$BATS_TEST_TMPDIR/enfants"
  : > "$DECOR_ENFANTS"
  local c vraie
  for c in "$@"; do
    vraie="$(PATH="${PATH//"$DECOR_BIN:"/}" command -v "$c")"
    printf '#!/usr/bin/env bash\n{ printf "ARGV %s %%s\\n" "$*"; env; } >> %q\nexec %q "$@"\n' "$c" "$DECOR_ENFANTS" "$vraie" > "$DECOR_BIN/$c"
    chmod +x "$DECOR_BIN/$c"
  done
}

decor_comptes() {
  export DECOR_COMPTES="$BATS_TEST_TMPDIR/comptes"
  : > "$DECOR_COMPTES"
  touch "$LCARS_DECOR_ROOT/etc/passwd" "$LCARS_DECOR_ROOT/etc/group"
  cat > "$DECOR_BIN/getent" <<'EOS'
#!/usr/bin/env bash
case "$1" in group) f="$LCARS_DECOR_ROOT/etc/group" ;; passwd) f="$LCARS_DECOR_ROOT/etc/passwd" ;; *) exit 2 ;; esac
[[ "${2:-}" != -- ]] || set -- "$1" "${@:3}"
[[ -n "${2:-}" ]] || { cat "$f"; exit 0; }
awk -F: -v n="$2" '$1==n {print; found=1; exit} END {exit !found}' "$f"
EOS
  # un compte se lit dans le décor ; l'identité de qui joue le cas (id -u, -un, -gn) reste celle de la machine
  cat > "$DECOR_BIN/id" <<'EOS'
#!/usr/bin/env bash
p="$LCARS_DECOR_ROOT/etc/passwd" g="$LCARS_DECOR_ROOT/etc/group"
[[ "${2:-}" != -- ]] || set -- "$1" "${@:3}"
case "$#:${1:-}" in
  2:-nG) gid="$(awk -F: -v n="$2" '$1==n {print $4; exit}' "$p")"
         [[ -n "$gid" ]] || exit 1
         { awk -F: -v g="$gid" '$3==g {print $1}' "$g"
           awk -F: -v u="$2" '{n=split($4,m,","); for(i=1;i<=n;i++) if (m[i]==u) print $1}' "$g"; } | sort -u | paste -sd' ' - ;;
  2:-u)  awk -F: -v n="$2" '$1==n {print $3; found=1; exit} END {exit !found}' "$p" ;;
  1:-*)  exec /usr/bin/id "$@" ;;
  1:*)   awk -F: -v n="$1" '$1==n {found=1} END {exit !found}' "$p" ;;
  *)     exec /usr/bin/id "$@" ;;
esac
EOS
  cat > "$DECOR_BIN/groupadd" <<'EOS'
#!/usr/bin/env bash
echo "groupadd $*" >> "$DECOR_COMPTES"
g="$LCARS_DECOR_ROOT/etc/group" gid=""
[[ "$1" != -g ]] || gid="$2"
printf '%s:x:%s:\n' "${*: -1}" "${gid:-$((3000 + $(wc -l < "$g")))}" >> "$g"
EOS
  cat > "$DECOR_BIN/useradd" <<'EOS'
#!/usr/bin/env bash
echo "useradd $*" >> "$DECOR_COMPTES"
grp="" shell=""
while [[ $# -gt 0 ]]; do case "$1" in -g) grp="$2" ;; --shell) shell="$2" ;; esac; nom="$1"; shift; done
gid="$(awk -F: -v n="$grp" '$1==n {print $3; exit}' "$LCARS_DECOR_ROOT/etc/group")"
printf '%s:x:999:%s::/nonexistent:%s\n' "$nom" "${gid:-65534}" "${DECOR_USERADD_SHELL:-$shell}" >> "$LCARS_DECOR_ROOT/etc/passwd"
EOS
  cat > "$DECOR_BIN/usermod" <<'EOS'
#!/usr/bin/env bash
echo "usermod $*" >> "$DECOR_COMPTES"
[[ -z "${DECOR_USERMOD_REFUS:-}" ]] || { echo "usermod: /etc/group verrouillé" >&2; exit 10; }
[[ "$1" == -aG ]] || exit 2
g="$LCARS_DECOR_ROOT/etc/group"
awk -F: -v OFS=: -v gr="$2" -v u="${*: -1}" '$1==gr {$4=($4=="" ? u : $4","u)} {print}' "$g" > "$g.new" && mv "$g.new" "$g"
EOS
  chmod 0755 "$DECOR_BIN/getent" "$DECOR_BIN/id" "$DECOR_BIN/groupadd" "$DECOR_BIN/useradd" "$DECOR_BIN/usermod"
}

forge_requests() { jq -c "${1:-.}" "$FORGE_DOUBLE_DIR/requests.jsonl"; }

forge_double_stop() {
  [[ -z "${FORGE_DOUBLE_PID:-}" ]] || { kill "$FORGE_DOUBLE_PID" 2>/dev/null || true; wait "$FORGE_DOUBLE_PID" 2>/dev/null || true; }
}
