# LCARS Fleet runtime config (per-human launch via bin/fleet_v2)
#
# Evaluated at every release start (post-Mix release build, runtime)
# AND by `mix test` (Mix loads config/runtime.exs in ALL envs).
#
# The `config_env() != :test` guard is MANDATORY: this file is boot
# config (it reads env vars of the human run `~/.lcars/fleet_v2.env`,
# nonexistent in test) and it is evaluated AFTER `config/test.exs`. Without the
# guard, `config :lcars_fleet, api_start_listener: true` (below) overrides the
# hermetic `start_listener: false` of test.exs → fleet_api starts the
# Cowboy listener in test → boot crash → dead daemon boot. Any runtime
# config added STAYS INSIDE the guard (hermetic discipline: runtime config ≠ tests).
#
# ─── THIS FILE CROSSES EVERY BOUNDARY, AND `boundary` CANNOT SEE IT ────────────────────────────
# `config/` is not in `elixirc_paths` — it is never compiled, so the compiled guardian of the
# architecture has no opinion about anything below. **The boundary map is therefore not the map of
# real couplings**, and this file is the gap: it calls application modules directly, across domains
# that `mix compile` would refuse to let call each other.
#
# It is deliberate, and the alternatives are worse. `Fleet.EnvParse` holds the env parsing because
# an inline lambda in a file wrapped `config_env() != :test` would never be tested. `Fleet.Layout`
# holds the platform paths because it is the authority on them, and inverting the call would add a
# dep to the one module whose layer name is mechanically checkable (`foundation ≡ deps: []`). The
# module *references* posted as values — the shutdown dispatcher, the coord backend, the incident
# rail, the completion-inflight fun — are seams: they cross as data so the domains stay uncoupled
# at compile time.
#
# THE COST, since it is not free: a failure inside one of those modules surfaces here as a
# CONFIGURATION error, with the diagnostic that comes with it, rather than as what it is. And no
# tool will tell you when a new call is added — this paragraph is the only place that says the
# blind spot exists. Every release start evaluates this file, so an unloadable module fails loud
# immediately; that is what the constraint is verified BY, and it is a boot, not a wall.
#
# If you add a call here, add it to the list above. A blind spot nobody wrote down stops being a
# known cost and becomes a surprise.

import Config

# TOOL MODE — a release `eval` runs the config providers (this whole file) BEFORE evaluating its
# expression. A verify/tooling invocation is NOT a fleet boot: it must not demand the deployment
# env (ports, forge, credentials). One flag skips the ENTIRE deployment-config body — deliberately
# coarse, so every present AND future deployment requirement below is covered at once, never a new
# variable to simulate per requirement (that whack-a-mole is what would re-create a dialect). Set
# by the tool entrypoint (`Fleet.Application.CatalogueVerify` via `bin/lcars_fleet eval`), absent
# on the daemon path, so the daemon still fails loud on a missing port. Cooperative threat model:
# setting this and then `start`ing the daemon is a deliberate misuse, out of scope like R-no-root.
tool_mode? = System.get_env("LCARS_TOOL_EVAL") == "1"

# HORS du garde `tool_mode?`, et c'est un correctif : ce bloc n'ouvre aucun port et ne demarre rien.
# Il dit seulement OU vivent les catalogues declares — un fait de lecture dont TOUTE porte `eval` a
# besoin. Enferme dans le garde, `LCARS_TOOL_EVAL=1` le sautait avec le reste, et un outil ne voyait
# que le catalogue livre : `lcars project migrate <projet> web` refusait « web n'est pas actif » sur
# une boite ou il l'etait, parce que la declaration lui etait invisible. Mesure du 2026-08-11 :
# `active_names()` rendait ["fleet"] sous eval la ou le boot en voyait deux.
#
# L'ORDRE de `install_dirs` est l'ordre de recherche d'un NOM, pas une precedence entre catalogues
# (celle-la est l'ordre des lignes du fichier) : le repertoire de l'operateur d'abord, pour qu'un
# catalogue importe masque un livre du meme nom.
#
# Pas de variable d'env : la declaration est un FICHIER que l'operateur edite, et pointer dessus par
# une variable mettrait la reponse a deux endroits. Fichier absent = le catalogue metier livre, seul.
if config_env() != :test do
  config :lcars_fleet,
    catalogue_active_declaration: Fleet.Layout.active_catalogues_path(),
    catalogue_install_dirs: [
      Fleet.Layout.catalogues_operator_dir(),
      Fleet.Layout.catalogues_shipped_dir()
    ]
end

