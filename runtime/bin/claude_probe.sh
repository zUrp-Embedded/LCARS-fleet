#!/usr/bin/env bash
# SOURCE: runtime/bin/claude_probe.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-03
# STATUS: sonde du CONTRAT VENDOR — les drapeaux dont le launcher depend existent-ils encore ?
#
# `claude_launch.sh` depend d'une vingtaine de drapeaux mesures a des versions PRECISES du binaire
# vendor, et le binaire se met a jour tout seul. Sans cette sonde, un drapeau renomme s'apprend au
# PREMIER POD CASSE, plusieurs couches sous l'endroit ou la cause vit.
#
# CE QU'ELLE NE COUVRE PAS : l'algo de SLUGIFICATION (`SeedStore.slugify`), l'autre contrat vendor.
# Un changement la-bas ne casse rien VISIBLEMENT — il fait pointer le resume vers un repertoire
# vide, donc un pod repart sans sa memoire au lieu d'echouer. Le sonder demanderait de LANCER une
# session : non fait ici, et nomme pour qu'on ne croie pas le contrat entierement couvert.
#
# USAGE : claude_probe.sh [--bin claude]
# EXIT  : 0 tous les drapeaux presents · 1 des drapeaux MANQUENT (nommes sur stderr)
#         2 le binaire vendor est introuvable ou ne repond pas a --help

set -euo pipefail

CLAUDE_BIN="${CLAUDE_BIN:-claude}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin) CLAUDE_BIN="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "claude_probe: option inconnue: $1" >&2; exit 1 ;;
  esac
done

# Les drapeaux LOAD-BEARING : ceux dont l'absence casse un spawn ou un contrat de pod, pas la liste
# exhaustive de ce que le launcher passe — un drapeau cosmetique qui disparait degrade, il ne ment pas.
REQUIRED=(
  --system-prompt-file      # le SP du role ; sans lui le pod demarre SANS son mandat
  --append-system-prompt-file
  --setting-sources         # d'ou viennent les settings ; sans lui, ceux de l'humain fuient
  --settings                # le settings.json compose du pod
  --mcp-config              # la socket MCP par-pod
  --strict-mcp-config       # interdit les serveurs MCP hors config — mur de perimetre
  --permission-mode         # allow/deny enforces ; sans lui, le defaut du vendor s'applique
  --allowedTools            # la scope du cap-profile
  --disallowedTools
  --model
  --effort
  --session-id              # l'identite de session, base du resume
  --resume
  --remote-control          # visibilite Desktop
  --disable-slash-commands  # coupe la surface vendor (`/init`, skills) d'un pod qui a un depot au cwd
)

command -v "$CLAUDE_BIN" >/dev/null 2>&1 \
  || { echo "claude_probe: binaire vendor introuvable: $CLAUDE_BIN" >&2; exit 2; }

HELP="$("$CLAUDE_BIN" --help 2>&1)" \
  || { echo "claude_probe: '$CLAUDE_BIN --help' a echoue" >&2; exit 2; }

[[ -n "$HELP" ]] || { echo "claude_probe: '$CLAUDE_BIN --help' n'a rien rendu" >&2; exit 2; }

# Le vendor factorise deux drapeaux en `--system-prompt[-file]` : on retire `[` et `]` AVANT de
# chercher, sinon le token exact est introuvable et le contrat declare rompu sur un drapeau present.
HELP_FLAT="${HELP//[/}"
HELP_FLAT="${HELP_FLAT//]/}"

MISSING=()
for flag in "${REQUIRED[@]}"; do
  grep -qE -- "(^|[[:space:]])${flag}([[:space:],=]|\$)" <<<"$HELP_FLAT" || MISSING+=("$flag")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  VERSION="$("$CLAUDE_BIN" --version 2>/dev/null | head -1 || echo inconnue)"
  echo "claude_probe: CONTRAT VENDOR ROMPU (version $VERSION) — drapeaux absents de --help :" >&2
  printf '  %s\n' "${MISSING[@]}" >&2
  echo "claude_probe: un spawn echouera au premier pod ; corriger bin/claude_launch.sh" >&2
  exit 1
fi

echo "claude_probe: contrat vendor OK — ${#REQUIRED[@]} drapeaux presents"
