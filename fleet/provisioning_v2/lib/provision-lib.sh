#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/lib/provision-lib.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — bibliothèque des modules : primitives convergentes, écriture atomique, verdicts réels
#
# Sourcée par CHAQUE module — qui sont des PROCESSUS SÉPARÉS, jamais un namespace partagé.
# (La v1 sourçait ses 9 modules dans UN shell sous `set -e` hérité : un chown en échec avortait
# TOUT le provisioning à mi-durcissement, et les compteurs globaux se marchaient dessus.)
#
# Contrat des primitives, les trois lois :
#   1. CONVERGENTES — elles amènent l'état déclaré et ne font RIEN s'il y est déjà.
#      Appliquer N fois = appliquer 1 fois, et re-converger vers la source COURANTE
#      (pas « append-once » : le .bashrc v1 gardait à jamais son premier état écrit).
#   2. VERDICT RÉEL — l'état est re-sondé APRÈS l'action, jamais déduit de l'intention.
#      (La v1 imprimait des `pass` inconditionnels par-dessus des setfacl étouffés en 2>/dev/null.)
#   3. ATOMIQUES — tout fichier est écrit tmp-même-dossier puis mv. Un crash ne laisse JAMAIS
#      un fichier tronqué. (La v1 écrivait /etc/sudoers.d et /etc/wsl.conf en place : un write
#      interrompu = lockout sudo fleet-wide / distro qui ne boote plus.)
#
# Toute mutation effective incrémente PROV_CHANGED (le module le rapporte en fin d'apply).
# Les commandes sont passées en ARGV, jamais en strings évaluées (le `bash -c "$fix_cmd"` v1
# interpolait des valeurs dans du code — injection dès qu'un chemin porte un métacaractère).

# Garde de double-source (un module qui se ferait sourcer deux fois ne doit pas ré-écraser l'état).
[[ -n "${PROVISION_LIB_LOADED:-}" ]] && return 0
PROVISION_LIB_LOADED=1

# ─── Données par défaut (chaque valeur est overridable par l'environnement — une SEULE définition,
#     consommée par les modules ; jamais re-défautée module par module comme en v1) ───────────────
# DOIT égaler le défaut d'etc/install.sh (SSoT du layout : etc/README.md §Install canonique —
# /local/fleet_v2 est MORT, renommé *.OBSOLETE le 2026-07-18). Un fait, deux rendus : sync à la main.
: "${PROV_PREFIX:=/local/LCARS_v2}"            # install RO du runtime (modèle 3 zones d'etc/install.sh)
: "${PROV_LINK_DIR:=/usr/local/bin}"           # symlinks PATH (miroir de LCARS_INSTALL_LINK_DIR d'install.sh)
: "${PROV_FLEET_GROUP:=fleet}"                 # groupe de lecture des tokens + de l'install RO
: "${PROV_TOKENS_DIR:=/home/private}"          # role-tokens forge (contrat FORGE_ROLE_TOKENS_DIR)
: "${PROV_FORGE_SEED_FILE:=$PROV_TOKENS_DIR/forge-seed.pass}"  # seed bootstrap tofu (handoff → A4)
: "${PROV_ROLES:=architect engineer gatekeeper qualifier reviewer scoper vulcan}"
: "${PROV_SYSTEM_ACCOUNT:=lcars-system}"       # compte forge du SYSTÈME (signe les marqueurs)
: "${PROV_FORGE_ORG:=fleet}"                   # org qui porte les repos projet (forge.tf)
: "${PROV_FORGE_URL:=${FORGE_BASE_URL:-}}"     # la forge cible ; vide = modules forge en instruct-only
# Jambe update du triangle (source→forge→runtime) : le remote à puller et le repo ATTENDU derrière.
# PROV_EXPECTED_REPO n'a PAS de défaut : l'autorité se DÉCLARE, elle ne se devine pas (héritage
# F-E1 de fleet-update v1 : vérifier le remote APRÈS le pull était une inversion de chaîne payée).
: "${PROV_UPDATE_REMOTE:=origin}"
: "${PROV_EXPECTED_REPO:=}"
# Toolchain build — pins EXACTS (bump = changer la paire version+sha ICI, nulle part ailleurs).
# Le zip est le précompilé officiel elixir-lang (assets de release, sha256sum publié à côté).
: "${PROV_ELIXIR_VERSION:=1.18.4}"
: "${PROV_ELIXIR_OTP_MAJOR:=25}"
: "${PROV_ELIXIR_ZIP_SHA256:=04ecc784c59692ce15511fbba54638d947f0566f5baf69c6542d4bf2ea89cd1a}"
# L'humain cible des modules per-humain : celui qui a lancé (à travers sudo s'il y a lieu).
: "${PROV_HUMAN:=${SUDO_USER:-$(id -un)}}"

