#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/25-directories.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — arborescence systeme : /opt/lcars + sa zone de jetons, les ZONES DE FACE, et la racine
#         des sockets de console sous /run (avec sa declaration tmpfiles, car /run est un tmpfs)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
#   /opt/lcars      0755 root:root — LA RACINE UNIQUE. Le prefixe d'install (`PROV_PREFIX`) y est
#                   cree par 60-deploy ; root-only en ecriture = personne ne remplace un runtime
#   /opt/lcars/var/tokens   0710 lcars-authority:fleet — les secrets de forge de la boite (jetons de role,
#                   jeton master, seed). UN SEUL process les OUVRE : le service d'autorite.
#                   ⚠ ROOT TRAVERSE ENCORE, et c'est ce qui fait tenir le provisionnement : les
#                   modules qui ecrivent ici tournent en root et ignorent le mode. Ce qui est
#                   ferme, c'est l'uid HUMAIN.
#

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# LA TABLE, source unique des deux modes. `check` et `apply` la déroulent tous les deux : une
# entrée ajoutée ici est vérifiée ET posée, sans qu'on puisse en oublier la moitié.
# Les zones de face sont le MIROIR SHELL de `Fleet.Layout.face_root/1` — en ajouter une sans
# l'ajouter là-bas (ou l'inverse) fait rougir `layout.face_roots_provisioned`, en la NOMMANT.
#
# ⚠ LE DOSSIER DE CONSOLE APPARTIENT A QUI LANCE LA FLEET, PAS A `--human`. Ce sont deux personnes
# differentes sur le rail poste : `--human` est l'OPERATEUR (SUDO_USER), presque toujours l'uid 1000
# que GUARD B reserve au siege, et la fleet tourne sous l'HUMAIN DE FLEET, seme sur la forge par
# `48-forge-host` et materialise par le convergeur que `64-services` tire.
#
# ⚠ RESOLU UNE FOIS, ET SOUS LA GARDE DOCKER. `prov_runtime_dirs` est appelee quatre fois par passe ;
# sans memo, chacune forkerait le script d'autorite. Et l'appel vit DANS cette fonction, jamais au
# chargement du module : la boite n'a pas de table de runtime a produire, elle n'a pas a payer une
# resolution dont elle ne fera rien.
_PROV_CONSOLE_HUMAN=""
prov_console_human() {
  [[ -n "$_PROV_CONSOLE_HUMAN" ]] && { echo "$_PROV_CONSOLE_HUMAN"; return 0; }
  local h
  h="$(bash "$(repo_root)/fleet/services/forge-gestures.sh" builtin-human 2>/dev/null || true)"
  # Repli sur `--human` tant que l'humain de fleet n'existe pas : mieux vaut un dossier pour
  # quelqu'un que pas de dossier du tout. Sans ce repli, une machine ou le convergeur n'a pas encore
  # pose le compte perdrait AUSSI sa racine de console.
  #
  # ⚠ DEUX CONDITIONS, DEUX LIGNES. Un `[[ -n "$h" ]] && id … || h=…` les enchaine correctement, mais
  # il cache la troisieme branche qu'il produit — et ce fichier se relit plus souvent qu'il ne
  # s'ecrit.
  if [[ -z "$h" ]] || ! id -u -- "$h" >/dev/null 2>&1; then
    h="$PROV_HUMAN"
  fi
  _PROV_CONSOLE_HUMAN="$h"
  echo "$h"
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
    `# ⚠ CETTE LIGNE POSAIT "/local", ET C'ETAIT LE PARENT DU PREFIXE — rien d'autre. Le prefixe est` \
    `# descendu sous la racine unique, donc "/local" n'a plus de contenu et cesse d'etre pose. Ce` \
    `# qui compte est la PROPRIETE, pas le chemin : le parent du prefixe se pose explicitement, avec` \
    `# un mode connu, plutot que d'apparaitre par le "mkdir -p" du premier ecrivain.` \
    `# "/local" n'etait declare NULLE PART dans la table — il echappait au mur des objets poses,` \
    `# dont le scraper ne connaissait que "/local/LCARS_v2". Une racine invisible aux deux bouts.` \
    "$PROV_ROOT 0755 root:root" \
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
    if [[ -e "$conf" ]]; then
      if rm -f "$conf"; then p_ok "tmpfiles: declaration retiree ($conf) — ce substrat ne la porte pas"
      else p_fail "tmpfiles: declaration perimee ($conf) impossible a retirer — le boot suivant obeira encore a un ordre que ce module a desavoue"
      fi
    fi
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
  write_atomic "$conf" 0644 <<<"$body" || { p_fail "tmpfiles: $conf"; return 1; }

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
