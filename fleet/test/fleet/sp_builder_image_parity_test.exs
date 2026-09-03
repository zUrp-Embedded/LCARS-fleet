defmodule Fleet.SPBuilderImageParityTest do
  @moduledoc """
  The two consumption regimes must produce the SAME prompts, on the REAL canon.

  Why this exists — the hole it closes: prompt material is resolved TWICE. With an image published
  the composer reads the frozen snapshot; without one it reads the live disk. Production always
  publishes (do-not-boot otherwise), so the disk path never runs there — while the whole SP suite
  runs on it, because `:test` disables publication for hermeticity. The suite was therefore
  exercising a path production never takes, and nothing anywhere proved the two agree.

  A second resolution of the same asset is one edit away from diverging with no gate to catch it.
  This IS that gate: it composes every canon role both ways and compares. Whichever regime a test
  happens to run under, this pins that the answer is the same one a pod would receive.
  """
  use ExUnit.Case, async: false

  alias Fleet.CapProfile
  alias Fleet.SPBuilder

  # Every role of the shipped canon — the parity claim is about what pods really get, so the list
  # is READ from the catalogue rather than retyped (a role added without a line here would escape).
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
    # Whatever the suite's ambient regime, this test drives both ends explicitly and leaves the
    # process as it found it: unpublished, the `:test` default the other suites rely on.
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
    # Not composed by SPBuilder but read by the spawner's Assets rail, through its own image
    # accessors — same duplication, same exposure, and it decides what `engage` means to the pod.
    # Swept over the THREE values because each one takes a different path through the rail
    # (machine only, machine + human, human only): a parity proven on `fleet` alone would leave
    # the two branches that actually gained an image accessor unchecked.
    for who <- ["fleet", "both", "human"] do
      cap = %CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "probe"},
        spec: %{"interlocutor" => who}
      }

      :ok = SPBuilder.publish_image!()
      assert {:ok, from_image} = Fleet.Spawner.Pod.Assets.read_protocole_user(cap)

      SPBuilder.Image.unpublish()
      assert {:ok, from_disk} = Fleet.Spawner.Pod.Assets.read_protocole_user(cap)

      assert from_image == from_disk, "interlocutor #{who}: image and disk regimes disagree"
    end
  end

  test "un root de drafts REPOINTE deplace aussi le chemin disque du spawn" do
    # Le cas que la parite sur la racine PAR DEFAUT ne pouvait pas voir : les deux resolveurs
    # coincidaient tant que personne ne deplacait la racine. L'image lisait
    # `:lcars_fleet, :sp_builder_sp_drafts_root`, `Pod.Assets` gardait un literal `app_dir` — repointer la
    # cle deplacait ce que l'image GELAIT et pas ce que le spawn LISAIT. Un catalogue pointe sur un
    # arbre de drafts etranger aurait ete gele depuis lui, et lu depuis le bundle sur le chemin
    # non-publie : deux drafts differents pour un seul role.
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
    assert {:ok, content} = Fleet.Spawner.Pod.Assets.read_agent_draft(cap)

    assert content =~ marker,
           "Pod.Assets a lu un autre arbre que celui que `:sp_drafts_root` designe"
  end
end
