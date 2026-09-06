#!/usr/bin/env bats
# SOURCE: deploy/tests/transverse/process_iso.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: bats tests — l'ISO des PROCESSUS : ce qui TOURNE apres le boot, des deux cotes
#
# ─── LE TROISIEME ISO, ET CELUI QUI N'AVAIT AUCUN TEMOIN ────────────────────────────────────────
#
# ⚖ USER 2026-08-22 : « les 2 rails posent le meme code, le meme LCARS, les memes scripts. une fois
# l'install terminee, on a le meme FS. pourquoi alors il y aurait des comportements differents ? »
#
# La reponse mesuree : le FS est le meme, le CONTRAT DE DEMARRAGE ne l'est pas. Le conteneur a UN
# entrypoint qui lance trois composants ; le rail natif RE-DERIVE ce contrat en unites systemd, et
# il n'en avait re-derive que deux.
#
#   entrypoint (conteneur)        rail natif
#   human-converger.sh        lcars-converger        ✓
#   console-landing.sh        lcars-landing          ✓
#   console.sh --all          AUCUN                  ← le trou
#
# CE QUE CE TROU COUTAIT. Le deck OFFRE une console a tout humain que `console-humans.sh` liste (le
# groupe unix `fleet`) ; le rail natif n'en DEMARRAIT que pour l'equipe forge `fleet:humans`. Deux
# populations, une offre, un demarreur, et ils ne coincidaient pas. L'operateur de la machine
# recevait un onglet et `[connexion impossible]` :
#
#   [lcars-deck] relais console -> /run/lcars/console/<operateur>/console.sock : [Errno 2]
#
# ⚠ LES DEUX AUTRES ISO ONT ETE TROUVES PAR SYMPTOME, PAS PAR TEMOIN — les paquets parce qu'un pod
# ne demarrait plus, les fichiers parce qu'une recette a plante. Celui-ci a ete trouve parce qu'un
# operateur s'est plaint. Trois fois le meme aveuglement ; c'est le troisieme temoin qui le ferme.

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

load ../refute

setup() {
  ENTRY="$BATS_TEST_DIRNAME/../../../runtime/services/container/boot.sh"
  SERVICES="$BATS_TEST_DIRNAME/../../modules.d/64-services.sh"
  CONVERGER="$BATS_TEST_DIRNAME/../../../runtime/services/human-converger.sh"
  [ -f "$ENTRY" ] && [ -f "$SERVICES" ] && [ -f "$CONVERGER" ]
}

# Le corps du fichier, commentaires retires. ⚠ Tous ces temoins lisent le CODE : l'entrypoint et ce
# module CITENT les noms des composants dans leur prose, et un grep nu conclurait sur ce qui est
# explique au lieu de ce qui est fait.
code() { grep -vE '^\s*#' "$1"; }

# La table declarative de `64-services` : <composant>:<unit|driven-by>:<nom>
starters() { code "$SERVICES" | sed -n '/^STARTERS=(/,/^)/p' | grep -oE '"[^"]+"' | tr -d '"'; }

@test "la table STARTERS existe, et sa forme est du vocabulaire" {
  # ⚠ SANS TABLE, CE TEMOIN NE PEUT QUE CROIRE UNE PROSE. « celui-la est demarre ailleurs » n'est
  # pas verifiable ; une ligne `console.sh:driven-by:lcars-converger` l'est.
  local n s
  n="$(starters | wc -l)"
  [ "$n" -ge 3 ]
  while read -r s; do
    [[ "$s" =~ ^[a-z0-9._-]+:(unit|driven-by):[a-z0-9-]+$ ]] || { echo "entree malformee : $s"; return 1; }
  done < <(starters)
}

# ─── LE SECOND ISO DE LA MEME TABLE : DEMARRE N'EST PAS TENU ───────────────────────────────────
#
# Le temoin ci-dessus mesure qu'un composant est LANCE. Il ne dit rien de ce qui arrive quand il
# MEURT — et c'est la que les deux rails ont diverge une seconde fois. Le rail poste pose
# `Restart=always` sur chaque unite ; le conteneur lancait `setsid <cmd> &` et tini recoltait sans
# relancer. `supervise.sh` a ferme l'ecart pour trois composants sur quatre : la landing appelait
# encore le script nu, qui se met lui-meme en arriere-plan et rend la main.
#
# LA SYMETRIE EST DANS LA TABLE, et c'est ce qui la rend verifiable : une ligne `unit:` dit que le
# rail poste donne un superviseur a ce composant ; le conteneur lui en doit un aussi, et son superviseur
# s'appelle `launch`. Une ligne `driven-by:` dit l'inverse — `console.sh` est rejoue par le
# convergeur a chaque tour, il n'a pas de superviseur et n'en veut pas.
joined() { code "$1" | sed -e :a -e '/\\$/N; s/\\\n//; ta'; }
launch_body() { code "$ENTRY" | sed -n '/^launch() {/,/^}/p'; }

