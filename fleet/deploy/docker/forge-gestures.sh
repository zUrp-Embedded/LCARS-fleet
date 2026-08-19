#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/forge-gestures.sh
# AUTHOR: drdree
# STARDATE: 2026-08-16
# STATUS: les gestes forge de la boite — poses UNE fois, joues par tout appelant
#
# ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────────────────────────
# Ces trois gestes vivaient dans `docker.sh`, sous forme de scripts distants passes a
# `compose exec bash -c`. Le banc ne peut PAS appeler `docker.sh` : sa boite est creee par un autre
# couple de fichiers compose (`docker-compose.install.yml` + `.bench.yml`), et `docker.sh` refuse
# — a raison — d'agir sur un projet qu'il n'a pas cree. Le banc aurait donc recopie les memes
# gestes, et deux copies d'un meme contrat derivent.
#
# Ils vivent donc DANS L'IMAGE, versionnes avec la recette qu'ils jouent. `docker.sh` et le banc
# sont alors deux facons d'entrer par la meme porte :
#     docker.sh          -> compose exec -T -u root lcars /opt/lcars/forge-gestures.sh <geste>
#     bench              -> docker exec -i -u root <box>  /opt/lcars/forge-gestures.sh <geste>
#
# ─── LES SECRETS ENTRENT PAR STDIN, JAMAIS PAR argv ─────────────────────────────────────────────
# `/proc/<pid>/cmdline` est lisible par tout le monde pendant l'appel — la lecon payee deux fois
# par 6-141 et 6-141bis, sur des credentials moins puissants que le master token. Un `--token X`
# l'aurait mis dans la ligne de commande de CE script ET dans celle du client docker.
#
# USAGE : forge-gestures.sh <geste>
#   config-token   lit un jeton master sur STDIN, le VERIFIE contre la forge de la boite, puis le
#                  pose en `0640 root:lcars-admin`. Un jeton qui ne s'authentifie pas n'est PAS ecrit.
#   config-seed    lit le seed sur STDIN, meme mode (handoff tofu -> mint A4).
#   apply          joue la recette : module instance/, module catalogue, puis le depot modele.
#                  Ne prend RIEN — il lit ce que la boite detient. Un jeton sur STDIN l'emporte.
#   toolchain-protection <login-du-siege> [admins...]
#                  GESTE D'INSTALLATION du rail toolchain : pose la protection de la branche
#                  \`sysadmin\` du depot ops (required_approvals=1, whitelist nommant le SIEGE —
#                  son login est VARIABLE, jamais en dur — dismiss_stale ; SANS status check,
#                  allumage en deux temps). Conclut par RELECTURE, et n'imprime la ligne de config
#                  :toolchain_auto_merge QUE si la protection tient — jamais l'un sans l'autre.
#   install <nom>  installe — ou MET A JOUR — le catalogue <nom> depuis le depot que la forge porte :
#                  resolution du depot, clone, MEME verification que le boot, roster derive, recette
#                  (org + comptes + teams), puis la source poussee dans <nom>/catalogue. Jamais
#                  declenche par le boot.
#   runner-token   minte un jeton d'ENREGISTREMENT de runner et l'imprime. Sortie unique, sur
#                  stdout : c'est un credential a usage unique, il ne se pose nulle part.
#
# EXIT : 0 · 1 donnee manquante ou geste en echec · 2 la boite n'a pas de FORGE_BASE_URL (et, pour
#        `install`, aucun depot ne porte ce nom) · 3 le jeton ne s'authentifie pas (et, pour
#        `install`, DEUX depots revendiquent le nom) · 4 `install` d'un catalogue livre dans le release

set -euo pipefail

# Les chemins sont SURCHARGEABLES, comme ceux de `provision-lib.sh`, et pour la meme raison : un
# temoin doit pouvoir exercer ce script sans etre root ni ecrire dans /home/private. Les defauts
# sont les chemins reels ; aucun appelant de production ne les passe.
PRIVATE_DIR="${LCARS_PRIVATE_DIR:-/home/private}"
MASTER_TOKEN_FILE="${LCARS_MASTER_TOKEN_FILE:-$PRIVATE_DIR/forge-master.token}"
SEED_FILE="${LCARS_FORGE_SEED_FILE:-$PRIVATE_DIR/forge-seed.pass}"
RECIPE_DIR="${LCARS_RECIPE_DIR:-/opt/lcars/fleet/deploy/deps}"
# Le repertoire de travail des gestes de structure. Il remonte ICI, avec les autres chemins, parce
# que le verrou d'apply y vit desormais — et une variable definie plus bas que sa premiere lecture
# ne tient que par l'ordre d'execution.
CATALOGUE_WORK="${LCARS_CATALOGUE_WORK:-/var/lib/lcars/tofu}"
# Le groupe qui porte `is_admin` de la forge — miroir de `PROV_ADMIN_GROUP` (provision-lib).
ADMIN_GROUP="${PROV_ADMIN_GROUP:-lcars-admin}"
# L'ENTRYPOINT porte les portes outil du release (`verify`, `roles-tfvars`,
# `catalogue-source`, `template-sync`). Il s'appelait `TEMPLATE_SYNC` quand il n'en servait
# qu'une : un nom qui decrit un seul usage devient faux au deuxieme.
ENTRYPOINT="${LCARS_ENTRYPOINT:-${LCARS_TEMPLATE_SYNC:-/opt/lcars/entrypoint.sh}}"

die() { echo "forge-gestures: $*" >&2; exit "${2:-1}"; }

need_forge_url() {
  [[ -n "${FORGE_BASE_URL:-}" ]] || {
    echo "forge-gestures: cette boite n'a pas de FORGE_BASE_URL — un jeton sans forge ne veut rien dire." >&2
    echo "                FORGE_BASE_URL=<url> ./docker.sh up, puis rejoue." >&2
    exit 2; }
}

