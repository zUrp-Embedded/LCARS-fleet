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
#     install.sh — entrée publique, bootstrap SEULEMENT.
#     S'assure qu'un checkout source existe, puis délègue TOUT à
#     fleet/provisioning_v2/provision (apply idempotent, doctor = sonde).
#     Modèle 3 zones : SOURCE (ce checkout) → INSTALL (/local/fleet_v2, RO)
#     → STATE (~/.lcars per-humain). Le re-run est TOUJOURS sûr : pas de
#     sentinelle, l'état c'est le système, re-sondé à chaque passage.
#
# --- END HEADER ---

set -euo pipefail

AMBER=$'\033[38;5;214m'; CYAN=$'\033[0;36m'; W=$'\033[1;37m'
G=$'\033[1;32m'; R=$'\033[1;31m'; N=$'\033[0m'; BA=$'\033[1;38;5;214m'

# ─── Options ────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/lordzurp/LCARS-fleet.git"
BRANCH="main"
DOCTOR_MODE=0
declare -a PASSTHRU=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|--doctor) DOCTOR_MODE=1; shift ;;
    --repo)   REPO_URL="${2:?--repo attend une URL}"; shift 2 ;;
    --branch) BRANCH="${2:?--branch attend un nom}"; shift 2 ;;
    --env|--human|--only|--substrate) PASSTHRU+=("$1" "${2:?$1 attend une valeur}"); shift 2 ;;
    --help|-h)
      cat <<'EOF'
Usage: sudo bash install.sh [OPTIONS]

  --check | --doctor   sonde read-only (provision doctor) — rien n'est modifié
  --repo URL           repo source (défaut : lordzurp/LCARS-fleet) — mode standalone
  --branch NAME        branche (défaut : main)
  --env FILE | --human USER | --only MODULE | --substrate S
                       passés tels quels à `provision` (voir fleet/provisioning_v2/README.md)

Install : wget -O /tmp/install.sh https://raw.githubusercontent.com/lordzurp/LCARS-fleet/main/install.sh
          sudo bash /tmp/install.sh
EOF
      exit 0 ;;
    *) echo "Option inconnue : $1 — --help" >&2; exit 1 ;;
  esac
done

# ─── Préflight (avant toute mutation, messages actionnables) ────────────────
preflight_ok=1
check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    echo "  ${G}[ok]${N} $1"
  else
    echo "  ${R}[MANQUE]${N} $1 — $2"
    preflight_ok=0
  fi
}
echo ""
echo "  ${W}Préflight${N}"
check_cmd git  "apt install git"
check_cmd curl "apt install curl"
[[ "$EUID" -ne 0 ]] && check_cmd sudo "requis pour le setup système"
if [[ "$preflight_ok" -eq 0 ]]; then
  echo ""
  echo "  ${R}Prérequis manquants — installe-les d'abord.${N}"
  exit 1
fi

# ─── Refus curl|bash (un installeur se lit avant de s'exécuter) ─────────────
if [[ ! -f "${BASH_SOURCE[0]:-}" ]]; then
  echo ""
  echo "  ${R}ERREUR : install.sh doit être exécuté depuis un fichier, pas pipé depuis stdin.${N}"
  echo "  Télécharge d'abord :"
  echo "    wget -O /tmp/install.sh https://raw.githubusercontent.com/lordzurp/LCARS-fleet/main/install.sh"
  echo "    sudo bash /tmp/install.sh"
  exit 1
fi

# ─── Bannière + consentement + escalade sudo ────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
  cat <<EOF

${AMBER}    ______________________________________________________
   /          ${BA}LCARS FLEET - FEDERATION DATABASE${N}           ${AMBER}\\
  |   ________   __________________________________________\\
  |  |  2026  |  | SOURCE: install.sh
  |  |________|  | SYSTEM: LCARS-FLEET v2 (Elixir/OTP)
  |   ________   | STATUS: INSTALLER
  |  | AGPL-3 |  |__________________________________________
  |  |________|  \\__________________________________________\\
  |                                                         /
   \\   ${W}"To boldly go where no code has gone before..."${AMBER}  /
    \\_____________________________________________________/${N}

${CYAN}  ┌─────────────────────────────────────────────────────────┐
  │${W}  Requiert sudo${N} — paquets, groupe fleet, /local,          ${CYAN}│
  │${N}  /home/private, et (WSL) verrouillage C: via wsl.conf.   ${CYAN}│
  │${N}  Idempotent : relancer est toujours sûr ; « --check »    ${CYAN}│
  │${N}  sonde sans rien modifier.                                ${CYAN}│
  │${N}  Confinement : les pods tournent sous bwrap, la fleet    ${CYAN}│
  │${N}  sous TON uid. Pire cas = nuke + re-provision (minutes). ${CYAN}│
  └─────────────────────────────────────────────────────────┘${N}

  ${G}    ▶  Entrée pour continuer${N}  /  ${R}Ctrl+C pour annuler${N}

EOF
  read -r _ < /dev/tty 2>/dev/null || echo "  [install] Pas de TTY — continue automatiquement."
  echo ""
  echo "  ${W}[sudo]${N} Privilèges root requis — ton mot de passe peut être demandé."
  REEXEC_ARGS=(--repo "$REPO_URL" --branch "$BRANCH")
  [[ "$DOCTOR_MODE" -eq 1 ]] && REEXEC_ARGS+=(--check)
  exec sudo bash "$(readlink -f "$0")" "${REEXEC_ARGS[@]}" "${PASSTHRU[@]}"
fi
# À partir d'ici : root, SUDO_USER = l'humain.

# ─── Trouver (ou poser) la SOURCE ───────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION="$SCRIPT_DIR/fleet/provisioning_v2/provision"

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
  PROVISION="$SRC_DIR/fleet/provisioning_v2/provision"
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
  │${N}     rouvrir un NOUVEL onglet, relancer cet install.      ${CYAN}│
  │${N}  ${W}2.${N} ${W}claude${N} → /login (geste d'identité, une fois).       ${CYAN}│
  │${N}  ${W}3.${N} ${W}fleet_v2 start${N} — ta fleet, sous ton uid.            ${CYAN}│
  │${N}  Sonde à tout moment : ${W}bash install.sh --check${N}          ${CYAN}│
  └─────────────────────────────────────────────────────────┘${N}
EOF
