#!/usr/bin/env bash
# SOURCE: fleet/services/forge-gestures.sh
# AUTHOR: drdree
# STARDATE: 2026-08-16
# STATUS: les gestes forge de la boite — poses UNE fois, joues par tout appelant
#
# ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────────────────────────
# Ces trois gestes vivaient dans la porte racine, sous forme de scripts distants passes a
# `compose exec bash -c`. Le banc ne peut PAS appeler `fleet/deploy/box` : sa boite est creee par un autre
# couple de fichiers compose (`docker-compose.install.yml` + `.bench.yml`), et `box` refuse
# — a raison — d'agir sur un projet qu'il n'a pas cree. Le banc aurait donc recopie les memes
# gestes, et deux copies d'un meme contrat derivent.
#
# Ils vivent donc DANS L'IMAGE, versionnes avec la recette qu'ils jouent. `box` et le banc
# sont alors deux facons d'entrer par la meme porte :
#     box                -> compose exec -T -u root lcars /opt/lcars/forge-gestures.sh <geste>
#     bench              -> docker exec -i -u root <box>  /opt/lcars/forge-gestures.sh <geste>
#
# ─── LES SECRETS ENTRENT PAR STDIN, JAMAIS PAR argv ─────────────────────────────────────────────
# `/proc/<pid>/cmdline` est lisible par tout le monde pendant l'appel — la lecon payee deux fois
# par 6-141 et 6-141bis, sur des credentials moins puissants que le master token. Un `--token X`
# l'aurait mis dans la ligne de commande de CE script ET dans celle du client docker.
#
# USAGE : forge-gestures.sh <geste>
#   config-token   lit un jeton master sur STDIN, le VERIFIE contre la forge de la boite, puis le
#                  pose en `0600 root:root`. Un jeton qui ne s'authentifie pas n'est PAS ecrit.
#   config-seed    lit le seed sur STDIN, meme mode (handoff tofu -> mint A4).
#   builtin-human  imprime le nom du compte integre — `forge-gestures.sh builtin-human`. Ce fichier
#                  en est l'AUTORITE (`LCARS_BUILTIN_HUMAN`, defaut plus bas) ; le verbe existe pour
#                  que ses appelants le DEMANDENT au lieu d'en recopier le defaut. Ne touche a rien.
#   apply          joue la recette : module instance/, puis module catalogue.
#                  Ne prend RIEN — il lit ce que la boite detient. Un jeton sur STDIN l'emporte.
#   toolchain-protection <login-du-siege> [admins...]
#                  GESTE D'INSTALLATION du rail toolchain : pose la protection de la branche
#                  \`sysadmin\` du depot ops (required_approvals=1, whitelist nommant le SIEGE —
#                  son login est VARIABLE, jamais en dur — dismiss_stale ; SANS status check,
#                  allumage en deux temps). Conclut par RELECTURE, et n'imprime la ligne de config
#                  :toolchain_auto_merge QUE si la protection tient — jamais l'un sans l'autre.
#   install <nom>  installe — ou MET A JOUR — le catalogue <nom> depuis le depot que la forge porte :
#                  resolution du depot, clone, MEME verification que le boot, roster derive, recette
#                  (org + comptes + teams), puis la source poussee dans <nom>/_catalogue. Jamais
#                  declenche par le boot.
#   runner-token   minte un jeton d'ENREGISTREMENT de runner et l'imprime. Sortie unique, sur
#                  stdout : c'est un credential a usage unique, il ne se pose nulle part.
#
# EXIT : 0 · 1 donnee manquante ou geste en echec · 2 la boite n'a pas de FORGE_BASE_URL (et, pour
#        `install`, aucun depot ne porte ce nom) · 3 le jeton ne s'authentifie pas (et, pour
#        `install`, DEUX depots revendiquent le nom) · 4 `install` d'un catalogue livre dans le release

set -euo pipefail