# La config de curl est un format cite : la valeur est ECHAPPEE, pas esperee propre. Meme geste
# que `provision-forge-charte.sh` et `forge-existing.sh`.
curl_cfg_escape() { local v="$1"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s' "$v"; }

# Ecriture ATOMIQUE dans le repertoire cible (rename garanti par le noyau sur le meme systeme de
# fichiers) : un appel interrompu ne laisse jamais un demi-secret que le lecteur suivant prendrait
# pour le vrai.
put_secret() { # $1=chemin  $2=valeur
  # `chown`/`-o root` ne sont tentes QUE si on est root. Tout appelant reel l'est (`docker exec
  # -u root`), et un temoin ne l'est pas : conditionner ici evite une garde `|| true` qui
  # avalerait un vrai echec de propriete sur une boite.
  if [[ "$(id -u)" -eq 0 ]]; then
    install -d -m 0750 -o root -g fleet "$PRIVATE_DIR"
  else
    install -d -m 0750 "$PRIVATE_DIR"
  fi
  local tmp="${1%/*}/.$(basename "$1").tmp"
  umask 077
  printf '%s\n' "$2" > "$tmp"

  # ⚖ 2026-08-17 : `0640 root:$ADMIN_GROUP` ET PLUS `0600 root`. Le mode EST le gate — « la
  # capacite, pas un drapeau qu'on peut oublier de poser » — mais il gatait sur `uid 0`, or aucun
  # humain n'est root et ne le sera : le seul root est `admiral`, compte d'administration SYSTEME,
  # dont le metier est d'installer des paquets et non des catalogues. Le groupe porte `is_admin`
  # de la forge, projete par le convergeur d'humains. La capacite ne change pas de nature, elle
  # change de GRANTEUR : la forge au lieu de l'uid.
  if [[ "$(id -u)" -eq 0 ]] && getent group "$ADMIN_GROUP" >/dev/null 2>&1; then
    chmod 0640 "$tmp"
    chown root:"$ADMIN_GROUP" "$tmp"
  else
    # Pas root, ou groupe absent : on RESSERRE plutot que d'ouvrir a un groupe qu'on n'a pas pu
    # nommer. Un secret trop ferme se diagnostique ; trop ouvert, non.
    chmod 0600 "$tmp"
  fi
  mv -f "$tmp" "$1"
}

read_stdin_secret() {
  local v=""
  IFS= read -r v || true
  printf '%s' "$v"
}

cmd_config_token() {
  need_forge_url
  local tok; tok="$(read_stdin_secret)"
  [[ -n "$tok" ]] || die "jeton vide sur stdin"

  # VERIFIER AVANT D'ECRIRE. Poser un jeton qui ne s'authentifie pas produirait une boite qui croit
  # tenir son autorite et le decouvre au premier geste structurel, des mois plus tard.
  local code
  code="$(printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
          | curl -sS -K - -o /dev/null -w '%{http_code}' -m 15 "${FORGE_BASE_URL%/}/api/v1/user" || true)"
  [[ "$code" == "200" ]] \
    || die "ce jeton ne s'authentifie pas sur $FORGE_BASE_URL (HTTP $code) — RIEN n'a ete ecrit" 3

  put_secret "$MASTER_TOKEN_FILE" "$tok"
  echo "forge-gestures: jeton master pose et VERIFIE ($MASTER_TOKEN_FILE, lisible par $ADMIN_GROUP)"
}

cmd_config_seed() {
  local seed; seed="$(read_stdin_secret)"
  [[ -n "$seed" ]] || die "seed vide sur stdin"
  put_secret "$SEED_FILE" "$seed"
  echo "forge-gestures: seed pose ($SEED_FILE, lisible par $ADMIN_GROUP)"
}

# ⚠ UN SEUL APPLY A LA FOIS. Deux `forge-apply` concurrents ecriraient le meme `terraform.tfstate`
# dans `$RECIPE_DIR`, et tofu ne se protege pas d'un backend local partage. L'etat est jetable
# depuis le lot 1, donc le degat n'est pas durable — mais un apply qui se termine sur l'etat de
# l'autre rend un verdict sur un travail qu'il n'a pas fait, et c'est ca qu'on refuse.
#
# `flock -n` : on REFUSE, on n'attend pas. Un appelant qui attendrait aurait deja recu son verdict
# quand l'autre finit, et il repartirait sur une forge qui a bouge sous lui. Meme choix que
# `provision`, qui refuse aussi (`un autre apply est en cours`).
#
# ⚠ LE VERROU VIVAIT DANS `/run/lock`, ET IL N'ETAIT PRENABLE QUE PAR SON PREMIER CREATEUR.
# `/run/lock` est en `1777` : n'importe qui y CREE un fichier — mais le boot joue l'apply en ROOT,
# donc root creait `lcars-forge-apply.lock` en `0644 root:root`, et l'humain qui jouait
# `lcars catalogue install` ensuite ouvrait en ecriture un fichier qui ne lui appartenait pas.
# Mesure du 2026-08-18, reproduite sur deux bancs : « Permission denied », puis « verrou d'apply
# inouvrable » — un refus qui accuse le verrou pour un probleme de proprietaire. Le geste etait
# donc injouable par un humain sur toute boite ayant demarre une fois.
#
# Il vit maintenant dans `$CATALOGUE_WORK`, et ce n'est pas un deplacement de commodite : ce
# repertoire est POSE PAR LE PROVISIONNEMENT en `2770 root:$ADMIN_GROUP`, c'est-a-dire avec
# exactement la reponse a « qui a le droit de jouer un geste de structure ». Le setgid donne le
# groupe, `umask 007` a la creation donne l'ecriture — donc root au boot et l'humain admin ensuite
# ouvrent le MEME verrou, quel que soit celui des deux qui l'a cree en premier.
with_apply_lock() {
  local lock="${LCARS_APPLY_LOCK:-$CATALOGUE_WORK/.apply.lock}"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  # `umask 007` PORTE LE PARTAGE, et il ne vaut qu'a la creation : un fichier deja la garde son
  # mode. C'est voulu — un operateur qui a durci ce verrou n'est pas contredit en silence.
  [[ -e "$lock" ]] || ( umask 007; : > "$lock" ) 2>/dev/null || true
  exec 9>"$lock" || die "verrou d'apply inouvrable ($lock) — regarde son proprietaire et son mode : il doit etre ouvrable en ecriture par $ADMIN_GROUP (le provisionnement pose $CATALOGUE_WORK en 2770 root:$ADMIN_GROUP)"
  flock -n 9 || die "un autre apply de structure est en cours (verrou $lock) — rien n'a ete tente"
  "$@"
}

