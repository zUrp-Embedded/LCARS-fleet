defmodule Fleet.Workflow.ModopsConsumptionTest do
  @moduledoc """
  Checks bundle presence, basic Markdown headers and known orphans across the shipped
  business/system catalogues. References come from parsed modop_set declarations;
  unreadable or differently shaped profiles are skipped, so this is not profile validation.
  Name sets are global here, not proof of per-catalogue runtime resolution or prompt quality.
  """
  use ExUnit.Case, async: true

  # Include system bundles referenced by mechanical roles as well as business bundles.
  @modop_canons [
    Application.app_dir(:lcars_fleet, "priv/catalogue-system/cap_profile"),
    Application.app_dir(:lcars_fleet, "priv/catalogue/cap_profile")
  ]

  # Superpowers templates were retired. This empty list makes any discovered template fail
  # before its content check; reintroducing one requires explicitly updating the expectation.
  @subagent_templates []

  # Exact allowed orphan set: new or removed bundles require a deliberate expectation change.
  # Their prompt content belongs to the separate SP rewrite, not this presence check.
  @known_orphans ~w(archive-mode fire-mode)

  defp bundle_dirs, do: Enum.map(@modop_canons, &Path.join(&1, "modop-bundles"))

  defp existing_bundles do
    bundle_dirs()
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn dir ->
      dir |> File.ls!() |> Enum.filter(&File.dir?(Path.join(dir, &1)))
    end)
    |> Enum.sort()
  end

  defp referenced_bundles do
    @modop_canons
    |> Enum.flat_map(&Path.wildcard(Path.join([&1, "cap-profiles", "*.yaml"])))
    |> Enum.flat_map(fn f ->
      case YamlElixir.read_from_file(f) do
        {:ok, %{"spec" => %{"modop_set" => set}}} when is_map(set) ->
          (Map.get(set, "default", []) || []) ++ (Map.get(set, "optional", []) || [])

        _ ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  test "every EXISTING modop-bundle has a well-formed sp.md (GO-7 header + non-empty)" do
    for b <- existing_bundles() do
      sp = Enum.find(bundle_dirs(), &File.exists?(Path.join([&1, b, "sp.md"])))
      assert sp, "missing modop-bundle sp.md: #{b}"
      content = File.read!(Path.join([sp, b, "sp.md"]))
      assert byte_size(content) > 200, "#{b}/sp.md too short (malformed?)"
      assert content =~ ~r/^#\s/, "#{b}/sp.md without markdown title"
      # "Statut" is the FR header of the SP fragments (SP content is FR by design).
      assert content =~ "Statut", "#{b}/sp.md without Statut header (GO-7)"
    end
  end

  test "tout subagent-template PRÉSENT est bien formé (corpus vide accepté)" do
    présents =
      Enum.flat_map(@modop_canons, fn r ->
        Path.wildcard(Path.join([r, "subagent-templates", "subagent-*.md"]))
      end)

    assert présents == [] or @subagent_templates != [],
           "des templates existent sur disque alors que la liste attendue est vide : " <>
             "la sortie de superpowers a été partiellement défaite, ou un template est revenu " <>
             "sans que personne le déclare — #{inspect(présents)}"

    for f <- présents do
      c = File.read!(f)
      assert byte_size(c) > 150 and c =~ ~r/^#\s/, "#{Path.basename(f)} malformed"
    end
  end

  test "consumer integrity: every bundle a cap-profile REFERENCES actually exists (no dangling activation)" do
    existing = MapSet.new(existing_bundles())
    dangling = Enum.reject(referenced_bundles(), &MapSet.member?(existing, &1))

    assert dangling == [],
           "cap-profiles reference modop-bundles that do NOT exist (a spawn would fail to compose): #{inspect(dangling)}"
  end

  test "consumer integrity: an EXISTING bundle is either activated by a cap-profile or a KNOWN orphan" do
    referenced = MapSet.new(referenced_bundles())
    orphans = existing_bundles() |> Enum.reject(&MapSet.member?(referenced, &1)) |> Enum.sort()

    assert orphans == Enum.sort(@known_orphans),
           "orphan-bundle drift: #{inspect(orphans)} ≠ known #{inspect(Enum.sort(@known_orphans))}. " <>
             "A new activable bundle must have a cap-profile consumer; a removed orphan updates @known_orphans."
  end
end
