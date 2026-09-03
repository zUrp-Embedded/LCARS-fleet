#!/usr/bin/env bash
# SOURCE: deploy/docker/entrypoint.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — entrypoint conteneur : converge le volume d'état puis exec sshd (login-manager)
#
# Modèle (etc/README.md du runtime) : l'humain SSH dans le conteneur EN TANT QUE LUI (sshd = le
# login-manager : auth + drop d'UID, zéro privilège custom) puis lance `fleet_v2 start`. Ce
# script est la transposition Docker du « re-run convergent » : l'image est immutable (build),
# le VOLUME /home converge ICI à chaque boot via LE MÊME `provision` que le chemin WSL.
#
# Un échec de convergence NE TUE PAS le conteneur : la boîte doit rester joignable pour être
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

# ─── MODE OUTIL : `verify <racine>` — valider un catalogue SANS booter la boîte ─────────────────
# ─── `drop_priv` — ABAISSER quand on est root, ne rien faire quand on ne l'est pas ──────────────
#
# Les trois portes de LECTURE ci-dessous tournent en `nobody:fleet` : le runtime REFUSE root
# (R-no-root-runtime), et une lecture n'a besoin que du gid `fleet` (l'install RO est root:fleet).
RELEASE_BIN="${LCARS_RELEASE_BIN:-/opt/lcars/runtime/rel/lcars_fleet/bin/lcars_fleet}"

drop_priv() { # drop_priv <cmd...>
  if [[ "$(id -u)" -eq 0 ]]; then
    exec setpriv --reuid 65534 --regid 2000 --clear-groups "$@"
  else
    exec "$@"
  fi
}

# `docker run --rm -v $PWD:/cat <image> verify /cat` : le code de sortie est le verdict
# (0 = catalogue OK, 1 = refusé), exploitable en CI ; le rapport s'imprime sur stdout et
# déclare ses hypothèses (la racine lue, les surcharges fines ignorées). Ne converge rien,
# ne crée personne : la seule chose exécutée est la release, en eval. Le binaire de release
# est appelé directement — `fleet_v2`, lui, porte le lancement per-humain (RELEASE_TMP dans
# ~/.lcars), des hypothèses qu'un mode outil n'a pas le droit d'avoir.
if [[ "${1:-}" == "verify" ]]; then
  root="${2:?verify: chemin de racine catalogue requis — usage : docker run --rm -v \$PWD:/cat IMAGE verify /cat}"
  # LCARS_TOOL_EVAL=1 : `release eval` execute les config providers (runtime.exs ENTIER) avant
  # l'expression — ce drapeau saute le corps de config deploiement (ports, forge, credentials),
  # qu'une invocation outil n'a pas a fournir. Sans lui, l'eval exige l'env d'un boot de fleet.
  drop_priv \
    env HOME=/tmp RELEASE_TMP=/tmp LCARS_TOOL_EVAL=1 \
    "$RELEASE_BIN" eval \
    "Fleet.Application.CatalogueVerify.eval_main(\"${root}\")"
fi

# `roles` / `roles-tfvars` : le ROSTER FORGE d'un catalogue — les comptes qu'un deploiement doit
# creer avant que ce catalogue puisse travailler. Meme porte outil que `verify` ci-dessus (meme
# eval, meme nobody, meme LCARS_TOOL_EVAL), et pour la meme raison : la question se pose a un
# script de provisionnement, qui se tient DEHORS d'une fleet vivante.
#   roles        un nom de ROLE par ligne  -> lecture humaine, inventaire d'un catalogue
#   roles-tfvars le JSON des quatre listes -> roles.auto.tfvars.json (les comptes, cote tofu)
#                                             ET la derivation de PROV_ROLES (`prov_roles`)
if [[ "${1:-}" == "roles" || "${1:-}" == "roles-tfvars" ]]; then
  root="${2:-}"
  fun="Fleet.Roster.eval_main"
  [[ "${1}" == "roles-tfvars" ]] && fun="Fleet.Roster.eval_tfvars"
  if [[ -n "$root" ]]; then arg="\"${root}\""; else arg="Fleet.Catalogue.root()"; fi
  drop_priv \
    env HOME=/tmp RELEASE_TMP=/tmp LCARS_TOOL_EVAL=1 \
    "$RELEASE_BIN" eval \
    "${fun}(${arg})"
fi

# `catalogue-root` : OU LE RELEASE PORTE SON CATALOGUE DE REFERENCE. Une ligne, un chemin.
#
# Il existe pour que personne ne RECOMPOSE ce chemin. Il vit dans le release, sous un repertoire qui
# porte la VERSION (`lib/lcars_fleet-<vsn>/priv/catalogue`) : un appelant shell qui le globberait
# marcherait jusqu'au jour ou la disposition du release change, et casserait alors en silence sur
# un glob vide. Le release est l'autorite de sa propre disposition, et c'est lui qu'on interroge.
# ⚠ CE DRAPEAU SAUTE LE CORPS DE CONFIG DE DEPLOIEMENT, donc un `LCARS_CATALOGUE_ROOT` pose par
# l'operateur n'est PAS lu ici — et c'est ce qu'on veut. Cette porte repond « le catalogue que CE
# RELEASE porte », pas « celui que cette boite sert ». C'est le premier qu'on publie sur la forge :
# la reference, celle qu'on forke, pas la variante locale de quelqu'un.
if [[ "${1:-}" == "catalogue-root" ]]; then
  drop_priv \
    env HOME=/tmp RELEASE_TMP=/tmp LCARS_TOOL_EVAL=1 \
    "$RELEASE_BIN" eval \
    'IO.puts(Fleet.Catalogue.root())'
