#!/usr/bin/env bash
# ⚠ SC2034 AU NIVEAU DU FICHIER, ET C'EST LE CONTRAT DE CETTE LIB QUI LE JUSTIFIE. Ses fonctions
# rendent leurs resultats par des GLOBALES `PROV_*` que l'APPELANT lit : `prov_seat_binding` pose
# trois variables et n'imprime rien, `run_step` laisse le code reel dans `PROV_LAST_RC`. Aucune n'est
# relue ici, donc elles sont toutes vues inutilisees. Une directive par site serait la meme phrase
# a chaque fois — et elle doit preceder TOUTE commande, `set -` compris, sinon elle est inerte.
# shellcheck disable=SC2034
# SOURCE: deploy/lib/provision-lib.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — bibliothèque des modules : primitives convergentes, écriture atomique, verdicts réels
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

[[ -n "${PROVISION_LIB_LOADED:-}" ]] && return 0
PROVISION_LIB_LOADED=1

# shellcheck source=docker-endpoint.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/docker-endpoint.sh"

# ─── Données par défaut — une SEULE définition, consommée par tous les modules ───────────────────
: "${PROV_ROOT:=/opt/lcars}"

: "${PROV_PREFIX:=$PROV_ROOT/runtime}"          # install RO du runtime (modèle 3 zones d'etc/deploy-release.sh)
: "${PROV_LINK_DIR:=/usr/local/bin}"           # symlinks PATH (miroir de LCARS_INSTALL_LINK_DIR d'install.sh)
: "${PROV_FLEET_GROUP:=fleet}"                 # groupe de lecture des tokens + de l'install RO
: "${PROV_AUTHORITY_USER:=lcars-authority}"

# ─── LE GROUPE QUI PORTE EXACTEMENT UN POUVOIR : TRAVERSER ──────────────────────────────────────
# ⚠ SURTOUT PAS `$PROV_FLEET_GROUP` : celui-la porte deja la lecture de l'install RO et des jetons,
# le reutiliser ici accorderait tout le reste par la meme occasion. Une console montee sous le
# mauvais groupe est vivante et injoignable — un pouvoir qu'on ne sait pas dire en une phrase est
# trop large.
: "${PROV_CONSOLE_GROUP:=lcars-console}"       # traverser /run/lcars/console/<humain>, RIEN d'autre
: "${PROV_CATALOGUES_WORK:=$PROV_ROOT/var/tofu}"  # recettes tofu par catalogue (etat = SENSIBLE)
: "${PROV_TOKENS_DIR:=$PROV_ROOT/var/tokens}"  # role-tokens forge (contrat FORGE_ROLE_TOKENS_DIR)
: "${PROV_FORGE_SEED_FILE:=$PROV_TOKENS_DIR/forge-seed.pass}"  # seed bootstrap tofu (handoff → A4)
# L'AUTORITE DE CREATION, posee par `box config`. ⚠ SON SUFFIXE N'EST PAS `.gitea_token`, celui des
# jetons de ROLE (`<login>.gitea_token`, contrat FORGE_ROLE_TOKENS_DIR) : qui globbe ce repertoire ne
# doit pas ramasser un site-admin en croyant lire un role.
: "${PROV_MASTER_TOKEN_FILE:=$PROV_TOKENS_DIR/forge-master.token}"
: "${PROV_UID_MAP_FILE:=$PROV_TOKENS_DIR/forge-uid.map}"

# ─── LES TROIS PROJETS COMPOSE DU POSTE, ET LE RESEAU DE LA FORGE ───────────────────────────────
: "${PROV_FORGE_BASE:=lcars}"
: "${PROV_FORGE_PROJECT:=${PROV_FORGE_BASE}-forge}"
: "${PROV_RUNNER_PROJECT:=${PROV_FORGE_BASE}-runner}"
# Le reseau que compose cree pour un projet sans `networks:` explicite. Le runner le REJOINT : depuis
# un conteneur, l'adresse publiee de la forge (`127.0.0.1:<port>`) designe ce conteneur-la.
: "${PROV_FORGE_NET:=${PROV_FORGE_PROJECT}_default}"
# ⚠ CETTE LISTE GAGNE SUR LES AUTRES : `63-forge-tokens` passe `--roles "$PROV_ROLES"` au mint A4, ecrasant
# le defaut du `.sh`. Un role absent ICI = pas de token sur une fleet fraiche = rail ops en
# `role_token_unavailable` (BL-6-34). Son egalite avec les autres listes n'est pas derivee (BL-6-45) :
# elle se tient a la main.
: "${PROV_ROLES:=system_architect system_chief system_gatekeeper fleet_engineer fleet_scribe fleet_qualifier fleet_reviewer fleet_scoper fleet_vulcan}"
: "${PROV_CATALOGUES_DIR:=/opt/lcars/var/catalogues}"
# ⚠ L'ANCIENNE ADRESSE DU CACHE, ET ELLE A BESOIN D'UNE SOURCE COMME LA NOUVELLE. Le cache a vecu
# sous `/home` ; deux gestes nomment encore cette adresse — `45-catalogues` pour DIRE que le
# reliquat subsiste, `provision uninstall` pour le porter a son bilan de sortie. Deux repli nommes
# (`${VAR:-/home/catalogues}`) auraient fait deux sources d'un meme fait, ce que le mur des racines
# refuse a juste titre : celle qu'on lit n'est jamais celle qu'on a corrigee.
: "${PROV_LEGACY_CATALOGUES_DIR:=/home/catalogues}"
: "${PROV_SYSTEM_ACCOUNT:=system_starfleet}"       # compte forge du SYSTÈME (signe les marqueurs)
: "${PROV_SYSTEM_TOKEN_FILE:=$PROV_TOKENS_DIR/$PROV_SYSTEM_ACCOUNT.gitea_token}"
: "${PROV_FORGE_ORG:=fleet}"                   # org qui porte les repos projet (forge.tf)
# La team d'ENROLEMENT, lue par le convergeur d'humains et par le deck.
: "${PROV_HUMANS_TEAM:=humans}"                # team forge dont l'adhesion vaut enrolement
# LE FICHIER EST LE SEUL CANAL ENTRE MODULES : ils sont des PROCESSUS, donc `48-forge-host` ne peut
# rien exporter vers `63-forge-tokens`. Il écrit son adresse, on la relit ici.
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
: "${PROV_DECK_PORT:=20999}"
: "${PROV_DECK_OIDC_FILE:=/etc/lcars/deck-oidc.json}"
: "${PROV_DECK_ORIGINS:=${LCARS_DECK_ORIGINS:-}}"
# Combien de lignes d'une commande en échec atterrissent à l'écran (le reste vit dans le fichier).
: "${PROV_DUMP_LINES:=40}"
# ⚠ `PROV_EXPECTED_REPO` N'A PAS DE DÉFAUT, ET C'EST L'INVARIANT : l'autorité se DÉCLARE, elle ne se
# devine pas. Vérifier le remote APRÈS le pull inverse la chaîne (F-E1).
: "${PROV_UPDATE_REMOTE:=origin}"
: "${PROV_EXPECTED_REPO:=}"
# ⚠ `mix.exs` EXIGE `~> 1.18`, ET C'EST LUI L'AUTORITÉ. Ce plancher-ci n'est pas une seconde
# exigence : il est ce que le rail vérifie AVANT de bâtir, pour que l'échec dise « distro trop
# vieille » au lieu de mourir dans `mix deps.get`. Les deux se déplacent ensemble.
: "${PROV_ELIXIR_OTP_MAJOR:=27}"
: "${PROV_ELIXIR_MIN:=1.18}"
: "${PROV_HUMAN:=${SUDO_USER:-$(id -un)}}"

# ─── Verdicts / log ───────────────────────────────────────────────────────────────────────────────
PROV_MODULE_TAG="${PROVISION_MODULE:-$(basename "${0:-provision-lib}")}"
PROV_CHANGED=0
PROV_DRIFT=0
PROV_FAILED=0

