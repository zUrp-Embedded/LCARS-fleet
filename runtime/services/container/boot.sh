#!/usr/bin/env bash
# SOURCE: runtime/services/container/boot.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — le boot du conteneur (PID 1 sous tini) : init de l'instance, gestes de forge, services, puis exec sshd
#
# USAGE — les portes de l'image (« docker run --rm IMAGE <porte> … »), deleguees a « lcars tool » :
#   boot.sh verify <root>
#   boot.sh roles [root]
#   boot.sh roles-tfvars [root]
#   boot.sh catalogue-root
#   boot.sh catalogue-source <nom>
#   boot.sh forge-apply              (root : joue forge-gestures apply DANS le conteneur)
# Sans porte : le boot du conteneur (PID 1 sous tini).
#
# Modèle (etc/README.md du runtime) : l'humain SSH dans le conteneur EN TANT QUE LUI (sshd = le
# login-manager : auth + drop d'UID, zéro privilège custom) puis lance `fleet start`. L'image est
# posée au build par les modules de l'installeur ; au boot, aucun module ne tourne : le VOLUME
# converge ICI, par `container/init.sh apply` puis les gestes de `forge.d/`.
#
# Un échec de convergence NE TUE PAS le conteneur : le conteneur doit rester joignable pour être
# réparée (fail-loud dans les logs, pas fail-dead) — sshd démarre quoi qu'il arrive.
#
# Env d'entrée (compose/docker run) :
#   LCARS_ADMIRAL   login du master/sysadmin (bench: admiral, prod: login installeur) — uid 1000, sudo root, ssh
#                   ⚠ DOIT etre EXACTEMENT le login forge du master (le `preferred_username` OIDC) : le
#                   deck admet admiral par is_admin, puis mappe sa console sur `sess.login`. Si les deux
#                   different, admiral entre mais ne trouve pas sa console (page « pas de bloc »).
#   LCARS_UID       uid du sysadmin (défaut : 1000, réservé) — stable = ownership du volume stable
#   LCARS_SSH_AUTHORIZED_KEYS  contenu authorized_keys (sinon : accès par `docker exec` seulement)
#   FORGE_BASE_URL  forge cible (avec le profil compose `gitea` : http://gitea:3000)

set -euo pipefail

# ─── LES PORTES OUTIL : L'IMAGE GARDE LES MOTS, LA CLI DU PRODUIT PORTE LES GESTES ──────────────
#
# `docker run --rm IMAGE roles-tfvars [root]` (et `verify`, `roles`, `catalogue-root`,
# `catalogue-source`) est l'API de l'image : le banc et `enroll-catalogue.sh --image` s'en servent
# pour demander a une image son roster sans rien installer. Les quatre evaluations vivaient ICI,
# dans le PID 1 ; elles sont dans `lcars tool …` (lot 6, 2026-09-04), posees sur les deux rails, et
# ce fichier ne fait plus que deleguer. `forge-apply` reste : c'est le geste de structure joue
# DANS le conteneur par `container forge-apply`, et il exige root (il lit et ecrit `/opt/lcars/var/tokens`).
case "${1:-}" in
  verify|roles|roles-tfvars|catalogue-root|catalogue-source)
    exec /usr/local/bin/lcars tool "$@" ;;
  forge-apply)
    [[ "$(id -u)" -eq 0 ]] || { echo "forge-apply: cette porte ecrit et lit /opt/lcars/var/tokens — elle exige root dans le conteneur" >&2; exit 1; }
    exec /opt/lcars/forge-gestures.sh apply ;;
esac


