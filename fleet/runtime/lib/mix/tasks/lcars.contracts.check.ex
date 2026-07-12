defmodule Mix.Tasks.Lcars.Contracts.Check do
  # Z4 migration — tâche Mix classifiée dans la boundary de son sujet (Fleet.Application).
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
        check_layering_dependency_graph(root),
        # ── Authority locks (Z7 migration — un fait = une source, cross-langage) ──
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
  defp check_event_consumers_canon(root) do
    residue_check(root, %{
      id: "event.consumers.canon",
      remediation: "R03/R10 (R2)",
      files: ["lib/fleet/api/ws.ex"],
      pattern: ~r/"event_type"\s*=>/,
      confirm: ~r/"event_type"\s*=>/,
      note: "consumers still on the legacy \"event_type\" tuple"
    })
  end

  # The Loader must unwrap the v2.5 ENVELOPE (kind/metadata/spec.steps) into the single internal
  # FLAT form. There is NO v1: a flat/enveloppe-less YAML fails the v2.5 schema before `normalize`.
  # « v1/v2.5 » = external envelope vs internal flat (same version, two shapes), NOT two versions.
  # Without the unwrap, a consumer reads `workflow_map["steps"]=nil` (steps live under spec.steps).
  defp check_pipeline_v25_normalized(root) do
    rel = "lib/fleet/workflow/loader.ex"
    loader = Path.join(root, rel)

    # Anti-hollow-green: matching `~r/normalize|déball/i` over the WHOLE source would turn the rail green as soon as a
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
      remediation: "R01/U1 (R3)",
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
      remediation: "R08 (R5)",
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
      remediation: "R06/R22 (R4)",
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
      remediation: "R12",
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
      remediation: "R13",
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
        remediation: "R20/F103",
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
        remediation: "R14",
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

  # `Fleet.Spawner.spawn_pod/3` must refuse a `one-shot` pod without a brief (otherwise
  # the pod starts with no work → timeout). Marker of the guard: the error
  # `:brief_required`. Red if absent (regression to the mute generic brief).
  defp check_spawn_has_brief(root) do
    presence_check(root, %{
      id: "spawn.has_brief",
      remediation: "R18",
      file: "lib/fleet/spawner.ex",
      pattern: ~r/:brief_required/,
      missing: "no :brief_required guard at the spawn_pod boundary",
      note: "spawn_pod must refuse a one-shot pod without a brief (except allow_no_brief)"
    })
  end

  # `Fleet.SPBuilder.filter_skills/2` must fail (fail-loud) if a whitelisted PLAIN
  # skill is absent from disk — otherwise a silent filtering would let a pod
  # claim a nonexistent skill. Marker: `:skills_missing`.
  # Red if absent.
  defp check_skills_declared_present(root) do
    presence_check(root, %{
      id: "skills.declared_present",
      remediation: "R11",
      file: "lib/fleet/sp_builder.ex",
      pattern: ~r/:skills_missing/,
      missing: "filter_skills silently filters out missing skills",
      note: "filter_skills must fail-loud {:skills_missing} on a missing plain skill"
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
      remediation: "R09/F-08",
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
  # exists to block). The containment gate stays direct in pod.ex; the
  # scope+plan gates have been grouped behind a dedicated credentials gate (Fleet.Credentials.Gate),
  # reached through Pod.LaunchEnv. This check verifies TWO levels, 5 checks (all required):
  #   level 1 — wiring on the real spawn path:
  #     (1) CapProfile.validate — containment gate (refusal of native server-tools), at do_allocate;
  #     (2) pod.ex calls LaunchEnv.build — do_launch chains the env + credentials gates;
  #     (3) LaunchEnv.build contains Fleet.Credentials.Gate.validate — the credentials gate (scope+plan);
  #   level 2 — the credentials gate ACTUALLY delegates (not an empty shell) in gate.ex:
  #     (4) ScopeValidator.validate — per-role OAuth scope coverage;
  #     (5) PlanValidator.validate — paid subscription.
  # Red if one is missing. A gate that runs only in test, or a wired gate that
  # delegates nothing, guards nothing in prod.
  defp check_spawn_gates_wired(root) do
    pod = "lib/fleet/spawner/pod.ex"

    # The env construction + the credentials gate live in Pod.LaunchEnv (the env/creds cluster extracted
    # from do_launch). do_launch (pod.ex) calls LaunchEnv.build, which wires Gate.validate. The gate is
    # thus wired to the spawn by TWO conjoint facts: pod.ex calls LaunchEnv.build AND LaunchEnv.build
    # contains Gate.validate (stronger than the old single-file check where everything was inline in pod.ex).
    launch_env = "lib/fleet/spawner/pod/launch_env.ex"
    gate = "lib/fleet/credentials/gate.ex"

    # Each check = {relative_file, regex, label}. The label names the expected file.
    items =
      for {rel, re, label} <- [
            {pod, ~r/CapProfile\.validate\(/,
             "CapProfile.validate (containment G24/F-CONT-RISK, do_allocate)"},
            {pod, ~r/LaunchEnv\.build\(/,
             "Pod.LaunchEnv.build wired to the spawn (do_launch chains env + credentials gates)"},
            {launch_env, ~r/Fleet\.Credentials\.Gate\.validate\(/,
             "Fleet.Credentials.Gate.validate (scope+plan gate, in LaunchEnv.build)"},
            {gate, ~r/ScopeValidator\.validate\(/,
             "ScopeValidator.validate (scope-coverage delegation)"},
            {gate, ~r/PlanValidator\.validate\(/, "PlanValidator.validate (paid-plan delegation)"}
          ],
          do:
            {code_match?(root, rel, re),
             "#{rel}: #{label} missing (hollow gate / empty delegation)"}

    evidence_check(
      %{
        id: "spawn.gates_wired",
        remediation: "R-spawn-gates",
        note:
          "containment gate (CapProfile.validate, do_allocate) in pod.ex + credentials gate wired to the spawn via Pod.LaunchEnv (do_launch calls LaunchEnv.build, which chains Fleet.Credentials.Gate.validate), AND the gate actually delegates scope (ScopeValidator) + plan (PlanValidator) in gate.ex — 5 checks, 2 levels"
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

    evidence =
      ((File.dir?(abs) && Path.wildcard(Path.join(abs, "*.yaml"))) || [])
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
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
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
  # 8 of the 18 checks are pure instantiations of 3 families; each migrated
  # check is now just a call carrying its DATA (id, files, patterns,
  # messages). The evidence messages are passed as-is to the combinator:
  # no loss of precision vs the unrolled versions they replace.

  # Does a CODE line of `rel` match `pattern`? Raw grep, then
  # confirmation on the line stripped of its comment (a comment
  # mention does not count — anti-hollow-green, cf. strip_comment/1).
  # `confirm`: regex OR list of regexes that must ALL match the
  # stripped line, when the confirmation differs from the grep (e.g. require the token
  # to live on the line of the `{:error, …}` tuple); default = `pattern` itself.
  defp code_match?(root, rel, pattern, confirm \\ nil) do
    confirms = if confirm, do: List.wrap(confirm), else: [pattern]

    Path.join(root, rel)
    |> grep_lines(pattern)
    |> Enum.any?(fn {_ln, line} ->
      stripped = strip_comment(line)
      Enum.all?(confirms, &Regex.match?(&1, stripped))
    end)
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

  # MIGRATION Z3 : plus d'umbrella — la tâche tourne toujours à la racine du projet single-app
  # (Mix pose le cwd à la racine ; l'ancienne détection « pas de dossier `apps/` → remonter de
  # deux niveaux » servait au lancement depuis une app umbrella, un cas qui n'existe plus et qui,
  # gardé, renverrait un `../..` HORS projet dès que le leftover `apps/` sera supprimé).
  defp project_root, do: File.cwd!()

  # ── Topology lock ──────────────────────────────────────────────
  # MIGRATION Z3 (D-19) — l'ancien `layering.dependency_graph` est RETIRÉ avec sa matière
  # première : il lisait les edges `in_umbrella:` des apps/*/mix.exs, qui n'existent plus.
  # Son successeur MÉCANIQUE est boundary (Z4) : chaque domaine déclarera ses deps dans
  # `use Boundary` et le COMPILATEUR refusera les violations — plus fort que ce grep.
  # FENÊTRE ASSUMÉE entre Z3 et Z4 : la direction des deps inter-domaines n'est enforcée
  # nulle part. Ce qui RESTE vérifiable ici, et que l'umbrella ne portait pas, c'est
  # l'invariant de BOOT : l'ordre des children de Fleet.Application est le SEUL porteur
  # de F8 (event_router premier ; mcp avant starfleet ; starfleet après spawner) — le
  # réordonner casse le boot sans erreur de compile. C'est ce que ce check verrouille,
  # sous un id honnête (`boot.order_f8`).
  defp check_layering_dependency_graph(root) do
    app_src = File.read!(Path.join(root, "lib/fleet/application.ex"))

    with [block] <- Regex.run(~r/children = \[(.*?)\n    \]/s, app_src, capture: :all_but_first),
         positions = %{
           er: :binary.match(block, "Fleet.EventRouter.Application"),
           mcp: :binary.match(block, "Fleet.MCP.Supervisor"),
           spw: :binary.match(block, "Fleet.Spawner.Application"),
           stf: :binary.match(block, "Fleet.Starfleet.Application")
         },
         false <- Enum.any?(positions, fn {_, m} -> m == :nomatch end) do
      %{er: {er, _}, mcp: {mcp, _}, spw: {spw, _}, stf: {stf, _}} = positions
      # er = MIN des quatre (le Bus boote avant tout consommateur potentiel) — PAS er==0 :
      # le bloc children commence par un COMMENTAIRE, l'offset du module n'est jamais 0.
      ok? = er < mcp and er < spw and mcp < stf and spw < stf

      %{
        id: "boot.order_f8",
        remediation:
          "réordonner les children de Fleet.Application : event_router EN TÊTE, " <>
            "mcp AVANT starfleet, starfleet APRÈS spawner (cicatrice F8 du moduledoc)",
        status: if(ok?, do: :pass, else: :fail),
        evidence: [
          "ordre children (offsets dans le bloc) : event_router=#{er} mcp=#{mcp} " <>
            "spawner=#{spw} starfleet=#{stf} — contraintes : er<mcp, er<spw, mcp<stf, spw<stf"
        ],
        note:
          "successeur du verrou topologie umbrella (retiré avec les mix.exs d'apps) ; " <>
            "l'enforcement de la DIRECTION des deps arrive avec boundary (Z4)"
      }
    else
      _ ->
        %{
          id: "boot.order_f8",
          remediation:
            "children de Fleet.Application introuvables (bloc `children = [...]` ou un " <>
              "superviseur de domaine attendu manquant) — restaurer la liste + cicatrice F8",
          status: :fail,
          evidence: ["extraction du bloc children impossible — fail-closed"],
          note: "cf. commentaire MIGRATION Z3 (D-19) ci-dessus"
        }
    end
  end

  # Z7 migration (F-C165 / arbitrage D6) — le provisioning de role-tokens porte une 2ᵉ liste
  # de rôles (etc/provision-role-tokens.sh ROLES=) qui a DÉJÀ divergé du canon une fois
  # (vulcan fantôme 6 semaines après le rename starfleet → exit 2 sur rôle inexistant).
  # SSOT minimal vérifiable AUJOURD'HUI : tout rôle du .sh EXISTE au catalogue canon.
  # (Le SSOT complet — flag needs_role_token dérivant la liste — reste à implémenter si
  # l'user tranche A-03 ; ce check attrape la classe de bug vécue en attendant.)
  # Boundary ne verra JAMAIS ça : le .sh est hors-BEAM — c'est exactement le rôle de CE checker.
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
        "retirer du .sh les rôles fantômes (hors catalogue canon) — ou si un rôle neuf est " <>
          "légitime, son cap-profile canon DOIT exister d'abord (le canon est la source)",
      status:
        if(is_list(phantoms) and phantoms == [] and catalogue != [], do: :pass, else: :fail),
      evidence:
        cond do
          is_nil(roles) ->
            ["#{sh_path}: ligne ROLES=\"…\" introuvable — fail-closed"]

          catalogue == [] ->
            ["catalogue canon vide/introuvable — fail-closed"]

          phantoms != [] ->
            ["rôles fantômes dans le .sh (absents du canon) : #{inspect(phantoms)}"]

          true ->
            []
        end,
      note:
        "provisioning .sh ⊆ catalogue canon (#{length(catalogue)} rôles) — la 2ᵉ liste ne peut " <>
          "plus dériver en silence"
    }
  end

  # Z7 migration (F1 / F-C138-format) — le wire MCP exige inputSchema (camelCase) là où la
  # forme interne ExMCP est input_schema (snake) : la régression F1 a rendu TOUS les pods
  # muets (tools silencieusement rejetés par claude). Le fix vit à la frontière socket
  # (PodSocketAcceptor projette en MCP-wire) + un test de non-régression. CE check verrouille
  # le CONTRAT au gate : la projection existe dans le code ET le test anti-régression existe
  # (si quelqu'un supprime le test, le gate le voit — ceinture du filet ExUnit).
  defp check_mcp_wire_inputschema(root) do
    acceptor = Path.join(root, "lib/fleet/mcp/pod_socket_acceptor.ex")
    test = Path.join(root, "test/pod_socket_test.exs")

    projection? =
      acceptor
      |> grep_lines(~r/"inputSchema"/)
      |> Enum.any?(fn {_l, line} -> Regex.match?(~r/"inputSchema"/, strip_comment(line)) end)

    test_src = if File.exists?(test), do: File.read!(test), else: ""
    asserts? = test_src =~ ~s("inputSchema") and test_src =~ ~s("input_schema")

    %{
      id: "mcp.wire_inputschema",
      remediation:
        "restaurer la projection MCP-wire (inputSchema camelCase) à la frontière socket " <>
          "(PodSocketAcceptor) + le test assert/refute de pod_socket_test (régression F1 : " <>
          "pods muets, tools rejetés en silence)",
      status: if(projection? and asserts?, do: :pass, else: :fail),
      evidence:
        cond do
          not projection? ->
            ["#{acceptor}: projection \"inputSchema\" absente du code (F1 rouvert)"]

          not asserts? ->
            ["#{test}: paire assert inputSchema / refute input_schema absente"]

          true ->
            []
        end,
      note:
        "frontière socket = wire (camelCase) ; forme interne ExMCP = snake — F1 verrouillé au gate"
    }
  end

  defp render_yaml(overall, checks) do
    header = "status: #{overall}\nchecks:"

    body =
      Enum.map_join(checks, "\n", fn c ->
        # Accès par CHAMP (c.evidence/c.note comme c.id/c.status) : chaque producteur pose les
        # 5 clés — un Map.get à défaut masquerait une forme garantie (et son défaut mort).
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
