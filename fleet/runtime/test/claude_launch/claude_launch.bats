#!/usr/bin/env bats
# SOURCE: test/claude_launch/claude_launch.bats
# AUTHOR: engineer
# STARDATE: 2026-06-01
# STATUS: beyond_#5 chantier 3 — tests bats bin/claude_launch.sh v2 (ADR-G, RC interactif)
#
# Tests intégration bin/claude_launch.sh (frontière vendor N1) au contrat ADR-G ACTUEL :
# 3 args positionnels <role> <pod_id> <pod_dir> (le SP N'est PLUS un arg — durcissement anti-fuite
# /proc/cmdline 2026-06-14). Le launcher lit le SP depuis $POD_DIR/.lcars/system-prompt.md (écrit par
# le spawner en do_project) et le passe via --system-prompt-file (replace + TRUSTED). Session UUID
# pré-allouée + préfixe nom RC voyagent par l'ENV (LCARS_POD_SESSION_ID / _RESUME / _SESSION_NAME_PREFIX).
# Permission = --permission-mode default par défaut (#kill-yolo : listes ENFORCED, fini le --dangerously-skip).
# exec `claude --remote-control` interactif (PAS -p/stream-json/budget). Le launcher exec direct → le stub
# claude echo ses args, on asserte sur la ligne STUB_ARGS.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/claude_launch.sh"
  TMP_BASE="$(mktemp -d)"
  POD_DIR="$TMP_BASE/pod-engineer-test"
  mkdir -p "$POD_DIR/.claude" "$POD_DIR/.lcars"

  # Cap-profile JSON resolved (forme fleet_spawner chantier 6). Pas de spec.invocation → le launcher
  # tombe sur ses défauts (permission_mode "default", remote_control true, model/effort omis).
  cat > "$POD_DIR/.cap-profile.json" <<'EOF'
{
  "api_version": "lcars/v2.5",
  "kind": "CapabilityProfile",
  "metadata": {"name": "engineer"},
  "spec": {
    "scope": {
      "allowedTools": ["Read", "Glob", "Grep"],
      "disallowedTools": ["web_search", "tool_search_internal"]
    }
  }
}
EOF

  # Stub vendor claude : répond à --version (provisioning .claude.json) puis echo ses args.
  CLAUDE_STUB="$TMP_BASE/claude-stub"
  cat > "$CLAUDE_STUB" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "2.1.159 (Claude Code)"; exit 0; fi
printf 'STUB_ARGS:'
for a in "$@"; do printf ' %s' "$a"; done
printf '\n'
printf 'STUB_ENV: ENABLE_TOOL_SEARCH=%s\n' "${ENABLE_TOOL_SEARCH:-unset}"
exit 0
EOF
  chmod +x "$CLAUDE_STUB"

  export LCARS_CLAUDE_BIN="$CLAUDE_STUB"
  # Session : UUID pré-alloué + préfixe nom RC (posés par le spawner via bwrap --setenv en prod).
  export LCARS_POD_SESSION_ID="test-session-uuid"
  export LCARS_POD_SESSION_NAME_PREFIX="lordzurp_engineer"

  # SP HORS argv : le launcher le lit depuis $POD_DIR/.lcars/system-prompt.md via --system-prompt-file
  # (écrit par le spawner en do_project). On le provisionne donc COMME le spawner, pas en argv.
  SP_FILE="$POD_DIR/.lcars/system-prompt.md"
  printf '%s\n' "# Engineer SP de test" > "$SP_FILE"
}

teardown() {
  rm -rf "$TMP_BASE"
}

# =============================================================
# Args validation — contrat 3 args STRICT (SP n'est plus positionnel)
# =============================================================

@test "args: exit 1 quand aucun argument" {
  run "$SCRIPT"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"usage:"* ]]
}

@test "args: exit 1 quand 4 args (SP n'est PLUS positionnel — $# -ne 3 strict)" {
  # Régression jumelle du bridge python A7 : l'ancien contrat prenait le SP en argv 4. Le durcissement
  # anti-fuite l'a sorti de l'argv → 4 args = trop d'args = usage error.
  run "$SCRIPT" engineer pod-1 "$POD_DIR" "# SP en trop"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"usage:"* ]]
}

