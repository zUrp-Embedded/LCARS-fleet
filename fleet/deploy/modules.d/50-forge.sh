#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/50-forge.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — forge : SONDE de la structure (territoire OpenTofu) + jambe tokens (A4)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
# La forge n'est PAS installée ici (sidecar compose en Docker, app TrueNAS, service externe —
# créée par LE SYSTÈME, jamais par LCARS), et sa STRUCTURE n'est plus créée ici non plus :
# comptes/org/teams/hardening sont le territoire EXCLUSIF d'OpenTofu (forge.tf, arbitrage WS1 :
# « TF fait toute la STRUCTURE, bash SEULEMENT les tokens »). Ce module :
#   1. SONDE la structure (comptes de rôle + compte système, endpoint public) — absente, il NOMME
#      la commande qui la pose : « fleet/deploy/box forge-apply ».
#      ⚠ LE MOTIF ÉCRIT ICI ÉTAIT « même famille de gestes d'identité que claude /login, sondés et
#      instruits, jamais faits ». C'ÉTAIT UN COMMENTAIRE, PAS UNE DOCTRINE — écrit ici le
#      2026-07-05 avec le code qu'il décrivait, sans arbitrage derrière. Et il est devenu faux : le
#      geste EST exécutable depuis le 2026-08-16 (tofu vit dans l'image, l'apply est rejouable).
#      Ce module ne le joue pas ENCORE, et ce « pas encore » n'a rien d'une propriété : où l'apply
#      se déclenche dans le boot est une question ouverte du chantier « deploy avec tofu dedans ».
#      Ce qui reste vrai sans discussion : l'apply a besoin d'une AUTORITÉ que l'opérateur fournit
#      (`fleet/deploy/box config`), et ce module ne l'invente pas ;
#   2. converge les TOKENS — délégués à fleet/etc/provision-role-tokens.sh (A4, une
#      seule mécanique de mint). Gitea n'accepte QUE la basic-auth pour minter (anti-escalade,
#      vérifié 2026-07-05) → passwords-file requis. S'il est absent mais que le SEED du
#      bootstrap est posé (PROV_FORGE_SEED_FILE = le TF_VAR_seed_password de tofu), le module
#      le DÉRIVE : {compte: seed} pour tous. Après le bootstrap unique, chaque apply converge
#      donc les tokens dans le MÊME cycle — plus aucun geste.
#      ⚠ LE SEED N'EST PLUS LE MOT DE PASSE DE PERSONNE, et cette ligne a dit le contraire :
#      « les bots le GARDENT ». Le mint POSE un mot de passe neuf par le jeton master
#      (`force_password_for`), s'en sert et l'oublie ; l'humain intégré reçoit le sien de
#      `48-forge-host`. Le seed n'est plus qu'une valeur de CRÉATION — celle que tofu exige à la
#      naissance d'un compte — et un REPLI si le PATCH du mint échoue. Il ne se supprime pas pour
#      autant : le provider ne pose le password qu'à la création, donc un seed régénéré rendrait
#      « changed » tous les plans à venir sans rien changer côté forge (piège documenté dans
#      `deps/instance/accounts.tf`).
#   3. SONDE (et ne converge plus) la VISIBILITÉ des adhésions d'org des comptes machine de l'org
#      SYSTÈME. Une adhésion créée par API est PRIVÉE par défaut, donc invisible aux non-membres :
#      un humain qui ouvre l'org ne voit pas quels workers y travaillent. C'est de l'UX, pas de la
#      sûreté (⚖ user 2026-08-17 — rien dans le dépôt ne LIT cette visibilité). Le geste qui la pose
#      vit dans `forge-gestures.sh`, joué par `forge-apply` et par `catalogue install`, chacun sur
#      l'org qu'il vient de créer. Le compte operateur est sondé + instruit,
#      jamais convergé : son mot de passe n'est dans aucun fichier de la recette (le passwords-file
#      ne porte que les comptes machine), donc il n'y a rien avec quoi converger. Le motif ecrit ici
#      etait « son password lui appartient » — faux : personne ne s'appelle `lcars`.
#
# Données : PROV_FORGE_URL (vide = instruct-only) · PROV_FORGE_SEED_FILE (défaut
# <tokens-dir>/forge-seed.pass, 0600 root, posé par « fleet/deploy/box config ») · PROV_MASTER_TOKEN_FILE
# (défaut <tokens-dir>/forge-master.token, 0600 root, même geste — l'autorité de création, elle
# RESTE) · PROV_PASSWORDS_FILE (défaut <tokens-dir>/forge-role-passwords.json — l'A4 durable,
# rejouable sur forge nuke).

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

: "${PROV_PASSWORDS_FILE:=$PROV_TOKENS_DIR/forge-role-passwords.json}"
A4_SCRIPT="$(repo_root)/fleet/etc/provision-role-tokens.sh"
# LE ROSTER EST DERIVE, PAS DECLARE — `prov_roles` (provision-lib) lit ce que les catalogues
# INSTALLES declarent, plus le plancher systeme. Resolu UNE fois ici et non a chaque usage : entre
# deux appels d'un meme cycle la liste ne doit pas bouger, sinon la sonde et le mint travaillent sur
# deux ensembles differents et le rapport parle d'un etat que personne n'a converge.
#
# ⚠ `45-catalogues` TOURNE AVANT CE MODULE, et c'est ce qui rend la derivation vraie du premier
# coup : le materiel est deja la quand cette ligne s'evalue. Inverser l'ordre ferait minter le
# roster du cycle PRECEDENT — un catalogue installe passerait son premier boot sans jetons.
ROLES="$(prov_roles)"
ACCOUNTS="$ROLES $PROV_SYSTEM_ACCOUNT"

