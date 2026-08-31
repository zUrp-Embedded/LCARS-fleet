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
#                       (/opt/lcars/runtime, RO) → STATE (~/.lcars per-humain).
#       --box           LCARS tourne dans un conteneur. Rien hors de ton
#                       clone et de docker.
#       --bench         fournit les annexes (forge jetable, runner CI, humain de
#                       démonstration) au lieu d'exiger que tu les aies déjà.
#                       L'humain EST une annexe : un déploiement de travail n'en
#                       sème aucun, les personnes s'inscrivent sur la forge.
#       --check         sonde read-only, rien n'est modifié.
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

# La version de CETTE porte. Elle s'affiche (`--version`) parce qu'une ligne de README doit pointer
# une URL PAR VERSION : servir depuis `HEAD` est le grief que `curl_bash_2026.md` nomme « gratuit à
# corriger », et une porte qui ne sait pas dire laquelle elle est ne peut pas être rapportée.
LCARS_DOOR_VERSION="2026-08-31"

main() {

if [[ -n "${NO_COLOR:-}" ]] || [[ "${PROV_COLOR:-}" == "0" ]] \
   || { [[ -z "${PROV_COLOR:-}" ]] && [[ ! -t 1 ]]; }; then
  AMBER=''; CYAN=''; W=''; G=''; R=''; N=''; BA=''
  LCARS_COLOR_HINT=1
else
  AMBER=$'\033[38;5;214m'; CYAN=$'\033[0;36m'; W=$'\033[1;37m'
  G=$'\033[1;32m'; R=$'\033[1;31m'; N=$'\033[0m'; BA=$'\033[1;38;5;214m'
fi

# ─── LA PORTE REFUSE ROOT ───────────────────────────────────────────────────
#
# ⚠ `curl | sudo bash` EST LE PIRE MOTIF QUI SOIT, et le refuser par construction vaut mieux que le
# déconseiller. Le sudo est demandé par le délégué du rail poste, à SON début, après la validation —
# jamais ici, où personne n'a encore rien choisi.
if [[ "$EUID" -eq 0 ]]; then
  echo ""
  echo "  ${R}Cette porte ne se lance pas en root.${N}"
  echo "  Elle mesure, elle propose, elle délègue — rien de tout cela n'a besoin de privilèges."
  echo "  Le rail poste demandera sudo lui-même, une fois, quand tu auras choisi :"
  echo "    bash $0 --workstation"
  exit 1
fi

# ⚠ `${BASH_SOURCE[0]}` EST NON LIÉ QUAND BASH LIT SUR STDIN, et c'est le cas NOMINAL du geste voulu
# (`curl … | bash`). Le repli `:-$0` tient sous `set -u` ; ce qui suit distingue les deux mondes :
#   · lancée depuis un fichier  → `SCRIPT_DIR` est le clone, le préflight y vit
#   · lancée depuis un flux     → il n'y a pas de clone, donc on en fait un (branche standalone)
#
# ⚠ ET LE REFUS DE STDIN A DISPARU (⚖ user 2026-08-31 : « c'est une question technique, pas un choix
# dogmatique »). Il n'achetait que deux des cinq griefs du pipe, et les deux ont un meilleur remède :
# la troncature par `{ main "$@"; }` en dernière ligne — mesuré, 0 fuite sur 162 troncatures contre
# 67 pour la forme sans `main` — et la localisation par cette branche-ci.
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR=""
fi

# ⚠ `fleet_human_name` A DISPARU D'ICI (⚖ user 2026-08-30). Elle allait demander à
# `forge-gestures.sh` le nom du compte que la recette sèmerait, pour que le bandeau et l'étape 3 le
# nomment. Le rail ne sème plus d'humain : il n'y a plus de nom à demander, et en nommer un serait
# faire taper à l'opérateur une commande qui échoue.

REPO_URL="https://github.com/lordzurp/LCARS-fleet.git"
BRANCH="main"
DOCTOR_MODE=0
RAIL=""              # workstation | box — VIDE tant que personne n'a choisi
FORCED_SUBSTRATE=""  # posé par --substrate : vaut pour la porte ET pour le rail
WITH_BENCH=0
# ⚠ `CONSENTED` A DISPARU D'ICI, ET SON DRAPEAU EST REFUSÉ PLUS BAS. Il valait « la 2ᵉ instance
# saute l'accueil et la pause » — une notion qui n'existe QUE si la porte se rejoue elle-même sous
# sudo. Elle ne le fait plus : le rail poste a son propre script, et l'escalade de celui-là n'a rien
# à sauter puisqu'il n'a ni accueil ni pause.
declare -a PASSTHRU=()
declare -a DELEGATE_ARGS=()   # ce qui suit `--` : pour le delegue de la branche, verbatim

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|--doctor) DOCTOR_MODE=1; shift ;;
    --workstation)    RAIL=workstation; shift ;;
    --box)            RAIL=box; shift ;;
    --bench)          WITH_BENCH=1; shift ;;
    # ⚠ REFUSE, PAS IGNORE. Un drapeau retire doit RATER : accepte et sans effet, il ferait
    # croire a un geste qui ne se produit plus. Meme regle que `--fleet-human`, meme verrou.
    --consented) echo "  --consented est retire : la porte ne se rejoue plus sous sudo." >&2
                 echo "  Le rail poste vit dans fleet/deploy/workstation, et son escalade n'a rien a sauter." >&2
                 exit 1 ;;
    --repo)   REPO_URL="${2:?--repo attend une URL}"; shift 2 ;;
    --branch) BRANCH="${2:?--branch attend un nom}"; shift 2 ;;
    --substrate) FORCED_SUBSTRATE="${2:?--substrate attend une valeur}"
                 PASSTHRU+=("$1" "$2"); shift 2 ;;
    # ports et nom d'instance : validés par `provision`, jamais ici
    --port-forge|--port-deck) PASSTHRU+=("$1" "${2:?$1 attend un port}"); shift 2 ;;
    --forge-project)          PASSTHRU+=("$1" "${2:?$1 attend un nom}"); shift 2 ;;
    --env|--human|--only) PASSTHRU+=("$1" "${2:?$1 attend une valeur}"); shift 2 ;;
    --) shift; DELEGATE_ARGS=("$@"); break ;;
    --version)
      # ⚠ ELLE DOIT MARCHER PIPÉE, DONC SANS LIRE SON PROPRE FICHIER. C'est tout l'intérêt : celui
      # qui rapporte un problème sur une porte qu'il a pipée doit pouvoir dire LAQUELLE.
      echo "$LCARS_DOOR_VERSION"; exit 0 ;;
    --help|-h)
      # Pipée, `${BASH_SOURCE[0]}` est non lié : l'aide se lit dans le fichier quand il y en a un,
      # et se réduit à l'essentiel sinon. Une aide qui exige un fichier est une porte fermée.
      if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
        sed -n '/^#     install.sh — LA porte/,/^#     système/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,5\}//'
      else
        echo "install.sh $LCARS_DOOR_VERSION — LA porte d'entrée."
        echo "  --workstation | --box   le rail · --bench  les annexes · --check  sonde read-only"
        echo "  --port-forge N | --port-deck N | --forge-project N | --substrate S"
      fi
      exit 0 ;;
    *) echo "Option inconnue : $1 — --help" >&2; exit 1 ;;
  esac
