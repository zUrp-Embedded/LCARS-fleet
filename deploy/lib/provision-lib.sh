#!/usr/bin/env bash
# les fonctions rendent leurs résultats par des globales PROV_* que l'appelant lit : shellcheck les voit inutilisées
# shellcheck disable=SC2034
# SOURCE: deploy/lib/provision-lib.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: la bibliothèque des modules — défauts, verdicts, primitives convergentes et atomiques, sondes de la machine et de la forge

[[ -n "${PROVISION_LIB_LOADED:-}" ]] && return 0
PROVISION_LIB_LOADED=1

# shellcheck source=docker-endpoint.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/docker-endpoint.sh"

PROV_ROOT_CANON=/opt/lcars
if [[ -n "${PROV_ROOT:-}" && "${PROV_ROOT}" != "$PROV_ROOT_CANON" && -z "${BATS_TEST_TMPDIR:-}" ]]; then
  printf 'ÉCHEC : PROV_ROOT est posé à « %s » dans l'"'"'environnement, et la racine du produit est fixe (%s).\n' \
    "$PROV_ROOT" "$PROV_ROOT_CANON" >&2
  printf '       LCARS ne s'"'"'installe que sur un terrain contrôlé — docker, WSL — où il impose son\n' >&2
  printf '       arborescence. Le manifeste déclare mode et propriétaire sous cette racine ; la déplacer\n' >&2
  printf '       rendrait fausse chaque mesure qui s'"'"'y réfère, sans que rien ne rougisse.\n' >&2
  printf '       Pour poser ailleurs : un autre terrain, pas une autre racine.\n' >&2
  exit 1
fi
: "${PROV_ROOT:=$PROV_ROOT_CANON}"

: "${PROV_PREFIX:=$PROV_ROOT/runtime}"          # install RO du runtime (modèle 3 zones d'etc/deploy-release.sh)
: "${PROV_LINK_DIR:=/usr/local/bin}"           # symlinks PATH (miroir de LCARS_INSTALL_LINK_DIR d'install.sh)
: "${PROV_FLEET_GROUP:=fleet}"                 # groupe de lecture des tokens + de l'install RO
: "${PROV_AUTHORITY_USER:=lcars-authority}"

: "${PROV_CONSOLE_GROUP:=lcars-console}"       # traverser /run/lcars/console/<humain>, RIEN d'autre
: "${PROV_CATALOGUES_WORK:=$PROV_ROOT/var/tofu}"  # recettes tofu par catalogue (etat = SENSIBLE)
: "${PROV_TOKENS_DIR:=$PROV_ROOT/var/tokens}"  # role-tokens forge (contrat FORGE_ROLE_TOKENS_DIR)
: "${PROV_FORGE_SEED_FILE:=$PROV_TOKENS_DIR/forge-seed.pass}"  # seed bootstrap tofu (handoff → A4)
: "${PROV_MASTER_TOKEN_FILE:=$PROV_TOKENS_DIR/forge-master.token}"
: "${PROV_UID_MAP_FILE:=$PROV_TOKENS_DIR/forge-uid.map}"

: "${PROV_FORGE_BASE:=lcars}"
: "${PROV_FORGE_PROJECT:=${PROV_FORGE_BASE}-forge}"
: "${PROV_RUNNER_PROJECT:=${PROV_FORGE_BASE}-runner}"
: "${PROV_FORGE_NET:=${PROV_FORGE_PROJECT}_default}"
: "${PROV_ROLES:=system_architect system_chief system_gatekeeper fleet_engineer fleet_scribe fleet_qualifier fleet_reviewer fleet_scoper fleet_vulcan}"
: "${PROV_CATALOGUES_DIR:=$PROV_ROOT/var/catalogues}"
: "${PROV_LEGACY_CATALOGUES_DIR:=/home/catalogues}"
: "${PROV_SYSTEM_ACCOUNT:=system_starfleet}"       # compte forge du SYSTÈME (signe les marqueurs)
: "${PROV_SYSTEM_TOKEN_FILE:=$PROV_TOKENS_DIR/$PROV_SYSTEM_ACCOUNT.gitea_token}"
: "${PROV_FORGE_ORG:=fleet}"                   # org qui porte les repos projet (forge.tf)
: "${PROV_HUMANS_TEAM:=humans}"                # team forge dont l'adhesion vaut enrolement
: "${PROV_DECK_PORT:=20999}"
: "${PROV_SSH_PORT:=2222}"
: "${PROV_FORGE_HOST_PORT:=21000}"
# une seule résolution des deux adresses, pour tous les modules : la forge montée (--bench) est celle
# du poste, un FORGE_BASE_URL résiduel ne la remplace pas ; une forge fournie s'annonce à sa propre
# adresse (FORGE_PUBLIC_URL, sinon la même), jamais à celle du poste
if [[ "${PROV_FORGE_MONTEE:-}" == "1" ]]; then
  PROV_FORGE_URL="http://127.0.0.1:${PROV_FORGE_HOST_PORT}"
  : "${PROV_FORGE_PUBLIC_URL:=${FORGE_PUBLIC_URL:-$(cat "$PROV_TOKENS_DIR/forge.public.url" 2>/dev/null || true)}}"
  : "${PROV_FORGE_PUBLIC_URL:=$PROV_FORGE_URL}"
else
  : "${PROV_FORGE_URL:=${FORGE_BASE_URL:-$(cat "$PROV_TOKENS_DIR/forge.url" 2>/dev/null || true)}}"
  if [[ -n "${FORGE_BASE_URL:-}" ]]; then
    : "${PROV_FORGE_PUBLIC_URL:=${FORGE_PUBLIC_URL:-$PROV_FORGE_URL}}"
  else
    : "${PROV_FORGE_PUBLIC_URL:=${FORGE_PUBLIC_URL:-$(cat "$PROV_TOKENS_DIR/forge.public.url" 2>/dev/null || true)}}"
    : "${PROV_FORGE_PUBLIC_URL:=$PROV_FORGE_URL}"
  fi
fi
PROV_FORGE_URL="${PROV_FORGE_URL%/}"
PROV_FORGE_PUBLIC_URL="${PROV_FORGE_PUBLIC_URL%/}"
: "${PROV_DECK_OIDC_FILE:=/etc/lcars/deck-oidc.json}"
: "${PROV_DECK_ORIGINS:=${LCARS_DECK_ORIGINS:-}}"
: "${PROV_DUMP_LINES:=40}"
: "${PROV_UPDATE_REMOTE:=origin}"
: "${PROV_EXPECTED_REPO:=}"
: "${PROV_ELIXIR_OTP_MAJOR:=27}"
: "${PROV_ELIXIR_MIN:=1.20}"
: "${PROV_ELIXIR_PIN:=1.20.4}"
: "${PROV_ELIXIR_PIN_SHA256:=4389f216eec086b34a08d70a3eb0a649d00e6631987d1cbb649a2f81092f034c}"
: "${PROV_HUMAN:=${SUDO_USER:-$(id -un)}}"