@test "args: exit 1 quand role est string vide" {
  run "$SCRIPT" "" pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"must be non-empty"* ]]
}

@test "args: exit 1 quand le fichier SP (.lcars/system-prompt.md) est absent ou vide" {
  # Le SP est lu d'un fichier ([[ ! -s ]] = absent OU vide). On tronque à vide pour exercer le -s.
  : > "$SP_FILE"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"SP file"* ]]
  [[ "$output" == *"missing or empty"* ]]
}

# =============================================================
# Session env (:? strict — posés par le spawner)
# =============================================================

@test "session: exit non-zéro + message quand LCARS_POD_SESSION_ID absent" {
  unset LCARS_POD_SESSION_ID
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"session UUID required"* ]]
}

@test "session: exit non-zéro + message quand LCARS_POD_SESSION_NAME_PREFIX absent" {
  unset LCARS_POD_SESSION_NAME_PREFIX
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"RC name prefix required"* ]]
}

# =============================================================
# Setup checks
# =============================================================

@test "setup: exit 1 quand claude binary missing" {
  export LCARS_CLAUDE_BIN="/nonexistent/claude"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"claude binary missing"* ]]
}

@test "setup: exit 1 quand jq binary missing" {
  export LCARS_JQ_BIN="/nonexistent/jq"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"jq binary missing"* ]]
}

@test "setup: exit 1 quand cap-profile JSON missing" {
  rm -f "$POD_DIR/.cap-profile.json"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"cap-profile"* ]]
  [[ "$output" == *"missing"* ]]
}

# =============================================================
# Happy path + assemblage flags ADR-G (le stub echo ses args)
# =============================================================

@test "happy path: exit 0" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
}

@test "flags: --remote-control présent (RC-at-startup)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--remote-control"* ]]
}

@test "env: ENABLE_TOOL_SEARCH non exporté (défaut vendor conservé — arbitrage 2026-07-18)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"STUB_ENV: ENABLE_TOOL_SEARCH=unset"* ]]
}

@test "F115/F157: .claude.json provisionné porte les 3 clés remote-control (écrivain unique N1)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  # Le launcher est l'unique écrivain du .claude.json : sans ces clés, le dialog RC re-bloque
  # au boot (pod.ex N0 ne les pose plus — sa version était clobberée par ce `cat >`).
  [[ -f "$POD_DIR/.claude.json" ]]
  run cat "$POD_DIR/.claude.json"
  [[ "$output" == *'"remoteControlAtStartup": true'* ]]
  [[ "$output" == *'"hasUsedRemoteControl": true'* ]]
  [[ "$output" == *'"remoteDialogSeen": true'* ]]
}

@test "flags: 1ʳᵉ création → --session-id <UUID> (pas --resume)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--session-id test-session-uuid"* ]]
  [[ "$output" != *"--resume"* ]]
}

@test "flags: recovery (LCARS_POD_RESUME=1) → --resume <UUID> (pas --session-id)" {
  export LCARS_POD_RESUME=1
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--resume test-session-uuid"* ]]
  [[ "$output" != *"--session-id"* ]]
}

@test "flags: nom RC = préfixe humain_role (positionnel de --remote-control, PAS de suffixe auto)" {
  # Le nom RC lisible Desktop est le positionnel de --remote-control (= SESSION_NAME_PREFIX = <projet>_<role>),
  # PAS --remote-control-session-name-prefix (qui collerait un suffixe auto random qui s'empile).
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--remote-control lordzurp_engineer"* ]]
}

@test "flags: SP via --system-prompt-file (HORS argv, anti-fuite /proc/cmdline) — pas inline" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  # Le launcher passe le CHEMIN du fichier SP, pas le contenu → le SP ne fuite pas dans l'argv exec'd.
  [[ "$output" == *"--system-prompt-file $POD_DIR/.lcars/system-prompt.md"* ]]
  [[ "$output" != *"Engineer SP de test"* ]]
}

@test "flags: --permission-mode default par défaut (#kill-yolo : listes ENFORCED, plus de skip)" {
  # Le monde est shapé (bwrap RO/RW + cap-profile allow/deny) → on N'utilise PLUS --dangerously-skip-
  # permissions (qui neutralisait les listes). Sans spec.invocation.permission_mode → défaut "default".
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--permission-mode default"* ]]
  [[ "$output" != *"--dangerously-skip-permissions"* ]]
}

