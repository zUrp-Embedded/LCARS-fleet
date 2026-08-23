#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/entrypoint.sh
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
#                   ⚠ CETTE VARIABLE EST DESORMAIS FACULTATIVE, et la laisser vide est le cas NOMINAL :
#                   le siege se DERIVE du #1 de la forge (`resolve_admiral`, plus bas). La poser garde
#                   la priorite — c'est le geste de l'operateur qui sait ce qu'il fait — mais ce n'est
#                   plus a lui de tenir une egalite que la boite peut mesurer. « Pas de check runtime
#                   possible » etait ecrit ici : c'etait vrai de la CONVERGENCE, pas du jeton master.
#   LCARS_UID       uid du sysadmin (défaut : 1000, réservé) — stable = ownership du volume stable
#   LCARS_SSH_AUTHORIZED_KEYS  contenu authorized_keys (sinon : accès par `docker exec` seulement)
#   FORGE_BASE_URL  forge cible (avec le profil compose `forge` : http://forge:3000)

set -euo pipefail

# ─── MODE OUTIL : `verify <racine>` — valider un catalogue SANS booter la boîte ─────────────────
# ─── `drop_priv` — ABAISSER quand on est root, ne rien faire quand on ne l'est pas ──────────────
#
# Les trois portes de LECTURE ci-dessous tournent en `nobody:fleet` : le runtime REFUSE root
# (R-no-root-runtime), et une lecture n'a besoin que du gid `fleet` (l'install RO est root:fleet).
#
# ⚠ `setpriv --reuid` EST UN ABAISSEMENT, DONC IL EXIGE D'ETRE ROOT — et ces portes ont ete ecrites
# quand leur seul appelant l'etait. Depuis que « admin » est un fait de FORGE et non `uid 0`
# (⚖ user 2026-08-17), l'appelant est un humain ordinaire : `setpriv` rendait alors
# `setresuid failed: Operation not permitted`, et l'install mourait sur « pas de source
# installable » — un refus de catalogue pour un probleme de privilege. MESURE SUR BANC le
# 2026-08-17, sur la premiere install jouee par un non-root.
#
# Un appelant deja non-root n'a RIEN a abaisser : il est deja depourvu. On ne simule donc pas
# `nobody` — on constate qu'il n'y a plus rien a retirer, et on execute en place.
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
  # Le runtime REFUSE root (R-no-root-runtime, runtime.exs) et le mode outil respecte
  # l'invariant au lieu de le contourner : l'eval tombe sur nobody:fleet — le gid fleet
  # donne la lecture de l'install RO (/local, root:fleet), nobody ne possède rien d'autre.
  # LCARS_TOOL_EVAL=1 : `release eval` execute les config providers (runtime.exs ENTIER) avant
  # l'expression — ce drapeau saute le corps de config deploiement (ports, forge, credentials),
  # qu'une invocation outil n'a pas a fournir. Sans lui, l'eval exige l'env d'un boot de fleet.
  drop_priv \
    env HOME=/tmp RELEASE_TMP=/tmp LCARS_TOOL_EVAL=1 \
    /local/LCARS_v2/rel/lcars_fleet/bin/lcars_fleet eval \
    "Fleet.Application.CatalogueVerify.eval_main(\"${root}\")"
fi

