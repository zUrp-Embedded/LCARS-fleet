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
# Prérequis : bwrap + tmux UTILISABLES (syscalls unshare/mount — préflight ci-dessous) ; vendor
# résolvable (claude sur PATH, ou LCARS_VENDOR_BIN/_SHARE), à défaut un STUB --version est
# substitué (la sonde prouve le SANDBOX, pas le vendor).
# Debug : KEEP=1 conserve le workdir. Manuel/opt-in (hors mix gate : exige les syscalls bwrap).
#
# 3 ÉTATS — un environnement incapable ne fabrique JAMAIS un vert :
#   exit 0  PASS — sonde exécutée DANS bwrap, rapport COMPLET, tous checks verts (+ holder + rw host)
#   exit 1  FAIL — isolation KO : un check rouge (même sur rapport partiel), compte incomplet,
#           holder cassé, ou propagation creds host absente — le vrai signal d'alerte
#   exit 3  SKIP — bwrap/tmux/syscalls indisponibles (WSL/container sans cap-add), launcher mort en
#           setup, ou sonde sans verdict ni constat : isolation NON VÉRIFIÉE — état EXPLICITE,
#           jamais un PASS déguisé (l'ancien gate prenait exactement ce chemin pour du vert)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BWRAP_LAUNCH="$HERE/../bin/bwrap_launch.sh"
BWRAP_BIN="${LCARS_BWRAP_BIN:-/usr/bin/bwrap}"
TMUX_BIN="${LCARS_TMUX_BIN:-/usr/bin/tmux}"

skip3() {
  echo "GATE R0.1 : SKIP — $*"
  echo "GATE R0.1 : exit 3 — isolation NON VÉRIFIÉE (SKIP explicite, jamais un PASS)"
  exit 3
}

echo "== Gate R0.1 — bwrap primitive (vrai bwrap_launch.sh, sonde d'isolation intérieure) =="
echo "   launcher: $BWRAP_LAUNCH"

# ---------------------------------------------------------------------------
# Préflight matériel : bwrap PRÉSENT ne suffit pas — il lui faut les syscalls (unshare/mount/
# pivot_root), que WSL/un container sans cap-add refusent. Sonde impossible = SKIP explicite,
# jamais un verdict d'isolation dans un sens ou dans l'autre.
# ---------------------------------------------------------------------------
[[ -x "$BWRAP_LAUNCH" ]] || skip3 "launcher introuvable/non-x: $BWRAP_LAUNCH"
[[ -x "$BWRAP_BIN" ]] || skip3 "bwrap indisponible ($BWRAP_BIN) — installer bubblewrap"
[[ -x "$TMUX_BIN" ]] || skip3 "tmux indisponible ($TMUX_BIN) — PTY N0 requis dans le sandbox"
"$BWRAP_BIN" --ro-bind / / true >/dev/null 2>&1 \
  || skip3 "bwrap présent mais syscalls sandbox refusés (unshare/mount — container sans cap-add/seccomp ?)"
"$BWRAP_BIN" --unshare-all --share-net --die-with-parent --ro-bind / / --tmpfs /home --tmpfs /tmp \
  --dev /dev --proc /proc true >/dev/null 2>&1 \
  || skip3 "bwrap sans namespaces complets (--unshare-all/--proc) — sandboxing réel impossible ici"

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