# ─── LA PALETTE — LA MÊME QUE CELLE DU BANDEAU D'ENTRÉE ─────────────────────────────────────────
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

# ─── p_fact <nom> <valeur> — LE MEME FAIT, POUR UNE MACHINE ─────────────────────────────────────
#
# Les `p_*` ci-dessus s'adressent a un humain : ils racontent. Un appelant qui doit DECIDER (la
# porte, qui restreint son menu selon ce que la machine permet) a besoin du fait nu, et le tirer par
# `grep` de ces lignes en ferait une prose-lock — le jour ou on reformule « docker repond », la
# porte se trompe en silence.
#
# Meme idiome que `prov_announce_credential` : un composant sait, il l'ECRIT la ou un autre peut le
# lire. L'appelant pose `PROV_FACTS_FILE`, le module y depose ses faits, l'appelant les relit.
#
# ⚠ SILENCIEUX SANS LA VARIABLE, et c'est deliberé. Un fait n'a d'interet que pour qui l'a demande ;
# l'imprimer par defaut doublerait chaque ligne du rapport. Un module reste donc lisible seul, et le
# canal ne change RIEN a ce qu'un operateur voit.
#
# ⚠ `2>/dev/null` AVANT `>>` : les redirections se traitent de gauche a droite, ecrite apres elle
# arrive trop tard et le « No such file » du shell pollue la sortie de l'appelant (meme regle que
# `prov_journal_acc`). Et `return 0` explicite, meme motif que `p_ok` : une fonction qui RAPPORTE ne
# doit pas pouvoir renverser le verdict qu'elle rapporte.
p_fact() { # p_fact <nom> <valeur…>
  [[ -n "${PROV_FACTS_FILE:-}" ]] || return 0
  [[ "$#" -ge 2 ]] || return 0
  printf '%s=%s\n' "$1" "${*:2}" 2>/dev/null >> "$PROV_FACTS_FILE" || true
  return 0
}

# Sortie standard d'un module : à appeler en FIN de check() et d'apply(). Le runner lit ces codes
# tels quels — les changer ici change son bilan.
#   check   0 conforme · 1 drift constaté · 2 échec de sonde (un `p_fail` a été appelé)
#   apply   0 convergé · 1 au moins un échec · 2 appliqué, DRIFT RÉSIDUEL
#   p_die   1, verdict rendu — fatal immédiat
#   tout    3 MORT avant d'avoir rendu son verdict, posé par `_prov_exit_guard` ci-dessous
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
verdict_apply() {
  PROV_VERDICT_RENDERED=1
  [[ "$PROV_FAILED" -gt 0 ]] && exit 1
  [[ "$PROV_DRIFT" -gt 0 ]] && exit 2
  exit 0
}

# ─── run_quiet — succès silencieux, échec verbeux (l'école mail-in-a-box `hide_output`) ──────────
# ─── run_step <label> -- <cmd…> — UNE ETAPE LONGUE QUI DIT OU ELLE EN EST ───────────────────────
#
# Pour les etapes de plusieurs minutes, ou le mutisme de `run_quiet` ne distingue plus « ca
# travaille » de « c'est fige ». Sur un terminal : UNE ligne reecrite en place. Ailleurs (log, CI) :
# une ligne par CHANGEMENT de phase.
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
# non un verdict — `etc/deploy-release.sh` rend 3 pour « release posee, cablage PATH incomplet », le cas
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
  if [[ "${PROV_VERBOSE:-0}" -eq 1 ]]; then
    "$@" || rc=$?
    [[ "$rc" -eq 0 ]] || p_fail "commande en échec (rc=$rc) : $*"
    return "$rc"
  fi
  out="$(mktemp "${TMPDIR:-/tmp}/prov-out.XXXXXX")"
  "$@" >"$out" 2>&1 || rc=$?
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
# ⚠ `TMPDIR` N'EST PAS HONORE : une variable d'environnement preservee a travers `sudo` deplacerait
# le verrou dans un dossier que l'appelant choisit, et un verrou privilegie dont l'emplacement est un
# parametre de l'appelant n'est pas un verrou. Un emplacement introuvable ARRETE.
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
  # ⚠ LE RC DE `cat` SE LIT, ET IL NE SE LISAIT PAS — LA LIGNE ETAIT NUE. Les trois gestes suivants
  # (chmod, chown, mv) REUSSISSENT tous sur un tampon tronque : le fichier bascule, PROV_CHANGED
  # s'incremente, et `p_chg` imprime POSE. Un echec d'ecriture ressortait donc en SUCCES.
  #
  # VU : `( ulimit -f 0; printf x | write_atomic "$D/cible" 0644 )` rendait
  # « POSE », rc 0, et un fichier de ZERO octet. Tout ce que le rail pose sous /etc passe par ici —
  # `seat.uid` vide fait refuser tout `fleet start` par le GUARD B ; `services.env` vide demarre
  # les quatre daemons sans FORGE_BASE_URL ; `wsl.conf` vide laisse l'interop Windows OUVERTE sur
  # une machine dont le bilan annonce la frontiere armee. Le pire des trois est le dernier : il est
  # SILENCIEUX et il ment sur une frontiere de securite.
  cat > "$tmp" || { rm -f "$tmp"; p_fail "write_atomic: ecriture du tampon RATEE (disque plein ? quota ?): $dest"; return 1; }
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
    # ⚠ UN MODE NUMERIQUE NE RETIRE JAMAIS LE SETGID D'UN REPERTOIRE — c'est GNU chmod, pas une
    # option : « you can set (but not clear) the bits with a numeric mode ». Un repertoire arrive
    # en 2755 des qu'il herite d'un parent setgid ou qu'un `cp -a src/. dst/` lui recopie celui
    # de sa source (tout checkout pose dans un arbre `fleet` setgid). Le `chmod 0755` passait, la
    # relecture lisait 2755, et la primitive rendait « mode 2755 ≠ 755 après chmod » : le module
    # echouait sur un etat qu'il venait de poser, et le rail cessait d'etre rejouable.
    # Cas vu : un second apply de `44-media` sur `/opt/lcars/share/avatars`.
    # On efface d'abord les bits speciaux ; le mode numerique REPOSE ensuite ceux qu'il demande
    # (2775 remet son setgid), donc rien n'est perdu pour un objet qui les veut.
    chmod u-s,g-s,o-t "$path" 2>/dev/null || true
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
  cur_mode="$(stat -c '%a' "$path")"
  [[ "$cur_mode" == "$want_mode" ]] || { p_fail "ensure_mode: mode $cur_mode ≠ $want_mode après chmod: $path"; return 1; }
  if [[ "$changed" -eq 1 ]]; then PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "perms $mode ${owner:+$owner }$path"; fi
  return 0
}

