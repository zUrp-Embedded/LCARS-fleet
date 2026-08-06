#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/console-pod.sh
# AUTHOR: consultant
# STARDATE: 2026-08-02
# STATUS: PROTO-V2 — la console D'UN pod, cible d'un ttyd `--url-arg` (UN port pour tous les pods)
#
# ttyd passe l'argument d'URL (`?arg=<pod_id>`) en argv. Ce script est la GARDE entre le monde
# et `lcars attach` : sans lui, un client choisit les arguments d'une commande locale.
#
# TROIS REFUS, ET ILS SE LISENT A L'ECRAN (l'humain est devant un terminal, pas devant un log) :
#   1. forme du pod_id (`[a-z0-9][a-z0-9-]*`) — rien d'autre ne peut ressembler a une option ;
#   2. UN seul argument — un second serait un argument passe a `lcars`, pas un pod ;
#   3. existence du socket tmux du pod — attacher un pod inconnu rend un message tmux illisible.
#
# UN PORT POUR N PODS : le bloc d'un humain n'a que 10 ports (base+0 API, +1 deck, +3 webhook,
# +4 console, +5 ici) — un ttyd par pod l'epuiserait a la sixieme mission. `--url-arg` est la
# seule forme qui tienne dans le bloc.

set -uo pipefail

POD_ID="${1:-}"
SOCK_BASE="${LCARS_TMUX_SOCK_BASE:-$HOME/.lcars/run/tmux-sock}"

# Un refus TIENT L'ECRAN, il ne sort pas. Le client de la console rouvre tout seul : sortir ferme
# la WebSocket avec un code que le navigateur rejette (« broken close frame » puis 1006), xterm.js
# se reconnecte, et le meme refus repart — un `sleep` avant `exit` ne ralentit pas la boucle, il en
# fixe la periode. Mesure: la mort groupee des pods d'un ticket mettait autant de cadres en
# reconnexion permanente. Le message dit « fermer cet onglet » : il s'adresse a un humain dont on
# attend qu'il RESTE, donc le processus reste aussi. C'est le navigateur qui coupe, et ttyd tue
# alors son enfant — rien ne fuit quand le cadre disparait.
die() { printf '\n  %s\n\n  (fermer cet onglet)\n' "$*"; exec sleep infinity; }

[[ $# -eq 1 ]] || die "console-pod: un seul argument attendu (le pod_id), recu $#."
[[ "$POD_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "console-pod: pod_id invalide."
[[ -S "$SOCK_BASE/$POD_ID/pod.sock" ]] || die "console-pod: pas de socket pour « $POD_ID » — pod inconnu ou deja mort."

exec lcars attach "$POD_ID"
