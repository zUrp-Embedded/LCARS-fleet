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
  @seam ~r/Application\.get_env\(:lcars_fleet,\s*(:[a-z_]+),\s*([A-Z@][A-Za-z0-9_.{]*)/

  # `lib/fleet/<owner>/…` — the subsystem directory IS the owner, which is also what `use Boundary`
  # carves up. Anything outside that shape (mix tasks) owns nothing and is skipped rather than
  # guessed at.
  defp owner_of(path) do
    case Path.relative_to(path, @lib_root) |> Path.split() do
      ["fleet", owner | _] -> owner
      _ -> nil
    end
  end

  defp seam_owners do
    for path <- Path.wildcard(Path.join(@lib_root, "**/*.ex")),
        owner = owner_of(path),
        not is_nil(owner),
        line <- String.split(File.read!(path), "\n"),
        # ⚠ COMMENT LINES EXCLUDED, and it is not cosmetic: this very repository documents its seams
        # by quoting the call, so a comment naming a key would invent an owner for it. Found while
        # writing this file — a `#` line in `Fleet.Forge.Client` made one key look cross-owner.
        not String.starts_with?(String.trim_leading(line), "#"),
        [_, key, _default] <- Regex.scan(@seam, line) do
      {key, owner}
    end
    |> Enum.group_by(fn {k, _} -> k end, fn {_, o} -> o end)
    |> Map.new(fn {k, os} -> {k, Enum.uniq(os)} end)
  end

  test "the sweep still sees the seams — an empty scan would pass on anything" do
    seams = seam_owners()

    assert map_size(seams) >= 15,
           "only #{map_size(seams)} module seams found: the scan stopped matching, it did not " <>
             "prove the naming clean"

    assert Map.has_key?(seams, ":forge_actions"),
           "the deliberately-bare key is no longer visible to this test"
  end

  test "a seam with ONE owner carries that owner's prefix" do
    offenders =
      for {key, [owner]} <- seam_owners(),
          not String.starts_with?(key, ":#{owner}_"),
          do: "#{key} is read only by fleet/#{owner}/ but does not say so"

    assert offenders == [],
           "seam key(s) naming no owner — a reader cannot tell what configures what:\n  " <>
             Enum.join(offenders, "\n  ")
  end

  test "a seam with SEVERAL owners carries none of their prefixes — it would lie" do
    offenders =
      for {key, owners} <- seam_owners(),
          length(owners) > 1,
          o <- owners,
          String.starts_with?(key, ":#{o}_"),
          do: "#{key} claims fleet/#{o}/ but is also read by #{inspect(owners -- [o])}"

    assert offenders == [],
           "seam key(s) whose prefix names one owner among several:\n  " <>
             Enum.join(offenders, "\n  ")
  end
end
