#!/usr/bin/env bash
# SOURCE: deploy/modules.d/62-runtime-helpers.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: les auxiliaires du runtime sur la machine — services, binaires du PATH, arbres embarqués sous /opt/lcars, client de terminal, réglage de shell
# APPLY-ON: wsl linux docker
# CHECK-ON: any
# NEEDS: root
# AFTER: 60-deploy

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

HELPERS_DIR="${LCARS_HELPERS_DIR:-$PROV_ROOT}"
TOOLCHAIN_BIN="${LCARS_TOOLCHAIN_CONVERGE_BIN:-/usr/local/bin/lcars-toolchain-converge}"
AUTHORITY_ASK_BIN="${LCARS_AUTHORITY_ASK_BIN:-/usr/local/bin/lcars-authority-ask}"
HELPERS_OWNER="${LCARS_HELPERS_OWNER:-root:root}"
SRC_DIR="$(product_tree)/services"
BIN_SRC_DIR="$(product_tree)/bin"
TTYD_BIN="${LCARS_TTYD_BIN:-ttyd}"
owner_args() { printf '%s\n%s\n%s\n%s\n' -o "${HELPERS_OWNER%%:*}" -g "${HELPERS_OWNER##*:}"; }

HELPERS=(
  console.sh
  console-humans.sh
  console-status.sh
  console-landing.sh
  console-deck.py
  console-pod.sh
  human-converger.sh
  forge-gestures.sh
  provision-role-tokens.sh
  catalogue-executor.py
  lcars_socket.py
  privileged-executor.py
  supervise.sh
)
SKEL_FILE="${LCARS_SKEL_FILE:-/etc/skel/.bashrc}"
BASH_BASHRC="${LCARS_BASH_BASHRC:-/etc/bash.bashrc}"
LCARS_BASHRC="${LCARS_BASHRC_FILE:-/etc/lcars/lcars.bashrc}"
DATA=(
  "console.tmux.conf $HELPERS_DIR/console.tmux.conf 0644"
  "lcars.bashrc $LCARS_BASHRC 0644"
)

XTERM_VERSION="${LCARS_XTERM_VERSION:-5.5.0}"
XTERM_FIT_VERSION="${LCARS_XTERM_FIT_VERSION:-0.10.0}"
XTERM_JS_SHA256=1f991ac3b4b283ebf96e60ae23a00a52765dd3a2e46fa6fdda9f1aab032f7495
XTERM_CSS_SHA256=ba8e6985669488981ccf40c0cefe3aba80722cb6c92de7ad628b0bd717faf2b6
XTERM_FIT_SHA256=bdaefa370b1bfc42ee88d46fe6072400902a4d4b2d45cd93438dda9b23c97089
deck_static_dir() { echo "$HELPERS_DIR/deck-static"; }
deck_static_table() {
  printf '%s\t%s\t%s\n' \
    xterm.js "https://cdn.jsdelivr.net/npm/@xterm/xterm@${XTERM_VERSION}/lib/xterm.js" "$XTERM_JS_SHA256" \
    xterm.css "https://cdn.jsdelivr.net/npm/@xterm/xterm@${XTERM_VERSION}/css/xterm.css" "$XTERM_CSS_SHA256" \
    addon-fit.js "https://cdn.jsdelivr.net/npm/@xterm/addon-fit@${XTERM_FIT_VERSION}/lib/addon-fit.js" "$XTERM_FIT_SHA256"
}

# les arbres embarqués à plat sous $HELPERS_DIR : la copie sert à rejouer le provisionnement (repo_root y mène) et aux lecteurs du produit
EMBEDDED_FLEET="$HELPERS_DIR"
EMBEDDED=(etc services bin vendor)
EMBEDDED_ROOT=(assets catalogues deploy)
# ce que la copie n'emporte pas : le cache de providers tofu, l'état et les variables de la recette (jetons), node_modules
EMBEDDED_EXCLUDE=(
  --exclude=.terraform
  --exclude=node_modules
  --exclude='*.tfstate'
  --exclude='*.tfstate.*'
  --exclude='*.tfvars'
  --exclude=crash.log
)
# le tampon des auxiliaires n'est pas .source-revision, le discriminant de livraison que prov_delivery lit à la même racine
helpers_stamp() { echo "$EMBEDDED_FLEET/${PROV_HELPERS_STAMP:-.helpers-revision}"; }
copie_delivery_stamp() { echo "$EMBEDDED_FLEET/${PROV_SOURCE_STAMP:-.source-revision}"; }
posed_rev() { # posed_rev → la révision d'où sort ce qui est posé, ou « inconnue »
  local f; f="$(helpers_stamp)"
  if [[ -r "$f" ]]; then head -n1 "$f" | tr -d '[:space:]' || echo inconnue; else echo inconnue; fi
}

