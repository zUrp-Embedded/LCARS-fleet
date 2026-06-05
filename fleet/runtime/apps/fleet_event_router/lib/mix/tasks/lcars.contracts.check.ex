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
  @pending_checks [
    %{
      id: "events.registry.keys_aligned",
      remediation: "R09/F-08",
      note: "clés <source>.<type> + Dispatch keye source.type"
    },
    %{
      id: "mcp.required_for_real_backend",
      remediation: "R14",
      note: "mcp_server_spec=nil fail-loud si backend réel"
    },
    %{
      id: "auth.token_arg.failloud",
      remediation: "R15",
      note: ":token_arg fail-loud si token absent"
    },
    %{
      id: "skills.declared_present",
      remediation: "R11",
      note: "skills whitelistés absents → fail"
    },
    %{
      id: "spawn.has_mandate",
      remediation: "R18",
      note: "refus spawn sans mandat hors mode admin"
    },
    %{
      id: "launch.backend_containment_coherent",
      remediation: "R20",
      note: "TmuxBackend quarantaine/containment cohérent"
    }
  ]

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
        check_capprofile_modop_incompatible_path(root)
      ] ++ Enum.map(@pending_checks, &Map.put(&1, :status, :pending))

    overall = if Enum.any?(checks, &(&1.status == :fail)), do: :fail, else: :pass

    {overall, checks}
  end

  # ── Checks implémentés ───────────────────────────────────────────────

  # R03/R10 (→R2) : les consommateurs d'events doivent matcher %Fleet.Event{},
  # pas le tuple legacy {atom, %{"event_type" => ...}}. Set R2 = Executor + WS
  # (R2a, fait) + TaskMonitor + RelayHandler (R2b). Hors R2 (autres sous-lots) :
  # AutoDispatcher (Pilot→R4), MCP Bridge (channels→R6), Dispatch/AuditConsumer
  # (dual legacy retiré au verrou→R5/R7).
  defp check_event_consumers_canon(root) do
    targets = [
      "apps/fleet_pipeline/lib/fleet/pipeline/executor.ex",
      "apps/fleet_api/lib/fleet/api/ws.ex",
      "apps/fleet_task_monitor/lib/fleet/task_monitor.ex",
      "apps/fleet_api/lib/fleet/api/relay_handler.ex"
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
    loader = Path.join(root, "apps/fleet_pipeline/lib/fleet/pipeline/loader.ex")
    src = File.read!(loader)

    # Normalisation présente = le loader déballe spec.stages (ex `get_in(yaml, ["spec", "stages"])`
    # ou un Map.put("stages", ...)). Heuristique : absence de toute extraction de spec.stages.
    normalized? = Regex.match?(~r/"spec".*"stages"|normalize|deenvelope|déball/i, src)

    %{
      id: "pipeline.v25.normalized",
      remediation: "R01/U1 (R3)",
      status: if(normalized?, do: :pass, else: :fail),
      evidence:
        grep_lines(loader, ~r/has_key\?\(yaml, "spec"\)/)
        |> Enum.map(fn {ln, _} -> "apps/fleet_pipeline/lib/fleet/pipeline/loader.ex:#{ln}" end),
      note: "Loader détecte v2.5 mais ne déballe pas spec → Executor lit stages=nil"
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
    notwired =
      grep_lines(
        Path.join(root, "apps/fleet_coord/lib/fleet/coord/soft_gate.ex"),
        ~r/NotWiredYet/
      )
      |> Enum.map(fn {ln, _} -> "apps/fleet_coord/lib/fleet/coord/soft_gate.ex:#{ln}" end)

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
