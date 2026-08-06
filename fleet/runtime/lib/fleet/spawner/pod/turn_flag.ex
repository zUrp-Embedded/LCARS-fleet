defmodule Fleet.Spawner.Pod.TurnFlag do
  @moduledoc """
  Writes the `turn.flag` watched by the in-pod Monitor.

  Every write uses distinct content so consecutive wakes are observable. Write failures are logged
  but return `:ok`; the tmux kick and response deadline remain the fallback rails.
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
end