fi

# `forge-apply` : LA STRUCTURE DE LA FORGE, POSEE PAR UN RUN TRANSITOIRE ─────────────────────────
#
# Meme geste que `deploy/box forge-apply`, mais SANS boite vivante : `docker run --rm <image>
# forge-apply`. C'est ce qui permet a un POSTE DE TRAVAIL (rail WSL) d'avoir une forge utilisable
# sans reconstruire et relancer un LCARS en conteneur alors qu'il vient de l'installer nativement.
#
# ⚠ ET L'ETAT DE TOFU N'A PAS BESOIN DE SURVIVRE — c'est le design, pas un pis-aller : la recette
# reconstruit ce qui existe par ses blocs `import`, donc partir d'un tfstate VIDE est le cas normal.
# C'est exactement pourquoi `--tofu-dir` est devenu un argument ignore. Un run `--rm` est donc
# legitime ici, la ou il aurait ete un piege avant ce chantier.
#
# L'appelant fournit : `--network <reseau-de-la-forge>`, `-v /opt/lcars/var/tokens:/opt/lcars/var/tokens`,
# `-e FORGE_BASE_URL=http://gitea:3000`. Le jeton peut aussi arriver sur stdin (jamais en argv).
if [[ "${1:-}" == "forge-apply" ]]; then
  [[ "$(id -u)" -eq 0 ]] || { echo "forge-apply: cette porte ecrit et lit /opt/lcars/var/tokens — elle exige root dans le conteneur" >&2; exit 1; }
  exec /opt/lcars/forge-gestures.sh apply
fi

# `catalogue-source <nom>` : resout UN nom vers le depot qui le porte, et n'imprime que
# `<repo> <branche> <sha>`. Le geste d'install le donne a `git clone`, donc une ligne de politesse
# deviendrait un morceau d'URL.
#
# Meme porte `nobody` que `roles` : c'est une LECTURE. Les codes de sortie distinguent trois refus
# qui appellent trois gestes differents — 2 personne n'a depose, 3 deux depots revendiquent le meme
# nom (on ne devine pas), 4 c'est le catalogue livre dans le release, il n'y a rien a installer.
if [[ "${1:-}" == "catalogue-source" ]]; then
  name="${2:?catalogue-source: nom de catalogue requis}"
  # ⚠ `FORGE_TOKEN` RELAYE A COTE DE `FORGE_TOKEN_FILE`, ET SANS LUI LE MAILLON CASSE EN SILENCE.
  # Cette porte tombe en `nobody:fleet` : elle ne peut ouvrir aucun SECRET de `/opt/lcars/var/tokens`.
  # Ce qui la tient est le mode des FICHIERS (0600), pas celui du dossier. La conclusion n'a pas
  # bouge, sa raison si — et une raison fausse est ce qui fait relacher le vrai garde un jour. Son
  # appelant — `forge-gestures.sh cmd_install`, qui EST le service d'autorite — lit donc le jeton
  # systeme et transmet sa VALEUR. Or `env` ne propage que ce qu'on lui NOMME : oublier cette
  # variable ici aurait rendu une porte sans credential, dont l'echec accuse la source du catalogue.
  #
  # LE CHEMIN RESTE ACCEPTE : un appelant ROOT (le rail poste, un banc) en a un qui lui est lisible,
  # et `Transport.resolve_token/1` prend le jeton fourni AVANT le chemin. Deux entrees, une seule
  # resolution, et la plus specifique gagne.
  drop_priv \
    env HOME=/tmp RELEASE_TMP=/tmp LCARS_TOOL_EVAL=1 \
    FORGE_BASE_URL="${FORGE_BASE_URL:-}" FORGE_TOKEN_FILE="${FORGE_TOKEN_FILE:-}" \
    FORGE_TOKEN="${FORGE_TOKEN:-}" \
    "$RELEASE_BIN" eval \
    "Fleet.Application.CatalogueLifecycle.eval_source(\"${name}\")"
fi

# admiral = le master/sysadmin (uid 1000 reserve, sudo root). Bench: `admiral`. Prod: le login que
# l'installeur a cree sur SA forge. Ce n'est PAS un worker de la fleet — Guard B refuse de lancer une
# fleet sous cet uid, et les workers viennent du convergeur (forge fleet:humans, uid >= 1001).
LCARS_UID="${LCARS_UID:-1000}"

# Un fait, un nom : `LCARS_UID` reste l'ENTREE de ce rail (c'est par elle qu'un operateur choisit),
# `LCARS_SYSADMIN_UID` est le NOM DU FAIT que tout le reste lit. Le second derive du premier ici,
# une fois, avant que quoi que ce soit ne le lise.
export LCARS_SYSADMIN_UID="$LCARS_UID"

# ⚠ ET L'EXPORT NE SUFFIT PAS, PARCE QU'IL NE TRAVERSE PAS `exec sshd`. Une session ssh part d'un
# environnement NEUF — l'image ne pose ni `AcceptEnv` ni `PermitUserEnvironment` — donc l'humain qui
# tape `fleet_v2 start` n'a jamais vu cette variable, et GUARD B y retombait sur son litteral `1000`.
#
# ⚠ ET MEME ACHEMINEE, UNE VARIABLE NE PEUT PAS PORTER CETTE CLEF : mesure du 2026-08-27,
# `LCARS_SYSADMIN_UID=99999 fleet_v2 start` desarmait la garde. L'environnement d'un processus
# appartient a ce processus ; une garde ne peut pas y prendre sa politique.
#
# D'ou un FICHIER, `root:root`, que le garde ne peut pas reecrire et qui GAGNE sur la variable chez
# ses deux lecteurs (`bin/fleet_v2` et son miroir `config/runtime.exs`). `64-services` le pose au
# poste ; ce module-la est `APPLY-ON: wsl linux`, donc en boite c'est ici, et nulle part ailleurs.
SEAT_UID_FILE="${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}"
if mkdir -p "$(dirname "$SEAT_UID_FILE")" 2>/dev/null \
   && printf '%s\n' "$LCARS_UID" > "$SEAT_UID_FILE" 2>/dev/null; then
  chmod 0644 "$SEAT_UID_FILE" 2>/dev/null || true
  chown root:root "$SEAT_UID_FILE" 2>/dev/null || true