# admiral = le master/sysadmin (uid 1000 reserve, sudo root). Bench: `admiral`. Prod: le login que
# l'installeur a cree sur SA forge. Ce n'est PAS un worker de la fleet — Guard B refuse de lancer une
# fleet sous cet uid, et les workers viennent du convergeur (forge lcars:humans, uid >= 1001).
# ─── 1. L'INIT DE L'INSTANCE — COTE PRODUIT ─────────────────────────────────────────────────────
#
# `container/init.sh` rend 4 quand le conteneur n'a rien pour determiner son siege : c'est l'etat
# « en attente de configuration », et le conteneur reste debout pour que « container config » soit jouable.
# 3 reste ce qu'il est partout ailleurs : la mort avant verdict, que la garde du protocole rend.
LCARS_UID="${LCARS_UID:-1000}"
export LCARS_SYSADMIN_UID="$LCARS_UID"
CONTAINER_INIT="${LCARS_CONTAINER_INIT:-/opt/lcars/services/container/init.sh}"
MODULE_PROTOCOL="${LCARS_MODULE_PROTOCOL:-/opt/lcars/services/lib/module-protocol.sh}"
# Un chemin en dur rend le bloc des gestes intestable, et un temoin qui ne peut pas le jouer ne dit
# rien de ce qu'il fait quand un geste meurt.
GESTES_DIR="${LCARS_FORGE_GESTURES_DIR:-/opt/lcars/services/forge.d}"
SEAT_LOGIN_FILE="${LCARS_SEAT_LOGIN_FILE:-/run/lcars-seat.login}"
# /run n'est pas un tmpfs dans un conteneur : un `docker restart` garde les verdicts du boot précédent,
# que « container status » lirait comme l'état présent. Chaque boot part d'un /run vide de ses verdicts.
say() { echo "[container-boot] $*"; }
# Un etat de boot qu'on ne peut ni retirer ni ecrire se DIT : son lecteur (« container status »)
# prendrait celui du boot precedent pour l'etat present, et personne ne saurait que le fichier ment.
etat_ecrit() { # etat_ecrit <fichier> <contenu> — 0 ecrit · 1 dit pourquoi il ne l'est pas
  if ! printf '%s\n' "$2" > "$1" 2>/dev/null; then
    say "verdict NON publie dans $1 — « container status » lira l'etat du boot precedent, ou rien"
    return 1
  fi
  # Le contenu est publie : un mode qui ne se pose pas se dit pour ce qu'il est, pas pour une
  # non-publication — le lecteur non privilegie pourrait ne pas l'ouvrir, le fichier est juste.
  chmod 0644 "$1" 2>/dev/null \
    || say "$1 publie, mais son mode n'a pas ete pose — un lecteur non privilegie pourrait ne pas l'ouvrir"
  return 0
}
for _f in "${LCARS_BOOT_STATE_FILE:-/run/lcars-boot.state}" "${LCARS_FORGE_RC_FILE:-/run/lcars-forge.rc}" "${LCARS_HUMANS_RC_FILE:-/run/lcars-humans.rc}"; do
  rm -f "$_f" 2>/dev/null \
    || say "verdict du boot precedent NON retire ($_f) — « container status » pourrait le lire comme l'etat present"
done
unset _f
[[ -r "$CONTAINER_INIT" && -r "$MODULE_PROTOCOL" ]] || {
  echo "[container-boot] init de l'instance introuvable ($CONTAINER_INIT, $MODULE_PROTOCOL) — cette image n'est pas complete, rien ne demarre" >&2
  exit 1
}
init_rc=0
LCARS_MODULE_PROTOCOL="$MODULE_PROTOCOL" LCARS_MODULE_RUN=1 \
  bash "$CONTAINER_INIT" apply 2>&1 | sed 's/^/[container-init] /' || init_rc=${PIPESTATUS[0]}