PROV_MODULE_TAG="${PROVISION_MODULE:-$(basename "${0:-provision-lib}")}"
PROV_CHANGED=0
PROV_DRIFT=0
PROV_FAILED=0

if [[ -n "${NO_COLOR:-}" ]]; then PROV_COLOR=0
elif [[ -n "${PROV_COLOR:-}" ]]; then :
elif [[ -t 1 ]]; then PROV_COLOR=1
else PROV_COLOR=0
fi
if [[ "$PROV_COLOR" -eq 1 ]]; then
  _PG=$'\033[1;32m'; _PC=$'\033[0;36m'; _PA=$'\033[38;5;214m'; _PR=$'\033[1;31m'; _PN=$'\033[0m'
else
  _PG=''; _PC=''; _PA=''; _PR=''; _PN=''
fi

p_step() { printf '%s>>    %s:%s %s\n' "$_PC" "$PROV_MODULE_TAG" "$_PN" "$*"; }
p_ok()   { printf '%sOK    %s:%s %s\n' "$_PG" "$PROV_MODULE_TAG" "$_PN" "$*"; return 0; }
p_chg()  { printf '%sPOSÉ  %s:%s %s\n' "$_PC" "$PROV_MODULE_TAG" "$_PN" "$*"; return 0; }
p_drift(){ printf '%sDRIFT %s:%s %s\n' "$_PA" "$PROV_MODULE_TAG" "$_PN" "$*" >&2; PROV_DRIFT=$((PROV_DRIFT + 1)); }
p_warn() { printf '%sWARN  %s:%s %s\n' "$_PA" "$PROV_MODULE_TAG" "$_PN" "$*" >&2; }
p_fail() { printf '%sFAIL  %s:%s %s\n' "$_PR" "$PROV_MODULE_TAG" "$_PN" "$*" >&2; PROV_FAILED=$((PROV_FAILED + 1)); }
p_die()  { PROV_VERDICT_RENDERED=1; printf '%sFATAL %s:%s %s\n' "$_PR" "$PROV_MODULE_TAG" "$_PN" "$*" >&2; exit 1; }

p_fact() { # p_fact <nom> <valeur…>
  [[ -n "${PROV_FACTS_FILE:-}" ]] || return 0
  [[ "$#" -ge 2 ]] || return 0
  printf '%s=%s\n' "$1" "${*:2}" 2>/dev/null >> "$PROV_FACTS_FILE" || true
  return 0
}

# le runner arme la garde (PROVISION_RUN) : un module qui meurt sans verdict rend 3, jamais un code lu comme un verdict
PROV_VERDICT_RENDERED=0
_prov_exit_guard() {
  local rc=$?
  [[ "$PROV_VERDICT_RENDERED" -eq 1 ]] && return 0
  printf '%sERREUR %s:%s mort avant de rendre son verdict (rc=%d) — aucune ligne ci-dessus ne le dit, faute de temps\n' \
    "$_PR" "$PROV_MODULE_TAG" "$_PN" "$rc" >&2
  exit 3
}
if [[ -n "${PROVISION_RUN:-}" ]]; then
  trap _prov_exit_guard EXIT
  unset PROVISION_RUN
fi

verdict_check() {
  PROV_VERDICT_RENDERED=1
  if [[ "$PROV_FAILED" -gt 0 ]]; then exit 2; fi
  [[ "$PROV_DRIFT" -gt 0 ]] && exit 1
  exit 0
}
verdict_apply() {
  PROV_VERDICT_RENDERED=1
  [[ "$PROV_FAILED" -gt 0 ]] && exit 1
  [[ "$PROV_DRIFT" -gt 0 ]] && exit 2
  exit 0
}

_prov_phase_of() { # _prov_phase_of <fichier> -> le libelle de la derniere phase reconnue
  local m
  m="$(grep -oE 'Compiling [0-9]+ files|Running ExUnit|Finished in |=== shell_gate|--- bats|contracts\.check green|lcars\.topology|Checking [0-9]+ modules|Total errors|done \(passed|Release created at' "$1" 2>/dev/null | tail -n1 || true)"
  case "$m" in
    "Compiling"*)        echo "compilation" ;;
    "Running ExUnit")    echo "suite ExUnit (3000+ cas)" ;;
    "Finished in "*)     echo "suite ExUnit terminée" ;;
    "=== shell_gate"*)   echo "gate shell (python + bats)" ;;
    "--- bats"*)         echo "gate shell (bats)" ;;
    *"contracts.check green") echo "contrats" ;;
    "lcars.topology")    echo "topologie" ;;
    "Checking "*)        echo "dialyzer (construction du PLT)" ;;
    "Total errors"*)     echo "dialyzer" ;;
    "done (passed"*)     echo "dialyzer terminé" ;;
    "Release created at") echo "release posée" ;;
    *)                   echo "démarrage" ;;
  esac
}

# Exécuter et qualifier sont deux gestes : run_capture exécute et rend le code, l'appelant pose le
# verdict. run_quiet et run_step posent le verdict ordinaire — un échec est un FAIL, avec sa sortie.
run_capture() { # run_capture <cmd…> — sur échec, la sortie reste dans PROV_LAST_OUT
  local rc=0
  PROV_LAST_OUT=""
  if [[ "${PROV_VERBOSE:-0}" -eq 1 ]]; then
    "$@" || rc=$?
  else
    PROV_LAST_OUT="$(mktemp "${TMPDIR:-/tmp}/prov-out.XXXXXX")"
    "$@" >"$PROV_LAST_OUT" 2>&1 || rc=$?
    [[ "$rc" -ne 0 ]] || { rm -f "$PROV_LAST_OUT"; PROV_LAST_OUT=""; }
  fi
  PROV_LAST_RC="$rc"
  return "$rc"
}

prov_dump_last() { # les dernières lignes de la sortie capturée ; le fichier est conservé
  [[ -n "${PROV_LAST_OUT:-}" && -f "$PROV_LAST_OUT" ]] || return 0
  local n; n="$(wc -l < "$PROV_LAST_OUT")"
  {
    printf '───── sortie : %s dernières lignes sur %s ─────\n' "$PROV_DUMP_LINES" "$n"
    tail -n "$PROV_DUMP_LINES" "$PROV_LAST_OUT"
    printf '───── sortie COMPLÈTE conservée : %s ─────\n' "$PROV_LAST_OUT"
  } >&2
}

run_quiet() { # run_quiet <cmd…>
  local rc=0
  run_capture "$@" || rc=$?
  [[ "$rc" -eq 0 ]] || { p_fail "commande en échec (rc=$rc) : $*"; prov_dump_last; }
  return "$rc"
}

