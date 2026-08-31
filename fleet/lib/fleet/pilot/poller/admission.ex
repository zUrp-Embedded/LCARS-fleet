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

  # How many workflow_runs one PROJECT may have in flight at once. Per project and not fleet-wide:
  # the thing being protected is a repo's merge surface, and two projects do not race each other's
  # base. Ceiling 15 = the pool slots a role actually has (`PoolSlot`, seats 1..15, seat 0 reserved)
  # — asking for a 16th producer is asking for a slot that does not exist.
  @default_max_fan 5
  @max_max_fan 15

  @doc """
  The FLEET default ceiling on workflow_runs in flight **PER HUMAN** — `:lcars_fleet,
  :pilot_max_fan`, default #{@default_max_fan}, clamped to `1..#{@max_max_fan}`. A project that
  declares its own throughput overrides it: `max_fan/2` is what a dispatch decision reads.

  **PER HUMAN, BY DESIGN — et ce n'est pas une fuite du filtre.** Le compte se fait sur la liste que
  le poller a obtenue avec `assigned_by=<son humain>`, donc deux humains sur un depot tiennent deux
  budgets. C'est le modele de la fleet, entier : un architect est un agent DE l'humain, cape par
  uid ; les pods, le feed, le scoping le sont aussi. Une config centrale qui accorde un quota PAR
  UTILISATEUR est la forme ordinaire de la chose (quotas disque, rate-limit par cle), et l'endroit
  ou la valeur est DECLAREE ne dit rien de QUI elle borne.

  ⚠ Ecrit ici parce que l'intuition inverse — « c'est declare dans le fichier du projet, donc ca
  borne le projet » — se tire toute seule, et une fois au point d'ouvrir un chantier pour un defaut
  qui n'existe pas. Ce qui borne le DEPOT est ailleurs et se nomme : les sieges de
  pool par `(role, repo)`, et le fusible `Spawner.max_pods` (128) en dernier ressort.

  **Serial is this ceiling at 1**, not another mechanism. The boolean it replaces
  (`:repo_serialized_lease`) and this counter are the same parameter at two resolutions, which is
  why such a boolean can only ever say "one" or "as many as there are" — and "as many as there are"
  is genuinely UNBOUNDED: a repo with forty queued tickets starts forty runs.

  Clamped rather than refused HERE because this is read on every dispatch decision (a tick, then a
  ticket): a value that fails must fail at a DOOR, once — `runtime.exs` for the env, the flag parser
  for `--max-fan` — not on a rail that would then log the same complaint every thirty seconds. The
  clamp is the belt behind those doors, never the place a mistake is reported.
  """
  @spec max_fan() :: pos_integer()
  def max_fan do
    :lcars_fleet
    |> Application.get_env(:pilot_max_fan, @default_max_fan)
    |> case do
      n when is_integer(n) -> n |> max(1) |> min(@max_max_fan)
      _ -> @default_max_fan
    end
  end

  @doc """
  The ceiling for THIS project: its declaration if it made one, the fleet default otherwise.

  The item this closes, in one sentence: the counter was per project and the knob was per box, so
  `--max-fan 1` to watch one pipeline end to end serialized every other project in the fleet —
  a brake laid on unrelated work. The declaration lives in `<project>/.lcars.json` (see
  `ProjectDeclaration`) because a project can route its tickets through several cards, and a
  per-card ceiling cannot bound something that spans them.

  Clamped HERE and only here: `max_fan/0` and this share one authority for `1..#{@max_max_fan}`,
  so a declaration cannot buy a 16th pool seat that does not exist.
  """
  @spec max_fan(String.t(), keyword()) :: pos_integer()
  def max_fan(repo, opts \\ []) when is_binary(repo) do
    case Fleet.Project.Declaration.declared_max_fan(repo, opts) do
      n when is_integer(n) -> n |> max(1) |> min(@max_max_fan)
      _ -> max_fan()
    end
  end

  @doc "The hard ceiling `max_fan` is clamped to — single source for the doors that validate it."
  @spec max_fan_ceiling() :: pos_integer()
  def max_fan_ceiling, do: @max_max_fan

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
    forge = Keyword.get(opts, :forge_client, Fleet.Forge.Client)
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
