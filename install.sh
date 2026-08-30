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

if [[ -n "${NO_COLOR:-}" ]] || [[ "${PROV_COLOR:-}" == "0" ]] \
   || { [[ -z "${PROV_COLOR:-}" ]] && [[ ! -t 1 ]]; }; then
  AMBER=''; CYAN=''; W=''; G=''; R=''; N=''; BA=''
  LCARS_COLOR_HINT=1
else
  AMBER=$'\033[38;5;214m'; CYAN=$'\033[0;36m'; W=$'\033[1;37m'
  G=$'\033[1;32m'; R=$'\033[1;31m'; N=$'\033[0m'; BA=$'\033[1;38;5;214m'
fi

if [[ ! -f "${BASH_SOURCE[0]:-}" ]]; then
  echo ""
  echo "  ${R}ERREUR : install.sh doit être exécuté depuis un fichier, pas pipé depuis stdin.${N}"
  echo "  Télécharge d'abord :"
  echo "    wget -O /tmp/install.sh https://raw.githubusercontent.com/lordzurp/LCARS-fleet/main/install.sh"
  echo "    sudo bash /tmp/install.sh --workstation   # ou --box"
  exit 1
fi

# `${BASH_SOURCE[0]}` est NON LIÉ quand bash lit sur stdin : sous `set -u`, cette ligne meurt avant
# la garde ci-dessus si elle remonte. Le repli `:-$0` et cette position sont la même précaution.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

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
CONSENTED=0          # posé par le re-exec sudo : la 2ᵉ instance saute l'accueil et la pause
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
    --substrate) FORCED_SUBSTRATE="${2:?--substrate attend une valeur}"
                 PASSTHRU+=("$1" "$2"); shift 2 ;;
    # ports et nom d'instance : validés par `provision`, jamais ici
    --port-forge|--port-deck) PASSTHRU+=("$1" "${2:?$1 attend un port}"); shift 2 ;;
    --forge-project)          PASSTHRU+=("$1" "${2:?$1 attend un nom}"); shift 2 ;;
    --env|--human|--only) PASSTHRU+=("$1" "${2:?$1 attend une valeur}"); shift 2 ;;
    --) shift; DELEGATE_ARGS=("$@"); break ;;
    --help|-h)
      sed -n '/^#     install.sh — LA porte/,/^#     système/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,5\}//'
      exit 0 ;;
    *) echo "Option inconnue : $1 — --help" >&2; exit 1 ;;
  esac
done

# ─── PRÉFLIGHT COMMUN — ce dont les DEUX branches ont besoin ────────────────
preflight_ok=1
# `return 0` : sans lui le code de sortie est celui d'`echo`, et un `A && say_ok || say_miss`
# bascule en MANQUE sur un prérequis présent. Même règle que `p_ok` (provision-lib.sh).
say_ok()   { echo "  ${G}[ok]${N} $1"; return 0; }
say_miss() { echo "  ${R}[MANQUE]${N} $1"; preflight_ok=0; }

docker_installable_here() {   # 0 si le rail POSTE peut poser docker sur cette machine-ci
  [[ "${RAIL:-}" != "box" ]] || return 1
  [[ -n "${LCARS_ALLOW_ANY_HOST:-}" ]] || return 1
  local s="${FORCED_SUBSTRATE:-$(detect_substrate 2>/dev/null || echo "")}"
  [[ "$s" == "linux" ]]
}

echo ""
echo "  ${W}Préflight${N}"
for t in git curl; do
  if command -v "$t" >/dev/null 2>&1; then
    say_ok "$t"
  else
    say_miss "$t — apt install $t"
  fi
