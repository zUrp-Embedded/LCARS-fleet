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

HELPERS_DIR="$PROV_ROOT"
TOOLCHAIN_BIN="$PROV_LINK_DIR/lcars-toolchain-converge"
AUTHORITY_ASK_BIN="$PROV_LINK_DIR/lcars-authority-ask"
HELPERS_OWNER="$(prov_owner root:root)"
OWN=(-o "${HELPERS_OWNER%%:*}" -g "${HELPERS_OWNER##*:}")
SRC_DIR="$(product_tree)/services"
BIN_SRC_DIR="$(product_tree)/bin"
read -ra HELPERS <<<"$PROV_HELPERS"
read -ra HELPERS_DATA <<<"$PROV_HELPERS_DATA"
# les arbres embarqués à plat sous HELPERS_DIR : la copie sert à rejouer le provisionnement (repo_root y mène) et aux lecteurs du produit
read -ra EMBEDDED <<<"$PROV_EMBEDDED"
read -ra EMBEDDED_ROOT <<<"$PROV_EMBEDDED_ROOT"
SKEL_FILE="$(prov_decor /etc/skel/.bashrc)"
BASH_BASHRC="$(prov_decor /etc/bash.bashrc)"

XTERM_VERSION=5.5.0
XTERM_FIT_VERSION=0.10.0
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
helpers_stamp() { echo "$HELPERS_DIR/$PROV_HELPERS_STAMP"; }
copie_delivery_stamp() { echo "$HELPERS_DIR/$PROV_SOURCE_STAMP"; }
posed_rev() { # posed_rev → la révision d'où sort ce qui est posé, ou « inconnue »
  local f; f="$(helpers_stamp)"
  if [[ -r "$f" ]]; then head -n1 "$f" | tr -d '[:space:]' || echo inconnue; else echo inconnue; fi
}

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
tree_hors_contrat() { # tree_hors_contrat <racine> → les objets qui ne sont pas à HELPERS_OWNER, ou setgid, ou inscriptibles par le groupe ou les autres ; ce que la copie n'emporte pas n'est pas jugé
  local x
  local -a skip=()
  for x in "${EMBEDDED_EXCLUDE[@]}"; do skip+=(-name "${x#--exclude=}" -o); done
  find "$1" \( "${skip[@]}" -type l \) -prune -o \
       \( ! -user "${HELPERS_OWNER%%:*}" -o ! -group "${HELPERS_OWNER##*:}" -o -perm /2022 \) -print 2>/dev/null || true
}
check_tree_perms() { # check_tree_perms <racine>
  local root="$1" bad n first
  [[ -d "$root" ]] || return 0
  bad="$(tree_hors_contrat "$root")"
  if [[ -z "$bad" ]]; then _PERMS_OK=$((_PERMS_OK + 1)); return 0; fi
  n="$(wc -l <<<"$bad")"; first="${bad%%$'\n'*}"
  p_drift "$root : $n objet(s) hors contrat (premier : $first, $(perm_of "$first")) — propriétaire $HELPERS_OWNER, ni setgid ni écriture groupe/autres ; l'apply repose l'arbre"
}
check_perms() {
  local n name _u _s _r
  _PERMS_OK=0
  for n in "${HELPERS[@]}"; do check_perm "$HELPERS_DIR/$n" 0755 "$HELPERS_OWNER"; done
  for n in "${HELPERS_DATA[@]}"; do check_perm "$HELPERS_DIR/$n" 0644 "$HELPERS_OWNER"; done
  check_perm "$PROV_SHELL_RC" 0644 "$HELPERS_OWNER"
  check_perm "$TOOLCHAIN_BIN" 0755 "$HELPERS_OWNER"
  check_perm "$AUTHORITY_ASK_BIN" 0755 "$HELPERS_OWNER"
  check_perm "$(helpers_stamp)" 0644 "$HELPERS_OWNER"
  check_perm "$(copie_delivery_stamp)" 0644 "$HELPERS_OWNER"
  check_perm "$(deck_static_dir)" 0755 "$HELPERS_OWNER"
  while IFS=$'\t' read -r name _u _s; do check_perm "$(deck_static_dir)/$name" 0644 "$HELPERS_OWNER"; done < <(deck_static_table)
  for _r in "${EMBEDDED[@]}" "${EMBEDDED_ROOT[@]}"; do check_tree_perms "$HELPERS_DIR/$_r"; done
  [[ "$_PERMS_OK" -eq 0 ]] || p_ok "modes et propriétaires relus : $_PERMS_OK objet(s)/arbre(s) conformes à ce que l'apply pose"
  return 0
}