# `roles` / `roles-tfvars` : le ROSTER FORGE d'un catalogue — les comptes qu'un deploiement doit
# creer avant que ce catalogue puisse travailler. Meme porte outil que `verify` ci-dessus (meme
# eval, meme nobody, meme LCARS_TOOL_EVAL), et pour la meme raison : la question se pose a un
# script de provisionnement, qui se tient DEHORS d'une fleet vivante.
#   roles        un nom de ROLE par ligne  -> lecture humaine, inventaire d'un catalogue
#   roles-tfvars le JSON des quatre listes -> roles.auto.tfvars.json (les comptes, cote tofu)
#                                             ET la derivation de PROV_ROLES (`prov_roles`)
#
# ⚠ LES DEUX NE RENDENT PAS LA MEME CHOSE, et cette ligne a affirme le contraire jusqu'au
# 2026-08-16 : elle donnait `roles` comme la source de `PROV_ROLES`. `roles` rend des noms de ROLE
# (`dev`, `writer`) ; `PROV_ROLES` est une liste de COMPTES (`web-demo_dev`). Branchee dessus, la
# derivation faisait entrer `dev` et `writer` dans le roster a minter — des comptes forge portant le
# nom nu d'un role, a cote des vrais. Le compte est `<org>_<role>`, et seul `roles-tfvars` le sait.
# Le motif va sur stderr : capturer stdout sur un echec doit rendre la chaine VIDE, jamais un
# message d'erreur qu'on creerait ensuite comme compte forge.
#
# ⚠ LA RACINE EST FACULTATIVE, ET SON ABSENCE VEUT DIRE « LE TIEN ». Elle etait obligatoire, donc
# l'appelant devait NOMMER un chemin — et sur un banc il nommait celui de l'HOTE, que ce conteneur
# n'a pas. Mesure du 2026-08-18 : monter l'arbre de l'hote ne suffit pas non plus, cette porte
# tourne en `nobody` et un `/home/<user>` en 0700 lui reste ferme. Une image PORTE son catalogue :
# lui demander le roster du sien ne demande ni chemin, ni montage, ni droits — et c'est plus juste,
# parce que les comptes doivent correspondre au catalogue que la boite SERVIRA, pas a un arbre de
# l'hote qui peut avoir bouge depuis le build.
if [[ "${1:-}" == "roles" || "${1:-}" == "roles-tfvars" ]]; then
  root="${2:-}"
  fun="Fleet.Application.CatalogueRoles.eval_main"
  [[ "${1}" == "roles-tfvars" ]] && fun="Fleet.Application.CatalogueRoles.eval_tfvars"
  if [[ -n "$root" ]]; then arg="\"${root}\""; else arg="Fleet.Catalogue.root()"; fi
  drop_priv \
    env HOME=/tmp RELEASE_TMP=/tmp LCARS_TOOL_EVAL=1 \
    /local/LCARS_v2/rel/lcars_fleet/bin/lcars_fleet eval \
    "${fun}(${arg})"
fi

# `catalogue-root` : OU LE RELEASE PORTE SON CATALOGUE DE REFERENCE. Une ligne, un chemin.
#
# Il existe pour que personne ne RECOMPOSE ce chemin. Il vit dans le release, sous un repertoire qui
# porte la VERSION (`lib/lcars_fleet-<vsn>/priv/catalogue`) : un appelant shell qui le globberait
# marcherait jusqu'au jour ou la disposition du release change, et casserait alors en silence sur
# un glob vide. Le release est l'autorite de sa propre disposition, et c'est lui qu'on interroge.
#
# Meme porte outil que `verify` et `roles` — meme eval, meme `nobody`, meme `LCARS_TOOL_EVAL`.
#
# ⚠ CE DRAPEAU SAUTE LE CORPS DE CONFIG DE DEPLOIEMENT, donc un `LCARS_CATALOGUE_ROOT` pose par
# l'operateur n'est PAS lu ici — et c'est ce qu'on veut. Cette porte repond « le catalogue que CE
# RELEASE porte », pas « celui que cette boite sert ». C'est le premier qu'on publie sur la forge :
# la reference, celle qu'on forke, pas la variante locale de quelqu'un.
if [[ "${1:-}" == "catalogue-root" ]]; then
  drop_priv \
    env HOME=/tmp RELEASE_TMP=/tmp LCARS_TOOL_EVAL=1 \
    /local/LCARS_v2/rel/lcars_fleet/bin/lcars_fleet eval \
    'IO.puts(Fleet.Catalogue.root())'