case "$init_rc" in
  0) say "init de l'instance : converge" ;;
  2) say "init de l'instance : APPLIQUE, DRIFT RESIDUEL — un geste manque, rien n'est casse" ;;
  3) say "init de l'instance : MORT avant de rendre son verdict — rien n'a ete conclu, les lignes [container-init] ci-dessus disent ou ; le conteneur reste debout pour etre lu, aucun service n'est demarre"
     etat_ecrit "${LCARS_BOOT_STATE_FILE:-/run/lcars-boot.state}" init-failed || true
     exec sleep infinity ;;
  4) say "conteneur EN ATTENTE DE CONFIGURATION — il reste debout pour que « container config » soit jouable. Aucun service n'est demarre, et le healthcheck le dira."
     etat_ecrit "${LCARS_BOOT_STATE_FILE:-/run/lcars-boot.state}" awaiting-config || true
     exec sleep infinity ;;
  *) say "init de l'instance : ECHEC (rc=$init_rc) — le conteneur reste debout pour etre lu, aucun service n'est demarre"
     etat_ecrit "${LCARS_BOOT_STATE_FILE:-/run/lcars-boot.state}" init-failed || true
     exec sleep infinity ;;
esac
LCARS_ADMIRAL="$(tr -d '[:space:]' < "$SEAT_LOGIN_FILE" 2>/dev/null || true)"
[[ -n "$LCARS_ADMIRAL" ]] || { say "siege NON lu ($SEAT_LOGIN_FILE) apres un init converge — incoherent, rien ne demarre" >&2; exit 1; }

# ─── 2. LES GESTES DE FORGE ──────────────────────────────────────────────────────────────────────
#
# Les quatre gestes du produit (`forge.d/`) : cache des catalogues, jetons de role, depot du systeme,
# client OAuth2 du deck. Chacun rend le code du protocole ; on n'invente rien, on relaie.

RC_FILE="${LCARS_FORGE_RC_FILE:-/run/lcars-forge.rc}"
# le verdict publié : le PREMIER état non conclusif rencontré tient — un échec ou une mort (3)
# l'emportent sur un drift, un drift (init compris) sur 0, et aucun des deux ne s'efface l'un l'autre
prov_rc=0
[[ "$init_rc" -ne 2 ]] || prov_rc=2
# L'ORDRE EST CELUI DU POSTE (modules 50, 63, 65, 66), et il porte une dependance : les roles a
# minter viennent des catalogues installes, donc `catalogues` precede `tokens`. Le geste `tokens`
# sonde aussi le compte forge du siege, que ce boot nomme par LCARS_LOGIN.
# LCARS_MODULE_RUN arme la garde du protocole : une mort avant verdict rend 3, jamais 1 ou 2, qui se
# lisent comme des verdicts.
for gesture in catalogues tokens ops-repo deck-oidc; do
  g_rc=0
  LCARS_MODULE_PROTOCOL="$MODULE_PROTOCOL" LCARS_MODULE_TAG="$gesture" LCARS_LOGIN="$LCARS_ADMIRAL" \
    LCARS_MODULE_RUN=1 \
    bash "$GESTES_DIR/$gesture.sh" apply 2>&1 | sed "s/^/[forge.d] /" || g_rc=${PIPESTATUS[0]}
  case "$g_rc" in
    0) : ;;
    2) say "geste de forge « $gesture » : drift residuel — il se reposera au boot suivant"
       [[ "$prov_rc" -ne 0 ]] || prov_rc=2 ;;
    # 3 et un echec sont tous deux non nuls, et le PREMIER rencontre reste : une mort n'efface pas
    # un echec deja rendu, un echec n'efface pas une mort. Seul un drift (2) se laisse remplacer.
    3) say "geste de forge « $gesture » : MORT avant de rendre son verdict — rien n'a ete conclu, les lignes [forge.d] ci-dessus disent ou ; le conteneur demarre quand meme"
       [[ "$prov_rc" -ne 0 && "$prov_rc" -ne 2 ]] || prov_rc=3 ;;
    *) say "geste de forge « $gesture » : ECHEC (rc=$g_rc) — le conteneur demarre quand meme"
       [[ "$prov_rc" -ne 0 && "$prov_rc" -ne 2 ]] || prov_rc=$g_rc ;;
  esac