# ─── LA VISIBILITE DES ADHESIONS MACHINE ────────────────────────────────────────────────────────
# CE GESTE VIVAIT DANS LA BOUCLE DE BOOT, ET IL N'AVAIT RIEN A Y FAIRE. `50-forge.sh` le rejouait a
# chaque `provision apply` : une convergence, a chaque demarrage, pour un fait qui ne peut changer
# qu'au moment ou des comptes sont crees. C'est la regle du re-roll (⚖ user 2026-08-17) — on repose
# le squelette, on ne remute pas la config.
#
# ET IL ETAIT MONO-ORG, ce que le deplacement corrige tout seul. La sonde interrogeait
# `/orgs/$PROV_FORGE_ORG/...` en dur, donc elle ne voyait jamais l'org d'un catalogue : mesure du
# 2026-08-17, `fleet` portait ses dix comptes machine en public et `web-demo` AUCUN. Pire, elle
# accusait — les comptes `web-demo_*` etaient dans sa liste, cherches dans `fleet`, donc rendus
# « absents », et le module imprimait « la recette ne les place dans aucune team » pour des comptes
# parfaitement places dans la leur. Ici chaque geste traite SON org, et la question ne se pose plus.
#
# A QUOI CA SERT, ET CE N'EST PAS DE LA SURETE (⚖ user 2026-08-17) : c'est de l'UX. Une adhesion
# privee est invisible aux non-membres, donc un humain qui ouvre l'org ne voit pas quels workers y
# travaillent. Le motif « savoir QUI existe est un prerequis de surete » etait emprunte : rien dans
# le depot ne LIT cette visibilite.
#
# ⚠ `publicize` EST SELF-ONLY, mesure sur Gitea 1.26.4 : le jeton master sur un autre compte rend
# 403, meme avec `write:organization` ; un jeton de role au scope A4 rend 403 meme sur lui-meme. La
# seule voie est donc la basic-auth DU COMPTE — et c'est ce qui rend cette boucle auto-limitante :
# les comptes que tofu vient de creer portent le seed, une vraie personne porte le sien, donc un
# 401 sur un humain est le comportement voulu et non une panne. On ne publicise que ce qu'on possede.
publicize_org_members() { # $1=org  $2=jeton de lecture  $3=seed
  local org="$1" tok="$2" seed="$3" acct code posed=0 skipped=0
  local -a members=()
  mapfile -t members < <(curl -sS -m 15 -H "Authorization: token $tok" \
      "${FORGE_BASE_URL%/}/api/v1/orgs/$org/members" 2>/dev/null \
    | jq -r 'if type=="array" then .[].login else empty end' 2>/dev/null || true)

  [[ ${#members[@]} -gt 0 ]] || { echo "forge-gestures: $org — aucun membre lu, visibilite non posee" >&2; return 0; }

  for acct in "${members[@]}"; do
    [[ -n "$acct" ]] || continue
    # DEJA PUBLIC : on ne rejoue pas un PUT pour le plaisir d'un 204. 204 = public, 404 = prive.
    [[ "$(curl -sS -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: token $tok" \
          "${FORGE_BASE_URL%/}/api/v1/orgs/$org/public_members/$acct" 2>/dev/null)" == "204" ]] && continue
    code="$(curl -sS -o /dev/null -w '%{http_code}' -m 10 -X PUT -u "$acct:$seed" \
            "${FORGE_BASE_URL%/}/api/v1/orgs/$org/public_members/$acct" 2>/dev/null || true)"
    case "$code" in
      204) posed=$((posed + 1)) ;;
      # 401/403 = ce compte n'est pas a nous (une personne a change son mot de passe, ou n'a jamais
      # eu le seed). C'est le cas NOMINAL pour un humain : sa visibilite lui appartient.
      401|403) skipped=$((skipped + 1)) ;;
      *) echo "forge-gestures: $org/$acct — publicize HTTP $code" >&2 ;;
    esac
  done

  echo "forge-gestures: $org — $posed adhesion(s) rendue(s) visible(s), $skipped compte(s) hors de notre autorite"
}

cmd_apply() {
  local tok seed
  # Le jeton donne a la main l'emporte sur celui que la boite garde ; le SEED, lui, n'a pas de
  # variante : il doit etre celui des comptes existants, et rien d'autre. Le provider n'ecrit pas
  # le password d'un compte existant (mesure 2026-08-16), donc un autre seed ne changerait rien
  # sur la forge et casserait le mint.
  tok="$(read_stdin_secret)"
  [[ -n "$tok" ]] || tok="$(cat "$MASTER_TOKEN_FILE" 2>/dev/null || true)"
  seed="$(cat "$SEED_FILE" 2>/dev/null || true)"

  local manque=""
  [[ -n "${FORGE_BASE_URL:-}" ]] || manque="$manque\n  l'URL de la forge   -> FORGE_BASE_URL=<url> ./docker.sh up"
  [[ -n "$tok" ]]                || manque="$manque\n  l'autorite          -> FORGE_ADMIN_TOKEN=<token master> ./docker.sh config"
  [[ -n "$seed" ]]               || manque="$manque\n  le seed des comptes -> FORGE_SEED_PASSWORD=<mot de passe> ./docker.sh config"
  if [[ -n "$manque" ]]; then
    printf 'forge-gestures: la boite ne detient pas ce qu il faut :%b\n' "$manque" >&2
    exit 1
  fi

  export TF_VAR_gitea_url="$FORGE_BASE_URL"
  export TF_VAR_gitea_token="$tok"
  export TF_VAR_seed_password="$seed"
  # ⚠ LE DEFAUT ETAIT UN RESIDU, PAS UN CHOIX : cette ligne lisait
  # `${LCARS_FORGE_HUMAN:-${LCARS_HUMAN:-lcars}}`, et `LCARS_HUMAN` n'existe plus depuis identity-v2
  # (cf. `console.sh` : « Pas de defaut : identite-v2 a retire l'humain unique »). Le nom `lcars`
  # tombait donc d'une variable morte, pour un compte qui, lui, a une raison d'etre : le siege
  # BUILT-IN de demonstration, cible du tutoriel de promotion admin. Le defaut est desormais
  # delibere et la variable dit ce qu'elle nomme.
  export TF_VAR_builtin_human="${LCARS_BUILTIN_HUMAN:-lcars}"
  export TF_VAR_builtin_email="${LCARS_BUILTIN_EMAIL:-${TF_VAR_builtin_human}@lcars.local}"

  # L'ORDRE EST UN INVARIANT, pas une preference : `instance/` porte les comptes partages, et une
  # adhesion peut nommer un compte qu'elle ne cree pas, jamais un compte qui n'existe pas.
  local m
  for m in instance .; do
    echo "forge-gestures: apply $m"
    ( cd "$RECIPE_DIR/$m" && tofu apply -auto-approve -input=false -no-color ) \
      || die "apply $m en echec — rien n'est suppose, relis la sortie ci-dessus"
  done

  # ─── LE DEPOT MODELE, dans le meme geste ──────────────────────────────────────────────────────
  # `create_project` GENERE depuis lui ; absent, l'onboard degrade en bare-create sur chaque projet.
  # AVEC LE JETON MASTER, ce qui supprime un ordre : le poser avec le jeton SYSTEME exigerait qu'il
  # soit deja minte, donc un boot entre l'apply et ce geste.
  #
  # ⚠ NON FATAL, ET C'EST DELIBERE : la structure EST posee a ce stade. Un modele qui ne part pas
  # est une degradation NOMMEE, pas une raison de rendre un echec sur un geste qui a reussi.
  echo "forge-gestures: depot modele (project-template)"
  local tf; tf="$(umask 077; mktemp)"
  printf '%s\n' "$tok" > "$tf"
  # shellcheck disable=SC2064 -- on veut la valeur d'ICI, pas celle du moment du trap
  trap "rm -f '$tf'" EXIT
  FORGE_TOKEN_FILE="$tf" "$ENTRYPOINT" template-sync \
    || echo "forge-gestures: depot modele NON pose — l'onboard degradera en bare-create (dit a chaque projet)" >&2

  # La visibilite des comptes machine de l'org systeme, DANS LE GESTE QUI VIENT DE LES CREER.
  publicize_org_members "${PROV_FORGE_ORG:-fleet}" "$tok" "$seed"

  seed_demo_catalogue "$tok"
}

# ─── LA DEMO, DEPOSEE CHEZ LE MASTER ────────────────────────────────────────────────────────────
# `web-demo` est un catalogue metier COMPLET qui montre comment on en fait un et comment on
# l'installe. Il est livre dans l'image, depose sur la forge — donc immediatement `available` — et
# JAMAIS installe : c'est a l'operateur de decider, et le nom le pousse au fork plutot qu'a
# l'installation.
#
# DANS L'ESPACE DE `id = 1`, et pas ailleurs. C'est le seul espace garanti present que LCARS n'a pas
# invente : Gitea le cree a son installation, avant nous, et la recette ecrit deja « le premier admin
# est un PREREQUIS D'ENTREE, pas un produit ». Le compte humain, lui, EST cree par la recette mais
# sous le login que l'operateur choisit — on ne peut pas s'y ancrer.
#
# ⚠ REPOSE A CHAQUE APPLY, en projection (force-push). Son README le dit en toutes lettres : un
# admin qui l'edite en place perd ses modifications. C'est la bonne semantique pour une demo, et
# c'est pour ca qu'elle doit etre ECRITE plutot qu'apprise.
#
# NON FATAL : la structure est posee a ce stade. Une demo qui ne part pas est une demo absente, pas
# un deploiement casse.
DEMO_CATALOGUE="${LCARS_DEMO_CATALOGUE:-/opt/lcars/catalogues/web-demo}"

seed_demo_catalogue() { # $1=jeton master
  local tok="$1"
  [[ -d "$DEMO_CATALOGUE" ]] || return 0

  local name; name="$(basename "$DEMO_CATALOGUE")"
  local master
  master="$(printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
            | curl -sS -K - -m 15 "${FORGE_BASE_URL%/}/api/v1/admin/users?limit=50" 2>/dev/null \
            | jq -r 'map(select(.id == 1)) | .[0].login // empty' 2>/dev/null || true)"
  if [[ -z "$master" ]]; then
    # Un refus qui ne nomme pas SON objet est un demi-message : celui qui le lit ne sait pas ce
    # qui manque a sa forge.
    echo "forge-gestures: master (id=1) non resolu — $name NON depose, il n'apparaitra pas dans « catalogue list »" >&2
    return 0
  fi

  echo "forge-gestures: catalogue de demonstration ($name -> $master/$name)"
  printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
    | curl -sS -K - -o /dev/null -m 20 -X POST -H 'Content-Type: application/json' \
      -d "{\"name\":\"$name\",\"private\":false,\"auto_init\":false}" \
      "${FORGE_BASE_URL%/}/api/v1/user/repos" 2>/dev/null || true

  local stage; stage="$(mktemp -d)"
  cp -r "$DEMO_CATALOGUE/." "$stage/"
  rm -rf "$stage/.git"
  ( cd "$stage" \
    && git init -q -b main \
    && git add -A \
    && git -c user.name=lcars-system -c user.email=lcars-system@lcars.local \
         commit -q -m "chore(catalogue): projection de $name depuis l image" \
    && GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
       GIT_CONFIG_KEY_0="http.${FORGE_BASE_URL%/}.extraheader" \
       GIT_CONFIG_VALUE_0="Authorization: token $tok" \
       git push -q --force "${FORGE_BASE_URL%/}/${master}/${name}.git" main ) \
    || echo "forge-gestures: $name NON depose chez $master — il n'apparaitra pas dans « catalogue list »" >&2
  rm -rf "$stage"
}

