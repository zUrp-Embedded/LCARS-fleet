#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/system_manifest.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: bats tests for deploy/system.manifest — le TROISIEME temoin ISO, celui de l'EMPREINTE
#
# ─── POURQUOI CE TEMOIN EXISTE ──────────────────────────────────────────────────────────────────
#
# Trois classes d'ecart entre ce que le produit DECLARE et ce qu'il POSE ont mordu en 24 h :
#
#   paquets   ce qu'`apt` installe de chaque cote        -> `deploy_manifest.bats`, bidirectionnel
#   fichiers  `/usr/share/lcars/*` pose par personne     -> `media_tree.bats`
#   EMPREINTE tout le reste                              -> CE FICHIER
#
# Les deux premieres ont ete trouvees par accident : l'une parce qu'une recette a plante, l'autre
# parce qu'un operateur s'est plaint d'une console. Un ecart qu'on decouvre par symptome est un
# ecart qu'on a mis des jours a voir.
#
# ⚠ CE TEMOIN NE LIT AUCUNE MACHINE, et c'est une limite qu'il faut connaitre. Il tient la moitie
# STATIQUE du contrat — tout ce que le code pose est declare, tout ce qui est declare a un poseur.
# La moitie vivante — opposer la table a un `find` reel — appartient au doctor et a
# `provision uninstall`, qui lisent la MEME table. Un temoin qui pretendrait mesurer la machine
# depuis ce poste mesurerait ce poste.
#
# ─── DEUX REGLES QUE CE FICHIER ENCODE, ET QUI ONT COUTE ────────────────────────────────────────
#
# 1. UN CHEMIN EST COUVERT PAR SES ANCETRES. Declarer chaque fichier de `/opt/lcars` ferait une
#    table de cent lignes que personne ne relit. `dir /opt/lcars` couvre ce qu'il contient — meme
#    idee que la couverture par glob de `site_path_covered?` dans le controleur de contrats.
#
# 2. `preserve` NE VEUT PAS DIRE « NON POSE ». `25-directories:139` cree bien les trois faces. Ca
#    veut dire POSE, JAMAIS RETIRE. Un temoin qui confondrait les deux declarerait une faute la ou
#    il n'y en a pas, et le vrai contrat — celui de l'uninstall — resterait sans gardien.

load refute

