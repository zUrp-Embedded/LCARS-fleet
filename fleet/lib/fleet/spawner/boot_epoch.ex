defmodule Fleet.Spawner.BootEpoch do
  @moduledoc """
  Per-BEAM-boot identity distinguishing same-life pod failure from a fleet restart.
  Current-epoch snapshots use fresh recovery; stale or unstamped snapshots use the
  normal seed decision. Initialized before any pod starts.
  """

  @key {__MODULE__, :id}

  @doc "Stamps the current fleet life's epoch id (idempotent within a BEAM boot)."
  @spec init() :: :ok
  def init do
    case :persistent_term.get(@key, nil) do
      nil ->
        id =
          "boot-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

        :persistent_term.put(@key, id)
        :ok

      _already ->
        :ok
    end
  end

  @doc "The current fleet life's epoch id (self-initializes defensively if `init/0` never ran)."
  @spec id() :: String.t()
  def id do
    case :persistent_term.get(@key, nil) do
      nil ->
        :ok = init()
        :persistent_term.get(@key)

      id ->
        id
    end
  end
end
