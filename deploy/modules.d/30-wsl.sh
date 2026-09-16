#!/usr/bin/env bash
# SOURCE: deploy/modules.d/30-wsl.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: le substrat WSL — wsl.conf clé par clé (C: fermé, interop coupée, systemd, hostname), les projets ouverts au compte de Windows, snapd purgé, gpg-agent masqué, credsStore retiré, docker.io à côté de Docker Desktop refusé
# APPLY-ON: wsl
# CHECK-ON: wsl
# NEEDS: root
# AFTER: 10-packages 25-directories
#
# wsl.conf est le fichier de l'instance : chaque clé de l'état-cible s'y pose, le reste du fichier
# ([user] compris) est conservé. Il ne prend effet qu'après « wsl --shutdown » ; la sonde de C:
# mesure l'état réel, pas la configuration. Le hostname de l'instance prend la base du projet, que
# provision a validée comme étiquette DNS.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

WSL_CONF="$(prov_decor /etc/wsl.conf)"
SNAP_DIRS=("$(prov_decor /snap)" "$(prov_decor /var/snap)" "$(prov_decor /var/lib/snapd)")
HOSTNAME_CIBLE="${PROV_FORGE_BASE//_/-}"

# section clé valeur — l'état-cible entier ; [interop] coupée = pas d'exécutable Windows depuis l'instance
wsl_cles() {
  printf '%s\n' \
    "boot systemd true" \
    "automount enabled false" \
    "automount mountFsTab true" \
    "interop enabled false" \
    "interop appendWindowsPath false" \
    "network hostname $HOSTNAME_CIBLE"
}

dire_hostname() { # un hostname qui ne prend qu'au redémarrage se dit, au check comme à l'apply
  [[ "$(hostname)" == "$HOSTNAME_CIBLE" ]] || p_warn "hostname « $(hostname) » — « $HOSTNAME_CIBLE » prendra après « wsl --shutdown »"
}

ini_get() { # ini_get <fichier> <section> <clé> → la valeur, ou rien
  [[ -r "$1" ]] || return 0
  awk -v S="$2" -v K="$3" '
    /^[[:space:]]*\[.*\][[:space:]]*$/ { s=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", s); insec=(s==S); next }
    insec && $0 ~ "^[[:space:]]*" K "[[:space:]]*=" { v=$0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); print v; exit }
  ' "$1"
}

