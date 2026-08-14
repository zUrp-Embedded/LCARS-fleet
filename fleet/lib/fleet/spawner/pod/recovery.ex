defmodule Fleet.Spawner.Pod.Recovery do
  @moduledoc """
  Pure recovery decisions for a deliberately respawned pod.

  Terminal snapshots release without relaunch. Every non-terminal or ambiguous snapshot recreates a
  fresh session; recovery never resumes a dead backend mid-flight.
  """

  @doc """
  Maps terminal phases to `:release` and every other phase to `:recreate`.
  """
  @spec recovery_action(atom()) :: :release | :recreate
  def recovery_action(phase) do
    if phase in [:succeeded, :released, :killed], do: :release, else: :recreate
  end

  @doc """
  Projects the recovery decision into fresh pod state.

  The snapshot's `session_id` is NOT a parameter, and its absence is the contract: recovery does
  not resume, so the persisted identity has no say in the decision. It used to be passed and
  ignored by both clauses — a signature claiming a say that the body never took, which reads as an
  oversight rather than as the doctrine it is. The caller still matches on it to validate the
  snapshot's shape; that is a different job.
  """
  @spec apply_recovery(map(), :recreate | :release, atom()) :: map()
  def apply_recovery(base, :recreate, _phase), do: Map.put(base, :recovery, :recreate)

  def apply_recovery(base, :release, phase) do
    base |> Map.put(:phase, phase) |> Map.put(:recovery, :release)
  end

  @doc """
  Returns the only valid startup continuation: fresh allocation or terminal release.
  """
  @spec first_continue_for(map()) :: :allocate | :release
  def first_continue_for(%{recovery: :recreate}), do: :allocate
  def first_continue_for(%{recovery: :release}), do: :release
  def first_continue_for(_fresh_or_corrupt), do: :allocate

  @doc """
  Maps a startup continuation to its gen_statem phase.
  """
  @spec continue_to_phase(:allocate | :release) :: :allocating | :releasing
  def continue_to_phase(:allocate), do: :allocating
  def continue_to_phase(:release), do: :releasing

  @doc """
  Decodes a snapshot phase to an existing atom, or returns `nil`.
  """
  @spec phase_from_string(term()) :: atom() | nil
  def phase_from_string(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  def phase_from_string(_), do: nil
end
