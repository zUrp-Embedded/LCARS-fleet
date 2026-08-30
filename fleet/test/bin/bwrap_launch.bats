#!/usr/bin/env bats
# SOURCE: fleet/test/bin/bwrap_launch.bats
# AUTHOR: engineer
# STARDATE: 2026-06-01
# STATUS: bats tests for bin/bwrap_launch.sh v2 (ADR-G sanctuary)
#
# The v2 model is ASYNC and detached (bwrap → tmux new-session -d → command; bwrap returns 0, the exit
# code is not propagated). So we stub bwrap (echoing its invocation) and assert the ASSEMBLY of the v2
# flags. The real sanctuary isolation (/ RO, /home tmpfs, closed env) is NOT tested here: its e2e proof
# is test/probes/gate-r0.1-bwrap.sh (an INSIDE probe against a real bwrap+tmux+vendor — manual/opt-in, it needs
# the bwrap syscalls). What IS covered here: args, the `:?` session guards, setup checks, assembly
# (clearenv/die-with-parent/binds/setenv/sock-dir/tmux), the pre-exec trap, and the N0/N1 frontier.

load ../support/refute

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/bwrap_launch.sh"
  TMP_BASE="$(mktemp -d)"

  POD_DIR="$TMP_BASE/pod-engineer-test"; mkdir -p "$POD_DIR/.claude"
  export CLAUDE_DIR="$TMP_BASE/claudedir"; mkdir -p "$CLAUDE_DIR"
  # Human creds: the launcher binds `.credentials.json` (auth :bind, native in-place OAuth refresh), so
  # the file MUST exist host-side or the launcher fails at the boundary. Empty fixture — the bwrap stub
  # does not read it, we only test the assembly.
  : > "$CLAUDE_DIR/.credentials.json"
  export LCARS_GIT_MIRROR="$TMP_BASE/git-mirror"; mkdir -p "$LCARS_GIT_MIRROR"
  export LCARS_TMUX_SOCK_BASE="$TMP_BASE/sock"; mkdir -p "$LCARS_TMUX_SOCK_BASE"

  # Per-pod MCP socket: central provisions it BEFORE the launch (the dir MUST pre-exist — bwrap MOUNTS
  # it, it does not create it). We simulate that provisioning here for the `pod-1` id the tests use.
  export LCARS_FLEET_MCP_SOCK_BASE="$TMP_BASE/mcp-sock"; mkdir -p "$LCARS_FLEET_MCP_SOCK_BASE/pod-1"

  # Vendor stub (just -x + a share dir). Explicit authority, no PATH resolution.
  export LCARS_VENDOR_NAME="claude"
  export LCARS_VENDOR_BIN="$TMP_BASE/vendor/bin/claude"
  export LCARS_VENDOR_SHARE="$TMP_BASE/vendor/share"
  mkdir -p "$(dirname "$LCARS_VENDOR_BIN")" "$LCARS_VENDOR_SHARE"
  echo '#!/usr/bin/env bash' > "$LCARS_VENDOR_BIN"; chmod +x "$LCARS_VENDOR_BIN"

  # Session: set by the spawner in prod.
  export LCARS_POD_SESSION_ID="test-session-uuid"
  export LCARS_POD_SESSION_NAME_PREFIX="lordzurp_engineer"

  # The mandate's git identity is the HUMAN (set by the spawner through ForgeIdentity; read with a
  # strict `:?` by the launcher, so `--setenv GIT_*` no-boots without it). Deterministic fixture, so the
  # tests reach the assembly.
  export GIT_AUTHOR_NAME="Test Human"
  export GIT_AUTHOR_EMAIL="test-human@lcars.invalid"
  export GIT_COMMITTER_NAME="Test Human"
  export GIT_COMMITTER_EMAIL="test-human@lcars.invalid"

  # bwrap stub: echoes the full invocation (including the tmux command) → assembly assertions.
  export LCARS_BWRAP_BIN="$TMP_BASE/bwrap-stub"
  cat > "$LCARS_BWRAP_BIN" <<'EOF'
#!/usr/bin/env bash
printf 'BWRAP_ARGS:'
for a in "$@"; do printf ' %s' "$a"; done
printf '\n'
exit 0
EOF
  chmod +x "$LCARS_BWRAP_BIN"
}

teardown() { rm -rf "$TMP_BASE"; }

# ============================ Args ============================

