#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/poseurs.bats
# AUTHOR: bob
# STARDATE: 2026-09-01
# STATUS: bats tests — ce que les poseurs laissent derrière eux

# shellcheck disable=SC2030,SC2031

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/.."
  MODS="$DEPLOY/modules.d"
  [ -d "$MODS" ]
}

embarque() { sed -n "s/^$1=//p" "$DEPLOY/installer-constants.env" | tr ' ' '\n' | grep -qx "$2"; }   # embarque <liste des constantes> <arbre>

@test "~/.lcars/log est posé en 0700 par l'apply de 70-human, pas laissé au umask" {
  local mod="$BATS_TEST_DIRNAME/../../runtime/services/human.d/70-human.sh"
  local ligne; ligne="$(grep -n 'chmod 0700' "$mod" | head -1)"
  [ -n "$ligne" ]
  grep -q 'chmod 0700 .*\.lcars/log' "$mod"
}

@test "le check de 70-human regarde ~/.lcars/log — sinon le doctor ne voit pas ce que l'apply pose" {
  local mod="$BATS_TEST_DIRNAME/../../runtime/services/human.d/70-human.sh"
  local bloc; bloc="$(sed -n '/^check()/,/^}$/p' "$mod")"
  grep -q '\.lcars/log' <<<"$bloc"
}


@test "le contenu de la racine des medias est rendu a root, pas laisse a l'operateur" {
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


@test "ce que les modules LISENT a la RACINE (repo_root) est ce qui est embarque" {
  local lus; lus="$(grep -rhoE 'repo_root\)/[a-z]+' "$MODS"/*.sh "$DEPLOY"/lib/*.sh 2>/dev/null \
    | sed 's|repo_root)/||' | sort -u | grep -vx runtime)"
  local n
  for n in $lus; do
    embarque PROV_EMBEDDED_ROOT "$n" \
      || { echo "lu sous repo_root mais PAS embarque : $n"; return 1; }
  done
}

@test "ce que les modules LISENT dans l ARBRE PRODUIT (product_tree) est dans EMBEDDED" {
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


# ⚠ MUR : AUCUN PROPRIETAIRE N'EST UN LITTERAL DE SERVICE — LA GENERALISATION DE CELUI DU DESSUS
#
# Le temoin de `44-media` porte deja la phrase qui explique POURQUOI un mur textuel est necessaire
# ici : « sous un decor tout appartient a qui le joue : le proprietaire ne se mesure pas, il se lit
# dans le code ». Ce n'est pas une facon de parler. `prov_owner` rend le joueur du banc quoi qu'on
# lui demande des que `LCARS_DECOR_ROOT` est pose, donc `prov_check_mode` compare le joueur au
# joueur : LA MOITIE « PROPRIETAIRE » DE LA VERIFICATION EST TAUTOLOGIQUE DANS TOUT LE CORPUS DE
# BANC, et `ensure_mode` ne pose jamais le proprietaire demande. Un module qui reclamerait
# « lcars-systeme:flotte » au lieu de « lcars-system:fleet » passerait tous les bancs au vert.
#
# La compensation existait pour UN module sur la quinzaine de sites qui passent un proprietaire.
# Celui-ci la porte a tous, et la propriete est celle que l'arbre tient deja (mesure du 2026-09-20,
# quinze sites, aucun ecart) : un proprietaire est DERIVE — du manifeste, d'une constante, d'une
# variable — ou c'est `root`, qui ne derive de rien et n'appartient a personne d'autre.
#
# ⚠ `root` EST LA SEULE EXCEPTION, ET ELLE EST STRUCTURELLE : aucune constante ne le declare parce
# qu'il n'y a rien a declarer. Un nom de service, lui, est cree par l'installeur, nomme dans
# `system.manifest`, et lu par le produit : trois endroits qui doivent dire la meme chose.

# origine <fichier> <argument> — resout UN niveau : « $X » devient la droite de « X=… » du fichier
_poseur_origine() {
  local f="$1" a="$2" nom rhs
  if [[ "$a" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ ]]; then
    nom="${BASH_REMATCH[1]}"
    rhs="$(sed -n "s/^${nom}=//p" "$f" | head -n1)"
    [[ -z "$rhs" ]] || a="$rhs"
  fi
  printf '%s' "$a"
}

# reste <expression> — retire tout ce qui est DERIVE, et rend ce qui a ete ecrit en dur
_poseur_reste() {
  printf '%s' "$1" \
    | sed -E 's/\$\(prov_manifest_owner[^)]*\)/root/g' \
    | sed -E 's/\$\(prov_owner[[:space:]]*//g; s/\)//g' \
    | sed -E 's/\$\{[^}]*\}//g' \
    | sed -E 's/\$[A-Za-z_][A-Za-z0-9_]*//g' \
    | tr -d "\"' ("
}

@test "MUR: tout proprietaire pose est DERIVE (manifeste, constante, variable) ou vaut root" {
  local repo f arg src r sites=0 fautifs=""
  repo="$(cd "$DEPLOY/.." && pwd)"

  # ⚠ LE CHEMIN DE LA PREUVE SE LIT TEL QU'ON LE TAPE : `$MODS` vaut « …/tests/../modules.d », et
  # une evidence en « deploy/tests/../modules.d/48-forge-host.sh » n'est retrouvable par personne.
  for f in "$repo"/deploy/modules.d/*.sh "$repo"/runtime/services/container/*.sh "$repo"/runtime/services/*.sh \
           "$repo"/runtime/services/forge.d/*.sh "$repo"/runtime/services/human.d/*.sh; do
    [ -f "$f" ] || continue
    while IFS= read -r arg; do
      [ -n "$arg" ] || continue
      sites=$((sites + 1))
      src="$(_poseur_origine "$f" "$arg")"
      r="$(_poseur_reste "$src")"
      [[ "$r" =~ ^(root)?:?(root)?$ ]] || fautifs="$fautifs ${f#"$repo"/}:«$arg»"
    done < <(sed 's/#.*//' "$f" \
              | grep -oE '(ensure_dir|ensure_mode|write_atomic|prov_check_mode) "[^"]*" [0-9]{3,4} "[^"]*"' \
              | sed -E 's/.* [0-9]+ "//; s/"$//')
  done

  [ -z "${fautifs// /}" ] || {
    echo "proprietaire(s) ecrit(s) en dur :$fautifs" >&2
    echo "→ un nom de service est cree par l'installeur, declare dans deploy/system.manifest et lu" >&2
    echo "  par le produit : ecrit en dur ici, il derive sans que rien ne rougisse — SOUS UN DECOR" >&2
    echo "  le proprietaire n'est PAS pose (prov_owner rend le joueur), donc aucun banc ne le voit." >&2
    echo "  Le prendre de « prov_manifest_owner », d'une constante PROV_*/LCARS_*, ou dire root." >&2
    return 1
  }
  # GARDE D'INSTRUMENT : sans population, ce mur serait vert en ne lisant rien.
  [ "$sites" -ge 12 ] || { echo "MUR — seulement $sites site(s) lus : l'extraction ne trouve plus les poses" >&2; return 1; }
}
