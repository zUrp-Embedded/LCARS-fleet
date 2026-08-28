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

@test "MUR 5: le chemin du fichier de siege est le MEME partout, et le manifeste pose celui-la" {
  # Le fichier que GUARD B lit — les DEUX moities, le launcher shell et le BEAM — et que le
  # provisionnement pose. Sept sites le nomment, un huitieme le CREE (la ligne `anchor` du
  # manifeste). C'est un chemin que j'ai introduit le 2026-08-26 et propage sans verrou ; le
  # verrou arrive apres, ce qui est l'ordre inverse de celui qu'on recommande.
  #
  # ⚠ AUCUNE AUTORITE DESIGNEE, ET ON NE S'EN INVENTE PAS UNE. Comme pour `/home/private`, le
  # manifeste ne peut pas faire foi : sa ligne est `anchor <chemin> <mode> <proprietaire> <rail>`,
  # il n'y a AUCUN NOM a interroger — on ne peut que confirmer un chemin qu'on connait deja. Et
  # aucune des sept declarations n'a ete designee. Ce mur enonce donc la revendication plus faible
  # mais VRAIE : elles s'accordent, et le manifeste cree celui qu'elles nomment.
  #
  # ⚠ CE QUE CE MUR N'EST PAS. Une derive ici ne produit pas un silence : les deux moities de
  # GUARD B REFUSENT quand le fichier manque (`R-no-seat`, « siege non etabli »). Ce qu'il achete
  # n'est donc pas la fermeture d'un trou muet, c'est qu'un renommage devienne un geste VISIBLE de
  # huit fichiers au lieu d'une panne totale decouverte au boot suivant.
  local sites=(
    "bin/fleet_v2"
    "config/runtime.exs"
    "services/human-converger.sh"
    "deploy/modules.d/64-services.sh"
    "deploy/docker/entrypoint.sh"
    "deploy/lib/provision-lib.sh"
  )
  # Les chemins DECLARES, captures a la source : la forme shell `${LCARS_SEAT_UID_FILE:-<X>}` et la
  # forme BEAM `System.get_env("LCARS_SEAT_UID_FILE", "<X>")`.
  local f vus=() v
  for f in "${sites[@]}"; do
    [ -r "$REPO/$f" ] || { echo "MUR 5 rompu — $f illisible" >&2; return 1; }
    while read -r v; do [ -n "$v" ] && vus+=("$v"); done < <(
      sed 's/#.*//' "$REPO/$f" \
        | sed -nE -e 's/.*LCARS_SEAT_UID_FILE:-([^}]+)\}.*/\1/p' \
                  -e 's/.*LCARS_SEAT_UID_FILE", "([^"]+)".*/\1/p'
    )
  done
  [ "${#vus[@]}" -ge 6 ] || {
    echo "MUR 5 — seulement ${#vus[@]} declarations lues sur ${#sites[@]} fichiers : l'instrument ne lit plus la forme" >&2
    printf '   vu: %s\n' "${vus[@]}" >&2
    return 1
  }
  local distinctes; distinctes="$(printf '%s\n' "${vus[@]}" | sort -u)"
  [ "$(printf '%s\n' "$distinctes" | wc -l)" -eq 1 ] || {
    echo "MUR 5 rompu — ${#vus[@]} declarations, PLUSIEURS chemins :" >&2
    printf '%s\n' "$distinctes" | sed 's/^/     /' >&2
    return 1
  }
  local attendu="$distinctes"
  grep -qE "^anchor[[:space:]]+${attendu//\//\\/}[[:space:]]" "$REPO/deploy/system.manifest" || {
    echo "MUR 5 rompu — les ${#vus[@]} declarations disent « $attendu » et le manifeste ne pose pas ce fichier :" >&2
    grep -nE '^anchor' "$REPO/deploy/system.manifest" >&2
    return 1
  }
}

