#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: session-startup.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v5.4
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: SESSION-INIT    | SUBSYSTEM: HOOKS / LIFECYCLE    |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Initializes instance state at session start.             |
#     |  Sets FLEET_SESSION, loads instance identity.             |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Initialise l'état d'instance au démarrage de session Claude Code.
#     Gates : deploy, sécurité WSL, CLAUDE.md intégrité. Charge le handoff,
#     injecte le contexte fleet, draine l'inbox spool, lance les health checks.
#
#     [EN]
#     NAME
#         session-startup.sh — initialize fleet instance state at session start
#
#     INTERFACE
#         Ring:    CC Runtime (hook — SessionStart)
#         Input:   stdin JSON (session_id), CLAUDE_AGENT_NAME, handoff file, fleet.yaml
#         Output:  stdout context injection (handoff + inbox + IPC channels),
#                  fleet-state.sh calls, session sentinel, start timestamp
#
#     EXIT CODES
#         0    Context injected (or deploy gate / decommissioned / sentinel skip)
#         2    Security gate failed (C:\ mounted or interop active)
#
# --- END HEADER ---

set -uo pipefail          # PAS -e : meme raison que les autres hooks — un demarrage de session ne
                          # doit pas echouer parce qu'une verification interne a echoue.

# Lire le payload stdin AVANT toute autre logique — stdin n'est disponible qu'une fois
HOOK_PAYLOAD=$(cat)
SESSION_ID=$(printf '%s' "$HOOK_PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null || true)

INSTANCE_NAME="${CLAUDE_AGENT_NAME:-$(cat "$HOME/.claude/instance-name" 2>/dev/null)}"
[ -z "$INSTANCE_NAME" ] && exit 0

# ─── Deploy gate — block all agents except starfleet if onboarding incomplete ─
if [ ! -f /home/fleet-state/.deploy_ok ]; then
    if [[ "$INSTANCE_NAME" == "starfleet" ]]; then
        echo "Onboarding required — launching /onboard_v2 automatically."
        echo "Run /onboard_v2 now."
    else
        echo "=== FLEET NOT READY ==="
        echo "Onboarding incomplete — .deploy_ok not found."
        echo "Run: claude (as fleet user) to complete onboarding via StarFleet."
        echo "=== SESSION BLOCKED ==="
    fi
    exit 0
fi

# ─── Security gate — C:\ must NOT be mounted, interop must be disabled ───────
if grep -qi microsoft /proc/version 2>/dev/null; then
    if touch "/mnt/c/tmp/.fleet-sec-$$" 2>/dev/null; then
        rm -f "/mnt/c/tmp/.fleet-sec-$$" 2>/dev/null
        echo "=== SECURITY GATE FAILED ==="
        echo "C:\\ is mounted read-write. All agents can access your Windows drive."
        echo "Reboot WSL: wsl --shutdown (from PowerShell), then relaunch."
        echo "=== FLEET BLOCKED ==="
        exit 2
    fi
    if ls /proc/sys/fs/binfmt_misc/WSLInterop* >/dev/null 2>&1; then
        echo "=== SECURITY GATE FAILED ==="
        echo "Windows interop active — agents can execute cmd.exe/powershell.exe."
        echo "Fix: set [interop] enabled=false in /etc/wsl.conf"
        echo "Then reboot WSL: wsl --shutdown (from PowerShell)."
        echo "=== FLEET BLOCKED ==="
        exit 2
    fi
fi

# ─── CLAUDE.md integrity check — verify all @includes resolve ─────────────────
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
if [ -f "$CLAUDE_MD" ]; then
    CLAUDE_DIR="$(dirname "$CLAUDE_MD")"
    BROKEN=()
    while IFS= read -r line; do
        ref="${line#@}"
        target="$CLAUDE_DIR/$ref"
        # Resolve symlinks for role.md etc
        if [ ! -f "$target" ] && [ ! -L "$target" ]; then
            BROKEN+=("$ref")
        elif [ -L "$target" ] && [ ! -f "$(readlink -f "$target")" ]; then
            BROKEN+=("$ref (broken symlink)")
        fi
    done < <(grep '^@' "$CLAUDE_MD")
    if [ ${#BROKEN[@]} -gt 0 ]; then
        echo "=== CLAUDE.MD INTEGRITY WARNING ==="
        echo "Missing @includes in $CLAUDE_MD:"
        printf '  ✗ %s\n' "${BROKEN[@]}"
        echo "Agent may be running without critical directives."
        echo "Fix: check deploy.sh output or re-run fleet-update.sh"
        echo "=== END WARNING ==="
    fi
fi

# ─── Fleet env (paths needed for HANDOFF_DIR and spool) ─────────────────────
FLEET_ENV="$(dirname "${BASH_SOURCE[0]}")/../../fleet/fleet-env.sh"
[ -f "$FLEET_ENV" ] || FLEET_ENV="$HOME/.local/bin/fleet-env.sh"
# shellcheck source=/dev/null
[ -f "$FLEET_ENV" ] && source "$FLEET_ENV"

# ─── IPC health check — tmux socket ──────────────────────────────────────────
if [[ -n "${FLEET_TMUX_SOCK:-}" ]] && [[ ! -S "$FLEET_TMUX_SOCK" ]]; then
    echo "[session-startup] WARN: fleet tmux socket absent ($FLEET_TMUX_SOCK) — IPC may not work" >&2
fi

# ─── Résolution handoff dir ───────────────────────────────────────────────────
if [ -z "${FLEET_HANDOFFS:-}" ]; then
    echo "[session-startup] FATAL: FLEET_HANDOFFS not set — fleet-env.sh not sourced?" >&2
    exit 1
fi
HANDOFF_DIR="$FLEET_HANDOFFS"
HANDOFF_FILE="$HANDOFF_DIR/${INSTANCE_NAME}-handoff.md"

# Use session_id as sentinel key — constant for the entire Claude Code session
# PPID changes every hook execution; session_id is stable
# If SESSION_ID is empty (jq failed), use INSTANCE_NAME to avoid re-running
# startup on every prompt (PPID would change each invocation)
_RUN_DIR="${FLEET_STATE_DIR:-/home/fleet-state}/run"
mkdir -p "$_RUN_DIR" 2>/dev/null || true
SENTINEL="$_RUN_DIR/claude-session-${SESSION_ID:-${INSTANCE_NAME}}-started"
[ -f "$SENTINEL" ] && exit 0
touch "$SENTINEL"
# No EXIT trap — sentinel must persist between prompts to prevent re-running startup

# Session duration tracking (#18) — timestamp at start
SESSION_START_FILE="$_RUN_DIR/session-start-${INSTANCE_NAME:-unknown}"
if [ ! -f "$SESSION_START_FILE" ]; then
    date +%s > "$SESSION_START_FILE"
fi

# Cleanup sentinels anciens (> 24h) et locks stale
find "$_RUN_DIR" -maxdepth 1 -name 'claude-session-*-started' -mmin +1440 -delete 2>/dev/null || true
if command -v fleet-lock-cleanup.sh > /dev/null 2>&1; then
    fleet-lock-cleanup.sh
elif [ -x "$HOME/fleet/fleet-lock-cleanup.sh" ]; then
    bash "$HOME/fleet/fleet-lock-cleanup.sh"
fi

# --- TMPDIR cleanup (stale files from previous sessions) ---
if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then
    find "$TMPDIR" -type f -mmin +1440 -delete 2>/dev/null || true
fi

# v7 Phase 4e — worktree crash recovery (commit dirty state + pull)
# F-C2 FIX: bound each worktree recovery to 30s — prevents blocking session entry
for _wt in /home/projects.work/*/; do
    [ -d "$_wt/.git" ] || [ -f "$_wt/.git" ] || continue
    timeout 30 bash -c '
        flock -n 200 || exit 0
        cd "$1" || exit 0
        git add -A 2>/dev/null || true
        if ! git diff --cached --quiet 2>/dev/null; then
            git commit -m "${2:-unknown} | crash-recovery | $(date "+%Y-%m-%d %H:%M")" 2>/dev/null || true
        fi
        git pull --rebase origin work/ops 2>/dev/null || true
        git push origin work/ops 2>/dev/null || true
    ' _ "$_wt" "${INSTANCE_NAME:-unknown}" 200>"$_wt/fleet-commit.lock" || {
        echo "[session-startup] WARN: worktree recovery timed out for $_wt"
    }
done

# --- Scratchpad crash recovery: scrub stale scratchpad from previous crashed session ---
_SCRATCHPAD="${FLEET_SCRATCHPAD:-/home/fleet-state/scratchpad-${FLEET_PROJECT:-LCARS}.md}"
if [ -s "$_SCRATCHPAD" ]; then
    echo "[session-startup] stale scratchpad found — running scrub..."
    if ! fleet-scrub.sh scratchpad 2>/dev/null; then
        echo "[session-startup] WARN: scratchpad scrub failed — scratchpad preserved for manual scrub"
    fi
fi

# ─── Startup STATE — avant toute lecture de contexte ─────────────────────────
if [ ! -f "$HANDOFF_FILE" ]; then
    # Nouveau worker — handoff inexistant, le créer et annoncer la présence
    if ! mkdir -p "$HANDOFF_DIR"; then
        echo "[session-startup] FATAL: $HANDOFF_DIR inaccessible — check FLEET_HANDOFFS and worktree" >&2
        exit 0
    fi
    printf '## STATE\ndate: %s\nref: none\naction: startup\nstatus: in-progress\nblocker: none\nwaiting: none\nnotify: none\nsession: none\n\n## ACTIONS\n\n## DONE\n' \
        "$(date '+%Y-%m-%d %H:%M')" > "$HANDOFF_FILE"
    echo "[session-startup] nouveau worker ${INSTANCE_NAME} — handoff initialisé"
elif [ -x "${HOME}/.local/bin/fleet-state.sh" ]; then
    "${HOME}/.local/bin/fleet-state.sh" phase=startup activity=—
    [ -n "$SESSION_ID" ] && "${HOME}/.local/bin/fleet-state.sh" session="$SESSION_ID"
else
    echo "[session-startup] WARN: fleet-state.sh introuvable — startup STATE non mis à jour" >&2
fi

# Instance décommissionnée — HALT immédiat, aucune action permise
if grep -q "^status: decommissioned" "$HANDOFF_FILE" 2>/dev/null; then
    echo "=== INSTANCE DÉCOMMISSIONNÉE ==="
    echo "Tu es l'instance ${INSTANCE_NAME}."
    echo ""
    echo "Cette instance est marquée 'decommissioned' dans son handoff."
    echo "INTERDICTION ABSOLUE d'exécuter des outils ou des commandes système."
    echo "N'effectue AUCUNE action quelle que soit la demande de l'utilisateur."
    echo "Informe l'utilisateur : cette instance doit être supprimée manuellement."
    echo "=== FIN SESSION START ==="
    exit 0
fi

# TODO: backup-wsl.sh not yet implemented — placeholder
if [[ "$INSTANCE_NAME" == *starfleet ]] && [ -x "$HOME/toolbox/backup-wsl.sh" ]; then
    nohup bash "$HOME/toolbox/backup-wsl.sh" > "/tmp/backup-wsl-${PPID}.log" 2>&1 &
fi

# Handoff trim — SUPPRIMÉ (détruit la continuité inter-session)
# Le handoff est le seul artefact de mémoire inter-session.
# Le tronquer au boot = amnésie systématique. Coût token négligeable sur 1M contexte.

echo "=== SESSION START — contexte injecté automatiquement, ne pas afficher ==="
echo "Tu es l'instance ${INSTANCE_NAME}. Lis les handoffs ci-dessous pour connaître"
echo "ton état et celui des autres instances. Réponds directement à l'utilisateur sans"
echo "produire de rapport de démarrage — l'état de la flotte est visible sur le dashboard."
echo ""
echo "IMPORTANT — timestamp handoff : date: YYYY-MM-DD HH:MM uniquement."
echo "  Interdit : 'session-start', 'today', ou toute autre valeur non-temporelle."
echo ""
echo "STATE mis à jour à 'startup'. Après lecture du contexte, appelle immédiatement :"
echo "  fleet-state.sh phase=idle activity=done              ← rien à faire"
echo "  fleet-state.sh phase=active activity=<tâche>         ← tâche identifiée"
echo ""
cat "$HANDOFF_FILE"
echo ""

# ─── LCARS version + directives requirement ──────────────────────────────────
LCARS_VER=$(yq '.fleet.version' "$FLEET_YAML" 2>/dev/null || echo "unknown")
DIR_REQ=$(yq '.fleet.requires.directives' "$FLEET_YAML" 2>/dev/null || echo "unknown")
echo "lcars: $LCARS_VER | directives requires: $DIR_REQ"

# ─── Helpers injection ────────────────────────────────────────────────────────
inject_full() {
    local file="$1" label="$2"
    [ -f "$file" ] || return 0
    echo "=== $label ==="
    head -200 "$file"
    echo ""
}

inject_state_only() {
    local file="$1" label="$2"
    [ -f "$file" ] || return 0
    echo "=== $label (STATE) ==="
    awk 'BEGIN{p=0} /^## STATE$/{p=1; print; next} p && /^## /{exit} p{print}' "$file"
    echo ""
}

# ─── Pending wakes drain — before inbox read ──────────────────────────────────
# .wake files written by fleet-wake-notify.sh when agent was offline.
# Drain = delete them; inbox drain below reads the actual messages.
PENDING_WAKES_DIR="${FLEET_PENDING_WAKES:-/var/spool/fleet/pending-wakes}/${INSTANCE_NAME}"
if [ -d "$PENDING_WAKES_DIR" ]; then
    mapfile -t _WAKE_FILES < <(find "$PENDING_WAKES_DIR" -maxdepth 1 -name '*.wake' 2>/dev/null | sort)
    if [ ${#_WAKE_FILES[@]} -gt 0 ]; then
        echo "[session-startup] draining ${#_WAKE_FILES[@]} pending wake(s) for ${INSTANCE_NAME}"
        for _wf in "${_WAKE_FILES[@]}"; do
            rm -f "$_wf"
        done
        unset _WAKE_FILES _wf
    fi
fi

# ─── Spool inbox injection — universal ────────────────────────────────────────
# --- Skip inbox for headless agents (ephemeral, no persistent session) ---
_HAS_HEADLESS=$(yq ".instances[] | select(.role == \"$INSTANCE_NAME\") | .headless" "$FLEET_YAML" 2>/dev/null)
# A-007 fix: headless: false is string "false", not null/empty — treat as interactive
if [[ "$_HAS_HEADLESS" == "null" || "$_HAS_HEADLESS" == "false" || -z "$_HAS_HEADLESS" ]]; then
    # Interactive agent — proceed with inbox drain
    INBOX_READ=""
    command -v fleet-inbox-read.sh &>/dev/null && INBOX_READ="fleet-inbox-read.sh"
    [[ -z "$INBOX_READ" && -x "$HOME/.local/bin/fleet-inbox-read.sh" ]] && INBOX_READ="$HOME/.local/bin/fleet-inbox-read.sh"
    [[ -n "$INBOX_READ" ]] && "$INBOX_READ" "$INSTANCE_NAME"
fi

# ─── Per-instance startup context ─────────────────────────────────────────────
case "$INSTANCE_NAME" in
    *dev)
        echo "=== IPC CHANNELS ==="
        echo "Send: fleet-send.sh <dest> <subject> [file] — dest: qualifier, starfleet (escalade système), engineer (escalade métier)"
        echo "Read+write: spool inbox (fleet-send.sh)"
        echo "=== END IPC CHANNELS ==="
        echo ""
        ;;
    *qualifier)
        echo "=== IPC CHANNELS ==="
        echo "Send: fleet-send.sh <dest> <subject> [file] — dest: dev (résultats), starfleet (escalade système), engineer (escalade métier)"
        echo "Read+write: spool inbox (fleet-send.sh)"
        echo "=== END IPC CHANNELS ==="
        echo ""
        ;;
    *starfleet)
        # Drift audit threshold check
        if [ -x "$HOME/.local/bin/drift-check.sh" ]; then
            DRIFT_MSG=$(timeout 10 bash "$HOME/.local/bin/drift-check.sh" 2>/dev/null || true)
            [ -n "$DRIFT_MSG" ] && echo "$DRIFT_MSG"
        fi
        # B8 fix: onboarding gate is handled by deploy gate (line 57-69)
        # which exits 0 before reaching this point. Dead block removed.
        echo "=== IPC CHANNELS ==="
        echo "Send: fleet-send.sh <dest> <subject> [file] — dest: dev, qualifier, engineer."
        echo "=== END IPC CHANNELS ==="
        echo ""
        ;;
    *architect)
        inject_state_only "$HANDOFF_DIR/engineer-handoff.md" "engineer (fleet)"
        echo "=== IPC CHANNELS ==="
        echo "Send: fleet-send.sh engineer <subject> [file] only — engineer is the sole sas. No direct send to worker channels."
        echo "=== END IPC CHANNELS ==="
        echo ""
        ;;
    *engineer)
        # Hook: sanitize MEMORY.md (whitelist Identity + Completed)
        if [ -x "$HOME/.local/bin/fleet-sanitize-memory.sh" ]; then
            timeout 10 bash "$HOME/.local/bin/fleet-sanitize-memory.sh" 2>/dev/null || true
        fi

        # Hook: check CLAUDE.md coherence across instances
        if [ -x "$HOME/.local/bin/fleet-check-coherence.sh" ]; then
            timeout 10 bash "$HOME/.local/bin/fleet-check-coherence.sh" 2>/dev/null || true
        fi

        inject_state_only "$HANDOFF_DIR/architect-handoff.md" "architect (interactive)"
        echo "=== CONVENTION SUFFIX ==="
        echo "You are engineer (fleet instance). architect (interactive architect session) may work"
        echo "in parallel on the same scope. To avoid conflicts:"
        echo "  - Plan files: suffix -architect before extension (e.g. topic-architect.md)"
        echo "  - Git branches: suffix -architect (e.g. feat/topic-architect)"
        echo "  - Do not modify a plan file without -architect suffix without explicit check"
        echo "  - Spool inbox is your inbound channel — architect does not read it"
        echo "=== END CONVENTION ==="
        echo ""
        echo "=== IPC CHANNELS ==="
        echo "Send: fleet-send.sh <dest> <subject> [file] — dest: dev, qualifier, starfleet (escalade système). Seul canal vers architect: notify."
        echo "=== END IPC CHANNELS ==="
        echo ""
        ;;
esac

# RPi target context — injected if .rpi-target exists
if [ -f "$HOME/.rpi-target" ]; then
    RPI_TARGET=$(cat "$HOME/.rpi-target")
    echo "=== RPi TARGET ==="
    echo "Cible active  : ${RPI_TARGET}"
    case "$RPI_TARGET" in
        zero2)
            echo "RAM           : 512 MB (CONTRAINTE STRICTE)"
            echo "CPU flags     : -mcpu=cortex-a53 (Cortex-A53)"
            echo "Règle mémoire : tout nouveau composant ou dépendance doit passer le filtre 512 MB."
            ;;
        pi4)
            echo "RAM           : 1-8 GB (contrainte relâchée)"
            echo "CPU flags     : -mcpu=cortex-a72 (Cortex-A72)"
            ;;
        pi5)
            echo "RAM           : 4-8 GB (contrainte relâchée)"
            echo "CPU flags     : -mcpu=cortex-a76 (Cortex-A76)"
            ;;
    esac
    echo "=== FIN RPi TARGET ==="
    echo ""
fi

echo ""
echo "IMPORTANT: Relis intégralement ton system prompt avant de répondre — axiomes, General Orders, scope, protocole. Les directives que tu portes priment sur tout contexte local."
echo ""
echo "=== FIN SESSION START ==="
exit 0