setup() {
  MANIFEST="$BATS_TEST_DIRNAME/../system.manifest"
  ROOT="$BATS_TEST_DIRNAME/../../.."
  [ -f "$MANIFEST" ]

  DECL="$BATS_TEST_TMPDIR/decl"; ROOTS="$BATS_TEST_TMPDIR/roots"
  rows > "$BATS_TEST_TMPDIR/rows"
  awk '{print $2}' "$BATS_TEST_TMPDIR/rows" | sort -u > "$DECL"
  awk '{c=$1;sub(/:.*/,"",c)} c=="prefix"||c=="dir"{print $2}' "$BATS_TEST_TMPDIR/rows" | sort -u > "$ROOTS"

  # ⚠ EXEMPTIONS NOMMEES, JAMAIS GLISSEES DANS UNE LISTE. Ces quatre repertoires appartiennent a
  # l'OS : LCARS y DEPOSE des fichiers, il ne les CREE pas, et un uninstall qui les retirerait
  # casserait la machine. C'est la meme convention que `deploy_manifest.bats` pour les paquets.
  #
  # `/home/projects/LCARS` est le CHECKOUT, monte dans la boite par l'operateur
  # (`entrypoint.sh:226`, `LCARS_SOURCE_DIR`). LCARS le LIT ; il ne le pose pas, et un uninstall qui
  # y toucherait detruirait le depot de quelqu'un.
  #
  # ⚠ `/opt/elixir-` EST LA SIXIEME, ET ELLE N'EST PAS DE LA MEME NATURE QUE LES CINQ AUTRES : ce
  # n'est pas un repertoire de l'OS, c'est un objet que le rail RETIRE. `15-toolchain` le nommait
  # pour le POSER (precompile telecharge) ; il le nomme maintenant pour le DETRUIRE sur les postes
  # qui l'ont encore — et ce mur, qui lit du code, ne distingue pas les deux (c'est son angle mort
  # connu : le radical apparait, donc il reclame une declaration).
  #
  # LA TABLE DECLARE CE QU'ON POSE ; L'ABSENCE SE CONVERGE, ELLE NE SE DECLARE PAS. L'y remettre
  # dirait « on a le droit de poser ca » d'un objet dont l'etat-cible est l'absence — exactement la
  # faute corrigee sur `/etc/sudoers.d/lcars-toolchain`, qui n'echappe a ce mur que parce que son
  # repertoire parent est exempte pour une TOUTE AUTRE raison. Le contrat d'absence est tenu par
  # `toolchain_legacy.bats`, et par lui seul.
  #
  # ⚠ `/home/catalogues` EST LA SEPTIEME, ET ELLE EST DE LA MEME NATURE QUE `/opt/elixir-` : un objet
  # que le rail NOMME sans le poser. Le cache des catalogues a demenage sous `/opt/lcars/var` le
  # 2026-09-01 ; `45-catalogues` nomme encore l'ancien chemin pour DIRE a l'operateur qu'il subsiste,
  # parce que `/home` est hors du perimetre et qu'aucun geste ne le retirera. Le declarer dirait « on
  # a le droit de poser ca » d'un chemin dont l'etat-cible est l'absence — et sur `/home`, ou rien ne
  # se supprime, ce serait la pire des declarations : celle qu'on ne peut pas tenir.
  #
  # ⚠ `/etc/apt/keyrings` EST LA HUITIEME, ET SA RAISON EST A ELLE. LCARS le CREE quand il manque
  # (`10-packages`, `ensure_dir` avant de deposer la cle docker) — donc l'argument des quatre
  # premieres, « on y depose sans le creer », ne le couvre pas. Ce qui le couvre est l'autre bout :
  # le repertoire est PARTAGE. Toutes les cles de tous les depots de la machine y vivent, et le
  # declarer promettrait un retrait qui casserait les depots des autres.
  #
  # `preserve` serait le mot juste — « pose, jamais retire » — et c'est un piege : sa garde est
  # ABSOLUE et s'evalue avant le journal, donc elle emporterait aussi `docker.asc`, que
  # `10-packages` inscrit au journal precisement pour pouvoir le retirer. Une classe qui protege le
  # contenant protegerait ici le contenu qu'on doit reprendre.
  EXEMPT="$BATS_TEST_TMPDIR/exempt"
  printf '%s\n' /usr/local/bin /etc/systemd/system /etc/sudoers.d /etc/tmpfiles.d \
                /home/projects/LCARS /opt/elixir- /home/catalogues /etc/apt/keyrings > "$EXEMPT"
}

# Les lignes de donnees du manifeste : ni commentaire, ni vide.
rows() { grep -vE '^\s*#|^\s*$' "$MANIFEST"; }