@test "MUR 6: le groupe de traversee des consoles a UNE declaration, nom ET gid" {
  # Le groupe qui accorde le `--x` sur `/run/lcars/console/<humain>/` — rien d'autre. Il porte
  # ZERO membre declare (`MUR 5 ter` d'`adminite_walls` le garde) : root le rend a l'exec, a un
  # processus nomme. Ce mur-ci ne garde pas ce pouvoir, il garde que tout le monde parle du MEME
  # groupe — et du meme gid, parce que les deux rails le CREENT chacun de leur cote.
  #
  # ⚠ LE PIEGE EST DANS LES FAUX PORTEURS, ET IL EST EXACTEMENT CELUI QUI A SATISFAIT `MUR 4 bis`
  # CE MATIN (`lcars-authority-ask`, un nom de binaire). Trois sites portent la chaine sans porter
  # le fait : `console.sh:58` en fait un PREFIXE DE LOG (`[lcars-console]`),
  # `/etc/tmpfiles.d/lcars-console.conf` est un NOM DE FICHIER (manifeste + `25-directories`), et
  # `observation/application.ex` la cite dans sa prose. Un mur qui compterait les occurrences serait
  # vert en ayant compte des choses qui n'ont rien a voir. Chaque miroir est donc ancre sur SON
  # GESTE : declarer, lire, creer, posseder.
  local nom gid
  nom="$(sed 's/#.*//' "$REPO/deploy/lib/provision-lib.sh" \
         | sed -nE 's/^[[:space:]]*:[[:space:]]*"\$\{PROV_CONSOLE_GROUP:=([a-z0-9_-]+)\}".*$/\1/p' | head -n1)"
  [ -n "$nom" ] || { echo "MUR 6 — PROV_CONSOLE_GROUP illisible dans provision-lib.sh" >&2; return 1; }
  # Le gid vient du manifeste, seul endroit ou le groupe est DECLARE avec son numero.
  gid="$(sed -nE "s/^group[[:space:]]+${nom}[[:space:]]+([0-9]+)[[:space:]].*/\1/p" "$REPO/deploy/system.manifest" | head -n1)"
  [[ "$gid" =~ ^[0-9]+$ ]] || {
    echo "MUR 6 rompu — le manifeste ne DECLARE pas le groupe « $nom » avec un gid :" >&2
    grep -nE '^group' "$REPO/deploy/system.manifest" >&2
    return 1
  }

  local rompu=0
  need() { # need <fichier> <motif> <geste>
    sed 's/#.*//' "$REPO/$1" 2>/dev/null | grep -qE -- "$2" || {
      echo "MUR 6 rompu — $1 ne porte pas « $nom » pour $3" >&2; rompu=1; }
  }
  need services/console.sh          "LCARS_CONSOLE_GROUP:-$nom\}"          "la lecture du lanceur de console"
  need services/console-landing.sh  "LCARS_CONSOLE_GROUP:-$nom\}"          "la lecture du lanceur de deck"
  # Les DEUX createurs, un par rail, et ils doivent s'accorder sur le gid : un groupe de meme nom
  # et de gid different sur les deux rails, c'est un `chown` qui reussit et une traversee qui non.
  need deploy/docker/Dockerfile     "groupadd -g $gid $nom([[:space:]]|\\\\|$)"  "la creation dans l'image (gid $gid)"
  need deploy/system.manifest       "^runtime[[:space:]]+/run/lcars/console/<human>[[:space:]]+2710[[:space:]]+<human>:$nom" "la possession du repertoire de socket"

  [ "$rompu" -eq 0 ] || { echo "L'autorite est PROV_CONSOLE_GROUP dans provision-lib.sh." >&2; return 1; }
}

