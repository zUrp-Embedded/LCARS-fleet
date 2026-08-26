#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/25-directories.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — arborescence systeme : /local + /home/private, les ZONES DE FACE, et la racine
#         des sockets de console sous /run (avec sa declaration tmpfiles, car /run est un tmpfs)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
# DEUX dossiers systeme, et les zones de face. (La v1 en posait une dizaine — commons, handoffs,
# fleet-state, spool, projects, tmp — pour l'IPC de sa fleet bash ; le runtime v2 n'a besoin
# d'AUCUN d'eux : son etat vit sous ~/.lcars per-humain, pose par `fleet_v2 start` lui-meme.)
#
#   /local          0755 root:root — les prefixes d'install y sont crees par 60-deploy ;
#                   root-only en ecriture = personne ne remplace un runtime deploye par surprise.
#   /home/private   0710 lcars-authority:fleet — les secrets de forge de la boite (jetons de role,
#                   jeton master, seed). UN SEUL process les OUVRE : le service d'autorite.
#                   ⚠ `0710` ET PAS `0700` : le groupe TRAVERSE, il ne LISTE pas. Ce repertoire ne
#                   contient pas que des secrets — `forge.url` et `forge.public.url` y sont en 0644,
#                   et trois modules `NEEDS: human` les lisent SOUS L'HUMAIN via `as_human`. En 0700
#                   ils prenaient « Permission denied », `PROV_FORGE_URL` restait vide, et
#                   `fleet_v2.env` n'obtenait jamais son `FORGE_BASE_URL` (mesure du 2026-08-25).
#                   ⚠ IL ETAIT `0750 root:fleet`, ET LE GROUPE ETAIT UNE PROJECTION. Le convergeur
#                   remplissait `fleet` depuis l'equipe `humans` de la forge toutes les 30 s : le
#                   droit de lire un credential avait donc la peremption d'un cache, et se retirer
#                   demandait un `pkill`. Le BEAM ne lit plus rien ici — il DEMANDE au service, qui
#                   pose la question a la forge a l'instant du geste.
#                   ⚠ ROOT TRAVERSE ENCORE, et c'est ce qui fait tenir le provisionnement : les
#                   modules qui ecrivent ici tournent en root et ignorent le mode. Ce qui est
#                   ferme, c'est l'uid HUMAIN.
#
# ─── LES ZONES DE FACE, ET POURQUOI ELLES SONT ICI ────────────────────────────────────────────
# Une racine par face — le miroir shell de `Fleet.Layout.face_root/1`, tenu en phase avec lui par
# le contrat `layout.face_roots_provisioned` de `mix lcars.contracts.check`.
#
# ELLES N'ETAIENT CREEES QUE PAR L'ENTRYPOINT DOCKER, et le rail reconnait TROIS substrats. Sur
# `wsl` elles existaient « par histoire du substrat » — c'est-a-dire a la main, un jour, sur la
# machine de l'auteur — et sur un `linux` natif, pas du tout. Le runtime tourne sous l'humain et
# `/home` appartient a root : creer la zone n'est donc PAS un geste qu'il peut rattraper. La boite
# demarrait saine et le premier onboarding mourait sur un `permission denied`, exactement comme la
# face `doc` absente de l'entrypoint l'avait fait le 2026-08-09 — meme panne, sur le chemin que le
# contrat ne couvrait pas.
#
# setgid + groupe fleet : chaque humain du groupe cree ses projets et ses worktrees dans la zone,
# et ce qu'il y pose reste lisible par les autres. Un `mkdir` de rattrapage cote runtime herite de
# l'umask, donc sans setgid ni groupe — le partage se casse en silence, ce qui est pire que
# l'echec franc.
#
# ⚠ L'entrypoint docker garde SA propre creation de ces memes zones, et ce n'est pas un doublon
# oublie : il clone la source dans `/home/projects/LCARS` bien AVANT d'appeler `provision apply`,
# donc les zones doivent exister plus tot que ce module ne tourne. Les deux miroirs sont tenus par
# le meme contrat, qui les compare tous les deux a `Fleet.Layout` — l'ordre de boot est la raison
# d'etre du second, pas une negligence.
#
# CHAQUE dossier est pose creation+mode+owner en un geste convergent (la v1 separait mkdir des
# perms → un crash entre les deux laissait des dossiers ownes root par defaut, silencieusement).

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# LA TABLE, source unique des deux modes. `check` et `apply` la déroulent tous les deux : une
# entrée ajoutée ici est vérifiée ET posée, sans qu'on puisse en oublier la moitié.
# Les zones de face sont le MIROIR SHELL de `Fleet.Layout.face_root/1` — en ajouter une sans
# l'ajouter là-bas (ou l'inverse) fait rougir `layout.face_roots_provisioned`, en la NOMMANT.
# ⚠ LES DEUX ZONES CATALOGUE N'ONT PAS LE MEME MODE, ET LA DIFFERENCE EST LEUR CONTENU.
# `$PROV_CATALOGUES_DIR` (le materiel installe) est du METIER : les cap-profiles, les cartes, les
# prompts. Il se LIT — chaque fleet humaine, et les pods par leurs mounts — donc `0750 root:fleet`.
# `$PROV_CATALOGUES_WORK` (les recettes tofu par catalogue) porte l'ETAT terraform, qui contient
# les valeurs des variables : le mot de passe de seed y figure. Donc `0700 root:root`.
#
# ⚠ PLUS AUCUN GROUPE N'Y ECRIT, ET C'EST LE CHANGEMENT. Les deux zones etaient `2775`/`2770` sur un
# groupe d'admins, avec le setgid pour qu'un second admin puisse reprendre le travail du premier :
# il fallait que des HUMAINS ecrivent ici, parce que le geste d'install tournait sous leur uid.
# Il tourne maintenant dans un service root (`catalogue-executor.py`), donc un seul ecrivain, donc
# ni groupe d'ecriture ni setgid a tenir. Ce qui reste est une question de LECTURE, et elle se
# repond par `fleet` pour le materiel et par personne pour l'etat.
# ─── LA RACINE DES SOCKETS DE CONSOLE — SANS ELLE LA FLEET NE BOOTE PAS ─────────────────────────
# MEME CICATRICE QUE LES ZONES DE FACE, UN SITE PLUS LOIN. `Fleet.Observation` fait ecouter le deck
# sur `/run/lcars/console/<humain>/deck.sock`, et ce dossier n'etait cree QUE par `console.sh`,
# artefact de CONTENEUR (`/opt/lcars/console.sh`, appele par l'entrypoint). Une install native ne le
# joue jamais, donc le dossier n'existait pas, donc Ranch echouait a binder et — `max_restarts: 0`
# au sommet — le node MOURAIT au boot :
#
#   [error] Failed to start Ranch listener {Fleet.EventRouter.UnixListener, 3205} … ip: {:local,
#   "/run/lcars/console/lcars/deck.sock"} … for reason :enoent (no such file or directory)
#
# Mesure du 2026-08-20 sur le poste natif : `provision apply` vert sur ses 14 modules, release
# posee, `fleet_v2 start` annoncant « fleet up » — et zero `beam.smp` une seconde plus tard. Le
# lanceur ne ment pas, il rend la main avant que le BEAM ne meure.
#
# ⚠ SUR `docker` ON NE TOUCHE A RIEN : `console.sh` y possede ces dossiers. Deux createurs pour un
# meme dossier donneraient un mode qui depend de qui a couru le premier — et `install -d` ne repose
# PAS le mode d'un dossier existant, donc le desaccord serait SILENCIEUX.
#
# ⚠ LE GROUPE EST CELUI DE LA CONSOLE, PAS CELUI DE LA FLEET, ET CETTE LIGNE A PORTE `fleet` JUSQU'AU
# 2026-08-21. Le motif ecrit ici disait « un groupe que seule l'image cree » — c'etait vrai, et c'est
# devenu une raison de se tromper : le rail poste a cable `$PROV_FLEET_GROUP` faute de mieux, au lieu
# de creer le groupe manquant. `20-groups` le pose desormais.
#
# Ce que ca coutait, mesure sur un poste natif : `/run/lcars/console/lcars` en `lcars:fleet`, le deck
# sous `nobody:lcars-console`, traversee REFUSEE par le noyau. Une console vivante, une socket bien
# posee, et une page noire — sans une ligne d'erreur nulle part, parce que du point de vue de chaque
# composant tout etait conforme.
#
# Et `fleet` etait le mauvais groupe pour une raison de fond, pas seulement d'accord : il porte deja
# la lecture de `/local/LCARS_v2`, des role-tokens et de `/home/private`. Le donner au deck pour qu'il
# traverse un repertoire lui aurait accorde tout le reste au passage.
# ⚠ LE DOSSIER DE CONSOLE APPARTIENT A QUI LANCE LA FLEET, PAS A `--human`. Ce sont deux personnes
# differentes sur le rail poste : `--human` est l'OPERATEUR (SUDO_USER), presque toujours l'uid 1000
# que GUARD B reserve au siege, et la fleet tourne sous l'HUMAIN DE FLEET pose par `22-fleet-human`.
# Le deck derive son chemin du `USER` du BEAM (`Fleet.Observation.deck_socket/0`), donc c'est cet
# humain-la qui doit posseder le dossier.
#
# Mesure du 2026-08-21, install a froid : `/run/lcars/console/lordzurp` cree, fleet lancee sous
# `lcars`, et le node MORT au boot sur `:enoent` — le meme echec que la veille, deplace d'un compte.
# Ce module est `NEEDS: root`, donc il n'est PAS rejoue par le second passage per-humain : il ne
# peut pas compter dessus pour rattraper, il doit viser juste du premier coup.
#
# ⚠ ET C'EST POURQUOI `22-fleet-human` PORTE LE NUMERO 22. Il s'appelait 65 : le compte etait donc
# cree APRES ce module, qui ne pouvait pas lui donner son dossier. Une identite precede les
# repertoires qu'elle possede — l'ordre est le prefixe, et le prefixe porte le sens.
prov_console_human() {
  # ⚖ AUCUN NOM PAR DÉFAUT (USER 2026-08-21). Tant que l'opérateur n'a pas NOMMÉ l'humain de fleet,
  # il n'y en a pas — et la console revient à `--human`, qui existe forcément.
  local h="${PROV_FLEET_HUMAN:-}"
  [[ -n "$h" ]] || { echo "$PROV_HUMAN"; return 0; }
  # Repli sur `--human` tant que l'humain de fleet n'existe pas : mieux vaut un dossier pour
  # quelqu'un que pas de dossier du tout, et le prochain apply corrigera. Sans ce repli, une
  # machine dont `22-fleet-human` a derive (useradd refuse) perdrait aussi sa racine de console.
  id -u -- "$h" >/dev/null 2>&1 && { echo "$h"; return 0; }
  echo "$PROV_HUMAN"
}

