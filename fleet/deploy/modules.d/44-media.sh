#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/44-media.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — les médias partagés (avatars, favicon) : le jumeau FICHIER du trou ISO des paquets
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
# AFTER: 16-node

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# Le seam est celui du PRODUIT : `runtime.exs` lit `LCARS_MEDIA_ROOT` avec ce même défaut, et
# `deck.ex` le documente. On n'en invente pas un second.
MEDIA_ROOT="${LCARS_MEDIA_ROOT:-$PROV_ROOT/share}"
MEDIA_OWNER="${LCARS_MEDIA_OWNER:-root:root}"

MEDIA_TREES=(avatars favicon)

MEDIA_SRC_ROOT="${LCARS_MEDIA_SRC_ROOT:-$(repo_root)/assets}"

media_src() { echo "$MEDIA_SRC_ROOT/$1"; }

SITE_SRC="${LCARS_SITE_SRC:-$(repo_root)/assets/github.io}"
SITE_BASE="${LCARS_SITE_BASE:-/doc/}"
NPM_BIN="${LCARS_NPM_BIN:-npm}"

doc_dir() { echo "$MEDIA_ROOT/doc"; }

check() {
  local t src n
  for t in "${MEDIA_TREES[@]}"; do
    src="$(media_src "$t")"
    if [[ ! -d "$MEDIA_ROOT/$t" ]]; then
      p_drift "$MEDIA_ROOT/$t absent — la charte de forge échoue dessus, et le deck sert des icônes génériques"
      continue
    fi
    # ⚠ LA PRÉSENCE DU RÉPERTOIRE NE SUFFIT PAS. Un dossier vide passe un test d'existence et fait
    # échouer la recette exactement pareil. On compare les COMPTES, qui est la question posée.
    n="$(find "$MEDIA_ROOT/$t" -maxdepth 1 -type f 2>/dev/null | wc -l)"
    if [[ -d "$src" ]] && (( n < $(find "$src" -maxdepth 1 -type f | wc -l) )); then
      p_drift "$MEDIA_ROOT/$t incomplet ($n fichiers) — la source en porte plus ($src)"
    else
      p_ok "$MEDIA_ROOT/$t posé ($n fichiers)"
    fi
  done

  # ⚠ ON SONDE `index.html`, PAS LE RÉPERTOIRE. Un build interrompu laisse un `doc/` qui existe et
  # que la route sert en 404 — la question posée est « le deck a-t-il une page d'accueil à rendre »,
  # et c'est ce fichier-là qui y répond.
  if [[ -s "$(doc_dir)/index.html" ]]; then
    p_ok "$(doc_dir) posée ($(find "$(doc_dir)" -type f 2>/dev/null | wc -l) fichiers)"
  else
    p_drift "$(doc_dir) absente — l'onglet Doc du deck rendra 404 (16-node la bâtit, ce module la pose)"
  fi

  verdict_check
}

build_doc() {
  [[ -d "$SITE_SRC" ]] \
    || { p_fail "sources du site absentes ($SITE_SRC) — l'arbre livre-t-il encore sa doc ?"; verdict_apply; }

  # ⚠ EN LIVRAISON BINAIRE, ON NE BÂTIT PAS — ON POSE CE QUI EST ARRIVÉ BÂTI. `pack.sh` emporte le
  # `dist/` à ce chemin exact, à côté de la release et pour la même raison : les deux sont
  # gitignorés, donc `git archive` ne les emporte pas, donc le paquet les ajoute.
  #
  # Sans cette branche, une cible qui installe un paquet mourait ICI. `16-node` ne pose plus node en
  # livraison binaire — c'est le geste R4 — donc `npm` est absent, et ce module échouait sur un
  # « joue-le d'abord » qui désigne un module dont l'état-cible est justement de ne rien poser. Le
  # rail s'envoyait à lui-même une instruction impossible.
  if prov_delivery_is_binary; then
    [[ -s "$SITE_SRC/dist/index.html" ]] \
      || { p_fail "livraison binaire, mais le paquet n'apporte pas la doc bâtie ($SITE_SRC/dist) — « pack.sh » la bâtit ET l'emporte ; ce paquet est une demi-livraison"; verdict_apply; }
    poser_doc
    return 0
  fi

  # ⚠ LA COPIE POSÉE N'EST PAS UN ARBRE DE BUILD, ET CELUI-CI Y INSTALLAIT 176 Mo AVANT D'ÉCHOUER.
  # La branche du dessus lit la LIVRAISON ; celle-ci lit l'EMPLACEMENT, et les deux questions sont
  # distinctes. Un poste en livraison SOURCE rejoué depuis `/opt/lcars` arrivait ici, lançait
  # `npm ci` dans `/opt/lcars/assets/github.io` — que `62-runtime-helpers` embarque justement SANS
  # `node_modules` — puis mourait sur `npm run build`.
  #
  # MESURE DU 2026-09-02, BANC 2007 : `FAIL 44-media: build du site en échec`, et
  # `/opt/lcars/assets` pesant 176 Mo au relevé suivant. L'échec était visible ; la pollution, non.
  #
  # Le `dist/` embarqué EST la doc de cette machine. S'il manque, c'est un drift à nommer — pas un
  # build à lancer depuis un arbre qui n'a jamais eu vocation à en porter un.
  if prov_dans_la_copie; then
    if [[ -s "$SITE_SRC/dist/index.html" ]]; then
      poser_doc
      return 0
    fi
    p_drift "doc non bâtie dans la copie posée ($SITE_SRC/dist) — ce rail se REJOUE ici, il ne s'y reconstruit pas : relance l'apply depuis l'arbre de travail"
    return 0
  fi

  command -v "$NPM_BIN" >/dev/null 2>&1 \
    || { p_fail "npm absent — 16-node pose le précompilé épinglé ; joue-le d'abord"; verdict_apply; }

  # ⚠ `as_human` : `npm ci` ÉCRIT dans le checkout (`node_modules/`, `dist/`, tous deux gitignorés).
  run_step "doc du deck · dépendances" -- as_human env -C "$SITE_SRC" "$NPM_BIN" ci --no-audit --no-fund \
    || { p_fail "npm ci en échec ($SITE_SRC) — la doc ne peut pas être bâtie"; verdict_apply; }

  # ⚠ LA BASE VOYAGE PAR L'ENVIRONNEMENT, et sans elle le site sort pour la racine : servi sous
  # `/doc/`, chacune de ses URL d'asset serait fausse. C'est la variable que le Dockerfile pose, et
  # que le workflow GitHub NE pose pas — Pages sert au domaine, le deck sous un chemin.
  run_step "doc du deck · build" -- as_human env -C "$SITE_SRC" LCARS_SITE_BASE="$SITE_BASE" "$NPM_BIN" run build \
    || { p_fail "build du site en échec ($SITE_SRC) — un chemin du runtime a-t-il bougé ? le build LIT l'arbre"; verdict_apply; }

  [[ -s "$SITE_SRC/dist/index.html" ]] \
    || { p_fail "build terminé sans index.html ($SITE_SRC/dist) — rien à servir"; verdict_apply; }

  poser_doc
}