# Tout le code qui POSE quelque chose : les modules, les deux installeurs, et le RUNTIME — qui pose
# apres l'install, en boucle. Ignorer le troisieme declare une machine qui n'existe que la premiere
# seconde.
#
# ⚠ `services/*.py` A ETE AJOUTE LE 2026-08-25, ET SON ABSENCE ETAIT UN TROU, PAS UN CHOIX. Ce
# balayage ne lisait que les `.sh`. Or trois services de cette machine sont ecrits en python —
# `catalogue-executor`, `console-deck`, `lcars_socket` — et ils POSENT : deux sockets unix, entre
# autres. Aucune n'etait couverte par la table, et le temoin passait au vert en n'ayant pas regarde.
#
# Trouve par accident : un client SHELL de la meme socket a rendu visible un chemin que le service
# qui la CREE ecrivait depuis toujours. La sonde mesurait donc le LANGAGE du fichier, pas le fait de
# poser — exactement la classe de defaut que ces murs existent pour attraper.
code() {
  grep -hvE '^\s*#' \
    "$BATS_TEST_DIRNAME"/../modules.d/*.sh \
    "$ROOT"/install.sh \
    "$BATS_TEST_DIRNAME"/../../etc/deploy-release.sh \
    "$BATS_TEST_DIRNAME"/../docker/*.sh \
    "$BATS_TEST_DIRNAME"/../../services/*.sh \
    "$BATS_TEST_DIRNAME"/../../services/*.py \
    "$BATS_TEST_DIRNAME"/../lib/*.sh 2>/dev/null
}

# Les chemins litteraux que le code pose, normalises : `}` de `${VAR:-/chemin}` retire, ponctuation
# de fin retiree, versions repliees sur le joker du manifeste.
#
# ⚠ `:` BORNE UN CHEMIN, ET SON ABSENCE DE LA CLASSE A PRODUIT UN FAUX ROUGE. Un `PATH=` litteral —
# celui que `64-services` donne a la passe de convergence pour reproduire l'environnement d'un
# service systemd — commence par `/usr/local/sbin:/usr/local/bin:…`. La sonde accrochait
# `/usr/local/bin` puis avalait TOUTE la suite, et reclamait la declaration d'un objet nomme
# « /usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ». Un separateur de liste n'a jamais fait partie
# d'un chemin de fichier ; le sortir de la classe rend la sonde plus juste, pas plus permissive —
# `/usr/local/bin` seul est toujours attrape, et il est declare.
posed() {
  # ⚠ `/run/lock` MANQUAIT A CETTE CLASSE, ET L'ANGLE MORT EST DOUBLE. `/run/lock/lcars` est pose par
  # `provision-lib.sh` (le verrou de `provision apply`) et declare dans la table — mais la sonde ne
  # l'attrapait PAS : ISO 1/2 ne le voyait pas parce que le motif ne le nomme pas, et ISO 2/2 passait
  # par le radical `lcars`, trop generique pour discriminer quoi que ce soit. Les deux sens etaient
  # donc muets sur cet objet : un second `/run/lock/<truc>` pose sans declaration serait invisible,
  # et la ligne de la table pourrait disparaitre sans que rien ne crie.
  code | grep -ohE '(/usr/local/bin|/usr/share/lcars|/etc/systemd/system|/etc/tmpfiles\.d|/etc/sudoers\.d|/opt/[a-z]|/home/catalogues|/home/projects|/var/lib/lcars|/opt/lcars/runtime|/etc/lcars|/run/lock|/run/lcars)[^"$ ),;:'"'"']*' \
    | tr -d '}' \
    | sed -e 's#/$##' -e 's#\.$##' \
          `# ⚠ LA NORMALISATION D'ELIXIR EST PARTIE AVEC SON OBJET. Elle ramenait` \
          `# \`/opt/elixir-$PROV_ELIXIR_VERSION\` sur le joker de la table ; le precompile pinne a` \
          `# ete remplace par le paquet apt de la distro, donc plus aucun module ne nomme ce chemin.` \
          `# Une normalisation qui survit a l'objet qu'elle normalise est un decor : elle fait croire` \
          `# que la sonde couvre un cas que le code ne produit plus.` \
          -e 's#/opt/node-[^ ]*#/opt/node-<version>#' \
          `# le joker de l'humain s'ecrit <humain> dans la prose du code et <human> dans la table :` \
          `# deux orthographes pour UN meme fait. La table gagne — code et identifiants en anglais.` \
          -e 's#<humain>#<human>#' \
    | sort -u
}

covered() { # covered <chemin> -> 0 si lui-meme ou un ancetre est declare, ou s'il est exempte
  local p="$1" r
  grep -qxF "$p" "$DECL" && return 0
  grep -qxF "$p" "$EXEMPT" && return 0
  while read -r r; do [[ "$p" == "$r"/* ]] && return 0; done < "$ROOTS"
  return 1
}

@test "LCARS header: SOURCE/STARDATE/STATUS, et il se declare DATA" {
  run head -3 "$MANIFEST"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"data, not code"* ]]
}

@test "FORME : cinq colonnes par ligne, et une classe du vocabulaire" {
  local line n cls trait
  while read -r line; do
    n="$(awk '{print NF}' <<<"$line")"
    [ "$n" -eq 5 ] || { echo "ligne a $n colonnes : $line"; return 1; }
    cls="$(awk '{print $1}' <<<"$line")"
    # ⚠ LE TRAIT EST UN SUFFIXE DE LA PREMIERE COLONNE, PAS UNE SIXIEME COLONNE. Le choix est celui
    # que le manifeste fait deja pour le GID d'`account` : on n'ajoute pas un champ que la plupart
    # des lignes laisseraient vide. Consequence a tenir : tout lecteur DECOUPE avant de comparer.
    trait="${cls#*:}"; [[ "$trait" != "$cls" ]] || trait=""
    cls="${cls%%:*}"
    case "$trait" in
      ""|cond|merge|single|unset) ;;
      *) echo "trait inconnu « $trait » : $line"; return 1 ;;
    esac
    case "$cls" in
      prefix|dir|anchor|link|group|runtime|human|preserve) ;;
      # ⚠ TROIS CLASSES AJOUTEES LE 2026-08-28, chacune sur une mesure de banc vierge :
      #   account  deux comptes de service survivaient a `uninstall --yes`, avec leur groupe
      #   person   `/home/lcars` portait 32 objets qu'aucune classe ne nommait
      #   docker   quatre volumes survivaient, dont celui qui porte les depots de la forge
      # `account` et `person` sont DEUX classes et pas une avec un drapeau : un compte de service se
      # retire toujours, un compte d'humain jamais sans qu'on le demande. Les fondre ferait un
      # desinstalleur qui supprime des gens.
      account|person|docker) ;;
      *) echo "classe inconnue « $cls » : $line"; return 1 ;;
    esac
  done < "$BATS_TEST_TMPDIR/rows"
}

@test "SUBSTRAT : la cinquieme colonne est du vocabulaire connu" {
  local s
  while read -r s; do
    [[ "$s" =~ ^(any|wsl|linux|docker)(\+(any|wsl|linux|docker))*$ ]] \
      || { echo "substrat inconnu : $s"; return 1; }
  done < <(awk '{print $5}' "$BATS_TEST_TMPDIR/rows")
}

@test "ISO 1/2 : tout chemin POSE par le code est couvert par la table" {
  # Le sens qui attrape un module neuf. `44-media` a pose `/usr/share/lcars` pendant des heures sans
  # que rien ne le declare — trouve parce qu'une recette a plante, pas par un temoin.
  local p bad=0
  while read -r p; do
    covered "$p" || { echo "POSE, NON DECLARE : $p"; bad=1; }
  done < <(posed)
  [ "$bad" -eq 0 ]
}

# ⚠ AUCUN ACCENT GRAVE DANS CE TITRE, ET CE N'EST PAS UN CHOIX DE STYLE. Depuis bats 1.11 le nom
# d'un test est evalue par le shell : la premiere version disait « borne un chemin sur `:` » et
# EXECUTAIT `:` au chargement du fichier. Inoffensif ici, interdit partout — le gate porte une regle
# `bats.descriptions_inert` pour exactement ca, et je venais de l'enfreindre en la connaissant.
@test "le scraper BORNE un chemin sur le deux-points — un PATH= n'est pas un objet a declarer" {
  # ⚠ LA CORRECTION QUI A OUVERT CE TEMOIN N'EN AVAIT AUCUN. `64-services` donne a la passe de
  # convergence le `PATH` que systemd pose par defaut, en litteral. La classe d'exclusion de `posed()`
  # ne contenait pas `:` : la sonde accrochait `/usr/local/bin` puis avalait toute la suite, et
  # reclamait la declaration d'un objet nomme « /usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ».
  #
  # ⚠ ET ON NE MESURE PAS SUR LE DEPOT. Le corriger en lisant les fichiers reels ferait un temoin
  # vert le jour ou plus personne n'ecrit de `PATH=` — donc un temoin qui s'eteint tout seul. On lui
  # donne son propre echantillon, et on verifie les DEUX moities : le separateur borne, et le chemin
  # simple reste attrape.
  local ech; ech="$BATS_TEST_TMPDIR/echantillon.sh"
  printf '%s\n' 'env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin cmd' \
                'install -d /run/lcars/quelque-chose' > "$ech"
  local vus; vus="$(code() { cat "$ech"; }; posed)"

  # Le PATH ne produit AUCUN objet a rallonge…
  refute grep -q ':' <<<"$vus"
  # …et le chemin simple qu'il contient est quand meme vu, comme le chemin ordinaire d'a cote.
  grep -qx '/usr/local/bin' <<<"$vus"
  grep -qx '/run/lcars/quelque-chose' <<<"$vus"
}

@test "ISO 2/2 : tout objet DECLARE a un poseur dans le code" {
  # Le sens qui attrape une declaration morte — la faute exacte du corpus d'alice, qui declarait
  # `/etc/tmpfiles.d/lcars.conf` quand le fichier pose s'appelle `lcars-console.conf`.
  #
  # ⚠ ON CHERCHE LE RADICAL, PAS LE NOM COMPOSE. Le code ecrit `"/opt/elixir-${VERSION}"` et
  # `"$1.service"` depuis `UNITS=(…)` : le nom complet n'apparait JAMAIS littéralement. Un temoin
  # qui cherche `lcars-landing.service` declare quatre objets morts qui sont tous vivants — mesure
  # du 2026-08-22, sur ce fichier meme.
  local cls p rest base stem bad=0 CODE
  CODE="$(code)"
  while read -r cls p rest; do
    cls="${cls%%:*}"        # le trait qualifie la classe, il ne la remplace pas
    if [[ "$cls" == "group" ]]; then
      grep -qF "$p" <<<"$CODE" || { echo "GROUPE DECLARE, aucun poseur : $p"; bad=1; }
      continue
    fi
    base="$(basename "$p")"
    [[ "$base" == "<human>" ]] && continue
    # ⚠ POSE PAR UN TIERS QU'ON INVOQUE — exemption NOMMEE, une ligne par objet, jamais une regex.
    # `/root/.terraform.d` est le cache de plugins que le binaire `tofu` ecrit sous le HOME de root
    # quand `46-tofu` l'invoque : aucun module ne l'ecrit, donc ISO 2/2 le refuse a juste titre. On
    # le declare parce qu'on le PROVOQUE — c'est ce que l'uninstall doit pouvoir retirer — et
    # l'exemption dit pourquoi il n'a pas de poseur dans ce depot.
    # Elargir cette liste sans nommer l'outil rouvrirait la porte que ce temoin ferme : un objet
    # declare que personne ne pose est, par defaut, une ligne qui ment.
    #
    # ⚠ `~/.hex` NE PASSAIT QUE PAR COINCIDENCE, et c'est pourquoi il est nomme ici avec `~/.mix`.
    # Les deux sont ecrits par `mix` quand `48-forge-host` et `60-deploy` invoquent `mix local.hex`
    # et `mix local.rebar`. Le radical `.hex` trouvait cette invocation — la sous-chaine « local.hex »
    # le contient — et le temoin le declarait couvert. `.mix`, lui, n'apparait nulle part : meme
    # objet, meme poseur, meme nature, et un verdict oppose selon l'orthographe d'une commande.
    case "$p" in
      /root/.terraform.d)      continue ;;   # tiers : le binaire `tofu`, invoque par 46-tofu
      /home/\<human\>/.hex)    continue ;;   # tiers : `mix local.hex`,   48-forge-host + 60-deploy
      /home/\<human\>/.mix)    continue ;;   # tiers : `mix local.rebar`, 48-forge-host + 60-deploy
    esac
    stem="$(sed -e 's#-<version>$##' -e 's#\.service$##' <<<"$base")"
    grep -qF "$stem" <<<"$CODE" || { echo "DECLARE, aucun poseur : $p (radical « $stem »)"; bad=1; }
  done < "$BATS_TEST_TMPDIR/rows"
  [ "$bad" -eq 0 ]
}

@test "le nom REEL du fichier tmpfiles, pas celui qu'on croit" {
  # ⚠ L'ECART QUI JUSTIFIE A LUI SEUL CE FICHIER. Le corpus declarait `lcars.conf` ; `25-directories`
  # pose `lcars-console.conf`. Un desinstalleur ecrit depuis la table fausse le raterait,
  # silencieusement et pour toujours.
  grep -qE '^anchor +/etc/tmpfiles\.d/lcars-console\.conf ' "$MANIFEST"
  # ⚠ ET CETTE INTERDICTION ETAIT INERTE — le temoin qui justifie ce fichier ne gardait qu'a moitie.
  # Mutation du 2026-08-26 : l'ancien nom `lcars.conf` remis au manifeste a cote du bon laissait le
  # temoin VERT. Les deux `grep` positifs encadrants reussissaient, et le `!` du milieu, exempte
  # d'`errexit`, echouait sans consequence. Detail : `refute.bash`.
  refute grep -qE '^anchor +/etc/tmpfiles\.d/lcars\.conf ' "$MANIFEST"
  grep -q 'lcars-console.conf' "$BATS_TEST_DIRNAME/../modules.d/25-directories.sh"
}

@test "le marqueur HORS de l'arbre /run/lcars est declare" {
  # `/run/lcars-converger.refused` vit a la RACINE de `/run`. Un `rm -rf /run/lcars` ne l'emporte
  # pas. Ni la mesure machine ni la table du corpus ne l'avaient : c'est la lecture du RUNTIME qui
  # l'a rendu visible.
  grep -qE '^runtime +/run/lcars-converger\.refused ' "$MANIFEST"
  grep -q 'lcars-converger.refused' "$BATS_TEST_DIRNAME/../../services/human-converger.sh"
}

@test "preserve = POSE mais JAMAIS RETIRE — pas « non pose »" {
  # `25-directories` cree les trois faces. Confondre les deux sens ferait declarer une faute la ou
  # il n'y en a pas, et laisserait le vrai contrat — celui de l'uninstall — sans gardien.
  #
  # ⚠ CE TEMOIN CHERCHAIT LE POSEUR DANS UN SEUL MODULE, ET COMPTAIT « exactement trois ». Les deux
  # etaient des raccourcis vrais au moment ou ils ont ete ecrits : toutes les lignes `preserve`
  # etaient des faces, toutes posees par `25-directories`. Le 2026-08-26, `/etc/skel/.bashrc` est
  # devenu preserve — pose par `62-runtime-helpers`, et quatrieme. Un compte litteral se relit comme
  # une regle (« il ne peut y en avoir que trois ») alors qu'il n'etait qu'un inventaire.
  #
  # Ce qui se mesure vraiment est en DEUX parties : chaque ligne preservee a un poseur QUELQUE PART,
  # et les trois faces canoniques sont toujours la. Le nombre total n'est ni l'un ni l'autre.
  local p
  while read -r p; do
    grep -rqF -- "$p" "$BATS_TEST_DIRNAME"/../modules.d/*.sh \
      || { echo "objet preserve sans poseur dans modules.d : $p"; return 1; }
  done < <(awk '{c=$1;sub(/:.*/,"",c)} c=="preserve"{print $2}' "$BATS_TEST_TMPDIR/rows")

  local f
  for f in /home/projects /home/projects.ops /home/projects.workshop; do
    awk '{c=$1;sub(/:.*/,"",c)} c=="preserve"{print $2}' "$BATS_TEST_TMPDIR/rows" | grep -qx -- "$f" \
      || { echo "face canonique DISPARUE de preserve : $f"; return 1; }
  done

  # ⚠ GARDE DE POPULATION : zero ligne `preserve` passerait les deux boucles ci-dessus.
  [ "$(awk '{c=$1;sub(/:.*/,"",c)} c=="preserve"' "$BATS_TEST_TMPDIR/rows" | wc -l)" -ge 3 ]
}