@test "args: exit 1 with no argument" {
  run "$SCRIPT"; [[ "$status" -eq 1 ]]; [[ "$output" == *"usage:"* ]]
}
@test "args: exit 1 with 3 args (command missing)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR"; [[ "$status" -eq 1 ]]; [[ "$output" == *"usage:"* ]]
}
@test "args: exit 1 when role is an empty string" {
  run "$SCRIPT" "" pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"non-empty"* ]]
}

# ===================== Session (strict :?) ====================

@test "session: non-zero exit + message when LCARS_POD_SESSION_ID is absent" {
  unset LCARS_POD_SESSION_ID
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -ne 0 ]]; [[ "$output" == *"session UUID required"* ]]
}
@test "session: non-zero exit + message when LCARS_POD_SESSION_NAME_PREFIX is absent" {
  unset LCARS_POD_SESSION_NAME_PREFIX
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -ne 0 ]]; [[ "$output" == *"pod label required"* ]]
}

# ======================= Setup checks ========================

# 6-069 — LE TRAP EMPORTAIT $POD_DIR SUR N'IMPORTE QUEL ECHEC DE SETUP, et toutes ces
# verifications-la sont posees APRES lui. A cet instant le repertoire a deja ete entierement projete
# par la fleet : clone AVEC son historique git, CLAUDE.md, prompt systeme, brief, settings.json,
# watch.sh, hook de trailer. Un socat manquant faisait recloner le depot au prochain essai.
#
# Le script declare lui-meme `pod_dir … (caller responsibility)` quatre lignes plus bas, et le
# proprietaire a son propre teardown garde, exerce sur un pod TERMINAL. « On n'a pas pu demarrer »
# n'est pas « ce pod est fini ».
#
# On boucle sur les CINQ echecs de setup plutot que sur un seul : le trap est unique, mais les
# chemins qui l'atteignent ne le sont pas, et c'est justement leur nombre qui fait le defaut.
@test "6-069: un echec de setup ne detruit PAS le pod_dir deja projete" {
  local temoin="$POD_DIR/clone/.git/HEAD"
  mkdir -p "$(dirname "$temoin")"
  echo "ref: refs/heads/main" > "$temoin"

  run_setup_failure() {
    run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
    [[ "$status" -ne 0 ]] || return 1
    [[ -f "$temoin" ]] || return 2
    [[ "$(cat "$temoin")" == "ref: refs/heads/main" ]] || return 3
  }

  # 1. bwrap absent
  ( export LCARS_BWRAP_BIN="/nonexistent/bwrap"; run_setup_failure )
  [[ -f "$temoin" ]]

  # 2. tmux absent
  ( export LCARS_TMUX_BIN="/nonexistent/tmux"; run_setup_failure )
  [[ -f "$temoin" ]]

  # 3. binaire vendor absent
  ( export LCARS_VENDOR_BIN="/nonexistent/claude"; run_setup_failure )
  [[ -f "$temoin" ]]

  # 4. claudeDir absent
  ( export CLAUDE_DIR="/nonexistent/claudedir"; run_setup_failure )
  [[ -f "$temoin" ]]

  # 5. miroir git demande mais absent
  ( export LCARS_GIT_MIRROR="/nonexistent/mirror"; run_setup_failure )
  [[ -f "$temoin" ]]

  # Le contenu est intact, pas seulement le chemin.
  [[ "$(cat "$temoin")" == "ref: refs/heads/main" ]]
}

# TEMOIN — sans lui, la preuve ci-dessus passerait aussi si le script n'echouait plus du tout, ou
# s'il n'atteignait plus jamais le trap. Le repertoire de socket, LUI, est bien a ce script : il le
# cree, donc il le nettoie.
@test "6-069: TEMOIN — le repertoire de socket, lui, EST nettoye (c'est ce script qui le cree)" {
  local sock_dir="$LCARS_TMUX_SOCK_BASE/pod-1"
  mkdir -p "$sock_dir"

  # Un echec APRES la creation du sock dir : le parent existe, mais socat/le vendor manquent.
  export LCARS_VENDOR_BIN="/nonexistent/claude"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -ne 0 ]]

  [[ ! -d "$sock_dir" ]]
}

