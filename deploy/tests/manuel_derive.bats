#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/manuel_derive.bats
# AUTHOR: bob
# STARDATE: 2026-09-17
# STATUS: actif — MUR 22 : le manuel du site et les scripts de la console disent les mêmes verbes
#
# POURQUOI CE MUR EXISTE ICI ET PAS SEULEMENT DANS LE SITE.
#
# `manuel.astro` porte déjà son appariement : un verbe sans prose casse `npm run build`. Mais
# AUCUNE porte du dépôt ne bâtit le site — ni `deploy/gate.sh`, ni `mix gate`. Cette garde ne se
# déclenchait donc qu'à l'installation, dans le module 44, sur la machine de quelqu'un : un verbe
# ajouté à `bin/lcars` faisait tomber une installation entière, des jours plus tard, sur une ligne
# qui parle d'Astro. Mesuré le 2026-09-17 sur un banc vierge, où `lcars project adopt-system`
# (posé la veille) a mis `44-media` en échec.
#
# Le mur relit la MÊME source que le site (`lib/cli.js`, qui lit les deux scripts) et les MÊMES
# clés de prose, sans Astro ni `node_modules` : ce qu'il mesure est l'appariement, pas le rendu.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SITE="$REPO/assets/github.io"
  MANUEL="$SITE/src/pages/manuel.astro"
  command -v node >/dev/null || skip "node absent — le manuel se dérive des scripts par lib/cli.js"
  [ -f "$MANUEL" ] || skip "le site n'est pas dans cet arbre (livraison sans assets/)"
}

# les clés de prose d'un objet du manuel. Le bloc est ÉVALUÉ comme du JavaScript, pas lu au motif :
# le site fait `Object.keys` dessus, et une clé en guillemets doubles ou indentée autrement est le
# même objet pour lui. Un mur qui lirait le texte accuserait le manuel d'un défaut de mise en forme.
prose_de() { # prose_de <FLEET|LCARS>
  node --input-type=module -e '
    import { readFileSync } from "node:fs";
    const [fichier, nom] = process.argv.slice(1);
    const src = readFileSync(fichier, "utf8");
    const apres = src.split("const " + nom + " = {")[1];
    if (apres === undefined) { console.error("objet " + nom + " introuvable"); process.exit(1); }
    const bloc = apres.split("\n};")[0];
    const o = new Function("return {" + bloc + "\n}")();
    for (const k of Object.keys(o)) console.log(k);
  ' "$MANUEL" "$1"
}

lus_de() { # lus_de <fleet|lcars> — les verbes que lib/cli.js lit dans les scripts
  # `import()` et non `require()` : cli.js est un module ES, et `require(esm)` dépend de la version
  # de node — un mur qui tombe sur la toolchain accuserait le manuel à sa place
  node --input-type=module -e '
    const [site, quoi] = process.argv.slice(1);
    const cli = await import(new URL("src/lib/cli.js", "file://" + site + "/").href);
    const v = quoi === "fleet" ? cli.fleetVerbs() : cli.lcarsEntries().map((e) => e.verb);
    for (const x of new Set(v)) console.log(x);
  ' "$SITE" "$1"
}

# LES DEUX CÔTÉS DOIVENT AVOIR PARLÉ. `comm` de deux listes vides est vide : un node qui échoue des
# deux côtés rendrait ce mur VERT sans rien avoir lu.
apparie() { # apparie <fleet|lcars> <FLEET|LCARS>
  local lus prose sans_prose sans_verbe
  lus="$(lus_de "$1")" || { echo "lecture des verbes de « $1 » en échec"; return 1; }
  prose="$(prose_de "$2")" || { echo "lecture de la prose « $2 » en échec"; return 1; }
  [ -n "$lus" ] || { echo "aucun verbe lu pour « $1 » — lib/cli.js n'a rien rendu"; return 1; }
  [ -n "$prose" ] || { echo "aucune prose lue pour « $2 » — manuel.astro n'a rien rendu"; return 1; }
  sans_prose="$(comm -23 <(sort -u <<<"$lus") <(sort -u <<<"$prose"))"
  sans_verbe="$(comm -13 <(sort -u <<<"$lus") <(sort -u <<<"$prose"))"
  [ -z "$sans_prose" ] || { echo "verbes de $1 sans prose dans manuel.astro :"; echo "$sans_prose"; return 1; }
  [ -z "$sans_verbe" ] || { echo "prose de manuel.astro sans verbe dans $1 :"; echo "$sans_verbe"; return 1; }
}

