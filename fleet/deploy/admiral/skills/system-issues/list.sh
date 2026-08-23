#!/usr/bin/env bash
# SOURCE: fleet/deploy/admiral/skills/system-issues/list.sh
# AUTHOR: bob
# STARDATE: 2026-08-19
# STATUS: PROTO-V2 — la boite de reception d'admiral (05 §7, chantier admiral)
#
# DEUX LECTURES, RIEN D'AUTRE : les issues error_system du depot ops, et les PR ouvertes vers la
# branche protegee. Ce script LISTE — il n'approuve rien, ne ferme rien, ne pose aucun label.
# La signature d'une PR d'outillage est un clic d'admin sur la forge, jamais un geste d'agent.
#
# ⚠ PAS de filtre `lcars-awaits-toolchain` ici : ce verrou vit sur les issues des WORK-ITEMS,
# dans les depots PROJET — le chercher sur le depot ops rendrait toujours rien (05 §7, corrige).

set -euo pipefail

FORGE_URL="${LCARS_FORGE_URL:-$(cat /home/lcars/tokens/forge.url 2>/dev/null || true)}"
# ⚠ LE JETON SYSTEME, PAS LE MASTER, ET C'EST UNE CORRECTION DE PRIVILEGE. Ce script ne fait que
# DEUX LECTURES sur un depot PUBLIC — mesure du 2026-08-23 sur une forge vivante : `fleet/lcars` est
# `private=false, internal=false`, et ses deux points d'entree (`issues`, `pulls`) repondent 200 en
# ANONYME. Aucune de ces lectures n'est site-admin.
#
# Il tenait le master parce qu'il etait la, pas parce que son geste l'exige — et le tenir imposait
# que le fichier reste lisible par un humain, ce qui est exactement l'ACL qu'on retire. Le compte
# systeme est l'identite juste : c'est avec lui que la boite lit sa forge. Donner un site-admin a
# une lecture serait lui accorder un pouvoir dont elle n'a aucun usage — meme argument, et meme
# formulation, que `cmd_install` dans `forge-gestures.sh`.
PRIVATE_DIR="${LCARS_PRIVATE_DIR:-/home/private}"
SYSTEM_ACCOUNT="${LCARS_SYSTEM_ACCOUNT:-${PROV_SYSTEM_ACCOUNT:-system_starfleet}}"
TOKEN_FILE="${LCARS_FORGE_TOKEN_FILE:-$PRIVATE_DIR/$SYSTEM_ACCOUNT.gitea_token}"
OPS_REPO="${LCARS_OPS_REPO:-fleet/lcars}"
# Nom GELE, autorite `Fleet.Toolchain.branch/0`, recopie tenue par le contrat
# `toolchain.branch_single_source`. Reglable a moitie, il faisait relever une boite aux lettres
# pendant que les demandes atterrissaient dans une autre.
BRANCH="tool_request"

[[ -n "$FORGE_URL" ]] || { echo "system-issues: URL de forge inconnue (LCARS_FORGE_URL ou tokens/forge.url)" >&2; exit 1; }
[[ -r "$TOKEN_FILE" ]] || { echo "system-issues: jeton systeme illisible ($TOKEN_FILE) — « provision apply » le minte, et il est lisible par le groupe fleet" >&2; exit 1; }

auth=(-H "Authorization: token $(tr -d '[:space:]' < "$TOKEN_FILE")")
api="$FORGE_URL/api/v1"

echo "═══ Boite de reception sysadmin — $OPS_REPO ═══"
echo
echo "── Issues error_system (ouvertes) ──"
curl -sSf -m 15 "${auth[@]}" "$api/repos/$OPS_REPO/issues?state=open&labels=error_system&type=issues&limit=50" \
  | jq -r '.[] | "#\(.number)  [\(.created_at[:10])]  \(.title)"' \
  || echo "(lecture impossible — forge down ?)"
echo
echo "── PR d'outillage en attente (vers $BRANCH) ──"
curl -sSf -m 15 "${auth[@]}" "$api/repos/$OPS_REPO/pulls?state=open&limit=50" \
  | jq -r --arg b "$BRANCH" '.[] | select(.base.ref == $b) | "!\(.number)  [\(.created_at[:10])]  \(.title)"' \
  || echo "(lecture impossible — forge down ?)"
echo
echo "(signature d'une PR : sur la forge — approve, l'auto-merge fait le reste ; detail : chaque ticket)"
