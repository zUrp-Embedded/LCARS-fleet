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
      id: "capprofile.lifetime_scope_path",
      remediation: "R12",
      note: "compose_claude_md lit spec.invocation.lifetime_scope"
    },
    %{
      id: "capprofile.modop_incompatible_path",
      remediation: "R13",
      note: "check_modop_incompatible lit spec.modop_set.incompatible"
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

    root = umbrella_root()

    checks =
      [
        check_event_consumers_canon(root),
        check_pipeline_v25_normalized(root),
        check_events_handlers_exist(root),
        check_coord_backend_wired(root)
      ] ++ Enum.map(@pending_checks, &Map.put(&1, :status, :pending))

    overall = if Enum.any?(checks, &(&1.status == :fail)), do: :fail, else: :pass

    unless quiet?, do: IO.puts(render_yaml(overall, checks))

    fails = Enum.count(checks, &(&1.status == :fail))
    pend = Enum.count(checks, &(&1.status == :pending))

    Mix.shell().info(
      "contracts.check: #{overall} — #{fails} fail, #{pend} pending, " <>
        "#{Enum.count(checks, &(&1.status == :pass))} pass"
    )

    if overall == :fail, do: exit({:shutdown, 1})
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
  defp check_coord_backend_wired(root) do
    soft_gate = Path.join(root, "apps/fleet_coord/lib/fleet/coord/soft_gate.ex")

    evidence =
      grep_lines(soft_gate, ~r/HookSpawner\.NotWiredYet/)
      |> Enum.map(fn {ln, _} -> "apps/fleet_coord/lib/fleet/coord/soft_gate.ex:#{ln}" end)

    %{
      id: "coord.backend.wired_or_pure",
      remediation: "R06/R22 (R4)",
      status: if(evidence == [], do: :pass, else: :fail),
      evidence: evidence,
      note: "soft_gate spawner_backend défaut = NotWiredYet placeholder"
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