prov_runtime_dirs() {
  [[ "${PROV_SUBSTRATE:-}" == "docker" ]] && return 0
  local h; h="$(prov_console_human)"
  printf '%s\n' \
    "/run/lcars 0755 root:root" \
    "/run/lcars/console 0711 root:root" \
    "/run/lcars/console/$h 2710 $h:$PROV_CONSOLE_GROUP" \
    "/run/lcars/authority 0750 $PROV_AUTHORITY_USER:$PROV_FLEET_GROUP" \
    `# Le service privilégié est root : il POURRAIT créer sa socket dans /run/lcars (0755 root:root).` \
    `# Elle a quand même son répertoire, pour la même raison que la voisine — un répertoire par` \
    `# service rend l'ACL lisible d'un « ls », et une porte posée à la racine d'un arbre partagé se` \
    `# retrouve un jour balayée par le nettoyage de quelqu'un d'autre.` \
    "/run/lcars/privileged 0750 root:$PROV_FLEET_GROUP" \
    `# ⚠ CE REPERTOIRE VIVAIT HORS DE CETTE TABLE, ET IL NE SURVIVAIT PAS AUX REBOOTS. Son seul` \
    `# createur etait 45-sudoers-toolchain, en install -d nu. Or c'est CETTE table qui engendre le` \
    `# tmpfiles.d : un repertoire runtime qui n'y figure pas n'est pas recree au boot — il revient` \
    `# au prochain « provision apply ». Entre les deux, le reconciliateur de toolchain du BEAM (qui` \
    `# lit LCARS_TOOLCHAIN_RUN_STATE) ecrit dans un chemin absent.` \
    `#` \
    `# 2775 root:fleet — sgid et ecriture de groupe, parce que le BEAM ecrit le marqueur sous le` \
    `# groupe fleet et que root possede. Le manifeste annonçait « 0755 root:root » : faux sur le mode` \
    `# ET sur le groupe, dans le sens qui SOUS-ESTIME qui peut ecrire la. Les deux murs ISO comparent` \
    `# la PRESENCE d'un chemin, jamais son mode : c'est pour ca que rien ne l'a vu.` \
    "/run/lcars/toolchain 2775 root:$PROV_FLEET_GROUP"
}

