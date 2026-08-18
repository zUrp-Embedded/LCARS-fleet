#!/usr/bin/env bash
# SOURCE: fleet/deploy/lib/provision-lib.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — bibliothèque des modules : primitives convergentes, écriture atomique, verdicts réels
#
# Sourcée par CHAQUE module — qui sont des PROCESSUS SÉPARÉS, jamais un namespace partagé.
# (La v1 sourçait ses 9 modules dans UN shell sous `set -e` hérité : un chown en échec avortait
# TOUT le provisioning à mi-durcissement, et les compteurs globaux se marchaient dessus.)
#
# Contrat des primitives, les trois lois :
#   1. CONVERGENTES — elles amènent l'état déclaré et ne font RIEN s'il y est déjà.
#      Appliquer N fois = appliquer 1 fois, et re-converger vers la source COURANTE
#      (pas « append-once » : le .bashrc v1 gardait à jamais son premier état écrit).
#   2. VERDICT RÉEL — l'état est re-sondé APRÈS l'action, jamais déduit de l'intention.
#      (La v1 imprimait des `pass` inconditionnels par-dessus des setfacl étouffés en 2>/dev/null.)
#   3. ATOMIQUES — tout fichier est écrit tmp-même-dossier puis mv. Un crash ne laisse JAMAIS
#      un fichier tronqué. (La v1 écrivait /etc/sudoers.d et /etc/wsl.conf en place : un write
#      interrompu = lockout sudo fleet-wide / distro qui ne boote plus.)
#
# Toute mutation effective incrémente PROV_CHANGED (le module le rapporte en fin d'apply).
# Les commandes sont passées en ARGV, jamais en strings évaluées (le `bash -c "$fix_cmd"` v1
# interpolait des valeurs dans du code — injection dès qu'un chemin porte un métacaractère).

# Garde de double-source (un module qui se ferait sourcer deux fois ne doit pas ré-écraser l'état).
[[ -n "${PROVISION_LIB_LOADED:-}" ]] && return 0
PROVISION_LIB_LOADED=1

# ─── Données par défaut (chaque valeur est overridable par l'environnement — une SEULE définition,
#     consommée par les modules ; jamais re-défautée module par module comme en v1) ───────────────
# DOIT égaler le défaut d'etc/install.sh (SSoT du layout : etc/README.md §Install canonique —
# /local/fleet_v2 est MORT, renommé *.OBSOLETE le 2026-07-18). Un fait, deux rendus : sync à la main.
: "${PROV_PREFIX:=/local/LCARS_v2}"            # install RO du runtime (modèle 3 zones d'etc/install.sh)
: "${PROV_LINK_DIR:=/usr/local/bin}"           # symlinks PATH (miroir de LCARS_INSTALL_LINK_DIR d'install.sh)
: "${PROV_FLEET_GROUP:=fleet}"                 # groupe de lecture des tokens + de l'install RO
# ⚖ ARBITRAGE USER (2026-08-17) : « ADMIN » EST UN FAIT DE FORGE, PAS `uid 0`.
# `is_admin` cote Gitea dit qui administre le runtime — le deck le lit deja a chaque connexion
# (`console-deck.py`, porte OIDC). Le CLI, lui, gatait `catalogue install` sur root : or AUCUN
# humain n'est root et ne le sera. Le seul root est `admiral`, compte d'ADMINISTRATION SYSTEME —
# son metier est d'installer des paquets, pas des catalogues.
#
# Ce groupe est la PROJECTION Unix de ce fait, exactement comme `fleet` projette l'appartenance a
# la team `humans` : le convergeur d'humains l'ecrit, et il ouvre la lecture de l'autorite de la
# boite (jeton master, seed). La capacite reste le systeme de fichiers — jamais un booleen qu'un
# appelant pourrait oublier de tester.
: "${PROV_ADMIN_GROUP:=lcars-admin}"           # is_admin sur la forge -> administre le runtime
: "${PROV_CATALOGUES_WORK:=/var/lib/lcars/tofu}"  # recettes tofu par catalogue (etat = SENSIBLE)
: "${PROV_TOKENS_DIR:=/home/private}"          # role-tokens forge (contrat FORGE_ROLE_TOKENS_DIR)
: "${PROV_FORGE_SEED_FILE:=$PROV_TOKENS_DIR/forge-seed.pass}"  # seed bootstrap tofu (handoff → A4)
# L'AUTORITE DE CREATION, posee par `docker.sh config` et QUI RESTE (⚖ user 2026-08-16). Le suffixe
# n'est PAS `.gitea_token` : celui-la designe un jeton de ROLE (`<login>.gitea_token`, contrat
# FORGE_ROLE_TOKENS_DIR). Personne ne globbe ce repertoire aujourd'hui — le premier qui le fera ne
# doit pas ramasser un site-admin en croyant lire un role.
: "${PROV_MASTER_TOKEN_FILE:=$PROV_TOKENS_DIR/forge-master.token}"
# GRAINE du binaire vendor : un chemin où un binaire `claude` déjà présent SUR LA MACHINE
# court-circuite l'installeur officiel de 40-claude-bin (donc le réseau). Root-owned, hors de tout
# home — l'humain du runtime n'existe pas encore quand un semis extérieur le pose. Vide/absent =
# comportement inchangé : le module télécharge.
# QUATRIÈME liste de rôles du système (avec forge.tf, provision-role-tokens.sh, le catalogue
# cap-profiles) — et elle GAGNE : 50-forge passe --roles "$PROV_ROLES" au mint A4, écrasant le
# défaut du .sh. un producteur absent ICI = pas de token sur une fleet fraîche = rail ops en
# role_token_unavailable (la cause racine de BL-6-34 — vécu deux fois : eng_doc, puis son rename scribe). Le verrou
# d'égalité des listes est BL-6-45 ; d'ici sa dérivation, cette ligne se tient à la main.
: "${PROV_ROLES:=system_architect system_chief system_gatekeeper fleet_engineer fleet_scribe fleet_qualifier fleet_reviewer fleet_scoper fleet_vulcan}"
# LE MATERIEL DES CATALOGUES INSTALLES — miroir shell de `Fleet.Layout.catalogues_installed_dir/0`,
# verrouille par `catalogue.install_paths_locked` de `mix lcars.contracts.check`. Diverger d'avec le
# runtime ne casse rien : `45-catalogues` converge un repertoire que personne ne lit, et la boite
# tourne sur le catalogue livre en annonçant qu'elle en sert trois.
: "${PROV_CATALOGUES_DIR:=/home/catalogues}"
: "${PROV_SYSTEM_ACCOUNT:=lcars-system}"       # compte forge du SYSTÈME (signe les marqueurs)
: "${PROV_FORGE_ORG:=fleet}"                   # org qui porte les repos projet (forge.tf)
# La team d'ENROLEMENT, lue par le convergeur d'humains et par le deck. Elle n'avait pas de nom
# ici — elle vivait en `LCARS_HUMANS_TEAM` cote boite, seconde famille de variables pour un fait
# que ce fichier declare deja pour ses voisins (org, groupes). Un jeu de noms, un fait.
: "${PROV_HUMANS_TEAM:=humans}"                # team forge dont l'adhesion vaut enrolement
: "${PROV_FORGE_URL:=${FORGE_BASE_URL:-}}"     # la forge cible ; vide = modules forge en instruct-only
# LA FORGE A DEUX ADRESSES, ET LES CONFONDRE CASSE LA PORTE DU DECK. Celle du dessus est celle que
# le SERVEUR compose (dans un conteneur, le nom du service : `http://forge:3000`) ; celle-ci est
# celle qu'un NAVIGATEUR doit atteindre. Une seule valeur ne peut pas être les deux — `forge:3000`
# ne résout nulle part hors du réseau docker, et l'adresse de l'hôte peut ne pas résoudre dedans.
# Le défaut égale l'interne : sur une boîte où les deux coïncident, il n'y a rien à poser.
: "${PROV_FORGE_PUBLIC_URL:=${FORGE_PUBLIC_URL:-$PROV_FORGE_URL}}"
# Le deck de la BOÎTE (porte d'entrée, hors de l'espace des blocs humains) et son client OAuth2.
# Les ORIGINES sont les adresses par lesquelles on entre vraiment : OAuth2 compare le `redirect_uri`
# EXACTEMENT, donc une entrée non déclarée échoue au RETOUR, après l'identification, là où c'est le
# plus déroutant. La loopback est toujours incluse ; le reste se déclare.
: "${PROV_DECK_PORT:=20999}"
: "${PROV_DECK_OIDC_FILE:=/etc/lcars/deck-oidc.json}"
: "${PROV_DECK_ORIGINS:=${LCARS_DECK_ORIGINS:-}}"
# Jambe update du triangle (source→forge→runtime) : le remote à puller et le repo ATTENDU derrière.
# PROV_EXPECTED_REPO n'a PAS de défaut : l'autorité se DÉCLARE, elle ne se devine pas (héritage
# F-E1 de fleet-update v1 : vérifier le remote APRÈS le pull était une inversion de chaîne payée).
# Combien de lignes d'une commande en échec atterrissent à l'écran (le reste vit dans le fichier).
: "${PROV_DUMP_LINES:=40}"
: "${PROV_UPDATE_REMOTE:=origin}"
: "${PROV_EXPECTED_REPO:=}"
# Toolchain build — pins EXACTS (bump = changer la paire version+sha ICI, nulle part ailleurs).
# Le zip est le précompilé officiel elixir-lang (assets de release, sha256sum publié à côté).
: "${PROV_ELIXIR_VERSION:=1.18.4}"
: "${PROV_ELIXIR_OTP_MAJOR:=25}"
: "${PROV_ELIXIR_ZIP_SHA256:=04ecc784c59692ce15511fbba54638d947f0566f5baf69c6542d4bf2ea89cd1a}"
# L'humain cible des modules per-humain : celui qui a lancé (à travers sudo s'il y a lieu).
: "${PROV_HUMAN:=${SUDO_USER:-$(id -un)}}"