fi

# `forge-apply` : LA STRUCTURE DE LA FORGE, POSEE PAR UN RUN TRANSITOIRE ─────────────────────────
#
# Meme geste que `docker.sh forge-apply`, mais SANS boite vivante : `docker run --rm <image>
# forge-apply`. C'est ce qui permet a un POSTE DE TRAVAIL (rail WSL) d'avoir une forge utilisable
# sans reconstruire et relancer un LCARS en conteneur alors qu'il vient de l'installer nativement.
#
# ⚠ CETTE PORTE N'EST PAS `nobody`, CONTRAIREMENT AUX AUTRES. `roles`, `catalogue-source` et
# consorts sont des LECTURES ; celle-ci ecrit sur une forge et lit le jeton master et le seed dans
# `/home/private` (0750 root:fleet). Elle tourne donc en root, et l'appelant DOIT monter ce dossier.
#
# ⚠ ET L'ETAT DE TOFU N'A PAS BESOIN DE SURVIVRE — c'est le design, pas un pis-aller : la recette
# reconstruit ce qui existe par ses blocs `import`, donc partir d'un tfstate VIDE est le cas normal.
# C'est exactement pourquoi `--tofu-dir` est devenu un argument ignore. Un run `--rm` est donc
# legitime ici, la ou il aurait ete un piege avant ce chantier.
#
# L'appelant fournit : `--network <reseau-de-la-forge>`, `-v /home/private:/home/private`,
# `-e FORGE_BASE_URL=http://forge:3000`. Le jeton peut aussi arriver sur stdin (jamais en argv).
if [[ "${1:-}" == "forge-apply" ]]; then
  [[ "$(id -u)" -eq 0 ]] || { echo "forge-apply: cette porte ecrit et lit /home/private — elle exige root dans le conteneur" >&2; exit 1; }
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
  drop_priv \
    env HOME=/tmp RELEASE_TMP=/tmp LCARS_TOOL_EVAL=1 \
    FORGE_BASE_URL="${FORGE_BASE_URL:-}" FORGE_TOKEN_FILE="${FORGE_TOKEN_FILE:-}" \
    /local/LCARS_v2/rel/lcars_fleet/bin/lcars_fleet eval \
    "Fleet.Application.CatalogueLifecycle.eval_source(\"${name}\")"
fi

