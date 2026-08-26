#!/usr/bin/env bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: install.sh
#     |  |________|  | AUTHOR: DRDREE
#     |   ________   | SYSTEM: LCARS-FLEET v2 (runtime Elixir/OTP)
#     |  |  v2.0  |  | STATUS: PROTO-V2
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     install.sh — LA porte d'entrée. Une seule, toujours.
#
#     Elle détecte ce que la machine PERMET, demande ce que tu VEUX quand
#     les deux sont possibles, annonce ce que ça prend, et délègue.
#
#       --workstation   LCARS s'installe DANS ce système (WSL2 seulement).
#                       Modèle 3 zones : SOURCE (ce checkout) → INSTALL
#                       (/local/LCARS_v2, RO) → STATE (~/.lcars per-humain).
#       --box           LCARS tourne dans un conteneur. Rien hors de ton
#                       clone et de docker.
#       --bench         fournit les annexes (forge jetable + runner CI) au
#                       lieu d'exiger que tu les aies déjà.
#       --check         sonde read-only, rien n'est modifié.
#       --fleet-human N nomme le compte de fleet à créer — le nommer, c'est
#                       l'autoriser ; sans lui, aucun humain n'est créé.
#       --port-forge N  le port que publie la forge du poste (défaut 21000).
#       --port-deck N   le port du deck (défaut 20999).
#       --forge-project N  nomme l'instance de forge (défaut lcars-forge) —
#                       conteneur, réseau, volumes et runner en dérivent. C'est
#                       le geste qui en monte une SECONDE au lieu de déplacer
#                       celle qui tourne.
#
#     Le re-run est TOUJOURS sûr : pas de sentinelle, l'état c'est le
#     système, re-sondé à chaque passage.
#
# --- END HEADER ---

set -euo pipefail

# MEME REGLE QUE `provision-lib.sh`, ET C'EST POURQUOI ELLE EST ICI AUSSI. Ce script colorisait
# sans condition : redirige vers un fichier, son bandeau y laissait des `[1;37m` en clair pendant
# que le provisionnement, lui, se taisait proprement. Un log a moitie colorise est le pire des deux
# — illisible a la relecture ET incoherent. `-t 1` tranche pour les deux moities du meme geste.
# ⚠ UN SEUL INTERRUPTEUR POUR LES DEUX MOITIES : `PROV_COLOR=1` force la couleur jusque DANS le
# fichier (utile a qui relit ses installs au `cat`, qui rend les sequences), `NO_COLOR` la coupe
# partout, et sans rien c'est le terminal qui decide. Le defaut est le log NU : une sequence ANSI
# dans un fichier casse le grep et se lit en clair dans un editeur.
if [[ -n "${NO_COLOR:-}" ]] || [[ "${PROV_COLOR:-}" == "0" ]] \
   || { [[ -z "${PROV_COLOR:-}" ]] && [[ ! -t 1 ]]; }; then
  AMBER=''; CYAN=''; W=''; G=''; R=''; N=''; BA=''
  LCARS_COLOR_HINT=1
else
  AMBER=$'\033[38;5;214m'; CYAN=$'\033[0;36m'; W=$'\033[1;37m'
  G=$'\033[1;32m'; R=$'\033[1;31m'; N=$'\033[0m'; BA=$'\033[1;38;5;214m'
fi

# ─── Refus curl|bash (un installeur se lit avant de s'exécuter) ─────────────
# ⚖ USER 2026-08-19 : « si on refuse stdin c'est que ça nous a emmerdé, je paye pas une 2ᵉ fois. »
# Ce refus RESTE, et il commande la forme publique : on télécharge, on lit, on exécute. Les
# drapeaux `--box`/`--workstation` servent le cas SANS TTY (ssh non interactif, CI, cron) sur un
# fichier posé, jamais un pipe.
if [[ ! -f "${BASH_SOURCE[0]:-}" ]]; then
  echo ""
  echo "  ${R}ERREUR : install.sh doit être exécuté depuis un fichier, pas pipé depuis stdin.${N}"
  echo "  Télécharge d'abord :"
  echo "    wget -O /tmp/install.sh https://raw.githubusercontent.com/lordzurp/LCARS-fleet/main/install.sh"
  echo "    sudo bash /tmp/install.sh --workstation   # ou --box"
  exit 1
fi

# ⚠ ET IL PASSE AVANT `SCRIPT_DIR`, PAS APRES — LA GARDE ETAIT INJOIGNABLE QUAND ON PIPAIT.
# `SCRIPT_DIR` derive de `${BASH_SOURCE[0]}`, qui est NON LIE quand bash lit son script sur stdin.
# Sous `set -u`, la ligne mourait donc AVANT la garde, en rendant une erreur brute de bash a la
# place de la phrase calme — exactement le defaut que le `/dev/tty` de la pause documente deja.
# Mesure sur instance vierge (Ubuntu 26.04) : « BASH_SOURCE[0]: unbound variable », ligne 53,
# refus jamais imprime. Ca PASSAIT sur un poste au bash plus ancien, plus tolerant sur les
# elements de tableau non lies : un test vert qui ne prouvait que la version de bash de sa machine.
#
# La regle : un script qui refuse d'etre pipe doit le detecter AVANT tout ce qui suppose un fichier.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ─── Options ────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/lordzurp/LCARS-fleet.git"
BRANCH="main"
DOCTOR_MODE=0
RAIL=""              # workstation | box — VIDE tant que personne n'a choisi
FORCED_SUBSTRATE=""  # posé par --substrate : vaut pour la porte ET pour le rail
FLEET_HUMAN=""       # posé par --fleet-human : NOMMER le compte, c'est autoriser sa création
WITH_BENCH=0
# ⚠ LE CONSENTEMENT TRAVERSE L'ESCALADE. Ce rail se ré-exécute sous `sudo` (plus bas) ; sans ce
# drapeau la seconde instance rejoue tout l'accueil et REDEMANDE la validation — une seconde fois,
# et cette fois APRÈS le mot de passe, quand l'opérateur croit avoir fini de décider. Il passe en
# ARGUMENT et non en variable d'environnement : `sudo` fait `env_reset`, c'est le piège que la
# construction de REEXEC_ENV documente déjà quatre fois.
CONSENTED=0
declare -a PASSTHRU=()
declare -a DELEGATE_ARGS=()   # ce qui suit `--` : pour le delegue de la branche, verbatim

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|--doctor) DOCTOR_MODE=1; shift ;;
    --workstation)    RAIL=workstation; shift ;;
    --box)            RAIL=box; shift ;;
    --bench)          WITH_BENCH=1; shift ;;
    --consented)      CONSENTED=1; shift ;;
    --repo)   REPO_URL="${2:?--repo attend une URL}"; shift 2 ;;
    --branch) BRANCH="${2:?--branch attend un nom}"; shift 2 ;;
    # ⚠ `--substrate` EST AUSSI LU ICI, PAS SEULEMENT TRANSMIS. Il était en passe-plat pur : la porte
    # détectait son substrat, décidait le rail dessus, puis remettait au rail un `--substrate` qui
    # pouvait dire l'inverse. Les deux étages raisonnaient alors sur deux terrains différents dans le
    # même geste — et c'est précisément l'étage du haut qui refuse ou autorise. Il reste TRANSMIS :
    # forcer le substrat doit valoir pour la porte ET pour le rail, jamais pour un seul des deux.
    --substrate) FORCED_SUBSTRATE="${2:?--substrate attend une valeur}"
                 PASSTHRU+=("$1" "$2"); shift 2 ;;
    # ⚖ USER 2026-08-21 : « on crée pas un user sur une machine nue. » Ce drapeau EST la validation :
    # le nom autorise la création, et il est LU ici — pas seulement transmis — parce que le bandeau
    # de consentement doit ANNONCER le compte qui va apparaître. Un coût qui se découvre après coup
    # n'a pas été consenti.
    --fleet-human) FLEET_HUMAN="${2:?--fleet-human attend un nom}"
                   PASSTHRU+=("$1" "$2"); shift 2 ;;
    # Les deux ports publiés. PASSTHRU les porte à travers le `sudo` ET jusqu'à `provision`, qui les
    # valide — un seul valideur, chez celui qui s'en sert. Le rail BOÎTE ne les lit pas : ses ports
    # sont ceux du compose, et `--` les passe au délégué.
    --port-forge|--port-deck) PASSTHRU+=("$1" "${2:?$1 attend un port}"); shift 2 ;;
    --forge-project)          PASSTHRU+=("$1" "${2:?$1 attend un nom}"); shift 2 ;;
    --env|--human|--only) PASSTHRU+=("$1" "${2:?$1 attend une valeur}"); shift 2 ;;
    # ⚠ TOUT CE QUI SUIT `--` VA AU DÉLÉGUÉ, VERBATIM — et sans ça `--bench` était une impasse.
    # Il délègue à `bench-up.sh`, qui a ses propres options (`--project`, `--ssh-port`, `--image`),
    # et le parseur ci-dessous refuse ce qu'il ne connaît pas : aucune d'elles ne pouvait donc
    # l'atteindre. Trouvé en rejouant sur une vraie machine, pas en relisant — un délégué qu'on ne
    # peut pas paramétrer n'est utilisable que dans le cas par défaut, c'est-à-dire une fois.
    --) shift; DELEGATE_ARGS=("$@"); break ;;
    --help|-h)
      sed -n '/^#     install.sh — LA porte/,/^#     système/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,5\}//'
      exit 0 ;;
    *) echo "Option inconnue : $1 — --help" >&2; exit 1 ;;
  esac