else
  echo "[lcars-entrypoint] $SEAT_UID_FILE NON pose — GUARD B refusera tout « fleet_v2 start » : sans ce fichier il ne peut pas etablir le siege (uid $LCARS_UID)" >&2
fi
PROVISION=/opt/lcars/deploy/provision
HOST_KEYS_DIR=/home/.lcars-container/ssh
# ⚠ LA MEME TABLE QUE LE CONVERGEUR, ET C'EST TOUT L'INTERET. Le siege est le #1 de la forge : son
# enregistrement est donc la LIGNE `forge_id = 1` de `forge-uid.map`, pas un fichier a lui. Une
# seconde table pour tenir une ligne de la premiere aurait fait deux verites d'un meme fait — celle
# qu'on ne lit pas finit toujours par mentir — et deux formats a maintenir la ou le convergeur en a
# deja un (`<forge_id>\t<uid>\t<login>`, keye sur l'id parce que Gitea le conserve au renommage).
UID_MAP_FILE="${LCARS_UID_MAP_FILE:-/opt/lcars/var/tokens/forge-uid.map}"
MASTER_TOKEN_FILE="${LCARS_MASTER_TOKEN_FILE:-/opt/lcars/var/tokens/forge-master.token}"

say() { echo "[lcars-entrypoint] $*"; }

# ─── LE SIEGE EST LE #1 DE LA FORGE ─────────────────────────────────────────────────────────────
#
# LA REGLE : celui des deux qui existe nomme l'autre, et le lien est enregistre.
#
# ⚠ AUCUN RAIL NE PART DE RIEN, et c'est ce qui rend la regle suffisante. Le poste a son systeme
# avant LCARS ; la boite vise une forge qui tourne deja. Le SEUL cas ou rien ne preexiste est
# `--bench`, qui cree tout — et le bench PASSE le nom lui-meme (`bench-up.sh:353`). Il n'y a donc
# aucun cas ou ce fichier aurait a inventer un nom, et il ne doit pas en inventer : un nom invente
# est la coincidence que ce code existe pour retirer.
#
# `LCARS_ADMIRAL` A DONC UN SEUL SENS : la SEMENCE du cas from-scratch. Elle court-circuite la
# derivation parce que dans ce cas-la il n'y a rien a deriver. Ce n'est pas une surcharge qui
# contredirait la forge — il n'y a pas de forge a contredire quand le bench la cree.
#
# ⚠ LA LIB EST SOURCEE ICI, ET C'EST MESURE. Hors du runner elle n'imprime rien, ne pose aucun trap
# (sa garde de sortie n'est armee que sous `PROVISION_RUN`) et n'ecrase aucune fonction de ce
# fichier — zero collision sur les 57 qu'elle definit. Ce qu'on y gagne : UNE derivation du siege
# pour les deux rails, au lieu de deux copies qui divergent le jour ou l'une est corrigee.
PROVISION_LIB_FILE="${LCARS_PROVISION_LIB:-/opt/lcars/deploy/lib/provision-lib.sh}"
if [[ ! -r "$PROVISION_LIB_FILE" ]]; then
  echo "[lcars-entrypoint] provision-lib introuvable ($PROVISION_LIB_FILE) — le siege ne peut pas se deriver, et le provisionnement de l'etape 3 vient du meme arbre. Image incomplete." >&2
  exit 1
fi
# shellcheck source=../lib/provision-lib.sh
. "$PROVISION_LIB_FILE"

resolve_admiral() {
  # Les noms de ce fichier sont ceux du conteneur, ceux de la lib ceux du provisionnement : on les
  # accorde ICI, une fois, plutot que de faire porter a la lib un second jeu de noms.
  PROV_UID_MAP_FILE="$UID_MAP_FILE"
  PROV_MASTER_TOKEN_FILE="$MASTER_TOKEN_FILE"
  PROV_FORGE_URL="${FORGE_BASE_URL:-}"

  prov_seat_binding "${LCARS_ADMIRAL:-}"

  case "$PROV_SEAT_BINDING" in
    seeded)
      say "siege : « $PROV_SEAT_LOGIN » seme par l'appelant (LCARS_ADMIRAL) — cas from-scratch, rien a deriver"
      ;;
    derived)
      say "siege : « $PROV_SEAT_LOGIN » ($PROV_SEAT_SOURCE)"
      ;;
    agree)
      say "siege : « $PROV_SEAT_LOGIN » — la semence et $PROV_SEAT_SOURCE nomment le meme acteur"
      ;;
    diverge)
      say "siege : DIVERGENCE — la semence dit « ${LCARS_ADMIRAL:-} », $PROV_SEAT_SOURCE dit « $PROV_SEAT_LOGIN ». Le home du siege vit sous UN de ces noms : retire la semence pour suivre $PROV_SEAT_SOURCE, ou corrige la table ($UID_MAP_FILE)."
      return 1
      ;;
    *)
      # ⚠ DEUX CAUSES, DEUX REPARATIONS. « Pas de jeton » et « forge muette » ne s'arrangent pas de
      # la meme facon, et les fondre renvoie l'operateur regarder le mauvais objet. On teste la
      # PRESENCE du fichier (`-s`), jamais son contenu : classer un refus ne demande pas de lire
      # un secret.
      local pourquoi
      if [[ -s "$MASTER_TOKEN_FILE" ]]; then pourquoi="forge muette"
      else pourquoi="jeton master illisible : $MASTER_TOKEN_FILE"; fi
      say "siege : IMPOSSIBLE a determiner — ni semence (LCARS_ADMIRAL), ni ligne forge_id=1 dans $UID_MAP_FILE, ni #1 lisible sur ${FORGE_BASE_URL:-<aucune forge configuree>} ($pourquoi). « box config » pose la forge et son jeton ; le bench, lui, seme le nom."
      return 1
      ;;
  esac

  LCARS_ADMIRAL="$PROV_SEAT_LOGIN"
  # `LCARS_UID` est pose sans condition en tete de ce fichier : le re-defauter ici en ferait une
  # seconde verite, et c'est celle qu'on ne relit pas qui finit par mentir.
  prov_seat_record "$LCARS_ADMIRAL" "$LCARS_UID" \
    || say "siege : nom NON enregistre dans $UID_MAP_FILE — le boot suivant le re-derivera"
  return 0
}