done

# ─── PRÉFLIGHT — UNE SEULE MESURE, ET C'EST CELLE DU PROVISIONNEMENT ────────
#
# ⚠ CETTE PORTE MESURAIT ELLE-MÊME, et c'est la duplication que le canon proscrit nommément (« le
# préflight dupliqué entre la porte et ce qui vit dans deploy/ : une seule mesure »). Deux sondes du
# même fait dérivent — et celle qu'on ne relit pas est celle qui ment le jour où l'autre change.
#
# Le module `00-preflight` porte désormais les deux rails. Il parle deux fois : en lignes pour un
# humain, et en faits `nom=valeur` (`p_fact`) dans `PROV_FACTS_FILE` pour qui doit DÉCIDER. La porte
# est ce « qui » : elle ne mesure plus rien, elle lit.
#
# ⚠ `doctor`, PAS `apply`, ET SANS SUDO : `doctor` est read-only, `NEEDS: root` n'est contrôlé qu'à
# l'apply (`provision`, `run_module`). La porte n'a pas de sudo et n'en aura pas — c'est le rail qui
# escalade, à son début.
preflight_ok=1
say_ok()   { echo "  ${G}[ok]${N} $1"; return 0; }
say_miss() { echo "  ${R}[MANQUE]${N} $1"; preflight_ok=0; }

