#!/usr/bin/env bash
# ⚠ SC2034 AU NIVEAU DU FICHIER, ET C'EST LE CONTRAT DE CETTE LIB QUI LE JUSTIFIE. Ses fonctions
# rendent leurs resultats par des GLOBALES `PROV_*` que l'APPELANT lit : `prov_seat_binding` pose
# trois variables et n'imprime rien, `run_step` laisse le code reel dans `PROV_LAST_RC`. Aucune n'est
# relue ici, donc elles sont toutes vues inutilisees. Une directive par site serait la meme phrase
# a chaque fois — et elle doit preceder TOUTE commande, `set -` compris, sinon elle est inerte.
# shellcheck disable=SC2034
# SOURCE: fleet/deploy/lib/provision-lib.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — bibliothèque des modules : primitives convergentes, écriture atomique, verdicts réels
#
# Sourcée par CHAQUE module — qui sont des PROCESSUS SÉPARÉS, jamais un namespace partagé : un
# module qui meurt ne peut pas avorter les autres à mi-durcissement, ni marcher sur leurs compteurs.
#
# Contrat des primitives, les trois lois :
#   1. CONVERGENTES — elles amènent l'état déclaré et ne font RIEN s'il y est déjà. Appliquer N fois
#      = appliquer 1 fois, et re-converger vers la source COURANTE. Pas « append-once », qui
#      garderait à jamais le premier état écrit.
#   2. VERDICT RÉEL — l'état est re-sondé APRÈS l'action, jamais déduit de l'intention. Rien n'est
#      étouffé en `2>/dev/null` : un `pass` imprimé par-dessus une commande rendue muette est pire
#      qu'une absence de sonde.
#   3. ATOMIQUES — tout fichier est écrit tmp-même-dossier puis mv. Écrire `/etc/sudoers.d` ou
#      `/etc/wsl.conf` EN PLACE, c'est un lockout sudo fleet-wide ou une distro qui ne boote plus,
#      au premier write interrompu.
#
# Toute mutation effective incrémente PROV_CHANGED (le module le rapporte en fin d'apply).
# Les commandes sont passées en ARGV, jamais en strings évaluées : une string interpole des valeurs
# dans du code — injection dès qu'un chemin porte un métacaractère.

# Garde de double-source (un module qui se ferait sourcer deux fois ne doit pas ré-écraser l'état).
[[ -n "${PROVISION_LIB_LOADED:-}" ]] && return 0
PROVISION_LIB_LOADED=1

# La sonde docker vit dans une lib SANS effet de bord, sourcee ici et jamais recopiee : le script
# d'entree du depot en a besoin AVANT tout clone, et n'a rien a faire des defauts d'INSTALLATION
# poses plus bas.
# shellcheck source=docker-endpoint.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/docker-endpoint.sh"

# ─── Données par défaut — une SEULE définition, consommée par tous les modules ───────────────────
#
# LA RACINE UNIQUE : tout objet d'installation descend sous `PROV_ROOT`. Ce qu'on achete n'est pas
# l'esthetique de `/`, c'est que `rm -rf <racine>` SOIT la desinstallation, et qu'un `.deb` puisse
# empaqueter une empreinte qu'on sait nommer.
#
# `/opt/lcars` est deja le mot du runtime (`Fleet.Layout.@platform_root`), et la seule racine que la
# norme reserve a un paquet applicatif autonome.
: "${PROV_ROOT:=/opt/lcars}"

# Deux SSoT nomment ce prefixe — celle-ci le VERIFIE, celle d'`etc/install.sh` le POSE — et
# `racine_prefixe.bats` exige qu'elles s'accordent.
: "${PROV_PREFIX:=$PROV_ROOT/runtime}"          # install RO du runtime (modèle 3 zones d'etc/install.sh)
: "${PROV_LINK_DIR:=/usr/local/bin}"           # symlinks PATH (miroir de LCARS_INSTALL_LINK_DIR d'install.sh)
: "${PROV_FLEET_GROUP:=fleet}"                 # groupe de lecture des tokens + de l'install RO
# Le compte du service d'autorite : il DETIENT les secrets de forge et n'a AUCUN privilege
# noyau. L'inverse exact du convergeur, qui a le privilege et ne detient rien. Pose par
# `21-service-accounts`, membre de `$PROV_FLEET_GROUP` pour TRAVERSER l'install RO — jamais
# pour decider : l'adminite se demande a la forge a l'instant du geste.
: "${PROV_AUTHORITY_USER:=lcars-authority}"
# L'ADMINITE NE SE PROJETTE DANS AUCUN GROUPE UNIX : elle se DEMANDE a la forge a l'instant du
# geste, par un service qui lit l'uid de son pair dans le noyau (`catalogue-executor.py`).
# `PROV_FLEET_GROUP` ci-dessus n'est PAS cet objet — il ouvre la lecture des jetons et de l'install
# RO, c'est du partage de fichiers.
# ─── LE GROUPE QUI PORTE EXACTEMENT UN POUVOIR : TRAVERSER ──────────────────────────────────────
# Le PRODUCTEUR d'une socket de console (ttyd, sous l'humain) et son CONSOMMATEUR (le deck, sous
# `lcars-system`) doivent se rencontrer sans que ni l'un ni l'autre ne change d'identite. Le
# repertoire de chaque humain est `2710 <humain>:lcars-console` : le setgid fait heriter ce groupe a
# la socket, et le `--x` du groupe donne la traversee sans le listage.
#
# ⚠ SURTOUT PAS `$PROV_FLEET_GROUP` : celui-la porte deja la lecture de l'install RO et des jetons,
# le reutiliser ici accorderait tout le reste par la meme occasion. Une console montee sous le
# mauvais groupe est vivante et injoignable — un pouvoir qu'on ne sait pas dire en une phrase est
# trop large.
: "${PROV_CONSOLE_GROUP:=lcars-console}"       # traverser /run/lcars/console/<humain>, RIEN d'autre
: "${PROV_CATALOGUES_WORK:=$PROV_ROOT/var/tofu}"  # recettes tofu par catalogue (etat = SENSIBLE)
# Les jetons sont de l'ETAT, pas du travail : ils se refabriquent contre la forge. Plusieurs defauts
# nomment ce repertoire dans trois langages, et `racine_jetons.bats` exige qu'ils s'accordent.
: "${PROV_TOKENS_DIR:=$PROV_ROOT/var/tokens}"  # role-tokens forge (contrat FORGE_ROLE_TOKENS_DIR)
: "${PROV_FORGE_SEED_FILE:=$PROV_TOKENS_DIR/forge-seed.pass}"  # seed bootstrap tofu (handoff → A4)
# L'AUTORITE DE CREATION, posee par `box config`. ⚠ SON SUFFIXE N'EST PAS `.gitea_token`, celui des
# jetons de ROLE (`<login>.gitea_token`, contrat FORGE_ROLE_TOKENS_DIR) : qui globbe ce repertoire ne
# doit pas ramasser un site-admin en croyant lire un role.
: "${PROV_MASTER_TOKEN_FILE:=$PROV_TOKENS_DIR/forge-master.token}"
: "${PROV_UID_MAP_FILE:=$PROV_TOKENS_DIR/forge-uid.map}"