# ─── Verdicts / log ───────────────────────────────────────────────────────────────────────────────
# Préfixe = nom du module (posé par le runner via PROVISION_MODULE, sinon dérivé de $0).
# Doctrine log LCARS : le nominal est SILENCIEUX en succès de sonde, une ligne par état constaté ;
# l'échec est VERBEUX (dump complet). Compteurs agrégés par le module.
PROV_MODULE_TAG="${PROVISION_MODULE:-$(basename "${0:-provision-lib}")}"
PROV_CHANGED=0
PROV_DRIFT=0
PROV_FAILED=0

# ─── LA PALETTE — LA MÊME QUE CELLE DU BANDEAU D'ENTRÉE ─────────────────────────────────────────
#
# Le préflight de `install.sh` sortait en couleurs et le provisionnement en blanc : deux moitiés du
# même geste, dont celle qu'on regarde pendant vingt minutes était la terne. Les quatre teintes sont
# reprises telles quelles de l'en-tête (vert / cyan du cadre / ambre du bandeau / rouge).
#
# ⚠ LA COULEUR NE SORT QUE SUR UN TERMINAL. Une séquence ANSI dans un fichier de log, c'est du
# `[1;32m` au milieu du texte : illisible à la relecture et cassé au grep. `-t 1` tranche, `NO_COLOR`
# (convention de fait) coupe, et `PROV_COLOR=1` force pour un `script`/`unbuffer`.
#
# ⚠ ET LA COULEUR N'ENTOURE QUE L'ÉTIQUETTE, JAMAIS LE REMPLISSAGE. Les espaces qui suivent restent
# littéraux : une séquence ANSI compte des caractères et s'affiche sur zéro colonne, donc tout
# alignement qui l'inclurait se décalerait sans que personne ne le voie. Ici les six colonnes de
# l'étiquette sont tenues par des espaces nus, et il n'y a rien à réaligner.
if [[ -n "${NO_COLOR:-}" ]]; then PROV_COLOR=0
elif [[ -n "${PROV_COLOR:-}" ]]; then :
elif [[ -t 1 ]]; then PROV_COLOR=1
else PROV_COLOR=0
fi
if [[ "$PROV_COLOR" -eq 1 ]]; then
  _PG=$'\033[1;32m'; _PC=$'\033[0;36m'; _PA=$'\033[38;5;214m'; _PR=$'\033[1;31m'; _PN=$'\033[0m'
else
  _PG=''; _PC=''; _PA=''; _PR=''; _PN=''
fi

# UNE ACTION LONGUE ET MUETTE N'EST PAS DISCERNABLE D'UN BLOCAGE. `60-deploy` construit la release
# — gate complet compris — et `run_quiet` n'imprime rien pendant plusieurs minutes : l'écran est
# figé, et la seule interprétation disponible est « c'est planté ». La v1 n'a jamais eu ce problème
# parce que sa plus longue action durait trente secondes ; elle annonçait un résultat PAR OBJET
# (`package:tmux — installed`). Un `mix gate` n'a pas d'objets à égrener : il lui faut donc ce que
# la v1 n'avait pas besoin d'avoir — dire ce qui commence, avant de dire comment ça s'est terminé.
# Les six colonnes de l'étiquette sont tenues en ASCII pur, pour la même raison que les autres.
p_step() { printf '%s>>%s    %s: %s\n' "$_PC" "$_PN" "$PROV_MODULE_TAG" "$*"; }
p_ok()   { printf '%sOK%s    %s: %s\n' "$_PG" "$_PN" "$PROV_MODULE_TAG" "$*"; }
p_chg()  { printf '%sPOSÉ%s  %s: %s\n' "$_PC" "$_PN" "$PROV_MODULE_TAG" "$*"; }
p_drift(){ printf '%sDRIFT%s %s: %s\n' "$_PA" "$_PN" "$PROV_MODULE_TAG" "$*" >&2; PROV_DRIFT=$((PROV_DRIFT + 1)); }
p_warn() { printf '%sWARN%s  %s: %s\n' "$_PA" "$_PN" "$PROV_MODULE_TAG" "$*" >&2; }
p_fail() { printf '%sFAIL%s  %s: %s\n' "$_PR" "$_PN" "$PROV_MODULE_TAG" "$*" >&2; PROV_FAILED=$((PROV_FAILED + 1)); }
p_die()  { PROV_VERDICT_RENDERED=1; printf '%sFATAL%s %s: %s\n' "$_PR" "$_PN" "$PROV_MODULE_TAG" "$*" >&2; exit 1; }

