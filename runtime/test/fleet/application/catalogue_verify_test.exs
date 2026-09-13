defmodule Fleet.Application.CatalogueVerifyTest do
  @moduledoc """
  Verifies bundled and mutated catalogue roots without starting pods or a release.
  Serial because image publication is global; cleanup unpublishes images rather
  than restoring previous snapshots. Cases check stage attribution, not all boot behavior.
  """
  use ExUnit.Case, async: false

  alias Fleet.Application.CatalogueVerify

  @moduletag :tmp_dir

  setup do
    on_exit(fn ->
      Fleet.CapProfile.Image.unpublish()
      Fleet.SPBuilder.Image.unpublish()
      Fleet.Workflow.Loader.unpublish_all_images()
    end)

    :ok
  end

  # Dereference the bundled priv symlink before mutation so fixtures cannot edit the source.
  defp catalogue_copy(tmp) do
    copy = Path.join(tmp, "catalogue")
    File.cp_r!(Fleet.Catalogue.root(), copy, dereference_symlinks: true)
    copy
  end

  test "the bundled catalogue passes every check" do
    assert {:ok, %{root: root, assumptions: assumptions}} =
             CatalogueVerify.verify(to_string(Fleet.Catalogue.root()))

    assert root == to_string(Fleet.Catalogue.root())

    assert Enum.any?(assumptions, &(&1 =~ "root read"))
    assert Enum.any?(assumptions, &(&1 =~ "IGNORED"))
  end

  test "a catalogue with NO cap-profiles of its own says so in the assumptions, and is not refused for it",
       %{tmp_dir: tmp} do
    copy = catalogue_copy(tmp)
    File.rm_rf!(Path.join(copy, "cap_profile/cap-profiles"))

    # Missing own profiles are named; success still depends on roles used by cards.
    {verdict, log} = ExUnit.CaptureLog.with_log(fn -> CatalogueVerify.verify(copy) end)

    assumptions =
      case verdict do
        {:ok, %{assumptions: a}} ->
          a

        {:error, %{assumptions: a, findings: findings}} ->
          refute Enum.any?(findings, &(&1.stage == "business catalogue advice")),
                 "the advice stage must not refuse an absent directory: #{inspect(findings)}"

          a
      end

    assert Enum.any?(assumptions, &(&1 =~ "cap-profiles: NONE of its own"))
    refute log =~ "declares NO judge", "no judge to advise about when there is no index at all"
  end

  test "the bundled catalogue's assumptions name where its cap-profiles were read" do
    assert {:ok, %{assumptions: assumptions}} =
             CatalogueVerify.verify(to_string(Fleet.Catalogue.root()))

    assert Enum.any?(assumptions, &(&1 =~ "cap-profiles: read from"))
  end

  test "a catalogue whose own roles carry NO judge gets the advice, as a warning and not a refusal",
       %{tmp_dir: tmp} do
    copy = catalogue_copy(tmp)
    dir = Path.join(copy, "cap_profile/cap-profiles")

    judges =
      dir
      |> File.ls!()
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&(File.regular?(&1) and File.read!(&1) =~ "brief_kind: judge"))

    assert judges != [], "the bundled catalogue is expected to declare at least one judge"
    Enum.each(judges, &File.rm!/1)

    {verdict, log} = ExUnit.CaptureLog.with_log(fn -> CatalogueVerify.verify(copy) end)
    assert log =~ "declares NO judge"

    case verdict do
      {:ok, _} ->
        :ok

      {:error, %{findings: findings}} ->
        refute Enum.any?(findings, &(&1.stage == "business catalogue advice"))
    end
  end

  test "it restores the previous root on the way out", %{tmp_dir: tmp} do
    Application.delete_env(:lcars_fleet, :catalogue_root)
    _ = CatalogueVerify.verify(catalogue_copy(tmp))
    assert Application.fetch_env(:lcars_fleet, :catalogue_root) == :error
  end

  test "an absent manifest is refused at the precondition, nothing downstream runs", %{
    tmp_dir: tmp
  } do
    bare = Path.join(tmp, "bare")
    File.mkdir_p!(bare)

    assert {:error, %{findings: findings}} = CatalogueVerify.verify(bare)

    assert [%{stage: "catalogue manifest"}] = findings
  end

  test "a foreign api_version is refused, and the finding names the stage", %{tmp_dir: tmp} do
    copy = catalogue_copy(tmp)
    File.write!(Path.join(copy, "catalogue.yaml"), "api_version: 99\n")

    assert {:error, %{findings: [%{stage: "catalogue manifest", error: error}]}} =
             CatalogueVerify.verify(copy)

    assert error =~ "99"
  end

  test "a card naming a role the catalogue does not carry is refused at the card stage",
       %{tmp_dir: tmp} do
    copy = catalogue_copy(tmp)

    # Anchor the YAML mutation on a real step's indentation, not a role mention in comments.
    map = Path.join(copy, "workflow/workflow_maps/c0-poc.yaml")

    content =
      map
      |> File.read!()
      |> String.replace(~r/^      role: \w+/m, "      role: ghost_role_absent", global: false)

    File.write!(map, content)

    refute File.read!(map) =~ "role: engineer",
           "the step mutation did not land on a real step role"

    assert {:error, %{findings: findings}} = CatalogueVerify.verify(copy)

    assert Enum.any?(findings, &(&1.stage == "cards + structural roles")),
           "a card pointing at a missing role should fail the card stage, got: #{inspect(findings)}"

    refute Enum.any?(findings, &(&1.stage =~ "image")),
           "the images were intact — they must not appear as findings"
  end

  test "a role that is schema-valid but not spawn-ready fails the canon spawn-proof stage",
       %{tmp_dir: tmp} do
    # Declare a nonexistent template explicitly: deleting a historically used template
    # stopped exercising spawn-proof once no role referenced it. Deleting a draft
    # fails earlier at image publication, so it cannot witness this stage.
    copy = catalogue_copy(tmp)
    profile = Path.join(copy, "cap_profile/cap-profiles/qualifier.yaml")

    File.write!(
      profile,
      String.replace(
        File.read!(profile),
        "subagent_template: null",
        "subagent_template: fantome-qui-nexiste-pas",
        global: false
      )
    )

    assert {:error, %{findings: findings}} = CatalogueVerify.verify(copy)

    assert Enum.any?(findings, &(&1.stage == "canon spawn-proof")),
           "a role missing its subagent template should fail the spawn-proof, got: #{inspect(findings)}"

    refute Enum.any?(findings, &(&1.stage =~ "image")),
           "the images were intact — they must not appear as findings"
  end

  test "a role DECLARED by a catalogue that carries no SP for it is refused at the image", %{
    tmp_dir: tmp
  } do
    copy = catalogue_copy(tmp)
    File.rm!(Path.join(copy, "sp_builder/sp_drafts/agent-engineer-base.md"))

    assert {:error, %{findings: findings}} = CatalogueVerify.verify(copy)

    assert Enum.any?(findings, &(&1.stage == "sp-builder image" and &1.error =~ "engineer")),
           "got: #{inspect(findings)}"
  end

  test "carrying a draft WITHOUT the role is a supersession, and stays silent", %{tmp_dir: tmp} do
    # A catalogue may override the prompt of a system role without redeclaring that role.
    copy = catalogue_copy(tmp)

    File.write!(
      Path.join(copy, "sp_builder/sp_drafts/agent-gatekeeper-base.md"),
      "# Gatekeeper, in my own words\n"
    )

    assert {:ok, _} = CatalogueVerify.verify(copy)
  end

  test "a business catalogue overriding a SYSTEM role BY NAME passes", %{tmp_dir: tmp} do
    # Same-name overrides are allowed; structural conflicts are checked on the merged index.
    copy = catalogue_copy(tmp)

    override =
      Fleet.Catalogue.system_root()
      |> Path.join("cap_profile/cap-profiles/architect.yaml")
      |> File.read!()

    # Keep the override byte-identical to isolate superposition from content validity.
    File.write!(Path.join(copy, "cap_profile/cap-profiles/architect.yaml"), override)

    assert {:ok, _} = CatalogueVerify.verify(copy)
  end

  test "a catalogue with NO sp_blocks/ passes — hand-written drafts owe no blocks", %{
    tmp_dir: tmp
  } do
    # Finished hand-written drafts need no build-time sp_blocks tree.
    copy = catalogue_copy(tmp)
    File.rm_rf!(Path.join(copy, "sp_builder/sp_blocks"))

    assert {:ok, _} = CatalogueVerify.verify(copy)
  end

  test "verify covers the CATALOGUE, not the deployment — no forge/token guard leaks in",
       %{tmp_dir: tmp} do
    # This calls the verifier with ambient test configuration; it does not explicitly
    # remove forge settings or tokens to prove independence from them.
    assert {:ok, _} = CatalogueVerify.verify(catalogue_copy(tmp))
  end
end