done

# ─── PRÉFLIGHT COMMUN — ce dont les DEUX branches ont besoin ────────────────
# Et docker en fait partie, y compris pour le poste : la forge de LCARS est un CONTENEUR, il n'en
# existe aucune autre forme dans ce dépôt. Un poste sans docker installe un runtime qui ne peut pas
# travailler. ⚖ USER : « ça, on refuse. docker-desktop c'est un clic. »
preflight_ok=1
say_ok()   { echo "  ${G}[ok]${N} $1"; }
say_miss() { echo "  ${R}[MANQUE]${N} $1"; preflight_ok=0; }

# UN MANQUE QUE LA SUITE COMBLE N'EST PAS UN PRÉREQUIS. `10-packages` pose `docker-ce` sur le
# substrat `linux` et sur lui SEUL — sur WSL le daemon vient de Docker Desktop, que rien ici ne peut
# installer, et dans un conteneur il n'y a rien à monter. La condition est donc la même des deux
# côtés, et elle se dit une fois : Linux natif, machine déclarée dédiée.
#
# ⚠ LA DÉCLARATION COMPTE AUTANT QUE LE SUBSTRAT. Sans `LCARS_ALLOW_ANY_HOST`, ce provisionnement
# n'a pas le droit de toucher cette machine — donc promettre qu'il y installera docker serait une
# promesse qu'il ne tiendra pas : `00-preflight` refusera trois lignes plus loin.
# Loi 5 (fleet/deploy/README.md) : poser un paquet est réservé au rail qui a REÇU la machine. La
# boîte est invitée — elle exige un daemon debout et n'en installe aucun, quel que soit le drapeau.
# Le rail fait donc partie de la question : sans lui, la réponse vaut pour un rail qu'on ignore.
docker_installable_here() {   # 0 si le rail POSTE peut poser docker sur cette machine-ci
  [[ "${RAIL:-}" != "box" ]] || return 1
  [[ -n "${LCARS_ALLOW_ANY_HOST:-}" ]] || return 1
  local s="${FORCED_SUBSTRATE:-$(detect_substrate 2>/dev/null || echo "")}"
  [[ "$s" == "linux" ]]
}

echo ""
echo "  ${W}Préflight${N}"
for t in git curl; do
  command -v "$t" >/dev/null 2>&1 && say_ok "$t" || say_miss "$t — apt install $t"
done
# ⚠ `sudo` N'EST PAS UN PREREQUIS COMMUN, ET LE METTRE ICI REFUSAIT DES MACHINES SAINES. C'est une
# exigence du rail POSTE, qui escalade pour provisionner. Le rail BOITE ne monte jamais en root : il
# n'a besoin de sudo que si la socket docker appartient a root — et la sonde le dit deja
# (`PROV_DOCKER_DENIED`). Sur une machine ou l'humain atteint docker directement, exiger sudo est un
# refus sans objet.
#
# Mesure : le gate CI tourne dans `lcars-build:2`, sous `builder`, SANS sudo — et il a docker par
# son daemon embarque. Le preflight commun y refusait tout, donc cinq temoins de ce rail tombaient
# en CI en passant partout ailleurs. C'est la meme regle que le preflight de branche : ce qui n'est
# vrai que d'une branche se verifie DANS cette branche.

# ⚠ ON SONDE UN ENDPOINT QUI RÉPOND, PAS UN BINAIRE. Mesuré sur une instance VIERGE — la seule
# mesure qui vaille, un poste de travail portant des années de câblage à la main : une distro sans
# intégration activée n'a NI `/usr/bin/docker` NI `/var/run/docker.sock`, et le daemon répond quand
# même, la CLI et la socket vivant dans le montage partagé par toutes les distros de la VM.
# Refuser sur l'absence du binaire refuserait cette machine-là, qui a pourtant docker.
DOCKER_OK=0
if [[ -r "$SCRIPT_DIR/fleet/deploy/lib/docker-endpoint.sh" ]]; then
  # shellcheck source=fleet/deploy/lib/docker-endpoint.sh
  . "$SCRIPT_DIR/fleet/deploy/lib/docker-endpoint.sh"
  if docker_endpoint; then
    DOCKER_OK=1; say_ok "docker répond ($PROV_DOCKER_BIN)"
  elif [[ "${PROV_DOCKER_DENIED:-0}" == "1" ]]; then
    # ⚠ « REFUSE À MOI » N'EST PAS « ABSENT », ET LE VERDICT DIFFÈRE SELON LA BRANCHE. Mesuré le
    # sur une instance vierge : la socket est `root:root 755`, donc le daemon répond et
    # l'utilisateur ne l'atteint pas. Le rail POSTE escalade en root trois lignes plus bas et s'en
    # moque ; le rail BOÎTE tourne sous l'humain et ne peut pas travailler. Refuser ici, c'était
    # refuser une machine saine sur la moitié des cas — la décision descend donc à la branche.
    echo "  ${W}[à voir]${N} $PROV_DOCKER_WHY"
  elif docker_installable_here; then
    # ⚠ LA PORTE REFUSAIT CE QUE LE RAIL SAIT DÉSORMAIS COMBLER, et les deux ne peuvent pas rester
    # en désaccord. Le motif d'origine — ⚖ « ça, on refuse. docker-desktop c'est un clic » — parle
    # de WSL, où Docker Desktop EST un clic et où rien ici ne peut l'installer. Sur du Linux natif
    # il n'y a pas de Docker Desktop : la réponse est un docker posé par apt, et c'est exactement
    # ce que `10-packages` fait depuis le 2026-08-21 (⚖ user : « tu peux toujours l'installer si tu
    # ne trouves pas »). Depuis le 2026-08-23 c'est le dépôt upstream — la ligne affichée plus bas
    # NOMME ce qui sera posé, et elle doit le suivre : une promesse faite au préflight qui ne
    # correspond pas à ce que l'opérateur voit vingt lignes plus loin est un mensonge, pas un détail.
    #
    # MESURÉ LE 2026-08-21, Ubuntu 26.04 fraîche : la porte s'arrêtait sur « aucune CLI docker », en
    # renvoyant vers un montage Docker Desktop qui n'existe pas sur une machine sans Windows — et le
    # module capable de le poser n'était jamais atteint. Un préflight ne doit refuser que ce que la
    # suite ne peut pas réparer.
    # Rail encore ouvert = les deux moitiés sont vraies en même temps, et une seule phrase ne peut
    # pas les porter : le poste posera docker, la boîte jamais. Les deux se disent, sinon on laisse
    # choisir un chemin condamné.
    if [[ -z "$RAIL" ]]; then
      echo "  ${W}[à voir]${N} docker absent — le rail POSTE le posera (docker-ce, dépôt upstream download.docker.com) ;"
      echo "           la BOÎTE, elle, exige un daemon DÉJÀ debout : elle n'installe rien (loi 5)."
    else
      echo "  ${W}[à voir]${N} docker absent — le rail le posera (docker-ce, dépôt upstream download.docker.com)"
    fi
  elif [[ "$RAIL" == "box" ]]; then
    # Loi 5 : ce rail est invité ici. Le daemon est un prérequis qu'on nomme, pas un manque qu'on
    # comble — le refus porte donc les deux sorties, pas seulement la cause.
    say_miss "$PROV_DOCKER_WHY"
    echo "           La boîte n'installe pas docker (loi 5) : pose-le comme tu l'entends,"
    echo "           ou donne cette machine au rail poste — sudo LCARS_ALLOW_ANY_HOST=1 bash $0 --workstation"
  else
    say_miss "$PROV_DOCKER_WHY"
  fi
else
  # Mode standalone : le dépôt n'est pas encore là, donc la sonde partagée non plus. On se contente
  # du minimum honnête, et la vraie sonde tournera après le clone.
  command -v docker >/dev/null 2>&1 && { DOCKER_OK=1; say_ok "docker (sonde complète après le clone)"; } \
    || say_miss "docker — Docker Desktop côté Windows, ou un docker natif (le rail le pose sur Linux dédié)"
fi