# La forme se teste ICI, pas chez l'appelant : `curl` accepte un « host:port » nu et lui prefixe
# `http://`, alors que le runtime concatene `base_url` verbatim (Fleet.Forge.Client.Transport) et
# refuse. Une sonde plus tolerante que son consommateur rend un vert faux.
forge_reachable() {   # 0 joignable · 1 forme invalide · 2 injoignable
  [[ "$PROV_FORGE_URL" == http://* || "$PROV_FORGE_URL" == https://* ]] || return 1
  curl -fsS -m 10 -o /dev/null "$PROV_FORGE_URL/api/v1/version" 2>/dev/null || return 2
}

# L'INSCRIPTION LIBRE EST UNE PRÉCONDITION DU MODÈLE D'ENROLLMENT, ET RIEN NE LA VÉRIFIAIT.
# Une personne s'inscrit seule ; l'unique acte admin est ensuite son ajout à la team `humans`.
#
# ⚠ CETTE PHRASE DISAIT « sur une forge PRÉEXISTANTE — LE CAS DE LA PRODUCTION — l'opérateur a pu
# fermer l'inscription dans SON app.ini », et le glissement était dans « son » : la forge n'est pas
# celle d'un tiers, c'est un COMPOSANT de LCARS (⚖ user 2026-08-17). L'autre objet, celui qui
# appartient à la team, c'est la SORTIE PUBLIQUE — GitHub, un GitLab interne — atteinte par
# `lcars forge add --host github` et le rail `publish`. Deux choses, un seul mot, et les confondre
# fait dériver tout le raisonnement d'autorité qui suit.
#
# CE QUI NE CHANGE PAS, ET QUI EST LE BON GESTE : on livre un DÉFAUT (inscription ouverte, comptes
# non restreints — cf. `forge-compose.yml`), et un admin peut le changer chez lui. Alors le rail
# entier ne marche plus, sans qu'aucun message ne dise pourquoi — donc on SONDE et on ANNONCE,
# jamais on ne mute. Ce n'est pas parce que le réglage ne serait pas à nous ; c'est parce qu'un
# admin qui a décidé quelque chose ne doit pas se le faire reprendre en silence.
#
# ⚠ LE CODE HTTP NE DISCRIMINE RIEN — mesuré le 2026-08-12 sur Gitea 1.26.1, les deux états rendent
# `GET /user/sign_up` -> 200. La page, elle, diffère : ouverte, elle porte le FORMULAIRE ; fermée,
# elle porte « Registration is disabled ». On teste donc la présence du champ `user_name`, et pas le
# texte : un marqueur structurel survit à la locale de l'instance, un message traduit non.
# (Le POST discrimine aussi — 303 contre 403 — mais il CRÉE un compte quand ça marche : une sonde
# ne laisse pas de trace derrière elle.)
probe_registration() {
  local page
  page="$(curl -fsS -m 10 "$PROV_FORGE_URL/user/sign_up" 2>/dev/null || true)"
  if [[ -z "$page" ]]; then
    p_warn "page d'inscription non lisible ($PROV_FORGE_URL/user/sign_up) — l'ouverture de l'inscription N'EST PAS mesurée"
  elif [[ "$page" == *'name="user_name"'* ]]; then
    p_ok "inscription OUVERTE — une personne peut créer son compte, puis un propriétaire d'org l'ajoute à « humans »"
  else
    p_drift "inscription FERMÉE sur cette forge — l'enrollment ne peut pas fonctionner : personne ne peut créer son compte. C'est un réglage d'instance (DISABLE_REGISTRATION dans app.ini), à ouvrir par l'opérateur de la forge"
  fi
}

# JUMELLE DE LA SONDE CI-DESSUS, ET LE MÊME CONTRAT : un défaut qu'on livre, un admin qui peut le
# changer, une conséquence qu'il doit connaître.
#
# UN COMPTE `restricted` NE VOIT QUE CE QUI LUI EST EXPLICITEMENT ACCORDÉ, et une ORG n'est pas un
# dépôt — c'est ce que la mesure de 2026-08-12 avait manqué en ne regardant que l'accès aux dépôts.
# Mesuré le 2026-08-17 : un humain restreint, membre de `fleet` mais d'aucune org de catalogue, reçoit
# 404 sur l'org d'un catalogue quand il est CONNECTÉ, et 200 quand il ne l'est pas. Connecté, il voit
# moins qu'un inconnu, et tous les catalogues installés lui sont invisibles — contre l'arbitrage
# « une fois installé, le catalogue est dispo system-wide ».
#
# La sonde n'a besoin d'AUCUN jeton : `GET /users/<login>` expose `restricted` en anonyme (mesuré).
# C'est ce qui la rend jouable au même rang que `probe_registration`, avant tout mint.
probe_restricted() { # $1=login à sonder
  local login="$1" body
  [[ -n "$login" ]] || return 0
  body="$(curl -fsS -m 10 "$PROV_FORGE_URL/api/v1/users/$login" 2>/dev/null || true)"
  # ⚠ `has()` ET PAS `//` : l'opérateur `//` de jq traite `false` comme absent, donc un compte
  # correctement NON restreint serait lu « non mesurable » et la sonde se tairait là où elle doit
  # dire OK. Même piège que `forge_is_admin` dans human-converger.sh, même correctif.
  case "$(printf '%s' "$body" | jq -r 'if has("restricted") then .restricted else "?" end' 2>/dev/null)" in
    false) p_ok "compte $login non restreint — il voit les orgs des catalogues installés" ;;
    true)  p_drift "compte $login RESTREINT sur la forge — il ne verra AUCUNE org de catalogue dont il n'est pas membre (404 connecté, 200 en anonyme). C'est un réglage d'instance (DEFAULT_USER_IS_RESTRICTED dans app.ini) + le drapeau du compte : geste admin « Site Administration → Users → $login → décocher Restricted »" ;;
    *)     p_warn "drapeau restricted de $login non lisible ($PROV_FORGE_URL/api/v1/users/$login) — la visibilité des catalogues N'EST PAS mesurée" ;;
  esac
}

