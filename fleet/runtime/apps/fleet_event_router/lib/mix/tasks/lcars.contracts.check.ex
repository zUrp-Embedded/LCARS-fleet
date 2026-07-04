defmodule Mix.Tasks.Lcars.Contracts.Check do
  @shortdoc "Vérifie les contrats inter-module au load (refuse le build si un contrat est rouvert)"

  @moduledoc """
  Runtime Contract Checker — valide les contrats inter-module AVANT
  exécution, et transforme chaque trou en refus explicite (exit≠0)
  plutôt qu'en timeout/bug silencieux runtime.

  Chaque check garde une classe de dérive déjà rencontrée : ROUGE tant que le
  fix n'est pas landé, VERT quand il l'est. Câblé en garde-fou permanent
  (`contracts.check` exit 0 au boot/CI fail-loud, et `mix release` refuse de
  bâtir si un check est rouge), il promeut chaque invariant d'une clôture
  documentaire à une clôture mécanique : un agent qui re-dérive casse le build.

  ## Usage

      mix lcars.contracts.check          # rapport YAML + exit 0/1
      mix lcars.contracts.check --quiet  # exit code seulement

  ## Sortie

  YAML `status + checks[] + evidence (file:line)`. `status: fail` si au
  moins un check `fail`. Les checks `pending` (pas encore implémentés) sont
  listés explicitement — aucun cap silencieux : un trou non encore couvert
  est visible, pas masqué en "pass".
  """

  use Mix.Task

  @recursive false

  # Chaque check : %{id, remediation, status: :pass|:fail|:pending, evidence: [..], note}
  # Les checks IMPLÉMENTÉS sont fondés sur le code réel (grep/introspection).
  # Les PENDING nommeraient la remédiation qui les rendrait exécutables.
  # Tous les checks sont implémentés : `@pending_checks` est vide.
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
  Exécute tous les checks et rend `{overall, checks}` SANS imprimer ni `exit`.

  Forme réutilisable de la logique de check : appelée par `run/1` (CLI : print +
  exit) ET par le step de `mix release` (`mix.exs` `verrou_contracts/1` : refuse de
  bâtir la release si rouge). Les sources étant présentes au build (release bâtie
  depuis le projet), les checks grep/introspection tournent ; un check rouge →
  release refusée = la réalisation mécanique de « le boot refuse de monter si un
  contrat a été rouvert » (rendre l'état interdit impossible en amont, pas le rattraper).

  Suppose le code déjà compilé (le caller compile : `run/1` via `Mix.Task.run`,
  le step release après la phase compile).
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
        # ── Rails de remédiation 2026-06-09 (STEP 0) ──
        check_result_deadline_cancelled(root),
        check_spawn_gates_wired(root),
        check_gatekeeper_not_a_step(root),
        check_verdict_envelope_unwrapped(root),
        check_no_root_runtime_guard(root),
        # ── Verrou de topologie (D4/A2, 2026-07-04) ──
        check_layering_dependency_graph(root)
        # NB il n'y a pas de rail `pipeline.bounded_retry_system_side` : il vérifiait le retry borné
        # système-side de l'`Executor` RAM, qui n'existe plus. L'équivalent côté rail forge = le
        # `max_rework_rounds` (StepRunConsumer) ; à re-contractualiser si besoin (backlog).
      ] ++ Enum.map(@pending_checks, &Map.put(&1, :status, :pending))

    overall = if Enum.any?(checks, &(&1.status == :fail)), do: :fail, else: :pass

    {overall, checks}
  end

  # ── Checks implémentés ───────────────────────────────────────────────

  # Les consommateurs d'events doivent matcher `%Fleet.Event{}`, jamais le tuple
  # legacy `{atom, %{"event_type" => ...}}` — un consommateur resté sur le tuple est
  # mort sur la struct canon (il ne matche plus rien) et le drift est silencieux.
  # Ce check mesure le CODE réel des cibles ci-dessous et flague toute lecture
  # `"event_type" =>` qui subsiste.
  # 9e instance de la famille B (residue_check), migrée à la factorisation D5. Le `confirm` = le
  # pattern lui-même post-strip : une mention `"event_type" =>` en COMMENTAIRE (doc du retrait du
  # tuple legacy) ne compte pas comme violation (sinon le gate flague sa propre documentation).
  # NB `executor.ex`/`task_monitor.ex` ne sont plus des cibles (rails/apps supprimés).
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

  # Le Loader doit normaliser v1/v2.5 vers une forme interne unique (déballer
  # spec.steps). Sans ça un consommateur lit `pipeline["steps"]=nil` sur du v2.5.
  defp check_pipeline_v25_normalized(root) do
    rel = "apps/fleet_workflow/lib/fleet/workflow/loader.ex"
    loader = Path.join(root, rel)

    # Anti-vert-creux : matcher `~r/normalize|déball/i` sur TOUT le source rendrait le rail vert dès qu'un
    # simple COMMENTAIRE contient « normalize », même sans le code. On matche donc la CLAUSE DE CODE réelle
    # qui déballe `spec.steps` (la normalisation v2.5) ET son appel, en STRIPPANT le commentaire de chaque
    # ligne (un `# defp normalize(...)` commenté ne compte pas).
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

  # Tout handler référencé dans events.yaml doit exister, sinon la route est un
  # handler fantôme toléré silencieusement.
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

  # Invariant : la gate LLM (soft + terminal non-tranchable) est jugée par le
  # **gatekeeper** côté pipeline ; `coord` ne porte aucun spawn de gate, et le
  # placeholder `NotWiredYet` (qui rendrait les soft gates silencieusement KO) ne
  # doit pas réapparaître dans le gate-path coord. On vérifie donc le code RÉEL,
  # sans se fier à un commentaire :
  # (a) aucun `HookSpawner.NotWiredYet` résiduel dans le lib coord, (b) `Gates`
  # est pur — aucune délégation `coord_backend()`/`CoordBackend` (la couture
  # morte ne doit pas revenir).
  defp check_coord_backend_wired(root) do
    # `soft_gate.ex` n'existe pas (gates consolidées sur le gatekeeper). Comme
    # `grep_lines/2` rend `[]` sur un fichier absent, grepper un fichier mort
    # passerait TOUJOURS vide = vert-creux (la classe d'échec que ce checker existe
    # pour prévenir). On grep donc TOUT le lib coord (glob de fichiers RÉELS, pas un
    # fichier mort) pour le placeholder `NotWiredYet` qui ne doit pas réapparaître
    # dans le gate-path coord.
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

  # `compose_claude_md/3` doit lire `spec.invocation.lifetime_scope` (le schéma v2.5
  # canon), pas `spec.lifetime_scope` (forme pré-v2.5) — sinon le CLAUDE.md du pod
  # affiche toujours "unknown". Le jumeau `check_lifetime_scope/1` (cap_profile.ex)
  # lit déjà le bon chemin.
  # Le pattern couvre get_in (forme liste `spec, ["lifetime_scope"]`) ET Map.get
  # (forme string `spec, "lifetime_scope"`) — futur-proof contre une régression qui
  # réintroduirait le mauvais chemin sous une autre forme.
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

  # `check_modop_incompatible/1` doit lire `spec.modop_set.incompatible` (schéma
  # v2.5) + comparer aux modops actifs (`default` ++ `optional`), pas
  # `spec.modop_incompatible` (clé inexistante) ni `spec.modop_set` traité comme
  # une liste → sinon l'invariant ne tire jamais. Confirmation post-strip plus
  # lâche que le grep : toute mention CODE de `modop_incompatible` sur une ligne
  # `Map.get(spec, …)` compte, même reformatée.
  defp check_capprofile_modop_incompatible_path(root) do
    residue_check(root, %{
      id: "capprofile.modop_incompatible_path",
      remediation: "R13",
      # La fonction gardée (check_modop_incompatible) a été EXTRAITE vers invariants.ex — le rail
      # surveille les DEUX (le mauvais chemin peut revenir dans l'un ou l'autre).
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

  # `TmuxBackend` (claude --remote-control HORS bwrap, dont le control-path est cassé) n'existe pas.
  # Ce check garde cette suppression : rouge s'il réapparaît OU si runtime.exs re-référence TmuxBackend.
  # NB il ne s'agit PAS d'interdire tout host-launch — `containment: none` est servi par
  # `bin/host_launch.sh` (le mécanisme tmux-holder PROUVÉ de bwrap_launch, sélectionné par `do_launch`
  # via `launcher_path`), pas par le remote-control nu de l'ex-TmuxBackend. Le rail interdit la
  # résurrection du MÉCANISME cassé, pas la voie host.
  # NB le versant runtime.exs matche le source BRUT (pas de strip_comment) :
  # même une mention en commentaire de TmuxBackend dans la config runtime est
  # un signal de résurrection à flaguer.
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

  # Un backend RÉEL sans `mcp_server_spec` doit être refusé (fail-loud) — un pod réel
  # parle MCP, sans MCP il part cassé (timeout silencieux). Le provisioning MCP a été
  # extrait de pod.ex vers son propre module ; ce check garde la garde à DEUX niveaux,
  # les deux requis (sinon fail) :
  #   niveau 1 (câblage) — pod.ex APPELLE `McpProvision.maybe_provision_mcp_config(` dans
  #     sa with-chain de provisioning (sans cet appel, la garde, fût-elle présente dans
  #     le module dédié, ne tournerait jamais sur le chemin de spawn) ;
  #   niveau 2 (garde réelle) — `mcp_provision.ex` porte le fail-loud, marqueur l'erreur
  #     `:mcp_server_spec_required` dans le TUPLE de retour `{:error, {:mcp_server_spec_required, …}}`.
  # Rouge si l'un des deux manque ; évidence claire pointant le fichier fautif.
  #
  # ⚠ Anti-vert-creux durci (niveau 2) : le moduledoc de `mcp_provision.ex` DOCUMENTE le même
  # tuple `{:error, {:mcp_server_spec_required, backend}}` (en inline-code). Grepper l'atome nu
  # laisserait le check VERT même si la clause de code réelle était retirée (la doc gardant le
  # token présent) — exactement le vert-creux que ce checker existe pour bloquer. On exige donc
  # le token dans une LIGNE DE CODE qui EST le tuple d'erreur (`^\s*{:error,` après strip_comment) ;
  # la ligne de doc (prose préfixée d'un backtick, pas `{:error,`) ne compte pas. Débrancher la
  # clause réelle re-ROUGIT, quoi que dise la doc.
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
        # Confirmation CONJONCTIVE (les 2 regex sur la ligne strippée) : le token
        # doit vivre sur une ligne qui EST le tuple d'erreur — cf. anti-vert-creux
        # durci ci-dessus (le moduledoc porte le même token en prose).
        {code_match?(root, mcp, ~r/:mcp_server_spec_required/, [
           ~r/:mcp_server_spec_required/,
           ~r/^\s*\{:error,/
         ]), "#{mcp} : pas de fail-loud :mcp_server_spec_required (garde réelle absente)"}
      ]
    )
  end

  # `Fleet.Spawner.spawn_pod/3` doit refuser un pod `one-shot` sans brief (sinon
  # le pod part sans travail → timeout). Marqueur du guard : l'erreur
  # `:brief_required`. Rouge si absente (retour au brief générique muet).
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

  # `Fleet.SPBuilder.filter_skills/2` doit échouer (fail-loud) si un skill PLAIN
  # whitelisté est absent du disque — sinon un filtrage silencieux laisserait un pod
  # réclamer un skill inexistant. Marqueur : `:skills_missing`.
  # Rouge si absent.
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

  # La clé events.yaml EST le `type` de l'event (le `source` est un champ séparé,
  # validé par `Fleet.Event.canonical_sources/0`) ; le registry est keyé par type, il
  # n'y a pas de table de dispatch keyée autrement. Invariant gardé ici : tout type
  # **consommé** (`handle_info(%Fleet.Event{type: :X})`, exemples moduledoc inclus)
  # doit être une clé du registry — sinon le consommateur est mort (il attend un type
  # qui ne peut être broadcast sans `UnregisteredError`). Les émetteurs, eux, sont
  # couverts par la validation fail-loud du broadcast au runtime (un type non-registré
  # crashe son émetteur), donc ce check ne couvre que le versant consommation.
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

  # `[^}]*?` autorise des champs AVANT `type:` (ex. `%Fleet.Event{source: :X,
  # type: :Y}`) et traverse les structs multi-lignes (négation de `}` matche les
  # newlines) → capture les consommateurs type-first ET source-first.
  # Limite connue : les consommateurs `%Fleet.Event{}` génériques + `case type do`
  # (pas de type literal dans le struct) ne sont pas couverts.
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

  # ── Rails de remédiation ─────────────────────────────────────────────
  # Ces rails promeuvent des invariants d'une clôture documentaire à une clôture
  # par contrainte : un invariant qu'on a déjà violé faute de check devient ici un
  # check exécutable. Un agent qui re-dérive → `mix release` REFUSE
  # (verrou_contracts), build rouge, fix immédiat.

  # Le timer `:result_deadline` doit être ANNULÉ à l'arrivée du résultat (sinon il
  # tue au cycle 2 les pods long-lived forever/pipe/run). Depuis la migration `Pod` →
  # `gen_statem`, l'annulation n'est plus une impl maison (`Process.cancel_timer`) mais
  # NATIVE : `:result_deadline` est un **state_timeout de l'état `:monitoring`**, et la
  # transition `:monitoring → :extracting` (déclenchée par l'arrivée du résultat,
  # `work_item.completed`) annule AUTOMATIQUEMENT ce state_timeout (un state_timeout est
  # cancellé au changement d'état). Ce check vérifie donc les DEUX piliers de cet
  # invariant natif dans pod.ex :
  #   (a) `:result_deadline` est bien armé/géré comme un `:state_timeout` (sinon il ne
  #       s'annulerait pas tout seul au changement d'état) ;
  #   (b) la transition annulante `{:next_state, :extracting, …}` existe (sinon le résultat
  #       arriverait sans jamais quitter `:monitoring` → deadline non annulé → kill cycle 2).
  # Rouge si l'un manque, OU si le band-aid `"forever" -> 60_000` (un HACK) réapparaît.
  defp check_result_deadline_cancelled(root) do
    pod = "apps/fleet_spawner/lib/fleet/spawner/pod.ex"
    src = File.read!(Path.join(root, pod))

    # (a) :result_deadline géré comme state_timeout (une ligne de CODE porte les deux tokens :
    #     l'armement `{:state_timeout, _, :result_deadline}` ET le handler `:state_timeout, :result_deadline`).
    state_timeout? =
      Path.join(root, pod)
      |> grep_lines(~r/:state_timeout.*:result_deadline|:result_deadline.*:state_timeout/)
      |> Enum.any?(fn {_l, line} ->
        stripped = strip_comment(line)

        Regex.match?(~r/:state_timeout/, stripped) and
          Regex.match?(~r/:result_deadline/, stripped)
      end)

    # (b) la transition annulante :monitoring → :extracting (annule nativement le state_timeout).
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

  # Les portes du spawn-boundary doivent être câblées sur le chemin de spawn réel,
  # PAS test-only, sinon ce sont des portes de containment/credentials CREUSES (appelées
  # en test mais jamais en prod — le mode de défaillance « hollow-gate » que ce checker
  # existe pour bloquer). La porte containment reste directe dans pod.ex ; les portes
  # scope+plan ont été regroupées derrière une porte credentials dédiée (Fleet.Credentials.Gate),
  # câblée au spawn. Ce check vérifie DEUX niveaux, 4 vérifs (toutes requises) :
  #   niveau 1 — câblage dans pod.ex sur le chemin de spawn réel :
  #     (1) CapProfile.validate — porte de containment (refus des server-tools natifs), à do_allocate ;
  #     (2) Fleet.Credentials.Gate.validate — la porte credentials (scope+plan) appelée à do_launch ;
  #   niveau 2 — la porte credentials délègue RÉELLEMENT (pas une coquille vide) dans gate.ex :
  #     (3) ScopeValidator.validate — couverture des scopes OAuth par-rôle ;
  #     (4) PlanValidator.validate — abonnement payant.
  # Rouge si l'une manque. Une porte qui ne tourne qu'en test, ou une porte câblée mais
  # qui ne délègue rien, ne garde rien en prod.
  defp check_spawn_gates_wired(root) do
    pod = "apps/fleet_spawner/lib/fleet/spawner/pod.ex"

    # La construction env + la porte credentials vivent dans Pod.LaunchEnv (le cluster env/creds extrait
    # de do_launch). do_launch (pod.ex) appelle LaunchEnv.build, qui câble Gate.validate. La porte est
    # donc câblée au spawn par DEUX faits conjoints : pod.ex appelle LaunchEnv.build ET LaunchEnv.build
    # contient Gate.validate (plus fort que l'ancienne vérif mono-fichier où tout était inline dans pod.ex).
    launch_env = "apps/fleet_spawner/lib/fleet/spawner/pod/launch_env.ex"
    gate = "apps/fleet_credentials/lib/fleet/credentials/gate.ex"

    # Chaque vérif = {fichier_relatif, regex, label}. Le label nomme le fichier attendu.
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

  # Le gatekeeper est un juge d'EXCEPTION-inférence (dispatché par une gate
  # :soft/:nontranchable), JAMAIS un step d'ordonnancement. Rouge si une workflow_map
  # déclare un step `role: gatekeeper` — méta-axiome : un raisonneur LLM dans la
  # mécanique de coordination est un signal de design défaillant.
  # NB les parenthèses externes autour de `(… || [])` sont load-bearing : sans elles
  # `|>` (précédence > `||`) appliquerait flat_map à `[]`, pas à la liste de
  # workflow_maps (`(true && l) || [] |> map` ⇒ `l`, map sauté).
  defp check_gatekeeper_not_a_step(root) do
    dir = "apps/fleet_workflow/priv/canon/workflow_maps"
    abs = Path.join(root, dir)

    evidence =
      ((File.dir?(abs) && Path.wildcard(Path.join(abs, "*.yaml"))) || [])
      |> Enum.flat_map(fn path ->
        rel = Path.relative_to(path, root)

        # `\brole:` (ancre gauche) — ne vise QUE les steps `role: gatekeeper`,
        # PAS `target_role: gatekeeper` (escalade légitime, ex. standard-qa
        # `on_escalation.target_role` : le gatekeeper EST la cible d'exception, pas un
        # step). Sans l'ancre, `target_role:` contient `role:` → faux-positif.
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

  # StepRunConsumer doit déplier l'enveloppe worker `%{status, result}` avant de lire la
  # décision (resume_gate/gate_result) OU d'évaluer la gate (gate_decide) — sinon
  # decision/outputs restent enfouis → fausse escalade / hard-gate à tort.
  defp check_verdict_envelope_unwrapped(root) do
    step_run = "apps/fleet_pilot/lib/fleet/pilot/step_run_consumer.ex"
    abs = Path.join(root, step_run)

    # Anti-vert-creux : un `not File.exists?(abs) or …` rendrait le rail VERT si `step_run_consumer.ex` était
    # SUPPRIMÉ (l'invariant verdict-route disparu mais pass quand même). Le verdict-route EST le
    # step_run_consumer : son absence est elle-même un défaut → on EXIGE le fichier ET le déballage
    # (strip_comment : un `# unwrap_worker_envelope` commenté ne compte pas). Déplacer l'unwrap ailleurs
    # = changement de design qui DOIT mettre à jour ce rail (ce que ce fail-on-absence force).
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

  # Vérifie que le self-check anti-root existe dans le boot path
  # (config/runtime.exs). Rouge s'il disparaît. Le boot guard runtime vit dans
  # runtime.exs (bloc :prod) ; ce check garde sa présence. Confirmation post-strip
  # plus lâche que le grep (`root` seul) : le marqueur long peut vivre en partie
  # dans un commentaire de la ligne, seul `root` doit survivre dans le code.
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

  # ── Combinators (3 familles de checks data-driven) ───────────────────
  # 8 des 17 checks sont des instanciations pures de 3 familles ; chaque check
  # migré n'est plus qu'un appel qui porte ses DONNÉES (id, fichiers, patterns,
  # messages). Les messages d'évidence sont passés tels quels au combinator :
  # aucune perte de précision vs les versions dépliées qu'ils remplacent.

  # Une ligne de CODE de `rel` matche-t-elle `pattern` ? Grep brut, puis
  # confirmation sur la ligne strippée de son commentaire (une mention en
  # commentaire ne compte pas — anti-vert-creux, cf. strip_comment/1).
  # `confirm` : regex OU liste de regex qui doivent TOUTES matcher la ligne
  # strippée, quand la confirmation diffère du grep (ex. exiger que le token
  # vive sur la ligne du tuple `{:error, …}`) ; défaut = `pattern` lui-même.
  defp code_match?(root, rel, pattern, confirm \\ nil) do
    confirms = if confirm, do: List.wrap(confirm), else: [pattern]

    Path.join(root, rel)
    |> grep_lines(pattern)
    |> Enum.any?(fn {_ln, line} ->
      stripped = strip_comment(line)
      Enum.all?(confirms, &Regex.match?(&1, stripped))
    end)
  end

  # Famille A — présence-de-marqueur : `file` doit porter `pattern` dans du code
  # (confirmé hors commentaire, `confirm` optionnel cf. code_match?/4) ;
  # présent = pass, absent = fail avec `"<file> : <missing>"` en évidence.
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

  # Famille B — absence-de-résidu : 0 hit de `pattern` (confirmé hors commentaire
  # par `confirm`, défaut `pattern`) dans `files` = pass ; chaque hit résiduel =
  # une évidence `fichier:ligne`. ⚠ hérite du piège vert-creux de `grep_lines/2`
  # (fichier absent = 0 hit = pass) : ne lister ici que des fichiers vivants dont
  # l'existence est gardée par ailleurs — pour un résidu sur fichier potentiellement
  # mort, grepper un glob (cf. check_coord_backend_wired).
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

  # Famille C — evidence-list : `items` = [{ok?, message}], conditions évaluées au
  # call site (grep, File.exists?, …). Toutes vraies = pass ; chaque condition
  # fausse verse son message (précis, pré-composé) en évidence.
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

  # Retire le commentaire `#...` de fin de ligne, hors chaîne double-quote
  # (les `#` à l'intérieur d'un "..." sont du code, ex. interpolation `#{}`).
  # Heuristique suffisante pour mesurer le code vs une mention en commentaire.
  # Limite connue : le char literal `?#` est tronqué (non géré) — non exploitable
  # sur les cibles fixes (aucun `?#`), une forme tuple `{?#, …}` étant absurde.
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

  # ⚠ PIÈGE VERT-CREUX : sur un fichier ABSENT, `grep_lines` rend `[]`
  # — indistinguable de « présent mais 0 match ». Un check « pas de résidu X dans
  # le fichier Y » qui statue `pass` sur `evidence == []` passe donc TOUJOURS si Y
  # a été supprimé. Pour un check de RÉSIDU, grep un glob de fichiers réels
  # (`Path.wildcard`), pas un chemin de fichier unique potentiellement mort.
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

  # ── Verrou de topologie (D4/A2) ──────────────────────────────────────────────
  # `priv/allowed_graph.yaml` fige le graphe de deps REEL. Trois versants, tous fail-closed :
  #   (a) mix.exs BIDIRECTIONNEL : arete compile reelle non declaree = fail ; arete declaree fantome = fail.
  #   (d) monotonicite RING : une dep compile MONTANTE (ring inf -> sup) non-seam = fail (le PubSub via
  #       event_router R0 est exempt par construction — il n'est pas une dep de couche).
  #   (b) seams VIVANTS : chaque seam declare porte un `marker` qui DOIT matcher du code de l'app `from` ;
  #       s'il n'y matche plus, le seam est mort (le code a bouge) et le yaml est stale -> fail.
  # Encode le graphe ACTUEL -> nait VERT ; tout ajout/retrait de dep le fait rougir tant que le yaml n'est
  # pas re-declare (force la conscience d'un changement de topologie). yaml illisible -> fail-closed.
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

  # Aretes compile reelles extraites des mix.exs (`{:fleet_x, in_umbrella: true}`), comment strippe (une
  # dep en commentaire ne compte pas). Rend un set de tuples `{from_app, to_app}`.
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

  # Un seam est VIVANT si son `marker` (regex) matche une ligne de code (comment strippe) de l'app `from`.
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
