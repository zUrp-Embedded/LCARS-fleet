defmodule Fleet.SeamKeyNamingTest do
  @moduledoc """
  Checks owner prefixes for recognized Application-config reads under lib/fleet.
  A key read by one owner needs its prefix; a key shared by several owners must carry
  none of those owners' prefixes. forge_actions intentionally joins probe and verification
  through one shared test seam.

  Scope is syntactic: literal app/key plus an alias or attribute default. Attributes are
  not resolved, so scalar defaults also enter the scan; no-default fetch_env calls do not.
  Per-call Keyword seams are outside this node-global config convention.
  """
  use ExUnit.Case, async: true

  @lib_root Path.join([__DIR__, "..", "..", "lib"]) |> Path.expand()
  @readers [:get_env, :fetch_env, :compile_env]

  # Infer ownership from the first fleet path component, stripping .ex so catalogue.ex
  # and catalogue/ agree. This does not consult Boundary declarations.
  defp owner_of(path) do
    case Path.relative_to(path, @lib_root) |> Path.split() do
      ["fleet", owner | _] -> Path.basename(owner, ".ex")
      _ -> nil
    end
  end

  # AST traversal handles multiline and pipe calls without treating comment text as reads.
  # It does not expand aliases/macros or infer the value of an attribute default.
  defp seam_reads(ast, owner) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:|>, _, [app, {{:., _, [{:__aliases__, _, [:Application]}, f]}, _, args}]} = node, list
        when f in @readers ->
          {node, collect(list, owner, app, args)}

        {{:., _, [{:__aliases__, _, [:Application]}, f]}, _, [app | args]} = node, list
        when f in @readers ->
          {node, collect(list, owner, app, args)}

        node, list ->
          {node, list}
      end)

    acc
  end

  # Include alias and attribute syntax; attribute values need not be modules.
  defp collect(list, owner, :lcars_fleet, [key, default]) when is_atom(key) do
    case default do
      {:__aliases__, _, _} -> [{key, owner} | list]
      {:@, _, _} -> [{key, owner} | list]
      _ -> list
    end
  end

  defp collect(list, _owner, _app, _args), do: list

  # Unparseable sources are skipped. Repeated reads are grouped by key and inferred owner.
  defp seam_pairs do
    for path <- Path.wildcard(Path.join(@lib_root, "**/*.ex")),
        owner = owner_of(path),
        not is_nil(owner),
        {:ok, ast} <- [Code.string_to_quoted(File.read!(path))],
        {key, o} <- seam_reads(ast, owner) do
      {Atom.to_string(key), o}
    end
  end

  defp seam_owners do
    seam_pairs()
    |> Enum.group_by(fn {k, _} -> k end, fn {_, o} -> o end)
    |> Map.new(fn {k, os} -> {k, Enum.uniq(os)} end)
  end

  test "the sweep still sees the seams — an empty scan would pass on anything" do
    seams = seam_owners()

    # Sentinels check specific syntax forms that a global population floor could miss.
    for {key, form} <- [
          {"task_queue_poll_retention_ms", "multi-line"},
          {"spawner_max_pods_per_role", "pipe"}
        ] do
      assert Map.has_key?(seams, key),
             "the #{form} form is no longer read: `#{key}` vanished from the sweep, so the green " <>
               "below no longer covers that form"
    end

    assert map_size(seams) >= 25,
           "only #{map_size(seams)} module seams found: the scan stopped matching, it did not " <>
             "prove the naming clean"

    assert Map.has_key?(seams, "forge_actions"),
           "the deliberately-bare key is no longer visible to this test"
  end

  test "a seam with ONE owner carries that owner's prefix" do
    offenders =
      for {key, [owner]} <- seam_owners(),
          not String.starts_with?(key, "#{owner}_"),
          do: ":#{key} is read only by fleet/#{owner}/ but does not say so"

    assert offenders == [],
           "seam key(s) naming no owner — a reader cannot tell what configures what:\n  " <>
             Enum.join(offenders, "\n  ")
  end

  test "a seam with SEVERAL owners carries none of their prefixes — it would lie" do
    offenders =
      for {key, owners} <- seam_owners(),
          length(owners) > 1,
          o <- owners,
          String.starts_with?(key, "#{o}_"),
          do: ":#{key} claims fleet/#{o}/ but is also read by #{inspect(owners -- [o])}"

    assert offenders == [],
           "seam key(s) whose prefix names one owner among several:\n  " <>
             Enum.join(offenders, "\n  ")
  end
end
