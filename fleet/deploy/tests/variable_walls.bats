#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/variable_walls.bats
# AUTHOR: vanille
# STARDATE: 2026-08-27
# STATUS: actif — les invariants d'ECRITURE des variables, tenus par une mesure et non par la relecture
#
# ─── POURQUOI CE FICHIER ────────────────────────────────────────────────────────────────────────
# Les defauts que l'inventaire des variables a trouves ne sont pas des fautes de frappe : ce sont
# des FORMES. Un repli ecrit contre un cas qui ne peut pas arriver, un nom recopie sans arbitre,
# une valeur inventee la ou l'absence est un fait. Une forme ne se corrige pas une fois — elle se
# refuse, sinon elle revient par le prochain fichier, ecrit par quelqu'un qui n'a lu aucun des
# precedents.
#
# ⚠ ON MESURE LE CODE, PAS LA PROSE — meme regle que `adminite_walls.bats`, et pour la meme raison :
# les cicatrices de ce depot NOMMENT ce qu'elles interdisent, c'est leur metier. Un mur qui lirait
# les commentaires interdirait de les ecrire.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # fleet/

  # ⚠ LE PERIMETRE SE DIT PAR SHEBANG, ET C'EST L'INVARIANT LUI-MEME QUI L'EXIGE. `EUID` n'est pose
  # que par bash : dans un fichier `#!/bin/sh`, `${EUID:-...}` est un repli LEGITIME, et un mur qui
  # balaierait `*.sh` l'accuserait a tort. Dans l'autre sens, balayer par extension raterait
  # `bin/fleet_v2`, `bin/lcars`, `deploy/box`, `deploy/provision`, `deploy/accept` — des programmes
  # bash sans suffixe. La question n'est pas « quel nom porte le fichier » mais « quel interprete
  # le lit », et la seule reponse est sur sa premiere ligne.
  #
  # ⚠ CE QUI EST EXCLU, ET CE QUI NE L'EST PAS — la premiere redaction de ce commentaire disait
  # « tests hors perimetre », et c'etait FAUX de son propre instrument : `*/tests/*` ne retire que
  # les suites de `deploy/tests/` et `git-hooks/tests/`, pas les 32 fichiers bash de `test/`, qui
  # SONT balayes. La mesure du 2026-08-27 : deploy 41 · test 32 · bin 11 · services 8 ·
  # git-hooks 4 · etc 3 · vendor 2 · priv 1 = 102.
  #
  # Et c'est le bon perimetre : un repli mort dans un temoin est une affirmation fausse comme
  # ailleurs. La seule exclusion NECESSAIRE est celle des fichiers de mur eux-memes — la liste de
  # variables ci-dessous est du CODE, donc un mur inclus dans son propre balayage s'accuse au
  # premier motif qu'il epingle. `*/tests/*` la couvre, et c'est sa vraie raison d'etre.
  mapfile -t BASH_CODE < <(
    find "$REPO" -type f \
      -not -path '*/tests/*' -not -path '*/_build/*' -not -path '*/deps/*' -not -path '*/.git/*' \
      2>/dev/null \
      | while read -r f; do
          head -1 "$f" 2>/dev/null | grep -qE '^#!.*(bash|bats)' && echo "$f"
        done | sort
  )
}

# Le code d'un fichier, prose retiree. La troncature sur un `#` qui n'ouvre pas un commentaire
# (`${VAR#motif}`, `"$#"`) fait PERDRE de la fin de ligne : le mur peut donc sous-compter, jamais
# accuser a tort. C'est le sens qui protege.
code_of() { sed 's/#.*//' "$1"; }

