defmodule Fleet.Spawner.SessionId do
  @moduledoc """
  Pure encoder of deterministic pod session IDs. Role indexes and kill classes come from
  `Fleet.CapProfile`; spawn policy belongs to `Fleet.Spawner.Pod.SessionMint`.

  Format: `<X>badcafe-<UID>-4dad-babe-<REPO4>dec0de<P><R>`

  - `<X>`: hexadecimal kill class; lower classes are more expensive to lose.
    `badcafe` identifies fleet sessions. Anchor process-kill patterns on `claude.*`:
    a bare `pkill -f <class>badcafe` can also kill a grep carrying that pattern in its argv.
  - `<UID>`: runtime human's OS UID, four decimal digits. It distinguishes humans sharing
    an OAuth account, since the Desktop slot sees OAuth + UUID, not the OS account.
  - `4dad-babe`: fixed filler with a valid UUID v4 version and variant.
  - `<REPO4>`: forge repo ID, four decimal digits; `0000` denotes fleet scope.
  - `dec0de`: fixed filler.
  - `<P><R>`: hexadecimal pool and role-index nibbles. Pool 0 is reserved for project-scoped
    or unmanaged pods; `PoolSlot` allocates instance slots 1..15.

  UID and repo must fit `0..9999`. This is a deployment constraint: container user namespaces
  may use larger UIDs. Widen the format if needed; modulo or recycling repo IDs would let one
  human or project resume another's conversation. Decimal fields allow direct ID searches.

  The scheme depends on the vendor accepting well-formed, non-random v4 UUIDs for session IDs.
  Server-side entropy or vendor-issued-ID validation would break it; this encoder cannot
  guarantee acceptance and does not provide a fallback.
  """
  import Bitwise

  @uuid_v4_re ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  @doc """
  Validates an explicit seed or override as a lowercase RFC4122 v4 UUID before launch/persistence.
  Checks shape only: random UUIDs also pass, without validating the deterministic field meanings.
  """
  @spec cast(term()) :: {:ok, String.t()} | {:error, :not_uuid_shaped}
  def cast(sid) when is_binary(sid) do
    if Regex.match?(@uuid_v4_re, sid), do: {:ok, sid}, else: {:error, :not_uuid_shaped}
  end

  def cast(_), do: {:error, :not_uuid_shaped}

  @doc """
  Encodes `(role_index, kill_class, uid, repo[, pool])` into a deterministic hexspeak UUID.

  Nibbles are in `0..15`; decimal UID and repo fields are in `0..9999`. Out-of-range
  caller input raises by function-clause rather than being folded into a colliding identity.
  """
  @spec encode(0..15, 0..15, 0..9999, 0..9999, 0..0xF) :: String.t()
  def encode(role_index, kill_class, uid, repo, pool \\ 0)
      when is_integer(role_index) and role_index in 0..15 and
             is_integer(kill_class) and kill_class in 0..15 and
             is_integer(uid) and uid in 0..9999 and
             repo in 0..9999 and pool in 0..0xF do
    xx = bsl(pool, 4) ||| role_index

    "#{hex(kill_class, 1)}badcafe-#{dec(uid, 4)}-4dad-babe-#{dec(repo, 4)}dec0de#{hex(xx, 2)}"
  end

  defp hex(n, width),
    do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  defp dec(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")
end
