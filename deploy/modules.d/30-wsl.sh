#!/usr/bin/env bash
# SOURCE: deploy/modules.d/30-wsl.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: le substrat WSL — wsl.conf clé par clé (C: fermé, interop coupée, systemd, hostname), snapd purgé, gpg-agent masqué
# APPLY-ON: wsl
# CHECK-ON: wsl
# NEEDS: root
#
# wsl.conf est le fichier de l'instance : chaque clé de l'état-cible s'y pose, le reste du fichier
# ([user] compris) est conservé. Il ne prend effet qu'après « wsl --shutdown » ; la sonde de C:
# mesure l'état réel, pas la configuration. Le hostname de l'instance prend la base du projet.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

WSL_CONF="$(prov_decor /etc/wsl.conf)"
SNAP_DIRS=("$(prov_decor /snap)" "$(prov_decor /var/snap)" "$(prov_decor /var/lib/snapd)")
HOSTNAME_CIBLE="${PROV_FORGE_BASE//_/-}"

# une étiquette DNS : la base du projet arrive aussi par --env, qui ne passe pas par la validation du projet
hostname_valide() { [[ "$HOSTNAME_CIBLE" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }

# section clé valeur — l'état-cible entier ; [interop] coupée = pas d'exécutable Windows depuis l'instance
wsl_cles() {
  printf '%s\n' \
    "boot systemd true" \
    "automount enabled false" \
    "automount mountFsTab true" \
    "interop enabled false" \
    "interop appendWindowsPath false"
  if hostname_valide; then printf '%s\n' "network hostname $HOSTNAME_CIBLE"; fi
}

dire_hostname() { # le même constat au check et à l'apply : un nom refusé, ou un nom qui ne prend qu'au redémarrage
  if ! hostname_valide; then
    p_fail "hostname « $HOSTNAME_CIBLE » refusé : une étiquette DNS porte lettres, chiffres et tirets, sans tiret aux bords, 63 caractères au plus — [network] hostname n'est pas posé ; choisir une autre base de projet"
  elif [[ "$(hostname)" != "$HOSTNAME_CIBLE" ]]; then
    p_warn "hostname « $(hostname) » — « $HOSTNAME_CIBLE » prendra après « wsl --shutdown »"
  fi
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

"$1"
