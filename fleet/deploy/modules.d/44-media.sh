#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/44-media.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — les médias partagés (avatars, favicon) : le jumeau FICHIER du trou ISO des paquets
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
#
# ─── UN TROU QUE LE CONTENEUR CACHAIT ───────────────────────────────────────────────────────────
#
# `assets/` est la SOURCE ; le Dockerfile la pose en `/opt/lcars/share/{avatars,favicon}` (lignes
# `COPY assets/avatars` et `COPY assets/favicon`). Aucun module de provision ne le faisait : le rail
# natif n'a jamais eu ce répertoire.
#
# ⚠ ET LE TROU ÉTAIT COSMÉTIQUE TANT QUE LA RECETTE TOURNAIT DANS L'IMAGE. `provision-forge-charte.sh`
# lit `$LCARS_MEDIA_ROOT/avatars` pour poser les avatars des comptes de rôle ; dans le conteneur ils
# existaient. En sortant tofu du conteneur (2026-08-22), la même recette s'exécute SUR la machine —
# et l'absence devient un ÉCHEC DUR de toute la structure de forge :
#
#   provision-forge-charte: dossier avatars introuvable: /opt/lcars/share/avatars
#   Error: local-exec provisioner error
#
# C'est la leçon des paquets, au niveau fichier : deux rails qui livrent le même produit doivent
# poser le même contenu, et ce qui manque d'un côté ne se voit que le jour où on l'exerce.
#
# ─── TROIS CONSOMMATEURS, PAS UN ────────────────────────────────────────────────────────────────
#
# Ce n'est pas un correctif pour la recette : le préfixe est LU par trois choses distinctes —
# `Fleet.Observation.Deck` (`media_root`, défaut `/opt/lcars/share`), `console-deck.py`
# (`DECK_FAVICON`) et la recette de charte. Le rail natif les servait tous les trois en générique.
#
# ─── ET `doc/`, QUI SE BÂTIT ICI ────────────────────────────────────────────────────────────────
#
# ⚖ USER 2026-08-22 : « j'ai pas envie de taper un site remote pour afficher la doc locale ».
#
# Ce module a d'abord posé les deux arbres statiques et laissé `doc/` de côté, au motif qu'il vient
# d'un étage de build que ce rail ne joue pas. C'était une omission déguisée en décision : la doc
# n'est pas accessoire, c'est la doc UTILISATEUR du produit, et l'onglet `/doc/` du deck rendait un
# `404 not found` nu sous un commentaire qui dit « doc absente = image ratée » — vrai dans la boîte,
# faux ici.
#
# Elle se bâtit à partir du MÊME arbre : le site lit `fleet/priv/catalogue` (les cartes, les sièges)
# et `fleet/lib/fleet/mcp/pod_tools.ex` (les outils). Même commit, donc rien à épingler et rien à
# rafraîchir — et un déplacement de catalogue CASSE ce build, ce qui est le comportement voulu.
#
# ⚠ `LCARS_SITE_BASE=/doc/` EST LOAD-BEARING. `astro.config.mjs` fait `base = LCARS_SITE_BASE || '/'`.
# GitHub Pages bâtit pour la racine ; le deck sert sous `/doc/`. Recopier l'artefact Pages ici
# donnerait un site dont chaque URL d'asset est fausse — d'où un build local, avec la base du deck.
# Le Dockerfile pose la même variable, pour la même raison.
#
# ⚠ ET LE BUILD TOURNE `as_human`, DANS LE CHECKOUT. `npm ci` écrit `node_modules/` (173 Mo) et
# `dist/` — les deux sont gitignorés, comme `_build` et `deps` pour mix. En root, il laisserait à
# l'opérateur un arbre qu'il ne peut plus effacer : c'est la leçon du `.terraform` de `46-tofu`,
# payée au nettoyage de .63.
#
# ─── POURQUOI 44 ────────────────────────────────────────────────────────────────────────────────
#
# `48-forge-host` joue la recette et en a besoin POUR ÇA. `62-runtime-helpers`, qui pose le reste des
# auxiliaires, tourne dix-huit crans plus tard. L'ordre est le préfixe — même leçon que `46-tofu`,
# et que `22-fleet-human` renommé de 65 à 22.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# Le seam est celui du PRODUIT : `runtime.exs` lit `LCARS_MEDIA_ROOT` avec ce même défaut, et
# `deck.ex` le documente. On n'en invente pas un second.
# La racine vient de la lib — les medias descendent sous la racine unique (phase B).
MEDIA_ROOT="${LCARS_MEDIA_ROOT:-$PROV_ROOT/share}"
MEDIA_OWNER="${LCARS_MEDIA_OWNER:-root:root}"

# Les arbres livrés, et leur source unique. `doc` n'y est pas (cf. en-tête).
MEDIA_TREES=(avatars favicon)