# ⚠ LA POSE EST COMMUNE AUX DEUX LIVRAISONS, ET C'EST DELIBERE. Ce qui change entre binaire et
# source est de savoir QUI a bâti le `dist/` — pas ce qu'on en fait. Deux copies de ce bloc
# dériveraient sur le mode, le propriétaire ou l'atomicité, et l'une des deux formes servirait une
# doc que personne n'a relue.
poser_doc() {
  # Pose atomique : un `doc/` à moitié recopié se sert en 404 silencieux.
  local partial; partial="$(doc_dir).partial"
  rm -rf "$partial"
  ensure_dir "$partial" 0755 "$MEDIA_OWNER" || verdict_apply
  cp -a "$SITE_SRC/dist/." "$partial/" \
    || { p_fail "doc non copiable ($SITE_SRC/dist → $(doc_dir))"; rm -rf "$partial"; verdict_apply; }
  rm -rf "$(doc_dir)"
  mv "$partial" "$(doc_dir)"
  p_chg "doc du deck posée ($(doc_dir), base $SITE_BASE)"
}

apply() {
  local t src
  for t in "${MEDIA_TREES[@]}"; do
    src="$(media_src "$t")"
    [[ -d "$src" ]] || { p_fail "source absente : $src — l'arbre livre-t-il encore ses médias ?"; verdict_apply; }
    ensure_dir "$MEDIA_ROOT/$t" 0755 "$MEDIA_OWNER" || verdict_apply
    # `cp -a … /.` : le CONTENU, pas le répertoire — sinon un second passage imbrique
    # `avatars/avatars`. Idempotent : on récrit par-dessus, ces fichiers n'ont pas d'état.
    cp -a "$src/." "$MEDIA_ROOT/$t/" \
      || { p_fail "médias non copiables ($src → $MEDIA_ROOT/$t)"; verdict_apply; }
  done
  build_doc

  # ⚠ LE SYMBOLIQUE EST OBLIGATOIRE. `chmod` NUMÉRIQUE ne retire pas le setgid d'un dossier (mesuré :
  # `chmod 0755` sur un dossier setgid laisse `2755`, avec ou sans ACL) — seul `a-s`/`g-s` l'adresse.
  # Sans lui, un checkout fleet (setgid) fait hériter la cible du setgid, et `ensure_dir … 0755`
  # échoue au 2e apply (`2755 ≠ 755`, `ensure_mode` ne converge jamais) : le rail cesse d'être
  # idempotent. Le `go=rx` ramène en plus le mask ACL à `r-x`, donc `stat %a` lit bien `755`.
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -bR "$MEDIA_ROOT" || p_warn "ACL héritées non nettoyées sous $MEDIA_ROOT"
  fi
  find "$MEDIA_ROOT" -type d -exec chmod a-s,u=rwx,go=rx {} + || p_warn "mode dossiers non posé sous $MEDIA_ROOT"
  find "$MEDIA_ROOT" -type f -exec chmod a+rX {} + || p_warn "lecture fichiers non posée sous $MEDIA_ROOT"
  # ⚠ LE PROPRIETAIRE SUIT LE MEME RAISONNEMENT QUE LE MODE, ET IL MANQUAIT. `cp -a` PRESERVE le
  # proprietaire de la SOURCE : le contenu de `/usr/share/lcars/*` appartenait donc a qui possedait
  # le checkout — un humain, sur un poste. Les deux `find` ci-dessus rattrapaient les modes et
  # jamais les proprietaires, si bien qu'un arbre systeme portait l'identite de l'operateur qui
  # avait lance l'install, et changeait de proprietaire selon QUI deployait. `root:root` est ce que
  # la table declare pour cet arbre ; c'est ici qu'on le tient.
  chown -R root:root "$MEDIA_ROOT" || p_warn "propriétaire non posé sous $MEDIA_ROOT — le contenu garde celui de la source (« cp -a » le préserve)"
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "médias posés ($MEDIA_ROOT : ${MEDIA_TREES[*]} doc)"
  verdict_apply
}

case "${1:?usage: 44-media.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