@test "MUR: le perimetre n'est pas VIDE — un balayage casse compte zero, comme un sans-faute" {
  # Sans ce garde, un `find` qui ne trouve plus rien (arbre deplace, `head -1` qui change de forme)
  # rendrait le mur vert en n'ayant rien lu. C'est la forme d'echec la plus chere : elle certifie.
  # ⚠ UN PLANCHER NE VOIT PAS LA PERTE D'UN ARBRE, ET J'AI POSE LE DEFAUT ICI AVANT DE LE CHASSER
  # AILLEURS : 60 pour 102 fichiers laisse perdre `test` (32) EN ENTIER sans un mot. Les deux murs
  # voisins portaient la meme forme, a 30 pour 123 et 30 pour 65.
  #
  # Le balayage etant par SHEBANG, il n'y a pas de liste d'arbres a consommer — le garde nomme donc
  # les cinq arbres stables, un par voie d'entree du bash dans ce depot : recette, temoins,
  # programmes de PATH, demons, outils d'install. Perdre l'un d'eux se voit ici.
  local t
  for t in deploy test bin services etc; do
    printf '%s\n' "${BASH_CODE[@]}" | grep -q "^$REPO/$t/" || {
      echo "MUR 0 rompu — l'arbre « $t » ne contribue AUCUN fichier bash au perimetre" >&2
      return 1
    }
  done
  [ "${#BASH_CODE[@]}" -ge 85 ]
  # Trois membres NOMMES, un par forme de nom : suffixe, sans suffixe, et le fichier meme pour
  # lequel ce mur a ete ecrit. Si `install.sh` sort du perimetre, c'est ici que ca rougit.
  printf '%s\n' "${BASH_CODE[@]}" | grep -q '/etc/install.sh$'
  printf '%s\n' "${BASH_CODE[@]}" | grep -q '/bin/fleet_v2$'
  printf '%s\n' "${BASH_CODE[@]}" | grep -q '/deploy/lib/provision-lib.sh$'
}

@test "MUR 1: aucun repli sur une variable que bash pose TOUJOURS" {
  # Bash pose ces variables au demarrage de chaque shell, avant la premiere ligne du script. Leur
  # ecrire un repli garde contre un cas qui n'existe pas — la branche de repli est du code MORT,
  # et personne ne le saura jamais parce qu'elle ne s'execute pas.
  #
  # ⚠ LE COUT N'EST PAS LE FORK QU'ON N'ECONOMISE PAS. C'est que la ligne AFFIRME que la valeur peut
  # manquer. `${1:-${EUID:-$(id -u)}}` se lit « trois sources possibles » alors qu'il y en a deux,
  # et le lecteur suivant ecrit son propre garde en croyant cette affirmation. Un repli est une
  # documentation executable de ce qui peut arriver ; contre l'impossible, il documente faux.
  #
  # ⚠ QUATRE VARIABLES INTERNES SONT DELIBEREMENT ABSENTES DE CETTE LISTE, et leur absence est la
  # mesure qui rend la liste utilisable :
  #   · `FUNCNAME`  — n'existe QUE dans un appel de fonction, vide au niveau du fichier ;
  #   · `OLDPWD`    — non pose tant qu'aucun `cd` n'a eu lieu ;
  #   · `BASH_SOURCE`— tableau, dont l'element lu peut legitimement ne pas exister ;
  #   · `HOSTNAME`  — pose par bash, mais sa valeur depend de l'hote et un repli y est un choix.
  # Un repli sur ces quatre-la est du code VIVANT. Les mettre dans la liste aurait fait de ce mur
  # un mur qui a raison en moyenne, ce qui n'est pas une propriete d'un mur.
  local internes='EUID|UID|PPID|BASHPID|RANDOM|SECONDS|LINENO|SHLVL|GROUPS|PWD|IFS|BASH_VERSION|MACHTYPE|OSTYPE|HOSTTYPE'

  # Les formes REFUSEES sont celles qui INVENTENT une valeur : `${V-x}`, `${V:-x}`, `${V=x}`,
  # `${V:=x}`. Pas `${V:?msg}` ni `${V?msg}` — celles-la REFUSENT, et un refus contre l'impossible
  # est du bruit, pas un mensonge. Pas `${V:+x}` non plus : elle ne se declenche que si la variable
  # EST posee, donc elle ne parle pas de son absence.
  local motif="\\\$\\{($internes):?[-=]"

  local f n total=0 rompu=0
  for f in "${BASH_CODE[@]}"; do
    n="$(code_of "$f" | grep -cE -- "$motif" || true)"
    [ "$n" -eq 0 ] && continue
    rompu=1
    total=$((total + n))
    echo "MUR 1 rompu — ${f#"$REPO"/} :" >&2
    code_of "$f" | grep -nE -- "$motif" >&2
  done
  [ "$rompu" -eq 0 ] || {
    echo "MUR 1 : $total repli(s) contre une variable que bash pose toujours." >&2
    echo "Le geste : retirer le repli, pas le remplacer par un autre." >&2
    return 1
  }
}