ini_set() { # ini_set <contenu sur stdin> <section> <clé> <valeur> → le contenu avec la clé posée, le reste intact
  awk -v S="$1" -v K="$2" -v V="$3" '
    function pose() { if (insec && !done) { print K "=" V; done=1 } }
    /^[[:space:]]*\[.*\][[:space:]]*$/ { pose(); s=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", s); insec=(s==S); if (insec) vue=1; print; next }
    insec && $0 ~ "^[[:space:]]*" K "[[:space:]]*=" { if (!done) { print K "=" V; done=1 }; next }
    { print }
    END { pose(); if (!vue) { if (NR > 0) print ""; print "[" S "]"; print K "=" V } }
  '
}

wsl_conf_cible() { # le contenu de wsl.conf avec l'état-cible posé sur le fichier tel qu'il est
  local contenu section cle valeur
  if [[ -s "$WSL_CONF" ]]; then contenu="$(cat "$WSL_CONF")"
  else contenu="# /etc/wsl.conf — les clés ci-dessous sont tenues par LCARS (deploy/modules.d/30-wsl.sh) ; le reste du fichier est à l'opérateur."
  fi
  while read -r section cle valeur; do
    contenu="$(printf '%s\n' "$contenu" | ini_set "$section" "$cle" "$valeur")"
  done < <(wsl_cles)
  printf '%s\n' "$contenu"
}

# la sonde de C: mesure l'état réel : root écrit partout, l'humain dit si C: est ouvert
c_drive_open() { # → 0 ouvert · 1 fermé · 2 non sondé, as_human a dit pourquoi
  local c; c="$(prov_decor /mnt/c)"
  [[ -d "$c" ]] || return 1
  local home; home="$(human_home)"
  [[ -z "$home" || -d "$home" ]] \
    || { p_warn "C: non sondé — le home de $PROV_HUMAN ($home) n'existe pas, et la sonde se joue sous son compte"; return 2; }
  as_human true || return 2
  local probe="$c/.lcars-lockdown-probe.$$"
  if as_human touch "$probe" 2>/dev/null; then
    as_human rm -f "$probe" 2>/dev/null || true
    return 0
  fi
  return 1
}

gpg_socket_mask_path() { # vide quand l'humain n'a pas de home — à l'appelant de le dire
  local home; home="$(human_home)"
  if [[ -n "$home" ]]; then echo "$home/.config/systemd/user/gpg-agent-ssh.socket"; fi
}

# docker.io à côté de Docker Desktop : deux daemons, et la socket de Desktop écrasée — un poste
# cassé, dit avec le geste entier, jamais retiré à l'insu de l'opérateur
docker_io_next_to_desktop() { pkg_installed docker.io && [[ -x "$(_docker_mount_cli)" ]]; }
DOCKER_IO_DESKTOP_GESTE="docker.io est posé À CÔTÉ de Docker Desktop : deux daemons, et /var/run/docker.sock de Desktop écrasé. Geste : « sudo apt purge docker.io containerd runc », puis Docker Desktop → Settings → Resources → WSL integration : décocher puis recocher ce distro (ou « wsl --shutdown ») pour qu'il retende le socket ; enfin « sudo dpkg --configure -a » et relancer"

wsl_conf_report() { # chaque clé de l'état-cible contre le fichier → 0 si toutes sont posées
  local section cle valeur lue conforme=1
  while read -r section cle valeur; do
    lue="$(ini_get "$WSL_CONF" "$section" "$cle")"
    if [[ "$lue" == "$valeur" ]]; then
      p_ok "$WSL_CONF : [$section] $cle=$valeur"
    else
      conforme=0
      p_drift "$WSL_CONF : [$section] $cle=${lue:-<absent>} — attendu $valeur"
    fi
  done < <(wsl_cles)
  [[ "$conforme" -eq 1 ]]
}

# ─── les projets vus de Windows ─────────────────────────────────────────────────────────────────
#
# Un projet appartient à l'humain de la fleet qui l'a créé, et le groupe fleet n'y a que la lecture :
# c'est l'isolation voulue entre humains. Windows ouvre les fichiers de l'instance sous le compte que
# wsl.conf déclare ([user] default), avec ses groupes — mesuré. Une entrée nominative pour ce seul
# compte, posée en accès et par défaut sur chaque racine de face, lui rend l'écriture sans ouvrir
# quoi que ce soit au groupe ; tout projet né ensuite en hérite. Ce geste n'a de sens que sous WSL :
# ailleurs, personne n'ouvre ces fichiers depuis un autre système.
ACL_DROITS=rwx

compte_windows() { # le compte sous lequel Windows ouvre les fichiers, ou rien (l'appelant le dit)
  local c
  c="$(ini_get "$WSL_CONF" user default)"
  if [[ -z "$c" ]]; then
    # wsl.conf ne nomme personne : WSL prendra le compte par défaut du distro, que ce fichier ne dit
    # pas. Le siège est le meilleur candidat — c'est le compte qui installe, et l'uid 1000 du distro.
    [[ "${LCARS_SYSADMIN_UID:-}" =~ ^[0-9]+$ ]] || return 0
    c="$(getent passwd | awk -F: -v u="$LCARS_SYSADMIN_UID" '$3 == u {print $1; exit}' || true)"
  fi
  [[ -n "$c" ]] && getent passwd "$c" >/dev/null 2>&1 || return 0
  printf '%s\n' "$c"
}

# les racines de face se lisent dans le manifeste : ce module n'en tient pas une copie de plus
faces_declarees() {
  awk '$1 == "dir" && $2 ~ /^\/home\/projects(\.[a-z]+)?$/ { print $2 }' "$PROV_MANIFEST_FILE"
}

acl_posee() { # acl_posee <chemin> <compte> → 0 si l'entrée d'accès ET celle par défaut sont là
  local lu
  lu="$(getfacl -pcE -- "$1" 2>/dev/null)" || return 1
  grep -qx "user:$2:$ACL_DROITS" <<<"$lu" && grep -qx "default:user:$2:$ACL_DROITS" <<<"$lu"
}

projets_report() { # projets_report <check|apply> — chaque racine de face contre l'entrée du compte
  local verbe="$1" compte racine chemin
  compte="$(compte_windows)"
  if [[ -z "$compte" ]]; then
    p_warn "compte de Windows inconnu : wsl.conf ne porte pas [user] default et aucun compte ne répond à l'uid du siège — les projets resteront en lecture seule depuis Windows"
    return 0
  fi
  if ! command -v setfacl >/dev/null 2>&1; then
    if [[ "$verbe" == apply ]]; then
      p_fail "setfacl absent (paquet acl, que 10-packages pose) — l'accès de « $compte » aux projets ne se pose pas"
    else
      p_drift "setfacl absent (paquet acl, que 10-packages pose) — l'accès de « $compte » aux projets ne se mesure ni ne se pose"
    fi
    return 0
  fi
  while read -r racine; do
    chemin="$(prov_decor "$racine")"
    if [[ ! -d "$chemin" ]]; then
      # une racine que 25-directories n'a pas posée est son affaire, pas la nôtre : dite, jamais
      # comptée en dérive à l'apply, où une dérive ferait rendre 2 à un module qui a tout fait
      if [[ "$verbe" == apply ]]; then
        p_warn "$chemin absent — 25-directories le pose, l'accès de « $compte » se posera à la passe suivante"
      else
        p_drift "$chemin absent — 25-directories le pose, l'accès de « $compte » se posera ensuite"
      fi
    elif acl_posee "$chemin" "$compte"; then
      p_ok "$chemin : « $compte » y écrit (ACL nominative, accès et défaut)"
    elif [[ "$verbe" != apply ]]; then
      p_drift "$chemin : « $compte » (le compte de Windows) n'y écrit pas — ACL nominative absente"
    elif setfacl -m "u:$compte:$ACL_DROITS" -m "d:u:$compte:$ACL_DROITS" -- "$chemin"; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "$chemin : « $compte » y écrit désormais — les projets nés ensuite en héritent, le groupe fleet reste en lecture"
    else
      p_fail "$chemin : ACL refusée pour « $compte » (setfacl) — ce système de fichiers porte-t-il les ACL ?"
    fi
  done < <(faces_declarees)
  return 0
}

check() {
  if docker_io_next_to_desktop; then
    p_drift "$DOCKER_IO_DESKTOP_GESTE"
  elif [[ -x "$(_docker_mount_cli)" ]]; then
    p_ok "docker.io absent — Docker Desktop est le daemon de ce distro"
  else
    p_ok "pas de Docker Desktop monté ici — docker.io (ou docker-ce) est le daemon, c'est voulu"
  fi
  if pkg_installed snapd; then
    p_drift "snapd présent (casse systemd --user sous WSL) — l'apply le purge"
  else
    p_ok "snapd absent"
  fi
  local mask; mask="$(gpg_socket_mask_path)"
  if [[ -n "$mask" && "$(readlink "$mask" 2>/dev/null)" == "/dev/null" ]]; then
    p_ok "gpg-agent-ssh.socket masqué ($PROV_HUMAN)"
  else
    p_drift "gpg-agent-ssh.socket non masqué pour $PROV_HUMAN (race shutdown WSL2 → sessions user cassées)"
  fi
  projets_report check
  local conforme=1 c=0; wsl_conf_report || conforme=0
  c_drive_open || c=$?
  if [[ "$c" -eq 0 && "$conforme" -eq 1 ]]; then
    p_warn "C: encore OUVERT alors que wsl.conf est posé — redémarrage requis : « wsl --shutdown » (PowerShell), un nouvel onglet, puis le doctor"
  elif [[ "$c" -eq 0 ]]; then
    p_drift "C: OUVERT (sonde réelle) et wsl.conf non conforme — le lockdown n'est pas armé"
  elif [[ "$c" -eq 1 ]]; then
    p_ok "C: fermé (sonde réelle : $PROV_HUMAN ne peut pas y écrire)"
  fi
  dire_hostname
  verdict_check
}

apply() {
  if docker_io_next_to_desktop; then
    p_fail "$DOCKER_IO_DESKTOP_GESTE"
  fi
  if pkg_installed snapd; then
    run_quiet env DEBIAN_FRONTEND=noninteractive apt-get purge -y snapd || verdict_apply
    rm -rf "${SNAP_DIRS[@]}"
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "snapd purgé (+ ${SNAP_DIRS[*]})"
  fi
  local home mask
  home="$(human_home)"
  if [[ -n "$home" && -d "$home" ]]; then
    local d
    # un dossier de l'humain qui existe garde le mode qu'il lui a donné ; seul ce qui manque est posé
    for d in "$home/.config" "$home/.config/systemd" "$home/.config/systemd/user"; do
      [[ -d "$d" ]] || ensure_dir "$d" 0700 "$PROV_HUMAN:" || verdict_apply
    done
    mask="$(gpg_socket_mask_path)"
    ensure_symlink "$mask" /dev/null || verdict_apply
  else
    p_fail "home de $PROV_HUMAN introuvable — masque gpg impossible"
  fi

  # le credential helper de Docker Desktop est un .exe : couper l'interop le rend inexécutable et
  # tout docker pull mourrait sur « error getting credentials » à la passe suivante. Une clé qui
  # désigne un binaire inexécutable est une configuration morte : elle part, les autres clés restent.
  local dcfg="$home/.docker/config.json"
  if [[ -f "$dcfg" ]] && grep -q '"credsStore"' "$dcfg" 2>/dev/null; then
    local dtmp
    dtmp="$(mktemp "${TMPDIR:-/tmp}/prov-dockercfg.XXXXXX")" || { p_fail "tmp config docker impossible"; verdict_apply; }
    jq 'del(.credsStore)' "$dcfg" > "$dtmp" 2>/dev/null \
      || { rm -f "$dtmp"; p_fail "config docker : $dcfg n'est pas un JSON lisible par jq — rien n'est réécrit"; verdict_apply; }
    write_atomic "$dcfg" 0600 "$PROV_HUMAN:" < "$dtmp" \
      || { rm -f "$dtmp"; verdict_apply; }
    rm -f "$dtmp"
    p_warn "credsStore retiré de $dcfg — il désignait un helper Windows (.exe) que la coupure de l'interop rendra inexécutable. Les registres publics restent joignables ; un registre privé redemandera un « docker login »"
  fi

  projets_report apply

  # wsl.conf en dernier : rien n'arme le redémarrage tant que le reste n'est pas posé
  local cible; cible="$(wsl_conf_cible)"
  write_atomic "$WSL_CONF" 0644 root:root <<<"$cible" || verdict_apply
  local c=0; c_drive_open || c=$?
  if [[ "$c" -eq 0 ]]; then
    p_warn "wsl.conf posé mais C: encore OUVERT — « wsl --shutdown » (PowerShell), un nouvel onglet, puis relancer l'installation"
  elif [[ "$c" -eq 1 ]]; then
    p_ok "C: fermé (sonde réelle)"
  fi
  dire_hostname
  verdict_apply
}

case "${1:-}" in check|apply) "$1" ;; *) p_die "mode inconnu: ${1:-} (check|apply)" ;; esac