done

# La publication descend donc APRÈS les deux mesures, et `lcars-forge.rc` s'écrit EN DERNIER :
# sa présence devient la garantie que l'autre fichier est là. Un lecteur qui attend un seul des deux
# n'a plus à connaître l'ordre — c'est le producteur qui le tient.
#
# Le verdict se publie quel qu'il soit, y compris 0. Un fichier qui n'apparaîtrait que sur l'échec
# forcerait son lecteur à distinguer « pas encore écrit » de « tout va bien », c'est-à-dire à deviner
# exactement ce que ce fichier existe pour dire.
publier_verdicts() {
  [[ -z "${humans_rc:-}" ]] || etat_ecrit "$HUMANS_RC_FILE" "$humans_rc" || true
  etat_ecrit "$RC_FILE" "$prov_rc" || true
}

# ─── LANCER UN SERVICE PERSISTANT — CE QUE `Restart=` FAIT SUR L'AUTRE RAIL ─────────────────────
#
# ⚠ ET LE SUPERVISEUR NE PEUT PAS VIVRE ICI. Ce script finit sur `exec /usr/sbin/sshd -D -e` : le
# shell est REMPLACÉ, donc toute boucle qu'il porterait disparaîtrait à cet instant. D'où un
# processus à part, lancé en `setsid` exactement comme les services l'étaient.
SUPERVISE="${LCARS_SUPERVISE_BIN:-/opt/lcars/supervise.sh}"
launch() { # launch <nom> <log> -- <cmd...> — rend 1 si la commande n'est pas lancable, et le dit
  local name="$1" log="$2"; shift 2
  [[ "${1:-}" == "--" ]] && shift
  # ⚠ L'ECHEC SE MESURE ICI OU NULLE PART. `setsid … &` rend la main sans savoir si la commande a pu
  # s'executer : un `|| say` derriere `launch` etait une branche inatteignable, et le message qu'elle
  # portait (« AUCUNE console n'est joignable ») n'etait jamais dit (relecture hostile 2026-09-04, M7).
  # Ce qui SE mesure avant de lancer : que la commande existe et soit executable. Ce qui meurt APRES
  # est l'affaire du superviseur, qui le journalise et borne la relance.
  if [[ -z "${1:-}" ]] || ! command -v -- "$1" >/dev/null 2>&1; then
    say "$name NON lancé — commande introuvable ou non exécutable : ${1:-<vide>}"
    return 1
  fi
  if [[ -x "$SUPERVISE" ]]; then
    # SC2094 : `--log "$log"` et `>>"$log"` visent bien le meme fichier, et c'est voulu — les deux
    # AJOUTENT (`O_APPEND`), pour que les messages du superviseur et la sortie du service tiennent
    # le meme journal. Un `>` ici tronquerait a l'ouverture ; c'est l'autre moitie du meme piege.
    # shellcheck disable=SC2094
    setsid "$SUPERVISE" --name "$name" --log "$log" -- "$@" </dev/null >>"$log" 2>&1 &
    say "$name ACTIF (pid $!, supervisé — relance automatique, bornée)"
  else
    setsid "$@" </dev/null >>"$log" 2>&1 &
    say "$name ACTIF (pid $!, NON supervisé — $SUPERVISE absent : une mort du service ne sera pas rattrapée)"
  fi
}

