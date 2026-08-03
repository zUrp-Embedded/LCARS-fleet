defmodule Fleet.Pilot.Poller.Admission do
  @moduledoc """
  THE passage point of the two dispatch rails — issues (`Lease.process_issues`) and pulls
  (`Poller.step_process_pulls`).

  ## Why it exists

  There are two entry points into dispatch, and every TRANSVERSE rule had to be written twice with
  nothing checking that it was. The asymmetry ran in both directions and cost real behaviour: the
  in-flight count lived on the issues rail only (repaired in the commit before this one — a repo
  serialized to one workflow_run started a second as soon as the first reached its jury), while the
  wait-label convergence was written on the pulls rail and forgotten on the lease branch. Two rules,
  two rails, two different omissions, and both were invisible until someone counted.

  So the rule is not "remember to write it twice". The rule is that a transverse decision has ONE
  home and both rails traverse it. What lives here:

    * the **accounting** of a dispatch result (tally + whether the lease was taken),
    * the **wait vocabulary** (`wait/*`) — when to write it, when to remove it, when to say nothing,
    * the **current wait label** of a ticket, read the same way on both sides.

  What does NOT live here: the lease arithmetic (who holds it, who waits) is the issues rail's own
  business, and the pulls rail has no equivalent.

  ## The wall

  This funnel cannot force a future rule to be written inside it — no test can. What holds is
  narrower and mechanical: `Fleet.Pilot.Poller.AdmissionTest` MEASURES `lib/` and refuses a second
  site that maps a dispatch result to a tally. A rail that starts accounting on its own reddens,
  which is the moment a rule is about to be duplicated.

  **Last revised**: 2026-08-03
  """

  require Logger

  alias Fleet.Pilot.Poller.Lease

  @doc """
  Runs one dispatch and accounts for it: calls `dispatch_fun`, converges the ticket's `wait/*` from
  the result, and folds the result into `acc`.

  Returns `{tally, started?}`. `started?` is the LEASE fact and not a success fact — the two rails
  read it differently and only one of them reads it at all. The canonical spawn order is
  lock -> pod -> enqueue -> WAKE, so `{:error, {:wake_unreached, _}}` means the workflow_run IS
  started (lease taken) while the anomaly still counts as an error. The pulls rail ignores
  `started?`: the judges of an already-active run are not an entry.

  `issue_number` is `nil` for anything that is not one of our tickets (a foreign PR whose branch
  does not parse) — the wait convergence then does nothing, which is correct and not a side effect.
  """
  @spec admit((-> term()), keyword(), integer() | nil, String.t() | nil, Lease.tally()) ::
          {Lease.tally(), boolean()}
  def admit(dispatch_fun, opts, issue_number, current_wait, acc)
      when is_function(dispatch_fun, 0) do
    result = dispatch_fun.()
    _ = converge_wait(opts, issue_number, current_wait, result)
    {account(result, acc), started?(result)}
  end

  @doc """
  Accounts for an item the rail refuses WITHOUT dispatching it — the lease branches, and tomorrow
  the `max_fan` ceiling.

  Same funnel as `admit/5`, and that is the point: a refusal is a decision about a ticket, so it
  owes that ticket the same wait vocabulary a dispatched skip does. These two branches were the
  ones the convergence had never reached — a ticket held back by the lease waited silently, tick
  after tick, indistinguishable from a forgotten one.

  Always `{tally, false}`: refusing takes nothing.
  """
  @spec refuse(atom() | tuple(), keyword(), integer() | nil, String.t() | nil, Lease.tally()) ::
          {Lease.tally(), boolean()}
  def refuse(reason, opts, issue_number, current_wait, acc) do
    admit(fn -> {:skipped, reason} end, opts, issue_number, current_wait, acc)
  end

  # ONE mapping for both rails. `{:ok, _}` covers `{:spawned, _, _}` (a producer or a judge) AND
  # `{:merged, _}` (a PR sealed by the pulls rail) — the issues rail cannot produce the second, and
  # matching it here costs nothing while a rail-local mapping that omits it raises.
  defp account({:ok, _}, acc), do: %{acc | dispatched: acc.dispatched + 1}
  defp account({:skipped, _reason}, acc), do: %{acc | skipped: acc.skipped + 1}
  defp account({:error, _reason}, acc), do: %{acc | errors: acc.errors + 1}

  # The lease is taken by anything that got as far as a pod, INCLUDING an unreachable wake: the lock
  # is placed and the pod exists, so a second start on that repo would be a duplicate. A real
  # dispatch failure compensated the lock and killed the pod -> nothing started.
  defp started?({:ok, _}), do: true
  defp started?({:error, {:wake_unreached, _pod_id, _role, _reason}}), do: true
  defp started?(_), do: false

  @doc """
  Converges the `wait/*` label of ticket `number` from its `current` value and a dispatch `result`.

  THE single write point of the wait vocabulary — both rails call it, so the two halves cannot
  drift into two dialects. The issues rail reads `current` off the payload it already listed; the
  PR rail reads it from the `issue -> wait/*` map the tick threads alongside `awaits_arch_ids`.
  Neither pays a forge call to know it.
  """
  @spec converge_wait(keyword(), integer() | nil, String.t() | nil, term()) :: :ok
  def converge_wait(_opts, nil, _current, _result), do: :ok

  def converge_wait(opts, number, current, result) do
    case wait_transition(current, desired_wait_label(result)) do
      :noop -> :ok
      op -> write_wait(opts, number, op)
    end
  end

  @doc """
  The PURE rule of the wait label: `current` (on the ticket) + `desired` (from the dispatch) ->
  `:noop | {:add, label} | {:remove, label}`.

  Extracted with no I/O for the same reason `ForgeClient.route_from_labels/1` was: a decision buried
  under a forge call is a decision nobody can exercise. Every branch below is reachable from a test
  without a network.

  `:keep` is NOT a third label, it is the ABSENCE of an opinion — a dispatch error says nothing
  about what a ticket is waiting for, and writing on it would turn a failure into a "wait".
  """
  @spec wait_transition(String.t() | nil, String.t() | nil | :keep) ::
          :noop | {:add, String.t()} | {:remove, String.t()}
  def wait_transition(_current, :keep), do: :noop
  # `(same, same)` also covers `(nil, nil)`: nothing carried, nothing wanted, nothing to do. An
  # explicit `(nil, nil)` clause would be dead — and dead code lies without the compiler saying so.
  def wait_transition(same, same), do: :noop
  def wait_transition(current, nil), do: {:remove, current}
  def wait_transition(_current, desired), do: {:add, desired}

  @doc """
  The `wait/*` label a ticket currently carries, or `nil`. Read from labels ALREADY in hand — the
  issues rail holds them on the payload, the tick projects them into a map for the pulls rail. One
  derivation, because two ways of answering "what is this ticket waiting for" is how the two rails
  earned their two dialects in the first place.
  """
  @spec current_wait(map() | nil) :: String.t() | nil
  def current_wait(payload) when is_map(payload) do
    prefix = Fleet.Labels.wait_prefix()

    (payload["labels"] || [])
    |> Enum.map(& &1["name"])
    |> Enum.find(&(is_binary(&1) and String.starts_with?(&1, prefix)))
  end

  def current_wait(_), do: nil

  defp desired_wait_label({:ok, _}), do: nil
  defp desired_wait_label({:error, _}), do: :keep

  defp desired_wait_label({:skipped, reason}) do
    Fleet.Labels.wait_for(reason)
  rescue
    # `wait_for/1` raises on a reason absent from the table — that is the WALL, and a test that
    # measures `lib/` holds it. In production we degrade rather than abort a whole tick over a
    # label: the trace is missing, the dispatch goes on. The red belongs to the gate, not the rail.
    ArgumentError ->
      Logger.warning(
        "Poller: skip reason #{inspect(reason)} absent from the BL-6-48 wait table — " <>
          "no label written (the tick stands; the exhaustiveness test is what must go red)"
      )

      :keep
  end

  defp write_wait(opts, number, op) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    repo = Keyword.get(opts, :repo)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    _ =
      case op do
        {:add, label} -> forge.add_label(repo, number, label, forge_opts)
        {:remove, label} -> forge.remove_label(repo, number, label, forge_opts)
      end

    :ok
  rescue
    # Best-effort by obligation: a label that cannot be posted must never block a dispatch. The
    # trace is missing, the work goes through.
    e ->
      Logger.warning(
        "Poller: wait label #{inspect(op)} on ##{number} failed (#{inspect(e)}) — dispatch unaffected"
      )

      :ok
  end
end
