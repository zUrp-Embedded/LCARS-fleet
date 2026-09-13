defmodule Fleet.Pilot.Poller.Admission do
  @moduledoc """
  Shared result accounting and wait-label policy for issue and PR dispatch.
  Lease owns admission arithmetic; the PR path advances existing runs without
  charging their started? result as new entries.

  AdmissionTest scans for a known tally-update syntax outside this module. That
  guard detects duplication of the established pattern, not every possible rewrite.
  """

  require Logger

  alias Fleet.Forge.Payload
  alias Fleet.Pilot.Poller.Lease

  @doc """
  Calls dispatch_fun, attempts wait-label convergence, then returns {tally, started?}.
  A successful result counts as dispatched. The wake_unreached four-field error
  counts as an error while taking a lease: lock, pod and enqueue preceded wake.
  Other errors do not count as started. PR callers ignore started?.

  A nil issue_number disables wait writes, as for an unrecognized PR branch.
  Callback exceptions/throws/exits can interrupt this sequence.
  """
  @spec admit((-> term()), keyword(), integer() | nil, String.t() | nil, Lease.tally()) ::
          {Lease.tally(), boolean()}
  def admit(dispatch_fun, opts, issue_number, current_wait, acc)
      when is_function(dispatch_fun, 0) do
    result = dispatch_fun.()
    _ = converge_wait(opts, issue_number, current_wait, result)
    {account(result, acc), started?(result)}
  end

  # Per-human, per-repository entry ceiling; separate projects have separate budgets.
  # The upper bound follows the 15 numbered pool seats, not a promise of free capacity.
  @default_max_fan 5
  @max_max_fan 15

  @doc """
  Reads :pilot_max_fan, default #{@default_max_fan}, clamped to 1..#{@max_max_fan}.
  The budget applies per human on each repository because Poller supplies
  human-filtered listings. A project-level declaration changes that value, not
  its ownership scope; different humans have separate budgets.

  Serial admission is max_fan 1. Pool seats and Spawner.max_pods impose additional
  capacity limits. Invalid settings should be reported at configuration/CLI entry;
  this hot-path reader clamps integers and defaults other values without logging.
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
  Uses the project's .lcars.json declaration, falling back to max_fan/0.
  Project scope lets one project serialize without affecting others, and spans
  all its workflow cards. The budget still applies per human.
  Declared integers are clamped to 1..#{@max_max_fan}.
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
  Accounts for refusal before dispatch through the same wait policy as admit/5.
  PR-open, capacity and dependency refusals return {tally, false}: no entry started.
  """
  @spec refuse(atom() | tuple(), keyword(), integer() | nil, String.t() | nil, Lease.tally()) ::
          {Lease.tally(), boolean()}
  def refuse(reason, opts, issue_number, current_wait, acc) do
    admit(fn -> {:skipped, reason} end, opts, issue_number, current_wait, acc)
  end

  # Count all successful result shapes, including PR merge/adoption, in one place.
  defp account({:ok, _}, acc), do: %{acc | dispatched: acc.dispatched + 1}
  defp account({:skipped, _reason}, acc), do: %{acc | skipped: acc.skipped + 1}
  defp account({:error, _reason}, acc), do: %{acc | errors: acc.errors + 1}

  # Wake failure is the specific error shape that still consumes an entry lease.
  defp started?({:ok, _}), do: true
  defp started?({:error, {:wake_unreached, _pod_id, _role, _reason}}), do: true
  defp started?(_), do: false

  @doc """
  Attempts to update the ticket's wait label from the supplied current value and
  result; nil numbers skip writes. Callers supply already-listed labels.
  Returned forge errors are discarded; write exceptions are logged and rescued,
  but exits and throws propagate. Success here does not prove a label was written.
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
  Computes noop, add or remove from current and desired wait state.
  :keep means no opinion: dispatch errors must not invent or clear an expectation.
  Replacing one label with another only adds the new one, relying on the forge's
  configured scope exclusivity to remove the previous label.
  """
  @spec wait_transition(String.t() | nil, String.t() | nil | :keep) ::
          :noop | {:add, String.t()} | {:remove, String.t()}
  def wait_transition(_current, :keep), do: :noop
  # Equality covers nil/nil as well as an unchanged label.
  def wait_transition(same, same), do: :noop
  def wait_transition(current, nil), do: {:remove, current}
  def wait_transition(_current, desired), do: {:add, desired}

  @doc """
  Returns the first wait-prefixed label found in the payload, or nil.
  This does not repair or diagnose multiple wait labels.
  """
  @spec current_wait(map() | nil) :: String.t() | nil
  def current_wait(payload) when is_map(payload) do
    prefix = Fleet.Labels.wait_prefix()

    payload
    |> Payload.label_names()
    |> Enum.find(&String.starts_with?(&1, prefix))
  end

  def current_wait(_), do: nil

  defp desired_wait_label({:ok, _}), do: nil
  defp desired_wait_label({:error, _}), do: :keep

  defp desired_wait_label({:skipped, reason}) do
    Fleet.Labels.wait_for(reason)
  rescue
    # Unknown skip reasons retain the current label and warn; source-level tests
    # check the known vocabulary without aborting a production tick here.
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
    # Rescue write exceptions so label failure does not prevent result accounting.
    e ->
      Logger.warning(
        "Poller: wait label #{inspect(op)} on ##{number} failed (#{inspect(e)}) — dispatch unaffected"
      )

      :ok
  end
end
