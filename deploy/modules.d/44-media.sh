#!/usr/bin/env bash
# SOURCE: deploy/modules.d/44-media.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: les médias partagés (avatars, favicon) et la doc du deck — bâtie depuis les sources, ou posée depuis le kit
# APPLY-ON: wsl linux docker
# CHECK-ON: any
# NEEDS: root
# AFTER: 10-packages 16-node

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

# le même défaut que runtime/config/runtime.exs (LCARS_MEDIA_ROOT) et deck.ex (:media_root)
MEDIA_ROOT="$PROV_MEDIA_ROOT"
MEDIA_OWNER="$(prov_owner "$(prov_manifest_owner "$MEDIA_ROOT")")"
MEDIA_TREES=(avatars favicon)
MEDIA_SRC_ROOT="$(repo_root)/assets"
SITE_SRC="$(repo_root)/assets/github.io"
SITE_BASE="${LCARS_SITE_BASE:-/doc/}"
DOC_DIR="$MEDIA_ROOT/doc"
# à côté de doc/, que prov_promote_dir remplace en entier
DOC_STAMP="$MEDIA_ROOT/.doc-revision"

media_mode() { prov_manifest_mode "$MEDIA_ROOT${1:+/$1}"; }   # media_mode [sous-arbre] → le mode que system.manifest déclare pour share[/<sous-arbre>]

media_check_perms() { # media_check_perms [sous-arbre] — mode et propriétaire relus contre la table
  local path="$MEDIA_ROOT${1:+/$1}"
  if prov_check_mode "$path" "$(media_mode "${1:-}")" "$MEDIA_OWNER"; then p_ok "$path (mode et propriétaire de la table)"; fi
  return 0
}

# par contenu : une copie de l'arbre (62, le kit) change les dates, pas la doc
doc_empreinte() { # doc_empreinte → une signature du dist/ et de la base qui l'a bâti, ou 1 sans dist
  [[ -d "$SITE_SRC/dist" ]] || return 1
  { printf 'base=%s\n' "$SITE_BASE"
    ( cd "$SITE_SRC/dist" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0r sha256sum )
  } | sha256sum | cut -d' ' -f1
}
doc_tampon_lit() { sed -n "s/^$1 //p" "$DOC_STAMP" 2>/dev/null | head -n1; }

doc_a_jour() { # doc_a_jour → 0 si la doc posée sort de cette révision, de cette base, et que l'arbre du site est propre
  [[ -n "$PROV_SOURCE_REV" && "$PROV_SOURCE_REV" != "inconnue" && "$PROV_SOURCE_REV" != *"+local" ]] || return 1
  [[ -s "$DOC_DIR/index.html" ]] || return 1
  [[ -r "$DOC_STAMP" ]] || return 1
  local sale
  sale="$(git -C "$SITE_SRC" status --porcelain --untracked-files=all -- . 2>/dev/null)" || return 1
  [[ -z "$sale" ]] || return 1
  [[ "$(doc_tampon_lit rev)" == "$PROV_SOURCE_REV" ]] || return 1
  [[ "$(doc_tampon_lit base)" == "$SITE_BASE" ]]
}

# la décision de build_doc, sans rien bâtir : une livraison binaire ou la copie posée comparent le dist, une source sa révision
doc_conforme() {
  if prov_delivery_is_binary || prov_dans_la_copie; then
    [[ "$(doc_empreinte || true)" == "$(doc_tampon_lit dist)" && -n "$(doc_tampon_lit dist)" ]]
  else
    doc_a_jour
  fi
}

medias_a_poser() { # medias_a_poser <source> <posé> → 0 si un fichier de la source manque sous le posé, ou y diffère ; ce que le posé porte en plus ne compte pas
  local ecarts
  ecarts="$(diff -rq "$1" "$2" 2>&1)" && return 1
  grep -qvF "Only in $2" <<<"$ecarts"
}

