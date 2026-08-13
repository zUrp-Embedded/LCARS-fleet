defmodule Fleet.Application.CatalogueVerifyTest do
  @moduledoc """
  The standalone catalogue verifier is the boot proof, off the supervision path. Two claims carry
  it: the bundled catalogue passes every check, and a catalogue broken exactly where the boot would
  refuse it produces the matching finding — not a green.

  `async: false` — publishes images to `:persistent_term`; `on_exit` restores the bundled images so
  a foreign catalogue's snapshot never leaks into a later test.
  """
  use ExUnit.Case, async: false

  alias Fleet.Application.CatalogueVerify

  @moduletag :tmp_dir

  setup do
    on_exit(fn ->
      # Republish the bundled images so nothing downstream in the suite reads a copy frozen from a
      # test root. Same discipline as Fleet.CatalogueTest's phase-criterion test.
      Fleet.CapProfile.Image.unpublish()
      Fleet.SPBuilder.Image.unpublish()
      Fleet.Workflow.Loader.unpublish_all_images()
    end)

    :ok
  end

  # A real, complete catalogue to mutate: a dereferenced copy of the bundled one. The build's priv
  # is a symlink to the source tree — without dereference the copy would BE that symlink and a
  # mutation would hit the bundled catalogue itself.
  defp catalogue_copy(tmp) do
    copy = Path.join(tmp, "catalogue")
    File.cp_r!(Fleet.Catalogue.root(), copy, dereference_symlinks: true)
    copy
  end

  test "the bundled catalogue passes every check" do
    assert {:ok, %{root: root, assumptions: assumptions}} =
             CatalogueVerify.verify(to_string(Fleet.Catalogue.root()))

    assert root == to_string(Fleet.Catalogue.root())
    # The header that guards against the panachage false-green is always present.
    assert Enum.any?(assumptions, &(&1 =~ "root read"))
    assert Enum.any?(assumptions, &(&1 =~ "IGNORED"))
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
    # Manifest is the precondition tier: exactly ONE finding, no cascade of image/spawn errors.
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

    # Point a real workflow STEP at a role no cap-profile declares. Anchored on the step's
    # indentation (`^      role: <name>`), NOT a bare `role:` — the latter also matches the prose in
    # the header comments, and a mutated comment is invisible to the image (it hashes the PARSED
    # map), the very trap `Fleet.CatalogueTest` documents. The manifest and both images still publish
    # (the profiles are intact); the break surfaces exactly where the boot would hit it.
    map = Path.join(copy, "workflow/canon/workflow_maps/c0-poc.yaml")

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
    # Delete a SUBAGENT TEMPLATE a role declares: the cap-profile still loads and passes the schema,
    # both images still publish (the other templates satisfy their root), but `CanonProof` calls the
    # spawn path, which composes — so the break lands on the spawn-proof, the stage schema validation
    # cannot reach. This is the check the card test could not exercise, and it proves the stage is
    # wired through the shared `prove_canon!`.
    #
    # It used to delete the role's DRAFT, and that stopped reaching this stage: the SP image now
    # refuses a declared role whose catalogue carries no prompt for it, so the fault is named one
    # tier earlier and more precisely. The break had to move to keep proving what this test is for.
    copy = catalogue_copy(tmp)
    File.rm!(Path.join(copy, "cap_profile/canon/subagent-templates/subagent-spec-reviewer.md"))

    assert {:error, %{findings: findings}} = CatalogueVerify.verify(copy)

    assert Enum.any?(findings, &(&1.stage == "canon spawn-proof")),
           "a role missing its subagent template should fail the spawn-proof, got: #{inspect(findings)}"

    refute Enum.any?(findings, &(&1.stage =~ "image")),
           "the images were intact — they must not appear as findings"
  end

  test "a role DECLARED by a catalogue that carries no SP for it is refused at the image", %{
    tmp_dir: tmp
  } do
    # The asymmetric half, and the earlier tier: declaring a role without its prompt. The message
    # names the contract rather than the spawn symptom, because the author's fault is the missing
    # file, not the pod that would have died on it.
    copy = catalogue_copy(tmp)
    File.rm!(Path.join(copy, "sp_builder/sp_drafts/agent-engineer-base.md"))

    assert {:error, %{findings: findings}} = CatalogueVerify.verify(copy)

    assert Enum.any?(findings, &(&1.stage == "sp-builder image" and &1.error =~ "engineer")),
           "got: #{inspect(findings)}"
  end

  test "carrying a draft WITHOUT the role is a supersession, and stays silent", %{tmp_dir: tmp} do
    # The other side of the asymmetry, and the one that must never be reported: a catalogue may
    # rewrite the prompt of a role it did not write, by putting a file at the same relative path.
    # `gatekeeper` is declared by the system catalogue alone — here only its SP is superseded.
    copy = catalogue_copy(tmp)

    File.write!(
      Path.join(copy, "sp_builder/sp_drafts/agent-gatekeeper-base.md"),
      "# Gatekeeper, in my own words\n"
    )

    assert {:ok, _} = CatalogueVerify.verify(copy)
  end

  test "a business catalogue overriding a SYSTEM role BY NAME passes", %{tmp_dir: tmp} do
    # The gesture the two retracted refusals blocked. An override of `architect` necessarily
    # declares `project_delegate` (its capability IS what makes it the architect), and the old
    # "a business role may not declare a system capability" refused exactly that. It was right
    # while a name collision was itself a refusal; since the resolver reads an ordered search path,
    # it forbade the feature. What tells an override from a conflict now is the MERGED index —
    # one entry, one delegate, one slot — checked at boot rather than here.
    copy = catalogue_copy(tmp)

    override =
      Fleet.Catalogue.system_root()
      |> Path.join("cap_profile/canon/cap-profiles/architect.yaml")
      |> File.read!()

    # Kept byte-identical on purpose: the point under test is that the SUPERPOSITION is admitted,
    # and any edit would move the failure to whatever the edit broke.
    File.write!(Path.join(copy, "cap_profile/canon/cap-profiles/architect.yaml"), override)

    assert {:ok, _} = CatalogueVerify.verify(copy)
  end

  test "a catalogue with NO sp_blocks/ passes — hand-written drafts owe no blocks", %{
    tmp_dir: tmp
  } do
    # The web catalogue's shape, and the one a newcomer writes first: four roles, four SPs typed by
    # hand, no composer. `sp_blocks/` is BUILD-TIME material for an author who composes; a catalogue
    # that ships its drafts finished never needs it. Proven on a bench up to the seal, held by
    # nothing until here — and the resolver reaching into the system root for `core/` is exactly the
    # kind of change that could have made an absent tree start mattering.
    copy = catalogue_copy(tmp)
    File.rm_rf!(Path.join(copy, "sp_builder/sp_blocks"))

    assert {:ok, _} = CatalogueVerify.verify(copy)
  end

  test "verify covers the CATALOGUE, not the deployment — no forge/token guard leaks in",
       %{tmp_dir: tmp} do
    # A complete catalogue on a machine with no forge configured must pass: the forge base_url,
    # tokens and credentials are deployment config, deliberately outside the verifier's scope.
    assert {:ok, _} = CatalogueVerify.verify(catalogue_copy(tmp))
  end
end
