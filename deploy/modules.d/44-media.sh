#!/usr/bin/env bash
# SOURCE: deploy/modules.d/44-media.sh
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
MEDIA_ROOT_CANON="$PROV_ROOT/share"   # le chemin que deploy/system.manifest declare (dir share, share/*)
MEDIA_ROOT="${LCARS_MEDIA_ROOT:-$MEDIA_ROOT_CANON}"
# ⚠ LE MODE ET LE PROPRIETAIRE VIENNENT DE LA TABLE, PLUS D'UN LITTERAL (lot 15). Ce module POSE
# `share` et ses trois sous-arbres ; il est donc le seul a pouvoir relire leur mode — les ajouter a
# la table de `25-directories` en ferait un second poseur (mur POSEUR). La table les declarait
# `0755 root:root` et AUCUN module ne les mesurait : un `share/avatars` en 2775 (setgid herite
# d'un checkout, ou d'un COPY depuis un contexte a umask 002) passait un doctor vert.
# Le proprietaire garde sa couture de decor (un temoin ne chown pas vers root) ; repli sur les
# valeurs historiques si la table ne dit rien.
MEDIA_OWNER="${LCARS_MEDIA_OWNER:-$(prov_manifest_owner "$MEDIA_ROOT_CANON")}"
: "${MEDIA_OWNER:=root:root}"
media_mode() { # media_mode [sous-arbre] -> le mode que la table declare pour share[/<sous-arbre>], sinon 0755
  local m; m="$(prov_manifest_mode "$MEDIA_ROOT_CANON${1:+/$1}")"; printf '%s\n' "${m:-0755}"
}
# media_check_perms [sous-arbre] — le mode et le proprietaire RELUS (stat), contre la table. Un objet
# absent n'est pas juge ici : son absence se dit une fois, la ou elle a une consequence.
media_check_perms() {
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
    media_check_perms "$t"
  done

  # ⚠ ON SONDE `index.html`, PAS LE RÉPERTOIRE. Un build interrompu laisse un `doc/` qui existe et
  # que la route sert en 404 — la question posée est « le deck a-t-il une page d'accueil à rendre »,
  # et c'est ce fichier-là qui y répond.
  if [[ -s "$(doc_dir)/index.html" ]]; then
    p_ok "$(doc_dir) posée ($(find "$(doc_dir)" -type f 2>/dev/null | wc -l) fichiers)"
  else
    p_drift "$(doc_dir) absente — l'onglet Doc du deck rendra 404 (16-node la bâtit, ce module la pose)"
  fi
  media_check_perms doc
  media_check_perms   # la racine `share` elle-meme, declaree comme les trois autres

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
  # VU : `FAIL 44-media: build du site en échec`, et
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
  prov_scaffold_dir "$partial" "$(media_mode doc)" "$MEDIA_OWNER" || verdict_apply   # hors journal (M8)
  cp -a "$SITE_SRC/dist/." "$partial/" \
    || { p_fail "doc non copiable ($SITE_SRC/dist → $(doc_dir))"; rm -rf "$partial"; verdict_apply; }
  prov_promote_dir "$partial" "$(doc_dir)" || verdict_apply   # journalise le nom FINAL
  p_chg "doc du deck posée ($(doc_dir), base $SITE_BASE)"
}