done
DOCKER_OK=0
if [[ -r "$SCRIPT_DIR/fleet/deploy/lib/docker-endpoint.sh" ]]; then
  # shellcheck source=fleet/deploy/lib/docker-endpoint.sh
  . "$SCRIPT_DIR/fleet/deploy/lib/docker-endpoint.sh"
  if docker_endpoint; then
    DOCKER_OK=1; say_ok "docker répond ($PROV_DOCKER_BIN)"
  elif [[ "${PROV_DOCKER_DENIED:-0}" == "1" ]]; then
    # Pas de verdict ici : le poste escalade et s'en moque, la boîte tourne sous l'humain et ne
    # peut pas travailler. Même fait, deux conclusions — la branche tranche.
    echo "  ${W}[à voir]${N} $PROV_DOCKER_WHY"
  elif docker_installable_here; then
    if [[ -z "$RAIL" ]]; then
      echo "  ${W}[à voir]${N} docker absent — le rail POSTE le posera (docker-ce, dépôt upstream download.docker.com) ;"
      echo "           la BOÎTE, elle, exige un daemon DÉJÀ debout : elle n'installe rien (loi 5)."
    else
      echo "  ${W}[à voir]${N} docker absent — le rail le posera (docker-ce, dépôt upstream download.docker.com)"
    fi
  elif [[ "$RAIL" == "box" ]]; then
    say_miss "$PROV_DOCKER_WHY"
    echo "           La boîte n'installe pas docker (loi 5) : pose-le comme tu l'entends,"
    echo "           ou donne cette machine au rail poste — sudo LCARS_ALLOW_ANY_HOST=1 bash $0 --workstation"
  else
    say_miss "$PROV_DOCKER_WHY"
  fi
else
  if command -v docker >/dev/null 2>&1; then
    DOCKER_OK=1
    say_ok "docker (sonde complète après le clone)"
  else
    say_miss "docker — Docker Desktop côté Windows, ou un docker natif (le rail le pose sur Linux dédié)"
  fi
fi

if [[ "$preflight_ok" -eq 0 ]]; then
  echo ""
  echo "  ${R}Prérequis manquants — rien n'a été fait. Comble-les et relance.${N}"
  exit 1
fi