@test "MUR 2: aucun fichier dans la portee de provision-lib ne RECOPIE un defaut qu'elle pose" {
  # ⚠ LA REGLE EST DEJA ECRITE DANS LE CORPUS, dans `64-services.sh` : « PAS DE `:-` ICI, ET C'EST
  # UNE CORRECTION. » Elle etait tenue pour DEUX noms, dans UN fichier, par un temoin qui ne
  # regardait qu'une seule forme d'ecriture. Une regle tenue par de la discipline est une regle que
  # le prochain site rate — et quatre sites l'avaient deja ratee.
  #
  # ⚠ CE QUI EST INTERDIT EST LA COPIE DU DEFAUT, PAS LE `:-`. `${PROV_X:-}` avec un defaut VIDE
  # est l'idiome sain de lecture sous `set -u`, et pour un nom que la lib peut poser vide il est
  # meme le seul juste. Ce qui ne peut pas mordre, c'est `${PROV_X:-<litteral>}` quand la lib pose
  # deja ce nom a une valeur NON VIDE : la branche est morte, et elle AFFIRME qu'un module peut
  # tourner sans la lib — alors qu'il meurt sur `PROVISION_LIB non pose` deux lignes plus haut.
  #
  # ⚠ ET L'INTERDICTION S'APPUIE SUR UN AUTRE VERROU, ce qui est la raison pour laquelle elle est
  # sure : `shell.sourcers_set_strict` (contrat Elixir) exige `set -u` de TOUT sourcer de la lib.
  # Retirer le repli ne rend donc pas la lecture silencieuse — elle devient un `unbound variable`
  # bruyant. Un echec explicite vaut mieux qu'un succes ambigu, mais seulement si quelque chose
  # garantit l'echec ; ici, quelque chose le garantit.
  #
  # LES DEUX LISTES SE DERIVENT, aucune n'est tenue a la main : les poseurs se lisent dans la lib,
  # la portee se lit dans les fichiers qui la sourcent. Un nom ajoute a la lib est garde le jour
  # meme.
  local lib="$REPO/deploy/lib/provision-lib.sh"
  [ -r "$lib" ] || { echo "provision-lib.sh introuvable : $lib" >&2; return 1; }

  # Les noms poses a une valeur NON VIDE. `sed` sur la forme `: "${X:=valeur}"`.
  local poseurs
  poseurs="$(sed 's/#.*//' "$lib" | sed -nE 's/^[[:space:]]*:[[:space:]]*"\$\{(PROV_[A-Z_]+):=(.+)\}"[[:space:]]*$/\1/p' | sort -u)"
  [ -n "$poseurs" ] || { echo "aucun poseur lu dans la lib — l'instrument est casse" >&2; return 1; }
  [ "$(printf '%s\n' "$poseurs" | wc -l)" -ge 15 ] || {
    echo "seulement $(printf '%s\n' "$poseurs" | wc -l) poseurs lus — le motif ne suit plus la lib" >&2; return 1; }

  # La portee : les fichiers qui sourcent la lib, PLUS le runner qui la source lui-meme.
  local portee
  portee="$(grep -rl '\. "\${PROVISION_LIB' "$REPO/deploy" "$REPO/etc" 2>/dev/null; echo "$REPO/deploy/provision")"
  [ "$(printf '%s\n' "$portee" | wc -l)" -ge 20 ] || {
    echo "portee a $(printf '%s\n' "$portee" | wc -l) fichiers — le balayage est casse" >&2; return 1; }

  local alt; alt="$(printf '%s\n' "$poseurs" | paste -sd'|')"
  local f n src rompu=0
  while read -r f; do
    [ -r "$f" ] || continue
    # ⚠ LE POSEUR NE VAUT QU'APRES LE `source`. Une lecture au-dessus de cette ligne est VIVANTE, et
    # l'ignorer accuserait un repli legitime — la faute symetrique de celle qu'on repare.
    src="$(grep -nE '^[[:space:]]*(\.|source)[[:space:]].*(PROVISION_LIB|provision-lib)' "$f" | head -1 | cut -d: -f1)"
    [ -n "$src" ] || continue
    while IFS=: read -r n _; do
      [ -n "$n" ] || continue
      [ "$n" -gt "$src" ] || continue
      echo "MUR 2 rompu — ${f#"$REPO"/}:$n recopie un defaut que provision-lib.sh pose deja :" >&2
      sed -n "${n}p" "$f" | sed 's/^/     /' >&2
      rompu=1
    done < <(sed 's/#.*//' "$f" | grep -nE "\\\$\{($alt):-[^}]+\}")
  done <<<"$portee"

  [ "$rompu" -eq 0 ] || {
    echo "Le geste : lire la variable sans repli. set -u est garanti par le contrat" >&2
    echo "shell.sourcers_set_strict, donc l'absence devient un echec bruyant, pas une valeur inventee." >&2
    return 1
  }
}

@test "MUR 3: aucun motif de temoin n'utilise la classe qui ne veut pas dire ce qu'elle a l'air de dire" {
  # ⚠ `[^` + `\` + `n` + `]` N'EST PAS « TOUT SAUF UN SAUT DE LIGNE ». Dans une expression entre
  # crochets POSIX, la contre-oblique n'echappe rien : la classe dit « ni contre-oblique, ni la
  # lettre n ». Un motif `verbe.CLASSE.*cible` cesse donc de traverser des mots aussi ordinaires que
  # `--no-create-home`, `nologin`, `$human`, `os.path.join` ou `--owner`.
  #
  # ⚠ ET C'EST INVISIBLE PARCE QUE LE MUR RESTE VERT. Un motif qui ne traverse plus rien ne rougit
  # pas : il cesse de trouver. Mesure du 2026-08-27 sur les onze occurrences du depot, cinq formes
  # REALISTES echappaient a leur mur :
  #     ensure_member "$human" lcars-console          (le `n` de « human »)
  #     install -d -m 0700 --owner root "$TOKENS_DIR" (le `n` de « owner »)
  #     FORGE_TOKEN_FILE=$(dirname …)/home/private/t  (le `n` de « dirname »)
  #     os.chmod(os.path.join(P,"x"), 0o750)          (le `n` de « join »)
  #     install -d --owner=root -m 0750 "$PRIVATE_DIR"
  # Les onze sont passees en `.` — dans grep, qui travaille ligne a ligne, le point ne franchit
  # JAMAIS un saut de ligne : la classe n'apportait rien, et elle retirait beaucoup.
  #
  # ⚠ ET LA MESURE ELLE-MEME A MENTI TROIS FOIS AVANT D'ETRE JUSTE. Teste en ligne de commande, le
  # motif se comportait comme « tout sauf newline » — une couche shell convertissait la sequence
  # avant grep. Il a fallu ecrire le test DANS UN FICHIER, comme les murs le sont, pour voir le
  # comportement reel. Un instrument doit etre eprouve dans la forme ou il vit.
  #
  # LE MOTIF INTERDIT EST ASSEMBLE, PAS ECRIT. Ecrit en clair, ce mur figurerait dans son propre
  # perimetre et s'accuserait lui-meme ; l'assembler evite de devoir s'exclure, donc ce mur se garde
  # AUSSI lui-meme.
  local bs; bs="$(printf '\\')"
  local interdit="\\[\\^${bs}n\\]"

  mapfile -t SUITES < <(
    find "$REPO" "$REPO/../.claude" -type f \( -name '*.bats' -o -name '*.bash' \) \
      -not -path '*/_build/*' -not -path '*/deps/*' 2>/dev/null | sort -u
  )
  [ "${#SUITES[@]}" -ge 60 ] || { echo "corpus de temoins a ${#SUITES[@]} fichiers — balayage casse" >&2; return 1; }

  local f n rompu=0
  for f in "${SUITES[@]}"; do
    n="$(grep -cE -- "$interdit" "$f" || true)"
    [ "$n" -eq 0 ] && continue
    rompu=1
    echo "MUR 3 rompu — ${f#"$REPO"/} :" >&2
    grep -nE -- "$interdit" "$f" >&2
  done
  [ "$rompu" -eq 0 ] || {
    echo "Le geste : remplacer par un point. grep travaille ligne a ligne." >&2
    return 1
  }
}

@test "MUR 4: le port du deck a UNE declaration, et les copies s'accordent" {
  # ⚠ CE N'EST PAS UN RANGEMENT, C'EST UN PONT QUI MANQUAIT SUR UN RAIL. `55-deck-oidc` batit les
  # `redirect_uris` OAuth2 du deck avec `PROV_DECK_PORT` ; le daemon lit `LCARS_LANDING_PORT`. Au
  # poste, `64-services` relie les deux et `services_units.bats` le garde depuis le 2026-08-23. Sur
  # le rail BOITE, rien ne les reliait : ils s'accordaient parce que leurs deux defauts independants
  # valent tous les deux 20999. La cicatrice du rail poste decrit la panne mot pour mot —
  # « la panne tombait au RETOUR du login, la ou elle se lit comme un probleme d'identite ».
  #
  # L'AUTORITE EST `PROV_DECK_PORT`, et elle se LIT : c'est la seule declaration nommee du fait
  # (`provision-lib.sh`), celle que `--port-deck` deplace et celle dont les callbacks OIDC derivent.
  local attendu
  attendu="$(sed 's/#.*//' "$REPO/deploy/lib/provision-lib.sh" \
             | sed -nE 's/^[[:space:]]*:[[:space:]]*"\$\{PROV_DECK_PORT:=([0-9]+)\}".*$/\1/p' | head -n1)"
  [[ "$attendu" =~ ^[0-9]+$ ]] || {
    echo "MUR 4 — PROV_DECK_PORT illisible dans provision-lib.sh : l'autorite ne se lit plus" >&2
    return 1
  }

  # Chaque miroir avec SON geste. Un nombre present ailleurs dans le fichier ne doit pas suffire —
  # `MUR 4 bis` d'`adminite_walls` a coute cette lecon le meme jour.
  local rompu=0
  check() { # check <fichier> <motif etendu> <ce que c'est>
    local f="$REPO/$1"
    [ -r "$f" ] || { echo "MUR 4 rompu — $1 illisible" >&2; rompu=1; return; }
    sed 's/#.*//' "$f" | grep -qE -- "$2" || {
      echo "MUR 4 rompu — $1 ne porte pas « $attendu » pour $3 :" >&2
      sed 's/#.*//' "$f" | grep -nE 'DECK_PORT|LANDING_PORT|20[0-9]{3}' >&2
      rompu=1
    }
  }
  check services/console-landing.sh   "LCARS_LANDING_PORT:-$attendu\}"        "le port d'ecoute du lanceur"
  check services/console-deck.py      "LCARS_LANDING_PORT\", \"$attendu\"\)"  "le port d'ecoute du serveur"
  check deploy/docker/entrypoint.sh   "PROV_DECK_PORT:-$attendu\}"            "le pont du rail boite"
  check deploy/docker/docker-compose.yml         ":$attendu\}:$attendu\""     "la publication du port"
  check deploy/docker/docker-compose.install.yml ":$attendu\}:$attendu\""     "la publication du port"
  check deploy/docker/Dockerfile      "LCARS_LANDING_PORT:-$attendu\}"        "la sonde de sante"
  check deploy/docker/bench/bench-up.sh          "DECK_PORT=\"$attendu\""     "le banc"
  check deploy/docker/bench/bench-swap-image.sh  "DECK_PORT=\"$attendu\""     "le banc"

  [ "$rompu" -eq 0 ] || {
    echo "L'autorite est PROV_DECK_PORT dans provision-lib.sh — les copies la suivent." >&2
    return 1
  }
}
