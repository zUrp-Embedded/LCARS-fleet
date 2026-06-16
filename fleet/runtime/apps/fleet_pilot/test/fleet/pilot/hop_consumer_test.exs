defmodule Fleet.Pilot.HopConsumerTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.HopConsumer

  # Seam HopCompleter : capture le hop PR-natif recu + retourne un outcome fixe.
  defmodule CaptureCompleter do
    def complete_pr(hop, opts) do
      send(self(), {:hop, hop, opts})
      {:ok, :captured}
    end
  end

  # Seam Loader (A2.4) : carte engineer-first lineaire (Corr.3) ; "bad" raise (introuvable).
  #   build(engineer, producteur) -> spec(qualifier, juge) -> review(reviewer, juge terminal)
  defmodule StubLoader do
    def load!("poc-cycle") do
      %{
        "name" => "poc-cycle",
        "stages" => %{
          "build" => %{"role" => "engineer", "needs" => []},
          "spec" => %{"role" => "qualifier", "needs" => ["build"]},
          "review" => %{"role" => "reviewer", "needs" => ["spec"]}
        }
      }
    end

    def load!(_), do: raise("pipeline introuvable")
  end

  # Seam ForgeClient (②.1c) : le juge résout la branche producteur via la PR ouverte de l'issue
  # (sans carte). Stub = une PR ouverte pour l'issue 42, head = la branche du producteur.
  defmodule StubForge do
    def list_open_pulls(_repo, _opts) do
      {:ok, [%{"number" => 7, "head" => %{"ref" => "lcars/issue-42-engineer"}}]}
    end
  end

  # Seam deliverable_mode : engineer = git_native (producteur), tout le reste = payload (juge).
  defp dmode,
    do: fn
      "engineer" -> "git_native"
      _ -> "payload"
    end

  defp state(extra \\ %{}) do
    Map.merge(
      %HopConsumer{
        repo: "lordzurp/lcars-test",
        remote: "origin",
        forge_opts: [base_url: "http://10.42.0.118"],
        role_emails: fn role -> ["#{role}@lcars.local"] end,
        hop_completer: CaptureCompleter,
        deliverable_mode_fun: dmode()
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

  describe "maybe_complete/2 — traduction event -> hop PR-natif" do
    test "pod engineer porteur de projet (A1) -> hop producteur, terminal (:promote)" do
      assert {:ok, :captured} = HopConsumer.maybe_complete(stage_payload(), state())

      assert_received {:hop, hop, opts}
      assert hop.repo == "lordzurp/lcars-test"
      assert hop.issue_number == 42
      assert hop.role == "engineer"
      assert hop.pr_role == :producer
      assert hop.intent == :promote
      assert hop.next_assignee == nil
      assert hop.producer_branch == "lcars/issue-42-engineer"
      assert hop.base_branch == "main"

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

  describe "F067 — offload de la completion (hop_runner)" do
    test "hop_runner async -> completion offloadee (le singleton ne bloque pas sur .complete_pr)" do
      test_pid = self()

      # Runner "recording" : capture l'exec sans le lancer (simule l'offload Task.Supervisor) ->
      # prouve que .complete_pr passe par le runner, pas en direct (bloquant) dans le GenServer.
      recording = fn exec ->
        send(test_pid, {:offloaded, exec})
        {:ok, :offloaded}
      end

      assert {:ok, :offloaded} =
               HopConsumer.maybe_complete(stage_payload(), state(%{hop_runner: recording}))

      assert_received {:offloaded, exec}

      # l'exec capture, lance, fait la VRAIE completion (CaptureCompleter -> {:hop,...} + {:ok,:captured}).
      assert {:ok, :captured} = exec.()
      assert_received {:hop, _hop, _opts}
    end
  end

  describe "maybe_complete/2 — filtres (skip)" do
    test "pipeline pod (pipeline_id present) -> skip, pas d'appel completer" do
      payload = stage_payload(%{"pipeline_id" => "pl-1", "stage" => "build"})
      assert {:skip, :pipeline_pod} = HopConsumer.maybe_complete(payload, state())
      refute_received {:hop, _, _}
    end

    test "pod sans projet (pas de base_sha) -> skip" do
      payload = stage_payload(%{"base_sha" => nil, "workspace" => nil})
      assert {:skip, :no_project} = HopConsumer.maybe_complete(payload, state())
      refute_received {:hop, _, _}
    end

    test "base_sha vide -> skip (pas de livrable git)" do
      payload = stage_payload(%{"base_sha" => ""})
      assert {:skip, :no_project} = HopConsumer.maybe_complete(payload, state())
    end

    test "ticket_id non parseable -> skip" do
      payload = stage_payload(%{"ticket_id" => "owner/repo#42"})

      assert {:skip, {:bad_ticket_id, "owner/repo#42"}} =
               HopConsumer.maybe_complete(payload, state())
    end
  end

  describe "A2.4 — chainage carte (pipeline+stage -> intent + pr_role)" do
    test "producteur stage milieu (build/engineer, gate pass) -> :advance vers qualifier" do
      payload = stage_payload(%{"pipeline" => "poc-cycle", "stage" => "build"})
      assert {:ok, :captured} = HopConsumer.maybe_complete(payload, state(%{loader: StubLoader}))

      assert_received {:hop, hop, _opts}
      assert hop.pr_role == :producer
      assert hop.intent == :advance
      # build -> spec (role qualifier)
      assert hop.next_assignee == "qualifier"
      assert hop.producer_branch == "lcars/issue-42-engineer"
    end

    test "juge dernier stage (review/reviewer) -> :promote terminal, branche du producteur" do
      payload =
        stage_payload(%{"role" => "reviewer", "pipeline" => "poc-cycle", "stage" => "review"})

      assert {:ok, :captured} =
               HopConsumer.maybe_complete(
                 payload,
                 state(%{loader: StubLoader, forge_client: StubForge})
               )

      assert_received {:hop, hop, _opts}
      assert hop.pr_role == :judge
      assert hop.intent == :promote
      assert hop.next_assignee == nil

      # le juge review la PR du producteur, résolue sans carte via la PR ouverte (head=producteur)
      assert hop.producer_branch == "lcars/issue-42-engineer"
      # un juge ne porte pas de deliverable_opts (il ne pousse pas)
      refute Map.has_key?(hop, :deliverable_opts)
    end

    test "carte introuvable -> {:error, {:carte_load, _}}, pas de hop" do
      payload = stage_payload(%{"pipeline" => "bad", "stage" => "build"})

      assert {:error, {:carte_load, _}} =
               HopConsumer.maybe_complete(payload, state(%{loader: StubLoader}))

      refute_received {:hop, _, _}
    end

    test "stage inconnu dans la carte -> {:error, {:carte_nav, :unknown_stage}}, pas de misroute" do
      payload = stage_payload(%{"pipeline" => "poc-cycle", "stage" => "ghost"})

      assert {:error, {:carte_nav, :unknown_stage}} =
               HopConsumer.maybe_complete(payload, state(%{loader: StubLoader}))

      refute_received {:hop, _, _}
    end

    test "sans contexte carte (A1 1-stage) -> terminal, pas d'appel loader" do
      # loader nil : si run_hop appelait le loader sans contexte carte, ca crasherait.
      payload = stage_payload()
      assert {:ok, :captured} = HopConsumer.maybe_complete(payload, state())
      assert_received {:hop, hop, _opts}
      assert hop.intent == :promote
      assert hop.next_assignee == nil
    end
  end

  describe "parse_issue_number/1" do
    test "issue-N -> {:ok, N}" do
      assert {:ok, 7} = HopConsumer.parse_issue_number("issue-7")
    end

    test "format legacy / inconnu -> :error" do
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

    test "F067 : start_link cable :hop_runner -> la completion passe par le runner (chemin init/prod)" do
      # RED-first : ce test passe par start_link -> init (le chemin PROD, que stage_children utilise),
      # PAS par un state construit en direct. Si init oublie de lire :hop_runner des opts, le runner
      # injecte est ignore -> la completion s'execute en sync (bloquante) -> {:offloaded_gs} n'arrive
      # JAMAIS -> ce test echoue. C'est le filet du critique F067-init.
      test_pid = self()

      recording = fn exec ->
        send(test_pid, {:offloaded_gs, exec})
        {:ok, :offloaded}
      end

      name = :"HC_runner_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        HopConsumer.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          remote: "origin",
          forge_opts: [base_url: "http://10.42.0.118"],
          role_emails: fn role -> ["#{role}@lcars.local"] end,
          hop_completer: CaptureCompleter,
          deliverable_mode_fun: dmode(),
          hop_runner: recording,
          subscribe: false
        )

      send(pid, %Fleet.Event{
        source: :spawner,
        type: :"pod.completed",
        timestamp: DateTime.utc_now(),
        pod_id: "pod-abc",
        payload: stage_payload()
      })

      # init a cable hop_runner -> la completion est routee vers le runner (msg au process test).
      assert_receive {:offloaded_gs, _exec}, 1_000
    end

    test "handle_info pod.completed -> delegue (via Event reel, subscribe: false)" do
      name = :"HC_live_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        HopConsumer.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          remote: "origin",
          hop_completer: CaptureCompleter,
          deliverable_mode_fun: dmode(),
          subscribe: false
        )

      # Le completer fait send(self()) DANS le GenServer -> on verifie juste que
      # l'event est route sans crash (le hop est unit-teste via maybe_complete).
      event = %Fleet.Event{
        source: :spawner,
        type: :"pod.completed",
        timestamp: DateTime.utc_now(),
        pod_id: "pod-abc",
        payload: stage_payload()
      }

      send(pid, event)
      assert Process.alive?(pid)
      # un event non-spawner est ignore sans crash
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