_run_watch() { # comme run_capture, avec la phase et la durée à l'écran
  local label="$1"; shift
  local rc=0
  PROV_LAST_OUT=""
  if [[ "${PROV_VERBOSE:-0}" -eq 1 ]]; then
    p_step "$label"
    "$@" || rc=$?
    PROV_LAST_RC="$rc"
    return "$rc"
  fi
  local t0="$SECONDS" phase="" prev="" el
  PROV_LAST_OUT="$(mktemp "${TMPDIR:-/tmp}/prov-out.XXXXXX")"
  "$@" >"$PROV_LAST_OUT" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    phase="$(_prov_phase_of "$PROV_LAST_OUT")"
    el="$(printf '%02d:%02d' "$(( (SECONDS - t0) / 60 ))" "$(( (SECONDS - t0) % 60 ))")"
    if [[ -t 1 ]]; then
      printf '\r\033[K%s>>%s    %s: %s · %s · %s' "$_PC" "$_PN" "$PROV_MODULE_TAG" "$label" "$phase" "$el"
    elif [[ "$phase" != "$prev" ]]; then
      printf '%s>>%s    %s: %s · %s\n' "$_PC" "$_PN" "$PROV_MODULE_TAG" "$label" "$phase"
    fi
    prev="$phase"
    sleep 1
  done
  wait "$pid" || rc=$?
  [[ -t 1 ]] && printf '\r\033[K'
  [[ "$rc" -ne 0 ]] || { rm -f "$PROV_LAST_OUT"; PROV_LAST_OUT=""; }
  PROV_LAST_RC="$rc"
  return "$rc"
}

run_step() { # run_step [--ok N]… <label> -- <cmd…> — un code listé rend 0 sans verdict : l'appelant le qualifie sur PROV_LAST_RC
  local ok_codes=()
  while [[ "${1:-}" == "--ok" ]]; do ok_codes+=("${2:?--ok attend un code}"); shift 2; done
  local label="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  local rc=0 c
  _run_watch "$label" "$@" || rc=$?
  for c in "${ok_codes[@]}"; do
    [[ "$rc" == "$c" ]] || continue
    [[ -z "$PROV_LAST_OUT" ]] || rm -f "$PROV_LAST_OUT"
    PROV_LAST_OUT=""
    return 0
  done
  [[ "$rc" -eq 0 ]] || { p_fail "commande en échec (rc=$rc) : $label"; prov_dump_last; }
  return "$rc"
}

prov_parse_remote() {
  local url="$1" rest host path owner repo

  case "$url" in
    *://*)
      rest="${url#*://}"
      ;;
    *:*/*)
      rest="${url%%:*}/${url#*:}"
      ;;
    *)
      return 1
      ;;
  esac

  case "${rest%%/*}" in
    *:*@*) return 1 ;;
  esac
  rest="${rest#*@}"

  host="${rest%%/*}"
  path="${rest#*/}"
  host="${host%%:*}"       # port ignore : il ne change pas QUI l'on contacte
  host="${host,,}"         # les hotes sont insensibles a la casse, les chemins non
  path="${path%.git}"
  path="${path%/}"

  [[ -n "$host" && "$path" == */* ]] || return 1
  owner="${path%%/*}"
  repo="${path#*/}"
  [[ -n "$owner" && -n "$repo" && "$repo" != */* ]] || return 1

  printf '%s/%s/%s\n' "$host" "$owner" "$repo"
}

prov_lock_path() {
  local dir uid scope="${1:-}"
  uid="$(id -u)"

  if [[ -n "$scope" && ! "$scope" =~ ^[A-Za-z0-9._-]+$ ]]; then
    p_fail "verrou : portée « $scope » hors charset — refusée"
    return 1
  fi

  if [[ "$uid" -eq 0 ]]; then
    dir=/run/lock/lcars
  else
    dir="${XDG_RUNTIME_DIR:-/run/user/$uid}/lcars"
  fi

  prov_refuse_symlink_path "$dir" || return 1

  local parent="${dir%/*}"
  [[ -d "$parent" ]] || { p_fail "verrou : $parent absent — pas d'emplacement sûr pour un verrou"; return 1; }
  mkdir -p "$dir" || { p_fail "verrou : dossier impossible : $dir"; return 1; }
  chmod 0700 "$dir" || { p_fail "verrou : chmod 0700 refusé : $dir"; return 1; }

  local owner mode
  owner="$(stat -c '%u' "$dir")" || { p_fail "verrou : stat impossible : $dir"; return 1; }
  mode="$(stat -c '%a' "$dir")" || { p_fail "verrou : stat impossible : $dir"; return 1; }
  [[ "$owner" == "$uid" ]] || { p_fail "verrou : $dir appartient à l'uid $owner, pas à $uid"; return 1; }
  [[ "$mode" == "700" ]] || { p_fail "verrou : $dir est en $mode, attendu 700"; return 1; }

  local lock="$dir/provision${scope:+.$scope}.lock"
  [[ -L "$lock" ]] && { p_fail "verrou : $lock est un symlink — refusé"; return 1; }

  printf '%s\n' "$lock"
}

prov_refuse_symlink_path() {
  local path="$1" cur="" part
  local -a parts

  [[ "$path" == /* ]] || {
    p_fail "mutation privilégiée refusée — chemin relatif : $path"
    return 1
  }

  IFS='/' read -ra parts <<< "${path#/}"

  for part in "${parts[@]}"; do
    [[ -z "$part" ]] && continue
    cur="$cur/$part"
    if [[ -L "$cur" ]]; then
      p_fail "mutation privilégiée refusée — composant symlink : $cur -> $(readlink "$cur")"
      return 1
    fi
  done

  return 0
}

write_atomic() {
  local dest="$1" mode="$2" owner="${3:-}"
  local dir tmp
  owner="$(prov_owner "$owner")"
  prov_refuse_symlink_path "$dest" || return 1
  dir="$(dirname "$dest")"
  [[ -d "$dir" ]] || { p_fail "write_atomic : dossier absent : $dir"; return 1; }
  tmp="$(mktemp "$dir/.prov.XXXXXX")" || { p_fail "write_atomic : tmp impossible dans $dir"; return 1; }
  cat > "$tmp" || { rm -f "$tmp"; p_fail "write_atomic : écriture du tampon ratée (disque plein ? quota ?) : $dest"; return 1; }
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    ensure_mode "$dest" "$mode" "$owner"   # le contenu est bon ; mode/owner convergés à part
    return $?
  fi
  chmod "$mode" "$tmp" || { rm -f "$tmp"; p_fail "write_atomic: chmod $mode: $dest"; return 1; }
  if [[ -n "$owner" ]]; then
    chown "$owner" "$tmp" || { rm -f "$tmp"; p_fail "write_atomic: chown $owner: $dest"; return 1; }
  fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; p_fail "write_atomic: mv final: $dest"; return 1; }
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "$dest"
}

prov_owner() { # prov_owner <user[:group]> → user:group — « user: » prend le groupe de connexion de user ; les coreutils uutils (Ubuntu 26.04) ignorent la forme nue
  local o="$1" g
  [[ "$o" == *: ]] || { printf '%s' "$o"; return 0; }
  g="$(id -gn -- "${o%:}" 2>/dev/null)" || { printf '%s' "$o"; return 0; }
  printf '%s:%s' "${o%:}" "$g"
}

ensure_mode() {
  local path="$1" mode="$2" owner="${3:-}"
  local cur_mode cur_owner want_owner changed=0
  owner="$(prov_owner "$owner")"
  prov_refuse_symlink_path "$path" || return 1
  [[ -e "$path" ]] || { p_fail "ensure_mode: absent: $path"; return 1; }
  cur_mode="$(stat -c '%a' "$path")"
  local want_mode="${mode#0}"
  if [[ "$cur_mode" != "$want_mode" ]]; then
    chmod u-s,g-s,o-t "$path" 2>/dev/null || true
    chmod "$mode" "$path" || { p_fail "ensure_mode: chmod $mode refusé: $path"; return 1; }
    changed=1
  fi
  if [[ -n "$owner" ]]; then
    cur_owner="$(stat -c '%U:%G' "$path")"
    want_owner="$owner"
    if [[ "$cur_owner" != "$want_owner" ]]; then
      chown "$owner" "$path" || { p_fail "ensure_mode: chown $owner refusé: $path"; return 1; }
      changed=1
    fi
  fi
  cur_mode="$(stat -c '%a' "$path")"
  [[ "$cur_mode" == "$want_mode" ]] || { p_fail "ensure_mode: mode $cur_mode ≠ $want_mode après chmod: $path"; return 1; }
  if [[ "$changed" -eq 1 ]]; then PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "perms $mode ${owner:+$owner }$path"; fi
  return 0
}

ensure_dir() {
  local path="$1" mode="$2" owner="${3:-}"
  prov_refuse_symlink_path "$path" || return 1
  if [[ ! -d "$path" ]]; then
    mkdir -p "$path" || { p_fail "ensure_dir: mkdir refusé: $path"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "dir $path"
  fi
  ensure_mode "$path" "$mode" "$owner"
}

prov_scaffold_dir() { # prov_scaffold_dir <chemin> <mode> [owner] — un repertoire de travail, hors journal
  local path="$1" mode="$2" owner="${3:-}"
  owner="$(prov_owner "$owner")"
  prov_refuse_symlink_path "$path" || return 1
  [[ -d "$path" ]] || mkdir -p "$path" || { p_fail "prov_scaffold_dir: mkdir refusé: $path"; return 1; }
  chmod "$mode" "$path" || { p_fail "prov_scaffold_dir: chmod $mode refusé: $path"; return 1; }
  [[ -z "$owner" ]] || chown "$owner" "$path" || { p_fail "prov_scaffold_dir: chown $owner refusé: $path"; return 1; }
  return 0
}
prov_promote_dir() { # prov_promote_dir <échafaudage> <final> — un final existant est échangé en un seul renommage (coreutils 9.5) : il ne manque à aucun instant
  local from="$1" to="$2"
  [[ -d "$from" ]] || { p_fail "prov_promote_dir : échafaudage absent : $from"; return 1; }
  [[ -n "$to" && "$to" != / ]] || { p_fail "prov_promote_dir : destination vide ou racine"; return 1; }
  if [[ -e "$to" || -L "$to" ]]; then
    mv --exchange -T -- "$from" "$to" || { p_fail "prov_promote_dir : bascule refusée : $from → $to"; return 1; }
    rm -rf -- "$from"
  else
    mv -T -- "$from" "$to" || { p_fail "prov_promote_dir : bascule refusée : $from → $to"; return 1; }
  fi
  return 0
}

prov_manifest_gid() {
  local grp="$1" f="${LCARS_SYSTEM_MANIFEST:-$(dirname "$PROVISION_LIB")/../system.manifest}"
  [[ -r "$f" ]] || return 0
  awk -v g="$grp" '{ c=$1; sub(/:.*/, "", c) } c=="group" && $2==g && $3!="-" { print $3; exit }' "$f"
}

