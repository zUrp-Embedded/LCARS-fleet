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
WITH_BENCH=0
declare -a PASSTHRU=()
declare -a DELEGATE_ARGS=()   # ce qui suit `--` : pour le delegue de la branche, verbatim

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|--doctor) DOCTOR_MODE=1; shift ;;
    --workstation)    RAIL=workstation; shift ;;
    --box)            RAIL=box; shift ;;
    --bench)          WITH_BENCH=1; shift ;;
    --repo)   REPO_URL="${2:?--repo attend une URL}"; shift 2 ;;
    --branch) BRANCH="${2:?--branch attend un nom}"; shift 2 ;;
    --env|--human|--only|--substrate) PASSTHRU+=("$1" "${2:?$1 attend une valeur}"); shift 2 ;;
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
  else
    say_miss "$PROV_DOCKER_WHY"
  fi
else
  # Mode standalone : le dépôt n'est pas encore là, donc la sonde partagée non plus. On se contente
  # du minimum honnête, et la vraie sonde tournera après le clone.
  command -v docker >/dev/null 2>&1 && { DOCKER_OK=1; say_ok "docker (sonde complète après le clone)"; } \
    || say_miss "docker — Docker Desktop côté Windows, ou le paquet docker.io"
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
SUBSTRATE="$(detect_substrate 2>/dev/null || { grep -qi microsoft /proc/version 2>/dev/null && echo wsl || echo linux; })"

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
  if [[ "$SUBSTRATE" != "wsl" ]]; then
    # Sur un Linux natif il n'y a rien à deviner : le poste est INTERDIT par le garde de cible du
    # provisionnement (il écrirait `/local` et `/home/private` sur la machine de quelqu'un). Une
    # seule option permise ⇒ pas de question, mais on le DIT.
    RAIL=box
    echo ""
    echo "  ${W}Linux natif${N} — une seule option est permise ici : la boîte."
    echo "  (le rail poste écrit dans /etc, /local et /home/private : il est réservé à WSL)"
  else
    # Les deux sont possibles. On demande, et la question dit ce que chaque branche PREND —
    # le coût est dans la question, pas après.
    cat <<EOF

  ${W}Tu es dans WSL2 avec docker — d'ici, les deux sont possibles.${N}

  ${BA}1)${N} ${W}TRAVAILLER SUR LCARS${N} — le code sur ce disque, éditable depuis Windows,
     la fleet tourne sous ton uid, le gate en 40 s.
     ${R}Ça prend${N} : sudo · /etc/wsl.conf possédé entier · un groupe système ·
     /local et /home/private · et il n'existe AUCUN désinstalleur.

  ${BA}2)${N} ${W}LE FAIRE TOURNER${N} — une boîte, et rien hors de ton clone et de docker :
     pas de paquet, pas d'utilisateur, pas de groupe, rien dans /etc ni /usr.
     ${R}Ça prend${N} : ~3 Go · ~15 min de build · deux ports · un volume qui survit.
     Pour tout défaire : reset, 30 s.