# ─── ensure_dir <path> <mode> [owner:group] ──────────────────────────────────────────────────────
ensure_dir() {
  local path="$1" mode="$2" owner="${3:-}"
  prov_refuse_symlink_path "$path" || return 1
  if [[ ! -d "$path" ]]; then
    mkdir -p "$path" || { p_fail "ensure_dir: mkdir refusé: $path"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "dir $path"
    prov_journal_note posed_dir "$path"
  fi
  ensure_mode "$path" "$mode" "$owner"
}

# ─── prov_scaffold_dir / prov_promote_dir — L'ECHAFAUDAGE NE SE JOURNALISE PAS (M8) ─────────────
#
# ⚠ LE JOURNAL ACCUMULAIT DES CHEMINS D'ECHAFAUDAGE (relecture hostile du 2026-09-04). Les poseurs
# atomiques (`16-node`, `44-media`, `62-runtime-helpers`) creaient leur `.partial` / `.new` par
# `ensure_dir`, qui note `posed_dir` : le journal du banc portait `/opt/node-24.20.0.partial`,
# `/opt/lcars/share/doc.partial`, `/opt/lcars/{etc,services,bin,…}.new` — des repertoires qui
# n'existent plus une seconde apres la bascule. Ceux qu'aucun ancetre declare n'absorbe remontent
# dans la ligne « hors table » du plan d'uninstall : du bruit sur la seule ligne dont tout
# l'interet est que l'operateur ne peut PAS en deviner le contenu.
#
# Un repertoire d'echafaudage se note APRES la bascule, SOUS SON NOM FINAL — et c'est la primitive
# qui bascule qui le note, pour que « ce qu'une primitive pose, elle le note » reste vrai (le
# temoin du journal interdit `prov_journal_note posed_dir` dans un module). Ni compteur ni « POSÉ »
# ici : la bascule est le geste que le module annonce lui-meme.
prov_scaffold_dir() { # prov_scaffold_dir <chemin> <mode> [owner] — un repertoire de travail, hors journal
  local path="$1" mode="$2" owner="${3:-}"
  prov_refuse_symlink_path "$path" || return 1
  [[ -d "$path" ]] || mkdir -p "$path" || { p_fail "prov_scaffold_dir: mkdir refusé: $path"; return 1; }
  chmod "$mode" "$path" || { p_fail "prov_scaffold_dir: chmod $mode refusé: $path"; return 1; }
  [[ -z "$owner" ]] || chown "$owner" "$path" || { p_fail "prov_scaffold_dir: chown $owner refusé: $path"; return 1; }
  return 0
}
prov_promote_dir() { # prov_promote_dir <echafaudage> <final> — bascule (rm -rf du final, mv), puis note le nom FINAL
  local from="$1" to="$2"
  [[ -d "$from" ]] || { p_fail "prov_promote_dir: échafaudage absent: $from"; return 1; }
  [[ -n "$to" && "$to" != / ]] || { p_fail "prov_promote_dir: destination vide ou racine"; return 1; }
  rm -rf -- "$to"
  mv -- "$from" "$to" || { p_fail "prov_promote_dir: bascule refusée: $from → $to"; return 1; }
  prov_journal_note posed_dir "$to"
  return 0
}

# ─── ensure_group / ensure_member — création idempotente ─────────────────────────────────────────
# prov_group_owns_preserved <groupe> <racine preservee…> -> 0 si un objet PRESERVE porte ce groupe
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
prov_manifest_gid() {
  local grp="$1" f="${LCARS_SYSTEM_MANIFEST:-$(dirname "$PROVISION_LIB")/../system.manifest}"
  [[ -r "$f" ]] || return 0
  # `c` est la classe DECOUPEE de son trait : `group:cond` reste un groupe, et son GID se lit.
  # ⚠ `-` EST UN GID ABSENT, PAS UN GID. Un groupe declare sans numero est declare FLOTTANT : la
  # table dit qu'on a le droit de le poser, elle ne dit pas lequel. Rendre le tiret tel quel ferait
  # un `groupadd -g -`, c'est-a-dire un refus a l'execution la ou l'intention etait « n'impose rien ».
  awk -v g="$grp" '{ c=$1; sub(/:.*/, "", c) } c=="group" && $2==g && $3!="-" { print $3; exit }' "$f"
}

ensure_group() {
  local grp="$1" gid="${2:-}"
  [[ -n "$gid" ]] || gid="$(prov_manifest_gid "$grp")"
  if ! getent group "$grp" >/dev/null; then
    local -a args=()
    [[ -n "$gid" ]] && args+=(-g "$gid")
    run_quiet groupadd "${args[@]}" "$grp" || return 1
    getent group "$grp" >/dev/null || { p_fail "groupe $grp absent après groupadd"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "groupe $grp${gid:+ (gid $gid, table)}"
    prov_journal_note posed_group "$grp"
    return 0
  fi
  local cur; cur="$(getent group "$grp" | cut -d: -f3)"
  [[ -z "$gid" || "$cur" == "$gid" ]] \
    || p_drift "groupe $grp : gid $cur, la table declare $gid — une machine ne se renumerote pas, elle se rebuilde"
}


# ─── prov_in_group <user> <groupe> — l'appartenance EFFECTIVE, capturee puis testee ─────────────
# ⚠ PAS `id -nG | tr | grep -qx` (DI-13, la classe de DI-12). Sous `pipefail`, `grep -q` sort au
# premier match et ferme le tuyau ; un producteur qui ecrit encore prend SIGPIPE et le pipeline
# rend 141 — « pas membre » alors qu'il l'est, une fois sur dix sous charge. Six sites portaient la
# forme (20, 21, 22 x2, cette lib x2). Capturer, puis tester la capture : aucun lecteur ne ferme
# rien avant la fin. MUR I16 (idiom_walls) interdit le retour de la forme.
# `pgrep -f "$x"` VOIT SON PROPRE APPELANT des que l'argv de celui-ci contient `x` (un `bash -c
# '... pgrep -f x ...'`, un `ssh host 'pgrep -f x'`, un temoin qui cite le chemin) — trois fois
# mordu dans ce chantier, une fois en tuant la commande qui mesurait. Le motif `[x]yz` matche
# `xyz` mais pas la chaine `[x]yz` qui le porte : c'est LA forme, et le MUR I17 l'exige partout.
prov_pgrep_pattern() { # prov_pgrep_pattern <chaine> -> le motif ERE qui ne matche pas son porteur
  local s="$1"; printf '[%s]%s\n' "${s:0:1}" "${s:1}"
}

prov_in_group() { # prov_in_group <user> <groupe> -> 0 si <user> est membre de <groupe> (session : id -nG)
  local groups; groups="$(id -nG "$1" 2>/dev/null)" || return 1
  [[ " $groups " == *" $2 "* ]]
}

ensure_member() {
  local user="$1" grp="$2"
  id "$user" >/dev/null 2>&1 || { p_fail "ensure_member: user inconnu: $user"; return 1; }
  if ! prov_in_group "$user" "$grp"; then
    run_quiet usermod -aG "$grp" "$user" || return 1
    prov_in_group "$user" "$grp" || { p_fail "$user toujours hors de $grp après usermod"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1))
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
# Contenu du bloc sur stdin. Le bloc ENTRE marqueurs est REMPLACÉ intégralement à chaque run, donc
# il converge vers la source COURANTE — un grep-marker suivi d'un append convergerait vers le
# PREMIER état écrit, et un bloc corrigé dans le source ne se réparerait jamais chez l'installé.
# Tout ce qui est HORS marqueurs est préservé octet pour octet.
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

# ─── prov_journal_note <clef> <valeur…> — CE QUI A ÉTÉ POSÉ *ICI* ───────────────────────────────
# ⚠ C'EST UNE NOTE, PAS UN VERDICT. Un journal qui échoue ne fait pas échouer un apply : il raconte,
# il ne décide pas. Sans accumulateur (`doctor`, module joué nu, témoin), la fonction est muette et
# rend 0 — un appelant n'a jamais à savoir si le journal existe.
#
# ⚠ LA NOTE VIT DANS LES PRIMITIVES, JAMAIS DANS LES MODULES : la poser dans chaque module
# demanderait à chaque site d'appel de S'EN SOUVENIR, et un poseur qui doit se souvenir oubliera.
# Ici, le prochain poseur est tracé par construction, sans qu'aucun module ne change.
prov_journal_note() { # prov_journal_note <clef> <valeur…>
  [[ -n "${PROV_JOURNAL_ACC:-}" ]] || return 0
  [[ "$#" -ge 2 ]] || return 0
  # ⚠ `2>/dev/null` AVANT `>>`, ET L'ORDRE EST LOAD-BEARING. Les redirections se traitent de GAUCHE
  # A DROITE : écrite après, elle arrive trop tard — l'ouverture a déjà échoué et le shell a déjà
  # imprimé son « No such file » sur stderr. La fonction survit, et pollue la sortie de son appelant.
  printf '%s %s\n' "$1" "${*:2}" 2>/dev/null >> "$PROV_JOURNAL_ACC" || true
  return 0
}

# ─── prov_announce_credential <libellé> <login> <secret> — CE QUI NE SE RELIRA PLUS ──────────────
# ⚠ LE FICHIER EST EN 0600 ET IL EST DÉTRUIT APRÈS IMPRESSION, par l'appelant racine qui l'a créé :
# le secret ne survit pas à l'installation qui l'a produit.
prov_announce_credential() { # prov_announce_credential <libellé> <login> <secret>
  [[ "$#" -ge 3 ]] || return 0
  if [[ -n "${PROV_ANNOUNCE_FILE:-}" ]]; then
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" 2>/dev/null >> "$PROV_ANNOUNCE_FILE" || true
    return 0
  fi
  prov_print_credentials <<< "$(printf '%s\t%s\t%s\n' "$1" "$2" "$3")"
}

# ⚠ `printf '%-60s'` COMPTE DES OCTETS, PAS DES COLONNES, et tout libellé français casse alors le
# cadre : « — », « é » et « ' » pèsent deux ou trois octets pour une seule colonne. `${#s}` en bash
# compte des CARACTÈRES sous une locale UTF-8, donc la marge se calcule et ne se délègue pas.
_prov_pad() { # <texte> <colonnes>
  local s="$1" n=$(( $2 - ${#1} ))
  (( n < 0 )) && n=0
  printf '%s%*s' "$s" "$n" ''
}

# ─── prov_box_emit [--rule] <titre> <ligne…> — LE CARTOUCHE ─────────────────────────────────────
#
# ⚠ IL COMPTE DES COLONNES, PAS DES OCTETS, ET IL RETIRE LES COULEURS AVANT DE COMPTER. Un cadre
# calculé sur la chaîne colorée fait entrer les séquences ANSI dans la largeur : le bord droit part
# à droite d'autant d'invisibles. Même piège que `_prov_pad` un cran plus loin — le français
# accentué pèse deux octets par lettre.
#
# La largeur s'ADAPTE à la ligne la plus longue, plancher 57 colonnes : un cadre compté à la main
# est un cadre qui ment dès qu'on touche à son contenu, et le corpus en a déjà payé un.
_prov_box_plain() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }
_prov_box_pad() { # <texte> <largeur>
  local p n; p="$(_prov_box_plain "$1")"; n=$(( $2 - ${#p} )); (( n < 0 )) && n=0
  printf '%s%*s' "$1" "$n" ''
}
prov_box_emit() {
  local _sep=0
  if [[ "${1:-}" == "--rule" ]]; then _sep=1; shift; fi
  local _title="$1"; shift
  local _w=57 _l _p _rule
  for _l in "$_title" "$@"; do _p="$(_prov_box_plain "$_l")"; (( ${#_p} > _w )) && _w=${#_p}; done
  _rule="$(printf '%*s' "$_w" '' | sed 's/ /─/g')"
  printf '%s  ┌%s┐\n' "$_PC" "$_rule"
  printf '  │%s%s%s│\n' "$_PG" "$(_prov_box_pad "$_title" "$_w")" "$_PC"
  if (( _sep )); then printf '  ├%s┤\n' "$_rule"; fi
  for _l in "$@"; do printf '  │%s%s%s│\n' "$_PN" "$(_prov_box_pad "$_l" "$_w")" "$_PC"; done
  printf '  └%s┘%s\n' "$_rule" "$_PN"
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

# ─── apt_ensure <pkg…> — install par liste des MANQUANTS, verdict réel paquet par paquet ─────────
# ⚠ `dpkg -s` REUSSIT SUR UN PAQUET RETIRE. Un `apt-get remove` laisse le paquet en etat `rc`
# (removed, config-files) : sa base de donnees existe toujours, donc `dpkg -s` sort 0 et une sonde
# batie dessus le croit pose. Vu : apres `provision uninstall --yes`,
# l'`apply` suivant n'a REINSTALLE ni `docker-ce` ni `ttyd` — les deux etaient en `rc` — et trois
# modules sont tombes en cascade (la forge non montee, la console sans serveur, quatre unites
# mortes). Le rail ne savait pas reinstaller ce qu'il venait de desinstaller.
# `db:Status-Status` rend l'etat REEL : `installed`, `config-files`, `not-installed`.
pkg_installed() { # pkg_installed <paquet> — 0 seulement s'il est REELLEMENT installe
  [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == "installed" ]]
}

apt_ensure() {
  local missing=() already=() pkg
  for pkg in "$@"; do
    if pkg_installed "$pkg"; then already+=("$pkg"); else missing+=("$pkg"); fi
  done
  # ⚠ LA SÉPARATION SE MESURE AVANT L'INSTALL, ET C'EST LE SEUL MOMENT OÙ ELLE EST CONNAISSABLE.
  # Une seconde plus tard, `dpkg -s` répond « présent » pour les deux listes et plus rien ne
  # distingue ce que LCARS a posé de ce que l'opérateur avait déjà. C'est exactement le fait
  # qu'aucun fichier statique ne peut porter — et sans lui, une désinstallation retire des paquets
  # que quelqu'un avait avant, ce qui est pire que d'en laisser.
  #
  # ⚠ MESURER N'EST PAS ÉCRIRE : la classification se fait ici, mais l'écriture du journal descend
  # APRÈS la vérification `dpkg`. Notée avant l'`apt-get`, elle porterait sur une INTENTION — un
  # dépôt injoignable, et le journal revendique des paquets que la machine n'a jamais portés, sur
  # lesquels un `uninstall` lancera un `apt-get remove`.
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
    if pkg_installed "$pkg"; then
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

# ─── PAR QUELLE ADRESSE CETTE MACHINE EST-ELLE ATTEINTE DU DEHORS ? ─────────────────────────────
PROV_ADVERTISE=""
PROV_ADVERTISE_WHY=""
PROV_LAST_RC=0

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
lan_addr() { ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1 || true; }

# advertise_addr <bind> — POSE DEUX GLOBALES, N'IMPRIME RIEN :
#   PROV_ADVERTISE      l'adresse à ANNONCER (ROOT_URL, redirect_uri, liens du récap)
#   PROV_ADVERTISE_WHY  vide si c'est une vraie adresse de réseau ; sinon la phrase qui dit ce
#                       qu'elle vaut. Un appelant qui l'ignore annonce sans savoir ce qu'il annonce.
#
# ⚠ DEUX GLOBALES ET PAS UN `echo`, ET C'EST UN PIÈGE DE LANGAGE : un appelant écrit naturellement
# `a="$(advertise_addr …)"`, or `$( )` ouvre un SOUS-SHELL — la valeur revient par stdout, et TOUTE
# variable posée dedans meurt avec lui. La forme « j'imprime l'un, je pose l'autre » perdrait donc
# silencieusement le second.
advertise_addr() {
  local bind="${1:-0.0.0.0}"
  PROV_ADVERTISE=""; PROV_ADVERTISE_WHY=""
  case "$bind" in
    0.0.0.0|::|"*") ;;
    # Un bind précis EST l'adresse : rien à dériver, et la dérivation se tromperait.
    *) PROV_ADVERTISE="$bind"; return 0 ;;
  esac
  # ⚠ `PROV_SUBSTRATE` D'ABORD, LA SONDE SEULEMENT EN REPLI. Le runner a DÉJÀ tranché le substrat
  # (`provision --substrate`) et l'exporte. Re-sonder ici en ferait une seconde dérivation du même
  # fait, et `--substrate linux` joué sur une machine WSL prendrait quand même la branche NAT : le
  # drapeau ne porterait pas jusqu'ici.
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
  # ⚠ `return 0` EXPLICITE : sans lui, la fonction rend le code du dernier `if` — donc 1 quand la
  # dérivation a RÉUSSI, le test `-z` étant faux. Les appelants tournent sous `set -e`, où un succès
  # avorte alors le script.
  return 0
}

# ─── LES PORTS — FIXES PAR DÉFAUT, SURCHARGEABLES, ET SONDÉS AVANT D'ÊTRE PRIS ──────────────────
# Le risque n'est pas symétrique : `3000` est le défaut de la moitié de l'écosystème de dev — React,
# Rails, Vite, Grafana — quand `20999` est choisi pour être improbable.
port_taken() { # port_taken <port> -> 0 si quelque chose ÉCOUTE sur la loopback
  timeout 2 bash -c "</dev/tcp/127.0.0.1/$1" 2>/dev/null
}

port_holder() { # port_holder <port> -> description, ou VIDE
  command -v ss >/dev/null 2>&1 || return 0
  ss -ltnp 2>/dev/null \
    | awk -v p=":$1\$" '$4 ~ p { for (i=1;i<=NF;i++) if ($i ~ /users:/) { print $i; exit } }' \
    | sed -e 's/users:((//' -e 's/))$//' -e 's/,fd=[0-9]*//' | head -1
}

# ─── as_human <cmd…> — exécute comme PROV_HUMAN avec le HOME de PROV_HUMAN ───────────────────────
# ⚠ Depuis root : `runuser` + env EXPLICITE — sans `-l`, `runuser` garde le HOME de root. Déjà cet
# utilisateur : exécution directe. Autre user non-root : impossible proprement, l'échec est dit.
as_human() {
  local home
  home="$(getent passwd "$PROV_HUMAN" | cut -d: -f6 || true)"
  [[ -n "$home" ]] || { p_fail "as_human: user inconnu: $PROV_HUMAN"; return 1; }
  if [[ "$(id -un)" == "$PROV_HUMAN" ]]; then
    "$@"
  elif [[ "$EUID" -eq 0 ]]; then
    # ⚠ LE `cd` FAIT PARTIE DE L'IDENTITE. Poser HOME/USER/LOGNAME en laissant le REPERTOIRE COURANT
    # de root donne un demi-humain : tout ce qui résout un chemin RELATIF échoue depuis un `/root` en
    # 0700, et le message n'accuse jamais le cwd — l'ERTS rend vingt lignes de
    # `File operation error: eacces. Target: ./Elixir.Logger.beam`, dont aucune ne nomme le fait.
    #
    # `cd` dans un SOUS-SHELL : le cwd du module appelant n'est pas touché.
    ( cd "$home" && runuser -u "$PROV_HUMAN" -- env HOME="$home" USER="$PROV_HUMAN" LOGNAME="$PROV_HUMAN" "$@" )
  else
    p_fail "as_human: je suis $(id -un), pas root ni $PROV_HUMAN — relance en root"
    return 1
  fi
}

# home de PROV_HUMAN, vide si inconnu — l'appelant DOIT tester. ⚠ `|| true` LOAD-BEARING (B5) :
# sous `set -euo pipefail`, un user inconnu tuerait l'assignation `home="$(human_home)"` AVANT la
# garde `p_fail` de l'appelant, et le contrat « vide si inconnu » ne tiendrait pas.
human_home() { getent passwd "$PROV_HUMAN" | cut -d: -f6 || true; }

# ─── is_fleet_human [login] — celui-ci peut-il faire tourner une fleet ? ───────────────────────────
# DEUX CONDITIONS, PARCE QU'IL Y A DEUX REGLES, et c'est le meme couple que le GUARD B de
# `bin/fleet` (le BEAM herite de l'uid de son lanceur, ses pods avec) :
#   1. `UID_MIN <= uid <= UID_MAX` — la frontiere systeme/humain. Elle n'est pas a inventer :
#      `/etc/login.defs` la declare et `useradd` la lit. Les comptes systeme sont en dessous,
#      `nobody` (65534, sur toute machine) au-dessus.
#   2. `uid != SYSADMIN_UID` — la reservation du siege, que `login.defs` ne peut PAS exprimer :
#      le sysadmin est souvent le premier uid humain, donc le systeme le classe utilisateur regulier.
#
# LA REGLE EST CELLE DE `runtime/services/lib/human-protocol.sh` (`uid_bounds`, `is_fleet_human`),
# la seule ecriture cote produit. Elle est RE-ECRITE ici plutot qu'appelee : l'installeur ne source
# pas de code du produit (PLAYBOOK, grille de nature : un partage est interdit dans les deux sens),
# le protocole exige un sujet de module et pose un vocabulaire fait pour lui, et `22-fleet-human`
# joue AVANT `62-runtime-helpers` — la decision d'installer ne peut pas dependre d'un fichier que
# l'install pose. Le nombre, lui, n'est pas recopie — il vient de login.defs. Ce qui tient les deux
# corps d'accord est un temoin (`provision-lib.bats`, « meme matrice, memes verdicts, meme phrase »),
# pas ce commentaire.
#
# ⚠ AUCUN REPLI SUR 1000 NI 60000, et c'est delibere (⚖ user 2026-09-05, solution A) — la politique
# que le BEAM applique a son boot (runtime.exs, R-no-uid-min) et `console-humans.sh` a sa liste.
# Un login.defs illisible n'est pas « la frontiere est a 1000 », c'est « la frontiere n'est pas
# etablie » : `is_fleet_human` rend non pour tout le monde, `fleet_humans` ne rend personne, et le
# remede — le fichier — est dit UNE FOIS par processus (un `$( )` herite de la trace ; dit D'ABORD
# dans un `$( )`, elle ne remonte pas, et le processus le redira une fois — jamais plus).
#
# ⚠ ARITHMETIQUE, jamais des chaines : en comparaison lexicographique `"999" < "1000"` est FAUX, et
# un compte systeme a uid 999 passerait la garde. `|| true` LOAD-BEARING : sous `set -euo pipefail`,
# un login.defs absent tuerait le module AVANT la garde, et une garde qui s'evanouit sur une
# lecture ratee est pire que pas de garde.
PROV_UID_MIN="" PROV_UID_MAX="" PROV_UID_BOUNDS_WHY=""
_PROV_UID_BOUNDS_SAID=""
prov_uid_bounds() { # pose PROV_UID_MIN et PROV_UID_MAX depuis login.defs — 0 si les deux se lisent ; 1 sinon, remede dans PROV_UID_BOUNDS_WHY, dit une fois
  local defs="${PASSWD_DEFS:-/etc/login.defs}" manque=""
  PROV_UID_MIN="$(awk '$1 == "UID_MIN" {print $2; exit}' "$defs" 2>/dev/null || true)"
  PROV_UID_MAX="$(awk '$1 == "UID_MAX" {print $2; exit}' "$defs" 2>/dev/null || true)"
  [[ "$PROV_UID_MIN" =~ ^[0-9]+$ ]] || manque=UID_MIN
  [[ -n "$manque" || "$PROV_UID_MAX" =~ ^[0-9]+$ ]] || manque=UID_MAX
  if [[ -z "$manque" ]]; then PROV_UID_BOUNDS_WHY=""; return 0; fi
  PROV_UID_MIN="" PROV_UID_MAX=""
  PROV_UID_BOUNDS_WHY="la frontiere systeme/humain n'est pas etablie ($manque illisible dans $defs) — la borne est declaree par le systeme, pas par ce processus : repare $defs"
  if [[ -z "$_PROV_UID_BOUNDS_SAID" ]]; then
    _PROV_UID_BOUNDS_SAID=1
    p_warn "$PROV_UID_BOUNDS_WHY"
  fi
  return 1
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

# ⚠ SIÈGE INCONNU ⇒ RÉPONSE NON, POUR TOUT LE MONDE. Un `:-1000` répondrait « oui » à quiconque n'est
# pas 1000 — donc au siège lui-même dès qu'il est ailleurs, c'est-à-dire exactement le compte que
# cette fonction existe pour écarter. Se fermer est la seule direction sûre quand la borne manque.
is_fleet_human() { # [login] (défaut: PROV_HUMAN) — 0 si oui
  local login="${1:-$PROV_HUMAN}" uid seat
  uid="$(id -u -- "$login" 2>/dev/null || true)"
  [[ "$uid" =~ ^[0-9]+$ ]] || return 1
  seat="$(prov_seat_uid)" || return 1
  prov_uid_bounds || return 1
  (( uid >= PROV_UID_MIN && uid <= PROV_UID_MAX )) && (( uid != seat ))
}

# ─── fleet_humans — CEUX QUI EXISTENT DÉJÀ SUR CETTE MACHINE ────────────────────────────────────
#
# ⚠ ÉNUMÉRER N'EST PAS TESTER UN NOM, ET LA DIFFÉRENCE EST UNE BORNE. `is_fleet_human` répond « ce
# login-là peut-il lancer une fleet » : on le lui a nommé, donc la borne HAUTE ne sert à rien.
# Balayer `passwd` pose l'autre question, et `nobody` — uid 65534, présent sur toute machine —
# répond OUI à la règle basse seule.
fleet_humans() {
  local seat
  seat="$(prov_seat_uid)" || {
    echo "fleet_humans: siège non établi (ni ${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}, ni LCARS_SYSADMIN_UID) — population non mesurable" >&2
    return 1
  }
  # Bornes illisibles : PERSONNE — une population devinee compterait `nobody` ou des comptes
  # systeme, et `64-services` l'annoncerait comme des humains de fleet.
  prov_uid_bounds || return 1
  awk -F: -v m="$PROV_UID_MIN" -v M="$PROV_UID_MAX" -v s="$seat" \
      '$3+0 >= m && $3+0 <= M && $3+0 != s {print $1}' "${PASSWD_FILE:-/etc/passwd}"
}

repo_root() { readlink -f "$(dirname "$PROVISION_LIB")/../.."; }
# L'ARBRE DU PRODUIT — `runtime/` dans un checkout, la racine `/opt/lcars` une fois pose. Le
# ponçage d'alice a renomme `fleet/` en `runtime/`, et `/opt/lcars/runtime` est deja le PREFIX de
# la release : l'arbre embarque (services, etc, bin) vit donc A PLAT sous `/opt/lcars/`, comme le
# convergeur du produit le suppose (`/opt/lcars/services/human.d`). Le discriminant est l'arbre A PLAT
# lui-meme : une racine posee porte `services/` ; un checkout ne porte `services/` nulle part a sa
# racine. Il se lit par un `stat` sur un ENFANT DIRECT de la racine — jamais en descendant dans
# `runtime/` : le PREFIX de la release y est `0750 root:fleet`, et un lecteur hors du groupe
# (un daemon) verrait « pas de rel/ » et prendrait la release pour l'arbre source (relecture
# hostile du 2026-09-04 : `FAIL 60-deploy: manifest introuvable: /opt/lcars/runtime/etc/…`).
product_tree() { local r; r="$(repo_root)"; if [[ -d "$r/runtime" && ! -e "$r/services" ]]; then printf '%s' "$r/runtime"; else printf '%s' "$r"; fi; }

# ─── LA RÉVISION DE LA SOURCE, ET POURQUOI ELLE DOIT VOYAGER AVEC LA COPIE ───────────────────────
PROV_SOURCE_STAMP="${LCARS_SOURCE_STAMP:-.source-revision}"

# ─── DEUX FAITS, DEUX FICHIERS — ET ILS ONT PORTÉ LE MÊME NOM ───────────────────────────────────
#
# ⚠ UN SEUL FICHIER A PORTÉ DEUX FAITS SANS RAPPORT, ET LE SECOND SE LISAIT COMME LE PREMIER.
#   `$PROV_SOURCE_STAMP`   « ce répertoire est un PAQUET » — écrit par `pack.sh` à la racine du
#                          paquet, lu par `prov_delivery` pour décider BINAIRE ou SOURCE, c'est-à-
#                          dire pour décider si la machine porte un toolchain.
#   `$PROV_HELPERS_STAMP`  « les auxiliaires posés ici sortent de CETTE révision » — écrit par
#                          `62-runtime-helpers` sous `$PROV_ROOT`, lu par lui seul.
#
# LA COLLISION : `62-runtime-helpers` écrivait le SECOND sous le nom du PREMIER, en `/opt/lcars/
# .source-revision`. Or `repo_root()` remonte trois crans depuis `<racine>/deploy/lib` — donc
# rejouer `/opt/lcars/deploy/provision` — la copie posée, sur un poste sans checkout ; le
# convergeur, lui, ne rejoue plus `provision`, il source `services/human.d/*.sh` — rend
# `root == /opt/lcars` : le tampon des auxiliaires
# devenait le discriminant de livraison. Un poste installé depuis un clone se déclarait BINAIRE au
# rejeu, `15-toolchain` rendait « toolchain non requise » sans jamais évaluer son plancher OTP, et
# `16-node` ne mesurait plus rien. Sur une machine qui COMPILE, le doctor rendait vert sur des
# questions qu'il avait cessé de poser.
#
# ⚠ ET RENOMMER NE SUFFIT PAS : il faut PROPAGER. Sans le second geste, le rejeu depuis
# `/opt/lcars` d'une machine installée par PAQUET ne trouverait plus rien et se déclarerait SOURCE
# — le défaut symétrique, qui exigerait un toolchain sur une boîte qui n'en a pas. `62-runtime-
# helpers` pose donc le discriminant sous `$PROV_ROOT` quand la livraison courante est binaire, et
# le RETIRE quand elle est source : la copie porte la vraie forme, dans les deux sens.
PROV_HELPERS_STAMP="${LCARS_HELPERS_STAMP:-.helpers-revision}"

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

# ─── LES PARAMETRES QUE LA MACHINE SE RAPPELLE ──────────────────────────────────────────────────
#
# ⚠ TROIS, ET LA LISTE EST FERMEE. Ce sont les seules options de `provision apply` qui decrivent un
# ETAT-CIBLE de la machine plutot qu'une intention du geste en cours. `--verbose` ou `--only` ne
# sont pas de cette nature : les memoriser ferait qu'un doctor futur n'examinerait plus qu'un
# module, parce que quelqu'un a un jour lance un apply cible.
#
# Elargir cette liste, c'est decider qu'un drapeau devient un fait persistant de la machine. Ca se
# fait ligne par ligne, jamais par une regex sur les noms.
PROV_REMEMBERED=(PROV_DECK_PORT PROV_FORGE_HOST_PORT PROV_FORGE_BASE)

prov_params_line() { # la ligne `params` du journal : `NOM=valeur …`, seulement ce qui differe
  local n out=""
  for n in "${PROV_REMEMBERED[@]}"; do
    [[ -n "${!n:-}" ]] && out="$out ${n}=${!n}"
  done
  printf '%s\n' "${out# }"
}

# ─── DRIFT OU WARN : LE CRITERE EST « SAIT-ON ? », PAS « PEUT-ON CORRIGER ? » ───────────────────
#
#   p_drift  L'ETAT-CIBLE N'EST PAS TENU, et c'est un fait ETABLI. Que `apply` sache le corriger ou
#            non ne change rien : une forge fournie qui ne repond pas est un drift, meme si ce rail
#            ne la monte pas et ne pourra jamais la relever.
#   p_warn   ON NE SAIT PAS, ou la question est HORS DU PERIMETRE du rail. Un objet qu'on ne peut pas
#            lire d'ici ; une adhesion d'org qu'une personne pose elle-meme sur la forge.
#
# ⚠ CE CRITERE A ETE POSE APRES S'ETRE TROMPE DANS LES DEUX SENS. D'abord en laissant
# `p_drift` sur des sondes qui DISAIENT ne pas savoir — « non mesurable », « NON SONDABLE »,
# « illisible » — ce qui produisait cinq drifts sans sudo qui disparaissaient avec, sur une machine
# identique. Puis, en corrigeant, en passant a `p_warn` une forge muette et un manifeste illisible :
# deux etats parfaitement ETABLIS, dont le verdict ne depend pas de qui lance le doctor. Trois
# temoins existants ont rougi et ils avaient raison.
#
# LE TEST QUI TRANCHE : « ce verdict changerait-il si quelqu'un d'autre lancait la meme commande ? »
# Si oui, c'est qu'on mesure le LECTEUR et pas la machine — donc un warn, et il doit dire pourquoi.
#
# ─── TROIS ETATS, JAMAIS DEUX ───────────────────────────────────────────────────────────────────
#
#   present       il est la, et on peut le lire
#   unreadable    il est la, et CE compte ne peut pas l'ouvrir — un fait sur NOUS, pas sur lui
#   absent        il n'est pas la, et on est en position de l'affirmer
#   unmeasurable  on ne peut meme pas conclure : un ancetre n'est pas traversable d'ici
#
# ⚠ POURQUOI QUATRE MOTS POUR CE QUI S'ECRIVAIT `[[ -r "$f" ]]`. Vu : `66-deck-oidc` annoncait « /etc/lcars/deck-oidc.json absent » d'un fichier de 336 octets
# parfaitement present — `0640 root:lcars-system`, que l'appelant ne peut pas OUVRIR mais peut
# parfaitement CONSTATER. Le test de lisibilite tenait lieu de test d'existence, et le doctor
# declarait non conforme une machine qui l'etait.
#
# UN VERDICT QUI NE PEUT PAS ETRE VRAI EST PIRE QU'UN VERDICT ABSENT : il envoie l'operateur
# converger un objet deja pose, et lui apprend a ne plus croire le rapport.
#
# ⚠ ET `absent` SE MERITE. Un `-e` faux ne prouve l'absence que si l'on peut traverser le parent :
# sous un repertoire ferme, tout parait absent. La boucle remonte donc jusqu'au premier ancetre qui
# existe et demande s'il est traversable — sinon la reponse honnete est « je ne sais pas ».
prov_file_state() { # prov_file_state <chemin> -> present | unreadable | absent | unmeasurable
  local p="$1" d
  if [[ -e "$p" ]]; then
    [[ -r "$p" ]] && { printf 'present\n'; return 0; }
    printf 'unreadable\n'; return 0
  fi
  d="$(dirname "$p")"
  while [[ "$d" != "/" && ! -e "$d" ]]; do d="$(dirname "$d")"; done
  if [[ -x "$d" ]]; then printf 'absent\n'; else printf 'unmeasurable\n'; fi
}

# La phrase qui accompagne un etat non concluant. Elle nomme le compte et le chemin : « non
# mesurable » sans le pourquoi est un troisieme verdict aussi opaque que les deux qu'il remplace.
prov_state_why() { # prov_state_why <etat> <chemin>
  case "$1" in
    unreadable)   printf 'présent, mais illisible pour %s — rien n'"'"'est conclu sur son contenu (relance sous sudo pour le mesurer)\n' "$(id -un 2>/dev/null || echo "ce compte")" ;;
    unmeasurable) printf 'NON MESURABLE ici : un répertoire du chemin (%s) n'"'"'est pas traversable par %s — ni présent ni absent, on ne sait pas\n' "$(dirname "$2")" "$(id -un 2>/dev/null || echo "ce compte")" ;;
  esac
}

# ─── LA FORME DE LA LIVRAISON — `binary` ou `source` ────────────────────────────────────────────
#
# DEUX FORMES, ET CHACUNE EST ENTIERE :
#   binary  la release Elixir ET la doc sont deja baties. Rien n'est a batir sur la cible, donc
#           AUCUN outil de build n'a de raison d'y etre pose.
#   source  on bâtit les deux. Les compilateurs vivent le temps du build.
#
# ⚠ ON N'EN FAIT JAMAIS LA MOITIE. Poser le toolchain Elixir « au cas ou » sur une livraison binaire,
# ou n'y poser que node parce que la doc se bâtit, produirait une machine dont personne ne sait ce
# qu'elle est : ni une boite de prod (elle porte des compilateurs), ni un poste de dev (il lui en
# manque). La question se pose UNE fois, ici, et les modules la lisent.
#
# ⚠ LE DISCRIMINANT EST EXPLICITE, PAS DEDUIT — meme raison que dans `etc/deploy-release.sh`, et
# c'est la meme convention : `pack.sh` ECRIT `$PROV_SOURCE_STAMP` a la racine du paquet. Sa presence
# DIT « paquet ». Le deduire de l'absence d'un `.git` se tromperait sur un paquet detare dans un
# depot, et sur un clone dont le `.git` a ete retire pour l'expedier.
prov_delivery() { # prov_delivery [racine] -> `binary` | `source`
  local root="${1:-$(repo_root)}"
  if [[ -f "$root/$PROV_SOURCE_STAMP" ]]; then printf 'binary\n'; else printf 'source\n'; fi
}

# Le raccourci que les modules lisent : 0 quand la cible n'a RIEN a batir.
prov_delivery_is_binary() { [[ "$(prov_delivery "$@")" == "binary" ]]; }

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
# `PROV_ROLES` SURVIT COMME PLANCHER, et pas par prudence : les comptes `system_*` vivent dans le
# catalogue SYSTEME, qui n'est pas installe — il est le substrat. Et une boite dont le release n'est
# pas encore pose doit quand meme minter de quoi demarrer.
# ─── LE SIEGE : le #1 de la forge et le compte unix sont le MEME acteur ─────────────────────────
#
# La regle : celui des deux qui existe nomme l'autre, et le lien est enregistre — ligne `forge_id=1`
# de `forge-uid.map`, la meme table que les humains de fleet. Une seconde table pour tenir une ligne
# de la premiere ferait deux verites d'un meme fait.
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
prov_seat_record() { # prov_seat_record <login> <uid>
  local login="${1:?prov_seat_record: login requis}" uid="${2:?prov_seat_record: uid requis}"
  [[ -n "$(prov_seat_from_map)" ]] && return 0
  mkdir -p "$(dirname "$PROV_UID_MAP_FILE")" 2>/dev/null || true
  printf '1\t%s\t%s\n' "$uid" "$login" >> "$PROV_UID_MAP_FILE" 2>/dev/null || return 1
  chmod 0640 "$PROV_UID_MAP_FILE" 2>/dev/null || true
}

# env_field <fichier> <CLE> — la valeur de `CLE=…` dans un fichier d'environnement : la DERNIERE si
# la cle est repetee (ce qu'un `source` retiendrait), vide si le fichier ou la cle manque. Jamais un
# echec : un fichier absent est une reponse, pas une mort de `sed` sous pipefail dans une affectation.
env_field() { sed -n "s/^${2}=//p" "$1" 2>/dev/null | tail -n1 || true; }

# set_diff <lignes-a> <lignes-b> — les lignes de b ABSENTES de a, une par ligne, sans ligne vide.
# Trie et dedoublonne lui-meme : `comm` exige des entrees triees et, sur GNU, ne le verifie pas —
# deux listes dans le mauvais ordre rendent un resultat faux sans un mot.
set_diff() {
  comm -13 <(printf '%s\n' "$1" | sed '/^$/d' | sort -u) <(printf '%s\n' "$2" | sed '/^$/d' | sort -u)
}

# arch_tag <raw|debian|node> — l'architecture au vocabulaire de la cible. `raw` rend ce que dpkg dit
# (vide s'il est absent) ; `debian` et `node` rendent le tag d'une release, ou VIDE si l'arch n'est
# pas epinglee — a l'appelant de refuser en la nommant. Jamais `uname -m` : il repond `x86_64` la
# ou les releases disent `amd64` ou `x64`, et il repond pour la machine de build en cross-compilation.
arch_tag() {
  local deb; deb="$(dpkg --print-architecture 2>/dev/null || true)"
  case "$1:$deb" in
    raw:*)                       echo "$deb" ;;
    debian:amd64|debian:arm64)   echo "$deb" ;;
    node:amd64)                  echo x64 ;;
    node:arm64)                  echo arm64 ;;
    *)                           echo "" ;;
  esac
}

# forge_curl <fichier-jeton> <args curl…> — le jeton part par `-K -` (config sur stdin), jamais par
# argv, ou il serait lisible dans /proc de tout l'hote pendant l'appel. Un fichier absent, vide ou
# illisible fait une requete ANONYME : une config vide est valide pour curl. Rend le rc de curl.
forge_curl() {
  local tokfile="$1" tok=""; shift
  tok="$(read_token "$tokfile")"
  { [[ -n "$tok" ]] && printf 'header = "Authorization: token %s"\n' "$tok" || true; } \
    | curl -K - "$@"
}

read_token() { # read_token <fichier> — le jeton sans blancs, ou rien : jamais un message, jamais un echec
  [[ -n "${1:-}" && -r "$1" ]] && tr -d '[:space:]' < "$1"
  return 0
}

# Le #1 de la forge, resolu par son ID et jamais par son nom : Gitea conserve l'`id` au renommage,
# le login est une etiquette. Vide quand la forge est muette ou le jeton illisible — un appelant qui
# lit du vide ne doit pas conclure « personne », seulement « pas su ».
prov_forge_seat_login() {
  [[ -s "$PROV_MASTER_TOKEN_FILE" && -n "${PROV_FORGE_URL:-}" ]] || return 0
  forge_curl "$PROV_MASTER_TOKEN_FILE" -sS -m 15 "${PROV_FORGE_URL%/}/api/v1/admin/users?limit=50" 2>/dev/null \
    | jq -r 'map(select(.id == 1)) | .[0].login // empty' 2>/dev/null || true
}

# prov_seat_binding [candidat_unix] — POSE TROIS GLOBALES, N'IMPRIME RIEN :
#
#   PROV_SEAT_BINDING   le verdict d'ACCORD, un mot
#   PROV_SEAT_LOGIN     le login du siege, vide seulement sur `unknown`
#   PROV_SEAT_SOURCE    d'ou il vient — `table` | `forge` | `candidat`, vide sur `unknown`
# Les cinq verdicts :
#
#   agree     le cote durable et le candidat unix nomment le meme acteur
#   diverge   ils nomment deux acteurs
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

# ─── LA RELEASE : CELLE QUE LA PASSE APPORTE, PUIS CELLE QUE LA MACHINE PORTE ───────────────────
#
# ⚠ UN MODULE LISAIT LA RELEASE POSEE DOUZE RANGS AVANT SON POSEUR. `48-forge-host` derivait le
# roster du catalogue par `--release "$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"` — chemin ecrit
# par `60-deploy` SEUL, et `provision:327` interdit a 48 de declarer `AFTER: 60-deploy` (un `AFTER`
# doit PRECEDER dans l'ordre du rang). Sur la premiere install d'un paquet, `enroll-catalogue.sh`
# mourait donc sur « release non executable », le module rendait « roster non derivable de l'arbre »
# — un message qui accuse l'ARBRE alors que le paquet est complet — et `workstation` sortait 1. Le
# second apply passait : defaut intermittent, donc invisible a toute campagne qui rejoue.
#
# ⚠ LE PAQUET D'ABORD, ET C'EST UN ORDRE, PAS UNE PREFERENCE. `pack.sh` embarque la release en
# `runtime/_build/prod/rel/lcars_fleet` : elle est LA avant d'etre posee, et elle EST celle que
# `60-deploy` posera. La release deja posee peut, elle, sortir d'un paquet PLUS ANCIEN — rejouer un
# paquet neuf sur une machine installee deriverait alors le roster d'une release perimee.
#
# Rend 1 sans rien ecrire quand aucun candidat n'est executable : c'est a l'appelant de dire ce que
# son geste en fait, et les deux appelants n'en font pas la meme chose.
# ─── LA COPIE POSÉE N'EST PAS UN ARBRE DE BUILD ─────────────────────────────────────────────────
#
# ⚠ TROIS MODULES ONT TENTÉ D'Y BÂTIR, ET LES TROIS ONT ÉCHOUÉ AU MÊME ENDROIT. Vu sur un apply rejoué depuis
# `/opt/lcars/deploy/provision` — le rejeu depuis la copie posée, sur un poste sans checkout :
#
#   FAIL 44-media:      npm run build (/opt/lcars/assets/github.io)
#   FAIL 48-forge-host: mix deps.get (/opt/lcars/services)
#   FAIL 60-deploy:     source runtime introuvable: /opt/lcars/services
#
# Et le premier ne faisait pas qu'échouer : `npm ci` a INSTALLÉ 176 Mo d'arbre npm SOUS /opt/lcars
# avant de rater son build. La copie n'est pas seulement incapable de bâtir — la laisser essayer la
# pollue.
#
# CE QUI MANQUAIT EST UN DISCRIMINANT, PAS UNE GARDE DE PLUS. Les trois modules savaient déjà lire
# la LIVRAISON (`prov_delivery_is_binary`) ; aucun ne savait répondre à « suis-je dans l'arbre de
# travail, ou dans la copie que j'ai moi-même posée ? ». Ce sont deux questions distinctes : un
# poste en livraison SOURCE rejoué depuis la copie n'a ni `mix.exs` ni `node_modules`, et il n'en a
# pas besoin — la release et le `dist/` sont déjà posés.
#
# `62-runtime-helpers` embarque `{deploy,etc,services,bin}` a plat et `{assets,catalogues}` pour que
# le rail puisse se REJOUER, pas pour qu'il puisse se RECONSTRUIRE. La distinction est le contrat
# de cette copie.
prov_dans_la_copie() { # prov_dans_la_copie -> 0 si ce rail tourne depuis la copie posée
  [[ "$(repo_root)" == "${PROV_ROOT}" ]]
}


prov_roles() {
  local out="$PROV_ROLES" root
  local bin="${PROV_RELEASE_BIN:-$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet}"
  # ⚠ LES PORTES OUTIL VIVENT DANS L'ENTRYPOINT, ET IL N'EST PAS AU MEME ENDROIT SUR LES DEUX RAILS :
  # `/opt/lcars/entrypoint.sh` dans l'image, `<racine>/deploy/docker/entrypoint.sh` sur un poste
  # (62-runtime-helpers l'exclut de ses auxiliaires et embarque `deploy/` entier). Un seul chemin
  # ici rendait le roster des catalogues installes VIDE sur tout poste : `63-forge-tokens` ne mintait que
  # le plancher, et les roles d'un catalogue installe n'avaient jamais de jeton. Meme resolution
  # que `forge-gestures.sh` (`_entrypoint_path`), et `-r` plutot que `-x` pour la meme raison : la
  # copie posee est 0644.
  # La porte outil est « lcars tool roles-tfvars », dans la CLI du PRODUIT —
  # elle vivait dans l'entrypoint de l'image, que ce fichier devinait a deux adresses. La CLI est
  # posee par 60 (`$PROV_LINK_DIR/lcars`) ; avant, ou depuis une copie, celle de l'arbre.
  local entry="${PROV_LCARS_CLI:-}" c
  if [[ -z "$entry" ]]; then
    for c in "$PROV_LINK_DIR/lcars" "$(product_tree)/bin/lcars"; do
      [[ -r "$c" ]] && { entry="$c"; break; }
    done
  fi

  # ⚠ `roles-tfvars` ET NON `roles` : les deux portes ne rendent pas la meme chose. `roles` rend des
  # noms de ROLE (`dev`, `writer`) quand `PROV_ROLES` est une liste de COMPTES (`web-demo_dev`) —
  # brancher la derivation sur la premiere fait creer des comptes forge portant le nom nu d'un role,
  # a cote des vrais.
  #
  # `.roles` porte les comptes du catalogue, `.system_roles` ceux du substrat partage. Le canon ne
  # connait pas cette coupure — il connait des comptes — donc on recolle ici.
  if [[ -n "$entry" && -r "$entry" && -x "$bin" && -d "$PROV_CATALOGUES_DIR" ]] && command -v jq >/dev/null; then
    for root in "$PROV_CATALOGUES_DIR"/*/; do
      [[ -f "${root}catalogue.yaml" ]] || continue
      # `|| true` : un catalogue dont la porte refuse est un catalogue que le boot refusera aussi,
      # et ce n'est pas au mint de trancher. On n'ajoute simplement rien pour lui.
      out="$out $(LCARS_FLEET_BIN="$bin" bash "$entry" tool roles-tfvars "${root%/}" 2>/dev/null \
                  | jq -r '(.roles[]?, .system_roles[]?)' 2>/dev/null | tr '\n' ' ' || true)"
    done
  fi

  # `$out` est une LISTE separee par des espaces, a eclater — c'est le but de cette ligne.
  # shellcheck disable=SC2086 # eclatement voulu : une entree par mot
  printf '%s\n' $out | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
