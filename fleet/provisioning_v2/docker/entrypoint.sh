#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/docker/entrypoint.sh
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
#   LCARS_HUMAN     login de l'humain (défaut : lcars) — créé s'il n'existe pas, home persistant
#   LCARS_UID       uid de l'humain (défaut : 1000) — stable = ownership du volume stable
#   LCARS_SSH_AUTHORIZED_KEYS  contenu authorized_keys (sinon : accès par `docker exec` seulement)
#   FORGE_BASE_URL  forge cible (avec le profil compose `forge` : http://forge:3000)

set -euo pipefail

LCARS_HUMAN="${LCARS_HUMAN:-lcars}"
LCARS_UID="${LCARS_UID:-1000}"
PROVISION=/opt/lcars/fleet/provisioning_v2/provision
HOST_KEYS_DIR=/home/.lcars-container/ssh

say() { echo "[lcars-entrypoint] $*"; }

# ─── 1. L'humain (idempotent — le home vit dans le volume, le user est recréé à l'identique) ─────
if ! getent passwd "$LCARS_HUMAN" >/dev/null; then
  useradd -m -u "$LCARS_UID" -s /bin/bash "$LCARS_HUMAN"
  say "humain $LCARS_HUMAN créé (uid $LCARS_UID)"
fi

if [[ -n "${LCARS_SSH_AUTHORIZED_KEYS:-}" ]]; then
  HOME_DIR="$(getent passwd "$LCARS_HUMAN" | cut -d: -f6)"
  install -d -m 0700 -o "$LCARS_HUMAN" -g "$LCARS_HUMAN" "$HOME_DIR/.ssh"
  # Écriture atomique tmp+mv (doctrine lib) — un crash ne laisse pas un authorized_keys tronqué.
  tmp="$(mktemp "$HOME_DIR/.ssh/.authk.XXXXXX")"
  printf '%s\n' "$LCARS_SSH_AUTHORIZED_KEYS" > "$tmp"
  chmod 0600 "$tmp" && chown "$LCARS_HUMAN:$LCARS_HUMAN" "$tmp"
  mv -f "$tmp" "$HOME_DIR/.ssh/authorized_keys"
  say "authorized_keys posé pour $LCARS_HUMAN"
else
  say "pas de LCARS_SSH_AUTHORIZED_KEYS — accès par « docker exec -it -u $LCARS_HUMAN <ctr> bash » seulement"
fi

# ─── 1bis. Les zones catalogue : /home/projects + /home/projects.work, groupe fleet ──────────────
# Le sanctuaire bwrap des pods monte ces zones (cap-profile starfleet : les deux en rw) —
# ABSENTE, le spawn meurt (« catalogue mount path missing host-side », vu au premier E2E,
# une zone par crash). Sur WSL elles existent (histoire du substrat) ; ICI, l'entrypoint est
# le créateur de zones du conteneur (comme pour l'humain). setgid fleet : chaque humain du
# groupe y crée ses projets/worktrees.
install -d -m 2775 -g fleet /home/projects /home/projects.work
say "zones catalogue : /home/projects /home/projects.work (2775 root:fleet)"

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
if "$PROVISION" apply --substrate docker --human "$LCARS_HUMAN"; then
  say "provision apply : convergé"
else
  say "provision apply : AU MOINS UN ÉCHEC (rc=$?) — la boîte démarre quand même ; diagnose : $PROVISION doctor"
fi

# ─── 4. sshd au premier plan (tini est PID 1 : reap + signaux ; exec = sshd reçoit les signaux) ──
say "sshd prêt — ssh $LCARS_HUMAN@<hôte> -p <port mappé> puis « fleet_v2 start »"
exec /usr/sbin/sshd -D -e
