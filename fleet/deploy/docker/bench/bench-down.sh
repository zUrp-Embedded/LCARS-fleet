#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/bench/bench-down.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-03
# STATUS: geste de BANC — DETRUIT un banc complet, volumes compris
#
# ─── POURQUOI CE GESTE VIT DANS SON PROPRE FICHIER ──────────────────────────────────────────────
# `bench-up.sh` monte, celui-ci detruit. Les separer n'est pas de la coquetterie : le `-v` de
# `compose down` efface les volumes, donc la forge, ses comptes, ses tokens et le /home de la boite.
# Tant que le geste destructeur est une OPTION d'un script qu'on lance vingt fois par nuit, il finit
# par partir sur le mauvais projet. Ici il faut ecrire le nom du projet, et --yes.
#
# ⚠ LE NOM DU PROJET EST LA SEULE PROTECTION. Il n'y a aucun defaut : un defaut sur ce script serait
# un banc detruit par une commande sans argument. Un banc qui TRAVAILLE se detruit comme un autre —
# la machine ne sait pas lequel compte, c'est a toi de le savoir.
#
# UN BANC = TROIS PROJETS COMPOSE : la boite (`<projet>`), la forge (`<projet>forge`) et le
# runner (`<projet>-runner`). Les trois partent ici, le runner en premier parce qu'il tient le
# reseau de la forge.
#
# USAGE : bench-down.sh --project lcars-nuit --yes
# EXIT  : 0 detruit · 1 arguments · 2 rien a detruire sous ce nom

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"

PROJECT=""
CONFIRM=0
DOCKER_BIN="${DOCKER_BIN:-docker}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:?}"; shift 2 ;;
    --yes)     CONFIRM=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench-down: option inconnue: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$PROJECT" ]] || { echo "bench-down: --project est OBLIGATOIRE (aucun defaut, par choix)" >&2; exit 1; }
[[ "$CONFIRM" -eq 1 ]] || { echo "bench-down: --yes requis — ceci efface les volumes de '$PROJECT'" >&2; exit 1; }

# ⚠ AVANT LE PREMIER APPEL A COMPOSE, PAS A LA FIN. Le compose de la boite nomme ses volumes de
# magasin `${LCARS_STORE_PREFIX}-<nature>` avec un `:?` : sans la variable, il REFUSE de parser le
# fichier, et le `down -v` ci-dessous echouerait sur un banc parfaitement destructible. C'est aussi
# la variable dont `store_destroy_volumes` derive ce qu'il efface.
export LCARS_STORE_PREFIX="$PROJECT"
# shellcheck source=../../lib/store.sh
source "$DOCKER_DIR/../lib/store.sh"

FORGE_PROJECT="${PROJECT}forge"
RUNNER_PROJECT="${PROJECT}-runner"
BOX="${PROJECT}-lcars-1"
RUNNER="${RUNNER_PROJECT}-runner-1"
FORGE="${FORGE_PROJECT}-forge-1"

# UN BANC A TROIS PROJETS COMPOSE, ET CELUI-CI N'EN VOYAIT QUE DEUX. `bench-up.sh` lance aussi un
# runner (`forge-runner.sh --project "${PROJECT}-runner"`) ; il n'etait jamais detruit. Mesure du
# 2026-08-09 : apres un `bench-down` complet, `lcars-faces-runner-runner-1` tournait toujours, et
# le `down` de la forge finissait sur « Network ... Resource is still in use » — le runner est
# branche sur le reseau de la forge, donc tant qu'il vit ce reseau ne part pas. Il reste enregistre
# contre une forge qui n'existe plus : le zombie que forge-runner decrit dans son propre en-tete,
# sauf que la, personne ne le nettoie avant le banc SUIVANT.
#
# ⚠ LE DISCRIMINANT PORTE SUR LE RESIDU, PLUS SUR UNE LISTE DE CONTENEURS ATTENDUS. Il a d'abord
# regarde la boite seule, puis la boite OU le runner — a chaque fois un membre de plus, jamais la
# classe. Le membre manquant s'est presente : `bench-up` meurt AVANT de creer la boite (forge qui
# ne repond pas), il ne reste que `<projet>forge-forge-1` et ses deux volumes, et ce script
# repondait « rien a detruire » sur un banc qui occupait le bind, le port et le nom du projet. Le
# banc suivant se montait alors sur les restes du precedent.
#
# La question juste n'est pas « la boite est-elle la ? » mais « reste-t-il QUOI QUE CE SOIT de ce
# banc ? » — donc les trois conteneurs ET les volumes des trois projets. Les volumes comptent
# seuls : ce sont eux qui portent l'etat (la forge semee, le /home de la boite), et `down -v` les
# emporte meme quand plus aucun conteneur ne les monte.
RESIDU_C="$("$DOCKER_BIN" ps -a --format '{{.Names}}' | grep -cxE "$BOX|$RUNNER|$FORGE" || true)"
RESIDU_V="$("$DOCKER_BIN" volume ls --format '{{.Name}}' \
  | grep -cE "^(${PROJECT}|${FORGE_PROJECT}|${RUNNER_PROJECT})_" || true)"

