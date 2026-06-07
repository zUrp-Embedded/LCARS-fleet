#!/usr/bin/env bash
# SOURCE: bin/bwrap_launch.sh
# AUTHOR: engineer
# STARDATE: 2026-06-01
# STATUS: PROD-V2 — containment N0 + tmux PTY persistant + socket-dir par-pod + holder bwrap-PID1 + die-with-parent
#
# Sanctuaire (N0, Ring 1 pod primitive, vendor-agnostic). Déroule la DN
# `beyond_#5/design-notes/spawn/containment-bwrap.md` (DRAFT, REWORK PROVEN terrain 2026-05-31).
# bwrap N'EST PAS une prison qui isole une menace — c'est un SANCTUAIRE : il PROJETTE un monde clos
# (« qu'est-ce qu'on fournit », default vide-sauf-provision), donc « les murs portent la sécurité, pas
# le SP » (I-CBC : ce qui n'est pas projeté n'existe pas → pas de règle à mettre dans la tête de l'agent).
#
# Modèle ADR-G : le command (`claude_launch.sh`, opaque) tourne dans un **PTY tmux persistant** DANS
# bwrap, via une **socket-DIR par-pod**. `tmux new-session -d` détache la session ; un **HOLDER**
# (`exec sleep infinity` après la création) garde bwrap-PID1 vivant → le namespace + le serveur tmux
# survivent. CORR. TERRAIN 2026-06-01 : SANS holder, bwrap sort dès que `new-session -d` rend la main
# et TUE le namespace (donc le pod) — le modèle "bwrap-PID1 tient le détaché tout seul / moniteur rend
# la main en ~13 ms" de la DN containment-bwrap est **FALSIFIÉ** (prouvé e2e). bwrap NE rend donc PAS
# la main : ce process EST le pod (handle Port spawner). Validation boot ASYNC côté spawner
# (`tmux list-sessions`) ; teardown = close Port / SIGTERM. `--die-with-parent` = orphan-safe.
#
# Frontière N0/N1 (IX.2/IX.3) : tmux = N0 (tient n'importe quel REPL). bwrap_launch ne connaît PAS les
# flags `claude` (c'est `claude_launch.sh`, command opaque dans ${COMMAND[@]}).
#
# Usage : bwrap_launch.sh <role> <pod_id> <pod_dir> <command...>
# Env identité/session (posés par le spawner avant Port.open ; propagés via --setenv) :
#   LCARS_POD_SESSION_ID          UUID pré-alloué — requis (:? strict, consommé par claude_launch)
#   LCARS_POD_RESUME              0|1 (1ʳᵉ création / recovery) — défaut 0
#   LCARS_POD_SESSION_NAME_PREFIX <human>_<role> nom RC lisible — requis (:? strict)
#   CLAUDE_DIR                    claudeDir du compte humain — requis (utilisé selon LCARS_AUTH_MODE)
#   LCARS_AUTH_MODE               bind (défaut, adr-f) | token_arg (BL-021 chantier 6) :
#                                   - bind     : bind RW de CLAUDE_DIR/.credentials.json SEUL →
#                                                pod_dir/.claude/.credentials.json (refresh natif
#                                                Anthropic en place + mtime sync). PAS le .claude
#                                                humain entier — sinon ses hooks fuient et jamment
#                                                le boot (P1/C9, JOURNAL-P1-hooks.md). .claude/ pod-owned.
#                                   - token_arg (DÉFAUT): pas de bind ; CLAUDE_CODE_OAUTH_TOKEN injecté via env
#                                                (LCARS_ANTHROPIC_AUTH_TOKEN extrait par le spawner
#                                                depuis CLAUDE_DIR/.credentials.json). Désactive le
#                                                refresh natif → viable si pod < ~8h (durée de vie
#                                                access_token) ou recovery 401 côté Pod GenServer.
#   LCARS_ANTHROPIC_AUTH_TOKEN    access_token OAuth — requis SSI LCARS_AUTH_MODE=token_arg
#   LCARS_POD_CWD                 cwd du pod = racine de la branche/repo (monde-invoqué, align Claude
#                                 Code natif /init) — défaut $POD_DIR (le bootstrap/spawner le pose
#                                 sur $POD_DIR/<repo> pour un pod-projet).
#
# Exit codes : 0 succès (le pod est lancé détaché) | 1 setup error | 2 bwrap/vendor missing
#
# DELTA vs DN containment-bwrap (DRAFT) — corrections de la synthèse principes→spawn 2026-06-01 :
#   + --clearenv            (env CLOS : tout en --setenv explicite ; sinon l'ambient du spawner fuit)
#   + DISABLE_AUTO_MEMORY   (pod stateless : pas d'auto-memory cachée qui drifte/meurt au nuke)
#   + LCARS_POD_CWD         (cwd = racine de branche, pas $POD_DIR — align Claude Code natif)
#   (à réconcilier dans la DN containment-bwrap au prochain tour doctrine.)

