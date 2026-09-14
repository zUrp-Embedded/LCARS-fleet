#!/usr/bin/env bash
# SOURCE: deploy/modules.d/44-media.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: les médias partagés (avatars, favicon) et la doc du deck — bâtie depuis les sources, ou posée depuis le kit
# APPLY-ON: wsl linux docker
# CHECK-ON: any
# NEEDS: root
# AFTER: 16-node

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

# le même défaut que runtime/config/runtime.exs (LCARS_MEDIA_ROOT) et deck.ex (:media_root)
MEDIA_ROOT="$PROV_MEDIA_ROOT"
MEDIA_OWNER="$(prov_owner "$(prov_manifest_owner "$MEDIA_ROOT")")"
MEDIA_TREES=(avatars favicon)
MEDIA_SRC_ROOT="${LCARS_MEDIA_SRC_ROOT:-$(repo_root)/assets}"
SITE_SRC="${LCARS_SITE_SRC:-$(repo_root)/assets/github.io}"
SITE_BASE="${LCARS_SITE_BASE:-/doc/}"

media_mode() { prov_manifest_mode "$MEDIA_ROOT${1:+/$1}"; }   # media_mode [sous-arbre] → le mode que system.manifest déclare pour share[/<sous-arbre>]
media_src() { echo "$MEDIA_SRC_ROOT/$1"; }
doc_dir() { echo "$MEDIA_ROOT/doc"; }
doc_stamp() { echo "$MEDIA_ROOT/.doc-revision"; }   # à côté de doc/, que prov_promote_dir remplace en entier

media_check_perms() { # media_check_perms [sous-arbre] — mode et propriétaire relus contre la table
  local path="$MEDIA_ROOT${1:+/$1}" cur want
  [[ -d "$path" ]] || return 0
  cur="$(stat -c '%a %U:%G' "$path")"
  want="$(media_mode "${1:-}") $MEDIA_OWNER"; want="${want#0}"
  if [[ "$cur" == "$want" ]]; then
    p_ok "$path $cur (table)"
  else
    p_drift "$path : $cur ≠ $want (deploy/system.manifest) — l'apply le repose"
  fi
}

doc_empreinte() { # doc_empreinte → une signature du dist/ et de la base qui l'a bâti, ou 1 sans dist
  [[ -d "$SITE_SRC/dist" ]] || return 1
  { printf 'base=%s\n' "$SITE_BASE"
    find "$SITE_SRC/dist" -printf '%P %s %T@\n' 2>/dev/null | LC_ALL=C sort
  } | sha256sum | cut -d' ' -f1
}
doc_tampon_lit() { sed -n "s/^$1 //p" "$(doc_stamp)" 2>/dev/null | head -n1; }

doc_a_jour() { # doc_a_jour → 0 si la doc posée sort de cette révision, de cette base, et que l'arbre du site est propre
  local rev; rev="${PROV_SOURCE_REV:-$(prov_source_rev)}"
  [[ -n "$rev" && "$rev" != "inconnue" && "$rev" != *"+local" ]] || return 1
  [[ -s "$(doc_dir)/index.html" ]] || return 1
  [[ -r "$(doc_stamp)" ]] || return 1
  local sale
  sale="$(git -C "$SITE_SRC" status --porcelain --untracked-files=all -- . 2>/dev/null)" || return 1
  [[ -z "$sale" ]] || return 1
  [[ "$(doc_tampon_lit rev)" == "$rev" ]] || return 1
  [[ "$(doc_tampon_lit base)" == "$SITE_BASE" ]]
}

check() {
  local t src n
  for t in "${MEDIA_TREES[@]}"; do
    src="$(media_src "$t")"
    if [[ ! -d "$MEDIA_ROOT/$t" ]]; then
      p_drift "$MEDIA_ROOT/$t absent — la charte de forge échoue dessus, et le deck sert des icônes génériques"
      continue
    fi
    n="$(find "$MEDIA_ROOT/$t" -maxdepth 1 -type f 2>/dev/null | wc -l)"
    if [[ -d "$src" ]] && (( n < $(find "$src" -maxdepth 1 -type f | wc -l) )); then
      p_drift "$MEDIA_ROOT/$t incomplet ($n fichiers) — la source en porte plus ($src)"
    else
      p_ok "$MEDIA_ROOT/$t posé ($n fichiers)"
    fi
    media_check_perms "$t"
  done
  if [[ -s "$(doc_dir)/index.html" ]]; then
    p_ok "$(doc_dir) posée ($(find "$(doc_dir)" -type f 2>/dev/null | wc -l) fichiers)"
  else
    p_drift "$(doc_dir) absente — l'onglet Doc du deck rendra 404 (l'apply la bâtit avec le node de 16-node, ou la pose depuis le kit)"
  fi
  media_check_perms doc
  media_check_perms
  verdict_check
}