# ─── LES TROIS PROJETS COMPOSE DU POSTE, ET LE RESEAU DE LA FORGE ───────────────────────────────
#
# ⚠ ILS VIVENT ICI PARCE QUE DEUX MODULES LES LISENT. `48-forge-host` monte la forge, `49-forge-runner`
# enrole le runner sur SON reseau : les derivations etaient dans 48, donc 49 aurait du les recopier —
# et une recopie de derivation est le defaut que `toolchain.branch_single_source` existe pour tenir,
# un etage plus bas. Une seule base, quatre noms derives, un seul endroit.
#
# `--forge-project bob` nomme la BASE : la forge devient `bob-forge`, le runner `bob-runner`, la boite
# `bob-fleet` (celle-la est derivee par `deploy/box`, qui n'est pas un module).
: "${PROV_FORGE_BASE:=lcars}"
: "${PROV_FORGE_PROJECT:=${PROV_FORGE_BASE}-forge}"
: "${PROV_RUNNER_PROJECT:=${PROV_FORGE_BASE}-runner}"
# Le reseau que compose cree pour un projet sans `networks:` explicite. Le runner le REJOINT : depuis
# un conteneur, l'adresse publiee de la forge (`127.0.0.1:<port>`) designe ce conteneur-la.
: "${PROV_FORGE_NET:=${PROV_FORGE_PROJECT}_default}"
# ⚠ CETTE LISTE GAGNE SUR LES AUTRES : `50-forge` passe `--roles "$PROV_ROLES"` au mint A4, ecrasant
# le defaut du `.sh`. Un role absent ICI = pas de token sur une fleet fraiche = rail ops en
# `role_token_unavailable` (BL-6-34). Son egalite avec les autres listes n'est pas derivee (BL-6-45) :
# elle se tient a la main.
: "${PROV_ROLES:=system_architect system_chief system_gatekeeper fleet_engineer fleet_scribe fleet_qualifier fleet_reviewer fleet_scoper fleet_vulcan}"
# LE MATERIEL DES CATALOGUES INSTALLES — miroir shell de `Fleet.Layout.catalogues_installed_dir/0`,
# verrouille par `catalogue.install_paths_locked` de `mix lcars.contracts.check`. Diverger d'avec le
# runtime ne casse rien : `45-catalogues` converge un repertoire que personne ne lit, et la boite
# tourne sur le catalogue livre en annonçant qu'elle en sert trois.
: "${PROV_CATALOGUES_DIR:=/home/catalogues}"
: "${PROV_SYSTEM_ACCOUNT:=system_starfleet}"       # compte forge du SYSTÈME (signe les marqueurs)
# SON JETON SE DÉRIVE DE SON LOGIN, COMME LES AUTRES : le contrat est `<login>.gitea_token`, et un
# nom qui s'en écarte réclame une table de cas particuliers.
: "${PROV_SYSTEM_TOKEN_FILE:=$PROV_TOKENS_DIR/$PROV_SYSTEM_ACCOUNT.gitea_token}"
: "${PROV_FORGE_ORG:=fleet}"                   # org qui porte les repos projet (forge.tf)
# La team d'ENROLEMENT, lue par le convergeur d'humains et par le deck.
: "${PROV_HUMANS_TEAM:=humans}"                # team forge dont l'adhesion vaut enrolement
# LE FICHIER EST LE SEUL CANAL ENTRE MODULES : ils sont des PROCESSUS, donc `48-forge-host` ne peut
# rien exporter vers `50-forge`. Il écrit son adresse, on la relit ici.
# En conteneur ce fichier n'existe pas : l'environnement du compose gagne.
: "${PROV_FORGE_URL:=${FORGE_BASE_URL:-$(cat "$PROV_TOKENS_DIR/forge.url" 2>/dev/null || true)}}"
# LA FORGE A DEUX ADRESSES, ET LES CONFONDRE CASSE LA PORTE DU DECK. Celle du dessus est celle que
# le SERVEUR compose (dans un conteneur, le nom du service : `http://gitea:3000`) ; celle-ci est
# celle qu'un NAVIGATEUR doit atteindre. Une seule valeur ne peut pas être les deux — `gitea:3000`
# ne résout nulle part hors du réseau docker, et l'adresse de l'hôte peut ne pas résoudre dedans.
#
# ⚠ ET LE REPLI « ÉGALE L'INTERNE » DE LA LIGNE SUIVANTE EST UN PIÈGE SUR LE RAIL POSTE, où les deux
# ne coïncident JAMAIS : le deck sort alors un `redirect_uri` juste et un ALLER en loopback, donc un
# bouton « s'identifier » qui n'arrive nulle part depuis une autre machine.
: "${PROV_FORGE_PUBLIC_URL:=${FORGE_PUBLIC_URL:-$(cat "$PROV_TOKENS_DIR/forge.public.url" 2>/dev/null || true)}}"
: "${PROV_FORGE_PUBLIC_URL:=$PROV_FORGE_URL}"
# Le deck de la BOÎTE (porte d'entrée, hors de l'espace des blocs humains) et son client OAuth2.
# Les ORIGINES sont les adresses par lesquelles on entre vraiment : OAuth2 compare le `redirect_uri`
# EXACTEMENT, donc une entrée non déclarée échoue au RETOUR, après l'identification, là où c'est le
# plus déroutant. La loopback est toujours incluse ; le reste se déclare.
: "${PROV_DECK_PORT:=20999}"
: "${PROV_DECK_OIDC_FILE:=/etc/lcars/deck-oidc.json}"
: "${PROV_DECK_ORIGINS:=${LCARS_DECK_ORIGINS:-}}"
# Combien de lignes d'une commande en échec atterrissent à l'écran (le reste vit dans le fichier).
: "${PROV_DUMP_LINES:=40}"
# Jambe update du triangle (source→forge→runtime) : le remote à puller et le repo ATTENDU derrière.
# ⚠ `PROV_EXPECTED_REPO` N'A PAS DE DÉFAUT, ET C'EST L'INVARIANT : l'autorité se DÉCLARE, elle ne se
# devine pas. Vérifier le remote APRÈS le pull inverse la chaîne (F-E1).
: "${PROV_UPDATE_REMOTE:=origin}"
: "${PROV_EXPECTED_REPO:=}"
# Toolchain build : CELLE DE LA DISTRO. Deux PLANCHERS, aucun téléchargement.
#
# ⚠ NE PINNE PAS UNE VARIANTE D'OTP À CÔTÉ DE L'APT : un paquet apt d'Elixir est compilé CONTRE
# l'Erlang de sa propre distro. Un plancher tolère un écart, une variante non — poser un Elixir bâti
# pour OTP 25 sur une VM 27 passe le plancher en vert et fait tourner du bytecode d'un compilateur
# sur la machine d'un autre.
#
# ⚠ `mix.exs` EXIGE `~> 1.18`, ET C'EST LUI L'AUTORITÉ. Ce plancher-ci n'est pas une seconde
# exigence : il est ce que le rail vérifie AVANT de bâtir, pour que l'échec dise « distro trop
# vieille » au lieu de mourir dans `mix deps.get`. Les deux se déplacent ensemble.
: "${PROV_ELIXIR_OTP_MAJOR:=27}"
: "${PROV_ELIXIR_MIN:=1.18}"
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
# ⚠ LA COULEUR NE SORT QUE SUR UN TERMINAL : une séquence ANSI dans un fichier de log, c'est du
# `[1;32m` au milieu du texte, illisible à la relecture et cassé au grep. `PROV_COLOR=1` la force
# pour un `script`/`unbuffer`.
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

# Une action longue et muette n'est pas discernable d'un blocage : `p_step` dit ce qui COMMENCE,
# pour les etapes ou `run_quiet` reste silencieux plusieurs minutes.
#
# ⚠ LA TEINTE ENVELOPPE TOUT LE PREFIXE « ETIQUETTE  module: », REMPLISSAGE COMPRIS. Une sequence
# ANSI glissee entre l'etiquette et le nom du module COUPE le jeton — la sortie devient
# « <ESC>ERREUR<ESC> 90-mort », et la chaine litterale « ERREUR 90-mort » que des temoins cherchent
# n'y est plus.
p_step() { printf '%s>>    %s:%s %s\n' "$_PC" "$PROV_MODULE_TAG" "$_PN" "$*"; }
# ⚠ LES DEUX RENDENT 0, EXPLICITEMENT. Sans ce `return`, leur code de sortie est celui de `printf` —
# donc une ecriture qui echoue (EPIPE sur un pipe ferme, disque plein) fait partir le `|| p_drift`
# des appelants : un drift ANNONCE que rien ne justifie, sur un etat qui etait conforme. Une fonction
# qui RAPPORTE ne doit pas pouvoir renverser le verdict qu'elle rapporte.
p_ok()   { printf '%sOK    %s:%s %s\n' "$_PG" "$PROV_MODULE_TAG" "$_PN" "$*"; return 0; }
p_chg()  { printf '%sPOSÉ  %s:%s %s\n' "$_PC" "$PROV_MODULE_TAG" "$_PN" "$*"; return 0; }
p_drift(){ printf '%sDRIFT %s:%s %s\n' "$_PA" "$PROV_MODULE_TAG" "$_PN" "$*" >&2; PROV_DRIFT=$((PROV_DRIFT + 1)); }
p_warn() { printf '%sWARN  %s:%s %s\n' "$_PA" "$PROV_MODULE_TAG" "$_PN" "$*" >&2; }
p_fail() { printf '%sFAIL  %s:%s %s\n' "$_PR" "$PROV_MODULE_TAG" "$_PN" "$*" >&2; PROV_FAILED=$((PROV_FAILED + 1)); }
p_die()  { PROV_VERDICT_RENDERED=1; printf '%sFATAL %s:%s %s\n' "$_PR" "$PROV_MODULE_TAG" "$_PN" "$*" >&2; exit 1; }

# Sortie standard d'un module : à appeler en FIN de check() et d'apply(). Le runner lit ces codes
# tels quels — les changer ici change son bilan.
#   check   0 conforme · 1 drift constaté · 2 échec de sonde (un `p_fail` a été appelé)
#   apply   0 convergé · 1 au moins un échec · 2 appliqué, DRIFT RÉSIDUEL
#   p_die   1, verdict rendu — fatal immédiat
#   tout    3 MORT avant d'avoir rendu son verdict, posé par `_prov_exit_guard` ci-dessous
# ─── UN MODULE QUI MEURT DOIT LE DIRE LUI-MEME ──────────────────────────────────────────────────
#
# Le 3 existe parce que `2` est pris DES DEUX COTES, et qu'un module tue par `set -e` rend justement
# 2 : le runner ne peut pas distinguer « appliqué, drift résiduel » de « mort en route ». Le module,
# lui, SAIT s'il a rendu son verdict.
#
# ⚠ La garde n'est armee que sous le RUNNER (`PROVISION_RUN`). Un extrait qui source cette lib pour
# appeler une primitive — les temoins bats — n'est pas un module et n'a aucun verdict a rendre.
PROV_VERDICT_RENDERED=0
_prov_exit_guard() {
  local rc=$?
  [[ "$PROV_VERDICT_RENDERED" -eq 1 ]] && return 0
  printf '%sERREUR %s:%s MORT avant de rendre son verdict (rc=%d) — aucune ligne ci-dessus ne le dit, faute de temps\n' \
    "$_PR" "$PROV_MODULE_TAG" "$_PN" "$rc" >&2
  exit 3
}
if [[ -n "${PROVISION_RUN:-}" ]]; then
  trap _prov_exit_guard EXIT
  # ⚠ ET LE DRAPEAU EST RETIRE AUSSITOT : il arrive par l'ENVIRONNEMENT, donc il DESCEND a tout ce
  # que le module lance ensuite. Un script qui source cette lib sans etre un module — `bench-up.sh`
  # — sortirait 3 sur un `exit 0` parfaitement propre, avec un « MORT avant son verdict » mensonger.
  unset PROVISION_RUN
