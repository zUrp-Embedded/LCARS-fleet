#!/usr/bin/env bats
# SOURCE: deploy/tests/authority_walls.bats
# AUTHOR: bob
# STARDATE: 2026-08-25
# STATUS: actif — les invariants du service d'autorite, tenus par une mesure et non par la discipline
#
# ⚠ POURQUOI UN SECOND FICHIER DE MURS. `adminite_walls.bats` garde les invariants du chantier
# PRECEDENT : le jeton master hors de portee d'un humain, et aucune adminite lue dans `/etc/group`.
# Ceux-ci gardent le chantier d'APRES, qui descend d'un cran : les jetons de ROLE et le repertoire
# qui les porte. Les deux jeux se ressemblent et ne disent pas la meme chose ; les fondre ferait un
# fichier dont personne ne saurait quelle regle il defend.
#
# LES INVARIANTS :
#   1. aucun ecrivain ne pose un mode de GROUPE sur `/opt/lcars/var/tokens` ni sur ce qu'il contient ;
#   2. le repertoire compte autant que les fichiers — un ecrivain qui le rouvre annule les autres ;
#   3. aucun chemin de `/opt/lcars/var/tokens` n'est passe a un process qui ne peut pas l'ouvrir.
#
# ⚠ ON MESURE LE CODE, PAS LA PROSE. Les cicatrices de ce depot NOMMENT ce qu'elles ont retire —
# c'est leur metier, et un mur qui attraperait l'explication d'un defaut interdirait de l'expliquer.
# Chaque balayage retire donc les commentaires avant de compter.

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