set -euo pipefail

# =============================================================
# Config (overridable via env)
# =============================================================

CLAUDE_DIR="${CLAUDE_DIR:?CLAUDE_DIR required (claudeDir du compte humain, resolu par Fleet.Spawner — adr-f)}"
GIT_MIRROR="${LCARS_GIT_MIRROR:-/var/lib/lcars/git-mirror}"
BWRAP_BIN="${LCARS_BWRAP_BIN:-/usr/bin/bwrap}"
TMUX_BIN="${LCARS_TMUX_BIN:-/usr/bin/tmux}"

# Vendor runtime (R0.1) — binaire per-user du humain, relocalisé à son emplacement natif DANS le pod
# ($POD_DIR/.local/bin/<vendor>), sinon masqué par --tmpfs /home. Autorité = LCARS_VENDOR_BIN (spawner).
VENDOR_NAME="${LCARS_VENDOR_NAME:-claude}"
VENDOR_BIN="${LCARS_VENDOR_BIN:-$(readlink -f "$(command -v "$VENDOR_NAME" 2>/dev/null)" 2>/dev/null || true)}"
VENDOR_SHARE="${LCARS_VENDOR_SHARE:-$([ -n "$VENDOR_BIN" ] && dirname "$(dirname "$VENDOR_BIN")" || true)}"

# Socket-dir par-pod (P1 panel #1 — bind du DIR, pas du fichier inexistant). Parent provisionné à
# l'install (systemd-tmpfiles.d, `lcars-fleet_service`). Base overridable pour tests (pas de /run perms).
SOCK_PARENT="${LCARS_TMUX_SOCK_BASE:-/run/lcars/tmux-sock}"

# =============================================================
# Args
# =============================================================

if [[ $# -lt 4 ]]; then
  echo "ERR: usage: $0 <role> <pod_id> <pod_dir> <command...>" >&2
  exit 1
fi
ROLE="$1"; POD_ID="$2"; POD_DIR="$3"; shift 3
COMMAND=("$@")
[[ -z "$ROLE" || -z "$POD_ID" || -z "$POD_DIR" ]] && { echo "ERR: role, pod_id, pod_dir must be non-empty" >&2; exit 1; }

# Identité/session (lues de l'env, posées par le spawner ; :? strict — claude_launch les exige aussi).
SESSION_ID="${LCARS_POD_SESSION_ID:?UUID de session requis (pré-alloué par le spawner)}"
POD_RESUME="${LCARS_POD_RESUME:-0}"
SESSION_NAME_PREFIX="${LCARS_POD_SESSION_NAME_PREFIX:?préfixe nom RC requis (<human>_<role>)}"

# cwd = racine de branche (monde-invoqué). Défaut $POD_DIR ; le spawner/bootstrap pose le repo cloné.
WORKDIR="${LCARS_POD_CWD:-$POD_DIR}"

# Mode auth — mundo invocado #1 (2026-06-07) : DÉFAUT = token_arg (inject, zéro mount du compte humain).
#   token_arg : pas de bind ; access_token OAuth injecté en env CLAUDE_CODE_OAUTH_TOKEN (abonnement —
#               inférence + MCP get_task/submit_result + Monitor PROUVÉS verts ; pas de bridge RC = confort).
#               Source = creds.json du HUMAIN propriétaire du pod (per-human), extrait côté spawner.
#   bind      : legacy ADR-F (bind RW de .credentials.json) — conservé comme échappatoire opt-in.
AUTH_MODE="${LCARS_AUTH_MODE:-token_arg}"
case "$AUTH_MODE" in
  bind|token_arg) ;;
  *) echo "ERR: LCARS_AUTH_MODE='$AUTH_MODE' invalide (attendu: bind | token_arg)" >&2; exit 1 ;;
esac
if [[ "$AUTH_MODE" == "token_arg" ]]; then
  OAUTH_TOKEN_VALUE="${LCARS_ANTHROPIC_AUTH_TOKEN:?LCARS_ANTHROPIC_AUTH_TOKEN requis quand LCARS_AUTH_MODE=token_arg (access_token OAuth extrait de creds.json côté spawner, per-human)}"
fi