# ─── 3ter. Convergence CONTINUE des humains (forge `humans` → users Linux) ───────────────────────
# L'étape 3 converge un état FIGÉ, au boot. Enrôler quelqu'un demandait donc un redémarrage — ce qui
# était défendable en 1976. Cette boucle poursuit le même état-cible pendant toute la vie du
# conteneur : elle lit la team `humans` au token système et crée les users manquants. Elle tourne en
# root parce que root tourne DÉJÀ ici en permanence (sshd juste dessous) — pas de `sudo` à
# installer, pas de droit à accorder à quiconque.
# Elle ne SUPPRIME jamais : la révocation est un retrait côté forge, et ce qui reste sur la machine
# est de la donnée, pas un accès (sans compte forge, ni console ni fleet ne s'ouvrent).
CONVERGER_BIN="${LCARS_HUMAN_CONVERGER:-/opt/lcars/human-converger.sh}"
CONVERGER_LOG="${LCARS_CONVERGER_LOG:-/var/log/lcars-converger.log}"
if [[ "${LCARS_CONVERGE_HUMANS:-1}" == "1" && -x "$CONVERGER_BIN" ]]; then
  # ─── UN PREMIER TOUR SYNCHRONE, PUIS LA BOUCLE ────────────────────────────────────────────────
  #
  # ⚠ ET LA RÈGLE D'UID N'EST PAS RÉÉCRITE ICI, C'EST TOUT LE SUJET. Le dispositif que ce
  # commentaire décrivait (`64-services`, `probe_fleet_humans`, un `doctor --only` au boot) est mort
  # au lot 6 : l'installeur ne joue plus dans le conteneur. Ce qui reste est le PRÉDICAT du protocole,
  # `is_fleet_human` (`lib/human-protocol.sh`) — celui du convergeur et des modules per-humain — et
  # c'est lui que le verdict ci-dessous appelle. Recopier la règle ici en ferait un troisième
  # exemplaire, et c'est toujours celui qu'on ne relit pas qui ment (relecture hostile 2026-09-04 :
  # ce bloc en portait un, plancher 1000 en dur, sous ce même commentaire).
  #
  # `timeout` : ce premier tour parle à la forge et provisionne chaque humain. Il est BORNÉ parce
  # qu'un boot ne peut pas dépendre d'un réseau, et NON FATAL parce que le conteneur doit rester
  # joignable pour être réparée — même règle que tout le reste de ce fichier.
  # ⚠ 240 s ETAIT TROP LONG POUR UN BOOT, et ce n'etait pas mesure — c'etait un chiffre pose au
  # jugé. Le port 22 n'ouvre qu'apres cette passe : chaque seconde ici est une seconde ou personne ne
  # peut entrer reparer. Le but de ce tour n'est PAS de tout provisionner — la boucle detachee s'en
  # charge — mais de rendre le VERDICT significatif. 120 s couvre une forge qui repond et quelques
  # humains ; au-dela, la boucle reprend et le verdict dit « non concluant », ce qui est vrai.
  FIRST_PASS_TIMEOUT="${LCARS_FIRST_PASS_TIMEOUT:-120}"
  first_rc=0
  timeout "$FIRST_PASS_TIMEOUT" "$CONVERGER_BIN" --once \
    </dev/null >>"$CONVERGER_LOG" 2>&1 || first_rc=$?
  if [[ "$first_rc" -eq 0 ]]; then
    say "convergence des humains : premier tour fait"
  else
    say "convergence des humains : premier tour NON CONCLUANT (rc=$first_rc) — la boucle reprendra ; détail dans $CONVERGER_LOG"
  fi

  # LE FAIT, PAS LE CODE DE RETOUR. Le convergeur peut rendre 0 sans avoir converti personne (une
  # team vide EST un résultat valide, et sur un conteneur de production c'est même le cas nominal tant
  # que personne ne s'est enrôlé). Ce qui se publie est ce que la SONDE constate.
  HUMANS_RC_FILE="${LCARS_HUMANS_RC_FILE:-/run/lcars-humans.rc}"
  # Un humain de fleet est un membre du groupe `fleet` que `is_fleet_human` reconnait (uid au-dessus
  # de UID_MIN, pas le siege). Le protocole est source dans un sous-shell : ses defauts sont faits
  # pour un module, pas pour le PID 1.
  HUMAN_PROTOCOL="${LCARS_HUMAN_PROTOCOL:-/opt/lcars/services/lib/human-protocol.sh}"
  # Trois reponses : 0 quelqu'un, 1 personne, 2 population non mesuree (protocole absent, bornes
  # d'uid illisibles). Un 1 sur une mesure impossible enverrait inscrire quelqu'un sur la forge
  # alors que c'est la machine qu'il faut reparer.
  humans_rc=1 pop_rc=1
  if [[ ! -r "$HUMAN_PROTOCOL" ]]; then
    pop_rc=2
    say "protocole des humains introuvable ($HUMAN_PROTOCOL) — la population n'est PAS mesuree, cette image n'est pas complete"
  else
    pop_rc=0
    # hote du protocole, comme le convergeur : ce bloc nomme un sujet a chaque appel au lieu
    # d'emprunter le siege, sinon toute lecture « de la personne » serait celle d'admiral
    ( export LCARS_MODULE_PROTOCOL="$MODULE_PROTOCOL"
      LCARS_HUMAN_PROTOCOL_HOST=1
      # shellcheck source=../lib/human-protocol.sh
      . "$HUMAN_PROTOCOL"
      unset LCARS_HUMAN_PROTOCOL_HOST
      uid_bounds || exit 2
      while IFS= read -r _m; do
        [[ -n "$_m" ]] || continue
        is_fleet_human "$_m" && exit 0
      done < <(getent group "${LCARS_FLEET_GROUP:-fleet}" | cut -d: -f4 | tr ',' '\n')
      exit 1 ) || pop_rc=$?
  fi
  case "$pop_rc" in 0) humans_rc=0 ;; 2) humans_rc=2 ;; esac
  if [[ "$humans_rc" -eq 0 ]]; then
    say "humain(s) de fleet : présent(s) — « fleet start » a quelqu'un pour le lancer"
  elif [[ "$pop_rc" -eq 2 ]]; then
    say "population des humains NON mesurée — la frontière système/humain n'est pas établie, la cause est dite ci-dessus : GUARD B refusera tout « fleet start » tant qu'elle ne l'est pas"
  else
    say "AUCUN humain de fleet dans ce conteneur — GUARD B refusera tout « fleet start ». Enrôle quelqu'un sur la forge et ajoute-le à la team « humans » : la boucle le matérialise au tour suivant"
  fi

  launch "convergence des humains" "$CONVERGER_LOG" -- "$CONVERGER_BIN" \
    || say "convergence des humains NON lancée — le conteneur reste joignable, mais personne ne sera matérialisé sans redémarrage"
  say "un ajout à la team « humans » suffit désormais, sans redémarrage"