PROVISION="$SCRIPT_DIR/fleet/deploy/provision"
FACTS_FILE=""
fait() { # fait <nom> — la valeur mesurée, vide si le fait n'a pas été posé
  [[ -n "$FACTS_FILE" ]] || return 0
  sed -n "s/^$1=//p" "$FACTS_FILE" 2>/dev/null | tail -1
}

# ⚠ UN DRAPEAU INVALIDE SE REFUSE AU PARSING, PAS APRÈS UNE MESURE. `provision` valide aussi son
# `--substrate` et rendrait le même refus — mais dix secondes plus tard, noyé dans un rapport, sur
# une machine qu'on aura sondée pour rien. Ce que l'opérateur a MAL TAPÉ ne demande aucune mesure.
case "${FORCED_SUBSTRATE:-wsl}" in
  wsl|docker|linux) ;;
  *) echo ""; echo "  ${R}--substrate $FORCED_SUBSTRATE : inconnu (wsl|docker|linux).${N}"; exit 1 ;;
esac

echo ""
echo "  ${W}Préflight${N}"

if [[ ! -x "$PROVISION" ]]; then
  # La porte seule (`wget install.sh` sans le dépôt) : le préflight vit dans le clone, donc la
  # source doit venir avant lui. Ce chemin est le flux « standalone » — il se traite à sa place,
  # dans l'accueil, pas ici en devinant ce que la machine vaut.
  echo "  ${R}Ce script est seul : le préflight vit dans le dépôt, et il n'est pas là.${N}"
  echo "  Clone d'abord, puis relance depuis le clone :"
  echo "    git clone $REPO_URL && bash LCARS-fleet/install.sh"
  exit 1
fi

FACTS_FILE="$(mktemp "${TMPDIR:-/tmp}/lcars-facts.XXXXXX")" || FACTS_FILE=""
trap '[[ -n "${FACTS_FILE:-}" ]] && rm -f "$FACTS_FILE"' EXIT

# La sortie du module est CAPTURÉE : la porte rend son propre préflight, à partir des faits. Le
# rapport brut reste disponible pour qui le demande — il n'est pas jeté, il n'est pas imposé.
# ⚠ `--substrate` EST UNE OPTION DU RUNNER, PAS UNE VARIABLE : `provision` pose lui-même
# `PROV_SUBSTRATE` depuis son option (`provision:169`), donc une variable passée en environnement
# est écrasée sans un mot. Le drapeau de la porte se traduit en drapeau du runner — c'est l'idiome
# du reste de ce fichier (`PASSTHRU`), et c'est aussi ce qui donne la validation gratuitement.
remesurer() { # rejoue le préflight et recharge les faits — la SEULE façon de re-mesurer ici
  # ⚠ ET C'EST POURQUOI CETTE PORTE N'A PLUS DE SONDE À ELLE. Elle en avait une, et après une
  # escalade ou une pose de paquets elle la rejouait — donc deux sondes du même fait, à deux
  # instants, avec deux façons de conclure. Rejouer LE module garde la mesure unique dans le temps
  # aussi, pas seulement dans l'espace.
  : > "$FACTS_FILE"
  PREFLIGHT_OUT="$(env PROV_FACTS_FILE="$FACTS_FILE" \
    "$PROVISION" doctor --only 00-preflight ${FORCED_SUBSTRATE:+--substrate "$FORCED_SUBSTRATE"} 2>&1)" || true
}
remesurer

for t in git curl; do
  if [[ "$(fait "$t")" == "oui" ]]; then say_ok "$t"; else say_miss "$t — apt install $t"; fi
done

DOCKER_OK=0
case "$(fait docker)" in
  oui)    DOCKER_OK=1; say_ok "docker répond ($(fait docker_bin))" ;;
  refuse) # Même fait, deux conclusions : le poste escalade et s'en moque, la boîte tourne sous
          # l'humain et ne peut pas travailler. La branche tranche, pas le préflight.
          echo "  ${W}[à voir]${N} $(fait docker_why)" ;;
  absent) if [[ "$(fait consent)" == "env" || "$(fait consent)" == "fichier" ]] \
             && [[ "$(fait substrat)" == "linux" && "${RAIL:-}" != "box" ]]; then
            echo "  ${W}[à voir]${N} docker absent — le rail POSTE le posera (docker-ce, dépôt upstream download.docker.com)"
            [[ -n "$RAIL" ]] || echo "           la BOÎTE, elle, exige un daemon DÉJÀ debout : elle n'installe rien (loi 5)."
          elif [[ "$RAIL" == "box" ]]; then
            say_miss "$(fait docker_why)"
            echo "           La boîte n'installe pas docker (loi 5) : pose-le comme tu l'entends,"
            echo "           ou donne cette machine au rail poste — sudo LCARS_ALLOW_ANY_HOST=1 bash $0 --workstation"
          else
            say_miss "$(fait docker_why)"
          fi ;;
  *)      say_miss "le préflight n'a pas rendu de fait « docker » — provision doctor a-t-il tourné ?" ;;