fi

verdict_check() {
  PROV_VERDICT_RENDERED=1
  if [[ "$PROV_FAILED" -gt 0 ]]; then exit 2; fi
  [[ "$PROV_DRIFT" -gt 0 ]] && exit 1
  exit 0
}
# ⚠ LE DRIFT D'UN APPLY SORT EN 2, JAMAIS EN 0 : rendre 0 ferait compter « convergé » un module qui
# vient d'imprimer une ligne DRIFT. Et jamais 1 non plus — ce serait confondre « je n'ai pas pu
# converger » avec « j'ai cassé », deux mots dont l'opérateur a besoin séparément.
verdict_apply() {
  PROV_VERDICT_RENDERED=1
  [[ "$PROV_FAILED" -gt 0 ]] && exit 1
  [[ "$PROV_DRIFT" -gt 0 ]] && exit 2
  exit 0
}

# ─── run_quiet — succès silencieux, échec verbeux (l'école mail-in-a-box `hide_output`) ──────────
# La commande est un ARGV. En échec : la commande, son code, et TOUTE sa sortie sont dumpés.
# Rien n'est jamais étouffé en `2>/dev/null` — un silence cache des permissions cassées.
# ─── run_step <label> -- <cmd…> — UNE ETAPE LONGUE QUI DIT OU ELLE EN EST ───────────────────────
#
# Pour les etapes de plusieurs minutes, ou le mutisme de `run_quiet` ne distingue plus « ca
# travaille » de « c'est fige ». Sur un terminal : UNE ligne reecrite en place. Ailleurs (log, CI) :
# une ligne par CHANGEMENT de phase.
#
# ⚠ AUCUN POURCENTAGE INVENTE : la duree totale est inconnue, et une barre qui la devine ment tout
# en etant crue. On affiche ce que l'enfant a REELLEMENT annonce — derniere phase reconnue dans sa
# propre sortie, et temps ecoule. Si les marqueurs changent, la phase se fige et le chrono continue :
# on perd du detail, jamais la verite.
_prov_phase_of() { # _prov_phase_of <fichier> -> le libelle de la derniere phase reconnue
  local m
  # ⚠ `|| true` LOAD-BEARING, ET LA FONCTION NE SURVIT QUE PAR SA FORME D'APPEL. « Aucune ligne
  # reconnue » est le cas NORMAL, et `grep` rend alors 1 — sous `pipefail`, c'est le code du
  # pipeline, donc celui de l'assignation. Sous `set -euo pipefail`, sur un fichier sans
  # correspondance :
  #   _prov_phase_of "$f"          -> le shell MEURT, aucune sortie
  #   p="$(_prov_phase_of "$f")"   -> survit, rend « demarrage »
  # L'appelant qui ecrirait la premiere forme tuerait son module au premier tick.
  m="$(grep -oE 'Compiling [0-9]+ files|Running ExUnit|Finished in |=== shell_gate|--- bats|contracts\.check green|lcars\.topology|Checking [0-9]+ modules|Total errors|done \(passed|Release created at' "$1" 2>/dev/null | tail -n1 || true)"
  case "$m" in
    "Compiling"*)        echo "compilation" ;;
    "Running ExUnit")    echo "suite ExUnit (3000+ temoins)" ;;
    "Finished in "*)     echo "suite ExUnit terminee" ;;
    "=== shell_gate"*)   echo "gate shell (python + bats)" ;;
    "--- bats"*)         echo "gate shell (bats)" ;;
    *"contracts.check green") echo "contrats" ;;
    "lcars.topology")    echo "topologie" ;;
    "Checking "*)        echo "dialyzer (construction du PLT)" ;;
    "Total errors"*)     echo "dialyzer" ;;
    "done (passed"*)     echo "dialyzer termine" ;;
    "Release created at") echo "release posee" ;;
    *)                   echo "demarrage" ;;
  esac
}