@test "flags: LCARS_PERMISSION_MODE override → --permission-mode <mode> (rôle bridé)" {
  export LCARS_PERMISSION_MODE=plan
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--permission-mode plan"* ]]
  [[ "$output" != *"--dangerously-skip-permissions"* ]]
}

@test "flags: --allowedTools = cap-profile + protocole MCP fleet universel (get_work_item/submit_result)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--allowedTools Read,Glob,Grep"* ]]
  # #kill-yolo : le protocole MCP fleet (get_work_item/submit_result) est APPENDÉ à l'allowlist — sinon
  # un tool MCP non listé PROMPTE en --permission-mode default → hang headless. (vocab : get_work_item,
  # ex-get_task renommé par la campagne vocab.)
  [[ "$output" == *"mcp__fleet__get_work_item"* ]]
  [[ "$output" == *"mcp__fleet__submit_result"* ]]
}

@test "flags: --disallowedTools extrait du cap-profile JSON" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--disallowedTools web_search,tool_search_internal"* ]]
}

@test "flags: --setting-sources project,local INCONDITIONNEL (exclut 'user')" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--setting-sources project,local"* ]]
}

@test "flags: --settings pointe .lcars/settings.json (flagSettings additif)" {
  # Le settings pod est provisionné INCONDITIONNELLEMENT (cf. section settings) → --settings toujours émis.
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--settings $POD_DIR/.lcars/settings.json"* ]]
}

@test "flags: --mcp-config --strict-mcp-config si .mcp-fleet.json présent" {
  echo '{"mcpServers":{}}' > "$POD_DIR/.mcp-fleet.json"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" == *"--mcp-config $POD_DIR/.mcp-fleet.json"* ]]
  [[ "$output" == *"--strict-mcp-config"* ]]
}

# =============================================================
# Settings pod (.lcars/settings.json) : provisioning INCONDITIONNEL + pass-through --settings (flagSettings).
# #kill-yolo (2026-06-22) : PERM_MODE default → plus de --dangerously-skip-permissions ni de
# skipDangerousModePermissionPrompt dans le chemin par défaut. Le fichier porte autoMemoryEnabled:false
# (F-POD-AUTOMEM : auto-memory pod coupée). Le skip-dialog est réservé à PERM_MODE=bypassPermissions
# (la valeur réelle de l'enum — PERM_MODE n'est JAMAIS vide, défaut "default" ; l'ancienne garde -z
# était morte, audit lot 6 2026-07-12). --settings = source flagSettings, indépendante de
# --setting-sources.
# =============================================================

@test "settings: provisionne .lcars/settings.json (autoMemory coupée) + le passe via --settings" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ -f "$POD_DIR/.lcars/settings.json" ]]
  grep -q "autoMemoryEnabled" "$POD_DIR/.lcars/settings.json"
  [[ "$output" == *"--settings $POD_DIR/.lcars/settings.json"* ]]
}

@test "settings: merge non-destructif (settings pod préexistant conservé + clé fleet ajoutée)" {
  echo '{"hooks":{"PreToolUse":[]}}' > "$POD_DIR/.lcars/settings.json"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  grep -q "autoMemoryEnabled" "$POD_DIR/.lcars/settings.json"   # la clé fleet est ajoutée
  grep -q "PreToolUse" "$POD_DIR/.lcars/settings.json"          # l'existant n'est PAS clobberé
}

@test "settings: rôle bridé (LCARS_PERMISSION_MODE) NE provisionne PAS le skip-dialog" {
  export LCARS_PERMISSION_MODE=plan
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  # Le fichier existe (autoMemoryEnabled INCONDITIONNEL) mais SANS skipDangerousModePermissionPrompt :
  # le skip-dialog est réservé à PERM_MODE=bypassPermissions, jamais pour un mode bridé/défaut.
  ! grep -q "skipDangerousModePermissionPrompt" "$POD_DIR/.lcars/settings.json"
}