prov_substrate_satisfait() { # <liste> [substrat] -> 0 si le substrat est couvert par la liste
  local liste="$1" sub="${2:-${PROV_SUBSTRATE:-$(detect_substrate)}}" mot
  [[ "$liste" == any ]] && return 0
  liste="${liste//+/ }"
  for mot in $liste; do
    [[ "$mot" == "$sub" ]] && return 0
  done
  return 1
}

prov_manifest_substrate() {
  local path="$1" f="${LCARS_SYSTEM_MANIFEST:-$(dirname "$PROVISION_LIB")/../system.manifest}"
  [[ -r "$f" ]] || return 0
  awk -v p="$path" '$1 !~ /^#/ && $2==p { print $5; exit }' "$f"
}

prov_manifest_mode() {
  local path="$1" f="${LCARS_SYSTEM_MANIFEST:-$(dirname "$PROVISION_LIB")/../system.manifest}"
  [[ -r "$f" ]] || return 0
  awk -v p="$path" '$1 !~ /^#/ && $1 !~ /(^|:)unset(:|$)/ && $2==p && $3!="-" { print $3; exit }' "$f"
}
prov_manifest_owner() {
  local path="$1" f="${LCARS_SYSTEM_MANIFEST:-$(dirname "$PROVISION_LIB")/../system.manifest}"
  [[ -r "$f" ]] || return 0
  awk -v p="$path" '$1 !~ /^#/ && $2==p && $4!="-" { print $4; exit }' "$f"
}

