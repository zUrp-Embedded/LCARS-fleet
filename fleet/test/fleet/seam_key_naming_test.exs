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
  # ⚠ `basename(o, ".ex")` : `fleet/catalogue.ex` et `fleet/catalogue/…` sont LE MEME proprietaire.
  # Sans ce retrait, la moitie des clefs correctement prefixees se lisaient « sans prefixe », parce
  # que « catalogue.ex » ne commence pas par « catalogue_ » — une accusation qui ne parlait que de
  # l'arborescence.
  defp owner_of(path) do
    case Path.relative_to(path, @lib_root) |> Path.split() do
      ["fleet", owner | _] -> Path.basename(owner, ".ex")
      _ -> nil
    end
  end

  # ⚠ SUR L'AST, ET LA PREMIERE VERSION NE L'ETAIT PAS. Ecrite en regex ligne-a-ligne, elle voyait
  # 25 seams sur 33 : les huit autres sont ecrits sur PLUSIEURS lignes (`mix format` casse un appel
  # trop long) et aucune expression de ligne ne les rattrape. Aucun des huit n'etait en faute, donc
  # rien n'etait cache — mais un temoin qui annonce une classe et en mesure les trois quarts est
  # exactement le defaut qu'il est cense attraper ailleurs. L'AST ignore les retours a la ligne, et
  # il ignore aussi les COMMENTAIRES : ce depot documente ses seams en CITANT l'appel, et une regex
  # comptait ces citations comme des lectures — un `#` dans `Fleet.Forge.Client` faisait passer une
  # clef pour bi-proprietaire.
  #
  # LES TROIS LECTEURS, ET LA FORME PIPE AVEC. `fetch_env` (pas de defaut) et `compile_env` (gele a
  # la compilation) lisent la meme configuration que `get_env` ; n'en couvrir qu'un rendait un vert
  # dont la portee etait plus etroite que sa phrase.
  defp seam_reads(ast, owner) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        # forme PIPE : `:lcars_fleet |> Application.get_env(:key, default)`
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

  defp seam_owners do
    for path <- Path.wildcard(Path.join(@lib_root, "**/*.ex")),
        owner = owner_of(path),
        not is_nil(owner),
        {:ok, ast} <- [Code.string_to_quoted(File.read!(path))],
        {key, o} <- seam_reads(ast, owner) do
      {Atom.to_string(key), o}
    end
    |> Enum.group_by(fn {k, _} -> k end, fn {_, o} -> o end)
    |> Map.new(fn {k, os} -> {k, Enum.uniq(os)} end)
  end

  test "the sweep still sees the seams — an empty scan would pass on anything" do
    seams = seam_owners()

    # 29 distinct keys today, over 33 call sites — a floor, not a census: it catches "the walk
    # stopped matching" without reddening on every key someone legitimately adds or removes.
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