# Session tmux (nom INTERNE, distinct du préfixe nom RC claude — P3 panel #13).
POD_SOCK_DIR="$SOCK_PARENT/$POD_ID"
TMUX_SESSION_NAME="lcars-pod-$POD_ID"
# Filename CONSTANT (pas ${TMUX_SESSION_NAME}.sock) : le dir $POD_ID/ donne déjà
# l'unicité. Le double pod_id (dir + filename) dépassait sun_path 108o pour un
# pod_id UUID (chemin pipeline) → "File name too long". MÊME chemin côté Elixir
# (Fleet.Spawner.PodTmux.sock_path = <base>/<pod_id>/pod.sock).
TMUX_SOCK="$POD_SOCK_DIR/pod.sock"
POD_VENDOR_BIN="$POD_DIR/.local/bin/$VENDOR_NAME"

# =============================================================
# Trap cleanup (P2 panel #7) — utile PRÉ-exec uniquement : `exec` remplace le shell, donc le EXIT trap
# ne se déclenche QUE si on sort avant `exec` (assertion/setup failed). Sur succès, le pod est lancé
# détaché et survit. state.json vit HORS $POD_DIR → jamais affecté. Opt-out caller (spawner lifecycle).
# =============================================================
if [[ "${LCARS_BWRAP_NO_CLEANUP:-0}" != "1" ]]; then
  trap 'rm -rf "$POD_DIR" "$POD_SOCK_DIR" 2>/dev/null || true' EXIT ERR
fi

# =============================================================
# Setup checks
# =============================================================
[[ -x "$BWRAP_BIN" ]] || { echo "ERR: bwrap missing/not-x: $BWRAP_BIN" >&2; exit 2; }
[[ -x "$TMUX_BIN"  ]] || { echo "ERR: tmux missing/not-x: $TMUX_BIN (N0 PTY host)" >&2; exit 2; }
if [[ -z "$VENDOR_BIN" || ! -x "$VENDOR_BIN" || ! -d "$VENDOR_SHARE" ]]; then
  echo "ERR: vendor '$VENDOR_NAME' introuvable (bin=$VENDOR_BIN share=$VENDOR_SHARE) — set LCARS_VENDOR_BIN" >&2; exit 2
fi
[[ -d "$CLAUDE_DIR"  ]] || { echo "ERR: claudeDir $CLAUDE_DIR missing (registration humain — adr-f)" >&2; exit 1; }
[[ -d "$GIT_MIRROR"  ]] || { echo "ERR: git mirror $GIT_MIRROR missing (provisioning starfleet)" >&2; exit 1; }
[[ -d "$POD_DIR"     ]] || { echo "ERR: pod_dir $POD_DIR missing (caller responsibility)" >&2; exit 1; }

# Socket-dir par-pod host-side AVANT le launch (tmux y créera la socket ; on bind le dir). En prod le
# spawner le crée ; ici idempotent. Parent doit exister (provisionné install) — fail-fast au boundary.
[[ -d "$SOCK_PARENT" ]] || { echo "ERR: sock parent $SOCK_PARENT absent (provisioning systemd-tmpfiles.d / LCARS_TMUX_SOCK_BASE)" >&2; exit 1; }
install -d -m 0700 "$POD_SOCK_DIR"
install -d -m 0755 "$POD_DIR/.local/bin"

