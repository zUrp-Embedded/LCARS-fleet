defmodule Fleet.Pilot.HopConsumerTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.HopConsumer

  # Seam HopCompleter : capture le hop PR-natif recu + retourne un outcome fixe.
  defmodule CaptureCompleter do
    def complete_pr(hop, opts) do
      send(self(), {:hop, hop, opts})
      {:ok, :captured}
    end

    # BLOCKED_DEP : escalade producteur bloqué → await_arch (capturé pour assertion).
    def await_arch(hop, opts) do
      send(self(), {:await_arch, hop, opts})
      {:ok, :awaiting_arch}
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
    test "pod engineer porteur de projet (A1 single-brique) -> hop producteur, intent :review (②.1d)" do
      # ②.1d : sans carte, le producteur ne merge PLUS directement (:promote) — il ouvre la PR et
      # DEMANDE les juges (:review). Le merge est ensuite piloté par l'état-PR (dispatch_review).
      assert {:ok, :captured} = HopConsumer.maybe_complete(stage_payload(), state())

      assert_received {:hop, hop, opts}
      assert hop.repo == "lordzurp/lcars-test"
      assert hop.issue_number == 42
      assert hop.role == "engineer"
      assert hop.pr_role == :producer
      assert hop.intent == :review
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

    test "producteur : result.summary -> hop.eng_summary (voix de l'eng, info SORTANTE)" do
      payload =
        stage_payload(%{"result" => %{"ok" => true, "summary" => "j'ai fait X, choisi Y"}})

      assert {:ok, :captured} = HopConsumer.maybe_complete(payload, state())
      assert_received {:hop, hop, _}
      assert hop.eng_summary == "j'ai fait X, choisi Y"
    end

    test "producteur : summary non-string -> coercé safe_str (pas de crash singleton #8) ; absent -> aucune clé" do
      # map -> inspect (coercion défensive : un LLM peut rendre un objet)
      p = stage_payload(%{"result" => %{"summary" => %{"raw" => 1}}})
      assert {:ok, :captured} = HopConsumer.maybe_complete(p, state())
      assert_received {:hop, hop, _}
      assert hop.eng_summary =~ "raw"
      # sans summary -> pas de clé eng_summary (pas de voix vide)
      assert {:ok, :captured} = HopConsumer.maybe_complete(stage_payload(), state())
      assert_received {:hop, hop2, _}
      refute Map.has_key?(hop2, :eng_summary)
    end

    test "producteur BLOQUÉ (result.blocked) -> await_arch (motif=summary), PAS complete_pr (anti-wedge)" do
      payload =
        stage_payload(%{
          "result" => %{"blocked" => true, "summary" => "Manque la spec du protocole X"}
        })

      assert {:ok, :awaiting_arch} = HopConsumer.maybe_complete(payload, state())

      # escalade humaine, pas une publish vide (qui wedgerait :no_deliverable_commit)
      assert_received {:await_arch, hop, _opts}
      refute_received {:hop, _, _}
      assert hop.issue_number == 42
      assert hop.role == "engineer"
      assert hop.decision == :blocked_dep
      assert hop.comment_body =~ "BLOQUÉ"
      assert hop.comment_body =~ "Manque la spec du protocole X"
    end

    test "blocked seulement pour un PRODUCTEUR (un juge avec blocked passe par le chemin normal)" do
      # reviewer = juge (deliverable_mode payload) → blocked ignoré, chemin normal (hop capturé).
      payload =
        stage_payload(%{"role" => "reviewer", "result" => %{"blocked" => true}})

      assert {:ok, :captured} = HopConsumer.maybe_complete(payload, state())
      assert_received {:hop, _hop, _}
      refute_received {:await_arch, _, _}
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

    test "F-E8 : juge NO-CARTE à route héritée (rôle != rôle du stage) -> :reviewed, JAMAIS :promote" do
      # Bug live PoC-7 : le qualifier (juge no-carte dispatché sur la PR) HÉRITE la route de l'issue
      # (stage `build`, rôle engineer). Sans le garde `stage_role_matches?`, gate_decide(build) le voyait
      # en terminal NON-producteur -> :promote -> MERGE sur 1 juge (quorum court-circuité). Avec : rôle
      # `qualifier` != rôle du stage `build` -> résolution no-carte -> :reviewed (enregistre la review ;
      # le merge revient au quorum `dispatch_by_verdicts` qui attend TOUS les juges).
      payload =
        stage_payload(%{"role" => "qualifier", "pipeline" => "poc-cycle", "stage" => "build"})

      assert {:ok, :captured} =
               HopConsumer.maybe_complete(
                 payload,
                 state(%{loader: StubLoader, forge_client: StubForge})
               )

      assert_received {:hop, hop, _opts}
      assert hop.pr_role == :judge
      assert hop.intent == :reviewed
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

    test "sans contexte carte (A1 single-brique) -> producteur :review, pas d'appel loader (carte)" do
      # loader (carte) nil : si run_hop appelait le loader de carte sans contexte carte, ca crasherait.
      # Le no-carte appelle deliverable_mode_fun (dmode), pas le loader de carte.
      payload = stage_payload()
      assert {:ok, :captured} = HopConsumer.maybe_complete(payload, state())
      assert_received {:hop, hop, _opts}
      assert hop.intent == :review
      assert hop.next_assignee == nil
    end

    test "sans carte, un JUGE (role payload) -> :reviewed + review_event mappe du gate-decision (②.1d)" do
      # role "qualifier" => dmode = "payload" => juge. Le verdict du pod (gate-decision) est mappe en
      # event de review : continue->approve ; TOUT le reste->request_changes (fail-closed DÉCISIF :
      # un COMMENT non-décisif ferait boucler le juge, vérifié live #6).
      for {decision, event} <- [
            {"continue", :approve},
            {"abandon", :request_changes},
            {"halt_wait_input", :request_changes},
            {"garbage_unparseable", :request_changes}
          ] do
        payload = stage_payload(%{"role" => "qualifier", "result" => %{"decision" => decision}})

        # forge_client: StubForge → le juge resout la branche producteur via la PR ouverte (pas de HTTP).
        assert {:ok, :captured} =
                 HopConsumer.maybe_complete(payload, state(%{forge_client: StubForge}))

        assert_received {:hop, hop, _opts}
        assert hop.pr_role == :judge
        assert hop.intent == :reviewed
        assert hop.review_event == event
        assert hop.producer_branch == "lcars/issue-42-engineer"
        refute Map.has_key?(hop, :deliverable_opts)
      end
    end

    test "review-body robuste aux sorties LLM mal typées (régression live #8 : chain non-string crashait)" do
      # Un juge peut rendre reason/chain/details en objets/listes imbriqués. L'ancien `#{...}` crashait
      # le HopConsumer (SINGLETON) → fin-de-hop perdue → verrou jamais levé → pipe wedgé. `safe_str` doit
      # absorber sans crasher et produire un corps de review en string.
      payload =
        stage_payload(%{
          "role" => "qualifier",
          "result" => %{
            "decision" => "abandon",
            "reason" => %{"resume" => "objet, pas string"},
            "chain" => [%{"step" => "lecture"}, ["liste", "imbriquée"], 42],
            "details" => %{"critere" => %{"nested" => true}}
          }
        })

      assert {:ok, :captured} =
               HopConsumer.maybe_complete(payload, state(%{forge_client: StubForge}))

      assert_received {:hop, hop, _opts}
      assert hop.review_event == :request_changes
      assert is_binary(hop.review_body)
      assert hop.review_body =~ "CHANGEMENTS DEMANDÉS"
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

  describe "F-037 — repo + remote per-hop (dérivés de l'event)" do
    test "payload porteur de repo → hop.repo + deliverable.remote viennent de l'EVENT, pas de la config" do
      # MULTI-PROJET : le singleton HopConsumer traite N projets. Le repo (forge API) et le remote (push)
      # de CE hop viennent du `pod.completed` (Spawner les embarque), PAS du fallback de config.
      payload =
        stage_payload(%{
          "repository" => %{"full_name" => "alice/proj-a"},
          "remote" => "http://forge/alice/proj-a.git"
        })

      # state de config délibérément DIFFÉRENT (repo "lordzurp/lcars-test", remote "origin") → si le hop
      # lisait la config au lieu de l'event, l'assertion casserait.
      assert {:ok, :captured} = HopConsumer.maybe_complete(payload, state())

      assert_received {:hop, hop, _opts}
      assert hop.repo == "alice/proj-a"
      assert hop.deliverable_opts.remote == "http://forge/alice/proj-a.git"
      # la branche système reste dérivée de l'issue (repo-locale, non scopée)
      assert hop.producer_branch == "lcars/issue-42-engineer"
    end

    test "payload SANS repo → fallback config (single-repo legacy / test à payload nu)" do
      # Rétro-compat : un `pod.completed` qui ne porte pas son repo → le HopConsumer retombe sur son
      # repo/remote de config (le chemin de TOUS les tests pré-F-037).
      assert {:ok, :captured} = HopConsumer.maybe_complete(stage_payload(), state())
      assert_received {:hop, hop, _opts}
      assert hop.repo == "lordzurp/lcars-test"
      assert hop.deliverable_opts.remote == "origin"
    end
  end

  describe "GenServer lifecycle" do
    test "F-037 : init SANS :repo/:remote réussit (per-hop, plus de require au boot)" do
      # Les opts :repo/:remote ne sont plus obligatoires (le repo+remote viennent de l'event). Un boot
      # multi-projet (sans repo fixe) est légitime ; la garde fail-loud du rail vit côté application.ex.
      name = :"HC_norepo_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        HopConsumer.start_link(
          name: name,
          subscribe: false,
          gatekeeper_boot_fun: fn -> {:ok, :disabled} end
        )

      assert Process.alive?(pid)
      assert %HopConsumer{repo: nil, remote: nil} = :sys.get_state(pid)

      GenServer.stop(pid)
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

      send(
        pid,
        Fleet.Event.new(:spawner, :"pod.completed", pod_id: "pod-abc", payload: stage_payload())
      )

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
      event =
        Fleet.Event.new(:spawner, :"pod.completed", pod_id: "pod-abc", payload: stage_payload())

      send(pid, event)
      assert Process.alive?(pid)
      # un event non-spawner est ignore sans crash
      send(pid, Fleet.Event.new(:task_queue, :work_item_completed))

      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end
end