account_exists() { # $1=login — endpoint public en lecture (pas besoin d'admin pour SONDER)
  curl -fsS -m 10 -o /dev/null "$PROV_FORGE_URL/api/v1/users/$1" 2>/dev/null
}

missing_accounts() { # → la liste des comptes absents (vide = structure complète)
  # (nommé absents, pas « missing » : la lib a un array `missing` dans apt_ensure et
  # l'analyse -x confond les deux scopes — SC2178 parasite.)
  local acct absents=""
  for acct in $ACCOUNTS; do
    account_exists "$acct" || absents="$absents $acct"
  done
  printf '%s' "${absents# }"
}

# ─── L'AUTORITÉ QUE LA BOÎTE DÉTIENT (⚖ user 2026-08-16 : « on pose le token, IL RESTE ») ────────
# `p_warn` et PAS `p_drift`, et la nuance est le fond du sujet : une boîte sans ce jeton FONCTIONNE
# — l'apply de structure converge en lisant la forge, le runtime tourne sur les jetons de rôle. Ce
# qu'elle perd est la capacité d'un geste STRUCTUREL autonome : `lcars catalogue install` crée une
# org et un compte par rôle, et sans autorité de création il redevient un geste manuel de l'opérateur.
# Un drift dirait « l'état-cible n'est pas tenu », ce qui serait crier au loup sur une boîte saine.
check_master_authority() {
  if [[ -r "$PROV_MASTER_TOKEN_FILE" ]]; then
    p_ok "autorité de création présente ($PROV_MASTER_TOKEN_FILE) — un catalogue de plus s'enrôle sans geste d'opérateur"
  else
    p_warn "pas d'autorité de création ($PROV_MASTER_TOKEN_FILE) — la boîte tourne, mais tout geste STRUCTUREL (enrôler un catalogue, ajouter un rôle) redevient manuel : « fleet/deploy/box config » la pose"
  fi
}

