defmodule Fleet.Pilot.Poller.Lease do
  @moduledoc """
  Classifies issues and admits new workflow runs under Admission.max_fan/2.
  Poller supplies human-scoped listings, so the limit is per human and repository;
  the default is five, and one gives serial entry. It is an admission check against
  a snapshot and this pass's starts, not a cross-process reservation.

  Open-PR issue IDs count as occupied seats independently of the issue listing.
  Other issues are engaged when locked or routed beyond the first step. Missing
  workflow data conservatively holds a seat; routeless/first-step issues are queued.
  Existing engaged runs continue even at capacity. Awaiting the architect does not
  itself change lease classification: an advanced run retains its seat.

  Queued candidates are considered by ascending issue number. With capacity, read
  dependencies before dispatch; open numbered blockers and unreadable responses
  refuse that entry without consuming a seat. Existing runs bypass this check.
  Admission separates an unsuccessful wake from whether the run already started.

  Seams carry dependencies; Poller retains cross-tick state. This module also owns
  zero_tally/0 and merge_tally/2. On the dispatched path, the wrapped payload has no
  top-level number or labels, so its admission call currently skips wait writes;
  pre-dispatch refusals pass the original issue number.
  """

  alias Fleet.Forge.Payload
  alias Fleet.Pilot.Poller.Admission

  @in_flight Fleet.Labels.in_flight()

  defmodule Seams do
    @moduledoc """
    Dependencies supplied by the caller; production resolves defaults in Poller.
    Enforced keys require presence, not non-nil values or valid implementations.
    """
    @enforce_keys [:forge, :repo, :forge_opts, :workflow_map_loader, :incident_fun]
    defstruct [
      # Forge client (concrete module — the test override is resolved upstream).
      :forge,
      # Repo "owner/name" of the current iteration of the multi-project scan.
      :repo,
      # Forge opts (base_url, token…).
      :forge_opts,
      # Workflow loader module; safe_load supplies catalogue-aware options.
      :workflow_map_loader,
      # Escalation of an unreadable workflow_map (arity 4) — never nil here.
      :incident_fun,
      # Injectable dispatcher keeps lease arithmetic testable independently.
      dispatcher: Fleet.Pilot.StepDispatcher
    ]

    @type t :: %__MODULE__{
            forge: module(),
            repo: String.t(),
            forge_opts: keyword(),
            workflow_map_loader: module(),
            dispatcher: module(),
            incident_fun: (String.t(), String.t(), term(), keyword() -> term())
          }
  end

  @typedoc "Counters of a tick: items dispatched / skipped / in error."
  @type tally :: %{
          dispatched: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc "Blank tally."
  @spec zero_tally() :: tally()
  def zero_tally, do: %{dispatched: 0, skipped: 0, errors: 0}

  @doc "Field-by-field tally sum."
  @spec merge_tally(tally(), tally()) :: tally()
  def merge_tally(a, b) do
    %{
      dispatched: a.dispatched + b.dispatched,
      skipped: a.skipped + b.skipped,
      errors: a.errors + b.errors
    }
  end

  @doc """
  Classifies and dispatches issues under the repository lease.
  """
  @spec process_issues([map()], MapSet.t(), keyword(), Seams.t()) :: tally()
  def process_issues(issues, pr_issue_ids, dispatch_opts, %Seams{} = seams) do
    # Classify once, prefetch the route/card for dispatch, then order by issue number.
    classified =
      issues
      |> Enum.map(fn issue ->
        pr? = MapSet.member?(pr_issue_ids, Map.get(issue, "number"))
        {engaged, prefetch} = classify_issue(issue, pr?, seams)
        {issue, pr?, engaged, prefetch}
      end)
      |> Enum.sort_by(fn {issue, _pr?, _engaged, _pf} -> Map.get(issue, "number") end)

    # The declaration applies across cards in this repo; dispatch_opts carries test code_root.
    max_fan = Admission.max_fan(seams.repo, dispatch_opts)

    # Count open-PR IDs too: their issue classification deliberately reports not engaged,
    # so the two categories do not double-count that ticket. Awaiting-arch alone
    # changes neither category; advanced routes retain seats until their run advances.
    in_flight =
      Enum.count(classified, fn {_issue, _pr?, engaged, _pf} -> engaged end) +
        MapSet.size(pr_issue_ids)

    # Ascending issue number is stable across forge reorderings. Seed the counter with
    # existing runs and increment only for newly started entries, not continued work.
    {tally, _fan} =
      Enum.reduce(classified, {zero_tally(), in_flight}, fn
        {issue, pr?, engaged, prefetch}, {acc, fan} ->
          payload = wrap_issue_as_payload(issue, seams.repo)
          item_opts = Keyword.merge(dispatch_opts, prefetch)
          wait = Admission.current_wait(payload)

          cond do
            # PR work already occupies a seat and advances through the pulls path.
            pr? ->
              {acc2, _} = Admission.refuse(:pr_open, item_opts, issue["number"], wait, acc)
              {acc2, fan}

            # Continuing an already-counted run must not consume another entry slot.
            engaged ->
              {acc2, _started?} =
                step_do_dispatch(payload, item_opts, acc, seams.dispatcher)

              {acc2, fan}

            # Record capacity refusal on the ticket.
            fan >= max_fan ->
              {acc2, _} = Admission.refuse(:at_capacity, item_opts, issue["number"], wait, acc)
              {acc2, fan}

            # Check dependencies before investing work that the forge might refuse to close.
            # Only new starts face this gate; engaged runs continue.
            true ->
              dispatch_unless_blocked(
                open_blockers(issue, seams),
                {payload, item_opts, issue["number"], wait},
                {acc, fan},
                seams
              )
          end
      end)

    tally
  end

  # Query dependencies only for new candidates with capacity. A blocked or unreadable
  # response refuses this ticket, allowing other candidates to proceed. Only starts
  # consume seats; both refusals use wait/depends with distinct diagnostic reasons.
  defp dispatch_unless_blocked({:ok, []}, {payload, item_opts, _n, _wait}, {acc, fan}, seams) do
    {acc2, started?} = step_do_dispatch(payload, item_opts, acc, seams.dispatcher)
    {acc2, if(started?, do: fan + 1, else: fan)}
  end

  defp dispatch_unless_blocked({:ok, [blocker | _]}, {_p, item_opts, n, wait}, {acc, fan}, _seams) do
    {acc2, _} = Admission.refuse({:depends, blocker}, item_opts, n, wait, acc)
    {acc2, fan}
  end

  defp dispatch_unless_blocked({:error, why}, {_p, item_opts, n, wait}, {acc, fan}, _seams) do
    {acc2, _} = Admission.refuse({:depends_unreadable, why}, item_opts, n, wait, acc)
    {acc2, fan}
  end

  defp open_blockers(issue, %Seams{} = seams) do
    case seams.forge.issue_dependencies(seams.repo, Map.get(issue, "number"), seams.forge_opts) do
      {:ok, deps} when is_list(deps) ->
        {:ok,
         deps
         |> Enum.filter(&(Map.get(&1, "state") == "open"))
         |> Enum.map(&Map.get(&1, "number"))
         |> Enum.reject(&is_nil/1)}

      other ->
        {:error, other}
    end
  end

  # Account for wake errors separately from already-started work.
  # The wrapper stores number/labels under issue; these top-level reads currently
  # produce nil, disabling wait convergence on the dispatch path.
  defp step_do_dispatch(payload, opts, acc, dispatcher) do
    Admission.admit(
      fn -> dispatcher.dispatch_issue(payload, opts) end,
      opts,
      payload["number"],
      Admission.current_wait(payload),
      acc
    )
  end

  # Classify and prefetch route/card from listed labels. Open-PR tickets are counted
  # separately; locks bypass route lookup. Unexpected route shapes hold a seat.
  defp classify_issue(_issue, true = _pr?, _seams), do: {false, []}

  defp classify_issue(issue, false = _pr?, seams) do
    labels = Payload.label_names(issue)

    if @in_flight in labels do
      {true, []}
    else
      # No network route read here: derive from listed labels. Network get_route
      # callers must separately handle transport failures.
      case seams.forge.route_from_labels(Payload.labels(issue)) do
        {:ok, {workflow_map_name, step} = route}
        when is_binary(workflow_map_name) and is_binary(step) ->
          # An unreadable card cannot prove the route is at its first step: hold the
          # seat and pass the same nil prefetch to dispatch for failure reporting.
          workflow_map = load_workflow_map_or_nil(workflow_map_name, seams)
          engaged = is_nil(workflow_map) or not first_step?(workflow_map, step)
          {engaged, [prefetched_route: route, prefetched_workflow_map: workflow_map]}

        :none ->
          {false, [prefetched_route: nil]}

        _ ->
          # An unexpected parser result leaves engagement unknown: retain a seat.
          {true, []}
      end
    end
  end

  # Return nil on a safe_load error and attempt to report the missing card.
  defp load_workflow_map_or_nil(workflow_map_name, seams) do
    # Use the shared loader boundary, retaining this caller's lease/escalation policy.
    case Fleet.Pilot.WorkflowMapNav.safe_load(
           seams.workflow_map_loader,
           workflow_map_name,
           Fleet.Workflow.Loader.card_opts_for_repo(seams.repo)
         ) do
      {:ok, map} ->
        map

      {:error, {:workflow_map_load_failed, _name, message}} ->
        # Report repeated load failure through the incident registry while holding
        # the conservative lease. Its return is ignored; each failed load tries again.
        _ = escalate_workflow_map_incident(workflow_map_name, message, seams)
        nil
    end
  end

  defp escalate_workflow_map_incident(workflow_map_name, message, seams) do
    seams.incident_fun.(
      "workflow_map_load",
      workflow_map_name,
      {:workflow_map_load_failed, message},
      forge_opts: seams.forge_opts
    )
  rescue
    # Rescue exceptions only; throws and exits from an injected callback propagate.
    _ -> :escalation_skipped
  end

  # A loaded card with no identifiable first step is treated as queued.
  # This differs from a nil card, which holds the lease before reaching here.
  defp first_step?(workflow_map, step) do
    case Fleet.Pilot.WorkflowMapNav.first_step(workflow_map) do
      {:ok, {first, _role}} -> step == first
      _ -> true
    end
  end

  # Shapes the payload expected by `StepDispatcher.dispatch_issue` (the issue + its origin repo).
  defp wrap_issue_as_payload(issue, repo) do
    %{
      "issue" => issue,
      "repository" => %{"full_name" => repo}
    }
  end
end