# ─── Verdicts / log ───────────────────────────────────────────────────────────────────────────────
# Préfixe = nom du module (posé par le runner via PROVISION_MODULE, sinon dérivé de $0).
# Doctrine log LCARS : le nominal est SILENCIEUX en succès de sonde, une ligne par état constaté ;
# l'échec est VERBEUX (dump complet). Compteurs agrégés par le module.
PROV_MODULE_TAG="${PROVISION_MODULE:-$(basename "${0:-provision-lib}")}"
PROV_CHANGED=0
PROV_DRIFT=0
PROV_FAILED=0

p_ok()   { printf 'OK    %s: %s\n' "$PROV_MODULE_TAG" "$*"; }
p_chg()  { printf 'POSÉ  %s: %s\n' "$PROV_MODULE_TAG" "$*"; }
p_drift(){ printf 'DRIFT %s: %s\n' "$PROV_MODULE_TAG" "$*" >&2; PROV_DRIFT=$((PROV_DRIFT + 1)); }
p_warn() { printf 'WARN  %s: %s\n' "$PROV_MODULE_TAG" "$*" >&2; }
p_fail() { printf 'FAIL  %s: %s\n' "$PROV_MODULE_TAG" "$*" >&2; PROV_FAILED=$((PROV_FAILED + 1)); }
p_die()  { printf 'FATAL %s: %s\n' "$PROV_MODULE_TAG" "$*" >&2; exit 1; }

# Sortie standard d'un module : à appeler en FIN de check() et d'apply().
# check  : exit 0 conforme · 1 drift constaté · (2 réservé erreur de sonde, via p_die)
# apply  : exit 0 convergé · 1 au moins un échec
verdict_check() {
  if [[ "$PROV_FAILED" -gt 0 ]]; then exit 2; fi
  [[ "$PROV_DRIFT" -gt 0 ]] && exit 1
  exit 0
}
verdict_apply() {
  [[ "$PROV_FAILED" -gt 0 ]] && exit 1
  exit 0
}

# ─── run_quiet — succès silencieux, échec verbeux (l'école mail-in-a-box `hide_output`) ──────────
# La commande est un ARGV. En échec : la commande, son code, et TOUTE sa sortie sont dumpés.
# Rien n'est jamais étouffé en 2>/dev/null (le silence v1 cachait des perms cassées).
run_quiet() {
  local out rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/prov-out.XXXXXX")"
  "$@" >"$out" 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    # B1 : l'échec COMPTE — via p_fail, qui incrémente PROV_FAILED. L'ancien printf nu laissait
    # les compteurs à zéro : `run_quiet x || verdict_apply` sortait 0 (« convergé ») alors que
    # x avait échoué — le verdict vert menteur, exactement le péché v1 que cette lib jure de tuer.
    p_fail "commande en échec (rc=$rc) : $*"
    {
      printf '───── sortie complète ─────\n'
      cat "$out"
      printf '───────────────────────────\n'
    } >&2
  fi
  rm -f "$out"
  return "$rc"
}

