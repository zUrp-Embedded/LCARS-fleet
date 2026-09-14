#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/poseurs.bats
# AUTHOR: bob
# STARDATE: 2026-09-01
# STATUS: bats tests — CE QUE LES POSEURS LAISSENT DERRIERE EUX

# shellcheck disable=SC2030,SC2031

load refute

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/.."
  MODS="$DEPLOY/modules.d"
  PORTE="$BATS_TEST_DIRNAME/../../install.sh"
  [ -d "$MODS" ]
  [ -f "$PORTE" ]
}

embarque() { sed -n "s/^$1=//p" "$DEPLOY/installer-constants.env" | tr ' ' '\n' | grep -qx "$2"; }   # embarque <liste des constantes> <arbre>



@test "C1 : --bench est CABLE sur le rail poste — il n'est plus avale" {
  grep -q 'export LCARS_BENCH=1 PROV_FORGE_MONTEE=1' "$PORTE"
  grep -qE '^ESCALADE_ENV=\(.*LCARS_BENCH ' "$DEPLOY/workstation"
  grep -qE '^ESCALADE_ENV=\(.*PROV_FORGE_ADMIN_RESET' "$DEPLOY/workstation"
  # et le banc du POSTE nomme son humain de demo comme celui du conteneur (ISO, ⚖ user 2026-09-11)
  grep -q 'export LCARS_BUILTIN_HUMAN="${LCARS_BUILTIN_HUMAN:-lcars}"' "$PORTE"
  grep -qE '^ESCALADE_ENV=\(.*LCARS_BUILTIN_HUMAN' "$DEPLOY/workstation"
  # et il traverse le `sudo` — ce qui n'est pas dans ESCALADE_ENV meurt a l'escalade, sans un mot
  grep -q 'PROV_FORGE_MONTEE' "$DEPLOY/workstation"
  grep -qE '^ESCALADE_ENV=\(.*PROV_FORGE_MONTEE' "$DEPLOY/workstation"
}

@test "C1 : la banniere du POSTE ne promet pas ce que fait le CONTENEUR" {
  local bloc; bloc="$(sed -n "/Installation dans ce système.*LCARS s'installe/,/Pour installer en conteneur/p" "$PORTE")"
  [ -n "$bloc" ]
  grep -q 'la forge' <<<"$bloc"
  grep -vE '^[[:space:]]*#' <<<"$bloc" | refute_out 'runner CI|humain de d|deploy/container'
}


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


@test "C4 : le contenu de /usr/share/lcars est rendu a root, pas laisse a l'operateur" {
  local mod="$MODS/44-media.sh"
  # 1. le propriétaire de l'arbre est celui que la table déclare, et la table dit root:root
  grep -qE '^dir +/opt/lcars/share +[0-7]+ +root:root ' "$DEPLOY/system.manifest" \
    || { echo "la table ne déclare plus /opt/lcars/share à root:root : le contenu garderait l'identite de la source (« cp -a » la preserve)"; return 1; }
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


@test "C6 : la copie embarquee emporte services/ — le module en depend LUI-MEME" {
  embarque PROV_EMBEDDED services
  # et l'arbre que le module LIT est bien celui-la
  grep -q 'services' "$MODS/62-runtime-helpers.sh"
}

@test "C6 : le second lecteur de l'arbre est servi lui aussi" {
  grep -q 'product_tree)/services/forge-gestures.sh' "$MODS/25-directories.sh"
  embarque PROV_EMBEDDED services
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

