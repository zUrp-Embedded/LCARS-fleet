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

WSL_CONF="${LCARS_WSL_CONF:-/etc/wsl.conf}"
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
c_drive_open() {
  local c="${LCARS_C_DRIVE:-/mnt/c}"
  [[ -d "$c" ]] || return 1
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

wsl_conf_report() { # wsl_conf_report <p_drift|p_warn> — chaque clé de l'état-cible contre le fichier
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
    p_fail "$DOCKER_IO_DESKTOP_GESTE"
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
  local conforme=1; wsl_conf_report || conforme=0
  if c_drive_open; then
    if [[ "$conforme" -eq 1 ]]; then
      p_warn "C: encore OUVERT alors que wsl.conf est posé — redémarrage requis : « wsl --shutdown » (PowerShell), un nouvel onglet, puis le doctor"
    else
      p_drift "C: OUVERT (sonde réelle) et wsl.conf non conforme — le lockdown n'est pas armé"
    fi
  else
    p_ok "C: fermé (sonde réelle : $PROV_HUMAN ne peut pas y écrire)"
  fi
  [[ "$(hostname)" == "$HOSTNAME_CIBLE" ]] \
    || p_warn "hostname « $(hostname) » — « $HOSTNAME_CIBLE » prendra après « wsl --shutdown »"
  verdict_check
}

apply() {
  if docker_io_next_to_desktop; then
    p_fail "$DOCKER_IO_DESKTOP_GESTE"
  fi
  if pkg_installed snapd; then
    run_quiet env DEBIAN_FRONTEND=noninteractive apt-get purge -y snapd || verdict_apply
    # shellcheck disable=SC2086 # une liste de chemins, découpée à dessein
    rm -rf ${LCARS_SNAP_DIRS:-/snap /var/snap /var/lib/snapd}
    if pkg_installed snapd; then
      p_fail "snapd toujours présent après purge"
    else
      PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "snapd purgé (+ ${LCARS_SNAP_DIRS:-/snap /var/snap /var/lib/snapd})"
    fi
  fi
  local home mask
  home="$(human_home)"
  if [[ -n "$home" && -d "$home" ]]; then
    ensure_dir "$home/.config" 0755 "$PROV_HUMAN:" || verdict_apply
    ensure_dir "$home/.config/systemd" 0755 "$PROV_HUMAN:" || verdict_apply
    ensure_dir "$home/.config/systemd/user" 0755 "$PROV_HUMAN:" || verdict_apply
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
    sed -e 's/"credsStore"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,//g' \
        -e 's/,[[:space:]]*"credsStore"[[:space:]]*:[[:space:]]*"[^"]*"//g' \
        -e 's/"credsStore"[[:space:]]*:[[:space:]]*"[^"]*"//g' \
        "$dcfg" > "$dtmp" \
      || { rm -f "$dtmp"; p_fail "config docker: réécriture ratée ($dcfg)"; verdict_apply; }
    [[ -s "$dtmp" ]] \
      || { rm -f "$dtmp"; p_fail "config docker: résultat VIDE — rien n'est écrit ($dcfg)"; verdict_apply; }
    write_atomic "$dcfg" 0600 "$PROV_HUMAN:" < "$dtmp" \
      || { rm -f "$dtmp"; verdict_apply; }
    rm -f "$dtmp"
    p_warn "credsStore retiré de $dcfg — il désignait un helper Windows (.exe) que la coupure de l'interop rendra inexécutable. Les registres publics restent joignables ; un registre privé redemandera un « docker login »"
  fi

  # wsl.conf en dernier : rien n'arme le redémarrage tant que le reste n'est pas posé ; un fichier
  # vide laisserait l'interop ouverte, c'est le seul objet du rail dont l'échec rouvre une porte
  local cible; cible="$(wsl_conf_cible)"
  [[ -n "${cible//[$'\n'[:space:]]/}" ]] \
    || { p_fail "wsl.conf: contenu cible VIDE — la frontière ne sera pas armée, rien n'est posé"; verdict_apply; }
  if [[ -f "$WSL_CONF" && "$(cat "$WSL_CONF")" == "$cible" ]]; then
    p_ok "$WSL_CONF conforme, clé par clé"
  else
    write_atomic "$WSL_CONF" 0644 root:root <<<"$cible" || verdict_apply
  fi
  if c_drive_open; then
    p_warn "wsl.conf posé mais C: encore OUVERT — « wsl --shutdown » (PowerShell), un nouvel onglet, puis relancer l'installation"
  else
    p_ok "C: fermé (sonde réelle)"
  fi
  [[ "$(hostname)" == "$HOSTNAME_CIBLE" ]] \
    || p_warn "hostname « $(hostname) » — « $HOSTNAME_CIBLE » prendra après « wsl --shutdown »"
  verdict_apply
}

case "${1:?usage: 30-wsl.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