build_doc() {
  [[ -d "$SITE_SRC" ]] || { p_fail "sources du site absentes ($SITE_SRC)"; verdict_apply; }
  if prov_delivery_is_binary; then
    [[ -s "$SITE_SRC/dist/index.html" ]] \
      || { p_fail "livraison binaire sans doc bâtie ($SITE_SRC/dist) — « pack.sh » la bâtit et l'emporte ; ce paquet est une demi-livraison"; verdict_apply; }
    poser_doc
    return 0
  fi
  if prov_dans_la_copie; then
    if [[ -s "$SITE_SRC/dist/index.html" ]]; then
      poser_doc
      return 0
    fi
    p_drift "doc non bâtie dans la copie posée ($SITE_SRC/dist) — elle ne s'y reconstruit pas : relancer l'apply depuis l'arbre de travail"
    return 0
  fi
  if doc_a_jour; then
    p_ok "doc du deck à jour ($(doc_dir), révision ${PROV_SOURCE_REV:-$(prov_source_rev)}) — rien à rebâtir"
    return 0
  fi
  command -v npm >/dev/null 2>&1 \
    || { p_fail "npm absent — 16-node pose le précompilé épinglé"; verdict_apply; }
  run_step "doc du deck · dépendances (npm ci, $SITE_SRC)" -- as_human env -C "$SITE_SRC" npm ci --no-audit --no-fund \
    || verdict_apply
  run_step "doc du deck · build ($SITE_SRC)" -- as_human env -C "$SITE_SRC" LCARS_SITE_BASE="$SITE_BASE" npm run build \
    || verdict_apply
  [[ -s "$SITE_SRC/dist/index.html" ]] \
    || { p_fail "build terminé sans index.html ($SITE_SRC/dist) — rien à servir"; verdict_apply; }
  poser_doc
}

poser_doc() {
  local partial emp; partial="$(doc_dir).partial"
  emp="$(doc_empreinte || true)"
  if [[ -n "$emp" && "$emp" == "$(doc_tampon_lit dist)" && -s "$(doc_dir)/index.html" ]]; then
    p_ok "doc du deck déjà posée ($(doc_dir), base $SITE_BASE) — rien à poser"
    return 0
  fi
  rm -rf "$partial"
  prov_scaffold_dir "$partial" "$(media_mode doc)" "$MEDIA_OWNER" || verdict_apply
  find -H "$SITE_SRC/dist" -mindepth 1 -maxdepth 1 -exec cp -a -t "$partial/" {} + \
    || { p_fail "doc non copiable ($SITE_SRC/dist → $(doc_dir))"; rm -rf "$partial"; verdict_apply; }
  prov_promote_dir "$partial" "$(doc_dir)" || verdict_apply
  local rev tampon=""
  rev="${PROV_SOURCE_REV:-$(prov_source_rev)}"
  if [[ -n "$rev" && "$rev" != "inconnue" && "$rev" != *"+local" ]]; then
    tampon+="rev $rev"$'\n'"base $SITE_BASE"$'\n'
  fi
  [[ -n "$emp" ]] && tampon+="dist $emp"$'\n'
  [[ -n "$tampon" ]] && { write_atomic "$(doc_stamp)" 0644 "$MEDIA_OWNER" <<<"${tampon%$'\n'}" || true; }
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "doc du deck posée ($(doc_dir), base $SITE_BASE)"
}

media_modes() { # media_modes <racine> — l'arbre profond en 755/644, sans bits spéciaux
  local racine="${1:?media_modes: racine absente}" rc=0
  find "$racine" -mindepth 2 -type d \( -perm /7022 -o ! -perm -u=rwx -o ! -perm -go=rx \) \
    -exec chmod a-s,u=rwx,go=rx {} + || { p_warn "mode dossiers non posé sous $MEDIA_ROOT"; rc=1; }
  find "$racine" -type f \( ! -perm -a=r -o \( -perm /111 -a ! -perm -a=x \) \) \
    -exec chmod a+rX {} + || { p_warn "lecture fichiers non posée sous $MEDIA_ROOT"; rc=1; }
  return "$rc"
}

medias_a_poser() { # medias_a_poser <source> <posé> → 0 si un fichier de la source manque sous le posé, ou y diffère ; ce que le posé porte en plus ne compte pas
  local ecarts
  ecarts="$(diff -rq "$1" "$2" 2>&1)" && return 1
  grep -qvF "Only in $2" <<<"$ecarts"
}

apply() {
  local t src
  for t in "${MEDIA_TREES[@]}"; do
    src="$(media_src "$t")"
    [[ -d "$src" ]] || { p_fail "source absente : $src"; verdict_apply; }
    ensure_dir "$MEDIA_ROOT/$t" "$(media_mode "$t")" "$MEDIA_OWNER" || verdict_apply
    medias_a_poser "$src" "$MEDIA_ROOT/$t" || continue
    find -H "$src" -mindepth 1 -maxdepth 1 -exec cp -a -t "$MEDIA_ROOT/$t/" {} + \
      || { p_fail "médias non copiables ($src → $MEDIA_ROOT/$t)"; verdict_apply; }
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "médias posés ($MEDIA_ROOT/$t)"
  done
  build_doc

  # cp -a emporte les ACL de la source, et leur retrait peut changer les bits de groupe : les modes se reposent après
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -bR "$MEDIA_ROOT" || p_warn "ACL héritées non nettoyées sous $MEDIA_ROOT"
  fi
  media_modes "$MEDIA_ROOT" || true
  find "$MEDIA_ROOT" \( ! -user "${MEDIA_OWNER%%:*}" -o ! -group "${MEDIA_OWNER##*:}" \) -exec chown -h "$MEDIA_OWNER" {} + \
    || p_warn "propriétaire non posé sous $MEDIA_ROOT — le contenu garde celui de la source"
  local d
  for d in "" "${MEDIA_TREES[@]}" doc; do
    [[ -d "$MEDIA_ROOT${d:+/$d}" ]] || continue
    ensure_mode "$MEDIA_ROOT${d:+/$d}" "$(media_mode "$d")" "$MEDIA_OWNER" || verdict_apply
  done
  verdict_apply
}

case "${1:?usage: 44-media.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