prov_dirs() {
  printf '%s\n' \
    "/local 0755 root:root" \
    "$PROV_TOKENS_DIR 0710 $PROV_AUTHORITY_USER:$PROV_FLEET_GROUP" \
    "$PROV_CATALOGUES_DIR 0750 root:$PROV_FLEET_GROUP" \
    "$PROV_CATALOGUES_WORK 0700 $PROV_AUTHORITY_USER:$PROV_AUTHORITY_USER" \
    "/home/projects 2775 root:$PROV_FLEET_GROUP" \
    "/home/projects.ops 2775 root:$PROV_FLEET_GROUP" \
    "/home/projects.workshop 2775 root:$PROV_FLEET_GROUP"
  prov_runtime_dirs
}

# ─── ET ELLES DOIVENT SURVIVRE AU REBOOT, SANS QU'ON REJOUE QUOI QUE CE SOIT ────────────────────
# `/run` est un tmpfs : tout ce que le bloc ci-dessus y pose disparait a l'extinction. Sans cette
# declaration, la fleet demarrerait apres un `provision apply` et plus jamais apres un redemarrage
# de la machine — la pire des pannes, parce qu'elle arrive des jours plus tard et que rien dans le
# journal du reboot ne la relie a l'install.
#
# `tmpfiles.d` EST le mecanisme prevu pour ca, et il est DERIVE de la meme table : une seule source
# decrit ces dossiers, donc la version du boot ne peut pas diverger de celle de l'apply. Sans
# systemd (un conteneur, un chroot) on ne pose rien et on le DIT — un fichier de configuration pour
# un service absent n'est pas une garde, c'est un decor.
prov_tmpfiles_conf() { echo "${LCARS_TMPFILES_CONF:-/etc/tmpfiles.d/lcars-console.conf}"; }