@test "ISO supervision : autant de sites d'appel a launch que d'unites declarees" {
  local units sites
  units="$(starters | grep -c ':unit:')"
  sites="$(joined "$ENTRY" | grep -cE '^[[:space:]]*launch ')"
  [ "$units" -ge 4 ]
  [ "$units" -eq "$sites" ] || {
    echo "$units composants ont une unite sur le rail poste, mais $sites passent par launch dans le conteneur"
    joined "$ENTRY" | grep -E '^[[:space:]]*launch ' | cut -c1-80
    return 1
  }
}

@test "ISO supervision : setsid ne vit QUE dans launch — rien ne se lance nu a cote" {
  # ⚠ LE SENS QUI ATTRAPE LE PROCHAIN. Compter les sites d'appel ne voit pas un composant AJOUTE
  # demain avec son propre `setsid <cmd> &` : il n'aurait pas d'unite non plus, donc les deux
  # nombres resteraient egaux. Ce que ce temoin garde, c'est qu'il n'existe qu'UNE porte de
  # lancement dans ce fichier — celle qui sait relancer et borner.
  local total inside
  total="$(code "$ENTRY" | grep -c 'setsid')"
  inside="$(launch_body | grep -c 'setsid')"
  [ "$inside" -ge 2 ]
  [ "$total" -eq "$inside" ] || {
    echo "setsid apparait $total fois dans le code, dont $inside dans launch() — un composant se lance hors de la seule porte qui supervise"
    return 1
  }
}

@test "la landing passe par launch AVEC --foreground — sans lui, la relance boucle" {
  # ⚠ LES DEUX MOITIES, ET LA SECONDE EST LA MOINS EVIDENTE. `console-landing.sh` nu se met en
  # arriere-plan et rend la main aussitot : supervise le verrait sortir en 0 a chaque fois et le
  # relancerait jusqu'a sa borne, sur une machine parfaitement saine. `--foreground` fait `exec` sur
  # `console-deck.py`, donc l'enfant du superviseur EST le deck — la meme forme que l'`ExecStart` de
  # `lcars-landing.service`, qu'un temoin de `services_units` epingle de son cote.
  joined "$ENTRY" | grep -qE "^[[:space:]]*launch .*console-landing\.sh --foreground" || {
    echo "la landing n'est pas lancee par launch avec --foreground :"
    joined "$ENTRY" | grep -n 'console-landing' | cut -c1-100
    return 1
  }
}

@test "ISO : chaque composant persistant de l'entrypoint a un DEMARREUR DECLARE" {
  # C'est la regle, et elle a ete REECRITE apres l'arbitrage : pas « un composant = une unite »,
  # mais « un composant = un demarreur declare » — unite, ou composant qu'une unite pilote. Le
  # choix de l'alignement (⚖ user) rend la premiere formulation fausse : `console.sh` n'aura jamais
  # d'unite, et ce n'est pas une exemption, c'est le dessin.
  local comp bad=0
  for comp in human-converger.sh console-landing.sh console.sh; do
    code "$ENTRY" | grep -q "$comp" || { echo "$comp n'est PAS lance par l'entrypoint — table perimee ?"; bad=1; continue; }
    starters | grep -q "^$comp:" || { echo "LANCE PAR L'ENTRYPOINT, AUCUN DEMARREUR DECLARE : $comp"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

@test "ISO inverse : chaque demarreur declare designe une unite POSEE, ou un pilote qui existe" {
  # Le sens qui attrape une table morte. Une ligne qui nomme une unite que `UNITS` ne pose pas est
  # aussi fausse qu'un composant sans demarreur — et elle se lit comme une garantie.
  local s comp kind name bad=0
  while IFS=: read -r comp kind name; do
    case "$kind" in
      unit)
        code "$SERVICES" | grep -qE "UNITS=\(.*$name" \
          || { echo "$comp declare l'unite $name, absente de UNITS"; bad=1; } ;;
      driven-by)
        code "$SERVICES" | grep -qE "UNITS=\(.*$name" \
          || { echo "$comp declare le pilote $name, absent de UNITS"; bad=1; } ;;
    esac
  done < <(starters)
  [ "$bad" -eq 0 ]
}

@test "le pilote APPELLE vraiment ce qu'il est cense piloter" {
  # ⚠ LA TABLE POURRAIT MENTIR. `console.sh:driven-by:lcars-converger` n'est vrai que si le
  # convergeur appelle REELLEMENT `console.sh --all`. Sans ce temoin, la table serait une promesse
  # qu'on verifie en lisant — c'est-a-dire jamais.
  code "$CONVERGER" | grep -q 'ensure_all_consoles'
  code "$CONVERGER" | grep -qE '"\$CONSOLE" --all'
  # et il est appele PAR TOUR, pas seulement a l'enrolement
  code "$CONVERGER" | sed -n '/^converge_once()/,/^}/p' | grep -q 'ensure_all_consoles'
}