# les deux fichiers appartiennent à la distribution : un bloc géré, jamais un remplacement, et un raccord qui teste avant de sourcer
BLOC_SKEL="if [ -r $PROV_SHELL_RC ]; then . $PROV_SHELL_RC; fi"
# /etc/skel ne sert qu'à la création d'un compte : le PATH de tout shell interactif se règle dans bash.bashrc
BLOC_PATH='case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) if [ -d "$HOME/.local/bin" ]; then PATH="$HOME/.local/bin:$PATH"; fi ;;
esac'

bloc_conforme() { # bloc_conforme <fichier> <marqueur> <corps> → 0 si le bloc géré du fichier porte ce corps
  local corps
  corps="$(awk -v b="# >>> lcars:$2 >>>" -v e="# <<< lcars:$2 <<<" '
    index($0, b) == 1 {dedans=1; next}
    $0 == e            {dedans=0; next}
    dedans             {print}
  ' "$1" 2>/dev/null || true)"
  [[ "$corps" == "$3" ]]
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
      0) p_drift "retour en arrière : posé depuis $posed, cet arbre est $src, qui en est un ancêtre — l'apply remplacerait du code par du code plus ancien" ;;
      1) p_drift "auxiliaires posés depuis $posed, cet arbre est $src — l'apply les mettra à jour" ;;
      *) p_warn "auxiliaires posés depuis $posed, cet arbre est $src — parenté indéterminable (pas de git, ou révision inconnue de ce clone)" ;;
    esac
  fi
  if command -v ttyd >/dev/null; then
    p_ok "ttyd présent ($(ttyd --version 2>&1 | head -1))"
  else
    p_drift "ttyd absent — la console web n'a aucun serveur derrière sa socket (page noire) ; 10-packages le pose"
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
    elif ! cmp -s "$SRC_DIR/$n" "$HELPERS_DIR/$n"; then
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
  local _r
  for _r in "${EMBEDDED[@]}" "${EMBEDDED_ROOT[@]}"; do
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
  if bloc_conforme "$BASH_BASHRC" path "$BLOC_PATH"; then
    p_ok "PATH des shells interactifs : ~/.local/bin ($BASH_BASHRC)"
  else
    p_drift "$BASH_BASHRC sans le bloc PATH attendu — « claude » (~/.local/bin) est invisible d'un shell interactif"
  fi
  if bloc_conforme "$SKEL_FILE" skel "$BLOC_SKEL"; then
    p_ok "squelette des humains raccordé ($SKEL_FILE → $PROV_SHELL_RC)"
  else
    p_drift "$SKEL_FILE sans le raccord attendu vers $PROV_SHELL_RC — les nouveaux comptes n'auraient pas le réglage de shell"
  fi
  check_perms
  verdict_check
}

poser_executable() { # poser_executable <source> <destination> — une copie qui diffère est reposée et comptée, une copie identique garde son contenu
  [[ -f "$1" ]] || { p_fail "source absente : $1 (arbre incomplet)"; return 1; }
  if cmp -s "$1" "$2"; then
    ensure_mode "$2" 0755 "$HELPERS_OWNER"
    return
  fi
  install -m 0755 "${OWN[@]}" "$1" "$2" || { p_fail "pose ratée : $2"; return 1; }
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "$2"
}