else
  say "convergence des humains DÉSACTIVÉE — enrôler quelqu'un exige un geste manuel dans le conteneur"
fi

# LES DEUX VERDICTS, ENSEMBLE ET DANS CET ORDRE. `humans_rc` n'existe que si la convergence a
# tourné ; sans elle, seul `forge.rc` est publié et `container up` dit « NON MESURÉE » — ce qui est
# exactement vrai. La présence de `forge.rc` garantit que l'autre est là quand il doit l'être.
publier_verdicts

# ─── 3bis. La console web (ttyd sous l'humain, sur SA socket AF_UNIX) ───────────────────────────
# Lancée APRÈS la convergence (elle a besoin de l'humain et de son home) et AVANT sshd (qui prend
# le premier plan). Son échec n'est pas fatal — même règle que la convergence : le conteneur doit
# rester joignable pour être réparée. La console est un CONFORT, ssh reste la porte d'admin.
if [[ "${LCARS_CONSOLE:-1}" == "1" ]]; then
  # `--all` : UNE console par humain éligible, chacune sur SA socket
  # (`/run/lcars/console/<humain>/`), gardée par le mode du répertoire. Le multi-humain ne coûte
  # aucune coordination — un répertoire possédé par chacun, pas de registre. L'éligibilité et la
  # garde anti-système vivent dans console-humans.sh, source unique.
  /opt/lcars/console.sh --all || say "console web NON lancée (rc=$?) — ssh reste la porte"

  # La home du conteneur, sur un port HORS de l'espace des blocs humains. Elle n'appartient à aucun
  # humain — c'est la porte du conteneur. Échec non fatal comme le reste.
  #
  # ⚠ PAR `launch`, ET AVEC `--foreground` : LES DEUX MOITIÉS COMPTENT. Ce bloc appelait le script
  # nu, qui se met lui-même en arrière-plan (`console-landing.sh`, dernière ligne) et rend la main.
  #
  # `--foreground` fait `exec` sur `console-deck.py` : l'enfant de `supervise.sh` EST le deck, donc
  # son `wait` mesure le bon processus et son relais de TERM l'atteint. SANS lui, on superviserait
  # un script qui rend la main aussitôt — donc une relance immédiate, en boucle, jusqu'à la borne.
  # C'est exactement la forme que l'unité systemd du rail poste met dans son `ExecStart`
  # (`64-services.sh`) : un seul mécanisme de démarrage pour les deux rails, pas deux.
  if [[ "${LCARS_LANDING:-1}" == "1" ]]; then
    # Le port du deck a UNE déclaration (`PROV_DECK_PORT`, MUR 4 de variable_walls) et ses copies la
    # suivent : ici le défaut que le daemon lit, EXPORTÉ pour que le geste `deck-oidc` (les
    # `redirect_uris` OAuth2) et le deck lisent la même valeur dans ce conteneur. L'ENTRÉE publiée
    # sur l'hôte (`LCARS_LANDING_PORT_BIND`) est un autre fait : « container up » la traduit en
    # `LCARS_DECK_ORIGINS` (B1). Le nom est unique depuis le lot 8 — plus de pont entre deux noms.
    export LCARS_LANDING_PORT="${LCARS_LANDING_PORT:-20999}"
    launch "home du conteneur (deck)" /var/log/lcars-landing.log -- \
      /opt/lcars/console-landing.sh --foreground \
      || say "home NON lancée (rc=$?) — AUCUNE console n'est joignable (elles n'ont plus de port, le landing est le seul chemin) ; ssh reste la porte"
  fi
