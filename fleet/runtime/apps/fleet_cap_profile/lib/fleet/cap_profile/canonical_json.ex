defmodule Fleet.CapProfile.CanonicalJson do
  @moduledoc """
  CANONICAL (deterministic) JSON encoding + sha256 hash — the cap-profile's
  "composition determinism" concern, ORTHOGONAL to the rest of the app: it
  touches neither the loader (`load`/`compose`/`validate`), nor the struct
  accessors, nor the FS catalogue. Extracted from `Fleet.CapProfile` for that
  reason.

  ## Why a canonical encoder (and not `Jason.encode!` directly)

  Two EQUAL maps (same key/value pairs) may iterate in different orders
  depending on their construction history — `Jason.encode!` would then produce
  two different strings, hence two different sha256 for THE SAME composition.
  The canonical encoder makes the hash independent of iteration order: keys
  converted to strings then sorted RECURSIVELY before encoding. That is what
  carries the "same composition ⇒ same hash" assertion that callers of
  `Fleet.CapProfile.sha256/1` verify.

  ## FROZEN format (the hash depends on it)

  The encoding is a stable HASHING format: `{"k":v,...}` sorted, lists in
  order, scalars via `Jason.encode!`. Changing it invalidates every sha256
  already observed (determinism assertions, composition comparisons).
  Deliberately NOT a custom `Jason.Encoder` protocol: off the standard Jason
  path, no global encoding option can make the hashes drift.
  """

  @doc """
  Encodes `value` into canonical JSON: map keys stringified then sorted
  recursively, lists encoded in order, scalars via the standard JSON encoder.
  Structs are NOT accepted in map position (no clause: the caller flattens them
  into a plain map first — see `Fleet.CapProfile.sha256/1`) — encoding a struct
  by its internal fields would silently produce a hash that depends on the
  struct shape, not on the data.
  """
  @spec encode(term()) :: String.t()
  def encode(map) when is_map(map) and not is_struct(map) do
    pairs =
      map
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {to_string(k), encode(v)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> Jason.encode!(k) <> ":" <> v end)
      |> Enum.join(",")

    "{" <> pairs <> "}"
  end

  def encode(list) when is_list(list) do
    inner = list |> Enum.map(&encode/1) |> Enum.join(",")
    "[" <> inner <> "]"
  end

  def encode(other), do: Jason.encode!(other)

  @doc """
  sha256 (lowercase hex) of the canonical encoding of `map`. The map's internal
  iteration order has no effect — same content ⇒ same hash.
  """
  @spec sha256(map()) :: String.t()
  def sha256(map) when is_map(map) and not is_struct(map) do
    map
    |> encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
