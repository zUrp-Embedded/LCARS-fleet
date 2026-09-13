defmodule Fleet.Pilot.ArchWake do
  @moduledoc """
  Shared offer/ensure/wake sequence for immediate escalation and the Poller retry net.
  Group by repository and choose its smallest issue number; groups are processed
  sequentially, while each architect has its own queue identity.

  Assigned means busy with no effects. Pending means ensure/wake the existing mandate.
  Other queue-status responses take the fresh-offer path: enqueue before ensure and
  wake so the pod cannot pull before content exists. An enqueue error sends no wake;
  returned ensure errors are logged and still permit a wake attempt.

  offered/woken_pending require wake_pod to return :ok, not proof the pod consumed it.
  Failed wake returns wake_unreached so callers can avoid a success cooldown. This
  module does not remove the forge escalation label or own retry scheduling.

  Aggregate prefers offered, then woken_pending, else the first outcome (nil for an
  empty set). Mixed outcomes lose per-repo detail; the single result cannot identify
  which repository's wake failed.
  """

  require Logger

  alias Fleet.Project.Architect, as: ProjectArchitect

  @type outcome ::
          :offered | :woken_pending | :busy | :wake_unreached | {:error, {:enqueue, term()}}

  @doc """
  Offers and wakes the architect for each repository represented in `awaits`.
  """
  @spec offer_then_wake(
          module(),
          module(),
          {String.t(), pos_integer()} | MapSet.t(),
          String.t(),
          keyword()
        ) :: outcome()
  def offer_then_wake(task_queue, spawner, awaits, via, opts \\ []) do
    ensure = Keyword.get(opts, :ensure, &ProjectArchitect.ensure/2)

    awaits
    |> normalize()
    |> Enum.group_by(fn {repo, _n} -> repo end)
    |> Enum.map(fn {repo, pairs} ->
      offer_one(task_queue, spawner, repo, Enum.min(pairs), via, ensure)
    end)
    |> aggregate()
  end

  defp normalize({repo, n}) when is_binary(repo), do: [{repo, n}]
  defp normalize(%MapSet{} = awaits), do: MapSet.to_list(awaits)

  defp offer_one(task_queue, spawner, repo, {repo, n}, via, ensure) do
    pod_id = ProjectArchitect.pod_id_for(repo)

    case task_queue.pod_status(pod_id) do
      {:ok, :assigned} ->
        :busy

      {:ok, :pending} ->
        ensure_arch(ensure, repo, spawner, via)

        case wake(spawner, pod_id, via, "pending mandate never fetched → re-wake only") do
          :ok -> :woken_pending
          {:error, _} -> :wake_unreached
        end

      _free_or_terminal_or_never ->
        offer_fresh_mandate(task_queue, spawner, repo, n, pod_id, via, ensure)
    end
  end

  # Enqueue before any bootstrap/explicit wake to avoid a signal-without-content race.
  defp offer_fresh_mandate(task_queue, spawner, repo, n, pod_id, via, ensure) do
    case enqueue_mandate(task_queue, pod_id, repo, n) do
      :ok ->
        ensure_arch(ensure, repo, spawner, via)

        case wake(spawner, pod_id, via, "mandate #{repo}##{n} enqueued (arch was free)") do
          :ok -> :offered
          {:error, _} -> :wake_unreached
        end

      {:error, reason} ->
        Logger.warning(
          "ArchWake: [#{via}] mandate enqueue KO (#{repo}##{n}): #{inspect(reason)} — " <>
            "NO wake sent (signal without content is the spurious-wake race); label intact, net retries"
        )

        {:error, {:enqueue, reason}}
    end
  end

  # Fetch host-side through WorktreeSync: the architect's read-only code face cannot
  # write FETCH_HEAD itself. Include success/absence/failure in the mandate so arbitration
  # does not mistake a judge's description for direct access to the deliverable.
  defp deliverable_section(repo, n) do
    case fetch_refs().(repo, n) do
      {:ok, []} ->
        "\n\nLe livrable n'a AUCUNE branche sur la forge pour ce ticket : il n'y a rien à lire, " <>
          "l'escalade porte sur autre chose que du code livré."

      {:ok, refs} ->
        dir = Path.join(Fleet.Layout.face_root("code"), Fleet.Layout.project_name(repo))

        "\n\nLE LIVRABLE EST LISIBLE, va le voir avant d'arbitrer : les branches du ticket sont " <>
          "dans ta face code (`#{dir}`) sous #{Enum.map_join(refs, ", ", &"`#{&1}`")}. " <>
          "`git -C #{dir} diff main...<ref>` te donne le diff complet, `log --oneline` l'historique. " <>
          "Les rapports des juges DÉCRIVENT le livrable ; ils ne sont pas le livrable."

      {:error, reason} ->
        Logger.warning(
          "ArchWake: deliverable refs for #{repo}##{n} NOT fetched (#{inspect(reason)}) — " <>
            "the mandate says so; the arch arbitrates knowing it, or defers"
        )

        "\n\n⚠ LE LIVRABLE N'A PAS PU ÊTRE RENDU LISIBLE (#{inspect(reason)}). Tu n'as donc que " <>
          "les rapports des juges, qui décrivent un code que tu ne vois pas. DIS-LE dans ta réponse " <>
          "plutôt que d'arbitrer comme si tu l'avais lu — un verdict rendu sur une description " <>
          "présentée comme une lecture est le défaut que cette ligne existe pour éviter."
    end
  end

  # Default fetch catches WorktreeSync call exits. Overrides bypass that wrapper;
  # exceptions/throws are not normalized here.
  defp fetch_refs do
    Application.get_env(:lcars_fleet, :pilot_arch_deliverable_fetch, &total_fetch/2)
  end

  defp total_fetch(repo, n) do
    Fleet.Project.WorktreeSync.fetch_issue_refs(repo, n)
  catch
    :exit, reason -> {:error, {:sync_unavailable, reason}}
  end

  # Collapse outcomes for the historical cooldown interface; any successful wake wins.
  defp aggregate([outcome]), do: outcome

  defp aggregate(outcomes) do
    cond do
      :offered in outcomes -> :offered
      :woken_pending in outcomes -> :woken_pending
      true -> List.first(outcomes)
    end
  end

  # Returned ensure errors do not prevent a wake attempt; callback exceptions still propagate.
  defp ensure_arch(ensure, repo, spawner, via) do
    case ensure.(repo, spawner: spawner) do
      {:ok, _pod_id} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ArchWake: [#{via}] arch ensure for #{repo} KO (#{inspect(reason)}) — wake still attempted; " <>
            "label intact, net retries"
        )

        :ok
    end
  end

  defp enqueue_mandate(task_queue, pod_id, repo, n) do
    attrs = %{
      issue_id: "issue-#{n}",
      # Resolve the mandate role from the same capability authority as architect ensure.
      role: Fleet.Project.Roles.project_delegate_role(),
      brief:
        "Arbitrage requis : escalade sur l'issue `##{n}` de ton projet. Lis-la (`escalation_list` / " <>
          "`issue_status`), tranche avec ton humain, puis dis ta décision sur le fil " <>
          "(`issue_comment`) ou corrige+re-délègue (`issue_create` avec `supersedes: #{n}` — la " <>
          "fleet retire l'ancien ticket elle-même ; sans ça il repart en dispatch après ton " <>
          "submit_result).\n\n⚠ CE QUI RÉSOUT L'ESCALADE EST `submit_result`, ET RIEN D'AUTRE. " <>
          "Commenter, c'est parler ; c'est `submit_result` sur CE work-item qui draine le label " <>
          "`lcars-awaits-arch` et rend la main au poller. Si tu commentes et que tu t'arrêtes, le " <>
          "ticket reste en attente et la fleet te relance dessus indéfiniment — en croyant que tu " <>
          "n'as pas encore répondu." <>
          deliverable_section(repo, n),
      metadata: %{"awaits_arch" => true, "repo" => repo, "number" => n}
    }

    case task_queue.enqueue(pod_id, attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Only wake_pod's :ok permits a success outcome; it is not an end-to-end delivery acknowledgment.
  defp wake(spawner, pod_id, via, context) do
    case spawner.wake_pod(pod_id) do
      :ok ->
        Logger.info("ArchWake: [#{via}] #{context} → wake sent to #{pod_id}")
        :ok

      other ->
        Logger.warning(
          "ArchWake: [#{via}] #{context} — wake #{pod_id} UNREACHED (#{inspect(other)}); " <>
            "forge label intact, net retries, the ensure respawns the arch on the next trigger"
        )

        {:error, other}
    end
  end
end