@test "setup: exit 2 when bwrap is missing" {
  export LCARS_BWRAP_BIN="/nonexistent/bwrap"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 2 ]]; [[ "$output" == *"bwrap missing"* ]]
}
@test "setup: exit 2 when tmux is missing" {
  export LCARS_TMUX_BIN="/nonexistent/tmux"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 2 ]]; [[ "$output" == *"tmux missing"* ]]
}
@test "setup: exit 2 when the vendor is missing" {
  export LCARS_VENDOR_BIN="/nonexistent/claude"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 2 ]]; [[ "$output" == *"vendor"* ]]
}
@test "setup: exit 1 when claudeDir is missing" {
  export CLAUDE_DIR="/nonexistent/claudedir"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"claudeDir"* ]]
}
@test "DR-023: git mirror DORMANT (LCARS_GIT_MIRROR unset) → INERT: no exit 1, no mirror bind" {
  # DR-023: a disabled feature is not a precondition any more. The old default pointed at the
  # /var/lib/lcars/git-mirror fossil, which killed the first spawn on a fresh home install.
  unset LCARS_GIT_MIRROR
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]                    # dormant is not fatal
  [[ "$output" == *"BWRAP_ARGS:"* ]]       # the launch reaches the bwrap exec
  [[ "$output" != *"ERR: git mirror"* ]]   # no mirror error
  [[ "$output" != *"git-mirror"* ]]        # NO mirror bind projected into the sandbox
}
@test "DR-023: git mirror SET but missing (LCARS_GIT_MIRROR=<nonexistent dir>) → fatal (an explicit ask cannot be met)" {
  export LCARS_GIT_MIRROR="/nonexistent/mirror"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"git mirror"* ]]
}
@test "mandat: issues/ est monte RO par-dessus le pod_dir (le mandat est immuable, le SP dit vrai)" {
  # Le mandat (issues/mandate.md) est adresse par contenu : le pod le lit, ne l'ecrit jamais. Le SP
  # promet "lecture seule" → l'implementation doit le tenir. SANDBOX_HOME=$POD_DIR ici (pas de
  # LCARS_POD_HOME) → la cible est $POD_DIR/issues.
  mkdir -p "$POD_DIR/issues"
  printf 'ORDRE\n' > "$POD_DIR/issues/mandate.md"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--ro-bind $POD_DIR/issues $POD_DIR/issues"* ]]
}

@test "mandat: sans issues/, aucun ro-bind issues (garde -d inerte, pas d'echec)" {
  # setup ne cree pas issues/ → le montage est inerte, pas fatal (meme posture que le miroir git).
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"BWRAP_ARGS:"* ]]
  [[ "$output" != *"--ro-bind $POD_DIR/issues"* ]]
}

@test "outillage: LCARS_POD_TOOLCHAIN_ENV absent -> INERT, aucun --setenv de plus (DR-023)" {
  # Le pendant exact du miroir git ci-dessus : une boite sans magasin doit produire la ligne de
  # commande d'hier, pas une ligne degradee. Un outillage manquant ralentit un pod, il ne le tue pas.
  unset LCARS_POD_TOOLCHAIN_ENV
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"BWRAP_ARGS:"* ]]
  [[ "$output" != *"CARGO_HOME"* ]]
}

@test "outillage: chaque paire devient un --setenv" {
  export LCARS_POD_TOOLCHAIN_ENV=$'CARGO_HOME=/store/toolchains/rust\nIDF_PATH=/store/toolchains/esp'
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--setenv CARGO_HOME /store/toolchains/rust"* ]]
  [[ "$output" == *"--setenv IDF_PATH /store/toolchains/esp"* ]]
}

@test "outillage: LCARS_PATH_PREPEND PREFIXE le PATH, il ne le REMPLACE pas" {
  # LE CAS QUI COMPTE. Un `--setenv PATH` venu du tableau ecraserait `$SANDBOX_HOME/.local/bin` et
  # couperait le pod de ses propres outils — une toolchain gagnee contre un pod casse. Le PATH final
  # est compose par CE script, jamais fourni par le fichier.
  export LCARS_POD_TOOLCHAIN_ENV='LCARS_PATH_PREPEND=/store/toolchains/rust/bin'
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--setenv PATH /store/toolchains/rust/bin:"*"/.local/bin:/usr/local/bin:/usr/bin:/bin"* ]]
  # et il n'apparait PAS comme une variable a lui seul
  [[ "$output" != *"--setenv LCARS_PATH_PREPEND"* ]]
}

