defmodule Mix.Tasks.Lcars.Contracts.Check do
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
  least one check is `fail`. The `pending` checks (not yet implemented) are
  listed explicitly — no silent cap: a gap not yet covered
  is visible, not masked as "pass".
  """

  use Mix.Task

  @recursive false

  # Each check: %{id, remediation, status: :pass|:fail|:pending, evidence: [..], note}
  # The IMPLEMENTED checks are grounded in the real code (grep/introspection).
  # The PENDING ones would name the remediation that would make them executable.
  # All checks are implemented: `@pending_checks` is empty.
  @pending_checks []

  @impl Mix.Task
  def run(args) do
    quiet? = "--quiet" in args
    Mix.Task.run("compile")

    {overall, checks} = run_checks()

    unless quiet?, do: IO.puts(render_yaml(overall, checks))

    fails = Enum.count(checks, &(&1.status == :fail))
    pend = Enum.count(checks, &(&1.status == :pending))

    Mix.shell().info(
      "contracts.check: #{overall} — #{fails} fail, #{pend} pending, " <>
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
    root = umbrella_root()

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
        # ── Remediation rails ──
        check_result_deadline_cancelled(root),
        check_spawn_gates_wired(root),
        check_gatekeeper_not_a_step(root),
        check_verdict_envelope_unwrapped(root),
        check_no_root_runtime_guard(root),
        # ── Topology lock ──
        check_layering_dependency_graph(root)
        # NB there is no `pipeline.bounded_retry_system_side` rail: it checked the bounded
        # system-side retry of the in-RAM `Executor`, which no longer exists. The forge-rail
        # equivalent = `max_rework_rounds` (StepRunConsumer); to re-contract if needed (backlog).
      ] ++ Enum.map(@pending_checks, &Map.put(&1, :status, :pending))

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
      files: ["apps/fleet_api/lib/fleet/api/ws.ex"],
      pattern: ~r/"event_type"\s*=>/,
      confirm: ~r/"event_type"\s*=>/,
      note: "consommateurs encore sur le tuple legacy \"event_type\""
    })
  end

  # The Loader must normalize v1/v2.5 to a single internal form (unwrap
  # spec.steps). Without it a consumer reads `pipeline["steps"]=nil` on v2.5.
  defp check_pipeline_v25_normalized(root) do
    rel = "apps/fleet_workflow/lib/fleet/workflow/loader.ex"
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
              "#{rel} : clause `defp normalize(%{\"spec\" => %{\"steps\" => ...}})` (déballage v2.5) absente → un consommateur de la workflow_map lit steps=nil"
            ]

          not called? ->
            ["#{rel} : `normalize(yaml)` jamais appelé au load → enveloppe v2.5 non déballée"]

          true ->
            []
        end,
      note:
        "Loader DÉBALLE spec.steps via la CLAUSE DE CODE v2.5 (`defp normalize(%{\"spec\"…})`) ET l'appelle au load — matche le code, pas un commentaire (anti-vert-creux durci)"
    }
  end

  # Every handler referenced in events.yaml must exist, otherwise the route is a
  # phantom handler tolerated silently.
  defp check_events_handlers_exist(root) do
    yaml = Path.join(root, "apps/fleet_event_router/priv/events.yaml")

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
          []
      end

    %{
      id: "events.handlers.exist",
      remediation: "R08 (R5)",
      status: if(missing == [], do: :pass, else: :fail),
      evidence: Enum.map(missing, &"events.yaml → #{&1} (absent)"),
      note:
        "handlers fantômes référencés dans events.yaml (dispatch table vs subscribers directs)"
    }
  end

  # Invariant: the LLM gate (soft + terminal non-adjudicable) is judged by the
  # **gatekeeper** on the pipeline side; `coord` carries no gate spawn, and the
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
      Path.wildcard(Path.join(root, "apps/fleet_coord/lib/**/*.ex"))
      |> Enum.flat_map(fn file ->
        file
        |> grep_lines(~r/NotWiredYet/)
        |> Enum.map(fn {ln, _} -> "#{Path.relative_to(file, root)}:#{ln}" end)
      end)

    gates_coord_dep =
      Path.join(root, "apps/fleet_workflow/lib/fleet/workflow/gates.ex")
      |> grep_lines(~r/coord_backend|CoordBackend/)
      |> Enum.filter(fn {_ln, line} ->
        Regex.match?(~r/coord_backend|CoordBackend/, strip_comment(line))
      end)
      |> Enum.map(fn {ln, _} -> "apps/fleet_workflow/lib/fleet/workflow/gates.ex:#{ln}" end)

    evidence = notwired ++ gates_coord_dep

    %{
      id: "coord.backend.wired_or_pure",
      remediation: "R06/R22 (R4)",
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
      note:
        "gate LLM consolidée gatekeeper (Gates pur) ; pas de NotWiredYet ni délégation coord résiduelle"
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
      files: ["apps/fleet_sp_builder/lib/fleet/sp_builder.ex"],
      pattern: ~r/cap_profile\.spec,\s*(\["lifetime_scope"\]|"lifetime_scope")/,
      note:
        "compose_claude_md lit spec.lifetime_scope (pré-v2.5) au lieu de spec.invocation.lifetime_scope"
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
        "apps/fleet_cap_profile/lib/fleet/cap_profile.ex",
        "apps/fleet_cap_profile/lib/fleet/cap_profile/invariants.ex"
      ],
      pattern: ~r/Map\.get\(spec,\s*"modop_incompatible"/,
      confirm: ~r/modop_incompatible/,
      note:
        "check_modop_incompatible lit spec.modop_incompatible (inexistant) au lieu de spec.modop_set.incompatible"
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
    tb = "apps/fleet_spawner/lib/fleet/spawner/launch_backend/tmux_backend.ex"

    evidence_check(
      %{
        id: "launch.backend_containment_coherent",
        remediation: "R20/F103",
        note:
          "TmuxBackend (remote-control nu, control-path cassé) supprimé ; ne doit pas réapparaître. La voie host containment:none = host_launch.sh (tmux-holder prouvé), pas TmuxBackend (LAUNCH-Q)"
      },
      [
        {not File.exists?(Path.join(root, tb)),
         "#{tb} : TmuxBackend supprimé (F103) — le module ne doit pas réapparaître"},
        {not Regex.match?(~r/LaunchBackend\.TmuxBackend/, File.read!(Path.join(root, rt))),
         "#{rt} : runtime ne doit plus référencer TmuxBackend (backend hors-bwrap supprimé)"}
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
    pod = "apps/fleet_spawner/lib/fleet/spawner/pod.ex"
    mcp = "apps/fleet_spawner/lib/fleet/spawner/pod/mcp_provision.ex"

    evidence_check(
      %{
        id: "mcp.required_for_real_backend",
        remediation: "R14",
        note:
          "pod.ex câble McpProvision.maybe_provision_mcp_config (niveau 1) ET mcp_provision.ex refuse fail-loud :mcp_server_spec_required un backend réel sans spec (niveau 2) — les 2 requis"
      },
      [
        {code_match?(root, pod, ~r/McpProvision\.maybe_provision_mcp_config\(/),
         "#{pod} : McpProvision.maybe_provision_mcp_config non appelé (provisioning MCP débranché du chemin de spawn)"},
        # CONJUNCTIVE confirmation (both regexes on the stripped line): the token
        # must live on a line that IS the error tuple — cf. the hardened
        # anti-hollow-green above (the moduledoc carries the same token in prose).
        {code_match?(root, mcp, ~r/:mcp_server_spec_required/, [
           ~r/:mcp_server_spec_required/,
           ~r/^\s*\{:error,/
         ]), "#{mcp} : pas de fail-loud :mcp_server_spec_required (garde réelle absente)"}
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
      file: "apps/fleet_spawner/lib/fleet/spawner.ex",
      pattern: ~r/:brief_required/,
      missing: "pas de guard :brief_required au boundary spawn_pod",
      note: "spawn_pod doit refuser un pod one-shot sans brief (hors allow_no_brief)"
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
      file: "apps/fleet_sp_builder/lib/fleet/sp_builder.ex",
      pattern: ~r/:skills_missing/,
      missing: "filter_skills filtre les absents en silence",
      note: "filter_skills doit fail-loud {:skills_missing} sur un skill plain absent"
    })
  end

  # The events.yaml key IS the event `type` (the `source` is a separate field,
  # validated by `Fleet.Event.canonical_sources/0`); the registry is keyed by type, there
  # is no dispatch table keyed otherwise. Invariant guarded here: every **consumed**
  # type (`handle_info(%Fleet.Event{type: :X})`, moduledoc examples included)
  # must be a registry key — otherwise the consumer is dead (it waits for a type
  # that cannot be broadcast without `UnregisteredError`). The emitters, for their part, are
  # covered by the fail-loud validation of the broadcast at runtime (an unregistered type
  # crashes its emitter), so this check covers only the consumption side.
  defp check_events_registry_keys_aligned(root) do
    registry = registry_event_keys(root)

    consumed =
      Path.wildcard(Path.join(root, "apps/*/lib/**/*.ex"))
      |> Enum.flat_map(&consumed_event_types/1)
      |> Enum.uniq()

    unregistered = Enum.reject(consumed, &MapSet.member?(registry, &1))

    %{
      id: "events.registry.keys_aligned",
      remediation: "R09/F-08",
      status: if(unregistered == [], do: :pass, else: :fail),
      evidence: Enum.map(unregistered, &"type consommé hors registry : #{&1}"),
      note: "tout type consommé (handle_info %Fleet.Event{type:}) doit être une clé events.yaml"
    }
  end

  defp registry_event_keys(root) do
    yaml = Path.join(root, "apps/fleet_event_router/priv/events.yaml")

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
    pod = "apps/fleet_spawner/lib/fleet/spawner/pod.ex"
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
         "#{pod} : :result_deadline n'est pas un :state_timeout de :monitoring — il ne s'annulerait plus tout seul au changement d'état (SPAWN-CR1, tue les pods permanents au cycle 2)"},
        {not cancels_via_transition?,
         "#{pod} : pas de transition `{:next_state, :extracting, …}` — le résultat arriverait sans quitter :monitoring → state_timeout :result_deadline jamais annulé"},
        {has_hack?,
         "#{pod} : band-aid `forever -> 60_000` encore présent — revert vers 60s + vrai fix (n'armer que si task active)"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    %{
      id: "spawner.result_deadline_cancelled",
      remediation: "R-result-deadline",
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
      note:
        "result_deadline = state_timeout de :monitoring, annulé NATIVEMENT par la transition :monitoring → :extracting à l'arrivée du résultat ; n'arme que si pas forever + fire ne tue que si task active ; pas de band-aid 60ks"
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
    pod = "apps/fleet_spawner/lib/fleet/spawner/pod.ex"

    # The env construction + the credentials gate live in Pod.LaunchEnv (the env/creds cluster extracted
    # from do_launch). do_launch (pod.ex) calls LaunchEnv.build, which wires Gate.validate. The gate is
    # thus wired to the spawn by TWO conjoint facts: pod.ex calls LaunchEnv.build AND LaunchEnv.build
    # contains Gate.validate (stronger than the old single-file check where everything was inline in pod.ex).
    launch_env = "apps/fleet_spawner/lib/fleet/spawner/pod/launch_env.ex"
    gate = "apps/fleet_credentials/lib/fleet/credentials/gate.ex"

    # Each check = {relative_file, regex, label}. The label names the expected file.
    items =
      for {rel, re, label} <- [
            {pod, ~r/CapProfile\.validate\(/,
             "CapProfile.validate (containment G24/F-CONT-RISK, do_allocate)"},
            {pod, ~r/LaunchEnv\.build\(/,
             "Pod.LaunchEnv.build câblé au spawn (do_launch enchaîne env + portes credentials)"},
            {launch_env, ~r/Fleet\.Credentials\.Gate\.validate\(/,
             "Fleet.Credentials.Gate.validate (porte scope+plan, dans LaunchEnv.build)"},
            {gate, ~r/ScopeValidator\.validate\(/,
             "ScopeValidator.validate (délégation scope-coverage)"},
            {gate, ~r/PlanValidator\.validate\(/,
             "PlanValidator.validate (délégation plan payant)"}
          ],
          do:
            {code_match?(root, rel, re),
             "#{rel} : #{label} absente (porte creuse / délégation vide)"}

    evidence_check(
      %{
        id: "spawn.gates_wired",
        remediation: "R-spawn-gates",
        note:
          "porte containment (CapProfile.validate, do_allocate) dans pod.ex + porte credentials câblée au spawn via Pod.LaunchEnv (do_launch appelle LaunchEnv.build, qui enchaîne Fleet.Credentials.Gate.validate), ET la porte délègue réellement scope (ScopeValidator) + plan (PlanValidator) dans gate.ex — 5 vérifs, 2 niveaux"
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
    dir = "apps/fleet_workflow/priv/canon/workflow_maps"
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
        "gatekeeper = juge d'exception (dispatch sur gate non-tranchable), jamais un step role:gatekeeper (§L441 ; GATE-D1)"
    }
  end

  # StepRunConsumer must unwrap the worker envelope `%{status, result}` before reading the
  # decision (resume_gate/gate_result) OR evaluating the gate (gate_decide) — otherwise
  # decision/outputs stay buried → false escalation / wrongful hard-gate.
  defp check_verdict_envelope_unwrapped(root) do
    step_run = "apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex"
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
              "#{step_run} : ABSENT — le verdict-route (déballage enveloppe worker) a disparu (#11) ; si déplacé, MAJ ce rail"
            ]

          not unwrap_present? ->
            ["#{step_run} : verdict_route ne déplie pas l'enveloppe worker (#11)"]

          true ->
            []
        end,
      note:
        "déplier %{status,result} avant de lire decision (StepRunConsumer) ; idem avant Gates.evaluate côté StepRunConsumer (le rail forge-driven, vérifié par test). Rail EXIGE le fichier (pas de pass-si-absent — anti-vert-creux durci)"
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
      missing: "pas de self-check anti-root au boot (FORGE-D1)",
      note:
        "le daemon doit refuser getuid()==0 au boot (boot guard) ; User=lcars systemd seul ne couvre pas un run dev/manuel en root"
    })
  end

  # ── Combinators (3 families of data-driven checks) ───────────────────
  # 8 of the 17 checks are pure instantiations of 3 families; each migrated
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
        Path.join(root, rel)
        |> grep_lines(opts.pattern)
        |> Enum.filter(fn {_ln, line} -> Regex.match?(confirm, strip_comment(line)) end)
        |> Enum.map(fn {ln, _} -> "#{rel}:#{ln}" end)
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

  defp umbrella_root do
    cwd = File.cwd!()
    if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
  end

  # ── Topology lock ──────────────────────────────────────────────
  # `priv/allowed_graph.yaml` freezes the REAL dep graph. Three facets, all fail-closed:
  #   (a) mix.exs BIDIRECTIONAL: real compile edge not declared = fail; declared phantom edge = fail.
  #   (d) RING monotonicity: an UPWARD compile dep (lower ring -> upper) that is non-seam = fail (the PubSub via
  #       event_router R0 is exempt by construction — it is not a layer dep).
  #   (b) LIVE seams: each declared seam carries a `marker` that MUST match code of the `from` app;
  #       if it no longer matches, the seam is dead (the code moved) and the yaml is stale -> fail.
  # Encodes the CURRENT graph -> born GREEN; any dep addition/removal turns it red until the yaml is
  # re-declared (forces awareness of a topology change). Unreadable yaml -> fail-closed.
  defp check_layering_dependency_graph(root) do
    yaml = Path.join(root, "apps/fleet_event_router/priv/allowed_graph.yaml")

    case YamlElixir.read_from_file(yaml) do
      {:ok, %{"rings" => rings, "edges" => declared_edges} = spec} ->
        seam_list = spec["seams"] || []
        seams = MapSet.new(seam_list, &{&1["from"], &1["to"]})
        declared = MapSet.new(declared_edges, &{&1["from"], &1["to"]})
        real = MapSet.new(real_mix_edges(root))

        undeclared =
          for {f, t} <- MapSet.difference(real, declared),
              do: "arete compile REELLE non declaree : #{f} -> #{t}"

        phantom =
          for {f, t} <- MapSet.difference(declared, real),
              do: "arete DECLAREE fantome (absente des mix.exs) : #{f} -> #{t}"

        upward =
          for {f, t} <- real,
              rf = rings[f],
              rt = rings[t],
              is_integer(rf) and is_integer(rt) and rf < rt and not MapSet.member?(seams, {f, t}),
              do: "dep compile MONTANTE non-seam : #{f}(R#{rf}) -> #{t}(R#{rt})"

        dead_seams =
          for s <- seam_list,
              not seam_alive?(root, s["from"], s["marker"]),
              do:
                "seam MORT (marker `#{s["marker"]}` absent du code de #{s["from"]}) : #{s["from"]} -> #{s["to"]}"

        evidence = undeclared ++ phantom ++ upward ++ dead_seams

        %{
          id: "layering.dependency_graph",
          remediation:
            "D4/A2 — MAJ apps/fleet_event_router/priv/allowed_graph.yaml, ou corriger la dep/seam",
          status: if(evidence == [], do: :pass, else: :fail),
          evidence: evidence,
          note:
            "topologie declaree = graphe compile reel (bidirectionnel) + monotonicite ring + seams vivants ; " <>
              "PubSub (Bus, R0) exempt"
        }

      _ ->
        %{
          id: "layering.dependency_graph",
          remediation: "D4/A2",
          status: :fail,
          evidence: ["priv/allowed_graph.yaml illisible ou malforme (fail-closed)"],
          note: "yaml de topologie absent/invalide"
        }
    end
  end

  # Real compile edges extracted from the mix.exs files (`{:fleet_x, in_umbrella: true}`), comment stripped (a
  # dep in a comment does not count). Returns a set of `{from_app, to_app}` tuples.
  defp real_mix_edges(root) do
    dep_re = ~r/\{:(fleet_\w+),\s*in_umbrella:\s*true\}/

    Path.wildcard(Path.join(root, "apps/fleet_*/mix.exs"))
    |> Enum.flat_map(fn mix_path ->
      from = mix_path |> Path.dirname() |> Path.basename()

      mix_path
      |> grep_lines(dep_re)
      |> Enum.flat_map(fn {_ln, line} ->
        dep_re
        |> Regex.scan(strip_comment(line))
        |> Enum.map(fn [_full, to] -> {from, to} end)
      end)
    end)
  end

  # A seam is LIVE if its `marker` (regex) matches a code line (comment stripped) of the `from` app.
  defp seam_alive?(root, from_app, marker) when is_binary(from_app) and is_binary(marker) do
    re = Regex.compile!(marker)

    root
    |> Path.join("apps/#{from_app}/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.any?(fn f ->
      f
      |> grep_lines(re)
      |> Enum.any?(fn {_ln, line} -> Regex.match?(re, strip_comment(line)) end)
    end)
  end

  defp seam_alive?(_root, _from, _marker), do: true

  defp render_yaml(overall, checks) do
    header = "status: #{overall}\nchecks:"

    body =
      Enum.map_join(checks, "\n", fn c ->
        ev =
          case Map.get(c, :evidence, []) do
            [] -> ""
            list -> "\n    evidence:\n" <> Enum.map_join(list, "\n", &"      - #{&1}")
          end

        "  - id: #{c.id}\n" <>
          "    remediation: #{c.remediation}\n" <>
          "    status: #{c.status}\n" <>
          "    note: #{Map.get(c, :note, "")}" <> ev
      end)

    header <> "\n" <> body
  end
end
