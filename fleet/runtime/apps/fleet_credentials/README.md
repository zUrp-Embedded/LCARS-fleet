# Fleet.Credentials

Business OAuth gates for LCARS v2 pods. The auth model is the **native Anthropic claudeDir** (`~/.claude/.credentials.json`) — LCARS manages neither storage nor refresh: just **2 gates** (scope + plan) that read the file directly.

## Model

Pods authenticate via the native Anthropic claudeDir, **shared per-human** across the pods of a single Linux UID (composes with ADR-E: N humans = N Linux users in 1 container = N distinct claudeDirs). Cross-process OAuth refresh is **100% delegated to the `claude` binary** via a POSIX lockfile (`proper-lockfile`).

**No LCARS write *at pod runtime* into `.credentials.json`** — onboarding (by starfleet, outside bwrap, cf. §Onboarding) is the only write path. No LCARS vault, no `CLAUDE_CODE_OAUTH_*` env vars injected into the pod, no LCARS-side refresh scheduler.

### The native Anthropic `.credentials.json`

**Linux default** path: `~/.claude/.credentials.json`, `chmod 0600` (imposed by the Linux/WSL/Windows `plainTextStorage` — the only backend LCARS uses; macOS would use Keychain, but LCARS = Linux server-side). Override possible via the `CLAUDE_CONFIG_DIR` env (not used by LCARS).

Two slots cohabit in the same file:

```json
{
  "claudeAiOauth": {
    "accessToken": "...",
    "refreshToken": "...",
    "expiresAt": <ms_epoch>,
    "scopes": ["user:profile", "user:inference", "user:sessions:claude_code",
               "user:mcp_servers", "user:file_upload"],
    "subscriptionType": "max" | "pro" | "team" | "enterprise" | null,
    "rateLimitTier": "..." | null
  },
  "mcpOAuth": {
    "<serverKey>": {
      "serverName", "serverUrl",
      "accessToken", "refreshToken?", "expiresAt", "scope?",
      "clientId?", "clientSecret?", "discoveryState?", "stepUpScope?"
    }
  }
}
```

- `claudeAiOauth` — main Anthropic subscription (`claude /login`), managed by the claude binary's `utils/auth.ts`.
- `mcpOAuth[serverKey]` — per-MCP-server OAuth (when an MCP server requires OAuth), managed by `services/mcp/auth.ts`. **Distinct system**, LCARS does not touch it. Share-claudeDir shares both slots implicitly. Full schema: reverse `#0_ref_mcp-oauth.md` §1.

## LCARS-side modules (the only things we code)

- `Fleet.Credentials.Gate` — **single entry point** of credentials gating at the spawn-boundary. `validate(claude_dir, cap_profile) :: :ok | {:error, {:credentials_invalid, reason}}`: reads the human claudeDir's `.credentials.json` ONCE (`claudeAiOauth` block), validates the scopes (per-role, via the cap-profile flags) then the paid plan; the first failure short-circuits. This is where the file read **physically lives** (`read_oauth_creds/1`, single source of a single `File.read` + `Jason.decode`) — reconciles the contract (the model already says "the gates read the file directly") with the code (the read used to live in `Fleet.Spawner.Pod`; moved here). Pure transformer, no state, no process: the claudeDir path is resolved by the caller (per-human) and passed as an argument. Consumed by `Fleet.Spawner.Pod` (`LaunchEnv`) at pod launch.
- `Fleet.Credentials.ScopeValidator` — **scope-coverage** gate: checks `oauth_scopes ⊇ role_required_scopes` by reading `claudeAiOauth.scopes` from `.credentials.json`. Profiles:
  - `default`: requires `user:inference` + `user:sessions:claude_code` (Remote Control)
  - `bridge_enabled`: adds `user:profile` (Bridge / Remote Control opt-in)
  - `mcp_oauth`: adds `user:mcp_servers` (for MCP-OAuth servers)

  Combinable flags (union of the required scopes, computed by `compute_required/1`).
