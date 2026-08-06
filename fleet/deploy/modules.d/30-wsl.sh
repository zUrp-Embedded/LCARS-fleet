#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/30-wsl.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — substrat WSL : lockdown C: (wsl.conf), purge snap, masque gpg-agent, ready-room optionnelle
# APPLY-ON: wsl
# CHECK-ON: wsl
# NEEDS: root
#
# Ce module encaisse la dette de guerre WSL payée par les générations v0→v1 (commentaires de
# terrain retrouvés dans _archived/) pour ne JAMAIS la repayer :
#   - snapd casse l'init des sessions `systemd --user` sous WSL (socket résiduel) → purge.
#   - gpg-agent-ssh.socket race au shutdown WSL2 (« Failed to start systemd user session » au
#     login suivant) → masqué par symlink /dev/null dans le home de l'humain.
#   - /etc/wsl.conf ne prend effet qu'après `wsl --shutdown` + NOUVEL onglet Windows Terminal ;
#     il s'écrit EN DERNIER dans ce module (un crash avant = rien d'armé à moitié).
#   - le lockdown C: se SONDE en réel (touch/rm sur /mnt/c), jamais en lisant la config —
#     la v1 avait DEUX sondes divergentes ; celle-ci est LA seule.
#
# /etc/wsl.conf est possédé EN ENTIER par ce module (write_atomic du fichier complet) : c'est la
# frontière de sécurité de la boîte (octogone — C: fermé, interop coupé), pas un fichier de
# préférences. Un edit manuel = un drift au doctor, réécrit à l'apply. Assumé et dit ici.
#
# Ready-room (échange humain↔fleet via C:\Users\<win_user>\ready-room, monté drvfs) : OPTIONNELLE.
# Gérée si PROV_WINDOWS_USER est posé (ou détectable par wslvar TANT QUE l'interop répond — après
# lockdown, plus aucune requête vers Windows n'est possible : on le dit au lieu d'échouer).

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

WSL_CONF=/etc/wsl.conf

# L'état-cible ENTIER de wsl.conf. [automount] enabled=false = C: fermé (seul le fstab géré
# monte quelque chose). [interop] enabled=false = pas de lancement d'exécutables Windows depuis
# la boîte (canal d'évasion) — posture v1 courante, conservée. [boot] systemd=true : le substrat
# OS peut en avoir besoin (runner CI, lingering) — la FLEET, elle, n'a pas d'unit (l'humain lance).
desired_wsl_conf() {
  cat <<'EOF'
# /etc/wsl.conf — géré par fleet/deploy (modules.d/30-wsl.sh). Édition manuelle = drift.
# Frontière de sécurité de la boîte : C: fermé, interop coupé. Appliqué après `wsl --shutdown`.
[boot]
systemd=true

[automount]
enabled=false
mountFsTab=true

[interop]
enabled=false
appendWindowsPath=false
EOF
}

# LA sonde C: (unique) : l'état RÉEL, pas la config. root écrit partout → sonde AS PROV_HUMAN
# (c'est de lui qu'on veut savoir s'il peut toucher C:).
c_drive_open() {
  [[ -d /mnt/c ]] || return 1
  local probe="/mnt/c/.lcars-lockdown-probe.$$"
  if as_human touch "$probe" 2>/dev/null; then
    as_human rm -f "$probe" 2>/dev/null || true
    return 0
  fi
  return 1
}

gpg_socket_mask_path() {
  local home; home="$(human_home)"
  [[ -n "$home" ]] && echo "$home/.config/systemd/user/gpg-agent-ssh.socket"
}

check() {
  # snapd
  if dpkg -s snapd >/dev/null 2>&1; then
    p_drift "snapd présent (casse systemd --user sous WSL) — l'apply le purge"
  else
    p_ok "snapd absent"
  fi

  # masque gpg-agent-ssh.socket
  local mask; mask="$(gpg_socket_mask_path)"
  if [[ -n "$mask" && "$(readlink "$mask" 2>/dev/null)" == "/dev/null" ]]; then
    p_ok "gpg-agent-ssh.socket masqué ($PROV_HUMAN)"
  else
    p_drift "gpg-agent-ssh.socket non masqué pour $PROV_HUMAN (race shutdown WSL2 → sessions user cassées)"
  fi

  # wsl.conf : contenu exact.
  if [[ -f "$WSL_CONF" ]] && desired_wsl_conf | cmp -s - "$WSL_CONF"; then
    p_ok "$WSL_CONF conforme"
  else
    p_drift "$WSL_CONF absent ou divergent de l'état-cible"
  fi

  # État RÉEL du lockdown.
  if c_drive_open; then
    if desired_wsl_conf | cmp -s - "$WSL_CONF" 2>/dev/null; then
      p_warn "C: encore OUVERT alors que wsl.conf est posé → REBOOT REQUIS : « wsl --shutdown » (PowerShell), rouvre un NOUVEL onglet, relance le doctor"
    else
      p_drift "C: OUVERT (sonde réelle) et wsl.conf non conforme — le lockdown n'est pas armé"
    fi
  else
    p_ok "C: fermé (sonde réelle : $PROV_HUMAN ne peut pas y écrire)"
  fi
  verdict_check
}