# ⚠ CE TEMOIN DISAIT « AUCUN LECTEUR », ET IL EST TOMBE — pas en rougissant, en RESTANT VERT.
#
# Il balayait `modules.d/*.sh`. Le premier lecteur de production est arrive dans
# `lib/provision-lib.sh` (`prov_manifest_gid`, lu par `ensure_group`), c'est-a-dire hors de sa
# fenetre : il a continue d'affirmer qu'il n'y en avait aucun. Un temoin qui regarde a cote reste
# vert sur l'evenement meme qu'il attendait — troisieme fois dans ce lot.
#
# Ce qui est epingle maintenant est le FAIT, pas son absence : la table a un lecteur, il est nomme,
# et il applique la colonne GID. Le jour ou `25-directories` ou le doctor la liront aussi, ce
# temoin les accueille sans changer de forme.

@test "LA TABLE A UN LECTEUR DE PRODUCTION, et il applique la colonne GID" {
  local lib="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  # Le lecteur existe et il lit bien CE fichier.
  grep -q '^prov_manifest_gid()' "$lib"
  sed 's/#.*//' "$lib" | grep -q 'system\.manifest'
  # Et il sert : `ensure_group` en derive le `-g`, jamais un litteral.
  local body; body="$(sed -n '/^ensure_group()/,/^}$/p' "$lib")"
  grep -q 'prov_manifest_gid' <<<"$body"
  grep -q 'groupadd' <<<"$body"
  # Garde d'instrument : une extraction cassee rendrait vide, donc verte sur rien.
  [ "$(wc -l <<<"$body")" -gt 10 ]
}