prov_tmpfiles_body() {
  echo "# Genere par 25-directories.sh — /run est un tmpfs, ces dossiers s'y refont a chaque boot."
  echo "# NE PAS EDITER : la source est la table \`prov_runtime_dirs\` du module."
  local path mode owner
  while read -r path mode owner; do
    printf 'd %s %s %s %s -\n' "$path" "$mode" "${owner%%:*}" "${owner##*:}"
  done < <(prov_runtime_dirs)
}

check() {
  local spec path mode owner cur
  # La table est LA donnée ; le code ne fait que la dérouler (une entrée = "chemin mode owner:groupe").
  # `done < <(...)` et non `prov_dirs | while` : un pipe met la boucle dans un SOUS-SHELL, et les
  # compteurs de drift qu'y posent `p_drift`/`p_ok` meurent avec lui — le module rendrait « aucun
  # drift » en ayant vu tous les siens.
  while read -r spec; do
    read -r path mode owner <<< "$spec"
    if [[ ! -d "$path" ]]; then
      p_drift "$path absent"
      continue
    fi
    cur="$(stat -c '%a %U:%G' "$path")"
    if [[ "$cur" == "${mode#0} $owner" ]]; then
      p_ok "$path ($cur)"
    else
      p_drift "$path : $cur ≠ ${mode#0} $owner"
    fi
  done < <(prov_dirs)
  check_tmpfiles
  verdict_check
}

check_tmpfiles() {
  local conf; conf="$(prov_tmpfiles_conf)"
  if ! prov_runtime_dirs | grep -q .; then
    [[ -e "$conf" ]] && p_drift "tmpfiles: $conf present alors que ce substrat ne le porte pas"
    return 0
  fi
  if [[ ! -f "$conf" ]]; then
    p_drift "tmpfiles: $conf absent — /run/lcars/console ne se refera pas au reboot, et la fleet ne demarrera pas"
  elif [[ "$(cat "$conf")" != "$(prov_tmpfiles_body)" ]]; then
    p_drift "tmpfiles: $conf ne correspond plus a la table du module"
  else
    p_ok "tmpfiles: $conf"
  fi
}