@test "outillage: une clef d'outillage ne peut pas ecraser une variable du contrat" {
  # bwrap garde la DERNIERE occurrence (mesure : `--setenv V a --setenv V b` rend b). La garde est
  # donc que le tableau d'outillage passe EN PREMIER et que le contrat, deplie apres, ait le dernier
  # mot. ⚠ Une v1 de ce temoin epinglait l'ordre INVERSE en croyant epingler la garde — son propre
  # commentaire disait « derniere occurrence » ET « le contrat passe en premier », c'est-a-dire la
  # victoire du pirate. Temoin vert, propriete violee : le hollow-green exact que ce fichier chasse.
  export LCARS_POD_TOOLCHAIN_ENV='HOME=/tmp/pirate'
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  # Sans LCARS_POD_HOME, SANDBOX_HOME == POD_DIR : c'est LUI la valeur du contrat ici.
  pirate_pos=$(awk '{print index($0, "--setenv HOME /tmp/pirate")}' <<< "$output" | head -1)
  contract_pos=$(awk '{print index($0, "--setenv HOME '"$POD_DIR"'")}' <<< "$output" | head -1)
  [[ "$pirate_pos" -gt 0 ]]
  [[ "$contract_pos" -gt 0 ]]
  [[ "$pirate_pos" -lt "$contract_pos" ]]
}

@test "mounts: mode+src binds in place (the ordinary form, unchanged)" {
  mkdir -p "$TMP_BASE/plain"
  export LCARS_POD_MOUNTS="ro:$TMP_BASE/plain"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--ro-bind $TMP_BASE/plain $TMP_BASE/plain"* ]]
}

@test "mounts: mode+src+dst binds the SOURCE at the DESTINATION (pinned reference face)" {
  # The pinned reference lives in the pod dir so it survives its source, but it is bound at the
  # canonical face path so a pointer written in a brief resolves unchanged. Source and destination
  # differ HERE and nowhere else.
  mkdir -p "$TMP_BASE/pinned"
  export LCARS_POD_MOUNTS="ro:$TMP_BASE/pinned:/home/projects.workshop/demo"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--ro-bind $TMP_BASE/pinned /home/projects.workshop/demo"* ]]
}

@test "mounts: a RELATIVE destination is refused (the belt covers the target too)" {
  mkdir -p "$TMP_BASE/pinned"
  export LCARS_POD_MOUNTS="ro:$TMP_BASE/pinned:home/projects.workshop/demo"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"mount target is not absolute"* ]]
}

@test "mounts: a RW translation onto a system root is refused on the DESTINATION" {
  # A translated mount could otherwise land a writable tree on /etc while its source looks innocent.
  mkdir -p "$TMP_BASE/innocent"
  export LCARS_POD_MOUNTS="rw:$TMP_BASE/innocent:/etc"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"RW forbidden on a system root"* ]]
}

@test "setup: exit 1 when pod_dir is missing" {
  run "$SCRIPT" engineer pod-1 "$TMP_BASE/nope" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"pod_dir"* ]]
}
@test "setup: exit 1 when the sock parent is missing" {
  export LCARS_TMUX_SOCK_BASE="/nonexistent/sock-base"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"sock parent"* ]]
}
@test "setup: exit 1 when the per-pod MCP socket dir is missing (central's provisioning contract)" {
  rm -rf "$LCARS_FLEET_MCP_SOCK_BASE/pod-1"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$status" -eq 1 ]]; [[ "$output" == *"dir socket MCP"* ]]
}

# ============== bwrap assembly (stub echo) — v2 ==============

@test "asm: --clearenv (closed env)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--clearenv"* ]]
}
@test "asm: --die-with-parent (orphan-safe)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--die-with-parent"* ]]
}
@test "asm: the sandbox is SEALED — --unshare-all, and --share-net exists nowhere any more" {
  # The pod has no route to anywhere. Its egress leaves through a unix socket and a CONNECT proxy
  # that decides host by host; sharing the host stack would put the open web on the same pipe as
  # the vendor API, and denying `WebFetch` while `Bash` has `curl` only moves the gesture from a
  # traced tool to an untraced one.
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"--unshare-all"* ]]
  [[ "$output" != *"--share-net"* ]]
}

@test "egress: no socket provisioned -> no bind, no socat, and the pod is simply sealed" {
  unset LCARS_POD_EGRESS_SOCK
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"/run/lcars/egress"* ]]
}