setup() {
  # ⚠ LE SIEGE SE LIT DANS UN FICHIER AVANT LA VARIABLE (`prov_seat_uid`), et ce fichier existe sur toute
  # machine provisionnee : sans decor, un temoin qui attend que celui qui joue passe GUARD B rougit des
  # le second run du gate — le siege, c'est lui (banc .63, 2026-08-30). Le decor nomme un fichier absent.
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/etc/lcars/seat.uid"
  # ⚠ LE CHEMIN EST RESOLU. `$BATS_TEST_DIRNAME/../..` garderait `deploy/tests/` dans la chaine, et
  # l'exclusion `-not -path '*/tests/*'` viderait alors TOUT le perimetre — les murs passeraient au
  # vert sur une liste vide. Le voisin a paye exactement ce defaut ; on ne le rejoue pas.
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # la RACINE du depot — `deploy/` et `runtime/` y sont FRERES
  # ⚠ LA LISTE DES ARBRES EST UNE VARIABLE, pour que le garde du perimetre la CONSOMME au lieu de
  # la recopier. Deux listes a maintenir, c'est une liste qui derive et un garde qui ne garde plus.
  # ⚠ `runtime/etc` N'EST PLUS UN ARBRE DE CODE (Q3, 2026-09-04) : ses trois outils d'install vivent
  # dans `deploy/lib`, il ne porte plus que des donnees (manifeste de release, gabarit d'env). Le
  # garder ici ferait rougir MUR 0 sur un arbre qui n'a rien a contribuer — et rien a cacher.
  ARBRES=("$REPO/deploy" "$REPO/runtime/services" "$REPO/runtime/bin")
  mapfile -t CODE < <(
    find "${ARBRES[@]}" -type f \
      \( -name '*.sh' -o -name '*.py' -o -name 'lcars' -o -name 'container' \
         -o -name 'provision' -o -name 'Dockerfile' \) \
      -not -path '*/tests/*' 2>/dev/null | sort
  )
  MANIFEST="$REPO/deploy/system.manifest"
  # ⚠ RESOLU DEPUIS LA LIB, JAMAIS GRAVE. Ce fichier gravait `/opt/lcars/var/tokens` en trois endroits ; le
  # jour ou la racine est descendue sous `/opt/lcars`, DEUX murs sont devenus rouges et le
  # troisieme — celui qui cherche une ABSENCE — serait passe au vert sur un motif qui ne peut plus
  # rien matcher. C'est l'asymetrie a retenir : un mur d'absence ne signale pas qu'on lui a retire
  # sa cible, il felicite.
  # ⚠ `env -i` : on resout le DEFAUT, pas la surcharge de l'appelant. Un `setup()` qui exporte
  # cette variable — plusieurs le font — la rendrait telle quelle, et le mur mesurerait le
  # temoin au lieu de la SSoT. Le motif complet est dans `deploy_manifest.bats`.
  TOKENS_DIR="$(env -i PATH="$PATH" bash -c ". '$REPO/deploy/lib/provision-lib.sh' >/dev/null 2>&1; printf '%s' \"\$PROV_TOKENS_DIR\"")"
  [[ "$TOKENS_DIR" == /* ]] || { echo "la lib ne rend pas de racine de jetons absolue : « $TOKENS_DIR »" >&2; return 1; }
}

code_of() { sed 's/#.*//' "$1"; }

# ⚠ AUCUNE ASSERTION NEGATIVE NUE DANS CE FICHIER. Bash EXEMPTE de `set -e` toute commande dont le
# statut est inverse par `!` : une `! grep` qui n'est pas la DERNIERE instruction d'un test est
# INERTE — elle s'execute, elle echoue, et rien ne le remarque. Un mur inerte est pire qu'un mur
# absent : il certifie.
absent() { # absent <motif etendu> <fichier>
  local n; n="$(code_of "$2" | grep -cE -- "$1" || true)"
  [ "$n" -eq 0 ] || {
    echo "MUR rompu — « $1 » present $n fois dans le CODE de $2 :" >&2
    code_of "$2" | grep -nE -- "$1" >&2
    return 1
  }
}

@test "MUR 0: le perimetre n'est pas VIDE — un balayage casse compte zero, comme un sans-faute" {
  # Sans ce garde, un `find` qui ne trouve plus rien (arbre deplace, extension renommee) rendrait
  # tous les murs verts en n'ayant RIEN lu. Une population vide et zero violation se ressemblent
  # exactement dans la sortie ; seul ce test les separe.
  # ⚠ UN PLANCHER NE VOIT PAS LA PERTE D'UN ARBRE. Celui-ci etait a 30 pour 65 fichiers (mesure du
  # 2026-08-27 : deploy 41, services 12, bin 9, etc 3) — perdre `services`, `bin` ET `etc` EN ENTIER
  # laisse 41 fichiers, donc vert. Le plancher n'attrape que le balayage totalement casse.
  #
  # Chaque arbre nomme doit contribuer, et la regle se DERIVE de `ARBRES`.
  local a
  for a in "${ARBRES[@]}"; do
    printf '%s\n' "${CODE[@]}" | grep -q "^$a/" || {
      echo "MUR 0 rompu — l'arbre « ${a#"$REPO"/} » ne contribue AUCUN fichier au perimetre" >&2
      return 1
    }
  done
  [ "${#CODE[@]}" -gt 55 ] || { echo "perimetre a ${#CODE[@]} fichiers — le balayage est casse" >&2; return 1; }
  printf '%s\n' "${CODE[@]}" | grep -q 'services/forge-gestures.sh'
  printf '%s\n' "${CODE[@]}" | grep -q 'runtime/services/provision-role-tokens.sh'
  printf '%s\n' "${CODE[@]}" | grep -q 'modules.d/25-directories.sh'
}

# ─── MUR 1 — LE GROUPE TRAVERSE LE REPERTOIRE DES SECRETS, IL NE LE LIT JAMAIS ──────────────────
#
# ⚠ CE MUR A ETE REECRIT LE 2026-08-25, ET SA PREMIERE VERSION AVAIT LE DEFAUT QU'IL EXISTE POUR
# ATTRAPER. Il refusait tout mode dont le chiffre de GROUPE est non nul — `0[0-7][1-7][0-7]`. Joue
# sur les trois modes possibles : `0700` passe, `0750` refuse, et `0710` REFUSE AUSSI, parce que le
# `1` matche `[1-7]`.
#
# Or `0710` est l'etat CORRECT, et le mur l'interdisait : j'avais grave le MECANISME (« aucun bit de
# groupe ») a la place de l'EXIGENCE (« aucun uid humain ne LIT un secret »). Le bit `x` donne la
# traversee d'un chemin connu ; le bit `r` donne l'enumeration. Ce sont deux droits differents, et
# seul le second est en cause.
#
# ⚠ POURQUOI `x` EST ACCORDE, ET POURQUOI `r` NE DOIT JAMAIS L'ETRE. Ce repertoire ne contient pas
# que des secrets : `forge.url` et `forge.public.url` y vivent en `0644` — des ADRESSES — et trois
# modules `NEEDS: human` les lisent sous l'uid de l'humain. En `0700` ils prenaient « Permission
# denied » et le conteneur finissait sans `FORGE_BASE_URL` (mesure du 2026-08-25, install reelle).
# Le `r`, lui, donnerait l'enumeration des comptes de forge du conteneur — et c'est une information
# en soi, meme sans le contenu des fichiers.
#
# ⚠ CE QUE LE `0710` DEPLACE, ET QUI SE TIENT ICI DESORMAIS : en `0700`, un secret qui perdait son
# `0600` restait ferme PAR LE REPERTOIRE. En `0710`, il devient lisible par tout `fleet`. La garantie
# n'a pas disparu, elle a change de porteur : c'est le MUR 2 et le temoin fonctionnel du minteur qui
# la tiennent maintenant. Un mur qui accorde le `x` doit dire pourquoi le `r` reste interdit, sinon
# le prochain elargira d'un cran en croyant suivre.

# ⚠ ET LA PREMIERE REECRITURE ETAIT ENCORE TROP LARGE — DANS L'AUTRE SENS, ET C'ETAIT PIRE.
#
# Elle refusait le bit `r` (`0[0-7][4-7][0-7]`) et laissait donc passer `0720` et `0730` : le bit
# `w` DU GROUPE sur le repertoire des secrets. Or `w` sur un REPERTOIRE ne depend d'aucun mode de
# fichier — n'importe quel membre de `fleet` fait `unlink` de `forge-master.token` et repose le
# sien. Le service d'autorite servirait alors un jeton de forge CHOISI PAR L'APPELANT : la classe
# `groupe -> root` que ce chantier ferme, rouverte par l'autre porte.
#
# J'avais elargi en lisant l'arbitrage comme « pas le bit r » alors qu'il dit « le groupe TRAVERSE,
# il ne LISTE pas » — donc le chiffre de groupe vaut 0 ou 1, jamais 2 a 7. Corriger un mur trop
# etroit en le rendant trop large est la faute symetrique de celle qu'on repare.
#
# ⚠ ET `other` EST FERME AUSSI, CE QUI EST NEUF. L'ancien mur avait `[0-7]` en derniere position :
# `0704` et `0707` passaient. Ca n'a jamais ete une regression, mais maintenant que les modes de
# FICHIERS sont porteurs (0710), un `other` ouvert sur ce repertoire ne doit plus passer non plus.
# ⚠ LE MOTIF ETAIT ECRIT EN SHELL SUR UN PERIMETRE QUI PORTE DU PYTHON, et c'est mesurable :
# `services/lcars_socket.py` est DANS `CODE` et il pose des modes de repertoire — `os.makedirs(parent,
# mode=0o750)`, `os.chmod(parent, 0o750)`. Deux raisons independantes le rendaient invisible :
# `makedirs` n'etait dans aucune alternative, et l'octal python s'ecrit `0o750`, que
# `0[0-7][2-7][0-7]` ne peut pas lire — le `o` n'est pas un chiffre.
#
# Ce n'est donc pas une forme hypothetique : le perimetre contient deja du code qui pose des modes
# dans cette notation. Il ne vise simplement pas encore le repertoire des secrets. Meme classe que
# la clause de branche du contrat Elixir le meme jour : une garde ecrite dans UNE langue sur un
# perimetre qui en parle plusieurs ne garde qu'une partie de son sujet, et elle a l'air complete.
@test "MUR 1: le groupe TRAVERSE le repertoire des secrets — il ne le lit ni ne l'ecrit, et « other » est ferme" {
  # ⚠ ET LE MOTIF ETAIT ECRIT DEUX FOIS, une pour juger et une pour rapporter. Deux copies d'une
  # regle sont deux regles : elargir l'une et pas l'autre donne un mur qui rougit sans savoir dire
  # sur quelle ligne. Une seule source, consommee deux fois.
  #
  # Chiffre de groupe ∈ {0,1} : `x` seul, jamais `r` ni `w`. Et `other` a zero.
  local mode='0o?[0-7][2-7][0-7]|0o?[0-7][0-7][1-7]'
  local lieu='PRIVATE_DIR|TOKENS_DIR|/home/private'
  local verbe='install -d|ensure_dir|chmod|makedirs|mkdir'
  # ⚠ LES DEUX ORDRES, ET C'EST LA MOITIE QUE MA PREMIERE CORRECTION AVAIT RATEE. Elargir le
  # vocabulaire ne suffit pas : le motif encodait aussi l'ORDRE DES ARGUMENTS du shell — mode PUIS
  # chemin (`install -d -m 0710 "$PRIVATE_DIR"`). Python ecrit l'inverse (`os.makedirs("/home/private",
  # mode=0o750)`), donc le mutant python passait encore au vert APRES l'ajout de `makedirs` et de
  # `0o`. Une garde multi-langue doit ignorer la SYNTAXE, pas seulement le lexique.
  local motif="($verbe).*(($mode).*($lieu)|($lieu).*($mode))"
  local f hits=0
  for f in "${CODE[@]}"; do
    if code_of "$f" | grep -qE -- "$motif"; then
      echo "MUR rompu — le groupe LIT le repertoire des secrets dans $f :" >&2
      code_of "$f" | grep -nE -- "$motif" >&2
      hits=$((hits + 1))
    fi
  done
  [ "$hits" -eq 0 ]
}

@test "MUR 1 bis: les QUATRE ecrivains du repertoire sont la, et ils posent le MEME mode" {
  # GARDE D'INSTRUMENT, ET IL A ETE PLUS QUE CA. Le mur 1 cherche une ABSENCE : il passe au vert si
  # les ecrivains ont disparu ou si le motif ne les matche plus. Ce test compte la POPULATION.
  #
  # ⚠ ET IL LA COMPTAIT DEJA QUAND J'AI ECRIT LE CORRECTIF, SANS QUE JE LA LISE COMME TELLE. Il
  # enumerait les ecrivains du repertoire — c'etait la liste exacte des sites a changer, et je l'ai
  # lue comme un test qui passe. Ce qui manquait n'etait pas la mesure : elle etait ecrite ici.
  #
  # ⚠ ET ILS SONT QUATRE, PAS TROIS. `runtime/services/provision-role-tokens.sh` en fait partie et n'etait nomme
  # nulle part dans la prose du chantier. Il suffit qu'UN pose un autre mode pour que le premier
  # passage suivant defasse les trois autres, EN SILENCE — le gate ne le voit pas, il n'execute
  # aucun de ces gestes contre une vraie table.
  local f
  for f in "$REPO/runtime/services/provision-role-tokens.sh" "$REPO/runtime/services/forge-gestures.sh"; do
    grep -qE 'install -d -m 0710' "$f" \
      || { echo "$f ne pose plus le repertoire des secrets en 0710" >&2; return 1; }
    # Et il ne reste AUCUN 0700 sur cet objet : deux modes dans un meme fichier, c'est celui qu'on
    # n'a pas relu qui gagne.
    local n
    n="$(sed 's/#.*//' "$f" | grep -cE 'install -d -m 0700.*(PRIVATE_DIR|TOKENS_DIR)' || true)"
    [ "$n" -eq 0 ] || { echo "$f pose ENCORE 0700 sur le repertoire des secrets" >&2; return 1; }
  done
  grep -qE 'PROV_TOKENS_DIR 0710' "$REPO/deploy/modules.d/25-directories.sh"
  grep -qE "^dir[[:space:]]+${TOKENS_DIR}[[:space:]]+0710" "$MANIFEST"
}

# ─── MUR 2 — LES SECRETS NE SONT LISIBLES PAR AUCUN GROUPE ──────────────────────────────────────

# ⚠ CE MUR A ETE REECRIT PARCE QUE LE PREMIER NE POUVAIT PAS VOIR, ET IL PASSAIT VERT.
#
# Il cherchait `(chmod|install)…0[0-7][1-7][0-7]…(gitea_token|forge-master|…)` — le mode ET le nom du
# fichier sur UNE ligne. Or ces ecritures sont ATOMIQUES : `chmod 0600 "$tmp"` puis `mv -f "$tmp"
# "$file"`. Le mode et le nom ne sont JAMAIS sur la meme ligne, chez aucun des ecrivains. Le motif
# etait donc structurellement incapable de matcher.
#
# MESURE DU 2026-08-25 : remettre `chmod 0640` dans le minteur n'a fait rougir AUCUN mur. Trouve par
# mutation, pas par relecture — et c'est exactement ce qu'une mutation est la pour trouver. Un mur
# qui certifie sans regarder est pire qu'un mur absent.
#
# ⚖ CE QU'UN MUR TEXTUEL PEUT TENIR ICI, ET CE QU'IL NE PEUT PAS. Le MODE d'un fichier ecrit par
# tmp+mv n'est pas lisible textuellement sans un faux positif par `chmod` legitime voisin
# (`forge-gestures` en pose un `0755` sur son clone jetable, dans le meme fichier). Le mode est donc
# garde FONCTIONNELLEMENT, par `test/provision_role_tokens` qui `stat` le fichier reellement pose.
# Ce mur-ci garde ce qui EST visible : le geste de DONNER un secret a un groupe.
# ⚠ ET IL EST SCOPE AUX ECRIVAINS DE SECRETS, PAS AU DEPOT ENTIER. Premiere ecriture : un `chgrp`
# interdit PARTOUT dans le perimetre. C'etait rouge des le premier passage, sur `66-deck-oidc.sh` —
# qui `chgrp` legitimement son fichier OIDC pour que le deck (`lcars-system`) puisse le lire. Un
# mur qui accuse un geste sain n'est pas severe, il est FAUX, et un mur faux se fait desarmer.
#
# La regle n'a jamais ete « aucun chgrp » : c'est « aucun SECRET DE FORGE donne a un groupe ». Le
# sujet du mur est donc une liste d'ecrivains, et `MUR 2 ter` garde cette liste non vide.
secret_writers() {
  printf '%s\n' \
    "$REPO/runtime/services/provision-role-tokens.sh" \
    "$REPO/runtime/services/forge-gestures.sh" \
    "$REPO/deploy/modules.d/48-forge-host.sh" \
    "$REPO/runtime/services/forge.d/tokens.sh" \
    "$REPO/deploy/modules.d/25-directories.sh"
}

@test "MUR 2: aucun ecrivain de secret ne donne son objet a un groupe" {
  local f
  while read -r f; do
    absent 'chgrp' "$f"
    absent '(chown|install).*(:|-g )(fleet|\$PROV_FLEET_GROUP|\$\{PROV_FLEET_GROUP\})' "$f"
  done < <(secret_writers)
}

@test "MUR 2 ter: les cinq ecrivains de secret existent — sinon le mur ci-dessus lit le vide" {
  # GARDE D'INSTRUMENT. Le mur 2 cherche une ABSENCE sur une liste NOMMEE : un fichier deplace ou
  # renomme le ferait lire un chemin inexistant, `code_of` rendrait vide, et l'absence serait
  # trivialement vraie. Zero violation et zero fichier se ressemblent exactement dans la sortie.
  local f n=0
  while read -r f; do
    [ -f "$f" ] || { echo "ecrivain de secret introuvable : $f" >&2; return 1; }
    n=$((n + 1))
  done < <(secret_writers)
  [ "$n" -eq 5 ]
}

@test "MUR 2 bis: le manifeste declare la racine des jetons au detenteur, traversable et non listable" {
  # ⚠ LE MANIFESTE N'EST PAS LA SOURCE DES MODES — QUATRE ecrivains le sont, d'ou le mur 1. Il est
  # la DECLARATION, et un `uninstall` s'en sert. Une table qui dirait encore `0750 root:fleet`
  # decrirait une machine qui n'existe plus.
  #
  # ⚠ CE MUR DISAIT `[[ "$row" != *fleet* ]]`, ET IL INTERDISAIT LE CORRECTIF. « le groupe fleet
  # traverse encore » etait ecrit comme une faute ; c'est l'etat voulu. J'y avais grave le MECANISME
  # par lequel j'obtenais l'exigence, pas l'exigence — et le mecanisme etait faux. Le groupe doit
  # traverser (les modules `NEEDS: human` lisent `forge.url` sous l'uid de l'humain) et ne doit pas
  # lister. Ce qui se verifie ici est donc : le detenteur est le service, le mode accorde `x` au
  # groupe et pas `r`.
  local row
  row="$(grep -E "^dir[[:space:]]+${TOKENS_DIR}[[:space:]]" "$MANIFEST")"
  [ -n "$row" ] || { echo "« $TOKENS_DIR » n'est plus declare dans le manifeste" >&2; return 1; }
  [[ "$row" == *0710* ]] || { echo "mode attendu 0710 (le groupe traverse, il ne liste pas) : $row" >&2; return 1; }
  [[ "$row" == *lcars-authority:fleet* ]] \
    || { echo "attendu « lcars-authority:fleet » — le service detient, le groupe traverse : $row" >&2; return 1; }
}

# ─── MUR 3 — AUCUN CHEMIN DE SECRET N'EST DONNE A QUI NE PEUT PAS L'OUVRIR ───────────────────────
#
# ⚠ C'EST LA CASSE QUE LA FERMETURE A FAILLI PRODUIRE, ET ELLE NE SE VOIT PAS EN LISANT UN SEUL
# FICHIER. `forge-gestures.sh cmd_install` passait `FORGE_TOKEN_FILE=<chemin du jeton systeme>` a une
# porte qui tombe en `nobody:fleet`. Ca marchait tant que le fichier etait `0640 root:fleet` ; en
# `0600 lcars-authority`, la porte meurt sur un `:eacces` presente comme « pas de source
# installable » — le mauvais diagnostic pour le mauvais probleme, sur le geste central du chantier
# voisin, et pour la DEUXIEME fois sur ce meme fichier.

@test "MUR 3: aucun FORGE_TOKEN_FILE construit depuis le repertoire des secrets ne part vers une porte" {
  local f
  for f in "${CODE[@]}"; do
    absent 'FORGE_TOKEN_FILE=.*(PRIVATE_DIR|TOKENS_DIR|/opt/lcars/var/tokens)' "$f"
  done
}

@test "MUR 3 bis: l'entrypoint relaie bien la VALEUR — sinon la porte part sans credential" {
  # GARDE D'INSTRUMENT du mur 3 : il interdit de passer un CHEMIN. Ce qui rend le geste possible est
  # que la valeur, elle, traverse. `env` ne propage que ce qu'on lui NOMME : la variable oubliee ici
  # rendrait une porte sans credential, et son echec accuserait la source du catalogue.
  # Lot 6 (2026-09-04) : la porte est « lcars tool catalogue-source » (bin/lcars) — l'entrypoint ne
  # fait plus que deleguer. C'est la CLI qui doit relayer la VALEUR.
  grep -qE 'FORGE_TOKEN="\$\{FORGE_TOKEN:-\}"' "$REPO/runtime/bin/lcars"
  grep -qE 'FORGE_TOKEN="\$sys_tok_value"' "$REPO/runtime/services/forge-gestures.sh"
}

# ─── MUR 4 — LA POSTCONDITION MESURE LE DETENTEUR, PAS LE GROUPE ────────────────────────────────

# ─── MUR 5 — AUCUNE REGLE SUDOERS N'ACCORDE ROOT A UN GROUPE ────────────────────────────────────
#
# ⚠ C'ETAIT LE LIEN LE PLUS FIN DU SYSTEME. `%fleet ALL=(root) NOPASSWD:` ouvrait un binaire root a
# TOUT membre d'un groupe que `human-converger` repeuple depuis l'equipe `humans` de la forge,
# toutes les trente secondes. Le droit d'executer du code en root avait donc la peremption d'un
# cache — et se retirer demandait un `pkill`.
#
# Le mur porte sur le DEPOT ENTIER, pas sur le module qui l'a pose : ce qu'on interdit n'est pas
# « que ce fichier-la recommence », c'est qu'un vingt-cinquieme site, ecrit dans six mois par
# quelqu'un qui n'a lu aucune de ces lignes, rouvre le chemin ailleurs.

@test "MUR 5: aucune ligne de CODE n'accorde root a un groupe par sudoers" {
  local f
  for f in "${CODE[@]}"; do
    # `ALL=(root)` est la syntaxe d'une regle. La PROSE qui nomme la regle retiree est legitime —
    # c'est son metier — et `code_of` l'a deja retiree.
    absent 'ALL=\(root\)' "$f"
  done
}

@test "MUR 5 bis: le rail d'outillage ne passe plus par sudo" {
  # GARDE D'INSTRUMENT ET DE SUBSTANCE A LA FOIS. Le mur 5 interdit d'ECRIRE la regle ; celui-ci
  # verifie que l'APPELANT ne la cherche plus. Les deux moities vont par paire : une regle absente
  # avec un appelant qui fait encore `sudo -n` donne un rail mort, pas un rail sur.
  local recon="$REPO/runtime/lib/fleet/admiral/toolchain_reconciler.ex"
  [ -f "$recon" ] || { echo "reconciliateur introuvable : $recon" >&2; return 1; }
  local n
  n="$(grep -cE 'System.cmd\("sudo"' "$recon" || true)"
  [ "$n" -eq 0 ] || { grep -nE 'System.cmd\("sudo"' "$recon" >&2; return 1; }
  grep -q 'toolchain.sock' "$recon"
}

@test "MUR 5 ter: le service privilegie n'OUVRE aucun secret" {
  # ⚠ LA MOITIE QUI REND LE RETRAIT DEFENDABLE. Deplacer le geste root derriere une socket ne vaut
  # que si le process qui le porte ne detient rien : sinon on a juste change la porte du meme
  # cumul — privilege ET secrets dans le meme espace d'adressage, ou un defaut escalade ce qu'il
  # vole. C'est la regle qui donne sa forme a tout ce chantier, lue de l'autre cote.
  local svc="$REPO/runtime/services/privileged-executor.py"
  [ -f "$svc" ] || { echo "service privilegie introuvable : $svc" >&2; return 1; }
  absent "$TOKENS_DIR" "$svc"
  absent '(MASTER_TOKEN|gitea_token|forge-master|forge-seed)' "$svc"
}

# ─── MUR 6 — LA REGLE D'ELIGIBILITE NE LIT PLUS AUCUN GROUPE ────────────────────────────────────
#
# ⚠ C'ETAIT LA DERNIERE LECTURE DE `/etc/group` QUI DECIDAIT QUELQUE CHOSE, et c'est ce qui la
# rendait dangereuse : les autres ayant disparu, elle serait devenue celle dont plus personne ne sait
# ce qu'elle tranche. Elle se disait « L'ELIGIBILITE DERIVE DE L'AUTORITE » — en nommant autorite une
# PROJECTION que le convergeur refaisait toutes les trente secondes depuis l'equipe `humans`.
#
# ⚠ ET L'EXCLUSION DU SIEGE ETAIT UN EFFET DE BORD DE CE FILTRE, jamais une regle : le sysadmin est
# dans `sudo` et pas dans `fleet`. Un effet de bord non nomme est ce qui disparait sans qu'on le
# voie — d'ou le second mur, qui verifie que la condition est ECRITE et keyee sur l'uid.

@test "MUR 6: la regle d'eligibilite ne lit AUCUN groupe" {
  local hum="$REPO/runtime/services/console-humans.sh"
  [ -f "$hum" ] || { echo "regle d'eligibilite introuvable : $hum" >&2; return 1; }
  absent '(getent group|LCARS_CONSOLE_GROUP|FLEET_MEMBERS|/etc/group)' "$hum"
}

@test "MUR 6 bis: l'eligibilite d'une console ne lit ni groupe ni siege — trois faits locaux" {
  # La contrepartie du mur 6. Ce qui decide est sur la ligne de `passwd` : uid dans la plage, home,
  # shell. Aucun groupe (une projection que le convergeur reecrit), aucun uid de siege (le siege a
  # une console comme tout humain ; ce qui lui reste ferme est la fleet, et GUARD B la tient).
  local hum="$REPO/runtime/services/console-humans.sh"
  absent 'LCARS_SYSADMIN_UID|SEAT_UID_FILE' "$hum"
  sed 's/#.*//' "$hum" | grep -qE 'uid.*-lt.*UID_MIN'
  sed 's/#.*//' "$hum" | grep -qE '\-d "\$home"'
}

# ─── MUR 7 — LE JETON MASTER NE SE GARDE PAS, ET C'EST CE QUI TIENT UN ARBITRAGE ────────────────
#
# ⚠ SANS CETTE PROPRIETE, UNE DECISION D'ARCHITECTURE N'EST PLUS DEFENDABLE. `02` a tranche « pas de
# troisieme process » : le jeton master (autorite TOTALE de la forge) et les jetons de role
# (identites de travail) partagent un espace d'adressage. La faiblesse est ASSUMEE, et elle ne l'est
# que parce que ce process ne garde rien — entre deux installs il n'y a RIEN a voler en memoire.
#
# ⚖ CE MUR EST LA MOITIE FAIBLE, ET C'EST DIT. La memoisation s'ecrit de dix facons qu'un texte ne
# voit pas. La propriete est tenue FONCTIONNELLEMENT par `test/services/catalogue-executor_test.py`, qui
# CHANGE le fichier entre deux appels et regarde ce qui sort — mesure du 2026-08-25 : une
# memoisation ajoutee fait rougir ses trois temoins. Ce mur-ci attrape les formes EXPLICITES, celles
# qu'on ecrit en croyant optimiser.
@test "MUR 7: le jeton master n'est ni memoise ni lu au chargement du module" {
  local svc="$REPO/runtime/services/catalogue-executor.py"
  [ -f "$svc" ] || { echo "executeur introuvable : $svc" >&2; return 1; }
  # Les formes explicites de cache.
  absent '(lru_cache|functools\.cache|@cache)' "$svc"
  # Une seule ouverture du fichier, et elle est dans la fonction — pas au niveau module.
  local n
  n="$(sed 's/#.*//' "$svc" | grep -cE 'open\(MASTER_TOKEN_FILE' || true)"
  [ "$n" -eq 2 ] || {
    echo "MUR 7: $n ouverture(s) de MASTER_TOKEN_FILE — attendu 2 (le garde de main, et master_token)" >&2
    sed 's/#.*//' "$svc" | grep -nE 'open\(MASTER_TOKEN_FILE' >&2
    return 1
  }
  # Et aucune affectation de module qui garderait la valeur.
  n="$(sed 's/#.*//' "$svc" | grep -cE '^[A-Z_]*(MASTER|TOKEN)[A-Z_]* *= *master_token' || true)"
  [ "$n" -eq 0 ]
}

@test "MUR 7 bis: le temoin FONCTIONNEL de 6d existe — le mur textuel ne suffit pas" {
  # GARDE D'INSTRUMENT, ET IL DIT UNE LIMITE. Le mur 7 attrape `@lru_cache` et une lecture au
  # chargement ; il ne voit PAS une valeur gardee dans un attribut ou une fermeture. Ce qui tient
  # vraiment la propriete est le banc python. Le supprimer laisserait le mur au vert et l'arbitrage
  # sans preuve — exactement la situation que ce fichier existe pour rendre impossible.
  local banc="$REPO/runtime/test/services/catalogue-executor_test.py"
  [ -f "$banc" ] || { echo "banc de l'executeur introuvable : $banc" >&2; return 1; }
  grep -q 'jeton-rotatif' "$banc"
  grep -q '6d: RELU a chaque appel' "$banc"
}

# ─── POSEUR → TABLE : POURQUOI IL N'Y A PAS DE MUR 8 TEXTUEL ICI ────────────────────────────────
#
# L'axe est juste, et c'est celui qui manquait : tous les murs de ce depot partent de la TABLE, donc
# aucun ne pouvait voir `bind()` — un service qui cree `/run/lcars/<x>/` avec l'uid:gid du process,
# une realite que la table ne decrit pas. La socket etait parfaite, son repertoire fermait la porte,
# et le chantier etait NON FONCTIONNEL sans qu'une ligne le dise.
#
# ⚠ MAIS UN MUR TEXTUEL NE PEUT PAS LE TENIR, ET J'EN AI ECRIT UN AVANT DE LE MESURER. Il cherchait
# le chemin litteral sur la ligne de l'appel ; le vrai code passe des VARIABLES
# (`os.makedirs(parent, …)`, `install -d … "$CONSOLE_ROOT"`). Son garde de population a rendu
# « 0 chemin trouve » — l'instrument s'est denonce lui-meme, ce pour quoi ces gardes existent.
#
# Et la moitie verifiable textuellement l'est DEJA : `system_manifest.bats` « ISO 1/2 » balaie les
# litteraux de `services/*.{sh,py}` et exige leur declaration. Elle passait — les deux sockets sont
# declarees. Ce qu'elle ne voit pas, c'est qu'un service pose un MODE ou un PROPRIETAIRE que la table
# contredit : `/run/lcars/privileged` declare `0750 root:fleet`, pose `root:root`. Deux faits sur le
# meme objet, dont un seul est du texte.
#
# ⚖ CETTE MOITIE-LA EST DONC TENUE FONCTIONNELLEMENT, dans `test/services/catalogue-executor_test.py` :
# `bind()` est APPELE dans un tmp, et on regarde le groupe que porte le repertoire. C'est la
# troisieme fois de ce chantier qu'un mur textuel ne suffit pas — apres le mode d'une ecriture
# atomique, et apres la memoisation d'un jeton.

@test "MUR 4: le minteur VERIFIE le proprietaire de ce qu'il vient d'ecrire" {
  # ⚠ LE CONTROLE EST LE JUMEAU DU MODE, ET LES DESYNCHRONISER FAIT ECHOUER CHAQUE COMPTE. Le script
  # posait `chgrp` puis verifiait `stat -c %G`. Passe au proprietaire sans changer le controle, il
  # aurait compare un groupe qui n'est plus pose — donc un `FAIL` par compte, sur des jetons
  # parfaitement valides. C'est une paire, elle se lit comme une paire.
  local src="$REPO/runtime/services/provision-role-tokens.sh"
  grep -qE 'chown "\$OWNER:\$OWNER"' "$src"
  grep -qE 'stat -c %U' "$src"
  absent 'stat -c %G' "$src"
  absent 'chgrp' "$src"
}