check() {
  local t src
  for t in "${MEDIA_TREES[@]}"; do
    src="$MEDIA_SRC_ROOT/$t"
    if [[ ! -d "$MEDIA_ROOT/$t" ]]; then
      p_drift "$MEDIA_ROOT/$t absent — la charte de forge échoue dessus, et le deck sert des icônes génériques"
      continue
    fi
    if [[ -d "$src" ]] && medias_a_poser "$src" "$MEDIA_ROOT/$t"; then
      p_drift "$MEDIA_ROOT/$t ne porte pas tout ce que la source porte, à l'identique ($src) — l'apply le repose"
    else
      p_ok "$MEDIA_ROOT/$t posé ($(find "$MEDIA_ROOT/$t" -maxdepth 1 -type f 2>/dev/null | wc -l) fichiers)"
    fi
    media_check_perms "$t"
  done
  if [[ ! -s "$DOC_DIR/index.html" ]]; then
    p_drift "$DOC_DIR absente — l'onglet Doc du deck rendra 404 (l'apply la bâtit avec le node de 16-node, ou la pose depuis le kit)"
  elif doc_conforme; then
    p_ok "$DOC_DIR posée ($(find "$DOC_DIR" -type f 2>/dev/null | wc -l) fichiers)"
  else
    p_drift "$DOC_DIR posée, mais pas depuis cette source (révision, base ou contenu du dist) — l'apply la rebâtit ou la repose"
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
    p_ok "doc du deck à jour ($DOC_DIR, révision $PROV_SOURCE_REV) — rien à rebâtir"
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
  local partial emp tampon=""; partial="$DOC_DIR.partial"
  emp="$(doc_empreinte || true)"
  if [[ -n "$PROV_SOURCE_REV" && "$PROV_SOURCE_REV" != "inconnue" && "$PROV_SOURCE_REV" != *"+local" ]]; then
    tampon+="rev $PROV_SOURCE_REV"$'\n'"base $SITE_BASE"$'\n'
  fi
  [[ -n "$emp" ]] && tampon+="dist $emp"$'\n'
  # un dist identique n'est pas recopié ; le tampon suit quand même la révision qui l'a rebâti
  if [[ -n "$emp" && "$emp" == "$(doc_tampon_lit dist)" && -s "$DOC_DIR/index.html" ]]; then
    write_atomic "$DOC_STAMP" 0644 "$MEDIA_OWNER" <<<"${tampon%$'\n'}" || true
    p_ok "doc du deck déjà posée ($DOC_DIR, base $SITE_BASE) — rien à poser"
    return 0
  fi
  rm -rf "$partial"
  prov_scaffold_dir "$partial" "$(media_mode doc)" "$MEDIA_OWNER" || verdict_apply
  find -H "$SITE_SRC/dist" -mindepth 1 -maxdepth 1 -exec cp -a -t "$partial/" {} + \
    || { p_fail "doc non copiable ($SITE_SRC/dist → $DOC_DIR)"; rm -rf "$partial"; verdict_apply; }
  prov_promote_dir "$partial" "$DOC_DIR" || verdict_apply
  [[ -n "$tampon" ]] && { write_atomic "$DOC_STAMP" 0644 "$MEDIA_OWNER" <<<"${tampon%$'\n'}" || true; }
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "doc du deck posée ($DOC_DIR, base $SITE_BASE)"
}

media_modes() { # media_modes <racine> — l'arbre profond en 755/644, sans bits spéciaux
  local racine="${1:?media_modes: racine absente}" rc=0
  find "$racine" -mindepth 2 -type d \( -perm /7022 -o ! -perm -u=rwx -o ! -perm -go=rx \) \
    -exec chmod a-s,u=rwx,go=rx {} + || { p_warn "mode dossiers non posé sous $MEDIA_ROOT"; rc=1; }
  find "$racine" -type f \( ! -perm -a=r -o \( -perm /111 -a ! -perm -a=x \) \) \
    -exec chmod a+rX {} + || { p_warn "lecture fichiers non posée sous $MEDIA_ROOT"; rc=1; }
  return "$rc"
}

apply() {
  local t src
  for t in "${MEDIA_TREES[@]}"; do
    src="$MEDIA_SRC_ROOT/$t"
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

case "${1:-}" in check|apply) "$1" ;; *) p_die "mode inconnu: ${1:-} (check|apply)" ;; esac