@test "egress: a socket WITHOUT its provisioned dir is FATAL, never a silent open pod" {
  export LCARS_FLEET_EGRESS_SOCK_BASE="$TMP_BASE/nonexistent-egress"
  export LCARS_POD_EGRESS_SOCK="$TMP_BASE/nonexistent-egress/pod-1/sock"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"dir socket egress"* ]]
}

@test "egress: socat MISSING is exit 2 — a missing package must not degrade into an open pod" {
  export LCARS_FLEET_EGRESS_SOCK_BASE="$TMP_BASE/egress"
  mkdir -p "$TMP_BASE/egress/pod-1"
  export LCARS_POD_EGRESS_SOCK="$TMP_BASE/egress/pod-1/sock"
  export LCARS_SOCAT_BIN="/nonexistent/socat"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"socat missing"* ]]
}

@test "egress: provisioned -> the dir is bound, socat is bound RO, and the proxy env is set" {
  export LCARS_FLEET_EGRESS_SOCK_BASE="$TMP_BASE/egress"
  mkdir -p "$TMP_BASE/egress/pod-1"
  export LCARS_POD_EGRESS_SOCK="$TMP_BASE/egress/pod-1/sock"
  export LCARS_SOCAT_BIN="$TMP_BASE/fake-socat"; : > "$LCARS_SOCAT_BIN"; chmod +x "$LCARS_SOCAT_BIN"

  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--bind $TMP_BASE/egress/pod-1 $TMP_BASE/egress/pod-1"* ]]
  [[ "$output" == *"--ro-bind $LCARS_SOCAT_BIN $LCARS_SOCAT_BIN"* ]]
  # The vendor CLI honours these natively (undici).
  [[ "$output" == *"--setenv HTTPS_PROXY http://127.0.0.1:8118"* ]]
  # NO_PROXY is set EMPTY on purpose: an inherited one is a documented bypass of the only wall.
  [[ "$output" == *"--setenv NO_PROXY "* ]]
}

@test "egress: the BASE dir is never bound — a sibling's socket is a sibling's allowlist" {
  export LCARS_FLEET_EGRESS_SOCK_BASE="$TMP_BASE/egress"
  mkdir -p "$TMP_BASE/egress/pod-1"
  export LCARS_POD_EGRESS_SOCK="$TMP_BASE/egress/pod-1/sock"
  export LCARS_SOCAT_BIN="$TMP_BASE/fake-socat"; : > "$LCARS_SOCAT_BIN"; chmod +x "$LCARS_SOCAT_BIN"

  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" != *"--bind $TMP_BASE/egress $TMP_BASE/egress "* ]]
}
@test "asm: bind pod_dir + creds (single-file .credentials.json) + git-mirror RO" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"--bind $POD_DIR $POD_DIR"* ]]
  # Auth :bind means ONLY `.credentials.json` is bound, NOT the human's whole `.claude` — otherwise
  # their hooks leak in as project settings and jam the boot. The native OAuth refresh writes in place
  # on this file. SANDBOX_HOME=$POD_DIR here (no LCARS_POD_HOME) → the target is under $POD_DIR/.claude/.
  [[ "$output" == *"--bind $CLAUDE_DIR/.credentials.json $POD_DIR/.claude/.credentials.json"* ]]
  [[ "$output" == *"--ro-bind $LCARS_GIT_MIRROR $LCARS_GIT_MIRROR"* ]]
}
@test "asm: vendor relocated → pod/.local/bin (per-user binary)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"--ro-bind $LCARS_VENDOR_BIN $POD_DIR/.local/bin/claude"* ]]
}
@test "asm: bind the per-pod socket dir" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"--bind $LCARS_TMUX_SOCK_BASE/pod-1 $LCARS_TMUX_SOCK_BASE/pod-1"* ]]
}
@test "asm: per-pod MCP socket — bind the DIR + setenv the socket, NEVER the base wholesale (tenant frontier)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  # The per-pod DIR is bound at the same host==namespace path (central already created `sock` in it).
  [[ "$output" == *"--bind $LCARS_FLEET_MCP_SOCK_BASE/pod-1 $LCARS_FLEET_MCP_SOCK_BASE/pod-1"* ]]
  # The socket path, set for the bridge (read by bridge.py).
  [[ "$output" == *"--setenv LCARS_FLEET_MCP_SOCKET $LCARS_FLEET_MCP_SOCK_BASE/pod-1/sock"* ]]
  # NEVER the base wholesale: that would expose sibling pods' sockets (multi-human tenant leak).
  [[ "$output" != *"--bind $LCARS_FLEET_MCP_SOCK_BASE $LCARS_FLEET_MCP_SOCK_BASE"* ]]
}
@test "asm: --setenv CLAUDE_CODE_DISABLE_AUTO_MEMORY 1 (pod stateless)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--setenv CLAUDE_CODE_DISABLE_AUTO_MEMORY 1"* ]]
}
@test "asm: --setenv HOME = pod_dir" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--setenv HOME $POD_DIR"* ]]
}
@test "asm: --setenv session (SESSION_ID / RESUME / NAME_PREFIX)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"--setenv LCARS_POD_SESSION_ID test-session-uuid"* ]]
  [[ "$output" == *"--setenv LCARS_POD_RESUME 0"* ]]
  [[ "$output" == *"--setenv LCARS_POD_SESSION_NAME_PREFIX lordzurp_engineer"* ]]
}
@test "asm: --setenv LCARS_CLAUDE_BIN = relocated vendor" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--setenv LCARS_CLAUDE_BIN $POD_DIR/.local/bin/claude"* ]]
}
@test "asm: --chdir = pod_dir by default" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--chdir $POD_DIR"* ]]
}
@test "asm: --chdir = LCARS_POD_CWD when supplied (cwd = branch root)" {
  export LCARS_POD_CWD="$POD_DIR/repo"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true; [[ "$output" == *"--chdir $POD_DIR/repo"* ]]
}
@test "asm: HOLDER = sh -c (tmux new-session -d + wait on the session) — alive WITH the agent, and only with it" {
  # The holder keeps bwrap-PID1 alive → the namespace and the tmux server survive. Without it, bwrap
  # exits the moment new-session -d returns and kills the namespace. The -d daemonizes; the WAIT holds.
  #
  # And the wait is `has-session`, never `sleep infinity`: a holder that outlives its agent leaves a
  # pod whose Port is open and whose tmux is gone — the fleet calls that alive and re-briefs it
  # forever. The pod must die when the session does, so the Port closes and `exited_before_result`
  # gets its chance to run.
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"/bin/sh -c"* ]]
  [[ "$output" == *"new-session -d -s"* ]]
  [[ "$output" == *"has-session"* ]]
  [[ "$output" != *"sleep infinity"* ]]
}
@test "asm: session name + command passed as the holder's ARGS (argv preserved, lcars-pod-<id> + command)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$output" == *"lcars-pod-pod-1"* ]]
  [[ "$output" == *"/bin/true"* ]]
}

