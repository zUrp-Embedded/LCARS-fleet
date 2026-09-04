defmodule Fleet.SeamKeyNamingTest do
  @moduledoc """
  A seam key says WHO owns it — and when it has no single owner, it says that too.

  ~110 application-env keys, and they all read `<owner>_<thing>`: `admiral_`, `mcp_`, `pilot_`,
  `spawner_`, `workflow_`, `credentials_`, `catalogue_`… The convention was never written down, so
  two keys drifted out of it — `:forge_client` and `:forge_actions`, the only MODULE seams naming no
  owner at all.

  WHY IT COST SOMETHING, on a project written by machines and judged by people. `:forge_client`
  named TWO mechanisms with different scopes: 22 `Keyword.get(opts, :forge_client, …)` in `Pilot`
  (per-call injection) and 2 `Application.get_env` (node-global). Nothing was miswired — every test
  used the right one, and the three suites that share these globals are `async: false`, measured.
  But a reader had to hold all of that to understand three lines, and a reader who gives up is the
  failure mode that matters most here.

  THE RULE IS DERIVED, NOT LISTED, and that is what makes it survive:

    · one owner  -> the key MUST carry that owner's prefix;
    · two owners -> the key MUST NOT carry any single owner's prefix, because it would lie.

  So `:forge_actions` stays bare and PASSES — it is read by `Fleet.MCP.PodTools.Probe` and
  `Fleet.Pilot.MergeAndPromote` deliberately, so that "la sonde et sa verification" cannot return
  two different answers in a test. Its exception is not an entry in a list here; it is a
  consequence of what the code does, and it would disappear by itself the day one of the two
  readers goes away.

  ⚠ SCOPE, STATED: MODULE-valued seams only — a default that is a module alias or a module
  attribute. Scalar knobs (`_ms`, roots, booleans) mostly follow the same convention and a handful
  do not; sweeping them is a separate decision, and pretending this test covers them would be the
  more expensive lie.
  """
  use ExUnit.Case, async: true

  @lib_root Path.join([__DIR__, "..", "..", "lib"]) |> Path.expand()
  @readers [:get_env, :fetch_env, :compile_env]

  # `lib/fleet/<owner>/…` — the subsystem directory IS the owner, which is also what `use Boundary`
  # carves up. Anything outside that shape (mix tasks) owns nothing and is skipped rather than
  # guessed at.
  # ⚠ `basename(o, ".ex")`: `fleet/catalogue.ex` and `fleet/catalogue/…` are the SAME owner. Without
  # that strip, half the correctly-prefixed keys read as "no prefix", because "catalogue.ex" does
  # not start with "catalogue_" — an accusation that spoke only about the directory tree.
  defp owner_of(path) do
    case Path.relative_to(path, @lib_root) |> Path.split() do
      ["fleet", owner | _] -> Path.basename(owner, ".ex")
      _ -> nil
    end
  end

  # ⚠ ON THE AST, AND THE FIRST VERSION WAS NOT. Written as a line-by-line regex, it saw 25 seams
  # out of 33: the other eight are written across SEVERAL lines (`mix format` breaks any call that
  # is too long) and no line expression catches them. None of the eight was in breach, so nothing
  # was hidden — but a witness that announces a class and measures three quarters of it is exactly
  # the defect it exists to catch elsewhere. The AST ignores line breaks, and it also ignores
  # COMMENTS: this repository documents its seams by QUOTING the call, and a regex counted those
  # quotations as reads — one `#` line in `Fleet.Forge.Client` made a key look cross-owner.
  #
  # THE THREE READERS, AND THE PIPE FORM WITH THEM. `fetch_env` (no default) and `compile_env`
  # (frozen at compile time) read the same configuration as `get_env`; covering only one produced a
  # green whose reach was narrower than its sentence.
  defp seam_reads(ast, owner) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        # PIPE form: `:lcars_fleet |> Application.get_env(:key, default)`
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

  # MODULE-VALUED ONLY — a module alias, or a module attribute holding one. That is the scope this
  # file claims, and the filter is what keeps the claim true: scalar knobs mostly follow the same
  # convention and a handful do not.
  defp collect(list, owner, :lcars_fleet, [key, default]) when is_atom(key) do
    case default do
      {:__aliases__, _, _} -> [{key, owner} | list]
      {:@, _, _} -> [{key, owner} | list]
      _ -> list
    end
  end

  defp collect(list, _owner, _app, _args), do: list

  # The SITES (key × file) before grouping by key. A number that lives only in a comment is
  # contradicted by nothing and drifts in silence — the comment is the one artefact of this repo
  # that neither the gate nor a review filters. An independent review recounted 27/31 where this
  # file's own logic yields 29/33; what settles it is what the code measures, not the prose.
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

    # ⚠ A FLOOR DOES NOT GUARD THE REACH, AND I TRIED ONE. `length(seam_pairs()) >= 28` does NOT
    # redden when the PIPE clause and the two neighbouring readers are removed: 31 sites out of 33
    # remain, and a global count is far too coarse to notice that a FORM disappeared. A threshold
    # that survives every real mutation is not a guard, it is a reassuring number.
    #
    # What bites is SENTINELS: two keys that exist ONLY in the forms the first version of this file
    # could not read. Lose the form, lose the key, and the assertion says which one.
    for {key, form} <- [
          # split across lines by `mix format` — invisible to any line expression
          {"task_queue_poll_retention_ms", "multi-line"},
          # `:lcars_fleet |> Application.get_env(:k, @default)` — two arguments in the AST
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