if [[ "$preflight_ok" -eq 0 ]]; then
  echo ""
  echo "  ${R}Prérequis manquants — rien n'a été fait. Comble-les et relance.${N}"
  exit 1
fi

# ─── DÉTECTION : ce que la machine PERMET, jamais ce qu'elle VEUT ───────────
# La distinction est tout le sujet. Deviner « poste », c'est posséder `/etc` de quelqu'un sans son
# accord ; deviner « boîte », c'est bâtir 3 Go que personne n'a demandés. Les deux erreurs sont
# graves et asymétriques : une question dont aucune réponse n'est sûre ne doit pas avoir de défaut.
SUBSTRATE="${FORCED_SUBSTRATE:-$(detect_substrate 2>/dev/null || { grep -qi microsoft /proc/version 2>/dev/null && echo wsl || echo linux; })}"
case "$SUBSTRATE" in
  wsl|docker|linux) ;;
  *) echo ""; echo "  ${R}--substrate $SUBSTRATE : inconnu (wsl|docker|linux).${N}"; exit 1 ;;
esac

if [[ "$SUBSTRATE" == "wsl" ]]; then
  # WSL1 n'a pas de vrai kernel, donc pas de namespaces, donc pas de bwrap : rien ne peut aboutir.
  # `wslinfo` absent = WSL antérieur au mode miroir, donc WSL2 — le refus ne se déclenche que sur
  # une preuve, jamais sur un doute.
  if [[ "$(wslinfo --wsl-version 2>/dev/null | cut -d. -f1)" == "1" ]]; then
    echo ""
    echo "  ${R}WSL1 détecté — LCARS ne peut pas y tourner.${N}"
    echo "  Les pods s'exécutent sous bwrap, qui exige des namespaces : WSL1 n'a pas de vrai kernel."
    echo "    wsl --set-version <distro> 2   (PowerShell), puis relance."
    exit 1
  fi
fi

# ─── LE CHOIX ───────────────────────────────────────────────────────────────
# ⚖ USER : « boot linux : on monte une boîte dans docker. Boot WSL : soit on monte une boîte, et
# c'est juste le kickstart ; soit on monte un poste, et on s'installe dans WSL. »
if [[ -z "$RAIL" ]]; then
  if [[ "$SUBSTRATE" != "wsl" ]] && [[ -z "${LCARS_ALLOW_ANY_HOST:-}" || "$SUBSTRATE" != "linux" ]]; then
    # Sur un Linux natif il n'y a rien à deviner : le poste est INTERDIT par le garde de cible du
    # provisionnement (il écrirait `/local` et `/home/private` sur la machine de quelqu'un). Une
    # seule option permise ⇒ pas de question, mais on le DIT.
    #
    # ⚠ « UNE SEULE OPTION » DEVIENT FAUX DÈS QUE `LCARS_ALLOW_ANY_HOST` EST POSÉ, d'où la condition
    # ci-dessus. Le drapeau est un ACTE : il dit « cette machine-ci est dédiée, je sais ce que le
    # rail poste y prend ». Continuer à afficher « une seule option est permise » pendant qu'une
    # seconde l'est serait le mensonge que ce dépôt refuse partout ailleurs — et il enverrait
    # l'opérateur monter une boîte alors qu'il vient de déclarer vouloir l'inverse.
    RAIL=box
    echo ""
    echo "  ${W}Linux natif${N} — une seule option est permise ici : la boîte."
    echo "  (le rail poste écrit dans /etc, /local et /home/private : il est réservé à WSL,"
    echo "   sauf machine DÉDIÉE déclarée telle : LCARS_ALLOW_ANY_HOST=1)"
  else
    # Les deux sont possibles. On demande, et la question dit ce que chaque branche PREND —
    # le coût est dans la question, pas après.
    #
    # ⚠ LA QUESTION DIT OÙ ON EST, et les deux terrains n'ont pas le même coût. Sur WSL le rail
    # poste possède `/etc/wsl.conf` en entier ; sur une machine dédiée il n'y a pas de wsl.conf mais
    # il n'y a pas non plus de distro jetable derrière — `wsl --unregister` n'existe pas, et
    # l'absence de désinstalleur y pèse d'un cran de plus. Une question qui décrirait le mauvais
    # terrain ferait choisir sur un coût qui n'est pas celui qu'on paie.
    if [[ "$SUBSTRATE" == "wsl" ]]; then
      _ici="${W}Tu es dans WSL2 avec docker — d'ici, les deux sont possibles.${N}"
      _prend="sudo · /etc/wsl.conf possédé entier · un groupe système ·
     /local et /home/private · et il n'existe AUCUN désinstalleur."
    else
      _ici="${W}Linux natif, machine déclarée DÉDIÉE (LCARS_ALLOW_ANY_HOST) — les deux sont possibles.${N}"
      _prend="sudo · un groupe système · /local et /home/private · des paquets ·
     et il n'existe AUCUN désinstalleur — ici il n'y a pas de distro à jeter derrière."
    fi
    # DOCKER_OK=0 ici signifie : le préflight a laissé passer parce que le rail POSTE peut poser
    # docker. La BOÎTE ne le peut pas (loi 5), donc son option se barre au lieu de s'offrir.
    if [[ "$DOCKER_OK" -eq 0 ]]; then
      _opt2_etat="${R}INDISPONIBLE ici${N} — docker n'est pas debout, et la boîte ne l'installe pas."
    else
      _opt2_etat="     Pour tout défaire : reset, 30 s."
    fi
    cat <<EOF

  $_ici

  ${BA}1)${N} ${W}TRAVAILLER SUR LCARS${N} — le code sur ce disque,
     la fleet tourne sous ton uid, le gate en 40 s.
     ${R}Ça prend${N} : $_prend

  ${BA}2)${N} ${W}LE FAIRE TOURNER${N} — une boîte, et rien hors de ton clone et de docker :
     pas de paquet, pas d'utilisateur, pas de groupe, rien dans /etc ni /usr.
     ${R}Ça prend${N} : ~3 Go · ~15 min de build · deux ports · un volume qui survit.
$_opt2_etat

EOF
    ans=""
    { read -r -p "  ${G}1 ou 2 ?${N} " ans < /dev/tty; } 2>/dev/null || ans="__NO_TTY__"
    case "$ans" in
      1) RAIL=workstation ;;
      2) if [[ "$DOCKER_OK" -eq 0 ]]; then
           echo ""
           echo "  ${R}La boîte exige un daemon docker debout, et elle n'en pose pas (loi 5).${N}"
           echo "  $PROV_DOCKER_WHY"
           echo "  Deux sorties : pose docker comme tu l'entends, puis relance ;"
           echo "  ou donne cette machine au rail poste — réponds « 1 »."
           exit 1
         fi
         RAIL=box ;;
      __NO_TTY__)
        # PAS DE DÉFAUT. Les deux erreurs sont graves et opposées ; on nomme les deux drapeaux.
        echo ""
        echo "  ${R}Pas de TTY : impossible de demander, et il n'y a pas de défaut sûr.${N}"
        echo "  Redis-le dans la ligne :"
        echo "    sudo bash $0 --workstation    # LCARS s'installe dans ce système"
        echo "    bash $0 --box                 # LCARS tourne dans un conteneur"
        exit 1 ;;
      *) echo "  ${R}Réponse « $ans » non comprise — rien n'a été fait.${N}"; exit 1 ;;
    esac
  fi
fi