# `--ok N` : UN CODE QUI N'EST PAS UN ECHEC, DIT AU POINT D'APPEL. Sans lui, un rc qui est un FAIT et
# non un verdict — `etc/install.sh` rend 3 pour « release posee, cablage PATH incomplet », le cas
# nominal sous un humain — ferait monter `PROV_FAILED` et le module rendrait un echec sur un succes.
#
# ⚠ LA FONCTION REND 0 POUR UN CODE TOLERE, et le code reel reste lisible dans `PROV_LAST_RC` : sous
# `set -e`, rendre le rc tuerait l'appelant AVANT la ligne qui lit `$?`, ce qui rend une tolerance
# ecrite au point d'appel litteralement inatteignable.
run_step() { # run_step [--ok N]… <label> -- <cmd…>
  local ok_codes=()
  while [[ "${1:-}" == "--ok" ]]; do ok_codes+=("${2:?--ok attend un code}"); shift 2; done
  local label="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  local rc=0 c
  # `--verbose` : pas de suivi, tout defile — c'est le mode de celui qui veut le detail brut.
  #
  # ⚠ NE DELEGUE PAS CETTE BRANCHE A `run_quiet` : il `p_fail`-e sur TOUT rc non nul, ne connait
  # aucune tolerance et ne pose pas `PROV_LAST_RC` — `--ok` se perdrait, et un mode d'AFFICHAGE
  # changerait un verdict.
  #
  # Le detail est le meme que plus bas, deliberement : les factoriser dans une fonction tierce
  # mettrait la boucle `--ok` a distance de son `rc`.
  if [[ "${PROV_VERBOSE:-0}" -eq 1 ]]; then
    p_step "$label"
    "$@" || rc=$?
    PROV_LAST_RC="$rc"
    if [[ "${#ok_codes[@]}" -gt 0 ]]; then
      for c in "${ok_codes[@]}"; do
        [[ "$rc" == "$c" ]] || continue
        p_ok "$label — terminé (rc=$rc, code attendu)"
        return 0
      done
    fi
    [[ "$rc" -eq 0 ]] || p_fail "commande en échec (rc=$rc) : $*"
    return "$rc"
  fi
  local out t0="$SECONDS" phase="" prev="" el
  out="$(mktemp "${TMPDIR:-/tmp}/prov-out.XXXXXX")"
  "$@" >"$out" 2>&1 &
  local pid=$!
  # On SONDE le fichier une fois par seconde plutot que de brancher un pipe : le code de retour de
  # l'enfant reste recuperable par `wait`, alors qu'un `cmd | while read` mettrait la boucle dans un
  # sous-shell et perdrait a la fois le rc et tout compteur touche dedans (meme piege que B3).
  while kill -0 "$pid" 2>/dev/null; do
    phase="$(_prov_phase_of "$out")"
    el="$(printf '%02d:%02d' "$(( (SECONDS - t0) / 60 ))" "$(( (SECONDS - t0) % 60 ))")"
    if [[ -t 1 ]]; then
      printf '\r\033[K%s>>%s    %s: %s · %s · %s' "$_PC" "$_PN" "$PROV_MODULE_TAG" "$label" "$phase" "$el"
    elif [[ "$phase" != "$prev" ]]; then
      printf '%s>>%s    %s: %s · %s\n' "$_PC" "$_PN" "$PROV_MODULE_TAG" "$label" "$phase"
    fi
    prev="$phase"
    sleep 1
  done
  wait "$pid" || rc=$?
  [[ -t 1 ]] && printf '\r\033[K'
  PROV_LAST_RC="$rc"
  # ⚠ ON TESTE LA TAILLE, PAS UNE VALEUR PAR DÉFAUT SUR `[@]`. `"${arr[@]:-}"` sur un tableau VIDE
  # produit une chaîne vide unique : la boucle tourne une fois avec `c=""`, et seule la garde
  # `-n "$c"` rattrapait le coup. C'est un comportement de bash, pas un contrat — et une garde qui
  # dépend d'un effet de bord n'en est pas une.
  if [[ "${#ok_codes[@]}" -gt 0 ]]; then
    for c in "${ok_codes[@]}"; do
      [[ "$rc" == "$c" ]] || continue
      p_ok "$label — terminé (rc=$rc, code attendu)"
      rm -f "$out"
      return 0
    done
  fi
  if [[ "$rc" -ne 0 ]]; then
    p_fail "commande en échec (rc=$rc) : $*"
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

run_quiet() {
  local out rc=0
  # `--verbose` : on ne capture RIEN, tout défile. Le verdict ne change pas — un échec compte pareil.
  if [[ "${PROV_VERBOSE:-0}" -eq 1 ]]; then
    "$@" || rc=$?
    [[ "$rc" -eq 0 ]] || p_fail "commande en échec (rc=$rc) : $*"
    return "$rc"
  fi
  out="$(mktemp "${TMPDIR:-/tmp}/prov-out.XXXXXX")"
  "$@" >"$out" 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    # ⚠ B1 — L'ECHEC DOIT PASSER PAR `p_fail`, QUI INCREMENTE `PROV_FAILED` : avec un `printf` nu,
    # les compteurs restent a zero et `run_quiet x || verdict_apply` sort « convergé » sur un x qui
    # a echoue.
    p_fail "commande en échec (rc=$rc) : $*"
    # ⚠ BORNÉ À L'ÉCRAN, ENTIER SUR LE DISQUE. Deverser toute la sortie noie le verdict — une suite
    # ExUnit en echec fait des milliers de lignes — et la supprimer ensuite laisse zero copie. La
    # queue porte le verdict, le detail vit dans un fichier qu'on NOMME et qu'on garde.
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
# ⚠ NE COMPARE JAMAIS UN REMOTE PAR SOUS-CHAINE (6-109) : avec `PROV_EXPECTED_REPO=fleet/lcars`, le
# `case "$REMOTE_URL" in *"$PROV_EXPECTED_REPO"*)` qu'on ecrit spontanement est satisfait par
# `https://host-de-l-attaquant/attaquant/fleet/lcars-malware.git`. Ni l'hote, ni le proprietaire, ni
# la fin du nom du depot ne sont regardes — et derriere, `git pull --ff-only` puis
# `exec "$SELF" apply` executent ce code EN ROOT.
#
# Trois formes admises, ramenees au MEME triplet ; tout le reste est refuse :
#   * `https://host[:port]/owner/repo[.git]`
#   * `ssh://[user@]host[:port]/owner/repo[.git]`
#   * `[user@]host:owner/repo[.git]`  (forme scp, celle que `git@` utilise)
#
# ⚠ USERINFO AVEC MOT DE PASSE REFUSE, SUR LES DEUX FORMES : un remote qui embarque `user:token@`
# fait de l'autorite de mise a jour un porteur de secret. L'utilisateur NU passe (`git@host`) —
# c'est la syntaxe normale de SSH, et le refuser rendrait tout remote SSH inutilisable.
#
# Le chemin doit avoir EXACTEMENT deux segments : `owner/repo`. Un de plus, c'est le
# `attaquant/fleet/lcars` de l'attaque ; un de moins, ce n'est pas un depot. C'est aussi cette regle,
# et non la garde userinfo, qui neutralise `https://fleet/lcars@ailleurs/…` : le `@` est mange par la
# normalisation, qui rend `ailleurs/…` — un triplet qui ne correspondra a aucune autorite attendue.
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
# ⚠ JAMAIS DE VERROU SOUS `/tmp` (6-130). Sous `sudo`, un nom derive de `id -u` vaut 0 : il est FIXE
# et devinable. `/tmp` est inscriptible par tout le monde, et `exec 9>"$LOCK"` SUIT les liens et
# TRONQUE la cible AVANT que `flock` n'ait protege quoi que ce soit — un utilisateur local pose ce
# nom en lien vers un fichier root, et le prochain `sudo provision apply` le vide.
#
# Deux dossiers, un par identite, et aucun des deux n'est ecrivable par un tiers :
#   * root      → `/run/lock/lcars`, cree root:root 0700. `/run/lock` est un tmpfs du systeme.
#   * non-root  → `$XDG_RUNTIME_DIR/lcars` (0700 par construction, propriete de l'utilisateur), ou
#                 `/run/user/<uid>/lcars` a defaut. `apply` peut tourner sans root quand aucun
#                 module selectionne ne mute — ce cas a besoin d'un verrou lui aussi.
#
# ⚠ `TMPDIR` N'EST PAS HONORE : une variable d'environnement preservee a travers `sudo` deplacerait
# le verrou dans un dossier que l'appelant choisit, et un verrou privilegie dont l'emplacement est un
# parametre de l'appelant n'est pas un verrou. Un emplacement introuvable ARRETE.
# ─── LA PORTEE DU VERROU — GLOBALE, OU CELLE D'UN SEUL HUMAIN ───────────────────────────────────
#
# ⚠ UN VERROU UNIQUE SERIALISE DES GESTES QUI NE SE TOUCHENT PAS, ET CA COUTE UNE INSTALL : le
# convergeur equipe un humain PENDANT que l'install tient son propre apply, se fait refuser, et
# l'humain garde un home, un shell, un groupe, et PAS de `claude` — sans que rien ne le lui dise.
# La fenetre est celle du chemin nominal, pas un cas de bord.
#
# L'unite de travail EST l'humain : deux humains n'ont aucun objet commun — homes, `~/.lcars`,
# binaires `claude` disjoints. Les serialiser ne protege rien.
#
# `prov_lock_path [portee]` — sans argument, le verrou GLOBAL d'une passe complete ; avec, le verrou
# de cette portee-la.
prov_lock_path() {
  local dir uid scope="${1:-}"
  uid="$(id -u)"

  # ⚠ LA PORTEE DEVIENT UN NOM DE FICHIER : elle est bornee au charset des logins unix, jamais prise
  # telle quelle. Un `../` ou un `/` dedans deplacerait le verrou hors du dossier qu'on vient de
  # prouver sur — et le prouver pour ecrire ailleurs serait pire que ne pas le prouver.
  if [[ -n "$scope" && ! "$scope" =~ ^[A-Za-z0-9._-]+$ ]]; then
    p_fail "verrou: portee « $scope » hors charset — REFUSE"
    return 1
  fi

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

  local lock="$dir/provision${scope:+.$scope}.lock"
  # Le dossier est desormais prouve non-ecrivable par un tiers ; un lien A L'INTERIEUR ne peut donc
  # venir que de nous-memes ou d'un root anterieur. On le refuse quand meme : cette verification-la
  # coute un `[[ -L ]]` et c'est la seule qui reste entre `flock` et une troncature.
  [[ -L "$lock" ]] && { p_fail "verrou: $lock est un symlink — REFUSE"; return 1; }

  printf '%s\n' "$lock"
}

# ─── prov_refuse_symlink_path <chemin absolu> — LA garde des mutations privilegiees ──────────────
#
# ⚠ SANS ELLE, UN LIEN POSE PAR L'HUMAIN DONNE `/etc` (6-131) : `[[ -d ]]` SUIT les liens, donc un
# symlink-vers-dossier passe pour un dossier et `stat`/`chmod`/`chown` operent sur la CIBLE. Ces
# helpers tournent EN ROOT sur des chemins de l'humain — `~/.config -> /etc`, et le prochain
# `sudo provision apply` les lui donne.
#
# ON REFUSE, ON NE RESOUT PAS : un `readlink -f` suivi de l'operation est le meme bug avec une etape
# de plus, la resolution et la mutation n'etant pas atomiques. Refuser n'a aucune fenetre a gagner.
#
# ⚠ CE QUE CETTE GARDE NE FAIT PAS, et il faut le savoir en la lisant : elle ne supprime pas le
# TOCTOU, elle le reduit a une COURSE. Pre-poser un lien et attendre le prochain `apply` ne marche
# plus ; le glisser entre notre `lstat` et notre `chmod` marche encore, et fermer ca demanderait des
# descripteurs `openat(O_NOFOLLOW)` que bash n'a pas. C'est la limite honnete de ce langage a cet
# endroit, et la remonter voudrait dire sortir le provisioning de bash.
#
# Le chemin est parcouru COMPOSANT PAR COMPOSANT : un lien au milieu (`~/.config` -> ailleurs) est
# aussi dangereux que le dernier.
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
#
# ⚠ POUR DONNER UN FICHIER À UN HUMAIN, ÉCRIRE `<humain>:` ET JAMAIS `<humain>:<humain>`. Le deux-
# points nu dit à `chown` « le groupe de CONNEXION de cet utilisateur », quel qu'il soit ; répéter
# le nom suppose un groupe privé homonyme, ce qui n'est vrai que là où `USERGROUPS_ENAB yes` a
# créé un groupe à l'inscription du compte. Un humain de la fleet créé avec `fleet` pour groupe
# primaire n'a AUCUN groupe à son nom, et l'appel meurt sur `chown: invalid group`. La forme
# `<humain>:` est correcte dans les DEUX cas.
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
  prov_journal_note posed_file "$dest"
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
    # ⚠ `<user>:` NE SE COMPARE PAS TEL QUEL, ET L'OUBLI COÛTE UNE CONVERGENCE PERPÉTUELLE. Le
    # deux-points nu dit à `chown` « le groupe de CONNEXION de cet utilisateur » — il ne dit pas
    # LEQUEL, donc `stat` rend ensuite `lordzurp:lordzurp` là où la cible s'écrit `lordzurp:`. La
    # comparaison littérale échoue à jamais : le module re-chowne à chaque passe, compte une
    # mutation, et imprime un POSÉ sur un fichier strictement identique. Rien ne casse — mais
    # « rejouer ne fait rien » devient faux, et c'est la propriété sur laquelle ce rail est bâti.
    #
    # On compare donc ce que la SPÉCIFICATION dit : l'utilisateur seul quand le groupe est laissé au
    # système, les deux quand il est nommé.
    if [[ "$owner" == *: ]]; then
      cur_owner="$(stat -c '%U' "$path"):"
    fi
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
    prov_journal_note posed_dir "$path"
  fi
  ensure_mode "$path" "$mode" "$owner"
}

# ─── ensure_group / ensure_member — création idempotente (le pattern propre de provision-groups v1) ─
# prov_group_owns_preserved <groupe> <racine preservee…> -> 0 si un objet PRESERVE porte ce groupe
#
# ⚠ CE CONTROLE NE PEUT PAS ETRE DELEGUE A `groupdel`, ET C'EST LA CICATRICE DE CE FICHIER.
# `provision` s'appuyait dessus : « un groupe encore porte par un objet preserve n'est pas
# retirable ». MESURE SUR BANC VIERGE le 2026-08-27 : `groupdel fleet` REUSSIT, et les trois faces
# `/home/projects*` restent en `root:1001` — un GID orphelin, que le prochain `groupadd` de la
# machine reattribuera. `groupdel` refuse un groupe PRIMAIRE d'un compte existant ; il ne regarde
# jamais qui possede des fichiers. La regle etait juste, son execution ne l'etait pas.
#
# `-print -quit` : on cherche l'EXISTENCE d'un porteur, pas la liste. Le premier suffit et le
# balayage s'arrete — une face de travail peut porter des dizaines de milliers de fichiers.
prov_group_owns_preserved() {
  local grp="$1"; shift
  local root hit
  for root in "$@"; do
    [[ -e "$root" ]] || continue
    hit="$(find "$root" -xdev -group "$grp" -print -quit 2>/dev/null || true)"
    [[ -n "$hit" ]] && { printf '%s\n' "$hit"; return 0; }
  done
  return 1
}

# prov_manifest_gid <groupe> -> le GID que la TABLE declare, ou vide
#
# ⚠ LE MANIFESTE GAGNE ICI SON PREMIER CONSOMMATEUR DE PRODUCTION, et c'est ce qui change sa nature.
# Il n'etait lu que par `provision uninstall` — donc une declaration qu'on n'opposait a rien a
# l'install, et qu'on n'executait qu'a la destruction. Une table qu'on APPLIQUE est une table qu'on
# ne peut plus laisser mentir.
prov_manifest_gid() {
  local grp="$1" f="${LCARS_SYSTEM_MANIFEST:-$(dirname "$PROVISION_LIB")/../system.manifest}"
  [[ -r "$f" ]] || return 0
  awk -v g="$grp" '$1=="group" && $2==g { print $3; exit }' "$f"
}

ensure_group() {
  local grp="$1" gid="${2:-}"
  [[ -n "$gid" ]] || gid="$(prov_manifest_gid "$grp")"
  if ! getent group "$grp" >/dev/null; then
    # ⚠ LE GID VIENT DE LA TABLE, ET SANS LUI IL FLOTTE. Mesure du 2026-08-27 sur banc vierge :
    # `groupadd` nu distribue 1001 et 1002 pendant que la table declare 2000 et 2001, et que le
    # Dockerfile ecrit `groupadd -g 2000` EN LITTERAL. Le meme produit donnait donc des GID
    # differents selon le rail, et un GID flottant est ce qui a fait naitre `lcars-authority` dans
    # le groupe `fleet`. Un GID absent de la table reste flottant : on ne l'invente pas.
    local -a args=()
    [[ -n "$gid" ]] && args+=(-g "$gid")
    run_quiet groupadd "${args[@]}" "$grp" || return 1
    getent group "$grp" >/dev/null || { p_fail "groupe $grp absent après groupadd"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "groupe $grp${gid:+ (gid $gid, table)}"
    prov_journal_note posed_group "$grp"
    return 0
  fi
  # LE GROUPE EXISTE : on ne le DEPLACE pas — changer un GID sous des fichiers qui le portent
  # produirait exactement les orphelins que la regle 5 vient de fermer. On le DIT.
  local cur; cur="$(getent group "$grp" | cut -d: -f3)"
  [[ -z "$gid" || "$cur" == "$gid" ]] \
    || p_drift "groupe $grp : gid $cur, la table declare $gid — une machine ne se renumerote pas, elle se rebuilde"
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
  prov_journal_note posed_link "$link"
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
# ─── prov_journal_note <clef> <valeur…> — CE QUI A ÉTÉ POSÉ *ICI* ───────────────────────────────
#
# `system.manifest` déclare ce que le provisionnement a le DROIT de poser. Il est statique, versionné,
# le même pour toutes les machines. Le JOURNAL dit ce qui a été posé sur CELLE-CI, et il porte le
# seul fait qu'aucun fichier statique ne peut connaître : la séparation entre ce que LCARS a
# installé et ce qui était déjà là.
#
# ⚠ LE CANAL EST UN FICHIER, PARCE QUE LES MODULES SONT DES PROCESSUS. Le runner les lance ; une
# variable posée dans l'un ne remonte pas au suivant. C'est la même leçon que `forge.url`, écrite
# par `48-forge-host` pour que `50-forge` et `55-deck-oidc` la lisent — mesure du 2026-08-18, deux
# modules en dérive parce qu'on croyait qu'un `export` traversait.
#
# ⚠ ET C'EST UNE NOTE, PAS UN VERDICT. Un journal qui échoue ne fait pas échouer un apply : il
# raconte, il ne décide pas. Sans accumulateur (`doctor`, module joué nu, témoin), la fonction est
# muette et rend 0 — un appelant n'a jamais à savoir si le journal existe.
# ⚠ LA NOTE VIT DANS LES PRIMITIVES, PAS DANS LES MODULES — ET C'EST LE GESTE CENTRAL DU JOURNAL.
#
# Cette fonction avait DEUX appelants, tous deux dans `apt_ensure`. Le journal ne connaissait donc
# que les paquets : zero repertoire, zero fichier, zero lien, zero groupe. MESURE DU 2026-08-27,
# banc vierge : dix-sept lignes, dont dix d'en-tete, cinq metadonnees et deux colonnes apt.
#
# La poser dans chaque module aurait demande a 53 sites d'appel de S'EN SOUVENIR. Un poseur qui doit
# se souvenir oubliera — c'est exactement ce qui s'est passe pour les deux modules qui sondent avant
# `apt_ensure`. Posee dans les primitives, elle trace ces 53 sites dans 18 modules sans qu'un seul
# module ne change, et le prochain poseur est trace par construction.
prov_journal_note() { # prov_journal_note <clef> <valeur…>
  [[ -n "${PROV_JOURNAL_ACC:-}" ]] || return 0
  [[ "$#" -ge 2 ]] || return 0
  # ⚠ `2>/dev/null` AVANT `>>`, ET L'ORDRE EST LOAD-BEARING. Les redirections se traitent de GAUCHE
  # A DROITE : écrite après, elle arrive trop tard — l'ouverture du fichier a déjà échoué et le
  # shell a déjà imprimé son « No such file » sur stderr. La fonction survivait, et polluait quand
  # même la sortie de son appelant. Mesuré le 2026-08-22 par le témoin qui vérifie qu'elle survit.
  printf '%s %s\n' "$1" "${*:2}" 2>/dev/null >> "$PROV_JOURNAL_ACC" || true
  return 0
}

# ─── prov_announce_credential <libellé> <login> <secret> — CE QUI NE SE RELIRA PLUS ──────────────
#
# ⚠ UN SECRET AFFICHÉ AU MILIEU DE DEUX CENTS LIGNES EST UN SECRET PERDU, et l'afficher au moment
# où il naît le condamne à ça. Ces credentials sortent de modules joués au rang 22 ou 48 : quarante
# modules plus tard, l'encadré a défilé. Le seul endroit où un opérateur regarde vraiment, c'est la
# FIN — donc c'est là qu'ils s'impriment, tous ensemble, une fois.
#
# ⚠ MÊME CANAL QUE LE JOURNAL, ET POUR LA MÊME RAISON : les modules sont des processus, une variable
# posée dans l'un ne remonte pas. Le fichier est créé par l'appelant racine (`install.sh`), en 0600,
# et il le DÉTRUIT après l'avoir imprimé — le secret ne survit pas à l'installation qui l'a produit.
#
# ⚠ ET SANS ACCUMULATEUR, ON IMPRIME SUR PLACE. Un `provision apply` joué à la main n'a pas de
# banner final : s'y taire échangerait un secret défilé contre un secret jamais montré, ce qui est
# strictement pire. Le canal est une amélioration de l'affichage, jamais une condition de son
# existence.
prov_announce_credential() { # prov_announce_credential <libellé> <login> <secret>
  [[ "$#" -ge 3 ]] || return 0
  if [[ -n "${PROV_ANNOUNCE_FILE:-}" ]]; then
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" 2>/dev/null >> "$PROV_ANNOUNCE_FILE" || true
    return 0
  fi
  prov_print_credentials <<< "$(printf '%s\t%s\t%s\n' "$1" "$2" "$3")"
}

# L'encadré, séparé de la collecte : `install.sh` l'appelle sur le fichier accumulé, un module joué
# nu l'appelle sur sa seule ligne. Une seule mise en forme, donc une seule à corriger.
# ⚠ `printf '%-60s'` COMPTE DES OCTETS, PAS DES COLONNES, et tout libellé français casse alors le
# cadre : « — », « é » et « ' » pèsent deux ou trois octets pour une seule colonne. `${#s}` en bash
# compte des CARACTÈRES sous une locale UTF-8, donc la marge se calcule et ne se délègue pas.
_prov_pad() { # <texte> <colonnes>
  local s="$1" n=$(( $2 - ${#1} ))
  (( n < 0 )) && n=0
  printf '%s%*s' "$s" "$n" ''
}

prov_print_credentials() { # lit des lignes « libellé<TAB>login<TAB>secret » sur stdin
  local lbl login secret n=0
  while IFS=$'\t' read -r lbl login secret; do
    [[ -n "$secret" ]] || continue
    if [[ "$n" -eq 0 ]]; then
      printf '\n'
      printf '    ┌──────────────────────────────────────────────────────────────┐\n'
      printf '    │  IDENTIFIANTS — note-les maintenant, ils ne seront PAS redits │\n'
      printf '    ├──────────────────────────────────────────────────────────────┤\n'
    else
      printf '    │%s│\n' "$(_prov_pad '' 62)"
    fi
    n=$((n + 1))
    printf '    │  %s│\n' "$(_prov_pad "$lbl" 60)"
    # 62 colonnes entre les bordures : le préfixe en pèse 18, la marge 44. Le compte est fait ici
    # une fois plutôt que répété en littéral — trois nombres pour une seule largeur dérivent.
    printf '    │    login       : %s│\n' "$(_prov_pad "$login" 44)"
    printf '    │    mot de passe: %s│\n' "$(_prov_pad "$secret" 44)"
  done
  [[ "$n" -eq 0 ]] && return 0
  printf '    └──────────────────────────────────────────────────────────────┘\n\n'
  return 0
}

apt_ensure() {
  local missing=() already=() pkg
  for pkg in "$@"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then already+=("$pkg"); else missing+=("$pkg"); fi
  done
  # ⚠ LA SÉPARATION SE MESURE AVANT L'INSTALL, ET C'EST LE SEUL MOMENT OÙ ELLE EST CONNAISSABLE.
  # Une seconde plus tard, `dpkg -s` répond « présent » pour les deux listes et plus rien ne
  # distingue ce que LCARS a posé de ce que l'opérateur avait déjà. C'est exactement le fait
  # qu'aucun fichier statique ne peut porter — et sans lui, une désinstallation retire des paquets
  # que quelqu'un avait avant, ce qui est pire que d'en laisser.
  #
  # ⚠ MAIS MESURER N'EST PAS ÉCRIRE, ET LES DEUX ÉTAIENT CONFONDUS ICI. `apt_installed` était noté
  # AVANT l'`apt-get`, donc sur une INTENTION. Un dépôt injoignable, et le journal revendiquait des
  # paquets que la machine n'a jamais portés : la passe suivante les reclasse en `missing` et les
  # note à nouveau, pendant qu'un `uninstall` lance un `apt-get remove` sur des absents. La
  # propriété que ce journal existe pour tenir — « savoir ce que LCARS a posé » — était fausse
  # exactement dans le cas où elle sert, celui de la passe interrompue.
  # La classification reste ici ; l'écriture descend après la vérification `dpkg`.
  [[ "${#already[@]}" -gt 0 ]] && prov_journal_note apt_already "${already[@]}"
  [[ "${#missing[@]}" -eq 0 ]] && return 0
  p_chg "apt: install ${missing[*]}"
  run_quiet env DEBIAN_FRONTEND=noninteractive apt-get update -qq || return 1
  run_quiet env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" || return 1
  # ⚠ ON NOTE CE QUI RÉPOND, PAS CE QU'ON A DEMANDÉ. `apt-get install` peut rendre 0 en ayant servi
  # moins que la liste ; c'est `dpkg -s`, paquet par paquet, qui dit ce qui est là. Le journal ne
  # revendique donc que des paquets vérifiés présents.
  local rc=0 posed=()
  for pkg in "${missing[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      posed+=("$pkg")
    else
      p_fail "apt: $pkg toujours absent après install"; rc=1
    fi
  done
  # ⚠ ET ON ÉCRIT MÊME EN ÉCHEC PARTIEL. Ce qui EST posé doit être journalisé, sinon le mode
  # dégradé échange un mensonge contre un orphelin : des paquets sur la machine que l'uninstall
  # ne saura jamais retirer. Le `rc` porte l'échec, le journal porte le fait.
  [[ "${#posed[@]}" -gt 0 ]] && prov_journal_note apt_installed "${posed[@]}"
  [[ "$rc" -eq 0 ]] && PROV_CHANGED=$((PROV_CHANGED + 1))
  return "$rc"
}

# ─── Substrat ─────────────────────────────────────────────────────────────────────────────────────
# docker : /.dockerenv (posé par le runtime Docker) ou LCARS_DOCKER=1 (posé par notre image).
# wsl    : kernel Microsoft. linux : le reste. La détection vit ICI, une fois (v1 la recopiait).

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
PROV_LAST_RC=0

# ⚠ COUTURE DE DÉCOR, MÊME IDIOME QUE `LCARS_SYSADMIN_UID` ET `LCARS_DOCKER`. Sans elle, tout témoin
# du mode réseau MESURE LA MACHINE qui le joue : la règle « sous WSL en NAT, on annonce localhost »
# n'est exerçable que sur un WSL en NAT, donc elle passe au vert chez son auteur et rougit ailleurs
# sans qu'aucune règle ait bougé. Mesuré le 2026-08-22 sur `.63` (Linux natif) : le témoin y tombait
# alors que le produit était juste. Un témoin qui n'est vrai que sur une machine ne garde rien.
wsl_networking_mode() {
  [[ -n "${LCARS_WSL_NETWORKING_MODE:-}" ]] && { echo "$LCARS_WSL_NETWORKING_MODE"; return 0; }
  local m
  m="$(wslinfo --networking-mode 2>/dev/null | tr -d '[:space:]')"
  # `wslinfo` absent = WSL antérieur au mode miroir. Il n'existait alors QUE le NAT : c'est un fait
  # de version, pas une supposition de repli.
  [[ -n "$m" ]] && { echo "$m"; return 0; }
  echo nat
}

# L'adresse source de sortie — vide si indéterminable. Vraie SEULEMENT là où on est joignable par
# elle : `advertise_addr` en est le seul appelant légitime.
# ⚠ `|| true` — MEME CLASSE QUE B5, TROISIEME FOIS DANS LA MEME JOURNEE. `ip` n'existe pas partout
# (l'image du job CI ne l'a pas), et sous `pipefail` une commande introuvable rend 127 que le
# pipeline propage : la fonction rend 127, l'assignation echoue, `set -e` tue l'appelant. Mesure du
# 2026-08-18 : huit temoins de `bench_up_verdict.bats` rouges DANS la CI et verts partout ailleurs,
# parce que `bench-up.sh` mourait a la ligne qui derive une adresse. « Vide si indeterminable » est
# le contrat de cette fonction ; sans ce garde elle ne le tenait pas.
lan_addr() { ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1 || true; }

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
  # ⚠ `PROV_SUBSTRATE` D'ABORD, LA SONDE SEULEMENT EN REPLI. Le runner a DÉJÀ tranché le substrat
  # (`provision --substrate`, `provision:126-128`) et l'exporte ; re-sonder ici en ferait une seconde
  # dérivation du même fait — celle-là même que l'en-tête de `48-forge-host` reproche à la version
  # d'avant. Conséquence concrète et pas seulement doctrinale : `--substrate linux` joué sur une
  # machine WSL prenait quand même la branche NAT, donc le drapeau ne portait pas jusqu'ici.
  local _sub="${PROV_SUBSTRATE:-$(detect_substrate)}"
  if [[ "$_sub" == "wsl" && "$(wsl_networking_mode)" == "nat" ]]; then
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
# ─── LES PORTS — FIXES PAR DÉFAUT, ET PERSONNE NE LES SONDAIT ───────────────────────────────────
#
# ⚖ USER 2026-08-22 : « les ports que tu montes, 3000 et 20999, ils sont fixes ? ils sont testés
# pour voir si c'est dispo ? » — fixes et surchargeables ; sondés, non.
#
# ⚠ CE N'ÉTAIT PAS SILENCIEUX, C'ÉTAIT MAL NOMMÉ, et c'est pire. Un port occupé fait échouer
# `compose up -d` (« port is already allocated ») et le module conclut « la forge ne converge pas » ;
# le deck, lui, ne bind pas et l'unité meurt en « posé mais PAS actif ». Dans les deux cas la cause
# est dans une sortie dumpée, jamais dans le verdict — l'opérateur cherche un défaut de LCARS quand
# le fait est « autre chose tient ce port ».
#
# ⚠ ET LE RISQUE N'EST PAS SYMÉTRIQUE. `3000` est le défaut de la moitié de l'écosystème de dev —
# React, Rails, Vite, Grafana. `20999` est choisi pour être improbable. Mesuré sur le poste de
# l'auteur : `3000` est tenu par la forge de LCARS elle-même, et les bancs sont déjà décalés en
# 3001/3002. Le produit CONNAÎT donc le besoin de ports distincts ; il ne le vérifiait pas.
#
# ⚠ « PRIS PAR NOUS » N'EST PAS « PRIS PAR UN AUTRE », et confondre les deux rendrait la sonde
# nuisible : au second passage, notre propre service tient le port, et refuser là serait casser
# l'idempotence. L'appelant tranche — il sait, lui, si le service qui répond est le sien.
port_taken() { # port_taken <port> -> 0 si quelque chose ÉCOUTE sur la loopback
  timeout 2 bash -c "</dev/tcp/127.0.0.1/$1" 2>/dev/null
}

# QUI le tient, quand on peut le dire. Sans privilège, `ss` ne rend pas le processus : on rend alors
# une chaîne vide plutôt qu'une phrase creuse — un « occupé par (inconnu) » n'aide personne, et
# prétendre nommer ce qu'on ne sait pas est la faute que ce dépôt paie le plus cher.
port_holder() { # port_holder <port> -> description, ou VIDE
  command -v ss >/dev/null 2>&1 || return 0
  ss -ltnp 2>/dev/null \
    | awk -v p=":$1\$" '$4 ~ p { for (i=1;i<=NF;i++) if ($i ~ /users:/) { print $i; exit } }' \
    | sed -e 's/users:((//' -e 's/))$//' -e 's/,fd=[0-9]*//' | head -1
}

as_human() {
  local home
  # `|| true` : même classe que B5 — sous pipefail, getent sur un user inconnu ferait échouer
  # l'assignation avant la garde p_fail juste en dessous.
  home="$(getent passwd "$PROV_HUMAN" | cut -d: -f6 || true)"
  [[ -n "$home" ]] || { p_fail "as_human: user inconnu: $PROV_HUMAN"; return 1; }
  if [[ "$(id -un)" == "$PROV_HUMAN" ]]; then
    "$@"
  elif [[ "$EUID" -eq 0 ]]; then
    # ⚠ LE `cd` FAIT PARTIE DE L'IDENTITE, ET SON ABSENCE A CASSE UNE INSTALLATION NATIVE. Cette
    # ligne posait HOME/USER/LOGNAME et laissait le REPERTOIRE COURANT de root. Un humain qui hérite
    # d'un cwd qu'il ne peut pas lire est un demi-humain : tout ce qui résout un chemin RELATIF
    # échoue, et le message n'accuse jamais le cwd.
    #
    # Mesure du 2026-08-20, poste natif Mintie : `75-projects` lance la porte `lcars project
    # reconcile` depuis un `provision apply` démarré en root avec cwd `/root` (0700). L'ERTS y
    # cherche ses modules par chemin relatif et rend `File operation error: eacces. Target:
    # ./Elixir.Logger.beam` — vingt lignes de `.beam` illisibles, aucune ne nommant le vrai fait :
    # le répertoire courant n'appartient pas à celui qui lit.
    #
    # `cd` dans un SOUS-SHELL : le cwd du module appelant n'est pas touché. Les 39 appelants
    # travaillent en chemins absolus, donc aucun ne dépend du cwd hérité — vérifié avant de changer.
    ( cd "$home" && runuser -u "$PROV_HUMAN" -- env HOME="$home" USER="$PROV_HUMAN" LOGNAME="$PROV_HUMAN" "$@" )
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
# Les bornes se LISENT dans login.defs, elles ne s'écrivent pas ici. `|| true` LOAD-BEARING : sous
# `set -euo pipefail`, un login.defs absent tuerait le module AVANT la garde, et une garde qui
# s'évanouit sur une lecture ratée est pire que pas de garde.
_uid_bound() { # <UID_MIN|UID_MAX> <défaut>
  local v; v="$(awk -v k="^$1" '$0 ~ k {print $2}' "${PASSWD_DEFS:-/etc/login.defs}" 2>/dev/null | head -n1 || true)"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '%s' "$2"
}

# ─── LE SIÈGE EST UN FAIT, ET IL N'A PAS DE DÉFAUT ──────────────────────────────────────────────
#
# `deploy/provision` le dérive de l'appelant de l'installeur avant tout module et l'exporte ;
# `64-services` le grave ensuite en `/etc/lcars/seat.uid`, `root:root`. Le FICHIER gagne quand il
# existe — il survit au shell et le gardé ne peut pas le réécrire ; la variable sert la fenêtre du
# provisionnement, avant que le fichier soit posé. L'absence des deux n'est pas la valeur `1000` :
# c'est une machine dont le siège n'est pas établi, et ça se dit.
prov_seat_uid() { # rend l'uid du siège, ou 1 si aucune source ne l'établit
  local f v
  f="${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}"
  if [[ -r "$f" ]]; then
    v="$(head -n1 -- "$f" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
  fi
  v="${LCARS_SYSADMIN_UID:-}"
  [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
  return 1
}

# ⚠ SIÈGE INCONNU ⇒ RÉPONSE NON, POUR TOUT LE MONDE. Un `:-1000` répondait « oui » à quiconque n'est
# pas 1000 — donc au siège lui-même dès qu'il est ailleurs, c'est-à-dire exactement le compte que
# cette fonction existe pour écarter. Se fermer est la seule direction sûre quand la borne manque.
is_fleet_human() { # [login] (défaut: PROV_HUMAN) — 0 si oui
  local login="${1:-$PROV_HUMAN}" uid uid_min seat
  uid="$(id -u -- "$login" 2>/dev/null || true)"
  [[ "$uid" =~ ^[0-9]+$ ]] || return 1
  seat="$(prov_seat_uid)" || return 1
  uid_min="$(_uid_bound UID_MIN 1000)"
  (( uid >= uid_min )) && (( uid != seat ))
}

# ─── fleet_humans — CEUX QUI EXISTENT DÉJÀ SUR CETTE MACHINE ────────────────────────────────────
#
# ⚠ ÉNUMÉRER N'EST PAS TESTER UN NOM, ET LA DIFFÉRENCE EST UNE BORNE. `is_fleet_human` répond « ce
# login-là peut-il lancer une fleet » : on le lui a nommé, donc la borne HAUTE ne sert à rien. Balayer
# `passwd` pose l'autre question, et `nobody` — uid 65534, présent sur toute machine — répond OUI à la
# règle basse seule. Mesuré le 2026-08-22 : une première écriture de cette fonction annonçait
# « cette machine porte déjà : nobody ».
#
# `UID_MAX` est la borne que login.defs déclare pour exactement ça. Et la lecture passe par le
# FICHIER, jamais par `id` : c'est ce qui rend la population mesurable par un témoin (`PASSWD_FILE`,
# même couture que le convergeur d'humains).
fleet_humans() {
  local seat
  # Siège inconnu : on ne rend PAS une liste. Un `:-1000` ferait entrer le siège dans la population
  # dès qu'il est ailleurs, et une liste fausse ici se lit comme une population.
  seat="$(prov_seat_uid)" || {
    echo "fleet_humans: siège non établi (ni ${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}, ni LCARS_SYSADMIN_UID) — population non mesurable" >&2
    return 1
  }
  awk -F: -v m="$(_uid_bound UID_MIN 1000)" -v M="$(_uid_bound UID_MAX 60000)" \
      -v s="$seat" \
      '$3+0 >= m && $3+0 <= M && $3+0 != s {print $1}' "${PASSWD_FILE:-/etc/passwd}"
}

# Racine du repo (le checkout depuis lequel on provisionne) — dérivée UNE fois de la position de
# la lib (fleet/deploy/lib/ → ../../..), jamais re-devinée par heuristique dans un module.
repo_root() { readlink -f "$(dirname "$PROVISION_LIB")/../../.."; }

# ─── LA RÉVISION DE LA SOURCE, ET POURQUOI ELLE DOIT VOYAGER AVEC LA COPIE ───────────────────────
#
# UN PROVISIONNEMENT NE DIT PAS D'OÙ IL VIENT, ET C'EST LA PANNE QU'ON NE VOIT JAMAIS. Chaque module
# converge son état-cible vers ce que dit SA source — et « conforme » ne veut alors dire que
# « conforme à l'arbre que j'ai sous la main ». Un checkout en retard réinstalle donc l'état d'avant,
# **en rendant vert**, parce que du point de vue du module il n'y a rien à redire.
#
# MESURE DU 2026-08-21, ET ELLE A COÛTÉ UN COMPTE UTILISATEUR. Un correctif d'allocation d'uid était
# posé et vérifié sur une machine ; `62-runtime-helpers` a ensuite reposé ses auxiliaires depuis un
# clone resté six commits en arrière, ce qui a REMIS EN PLACE l'ancienne formule. Le service systemd
# tournait dessus. La collision d'uid suivante était mécanique, et rien nulle part ne pouvait la
# relier à un arbre en retard : le module avait fait exactement son travail.
#
# ⚠ ET LA COPIE, ELLE, N'EST PAS UN CHECKOUT. `/opt/lcars/fleet` est un `cp -a` : `git rev-parse`
# n'y répond rien, donc un `provision` lancé depuis cette copie — c'est le cas du convergeur —
# n'aurait AUCUN moyen de nommer sa propre origine. D'où le fichier : celui qui copie ÉCRIT la
# révision qu'il a copiée, et celui qui lit la trouve. La révision voyage avec le code.
PROV_SOURCE_STAMP="${LCARS_SOURCE_STAMP:-.source-revision}"

prov_source_rev() { # prov_source_rev [racine] — la révision de l'arbre, ou « inconnue »
  local root="${1:-$(repo_root)}" rev
  if rev="$(git -C "$root" rev-parse --short=8 HEAD 2>/dev/null)" && [[ -n "$rev" ]]; then
    # Un arbre modifié n'EST pas sa révision : le dire évite qu'une mesure locale soit lue comme
    # une mesure sur un commit publié.
    git -C "$root" diff --quiet HEAD -- 2>/dev/null || rev="$rev+local"
    printf '%s\n' "$rev"
    return 0
  fi
  if [[ -r "$root/$PROV_SOURCE_STAMP" ]]; then
    printf '%s\n' "$(head -n1 "$root/$PROV_SOURCE_STAMP" | tr -d '[:space:]')"
    return 0
  fi
  printf 'inconnue\n'
}

# `A est-il un ANCÊTRE de B ?` — donc « la source est-elle EN RETARD sur ce qui est déjà posé ? ».
# Rend 0 (oui, en retard), 1 (non) ou 2 (impossible à dire : pas de git, ou l'une des deux révisions
# est inconnue de cet arbre). Le troisième cas EXISTE et compte : un clone re-cloné ne connaît pas
# forcément le commit d'où sort ce qui est installé, et répondre « non » là-dessus serait un mensonge.
prov_rev_is_behind() { # prov_rev_is_behind <rev_source> <rev_posee> [racine]
  local a="${1%%+*}" b="${2%%+*}" root="${3:-$(repo_root)}"
  [[ -n "$a" && -n "$b" && "$a" != "inconnue" && "$b" != "inconnue" ]] || return 2
  [[ "$a" == "$b" ]] && return 1
  git -C "$root" cat-file -e "$a^{commit}" 2>/dev/null || return 2
  git -C "$root" cat-file -e "$b^{commit}" 2>/dev/null || return 2
  git -C "$root" merge-base --is-ancestor "$a" "$b" 2>/dev/null && return 0
  return 1
}

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
# ─── LE SIEGE : le #1 de la forge et le compte unix sont le MEME acteur ─────────────────────────
#
# La regle : celui des deux qui existe nomme l'autre, et le lien est enregistre — ligne `forge_id=1`
# de `forge-uid.map`, la meme table que les humains de fleet. Une seconde table pour tenir une ligne
# de la premiere ferait deux verites d'un meme fait.
#
# ⚠ CES PRIMITIVES VIVENT ICI PARCE QUE LES DEUX RAILS EN ONT BESOIN AU MEME MOMENT, ET QUE CE
# MOMENT EST AVANT L'EXECUTEUR. Mesure : la boite lance `provision apply` (`entrypoint.sh:459`) puis
# l'executeur (`:655`) ; le poste nomme son admin forge au rang 48 et demarre l'unite au rang 64.
# Un verbe de l'executeur ne peut donc servir ni l'un ni l'autre. Le second lecteur du jeton master
# existe deja et il est delibere — `resolve_admiral`, en root, avant que quoi que ce soit d'autre
# existe : une primitive partagee REMPLACE deux copies de cette derivation, elle n'en ajoute pas.
#
# ⚠ ELLES LISENT ET ELLES ENREGISTRENT ; elles ne CREENT aucun compte. Chaque rail a deja son geste
# de creation (`useradd` a l'entrypoint, le compte forge dans `48-forge-host`) et il le garde : une
# lib sourcee qui creerait des comptes unix ET forge porterait une autorite que personne ne lui a
# donnee en la sourcant.

prov_seat_from_map() { # le login du siege enregistre, ou vide
  [[ -r "$PROV_UID_MAP_FILE" ]] || return 0
  awk -F'\t' '$1 == 1 { print $3; exit }' "$PROV_UID_MAP_FILE" 2>/dev/null
}

# ⚠ ECRIT UNE FOIS, JAMAIS RE-ECRIT. Le home du siege vit sous son nom ; changer ce nom plus tard
# laisserait un home orphelin et un compte qui ne le retrouve pas. La premiere resolution fait foi —
# c'est elle qui correspond a ce qui est sur le disque.
# Les deux arguments sont REQUIS et sans defaut : l'uid est celui que le systeme a donne, jamais un
# nombre qu'on espere, et les deux appelants le tiennent deja. Un `:-1000` ici aurait ete la
# troisieme copie du meme defaut sur une valeur qui ne peut pas etre vide.
prov_seat_record() { # prov_seat_record <login> <uid>
  local login="${1:?prov_seat_record: login requis}" uid="${2:?prov_seat_record: uid requis}"
  [[ -n "$(prov_seat_from_map)" ]] && return 0
  mkdir -p "$(dirname "$PROV_UID_MAP_FILE")" 2>/dev/null || true
  printf '1\t%s\t%s\n' "$uid" "$login" >> "$PROV_UID_MAP_FILE" 2>/dev/null || return 1
  chmod 0640 "$PROV_UID_MAP_FILE" 2>/dev/null || true
}

# Le #1 de la forge, resolu par son ID et jamais par son nom : Gitea conserve l'`id` au renommage,
# le login est une etiquette. Vide quand la forge est muette ou le jeton illisible — un appelant qui
# lit du vide ne doit pas conclure « personne », seulement « pas su ».
prov_forge_seat_login() {
  local tok
  tok="$(tr -d '[:space:]' < "$PROV_MASTER_TOKEN_FILE" 2>/dev/null || true)"
  [[ -n "$tok" && -n "${PROV_FORGE_URL:-}" ]] || return 0
  # `-K -` : le jeton ne passe pas par argv, lisible dans /proc de tout l'hote.
  printf 'header = "Authorization: token %s"\n' "$tok" \
    | curl -sS -K - -m 15 "${PROV_FORGE_URL%/}/api/v1/admin/users?limit=50" 2>/dev/null \
    | jq -r 'map(select(.id == 1)) | .[0].login // empty' 2>/dev/null || true
}

# prov_seat_binding [candidat_unix] — POSE TROIS GLOBALES, N'IMPRIME RIEN :
#
#   PROV_SEAT_BINDING   le verdict d'ACCORD, un mot
#   PROV_SEAT_LOGIN     le login du siege, vide seulement sur `unknown`
#   PROV_SEAT_SOURCE    d'ou il vient — `table` | `forge` | `candidat`, vide sur `unknown`
#
# ⚠ TROIS GLOBALES ET PAS UN `echo`, POUR LA MEME RAISON QUE `advertise_addr` — et j'ai reconstruit
# son defaut avant de relire son commentaire. Un appelant ecrit naturellement
# `v="$(prov_seat_binding x)"`, or `$( )` ouvre un SOUS-SHELL : la valeur revient par stdout et les
# globales meurent avec lui.
#
# ⚠ LE VERDICT ET LA SOURCE SONT DEUX FAITS. Un verdict qui s'appellerait `forge_only` alors que le
# login vient de la TABLE nommerait la mauvaise autorite dans le message d'un operateur qui
# diagnostique — et c'est precisement quand la forge est en carafe qu'il lira cette ligne.
#
# Les cinq verdicts :
#
#   agree     le cote durable et le candidat unix nomment le meme acteur
#   diverge   ils nomment deux acteurs — la branche que personne n'avait, et le controle qui
#             aurait attrape la divergence avant qu'elle casse
#   derived   le cote durable nomme, unix n'a pas de candidat a confronter
#   seeded    unix nomme, le cote durable est muet
#   unknown   ni l'un ni l'autre : on REFUSE de nommer plutot que d'inventer — un siege invente
#             s'installe et survit a la cause qui l'a produit, un refus se lit et se repare
#
# La table PASSE AVANT la forge : elle survit au conteneur et ne demande aucun reseau, donc un
# redemarrage reste possible pendant que la forge est en carafe.
PROV_SEAT_BINDING=""
PROV_SEAT_LOGIN=""
PROV_SEAT_SOURCE=""
prov_seat_binding() { # prov_seat_binding [candidat_unix]
  local candidat="${1:-}" durable source

  PROV_SEAT_BINDING=""
  PROV_SEAT_LOGIN=""
  PROV_SEAT_SOURCE=""

  durable="$(prov_seat_from_map)"
  source=table
  if [[ -z "$durable" ]]; then
    durable="$(prov_forge_seat_login)"
    source=forge
  fi

  if [[ -n "$durable" && -n "$candidat" ]]; then
    PROV_SEAT_LOGIN="$durable"
    PROV_SEAT_SOURCE="$source"
    if [[ "$durable" == "$candidat" ]]; then PROV_SEAT_BINDING=agree; else PROV_SEAT_BINDING=diverge; fi
  elif [[ -n "$durable" ]]; then
    PROV_SEAT_LOGIN="$durable"; PROV_SEAT_SOURCE="$source"; PROV_SEAT_BINDING=derived
  elif [[ -n "$candidat" ]]; then
    PROV_SEAT_LOGIN="$candidat"; PROV_SEAT_SOURCE=candidat; PROV_SEAT_BINDING=seeded
  else
    PROV_SEAT_BINDING=unknown
  fi

  # `return 0` EXPLICITE : sans lui la fonction rend le code du dernier `if`, donc 1 sur la branche
  # `unknown`. Tous les appelants tournent sous `set -e` — meme cicatrice qu'`advertise_addr`.
  return 0
}

prov_roles() {
  local out="$PROV_ROLES" root
  local bin="${PROV_RELEASE_BIN:-$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet}"
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

  # `$out` est une LISTE separee par des espaces, a eclater — c'est le but de cette ligne.
  # shellcheck disable=SC2086 # eclatement voulu : une entree par mot
  printf '%s\n' $out | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