# ======================= Trap (pre-exec) =====================

# 6-069 — CE TEST DISAIT L'INVERSE, et son titre annoncait le defaut comme une fonctionnalite :
# « a setup error cleans up pod_dir (default) ». Il epinglait donc la destruction du travail deja
# projete par la fleet. Remplace, pas contourne : la propriete tenue ici est celle du repertoire de
# SOCKET, que ce script cree et possede vraiment.
@test "trap: a setup error cleans up the pod SOCKET dir (what this script owns)" {
  local sock_dir="$LCARS_TMUX_SOCK_BASE/pod-1"
  mkdir -p "$sock_dir"
  export LCARS_GIT_MIRROR="/nonexistent/mirror"   # triggers a PRE-exec exit 1
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -ne 0 ]]; [[ ! -d "$sock_dir" ]]
  # Et le pod_dir, lui, SURVIT — cf. le test 6-069 plus haut.
  [[ -d "$POD_DIR" ]]
}
@test "trap: everything preserved with LCARS_BWRAP_NO_CLEANUP=1" {
  local sock_dir="$LCARS_TMUX_SOCK_BASE/pod-1"
  mkdir -p "$sock_dir"
  export LCARS_BWRAP_NO_CLEANUP=1
  export LCARS_GIT_MIRROR="/nonexistent/mirror"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -ne 0 ]]; [[ -d "$POD_DIR" ]]; [[ -d "$sock_dir" ]]
}

# ==================== N0/N1 frontier ========================

@test "frontier: no claude/vendor flag (N0 does not know claude)" {
  # `mkdir -p` is excluded: that is a shell builtin (defensive creation of .claude/), NOT claude's print
  # flag. bwrap_launch passes claude flags ONLY through the opaque ${COMMAND[@]}, never as a literal in
  # the source → any remaining literal `-p ` would be suspect, except this mkdir.
  grep -vE "^\s*#" "$SCRIPT" | grep -vE "mkdir -p" | refute_out "\-\-remote-control|\-\-system-prompt|\-\-mcp-config|\-\-allowedTools|\-\-permission-mode|\-p |\-\-print"
}
@test "frontier: invocable with any command (vendor-agnostic)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /usr/bin/env FOO=bar
  [[ "$status" -eq 0 ]]; [[ "$output" == *"/usr/bin/env FOO=bar"* ]]
}