# HORS du garde pour la meme raison que le bloc ci-dessus, et le meme defaut l'a revele : lire trois
# variables d'env n'ouvre rien et ne demarre rien. Resolue par `ForgeClient.resolve_config/1` a
# l'appel, cette config est ce qui permet a une porte `eval` d'AGIR sur la forge — et c'est le
# design : `bin/lcars` n'a aucun acces forge, lui en donner un ferait d'une commande locale un
# acteur distant, donc c'est le release qui agit. Enfermee dans le garde, elle rendait
# `lcars project migrate` structurellement incapable : mesure du 2026-08-11 sur banc,
# `ECHEC : {:config, {:missing, :base_url}}` — le transfert echoue FERME, sans demi-etat, mais la
# porte n'avait jamais pu fonctionner.
forge_opts =
  if config_env() != :test do
    [
      base_url: System.get_env("FORGE_BASE_URL"),
      token: System.get_env("FORGE_TOKEN"),
      token_file: System.get_env("FORGE_TOKEN_FILE")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  else
    []
  end

if forge_opts != [] do
  config :lcars_fleet, :pilot_forge, forge_opts
end

if config_env() != :test and not tool_mode? do
  # ============================================================
  # R-no-root-runtime — anti-root boot guard
  # ============================================================
  # The fleet daemon NEVER runs as root (the BEAM runs under the human's UID; this self-check
  # catches dev/manual launches as root, where `~/.gitea_token` resolves to `/root/.gitea_token` =
  # the admin token). starfleet/sysadmin is OUT-of-fleet (invoked outside the daemon) → no
  # exception here. Hygiene, not an anti-adversary defense (cooperative threat model).
  #
  # NO ENVIRONMENT CONDITION, and that is the point: the danger it names — a daemon writing
  # root-owned state into `~/.lcars`, then unreachable to the human UID that owns the next boot —
  # belongs to the MANUAL launches, which are `:dev` ones. Gating it on `:prod` armed the guard
  # exactly where nobody launches by hand and disarmed it where everybody does. `:test` never
  # reaches here (the whole file is guarded out).
  #
  # EVERY failure to READ the uid answers with the same refusal. `id` can be absent from a minimal
  # image, non-executable, or exit non-zero, and `System.cmd/3` raises `:enoent` of its own — a
  # strict match turned a security refusal into a filtering exception, so the operator got a stack
  # trace instead of the sentence that says what to do. A guard that cannot measure must not let
  # the boot through.
  uid_reading =
    try do
      case System.cmd("id", ["-u"]) do
        {out, 0} -> String.trim(out)
        {out, code} -> {:unreadable, "`id -u` exited #{code}: #{String.trim(out)}"}
      end
    rescue
      e -> {:unreadable, Exception.message(e)}
    end

  case uid_reading do
    "0" ->
      raise "R-no-root-runtime: the fleet daemon refuses to run as root " <>
              "(launch under your human UID via bin/fleet_v2, never as root)"

    {:unreadable, why} ->
      raise "R-no-root-runtime: the runtime UID could not be established (#{why}) — the anti-root " <>
              "guard refuses a boot it cannot verify (launch via bin/fleet_v2)"

    _other ->
      :ok
  end

  # ============================================================
  # fleet_mcp — fail-closed boot guard
  # ============================================================
  # The code default of `Fleet.MCP.Server.boot_environment` is `:pod` — it refuses BY OMISSION, and
  # a boot that declares neither here nor in config/test.exs is refused, never started permissively.
  #
  # THE POSITIVE DECLARATION IS NOW ACTUALLY POSITIVE (D2, closed 2026-08-05). This line used to be
  # unconditional, so ANY BEAM running this app declared itself host — including, in principle, one
  # started inside a pod. The doctrine said "a boot that does not declare `:host` is refused by
  # omission"; the declaration was made by the file itself, so the omission could not happen and the
  # guard vouched for a fact nobody had checked.
  #
  # `LCARS_HOST_BOOT` is exported by `bin/fleet_v2` at daemon start. A pod's projected environment is
  # a WHITELIST built by `LaunchEnv` (`LCARS_POD_*`, `LCARS_PROJECT_OPS`, …) and carries no such
  # variable, so a BEAM launched in that world falls to the fail-closed `:pod` and the MCP
  # supervisor refuses to boot.
  #
  # COST, written next to the switch: a boot that bypasses `bin/fleet_v2` — a developer's
  # `iex -S mix` starting the whole app — must now say so: `LCARS_HOST_BOOT=1 iex -S mix`. That is
  # the point rather than a side effect; the alternative is a declaration that declares nothing.
  # (`mix test` is unaffected: `config/test.exs` declares `:host` on its own.)
  config :lcars_fleet,
    mcp_boot_environment: if(System.get_env("LCARS_HOST_BOOT") == "1", do: :host, else: :pod)

  # `delete_project` — the ONE irreversible act of the tool surface (forge repo + both worktrees),
  # aimed by a free argument, reachable by any onboarder pod. Off unless this deployment says
  # otherwise; `force: true` at the call site makes the gesture deliberate, this makes it AVAILABLE,
  # and the two are different questions. Cost of arming it, written where the switch is: every
  # onboarder pod regains a destructive verb for the whole life of the daemon.
  # The code reads `=== true`, so a non-boolean here does not arm it.
  config :lcars_fleet,
         :mcp_allow_delete_project,
         Fleet.EnvParse.bool(
           "LCARS_ALLOW_DELETE_PROJECT",
           System.get_env("LCARS_ALLOW_DELETE_PROJECT"),
           false
         )

  # Env-var parsing is DELEGATED to `Fleet.EnvParse` (foundation, TESTABLE — this file is
  # wrapped `config_env() != :test`, an inline lambda would never be tested).
  # Bounded domain: `port` (1..65535), `positive_ms` (>0), `count` (≥0), `bool` (recognized forms +
  # default if unknown), `path` (expand + `..`/control rejection). An invalid load-bearing knob → clear raise.

  # ============================================================
  # Logger
  # ============================================================
  # A bare `String.to_existing_atom` would crash the boot on an unknown level
  # (e.g. LCARS_LOG_LEVEL=verbose). Validated against the Logger enum; unknown → :info fallback
  # + stderr warning (a bad log level must NOT prevent the boot — non-critical).
  log_level =
    case System.get_env("LCARS_LOG_LEVEL", "info") do
      lvl when lvl in ~w(emergency alert critical error warning notice info debug) ->
        String.to_existing_atom(lvl)

      other ->
        IO.puts(
          :stderr,
          "LCARS config: LCARS_LOG_LEVEL=#{inspect(other)} invalid — falling back to :info"
        )

        :info
    end

  config :logger, level: log_level

  # ============================================================
  # The warning+ trace ON DISK (BL-6-41)
  # ============================================================
  # `config :logger, level:` above used to be the ONLY logger configuration of this project: every
  # load-bearing warning lived in the daemon's tmux ring buffer and died with it, which makes an
  # incident un-auditable after the fact. `Fleet.DurableLog` owns the two decisions (warning+, and
  # the human's `.lcars/log/` beside their env file rather than the release directory a deploy
  # replaces); here we only resolve the PATH, since it is the operator's to move.
  #
  # `LCARS_LOG_FILE=` (explicitly empty) DISABLES it. That is not a courtesy knob: on a read-only
  # or ephemeral home the handler would fail to install at every boot, and an operator must be able
  # to say "I know, I collect elsewhere" without reading a warning about it forever.
  durable_log_path =
    case System.get_env("LCARS_LOG_FILE") do
      nil -> Path.expand("~/.lcars/log/fleet.log")
      "" -> nil
      explicit -> Fleet.EnvParse.path("LCARS_LOG_FILE", explicit)
    end

  if durable_log_path do
    config :lcars_fleet, durable_log: [path: durable_log_path, level: :warning]
  end

  # ============================================================
  # fleet_catalogue — THE catalogue root (coarse knob)
  # ============================================================
  # One variable brings ONE catalogue: every business tree derives its sub-path from here
  # (`Fleet.Catalogue`, SSoT of the layout). Unset = the bundled priv, which is what the current
  # instance runs. The per-tree keys below stay as FINE overrides and keep precedence over this one.
  if path = System.get_env("LCARS_CATALOGUE_ROOT") do
    config :lcars_fleet, catalogue_root: Fleet.EnvParse.path("LCARS_CATALOGUE_ROOT", path)
  end

  # WHICH catalogues run, and WHERE they are installed — the ordered declaration of section 9.3.
  # These are platform paths, so `Fleet.Layout` is their authority; they arrive HERE rather than
  # being called from `Fleet.Catalogue` so that module keeps `deps: []`, which is the one layer
  # name the topology can check instead of assert.
  #
  # The ORDER of `install_dirs` is the lookup order for a NAME, not a precedence between
  # catalogues (that one is the order of the lines in the file): the operator's own directory
  # first, so an imported catalogue shadows a shipped one of the same name — the `php.ini` over the
  # `php.ini-production`, the same rule as everywhere else here.
  #
  # No env var: the declaration is a FILE the operator edits, and adding a variable to point at it
  # would put the answer in two places. Absent file = the bundled business catalogue alone.

  # ============================================================
  # fleet_cap_profile — cap-profiles catalogue root
  # ============================================================
  # fleet_spawner — skills tree fine override (BL-6-22). ONLY the fine key is mapped here: the
  # DEFAULT is resolved at SPAWN time (`:catalogue` sentinel in Spawner.Pod → Fleet.Catalogue,
  # AFTER Config.Reader's batch-apply — a Catalogue call in THIS file would read the pre-runtime
  # ETS and ignore LCARS_CATALOGUE_ROOT, silently mounting the bundled skills under a custom
  # catalogue). An unconditional default here would also clobber every earlier layer (F6).
  if path = System.get_env("LCARS_SKILLS_ROOT") do
    config :lcars_fleet, spawner_skills_root: Fleet.EnvParse.path("LCARS_SKILLS_ROOT", path)
  end

  if path = System.get_env("LCARS_CAPPROFILES_ROOT") do
    path = Fleet.EnvParse.path("LCARS_CAPPROFILES_ROOT", path)
    # Key `:root_dir` (not `:capprofiles_root`) — what
    # Fleet.CapProfile.root_dir/0 actually reads.
    config :lcars_fleet, cap_profile_root_dir: path
    # Fleet.Spawner.PermanentBoot.cap_profiles_dir/0
    # reads `:lcars_fleet, :spawner_cap_profiles_dir` (a config separate from the
    # loader). Same env source → same shared canonical path.
    config :lcars_fleet, spawner_cap_profiles_dir: path

    # ⚠ SCOPE of this override: it moves the cap-profile YAMLs ONLY. The SP overlay artifacts the
    # profiles reference — modop bundles (`:lcars_fleet, :sp_builder_modop_root`) and subagent templates —
    # stay resolved from the catalogue root (or their own config keys). An operator overriding the
    # profiles WITHOUT the matching SP roots runs overridden profiles over the catalogue's SP
    # fragments: a coherent-looking skew. That narrowness is now a CHOICE, not the only option —
    # to bring a whole catalogue, set `LCARS_CATALOGUE_ROOT` above and none of the fine keys.
  end

  # ============================================================
  # fleet_credentials — no vault. The LCARS_CREDENTIALS_ROOT knob
  # (→ :credentials_root) is RETIRED: no module reads `credentials_root`
  # (the creds = the human claudeDir bind-mounted by bwrap, not a vault).
  # ============================================================

  # The human's git identity is DERIVED from the OS (git config →
  # GECOS → login) — no user catalogue (doctrine: if the user
  # exists on the system, they are a fleet human; we do not over-filter). No knob.

  # ============================================================
  # fleet_event_router — Gitea webhook + OS signals
  # ============================================================
  if path = System.get_env("LCARS_WEBHOOK_SECRET_PATH") do
    config :lcars_fleet,
      event_router_webhook_secret_path: Fleet.EnvParse.path("LCARS_WEBHOOK_SECRET_PATH", path)
  end

  # ON-SWITCH of the Gitea webhook listener (:8081 HMAC). Without it, `:start_webhooks` stays
  # `false` everywhere → WebhooksGitea + the secret + the gitea.* registry keys would be a config
  # surface that can NEVER start. Default OFF (forge integration opt-in). Port overridable.
  #
  # ⚠ USER DECISION — stays OFF DELIBERATELY; this is NOT just "not wired yet".
  # The webhook is only a poll ACCELERATOR: it makes the Poller react to a forge change right
  # away instead of waiting for the next tick (~30 s). But (a) it is a LOSSY hint that can fail /
  # get lost (the durable truth lives in the poll, doctrine D1), and (b) saving 30 s weighs nothing when
  # the agents' reaction is measured in MINUTES. The cost/risk/benefit ratio does not justify it.
  # Do NOT turn it back on "for latency" without re-asking the human this question.
  #
  # ⚖ LA QUESTION A ETE RE-POSEE ET TRANCHEE — 2026-08-14. *« C'etait pour short le poller, pour
  # etre responsive et gagner des secondes de latence. Avec des agents en minutes, on s'en fiche
  # completement. »* Donc : PAS pour la latence, jamais. Ce paragraphe garde sa question — elle a
  # fait son travail, elle s'est fait relire au bon moment — et recoit desormais sa reponse.
  #
  # ⚠ ET UNE DEUXIEME RAISON, TROUVEE EN RELISANT : la forme etait FAUSSE. Le port etait derive du
  # bloc par-humain (`base+3`, pose par `bin/fleet_v2`) — or le Poller sonde l'ORG, partagee, et ne
  # filtre par humain qu'au niveau de l'issue. Un webhook annonce donc un fait DE LA BOITE : un port
  # par humain demanderait a la forge de notifier N adresses du meme evenement. Le lanceur ne pose
  # plus ce port ; le defaut de code (8081) est un port de boite, ce qui est l'axe juste.
  #
  # Mesure du meme jour : aucun code de ce depot ne DECLARE de webhook sur la forge (`POST /hooks`
  # absent), et une forge de banc n'en portait aucun. Ce rail n'a jamais ete branche des deux bouts.
  #
  # SI IL REVIENT UN JOUR, pour une raison qui n'est PAS la latence : une seule URL, un port de
  # boite, hors des blocs. Pas `base+3`.
  if Fleet.EnvParse.bool("LCARS_FLEET_WEBHOOKS", System.get_env("LCARS_FLEET_WEBHOOKS"), false) do
    config :lcars_fleet, event_router_start_webhooks: true

    if port = System.get_env("LCARS_FLEET_WEBHOOK_PORT") do
      config :lcars_fleet,
        event_router_webhook_port: Fleet.EnvParse.port("LCARS_FLEET_WEBHOOK_PORT", port)
    end
  end

  # SignalsOS (:start_signals): NO on-switch — the module is a NON-IMPLEMENTED stub whose
  # `init/1` RAISES before any `:os.set_signal` (fail-loud boot: enabling it is a misconfiguration,
  # never a silent capture of SIGTERM/SIGHUP). The real fix, when the day comes = a gen_event
  # handler on `:erl_signal_server` (OS signals do not reach a GenServer). Stays gated-off, and
  # the registry declares NO `os.signal.*` type: keys for a producer that does not exist were three
  # atoms created at every boot for a broadcast nothing could emit. Whoever lands the handler
  # declares its types in the same gesture.

  # ============================================================
  # fleet_spawner — permanent pods
  # `:boot_permanent_at_start` IS the canonical gate of the permanent-pod boot
  # (consulted by `Fleet.Starfleet.BootOrchestrator` via
  # `PermanentBoot.auto_boot_enabled?/0`, the single authority). Default
  # **true** (prod);
  # `LCARS_BOOT_PERMANENT_AT_START=false` disables it (BootOrchestrator wires the
  # consumers + emits boot_complete but spawns no permanent pod). The second
  # gate `:start_boot_orchestrator` (default true) controls whether the orchestrator
  # runs at all. Two distinct, meaningful knobs.
  # ============================================================
  # STRICT parse (bool!): this is a reduction-of-effects switch — the warn-and-default
  # of `bool/3` would turn a typo'd `false` into a FULL boot (permanent pods spawned,
  # real spend). An unrecognized value refuses the boot instead.
  config :lcars_fleet,
    spawner_boot_permanent_at_start:
      Fleet.EnvParse.bool!(
        "LCARS_BOOT_PERMANENT_AT_START",
        System.get_env("LCARS_BOOT_PERMANENT_AT_START"),
        true
      )

  # ============================================================
  # fleet_spawner — debug visibility (`fleet_v2 start --debug`)
  # Posted by the start door for THIS fleet life. It widens ONE thing:
  # `Pod.LaunchSpec.remote_control?/1` answers true whatever the cap-profile declares, so a pod
  # nobody planned to look at is attachable. Read here rather than at the vendor launcher because
  # the answer also arms the Desktop slot capture and its resume — deciding it at the launcher
  # alone would show a pod whose slot is never captured.
  # ============================================================
  # STRICT parse (bool!): the flag exists to make something VISIBLE, so a typo'd value that
  # silently kept the fleet closed would be the exact failure the operator typed it to avoid.
  config :lcars_fleet,
    spawner_debug_visibility:
      Fleet.EnvParse.bool!(
        "LCARS_DEBUG_VISIBILITY",
        System.get_env("LCARS_DEBUG_VISIBILITY"),
        false
      )

  # ============================================================
  # fleet_spawner pod_dir: PER-HUMAN, derived from the runtime process HOME (pod.ex `pod_dir_for` →
  # `~/pods/pod_<id>`). User decision: no `LCARS_PODS_ROOT` env knob (it would override the
  # per-human derivation). The human = the user who launches the
  # runtime, period. Any override = `config :lcars_fleet, spawner_pod_dir_root: …` directly (tests).
  # ============================================================

  # tmux sock-dir base — the Elixir-side default is home-relative `~/.lcars/run/tmux-sock`
  # (`Fleet.Spawner.PodTmux.sock_base`, fleet launched by a human: a path writable without privilege).
  # This env (set by bin/fleet_v2) overrides it explicitly so that ALL sides compute the same
  # path. Sets both the runtime side (`:tmux_sock_base`) and, via do_launch, the
  # `LCARS_TMUX_SOCK_BASE` env the launchers read.
  if sock_base = System.get_env("LCARS_TMUX_SOCK_BASE") do
    config :lcars_fleet,
      spawner_tmux_sock_base: Fleet.EnvParse.path("LCARS_TMUX_SOCK_BASE", sock_base)
  end

  # ============================================================
  # Launch backend: LauncherPortBackend (bwrap chain) — the default and the only one.
  # ============================================================
  # There is NO out-of-bwrap backend to enable. The bwrap chain is the only sandboxed launch
  # path (it projects the pod's sanctuary — the closed world provided TO the agent).

  # ============================================================
  # fleet_mcp — per-pod MCP socket base (AF_UNIX transport)
  # ============================================================
  # The pod-facing transport is a PER-POD AF_UNIX socket (`<base>/<pod_id>/sock`, created
  # by `Fleet.MCP.PodSocketSupervisor.ensure_pod_socket`, read by the pod via `LCARS_FLEET_MCP_SOCKET`)
  # — never a shared HTTP listener.
  # Default `:sock_base` = `/run/lcars/mcp` (fleet_mcp side). When the runtime is launched by a HUMAN (not
  # a system service), `/run/lcars` is not writable without privilege → override UNDER their home, EXACTLY
  # as `LCARS_TMUX_SOCK_BASE` does for the pod tmux socket. The socket is bound at the SAME
  # absolute path inside the bwrap sandbox (`--bind X X`) → host == namespace (no path remap).
  if sock_base = System.get_env("LCARS_FLEET_MCP_SOCK_BASE") do
    config :lcars_fleet,
      mcp_sock_base: Fleet.EnvParse.path("LCARS_FLEET_MCP_SOCK_BASE", sock_base)
  end

  # EGRESS base — same override, same reason, same ONE source as the MCP socket above: `bin/fleet_v2`
  # exports it, this reads it, and `bwrap_launch.sh` binds the per-pod dir at the same absolute path.
  # Without this the code kept its `/run/lcars/egress` default while the fleet runs home-native, so
  # the directory never existed and every pod launched with no way to reach its vendor. Found on a
  # bench, not by the gate: nothing in the suite knows where a real fleet puts its sockets.
  if egress_base = System.get_env("LCARS_FLEET_EGRESS_SOCK_BASE") do
    config :lcars_fleet,
      spawner_egress_sock_base: Fleet.EnvParse.path("LCARS_FLEET_EGRESS_SOCK_BASE", egress_base)
  end

  # ============================================================
  # fleet_spawner — mcp_server_spec (config of the `.mcp-fleet.json`
  # written into each pod by `Fleet.Spawner.Pod.McpProvision.maybe_provision_mcp_config/5`)
  # ============================================================
  # The claude REPL pod starts the bridge via this spec; the bridge reaches the central over the
  # per-pod AF_UNIX socket, whose path is injected per-pod as `LCARS_FLEET_MCP_SOCKET`. No
  # `LCARS_FLEET_MCP_URL`: no shared HTTP loopback transport exists.
  #
  # IDENTITY IS THE CHANNEL, and nothing else. The central correlates a call to its pod FROM the
  # socket it arrived on, so no pod identity travels in the spec or on the wire — a declared one
  # would be forgeable, and the builder drops it rather than read it. Do not add one back here as
  # a convenience: the entry would carry a claim the protocol refuses to trust.
  #
  # `bridge_source` is a HOST path to COPY, never a path to launch: under bwrap the sandbox mounts
  # neither `/var/lib/lcars` nor the human's tree, so a host path does not exist in the namespace
  # and `bash -c` dies on the log redirect before exec'ing python — no `mcp__fleet__*` tool, hence
  # a pod that can neither pull its brief nor submit its result.
  #
  # ⚠ HOST PATH AND NAMESPACE PATH ARE TWO DIFFERENT PATHS. bwrap RELOCATES the pod_dir behind
  # `LCARS_POD_HOME` (`/home/.pod`), set for every bwrap pod — which is every canon cap-profile.
  # The copy goes to the host path, the `.mcp-fleet.json` references the in-namespace one. Identity
  # between the two holds ONLY for host pods and tests, and assuming it here is the exact trap
  # `McpProvision` documents. It is that module, not this file, that resolves the placeholders and
  # owns the rule.
  #
  # Gate on `bridge_path` ALONE (the bridge must be copyable): the comm target is not a URL but
  # the per-pod socket, resolved at runtime pod-side, not a static boot config.
  if bridge_path = System.get_env("LCARS_FLEET_MCP_BRIDGE_PATH") do
    config :lcars_fleet, :spawner_mcp_server_spec, %{
      # HOST path of the bridge, copied per-pod by `McpProvision` (never launched in place).
      "bridge_source" => Fleet.EnvParse.path("LCARS_FLEET_MCP_BRIDGE_PATH", bridge_path),
      "command" => "bash",
      "args" => [
        "-c",
        # {{BRIDGE}}/{{BRIDGE_LOG}} are resolved by `McpProvision` onto the IN-NAMESPACE path
        # (`sandbox_home/.lcars/`) — what claude executes in the sandbox, not where the spawner
        # wrote the file. A host path substituted here is invisible from inside bwrap.
        # The substituted values arrive SHELL-QUOTED: do not wrap the placeholders in quotes of
        # your own. They land in a `bash -c` string, and a host pod puts a real home in them.
        "exec python3 {{BRIDGE}} 2>>{{BRIDGE_LOG}}"
      ]
      # No static "env" key. `McpProvision.build_fleet_mcp_entry/5` injects exactly one variable
      # per pod, `LCARS_FLEET_MCP_SOCKET`, and MERGES it over whatever "env" the spec declares —
      # so a key added here would survive into every pod. None is: the pod's identity is the
      # socket it speaks on, and a declared identity would be forgeable.
    }
  end

  # ============================================================
  # fleet_workflow — workflow-map YAML catalogue root
  # ============================================================
  if path = System.get_env("LCARS_WORKFLOW_MAPS_ROOT") do
    config :lcars_fleet,
      workflow_workflow_maps_root: Fleet.EnvParse.path("LCARS_WORKFLOW_MAPS_ROOT", path)
  end

  # TOMBSTONE: the `LCARS_WORKSPACES_ROOT` knob (→ what would today be
  # `:lcars_fleet, :workflow_workspaces_root`, root of the pipeline scratch git workspaces) is RETIRED — it has
  # NO reader. Do not reintroduce: current workspaces are per-pod (pod_dir), not a
  # shared pipeline git scratch.

  # ============================================================
  # fleet_starfleet — Cat 5 audit log
  # ============================================================
  if path = System.get_env("LCARS_STARFLEET_AUDIT_LOG") do
    config :lcars_fleet,
      starfleet_audit_log_path: Fleet.EnvParse.path("LCARS_STARFLEET_AUDIT_LOG", path)
  end

  # Shutdown drain: real backend (aggregates the TaskQueue active work + the completion offloads and
  # activates quiescence). Outside `:test` (this file is guarded) →
  # tests keep the `NoOpDispatcher` default (hermeticity). User decision:
  # no Fleet.Dispatcher god-module, the seam IS the abstraction.
  # LA MEME VALEUR QUE `bin/fleet_v2` LIT POUR SA MARGE D'ATTENTE (BL-6-52). Un seul nombre, deux
  # lecteurs : le BEAM draine pendant ce delai, le launcher attend ce delai PLUS une marge avant de
  # conclure. Sans ca, les deux derivaient — 45 s cote BEAM, 90 s en dur cote shell.
  config :lcars_fleet,
         :starfleet_shutdown_grace_ms,
         Fleet.EnvParse.positive_ms(
           "LCARS_SHUTDOWN_GRACE_MS",
           System.get_env("LCARS_SHUTDOWN_GRACE_MS") || "45000"
         )

  config :lcars_fleet,
         :starfleet_shutdown_dispatcher,
         Fleet.Starfleet.Shutdown.AggregateDispatcher

  # CI-02 — in-flight COMPLETION offloads for the drain. Starfleet must NOT reference Pilot at compile
  # time (no boundary dep); this runtime fun crosses the boundary as a value (cf. AggregateDispatcher
  # ## Boundary). Absent in `:test` → the seam default `fn -> 0 end` (no completion Tasks to drain there).
  config :lcars_fleet,
         :starfleet_completion_inflight_fun,
         &Fleet.Pilot.StepRunConsumer.inflight_completions/0

  # The project-lifecycle domain sits BELOW the rail that drives projects, so its two card-fallback
  # sites cannot reference the incident registry at compile time. Same shape as the seam above and
  # as `:coord_backend`: the module crosses the boundary as a VALUE. Unwired, the fallback still
  # runs and warns — what is lost is the durable trace, and `Project.Incidents` says so loudly
  # rather than swallowing it.
  config :lcars_fleet,
         :project_incident_rail,
         {Fleet.Pilot.IncidentRegistry, :record_or_escalate}

  # ============================================================
  # fleet_coord — wired Fleet.Coord backend for starfleet
  # ============================================================
  config :lcars_fleet, :starfleet_coord_backend, Fleet.Coord

  if path = System.get_env("LCARS_COORD_POLICIES_PATH") do
    config :lcars_fleet,
      coord_policies_path: Fleet.EnvParse.path("LCARS_COORD_POLICIES_PATH", path)
  end

  # ============================================================
  # fleet_api — plus de port : le domaine n'a que son socket de contrôle
  # ============================================================
  # ⚠ `LCARS_API_PORT` A ÉTÉ RETIRÉE, PAS RENDUE OPTIONNELLE (2026-08-14). Ce bloc LEVAIT quand elle
  # manquait — une exigence dure pour un port que plus rien ne bind : la surface TCP de ce domaine a
  # été supprimée faute de capacité propre (états servis par l'observation, `/ws` débranché,
  # diagnostics avec un jumeau CLI, écritures déjà sur le socket ci-dessous), et personne ne
  # l'appelait. Une variable OBLIGATOIRE dont la valeur ne configure rien bloque un démarrage sans
  # rien régler.
  #
  # Il n'y a pas non plus de molette pour le chemin du socket au-delà de `LCARS_API_SOCK` : le
  # per-humain vient du HOME de celui qui lance le BEAM, pas d'un numéro qu'on devine.

  # AF_UNIX control socket for the write door (POST /api/admin/spawn, ControlRouter) —
  # off the network the pod shares. Default: ~/.lcars/run/api.sock (per-human, real
  # home never bound into the pod → unreachable). Override LCARS_API_SOCK (set by bin/fleet_v2).
  config :lcars_fleet,
    api_control_socket:
      System.get_env("LCARS_API_SOCK") ||
        Path.join([System.fetch_env!("HOME"), ".lcars", "run", "api.sock"])

  # ============================================================
  # fleet_observation — read-only observation deck, per-human SOCKET
  # ============================================================
  # Listener started in prod/dev (the hermetic `start_listener: false` of
  # test.exs is not reached here: runtime.exs is guarded out of :test).
  #
  # ⚠ `LCARS_OBSERVATION_PORT` A ETE RETIREE, PAS RENDUE OPTIONNELLE (6-072/6-098). Ce bloc LEVAIT
  # quand elle manquait — une exigence dure pour une valeur que plus rien ne bind : le deck ecoute
  # sur `/run/lcars/console/<humain>/deck.sock`. Une variable obligatoire dont la valeur ne sert a
  # rien est le pire des deux mondes : elle bloque un demarrage ET elle ne configure rien.
  #
  # Le chemin de la socket ne se declare pas ici : il se DERIVE de l'humain qui lance le BEAM
  # (`Fleet.Observation.Application.deck_socket/0`). Une molette ici permettrait de poser la socket
  # d'un humain dans le repertoire d'un autre, que le mode de ce repertoire refuserait ensuite —
  # un « deck injoignable » sans cause visible.
  config :lcars_fleet, observation_start_listener: true

  # ============================================================
  # fleet_pilot — only the forge-state-machine rail exists (config `LCARS_PILOT_STEP`). There is no
  # label-routing knob, no legacy dispatcher knob, and no fixed-repo knob: MULTI-PROJECT, the Poller
  # DISCOVERS its projects by org-membership (`list_org_repos`, WS3); repo+remote travel in the
  # `pod.completed` event. (`LCARS_PILOT_POLL_REPO` is REMOVED — it was parsed into `:poll_repo` with NO
  # runtime reader, a false ops contract: setting it did nothing. Do not reintroduce it as a dead knob.)
  # ============================================================

  if interval = System.get_env("LCARS_PILOT_POLL_INTERVAL_MS") do
    config :lcars_fleet,
      pilot_poll_interval_ms: Fleet.EnvParse.positive_ms("LCARS_PILOT_POLL_INTERVAL_MS", interval)
  end

  # Login of the SYSTEM account (owner of FORGE_TOKEN). The forge markers
  # (route / step_run / result-block) are only trusted when written by this login (a forge
  # user posting a fake one is ignored). Optional: if absent, ForgeClient derives it once
  # via `GET /user` (the token's authenticated user) and caches it. Overriding it here avoids that
  # round-trip and removes any ambiguity in deployment (shared token, mirror, etc.).
  if bot_login = System.get_env("FORGE_BOT_LOGIN") do
    config :lcars_fleet, pilot_forge_bot_login: bot_login
  end

  # Multi-forge by config (one forge per boot, chosen by env profile). The ROLE tokens
  # (`Fleet.Credentials.RoleToken`) are read from `<role_tokens_dir>/<role>.gitea_token`;
  # default `/home/private` (primary forge). To target a 2nd forge (e.g. backup :3000), a
  # distinct env profile sets FORGE_BASE_URL + FORGE_TOKEN_FILE + this dir → a token set
  # ISOLATED per forge (no clobber). The system token is already per-forge via
  # FORGE_TOKEN_FILE. Absent = default (strict backward-compat). No SIMULTANEOUS multi-forge
  # (per-project registry/routing): out-of-scope, that would be another model.
  if role_tokens_dir = System.get_env("FORGE_ROLE_TOKENS_DIR") do
    config :lcars_fleet,
      credentials_role_tokens_dir: Fleet.EnvParse.path("FORGE_ROLE_TOKENS_DIR", role_tokens_dir)
  end

  # ============================================================
  # Runtime STEP-MODE (the forge = the state machine) + push auth
  # ============================================================
  # OFF by default. `LCARS_PILOT_STEP=true` starts Poller(step) + StepRunConsumer
  # (cf. Fleet.Pilot.Application.step_children!). F-037: requires ONLY FORGE_BASE_URL — the
  # single fail-loud guard of the step boot (org-membership project discovery + per-step-run push).
  # No fixed-repo knob: the Poller discovers by org-membership, not a configured repo.
  if Fleet.EnvParse.bool("LCARS_PILOT_STEP", System.get_env("LCARS_PILOT_STEP"), false) do
    config :lcars_fleet, pilot_step_dispatch?: true
  end

  # ============================================================
  # fleet_pilot — `max_fan`: workflow_runs ONE project holds in flight (`fleet_v2 --max-fan N`).
  # Posted only when the operator typed it: an unconditional put would clobber a value set in
  # `config.exs` with the reader's own default, and the two would then disagree about which one is
  # the default (F6).
  # ============================================================
  # The DOOR validates (the flag parser refuses a non-integer and anything outside 1..15 rather
  # than clamping) and this parse is the belt behind it, for the env set by hand. STRICT: a
  # `max_fan` that silently falls back would run a fleet at a fan the operator never asked for,
  # and the symptom -- tickets waiting -- looks like a busy fleet, not like a misconfiguration.
  if raw = System.get_env("LCARS_MAX_FAN") do
    config :lcars_fleet,
      pilot_max_fan:
        Fleet.EnvParse.bounded(
          "LCARS_MAX_FAN",
          raw,
          1,
          Fleet.Pilot.Poller.Admission.max_fan_ceiling()
        )
  end

  # Anti-tie spacing of the forge writes (Fleet.Pilot.WriteSpacing — seal, onboard,
  # branch birth → content push). Reader default: 2000 ms. Gitea's own notification-queue
  # INSERTION lag (~1-2 s measured) can visually re-glue what the runtime spaced — raise
  # above the lag (e.g. 5000) for a strictly-readable feed. This line is the knob's ONLY
  # deployment surface: without it, an operator RPC was the sole way to set it, and it
  # evaporated at every reboot.
  if ms = System.get_env("LCARS_FORGE_WRITE_SPACING_MS") do
    config :lcars_fleet,
      pilot_forge_write_spacing_ms: Fleet.EnvParse.positive_ms("LCARS_FORGE_WRITE_SPACING_MS", ms)
  end

  # DR-018 degraded admission (the E-02 knob, read by MCP delegation at create_project):
  # accept an UNVERIFIABLE `humans` team-check (403 on the team API — the deployment's
  # system token is deliberately a plain org member). The runtime still logs LOUD on every
  # degraded admission. Default false (fail-closed). This is THE deployment surface the
  # knob never had — the boot ritual used to re-pose it by RPC after every restart.
  config :lcars_fleet,
    pilot_allow_unverifiable_human_team?:
      Fleet.EnvParse.bool(
        "LCARS_ALLOW_UNVERIFIABLE_HUMAN_TEAM",
        System.get_env("LCARS_ALLOW_UNVERIFIABLE_HUMAN_TEAM"),
        false
      )

  # No label-routing knob exists. Routing lives in the
  # scoped labels `wfmap/*`+`stage/*` (engraved by `post_route`; delegation workflow_map, default brief-gate). type:* = display.

  # No `LCARS_HOP_REMOTE` — the push remote is not a fixed URL (incompatible with multi-project);
  # it is PER-STEP-RUN, derived from the project's `repo_path` and embedded in the `pod.completed` event (cf.
  # `Fleet.Spawner.Pod.pod_completed_payload` + `Fleet.Pilot.StepRunConsumer.step_run_state/2`). Push auth
  # (`Fleet.Credentials.ForgeAuth.git_env` → token via env, never in the URL).

  # Runtime push auth (`Fleet.Credentials.ForgeAuth.git_env` → extraheader via env, token
  # OUTSIDE argv AND OUTSIDE .git/config). System token (lcars-system, write:repository).
  # FORGE_PUSH_TOKEN takes precedence over FORGE_TOKEN (the push requires write:repository, ≠ the read poller token).
  #
  # ⚠ THE TOKEN LIVES IN THE APPLICATION ENV, IN CLEAR, FOR THE WHOLE LIFE OF THE NODE. That is a
  # DECISION, not an oversight: `ForgeAuth` reads it from there on every auth-required git op, and
  # a vault would move the secret without removing the moment it is in memory. It is written here
  # because a secret whose exposure is undocumented gets re-exposed by the next well-meaning patch.
  #
  # WHAT MAKES IT ACCEPTABLE IS A PROPERTY OF THE SURFACE, AND THAT PROPERTY MUST BE PRESERVED:
  # nothing in the runtime reads the application env WHOLESALE, and the pod-facing MCP surface is a
  # closed list of business verbs — no pod can ask for configuration. Adding a config-dump door
  # (an "/api/config" route, a doctor that prints the env, a crash reporter that inspects it)
  # publishes this token, and the door will not look like a credentials change when it is written.
  # Never `inspect` this value: `ForgeAuth` says the same at its own site, for the same reason.
  forge_base = System.get_env("FORGE_BASE_URL")

  # The push token must come from the SAME source as the poller token: var (FORGE_PUSH_TOKEN / FORGE_TOKEN)
  # THEN the FILE (FORGE_TOKEN_FILE, default ~/.gitea_token). Without this file fallback, a deployment
  # that only sets the file (the nominal case) would have an auth-less push → "could not read Username"
  # (the poller would read the file while the push reads only the var).
  default_token_file =
    case System.user_home() do
      home when is_binary(home) -> Path.join(home, ".gitea_token")
      _ -> nil
    end

  forge_push_token =
    System.get_env("FORGE_PUSH_TOKEN") || System.get_env("FORGE_TOKEN") ||
      case System.get_env("FORGE_TOKEN_FILE") || default_token_file do
        path when is_binary(path) ->
          case File.read(path) do
            {:ok, t} -> String.trim(t)
            _ -> nil
          end

        _ ->
          nil
      end

  if is_binary(forge_base) and is_binary(forge_push_token) and forge_push_token != "" do
    config :lcars_fleet, :credentials_forge_auth, %{
      url_prefix: forge_base,
      token: forge_push_token
    }
  end

  # NB catalogue trees: covered by `LCARS_CATALOGUE_ROOT` (coarse, all of them) and the three fine
  # keys above — `LCARS_CAPPROFILES_ROOT`, `LCARS_WORKFLOW_MAPS_ROOT`, `LCARS_COORD_POLICIES_PATH`.
  # No duplicated knob here (one source per config).

  # (No `LCARS_POD_HUMAN` knob: the human = the runtime process user, derived in-code, never
  #  a config. Cf. pod.ex `runtime_user`/`runtime_home`.)

  # task-queue state (default home-relative `~/.lcars/task-queue/state.json`; unresolvable HOME =
  # deliberate fail-loud, raise — cf. task_queue/store.ex `default_path/0`; no fallback).
  if path = System.get_env("LCARS_STATE_PATH") do
    config :lcars_fleet, task_queue_state_path: Fleet.EnvParse.path("LCARS_STATE_PATH", path)
  end

  # Pod FS state (session_id/phase, recovery). Default `~/.lcars/state` (fleet under the human
  # — cf. pod.ex `default_state_fs_root`). Explicit override for a non-standard deployment;
  # otherwise the state follows the home of the human launching the fleet.
  if path = System.get_env("LCARS_STATE_FS_ROOT") do
    config :lcars_fleet, spawner_state_fs_root: Fleet.EnvParse.path("LCARS_STATE_FS_ROOT", path)
  end

  # 6-127 — Journal des completions DUES (`Fleet.Pilot.CompletionOutbox`). Défaut
  # `~/.lcars/completion-outbox`, même logique que l'état des pods juste au-dessus : il suit le home
  # de l'humain qui lance la fleet. Une entrée est un résultat d'agent déjà produit dont la trace
  # forge est incomplète — le déplacer, c'est déplacer ce qui sera rejoué au prochain démarrage.
  if path = System.get_env("LCARS_COMPLETION_OUTBOX_ROOT") do
    config :lcars_fleet,
      pilot_completion_outbox_root: Fleet.EnvParse.path("LCARS_COMPLETION_OUTBOX_ROOT", path)
  end

  # Pod launchers (N0/N1): absolute path read by the spawner (default `/usr/local/bin`, pod.ex). The
  # `fleet_v2` launcher sets them from `$INSTALL_DIR/bin` (everything under the install, nothing
  # scattered). The parent dir is bind-mounted RO in the sandbox (pod.ex `system_mounts`,
  # derived from `claude_launch_path`). An install param → a future rename touches no code.
  if path = System.get_env("LCARS_BWRAP_LAUNCH_PATH"),
    do:
      config(:lcars_fleet,
        spawner_bwrap_launch_path: Fleet.EnvParse.path("LCARS_BWRAP_LAUNCH_PATH", path)
      )

  if path = System.get_env("LCARS_HOST_LAUNCH_PATH"),
    do:
      config(:lcars_fleet,
        spawner_host_launch_path: Fleet.EnvParse.path("LCARS_HOST_LAUNCH_PATH", path)
      )

  if path = System.get_env("LCARS_CLAUDE_LAUNCH_PATH"),
    do:
      config(:lcars_fleet,
        spawner_claude_launch_path: Fleet.EnvParse.path("LCARS_CLAUDE_LAUNCH_PATH", path)
      )

  # Seed store (pod round-1 — a resume optimization, NEVER required; empty = self-populating, the
  # pod spawns fresh). Env OVERRIDE only, same shape as every other knob in this file: the key is
  # posted when the operator typed the variable, never otherwise. `SeedStore.root/0` holds the ONE
  # definition of this path (`Fleet.Layout.state_dir()` + `seeds`).
  #
  # This block used to post an unconditional default — a SECOND definition, reached only when HOME
  # is unresolvable, and disagreeing with the code's on exactly that case: it fabricated
  # `/var/lib/lcars/.lcars/seeds`, a path no other component targets, where `Layout` raises. Two
  # answers to one question, the divergence hidden in the case nobody exercises.
  #
  # A fabricated path is worse than a refusal here, and the repo says so wherever a home is derived
  # (`Fleet.Layout`, `IncidentRegistry`, `PodTmux`): an unresolvable HOME is a broken runtime, and
  # the answer is fail-loud, never an invented directory. Being optional buys the seed store the
  # right to fail without taking the fleet down — it does not buy it a private idea of where the
  # human's state lives.
  if path = System.get_env("LCARS_SEED_STORE_ROOT") do
    config :lcars_fleet,
      spawner_seed_store_root: Fleet.EnvParse.path("LCARS_SEED_STORE_ROOT", path)
  end

  # Pod onboarding kick (the `engage` nudge → claude calls get_work_item). The default window
  # (first 2s + 12×2.5s ≈ 32s) is too short against the claude cold-start in bwrap on a deployed
  # service (238MB binary, cold caches) → kick abandoned before the REPL is ready → pod without a
  # brief. Widen in deploy. Integers via env.
  if v = System.get_env("LCARS_KICK_FIRST_DELAY_MS"),
    do:
      config(:lcars_fleet,
        spawner_kick_first_delay_ms: Fleet.EnvParse.positive_ms("LCARS_KICK_FIRST_DELAY_MS", v)
      )

  if v = System.get_env("LCARS_KICK_RETRY_MS"),
    do:
      config(:lcars_fleet,
        spawner_kick_retry_ms: Fleet.EnvParse.positive_ms("LCARS_KICK_RETRY_MS", v)
      )

  if v = System.get_env("LCARS_KICK_MAX_ATTEMPTS"),
    do:
      config(:lcars_fleet,
        spawner_kick_max_attempts: Fleet.EnvParse.count("LCARS_KICK_MAX_ATTEMPTS", v)
      )
end