helper_current() { cmp -s "$SRC_DIR/$1" "$HELPERS_DIR/$1"; }
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

_PERMS_OK=0
perm_of() { stat -c '%a %U:%G' "$1" 2>/dev/null || echo '?'; }
check_perm() { # check_perm <chemin> <mode> [owner] — relit ce qui est là contre ce que l'apply affirme
  local path="$1" want="${2#0}" owner="${3:-}" cur
  [[ -e "$path" ]] || return 0
  cur="$(perm_of "$path")"
  if [[ -n "$owner" ]]; then want="$want $owner"; else cur="${cur%% *}"; fi
  if [[ "$cur" == "$want" ]]; then _PERMS_OK=$((_PERMS_OK + 1)); return 0; fi
  p_drift "$path : $cur ≠ $want — l'apply le repose"
}
check_tree_perms() { # check_tree_perms <racine> — HELPERS_OWNER partout, ni setgid ni écriture groupe/autres ; ce que la copie n'emporte pas n'est pas jugé
  local root="$1" bad n first x
  [[ -d "$root" ]] || return 0
  local -a skip=()
  for x in "${EMBEDDED_EXCLUDE[@]}"; do skip+=(-name "${x#--exclude=}" -o); done
  bad="$(find "$root" \( "${skip[@]}" -type l \) -prune -o \
             \( ! -user "${HELPERS_OWNER%%:*}" -o ! -group "${HELPERS_OWNER##*:}" -o -perm /2022 \) -print 2>/dev/null || true)"
  if [[ -z "$bad" ]]; then _PERMS_OK=$((_PERMS_OK + 1)); return 0; fi
  n="$(wc -l <<<"$bad")"; first="${bad%%$'\n'*}"
  p_drift "$root : $n objet(s) hors contrat (premier : $first, $(perm_of "$first")) — propriétaire $HELPERS_OWNER, ni setgid ni écriture groupe/autres ; l'apply repose l'arbre"
}
check_perms() {
  local n spec d_src d_dst d_mode name _u _s _r
  _PERMS_OK=0
  for n in "${HELPERS[@]}"; do check_perm "$HELPERS_DIR/$n" 0755 "$HELPERS_OWNER"; done
  for spec in "${DATA[@]}"; do
    read -r d_src d_dst d_mode <<<"$spec"
    check_perm "$d_dst" "$d_mode" "$HELPERS_OWNER"
  done
  check_perm "$TOOLCHAIN_BIN" 0755 "$HELPERS_OWNER"
  check_perm "$AUTHORITY_ASK_BIN" 0755 "$HELPERS_OWNER"
  check_perm "$(helpers_stamp)" 0644 "$HELPERS_OWNER"
  check_perm "$(copie_delivery_stamp)" 0644 "$HELPERS_OWNER"
  check_perm "$(deck_static_dir)" 0755 "$HELPERS_OWNER"
  while IFS=$'\t' read -r name _u _s; do check_perm "$(deck_static_dir)/$name" 0644 "$HELPERS_OWNER"; done < <(deck_static_table)
  for _r in "${EMBEDDED[@]}"; do check_tree_perms "$EMBEDDED_FLEET/$_r"; done
  for _r in "${EMBEDDED_ROOT[@]}"; do check_tree_perms "$HELPERS_DIR/$_r"; done
  [[ "$_PERMS_OK" -eq 0 ]] || p_ok "modes et propriétaires relus : $_PERMS_OK objet(s)/arbre(s) conformes à ce que l'apply pose"
  return 0
}

bloc_present() { # bloc_present <fichier> <marqueur> → 0 si le bloc géré est dans le fichier
  local trouve
  trouve="$(grep -F "# >>> lcars:$2 >>>" "$1" 2>/dev/null || true)"
  [[ -n "$trouve" ]]
}

check() {
  local n f name url sha stale=0
  local src posed
  src="${PROV_SOURCE_REV:-$(prov_source_rev)}"
  posed="$(posed_rev)"
  if [[ "$posed" == "inconnue" ]]; then
    if [[ -r "$(helpers_stamp)" ]]; then
      p_drift "$(helpers_stamp) existe mais vaut « inconnue » — les auxiliaires ont été posés depuis un arbre sans révision lisible"
    else
      p_drift "$(helpers_stamp) absent — impossible de dire de quelle révision sortent les auxiliaires posés"
    fi
  elif [[ "$posed" == "$src" ]]; then
    p_ok "auxiliaires posés depuis $posed (identique à la source)"
  else
    local rc=0; prov_rev_is_behind "$src" "$posed" || rc=$?
    case "$rc" in
      0) p_fail "la source est en retard : posé depuis $posed, cet arbre est $src, qui en est un ancêtre — un apply remplacerait du code par du code plus ancien" ;;
      1) p_drift "auxiliaires posés depuis $posed, cet arbre est $src — l'apply les mettra à jour" ;;
      *) p_warn "auxiliaires posés depuis $posed, cet arbre est $src — parenté indéterminable (pas de git, ou révision inconnue de ce clone)" ;;
    esac
  fi
  if command -v "$TTYD_BIN" >/dev/null; then
    p_ok "ttyd présent ($("$TTYD_BIN" --version 2>&1 | head -1))"
  else
    p_drift "ttyd absent — la console web n'a aucun serveur derrière sa socket (page noire)"
  fi
  for n in "${HELPERS[@]}"; do
    if [[ ! -e "$HELPERS_DIR/$n" ]]; then
      p_drift "$HELPERS_DIR/$n absent"
      stale=1
    elif [[ ! -x "$HELPERS_DIR/$n" ]]; then
      p_drift "$HELPERS_DIR/$n présent mais non exécutable (mode $(stat -c '%a' "$HELPERS_DIR/$n" 2>/dev/null || echo '?')) — l'apply pose 0755"
      stale=1
    elif [[ ! -r "$SRC_DIR/$n" ]]; then
      p_warn "$HELPERS_DIR/$n : rien n'est conclu — la source est absente ou illisible ici ($SRC_DIR/$n)"
    elif ! helper_current "$n"; then
      p_drift "$HELPERS_DIR/$n diverge de la source ($SRC_DIR/$n)"
      stale=1
    fi
  done
  [[ "$stale" -eq 0 ]] && p_ok "${#HELPERS[@]} auxiliaires à jour dans $HELPERS_DIR"
  while IFS=$'\t' read -r name url sha; do
    f="$(deck_static_dir)/$name"
    if [[ ! -s "$f" ]]; then
      p_drift "client de terminal absent ($f) — la console s'ouvre sur un cadre noir, et rien à l'écran ne le dit"
    elif [[ "$(sha_of "$f")" != "$sha" ]]; then
      p_drift "$f ne correspond pas à son pin sha256"
    fi
  done < <(deck_static_table)
  if [[ -x "$TOOLCHAIN_BIN" ]]; then
    p_ok "convergeur de toolchain posé ($TOOLCHAIN_BIN)"
  else
    p_drift "$TOOLCHAIN_BIN absent — le convergeur de toolchain ne se joue pas"
  fi
  if [[ -x "$AUTHORITY_ASK_BIN" ]]; then
    p_ok "client d'autorité posé ($AUTHORITY_ASK_BIN)"
  else
    p_drift "$AUTHORITY_ASK_BIN absent — « lcars publish run », « lcars approve » et le skill system-issues n'ont aucun moyen d'obtenir un jeton de forge"
  fi
  if [[ -x "$HELPERS_DIR/deploy/provision" ]]; then
    p_ok "provisionnement embarqué posé ($HELPERS_DIR/deploy/provision)"
  else
    p_drift "provisionnement embarqué absent ($HELPERS_DIR/deploy/provision) — le convergeur ne pourra pas converger un humain"
  fi
  if [[ -d "$HELPERS_DIR/fleet" ]]; then
    p_drift "ancien arbre embarqué présent ($HELPERS_DIR/fleet) — les arbres vivent à plat sous $HELPERS_DIR ; l'apply le retire"
  fi
  local _r
  for _r in "${EMBEDDED_ROOT[@]}"; do
    if [[ -d "$HELPERS_DIR/$_r" ]]; then
      p_ok "arbre embarqué $HELPERS_DIR/$_r"
    else
      p_drift "arbre embarqué absent ($HELPERS_DIR/$_r) — un apply rejoué depuis $HELPERS_DIR/deploy/provision échouerait"
    fi
  done
  local _veut _a
  _veut="$(prov_delivery)"; _a="source"; [[ -f "$(copie_delivery_stamp)" ]] && _a="binary"
  if [[ "$_veut" == "$_a" ]]; then
    p_ok "forme de livraison propagée dans la copie ($_a)"
  else
    p_drift "la copie de $HELPERS_DIR se déclare « $_a » alors que cette source est « $_veut » — un apply rejoué depuis $HELPERS_DIR/deploy/provision poserait (ou refuserait) un toolchain à tort"
  fi
  if bloc_present "$BASH_BASHRC" path; then
    p_ok "PATH des shells interactifs : ~/.local/bin ($BASH_BASHRC)"
  else
    p_drift "$BASH_BASHRC sans le bloc PATH — « claude » (~/.local/bin) est invisible d'un shell interactif"
  fi
  if bloc_present "$SKEL_FILE" skel; then
    p_ok "squelette des humains raccordé ($SKEL_FILE → $LCARS_BASHRC)"
  else
    p_drift "$SKEL_FILE sans le raccord vers $LCARS_BASHRC — les nouveaux comptes n'auraient pas le réglage de shell"
  fi
  check_perms
  verdict_check
}