# ─── 1. L'humain (idempotent — le home vit dans le volume, le user est recréé à l'identique) ─────
#
# Le nom se résout ICI et pas au chargement : c'est le premier geste qui en a besoin, et une
# résolution jouée au `source` rendrait la fonction non rejouable — elle verrait sa propre sortie
# comme un `LCARS_ADMIRAL` imposé par l'opérateur.
# ⚠ LE REFUS EST EXPLICITE, PAS UN EFFET DE `set -e`. Un `resolve_admiral` nu mourrait aussi, mais
# sur le code de retour d'une fonction — et le lecteur suivant ne saurait pas si c'est voulu. Ici le
# boot S'IMMOBILISE parce qu'on a decide qu'un siege inventable ne s'invente pas. Il s'ARRETAIT ;
# le refus n'a pas change, sa forme si — cf. le bloc ci-dessous.
if ! resolve_admiral; then
  # ⚠ ON REFUSE SANS SORTIR, ET C'EST LA DIFFERENCE ENTRE UN DIAGNOSTIC ET UN DIAGNOSTIC UTILE.
  # `exit 1` sous `restart: unless-stopped` faisait BOUCLER la boite — 25 redemarrages mesures sur
  # la 4e forme (boite + forge FOURNIE, .63, 2026-08-30). Or le geste que le message ci-dessus
  # propose, « box config », passe par un `docker exec`, et docker le REFUSE sur un conteneur qui
  # redemarre : « Container … is restarting, wait until the container is running ». Le diagnostic
  # etait juste, le remede nomme, et l'etat de la boite le rendait injouable.
  #
  # Elle reste donc debout, EN ATTENTE DE CONFIGURATION — le meme arbitrage que pour un echec de
  # convergence, plus bas : « elle tourne et reste joignable POUR ETRE REPAREE ». Un siege
  # indeterminable est un etat incomplet qu'un geste repare, pas une image cassee.
  #
  # ⚠ ET ELLE NE MENT PAS EN RESTANT DEBOUT : aucun service n'est demarre, donc le healthcheck (qui
  # sonde ssh et le deck) la declare `unhealthy`. « Up » sans « healthy » est exactement son etat.
  # `tini` est PID 1 et relaie SIGTERM : un `docker stop` la couche proprement.
  say "boite EN ATTENTE DE CONFIGURATION — elle reste debout pour que « box config » soit jouable. Aucun service n'est demarre, et le healthcheck le dira."
  # ⚠ L'ETAT SE PUBLIE, COMME LE VERDICT DE PROVISIONNEMENT PLUS BAS. Sans cette ligne, `box up`
  # attendait `/run/lcars-provision.rc` jusqu'a son timeout (300 a 900 s) pour rendre « verdict
  # NON LU » — sur une boite qui SAIT qu'elle attend et vient de l'ecrire dans ses logs. Mesure du
  # 2026-09-04, banc bob_2, premiere boite contre une forge fournie. `/run`, donc ce boot-ci.
  printf 'awaiting-config\n' > "${LCARS_BOOT_STATE_FILE:-/run/lcars-boot.state}" 2>/dev/null || true
  exec sleep infinity
fi
if ! getent passwd "$LCARS_ADMIRAL" >/dev/null; then
  useradd -m -u "$LCARS_UID" -s /bin/bash "$LCARS_ADMIRAL"
  say "sysadmin $LCARS_ADMIRAL cree (uid $LCARS_UID)"
fi
# Le mot de passe est POSE HORS d'ici (bench: fixe, pour tester ; prod: l'installeur) — l'entrypoint
# cree le siege, il ne choisit pas le secret.
if getent group sudo >/dev/null 2>&1; then
  usermod -aG sudo "$LCARS_ADMIRAL" || say "ATTENTION: « $LCARS_ADMIRAL » n'a PAS ete ajoute au groupe sudo — il n'aura pas d'elevation"
fi