- `Fleet.Credentials.PlanValidator` — **Pro/Max/Team/Enterprise plan** gate: reads `claudeAiOauth.subscriptionType` directly from the file. No network call, no SDK.
- `Fleet.Credentials.ForgeAuth` — `git_env/0`: **system-side** git auth for private forge ops (clone/fetch/ls-remote/push). **Single source** consumed by `Fleet.Workflow.Git`, `Fleet.Pilot.StepDispatcher.ProjectResolver` (ls-remote), `Fleet.Pilot.GitOps` (`:auth` opt) and, as the default env, `Fleet.Credentials.Shell.git/2`. Token injected via the `GIT_CONFIG_*` env vars (kept off argv/`/proc/cmdline`, which is world-readable), never persisted into `.git/config` (pod forge-blindness). Config `:fleet_credentials, :forge_auth = %{url_prefix, token}` set at boot. **ALWAYS carries `GIT_TERMINAL_PROMPT=0`** (anti-hang bound: a git without a credential fails instead of prompting with no TTY) + the auth extraheader if `forge_auth` is configured.
- `Fleet.Credentials.Shell` — `run/3` + `git/2`: execution of an external command bounded **BY CONSTRUCTION**. Launches the command via `setsid -w` (dedicated process-group) then `Port.open` (holds the wrapper's `os_pid`). Two HARD properties of the bound:
  - **Process-group, not top-level**: at the deadline, the **whole GROUP** is killed (`kill -s KILL -- -<pgid>`, the PGID discovered via `/proc/<child>/stat`) → the process AND all its descendants (git transport helpers, credential helpers, filters) die together. Killing only the top-level would leave them alive (they keep the forge token in their environ). ⚠ The `--` is mandatory: without it `/usr/bin/kill` reads the `-<pgid>` (starts with `-`) as an OPTION and does NOT kill the group.
  - **WALL deadline, not idle-gap**: the deadline is absolute (`monotonic_now + timeout_ms`, computed once); the `receive` loop waits only for the REMAINING time, never an `after timeout_ms` re-armed on each `{:data}`. A network-hung git that DRIPS output (one byte just before each expiry) is killed at the wall deadline, not postponed forever.

  Hardens the historical `Task.async`+`brutal_kill` pattern of `Fleet.Workflow.Git`, which killed the BEAM Task but let the OS process (and its descendants) leak. `git/2` injects `ForgeAuth.git_env/0` by default (anti-prompt + auth). Typed, non-ignorable result: `{:ok, {out, code}}` | `{:error, {:timeout, ms}}` | `{:error, {:exit, reason}}` (`:exit` also when `setsid` is absent — fail-closed rather than a bare, ungrouped `System.cmd`). Placed here (below bootstrap/workflow/pilot) → no compile cycle. Makes an unbounded `System.cmd("git", …)` **unrepresentable** on the PROJECT path. **Linux** (documented target: `setsid` + `/proc`). Consumed by `Fleet.Workflow.Git` (add/commit/rev-parse/push), `Fleet.Workflow.DeliverableGate`, `Fleet.Pilot.StepDispatcher.ProjectResolver` (ls-remote), `Fleet.Pilot.GitOps` (fleet_pilot's git wrapper — `Fleet.Pilot.ProjectOnboard` goes through IT for clone/worktree/commit/push) and `Fleet.ProjectBootstrap.Phase`.

  **`git_safe_config_args/0` (SINGLE SOURCE of the system-side git config neutralization)**: the list of `-c <key>=<val>` arguments to prefix to EVERY git op launched by the runtime (outside bwrap) on a workspace co-written by an adversarial pod. Neutralizes the git mechanisms steerable from the repo's content: `core.hooksPath=/dev/null` (hooks), `core.fsmonitor=`, `core.sshCommand=`, `diff.external=` (external diff driver executed by `git log -p`/`diff`/`show`), `core.attributesFile=/dev/null` (the GLOBAL attributes file). A single definition — the sites COMPOSE it instead of recopying the list (`Fleet.Workflow.Git`, `Fleet.Workflow.DeliverableGate`; `Deliverable` no longer composes anything directly since 2026-07-04, its rev-parse goes through `Fleet.Workflow.Git`). **Honest limit**: an IN-TREE `filter.<name>.clean` (armed by a `.gitattributes` + a `.git/config` definition in the repo) is NOT disableable via `-c` (git has no "disable all filters" switch); that vector is closed CONTENT-SIDE (fail-closed refusal of a payload that would write `.git/**` or a `.gitattributes` arming `filter=`/`diff=`, done by `Fleet.Workflow.PayloadGuard`). Since the filter's `.git/config` definition is never cloned from a remote, refusing the `.git/**` write content-side breaks the full chain.
- `Fleet.Credentials.Human` — the **SINGLE** source of "the fleet's human" = the OS user of the runtime process (`id -un`). Consumed by `ForgeIdentity`, the spawner (pod = the human), `Fleet.Pilot` (`Poller`, `StepRunCompleter`) and `Fleet.MCP.PodTools.Delegation`.
- `Fleet.Credentials.ForgeIdentity` — git identity of a deliverable: **author = the human** (via `Human`; name/email **DERIVED from the OS** — `git config --global` → GECOS → login, email fallback `<login>@<hostname>`; the catalogue is REMOVED, 2026-06-11 doctrine: an OS user ⇒ always an identity), **role = trailer `Co-authored-by: LCARS-<role>`** verified by the commit-identity gate. Fail-loud only if `id -un` is unresolvable. Also carries the SYSTEM identity (`system_identity/0` = `lcars-system@lcars.local`, single accessor), the commit-identity gate's `allowed_emails/2` and `coauthor_instruction/1` (single source of the trailer injected into the brief). Test seam: `:forge_identity_override` config.
- `Fleet.Credentials.RoleToken` — `token/1`: forge token of a ROLE's account, to post IN ITS NAME (issue by `Architect`, review by `Reviewer` — true avatar/traceability). Read from `<role_tokens_dir>/<role>.gitea_token` (config `:role_tokens_dir`, default `/home/private`); `role` validated path-safe via `Fleet.Slug`. Best-effort: absent/empty/unreadable → `nil` with a logged warning, the caller falls back to the system token (a provisioning hole to look into, not a fatal error). Consumed by `Fleet.Pilot` (StepRunCompleter, GatekeeperSeal, ForgeClient) and `Fleet.MCP.PodTools.Delegation`.

## Configuration (`:fleet_credentials`)

- `:forge_auth` — `%{url_prefix, token}` of the system-side git auth (`ForgeAuth.git_env/0`). Set at boot by `config/runtime.exs` from `FORGE_BASE_URL` + `FORGE_PUSH_TOKEN`/`FORGE_TOKEN`/the `FORGE_TOKEN_FILE` file (default `~/.gitea_token`). Absent → `git_env/0` only carries `GIT_TERMINAL_PROMPT=0`.
- `:role_tokens_dir` — root of the role tokens (`RoleToken`), default `/home/private`. Overridden by the `FORGE_ROLE_TOKENS_DIR` env (`config/runtime.exs`, multi-forge via env profile: one isolated token set per forge).
- `:forge_identity_override` — test seam (`%{name, email, human?}`): short-circuits `ForgeIdentity`'s OS derivation (set by `config/test.exs`; an explicit `:identity` in opts disables it, to test the real resolution).

(The `LCARS_CREDENTIALS_ROOT` → `:credentials_root` vault knob is **REMOVED** — no reader left, ADR-F: creds = the human's bound claudeDir, not a vault.)

## Distribution — per-human `share-claudeDir` (ADR-F, decided 2026-05-26)

All of a human's pods share **their** claudeDir (`/home/<human>/.claude/`). Sharing boundary = the human (UID/account). **Cross-human isolation** = distinct Linux UID + bwrap mount NS (cf. ADR-E §Isolation), not the `chmod 0600` alone.

The claudeDir bind inside the pod is defined by `04_design-notes/ring0/bwrap_launch.md` (canonical DN; the runtime script `bin/bwrap_launch.sh` is its implementation). Under bwrap containment, ONLY `.credentials.json` is bind-mounted RW into the pod's `.claude/` — the rest of `.claude/` is pod-owned (the human's settings/hooks do not leak into the pod); under `containment: none` (`bin/host_launch.sh`) the pod uses the human's native `~/.claude` directly. (The old `fleet_project_bootstrap` BIND phase that configured the mounts is REMOVED — dead code never wired in prod; mounts/creds are handled by `bwrap_launch.sh`.) **No copying** of creds between pods (`copy-direct` rejected by ADR-F).

De-risking PoC (2026-05-26): 5 concurrent bwrap pods + 1 sequential warmup; shared claudeDir intact, `projects/` without collision, 0 residual lock. **The PoC validates claudeDir/`projects/` concurrency, NOT the safety of the `.credentials.json` clobber under concurrent refresh** (refresh gate >20min out of scope by design; cf. §Accepted caveats).

### Accepted caveats (cf. ADR-F + reverse)

- **`.credentials.json` clobber under concurrent refresh**: *presumed* safe (Anthropic `rename(2)` atomicity to be confirmed at build — known open gap); refresh gate >20min out of the PoC's scope.
- **Cross-process stale-cache window** (reverse §F6, Linux): a pod that sees its token as fresh does not re-read the disk even if another pod refreshed; converges on the 1st 401 via `handleOAuth401Error`. Distinct from the clobber, accepted by design.
- **Shared dead-token backoff** (reverse §9, `initReplBridge.ts:177-240`): persistent state in **`~/.claude.json`** (NB: *not* `.credentials.json`) — fields `bridgeOauthDeadExpiresAt` + `bridgeOauthDeadFailCount` (capped at 3), content-addressed by `expiresAt`. If one pod hits "dead refresh-token" 3×, **all of the human's pods** inherit the backoff. Recovery via interactive `claude /login` by the human: a new `/login` produces a new `expiresAt`, the content-addressed key no longer matches → the backoff resets implicitly (the `/logout` forbidden by §Invariants is NOT required).
- **Lockfile retry-exhausted** (reverse §F2, event `tengu_oauth_token_refresh_lock_retry_limit_reached`): under N simultaneous pods at the same `expiresAt − 5min`, the 5 retries × 1-2s can be exhausted → `checkAndRefreshOAuthTokenIfNeeded` returns `false` silently → the API call goes out with the current token → 401 → reactive recovery via `handleOAuth401Error` on the claude-binary side. Convergence assured but to be monitored (event to instrument at build).

## Onboarding

starfleet (root-trusted sysadmin, running outside bwrap by design) **is the only write path** into `.credentials.json` — it places the creds in the human's claudeDir at onboarding (composes with ADR-E §Onboarding). Detailed onboarding/catalogue DN = post-ADR-F backlog.

## Anthropic auth precedence (official order)

Anthropic resolves credentials in this order (rank 1 = **highest priority**, preempts the ranks below):

| Rank | Source | LCARS |
|---|---|---|
| 1 | Cloud provider (`CLAUDE_CODE_USE_BEDROCK`/`VERTEX`/`FOUNDRY`) | excluded from the pod env |
| 2 | `ANTHROPIC_AUTH_TOKEN` | excluded from the pod env |
| 3 | `ANTHROPIC_API_KEY` | excluded from the pod env |
| 4 | `apiKeyHelper` script | controlled settings.json (not configured) |
| 5 | `CLAUDE_CODE_OAUTH_TOKEN` (long-lived setup-token) | excluded from the pod env + never generated |
| **6** | **Subscription OAuth `/login`** | **← the rank LCARS uses** |

⚠ **Descending** precedence: a higher rank **preempts** the ranks below. If a setup-token (rank 5) were present, it would mask the subscription (rank 6). LCARS prevents this by **never generating a setup-token** AND by **keeping the rank 1-5 env vars out of the pod env** at launch.

LCARS-side mechanism: the pod env is **closed by construction** — built explicitly by `Fleet.Spawner.Pod` (`LaunchEnv`) and injected by `bin/bwrap_launch.sh` under `--clearenv` (everything goes through explicit `--setenv`; nothing of the spawner's ambient env leaks). `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` / `CLAUDE_CODE_OAUTH_TOKEN` / `CLAUDE_CODE_USE_*` are simply never injected; the pod's `settings.json` does not configure `apiKeyHelper`. (Under `containment: none`, `bin/host_launch.sh` has no `--clearenv` — the pod inherits the BEAM's ambient env; the rank 1-5 exclusion there rests on the human's launch env not exporting them.) The native `.credentials.json` provides the subscription OAuth (rank 6).

NB: reverse §26 (`utils/auth.ts:153-206`, `getAuthTokenSource()`) documents two FD slots (`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`, `CCR_OAUTH_TOKEN_FILE` disk fallback) resolved around the `apiKeyHelper` / `CLAUDE_CODE_OAUTH_TOKEN` ranks. LCARS injects neither the FD nor the fallback file — inert slots. (`ANTHROPIC_API_KEY`, rank 3, is resolved by the sister function `getAnthropicApiKeyWithSource()`.)

## Invariants

- **NEVER** `ANTHROPIC_API_KEY` (rank 3, excluded from the pod env).
- **NEVER** `ANTHROPIC_AUTH_TOKEN` (rank 2, excluded from the pod env).
- **NEVER** `--bare` (API-key-only mode, skips subscription OAuth entirely — gated ahead of the precedence).
- **NEVER** `claude setup-token`: scope `user:inference` ONLY → (a) incompatible with MCP-OAuth (`user:mcp_servers` absent), (b) **incompatible with Remote Control** (`user:sessions:claude_code` absent) → **directly breaks ADR-G**; explicit user-reject 2026-05-09.
- **NEVER** `/logout`: `secureStorage.delete()` deletes `.credentials.json` **entirely** (the `claudeAiOauth` slot + all `mcpOAuth[*]` slots) → wipes **all** of the human's pods + all of the human's MCP-OAuth servers.
- Refresh = **delegated to the claude binary** (native lockfile, refresh at `expiresAt − 5min`, 5 retries with 1-2s backoff).
- Atomicity = the native Anthropic POSIX lockfile (cf. §Accepted caveats).

## ADR-G coherence (post-2026-06-15)

The Anthropic billing pivot (announced 2026-05-14, effective 2026-06-15, confirmed by the official docs) separates:

- **Interactive terminal `claude` REPL** = subscription = **used by LCARS**.
- **Programmatic `claude -p` / SDK / stream-json** = separate metered pool = **forbidden for LCARS**.

LCARS launches pods in **interactive Mode A** per ADR-G (interactive `claude` REPL under tmux). Remote Control activation is wired by `bin/claude_launch.sh` (sole writer of the pod's `.claude.json`): the `--remote-control` flag AND `remoteControlAtStartup` in the pod's `.claude.json`, both conditioned on the cap-profile's `spec.invocation.remote_control` flag (so that judge pods stay invisible in Desktop); the `/remote-control [name]` slash inside the REPL remains the manual path — the exact incantation is defined by `04_design-notes/ring0/claude_launch.md`. **Mode B** (the `claude remote-control` subcommand, which spawns `claude --print` children) = headless = **explicitly ruled out by ADR-G**.

## Articulation

| Doc | Relation |
|---|---|
| `01_architecture/adr-f-credentials-anthropic-natif.md` | canonical ADR, PROMOTED 2026-05-26 |
| `01_architecture/adr-e-single-user-runtime.md` | N humans = N Linux users in 1 container; N claudeDirs |
| `01_architecture/adr-g-launch-subscription.md` | interactive Mode A under tmux (subscription), not `-p` (metered) |
| `04_design-notes/ring0/fleet_credentials.md` | short model (native claudeDir + 2 gates) |
| `04_design-notes/ring0/bwrap_launch.md` | RW bind of the human's `.credentials.json` (that file alone; `.claude/` is pod-owned) |
| `04_design-notes/ring0/claude_launch.md` | exact incantation of the Mode A REPL |
| `04_design-notes/ring1/fleet_project_bootstrap.md` | historical: its claudeDir BIND phase is REMOVED from the code — mounts/creds are handled by `bwrap_launch.sh` |

## External sources

- Reverse `inbox/src/#0_audit-reverse/#0_ref_oauth-token-lifecycle.md` (snapshot 2026-04-12, addendum 2026-05-01 — based on Claude Code v2.1.88) — main claude.ai OAuth: `utils/auth.ts`, lockfile, refresh, anti-storm. Mechanics stable, confirmed by the official docs.
- Reverse `inbox/src/#0_audit-reverse/#0_ref_mcp-oauth.md` (snapshot 2026-05-01) — per-server MCP OAuth: distinct `mcpOAuth[serverKey]` slot, per-server lockfile, XAA/CIMD (enterprise, not applicable to a personal starfleet).
- Up-to-date official Anthropic doc: `https://code.claude.com/docs/en/authentication` (the most recent; priority 1 in case of reverse/canon divergence).