esac

if [[ "$preflight_ok" -eq 0 ]]; then
  echo ""
  echo "  ${R}Prérequis manquants — rien n'a été fait. Comble-les et relance.${N}"
  echo "  Le rapport complet du préflight :"
  printf '%s\n' "$PREFLIGHT_OUT" | sed 's/^/    /'
  exit 1
fi

# ─── LE SUBSTRAT SE LIT, IL NE SE REDÉTECTE PAS ─────────────────────────────
# `--substrate` a été passé au module ci-dessus : ce qu'il rend EST la réponse, forcée ou mesurée.
# Une seconde détection ici rouvrirait la divergence que ce bloc vient de fermer.
SUBSTRATE="$(fait substrat)"
[[ -n "$SUBSTRATE" ]] || SUBSTRATE="${FORCED_SUBSTRATE:-linux}"

docker_installable_here() {   # 0 si le rail POSTE peut poser docker sur cette machine-ci
  [[ "${RAIL:-}" != "box" ]] || return 1
  [[ -n "${LCARS_ALLOW_ANY_HOST:-}" ]] || return 1
  [[ "$SUBSTRATE" == "linux" ]]
}
case "$SUBSTRATE" in
  wsl|docker|linux) ;;
  *) echo ""; echo "  ${R}--substrate $SUBSTRATE : inconnu (wsl|docker|linux).${N}"; exit 1 ;;
esac

if [[ "$SUBSTRATE" == "wsl" ]] && ! unshare -Ur true 2>/dev/null; then
  echo ""
  echo "  ${R}Pas de namespaces utilisateur — les pods tournent sous bwrap, qui les exige.${N}"
  echo "  WSL1 ? passe en WSL2 :  wsl --set-version <distro> 2   (PowerShell)"
  exit 1
fi