# ⚠ LE MODE DES FICHIERS D'AUTORITÉ SE CONVERGE, IL NE SE POSE PAS UNE FOIS. Trois écrivains posent
# ces deux fichiers — `48-forge-host` au mint, `put_secret` (côté `forge-gestures.sh`) à l'écriture,
# et cette fonction à chaque apply — et seule celle-ci s'applique à un fichier DÉJÀ LÀ. Sans elle,
# un jeton posé sous un mode antérieur le garde pour toujours. MESURÉ SUR BANC le 2026-08-17, sur
# une boîte dont les jetons dataient de la veille.
#
# C'est la loi #1 du provisionnement (« l'état, c'est le système ») appliquée à un mode : ce qui
# n'est reposé qu'au geste initial dérive dès que le geste change d'avis.
#
# Le CONTENU n'est jamais touché ici — seulement `chmod`/`chgrp`. Un module qui réécrirait un
# secret pour en corriger le mode pourrait le perdre.
converge_authority_modes() {
  local f cur want="$PROV_AUTHORITY_USER:$PROV_AUTHORITY_USER"

  # ⚠ CE MODE N'EST PLUS UN GATE, ET C'EST LE FOND DU CHANGEMENT. Il l'a été : le jeton était
  # `0640 root:<groupe admin>` parce que le geste tournait sous l'uid de l'humain, donc DÉTENIR le
  # jeton était la preuve du droit. Le geste vit maintenant dans un service root
  # (`catalogue-executor.py`), qui demande à la forge à l'instant du geste. Plus personne n'a besoin
  # de LIRE ce fichier, donc plus personne ne doit pouvoir le lire.
  #
  # ⚠ ET IL N'Y A PLUS DE RETOUR ANTICIPÉ SUR UN GROUPE ABSENT. L'ancienne écriture rendait la main
  # en `p_drift` quand le groupe manquait — donc sur ce chemin le jeton restait tel que
  # `48-forge-host` l'avait posé au mint, `0640 root:$PROV_FLEET_GROUP`, LISIBLE PAR TOUT HUMAIN de
  # la boîte, sans qu'un apply échoue. Un fail-open sur une ACL est pire qu'une ACL absente : il a
  # l'air converge.
  for f in "$PROV_MASTER_TOKEN_FILE" "$PROV_FORGE_SEED_FILE"; do
    [[ -f "$f" ]] || continue
    cur="$(stat -c '%a %U:%G' "$f")"
    if [[ "$cur" != "600 $want" ]]; then
      if [[ "$PROV_MODE" == "check" ]]; then
        p_drift "$f est $cur — attendu 600 $want (aucun process d'humain ne doit pouvoir le lire)"
      else
        chown "$PROV_AUTHORITY_USER:$PROV_AUTHORITY_USER" "$f" && chmod 0600 "$f" \
          && p_chg "$f -> 0600 $want (seul le service d'autorite l'ouvre)" \
          || p_fail "$f : mode non convergé"
      fi
    else
      [[ "$PROV_MODE" == "check" ]] && p_ok "$f (0600 $want)"
    fi
  done

  # ⚠ `return 0` OBLIGATOIRE, ET SON ABSENCE A TUE UN BANC ENTIER (2026-08-17). Le dernier geste de
  # la boucle est `[[ "$PROV_MODE" == "check" ]] && p_ok …` : en mode APPLY il est FAUX, donc la
  # fonction rendait 1, donc `set -e` tuait le module juste apres cette ligne — sans un mot.
  #
  # ET IL NE MORD QUE SUR UNE BOITE DEJA CONVERGEE : au premier apply les modes sont a corriger, la
  # branche `chgrp && chmod && p_chg` rend 0, tout va bien. Des que `put_secret` a pose les fichiers
  # au bon mode (ce qu'il fait), le SECOND apply passe par ce `else` et meurt. Consequence mesuree :
  # aucun jeton de role minte, `55-deck-oidc` en drift, le convergeur aveugle, AUCUN humain
  # materialise — et le module annonce « echecs: 1 » sans nommer ce qui a echoue.
  #
  # La forme `[[ test ]] && cmd` en DERNIERE instruction d'une fonction est un piege general sous
  # `set -e` : elle transforme « ce cas ne s'applique pas » en « cette fonction a echoue ».
  return 0
}

# La sonde tokens EST le --check du script A4 (une seule vérité, pas une re-implémentation).
a4_check() {
  "$A4_SCRIPT" --forge "$PROV_FORGE_URL" --tokens-dir "$PROV_TOKENS_DIR" \
    --roles "$ROLES" --extra-token "$PROV_SYSTEM_ACCOUNT:$(basename "$PROV_SYSTEM_TOKEN_FILE")" --check >/dev/null 2>&1
}