# admiral = le master/sysadmin (uid 1000 reserve, sudo root). Bench: `admiral`. Prod: le login que
# l'installeur a cree sur SA forge. Ce n'est PAS un worker de la fleet — Guard B refuse de lancer une
# fleet sous cet uid, et les workers viennent du convergeur (forge fleet:humans, uid >= 1001).
LCARS_UID="${LCARS_UID:-1000}"
PROVISION=/opt/lcars/fleet/deploy/provision
HOST_KEYS_DIR=/home/.lcars-container/ssh
# ⚠ LA MEME TABLE QUE LE CONVERGEUR, ET C'EST TOUT L'INTERET. Le siege est le #1 de la forge : son
# enregistrement est donc la LIGNE `forge_id = 1` de `forge-uid.map`, pas un fichier a lui. Une
# seconde table pour tenir une ligne de la premiere aurait fait deux verites d'un meme fait — celle
# qu'on ne lit pas finit toujours par mentir — et deux formats a maintenir la ou le convergeur en a
# deja un (`<forge_id>\t<uid>\t<login>`, keye sur l'id parce que Gitea le conserve au renommage).
UID_MAP_FILE="${LCARS_UID_MAP_FILE:-/home/private/forge-uid.map}"
MASTER_TOKEN_FILE="${LCARS_MASTER_TOKEN_FILE:-/home/private/forge-master.token}"

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
# ⚠ ET ELLE NE DOIT PAS AVOIR DE DEFAUT PLUS HAUT. Les composes posaient
# `LCARS_ADMIRAL: "${LCARS_ADMIRAL:-admiral}"` : la variable etait alors TOUJOURS definie dans le
# conteneur, la premiere branche court-circuitait tout, et la derivation ne s'executait JAMAIS. Une
# semence qui a un defaut est un defaut, et c'est la coincidence a sa source.
#
# ⚠ LE VERROU N'EST PAS L'ORDRE, C'EST LE JETON. L'en-tete de ce fichier disait « pas de check
# runtime possible (la forge n'est pas jointe au moment du useradd) » : vrai de la CONVERGENCE, qui
# vient a l'etape 3. Resoudre le #1 ne demande que le jeton master, et il vit dans le VOLUME — donc
# il precede l'entrypoint des que l'operateur a configure sa boite.
resolve_admiral() {
  local from_table tok resolved
  if [[ -n "${LCARS_ADMIRAL:-}" ]]; then
    say "siege : « $LCARS_ADMIRAL » seme par l'appelant (LCARS_ADMIRAL) — cas from-scratch, rien a deriver"
    seat_record "$LCARS_ADMIRAL"
    return 0
  fi
  # 1. La table du volume : elle survit au conteneur, `/etc/passwd` non. Aucune forge necessaire, et
  #    c'est ce qui rend un redemarrage possible pendant que la forge est en carafe.
  from_table="$(seat_from_map)"
  if [[ -n "$from_table" ]]; then
    LCARS_ADMIRAL="$from_table"
    say "siege : « $LCARS_ADMIRAL » (table $UID_MAP_FILE, forge_id 1)"
    return 0
  fi
  # 2. Le #1 de la forge, resolu par son ID et jamais par son nom — Gitea conserve l'`id` au
  #    renommage, le login est une etiquette. Puis ENREGISTRE : le boot suivant ne demandera rien.
  tok="$(tr -d '[:space:]' < "$MASTER_TOKEN_FILE" 2>/dev/null || true)"
  if [[ -n "$tok" && -n "${FORGE_BASE_URL:-}" ]]; then
    # `-K -` : le jeton ne passe pas par argv, lisible dans /proc de tout l'hote (cicatrice 6-141).
    resolved="$(printf 'header = "Authorization: token %s"\n' "$tok" \
                | curl -sS -K - -m 15 "${FORGE_BASE_URL%/}/api/v1/admin/users?limit=50" 2>/dev/null \
                | jq -r 'map(select(.id == 1)) | .[0].login // empty' 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
      LCARS_ADMIRAL="$resolved"
      seat_record "$LCARS_ADMIRAL"
      say "siege : « $LCARS_ADMIRAL » derive du #1 de ${FORGE_BASE_URL%/} — enregistre"
      return 0
    fi
  fi
  # 3. Ni semence, ni table, ni forge : sur un rail reel, ce triplet n'arrive pas. On REFUSE plutot
  #    que de nommer — un siege invente s'installe dans le volume et survit a la cause qui l'a
  #    produit, alors qu'un refus se lit et se repare.
  say "siege : IMPOSSIBLE a determiner — ni semence (LCARS_ADMIRAL), ni ligne forge_id=1 dans $UID_MAP_FILE, ni #1 lisible sur ${FORGE_BASE_URL:-<aucune forge configuree>} ($([[ -z "$tok" ]] && echo "jeton master illisible : $MASTER_TOKEN_FILE" || echo 'forge muette')). « box config » pose la forge et son jeton ; le bench, lui, seme le nom."
  return 1
}

seat_from_map() { # le login du siege, ou vide — la ligne `forge_id = 1` de la table du convergeur
  [[ -r "$UID_MAP_FILE" ]] || return 0
  awk -F'\t' '$1 == 1 { print $3; exit }' "$UID_MAP_FILE" 2>/dev/null
}