# ─── write_atomic <dest> <mode> [owner:group] — LE primitif fichier ──────────────────────────────
# Contenu lu sur stdin. tmp dans le MÊME dossier (mv intra-FS = rename atomique), mode/owner posés
# sur le tmp AVANT le mv (le fichier n'existe jamais dans un état intermédiaire). Si le contenu,
# le mode ET l'owner sont déjà conformes : aucune écriture (mtime préservé, verdict OK).
write_atomic() {
  local dest="$1" mode="$2" owner="${3:-}"
  local dir tmp
  dir="$(dirname "$dest")"
  [[ -d "$dir" ]] || { p_fail "write_atomic: dossier absent: $dir"; return 1; }
  tmp="$(mktemp "$dir/.prov.XXXXXX")" || { p_fail "write_atomic: tmp impossible dans $dir"; return 1; }
  cat > "$tmp"
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

# ─── ensure_mode <path> <mode> [owner:group] — converge mode/owner, verdict par re-stat ──────────
# Compare AVANT d'agir (pas de chmod aveugle qui rafraîchit les ctime à chaque run), re-sonde APRÈS.
ensure_mode() {
  local path="$1" mode="$2" owner="${3:-}"
  local cur_mode cur_owner want_owner changed=0
  [[ -e "$path" ]] || { p_fail "ensure_mode: absent: $path"; return 1; }
  cur_mode="$(stat -c '%a' "$path")"
  # stat rend le mode SANS zéro de tête ; on normalise la cible pareil (0750 → 750).
  local want_mode="${mode#0}"
  if [[ "$cur_mode" != "$want_mode" ]]; then
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
  # Verdict réel : re-stat.
  cur_mode="$(stat -c '%a' "$path")"
  [[ "$cur_mode" == "$want_mode" ]] || { p_fail "ensure_mode: mode $cur_mode ≠ $want_mode après chmod: $path"; return 1; }
  if [[ "$changed" -eq 1 ]]; then PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "perms $mode ${owner:+$owner }$path"; fi
  return 0
}

# ─── ensure_dir <path> <mode> [owner:group] ──────────────────────────────────────────────────────
ensure_dir() {
  local path="$1" mode="$2" owner="${3:-}"
  if [[ ! -d "$path" ]]; then
    mkdir -p "$path" || { p_fail "ensure_dir: mkdir refusé: $path"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "dir $path"
  fi
  ensure_mode "$path" "$mode" "$owner"
}

# ─── ensure_group / ensure_member — création idempotente (le pattern propre de provision-groups v1) ─
ensure_group() {
  local grp="$1"
  if ! getent group "$grp" >/dev/null; then
    run_quiet groupadd "$grp" || return 1
    getent group "$grp" >/dev/null || { p_fail "groupe $grp absent après groupadd"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "groupe $grp"
  fi
}

ensure_member() {
  local user="$1" grp="$2"
  id "$user" >/dev/null 2>&1 || { p_fail "ensure_member: user inconnu: $user"; return 1; }
  if ! id -nG "$user" | tr ' ' '\n' | grep -qx "$grp"; then
    run_quiet usermod -aG "$grp" "$user" || return 1
    id -nG "$user" | tr ' ' '\n' | grep -qx "$grp" || { p_fail "$user toujours hors de $grp après usermod"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1))
    # usermod -aG ne prend effet qu'au PROCHAIN login (dette de guerre v1) : on le DIT.
    p_chg "$user ∈ $grp (effectif au prochain login — ou « sg $grp -c '<cmd>' » dans cette session)"
  fi
}

# ─── ensure_symlink <link> <target> — convergent (remplace un lien faux, refuse d'écraser un vrai fichier) ─
ensure_symlink() {
  local link="$1" target="$2"
  if [[ -L "$link" ]]; then
    [[ "$(readlink "$link")" == "$target" ]] && return 0
  elif [[ -e "$link" ]]; then
    p_fail "ensure_symlink: $link existe et n'est PAS un symlink — refus d'écraser (retire-le explicitement)"
    return 1
  fi
  ln -sfn "$target" "$link" || { p_fail "ensure_symlink: ln refusé: $link"; return 1; }
  [[ "$(readlink "$link")" == "$target" ]] || { p_fail "ensure_symlink: cible inattendue après ln: $link"; return 1; }
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "$link → $target"
}

# ─── ensure_managed_block <file> <marker> <mode> [owner:group] — bloc géré BEGIN/END ─────────────
# Contenu du bloc sur stdin. Le bloc ENTRE marqueurs est REMPLACÉ intégralement à chaque run →
# converge vers la source COURANTE. (Le grep-marker+append v1 convergeait vers le PREMIER état
# écrit : un bloc corrigé dans le source ne se réparait jamais chez l'installé.) Tout ce qui est
# HORS marqueurs est préservé octet pour octet (l'humain garde la main sur SON fichier).
ensure_managed_block() {
  local file="$1" marker="$2" mode="$3" owner="${4:-}"
  local begin="# >>> lcars:${marker} >>> (bloc géré par provisioning_v2 — édition manuelle écrasée au prochain apply)"
  local end="# <<< lcars:${marker} <<<"
  local block existing
  block="$(cat)"
  existing=""
  [[ -f "$file" ]] && existing="$(awk -v b="# >>> lcars:${marker} >>>" -v e="$end" '
      index($0, b) == 1 {skip=1; next}
      $0 == e            {skip=0; next}
      !skip              {print}
    ' "$file")"
  # B3 : write_atomic se nourrit par REDIRECTION, jamais par pipe — le membre droit d'un pipe
  # est un sous-shell : ses compteurs (PROV_FAILED/PROV_CHANGED) mouraient avec lui, et un
  # fichier non posé se rapportait vert.
  local tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/prov-block.XXXXXX")" || { p_fail "ensure_managed_block: tmp impossible"; return 1; }
  {
    if [[ -n "$existing" ]]; then printf '%s\n' "$existing"; fi
    printf '%s\n%s\n%s\n' "$begin" "$block" "$end"
  } > "$tmp"
  write_atomic "$file" "$mode" "$owner" < "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

# ─── fetch_verify <url> <sha256> <dest> <mode> — download pinné obligatoire ──────────────────────
# JAMAIS de download direct vers la destination (le yq v1 se téléchargeait EN PLACE : un curl
# tronqué laissait un binaire cassé installé). Mismatch = dump attendu-vs-trouvé + rm + échec
# (le workflow de bump : changer le pin, lancer, copier le sha réel depuis le message).
fetch_verify() {
  local url="$1" sha="$2" dest="$3" mode="$4"
  local dir tmp actual
  dir="$(dirname "$dest")"
  tmp="$(mktemp "$dir/.fetch.XXXXXX")" || { p_fail "fetch_verify: tmp impossible dans $dir"; return 1; }
  if ! run_quiet curl -fsSL --proto '=https' -m 300 -o "$tmp" "$url"; then
    rm -f "$tmp"; p_fail "fetch_verify: download raté: $url"; return 1
  fi
  actual="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$actual" != "$sha" ]]; then
    rm -f "$tmp"
    p_fail "fetch_verify: sha256 MISMATCH pour $url"
    p_fail "  attendu : $sha"
    p_fail "  trouvé  : $actual"
    return 1
  fi
  if ! { chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"; }; then
    rm -f "$tmp"; p_fail "fetch_verify: pose finale ratée: $dest"; return 1
  fi
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "$dest (sha256 vérifié)"
}

# ─── apt_ensure <pkg…> — le pattern MISSING-array v1 (le bon), avec verdict réel par paquet ──────
apt_ensure() {
  local missing=() pkg
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  [[ "${#missing[@]}" -eq 0 ]] && return 0
  p_chg "apt: install ${missing[*]}"
  run_quiet env DEBIAN_FRONTEND=noninteractive apt-get update -qq || return 1
  run_quiet env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" || return 1
  local rc=0
  for pkg in "${missing[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || { p_fail "apt: $pkg toujours absent après install"; rc=1; }
  done
  [[ "$rc" -eq 0 ]] && PROV_CHANGED=$((PROV_CHANGED + 1))
  return "$rc"
}

# ─── Substrat ─────────────────────────────────────────────────────────────────────────────────────
# docker : /.dockerenv (posé par le runtime Docker) ou LCARS_DOCKER=1 (posé par notre image).
# wsl    : kernel Microsoft. linux : le reste. La détection vit ICI, une fois (v1 la recopiait).
detect_substrate() {
  if [[ -f /.dockerenv || "${LCARS_DOCKER:-}" == "1" ]]; then echo docker
  elif grep -qi microsoft /proc/version 2>/dev/null; then echo wsl
  else echo linux
  fi
}

# ─── as_human <cmd…> — exécute comme PROV_HUMAN avec le HOME de PROV_HUMAN ───────────────────────
# Depuis root : runuser + env EXPLICITE (runuser sans -l garde le HOME de root — piège classique).
# Déjà cet utilisateur : exécution directe. Autre user non-root : impossible proprement → échec dit.
as_human() {
  local home
  # `|| true` : même classe que B5 — sous pipefail, getent sur un user inconnu ferait échouer
  # l'assignation avant la garde p_fail juste en dessous.
  home="$(getent passwd "$PROV_HUMAN" | cut -d: -f6 || true)"
  [[ -n "$home" ]] || { p_fail "as_human: user inconnu: $PROV_HUMAN"; return 1; }
  if [[ "$(id -un)" == "$PROV_HUMAN" ]]; then
    "$@"
  elif [[ "$EUID" -eq 0 ]]; then
    runuser -u "$PROV_HUMAN" -- env HOME="$home" USER="$PROV_HUMAN" LOGNAME="$PROV_HUMAN" "$@"
  else
    p_fail "as_human: je suis $(id -un), pas root ni $PROV_HUMAN — relance en root"
    return 1
  fi
}

# home de PROV_HUMAN (vide si inconnu — l'appelant DOIT tester). B5 : `|| true`, sinon sous
# `set -euo pipefail` (tous les modules) un user inconnu tue l'assignation `home="$(human_home)"`
# AVANT la garde p_fail de l'appelant — abort muet, le contrat « vide si inconnu » était un mensonge.
human_home() { getent passwd "$PROV_HUMAN" | cut -d: -f6 || true; }

# Racine du repo (le checkout depuis lequel on provisionne) — dérivée UNE fois de la position de
# la lib (fleet/provisioning_v2/lib/ → ../../..), jamais re-devinée par heuristique dans un module.
repo_root() { readlink -f "$(dirname "$PROVISION_LIB")/../../.."; }