[[ "$RESIDU_C" -gt 0 || "$RESIDU_V" -gt 0 ]] \
  || { echo "bench-down: aucun conteneur ni volume de '$PROJECT' (ni $BOX, $RUNNER, $FORGE) — rien a detruire" >&2; exit 2; }

# LE RUNNER D'ABORD, et l'ordre n'est pas cosmetique : il tient le reseau de la forge, donc le
# detruire apres laisserait ce reseau debout. Valeurs factices comme dans le nettoyage de
# forge-runner : `runner-compose.yml` exige LCARS_FORGE_URL (`:?`) et l'interpolation refuse MEME
# un down — sans elles ce nettoyage echoue en silence sous le `|| true`.
echo "[bench-down] destruction du runner ($RUNNER_PROJECT)"
# ⚠ MEME RAISON QUE DANS `forge-runner.sh` : ces valeurs voyagent par un ENV-FILE, pas par
# l'environnement. Sur WSL le rail passe peut-etre par un shim qui `sudo` pour joindre la socket, et
# `sudo` remet l'environnement a zero — les assignations en tete de commande mourraient en le
# traversant, l'interpolation de `runner-compose.yml` refuserait (`:?`), et ce nettoyage echouerait
# EN SILENCE sous le `|| true`. Un runner zombie survivrait a la destruction du banc.
RUNNER_ENV_DOWN="$(mktemp "${TMPDIR:-/tmp}/bench-down-runner.XXXXXX")"
chmod 0600 "$RUNNER_ENV_DOWN"
printf 'LCARS_FORGE_URL=%s\nLCARS_RUNNER_TOKEN=%s\n' "http://forge:3000" " " > "$RUNNER_ENV_DOWN"
"$DOCKER_BIN" compose --env-file "$RUNNER_ENV_DOWN" -f "$HERE/runner-compose.yml" -p "$RUNNER_PROJECT" \
  down -v --remove-orphans || true
rm -f "$RUNNER_ENV_DOWN"

echo "[bench-down] destruction de la boite ($PROJECT) — volumes compris"
"$DOCKER_BIN" compose -f "$DOCKER_DIR/docker-compose.install.yml" -p "$PROJECT" down -v --remove-orphans || true

echo "[bench-down] destruction de la forge ($FORGE_PROJECT) — volumes compris"
"$DOCKER_BIN" compose -f "$HERE/forge-compose.yml" -p "$FORGE_PROJECT" down -v --remove-orphans || true

# ⚠ LE MAGASIN EST DETRUIT AVEC LE BANC, ET C'EST LE SENS DU MOT « JETABLE ». Ce script a epargne
# les quatre volumes du magasin — ils etaient partages entre les bancs de la machine, donc les
# emporter aurait vide le voisin. Il le DISAIT (c'etait la contrepartie honnete d'un partage qu'il ne
# pouvait pas defaire) en dictant `docker volume rm lcars-cache …` pour finir le menage : une ligne
# qui, tapee, vidait le magasin de l'autre banc EN MARCHE. Un banc n'est pas jetable si le detruire
# demande une seconde commande dangereuse pour les autres.
#
# Depuis que les noms portent le projet (`lib/store.sh`), il n'y a plus rien a arbitrer : ce magasin
# n'appartient qu'a ce banc, et il part avec lui. Une toolchain compilee sur un banc l'a ete pour
# verifier que la mecanique marche, pas pour etre gardee.
echo "[bench-down] destruction du magasin de '$PROJECT' ($(store_volume_names | tr '\n' ' ' | sed 's/ $//'))"
store_destroy_volumes "$DOCKER_BIN" || echo "[bench-down] ATTENTION : au moins un volume du magasin n'a pas pu etre detruit" >&2

echo "[bench-down] banc '$PROJECT' detruit"