embarquer() { # embarquer <source> <destination> [--exclude…] — l'arbre copié par tar (exclusions à la source), possédé par HELPERS_OWNER, sans setgid ni écriture groupe
  local src="$1" dst="$2"; shift 2
  rm -rf "${dst:?}.new"
  prov_scaffold_dir "$dst.new" 0755 "$HELPERS_OWNER" || return 1
  ( cd "$src" && tar -cf - "${EMBEDDED_EXCLUDE[@]}" "$@" . ) | ( cd "$dst.new" && tar -xf - ) \
    || { p_fail "copie ratée: $src"; return 1; }
  chown -R "$HELPERS_OWNER" "$dst.new" 2>/dev/null || true
  chmod -R g-s,go-w "$dst.new" || { p_fail "modes de la copie non posés: $dst"; return 1; }
  prov_promote_dir "$dst.new" "$dst" || { p_fail "bascule ratée: $dst"; return 1; }
}

apply() {
  local n name url sha f
  local src posed
  src="${PROV_SOURCE_REV:-$(prov_source_rev)}"
  posed="$(posed_rev)"
  if prov_rev_is_behind "$src" "$posed"; then
    p_warn "retour en arrière : $HELPERS_DIR sort de $posed, cet arbre est $src, qui en est un ancêtre — ce qui suit remplace du code par du code plus ancien, convergeur d'humains compris"
  fi
  if command -v "$TTYD_BIN" >/dev/null; then
    p_ok "ttyd présent ($("$TTYD_BIN" --version 2>&1 | head -1))"
  else
    p_fail "ttyd absent — la console web n'aurait aucun serveur derrière sa socket (page noire) ; 10-packages le pose"
    verdict_apply
  fi

  local -a own; mapfile -t own < <(owner_args)
  ensure_dir "$HELPERS_DIR" 0755 "$HELPERS_OWNER" || verdict_apply
  for n in "${HELPERS[@]}"; do
    [[ -f "$SRC_DIR/$n" ]] || { p_fail "source absente: $SRC_DIR/$n (arbre incomplet)"; verdict_apply; }
    if helper_current "$n"; then
      ensure_mode "$HELPERS_DIR/$n" 0755 "$HELPERS_OWNER" || verdict_apply
      continue
    fi
    install -m 0755 "${own[@]}" "$SRC_DIR/$n" "$HELPERS_DIR/$n" \
      || { p_fail "pose ratée: $HELPERS_DIR/$n"; verdict_apply; }
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "$HELPERS_DIR/$n"
  done
  local spec d_src d_dst d_mode
  for spec in "${DATA[@]}"; do
    read -r d_src d_dst d_mode <<<"$spec"
    [[ -f "$SRC_DIR/$d_src" ]] || { p_fail "source absente: $SRC_DIR/$d_src (arbre incomplet)"; verdict_apply; }
    ensure_dir "$(dirname "$d_dst")" 0755 || verdict_apply
    write_atomic "$d_dst" "$d_mode" < "$SRC_DIR/$d_src" \
      || { p_fail "pose ratée: $d_dst"; verdict_apply; }
  done

  # les deux fichiers appartiennent à la distribution : un bloc géré, jamais un remplacement, et un raccord qui teste avant de sourcer
  ensure_dir "$(dirname "$SKEL_FILE")" 0755 || verdict_apply
  ensure_managed_block "$SKEL_FILE" skel 0644 <<BLOC || { p_fail "raccord du squelette non posé ($SKEL_FILE)"; verdict_apply; }
if [ -r $LCARS_BASHRC ]; then . $LCARS_BASHRC; fi
BLOC
  # /etc/skel ne sert qu'à la création d'un compte : le PATH de tout shell interactif se règle ici
  ensure_dir "$(dirname "$BASH_BASHRC")" 0755 || verdict_apply
  ensure_managed_block "$BASH_BASHRC" path 0644 <<'BLOC' || { p_fail "bloc PATH non posé ($BASH_BASHRC)"; verdict_apply; }
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) if [ -d "$HOME/.local/bin" ]; then PATH="$HOME/.local/bin:$PATH"; fi ;;
esac
BLOC

  ensure_dir "$(dirname "$TOOLCHAIN_BIN")" 0755 "$HELPERS_OWNER" || verdict_apply
  install -m 0755 "${own[@]}" "$BIN_SRC_DIR/lcars-toolchain-converge" "$TOOLCHAIN_BIN" \
    || { p_fail "pose ratée: $TOOLCHAIN_BIN"; verdict_apply; }
  ensure_dir "$(dirname "$AUTHORITY_ASK_BIN")" 0755 "$HELPERS_OWNER" || verdict_apply
  install -m 0755 "${own[@]}" "$BIN_SRC_DIR/lcars-authority-ask" "$AUTHORITY_ASK_BIN" \
    || { p_fail "pose ratée: $AUTHORITY_ASK_BIN"; verdict_apply; }

  ensure_dir "$EMBEDDED_FLEET" 0755 "$HELPERS_OWNER" || verdict_apply
  for n in "${EMBEDDED[@]}"; do
    [[ -d "$(product_tree)/$n" ]] || { p_fail "source absente: $(product_tree)/$n"; verdict_apply; }
    embarquer "$(product_tree)/$n" "$EMBEDDED_FLEET/$n" || verdict_apply
  done
  p_chg "arbres du runtime embarqués ($HELPERS_DIR/{${EMBEDDED[*]}})"
  if [[ -d "$HELPERS_DIR/fleet" ]]; then
    rm -rf "${HELPERS_DIR:?}/fleet" && p_chg "ancien arbre embarqué retiré ($HELPERS_DIR/fleet) — les arbres vivent à plat" \
      || p_fail "ancien arbre embarqué non retiré ($HELPERS_DIR/fleet)"
  fi
  local -a _only
  for n in "${EMBEDDED_ROOT[@]}"; do
    [[ -d "$(repo_root)/$n" ]] || { p_fail "source absente: $(repo_root)/$n"; verdict_apply; }
    _only=(); [[ "$n" == deploy ]] && _only=(--exclude=./tests)
    embarquer "$(repo_root)/$n" "$HELPERS_DIR/$n" "${_only[@]}" || verdict_apply
  done
  p_chg "arbres de la racine embarqués ($HELPERS_DIR/{${EMBEDDED_ROOT[*]}}, sans node_modules)"

  # le tampon s'écrit après la pose : il atteste ce qui est là
  write_atomic "$(helpers_stamp)" 0644 "$HELPERS_OWNER" <<<"$src" \
    || { p_fail "révision de source non tamponnée ($(helpers_stamp)) — la prochaine passe ne saura pas d'où sort ce qui est ici"; verdict_apply; }
  # la forme de la livraison se propage dans la copie, dans les deux sens : un rejeu depuis la copie la lit à sa racine
  if prov_delivery_is_binary; then
    write_atomic "$(copie_delivery_stamp)" 0644 "$HELPERS_OWNER" <<<"$(prov_source_rev)" \
      || { p_fail "forme de livraison non propagée ($(copie_delivery_stamp)) — un apply rejoué depuis $HELPERS_DIR se croirait en livraison source et réclamerait un toolchain"; verdict_apply; }
  elif [[ -e "$(copie_delivery_stamp)" ]]; then
    rm -f "$(copie_delivery_stamp)" \
      || { p_fail "discriminant de livraison périmé non retiré ($(copie_delivery_stamp)) — cette machine se déclarerait binaire alors qu'elle bâtit"; verdict_apply; }
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "discriminant de livraison retiré ($(copie_delivery_stamp)) — cette machine bâtit, elle ne consomme pas un paquet"
  fi

  # le réseau en dernier : une coupure ne coûte que le client de terminal, et le check le nomme
  ensure_dir "$(deck_static_dir)" 0755 "$HELPERS_OWNER" || verdict_apply
  while IFS=$'\t' read -r name url sha; do
    f="$(deck_static_dir)/$name"
    if [[ -s "$f" && "$(sha_of "$f")" == "$sha" ]]; then
      ensure_mode "$f" 0644 "$HELPERS_OWNER" || verdict_apply
      continue
    fi
    fetch_verify "$url" "$sha" "$f" 0644 || verdict_apply
  done < <(deck_static_table)
  verdict_apply
}

case "${1:?usage: 62-runtime-helpers.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
