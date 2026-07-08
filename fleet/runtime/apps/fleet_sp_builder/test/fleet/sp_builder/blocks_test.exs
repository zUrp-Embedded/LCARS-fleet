defmodule Fleet.SPBuilder.BlocksTest do
  use ExUnit.Case, async: true

  alias Fleet.SPBuilder.Blocks

  # `priv` résolu au RUNTIME (l'app est démarrée en test) — le _build reflète la source au dernier compile.
  defp blocks_dir, do: :fleet_sp_builder |> Application.app_dir("priv") |> Path.join("sp_blocks")
  defp drafts_dir, do: :fleet_sp_builder |> Application.app_dir("priv") |> Path.join("sp_drafts")

  test "chaque rôle de la carte compose un SP non vide et titré" do
    for {role, blocks} <- Blocks.role_map(blocks_dir()) do
      sp = Blocks.compose!(role, blocks, blocks_dir())
      assert sp =~ "# System Prompt — #{role}"
      assert String.length(sp) > 200
    end
  end

  test "no-drift : le flat committé == la re-génération depuis les blocs (sinon `mix lcars.sp.gen`)" do
    for {role, blocks} <- Blocks.role_map(blocks_dir()) do
      committed = drafts_dir() |> Path.join("agent-#{role}-base.md") |> File.read!()

      assert committed == Blocks.compose!(role, blocks, blocks_dir()),
             "agent-#{role}-base.md a drifté de ses blocs → lance `mix lcars.sp.gen` et committe"
    end
  end

  test "fail-loud : un bloc listé absent → lève (no-fallback)" do
    assert_raise RuntimeError, ~r/no-fallback/, fn ->
      Blocks.compose!("x", ["core/n-existe-pas"], blocks_dir())
    end
  end

  test "fail-loud : rôle sans blocs → lève (no-fallback)" do
    assert_raise RuntimeError, ~r/no-fallback/, fn ->
      Blocks.compose!("x", [], blocks_dir())
    end
  end

  test "complétude catalogue : chaque rôle-pod a son SP dédié (le flip no-fallback briquerait son spawn sinon)" do
    # Rôles spawnés via `Fleet.Spawner.Pod.Assets.read_agent_draft` (bwrap/host pods). Hors liste :
    # `starfleet` (host-native, booté par un systemd unit séparé, ne passe PAS par assets.ex).
    # `architect` garde son draft historique (socle user-facing, hors blocs). Un NOUVEAU rôle-pod → l'ajouter
    # ici ET lui donner un draft, sinon son spawn meurt dur (no-fallback, cf. no-sp-no-pod-no-fleet).
    pod_roles = ~w(architect consultant engineer gatekeeper qualifier reviewer)

    for role <- pod_roles do
      path = Path.join(drafts_dir(), "agent-#{role}-base.md")

      assert File.exists?(path),
             "agent-#{role}-base.md manquant → le spawn de #{role} briquerait (no-fallback). " <>
               "Compose-le (bloc + carte sp-map.yaml + `mix lcars.sp.gen`) ou fournis son draft."
    end
  end
end