else
  say "console web désactivée (LCARS_CONSOLE=0)"
fi

# ─── 3quater. L'exécuteur de catalogue (root, une socket, l'autorité de la forge) ───────────────
# `lcars catalogue install` ne détient plus rien : il DEMANDE ici. Ce process tient le jeton master,
# lit l'uid du pair que le noyau pose sur la socket, demande à la forge si ce login y porte
# `is_admin`, et joue le geste. Séparer « prouver qui tu es » de « exécuter » est ce qui supprime le
# groupe unix, sa projection, son cache et son rattrapage de dérive.
LCARS_AUTHORITY_USER="${LCARS_AUTHORITY_USER:-lcars-authority}"
if [[ "${LCARS_CATALOGUE_EXECUTOR:-1}" == "1" && -r /opt/lcars/catalogue-executor.py ]] \
   && id -u "$LCARS_AUTHORITY_USER" >/dev/null 2>&1; then
  # ⚠ `setpriv` PARCE QUE CE RAIL N'A PAS SYSTEMD. Sur le poste, `User=` de l'unite fait ce drop ;
  # ici ce boot est PID 1 et personne ne le fait a sa place. Le service ne doit pas heriter de son
  # root — il detient les secrets de la forge et n'a aucun privilege a exercer.
  # Le `setpriv` est DANS la commande supervisée, pas autour du superviseur : celui-ci doit rester
  # root pour pouvoir relancer, et c'est l'ENFANT qui descend — exactement ce que `User=` fait dans
  # l'unité systemd du rail poste, où systemd reste root et le service non.
  # ⚠ ET SON REPERTOIRE RUNTIME AVEC, POUR EXACTEMENT LA MEME RAISON — c'est l'autre moitie de
  # `User=`, et elle manquait. `lcars_socket.py` cree le dossier de socket AVEC L'UID DU SERVICE :
  # un service qui vient de DROPPER ne peut rien creer sous `/run/lcars` (root:root 0755). Sur le
  # poste, `25-directories` pose ce dossier et l'unite porte `User=` — deux moities d'un seul geste,
  # tenues par deux acteurs. Ici ce boot est le seul acteur, et il n'en tenait qu'une.
  #
  # Les services qui restent root creent le leur tout seuls : ils masquaient le trou. Celui-ci, non.
  # Mesure .63 du 2026-08-30 : « PermissionError: [Errno 13] … '/run/lcars/authority' », cinq
  # relances en moins d'une minute, puis ABANDON du superviseur (sa borne, et elle a bien joue) —
  # un service MORT sur un banc que tout le reste declarait PRET.
  #
  # ⚠ ICI ET NULLE PART AILLEURS : sur docker, `prov_runtime_dirs` ne declare AUCUN dossier de
  # `/run/lcars`, precisement pour qu'il n'y ait jamais deux createurs. `install -d` ne repose pas
  # le mode d'un dossier existant, donc un desaccord entre deux poseurs serait SILENCIEUX.
  install -d -m 0750 -o "$LCARS_AUTHORITY_USER" -g "${LCARS_FLEET_GROUP:-fleet}" /run/lcars/authority \
    || say "ATTENTION : /run/lcars/authority non pose — l'executeur de catalogue ne pourra pas ouvrir sa socket"
  launch "executeur de catalogue" /var/log/lcars-catalogue.log -- \
    setpriv --reuid "$LCARS_AUTHORITY_USER" --regid "$LCARS_AUTHORITY_USER" --init-groups \
    python3 /opt/lcars/catalogue-executor.py \
    || say "executeur de catalogue NON lancé — « lcars catalogue install » refusera, en nommant ce service"
  say "« lcars catalogue install » passe par lui"