@test "MUR 22: chaque verbe de « fleet » a sa prose dans le manuel, et chaque prose a son verbe" {
  apparie fleet FLEET
}

@test "MUR 22: chaque verbe de « lcars » a sa prose dans le manuel, et chaque prose a son verbe" {
  apparie lcars LCARS
}

@test "instrument : le mur voit un verbe sans prose — retirer une prose le rend rouge" {
  # la mesure se fait sur une COPIE : on n'ecrit pas dans l'arbre pour se prouver qu'on sait lire.
  # Retirer une prose, c'est exactement ce que fait un verbe AJOUTE au script : un nom lu d'un cote
  # et absent de l'autre. La garde du site ne distingue pas les deux, le mur non plus.
  # la mutilation RENOMME la cle plutot que de la retirer : retirer sa ligne de tete couperait une
  # chaine gabarit en deux et le manuel ne serait plus du JavaScript — on mesurerait l'accident.
  local faux="$BATS_TEST_TMPDIR/manuel.astro" victime
  victime="$(prose_de LCARS | head -1)"
  [ -n "$victime" ]
  sed "s|^\(  .\)$victime\(.:\)|\1$victime-qui-nexiste-pas\2|" "$MANUEL" > "$faux"

  # arme : le mur JOUE sur le manuel mutile doit tomber, et NOMMER le verbe orphelin
  local avant="$MANUEL"; MANUEL="$faux"
  run apparie lcars LCARS
  MANUEL="$avant"
  [ "$status" -ne 0 ] || { echo "le mur est reste vert sur un manuel mutile"; return 1; }
  [[ "$output" == *"$victime"* ]] || { echo "le mur n'a pas nomme « $victime » : $output"; return 1; }

  # desarme : sur le manuel de l'arbre, le meme mur est vert — sinon il crie toujours
  apparie lcars LCARS

  # et une cle REECRITE, sans changer l'objet, reste verte : le mur lit du JavaScript, pas du texte.
  # Guillemets doubles et indentation differente sont le meme objet pour le site ; un mur au motif
  # accuserait le manuel d'un verbe manquant qui est la.
  sed "s|^  '$victime':|    \"$victime\":|" "$MANUEL" > "$faux"
  MANUEL="$faux"; run apparie lcars LCARS; MANUEL="$avant"
  [ "$status" -eq 0 ] || { echo "une cle reecrite a rendu le mur rouge : $output"; return 1; }
}

@test "instrument : une toolchain muette ne rend pas le mur VERT — deux listes vides ne s'apparient pas" {
  # `comm` de deux listes vides est vide : sans ce garde, un node cassé (version, module ES, site
  # absent de l'arbre) ferait passer les deux murs sans qu'aucun des deux cotes n'ait ete lu.
  local faux_bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$faux_bin"
  printf '#!/bin/sh\nexit 1\n' > "$faux_bin/node"; chmod 0755 "$faux_bin/node"
  local avant="$PATH"; PATH="$faux_bin:$PATH"
  run apparie lcars LCARS
  PATH="$avant"
  [ "$status" -ne 0 ] || { echo "le mur est vert alors que node ne rend rien"; return 1; }
  [[ "$output" == *"en échec"* || "$output" == *"n'a rien rendu"* ]] || { echo "$output"; return 1; }
}
