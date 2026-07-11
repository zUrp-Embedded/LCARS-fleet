defmodule Fleet.Pilot.StepRunConsumerTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepRunConsumer

  # Seam StepRunCompleter : capture le step_run PR-natif recu + retourne un outcome fixe.
  defmodule CaptureCompleter do
    def complete_pr(step_run, opts) do
      send(self(), {:step_run, step_run, opts})
      {:ok, :captured}
    end

    # BLOCKED_DEP : escalade producteur bloqué → await_arch (capturé pour assertion).
    def await_arch(step_run, opts) do
      send(self(), {:await_arch, step_run, opts})
      {:ok, :awaiting_arch}
    end
  end

  # Seam Loader (A2.4) : workflow_map engineer-first lineaire (Corr.3) ; "bad" raise (introuvable).
  #   build(engineer, producteur) -> spec(qualifier, juge) -> review(reviewer, juge terminal)
  defmodule StubLoader do
    def load!("poc-cycle") do
      %{
        "name" => "poc-cycle",
        "steps" => %{
          "build" => %{"role" => "engineer", "needs" => []},
          "spec" => %{"role" => "qualifier", "needs" => ["build"]},
          "review" => %{"role" => "reviewer", "needs" => ["spec"]}
        }
      }
    end

    # Map producteur-TERMINALE (façon brief-gate) : le dernier step est un producteur (build/engineer) ;
    # il n'y a PAS de step `review`/`merged` (ceux-ci sont des stages lifecycle PR posés POST-map).
    def load!("gate-terminal") do
      %{
        "name" => "gate-terminal",
        "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }
    end

    def load!(_), do: raise("workflow_map introuvable")
  end

  # Seam ForgeClient (②.1c) : le juge résout la branche producteur via la PR ouverte de l'issue
  # (sans workflow_map). Stub = une PR ouverte pour l'issue 42, head = la branche du producteur.
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
      %StepRunConsumer{
        repo: "lordzurp/lcars-test",
        remote: "origin",
        forge_opts: [base_url: "http://10.42.0.118"],
        role_emails: fn role -> ["#{role}@lcars.local"] end,
        step_run_completer: CaptureCompleter,
        deliverable_mode_fun: dmode()
      },
      extra
    )
  end

  defp step_payload(extra \\ %{}) do
    Map.merge(
      %{
        "pod_id" => "pod-abc",
        "issue_id" => "issue-42",
        "result" => %{"ok" => true},
        "workspace" => "/pods/pod-abc/workspace",
        "base_sha" => "cafe1234",
        "role" => "engineer"
      },
      extra
    )
  end

  describe "maybe_complete/2 — traduction event -> step_run PR-natif" do
    test "pod engineer porteur de projet (A1 single-brique) -> step_run producteur, intent :review (②.1d)" do
      # ②.1d : sans workflow_map, le producteur ne merge PLUS directement (:promote) — il ouvre la PR et
      # DEMANDE les juges (:review). Le merge est ensuite piloté par l'état-PR (dispatch_review).
      assert {:ok, :captured} = StepRunConsumer.maybe_complete(step_payload(), state())

      assert_received {:step_run, step_run, opts}
      assert step_run.repo == "lordzurp/lcars-test"
      assert step_run.issue_number == 42
      assert step_run.role == "engineer"
      assert step_run.pr_role == :producer
      assert step_run.intent == :review
      assert step_run.next_assignee == nil
      assert step_run.producer_branch == "lcars/issue-42-engineer"
      assert step_run.base_branch == "main"

      d = step_run.deliverable_opts
      assert d.mode == :git_native
      assert d.workspace == "/pods/pod-abc/workspace"
      assert d.base_sha == "cafe1234"
      assert d.allowed_emails == ["engineer@lcars.local"]
      assert d.remote == "origin"
      assert d.target_branch == "lcars/issue-42-engineer"
      assert d.push? == true

      assert opts[:forge_opts] == [base_url: "http://10.42.0.118"]
    end

    test "producteur : result.summary -> step_run.eng_summary (voix de l'eng, info SORTANTE)" do
      payload =
        step_payload(%{"result" => %{"ok" => true, "summary" => "j'ai fait X, choisi Y"}})

      assert {:ok, :captured} = StepRunConsumer.maybe_complete(payload, state())
      assert_received {:step_run, step_run, _}
      assert step_run.eng_summary == "j'ai fait X, choisi Y"
    end

    test "producteur : summary non-string -> coercé safe_str (pas de crash singleton #8) ; absent -> aucune clé" do
      # map -> inspect (coercion défensive : un LLM peut rendre un objet)
      p = step_payload(%{"result" => %{"summary" => %{"raw" => 1}}})
      assert {:ok, :captured} = StepRunConsumer.maybe_complete(p, state())
      assert_received {:step_run, step_run, _}
      assert step_run.eng_summary =~ "raw"
      # sans summary -> pas de clé eng_summary (pas de voix vide)
      assert {:ok, :captured} = StepRunConsumer.maybe_complete(step_payload(), state())
      assert_received {:step_run, hop2, _}
      refute Map.has_key?(hop2, :eng_summary)
    end

    test "producteur BLOQUÉ (result.blocked) -> await_arch (motif=summary), PAS complete_pr (anti-wedge)" do
      payload =
        step_payload(%{
          "result" => %{"blocked" => true, "summary" => "Manque la spec du protocole X"}
        })

      assert {:ok, :awaiting_arch} = StepRunConsumer.maybe_complete(payload, state())

      # escalade humaine, pas une publish vide (qui wedgerait :no_deliverable_commit)
      assert_received {:await_arch, step_run, _opts}
      refute_received {:step_run, _, _}
      assert step_run.issue_number == 42
      assert step_run.role == "engineer"
      assert step_run.decision == :blocked_dep
      assert step_run.comment_body =~ "BLOQUÉ"
      assert step_run.comment_body =~ "Manque la spec du protocole X"
    end

    test "blocked seulement pour un PRODUCTEUR (un juge avec blocked passe par le chemin normal)" do
      # reviewer = juge (deliverable_mode payload) → blocked ignoré, chemin normal (step_run capturé).
      payload =
        step_payload(%{"role" => "reviewer", "result" => %{"blocked" => true}})

      assert {:ok, :captured} = StepRunConsumer.maybe_complete(payload, state())
      assert_received {:step_run, _step_run, _}
      refute_received {:await_arch, _, _}
    end
  end

  describe "F067 — offload de la completion (step_run_runner)" do
    test "step_run_runner async -> completion offloadee (le singleton ne bloque pas sur .complete_pr)" do
      test_pid = self()

      # Runner "recording" : capture l'exec sans le lancer (simule l'offload Task.Supervisor) ->
      # prouve que .complete_pr passe par le runner, pas en direct (bloquant) dans le GenServer.
      recording = fn exec ->
        send(test_pid, {:offloaded, exec})
        {:ok, :offloaded}
      end

      assert {:ok, :offloaded} =
               StepRunConsumer.maybe_complete(
                 step_payload(),
                 state(%{step_run_runner: recording})
               )

      assert_received {:offloaded, exec}

      # l'exec capture, lance, fait la VRAIE completion (CaptureCompleter -> {:step_run,...} + {:ok,:captured}).
      assert {:ok, :captured} = exec.()
      assert_received {:step_run, _step_run, _opts}
    end
  end

  describe "maybe_complete/2 — filtres (skip)" do
    test "pipeline pod (workflow_map_id present) -> skip, pas d'appel completer" do
      payload = step_payload(%{"workflow_map_id" => "pl-1", "step" => "build"})
      assert {:skip, :workflow_map_pod} = StepRunConsumer.maybe_complete(payload, state())
      refute_received {:step_run, _, _}
    end

    test "pod sans projet (pas de base_sha) -> skip" do
      payload = step_payload(%{"base_sha" => nil, "workspace" => nil})
      assert {:skip, :no_project} = StepRunConsumer.maybe_complete(payload, state())
      refute_received {:step_run, _, _}
    end

    test "base_sha vide -> skip (pas de livrable git)" do
      payload = step_payload(%{"base_sha" => ""})
      assert {:skip, :no_project} = StepRunConsumer.maybe_complete(payload, state())
    end

    test "issue_id non parseable -> skip" do
      payload = step_payload(%{"issue_id" => "owner/repo#42"})

      assert {:skip, {:bad_issue_id, "owner/repo#42"}} =
               StepRunConsumer.maybe_complete(payload, state())
    end
  end

  describe "A2.4 — chainage workflow_map (pipeline+step -> intent + pr_role)" do
    test "producteur step milieu (build/engineer, gate pass) -> :advance vers qualifier" do
      payload = step_payload(%{"workflow_map" => "poc-cycle", "step" => "build"})

      assert {:ok, :captured} =
               StepRunConsumer.maybe_complete(payload, state(%{loader: StubLoader}))

      assert_received {:step_run, step_run, _opts}
      assert step_run.pr_role == :producer
      assert step_run.intent == :advance
      # build -> spec (role qualifier)
      assert step_run.next_assignee == "qualifier"
      assert step_run.producer_branch == "lcars/issue-42-engineer"
    end

    test "juge dernier step (review/reviewer) -> :promote terminal, branche du producteur" do
      payload =
        step_payload(%{"role" => "reviewer", "workflow_map" => "poc-cycle", "step" => "review"})

      assert {:ok, :captured} =
               StepRunConsumer.maybe_complete(
                 payload,
                 state(%{loader: StubLoader, forge_client: StubForge})
               )

      assert_received {:step_run, step_run, _opts}
      assert step_run.pr_role == :judge
      assert step_run.intent == :promote
      assert step_run.next_assignee == nil

      # le juge review la PR du producteur, résolue sans workflow_map via la PR ouverte (head=producteur)
      assert step_run.producer_branch == "lcars/issue-42-engineer"
      # un juge ne porte pas de deliverable_opts (il ne pousse pas)
      refute Map.has_key?(step_run, :deliverable_opts)
    end

    test "F-E8 : juge NO-WORKFLOW_MAP à route héritée (rôle != rôle du step) -> :reviewed, JAMAIS :promote" do
      # Bug live PoC-7 : le qualifier (juge no-workflow_map dispatché sur la PR) HÉRITE la route de l'issue
      # (step `build`, rôle engineer). Sans le garde `step_role_matches?`, gate_decide(build) le voyait
      # en terminal NON-producteur -> :promote -> MERGE sur 1 juge (quorum court-circuité). Avec : rôle
      # `qualifier` != rôle du step `build` -> résolution no-workflow_map -> :reviewed (enregistre la review ;
      # le merge revient au quorum `dispatch_by_verdicts` qui attend TOUS les juges).
      payload =
        step_payload(%{"role" => "qualifier", "workflow_map" => "poc-cycle", "step" => "build"})

      assert {:ok, :captured} =
               StepRunConsumer.maybe_complete(
                 payload,
                 state(%{loader: StubLoader, forge_client: StubForge})
               )

      assert_received {:step_run, step_run, _opts}
      assert step_run.pr_role == :judge
      assert step_run.intent == :reviewed
    end

    test "stage LIFECYCLE (review) hérité sur une map producteur-terminale -> :reviewed, PAS unknown_step" do
      # Régression WS2 : `stage/review` est posé POST-map (open_deliverable_pr) ; get_route rend alors
      # step=`review`, qui N'EST PAS un step de la map producteur-terminale `gate-terminal`. Sans le garde
      # `lifecycle_stage?`, resolve_next tombait en `next_step(map, "review")` -> {:workflow_map_nav,
      # :unknown_step} (le juge PR bouclait, re-spawn à l'infini, jamais de merge). Un stage lifecycle absent
      # de la map -> résolution no-workflow_map -> :reviewed (le merge revient au quorum dispatch_review).
      payload =
        step_payload(%{
          "role" => "qualifier",
          "workflow_map" => "gate-terminal",
          "step" => "review"
        })

      assert {:ok, :captured} =
               StepRunConsumer.maybe_complete(
                 payload,
                 state(%{loader: StubLoader, forge_client: StubForge})
               )

      assert_received {:step_run, step_run, _opts}
      assert step_run.pr_role == :judge
      assert step_run.intent == :reviewed
    end

    test "workflow_map introuvable -> {:error, {:workflow_map_load_failed, ..}}, pas de step_run" do
      payload = step_payload(%{"workflow_map" => "bad", "step" => "build"})

      assert {:error, {:workflow_map_load_failed, _, _}} =
               StepRunConsumer.maybe_complete(payload, state(%{loader: StubLoader}))

      refute_received {:step_run, _, _}
    end

    test "step inconnu dans la workflow_map -> {:error, {:workflow_map_nav, :unknown_step}}, pas de misroute" do
      payload = step_payload(%{"workflow_map" => "poc-cycle", "step" => "ghost"})

      assert {:error, {:workflow_map_nav, :unknown_step}} =
               StepRunConsumer.maybe_complete(payload, state(%{loader: StubLoader}))

      refute_received {:step_run, _, _}
    end

    test "sans contexte workflow_map (A1 single-brique) -> producteur :review, pas d'appel loader (workflow_map)" do
      # loader (workflow_map) nil : si run_step_run appelait le loader de workflow_map sans contexte workflow_map, ca crasherait.
      # Le no-workflow_map appelle deliverable_mode_fun (dmode), pas le loader de workflow_map.
      payload = step_payload()
      assert {:ok, :captured} = StepRunConsumer.maybe_complete(payload, state())
      assert_received {:step_run, step_run, _opts}
      assert step_run.intent == :review
      assert step_run.next_assignee == nil
    end

    test "sans workflow_map, un JUGE (role payload) -> :reviewed + review_event mappe du gate-decision (②.1d)" do
      # role "qualifier" => dmode = "payload" => juge. Le verdict du pod (gate-decision) est mappe en
      # event de review : continue->approve ; TOUT le reste->request_changes (fail-closed DÉCISIF :
      # un COMMENT non-décisif ferait boucler le juge, vérifié live #6).
      for {decision, event} <- [
            {"continue", :approve},
            {"abandon", :request_changes},
            {"halt_wait_input", :request_changes},
            {"garbage_unparseable", :request_changes}
          ] do
        # `reason` présent (F-C161 : requis) → seule la DÉCISION distingue les cas ; `garbage_unparseable`
        # reste halt_invalid via l'enum, pas via le motif.
        payload =
          step_payload(%{
            "role" => "qualifier",
            "result" => %{"decision" => decision, "reason" => "motif"}
          })

        # forge_client: StubForge → le juge resout la branche producteur via la PR ouverte (pas de HTTP).
        assert {:ok, :captured} =
                 StepRunConsumer.maybe_complete(payload, state(%{forge_client: StubForge}))

        assert_received {:step_run, step_run, _opts}
        assert step_run.pr_role == :judge
        assert step_run.intent == :reviewed
        assert step_run.review_event == event
        assert step_run.producer_branch == "lcars/issue-42-engineer"
        refute Map.has_key?(step_run, :deliverable_opts)
      end
    end

    test "review-body robuste aux sorties LLM mal typées (régression live #8 : chain non-string crashait)" do
      # Un juge peut rendre reason/chain/details en objets/listes imbriqués. L'ancien `#{...}` crashait
      # le StepRunConsumer (SINGLETON) → fin-de-step-run perdue → verrou jamais levé → pipe wedgé. `safe_str` doit
      # absorber sans crasher et produire un corps de review en string.
      payload =
        step_payload(%{
          "role" => "qualifier",
          "result" => %{
            "decision" => "abandon",
            "reason" => %{"resume" => "objet, pas string"},
            "chain" => [%{"step" => "lecture"}, ["liste", "imbriquée"], 42],
            "details" => %{"critere" => %{"nested" => true}}
          }
        })

      assert {:ok, :captured} =
               StepRunConsumer.maybe_complete(payload, state(%{forge_client: StubForge}))

      assert_received {:step_run, step_run, _opts}
      assert step_run.review_event == :request_changes
      assert is_binary(step_run.review_body)
      assert step_run.review_body =~ "CHANGEMENTS DEMANDÉS"
    end
  end

  describe "parse_issue_number/1" do
    test "issue-N -> {:ok, N}" do
      assert {:ok, 7} = StepRunConsumer.parse_issue_number("issue-7")
    end

    test "format legacy / inconnu -> :error" do
      assert :error = StepRunConsumer.parse_issue_number("owner/repo#7")
      assert :error = StepRunConsumer.parse_issue_number("issue-7x")
      assert :error = StepRunConsumer.parse_issue_number("issue-")
    end
  end

  describe "F-037 — repo + remote per-step-run (dérivés de l'event)" do
    test "payload porteur de repo → step_run.repo + deliverable.remote viennent de l'EVENT, pas de la config" do
      # MULTI-PROJET : le singleton StepRunConsumer traite N projets. Le repo (forge API) et le remote (push)
      # de CE step_run viennent du `pod.completed` (Spawner les embarque), PAS du fallback de config.
      payload =
        step_payload(%{
          "repository" => %{"full_name" => "alice/proj-a"},
          "remote" => "http://forge/alice/proj-a.git"
        })

      # state de config délibérément DIFFÉRENT (repo "lordzurp/lcars-test", remote "origin") → si le step_run
      # lisait la config au lieu de l'event, l'assertion casserait.
      assert {:ok, :captured} = StepRunConsumer.maybe_complete(payload, state())

      assert_received {:step_run, step_run, _opts}
      assert step_run.repo == "alice/proj-a"
      assert step_run.deliverable_opts.remote == "http://forge/alice/proj-a.git"
      # la branche système reste dérivée de l'issue (repo-locale, non scopée)
      assert step_run.producer_branch == "lcars/issue-42-engineer"
    end

    test "payload SANS repo → fallback config (single-repo legacy / test à payload nu)" do
      # Rétro-compat : un `pod.completed` qui ne porte pas son repo → le StepRunConsumer retombe sur son
      # repo/remote de config (le chemin de TOUS les tests pré-F-037).
      assert {:ok, :captured} = StepRunConsumer.maybe_complete(step_payload(), state())
      assert_received {:step_run, step_run, _opts}
      assert step_run.repo == "lordzurp/lcars-test"
      assert step_run.deliverable_opts.remote == "origin"
    end
  end

  describe "GenServer lifecycle" do
    test "F-037 : init SANS :repo/:remote réussit (per-step-run, plus de require au boot)" do
      # Les opts :repo/:remote ne sont plus obligatoires (le repo+remote viennent de l'event). Un boot
      # multi-projet (sans repo fixe) est légitime ; la garde fail-loud du rail vit côté application.ex.
      name = :"HC_norepo_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        StepRunConsumer.start_link(
          name: name,
          subscribe: false,
          gatekeeper_boot_fun: fn -> {:ok, :disabled} end
        )

      assert Process.alive?(pid)
      assert %StepRunConsumer{repo: nil, remote: nil} = :sys.get_state(pid)

      GenServer.stop(pid)
    end

    test "F067 : start_link cable :step_run_runner -> la completion passe par le runner (chemin init/prod)" do
      # RED-first : ce test passe par start_link -> init (le chemin PROD, que step_children utilise),
      # PAS par un state construit en direct. Si init oublie de lire :step_run_runner des opts, le runner
      # injecte est ignore -> la completion s'execute en sync (bloquante) -> {:offloaded_gs} n'arrive
      # JAMAIS -> ce test echoue. C'est le filet du critique F067-init.
      test_pid = self()

      recording = fn exec ->
        send(test_pid, {:offloaded_gs, exec})
        {:ok, :offloaded}
      end

      name = :"HC_runner_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        StepRunConsumer.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          remote: "origin",
          forge_opts: [base_url: "http://10.42.0.118"],
          role_emails: fn role -> ["#{role}@lcars.local"] end,
          step_run_completer: CaptureCompleter,
          deliverable_mode_fun: dmode(),
          step_run_runner: recording,
          subscribe: false
        )

      send(
        pid,
        Fleet.Event.new(:spawner, :"pod.completed", pod_id: "pod-abc", payload: step_payload())
      )

      # init a cable step_run_runner -> la completion est routee vers le runner (msg au process test).
      assert_receive {:offloaded_gs, _exec}, 1_000
    end

    test "handle_info pod.completed -> delegue (via Event reel, subscribe: false)" do
      name = :"HC_live_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        StepRunConsumer.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          remote: "origin",
          step_run_completer: CaptureCompleter,
          deliverable_mode_fun: dmode(),
          subscribe: false
        )

      # Le completer fait send(self()) DANS le GenServer -> on verifie juste que
      # l'event est route sans crash (le step_run est unit-teste via maybe_complete).
      event =
        Fleet.Event.new(:spawner, :"pod.completed", pod_id: "pod-abc", payload: step_payload())

      send(pid, event)
      assert Process.alive?(pid)
      # un event non-spawner est ignore sans crash
      send(pid, Fleet.Event.new(:task_queue, :"work_item.completed"))

      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end
end