else
  say "executeur de catalogue ABSENT — « lcars catalogue install » refusera, en nommant ce service"
fi

# ─── 3quinquies. Le service PRIVILÉGIÉ (root, une socket, et AUCUN secret) ──────────────────────
#
# ⚠ IL REMPLACE `%fleet ALL=(root) NOPASSWD:`. C'était le lien le plus fin du système : un chemin
# `groupe → root` direct, sur un groupe que le convergeur repeuple depuis la forge toutes les 30 s.
# Le droit d'exécuter du code en root avait donc la péremption d'un cache.
#
# ⚠ PAS DE `setpriv` ICI, ET C'EST LE SEUL BLOC DE CE FICHIER OÙ SON ABSENCE EST LE CONTRAT. Le
# voisin au-dessus DOIT descendre (il détient les secrets) ; celui-ci DOIT rester root (il porte le
# geste privilégié) et ne détient rien. Les deux règles sont la même règle, lue des deux côtés.
if [[ "${LCARS_PRIVILEGED_EXECUTOR:-1}" == "1" && -r /opt/lcars/privileged-executor.py ]]; then
  launch "service privilégié" /var/log/lcars-privileged.log -- \
    python3 /opt/lcars/privileged-executor.py \
    || say "service privilégié NON lancé — la convergence d'outillage refusera, en nommant sa socket"
  say "la convergence d'outillage passe par sa socket, plus par sudo"
else
  say "service privilégié ABSENT — la convergence d'outillage refusera, en nommant sa socket"
fi

# ─── 4. sshd au premier plan (tini est PID 1 : reap + signaux ; exec = sshd reçoit les signaux) ──
say "sshd prêt — ssh $LCARS_ADMIRAL@<hôte> -p <port mappé> : c'est la porte d'ADMIN. « fleet start » veut un humain de fleet, depuis sa console — GUARD B refuse le siège"
exec /usr/sbin/sshd -D -e