# ─── DÉTECTION : ce que la machine PERMET, jamais ce qu'elle VEUT ───────────
SUBSTRATE="${FORCED_SUBSTRATE:-$(detect_substrate 2>/dev/null || { grep -qi microsoft /proc/version 2>/dev/null && echo wsl || echo linux; })}"
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

  if [[ "$EUID" -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    echo ""
    echo "  ${R}sudo est absent, et ce rail en a besoin pour provisionner ce système.${N}"
    echo "  La boîte, elle, ne modifie rien :  bash $0 --box"
    exit 1
  fi

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

# ─── LA BRANCHE POSTE : escalade, source, puis le délégué de provisionnement ─
if [[ "$EUID" -ne 0 ]]; then
  echo ""
  echo "  ${W}[sudo]${N} Privilèges root requis — ton mot de passe peut être demandé."
  REEXEC_ARGS=(--workstation --repo "$REPO_URL" --branch "$BRANCH" --consented)
  [[ "$DOCTOR_MODE" -eq 1 ]] && REEXEC_ARGS+=(--check)
  # ⚠ `sudo` FAIT `env_reset` : tout réglage posé avant l'escalade meurt en la traversant. Cette
  # liste est le SEUL passage — une variable qui n'y figure pas est mangée en silence, et le geste
  # qu'elle commande ne produit rien. On les nomme une par une plutôt que d'ouvrir `-E`.
  REEXEC_ENV=()
  for _v in PROV_COLOR NO_COLOR PROV_VERBOSE PROV_DUMP_LINES LCARS_ALLOW_ANY_HOST PROV_FORGE_ADMIN_RESET; do
    [[ -n "${!_v:-}" ]] && REEXEC_ENV+=("$_v=${!_v}")
  done
  exec sudo "${REEXEC_ENV[@]}" bash "$(readlink -f "$0")" "${REEXEC_ARGS[@]}" "${PASSTHRU[@]}"
fi
# À partir d'ici : root, SUDO_USER = l'humain.

PROVISION="$SCRIPT_DIR/fleet/deploy/provision"

if [[ ! -x "$PROVISION" ]]; then
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

# ─── LES PAQUETS D'ABORD, SI C'EST LE RAIL QUI POSE DOCKER ──────────────────
if [[ "$RAIL" == "workstation" && "$DOCTOR_MODE" -eq 0 ]] \
   && ! command -v "${PROV_DOCKER_BIN:-docker}" >/dev/null 2>&1 \
   && docker_installable_here; then
  echo ""
  echo "  docker n'est pas là et c'est le rail qui le pose — je joue d'abord les paquets."
  "$PROVISION" apply "${PASSTHRU[@]}" --only 00-preflight --only 05-host-consent --only 10-packages \
    || echo "  ${W}la tranche paquets n'a pas tout convergé — 48-forge-host dira ce qui manque.${N}"
  # LA SONDE SE REJOUE : `docker_endpoint` a répondu « absent » il y a trente secondes, et
  # `PROV_DOCKER_BIN` porte encore cette réponse-là. Sans ce second passage, le build interrogerait
  # un chemin périmé sur une machine qui a désormais docker.
  docker_endpoint >/dev/null 2>&1 || true
fi

# ─── Déléguer TOUT au provisioning (l'autorité) ─────────────────────────────
if [[ "$DOCTOR_MODE" -eq 1 ]]; then
  exec "$PROVISION" doctor "${PASSTHRU[@]}"
fi
# `provision apply` rend 0 (convergé), 2 (appliqué, drift résiduel — rien n'est cassé) ou 1 (échec) :
# sous `set -e`, une ligne nue tuerait la porte sur 1 ET 2, sans un mot. Même lecture que
# `deploy/box` (`await_provision_verdict`) — deux portes qui en tirent deux verdicts, c'est un code
# de retour qui ne veut plus rien dire.
PROV_ANNOUNCE_FILE="$(mktemp "${TMPDIR:-/tmp}/lcars-creds.XXXXXX")" && chmod 0600 "$PROV_ANNOUNCE_FILE" || PROV_ANNOUNCE_FILE=""
export PROV_ANNOUNCE_FILE

# ⚠ IMPRIMER PUIS DÉTRUIRE, DANS LE MÊME GESTE ET SUR TOUS LES CHEMINS DE SORTIE (Ctrl-C compris).
# Un `rm` qui s'exécute sans l'impression perd POUR DE BON un secret déjà posé sur la forge : le
# compte existe, avec un mot de passe que personne n'a jamais vu.
_CREDS_PRINTED=0
print_credentials_once() {
  [[ "$_CREDS_PRINTED" -eq 0 ]] || return 0
  [[ -n "${PROV_ANNOUNCE_FILE:-}" && -s "$PROV_ANNOUNCE_FILE" ]] || return 0
  _CREDS_PRINTED=1
  # Sans `PROVISION_RUN` : il arme la garde de sortie de la lib, qui réclame un verdict de module.
  # On n'en est pas un — on emprunte une mise en forme, pas un contrat.
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

if [[ "$SUBSTRATE" == "wsl" ]]; then
  _step1="${W}1.${N} WSL : si demandé, ${W}wsl --shutdown${N} (PowerShell),"
  _step1b="   rouvrir un ${W}NOUVEL${N} onglet, relancer cet install."
else
  _step1="${W}1.${N} Rien à redémarrer : ce terrain n'a pas de WSL."
  _step1b=""
fi
if [[ "$RAIL" == "workstation" ]]; then
  # ⚠ AUCUN NOM ICI : ce rail n'en crée plus, et à cette seconde il n'y a peut-être encore personne.
  # Nommer un compte que l'opérateur n'a pas serait lui faire taper une commande qui échoue.
  _step3="${W}3.${N} ${W}sudo -u <ton humain> fleet_v2 start${N} — la fleet tourne sous un"
  _step3b="     humain de fleet ; toi tu l'atteins par le groupe ${W}fleet${N}. Personne encore ? Inscris-toi sur la forge, team « humans »."
else
  _step3="${W}3.${N} ${W}fleet_v2 start${N} — depuis la console de ton humain de"
  _step3b="     fleet (deck sur 20999) ; ssh entre en admiral, que GUARD B refuse."
fi

# ─── L'ACCEPTATION, AVANT DE SE DÉCLARER FINI ───────────────────────────────────────────────────
# ⚠ ELLE SE JOUE ICI ET PAS APRÈS COUP : le mot de passe de la forge n'existe que pendant cette
# passe — le `trap` détruit le fichier en sortant, et la forge n'en garde qu'un hash. Plus tard, on
# ne pourrait plus vérifier « je peux me connecter », seulement « le compte existe ».
if [[ "$RAIL" == "workstation" && "$DOCTOR_MODE" -eq 0 && -x "$SCRIPT_DIR/fleet/deploy/accept" ]]; then
  _accept_args=(--announce-file "${PROV_ANNOUNCE_FILE:-/dev/null}")
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

echo ""
_box_emit --rule "$_box_title" "${_box_body[@]}"

# Les identifiants en dernier : la dernière chose à l'écran est la seule qu'on est sûr de ne pas
# avoir fait défiler. Le `trap` les imprimerait de toute façon — cet appel les place avant le code
# de sortie sur le chemin nominal.
print_credentials_once

exit "${_accept_rc:-0}"
