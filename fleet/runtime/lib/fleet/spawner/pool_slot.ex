defmodule Fleet.Spawner.PoolSlot do
  @moduledoc """
  Allocates the `pool` nibble of a pod's `session_id`, and CAPS the concurrency of a role.

  ## Why the nibble was dead

  `Fleet.Spawner.SessionId` reserves a high nibble for a "pool" (`<P><R>`, 16 values) — measured
  2026-08-03: **no caller ever passed it**, so it was always `0` and two concurrent pods of the
  same role shared their `session_id`. Harmless while a repo ran one producer at a time (the
  `pod_id` carried the uniqueness), and a latent lie the day producers fan out per ticket.

  ## What this module decides

  The lowest FREE index in `0..14` among the live pods of the same `(role, repo)`. Fifteen slots,
  not sixteen: `0xF` stays unallocated on purpose — a reserved value is what lets a future reader
  tell "no slot" from "slot zero" without a second field, and it costs one sixteenth of a
  concurrency nobody reaches today.

  Beyond the cap: `{:error, :role_at_capacity}` — a TYPED refusal that the caller turns into a
  skip, so the ticket STACKS and retries on the next tick. Never a raise: `SessionId.encode/5`
  guards `pool in 0..0xF`, so an unchecked 16th allocation would have crashed the spawn with a
  `FunctionClauseError` — a format ceiling must be hit like a ceiling, not like a bug.

  ## Where the truth lives

  The **Registry value**, not a GenServer call. Each pod registers `%{role, repo, pool}` at
  start-up, so the allocation reads live state without talking to a single pod — a hung pod can
  no longer block the spawn of another. It is also why the pool is decided at the SPAWN site and
  passed in: the value must be known before the process registers.

  **Last revised**: 2026-08-03
  """

  require Logger

  # 0..14 allocatable; 0xF reserved (see moduledoc). SINGLE authority for the default.
  @reserved_slot 0xF
  @default_max_per_role 15

  @doc """
  Max concurrent pods for ONE `(role, repo)` — config `:fleet_spawner, :max_pods_per_role`,
  default 15. Clamped to the format's capacity: the nibble cannot hold more, whatever the config
  says (a config that promises 20 would promise a crash).
  """
  @spec max_per_role() :: pos_integer()
  def max_per_role do
    :fleet_spawner
    |> Application.get_env(:max_pods_per_role, @default_max_per_role)
    |> min(@reserved_slot)
    |> max(1)
  end

  @doc """
  Allocates a free pool index for `(role, repo)`.

  `{:ok, pool}` | `{:error, :role_at_capacity}`. `repo` is the pod's `owner/name` (or `nil` for an
  unbound pod): the cap is per (role, repo), because two projects competing for one role's slots
  would starve each other for no reason — the nibble is per-repo in the session_id too.
  """
  @spec allocate(String.t(), String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, :role_at_capacity}
  def allocate(role, repo) when is_binary(role) do
    taken = taken_slots(role, repo)
    max = max_per_role()

    case Enum.find(0..(max - 1), &(&1 not in taken)) do
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

  @doc "Live pool indexes held by `(role, repo)` — read from the Registry values, no pod is called."
  @spec taken_slots(String.t(), String.t() | nil) :: MapSet.t(non_neg_integer())
  def taken_slots(role, repo) when is_binary(role) do
    Fleet.Spawner.Registry
    |> Registry.select([{{:_, :_, :"$1"}, [], [:"$1"]}])
    |> Enum.reduce(MapSet.new(), fn
      %{role: ^role, repo: ^repo, pool: pool}, acc when is_integer(pool) -> MapSet.put(acc, pool)
      _other, acc -> acc
    end)
  end

  @doc """
  Boot-time coherence of the two ceilings — the BRAKE.

  A per-role cap the global cap cannot hold produces skips nobody can explain: the role never
  reaches its own limit, it just gets refused by a ceiling that names something else. Rather than
  discover it on a wedged fleet, the incoherence is stated at boot, once, LOUD. Not a refusal:
  a small `max_pods` is a legitimate operator choice (a laptop) — but it must be a CHOSEN one.
  """
  @spec check_ceilings!() :: :ok
  def check_ceilings! do
    global = Fleet.Spawner.max_pods()
    per_role = max_per_role()

    if per_role > global do
      Logger.warning(
        "PoolSlot: max_pods_per_role=#{per_role} EXCEEDS max_pods=#{global} — a role will be " <>
          "refused by the GLOBAL ceiling before reaching its own, and the skip will name the " <>
          "wrong limit. Raise max_pods, or lower max_pods_per_role."
      )
    end

    :ok
  end
end