# ⚠ LE PREMIER ÉCHEC TERMINAIT LA TABLE, ET UNE SEULE LIGNE COÛTAIT LES SEIZE AUTRES.
#
# `verdict_apply` fait `exit` (provision-lib:282). Écrit dans la BOUCLE, il transformait un chown
# raté en abandon du module : tout ce qui suivait dans la table n'était jamais posé, et
# `apply_tmpfiles` non plus.
#
# MESURE DU 2026-08-25, install réelle sur WSL. Un groupe manquant sur `/home/private` a coûté SEPT
# objets sans aucun rapport avec lui :
#   /home/projects · /home/projects.ops · /home/projects.workshop   les racines de face
#   /run/lcars/console · /run/lcars/console/<humain>                la racine des consoles
#   /var/lib/lcars/tofu                                             l'état terraform
#   /etc/tmpfiles.d/lcars-console.conf                              la persistance au reboot
# Le dernier porte son propre verdict : « /run/lcars/console ne se refera pas au reboot, et la fleet
# ne démarrera pas ». La machine s'est retrouvée avec `lcars-landing` « debout » et aucune racine de
# console — un demi-état qu'aucune ligne ne nommait.
#
# ⚠ `|| true` N'EST PAS UNE NÉGLIGENCE ICI, ET C'EST LA SEULE CHOSE À VÉRIFIER AVANT DE LE LIRE
# COMME TELLE. Le comptage a DÉJÀ eu lieu en amont : `ensure_dir`, `ensure_mode` et
# `prov_refuse_symlink_path` passent tous par `p_fail`, qui incrémente `PROV_FAILED`
# (provision-lib:221) — précisément ce que lit le `verdict_apply` de la fin. La boucle finit,
# `apply_tmpfiles` tourne, et le module sort quand même en 1.
#
# On ne change pas S'IL échoue, seulement QUAND il le dit. Une entrée mauvaise — groupe absent,
# mount pas prêt, disque plein — ne doit pas emporter tout l'arbre.
apply() {
  local spec path mode owner
  while read -r spec; do
    read -r path mode owner <<< "$spec"
    ensure_dir "$path" "$mode" "$owner" || true
  done < <(prov_dirs)
  apply_tmpfiles
  verdict_apply
}

apply_tmpfiles() {
  local conf; conf="$(prov_tmpfiles_conf)"
  local body; body="$(prov_tmpfiles_body)"

  # Rien a declarer (substrat docker) : on retire une declaration devenue fausse plutot que de la
  # laisser vivre. Un fichier tmpfiles qui decrit des dossiers dont ce module ne repond plus est un
  # ordre donne au boot par un composant qui a change d'avis.
  if [[ -z "${body//[$'\n'[:space:]#]/}" ]] || ! prov_runtime_dirs | grep -q .; then
    [[ -e "$conf" ]] && { rm -f "$conf" && p_ok "tmpfiles: declaration retiree ($conf) — ce substrat ne la porte pas"; }
    return 0
  fi

  if [[ ! -d "$(dirname "$conf")" ]]; then
    p_drift "tmpfiles: $(dirname "$conf") absent — les dossiers de /run ne se referont PAS au reboot"
    return 0
  fi

  # PAS D'OWNER NOMME, ET C'EST RAISONNE. Ce module declare `NEEDS: root` : le fichier est donc cree
  # PAR root, et ecrire `root:root` ne fait que redire ce que le processus garantit deja. En
  # revanche, ce mot rendait ce bloc intestable hors root — un harnais non privilegie mourait sur
  # « chown: Operation not permitted » pour une convergence qui n'avait rien a converger. Un
  # /etc/tmpfiles.d/*.conf qui n'appartiendrait pas a root n'est pas une derive a rattraper ici,
  # c'est une machine compromise.
  printf '%s\n' "$body" | write_atomic "$conf" 0644 || { p_fail "tmpfiles: $conf"; return 1; }

  # ⚠ ON NE JOUE PAS `--create` ICI : `apply()` vient de creer les memes dossiers, donc il n'y a rien
  # a rattraper, et `systemd-tmpfiles` rendrait non-nul pour des lignes SANS RAPPORT avec les notres
  # (il traite tout /etc/tmpfiles.d). Le fichier est pose pour le PROCHAIN boot ; ce boot-ci est deja
  # convergé par le bloc du dessus.
  if command -v systemd-tmpfiles >/dev/null 2>&1; then
    p_ok "tmpfiles: $conf pose — /run/lcars/console se refera au reboot"
  else
    p_drift "tmpfiles: $conf pose mais systemd-tmpfiles est ABSENT — au reboot, /run/lcars/console
     ne sera pas recree et la fleet ne demarrera pas tant que 'provision apply' n'aura pas rejoue"
  fi
}

case "${1:?usage: 25-directories.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