if [[ -n "${LCARS_SSH_AUTHORIZED_KEYS:-}" ]]; then
  HOME_DIR="$(getent passwd "$LCARS_ADMIRAL" | cut -d: -f6)"
  install -d -m 0700 -o "$LCARS_ADMIRAL" -g "$LCARS_ADMIRAL" "$HOME_DIR/.ssh"
  # Écriture atomique tmp+mv (doctrine lib) — un crash ne laisse pas un authorized_keys tronqué.
  tmp="$(mktemp "$HOME_DIR/.ssh/.authk.XXXXXX")"
  printf '%s\n' "$LCARS_SSH_AUTHORIZED_KEYS" > "$tmp"
  chmod 0600 "$tmp" && chown "$LCARS_ADMIRAL:$LCARS_ADMIRAL" "$tmp"
  mv -f "$tmp" "$HOME_DIR/.ssh/authorized_keys"
  say "authorized_keys posé pour $LCARS_ADMIRAL"
else
  say "pas de LCARS_SSH_AUTHORIZED_KEYS — accès par « docker exec -it -u $LCARS_ADMIRAL <ctr> bash » seulement"
fi

# ─── 1bis. Les zones de FACE : une racine par face, groupe fleet ─────────────────────────────────
# Le sanctuaire bwrap des pods monte ces zones (cap-profile starfleet : les deux en rw) —
# ABSENTE, le spawn meurt (« catalogue mount path missing host-side », vu au premier E2E,
# une zone par crash). Sur WSL elles existent (histoire du substrat) ; ICI, l'entrypoint est
# le créateur de zones du conteneur (comme pour l'humain). setgid fleet : chaque humain du
# groupe y crée ses projets/worktrees.
#
# CETTE LIGNE EST LE MIROIR DE `Fleet.Layout.face_root/1`, ET UNE FACE MANQUANTE NE SE VOIT PAS.
# `layout.face_roots_provisioned` de `mix lcars.contracts.check` : ajouter une face sans l'ajouter
# ici fait rougir le gate, en la NOMMANT.
install -d -m 2775 -g fleet /home/projects /home/projects.ops /home/projects.workshop
say "zones de face : /home/projects /home/projects.ops /home/projects.workshop (2775 root:fleet)"

# La SOURCE — l'auto-maintenance en dépend : c'est le checkout que la fleet lit, met à jour
# (`provision update`) et sur lequel ses agents travaillent.
#
# DEUX CHEMINS, ET UN SEUL EST CELUI D'UNE INSTALLATION. Le geste de dév est `deploy/box
# source-push` : un `docker cp` depuis le clone de l'humain. Qui INSTALLE depuis une image tirée
# d'une registry n'a aucun clone à pousser — il a une URL. Le chemin nominal est donc un CLONE,
# fait ici, et il est possible sans credential : le dépôt est public en lecture (`git ls-remote`
# anonyme mesuré vivant sur la forge).
#
# LA RÈGLE QUI COMPTE : on ne clone que si le dossier est ABSENT. Une source déjà là n'est JAMAIS
# écrasée ni remise à niveau — un redémarrage du conteneur détruirait le travail en cours d'un
# agent, et ce serait le genre de perte qu'on ne remarque qu'après. Mettre à jour est un geste
# explicite (`provision update`), pas un effet de bord du boot.
LCARS_SOURCE_DIR="${LCARS_SOURCE_DIR:-/home/projects/LCARS}"

if [[ ! -d "$LCARS_SOURCE_DIR/.git" && -n "${LCARS_SOURCE_REMOTE:-}" ]]; then
  # `--branch` accepte une branche OU un tag, pas un sha nu : c'est la forme d'une ref publiée,
  # et un sha arbitraire exigerait `allowReachableSHA1InWant` côté serveur — dépendance qu'on ne
  # présume pas. Ref vide = branche par défaut du dépôt.
  clone_args=(--depth 1)
  [[ -n "${LCARS_SOURCE_REF:-}" ]] && clone_args+=(--branch "$LCARS_SOURCE_REF")
  say "clonage de la source : $LCARS_SOURCE_REMOTE${LCARS_SOURCE_REF:+ (ref $LCARS_SOURCE_REF)} → $LCARS_SOURCE_DIR"
  # ATOMIQUE (clone en .part puis mv) : un boot tué EN PLEIN clone laisserait un .git partiel
  # que la règle de non-écrasement protégerait ensuite comme du travail — la boîte vivrait sur
  # un cadavre de repo. Le .part orphelin d'un boot précédent se nettoie, lui : il n'est jamais
  # du travail, par construction.
  rm -rf "${LCARS_SOURCE_DIR}.part"
  if git clone "${clone_args[@]}" "$LCARS_SOURCE_REMOTE" "${LCARS_SOURCE_DIR}.part" 2>&1 | sed 's/^/[git] /' \
     && mv "${LCARS_SOURCE_DIR}.part" "$LCARS_SOURCE_DIR"; then
    # Le clone est fait par root ; la source appartient à l'humain qui travaillera dedans. Le
    # groupe `fleet` parce que c'est celui des zones catalogue posées juste au-dessus.
    chown -R "$LCARS_ADMIRAL:fleet" "$LCARS_SOURCE_DIR"
    say "source clonée"
  else
    rm -rf "${LCARS_SOURCE_DIR}.part"
    say "CLONAGE ÉCHOUÉ — la boîte démarre sans source (la fleet ne pourra pas se maintenir)"
  fi
fi