apply() {
  local t src
  for t in "${MEDIA_TREES[@]}"; do
    src="$(media_src "$t")"
    [[ -d "$src" ]] || { p_fail "source absente : $src — l'arbre livre-t-il encore ses médias ?"; verdict_apply; }
    ensure_dir "$MEDIA_ROOT/$t" "$(media_mode "$t")" "$MEDIA_OWNER" || verdict_apply
    # `cp -a … /.` : le CONTENU, pas le répertoire — sinon un second passage imbrique
    # `avatars/avatars`. Idempotent : on récrit par-dessus, ces fichiers n'ont pas d'état.
    cp -a "$src/." "$MEDIA_ROOT/$t/" \
      || { p_fail "médias non copiables ($src → $MEDIA_ROOT/$t)"; verdict_apply; }
  done
  build_doc

  # ⚠ LE SYMBOLIQUE EST OBLIGATOIRE. `chmod` NUMÉRIQUE ne retire pas le setgid d'un dossier (mesuré :
  # `chmod 0755` sur un dossier setgid laisse `2755`, avec ou sans ACL) — seul `a-s`/`g-s` l'adresse.
  # Sans lui, un checkout fleet (setgid) fait hériter la cible du setgid, et `ensure_dir … 0755`
  # échouait au 2e apply (`2755 ≠ 755`) : le rail cessait d'être idempotent. Le `go=rx` ramène en
  # plus le mask ACL à `r-x`, donc `stat %a` lit bien `755`.
  # `-mindepth 2` : l'arbre PROFOND seulement — les quatre objets que la table declare (share et ses
  # trois sous-arbres) convergent plus bas par `ensure_mode`, au mode de LEUR ligne, et
  # `ensure_mode` efface lui-meme les bits speciaux avant de poser le mode numerique.
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -bR "$MEDIA_ROOT" || p_warn "ACL héritées non nettoyées sous $MEDIA_ROOT"
  fi
  find "$MEDIA_ROOT" -mindepth 2 -type d -exec chmod a-s,u=rwx,go=rx {} + || p_warn "mode dossiers non posé sous $MEDIA_ROOT"
  find "$MEDIA_ROOT" -type f -exec chmod a+rX {} + || p_warn "lecture fichiers non posée sous $MEDIA_ROOT"
  # ⚠ LE PROPRIETAIRE SUIT LE MEME RAISONNEMENT QUE LE MODE, ET IL MANQUAIT. `cp -a` PRESERVE le
  # proprietaire de la SOURCE : le contenu de `/usr/share/lcars/*` appartenait donc a qui possedait
  # le checkout — un humain, sur un poste. Les deux `find` ci-dessus rattrapaient les modes et
  # jamais les proprietaires, si bien qu'un arbre systeme portait l'identite de l'operateur qui
  # avait lance l'install, et changeait de proprietaire selon QUI deployait. `root:root` est ce que
  # la table declare pour cet arbre ; c'est ici qu'on le tient.
  chown -R root:root "$MEDIA_ROOT" || p_warn "propriétaire non posé sous $MEDIA_ROOT — le contenu garde celui de la source (« cp -a » le préserve)"
  # ⚠ LA TABLE A LE DERNIER MOT SUR CE QU'ELLE DECLARE (lot 15). Les deux `find` posent le mode de
  # l'arbre profond ; les quatre objets que `deploy/system.manifest` nomme convergent ICI, par
  # `ensure_mode`, au mode de leur ligne — et c'est exactement ce que `check` relit.
  local d
  for d in "" "${MEDIA_TREES[@]}" doc; do
    [[ -d "$MEDIA_ROOT${d:+/$d}" ]] || continue
    ensure_mode "$MEDIA_ROOT${d:+/$d}" "$(media_mode "$d")" "$MEDIA_OWNER" || verdict_apply
  done
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "médias posés ($MEDIA_ROOT : ${MEDIA_TREES[*]} doc)"
  verdict_apply
}

case "${1:?usage: 44-media.sh <check|apply>}" in
  check|apply)
    # ⚠ UNE LECTURE DU CANAL, ICI, ET UN SEUL BRANCHEMENT. Sous `deb` la doc et les medias sont
    # possedes par le paquet `lcars` : ce module MESURE (check) et ne pose rien — le drift se
    # converge par le paquet. Un canal illisible est un verdict rouge avant tout geste.
    prov_channel_or_verdict "$1"
    if poseur_is_dpkg; then check; elif [[ "$1" == "apply" ]]; then apply; else check; fi ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
