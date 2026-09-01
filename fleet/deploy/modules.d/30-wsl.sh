#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/30-wsl.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — substrat WSL : lockdown C: (wsl.conf), purge snap, masque gpg-agent
# APPLY-ON: wsl
# CHECK-ON: wsl
# NEEDS: root

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

gpg_socket_mask_path() { # vide quand l'humain n'a pas de home — a l'appelant de le dire, pas de mourir
  local home; home="$(human_home)"
  if [[ -n "$home" ]]; then echo "$home/.config/systemd/user/gpg-agent-ssh.socket"; fi
}

check() {
  if dpkg -s snapd >/dev/null 2>&1; then
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

  if [[ -f "$WSL_CONF" ]] && desired_wsl_conf | cmp -s - "$WSL_CONF"; then
    p_ok "$WSL_CONF conforme"
  else
    p_drift "$WSL_CONF absent ou divergent de l'état-cible"
  fi

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
  if dpkg -s snapd >/dev/null 2>&1; then
    run_quiet env DEBIAN_FRONTEND=noninteractive apt-get purge -y snapd || verdict_apply
    rm -rf /snap /var/snap /var/lib/snapd
    if dpkg -s snapd >/dev/null 2>&1; then
      p_fail "snapd toujours présent après purge"
    else
      PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "snapd purgé (+ /snap /var/snap /var/lib/snapd)"
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

  # 3. wsl.conf EN DERNIER (le contrat de la dette de guerre : rien n'arme le reboot tant que
  #    tout le reste n'est pas posé). B3 : redirection, jamais de pipe vers write_atomic (le
  #    sous-shell du pipe perdait PROV_FAILED → wsl.conf non posé rapporté vert).
  local wsl_tmp
  wsl_tmp="$(mktemp "${TMPDIR:-/tmp}/prov-wslconf.XXXXXX")" || { p_fail "tmp wsl.conf impossible"; verdict_apply; }
  # ⚠ LA SECONDE COUCHE SE LIT AUSSI. `write_atomic` garde desormais le rc de son `cat`, mais elle
  # ne peut rien dire d'un tampon qu'un AUTRE geste a tronque avant elle : un contenu vide est un
  # contenu valide de son point de vue. Le rc de la redirection ET la non-vacuite du tampon, parce
  # que ce fichier-ci est la frontiere de securite de la boite — un `wsl.conf` vide laisse l'interop
  # Windows OUVERTE, et c'est le seul objet du rail dont l'echec silencieux ROUVRE une porte au lieu
  # d'en fermer une.
  desired_wsl_conf > "$wsl_tmp" \
    || { rm -f "$wsl_tmp"; p_fail "wsl.conf: ecriture du tampon RATEE (disque plein ? quota ?)"; verdict_apply; }
  [[ -s "$wsl_tmp" ]] \
    || { rm -f "$wsl_tmp"; p_fail "wsl.conf: tampon VIDE — la frontiere ne sera pas armee, rien n'est pose"; verdict_apply; }
  write_atomic "$WSL_CONF" 0644 root:root < "$wsl_tmp" || { rm -f "$wsl_tmp"; verdict_apply; }
  rm -f "$wsl_tmp"

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
