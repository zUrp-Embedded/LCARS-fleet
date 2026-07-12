#!/usr/bin/env bash
# SOURCE: test/gate-r0.1-bwrap.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: RÉÉCRIT (audit transverse lot 6, 2026-07-12) — sonde d'isolation e2e RÉELLE, modèle détaché ADR-G
#
# gate-r0.1-bwrap.sh — R0.1 (Ring 0, primitive bwrap). exit 0 ssi le VRAI bin/bwrap_launch.sh,
# invoqué au CONTRAT COURANT (env spawner complet), projette un sandbox où — vu DE L'INTÉRIEUR :
#   env_home        HOME intra-pod = le pod home (--setenv HOME, side-channel indépendant de HOME)
#   iso_home        le home host est MASQUÉ (--tmpfs /home : sentinelle posée dans ~ INVISIBLE)
#   iso_tmp         /tmp host est MASQUÉ (--tmpfs /tmp : canari host INVISIBLE)
#   iso_env         l'env est CLOS (--clearenv : var ambiante exportée au launch INVISIBLE)
#   env_forward     l'env CONTRACTUEL passe (--setenv : GIT_AUTHOR_NAME == valeur posée)
#   env_git_global  GIT_CONFIG_GLOBAL=/dev/null (identité git = env forwardé, jamais le global)
#   env_pod_id      LCARS_POD_ID câblé (--setenv = le pod_id passé au launcher)
#   creds_bind      les creds bindés sont LES BONS octets (nonce round-trip — creds FACTICES,
#                   jamais les vrais : le gate ne touche PAS ~/.claude)
#   creds_rw_pod    append EN PLACE sur les creds accepté in-pod (bind single-file RW)…
#   vendor_native   le vendor est provisionné à son emplacement natif ($HOME/.local/bin/<vendor>)
#   vendor_exec     ... et s'EXÉCUTE dans le pod (--version, zéro réseau/token)
#   ro_vendor_bind  le bind vendor est RO (touch refusé)
#   ro_usr          /usr est RO (écriture refusée — les roots système ne sont pas RW)
#   etc_shadow      /etc SÉLECTIF : /etc/shadow ABSENT du monde projeté (pas de bind /etc en bloc)
#   etc_dns         ... mais resolv.conf PRÉSENT (DNS projeté, sinon claude hang sur l'API)
#   pid_ns          le PID host du gate est INVISIBLE dans /proc (--unshare-all → PID namespace)
#   rw_home         le $HOME pod est RW
# + HOLDER : le launcher (bwrap-PID1) est encore VIVANT après la sonde (modèle détaché tient).
# + creds_rw_host (jugé HOST-SIDE, hors compte sonde) : …et l'append in-pod est PROPAGÉ au fichier
#   host — c'est LE chemin du refresh OAuth ADR-F (écriture en place qui survit au bind).
#
# POURQUOI une sonde INTÉRIEURE (side-channel) et pas l'exit code : le launcher fait
# `exec bwrap … tmux new-session -d … exec sleep infinity` et NE REND JAMAIS la main (holder
# ADR-G) — le stdout de la COMMAND va dans le pane tmux, son exit n'est jamais propagé. L'ancien
# gate (pré-ADR-G) jugeait sur l'exit du launcher : il prenait « launcher mort en setup » pour
# « sentinelle masquée » → PASS ISO mensonger (famille faux-vert F-C166/167, audit transverse #24).
# Ici la COMMAND lancée DANS le pod EST la sonde : elle inspecte le monde de l'intérieur et écrit
# son verdict dans $POD_DIR (bindé RW) → lisible host-side. Le gate juge sur ce rapport, avec un
# COMPTE DE CHECKS EXIGÉ (jamais vert sur rapport vide/partiel), puis kill le launcher.
#
# Les bats (test/bwrap_launch/bwrap_launch.bats) stubent bwrap et ne testent QUE l'assemblage des
# flags : CE gate est la preuve e2e de l'isolation réelle (bwrap + tmux + namespace vrais).
# Prérequis : bwrap, tmux, un vendor résolvable (claude sur PATH, ou LCARS_VENDOR_BIN/_SHARE —
# n'importe quel exécutable répondant à --version fait l'affaire sur une machine sans claude).
# Debug : KEEP=1 conserve le workdir. Manuel/opt-in (hors mix gate : exige les syscalls bwrap).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BWRAP_LAUNCH="$HERE/../bin/bwrap_launch.sh"