# ─── PRÉFLIGHT DE LA BRANCHE ────────────────────────────────────────────────
# ⚠ APRÈS LA QUESTION, JAMAIS AVANT, et ce n'est pas un détail d'ordre. Sur la branche boîte, la
# distro n'est PAS la cible : on n'y pose ni /local, ni groupe, ni wsl.conf. Exiger une distro
# vierge dans le préflight commun refuserait la machine de travail de quelqu'un qui voulait
# simplement lancer une boîte depuis elle — c'est le cas de la machine où ce rail a été écrit.
if [[ "$RAIL" == "workstation" ]]; then
  # ⚠ LE SUBSTRAT D'ABORD, SUDO ENSUITE — ON NOMME LA RAISON LA PLUS FONDAMENTALE. Sur une machine
  # qui n'est pas WSL, ce rail est refusé QUOI QU'IL ARRIVE : dire « sudo manque » y enverrait
  # installer sudo pour se faire refuser ensuite. Mesuré en CI, où le job tourne non-root et sans
  # sudo dans un conteneur : le refus sortait « sudo est absent » sur une machine dont le vrai
  # problème est qu'elle n'est pas un poste de travail.
  #
  # ⚠ ET LE REFUS EST UN GARDE-FOU, PAS UNE INCAPACITÉ — la distinction est tout ce qui change ici.
  # Ce rail est refusé hors WSL parce qu'il POSSÈDE la machine (paquets, groupe système, /local,
  # /home/private, aucun désinstalleur), pas parce qu'il ne saurait pas y tourner : sur une machine
  # DÉDIÉE, c'est exactement l'installation qu'on veut. Le refus par défaut protège la machine de
  # quelqu'un ; il ne décrète pas que le natif est hors d'atteinte.
  #
  # `LCARS_ALLOW_ANY_HOST` est donc lu ICI comme il l'est dans `00-preflight` — MÊME drapeau, même
  # sens, aux deux étages. Il ne l'était qu'en bas : la porte refusait avant que le rail n'ait la
  # chance de le lire, donc le drapeau était inatteignable par le chemin nominal et ne servait qu'à
  # qui appelait `provision` à la main. Un drapeau qu'on ne peut pas atteindre par la porte est un
  # drapeau qui n'existe pas.
  #
  # `docker` reste refusé QUOI QU'IL ARRIVE : installer le rail poste DANS un conteneur n'a pas de
  # sens (c'est le rail boîte qui fait ça, au build de l'image), et aucun drapeau ne rend ça vrai.
  if [[ "$SUBSTRATE" != "wsl" ]]; then
    if [[ "$SUBSTRATE" == "linux" && -n "${LCARS_ALLOW_ANY_HOST:-}" ]]; then
      echo ""
      echo "  ${AMBER}Linux natif, et tu l'as déclaré DÉDIÉ (LCARS_ALLOW_ANY_HOST).${N}"
      echo "  Ce rail va posséder cette machine : paquets, groupe système, /local, /home/private."
      echo "  Il n'y a AUCUN désinstalleur, et rien de LCARS n'est mesuré sur ce substrat."
    else
      echo ""
      echo "  ${R}--workstation est réservé à WSL2.${N} Sur un Linux ordinaire, LCARS s'installe en boîte :"
      echo "    bash $0 --box"
      [[ "$SUBSTRATE" == "linux" ]] && {
        echo ""
        echo "  Si cette machine est DÉDIÉE à LCARS et que tu acceptes qu'il la possède :"
        echo "    sudo LCARS_ALLOW_ANY_HOST=1 bash $0 --workstation"
      }
      exit 1
    fi
  fi
  # ⚠ `--bench` N'A AUCUN OBJET ICI, ET L'AVALER EN SILENCE EST LA FAUTE QU'ON CORRIGE PARTOUT
  # AILLEURS. Ce drapeau FOURNIT les annexes (forge jetable + runner) au rail boîte ; le rail poste,
  # lui, monte sa propre forge par `48-forge-host`, dans son propre cycle de convergence. Le lire
  # nulle part sur cette branche, c'est laisser quelqu'un croire qu'il a demandé quelque chose.
  if [[ "$WITH_BENCH" -eq 1 ]]; then
    echo ""
    echo "  ${R}--bench n'a pas d'objet sur le rail poste.${N}"
    echo "  Il fournit les annexes à une BOÎTE ; ici la forge est montée par le provisionnement"
    echo "  lui-même (module 48-forge-host), dans le même cycle et sans drapeau."
    echo "  Tu voulais sans doute :  bash $0 --box --bench"
    exit 1
  fi

  # Ce rail escalade pour provisionner : sans sudo il ne peut rien faire. Ici et pas dans le
  # préflight commun — le rail boîte n'escalade que pour joindre le daemon, et la sonde le dit.
  if [[ "$EUID" -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    echo ""
    echo "  ${R}sudo est absent, et ce rail en a besoin pour provisionner ce système.${N}"
    echo "  La boîte, elle, ne modifie rien :  bash $0 --box"
    exit 1
  fi

  # Le seul fichier système que ce rail PREND en entier. Le reste (paquets, groupe, /local) est
  # additif ; `wsl.conf` est une propriété exclusive.
  #
  # ⚠ CE BLOC REFUSAIT, ET C'ÉTAIT TROP BRUTAL — mesuré sur une WSL 26.04 neuve le 2026-08-19.
  # Toute distro correctement préparée porte un `wsl.conf` : `[boot] systemd=true` est un prérequis
  # de LCARS lui-même, et `[user] default=` est ce que pose n'importe quel setup soigné. Refuser
  # sur son existence, c'était refuser précisément les machines prêtes, et n'accepter que celles
  # qui ne le sont pas.
  #
  # On MONTRE ce qui va disparaître, et la pause qui suit est le consentement. C'est la même règle
  # que le bandeau : le coût s'annonce, il ne se découvre pas. Ce qui serait faux, c'est d'écraser
  # en silence : un `[user] default=` présent partirait sans un mot, et la distro se rouvrirait
  # sur un autre utilisateur au prochain `wsl --shutdown`. Constaté sur une instance vierge.
  #
  # ⚠ ET IL NE S'ANNONCE QUE LÀ OÙ IL EST VRAI. `30-wsl` porte `APPLY-ON: wsl` : sur une machine
  # dédiée non-WSL, ce rail ne touche JAMAIS `/etc/wsl.conf`. Un fichier de ce nom peut pourtant s'y
  # trouver — recopié, hérité d'une image, posé par un outil tiers — et le bloc l'annonçait alors
  # comme condamné. Promettre une destruction qui n'aura pas lieu est du même ordre qu'en taire une
  # qui aura lieu : dans les deux cas l'opérateur consent à autre chose que ce qui se passe.
  if [[ "$CONSENTED" -eq 0 ]] && [[ "$SUBSTRATE" == "wsl" ]] && [[ -f /etc/wsl.conf ]] && ! grep -q "LCARS" /etc/wsl.conf 2>/dev/null; then
    echo ""
    echo "  ${R}/etc/wsl.conf existe et n'est pas le nôtre — ce rail le REMPLACE en entier.${N}"
    echo "  C'est la frontière de sécurité de la boîte (C: fermé, interop coupé), donc il n'est pas"
    echo "  fusionné : tout ce qui suit disparaît, sauvegarde ce qui compte."
    echo ""
    sed 's/^/      /' /etc/wsl.conf
    echo ""
    echo "  Si tu ne veux pas de ça : la boîte ne touche à rien —  bash $0 --box"
  fi
fi

# ─── BANDEAU DE LA BRANCHE CHOISIE, ET LUI SEUL ─────────────────────────────
if [[ "$CONSENTED" -eq 0 ]]; then
cat <<EOF

${AMBER}     ____________________________________________________
    /                                                    \\
   /                ${BA}LCARS FLEET - FEDERATION DATABASE${N}     ${AMBER}\\
  |   ________   __________________________________________\\
  |  |  2026  |  | SOURCE: install.sh
  |  |________|  | SYSTEM: LCARS-FLEET v2 (Elixir/OTP)
  |   ________   | STATUS: INSTALLER — rail ${RAIL}
  |  | AGPL-3 |  |__________________________________________
  |  |________|  \\__________________________________________\\
  |                                                         /
   \\    ${W}"To boldly go where no code has gone before..."${AMBER}    /
    \\_____________________________________________________/${N}
EOF

if [[ "$RAIL" == "workstation" ]]; then
  # `/etc/wsl.conf` n'est pris QUE sur WSL (`30-wsl`, APPLY-ON: wsl). Le bandeau annonce le coût :
  # y nommer un fichier qu'on ne touchera pas sur cette machine-ci est un coût inventé, et un coût
  # inventé décrédibilise ceux qui sont vrais.
  if [[ "$SUBSTRATE" == "wsl" ]]; then _banner_wslconf="· /etc/wsl.conf. "; else _banner_wslconf="                  "; fi
  # ⚖ LE COMPTE SE DIT AVANT D'EXISTER (USER 2026-08-21). C'est la seule mutation de ce rail qui
  # crée un UTILISATEUR sur la machine de quelqu'un ; l'annoncer dans le bandeau du coût est ce qui
  # la rend consentie, et la taire la rendrait subie. Sans `--fleet-human`, rien n'est créé : le
  # module dérive en nommant le geste, et le bandeau dit ce qui manquera.
  if [[ "$RAIL" == "workstation" ]]; then
    if [[ -n "$FLEET_HUMAN" ]]; then
      echo ""
      echo "  ${AMBER}Ce rail créera l'utilisateur « $FLEET_HUMAN »${N} (uid libre au-dessus du siège,"
      echo "  groupe fleet) : c'est lui qui fera tourner la fleet. Toi, tu restes le siège."
    else
      echo ""
      echo "  ${W}Aucun humain de fleet nommé${N} — rien ne sera créé, et personne ne pourra lancer"
      echo "  la fleet ici (ton compte est le siège, GUARD B le lui interdit). Pour en poser un :"
      echo "    sudo … bash $0 --workstation --fleet-human <nom>"
    fi
  fi
  cat <<EOF
${CYAN}  ┌─────────────────────────────────────────────────────────┐
  │${W}  RAIL POSTE — LCARS s'installe DANS ce système.${N}          ${CYAN}│
  │${N}  sudo · paquets · groupe fleet · /local · /home/private  ${CYAN}│
  │${N}  ${_banner_wslconf}${R}Aucun désinstalleur n'existe.${N}         ${CYAN}│
  │${N}  Idempotent : relancer est toujours sûr ; « --check »    ${CYAN}│
  │${N}  sonde sans rien modifier.                               ${CYAN}│
  │${N}  Confinement : les pods tournent sous bwrap, la fleet    ${CYAN}│
  │${N}  sous TON uid. Pire cas = nuke + re-provision (minutes). ${CYAN}│
  └─────────────────────────────────────────────────────────┘${N}
EOF
else
  cat <<EOF
${CYAN}  ┌─────────────────────────────────────────────────────────┐
  │${W}  RAIL BOÎTE — rien hors de ton clone et de docker.${N}       ${CYAN}│
  │${N}  Pas de paquet, pas d'utilisateur, pas de groupe, rien   ${CYAN}│
  │${N}  dans /etc ni /usr. ~3 Go d'image, ~15 min de build.     ${CYAN}│
  │${N}  Pour tout défaire : ${W}fleet/deploy/box reset${N} — 30 s.           ${CYAN}│
$( [[ -n "${PROV_DOCKER_SUDO:-}" ]] && printf '  │%s  ⚠ sudo sera demandé pour PARLER au daemon docker —%s     %s│\n  │%s    sa socket appartient à root. Aucune modification.%s    %s│\n' "$W" "$N" "$CYAN" "$N" "$N" "$CYAN" )
$( [[ "$WITH_BENCH" -eq 1 ]] && printf '  │%s  --bench : forge jetable + runner CI montés ici.%s      %s│\n' "$W" "$N" "$CYAN" \
                             || printf '  │%s  Il te faut une forge : FORGE_BASE_URL + un token.%s    %s│\n' "$N" "$N" "$CYAN" )
  └─────────────────────────────────────────────────────────┘${N}
EOF
fi

echo ""
echo "  ${G}    ▶  Entrée pour continuer${N}  /  ${R}Ctrl+C pour annuler${N}"
echo ""

# ⚠ LES ACCOLADES PORTENT LA REDIRECTION D'ERREUR, PAS LE `read`. Sans elles, l'echec du
# `< /dev/tty` est signale par le SHELL lui-meme — « install.sh: line NNN: /dev/tty: No such
# device or address » — avant la phrase calme qui l'explique, et le `2>/dev/null` du `read` ne
# l'attrape pas. Mesure du 2026-08-18, install joue par ssh sans TTY : l'operateur voit d'abord
# une erreur brute, puis apprend que tout va bien. On ne montre que la seconde.
{ read -r _ < /dev/tty; } 2>/dev/null || {
  echo "  [install] Pas de TTY — continue automatiquement (le rail est déjà choisi)."
  [[ -n "${LCARS_COLOR_HINT:-}" ]] && echo "  [install] Sortie non-terminal : couleurs coupées (PROV_COLOR=1 pour les garder dans le log)."
}
fi

# ─── LA BRANCHE BOÎTE : aucune escalade, on délègue à la porte docker ───────
# Elle ne demande PAS root, et c'est la promesse auditée du rail : « rien hors de ton clone et de
# docker ». Un `sudo` ici la casserait sans rien acheter.
if [[ "$RAIL" == "box" ]]; then
  # ⚠ CE BLOC DICTAIT UN GESTE QU'ON SAIT FAIRE, et c'est la faute qu'il fallait retirer. Il
  # renvoyait l'opérateur cliquer dans Docker Desktop ou ouvrir la socket à un groupe — pendant que
  # la seule chose qui avait jamais fait tourner ce rail, c'était un `sudo` posé À LA MAIN, hors du
  # code, par celui qui l'écrivait. Un refus qui dicte double le rail ; et un rail dont la démo tient
  # par un geste non écrit ne tient pas.
  #
  # ⚖ USER : « si l'installeur promet "jamais sudo" et ne peut pas faire son job parce qu'il faut
  # sudo, la seule conclusion logique c'est que l'installeur a besoin de sudo. » La sonde escalade
  # donc elle-même quand la socket appartient à root — et ce qui reste ici est le cas où même ça ne
  # suffit pas.
  # `sudo -v` et pas un vrai sudo : il DEMANDE le mot de passe et met en cache, sans rien exécuter.
  # Le shim de la sonde consomme ensuite ce cache, commande par commande.
  #
  # ⚠ NE PAS REMPLACER PAR UN `exec sudo`. Ce rail bâtit une image sous l'uid de l'humain : en root,
  # `git` lirait son clone en « dubious ownership » et l'image sortirait estampée `unknown`.
  #
  # ⚠ TTY OBLIGATOIRE : sans terminal, une invite pend jusqu'au timeout au lieu de refuser.
  if [[ "$DOCKER_OK" -eq 0 && "${PROV_DOCKER_DENIED:-0}" == "1" ]] \
     && command -v sudo >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
    echo ""
    echo "  ${W}[sudo]${N} La socket du daemon appartient à root — une invite, une fois."
    echo "         Elle amorce le cache que la sonde consomme commande par commande ;"
    echo "         ce rail ne monte JAMAIS en root, ton image reste bâtie sous ton compte."
    if sudo -v; then
      docker_endpoint && { DOCKER_OK=1; echo "  ${G}[ok]${N} docker répond ($PROV_DOCKER_BIN)"; }
    fi
  fi
  if [[ "$DOCKER_OK" -eq 0 ]]; then
    echo ""
    echo "  ${R}$PROV_DOCKER_WHY${N}"
    if [[ "${PROV_DOCKER_DENIED:-0}" == "1" ]]; then
      echo "  L'escalade a été tentée et refusée : « sudo -n » n'a pas abouti (mot de passe requis ?)."
      [[ -t 0 && -t 1 ]] \
        || echo "  Pas de terminal ici, donc pas d'invite possible : joue « sudo -v » d'abord, ou donne un NOPASSWD sur la CLI docker."
    fi
    exit 1
  fi
  [[ -x "$SCRIPT_DIR/fleet/deploy/box" ]] || {
    echo "  ${R}fleet/deploy/box introuvable — ce rail exige le checkout complet.${N}"
    echo "  git clone $REPO_URL && cd LCARS-fleet && bash install.sh --box"
    exit 1
  }
  if [[ "$DOCTOR_MODE" -eq 1 ]]; then
    exec "$SCRIPT_DIR/fleet/deploy/box" doctor
  fi
  # ─── L'IMAGE EST UNE PRÉCONDITION DES DEUX CHEMINS BOÎTE, ET C'EST LA PORTE QUI LA FOURNIT ──────
  # `--bench` promet « forge jetable + boîte + runner CI, EN UN GESTE », et la porte entière existe
  # pour FOURNIR les préconditions au lieu de les exiger. L'image était bâtie plus bas, sur le chemin
  # sans `--bench` UNIQUEMENT — et `--bench` `exec`ute son délégué bien avant d'y arriver. Donc sur
  # une machine sans image, le seul rail qui promet « en un geste » mourait sur « image absente
  # localement » en DICTANT `fleet/deploy/box build`. Le geste ne bouge pas, il REMONTE : un seul endroit,
  # les deux chemins.
  #
  # ⚠ ET LES DÉLÉGUÉS GARDENT LEUR REFUS. `up` porte `--no-build` sur une cicatrice mesurée (un `up`
  # qui masquait un build `--no-cache` raté en repartant du cache de layers) et `bench-up` refuse pour
  # la même raison : un build rend SON verdict, il n'est jamais l'effet de bord d'autre chose. La
  # porte, elle, a le droit de l'appeler — c'est son métier — et le verdict reste celui du build.
  #
  # ⚠ LE TROU A SURVÉCU À QUATRE REJEUX SUR TROIS MACHINES, et la raison est dans le substrat : sous
  # WSL le daemon est partagé par toute la VM, donc une distro vierge n'est PAS un docker vierge —
  # l'image était toujours déjà là. Le chemin sans image ne s'est joué qu'une fois toutes les images
  # supprimées. Les témoins de `install_door.bats` le couvrent maintenant avec un `box` espion.
  #
  # L'image PRÉSENTE n'est jamais reconstruite : rebâtir à chaque passage ferait d'un `--check` de
  # dix secondes un quart d'heure, et le re-run doit rester sûr ET court.
  BOX_IMAGE="${LCARS_IMAGE:-lcars-fleet:2}"
  for _i in "${!DELEGATE_ARGS[@]}"; do
    [[ "${DELEGATE_ARGS[$_i]}" == "--image" ]] && BOX_IMAGE="${DELEGATE_ARGS[$((_i + 1))]:-$BOX_IMAGE}"
  done
  if ! "$PROV_DOCKER_BIN" image inspect "$BOX_IMAGE" >/dev/null 2>&1; then
    echo ""
    echo "  ${W}$BOX_IMAGE${N} n'est pas là — je la construis (plusieurs minutes, une seule fois)."
    # ⚠ PAS DE `DOCKER_BIN=` ICI, ET C'EST DELIBERE : le delegue SONDE lui-meme et lit
    # `PROV_DOCKER_BIN` de sa propre sonde. Le prefixe a vecu ici sans lecteur — ni l'ancienne
    # porte ni `box` ne l'ont jamais lu. ⚠ NE PAS L'AJOUTER PAR SYMETRIE avec le `--bench`
    # plus bas : celui-la est REEL, `bench-up.sh` compose `"$DOCKER_BIN" <verbe>` et retombe
    # sinon sur un `docker` nu, contournant le shim d'escalade.
    LCARS_IMAGE="$BOX_IMAGE" "$SCRIPT_DIR/fleet/deploy/box" build || {
      echo "  ${R}Le build a échoué — son verdict est le sien, rien n'a été déployé.${N}"
      exit 1
    }
  else
    say_ok "image $BOX_IMAGE présente — je la garde (elle ne se rebâtit pas toute seule)"
  fi

  if [[ "$WITH_BENCH" -eq 1 ]]; then
    # `--bench` FOURNIT les préconditions au lieu de les exiger : forge jetable, boîte, runner CI.
    # Après lui, l'état est le MÊME qu'un déploiement où l'opérateur les avait déjà — c'est ce qui
    # empêche « flux banc » et « flux prod » de diverger.
    echo ""
    echo "  ${W}--bench${N} : forge jetable + boîte + runner CI, en un geste."
    # ⚠ LE DÉLÉGUÉ REÇOIT LA RÉSOLUTION, IL NE LA REFAIT PAS. Mesuré sur une instance vierge : sans
    # cette ligne, `bench-up.sh` retombe sur son défaut `docker` et meurt sur « docker introuvable »
    # — sur une machine où la porte venait d'annoncer « docker répond ». Deux résolutions pour un
    # fait, donc deux verdicts selon qui regarde. Le shim d'escalade voyage avec.
    export DOCKER_BIN="$PROV_DOCKER_BIN"
    exec "$SCRIPT_DIR/fleet/deploy/docker/bench/bench-up.sh" ${DELEGATE_ARGS[@]+"${DELEGATE_ARGS[@]}"}
  fi
  [[ -n "${FORGE_BASE_URL:-}" ]] || {
    echo ""
    echo "  ${R}FORGE_BASE_URL n'est pas posée — la boîte ne fabrique pas ta forge, elle la consomme.${N}"
    echo "  Deux voies :"
    echo "    ${W}--bench${N}                     LCARS monte une forge jetable + un runner pour toi"
    echo "    FORGE_BASE_URL=http://…    tu as déjà une forge  (« fleet/deploy/box forge-check »)"
    exit 1
  }
  echo ""
  echo "  ${W}up${N} — la sortie qui suit est celle de fleet/deploy/box"
  # L'image est déjà là : le bloc au-dessus l'a construite si elle manquait, pour les DEUX chemins.
  exec "$SCRIPT_DIR/fleet/deploy/box" up
fi

# ─── LA BRANCHE POSTE : escalade, source, puis le délégué de provisionnement ─
if [[ "$EUID" -ne 0 ]]; then
  echo ""
  echo "  ${W}[sudo]${N} Privilèges root requis — ton mot de passe peut être demandé."
  REEXEC_ARGS=(--workstation --repo "$REPO_URL" --branch "$BRANCH" --consented)
  [[ "$DOCTOR_MODE" -eq 1 ]] && REEXEC_ARGS+=(--check)
  # ⚠ `sudo` REMET L'ENVIRONNEMENT A ZERO (env_reset), ET C'EST LE TROISIEME PIEGE DE CETTE FAMILLE
  # MESURE SUR CETTE MACHINE. Les reglages de provisionnement posés AVANT l'escalade meurent en la
  # traversant : `PROV_COLOR=1 bash install.sh` colorisait le preflight puis rendait un
  # provisionnement blanc, sans que rien ne dise pourquoi. Les assignations en tete de commande
  # sont la forme que sudo laisse passer — on les nomme, une par une, plutot que d'ouvrir `-E`.
  #
  # ⚠ QUATRIÈME EXEMPLAIRE, ET LE PLUS COÛTEUX : `LCARS_ALLOW_ANY_HOST`. Sans lui dans cette liste,
  # la machine dédiée est INSTALLABLE EN THÉORIE ET REFUSÉE EN PRATIQUE — la porte lit le drapeau,
  # décide de laisser passer, escalade… et la seconde instance ne le voit plus, donc se refuse
  # elle-même avec le message qui invite à poser le drapeau qu'on vient de poser. Le refus est alors
  # parfaitement circulaire, et rien dans la sortie ne dit que sudo est passé entre les deux.
  REEXEC_ENV=()
  # ⚠ CINQUIÈME EXEMPLAIRE : `PROV_FORGE_ADMIN_RESET`. Le drapeau par lequel un opérateur demande un
  # mot de passe neuf pour sa forge — posé avant l'escalade, mangé par `env_reset`, et l'apply
  # repartait sans lui : le geste ne produisait RIEN, et rien ne disait pourquoi.
  for _v in PROV_COLOR NO_COLOR PROV_VERBOSE PROV_DUMP_LINES LCARS_ALLOW_ANY_HOST PROV_FORGE_ADMIN_RESET; do
    [[ -n "${!_v:-}" ]] && REEXEC_ENV+=("$_v=${!_v}")
  done
  exec sudo "${REEXEC_ENV[@]}" bash "$(readlink -f "$0")" "${REEXEC_ARGS[@]}" "${PASSTHRU[@]}"
fi
# À partir d'ici : root, SUDO_USER = l'humain.

PROVISION="$SCRIPT_DIR/fleet/deploy/provision"

if [[ ! -x "$PROVISION" ]]; then
  # Mode standalone (script téléchargé seul) : cloner la source CHEZ L'HUMAIN — c'est SON
  # checkout (3 zones : la source ne vit pas sous /local, seul l'install déployé y va).
  HUMAN="${SUDO_USER:-root}"
  HUMAN_HOME="$(getent passwd "$HUMAN" | cut -d: -f6)"
  SRC_DIR="${LCARS_SRC:-$HUMAN_HOME/LCARS-fleet}"
  if [[ -d "$SRC_DIR/.git" ]]; then
    echo "[install] source existante : $SRC_DIR — sync sur $BRANCH"
    runuser -u "$HUMAN" -- git -C "$SRC_DIR" fetch origin
    runuser -u "$HUMAN" -- git -C "$SRC_DIR" checkout "$BRANCH"
    runuser -u "$HUMAN" -- git -C "$SRC_DIR" pull --ff-only origin "$BRANCH"
  else
    echo "[install] clone $REPO_URL (branche $BRANCH) → $SRC_DIR"
    runuser -u "$HUMAN" -- git clone --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
  fi
  PROVISION="$SRC_DIR/fleet/deploy/provision"
  [[ -x "$PROVISION" ]] || { echo "[install] provision introuvable après clone : $PROVISION" >&2; exit 1; }
fi

# ─── CE QUE LE RAIL POSTE A COÛTÉ QUAND IL DÉPENDAIT DE L'IMAGE (cicatrice, 2026-08-21) ─────────
# Ce bloc bâtissait `lcars-fleet:2` pour le rail poste, et le motif était juste à l'époque :
# `48-forge-host` montait SA forge et posait sa structure par un conteneur transitoire de cette
# image, qui portait tofu, la recette et les gestes.
#
# ⚠ LE TROU AVAIT ÉTÉ INVISIBLE SUR LE SUBSTRAT OÙ CE RAIL EST ÉCRIT — sous WSL le daemon est
# partagé par toute la VM, donc une distro vierge n'est PAS un docker vierge : l'image était
# toujours déjà là. Le même masque a couvert le rail poste deux jours de plus.
#
# MESURÉ le 2026-08-21, install à froid sur une machine dédiée nue :
#   DRIFT 48-forge-host: image lcars-fleet:2 absente
#   DRIFT 50-forge: FORGE_BASE_URL non posé
#   FAIL  52-ops-branch: forge injoignable
#   DRIFT 55-deck-oidc: FORGE_BASE_URL non posé
# Quatre modules en cascade, une seule cause.
#
# ⚖ LA DÉPENDANCE EST MORTE LE 2026-08-22 (user : « tu build une image complète de 1,2 Go juste pour
# exécuter 100 ko de recette tofu ? »). `46-tofu` pose tofu et son miroir SUR la machine, et
# `48-forge-host` appelle le geste directement. LA CASCADE, ELLE, RESTE VRAIE : ces quatre modules
# tombent toujours ensemble, seule leur cause commune a changé de nom.
#
# Ce qui reste de ce bloc est la leçon, pas le geste : sur ce rail, ne rebâtis rien ici — regarde
# d'abord si la dépendance existe encore.
# ─── LES PAQUETS AVANT LE BUILD, QUAND C'EST LE RAIL QUI POSE DOCKER ────────
#
# ⚠ ORDRE, PAS CONTENU — ET C'EST LA PASSE À FROID QUI L'A RENDU VISIBLE. Depuis que la porte laisse
# passer un Linux natif déclaré sans docker (le rail l'installe), elle atteint ce build AVANT que le
# provisionnement n'ait tourné. Elle cherche donc un binaire que personne n'a encore posé.
#
# MESURÉ LE 2026-08-21, Ubuntu 26.04 fraîche :
#     ligne  5  [à voir] docker absent — le rail le posera
#     ligne 42  box: aucune CLI docker …                 ← le build échoue
#     ligne 61  POSÉ 10-packages: apt: install … docker.io  ← vingt secondes trop tard
#
# La dépendance est réelle et circulaire d'apparence : l'image a besoin de docker, `48-forge-host` a
# besoin de l'image, docker vient de `10-packages`. Elle se dénoue par l'ORDRE, pas par un artifice :
# on joue d'abord la tranche qui pose les paquets — le provisionnement est rejouable, donc ces trois
# modules seront simplement conformes au passage suivant — puis on bâtit, puis on converge tout.
#
# `--only` NE CHANGE PAS le verdict final : c'est l'apply complet, plus bas, qui fait autorité.
if [[ "$RAIL" == "workstation" && "$DOCTOR_MODE" -eq 0 ]] \
   && ! command -v "${PROV_DOCKER_BIN:-docker}" >/dev/null 2>&1 \
   && docker_installable_here; then
  echo ""
  echo "  docker n'est pas là et c'est le rail qui le pose — je joue d'abord les paquets."
  "$PROVISION" apply "${PASSTHRU[@]}" --only 00-preflight --only 05-host-consent --only 10-packages \
    || echo "  ${W}la tranche paquets n'a pas tout convergé — le build dira ce qui manque.${N}"
  # LA SONDE SE REJOUE : `docker_endpoint` a répondu « absent » il y a trente secondes, et
  # `PROV_DOCKER_BIN` porte encore cette réponse-là. Sans ce second passage, le build interrogerait
  # un chemin périmé sur une machine qui a désormais docker.
  docker_endpoint >/dev/null 2>&1 || true
fi

# ⚖ LE RAIL POSTE NE BÂTIT PLUS D'IMAGE, et l'absence de ce bloc est le gain du chantier.
#
# Il bâtissait ici `lcars-fleet:2` — dix minutes, 1,18 Go — sous le motif « la forge du poste en a
# besoin (tofu, recette, gestes) ». C'était vrai, et c'était le SEUL motif : ce rail installe un
# LCARS natif, il ne démarre jamais cette image. Il la bâtissait pour en extraire 124 Mo d'outil
# dans un conteneur jetable.
#
# ⚖ USER 2026-08-22 : « tu build une image complète de 1,2 Go juste pour exécuter 100 ko de recette
# tofu ? » — `46-tofu` pose désormais tofu et son miroir de providers SUR la machine, avec les mêmes
# pins que le Dockerfile, et `48-forge-host` appelle le geste directement.
#
# ⚠ LE RAIL BOÎTE, LUI, BÂTIT TOUJOURS (plus haut) : là, l'image EST le produit livré.

# ─── Déléguer TOUT au provisioning (l'autorité) ─────────────────────────────
if [[ "$DOCTOR_MODE" -eq 1 ]]; then
  exec "$PROVISION" doctor "${PASSTHRU[@]}"
fi
# ⚠ LE CODE DE RETOUR DE L'APPLY SE LIT, ET IL A TROIS SENS — LA PORTE N'EN CONNAISSAIT AUCUN.
# `provision apply` rend 0 (tout convergé), 2 (appliqué, drift résiduel : un geste manque, rien
# n'est cassé) ou 1 (au moins un échec). Cette ligne était nue : sous `set -e`, 1 ET 2 tuaient
# install.sh au même endroit, sans un mot, et le bandeau de fin — celui qui dit « les verdicts
# ci-dessus font foi » — n'était imprimé QUE sur une convergence parfaite.
#
# Conséquences mesurées le 2026-08-21 sur une install à froid : la première passe d'une machine
# dédiée dérive forcément (la forge n'existe pas encore), donc la porte mourait muette sur une
# installation qui venait de poser un runtime complet. L'opérateur voyait des lignes DRIFT puis
# plus rien — et rien ne lui disait si l'install avait abouti.
#
# La sémantique est celle du geste opérateur `deploy/box` (`await_provision_verdict`), reprise à
# dessein plutôt que réinventée : deux portes qui lisent le même code de retour et en tirent deux
# verdicts, c'est un code de retour qui ne veut plus rien dire.
# ⚠ LE CANAL DES IDENTIFIANTS, ET IL EST À NOUS PARCE QUE LE BANNER FINAL EST À NOUS. Les modules
# qui fabriquent un mot de passe tournent au rang 22 ou 48 : afficher sur place, c'est afficher puis
# faire défiler deux cents lignes par-dessus. Ils écrivent donc ici, et on imprime à la fin.
#
# 0600 root, et DÉTRUIT juste après l'impression : le secret ne survit pas à l'installation qui l'a
# produit. C'est la propriété qui rend l'affichage différé acceptable — sans elle on aurait échangé
# « défilé » contre « posé en clair sur le disque ».
PROV_ANNOUNCE_FILE="$(mktemp "${TMPDIR:-/tmp}/lcars-creds.XXXXXX")" && chmod 0600 "$PROV_ANNOUNCE_FILE" || PROV_ANNOUNCE_FILE=""
export PROV_ANNOUNCE_FILE

# ─── DÉTRUIRE, OUI — MAIS APRÈS AVOIR IMPRIMÉ, ET C'EST LA CORRECTION DU 2026-08-23 ──────────────
#
# ⚠ CE CANAL A PERDU UN MOT DE PASSE POUR DE BON. Sur un poste natif, la première passe a généré le
# mot de passe forge de l'humain intégré, l'a POSÉ sur la forge, l'a écrit ici — et a écrit son
# marqueur « déjà posé ». Puis `60-deploy` a échoué au gate, `install.sh` est sorti en erreur, et le
# `trap` a détruit le fichier AVANT le banner final, qu'on n'atteint jamais sur ce chemin. Aux onze
# relances suivantes, le marqueur a fait sauter la pose. Le compte existait, avec un mot de passe
# que personne n'avait jamais vu : exactement « un compte d'administration où personne ne peut
# entrer », le défaut que ce canal existait pour fermer.
#
# La propriété « le secret ne survit pas à l'installation qui l'a produit » est juste. Ce qui était
# faux, c'est de la faire porter par un geste qui peut s'exécuter SANS que l'impression ait eu lieu.
# Détruire est la seconde moitié d'un geste dont imprimer est la première — les deux vivent
# ensemble, dans la sortie, quel que soit le code de retour.
#
# ⚠ ET SUR CTRL-C AUSSI. Un secret déjà posé sur la forge est perdu de la même manière si on
# l'efface sans le dire ; l'interruption ne rend pas le compte inexistant.
_CREDS_PRINTED=0
print_credentials_once() {
  [[ "$_CREDS_PRINTED" -eq 0 ]] || return 0
  [[ -n "${PROV_ANNOUNCE_FILE:-}" && -s "$PROV_ANNOUNCE_FILE" ]] || return 0
  _CREDS_PRINTED=1
  # ⚠ SANS `PROVISION_RUN` : ce drapeau arme la garde de sortie de la lib, qui réclame un verdict de
  # module. On n'en est pas un — on emprunte UNE mise en forme, et le poser ferait crier « MORT
  # avant de rendre son verdict » juste après un install réussi.
  # shellcheck source=fleet/deploy/lib/provision-lib.sh
  ( . "$SCRIPT_DIR/fleet/deploy/lib/provision-lib.sh" 2>/dev/null \
      && prov_print_credentials < "$PROV_ANNOUNCE_FILE" ) || cat "$PROV_ANNOUNCE_FILE"
}
trap 'print_credentials_once; [[ -n "${PROV_ANNOUNCE_FILE:-}" ]] && rm -f "$PROV_ANNOUNCE_FILE"' EXIT INT TERM

_apply_rc=0
"$PROVISION" apply "${PASSTHRU[@]}" || _apply_rc=$?

case "$_apply_rc" in
  0) ;;
  2)
    echo ""
    echo "  ${AMBER}Provisionnement APPLIQUÉ, avec DRIFT RÉSIDUEL.${N} Rien n'est cassé : un geste manque."
    echo "  Les lignes DRIFT ci-dessus le nomment, et « bash $0 --check » les relit à tout moment."
    ;;
  *)
    echo ""
    echo "  ${R}Provisionnement EN ÉCHEC (rc=$_apply_rc) — l'installation n'est PAS complète.${N}"
    echo "  Les lignes FAIL ci-dessus nomment ce qui a échoué ; « bash $0 --check » les relit."
    exit "$_apply_rc"
    ;;