# Le jeton d'ENREGISTREMENT d'un runner. Il n'entre PAS dans la recette, et c'est un choix mesure :
# le provider sait le produire (`data.gitea_actions_runner_registration_token`, scope « admin »,
# 0.8.1), mais une data source ECRIT sa valeur dans le tfstate — un credential dans un fichier
# d'etat, pour un objet qui n'est pas de la structure. C'est une LECTURE a usage unique : elle
# s'imprime et s'oublie.
# ─── toolchain-protection — LE GESTE D'INSTALLATION du rail toolchain (⚖ user 2026-08-19) ──────
# Pose la protection de la branche `sysadmin` du depot ops : `required_approvals=1` + whitelist
# d'approbateurs (les admins convergés + LE SIEGE, nomme par argument — il n'est pas dans
# fleet:humans, `01` §3.11) + `dismiss_stale_approvals` (un re-push tue l'approbation — la seule
# propriete qu'aucun test ni ACL ne porte). SANS status check : l'allumage est en DEUX temps
# (`01` §4.7 addendum), le contexte `toolchain-dryrun` viendra AVEC son job.
#
# ⚠ CE GESTE ET LA CONFIG :toolchain_auto_merge VONT ENSEMBLE, JAMAIS L'UN SANS L'AUTRE : armer
# l'auto-merge sur une branche sans protection = « conditions remplies » tout de suite = merge
# sans signature, convergeur derriere. Le defaut runtime est OFF ; ce geste imprime la ligne de
# config a poser une fois la protection VERIFIEE (le test de fin de chantier).
cmd_toolchain_protection() { # toolchain-protection <login-du-siege> [autres-approbateurs...]
  need_forge_url
  [[ $# -ge 1 ]] || die "toolchain-protection: le LOGIN du siege est requis (variable — celui de l'installeur ; jamais en dur)"
  local tok; tok="$(cat "$MASTER_TOKEN_FILE" 2>/dev/null || true)"
  [[ -n "$tok" ]] || die "pas d'autorite — « FORGE_ADMIN_TOKEN=<token master> ./docker.sh config »"

  local repo="${LCARS_OPS_REPO:-fleet/lcars}" branch="${LCARS_SYSADMIN_BRANCH:-sysadmin}"
  local approvers; approvers="$(printf '"%s",' "$@")"; approvers="[${approvers%,}]"

  # POST best-effort (idempotence par RELECTURE, pas par code devine — une v1 concluait
  # « deja presente » sur un 409/422 alors que Gitea rend d'autres codes selon la version, et un
  # 422 de validation aurait passe pour un succes suivi de l'activation de l'auto-merge : merge
  # sans signature, l'exact bloquant n5 du PLAN).
  curl -sS -m 15 -o /dev/null     -H "Authorization: token $tok" -H 'Content-Type: application/json'     -X POST "${FORGE_BASE_URL%/}/api/v1/repos/$repo/branch_protections"     -d "{\"branch_name\":\"$branch\",\"required_approvals\":1,\"enable_approvals_whitelist\":true,\"approvals_whitelist_username\":$approvers,\"dismiss_stale_approvals\":true}" || true

  # LA RELECTURE FAIT FOI : la protection existe ET porte les champs qui comptent, sinon rien
  # n'est annonce et SURTOUT pas la ligne de config auto-merge.
  local got
  got="$(curl -sS -m 15 -H "Authorization: token $tok"     "${FORGE_BASE_URL%/}/api/v1/repos/$repo/branch_protections/$branch" 2>/dev/null || true)"

  local ra ds
  ra="$(jq -r '.required_approvals // empty' <<< "$got" 2>/dev/null || true)"
  ds="$(jq -r '.dismiss_stale_approvals // empty' <<< "$got" 2>/dev/null || true)"

  if [[ "$ra" == "1" && "$ds" == "true" ]]; then
    echo "forge-gestures: protection VERIFIEE par relecture sur $repo:$branch (required_approvals=1, dismiss_stale, approbateurs: $approvers)"
    echo "  -> ACTIVER l'auto-merge maintenant que la protection TIENT :"
    echo "     config :lcars_fleet, :toolchain_auto_merge, true   (runtime.exs / env du deploy)"
  else
    echo "relecture: $got" >&2
    die "toolchain-protection: la protection n'est PAS en place sur $repo:$branch — NE PAS activer :toolchain_auto_merge"
  fi
}

cmd_runner_token() {
  need_forge_url
  local tok
  tok="$(read_stdin_secret)"
  [[ -n "$tok" ]] || tok="$(cat "$MASTER_TOKEN_FILE" 2>/dev/null || true)"
  [[ -n "$tok" ]] || die "pas d'autorite — « FORGE_ADMIN_TOKEN=<token master> ./docker.sh config »"

  local body
  body="$(printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
          | curl -sS -K - -m 15 -X POST "${FORGE_BASE_URL%/}/api/v1/admin/actions/runners/registration-token" || true)"
  local reg
  reg="$(printf '%s' "$body" | jq -r '.token // empty' 2>/dev/null || true)"
  [[ -n "$reg" ]] || die "la forge n'a pas rendu de jeton d'enregistrement (portee du jeton master ?)"
  printf '%s\n' "$reg"
}

# ─── INSTALLER UN CATALOGUE ─────────────────────────────────────────────────────────────────────
# Un seul verbe, et il MET A JOUR quand le catalogue est deja la (⚖ user 2026-08-16). Rien n'existe
# -> il cree ; la source a bouge -> il reconverge ; rien n'a bouge -> il ne touche rien. Jamais
# declenche par le boot : une mise a jour automatique changerait le metier sous les pieds d'une
# flotte qui tourne.
#
# LE GATE ADMIN N'EST PAS UN DRAPEAU QU'ON INVENTE. Installer exige de lire le jeton master
# (`0640 root:lcars-admin`, groupe derive de `is_admin`) et d'ecrire l'etat de tofu : la capacite
# EST la permission. Un non-admin qui tente le
# geste est refuse par le systeme de fichiers, pas par un booleen qu'on pourrait oublier de poser.
#
# ⚠ UN DOSSIER DE RECETTE PAR CATALOGUE. La recette lit `roles.auto.tfvars.json` dans son propre
# dossier, et ce fichier porte l'org ET le roster : deux catalogues dans le meme dossier, c'est le
# dernier installe qui decide de ce que le suivant applique. L'etat etant jetable (il se reconstruit
# par import), un dossier par catalogue ne coute qu'une copie et supprime la question.
# (`CATALOGUE_WORK` est declare en tete, avec les autres chemins : le verrou d'apply en depend.)

cmd_install() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "install: nom de catalogue requis"
  need_forge_url

  local tok; tok="$(cat "$MASTER_TOKEN_FILE" 2>/dev/null || true)"
  [[ -n "$tok" ]] || die "install: pas d'autorite — « FORGE_ADMIN_TOKEN=<token master> ./docker.sh config »"
  local seed; seed="$(cat "$SEED_FILE" 2>/dev/null || true)"
  [[ -n "$seed" ]] || die "install: pas de seed — « FORGE_SEED_PASSWORD=<mot de passe> ./docker.sh config »"

  # 1. QUI porte ce catalogue. La porte refuse l'absent, le doublon et le catalogue livre, chacun
  #    avec son code — on ne traduit pas, on relaie.
  #    ⚠ PAS LE JETON MASTER, ET CE N'EST PAS UNE PREFERENCE. La porte tourne en `nobody:fleet`
  #    (`setpriv --reuid 65534 --regid 2000`) parce que c'est une LECTURE ; le jeton master est
  #    ferme au monde, donc illisible pour elle. Mesure sur banc du 2026-08-16 : l'install mourait sur
  #    `UNREACHABLE {:config, {:token_file, …, :eacces}}` — un refus de permission presente comme
  #    « pas de source installable », c'est-a-dire le mauvais diagnostic pour le mauvais probleme.
  #
  #    `system.gitea_token` est `0640 root:fleet`, donc lisible par la porte, et c'est l'identite
  #    juste : `lcars-system` est le compte avec lequel la boite lit sa forge. Un depot de catalogue
  #    est public par construction, donc ce jeton suffit — donner le site-admin a une lecture serait
  #    lui accorder un pouvoir dont elle n'a aucun usage.
  local sys_token="$PRIVATE_DIR/system.gitea_token"
  [[ -r "$sys_token" ]] \
    || die "install: $sys_token illisible — la boite n'a pas encore de jeton systeme (« provision apply » le minte)"

  local src rc=0
  src="$(FORGE_BASE_URL="$FORGE_BASE_URL" FORGE_TOKEN_FILE="$sys_token" \
         "$ENTRYPOINT" catalogue-source "$name" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "$src" >&2
    die "install: $name — pas de source installable (cf. ci-dessus)" "$rc"
  fi
  local repo branch sha
  read -r repo branch sha <<< "$src"
  echo "forge-gestures: $name <- $repo ($branch@${sha:0:8})"

  # 2. Le materiel, clone dans un jetable. Le jeton voyage par l'ENVIRON de git (extraheader),
  #    jamais dans l'URL : `/proc/<pid>/cmdline` est lisible par tout le monde, `environ` non.
  local work; work="$(mktemp -d)"
  # ⚠ `mktemp -d` REND 0700, ET LES PORTES QUI LISENT CE CLONE TOURNENT EN `nobody`. `verify` et
  # `roles-tfvars` sont des LECTURES, donc jouees en `setpriv --reuid 65534` — elles ne peuvent pas
  # traverser un repertoire que seul root ouvre. Mesure sur banc du 2026-08-16 : le verify rendait
  # « root "/tmp/tmp.XXXX/src" is not a readable directory », c'est-a-dire un refus de catalogue
  # pour un probleme de permission, sur un catalogue parfaitement valide.
  #
  # Rien de secret n'atterrit ici : le materiel d'un catalogue est public par construction, et le
  # jeton voyage par l'ENVIRON de git, jamais dans le `.git/config` du clone.
  chmod 0755 "$work"
  # shellcheck disable=SC2064 -- on veut la valeur d'ICI
  trap "rm -rf '$work'" EXIT
  GIT_TERMINAL_PROMPT=0 \
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="http.${FORGE_BASE_URL%/}.extraheader" \
  GIT_CONFIG_VALUE_0="Authorization: token $tok" \
    git clone --quiet --depth 1 --branch "$branch" "${FORGE_BASE_URL%/}/${repo}.git" "$work/src" \
    || die "install: clone de $repo impossible"

  # 3. LE MEME CONTROLE QUE LE BOOT, avant de toucher la forge. Un catalogue incoherent refuse ici
  #    coute un message ; installe, il coute un boot qui refuse ou un dispatch qui boucle, loin de
  #    sa cause.
  "$ENTRYPOINT" verify "$work/src" || die "install: $name ne passe pas la verification — RIEN n'a ete pose"

  # 4. Le roster, derive du materiel du candidat — jamais tenu a la main.
  local dir="$CATALOGUE_WORK/$name"
  mkdir -p "$dir"

  # L'ETAT DE CE CATALOGUE-CI SURVIT A LA COPIE, celui du voisin non. `cp -r` ecraserait le premier
  # avec le second : le dossier de recette de reference porte l'etat de `fleet`, et le copier par
  # dessus celui de `web-demo` revient a jeter le sien A CHAQUE passe. Le rejeu re-importerait alors
  # tout depuis zero — ca converge (l'etat est jetable par construction, chantier « tofu dedans »),
  # mais ca ne tient pas la promesse que la CLI affiche : « rien n'a bouge -> il ne touche rien ».
  local keep; keep="$(mktemp -d)"
  for f in terraform.tfstate terraform.tfstate.backup; do
    [[ -f "$dir/$f" ]] && cp "$dir/$f" "$keep/$f"
  done

  cp -r "$RECIPE_DIR/." "$dir/"

  # ⚠ L'ETAT DE TOFU NE SE COPIE PAS D'UN CATALOGUE A L'AUTRE, ET LA COPIE LE FAISAIT.
  # `cmd_apply` joue la recette DANS `$RECIPE_DIR`, donc y laisse un `terraform.tfstate` — celui du
  # catalogue de reference. Le `cp -r` ci-dessus l'emportait tel quel : mesure sur banc du
  # 2026-08-16, 26 Ko d'etat de `fleet` recopies a l'identique dans la recette de `web-demo`, et
  # l'apply partait en `Error: user not found with id 12` sur `gitea_user.role["fleet_engineer"]` —
  # un compte qui n'est dans NI le roster ni le catalogue qu'on installe.
  #
  # LE DANGER N'EST PAS L'ERREUR, C'EST CE QUI SERAIT ARRIVE SANS ELLE : un etat portant les
  # comptes de `fleet`, applique avec les variables de `web-demo`, decrit ces comptes comme « plus
  # dans la configuration ». Le plan suivant les DETRUIT. Installer un catalogue aurait desinstalle
  # le voisin.
  #
  # Partir d'un etat VIDE est le design, pas un pis-aller : la recette reconstruit ce qui existe
  # par ses blocs `import` (chantier « deploy avec tofu dedans »), donc l'etat est jetable par
  # construction. En apporter un etranger, c'est precisement lui mentir sur ce qu'il gouverne.
  rm -rf "$dir/.terraform" "$dir/instance/.terraform"
  rm -f "$dir"/terraform.tfstate* "$dir"/instance/terraform.tfstate*

  # …puis on REND a ce catalogue le sien, s'il en avait un.
  for f in terraform.tfstate terraform.tfstate.backup; do
    [[ -f "$keep/$f" ]] && mv "$keep/$f" "$dir/$f"
  done
  rmdir "$keep" 2>/dev/null || true
  # LES AVATARS DU CATALOGUE, a cote de la recette qui va les poser. Ils vivent dans l'arbre du
  # catalogue (`<catalogue>/avatars/<role>.png`) et sont nommes par le ROLE : la recette n'a donc
  # aucune table a tenir pour un catalogue tiers, le compte se derive en `<org>_<role>`.
  # Facultatif : un catalogue qui n'en livre pas laisse ses comptes en identicon, et c'est tout.
  rm -rf "$dir/catalogue-avatars"
  [[ -d "$work/src/avatars" ]] && cp -r "$work/src/avatars" "$dir/catalogue-avatars"
  "$ENTRYPOINT" roles-tfvars "$work/src" > "$dir/roles.auto.tfvars.json" \
    || die "install: roster non derive depuis $name"

  # 5. La structure : org, comptes de role, teams, adhesions, propriete, charte. LA RECETTE, pas une
  #    reecriture — `var.org` porte le nom du catalogue depuis le premier jour.
  export TF_VAR_gitea_url="$FORGE_BASE_URL" TF_VAR_gitea_token="$tok" TF_VAR_seed_password="$seed"
  # ⚠ LE DEFAUT ETAIT UN RESIDU, PAS UN CHOIX : cette ligne lisait
  # `${LCARS_FORGE_HUMAN:-${LCARS_HUMAN:-lcars}}`, et `LCARS_HUMAN` n'existe plus depuis identity-v2
  # (cf. `console.sh` : « Pas de defaut : identite-v2 a retire l'humain unique »). Le nom `lcars`
  # tombait donc d'une variable morte, pour un compte qui, lui, a une raison d'etre : le siege
  # BUILT-IN de demonstration, cible du tutoriel de promotion admin. Le defaut est desormais
  # delibere et la variable dit ce qu'elle nomme.
  export TF_VAR_builtin_human="${LCARS_BUILTIN_HUMAN:-lcars}"
  export TF_VAR_builtin_email="${LCARS_BUILTIN_EMAIL:-${TF_VAR_builtin_human}@lcars.local}"
  ( cd "$dir" && tofu init -input=false -no-color >/dev/null && tofu apply -auto-approve -input=false -no-color ) \
    || die "install: apply de la structure de $name en echec"

  # 5bis. La visibilite des comptes machine de CETTE org, dans le geste qui vient de les creer.
  #       Elle ne se faisait NULLE PART pour un catalogue : le convergeur de boot ne regardait que
  #       l'org systeme, donc `web-demo` n'avait aucun membre public (mesure du 2026-08-17).
  publicize_org_members "$name" "$tok" "$seed"

  # 6. Le STORE : la source dans l'org du catalogue. C'est LUI qui signe l'installation — une org
  #    sans sa source est un install interrompu, et aucune boite ne peut servir un catalogue dont le
  #    materiel n'est nulle part.
  push_store "$name" "$work/src" "$tok" "$sha"

  # 7. LE MATERIEL LOCAL, POSE TOUT DE SUITE. Il n'est pas l'installation — celle-ci est le depot
  #    `$name/catalogue` pousse juste au-dessus — et `45-catalogues` le reposerait de toute facon au
  #    prochain boot. Mais « au prochain boot » veut dire que la commande rend la main sur une boite
  #    qui ne sert pas encore le catalogue qu'elle vient d'installer, et l'admin n'a aucun moyen de
  #    savoir qu'il doit redemarrer. On converge donc ici le meme cache, par le meme geste.
  #
  #    Un echec ici n'annule RIEN : la forge porte l'org et la source, l'installation a eu lieu. Le
  #    dire, et laisser le boot suivant rattraper, est plus honnete que de defaire ce qui est bon.
  local materiel=1
  install_material "$name" "$work/src" && materiel=0

  # 8. LE MODELE DE PROJET DU CATALOGUE, ET IL VIENT APRES LE MATERIEL — L'ORDRE EST LE POINT.
  #    `TemplateSync` decide `<name>/project-template` ou le repli en LISANT le materiel local :
  #    un catalogue dont l'arbre `project_template` est sur le disque a le sien. Joue avant l'etape
  #    7, il ne trouvait rien et repliait TOUJOURS — mesure sur banc du 2026-08-16, l'install de
  #    `web-demo` annoncait « fleet/project-template synced » alors que le catalogue livre treize
  #    fichiers a lui. Le repli etait correct au sens du code, et faux au sens du fait.
  #
  #    Un echec ici n'annule rien : la forge porte l'org et la source. Il coute un repli sur le
  #    modele de reference, ce qui est degrade et pas casse — et ca se dit.
  if [[ "$materiel" -eq 0 ]]; then
    local tf; tf="$(umask 077; mktemp)"
    printf '%s\n' "$tok" > "$tf"
    FORGE_TOKEN_FILE="$tf" "$ENTRYPOINT" template-sync "$name" \
      || echo "forge-gestures: modele de projet de $name NON pose — ses projets partiront du modele de reference" >&2
    rm -f "$tf"
  fi

  if [[ "$materiel" -eq 0 ]]; then
    echo "forge-gestures: $name installe (org, comptes, teams, sa source dans $name/catalogue, materiel pose)"
  else
    echo "forge-gestures: $name INSTALLE sur la forge, mais le materiel local n'a pas pu etre pose" >&2
    echo "  la boite ne le servira qu'apres un redemarrage (provision apply le reconverge)" >&2
    echo "  son modele de projet n'est donc pas pose non plus : ses projets partiront du modele de reference" >&2
  fi
}

