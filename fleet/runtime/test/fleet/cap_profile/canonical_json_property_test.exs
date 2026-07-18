defmodule Fleet.CapProfile.CanonicalJsonPropertyTest do
  @moduledoc """
  Property-based proof of the canonical encoder. The 3 properties already in place
  (`cap_profile_test.exs`) prove hash STABILITY — same content ⇒ same sha256, whatever
  the insertion order. None proves FIDELITY: an encoder that would LOSE an entry (or
  clobber one) would pass ALL THREE, since it would lose the same entry deterministically.

  This file closes that hole. A cap-profile's sha256 is its IDENTITY (composition
  comparison, determinism assertions): a stable hash sitting on an amputated encoding
  means two DIFFERENT profiles carrying the same identity — exactly the ambiguity the
  module's anti-collision guard already refuses to mint, from the other end.

  (Fidelity `decode ∘ encode == id` implies the encoder's INJECTIVITY: two distinct
  contents cannot hash the same. That is what "stable" alone does not say.)
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.CapProfile.CanonicalJson

  # ── generators ──

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

  # Recursive JSON value (nested maps/lists) — the real shape of a composed cap-profile
  # (`permissions`, `knowledge`, `modop_set`… are subtrees).
  defp json_value do
    tree(json_scalar(), fn child ->
      one_of([list_of(child, max_length: 3), map_of(json_key(), child, max_length: 3)])
    end)
  end

  defp json_map, do: map_of(json_key(), json_value(), max_length: 5)

  # Deliberately NARROW charset: the collision properties' keys go through
  # `String.to_atom/1` — the atom table must not swell (≤ 155 possible atoms here).
  defp small_key, do: string([?a..?e], min_length: 1, max_length: 3)

  # ── P1 — FIDELITY ──

  # INVARIANT: the canonical encoding is VALID JSON that yields back EXACTLY the original map
  # (`Jason.decode!(encode(m)) == m`) — nothing lost, nothing added, nothing clobbered, at any
  # depth.
  # WHY: the 3 existing properties only test `sha256(m) == sha256(m)`. An encoder dropping
  # the last key, or flattening a nested map, would be perfectly STABLE — hence perfectly
  # green — while making two distinct compositions collide on one sha256. Fidelity is what
  # makes the hash an IDENTITY and not merely a reproducible fingerprint.
  property "P1 FIDELITY — Jason.decode!(encode(m)) == m (canonicalization loses NOTHING)" do
    check all(m <- json_map(), max_runs: 300) do
      assert Jason.decode!(CanonicalJson.encode(m)) == m
    end
  end

  # Direct, load-bearing corollary: the encoder is INJECTIVE → two DIFFERENT contents cannot
  # produce the same sha256. "Same content ⇒ same hash" (already proven) without
  # "different content ⇒ different hash" would be satisfied by a constant encoder.
  property "P1b INJECTIVITY — two different maps ⇒ two different sha256" do
    check all(m1 <- json_map(), m2 <- json_map(), max_runs: 200) do
      if m1 != m2 do
        assert CanonicalJson.sha256(m1) != CanonicalJson.sha256(m2)
      end
    end
  end

  # INVARIANT: an atom key is encoded as its string form (`to_string/1`), value intact.
  # WHY: `Fleet.CapProfile.sha256/1` flattens a struct into a map — keys arrive there as
  # ATOMS. If stringification lost or renamed a key, the hash of a loaded profile (atoms)
  # would differ from that of the same profile re-read from JSON (strings): two identities
  # for a single content, on either side of the struct/JSON boundary.
  property "P1c — atom key ⇒ homonymous string key, value intact, SAME hash" do
    check all(m <- map_of(small_key(), json_scalar(), max_length: 5)) do
      atom_map = Map.new(m, fn {k, v} -> {String.to_atom(k), v} end)

      assert Jason.decode!(CanonicalJson.encode(atom_map)) == m
      assert CanonicalJson.sha256(atom_map) == CanonicalJson.sha256(m)
    end
  end

  # ── P2 — COLLISION GUARD ──

  # INVARIANT: any map carrying both `:k` and `"k"` makes `encode/1` RAISE (ArgumentError),
  # whatever the other contents and the insertion order.
  # WHY: after stringification both keys become `"k"` → `{"k":v1,"k":v2}`, a JSON with
  # duplicated keys whose order depends on map iteration. The hash would stop being a
  # FUNCTION of the content: the same cap-profile could hash differently from run to run.
  # The module picks fail-loud over a silently unstable identity — the property locks the
  # "ALWAYS", which a hardwired example cannot give.
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

  # The guard holds IN DEPTH (encode/1 is recursive, so is the guard). An encoder guarding
  # only the 1st level would let the unstable identity through where it is hardest to see:
  # a subtree (`permissions`, `knowledge`) of a composed cap-profile.
  property "P2b — the collision guard holds inside a NESTED map" do
    check all(k <- small_key(), outer <- small_key(), v1 <- json_scalar(), v2 <- json_scalar()) do
      nested = %{outer => %{k => v1, String.to_atom(k) => v2}}

      assert_raise ArgumentError, fn -> CanonicalJson.encode(nested) end
    end
  end
end
