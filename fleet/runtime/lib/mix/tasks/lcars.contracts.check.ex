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

  **Last revised**: 2026-08-06
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
  exit) AND by the `mix release` step (`mix.exs` `contracts_gate/1`: refuses to
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
        check_roles_provisioning_locked(root),
        check_roles_role_index_unique(root),
        check_sourcers_set_strict(root),
        check_sanctuary_contained(root),
        check_mcp_wire_inputschema(root),
        check_mcp_tools_gated(root),
        check_mcp_seam_surface(root),
        check_forge_fields_read(root),
        check_forge_mutations_exposed(root),
        check_intensity_max_fan_ceiling(root),
        check_test_corpora_on_record(root)
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
  # SCOPE: a GLOBAL residue sweep over lib/ — the id's "canon" covers every consumer, matching
  # what the name claims (it long scanned only api/ws.ex, the last migrant).
  defp check_event_consumers_canon(root) do
    # The check's NAME claims the canon for ALL consumers; it long grepped ws.ex alone (the last
    # migrant), leaving the guarantee narrower than its label. The residue scan now covers
    # every source under lib/ — a legacy `"event_type"` tuple REINTRODUCED anywhere fails the gate,
    # not just in the one file that once carried it.
    residue_check(root, %{
      id: "event.consumers.canon",
      remediation:
        "migrate the flagged consumer(s) off the legacy `event_type` tuple to `%Fleet.Event{}` matching",
      files:
        Path.wildcard(Path.join(root, "lib/**/*.ex"))
        |> Enum.map(&Path.relative_to(&1, root)),
      pattern: ~r/"event_type"\s*=>/,
      confirm: ~r/"event_type"\s*=>/,
      note: "a consumer on the legacy \"event_type\" tuple (canon = %Fleet.Event{} matching)"
    })
  end

  # The Loader must unwrap the v2.5 ENVELOPE (kind/metadata/spec.steps) into the single internal
  # FLAT form. There is NO v1: a flat/envelope-less YAML fails the v2.5 schema before `normalize`.
  # "v1/v2.5" = external envelope vs internal flat (same version, two shapes), NOT two versions.
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
      remediation:
        "add the v2.5 `normalize` unwrap clause for spec.steps so a workflow_map consumer does not read steps=nil",
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
      remediation:
        "remove the phantom handler ref(s) from events.yaml, or add the missing subscriber(s)",
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
      remediation:
        "keep the LLM gate on the gatekeeper (pure Gates) — no residual NotWiredYet nor coord delegation",
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
      remediation:
        "read spec.invocation.lifetime_scope (v2.5), not the pre-v2.5 spec.lifetime_scope, in compose_claude_md",
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
      remediation:
        "keep the modop-incompatibility guard (check_modop_incompatible) in cap_profile.ex / invariants.ex",
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
        remediation:
          "keep host containment:none on host_launch.sh; do not reintroduce TmuxBackend (bare remote-control)",
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
        remediation:
          "keep both MCP levels: pod.ex maybe_provision_mcp_config AND mcp_provision.ex fail-loud :mcp_server_spec_required for a real backend without a spec",
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
  #   3. same structural guard on `interlocutor`: it selects WHICH protocol contract a pod is
  #      provisioned with, so an undeclared profile must not spawn. Defaulting it would restore the
  #      silence the field exists to end — the pod boots and looks healthy while holding a contract
  #      nobody chose for it, which is undetectable from the outside.
  # Unwiring any clause turns this RED, whatever the docs say.
  defp check_spawn_has_brief(root) do
    spawner = "lib/fleet/spawner.ex"

    evidence_check(
      %{
        id: "spawn.has_brief",
        remediation:
          "keep spawn_pod guards: {:error, :brief_required} for a one-shot without brief, {:error, :cap_profile_no_lifetime_scope} for a missing lifetime_scope, {:error, :cap_profile_no_interlocutor} for a missing interlocutor",
        note:
          "spawn_pod refuses a one-shot pod without a brief ({:error, :brief_required}), a cap-profile with no lifetime_scope (DR-019: fetch_lifetime_scope → {:error, :cap_profile_no_lifetime_scope}) AND one with no interlocutor (fetch_interlocutor → {:error, :cap_profile_no_interlocutor}) — the real invariants, not markers"
      },
      [
        {code_match?(root, spawner, ~r/:brief_required/, [
           ~r/:brief_required/,
           ~r/^\s*\{:error, :brief_required\}/
         ]),
         "#{spawner}: no executable {:error, :brief_required} guard at the spawn_pod boundary"},
        {code_match?(root, spawner, ~r/fetch_lifetime_scope/),
         "#{spawner}: spawn_pod does not gate on CapProfile.fetch_lifetime_scope (DR-019 source-fix unwired)"},
        {code_match?(root, spawner, ~r/:cap_profile_no_lifetime_scope/, [
           ~r/:cap_profile_no_lifetime_scope/,
           ~r/^\s*\{:error, :cap_profile_no_lifetime_scope\}/
         ]),
         "#{spawner}: no executable refusal of a cap-profile without lifetime_scope (DR-019)"},
        {code_match?(root, spawner, ~r/fetch_interlocutor/),
         "#{spawner}: spawn_pod does not gate on CapProfile.fetch_interlocutor (the protocol contract would be inferred)"},
        {code_match?(root, spawner, ~r/:cap_profile_no_interlocutor/, [
           ~r/:cap_profile_no_interlocutor/,
           ~r/^\s*\{:error, :cap_profile_no_interlocutor\}/
         ]), "#{spawner}: no executable refusal of a cap-profile without interlocutor"}
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
      remediation:
        "make filter_skills fail-loud {:error, {:skills_missing, _}} on a missing plain skill",
      file: "lib/fleet/sp_builder.ex",
      pattern: ~r/:skills_missing/,
      confirm: [~r/:skills_missing/, ~r/\{:error, \{:skills_missing,/],
      missing:
        "filter_skills silently filters out missing skills (no executable {:error, {:skills_missing,} fail-loud)",
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
      remediation:
        "add the consumed type(s) to events.yaml (every handle_info %Fleet.Event{type:} must be a registry key)",
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
  # (contracts_gate), red build, immediate fix.

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
    dir = "priv/catalogue/workflow/canon/workflow_maps"
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
          do: [
            "#{dir}: no workflow-map yaml found — corpus absent, this check cannot vouch (fail-closed)"
          ],
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
      pattern: ~r/R-no-root-runtime/,
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
        note: "boot-order lock (the deps DIRECTION is enforced by boundary at compile time, Z4)"
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

  # Z7 (F-C165 → BL-6-45) — FOUR lists declare which roles exist, and every pairwise drift has
  # bitten or nearly bitten: the canon catalogue (the SOURCE), forge.tf `local.roles` (accounts),
  # etc/provision-role-tokens.sh `ROLES` (token mint default), and provisioning_v2's
  # `PROV_ROLES` (which OVERRIDES the .sh default via --roles — the list that actually wins on
  # a fresh deploy; measured: eng_doc missing there while present in the three others = the
  # BL-6-34 root-cause class resurrected). The old check covered ONE direction (.sh ⊆ canon);
  # a canon role dropped from any provisioning list looped the fleet in role_token_unavailable
  # (scoper 07-31, eng_doc 08-02 — one diagnosis session each).
  # The rule: {canon roles with forge_identity} == tf == sh == lib, STRICT EQUALITY, every
  # delta named with its own remediation. The asymmetry lives in the DATA, never in this
  # control: starfleet declares `forge_identity: false` (its forge writes go through the
  # system), a ReservedSeat (vulcan) counts as a seat = an account + a token, both inert.
  # Boundary can NEVER see any of this: three of the four lists are outside the BEAM.
  defp check_roles_provisioning_locked(root) do
    # Decoded reads (kind/forge_identity are yaml fields, not greppable shapes) — the task
    # context does not start :yaml_elixir by itself; same explicit start as lcars.sp.gen.
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    catalogue = scan_catalogue_roles(root)

    canon =
      catalogue
      |> Enum.filter(& &1.forge_identity)
      |> Enum.map(& &1.name)
      |> Enum.sort()

    sh_path = Path.join(root, "etc/provision-role-tokens.sh")

    # `provisioning_v2/deps/`, moved there 2026-08-05: the tofu recipe was the LAST live leg of the
    # v1 tree, and this check reading it across trees is what caught the move — the wall working on
    # the gesture that touched it.
    tf_path = Path.expand("../provisioning_v2/deps/forge.tf", root)
    lib_path = Path.expand("../provisioning_v2/lib/provision-lib.sh", root)

    # The two SIBLING-TREE lists are outside `fleet/runtime`, and one legitimate context does not
    # carry them: the image BUILD stage copies `fleet/runtime` ALONE (Dockerfile), then runs this
    # gate — a runtime-only artifact cannot prove anything about a provisioning list it does not
    # ship. So absence is read at the TREE level: no sibling tree at all = out of scope, SKIPPED
    # and named in the note (never a silent pass on unmeasured ground); tree present but file or
    # pattern unreadable = the real defect (partial checkout, renamed variable) = FAIL. The
    # `.sh` lives inside `etc/` and is always present.
    lists =
      [
        {"provision-role-tokens.sh ROLES", :required,
         read_list(sh_path, ~r/^ROLES="([^"]*)"/m, :plain),
         "add/remove the role in ROLES=\"…\" (token mint default)"},
        {"forge.tf local.roles", tree_scope(Path.expand("../provisioning_v2", root)),
         read_list(tf_path, ~r/^\s*roles\s*=\s*\[([^\]]*)\]/m, :quoted),
         "add/remove the role in local.roles (forge account) — the canon is the source: a role " <>
           "only in forge.tf needs its cap-profile or a ReservedSeat, or loses its account"},
        {"provision-lib.sh PROV_ROLES", tree_scope(Path.expand("../provisioning_v2", root)),
         read_list(lib_path, ~r/\$\{PROV_ROLES:=([^}]*)\}/, :plain),
         "add/remove the role in PROV_ROLES (the list that WINS the mint on deploy — a role " <>
           "absent here gets no token on a fresh fleet)"}
      ]

    {lists, skipped} = split_out_of_scope(lists)

    {evidence, remediations} =
      Enum.reduce(lists, {[], []}, fn {label, roles, remediation}, {ev, rem} ->
        case roles do
          nil ->
            {ev ++ ["#{label}: list not readable — fail-closed (partial checkout?)"],
             rem ++ [remediation]}

          list ->
            missing = canon -- list
            extra = list -- canon
            ev2 = if missing != [], do: ["#{label}: MISSING #{inspect(missing)}"], else: []
            ev3 = if extra != [], do: ["#{label}: EXTRA #{inspect(extra)}"], else: []
            rem2 = if missing != [] or extra != [], do: [remediation], else: []
            {ev ++ ev2 ++ ev3, rem ++ rem2}
        end
      end)

    evidence =
      if canon == [], do: ["canon catalogue empty/not found — fail-closed"], else: evidence

    %{
      id: "roles.provisioning_locked",
      remediation:
        case remediations do
          [] -> "—"
          rems -> Enum.join(Enum.uniq(rems), " ; ")
        end,
      status: if(evidence == [] and canon != [], do: :pass, else: :fail),
      evidence: evidence,
      note:
        "four-list STRICT equality (BL-6-45): canon{forge_identity} (#{length(canon)} roles, " <>
          "seats included) == forge.tf == ROLES == PROV_ROLES — any delta is a defect, named" <>
          skipped_note(skipped)
    }
  end

  # Sibling trees that are simply NOT PART of this artifact (runtime-only image build stage).
  defp tree_scope(dir), do: if(File.dir?(dir), do: :required, else: :out_of_scope)

  defp split_out_of_scope(lists) do
    {out, kept} = Enum.split_with(lists, fn {_l, scope, _r, _rem} -> scope == :out_of_scope end)
    {Enum.map(kept, fn {l, _scope, r, rem} -> {l, r, rem} end), Enum.map(out, &elem(&1, 0))}
  end

  defp skipped_note([]), do: ""

  defp skipped_note(labels),
    do:
      " · NOT CHECKED here (tree absent from this artifact — runtime-only context): " <>
        Enum.join(labels, ", ")

  # role_index is the role's slot in the hexspeak UUID — the schema bounds it (0..15) per file,
  # nothing enforced uniqueness across the catalogue (BL-6-45 F7): two roles on one slot would
  # make `pkill -f '<X>badcafe'` kill classes collide. Seats included (a seat CLAIMS its slot).
  defp check_roles_role_index_unique(root) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    duplicates =
      scan_catalogue_roles(root)
      |> Enum.filter(&is_integer(&1.role_index))
      |> Enum.group_by(& &1.role_index, & &1.name)
      |> Enum.filter(fn {_idx, names} -> length(names) > 1 end)

    %{
      id: "roles.role_index_unique",
      remediation:
        "two catalogue entries claim the same role_index slot — reassign one (0..15, " <>
          "see each file's metadata comment for the taken slots)",
      status: if(duplicates == [], do: :pass, else: :fail),
      evidence:
        Enum.map(duplicates, fn {idx, names} ->
          "role_index #{idx} claimed by: #{Enum.join(Enum.sort(names), ", ")}"
        end),
      note: "role_index (hexspeak UUID slot) unique across the canon catalogue, seats included"
    }
  end

  # The word "sanctuaire"/"sanctuary" carries a dominant NL prior — sacred, untouchable — and its
  # only antibody is PROSE ("Aucun code n'est sacre", CLAUDE.md; "THIS FILE is NOT the sanctuary",
  # bwrap_launch.sh). Yet prose is the first thing a context compression drops: the word remains,
  # the correction does not. The symptom is measured — an agent refusing to edit the launcher
  # because it read it as sacred.
  #
  # This lock RENAMES nothing (that would be a vocabulary arbitration, not a fix): it stops the word
  # from SPREADING. Three files use it today, each next to its antibody; a fourth would do so
  # without one, and that is exactly how a prior settles in. A lint does not repair a prior, it
  # bounds its surface (BL-6-44).
  # The check's own file is on the list by NECESSITY: it must name the word in order to forbid it.
  # That is the one exemption needing no antibody — a lock does not trap itself.
  @sanctuary_allowed ~w(
    bin/bwrap_launch.sh
    lib/fleet/cap_profile/invariants.ex
    lib/fleet/spawner/pod/launch_spec.ex
    lib/mix/tasks/lcars.contracts.check.ex
  )

  defp check_sanctuary_contained(root) do
    offenders =
      ["lib", "bin", "etc"]
      |> Enum.flat_map(fn d -> Path.wildcard(Path.join([root, d, "**", "*.{ex,exs,sh}"])) end)
      |> Enum.filter(fn f ->
        rel = Path.relative_to(f, root)

        rel not in @sanctuary_allowed and
          match?({:ok, c} when is_binary(c), File.read(f)) and
          File.read!(f) =~ ~r/sanctuaire|sanctuary/i
      end)
      |> Enum.map(&Path.relative_to(&1, root))

    %{
      id: "vocab.sanctuary_contained",
      remediation:
        "le mot « sanctuaire »/« sanctuary » porte un prior NL dominant (sacre, intouchable) que " <>
          "seule de la prose corrige — et la prose est ce qu'une compression de contexte retire " <>
          "d'abord. Employer un terme descriptif (le monde projete, le perimetre du pod), ou " <>
          "ajouter le fichier a @sanctuary_allowed EN Y METTANT l'anticorps",
      status: if(offenders == [], do: :pass, else: :fail),
      evidence: offenders,
      note:
        "le mot reste borne aux #{length(@sanctuary_allowed)} fichiers qui portent son anticorps (BL-6-44)"
    }
  end

  # `provision-lib.sh` is SOURCED, so it inherits its caller's shell flags — it sets none of its
  # own, which is correct for a library (a sourced file imposing `set -e` on its caller changes the
  # caller's error semantics behind its back). The consequence is that its safety belongs to every
  # SOURCER: without `set -u`, an undefined variable expands to the empty string and the recipe
  # silently provisions the wrong thing (BL-6-36, the "silent coercion" class — bash's dialect of
  # `[object Object]`).
  #
  # Measured 2026-08-03: all 11 sourcers set `-euo pipefail`. Nothing held it, so the 12th could
  # omit it and no one would learn until a provisioning run did the wrong thing quietly. This is
  # that hold. Named-file evidence, so a failure says WHICH sourcer, not "some file".
  defp check_sourcers_set_strict(root) do
    # `root` IS fleet/runtime (project_root/0) — the sibling trees hang off `..`, exactly as the
    # four-list check resolves them. Getting this wrong makes the check silently SKIP instead of
    # run, which is the worst of the three outcomes: a green that checked nothing.
    dir = Path.expand("../provisioning_v2", root)

    case tree_scope(dir) do
      :out_of_scope ->
        %{
          id: "shell.sourcers_set_strict",
          remediation: "—",
          status: :pass,
          evidence: [],
          note:
            "NOT CHECKED here (provisioning_v2 absent from this artifact — runtime-only context)"
        }

      :required ->
        offenders =
          [
            Path.join(dir, "modules.d"),
            Path.join(root, "etc")
          ]
          |> Enum.flat_map(fn d -> Path.wildcard(Path.join(d, "*.sh")) end)
          |> Enum.filter(fn f ->
            # `File.read/1`, not the bang: a broken symlink in one of these dirs would crash the
            # whole contracts run, turning a shell-hygiene check into a gate outage.
            case File.read(f) do
              {:ok, content} ->
                String.contains?(content, "provision-lib.sh") and
                  not Regex.match?(~r/^set -[a-z]*u[a-z]*\b/m, content)

              {:error, _} ->
                false
            end
          end)

        %{
          id: "shell.sourcers_set_strict",
          remediation:
            "a script sourcing provision-lib.sh must `set -u` (`set -euo pipefail`): the library " <>
              "sets no flags of its own (correct for a sourced file), so an undefined variable " <>
              "expands to \"\" and the recipe provisions the wrong thing in silence",
          status: if(offenders == [], do: :pass, else: :fail),
          evidence: Enum.map(offenders, &Path.relative_to(&1, Path.expand("..", root))),
          note:
            "every sourcer of provision-lib.sh sets -u (BL-6-36: bash's silent-coercion class)"
        }
    end
  end

  # One provisioning list, read fail-closed: nil when the file or its anchor pattern is absent
  # (partial checkout / renamed variable — the caller renders the named fail, never a silent
  # empty list that would flag every canon role as missing with the wrong message).
  defp read_list(path, regex, format) do
    with {:ok, content} <- File.read(path),
         [_, inner] <- Regex.run(regex, content) do
      case format do
        :plain ->
          inner |> String.split() |> Enum.sort()

        :quoted ->
          ~r/"([^"]+)"/ |> Regex.scan(inner) |> Enum.map(fn [_, s] -> s end) |> Enum.sort()
      end
    else
      _ -> nil
    end
  end

  # The canon catalogue read ONCE for both role checks: name (metadata.name, basename fallback),
  # kind, forge_identity (absent = true), role_index. Underscore basenames = overlay fragments
  # (the `_frozen-monks` convention), excluded like name_index does; undecodable yaml = entry
  # dropped HERE (the boot's name_index fail-louds on it — this check only counts names).
  defp scan_catalogue_roles(root) do
    root
    |> Path.join("priv/catalogue/cap_profile/canon/cap-profiles/*.yaml")
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "_"))
    |> Enum.flat_map(fn path ->
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = raw} ->
          [
            %{
              name: get_in(raw, ["metadata", "name"]) || Path.basename(path, ".yaml"),
              kind: Map.get(raw, "kind"),
              forge_identity: get_in(raw, ["metadata", "forge_identity"]) != false,
              role_index: get_in(raw, ["metadata", "role_index"])
            }
          ]

        _ ->
          []
      end
    end)
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
        code_match?(root, test, ~r/"input_schema"/, [
          ~r/refute\s+Map\.has_key\?/,
          ~r/"input_schema"/
        ])

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

  # ── Tool authorization (A1) ──────────────────────────────────────────
  # `tools/list` is DISCOVERY, not authorization: `tools/call` re-verifies nothing against it.
  # Every pod's MCP session is handed the same tool catalogue, so what stops a producer from
  # calling a destructive project op is never the catalogue — it is the gate on that tool's own
  # dispatch path. The invariant held by discipline alone: nothing refused a new `deftool` wired
  # to an ungated body, and such a tool is callable by ANY pod with nothing said about it.
  #
  # Two admissible forms, and no third:
  #   * POD-SCOPED — the clause head matches `%{pod_id: _}`. Identity is the CHANNEL (one pod, one
  #     socket), never the wire.
  #   * ROLE-GATED — the body calls a `Delegation` function whose own body calls
  #     `require_architect`/`require_onboarder`, which resolve role AND repo from the spawn binding.
  # A clause whose body is a bare `{:error, _, state}` (bad arguments) is inert: it neither needs
  # nor supplies a gate, and a tool made only of those is not gated.
  #
  # INVERSE TWIN, and it is the sharper half: a `handle_tool_call` clause with NO `deftool` schema
  # is not dead code. It is absent from `tools/list` and still dispatched by `tools/call` — a tool
  # that works and that no catalogue admits.
  #
  # Read from the AST, never from a grep: a comment mentioning `require_architect` must not be able
  # to green this check (BND-111, applied to the thing rather than to a stripped line).
  #
  # PUBLIC (@doc false) for the same reason as `code_match?/4`: this check reports ABSENCES, and a
  # broken parser reports the same absences as a clean tree. Its refusals must be provable against
  # CRAFTED fixture trees, not only observed green on the real one — the whole-repo smoke test can
  # never distinguish "nothing wrong" from "nothing measured". It takes its root as an argument
  # precisely so a test can hand it one.
  @doc false
  def check_mcp_tools_gated(root) do
    tools_rel = "lib/fleet/mcp/pod_tools.ex"
    deleg_rel = "lib/fleet/mcp/pod_tools/delegation.ex"

    declared = deftool_names(quoted!(root, tools_rel))
    clauses = dispatch_clauses(quoted!(root, tools_rel))
    gated_fns = role_gated_functions(quoted!(root, deleg_rel))

    ungated =
      declared
      |> Enum.reject(&tool_gated?(Map.get(clauses, &1, []), gated_fns))
      |> Enum.sort()

    undeclared = clauses |> Map.keys() |> Enum.reject(&(&1 in declared)) |> Enum.sort()

    # INSTRUMENT GUARD. Every finding below is an ABSENCE, and an absence is what a broken parser
    # produces too: a `deftool` shape change would empty `declared`, and this check would pass by
    # measuring nothing. The floors are set under the state of the day, not at it — they catch a
    # blind instrument, they do not freeze the tool count.
    broken =
      cond do
        MapSet.size(declared) < 12 ->
          "only #{MapSet.size(declared)} deftool found (expected 12+)"

        map_size(clauses) < 12 ->
          "only #{map_size(clauses)} dispatch clauses found (expected 12+)"

        MapSet.size(gated_fns) < 10 ->
          "only #{MapSet.size(gated_fns)} gated delegations (10+)"

        true ->
          nil
      end

    %{
      id: "mcp.tools_gated",
      remediation:
        "give the tool a gate: pattern-match %{pod_id: _} in its handle_tool_call head " <>
          "(channel identity) or route it through a Delegation function guarded by " <>
          "require_architect/require_onboarder — tools/call does not re-check tools/list",
      status: if(is_nil(broken) and ungated == [] and undeclared == [], do: :pass, else: :fail),
      evidence:
        cond do
          broken ->
            ["#{tools_rel}: INSTRUMENT BROKEN — #{broken}; this check measured nothing"]

          ungated != [] ->
            ["#{tools_rel}: ungated tools #{inspect(ungated)}"]

          undeclared != [] ->
            ["#{tools_rel}: dispatched without a deftool #{inspect(undeclared)}"]

          true ->
            []
        end,
      note:
        "#{MapSet.size(declared)} tools, each pod-scoped or role-gated; " <>
          "#{MapSet.size(gated_fns)} delegations carry a require_* gate"
    }
  end

  # ── Seam surface ─────────────────────────────────────────────────────
  # The `conforming/2` guard turns a misconfigured seam into a named error instead of an
  # UndefinedFunctionError raised deep inside a half-finished gesture. It can only see what a
  # behaviour DECLARES — so a seam op nobody wrote down is a call the guard vouches for without
  # having checked it. Measured 2026-08-04: 12 callbacks declared, 16 functions called; the three
  # dependency ops ran inside the supersede retirement, past the point where the live PR is already
  # closed, guarded by nothing.
  #
  # `Delegation` reaches its seams ONLY through a variable holding a resolved module (the guard
  # hands it over). So every remote call on a variable in that file is a seam call and must be
  # declared by one of the four behaviours. One exception, named rather than pattern-matched away:
  # `behaviour.behaviour_info/1` is the guard reflecting ON a behaviour module, not a call THROUGH
  # a seam.
  @seam_behaviours [
    Fleet.MCP.PodTools.Delegation.ForgeClient,
    Fleet.MCP.PodTools.Delegation.EscalationForge,
    Fleet.MCP.PodTools.Delegation.DependencyForge,
    Fleet.MCP.PodTools.Delegation.ProjectOnboard
  ]

  # Reflection on a behaviour module, not a seam op. The ONLY admitted exception.
  @seam_reflection [behaviour_info: 1]

  @doc false
  def check_mcp_seam_surface(root, behaviours \\ @seam_behaviours) do
    deleg_rel = "lib/fleet/mcp/pod_tools/delegation.ex"

    called = seam_calls(quoted!(root, deleg_rel))

    declared =
      behaviours
      |> Enum.flat_map(fn b ->
        Code.ensure_loaded!(b)
        b.behaviour_info(:callbacks)
      end)
      |> MapSet.new()

    undeclared =
      called
      |> Enum.reject(fn {fun, arity} ->
        MapSet.member?(declared, {fun, arity}) or {fun, arity} in @seam_reflection
      end)
      |> Enum.sort()

    # INSTRUMENT GUARD: both sides of the comparison can go empty on their own. An AST shape change
    # empties `called` and everything is declared; a behaviour that stops resolving empties
    # `declared` and everything is undeclared — the second is loud, the first is silent.
    broken =
      cond do
        length(called) < 15 -> "only #{length(called)} seam calls found (expected 15+)"
        MapSet.size(declared) < 20 -> "only #{MapSet.size(declared)} callbacks declared (20+)"
        true -> nil
      end

    %{
      id: "mcp.seam_surface_declared",
      remediation:
        "declare the op as a @callback of the behaviour that covers its path " <>
          "(ForgeClient / EscalationForge / DependencyForge / ProjectOnboard) — " <>
          "conforming/2 vouches only for what a behaviour declares",
      status: if(is_nil(broken) and undeclared == [], do: :pass, else: :fail),
      evidence:
        cond do
          broken ->
            ["#{deleg_rel}: INSTRUMENT BROKEN — #{broken}; this check measured nothing"]

          undeclared != [] ->
            ["#{deleg_rel}: called through a seam, declared nowhere: #{inspect(undeclared)}"]

          true ->
            []
        end,
      note:
        "#{length(called)} seam calls covered by #{MapSet.size(declared)} callbacks " <>
          "over #{length(behaviours)} behaviours"
    }
  end

  # Remote calls on a VARIABLE (`forge.close_pr(...)`), which in `Delegation` are seam calls and
  # nothing else. `no_parens` nodes are field access (`identity.token`), not calls.
  defp seam_calls(ast) do
    ast
    |> collect(fn
      {{:., _, [{var, _, nil}, fun]}, meta, args} when is_atom(var) and is_atom(fun) ->
        if meta[:no_parens] == true, do: nil, else: {fun, length(args)}

      _ ->
        nil
    end)
    |> Enum.uniq()
  end

  # ── Forge payload fields: received, and read? ────────────────────────
  # PROBE N°1 of the 2026-08-04 pattern hunt, promoted from a one-off command to a wall.
  #
  # The forge hands back whole objects. The code picks what it needs and the rest is dropped
  # silently — which is correct, right up until the dropped part is the answer to a question someone
  # is reconstructing from the outside. Measured that day: `submitted_at`, `merged_at`, `closed_at`
  # and `html_url` arrived in payloads already fetched (`get_pull`, `get_issue`, `reviews`) and NO
  # line of `lib/` touched them. That list was EXACTLY what the architect had spent three campaigns
  # rebuilding — and one command produced it, with no bench and no agent.
  #
  # `submitted_at` has three readers since 2026-08-05 (the reviews now carry their substance to the
  # arch), which is the probe having already paid for itself.
  #
  # WHAT THIS IS NOT: a demand that every field be consumed. Most have no business being read. The
  # wall is on the DECISION: a field is read, or it is listed below with what we know about why. An
  # entry with no recorded reason says so in those words — an allowlist that invents rationales is
  # worse than one that admits it is a queue.
  #
  # FROZEN at the current state, per the arbitration: this catches a field that LOSES its last
  # reader, and a new field added to the inventory without a decision. It does not re-litigate the
  # past.
  @forge_read_fields ~w(state merged number title body labels commit_id dismissed login head base
                        sha assignees full_name submitted_at created_at updated_at)

  @forge_unread_fields %{
    "merged_at" =>
      "the merge is PROVEN by the `stage/merged` label (WS1, set by the seal at merge); a " <>
        "timestamp would be a second source of the same fact, and the two can disagree",
    "closed_at" =>
      "no decision recorded — not read, no reason established. A candidate for the next pass, " <>
        "not a justification",
    "html_url" =>
      "URLs are composed from repo + number against the configured base_url; a forge-supplied " <>
        "one would carry whatever host answered, which is not necessarily the one we address"
  }

  # EVERY test corpus in the repo — bats AND python — and what happens to it. `:gated` = shell_gate discovers it;
  # `{:out, why}` = deliberately outside, ON RECORD. A corpus absent from this map fails the check.
  #
  # WHY THIS EXISTS, and it cost three findings in one evening (2026-08-05): nothing in this repo
  # answered "which test corpora exist, and which ones do we run". `fleet/provisioning_v2/tests`
  # and `fleet/git-hooks/tests` had never been run by any gate, and `fleet/tests/unit/v1` had been
  # failing at `setup` on all 447 of its cases since a tidying commit moved the paths out from under
  # it. All three were found by a `find` run out of curiosity. A corpus nobody runs does not rot
  # loudly — it rots while reporting a coverage it does not provide, which is the most expensive
  # silence a test can keep.
  @test_corpora [
    {"fleet/runtime/test", :gated},
    {".claude/skills", :gated},
    {"fleet/provisioning_v2/tests", :gated},
    {"fleet/git-hooks/tests", :gated},
    {"fleet/tests/python/v1",
     {:out, "v1 python smoke, frozen with the rest of v1 — same decision as the v1 bats corpus"}},
    {"PoC",
     {:out,
      "prototypes kept as EVIDENCE of an experiment. A PoC owes a reader its result, never a green " <>
        "suite, and gating one would make the product answer for a question already answered"}},
    {"fleet/tests/.bats",
     {:out, "vendored bats-core + its helper libraries: upstream's own suites, not ours to run"}},
    {"fleet/tests/unit/v1",
     {:out,
      "v1 frozen since 2026-04-18; 246 of 447 cases still red after the BL-6-68 repair. Gating it " <>
        "would turn the gate red on code nobody changes, and the remaining failures are a decision " <>
        "about whether v1 is maintained, not a repair"}}
  ]

  @doc false
  def check_test_corpora_on_record(root) do
    repo = Path.expand("../..", root)

    # `-type f` is load-bearing: `fleet/tests/.bats` is a DIRECTORY whose name matches `*.bats`, and
    # without it the scan reports a corpus that is a folder.
    found =
      case System.cmd(
             "find",
             [
               repo,
               "-type",
               "f",
               "(",
               "-name",
               "*.bats",
               "-o",
               "-name",
               "test_*.py",
               "-o",
               "-name",
               "*_test.py",
               ")",
               "-not",
               "-path",
               "*/.git/*",
               "-not",
               "-path",
               "*/_build/*",
               "-not",
               "-path",
               # `*/fleet/runtime/tmp/*`, NOT `*/tmp/*`: the second excludes any path containing
               # "tmp" ANYWHERE, which silently blanks the scan on a tree living under /tmp — a
               # filter broad enough to make the instrument measure nothing and report a pass. Its
               # own test caught it, by building its fixtures exactly there.
               "*/fleet/runtime/tmp/*",
               # VENDORED python, the twin of the `.bats` submodules: a virtualenv's site-packages
               # carries hundreds of upstream suites. They are not ours to run and not ours to
               # declare — excluding them is the declaration.
               "-not",
               "-path",
               "*/.venv/*",
               "-not",
               "-path",
               "*/site-packages/*"
             ],
             stderr_to_stdout: true
           ) do
        {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&Path.relative_to(&1, repo))
        _ -> []
      end

    unknown =
      found
      |> Enum.reject(fn f ->
        Enum.any?(@test_corpora, fn {p, _} -> String.starts_with?(f, p <> "/") end)
      end)
      |> Enum.map(&Path.dirname/1)
      |> Enum.uniq()

    broken =
      cond do
        not File.dir?(Path.join(repo, "fleet/runtime/test")) ->
          "#{repo} does not look like the repo root — nothing was scanned"

        found == [] ->
          "no .bats file found under #{repo}; this check measured nothing"

        true ->
          nil
      end

    gated = Enum.count(@test_corpora, fn {_, v} -> v == :gated end)

    %{
      id: "tests.corpora_on_record",
      remediation:
        "wire the corpus into test/shell_gate.sh, or add it to @test_corpora as {:out, why} — " <>
          "a corpus nobody runs reports a coverage it does not provide",
      status: if(is_nil(broken) and unknown == [], do: :pass, else: :fail),
      evidence:
        cond do
          broken -> ["INSTRUMENT BROKEN — #{broken}"]
          unknown != [] -> ["test corpora on no record: #{inspect(unknown)}"]
          true -> []
        end,
      note:
        "#{length(found)} test files (bats + python) over #{length(@test_corpora)} corpora — " <>
          "#{gated} gated, #{length(@test_corpora) - gated} deliberately out ON RECORD"
    }
  end

  @doc false
  # ONE FACT, TWO RENDERS — the hard ceiling on a project's in-flight workflow_runs. It is typed in
  # Elixir (`Admission.max_fan_ceiling/0`, itself derived from the pool seats a role actually has)
  # and AGAIN in `intensity-v1.json`, because a JSON Schema cannot call a function. The declaration
  # a human writes is validated by the schema; the value the dispatcher enforces comes from the
  # module. Let those two drift and a project declares a throughput the schema accepts and the
  # engine silently clamps away — a declaration that validates and does not apply, which is the
  # worst of the three possible outcomes.
  def check_intensity_max_fan_ceiling(root) do
    path = Path.join([root, "priv", "cap_profile", "schema", "intensity-v1.json"])
    src = Path.join([root, "lib", "fleet", "pilot", "poller", "admission.ex"])

    # Read from the SOURCE, never by calling `Admission.max_fan_ceiling/0`. Two reasons, and the
    # first is the one that bites: `Admission` is not exported by the `Fleet.Pilot` boundary, and
    # widening an export so a checker can peek is the reflex the boundary exists to refuse. The
    # second is the older rule of this file — a gate instrument MEASURES the tree, it does not run
    # the product; a check that needs the app compiled cannot report on a tree that does not build.
    module_ceiling =
      with {:ok, code} <- File.read(src),
           [_, n] <- Regex.run(~r/@max_max_fan\s+(\d+)/, code) do
        String.to_integer(n)
      else
        _ -> nil
      end

    schema_ceiling =
      with {:ok, raw} <- File.read(path),
           {:ok, json} <- Jason.decode(raw),
           %{"maximum" => max} <- get_in(json, ["properties", "max_fan"]) do
        max
      else
        _ -> nil
      end

    broken =
      cond do
        is_nil(schema_ceiling) -> "#{path} has no properties.max_fan.maximum — nothing to compare"
        is_nil(module_ceiling) -> "#{src} has no @max_max_fan — nothing to compare"
        true -> nil
      end

    %{
      id: "intensity.max_fan_ceiling",
      remediation:
        "make properties.max_fan.maximum in intensity-v1.json equal " <>
          "Admission.max_fan_ceiling/0 — the module is the authority, the schema is its render",
      status: if(is_nil(broken) and schema_ceiling == module_ceiling, do: :pass, else: :fail),
      evidence:
        cond do
          broken ->
            ["INSTRUMENT BROKEN — #{broken}; this check measured nothing"]

          schema_ceiling != module_ceiling ->
            ["schema says #{schema_ceiling}, module says #{module_ceiling}"]

          true ->
            []
        end,
      note:
        "max_fan ceiling agrees: schema #{inspect(schema_ceiling)} = @max_max_fan #{inspect(module_ceiling)}"
    }
  end

  @doc false
  def check_forge_fields_read(root) do
    lib = Path.join(root, "fleet/runtime/lib")
    lib = if File.dir?(lib), do: lib, else: Path.join(root, "lib")

    unread = Enum.reject(@forge_read_fields, &field_read?(lib, &1))
    resurrected = Enum.filter(Map.keys(@forge_unread_fields), &field_read?(lib, &1))

    # INSTRUMENT GUARD: the whole check is a set of greps over a tree. A wrong root, a moved lib/,
    # and every field reads as unread — a loud failure, which is survivable — or the inventory goes
    # empty and everything passes, which is not.
    broken =
      cond do
        not File.dir?(lib) -> "lib/ not found under #{root}"
        length(@forge_read_fields) < 10 -> "inventory shrank to #{length(@forge_read_fields)}"
        true -> nil
      end

    %{
      id: "forge.payload_fields_read",
      remediation:
        "either read the field where it answers a real question, or move it to " <>
          "@forge_unread_fields WITH what is known about why — including \"no reason recorded\" " <>
          "when that is the truth",
      status: if(is_nil(broken) and unread == [] and resurrected == [], do: :pass, else: :fail),
      evidence:
        cond do
          broken -> ["INSTRUMENT BROKEN — #{broken}; this check measured nothing"]
          unread != [] -> ["fields that LOST their last reader: #{inspect(Enum.sort(unread))}"]
          resurrected != [] -> ["now read, remove from the allowlist: #{inspect(resurrected)}"]
          true -> []
        end,
      note:
        "#{length(@forge_read_fields)} fields read, #{map_size(@forge_unread_fields)} deliberately " <>
          "not (1 of them with no reason recorded — that is a queue, not an answer)"
    }
  end

  # ── Forge mutations: which have a door, and for whom ─────────────────
  # PROBE N°4 of the pattern hunt — "a gesture with no door". The family that produced the five
  # tools of lot 1: `retire_issue`, `publish_doc`, `list_projects`, `emergency_stop` all existed as
  # CAPABILITIES the runtime could already execute, and had to be disguised as something else (or
  # were simply unreachable) for want of a tool exposing them. An absence raises no error, which is
  # why it survives: nothing fails, the gesture is just performed sideways.
  #
  # Mechanised as a two-column table the gate holds: every mutating op of the forge client is either
  # REACHED from a delegation tool, or listed here with why it is runtime-only. The runtime-only
  # answer is the common and correct one — the point is that it becomes a decision on record rather
  # than an omission nobody looked at.
  #
  # `merged_pr_of_issue` is not in the inventory: its name reads like a mutation and it is a READ
  # (it finds the merged PR of an issue). Named here because the next reader will wonder.
  @forge_mutations ~w(add_issue_dependency add_label close_issue close_pr create_branch
                      create_issue merge_pr post_comment post_review post_route
                      remove_issue_dependency remove_label)

  @forge_mutations_runtime_only %{
    "create_branch" =>
      "the feature branch is cut by the dispatch, from the base the card decided; an agent " <>
        "choosing where to cut would decide the face, which is not its call",
    "merge_pr" =>
      "the merge is the gatekeeper seal's, behind branch protection and the jury; a tool would " <>
        "put a second door on the one gesture the whole rail exists to guard",
    "post_review" =>
      "a native review carries a VERDICT and the merge gate counts approvals; the judge posts " <>
        "through its step, never as a tool it could call twice",
    "post_route" =>
      "the route is engraved by the burn from the project card — an agent writing it would " <>
        "choose its own pipeline",
    "add_label" =>
      "labels are the forge-side state machine (`stage/*`, `wait/*`); a tool would let an actor " <>
        "write the state instead of reaching it",
    "remove_label" => "same reason as `add_label` — the state is reached, never set"
  }

  @doc false
  def check_forge_mutations_exposed(root) do
    deleg_rel = "lib/fleet/mcp/pod_tools/delegation.ex"
    path = Path.join(root, deleg_rel)

    called =
      if File.exists?(path) do
        path
        |> File.read!()
        |> Code.string_to_quoted!()
        |> seam_calls()
        |> MapSet.new(&elem(&1, 0))
      else
        MapSet.new()
      end

    undecided =
      Enum.reject(@forge_mutations, fn m ->
        MapSet.member?(called, String.to_atom(m)) or
          Map.has_key?(@forge_mutations_runtime_only, m)
      end)

    stale = Enum.filter(Map.keys(@forge_mutations_runtime_only), &(&1 not in @forge_mutations))

    broken =
      cond do
        not File.exists?(path) -> "#{deleg_rel} not found under #{root}"
        length(@forge_mutations) < 8 -> "inventory shrank to #{length(@forge_mutations)}"
        MapSet.size(called) < 5 -> "only #{MapSet.size(called)} seam calls parsed"
        true -> nil
      end

    %{
      id: "forge.mutations_exposed",
      remediation:
        "expose the capability through a gated delegation tool, or record it in " <>
          "@forge_mutations_runtime_only with WHY it stays runtime-only",
      status: if(is_nil(broken) and undecided == [] and stale == [], do: :pass, else: :fail),
      evidence:
        cond do
          broken -> ["INSTRUMENT BROKEN — #{broken}; this check measured nothing"]
          undecided != [] -> ["mutations with no door and no decision: #{inspect(undecided)}"]
          stale != [] -> ["listed runtime-only but no longer a mutation: #{inspect(stale)}"]
          true -> []
        end,
      note:
        "#{length(@forge_mutations)} forge mutations — " <>
          "#{length(@forge_mutations) - map_size(@forge_mutations_runtime_only)} reachable by a " <>
          "tool, #{map_size(@forge_mutations_runtime_only)} runtime-only ON RECORD"
    }
  end

  # A quoted key anywhere in `lib/`, MINUS `lib/mix/tasks/`. Deliberately coarse on the pattern: the
  # question is "does anything in this code touch that name", and a stricter parse would answer a
  # narrower one.
  #
  # THE EXCLUSION IS THE LOAD-BEARING PART, and the first run proved it: the allowlist below LIVES in
  # this file, so `"closed_at" =>` counted as a reader and all three deliberately-unread fields
  # reported themselves as read. The instrument was measuring its own declaration — the exact defect
  # class this check exists to catch, arriving first in the check itself.
  #
  # Gate tooling is excluded on its own merit too: a field named in a mix task is named by the
  # machinery that audits the product, not by the product answering a question with it.
  defp field_read?(lib, field) do
    args = ["-rq", "--include=*.ex", "--exclude-dir=tasks", ~s("#{field}"), lib]

    case System.cmd("grep", args, stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp quoted!(root, rel), do: root |> Path.join(rel) |> File.read!() |> Code.string_to_quoted!()

  # `deftool "name" do … end` — the schemas advertised by `tools/list`.
  defp deftool_names(ast) do
    ast
    |> collect(fn
      {:deftool, _, [name | _]} when is_binary(name) -> name
      _ -> nil
    end)
    |> MapSet.new()
  end

  # `def handle_tool_call("name", args, state)` clauses, grouped by tool name. The catch-all
  # (`handle_tool_call(_unknown, …)`) has no literal name and is skipped: it refuses by definition.
  defp dispatch_clauses(ast) do
    ast
    |> collect(fn
      {:def, _, [head, [do: body]]} -> dispatch_clause(head, body)
      _ -> nil
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp dispatch_clause({:when, _, [inner, _guard]}, body), do: dispatch_clause(inner, body)

  defp dispatch_clause({:handle_tool_call, _, [name, _args, state]}, body) when is_binary(name),
    do: {name, %{state: state, body: body}}

  defp dispatch_clause(_head, _body), do: nil

  # A `Delegation` function whose own body reaches a role gate. `Macro.to_string/1` on the BODY AST,
  # so a `require_architect` written in a comment is not in the tree and cannot answer for it.
  defp role_gated_functions(ast) do
    ast
    |> collect(fn
      {:def, _, [head, [do: body]]} ->
        name = def_name(head)

        if name && Macro.to_string(body) =~ ~r/require_(architect|onboarder)\(/,
          do: name,
          else: nil

      _ ->
        nil
    end)
    |> MapSet.new()
  end

  defp def_name({:when, _, [inner, _guard]}), do: def_name(inner)
  defp def_name({name, _, _args}) when is_atom(name), do: name
  defp def_name(_), do: nil

  # Gated = every clause is pod-scoped, role-gated or inert, AND at least one actually carries a
  # gate. A tool made only of refusals is not "safe by absence" — it is a tool that does nothing,
  # and it should not be advertised.
  defp tool_gated?([], _gated_fns), do: false

  defp tool_gated?(clauses, gated_fns) do
    Enum.all?(clauses, &clause_ok?(&1, gated_fns)) and
      Enum.any?(clauses, &(pod_scoped?(&1) or role_gated?(&1, gated_fns)))
  end

  defp clause_ok?(clause, gated_fns),
    do: pod_scoped?(clause) or role_gated?(clause, gated_fns) or inert?(clause)

  defp pod_scoped?(%{state: state}), do: Macro.to_string(state) =~ ~r/\bpod_id:/

  defp role_gated?(%{body: body}, gated_fns) do
    body
    |> collect(fn
      {{:., _, [{:__aliases__, _, aliases}, fun]}, _, _} ->
        if List.last(aliases) == :Delegation, do: fun, else: nil

      _ ->
        nil
    end)
    |> Enum.any?(&MapSet.member?(gated_fns, &1))
  end

  # A bare `{:error, reason, state}` return: no gate, no work.
  defp inert?(%{body: {:{}, _, [:error | _]}}), do: true
  defp inert?(_), do: false

  # Walks an AST and keeps every non-nil result of `fun`.
  defp collect(ast, fun) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case fun.(node) do
          nil -> {node, acc}
          value -> {node, [value | acc]}
        end
      end)

    Enum.reverse(acc)
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
