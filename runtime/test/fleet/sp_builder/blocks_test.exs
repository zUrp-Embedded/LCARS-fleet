defmodule Fleet.SPBuilder.BlocksTest do
  use ExUnit.Case, async: true

  alias Fleet.SPBuilder.Blocks

  # Business root plus resolver fallback to system core blocks.
  defp blocks_dir, do: Fleet.Catalogue.sp_blocks_root()

  # Drafts may live in either catalogue; use the consumer's resolver.
  defp draft_path(role), do: Fleet.SPBuilder.sp_draft_path(role)

  test "each role in the map composes a non-empty, titled SP" do
    roles = Blocks.role_map(blocks_dir())

    # Prevent an empty map from passing without composing a role.
    assert map_size(roles) > 0,
           "empty role_map (sp-map.yaml not found?) → the loop tests NOTHING"

    for {role, blocks} <- roles do
      sp = Blocks.compose!(role, blocks, blocks_dir())
      assert sp =~ "# System Prompt — #{role}"
      assert String.length(sp) > 200
    end
  end

  test "no-drift: the committed flat == the regeneration from the blocks (else run `mix lcars.sp.gen`)" do
    roles = Blocks.role_map(blocks_dir())

    assert map_size(roles) > 0,
           "empty role_map (sp-map.yaml not found?) → the no-drift compares NOTHING"

    for {role, blocks} <- roles do
      committed = role |> draft_path() |> File.read!()

      assert committed == Blocks.compose!(role, blocks, blocks_dir()),
             "agent-#{role}-base.md drifted from its blocks → run `mix lcars.sp.gen` and commit"
    end
  end

  describe "the blocks are a SEARCH PATH — `core/` is a shipped default, not a buried constant" do
    @moduletag :tmp_dir

    # A business blocks root of our own, with the REAL system root behind it. Nothing is copied:
    # what the composer finds under `core/` it finds because the resolver went looking there.
    defp business_blocks(tmp) do
      dir = Path.join([tmp, "cat", Fleet.Catalogue.rel(:sp_blocks)])
      File.mkdir_p!(Path.join(dir, "core"))
      dir
    end

    test "a business catalogue with NO core/ still composes — the system default is found", %{
      tmp_dir: tmp
    } do
      sp = Blocks.compose!("x", ["core/runtime-contract"], business_blocks(tmp))

      assert sp =~ "submit_result",
             "the system core/ block was not reached — the composer read one root"
    end

    test "a business block at the same relative path WINS, and nothing is written to the system",
         %{tmp_dir: tmp} do
      dir = business_blocks(tmp)

      system_file =
        Path.join([
          Fleet.Catalogue.system_root(),
          "sp_builder/sp_blocks/core/runtime-contract.md"
        ])

      before = File.read!(system_file)

      File.write!(
        Path.join(dir, "core/runtime-contract.md"),
        "MINE, and in Esperanto if I want.\n"
      )

      sp = Blocks.compose!("x", ["core/runtime-contract"], dir)
      assert sp =~ "MINE, and in Esperanto"
      refute sp =~ "submit_result"

      # The child-theme property: the default is untouched on disk, so removing the override
      # restores it. Superseding happens at READ time — this is the half a `cp` would break.
      assert File.read!(system_file) == before
      File.rm!(Path.join(dir, "core/runtime-contract.md"))
      assert Blocks.compose!("x", ["core/runtime-contract"], dir) =~ "submit_result"
    end
  end

  describe "generate! confined — `--catalogue` writes nothing outside the catalogue it was given" do
    @describetag :tmp_dir

    test "an operator's own `gatekeeper` lands in THEIR tree, and the system's is untouched", %{
      tmp_dir: tmp
    } do
      # An existing system draft is the discriminator: unconfined generation would overwrite it.
      system_draft =
        Path.join([
          Fleet.Catalogue.system_root(),
          Fleet.Catalogue.rel(:sp_drafts),
          "agent-gatekeeper-base.md"
        ])

      before = File.read!(system_draft)

      blocks = Path.join([tmp, "cat", Fleet.Catalogue.rel(:sp_blocks)])
      drafts = Path.join([tmp, "cat", Fleet.Catalogue.rel(:sp_drafts)])
      File.mkdir_p!(Path.join(blocks, "role"))
      File.mkdir_p!(drafts)
      File.write!(Path.join(blocks, "role/mine.md"), "## Role — a moi\n")
      File.write!(Path.join(blocks, "sp-map.yaml"), "gatekeeper:\n  - role/mine\n")

      assert ["gatekeeper"] = Blocks.generate!(blocks, drafts, confined?: true)

      assert File.read!(Path.join(drafts, "agent-gatekeeper-base.md")) =~ "Role — a moi"
      assert File.read!(system_draft) == before, "the system catalogue must never be written to"
    end
  end

  test "fail-loud: a listed block absent from disk → raises (no-fallback)" do
    assert_raise RuntimeError, ~r/no-fallback/, fn ->
      Blocks.compose!("x", ["core/does-not-exist"], blocks_dir())
    end
  end

  test "fail-loud: a role with no blocks → raises (no-fallback)" do
    assert_raise RuntimeError, ~r/no-fallback/, fn ->
      Blocks.compose!("x", [], blocks_dir())
    end
  end

  describe "audit!: every role owes EXACTLY ONE source for its SP" do
    # Shipped-content checks depend on architect remaining a hand-written draft.

    test "the bundled catalogue passes its own audit" do
      assert :ok = Blocks.audit!(roster!(), Blocks.role_map(blocks_dir()))
    end

    test "NEITHER an entry nor a draft → refused, and the role is named" do
      assert_raise RuntimeError, ~r/ghost-role-xyz carry NEITHER/, fn ->
        Blocks.audit!(["ghost-role-xyz"], %{})
      end
    end

    test "an entry for a role the catalogue does not carry → refused (blocks for a ghost)" do
      assert_raise RuntimeError, ~r/nobody are named by sp-map.yaml/, fn ->
        Blocks.audit!(["engineer"], %{"nobody" => ["core/runtime-contract"]})
      end
    end

    test "an entry AND a hand-written draft → refused before composing overwrites it" do
      assert_raise RuntimeError, ~r/architect carry BOTH/, fn ->
        Blocks.audit!(["architect"], %{"architect" => ["core/runtime-contract"]})
      end
    end

    test "a draft and NO entry is the hand-written family — silent, not a violation" do
      assert :ok = Blocks.audit!(["architect", "starfleet"], %{})
    end

    test "every disagreement is named at once, not the first one" do
      message =
        assert_raise RuntimeError, fn ->
          Blocks.audit!(["architect", "ghost-role-xyz"], %{
            "architect" => ["core/runtime-contract"],
            "nobody" => ["core/runtime-contract"]
          })
        end

      assert message.message =~ "ghost-role-xyz carry NEITHER"
      assert message.message =~ "nobody are named by sp-map.yaml"
      assert message.message =~ "architect carry BOTH"
    end

    defp roster! do
      {:ok, roster} = Fleet.CapProfile.forge_roster()
      Enum.map(roster, & &1.name)
    end
  end

  test "catalog completeness: each pod role has its own SP (the no-fallback flip would brick its spawn otherwise)" do
    # Derive the population from CapProfile.list/0, excluding ReservedSeats. This checks
    # draft existence, not readability/content or whether every other spawn prerequisite holds.
    {:ok, pod_roles} = Fleet.CapProfile.list()

    # Anti-vacuity, same reason as above: an empty list would loop over nothing and pass.
    assert length(pod_roles) >= 8,
           "the catalogue returns #{length(pod_roles)} spawnable roles — the instrument is broken, " <>
             "not the tree (measured: 8 on 2026-08-03)"

    for role <- pod_roles do
      path = draft_path(role)

      assert File.exists?(path),
             "agent-#{role}-base.md missing → spawning #{role} would brick (no-fallback). " <>
               "Compose it (block + sp-map.yaml + `mix lcars.sp.gen`) or provide its draft."
    end
  end
end
