#!/usr/bin/env bash
# SOURCE: fleet/bin/claude_probe.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-03
# STATUS: sonde du CONTRAT VENDOR — les drapeaux dont le launcher depend existent-ils encore ?
#
# ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────────────────────────
# `claude_launch.sh` construit sa ligne de commande avec une vingtaine de drapeaux mesures a des
# versions PRECISES du binaire vendor (2.1.88/177/183). Le binaire, lui, se met a jour tout seul.
# Le jour ou l'un de ces drapeaux est renomme ou retire, on l'apprend au PREMIER POD CASSE — un
# spawn qui echoue avec un message du vendor, plusieurs couches sous l'endroit ou la cause vit.
#
# Cette sonde pose la question a l'avance : `claude --help` nomme-t-il encore ce dont on depend ?
#
# ─── LA FRONTIERE, ET POURQUOI LA SONDE EST EN BASH ─────────────────────────────────────────────
# La frontiere vendor N1 EST le script `bin/` (CLAUDE.md). Une sonde ecrite en Elixir devrait
# CONNAITRE les drapeaux du vendor pour les verifier — elle importerait le savoir N1 dans du code
# N0, exactement ce que la frontiere existe pour empecher. La liste vit donc ici, a cote du seul
# fichier qui la consomme, et l'appelant n'apprend qu'un code de sortie.
#
# ─── CE QU'ELLE NE COUVRE PAS, ET C'EST LA MOITIE QUI FAIT LE PLUS MAL ──────────────────────────
# Le second contrat vendor est l'algo de SLUGIFICATION (`SeedStore.slugify`, gele bit-pour-bit
# contre la v2.1.183) : c'est lui qui permet de retrouver `~/.claude/projects/<slug>/<uuid>.jsonl`
# au resume. Un changement la-bas ne casse rien VISIBLEMENT — il fait pointer le resume vers un
# repertoire vide, donc un pod repart sans sa memoire au lieu d'echouer. Le sonder demanderait de
# LANCER une session et de regarder ou elle ecrit : trop cher pour un boot, et non fait ici.
# Nomme plutot que tu, parce qu'une sonde qui couvre la moitie visible d'un contrat laisse croire
# que l'autre moitie est couverte.
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

# Les drapeaux LOAD-BEARING : ceux dont l'absence casse un spawn ou un contrat de pod. Pas la
# liste exhaustive de ce que le launcher passe — un drapeau cosmetique qui disparait degrade,
# il ne ment pas. Chaque ligne ici doit avoir un consommateur dans claude_launch.sh.
# La liste est VERROUILLEE sur les drapeaux que `claude_launch.sh` passe reellement en argv (un
# bats l'epingle : ajouter un drapeau au launcher sans l'ajouter ici rend la sonde menteuse par
# omission — elle attesterait un contrat plus petit que celui dont on depend).
REQUIRED=(
  --system-prompt-file      # le SP du role ; sans lui le pod demarre SANS son mandat
  # ⚠ EXCEPTION DE DEBUG (2026-08-21) : le bras APPEND de l'A/B du SP de l'architect. Cette ligne
  # n'est PAS un choix — `claude_probe.bats:106` verrouille « tout drapeau passe en argv est ici ».
  # Elle part avec l'exception, dont le bloc vit dans `claude_launch.sh` juste avant l'`exec`.
  # Elle a aussi un metier propre en attendant : le `-file` n'a pas d'entree a lui dans `--help`
  # (il vit dans la notation a crochets, comme son voisin), donc c'est cette sonde qui attrapera la
  # version du vendor ou il disparait — plutot qu'un pod qui demarre sans mandat.
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
  --disable-slash-commands  # coupe la surface vendor (`/init` et les skills) pour un pod qui a un
                            # depot au cwd. LOAD-BEARING : cette surface est COMPILEE dans le
                            # binaire (mesure 2026-08-12), donc aucun montage ne la borne — ce
                            # drapeau est le seul levier. Sa disparition rendrait `/init` a des
                            # pods dont il ecraserait le CLAUDE.md du depot dans un format que
                            # l'extracteur de la fleet ne lit pas.
)

command -v "$CLAUDE_BIN" >/dev/null 2>&1 \
  || { echo "claude_probe: binaire vendor introuvable: $CLAUDE_BIN" >&2; exit 2; }

HELP="$("$CLAUDE_BIN" --help 2>&1)" \
  || { echo "claude_probe: '$CLAUDE_BIN --help' a echoue" >&2; exit 2; }

[[ -n "$HELP" ]] || { echo "claude_probe: '$CLAUDE_BIN --help' n'a rien rendu" >&2; exit 2; }

# LES CROCHETS DU VENDOR, ET POURQUOI ILS ONT FAIT MENTIR CETTE SONDE A SON PREMIER TIR.
# `--help` de la 2.1.220 ecrit `--system-prompt[-file]` — une notation qui factorise deux drapeaux
# en une ligne. Une recherche du token exact ne le trouve pas et declare le contrat rompu sur un
# drapeau parfaitement present : un FAUX POSITIF sur le drapeau le plus load-bearing de la liste,
# qui aurait envoye reparer un launcher intact. On normalise donc le help en retirant `[` et `]`
# AVANT de chercher — `--system-prompt[-file]` redevient `--system-prompt-file`, et la question
# posee est celle qu'on voulait poser.
HELP_FLAT="${HELP//[/}"
HELP_FLAT="${HELP_FLAT//]/}"

MISSING=()
for flag in "${REQUIRED[@]}"; do
  # Frontiere de token OBLIGATOIRE : chercher `--settings` en sous-chaine matcherait
  # `--setting-sources` et rendrait un vert menteur sur les deux drapeaux dont la confusion coute
  # le plus cher (le settings.json du pod contre ceux de l'humain qui fuiraient).
  printf '%s' "$HELP_FLAT" | grep -qE -- "(^|[[:space:]])${flag}([[:space:],=]|$)" || MISSING+=("$flag")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  VERSION="$("$CLAUDE_BIN" --version 2>/dev/null | head -1 || echo inconnue)"
  echo "claude_probe: CONTRAT VENDOR ROMPU (version $VERSION) — drapeaux absents de --help :" >&2
  printf '  %s\n' "${MISSING[@]}" >&2
  echo "claude_probe: un spawn echouera au premier pod ; corriger bin/claude_launch.sh" >&2
  exit 1
fi

echo "claude_probe: contrat vendor OK — ${#REQUIRED[@]} drapeaux presents"
