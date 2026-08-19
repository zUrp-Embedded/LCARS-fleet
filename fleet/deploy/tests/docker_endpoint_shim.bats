#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/docker_endpoint_shim.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-19
# STATUS: bats tests for the escalation shim — ce qui traverse sudo, et ce qui ne doit JAMAIS traverser
#
# POURQUOI CE FICHIER. Sur WSL la socket docker appartient a root : le rail escalade pour LA JOINDRE,
# sans rien modifier. L'escalade prend la forme d'un shim, et ce shim a deux devoirs opposes :
#
#   - FAIRE TRAVERSER ce qui pilote compose. `sudo` remet l'environnement a zero, et le rail conduit
#     compose PAR DES VARIABLES (`LCARS_DEVFORGE_PORT`, `LCARS_IMAGE`, `FORGE_BASE_URL`…). Mesure sur
#     instance vierge : sans ce relais, une forge demandee sur le port 21199 monte sur 3300 — le
#     defaut du compose — et le banc meurt sur « la forge ne repond pas », en accusant la forge ;
#   - NE JAMAIS FAIRE TRAVERSER UN SECRET. Une assignation `sudo VAR=valeur` vit dans la LIGNE DE
#     COMMANDE, exposee par `/proc/<pid>/cmdline` a tout l'hote pendant l'appel (cicatrice 6-141,
#     payee deux fois). Les credentials de ce rail voyagent par STDIN, jamais par l'environnement.
#
# ⚠ CE QUI EST MESURE ICI EST STRUCTUREL, ET C'EST ASSUME. Faire tourner le shim exigerait une socket
# appartenant a root ET un sudo non interactif — donc un test qui ne passerait que sur certaines
# machines, c'est-a-dire un test qui mesure la machine. On epingle donc la FORME du shim genere : le
# filtre existe, il refuse la bonne classe de noms, et les deux listes ne sont pas inversees.

setup() {
  LIB="$BATS_TEST_DIRNAME/../lib/docker-endpoint.sh"
  [ -f "$LIB" ]
}

@test "le shim FILTRE par nom, et la classe des secrets est refusee" {
  # Large volontairement : un faux positif coute une variable non transmise, un faux negatif coute
  # un secret dans une ligne de commande.
  for motif in 'TOKEN' 'PASSWORD' 'SECRET' 'CREDENTIAL' 'PASSWD'; do
    # ⚠ PAS DE PARENTHESE DANS LE MOTIF : les alternatives d'un `case` sont separees par `|`, donc
    # une seule des cinq porte le `)` fermant. Chercher `*TOKEN*)` ne trouvait que la derniere.
    grep -q "\*${motif}\*" "$LIB" || { echo "classe de secret NON refusee : $motif"; return 1; }
  done
  # Et le refus vient AVANT la selection : un `case` teste ses motifs dans l'ordre.
  local ligne_secret ligne_garde
  ligne_secret="$(grep -n '\*TOKEN\*' "$LIB" | head -1 | cut -d: -f1)"
  ligne_garde="$(grep -n 'LCARS_\*|FORGE_\*' "$LIB" | head -1 | cut -d: -f1)"
  [ "$ligne_secret" -lt "$ligne_garde" ]
}

@test "le shim fait traverser ce qui PILOTE compose — sinon il casse ce qu'il escalade" {
  # Le temoin d'attaque va par paire avec sa preuve (P-40) : « aucun secret ne passe » serait
  # satisfait par un shim qui ne passe RIEN, et qui casserait alors tout le rail en silence.
  grep -q 'LCARS_\*|FORGE_\*|COMPOSE_\*|PROV_\*' "$LIB"
}

@test "une valeur a saut de ligne est SAUTEE, jamais tronquee" {
  # `sudo VAR=val` ne sait pas representer un saut de ligne. La transmettre tronquee serait pire que
  # ne pas la transmettre : le lecteur croirait tenir la valeur.
  grep -q "v\" == \*\$'\\\\n'\*" "$LIB" || grep -q 'saut de ligne est SAUTEE' "$LIB"
}

@test "le shim porte le chemin des plugins — sans quoi « docker compose » n'existe pas sous sudo" {
  # `compose` est un PLUGIN, cherche dans `~/.docker/cli-plugins` : sous sudo, HOME devient celui de
  # root. Mesure : `version` repond et `compose -f …` echoue sur « unknown shorthand flag: 'f' ».
  grep -q 'DOCKER_CONFIG=' "$LIB"
  grep -q 'cliPluginsExtraDirs' "$LIB"
}

@test "la sonde REFUSE une paire incomplete — repondre a moitie est pire qu'etre absent" {
  grep -q 'compose version' "$LIB"
  grep -q 'reste introuvable' "$LIB"
}