ensure_group() {
  local grp="$1" gid="${2:-}"
  [[ -n "$gid" ]] || gid="$(prov_manifest_gid "$grp")"
  if ! getent group "$grp" >/dev/null; then
    local -a args=()
    [[ -n "$gid" ]] && args+=(-g "$gid")
    run_quiet groupadd "${args[@]}" "$grp" || return 1
    getent group "$grp" >/dev/null || { p_fail "groupe $grp absent après groupadd"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "groupe $grp${gid:+ (gid $gid, table)}"
    return 0
  fi
  local cur; cur="$(getent group "$grp" | cut -d: -f3)"
  [[ -z "$gid" || "$cur" == "$gid" ]] \
    || p_drift "groupe $grp : gid $cur, la table déclare $gid — une machine ne se renumérote pas, elle se recrée"
}

prov_pgrep_pattern() { # prov_pgrep_pattern <chaine> -> le motif ERE qui ne matche pas son porteur
  local s="$1"; printf '[%s]%s\n' "${s:0:1}" "${s:1}"
}

prov_in_group() { # prov_in_group <user> <groupe> -> 0 si <user> est membre de <groupe> (session : id -nG)
  local groups; groups="$(id -nG "$1" 2>/dev/null)" || return 1
  [[ " $groups " == *" $2 "* ]]
}

ensure_member() {
  local user="$1" grp="$2"
  id "$user" >/dev/null 2>&1 || { p_fail "ensure_member: user inconnu: $user"; return 1; }
  if ! prov_in_group "$user" "$grp"; then
    run_quiet usermod -aG "$grp" "$user" || return 1
    prov_in_group "$user" "$grp" || { p_fail "$user toujours hors de $grp après usermod"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "$user ∈ $grp (effectif au prochain login — ou « sg $grp -c '<cmd>' » dans cette session)"
  fi
}

ensure_symlink() {
  local link="$1" target="$2"
  prov_refuse_symlink_path "$(dirname "$link")" || return 1
  if [[ -L "$link" ]]; then
    [[ "$(readlink "$link")" == "$target" ]] && return 0
  elif [[ -e "$link" ]]; then
    p_fail "ensure_symlink: $link existe et n'est pas un symlink — refus d'écraser, à retirer explicitement"
    return 1
  fi
  ln -sfn "$target" "$link" || { p_fail "ensure_symlink: ln refusé: $link"; return 1; }
  [[ "$(readlink "$link")" == "$target" ]] || { p_fail "ensure_symlink: cible inattendue après ln: $link"; return 1; }
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "$link → $target"
}

ensure_managed_block() {
  local file="$1" marker="$2" mode="$3" owner="${4:-}"
  local begin="# >>> lcars:${marker} >>> (bloc géré par deploy — édition manuelle écrasée au prochain apply)"
  local end="# <<< lcars:${marker} <<<"
  local block existing
  block="$(cat)"
  existing=""
  [[ -f "$file" ]] && existing="$(awk -v b="# >>> lcars:${marker} >>>" -v e="$end" '
      index($0, b) == 1 {skip=1; next}
      $0 == e            {skip=0; next}
      !skip              {print}
    ' "$file")"
  local tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/prov-block.XXXXXX")" || { p_fail "ensure_managed_block : tmp impossible"; return 1; }
  {
    if [[ -n "$existing" ]]; then printf '%s\n' "$existing"; fi
    printf '%s\n%s\n%s\n' "$begin" "$block" "$end"
  } > "$tmp"
  write_atomic "$file" "$mode" "$owner" < "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

fetch_verify() {
  local url="$1" sha="$2" dest="$3" mode="$4"
  local dir tmp actual
  dir="$(dirname "$dest")"
  tmp="$(mktemp "$dir/.fetch.XXXXXX")" || { p_fail "fetch_verify : tmp impossible dans $dir"; return 1; }
  if ! run_capture curl -fsSL --proto '=https' -m 300 -o "$tmp" "$url"; then
    rm -f "$tmp"; p_fail "fetch_verify : téléchargement raté : $url"; prov_dump_last; return 1
  fi
  actual="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$actual" != "$sha" ]]; then
    rm -f "$tmp"
    p_fail "fetch_verify : sha256 différent pour $url"
    p_fail "  attendu : $sha"
    p_fail "  trouvé  : $actual"
    return 1
  fi
  if ! { chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"; }; then
    rm -f "$tmp"; p_fail "fetch_verify: pose finale ratée: $dest"; return 1
  fi
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "$dest (sha256 vérifié)"
}

prov_journal_note() { # prov_journal_note <clef> <valeur…>
  [[ -n "${PROV_JOURNAL_ACC:-}" ]] || return 0
  [[ "$#" -ge 2 ]] || return 0
  printf '%s %s\n' "$1" "${*:2}" 2>/dev/null >> "$PROV_JOURNAL_ACC" || true
  return 0
}

prov_announce_credential() { # prov_announce_credential <libellé> <login> <secret>
  [[ "$#" -ge 3 ]] || return 0
  if [[ -n "${PROV_ANNOUNCE_FILE:-}" ]]; then
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" 2>/dev/null >> "$PROV_ANNOUNCE_FILE" || true
    return 0
  fi
  prov_print_credentials <<< "$(printf '%s\t%s\t%s\n' "$1" "$2" "$3")"
}

_prov_pad() { # <texte> <colonnes>
  local s="$1" n=$(( $2 - ${#1} ))
  (( n < 0 )) && n=0
  printf '%s%*s' "$s" "$n" ''
}

_prov_box_plain() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }
_prov_box_pad() { # <texte> <largeur>
  local p n; p="$(_prov_box_plain "$1")"; n=$(( $2 - ${#p} )); (( n < 0 )) && n=0
  printf '%s%*s' "$1" "$n" ''
}
prov_box_emit() {
  local _sep=0
  if [[ "${1:-}" == "--rule" ]]; then _sep=1; shift; fi
  local _title="$1"; shift
  local _w=57 _l _p _rule
  for _l in "$_title" "$@"; do _p="$(_prov_box_plain "$_l")"; (( ${#_p} > _w )) && _w=${#_p}; done
  _rule="$(printf '%*s' "$_w" '' | sed 's/ /─/g')"
  printf '%s  ┌%s┐\n' "$_PC" "$_rule"
  printf '  │%s%s%s│\n' "$_PG" "$(_prov_box_pad "$_title" "$_w")" "$_PC"
  if (( _sep )); then printf '  ├%s┤\n' "$_rule"; fi
  for _l in "$@"; do printf '  │%s%s%s│\n' "$_PN" "$(_prov_box_pad "$_l" "$_w")" "$_PC"; done
  printf '  └%s┘%s\n' "$_rule" "$_PN"
}

prov_print_credentials() { # lit des lignes « libellé<TAB>login<TAB>secret » sur stdin
  local lbl login secret n=0
  while IFS=$'\t' read -r lbl login secret; do
    [[ -n "$secret" ]] || continue
    if [[ "$n" -eq 0 ]]; then
      printf '\n'
      printf '    ┌──────────────────────────────────────────────────────────────┐\n'
      printf '    │  IDENTIFIANTS — à noter maintenant, ils ne seront pas redits  │\n'
      printf '    ├──────────────────────────────────────────────────────────────┤\n'
    else
      printf '    │%s│\n' "$(_prov_pad '' 62)"
    fi
    n=$((n + 1))
    printf '    │  %s│\n' "$(_prov_pad "$lbl" 60)"
    printf '    │    login       : %s│\n' "$(_prov_pad "$login" 44)"
    printf '    │    mot de passe: %s│\n' "$(_prov_pad "$secret" 44)"
  done
  [[ "$n" -eq 0 ]] && return 0
  printf '    └──────────────────────────────────────────────────────────────┘\n\n'
  return 0
}

pkg_installed() { # pkg_installed <paquet> — 0 seulement s'il est REELLEMENT installe
  [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == "installed" ]]
}

APT_ACQUIRE_OPTS=(-o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=2)

apt_mirror_diag() {
  local u h
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    if curl -fsI -m 10 -o /dev/null "$u/" 2>/dev/null; then
      p_warn "apt: le miroir $u répond — l'échec est ailleurs (paquet, signature, espace disque) : la sortie d'apt ci-dessus le dit"
      continue
    fi
    case "$u" in
      http://*)
        h="https://${u#http://}"
        if curl -fsI -m 10 -o /dev/null "$h/" 2>/dev/null; then
          p_fail "apt: $u injoignable en http alors que $h répond — passer les sources apt en https (URIs: de /etc/apt/sources.list.d/*.sources) et relancer"
        else
          p_fail "apt: $u injoignable, en http comme en https — réseau, proxy ou DNS de cette machine"
        fi ;;
      *) p_fail "apt: $u injoignable — réseau, proxy ou DNS de cette machine" ;;
    esac
  done < <(apt-get indextargets --format '$(URI)' 2>/dev/null | sed -n 's|^\(https\?://[^/]*\)/.*|\1|p' | sort -u)
}

apt_ensure() {
  local missing=() already=() pkg
  for pkg in "$@"; do
    if pkg_installed "$pkg"; then already+=("$pkg"); else missing+=("$pkg"); fi
  done
  [[ "${#already[@]}" -gt 0 ]] && prov_journal_note apt_already "${already[@]}"
  [[ "${#missing[@]}" -eq 0 ]] && return 0
  p_chg "apt: install ${missing[*]}"
  run_quiet env DEBIAN_FRONTEND=noninteractive apt-get update "${APT_ACQUIRE_OPTS[@]}" -qq \
    || { apt_mirror_diag; return 1; }
  run_quiet env DEBIAN_FRONTEND=noninteractive apt-get install "${APT_ACQUIRE_OPTS[@]}" -y --no-install-recommends "${missing[@]}" \
    || { apt_mirror_diag; return 1; }
  local rc=0 posed=()
  for pkg in "${missing[@]}"; do
    if pkg_installed "$pkg"; then
      posed+=("$pkg")
    else
      p_fail "apt: $pkg toujours absent après install"; rc=1
    fi
  done
  [[ "${#posed[@]}" -gt 0 ]] && prov_journal_note apt_installed "${posed[@]}"
  [[ "$rc" -eq 0 ]] && PROV_CHANGED=$((PROV_CHANGED + 1))
  return "$rc"
}

PROV_ADVERTISE=""
PROV_ADVERTISE_WHY=""
PROV_LAST_RC=0
PROV_LAST_OUT=""

wsl_networking_mode() {
  [[ -n "${LCARS_WSL_NETWORKING_MODE:-}" ]] && { echo "$LCARS_WSL_NETWORKING_MODE"; return 0; }
  local m
  m="$(wslinfo --networking-mode 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$m" ]] && { echo "$m"; return 0; }
  echo nat
}

lan_addr() { ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1 || true; }

advertise_addr() {
  local bind="${1:-0.0.0.0}"
  PROV_ADVERTISE=""; PROV_ADVERTISE_WHY=""
  case "$bind" in
    0.0.0.0|::|"*") ;;
    *) PROV_ADVERTISE="$bind"; return 0 ;;
  esac
  local _sub="${PROV_SUBSTRATE:-$(detect_substrate)}"
  if [[ "$_sub" == "wsl" && "$(wsl_networking_mode)" == "nat" ]]; then
    PROV_ADVERTISE="localhost"
    PROV_ADVERTISE_WHY="WSL2 en mode NAT (le défaut) — l'adresse de la VM n'est routée depuis aucune autre machine et change à chaque redémarrage de WSL ; localhost est le relais que Windows tient vers elle. Sous ce substrat, un déploiement est joignable de CETTE machine et pas du LAN : c'est du test/dev, et l'ouvrir demanderait de toucher au réseau Hyper-V du poste."
    return 0
  fi
  PROV_ADVERTISE="$(lan_addr)"
  if [[ -z "$PROV_ADVERTISE" ]]; then
    PROV_ADVERTISE="127.0.0.1"
    PROV_ADVERTISE_WHY="aucune adresse de sortie détectée — les liens ne valent que sur cette machine"
  fi
  return 0
}

port_taken() { # port_taken <port> -> 0 si quelque chose écoute sur la loopback
  timeout 2 bash -c "</dev/tcp/127.0.0.1/$1" 2>/dev/null
}

port_holder() {
  local port="$1" bin name proj
  bin="${PROV_DOCKER_BIN:-${DOCKER_BIN:-docker}}"
  if command -v "$bin" >/dev/null 2>&1 && timeout 2 "$bin" version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    name="$(timeout 5 "$bin" ps --filter "publish=$port" --format '{{.Names}}' 2>/dev/null | head -1)"
    if [[ -n "$name" ]]; then
      proj="$(timeout 5 "$bin" inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null || true)"
      printf '%s (projet %s)\n' "$name" "${proj:-<hors compose>}"
      return 0
    fi
  fi
  command -v ss >/dev/null 2>&1 || return 0
  ss -ltnp 2>/dev/null \
    | awk -v p=":$port\$" '$4 ~ p { for (i=1;i<=NF;i++) if ($i ~ /users:/) { print $i; exit } }' \
    | sed -e 's/users:((//' -e 's/))$//' -e 's/,fd=[0-9]*//' | head -1
  return 0
}

port_state() {
  local port="$1" tenu own proj; shift
  tenu="$(port_holder "$port")"
  if [[ "$tenu" == *"(projet "* ]]; then
    proj="${tenu##*(projet }"; proj="${proj%)}"
    for own in "$@"; do [[ "$proj" == "$own" ]] && { printf 'nous %s\n' "$tenu"; return 0; }; done
  fi
  if [[ -n "$tenu" ]]; then printf 'pris par %s\n' "$tenu"
  elif port_taken "$port"; then echo pris
  else echo libre
  fi
  return 0
}

as_human() {
  local home
  home="$(getent passwd "$PROV_HUMAN" | cut -d: -f6 || true)"
  [[ -n "$home" ]] || { p_fail "as_human: user inconnu: $PROV_HUMAN"; return 1; }
  if [[ "$(id -un)" == "$PROV_HUMAN" ]]; then
    "$@"
  elif [[ "$EUID" -eq 0 ]]; then
    ( cd "$home" && runuser -u "$PROV_HUMAN" -- env HOME="$home" USER="$PROV_HUMAN" LOGNAME="$PROV_HUMAN" "$@" )
  else
    p_fail "as_human: appelé par $(id -un), ni root ni $PROV_HUMAN — à relancer en root"
    return 1
  fi
}

human_home() { getent passwd "$PROV_HUMAN" | cut -d: -f6 || true; }

PROV_UID_MIN="" PROV_UID_MAX="" PROV_UID_BOUNDS_WHY=""
_PROV_UID_BOUNDS_SAID=""
prov_uid_bounds() { # pose PROV_UID_MIN et PROV_UID_MAX depuis login.defs — 0 si les deux se lisent ; 1 sinon, remede dans PROV_UID_BOUNDS_WHY, dit une fois
  local defs="${PASSWD_DEFS:-/etc/login.defs}" manque=""
  PROV_UID_MIN="$(awk '$1 == "UID_MIN" {print $2; exit}' "$defs" 2>/dev/null || true)"
  PROV_UID_MAX="$(awk '$1 == "UID_MAX" {print $2; exit}' "$defs" 2>/dev/null || true)"
  [[ "$PROV_UID_MIN" =~ ^[0-9]+$ ]] || manque=UID_MIN
  [[ -n "$manque" || "$PROV_UID_MAX" =~ ^[0-9]+$ ]] || manque=UID_MAX
  if [[ -z "$manque" ]]; then PROV_UID_BOUNDS_WHY=""; return 0; fi
  PROV_UID_MIN="" PROV_UID_MAX=""
  # phrase identique à celle du protocole du produit (module-protocol.sh), que ses témoins épinglent sans accents
  PROV_UID_BOUNDS_WHY="la frontiere systeme/humain n'est pas etablie ($manque illisible dans $defs) — la borne est declaree par le systeme, pas par ce processus : repare $defs"
  if [[ -z "$_PROV_UID_BOUNDS_SAID" ]]; then
    _PROV_UID_BOUNDS_SAID=1
    p_warn "$PROV_UID_BOUNDS_WHY"
  fi
  return 1
}

prov_seat_uid() { # rend l'uid du siège, ou 1 si aucune source ne l'établit
  local f v
  f="${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}"
  if [[ -r "$f" ]]; then
    v="$(head -n1 -- "$f" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
  fi
  v="${LCARS_SYSADMIN_UID:-}"
  [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
  return 1
}

is_fleet_human() { # [login] (défaut: PROV_HUMAN) — 0 si oui
  local login="${1:-$PROV_HUMAN}" uid seat
  uid="$(id -u -- "$login" 2>/dev/null || true)"
  [[ "$uid" =~ ^[0-9]+$ ]] || return 1
  seat="$(prov_seat_uid)" || return 1
  prov_uid_bounds || return 1
  (( uid >= PROV_UID_MIN && uid <= PROV_UID_MAX )) && (( uid != seat ))
}

fleet_humans() {
  local seat
  seat="$(prov_seat_uid)" || {
    echo "fleet_humans: siège non établi (ni ${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}, ni LCARS_SYSADMIN_UID) — population non mesurable" >&2
    return 1
  }
  prov_uid_bounds || return 1
  awk -F: -v m="$PROV_UID_MIN" -v M="$PROV_UID_MAX" -v s="$seat" \
      '$3+0 >= m && $3+0 <= M && $3+0 != s {print $1}' "${PASSWD_FILE:-/etc/passwd}"
}

repo_root() { readlink -f "$(dirname "$PROVISION_LIB")/../.."; }
product_tree() { local r; r="$(repo_root)"; if [[ -d "$r/runtime" && ! -e "$r/services" ]]; then printf '%s' "$r/runtime"; else printf '%s' "$r"; fi; }

PROV_SOURCE_STAMP="${LCARS_SOURCE_STAMP:-.source-revision}"

PROV_HELPERS_STAMP="${LCARS_HELPERS_STAMP:-.helpers-revision}"

prov_source_rev() { # prov_source_rev [racine] — la révision de l'arbre, ou « inconnue »
  local root="${1:-$(repo_root)}" rev
  if rev="$(git -C "$root" rev-parse --short=8 HEAD 2>/dev/null)" && [[ -n "$rev" ]]; then
    git -C "$root" diff --quiet HEAD -- 2>/dev/null || rev="$rev+local"
    printf '%s\n' "$rev"
    return 0
  fi
  if [[ -r "$root/$PROV_SOURCE_STAMP" ]]; then
    printf '%s\n' "$(head -n1 "$root/$PROV_SOURCE_STAMP" | tr -d '[:space:]')"
    return 0
  fi
  printf 'inconnue\n'
}

PROV_REMEMBERED=(PROV_DECK_PORT PROV_FORGE_HOST_PORT PROV_SSH_PORT PROV_FORGE_BASE)

prov_params_line() { # la ligne `params` du journal : `NOM=valeur …`, seulement ce qui differe
  local n out=""
  for n in "${PROV_REMEMBERED[@]}"; do
    [[ -n "${!n:-}" ]] && out="$out ${n}=${!n}"
  done
  printf '%s\n' "${out# }"
}

prov_file_state() { # prov_file_state <chemin> -> present | unreadable | absent | unmeasurable
  local p="$1" d
  if [[ -e "$p" ]]; then
    [[ -r "$p" ]] && { printf 'present\n'; return 0; }
    printf 'unreadable\n'; return 0
  fi
  d="$(dirname "$p")"
  while [[ "$d" != "/" && ! -e "$d" ]]; do d="$(dirname "$d")"; done
  if [[ -x "$d" ]]; then printf 'absent\n'; else printf 'unmeasurable\n'; fi
}

prov_state_why() { # prov_state_why <etat> <chemin>
  case "$1" in
    unreadable)   printf 'présent, mais illisible pour %s — rien n'"'"'est conclu sur son contenu (à relancer sous sudo pour le mesurer)\n' "$(id -un 2>/dev/null || echo "ce compte")" ;;
    unmeasurable) printf 'NON MESURABLE ici : un répertoire du chemin (%s) n'"'"'est pas traversable par %s — ni présent ni absent, on ne sait pas\n' "$(dirname "$2")" "$(id -un 2>/dev/null || echo "ce compte")" ;;
  esac
}

prov_delivery() { # prov_delivery [racine] -> `binary` | `source`
  local root="${1:-$(repo_root)}"
  if [[ -f "$root/$PROV_SOURCE_STAMP" ]]; then printf 'binary\n'; else printf 'source\n'; fi
}

prov_delivery_is_binary() { [[ "$(prov_delivery "$@")" == "binary" ]]; }

: "${PROV_CHANNEL_FILE_CANON:=/etc/lcars/channel}"  # le chemin que deploy/system.manifest declare (anchor)
PROV_CHANNEL_FILE="${LCARS_CHANNEL_FILE:-$PROV_CHANNEL_FILE_CANON}"

prov_channel() {
  local v
  PROV_CHANNEL=""
  if [[ ! -e "$PROV_CHANNEL_FILE" ]]; then
    if [[ -d "$PROV_PREFIX" || -e "$PROV_ROOT/.source-revision" ]]; then PROV_CHANNEL=inconnu; printf 'inconnu\n'
    else PROV_CHANNEL=aucun; printf 'aucun\n'; fi
    return 0
  fi
  v="$(head -n1 "$PROV_CHANNEL_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
  case "$v" in
    source|kit) PROV_CHANNEL="$v"; printf '%s\n' "$v"; return 0 ;;
  esac
  p_fail "canal d'installation illisible : $PROV_CHANNEL_FILE porte « $v », attendu source ou kit — à corriger à la main, ou à retirer si cette machine n'a jamais été posée"
  return 1
}

prov_channel_write() {
  case "${1:-}" in
    source|kit) ;;
    *) p_fail "prov_channel_write : « ${1:-} » n'est pas un canal (source|kit)"; return 1 ;;
  esac
  local mode owner
  mode="$(prov_manifest_mode "$PROV_CHANNEL_FILE_CANON")"; : "${mode:=0644}"
  owner="${LCARS_CHANNEL_OWNER:-$(prov_manifest_owner "$PROV_CHANNEL_FILE_CANON")}"; : "${owner:=root:root}"
  write_atomic "$PROV_CHANNEL_FILE" "$mode" "$owner" <<<"$1"
}