# Seam de test sur la SOURCE. Sans lui, la branche « la source a disparu » n'est jouable par aucun
# témoin : `repo_root` vient de la lib, qui la redéfinit au source — la surcharger depuis le décor ne
# tient pas. Un chemin qu'aucun témoin ne peut atteindre est un chemin non écrit.
MEDIA_SRC_ROOT="${LCARS_MEDIA_SRC_ROOT:-$(repo_root)/assets}"

media_src() { echo "$MEDIA_SRC_ROOT/$1"; }

# Le projet du site, et la base sous laquelle le deck le sert. Les deux sont des coutures : le
# premier pour qu'un témoin puisse jouer la branche « sources absentes », la seconde parce que c'est
# le contrat entre ce build et la route `/doc/` de `console-deck.py`.
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

# ─── build_doc — LA DOC, BÂTIE DU MÊME ARBRE ────────────────────────────────────────────────────
#
# Elle échoue FORT : une doc absente est une doc absente, pas un lien mort qu'on découvre en
# cliquant. Le module qui la pose est le seul endroit où l'échec a encore un contexte.
build_doc() {
  [[ -d "$SITE_SRC" ]] \
    || { p_fail "sources du site absentes ($SITE_SRC) — l'arbre livre-t-il encore sa doc ?"; verdict_apply; }
  command -v "$NPM_BIN" >/dev/null 2>&1 \
    || { p_fail "npm absent — 16-node pose le précompilé épinglé ; joue-le d'abord"; verdict_apply; }

  # ⚠ `as_human` : `npm ci` ÉCRIT dans le checkout (`node_modules/`, `dist/`, tous deux gitignorés).
  # En root il laisserait à l'opérateur un arbre qu'il ne peut plus effacer — la leçon du
  # `.terraform` de `46-tofu`, payée au nettoyage de .63.
  run_step "doc du deck · dépendances" -- as_human env -C "$SITE_SRC" "$NPM_BIN" ci --no-audit --no-fund \
    || { p_fail "npm ci en échec ($SITE_SRC) — la doc ne peut pas être bâtie"; verdict_apply; }

  # ⚠ LA BASE VOYAGE PAR L'ENVIRONNEMENT, et sans elle le site sort pour la racine : servi sous
  # `/doc/`, chacune de ses URL d'asset serait fausse. C'est la variable que le Dockerfile pose, et
  # que le workflow GitHub NE pose pas — Pages sert au domaine, le deck sous un chemin.
  run_step "doc du deck · build" -- as_human env -C "$SITE_SRC" LCARS_SITE_BASE="$SITE_BASE" "$NPM_BIN" run build \
    || { p_fail "build du site en échec ($SITE_SRC) — un chemin du runtime a-t-il bougé ? le build LIT l'arbre"; verdict_apply; }

  [[ -s "$SITE_SRC/dist/index.html" ]] \
    || { p_fail "build terminé sans index.html ($SITE_SRC/dist) — rien à servir"; verdict_apply; }

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

  # L'ARBRE DÉPLOYÉ APPARTIENT AU MODULE, PAS À LA SOURCE. `cp -a` a recopié les attributs du
  # checkout — un checkout fleet est setgid + ACL par défaut `group:fleet` — et l'arbre en héritait.
  # Deux gestes pour le posséder, et le second est load-bearing :
  #  1) retirer les ACL héritées : le rail Docker (`COPY assets/…`) pose SANS ACL, les deux rails
  #     doivent livrer le même état (ce module se targue d'être le jumeau du Dockerfile) ;
  #  2) forcer 0755 sur les dossiers + lisible partout : le deck tourne sous l'humain, la recette
  #     sous root, un pod sous un troisième.
  # ⚠ LE SYMBOLIQUE EST OBLIGATOIRE. `chmod` NUMÉRIQUE ne retire pas le setgid d'un dossier (mesuré :
  # `chmod 0755` sur un dossier setgid laisse `2755`, avec ou sans ACL) — seul `a-s`/`g-s` l'adresse.
  # Sans lui, un checkout fleet (setgid) fait hériter la cible du setgid, et `ensure_dir … 0755`
  # échoue au 2e apply (`2755 ≠ 755`, `ensure_mode` ne converge jamais) : le rail cesse d'être
  # idempotent. Le `go=rx` ramène en plus le mask ACL à `r-x`, donc `stat %a` lit bien `755`.
  # Pas de `2>/dev/null` muet ici (cf. l'en-tête de ce module, grief v1) : un refus se DIT.
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -bR "$MEDIA_ROOT" || p_warn "ACL héritées non nettoyées sous $MEDIA_ROOT"
  fi
  find "$MEDIA_ROOT" -type d -exec chmod a-s,u=rwx,go=rx {} + || p_warn "mode dossiers non posé sous $MEDIA_ROOT"
  find "$MEDIA_ROOT" -type f -exec chmod a+rX {} + || p_warn "lecture fichiers non posée sous $MEDIA_ROOT"
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "médias posés ($MEDIA_ROOT : ${MEDIA_TREES[*]} doc)"
  verdict_apply
}

case "${1:?usage: 44-media.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
