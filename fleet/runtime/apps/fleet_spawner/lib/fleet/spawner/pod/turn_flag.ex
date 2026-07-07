defmodule Fleet.Spawner.Pod.TurnFlag do
  @moduledoc """
  Writes the `turn.flag` — the LOAD-BEARING RAIL of the flag-driven wake, an FS-I/O island extracted
  from the `Fleet.Spawner` façade.

  The in-pod monitor (`watch.sh`, armed by the agent via the native Monitor tool) watches
  `pod_dir/turn.flag` (bind-mounted = `~/turn.flag` on the pod side) and compares its CONTENT
  (`cur != last`): content that changes → "your turn" → the agent wakes WITHOUT send-keys. This
  module carries ONLY the flag write; the wake orchestration (trigger + arming of the ack-driven
  safety-net) stays in the façade (`Fleet.Spawner.wake_pod/1`), the send-keys fallback in the
  `Pod`'s kick loop.

  Best-effort by contract: a mute flag (dir gone, perm, disk) is logged LOUD but never fails the
  wake — the send-keys fallback + the result_deadline catch up. No state, no Port, no timer: one FS
  write. No dependency on `Fleet.Spawner.Pod` (no cycle).

  ## Contract (called by `Fleet.Spawner`)

  - `touch/1` — touches the flag from a `pod_info` (the `_info` clause without pod_dir = no-op).
  - `write/1` — writes a UNIQUE token into `pod_dir/turn.flag`; tested directly (the "proceed" path
    of `wake_pod` is never reached by StubBackend).
  """

  require Logger

  @doc """
  Touches the in-pod monitor's flag from a `pod_info` (map). With a binary `pod_dir` → `write/1`;
  without (incomplete info) → `:ok` no-op — the wake stays best-effort.
  """
  @spec touch(map()) :: :ok
  def touch(%{pod_dir: pod_dir}) when is_binary(pod_dir), do: write(pod_dir)
  def touch(_info), do: :ok

  @doc """
  Writes a UNIQUE token into `pod_dir/turn.flag`. `watch.sh` compares the CONTENT (`cur != last`):
  a BARE ms can repeat (2 wakes in the same ms) → identical token → wake MISSED; the unique suffix
  (`System.unique_integer`) guarantees each write changes the content → always detected. `File.write`
  RETURNS `{:error, _}` (does not raise) on dir gone/perm/disk → we handle the RETURN. LOAD-BEARING
  rail: a mute flag = log-LOUD, never a failure (best-effort — send-keys fallback + result_deadline
  catch up).
  """
  @spec write(Path.t()) :: :ok
  def write(pod_dir) when is_binary(pod_dir) do
    flag = Path.join(pod_dir, "turn.flag")

    token =
      "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}"

    case File.write(flag, token <> "\n") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "TurnFlag: write #{pod_dir}: écriture flag échouée (#{inspect(reason)}) — rail porteur muet (best-effort)"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "TurnFlag: write #{pod_dir}: exception écriture flag (#{inspect(e)}) — rail porteur muet (best-effort)"
      )

      :ok
  end
end