# ⚠ ECRIT UNE FOIS, JAMAIS RE-ECRIT. Le home du siege vit dans le volume sous son nom ; changer le
# nom au boot suivant laisserait un home orphelin et un compte qui ne le retrouve pas. La premiere
# resolution fait foi — c'est elle qui correspond a ce qui est sur le disque.
#
# Le format est celui du convergeur (`<forge_id>\t<uid>\t<login>`) parce que c'est la MEME table :
# le siege y est la ligne 1, les humains de fleet les autres. Une seconde table pour tenir une ligne
# de la premiere ferait deux verites d'un meme fait.
seat_record() { # seat_record <login>
  [[ -n "${1:-}" ]] || return 0
  [[ -n "$(seat_from_map)" ]] && return 0
  mkdir -p "$(dirname "$UID_MAP_FILE")" 2>/dev/null || true
  if printf '1\t%s\t%s\n' "${LCARS_UID:-1000}" "$1" >> "$UID_MAP_FILE" 2>/dev/null; then
    chmod 0640 "$UID_MAP_FILE" 2>/dev/null || true
  else
    say "siege : nom NON enregistre dans $UID_MAP_FILE — le boot suivant le re-derivera"
  fi
}

# ─── 1. L'humain (idempotent — le home vit dans le volume, le user est recréé à l'identique) ─────
#
# Le nom se résout ICI et pas au chargement : c'est le premier geste qui en a besoin, et une
# résolution jouée au `source` rendrait la fonction non rejouable — elle verrait sa propre sortie
# comme un `LCARS_ADMIRAL` imposé par l'opérateur.
# ⚠ LE REFUS EST EXPLICITE, PAS UN EFFET DE `set -e`. Un `resolve_admiral` nu mourrait aussi, mais
# sur le code de retour d'une fonction — et le lecteur suivant ne saurait pas si c'est voulu. Ici le
# boot s'arrete parce qu'on a decide qu'un siege inventable ne s'invente pas.
resolve_admiral || exit 1
if ! getent passwd "$LCARS_ADMIRAL" >/dev/null; then
  useradd -m -u "$LCARS_UID" -s /bin/bash "$LCARS_ADMIRAL"
  say "sysadmin $LCARS_ADMIRAL cree (uid $LCARS_UID)"
fi
# root du sysadmin : membre du groupe sudo (le paquet sudo pose la regle %sudo par defaut). Idempotent.
# Le mot de passe est POSE HORS d'ici (bench: fixe, pour tester ; prod: l'installeur) — l'entrypoint
# cree le siege, il ne choisit pas le secret.
getent group sudo >/dev/null 2>&1 && usermod -aG sudo "$LCARS_ADMIRAL" || true

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
# Mesure du 2026-08-09, sur un banc neuf : la face `doc` etait posee dans le code et dans l'etage
# `build` de l'image (pour le gate), et PAS ici. La boite avait l'air saine, la fleet demarrait,
# et le premier `create_project` mourait sur « could not make directory (with -p)
# "/home/projects.workshop": permission denied » — le runtime tourne sous l'humain, `/home` est a root,
# donc creer la zone n'est PAS un geste qu'il peut rattraper. La divergence est tenue par le check
# `layout.face_roots_provisioned` de `mix lcars.contracts.check` : ajouter une face sans l'ajouter
# ici fait rougir le gate, en la NOMMANT.
install -d -m 2775 -g fleet /home/projects /home/projects.ops /home/projects.workshop
say "zones de face : /home/projects /home/projects.ops /home/projects.workshop (2775 root:fleet)"

