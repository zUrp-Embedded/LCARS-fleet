#!/usr/bin/env bash
# SOURCE: deploy/modules.d/25-directories.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — arborescence systeme : /opt/lcars + sa zone de jetons, les ZONES DE FACE, et la racine
#         des sockets de console sous /run (avec sa declaration tmpfiles, car /run est un tmpfs)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
# AFTER: 20-groups 21-service-accounts

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

_PROV_CONSOLE_HUMAN=""
prov_console_human() {
  [[ -n "$_PROV_CONSOLE_HUMAN" ]] && { echo "$_PROV_CONSOLE_HUMAN"; return 0; }
  local h
  h="$(bash "$(product_tree)/services/forge-gestures.sh" builtin-human 2>/dev/null || true)"
  if [[ -z "$h" ]] || ! id -u -- "$h" >/dev/null 2>&1; then
    h="$PROV_HUMAN"
  fi
  _PROV_CONSOLE_HUMAN="$h"
  echo "$h"
}

prov_runtime_dirs() {
  # ⚠ RIEN SUR DOCKER, ET C'EST LA TABLE QUI LE DIT, PAS UN DRIFT. /run est un tmpfs : VIDE au build
  # de l'image, pose par `runtime/services/box/init.sh` au boot de l'instance — un fait de BOOT, pas
  # de l'image. Et sans systemd dans la boite, aucune declaration tmpfiles n'y a de sens. Une table
  # vide est exactement ce que `check_tmpfiles` lit comme « ce substrat ne le porte pas ». Sur la
  # boite, le stage `verify` joue ce module AU BUILD (lot 14) : ces six entrees y rendraient six
  # absents, et la sonde de l'humain integre interrogerait une forge qui n'existe pas encore.
  # Le substrat est celui que le runner a tranche (`provision --substrate`, exporte) ; la sonde
  # n'est qu'un repli — meme regle que `advertise_addr` dans la lib.
  [[ "${PROV_SUBSTRATE:-$(detect_substrate)}" != docker ]] || return 0
  local h; h="$(prov_console_human)"
  printf '%s\n' \
    "/run/lcars 0755 root:root" \
    "/run/lcars/console 0711 root:root" \
    "/run/lcars/console/$h 2710 $h:$PROV_CONSOLE_GROUP" \
    "/run/lcars/authority 0750 $PROV_AUTHORITY_USER:$PROV_FLEET_GROUP" \
    "/run/lcars/privileged 0750 root:$PROV_FLEET_GROUP" \
    `# 2775 root:fleet — sgid et ecriture de groupe, parce que le BEAM ecrit le marqueur sous le` \
    `# groupe fleet et que root possede. Le manifeste annonçait « 0755 root:root » : faux sur le mode` \
    `# ET sur le groupe, dans le sens qui SOUS-ESTIME qui peut ecrire la. Les deux murs ISO comparent` \
    `# la PRESENCE d'un chemin, jamais son mode : c'est pour ca que rien ne l'a vu.` \
    "/run/lcars/toolchain 2775 root:$PROV_FLEET_GROUP"
}

