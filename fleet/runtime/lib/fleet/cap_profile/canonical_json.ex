defmodule Fleet.CapProfile.CanonicalJson do
  @moduledoc """
  Deterministic JSON encoding and SHA256 hashing for capability profiles.

  Map keys are stringified and sorted recursively, lists retain their order,
  and scalars use Jason. The encoding is a stable hashing format; stringified
  key collisions raise instead of producing ambiguous JSON.
  """

  @doc """
  Encodes a value as canonical JSON. Plain maps, lists, and JSON scalars are accepted.
  """
  @spec encode(term()) :: String.t()
  def encode(map) when is_map(map) and not is_struct(map) do
    pairs =
      map
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {to_string(k), encode(v)} end)
      |> Enum.sort_by(&elem(&1, 0))

    keys = Enum.map(pairs, &elem(&1, 0))

    unless keys == Enum.uniq(keys) do
      raise ArgumentError,
            "CanonicalJson: key collision after stringification " <>
              "(#{inspect(keys -- Enum.uniq(keys))}) — ambiguous canonical form, cannot hash deterministically"
    end

    body = Enum.map_join(pairs, ",", fn {k, v} -> Jason.encode!(k) <> ":" <> v end)

    "{" <> body <> "}"
  end

  def encode(list) when is_list(list) do
    inner = Enum.map_join(list, ",", &encode/1)
    "[" <> inner <> "]"
  end

  def encode(other), do: Jason.encode!(other)

  @doc """
  Returns the lowercase SHA256 of a plain map's canonical encoding.
  """
  @spec sha256(map()) :: String.t()
  def sha256(map) when is_map(map) and not is_struct(map) do
    map
    |> encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
