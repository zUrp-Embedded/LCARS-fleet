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
  Runs the compiled-source checks without printing or exiting.
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
        check_catalogue_before_freeze(root),
        check_event_registry_loaded_before_children(root),
        # ── Authority locks (Z7 — one fact = one source, cross-language) ──
        check_roles_provisioning_locked(root),
        check_roles_role_index_unique(root),
        check_sourcers_set_strict(root),
        check_face_roots_provisioned(root),
        check_gitea_template_expansion(root),
        check_awaits_arch_clears_in_flight(root),
        check_sanctuary_contained(root),
        check_no_legacy_config_namespace(root),
        check_mcp_wire_inputschema(root),
        check_mcp_tools_gated(root),
        check_mcp_tool_effects(root),
        check_cap_profile_project_keys(root),
        check_modop_tools_granted(root),
        check_proven_image_regime(root),
        check_verifier_covers_rail(root),
        check_capabilities_exercisable(root),
        check_catalogue_paths_locked(root),
        check_eval_doors_start_transport(root),
        check_mcp_seam_surface(root),
        check_forge_fields_read(root),
        check_forge_mutations_exposed(root),
        check_intensity_max_fan_ceiling(root),
        check_test_corpora_on_record(root),
        check_doctest_declarations_have_examples(root),
        check_public_functions_documented(root)
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
  @doc false
  def check_event_consumers_canon(root) do
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
  @doc false
  def check_pipeline_v25_normalized(root) do
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
  @doc false
  def check_events_handlers_exist(root) do
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
  @doc false
  def check_coord_backend_wired(root) do
    # MOITIE SURVIVANTE d'une gate a deux moitiés : l'autre grepait `lib/fleet/coord/**` pour le
    # placeholder `NotWiredYet` — le domaine `Fleet.Coord` est parti entier (brouette 2026-08-19,
    # rail decision = telemetrie sans acte), il n'y a plus de source a sonder. Ce qui reste a
    # garder : `Workflow.Gates` est PUR — aucune delegation coord ne doit y reapparaitre (le gate
    # LLM vit chez le gatekeeper, jamais dans une machinerie systeme).
    gates_path = Path.join(root, "lib/fleet/workflow/gates.ex")

    gates_coord_dep =
      gates_path
      |> grep_lines(~r/coord_backend|CoordBackend/)
      |> Enum.filter(fn {_ln, line} ->
        Regex.match?(~r/coord_backend|CoordBackend/, strip_comment(line))
      end)
      |> Enum.map(fn {ln, _} -> "lib/fleet/workflow/gates.ex:#{ln}" end)

    if not File.exists?(gates_path) do
      broken_result("coord.backend.wired_or_pure", "lib/fleet/workflow/gates.ex")
    else
      %{
        id: "coord.backend.wired_or_pure",
        remediation:
          "keep the LLM gate on the gatekeeper (pure Gates) — no coord delegation may reappear",
        status: if(gates_coord_dep == [], do: :pass, else: :fail),
        evidence: gates_coord_dep,
        note: "Gates purity (the coord-lib half of this gate died with Fleet.Coord, 2026-08-19)"
      }
    end
  end

  # `compose_claude_md/3` must read `spec.invocation.lifetime_scope` (the canonical
  # v2.5 schema), not `spec.lifetime_scope` (pre-v2.5 form) — otherwise the pod's CLAUDE.md
  # always shows "unknown". The twin `check_lifetime_scope/1` (cap_profile.ex)
  # already reads the right path.
  # The pattern covers get_in (list form `spec, ["lifetime_scope"]`) AND Map.get
  # (string form `spec, "lifetime_scope"`) — future-proof against a regression that
  # would reintroduce the wrong path under another form.
  @doc false
  def check_capprofile_lifetime_scope_path(root) do
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
  @doc false
  def check_capprofile_modop_incompatible_path(root) do
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
  @doc false
  def check_launch_backend_containment(root) do
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
  @doc false
  def check_mcp_required_real_backend(root) do
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
  @doc false
  def check_spawn_has_brief(root) do
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
  @doc false
  def check_skills_declared_present(root) do
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
  @doc false
  def check_events_registry_keys_aligned(root) do
    registry = registry_event_keys(root)

    consumed =
      Path.wildcard(Path.join(root, "lib/**/*.ex"))
      |> Enum.flat_map(&consumed_event_types/1)
      |> Enum.uniq()

    unregistered = Enum.reject(consumed, &MapSet.member?(registry, &1))

    # BOTH sides are the population here: an empty registry makes every consumed type unregistered
    # (loud, fine), but an empty SOURCE set makes `consumed` empty and the wall green about a code
    # base it never opened.
    cond do
      measured_nothing?(registry) ->
        broken_result("events.registry.keys_aligned", "key in events.yaml")

      measured_nothing?(Path.wildcard(Path.join(root, "lib/**/*.ex"))) ->
        broken_result("events.registry.keys_aligned", "source under lib/")

      true ->
        %{
          id: "events.registry.keys_aligned",
          remediation:
            "add the consumed type(s) to events.yaml (every handle_info %Fleet.Event{type:} must be a registry key)",
          status: if(unregistered == [], do: :pass, else: :fail),
          evidence: Enum.map(unregistered, &"consumed type outside registry: #{&1}"),
          note: "every consumed type (handle_info %Fleet.Event{type:}) must be an events.yaml key"
        }
    end
  end

  @doc """
  Every site that SETS `awaits-arch` must CLEAR `in-flight` in the same file.

  The invariant was stated in three places and guarded in none, so two writers honoured it and the
  third did not — and the registry that was supposed to record which is which had itself gone
  stale. A wall makes the registry's accuracy irrelevant: the property holds whether or not anyone
  remembered to write it down.

  What the third writer cost, observed on the bench: `awaits-arch` takes a ticket out of dispatch
  but the in-flight lock stays. Reconciliation then finds that lock orphaned (no live pod),
  reclaims it, re-dispatches — and a fresh pod goes to block in the same place, every tick, until a
  human closes the ticket. The brake was on and the wheel kept turning.

  Clearing is any of the three real shapes: `remove_label` with the in-flight label,
  `StepRunCompleter.unlock/6` (which removes it, stops the role stopwatch and emits
  `step.unlocked`), or the `@in_flight_label` attribute passed to a removal. File granularity is
  deliberate — the pairing is a property of the escalation PATH, and a checker chasing it across
  call boundaries would be guessing.

  ## What this check does NOT see, and what does

  Measured with two mutations. Strip the clearing from a writer entirely and this check FAILS,
  naming the file. Strip only the CALL and leave the clearing function behind, and this check
  PASSES — file granularity cannot tell a live helper from a dead one.

  That second one is caught, but by the compiler: an unused private function is a warning, and the
  gate compiles `--warnings-as-errors`. The two layers compose and neither covers the other, which
  is worth stating because the obvious "improvement" — chasing the call graph here — would trade a
  precise wall for a guessing one and cover nothing new.
  """
  @spec check_awaits_arch_clears_in_flight(Path.t()) :: map()
  def check_awaits_arch_clears_in_flight(root) do
    sources = Path.wildcard(Path.join(root, "lib/**/*.ex"))

    writers = Enum.filter(sources, &sets_awaits_arch?/1)

    setters =
      writers
      |> Enum.reject(&clears_in_flight?/1)
      |> Enum.map(&Path.relative_to(&1, root))

    # The population is the SETTERS, and an empty one is not a green: it means the reader stopped
    # seeing the label writers — the exact way a wall goes quiet while the code drifts underneath.
    cond do
      measured_nothing?(sources) ->
        broken_result("labels.awaits_arch_clears_in_flight", "source under lib/")

      measured_nothing?(writers) ->
        broken_result("labels.awaits_arch_clears_in_flight", "site setting awaits-arch")

      true ->
        %{
          id: "labels.awaits_arch_clears_in_flight",
          remediation:
            "clear `lcars-in-flight` on that path (remove_label, or StepRunCompleter.unlock/6 when " <>
              "the role identity is known) — awaits-arch alone stops the dispatch but leaves a lock " <>
              "that reconciliation reclaims and re-dispatches",
          status: if(setters == [], do: :pass, else: :fail),
          evidence: Enum.map(setters, &"sets awaits-arch without clearing in-flight: #{&1}"),
          note:
            "every awaits-arch writer releases the in-flight lock in the same file " <>
              "(#{length(writers)} writer(s) measured: #{Enum.map_join(writers, ", ", &Path.relative_to(&1, root))})"
        }
    end
  end

  # ANCHORED ON THE CALL, not on the file. The first version asked "does this file mention
  # add_label AND the awaits-arch label?" and flagged `pod_tools/delegation.ex`, which READS the
  # label to list the arch's escalation inbox and adds an unrelated one. A file-level co-occurrence
  # answers a neighbouring question, and the answer looks like a finding.
  #
  # The label may arrive as `@attr` or as the accessor call, so the argument span has to tolerate
  # ONE level of nesting (`Fleet.Labels.awaits_arch()` carries its own parens) — a plain `[^)]*`
  # stops at that inner paren and sees nothing. Newlines are allowed on purpose: all three real
  # sites keep the label on the call's line today, and a checker that silently depends on that
  # would go quiet the day someone reformats.
  @label_arg_span "(?:[^()]|\\([^()]*\\)){0,200}?"

  defp sets_awaits_arch?(path),
    do: calls_with_label?(path, "add_label", "@awaits_arch_label|Labels\\.awaits_arch\\(\\)")

  defp clears_in_flight?(path) do
    # `unlock/6` is the third real shape: it removes the label AND stops the role stopwatch AND
    # emits `step.unlocked`. A site delegating to it clears the lock without naming it.
    calls_with_label?(path, "remove_label", "@in_flight_label|Labels\\.in_flight\\(\\)") or
      match_source?(path, ~r/\bunlock\(/)
  end

  defp calls_with_label?(path, fun, label_alt) do
    match_source?(path, Regex.compile!("#{fun}\\(#{@label_arg_span}(#{label_alt})", "s"))
  end

  defp match_source?(path, re) do
    case File.read(path) do
      {:ok, src} -> Regex.match?(re, src)
      _ -> false
    end
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
  @doc false
  def check_no_cowboy_bypass(root) do
    builder = "lib/fleet/event_router/listener.ex"

    lib_sources = Path.wildcard(Path.join(root, "lib/**/*.ex"))

    bypass =
      lib_sources
      |> Enum.reject(&(Path.relative_to(&1, root) == builder))
      |> Enum.flat_map(fn file ->
        file
        |> grep_lines(~r/\{Plug\.Cowboy,/)
        |> Enum.filter(fn {_ln, line} ->
          Regex.match?(~r/\{Plug\.Cowboy,/, strip_comment(line))
        end)
        |> Enum.map(fn {ln, _} -> "#{Path.relative_to(file, root)}:#{ln}" end)
      end)

    # The BUILDER is part of the population too: this wall says "nobody but the listener builds a
    # Cowboy child", and if the listener itself has moved, the sentence is about nothing.
    if measured_nothing?(lib_sources) or not File.exists?(Path.join(root, builder)) do
      broken_result("listener.no_cowboy_bypass", "source under lib/ (or the listener itself)")
    else
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
  @doc false
  def check_result_deadline_cancelled(root) do
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
  @doc false
  def check_spawn_gates_wired(root) do
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
  @doc false
  def check_gatekeeper_not_a_step(root) do
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
  @doc false
  def check_verdict_envelope_unwrapped(root) do
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
  # (config/runtime.exs). Red if it disappears; this check guards its PRESENCE, not its shape —
  # the guard is unconditional on environment, and this wall stays green either way. Post-strip
  # confirmation looser than the grep (`root` alone): the long marker may live partly
  # in a comment on the line, only `root` needs to survive in the code.
  @doc false
  def check_no_root_runtime_guard(root) do
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
  # POPULATION GUARD — zero subjects and zero violations are indistinguishable at the output of an
  # absence-of-violation wall. Every check below that answers "nothing violates X" owes its reader
  # the count it looked at: a glob that matches nothing, a registry that loads empty, a directory
  # that moved, all read as compliance otherwise. The probe that finds them: point the checker at an
  # EMPTY tree and read what still returns `pass` (BL-6-70). Walls whose subject has moved out from
  # under them are the ones it catches, and a subject moves in the same commit that adds the wall.
  # Two clauses, and no third for integers: nothing counts before asking. A speculative clause is a
  # branch no test can reach and no reader can trust — dialyzer named it, and it was right.
  defp measured_nothing?(population) when is_list(population), do: population == []
  defp measured_nothing?(%MapSet{} = population), do: MapSet.size(population) == 0

  defp broken_result(id, what) do
    %{
      id: id,
      remediation:
        "point the check at a tree that contains its subject, or fix the path it scans",
      status: :fail,
      evidence: ["INSTRUMENT BROKEN — no #{what} found; this check measured nothing"],
      note: "population empty"
    }
  end

  defp residue_check(root, opts) do
    confirm = Map.get(opts, :confirm) || opts.pattern

    evidence =
      Enum.flat_map(opts.files, fn rel ->
        abs = Path.join(root, rel)

        # HOLLOW-GREEN GUARD (R0-EVT-012): a residue check greps FIXED file paths; a file it cannot
        # read yields 0 residue → `:pass` FOREVER, even though the target moved/was deleted and the
        # contract is no longer verified. A residue target the check cannot read is therefore a
        # FAILURE, not a silent green.
        #
        # ONE read, and it decides both. `File.exists?/1` answered only the ABSENT half: it is TRUE
        # for a file present and unreadable (permissions, I/O error, a path that became a
        # directory), which sent the flow into the reading branch where the swallowed error became
        # zero lines, i.e. compliance. The half that was guarded is the half a moved file trips; the
        # half that was not is the one a chmod trips, and nothing in the output told them apart.
        # Reading once also removes the window between the test and the read.
        case File.read(abs) do
          {:ok, content} ->
            content
            |> grep_content(opts.pattern)
            |> Enum.filter(fn {_ln, line} -> Regex.match?(confirm, strip_comment(line)) end)
            |> Enum.map(fn {ln, _} -> "#{rel}:#{ln}" end)

          {:error, reason} ->
            [
              "#{rel}:MISSING(#{reason}) — residue-check target unreadable " <>
                "(hollow-green guard, R0-EVT-012)"
            ]
        end
      end)

    # The existing hollow-green guard below covers a NAMED file that vanished. It cannot cover a
    # GLOB that matched nothing: the flat_map produces no evidence and the wall reports compliance
    # about a set it never had. Same defect, one level up.
    if measured_nothing?(opts.files) do
      broken_result(opts.id, "file to scan")
    else
      %{
        id: opts.id,
        remediation: opts.remediation,
        status: if(evidence == [], do: :pass, else: :fail),
        evidence: evidence,
        note: opts.note
      }
    end
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
  #
  # ABSENCE AND UNREADABILITY ARE NOT THE SAME FAULT, and one `_ -> []` used to answer both.
  # Absence is a state every caller models: a presence-prover reports the missing proof and fails,
  # a residue check reads the file itself and turns it into evidence. Unreadability is not a state
  # of the SUBJECT, it is a fault of the INSTRUMENT — there is no true answer to give about a file
  # that could not be opened, so the only non-lying option is to stop. It fires on an I/O error, on
  # a path that became a directory, on a permission the runner lost; never in nominal operation,
  # which is exactly why it was never noticed swallowing three absence-of-violation walls
  # (`coord.backend.wired_or_pure`, `cowboy.no_bypass`, `gatekeeper.not_an_ordering_step`), each of
  # which globs REAL files and would have reported compliance about one it could not open.
  defp grep_lines(path, regex) do
    case File.read(path) do
      {:ok, content} ->
        grep_content(content, regex)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise "INSTRUMENT BROKEN — #{path}: #{:file.format_error(reason)} " <>
                "(#{inspect(reason)}). A contract wall cannot report on a file it could not read; " <>
                "refusing to answer rather than answering `no violation found`."
    end
  end

  defp grep_content(content, regex) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
    |> Enum.map(fn {line, ln} -> {ln, line} end)
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
  # SOLE carrier of F8 (event_router first; mcp before spawner — no admiral-domain constraint,
  # cf. A-08 comment in the function) — reordering it breaks the boot WITHOUT a compile
  # error. Hence the honest check id: `boot.order_f8`.
  @doc false
  def check_boot_order_f8(root) do
    app_src = File.read!(Path.join(root, "lib/fleet/application.ex"))

    # A-08: there is NO `mcp < admiral` / `spawner < admiral` constraint — their only
    # would-be cause (a mid-boot admiral-domain child spawning the permanents) does not exist:
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
            "mcp BEFORE spawner (F8 scar in the moduledoc; no admiral-domain " <>
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

  # DEUX MECANISMES D'EXPANSION POUR LE MEME TEMPLATE, ET UN SEUL EST TENU A LA MAIN.
  # La face `main` d'un projet est generee par GITEA depuis le repo-modele : l'expansion des
  # `${VAR}` y est pilotee par le fichier de controle `.gitea/template`, une LISTE de chemins. Les
  # faces `ops`/`workshop`, elles, sont ecrites par `Onboard.Scaffold`, qui expanse TOUT ce qu'il
  # copie. Ajouter un placeholder a un fichier de `main` sans l'ajouter a cette liste ne casse rien
  # ici : ca casse dans le projet livre, des mois plus tard.
  #
  # Mesure du 2026-08-12 sur `fleet/chifoumi` : `README.md` (liste) portait « # chifoumi », et
  # `CLAUDE.md` (hors liste) portait « # ${REPO_NAME} » — dans le fichier meme que la fleet relit a
  # chaque spawn de producteur, avec une date qui n'est pas une date et un en-tete LCARS malforme.
  # Tous les projets crees par la fleet le portaient.
  #
  # ⚠ LE PREDICAT EST « PORTE UNE DE NOS VARIABLES », PAS « PORTE UN ${...} ». `ci.yml` contient
  # `${GITHUB_REF}`, `${GITHUB_REPOSITORY}`, `${GITHUB_SHA}` — des variables du JOB CI, pas les
  # notres. Les inscrire ici confierait a Gitea des noms qu'il ne connait pas, et le jour ou il
  # expanserait l'inconnu en vide, le script CI partirait en morceaux. La liste des cinq variables
  # est celle de `Onboard.Scaffold` : une seule autorite, des deux cotes.
  defp check_gitea_template_expansion(root) do
    face = Path.join([root, "priv", "catalogue", "project_template", "main"])
    control = Path.join([face, ".gitea", "template"])
    vars = ~w(REPO_NAME REPO_DESCRIPTION YEAR MONTH DAY)
    re = ~r/\$\{(#{Enum.join(vars, "|")})\}/

    listed =
      case File.read(control) do
        {:ok, c} ->
          c |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()

        _ ->
          MapSet.new()
      end

    bearing =
      face
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(&Regex.match?(re, File.read!(&1)))
      |> Enum.map(&Path.relative_to(&1, face))
      |> MapSet.new()

    missing = MapSet.difference(bearing, listed) |> Enum.sort()
    extra = MapSet.difference(listed, bearing) |> Enum.sort()

    %{
      id: "template.gitea_expansion",
      status: if(missing == [] and extra == [], do: :pass, else: :fail),
      remediation:
        "aligner priv/catalogue/project_template/main/.gitea/template sur les fichiers qui " <>
          "portent une variable de Onboard.Scaffold (#{Enum.join(vars, ", ")}) — un fichier " <>
          "porteur hors liste sort du projet livre avec ses ${VAR} litteraux",
      evidence:
        Enum.map(missing, &"porteur NON liste: #{&1}") ++
          Enum.map(extra, &"liste mais sans variable: #{&1}"),
      note:
        "expansion Gitea de la face main : la liste de controle doit couvrir exactement les " <>
          "fichiers porteurs (les faces writer passent par Scaffold, qui expanse tout)"
    }
  end

  # Jumeau du precedent, et meme raison d'exister : un ORDRE dans `start/2` que le compilateur ne
  # voit pas. `application.ex` l'ecrit noir sur blanc — *« the images below FREEZE their snapshot
  # from this disk, and a snapshot taken from an unchecked root would carry the fault forward under
  # a proven-good name »*. Une phrase de doctrine que rien ne tient est une phrase qui sera vraie
  # jusqu'au premier refactor : ce check est ce qui la tient.
  #
  # Verrouille sur la SOURCE, comme F8, parce que le mode de panne n'est pas reproductible en test :
  # il demande un catalogue invalide ET des images publiees, c'est-a-dire exactement le boot qu'un
  # test hermetique ne joue pas.
  @doc false
  def check_catalogue_before_freeze(root) do
    app_src = File.read!(Path.join(root, "lib/fleet/application.ex"))

    positions = %{
      verify: :binary.match(app_src, "Fleet.Catalogue.verify!()"),
      cap: :binary.match(app_src, "Fleet.CapProfile.publish_image!()"),
      sp: :binary.match(app_src, "Fleet.SPBuilder.publish_image!()")
    }

    if Enum.any?(positions, fn {_, m} -> m == :nomatch end) do
      %{
        id: "boot.catalogue_before_freeze",
        remediation:
          "restore in Fleet.Application.start/2: Catalogue.verify!() BEFORE " <>
            "CapProfile.publish_image!() and SPBuilder.publish_image!()",
        status: :fail,
        evidence: ["one of verify!/publish_image! not found in application.ex — fail-closed"],
        note: "boot-order lock, twin of boot.order_f8"
      }
    else
      %{verify: {v, _}, cap: {c, _}, sp: {sp, _}} = positions

      %{
        id: "boot.catalogue_before_freeze",
        remediation:
          "move Catalogue.verify!() ABOVE both publish_image! calls: an image frozen from " <>
            "an unchecked catalogue root carries the fault forward under a proven-good name",
        status: if(v < c and v < sp, do: :pass, else: :fail),
        evidence: ["offsets in application.ex: verify=#{v} cap_profile=#{c} sp_builder=#{sp}"],
        note: "boot-order lock, twin of boot.order_f8"
      }
    end
  end

  # LE VERIFICATEUR AUTONOME AFFIRMAIT COUVRIR LE BOOT, ET L'EQUIVALENCE N'ETAIT TENUE PAR RIEN
  # (6-008). `CatalogueVerify` imprime « catalogue OK — every check the boot runs passed. » et
  # `Pilot.Application.verify_cards_and_roles!/1` documente « Runs EXACTLY what start_link/1 runs at
  # rail boot ». Mesure du 2026-08-14 : le boot en jouait SIX, le verificateur QUATRE —
  # `validate_workshop_card!` et `validate_default_card_matrix!` manquaient. Un verificateur VERT
  # pouvait preceder un boot ROUGE, ce qui est le contraire de son objet.
  #
  # Les deux sequences sont lues A L'AST, pas au grep : une garde citee dans un commentaire ne doit
  # pas pouvoir verdir ce mur, et une garde ajoutee au boot ne doit pas pouvoir s'y cacher. On
  # compare les APPELS de `validate_*!` dans les deux corps de fonction.
  @doc false
  def check_verifier_covers_rail(root) do
    rel = "lib/fleet/pilot/application.ex"
    ast = quoted!(root, rel)

    boot = validate_calls(ast, :step_children!)
    verifier = validate_calls(ast, :verify_cards_and_roles!)

    manquantes = boot |> Enum.reject(&(&1 in verifier)) |> Enum.sort()

    cond do
      measured_nothing?(boot) ->
        broken_result("boot.verifier_covers_rail", "validate_*! call in step_children!/0")

      measured_nothing?(verifier) ->
        broken_result(
          "boot.verifier_covers_rail",
          "validate_*! call in verify_cards_and_roles!/1"
        )

      true ->
        %{
          id: "boot.verifier_covers_rail",
          remediation:
            "ajouter la garde au corps de `verify_cards_and_roles!/1` — le verificateur autonome " <>
              "affirme jouer ce que le boot joue, et une garde presente au boot seul rend un vert " <>
              "qui precede un boot rouge",
          status: if(manquantes == [], do: :pass, else: :fail),
          evidence:
            Enum.map(manquantes, &"#{rel}: #{&1} au boot, absente du verificateur autonome"),
          # Le sens de la couverture est ORIENTE : le verificateur doit contenir le boot, jamais
          # l'inverse. Une garde qu'il joue en PLUS est conservatrice (un rouge de trop, jamais un
          # vert menteur) — d'ou deux comptes affiches et pas une egalite.
          note:
            "boot: #{MapSet.size(boot)} gardes `validate_*!` · verificateur: " <>
              "#{MapSet.size(verifier)} — le boot est couvert"
        }
    end
  end

  # Les `validate_<x>!(…)` appelees dans le corps de `fun` — a l'AST. Le nom de la fonction porte
  # l'intention (`validate_` + `!`), et c'est ce qui permet de comparer deux sequences sans tenir
  # une troisieme liste qui deriverait a son tour.
  defp validate_calls(ast, fun) do
    ast
    |> collect(fn
      {:def, _, [{^fun, _, _} | _] = body} -> [body]
      {:defp, _, [{^fun, _, _} | _] = body} -> [body]
      _ -> nil
    end)
    |> List.flatten()
    |> collect(fn
      {name, _, _args} when is_atom(name) ->
        s = Atom.to_string(name)
        if String.starts_with?(s, "validate_") and String.ends_with?(s, "!"), do: [s], else: nil

      _ ->
        nil
    end)
    |> List.flatten()
    |> MapSet.new()
  end

  # WHAT THE PROVEN-IMAGE REGIME IS ACTUALLY WORTH, AND THE ONE SWITCH THAT VOIDS IT. `SPBuilder`
  # renders its templates with `EEx.eval_string/2` — EEx evaluates arbitrary Elixir at render time,
  # in the DAEMON's process, with the whole fleet's rights and not a confined pod's. Two regimes
  # decide which bytes get evaluated:
  #
  #   * image PUBLISHED (the default, frozen at boot AFTER `Catalogue.verify!()`, sha256-fingerprinted,
  #     served from `:persistent_term`) -- a mid-life disk mutation changes nothing until a restart;
  #   * NO image -> live disk at every render, re-read each time, verified by nothing.
  #
  # The second regime exists on purpose (the suites' hermetic default, tooling) and its twin says so
  # in `CapProfile.Catalog.read_role/2`. What has no legitimate reason to exist is that switch being
  # flipped ANYWHERE ELSE than `config/test.exs`: it silently moves a production daemon onto
  # evaluate-whatever-is-on-disk, and nothing in the code would look different.
  @doc false
  def check_proven_image_regime(root) do
    files = Path.wildcard(Path.join(root, "config/*.exs"))

    disabling =
      for f <- files,
          key <- disabled_image_keys(quoted!(root, Path.relative_to(f, root))),
          do: {Path.basename(f), key}

    offenders = disabling |> Enum.reject(fn {base, _} -> base == "test.exs" end) |> Enum.sort()

    cond do
      measured_nothing?(files) ->
        broken_result("boot.proven_image_regime", "file under config/")

      # `config/test.exs` disables BOTH images by design. Finding none means the reader stopped
      # seeing the switch -- and a wall that cannot see its subject passes everything.
      measured_nothing?(disabling) ->
        broken_result("boot.proven_image_regime", "publish_image switch in config/")

      true ->
        %{
          id: "boot.proven_image_regime",
          remediation:
            "keep `cap_profile_publish_image` / `sp_builder_publish_image` false in config/test.exs " <>
              "ONLY: without a published image the SP templates are re-read from live disk at every " <>
              "render and EEx-evaluated in the daemon, verified by nothing",
          status: if(offenders == [], do: :pass, else: :fail),
          evidence:
            Enum.map(offenders, fn {file, key} ->
              "config/#{file}: #{key} disabled outside the hermetic test config"
            end),
          note:
            "#{length(disabling)} switch(es) off, all in test.exs — proven-image regime intact"
        }
    end
  end

  # `config :lcars_fleet, <key>: false` for either image key, read from the AST: a key named in a
  # comment must not be able to redden this, and one hidden in a keyword list must not escape it.
  defp disabled_image_keys(ast) do
    ast
    |> collect(fn
      {:config, _, [:lcars_fleet, opts]} when is_list(opts) ->
        for {k, false} <- opts,
            k in [:cap_profile_publish_image, :sp_builder_publish_image],
            do: k

      _ ->
        nil
    end)
    |> List.flatten()
  end

  # THIRD OF THE BOOT-ORDER FAMILY, and the one whose subject is a DEFAULT rather than a call.
  # `Bus.assert_authorized!/1` permits every event while the registry is empty
  # (`@permit_empty_default true`). That default is not laxity: it holds the window between the
  # first line of boot and the moment `Catalog.load!/0` populates the registry, and `load!/0` RAISES
  # on an absent, invalid or empty `events.yaml` — so a fleet that reaches its first broadcast has a
  # loaded registry, always.
  #
  # THE GUARANTEE LIVES IN ANOTHER MODULE AT ANOTHER MOMENT, and nothing held it. `Catalog.load!/0`
  # sits in `EventRouter.Application.init/1` above the children list by convention alone; moving it
  # one line down, or into a child's `init`, widens the permissive window to the whole boot without
  # a single test going red — the failure needs an unregistered event AND a real supervision tree,
  # which the hermetic suite does not play (`event_router_load_event_registry: false` in test.exs).
  #
  # MEASURED, because the register's fiche asks for the opposite and the number decides: flipping
  # `@permit_empty_default` to `false` yields **101 failures out of 2698**. The permissive default
  # is load-bearing. What was missing was never the fail-closed posture — it was this lock.
  @doc false
  def check_event_registry_loaded_before_children(root) do
    rel = "lib/fleet/event_router/application.ex"
    src = File.read!(Path.join(root, rel))

    positions = %{
      load: :binary.match(src, "Fleet.EventRouter.Catalog.load!()"),
      children: :binary.match(src, "children =")
    }

    remediation =
      "keep `Fleet.EventRouter.Catalog.load!()` ABOVE the children list in " <>
        "EventRouter.Application.init/1: it is what closes the window that " <>
        "`Bus.@permit_empty_default true` deliberately leaves open, and it raises on an absent, " <>
        "invalid or empty events.yaml"

    if Enum.any?(positions, fn {_, m} -> m == :nomatch end) do
      %{
        id: "boot.event_registry_before_children",
        remediation: remediation,
        status: :fail,
        evidence: ["#{rel}: `Catalog.load!()` or the children list not found — fail-closed"],
        note: "boot-order lock, third of the family (F8, catalogue_before_freeze)"
      }
    else
      %{load: {l, _}, children: {c, _}} = positions

      %{
        id: "boot.event_registry_before_children",
        remediation: remediation,
        status: if(l < c, do: :pass, else: :fail),
        evidence: ["offsets in #{rel}: Catalog.load!=#{l} children=#{c}"],
        note:
          "the permissive empty-registry default is safe only while this call precedes every " <>
            "process that can broadcast"
      }
    end
  end

  # Z7 (F-C165 → BL-6-45) — FOUR lists declare which roles exist, and every pairwise drift has
  # bitten or nearly bitten: the canon catalogue (the SOURCE), forge.tf `local.roles` (accounts),
  # etc/provision-role-tokens.sh `ROLES` (token mint default), and deploy's
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
  @doc false
  def check_roles_provisioning_locked(root) do
    # Decoded reads (kind/forge_identity are yaml fields, not greppable shapes) — the task
    # context does not start :yaml_elixir by itself; same explicit start as lcars.sp.gen.
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    catalogue = scan_catalogue_roles(root)

    # PROJETE en LOGINS avant de comparer, parce que les trois listes en portent desormais. Le
    # verrou ne change pas de nature — il reste l'egalite stricte des quatre — mais il compare les
    # memes objets. Meme regle que la derivation runtime : le prefixe suit le TIER, donc ou le nom
    # est declare en premier, et non le fichier qui gagne la superposition (un catalogue metier peut
    # livrer son propre `architect.yaml` sans que le compte cesse d'etre `system_architect`).
    canon =
      catalogue
      |> Enum.filter(& &1.forge_identity)
      |> Enum.map(&role_login(root, &1.name))
      |> Enum.sort()

    sh_path = Path.join(root, "etc/provision-role-tokens.sh")

    # `deploy/deps/`, moved there 2026-08-05: the tofu recipe was the LAST live leg of the
    # v1 tree, and this check reading it across trees is what caught the move — the wall working on
    # the gesture that touched it.
    tf_path = Path.expand("deploy/deps/forge.tf", root)
    lib_path = Path.expand("deploy/lib/provision-lib.sh", root)

    # The two SIBLING-TREE lists are outside `fleet`, and one legitimate context does not
    # carry them: the image BUILD stage copies `fleet` ALONE (Dockerfile), then runs this
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
        # `variable "roles"` since the enroll derivation (2026-08-10): the roster moved from a
        # `local` to a VARIABLE so a deployment can supply the roster of the catalogue it brings.
        # The DEFAULT is what this check measures, and that is the right target — it is the value
        # a deployment gets when it supplies nothing, so it is the one that must equal the canon.
        # Anchored on the variable NAME, not on a bare `default = [...]`: the recipe has other
        # list variables now, and an unanchored pattern would lock the canon against whichever
        # one happens to appear first.
        # L'UNION des deux listes : `roles` porte le metier de ce catalogue, `system_roles` l'autorite
        # d'instance partagee. Le canon ne connait pas cette coupure — il connait les comptes — donc
        # c'est ici qu'on recolle, sans quoi le verrou declarerait trois roles « manquants ».
        {"forge.tf var.roles + var.system_roles defaults",
         tree_scope(Path.expand("deploy", root)),
         merge_lists(
           read_list(tf_path, ~r/variable\s+"roles"\s*\{.*?default\s*=\s*\[([^\]]*)\]/s, :quoted),
           read_list(
             tf_path,
             ~r/variable\s+"system_roles"\s*\{.*?default\s*=\s*\[([^\]]*)\]/s,
             :quoted
           )
         ),
         "add/remove the role in the `roles` variable default (forge account) — the canon is the " <>
           "source: a role only in forge.tf needs its cap-profile or a ReservedSeat, or loses " <>
           "its account"},
        {"provision-lib.sh PROV_ROLES", tree_scope(Path.expand("deploy", root)),
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

    # LES TROIS LISTES DE PLACEMENT etaient hors du verrou, et c'est le meme defaut d'un cran plus
    # bas : `writers`/`judges`/`externals` sont des defauts tenus A LA MAIN pendant que la derivation
    # (`CatalogueRoles.tfvars/1`) produit deja la reponse. Rien ne les comparait, donc rien
    # n'empechait la divergence qui a coute `chief` — present dans `roles`, absent de `writers`,
    # compte sans droit d'ecriture, trouve a l'oeil sur une forge.
    #
    # La comparaison consomme la DERIVATION, pas une seconde implementation de la regle de placement
    # (siege -> externals, juge sans capacite -> judges, le reste -> writers) : la redire ici serait
    # exactement la duplication que ce verrou existe pour interdire.
    {placement, placement_note} = check_placement_defaults(root, tf_path)
    evidence = evidence ++ placement

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
        "four-list STRICT equality (BL-6-45)" <>
          placement_note <>
          ": canon{forge_identity} PROJECTED into " <>
          "`<catalogue>_<role>` logins (#{length(canon)} roles, seats included) == forge.tf == " <>
          "ROLES == PROV_ROLES — any delta is a defect, named" <>
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
  @doc false
  def check_roles_role_index_unique(root) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    indexed =
      scan_catalogue_roles(root)
      |> Enum.filter(&is_integer(&1.role_index))

    duplicates =
      indexed
      |> Enum.group_by(& &1.role_index, & &1.name)
      |> Enum.filter(fn {_idx, names} -> length(names) > 1 end)

    if measured_nothing?(indexed) do
      broken_result("roles.role_index_unique", "catalogue role carrying a role_index")
    else
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
  #
  # WHAT IT DOES NOT REACH, and the sentence above must not be read past it: THE SOURCE TREE ONLY.
  # The word also lives in the SP corpus (`priv/catalogue*/sp_builder/**`), which is not scanned
  # here — and that is the population where the prior does its work, since those texts are injected
  # into the agents' own context. Measured 2026-08-13: the block `core/pod-sanctuary`, composed into
  # SIX roles, opens on the heading "## Ton monde (sanctuaire)" with NO antibody anywhere in it.
  # Extending the scan there is not a lint change but a change to authored prompt material, whose
  # calibration belongs to its author — the finding is on record, the edit is not this wall's to
  # make.
  #
  # A WHITELIST ENTRY THAT PROTECTS NOTHING IS A PRE-AUTHORIZED SLOT. `lib/fleet/spawner/pod/
  # launch_spec.ex` sat here after the word had left it: the exemption survived its subject, and the
  # day the word came back that file would have carried it exempt and unremarked. An allowlist is
  # audited by re-measuring, never by reading it.
  @sanctuary_allowed ~w(
    bin/bwrap_launch.sh
    lib/fleet/cap_profile/invariants.ex
    lib/mix/tasks/lcars.contracts.check.ex
  )

  @doc false
  # BL-6-05 — LE MUR D'EXHAUSTIVITE DE LA MIGRATION DE NAMESPACE, et il est ne AVANT elle.
  #
  # Les 15 atoms `:fleet_<dom>` etaient LEGACY-VALIDES (D-07) : ils fonctionnaient, la config ETS
  # etant keyee par atom. Ce qu'ils coutaient etait a l'ENTREE — dix messages de Mix a chaque
  # `mix test`, disant a qui decouvre le depot que sa configuration est fausse.
  #
  # ⚠ CE CHECK EXISTE PARCE QUE LE MODE DE DEFAILLANCE EST SILENCIEUX. Un site oublie appelle
  # `Application.get_env(:fleet_x, :k)` sur un namespace desormais vide : il recoit le DEFAUT, pas
  # une erreur. La config cesse de s'appliquer sans que rien ne le dise, et un test qui n'exerce pas
  # ce knob reste vert. Une migration de 535 sites ne peut pas se verifier a la relecture.
  #
  # Deux classes ont echappe au balayage textuel de la migration, et elles sont la raison d'etre de
  # ce mur : la forme PIPE (`:fleet_pilot |> Application.get_env(:max_fan, …)`, ou l'atome precede
  # l'appel) et les cles DYNAMIQUES (une variable, un attribut de module). La premiere est attrapee
  # ici ; la seconde ne peut l'etre par personne — d'ou la regle posee au meme moment : une cle de
  # config se lit EN TOUTES LETTRES a son point d'usage, jamais assemblee.
  def check_no_legacy_config_namespace(root) do
    scanned =
      ["lib", "test", "config"]
      |> Enum.flat_map(fn d -> Path.wildcard(Path.join([root, d, "**", "*.{ex,exs}"])) end)
      |> Enum.reject(&(&1 =~ ~r{/(_build|tmp)/}))

    offenders =
      scanned
      |> Enum.filter(fn f ->
        rel = Path.relative_to(f, root)

        rel != "lib/mix/tasks/lcars.contracts.check.ex" and
          match?({:ok, c} when is_binary(c), File.read(f)) and
          File.read!(f) =~
            ~r/:fleet_(api|cap_profile|catalogue|coord|credentials|event_router|mcp|observation|pilot|project|sp_builder|spawner|starfleet|task_queue|workflow)\b/
      end)
      |> Enum.map(&Path.relative_to(&1, root))

    if measured_nothing?(scanned) do
      broken_result("config.no_legacy_config_namespace", "source under lib/, test/ or config/")
    else
      %{
        id: "config.no_legacy_namespace",
        remediation:
          "un atome de config `:fleet_<domaine>` subsiste. La config vit sous `:lcars_fleet` avec " <>
            "la cle prefixee par son domaine (`:fleet_api, :http_port` => `:lcars_fleet, " <>
            ":api_http_port`) — le prefixe n'est pas cosmetique : `http_port` et `start_listener` " <>
            "COLLISIONNENT entre `api` et `observation`, une fusion a plat ferait ecouter un " <>
            "service sur le port d'un autre, sans un mot",
        status: if(offenders == [], do: :pass, else: :fail),
        evidence: offenders,
        note: "les 15 namespaces `:fleet_*` sont morts avec la migration (BL-6-05, D-07 executee)"
      }
    end
  end

  @doc false
  def check_sanctuary_contained(root) do
    # EVERY FILE OF THE THREE TREES, not the three source extensions. `**/*.{ex,exs,sh}` could not
    # see `bin/claude_launch.egress`, which carried the word, in a scanned directory, with no
    # antibody — a carrier that escaped by file extension alone. `bin/` holds `.sh`, `.py`,
    # `.egress`, `.identity` and two extensionless launchers; a wall that names a directory and
    # measures three suffixes of it says more than it checks. Non-text files (the `__pycache__`
    # bytecode) drop out on `String.valid?/1` rather than on a suffix list that would have to be
    # kept in step with them.
    scanned =
      ["lib", "bin", "etc"]
      |> Enum.flat_map(fn d -> Path.wildcard(Path.join([root, d, "**"])) end)
      |> Enum.reject(&File.dir?/1)

    offenders =
      scanned
      |> Enum.filter(fn f ->
        rel = Path.relative_to(f, root)

        rel not in @sanctuary_allowed and
          match?({:ok, c} when is_binary(c), File.read(f)) and
          String.valid?(File.read!(f)) and
          File.read!(f) =~ ~r/sanctuaire|sanctuary/i
      end)
      |> Enum.map(&Path.relative_to(&1, root))

    if measured_nothing?(scanned) do
      broken_result("vocab.sanctuary_contained", "source under lib/, bin/ or etc/")
    else
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
          "#{length(scanned)} fichier(s) de lib/, bin/ et etc/ balayes — le mot y reste borne aux " <>
            "#{length(@sanctuary_allowed)} qui portent son anticorps (BL-6-44). Le corpus SP " <>
            "(priv/catalogue*/sp_builder/**) est HORS de ce perimetre : c'est de la matiere de " <>
            "prompt, dont la calibration appartient a son auteur"
      }
    end
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
  @doc false
  def check_sourcers_set_strict(root) do
    # `root` IS fleet (project_root/0) — the sibling trees hang off `..`, exactly as the
    # four-list check resolves them. Getting this wrong makes the check silently SKIP instead of
    # run, which is the worst of the three outcomes: a green that checked nothing.
    dir = Path.expand("deploy", root)

    case tree_scope(dir) do
      :out_of_scope ->
        %{
          id: "shell.sourcers_set_strict",
          remediation: "—",
          status: :pass,
          evidence: [],
          note: "NOT CHECKED here (fleet/deploy absent from this artifact — runtime-only context)"
        }

      :required ->
        # THE POPULATION IS COMPUTED FIRST, AND ITS EMPTINESS IS A FAILURE (BL-6-70). `tree_scope/1`
        # guards the PERIMETER — is `fleet/deploy` part of this artifact — and it was doing that job
        # alone. The population is a different question: these are TWO roots, only one of them is
        # scoped, and `Path.wildcard` on a path that does not exist returns `[]` in silence. A
        # `deploy/` present with an empty or moved `modules.d/` therefore yielded `offenders == []`
        # and a `:pass` that had not opened a single file — indistinguishable, in the output, from a
        # green earned on eleven conforming sourcers.
        #
        # The comment above this function already named the risk: "a green that checked nothing".
        # It guarded the scope and not the population, which is exactly the half that was missing.
        sourcers =
          [
            Path.join(dir, "modules.d"),
            Path.join(root, "etc")
          ]
          |> Enum.flat_map(fn d -> Path.wildcard(Path.join(d, "*.sh")) end)

        if measured_nothing?(sourcers) do
          broken_result("shell.sourcers_set_strict", "sourcer scripts")
        else
          do_check_sourcers(sourcers, root)
        end
    end
  end

  defp do_check_sourcers(sourcers, root) do
    offenders =
      sourcers
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
      evidence: Enum.map(offenders, &Path.relative_to(&1, root)),
      note:
        "#{length(sourcers)} shell file(s) scanned; every sourcer of provision-lib.sh sets -u " <>
          "(BL-6-36: bash's silent-coercion class)"
    }
  end

  # A face's root must EXIST on the machine before anything can put a repo in it, and the runtime
  # cannot create it: the fleet runs as the human, `/home` belongs to root. Two creators write it,
  # each a hand-written mirror of `Fleet.Layout.face_root/1` in another language — the exact shape
  # that drifts without a word.
  #
  # THE WALL HELD ONE OF THE TWO, and the one it held is the narrower. Until 2026-08-13 it read the
  # docker entrypoint alone, so it was green on a rail that recognises THREE substrates
  # (`docker`, `wsl`, `linux`) while creating the zones on one. On `wsl` they existed "by history of
  # the substrate" — by hand, one day, on the author's machine — and on a native `linux`, not at
  # all. Same failure as the `doc` face below, on the path the check did not cover.
  #
  # Measured 2026-08-09 on a fresh bench: the `doc` face was in the code AND in the image's `build`
  # stage (added so the gate could run), and NOT in the entrypoint. The box came up healthy, the
  # fleet started, and the first `project_create` died on `could not make directory (with -p)
  # "/home/projects.workshop": permission denied`. Nothing before that moment could have said it.
  #
  # FAIL-CLOSED ON THE ANCHOR: if the `install -d` line cannot be found, this check FAILS instead of
  # passing on an empty read. A renamed line would otherwise turn the guard off in silence, which is
  # worse than the drift it watches.
  @doc false
  def check_face_roots_provisioned(root) do
    entrypoint = Path.expand("deploy/docker/entrypoint.sh", root)
    module = Path.expand("deploy/modules.d/25-directories.sh", root)
    expected = read_face_roots(Path.expand("lib/fleet/layout.ex", root))

    remediation =
      "add the face root to the `install -d` line of deploy/docker/entrypoint.sh — a face declared " <>
        "in Fleet.Layout with no zone on the machine makes the box look healthy and kills the " <>
        "first onboard that needs it (the runtime runs as the human; /home belongs to root)"

    case tree_scope(Path.expand("deploy", root)) do
      :out_of_scope ->
        %{
          id: "layout.face_roots_provisioned",
          remediation: "—",
          status: :pass,
          evidence: [],
          note: "NOT CHECKED here (fleet/deploy absent from this artifact — runtime-only context)"
        }

      :required ->
        case {expected, read_install_zone_paths(entrypoint), read_provision_zone_paths(module)} do
          {nil, _, _} ->
            %{
              id: "layout.face_roots_provisioned",
              remediation: remediation,
              status: :fail,
              evidence: ["lib/fleet/layout.ex"],
              note: "face_root/1 unreadable in Fleet.Layout — guard fail-closed, nothing measured"
            }

          {_, nil, _} ->
            %{
              id: "layout.face_roots_provisioned",
              remediation: remediation,
              status: :fail,
              evidence: [Path.relative_to(entrypoint, root)],
              note: "the `install -d -m 2775 -g fleet` anchor is unreadable — guard fail-closed"
            }

          {_, _, nil} ->
            %{
              id: "layout.face_roots_provisioned",
              remediation: remediation,
              status: :fail,
              evidence: [Path.relative_to(module, root)],
              note:
                "the provision module's `2775` zone table is unreadable — guard fail-closed " <>
                  "(this is the creator on every substrate; the entrypoint only covers docker)"
            }

          {expected, at_boot, on_every_substrate} ->
            missing =
              Enum.map(expected -- at_boot, &"#{&1}: absent de l'entrypoint docker") ++
                Enum.map(
                  expected -- on_every_substrate,
                  &"#{&1}: absent du module provision (donc absent sur wsl et linux)"
                )

            %{
              id: "layout.face_roots_provisioned",
              remediation: remediation,
              status: if(missing == [], do: :pass, else: :fail),
              evidence: missing,
              note:
                "les #{length(expected)} racines de face de Fleet.Layout sont créées par les DEUX " <>
                  "miroirs — le module provision (tout substrat) et l'entrypoint docker (l'ordre " <>
                  "de boot l'exige avant `provision apply`) : #{Enum.join(expected, ", ")}"
            }
        end
    end
  end

  # The face roots, READ from `Fleet.Layout`'s source rather than called. This task references no
  # Fleet module at runtime — by design: a contract checker that CALLED the code would be measuring
  # the code with the code, and `Fleet.Application` (which classifies this task, Z4) does not carry
  # an edge to Layout. Same shape as `read_list/3` above: cross-language facts are read, and the
  # authority stays where it is.
  #
  # `face_root/1` has one clause per face; the body is an attribute (today) or could be the literal
  # itself. BOTH are read, and a body that is NEITHER makes the whole read nil.
  #
  # That last part is the point, and it cost a surviving mutation to find. The first version matched
  # only `do: @attr`; inlining one clause's literal made that clause invisible, and the check then
  # declared a 2-face population fully provisioned — green, with a smaller subject than it names.
  # The mutation was semantically harmless, the READER was not: any face whose body it cannot parse
  # would vanish the same way, including one whose root is genuinely missing from the machine.
  # A guard that silently narrows its population is the exact defect this check exists to close.
  defp read_face_roots(layout_path) do
    with {:ok, src} <- File.read(layout_path),
         [_ | _] = clauses <- Regex.scan(~r/^\s*def face_root\("([a-z]+)"\), do: (.+)$/m, src) do
      attrs =
        ~r/^\s*@([a-z_]+)\s+"(\/[^"]+)"$/m
        |> Regex.scan(src)
        |> Map.new(fn [_, name, value] -> {name, value} end)

      roots = Enum.map(clauses, fn [_, _face, body] -> resolve_face_root(body, attrs) end)
      if Enum.any?(roots, &is_nil/1), do: nil, else: Enum.sort(roots)
    else
      _ -> nil
    end
  end

  defp resolve_face_root(body, attrs) do
    case String.trim(body) do
      "@" <> attr -> Map.get(attrs, attr)
      ~s(") <> _ = literal -> literal |> String.trim(~s(")) |> nonempty_abs_path()
      _ -> nil
    end
  end

  defp nonempty_abs_path("/" <> _ = p), do: p
  defp nonempty_abs_path(_), do: nil

  # The paths of the entrypoint's zone-creating line. Absolute tokens only — the flags (`-d`,
  # `-m 2775`, `-g fleet`) are not paths, and matching them as such would make a missing face
  # indistinguishable from a changed mode.
  defp read_install_zone_paths(path) do
    with {:ok, content} <- File.read(path),
         [_, tail] <- Regex.run(~r/^install\s+-d\s+-m\s+2775\s+-g\s+fleet\s+(.+)$/m, content) do
      tail |> String.split() |> Enum.filter(&String.starts_with?(&1, "/"))
    else
      _ -> nil
    end
  end

  # The face zones of the PROVISION module — the substrate-agnostic creator. Read from its table
  # (`"<path> <mode> <owner>"`, one entry per line), and only the `2775` rows: the module also
  # provisions `/local` and the token dir, which are not faces.
  #
  # WHY THERE ARE TWO MIRRORS AND WHY BOTH ARE HELD HERE. The docker entrypoint creates these zones
  # too, and that is not a forgotten duplicate: it clones the source into `/home/projects/LCARS`
  # long BEFORE it calls `provision apply`, so the zones must exist earlier than the module runs.
  # Boot ordering is the reason for the second mirror. What must never happen is the two drifting
  # from `Fleet.Layout`, or from each other — so the check compares BOTH against the code, and its
  # evidence says which mirror is short. A wall that held one of two mirrors was green on a fleet
  # whose `wsl` and `linux` substrates created no zone at all.
  defp read_provision_zone_paths(path) do
    case File.read(path) do
      {:ok, content} ->
        case Regex.scan(~r/^\s*"(\/[^"\s]+)\s+2775\s/m, content) do
          [] -> nil
          rows -> rows |> Enum.map(fn [_, p] -> p end) |> Enum.sort()
        end

      _ ->
        nil
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
  # Rendue muette quand le catalogue bundle n'est pas la (etape BUILD de l'image, fixture de test) :
  # meme regle que les listes de l'arbre frere — l'absence d'un arbre est hors-perimetre, jamais un
  # vert silencieux sur du terrain non mesure.
  defp merge_lists(nil, _), do: nil
  defp merge_lists(_, nil), do: nil
  defp merge_lists(a, b), do: Enum.sort(a ++ b)

  @placement_checked " + the THREE placement defaults against the derivation"

  defp check_placement_defaults(root, tf_path) do
    catalogue = Path.join(root, "priv/catalogue")

    # HORS-PERIMETRE quand l'arbre `deploy/` n'est pas la — MEME regle que les listes de l'arbre
    # frere juste au-dessus, et je l'avais oubliee. L'etage BUILD de l'image copie `fleet/` SANS
    # `deploy/` (COPY explicite, par choix), donc la recette n'y est pas : les listes existantes se
    # skippaient proprement pendant que celle-ci rendait « not readable — fail-closed ». Un gate vert
    # sur l'hote et rouge dans l'image, sur un artefact qui n'a jamais fait partie du perimetre.
    if File.dir?(Path.expand("deploy", root)) and File.dir?(catalogue) do
      case Fleet.Application.CatalogueRoles.tfvars(catalogue) do
        {:ok, derived} ->
          ev =
            Enum.flat_map(~w(writers judges externals), fn key ->
              rx = ~r/variable\s+"#{key}"\s*\{.*?default\s*=\s*\[([^\]]*)\]/s
              hard = read_list(tf_path, rx, :quoted)
              want = Enum.sort(Map.get(derived, key, []))

              cond do
                hard == nil ->
                  ["forge.tf var.#{key} default: not readable — fail-closed"]

                Enum.sort(hard) == want ->
                  []

                true ->
                  [
                    "forge.tf var.#{key} default #{inspect(Enum.sort(hard))} != derivation #{inspect(want)}"
                  ]
              end
            end)

          {ev, @placement_checked}

        {:error, reason} ->
          {["placement derivation unreadable (#{inspect(reason)}) — fail-closed"],
           @placement_checked}
      end
    else
      # PAS un vert silencieux : la note le DIT. Une verification qui borne sa couverture sans le
      # dire se lit comme une couverture complete — et c'est ainsi qu'un mur devient decoratif.
      {[], " (placement defaults SKIPPED: no `deploy` tree)"}
    end
  end

  defp role_login(root, role) do
    prefix =
      if MapSet.member?(system_role_names(root), role), do: "system", else: bundled_name(root)

    "#{prefix}_#{role}"
  end

  defp system_role_names(root) do
    root
    |> Path.join("priv/catalogue-system/cap_profile/canon/cap-profiles/*.yaml")
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "_"))
    |> Enum.flat_map(fn path ->
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = raw} -> [get_in(raw, ["metadata", "name"]) || Path.basename(path, ".yaml")]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp bundled_name(root) do
    case YamlElixir.read_from_file(Path.join(root, "priv/catalogue/catalogue.yaml")) do
      {:ok, %{"name" => n}} when is_binary(n) -> n
      _ -> "fleet"
    end
  end

  defp scan_catalogue_roles(root) do
    # BOTH catalogues. The provisioning lists cover the whole deployment — a mechanism role needs
    # its forge account exactly as much as a producer does — so scanning the business tree alone
    # would declare four roles "extra" in every list and turn a correct deployment red.
    [
      "priv/catalogue/cap_profile/canon/cap-profiles/*.yaml",
      "priv/catalogue-system/cap_profile/canon/cap-profiles/*.yaml"
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "_"))
    |> Enum.flat_map(fn path ->
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = raw} ->
          [
            %{
              name: get_in(raw, ["metadata", "name"]) || Path.basename(path, ".yaml"),
              kind: Map.get(raw, "kind"),
              forge_identity: get_in(raw, ["metadata", "forge_identity"]) != false,
              role_index: get_in(raw, ["metadata", "role_index"]),
              capabilities: get_in(raw, ["spec", "capabilities"]) || [],
              allowed_tools: get_in(raw, ["spec", "scope", "allowedTools"]) || []
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
  @doc false
  def check_mcp_wire_inputschema(root) do
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
  #   * POD-SCOPED — the clause BINDS the channel identity and its body USES it, so the tool's
  #     subject comes from the socket (one pod, one socket) and never from the wire. Receiving
  #     `%{pod_id: _}` is not the property: the acceptor hands that map to every tool alike.
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
        "give the tool a gate: bind the channel identity in its handle_tool_call head " <>
          "(%{pod_id: pod_id}) AND derive the tool's subject from it in the body, or route it " <>
          "through a Delegation function guarded by require_architect/require_onboarder — " <>
          "tools/call does not re-check tools/list, and receiving pod_id is not using it",
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

  # 6-106 — L'EXHAUSTIVITE DE LA CLASSIFICATION DES OUTILS, MECANIQUE OU RIEN.
  #
  # L'acceptor protegeait cinq outils sur ~17 contre le double effet, depuis une liste de mots nus
  # posee LOIN des definitions. Deplacer cette liste a cote des `deftool` la rend traversable par un
  # renommage — ce qui repare la panne du 2026-08-11 — mais ne repare PAS l'oubli : rien n'oblige
  # celui qui ajoute un `deftool` a le classer.
  #
  # Ce check est ce qui l'oblige, et il porte dans les DEUX sens :
  #   * un outil declare sans effet → le prochain mutateur ajoute est protege par defaut
  #     (`:unknown` → single-flight) et le gate NOMME l'omission au lieu de la laisser dormir ;
  #   * un effet declare pour un outil qui n'existe plus → le residu d'un renommage, exactement la
  #     forme du bug d'origine, vue de l'autre cote.
  #
  # Meme posture d'instrument que son voisin : les findings sont des ABSENCES, et un parseur casse
  # produit les memes. Le plancher attrape un instrument aveugle, il ne fige pas le nombre d'outils.
  @doc false
  def check_mcp_tool_effects(root) do
    tools_rel = "lib/fleet/mcp/pod_tools.ex"

    declared = deftool_names(quoted!(root, tools_rel))
    classified = tool_effect_names(quoted!(root, tools_rel))

    unclassified = declared |> Enum.reject(&(&1 in classified)) |> Enum.sort()
    orphan = classified |> Enum.reject(&(&1 in declared)) |> Enum.sort()

    broken =
      cond do
        MapSet.size(declared) < 12 ->
          "only #{MapSet.size(declared)} deftool found (expected 12+)"

        MapSet.size(classified) < 12 ->
          "@tool_effects has #{MapSet.size(classified)} entries (12+)"

        true ->
          nil
      end

    %{
      id: "mcp.tool_effects",
      remediation:
        "declare the tool's world-effect in `@tool_effects` of Fleet.MCP.PodTools, next to its " <>
          "deftool: `:mutation` (changes the world → single-flight), `:protocol` (the pod's own " <>
          "IN/OUT channel, whose re-emission is designed and owned by the TaskQueue) or `:read`",
      status: if(is_nil(broken) and unclassified == [] and orphan == [], do: :pass, else: :fail),
      evidence:
        cond do
          broken ->
            ["#{tools_rel}: INSTRUMENT BROKEN — #{broken}; this check measured nothing"]

          unclassified != [] ->
            ["#{tools_rel}: tools with no declared effect #{inspect(unclassified)}"]

          orphan != [] ->
            ["#{tools_rel}: @tool_effects names no tool declares #{inspect(orphan)}"]

          true ->
            []
        end,
      note: "#{MapSet.size(declared)} tools, each with a declared world-effect"
    }
  end

  # 6-136 — UN MODOP QUI ORDONNE UN OUTIL QUE SON PORTEUR N'A PAS **GELE LE POD**, ET RIEN NE LE
  # DISAIT NULLE PART.
  #
  # Ce n'est pas une gene de prompt. Mesure de banc du 2026-08-09, ecrite dans `architect.yaml` et
  # dans `launch_env.ex` : sous `--permission-mode default`, un outil absent d'`allowedTools` ne se
  # saute PAS, il PROMPTE (« Do you want to… 1. Yes 2. Yes, allow all 3. No ») — et un pod n'a
  # personne pour repondre. Il reste vivant, tient son creneau et le verrou `lcars-in-flight` du
  # ticket, et ne produit rien ; la chaine de reprise redispatche alors un pod qui se bloque au meme
  # endroit. Le bundle `brainstorming` ordonnait un `TodoWrite` que ni `architect` ni `starfleet`
  # ne declaraient, et les deux l'activent.
  #
  # LA CHARGE DE LA PREUVE EST RENVERSEE, ET C'EST CE QUI FAIT TENIR LE MUR. Le premier jet bornait
  # le vocabulaire aux noms deja declares par un cap-profile — exact, sans faux positif… et MUET sur
  # le defaut qui l'a motive : `TodoWrite` n'etait declare NULLE PART, donc rien ne le reconnaissait
  # comme outil. Un mur qu'on desarme en retirant la derniere declaration ne protege rien.
  #
  # Donc : tout nom EN FORME D'OUTIL cite par un bundle doit etre accorde par chacun de ses
  # porteurs, ou figurer ci-dessous avec sa raison. La liste se PURGE quand son sujet disparait
  # (lecon 6-091 : une exemption qui ne correspond plus a rien n'exempte rien et masque la
  # suivante) — et elle vient de le faire, toute seule, le 2026-08-19.
  #
  # ⚠ ELLE ETAIT VIDEE PAR LA SORTIE DE SUPERPOWERS, ET C'EST LA GARDE QUI L'A DIT. Son unique
  # entree, `MailerTest`, etait un nom de module cite par le test d'exemple de `tdd/sp.md` ; le
  # bundle supprime, l'exemption ne designait plus rien et le check a demande sa purge de lui-meme
  # (« MailerTest is cited by no bundle — purge it »). Une exemption survivante aurait laisse un
  # trou nomme dans un mur, pret a couvrir le prochain nom homonyme.
  #
  # La map reste, VIDE : c'est la porte par ou une future exemption entre AVEC sa raison, et son
  # absence forcerait la prochaine a s'inventer un mecanisme.
  @modop_not_tools %{}

  @doc false
  def check_modop_tools_granted(root) do
    profiles = catalogue_profiles(root)
    bundles = catalogue_modop_bundles(root)

    missing =
      for {bundle, path, cited} <- bundles,
          {rname, allowed, _denied, modops} <- profiles,
          bundle in modops,
          tool <- cited,
          not Map.has_key?(@modop_not_tools, tool),
          tool not in allowed,
          do: "#{path}: orders #{tool}, which #{rname} (a carrier) does not grant"

    cited_anywhere = bundles |> Enum.flat_map(fn {_b, _p, cited} -> cited end) |> MapSet.new()

    dead_exemptions =
      @modop_not_tools |> Map.keys() |> Enum.reject(&(&1 in cited_anywhere)) |> Enum.sort()

    cond do
      measured_nothing?(profiles) ->
        broken_result("cap_profile.modop_tools_granted", "cap-profile under the catalogue roots")

      measured_nothing?(bundles) ->
        broken_result("cap_profile.modop_tools_granted", "modop bundle under the catalogue roots")

      measured_nothing?(cited_anywhere) ->
        broken_result("cap_profile.modop_tools_granted", "tool-shaped name cited by any bundle")

      true ->
        %{
          id: "cap_profile.modop_tools_granted",
          remediation:
            "add the tool to `allowedTools` of every role that activates the bundle (the list must " <>
              "cover what a role may LEGITIMATELY reach for — leaving it out does not close it, it " <>
              "wedges the pod on a prompt), stop ordering it in the bundle's sp.md, or declare it " <>
              "in @modop_not_tools with the reason it is not a tool",
          status: if(missing == [] and dead_exemptions == [], do: :pass, else: :fail),
          evidence:
            Enum.sort(missing) ++
              for(
                n <- dead_exemptions,
                do: "@modop_not_tools: #{n} is cited by no bundle — purge it"
              ),
          note:
            "#{length(bundles)} bundles x #{length(profiles)} profiles, " <>
              "#{MapSet.size(cited_anywhere)} tool-shaped names cited, " <>
              "#{map_size(@modop_not_tools)} declared non-tools"
        }
    end
  end

  @tool_cite_re ~r/\b(?:mcp__[a-z0-9_]+|[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+)\b/

  # `{name, allowedTools, disallowedTools, modops}` per cap-profile of EVERY installed catalogue root.
  defp catalogue_profiles(root) do
    root
    |> catalogue_roots()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "cap_profile/canon/cap-profiles/*.yaml")))
    |> Enum.map(fn path ->
      spec = path |> YamlElixir.read_from_file!() |> Map.get("spec", %{})
      scope = Map.get(spec, "scope", %{})
      ms = Map.get(spec, "modop_set", %{})

      {Path.basename(path, ".yaml"), string_list(scope["allowedTools"]),
       string_list(scope["disallowedTools"]),
       string_list(Map.get(ms, "default")) ++ string_list(Map.get(ms, "optional"))}
    end)
  end

  # `{bundle_name, relative_path, cited_names}` per modop bundle.
  defp catalogue_modop_bundles(root) do
    root
    |> catalogue_roots()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "cap_profile/canon/modop-bundles/*/sp.md")))
    |> Enum.map(fn path ->
      cited = @tool_cite_re |> Regex.scan(File.read!(path)) |> List.flatten() |> Enum.uniq()
      {path |> Path.dirname() |> Path.basename(), Path.relative_to(path, root), cited}
    end)
  end

  # BOTH shipped catalogues, and the plural is the point: `brainstorming` lives in the SYSTEM one
  # while the business roles live in the other, so a check reading a single root would have found
  # the bundle and none of its carriers — or the reverse — and passed on an empty intersection.
  defp catalogue_roots(root),
    do: [Path.join(root, "priv/catalogue"), Path.join(root, "priv/catalogue-system")]

  defp string_list(nil), do: []
  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_), do: []

  # `spec.project` CARRIES TWO POPULATIONS IN ONE SLOT and only one of them was ever written down.
  # The catalogue schema declares four keys with `additionalProperties: false`; the pilot injects
  # four MORE at dispatch (`repo`, `base_sha`, `gate_base_sha`, `pr_base_branch`), read by live code
  # and validated by nothing. The contradiction was silent in both directions: a reader of the
  # schema concluded a catalogue could not pin a base, a reader of the code concluded the schema
  # allowed one.
  #
  # The two halves stay APART deliberately (a card that set `base_sha` would validate and then be
  # overwritten at every dispatch — a knob that reads as configuration and does nothing). What must
  # not happen is the two lists drifting, which is why this wall exists: every key the resolver
  # WRITES must be declared on one side or the other, and no key may be on both.
  @doc false
  def check_cap_profile_project_keys(root) do
    resolver_rel = "lib/fleet/pilot/step_dispatcher/project_resolver.ex"
    schema_rel = "priv/cap_profile/schema/cap-profile-v2.5.json"

    schema_keys = schema_project_keys(root, schema_rel)
    runtime_keys = MapSet.new(Fleet.CapProfile.runtime_project_keys())
    written = resolver_project_keys(quoted!(root, resolver_rel))

    undeclared = written |> Enum.reject(&(&1 in schema_keys or &1 in runtime_keys)) |> Enum.sort()
    both = schema_keys |> Enum.filter(&(&1 in runtime_keys)) |> Enum.sort()

    cond do
      measured_nothing?(schema_keys) ->
        broken_result(
          "cap_profile.project_keys_declared",
          "property under spec.project in #{schema_rel}"
        )

      measured_nothing?(written) ->
        broken_result("cap_profile.project_keys_declared", "key written into the project map")

      true ->
        %{
          id: "cap_profile.project_keys_declared",
          remediation:
            "declare the new `spec.project` key in the catalogue schema (an operator may set it) " <>
              "or in `Fleet.CapProfile.runtime_project_keys/0` (the pilot injects it) — never both, " <>
              "never neither",
          status: if(undeclared == [] and both == [], do: :pass, else: :fail),
          evidence:
            cond do
              undeclared != [] ->
                ["#{resolver_rel}: project keys declared nowhere #{inspect(undeclared)}"]

              both != [] ->
                ["#{schema_rel}: keys declared as BOTH catalogue and runtime #{inspect(both)}"]

              true ->
                []
            end,
          note:
            "#{MapSet.size(schema_keys)} catalogue keys + #{MapSet.size(runtime_keys)} runtime-injected, disjoint"
        }
    end
  end

  defp schema_project_keys(root, rel) do
    root
    |> Path.join(rel)
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["properties", "spec", "properties", "project", "properties"])
    |> Kernel.||(%{})
    |> Map.keys()
    |> MapSet.new()
  end

  # Keys of the map literal the resolver returns — from the AST, so a key named only in a comment
  # cannot green this, and a key added to the map cannot hide from it.
  defp resolver_project_keys(ast) do
    ast
    |> collect(fn
      {:%{}, _, pairs} when is_list(pairs) ->
        keys = for {k, _v} <- pairs, is_binary(k), do: k
        if "repo_path" in keys, do: keys, else: nil

      _ ->
        nil
    end)
    |> List.flatten()
    |> MapSet.new()
  end

  # Keys of the `@tool_effects` module attribute, read from the AST — never from a grep, for the
  # same reason as `deftool_names/1`: a comment quoting a tool name must not be able to green this.
  defp tool_effect_names(ast) do
    ast
    |> collect(fn
      {:@, _, [{:tool_effects, _, [{:%{}, _, pairs}]}]} when is_list(pairs) ->
        for {k, _v} <- pairs, is_binary(k), do: k

      _ ->
        nil
    end)
    |> List.flatten()
    |> MapSet.new()
  end

  # ── An `eval` door that reaches the forge must START its transport ───────
  # `LCARS_TOOL_EVAL=1` skips the whole deployment-config body of `config/runtime.exs` — that is
  # what the flag is FOR — so a release `eval` LOADS the app without STARTING it. `Fleet.Forge`'s
  # Finch pool is supervised by the app, so it does not exist, and the first forge call dies on
  # `** (ArgumentError) unknown registry: Fleet.Forge.Finch`.
  #
  # ⚠ THIS HAS NOW BEEN FOUND TWICE, ON TWO DIFFERENT DOORS, WITH THE SAME MESSAGE. `eval_migrate`
  # carries the scar and its fix inline; `CatalogueLifecycle`'s two doors were written afterwards
  # and reintroduced it, measured on a bench 2026-08-16 — `lcars catalogue list` printed the
  # ArgumentError under its own "the forge did not answer" line, i.e. a network diagnostic for a
  # startup failure. Unit tests cannot catch it: they inject forge doubles, so the path that needs
  # the pool is taken by nobody.
  #
  # THE RULE IS FILE-LEVEL AND THAT IS DELIBERATE. Deciding per function whether a door "reaches"
  # the forge means following calls across modules — fragile, and wrong the day an indirection is
  # added. A file that defines an `eval` door AND names `Fleet.Forge` is a file whose door can
  # reach the forge; it owes the start. The false positive (a door that names Forge without
  # calling it) costs three lines; the false negative costs a bench session.
  @doc false
  def check_eval_doors_start_transport(root) do
    files =
      Path.wildcard(Path.join(root, "lib/**/*.ex"))
      |> Enum.filter(fn f ->
        src = File.read!(f)
        src =~ ~r/^\s*def eval_/m and src =~ "Fleet.Forge"
      end)

    missing =
      for f <- files,
          src = File.read!(f),
          not (src =~ "finch_spec"),
          do: Path.relative_to(f, root)

    %{
      id: "eval_doors.transport_started",
      remediation:
        "start the Finch pool in the eval door (`Supervisor.start_link([Fleet.Forge.finch_spec()], " <>
          "strategy: :one_for_one)`) — a release `eval` loads the app without starting it, so the " <>
          "first forge call dies on `unknown registry: Fleet.Forge.Finch`, under whatever error " <>
          "line the door prints for a forge that did not answer",
      status: if(files != [] and missing == [], do: :pass, else: :fail),
      evidence:
        cond do
          files == [] ->
            ["INSTRUMENT BROKEN — no file defines an `eval` door AND names Fleet.Forge"]

          true ->
            Enum.sort(missing)
        end,
      note: "#{length(files)} forge-reaching `eval` door file(s), each starting its own transport"
    }
  end

  # ── Catalogue install paths: ONE fact, THREE languages ───────────────────
  # `Fleet.Layout` says where the installed catalogues sit and where the image's seeds sit.
  # `bin/lcars` reads both and `deploy/lib/provision-lib.sh` WRITES one of them, and neither can
  # call Elixir — so the same paths exist three times, in languages that have no way to agree by
  # construction.
  #
  # What a divergence costs is worse than a crash, and the provisioning half is the expensive one:
  # `45-catalogues` would converge a directory the runtime never reads. Every boot would clone the
  # installed catalogues, report them converged, and the fleet would run on the bundled one alone
  # while announcing three. Nothing errors and nothing is logged. The CLI half is milder but hits
  # at the worst moment — degraded `catalogue list` (no release reachable) prints the material of a
  # cache nobody runs on, which is exactly when the operator has no second source to check it
  # against.
  #
  # Same family as the four provisioning lists locked above, and the same fix — the shells' DEFAULTS
  # are read out of the scripts and compared to what the module derives.
  #
  # The env overrides (`LCARS_CATALOGUES_*`, `PROV_CATALOGUES_DIR`) are deliberately not checked: an
  # operator pointing them elsewhere is answering for both halves themselves. What must agree is
  # what happens when nobody sets anything, which is every deployment.
  #
  # ⚠ THE PROVISIONING HALF IS A SIBLING TREE, AND ONE LEGITIMATE CONTEXT DOES NOT CARRY IT: the
  # image BUILD stage copies `fleet` ALONE and then runs this gate. Measured 2026-08-16 — adding
  # the third source turned the image build red on a file it cannot have. Absence is read at the
  # TREE level, like the provisioning lists above: no `deploy` tree = out of scope, SKIPPED and
  # NAMED in the note; tree present and the default gone = the real defect, FAIL.
  @doc false
  def check_catalogue_paths_locked(root) do
    layout = "lib/fleet/layout.ex"
    cli = "bin/lcars"
    lib = "deploy/lib/provision-lib.sh"
    layout_src = read_or_empty(root, layout)
    cli_src = read_or_empty(root, cli)
    lib_src = read_or_empty(root, lib)

    # Read from the SOURCE, not by calling the module: this check is classified into
    # `Fleet.Application`, which may not reference foundation's `Fleet.Layout` — and a boundary is
    # not widened to let a lint reach across it. Reading both files is also the truer comparison:
    # the fact under test is what the two SOURCES say, and a runtime value could agree with neither.
    attrs =
      Map.new(
        ~w(platform_root catalogues_dirname installed_catalogues_root),
        &{&1, module_attribute(layout_src, &1)}
      )

    expected =
      if Enum.any?(attrs, fn {_k, v} -> is_nil(v) end) do
        nil
      else
        %{
          "LCARS_CATALOGUES_DIR" => attrs["installed_catalogues_root"],
          "LCARS_CATALOGUES_SHIPPED" => "#{attrs["platform_root"]}/#{attrs["catalogues_dirname"]}"
        }
      end

    # `${VAR:=default}` in the lib, `${VAR:-default}` in the CLI — two different shell operators for
    # the same fact. `shell_default/2` reads both, because the difference is about who ASSIGNS, not
    # about what the default IS.
    deploy? = File.dir?(Path.expand("deploy", root))

    sources =
      [{cli, cli_src, expected || %{}}] ++
        if deploy?, do: [{lib, lib_src, lib_expected(expected)}], else: []

    mismatches =
      for {file, src, wanted} <- sources,
          {var, want} <- wanted,
          got = shell_default(src, var),
          got != want,
          do: "#{var}: #{file} defaults to #{inspect(got)}, #{layout} says #{inspect(want)}"

    missing =
      for {file, src, wanted} <- sources,
          {var, _} <- wanted,
          is_nil(shell_default(src, var)),
          do: "#{var} (#{file})"

    %{
      id: "catalogue.install_paths_locked",
      remediation:
        "make bin/lcars and deploy/lib/provision-lib.sh agree with Fleet.Layout (@platform_root, " <>
          "@catalogues_dirname, @installed_catalogues_root) — provisioning that converges a " <>
          "directory the runtime does not read reports every catalogue installed and serves none",
      status:
        if(not is_nil(expected) and mismatches == [] and missing == [], do: :pass, else: :fail),
      evidence:
        cond do
          is_nil(expected) ->
            [
              "#{layout}: INSTRUMENT BROKEN — a catalogue path attribute is gone or renamed; " <>
                "this check measured nothing"
            ]

          missing != [] ->
            [
              "no shell default for #{inspect(Enum.sort(missing))} — that half stopped carrying " <>
                "the path"
            ]

          true ->
            Enum.sort(mismatches)
        end,
      note:
        "3 catalogue paths, one fact each, agreed between #{layout} and #{cli}" <>
          if(deploy?,
            do: " and #{lib}",
            else:
              " · #{lib} NOT CHECKED here (tree absent from this artifact — runtime-only context)"
          )
    }
  end

  # The provisioning lib carries ONE of the two paths — the installed cache, which `45-catalogues`
  # writes. It has no business with the image's seeds: it never reads them.
  defp lib_expected(nil), do: %{}
  defp lib_expected(exp), do: %{"PROV_CATALOGUES_DIR" => exp["LCARS_CATALOGUES_DIR"]}

  defp read_or_empty(root, rel) do
    path = Path.join(root, rel)
    if File.regular?(path), do: File.read!(path), else: ""
  end

  # `@name "value"` — the literal as the module declares it.
  defp module_attribute(source, name) do
    case Regex.run(~r/^\s*@#{name}\s+"([^"]*)"/m, source) do
      [_, value] -> value
      nil -> nil
    end
  end

  # `VAR="${VAR:-<default>}"` — the DEFAULT only, never the override. An operator pointing the env
  # elsewhere is answering for both halves themselves; what must agree is what happens when nobody
  # sets anything, which is every deployment.
  defp shell_default(source, var) do
    case Regex.run(~r/\$\{#{var}:[-=]([^}]*)\}/, source) do
      [_, default] -> default
      nil -> nil
    end
  end

  # ── A declared capability must be EXERCISABLE ────────────────────────
  # A capability is a permission the runtime resolves — `require_onboarder` asks "does this role
  # carry `onboarder`?" and opens the portfolio verbs. So a role can declare one and carry NONE of
  # the tools it opens: the gate would admit the pod, and no call ever reaches the gate. The
  # declaration then grants nothing and describes nothing, which is worse than absent — measured on
  # `architect`, which declared `onboarder` for a transition that had ended, and whose own
  # `allowedTools` comment said the portfolio belonged to starfleet. It stayed green for weeks and
  # made `onboarder` look like a capability with two carriers, which is the fact the cardinality
  # regimes were reasoned from.
  #
  # DERIVED END TO END — no table of capability names lives here, which is the point. Three reads
  # of the AST chain together: a `require_*` gate is a `defp` whose body calls
  # `role_has_capability?(role, :cap)`; a Delegation function is gated by whichever `require_*` its
  # body calls; a tool carries a capability when its dispatch clause reaches such a function. Add a
  # gate for a new capability and this check covers it with no edit.
  #
  # Only TOOL-GATED capabilities are checkable, and the others are silently out of scope on purpose:
  # `producer` is selected by a card, `exception_judge` and `conflict_resolver` are resolved by the
  # runtime to spawn someone. Nothing about them is exercised by the role reaching for a tool, so
  # there is no allow-list to compare against.
  #
  # LIMIT, named rather than papered over: this proves the BUNDLED catalogues, because half its
  # evidence is the runtime's own source and a release has no AST. A third-party catalogue declaring
  # an inert capability is not covered — its boot refuses an unresolvable capability, never a
  # useless one.
  @doc false
  def check_capabilities_exercisable(root) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)
    deleg_rel = "lib/fleet/mcp/pod_tools/delegation.ex"
    tools_rel = "lib/fleet/mcp/pod_tools.ex"

    deleg_ast = quoted!(root, deleg_rel)
    gates = capability_gates(deleg_ast)
    gated_delegations = delegation_capabilities(deleg_ast, gates)
    tools_by_capability = capability_tools(quoted!(root, tools_rel), gated_delegations)

    inert =
      for role <- scan_catalogue_roles(root),
          cap <- role.capabilities,
          tools = Map.get(tools_by_capability, cap),
          tools != nil,
          not Enum.any?(tools, &(("mcp__fleet__" <> &1) in role.allowed_tools)),
          do: "#{role.name} declares #{cap} and carries none of its tools"

    # INSTRUMENT GUARD, same reasoning as `mcp.tools_gated`: every finding here is an ABSENCE, and
    # an AST shape change would empty the derivation and report the same clean absence. Two gates
    # exist today; the floor is set under that, not at it.
    broken =
      cond do
        map_size(gates) < 2 -> "only #{map_size(gates)} require_* gate(s) derived (expected 2+)"
        map_size(tools_by_capability) < 2 -> "only #{map_size(tools_by_capability)} capability"
        true -> nil
      end

    %{
      id: "roles.capabilities_exercisable",
      remediation:
        "either drop the capability from the cap-profile, or add at least one of the tools it " <>
          "gates to that role's allowedTools — a capability that opens no reachable tool " <>
          "authorizes nothing and misdescribes the role",
      status: if(is_nil(broken) and inert == [], do: :pass, else: :fail),
      evidence:
        cond do
          broken -> ["#{deleg_rel}: INSTRUMENT BROKEN — #{broken}; this check measured nothing"]
          inert != [] -> Enum.sort(inert)
          true -> []
        end,
      note:
        "#{map_size(tools_by_capability)} tool-gated capabilities derived from the AST; " <>
          "card-selected and runtime-resolved capabilities are out of scope by nature"
    }
  end

  # `defp require_x(...)` whose body asks `role_has_capability?(_, :cap)` — the gate, and the
  # capability it gates, read from the tree so a mention in a comment cannot answer for it. A gate
  # asking about several capabilities is skipped rather than guessed: there would be no single
  # answer to "which tools does this capability open".
  defp capability_gates(ast) do
    ast
    |> collect(fn
      {:defp, _, [head, [do: body]]} ->
        with name when not is_nil(name) <- def_name(head),
             [cap] <- body |> collect(&capability_asked/1) |> Enum.uniq() do
          {name, to_string(cap)}
        else
          _ -> nil
        end

      _ ->
        nil
    end)
    |> Map.new()
  end

  defp capability_asked({:role_has_capability?, _, [_role, cap]}) when is_atom(cap), do: cap
  defp capability_asked(_), do: nil

  # A `Delegation` function is gated by whichever `require_*` its own body calls.
  defp delegation_capabilities(ast, gates) do
    ast
    |> collect(fn
      {:def, _, [head, [do: body]]} ->
        caps =
          body
          |> collect(fn
            {fun, _, _} when is_atom(fun) -> Map.get(gates, fun)
            _ -> nil
          end)
          |> Enum.uniq()

        case {def_name(head), caps} do
          {nil, _} -> nil
          {_name, []} -> nil
          {name, caps} -> {name, caps}
        end

      _ ->
        nil
    end)
    |> Map.new()
  end

  # capability => the tool names that reach it, inverted from the dispatch clauses.
  defp capability_tools(tools_ast, gated_delegations) do
    tools_ast
    |> dispatch_clauses()
    |> Enum.flat_map(fn {tool, clauses} ->
      clauses
      |> Enum.flat_map(fn %{body: body} ->
        collect(body, fn
          {{:., _, [{:__aliases__, _, aliases}, fun]}, _, _} ->
            if List.last(aliases) == :Delegation, do: Map.get(gated_delegations, fun), else: nil

          _ ->
            nil
        end)
      end)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.map(&{&1, tool})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # ── Seam surface ─────────────────────────────────────────────────────
  # The `conforming/2` guard turns a misconfigured seam into a named error instead of an
  # UndefinedFunctionError raised deep inside a half-finished gesture. It can only see what a
  # behaviour DECLARES — so a seam op nobody wrote down is a call the guard vouches for without
  # having checked it. Every seam call must be covered by a @callback of the behaviour on its path; the three
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
    Fleet.MCP.PodTools.Delegation.ForgeWriter,
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
  # and `html_url` arrived in payloads already fetched (`get_pull`, `issue_get`, `reviews`) and NO
  # line of `lib/` touched them. That list was EXACTLY what the architect had spent three campaigns
  # rebuilding — and one command produced it, with no bench and no agent.
  #
  # `submitted_at` is READ (the reviews carry their substance to the
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
      "a forge-supplied URL carries whatever host ANSWERED, which is not necessarily the one we " <>
        "address — the container reaches `http://forge:3000` where a browser reaches a published " <>
        "port, so handing it on as-is would propagate the wrong host. No reader today: that is " <>
        "the state, not a plan"
  }

  # EVERY test corpus in the repo — bats AND python — and what happens to it. `:gated` = shell_gate discovers it;
  # `{:out, why}` = deliberately outside, ON RECORD. A corpus absent from this map fails the check.
  #
  # WHY THIS EXISTS, and it cost three findings in one evening (2026-08-05): nothing in this repo
  # answered "which test corpora exist, and which ones do we run". `fleet/deploy/tests`
  # and `fleet/git-hooks/tests` had never been run by any gate, and `fleet/tests/unit/v1` had been
  # failing at `setup` on all 447 of its cases since a tidying commit moved the paths out from under
  # it. All three were found by a `find` run out of curiosity. A corpus nobody runs does not rot
  # loudly — it rots while reporting a coverage it does not provide, which is the most expensive
  # silence a test can keep.
  @test_corpora [
    {"fleet/test", :gated},
    {".claude/skills", :gated},
    {"fleet/deploy/tests", :gated},
    {"fleet/git-hooks/tests", :gated},
    {"fleet/vendor/token_saver/lcars_tests", :gated},
    {"fleet/vendor/token_saver/tests",
     {:out,
      "upstream suites of the vendored engine (7 884 l). They arbitrate UPSTREAM merges — " <>
        "update_vendor.sh plays them at the moment they serve — and gating them would make every " <>
        "commit here pay for a question nobody is asking"}}
  ]

  # `test_*.py` is a PYTEST NAMING CONVENTION, and it only means "this is a test" INSIDE a test
  # directory. A source tree is free to call a module `test_output.py` because it PROCESSES test
  # output — the vendored token-saver does exactly that, in `src/processors/`. Counting it as an
  # undeclared corpus would force a record saying "this test suite is deliberately ungated", which
  # would be a lie about a production file: the wall would be satisfied and the sentence false.
  #
  # The discriminant is the PATH, not the name: a file under a source root (`src/`, `lib/`) is not a
  # test unless a test directory appears in its path too. `.bats` needs no such care — that
  # extension has one meaning wherever it sits.
  defp test_corpus_member?(path) do
    parts = Path.split(path)

    cond do
      Path.extname(path) == ".bats" -> true
      Enum.any?(parts, &Regex.match?(~r/^tests?$|_tests?$/, &1)) -> true
      Enum.any?(parts, &(&1 in ["src", "lib"])) -> false
      true -> true
    end
  end

  @doc false
  # A SUITE DOES NOT GO RED OVER A TEST THAT WAS REMOVED — it goes green over one fewer.
  #
  # Measured 2026-08-06 while replaying the GC-prose transplant: `forge_protocol.ex` went from 13
  # `iex>` lines to zero, `mix test` reported "0 failures" on both sides, and the count moved from
  # 13 doctests to 10 with nothing to see. The examples were round-trip assertions — the predicate
  # recognises what the builder records — and `test/…/forge_protocol_test.exs` still carries
  # `doctest Fleet.Forge.Protocol`. The file LOOKS covered and executes nothing.
  #
  # This wall answers the DECIDABLE half of that: a declaration whose module holds no example runs
  # no test. It does NOT claim to notice a deleted test file or a shrunk suite — those need a
  # recorded floor, which is state that rots. One decidable question, answered without state.
  def check_doctest_declarations_have_examples(root) do
    declarations =
      Path.wildcard(Path.join(root, "test/**/*.exs"))
      |> Enum.flat_map(fn f ->
        case File.read(f) do
          {:ok, src} ->
            Regex.scan(~r/^\s*doctest\s+([A-Za-z0-9_.]+)/m, src, capture: :all_but_first)

          _ ->
            []
        end
      end)
      |> List.flatten()
      |> Enum.uniq()

    empty =
      Enum.filter(declarations, fn mod ->
        path = Path.join([root, "lib", Macro.underscore(mod) <> ".ex"])

        case File.read(path) do
          {:ok, src} -> not String.contains?(src, "iex>")
          # An unresolvable module is NOT reported as empty: the derivation may simply be wrong for
          # a module whose file does not follow the convention, and accusing it would be the wall
          # crying about its own blind spot.
          _ -> false
        end
      end)

    unresolved =
      Enum.reject(declarations, fn mod ->
        File.exists?(Path.join([root, "lib", Macro.underscore(mod) <> ".ex"]))
      end)

    broken =
      cond do
        declarations == [] ->
          "no `doctest` declaration found under test/; this check measured nothing"

        length(unresolved) == length(declarations) ->
          "no declared module resolved to a source file"

        true ->
          nil
      end

    %{
      id: "tests.doctest_declarations_have_examples",
      remediation:
        "restore the `iex>` examples in the module, or drop the `doctest` line — a declaration " <>
          "over a module with no example is a test file that looks covered and runs nothing",
      status: if(is_nil(broken) and empty == [], do: :pass, else: :fail),
      evidence:
        cond do
          broken ->
            ["INSTRUMENT BROKEN — #{broken}"]

          empty != [] ->
            ["doctest declared over a module with NO `iex>` example: #{inspect(empty)}"]

          true ->
            []
        end,
      # Le compte, pas l'affirmation : « all backed » se lit encore quand l'evidence juste au-dessus
      # nomme un module qui ne l'est pas. Une note qui contredit son propre verdict apprend a son
      # lecteur a ne plus la lire.
      note:
        "#{length(declarations)} doctest declarations, #{length(declarations) - length(empty)} backed by examples" <>
          if(unresolved == [],
            do: "",
            else: " (#{length(unresolved)} module(s) unresolved, not judged)"
          )
    }
  end

  @doc false
  # A PUBLIC FUNCTION WITH NO `@doc` IS A HOLE IN THE SSoT. The repo's contract rule is that a
  # module's `@moduledoc` carries the domain contract and each public function carries its own
  # `@doc` — machine-visible through `h`/ExDoc. A public function without one answers `h` with
  # nothing, and the caller reads the body instead: the source becomes the contract, and every
  # detail of it becomes load-bearing by accident.
  #
  # WHAT THIS DOES NOT CHECK, and the distinction is the whole reliability of it. It does NOT
  # require the `@moduledoc` to enumerate the public functions — measured on this tree, that rule
  # accuses 157 modules out of 194 (80%), starting with `Fleet.Layout`, whose moduledoc explains a
  # LAYOUT and is right not to be an index. A wall that fires on 80% of correct code is not a wall,
  # it is a nag, and the next person widens it until it stops firing.
  #
  # `@impl` callbacks are EXCLUDED: their contract lives in the behaviour, and restating it per
  # implementation is the duplication this repo refuses elsewhere. OTP callbacks likewise.
  #
  # Calibrated by measurement, in this order: the naive rule accused 80%, "no `@doc`" accused 33
  # modules — dominated by behaviour implementations — and excluding `@impl` left 9 modules and 12
  # functions, four of which were verified BY HAND before anything shipped. Those twelve were
  # documented; the check then starts green, which is the only state a wall may be born in.
  def check_public_functions_documented(root) do
    undocumented =
      Path.wildcard(Path.join([root, "lib", "**", "*.ex"]))
      |> Enum.flat_map(fn path ->
        case File.read(path) do
          {:ok, src} ->
            case undocumented_public_functions(src) do
              [] -> []
              names -> [{Path.relative_to(path, root), names}]
            end

          _ ->
            []
        end
      end)

    scanned = length(Path.wildcard(Path.join([root, "lib", "**", "*.ex"])))

    %{
      id: "docs.public_functions_documented",
      remediation:
        "give the function an `@doc` saying its contract — or `@doc false` if it is public only " <>
          "for a reason the reader must not take as an API. `h Module.fun` answering nothing is " <>
          "the source becoming the contract by default",
      status: if(scanned > 0 and undocumented == [], do: :pass, else: :fail),
      evidence:
        cond do
          scanned == 0 ->
            ["INSTRUMENT BROKEN — no source file scanned under lib/"]

          undocumented != [] ->
            Enum.map(undocumented, fn {p, n} -> "#{p}: #{Enum.join(n, ", ")}" end)

          true ->
            []
        end,
      note:
        "#{scanned} modules scanned, #{length(undocumented)} carrying an undocumented public function"
    }
  end

  # NESTING IS THE POPULATION, NOT A DETAIL OF IT. These matched `^  def` — EXACTLY two spaces, the
  # indentation of a `def` sitting directly under a top-level `defmodule`. A nested module indents
  # its functions by four, so its public functions were not judged undocumented: they were never
  # looked at. The blind spot measured five `def` clauses over two files, and one of them is
  # `ProjectBootstrap.Phase.Clone.clone_or_skip/3` — the system-side git entry point, i.e. the
  # module that carried the sandbox escape this repo fixed by composing `git_safe_config_args/0`.
  # A wall that starts green because its subject is out of frame is the failure class this whole
  # file exists to prevent, one level up: not a hollow green over an empty tree, a hollow green over
  # a tree it declined to enter.
  @def_re ~r/^(\s+)def\s+([a-z_][a-zA-Z0-9_?!]*)/
  @defp_re ~r/^\s+defp?\s/
  @defmodule_re ~r/^(\s*)defmodule\s+([A-Z][A-Za-z0-9_.]*)/

  # `@doc false` COUNTS AS DOCUMENTED, deliberately: it is an explicit statement that the function is
  # public for a mechanical reason and not as an API. Treating it as a miss would push its authors to
  # write a hollow `@doc` instead, which is worse — a sentence nobody meant, in the place a reader
  # trusts most.
  defp undocumented_public_functions(src) do
    otp =
      ~w(start_link init child_spec handle_call handle_cast handle_info terminate code_change handle_continue)

    state =
      src
      |> String.split("\n")
      |> Enum.reduce(
        %{
          public: MapSet.new(),
          documented: MapSet.new(),
          impls: MapSet.new(),
          mods: [],
          doc?: false,
          impl?: false
        },
        fn line, st ->
          trimmed = String.trim_leading(line)

          cond do
            String.starts_with?(trimmed, "@doc") ->
              %{st | doc?: true}

            String.starts_with?(trimmed, "@impl") ->
              %{st | impl?: true}

            String.starts_with?(trimmed, "@spec") ->
              st

            match?([_, _, _], Regex.run(@defmodule_re, line)) ->
              [_, indent, mod] = Regex.run(@defmodule_re, line)
              depth = String.length(indent)
              # A pending `@doc` does not cross a `defmodule`: it belonged to whatever was being
              # written before, and letting it through would credit the nested module's first
              # function with someone else's documentation.
              %{st | mods: [{depth, mod} | pop_to(st.mods, depth)], doc?: false, impl?: false}

            match?([_, _, _], Regex.run(@def_re, line)) ->
              [_, indent, name] = Regex.run(@def_re, line)
              key = {enclosing_module(st.mods, String.length(indent)), name}
              st = if st.impl?, do: %{st | impls: MapSet.put(st.impls, key)}, else: st

              if name in otp do
                %{st | doc?: false, impl?: false}
              else
                st = if st.doc?, do: %{st | documented: MapSet.put(st.documented, key)}, else: st
                %{st | public: MapSet.put(st.public, key), doc?: false, impl?: false}
              end

            Regex.match?(@defp_re, line) ->
              %{st | doc?: false, impl?: false}

            true ->
              st
          end
        end
      )

    state.public
    |> MapSet.difference(state.documented)
    |> MapSet.difference(state.impls)
    |> Enum.sort()
    |> Enum.map(fn
      {nil, name} -> name
      {mod, name} -> "#{mod}.#{name}"
    end)
  end

  # The enclosing module of a `def` = the innermost one indented LESS than it. Closing `end`s are
  # never parsed: popping by indentation does it, because a sibling that follows a nested module is
  # written back at the shallower depth. `nil` for the file's outermost module, so its functions
  # keep printing as bare names — a qualified name means "this one is nested", which is precisely
  # what a reader needs to find it.
  defp pop_to(mods, depth), do: Enum.drop_while(mods, fn {d, _} -> d >= depth end)

  defp enclosing_module(mods, indent) do
    case pop_to(mods, indent) do
      [{_, _} | []] -> nil
      [{_, mod} | _] -> mod
      [] -> nil
    end
  end

  @doc false
  def check_test_corpora_on_record(root) do
    repo = Path.expand("..", root)

    # `-type f` is load-bearing: a DIRECTORY can be named `*.bats` (the vendored bats-core lived in
    # one until the v1 excommunication), and
    # without it the scan reports a corpus that is a folder.
    found =
      case System.cmd(
             "find",
             [
               repo,
               # ELAGUAGE D'ABORD, filtre ensuite. Les quatre arbres ci-dessous ne sont jamais
               # PARCOURUS : `.git` et `_build` par volume, `fleet/tmp` parce qu'il bouge sous les
               # pieds de find (cf. la course decrite au-dessus), les virtualenvs parce qu'ils
               # portent des centaines de suites amont qui ne sont ni a nous ni a declarer —
               # les exclure EST la declaration.
               "(",
               "-name",
               ".git",
               "-o",
               "-name",
               "_build",
               "-o",
               "-name",
               ".venv",
               "-o",
               "-name",
               "site-packages",
               "-o",
               "-path",
               "*/fleet/tmp",
               ")",
               "-prune",
               "-o",
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
               "-print"
             ],
             stderr_to_stdout: true
           ) do
        {out, 0} ->
          out
          |> String.split("\n", trim: true)
          |> Enum.map(&Path.relative_to(&1, repo))
          |> Enum.filter(&test_corpus_member?/1)

        _ ->
          []
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
        not File.dir?(Path.join(repo, "fleet/test")) ->
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
    lib = Path.join(root, "fleet/lib")
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
  # PROBE N°4 of the pattern hunt — "a gesture with no door". The family that produced the tools of
  # lot 1: `issue_retire`, `project_list`, `emergency_stop` all existed as CAPABILITIES the runtime
  # could already execute, and had to be disguised as something else (or were simply unreachable)
  # for want of a tool exposing them. An absence raises no error, which is why it survives: nothing
  # fails, the gesture is just performed sideways.
  #
  # THE SYMMETRIC FAULT COST ONE OF THAT LOT ITS LIFE: `publish_doc` was a door built for a gesture
  # that then reached no one — no canon cap-profile ever granted it — into the one tree that must
  # stay read-only for every agent. A door nobody holds the key to is not harmless: it is an opening
  # that reads as a decision. Removed with the `notes/` subtree it served.
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

  # POD-SCOPED = THE CLAUSE USES THE CHANNEL IDENTITY, not merely receives it. `PodSocketAcceptor`
  # builds `%{pod_id: pod_id}` for EVERY `tools/call`, unconditionally and identically for every
  # tool — so the presence of that key in a clause head says nothing about authorization. Matching
  # `\bpod_id:` alone accepted `%{pod_id: _}`: a clause that pattern-matches the identity and throws
  # it away, then acts globally, was reported as gated. The wall was one underscore wide.
  #
  # Two conditions now, and the second is the one that carries the meaning: the head must BIND the
  # identity to a real variable (`_` and `_pod_id` are discards, and a discard is the tell), and the
  # BODY must mention that variable — the tool's subject is then derived from the channel rather
  # than from the wire, which is the whole property.
  #
  # MEASURED before tightening, because a wall may only be born green: 23 of the 25 tools are
  # ROLE-gated (`require_architect`/`require_onboarder`), every mutator among them, and the only two
  # admitted by this predicate are `get_work_item` and `submit_result` — both bind and both use.
  # The hole was real and nothing was standing in it.
  defp pod_scoped?(%{state: state, body: body}) do
    case Regex.run(~r/pod_id:\s*([a-z][a-zA-Z0-9_]*)/, Macro.to_string(state)) do
      [_, var] -> Macro.to_string(body) =~ ~r/\b#{Regex.escape(var)}\b/
      nil -> false
    end
  end

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
