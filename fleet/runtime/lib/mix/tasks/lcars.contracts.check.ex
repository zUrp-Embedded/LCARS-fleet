defmodule Mix.Tasks.Lcars.Contracts.Check do
  # Z4 — Mix task classified into the boundary of its subject (Fleet.Application).
  use Boundary, classify_to: Fleet.Application

  @shortdoc "Verifies inter-module contracts at load (refuses the build if a contract is reopened)"

  @moduledoc """
  Runtime Contract Checker — validates inter-module contracts BEFORE
  execution, and turns each gap into an explicit refusal (exit≠0)
  rather than a silent runtime timeout/bug.

  Each check guards a class of drift already encountered: RED as long as the
  fix is not landed, GREEN once it is. Wired in as a permanent guardrail
  (`contracts.check` exit 0 at boot/CI fail-loud, and `mix release` refuses to
  build if a check is red), it promotes each invariant from a documentary
  closure to a mechanical closure: an agent who re-derives breaks the build.

  ## Usage

      mix lcars.contracts.check          # YAML report + exit 0/1
      mix lcars.contracts.check --quiet  # exit code only

  ## Output

  YAML `status + checks[] + evidence (file:line)`. `status: fail` if at
  least one check is `fail`. Every check is IMPLEMENTED and grounded in the real
  code (grep/introspection) — there is no "pending/declared-only" tier: a contract
  either has an executable check or it is not listed.

  **Last revised**: 2026-07-21
  """

  use Mix.Task

  @recursive false

  # Each check: %{id, remediation, status: :pass|:fail, evidence: [..], note}
  # (The `@pending_checks` machinery — a list that was ALWAYS empty, a counter that always
  # printed "0 pending" — was inert ceremony, removed acte4 A-16. Reintroduce a pending tier
  # only the day a real declared-but-not-yet-executable check exists.)

  @impl Mix.Task
  def run(args) do
    quiet? = "--quiet" in args
    Mix.Task.run("compile")

    {overall, checks} = run_checks()

    unless quiet?, do: IO.puts(render_yaml(overall, checks))

    fails = Enum.count(checks, &(&1.status == :fail))

    Mix.shell().info(
      "contracts.check: #{overall} — #{fails} fail, " <>
        "#{Enum.count(checks, &(&1.status == :pass))} pass"
    )

    if overall == :fail, do: exit({:shutdown, 1})
  end

  @doc """
  Runs all checks and returns `{overall, checks}` WITHOUT printing or `exit`.

  Reusable form of the check logic: called by `run/1` (CLI: print +
  exit) AND by the `mix release` step (`mix.exs` `verrou_contracts/1`: refuses to
  build the release if red). Since the sources are present at build (release built
  from the project), the grep/introspection checks run; a red check →
  release refused = the mechanical realization of "the boot refuses to come up if a
  contract has been reopened" (make the forbidden state impossible upstream, not catch it after the fact).

  Assumes the code is already compiled (the caller compiles: `run/1` via `Mix.Task.run`,
  the release step after the compile phase).
  """
  @spec run_checks() :: {:pass | :fail, [map()]}
  def run_checks do
    root = project_root()

    checks =
      [
        check_event_consumers_canon(root),
        check_pipeline_v25_normalized(root),
        check_events_handlers_exist(root),
        check_coord_backend_wired(root),
        check_capprofile_lifetime_scope_path(root),
        check_capprofile_modop_incompatible_path(root),
        check_launch_backend_containment(root),
        check_mcp_required_real_backend(root),
        check_spawn_has_brief(root),
        check_skills_declared_present(root),
        check_events_registry_keys_aligned(root),
        check_no_cowboy_bypass(root),
        # ── Remediation rails ──
        check_result_deadline_cancelled(root),
        check_spawn_gates_wired(root),
        check_gatekeeper_not_a_step(root),
        check_verdict_envelope_unwrapped(root),
        check_no_root_runtime_guard(root),
        # ── Topology lock ──
        check_boot_order_f8(root),
        # ── Authority locks (Z7 — one fact = one source, cross-language) ──
        check_roles_provisioning_in_catalogue(root),
        check_mcp_wire_inputschema(root)
        # NB no `pipeline.bounded_retry_system_side` rail here: bounded rework lives on the
        # forge rail (`max_rework_rounds`, StepRunConsumer), not an in-memory retry loop —
        # nothing separate to contract.
      ]

    overall = if Enum.any?(checks, &(&1.status == :fail)), do: :fail, else: :pass

    {overall, checks}
  end

  # ── Implemented checks ───────────────────────────────────────────────

  # Event consumers must match `%Fleet.Event{}`, never the legacy tuple
  # `{atom, %{"event_type" => ...}}` — a consumer left on the tuple is
  # dead against the canonical struct (it matches nothing anymore) and the drift is silent.
  # This check measures the real CODE of the targets below and flags any residual
  # `"event_type" =>` read.
  # 9th instance of the B family (residue_check), migrated in the shared-combinator factorization. The `confirm` = the
  # pattern itself post-strip: an `"event_type" =>` mention in a COMMENT (doc of the legacy-tuple
  # removal) does not count as a violation (otherwise the gate would flag its own documentation).
  # NB `executor.ex`/`task_monitor.ex` are no longer targets (rails/apps removed).
  # SCOPE: a TARGETED residue check — it scans ONLY api/ws.ex (the `files:` below), the WS boundary
  # consumer. NOT a global consumer sweep: the id's "canon" is the canonical `%Fleet.Event{}` SHAPE,
  # not exhaustive coverage. A legacy "event_type" tuple reappearing in a Pilot/Starfleet/Observation
  # consumer is NOT caught here — those files are not scanned. Broadening the scan is a separate change;
  # this check's contract is the single file it lists.
  defp check_event_consumers_canon(root) do
    residue_check(root, %{
      id: "event.consumers.canon",
      remediation: "migrate the flagged consumer(s) off the legacy `event_type` tuple to `%Fleet.Event{}` matching",
      files: ["lib/fleet/api/ws.ex"],
      pattern: ~r/"event_type"\s*=>/,
      confirm: ~r/"event_type"\s*=>/,
      note: "the WS boundary consumer (api/ws.ex) still on the legacy \"event_type\" tuple"
    })
  end

  # The Loader must unwrap the v2.5 ENVELOPE (kind/metadata/spec.steps) into the single internal
  # FLAT form. There is NO v1: a flat/enveloppe-less YAML fails the v2.5 schema before `normalize`.
  # « v1/v2.5 » = external envelope vs internal flat (same version, two shapes), NOT two versions.
  # Without the unwrap, a consumer reads `workflow_map["steps"]=nil` (steps live under spec.steps).
  defp check_pipeline_v25_normalized(root) do
    rel = "lib/fleet/workflow/loader.ex"
    loader = Path.join(root, rel)

    # Anti-hollow-green: matching `~r/normalize/i` over the WHOLE source would turn the rail green as soon as a
    # mere COMMENT contains "normalize", even without the code. So we match the real CODE CLAUSE
    # that unwraps `spec.steps` (the v2.5 normalization) AND its call, STRIPPING the comment from each
    # line (a commented-out `# defp normalize(...)` does not count).
    unwrap_clause? =
      loader
      |> grep_lines(~r/defp normalize\(%\{"spec"/)
      |> Enum.any?(fn {_l, line} -> Regex.match?(~r/defp normalize/, strip_comment(line)) end)

    called? =
      loader
      |> grep_lines(~r/normalize\(yaml\)/)
      |> Enum.any?(fn {_l, line} -> Regex.match?(~r/normalize\(yaml\)/, strip_comment(line)) end)

    ok? = unwrap_clause? and called?

    %{
      id: "pipeline.v25.normalized",
      remediation: "add the v2.5 `normalize` unwrap clause for spec.steps so a workflow_map consumer does not read steps=nil",
      status: if(ok?, do: :pass, else: :fail),
      evidence:
        cond do
          not unwrap_clause? ->
            [
              "#{rel}: `defp normalize(%{\"spec\" => %{\"steps\" => ...}})` clause (v2.5 unwrap) missing → a workflow_map consumer reads steps=nil"
            ]

          not called? ->
            ["#{rel}: `normalize(yaml)` never called at load → v2.5 envelope not unwrapped"]

          true ->
            []
        end,
      note:
        "Loader UNWRAPS spec.steps via the v2.5 CODE CLAUSE (`defp normalize(%{\"spec\"…})`) AND calls it at load — matches the code, not a comment (hardened anti-hollow-green)"
    }
  end

  # Every handler referenced in events.yaml must exist, otherwise the route is a
  # phantom handler tolerated silently.
  defp check_events_handlers_exist(root) do
    yaml = Path.join(root, "priv/event_router/events.yaml")

    missing =
      case YamlElixir.read_from_file(yaml) do
        {:ok, %{"events" => events}} when is_map(events) ->
          events
          |> Map.values()
          |> List.flatten()
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()
          |> Enum.reject(&module_exists?/1)

        _ ->
          # HOLLOW-GREEN GUARD (R0-EVT-012): an ABSENT/invalid events.yaml used to yield `[]` → `:pass`
          # — the "every handler exists" check passing precisely when the registry it reads is GONE. An
          # unreadable registry is a broken deploy → FAIL, not a silent green.
          [
            "events.yaml absent or invalid at #{yaml} — handlers unverifiable (hollow-green guard)"
          ]
      end

    %{
      id: "events.handlers.exist",
      remediation: "remove the phantom handler ref(s) from events.yaml, or add the missing subscriber(s)",
      status: if(missing == [], do: :pass, else: :fail),
      evidence: Enum.map(missing, &"events.yaml → #{&1} (missing)"),
      note: "phantom handlers referenced in events.yaml (dispatch table vs direct subscribers)"
    }
  end

  # Invariant: the LLM gate (soft + terminal non-adjudicable) is judged by the
  # **gatekeeper** on the workflow side; `coord` carries no gate spawn, and the
  # `NotWiredYet` placeholder (which would silently break the soft gates) must
  # not reappear in the coord gate-path. So we check the REAL code,
  # not trusting a comment:
  # (a) no residual `HookSpawner.NotWiredYet` in the coord lib, (b) `Gates`
  # is pure — no `coord_backend()`/`CoordBackend` delegation (the dead
  # seam must not come back).
  defp check_coord_backend_wired(root) do
    # `soft_gate.ex` does not exist (gates consolidated onto the gatekeeper). Since
    # `grep_lines/2` returns `[]` on an absent file, grepping a dead file
    # would ALWAYS pass empty = hollow-green (the failure class this checker exists
    # to prevent). So we grep the WHOLE coord lib (glob of REAL files, not a
    # dead file) for the `NotWiredYet` placeholder that must not reappear
    # in the coord gate-path.
    notwired =
      Path.wildcard(Path.join(root, "lib/fleet/coord/**/*.ex"))
      |> Enum.flat_map(fn file ->
        file
        |> grep_lines(~r/NotWiredYet/)
        |> Enum.map(fn {ln, _} -> "#{Path.relative_to(file, root)}:#{ln}" end)
      end)

    gates_coord_dep =
      Path.join(root, "lib/fleet/workflow/gates.ex")
      |> grep_lines(~r/coord_backend|CoordBackend/)
      |> Enum.filter(fn {_ln, line} ->
        Regex.match?(~r/coord_backend|CoordBackend/, strip_comment(line))
      end)
      |> Enum.map(fn {ln, _} -> "lib/fleet/workflow/gates.ex:#{ln}" end)

    evidence = notwired ++ gates_coord_dep

    %{
      id: "coord.backend.wired_or_pure",
      remediation: "keep the LLM gate on the gatekeeper (pure Gates) — no residual NotWiredYet nor coord delegation",
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
      note:
        "LLM gate consolidated on the gatekeeper (pure Gates); no residual NotWiredYet nor coord delegation"
    }
  end

  # `compose_claude_md/3` must read `spec.invocation.lifetime_scope` (the canonical
  # v2.5 schema), not `spec.lifetime_scope` (pre-v2.5 form) — otherwise the pod's CLAUDE.md
  # always shows "unknown". The twin `check_lifetime_scope/1` (cap_profile.ex)
  # already reads the right path.
  # The pattern covers get_in (list form `spec, ["lifetime_scope"]`) AND Map.get
  # (string form `spec, "lifetime_scope"`) — future-proof against a regression that
  # would reintroduce the wrong path under another form.
  defp check_capprofile_lifetime_scope_path(root) do
    residue_check(root, %{
      id: "capprofile.lifetime_scope_path",
      remediation: "read spec.invocation.lifetime_scope (v2.5), not the pre-v2.5 spec.lifetime_scope, in compose_claude_md",
      files: ["lib/fleet/sp_builder.ex"],
      pattern: ~r/cap_profile\.spec,\s*(\["lifetime_scope"\]|"lifetime_scope")/,
      note:
        "compose_claude_md reads spec.lifetime_scope (pre-v2.5) instead of spec.invocation.lifetime_scope"
    })
  end

  # `check_modop_incompatible/1` must read `spec.modop_set.incompatible` (v2.5
  # schema) + compare against the active modops (`default` ++ `optional`), not
  # `spec.modop_incompatible` (nonexistent key) nor `spec.modop_set` treated as
  # a list → otherwise the invariant never fires. Post-strip confirmation looser
  # than the grep: any CODE mention of `modop_incompatible` on a
  # `Map.get(spec, …)` line counts, even reformatted.
  defp check_capprofile_modop_incompatible_path(root) do
    residue_check(root, %{
      id: "capprofile.modop_incompatible_path",
      remediation: "keep the modop-incompatibility guard (check_modop_incompatible) in cap_profile.ex / invariants.ex",
      # The guarded function (check_modop_incompatible) was EXTRACTED to invariants.ex — the rail
      # watches BOTH (the wrong path can come back in either one).
      files: [
        "lib/fleet/cap_profile.ex",
        "lib/fleet/cap_profile/invariants.ex"
      ],
      pattern: ~r/Map\.get\(spec,\s*"modop_incompatible"/,
      confirm: ~r/modop_incompatible/,
      note:
        "check_modop_incompatible reads spec.modop_incompatible (nonexistent) instead of spec.modop_set.incompatible"
    })
  end

  # `TmuxBackend` (claude --remote-control OUTSIDE bwrap, whose control-path is broken) does not exist.
  # This check guards that removal: red if it reappears OR if runtime.exs re-references TmuxBackend.
  # NB this is NOT about forbidding all host-launch — `containment: none` is served by
  # `bin/host_launch.sh` (the PROVEN tmux-holder mechanism of bwrap_launch, selected by `do_launch`
  # via `launcher_path`), not by the bare remote-control of the former TmuxBackend. The rail forbids
  # the resurrection of the broken MECHANISM, not the host path.
  # NB the runtime.exs side matches the RAW source (no strip_comment):
  # even a comment mention of TmuxBackend in the runtime config is
  # a resurrection signal to flag.
  defp check_launch_backend_containment(root) do
    rt = "config/runtime.exs"
    tb = "lib/fleet/spawner/launch_backend/tmux_backend.ex"

    evidence_check(
      %{
        id: "launch.backend_containment_coherent",
        remediation: "keep host containment:none on host_launch.sh; do not reintroduce TmuxBackend (bare remote-control)",
        note:
          "TmuxBackend (bare remote-control, broken control-path) removed; must not reappear. The host containment:none path = host_launch.sh (proven tmux-holder), not TmuxBackend (LAUNCH-Q)"
      },
      [
        {not File.exists?(Path.join(root, tb)),
         "#{tb}: TmuxBackend removed (F103) — the module must not reappear"},
        {not Regex.match?(~r/LaunchBackend\.TmuxBackend/, File.read!(Path.join(root, rt))),
         "#{rt}: runtime must no longer reference TmuxBackend (out-of-bwrap backend removed)"}
      ]
    )
  end

  # A REAL backend without `mcp_server_spec` must be refused (fail-loud) — a real pod
  # speaks MCP, without MCP it starts broken (silent timeout). MCP provisioning was
  # extracted from pod.ex into its own module; this check guards the guard at TWO levels,
  # both required (otherwise fail):
  #   level 1 (wiring) — pod.ex CALLS `McpProvision.maybe_provision_mcp_config(` in
  #     its provisioning with-chain (without this call, the guard, even present in
  #     the dedicated module, would never run on the spawn path);
  #   level 2 (real guard) — `mcp_provision.ex` carries the fail-loud, marker being the error
  #     `:mcp_server_spec_required` in the return TUPLE `{:error, {:mcp_server_spec_required, …}}`.
  # Red if either of the two is missing; clear evidence pointing at the offending file.
  #
  # ⚠ Hardened anti-hollow-green (level 2): the moduledoc of `mcp_provision.ex` DOCUMENTS the same
  # tuple `{:error, {:mcp_server_spec_required, backend}}` (as inline-code). Grepping the bare atom
  # would leave the check GREEN even if the real code clause were removed (the doc keeping the
  # token present) — exactly the hollow-green this checker exists to block. So we require
  # the token on a CODE LINE that IS the error tuple (`^\s*{:error,` after strip_comment);
  # the doc line (prose prefixed by a backtick, not `{:error,`) does not count. Unwiring the
  # real clause turns it RED again, whatever the doc says.
  defp check_mcp_required_real_backend(root) do
    pod = "lib/fleet/spawner/pod.ex"
    mcp = "lib/fleet/spawner/pod/mcp_provision.ex"

    evidence_check(
      %{
        id: "mcp.required_for_real_backend",
        remediation: "keep both MCP levels: pod.ex maybe_provision_mcp_config AND mcp_provision.ex fail-loud :mcp_server_spec_required for a real backend without a spec",
        note:
          "pod.ex wires McpProvision.maybe_provision_mcp_config (level 1) AND mcp_provision.ex refuses fail-loud :mcp_server_spec_required a real backend without a spec (level 2) — both required"
      },
      [
        {code_match?(root, pod, ~r/McpProvision\.maybe_provision_mcp_config\(/),
         "#{pod}: McpProvision.maybe_provision_mcp_config not called (MCP provisioning unwired from the spawn path)"},
        # CONJUNCTIVE confirmation (both regexes on the stripped line): the token
        # must live on a line that IS the error tuple — cf. the hardened
        # anti-hollow-green above (the moduledoc carries the same token in prose).
        {code_match?(root, mcp, ~r/:mcp_server_spec_required/, [
           ~r/:mcp_server_spec_required/,
           ~r/^\s*\{:error,/
         ]), "#{mcp}: no fail-loud :mcp_server_spec_required (real guard missing)"}
      ]
    )
  end

  # `Fleet.Spawner.spawn_pod/3` must enforce the one-shot-brief REAL invariant, not merely NAME it (DR-030): the
  # earlier marker-only `:brief_required` presence passed on the @doc prose alone. We now assert the
  # EXECUTABLE clauses (doc blocks excluded by `code_match?`, BND-111):
  #   1. one-shot without brief → refused: the executable tuple `{:error, :brief_required}` on its line.
  #   2. a cap-profile WITHOUT `lifetime_scope` is not a spawnable state (DR-019): spawn_pod gates on
  #      `CapProfile.fetch_lifetime_scope/1` and refuses `{:error, :cap_profile_no_lifetime_scope}` — so
  #      "absent lifetime_scope" is not silently exempted from the brief rule (the hole DR-019/BND-099 closed).
  # Unwiring any clause turns this RED, whatever the docs say.
  defp check_spawn_has_brief(root) do
    spawner = "lib/fleet/spawner.ex"

    evidence_check(
      %{
        id: "spawn.has_brief",
        remediation: "keep spawn_pod guards: {:error, :brief_required} for a one-shot without brief AND {:error, :cap_profile_no_lifetime_scope} for a missing lifetime_scope",
        note:
          "spawn_pod refuses a one-shot pod without a brief ({:error, :brief_required}) AND refuses a cap-profile with no lifetime_scope (DR-019: fetch_lifetime_scope → {:error, :cap_profile_no_lifetime_scope}) — the real one-shot-brief invariant, not a marker"
      },
      [
        {code_match?(root, spawner, ~r/:brief_required/, [
           ~r/:brief_required/,
           ~r/^\s*\{:error, :brief_required\}/
         ]), "#{spawner}: no executable {:error, :brief_required} guard at the spawn_pod boundary"},
        {code_match?(root, spawner, ~r/fetch_lifetime_scope/),
         "#{spawner}: spawn_pod does not gate on CapProfile.fetch_lifetime_scope (DR-019 source-fix unwired)"},
        {code_match?(root, spawner, ~r/:cap_profile_no_lifetime_scope/, [
           ~r/:cap_profile_no_lifetime_scope/,
           ~r/^\s*\{:error, :cap_profile_no_lifetime_scope\}/
         ]), "#{spawner}: no executable refusal of a cap-profile without lifetime_scope (DR-019)"}
      ]
    )
  end

  # `Fleet.SPBuilder.filter_skills/2` must fail (fail-loud) if a whitelisted PLAIN skill is absent from
  # disk — otherwise a silent filtering would let a pod claim a nonexistent skill. BND-111: confirm the
  # EXECUTABLE tuple `{:error, {:skills_missing, ...}}` on its line (the @doc/@comment name the same tuple
  # in prose; `code_match?` excludes doc blocks, and the tuple-shape confirm excludes an inline mention).
  # Red if absent.
  defp check_skills_declared_present(root) do
    presence_check(root, %{
      id: "skills.declared_present",
      remediation: "make filter_skills fail-loud {:error, {:skills_missing, _}} on a missing plain skill",
      file: "lib/fleet/sp_builder.ex",
      pattern: ~r/:skills_missing/,
      confirm: [~r/:skills_missing/, ~r/\{:error, \{:skills_missing,/],
      missing: "filter_skills silently filters out missing skills (no executable {:error, {:skills_missing,} fail-loud)",
      note: "filter_skills must fail-loud {:error, {:skills_missing, _}} on a missing plain skill"
    })
  end

  # The events.yaml key IS the event `type` (the `source` is a separate field,
  # validated by `Fleet.Event.valid_source?/1`); the registry is keyed by type, there
  # is no dispatch table keyed otherwise. Invariant guarded here: every **consumed**
  # type (`handle_info(%Fleet.Event{type: :X})`, moduledoc examples included)
  # must be a registry key — otherwise the consumer is dead (it waits for a type
  # that cannot be broadcast without `UnregisteredError`). The emitters, for their part, are
  # covered by the fail-loud validation of the broadcast at runtime (an unregistered type
  # crashes its emitter), so this check covers only the consumption side.
  defp check_events_registry_keys_aligned(root) do
    registry = registry_event_keys(root)

    consumed =
      Path.wildcard(Path.join(root, "lib/**/*.ex"))
      |> Enum.flat_map(&consumed_event_types/1)
      |> Enum.uniq()

    unregistered = Enum.reject(consumed, &MapSet.member?(registry, &1))

    %{
      id: "events.registry.keys_aligned",
      remediation: "add the consumed type(s) to events.yaml (every handle_info %Fleet.Event{type:} must be a registry key)",
      status: if(unregistered == [], do: :pass, else: :fail),
      evidence: Enum.map(unregistered, &"consumed type outside registry: #{&1}"),
      note: "every consumed type (handle_info %Fleet.Event{type:}) must be an events.yaml key"
    }
  end

  defp registry_event_keys(root) do
    yaml = Path.join(root, "priv/event_router/events.yaml")

    case YamlElixir.read_from_file(yaml) do
      {:ok, %{"events" => events}} when is_map(events) -> MapSet.new(Map.keys(events))
      _ -> MapSet.new()
    end
  end

  # `[^}]*?` allows fields BEFORE `type:` (e.g. `%Fleet.Event{source: :X,
  # type: :Y}`) and traverses multi-line structs (the negation of `}` matches
  # newlines) → captures type-first AND source-first consumers.
  # Known limit: generic `%Fleet.Event{}` consumers + `case type do`
  # (no type literal in the struct) are not covered.
  defp consumed_event_types(file) do
    case File.read(file) do
      {:ok, content} ->
        ~r/%Fleet\.Event\{[^}]*?type:\s*:"?([a-z_][a-z0-9_.]*)"?/
        |> Regex.scan(content)
        |> Enum.map(fn [_, type] -> type end)

      _ ->
        []
    end
  end

  # Every HTTP listener child-spec `{Plug.Cowboy, …}` must be built by the SINGLE authority
  # `Fleet.EventRouter.Listener.cowboy_child/1` — that is where the loopback `:ip` bind is set BY
  # CONSTRUCTION (via BindAddress). A surface that builds its own `{Plug.Cowboy, …}` elsewhere would
  # bypass the loopback-by-default guarantee (network exposure by accident). Red if a `{Plug.Cowboy,`
  # child-spec appears on a code line outside listener.ex. NB the pattern matches the child-spec tuple
  # `{Plug.Cowboy,` (comma), NOT `Plug.Cowboy.Handler` (a dispatch clause) nor comments (strip_comment).
  # ⚠ This checker file is scanned too: its own evidence/note prose must AVOID the literal `{Plug.Cowboy,`
  # token (it would self-flag — strip_comment removes it from comments, not from string bodies).
  defp check_no_cowboy_bypass(root) do
    builder = "lib/fleet/event_router/listener.ex"

    bypass =
      Path.wildcard(Path.join(root, "lib/**/*.ex"))
      |> Enum.reject(&(Path.relative_to(&1, root) == builder))
      |> Enum.flat_map(fn file ->
        file
        |> grep_lines(~r/\{Plug\.Cowboy,/)
        |> Enum.filter(fn {_ln, line} ->
          Regex.match?(~r/\{Plug\.Cowboy,/, strip_comment(line))
        end)
        |> Enum.map(fn {ln, _} -> "#{Path.relative_to(file, root)}:#{ln}" end)
      end)

    %{
      id: "listener.no_cowboy_bypass",
      remediation: "route the listener through Fleet.EventRouter.Listener.cowboy_child/1",
      status: if(bypass == [], do: :pass, else: :fail),
      evidence:
        Enum.map(
          bypass,
          &"#{&1} : a Plug.Cowboy listener child-spec is built outside listener.ex — loopback-by-construction bypassed"
        ),
      note:
        "the Plug.Cowboy listener child-spec has a single builder (Listener.cowboy_child/1, loopback :ip by construction); no surface builds one of its own"
    }
  end

  # ── Remediation rails ─────────────────────────────────────────────
  # These rails promote invariants from a documentary closure to a closure
  # by constraint: an invariant we already violated for lack of a check becomes here an
  # executable check. An agent who re-derives → `mix release` REFUSES
  # (verrou_contracts), red build, immediate fix.

  # The `:result_deadline` timer must be CANCELLED when the result arrives (otherwise it
  # kills the long-lived forever/pipe/run pods at cycle 2). Since the `Pod` →
  # `gen_statem` migration, the cancellation is no longer a home-made impl (`Process.cancel_timer`) but
  # NATIVE: `:result_deadline` is a **state_timeout of the `:monitoring` state**, and the
  # `:monitoring → :extracting` transition (triggered by the result arriving,
  # `work_item.completed`) AUTOMATICALLY cancels this state_timeout (a state_timeout is
  # cancelled at the state change). So this check verifies the TWO pillars of this
  # native invariant in pod.ex:
  #   (a) `:result_deadline` is indeed armed/handled as a `:state_timeout` (otherwise it
  #       would not cancel itself at the state change);
  #   (b) the cancelling transition `{:next_state, :extracting, …}` exists (otherwise the result
  #       would arrive without ever leaving `:monitoring` → deadline not cancelled → kill at cycle 2).
  # Red if one is missing, OR if the band-aid `"forever" -> 60_000` (a HACK) reappears.
  defp check_result_deadline_cancelled(root) do
    pod = "lib/fleet/spawner/pod.ex"
    src = File.read!(Path.join(root, pod))

    # (a) :result_deadline handled as state_timeout (one CODE line carries both tokens:
    #     the arming `{:state_timeout, _, :result_deadline}` AND the handler `:state_timeout, :result_deadline`).
    state_timeout? =
      Path.join(root, pod)
      |> grep_lines(~r/:state_timeout.*:result_deadline|:result_deadline.*:state_timeout/)
      |> Enum.any?(fn {_l, line} ->
        stripped = strip_comment(line)

        Regex.match?(~r/:state_timeout/, stripped) and
          Regex.match?(~r/:result_deadline/, stripped)
      end)

    # (b) the cancelling transition :monitoring → :extracting (natively cancels the state_timeout).
    cancels_via_transition? =
      Path.join(root, pod)
      |> grep_lines(~r/:next_state,\s*:extracting/)
      |> Enum.any?(fn {_l, line} ->
        Regex.match?(~r/:next_state,\s*:extracting/, strip_comment(line))
      end)

    has_hack? = Regex.match?(~r/"forever"\s*->\s*60_?000\b/, src)

    evidence =
      [
        {not state_timeout?,
         "#{pod}: :result_deadline is not a :state_timeout of :monitoring — it would no longer cancel itself on the state change (SPAWN-CR1, kills permanent pods at cycle 2)"},
        {not cancels_via_transition?,
         "#{pod}: no `{:next_state, :extracting, …}` transition — the result would arrive without leaving :monitoring → state_timeout :result_deadline never cancelled"},
        {has_hack?,
         "#{pod}: band-aid `forever -> 60_000` still present — revert to 60s + real fix (arm only if a task is active)"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    %{
      id: "spawner.result_deadline_cancelled",
      remediation: "R-result-deadline",
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
      note:
        "result_deadline = state_timeout of :monitoring, cancelled NATIVELY by the :monitoring → :extracting transition when the result arrives; arms only if not forever + fire kills only if a task is active; no 60ks band-aid"
    }
  end

  # The spawn-boundary gates must be wired onto the real spawn path,
  # NOT test-only, otherwise they are HOLLOW containment/credentials gates (called
  # in test but never in prod — the "hollow-gate" failure mode this checker
  # exists to block). The containment gate stays direct in pod.ex; the credentials
  # gate (login-validity — the scope/plan sub-gates were nuked 2026-07-20 as vendor-redundant)
  # lives behind Fleet.Credentials.Gate, reached through Pod.LaunchEnv. 3 checks (all required):
  #     (1) CapProfile.validate — containment gate (refusal of native server-tools), at do_allocate;
  #     (2) pod.ex calls LaunchEnv.build — do_launch chains the env + credentials gates;
  #     (3) LaunchEnv.build contains Fleet.Credentials.Gate.validate — the login-validity gate.
  # Red if one is missing. A gate that runs only in test guards nothing in prod.
  defp check_spawn_gates_wired(root) do
    pod = "lib/fleet/spawner/pod.ex"

    # The env construction + the credentials gate live in Pod.LaunchEnv (the env/creds cluster extracted
    # from do_launch). do_launch (pod.ex) calls LaunchEnv.build, which wires Gate.validate. The gate is
    # thus wired to the spawn by TWO conjoint facts: pod.ex calls LaunchEnv.build AND LaunchEnv.build
    # contains Gate.validate (stronger than the old single-file check where everything was inline in pod.ex).
    launch_env = "lib/fleet/spawner/pod/launch_env.ex"

    # Each check = {relative_file, regex, label}. The label names the expected file.
    items =
      for {rel, re, label} <- [
            {pod, ~r/CapProfile\.validate\(/,
             "CapProfile.validate (containment G24/F-CONT-RISK, do_allocate)"},
            {pod, ~r/LaunchEnv\.build\(/,
             "Pod.LaunchEnv.build wired to the spawn (do_launch chains env + credentials gates)"},
            {launch_env, ~r/Fleet\.Credentials\.Gate\.validate\(/,
             "Fleet.Credentials.Gate.validate (login-validity gate, in LaunchEnv.build)"}
          ],
          do:
            {code_match?(root, rel, re),
             "#{rel}: #{label} missing (hollow gate / empty delegation)"}

    evidence_check(
      %{
        id: "spawn.gates_wired",
        remediation: "R-spawn-gates",
        note:
          "containment gate (CapProfile.validate, do_allocate) in pod.ex + login-validity credentials gate wired to the spawn via Pod.LaunchEnv (do_launch calls LaunchEnv.build, which chains Fleet.Credentials.Gate.validate) — 3 checks"
      },
      items
    )
  end

  # The gatekeeper is an EXCEPTION-inference judge (dispatched by a
  # :soft/:nontranchable gate), NEVER an ordering step. Red if a workflow_map
  # declares a step `role: gatekeeper` — meta-axiom: an LLM reasoner in the
  # coordination mechanics is a signal of failing design.
  # NB the outer parentheses around `(… || [])` are load-bearing: without them
  # `|>` (precedence > `||`) would apply flat_map to `[]`, not to the list of
  # workflow_maps (`(true && l) || [] |> map` ⇒ `l`, map skipped).
  defp check_gatekeeper_not_a_step(root) do
    dir = "priv/workflow/canon/workflow_maps"
    abs = Path.join(root, dir)

    # Anti-hollow-green (mirror of `check_verdict_envelope_unwrapped`): an ABSENT/empty workflow-map
    # corpus must NOT let this rail pass vacuously — a deleted catalogue would silently green a check
    # that vouches for the content of files that are no longer there. So :pass REQUIRES at least one
    # yaml AND no `role: gatekeeper` step.
    yaml_files = (File.dir?(abs) && Path.wildcard(Path.join(abs, "*.yaml"))) || []

    gatekeeper_steps =
      yaml_files
      |> Enum.flat_map(fn path ->
        rel = Path.relative_to(path, root)

        # `\brole:` (left anchor) — targets ONLY the `role: gatekeeper` steps,
        # NOT `target_role: gatekeeper` (legitimate escalation, e.g. standard-qa
        # `on_escalation.target_role`: the gatekeeper IS the exception target, not a
        # step). Without the anchor, `target_role:` contains `role:` → false positive.
        path
        |> grep_lines(~r/\brole:\s*gatekeeper\b/)
        |> Enum.filter(fn {_ln, line} ->
          Regex.match?(~r/\brole:\s*gatekeeper\b/, strip_comment(line))
        end)
        |> Enum.map(fn {ln, _} -> "#{rel}:#{ln} (step role: gatekeeper)" end)
      end)

    %{
      id: "gatekeeper.not_an_ordering_step",
      remediation: "R-gatekeeper-exception",
      status: if(yaml_files != [] and gatekeeper_steps == [], do: :pass, else: :fail),
      evidence:
        if(yaml_files == [],
          do: ["#{dir}: no workflow-map yaml found — corpus absent, this check cannot vouch (fail-closed)"],
          else: gatekeeper_steps
        ),
      note:
        "gatekeeper = exception judge (dispatched on a non-adjudicable gate), never a step role:gatekeeper (§L441; GATE-D1)"
    }
  end

  # StepRunConsumer must unwrap the worker envelope `%{status, result}` before reading the
  # decision (resume_gate/gate_result) OR evaluating the gate (gate_decide) — otherwise
  # decision/outputs stay buried → false escalation / wrongful hard-gate.
  defp check_verdict_envelope_unwrapped(root) do
    step_run = "lib/fleet/pilot/step_run_consumer.ex"
    abs = Path.join(root, step_run)

    # Anti-hollow-green: a `not File.exists?(abs) or …` would turn the rail GREEN if `step_run_consumer.ex` were
    # DELETED (the verdict-route invariant gone but pass anyway). The verdict-route IS the
    # step_run_consumer: its absence is itself a defect → we REQUIRE the file AND the unwrapping
    # (strip_comment: a commented-out `# unwrap_worker_envelope` does not count). Moving the unwrap elsewhere
    # = a design change that MUST update this rail (which this fail-on-absence forces).
    unwrap_present? =
      File.exists?(abs) and
        abs
        |> grep_lines(~r/unwrap_worker_envelope|unwrap_envelope/)
        |> Enum.any?(fn {_l, line} -> Regex.match?(~r/unwrap/, strip_comment(line)) end)

    %{
      id: "verdict.worker_envelope_unwrapped",
      remediation: "R-worker-envelope-unwrap",
      status: if(unwrap_present?, do: :pass, else: :fail),
      evidence:
        cond do
          not File.exists?(abs) ->
            [
              "#{step_run}: ABSENT — the verdict-route (worker envelope unwrap) is gone (#11); if moved, update this rail"
            ]

          not unwrap_present? ->
            ["#{step_run}: verdict_route does not unwrap the worker envelope (#11)"]

          true ->
            []
        end,
      note:
        "unwrap %{status,result} before reading decision (StepRunConsumer); same before Gates.evaluate on the StepRunConsumer side (the forge-driven rail, test-verified). Rail REQUIRES the file (no pass-if-absent — hardened anti-hollow-green)"
    }
  end

  # Verifies that the anti-root self-check exists in the boot path
  # (config/runtime.exs). Red if it disappears. The runtime boot guard lives in
  # runtime.exs (:prod block); this check guards its presence. Post-strip confirmation
  # looser than the grep (`root` alone): the long marker may live partly
  # in a comment on the line, only `root` needs to survive in the code.
  defp check_no_root_runtime_guard(root) do
    presence_check(root, %{
      id: "runtime.no_root_boot_guard",
      remediation: "R-no-root-runtime",
      file: "config/runtime.exs",
      pattern: ~r/R-no-root-runtime|refuse de tourner en root/,
      confirm: ~r/root/,
      missing: "no anti-root self-check at boot (FORGE-D1)",
      note:
        "the daemon must refuse getuid()==0 at boot (boot guard) — a dev/manual run as root resolves ~/.gitea_token to /root's admin token (FORGE-D1)"
    })
  end

  # ── Combinators (3 families of data-driven checks) ───────────────────
  # A good share of the checks are pure instantiations of these 3 families (no COUNT here:
  # comment-counters rust — the list in `run_checks` is the truth); each migrated check is
  # just a call carrying its DATA (id, files, patterns, messages). The evidence messages are
  # passed as-is to the combinator: no loss of precision vs the unrolled versions they replace.

  # Does a CODE line of `rel` match `pattern`? Raw grep, then
  # confirmation on the line stripped of its comment (a comment
  # mention does not count — anti-hollow-green, cf. strip_comment/1).
  # `confirm`: regex OR list of regexes that must ALL match the
  # stripped line, when the confirmation differs from the grep (e.g. require the token
  # to live on the line of the `{:error, …}` tuple); default = `pattern` itself.
  # Public (`@doc false`) so the anti-hollow-green property (a marker in prose does NOT count, BND-111)
  # is unit-testable against a crafted fixture file, not only via the whole-repo smoke test.
  @doc false
  def code_match?(root, rel, pattern, confirm \\ nil) do
    confirms = if confirm, do: List.wrap(confirm), else: [pattern]
    path = Path.join(root, rel)
    doc_lines = doc_block_lines(path)

    path
    |> grep_lines(pattern)
    # BND-111: a marker in RETURN-VALUE docs or module prose (`@doc/@moduledoc` heredocs) is NOT
    # executable code. This checker IS the anti-hollow-green mechanism — it must not accept its own
    # markers' documentation as proof (e.g. `{:error, :brief_required}` is BOTH in `spawner.ex`'s @doc
    # AND at the guard; only the guard proves the invariant). Doc-block lines are dropped before matching.
    |> Enum.reject(fn {ln, _line} -> MapSet.member?(doc_lines, ln) end)
    |> Enum.any?(fn {_ln, line} ->
      stripped = strip_comment(line)
      Enum.all?(confirms, &Regex.match?(&1, stripped))
    end)
  end

  # Line numbers inside `@moduledoc`/`@doc`/`@typedoc`/`@shortdoc` HEREDOC blocks (delimiters included).
  # Line-based scan: enter on `@…doc [~sS]?"""`, exit on a lone `"""`. A heredoc cannot contain an
  # unescaped `"""` (Elixir), so the first lone `"""` closes it. Single-line `@doc "..."` is not a
  # heredoc — left to `strip_comment/1`'s inline-string tracking. Used by `code_match?/4` (BND-111).
  defp doc_block_lines(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reduce({MapSet.new(), false}, fn {line, ln}, {acc, in_doc?} ->
          cond do
            in_doc? ->
              if Regex.match?(~r/^\s*"""\s*$/, line),
                do: {MapSet.put(acc, ln), false},
                else: {MapSet.put(acc, ln), true}

            Regex.match?(~r/^\s*@(module|type|short)?doc\s+(~[sS])?"""/, line) ->
              {MapSet.put(acc, ln), true}

            true ->
              {acc, in_doc?}
          end
        end)
        |> elem(0)

      _ ->
        MapSet.new()
    end
  end

  # Family A — marker-presence: `file` must carry `pattern` in code
  # (confirmed outside comments, `confirm` optional cf. code_match?/4);
  # present = pass, absent = fail with `"<file> : <missing>"` as evidence.
  defp presence_check(root, opts) do
    present? = code_match?(root, opts.file, opts.pattern, Map.get(opts, :confirm))

    %{
      id: opts.id,
      remediation: opts.remediation,
      status: if(present?, do: :pass, else: :fail),
      evidence: if(present?, do: [], else: ["#{opts.file} : #{opts.missing}"]),
      note: opts.note
    }
  end

  # Family B — residue-absence: 0 hit of `pattern` (confirmed outside comments
  # by `confirm`, default `pattern`) in `files` = pass; each residual hit =
  # a `file:line` evidence. ⚠ inherits the hollow-green trap of `grep_lines/2`
  # (absent file = 0 hit = pass): list here only live files whose
  # existence is guarded elsewhere — for a residue on a potentially
  # dead file, grep a glob (cf. check_coord_backend_wired).
  defp residue_check(root, opts) do
    confirm = Map.get(opts, :confirm) || opts.pattern

    evidence =
      Enum.flat_map(opts.files, fn rel ->
        abs = Path.join(root, rel)

        # HOLLOW-GREEN GUARD (R0-EVT-012): a residue check greps FIXED file paths; on an ABSENT file
        # `grep_lines` returns `[]` (0 residue) → `:pass` FOREVER, even though the target moved/was
        # deleted and the contract is no longer verified. An absent residue target is therefore a
        # FAILURE, not a silent green — the check must be told its file vanished.
        if File.exists?(abs) do
          abs
          |> grep_lines(opts.pattern)
          |> Enum.filter(fn {_ln, line} -> Regex.match?(confirm, strip_comment(line)) end)
          |> Enum.map(fn {ln, _} -> "#{rel}:#{ln}" end)
        else
          ["#{rel}:MISSING — residue-check target absent (hollow-green guard, R0-EVT-012)"]
        end
      end)

    %{
      id: opts.id,
      remediation: opts.remediation,
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
      note: opts.note
    }
  end

  # Family C — evidence-list: `items` = [{ok?, message}], conditions evaluated at the
  # call site (grep, File.exists?, …). All true = pass; each false
  # condition puts its message (precise, pre-composed) into evidence.
  defp evidence_check(meta, items) do
    evidence = for {ok?, msg} <- items, not ok?, do: msg

    %{
      id: meta.id,
      remediation: meta.remediation,
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
      note: meta.note
    }
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp module_exists?(name) do
    mod = String.to_atom("Elixir." <> name)
    Code.ensure_loaded?(mod)
  end

  # Removes the end-of-line `#...` comment, outside a double-quote string
  # (the `#` inside a "..." are code, e.g. `#{}` interpolation).
  # Heuristic sufficient to measure code vs a comment mention.
  # Known limit: the char literal `?#` is truncated (not handled) — not exploitable
  # on the fixed targets (no `?#`), a tuple form `{?#, …}` being absurd.
  defp strip_comment(line) do
    line
    |> String.to_charlist()
    |> do_strip_comment([], false)
    |> Enum.reverse()
    |> List.to_string()
  end

  defp do_strip_comment([], acc, _in_str), do: acc
  defp do_strip_comment([?# | _rest], acc, false), do: acc

  defp do_strip_comment([?" | rest], acc, in_str),
    do: do_strip_comment(rest, [?" | acc], not in_str)

  defp do_strip_comment([c | rest], acc, in_str), do: do_strip_comment(rest, [c | acc], in_str)

  # ⚠ HOLLOW-GREEN TRAP: on an ABSENT file, `grep_lines` returns `[]`
  # — indistinguishable from "present but 0 match". A check "no residue X in
  # file Y" that rules `pass` on `evidence == []` therefore ALWAYS passes if Y
  # has been deleted. For a RESIDUE check, grep a glob of real files
  # (`Path.wildcard`), not a single potentially dead file path.
  defp grep_lines(path, regex) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
        |> Enum.map(fn {line, ln} -> {ln, line} end)

      _ ->
        []
    end
  end

  # Z3: single-app project — the task always runs at the project root (Mix sets the cwd
  # there). NO umbrella-style detection ("no `apps/` dir → go up two levels"): that case
  # does not exist, and such a heuristic would resolve to a `../..` OUTSIDE the project.
  defp project_root, do: File.cwd!()

  # ── Topology lock ──────────────────────────────────────────────
  # Z3 (D-19) — there is NO `layering.dependency_graph` check here: dependency DIRECTION
  # is enforced by boundary (Z4) — each domain declares its deps in `use Boundary` and the
  # COMPILER refuses violations, stronger than any grep. What boundary CANNOT see, and what
  # this check locks, is the BOOT invariant: the children order of Fleet.Application is the
  # SOLE carrier of F8 (event_router first; mcp before spawner — no starfleet constraint,
  # cf. A-08 comment in the function) — reordering it breaks the boot WITHOUT a compile
  # error. Hence the honest check id: `boot.order_f8`.
  defp check_boot_order_f8(root) do
    app_src = File.read!(Path.join(root, "lib/fleet/application.ex"))

    # A-08: there is NO `mcp < starfleet` / `spawner < starfleet` constraint — their only
    # would-be cause (a mid-boot starfleet child spawning the permanents) does not exist:
    # the BootOrchestrator is a root-level POST-boot trigger. What holds: event_router
    # FIRST (the Bus is every subscriber's substrate) and mcp BEFORE spawner (spawner's
    # PublishConsumer can receive an admin.spawn.request as soon as it subscribes →
    # ensure_pod_socket requires the mcp substrate alive).
    with [block] <- Regex.run(~r/children = \[(.*?)\n    \]/s, app_src, capture: :all_but_first),
         positions = %{
           er: :binary.match(block, "Fleet.EventRouter.Application"),
           mcp: :binary.match(block, "Fleet.MCP.Supervisor"),
           spw: :binary.match(block, "Fleet.Spawner.Application")
         },
         false <- Enum.any?(positions, fn {_, m} -> m == :nomatch end) do
      %{er: {er, _}, mcp: {mcp, _}, spw: {spw, _}} = positions
      # er = MIN of the three (the Bus boots before any potential consumer) — NOT er==0:
      # the children block starts with a COMMENT, the module offset is never 0.
      ok? = er < mcp and mcp < spw

      %{
        id: "boot.order_f8",
        remediation:
          "reorder the children of Fleet.Application: event_router FIRST, " <>
            "mcp BEFORE spawner (F8 scar in the moduledoc; no starfleet " <>
            "constraint per A-08 — BootOrchestrator is triggered post-boot by the root)",
        status: if(ok?, do: :pass, else: :fail),
        evidence: [
          "children order (offsets in the block): event_router=#{er} mcp=#{mcp} " <>
            "spawner=#{spw} — constraints: er<mcp, mcp<spw"
        ],
        note:
          "boot-order lock (the deps DIRECTION is enforced by boundary at compile time, Z4)"
      }
    else
      _ ->
        %{
          id: "boot.order_f8",
          remediation:
            "children of Fleet.Application not found (`children = [...]` block or an " <>
              "expected domain supervisor missing) — restore the list + F8 scar",
          status: :fail,
          evidence: ["children block extraction impossible — fail-closed"],
          note: "cf. Z3 (D-19) comment above"
        }
    end
  end

  # Z7 (F-C165 / D6 arbitration) — role-token provisioning carries a SECOND role list
  # (etc/provision-role-tokens.sh ROLES=), which CAN diverge from the canon (lived bug
  # class: a name in the .sh that is not a pod role — e.g. an external agent, which by
  # construction has no vendor bridge and thus no canon entry → exit 2 on an unknown role).
  # Minimal verifiable SSOT: every role in the .sh EXISTS in the canon catalogue.
  # (The full SSOT — a needs_role_token flag deriving the list — is pending the user's
  # A-03 arbitration; this check catches the lived bug class meanwhile.)
  # Boundary can NEVER see this: the .sh is outside the BEAM — exactly THIS checker's job.
  defp check_roles_provisioning_in_catalogue(root) do
    sh_path = Path.join(root, "etc/provision-role-tokens.sh")

    roles =
      case Regex.run(~r/^ROLES="([^"]*)"/m, File.read!(sh_path)) do
        [_, list] -> String.split(list)
        _ -> nil
      end

    catalogue =
      root
      |> Path.join("priv/cap_profile/canon/cap-profiles/*.yaml")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".yaml"))
      |> Enum.reject(&String.starts_with?(&1, "_"))

    phantoms = if roles, do: roles -- catalogue, else: nil

    %{
      id: "roles.provisioning_in_catalogue",
      remediation:
        "remove phantom roles (absent from the canon catalogue) from the .sh — or if a new " <>
          "role is legitimate, its canon cap-profile MUST exist first (the canon is the source)",
      status:
        if(is_list(phantoms) and phantoms == [] and catalogue != [], do: :pass, else: :fail),
      evidence:
        cond do
          is_nil(roles) ->
            ["#{sh_path}: ROLES=\"…\" line not found — fail-closed"]

          catalogue == [] ->
            ["canon catalogue empty/not found — fail-closed"]

          phantoms != [] ->
            ["phantom roles in the .sh (absent from the canon): #{inspect(phantoms)}"]

          true ->
            []
        end,
      note:
        "provisioning .sh ⊆ canon catalogue (#{length(catalogue)} roles) — the second list " <>
          "cannot drift silently"
    }
  end

  # Z7 (F1 / F-C138-format) — the MCP wire requires inputSchema (camelCase) where the
  # ExMCP internal shape is input_schema (snake): missing the projection makes ALL pods
  # mute (tools silently rejected by the vendor CLI — regression F1). The fix lives at the
  # socket frontier (PodSocketAcceptor projects to MCP-wire) + a non-regression test. THIS
  # check locks the CONTRACT at the gate: the projection exists in the code AND the
  # anti-regression test exists (deleting the test is visible to the gate — belt over
  # the ExUnit net).
  defp check_mcp_wire_inputschema(root) do
    acceptor = "lib/fleet/mcp/pod_socket_acceptor.ex"
    test = "test/pod_socket_test.exs"

    # Projection code-side: the camelCase wire key on an EXECUTABLE line (`code_match?` excludes
    # @doc/@moduledoc heredocs + `#` comments — BND-111: a prose mention of "inputSchema" is not a proof).
    projection? = code_match?(root, acceptor, ~r/"inputSchema"/)

    # Test-side proof: the EXECUTABLE assert/refute PAIR, NOT a bare full-file string presence (BND-111:
    # the test's own COMMENT names BOTH tokens → a raw `=~` would stay green even if the asserts were
    # deleted). We require `assert Map.has_key?(… "inputSchema")` AND `refute Map.has_key?(… "input_schema")`
    # each on its own code line (absent test file → code_match? false → fail, hollow-green guard).
    asserts? =
      code_match?(root, test, ~r/"inputSchema"/, [~r/assert\s+Map\.has_key\?/, ~r/"inputSchema"/]) and
        code_match?(root, test, ~r/"input_schema"/, [~r/refute\s+Map\.has_key\?/, ~r/"input_schema"/])

    %{
      id: "mcp.wire_inputschema",
      remediation:
        "restore the MCP-wire projection (inputSchema camelCase) at the socket frontier " <>
          "(PodSocketAcceptor) + the assert/refute pair of pod_socket_test (regression F1: " <>
          "mute pods, tools silently rejected)",
      status: if(projection? and asserts?, do: :pass, else: :fail),
      evidence:
        cond do
          not projection? ->
            ["#{acceptor}: \"inputSchema\" projection absent from the code (F1 reopened)"]

          not asserts? ->
            [
              "#{test}: EXECUTABLE pair assert Map.has_key?(inputSchema) / refute Map.has_key?(input_schema) absent (BND-111: a comment is not proof)"
            ]

          true ->
            []
        end,
      note:
        "socket frontier = wire (camelCase); ExMCP internal shape = snake — F1 locked at the gate"
    }
  end

  defp render_yaml(overall, checks) do
    header = "status: #{overall}\nchecks:"

    body =
      Enum.map_join(checks, "\n", fn c ->
        # FIELD access (c.evidence/c.note like c.id/c.status): every producer sets the
        # 5 keys — a defaulted Map.get would mask a guaranteed shape (dead default).
        ev =
          case c.evidence do
            [] -> ""
            list -> "\n    evidence:\n" <> Enum.map_join(list, "\n", &"      - #{&1}")
          end

        "  - id: #{c.id}\n" <>
          "    remediation: #{c.remediation}\n" <>
          "    status: #{c.status}\n" <>
          "    note: #{c.note}" <> ev
      end)

    header <> "\n" <> body
  end
end