apply() {
  # 1. Purge snap (AVANT wsl.conf — l'ordre d'écriture de wsl.conf en dernier est le contrat).
  if dpkg -s snapd >/dev/null 2>&1; then
    run_quiet env DEBIAN_FRONTEND=noninteractive apt-get purge -y snapd || verdict_apply
    rm -rf /snap /var/snap /var/lib/snapd
    if dpkg -s snapd >/dev/null 2>&1; then
      p_fail "snapd toujours présent après purge"
    else
      PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "snapd purgé (+ /snap /var/snap /var/lib/snapd)"
    fi
  fi

  # 2. Masque gpg-agent-ssh.socket pour l'humain.
  local home mask
  home="$(human_home)"
  if [[ -n "$home" && -d "$home" ]]; then
    ensure_dir "$home/.config" 0755 "$PROV_HUMAN:$PROV_HUMAN" || verdict_apply
    ensure_dir "$home/.config/systemd" 0755 "$PROV_HUMAN:$PROV_HUMAN" || verdict_apply
    ensure_dir "$home/.config/systemd/user" 0755 "$PROV_HUMAN:$PROV_HUMAN" || verdict_apply
    mask="$(gpg_socket_mask_path)"
    ensure_symlink "$mask" /dev/null || verdict_apply
  else
    p_fail "home de $PROV_HUMAN introuvable — masque gpg impossible"
  fi

  # 3. Ready-room (optionnelle — seulement si on peut nommer le user Windows).
  local win_user="${PROV_WINDOWS_USER:-}"
  if [[ -z "$win_user" ]] && command -v wslvar >/dev/null; then
    # wslvar passe par l'interop : ne répond QUE tant que le lockdown n'est pas appliqué.
    win_user="$(wslvar USERNAME 2>/dev/null || true)"
  fi
  if [[ -n "$win_user" ]]; then
    ensure_dir /home/ready-room 0755 "$PROV_HUMAN:$PROV_FLEET_GROUP" || verdict_apply
    # Le flag `metadata` est ce qui donne des perms Unix sur NTFS (dette de guerre v1).
    local uid gid
    uid="$(id -u "$PROV_HUMAN")"; gid="$(getent group "$PROV_FLEET_GROUP" | cut -d: -f3)"
    ensure_managed_block /etc/fstab lcars-ready-room 0644 root:root <<EOF
C:\\Users\\${win_user}\\ready-room /home/ready-room drvfs uid=${uid},gid=${gid},metadata,umask=22,fmask=11,noatime 0 0
EOF
  else
    p_warn "ready-room : user Windows inconnu (PROV_WINDOWS_USER non posé, wslvar muet — interop déjà coupé ?) — montage non géré, pose PROV_WINDOWS_USER et relance si tu la veux"
  fi

  # 4. wsl.conf EN DERNIER (le contrat de la dette de guerre : rien n'arme le reboot tant que
  #    tout le reste n'est pas posé). B3 : redirection, jamais de pipe vers write_atomic (le
  #    sous-shell du pipe perdait PROV_FAILED → wsl.conf non posé rapporté vert).
  local wsl_tmp
  wsl_tmp="$(mktemp "${TMPDIR:-/tmp}/prov-wslconf.XXXXXX")" || { p_fail "tmp wsl.conf impossible"; verdict_apply; }
  desired_wsl_conf > "$wsl_tmp"
  write_atomic "$WSL_CONF" 0644 root:root < "$wsl_tmp" || { rm -f "$wsl_tmp"; verdict_apply; }
  rm -f "$wsl_tmp"

  # 5. État réel + consigne de reprise (pas de sentinelle, pas de trigger bashrc : l'humain
  #    relance le MÊME apply après le reboot, l'idempotence fait le reste).
  if c_drive_open; then
    p_warn "wsl.conf posé mais C: encore OUVERT → « wsl --shutdown » (PowerShell), rouvre un NOUVEL onglet (pas l'ancien), relance « provision apply »"
  else
    p_ok "C: fermé (sonde réelle)"
  fi
  verdict_apply
}

case "${1:?usage: 30-wsl.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