prov_channel_here() { if prov_delivery_is_binary "$@"; then printf 'kit\n'; else printf 'source\n'; fi; }

prov_rev_is_behind() { # prov_rev_is_behind <rev_source> <rev_posee> [racine]
  local a="${1%%+*}" b="${2%%+*}" root="${3:-$(repo_root)}"
  [[ -n "$a" && -n "$b" && "$a" != "inconnue" && "$b" != "inconnue" ]] || return 2
  [[ "$a" == "$b" ]] && return 1
  git -C "$root" cat-file -e "$a^{commit}" 2>/dev/null || return 2
  git -C "$root" cat-file -e "$b^{commit}" 2>/dev/null || return 2
  git -C "$root" merge-base --is-ancestor "$a" "$b" 2>/dev/null && return 0
  return 1
}

prov_seat_from_map() { # le login du siege enregistre, ou vide
  [[ -r "$PROV_UID_MAP_FILE" ]] || return 0
  awk -F'\t' '$1 == 1 { print $3; exit }' "$PROV_UID_MAP_FILE" 2>/dev/null
}

prov_seat_record() { # prov_seat_record <login> <uid>
  local login="${1:?prov_seat_record: login requis}" uid="${2:?prov_seat_record: uid requis}"
  [[ -n "$(prov_seat_from_map)" ]] && return 0
  mkdir -p "$(dirname "$PROV_UID_MAP_FILE")" 2>/dev/null || true
  printf '1\t%s\t%s\n' "$uid" "$login" >> "$PROV_UID_MAP_FILE" 2>/dev/null || return 1
  chmod 0640 "$PROV_UID_MAP_FILE" 2>/dev/null || true
}