# LE CORPUS ops — même contrat que les projets nés ici : un projet canon a DEUX arbres,
# `main` (le code, ci-dessus) et `ops` (plans, journaux, gate-briefs), checkouté dans le
# dual-dir /home/projects.ops/<nom>. Si le remote porte la branche, on la pose ; sinon on le
# dit et la boîte vit sans (une source sans corpus reste maintenable, elle est juste amnésique).
# Même règle de non-écrasement : un dual-dir déjà là n'est jamais touché.
LCARS_WORK_DIR="/home/projects.ops/$(basename "$LCARS_SOURCE_DIR")"
if [[ ! -d "$LCARS_WORK_DIR/.git" && -n "${LCARS_SOURCE_REMOTE:-}" ]]; then
  if git ls-remote --exit-code --heads "$LCARS_SOURCE_REMOTE" ops >/dev/null 2>&1; then
    say "clonage du corpus ops → $LCARS_WORK_DIR"
    rm -rf "${LCARS_WORK_DIR}.part"
    if git clone --depth 1 --branch ops "$LCARS_SOURCE_REMOTE" "${LCARS_WORK_DIR}.part" 2>&1 | sed 's/^/[git] /' \
       && mv "${LCARS_WORK_DIR}.part" "$LCARS_WORK_DIR"; then
      chown -R "$LCARS_ADMIRAL:fleet" "$LCARS_WORK_DIR"
      say "corpus ops posé"
    else
      rm -rf "${LCARS_WORK_DIR}.part"
      say "CLONAGE ops ÉCHOUÉ — dual-dir absent (adoptable plus tard, rien de fatal)"
    fi
  else
    say "pas de branche ops sur le remote — dual-dir non posé (le corpus arrive par l'adopt)"
  fi
fi

# ⚠ L'IDENTITÉ GIT NE SE POSE PLUS ICI, ET LA VARIABLE `LCARS_ADMIRAL_EMAIL` N'EXISTE PLUS.
# C'est `70-human` qui la porte désormais, per-humain, DÉRIVÉE DU COMPTE FORGE — la seule adresse
# qui mappe un commit sur un compte (avatar compris). Une variable d'install n'en était qu'une copie.

if [[ -d "$LCARS_SOURCE_DIR/.git" ]]; then
  # git refuse un repo d'un autre owner (« dubious ownership ») : le clone vient de l'hôte,
  # son uid n'a aucune raison d'être celui du conteneur. Déclaré safe pour TOUS les humains.
  git config --system --replace-all safe.directory "$LCARS_SOURCE_DIR" 2>/dev/null || true
  src_rev="$(git -C "$LCARS_SOURCE_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo '?')"
  say "source LCARS : $LCARS_SOURCE_DIR ($src_rev) — auto-maintenance possible"

  img_rev="${LCARS_IMAGE_REVISION:-unknown}"
  if [[ "$img_rev" == "unknown" ]]; then
    say "  révision de l'image INCONNUE — écart image/source invérifiable (image bâtie sans GIT_SHA)"
  elif [[ "$src_rev" != "$img_rev" ]]; then
    say "  ÉCART image/source : le runtime qui tourne est bâti sur $img_rev, la source est sur $src_rev"
    say "  (ce n'est pas une panne : lire la source ne renseigne pas sur le binaire, et inversement)"
  else
    say "  image et source sur la même révision ($img_rev)"
  fi
else
  say "PAS de source LCARS sous $LCARS_SOURCE_DIR — la fleet ne peut PAS se maintenir elle-même"
  say "  install : LCARS_SOURCE_REMOTE=<url> [LCARS_SOURCE_REF=<branche|tag>] au démarrage"
  say "  dév     : deploy/box source-push (docker cp depuis ton clone)"
fi

# ─── 2. Identité SSH du conteneur : clés d'hôte PERSISTANTES dans le volume ──────────────────────
# (Un conteneur recréé qui change de clés d'hôte = « WARNING: REMOTE HOST IDENTIFICATION HAS
# CHANGED » chez chaque humain — l'identité vit avec l'état, pas avec l'éphémère.)
install -d -m 0700 "$HOST_KEYS_DIR"
if ls "$HOST_KEYS_DIR"/ssh_host_*_key >/dev/null 2>&1; then
  cp "$HOST_KEYS_DIR"/ssh_host_* /etc/ssh/
  chmod 0600 /etc/ssh/ssh_host_*_key
  say "clés d'hôte SSH restaurées depuis le volume"
else
  ssh-keygen -A >/dev/null            # génère dans /etc/ssh les types manquants
  cp /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub "$HOST_KEYS_DIR/"
  chmod 0600 "$HOST_KEYS_DIR"/ssh_host_*_key
  say "clés d'hôte SSH générées → $HOST_KEYS_DIR (persistantes)"
fi

# ─── 3. Convergence de l'état — LE MÊME provision que le chemin WSL, substrat docker ─────────────
#
# ⚠ ET LE VERDICT SE PUBLIE, parce que « jamais fatal » n'a jamais voulu dire « jamais dit ». Il ne
# vivait que dans les logs du conteneur, donc `deploy/box up` rendait la main sur une boîte qui
# annonce « fleet up », se déclare *healthy* (son healthcheck ne sonde que des ports : ssh + le deck) et ne peut démarrer
# AUCUN pod. Un opérateur n'a aucune raison d'aller lire des logs après une commande qui a dit oui.
#
# `/run` et pas un volume : c'est un tmpfs, donc le fichier meurt avec le conteneur et décrit
# TOUJOURS ce boot-ci. Même emplacement et même motif que `/run/lcars-converger.refused` — un
# composant sait pourquoi, il l'écrit là où un autre peut le lire.
PROV_RC_FILE="${LCARS_PROV_RC_FILE:-/run/lcars-provision.rc}"
prov_rc=0
"$PROVISION" apply --substrate docker --human "$LCARS_ADMIRAL" || prov_rc=$?
case "$prov_rc" in
  0) say "provision apply : convergé" ;;
  2) say "provision apply : APPLIQUÉ, DRIFT RÉSIDUEL — rien n'est cassé, un geste manque (forge,
credentials, réseau). Détail : $PROVISION doctor" ;;
  *) say "provision apply : AU MOINS UN ÉCHEC (rc=$prov_rc) — la boîte démarre quand même ; diagnose : $PROVISION doctor" ;;
