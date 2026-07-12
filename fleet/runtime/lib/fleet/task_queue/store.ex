defmodule Fleet.TaskQueue.Store do
  @moduledoc """
  `state.json` persistence of the broker — serialization + FS, extracted from
  `Fleet.TaskQueue.Server` (the GenServer keeps the orchestration: WHEN to persist,
  WHAT to reload; this module ONLY knows how to read/write a map of work items).

  No process, no GenServer state: both operations take a `path` and a
  `%{id => %WorkItem{}}` map as explicit arguments.

  ## Contract

    * `save/2` — ATOMIC write (tmp + rename) of the versioned schema `v: 1`.
      **Non-blocking on the WRITE side**: a write failure is logged at **error**
      (durability of the recovery point is broken) but still returns `:ok` —
      we do not crash the broker over a disk blip; reconciliation goes through
      the forge-driven rail (re-dispatch from the forge state), not through
      this local persistence.
    * `load/1` — **fail-loud on the READ side**: a `state.json` that is
      unparseable, of an unexpected version, or carrying a non-deserializable
      work item returns `{:corrupt, found}` (never a silent drop of part of the
      state); the Server turns it into a non-blocking fallback (empty state +
      `:"state.corrupt"` event).
    * `default_path/0` — where `state.json` lives when the caller does not set it.

  The decision NOT to persist (`persist: false`, ephemeral prod mode) or to load
  empty stays in the Server: it depends on its boot options, not on the file
  format.
  """

  require Logger

  alias Fleet.TaskQueue.WorkItem

  @doc """
  Default path of `state.json`: config `:fleet_task_queue, :state_path`,
  otherwise `~/.lcars/task-queue/state.json`.

  The fleet runs under the human → home-relative default `~/.lcars/task-queue`, like the pod
  state_fs_root (`Fleet.Spawner.Pod.default_state_fs_root`): a hardcoded `/var/lib/lcars`
  would not be ownable outside the `lcars` account. Unresolvable HOME = broken runtime →
  fail-loud (`System.user_home!()` raises), never a fabricated path: the .lcars state must
  not scatter silently.
  """
  @spec default_path() :: Path.t()
  def default_path do
    Application.get_env(
      :fleet_task_queue,
      :state_path,
      Path.join(System.user_home!(), ".lcars/task-queue/state.json")
    )
  end

  @doc """
  Writes the map of work items to `path` — atomic write (tmp + rename),
  schema `%{"v" => 1, "work_items" => %{id => WorkItem.to_map(t)}}`.

  ALWAYS returns `:ok` (a write failure never propagates). A write failure breaks the durability
  of the cross-restart recovery point — this is a logged ERROR, not a warning: the RAM queue
  moves forward but state.json diverges → a restart would re-read a stale state. We do NOT
  crash the broker (a transient disk blip must not kill the in-flight work items);
  the truth of the work is the FORGE — on restart the queue re-derives itself from the
  forge polls (canonical reconciliation rail). The breach becomes LOUD
  (error-level → monitoring), no more silent degradation.
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
  Reads and deserializes `state.json` from `path`.

    * `:empty` — file absent (`:enoent`): first boot, nothing to reload.
    * `{:ok, %{id => %WorkItem{}}}` — valid `v: 1` schema, all work items deserialized.
    * `{:corrupt, found}` — unreadable file, unparseable JSON, version ≠ 1, or a
      non-deserializable work item (corrupt state / required field absent). Fail-loud:
      we HALT on the 1st corrupt work item rather than FILTERING it out (state silently
      truncated); `WorkItem.from_map` returns `{:error, _}` instead of RAISING (the
      Server's `:corrupt` fallback holds).
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

  # fail-loud: a non-deserializable task → `{:corrupt, ...}`, NOT a silent drop.
  # `reduce_while` HALTS on the 1st corrupt task rather than FILTERING it out (state
  # silently truncated).
  defp decode_work_items(work_items_map) do
    Enum.reduce_while(work_items_map, {:ok, %{}}, fn {id, tm}, {:ok, acc} ->
      case WorkItem.from_map(tm) do
        {:ok, t} -> {:cont, {:ok, Map.put(acc, id, t)}}
        {:error, reason} -> {:halt, {:corrupt, {:work_item, id, reason}}}
      end
    end)
  end
end