# Le CACHE local, clone depuis le store qu'on vient de pousser — jamais copie depuis `$work/src`.
# La difference n'est pas cosmetique : `45-catalogues` compare le sha local au sha du store, et un
# repertoire copie n'a pas de `.git`, donc pas de sha. Il serait re-clone au premier boot, ce qui
# marche mais fait mentir le premier `check` (« materiel absent ») sur une boite qui vient
# d'installer. Cloner depuis la meme autorite met les deux d'accord immediatement.
install_material() { # $1=catalogue  $2=arbre (non utilise : on clone l autorite)
  local name="$1" dir="${LCARS_CATALOGUES_DIR:-/home/catalogues}/$name"
  mkdir -p "$(dirname "$dir")"
  rm -rf "$dir.tmp"
  GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 \
    "${FORGE_BASE_URL%/}/${name}/catalogue.git" "$dir.tmp" || { rm -rf "$dir.tmp"; return 1; }
  rm -rf "$dir"
  mv "$dir.tmp" "$dir"
}

# Projection, pas fusion : la copie sur la forge REFLETE le depot, un commit frais a chaque fois.
# L'historique du store n'est pas porteur — celui du depot l'est, et il reste chez son proprietaire.
#
# ⚠ LA PROJECTION PORTE SA SOURCE, ET SANS CA « updatable » EST TOUJOURS VRAI. Un commit frais ne
# partage jamais son sha avec celui qu'il projette : comparer les deux tetes repond « commit
# different », ce qui est vrai par construction. Mesure sur banc du 2026-08-16 : `web-demo`,
# installe trente secondes plus tot, s'affichait « MAJ DISPO », et le seul geste offert etait de le
# reinstaller pour rien. La forge ne donne pas de hash de CONTENU exploitable non plus (mesure sur
# Gitea 1.26.1 : `/git/trees/{sha}` renvoie le sha qu'on lui passe). Le trailer est donc le lien, et
# `Fleet.Forge.Client.Repo.branch_commit/3` est ce qui le relit.
push_store() { # $1=catalogue  $2=arbre  $3=jeton  $4=sha source
  local name="$1" tree="$2" tok="$3" src_sha="${4:-}"
  local url="${FORGE_BASE_URL%/}/${name}/catalogue.git"

  printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
    | curl -sS -K - -o /dev/null -m 20 -X POST -H 'Content-Type: application/json' \
      -d "{\"name\":\"catalogue\",\"private\":false,\"auto_init\":false}" \
      "${FORGE_BASE_URL%/}/api/v1/orgs/${name}/repos" || true

  local stage; stage="$(mktemp -d)"
  cp -r "$tree/." "$stage/"
  rm -rf "$stage/.git"
  ( cd "$stage" \
    && git init -q -b main \
    && git add -A \
    && git -c user.name=lcars-system -c user.email=lcars-system@lcars.local \
         commit -q -m "chore(catalogue): projection de $name depuis son depot" \
                   -m "Source-Commit: $src_sha" \
    && GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
       GIT_CONFIG_KEY_0="http.${FORGE_BASE_URL%/}.extraheader" \
       GIT_CONFIG_VALUE_0="Authorization: token $tok" \
       git push -q --force "$url" main ) \
    || { rm -rf "$stage"; die "install: source NON poussee dans $name/catalogue — l'org est posee mais le catalogue n'est PAS installe"; }
  rm -rf "$stage"
}

# ⚠ FRONTIERE DE SOURCING — TOUT CE QUI EST AU-DESSUS EST TESTABLE, TOUT CE QUI EST DESSOUS NE
# L'EST PAS. Un temoin charge ce fichier pour appeler UNE fonction sans jouer le dispatch ; sans
# cette ligne, `case "${1:-}"` tombe sur `*)` et sort 1 des le `source`. Meme forme et meme motif que
# `human-converger.sh`.
#
# ⚠ ET LE PIEGE EST DE POSER UNE FONCTION SOUS CETTE LIGNE : elle devient invisible aux temoins,
# qui echouent alors sur « command not found » — une erreur qui accuse le test, pas le rangement.
# C'est arrive une fois sur `forge_is_admin`.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

case "${1:-}" in
  config-token) cmd_config_token ;;
  config-seed)  cmd_config_seed ;;
  apply)        with_apply_lock cmd_apply ;;
  install)      shift; with_apply_lock cmd_install "$@" ;;
  runner-token) cmd_runner_token ;;
  toolchain-protection) shift; cmd_toolchain_protection "$@" ;;
  *) echo "forge-gestures: geste requis (config-token|config-seed|apply|install|runner-token|toolchain-protection)" >&2; exit 1 ;;
esac
