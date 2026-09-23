defmodule Fleet.MCP.PodTools.Delegation.Retirement do
  @moduledoc """
  Retires issues directly, through supersede, or in a project sweep — through ONE ordered sequence.

  1. Stamp `stage/retired` on the still-open ticket. `StepDispatcher.decide/1` skips it from here
     on: whatever fails afterwards, the ticket is never dispatched again.
  2. Close its live pull request (pull processing can outlive the issue).
  3. Read its graph: what it waits on (blockers), what waits on it (dependents).
  4. With a successor, give the successor the edges it lacks — decided by READING the successor's
     graph, never by parsing a forge error. Without one, tell each dependent it is released.
  5. Lift the ticket's own blockers. Gitea refuses to close an issue with open dependencies (HTTP
     412): without this step a blocked ticket cannot be retired at all.
  6. Close as retired, then lift the dependents' edges (closure already releases them for
     admission, which counts open blockers only; the removal cleans the graph).
  7. Only now say it on the ticket: the comment describes what happened, never what was intended.
  8. Reap its pods.

  A failure after step 1 stops the sequence, leaves the ticket stamped and open, and says which
  step failed and why — on the ticket and in the result. Every step tolerates being replayed, so
  the same call finishes the retirement. An already-closed ticket is a no-op.
  These are ordered effects, not transactions. Reaper results are ignored and callback
  exceptions propagate.
  """

  require Logger

  alias Fleet.MCP.PodTools.Delegation.{DependencyForge, Gate, IssuePR}

  @retired_label Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_retired()

  @typedoc "What a retirement is for: a successor carries the work on, a reason ends it."
  @type intent :: {:successor, pos_integer()} | {:reason, String.t()}

  @doc """
  Runs the retirement sequence on an open ticket. Returns the outcome map, or
  `{:error, {:retire_incomplete, n, step, reason}}` with the ticket left stamped and open.
  """
  @spec retire(module(), String.t(), pos_integer(), :open | {:open, pos_integer()}, intent()) ::
          {:ok, map()} | {:error, {:retire_incomplete, pos_integer(), atom(), term()}}
  def retire(forge, repo, n, target, intent) do
    pr = live_pr(target)

    with {:ok, _} <- step(:stamp, forge.add_label(repo, n, @retired_label, [])),
         :ok <- step(:pull_request, IssuePR.close_live_pr(forge, repo, pr)),
         {:ok, blockers, dependents} <- read_graph(forge, repo, n),
         {:ok, not_carried} <- hand_over(forge, repo, n, dependents, blockers, intent),
         :ok <- lift(forge, repo, n, blockers),
         {:ok, _} <- step(:close, forge.close_issue(repo, n, closure: :retired)) do
      {released, unlifted} = lift_dependents(forge, repo, n, dependents)
      said = say(forge, repo, n, closed_comment(intent, not_carried))
      _ = pod_reaper().reap_issue(repo, n)

      {:ok,
       %{"issue" => n, "retired" => true, "released" => released, "pr_closed" => pr}
       |> put_if("edges_not_lifted", unlifted)
       |> put_if("edges_not_carried", not_carried)
       |> put_if("comment_not_posted", if(said == :ok, do: [], else: [said]))}
    else
      {:error, {step, reason}} ->
        Logger.error(
          "Delegation: retirement of #{repo}##{n} INCOMPLETE at #{step} (#{inspect(reason)}) — " <>
            "stamped #{@retired_label}, so never dispatched again; replaying the retirement finishes it"
        )

        _ = say(forge, repo, n, incomplete_comment(step, reason))
        {:error, {:retire_incomplete, n, step, reason}}
    end
  end

  defp live_pr({:open, pr}), do: pr
  defp live_pr(_open), do: nil

  defp step(_name, :ok), do: :ok
  defp step(_name, {:ok, _} = ok), do: ok
  defp step(name, {:error, reason}), do: {:error, {name, reason}}

  defp read_graph(forge, repo, n) do
    with {:ok, blockers} <- step(:graph, numbers(forge.issue_dependencies(repo, n, []))),
         {:ok, dependents} <- step(:graph, numbers(forge.issue_blocks(repo, n, []))) do
      {:ok, blockers, dependents}
    end
  end

  # An edge whose other end has no number cannot be carried nor lifted: stop rather than guess.
  defp numbers({:ok, issues}) do
    Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, acc} ->
      case Map.get(issue, "number") do
        d when is_integer(d) -> {:cont, {:ok, acc ++ [d]}}
        _ -> {:halt, {:error, {:edge_without_number, issue}}}
      end
    end)
  end

  defp numbers({:error, _} = err), do: err

  defp hand_over(forge, repo, n, dependents, blockers, {:successor, succ}) do
    with {:ok, held} <- step(:carry, numbers(forge.issue_dependencies(repo, succ, []))),
         {:ok, waiting} <- step(:carry, numbers(forge.issue_blocks(repo, succ, []))) do
      to_hold = (blockers -- [succ, n]) -- held
      to_wait = (dependents -- [succ, n]) -- waiting

      # A refused edge is SAID (on the ticket and in the result), it does not stop the retirement:
      # the successor exists already, and a zombie predecessor costs more than a missing edge.
      not_carried =
        Enum.flat_map(to_hold, &carry(forge.add_issue_dependency(repo, succ, &1, []), &1)) ++
          Enum.flat_map(to_wait, &carry(forge.add_issue_dependency(repo, &1, succ, []), &1))

      {:ok, not_carried}
    end
  end

  defp hand_over(forge, repo, n, dependents, _blockers, {:reason, _}) do
    Enum.reduce_while(dependents, {:ok, []}, fn d, acc ->
      case forge.post_comment(repo, d, released_comment(n), []) do
        {:ok, _} -> {:cont, acc}
        {:error, err} -> {:halt, {:error, {:announce, {d, err}}}}
      end
    end)
  end

  defp carry({:ok, _}, _other), do: []
  # 409: the edge appeared between the read and the write — it is carried.
  defp carry({:error, {:http, 409, _}}, _other), do: []

  defp carry({:error, {:http, _, %{"message" => m}}}, other) when is_binary(m) and m != "",
    do: ["##{other} : #{m}"]

  defp carry({:error, reason}, other), do: ["##{other} : #{inspect(reason)}"]

  # The ticket's own blockers must go before the close: Gitea refuses to close an issue that still
  # has open dependencies. Every removal is attempted; the first failure stops before the close.
  defp lift(forge, repo, n, blockers) do
    case Enum.reject(blockers, &match?({:ok, _}, forge.remove_issue_dependency(repo, n, &1, []))) do
      [] -> :ok
      left -> {:error, {:lift, {:blockers_not_lifted, left}}}
    end
  end

  # After closure, attempt every removal and report failures rather than stopping at the first.
  defp lift_dependents(forge, repo, n, dependents) do
    Enum.reduce(dependents, {[], []}, fn d, {ok, ko} ->
      case forge.remove_issue_dependency(repo, d, n, []) do
        {:ok, _} ->
          {ok ++ [d], ko}

        {:error, err} ->
          Logger.error(
            "Delegation: #{repo}##{n} retired and closed, but the edge of dependent ##{d} could " <>
              "not be lifted (#{inspect(err)}) — ##{d} is released anyway (admission counts open " <>
              "blockers only); the stale edge remains to be cleaned by hand"
          )

          {ok, ko ++ [d]}
      end
    end)
  end

  defp say(forge, repo, n, body) do
    case forge.post_comment(repo, n, body, []) do
      {:ok, _} -> :ok
      {:error, reason} -> inspect(reason)
    end
  end

  defp put_if(map, _key, []), do: map
  defp put_if(map, key, list), do: Map.put(map, key, list)

  defp closed_comment({:reason, reason}, _not_carried) do
    "Ticket retiré par l'architecte — aucun remplaçant, rien n'a été livré.\n\nMotif : #{reason}"
  end

  defp closed_comment({:successor, succ}, []) do
    "Remplacé par ##{succ} (brief re-cadré) — ticket retiré et fermé par la fleet (supersede)."
  end

  defp closed_comment({:successor, succ}, not_carried) do
    closed_comment({:successor, succ}, []) <>
      "\n\n⚠ Dépendance(s) NON portée(s) vers ##{succ}, à reposer à la main si elles comptent :\n" <>
      Enum.map_join(not_carried, "\n", &("- " <> &1))
  end

  defp incomplete_comment(step, reason) do
    "Retrait INTERROMPU à l'étape `#{step}` (#{inspect(reason)}). Le ticket est tamponné " <>
      "`#{@retired_label}` : il ne sera plus jamais dispatché. Il reste ouvert : relancer le " <>
      "retrait (`issue_retire`) le termine."
  end

  defp released_comment(n) do
    "Le bloqueur ##{n} a été retiré sans remplaçant : la dépendance est levée sur ce ticket. " <>
      "Si ce travail restait nécessaire, il doit être redemandé — le retrait n'a rien livré."
  end

  @doc """
  Sweeps issues in projects whose reported state is open, behind the onboarder gate.
  Onboard.list_stoppable_issues supplies human-scoped tickets and excludes parked
  markers, whose closure would unpark a project. Unknown/parked projects are skipped.

  Uses retirement, including the pod reaper, and continues after returned per-ticket
  errors; callback exceptions still abort. Global project-list errors propagate;
  a project's ticket-list failure counts as one entry, not a count of affected tickets.
  Re-running skips closed
  issues, so it does not guarantee repair of cleanup left after closure.
  """
  @spec emergency_stop(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def emergency_stop(reason, state) when is_binary(reason) and reason != "" do
    with {:ok, _role} <- Gate.require_onboarder(state),
         {:ok, forge} <- Gate.conforming_forge(),
         {:ok, _} <- Gate.conforming(DependencyForge, forge),
         {:ok, onboard} <- Gate.conforming_onboard(),
         {:ok, projects} <- onboard.list_projects([]) do
      targets = Enum.filter(projects, &(&1["state"] == "open"))
      skipped = Enum.map(projects -- targets, & &1["repo"])

      swept = Enum.map(targets, &sweep_project(forge, onboard, &1["repo"], reason))

      {:ok,
       %{
         "stopped" => Enum.sum(Enum.map(swept, &length(&1["retired"]))),
         "failed" => Enum.sum(Enum.map(swept, &length(&1["failures"]))),
         "projects" => swept,
         "skipped_not_open" => skipped
       }}
    end
  end

  def emergency_stop(_reason, _state), do: {:error, :invalid_arguments}

  defp sweep_project(forge, onboard, repo, reason) do
    case onboard.list_stoppable_issues(repo, []) do
      {:ok, numbers} ->
        Enum.reduce(numbers, %{"repo" => repo, "retired" => [], "failures" => []}, fn n, acc ->
          record_sweep(acc, n, stop_one(forge, repo, n, reason))
        end)

      {:error, why} ->
        %{
          "repo" => repo,
          "retired" => [],
          "failures" => [%{"issue" => nil, "error" => inspect(why)}]
        }
    end
  end

  defp record_sweep(acc, n, {:ok, %{"retired" => true}}),
    do: Map.update!(acc, "retired", &(&1 ++ [n]))

  defp record_sweep(acc, _n, {:ok, _already_closed}), do: acc

  defp record_sweep(acc, n, {:error, why}),
    do: Map.update!(acc, "failures", &(&1 ++ [%{"issue" => n, "error" => inspect(why)}]))

  defp stop_one(forge, repo, n, reason) do
    case IssuePR.target_state_preflight(forge, repo, n) do
      {:ok, target} -> retire_open(forge, repo, n, target, {:reason, reason})
      {:error, _} = err -> err
    end
  end

  @doc """
  Retires a bound-project ticket without creating a replacement. Requires a nonempty
  reason; closure records retirement rather than delivery. Runs the sequence of the moduledoc;
  an incomplete retirement is replayed by calling it again.
  """
  @spec retire_issue(integer(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def retire_issue(number, reason, state)
      when is_integer(number) and number > 0 and is_binary(reason) and reason != "" do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         {:ok, forge} <- Gate.conforming_forge(),
         {:ok, _} <- Gate.conforming(DependencyForge, forge),
         {:ok, target} <- IssuePR.target_state_preflight(forge, repo, number) do
      retire_open(forge, repo, number, target, {:reason, reason})
    end
  end

  def retire_issue(_number, _reason, _state), do: {:error, :invalid_arguments}

  defp retire_open(_forge, _repo, n, :closed, _intent) do
    {:ok,
     %{
       "issue" => n,
       "retired" => false,
       "note" => "##{n} etait deja ferme — rien fait, le retrait est idempotent"
     }}
  end

  defp retire_open(forge, repo, n, target, intent), do: retire(forge, repo, n, target, intent)

  @doc """
  Retires the ticket a new one supersedes, handing its edges to the successor. Never fails the
  creation of the successor: an incomplete retirement is reported in `supersede_warning`, the old
  ticket stays stamped (never dispatched again) and the architect replays it with `issue_retire`.
  """
  @spec retire_superseded(module(), String.t(), term(), term(), map()) :: map()
  def retire_superseded(_forge, _repo, nil, _target_state, result), do: result

  def retire_superseded(_forge, _repo, n, :closed, result),
    do: Map.put(result, "supersedes", n)

  def retire_superseded(forge, repo, n, target, result) do
    case Gate.conforming(DependencyForge, forge) do
      {:ok, _} ->
        superseded(forge, repo, n, target, result)

      # The edges cannot be read, so nothing else is attempted — but the stamp is: the successor
      # already exists, and an unstamped predecessor would be dispatched again beside it.
      {:error, reason} ->
        _ = forge.add_label(repo, n, @retired_label, [])
        warn_superseded(result, n, {:dependency_surface, reason})
    end
  end

  defp superseded(forge, repo, n, target, result) do
    case retire(forge, repo, n, target, {:successor, Map.get(result, "issue")}) do
      {:ok, outcome} ->
        result
        |> Map.put("supersedes", n)
        |> put_if("edges_not_carried", Map.get(outcome, "edges_not_carried", []))

      {:error, {:retire_incomplete, ^n, step, reason}} ->
        warn_superseded(result, n, {step, reason})
    end
  end

  defp warn_superseded(result, n, {step, reason}) do
    result
    |> Map.put("supersedes", n)
    |> Map.put(
      "supersede_warning",
      "le retrait de ##{n} s'est arrêté à l'étape #{step} (#{inspect(reason)}). Il est tamponné " <>
        "retiré : il ne repartira pas. Termine-le avec issue_retire(#{n})."
    )
  end

  # Upward reaper seam: keep the module in an attribute rather than a forbidden remote Pilot call.
  @default_pod_reaper Fleet.Pilot.PodReaper
  defp pod_reaper, do: Application.get_env(:lcars_fleet, :mcp_pod_reaper, @default_pod_reaper)
end