esac

# La publication descend donc APRÈS les deux mesures, et `lcars-provision.rc` s'écrit EN DERNIER :
# sa présence devient la garantie que l'autre fichier est là. Un lecteur qui attend un seul des deux
# n'a plus à connaître l'ordre — c'est le producteur qui le tient.
#
# Le verdict se publie quel qu'il soit, y compris 0. Un fichier qui n'apparaîtrait que sur l'échec
# forcerait son lecteur à distinguer « pas encore écrit » de « tout va bien », c'est-à-dire à deviner
# exactement ce que ce fichier existe pour dire.
publier_verdicts() {
  [[ -n "${humans_rc:-}" ]] && {
    printf '%s\n' "$humans_rc" > "$HUMANS_RC_FILE" 2>/dev/null || true
    chmod 0644 "$HUMANS_RC_FILE" 2>/dev/null || true
  }
  printf '%s\n' "$prov_rc" > "$PROV_RC_FILE" 2>/dev/null || true
  chmod 0644 "$PROV_RC_FILE" 2>/dev/null || true
}

# ─── LANCER UN SERVICE PERSISTANT — CE QUE `Restart=` FAIT SUR L'AUTRE RAIL ─────────────────────
#
# ⚠ ET LE SUPERVISEUR NE PEUT PAS VIVRE ICI. Ce script finit sur `exec /usr/sbin/sshd -D -e` : le
# shell est REMPLACÉ, donc toute boucle qu'il porterait disparaîtrait à cet instant. D'où un
# processus à part, lancé en `setsid` exactement comme les services l'étaient.
SUPERVISE="${LCARS_SUPERVISE_BIN:-/opt/lcars/supervise.sh}"
launch() { # launch <nom> <log> -- <cmd...>
  local name="$1" log="$2"; shift 2
  [[ "${1:-}" == "--" ]] && shift
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
# était défendable en 1976. Cette boucle poursuit le même état-cible pendant toute la vie de la
# boîte : elle lit la team `humans` au token système et crée les users manquants. Elle tourne en
# root parce que root tourne DÉJÀ ici en permanence (sshd juste dessous) — pas de `sudo` à
# installer, pas de droit à accorder à quiconque.
# Elle ne SUPPRIME jamais : la révocation est un retrait côté forge, et ce qui reste sur la machine
# est de la donnée, pas un accès (sans compte forge, ni console ni fleet ne s'ouvrent).
CONVERGER_BIN="${LCARS_HUMAN_CONVERGER:-/opt/lcars/human-converger.sh}"
CONVERGER_LOG="${LCARS_CONVERGER_LOG:-/var/log/lcars-converger.log}"
if [[ "${LCARS_CONVERGE_HUMANS:-1}" == "1" && -x "$CONVERGER_BIN" ]]; then
  # ─── UN PREMIER TOUR SYNCHRONE, PUIS LA BOUCLE ────────────────────────────────────────────────
  #
  # ⚠ ET LA VÉRIFICATION N'EST PAS RÉÉCRITE ICI, C'EST TOUT LE SUJET. `64-services` porte déjà la
  # sonde (`probe_fleet_humans`), et ce module est `CHECK-ON: any` : il tourne donc en docker. Un
  # `doctor --only` rejoue LA MÊME sonde que le poste, sur le même code. Recopier la règle d'uid ici
  # en aurait fait un troisième exemplaire — après `fleet_humans` et `converged_humans` du
  # convergeur — et c'est toujours celui qu'on ne relit pas qui ment.
  #
  # `timeout` : ce premier tour parle à la forge et provisionne chaque humain. Il est BORNÉ parce
  # qu'un boot ne peut pas dépendre d'un réseau, et NON FATAL parce que la boîte doit rester
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
  # team vide EST un résultat valide, et sur une boîte de production c'est même le cas nominal tant
  # que personne ne s'est enrôlé). Ce qui se publie est ce que la SONDE constate.
  HUMANS_RC_FILE="${LCARS_HUMANS_RC_FILE:-/run/lcars-humans.rc}"
  # ⚠ LE FAIT, PAS LE CODE DE RETOUR DU DOCTOR. `64-services` rend 0 sur une boite conforme SANS
  # humain — l'absence y est un WARN, par doctrine (un deploiement neuf attend son premier inscrit).
  # Ce bloc lisait ce 0 comme « quelqu'un peut lancer une fleet » : toujours vrai, donc jamais une
  # information. Mesure du 2026-09-04, banc bob_2 : seul le siege existait, et la boite l'annoncait.
  # Le module DEPOSE le fait (`p_fact fleet_humans`), on le relit — le canal de la porte.
  humans_facts="$(mktemp "${TMPDIR:-/tmp}/lcars-facts.XXXXXX")" || humans_facts=""
  PROV_FACTS_FILE="$humans_facts" "$PROVISION" doctor --substrate docker --only 64-services >/dev/null 2>&1 || true
  humans_rc=1
  [[ -n "$humans_facts" ]] && [[ -n "$(sed -n 's/^fleet_humans=//p' "$humans_facts" 2>/dev/null | tail -1 | tr -d '[:space:]')" ]] && humans_rc=0
  rm -f "$humans_facts"
  if [[ "$humans_rc" -eq 0 ]]; then
    say "humain(s) de fleet : présent(s) — « fleet_v2 start » a quelqu'un pour le lancer"
  else
    say "AUCUN humain de fleet dans cette boîte — GUARD B refusera tout « fleet_v2 start ». Enrôle quelqu'un sur la forge et ajoute-le à la team « humans » : la boucle le matérialise au tour suivant"
  fi

  launch "convergence des humains" "$CONVERGER_LOG" -- "$CONVERGER_BIN"
  say "un ajout à la team « humans » suffit désormais, sans redémarrage"
else
  say "convergence des humains DÉSACTIVÉE — enrôler quelqu'un exige un geste manuel dans la boîte"
fi

# LES DEUX VERDICTS, ENSEMBLE ET DANS CET ORDRE. `humans_rc` n'existe que si la convergence a
# tourné ; sans elle, seul `provision.rc` est publié et `box up` dit « NON MESURÉE » — ce qui est
# exactement vrai. La présence de `provision.rc` garantit que l'autre est là quand il doit l'être.
publier_verdicts

# ─── 3bis. La console web (ttyd sous l'humain, sur SA socket AF_UNIX) ───────────────────────────
# Lancée APRÈS la convergence (elle a besoin de l'humain et de son home) et AVANT sshd (qui prend
# le premier plan). Son échec n'est pas fatal — même règle que la convergence : la boîte doit
# rester joignable pour être réparée. La console est un CONFORT, ssh reste la porte d'admin.
if [[ "${LCARS_CONSOLE:-1}" == "1" ]]; then
  # `--all` : UNE console par humain éligible, chacune sur SA socket
  # (`/run/lcars/console/<humain>/`), gardée par le mode du répertoire. Le multi-humain ne coûte
  # aucune coordination — un répertoire possédé par chacun, pas de registre. L'éligibilité et la
  # garde anti-système vivent dans console-humans.sh, source unique.
  /opt/lcars/console.sh --all || say "console web NON lancée (rc=$?) — ssh reste la porte"

  # La home de la boîte, sur un port HORS de l'espace des blocs humains. Elle n'appartient à aucun
  # humain — c'est la porte de la boîte. Échec non fatal comme le reste.
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
    # `redirect_uris` OAuth2 avec `PROV_DECK_PORT` ; le daemon, lui, lit `LCARS_LANDING_PORT`. Au
    # poste, `64-services` fait le pont (`LCARS_LANDING_PORT=$PROV_DECK_PORT` dans `services.env`,
    # gardé par `services_units.bats`). Ici, RIEN ne le faisait : les deux valeurs ne s'accordaient
    # que parce que leurs deux défauts indépendants valent tous les deux 20999.
    export LCARS_LANDING_PORT="${LCARS_LANDING_PORT:-${PROV_DECK_PORT:-20999}}"
    launch "home de la boîte (deck)" /var/log/lcars-landing.log -- \
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
  # ici l'entrypoint est PID 1 et personne ne le fait a sa place. Le service ne doit pas heriter du
  # root de l'entrypoint — il detient les secrets de la forge et n'a aucun privilege a exercer.
  # Le `setpriv` est DANS la commande supervisée, pas autour du superviseur : celui-ci doit rester
  # root pour pouvoir relancer, et c'est l'ENFANT qui descend — exactement ce que `User=` fait dans
  # l'unité systemd du rail poste, où systemd reste root et le service non.
  # ⚠ ET SON REPERTOIRE RUNTIME AVEC, POUR EXACTEMENT LA MEME RAISON — c'est l'autre moitie de
  # `User=`, et elle manquait. `lcars_socket.py` cree le dossier de socket AVEC L'UID DU SERVICE :
  # un service qui vient de DROPPER ne peut rien creer sous `/run/lcars` (root:root 0755). Sur le
  # poste, `25-directories` pose ce dossier et l'unite porte `User=` — deux moities d'un seul geste,
  # tenues par deux acteurs. Ici l'entrypoint est le seul acteur, et il n'en tenait qu'une.
  #
  # Les services qui restent root creent le leur tout seuls : ils masquaient le trou. Celui-ci, non.
  # Mesure .63 du 2026-08-30 : « PermissionError: [Errno 13] … '/run/lcars/authority' », cinq
  # relances en moins d'une minute, puis ABANDON du superviseur (sa borne, et elle a bien joue) —
  # un service MORT sur un banc que tout le reste declarait PRET.
  #
  # ⚠ ICI ET NULLE PART AILLEURS : sur docker, `prov_runtime_dirs` ne declare AUCUN dossier de
  # `/run/lcars`, precisement pour qu'il n'y ait jamais deux createurs. `install -d` ne repose pas
  # le mode d'un dossier existant, donc un desaccord entre deux poseurs serait SILENCIEUX.
  install -d -m 0750 -o "$LCARS_AUTHORITY_USER" -g "${PROV_FLEET_GROUP:-fleet}" /run/lcars/authority \
    || say "ATTENTION : /run/lcars/authority non pose — l'executeur de catalogue ne pourra pas ouvrir sa socket"
  launch "executeur de catalogue" /var/log/lcars-catalogue.log -- \
    setpriv --reuid "$LCARS_AUTHORITY_USER" --regid "$LCARS_AUTHORITY_USER" --init-groups \
    python3 /opt/lcars/catalogue-executor.py
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
    python3 /opt/lcars/privileged-executor.py
  say "la convergence d'outillage passe par sa socket, plus par sudo"
else
  say "service privilégié ABSENT — la convergence d'outillage refusera, en nommant sa socket"
fi

# ─── 4. sshd au premier plan (tini est PID 1 : reap + signaux ; exec = sshd reçoit les signaux) ──
say "sshd prêt — ssh $LCARS_ADMIRAL@<hôte> -p <port mappé> : c'est la porte d'ADMIN. « fleet_v2 start » veut un humain de fleet, depuis sa console — GUARD B refuse le siège"
exec /usr/sbin/sshd -D -e
