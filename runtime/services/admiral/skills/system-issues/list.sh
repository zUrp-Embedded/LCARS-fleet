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

# L'adresse de la forge, là où la session du siège la trouve : `FORGE_BASE_URL` s'il est dans
# l'environnement (une session « docker exec » l'hérite du service), sinon `forge.url` du répertoire
# des jetons (0644, dans un dossier que le groupe fleet traverse, et le siège est dans fleet). Ce
# fichier est posé sur les deux rails : par l'installeur sur un poste, par l'init du démarrage dans un
# conteneur — une session ssh n'hérite pas de l'environnement du service. Même ordre que le protocole
# des gestes de forge.
FORGE_URL_FILE="${LCARS_PRIVATE_DIR:-/opt/lcars/var/tokens}/forge.url"
FORGE_URL="${LCARS_FORGE_URL:-${FORGE_BASE_URL:-$(head -n1 "$FORGE_URL_FILE" 2>/dev/null | tr -d '[:space:]' || true)}}"
# ⚠ LE JETON SYSTEME, PAS LE MASTER, ET C'EST UNE CORRECTION DE PRIVILEGE. Ce script ne fait que
# DEUX LECTURES sur un depot PUBLIC — mesure du 2026-08-23 sur une forge vivante : le dépôt système (`lcars/_ops`) est
# `private=false, internal=false`, et ses deux points d'entree (`issues`, `pulls`) repondent 200 en
# ANONYME. Aucune de ces lectures n'est site-admin.
#
# Tenir le master parce qu'il est la imposerait que son fichier reste lisible par un humain — l'ACL
# que le conteneur refuse. Le compte systeme est l'identite juste : c'est avec lui que le conteneur lit sa
# forge. Donner un site-admin a une lecture serait lui accorder un pouvoir dont elle n'a aucun usage
# — meme argument, et meme formulation, que `cmd_install` dans `forge-gestures.sh`.
#
# ─── ET IL NE LIT PAS LE JETON : IL LE DEMANDE ──────────────────────────────────────────────────
#
# Un fichier `0640 root:fleet` que le siege lirait par le groupe serait encore une PROJECTION de
# l'equipe `humans` de la forge, avec trente secondes de peremption — et un refus qui dirait « il
# est lisible par le groupe fleet » enverrait chercher une adhesion. La question se pose a
# `roles.sock` : le service la porte a la forge A L'INSTANT du geste.
SYSTEM_ACCOUNT="${LCARS_SYSTEM_ACCOUNT:-system_starfleet}"
AUTHORITY_ASK="${LCARS_AUTHORITY_ASK_BIN:-/usr/local/bin/lcars-authority-ask}"
OPS_REPO="${LCARS_OPS_REPO:-lcars/_ops}"
# Nom GELE, autorite `Fleet.Toolchain.branch/0`, recopie tenue par le contrat
# `toolchain.branch_single_source`. Reglable a moitie, il ferait relever une boite aux lettres
# pendant que les demandes atterrissent dans une autre.
BRANCH="tool_request"

[[ -n "$FORGE_URL" ]] || { echo "system-issues: adresse de la forge inconnue — ni FORGE_BASE_URL dans l'environnement, ni $FORGE_URL_FILE lisible. Sur un poste, « deploy/workstation up » écrit ce fichier ; dans un conteneur, son démarrage l'écrit depuis FORGE_BASE_URL (« FORGE_BASE_URL=<url> deploy/container config » depuis l'hôte, puis « deploy/container up ») ; ailleurs, « FORGE_BASE_URL=<url> » devant la commande" >&2; exit 1; }
[[ -x "$AUTHORITY_ASK" ]] || { echo "system-issues: client d'autorité absent ($AUTHORITY_ASK) — sur un poste, « deploy/workstation up » le pose ; dans un conteneur, c'est l'image qui le porte" >&2; exit 1; }

# La cause du refus est deja imprimee en francais par le client, sur stderr. La reformuler ici la
# remplacerait par une plus vague : ce script sait qu'il n'a pas de jeton, il ne sait pas pourquoi.
#
# ⚠ UN REFUS N'ARRETE PAS LA LECTURE. Le siege n'entre pas dans la team humans (aucun siege n'est
# privilegie aupres de l'autorite), donc l'autorite lui refuse le jeton ; or ces deux lectures portent
# sur un depot public, que la forge sert en anonyme. Sans jeton, elles se font en anonyme, et le
# script le dit ; un depot qui ne se lit pas en anonyme est alors un refus nomme, jamais une liste vide.
TOKEN="$("$AUTHORITY_ASK" "$SYSTEM_ACCOUNT")" \
  || { TOKEN=""; echo "system-issues: pas de jeton de forge pour ce compte (cause ci-dessus) — lecture anonyme de $OPS_REPO, dépôt public" >&2; }

api="$FORGE_URL/api/v1"

# ⚠ `-K -` ET PAS `-H` : un en-tete construit en ARGV met le jeton systeme dans
# `/proc/<pid>/cmdline`, lisible par n'importe quel process du conteneur pendant toute la duree de
# l'appel — demander le jeton a un service pour le laisser ensuite dans une ligne de commande
# annulerait le geste au moment meme ou il s'exerce.
#
# `-K -` lit la configuration sur stdin — le secret passe par un tube, jamais par argv ni par un
# fichier. La sortie de `curl` reste sur stdout, donc les `| jq` en aval ne changent pas.
curl_auth() { # <url> — rend le corps de la reponse sur stdout ; sans jeton, la lecture est anonyme
  if [[ -z "$TOKEN" ]]; then
    curl -sSf -m 15 "$1"
    return
  fi
  printf 'header = "Authorization: token %s"\n' "$TOKEN" \
    | curl -sSf -m 15 -K - "$1"
}

lecture_ko() { # la phrase d'une lecture en echec, selon qu'elle etait anonyme ou non
  if [[ -z "$TOKEN" ]]; then
    echo "(lecture anonyme refusée : $OPS_REPO ne se lit pas sans jeton, et l'autorité n'en donne pas à ce compte)"
  else
    echo "(lecture impossible — la forge répond-elle ? $FORGE_URL)"
  fi
  RC=1
}

RC=0
echo "═══ Boite de reception sysadmin — $OPS_REPO ═══"
echo
echo "── Issues error_system (ouvertes) ──"
curl_auth "$api/repos/$OPS_REPO/issues?state=open&labels=error_system&type=issues&limit=50" \
  | jq -r '.[] | "#\(.number)  [\(.created_at[:10])]  \(.title)"' \
  || lecture_ko
echo
echo "── PR d'outillage en attente (vers $BRANCH) ──"
curl_auth "$api/repos/$OPS_REPO/pulls?state=open&limit=50" \
  | jq -r --arg b "$BRANCH" '.[] | select(.base.ref == $b) | "!\(.number)  [\(.created_at[:10])]  \(.title)"' \
  || lecture_ko
echo
echo "(signature d'une PR : sur la forge — approve, l'auto-merge fait le reste ; detail : chaque ticket)"
exit "$RC"
