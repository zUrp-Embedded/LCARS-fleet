#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/deck_doc.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for the /doc/ route — l'arbre servi doit etre LISIBLE PAR CELUI QUI LE SERT
#
# CE QUE CES TEMOINS TIENNENT, et ce n'est pas une question de rangement. La plaquette est batie par
# le stage `site` du Dockerfile, copiee dans l'image, et le deck la sert sous `/doc/`. Toute cette
# chaine etait juste en source, et elle rendait 404 sur des fichiers presents.
#
# LA CAUSE : la doc etait posee dans `/opt/lcars/runtime/doc`, sous le verrou RO du prefixe de release
# (`750 root:fleet`, fichiers `640`) — pose par le `chmod -R u=rwX,g=rX,o=` du meme Dockerfile. Le
# deck largue ses privileges vers son compte de service (`lcars-system`) : il ne pouvait ni traverser le repertoire ni
# ouvrir un fichier. Chaque `open()` levait, le handler rendait son 404, et ce 404 est honnete sur
# « je n'ai pas pu lire » tout en etant MUET sur la raison : il ne distingue pas l'absent de
# l'interdit. Mesure du 2026-08-20, banc neuf et session OIDC reelle : 9 pages dans l'image,
# `/doc/`, `/doc/manuel/` et `/doc/outils/` tous en 404.
#
# ⚠ LE PIEGE EST UN ORDRE, PAS UN CHEMIN, et c'est pour ca qu'un temoin sur le seul chemin ne
# suffirait pas. Le `chmod` frappe un ARBRE : n'importe quel `COPY` place AVANT lui, ou dessous, se
# fait retirer `o` — sans qu'aucune ligne ne parle de la doc. Le second temoin tient cet ordre.
#
# La reponse n'est pas d'affaiblir le verrou : ce qu'il protege est le runtime deploye. La doc n'est
# pas du binaire livre, c'est de l'actif statique pour le deck, et la porte n'est pas le mode du
# fichier — c'est la session OIDC devant la route.

setup() {
  DOCKERFILE="$BATS_TEST_DIRNAME/../docker/Dockerfile"
  DECK="$BATS_TEST_DIRNAME/../../services/console-deck.py"
  [ -f "$DOCKERFILE" ]
  [ -f "$DECK" ]
  # La destination du `COPY --from=site`, telle qu'ecrite dans l'image.
  DOC_DEST="$(grep -E '^COPY --from=site ' "$DOCKERFILE" | awk '{print $NF}')"
  # Le defaut du serveur, celui qui vaut quand personne ne pose la variable — et personne ne la pose.
  DECK_DEFAULT="$(grep -oE 'LCARS_DECK_DOC", "[^"]+' "$DECK" | sed 's/.*, "//')"
}

@test "la doc est servie depuis LE MEME chemin que celui ou l'image la pose" {
  # Deux ecritures d'un meme fait derivent. Ici la derive est SILENCIEUSE dans les deux sens : un
  # deck qui pointe ailleurs rend 404 sur une image complete, une image qui pose ailleurs rend 404
  # sur un deck correct — et le message est le meme.
  [ -n "$DOC_DEST" ]
  [ -n "$DECK_DEFAULT" ]
  [ "$DOC_DEST" = "$DECK_DEFAULT" ]
}

@test "la doc est HORS du prefixe de release — le verrou RO y interdit sa lecture" {
  # Le prefixe est `750 root:fleet` et le deck ne tourne PAS dans le groupe `fleet` : tout ce qui vit dessous
  # lui est illisible, quel que soit le mode du fichier lui-meme.
  [[ "$DOC_DEST" != /opt/lcars/runtime* ]]
  [[ "$DECK_DEFAULT" != /opt/lcars/runtime* ]]
}

@test "le COPY de la doc vient APRES le chmod qui retire les droits « autres »" {
  # ⚠ LE TEMOIN QUI TIENT LA VRAIE CICATRICE. Le `chmod -R …,o=` frappe l'ARBRE du prefixe : ce qui
  # compte n'est pas seulement ou la doc atterrit, mais qu'aucune passe de durcissement ne repasse
  # dessus ensuite. Un `COPY` remonte de quelques lignes suffit a tout re-casser sans qu'une seule
  # ligne ne mentionne la doc.
  local copy_line chmod_line
  copy_line="$(grep -nE '^COPY --from=site ' "$DOCKERFILE" | cut -d: -f1)"
  chmod_line="$(grep -nE '^\s+&& chmod -R u=rwX,g=rX,o= /opt/lcars/runtime' "$DOCKERFILE" | cut -d: -f1)"
  [ -n "$copy_line" ]
  [ -n "$chmod_line" ]
  [ "$copy_line" -gt "$chmod_line" ]
}

@test "l'arbre servi est rendu lisible EXPLICITEMENT, jamais par heritage du COPY" {
  # `COPY` conserve les modes de l'etage source (`node:<majeure>-slim`), qui ne nous doit rien. Un arbre
  # servi doit dire lui-meme qu'il est lisible ; l'heritage est une hypothese sur une image amont.
  grep -qE "^RUN chmod -R a\+rX ${DOC_DEST%/doc}\$" "$DOCKERFILE"
}