@test "un GID absent de la table reste FLOTTANT — on ne l'invente pas" {
  # La table dit ce qu'on a le droit de poser ; elle ne fabrique pas de numero. Un groupe qu'elle
  # ne nomme pas doit passer par `groupadd` nu, sans `-g`.
  local lib="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  eval "$(sed -n '/^prov_manifest_gid()/,/^}$/p' "$lib")"
  # ⚠ PORTANT, malgre le signalement : la fonction eval-uee lit `$PROVISION_LIB` pour retrouver la
  # table. Verifie par mutation — un chemin bidon fait rougir ce temoin.
  # shellcheck disable=SC2034 # lu a l'interieur de l'`eval`, invisible a l'analyse statique
  PROVISION_LIB="$lib"
  run prov_manifest_gid "groupe-que-la-table-ne-nomme-pas"
  [ -z "$output" ]
  run prov_manifest_gid "fleet"
  [ "$output" = "2000" ]
}

# ⚠ L'ANGLE MORT QUE NI ISO 1/2 NI ISO 2/2 NE PEUVENT VOIR, ET IL A COUTE QUATRE LIENS MORTS.
#
# `unit_path()` compose `"$1.service"` a l'execution : aucun des quatre noms n'existe LITTERALEMENT
# dans le code. ISO 1/2 extrait des litteraux — il ne les trouve pas. ISO 2/2 cherche le radical
# dans le code — il le trouve, mais dans `UNITS=`, pas au site de pose. Un objet dont le nom se
# compose sous un repertoire exempte est invisible aux DEUX sens du contrat.
#
# MESURE DU 2026-08-28 : apres `uninstall --yes`, les quatre liens `multi-user.target.wants/` sont
# encore la, pointant vers des unites SUPPRIMEES — quatre liens morts dans une cible systemd, que le
# prochain boot signale sans que rien ne le repare.
#
# LE GESTE N'EST PAS D'AGRANDIR UNE REGEX, c'est de DERIVER la liste de sa source. `UNITS=` est la
# seule autorite sur ce qui est active ; la table doit la refleter, et ajouter une cinquieme unite
# sans la declarer doit rougir ICI.