prov_dirs() {
  # ⚠ LE PREFIXE MANQUAIT A CETTE LISTE, ET PERSONNE NE LE POSAIT. La table le declare
  # `prefix /opt/lcars/runtime 0750 root:fleet` — mais aucun module ne le creait : c'est
  # `deploy/lib/deploy-release.sh:270` qui le faisait apparaitre par `mkdir -p "$PREFIX/bin" …`, et ce
  # script tourne sous `runuser -u bob`. Le prefixe naissait donc a l'identite de l'OPERATEUR.
  #
  # ⚠ INVISIBLE TANT QU'ON NE DESINSTALLE PAS, et c'est le cycle du rang D qui l'a trouve : sur une
  # machine ou le repertoire existe deja — pose une fois, correctement, par un geste ancien —
  # `mkdir -p` ne touche pas a ses droits. Il faut l'avoir RETIRE pour le voir renaitre en
  # `bob:fleet` : vu apres `uninstall --yes` puis re-apply.
  #
  # Une install qui reussit ne prouve rien de ce qu'elle laisse.
  printf '%s\n' \
    "$PROV_ROOT 0755 root:root" \
    "$PROV_PREFIX 0750 root:$PROV_FLEET_GROUP" \
    "$PROV_TOKENS_DIR 0710 $PROV_AUTHORITY_USER:$PROV_FLEET_GROUP" \
    "$PROV_CATALOGUES_DIR 0750 root:$PROV_FLEET_GROUP" \
    "$PROV_CATALOGUES_WORK 0700 $PROV_AUTHORITY_USER:$PROV_AUTHORITY_USER" \
    "/home/projects 2775 root:$PROV_FLEET_GROUP" \
    "/home/projects.ops 2775 root:$PROV_FLEET_GROUP" \
    "/home/projects.workshop 2775 root:$PROV_FLEET_GROUP" \
    `# ⚠ LES REPERTOIRES DE TRAVAIL DES GESTES ROOT — DECLARES A LA TABLE LE 2026-09-01, ET POSES` \
    `# PAR PERSONNE JUSQU'ICI. Mesure du 2026-09-02, banc 2006 : les deux sont ABSENTS apres un` \
    `# apply complet, alors que le manifeste les declare. Declarer sans poser ne ferme rien — ca` \
    `# deplace seulement le mensonge de la machine vers la table.` \
    `#` \
    `# ⚠ ET ISO 2/2 A LAISSE PASSER, POUR LA RAISON QU'IL DOCUMENTE LUI-MEME : il cherche le RADICAL` \
    `# du chemin dans le texte du code, et « toolchain-work » apparait dans` \
    `# bin/lcars-toolchain-converge — qui le LIT, ne le pose pas. Le mur a ete satisfait par une` \
    `# mention. Meme piege que « .hex » trouve dans « local.hex », deja nomme dans ce corpus.` \
    `#` \
    `# Le 0700 est le correctif : /var/tmp est 1777, et le rail doit POSSEDER ce chemin avant que` \
    `# le convergeur n'y telecharge puis n'y execute.` \
    "/var/lib/lcars 0755 root:root" \
    "/var/tmp/lcars 0755 root:root" \
    "/var/tmp/lcars/toolchain-work 0700 root:root" \
    `# ⚠ POSE PAR DEUX \`dirname\`, NOMME PAR PERSONNE — et c'est la meme situation que le prefixe` \
    `# ci-dessus. \`05-host-consent:51\` et \`64-services:427\` le creent en derivant le dossier de` \
    `# LEUR fichier ; aucun des deux ne le declare. Il nait donc du mode et du proprietaire que le` \
    `# premier arrive lui donne, et il disparaitrait le jour ou ces deux modules cesseraient d'y` \
    `# ecrire — sans que la table, qui le declare, ait bouge.` \
    `#` \
    `# Les deux \`dirname\` RESTENT : \`05-host-consent\` tourne au rang 05, vingt rangs avant ce` \
    `# poseur, et il a besoin du dossier a ce moment-la. Ce qu'on ajoute ici n'est pas la creation,` \
    `# c'est la CONVERGENCE — le mode et le proprietaire relus a chaque passe, depuis un seul site.` \
    "/etc/lcars 0755 root:root"
  prov_runtime_dirs
}

# ─── OU UNE ENTREE SE MESURE : LE MANIFESTE, ET LUI SEUL, DIT LE SUBSTRAT ─────────────────────
#
# ⚠ CE MODULE N'A PAS DE COLONNE SUBSTRAT, ET C'EST VOULU. `deploy/system.manifest` en porte une
# (cinquieme colonne) ; en recopier une ici ferait deux tables qui disent le meme fait, et deux
# tables divergent. `prov_manifest_substrate` (lib) la lit — meme geste que `prov_manifest_gid`.
# `prov_dirs` reste la table BRUTE (le mur POSEUR de `system_manifest.bats` l'enumere hors
# substrat) ; c'est ICI qu'une entree est retenue ou ecartee.
#
# Sur docker, ou le stage `verify` joue ce module au BUILD de l'image, deux familles d'entrees
# n'ont aucune verite :
#   substrate  le manifeste ne la declare pas pour docker (`prefix`, `/opt/lcars/var/tofu`) ;
#   volume     elle vit sur un VOLUME de la boite — `/home`, `/opt/lcars/var` (Dockerfile :
#              `VOLUME`) — que l'init de l'instance pose au boot, sur le volume monte. Au build
#              rien n'est monte : la mesurer rendrait un absent qui n'en est pas.
# Une entree que le manifeste NE CONNAIT PAS se mesure partout : au build, un absent NOMME vaut
# mieux qu'un silence, et le remede est de la declarer. Sur un poste, rien ne change : toutes les
# entrees de la table y sont declarees `any` ou `wsl+linux`, et il n'y a pas de volume.
prov_box_volumes() { printf '%s\n' /home "$PROV_ROOT/var"; }

