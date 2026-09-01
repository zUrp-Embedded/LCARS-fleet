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

  alias Mix.Tasks.Lcars.Contracts.Check.Catalogue
  alias Mix.Tasks.Lcars.Contracts.Check.SingleSource
  alias Mix.Tasks.Lcars.Contracts.Check.Tests
  alias Mix.Tasks.Lcars.Contracts.Check.Tools
  alias Mix.Tasks.Lcars.Contracts.Check.Support

  # Les combinateurs, les lecteurs de code et le parcours de corpus vivent dans `Support` — importes
  # ici pour que chaque mur s'ecrive en donnees, sans prefixe de module a chaque ligne. Le type du
  # verdict y vit aussi : il decrit ce que les combinateurs RENDENT, il appartient donc a l'outil, et
  # le redefinir ici en ferait deux definitions d'une meme forme.
  import Mix.Tasks.Lcars.Contracts.Check.Support

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
        check_gates_no_runtime_seam(root),
        check_visual_types_derived(root),
        check_escalation_kinds_closed(root),
        check_findings_severities_aligned(root),
        check_pulled_states_declared(root),
        check_public_functions_spec(root),
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
        check_sp_adresser_un_agent(root),
        check_sourcers_set_strict(root),
        check_face_roots_provisioned(root),
        SingleSource.check_toolchain_branch_single_source(root),
        SingleSource.check_catalogue_roots_single_source(root),
        SingleSource.check_private_dir_single_source(root),
        SingleSource.check_system_account_single_source(root),
        SingleSource.check_platform_root_single_source(root),
        SingleSource.check_runtime_root_single_source(root),
        SingleSource.check_face_roots_single_source(root),
        SingleSource.check_ops_repo_single_source(root),
        Tools.check_tool_descriptions_no_permuted_names(root),
        Tools.check_tool_grants_resolve(root),
        Tools.check_catalogue_enumerates_no_tools(root),
        check_eval_doors_claim_stdout(root),
        check_gitea_template_expansion(root),
        check_site_build_inputs(root),
        check_bats_descriptions_inert(root),
        check_awaits_arch_clears_in_flight(root),
        check_sanctuary_contained(root),
        check_no_legacy_config_namespace(root),
        Tools.check_mcp_wire_inputschema(root),
        Tools.check_mcp_tools_gated(root),
        Tools.check_mcp_tool_effects(root),
        Tools.check_cap_profile_project_keys(root),
        Tools.check_modop_tools_granted(root),
        check_proven_image_regime(root),
        check_verifier_covers_rail(root),
        Tools.check_capabilities_exercisable(root),
        check_catalogue_paths_locked(root),
        check_eval_doors_start_transport(root),
        Tools.check_mcp_seam_surface(root),
        Tools.check_forge_fields_read(root),
        Tools.check_forge_mutations_exposed(root),
        check_declaration_max_fan_ceiling(root),
        Tests.check_test_corpora_on_record(root),
        Tests.check_doctest_declarations_have_examples(root),
        Tests.check_test_dirs_mirror_source(root),
        Tests.check_witness_naming(root),
        Tests.check_negations_bite(root),
        Tests.check_refute_copies_agree(root),
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
  @spec check_event_consumers_canon(String.t()) :: Support.result()
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
  @spec check_pipeline_v25_normalized(String.t()) :: Support.result()
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
  @spec check_events_handlers_exist(String.t()) :: Support.result()
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

  # LE JUMEAU DE `docs.public_functions_documented`, sur l'autre contrat.
  #
  # Dialyzer tourne au dernier maillon du gate avec `:extra_return` et `:missing_return` — deux
  # drapeaux dont tout le metier est de comparer le DECLARE a l'INFERE. Ils sont INERTES sur une
  # fonction sans `@spec` : le fichier est analyse, mais avec le contrat le plus permissif que
  # l'inference veuille bien lui accorder. Une fonction sans spec n'est donc pas « moins finie »,
  # elle est HORS DE PORTEE de l'instrument le plus strict du gate, tout en le faisant verdir.
  #
  # ⚖ Arbitrage user, 2026-08-20 : « on ne laisse pas le boulot a 90 %, c'est pas un plafond, c'est
  # le dernier kilometre ». La couverture etait a 89,0 % (64 fonctions sur 16 fichiers) et la fuite
  # S'ELARGISSAIT — chaque check ajoute a ce fichier ajoutait une fonction publique sans spec.
  #
  # `@impl` EXCLU, meme motif que le jumeau : le contrat d'un callback vit dans son behaviour, et le
  # restater par implementation est la duplication que ce depot refuse ailleurs. Les callbacks OTP
  # NOMMES ne sont PAS exclus, eux : `start_link/1` et `child_spec/1` portent un contrat propre a
  # chaque module, et les exclure retirerait du mur ce qu'on vient de fermer.
  #
  # ## Preuve (mesure et mutation, 2026-08-20)
  # Pose a 540/540. Retirer un `@spec` -> ECHEC, fonction et fichier nommes. Et l'exercice s'est
  # auto-verifie pendant qu'on le faisait : QUATRE specs ecrits de bonne foi etaient FAUX, et
  # Dialyzer les a nommes un par un — `paginate/3` (une chaine de requete prise pour un keyword,
  # 75 avertissements en cascade), `forge_bot_login/2` et `login_of/1` (un tuple pris pour une
  # chaine), `maybe_complete/2` (deux formes de retour sur quatre). Aucun n'aurait pu passer en
  # silence : c'est la propriete qui rend ce mur sur a poser.
  @doc false
  @spec check_public_functions_spec(String.t()) :: Support.result()
  def check_public_functions_spec(root) do
    files = Path.wildcard(Path.join([root, "lib", "**", "*.ex"]))

    manquantes =
      Enum.flat_map(files, fn path ->
        case unspecced_public_units(File.read!(path)) do
          [] -> []
          names -> [{Path.relative_to(path, root), names}]
        end
      end)

    %{
      id: "types.public_functions_spec",
      remediation:
        "donne un `@spec` a la fonction — sans lui, Dialyzer l'analyse avec le contrat le plus " <>
          "permissif qu'il puisse inferer, et `:extra_return`/`:missing_return` n'ont rien a " <>
          "comparer. Un `@impl` n'en a pas besoin : son contrat vit dans le behaviour",
      status: if(files != [] and manquantes == [], do: :pass, else: :fail),
      evidence:
        cond do
          files == [] ->
            ["INSTRUMENT BROKEN — aucun fichier source lu sous lib/"]

          manquantes != [] ->
            Enum.map(manquantes, fn {f, ns} -> "#{f}: #{Enum.join(ns, ", ")}" end)

          true ->
            []
        end,
      note: "public functions carrying a @spec (@impl excluded), #{length(files)} files scanned"
    }
  end

  # Les callbacks dont le contrat vit dans leur BEHAVIOUR — meme exclusion que le jumeau
  # `docs.public_functions_documented`, et pour le meme motif : le restater par implementation est
  # la duplication que ce depot refuse ailleurs. Beaucoup ne portent pas `@impl` dans cet arbre, et
  # c'est une AUTRE dette : les exclure par nom ferme le trou du spec sans masquer celui-la.
  # `start_link` et `child_spec` N'Y SONT PAS : leur contrat est propre a chaque module.
  @behaviour_callbacks ~w(init handle_call handle_cast handle_info handle_continue terminate
                          code_change handle_event)a

  # Les unites publiques d'UN fichier qui n'ont pas de `@spec`, par NOM ET ARITE.
  #
  # ⚠ RECRITURE SUR L'AST (2026-08-20), et le motif de la reecriture est le defaut qu'elle repare :
  # la premiere version lisait ligne a ligne avec une machine a phases, et sa bascule de heredoc
  # (`String.starts_with?(trimmed, ~s("""))`) ne basculait PAS sur `@moduledoc """` — cette ligne ne
  # COMMENCE pas par les trois guillemets. Seule la fermeture basculait, donc tout ce qui suivait un
  # moduledoc etait invisible : 547 noms vus sur 1237, 88 fichiers sur 246 amputes de plus de la
  # moitie, et onze fichiers vus a ZERO. Le mur annonçait 100 % sur 92,8 % de reel. Meme classe de
  # bug que celui trouve le matin meme dans l'outil de replay de l'audit — un compteur qui se trompe
  # de phase ne se rapiece pas, il se refait sur la seule structure qui ne ment pas.
  #
  # TROIS choses que la version ligne a ligne ne pouvait pas faire :
  #   * `defdelegate` — la regex `^def\s+` ne le matche pas (pas d'espace) ; 22 delegations
  #     publiques etaient hors de portee, dont `Pilot.onboard` et `IncidentRegistry.escalate` ;
  #   * l'ARITE — les `@spec` etaient indexes par nom seul, donc un `in_flight/1` ajoute a cote d'un
  #     `in_flight/0` spec'e passait au vert ;
  #   * les ARGS PAR DEFAUT — `def f(a, b \\ 1)` definit deux arites et un seul `@spec` les couvre.
  #     Une unite porte donc son intervalle, et un spec dedans suffit.
  defp unspecced_public_units(src) do
    src
    |> Code.string_to_quoted!()
    |> module_bodies()
    |> Enum.flat_map(&scope_gap/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Les corps de module, UN PAR MODULE. Deux corrections mesurees a la pose (2026-08-20) :
  #   * un corps a UN SEUL statement n'est pas un `__block__` — un module d'une fonction etait
  #     entierement invisible ;
  #   * les statements d'un module IMBRIQUE sont aussi des statements du parent. Melanger les deux
  #     faisait fuir les `@spec` et les `@impl` d'un module vers son voisin du meme fichier :
  #     quatre modules dans `conflict/types.ex`, quatre dans `admiral/shutdown.ex`, et le spec de
  #     l'un couvrait la fonction homonyme de l'autre. Chaque module est donc son propre monde.
  defp module_bodies(ast) do
    collect(ast, fn
      {:defmodule, _, [_name, [do: body]]} -> stmts_of(body)
      _ -> nil
    end)
  end

  defp stmts_of({:__block__, _, stmts}) when is_list(stmts), do: stmts
  defp stmts_of(single), do: [single]

  defp scope_gap(stmts) do
    {defs, specs} =
      Enum.reduce(stmts, {{[], MapSet.new()}, false}, fn stmt, {{ds, ss}, impl?} ->
        case stmt do
          # Le module imbrique a son propre monde (`module_bodies/1` le visite a part).
          {:defmodule, _, _} ->
            {{ds, ss}, false}

          {:@, _, [{:impl, _, _}]} ->
            {{ds, ss}, true}

          {:@, _, [{:spec, _, [spec]}]} ->
            {{ds, spec_unit(spec, ss)}, false}

          {kind, _, [head | _]} when kind in [:def, :defdelegate, :defmacro] ->
            {{def_unit(head, ds, impl?), ss}, false}

          _ ->
            {{ds, ss}, false}
        end
      end)
      |> elem(0)

    impls = for {n, lo, hi, true} <- defs, a <- lo..hi, into: MapSet.new(), do: {n, a}

    defs
    |> Enum.reject(fn {name, _lo, _hi, impl?} -> impl? or name in @behaviour_callbacks end)
    |> Enum.reject(fn {name, lo, hi, _} ->
      Enum.any?(lo..hi, fn a ->
        MapSet.member?(specs, {name, a}) or MapSet.member?(impls, {name, a})
      end)
    end)
    |> Enum.map(fn {name, _lo, hi, _} -> "#{name}/#{hi}" end)
  end

  # `{nom, arite_min, arite_max}` — l'intervalle vient des arguments a valeur par defaut.
  defp def_unit({:when, _, [inner | _]}, acc, impl?), do: def_unit(inner, acc, impl?)

  defp def_unit({name, _, args}, acc, impl?) when is_atom(name) and is_list(args) do
    hi = length(args)
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    [{name, hi - defaults, hi, impl?} | acc]
  end

  defp def_unit({name, _, nil}, acc, impl?) when is_atom(name), do: [{name, 0, 0, impl?} | acc]
  defp def_unit(_, acc, _impl?), do: acc

  defp spec_unit({:when, _, [inner | _]}, acc), do: spec_unit(inner, acc)
  defp spec_unit({:"::", _, [head | _]}, acc), do: spec_unit(head, acc)

  defp spec_unit({name, _, args}, acc) when is_atom(name) and is_list(args),
    do: MapSet.put(acc, {name, length(args)})

  defp spec_unit({name, _, nil}, acc) when is_atom(name), do: MapSet.put(acc, {name, 0})
  defp spec_unit(_, acc), do: acc

  # LA DEPENDANCE INVISIBLE DU FOURNISSEUR — nature de couture SANS PRECEDENT dans ce depot.
  #
  # `Reconciliation.@pulled_states [:assigned]` dit qu'un work-item `:pending` (enfile, jamais tire)
  # ne possede AUCUN verrou. Trois modules raisonnent sur cette regle sans jamais l'appeler : ils la
  # citent en commentaire. Le fournisseur, lui, ignorait qu'il portait une garantie pour eux — la
  # changer casse leur raisonnement en silence, et rien ne relie les quatre fichiers.
  #
  # Les cinq autres natures de couture se verifient entre deux ENSEMBLES qui s'ecrivent. Celle-ci
  # n'a rien a comparer : la dependance ne laisse aucune trace executable. La seule forme qui la
  # rende verifiable est que le fournisseur la DECLARE — d'ou `pulled_states_dependents/0`, une
  # valeur dont le seul lecteur est ce mur.
  #
  # DEUX SENS, et le second est celui qui coute : un dependant qui apparait sans etre declare
  # reintroduit exactement l'angle mort qu'on ferme.
  #
  # ## Preuve (mutations jouees a la pose, 2026-08-20)
  # (a) un dependant retire de la declaration -> ECHEC, fichier nomme cote « cite, non declare » ;
  # (b) un fichier declare qui ne cite plus rien -> ECHEC, nomme cote « declare, ne cite plus ».
  # Angle mort declare : la citation est un GREP sur `@pulled_states`. Un module qui raisonnerait
  # sur la regle sans la nommer resterait invisible — c'est le prix d'une dependance qui ne
  # s'execute pas, et le nommage est deja la discipline du depot.
  @doc false
  @spec check_pulled_states_declared(String.t()) :: Support.result()
  def check_pulled_states_declared(root) do
    rel = "lib/fleet/pilot/poller/reconciliation.ex"

    declared =
      root
      |> quoted!(rel)
      |> collect(fn
        {:@, _, [{:pulled_states_dependents, _, [list]}]} when is_list(list) -> list
        _ -> nil
      end)
      |> List.flatten()
      |> collect_strings()
      |> MapSet.new()

    citing =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(&String.contains?(File.read!(&1), "@pulled_states"))
      |> Enum.map(&Path.relative_to(&1, root))
      # Le fournisseur lui-meme, et CE FICHIER : le gate LIT la regle, il n'en depend pas. S'auto-
      # compter ferait rougir le mur sur sa propre pose — mesure a la pose, 2026-08-20.
      |> Enum.reject(&(&1 in [rel, "lib/mix/tasks/lcars.contracts.check.ex"]))
      |> MapSet.new()

    cond do
      measured_nothing?(MapSet.to_list(declared)) ->
        broken_result(
          "reconciliation.pulled_states_declared",
          "@pulled_states_dependents in #{rel}"
        )

      measured_nothing?(MapSet.to_list(citing)) ->
        broken_result("reconciliation.pulled_states_declared", "files citing @pulled_states")

      true ->
        non_declares = citing |> MapSet.difference(declared) |> Enum.sort()
        fantomes = declared |> MapSet.difference(citing) |> Enum.sort()

        %{
          id: "reconciliation.pulled_states_declared",
          remediation:
            "`@pulled_states` porte une garantie pour des modules qui ne l'appellent pas — le " <>
              "fournisseur doit les nommer, sinon le changer casse leur raisonnement en silence",
          status: if(non_declares == [] and fantomes == [], do: :pass, else: :fail),
          evidence:
            Enum.map(non_declares, &"cite @pulled_states, NON declare: #{&1}") ++
              Enum.map(fantomes, &"declare, ne cite plus: #{&1}"),
          note: "provider declares the dependents of its ownership rule (nature 4)"
        }
    end
  end

  # L'ECHELLE DE SEVERITE, ECRITE DEUX FOIS.
  #
  # `FindingsWire.severities/0` porte l'ORDRE (du plus faible au plus fort) : le `block_at` d'une
  # carte s'y compare. `findings-v1.json` porte l'APPARTENANCE : ce qu'un juge a le droit d'ecrire.
  # Deux formes, un seul vocabulaire — et le `@doc` de la fonction affirme etre « the ONLY place
  # this order is written », ce qui est vrai de l'ORDRE et faux de l'ENSEMBLE.
  #
  # La paire est nee DANS le lot qui a paye le cas `"none"` : un juge avait ecrit `"none"` pour dire
  # « rien trouve », l'enum ne le portait pas, et toute sa charge est morte pour un mot. La lecon du
  # lot etait « tout ce qu'un juge peut ecrire doit etre accepte ou refuse lisiblement » ; le meme
  # lot a cree une seconde copie du meme vocabulaire, sans mur.
  #
  # Ce check compare les ENSEMBLES, jamais l'ordre : l'ordre n'existe que cote Elixir, et un enum
  # JSON n'en porte aucun. Une severite ajoutee d'un cote et pas de l'autre est refusee ici.
  #
  # ## Preuve (mutation jouee a la pose, 2026-08-20)
  # (a) Ajouter `"blocker"` a `severities/0` sans toucher le schema -> ECHEC, la severite est
  #     nommee absente des DEUX enums.
  # (b) Remplacer `"important"` par `"zzz"` dans le seul enum `severity_max` -> ECHEC, une absence
  #     et un surnombre nommes. La version qui ne lisait que l'enum par-finding restait verte.
  # Angle mort declare : `"none"` est ecrit ici, pas derive — aucun code Elixir ne le produit, il
  # naît du juge et ne vit que dans le schema. Un second sentinelle du meme genre serait invisible.
  # La valeur que le juge rend quand la mesure est faite et vide. Elle n'existe QUE dans le
  # schema — aucun code Elixir ne la produit — donc le mur la nomme ici plutot que de deviner.
  @severity_max_empty "none"

  @doc false
  @spec check_findings_severities_aligned(String.t()) :: Support.result()
  def check_findings_severities_aligned(root) do
    rel_ex = "lib/fleet/findings_wire.ex"
    rel_json = "priv/workflow/schema/findings-v1.json"

    from_code =
      root
      |> quoted!(rel_ex)
      |> collect(fn
        {:def, _, [{:severities, _, nil} | rest]} -> rest
        {:def, _, [{:severities, _, []} | rest]} -> rest
        _ -> nil
      end)
      |> List.flatten()
      |> collect_strings()
      |> MapSet.new()

    json =
      with {:ok, raw} <- File.read(Path.join(root, rel_json)),
           {:ok, decoded} <- Jason.decode(raw) do
        decoded
      else
        _ -> %{}
      end

    enum = fn path ->
      case get_in(json, path) do
        l when is_list(l) -> MapSet.new(l)
        _ -> MapSet.new()
      end
    end

    from_schema = enum.(["properties", "findings", "items", "properties", "severity", "enum"])

    # LE SECOND ENUM, ET CELUI OU L'INCIDENT A EU LIEU. `severity_max` n'est pas une redite de
    # `severity` : c'est l'operande que `Gates.Predicate` compare (`"severity_max != critical"`),
    # donc le seul des deux qu'une porte lise. Il porte une valeur de plus, `"none"` — la mesure
    # faite dont le resultat est vide, refusee au fil quand elle manquait. Le mur ne lisait que
    # l'enum par-finding : une severite ajoutee ici et pas la, ou l'inverse, passait au vert.
    max_expected = MapSet.put(from_code, @severity_max_empty)
    from_max = enum.(["properties", "severity_max", "enum"])

    cond do
      measured_nothing?(MapSet.to_list(from_code)) ->
        broken_result("findings.severities_aligned", "severities/0 in #{rel_ex}")

      measured_nothing?(MapSet.to_list(from_schema)) ->
        broken_result("findings.severities_aligned", "severity enum in #{rel_json}")

      measured_nothing?(MapSet.to_list(from_max)) ->
        broken_result("findings.severities_aligned", "severity_max enum in #{rel_json}")

      true ->
        code_only = from_code |> MapSet.difference(from_schema) |> Enum.sort()
        schema_only = from_schema |> MapSet.difference(from_code) |> Enum.sort()
        max_missing = max_expected |> MapSet.difference(from_max) |> Enum.sort()
        max_extra = from_max |> MapSet.difference(max_expected) |> Enum.sort()

        %{
          id: "findings.severities_aligned",
          remediation:
            "une severite ecrite d'un seul cote est soit refusee au fil (le juge perd sa charge " <>
              "entiere, cf. le cas `none`), soit acceptee et jamais comparee au `block_at`",
          status:
            if(code_only == [] and schema_only == [] and max_missing == [] and max_extra == [],
              do: :pass,
              else: :fail
            ),
          evidence:
            Enum.map(code_only, &"absente de l'enum severity: #{inspect(&1)}") ++
              Enum.map(schema_only, &"absente de severities/0: #{inspect(&1)}") ++
              Enum.map(max_missing, &"absente de l'enum severity_max: #{inspect(&1)}") ++
              Enum.map(max_extra, &"en trop dans severity_max: #{inspect(&1)}"),
          note:
            "findings-v1 severity vocabulary: severities/0 == enum severity, " <>
              "et == enum severity_max prive de #{inspect(@severity_max_empty)}"
        }
    end
  end

  # Les binaires litteraux d'un fragment d'AST — la liste rendue par une fonction, sans l'evaluer.
  defp collect_strings(ast) do
    collect(ast, fn
      s when is_binary(s) -> s
      _ -> nil
    end)
  end

  # LA TABLE DES KINDS D'ESCALADE, FERMEE DANS LES DEUX SENS.
  #
  # `Escalation.kind_describe/1` est une table CLOSE : un kind sans clause n'ouvre pas d'issue, il
  # leve un `FunctionClauseError`. C'est ce qui est arrive a `:awaits_arch_stuck` — emis par
  # `StepRunConsumer.drain_failed/4`, sans clause — et il a crashe exactement sur le chemin
  # « un ticket sort du pipeline en silence ». Le temoin du drain stubbait `escalate_fun`, donc il
  # ne pouvait pas le voir : une couverture de test ne dit rien d'une couture.
  #
  # L'autre sens coute moins cher mais ment autant : une clause sans producteur (`:pod_failed`,
  # 2026-08-20) se lit comme une garantie que quelque chose sait remonter ce cas. C'est le motif
  # « mensonge du registre » que `events.yaml` nomme deja pour ses propres cles.
  #
  # DEUX SOURCES DE PRODUCTION, et il faut les deux : les routes declaratives d'`events.yaml`
  # (`escalate_kind:`) et les sites de code, ou le kind est le PREMIER argument d'un appel a cinq
  # arguments dont l'appele nomme une escalade (`escalate`, `escalate_gated`, `escalate_or_signal`,
  # ou la couture homonyme). Le Catalog garde deja au boot qu'une route `immediate` PORTE un
  # `escalate_kind` ; il ne verifie pas que ce kind ait une clause.
  #
  # ## Preuve (mutations jouees a la pose, 2026-08-20)
  # (a) clause retiree pour un kind produit -> ECHEC, kind nomme cote « sans clause » ;
  # (b) clause ajoutee pour un kind que personne ne produit -> ECHEC, kind nomme cote « morte » ;
  # (c) `escalate_kind: :disk_full` pose chez un appelant de `record_or_escalate/4` -> ECHEC, kind
  #     nomme « emis SANS clause ». C'est la voie CANONIQUE, et la version precedente la manquait
  #     entierement : le kind ne passe pas en argument, il voyage dans les opts ;
  # (d) une clause morte gardee vivante par un COMMENTAIRE de `events.yaml` -> ECHEC. Le regex
  #     lisait le texte brut, donc une ligne d'historique suffisait a nier la mort d'une clause.
  # Angle mort declare : un kind construit dynamiquement (variable, interpolation) est invisible —
  # aucun n'existe aujourd'hui, et un mur precis vaut mieux qu'un mur qui devine.
  @doc false
  @spec check_escalation_kinds_closed(String.t()) :: Support.result()
  def check_escalation_kinds_closed(root) do
    rel = "lib/fleet/pilot/incident_registry/escalation.ex"

    declared =
      root
      |> quoted!(rel)
      |> collect(fn
        {:defp, _, [{:kind_describe, _, [k]} | _]} when is_atom(k) -> k
        _ -> nil
      end)
      |> MapSet.new()

    from_code =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn f ->
        f |> File.read!() |> Code.string_to_quoted!() |> escalated_kinds()
      end)
      |> MapSet.new()

    from_yaml =
      case File.read(Path.join(root, "priv/event_router/events.yaml")) do
        {:ok, y} ->
          # Les commentaires tombent AVANT la lecture : la version brute lisait le texte entier,
          # donc `# historique: on avait un jour escalate_kind: zzz_dead` suffisait a garder
          # vivante une clause que plus personne ne produit. Un mur qui lit un commentaire mesure
          # ce que quelqu'un a ECRIT, pas ce que le systeme EMET.
          ~r/escalate_kind:\s*([a-z_]+)/
          |> Regex.scan(y |> String.split("\n") |> Enum.map_join("\n", &strip_comment/1))
          |> Enum.map(fn [_, k] -> String.to_atom(k) end)
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    emitted = MapSet.union(from_code, from_yaml)

    sans_clause = emitted |> MapSet.difference(declared) |> Enum.sort()
    mortes = declared |> MapSet.difference(emitted) |> Enum.sort()

    cond do
      measured_nothing?(MapSet.to_list(declared)) ->
        broken_result("incident.kinds_closed", "defp kind_describe/1 in #{rel}")

      measured_nothing?(MapSet.to_list(emitted)) ->
        broken_result("incident.kinds_closed", "escalate_kind producers (events.yaml + lib/)")

      true ->
        %{
          id: "incident.kinds_closed",
          remediation:
            "tout kind emis doit avoir sa clause `kind_describe/1` (sinon l'escalade CRASHE au " <>
              "lieu d'ouvrir l'issue) et toute clause doit avoir un producteur (sinon la table " <>
              "annonce une remontee que personne ne declenche)",
          status: if(sans_clause == [] and mortes == [], do: :pass, else: :fail),
          evidence:
            Enum.map(sans_clause, &"emis SANS clause: #{inspect(&1)}") ++
              Enum.map(mortes, &"clause MORTE (aucun producteur): #{inspect(&1)}"),
          note: "escalation kinds: emitted set == kind_describe/1 clause set"
        }
    end
  end

  # Le kind d'une escalade : premier argument d'un appel a CINQ arguments dont l'appele nomme une
  # escalade. Couvre l'appel direct, la couture (`escalate.(…)`) et le relais local.
  defp escalated_kinds(ast) do
    collect(ast, fn
      # (1) le kind litteral en TETE d'un appel a cinq arguments dont l'appele nomme une escalade.
      {callee, _, [k | rest]} when is_atom(k) and length(rest) == 4 ->
        n = callee_name(callee)
        if n && String.contains?(Atom.to_string(n), "escalate"), do: k, else: nil

      # (2) `escalate_kind: :foo` dans n'importe quelle liste a mots-cles. C'EST LA VOIE
      #     CANONIQUE, et la version (1) seule la manquait entierement : l'API publique est
      #     `record_or_escalate/4`, qui ne prend PAS le kind en argument — il voyage dans ses
      #     `opts` jusqu'a `escalate/5` (`incident_registry.ex:84`). Un `escalate_kind: :disk_full`
      #     ecrit chez un appelant passait donc au vert et levait un `FunctionClauseError` a
      #     l'execution, exactement le crash que cette table close est censee rendre impossible.
      {:escalate_kind, k} when is_atom(k) and k not in [nil, true, false] ->
        k

      # (3) le DEFAUT du meme acces : `Keyword.get(opts, :escalate_kind, :recurrence)` emet
      #     `:recurrence` sans qu'aucun appelant ne l'ecrive nulle part.
      {{:., _, [{:__aliases__, _, [:Keyword]}, g]}, _, [_, :escalate_kind, d]}
      when g in [:get, :get_lazy] and is_atom(d) and d not in [nil, true, false] ->
        d

      _ ->
        nil
    end)
  end

  defp callee_name({:., _, [{n, _, _}]}) when is_atom(n), do: n
  defp callee_name({:., _, [_mod, n]}) when is_atom(n), do: n
  defp callee_name(n) when is_atom(n), do: n
  defp callee_name(_), do: nil

  # LE COUPLE `type_for_destination/1` <-> `visual_types/0` : l'un PRODUIT les types visuels, l'autre
  # les SEME sur chaque depot. Deux ensembles qui doivent rester egaux, et qui ont divergé pendant
  # SEIZE JOURS — `type:doc` seme et porte par personne, `type:workshop` porte et jamais seme, donc
  # cree paresseusement, gris et sans description.
  #
  # `visual_types/0` est desormais DERIVEE : elle mappe `type_for_destination/1` sur `@destinations`.
  # La derivation ferme la recopie ; ce mur ferme ce qu'elle laisse ouvert — qu'une clause ajoutee a
  # `type_for_destination/1` ait sa destination dans `@destinations`. Sans lui, un troisieme type
  # naitrait produit et jamais seme, exactement comme le deuxieme.
  #
  # ## Preuve (mutation jouee a la pose, 2026-08-20)
  # (a) Ajouter une clause `def type_for_destination("ops"), do: "type:ops"` sans toucher
  #     `@destinations` -> ECHEC, 3 clauses annoncees pour 2 destinations.
  # (b) Rendre `visual_types/0` a sa forme d'avant — `do: ["type:feature", "type:doc"]`, la recopie
  #     exacte qui a diverge seize jours -> ECHEC, la derivation manquante ET les deux litteraux
  #     nommes. La version qui comptait seulement clauses contre destinations restait verte : elle
  #     ne lisait jamais la fonction dont elle porte le nom.
  # Son angle mort, declare : il compte, il ne resout pas — deux clauses rendant le MEME type
  # passeraient pour deux destinations manquantes si l'une n'etait pas listee. Le cas n'existe pas
  # aujourd'hui et un compteur exact vaut mieux qu'un resolveur qui devine.
  @doc false
  @spec check_visual_types_derived(String.t()) :: Support.result()
  def check_visual_types_derived(root) do
    rel = "lib/fleet/labels.ex"
    ast = quoted!(root, rel)

    clauses =
      collect(ast, fn
        {:def, _, [{:type_for_destination, _, [_arg]} | _]} -> :clause
        _ -> nil
      end)

    destinations =
      collect(ast, fn
        {:@, _, [{:destinations, _, [list]}]} when is_list(list) -> length(list)
        _ -> nil
      end)

    # LE CORPS DE `visual_types/0`, ET C'EST LE POINT QUI MANQUAIT. Le mur comptait des clauses
    # contre des destinations et ne lisait JAMAIS la fonction dont il porte le nom : reecrire
    # `def visual_types, do: ["type:feature", "type:doc"]` — la recopie exacte qui a diverge
    # pendant seize jours — le laissait au vert. Un mur qui garde une DERIVATION doit constater
    # la derivation, pas ses deux operandes.
    body =
      collect(ast, fn
        {:def, _, [{:visual_types, _, a}, [do: b]]} when a in [nil, []] -> b
        _ -> nil
      end)

    cond do
      measured_nothing?(clauses) ->
        broken_result("labels.visual_types_derived", "def type_for_destination/1 in #{rel}")

      measured_nothing?(destinations) ->
        broken_result("labels.visual_types_derived", "@destinations in #{rel}")

      measured_nothing?(body) ->
        broken_result("labels.visual_types_derived", "def visual_types/0 in #{rel}")

      true ->
        n_clauses = length(clauses)
        n_dest = hd(destinations)
        b = hd(body)

        reads = fn name ->
          [] !=
            collect(b, fn
              {:@, _, [{^name, _, _}]} -> :ref
              {^name, _, _} -> :ref
              {:/, _, [{^name, _, _}, _]} -> :ref
              _ -> nil
            end)
        end

        derived? = reads.(:destinations) and reads.(:type_for_destination)
        literals = b |> collect_strings() |> Enum.sort()

        %{
          id: "labels.visual_types_derived",
          remediation:
            "une clause de `type_for_destination/1` sans sa destination dans `@destinations` " <>
              "produit un type visuel que `visual_types/0` ne seme pas — il naitra gris et sans " <>
              "description, comme `type:workshop` pendant seize jours",
          status: if(n_clauses == n_dest and derived? and literals == [], do: :pass, else: :fail),
          evidence:
            if(n_clauses == n_dest,
              do: [],
              else: [
                "#{rel}: #{n_clauses} clause(s) type_for_destination/1 pour #{n_dest} @destinations"
              ]
            ) ++
              if(derived?,
                do: [],
                else: [
                  "#{rel}: visual_types/0 ne lit pas @destinations via type_for_destination/1"
                ]
              ) ++
              Enum.map(
                literals,
                &"#{rel}: visual_types/0 ecrit un type en dur: #{inspect(&1)}"
              ),
          note: "visual_types derives from type_for_destination over @destinations"
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

  # `Fleet.SPBuilder.filter_skills/2` must fail (fail-loud) if a whitelisted PLAIN skill is absent from
  # disk — otherwise a silent filtering would let a pod claim a nonexistent skill. BND-111: confirm the
  # EXECUTABLE tuple `{:error, {:skills_missing, ...}}` on its line (the @doc/@comment name the same tuple
  # in prose; `code_match?` excludes doc blocks, and the tuple-shape confirm excludes an inline mention).
  # Red if absent.
  @doc false
  @spec check_skills_declared_present(String.t()) :: Support.result()
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
  @spec check_events_registry_keys_aligned(String.t()) :: Support.result()
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
  @spec check_boot_order_f8(String.t()) :: Support.result()
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
  # ── site.build_inputs ──────────────────────────────────────────────────────────────────────────
  # LE SITE VITRINE LIT LE RUNTIME POUR L'ENUMERER : chaque fichier que son build ouvre est une
  # ENTREE, et le workflow qui le publie filtre sur `paths:`. Une entree absente de ce filtre est un
  # changement qui ne redeclenche RIEN — le site reste en ligne et decrit la version d'avant.
  #
  # ⚠ LE MODE DE PANNE EST MUET DANS LA MAUVAISE DIRECTION, et c'est ce qui justifie un contrat
  # plutot qu'une relecture. L'en-tete du workflow dit vouloir l'inverse — « une plaquette qui ne
  # trouve plus ce qu'elle decrit doit ECHOUER, pas servir la version d'avant » — et les vingt
  # `throw` des sources du site sont ecrits pour ca. Ils ne servent a rien quand le build NE TOURNE
  # PAS : le filtre decide s'il tourne, donc le filtre decide si les gardes existent. Mesure du
  # 2026-08-20 : huit entrees sur dix hors filtre (les cap-profiles systeme, les deux sources Elixir
  # du catalogue, les launchers, les deux fichiers MCP).
  #
  # CE QUI EST DERIVE, ET LA LIMITE ASSUMEE. On resout les `join()` des sources du site : `const X =
  # join(here, '..'x4, …)` puis `join(X, …)`, style uniforme dans ces quatre fichiers. Un segment
  # NON litteral (`join(BIN, name)`) ne se resout pas — on rend alors le prefixe connu comme un
  # repertoire, qui exige une couverture en `**`. C'est volontairement conservateur : mieux vaut
  # exiger trop large sur le seul cas dynamique que de certifier une liste close qui ne l'est pas.
  # A BATS TEST NAME IS EVALUATED BY THE SHELL, AND THAT IS NOT A STYLE MATTER.
  #
  # From bats-core 1.11, `bats_test_function` resolves variable references in a description with
  # `eval "printf -v d '%s' \"$2\""`. Everything a double-quoted string expands, a test NAME expands:
  # a backtick pair runs a command, `$(…)` runs a command, `$VAR` interpolates. Measured 2026-08-20
  # on bats 1.11.1: the description « ce que `box reset` epargne » RAN `box reset` at file load —
  # twice — and the name printed in the report came back MUTILATED, with the quoted text gone.
  #
  # THE COST IS NOT THE MANGLED NAME, IT IS THE EXECUTION. A description is prose: nobody reviews it
  # as code, and the danger scales with how ordinary the quoted words look. `box reset`, `ip`, `..`,
  # `/`, `-`, `:=` were all in this repository, in files that also drive a real provisioning rail.
  # Nothing ran on bats 1.10, so a whole estate can carry this for months and see it the day one
  # machine upgrades — six suites went red at once on the native workbench, and the reported failures
  # named assertions that were fine: the eval's stderr had leaked into `$output`.
  #
  # ESCAPING IS ENOUGH AND KEEPS THE PROSE INTACT (measured, both forms, in isolation): `\`` survives
  # the eval and renders as a plain backtick. So this wall does not ban the repository's habit of
  # quoting code in a test name — it requires the one backslash that makes the name inert.
  @doc false
  @spec check_bats_descriptions_inert(String.t()) :: Support.result()
  def check_bats_descriptions_inert(root) do
    # ⚠ L'ARBRE SE BALAYE, IL NE SE LISTE PAS. Ce check a d'abord nomme `test/` et `deploy/tests/` :
    # il ratait les six suites de `git-hooks/tests/` et de `.claude/skills/`, c'est-a-dire justement
    # les repertoires qu'on oublie. Un mur qui enumere ses arbres ne protege que ceux qu'on avait
    # deja en tete le jour ou on l'a ecrit — et le suivant qu'on cree n'est protege par rien.
    #
    # `_build`, `deps` et `tmp` sont exclus : ce sont des COPIES ou des artefacts, et un doublon
    # signale la ligne deux fois sous un chemin que personne ne peut editer.
    files =
      [root, Path.join(Path.expand("..", root), ".claude")]
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.bats")))
      |> Enum.reject(
        &String.match?("/" <> Path.relative_to(&1, root), ~r"/(_build|deps|tmp|node_modules)/")
      )
      |> Enum.uniq()
      |> Enum.sort()

    offenders =
      for path <- files,
          {line, n} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
          String.starts_with?(line, "@test "),
          reason = evaluable_description_reason(line),
          do: "#{Path.relative_to(path, root)}:#{n} — #{reason}"

    cond do
      files == [] ->
        %{
          id: "bats.descriptions_inert",
          status: :pass,
          remediation:
            "aucun geste : aucun fichier .bats dans cet arbre. Rejouer depuis un arbre complet",
          evidence: [],
          note: "HORS PERIMETRE — pas de suite bats ici, donc aucune description n'est mesuree"
        }

      offenders == [] ->
        %{
          id: "bats.descriptions_inert",
          status: :pass,
          remediation: "",
          evidence: [],
          note:
            "les #{length(files)} suites bats ont des descriptions INERTES — depuis bats 1.11 un " <>
              "nom de test est evalue par le shell, donc un accent grave nu y EXECUTE une commande"
        }

      true ->
        %{
          id: "bats.descriptions_inert",
          status: :fail,
          remediation:
            "echapper l'accent grave dans la description (\\` au lieu de `) — la forme echappee " <>
              "traverse l'eval et s'affiche identique. Meme geste pour $( et $VAR",
          evidence: offenders,
          note:
            "#{length(offenders)} description(s) de test EXECUTEES par bats >= 1.11 au chargement " <>
              "du fichier : le nom est passe a `eval` (bats_test_function), et sa sortie pollue " <>
              "`$output` de tous les temoins du fichier"
        }
    end
  end

  # Ce que l'eval de bats ferait de cette ligne, ou nil si elle est inerte. Un caractere precede d'un
  # nombre IMPAIR de contre-obliques est echappe ; sinon il est vivant. `$VAR` est inclus : il
  # n'execute rien mais il rend le nom du test dependant de l'environnement, ce qui le fait varier
  # d'une machine a l'autre — la meme faute, en plus silencieuse.
  defp evaluable_description_reason(line) do
    cond do
      Regex.match?(~r/(?<!\\)(?:\\\\)*`/, line) ->
        "accent grave NU — la commande citee est EXECUTEE"

      Regex.match?(~r/(?<!\\)(?:\\\\)*\$\(/, line) ->
        "$( NU — la commande citee est EXECUTEE"

      Regex.match?(~r/(?<!\\)(?:\\\\)*\$[A-Za-z_{]/, line) ->
        "$VAR NU — le nom du test varie selon l'environnement"

      true ->
        nil
    end
  end

  @doc false
  @spec check_site_build_inputs(String.t()) :: Support.result()
  def check_site_build_inputs(root) do
    repo = Path.expand("..", root)
    wf = Path.join(repo, ".github/workflows/site.yml")
    lib = Path.join(repo, "assets/github.io/src/lib")

    # ⚠ L'ARBRE `assets/` EST UN VOISIN, ET UN CONTEXTE LEGITIME NE LE PORTE PAS. Le stage `build`
    # de l'image copie `fleet` SEUL puis joue ce gate : un artefact runtime ne peut rien prouver sur
    # une plaquette qu'il n'embarque pas. Ce check a d'abord rendu FAIL la — 0 entree derivee, mon
    # fail-closed — et il a fait echouer la construction de l'image sur une plaquette absente.
    #
    # L'absence se lit au niveau de L'ARBRE, comme pour les listes de provisioning : pas d'arbre du
    # tout = hors perimetre, on passe EN LE DISANT (jamais un vert muet sur du terrain non mesure).
    # Arbre present mais workflow illisible = le vrai defaut, et il reste rouge.
    if not File.dir?(lib) do
      %{
        id: "site.build_inputs",
        status: :pass,
        remediation:
          "aucun geste : l'arbre du site n'est pas ici. Rejouer ce check depuis un arbre complet " <>
            "(racine du depot) pour mesurer le filtre `paths:`",
        evidence: [],
        note:
          "HORS PERIMETRE — assets/github.io absent de cet arbre (le stage image `build` ne copie " <>
            "que fleet/), donc le filtre `paths:` n'est pas mesure ici"
      }
    else
      check_site_build_inputs_measured(wf, lib, repo)
    end
  end

  defp check_site_build_inputs_measured(wf, lib, repo) do
    listed =
      case File.read(wf) do
        {:ok, y} ->
          # ⚠ LES TROIS FORMES YAML, PAS SEULEMENT CELLE QU'ON ECRIT AUJOURD'HUI. Ce motif ne
          # prenait que l'apostrophe simple. Le workflow n'emploie qu'elle, donc le mur etait vert —
          # mais passer une entree en double-quote ou en nu l'aurait rendue invisible a `listed`,
          # donc tous les chemins qu'elle couvre auraient ete declares NON couverts. Un FAUX ROUGE
          # sur un filtre correct, et l'operateur aurait cherche le defaut dans le filtre. Un
          # instrument couple a la forme de ce qu'il mesure ne mesure plus, il devine. (Revue
          # 2026-08-20.)
          ~r/^\s*-\s*(?:'([^']+)'|"([^"]+)"|([^\s#'"][^\s#]*))\s*$/m
          |> Regex.scan(y, capture: :all_but_first)
          |> List.flatten()
          |> Enum.reject(&(&1 == ""))
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    read = site_build_inputs(repo)

    uncovered =
      read
      |> Enum.reject(fn {path, kind} -> site_path_covered?(path, kind, listed) end)
      |> Enum.map(fn {path, kind} ->
        "#{path}#{if kind == :dir, do: "/** (lecture dynamique)"}"
      end)
      |> Enum.sort()

    %{
      id: "site.build_inputs",
      status: if(File.exists?(wf) and read != [] and uncovered == [], do: :pass, else: :fail),
      remediation:
        "ajouter les chemins manquants au `paths:` de .github/workflows/site.yml — le build du " <>
          "site LIT ces fichiers, donc un changement qui ne les declenche pas laisse la plaquette " <>
          "decrire la version d'avant, en silence",
      evidence:
        cond do
          not File.exists?(wf) -> [".github/workflows/site.yml INTROUVABLE — fail-closed"]
          read == [] -> ["aucune entree derivee de #{Path.relative_to(lib, repo)} — fail-closed"]
          true -> Enum.map(uncovered, &"lu par le build, HORS paths: #{&1}")
        end,
      note:
        "le filtre `paths:` du workflow doit couvrir toute source runtime que le site lit " <>
          "(#{length(read)} derivees)"
    }
  end

  # Les chemins repo-relatifs que le build du site ouvre, en {chemin, :file | :dir}.
  #
  # ⚠ UN REPERTOIRE QUI N'EST QU'UN PREFIXE N'EST PAS UNE ENTREE. `const PRIV = join(ROOT, 'fleet',
  # 'priv')` est un `join()` comme un autre pour l'extracteur, mais personne ne LIT `fleet/priv` :
  # c'est le point de depart de `fleet/priv/catalogue/…`. Les garder exigeait du filtre qu'il couvre
  # `fleet/priv` entier — c'est-a-dire tout le catalogue, tous les schemas, tout `priv/` — pour une
  # ligne qui ne lit rien.
  #
  # La lecture DYNAMIQUE echappe a cette regle et c'est le fond de l'affaire : `join(BIN, name)` ne
  # dit pas quel fichier, donc `fleet/bin` est bien l'entree, meme si un autre site en lit un fichier
  # nomme. Un prefixe rendu par une lecture dynamique reste une entree ; le meme prefixe rendu par
  # une definition de constante disparait.
  # ⚠ `src/lib/*.js` N'EST PAS TOUT CE QUI LIT L'ARBRE, ET LE CONTRAT A RENDU UN FAUX VERT DESSUS.
  # `src/components/Seat.astro:14` fait `existsSync(join(here, '..','..','..','avatars', …))` — une
  # lecture de `assets/avatars/` AU BUILD — et `src/layouts/Site.astro` sert `/favicon/`. Les deux
  # etaient invisibles ici.
  #
  # Mesure du 2026-08-22 : on a restreint `paths:` de `assets/**` a `assets/github.io/**` et le
  # contrat a repondu `pass`. Avec ce filtre, ajouter un avatar de role ne rebatit plus la vitrine
  # qui l'affiche — exactement le mode de panne MUET que ce contrat existe pour fermer, et il le
  # laissait passer parce qu'il ne regardait qu'un tiers des fichiers.
  #
  # ⚠ ET C'EST UNE FAUTE DE PERIMETRE, PAS DE REGLE. La regle etait juste ; l'instrument lisait a
  # cote. Un contrat qui scanne moins que ce qu'il pretend couvrir ne dit pas « je ne sais pas », il
  # dit « pass ».
  @site_sources [
    "src/lib/*.js",
    "src/components/*.astro",
    "src/layouts/*.astro",
    "src/pages/*.astro"
  ]

  defp site_build_inputs(repo) do
    site = Path.join(repo, "assets/github.io")

    all =
      @site_sources
      |> Enum.flat_map(&Path.wildcard(Path.join(site, &1)))
      |> Enum.flat_map(&site_inputs_of_file(&1, repo))
      |> Enum.uniq()

    deeper = fn p ->
      Enum.any?(all, fn {q, _} -> q != p and String.starts_with?(q, p <> "/") end)
    end

    Enum.reject(all, fn {path, kind} -> kind == :file and deeper.(path) end)
  end

  defp site_inputs_of_file(file, repo) do
    src = File.read!(file)

    # LE REPERTOIRE DU FICHIER, RELATIF A LA RACINE. C'est de LUI que les `..` remontent — pas d'une
    # profondeur supposee. Deux fichiers a la meme profondeur peuvent ecrire un nombre DIFFERENT de
    # `..`, et c'est exactement ce qui rendait `avatars` la ou la cible est `assets/avatars`.
    here_dir = file |> Path.dirname() |> Path.relative_to(repo)

    # 1. Les constantes : `const NAME = join(<base>, 'a', 'b')`.
    #    Deux passes suffisent : ces fichiers ne chainent jamais plus loin.
    consts =
      Enum.reduce(1..2, %{}, fn _, acc ->
        Regex.scan(~r/const\s+(\w+)\s*=\s*join\(\s*(\w+)\s*,([^)]*)\)/, src)
        |> Enum.reduce(acc, fn [_, name, base, rest], m ->
          case site_resolve(base, rest, m, here_dir) do
            {:ok, p} ->
              Map.put(m, name, p)

            # ⚠ UNE CONSTANTE DYNAMIQUE N'EST PAS UN PREFIXE, ET LA RECORDER MENTIRAIT. `const path
            # = join(dir, f)` nomme un FICHIER dont le dernier segment est inconnu ; ranger `dir`
            # sous le nom `path` ferait resoudre un futur `join(path, 'x')` vers un chemin qui
            # n'existe pas, et le contrat conclurait sur une lecture imaginaire.
            #
            # Ne rien retenir ne perd rien : la passe des USAGES voit le meme `join` et rend
            # `{dir, :dir}`, c'est-a-dire l'exigence la plus forte — un repertoire ouvert reclame un
            # glob, et nommer trois fichiers ne le ferme pas.
            #
            # ⚠ CETTE CLAUSE MANQUAIT, et son absence n'etait pas inerte : `site_resolve` rend TROIS
            # formes depuis toujours, le `case` en connaissait deux. La premiere constante dynamique
            # du site a fait tomber le contrat par CaseClauseError — un contrat qui CRASHE ne dit
            # rien, ni pass ni fail (2026-08-22, `assets/github.io/src/lib/catalogue.js:81`).
            {:dynamic, _} ->
              m

            :error ->
              m
          end
        end)
      end)

    # 2. Les usages : tout `join(<base>, …)` dont la base est `here` ou une constante connue.
    Regex.scan(~r/join\(\s*(\w+)\s*,([^)]*)\)/, src)
    |> Enum.flat_map(fn [_, base, rest] ->
      case site_resolve(base, rest, consts, here_dir) do
        # Un segment non litteral : on ne sait pas QUEL fichier, on sait dans quel repertoire.
        {:dynamic, p} -> [{p, :dir}]
        {:ok, p} -> if p == "", do: [], else: [{p, :file}]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  # base + segments -> chemin repo-relatif. `here` = racine (les quatre `..` l'y ramenent).
  # ⚠ LES `..` SE COMPTENT, ILS NE « S'ANNULENT » PAS. Cette fonction supposait que `here` valait la
  # RACINE du depot et que les `..` disparaissaient — vrai par coincidence pour `src/lib/*.js`, qui
  # est a quatre crans et n'ecrit jamais que quatre `..`. `src/components/Seat.astro` en ecrit TROIS
  # depuis la meme profondeur : la vraie cible est `assets/avatars`, et l'ancienne regle rendait
  # `avatars` — un chemin qui n'existe pas, donc jamais couvert, donc un `fail` inexplicable.
  #
  # On resout donc pour de vrai : depuis le repertoire du FICHIER, `..` par `..`, puis on rend le
  # chemin relatif a la racine. `here_depth` est le nombre de crans du fichier sous la racine.
  defp site_resolve(base, rest, consts, here_dir) do
    prefix =
      case base do
        "here" -> {:ok, :here}
        n -> if p = consts[n], do: {:ok, p}, else: :error
      end

    with {:ok, pre} <- prefix do
      segs = String.split(rest, ",", trim: true) |> Enum.map(&String.trim/1)
      ups = Enum.count(segs, &(&1 in ["'..'", "\"..\""]))
      lits = Enum.reject(segs, &(&1 in ["'..'", "\"..\"", ""]))
      dynamic? = Enum.any?(lits, &(not Regex.match?(~r/^'[^']*'$|^"[^"]*"$/, &1)))

      parts =
        lits |> Enum.filter(&Regex.match?(~r/^'|^"/, &1)) |> Enum.map(&String.slice(&1, 1..-2//1))

      path =
        case pre do
          # Depuis `here` : on REMONTE reellement, `..` par `..`, depuis le repertoire du fichier.
          :here ->
            here_dir
            |> String.split("/", trim: true)
            |> then(&Enum.take(&1, max(length(&1) - ups, 0)))
            |> Kernel.++(parts)
            |> Enum.reject(&(&1 == ""))
            |> Enum.join("/")

          # Depuis une constante : elle est deja relative a la racine.
          p ->
            Enum.join(Enum.reject([p | parts], &(&1 == "")), "/")
        end

      if dynamic?, do: {:dynamic, path}, else: {:ok, path}
    end
  end

  # Un chemin est couvert si le filtre le nomme, ou si un glob `X/**` le contient. Une lecture
  # DYNAMIQUE (`:dir`) exige le glob : nommer trois fichiers ne ferme pas un repertoire ouvert.
  defp site_path_covered?(path, kind, listed) do
    globs =
      listed
      |> Enum.filter(&String.ends_with?(&1, "/**"))
      |> Enum.map(&String.replace_suffix(&1, "/**", ""))

    covered_by_glob? = Enum.any?(globs, &(path == &1 or String.starts_with?(path, &1 <> "/")))

    case kind do
      :dir -> covered_by_glob?
      :file -> covered_by_glob? or MapSet.member?(listed, path)
    end
  end

  @doc false
  @spec check_gitea_template_expansion(String.t()) :: Support.result()
  def check_gitea_template_expansion(root) do
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

    # ⚠ GARDE D'INSTRUMENT, ET IL MANQUAIT. `bearing` vient d'un `Path.wildcard` — repertoire absent
    # rend l'ensemble VIDE ; `listed` vient d'un `File.read` dont l'echec rend `MapSet.new()`. Les
    # deux vides rendent les deux differences vides, donc `:pass`. Prouve par mutation le
    # 2026-08-27 : renommer `priv/catalogue/project_template/main/` en `main_mv/` rendait
    # `pass — 0 fail, 58 pass`. Cinq autres contrats passent aussi sur perimetre vide, mais ILS LE
    # DISENT ; celui-ci etait le seul muet.
    #
    # ⚠ ET IL ECHAPPAIT AU FILET QUI EXISTE POUR CA. `no_check_passes_on_nothing_test` enumere les
    # checks par `__info__(:functions)`, qui ne voit que le PUBLIC — ce check etait `defp`. La
    # garantie « aucun check ne passe sur rien » couvrait 55 des 58, et le trou etait exactement la
    # ou personne ne regardait. Les trois checks prives sont passes `def` dans le meme geste.
    #
    # ICI ON ECHOUE, on ne declare pas « hors perimetre » : `priv/catalogue` part avec CHAQUE
    # artefact — le stage `build` de l'image copie `fleet` en entier moins `deploy`, `git-hooks` et
    # `system-prompt`. Une face absente n'est donc pas un contexte, c'est une face perdue.
    files =
      face
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)

    broken =
      cond do
        not File.dir?(face) -> "face priv/catalogue/project_template/main"
        files == [] -> "fichier sous la face project_template/main"
        not File.regular?(control) -> "liste de controle .gitea/template sous la face"
        true -> nil
      end

    bearing =
      files
      |> Enum.filter(&Regex.match?(re, File.read!(&1)))
      |> Enum.map(&Path.relative_to(&1, face))
      |> MapSet.new()

    missing = MapSet.difference(bearing, listed) |> Enum.sort()
    extra = MapSet.difference(listed, bearing) |> Enum.sort()

    if broken do
      broken_result("template.gitea_expansion", broken)
    else
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
  @spec check_catalogue_before_freeze(String.t()) :: Support.result()
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
  @spec check_proven_image_regime(String.t()) :: Support.result()
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
  @spec check_event_registry_loaded_before_children(String.t()) :: Support.result()
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
  @spec check_roles_provisioning_locked(String.t()) :: Support.result()
  def check_roles_provisioning_locked(root) do
    # Decoded reads (kind/forge_identity are yaml fields, not greppable shapes) — the task
    # context does not start :yaml_elixir by itself; same explicit start as lcars.sp.gen.
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    catalogue = Catalogue.scan_catalogue_roles(root)

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
    # (`Fleet.Roster.tfvars/1`) produit deja la reponse. Rien ne les comparait, donc rien
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

  # role_index is the role's slot in the hexspeak UUID — the schema bounds it (0..15) per file,
  # nothing enforced uniqueness across the catalogue (BL-6-45 F7): two roles on one slot would
  # make `pkill -f '<X>badcafe'` kill classes collide. Seats included (a seat CLAIMS its slot).
  # ── sp.adresser_un_agent ───────────────────────────────────────────────────────────────────────
  # UNE SOURCE DE PROSE, DIX NOMS, UN MUR — et c'est le mur qui rend les deux premiers tenables.
  #
  # La regle « le destinataire de ce que tu ecris est le meme agent que toi » doit atteindre TOUS les
  # roles. Elle ne peut pas passer par un bloc `core/*` : `Blocks.audit!` impose UNE source par role
  # — une entree dans `sp-map.yaml` OU un draft ecrit a la main, jamais les deux — et `architect` et
  # `starfleet`, qui ont un draft, sont precisement les deux premiers concernes. Y recopier le
  # paragraphe en ferait deux exemplaires de prose, et deux prose divergent en restant plausibles.
  #
  # Elle passe donc par l'ENVELOPPE : `sp_template.eex` rend `@modop_fragments` pour tout pod, quelle
  # que soit l'origine de son SP. Le bundle est la source unique ; chaque carte le NOMME.
  #
  # ⚠ CE CHECK EXISTE PARCE QU'UN NOM MANQUANT EST SILENCIEUX. Un role dont la carte oublie la ligne
  # ne recoit rien, et rien ne le dit — meme classe de panne que la prose qui derive, en plus discret.
  # Un drapeau peut manquer, une prose peut mentir : l'un se detecte, l'autre non. C'est tout ce que
  # ce mur achete, et ca suffit a rendre la voie bundle superieure a la voie bloc.
  #
  # ⚠ ET IL PORTE SUR `default`, PAS SUR LA PRESENCE. Le piege est deja mesure dans ce depot :
  # `architect.yaml` ecrit que « aucun appelant de production n'active un bundle `optional` »
  # (`CapProfile.resolve/4` est toujours appele a deux arguments), donc les bundles ranges la sont
  # livres et jamais composes. Un role qui declarerait celui-ci en `optional` passerait un controle
  # naif en ne recevant rien. Le second volet lit `incompatible:` pour la meme raison : l'y nommer
  # retirerait legalement le bundle a un role, et ce n'est pas un mode commutable — il n'existe
  # aucune conduite ou ecrire a un agent en le prenant pour un executant serait juste.
  #
  # Les `ReservedSeat` sont hors perimetre : un siege n'a pas de `spec`, donc pas de SP a garnir.
  @adresser_bundle "adresser-un-agent"
  @doc false
  @spec check_sp_adresser_un_agent(String.t()) :: Support.result()
  def check_sp_adresser_un_agent(root) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    profiles =
      root
      |> Catalogue.scan_catalogue_roles()
      |> Enum.filter(&(&1.kind == "CapabilityProfile"))

    missing =
      profiles
      |> Enum.reject(&(@adresser_bundle in &1.modop_default))
      |> Enum.map(& &1.name)
      |> Enum.sort()

    # `incompatible` est une liste de PAIRES : le bundle ne doit apparaitre dans aucune.
    #
    # ⚠ ET ON ACCEPTE AUSSI L'ENTREE PLATE, QUI EST UNE MALFORMATION. `incompatible:
    # [adresser-un-agent]` (des chaines au lieu de paires) faisait echouer le `is_list(pair)` :
    # chaque element etait une chaine, aucun n'etait signale, et le mur passait au VERT sur un
    # profil qui retire pourtant le bundle. Le schema doit refuser cette forme en amont — mais un
    # mur qui ne tient que si un AUTRE controle a fait son travail ne tient rien par lui-meme, et
    # c'est precisement la classe de faux-vert que ce fichier existe pour interdire. (Revue
    # 2026-08-20.)
    excluded =
      profiles
      |> Enum.filter(fn p ->
        Enum.any?(p.modop_incompatible, fn entry ->
          (is_list(entry) and @adresser_bundle in entry) or entry == @adresser_bundle
        end)
      end)
      |> Enum.map(& &1.name)
      |> Enum.sort()

    bundle =
      Path.join(
        root,
        "priv/catalogue-system/cap_profile/canon/modop-bundles/#{@adresser_bundle}/sp.md"
      )

    cond do
      not File.regular?(bundle) ->
        %{
          id: "sp.adresser_un_agent",
          status: :fail,
          remediation:
            "le bundle #{@adresser_bundle} est nomme par les cartes et sa prose est ABSENTE — " <>
              "les pods recevraient un nom qui ne compose rien",
          evidence: ["source introuvable : #{Path.relative_to(bundle, root)}"],
          note: "la source unique de prose du bundle"
        }

      measured_nothing?(profiles) ->
        broken_result("sp.adresser_un_agent", "CapabilityProfile in the catalogues")

      true ->
        %{
          id: "sp.adresser_un_agent",
          status: if(missing == [] and excluded == [], do: :pass, else: :fail),
          remediation:
            "ajouter `#{@adresser_bundle}` a `spec.modop_set.default` de la carte (jamais " <>
              "`optional` : aucun appelant de production ne l'activerait ; jamais dans un " <>
              "`incompatible:` : ce n'est pas un mode commutable)",
          evidence:
            Enum.map(missing, &"#{&1} : absent de modop_set.default") ++
              Enum.map(excluded, &"#{&1} : nomme dans un incompatible: — retire au role"),
          note:
            "une seule source de prose (le bundle), un nom par carte, ce mur contre le nom " <>
              "manquant (#{length(profiles)} profil(s) mesure(s) ; les ReservedSeat sont hors perimetre)"
        }
    end
  end

  @doc false
  @spec check_roles_role_index_unique(String.t()) :: Support.result()
  def check_roles_role_index_unique(root) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)

    indexed =
      Catalogue.scan_catalogue_roles(root)
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
  @spec check_no_legacy_config_namespace(String.t()) :: Support.result()
  def check_no_legacy_config_namespace(root) do
    scanned =
      ["lib", "test", "config"]
      |> Enum.flat_map(fn d -> Path.wildcard(Path.join([root, d, "**", "*.{ex,exs}"])) end)
      # meme correction qu'aux scans globaux : sur le chemin RELATIF, sinon un depot pose sous
      # un dossier `tmp` ou `_build` voit son corpus entier rejete (cf. le motif en tete de
      # `check_platform_root_single_source`).
      |> Enum.reject(&("/" <> Path.relative_to(&1, root) =~ ~r{/(_build|tmp)/}))

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
  @spec check_sanctuary_contained(String.t()) :: Support.result()
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
  @spec check_sourcers_set_strict(String.t()) :: Support.result()
  def check_sourcers_set_strict(root) do
    # `root` IS fleet (project_root/0) — the sibling trees hang off `..`, exactly as the
    # four-list check resolves them. Getting this wrong makes the check silently SKIP instead of
    # run, which is the worst of the three outcomes: a green that checked nothing.
    # ⚠ LE PERIMETRE SE DISAIT SUR `deploy/` SEUL, POUR UNE POPULATION QUI VIT SOUS DEUX RACINES.
    # Le commentaire du calcul plus bas nommait deja l'asymetrie — « these are TWO roots, only one
    # of them is scoped » — et l'a portee au garde de POPULATION sans la porter au garde de
    # PERIMETRE. Consequence mesuree le 2026-08-27 : `etc/` porte DEUX sourcers
    # (`enroll-catalogue.sh`, `provision-role-tokens.sh`) et l'image LES EMBARQUE (`COPY fleet/etc`,
    # et le stage `build` n'exclut que `deploy`, `git-hooks`, `system-prompt`). Dans l'artefact, ce
    # check declarait « NOT CHECKED » sur deux fichiers qu'il tenait dans la main.
    #
    # Meme geste que `toolchain.branch_single_source` le meme jour : le perimetre se dit PAR RACINE,
    # on mesure ce qui est la, et on NOMME ce qu'on ne voit pas.
    roots = [
      {"deploy/modules.d", Path.join(Path.expand("deploy", root), "modules.d")},
      {"etc", Path.join(root, "etc")}
    ]

    {present, skipped} = Enum.split_with(roots, fn {_label, d} -> File.dir?(d) end)
    skipped_labels = Enum.map(skipped, &elem(&1, 0))

    case present do
      [] ->
        %{
          id: "shell.sourcers_set_strict",
          remediation: "—",
          status: :pass,
          evidence: [],
          note:
            "NOT CHECKED here — no sourcer root present in this artifact (runtime-only context): " <>
              Enum.join(skipped_labels, ", ")
        }

      _ ->
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
          present
          |> Enum.flat_map(fn {_label, d} -> Path.wildcard(Path.join(d, "*.sh")) end)

        if measured_nothing?(sourcers) do
          broken_result("shell.sourcers_set_strict", "sourcer scripts")
        else
          do_check_sourcers(sourcers, root, skipped_labels)
        end
    end
  end

  defp do_check_sourcers(sourcers, root, skipped_labels) do
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
          "(BL-6-36: bash's silent-coercion class)" <> skipped_note(skipped_labels)
    }
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
  @spec check_face_roots_provisioned(String.t()) :: Support.result()
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
      case Fleet.Roster.tfvars(catalogue) do
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
  @spec check_catalogue_paths_locked(String.t()) :: Support.result()
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
  @spec check_public_functions_documented(String.t()) :: Support.result()
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
