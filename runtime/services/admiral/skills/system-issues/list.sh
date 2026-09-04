#!/usr/bin/env bash
# SOURCE: runtime/services/admiral/skills/system-issues/list.sh
# AUTHOR: bob
# STARDATE: 2026-08-19
# STATUS: PROTO-V2 — la boite de reception d'admiral
#
# DEUX LECTURES, RIEN D'AUTRE : les issues error_system du depot ops, et les PR ouvertes vers la
# branche protegee. Ce script LISTE — il n'approuve rien, ne ferme rien, ne pose aucun label.
# La signature d'une PR d'outillage est un clic d'admin sur la forge, jamais un geste d'agent.
#
# ⚠ PAS de filtre `lcars-awaits-toolchain` ici : ce verrou vit sur les issues des WORK-ITEMS,
# dans les depots PROJET — le chercher sur le depot ops rendrait toujours rien.

set -euo pipefail

FORGE_URL="${LCARS_FORGE_URL:-$(cat /home/lcars/tokens/forge.url 2>/dev/null || true)}"
# ⚠ LE JETON SYSTEME, PAS LE MASTER, ET C'EST UNE CORRECTION DE PRIVILEGE. Ce script ne fait que
# DEUX LECTURES sur un depot PUBLIC — mesure du 2026-08-23 sur une forge vivante : `fleet/lcars` est
# `private=false, internal=false`, et ses deux points d'entree (`issues`, `pulls`) repondent 200 en
# ANONYME. Aucune de ces lectures n'est site-admin.
#
# Tenir le master parce qu'il est la imposerait que son fichier reste lisible par un humain — l'ACL
# que la boite refuse. Le compte systeme est l'identite juste : c'est avec lui que la boite lit sa
# forge. Donner un site-admin a une lecture serait lui accorder un pouvoir dont elle n'a aucun usage
# — meme argument, et meme formulation, que `cmd_install` dans `forge-gestures.sh`.
#
# ─── ET IL NE LIT PAS LE JETON : IL LE DEMANDE ──────────────────────────────────────────────────
#
# Un fichier `0640 root:fleet` que le siege lirait par le groupe serait encore une PROJECTION de
# l'equipe `humans` de la forge, avec trente secondes de peremption — et un refus qui dirait « il
# est lisible par le groupe fleet » enverrait chercher une adhesion. La question se pose a
# `roles.sock` : le service la porte a la forge A L'INSTANT du geste.
SYSTEM_ACCOUNT="${LCARS_SYSTEM_ACCOUNT:-${PROV_SYSTEM_ACCOUNT:-system_starfleet}}"
AUTHORITY_ASK="${LCARS_AUTHORITY_ASK_BIN:-/usr/local/bin/lcars-authority-ask}"
OPS_REPO="${LCARS_OPS_REPO:-fleet/lcars}"
# Nom GELE, autorite `Fleet.Toolchain.branch/0`, recopie tenue par le contrat
# `toolchain.branch_single_source`. Reglable a moitie, il ferait relever une boite aux lettres
# pendant que les demandes atterrissent dans une autre.
BRANCH="tool_request"

[[ -n "$FORGE_URL" ]] || { echo "system-issues: URL de forge inconnue (LCARS_FORGE_URL ou tokens/forge.url)" >&2; exit 1; }
[[ -x "$AUTHORITY_ASK" ]] || { echo "system-issues: client d'autorite absent ($AUTHORITY_ASK) — « provision apply » le pose" >&2; exit 1; }

# La cause du refus est deja imprimee en francais par le client, sur stderr. La reformuler ici la
# remplacerait par une plus vague : ce script sait qu'il n'a pas de jeton, il ne sait pas pourquoi.
TOKEN="$("$AUTHORITY_ASK" "$SYSTEM_ACCOUNT")" \
  || { echo "system-issues: pas de jeton de forge (cause ci-dessus)" >&2; exit 1; }

api="$FORGE_URL/api/v1"

# ⚠ `-K -` ET PAS `-H` : un en-tete construit en ARGV met le jeton systeme dans
# `/proc/<pid>/cmdline`, lisible par n'importe quel process de la boite pendant toute la duree de
# l'appel — demander le jeton a un service pour le laisser ensuite dans une ligne de commande
# annulerait le geste au moment meme ou il s'exerce.
#
# `-K -` lit la configuration sur stdin — le secret passe par un tube, jamais par argv ni par un
# fichier. La sortie de `curl` reste sur stdout, donc les `| jq` en aval ne changent pas.
curl_auth() { # <url> — rend le corps de la reponse sur stdout
  printf 'header = "Authorization: token %s"\n' "$TOKEN" \
    | curl -sSf -m 15 -K - "$1"
}

echo "═══ Boite de reception sysadmin — $OPS_REPO ═══"
echo
echo "── Issues error_system (ouvertes) ──"
curl_auth "$api/repos/$OPS_REPO/issues?state=open&labels=error_system&type=issues&limit=50" \
  | jq -r '.[] | "#\(.number)  [\(.created_at[:10])]  \(.title)"' \
  || echo "(lecture impossible — forge down ?)"
echo
echo "── PR d'outillage en attente (vers $BRANCH) ──"
curl_auth "$api/repos/$OPS_REPO/pulls?state=open&limit=50" \
  | jq -r --arg b "$BRANCH" '.[] | select(.base.ref == $b) | "!\(.number)  [\(.created_at[:10])]  \(.title)"' \
  || echo "(lecture impossible — forge down ?)"
echo
echo "(signature d'une PR : sur la forge — approve, l'auto-merge fait le reste ; detail : chaque ticket)"