@test "MUR 7: tout PROV_* qu'un daemon lit figure dans la table de transport" {
  # ⚠ CE MUR SE CONSTRUIT DEPUIS LES DEUX LISTES ET N'EN RECOPIE AUCUNE. La table de transport est
  # `services_env_body` de `64-services.sh` ; la population des daemons se lit dans les `ExecStart`
  # des unites que ce meme fichier ecrit. Recopier l'une ou l'autre ici en ferait une troisieme, qui
  # derive — et c'est exactement le defaut que ce chantier poursuit.
  #
  # ⚠ ET LE PERIMETRE EST « CE QUI RECOIT LE FICHIER », PAS « CE QUI EST DANS services/ ». La
  # distinction a coute une demi-mesure : `forge-gestures.sh` et `etc/provision-role-tokens.sh`
  # lisent des `PROV_*` eux aussi, mais ce sont des processus ENFANTS de modules — ils ne recoivent
  # pas `services.env` (mesure : zero `set -a`, zero mention du fichier), et rien ne leur exporte
  # ces noms (`provision-lib` n'exporte RIEN ; `deploy/provision` n'exporte que ses drapeaux CLI).
  # Les inclure ferait rougir ce mur pour des noms que la table ne peut pas leur transmettre.
  local svc="$REPO/deploy/modules.d/64-services.sh"
  [ -r "$svc" ] || { echo "MUR 7 — 64-services.sh illisible" >&2; return 1; }

  # (1) La TABLE : ce que `services_env_body` ecrit.
  local table; table="$(sed 's/#.*//' "$svc" | sed -n '/services_env_body/,/^}/p' \
                        | sed -nE 's/.*echo "(PROV_[A-Z_]+)=.*/\1/p' | sort -u)"
  [ -n "$table" ] || { echo "MUR 7 — la table de transport ne se lit plus dans services_env_body" >&2; return 1; }

  # (2) LES DAEMONS : les fichiers que les `ExecStart` des unites lancent.
  local daemons; daemons="$(sed 's/#.*//' "$svc" \
                            | sed -nE 's;.*ExecStart=.*/([a-z0-9-]+\.(sh|py)).*;\1;p' | sort -u)"
  [ "$(printf '%s\n' "$daemons" | grep -c .)" -ge 3 ] || {
    echo "MUR 7 — seulement $(printf '%s\n' "$daemons" | grep -c .) daemon(s) lus dans les ExecStart : l'instrument est casse" >&2
    return 1
  }

  # (3) Ce que ces daemons LISENT, formes shell et python.
  local d lus="" f
  for d in $daemons; do
    f="$REPO/services/$d"
    [ -r "$f" ] || { echo "MUR 7 — daemon introuvable : services/$d" >&2; return 1; }
    lus="$lus$(sed 's/#.*//' "$f" | grep -oE 'PROV_[A-Z_]+' | sort -u)
"
  done
  lus="$(printf '%s\n' "$lus" | grep . | sort -u)"

  local manquants; manquants="$(comm -23 <(printf '%s\n' "$lus") <(printf '%s\n' "$table"))"
  [ -z "$manquants" ] || {
    echo "MUR 7 rompu — des daemons lisent des PROV_* que la table ne transporte pas :" >&2
    printf '     %s\n' $manquants >&2
    echo "   Sans transport, le daemon retombe sur SON defaut : la valeur choisie au provisionnement" >&2
    echo "   ne l'atteint jamais, et rien ne le dit." >&2
    return 1
  }
}

