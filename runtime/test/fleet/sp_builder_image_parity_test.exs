defmodule Fleet.SPBuilderImageParityTest do
  @moduledoc """
  Compares shipped-role fragment hashes and composed CLAUDE.md between image and disk
  regimes, plus protocol bytes for all interlocutors. The hash comparison does not cover
  role drafts or full rendered system prompts. Production normally publishes while test
  configuration defaults to disk, so both consumption paths need explicit checks.
  """
  use ExUnit.Case, async: false

  alias Fleet.CapProfile
  alias Fleet.Spawner.Pod.Assets
  alias Fleet.SPBuilder

  # Derive role names from the catalogue; underscore-prefixed entries are excluded.
  defp canon_roles do
    {:ok, names} = CapProfile.Catalog.list()
    Enum.reject(names, &String.starts_with?(&1, "_"))
  end

  defp compose_all(roles) do
    Map.new(roles, fn role ->
      {:ok, cap} = CapProfile.resolve(CapProfile, role)
      {:ok, %{stable_sha256: sha}} = SPBuilder.compose(cap, CapProfile.active_modops(cap), [])
      {:ok, claude_md} = SPBuilder.compose_claude_md(cap, nil)
      {role, {sha, claude_md}}
    end)
  end

  setup do
    # Leave both images unpublished, the test default; this does not restore a prior image.
    on_exit(fn ->
      SPBuilder.Image.unpublish()
      CapProfile.Image.unpublish()
    end)

    :ok
  end

  test "every canon role composes IDENTICALLY from the image and from the live disk" do
    roles = canon_roles()
    assert length(roles) >= 5, "the canon should carry the fleet roles, got #{inspect(roles)}"

    SPBuilder.Image.unpublish()
    CapProfile.Image.unpublish()
    from_disk = compose_all(roles)

    :ok = CapProfile.publish_image!()
    :ok = SPBuilder.publish_image!()
    from_image = compose_all(roles)

    divergent =
      for role <- roles,
          {sha_d, cm_d} = Map.fetch!(from_disk, role),
          {sha_i, cm_i} = Map.fetch!(from_image, role),
          sha_d != sha_i or cm_d != cm_i,
          do: {role, sp_equal: sha_d == sha_i, claude_md_equal: cm_d == cm_i}

    assert divergent == [],
           "image and disk regimes disagree — a pod's prompt depends on which one served it: " <>
             inspect(divergent)
  end

  test "the protocole-user is byte-identical in both regimes, for every interlocutor" do
    # Exercise all Assets protocol branches: worker, worker+human, human.
    for who <- ["fleet", "both", "human"] do
      cap = %CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "probe"},
        spec: %{"interlocutor" => who}
      }

      :ok = SPBuilder.publish_image!()
      assert {:ok, from_image} = Assets.read_protocole_user(cap)

      SPBuilder.Image.unpublish()
      assert {:ok, from_disk} = Assets.read_protocole_user(cap)

      assert from_image == from_disk, "interlocutor #{who}: image and disk regimes disagree"
    end
  end

  test "un root de drafts REPOINTE deplace aussi le chemin disque du spawn" do
    # Default-root parity cannot catch a disk reader ignoring the draft override. This case
    # checks that disk path directly; it does not publish/compare the override's image.
    role = "engineer"
    tmp = Fleet.TestEnv.tmp_path("drafts")
    File.mkdir_p!(tmp)
    marker = "MARQUEUR-PARITE-#{System.unique_integer([:positive])}"
    File.write!(Path.join(tmp, "agent-#{role}-base.md"), marker)

    prev = Application.get_env(:lcars_fleet, :sp_builder_sp_drafts_root)
    Application.put_env(:lcars_fleet, :sp_builder_sp_drafts_root, tmp)
    SPBuilder.Image.unpublish()

    on_exit(fn ->
      File.rm_rf(tmp)

      if prev,
        do: Application.put_env(:lcars_fleet, :sp_builder_sp_drafts_root, prev),
        else: Application.delete_env(:lcars_fleet, :sp_builder_sp_drafts_root)
    end)

    assert {:ok, cap} = CapProfile.load(role)
    assert {:ok, content} = Assets.read_agent_draft(cap)

    assert content =~ marker,
           "Pod.Assets a lu un autre arbre que celui que `:sp_drafts_root` designe"
  end
end
