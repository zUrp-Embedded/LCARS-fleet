defmodule Fleet.Pilot.HopConsumerTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.HopConsumer

  # Seam HopCompleter : capture le hop reçu + retourne un outcome configurable.
  defmodule CaptureCompleter do
    def complete(hop, opts) do
      send(self(), {:hop, hop, opts})
      {:ok, :completed}
    end
  end

  # Seam Loader (A2.4) : carte poc-cycle linéaire ; "bad" raise (pipeline introuvable).
  defmodule StubLoader do
    def load!("poc-cycle") do
      %{
        "name" => "poc-cycle",
        "stages" => %{
          "triage" => %{"role" => "architect", "needs" => []},
          "refine" => %{"role" => "consultant", "needs" => ["triage"]},
          "build" => %{"role" => "engineer", "needs" => ["refine"]},
          "review" => %{"role" => "reviewer", "needs" => ["build"]}
        }
      }
    end

    def load!(_), do: raise("pipeline introuvable")
  end

  defp state(extra \\ %{}) do
    Map.merge(
      %HopConsumer{
        repo: "lordzurp/lcars-test",
        remote: "origin",
        forge_opts: [base_url: "http://10.42.0.118"],
        role_emails: fn role -> ["#{role}@lcars.local"] end,
        hop_completer: CaptureCompleter
      },
      extra
    )
  end

  defp stage_payload(extra \\ %{}) do
    Map.merge(
      %{
        "pod_id" => "pod-abc",
        "ticket_id" => "issue-42",
        "result" => %{"ok" => true},
        "workspace" => "/pods/pod-abc/workspace",
        "base_sha" => "cafe1234",
        "role" => "engineer"
      },
      extra
    )
  end

  describe "maybe_complete/2 — traduction event → hop" do
    test "pod stage-dispatch porteur de projet → hop git_native, terminal (close)" do
      assert {:ok, :completed} = HopConsumer.maybe_complete(stage_payload(), state())

      assert_received {:hop, hop, opts}
      assert hop.repo == "lordzurp/lcars-test"
      assert hop.issue_number == 42
      assert hop.role == "engineer"
      assert hop.next_assignee == nil
      assert hop.state_label == "state:delivered"

      d = hop.deliverable_opts
      assert d.mode == :git_native
      assert d.workspace == "/pods/pod-abc/workspace"
      assert d.base_sha == "cafe1234"
      assert d.allowed_emails == ["engineer@lcars.local"]
      assert d.remote == "origin"
      assert d.target_branch == "lcars/issue-42-engineer"
      assert d.push? == true

      assert opts[:forge_opts] == [base_url: "http://10.42.0.118"]
    end
  end

  describe "maybe_complete/2 — filtres (skip)" do
    test "pipeline pod (pipeline_id présent) → skip, pas d'appel completer" do
      payload = stage_payload(%{"pipeline_id" => "pl-1", "stage" => "build"})
      assert {:skip, :pipeline_pod} = HopConsumer.maybe_complete(payload, state())
      refute_received {:hop, _, _}
    end

    test "pod sans projet (pas de base_sha) → skip" do
      payload = stage_payload(%{"base_sha" => nil, "workspace" => nil})
      assert {:skip, :no_project} = HopConsumer.maybe_complete(payload, state())
      refute_received {:hop, _, _}
    end

    test "base_sha vide → skip (pas de livrable git)" do
      payload = stage_payload(%{"base_sha" => ""})
      assert {:skip, :no_project} = HopConsumer.maybe_complete(payload, state())
    end

    test "ticket_id non parseable → skip" do
      payload = stage_payload(%{"ticket_id" => "owner/repo#42"})

      assert {:skip, {:bad_ticket_id, "owner/repo#42"}} =
               HopConsumer.maybe_complete(payload, state())
    end
  end

  describe "A2.4 — chaînage carte (pipeline+stage → next_assignee)" do
    test "stage milieu de chaîne → reassign vers le rôle suivant" do
      payload = stage_payload(%{"pipeline" => "poc-cycle", "stage" => "build"})
      assert {:ok, :completed} = HopConsumer.maybe_complete(payload, state(%{loader: StubLoader}))

      assert_received {:hop, hop, _opts}
      # build → review (rôle reviewer)
      assert hop.next_assignee == "reviewer"
    end

    test "dernier stage → terminal (next_assignee nil → close)" do
      payload = stage_payload(%{"pipeline" => "poc-cycle", "stage" => "review"})
      assert {:ok, :completed} = HopConsumer.maybe_complete(payload, state(%{loader: StubLoader}))

      assert_received {:hop, hop, _opts}
      assert hop.next_assignee == nil
    end

    test "carte introuvable → {:error, {:carte_load, _}}, pas de hop" do
      payload = stage_payload(%{"pipeline" => "bad", "stage" => "build"})

      assert {:error, {:carte_load, _}} =
               HopConsumer.maybe_complete(payload, state(%{loader: StubLoader}))

      refute_received {:hop, _, _}
    end

    test "stage inconnu dans la carte → {:error, {:carte_nav, :unknown_stage}}, pas de misroute" do
      payload = stage_payload(%{"pipeline" => "poc-cycle", "stage" => "ghost"})

      assert {:error, {:carte_nav, :unknown_stage}} =
               HopConsumer.maybe_complete(payload, state(%{loader: StubLoader}))

      refute_received {:hop, _, _}
    end

    test "sans contexte carte (A1 1-stage) → terminal, pas d'appel loader" do
      # loader nil : si run_hop appelait le loader sans contexte carte, ça crasherait.
      payload = stage_payload()
      assert {:ok, :completed} = HopConsumer.maybe_complete(payload, state())
      assert_received {:hop, hop, _opts}
      assert hop.next_assignee == nil
    end
  end

  describe "parse_issue_number/1" do
    test "issue-N → {:ok, N}" do
      assert {:ok, 7} = HopConsumer.parse_issue_number("issue-7")
    end

    test "format legacy / inconnu → :error" do
      assert :error = HopConsumer.parse_issue_number("owner/repo#7")
      assert :error = HopConsumer.parse_issue_number("issue-7x")
      assert :error = HopConsumer.parse_issue_number("issue-")
    end
  end

  describe "GenServer lifecycle" do
    test "crash si :repo ou :remote manquant" do
      Process.flag(:trap_exit, true)

      assert {:error, {:missing_required_opt, :repo}} =
               HopConsumer.start_link(
                 name: :"HC_norepo_#{System.unique_integer([:positive])}",
                 remote: "origin",
                 subscribe: false
               )

      assert {:error, {:missing_required_opt, :remote}} =
               HopConsumer.start_link(
                 name: :"HC_noremote_#{System.unique_integer([:positive])}",
                 repo: "o/r",
                 subscribe: false
               )
    end

    test "handle_info pod.completed → délègue (via Event réel, subscribe: false)" do
      name = :"HC_live_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        HopConsumer.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          remote: "origin",
          hop_completer: CaptureCompleter,
          subscribe: false
        )

      # Le completer fait send(self()) DANS le GenServer → on vérifie juste que
      # l'event est routé sans crash (le hop est unit-testé via maybe_complete).
      event = %Fleet.Event{
        source: :spawner,
        type: :"pod.completed",
        timestamp: DateTime.utc_now(),
        pod_id: "pod-abc",
        payload: stage_payload()
      }

      send(pid, event)
      assert Process.alive?(pid)
      # un event non-spawner est ignoré sans crash
      send(pid, %Fleet.Event{
        source: :task_queue,
        type: :task_completed,
        timestamp: DateTime.utc_now(),
        payload: %{}
      })

      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end
end
