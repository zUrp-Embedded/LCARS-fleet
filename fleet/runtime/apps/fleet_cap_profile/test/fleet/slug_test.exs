defmodule Fleet.SlugTest do
  @moduledoc """
  Smart-constructor `Fleet.Slug` — la brique de confinement-par-construction des noms
  qui atteignent un `Path.join` (feuille FS) ou un segment d'URL. Le contrat exact
  (`^[a-z0-9][a-z0-9_-]*$`, pas de `..`/`/`/contrôle, non-vide, pas de leading `-`/`_`)
  est prouvé ici une fois ; les sites (seed-store, modop, pipeline, forge) le composent.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.Slug

  describe "cast/1 — accepte les slugs valides" do
    test "noms canon" do
      for ok <- ["a", "z9", "my_checkpoint-1", "poc-8", "engineer", "a_b-c", "0", "x123"] do
        assert {:ok, ^ok} = Slug.cast(ok), "devrait accepter #{inspect(ok)}"
        assert Slug.valid?(ok)
      end
    end
  end

  describe "cast/1 — REFUSE tout ce qui pourrait traverser ou injecter" do
    test "traversal / séparateurs de chemin" do
      for bad <- ["..", "../evil", "a/b", "/abs", "a/../b", "."] do
        assert {:error, {:invalid_slug, ^bad}} = Slug.cast(bad), "devrait refuser #{inspect(bad)}"
        refute Slug.valid?(bad)
      end
    end

    test "vide / leading - ou _ (ressemble à un flag, ou nom caché)" do
      for bad <- ["", "-rf", "_hidden", "-", "_"] do
        assert {:error, {:invalid_slug, ^bad}} = Slug.cast(bad)
      end
    end

    test "NUL / contrôle / newline (un nom multi-ligne ne doit pas passer)" do
      for bad <- ["ok\x00evil", "ok\nevil", "tab\tx", "a\r"] do
        assert {:error, {:invalid_slug, ^bad}} = Slug.cast(bad)
      end
    end

    test "majuscules / unicode trompeur / espace / ponctuation" do
      # "оk" porte un O cyrillique (U+043E) — homoglyphe hors [a-z0-9_-].
      for bad <- ["Ok", "ОK", "оk", "a b", "a.b", "a?x=1", "a#frag", "été"] do
        assert {:error, {:invalid_slug, ^bad}} = Slug.cast(bad)
      end
    end

    test "non-binaire → refusé fail-closed" do
      assert {:error, {:invalid_slug, nil}} = Slug.cast(nil)
      assert {:error, {:invalid_slug, 42}} = Slug.cast(42)
      refute Slug.valid?(nil)
    end
  end

  describe "cast!/1" do
    test "bang rend la valeur ou raise" do
      assert "ok-1" == Slug.cast!("ok-1")
      assert_raise ArgumentError, fn -> Slug.cast!("../evil") end
    end
  end

  describe "under_root?/2 + confined_join/2 — la garde de feuille FS" do
    test "un slug joint sous la racine reste confiné" do
      assert {:ok, abs} = Slug.confined_join("/srv/store", "proj-1")
      assert abs == "/srv/store/proj-1"
      assert Slug.under_root?(abs, "/srv/store")
    end

    test "un nom non-slug est refusé AVANT le join (jamais de Path.join atteint)" do
      assert {:error, {:invalid_slug, "../evil"}} = Slug.confined_join("/srv/store", "../evil")
    end

    test "under_root? rejette un dest qui remonte au-dessus de la racine" do
      refute Slug.under_root?("/srv/store/../evil", "/srv/store")
      refute Slug.under_root?("/srv/other", "/srv/store")
      # préfixe-sœur (pas un vrai sous-dossier) refusé
      refute Slug.under_root?("/srv/store-evil", "/srv/store")
      assert Slug.under_root?("/srv/store", "/srv/store")
      assert Slug.under_root?("/srv/store/sub/deep", "/srv/store")
    end
  end

  # ============================================================
  # Property : le slug accepté est EXACTEMENT le charset path-safe, et il est sûr par construction.
  # ============================================================

  property "tout slug accepté est mono-composant et ne remonte pas (round-trip Path.join sûr)" do
    check all(slug <- valid_slug_gen()) do
      assert {:ok, ^slug} = Slug.cast(slug)
      # Un slug ne contient ni séparateur ni `..` → joint sous une racine, il reste confiné.
      joined = Path.join("/root", slug)
      assert Path.expand(joined) == "/root/" <> slug
      assert Slug.under_root?(Path.expand(joined), "/root")
      assert length(Path.split(slug)) == 1
    end
  end

  property "une chaîne portant / ou .. ou un contrôle est TOUJOURS refusée" do
    check all(
            prefix <- string(:alphanumeric, min_length: 0, max_length: 4),
            poison <- member_of(["..", "/", "\x00", "\n", " ", "%2e%2e"]),
            suffix <- string(:alphanumeric, min_length: 0, max_length: 4)
          ) do
      candidate = prefix <> poison <> suffix
      refute Slug.valid?(candidate), "ne doit JAMAIS accepter #{inspect(candidate)}"
    end
  end

  # Générateur de slugs valides : 1ʳᵉ position [a-z0-9], reste [a-z0-9_-].
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
