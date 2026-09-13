defmodule Fleet.Pilot.CompletionOutboxReplayTest do
  @moduledoc """
  Exercises consumer replay of a file-backed payload after a returned completer error.
  Verifies raw result retention, derived pod/input identity and journal removal on success.
  Calls handlers directly: no BEAM restart, killed Task, real push/PR or exactly-once
  forge convergence is exercised.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.CompletionOutbox
  alias Fleet.Pilot.StepRunConsumer

  # Returns an error; it neither raises nor kills a completion Task.
  defmodule CompleterQuiMeurt do
    def complete_pr(_step_run, _opts), do: {:error, :task_morte}
    def await_arch(_step_run, _opts), do: {:error, :task_morte}
  end

  # Observe the derived completion passed to the successful replay stub.
  defmodule CompleterQuiAboutit do
    def complete_pr(step_run, _opts) do
      if obs = Process.whereis(:outbox_replay_observer), do: send(obs, {:complete, step_run})
      {:ok, :fait}
    end

    def await_arch(_step_run, _opts), do: {:ok, :awaiting_arch}
  end

  defp dmode,
    do: fn
      "engineer", _root -> {:ok, "git_native"}
      _, _root -> {:ok, "payload"}
    end

  defp state(completer) do
    %StepRunConsumer{
      repo: "lordzurp/lcars-test",
      remote: "origin",
      forge_opts: [base_url: "http://192.0.2.10"],
      role_emails: fn role -> ["#{role}@lcars.local"] end,
      step_run_completer: completer,
      deliverable_mode_fun: dmode()
    }
  end

  defp payload do
    %{
      "pod_id" => "pod-abc",
      "work_item_id" => "wi-6127",
      "issue_id" => "issue-42",
      "result" => %{"ok" => true, "empreinte" => "LE-TRAVAIL-DE-L-AGENT"},
      "workspace" => "/pods/pod-abc/workspace",
      "base_sha" => "cafe1234",
      "base_branch" => "main",
      "role" => "engineer"
    }
  end

  defp evenement, do: Fleet.Event.new(:spawner, :"pod.completed", payload: payload())

  setup do
    root = Fleet.TestEnv.tmp_path("outbox-replay")
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_completion_outbox_root, root)
    on_exit(fn -> File.rm_rf(root) end)
    :ok
  end

  test "chaine interrompue -> le resultat RESTE du ; reprise -> meme resultat, journal vide" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert {:noreply, _} = StepRunConsumer.handle_info(evenement(), state(CompleterQuiMeurt))
    end)

    assert [%{"work_item_id" => "wi-6127"} = du] = CompletionOutbox.pending(),
           "une completion interrompue doit rester DUE — sinon le travail de l'agent est perdu"

    assert get_in(du, ["result", "empreinte"]) == "LE-TRAVAIL-DE-L-AGENT",
           "c'est le RESULTAT qui doit survivre, pas seulement un marqueur"

    # Invoke the replay handler directly. Registration ends when this test process exits.
    Process.register(self(), :outbox_replay_observer)

    assert {:noreply, _} =
             StepRunConsumer.handle_info(:replay_completion_outbox, state(CompleterQuiAboutit))

    # The raw result is checked in the journal above; the derived step_run retains pod and input SHA.
    assert_received {:complete, step_run}
    assert step_run.pod_id == "pod-abc"
    assert step_run.deliverable_opts.provenance.input_sha == "cafe1234"

    assert CompletionOutbox.pending() == []
  end

  test "chaine qui ABOUTIT du premier coup -> rien ne reste du" do
    # Process registration disappears with the test process.
    Process.register(self(), :outbox_replay_observer)

    assert {:noreply, _} = StepRunConsumer.handle_info(evenement(), state(CompleterQuiAboutit))
    assert_received {:complete, _}
    assert CompletionOutbox.pending() == []
  end

  # An empty journal must not invent a completion.
  test "TEMOIN — la reprise sur un journal VIDE ne fabrique aucune completion" do
    # Process registration disappears with the test process.
    Process.register(self(), :outbox_replay_observer)

    assert CompletionOutbox.pending() == []

    assert {:noreply, _} =
             StepRunConsumer.handle_info(:replay_completion_outbox, state(CompleterQuiAboutit))

    refute_received {:complete, _}
  end

  # Missing workspace takes the consumer skip path, which removes the journal entry.
  test "un pod.completed SANS projet est acquitte : {:skip, _} retire l'entree du journal" do
    sans_projet =
      Fleet.Event.new(:spawner, :"pod.completed", payload: Map.delete(payload(), "workspace"))

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:noreply, _} = StepRunConsumer.handle_info(sans_projet, state(CompleterQuiMeurt))
    end)

    assert CompletionOutbox.pending() == []
  end
end