# iso_home s'appuie sur `--tmpfs /home` : un $HOME hors /home rendrait le check vide de sens.
# Environnement non probant ≠ isolation cassée → SKIP explicite (3-états), pas un FAIL.
[[ "$HOME" == /home/* ]] || skip3 "\$HOME=$HOME hors /home — iso_home (tmpfs /home) ne prouverait rien ici"

# ---------------------------------------------------------------------------
# Monde host minimal au CONTRAT du launcher (chaque :?/guard de bwrap_launch.sh servi,
# TOUT sous $WORK — rien du vrai ~/.lcars ni ~/.claude n'est utilisé).
# ---------------------------------------------------------------------------
mkdir -p "$POD_DIR" "$WORK/claude-dir" "$WORK/mirror" "$WORK/sock" "$WORK/mcp/$POD_ID"
CREDS_NONCE="creds-nonce-$$-$RANDOM"
CREDS_RW_NONCE="creds-rw-$$-$RANDOM"     # appendé in-pod, cherché HOST-side (propagation ADR-F)
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

# Ambient hostile neutralisé : ces vars re-shaperaient le monde projeté sous la sonde — et
# LCARS_POD_HOME déplacerait SANDBOX_HOME, rendant le side-channel $POD_DIR/iso-report invisible.
unset LCARS_POD_MOUNTS LCARS_SKILLS_PLUGINS LCARS_POD_HOME LCARS_POD_CWD LCARS_POD_CWD_SRC \
      LCARS_POD_RESUME LCARS_AUTH_MODE LCARS_POD_DISABLE_TELEMETRY

# Vendor : le vrai claude si résolvable (probe la vraie relocation native-install) ; sinon STUB
# répondant à --version — machine sans claude ≠ SKIP, la sonde teste le sandbox, pas le vendor.
VENDOR_NAME="${LCARS_VENDOR_NAME:-claude}"
if [[ -z "${LCARS_VENDOR_BIN:-}" ]] && ! command -v "$VENDOR_NAME" >/dev/null 2>&1; then
  export LCARS_VENDOR_BIN="$WORK/vendor/bin/$VENDOR_NAME" LCARS_VENDOR_SHARE="$WORK/vendor/share"
  mkdir -p "$WORK/vendor/bin" "$WORK/vendor/share"
  printf '#!/bin/sh\necho "gate-r01 vendor-stub 0.0.0"\n' > "$LCARS_VENDOR_BIN"
  chmod +x "$LCARS_VENDOR_BIN"
  echo "   vendor '$VENDOR_NAME' non résolvable → stub --version substitué"
fi

# ---------------------------------------------------------------------------
# La sonde intérieure (POSIX sh — c'est la COMMAND du pod). Heredoc NON quoté : les chemins/nonces
# host ($SENTINEL, $TMP_CANARY, $CREDS_NONCE, $POD_ID, PID du gate, vendor) sont FIGÉS dans le
# script au moment du write ; les \$ échappés sont évalués DANS le sandbox. Rapport ANCRÉ sur le
# chemin $POD_DIR EMBARQUÉ (= même chemin in-sandbox, bind identité) et PAS sur \$HOME : un HOME
# cassé doit devenir un FAIL enregistré (env_home), jamais un rapport perdu dégradé en SKIP.
# ---------------------------------------------------------------------------
EXPECTED_CHECKS=17
cat > "$POD_DIR/.iso-probe.sh" <<PROBE
#!/bin/sh
R="$POD_DIR/iso-report"
: > "\$R"
ck() { s=\$1; shift; if [ "\$s" = 0 ]; then echo "PASS \$1" >> "\$R"; else shift; echo "FAIL \$*" >> "\$R"; fi; }

[ "\${HOME:-}" = "$POD_DIR" ];            ck \$? env_home env_home "HOME='\${HOME:-}' != pod home $POD_DIR"
[ ! -e "$SENTINEL" ];                     ck \$? iso_home iso_home "sentinelle host LISIBLE: $SENTINEL"
[ ! -e "$TMP_CANARY" ];                   ck \$? iso_tmp iso_tmp "canari /tmp host LISIBLE: $TMP_CANARY"
[ -z "\${LCARS_ISO_ENV_CANARY:-}" ];      ck \$? iso_env iso_env "env ambiant FUITÉ malgré --clearenv"
[ "\${GIT_AUTHOR_NAME:-}" = "gate-r01" ]; ck \$? env_forward env_forward "GIT_AUTHOR_NAME='\${GIT_AUTHOR_NAME:-}'"
[ "\$(cat "\$HOME/.claude/.credentials.json" 2>/dev/null)" = "$CREDS_NONCE" ]; \
                                          ck \$? creds_bind creds_bind "contenu creds != nonce attendu"
printf 'rw:%s' "$CREDS_RW_NONCE" >> "\$HOME/.claude/.credentials.json" 2>/dev/null; \
                                          ck \$? creds_rw_pod creds_rw_pod "append creds refusé in-pod (bind pas RW)"
[ -x "\$HOME/.local/bin/$VENDOR_NAME" ];  ck \$? vendor_native vendor_native "\$HOME/.local/bin/$VENDOR_NAME absent/non-x"
V="\$(timeout 20 "\$HOME/.local/bin/$VENDOR_NAME" --version 2>&1)"; \
                                          ck \$? vendor_exec vendor_exec "--version KO: \$V"
echo "INFO vendor_version: \$V" >> "\$R"
! touch "\$HOME/.local/bin/$VENDOR_NAME" 2>/dev/null; \
                                          ck \$? ro_vendor_bind ro_vendor_bind "bind vendor ÉCRIVABLE (RO cassé)"
if ( : > /usr/.gate-r01-ro ) 2>/dev/null; then rm -f /usr/.gate-r01-ro; false; else true; fi; \
                                          ck \$? ro_usr ro_usr "/usr ÉCRIVABLE dans le pod (roots système pas RO)"
[ ! -e /etc/shadow ];                     ck \$? etc_shadow etc_shadow "/etc/shadow VISIBLE (bind /etc trop large)"
[ -e /etc/resolv.conf ];                  ck \$? etc_dns etc_dns "resolv.conf ABSENT (DNS du pod mort)"
[ "\${GIT_CONFIG_GLOBAL:-}" = "/dev/null" ]; \
                                          ck \$? env_git_global env_git_global "GIT_CONFIG_GLOBAL='\${GIT_CONFIG_GLOBAL:-}'"
[ "\${LCARS_POD_ID:-}" = "$POD_ID" ];     ck \$? env_pod_id env_pod_id "LCARS_POD_ID='\${LCARS_POD_ID:-}'"
[ ! -d /proc/$$ ];                        ck \$? pid_ns pid_ns "PID host $$ VISIBLE dans /proc (unshare-pid KO)"
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
LAUNCHER_DIED=0
for _ in $(seq 1 60); do
  if [[ -f "$REPORT" ]] && grep -q '^END ' "$REPORT" 2>/dev/null; then break; fi
  if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
    wait "$LAUNCH_PID" 2>/dev/null || true
    LAUNCHER_DIED=1
    break
  fi
  sleep 0.5
done

# ---------------------------------------------------------------------------
# Verdict 3-états sur RAPPORT — compte exigé, jamais vert sur rapport vide/partiel (F-C166/167).
# ---------------------------------------------------------------------------
FAIL=0
if grep -q '^END ' "$REPORT" 2>/dev/null; then
  # HOLDER : le launcher doit être encore vivant (bwrap-PID1 tient le namespace, ADR-G).
  if [[ "$LAUNCHER_DIED" -eq 0 ]] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
    echo "PASS HOLDER  bwrap-PID1 vivant après la sonde (modèle détaché tient)"
  else
    echo "FAIL HOLDER  launcher mort après la sonde (holder ADR-G cassé)"; FAIL=1
  fi
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
  # creds_rw_host — jugé HOST-SIDE : l'append fait DANS le pod doit être visible dans le fichier
  # creds host (bind single-file RW = LE chemin du refresh OAuth ADR-F ; sans propagation, un pod
  # long perdrait son auth en silence).
  if grep -q "rw:$CREDS_RW_NONCE" "$WORK/claude-dir/.credentials.json" 2>/dev/null; then
    echo "PASS creds_rw_host  append in-pod propagé au fichier creds host (refresh ADR-F viable)"
  else
    echo "FAIL creds_rw_host  append in-pod NON propagé au fichier creds host"; FAIL=1
  fi
elif grep -q '^FAIL ' "$REPORT" 2>/dev/null; then
  # Rapport INACHEVÉ mais constat rouge déjà gravé : un FAIL ne se dégrade JAMAIS en SKIP.
  echo "FAIL PROBE   sonde interrompue avec invariant(s) déjà KO :"
  sed 's/^/   | /' "$REPORT"
  FAIL=1
elif [[ "$LAUNCHER_DIED" -eq 1 ]]; then
  # Mort AVANT le détachement = échec de setup du launcher (guards :?/exit 1|2) : l'isolation n'a
  # été NI prouvée NI infirmée → SKIP avec la cause réelle. L'ancien gate prenait exactement ce
  # chemin pour un PASS ISO ; le déguiser en FAIL d'isolation serait l'autre mensonge.
  echo "   bwrap_launch mort en setup (aucune isolation testée) — launch.log :"
  sed 's/^/   | /' "$WORK/launch.log" 2>/dev/null || true
  skip3 "launcher mort AVANT bwrap (contrat env/provisioning — cf. log ci-dessus, KEEP=1 pour investiguer)"
else
  # Ni verdict, ni constat, launcher vivant : la sonde n'a pas pu tourner (tmux/sonde KO dans le
  # sandbox ?) → SKIP explicite, jamais un vert.
  echo "   sonde sans verdict après 30s — launch.log :"
  sed 's/^/   | /' "$WORK/launch.log" 2>/dev/null || true
  skip3 "la sonde n'a pas rendu de verdict (rapport absent, aucun FAIL gravé) — KEEP=1 pour investiguer"
fi

echo "---"
if [[ "$FAIL" -eq 0 ]]; then
  echo "GATE R0.1 : exit 0 — bwrap primitive porte (isolation prouvée de l'intérieur, vrai launcher)"
else
  echo "GATE R0.1 : exit 1 — ne porte pas"
fi
exit "$FAIL"