@test "l'image pose les MEDIAS a cote de la doc — une source installee, lue par tous" {
  # ⚠ TROIS EXEMPLAIRES AVAIENT DERIVE. Les memes avatars vivaient dans `assets/avatars/` (la
  # marque), `fleet/deploy/deps/avatars/` (les png de la charte forge) et
  # `fleet/priv/observation/static/assets/` (les svg du deck) : sept des neuf roles communs
  # differaient, parce qu'une mise a jour touchait un dossier et pas les autres. La source est
  # `assets/`, l'installation la pose ici, et les deux lecteurs — le deck d'observation et
  # `provision-forge-charte.sh` — visent cette racine.
  local root="${DOC_DEST%/doc}"
  grep -qE "^COPY assets/avatars +${root}/avatars\$" "$DOCKERFILE"
  grep -qE "^COPY assets/favicon +${root}/favicon\$" "$DOCKERFILE"
  # Les deux dossiers qui portaient les copies ont disparu, sinon elles repousseraient.
  [ ! -d "$BATS_TEST_DIRNAME/../deps/avatars" ]
  [ ! -d "$BATS_TEST_DIRNAME/../../priv/observation/static/assets" ]
}

@test "la source porte les DEUX formats — le png n'est pas un derive du svg" {
  # Gitea decode png/jpeg/gif et PAS le svg : le raster est de la matiere, pas une projection. Et
  # aucun rasteriseur n'existe dans le runtime — le generer au boot est impossible, le generer au
  # build exigerait un outil de plus pour un fichier qui ne change qu'a la main.
  local src="$BATS_TEST_DIRNAME/../../../assets/avatars"
  [ -d "$src" ]
  local r
  for r in architect starfleet vulcan; do
    [ -f "$src/$r.svg" ] || { echo "svg manquant : $r"; return 1; }
    [ -f "$src/$r.png" ] || { echo "png manquant : $r"; return 1; }
  done
}

@test "la route /doc/ refuse de sortir de sa racine — \`..\` reste la plus vieille faute du web" {
  # Le prefixe voisin porte les jetons de la boite : une remontee ici ne serait pas un defaut de
  # confort. La garde est `realpath` + comparaison de prefixe, pas un filtrage de la chaine.
  grep -q 'os.path.realpath(os.path.join(DECK_DOC, rel))' "$DECK"
  grep -q 'full == root or full.startswith(root + os.sep)' "$DECK"
}

@test "VERROU : toute racine de catalogue que le SITE nomme est copiee dans son stage" {
  # ⚠ MESURE DU 2026-08-23 : l'image etait INCONSTRUCTIBLE depuis la veille. `catalogue.js` nomme
  # trois catalogues — deux sous `fleet/priv/`, et `web-demo` a la RACINE du depot. Le stage `site`
  # copiait `assets/` et `fleet/`, jamais `catalogues/`. Donc `existsSync` faux, `throw`,
  # `npm run build` exit 1, et le build de l'IMAGE meurt — pas seulement celui de la doc.
  #
  # ⚠ ET RIEN NE POUVAIT LE VOIR. Le site ne se batit qu'au build d'image : `mix gate` ne touche pas
  # ce stage, `shell_gate` ignore son existence. Gate entierement vert, produit inconstructible,
  # pendant douze heures. Ce temoin est le seul endroit ou les deux listes se rencontrent SANS
  # docker — il ne bat pas l'image, il compare deux textes.
  local js="$BATS_TEST_DIRNAME/../../../assets/github.io/src/lib/catalogue.js"
  local df="$BATS_TEST_DIRNAME/../docker/Dockerfile"
  [ -f "$js" ] && [ -f "$df" ]

  # Ce que le stage `site` copie : les lignes COPY entre `AS site` et son `npm run build`.
  # ⚠ LA BORNE EST ANCRÉE (`^RUN`), et elle ne l'était pas. Le commentaire qui explique ce témoin
  # contient les mots `npm run build` : une borne non ancrée fermait la plage sur la PROSE, donc le
  # `COPY catalogues` qu'elle décrit tombait hors du champ et le témoin rougissait sur son propre
  # texte. Même classe que l'extraction de `native_list` — un instrument qui lit du code doit borner
  # sur du code.
  local copied; copied="$(sed -n '/AS site/,/^RUN npm run build/p' "$df" | sed -n 's/^COPY \([^ ]*\).*/\1/p')"
  [ -n "$copied" ]

  # Les racines que le site nomme, cote depot : `PRIV` -> fleet/priv, `CATALOGUES` -> catalogues.
  # On ne lit pas les noms de catalogues (ils bougent), on lit les RACINES (elles sont deux).
  grep -q 'PRIV' "$js"
  grep -q 'CATALOGUES' "$js"
  # `fleet` couvre PRIV ; `catalogues` couvre CATALOGUES. Chacune doit etre copiee.
  printf '%s\n' "$copied" | grep -qx 'fleet'
  printf '%s\n' "$copied" | grep -qx 'catalogues'
}