@test "MUR 8: l'override genere nomme le service que la base DEFINIT, et sa prose ne s'execute pas" {
  # ⚠ TROUVE AU BANC DU 2026-08-28, PAS PAR RELECTURE. `runner-compose.yml` a renomme son service
  # `runner` -> `act` (b01fe3164). Six consommateurs ont suivi ; le septieme vivait DANS UN HEREDOC
  # de `forge-runner.sh`, donc dans une CHAINE — invisible a tout grep sur le nom du service.
  # Compose fusionnait alors un service `runner` absent de la base, sans image, et refusait :
  # « service "runner" has neither an image nor a build context specified ». L'enrolement du runner
  # echouait a CHAQUE install fraiche, et avec lui toute la CI.
  local src="$REPO/deploy/docker/forge-runner.sh" base="$REPO/deploy/docker/runner-compose.yml"
  [ -r "$src" ] && [ -r "$base" ] || { echo "MUR 8 — source ou base illisible" >&2; return 1; }

  # (1) Le nom se DERIVE de la base, il ne se recopie pas : le script doit le lire, pas l'ecrire.
  grep -qE 'SERVICE="\$\(sed' "$src" || {
    echo "MUR 8 rompu — forge-runner.sh ne DERIVE plus le nom du service de runner-compose.yml" >&2
    return 1
  }
  # (2) Et aucun nom de service en dur ne subsiste dans le heredoc de l'override.
  # ⚠ LE MOTIF DE PLAGE ETAIT INERTE, ET SEULE LA MUTATION L'A MONTRE. Il disait
  # `/override.yml <</` alors que la ligne porte `…override.yml" <<EOF` — un guillemet entre les
  # deux. La plage ne capturait RIEN, donc ce controle passait au vert sans rien lire, y compris
  # quand on recodait le nom du service en dur. Un mur vert qui n'a rien lu est le defaut que ce
  # fichier existe pour interdire, commis en l'ecrivant.
  local codees; codees="$(sed -n '/override\.yml.*<</,/^EOF$/p' "$src" | sed -nE 's/^  ([a-z][a-z0-9_-]+):[[:space:]]*$/\1/p' | grep -v '^default$' || true)"
  [ -z "$codees" ] || {
    echo "MUR 8 rompu — l'override code un nom de service en dur : $codees" >&2
    return 1
  }

  # (3) LES HEREDOCS QUI N'ONT RIEN A EXPANSER SONT QUOTES. Un `<<EOF` nu evalue sa prose : les
  # accents graves y sont des substitutions de commande. Mesure du banc : `bridge`, `host`, `none`,
  # `getent`, `wget` et `git ls-remote` EXECUTES, et le fichier produit troue de leurs sorties vides.
  # Meme defaut que `bats.descriptions_inert`, a un endroit qu'aucun mur ne regardait.
  local f n=0
  for f in "$REPO"/deploy/docker/*.sh "$REPO"/services/*.sh; do
    [ -r "$f" ] || continue
    # Pour chaque heredoc NON quote, le corps doit etre exempt d'accent grave.
    awk '
      /<<[[:space:]]*EOF[[:space:]]*$/ { inhd=1; start=NR; body=""; next }
      inhd && /^EOF$/ { if (body ~ /`/) printf "%s:%d\n", FILENAME, start; inhd=0; next }
      inhd { body = body $0 "\n" }
    ' "$f"
  done > "$BATS_TEST_TMPDIR/hd" 2>/dev/null || true
  n="$(grep -c . "$BATS_TEST_TMPDIR/hd" || true)"
  [ "$n" -eq 0 ] || {
    echo "MUR 8 rompu — $n heredoc(s) NON quote(s) dont la prose porte un accent grave : elle sera EXECUTEE" >&2
    cat "$BATS_TEST_TMPDIR/hd" >&2
    echo "   Le geste : <<'EOF' si rien n'est a expanser, sinon echapper les accents graves." >&2
    return 1
  }
}

@test "MUR 9: le chemin du magasin s'accorde partout avec celui que le compose declare" {
  # ⚠ LA REGLE EXISTE DEJA, ECRITE ET GARDEE — SUR UN FICHIER SUR CINQ. `store_volumes.bats` dit :
  # « store.sh possede les NOMS, le compose possede le CHEMIN. Un `/var/lib/lcars` en dur dans un
  # script serait une seconde verite, et c'est celle qu'on ne relit pas qui derive. » Son assertion
  # ne porte que sur `store.sh`. Mesure du 2026-08-28 : TROIS autres scripts portent le chemin
  # (`bin/lcars-toolchain-converge`, `services/forge-gestures.sh`, `deploy/lib/provision-lib.sh`),
  # plus le manifeste. Une regle gardee sur un cinquieme de son sujet est le verrou partiel du §22.
  #
  # ⚠ ET J'AI FAILLI L'ENFREINDRE. Le balayage derive m'a fait conclure « la racine n'a aucun
  # foyer » et j'ai declare un `LCARS_STORE_ROOT_DEFAULT` dans `store.sh` — exactement la seconde
  # verite que la regle interdit. C'est le temoin existant qui m'a arrete, en rougissant. Le
  # balayage voit les COPIES ; il ne voit pas qui a deja ete DESIGNE.
  #
  # CE MUR N'INVENTE DONC AUCUNE AUTORITE : il consomme celle que la regle designe (le compose) et
  # l'etend aux porteurs que le temoin d'origine ne regardait pas. Rien n'est retire : ce qui se
  # verifie est l'ACCORD.
  local compose="$REPO/deploy/docker/docker-compose.yml"
  local lib="$REPO/deploy/lib/store.sh"
  [ -r "$compose" ] && [ -r "$lib" ] || { echo "MUR 9 — compose ou store.sh illisible" >&2; return 1; }

  local racine
  racine="$(sed -nE 's/^[[:space:]]*LCARS_STORE_ROOT:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$compose" | head -n1)"
  [ -n "$racine" ] || { echo "MUR 9 — le compose ne declare plus LCARS_STORE_ROOT : l'autorite est illisible" >&2; return 1; }

  local natures
  natures="$(sed -n '/^LCARS_STORE_TREES=(/,/^)/p' "$lib" | sed -nE 's/^  ([a-z]+)\b.*/\1/p')"
  [ "$(printf '%s\n' "$natures" | grep -c .)" -ge 3 ] || {
    echo "MUR 9 — moins de 3 natures lues dans store.sh : l'instrument ne lit plus la liste" >&2; return 1; }

  # ⚠ LES SOUS-ARBRES HORS NATURE SE DECLARENT PAR LEUR NOM, chacun une decision visible.
  #   tofu — l'arbre de travail d'OpenTofu, pose par le manifeste en 0700 lcars-authority. Ce n'est
  #          pas une nature de magasin (il ne se purge pas par duree de vie) mais il partage la
  #          persistance de la racine.
  local hors_nature="tofu"

  : > "$BATS_TEST_TMPDIR/vus"
  local f
  while read -r f; do
    [ -r "$f" ] || continue
    # ⚠ CODE SEUL, ET LES DOCSTRINGS ELIXIR COMPTENT. Sans les depouiller, ce mur accusait
    # `admiral/toolchain_reconciler.ex`, dont le `@moduledoc` cite `/var/lib/lcars/toolchain` (au
    # SINGULIER) pour raconter une faute de la v2 — 0 occurrence en code, 1 en prose. Un mur qui lit
    # la prose interdit de l'ecrire, et `MUR 4 bis` a coute cette lecon le meme jour.
    python3 - "$f" "$racine" <<'PYX' >> "$BATS_TEST_TMPDIR/vus" 2>/dev/null || true
import io, re, sys
s = io.open(sys.argv[1], encoding='utf-8', errors='replace').read()
s = re.sub(r'@(?:module)?doc\s+"""(.*?)"""', '', s, flags=re.S)
s = '\n'.join(re.sub(r'#.*', '', l) for l in s.split('\n'))
racine = sys.argv[2]
for m in re.finditer(r'/var/lib/[A-Za-z0-9_.-]*lcars[A-Za-z0-9_.-]*(?:/([a-z.]+))?', s):
    tete = '/'.join(m.group(0).split('/')[:4])
    print('ORPHELIN:' + tete if tete != racine else (m.group(1) or ''))
PYX
  done < <(grep -rl '/var/lib/.*lcars' "$REPO" --exclude-dir=_build --exclude-dir=.git --exclude-dir=tmp 2>/dev/null | grep -v '/deps/[a-z_]*/')

  [ -s "$BATS_TEST_TMPDIR/vus" ] || { echo "MUR 9 — aucun porteur lu : le balayage est casse" >&2; return 1; }
  local rompu=0 sub
  while read -r sub; do
    [ -n "$sub" ] || continue
    case "$sub" in
      ORPHELIN:*)
        echo "MUR 9 rompu — « ${sub#ORPHELIN:} » ne s'accorde pas avec la racine que le compose declare (« $racine »)" >&2
        rompu=1; continue ;;
    esac
    printf '%s\n' "$natures" | grep -qx "$sub" && continue
    printf '%s\n' "$hors_nature" | grep -qx "$sub" && continue
    echo "MUR 9 rompu — « $racine/$sub » n'est ni une NATURE de LCARS_STORE_TREES ni un sous-arbre declare" >&2
    rompu=1
  done < <(sort -u "$BATS_TEST_TMPDIR/vus")
  [ "$rompu" -eq 0 ] || return 1
}

