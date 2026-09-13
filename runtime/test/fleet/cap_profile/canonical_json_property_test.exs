defmodule Fleet.CapProfile.CanonicalJsonPropertyTest do
  @moduledoc """
  Checks JSON round-trip fidelity, atom/string key equivalence and rejection of key
  collisions, including nested maps. Stability alone would also accept an encoder that
  consistently drops data. The sampled distinct-hash check is not a proof that SHA-256
  has no collisions; round-trip fidelity concerns the encoding, not hash injectivity.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.CapProfile.CanonicalJson

  defp json_scalar do
    one_of([
      string(:printable, max_length: 8),
      integer(),
      float(),
      boolean(),
      constant(nil)
    ])
  end

  defp json_key, do: string(:alphanumeric, min_length: 1, max_length: 6)

  defp json_value do
    tree(json_scalar(), fn child ->
      one_of([list_of(child, max_length: 3), map_of(json_key(), child, max_length: 3)])
    end)
  end

  defp json_map, do: map_of(json_key(), json_value(), max_length: 5)

  # Bound String.to_atom/1 to at most 155 keys to avoid growing the atom table without limit.
  defp small_key, do: string([?a..?e], min_length: 1, max_length: 3)

  property "P1 FIDELITY — Jason.decode!(encode(m)) == m (canonicalization loses NOTHING)" do
    check all(m <- json_map(), max_runs: 300) do
      assert Jason.decode!(CanonicalJson.encode(m)) == m
    end
  end

  # Detects degenerate hashing on sampled maps, not mathematical collision freedom.
  property "P1b INJECTIVITY — two different maps ⇒ two different sha256" do
    check all(m1 <- json_map(), m2 <- json_map(), max_runs: 200) do
      if m1 != m2 do
        assert CanonicalJson.sha256(m1) != CanonicalJson.sha256(m2)
      end
    end
  end

  property "P1c — atom key ⇒ homonymous string key, value intact, SAME hash" do
    check all(m <- map_of(small_key(), json_scalar(), max_length: 5)) do
      atom_map = Map.new(m, fn {k, v} -> {String.to_atom(k), v} end)

      assert Jason.decode!(CanonicalJson.encode(atom_map)) == m
      assert CanonicalJson.sha256(atom_map) == CanonicalJson.sha256(m)
    end
  end

  # Distinct Elixir keys must not become duplicate JSON keys with ambiguous values.
  property "P2 COLLISION GUARD — atom key :k + string key \"k\" ⇒ encode/1 ALWAYS raises" do
    check all(
            k <- small_key(),
            v1 <- json_scalar(),
            v2 <- json_scalar(),
            noise <- json_map()
          ) do
      colliding =
        noise
        |> Map.delete(k)
        |> Map.put(k, v1)
        |> Map.put(String.to_atom(k), v2)

      assert_raise ArgumentError, fn -> CanonicalJson.encode(colliding) end
      assert_raise ArgumentError, fn -> CanonicalJson.sha256(colliding) end
    end
  end

  property "P2b — the collision guard holds inside a NESTED map" do
    check all(k <- small_key(), outer <- small_key(), v1 <- json_scalar(), v2 <- json_scalar()) do
      nested = %{outer => %{k => v1, String.to_atom(k) => v2}}

      assert_raise ArgumentError, fn -> CanonicalJson.encode(nested) end
    end
  end
end