# Le handoff tofu→A4, convergent PAR ENTRÉE : chaque compte de $ACCOUNTS a son entrée dans le
# passwords-file. Fichier absent → dérivé entier depuis le seed ; rôle AJOUTÉ après bootstrap →
# entrée manquante complétée depuis le seed (l'ajout de rôle converge dans le cycle — la
# dérivation fichier-entier ratait ce cas, attrapé au premier ajout réel : scoper). Les entrées
# existantes ne sont JAMAIS réécrites (un password tourné à la main reste sien).
ensure_passwords_entries() {
  local acct absents=()
  for acct in $ACCOUNTS; do
    if ! { [[ -r "$PROV_PASSWORDS_FILE" ]] && jq -e --arg a "$acct" 'has($a)' "$PROV_PASSWORDS_FILE" >/dev/null 2>&1; }; then
      absents+=("$acct")
    fi
  done
  [[ "${#absents[@]}" -eq 0 ]] && return 0
  if [[ ! -r "$PROV_FORGE_SEED_FILE" ]]; then
    p_drift "entrées passwords manquantes (${absents[*]}) et pas de seed ($PROV_FORGE_SEED_FILE) — « FORGE_SEED_PASSWORD=<seed> fleet/deploy/box config » le pose (ou complète $PROV_PASSWORDS_FILE), puis relance"
    return 1
  fi
  local seed tmp rc=0
  seed="$(tr -d '[:space:]' < "$PROV_FORGE_SEED_FILE")"
  [[ -n "$seed" ]] || { p_fail "seed vide : $PROV_FORGE_SEED_FILE"; return 1; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/prov-pwd.XXXXXX")" || { p_fail "tmp passwords-file"; return 1; }
  if ! { [[ -r "$PROV_PASSWORDS_FILE" ]] && cat "$PROV_PASSWORDS_FILE" || printf '{}'; } \
      | jq --arg s "$seed" '. + ($ARGS.positional | map({(.): $s}) | add)' --args "${absents[@]}" > "$tmp"; then
    rm -f "$tmp"; p_fail "complétion jq du passwords-file"; return 1
  fi
  write_atomic "$PROV_PASSWORDS_FILE" 0600 root:root < "$tmp" || rc=1
  rm -f "$tmp"
  [[ "$rc" -eq 0 ]] || return 1
  p_ok "passwords-file complété depuis le seed (entrées : ${absents[*]})"
}

# La visibilité des adhésions, SONDÉE ICI et posée ailleurs (`forge-gestures.sh`).
#
# ⚠ SON MOTIF ÉTAIT EMPRUNTÉ : « savoir QUI existe est un prérequis de sûreté » (BL-6-46). Mesuré le
# 2026-08-17 — `public_members` n'a AUCUNE autre occurrence dans le dépôt, et cette fiche n'apparaît
# que dans les commentaires de ce fichier. Rien ne LIT cette visibilité. Le besoin est réel et il est
# d'UX (⚖ user) : une adhésion privée est invisible aux non-membres, donc un humain qui ouvre l'org
# ne voit pas quels workers y travaillent. Nommer une commodité « sûreté » lui donne une priorité
# qu'elle n'a pas et rend son coût indiscutable.
#
# Sémantique MESURÉE sur Gitea 1.26.4 : publicize est SELF-ONLY (le token système sur autrui : 403,
# même avec write:organization ; sur lui-même : 204) et un token de rôle au scope minimal A4
# (write:repository,write:issue) répond 403 même sur soi. La seule voie est donc la basic-auth DU
# COMPTE — c'est pourquoi le geste vit là où le seed est en main, pas ici.
# Sonde : GET public_members/<u> (204 visible / 404 privé), token système si présent.
# ⚠ LE JETON NE PASSE JAMAIS PAR `argv` (6-141) : `-H "Authorization: token $tok"` le rend lisible
# dans `/proc` de tout l'hôte pendant l'appel. `-K -` fait lire l'en-tête à curl sur stdin ; un
# stdin VIDE est une requête anonyme parfaitement valide, donc la branche « pas de jeton » n'a
# besoin d'aucune forme à part.
forge_code() { # $1=chemin d'API → code HTTP, sous le jeton système s'il existe
  local tokfile="$PROV_SYSTEM_TOKEN_FILE" tok=""
  [[ -r "$tokfile" ]] && tok="$(tr -d '[:space:]' < "$tokfile")"
  { [[ -n "$tok" ]] && printf 'header = "Authorization: token %s"\n' "$tok" || true; } \
    | curl -K - -s -o /dev/null -w '%{http_code}' -m 10 \
        "$PROV_FORGE_URL/api/v1$1" 2>/dev/null || true
}

# TROIS états, pas deux — et c'est tout le correctif. `public_members/<u>` rend 404 aussi bien pour
# un membre qui se cache que pour quelqu'un qui n'est PAS membre (mesuré : `chief` membre caché 404,
# `nonmember` 404). Les traiter pareil produisait une consigne inapplicable — « rends ton adhésion
# publique » à qui n'en a pas — et masquait le défaut inverse : un compte avec un jeton et aucune
# team, qui est exactement ce que `chief` a été jusqu'au 2026-08-10. `members/<u>` les sépare (204
# membre / 404 non-membre) et c'est la sonde qui manquait.
#
# ⚠ QUATRE ETATS, PAS TROIS — et le quatrieme est « je ne sais pas ». `forge_code` appelle SANS
# AUCUN JETON quand le token systeme n'existe pas encore, et Gitea rend alors 404 sur l'adhesion
# d'une org privee : indiscernable d'une absence reelle. Le module accusait donc la recette
# (« la recette ne les place dans aucune team ») pour un fait qu'il n'avait pas l'autorite de lire.
# Mesure du 2026-08-16 sur une forge fraichement posee par `fleet/deploy/box forge-apply` : les cinq teams
# etaient peuplees et les dix comptes membres de l'org — le module annoncait le contraire, et
# renvoyait le lecteur vers les listes writers/judges/externals, qui n'y etaient pour rien.
# C'est l'etat NOMINAL d'une installation neuve : structure posee, jeton systeme pas encore minte.
member_state() { # $1=compte → visible | hidden | absent | unknown
  [[ -r "$PROV_SYSTEM_TOKEN_FILE" ]] || { printf 'unknown'; return; }
  [[ "$(forge_code "/orgs/$PROV_FORGE_ORG/members/$1")" == "204" ]] || { printf 'absent'; return; }
  if [[ "$(forge_code "/orgs/$PROV_FORGE_ORG/public_members/$1")" == "204" ]]; then
    printf 'visible'
  else
    printf 'hidden'
  fi
}

members_in_state() { # $1=état recherché, $2=liste → sous-liste
  local acct out=""
  for acct in $2; do [[ "$(member_state "$acct")" == "$1" ]] && out="$out $acct"; done
  printf '%s' "${out# }"
}

members_hidden() { members_in_state hidden "$1"; }

# ⚠ CETTE SONDE INTERROGEAIT `$ACCOUNTS`, ET ELLE ACCUSAIT. `$ACCOUNTS` contient les comptes de TOUS
# les catalogues installés (`prov_roles` boucle sur `/home/catalogues/*/`), or `member_state` ne
# regarde que `$PROV_FORGE_ORG`. Un `web-demo_dev`, parfaitement membre de `web-demo`, y était donc
# rendu « absent », et le module imprimait « la recette ne les place dans aucune team » — un
# diagnostic faux, qui envoyait l'opérateur vérifier des listes writers/judges/externals sans
# rapport. Mesuré le 2026-08-17.
#
# Elle sonde donc le ROSTER SYSTÈME seul : `$PROV_ROLES` est le plancher (avant que `prov_roles` n'y
# ajoute les catalogues), et c'est exactement la population de l'org système. La visibilité d'une org
# de catalogue est posée par `catalogue install`, dans le geste qui crée ses comptes.
check_members_visible() {
  local hidden absent unknown org_accounts="$PROV_ROLES $PROV_SYSTEM_ACCOUNT"
  unknown="$(members_in_state unknown "$org_accounts")"
  # NE RIEN DIRE D'AUTRE quand on ne peut pas lire. Enchainer sur « absent » ici produirait un
  # verdict sur des comptes qu'on n'a pas interroges, et il serait FAUX exactement au moment le plus
  # courant : juste apres la pose de la structure, avant le premier mint.
  if [[ -n "$unknown" ]]; then
    p_drift "adhésions org NON SONDABLES (jeton système absent : $PROV_SYSTEM_TOKEN_FILE) — l'apply le minte dès que le seed est posé ; rien n'est conclu sur les comptes en attendant"
    return 0
  fi

  absent="$(members_in_state absent "$org_accounts")"
  hidden="$(members_hidden "$org_accounts")"

  # Un compte sans adhésion a un jeton et AUCUN droit d'écriture : il échoue au premier geste, et
  # tard, parce que la recette ne l'a placé dans aucune team. Le publiciser n'y ferait rien.
  [[ -n "$absent" ]] && p_drift \
    "comptes SANS adhésion à l'org :$(printf ' %s' $absent) — jeton valide, zéro droit d'écriture. La recette ne les place dans aucune team (vérifier les listes writers/judges/externals)"

  if [[ -z "$hidden" ]]; then
    p_ok "adhésions org visibles (comptes machine)"
  else
    p_drift "adhésions org PRIVÉES :$(printf ' %s' $hidden) — invisibles aux non-membres, donc un humain ne voit pas quels workers travaillent ici. Le geste qui les pose est « fleet/deploy/box forge-apply » (il les publicise juste après la structure)"
  fi

  # L'humain : sonde seule, geste instruit — jamais convergé ici (cf. en-tête, point 3).
  if account_exists "$PROV_HUMAN"; then
    case "$(member_state "$PROV_HUMAN")" in
      hidden) p_drift "adhésion org de $PROV_HUMAN privée — geste utilisateur : profil forge → Organizations → $PROV_FORGE_ORG → visible (ou PUT public_members avec SES credentials)" ;;
      absent) p_drift "$PROV_HUMAN n'est membre d'aucune team de $PROV_FORGE_ORG — il ne verra pas les dépôts de l'org (team humans, lecture)" ;;
    esac
  fi
}