# La SOURCE — l'auto-maintenance en dépend : c'est le checkout que la fleet lit, met à jour
# (`provision update`) et sur lequel ses agents travaillent.
#
# DEUX CHEMINS, ET UN SEUL EST CELUI D'UNE INSTALLATION. Le geste de dév est `./docker.sh
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
# Ce bloc posait `user.name`/`user.email` de `LCARS_HUMAN` — l'unique humain de la boîte à l'époque.
# `identity-v2` a fait de l'entrée du conteneur le SYSADMIN et confié les humains à la team
# `humans` : la substitution `LCARS_HUMAN` → `LCARS_ADMIRAL` a suivi mécaniquement, et l'identité a
# atterri sur le seul compte qui ne commite jamais, pendant que le boot annonçait « identité git
# seedée » à chaque démarrage. Un humain enrôlé après le boot n'était de toute façon pas atteignable
# d'ici.
# C'est `70-human` qui la porte désormais, per-humain, DÉRIVÉE DU COMPTE FORGE — la seule adresse
# qui mappe un commit sur un compte (avatar compris). Une variable d'install n'en était qu'une copie.

if [[ -d "$LCARS_SOURCE_DIR/.git" ]]; then
  # git refuse un repo d'un autre owner (« dubious ownership ») : le clone vient de l'hôte,
  # son uid n'a aucune raison d'être celui du conteneur. Déclaré safe pour TOUS les humains.
  git config --system --replace-all safe.directory "$LCARS_SOURCE_DIR" 2>/dev/null || true
  src_rev="$(git -C "$LCARS_SOURCE_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo '?')"
  say "source LCARS : $LCARS_SOURCE_DIR ($src_rev) — auto-maintenance possible"

  # LE CONTRÔLE QUI FERME LA BOUCLE. Le binaire qui tourne vient de l'IMAGE ; la source vient du
  # clone. Rien ne garantit que ce sont les mêmes commits — et une source en avance est le cas
  # NORMAL (c'est le but de l'auto-maintenance), pas une panne. Ce qui n'est pas normal, c'est de
  # ne pas le savoir : on lit du code qui n'est pas celui qui s'exécute. On déclare l'écart, on ne
  # le corrige pas et on ne bloque rien.
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
  say "  dév     : ./docker.sh source-push (docker cp depuis ton clone)"
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
# rc capturé, jamais fatal : le doctor dira la vérité, sshd doit démarrer pour permettre la
# réparation. (Le détail des verdicts est dans les logs du conteneur.)
#
# ⚠ ET LE VERDICT SE PUBLIE, parce que « jamais fatal » n'a jamais voulu dire « jamais dit ». Il ne
# vivait que dans les logs du conteneur, donc `./docker.sh up` rendait la main sur une boîte qui
# annonce « fleet up », se déclare *healthy* (son healthcheck teste le port 22) et ne peut démarrer
# AUCUN pod. Un opérateur n'a aucune raison d'aller lire des logs après une commande qui a dit oui.
#
# `/run` et pas un volume : c'est un tmpfs, donc le fichier meurt avec le conteneur et décrit
# TOUJOURS ce boot-ci. Même emplacement et même motif que `/run/lcars-converger.refused` — un
# composant sait pourquoi, il l'écrit là où un autre peut le lire.
PROV_RC_FILE=/run/lcars-provision.rc
prov_rc=0
"$PROVISION" apply --substrate docker --human "$LCARS_ADMIRAL" || prov_rc=$?
case "$prov_rc" in
  0) say "provision apply : convergé" ;;
  # 2 = appliqué, état-cible non tenu. Confondu avec « AU MOINS UN ÉCHEC » jusqu'ici — et avant
  # 6-101 il ne remontait pas du tout : le module rendait 0 et la boîte annonçait « convergé ».
  2) say "provision apply : APPLIQUÉ, DRIFT RÉSIDUEL — rien n'est cassé, un geste manque (forge,
credentials, réseau). Détail : $PROVISION doctor" ;;
  *) say "provision apply : AU MOINS UN ÉCHEC (rc=$prov_rc) — la boîte démarre quand même ; diagnose : $PROVISION doctor" ;;
esac

