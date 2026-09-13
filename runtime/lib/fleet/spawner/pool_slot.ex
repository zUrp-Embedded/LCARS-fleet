defmodule Fleet.Spawner.PoolSlot do
  @moduledoc """
  Allocates session-ID pool nibbles per `(role, repo)` to keep concurrent identities distinct.
  Instance slots are 1..15; slot 0 matches `SessionMint`'s default for unmanaged pods and is
  reserved for project-scoped pods. Their uniqueness comes from their `<repo>-<role>` pod ID.

  Occupancy combines Registry values with live survivors recorded on disk. Reading values
  avoids GenServer calls to potentially hung pods. Exhaustion returns `:role_at_capacity`
  so dispatch can defer the ticket instead of exceeding the UUID format's capacity.
  """

  require Logger

  @reserved_slot 0
  @first_slot 1
  @format_capacity 0xF
  @default_max_per_role @format_capacity

  @doc """
  Per-role/repo cap from `:lcars_fleet, :spawner_max_pods_per_role`, default 15, clamped to 1..15.
  """
  @spec max_per_role() :: pos_integer()
  def max_per_role do
    :lcars_fleet
    |> Application.get_env(:spawner_max_pods_per_role, @default_max_per_role)
    |> min(@format_capacity)
    |> max(1)
  end

  @doc """
  Returns reserved slot 0 for `project` scope without reading occupancy. Otherwise returns
  the lowest free slot in `1..max_per_role/0`, or `{:error, :role_at_capacity}`.
  `repo` is the forge ID encoded in the session identity, or `nil` for an unbound pod.

  Call during child start under the same DynamicSupervisor: allocation and Registry publication
  rely on its serialized starts. This read-then-register sequence is not atomic itself;
  concurrent spawn callers must not allocate before starting their children.
  """
  @spec allocate(String.t(), integer() | nil, String.t()) ::
          {:ok, non_neg_integer()} | {:error, :role_at_capacity}
  def allocate(role, repo, slot_scope)

  def allocate(role, _repo, "project") when is_binary(role), do: {:ok, @reserved_slot}

  def allocate(role, repo, _instance) when is_binary(role) do
    taken = taken_slots(role, repo)
    max = max_per_role()

    case Enum.find(@first_slot..(@first_slot + max - 1), &(&1 not in taken)) do
      nil ->
        Logger.warning(
          "PoolSlot: role #{role} at capacity on #{inspect(repo)} " <>
            "(#{MapSet.size(taken)}/#{max} slots) — the spawn is DEFERRED, not failed"
        )

        {:error, :role_at_capacity}

      pool ->
        {:ok, pool}
    end
  end

  @doc """
  Preflight for the same bucket as `allocate/3`; project scope always has room.
  Avoids a forge lock/unlock cycle when already full. The answer can become stale;
  `allocate/3` still enforces capacity during serialized child start.
  """
  @spec has_free_slot?(String.t(), integer() | nil, String.t()) :: boolean()
  def has_free_slot?(role, repo, slot_scope)

  def has_free_slot?(role, _repo, "project") when is_binary(role), do: true

  def has_free_slot?(role, repo, _instance) when is_binary(role) do
    # Only allocatable slots count; a reserved 0 in the bucket must not consume capacity.
    taken = taken_slots(role, repo)
    max = max_per_role()

    Enum.any?(@first_slot..(@first_slot + max - 1), &(&1 not in taken))
  end

  @doc """
  Returns Registry slots union live survivors' snapshot slots for `(role, repo)`.

  A BEAM crash loses the Registry but can leave bwrap holders alive: their `sleep infinity`
  ignores stdin EOF. Snapshots cover the window before the warden's two-tick collection.
  Unreadable or slot-less snapshots and survivors not confirmed alive are skipped.

  Test seams: `:state_fs_root` and `:alive_fun` (`pod_id -> boolean`, default `PodTmux.alive?/1`).
  The default liveness check invokes tmux, unlike the Registry-only part.
  """
  @spec taken_slots(String.t(), integer() | nil, keyword()) :: MapSet.t(non_neg_integer())
  def taken_slots(role, repo, opts \\ []) when is_binary(role) do
    MapSet.union(registry_slots(role, repo), surviving_slots(role, repo, opts))
  end

  defp registry_slots(role, repo) do
    Fleet.Spawner.Registry
    |> Registry.select([{{:_, :_, :"$1"}, [], [:"$1"]}])
    |> Enum.reduce(MapSet.new(), fn
      %{role: ^role, repo: ^repo, pool: pool}, acc when is_integer(pool) -> MapSet.put(acc, pool)
      _other, acc -> acc
    end)
  end

  defp surviving_slots(role, repo, opts) do
    alive? = Keyword.get(opts, :alive_fun, &Fleet.Spawner.PodTmux.alive?/1)
    root = Fleet.Spawner.Pod.Paths.state_fs_root_for(opts)

    root
    |> Path.join("*/*/state.json")
    |> Path.wildcard()
    |> Enum.reduce(MapSet.new(), fn path, acc ->
      pod_id = path |> Path.dirname() |> Path.basename()

      with {:ok, json} <- File.read(path),
           {:ok, %{"slot" => %{"role" => ^role, "repo" => ^repo, "pool" => pool}}} <-
             Jason.decode(json),
           true <- is_integer(pool),
           true <- alive?.(pod_id) do
        MapSet.put(acc, pool)
      else
        _ -> acc
      end
    end)
  end
end
