defmodule Fleet.MCP.PodTools.Delegation.Retirement do
  @moduledoc """
  Retires issues directly, through supersede, or in a project sweep.
  PR closure precedes dependency work because pull processing can outlive the issue.
  These are ordered effects, not transactions: errors can leave a closed PR, copied
  edges or posted comments. Reaper results are ignored and callback exceptions propagate.
  """

  require Logger

  alias Fleet.MCP.PodTools.Delegation.{DependencyForge, Gate, IssuePR}

  # Copy both dependency directions before closing the old ticket. Reading the graph is what can
  # stop the retirement; a single edge that will not be written does NOT — it is reported.
  #
  # ⚠ MESURE DU 2026-09-16 : LE RETRAIT QUI ECHOUE EST PIRE QUE L'ARETE QU'IL PORTE. Gitea 1.26 rend
  # 500 (pas 409) sur deux etats ordinaires de cette ecriture — « issue dependency does already
  # exist » et « circular dependencies exists » — et ce code faisait alors avorter le retrait. Le
  # ticket remplace restait OUVERT, la fleet le redispatchait, et la meme brique etait livree deux
  # fois : mesure sur le banc beta, cinq supersedes en echec sur un projet, deux livraisons
  # jumelles (#12 et #14, #19 et #20). Une arete non portee se DIT ; un zombie, personne ne le voit.
  #
  # ⚠ A SURVEILLER : si ces deux etats se mettent a rendre 409 ou 200, c'est que la forge a ete
  # corrigee en amont — le code ci-dessous continuera de marcher, et cette note pourra partir.
  defp carry_dependencies(forge, repo, old_n, new_n) do
    with {:ok, _} <- Gate.conforming(DependencyForge, forge),
         {:ok, blockers} <- forge.issue_dependencies(repo, old_n, []),
         {:ok, blocked} <- forge.issue_blocks(repo, old_n, []) do
      non_portees =
        copy_edges(blockers, fn b -> forge.add_issue_dependency(repo, new_n, b, []) end) ++
          copy_edges(blocked, fn b -> forge.add_issue_dependency(repo, b, new_n, []) end)

      {:ok, non_portees}
    else
      {:error, reason} -> {:error, {:dependencies_not_read, reason}}
    end
  end

  # Rend la liste des aretes qui n'ont PAS ete portees, chacune avec sa cause.
  defp copy_edges(issues, write_fun) do
    Enum.flat_map(issues, &copy_one_edge(&1, write_fun))
  end

  defp copy_one_edge(issue, write_fun) do
    case Map.get(issue, "number") do
      n when is_integer(n) -> edge_written(n, write_fun.(n))
      _ -> ["une arête sans numéro (#{inspect(issue)})"]
    end
  end

  defp edge_written(_n, {:ok, _}), do: []
  # 409, et 500 « does already exist » : l'arête EST portée, la forge le dit mal.
  defp edge_written(_n, {:error, {:http, 409, _}}), do: []

  defp edge_written(n, {:error, {:http, 500, %{"message" => m}}}) when is_binary(m) do
    if String.contains?(m, "does already exist"), do: [], else: ["##{n} : #{m}"]
  end

  defp edge_written(n, {:error, raison}), do: ["##{n} : #{inspect(raison)}"]

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
      {:ok, target} -> do_retire_issue(forge, repo, n, reason, target)
      {:error, _} = err -> err
    end
  end

  @doc """
  Retires a bound-project ticket without creating a replacement. Requires a nonempty
  reason; closure records retirement rather than delivery.

  Order: close live PR, read/address dependents, announce their release, comment on
  the target, close it, then attempt each edge removal and reap its pods. Closing
  releases admission blockers because Lease counts only open issues; removing edges
  afterwards cleans the graph. Announcements explain that necessary work must be requested again.

  A returned failure before closure aborts remaining steps but does not undo earlier
  effects. Edge-removal failures after closure are returned in edges_not_lifted;
  released lists successful removals, not every dependent unblocked by closure.
  An already-closed target is a no-op and does not retry edge cleanup or reaping.
  Concurrent forge changes and ambiguous write failures can invalidate the logged
  claim that an aborted target is still open.
  """
  @spec retire_issue(integer(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def retire_issue(number, reason, state)
      when is_integer(number) and number > 0 and is_binary(reason) and reason != "" do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         {:ok, forge} <- Gate.conforming_forge(),
         {:ok, _} <- Gate.conforming(DependencyForge, forge),
         {:ok, target} <- IssuePR.target_state_preflight(forge, repo, number) do
      do_retire_issue(forge, repo, number, reason, target)
    end
  end

  def retire_issue(_number, _reason, _state), do: {:error, :invalid_arguments}

  defp do_retire_issue(_forge, _repo, n, _reason, :closed) do
    {:ok,
     %{
       "issue" => n,
       "retired" => false,
       "note" => "##{n} etait deja ferme — rien fait, le retrait est idempotent"
     }}
  end

  defp do_retire_issue(forge, repo, n, reason, target) do
    pr = if match?({:open, _}, target), do: elem(target, 1)

    with :ok <- IssuePR.close_live_pr(forge, repo, pr),
         {:ok, dependents} <- forge.issue_blocks(repo, n, []),
         {:ok, numbers} <- addressable_dependents(dependents),
         :ok <- announce_release(forge, repo, n, numbers),
         {:ok, _} <- forge.post_comment(repo, n, retire_comment(reason), []),
         {:ok, _} <- forge.close_issue(repo, n, closure: :retired) do
      # Closure already released admission blockers; report stale edges that could not be removed.
      {released, unlifted} = lift_edges(forge, repo, n, numbers)

      # Request immediate reaping after closure; the returned outcome is ignored.
      _ = pod_reaper().reap_issue(repo, n)

      result = %{"issue" => n, "retired" => true, "released" => released, "pr_closed" => pr}

      {:ok, with_unlifted(result, unlifted)}
    else
      {:error, reason} ->
        Logger.error(
          "Delegation: retirement of #{repo}##{n} ABORTED (#{inspect(reason)}) — " <>
            "the ticket is still OPEN and NOTHING was released: nothing to repair, re-emit"
        )

        {:error, {:retire_aborted, n, reason}}
    end
  end

  # Validate dependent numbers before their announcements/target closure, but after PR closure.
  defp addressable_dependents(dependents) do
    Enum.reduce_while(dependents, {:ok, []}, fn dep, {:ok, acc} ->
      case Map.get(dep, "number") do
        d when is_integer(d) -> {:cont, {:ok, acc ++ [d]}}
        _ -> {:halt, {:error, {:edge_without_number, dep}}}
      end
    end)
  end

  # Announce before closure releases blockers. A failed announcement stops remaining
  # steps; earlier announcements are not rolled back and may repeat on retry.
  defp announce_release(forge, repo, n, numbers) do
    Enum.reduce_while(numbers, :ok, fn d, :ok ->
      case forge.post_comment(repo, d, released_comment(n), []) do
        {:ok, _} -> {:cont, :ok}
        {:error, err} -> {:halt, {:error, {:dependent_not_announced, d, err}}}
      end
    end)
  end

  # After closure, attempt every removal and report failures rather than stopping at the first.
  defp lift_edges(forge, repo, n, numbers) do
    Enum.reduce(numbers, {[], []}, fn d, {ok, ko} ->
      case forge.remove_issue_dependency(repo, d, n, []) do
        {:ok, _} ->
          {ok ++ [d], ko}

        {:error, err} ->
          Logger.error(
            "Delegation: #{repo}##{n} RETIRE et ferme, mais l'arete du dependant ##{d} n'a pas pu " <>
              "etre levee (#{inspect(err)}) — ##{d} est DEBLOQUE (l'admission ne compte que les " <>
              "bloqueurs ouverts) et il a ete annonce ; l'arete perimee reste a nettoyer a la main"
          )

          {ok, ko ++ [d]}
      end
    end)
  end

  defp with_unlifted(result, []), do: result
  defp with_unlifted(result, unlifted), do: Map.put(result, "edges_not_lifted", unlifted)

  defp retire_comment(reason) do
    "Ticket retiré par l'architecte — aucun remplaçant, rien n'a été livré.\n\nMotif : #{reason}"
  end

  defp released_comment(n) do
    "Le bloqueur ##{n} a été retiré sans remplaçant : la dépendance est levée sur ce ticket. " <>
      "Si ce travail restait nécessaire, il doit être redemandé — le retrait n'a rien livré."
  end

  # Supersede uses system-authored comment/closure and leaves the replacement intact
  # on failure, returning supersede_warning. Public so tests can observe copy-before-close order.
  # The awaits-arch label remains historical; closed issues leave open-only inboxes.
  @doc false
  @spec retire_superseded(module(), String.t(), term(), term(), map()) :: map()
  def retire_superseded(_forge, _repo, nil, _target_state, result), do: result

  def retire_superseded(_forge, _repo, n, :closed, result),
    do: Map.put(result, "supersedes", n)

  def retire_superseded(forge, repo, n, :open, result), do: do_retire(forge, repo, n, nil, result)

  def retire_superseded(forge, repo, n, {:open, pr}, result),
    do: do_retire(forge, repo, n, pr, result)

  defp do_retire(forge, repo, n, pr, result) do
    new_number = Map.get(result, "issue")

    # Supersedes is an LCARS convention, not a forge graph operation. Copy what the old
    # issue waits on and what waits on it before closure; otherwise dependents can be
    # admitted in the gap or the replacement can lose its own prerequisites.
    with :ok <- IssuePR.close_live_pr(forge, repo, pr),
         {:ok, non_portees} <- carry_dependencies(forge, repo, n, new_number),
         comment = supersede_comment(new_number, non_portees),
         {:ok, _} <- forge.post_comment(repo, n, comment, []),
         # Work moved to the replacement; retiring the old issue claims no delivery.
         {:ok, _} <- forge.close_issue(repo, n, closure: :retired) do
      # Request reaping after closure; callback failure does not undo forge effects.
      _ = pod_reaper().reap_issue(repo, n)
      Map.put(result, "supersedes", n)
    else
      err ->
        Logger.error(
          "Delegation: supersede retirement of #{repo}##{n} FAILED (#{inspect(err)}) — " <>
            "##{new_number} created but ##{n} still open (zombie risk): close it manually"
        )

        result
        |> Map.put("supersedes", n)
        |> Map.put(
          "supersede_warning",
          "le retrait de ##{n} a échoué — il est encore ouvert, fais-le fermer par ton humain"
        )
    end
  end

  # Une arête non portée se dit SUR LE TICKET, pas seulement dans un journal que personne ne lit.
  defp supersede_comment(new_number, []) do
    "Remplacé par ##{new_number} (brief re-cadré) — ticket retiré par la fleet (supersede)."
  end

  defp supersede_comment(new_number, non_portees) do
    "Remplacé par ##{new_number} (brief re-cadré) — ticket retiré par la fleet (supersede).\n\n" <>
      "⚠ Dépendance(s) NON portée(s) vers ##{new_number}, à reposer à la main si elles comptent :\n" <>
      Enum.map_join(non_portees, "\n", &("- " <> &1))
  end

  # Upward reaper seam: keep the module in an attribute rather than a forbidden remote Pilot call.
  @default_pod_reaper Fleet.Pilot.PodReaper
  defp pod_reaper, do: Application.get_env(:lcars_fleet, :mcp_pod_reaper, @default_pod_reaper)
end