# Sortie standard d'un module : à appeler en FIN de check() et d'apply().
# check  : exit 0 conforme · 1 drift constaté · (2 réservé erreur de sonde, via p_die)
# apply  : exit 0 convergé · 1 au moins un échec
# ─── UN MODULE QUI MEURT DOIT LE DIRE LUI-MEME ──────────────────────────────────────────────────
#
# Mesure du 2026-08-18, banc lcars-l8 : `70-human` sondait `root`, imprimait trois lignes DRIFT
# justes, puis MOURAIT — `pipefail` sur un `sed` d'un `fleet_v2.env` absent, rc 2, avant tout
# verdict. Le doctor affichait « échecs: 1 » sans nommer personne. Pire du cote apply : rc 2 y
# signifie « appliqué, drift résiduel », donc le bilan disait « rien n'est cassé, il manque un
# geste » sur un module qui n'avait pas fini de tourner.
#
# Le runner ne peut pas distinguer ces deux 2 : c'est le meme entier. Le module, lui, SAIT s'il a
# rendu son verdict. Il le dit, et il rend un code qui n'appartient qu'a ce cas.
#
# ⚠ La garde n'est armee que sous le RUNNER (`PROVISION_RUN`). Un extrait qui source cette lib pour
# appeler une primitive — les temoins bats — n'est pas un module et n'a aucun verdict a rendre.
PROV_VERDICT_RENDERED=0
_prov_exit_guard() {
  local rc=$?
  [[ "$PROV_VERDICT_RENDERED" -eq 1 ]] && return 0
  printf '%sERREUR%s %s: MORT avant de rendre son verdict (rc=%d) — aucune ligne ci-dessus ne le dit, faute de temps\n' \
    "$_PR" "$_PN" "$PROV_MODULE_TAG" "$rc" >&2
  exit 3
}
[[ -n "${PROVISION_RUN:-}" ]] && trap _prov_exit_guard EXIT

verdict_check() {
  PROV_VERDICT_RENDERED=1
  if [[ "$PROV_FAILED" -gt 0 ]]; then exit 2; fi
  [[ "$PROV_DRIFT" -gt 0 ]] && exit 1
  exit 0
}
# ⚠ LE COMPTEUR DE DRIFT N'ETAIT PAS LU, ET LE RESUME MENTAIT DEUX FOIS. Un module dont l'`apply`
# constate une non-convergence (`p_drift`) puis rend ce verdict sortait **0** : le runner le comptait
# « convergé », et sa ligne de bilan affichait « drift: 0 » alors qu'une ligne DRIFT venait d'etre
# imprimee. MESURE 2026-08-14 sur un module bac-a-sable : `EXIT 0`, « conformes/convergés: 1 ·
# drift: 0 ». Deux modules vivants portent exactement cette forme (`50-forge`, `55-deck-oidc`).
#
# ⚠ ET CE N'EST PAS LE SITE QUE LA FICHE NOMME. `00-preflight` termine par `verdict_check`, qui sort
# 1 sur drift, et le runner mappe `apply:apply:*` non-zero en echec : ce chemin-la etait deja juste,
# mesure. Le defaut vit un cran a cote, dans les modules qui rendent un verdict d'APPLY.
#
# Code **2** = « applique, drift residuel » : ni 0 (ce serait le mensonge qu'on retire) ni 1 (ce
# serait confondre « je n'ai pas pu converger » avec « j'ai casse »). L'operateur a besoin des deux
# mots, et l'entrypoint conteneur les distingue desormais dans son message.
verdict_apply() {
  PROV_VERDICT_RENDERED=1
  [[ "$PROV_FAILED" -gt 0 ]] && exit 1
  [[ "$PROV_DRIFT" -gt 0 ]] && exit 2
  exit 0
}

# ─── run_quiet — succès silencieux, échec verbeux (l'école mail-in-a-box `hide_output`) ──────────
# La commande est un ARGV. En échec : la commande, son code, et TOUTE sa sortie sont dumpés.
# Rien n'est jamais étouffé en 2>/dev/null (le silence v1 cachait des perms cassées).
run_quiet() {
  local out rc=0
  # `--verbose` (PROV_VERBOSE=1) : on ne capture RIEN, tout défile. C'est le mode de celui qui
  # regarde une étape qui traîne et veut savoir sur quoi — pas le mode nominal, qui doit rester
  # lisible par un humain. Le verdict, lui, ne change pas : un échec compte pareil.
  if [[ "${PROV_VERBOSE:-0}" -eq 1 ]]; then
    "$@" || rc=$?
    [[ "$rc" -eq 0 ]] || p_fail "commande en échec (rc=$rc) : $*"
    return "$rc"
  fi
  out="$(mktemp "${TMPDIR:-/tmp}/prov-out.XXXXXX")"
  "$@" >"$out" 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    # B1 : l'échec COMPTE — via p_fail, qui incrémente PROV_FAILED. L'ancien printf nu laissait
    # les compteurs à zéro : `run_quiet x || verdict_apply` sortait 0 (« convergé ») alors que
    # x avait échoué — le verdict vert menteur, exactement le péché v1 que cette lib jure de tuer.
    p_fail "commande en échec (rc=$rc) : $*"
    # ⚠ BORNÉ À L'ÉCRAN, ENTIER SUR LE DISQUE — et l'ancienne forme faisait exactement l'inverse.
    # Elle déversait TOUT puis supprimait le fichier : mesure du 2026-08-18, l'install native sur
    # une Ubuntu neuve a craché 3 300 lignes de log de suite ExUnit dans le terminal, et l'unique
    # copie partait au `rm` de la ligne suivante. Illisible sur le moment, irrécupérable après.
    # La queue porte le verdict (« gate: the ExUnit suite FAILED ») ; le détail vit dans le fichier,
    # qu'on NOMME et qu'on garde. Un échec est une pièce à conviction, pas un tas à balayer.
    local n; n="$(wc -l < "$out")"
    {
      printf '───── sortie : %s dernières lignes sur %s ─────\n' "$PROV_DUMP_LINES" "$n"
      tail -n "$PROV_DUMP_LINES" "$out"
      printf '───── sortie COMPLÈTE conservée : %s ─────\n' "$out"
    } >&2
    return "$rc"
  fi
  rm -f "$out"
  return 0
}