@test "MUR 10: le prefixe d'install s'accorde — y compris dans la garde qui le protege" {
  # ⚠ TROIS PORTEURS, ET LE TROISIEME EST UNE GARDE. `etc/install.sh` et `provision-lib.sh`
  # declarent le prefixe chacun de leur cote ; `.claude/hooks/runtime-guard.sh` REFUSE les ecritures
  # dans l'arbre d'install, en le nommant. Si le prefixe bougeait sans que le hook suive, la garde
  # cesserait de proteger l'install reelle — sans un mot, et c'est le pire mode : elle continuerait
  # de dire non sur un chemin que plus personne n'utilise.
  #
  # ⚠ AUCUNE AUTORITE N'EST DESIGNEE, et on ne s'en invente pas. `60-deploy` passe `PROV_PREFIX` a
  # `install.sh`, donc `provision-lib` est en amont — mais `install.sh` joue aussi SEUL, avec son
  # propre repli. Ce qui se verifie est donc l'ACCORD, comme pour `/home/private`. Une designation
  # pourra s'ajouter ; l'inventer ici serait une decision que personne n'a prise.
  local inst="$REPO/etc/install.sh" lib="$REPO/deploy/lib/provision-lib.sh"
  local guard="$REPO/../.claude/hooks/runtime-guard.sh"
  [ -r "$inst" ] && [ -r "$lib" ] || { echo "MUR 10 — install.sh ou provision-lib.sh illisible" >&2; return 1; }

  local a b
  a="$(sed 's/#.*//' "$inst" | sed -nE 's/.*LCARS_INSTALL_PREFIX:-([^}]+)\}.*/\1/p' | head -n1)"
  b="$(sed 's/#.*//' "$lib"  | sed -nE 's/^: "\$\{PROV_PREFIX:=([^}]+)\}".*/\1/p' | head -n1)"
  [ -n "$a" ] || { echo "MUR 10 — le repli de LCARS_INSTALL_PREFIX ne se lit plus dans install.sh" >&2; return 1; }
  [ -n "$b" ] || { echo "MUR 10 — PROV_PREFIX ne se lit plus dans provision-lib.sh" >&2; return 1; }
  [ "$a" = "$b" ] || {
    echo "MUR 10 rompu — deux prefixes declares : install.sh dit « $a », provision-lib.sh dit « $b »" >&2
    return 1
  }

  # La garde doit NOMMER ce prefixe. Elle protege aussi l'arbre v1 (`/local/LCARS`), ce qui est
  # deliberé et hors sujet ici : on ne verifie que la presence du prefixe COURANT.
  if [ -r "$guard" ]; then
    sed 's/#.*//' "$guard" | grep -qF -- "$a" || {
      echo "MUR 10 rompu — .claude/hooks/runtime-guard.sh ne protege pas « $a » : la garde vise un" >&2
      echo "   arbre que l'install n'utilise plus, et laisse le vrai ouvert" >&2
      return 1
    }
  fi

  # Et aucun litteral du corpus ne nomme un AUTRE prefixe de la meme forme.
  local orphelins
  #
  # ⚠ LA TRONCATURE GARDE LE POINT. Sans lui `/local/LCARS-v1.5` sortait en `/local/LCARS-v1`, et
  # l'exemption ecrite plus bas ne le reconnaissait pas : le mur accusait un arbre qu'il declarait
  # connaitre. Un motif qui mutile le nom qu'il compare ne compare rien.
  #
  # LES ARBRES NON-INSTALL SE DECLARENT PAR LEUR NOM, chacun avec sa raison :
  #   /local/LCARS      — l'arbre v1, que la garde protege AUSSI et deliberement
  #   /local/LCARS-v1.5 — cite par une donnee de CATALOGUE (`systemPrompt:` d'un cap-profile) ;
  #                       un catalogue est substituable, son contenu n'est pas un fait de la fleet
  #   /local/LCARS-fleet— un nom d'avant, qui ne vit plus que dans le CHANGELOG et un plan
  #
  # ⚠ ET LES `tests/` SONT HORS BALAYAGE, PARCE QUE CE MUR S'EST ACCUSE LUI-MEME. La cicatrice
  # ci-dessus cite le nom tronque pour expliquer le defaut ; le balayage l'a lue et l'a comptee
  # comme un prefixe etranger. C'est la lecon nº2 du chantier, mot pour mot : « un temoin qui lit
  # la prose accuse la prose ». `adminite_walls` la porte deja — « un mur qui attraperait
  # l'explication d'un defaut interdirait de l'expliquer ».
  orphelins="$(grep -rhoE '/local/LCARS[A-Za-z0-9_.-]*' "$REPO" "$REPO/../.claude" \
                 --exclude-dir=_build --exclude-dir=.git --exclude-dir=tmp --exclude-dir=.expert \
                 --exclude-dir=tests 2>/dev/null \
               | sed -E 's|(/local/LCARS[A-Za-z0-9_.-]*).*|\1|' | sed -E 's|\.$||' | sort -u \
               | grep -vxF -- "$a" \
               | grep -vxF -- '/local/LCARS' \
               | grep -vxF -- '/local/LCARS-v1.5' \
               | grep -vxF -- '/local/LCARS-fleet' || true)"
  [ -z "$orphelins" ] || {
    echo "MUR 10 rompu — prefixe(s) etranger(s) sous /local, ni « $a » ni un arbre v1 declare :" >&2
    printf '     %s\n' $orphelins >&2
    return 1
  }
}