@test "ACTIVATION : chaque unite de UNITS= a son lien declare dans la table" {
  local mod="$BATS_TEST_DIRNAME/../modules.d/64-services.sh"
  local units u bad=0
  # ⚠ `UNITS=(…)` TIENT SUR UNE SEULE LIGNE, donc une plage `sed '/^UNITS=(/,/)/'` ne s'arrete pas :
  # le `)` de fin est celui de l'ouverture, et la plage court jusqu'au suivant — elle avalait la
  # prose du module. Le voisin `services_dir.bats` peut utiliser une plage parce que `HELPERS=(` est
  # multi-ligne et se ferme sur `^)`. Ici, la ligne suffit.
  units="$(grep '^UNITS=' "$mod" | head -1 | tr -d '()' | sed 's/^UNITS=//' | tr ' ' '\n' | grep -v '^$')"
  # Garde d'instrument : une extraction cassee rendrait vide, donc verte sur rien.
  [ "$(grep -c . <<<"$units")" -ge 4 ]
  for u in $units; do
    grep -qE "^link +/etc/systemd/system/multi-user\.target\.wants/${u}\.service " "$MANIFEST" \
      || { echo "unite ACTIVEE mais lien NON declare : $u"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

# ⚠ LA COLONNE SUBSTRAT MENTAIT, ET RIEN NE POUVAIT LE DIRE TANT QU'ELLE N'ETAIT PAS LUE.
#
# Les quatre unites, leurs quatre liens et `services.env` etaient declares `linux` SEUL. Or
# `64-services` porte `APPLY-ON: wsl linux` et les POSE sur WSL — mesure du 2026-08-28, le banc en
# portait quatre. Sans consequence tant que l'uninstall retirait tout sans lire la colonne ; le
# filtre substrat (iteration 2) l'a rendue mordante, et sur un poste WSL ces neuf objets
# n'entraient plus au plan DU TOUT.
#
# Le geste n'est pas de corriger neuf lignes : c'est de DERIVER le substrat du module qui pose.
# Un module qui gagne un terrain, ou une unite qui change de main, doit faire rougir ICI.

@test "SUBSTRAT : celui des unites suit l'APPLY-ON du module qui les pose" {
  local mod="$BATS_TEST_DIRNAME/../modules.d/64-services.sh"
  local applique u col bad=0
  applique="$(grep -m1 '^# APPLY-ON:' "$mod" | sed 's/^# APPLY-ON: *//' | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')"
  # Garde d'instrument : un en-tete illisible rendrait vide, donc vert sur rien.
  [ -n "$applique" ]
  for u in $(grep '^UNITS=' "$mod" | head -1 | tr -d '()' | sed 's/^UNITS=//'); do
    col="$(awk -v u="/etc/systemd/system/$u.service" '{c=$1;sub(/:.*/,"",c)} c=="anchor" && $2==u { print $5 }' "$MANIFEST")"
    [ -n "$col" ] || { echo "unite non declaree : $u"; bad=1; continue; }
    # `wsl+linux` en table doit couvrir `wsl linux` en en-tete, dans les deux sens.
    local vu; vu="$(tr '+' '\n' <<<"$col" | sort | tr '\n' ' ')"
    [ "$vu" = "$applique" ] || { echo "$u : table dit « $col », le module pose sur « $applique »"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

@test "les GID declares sont FIXES, et ils sont ceux de l'image" {
  # Mesure .63 : fleet 1001, lcars-admin 1002, lcars-console 1003 — flottants, distribues par
  # `groupadd`. Le Dockerfile, lui, fixe fleet 2000 et lcars-console 2001. Les deux substrats
  # divergent donc sur un fait, et c'est la colonne de ce fichier qui les remettra d'accord.
  # ⚠ LE TRAIT `unset` EST EXEMPTE, ET C'EST LE POINT DU TRAIT. Un groupe declare `group:unset` dit
  # « on a le droit de poser ce groupe, on n'impose pas son numero » — exiger un GID de lui serait
  # exiger le contraire de ce qu'il declare. Ce qui reste verrouille : tout groupe SANS trait porte
  # un numero fixe, au-dessus du plancher.
  local g gid
  while read -r g gid; do
    [[ "$gid" =~ ^[0-9]+$ ]] || { echo "GID non numerique pour $g : $gid"; return 1; }
    [ "$gid" -ge 2000 ] || { echo "GID $gid sous le plancher fixe (2000) pour $g"; return 1; }
  done < <(awk '$1=="group"{print $2, $3}' "$BATS_TEST_TMPDIR/rows")
  grep -qE '^group +fleet +2000 ' "$MANIFEST"
  grep -qE '^group +lcars-console +2001 ' "$MANIFEST"
}

@test "PREFIX : la classe la plus importante de la table a un POSEUR, pas un effet de bord" {
  # ⚠ TROUVE PAR LE CYCLE DU RANG D, PAS PAR CE FICHIER, et l'angle mort merite d'etre nomme :
  # ISO 2/2 cherche un RADICAL du chemin dans le code. « runtime » apparait partout, donc
  # `/opt/lcars/runtime` etait declare « couvert » alors qu'aucun module ne le CREAIT — c'est
  # `etc/deploy-release.sh` qui le faisait apparaitre par `mkdir -p`, sous `runuser -u bob`.
  #
  # Consequence mesuree (banc 2001, 2026-09-01) : apres `uninstall --yes` puis re-apply, le prefixe
  # renaissait en `bob:fleet` au lieu de `root:fleet`. Invisible sur une machine ou il existe deja,
  # parce que `mkdir -p` ne touche pas aux droits d'un repertoire present.
  local dirs_mod="$BATS_TEST_DIRNAME/../modules.d/25-directories.sh"
  local liste; liste="$(sed -n '/^prov_dirs()/,/^}$/p' "$dirs_mod")"
  [ -n "$liste" ]
  grep -q 'PROV_PREFIX' <<<"$liste"

  # et il est pose avec ce que la TABLE declare, pas avec autre chose
  local decl; decl="$(awk '{c=$1;sub(/:.*/,"",c)} c=="prefix"{print $3, $4; exit}' "$MANIFEST")"
  [ "$decl" = "0750 root:fleet" ]
  grep -qE 'PROV_PREFIX 0750 root:\$PROV_FLEET_GROUP' <<<"$liste"
}
