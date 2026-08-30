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

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

load refute

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

# ─── docker_compose_cmd — UNE SEULE REPONSE A « QUEL COMPOSE » ──────────────────────────────────
#
# ⚠ ELLE A VECU EN DEUX EXEMPLAIRES — une resolution dans la porte, un DEFAUT dans le delegue. Deux
# detections pour un fait donnent deux verdicts possibles selon la porte empruntee — et celui qu'on
# ne lit pas est celui qui decide le jour ou ca casse. Elle vit ici, a cote de la sonde d'endpoint,
# en un exemplaire ; chaque porte la joue puis TRANSMET son resultat.

compose_lib() { # compose_lib <script> — joue la fonction dans un shell decore
  run bash -c ". '$LIB' >/dev/null 2>&1; $1"
}

@test "compose: le plugin est prefere, et il porte le binaire qu'on lui donne" {
  local bin="$BATS_TEST_TMPDIR/mydocker"
  printf '#!/usr/bin/env bash\n[[ "$1" == compose ]] && exit 0\nexit 1\n' > "$bin"; chmod +x "$bin"
  compose_lib "docker_compose_cmd '$bin' && echo \"[\$PROV_COMPOSE_CMD]\""
  [[ "$output" == *"[$bin compose]"* ]]
}

@test "compose: sans plugin, l'autonome prend le relais" {
  local bin="$BATS_TEST_TMPDIR/nodocker"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin"; chmod +x "$bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/docker-compose"
  chmod +x "$BATS_TEST_TMPDIR/docker-compose"
  compose_lib "PATH='$BATS_TEST_TMPDIR:\$PATH'; docker_compose_cmd '$bin' && echo \"[\$PROV_COMPOSE_CMD]\""
  [[ "$output" == *"[docker-compose]"* ]]
}

@test "compose: aucune des deux formes -> REFUS nomme, jamais une commande vide" {
  # ⚠ Un `PROV_COMPOSE_CMD` vide rendu avec un code 0 ferait lancer `"" -f … up` : le rail
  # echouerait sur « command not found » en accusant le compose, pas l'absence.
  local bin="$BATS_TEST_TMPDIR/nodocker2"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin"; chmod +x "$bin"
  compose_lib "PATH='$BATS_TEST_TMPDIR/vide'; docker_compose_cmd '$bin' && echo OUI || echo \"NON [\$PROV_COMPOSE_WHY]\""
  [[ "$output" == *"NON ["* ]]
  [[ "$output" == *"compose est absent"* ]]
}

@test "compose: qui SONDE nomme sa reponse a qui CONSOMME — jamais un second defaut" {
  # ⚠ CE TEMOIN A EPINGLE UN FICHIER, ET LE FICHIER A BOUGE. Sa premiere forme cherchait le cablage
  # dans la porte ; l'etape qui a fait passer le preflight dans le delegue l'a rendu rouge sans que
  # rien ne soit casse. Ce qui se tient est la REGLE : celui qui sonde pose `PROV_COMPOSE_CMD`, et
  # celui qui lance compose le LIT — sans repli, parce qu'un repli est la seconde reponse qu'on
  # vient de supprimer.
  local box="$BATS_TEST_DIRNAME/../box"
  grep -q 'docker_compose_cmd || fail' "$box"
  grep -q 'COMPOSE=(\$PROV_COMPOSE_CMD)' "$box"
  refute grep -q 'LCARS_COMPOSE_CMD:-' "$box"
  # Et personne ne redecouvre : une seconde detection dans l'arbre rendrait deux verdicts possibles.
  [ "$(grep -rl 'compose version >/dev/null' "$BATS_TEST_DIRNAME/../.." --include='*.sh' --include=box --include=provision 2>/dev/null | wc -l)" -le 1 ]
}

# ─── LE REFUS ACCUSE LA PREMIERE SOCKET, PAS LA DERNIERE ────────────────────────────────────────
#
# ⚠ MESURE D'UN BANC WSL A INTEGRATION ACTIVEE (2026-08-30) : le message de refus nommait
# `docker.proxy.sock` en `root:root 755`, alors que la socket qui compte est `/var/run/docker.sock`
# en `root:docker 660` — refusee faute d'appartenance au groupe, ce qui est une cause TOUTE AUTRE et
# un geste tout autre. Le balayage voit la seconde d'abord, la premiere ensuite, et l'affectation
# ecrasait : c'est donc le dernier repli qui parlait, jamais la cause.
#
# Un diagnostic qui accuse le mauvais objet coute plus qu'un diagnostic absent — il envoie chercher
# la panne la ou elle n'est pas.

@test "le premier refus est celui qu'on garde — l'affectation ne s'ecrase pas" {
  # La FORME, comme tout ce fichier : jouer la boucle demanderait deux sockets refusees et un daemon
  # qui repond, c'est-a-dire une machine precise. `:=` n'affecte que si la variable est vide.
  local code; code="$(grep -vE '^\s*#' "$LIB")"
  grep -q ': "${PROV_DOCKER_SOCK:=$sock}"' <<<"$code"
  refute grep -q 'PROV_DOCKER_SOCK="$sock"' <<<"$code"
}

@test "TEMOIN DU TEMOIN : l'affectation conditionnelle garde la premiere, l'affectation nue la derniere" {
  # Sans lui, le temoin ci-dessus epingle une syntaxe sans prouver qu'elle fait ce qu'on lui prete —
  # et le jour ou quelqu'un la « simplifie », rien ne dira ce qui a ete perdu.
  run bash -c 'p=""; for s in premiere derniere; do : "${p:=$s}"; done; echo "$p"'
  [ "$output" = "premiere" ]
  run bash -c 'p=""; for s in premiere derniere; do p="$s"; done; echo "$p"'
  [ "$output" = "derniere" ]
}

# ─── LE `DOCKER_CONFIG` SE POSE SUR UNE MESURE, PAS SUR UN SUBSTRAT ─────────────────────────────

@test "le DOCKER_CONFIG n'est fabrique que si compose ne repond PAS — jamais par deduction" {
  # ⚠ CE QUE CETTE CONDITION COUTAIT, MESURE SUR UN BANC WSL A INTEGRATION ACTIVEE (2026-08-30).
  # Elle portait sur « substrat WSL ET la CLI du montage » — vrai sur toute distro integree, ou
  # `docker compose version` repond pourtant NU. Le config fabrique remplacait alors celui de
  # l'humain, donc ses CONTEXTS :
  #     contexts AVANT : default desktop-linux
  #     contexts APRES : default
  # Le rail ne s'en apercevait pas (il porte `DOCKER_HOST`) ; l'humain qui herite de cet
  # environnement, si. Un contournement ecrit contre le montage NU s'appliquait la ou il n'a plus
  # d'objet — et il n'etait pas neutre.
  local code; code="$(grep -vE '^\s*#' "$LIB")"
  local cond; cond="$(grep -n 'DOCKER_CONFIG:-' <<<"$code" | head -1)"
  [ -n "$cond" ]
  # La mesure, et pas la deduction : `compose version` decide, `detect_substrate` n'a rien a y faire.
  grep -qE 'DOCKER_CONFIG:-.*\]\] && ! "\$PROV_DOCKER_BIN" compose version' <<<"$code"
  refute grep -qE 'detect_substrate.*==.*wsl.*&&.*_docker_mount_cli.*&&.*DOCKER_CONFIG' <<<"$code"
}
