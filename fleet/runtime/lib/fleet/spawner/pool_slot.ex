defmodule Fleet.Spawner.PoolSlot do
  @moduledoc """
  Allocates the `pool` nibble of a pod's `session_id`, and CAPS the concurrency of a role.

  ## Why the nibble was dead

  `Fleet.Spawner.SessionId` reserves a high nibble for a "pool" (`<P><R>`, 16 values) — measured
  2026-08-03: **no caller ever passed it**, so it was always `0` and two concurrent pods of the
  same role shared their `session_id`. Harmless while a repo ran one producer at a time (the
  `pod_id` carried the uniqueness), and a latent lie the day producers fan out per ticket.

  ## What this module decides

  The lowest FREE index in `1..15` among the live pods of the same `(role, repo)`. Fifteen slots,
  not sixteen: index **0 is RESERVED** and never allocated.

  Reserving 0 rather than 0xF is not cosmetic. `SessionMint` already mints `pool: 0` for every
  caller that does not allocate, so the reserved value is the one the un-allocated ALREADY carry:
  the reservation needs no new default, and every session_id minted before this module existed
  (the nibble was measured never-allocated, so all of them) reads retroactively as what it was —
  a pod outside the managed fan-out. Reserving the top value instead would have required changing
  that default AND left the whole history claiming a slot it never held.

  The seat is for a pod that is deliberately NOT a fan-out member — a producer held for the life
  of a project rather than a ticket. Note what the seat does and does not buy: such a pod is
  distinguished by its `slot_scope` (`project` ⟹ a `<repo>-<role>` pod id of its own), not by its
  nibble, so the reservation is not what MAKES it possible — it is what makes it READABLE from a
  session_id alone, with no second field to consult.

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

  # The nibble holds 16 values. Index 0 is RESERVED (see moduledoc), 1..15 are allocatable — so the
  # FORMAT's capacity is 15 concurrent pods for one (role, repo), and that is also the config's
  # ceiling. SINGLE authority for all four.
  @reserved_slot 0
  @first_slot 1
  @format_capacity 0xF
  @default_max_per_role @format_capacity

  @doc """
  Max concurrent pods for ONE `(role, repo)` — config `:fleet_spawner, :max_pods_per_role`,
  default 15. Clamped to the format's capacity: the nibble cannot hold more, whatever the config
  says (a config that promises 20 would promise a crash).
  """
  @spec max_per_role() :: pos_integer()
  def max_per_role do
    :fleet_spawner
    |> Application.get_env(:max_pods_per_role, @default_max_per_role)
    |> min(@format_capacity)
    |> max(1)
  end

  @doc """
  Allocates the pool index of a pod, from its `slot_scope`.

  `project` ⟹ the RESERVED seat, without reading anything: such a pod is not a fan-out member, so
  it neither competes for a slot nor consumes one. Its uniqueness is already carried by its pod id
  (`<repo>-<role>`, one per repo), so the seat can be handed to every project-keyed pod at once
  without collision. This is where the reservation stops being decorative: the seat has an
  occupant, and it is derived — no declaration names a role.

  `instance` ⟹ the lowest free index in `1..max_per_role/0` for `(role, repo)`, or
  `{:error, :role_at_capacity}`.

  `repo` is the pod's forge repo id (`nil` for an unbound pod): the cap is per (role, repo),
  because two projects competing for one role's slots would starve each other for no reason. The
  ID and not the `owner/name` — it is what the `session_id` encodes (`<REPO4>`), so bucket and
  identity designate the same object instead of coexisting.

  CALLED FROM THE CHILD'S START, under the supervisor. Read-then-write has no atomicity of its own:
  two concurrent allocators of the same (role, repo) would both see the same lowest free index and
  hand it out twice — two live pods sharing a session_id, the exact lie this module exists to end,
  and a silent one. The serialization is not added here, it is INHERITED: `DynamicSupervisor.
  start_child/2` is synchronous, so allocation and the registration that publishes it happen in the
  same window, with no other pod start able to interleave. Which is why this must not be called
  from the spawn CALLER's process (`Fleet.Spawner.spawn_pod/3` runs in whoever called it — the
  poller, the admin API — and two of those can run at once).
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
  Is there a free slot RIGHT NOW? The pre-flight twin of `allocate/3`, for the dispatcher's
  admission gate for the ceiling that actually shapes the queue: the per-role seats.

  Takes the SAME three arguments as `allocate/3` on purpose: a pre-flight that interrogates a
  different bucket than the wall is worse than no pre-flight, because it defers on a ceiling that
  is not the one that will refuse. A `project` pod always has room — it holds the reserved seat.

  It is an OPTIMIZATION, never the enforcement: the answer can be stale by the time the spawn runs,
  and the real refusal stays in `allocate/3`, inside the serialized start. What it buys is the
  difference between deferring BEFORE the forge lock and discovering saturation after it — a
  lock/unlock cycle per issue per tick, and "full" tallied as an error instead of a wait.
  """
  @spec has_free_slot?(String.t(), integer() | nil, String.t()) :: boolean()
  def has_free_slot?(role, repo, slot_scope)

  def has_free_slot?(role, _repo, "project") when is_binary(role), do: true

  def has_free_slot?(role, repo, _instance) when is_binary(role) do
    # Counts the ALLOCATABLE range only, never the raw set size. A `0` sitting in the bucket must
    # not eat a slot: the reserved seat is outside the cap by definition. Homogeneity of a bucket
    # (`slot_scope` is a property of the role, so project and instance pods never share one) makes
    # that case unreachable today — which is exactly why the count must not DEPEND on it. An
    # invariant held elsewhere is a rule to maintain; counting the right range is a property.
    taken = taken_slots(role, repo)
    max = max_per_role()

    Enum.any?(@first_slot..(@first_slot + max - 1), &(&1 not in taken))
  end

  @doc "Live pool indexes held by `(role, repo)` — read from the Registry values, no pod is called."
  @spec taken_slots(String.t(), integer() | nil) :: MapSet.t(non_neg_integer())
  def taken_slots(role, repo) when is_binary(role) do
    Fleet.Spawner.Registry
    |> Registry.select([{{:_, :_, :"$1"}, [], [:"$1"]}])
    |> Enum.reduce(MapSet.new(), fn
      %{role: ^role, repo: ^repo, pool: pool}, acc when is_integer(pool) -> MapSet.put(acc, pool)
      _other, acc -> acc
    end)
  end
end
