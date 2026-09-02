defmodule Mix.Tasks.Lcars.Contracts.Check.Runtime do
  # Z4 — classe dans la boundary de son sujet, comme la tache qui l'utilise.
  use Boundary, classify_to: Fleet.Application

  @moduledoc """
  Les rails du runtime : les invariants qu'aucun type ne peut porter et qu'aucun test ne traverse.

  Chacun de ces murs garde une COUTURE — un endroit ou deux morceaux de code doivent s'accorder sans
  qu'aucun appel ne les relie. Une porte cablee d'un cote et pas de l'autre, une enveloppe de verdict
  qu'un consommateur ne deballe plus, un drapeau pose et jamais efface, un backend de lancement qui
  s'echappe de son conteneur. Rien de tout cela ne casse a la compilation, et la plupart ne cassent
  pas non plus a l'execution : ils DERIVENT.

  ⚠ LA FORME COMMUNE EST L'ABSENCE, ET L'ABSENCE EST MUETTE. « Ce marqueur doit exister », « ce
  residu ne doit plus exister » : les deux se lisent sur le CODE, jamais sur la prose — un marqueur
  cite dans un commentaire ne compte pas, sinon le mur serait satisfait par sa propre documentation.
  C'est ce que `Support.code_match?/4` garantit, et c'est pourquoi ces murs l'empruntent tous.
  """

  alias Mix.Tasks.Lcars.Contracts.Check.Support

  import Mix.Tasks.Lcars.Contracts.Check.Support

  # Invariant: the LLM gate (soft + terminal non-adjudicable) is judged by the **gatekeeper** on the
  # workflow side. `Workflow.Gates` is SYSTEM machinery and stays PURE — it must not acquire a
  # runtime seam that re-installs a judgement inside it.
  #
  # ⚠ CE QUI EST GREPE EST UNE FORME, PLUS UN NOM. La version precedente cherchait
  # `coord_backend|CoordBackend` : deux chaines qu'aucun commit ne pouvait produire depuis que
  # `Fleet.Coord` est parti entier (brouette 2026-08-19). Un mur contre une resurrection que
  # personne ne peut accomplir se lit comme une garantie et n'en tient aucune — et il verdissait
  # sur n'importe quelle delegation vers un AUTRE destinataire.
  #
  # `boundary` attrape deja toute delegation EN DUR vers un autre domaine, a la compilation. Ce
  # qu'il ne voit pas, c'est le seam passe EN VALEUR (`Application.get_env` puis `apply/3`) — le
  # mecanisme exact de feu `:coord_backend`. C'est donc lui qu'on refuse ici, et les deux couches
  # se composent sans se recouvrir.
  #
  # Ne pond aucun faux positif aujourd'hui : `gates.ex` n'a ni lecture d'app-env ni `apply/3`
  # (mesure a la pose, 2026-08-20) — le mur nait VERT, seul etat dans lequel un mur puisse naitre.
  #
  # ## Preuve (mutation jouee a la pose, 2026-08-20)
  # Insere `defp _mutation_seam, do: Application.get_env(:lcars_fleet, :gate_backend)` dans
  # `gates.ex` : ce check ECHOUE et nomme `lib/fleet/workflow/gates.ex:43`. Mutation retiree.
  # Quatre contournements de la version grep, rejoues et ROUGES depuis la lecture AST :
  # `Application.get_all_env(…)`, `@x Application.compile_env(…)` en corps de module,
  # `seam.eval?(1, 2)` (dispatch sur une cible non statique) et `inj.(1)` (fonction injectee).
  # Son angle mort, declare : la granularite est le FICHIER `gates.ex`. Un seam installe dans
  # `gates/predicate.ex` passerait — `boundary` le verrait s'il traverse un domaine, pas s'il reste
  # dans `Fleet.Workflow`. Les deux couches se composent et aucune ne couvre l'autre.
  @doc false
  @spec check_gates_no_runtime_seam(String.t()) :: Support.result()
  def check_gates_no_runtime_seam(root) do
    rel = "lib/fleet/workflow/gates.ex"
    gates_path = Path.join(root, rel)

    if not File.exists?(gates_path) do
      broken_result("gates.no_runtime_seam", rel)
    else
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
    end
  end

  # UN SEAM D'EXECUTION, LU SUR L'AST ET NON SUR LE TEXTE. La version grep ne nommait que
  # `Application.get_env`/`fetch_env` et `apply(` — trois contournements passaient au vert en
  # faisant exactement la meme chose : `Application.get_all_env`, `Application.compile_env`, et le
  # dispatch par cible non statique (`mod().f()`, `fun.()`), qui est la forme la plus pure de
  # l'injection de module qu'on refuse ici.
  defp runtime_seam({{:., _, [{:__aliases__, _, [:Application]}, f]}, _, _}),
    do: "Application.#{f}"

  defp runtime_seam({{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, args}),
    do: "apply/#{length(args)}"

  defp runtime_seam({:apply, _, args}) when is_list(args), do: "apply/#{length(args)}"

  # `fun.(…)` — une fonction injectee est un seam sans nom de module.
  defp runtime_seam({{:., _, [target]}, _, _}) when not is_atom(target),
    do: "appel d'une fonction injectee"

  # `expr.f(…)` dont la cible n'est ni un alias ni un atome. `meta[:no_parens]` distingue l'ACCES
  # (`state.field`, qui n'est pas un dispatch) de l'APPEL (`mod().f()`, qui en est un).
  defp runtime_seam({{:., _, [target, f]}, meta, _}) when is_atom(f) do
    cond do
      meta[:no_parens] == true -> nil
      match?({:__aliases__, _, _}, target) -> nil
      is_atom(target) -> nil
      true -> "dispatch dynamique .#{f}()"
    end
  end

  defp runtime_seam(_), do: nil

  # `compose_claude_md/3` must read `spec.invocation.lifetime_scope` (the canonical
  # v2.5 schema), not `spec.lifetime_scope` (pre-v2.5 form) — otherwise the pod's CLAUDE.md
  # always shows "unknown". The twin `check_lifetime_scope/1` (cap_profile.ex)
  # already reads the right path.
  # The pattern covers get_in (list form `spec, ["lifetime_scope"]`) AND Map.get
  # (string form `spec, "lifetime_scope"`) — future-proof against a regression that
  # would reintroduce the wrong path under another form.
  @doc false
  @spec check_capprofile_lifetime_scope_path(String.t()) :: Support.result()
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
  @spec check_capprofile_modop_incompatible_path(String.t()) :: Support.result()
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

  # Every HTTP listener child-spec `{Plug.Cowboy, …}` must be built by the SINGLE authority
  # `Fleet.EventRouter.Listener.cowboy_child/1` — that is where the loopback `:ip` bind is set BY
  # CONSTRUCTION (via BindAddress). A surface that builds its own `{Plug.Cowboy, …}` elsewhere would
  # bypass the loopback-by-default guarantee (network exposure by accident). Red if a `{Plug.Cowboy,`
  # child-spec appears on a code line outside listener.ex. NB the pattern matches the child-spec tuple
  # `{Plug.Cowboy,` (comma), NOT `Plug.Cowboy.Handler` (a dispatch clause) nor comments (strip_comment).
  # ⚠ This checker file is scanned too: its own evidence/note prose must AVOID the literal `{Plug.Cowboy,`
  # token (it would self-flag — strip_comment removes it from comments, not from string bodies).
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
  @spec check_result_deadline_cancelled(String.t()) :: Support.result()
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
  @spec check_spawn_gates_wired(String.t()) :: Support.result()
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
  @spec check_gatekeeper_not_a_step(String.t()) :: Support.result()
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
  @spec check_verdict_envelope_unwrapped(String.t()) :: Support.result()
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
  @spec check_no_root_runtime_guard(String.t()) :: Support.result()
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

  @doc false
  # ONE FACT, TWO RENDERS — the hard ceiling on a project's in-flight workflow_runs. It is typed in
  # Elixir (`Admission.max_fan_ceiling/0`, itself derived from the pool seats a role actually has)
  # and AGAIN in `declaration-v1.json`, because a JSON Schema cannot call a function. The declaration
  # a human writes is validated by the schema; the value the dispatcher enforces comes from the
  # module. Let those two drift and a project declares a throughput the schema accepts and the
  # engine silently clamps away — a declaration that validates and does not apply, which is the
  # worst of the three possible outcomes.
  @spec check_declaration_max_fan_ceiling(String.t()) :: Support.result()
  def check_declaration_max_fan_ceiling(root) do
    path = Path.join([root, "priv", "cap_profile", "schema", "declaration-v1.json"])
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
      id: "declaration.max_fan_ceiling",
      remediation:
        "make properties.max_fan.maximum in declaration-v1.json equal " <>
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

  # LE VERIFICATEUR AUTONOME AFFIRMAIT COUVRIR LE BOOT, ET L'EQUIVALENCE N'ETAIT TENUE PAR RIEN
  # (6-008). `CatalogueVerify` imprime « catalogue OK — every check the boot runs passed. » et
  # `Pilot.Application.verify_cards_and_roles!/1` documente « Runs EXACTLY what start_link/1 runs at
  # rail boot ». Mesure du 2026-08-14 : le boot en jouait SIX, le verificateur QUATRE —
  # `validate_workshop_card!` et `validate_default_card_loads!` (alors `validate_default_card_matrix!`)
  # manquaient. Un verificateur VERT
  # pouvait preceder un boot ROUGE, ce qui est le contraire de son objet.
  #
  # Les deux sequences sont lues A L'AST, pas au grep : une garde citee dans un commentaire ne doit
  # pas pouvoir verdir ce mur, et une garde ajoutee au boot ne doit pas pouvoir s'y cacher. On
  # compare les APPELS de `validate_*!` dans les deux corps de fonction.
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

  @doc """
  Une porte `eval*` qui ECRIT sur stdout doit d'abord le RECLAMER.

  ## Ce que ca a coute, mesure

  Une porte `eval` a un flux de sortie CONTRACTUEL : `catalogue-source` rend `<depot> <branche>
  <sha>` que l'appelant donne a `git clone` ; `roles-tfvars` rend du JSON redirige dans un fichier
  que tofu lit et repasse dans `jq`. Le handler Logger par defaut ecrit, lui aussi, sur stdout.
  `Fleet.ReleaseDoor.claim_stdout!/0` le renvoie vers stderr, et c'est le seul geste qui separe les
  deux flux.

  Le 2026-08-23, sur un poste : `lcars catalogue install web-demo` a rendu

      forge-gestures: web-demo <-  (@)
      fatal: repository 'http://127.0.0.1:21000/.git/' not found

  La porte avait imprime une ligne vide, puis un `Logger.info`, puis sa reponse. `read -r repo
  branch sha` a lu la premiere ligne. L'URL a ete construite sur du vide et git s'est fait accuser.

  Le `@doc` de cette porte ENONCAIT la regle depuis toujours — « and nothing else: the caller feeds
  it to `git clone`, so a line of politeness would become part of a URL » — et rien ne la tenait.
  Le defaut a dormi tant qu'aucun log ne sortait sur ce chemin ; il s'est reveille quand la fleet a
  commence a publier son catalogue de reference, dont l'ecartement est DIT.

  ## Pourquoi un mur et pas une relecture

  Quatre portes sur sept le faisaient, trois ne le faisaient pas — dont deux que personne n'avait
  regardees (`Fleet.Roster.eval_main/1` et `eval_tfvars/1`, toutes deux sur le meme rail, une
  etape plus loin). Une regle tenue par quatre sites sur sept est une regle que le huitieme rate.

  Derive de l'AST, donc rien a maintenir : une porte ajoutee demain est mesuree par construction.

  ## Ce qu'il mesure exactement

  Une fonction dont le nom commence par `eval` et dont le corps porte `IO.puts/1` (un seul
  argument — `IO.puts(:stderr, x)` en a deux et ne compte pas) ou la capture `&IO.puts/1`, sans
  appel a `Fleet.ReleaseDoor.claim_stdout!/0` dans le meme corps.
  """
  @spec check_eval_doors_claim_stdout(String.t()) :: Support.result()
  def check_eval_doors_claim_stdout(root) do
    id = "runtime.eval_doors_claim_stdout"

    doors =
      Path.wildcard(Path.join(root, "lib/**/*.ex"))
      |> Enum.flat_map(&eval_doors_in/1)

    writers = Enum.filter(doors, fn {_f, _n, out, _c} -> out end)
    naked = for {f, n, _, claim} <- writers, not claim, do: "#{Path.relative_to(f, root)}: #{n}"

    # INSTRUMENT GUARD. Chaque finding est une ABSENCE, et un parseur casse en produit autant. La
    # premiere ecriture de cette sonde ratait la forme `def f(x) when g` — la tete est enveloppee
    # dans un `:when`, donc aucun corps n'etait scanne — et elle rendait un vert parfait sur un
    # arbre qui portait TROIS portes nues. Le plancher est pose sous l'etat du jour, pas dessus.
    broken =
      cond do
        length(doors) < 6 -> "only #{length(doors)} `eval*` function(s) found (expected 6+)"
        writers == [] -> "no `eval*` function writes to stdout — the scan matched no IO.puts/1"
        true -> nil
      end

    %{
      id: id,
      remediation:
        "call `Fleet.ReleaseDoor.claim_stdout!/0` at the top of the door, before anything that " <>
          "can log: the default Logger handler writes to stdout, and a door's stdout is a " <>
          "CONTRACT read by a shell — a log line there becomes part of a URL or breaks a JSON",
      status: if(is_nil(broken) and naked == [], do: :pass, else: :fail),
      evidence:
        cond do
          broken -> ["lib/**/*.ex: INSTRUMENT BROKEN — #{broken}; this check measured nothing"]
          naked != [] -> Enum.sort(naked)
          true -> []
        end,
      # ⚠ LA NOTE DECRIT L'ETAT, PAS L'ESPOIR. Elle disait « all claiming it » sans condition, donc
      # elle affirmait la conformite dans le rapport meme d'un echec.
      note:
        "#{length(doors)} `eval*` door(s), #{length(writers)} writing to stdout, " <>
          if(naked == [], do: "all claiming it", else: "#{length(naked)} NOT claiming it")
    }
  end

  # ⚠ `def_name/1` (plus bas) DEPLIE le `:when` : la tete d'un `def f(x) when g` y est enveloppee,
  # et sans ce depliage aucun corps n'est atteint. Ma premiere ecriture en avait un doublon local —
  # le meme code, deux maisons, exactement ce que ce fichier refuse partout ailleurs.
  defp eval_doors_in(path) do
    {_, found} =
      quoted!(Path.dirname(path), Path.basename(path))
      |> Macro.prewalk([], fn
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
        cond do
          files == [] ->
            ["INSTRUMENT BROKEN — no file defines an `eval` door AND names Fleet.Forge"]

          true ->
            Enum.sort(missing)
        end,
      note: "#{length(files)} forge-reaching `eval` door file(s), each starting its own transport"
    }
  end
end