# ==================== Fleet skills rail (BL-6-22) =================

@test "skills: a name:path line binds RO into ~/.claude/skills/<name> — path spaces preserved, no host-side mkdir" {
  # Newline format, first `:` separates. The path CARRIES a space — the case a word-split loop
  # would shatter. NC3 invariant: bwrap CREATES the bind target inside the namespace (same as the
  # plugin loop) — the launcher must NOT pre-create it host-side.
  mkdir -p "$POD_DIR/sk root/card-revision"
  export LCARS_SKILLS_PATHS="card-revision:$POD_DIR/sk root/card-revision"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--ro-bind $POD_DIR/sk root/card-revision"* ]]
  [[ "$output" == *".claude/skills/card-revision"* ]]
}

@test "skills: a path-traversal skill name is rejected before any bind" {
  export LCARS_SKILLS_PATHS="../evil:/tmp"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]; [[ "$output" == *"path-traversal"* ]]
}

@test "skills: a missing skill dir fails LOUD (projection/launch skew, never a silent skip)" {
  export LCARS_SKILLS_PATHS="ghost:$POD_DIR/absent-skill"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]; [[ "$output" == *"no dir"* ]]
}

@test "skills: absent var → zero skill bind (skill-less pods unchanged)" {
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" != *".claude/skills/"* ]]
}

# ==================== Plugin security (S5) =================

@test "security: a path-traversal plugin name (../) is rejected before any bind (S5 allowlist)" {
  export LCARS_SKILLS_PLUGINS="../evil"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]; [[ "$output" == *"path-traversal"* ]]
}
@test "security: a plugin name with a slash is rejected (S5 allowlist)" {
  export LCARS_SKILLS_PLUGINS="a/b"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 1 ]]; [[ "$output" == *"path-traversal"* ]]
}

@test "security: bwrap is started with an EMPTY environment (S2: /proc/1/environ leak)" {
  # bwrap is PID 1 of the pod's namespace and keeps its OWN env: --clearenv scrubs the CHILD,
  # not bwrap. Measured in a live pod, /proc/1/environ handed the agent RELEASE_COOKIE (the
  # Erlang distribution secret) + the central's topology. `env -i` closes it at the source.
  run grep -E '^exec env -i "\$BWRAP_BIN"' "$SCRIPT"
  [[ "$status" -eq 0 ]]
}

@test "security: a secret in the spawner's ambient env never reaches the bwrap process" {
  # End-to-end on the assembly: the stub records ITS OWN environment; with `env -i` the secret
  # exported here must not appear in it (the pod's /proc/1/environ is that very environment).
  # The dump path is BAKED IN (unquoted heredoc → expanded now): under `env -i` the stub itself
  # inherits nothing, so it could not read a variable to find where to write.
  cat > "$LCARS_BWRAP_BIN" <<STUB
#!/usr/bin/env bash
env > "$TMP_BASE/bwrap.env"
exit 0
STUB
  chmod +x "$LCARS_BWRAP_BIN"
  RELEASE_COOKIE="cookie-must-not-leak" run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  run grep -c 'cookie-must-not-leak' "$TMP_BASE/bwrap.env"
  [[ "$output" == "0" ]]
}

# ============== the pod's umask — what makes the shared cache shared ==============
#
# The store's `cache/` is bound `rw` on a setgid directory, so a pod's writes land in the fleet
# group. setgid fixes the GROUP and never the MODE: at 022 every entry pip/npm/cargo leaves is
# `0644`, and the next human's pod reads it without being able to replace it. The cache silently
# becomes one stale copy per human. These two witnesses hold the fix from both ends — that the
# value REACHES the sandbox, and that it is set late enough not to loosen anything else.

@test "toolchain store: the pod is launched under umask 002" {
  # Behavioural, not a grep: the stub records ITS OWN umask, so this proves the value crosses the
  # exec. `env -i` is no threat to it — a umask is a process attribute, not an environment
  # variable — and this witness is what would catch someone "cleaning up" that distinction.
  cat > "$LCARS_BWRAP_BIN" <<STUB
#!/usr/bin/env bash
umask > "$TMP_BASE/bwrap.umask"
exit 0
STUB
  chmod +x "$LCARS_BWRAP_BIN"
  umask 022
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$TMP_BASE/bwrap.umask")" == "0002" ]]
}