# ─── prov_parse_remote <url> — normalise un remote git en `host/owner/repo`, ou REFUSE ───────────
#
# CE QUE REMPLACE CETTE FONCTION (6-109), et c'etait une prise root en une ligne :
#
#     case "$REMOTE_URL" in *"$PROV_EXPECTED_REPO"*) ;; *) die ;; esac
#
# Une SOUS-CHAINE. Avec `PROV_EXPECTED_REPO=fleet/lcars`, l'URL
# `https://host-de-l-attaquant/attaquant/fleet/lcars-malware.git` la contient — donc l'autorite est
# satisfaite, `git pull --ff-only` tire, et `exec "$SELF" apply` execute ce code EN ROOT. Ni l'hote,
# ni le proprietaire, ni la fin du nom du depot n'etaient regardes.
#
# Trois formes admises, ramenees au MEME triplet ; tout le reste est refuse :
#   * `https://host[:port]/owner/repo[.git]`
#   * `ssh://[user@]host[:port]/owner/repo[.git]`
#   * `[user@]host:owner/repo[.git]`  (forme scp, celle que `git@` utilise)
#
# ⚠ USERINFO REFUSE sur les formes a schema : un remote qui embarque `user:token@` fait de
# l'autorite de mise a jour un porteur de secret, et c'est aussi la ou se glisse la confusion
# `https://fleet/lcars@ailleurs/...`. La forme scp garde son utilisateur NU (`git@host`) : c'est sa
# syntaxe normale, pas un credential, et refuser la rendrait inutilisable.
#
# Le chemin doit avoir EXACTEMENT deux segments : `owner/repo`. Un segment de plus, c'est le
# `attaquant/fleet/lcars` de l'attaque ; un de moins, ce n'est pas un depot.
prov_parse_remote() {
  local url="$1" rest host path owner repo

  case "$url" in
    *://*)
      rest="${url#*://}"
      ;;
    *:*/*)
      # scp : `[user@]host:owner/repo`. Le `:` separe l'hote du chemin ; on le remplace par `/`
      # pour rejoindre la forme commune.
      rest="${url%%:*}/${url#*:}"
      ;;
    *)
      return 1
      ;;
  esac

  # UNE SEULE REGLE POUR LES DEUX FORMES, et c'est la bonne : on refuse un userinfo qui porte un
  # MOT DE PASSE (`user:token@`), on accepte l'utilisateur NU. `git@host` et `ssh://git@host` sont
  # la syntaxe normale de SSH — les refuser rendrait tout remote SSH inutilisable, ce qui est un
  # mur, pas une garde. Un remote qui embarque un secret, lui, fait de l'autorite de mise a jour un
  # porteur de credential.
  case "${rest%%/*}" in
    *:*@*) return 1 ;;
  esac
  rest="${rest#*@}"

  host="${rest%%/*}"
  path="${rest#*/}"
  host="${host%%:*}"       # port ignore : il ne change pas QUI l'on contacte
  host="${host,,}"         # les hotes sont insensibles a la casse, les chemins non
  path="${path%.git}"
  path="${path%/}"

  [[ -n "$host" && "$path" == */* ]] || return 1
  owner="${path%%/*}"
  repo="${path#*/}"
  [[ -n "$owner" && -n "$repo" && "$repo" != */* ]] || return 1

  printf '%s/%s/%s\n' "$host" "$owner" "$repo"
}

# ─── prov_lock_path — LE chemin du verrou apply/update, dans un dossier que personne d'autre ─────
#     n'ecrit.
#
# CE QU'IL ETAIT, et pourquoi c'etait une prise root (6-130) : `${TMPDIR:-/tmp}/lcars-provision.$(id
# -u).lock`. Sous `sudo`, `id -u` vaut 0, donc le nom est FIXE et devinable :
# `/tmp/lcars-provision.0.lock`. `/tmp` est inscriptible par tout le monde, et `exec 9>"$LOCK"` SUIT
# les liens et TRONQUE la cible — avant que `flock` n'ait protege quoi que ce soit. Un utilisateur
# local pose ce nom en lien vers un fichier root et le prochain `sudo provision apply` le vide.
#
# Deux dossiers, un par identite, et aucun des deux n'est ecrivable par un tiers :
#   * root      → `/run/lock/lcars`, cree root:root 0700. `/run/lock` est un tmpfs du systeme.
#   * non-root  → `$XDG_RUNTIME_DIR/lcars` (0700 par construction, propriete de l'utilisateur), ou
#                 `/run/user/<uid>/lcars` a defaut. `apply` peut tourner sans root quand aucun
#                 module selectionne ne mute — ce cas a besoin d'un verrou lui aussi.
#
# ⚠ `TMPDIR` N'EST PLUS HONORE, et c'est la moitie de la fiche : une variable d'environnement
# preservee a travers `sudo` deplacerait le verrou dans un dossier que l'appelant choisit. Un verrou
# privilegie dont l'emplacement est un parametre de l'appelant n'est pas un verrou.
#
# ECHEC = ARRET. Se rabattre sur `/tmp` serait re-ecrire le bug avec un commentaire qui dit qu'on ne
# le fait pas.
prov_lock_path() {
  local dir uid
  uid="$(id -u)"

  if [[ "$uid" -eq 0 ]]; then
    dir=/run/lock/lcars
  else
    dir="${XDG_RUNTIME_DIR:-/run/user/$uid}/lcars"
  fi

  prov_refuse_symlink_path "$dir" || return 1

  # LE PARENT DOIT DEJA EXISTER, on ne le fabrique pas. `/run/lock` et `/run/user/<uid>` sont
  # poses par le systeme ; les creer nous-memes les creerait au umask courant — et `mkdir -p -m`
  # n'applique son mode qu'au DERNIER composant (SC2174), donc le trou serait exactement celui
  # qu'on vient de fermer, un cran plus haut. Absent = environnement anormal, on le DIT.
  local parent="${dir%/*}"
  [[ -d "$parent" ]] || { p_fail "verrou: $parent absent — pas d'emplacement sur pour un verrou"; return 1; }
  mkdir -p "$dir" || { p_fail "verrou: dossier impossible: $dir"; return 1; }
  chmod 0700 "$dir" || { p_fail "verrou: chmod 0700 refuse: $dir"; return 1; }

  # Re-verifie APRES : un dossier deja la avec un autre proprietaire ou d'autres permissions
  # passerait sinon sans que rien ne le dise.
  local owner mode
  owner="$(stat -c '%u' "$dir")" || { p_fail "verrou: stat impossible: $dir"; return 1; }
  mode="$(stat -c '%a' "$dir")" || { p_fail "verrou: stat impossible: $dir"; return 1; }
  [[ "$owner" == "$uid" ]] || { p_fail "verrou: $dir appartient a l'uid $owner, pas a $uid"; return 1; }
  [[ "$mode" == "700" ]] || { p_fail "verrou: $dir est en $mode, attendu 700"; return 1; }

  local lock="$dir/provision.lock"
  # Le dossier est desormais prouve non-ecrivable par un tiers ; un lien A L'INTERIEUR ne peut donc
  # venir que de nous-memes ou d'un root anterieur. On le refuse quand meme : cette verification-la
  # coute un `[[ -L ]]` et c'est la seule qui reste entre `flock` et une troncature.
  [[ -L "$lock" ]] && { p_fail "verrou: $lock est un symlink — REFUSE"; return 1; }

  printf '%s\n' "$lock"
}

# ─── prov_refuse_symlink_path <chemin absolu> — LA garde des mutations privilegiees ──────────────
#
# CE QUI ARRIVE SANS ELLE, mesure sur 6-131 : `ensure_dir` tenait un symlink-vers-dossier pour un
# dossier (`[[ -d ]]` suit les liens), puis `stat`/`chmod`/`chown` suivaient la cible. Le module WSL
# applique ces helpers, EN ROOT, a `$HOME/.config` de l'humain — donc l'humain vise pose
# `~/.config -> /etc` et le prochain `sudo provision apply` lui donne `/etc`. Meme forme pour
# n'importe quel dossier root atteignable par un lien qu'il controle.
#
# ON REFUSE, ON NE RESOUT PAS. Un `readlink -f` suivi de l'operation serait le meme bug avec une
# etape de plus : la resolution et la mutation ne sont pas atomiques, et c'est exactement ce que la
# fiche interdit de faire passer pour un correctif. Refuser n'a pas de fenetre a gagner : il n'y a
# rien a devancer, le chemin est declare inapte.
#
# ⚠ CE QUE CETTE GARDE NE FAIT PAS, et il faut le savoir en la lisant : elle ne supprime pas le
# TOCTOU, elle le reduit a une COURSE. Pre-poser un lien et attendre le prochain `apply` ne marche
# plus ; le glisser entre notre `lstat` et notre `chmod` marche encore, et fermer ca demanderait des
# descripteurs `openat(O_NOFOLLOW)` que bash n'a pas. C'est la limite honnete de ce langage a cet
# endroit, et la remonter voudrait dire sortir le provisioning de bash.
#
# Le chemin est parcouru COMPOSANT PAR COMPOSANT : un lien au milieu (`~/.config` -> ailleurs) est
# aussi dangereux que le dernier, et c'est justement celui-la que l'attaque de la fiche utilise.
prov_refuse_symlink_path() {
  local path="$1" cur="" part
  local -a parts

  [[ "$path" == /* ]] || {
    p_fail "mutation privilegiee REFUSEE — chemin relatif: $path"
    return 1
  }

  # `read -ra` et non une boucle sur une expansion nue : un composant qui contiendrait `*` serait
  # sinon globbe, donc le chemin verifie ne serait pas le chemin mute.
  IFS='/' read -ra parts <<< "${path#/}"

  for part in "${parts[@]}"; do
    [[ -z "$part" ]] && continue
    cur="$cur/$part"
    if [[ -L "$cur" ]]; then
      p_fail "mutation privilegiee REFUSEE — composant symlink: $cur -> $(readlink "$cur")"
      return 1
    fi
  done

  return 0
}

# ─── write_atomic <dest> <mode> [owner:group] — LE primitif fichier ──────────────────────────────
# Contenu lu sur stdin. tmp dans le MÊME dossier (mv intra-FS = rename atomique), mode/owner posés
# sur le tmp AVANT le mv (le fichier n'existe jamais dans un état intermédiaire). Si le contenu,
# le mode ET l'owner sont déjà conformes : aucune écriture (mtime préservé, verdict OK).
write_atomic() {
  local dest="$1" mode="$2" owner="${3:-}"
  local dir tmp
  prov_refuse_symlink_path "$dest" || return 1
  dir="$(dirname "$dest")"
  [[ -d "$dir" ]] || { p_fail "write_atomic: dossier absent: $dir"; return 1; }
  tmp="$(mktemp "$dir/.prov.XXXXXX")" || { p_fail "write_atomic: tmp impossible dans $dir"; return 1; }
  cat > "$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    ensure_mode "$dest" "$mode" "$owner"   # le contenu est bon ; mode/owner convergés à part
    return $?
  fi
  chmod "$mode" "$tmp" || { rm -f "$tmp"; p_fail "write_atomic: chmod $mode: $dest"; return 1; }
  if [[ -n "$owner" ]]; then
    chown "$owner" "$tmp" || { rm -f "$tmp"; p_fail "write_atomic: chown $owner: $dest"; return 1; }
  fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; p_fail "write_atomic: mv final: $dest"; return 1; }
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "$dest"
}

# ─── ensure_mode <path> <mode> [owner:group] — converge mode/owner, verdict par re-stat ──────────
# Compare AVANT d'agir (pas de chmod aveugle qui rafraîchit les ctime à chaque run), re-sonde APRÈS.
ensure_mode() {
  local path="$1" mode="$2" owner="${3:-}"
  local cur_mode cur_owner want_owner changed=0
  # AVANT le test d'existence, pas apres : `[[ -e ]]` est faux sur un lien casse, donc un symlink
  # pose comme piege serait rapporte « absent » — le bon diagnostic est « lien », et c'est celui-la
  # qui dit a l'operateur ce qu'il regarde.
  prov_refuse_symlink_path "$path" || return 1
  [[ -e "$path" ]] || { p_fail "ensure_mode: absent: $path"; return 1; }
  cur_mode="$(stat -c '%a' "$path")"
  # stat rend le mode SANS zéro de tête ; on normalise la cible pareil (0750 → 750).
  local want_mode="${mode#0}"
  if [[ "$cur_mode" != "$want_mode" ]]; then
    chmod "$mode" "$path" || { p_fail "ensure_mode: chmod $mode refusé: $path"; return 1; }
    changed=1
  fi
  if [[ -n "$owner" ]]; then
    cur_owner="$(stat -c '%U:%G' "$path")"
    want_owner="$owner"
    if [[ "$cur_owner" != "$want_owner" ]]; then
      chown "$owner" "$path" || { p_fail "ensure_mode: chown $owner refusé: $path"; return 1; }
      changed=1
    fi
  fi
  # Verdict réel : re-stat.
  cur_mode="$(stat -c '%a' "$path")"
  [[ "$cur_mode" == "$want_mode" ]] || { p_fail "ensure_mode: mode $cur_mode ≠ $want_mode après chmod: $path"; return 1; }
  if [[ "$changed" -eq 1 ]]; then PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "perms $mode ${owner:+$owner }$path"; fi
  return 0
}

# ─── ensure_dir <path> <mode> [owner:group] ──────────────────────────────────────────────────────
ensure_dir() {
  local path="$1" mode="$2" owner="${3:-}"
  # `[[ -d ]]` SUIT LES LIENS : sans cette garde, un symlink-vers-dossier passait pour un dossier
  # convergé et `ensure_mode` chownait sa CIBLE (6-131). Un composant qui n'existe pas encore n'est
  # pas un lien, donc la creation nominale traverse la garde sans la voir.
  prov_refuse_symlink_path "$path" || return 1
  if [[ ! -d "$path" ]]; then
    mkdir -p "$path" || { p_fail "ensure_dir: mkdir refusé: $path"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "dir $path"
  fi
  ensure_mode "$path" "$mode" "$owner"
}

# ─── ensure_group / ensure_member — création idempotente (le pattern propre de provision-groups v1) ─
ensure_group() {
  local grp="$1"
  if ! getent group "$grp" >/dev/null; then
    run_quiet groupadd "$grp" || return 1
    getent group "$grp" >/dev/null || { p_fail "groupe $grp absent après groupadd"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "groupe $grp"
  fi
}

# Les membres d'un groupe, secondaires ET primaires — `getent group` ne liste que les premiers, et
# un humain dont le groupe d'admin serait primaire aurait disparu du rapport.
members_of() {
  local grp="$1" sec
  sec="$(getent group "$grp" 2>/dev/null | cut -d: -f4 | tr ',' ' ')"
  printf '%s' "${sec:-aucun}"
}

ensure_member() {
  local user="$1" grp="$2"
  id "$user" >/dev/null 2>&1 || { p_fail "ensure_member: user inconnu: $user"; return 1; }
  if ! id -nG "$user" | tr ' ' '\n' | grep -qx "$grp"; then
    run_quiet usermod -aG "$grp" "$user" || return 1
    id -nG "$user" | tr ' ' '\n' | grep -qx "$grp" || { p_fail "$user toujours hors de $grp après usermod"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1))
    # usermod -aG ne prend effet qu'au PROCHAIN login (dette de guerre v1) : on le DIT.
    p_chg "$user ∈ $grp (effectif au prochain login — ou « sg $grp -c '<cmd>' » dans cette session)"
  fi
}

# ─── ensure_symlink <link> <target> — convergent (remplace un lien faux, refuse d'écraser un vrai fichier) ─
ensure_symlink() {
  local link="$1" target="$2"
  # LA GARDE PORTE SUR LE PARENT, jamais sur `$link` : ce verbe CREE un lien, exiger que le dernier
  # composant n'en soit pas un lui interdirait son propre travail. Ce qui doit rester vrai, c'est
  # que le REPERTOIRE ou on le pose n'a pas ete deplace sous nous par un lien (6-131).
  prov_refuse_symlink_path "$(dirname "$link")" || return 1
  if [[ -L "$link" ]]; then
    [[ "$(readlink "$link")" == "$target" ]] && return 0
  elif [[ -e "$link" ]]; then
    p_fail "ensure_symlink: $link existe et n'est PAS un symlink — refus d'écraser (retire-le explicitement)"
    return 1
  fi
  ln -sfn "$target" "$link" || { p_fail "ensure_symlink: ln refusé: $link"; return 1; }
  [[ "$(readlink "$link")" == "$target" ]] || { p_fail "ensure_symlink: cible inattendue après ln: $link"; return 1; }
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "$link → $target"
}

# ─── ensure_managed_block <file> <marker> <mode> [owner:group] — bloc géré BEGIN/END ─────────────
# Contenu du bloc sur stdin. Le bloc ENTRE marqueurs est REMPLACÉ intégralement à chaque run →
# converge vers la source COURANTE. (Le grep-marker+append v1 convergeait vers le PREMIER état
# écrit : un bloc corrigé dans le source ne se réparait jamais chez l'installé.) Tout ce qui est
# HORS marqueurs est préservé octet pour octet (l'humain garde la main sur SON fichier).
ensure_managed_block() {
  local file="$1" marker="$2" mode="$3" owner="${4:-}"
  local begin="# >>> lcars:${marker} >>> (bloc géré par deploy — édition manuelle écrasée au prochain apply)"
  local end="# <<< lcars:${marker} <<<"
  local block existing
  block="$(cat)"
  existing=""
  [[ -f "$file" ]] && existing="$(awk -v b="# >>> lcars:${marker} >>>" -v e="$end" '
      index($0, b) == 1 {skip=1; next}
      $0 == e            {skip=0; next}
      !skip              {print}
    ' "$file")"
  # B3 : write_atomic se nourrit par REDIRECTION, jamais par pipe — le membre droit d'un pipe
  # est un sous-shell : ses compteurs (PROV_FAILED/PROV_CHANGED) mouraient avec lui, et un
  # fichier non posé se rapportait vert.
  local tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/prov-block.XXXXXX")" || { p_fail "ensure_managed_block: tmp impossible"; return 1; }
  {
    if [[ -n "$existing" ]]; then printf '%s\n' "$existing"; fi
    printf '%s\n%s\n%s\n' "$begin" "$block" "$end"
  } > "$tmp"
  write_atomic "$file" "$mode" "$owner" < "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

# ─── fetch_verify <url> <sha256> <dest> <mode> — download pinné obligatoire ──────────────────────
# JAMAIS de download direct vers la destination (le yq v1 se téléchargeait EN PLACE : un curl
# tronqué laissait un binaire cassé installé). Mismatch = dump attendu-vs-trouvé + rm + échec
# (le workflow de bump : changer le pin, lancer, copier le sha réel depuis le message).
fetch_verify() {
  local url="$1" sha="$2" dest="$3" mode="$4"
  local dir tmp actual
  dir="$(dirname "$dest")"
  tmp="$(mktemp "$dir/.fetch.XXXXXX")" || { p_fail "fetch_verify: tmp impossible dans $dir"; return 1; }
  if ! run_quiet curl -fsSL --proto '=https' -m 300 -o "$tmp" "$url"; then
    rm -f "$tmp"; p_fail "fetch_verify: download raté: $url"; return 1
  fi
  actual="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$actual" != "$sha" ]]; then
    rm -f "$tmp"
    p_fail "fetch_verify: sha256 MISMATCH pour $url"
    p_fail "  attendu : $sha"
    p_fail "  trouvé  : $actual"
    return 1
  fi
  if ! { chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"; }; then
    rm -f "$tmp"; p_fail "fetch_verify: pose finale ratée: $dest"; return 1
  fi
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "$dest (sha256 vérifié)"
}

# ─── apt_ensure <pkg…> — le pattern MISSING-array v1 (le bon), avec verdict réel par paquet ──────
apt_ensure() {
  local missing=() pkg
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  [[ "${#missing[@]}" -eq 0 ]] && return 0
  p_chg "apt: install ${missing[*]}"
  run_quiet env DEBIAN_FRONTEND=noninteractive apt-get update -qq || return 1
  run_quiet env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" || return 1
  local rc=0
  for pkg in "${missing[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || { p_fail "apt: $pkg toujours absent après install"; rc=1; }
  done
  [[ "$rc" -eq 0 ]] && PROV_CHANGED=$((PROV_CHANGED + 1))
  return "$rc"
}

# ─── Substrat ─────────────────────────────────────────────────────────────────────────────────────
# docker : /.dockerenv (posé par le runtime Docker) ou LCARS_DOCKER=1 (posé par notre image).
# wsl    : kernel Microsoft. linux : le reste. La détection vit ICI, une fois (v1 la recopiait).
detect_substrate() {
  if [[ -f /.dockerenv || "${LCARS_DOCKER:-}" == "1" ]]; then echo docker
  elif grep -qi microsoft /proc/version 2>/dev/null; then echo wsl
  else echo linux
  fi
}

# ─── PAR QUELLE ADRESSE CETTE MACHINE EST-ELLE ATTEINTE DU DEHORS ? ─────────────────────────────
#
# ⚠ CE N'EST PAS LA MÊME QUESTION QUE « quelle est mon IP », et c'est le substrat qui les sépare.
#
# La forme historique — `ip route get 1.1.1.1`, l'adresse SOURCE utilisée pour sortir — répond
# « par où je pars », et on la lisait comme « par où on m'atteint ». Les deux coïncident sur une
# machine posée sur son LAN. Sous WSL2 en mode NAT, elles ne coïncident pas :
#
#   · l'eth0 de la VM (172.25.115.129/20 ici) vit sur un commutateur Hyper-V NATé. AUCUNE autre
#     machine ne la route — pas « pare-feu à ouvrir » : pas de route, par construction ;
#   · elle est RÉATTRIBUÉE à chaque redémarrage de WSL, donc même juste, elle périme seule ;
#   · ce qui marche depuis Windows, c'est `localhost` : WSL relaie les ports publiés vers la VM.
#
# Mesure du 2026-08-18 (ce poste, `wslinfo --networking-mode` = nat) : le banc annonçait
# `172.25.115.129:20999`, le navigateur arrivait en `localhost:20999`, et la porte du deck refusait
# — correctement — une entrée non déclarée. L'adresse annoncée était fausse depuis le début ; c'est
# le premier accès par le navigateur de l'hôte qui l'a dit.
#
# Le mode miroir (`--networking-mode mirrored`) supprime le NAT : la VM porte alors les interfaces
# de l'hôte et `ip route get` redevient vrai. Le discriminant est donc le MODE, pas « est-ce WSL ».
#
# ⚖ ARBITRAGE USER 2026-08-18 : sous WSL on RESTE host-only, et ce n'est pas un pis-aller. Le NAT
# est le défaut de WSL et de Docker Desktop — donc l'état de presque tous les postes Windows — et
# l'ouvrir sur le LAN demanderait de reconfigurer la pile réseau Hyper-V de la machine. Ce substrat
# est celui du test/dev ; la cible d'un déploiement joignable 24/7 sur le LAN, c'est le Linux natif,
# où la dérivation nominale donne la vraie adresse et où il n'y a rien à régler. Quelqu'un qui a
# déjà tuné son réseau saura le retuner : `--advertise` est là pour ça, et il n'est pas ignoré.
PROV_ADVERTISE=""
PROV_ADVERTISE_WHY=""

wsl_networking_mode() {
  local m
  m="$(wslinfo --networking-mode 2>/dev/null | tr -d '[:space:]')"
  # `wslinfo` absent = WSL antérieur au mode miroir. Il n'existait alors QUE le NAT : c'est un fait
  # de version, pas une supposition de repli.
  [[ -n "$m" ]] && { echo "$m"; return 0; }
  echo nat
}

# L'adresse source de sortie — vide si indéterminable. Vraie SEULEMENT là où on est joignable par
# elle : `advertise_addr` en est le seul appelant légitime.
lan_addr() { ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1; }

# advertise_addr <bind> — POSE DEUX GLOBALES, N'IMPRIME RIEN :
#   PROV_ADVERTISE      l'adresse à ANNONCER (ROOT_URL, redirect_uri, liens du récap)
#   PROV_ADVERTISE_WHY  vide si c'est une vraie adresse de réseau ; sinon la phrase qui dit ce
#                       qu'elle vaut. Un appelant qui l'ignore annonce sans savoir ce qu'il annonce.
#
# ⚠ POURQUOI DEUX GLOBALES ET PAS UN `echo` — c'est un piège de langage, pas un goût. Un appelant
# écrit naturellement `a="$(advertise_addr ...)"`, or `$( )` ouvre un SOUS-SHELL : la valeur revient
# par stdout, et TOUTE variable posée dedans meurt avec lui. La forme « j'imprime l'un, je pose
# l'autre » perd donc silencieusement le second — mesuré ici même en écrivant cette fonction.
advertise_addr() {
  local bind="${1:-0.0.0.0}"
  PROV_ADVERTISE=""; PROV_ADVERTISE_WHY=""
  case "$bind" in
    0.0.0.0|::|"*") ;;
    # Un bind précis EST l'adresse : rien à dériver, et la dérivation se tromperait.
    *) PROV_ADVERTISE="$bind"; return 0 ;;
  esac
  if [[ "$(detect_substrate)" == "wsl" && "$(wsl_networking_mode)" == "nat" ]]; then
    PROV_ADVERTISE="localhost"
    PROV_ADVERTISE_WHY="WSL2 en mode NAT (le défaut) — l'adresse de la VM n'est routée depuis aucune autre machine et change à chaque redémarrage de WSL ; localhost est le relais que Windows tient vers elle. Sous ce substrat, un déploiement est joignable de CETTE machine et pas du LAN : c'est du test/dev, et l'ouvrir demanderait de toucher au réseau Hyper-V du poste."
    return 0
  fi
  PROV_ADVERTISE="$(lan_addr)"
  if [[ -z "$PROV_ADVERTISE" ]]; then
    PROV_ADVERTISE="127.0.0.1"
    PROV_ADVERTISE_WHY="aucune adresse de sortie détectée — les liens ne valent que sur cette machine"
  fi
  # ⚠ `return 0` EXPLICITE. Sans lui, la fonction rend le code du dernier `if` — donc 1 quand la
  # dérivation a RÉUSSI (le test `-z` est faux). Tous les appelants tournent sous `set -e` : un
  # succès y avortait le script. Trouvé par le témoin « n'imprime rien », sur le chemin linux —
  # celui qu'aucun appel de cette machine ne prend.
  return 0
}

# ─── as_human <cmd…> — exécute comme PROV_HUMAN avec le HOME de PROV_HUMAN ───────────────────────
# Depuis root : runuser + env EXPLICITE (runuser sans -l garde le HOME de root — piège classique).
# Déjà cet utilisateur : exécution directe. Autre user non-root : impossible proprement → échec dit.
as_human() {
  local home
  # `|| true` : même classe que B5 — sous pipefail, getent sur un user inconnu ferait échouer
  # l'assignation avant la garde p_fail juste en dessous.
  home="$(getent passwd "$PROV_HUMAN" | cut -d: -f6 || true)"
  [[ -n "$home" ]] || { p_fail "as_human: user inconnu: $PROV_HUMAN"; return 1; }
  if [[ "$(id -un)" == "$PROV_HUMAN" ]]; then
    "$@"
  elif [[ "$EUID" -eq 0 ]]; then
    runuser -u "$PROV_HUMAN" -- env HOME="$home" USER="$PROV_HUMAN" LOGNAME="$PROV_HUMAN" "$@"
  else
    p_fail "as_human: je suis $(id -un), pas root ni $PROV_HUMAN — relance en root"
    return 1
  fi
}

# home de PROV_HUMAN (vide si inconnu — l'appelant DOIT tester). B5 : `|| true`, sinon sous
# `set -euo pipefail` (tous les modules) un user inconnu tue l'assignation `home="$(human_home)"`
# AVANT la garde p_fail de l'appelant — abort muet, le contrat « vide si inconnu » était un mensonge.
human_home() { getent passwd "$PROV_HUMAN" | cut -d: -f6 || true; }

# ─── is_fleet_human [login] — celui-ci peut-il faire tourner une fleet ? ───────────────────────────
#
# ⚠ TOUS LES `# NEEDS: human` NE PARLENT PAS DU MÊME HUMAIN. L'entrypoint conteneur joue le cycle de
# boot avec `--human $LCARS_ADMIRAL` : le sysadmin. C'est juste pour ce qui lui appartient (son
# `~/.lcars`, son binaire `claude`), et FAUX pour ce qui appartient à une fleet — un module qui
# poserait du travail de fleet sous cet uid le poserait sous le seul compte qui ne peut pas en
# lancer une.
#
# DEUX CONDITIONS, PARCE QU'IL Y A DEUX RÈGLES, et c'est le même couple que le GUARD B de
# `bin/fleet_v2` (le BEAM hérite de l'uid de son lanceur, ses pods avec) :
#   1. `uid >= UID_MIN` — la frontière système/humain. Elle n'est pas à inventer : `/etc/login.defs`
#      la déclare et `useradd` la lit.
#   2. `uid != SYSADMIN_UID` — la réservation du siège, que `login.defs` ne peut PAS exprimer :
#      UID_MIN vaut 1000 et le sysadmin EST 1000, donc le système le classe utilisateur régulier.
#
# La règle est ré-écrite ici plutôt qu'appelée chez `bin/fleet_v2` parce que le provisioning ne peut
# pas dépendre de l'artefact qu'il INSTALLE : `60-deploy` pose ce binaire, et une machine vierge
# n'en a aucun quand ce cycle démarre. Le nombre, lui, n'est pas recopié — il vient de login.defs.
#
# ⚠ ARITHMÉTIQUE, jamais des chaînes : en comparaison lexicographique `"999" < "1000"` est FAUX, et
# un compte système à uid 999 passerait la garde.
is_fleet_human() { # [login] (défaut: PROV_HUMAN) — 0 si oui
  local login="${1:-$PROV_HUMAN}" uid uid_min
  uid="$(id -u -- "$login" 2>/dev/null || true)"
  [[ "$uid" =~ ^[0-9]+$ ]] || return 1
  # `|| true` LOAD-BEARING : sous `set -euo pipefail`, un login.defs absent tuerait le module AVANT
  # la garde. Une garde qui s'évanouit sur une lecture ratée est pire que pas de garde.
  uid_min="$(awk '/^UID_MIN/ {print $2}' "${PASSWD_DEFS:-/etc/login.defs}" 2>/dev/null | head -n1 || true)"
  [[ "$uid_min" =~ ^[0-9]+$ ]] || uid_min=1000
  (( uid >= uid_min )) && (( uid != ${LCARS_SYSADMIN_UID:-1000} ))
}

# Racine du repo (le checkout depuis lequel on provisionne) — dérivée UNE fois de la position de
# la lib (fleet/deploy/lib/ → ../../..), jamais re-devinée par heuristique dans un module.
repo_root() { readlink -f "$(dirname "$PROVISION_LIB")/../../.."; }

# ─── prov_roles — LE ROSTER FORGE, DERIVE DU MATERIEL ─────────────────────────────────────────────
#
# LA QUATRIEME LISTE DE ROLES TENUE A LA MAIN EST MORTE ICI. `PROV_ROLES` enumerait neuf comptes
# `<catalogue>_<role>` en dur, a cote de trois autres inventaires du meme fait (forge.tf,
# provision-role-tokens.sh, les cap-profiles du catalogue) — et c'est ELLE qui gagnait, puisque
# `50-forge` la passe au mint. Un producteur absent de cette ligne = pas de jeton sur une fleet
# fraiche = rail ops en `role_token_unavailable` (BL-6-34, vecu deux fois : eng_doc, puis son rename
# scribe). Une liste ecrite a la main pour un ensemble qui grandit avec chaque catalogue installe ne
# pouvait que rester en retard.
#
# Elle se derive maintenant de ce que les catalogues DECLARENT : le release lit leurs cap-profiles
# (`entrypoint roles <racine>`), la meme porte que la recette tofu emprunte pour son roster. Un
# catalogue installe apporte donc ses comptes sans qu'aucun fichier de deploiement ne le sache.
#
# LA LISTE EN DUR SURVIT COMME PLANCHER, et pas par prudence : les comptes `system_*` vivent dans le
# catalogue SYSTEME, qui n'est pas installe — il est le substrat. Et une boite dont le release n'est
# pas encore pose (chemin WSL, avant `60-deploy`) doit quand meme minter de quoi demarrer.
#
# ⚠ LE MINT NE PERD JAMAIS UN COMPTE QU'IL A DEJA CREE : l'union est cumulative, jamais un
# remplacement. Un catalogue desinstalle laisse ses comptes derriere lui — c'est deliberé, ses
# projets existent encore et leurs commits portent ces signatures.
prov_roles() {
  local out="$PROV_ROLES" root
  local bin="${PROV_RELEASE_BIN:-/local/LCARS_v2/rel/lcars_fleet/bin/lcars_fleet}"
  local entry="${PROV_ENTRYPOINT:-/opt/lcars/entrypoint.sh}"

  # ⚠ `roles-tfvars` ET NON `roles`, ET LES DEUX PORTES NE RENDENT PAS LA MEME CHOSE. `roles` rend
  # des noms de ROLE (`dev`, `writer`) ; `PROV_ROLES` est une liste de COMPTES (`web-demo_dev`).
  # Mesure sur banc du 2026-08-16 : la derivation branchee sur `roles` faisait entrer `dev`,
  # `writer`, `architect` dans le roster — le mint aurait cree des comptes forge portant le nom nu
  # d'un role, a cote des vrais. Le commentaire de l'entrypoint annoncait `roles -> PROV_ROLES`, et
  # c'est ce qui m'a fait prendre la mauvaise porte : il est corrige la-bas.
  #
  # `.roles` porte les comptes du catalogue, `.system_roles` ceux du substrat partage. Le canon ne
  # connait pas cette coupure — il connait des comptes — donc on recolle ici, comme le fait deja le
  # verrou d'egalite des listes.
  if [[ -x "$entry" && -x "$bin" && -d "$PROV_CATALOGUES_DIR" ]] && command -v jq >/dev/null; then
    for root in "$PROV_CATALOGUES_DIR"/*/; do
      [[ -f "${root}catalogue.yaml" ]] || continue
      # `|| true` : un catalogue dont la porte refuse est un catalogue que le boot refusera aussi,
      # et ce n'est pas au mint de trancher. On n'ajoute simplement rien pour lui.
      out="$out $("$entry" roles-tfvars "${root%/}" 2>/dev/null \
                  | jq -r '(.roles[]?, .system_roles[]?)' 2>/dev/null | tr '\n' ' ' || true)"
    done
  fi

  printf '%s\n' $out | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