# ─── LE CHOIX ───────────────────────────────────────────────────────────────
if [[ -z "$RAIL" ]]; then
  if [[ "$SUBSTRATE" != "wsl" ]] && [[ -z "${LCARS_ALLOW_ANY_HOST:-}" || "$SUBSTRATE" != "linux" ]]; then
    RAIL=box
    echo ""
    echo "  ${W}Linux natif${N} — une seule option est permise ici : la boîte."
    echo "  (le rail poste écrit dans /etc, /opt/lcars : il est réservé à WSL,"
    echo "   sauf machine DÉDIÉE déclarée telle : LCARS_ALLOW_ANY_HOST=1)"
  else
    if [[ "$SUBSTRATE" == "wsl" ]]; then
      _ici="${W}Tu es dans WSL2 avec docker — d'ici, les deux sont possibles.${N}"
      _prend="sudo · /etc/wsl.conf possédé entier · un groupe système ·
     /opt/lcars · la convergence ajoute et ne retire pas."
    else
      _ici="${W}Linux natif, machine déclarée DÉDIÉE (LCARS_ALLOW_ANY_HOST) — les deux sont possibles.${N}"
      _prend="sudo · un groupe système · /opt/lcars · des paquets ·
     la convergence ajoute et ne retire pas, et ici il n'y a pas de distro à jeter."
    fi
    if [[ "$DOCKER_OK" -eq 0 ]]; then
      _opt2_etat="${R}INDISPONIBLE ici${N} — docker n'est pas debout, et la boîte ne l'installe pas."
    else
      _opt2_etat="     Pour tout défaire : reset, 30 s."
    fi
    cat <<EOF

  $_ici

  ${BA}1)${N} ${W}TRAVAILLER SUR LCARS${N} — le code sur ce disque,
     la fleet tourne sous l'humain de fleet, le gate en 40 s.
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
# Après la question, jamais avant : la boîte ne prend pas la distro pour cible, et exiger une
# distro vierge plus haut refuserait une machine de travail qui voulait juste lancer une boîte.
if [[ "$RAIL" == "workstation" ]]; then
  # Le substrat AVANT sudo : hors WSL ce rail est refusé quoi qu'il arrive, et « sudo manque »
  # enverrait installer sudo pour se faire refuser ensuite. `LCARS_ALLOW_ANY_HOST` est lu ici ET
  # dans `00-preflight` — même drapeau, même sens, aux deux étages.
  if [[ "$SUBSTRATE" != "wsl" ]]; then
    if [[ "$SUBSTRATE" == "linux" && -n "${LCARS_ALLOW_ANY_HOST:-}" ]]; then
      echo ""
      echo "  ${AMBER}Linux natif, et tu l'as déclaré DÉDIÉ (LCARS_ALLOW_ANY_HOST).${N}"
      echo "  Ce rail va posséder cette machine : paquets, groupe système, /opt/lcars."
      echo "  « provision uninstall » retire ce que le journal a noté ; le reste, la convergence"
      echo "  ne sait pas le retirer. Et rien de LCARS n'est mesuré sur ce substrat."
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
  if [[ "$WITH_BENCH" -eq 1 ]]; then
    echo ""
    echo "  ${R}--bench n'a pas d'objet sur le rail poste.${N}"
    echo "  Il fournit les annexes à une BOÎTE ; ici la forge est montée par le provisionnement"
    echo "  lui-même (module 48-forge-host), dans le même cycle et sans drapeau."
    echo "  Tu voulais sans doute :  bash $0 --box --bench"
    exit 1
  fi

  # `fait sudo` vaut `root` quand on y est déjà, `oui` quand la commande est là, `absent` sinon —
  # trois états mesurés par le module, pas re-sondés ici.
  if [[ "$(fait sudo)" == "absent" ]]; then
    echo ""
    echo "  ${R}sudo est absent, et ce rail en a besoin pour provisionner ce système.${N}"
    echo "  La boîte, elle, ne modifie rien :  bash $0 --box"
    exit 1
  fi

  if [[ "$SUBSTRATE" == "wsl" ]] && [[ -f /etc/wsl.conf ]] && ! grep -q "LCARS" /etc/wsl.conf 2>/dev/null; then
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