esac

# ⚠ LA DERNIÈRE CHOSE QU'ON LIT EST L'INSTRUCTION QU'ON SUIT — donc elle doit être vraie SUR CE
# TERRAIN-CI. Ce bandeau disait « WSL : wsl --shutdown » sur une machine dédiée qui n'a pas de WSL,
# et « fleet_v2 start — ta fleet, sous ton uid » alors que le rail poste fait tourner la fleet sous
# l'humain de fleet (`22-fleet-human`), pas sous l'opérateur : GUARD B refuse l'uid du siège, qui
# est justement celui de l'opérateur sur une machine standard. Un opérateur qui suit la ligne 3 se
# fait refuser par un garde, sans savoir pourquoi.
#
# Mesuré le 2026-08-21 sur l'install à froid : les deux lignes fausses, imprimées côte à côte, en
# clôture d'un provisionnement par ailleurs juste.
if [[ "$SUBSTRATE" == "wsl" ]]; then
  _step1="${W}1.${N} WSL : si demandé, ${W}wsl --shutdown${N} (PowerShell),"
  _step1b="   rouvrir un ${W}NOUVEL${N} onglet, relancer cet install."
else
  _step1="${W}1.${N} Rien à redémarrer : ce terrain n'a pas de WSL."
  _step1b=""
