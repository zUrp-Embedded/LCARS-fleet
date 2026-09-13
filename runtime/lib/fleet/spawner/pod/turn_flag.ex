defmodule Fleet.Spawner.Pod.TurnFlag do
  @moduledoc """
  Writes the `turn.flag` watched by the in-pod Monitor.

  Every write uses distinct content so consecutive wakes are observable. Write failures are logged
  but return `:ok`; tmux kick and response deadline provide fallback where enabled by the profile.
  """

  require Logger

  @doc """
  Writes the flag when pod info contains a directory; otherwise does nothing.
  """
  @spec touch(map()) :: :ok
  def touch(%{pod_dir: pod_dir}) when is_binary(pod_dir), do: write(pod_dir)
  def touch(_info), do: :ok

  @doc """
  Writes a single-line informational wake message after the unique token.
  """
  @spec touch(map(), String.t()) :: :ok
  def touch(%{pod_dir: pod_dir}, message) when is_binary(pod_dir) and is_binary(message),
    do: write(pod_dir, message)

  def touch(_info, _message), do: :ok

  @doc """
  Writes a unique token and optional flattened message. Failures are logged and remain non-fatal.
  """
  @spec write(Path.t(), String.t() | nil) :: :ok
  def write(pod_dir, message \\ nil) when is_binary(pod_dir) do
    flag = Path.join(pod_dir, "turn.flag")

    token =
      "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}"

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

  @doc """
  Whether non-empty `turn.flag` and `turn.flag.seen` match after trimming whitespace.
  watch.sh records .seen after emitting the wake: this acknowledges Monitor delivery, not an
  agent get_work_item response. An informational turn may need no pull; delivery stops redundant
  wake input anyway. Missing/unreadable files or mismatches return false, leaving fallback eligible.
  """
  @spec delivered?(Path.t()) :: boolean()
  def delivered?(pod_dir) when is_binary(pod_dir) do
    flag = Path.join(pod_dir, "turn.flag")
    seen = Path.join(pod_dir, "turn.flag.seen")

    case {File.read(flag), File.read(seen)} do
      {{:ok, f}, {:ok, s}} ->
        ft = String.trim(f)
        ft != "" and ft == String.trim(s)

      _ ->
        false
    end
  end

  def delivered?(_), do: false

  @doc """
  Whether `turn.flag.seen` exists. watch.sh creates its baseline when arming, before any wake;
  Pod uses this to stop bootstrap engage. Unlike `delivered?/1`, no particular turn is acknowledged.
  Launch calls `reset/1` to remove stale acknowledgements, including on resumed pods.
  """
  @spec monitor_armed?(Path.t() | nil) :: boolean()
  def monitor_armed?(pod_dir) when is_binary(pod_dir),
    do: File.exists?(Path.join(pod_dir, "turn.flag.seen"))

  def monitor_armed?(_), do: false

  @doc """
  Removes turn.flag and turn.flag.seen at launch to prevent acknowledgements surviving a restart.
  Removal errors are ignored; returns `:ok`.
  """
  @spec reset(Path.t() | nil) :: :ok
  def reset(pod_dir) when is_binary(pod_dir) do
    _ = File.rm(Path.join(pod_dir, "turn.flag"))
    _ = File.rm(Path.join(pod_dir, "turn.flag.seen"))
    :ok
  end

  def reset(_), do: :ok
end