poser_donnee() { # poser_donnee <source> <destination> — 0644 ; la redirection d'une source absente ne compterait aucun échec
  [[ -f "$1" ]] || { p_fail "source absente : $1 (arbre incomplet)"; return 1; }
  write_atomic "$2" 0644 < "$1"
}

embarquer() { # embarquer <source> <destination> [--exclude…] — l'arbre copié par tar (exclusions à la source) ; basculé et compté s'il diffère de ce qui est posé
  local src="$1" dst="$2"; shift 2
  rm -rf "${dst:?}.new"
  prov_scaffold_dir "$dst.new" 0755 "$HELPERS_OWNER" || return 1
  ( cd "$src" && tar -cf - "${EMBEDDED_EXCLUDE[@]}" "$@" . ) | ( cd "$dst.new" && tar --no-same-owner -xf - ) \
    || { p_fail "copie ratée : $src"; return 1; }
  chmod -R g-s,go-w "$dst.new" || { p_fail "modes de la copie non posés : $dst"; return 1; }
  if [[ -d "$dst" && -z "$(tree_hors_contrat "$dst")" ]] && diff -rq --no-dereference "$dst.new" "$dst" >/dev/null 2>&1; then
    rm -rf "$dst.new"
    return 0
  fi
  prov_promote_dir "$dst.new" "$dst" || return 1
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "arbre embarqué $dst"
}

apply() {
  local n name url sha f
  local src posed
  src="${PROV_SOURCE_REV:-$(prov_source_rev)}"
  posed="$(posed_rev)"
  if prov_rev_is_behind "$src" "$posed"; then
    p_warn "retour en arrière : $HELPERS_DIR sort de $posed, cet arbre est $src, qui en est un ancêtre — ce qui suit remplace du code par du code plus ancien, convergeur d'humains compris"
  fi

  for n in "${HELPERS[@]}"; do
    poser_executable "$SRC_DIR/$n" "$HELPERS_DIR/$n" || verdict_apply
  done
  for n in "${HELPERS_DATA[@]}"; do
    poser_donnee "$SRC_DIR/$n" "$HELPERS_DIR/$n" || verdict_apply
  done
  poser_donnee "$SRC_DIR/${PROV_SHELL_RC##*/}" "$PROV_SHELL_RC" || verdict_apply

  ensure_managed_block "$SKEL_FILE" skel 0644 <<<"$BLOC_SKEL" || verdict_apply
  ensure_managed_block "$BASH_BASHRC" path 0644 <<<"$BLOC_PATH" || verdict_apply

  poser_executable "$BIN_SRC_DIR/lcars-toolchain-converge" "$TOOLCHAIN_BIN" || verdict_apply
  poser_executable "$BIN_SRC_DIR/lcars-authority-ask" "$AUTHORITY_ASK_BIN" || verdict_apply

  for n in "${EMBEDDED[@]}"; do
    [[ -d "$(product_tree)/$n" ]] || { p_fail "source absente : $(product_tree)/$n"; verdict_apply; }
    embarquer "$(product_tree)/$n" "$HELPERS_DIR/$n" || verdict_apply
  done
  local -a _only
  for n in "${EMBEDDED_ROOT[@]}"; do
    [[ -d "$(repo_root)/$n" ]] || { p_fail "source absente : $(repo_root)/$n"; verdict_apply; }
    _only=(); [[ "$n" == deploy ]] && _only=(--exclude=./tests)
    embarquer "$(repo_root)/$n" "$HELPERS_DIR/$n" "${_only[@]}" || verdict_apply
  done

  # le tampon s'écrit après la pose : il atteste ce qui est là
  write_atomic "$(helpers_stamp)" 0644 "$HELPERS_OWNER" <<<"$src" || verdict_apply
  # la forme de la livraison se propage dans la copie, dans les deux sens : un rejeu depuis la copie la lit à sa racine
  if prov_delivery_is_binary; then
    write_atomic "$(copie_delivery_stamp)" 0644 "$HELPERS_OWNER" <<<"$src" || verdict_apply
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