env_field() { sed -n "s/^${2}=//p" "$1" 2>/dev/null | tail -n1 || true; }

set_diff() {
  comm -13 <(printf '%s\n' "$1" | sed '/^$/d' | sort -u) <(printf '%s\n' "$2" | sed '/^$/d' | sort -u)
}

arch_tag() {
  local deb; deb="$(dpkg --print-architecture 2>/dev/null || true)"
  case "$1:$deb" in
    raw:*)                       echo "$deb" ;;
    debian:amd64|debian:arm64)   echo "$deb" ;;
    node:amd64)                  echo x64 ;;
    node:arm64)                  echo arm64 ;;
    *)                           echo "" ;;
  esac
}

forge_curl() {
  local tokfile="$1" tok=""; shift
  tok="$(read_token "$tokfile")"
  { [[ -n "$tok" ]] && printf 'header = "Authorization: token %s"\n' "$tok" || true; } \
    | curl -K - "$@"
}

read_token() { # read_token <fichier> — le jeton sans blancs, ou rien : jamais un message, jamais un echec
  [[ -n "${1:-}" && -r "$1" ]] && tr -d '[:space:]' < "$1"
  return 0
}

prov_forge_seat_login() {
  [[ -s "$PROV_MASTER_TOKEN_FILE" && -n "${PROV_FORGE_URL:-}" ]] || return 0
  forge_curl "$PROV_MASTER_TOKEN_FILE" -sS -m 15 "${PROV_FORGE_URL%/}/api/v1/admin/users?limit=50" 2>/dev/null \
    | jq -r 'map(select(.id == 1)) | .[0].login // empty' 2>/dev/null || true
}