EOF
    ans=""
    { read -r -p "  ${G}1 ou 2 ?${N} " ans < /dev/tty; } 2>/dev/null || ans="__NO_TTY__"
    case "$ans" in
      1) RAIL=workstation ;;
      2) RAIL=box ;;
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
  # Ce rail escalade pour provisionner : sans sudo il ne peut rien faire, et le dire ici est plus
  # juste que de le dire a tout le monde.
  if [[ "$EUID" -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    echo ""
    echo "  ${R}sudo est absent, et ce rail en a besoin pour provisionner ce système.${N}"
    echo "  La boîte, elle, n'escalade que pour joindre le daemon :  bash $0 --box"
    exit 1
  fi
  [[ "$SUBSTRATE" == "wsl" ]] || {
    echo ""
    echo "  ${R}--workstation est réservé à WSL2.${N} Sur un Linux ordinaire, LCARS s'installe en boîte :"
    echo "    bash $0 --box"
    exit 1
  }
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
  if [[ -f /etc/wsl.conf ]] && ! grep -q "LCARS" /etc/wsl.conf 2>/dev/null; then
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
cat <<EOF

${AMBER}    ______________________________________________________
   /          ${BA}LCARS FLEET - FEDERATION DATABASE${N}           ${AMBER}\\
  |   ________   __________________________________________\\
  |  |  2026  |  | SOURCE: install.sh
  |  |________|  | SYSTEM: LCARS-FLEET v2 (Elixir/OTP)
  |   ________   | STATUS: INSTALLER — rail ${RAIL}
  |  | AGPL-3 |  |__________________________________________
  |  |________|  \\__________________________________________\\
  |                                                         /
   \\   ${W}"To boldly go where no code has gone before..."${AMBER}  /
    \\_____________________________________________________/${N}
EOF

if [[ "$RAIL" == "workstation" ]]; then
  cat <<EOF
${CYAN}  ┌─────────────────────────────────────────────────────────┐
  │${W}  RAIL POSTE — LCARS s'installe DANS ce système.${N}          ${CYAN}│
  │${N}  sudo · paquets · groupe fleet · /local · /home/private  ${CYAN}│
  │${N}  · /etc/wsl.conf. ${R}Aucun désinstalleur n'existe.${N}         ${CYAN}│
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
  │${N}  Pour tout défaire : ${W}./docker.sh reset${N} — 30 s.           ${CYAN}│
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
  if [[ "$DOCKER_OK" -eq 0 ]]; then
    echo ""
    echo "  ${R}$PROV_DOCKER_WHY${N}"
    [[ "${PROV_DOCKER_DENIED:-0}" == "1" ]] && \
      echo "  L'escalade a été tentée et refusée : « sudo -n » n'a pas abouti (mot de passe requis ?)."
    exit 1
  fi
  [[ -x "$SCRIPT_DIR/docker.sh" ]] || {
    echo "  ${R}docker.sh introuvable — ce rail exige le checkout complet.${N}"
    echo "  git clone $REPO_URL && cd LCARS-fleet && bash install.sh --box"
    exit 1
  }
  if [[ "$DOCTOR_MODE" -eq 1 ]]; then
    exec "$SCRIPT_DIR/docker.sh" doctor
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
    echo "    FORGE_BASE_URL=http://…    tu as déjà une forge  (« ./docker.sh forge-check »)"
    exit 1
  }
  echo ""
  echo "  ${W}build${N} puis ${W}up${N} — la sortie qui suit est celle de ./docker.sh"
  "$SCRIPT_DIR/docker.sh" build
  exec "$SCRIPT_DIR/docker.sh" up
fi

# ─── LA BRANCHE POSTE : escalade, source, puis le délégué de provisionnement ─
if [[ "$EUID" -ne 0 ]]; then
  echo ""
  echo "  ${W}[sudo]${N} Privilèges root requis — ton mot de passe peut être demandé."
  REEXEC_ARGS=(--workstation --repo "$REPO_URL" --branch "$BRANCH")
  [[ "$DOCTOR_MODE" -eq 1 ]] && REEXEC_ARGS+=(--check)
  # ⚠ `sudo` REMET L'ENVIRONNEMENT A ZERO (env_reset), ET C'EST LE TROISIEME PIEGE DE CETTE FAMILLE
  # MESURE SUR CETTE MACHINE. Les reglages de provisionnement posés AVANT l'escalade meurent en la
  # traversant : `PROV_COLOR=1 bash install.sh` colorisait le preflight puis rendait un
  # provisionnement blanc, sans que rien ne dise pourquoi. Les assignations en tete de commande
  # sont la forme que sudo laisse passer — on les nomme, une par une, plutot que d'ouvrir `-E`.
  REEXEC_ENV=()
  for _v in PROV_COLOR NO_COLOR PROV_VERBOSE PROV_DUMP_LINES; do
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

# ─── Déléguer TOUT au provisioning (l'autorité) ─────────────────────────────
if [[ "$DOCTOR_MODE" -eq 1 ]]; then
  exec "$PROVISION" doctor "${PASSTHRU[@]}"
fi
"$PROVISION" apply "${PASSTHRU[@]}"

cat <<EOF

${CYAN}  ┌─────────────────────────────────────────────────────────┐
  │${W}         LCARS-FLEET v2 — PROVISIONING TERMINÉ           ${CYAN}│
  ├─────────────────────────────────────────────────────────┤
  │${N}  Suite (les verdicts ci-dessus font foi) :               ${CYAN}│
  │${N}  ${W}1.${N} WSL : si demandé, ${W}wsl --shutdown${N} (PowerShell),      ${CYAN}│
  │${N}     rouvrir un ${W}NOUVEL${N} onglet, relancer cet install.      ${CYAN}│
  │${N}  ${W}2.${N} ${W}claude${N} → /login (geste d'identité, une fois).       ${CYAN}│
  │${N}  ${W}3.${N} ${W}fleet_v2 start${N} — ta fleet, sous ton uid.            ${CYAN}│
  │${N}  Sonde à tout moment : ${W}bash install.sh --check${N}          ${CYAN}│
  └─────────────────────────────────────────────────────────┘${N}
EOF
