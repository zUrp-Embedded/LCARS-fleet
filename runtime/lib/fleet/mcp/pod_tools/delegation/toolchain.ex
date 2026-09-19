defmodule Fleet.MCP.PodTools.Delegation.Toolchain do
  @moduledoc """
  Composes tooling requests from typed input and channel-derived work context.
  Target tooling repo/base come from Toolchain configuration; a related issue address
  comes from pod identity and its active work item. Direct calls check identity,
  not role capability; socket admission is upstream.
  """

  require Logger

  alias Fleet.MCP.PodTools.Delegation.{ForgeWriter, Gate}

  @doc """
  Creates/updates a tooling manifest and PR. Read active work through list_active:
  get_for_pod would assign/poll it and alter queue state as a side effect.

  With an active item, the PR carries its issue marker and the issue receives a
  waiting label; failure to set that label fails the request after PR creation.
  Without an item, use an identity-bound anticipation branch and no waiting marker,
  so the reconciler has no ticket to drain. Branch names use separate item/pod prefixes.

  Deterministic branches and existing-PR lookup support retries but are not a
  transaction. All returned branch-creation errors are ignored, not only already-exists.
  """
  @spec request_toolchain(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def request_toolchain(args, pod_id) when is_map(args) and is_binary(pod_id) and pod_id != "" do
    with :ok <- Fleet.Toolchain.validate_form(args),
         {:ok, forge} <- Gate.conforming(ForgeWriter, ForgeWriter.resolved()) do
      case active_work_item(pod_id) do
        {:ok, work_item} -> toolchain_for_work_item(args, pod_id, work_item, forge)
        {:error, :no_active_work_item} -> toolchain_anticipated(args, pod_id, forge)
      end
    end
  end

  def request_toolchain(_args, _pod_id), do: {:error, :pod_id_required}

  # Associate the request with the active item using persisted forge markers and a waiting label.
  # The TaskQueue item itself is not changed to a waiting state here.
  defp toolchain_for_work_item(args, pod_id, work_item, forge) do
    repo = Fleet.Toolchain.ops_repo()
    base = Fleet.Toolchain.branch()
    branch = Fleet.Toolchain.branch_for(work_item.id)
    eco = args["ecosystem"]

    content =
      Fleet.Toolchain.render(args,
        issue: work_item.issue_id,
        role: work_item.role,
        work_item_id: work_item.id
      )

    # ⚠ L'ADRESSE SE RESOUT AVANT QUE LA BRANCHE N'EXISTE. Elle ne demande rien a la forge — elle
    # lit l'identite du pod et le numero du work-item — donc la faire passer d'abord ne coute rien
    # et evite une branche que plus personne ne reclame : un refus laissait jusqu'ici un
    # `tool_request-<id>` orphelin, sans manifeste ni PR (les `lcars/toolchain-*` de LCARS-beta).
    with {:ok, item_repo, item_issue} <- workitem_address(pod_id, work_item),
         # Retry may encounter an existing branch; this also ignores unrelated creation failures.
         _ = forge.create_branch(repo, branch, base, []),
         # PR body identifies the issue for reconciler draining even on close-without-merge.
         # The issue label blocks dispatch; the comment adds human context and a PR marker.
         # Label failure aborts the remaining steps; comment failure is logged and tolerated.
         {:ok, _} <-
           forge.put_file(repo, Fleet.Toolchain.manifest_path(eco), content, branch: branch),
         {:ok, pr} <-
           forge.open_pr(repo, branch, base, "[toolchain] #{eco}",
             body:
               "Demande d'outillage — work-item `#{work_item.id}` (#{item_repo}##{item_issue}).\n" <>
                 Fleet.Toolchain.workitem_marker(item_repo, item_issue)
           ),
         {:ok, _} <- forge.add_label(item_repo, item_issue, Fleet.Toolchain.waiting_label(), []) do
      case forge.post_comment(
             item_repo,
             item_issue,
             "Demande d'outillage en vol : PR #{repo}!#{pr_number(pr)} — ce ticket attend la " <>
               "signature d'un admin (ou son refus).\n" <>
               Fleet.Toolchain.marker(pr_number(pr) || 0),
             []
           ) do
        {:ok, _} ->
          :ok

        {:error, why} ->
          Logger.warning(
            "Delegation: toolchain_request — commentaire de lien NON posé sur " <>
              "#{item_repo}##{item_issue} (#{inspect(why)}) ; le verrou et le marqueur de PR " <>
              "portent le drain, seule la lisibilité humaine est perdue"
          )
      end

      arm_auto_merge(forge, repo, pr)

      {:ok, %{"status" => "toolchain_requested", "ecosystem" => eco, "pr" => pr_number(pr)}}
    end
  end

  # Optional auto-merge defaults off. Deployment must pair enablement with branch
  # protection or the forge may merge without review; this code does not inspect protection.
  # The setting uses truthiness. Scheduling errors leave manual approve/merge available.
  defp arm_auto_merge(forge, repo, pr) do
    if Application.get_env(:lcars_fleet, :toolchain_auto_merge, false) do
      case forge.schedule_auto_merge(repo, pr_number(pr), []) do
        {:ok, _} ->
          :ok

        :ok ->
          :ok

        {:error, why} ->
          Logger.warning(
            "Delegation: toolchain_request — auto-merge NON armé sur ##{pr_number(pr)} " <>
              "(#{inspect(why)}) ; le chemin deux-clics reste (approve puis merge)"
          )
      end
    end

    :ok
  end

  # Anticipation must work without an active item (toolchain.grant_reachable).
  # Omit waiting labels and workitem_marker: the reconciler skips unassociated PRs.
  # The PR body tells the approver there is no ticket waiting for redispatch.
  defp toolchain_anticipated(args, pod_id, forge) do
    with {:ok, %{role: role}} <- Gate.resolve_identity(pod_id) do
      repo = Fleet.Toolchain.ops_repo()
      base = Fleet.Toolchain.branch()
      branch = Fleet.Toolchain.branch_for_pod(pod_id)
      eco = args["ecosystem"]

      content = Fleet.Toolchain.render(args, role: role)

      # Use the pod-derived branch for repeat anticipated requests.
      _ = forge.create_branch(repo, branch, base, [])

      with {:ok, _} <-
             forge.put_file(repo, Fleet.Toolchain.manifest_path(eco), content, branch: branch),
           {:ok, pr} <-
             forge.open_pr(repo, branch, base, "[toolchain] #{eco} (anticipation)",
               body:
                 "Demande d'outillage ANTICIPÉE — rôle `#{role}`, AUCUN ticket en attente.\n\n" <>
                   "Merger installe l'outil sur les conteneurs qui suivent cette branche. " <>
                   "Aucun work-item ne sera re-dispatché : il n'y en a pas."
             ) do
        arm_auto_merge(forge, repo, pr)
        {:ok, %{"status" => "toolchain_requested", "ecosystem" => eco, "pr" => pr_number(pr)}}
      end
    end
  end

  # Derive the related repo from identity and number from issue_id, never request arguments.
  # Unbound/unparseable addresses refuse BEFORE the branch exists: nothing is left behind.
  defp workitem_address(pod_id, work_item) do
    with {:ok, %{repo: repo}} when is_binary(repo) and repo != "" <-
           Gate.resolve_identity(pod_id),
         {:ok, n} <- Fleet.Toolchain.workitem_issue_number(work_item.issue_id) do
      {:ok, repo, n}
    else
      :error -> {:error, :work_item_issue_unparseable}
      {:ok, _} -> {:error, :pod_repo_unbound}
      {:error, _} = err -> err
    end
  end

  # Select the first active item for this pod without recording a poll or assignment.
  defp active_work_item(pod_id) do
    case Enum.find(Fleet.TaskQueue.list_active(), &(&1.pod_id == pod_id)) do
      nil -> {:error, :no_active_work_item}
      item -> {:ok, item}
    end
  end

  # The canonical writer returns a bare PR number, including existing-PR lookup on 409.
  defp pr_number(n) when is_integer(n), do: n
  defp pr_number(_), do: nil
end
