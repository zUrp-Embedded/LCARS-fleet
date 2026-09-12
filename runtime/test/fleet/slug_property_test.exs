defmodule Fleet.SlugPropertyTest do
  @moduledoc """
  Generated lexical-confinement checks over varied roots and names. Root normalization matters
  independently of slug validation; the oracle compares path components rather than copying
  under_root?'s string-prefix logic. These properties do not check filesystem symlinks.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.Slug

  defp seg, do: string([?a..?z], min_length: 1, max_length: 5)

  # Slug grammar: `[a-z0-9][a-z0-9_-]*`.
  defp valid_slug do
    gen all(
          head <- string([?a..?z, ?0..?9], length: 1),
          tail <- string([?a..?z, ?0..?9, ?_, ?-], max_length: 12)
        ) do
      head <> tail
    end
  end

  # Include relative paths, traversal, redundant separators and degenerate roots.
  defp root_gen do
    gen all(
          segs <- list_of(seg(), max_length: 3),
          shape <-
            member_of([
              :abs,
              :rel,
              :dot,
              :dotdot,
              :climb,
              :double_slash,
              :trailing,
              :empty,
              :root
            ])
        ) do
      shaped(shape, Enum.join(segs, "/"))
    end
  end

  defp shaped(:abs, base), do: "/srv/" <> base
  defp shaped(:rel, base), do: base
  defp shaped(:dot, base), do: "./" <> base
  defp shaped(:dotdot, base), do: "/srv/" <> base <> "/.."
  defp shaped(:climb, base), do: "/srv/" <> base <> "/../../../.."
  defp shaped(:double_slash, base), do: "//srv//" <> base
  defp shaped(:trailing, base), do: "/srv/" <> base <> "/"
  defp shaped(:empty, _base), do: ""
  defp shaped(:root, _base), do: "/"

  # Draw valid slugs, printable strings and explicit invalid names.
  defp name_gen do
    one_of([
      valid_slug(),
      string(:printable, max_length: 12),
      member_of([
        "..",
        "../evil",
        "../../etc/passwd",
        "a/b",
        "/abs",
        ".",
        "",
        "-rf",
        "_hidden",
        "ok\nevil",
        "ok\0evil",
        "a b",
        "Ok",
        "été"
      ])
    ])
  end

  # Generated inputs must produce a confined absolute path or typed refusal before filesystem use.
  property "P1 CONFINEMENT — {:ok, abs} always under the root, otherwise typed error, never a raise" do
    check all(root <- root_gen(), name <- name_gen(), max_runs: 400) do
      expanded_root = Path.expand(root)

      case Slug.confined_join(root, name) do
        {:ok, abs} ->
          assert Path.type(abs) == :absolute, "non-absolute path: #{inspect(abs)}"

          # Component comparison catches the naive root <> "/" bug: root / would become //.
          root_parts = Path.split(expanded_root)
          abs_parts = Path.split(abs)

          assert Enum.take(abs_parts, length(root_parts)) == root_parts,
                 "ESCAPE: #{inspect(abs)} outside #{inspect(expanded_root)} " <>
                   "(root=#{inspect(root)}, name=#{inspect(name)})"

          assert Slug.under_root?(abs, root)
          refute String.contains?(abs, "/../"), "unresolved residual `..` in #{inspect(abs)}"
          # The accepted name is a valid slug, hence a SINGLE path component.
          assert Slug.valid?(name)
          assert Path.basename(abs) == name

        {:error, {:invalid_slug, raw}} ->
          assert raw == name
          refute Slug.valid?(name), "rejected as invalid_slug while the slug is valid"

        {:error, {:path_escape, abs}} ->
          # An error path is diagnostic, not authorized for filesystem use.
          assert is_binary(abs)

          # A valid slug cannot escape. Accepting any typed error here would hide false refusal
          # for root /, even though that bug does not permit traversal.
          refute Slug.valid?(name),
                 "path_escape on a VALID slug (root=#{inspect(root)}, name=#{inspect(name)}) " <>
                   "— a slug cannot escape: the root is what is being compared wrong"
      end
    end
  end

  test "REGRESSION — `/` root: confined_join joins, under_root? recognizes (no more false-reject)" do
    assert {:ok, "/proj"} = Slug.confined_join("/", "proj")
    assert Slug.under_root?("/x", "/")
    assert Slug.under_root?("/", "/")
    # Roots that EXPAND to `/` are covered by the same path.
    assert {:ok, "/proj"} = Slug.confined_join("//", "proj")
    assert {:ok, "/proj"} = Slug.confined_join("/a/../..", "proj")
  end

  # Validation must preserve the exact name; normalization could collapse distinct pod directories.
  property "P2 IDEMPOTENCE — cast(s) == {:ok, s} and the joined leaf is exactly root/s" do
    check all(s <- valid_slug(), segs <- list_of(seg(), min_length: 1, max_length: 3)) do
      assert {:ok, ^s} = Slug.cast(s)
      assert Slug.valid?(s)

      root = "/" <> Enum.join(segs, "/")
      assert {:ok, abs} = Slug.confined_join(root, s)
      assert abs == root <> "/" <> s
    end
  end
end