_box_plain() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }
_box_pad() { # <texte> <largeur>
  local p n; p="$(_box_plain "$1")"; n=$(( $2 - ${#p} )); (( n < 0 )) && n=0
  printf '%s%*s' "$1" "$n" ''
}
# _box_emit [--rule] <titre> <ligne…> — `--rule` pose une règle sous le titre. Plancher : 57 colonnes.
_box_emit() {
  local _sep=0
  if [[ "${1:-}" == "--rule" ]]; then _sep=1; shift; fi
  local _title="$1"; shift
  local _w=57 _l _p _rule
  for _l in "$_title" "$@"; do _p="$(_box_plain "$_l")"; (( ${#_p} > _w )) && _w=${#_p}; done
  _rule="$(printf '%*s' "$_w" '' | sed 's/ /─/g')"
  printf '%s  ┌%s┐\n' "$CYAN" "$_rule"
  printf '  │%s%s%s│\n' "$W" "$(_box_pad "$_title" "$_w")" "$CYAN"
  if (( _sep )); then printf '  ├%s┤\n' "$_rule"; fi
  for _l in "$@"; do printf '  │%s%s%s│\n' "$N" "$(_box_pad "$_l" "$_w")" "$CYAN"; done
  printf '  └%s┘%s\n' "$_rule" "$N"
}

# ─── BANDEAU DE LA BRANCHE CHOISIE, ET LUI SEUL ─────────────────────────────
if true; then
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
  if [[ "$SUBSTRATE" == "wsl" ]]; then
    _banner_wslconf="  · /etc/wsl.conf, pris en entier."
    _banner_back="  sous WSL il est gratuit — « wsl --unregister »."
  else
    _banner_wslconf=""
    _banner_back="  snapshot ou image, et le rail n'en fournit aucun."
  fi
  # ⚠ CE RAIL NE CRÉE PLUS D'UTILISATEUR, ET LE BANDEAU NE PEUT PAS LE PROMETTRE (⚖ user
  # 2026-08-30). Il annonçait « Ce rail créera l'utilisateur « lcars » » — un compte de
  # DÉMONSTRATION que la recette semait sur tout déploiement, avec un mot de passe posé et annoncé.
  # Un déploiement de travail pose les AUTORITÉS ; les personnes s'inscrivent sur la forge, sous
  # leur nom, et le convergeur les matérialise. Un bandeau qui promet un compte que rien ne créera
  # est la première chose que l'opérateur lira, et la première qui sera fausse.
  echo ""
  echo "  ${AMBER}Ce rail ne crée aucun humain${N} — il pose les autorités : ton siège, l'admin"
  echo "  de la forge, les comptes de service. Les personnes s'inscrivent sur la forge ;"
  echo "  un propriétaire les ajoute à la team « humans » et le convergeur les matérialise"
  echo "  ici (uid libre au-dessus du siège, groupe fleet). Toi, tu restes le siège."
  _banner_body=("  sudo · paquets · groupe fleet · /opt/lcars")
  if [[ -n "$_banner_wslconf" ]]; then _banner_body+=("$_banner_wslconf"); fi
  _banner_body+=(
    "  ${R}Mode dev : la convergence AJOUTE, elle ne retire pas.${N}"
    "  Revenir en arrière demande un point de restauration :"
    "$_banner_back"
    "  Idempotent : relancer est toujours sûr ; « --check »"
    "  sonde sans rien modifier."
    "  Confinement : les pods tournent sous bwrap, et la fleet"
    "  sous l'humain de fleet : le siège a sudo, ses pods aussi."
    "  Pire cas = nuke + re-provision (minutes)."
  )
  _box_emit "  RAIL POSTE — LCARS s'installe DANS ce système." "${_banner_body[@]}"
else
  _banner_body=(
    "  Pas de paquet, pas d'utilisateur, pas de groupe, rien"
    "  dans /etc ni /usr. ~3 Go d'image, ~15 min de build."
    "  Pour tout défaire : ${W}fleet/deploy/box reset${N} — 30 s."
  )
  if [[ -n "${PROV_DOCKER_SUDO:-}" ]]; then
    _banner_body+=(
      "  ${W}⚠ sudo sera demandé pour PARLER au daemon docker —${N}"
      "    sa socket appartient à root. Aucune modification."
    )
  fi
  if [[ "$WITH_BENCH" -eq 1 ]]; then
    _banner_body+=("  ${W}--bench : forge jetable + runner CI + humain de démo.${N}")
  else
    _banner_body+=("  Il te faut une forge : FORGE_BASE_URL + un token.")
  fi
  _box_emit "  RAIL BOÎTE — rien hors de ton clone et de docker." "${_banner_body[@]}"
fi

echo ""
echo "  ${G}    ▶  Entrée pour continuer${N}  /  ${R}Ctrl+C pour annuler${N}"
echo ""

# Les accolades portent la redirection d'erreur, pas le `read` : sans elles, l'échec de
# `< /dev/tty` est signalé par le shell lui-même, avant la phrase calme qui l'explique.
{ read -r _ < /dev/tty; } 2>/dev/null || {
  echo "  [install] Pas de TTY — continue automatiquement (le rail est déjà choisi)."
  [[ -n "${LCARS_COLOR_HINT:-}" ]] && echo "  [install] Sortie non-terminal : couleurs coupées (PROV_COLOR=1 pour les garder dans le log)."
}
fi

# ─── LA BRANCHE BOÎTE : aucune escalade, on délègue à la porte docker ───────
if [[ "$RAIL" == "box" ]]; then
  # ⚠ NE PAS REMPLACER PAR UN `exec sudo` : ce rail bâtit une image sous l'uid de l'humain ; en root,
  # `git` lirait le clone en « dubious ownership » et l'image sortirait estampée `unknown`.
  # TTY exigé : sans terminal, l'invite pend jusqu'au timeout au lieu de refuser.
  # ⚠ CES TROIS BRANCHES LISAIENT `PROV_DOCKER_DENIED`, `PROV_DOCKER_WHY` ET APPELAIENT
  # `docker_endpoint` — trois choses que cette porte n'a plus, depuis qu'elle ne source plus la lib
  # de sonde. Elles étaient MORTES et aucun témoin ne l'a vu : elles exigent un TTY et un daemon qui
  # refuse, deux conditions qu'une suite ne reproduit pas. Le fait les remplace, et il vient du même
  # module que tout le reste.
  if [[ "$DOCKER_OK" -eq 0 && "$(fait docker)" == "refuse" ]] \
     && [[ "$(fait sudo)" != "absent" ]] && [[ -t 0 && -t 1 ]]; then
    echo ""
    echo "  ${W}[sudo]${N} La socket du daemon appartient à root — une invite, une fois."
    echo "         Elle amorce le cache que la sonde consomme commande par commande ;"
    echo "         ce rail ne monte JAMAIS en root, ton image reste bâtie sous ton compte."
    if sudo -v; then
      remesurer
      [[ "$(fait docker)" == "oui" ]] \
        && { DOCKER_OK=1; echo "  ${G}[ok]${N} docker répond ($(fait docker_bin))"; }
    fi
  fi
  if [[ "$DOCKER_OK" -eq 0 ]]; then
    echo ""
    echo "  ${R}$(fait docker_why)${N}"
    if [[ "$(fait docker)" == "refuse" ]]; then
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
  _box_reject=()
  _i=0
  while [[ "$_i" -lt "${#PASSTHRU[@]}" ]]; do
    case "${PASSTHRU[$_i]}" in
      --forge-project)
        if [[ "$WITH_BENCH" -eq 1 ]]; then
          # PRÉPOSÉ : le délégué lit en dernier-gagne, donc un `-- --project X` explicite l'emporte.
          DELEGATE_ARGS=(--project "${PASSTHRU[$((_i + 1))]}" ${DELEGATE_ARGS[@]+"${DELEGATE_ARGS[@]}"})
        else
          export LCARS_PROJECT="${PASSTHRU[$((_i + 1))]}"
        fi ;;
      --port-forge|--port-deck)
        if [[ "$WITH_BENCH" -eq 1 ]]; then
          _d="--forge-port"; [[ "${PASSTHRU[$_i]}" == "--port-deck" ]] && _d="--deck-port"
          DELEGATE_ARGS=("$_d" "${PASSTHRU[$((_i + 1))]}" ${DELEGATE_ARGS[@]+"${DELEGATE_ARGS[@]}"})
        else
          _box_reject+=("${PASSTHRU[$_i]} (les ports de la boite sont ceux du compose — ajoute --bench, ou edite le compose)")
        fi ;;
      --env|--human|--only)
        _box_reject+=("${PASSTHRU[$_i]} (drapeau du rail POSTE : il pilote « provision », que la boite n'appelle pas)") ;;
    esac
    _i=$((_i + 2))
  done
  if [[ "${#_box_reject[@]}" -gt 0 ]]; then
    echo ""
    echo "  ${R}Ce rail ne peut pas honorer ces options :${N}"
    printf '    %s\n' "${_box_reject[@]}"
    echo "  Rien n'a ete fait. Les accepter sans les lire serait pire que les refuser."
    exit 1
  fi

  BOX_IMAGE="${LCARS_IMAGE:-lcars-fleet:2}"
  for _i in "${!DELEGATE_ARGS[@]}"; do
    [[ "${DELEGATE_ARGS[$_i]}" == "--image" ]] && BOX_IMAGE="${DELEGATE_ARGS[$((_i + 1))]:-$BOX_IMAGE}"
  done
  if [[ "$WITH_BENCH" -ne 1 && -z "${FORGE_BASE_URL:-}" ]]; then
    echo ""
    echo "  ${R}FORGE_BASE_URL n'est pas posée — la boîte ne fabrique pas ta forge, elle la consomme.${N}"
    echo "  Deux voies :"
    echo "    ${W}--bench${N}                     LCARS monte une forge jetable, un runner et un humain de démo"
    echo "    FORGE_BASE_URL=http://…    tu as déjà une forge  (« fleet/deploy/box forge-check »)"
    exit 1
  fi

  if ! "$PROV_DOCKER_BIN" image inspect "$BOX_IMAGE" >/dev/null 2>&1; then
    echo ""
    echo "  ${W}$BOX_IMAGE${N} n'est pas là — je la construis (plusieurs minutes, une seule fois)."
    # ⚠ PAS DE `DOCKER_BIN=` ICI, ET C'EST DÉLIBÉRÉ : `box` sonde lui-même. Ne pas l'ajouter par
    # symétrie avec le `--bench` plus bas — celui-là est réel, `bench-up.sh` le lit.
    LCARS_IMAGE="$BOX_IMAGE" "$SCRIPT_DIR/fleet/deploy/box" build || {
      echo "  ${R}Le build a échoué — son verdict est le sien, rien n'a été déployé.${N}"
      exit 1
    }
  else
    say_ok "image $BOX_IMAGE présente — je la garde (elle ne se rebâtit pas toute seule)"
  fi

  if [[ "$WITH_BENCH" -eq 1 ]]; then
    echo ""
    echo "  ${W}--bench${N} : forge jetable + boîte + runner CI + humain de démo, en un geste."
    # Le délégué reçoit la résolution, il ne la refait pas : sans cette ligne `bench-up.sh` retombe
    # sur un `docker` nu et meurt là où la porte vient d'annoncer « docker répond ». Le shim voyage avec.
    export DOCKER_BIN="$PROV_DOCKER_BIN"
    exec "$SCRIPT_DIR/fleet/deploy/docker/bench/bench-up.sh" ${DELEGATE_ARGS[@]+"${DELEGATE_ARGS[@]}"}
  fi
  echo ""
  echo "  ${W}up${N} — la sortie qui suit est celle de fleet/deploy/box"
  exec "$SCRIPT_DIR/fleet/deploy/box" up
fi

# ─── LA BRANCHE POSTE : on délègue, comme pour la boîte ─────────────────────
#
# ⚠ CE BLOC FAISAIT CENT QUARANTE LIGNES, ET C'ÉTAIT LE RAIL ENTIER. Escalade sudo, clone sous
# l'humain, tranche paquets, `provision apply`, lecture du verdict, acceptation, identifiants,
# bandeau de fin : la porte ne choisissait pas un rail, elle en EXÉCUTAIT un. Le canon l'a tranché
# — « le rail poste sédimenté dans install.sh : il SORT, dans son propre script ».
#
# ⚠ ET LE RE-EXEC MEURT AVEC LUI. La porte se relançait sous sudo, donc elle devait se dire de
# sauter l'accueil et la pause qu'elle venait de jouer : `--consented`, un drapeau pour contourner
# un problème qu'elle s'était créé en voulant tout porter. `workstation` n'a ni accueil ni pause :
# son escalade n'a rien à sauter, et `EUID` — un FAIT — lui suffit à reconnaître son second passage.
#
# Le rail poste et le rail boîte sortent maintenant par la même forme : un `exec` vers un délégué du
# clone, et le code de retour est le sien.
WORKSTATION="$SCRIPT_DIR/fleet/deploy/workstation"
[[ -x "$WORKSTATION" ]] || {
  echo "  ${R}fleet/deploy/workstation introuvable — ce rail exige le checkout complet.${N}"
  echo "  git clone $REPO_URL && cd LCARS-fleet && bash install.sh --workstation"
  exit 1
}
if [[ "$DOCTOR_MODE" -eq 1 ]]; then
  exec "$WORKSTATION" doctor "${PASSTHRU[@]}"
fi
echo ""
echo "  ${W}up${N} — la sortie qui suit est celle de fleet/deploy/workstation"
exec "$WORKSTATION" up "${PASSTHRU[@]}"

}

# ⚠ `{ main "$@"; }` ET PAS `main "$@"` — LA DIFFERENCE EST MESUREE, PAS ESTHETIQUE.
#
# `curl | bash` fait lire le script AU FIL DE L'EAU : un flux coupe laisse bash executer ce qu'il a
# deja lu. Tout mettre dans des fonctions et n'appeler qu'a la fin ferme presque le trou — presque :
# une troncature qui tombe exactement sur `main` ou `main ` donne a bash une commande VALIDE sans
# arguments, et il APPELLE la fonction. Deux octets, et tout s'execute.
#
# L'accolade ferme ce reste : `{ main` non fermee est une erreur de syntaxe, jamais une commande.
# Banc a toutes les troncatures possibles (`work/…/chantier-porte-install-2026-08-30/bancs/`) :
#
#     sans main()      41 fuites / 97
#     main "$@"         2 vraies / 118
#     { main "$@"; }    0 vraies / 123
#
# `curl_bash_2026.md` ecrit « Resolu : la troncature (main(){…} en derniere ligne) ». C'est vrai a
# deux octets pres, et ces deux octets executent le script entier.
#
# RIEN NE DOIT SUIVRE CETTE LIGNE.
{ main "$@"; }
