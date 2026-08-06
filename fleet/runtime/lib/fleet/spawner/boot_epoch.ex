defmodule Fleet.Spawner.BootEpoch do
  @moduledoc """
  Identity of the CURRENT BEAM boot (a per-fleet-life nonce) — the discriminator that separates
  a POD-level recovery from a FLEET-level restart (reorg 2026-07-19, live scar):

    * a `state.json` snapshot stamped with the CURRENT epoch = the pod died while THIS fleet was
      alive (crash/wedge) → the fresh-reroll recovery doctrine applies (`Recovery.apply_recovery`,
      never resume a dead pod's accumulated session);
    * a snapshot from a PREVIOUS epoch (clean `fleet_v2 stop`, fleet crash — the whole BEAM was
      down) = a STALE snapshot: nothing was mid-flight in this fleet life, so the unified seed
      decision (`Pod.maybe_slot_resume`: live jsonl → resume in place; seed → resume from it)
      applies exactly as on a first boot. Without this discriminator, a clean stop left a
      non-terminal `state.json` (`monitoring`) and EVERY reboot fell into `:recreate` — the slot
      and the context never came back (proven live 2026-07-19: starfleet rebooted `resume=0`).

  Initialized ONCE by `Fleet.Spawner.Application.init/1` (before any pod starts — no init race);
  `id/0` is a cheap `:persistent_term` read. Old snapshots without the field compare `nil` ≠
  current → stale epoch (correct: they predate this fleet life by construction).
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