PROV_SEAT_BINDING=""
PROV_SEAT_LOGIN=""
PROV_SEAT_SOURCE=""
prov_seat_binding() { # prov_seat_binding [candidat_unix]
  local candidat="${1:-}" durable source

  PROV_SEAT_BINDING=""
  PROV_SEAT_LOGIN=""
  PROV_SEAT_SOURCE=""

  durable="$(prov_seat_from_map)"
  source=table
  if [[ -z "$durable" ]]; then
    durable="$(prov_forge_seat_login)"
    source=forge
  fi

  if [[ -n "$durable" && -n "$candidat" ]]; then
    PROV_SEAT_LOGIN="$durable"
    PROV_SEAT_SOURCE="$source"
    if [[ "$durable" == "$candidat" ]]; then PROV_SEAT_BINDING=agree; else PROV_SEAT_BINDING=diverge; fi
  elif [[ -n "$durable" ]]; then
    PROV_SEAT_LOGIN="$durable"; PROV_SEAT_SOURCE="$source"; PROV_SEAT_BINDING=derived
  elif [[ -n "$candidat" ]]; then
    PROV_SEAT_LOGIN="$candidat"; PROV_SEAT_SOURCE=candidat; PROV_SEAT_BINDING=seeded
  else
    PROV_SEAT_BINDING=unknown
  fi

  return 0
}

prov_dans_la_copie() { # prov_dans_la_copie -> 0 si ce rail tourne depuis la copie posée
  [[ "$(repo_root)" == "${PROV_ROOT}" ]]
}

prov_roles() {
  local out="$PROV_ROLES" root
  local bin="${PROV_RELEASE_BIN:-$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet}"
  local entry="${PROV_LCARS_CLI:-}" c
  if [[ -z "$entry" ]]; then
    for c in "$PROV_LINK_DIR/lcars" "$(product_tree)/bin/lcars"; do
      [[ -r "$c" ]] && { entry="$c"; break; }
    done
  fi

  if [[ -n "$entry" && -r "$entry" && -x "$bin" && -d "$PROV_CATALOGUES_DIR" ]] && command -v jq >/dev/null; then
    for root in "$PROV_CATALOGUES_DIR"/*/; do
      [[ -f "${root}catalogue.yaml" ]] || continue
      out="$out $(LCARS_FLEET_BIN="$bin" bash "$entry" tool roles-tfvars "${root%/}" 2>/dev/null \
                  | jq -r '(.roles[]?, .system_roles[]?)' 2>/dev/null | tr '\n' ' ' || true)"
    done
  fi

  # shellcheck disable=SC2086 # eclatement voulu : une entree par mot
  printf '%s\n' $out | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
