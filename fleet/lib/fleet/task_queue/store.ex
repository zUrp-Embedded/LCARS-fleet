defmodule Fleet.TaskQueue.Store do
  @moduledoc """
  Version-1 `state.json` serialization for the task queue.

  Writes are atomic and non-blocking: failures are logged and return `:ok`.
  Reads are all-or-nothing: malformed state or any invalid work item returns
  `{:corrupt, found}`. Persistence policy remains owned by the server.
  """

  require Logger

  alias Fleet.TaskQueue.WorkItem

  @doc """
  Returns the configured state path or `~/.lcars/task-queue/state.json`.
  """
  # `fetch_env/2` + explicit fallback, NOT `get_env/3`. The third argument of `get_env/3` is an
  # ordinary function argument: it is evaluated on EVERY call, whether or not the key is set. With
  # `System.user_home!()` in it, a deployment that configures `:task_queue_state_path` still pays
  # the `!` — and an unresolvable HOME raises while building a default the caller will discard.
  # A fallback that costs something must only run when it is the answer.
  @spec default_path() :: Path.t()
  def default_path do
    case Application.fetch_env(:lcars_fleet, :task_queue_state_path) do
      {:ok, path} -> path
      :error -> Path.join(System.user_home!(), ".lcars/task-queue/state.json")
    end
  end

  @doc """
  Atomically writes a version-1 work-item map.

  Write failures are logged at error level and flattened to `:ok`.
  """
  @spec save(Path.t(), %{optional(String.t()) => WorkItem.t()}) :: :ok
  def save(path, work_items) when is_binary(path) and is_map(work_items) do
    data = %{
      "v" => 1,
      "work_items" => Map.new(work_items, fn {id, t} -> {id, WorkItem.to_map(t)} end)
    }

    try do
      File.mkdir_p!(Path.dirname(path))
      tmp = path <> ".tmp"
      File.write!(tmp, Jason.encode!(data))
      File.rename!(tmp, path)
    rescue
      e ->
        Logger.error(
          "Store: persist FAILED — recovery point durability broken (non-fatal, " <>
            "forge-driven reconciliation; path=#{path}): #{inspect(e)}"
        )
    end

    :ok
  end

  @doc """
  Loads all work items, returning `:empty`, `{:ok, items}`, or `{:corrupt, found}`.
  """
  @spec load(Path.t()) ::
          :empty | {:ok, %{optional(String.t()) => WorkItem.t()}} | {:corrupt, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> decode_state(content)
      {:error, :enoent} -> :empty
      {:error, reason} -> {:corrupt, reason}
    end
  end

  defp decode_state(content) do
    case Jason.decode(content) do
      {:ok, %{"v" => 1, "work_items" => work_items_map}} when is_map(work_items_map) ->
        decode_work_items(work_items_map)

      {:ok, %{"v" => v}} ->
        {:corrupt, v}

      _ ->
        {:corrupt, :unparseable}
    end
  end

  defp decode_work_items(work_items_map) do
    Enum.reduce_while(work_items_map, {:ok, %{}}, fn {id, tm}, {:ok, acc} ->
      case WorkItem.from_map(tm) do
        {:ok, t} -> {:cont, {:ok, Map.put(acc, id, t)}}
        {:error, reason} -> {:halt, {:corrupt, {:work_item, id, reason}}}
      end
    end)
  end
end
