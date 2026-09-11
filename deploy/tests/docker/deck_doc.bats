#!/usr/bin/env bats
# SOURCE: deploy/tests/docker/deck_doc.bats
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
  DOCKERFILE="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  DECK="$BATS_TEST_DIRNAME/../../../runtime/services/console-deck.py"
  [ -f "$DOCKERFILE" ]
  [ -f "$DECK" ]
  # La destination du `COPY --from=site`, telle qu'ecrite dans l'image.
  DOC_DEST="$(grep -E '^COPY --from=site ' "$DOCKERFILE" | awk '{print $NF}')"
  # Le defaut du serveur, celui qui vaut quand personne ne pose la variable — et personne ne la pose.
  DECK_DEFAULT="$(grep -oE 'LCARS_DECK_DOC", "[^"]+' "$DECK" | sed 's/.*, "//')"
}

@test "la doc est HORS du prefixe de release — le verrou RO y interdit sa lecture" {
  # Le prefixe est `750 root:fleet` et le deck ne tourne PAS dans le groupe `fleet` : tout ce qui vit dessous
  # lui est illisible, quel que soit le mode du fichier lui-meme.
  [[ "$DOC_DEST" != /opt/lcars/runtime* ]]
  [[ "$DECK_DEFAULT" != /opt/lcars/runtime* ]]
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
  # Le prefixe voisin porte les jetons du conteneur : une remontee ici ne serait pas un defaut de
  # confort. La garde est `realpath` + comparaison de prefixe, pas un filtrage de la chaine.
  grep -q 'os.path.realpath(os.path.join(DECK_DOC, rel))' "$DECK"
  grep -q 'full == root or full.startswith(root + os.sep)' "$DECK"
}
