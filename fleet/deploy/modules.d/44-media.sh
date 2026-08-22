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
# `assets/` est la SOURCE ; le Dockerfile la pose en `/usr/share/lcars/{avatars,favicon}` (lignes
# `COPY assets/avatars` et `COPY assets/favicon`). Aucun module de provision ne le faisait : le rail
# natif n'a jamais eu ce répertoire.
#
# ⚠ ET LE TROU ÉTAIT COSMÉTIQUE TANT QUE LA RECETTE TOURNAIT DANS L'IMAGE. `provision-forge-charte.sh`
# lit `$LCARS_MEDIA_ROOT/avatars` pour poser les avatars des comptes de rôle ; dans le conteneur ils
# existaient. En sortant tofu du conteneur (2026-08-22), la même recette s'exécute SUR la machine —
# et l'absence devient un ÉCHEC DUR de toute la structure de forge :
#
#   provision-forge-charte: dossier avatars introuvable: /usr/share/lcars/avatars
#   Error: local-exec provisioner error
#
# C'est la leçon des paquets, au niveau fichier : deux rails qui livrent le même produit doivent
# poser le même contenu, et ce qui manque d'un côté ne se voit que le jour où on l'exerce.
#
# ─── TROIS CONSOMMATEURS, PAS UN ────────────────────────────────────────────────────────────────
#
# Ce n'est pas un correctif pour la recette : le préfixe est LU par trois choses distinctes —
# `Fleet.Observation.Deck` (`media_root`, défaut `/usr/share/lcars`), `console-deck.py`
# (`DECK_FAVICON`) et la recette de charte. Le rail natif les servait tous les trois en générique.
#
# ⚠ `doc/` N'EST PAS POSÉ ICI, ET C'EST DÉLIBÉRÉ. Le Dockerfile le remplit depuis un étage de build
# du site (`COPY --from=site`), que ce rail ne bâtit pas. `console-deck.py` défaute dessus et son
# absence coûte un lien mort, jamais un échec. Le poser demanderait de bâtir le site à l'install —
# une décision qui n'a pas été prise, et qu'un module ne prend pas tout seul.
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
MEDIA_ROOT="${LCARS_MEDIA_ROOT:-/usr/share/lcars}"
MEDIA_OWNER="${LCARS_MEDIA_OWNER:-root:root}"

# Les arbres livrés, et leur source unique. `doc` n'y est pas (cf. en-tête).
MEDIA_TREES=(avatars favicon)

# Seam de test sur la SOURCE. Sans lui, la branche « la source a disparu » n'est jouable par aucun
# témoin : `repo_root` vient de la lib, qui la redéfinit au source — la surcharger depuis le décor ne
# tient pas. Un chemin qu'aucun témoin ne peut atteindre est un chemin non écrit.
MEDIA_SRC_ROOT="${LCARS_MEDIA_SRC_ROOT:-$(repo_root)/assets}"

media_src() { echo "$MEDIA_SRC_ROOT/$1"; }

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
  verdict_check
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
  # Lisible par tous : le deck tourne sous l'humain, la recette sous root, un pod sous un troisième.
  chmod -R a+rX "$MEDIA_ROOT" 2>/dev/null || true
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "médias posés ($MEDIA_ROOT : ${MEDIA_TREES[*]})"
  verdict_apply
}

case "${1:?usage: 44-media.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