# Les chemins sont SURCHARGEABLES, comme ceux de `provision-lib.sh`, et pour la meme raison : un
# temoin doit pouvoir exercer ce script sans etre root ni ecrire dans /opt/lcars/var/tokens. Les defauts
# sont les chemins reels ; aucun appelant de production ne les passe.
PRIVATE_DIR="${LCARS_PRIVATE_DIR:-/opt/lcars/var/tokens}"
# LE COMPTE SYSTEME EN UN SEUL ENDROIT DE CE FICHIER. Son nom etait ecrit en dur dans les deux
# projections de catalogue (`git -c user.name=...`), donc le renommer demandait de les retrouver.
# Le defaut suit celui de `provision-lib.sh` et de `forge.tf` — trois recopies d'un meme nom, mais
# chacune est un DEFAUT dans un runtime different (bash de boite, bash de provisioning, HCL), pas
# une seconde autorite : l'appelant les surcharge ensemble ou pas du tout.
# Le compte integre, resolu UNE fois : le `TF_VAR_builtin_human` plus bas et le verbe
# `builtin-human` lisent celui-ci. Trois `${LCARS_BUILTIN_HUMAN:-…}` dans le meme fichier seraient
# trois autorites pour un nom, et c'est celle qu'on ne relit pas qui gagne.
#
# ⚠ VIDE PAR DEFAUT, ET C'EST LE CANON (⚖ user 2026-08-30). Il valait `lcars` : tout deploiement
# semait donc un compte humain, avec un mot de passe pose et ANNONCE. Or aucun deploiement de
# TRAVAIL ne fabrique d'humain — le rail pose les autorites (le siege, l'admin de forge, le master
# token) et les personnes s'enrolent par la page d'inscription, sous leur nom. Le commentaire
# ci-dessous le disait deja sans en tirer la consequence : « le siege BUILT-IN de DEMONSTRATION ».
#
# Qui en veut un le NOMME : `bench-forge-bootstrap.sh` pose `LCARS_BUILTIN_HUMAN` pour ses bancs,
# ou c'est du confort assume sur une machine jetable qui ne verra jamais de vraie personne.
BUILTIN_HUMAN="${LCARS_BUILTIN_HUMAN:-}"
SYSTEM_ACCOUNT="${LCARS_SYSTEM_ACCOUNT:-${PROV_SYSTEM_ACCOUNT:-system_starfleet}}"
# LE DETENTEUR DES SECRETS DE FORGE. Meme defaut que `provision-lib.sh` et que `21-service-accounts`,
# et meme raison qu'au-dessus : une recopie par runtime, surchargee ensemble ou pas du tout. C'est le
# compte que `put_secret` pose sur ce qu'il ecrit — le seul qui ouvrira ces fichiers.
AUTHORITY_USER="${LCARS_AUTHORITY_USER:-${PROV_AUTHORITY_USER:-lcars-authority}}"
# Le groupe qui TRAVERSE `/opt/lcars/var/tokens` — jamais celui qui lit. Meme defaut que partout ailleurs
# dans l'arbre, et il est ici parce que `put_secret` pose ce repertoire lui-meme : sans lui, ce geste
# et la table diraient deux choses differentes du meme objet.
FLEET_GROUP="${LCARS_FLEET_GROUP:-${PROV_FLEET_GROUP:-fleet}}"
SYSTEM_EMAIL="${LCARS_SYSTEM_EMAIL:-${SYSTEM_ACCOUNT}@lcars.local}"
# ⚠ NE FINIT PAS PAR `.gitea_token`, ET C'EST VOULU : ce suffixe est celui des jetons de ROLE
# (`<login>.gitea_token`, plus bas). Le premier lecteur qui globbera ce repertoire ne doit pas
# ramasser un site-admin.
MASTER_TOKEN_FILE="${LCARS_MASTER_TOKEN_FILE:-$PRIVATE_DIR/forge-master.token}"
SEED_FILE="${LCARS_FORGE_SEED_FILE:-$PRIVATE_DIR/forge-seed.pass}"
RECIPE_DIR="${LCARS_RECIPE_DIR:-/opt/lcars/fleet/deploy/deps}"
# Le repertoire de travail des gestes de structure. Il remonte ICI, avec les autres chemins, parce
# que le verrou d'apply y vit desormais — et une variable definie plus bas que sa premiere lecture
# ne tient que par l'ordre d'execution.
CATALOGUE_WORK="${LCARS_CATALOGUE_WORK:-/var/lib/lcars/tofu}"
# L'ADRESSE du magasin d'un catalogue installe, dans SON org. Ce fichier est ce qui l'ECRIT (le
# `push_store` plus bas), et c'est pour ca que le nom vit ici : une adresse appartient a celui qui
# pose. Rien ne se DECIDE en la lisant — l'identite d'un magasin est `manifest.name == owner`, et
# elle se tranche cote lecteurs (`CatalogueDeposits.split/2`, `45-catalogues.sh`). Le `_` initial est
# de l'UX (⚖ user, 2026-08-21) : il separe a l'oeil ce que la fleet pose de ce qu'un humain depose.
STORE_REPO="${LCARS_STORE_REPO:-_catalogue}"
# L'ENTRYPOINT porte les portes outil du release (`verify`, `roles-tfvars`, `catalogue-source`).
# Il s'appelait `TEMPLATE_SYNC` quand il n'en servait qu'une : un nom qui decrit un seul usage
# devient faux au deuxieme — et celui-la est mort deux fois, la porte `template-sync` ayant ete
# retiree avec le depot modele le 2026-08-21. Le repli sur l'ancien nom part avec elle : personne ne
# le posait (verifie sur tout le depot), donc le garder ne compatibilisait rien et faisait croire a
# un cablage.
#
# ⚠ SON DEFAUT ETAIT `/opt/lcars/entrypoint.sh`, UN CHEMIN D'IMAGE, DANS LE SCRIPT DONT LE MIROIR DES
# AUXILIAIRES AFFIRME QU'IL « n'a jamais eu la moindre hypothese de conteneur ». Il en avait une,
# gelee dans ce defaut. `62-runtime-helpers` pose ce fichier-ci a plat dans `/opt/lcars/` et EXCLUT
# `entrypoint.sh` au motif qu'« il n'a pas de sens hors conteneur » : vrai de son metier de BOOT,
# faux de son metier de PORTES OUTIL. Mesure du 2026-08-22 sur un poste :
# `lcars catalogue install web-demo` mourait en « /opt/lcars/entrypoint.sh: No such file or
# directory », rendu a l'operateur comme « pas de source installable » — un fichier absent presente
# comme un catalogue introuvable.
#
# IL N'Y A RIEN A COPIER, ET C'EST LE POINT. L'arbre `deploy/` est DEJA pose (`EMBEDDED=(deploy etc)`
# du meme module), donc le fichier est la, sous un autre chemin. On le cherche depuis ICI, dans les
# deux dispositions ou ce script peut vivre : a cote de lui (image, ou arbre embarque) puis sous
# l'arbre embarque (copie a plat). Une troisieme copie du meme fichier serait la mauvaise reponse a
# une absence qui n'en est pas une.
#
# ⚠ `-r` ET PAS `-x`, ET `bash` PLUTOT QUE L'EXECUTION DIRECTE. `entrypoint.sh` est `100644` dans le
# depot ; seule l'image le passe en `0755` (`RUN chmod 0755`). Le `cp -a` de l'arbre embarque preserve
# donc un mode NON executable, et un test sur `-x` echouerait APRES avoir trouve le bon chemin — un
# garde qui rejette exactement ce qu'il cherchait.
_entrypoint_path() {
  local here c
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for c in "$here/entrypoint.sh" "$here/fleet/deploy/docker/entrypoint.sh"; do
    [[ -r "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  # Aucun candidat lisible : on rend le premier quand meme, pour qu'un refus NOMME un chemin. Le
  # garde qui tranche est `need_entrypoint`, a la porte du geste qui en depend.
  printf '%s' "$here/entrypoint.sh"
}
ENTRYPOINT="${LCARS_ENTRYPOINT:-$(_entrypoint_path)}"

# LE GARDE, A LA PORTE ET PAS AU MILIEU DU PIPELINE. Sans lui, l'absence se manifestait quatre
# etapes plus loin, traduite en « pas de source installable » : le refus accusait la forge d'un
# manque qui etait celui de la boite.
need_entrypoint() {
  [[ -r "$ENTRYPOINT" ]] && return 0
  die "portes outil du release introuvables ($ENTRYPOINT).
  Ce script les appelle pour resoudre, verifier et enroler un catalogue. Sur un poste elles vivent
  dans l'arbre embarque (<prefixe>/fleet/deploy/docker/entrypoint.sh), pose par « provision apply ».
  « LCARS_ENTRYPOINT=<chemin> » force la resolution."
}

die() { echo "forge-gestures: $*" >&2; exit "${2:-1}"; }

need_forge_url() {
  [[ -n "${FORGE_BASE_URL:-}" ]] || {
    echo "forge-gestures: cette boite n'a pas de FORGE_BASE_URL — un jeton sans forge ne veut rien dire." >&2
    echo "                FORGE_BASE_URL=<url> fleet/deploy/box up, puis rejoue." >&2
    exit 2; }
}

# La config de curl est un format cite : la valeur est ECHAPPEE, pas esperee propre. Meme geste
# que `provision-forge-charte.sh` et `forge-existing.sh`.
curl_cfg_escape() { local v="$1"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s' "$v"; }

# Ecriture ATOMIQUE dans le repertoire cible (rename garanti par le noyau sur le meme systeme de
# fichiers) : un appel interrompu ne laisse jamais un demi-secret que le lecteur suivant prendrait
# pour le vrai.
put_secret() { # $1=chemin  $2=valeur
  # `chown`/`-o` ne sont tentes QUE si on est root. Tout appelant reel l'est (`docker exec
  # -u root`), et un temoin ne l'est pas : conditionner ici evite une garde `|| true` qui
  # avalerait un vrai echec de propriete sur une boite.
  #
  # ⚠ LE REPERTOIRE COMPTE AUTANT QUE LES FICHIERS. Il naissait ici `0750 root:fleet` : fermer les
  # secrets sans fermer leur repertoire ne fermait rien, parce que CE geste-ci le rouvrait au premier
  # passage. Le groupe `fleet` etait une projection de l'equipe `humans` de la forge, refaite toutes
  # les 30 s — donc une ACL a peremption de cache sur les deux secrets les plus puissants de la boite.
  #
  # ⚠ ET CE MEME GESTE A FAILLI REFERMER CE QUE LA TABLE OUVRE, DANS L'AUTRE SENS. Une premiere
  # ecriture posait `0700 $AUTHORITY_USER:$AUTHORITY_USER` ici pendant que `system.manifest` et
  # `25-directories` disaient `0710 …:fleet`. Le premier `put_secret` aurait REFERME le repertoire,
  # en silence, et les trois modules `NEEDS: human` — qui lisent `forge.url` sous l'uid de l'humain —
  # auraient recasse. Le gate ne peut pas voir ca : il n'execute pas ce geste contre une vraie table.
  #
  # LA REGLE, LA MEME DANS LES QUATRE POSEURS DE CE REPERTOIRE : le groupe TRAVERSE (`x`), il ne LIT
  # jamais (`r`). Ce repertoire ne contient pas que des secrets — `forge.url` et `forge.public.url`
  # y sont en 0644, et ce sont des adresses. Les secrets, eux, restent `0600` : c'est le MODE DU
  # FICHIER qui les ferme, plus celui du repertoire.
  if [[ "$(id -u)" -eq 0 ]]; then
    install -d -m 0710 -o "$AUTHORITY_USER" -g "$FLEET_GROUP" "$PRIVATE_DIR"
  else
    install -d -m 0710 "$PRIVATE_DIR"
  fi
  local tmp
  tmp="${1%/*}/.$(basename "$1").tmp"   # SC2155 : `local` masquerait le statut de `basename`
  umask 077
  printf '%s\n' "$2" > "$tmp"

  # ⚠ `0600`, SANS BRANCHE SUR LE MODE. Ce mode a ete un GATE : quand le geste tournait sous l'uid
  # de l'humain, DETENIR le jeton etait la preuve du droit, donc il fallait l'ouvrir a un groupe qui
  # portait `is_admin`. Le geste vit maintenant dans un service qui pose la question a la forge a
  # l'instant ou elle compte — plus personne n'a besoin de lire ce fichier.
  #
  # Une branche de moins, et c'est le point : un mode qui depend de l'identite de l'ecrivain donne
  # deux etats possibles au meme secret, et c'est celui qu'on n'a pas relu qui gagne.
  #
  # ⚠ LE PROPRIETAIRE ETAIT `root:root`, ET C'ETAIT UN DEFAUT VIVANT. Ce service N'EST PLUS ROOT
  # depuis que le detenteur des secrets a perdu tout privilege noyau. Un appelant root qui minte
  # par ici posait donc un jeton master que le service ne peut PAS ouvrir — et il refuse de demarrer
  # sans lui. Dans un `provision apply` complet, `converge_authority_modes` (50-forge) reparait au
  # module suivant ; appele seul — le verbe `forge-apply` de l'entrypoint, ou `48-forge-host` sur le
  # rail poste — rien ne reparait, et la boite se retrouve avec un secret qu'elle a mais ne lit pas.
  #
  # ⚠ UN `if`, PAS `[[ ]] && cmd`. Mesure : un AND-list dont le test est faux rend 1 ; c'est sans
  # effet au milieu d'une fonction, mais MORTEL sous `set -e` s'il en devient la derniere
  # instruction — la fonction rend 1 et l'appelant meurt sans un mot. Ce depot a deja paye ce piege
  # (le `return 0` OBLIGATOIRE de `converge_authority_modes`). On n'ecrit pas une ligne dont la
  # surete depend de ce qui la suit.
  chmod 0600 "$tmp"
  if [[ "$(id -u)" -eq 0 ]]; then
    chown "$AUTHORITY_USER:$AUTHORITY_USER" "$tmp"
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
  echo "forge-gestures: jeton master pose et VERIFIE ($MASTER_TOKEN_FILE, $AUTHORITY_USER seul)"
}

cmd_config_seed() {
  local seed; seed="$(read_stdin_secret)"
  [[ -n "$seed" ]] || die "seed vide sur stdin"
  put_secret "$SEED_FILE" "$seed"
  echo "forge-gestures: seed pose ($SEED_FILE, $AUTHORITY_USER seul)"
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
# ⚠ IL N'Y A PLUS QU'UNE SEULE IDENTITE DE CHAQUE COTE DE CE VERROU, ET C'EST CE QUI LE SIMPLIFIE.
# Il a fallu le partager entre DEUX : root au boot et l'humain admin ensuite. Il vivait dans
# `/run/lock` (1777), donc root le creait en `0644 root:root` et l'humain qui jouait
# `lcars catalogue install` ouvrait en ecriture un fichier qui ne lui appartenait pas — mesure du
# 2026-08-18, sur deux bancs : « Permission denied », puis « verrou d'apply inouvrable », un refus
# qui accuse le verrou pour un probleme de proprietaire. Le geste etait injouable par un humain sur
# toute boite ayant demarre une fois. Le partage par setgid + `umask 007` a ferme ce defaut.
#
# Les deux appelants sont ROOT desormais : le boot, et `catalogue-executor.py`. Le partage entre
# deux identites n'a plus d'objet — mais on ne DURCIT pas le verrou pour autant, parce qu'un verrou
# est un rendez-vous, pas un secret : le resserrer n'ajoute aucune garde et casserait toute boite
# migree dont le fichier existe deja.
with_apply_lock() {
  local lock="${LCARS_APPLY_LOCK:-$CATALOGUE_WORK/.apply.lock}"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  [[ -e "$lock" ]] || ( : > "$lock" ) 2>/dev/null || true
  exec 9>"$lock" || die "verrou d'apply inouvrable ($lock) — regarde son proprietaire et son mode : ce geste tourne en root, donc un refus ici designe un montage ou un systeme de fichiers en lecture seule, pas une permission"
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
# ─── ensure_ops_repo — LE DEPOT DU SYSADMIN, QUE PERSONNE NE CREAIT ─────────────────────────────
#
# ⚠ IL ETAIT LU PAR TROIS DOMAINES ET CREE PAR AUCUN. `Fleet.Toolchain.ops_repo/0`,
# `IncidentRegistry.Escalation` et `pod_tools/delegation.ex` visent tous `fleet/lcars` ; le seul
# `create_repo` du runtime sert aux depots de PROJET. La recette tofu, elle, ne cree aucun depot —
# elle fait les orgs, les comptes, les teams.
#
# CE QUE LE TROU COUTAIT. `52-ops-branch` derive a chaque passage, sur les deux substrats, avec un
# message qui accuse « l'amorcage de la forge » — une affirmation sur un AUTRE artefact, et elle
# etait fausse. Et le 2026-08-22 il a fait pire : un 404 sur ce depot a ete lu comme une panne de
# l'IncidentRegistry, et diagnostique deux fois de travers avant qu'on regarde le depot lui-meme.
#
# ⚠ POURQUOI ICI ET PAS DANS LA RECETTE. La structure de forge est le territoire de tofu, mais tofu
# ne cree AUCUN depot dans ce depot-ci : les depots de catalogue sont pousses par ce fichier, en
# POST + git (`push_store`). Ce geste reprend exactement ce mecanisme, au meme endroit, dans la
# meme passe. Le jour ou la recette gagnera une ressource `gitea_repository`, ce geste devra
# demenager avec les autres — pas avant.
#
# `auto_init` VRAI : un depot vide n'a pas de branche, et `52-ops-branch` pousse SUR une branche.
# Sans branche par defaut, la forge repond « Push to create is not enabled for organizations » —
# un message qui parle d'un reglage alors que le fait est « il n'y a rien ou pousser ».
ensure_ops_repo() { # $1=org  $2=jeton master
  local org="$1" tok="$2"
  # ⚠ DEUX LIGNES, ET CE N'EST PAS DU STYLE. `local a=… b="${a#…}"` NE VOIT PAS `a` : bash expanse
  # toute la ligne AVANT d'assigner, donc `$a` y est encore inconnu — et sous `set -u` c'est un
  # « unbound variable » qui tue le script au milieu d'un apply. Mesure du 2026-08-22 : douze
  # temoins rouges d'un coup, et l'erreur pointait une ligne qui avait l'air juste.
  local repo="${LCARS_OPS_REPO:-$org/lcars}"
  local name="${repo#*/}"

  local code
  code="$(printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
    | curl -sS -K - -o /dev/null -w '%{http_code}' -m 15 \
      "${FORGE_BASE_URL%/}/api/v1/repos/$repo" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    echo "forge-gestures: depot ops $repo deja la"
    return 0
  fi

  # ⚠ LA RELECTURE FAIT FOI, PAS LE CODE DU POST. Meme regle que la protection de branche plus bas :
  # une v1 concluait « deja present » sur un 409/422 alors que Gitea rend d'autres codes selon la
  # version. On POST au mieux, puis on REDEMANDE.
  printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
    | curl -sS -K - -o /dev/null -m 20 -X POST -H 'Content-Type: application/json' \
      -d "{\"name\":\"${name}\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\",\"description\":\"Depot du sysadmin : escalades, demandes d'outillage, registre d'incidents.\"}" \
      "${FORGE_BASE_URL%/}/api/v1/orgs/${org}/repos" 2>/dev/null || true

  code="$(printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
    | curl -sS -K - -o /dev/null -w '%{http_code}' -m 15 \
      "${FORGE_BASE_URL%/}/api/v1/repos/$repo" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    echo "forge-gestures: depot ops $repo cree (auto_init, branche main)"
  else
    # NON FATAL, ET C'EST DELIBERE : une forge sans depot ops reste une forge. `52-ops-branch` le
    # dira en derive au passage suivant — ce qui est exactement son travail.
    echo "forge-gestures: depot ops $repo NON cree (HTTP $code) — 52-ops-branch le dira en derive" >&2
  fi
  return 0
}

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

# ─── LE CREATEUR DE L'ORG N'EN EST PAS LE PROPRIETAIRE ──────────────────────────────────────────
# Gitea fait de qui cree une org un membre de son equipe `Owners`. La recette n'a jamais declare ca :
# `forge.tf` ne nomme QU'UN owner, le compte systeme. Le master s'y retrouvait donc par effet de
# bord — parce que c'est SON jeton que tofu porte — et une liste de proprietaires qui nomme
# quelqu'un qui n'a fait que creer ment sur qui tient l'org.
#
# ⚠ CE N'EST PAS UNE QUESTION DE POUVOIR, C'EST UNE QUESTION DE CE QUE LA LISTE DIT. Le master est
# site-admin : il passe outre toutes les permissions de team, avant comme apres. Mesure du
# 2026-08-20 sur banc neuf : apres le retrait, le compte systeme lit toujours les membres d'une team
# (200 — la capacite qui exigeait la propriete, il l'a parce que c'est LUI l'owner), et le master
# atteint toujours l'org avec un jeton sans droit d'org. Rien ne se degrade, la liste cesse de mentir.
#
# L'ORDRE EST LE GESTE : on RELIT la liste et on confirme que le compte systeme y est AVANT de
# retirer le master. Jamais l'inverse, jamais sans la relecture — sinon une passe ou tofu n'a pas
# encore pose l'adhesion laisserait une org sans proprietaire. C'est la meme discipline que
# `toolchain-protection` : la relecture fait foi, pas l'ordre suppose des gestes.
demote_creator_from_owners() { # $1=org  $2=jeton master
  local org="$1" tok="$2" api="${FORGE_BASE_URL%/}/api/v1" tid owners
  tid="$(curl -sS -m 15 -H "Authorization: token $tok" "$api/orgs/$org/teams" 2>/dev/null \
        | python3 -c 'import json,sys;print(next((t["id"] for t in json.load(sys.stdin) if t["name"]=="Owners"),""))' 2>/dev/null || true)"
  [[ -n "$tid" ]] || { echo "forge-gestures: equipe Owners de $org introuvable — le master y reste (rien n'est retire a l'aveugle)" >&2; return 0; }

  owners="$(curl -sS -m 15 -H "Authorization: token $tok" "$api/teams/$tid/members" 2>/dev/null \
           | python3 -c 'import json,sys;print(" ".join(m["login"] for m in json.load(sys.stdin)))' 2>/dev/null || true)"

  # LA PRECONDITION, ET ELLE EST LUE, PAS SUPPOSEE : sans le compte systeme dans la liste, on ne
  # retire rien. Une org sans proprietaire est irreparable sans site-admin.
  [[ " $owners " == *" $SYSTEM_ACCOUNT "* ]] || {
    echo "forge-gestures: $SYSTEM_ACCOUNT n'est PAS owner de $org (vu: ${owners:-aucun}) — le master y reste" >&2
    return 0; }

  # Le master est celui dont ce jeton est l'autorite : on le demande a la forge plutot que de le
  # deviner, son login etant variable (l'installeur en prod, `admiral` au banc).
  local master
  master="$(curl -sS -m 15 -H "Authorization: token $tok" "$api/user" 2>/dev/null \
           | python3 -c 'import json,sys;print(json.load(sys.stdin).get("login",""))' 2>/dev/null || true)"
  [[ -n "$master" ]] || return 0
  [[ " $owners " == *" $master "* ]] || return 0   # deja retire : rien a dire

  if curl -sS -m 15 -o /dev/null -w '%{http_code}' -H "Authorization: token $tok" \
       -X DELETE "$api/teams/$tid/members/$master" 2>/dev/null | grep -q '^204$'; then
    echo "forge-gestures: $master retire des Owners de $org — il l'etait par creation, pas par decision ($SYSTEM_ACCOUNT reste proprietaire ; le site-admin est intact)"
  else
    echo "forge-gestures: retrait de $master des Owners de $org REFUSE — la liste garde son proprietaire de creation" >&2
  fi
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
  [[ -n "${FORGE_BASE_URL:-}" ]] || manque="$manque\n  l'URL de la forge   -> FORGE_BASE_URL=<url> fleet/deploy/box up"
  [[ -n "$tok" ]]                || manque="$manque\n  l'autorite          -> FORGE_ADMIN_TOKEN=<token master> fleet/deploy/box config"
  [[ -n "$seed" ]]               || manque="$manque\n  le seed des comptes -> FORGE_SEED_PASSWORD=<mot de passe> fleet/deploy/box config"
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
  export TF_VAR_builtin_human="$BUILTIN_HUMAN"
  # Sans compte de demonstration, pas d'adresse a lui donner : la deriver rendrait « @lcars.local ».
  export TF_VAR_builtin_email="${LCARS_BUILTIN_EMAIL:-${TF_VAR_builtin_human:+${TF_VAR_builtin_human}@lcars.local}}"

  # L'ORDRE EST UN INVARIANT, pas une preference : `instance/` porte les comptes partages, et une
  # adhesion peut nommer un compte qu'elle ne cree pas, jamais un compte qui n'existe pas.
  local m
  for m in instance .; do
    echo "forge-gestures: apply $m"
    ( cd "$RECIPE_DIR/$m" && tofu apply -auto-approve -input=false -no-color ) \
      || die "apply $m en echec — rien n'est suppose, relis la sortie ci-dessus"
  done

  # La visibilite des comptes machine de l'org systeme, DANS LE GESTE QUI VIENT DE LES CREER.
  ensure_ops_repo "${PROV_FORGE_ORG:-fleet}" "$tok"

  publicize_org_members "${PROV_FORGE_ORG:-fleet}" "$tok" "$seed"

  demote_creator_from_owners "${PROV_FORGE_ORG:-fleet}" "$tok"

  seed_catalogue_deposit "$tok" "$(reference_catalogue_root)" "catalogue de reference"
  seed_catalogue_deposit "$tok" "$DEMO_CATALOGUE" "catalogue de demonstration"
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

# ─── LA REFERENCE, DEPOSEE AU MEME ENDROIT ──────────────────────────────────────────────────────
# ⚖ user, 2026-08-21 : « il FAUT garder le catalogue dispo et visible sur la forge », « il faut
# republier le catalogue de base `fleet` ».
#
# Le catalogue metier de reference vit DANS LE RELEASE, pas dans `catalogues/` : il est installe par
# construction et n'a jamais eu besoin d'etre sur la forge pour tourner. Ce qu'il gagne a y etre est
# la LISIBILITE — on ne forke pas ce qu'on ne peut pas ouvrir, et faire son propre catalogue commence
# par lire celui qui marche.
#
# ⚠ IL NE DEVIENT PAS INSTALLABLE POUR AUTANT, et la liste le sait : `CatalogueDeposits` ecarte toute
# candidature portant le nom du catalogue livre. Sans cette clause, ce depot serait un candidat de
# plus sous ce nom — et le premier fork qui garde son manifeste tel quel en ferait deux, donc
# `catalogue list` refusant la liste ENTIERE. Publier un objet fait pour etre forke ne doit pas armer
# la casse au premier fork.
#
# LE CHEMIN SE DEMANDE AU RELEASE (`$ENTRYPOINT catalogue-root`) et ne se recompose pas : il porte la
# VERSION du release, donc tout glob ecrit ici marcherait jusqu'a la premiere reorganisation, puis
# echouerait en silence sur un glob vide.
REFERENCE_CATALOGUE="${LCARS_REFERENCE_CATALOGUE:-}"

reference_catalogue_root() {
  [[ -n "$REFERENCE_CATALOGUE" ]] && { printf '%s' "$REFERENCE_CATALOGUE"; return 0; }

  local root
  root="$(bash "$ENTRYPOINT" catalogue-root 2>/dev/null | tail -n1)" || root=""
  if [[ -z "$root" || ! -d "$root" ]]; then
    # Un refus MUET ferait croire a une image sans reference — or elle en porte toujours une.
    echo "forge-gestures: le release ne dit pas ou vit son catalogue de reference — NON depose" >&2
    return 0
  fi
  printf '%s' "$root"
}

# ─── LE GESTE, POUR LES DEUX ────────────────────────────────────────────────────────────────────
# Il etait ecrit pour la demo seule, et la reference l'a rejoint le 2026-08-21. Le PARAMETRER plutot
# que le recopier n'est pas un gout : les deux depots ont exactement la meme semantique — projection
# force-poussee chez `id = 1`, non fatale — et deux copies d'un meme geste divergent par la ligne
# qu'on corrige d'un cote.
#
# LE NOM VIENT DU MANIFESTE, jamais du repertoire. Un arbre range sous `catalogues/web-demo` qui
# declarerait `name: autre` serait pousse sous `web-demo` et n'apparaitrait JAMAIS dans
# `catalogue list`, qui indexe par identite declaree. Meme regle qu'a l'install, meme colonne zero.
seed_catalogue_deposit() { # $1=jeton master  $2=arbre  $3=quoi (pour le message)
  local tok="$1" tree="$2" kind="$3"
  [[ -d "$tree" ]] || return 0

  local name
  name="$(awk '/^name:/ { sub(/^name:[ \t]*/, ""); sub(/[ \t]*#.*$/, ""); gsub(/"/, "");
                          sub(/[ \t]+$/, ""); if ($0 != "") { print; exit } }' \
          "$tree/catalogue.yaml" 2>/dev/null || true)"
  if [[ -z "$name" ]]; then
    echo "forge-gestures: $tree ne declare pas de \`name:\` en colonne zero — $kind NON depose" >&2
    return 0
  fi

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

  echo "forge-gestures: $kind ($name -> $master/$name)"
  printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
    | curl -sS -K - -o /dev/null -m 20 -X POST -H 'Content-Type: application/json' \
      -d "{\"name\":\"$name\",\"private\":false,\"auto_init\":false}" \
      "${FORGE_BASE_URL%/}/api/v1/user/repos" 2>/dev/null || true

  # ⚠ `cp` PEUT ECHOUER, ET `set -e` TUE ALORS LE SCRIPT AVANT LE `rm -rf` DE FIN. Source illisible,
  # disque plein : le repertoire temporaire fuit. Le nettoyer sur place vaut mieux qu'un `trap`, qui
  # est global au processus et ecraserait celui qu'un autre geste aurait pose.
  local stage; stage="$(mktemp -d)"
  cp -r "$tree/." "$stage/" || {
    rm -rf "$stage"
    echo "forge-gestures: $tree illisible — $name NON depose" >&2
    return 0
  }
  rm -rf "$stage/.git"
  ( cd "$stage" \
    && git init -q -b main \
    && git add -A \
    && git -c "user.name=$SYSTEM_ACCOUNT" -c "user.email=$SYSTEM_EMAIL" \
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
# Pose la protection de la branche `tool_request` du depot ops : `required_approvals=1` + whitelist
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
  [[ -n "$tok" ]] || die "pas d'autorite — « FORGE_ADMIN_TOKEN=<token master> fleet/deploy/box config »"

  # LE NOM EST GELE, ET SON AUTORITE EST `Fleet.Toolchain.branch/0` — cette ligne en est une
  # RECOPIE, tenue par le contrat `toolchain.branch_single_source`. Il a ete reglable a moitie (une
  # variable ici, une clef d'app-env dans le BEAM, aucun pont) : la tourner posait la protection sur
  # une branche pendant que le reconciliateur en interrogeait une autre.
  local repo="${LCARS_OPS_REPO:-fleet/lcars}" branch="tool_request"
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
  [[ -n "$tok" ]] || die "pas d'autorite — « FORGE_ADMIN_TOKEN=<token master> fleet/deploy/box config »"

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
# ⚠ CE FICHIER NE GATE PLUS RIEN, ET IL NE DOIT PAS ESSAYER. L'autorisation est prise EN AMONT, par
# `catalogue-executor.py` : il lit l'uid du pair que le noyau pose sur sa socket, demande a la forge
# si ce login y porte `is_admin`, et n'appelle ce geste que si la reponse est oui. Ce script est donc
# appele par un service, jamais par un humain.
#
# ⚠ ET CE SERVICE N'EST PLUS ROOT. La ligne d'avant disait « tourne donc toujours en root » ; c'est
# faux depuis que le detenteur des secrets a perdu tout privilege noyau. Il tourne sous
# `lcars-authority` — assez pour ouvrir les secrets qu'il possede, pas assez pour quoi que ce soit
# d'autre. La consequence pratique est plus bas, dans `cmd_install` : les portes qui tombent en
# `nobody` ne peuvent plus lire les fichiers de `/opt/lcars/var/tokens`, donc ce qu'on leur passe est une
# VALEUR, plus un chemin.
#
# Le mode du jeton a ete le gate — « la capacite EST la permission » — et c'est precisement ce qui
# imposait un groupe unix, sa projection depuis `is_admin`, son cache et son rattrapage de derive.
# Un second gate ici serait une seconde verite sur la meme question.
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
  need_entrypoint

  local tok; tok="$(cat "$MASTER_TOKEN_FILE" 2>/dev/null || true)"
  [[ -n "$tok" ]] || die "install: pas d'autorite — « FORGE_ADMIN_TOKEN=<token master> fleet/deploy/box config »"
  local seed; seed="$(cat "$SEED_FILE" 2>/dev/null || true)"
  [[ -n "$seed" ]] || die "install: pas de seed — « FORGE_SEED_PASSWORD=<mot de passe> fleet/deploy/box config »"

  # 1. QUI porte ce catalogue. La porte refuse l'absent, le doublon et le catalogue livre, chacun
  #    avec son code — on ne traduit pas, on relaie.
  #    ⚠ PAS LE JETON MASTER, ET CE N'EST PAS UNE PREFERENCE. La porte tourne en `nobody:fleet`
  #    (`setpriv --reuid 65534 --regid 2000`) parce que c'est une LECTURE ; le jeton master est
  #    ferme au monde, donc illisible pour elle. Mesure sur banc du 2026-08-16 : l'install mourait sur
  #    `UNREACHABLE {:config, {:token_file, …, :eacces}}` — un refus de permission presente comme
  #    « pas de source installable », c'est-a-dire le mauvais diagnostic pour le mauvais probleme.
  #
  #    `$SYSTEM_ACCOUNT` (defaut `system_starfleet`) est l'identite juste : c'est le compte avec
  #    lequel la boite LIT sa forge. Un depot de catalogue est public par construction, donc ce jeton
  #    suffit — donner le site-admin a une lecture serait lui accorder un pouvoir dont elle n'a aucun
  #    usage.
  #
  # ⚠ ON PASSE LA VALEUR, PLUS LE CHEMIN, ET C'EST UNE CASSE EVITEE DE JUSTESSE. Ce geste donnait
  # `FORGE_TOKEN_FILE=<chemin>` a une porte qui tombe en `nobody:fleet` : ca ne marchait QUE parce
  # que le fichier etait `0640 root:fleet`. En `0600 lcars-authority` — l'etat que ce chantier pose —
  # la porte ne peut plus l'ouvrir, et `catalogue install` mourrait sur un `:eacces` presente comme
  # « pas de source installable ». Exactement le mauvais diagnostic que les six lignes au-dessus
  # racontent avoir deja paye une fois, sur ce meme fichier, pour le jeton master.
  #
  # CE PROCESS, LUI, PEUT LIRE : il EST le service d'autorite. Il lit et transmet la VALEUR par
  # l'environnement — `/proc/<pid>/environ` n'est lisible que par le proprietaire du process et par
  # root, alors qu'un argv est lisible par tout le monde. Meme canal, et meme raison, que
  # `ForgeAuth.git_env` cote BEAM.
  local sys_token="$PRIVATE_DIR/$SYSTEM_ACCOUNT.gitea_token"
  [[ -r "$sys_token" ]] \
    || die "install: $sys_token illisible — la boite n'a pas encore de jeton systeme (« provision apply » le minte)"
  local sys_tok_value; sys_tok_value="$(tr -d '[:space:]' < "$sys_token")"
  [[ -n "$sys_tok_value" ]] \
    || die "install: $sys_token est VIDE — un jeton vide part en 401, et la forge accuserait la source"

  local src rc=0
  src="$(FORGE_BASE_URL="$FORGE_BASE_URL" FORGE_TOKEN="$sys_tok_value" \
         bash "$ENTRYPOINT" catalogue-source "$name" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "$src" >&2
    die "install: $name — pas de source installable (cf. ci-dessus)" "$rc"
  fi
  local repo branch sha
  read -r repo branch sha <<< "$src"

  # ⚠ UN CODE DE SORTIE 0 N'EST PAS UNE REPONSE, et ce geste le tenait pour tel. La porte annonce
  # `<depot> <branche> <sha>` sur stdout ; aucune branche de `eval_source/1` ne rend 0 sans imprimer.
  # Un 0 muet ne vient donc PAS d'elle — il vient de ce qui a repondu a sa place, et c'est justement
  # ce qu'il faut nommer.
  #
  # MESURE DU 2026-08-23 sur un poste : `catalogue install web-demo` a affiche
  # « web-demo <-  (@) » puis « fatal: repository 'http://127.0.0.1:21000/.git/' not found », et
  # enfin « clone de  impossible ». Trois messages, aucun ne nomme le vrai manque : les trois champs
  # etaient VIDES et le geste a construit une URL a partir de rien, l'a donnee a git, et a rapporte
  # l'echec de git. Un refus qui cite l'erreur d'un outil auquel on a passe du vide accuse l'outil.
  #
  # ON VALIDE LA FORME, pas seulement la presence : `branch` et `sha` manquants produisent un clone
  # sur une reference vide, qui echoue plus loin et pour une autre raison apparente.
  if [[ -z "$repo" || -z "$branch" || -z "$sha" ]]; then
    printf '%s\n' "$src" >&2
    die "install: $name — la porte de resolution a rendu 0 sans reponse exploitable.
  Attendu sur stdout : « <owner>/<depot> <branche> <sha> ». Recu : $(
    [[ -z "$src" ]] && printf 'RIEN' || printf '%s' "«$src»")
  Ce n'est pas un refus de la forge : un refus porte un code de sortie et une phrase. Un zero muet
  vient de ce qui a repondu A LA PLACE de la porte — verifier ce que « \$ENTRYPOINT » designe
  ($ENTRYPOINT) et ce que « bash \"\$ENTRYPOINT\" catalogue-source $name » imprime a la main."
  fi

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
  # SC2064 : on veut la valeur d'ICI, pas celle du moment ou le trap se declenche.
  # shellcheck disable=SC2064
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
  bash "$ENTRYPOINT" verify "$work/src" || die "install: $name ne passe pas la verification — RIEN n'a ete pose"

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
  bash "$ENTRYPOINT" roles-tfvars "$work/src" > "$dir/roles.auto.tfvars.json" \
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
  export TF_VAR_builtin_human="$BUILTIN_HUMAN"
  # Sans compte de demonstration, pas d'adresse a lui donner : la deriver rendrait « @lcars.local ».
  export TF_VAR_builtin_email="${LCARS_BUILTIN_EMAIL:-${TF_VAR_builtin_human:+${TF_VAR_builtin_human}@lcars.local}}"
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
  #    `$name/$STORE_REPO` pousse juste au-dessus — et `45-catalogues` le reposerait de toute facon au
  #    prochain boot. Mais « au prochain boot » veut dire que la commande rend la main sur une boite
  #    qui ne sert pas encore le catalogue qu'elle vient d'installer, et l'admin n'a aucun moyen de
  #    savoir qu'il doit redemarrer. On converge donc ici le meme cache, par le meme geste.
  #
  #    Un echec ici n'annule RIEN : la forge porte l'org et la source, l'installation a eu lieu. Le
  #    dire, et laisser le boot suivant rattraper, est plus honnete que de defaire ce qui est bon.
  #
  #    ⚠ CE MATERIEL EST AUSSI LE SQUELETTE DES PROJETS DE CE CATALOGUE. `Scaffold.template_root/1`
  #    lit `project_template/` SOUS CE REPERTOIRE ; absent, il se replie sur le catalogue livre. Un
  #    catalogue qui livre son propre arbre et dont le materiel n'est pas pose voit donc ses projets
  #    naitre du squelette d'un voisin — c'est ce que le message d'echec ci-dessous doit dire.
  local materiel=1
  install_material "$name" "$work/src" && materiel=0

  if [[ "$materiel" -eq 0 ]]; then
    echo "forge-gestures: $name installe (org, comptes, teams, sa source dans $name/$STORE_REPO, materiel pose)"
  else
    echo "forge-gestures: $name INSTALLE sur la forge, mais le materiel local n'a pas pu etre pose" >&2
    echo "  la boite ne le servira qu'apres un redemarrage (provision apply le reconverge)" >&2
    echo "  son squelette de projet n'est donc pas lisible : ses projets naitront de celui du catalogue livre" >&2
  fi
}

# Le CACHE local, clone depuis le store qu'on vient de pousser — jamais copie depuis `$work/src`.
# La difference n'est pas cosmetique : `45-catalogues` compare le sha local au sha du store, et un
# repertoire copie n'a pas de `.git`, donc pas de sha. Il serait re-clone au premier boot, ce qui
# marche mais fait mentir le premier `check` (« materiel absent ») sur une boite qui vient
# d'installer. Cloner depuis la meme autorite met les deux d'accord immediatement.
# ⚠ DEUX `local`, ET LE PREMIER JET N'EN AVAIT QU'UN. `local name="$1" dir=".../$name"` : bash
# expanse TOUS les arguments du builtin AVANT de l'executer, donc ce `$name` n'est pas celui qu'on
# vient d'ecrire. Mesure : `f(){ local a="$1" b="/base/$a"; }` rend `b=/base/`.
#
# Ca marchait — par PORTEE DYNAMIQUE : l'appelant `cmd_install` a un `local name` qui porte deja la
# meme valeur, et c'est lui que l'expansion trouvait. La ligne etait donc correcte tant que son
# appelant gardait ce nom de variable. Renommer un local dans `cmd_install` — un refactor sans
# aucune intention de changer quoi que ce soit — rendait `$name` VIDE, donc `dir` egal a la racine
# des catalogues, et le `rm -rf "$dir"` de trois lignes plus bas emportait TOUS les catalogues.
#
# Le defaut etait invisible : une directive `disable=SC2064 -- raison` malformee (le `--` n'est pas
# une syntaxe shellcheck) faisait ABANDONNER l'analyse du fichier entier.
install_material() { # $1=catalogue  $2=arbre (non utilise : on clone l autorite)
  local name="$1"
  local dir="${LCARS_CATALOGUES_DIR:-/home/catalogues}/$name"
  mkdir -p "$(dirname "$dir")"
  rm -rf "$dir.tmp"
  GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 \
    "${FORGE_BASE_URL%/}/${name}/${STORE_REPO}.git" "$dir.tmp" || { rm -rf "$dir.tmp"; return 1; }
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
  local url="${FORGE_BASE_URL%/}/${name}/${STORE_REPO}.git"

  printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$tok")" \
    | curl -sS -K - -o /dev/null -m 20 -X POST -H 'Content-Type: application/json' \
      -d "{\"name\":\"${STORE_REPO}\",\"private\":false,\"auto_init\":false}" \
      "${FORGE_BASE_URL%/}/api/v1/orgs/${name}/repos" || true

  local stage; stage="$(mktemp -d)"
  cp -r "$tree/." "$stage/"
  rm -rf "$stage/.git"
  ( cd "$stage" \
    && git init -q -b main \
    && git add -A \
    && git -c "user.name=$SYSTEM_ACCOUNT" -c "user.email=$SYSTEM_EMAIL" \
         commit -q -m "chore(catalogue): projection de $name depuis son depot" \
                   -m "Source-Commit: $src_sha" \
    && GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
       GIT_CONFIG_KEY_0="http.${FORGE_BASE_URL%/}.extraheader" \
       GIT_CONFIG_VALUE_0="Authorization: token $tok" \
       git push -q --force "$url" main ) \
    || { rm -rf "$stage"; die "install: source NON poussee dans $name/$STORE_REPO — l'org est posee mais le catalogue n'est PAS installe"; }
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
  # ⚠ CE VERBE EXISTE POUR QU'AUCUN APPELANT N'AIT A RECOPIER LE DEFAUT. Le nom du compte integre a
  # UN auteur — la ligne `TF_VAR_builtin_human` ci-dessus — et un second litteral ailleurs ne reste
  # d'accord avec elle que jusqu'au jour ou l'un des deux bouge. `48-forge-host` doit poser un mot de
  # passe sur ce compte : sans porte pour DEMANDER son nom, il ne pouvait le faire que quand
  # l'operateur l'avait nomme lui-meme, c'est-a-dire jamais dans le cas nominal.
  builtin-human) printf "%s\n" "$BUILTIN_HUMAN" ;;
  *) echo "forge-gestures: geste requis (config-token|config-seed|apply|install|runner-token|toolchain-protection|builtin-human)" >&2; exit 1 ;;
esac
