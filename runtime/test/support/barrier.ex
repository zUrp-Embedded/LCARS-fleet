defmodule Fleet.Test.Barrier do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Synchronization helper using `:sys.get_state/2` with a 30-second timeout.
  The longer budget tolerates suite contention while staying below ExUnit's default
  60-second deadline, so a stuck server is diagnosed by the barrier first.

  Use after messages sent by the same test process to a GenServer. It does not wait for
  background work started by a handler or establish ordering across independent senders.
  A timeout exit can also kill a linked server and leave shared test state behind.
  """

  @barrier_timeout 30_000

  @doc """
  Returns the server state through a system request, or exits if it cannot answer
  within the barrier timeout.
  """
  @spec settle(GenServer.server()) :: term()
  def settle(server), do: :sys.get_state(server, @barrier_timeout)
end
