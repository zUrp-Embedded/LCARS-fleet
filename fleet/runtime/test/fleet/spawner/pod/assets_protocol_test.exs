defmodule Fleet.Spawner.Pod.AssetsProtocolTest do
  @moduledoc """
  The protocol a pod is provisioned with is SELECTED by its cap-profile's `interlocutor`, not
  assumed. Before that field existed the rail had no branch at all: every pod — the interactive
  architect included — was handed the machine contract, which tells its reader that `SeeU` closes
  nothing and that no handoff exists. True of an engineer, false of a role a human talks to.

  These tests drive the IMAGE regime, which is the one a deployed fleet runs on, with marker
  contents so the assertions read what was actually served rather than a substring of the shipped
  documents. The disk regime is covered where it belongs — `Fleet.SPBuilderImageParityTest` proves
  the two regimes serve identical bytes for all three values, so neither suite asserts the other's
  job.
  """
  use ExUnit.Case, async: false

  alias Fleet.SPBuilder.Image
  alias Fleet.Spawner.Pod.Assets

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    drafts = Path.join(tmp, "drafts")
    File.mkdir_p!(drafts)
    File.write!(Path.join(drafts, "protocole-user-worker.md"), "MACHINE-CONTRACT\n")
    File.write!(Path.join(drafts, "protocole-user-human.md"), "HUMAN-CONTRACT\n")
    # publish! requires at least one role draft under the root (proven-good or do not boot).
    File.write!(Path.join(drafts, "agent-probe-base.md"), "# probe\n")

    Fleet.TestEnv.put_env_restoring(:fleet_sp_builder, :sp_drafts_root, drafts)

    Fleet.TestEnv.put_env_restoring(
      :fleet_spawner,
      :protocole_user_path,
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
    # ADDITIVE, not a replacement: the architect is kicked by the machine and talked to by a human
    # at the same terminal, so dropping either half breaks one of its two rails. Machine first
    # because that is the contract that starts the pod; the human half is what it does once alive.
    assert {:ok, served} = Assets.read_protocole_user(cap("both"))
    assert served =~ "MACHINE-CONTRACT"
    assert served =~ "HUMAN-CONTRACT"

    machine_at = :binary.match(served, "MACHINE-CONTRACT") |> elem(0)
    human_at = :binary.match(served, "HUMAN-CONTRACT") |> elem(0)
    assert machine_at < human_at
  end

  test "the three values do not collapse — each serves a distinct document" do
    # The cheap failure this closes: a branch written so that two values happen to produce the same
    # bytes reads as implemented and is not. Measured, not assumed.
    served =
      for who <- ["fleet", "both", "human"], into: %{} do
        assert {:ok, content} = Assets.read_protocole_user(cap(who))
        {who, content}
      end

    assert map_size(Map.new(served, fn {_who, c} -> {c, true} end)) == 3
  end

  test "the canon's own interlocutors are declared, and the architect is dual" do
    # The catalogue is the source: this asserts the DECLARATION, not a hardcoded role list in the
    # code. `architect`/`starfleet` face a human AND are dispatched by the fleet; the producer and
    # the judges have nobody at their terminal.
    for {role, expected} <- [
          {"architect", "both"},
          {"starfleet", "both"},
          {"engineer", "fleet"},
          {"consultant", "fleet"},
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
