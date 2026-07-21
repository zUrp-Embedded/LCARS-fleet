defmodule Fleet.Spawner.Pod.TurnFlag do
  @moduledoc """
  Writes the `turn.flag` — the LOAD-BEARING RAIL of the flag-driven wake, an FS-I/O island extracted
  from the `Fleet.Spawner` facade.

  The in-pod monitor (`watch.sh`, armed by the agent via the native Monitor tool) watches
  `pod_dir/turn.flag` (bind-mounted = `~/turn.flag` on the pod side) and compares its CONTENT
  (`cur != last`): content that changes → "your turn" → the agent wakes WITHOUT send-keys. This
  module carries ONLY the flag write; the wake orchestration (trigger + arming of the ack-driven
  safety-net) stays in the facade (`Fleet.Spawner.wake_pod/1`), the send-keys fallback in the
  `Pod`'s kick loop.

  A mute flag (dir gone, perm, disk) is logged LOUD (warning, in `write/1`) but never fails the
  wake: the wake is re-derived by the send-keys fallback of the `Pod`'s kick loop and, last resort,
  by the result_deadline — a lost flag costs latency, never the turn. No state, no Port, no timer:
  one FS write. No dependency on `Fleet.Spawner.Pod` (no cycle).

  ## Contract (called by `Fleet.Spawner`)

  - `touch/1` — touches the flag from a `pod_info` (the `_info` clause without pod_dir = no-op).
  - `write/1` — writes a UNIQUE token into `pod_dir/turn.flag`; tested directly (the "proceed" path
    of `wake_pod` is never reached by StubBackend).

  **Last revised**: 2026-07-21
  """

  require Logger

  @doc """
  Touches the in-pod monitor's flag from a `pod_info` (map). With a binary `pod_dir` → `write/1`;
  without (incomplete info) → `:ok` no-op — no flag is written; the wake then rides the send-keys
  fallback + result_deadline alone.
  """
  @spec touch(map()) :: :ok
  def touch(%{pod_dir: pod_dir}) when is_binary(pod_dir), do: write(pod_dir)
  def touch(_info), do: :ok

  @doc """
  Touches the flag WITH an informational message: the flag carries `"<token> <message>"`
  and `watch.sh` emits the MESSAGE verbatim (instead of the fixed "ton tour"). The typed
  wake channel: "ton tour" = a mandate awaits (`get_work_item`); anything else = pure
  information (progress milestone), the agent must NOT pull. One line only (newlines
  flattened — the flag is a single-line contract).
  """
  @spec touch(map(), String.t()) :: :ok
  def touch(%{pod_dir: pod_dir}, message) when is_binary(pod_dir) and is_binary(message),
    do: write(pod_dir, message)

  def touch(_info, _message), do: :ok

  @doc """
  Writes a UNIQUE token into `pod_dir/turn.flag`. `watch.sh` compares the CONTENT (`cur != last`):
  a BARE ms can repeat (2 wakes in the same ms) → identical token → wake MISSED; the unique suffix
  (`System.unique_integer`) guarantees each write changes the content → always detected. `File.write`
  RETURNS `{:error, _}` (does not raise) on dir gone/perm/disk → we handle the RETURN. LOAD-BEARING
  rail: a mute flag = log-LOUD (warning), never a failure — the send-keys fallback + the
  result_deadline re-derive the wake; the miss costs latency, not the turn.
  """
  @spec write(Path.t(), String.t() | nil) :: :ok
  def write(pod_dir, message \\ nil) when is_binary(pod_dir) do
    flag = Path.join(pod_dir, "turn.flag")

    token =
      "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}"

    # Bare token → watch.sh emits the fixed "ton tour" (mandate wake, unchanged contract).
    # "<token> <message>" → watch.sh emits the message verbatim (informational wake).
    content =
      case message do
        nil -> token
        msg -> token <> " " <> String.replace(msg, ~r/\s*\n\s*/, " ")
      end

    case File.write(flag, content <> "\n") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "TurnFlag: write #{pod_dir}: flag write failed (#{inspect(reason)}) — flag rail mute this wake; send-keys fallback + result_deadline take over"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "TurnFlag: write #{pod_dir}: flag write exception (#{inspect(e)}) — flag rail mute this wake; send-keys fallback + result_deadline take over"
      )

      :ok
  end
end
