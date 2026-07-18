defmodule Fleet.SlugPropertyTest do
  @moduledoc """
  Property-based proof of CONFINEMENT (`confined_join/2`). `slug_test.exs` already proves the
  `cast/1` smart-constructor (charset, traversal refusal) and its two properties target the
  NAME. Here we attack the other half of the move — the ROOT.

  `cast/1` is not enough when the root itself is computed: exactly what the moduledoc says
  ("the belt on top of the braces"). So the property bombards TWISTED roots (relative, `..`,
  `.`, `//`, trailing slash, empty) and demands, for every possible outcome, that the result
  is NEVER an absolute path OUTSIDE the root — nor an exception.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.Slug

  # ── generators ──

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

  # Twisted roots: every shape a COMPUTED path can take when it comes from a config,
  # an env var or a concatenation — including the ones that climb up.
  defp root_gen do
    gen all(
          segs <- list_of(seg(), max_length: 3),
          shape <-
            member_of([:abs, :rel, :dot, :dotdot, :climb, :double_slash, :trailing, :empty, :root])
        ) do
      base = Enum.join(segs, "/")

      case shape do
        :abs -> "/srv/" <> base
        :rel -> base
        :dot -> "./" <> base
        :dotdot -> "/srv/" <> base <> "/.."
        :climb -> "/srv/" <> base <> "/../../../.."
        :double_slash -> "//srv//" <> base
        :trailing -> "/srv/" <> base <> "/"
        :empty -> ""
        :root -> "/"
      end
    end
  end

  # Names: valid slugs AND everything a payload/catalogue may send in their place.
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

  # ── P1 — CONFINEMENT ──

  # INVARIANT: for ANY root (even twisted) and ANY name, `confined_join/2` returns
  #   • either `{:ok, abs}` with `abs` ABSOLUTE and UNDER `Path.expand(root)` (== root, or
  #     prefixed by `root <> "/"`), with no residual `..`;
  #   • or a TYPED error (`{:invalid_slug, name}` | `{:path_escape, abs}`).
  # Never an exception. Never a path outside the root.
  # WHY: this is the last rampart before a `File.write`/`File.rm_rf` on a path where one
  # segment comes from an input. A single out-of-root `{:ok, abs}` and we write (or erase)
  # out of zone. An untyped exception breaks the caller expecting a fail-closed `{:error, _}`.
  property "P1 CONFINEMENT — {:ok, abs} always under the root, otherwise typed error, never a raise" do
    check all(root <- root_gen(), name <- name_gen(), max_runs: 400) do
      expanded_root = Path.expand(root)

      case Slug.confined_join(root, name) do
        {:ok, abs} ->
          assert Path.type(abs) == :absolute, "non-absolute path: #{inspect(abs)}"

          # Confinement oracle, implementation-independent: `abs` is the root itself, or one
          # of its descendants — compared by COMPONENTS (Path.split), not by string prefix.
          # The naive `expanded_root <> "/"` prefix is exactly the bug fixed on the code side
          # (root `/` → prefix `//` that nothing carries): an oracle copying the code's bug
          # cannot find it.
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
          # Fail-closed outcome: refuse rather than write out of zone. The path is returned
          # for diagnostics, it is NOT usable.
          assert is_binary(abs)

          # ⚠ LOCK (defect found BY this property): with a VALID slug, `..` is already
          # impossible by construction → `:path_escape` must NEVER fire. Yet it fired on the
          # `/` root: `under_root?` compared against the `root <> "/"` prefix, i.e. `"//"` for
          # the root — which no expanded path carries. Fail-closed, hence not an escape, but a
          # guard refusing the LEGAL case is an unusable guard (and its contract, a lie).
          # Without this refute, the property stayed green on the bug: both outcomes were
          # accepted.
          refute Slug.valid?(name),
                 "path_escape on a VALID slug (root=#{inspect(root)}, name=#{inspect(name)}) " <>
                   "— a slug cannot escape: the root is what is being compared wrong"
      end
    end
  end

  # REGRESSION of the same defect, spelled out (the `/` root is a legal edge case: a store
  # mounted at the root, a test joining under `/`).
  test "REGRESSION — `/` root: confined_join joins, under_root? recognizes (no more false-reject)" do
    assert {:ok, "/proj"} = Slug.confined_join("/", "proj")
    assert Slug.under_root?("/x", "/")
    assert Slug.under_root?("/", "/")
    # Roots that EXPAND to `/` are covered by the same path.
    assert {:ok, "/proj"} = Slug.confined_join("//", "proj")
    assert {:ok, "/proj"} = Slug.confined_join("/a/../..", "proj")
  end

  # ── P2 — IDEMPOTENCE / exact leaf ──

  # INVARIANT: for every `s` produced by the slug grammar, `cast(s) == {:ok, s}` (the
  # smart-constructor TRANSFORMS nothing, it validates) and, under a clean root, `confined_join`
  # returns exactly the leaf `Path.expand(root) <> "/" <> s`.
  # WHY: if `cast/1` quietly normalized the name (lowercase, trim, substitution), the written
  # path would no longer be the one the caller believes it asked for — two pods could end up
  # in the SAME pod_dir after a normalization collision. The contract is "validate or refuse",
  # never "repair".
  property "P2 IDEMPOTENCE — cast(s) == {:ok, s} and the joined leaf is exactly root/s" do
    check all(s <- valid_slug(), segs <- list_of(seg(), min_length: 1, max_length: 3)) do
      assert {:ok, ^s} = Slug.cast(s)
      assert Slug.valid?(s)

      root = "/" <> Enum.join(segs, "/")
      assert {:ok, abs} = Slug.confined_join(root, s)
      assert abs == root <> "/" <> s
    end
  end

  # ── AUDIT NOTE — the `/`-root pitfall locked above ──
  #
  # A prefix-based `under_root?/2` (`dest == root or dest starts_with root <> "/"`) is WRONG
  # for `root == "/"`: the concatenation yields `"//"` — and `"/x"` does not start with `"//"`.
  #     Slug.under_root?("/x", "/")        would be false   (expected: true — "/x" IS under "/")
  #     Slug.confined_join("/", "proj")    would be {:error, {:path_escape, "/proj"}}
  # Consequence: a `"/"` root (or any root that `Path.expand`s to `"/"`, e.g. `"//"`) makes
  # `confined_join/2` UNUSABLE — systematic refusal. The defect's direction is FAIL-CLOSED
  # (false-reject, not false-accept): no escape, which is why property P1 would stay green by
  # classifying the case under the `{:path_escape, _}` branch. Not a security hole, then, but a
  # false-reject in a guard whose stated contract is "== root or under root" — hence the
  # component-wise oracle in P1 and the REGRESSION test above.
end