# ─── LE RUNNER CI : MESURE, JAMAIS POSE ──────────────────────────────────────────────────────────
#
# ⚖ ARBITRAGE 2026-07-30 : le runner est un sidecar compose, PAS un module — l'admin le provisionne
# avec ses choix. Cet arbitrage tient, et cette fonction ne le rouvre pas : elle ne pose rien.
#
# CE QU'IL NE DISAIT PAS, C'EST LE SILENCE. Une boite peut sortir sans aucun runner : la fleet
# accepte alors un ticket, depense un producteur, ouvre une PR, et la CI attend une machine qui
# n'existe pas. MESURE DU 2026-08-22 sur une forge de deux heures : sept courses `queued`, aucune
# demarree, zero runner aux trois portees (depot, org, instance) — et pas une ligne pour le dire.
# L'operateur l'a appris par un ticket bloque, pas par la boite.
#
# Ce fichier MESURE deja des preconditions d'INSTANCE qu'il ne pose pas — inscription ouverte,
# comptes restreints, adhesions d'org — et nomme a chaque fois le geste de l'operateur. Celle-ci est
# de la meme nature, au meme endroit, avec la meme sortie.
#
# ⚠ ON NE COMPARE PAS LES LABELS ICI, ET C'EST DELIBERE. « Un runner existe mais ne sert pas le label
# demande » est l'autre moitie du probleme (mesure du 2026-08-21 : un job `ubuntu-latest` sur une
# forge dont le seul runner servait `shell,elixir,dood`). Elle se mesure au TICKET et pas au boot :
# `CiGate` escalade en cinq minutes en NOMMANT le label que le job demande. Poser ici une liste de
# labels attendus en ferait une TROISIEME copie — le gabarit livre la porte deja, les defauts de
# `forge-runner.sh` aussi — et c'est exactement la forme qui derive.
check_ci_runner() {
  local tok body n labels
  [[ -r "$PROV_MASTER_TOKEN_FILE" ]] || {
    p_warn "runners CI non sondables (jeton master absent : $PROV_MASTER_TOKEN_FILE) — rien n'est conclu"
    return 0
  }
  tok="$(tr -d '[:space:]' < "$PROV_MASTER_TOKEN_FILE")"
  body="$(printf 'header = "Authorization: token %s"\n' "$tok" \
          | curl -K - -fsS -m 10 \
              "$PROV_FORGE_URL/api/v1/admin/actions/runners" 2>/dev/null || true)"

  # Une API muette n'est PAS « zero runner » : la portee du jeton suffit a expliquer le silence, et
  # conclure a l'absence enverrait enroler un runner qui existe deja.
  [[ -n "$body" ]] || {
    p_warn "runners CI non sondables (l'API admin n'a pas repondu — portee du jeton master ?) — rien n'est conclu"
    return 0
  }

  n="$(printf '%s' "$body" | jq -r '.total_count // 0' 2>/dev/null || echo 0)"
  if [[ "${n:-0}" -eq 0 ]]; then
    # Une forge sans runner accepte un ticket, depense un producteur, ouvre une PR — et la CI attend
    # une machine qui n'existe pas. C'est un etat-cible, pas un supplement : `48-forge-host` enrole
    # le runner apres avoir pose la forge, donc le rail PEUT le tenir, donc le mot est DRIFT.
    #
    # ⚠ « CE RAIL N'EN MONTE PAS » N'EST JAMAIS UNE RAISON DE BAISSER LE VERDICT. Un drift que rien
    # ne peut lever signale un module MANQUANT ; le degrader en constat rend le voyant muet et
    # laisse livrer l'objet incomplet.
    p_drift "AUCUN runner CI enregistre sur cette forge — tout job reste en attente, aucune PR ne fusionne, et le rail de livraison est mort avant son premier ticket. \`48-forge-host\` l'enrole : rejoue l'apply, sa sortie dira ce qui a bloque"
  else
    labels="$(printf '%s' "$body" \
      | jq -r '[.runners[]? | .name + " [" + ([.labels[]?.name] | join(",")) + "]"] | join(" · ")' 2>/dev/null || true)"
    p_ok "$n runner(s) CI : ${labels:-labels illisibles}"
  fi
}