# APRÈS le `case`, pas dedans : le verdict se publie quel qu'il soit, y compris 0. Un fichier qui
# n'apparaît que sur l'échec forcerait son lecteur à distinguer « pas encore écrit » de « tout va
# bien », c'est-à-dire à deviner exactement ce que ce fichier existe pour dire.
printf '%s\n' "$prov_rc" > "$PROV_RC_FILE" 2>/dev/null || true
chmod 0644 "$PROV_RC_FILE" 2>/dev/null || true

# ─── 3ter. Convergence CONTINUE des humains (forge `humans` → users Linux) ───────────────────────
# L'étape 3 converge un état FIGÉ, au boot. Enrôler quelqu'un demandait donc un redémarrage — ce qui
# était défendable en 1976. Cette boucle poursuit le même état-cible pendant toute la vie de la
# boîte : elle lit la team `humans` au token système et crée les users manquants. Elle tourne en
# root parce que root tourne DÉJÀ ici en permanence (sshd juste dessous) — pas de `sudo` à
# installer, pas de droit à accorder à quiconque.
# Elle ne SUPPRIME jamais : la révocation est un retrait côté forge, et ce qui reste sur la machine
# est de la donnée, pas un accès (sans compte forge, ni console ni fleet ne s'ouvrent).
if [[ "${LCARS_CONVERGE_HUMANS:-1}" == "1" && -x /opt/lcars/human-converger.sh ]]; then
  # Détaché du shell de l'entrypoint : celui-ci finit sur `exec sshd`, ce qui remplace le process.
  # Un enfant simplement mis en arrière-plan survit à l'exec (même PID 1 tini le récolte), mais
  # setsid le détache aussi du terminal, donc un signal de session ne l'emporte pas avec elle.
  setsid /opt/lcars/human-converger.sh </dev/null >>/var/log/lcars-converger.log 2>&1 &
  say "convergence des humains ACTIVE (pid $!) — un ajout à la team « humans » suffit, sans redémarrage"
else
  say "convergence des humains DÉSACTIVÉE — enrôler quelqu'un exige un geste manuel dans la boîte"
fi

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
  # ⚠ ET SON ÉCHEC N'EST PLUS DÉGRADÉ, IL EST TOTAL. Ce message disait « les consoles restent
  # joignables par leur port » : c'était vrai quand chaque terminal publiait le sien, et c'est
  # devenu faux le jour où ils sont passés sur des sockets (6-072/6-098). Le landing est désormais
  # le SEUL chemin vers eux — c'était le but — donc s'il ne démarre pas, aucune console n'est
  # atteignable, et seul ssh reste. Un message de repli qui annonce un repli disparu ment à
  # l'opérateur au pire moment : celui où quelque chose vient déjà d'échouer.
  if [[ "${LCARS_LANDING:-1}" == "1" ]]; then
    /opt/lcars/console-landing.sh \
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
#
# ⚠ SON ABSENCE N'EST PAS FATALE, ET ELLE N'EST PAS MUETTE NON PLUS. Sans lui, installer un
# catalogue devient injouable — mais la boîte doit rester joignable pour être réparée, même règle
# que la convergence et la console. Le refus côté `bin/lcars` nomme alors le service, pas l'adminité
# de l'opérateur : une porte fermée n'est pas une porte gardée.
if [[ "${LCARS_CATALOGUE_EXECUTOR:-1}" == "1" && -r /opt/lcars/catalogue-executor.py ]]; then
  setsid python3 /opt/lcars/catalogue-executor.py </dev/null >>/var/log/lcars-catalogue.log 2>&1 &
  say "executeur de catalogue ACTIF (pid $!) — « lcars catalogue install » passe par lui"
else
  say "executeur de catalogue ABSENT — « lcars catalogue install » refusera, en nommant ce service"
fi

# ─── 4. sshd au premier plan (tini est PID 1 : reap + signaux ; exec = sshd reçoit les signaux) ──
say "sshd prêt — ssh $LCARS_ADMIRAL@<hôte> -p <port mappé> puis « fleet_v2 start »"
exec /usr/sbin/sshd -D -e
