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
TOKEN_FILE="${LCARS_MASTER_TOKEN_FILE:-/home/private/forge-master.token}"
OPS_REPO="${LCARS_OPS_REPO:-fleet/lcars}"
# Nom GELE, autorite `Fleet.Toolchain.branch/0`, recopie tenue par le contrat
# `toolchain.branch_single_source`. Reglable a moitie, il faisait relever une boite aux lettres
# pendant que les demandes atterrissaient dans une autre.
BRANCH="tool_request"

[[ -n "$FORGE_URL" ]] || { echo "system-issues: URL de forge inconnue (LCARS_FORGE_URL ou tokens/forge.url)" >&2; exit 1; }
[[ -r "$TOKEN_FILE" ]] || { echo "system-issues: master token illisible ($TOKEN_FILE) — cette session peut-elle le lire ?" >&2; exit 1; }

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