@test "toolchain store: umask 002 is set LAST, immediately before the exec" {
  # Everything the launcher creates before this point — the pod dir, the socket dir — must keep the
  # mode it was created with. Moving the line up would widen them by a side effect nobody reads as
  # one, and no other witness here would notice.
  run bash -c "grep -n -E '^(umask 002|exec env -i)' '$SCRIPT' | cut -d: -f1 | tr '\\n' ' '"
  read -r umask_line exec_line <<< "$output"
  [[ -n "$umask_line" && -n "$exec_line" ]]
  [[ $((exec_line - umask_line)) -eq 2 ]]
}

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  grep -q "^# SOURCE:" "$SCRIPT"; grep -q "^# AUTHOR:" "$SCRIPT"
  grep -q "^# STARDATE:" "$SCRIPT"; grep -q "^# STATUS:" "$SCRIPT"
}

# ============================ fleet.feed : le journal est RO pour le pod ============================
#
# `fleet.feed` est ce que le RUNTIME raconte au pod. Le pod_dir etant monte en ecriture, le pod
# pouvait l'editer — et `PodFeed.append/2` RELIT le fichier avant de le reecrire, donc une ligne
# posee par l'agent revient signee par le runtime. Ces tests tiennent les trois proprietes dont
# depend le montage : le fichier EXISTE au spawn (bwrap bind strictement), il n'est PAS tronque
# (le pod_dir survit au respawn), et le ro-bind vient APRES le bind du dossier (bwrap applique
# dans l'ordre : avant, il serait annule).

@test "feed: le fichier est CREE au spawn — sinon bwrap n'a rien a binder" {
  rm -f "$POD_DIR/fleet.feed"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ -f "$POD_DIR/fleet.feed" ]]
}

@test "feed: un journal DEJA ECRIT n'est jamais tronque par un respawn" {
  printf '10:15 jalon precedent\n' > "$POD_DIR/fleet.feed"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  run cat "$POD_DIR/fleet.feed"
  [[ "$output" == *"jalon precedent"* ]]
}

@test "feed: monte en LECTURE SEULE dans le home du pod" {
  export LCARS_POD_HOME="/home/.pod"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--ro-bind $POD_DIR/fleet.feed /home/.pod/fleet.feed"* ]]
}

@test "feed: le ro-bind vient APRES le bind du pod_dir (sinon il est recouvert)" {
  export LCARS_POD_HOME="/home/.pod"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  dir_bind="${output%%--ro-bind $POD_DIR/fleet.feed*}"
  [[ "$dir_bind" == *"--bind $POD_DIR /home/.pod"* ]]
}

@test "feed: un pod dont le cwd RE-MONTE le pod_dir le voit RO sous SES DEUX chemins" {
  # L'arch : /home/.pod et /home/<projet> sont la meme source. Un seul monte RO laisserait
  # l'autre ecrivable, ce qui revient a n'en monter aucun.
  export LCARS_POD_HOME="/home/.pod"
  export LCARS_POD_CWD="/home/chifoumi"
  export LCARS_POD_CWD_SRC="$POD_DIR"
  run "$SCRIPT" architect pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--ro-bind $POD_DIR/fleet.feed /home/.pod/fleet.feed"* ]]
  [[ "$output" == *"--ro-bind $POD_DIR/fleet.feed /home/chifoumi/fleet.feed"* ]]
}

@test "feed: un pod dont le cwd est un CLONE ne recoit que le montage du home" {
  # Le producteur travaille dans un clone : il n'y a pas de feed a cet endroit-la, et en binder un
  # y planterait un fichier que le depot ne connait pas.
  export LCARS_POD_HOME="/home/.pod"
  export LCARS_POD_CWD="/home/projet"
  export LCARS_POD_CWD_SRC="$POD_DIR/projet"; mkdir -p "$LCARS_POD_CWD_SRC"
  run "$SCRIPT" engineer pod-1 "$POD_DIR" /bin/true
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"--ro-bind $POD_DIR/fleet.feed /home/.pod/fleet.feed"* ]]
  [[ "$output" != *"/home/projet/fleet.feed"* ]]
}