@test "l'alignement suit le LECTEUR du deck, pas l'equipe forge" {
  # Le fond du defaut : deux populations. `--all` lit `console-humans.sh`, qui est exactement ce que
  # `console-deck.py` interroge pour dessiner ses onglets. Offre et demarrage coincident alors PAR
  # CONSTRUCTION, au lieu de coincider par accident.
  local console="$BATS_TEST_DIRNAME/../../../runtime/services/console.sh"
  local deck="$BATS_TEST_DIRNAME/../../../runtime/services/console-deck.py"
  code "$console" | grep -qE 'LCARS_CONSOLE_HUMANS:-.*console-humans\.sh'
  grep -qE 'LCARS_CONSOLE_HUMANS", "[^"]*console-humans\.sh' "$deck"
}

@test "le pilote est IDEMPOTENT — sinon il empile un ttyd par tour" {
  # Mesure du 2026-08-18 : **64 ttyd par humain** sur un banc de trente minutes, quand le geste
  # faisait `rm -f` sur la socket a chaque passage. Ce qui a change est que l'idempotence vit
  # maintenant la ou elle se mesure — une connexion REELLE sur la socket, ce que le deck fera.
  local console="$BATS_TEST_DIRNAME/../../../runtime/services/console.sh"
  code "$console" | grep -q 'console_alive'
  # et l'appel par tour ne contourne pas cette garde
  code "$BATS_TEST_DIRNAME/../../../runtime/services/human-converger.sh" | grep -qv 'rm -f.*console.sock'
}

@test "sshd n'est PAS dans la table, et son absence est motivee" {
  # L'entrypoint lance un quatrieme processus persistant — `exec sshd -D -e`, son PID 1. Il n'est
  # pas un composant LCARS : sur le rail natif, c'est le systeme qui le tient. L'exclure est une
  # decision ; l'exclure en silence serait un oubli, et le prochain lecteur compterait quatre.
  code "$ENTRY" | grep -qE 'exec .*sshd'
  starters | refute_out '^sshd:'
  grep -q 'sshd' "$BATS_TEST_DIRNAME/process_iso.bats"
}

@test "LCARS_CONSOLE_GROUP n'a plus qu'UN sens — l'ambiguite est levee, et elle le reste" {
  # ⚠ CE TEMOIN A FAIT EXACTEMENT CE QU'IL ANNONÇAIT, ET IL EST TOMBE COMME PREVU.
  #
  # Il disait : « UN NOM, DEUX SENS. `console-humans.sh` l'entend comme "qui a droit a une console"
  # (defaut `fleet`) ; `console.sh` et `console-landing.sh` comme "quel groupe traverse les sockets"
  # (defaut `lcars-console`). Un operateur qui pose la variable deplace les DEUX. […] Le jour ou les
  # deux sens sont separes en deux variables, il tombe — et sa chute est le signal. »
  #
  # Le signal est venu. Le sens de trop n'a pas ete separe : il a CESSE D'EXISTER.
  # `console-humans.sh` ne lit plus aucun groupe — l'eligibilite derive de conditions de SIEGE, et
  # le groupe `fleet` etait une projection de l'equipe `humans` de la forge, refaite toutes les 30 s.
  #
  # Ce qui se garde maintenant : le nom porte UN sens, et il ne doit pas en reprendre un second.
  local hum="$BATS_TEST_DIRNAME/../../../runtime/services/console-humans.sh"
  local con="$BATS_TEST_DIRNAME/../../../runtime/services/console.sh"
  local lan="$BATS_TEST_DIRNAME/../../../runtime/services/console-landing.sh"

  # Le sens SURVIVANT, sur ses deux lecteurs : un groupe de TRAVERSEE de sockets, jamais un droit.
  grep -qE 'CONSOLE_GROUP="\$\{LCARS_CONSOLE_GROUP:-lcars-console\}"' "$con"
  grep -qE 'CONSOLE_GROUP="\$\{LCARS_CONSOLE_GROUP:-lcars-console\}"' "$lan"

  # Et la regle d'eligibilite n'en lit plus AUCUN. On mesure le CODE : la cicatrice de ce fichier
  # nomme le groupe qu'elle a retire, et c'est son metier.
  local n
  n="$(sed 's/#.*//' "$hum" | grep -cE 'LCARS_CONSOLE_GROUP|getent group|FLEET_MEMBERS' || true)"
  [ "$n" -eq 0 ] || { sed 's/#.*//' "$hum" | grep -nE 'LCARS_CONSOLE_GROUP|getent group|FLEET_MEMBERS' >&2; return 1; }
}
