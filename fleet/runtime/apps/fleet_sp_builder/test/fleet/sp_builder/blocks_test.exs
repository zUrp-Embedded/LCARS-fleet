defmodule Fleet.SPBuilder.BlocksTest do
  use ExUnit.Case, async: true

  alias Fleet.SPBuilder.Blocks

  # `priv` resolved at RUNTIME (the app is started in test) — `_build` mirrors the source at the last compile.
  defp blocks_dir, do: :fleet_sp_builder |> Application.app_dir("priv") |> Path.join("sp_blocks")
  defp drafts_dir, do: :fleet_sp_builder |> Application.app_dir("priv") |> Path.join("sp_drafts")

  test "each role in the map composes a non-empty, titled SP" do
    roles = Blocks.role_map(blocks_dir())

    # Anti-vacuité : un `for` sur une map VIDE ne lève rien → le test passerait VERT sans exécuter la
    # moindre assertion (ex. sp-map.yaml introuvable dans _build). On exige au moins un rôle AVANT la boucle.
    assert map_size(roles) > 0,
           "role_map vide (sp-map.yaml introuvable ?) → la boucle ne teste RIEN"

    for {role, blocks} <- roles do
      sp = Blocks.compose!(role, blocks, blocks_dir())
      assert sp =~ "# System Prompt — #{role}"
      assert String.length(sp) > 200
    end
  end

  test "no-drift: the committed flat == the regeneration from the blocks (else run `mix lcars.sp.gen`)" do
    roles = Blocks.role_map(blocks_dir())

    assert map_size(roles) > 0,
           "role_map vide (sp-map.yaml introuvable ?) → le no-drift ne compare RIEN"

    for {role, blocks} <- roles do
      committed = drafts_dir() |> Path.join("agent-#{role}-base.md") |> File.read!()

      assert committed == Blocks.compose!(role, blocks, blocks_dir()),
             "agent-#{role}-base.md drifted from its blocks → run `mix lcars.sp.gen` and commit"
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

  test "catalog completeness: each pod role has its own SP (the no-fallback flip would brick its spawn otherwise)" do
    # Roles spawned via `Fleet.Spawner.Pod.Assets.read_agent_draft` (bwrap/host pods). Excluded:
    # `starfleet` (host-native, booted by a separate systemd unit, does NOT go through assets.ex).
    # `architect` keeps its historical draft (user-facing socle, outside the blocks). A NEW pod role → add it
    # here AND give it a draft, else its spawn dies hard (no-fallback, cf. no-sp-no-pod-no-fleet).
    pod_roles = ~w(architect consultant engineer gatekeeper qualifier reviewer)

    for role <- pod_roles do
      path = Path.join(drafts_dir(), "agent-#{role}-base.md")

      assert File.exists?(path),
             "agent-#{role}-base.md missing → spawning #{role} would brick (no-fallback). " <>
               "Compose it (block + sp-map.yaml + `mix lcars.sp.gen`) or provide its draft."
    end
  end
end
