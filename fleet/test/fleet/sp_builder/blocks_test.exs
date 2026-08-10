defmodule Fleet.SPBuilder.BlocksTest do
  use ExUnit.Case, async: true

  alias Fleet.SPBuilder.Blocks

  # The BUSINESS blocks root. `core/` is not under it — it lives in the system catalogue and is
  # reached by the resolver, so a hardcoded path here would compose half the corpus and the
  # no-drift below would compare a truncated SP to the committed one.
  defp blocks_dir, do: Fleet.Catalogue.sp_blocks_root()

  # Le draft d'un role vit avec le role : mecanique dans le catalogue systeme, metier dans l'autre.
  # Le resolveur repond ou qu'il soit — le tester par un chemin en dur reviendrait a epingler la
  # moitie metier et a declarer manquant tout ce qui a demenage.
  defp draft_path(role), do: Fleet.SPBuilder.sp_draft_path(role)

  test "each role in the map composes a non-empty, titled SP" do
    roles = Blocks.role_map(blocks_dir())

    # Anti-vacuity: a `for` over an EMPTY map raises nothing → the test would pass GREEN without
    # running a single assertion (e.g. sp-map.yaml not found in _build). Require at least one role
    # BEFORE the loop.
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
    # Measured against the REAL tree on purpose. Each case below needs one real property — a role
    # that exists, a draft that is hand-written, a name that exists nowhere — and a fixture would
    # only prove the fixture. `architect` is the hand-written twin, and that is not incidental: it
    # is the role the "both" refusal must protect.

    test "the bundled catalogue passes its own audit" do
      assert :ok = Blocks.audit!(roster!(), Blocks.role_map(blocks_dir()))
    end

    test "NEITHER an entry nor a draft → refused, and the role is named" do
      assert_raise RuntimeError, ~r/ghost-role-xyz carry NEITHER/, fn ->
        Blocks.audit!(["ghost-role-xyz"], %{})
      end
    end

    test "an entry for a role the catalogue does not carry → refused (blocks for a ghost)" do
      # Never fatal at spawn — nothing spawns a role that does not exist — which is exactly why
      # nothing would ever report it.
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
      # An operator fixes a catalogue in one pass. Reporting one fault per run turns a three-line
      # fix into three edit-run cycles, which is how the third one gets skipped.
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
    # Roles spawned via `Fleet.Spawner.Pod.Assets.read_agent_draft` (bwrap pods). `architect` and
    # `starfleet` keep a HISTORICAL/manual draft (user-facing socle — one per-project, one fleet-level —
    # outside the composed blocks, so NOT in sp-map.yaml). Every other role is block-composed.
    #
    # DERIVED from the catalogue, not listed. This used to be a hand-written `~w(...)` of the eight
    # names, with a comment telling the reader to add the next role to it — a FIFTH list to keep in
    # sync, checked by nothing, next to the four the contracts check locks precisely because
    # hand-kept lists drift. A role added everywhere else would leave this test green while never
    # testing it: the one test whose job is to catch a missing draft would be the one that missed it.
    #
    # `list/0` filters ReservedSeats out (`vulcan` is not spawnable, so it owes no draft, BL-6-45),
    # which is the exact set that owes one.
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