fi
# Le lanceur nommé est celui qui MARCHE. Sur le rail poste la fleet appartient à l'humain de fleet ;
# l'opérateur la lance par `sudo -u`, et atteint son deck par le groupe.
if [[ "$RAIL" == "workstation" && -n "${FLEET_HUMAN:-}" ]]; then
  _step3="${W}3.${N} ${W}sudo -u $FLEET_HUMAN fleet_v2 start${N} — la fleet tourne sous"
  _step3b="     « $FLEET_HUMAN » ; toi tu l'atteins par le groupe ${W}fleet${N}."
elif [[ "$RAIL" == "workstation" ]]; then
  # Aucun humain nommé : la ligne 3 ne peut pas donner une commande qui marche, donc elle donne le
  # geste qui manque. Nommer une commande vouée au refus serait pire que de ne rien dire.
  _step3="${W}3.${N} Nomme un humain de fleet, sinon personne ne peut la lancer :"
  _step3b="     ${W}bash $0 --workstation --fleet-human <nom>${N}"
else
  _step3="${W}3.${N} ${W}fleet_v2 start${N} — ta fleet, sous ton uid."
  _step3b=""
fi

# ─── LE CARTOUCHE SE MESURE, IL NE SE COMPTE PLUS À LA MAIN ─────────────────────────────────────
#
# ⚠ TROIS DE SES LIGNES NE FERMAIENT PAS, et c'est structurel, pas une coquille. Chaque ligne
# portait sa propre bordure droite sous forme d'espaces comptés à l'œil, donc toute ligne écrite
# ailleurs que dans le littéral du cartouche l'oubliait — mesuré le 2026-08-23 sur un poste natif :
# `1.`, `3.` et la commande de `3.` sortaient sans leur `│`.
#
# ⚠ ET UNE D'ELLES NE POUVAIT PAS ÊTRE COMPTÉE. `bash $0 --workstation --fleet-human <nom>` porte le
# chemin de l'installeur : sa longueur dépend d'où l'opérateur a déballé l'archive. Une largeur fixe
# ne peut pas la contenir — la boîte se dérive donc de son contenu, et un chemin long l'élargit au
# lieu de la percer.
#
# La largeur ignore les séquences ANSI : elles pèsent dans la chaîne et pas à l'écran, ce qui est
# exactement pourquoi l'alignement ne se lisait pas dans le diff.
_box_plain() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }
_box_pad() { # <texte> <largeur>
  local p n; p="$(_box_plain "$1")"; n=$(( $2 - ${#p} )); (( n < 0 )) && n=0
  printf '%s%*s' "$1" "$n" ''
}

# ─── L'ACCEPTATION, AVANT DE SE DÉCLARER FINI ───────────────────────────────────────────────────
#
# ⚠ LE BILAN DE MODULES NE DIT PAS CE QU'ON PEUT FAIRE. « 26 modules · 0 échec » signifie que chaque
# module est d'accord avec lui-même ; il a déjà été vert sur une forge que rien ne pouvait servir,
# sans identifiants affichés et sans humain de fleet. Les trois capacités qui font qu'une
# installation vaut quelque chose n'étaient mesurées par personne.
#
# ⚠ ELLE SE JOUE ICI ET PAS APRÈS COUP : le mot de passe de la forge n'existe que pendant cette
# passe — le `trap` ci-dessus détruit le fichier en sortant, et la forge n'en garde qu'un hash. Une
# recette lancée plus tard ne pourrait pas vérifier « je peux me connecter », seulement « le compte
# existe », qui est une autre question.
#
# Son verdict N'ÉCRASE PAS celui du provisionnement : les deux se cumulent, parce qu'ils ne mesurent
# pas la même chose. Un rail qui converge et ne sert à rien doit dire les deux.
if [[ "$RAIL" == "workstation" && "$DOCTOR_MODE" -eq 0 && -x "$SCRIPT_DIR/fleet/deploy/accept" ]]; then
  _accept_args=(--announce-file "${PROV_ANNOUNCE_FILE:-/dev/null}")
  [[ -n "${FLEET_HUMAN:-}" ]] && _accept_args+=(--fleet-human "$FLEET_HUMAN")
  # ⚠ SA PROPRE VARIABLE : `_apply_rc` a DÉJÀ été lu et tranché par le `case` bien plus haut — s'y
  # ranger ici ne changerait rien, et une acceptation qui échoue sans porter à conséquence est
  # exactement le défaut qu'elle existe pour fermer. Elle décide du code de sortie tout en bas.
  _accept_rc=0
  bash "$SCRIPT_DIR/fleet/deploy/accept" "${_accept_args[@]}" || _accept_rc=$?
fi

_box_title="       LCARS-FLEET v2 — PROVISIONING TERMINÉ"
_box_body=(
  "  Suite (les verdicts ci-dessus font foi) :"
  "  $_step1"
)
[[ -n "$_step1b" ]] && _box_body+=("  $_step1b")
_box_body+=("  ${W}2.${N} ${W}claude${N} → /login (geste d'identité, une fois).")
_box_body+=("  $_step3")
[[ -n "$_step3b" ]] && _box_body+=("  $_step3b")
_box_body+=("  Sonde à tout moment : ${W}bash install.sh --check${N}")

# 57 est le PLANCHER, pas la largeur : c'est celle qu'avait le cartouche, et rien ne gagne à ce
# qu'il rétrécisse selon le rail. Une ligne plus longue l'élargit, bordures comprises.
_box_w=57
for _l in "$_box_title" "${_box_body[@]}"; do
  _p="$(_box_plain "$_l")"; (( ${#_p} > _box_w )) && _box_w=${#_p}
done
_box_rule="$(printf '%*s' "$_box_w" '' | sed 's/ /─/g')"

printf '\n%s  ┌%s┐\n' "$CYAN" "$_box_rule"
printf '  │%s%s%s│\n' "$W" "$(_box_pad "$_box_title" "$_box_w")" "$CYAN"
printf '  ├%s┤\n' "$_box_rule"
for _l in "${_box_body[@]}"; do
  printf '  │%s%s%s│\n' "$N" "$(_box_pad "$_l" "$_box_w")" "$CYAN"
done
printf '  └%s┘%s\n' "$_box_rule" "$N"

# LES IDENTIFIANTS EN DERNIER, APRÈS le bloc « suite » : c'est la dernière chose à l'écran, donc la
# seule qu'on est sûr de ne pas avoir fait défiler. Le `trap` les imprimerait de toute façon en
# sortant — l'appel ici sert à les placer AVANT le code de sortie plutôt qu'après, sur le chemin
# nominal. Sur un chemin d'échec, le trap reste le seul à passer, et c'est tout l'objet.
print_credentials_once

# ⚠ LE CODE DE SORTIE PORTE L'ACCEPTATION, ET IL EST EN DERNIER PARCE QU'ELLE EST EN DERNIER. Les
# identifiants s'impriment quoi qu'il arrive : une capacité manquante ne doit pas les emporter avec
# elle — l'opérateur en a besoin PRÉCISÉMENT pour réparer.
exit "${_accept_rc:-0}"