check() {
  if [[ -z "$PROV_FORGE_URL" ]]; then
    p_drift "FORGE_BASE_URL/PROV_FORGE_URL non posé — l'état-cible inclut une forge (pose-le via --env ou l'environnement)"
    verdict_check
  fi
  _rc=0; forge_reachable || _rc=$?   # errexit : le code se recolte par `||`, jamais en nu
  case "$_rc" in
    1) p_drift "FORGE_BASE_URL=« $PROV_FORGE_URL » sans schéma — attendu : http://<hôte>:<port>"
       verdict_check ;;
    2) p_drift "forge injoignable : $PROV_FORGE_URL/api/v1/version"
       verdict_check ;;
  esac
  p_ok "forge joignable ($PROV_FORGE_URL)"
  check_ci_runner
  probe_registration
  probe_restricted "$PROV_HUMAN"
  check_master_authority
  PROV_MODE=check converge_authority_modes

  local miss acct
  miss="$(missing_accounts)"
  if [[ -n "$miss" ]]; then
    p_drift "structure absente (comptes : $miss) — territoire OpenTofu : « fleet/deploy/box forge-apply » la pose (tofu est DANS l'image ; « forge-check » enonce le contrat)"
  else
    for acct in $ACCOUNTS; do p_ok "compte $acct"; done
  fi

  if [[ -x "$A4_SCRIPT" ]]; then
    if a4_check; then
      p_ok "role-tokens valides (sonde A4 --check)"
    else
      p_drift "role-tokens absents/invalides (sonde A4 --check) — l'apply les re-mint"
    fi
  else
    p_fail "script A4 introuvable/inexécutable : $A4_SCRIPT (checkout incomplet ?)"
  fi

  check_human_onboardable
  check_members_visible
  verdict_check
}

# L'HUMAIN sur la forge — ce que le runtime exige à l'onboarding d'un projet, sondé ICI plutôt
# que découvert par un pod au milieu d'un create_project ({:human_not_provisioned, …} puis
# {:human_team_unverifiable, …}, vécus au premier E2E docker). L'appartenance se sonde au
# niveau ORG (204/404, lisible par le token système) et non au niveau TEAM : `GET
# /teams/<id>/members/<u>` est 403 pour lui — Gitea réserve la lecture d'une team à ses membres
# et aux owners, et le système n'est NI l'un NI l'autre (choix forge.tf, blast-radius borné).
check_human_onboardable() {
  local tokfile="$PROV_SYSTEM_TOKEN_FILE" tok code
  if ! account_exists "$PROV_HUMAN"; then
    p_drift "compte forge absent pour l'humain « $PROV_HUMAN » — l'onboarding projet échouera (human_not_provisioned) : LCARS_HUMAN=$PROV_HUMAN … « fleet/deploy/box forge-apply »"
    return 0
  fi
  p_ok "compte forge de l'humain ($PROV_HUMAN)"
  [[ -r "$tokfile" ]] || { p_drift "token système illisible ($tokfile) — appartenance de $PROV_HUMAN à l'org $PROV_FORGE_ORG non sondable"; return 0; }
  tok="$(tr -d '[:space:]' < "$tokfile")"
  code="$(printf 'header = "Authorization: token %s"\n' "$tok" \
          | curl -K - -s -o /dev/null -w '%{http_code}' -m 10 \
              "$PROV_FORGE_URL/api/v1/orgs/$PROV_FORGE_ORG/members/$PROV_HUMAN" 2>/dev/null || true)"
  case "$code" in
    204) p_ok "$PROV_HUMAN membre de l'org $PROV_FORGE_ORG (sonde du token système)" ;;
    404) p_drift "$PROV_HUMAN N'EST PAS membre de l'org $PROV_FORGE_ORG — l'onboarding projet le refusera ; il entre dans la team humans par « fleet/deploy/box forge-apply »" ;;
    *)   p_drift "appartenance de $PROV_HUMAN à l'org $PROV_FORGE_ORG non vérifiable (HTTP $code) — scope du token système ?" ;;
  esac
}

