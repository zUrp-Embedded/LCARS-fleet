defmodule Fleet.Spawner.Pod.AssetsProtocolTest do
  @moduledoc """
  Exercise interlocutor selection against a published image using distinct fixture markers.
  `Fleet.SPBuilderImageParityTest` covers parity with the disk regime.
  """
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod.Assets
  alias Fleet.SPBuilder.Image

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    drafts = Path.join(tmp, "drafts")
    File.mkdir_p!(drafts)
    File.write!(Path.join(drafts, "protocole-user-worker.md"), "MACHINE-CONTRACT\n")
    File.write!(Path.join(drafts, "protocole-user-human.md"), "HUMAN-CONTRACT\n")
    # publish! requires at least one role draft under the root (proven-good or do not boot).
    File.write!(Path.join(drafts, "agent-probe-base.md"), "# probe\n")

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :sp_builder_sp_drafts_root, drafts)

    Fleet.TestEnv.put_env_restoring(
      :lcars_fleet,
      :spawner_protocole_user_path,
      Path.join(drafts, "protocole-user-worker.md")
    )

    :ok = Image.publish!()
    on_exit(fn -> Image.unpublish() end)
    :ok
  end

  defp cap(who) do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "probe"},
      spec: %{"interlocutor" => who}
    }
  end

  test "interlocutor: fleet → the machine contract alone" do
    assert {:ok, served} = Assets.read_protocole_user(cap("fleet"))
    assert served =~ "MACHINE-CONTRACT"

    refute served =~ "HUMAN-CONTRACT",
           "a pod with nobody in front must not be told how to talk to a human"
  end

  test "interlocutor: human → the conversation contract alone, no work-item rail" do
    assert {:ok, served} = Assets.read_protocole_user(cap("human"))
    assert served =~ "HUMAN-CONTRACT"

    refute served =~ "MACHINE-CONTRACT",
           "a human-driven pod must not be handed the work-item cycle it does not run"
  end

  test "interlocutor: both → the machine contract AND the human one, machine first" do
    # Machine protocol comes first to start the pod; the human protocol supports conversation.
    assert {:ok, served} = Assets.read_protocole_user(cap("both"))
    assert served =~ "MACHINE-CONTRACT"
    assert served =~ "HUMAN-CONTRACT"

    machine_at = :binary.match(served, "MACHINE-CONTRACT") |> elem(0)
    human_at = :binary.match(served, "HUMAN-CONTRACT") |> elem(0)
    assert machine_at < human_at
  end

  test "the three values do not collapse — each serves a distinct document" do
    served =
      for who <- ["fleet", "both", "human"], into: %{} do
        assert {:ok, content} = Assets.read_protocole_user(cap(who))
        {who, content}
      end

    assert map_size(Map.new(served, fn {_who, c} -> {c, true} end)) == 3
  end

  test "the canon's own interlocutors are declared, and the architect is dual" do
    # Read catalogue declarations: architect/starfleet support both interaction modes.
    for {role, expected} <- [
          {"architect", "both"},
          {"starfleet", "both"},
          {"engineer", "fleet"},
          {"scoper", "fleet"},
          {"qualifier", "fleet"},
          {"reviewer", "fleet"},
          {"gatekeeper", "fleet"}
        ] do
      assert {:ok, profile} = Fleet.CapProfile.load(role)

      assert Fleet.CapProfile.interlocutor(profile) == expected,
             "#{role} declares #{inspect(Fleet.CapProfile.interlocutor(profile))}, expected #{expected}"
    end
  end
end