@test "settings: PERM_MODE=bypassPermissions (override env) provisionne le skip-dialog (pré-acceptation, pas de hang)" {
  # Régression audit lot 6 : la garde historique `-z "$PERM_MODE"` était MORTE (PERM_MODE jamais vide,
  # défaut "default") → un pod bypassPermissions hangait au boot sur le dialogue « Yes I accept ».
  # La garde est keyée sur la valeur réelle de l'enum (launch_spec.ex @permission_modes).
  export LCARS_PERMISSION_MODE=bypassPermissions
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--permission-mode bypassPermissions"* ]]
  grep -q '"skipDangerousModePermissionPrompt":true' "$POD_DIR/.lcars/settings.json"
}

@test "settings: cap-profile permission_mode=bypassPermissions provisionne le skip-dialog (canal in-sandbox)" {
  # Même invariant que ci-dessus mais par le canal PROD : `.spec.invocation.permission_mode` du
  # cap-profile JSON (l'env est strippé par bwrap --clearenv — la JSON est LE canal du mode).
  cat > "$POD_DIR/.cap-profile.json" <<'EOF'
{
  "api_version": "lcars/v2.5",
  "kind": "CapabilityProfile",
  "metadata": {"name": "engineer"},
  "spec": {
    "invocation": {"permission_mode": "bypassPermissions"},
    "scope": {"allowedTools": ["Read"], "disallowedTools": []}
  }
}
EOF
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--permission-mode bypassPermissions"* ]]
  grep -q '"skipDangerousModePermissionPrompt":true' "$POD_DIR/.lcars/settings.json"
}

@test "version: claude --version au format inattendu → fallback 2.1.150, PAS de mort pipefail" {
  # Régression audit lot 6 : `VER=$(... | grep ...)` sous set -euo pipefail mourait (exit 1 opaque,
  # TOUS les pods) quand le format --version changeait — le fallback ${VER:-2.1.150} était
  # inatteignable pour ce chemin. Le pipeline doit être non-fatal et le fallback effectif.
  cat > "$CLAUDE_STUB" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "Claude Code (dev build, no semver here)"; exit 0; fi
printf 'STUB_ARGS:'
for a in "$@"; do printf ' %s' "$a"; done
printf '\n'
exit 0
EOF
  chmod +x "$CLAUDE_STUB"
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$status" -eq 0 ]]
  grep -q '"lastOnboardingVersion": "2.1.150"' "$POD_DIR/.claude.json"
}

# =============================================================
# Interdits ADR-G (IV.1/IV.2 : pas de -p/stream-json/budget)
# =============================================================

@test "ADR-G: aucun -p/--print/--output-format/stream-json/--max-budget-usd" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"
  [[ "$output" != *"--print"* ]]
  [[ "$output" != *"--output-format"* ]]
  [[ "$output" != *"stream-json"* ]]
  [[ "$output" != *"--max-budget-usd"* ]]
}

# =============================================================
# Frontière vendor N1 — préfixe claude_*, jamais bwrap/tmux
# =============================================================

@test "frontière vendor: aucun containment fonctionnel (flags bwrap / bwrap|tmux exécutés)" {
  # Les MENTIONS en doc/string (« LCARS_CLAUDE_BIN posé par bwrap », « le PTY est tmux ») sont
  # légitimes (frontière N0/N1 documentée). On interdit le FONCTIONNEL : flags bwrap
  # (--ro-bind/--unshare/--clearenv/--tmpfs) ou bwrap/tmux exécutés (début de ligne ou après exec).
  ! grep -vE "^\s*#" "$SCRIPT" | grep -E "(^|exec +)(bwrap|tmux)\b|--ro-bind|--unshare|--clearenv|--tmpfs"
}

@test "frontière vendor: pas de --bare ni anthropic_api_key fonctionnels (hors commentaires)" {
  ! grep -vE "^\s*#" "$SCRIPT" | grep -iE "openai|anthropic_api_key|--bare"
}

@test "frontière vendor: script connaît juste claude (vendor N1)" {
  grep -q "claude" "$SCRIPT"
}

# =============================================================
# Header LCARS standard
# =============================================================

@test "header LCARS: SOURCE/AUTHOR/STARDATE/STATUS présents" {
  grep -q "^# SOURCE:" "$SCRIPT"
  grep -q "^# AUTHOR:" "$SCRIPT"
  grep -q "^# STARDATE:" "$SCRIPT"
  grep -q "^# STATUS:" "$SCRIPT"
}