apply() {
  # B6 : aligné sur le check — URL vide ou forge injoignable est un DRIFT dit, pas un échec.
  # L'apply (dont le boot Docker) converge le reste et DIT ce qui manque.
  if [[ -z "$PROV_FORGE_URL" ]]; then
    p_drift "FORGE_BASE_URL/PROV_FORGE_URL non posé — comptes/tokens forge non convergés (pose-le et relance)"
    verdict_apply
  fi
  _rc=0; forge_reachable || _rc=$?   # errexit : le code se recolte par `||`, jamais en nu
  case "$_rc" in
    1) p_drift "FORGE_BASE_URL=« $PROV_FORGE_URL » sans schéma — attendu : http://<hôte>:<port> ; tokens non convergés"
       verdict_apply ;;
    2) p_drift "forge injoignable : $PROV_FORGE_URL — tokens non convergés (relance quand elle répond)"
       verdict_apply ;;
  esac

  # ⚠ TOT, ET DANS L'APPLY AUSSI — les deux points comptent.
  #
  # DANS L'APPLY : le boot joue `provision apply` (entrypoint.sh), jamais `check`. Une sonde qui ne
  # vivrait que dans le check ne parlerait a personne au demarrage, c'est-a-dire au seul moment ou
  # l'operateur peut encore enroler un runner AVANT que la fleet ne depense un producteur.
  #
  # TOT : posee en fin d'apply, elle n'etait atteinte que si tout le reste convergeait — la
  # structure absente sort par `verdict_apply` bien avant. On n'aurait donc appris l'absence de
  # runner que sur une boite deja parfaite par ailleurs, ce qui est l'inverse du besoin : une boite
  # qui derive AUSSI ailleurs a exactement le meme rail de livraison mort.
  check_ci_runner
  [[ -x "$A4_SCRIPT" ]] || { p_fail "script A4 introuvable : $A4_SCRIPT"; verdict_apply; }
  check_master_authority
  PROV_MODE=apply converge_authority_modes

  local miss
  miss="$(missing_accounts)"
  if [[ -n "$miss" ]]; then
    # Territoire tofu, et ce module ne le joue pas : il n'a ni l'URL ni le jeton MASTER, qui
    # arrivent par l'operateur. Le geste, lui, est desormais executable — tofu vit dans l'image.
    p_drift "structure absente (comptes : $miss) — « fleet/deploy/box forge-apply » la pose (il faut le token master + le seed ; « forge-check » enonce le contrat)"
    verdict_apply
  fi

  # ⚠ `converge_members_visible` VIVAIT ICI ET N'Y EST PLUS (2026-08-17). Elle rendait publiques les
  # adhésions d'org des comptes machine — à CHAQUE apply, donc à chaque démarrage, pour un fait qui
  # ne peut changer qu'au moment où des comptes sont créés. ⚖ Règle du re-roll : on repose le
  # squelette sans lequel la fleet ne produit rien, on ne remute pas la config.
  # Le geste vit désormais dans `forge-gestures.sh`, joué par `forge-apply` pour l'org système et par
  # `catalogue install` pour l'org du catalogue — chacun sur l'org qu'il vient de créer, ce qui
  # supprime au passage le défaut mono-org que ce module portait.
  if a4_check; then
    p_ok "role-tokens déjà valides ($PROV_TOKENS_DIR)"
    verdict_apply
  fi
  # Des tokens manquent/sont morts → mode pose (mint basic-auth). Le passwords-file converge
  # PAR ENTRÉE depuis le seed — fichier absent OU rôle ajouté après bootstrap, même chemin.
  ensure_passwords_entries || verdict_apply
  # ⚠ LE JETON MASTER EST DONNE AU MINTEUR, ET C'EST CE QUI REND LE MINT INDEPENDANT DE TOFU.
  # Le passwords-file reste, en repli : il derive du seed, or le provider ne pose reellement ce
  # password qu'a la CREATION du compte (`deps/instance/accounts.tf`). Des que les deux divergent,
  # le mint partait en 401 sur des comptes sains, definitivement. Avec le master token, le minteur
  # POSE un password neuf juste avant de s'en servir puis l'oublie — il n'a plus a croire ce qu'un
  # autre outil a bien voulu ecrire. Mesure sur instance vierge, 2026-08-19 : dix comptes en 401
  # avec le fichier, et PATCH 200 / basic-auth 200 / token minte par cette voie.
  if "$A4_SCRIPT" --forge "$PROV_FORGE_URL" --tokens-dir "$PROV_TOKENS_DIR" \
      --passwords-file "$PROV_PASSWORDS_FILE" --owner "$PROV_AUTHORITY_USER" \
      ${PROV_MASTER_TOKEN_FILE:+--master-token-file "$PROV_MASTER_TOKEN_FILE"} \
      --roles "$ROLES" --extra-token "$PROV_SYSTEM_ACCOUNT:$(basename "$PROV_SYSTEM_TOKEN_FILE")"; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "tokens A4 posés ($PROV_TOKENS_DIR)"
  else
    p_fail "provision-role-tokens.sh en échec (son verdict est au-dessus)"
  fi
  verdict_apply
}

case "${1:?usage: 50-forge.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
