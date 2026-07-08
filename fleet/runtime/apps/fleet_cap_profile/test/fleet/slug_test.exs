defmodule Fleet.SlugTest do
  @moduledoc """
  Smart-constructor `Fleet.Slug` — the confinement-by-construction brick for names
  that reach a `Path.join` (FS leaf) or a URL segment. The exact contract
  (`^[a-z0-9][a-z0-9_-]*$`, no `..`/`/`/control, non-empty, no leading `-`/`_`) is
  proven here once; the call sites (seed-store, modop, workflow_map, forge) compose it.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.Slug

  doctest Fleet.Slug

  describe "cast/1 — accepts valid slugs" do
    test "canonical names" do
      for ok <- ["a", "z9", "my_checkpoint-1", "poc-8", "engineer", "a_b-c", "0", "x123"] do
        assert {:ok, ^ok} = Slug.cast(ok), "should accept #{inspect(ok)}"
        assert Slug.valid?(ok)
      end
    end
  end

  describe "cast/1 — REFUSES anything that could traverse or inject" do
    test "traversal / path separators" do
      for bad <- ["..", "../evil", "a/b", "/abs", "a/../b", "."] do
        assert {:error, {:invalid_slug, ^bad}} = Slug.cast(bad), "should refuse #{inspect(bad)}"
        refute Slug.valid?(bad)
      end
    end

    test "empty / leading - or _ (looks like a flag, or a hidden name)" do
      for bad <- ["", "-rf", "_hidden", "-", "_"] do
        assert {:error, {:invalid_slug, ^bad}} = Slug.cast(bad)
      end
    end

    test "NUL / control / newline (a multi-line name must not pass)" do
      for bad <- ["ok\x00evil", "ok\nevil", "tab\tx", "a\r"] do
        assert {:error, {:invalid_slug, ^bad}} = Slug.cast(bad)
      end
    end

    test "uppercase / misleading unicode / space / punctuation" do
      # "оk" carries a Cyrillic O (U+043E) — a homoglyph outside [a-z0-9_-].
      for bad <- ["Ok", "ОK", "оk", "a b", "a.b", "a?x=1", "a#frag", "été"] do
        assert {:error, {:invalid_slug, ^bad}} = Slug.cast(bad)
      end
    end

    test "non-binary → refused fail-closed" do
      assert {:error, {:invalid_slug, nil}} = Slug.cast(nil)
      assert {:error, {:invalid_slug, 42}} = Slug.cast(42)
      refute Slug.valid?(nil)
    end
  end

  describe "cast!/1" do
    test "bang returns the value or raises" do
      assert "ok-1" == Slug.cast!("ok-1")
      assert_raise ArgumentError, fn -> Slug.cast!("../evil") end
    end
  end

  describe "under_root?/2 + confined_join/2 — the FS-leaf guard" do
    test "a slug joined under the root stays confined" do
      assert {:ok, abs} = Slug.confined_join("/srv/store", "proj-1")
      assert abs == "/srv/store/proj-1"
      assert Slug.under_root?(abs, "/srv/store")
    end

    test "a non-slug name is refused BEFORE the join (no Path.join ever reached)" do
      assert {:error, {:invalid_slug, "../evil"}} = Slug.confined_join("/srv/store", "../evil")
    end

    test "under_root? rejects a dest that climbs above the root" do
      refute Slug.under_root?("/srv/store/../evil", "/srv/store")
      refute Slug.under_root?("/srv/other", "/srv/store")
      # sibling prefix (not a real subdirectory) refused
      refute Slug.under_root?("/srv/store-evil", "/srv/store")
      assert Slug.under_root?("/srv/store", "/srv/store")
      assert Slug.under_root?("/srv/store/sub/deep", "/srv/store")
    end
  end

  # ============================================================
  # Property: the accepted slug is EXACTLY the path-safe charset, and it is safe by construction.
  # ============================================================

  property "every accepted slug is single-component and does not climb (safe Path.join round-trip)" do
    check all(slug <- valid_slug_gen()) do
      assert {:ok, ^slug} = Slug.cast(slug)
      # A slug contains neither a separator nor `..` → joined under a root, it stays confined.
      joined = Path.join("/root", slug)
      assert Path.expand(joined) == "/root/" <> slug
      assert Slug.under_root?(Path.expand(joined), "/root")
      assert length(Path.split(slug)) == 1
    end
  end

  property "a string carrying / or .. or a control char is ALWAYS refused" do
    check all(
            prefix <- string(:alphanumeric, min_length: 0, max_length: 4),
            poison <- member_of(["..", "/", "\x00", "\n", " ", "%2e%2e"]),
            suffix <- string(:alphanumeric, min_length: 0, max_length: 4)
          ) do
      candidate = prefix <> poison <> suffix
      refute Slug.valid?(candidate), "must NEVER accept #{inspect(candidate)}"
    end
  end

  # Generator of valid slugs: first position [a-z0-9], rest [a-z0-9_-].
  defp valid_slug_gen do
    gen all(
          head <- member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9)),
          tail <-
            list_of(
              member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9) ++ [?_, ?-]),
              max_length: 12
            )
        ) do
      List.to_string([head | tail])
    end
  end
end