# prov_dir_scope <chemin> -> here | substrate | volume
prov_dir_scope() {
  local path="$1" sub col v
  sub="${PROV_SUBSTRATE:-$(detect_substrate)}"
  col="$(prov_manifest_substrate "$path")"
  if [[ -n "$col" && "$col" != any ]]; then
    case "+$col+" in *"+$sub+"*) ;; *) echo substrate; return 0 ;; esac
  fi
  if [[ "$sub" == docker ]]; then
    while read -r v; do
      if [[ "$path" == "$v" || "$path" == "$v"/* ]]; then echo volume; return 0; fi
    done < <(prov_box_volumes)
  fi
  echo here
}

# Ce qui n'est PAS mesure se DIT — on debranche nommement, jamais en baissant le verdict (la regle
# de la sonde bwrap de 10-packages sous PROV_KERNEL_PROBES=0). `p_warn` ne compte rien : c'est la
# voix de « non joue ici ». Sur un poste les deux listes sont vides et rien ne s'imprime.
say_unmeasured() { # say_unmeasured <hors substrat> <sur volume>
  local sub; sub="${PROV_SUBSTRATE:-$(detect_substrate)}"
  if [[ -n "$1" ]]; then p_warn "hors substrat $sub selon le manifeste — non mesure :$1"; fi
  if [[ -n "$2" ]]; then p_warn "sur un volume de la boite — pas de verite au build, l'init de l'instance les pose :$2"; fi
  return 0
}

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
  local spec path mode owner cur hors_substrat="" hors_build=""
  # `done < <(...)` et non `prov_dirs | while` : un pipe met la boucle dans un SOUS-SHELL, et les
  # compteurs de drift qu'y posent `p_drift`/`p_ok` meurent avec lui — le module rendrait « aucun
  # drift » en ayant vu tous les siens.
  while read -r spec; do
    read -r path mode owner <<< "$spec"
    case "$(prov_dir_scope "$path")" in
      substrate) hors_substrat="$hors_substrat $path"; continue ;;
      volume)    hors_build="$hors_build $path"; continue ;;
    esac
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
  say_unmeasured "$hors_substrat" "$hors_build"
  check_tmpfiles
  verdict_check
}

# ⚠ PAS DE `prov_runtime_dirs | grep -q .` ICI — DI-12. Sous `pipefail`, `grep -q` sort au premier
# match et ferme le tuyau ; si le producteur ecrit encore, il prend SIGPIPE et le pipeline rend 141 :
# la table « n'existait plus » une fois sur dix sous charge (trois temoins differents, meme cause).
# Capturer, puis tester la capture : aucun lecteur ne ferme rien avant la fin.
runtime_dirs_declared() { [[ -n "$(prov_runtime_dirs)" ]]; }

check_tmpfiles() {
  local conf; conf="$(prov_tmpfiles_conf)"
  if ! runtime_dirs_declared; then
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

apply() {
  local spec path mode owner hors_substrat="" hors_build=""
  while read -r spec; do
    read -r path mode owner <<< "$spec"
    case "$(prov_dir_scope "$path")" in
      substrate) hors_substrat="$hors_substrat $path"; continue ;;
      volume)    hors_build="$hors_build $path"; continue ;;
    esac
    ensure_dir "$path" "$mode" "$owner" || true
  done < <(prov_dirs)
  say_unmeasured "$hors_substrat" "$hors_build"
  apply_tmpfiles
  verdict_apply
}

apply_tmpfiles() {
  local conf; conf="$(prov_tmpfiles_conf)"
  local body; body="$(prov_tmpfiles_body)"

  if [[ -z "${body//[$'\n'[:space:]#]/}" ]] || ! runtime_dirs_declared; then
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