WORK="$(mktemp -d)"
POD_ID="gate-r01-$$"
POD_DIR="$WORK/pod"
SENTINEL="$HOME/.gate-r01-sentinel-$$"
TMP_CANARY="$(mktemp /tmp/gate-r01-canary.XXXXXX)"
LAUNCH_PID=""
cleanup() {
  if [[ -n "$LAUNCH_PID" ]]; then
    kill "$LAUNCH_PID" 2>/dev/null || true
    wait "$LAUNCH_PID" 2>/dev/null || true
  fi
  rm -f "$SENTINEL" "$TMP_CANARY"
  if [[ "${KEEP:-0}" = 1 ]]; then echo "KEEP $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

echo "== Gate R0.1 — bwrap primitive (vrai bwrap_launch.sh, sonde d'isolation intérieure) =="
echo "   launcher: $BWRAP_LAUNCH"

# iso_home s'appuie sur `--tmpfs /home` : un $HOME hors /home rendrait le check vide de sens.
[[ "$HOME" == /home/* ]] || { echo "FAIL SETUP  \$HOME=$HOME hors /home — iso_home (tmpfs /home) ne prouverait rien ici"; exit 1; }

# ---------------------------------------------------------------------------
# Monde host minimal au CONTRAT du launcher (chaque :?/guard de bwrap_launch.sh servi,
# TOUT sous $WORK — rien du vrai ~/.lcars ni ~/.claude n'est utilisé).
# ---------------------------------------------------------------------------
mkdir -p "$POD_DIR" "$WORK/claude-dir" "$WORK/mirror" "$WORK/sock" "$WORK/mcp/$POD_ID"
CREDS_NONCE="creds-nonce-$$-$RANDOM"
printf '%s' "$CREDS_NONCE" > "$WORK/claude-dir/.credentials.json"   # FACTICE — jamais les vrais creds
echo "gate-r01-secret" > "$SENTINEL"

export CLAUDE_DIR="$WORK/claude-dir"
export LCARS_GIT_MIRROR="$WORK/mirror"
export LCARS_TMUX_SOCK_BASE="$WORK/sock"
export LCARS_FLEET_MCP_SOCK_BASE="$WORK/mcp"
export LCARS_POD_SESSION_ID="gate-r01-session-$$"
export LCARS_POD_SESSION_NAME_PREFIX="gate_r01"
export GIT_AUTHOR_NAME="gate-r01" GIT_AUTHOR_EMAIL="gate-r01@lcars.local"
export GIT_COMMITTER_NAME="gate-r01" GIT_COMMITTER_EMAIL="gate-r01@lcars.local"
export LCARS_BWRAP_NO_CLEANUP=1          # échec setup → diagnostics conservés (cleanup = notre trap)
export LCARS_ISO_ENV_CANARY="leak-$$"    # DOIT être invisible dans le pod (--clearenv)

# ---------------------------------------------------------------------------
# La sonde intérieure (POSIX sh — c'est la COMMAND du pod). Heredoc NON quoté : les chemins/nonces
# host ($SENTINEL, $TMP_CANARY, $CREDS_NONCE, vendor) sont FIGÉS dans le script au moment du write ;
# les \$ échappés sont évalués DANS le sandbox. Rapport : $HOME/iso-report (= $POD_DIR/iso-report
# host-side, SANDBOX_HOME=$POD_DIR car LCARS_POD_HOME non posé).
# ---------------------------------------------------------------------------
VENDOR_NAME="${LCARS_VENDOR_NAME:-claude}"
EXPECTED_CHECKS=9
cat > "$POD_DIR/.iso-probe.sh" <<PROBE
#!/bin/sh
R="\$HOME/iso-report"
: > "\$R"
ck() { s=\$1; shift; if [ "\$s" = 0 ]; then echo "PASS \$1" >> "\$R"; else shift; echo "FAIL \$*" >> "\$R"; fi; }

[ ! -e "$SENTINEL" ];                     ck \$? iso_home iso_home "sentinelle host LISIBLE: $SENTINEL"
[ ! -e "$TMP_CANARY" ];                   ck \$? iso_tmp iso_tmp "canari /tmp host LISIBLE: $TMP_CANARY"
[ -z "\${LCARS_ISO_ENV_CANARY:-}" ];      ck \$? iso_env iso_env "env ambiant FUITÉ malgré --clearenv"
[ "\${GIT_AUTHOR_NAME:-}" = "gate-r01" ]; ck \$? env_forward env_forward "GIT_AUTHOR_NAME='\${GIT_AUTHOR_NAME:-}'"
[ "\$(cat "\$HOME/.claude/.credentials.json" 2>/dev/null)" = "$CREDS_NONCE" ]; \
                                          ck \$? creds_bind creds_bind "contenu creds != nonce attendu"
[ -x "\$HOME/.local/bin/$VENDOR_NAME" ];  ck \$? vendor_native vendor_native "\$HOME/.local/bin/$VENDOR_NAME absent/non-x"
V="\$(timeout 20 "\$HOME/.local/bin/$VENDOR_NAME" --version 2>&1)"; \
                                          ck \$? vendor_exec vendor_exec "--version KO: \$V"
echo "INFO vendor_version: \$V" >> "\$R"
! touch "\$HOME/.local/bin/$VENDOR_NAME" 2>/dev/null; \
                                          ck \$? ro_vendor_bind ro_vendor_bind "bind vendor ÉCRIVABLE (RO cassé)"
touch "\$HOME/.rw-check" 2>/dev/null;     ck \$? rw_home rw_home "write \$HOME refusé (bind pod pas RW)"

echo "END $EXPECTED_CHECKS" >> "\$R"
PROBE
chmod +x "$POD_DIR/.iso-probe.sh"

# ---------------------------------------------------------------------------
# Launch détaché : bwrap_launch ne rend PAS la main (holder) → background + poll du rapport.
# ---------------------------------------------------------------------------
"$BWRAP_LAUNCH" gate-r01-role "$POD_ID" "$POD_DIR" /bin/sh "$POD_DIR/.iso-probe.sh" \
  > "$WORK/launch.log" 2>&1 &
LAUNCH_PID=$!

REPORT="$POD_DIR/iso-report"
for _ in $(seq 1 60); do
  if [[ -f "$REPORT" ]] && grep -q '^END ' "$REPORT" 2>/dev/null; then break; fi
  if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
    # Mort AVANT le détachement = échec de setup du launcher (guards :?/exit 1|2) — fail-loud
    # avec la cause réelle, PAS un verdict d'isolation (c'était le mensonge de l'ancien gate).
    wait "$LAUNCH_PID" 2>/dev/null || true
    LAUNCH_PID=""
    echo "FAIL LAUNCH  bwrap_launch mort en setup (aucune isolation testée) :"
    sed 's/^/    | /' "$WORK/launch.log" 2>/dev/null || true
    echo "---"
    echo "GATE R0.1 : exit 1 — ne porte pas"
    exit 1
  fi
  sleep 0.5
done

FAIL=0

# HOLDER : le launcher doit être encore vivant (bwrap-PID1 tient le namespace, ADR-G).
if kill -0 "$LAUNCH_PID" 2>/dev/null; then
  echo "PASS HOLDER  bwrap-PID1 vivant après la sonde (modèle détaché tient)"
else
  echo "FAIL HOLDER  launcher mort après la sonde (holder ADR-G cassé)"; FAIL=1
fi

# Verdict sur RAPPORT — compte exigé, jamais vert sur rapport vide/partiel (F-C166/167).
if ! grep -q '^END ' "$REPORT" 2>/dev/null; then
  echo "FAIL PROBE   rapport de sonde absent/incomplet après 30s ($REPORT)"
  echo "  -- launch.log --"; sed 's/^/    | /' "$WORK/launch.log" 2>/dev/null || true
  FAIL=1
else
  sed 's/^/   | /' "$REPORT"
  PASS_N="$(grep -c '^PASS ' "$REPORT" || true)"
  FAIL_N="$(grep -c '^FAIL ' "$REPORT" || true)"
  END_N="$(sed -n 's/^END //p' "$REPORT" | head -1)"
  if [[ "$FAIL_N" -gt 0 ]]; then
    echo "FAIL ISO     $FAIL_N check(s) rouges dans le pod"; FAIL=1
  fi
  if [[ "$PASS_N" -ne "$EXPECTED_CHECKS" || "${END_N:-0}" -ne "$EXPECTED_CHECKS" ]]; then
    echo "FAIL COUNT   $PASS_N/$EXPECTED_CHECKS PASS (END=${END_N:-absent}) — rapport partiel ≠ vert"; FAIL=1
  fi
fi

echo "---"
if [[ "$FAIL" -eq 0 ]]; then
  echo "GATE R0.1 : exit 0 — bwrap primitive porte (isolation prouvée de l'intérieur, vrai launcher)"
else
  echo "GATE R0.1 : exit 1 — ne porte pas"
fi
exit "$FAIL"