# =============================================================
# Plugins Claude Code natifs (bind RO host→pod, whitelist LCARS_SKILLS_PLUGINS).
# (Vecteur de cascade arch→worker : un worker bare n'a aucun plugin par défaut = liste vide.)
# =============================================================
PLUGIN_BINDS=()
set -f
for plugin in ${LCARS_SKILLS_PLUGINS:-}; do
  # Allowlist stricte du NOM (audit deep-04 S5) : le nom est interpolé dans des paths de bind. Sans
  # garde, un nom forgé (`..`, `/`, leading-dot) = path-traversal hors ~/.claude/plugins. Rejet avant
  # toute construction de path. (La source cap-profile doit rester opérateur-de-confiance ; ceinture.)
  case "$plugin" in
    *..* | */* | .*) echo "ERR: nom de plugin invalide '$plugin' (path-traversal)" >&2; exit 1 ;;
  esac
  [[ "$plugin" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERR: nom de plugin invalide '$plugin' (allowlist [A-Za-z0-9._-])" >&2; exit 1; }
  HOST_PLUGIN_PATH="$HOME/.claude/plugins/$plugin"
  [[ -d "$HOST_PLUGIN_PATH" ]] || { echo "ERR: plugin '$plugin' not installed host-side at $HOST_PLUGIN_PATH" >&2; exit 1; }
  PLUGIN_BINDS+=(--ro-bind "$HOST_PLUGIN_PATH" "$POD_DIR/.claude/plugins/$plugin")
done
set +f

# =============================================================
# exec bwrap → HOLDER sh → (tmux new-session -d détaché + exec sleep infinity) → command.
#   HOLDER (corr. terrain 2026-06-01) : `new-session -d` rend la main aussitôt ; si c'était le process
#   avant-plan de bwrap, bwrap sortirait et TUERAIT le namespace + le serveur tmux (donc le pod). Le
#   `exec sleep infinity` après la création garde PID1 vivant → bwrap bloque = handle de vie du pod
#   (Port spawner ; close → SIGTERM → sleep meurt → namespace+tmux+claude tombent ensemble).
#   sock/name/command passés en ARGS du holder ($1/$2/$3/$@) ⇒ argv préservé, zéro re-parsing shell.
#   --clearenv : ENV CLOS — rien de l'ambient du spawner ne fuit ; tout est --setenv explicite.
#   La discipline est dans les MURS (binds = ce qui existe) + l'ENV (ce qui est posé), pas dans le SP.
# =============================================================
# BL-021 chantier 6 — branchement bind vs token_arg sur LCARS_AUTH_MODE :
#   bind     : bind RW de CLAUDE_DIR/.credentials.json SEUL (legacy ADR-F).
#   token_arg (DÉFAUT): pas de bind claudeDir (pod isolé), --setenv CLAUDE_CODE_OAUTH_TOKEN <token>.
#
# P1/C9 (2026-06-07) — on NE bind PLUS le .claude humain entier. Raison : cwd=HOME=POD_DIR, donc les
# tiers settings `project`/`local` (racine=cwd, activés par --setting-sources project,local)
# résolvaient dans le .claude humain bindé → le settings.json humain était chargé comme settings
# *projet* → ses hooks (session-startup.sh…) s'exécutaient → plantent → retry 10× → JAM au boot.
# Le flag ne pouvait rien (il autorise project/local). Fix : seul `.credentials.json` est bindé
# (refresh OAuth natif = écriture EN PLACE, survit au bind single-file + réécrit le fichier humain) ;
# `.claude/` reste pod-owned (créé par do_project) → 0 settings.json humain → 0 hook. Détail
# mécanisme : validation-pod/JOURNAL-P1-hooks.md.
AUTH_BIND_ARGS=()
AUTH_ENV_ARGS=()
if [[ "$AUTH_MODE" == "bind" ]]; then
  HUMAN_CREDS="$CLAUDE_DIR/.credentials.json"
  [[ -f "$HUMAN_CREDS" ]] || { echo "ERR: creds $HUMAN_CREDS missing (registration humain — adr-f)" >&2; exit 1; }
  # `.claude/` pod-owned doit exister host-side pour héberger le mountpoint creds (POD_DIR est lui-même
  # bind-monté RW → ce mkdir est visible dans le sandbox). do_project le crée déjà ; défensif ici.
  mkdir -p "$POD_DIR/.claude"
  AUTH_BIND_ARGS=(--bind "$HUMAN_CREDS" "$POD_DIR/.claude/.credentials.json")
else
  # CLAUDE_CODE_OAUTH_TOKEN = chemin abonnement (cf. reverse oauth-token-lifecycle §10.1).
  # ≠ ANTHROPIC_AUTH_TOKEN (Bearer gateway) ≠ ANTHROPIC_API_KEY (X-Api-Key) — ces deux-là = métré, morts 15/06.
  AUTH_ENV_ARGS=(--setenv CLAUDE_CODE_OAUTH_TOKEN "$OAUTH_TOKEN_VALUE")
fi

# Télémétrie ↔ feature-flags. Les flags Statsig/GrowthBook (dont `MONITOR_TOOL`, qui expose
# l'outil Monitor = réveil-par-flag du pod, cf. investigation 2026-06-07 :
# beyond_#5/.../investigation-monitor/JOURNAL.md) sont fetchés via le pipeline télémétrie.
# `DISABLE_TELEMETRY=1` + `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` COUPENT ce fetch → `MONITOR_TOOL`
# défaut OFF → l'agent retombe sur le kick `yop` (send-keys) au lieu du Monitor. Le contenu reste
# 100% MCP (get_task/submit_result) dans les deux cas. Arbitrage acté (user) : on PRIVILÉGIE le
# Monitor → télémétrie ACTIVE par défaut. Mode privacy opt-in : `LCARS_POD_DISABLE_TELEMETRY=1`
# (pas de Monitor, fallback yop). Le couplage télémétrie→Monitor est côté relais Anthropic, pas
# notre choix ; l'override `CLAUDE_INTERNAL_FC_OVERRIDES` est gardé `USER_TYPE=ant` (interne, inerte
# sur le binaire public) → non utilisable.
TELEMETRY_ENV=()
if [[ "${LCARS_POD_DISABLE_TELEMETRY:-0}" == "1" ]]; then
  TELEMETRY_ENV=(--setenv DISABLE_TELEMETRY "1" --setenv CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC "1")
fi

# Monde minimal (#2 mundo invocado) : resolv.conf est souvent un symlink HORS /etc (WSL → /mnt/wsl ;
# systemd-resolved → /run). Comme on bind /etc seul (pas `/ /`), il faut binder le fichier RÉEL à son
# path d'origine pour que le symlink /etc/resolv.conf résolve dans le pod — sinon DNS mort → claude
# hang sur l'API (POC 2026-06-07, gotcha WSL). On ne peut PAS override sous /etc RO ⇒ bind au vrai path.
RESOLV_BIND=()
RESOLV_REAL="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
if [[ -n "$RESOLV_REAL" && "$RESOLV_REAL" != /etc/* && -e "$RESOLV_REAL" ]]; then
  RESOLV_BIND=(--ro-bind "$RESOLV_REAL" "$RESOLV_REAL")
fi

exec "$BWRAP_BIN" \
  --unshare-all --share-net \
  --die-with-parent \
  --clearenv \
  --ro-bind /usr /usr \
  --symlink usr/bin /bin \
  --symlink usr/sbin /sbin \
  --symlink usr/lib /lib \
  --symlink usr/lib64 /lib64 \
  --ro-bind /etc /etc \
  ${RESOLV_BIND[@]+"${RESOLV_BIND[@]}"} \
  --ro-bind /sys /sys \
  --tmpfs /home \
  --tmpfs /tmp \
  --dev /dev --proc /proc \
  --bind "$POD_DIR" "$POD_DIR" \
  ${AUTH_BIND_ARGS[@]+"${AUTH_BIND_ARGS[@]}"} \
  --ro-bind "$GIT_MIRROR" "$GIT_MIRROR" \
  --ro-bind "$VENDOR_BIN" "$POD_VENDOR_BIN" \
  --ro-bind "$VENDOR_SHARE" "$POD_DIR/.local/share/$VENDOR_NAME" \
  --bind "$POD_SOCK_DIR" "$POD_SOCK_DIR" \
  ${PLUGIN_BINDS[@]+"${PLUGIN_BINDS[@]}"} \
  --chdir "$WORKDIR" \
  --setenv HOME "$POD_DIR" \
  --setenv PATH "$POD_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin" \
  --setenv TERM "${TERM:-xterm-256color}" \
  --setenv LANG "${LANG:-C.UTF-8}" \
  --setenv LCARS_POD_ID "$POD_ID" \
  --setenv LCARS_ROLE "$ROLE" \
  --setenv LCARS_POD_CWD "$WORKDIR" \
  --setenv LCARS_AUTH_MODE "$AUTH_MODE" \
  --setenv LCARS_POD_SESSION_ID "$SESSION_ID" \
  --setenv LCARS_POD_RESUME "$POD_RESUME" \
  --setenv LCARS_POD_SESSION_NAME_PREFIX "$SESSION_NAME_PREFIX" \
  --setenv LCARS_CLAUDE_BIN "$POD_VENDOR_BIN" \
  --setenv DISABLE_AUTOUPDATER "1" \
  --setenv CLAUDE_CODE_DISABLE_AUTO_MEMORY "1" \
  --setenv CLAUDE_AUTOCOMPACT_PCT_OVERRIDE "100" \
  ${TELEMETRY_ENV[@]+"${TELEMETRY_ENV[@]}"} \
  ${AUTH_ENV_ARGS[@]+"${AUTH_ENV_ARGS[@]}"} \
  -- /bin/sh -c '
       tmux_bin=$1; sock=$2; name=$3; shift 3
       "$tmux_bin" -S "$sock" new-session -d -s "$name" "$@"
       exec sleep infinity
     ' sh "$TMUX_BIN" "$TMUX_SOCK" "$TMUX_SESSION_NAME" "${COMMAND[@]}"

# bwrap NE rend PAS la main (holder sleep infinity) : ce process EST le pod vivant (handle Port spawner).
# Validation ASYNC côté spawner : `tmux -S "$TMUX_SOCK" list-sessions` → session "lcars-pod-$POD_ID" ?
# Teardown côté spawner : close Port / SIGTERM ce process → sleep meurt → namespace + tmux + claude
# tombent ensemble ; --die-with-parent = orphan-safe si le spawner meurt. (sock-dir nettoyé par le spawner.)
