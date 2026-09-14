#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/poseurs.bats
# AUTHOR: bob
# STARDATE: 2026-09-01
# STATUS: bats tests — CE QUE LES POSEURS LAISSENT DERRIERE EUX

# shellcheck disable=SC2030,SC2031

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/.."
  MODS="$DEPLOY/modules.d"
  [ -d "$MODS" ]
}

embarque() { sed -n "s/^$1=//p" "$DEPLOY/installer-constants.env" | tr ' ' '\n' | grep -qx "$2"; }   # embarque <liste des constantes> <arbre>

@test "C2 : ~/.lcars/log est chmode par l'apply — il ne nait plus au umask" {
  local mod="$BATS_TEST_DIRNAME/../../runtime/services/human.d/70-human.sh"
  local ligne; ligne="$(grep -n 'chmod 0700' "$mod" | head -1)"
  [ -n "$ligne" ]
  grep -q 'chmod 0700 .*\.lcars/log' "$mod"
}

@test "C2 : et le CHECK le regarde — sinon le doctor reste aveugle apres le correctif" {
  # L'angle mort etait double, et la seconde moitie est la plus sournoise : corriger l'apply sans
  # toucher au check aurait rendu le defaut invisible au lieu de le fermer.
  local mod="$BATS_TEST_DIRNAME/../../runtime/services/human.d/70-human.sh"
  local bloc; bloc="$(sed -n '/^check()/,/^}$/p' "$mod")"
  grep -q '\.lcars/log' <<<"$bloc"
}


@test "C4 : le contenu de la racine des medias est rendu a root, pas laisse a l'operateur" {
  # sous un décor tout appartient à qui le joue : le propriétaire ne se mesure pas, il se lit dans le code
  local mod="$MODS/44-media.sh" media
  media="$(sed -n 's/^PROV_MEDIA_ROOT=//p' "$DEPLOY/installer-constants.env")"
  [ -n "$media" ]
  # 1. le propriétaire de l'arbre est celui que la table déclare, et la table dit root:root
  awk -v p="$media" '$1 == "dir" && $2 == p && $4 == "root:root" {t=1} END {exit !t}' "$DEPLOY/system.manifest" \
    || { echo "la table ne déclare plus $media à root:root : le contenu garderait l'identite de la source (« cp -a » la preserve)"; return 1; }
  grep -qF 'MEDIA_OWNER="$(prov_owner "$(prov_manifest_owner "$MEDIA_ROOT")")"' "$mod" \
    || { echo "le propriétaire de 44-media ne vient plus de la table"; return 1; }
  # 2. le chown est CONDITIONNEL — il ne touche que ce qui devie
  grep -qF '! -user "${MEDIA_OWNER%%:*}" -o ! -group "${MEDIA_OWNER##*:}"' "$mod" \
    || { echo "le chown de 44-media n'est plus filtre : il touchera tout l'arbre a chaque apply (ctime), et le module comptera une mutation sur un arbre identique"; return 1; }
  grep -qF 'chown -h "$MEDIA_OWNER"' "$mod" \
    || { echo "le chown de 44-media n'est plus en -h : il suivrait les liens (chown root sur une cible arbitraire) et ne convergerait jamais"; return 1; }
  local n_chmod n_chown
  n_chmod="$(grep -n 'media_modes "$MEDIA_ROOT"' "$mod" | tail -1 | cut -d: -f1)"
  n_chown="$(grep -nF 'exec chown -h "$MEDIA_OWNER"' "$mod" | head -1 | cut -d: -f1)"
  [ -n "$n_chmod" ] || { echo "aucun appel « media_modes \"\$MEDIA_ROOT\" » dans 44-media : les modes ne sont plus poses, ou la fonction a change de nom"; return 1; }
  [ -n "$n_chown" ] || { echo "aucun chown vers le propriétaire de la table dans 44-media"; return 1; }
  [ "$n_chmod" -lt "$n_chown" ] \
    || { echo "le chown (l. $n_chown) precede la pose des modes (l. $n_chmod) — l'ordre dit l'intention"; return 1; }
}


@test "C6+ : ce que les modules LISENT a la RACINE (repo_root) est ce qui est embarque" {
  local lus; lus="$(grep -rhoE 'repo_root\)/[a-z]+' "$MODS"/*.sh "$DEPLOY"/lib/*.sh 2>/dev/null \
    | sed 's|repo_root)/||' | sort -u | grep -vE '^(fleet|runtime)$')"
  local n
  for n in $lus; do
    embarque PROV_EMBEDDED_ROOT "$n" \
      || { echo "lu sous repo_root mais PAS embarque : $n"; return 1; }
  done
}

@test "C6+ : ce que les modules LISENT dans l ARBRE PRODUIT (product_tree) est dans EMBEDDED" {
  local lus; lus="$(grep -rhoE 'product_tree\)/[a-z_]+' "$MODS"/*.sh "$DEPLOY"/lib/*.sh 2>/dev/null \
    | sed 's|product_tree)/||' | sort -u)"
  [ -n "$lus" ] || { echo "extraction ratee : aucune lecture sous product_tree trouvee"; return 1; }
  local n manquants=""
  for n in $lus; do
    # `_build` est l arbre de BUILD : il ne s embarque pas, il se consomme la ou il est bati.
    # `prov_release_bin` le cherche dans le PAQUET, jamais dans la copie posee.
    [ "$n" = "_build" ] && continue
    embarque PROV_EMBEDDED "$n" || manquants="$manquants $n"
  done
  [ -z "$manquants" ] \
    || { echo "lu sous product_tree mais PAS dans EMBEDDED :$manquants"; return 1; }
}

