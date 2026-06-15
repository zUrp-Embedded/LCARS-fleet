defmodule Mix.Tasks.Lcars.Contracts.Check do
  @shortdoc "Vérifie les contrats inter-module au load (jumeau runtime du gate §11-PATH)"

  @moduledoc """
  Runtime Contract Checker (P01) — valide les contrats inter-module
  AVANT exécution, et transforme chaque trou en refus explicite (exit≠0)
  plutôt qu'en timeout/bug silencieux runtime.

  C'est la **forme exécutable** de la worklist de remédiation REMED-RUNTIME-1
  (cf. `PLAN-REMEDIATION-runtime-2026-06-04.md`) : chaque check = une classe
  de dérive ; ROUGE tant que le fix n'est pas landé, VERT quand il l'est.
  Au verrou R7, `contracts.check` exit 0 devient le garde-fou permanent
  (boot/CI fail-loud) — le jumeau runtime du gate `§11-PATH` doctrine.

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
  # Les checks IMPLÉMENTÉS sont grounded sur le code réel (grep/introspection).
  # Les PENDING nomment la remédiation qui les rendra exécutables (R2→R7).
  # Tous les checks de remédiation sont implémentés (8/8). @pending_checks vide.
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

  Forme réutilisable de la logique de check (R7 verrou I-CBC) : appelée par
  `run/1` (CLI : print + exit) ET par le step de `mix release`
  (`mix.exs` `verrou_contracts/1` : refuse de bâtir la release si rouge). Les
  sources étant présentes au build (release bâtie depuis le projet), les checks
  grep/introspection tournent ; un check rouge → release refusée = la
  réalisation mécanique de « le boot refuse si un contrat est rouvert ».

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
        check_spawn_has_mandate(root),
        check_skills_declared_present(root),
        check_events_registry_keys_aligned(root),
        # ── Rails de remédiation 2026-06-09 (STEP 0) ──
        check_result_deadline_cancelled(root),
        check_spawn_gates_wired(root),
        check_gatekeeper_not_a_stage(root),
        check_verdict_envelope_unwrapped(root),
        check_no_root_runtime_guard(root),
        # ── Rail F150 (retry borné système-side, 2026-06-14) ──
        check_bounded_retry_system_side(root)
      ] ++ Enum.map(@pending_checks, &Map.put(&1, :status, :pending))

    overall = if Enum.any?(checks, &(&1.status == :fail)), do: :fail, else: :pass

    {overall, checks}
  end

  # ── Checks implémentés ───────────────────────────────────────────────

  # R03/R10 (→R2) : les consommateurs d'events doivent matcher %Fleet.Event{},
  # pas le tuple legacy {atom, %{"event_type" => ...}}. Set R2 = Executor + WS
  # (R2a, fait) + TaskMonitor (R2b). Hors R2 (autres sous-lots) :
  # AutoDispatcher (Pilot→R4), MCP Bridge (channels→R6), Dispatch/AuditConsumer
  # (dual legacy retiré au verrou→R5/R7).
  defp check_event_consumers_canon(root) do
    targets = [
      "apps/fleet_pipeline/lib/fleet/pipeline/executor.ex",
      "apps/fleet_api/lib/fleet/api/ws.ex",
      "apps/fleet_task_monitor/lib/fleet/task_monitor.ex"
    ]

    pattern = ~r/"event_type"\s*=>/

    # Le check mesure le CODE réel : une mention `"event_type" =>` en
    # commentaire (ex. « le tuple legacy {atom, %{"event_type" => ...}} est
    # RETIRÉ ») ne doit PAS compter comme une violation (sinon le gate flague
    # sa propre documentation — clôture sur proxy). On retire le commentaire
    # de fin de ligne avant de re-tester (R2b).
    evidence =
      Enum.flat_map(targets, fn rel ->
        Path.join(root, rel)
        |> grep_lines(pattern)
        |> Enum.filter(fn {_ln, line} -> Regex.match?(pattern, strip_comment(line)) end)
        |> Enum.map(fn {ln, _} -> "#{rel}:#{ln}" end)
      end)

    %{
      id: "event.consumers.canon",
      remediation: "R03/R10 (R2)",
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
      note: "consommateurs encore sur le tuple legacy \"event_type\""
    }
  end

  # R01 (→R3) : le Loader doit normaliser v1/v2.5 vers une forme interne unique
  # (déballer spec.stages). Sans ça l'Executor lit pipeline["stages"]=nil sur v2.5.
  defp check_pipeline_v25_normalized(root) do
    rel = "apps/fleet_pipeline/lib/fleet/pipeline/loader.ex"
    loader = Path.join(root, rel)

    # Anti-vert-creux DURCI (F-couche3, 2026-06-14) : l'ancien rail matchait `~r/normalize|déball/i` sur
    # TOUT le source → un simple COMMENTAIRE contenant « normalize » le rendait vert même sans le code. On
    # matche désormais la CLAUSE DE CODE réelle qui déballe `spec.stages` (la normalisation v2.5) ET son
    # appel, en STRIPPANT le commentaire de chaque ligne (un `# defp normalize(...)` commenté ne compte pas).
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
              "#{rel} : clause `defp normalize(%{\"spec\" => %{\"stages\" => ...}})` (déballage v2.5) absente → Executor lit stages=nil"
            ]

          not called? ->
            ["#{rel} : `normalize(yaml)` jamais appelé au load → enveloppe v2.5 non déballée"]

          true ->
            []
        end,
      note:
        "Loader DÉBALLE spec.stages via la CLAUSE DE CODE v2.5 (`defp normalize(%{\"spec\"…})`) ET l'appelle au load — matche le code, pas un commentaire (anti-vert-creux durci)"
    }
  end

  # R08 (→R5) : tout handler référencé dans events.yaml doit exister, sinon
  # la route est un handler fantôme toléré silencieusement.
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

  # R06/R22 (→R4) : le backend de spawn coord par défaut doit être câblé,
  # pas le placeholder NotWiredYet (qui rend les soft gates silencieusement KO).
  # R06/R22 — invariant post-consolidation : la gate LLM (soft + terminal
  # non-tranchable) est jugée par le **gatekeeper** côté pipeline ; `coord` ne
  # porte plus de spawn de gate (placeholder `NotWiredYet` retiré du chemin
  # actif). On vérifie le code RÉEL : (a) aucun `HookSpawner.NotWiredYet`
  # résiduel dans le gate-path coord, (b) `Gates` est pur — aucune délégation
  # `coord_backend()`/`CoordBackend` (la couture morte ne doit pas réapparaître).
  defp check_coord_backend_wired(root) do
    # F043 fix : `soft_gate.ex` a été retiré en R06 (gates consolidées gatekeeper).
    # `grep_lines/2` rend `[]` sur un fichier absent → cette moitié `notwired`
    # passait TOUJOURS vide = vert-creux (la classe d'échec que ce checker existe
    # pour prévenir). On grep désormais TOUT le lib coord (glob de fichiers RÉELS,
    # pas un fichier mort) pour le placeholder `NotWiredYet` qui ne doit pas
    # réapparaître dans le gate-path coord.
    notwired =
      Path.wildcard(Path.join(root, "apps/fleet_coord/lib/**/*.ex"))
      |> Enum.flat_map(fn file ->
        file
        |> grep_lines(~r/NotWiredYet/)
        |> Enum.map(fn {ln, _} -> "#{Path.relative_to(file, root)}:#{ln}" end)
      end)

    gates_coord_dep =
      Path.join(root, "apps/fleet_pipeline/lib/fleet/pipeline/gates.ex")
      |> grep_lines(~r/coord_backend|CoordBackend/)
      |> Enum.filter(fn {_ln, line} ->
        Regex.match?(~r/coord_backend|CoordBackend/, strip_comment(line))
      end)
      |> Enum.map(fn {ln, _} -> "apps/fleet_pipeline/lib/fleet/pipeline/gates.ex:#{ln}" end)

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

  # R12 (→R4-pending) : `compose_claude_md/3` doit lire `spec.invocation.lifetime_scope`
  # (le schéma v2.5 + les cap-profiles canon), pas `spec.lifetime_scope` (forme
  # pré-v2.5) — sinon le CLAUDE.md du pod affiche toujours "unknown". Le jumeau
  # `check_lifetime_scope/1` (cap_profile.ex) lit déjà le bon chemin.
  defp check_capprofile_lifetime_scope_path(root) do
    sp = "apps/fleet_sp_builder/lib/fleet/sp_builder.ex"

    # Couvre get_in (forme liste `spec, ["lifetime_scope"]`) ET Map.get (forme
    # string `spec, "lifetime_scope"`) — futur-proof contre une régression qui
    # réintroduirait le mauvais chemin sous une autre forme.
    wrong = ~r/cap_profile\.spec,\s*(\["lifetime_scope"\]|"lifetime_scope")/

    evidence =
      Path.join(root, sp)
      |> grep_lines(wrong)
      |> Enum.filter(fn {_ln, line} -> Regex.match?(wrong, strip_comment(line)) end)
      |> Enum.map(fn {ln, _} -> "#{sp}:#{ln}" end)

    %{
      id: "capprofile.lifetime_scope_path",
      remediation: "R12",
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
      note:
        "compose_claude_md lit spec.lifetime_scope (pré-v2.5) au lieu de spec.invocation.lifetime_scope"
    }
  end

  # R13 (→R4-pending) : `check_modop_incompatible/1` doit lire
  # `spec.modop_set.incompatible` (schéma v2.5) + comparer aux modops actifs
  # (`default` ++ `optional`), pas `spec.modop_incompatible` (clé inexistante)
  # ni `spec.modop_set` traité comme une liste → l'invariant ne tire jamais.
  defp check_capprofile_modop_incompatible_path(root) do
    cp = "apps/fleet_cap_profile/lib/fleet/cap_profile.ex"

    evidence =
      Path.join(root, cp)
      |> grep_lines(~r/Map\.get\(spec,\s*"modop_incompatible"/)
      |> Enum.filter(fn {_ln, line} ->
        Regex.match?(~r/modop_incompatible/, strip_comment(line))
      end)
      |> Enum.map(fn {ln, _} -> "#{cp}:#{ln}" end)

    %{
      id: "capprofile.modop_incompatible_path",
      remediation: "R13",
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
      note:
        "check_modop_incompatible lit spec.modop_incompatible (inexistant) au lieu de spec.modop_set.incompatible"
    }
  end

  # R20/F103 : `TmuxBackend` (claude --remote-control HORS bwrap, control-path CASSÉ depuis la
  # convergence PodTmux) a été SUPPRIMÉ. Le check garde la SUPPRESSION du module CASSÉ : rouge s'il
  # réapparaît OU si runtime.exs re-référence TmuxBackend. NB (LAUNCH-Q) : il ne s'agit PAS d'interdire
  # tout host-launch — `containment: none` est désormais servi par `bin/host_launch.sh` (mécanisme
  # tmux-holder PROUVÉ de bwrap_launch, sélectionné par `do_launch` via `launcher_path`), pas par le
  # remote-control nu de l'ex-TmuxBackend. Le rail interdit la résurrection du MÉCANISME cassé, pas la voie host.
  defp check_launch_backend_containment(root) do
    rt = "config/runtime.exs"
    tb = "apps/fleet_spawner/lib/fleet/spawner/launch_backend/tmux_backend.ex"
    rt_src = File.read!(Path.join(root, rt))

    evidence =
      [
        {File.exists?(Path.join(root, tb)),
         "#{tb} : TmuxBackend supprimé (F103) — le module ne doit pas réapparaître"},
        {Regex.match?(~r/LaunchBackend\.TmuxBackend/, rt_src),
         "#{rt} : runtime ne doit plus référencer TmuxBackend (backend hors-bwrap supprimé)"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    %{
      id: "launch.backend_containment_coherent",
      remediation: "R20/F103",
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
      note:
        "TmuxBackend (remote-control nu, control-path cassé) supprimé ; ne doit pas réapparaître. La voie host containment:none = host_launch.sh (tmux-holder prouvé), pas TmuxBackend (LAUNCH-Q)"
    }
  end

  # R14 (→R4-pending) : `maybe_provision_mcp_config/1` doit refuser (fail-loud)
  # un backend RÉEL avec `mcp_server_spec` nil — un pod réel parle MCP, sans MCP
  # il part cassé (timeout silencieux). Marqueur du fail-loud : l'erreur
  # `:mcp_server_spec_required`. Rouge si absente (retour au `:ok` muet).
  defp check_mcp_required_real_backend(root) do
    pod = "apps/fleet_spawner/lib/fleet/spawner/pod.ex"

    present? =
      Path.join(root, pod)
      |> grep_lines(~r/:mcp_server_spec_required/)
      |> Enum.any?(fn {_ln, line} ->
        Regex.match?(~r/:mcp_server_spec_required/, strip_comment(line))
      end)

    %{
      id: "mcp.required_for_real_backend",
      remediation: "R14",
      status: if(present?, do: :pass, else: :fail),
      evidence:
        if(present?, do: [], else: ["#{pod} : pas de fail-loud :mcp_server_spec_required"]),
      note: "maybe_provision_mcp_config doit refuser un backend réel sans mcp_server_spec"
    }
  end

  # R18 (→R4-pending) : `Fleet.Spawner.spawn_pod/3` doit refuser un pod `one-shot`
  # sans mandat (sinon le pod part sans travail → timeout). Marqueur du guard :
  # l'erreur `:mandate_required`. Rouge si absente (retour au brief générique muet).
  defp check_spawn_has_mandate(root) do
    sp = "apps/fleet_spawner/lib/fleet/spawner.ex"

    present? =
      Path.join(root, sp)
      |> grep_lines(~r/:mandate_required/)
      |> Enum.any?(fn {_ln, line} -> Regex.match?(~r/:mandate_required/, strip_comment(line)) end)

    %{
      id: "spawn.has_mandate",
      remediation: "R18",
      status: if(present?, do: :pass, else: :fail),
      evidence:
        if(present?,
          do: [],
          else: ["#{sp} : pas de guard :mandate_required au boundary spawn_pod"]
        ),
      note: "spawn_pod doit refuser un pod one-shot sans mandat (hors allow_no_mandate)"
    }
  end

  # R11 (→R4-pending) : `Fleet.SPBuilder.filter_skills/2` doit échouer (fail-loud)
  # si un skill PLAIN whitelisté est absent du disque (plus de filtrage silencieux
  # qui laissait un pod réclamer un skill inexistant). Marqueur : `:skills_missing`.
  # Rouge si absent.
  defp check_skills_declared_present(root) do
    sp = "apps/fleet_sp_builder/lib/fleet/sp_builder.ex"

    present? =
      Path.join(root, sp)
      |> grep_lines(~r/:skills_missing/)
      |> Enum.any?(fn {_ln, line} -> Regex.match?(~r/:skills_missing/, strip_comment(line)) end)

    %{
      id: "skills.declared_present",
      remediation: "R11",
      status: if(present?, do: :pass, else: :fail),
      evidence:
        if(present?, do: [], else: ["#{sp} : filter_skills filtre les absents en silence"]),
      note: "filter_skills doit fail-loud {:skills_missing} sur un skill plain absent"
    }
  end

  # R09/F-08 (→R4-pending) : modèle réel post-B2 — la clé events.yaml EST le
  # `type` de l'event (le `source` est un champ séparé, validé par
  # `Fleet.Event.canonical_sources/0`). Le « rename <source>.<type> » de F-08 est
  # superseded par B2 (Dispatch retiré, registry keye par type). L'invariant qui
  # RESTE : tout type **consommé** (`handle_info(%Fleet.Event{type: :X})`, exemples
  # moduledoc inclus) doit être une clé du registry — sinon consommateur mort
  # (attend un type qui ne peut être broadcast sans UnregisteredError). Les
  # émetteurs sont couverts par la validation fail-loud B2 au runtime.
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

  # ── Rails de remédiation (STEP 0, 2026-06-09) ────────────────────────
  # Drop-ins de `RAILS-R-xx-pret-a-graver-2026-06-09.md` (audit re-analyse).
  # Promotion clôture-documentaire → clôture-contrainte des invariants que la
  # branche cowboy a traversés faute de check : un agent qui re-dérive →
  # `mix release` REFUSE (verrou_contracts), build rouge, fix immédiat.

  # R-result-deadline (SPAWN-CR1, Z1) : timer :result_deadline ANNULÉ à l'arrivée
  # du résultat (sinon tue les pods forever/pipe/run au cycle 2). Rouge si
  # (a) aucun Process.cancel_timer dans pod.ex, OU (b) le band-aid
  # `"forever" -> 60_000` (HACK) encore présent au lieu du vrai fix.
  defp check_result_deadline_cancelled(root) do
    pod = "apps/fleet_spawner/lib/fleet/spawner/pod.ex"
    src = File.read!(Path.join(root, pod))

    has_cancel? =
      Path.join(root, pod)
      |> grep_lines(~r/Process\.cancel_timer/)
      |> Enum.any?(fn {_l, line} -> Regex.match?(~r/cancel_timer/, strip_comment(line)) end)

    has_hack? = Regex.match?(~r/"forever"\s*->\s*60_?000\b/, src)

    evidence =
      [
        {not has_cancel?,
         "#{pod} : aucun Process.cancel_timer — timer :result_deadline jamais annulé (SPAWN-CR1, tue les pods permanents)"},
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
        "annuler le timer à l'arrivée du résultat + n'armer que si task active ; revert le band-aid 60ks"
    }
  end

  # R-cap-validate (CAP-D1) : la porte G24 `Fleet.CapProfile.validate/1` (dont
  # F-CONT-RISK g24_9 : deny server-tools natifs) DOIT être appelée sur le chemin
  # de spawn (boundary do_allocate), pas seulement par les tests. Rouge si pod.ex
  # ne l'appelle pas → porte de containment creuse (CAP-D1). NB Z2 : ce rail sera
  # ÉTENDU en R-spawn-gates (3 callsites : validate + ScopeValidator + PlanValidator)
  # au câblage du cluster de gates — cf. SYNTHESE §Z2.
  # R-spawn-gates (Z2, ex-R-cap-validate étendu) : les 3 portes du spawn-boundary
  # doivent être câblées dans pod.ex, pas test-only — (1) CapProfile.validate (G24 /
  # F-CONT-RISK deny server-tools, do_allocate), (2) ScopeValidator.validate (couverture
  # de scopes OAuth par-rôle), (3) PlanValidator.validate (abonnement payant). Rouge si
  # l'une manque → porte de containment/credentials creuse (CAP-D1 / CRED-D1).
  defp check_spawn_gates_wired(root) do
    pod = "apps/fleet_spawner/lib/fleet/spawner/pod.ex"
    abs = Path.join(root, pod)

    gates = [
      {~r/CapProfile\.validate\(/, "CapProfile.validate (G24/F-CONT-RISK)"},
      {~r/ScopeValidator\.validate\(/, "ScopeValidator.validate (scope-coverage)"},
      {~r/PlanValidator\.validate\(/, "PlanValidator.validate (plan payant)"}
    ]

    evidence =
      gates
      |> Enum.reject(fn {re, _label} ->
        abs
        |> grep_lines(re)
        |> Enum.any?(fn {_ln, line} -> Regex.match?(re, strip_comment(line)) end)
      end)
      |> Enum.map(fn {_re, label} -> "#{pod} : #{label} non câblée au spawn (porte creuse)" end)

    %{
      id: "spawn.gates_wired",
      remediation: "R-spawn-gates",
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
      note:
        "les 3 portes spawn (cap.validate G24 + scope + plan) câblées dans pod.ex (do_allocate + do_launch), pas test-only"
    }
  end

  # R-gatekeeper-exception (GATE-D1) : le gatekeeper est un juge d'EXCEPTION-
  # inférence (dispatché par une gate :soft/:nontranchable), JAMAIS un stage
  # d'ordonnancement. Rouge si une carte déclare un stage `role: gatekeeper`
  # (méta-axiome §L441 : raisonneur dans la mécanique = design défaillant).
  # NB transcription : parenthèses externes autour de `(… || [])` — sans elles
  # `|>` (précédence > `||`) appliquerait flat_map à `[]`, pas à la liste de
  # cartes (testé : `(true && l) || [] |> map` ⇒ `l`, map sauté). Drop-in corrigé.
  defp check_gatekeeper_not_a_stage(root) do
    dir = "apps/fleet_pipeline/priv/canon/pipelines"
    abs = Path.join(root, dir)

    evidence =
      ((File.dir?(abs) && Path.wildcard(Path.join(abs, "*.yaml"))) || [])
      |> Enum.flat_map(fn path ->
        rel = Path.relative_to(path, root)

        # `\brole:` (ancre gauche) — ne vise QUE les stages `role: gatekeeper`,
        # PAS `target_role: gatekeeper` (escalade légitime §L441, ex. standard-qa
        # `on_escalation.target_role` : le gatekeeper EST la cible d'exception, pas un
        # stage). Sans l'ancre, `target_role:` contient `role:` → faux-positif.
        path
        |> grep_lines(~r/\brole:\s*gatekeeper\b/)
        |> Enum.filter(fn {_ln, line} ->
          Regex.match?(~r/\brole:\s*gatekeeper\b/, strip_comment(line))
        end)
        |> Enum.map(fn {ln, _} -> "#{rel}:#{ln} (stage role: gatekeeper)" end)
      end)

    %{
      id: "gatekeeper.not_an_ordering_stage",
      remediation: "R-gatekeeper-exception",
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
      note:
        "gatekeeper = juge d'exception (dispatch sur gate non-tranchable), jamais un stage role:gatekeeper (§L441 ; GATE-D1)"
    }
  end

  # R-worker-envelope-unwrap (#11/#2, Z3) : HopConsumer doit déplier l'enveloppe worker
  # `%{status,result}` avant de lire la décision (resume_gate/gate_result, B) OU d'évaluer
  # la gate (gate_decide) — sinon decision/outputs enfouis → fausse escalade / hard-gate à tort.
  defp check_verdict_envelope_unwrapped(root) do
    hop = "apps/fleet_pilot/lib/fleet/pilot/hop_consumer.ex"
    abs = Path.join(root, hop)

    # Anti-vert-creux DURCI (F-couche3, 2026-06-14) : l'ancien `not File.exists?(abs) or …` rendait le rail
    # VERT si `hop_consumer.ex` était SUPPRIMÉ (l'invariant verdict-route disparu mais pass quand même). Le
    # verdict-route EST le hop_consumer : son absence est elle-même un défaut → on EXIGE le fichier ET le
    # déballage (strip_comment : un `# unwrap_worker_envelope` commenté ne compte pas). Déplacer l'unwrap
    # ailleurs = changement de design qui DOIT mettre à jour ce rail (ce que ce fail-on-absence force).
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
              "#{hop} : ABSENT — le verdict-route (déballage enveloppe worker) a disparu (#11) ; si déplacé, MAJ ce rail"
            ]

          not unwrap_present? ->
            ["#{hop} : verdict_route ne déplie pas l'enveloppe worker (#11)"]

          true ->
            []
        end,
      note:
        "déplier %{status,result} avant de lire decision (HopConsumer #11) ; idem avant Gates.evaluate côté Executor (#2, vérifié par test). Rail EXIGE le fichier (pas de pass-si-absent — anti-vert-creux durci)"
    }
  end

  # R-no-root-runtime (présence du guard) : vérifie que le self-check anti-root
  # existe dans le boot path (config/runtime.exs). Rouge s'il disparaît. Le boot
  # guard runtime vit dans runtime.exs (bloc :prod) ; ce check garde sa présence.
  defp check_no_root_runtime_guard(root) do
    rt = "config/runtime.exs"

    present? =
      Path.join(root, rt)
      |> grep_lines(~r/R-no-root-runtime|refuse de tourner en root/)
      |> Enum.any?(fn {_ln, line} -> Regex.match?(~r/root/, strip_comment(line)) end)

    %{
      id: "runtime.no_root_boot_guard",
      remediation: "R-no-root-runtime",
      status: if(present?, do: :pass, else: :fail),
      evidence:
        if(present?, do: [], else: ["#{rt} : pas de self-check anti-root au boot (FORGE-D1)"]),
      note:
        "le daemon doit refuser getuid()==0 au boot (boot guard) ; User=lcars systemd seul ne couvre pas un run dev/manuel en root"
    }
  end

  # F150 : le retry de stage après un FAIL hard-gate doit être (a) BORNÉ (`stage_max_retries`, sinon
  # re-spawn en boucle — la crainte explicite de `gates.ex`) et (b) maintenu par le SYSTÈME (l'Executor,
  # via `retry_counts` dans son state), JAMAIS par le pod (un agent s'acharnerait à l'infini). Au seuil →
  # interception (diagnostic gatekeeper), pas d'abandon muet ni de loop. Rouge si l'un des marqueurs manque.
  defp check_bounded_retry_system_side(root) do
    exec = "apps/fleet_pipeline/lib/fleet/pipeline/executor.ex"
    src = File.read!(Path.join(root, exec))

    evidence =
      [
        {not Regex.match?(~r/retry_counts:/, src),
         "#{exec} : champ `retry_counts` (compteur système-side) absent du state Executor"},
        {not Regex.match?(~r/defp stage_max_retries/, src),
         "#{exec} : borne `stage_max_retries` absente — retry NON borné (re-spawn en boucle, cf. gates.ex)"},
        {not Regex.match?(~r/defp reject_stage/, src),
         "#{exec} : `reject_stage` absent — le hard-gate {:fail} ne passe plus par le retry borné système"},
        {not Regex.match?(~r/\{:fail, reason\}\s*->\s+reject_stage/, src),
         "#{exec} : la branche {:fail} ne route plus vers `reject_stage` (retry système contourné)"},
        {not Regex.match?(~r/dispatch_gatekeeper_diagnosis/, src),
         "#{exec} : pas d'interception au seuil (`dispatch_gatekeeper_diagnosis`) — abandon ou loop"},
        {not Regex.match?(~r/if n < max do/, src),
         "#{exec} : la comparaison de borne `if n < max` absente — borne potentiellement inopérante (retry non-borné)"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    %{
      id: "pipeline.bounded_retry_system_side",
      remediation: "F150",
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
      note:
        "retry de stage BORNÉ (`stage_max_retries`) + maintenu par le SYSTÈME (`Executor.retry_counts`, jamais le pod) ; au seuil → diagnostic gatekeeper (mandat→arch / autre→escalade), pas de loop infini (F150)"
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

  # ⚠ PIÈGE VERT-CREUX (cf. F043) : sur un fichier ABSENT, `grep_lines` rend `[]`
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
