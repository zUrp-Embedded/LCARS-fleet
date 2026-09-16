defmodule Mix.Tasks.Lcars.Contracts.Check.Runtime do
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Inspects selected runtime integration rules through source patterns and ASTs.

  Presence checks recognise expected spellings and residue checks reject known
  obsolete forms. Coverage varies by function: some strip comments/doc blocks,
  others inspect raw text. None traces the runtime call graph or proves that
  matched guards execute. Read each check's scope and population guard.
  """

  alias Mix.Tasks.Lcars.Contracts.Check.Support

  import Mix.Tasks.Lcars.Contracts.Check.Support

  # Workflow.Gates should leave LLM judgement to the gatekeeper.
  # Inspect only gates.ex; an injected seam moved to a neighbouring file is outside this check.
  @doc false
  @spec check_gates_no_runtime_seam(String.t()) :: Support.result()
  def check_gates_no_runtime_seam(root) do
    rel = "lib/fleet/workflow/gates.ex"
    gates_path = Path.join(root, rel)

    if File.exists?(gates_path) do
      gates_seams =
        gates_path
        |> File.read!()
        |> Code.string_to_quoted!()
        |> collect(&runtime_seam/1)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&"#{rel}: #{&1}")

      %{
        id: "gates.no_runtime_seam",
        remediation:
          "keep the LLM gate on the gatekeeper — `Workflow.Gates` reads no app-env and applies " <>
            "no injected module; a judgement belongs to a role, never to system machinery",
        status: if(gates_seams == [], do: :pass, else: :fail),
        evidence: gates_seams,
        note: "Gates purity: no runtime seam (app-env read / apply) inside system machinery"
      }
    else
      broken_result("gates.no_runtime_seam", rel)
    end
  end

  # Recognise Application calls, apply and dynamic targets; no alias resolution or effect analysis.
  defp runtime_seam({{:., _, [{:__aliases__, _, [:Application]}, f]}, _, _}),
    do: "Application.#{f}"

  defp runtime_seam({{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, args}),
    do: "apply/#{length(args)}"

  defp runtime_seam({:apply, _, args}) when is_list(args), do: "apply/#{length(args)}"

  defp runtime_seam({{:., _, [target]}, _, _}) when not is_atom(target),
    do: "appel d'une fonction injectee"

  # no_parens distinguishes field-access syntax from a dynamic call.
  defp runtime_seam({{:., _, [target, f]}, meta, _}) when is_atom(f) do
    cond do
      meta[:no_parens] == true -> nil
      match?({:__aliases__, _, _}, target) -> nil
      is_atom(target) -> nil
      true -> "dispatch dynamique .#{f}()"
    end
  end

  defp runtime_seam(_), do: nil

  # Reject two spellings of the obsolete spec.lifetime_scope path;
  # the schema places it under spec.invocation.lifetime_scope.
  @doc false
  @spec check_capprofile_lifetime_scope_path(String.t()) :: Support.result()
  def check_capprofile_lifetime_scope_path(root) do
    residue_check(root, %{
      id: "capprofile.lifetime_scope_path",
      remediation:
        "read spec.invocation.lifetime_scope, not spec.lifetime_scope, in compose_claude_md",
      files: ["lib/fleet/sp_builder.ex"],
      pattern: ~r/cap_profile\.spec,\s*(\["lifetime_scope"\]|"lifetime_scope")/,
      note:
        "compose_claude_md reads spec.lifetime_scope instead of spec.invocation.lifetime_scope"
    })
  end

  # Reject the obsolete modop_incompatible key in the profile and invariants sources.
  @doc false
  @spec check_capprofile_modop_incompatible_path(String.t()) :: Support.result()
  def check_capprofile_modop_incompatible_path(root) do
    residue_check(root, %{
      id: "capprofile.modop_incompatible_path",
      remediation:
        "keep the modop-incompatibility guard (check_modop_incompatible) in cap_profile.ex / invariants.ex",
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

  # Guard removal of the old bare remote-control backend, not all host launches.
  # containment:none uses host_launch.sh; runtime config is scanned raw, including comments.
  @doc false
  @spec check_launch_backend_containment(String.t()) :: Support.result()
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

  # Require both the pod's MCP-provision call spelling and the provisioner's error-tuple line.
  # This couples the two files without proving that the call reaches the refusal branch.
  @doc false
  @spec check_mcp_required_real_backend(String.t()) :: Support.result()
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
        # Match the error atom and tuple prefix on the same stripped line.
        {code_match?(root, mcp, ~r/:mcp_server_spec_required/, [
           ~r/:mcp_server_spec_required/,
           ~r/^\s*\{:error,/
         ]), "#{mcp}: no fail-loud :mcp_server_spec_required (real guard missing)"}
      ]
    )
  end

  # Require the three refusal tuple shapes and lifetime/interlocutor fetch spellings.
  # Brief, lifetime and protocol selection are separate spawn prerequisites.
  @doc false
  @spec check_spawn_has_brief(String.t()) :: Support.result()
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

  @doc """
  Requires a recognised in-flight clearing form in each file setting awaits-arch.
  Leaving the lock can let reconciliation reclaim and redispatch a blocked ticket.

  Setters match label-addition calls; clearing matches removal calls or any unlock(
  spelling in the same file. The scan does not pair execution paths, resolve unlock
  targets or distinguish live helpers from unused ones. Compiler warnings can catch
  unused private helpers, but do not establish this path pairing.

  Both source and writer populations must be nonempty.
  """
  @spec check_awaits_arch_clears_in_flight(Path.t()) :: map()
  def check_awaits_arch_clears_in_flight(root) do
    sources = Path.wildcard(Path.join(root, "lib/**/*.ex"))

    writers = Enum.filter(sources, &sets_awaits_arch?/1)

    setters =
      writers
      |> Enum.reject(&clears_in_flight?/1)
      |> Enum.map(&Path.relative_to(&1, root))

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

  # Bind the label to add_label arguments, not arbitrary file-level co-occurrence.
  # The regex allows one nested-parenthesis level and a bounded span across lines.
  @label_arg_span "(?:[^()]|\\([^()]*\\)){0,200}?"

  defp sets_awaits_arch?(path),
    do: calls_with_label?(path, "add_label", "@awaits_arch_label|Labels\\.awaits_arch\\(\\)")

  defp clears_in_flight?(path) do
    # StepRunCompleter.unlock also clears the lock; this pattern accepts any unlock name.
    calls_with_label?(path, "remove_label", "@in_flight_label|Labels\\.in_flight\\(\\)") or
      match_source?(path, ~r/\bunlock\(/)
  end

  defp calls_with_label?(path, fun, label_alt) do
    match_source?(path, Regex.compile!("#{fun}\\(#{@label_arg_span}(#{label_alt})", "s"))
  end

  # Remove comments through code_of before checking label-call patterns.
  defp match_source?(path, re) do
    case File.read(path) do
      {:ok, src} -> Regex.match?(re, code_of(src))
      _ -> false
    end
  end

  # Route Cowboy child construction through Listener.cowboy_child for the default bind address.
  # This line scan can match strings/docs; checker output must avoid the literal tuple prefix.
  @doc false
  @spec check_no_cowboy_bypass(String.t()) :: Support.result()
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

  # gen_statem cancels a state_timeout on state change.
  # Require deadline/timeout tokens on one line and an extracting transition somewhere in pod.ex.
  # These patterns do not prove arming conditions, source state or transition reachability.
  # The obsolete forever timeout shortcut is searched in raw text, including comments.
  @doc false
  @spec check_result_deadline_cancelled(String.t()) :: Support.result()
  def check_result_deadline_cancelled(root) do
    pod = "lib/fleet/spawner/pod.ex"
    src = File.read!(Path.join(root, pod))

    state_timeout? =
      Path.join(root, pod)
      |> grep_lines(~r/:state_timeout.*:result_deadline|:result_deadline.*:state_timeout/)
      |> Enum.any?(fn {_l, line} ->
        stripped = strip_comment(line)

        Regex.match?(~r/:state_timeout/, stripped) and
          Regex.match?(~r/:result_deadline/, stripped)
      end)

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

  # Check containment validation and both halves of the LaunchEnv/credentials delegation.
  @doc false
  @spec check_spawn_gates_wired(String.t()) :: Support.result()
  def check_spawn_gates_wired(root) do
    pod = "lib/fleet/spawner/pod.ex"

    launch_env = "lib/fleet/spawner/pod/launch_env.ex"

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

  # Gatekeeper is an exception judge, not a workflow ordering step.
  # This scan recognises unquoted role: gatekeeper text; it does not decode YAML.
  @doc false
  @spec check_gatekeeper_not_a_step(String.t()) :: Support.result()
  def check_gatekeeper_not_a_step(root) do
    dir = "priv/catalogue/workflow/workflow_maps"
    abs = Path.join(root, dir)

    yaml_files = (File.dir?(abs) && Path.wildcard(Path.join(abs, "*.yaml"))) || []

    gatekeeper_steps =
      yaml_files
      |> Enum.flat_map(fn path ->
        rel = Path.relative_to(path, root)

        # The word boundary excludes target_role, a legitimate escalation target.
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

  # Worker status/result envelopes must be unwrapped before gate decisions.
  @doc false
  @spec check_verdict_envelope_unwrapped(String.t()) :: Support.result()
  def check_verdict_envelope_unwrapped(root) do
    step_run = "lib/fleet/pilot/step_run_consumer.ex"
    abs = Path.join(root, step_run)

    # Require the consumer file and unwrap-name text; this does not prove an invocation.
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

  # Two halves, and one alone is a hollow green: the guard must CARRY its refusal (Fleet.BootGuard)
  # and the boot must CALL it (config/runtime.exs). A module nobody wires leaves the machine open,
  # and a call to a guard that refuses nothing is decoration. The check reads markers surviving
  # comment stripping; it inspects neither the condition nor the refusal at boot.
  @doc false
  @spec check_no_root_runtime_guard(String.t()) :: Support.result()
  def check_no_root_runtime_guard(root) do
    carries? =
      Support.code_match?(root, "lib/fleet/boot_guard.ex", ~r/R-no-root-runtime/, ~r/root/)

    wired? = Support.code_match?(root, "config/runtime.exs", ~r/BootGuard\.verify/, nil)

    Support.measured_verdict("runtime.no_root_boot_guard", %{
      remediation:
        "R-no-root-runtime: keep the refusal in lib/fleet/boot_guard.ex AND the call " <>
          "`Fleet.BootGuard.verify()` in config/runtime.exs — both, or the guard is decoration",
      findings:
        if(carries?, do: [], else: ["lib/fleet/boot_guard.ex : no anti-root refusal (FORGE-D1)"]) ++
          if(wired?,
            do: [],
            else: [
              "config/runtime.exs : the boot does not call Fleet.BootGuard.verify (FORGE-D1)"
            ]
          ),
      note:
        "the daemon must refuse getuid()==0 at boot (boot guard) — a dev/manual run as root resolves ~/.gitea_token to /root's admin token (FORGE-D1)"
    })
  end

  @doc false
  # Compare the declaration schema maximum with the source @max_max_fan literal.
  @spec check_declaration_max_fan_ceiling(String.t()) :: Support.result()
  def check_declaration_max_fan_ceiling(root) do
    path = Path.join([root, "priv", "cap_profile", "schema", "declaration.json"])
    src = Path.join([root, "lib", "fleet", "pilot", "poller", "admission.ex"])

    # Read the source literal without widening Admission's Boundary exports.
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
      id: "declaration.max_fan_ceiling",
      remediation:
        "make properties.max_fan.maximum in declaration.json equal " <>
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

  # The verifier must contain every recognised validate_*! name found in the boot function.
  # Compare name sets, not order, arguments, modules or execution paths.
  @doc false
  @spec check_verifier_covers_rail(String.t()) :: Support.result()
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
          # Extra verifier guards are allowed; this is inclusion, not equality.
          note:
            "boot: #{MapSet.size(boot)} gardes `validate_*!` · verificateur: " <>
              "#{MapSet.size(verifier)} — le boot est couvert"
        }
    end
  end

  defp validate_calls(ast, fun) do
    ast
    |> collect(fn
      {:def, _, [{^fun, _, _} | _] = body} -> [body]
      {:defp, _, [{^fun, _, _} | _] = body} -> [body]
      _ -> nil
    end)
    |> List.flatten()
    # Include qualified calls; both forms contribute only the function name.
    |> collect(fn
      {name, _, _args} when is_atom(name) ->
        if validate_guard?(name), do: [Atom.to_string(name)], else: nil

      {{:., _, [_module, name]}, _, _args} when is_atom(name) ->
        if validate_guard?(name), do: [Atom.to_string(name)], else: nil

      _ ->
        nil
    end)
    |> List.flatten()
    |> MapSet.new()
  end

  defp validate_guard?(name) do
    s = Atom.to_string(name)
    String.starts_with?(s, "validate_") and String.ends_with?(s, "!")
  end

  @doc """
  Checks names used by recognised eval calls in immediate bin/ and etc/ files
  against def or defdelegate spellings in lib/ source. At least three doors must
  be found. This catches functions moved away from names still used by shell.

  Only the function name is checked, not arity. Column-zero defmodule declarations
  index the whole file, so another module's function or a doc example can satisfy
  the export regex. This does not prove an actual module export or shell-call
  reachability.
  """
  @spec check_eval_doors_resolve(String.t()) :: Support.result()
  def check_eval_doors_resolve(root) do
    id = "runtime.eval_doors_resolve"

    modules = source_by_module(root)
    portes = eval_calls_in_scripts(root)

    # Do not filter out missing modules while constructing findings.
    absents =
      portes
      |> Enum.reject(fn {_rel, mod, fun} -> exporte?(modules, mod, fun) end)
      |> Enum.map(&porte_absente(modules, &1))

    broken = if length(portes) < 3, do: "only #{length(portes)} eval door(s) found (expected 3+)"

    measured_verdict(id, %{
      remediation:
        "re-exporte la fonction depuis le module que le script nomme (`defdelegate`), ou change " <>
          "le script : une porte `eval` est un appel qui traverse une frontiere de langage, et " <>
          "aucune etape du gate ne lit cette chaine a part ce mur",
      broken: broken,
      findings: Enum.sort(absents),
      note:
        "#{length(portes)} porte(s) `eval` nommee(s) par les scripts, " <>
          if(absents == [],
            do: "chacune resolue",
            else: "#{length(absents)} NON resolue(s)"
          )
    })
  end

  defp exporte?(modules, mod, fun) do
    src = Map.get(modules, mod)
    is_binary(src) and Regex.match?(~r/^\s*(def|defdelegate)\s+#{Regex.escape(fun)}\b/m, src)
  end

  defp porte_absente(modules, {rel, mod, fun}) do
    cause =
      if Map.has_key?(modules, mod), do: "le module ne l'exporte pas", else: "module introuvable"

    "#{rel}: #{mod}.#{fun} — #{cause}"
  end

  # Each column-zero module name maps to the entire file, not an isolated module body.
  defp source_by_module(root) do
    root
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn f ->
      src = File.read!(f)

      ~r/^defmodule\s+([A-Za-z0-9_.]+)\s+do/m
      |> Regex.scan(src)
      |> Enum.map(fn [_, nom] -> {nom, src} end)
    end)
    |> Map.new()
  end

  defp eval_calls_in_scripts(root) do
    ["bin/*", "etc/*"]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.filter(&File.regular?/1)
    |> Enum.flat_map(fn f ->
      ~r/eval\s+"([A-Za-z0-9_.]+)\.([a-z_][A-Za-z0-9_?!]*)\(/
      |> Regex.scan(File.read!(f))
      |> Enum.map(fn [_, mod, fun] -> {Path.relative_to(f, root), mod, fun} end)
    end)
    |> Enum.uniq()
  end

  @doc """
  Checks stdout writers for a Fleet.ReleaseDoor.claim_stdout! call, which redirects
  the default Logger handler away from payloads consumed as JSON or shell fields.

  Recognised writes are IO.puts/1 calls and captures, excluding two-argument writes
  and Mix.shell output. Eval-prefixed public definitions are scanned individually;
  a file containing use Mix.Task is scanned as a whole, including private helpers.

  The AST scan checks co-occurrence, not call order or reachability. A claim in an
  unrelated branch can satisfy it; writes through other functions may be missed.
  Minimum door, writer and Mix-task populations guard against a blind scan.
  """
  @spec check_eval_doors_claim_stdout(String.t()) :: Support.result()
  def check_eval_doors_claim_stdout(root) do
    id = "runtime.eval_doors_claim_stdout"

    doors =
      Path.wildcard(Path.join(root, "lib/**/*.ex"))
      |> Enum.flat_map(&eval_doors_in/1)

    writers = Enum.filter(doors, fn {_f, _n, out, _c} -> out end)
    naked = for {f, n, _, claim} <- writers, not claim, do: "#{Path.relative_to(f, root)}: #{n}"

    tasks = Enum.filter(doors, fn {_f, n, _, _} -> n == :"<the whole task>" end)

    broken =
      cond do
        length(doors) < 15 ->
          "lib/**/*.ex: only #{length(doors)} door(s) found (expected 15+)"

        writers == [] ->
          "lib/**/*.ex: no door writes to stdout — the scan matched no IO.puts/1"

        # Require a Mix-task population separately from eval functions.
        length(tasks) < 6 ->
          "lib/**/*.ex: only #{length(tasks)} Mix task(s) matched (expected 6+)"

        true ->
          nil
      end

    measured_verdict(id, %{
      remediation:
        "call `Fleet.ReleaseDoor.claim_stdout!/0` at the top of the door, before anything that " <>
          "can log: the default Logger handler writes to stdout, and a door's stdout is a " <>
          "CONTRACT read by a shell — a log line there becomes part of a URL or breaks a JSON",
      broken: broken,
      findings: Enum.sort(naked),
      note:
        "#{length(doors)} door(s) (`eval*` + Mix task `run/1`), #{length(writers)} writing to " <>
          "stdout, " <>
          if(naked == [], do: "all claiming it", else: "#{length(naked)} NOT claiming it")
    })
  end

  # Eval functions are scanned by body; any use Mix.Task makes the whole file a door.
  # This includes private output helpers, but also unrelated modules in the same file.
  defp eval_doors_in(path) do
    ast = quoted!(Path.dirname(path), Path.basename(path))

    if mix_task?(ast) do
      [{path, :"<the whole task>", ast_writes_stdout?(ast), ast_claims_stdout?(ast)}]
    else
      eval_doors_by_function(path, ast)
    end
  end

  # A Mix.Tasks namespace alone includes non-task support modules; use Mix.Task is the marker.
  defp mix_task?(ast) do
    ast_any?(ast, fn
      {:use, _, [{:__aliases__, _, [:Mix, :Task]} | _]} -> true
      _ -> false
    end)
  end

  defp eval_doors_by_function(path, ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:def, _, [head | _] = args} = n, acc ->
          case def_name(head) do
            nil -> {n, acc}
            name -> {n, [{path, name, ast_writes_stdout?(args), ast_claims_stdout?(args)} | acc]}
          end

        n, acc ->
          {n, acc}
      end)

    Enum.filter(found, fn {_, n, _, _} -> String.starts_with?(to_string(n), "eval") end)
  end

  defp ast_any?(ast, pred) do
    {_, hits} = Macro.prewalk(ast, [], fn n, a -> if pred.(n), do: {n, [1 | a]}, else: {n, a} end)
    hits != []
  end

  defp ast_writes_stdout?(ast) do
    ast_any?(ast, fn
      {{:., _, [{:__aliases__, _, [:IO]}, :puts]}, _, [_one]} -> true
      {:/, _, [{{:., _, [{:__aliases__, _, [:IO]}, :puts]}, _, []}, 1]} -> true
      _ -> false
    end)
  end

  defp ast_claims_stdout?(ast) do
    ast_any?(ast, fn
      {{:., _, [{:__aliases__, _, [:Fleet, :ReleaseDoor]}, :claim_stdout!]}, _, _} -> true
      _ -> false
    end)
  end

  # Release eval does not start the application, so forge calls need their Finch transport.
  # This check only requires finch_spec text in files naming eval_ definitions and Fleet.Forge;
  # comments/strings can satisfy it and it does not verify pool startup.
  @doc false
  @spec check_eval_doors_start_transport(String.t()) :: Support.result()
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
        if(files == [],
          do: ["INSTRUMENT BROKEN — no file defines an `eval` door AND names Fleet.Forge"],
          else: Enum.sort(missing)
        ),
      note: "#{length(files)} forge-reaching `eval` door file(s), each starting its own transport"
    }
  end

  # A short module name used as a value can compile as an atom without resolving.
  # Check single-segment aliases outside use Boundary, whose names can be boundary-relative.
  # Aliases and local modules are collected across each file without lexical scope or target validation.
  @doc false
  @spec check_bare_alias_resolves(String.t()) :: Support.result()
  def check_bare_alias_resolves(root) do
    fichiers = root |> Path.join("lib/**/*.ex") |> Path.wildcard()

    {examines, trous} =
      Enum.reduce(fichiers, {0, []}, fn f, {n, acc} ->
        ast = f |> File.read!() |> Code.string_to_quoted!()
        alias_ = aliases_of(ast)
        locaux = MapSet.new(defmodules_of(ast))

        manquants =
          ast
          |> bare_refs()
          |> Enum.reject(fn {seg, _l} ->
            Map.has_key?(alias_, seg) or Module.concat([seg]) in locaux or
              Support.module_exists?(Atom.to_string(seg))
          end)
          |> Enum.map(fn {seg, l} -> "#{Path.relative_to(f, root)}:#{l}: #{seg}" end)

        {n + length(bare_refs(ast)), manquants ++ acc}
      end)

    cond do
      length(fichiers) < 100 ->
        Support.broken_result("code.bare_alias_resolves", "source file under lib/")

      examines < 200 ->
        Support.broken_result("code.bare_alias_resolves", "single-segment module reference")

      true ->
        %{
          id: "code.bare_alias_resolves",
          remediation:
            "alias the module, or write it in full — a single-segment name Elixir cannot resolve " <>
              "is a valid atom, so it compiles, passes every wall, and dies at runtime the first " <>
              "time something dispatches on it",
          status: if(trous == [], do: :pass, else: :fail),
          evidence: Enum.sort(trous),
          note: "#{examines} single-segment references over #{length(fichiers)} files"
        }
    end
  end

  defp aliases_of(ast) do
    {_, m} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, segs}]} = n, acc ->
          {n, Map.put(acc, List.last(segs), true)}

        {:alias, _, [{:__aliases__, _, segs}, opts]} = n, acc when is_list(opts) ->
          court =
            case opts[:as] do
              {:__aliases__, _, s} -> List.last(s)
              _ -> List.last(segs)
            end

          {n, Map.put(acc, court, true)}

        {:alias, _, [{{:., _, [{:__aliases__, _, _}, :{}]}, _, enfants}]} = n, acc ->
          {n,
           Enum.reduce(enfants, acc, fn {:__aliases__, _, s}, a ->
             Map.put(a, List.last(s), true)
           end)}

        n, acc ->
          {n, acc}
      end)

    m
  end

  defp defmodules_of(ast) do
    {_, l} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, segs} | _]} = n, acc ->
          {n, [Module.concat(segs) | acc]}

        n, acc ->
          {n, acc}
      end)

    l
  end

  defp bare_refs(ast) do
    {_, l} =
      Macro.prewalk(ast, [], fn
        {:use, _, [{:__aliases__, _, [:Boundary]} | _]}, acc -> {nil, acc}
        {:__aliases__, meta, [seg]} = n, acc when is_atom(seg) -> {n, [{seg, meta[:line]} | acc]}
        n, acc -> {n, acc}
      end)

    l
  end

  # Unary Loader calls/captures discard catalogue opts and can select a foreign same-name card.
  # Inspect the three alias spellings below after expanding pipes, without resolving aliases.
  # Renamed aliases, dynamic targets and apply are outside coverage; opts content is not checked.
  @doc false
  @spec check_workflow_loader_arity(String.t()) :: Support.result()
  def check_workflow_loader_arity(root) do
    id = "workflow.loader_arity"
    own = "lib/fleet/workflow/loader.ex"

    # A missing loader invalidates the exemption and raises a loader_moved throw.
    if not File.regular?(Path.join(root, own)),
      do: throw({:loader_moved, own})

    files =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.reject(&(&1 == own))
      |> Enum.sort()

    {binary, unary} =
      Enum.reduce(files, {0, []}, fn rel, {n_bin, bad} ->
        {b, u} = loader_call_sites(quoted!(root, rel))
        {n_bin + b, bad ++ Enum.map(u, fn {line, form} -> "#{rel}:#{line} — #{form}" end)}
      end)

    # Require five recognised binary calls; include unary findings if that floor fails.
    if binary < 5 do
      broken_result(
        id,
        "Loader.load!/2 call sites (only #{binary}, expected 5+)" <>
          if(unary == [], do: "", else: "; unary seen: #{Enum.join(unary, " · ")}")
      )
    else
      %{
        id: id,
        remediation:
          "pass the catalogue: `Loader.load!(name, Loader.card_opts_for_repo(repo))` (or the " <>
            "`loader_opts` already in scope), and hand `&Loader.load!/2` to `safe_load/3`",
        status: if(unary == [], do: :pass, else: :fail),
        evidence: unary,
        note: "#{binary} binary site(s) across lib/; #{length(unary)} unary"
      }
    end
  end

  @loader_aliases [[:Loader], [:Workflow, :Loader], [:Fleet, :Workflow, :Loader]]

  defp loader_call_sites(ast) do
    {_, acc} =
      ast
      |> unpipe()
      |> Macro.prewalk({0, []}, fn
        {:&, meta, [{:/, _, [{{:., _, [{:__aliases__, _, parts}, :load!]}, _, []}, 1]}]} = node,
        {b, u} ->
          if parts in @loader_aliases,
            do: {node, {b, u ++ [{meta[:line], "&Loader.load!/1"}]}},
            else: {node, {b, u}}

        {{:., _, [{:__aliases__, _, parts}, :load!]}, meta, args} = node, {b, u}
        when is_list(args) ->
          cond do
            parts not in @loader_aliases -> {node, {b, u}}
            length(args) == 1 -> {node, {b, u ++ [{meta[:line], "Loader.load!(_)"}]}}
            length(args) == 2 -> {node, {b + 1, u}}
            true -> {node, {b, u}}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end
end
