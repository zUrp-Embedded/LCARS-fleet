defmodule Fleet.Pilot.PollerTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Poller

  # Rail legacy (poll_once/4 → Routing → Dispatcher → Executor RAM) RETIRÉ (②.3 / BL-050). Ses tests
  # (`describe "poll_once/4"`, stubs `StubForge`/`StubInvoker`) sont partis avec. Seul le mode step
  # subsiste ci-dessous (+ le lifecycle GenServer, partagé).

  # G6 : workflow_map_loader qui RAISE (map retirée/renommée du catalogue) → load_workflow_map_or_nil rescue.
  defmodule RaisingWorkflowMapLoader do
    def load!(name), do: raise("workflow_map #{name} introuvable (retirée du catalogue)")
  end

  describe "G6 — workflow_map illisible → escalade (repo plus bloqué en silence)" do
    test "load workflow_map RAISE pendant classify → incident_fun appelé (bail tenu MAIS visible)" do
      parent = self()

      # Issue #42 routée AU-DELÀ du 1er step ("deploy") → classify_issue charge la workflow_map "ghostmap"
      # → le loader RAISE (map retirée du catalogue). `start_entry_poller` = harnais prouvé (découverte +
      # admission repo OK) ; on injecte le loader-qui-raise + un incident_fun stub.
      {name, pid} =
        start_entry_poller(
          {:ok,
           [
             %{
               "number" => 42,
               "body" => "x",
               "labels" => [],
               "assignees" => [%{"login" => "lordzurp"}]
             }
           ]},
          %{42 => {"ghostmap", "deploy"}},
          workflow_map_loader: RaisingWorkflowMapLoader,
          incident_fun: fn op, subject, reason, _opts ->
            send(parent, {:incident, op, subject, reason}) && :recorded
          end
        )

      Poller.force_poll(name)

      # AVANT : la map absente → issue ENGAGÉE (bail tenu) → repo bloqué POUR TOUJOURS, aucun signal.
      # MAINTENANT : l'échec de load ESCALADE (IncidentRegistry dédup → note puis issue sysadmin).
      assert_received {:incident, "workflow_map_load", "ghostmap",
                       {:workflow_map_load_failed, _msg}}

      GenServer.stop(pid)
    end
  end

  describe "G4 — awaits_rekick?/2 (throttle du re-kick arch)" do
    test "au moins 1 issue attend ET tick multiple du throttle → re-kick" do
      assert Poller.awaits_rekick?(1, 0)
      assert Poller.awaits_rekick?(3, 10)
      assert Poller.awaits_rekick?(1, 20)
    end

    test "aucune issue n'attend → JAMAIS de re-kick (même sur un tick multiple)" do
      refute Poller.awaits_rekick?(0, 0)
      refute Poller.awaits_rekick?(0, 10)
    end

    test "issue attend MAIS tick non-multiple → pas de re-kick (dépense bornée, pas 30s)" do
      refute Poller.awaits_rekick?(1, 1)
      refute Poller.awaits_rekick?(2, 9)
      refute Poller.awaits_rekick?(1, 15)
    end
  end

  describe "GenServer init / lifecycle" do
    test "F-037 : init SANS :repo réussit (découverte par topic, plus de repo fixe requis)" do
      # Le poller ne scanne plus un repo hard-codé — il DÉCOUVRE ses projets par topic. `:repo` n'est
      # donc plus requis ; le scoping `my_human` l'est (via :human ici, sinon `Human.current!()`).
      name = :"P_no_repo_#{System.unique_integer([:positive])}"

      {:ok, pid} = Poller.start_link(name: name, human: "lordzurp", start_tick?: false)

      assert Process.alive?(pid)
      assert %{poll_count: 0, error_count: 0, err_streak: 0} = Poller.stats(name)

      GenServer.stop(pid)
    end

    test "start réussit avec start_tick?: false (pas de tick planifié)" do
      name = :"P_lifecycle_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "fleet/lcars",
          start_tick?: false
        )

      assert Process.alive?(pid)
      assert %{poll_count: 0, error_count: 0, err_streak: 0, last_error: nil} = Poller.stats(name)

      GenServer.stop(pid)
    end
  end

  # ============================================================
  # Mode STEP — assignee-driven (DN forge-state-machine)
  # ============================================================

  # Forge stub pour le mode step : list (filtre déjà appliqué côté API
  # réelle, ici on renvoie tel quel) + les write-ops touchées par
  # StepDispatcher.dispatch_issue (add_label / post_comment).
  defmodule StepStubForge do
    # WS3 — le poller DÉCOUVRE ses repos par appartenance-org (`list_org_repos`) AVANT de scanner. Défaut =
    # LE repo de test (single-repo : 1 repo découvert → 1 `step_do_poll`). `_test_repos` pour le multi-repo,
    # `_test_discover` pour simuler une découverte en erreur (forge down → backoff). Plus de sceau/admission :
    # l'appartenance-org EST l'admission (tout repo rendu ici est scanné).
    def list_org_repos(_org, opts) do
      Keyword.get(
        opts,
        :_test_discover,
        {:ok, Keyword.get(opts, :_test_repos, ["lordzurp/lcars-test"])}
      )
    end

    # #5.2 D1 — le scoping multi-user est FORGE-SIDE : le poller passe `assigned_by=<my_human>`. Le stub
    # CAPTURE ce scoping (→ `:_test_pid`) pour le vérifier, puis renvoie `:_test_issues` tel quel.
    def list_open_issues(_repo, opts) do
      send(
        Keyword.get(opts, :_test_pid, self()),
        {:scoped, :issues, Keyword.get(opts, :assigned_by)}
      )

      Keyword.fetch!(opts, :_test_issues)
    end

    # Corr.3 4-C : le mode step liste AUSSI les PR (chemin juge), scopées pareil (assigned_by). Default {:ok, []}.
    def list_open_pulls(_repo, opts) do
      send(
        Keyword.get(opts, :_test_pid, self()),
        {:scoped, :pulls, Keyword.get(opts, :assigned_by)}
      )

      Keyword.get(opts, :_test_pulls, {:ok, []})
    end

    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}

    # #8 : la route vit dans le route-comment (state-machine). Stub configurable par `_test_routes`
    # (map n → {workflow_map, step}). Défaut :none (issue non routé → A1 producteur).
    def get_route(_repo, n, opts) do
      case Map.get(Keyword.get(opts, :_test_routes, %{}), n) do
        {workflow_map, step} -> {:ok, {workflow_map, step}}
        _ -> :none
      end
    end

    def get_predecessor_result(_repo, _n, _opts), do: :none
    # Fix famine-d'info : build_judge_brief lit le critère (body de l'issue) via get_issue.
    def get_issue(_repo, n, _opts), do: {:ok, %{"number" => n, "body" => "critère stub ##{n}"}}

    # ②.1d : par defaut aucun verdict de juge (les tests poller ne couvrent pas merge/rework) → tout
    # juge demandé est « pending » → dispatché.
    def pr_review_verdicts(_repo, _index, _opts), do: {:ok, %{}}

    # F-E8 : état de jury combiné — aucun verdict + jury vide (les tests poller ne couvrent pas merge) →
    # `requested` = `requested_reviewers` du PR → tout juge demandé reste pending → dispatché.
    def pr_review_state(_repo, _index, _opts), do: {:ok, %{verdicts: %{}, reviewers: []}}
    # Adoption : pose des juges sur une PR orpheline (humaine/fork, ou agent ayant perdu ses reviewers).
    def request_review(_repo, index, reviewers, _opts),
      do: send(self(), {:requested_review, index, reviewers}) && :ok

    # MA-06 : compteur forge-natif des rounds de rework (les tests poller ne couvrent pas le rework borné).
    def count_change_request_rounds(_repo, _index, _opts), do: {:ok, 0}
    def post_route(_repo, _n, p, s, _opts), do: send(self(), {:route, p, s}) && {:ok, :posted}
    def set_assignee(_repo, _n, login, _opts), do: send(self(), {:assignee, login}) && {:ok, :set}

    # Réconciliation (B) : la réclamation tourne DANS le GenServer Poller → on route le signal vers
    # le pid de test (`:_test_pid` des forge_opts), pas vers `self()` (la mailbox du Poller).
    def remove_label(_repo, n, label, opts) do
      send(Keyword.get(opts, :_test_pid, self()), {:remove_label, n, label})
      {:ok, :removed}
    end
  end

  defmodule StepStubLoader do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"slot_scope" => "project"},
           spec: %{}
         }}

    # Corr.3 : juge de PR (qualifier/reviewer) -> brief_kind: judge (brief GateBrief desamorce).
    def load(role) when role in ["qualifier", "reviewer"],
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => role, "slot_scope" => "instance"},
           spec: %{"brief_kind" => "judge"}
         }}

    def load(_), do: {:error, :not_found}
  end

  # Loader de WORKFLOW_MAP (load!/1) — distinct du loader CapProfile ci-dessus (load/1).
  defmodule StepStubWorkflowMapLoader do
    # 1-step (producteur engineer) : un issue routé ici (step=build=1er) est EN FILE (pas démarré).
    def load!("qa-build") do
      %{"name" => "qa-build", "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}}
    end

    # 2-step : routé au 2e step (deploy ≠ 1er) = pipeline AVANCÉ (entre deux step_runs) = ENGAGÉ.
    def load!("qa-2") do
      %{
        "name" => "qa-2",
        "steps" => %{
          "build" => %{"role" => "engineer", "needs" => []},
          "deploy" => %{"role" => "engineer", "needs" => ["build"]}
        }
      }
    end
  end

  defmodule StepStubSpawner do
    def spawn_pod(_profile, issue_id, opts) do
      send(self(), {:spawned, issue_id, opts})
      {:ok, "pod-#{issue_id}"}
    end

    # Réconciliation (B) : aucun pod vivant par défaut → tout verrou `lcars-in-flight` est candidat
    # orphelin (réclamé après la grace 2-tick). Un stub avec list_pods absent ferait fail-safe (skip).
    def list_pods, do: []

    # G4 : le re-kick awaits-arch appelle wake_pod (best-effort) — stub no-op (le tick ne doit pas crasher
    # quand une issue awaits-arch est présente). La DÉCISION de re-kicker est testée via awaits_rekick?/2.
    def wake_pod(_pod_id), do: :ok
  end

  # F-037 / #25 : un pod VIVANT à pod_id REPO-SCOPÉ (`<repo-slug>-issue-<n>-<role>`, format PodId réel).
  defmodule LivePodSpawner do
    def spawn_pod(_profile, issue_id, _opts), do: {:ok, "pod-#{issue_id}"}
    def list_pods, do: [%{pod_id: "lordzurp-lcars-test-issue-8-engineer"}]
  end

  # TaskQueue stub : le pod a une tâche ACTIVE → il POSSÈDE légitimement son verrou.
  defmodule ActiveTaskQueue do
    def pod_status(_pod_id), do: {:ok, :running}
  end

  # SLOT-FREEZE : un eng PIPE project-scoped (pod_id `<repo>-engineer`, SANS `-issue-N-` — l'eng resident
  # qui traite N issues sequentiellement, 1 process = 1 slot Desktop).
  defmodule ProjectPipeSpawner do
    def spawn_pod(_profile, issue_id, _opts), do: {:ok, "pod-#{issue_id}"}
    def list_pods, do: [%{pod_id: "lordzurp-lcars-test-engineer"}]
  end

  # TaskQueue stub : l'eng project travaille la BRIQUE 8 (issue_id "issue-8") -> il possede #8.
  defmodule ProjectTaskQueueIssue8 do
    def pod_status(_pod_id), do: {:ok, :running}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-8"}
  end

  # TaskQueue stub : l'eng project travaille une AUTRE brique (9) -> il ne possede PAS #8.
  defmodule ProjectTaskQueueIssue9 do
    def pod_status(_pod_id), do: {:ok, :running}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-9"}
  end

  # G1 — TaskQueue stub : une ÉVAL GATEKEEPER ACTIVE porte la brique #8 de CE repo (metadata MA-03
  # auto-descriptif : gate_eval + resume_n + resume_payload.repository). Aucun pod vivant par ailleurs
  # (le producteur est fini) : c'est exactement la fenêtre d'éval.
  defmodule GateEvalTaskQueue do
    def pod_status(_pod_id), do: {:ok, nil}

    def list_active do
      [
        %{
          metadata: %{
            "gate_eval" => true,
            "resume_n" => 8,
            "resume_payload" => %{"repository" => %{"full_name" => "lordzurp/lcars-test"}}
          }
        }
      ]
    end
  end

  # G1 — TaskQueue stub : une éval active existe mais pour un AUTRE repo → elle ne possède PAS la
  # ref #8 de lordzurp/lcars-test (multi-projet : le repo de la ref vient du resume_payload).
  defmodule GateEvalOtherRepoTaskQueue do
    def pod_status(_pod_id), do: {:ok, nil}

    def list_active do
      [
        %{
          metadata: %{
            "gate_eval" => true,
            "resume_n" => 8,
            "resume_payload" => %{"repository" => %{"full_name" => "lordzurp/autre-projet"}}
          }
        }
      ]
    end
  end

  # Recovery de wake qui ÉCHOUE (pod injoignable, re-roll non réparé) → `StepDispatcher.dispatch_issue`
  # surface `{:error, {:wake_unreached, …}}` : le pipeline EST démarré (verrou + pod + brief posés en amont,
  # ordre canonique), seul le réveil tmux a raté. Sert à prouver le contrat « wake raté ⇒ bail PRIS ».
  defmodule FailingWakeRecovery do
    def wake(_pod_id, _respawn_fun, _opts), do: {:error, {:escalated, :not_found}}
  end

  # Loader de WORKFLOW_MAP qui RATE TRANSITOIREMENT sur `qa-2` (workflow_map → nil) mais charge `qa-build` normalement.
  # Simule un échec réseau/forge de chargement de workflow_map sur un pipeline routé-avancé : le bail ne doit PAS
  # se libérer pour autant (fail-closed). `load!/1` LÈVE pour `qa-2` → le poller (load_workflow_map_or_nil) ET le
  # StepDispatcher (load_workflow_map) le rescue-ent en nil/`{:error}`.
  defmodule NilWorkflowMapForQa2Loader do
    def load!("qa-2"), do: raise("workflow_map qa-2 indisponible (échec transitoire simulé)")

    def load!("qa-build"),
      do: %{
        "name" => "qa-build",
        "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }
  end

  defp start_step_poller(issues_response, pulls_response \\ {:ok, []}) do
    name = :"P_step_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Poller.start_link(
        name: name,
        repo: "lordzurp/lcars-test",
        human: "lordzurp",
        start_tick?: false,
        step_dispatch?: true,
        forge_client: StepStubForge,
        forge_opts: [
          _test_issues: issues_response,
          _test_pulls: pulls_response,
          _test_pid: self()
        ],
        loader: StepStubLoader,
        spawner: StepStubSpawner,
      )

    {name, pid}
  end

  describe "mode step — force_poll" do
    test "issue assignée ROUTELESS → onboardée sur la workflow_map par défaut (skip, pas de spawn)" do
      issues = [
        %{
          "number" => 7,
          "body" => "fais le hello",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      {name, pid} = start_step_poller({:ok, issues})

      # #5.2 D2 — route nil → le poller ONBOARDE (grave la workflow_map par défaut brief-gate via Loader) puis
      # DÉFÈRE → skip (le tick suivant la voit routée → dispatch). Le dispatch routé est testé dans le
      # describe « route gravée » + step_dispatcher_test. Au niveau Poller, le contrat = le tally.
      assert %{dispatched: 0, skipped: 1, errors: 0} = Poller.force_poll(name)
      refute_received {:spawned, _, _}

      GenServer.stop(pid)
    end

    test "verrou lcars-in-flight → skip, pas de spawn" do
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      {name, pid} = start_step_poller({:ok, issues})

      assert %{dispatched: 0, skipped: 1, errors: 0} = Poller.force_poll(name)
      refute_received {:spawned, _, _}

      GenServer.stop(pid)
    end

    test "réconciliation (B) : verrou orphelin réclamé au 2e tick (grace), pas au 1er" do
      # #8 verrouillé mais AUCUN pod vivant (StepStubSpawner.list_pods → []) = orphelin confirmé.
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      {name, pid} = start_step_poller({:ok, issues})

      # 1er tick : #8 devient SUSPECT (grace 2-tick) — PAS encore réclamé.
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      # 2e tick consécutif : orphelin CONFIRMÉ → verrou réclamé (le prochain tick re-dispatchera).
      Poller.force_poll(name)
      assert_received {:remove_label, 8, "lcars-in-flight"}

      GenServer.stop(pid)
    end

    test "F-037 : un pod VIVANT à pod_id REPO-SCOPÉ tient son verrou (PAS de mis-réclamation)" do
      # Régression du fix `parse_pod_ref` : pod_id = `<repo-slug>-issue-N-role` (repo-scopé, PodId/#25).
      # L'ancien parse ancré `^issue-` ne le reconnaissait PAS → `live_owned_refs` vide → le verrou d'un pod
      # VIVANT paraissait orphelin → mis-réclamé après la grace. Ici le pod (tâche active sur l'issue 8) est
      # reconnu propriétaire → son verrou n'est JAMAIS réclamé, même après 2 ticks.
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      name = :"P_live_lock_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          spawner: LivePodSpawner,
          task_queue: ActiveTaskQueue,
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "SLOT-FREEZE : un eng PIPE project-scoped tient le verrou de sa BRIQUE ACTIVE (pas de mis-reclamation -> pas de loop)" do
      # Regression du loop hello-avengers : le pod project `<repo>-engineer` (sans `-issue-N-`) n'etait
      # reconnu proprietaire d'AUCUN verrou (parse_pod_ref -> []) -> le poller reclamait le sien ->
      # re-dispatch en boucle. Ici l'eng (tache active sur #8 via son issue_id "issue-8") est reconnu
      # proprietaire -> #8 JAMAIS reclame, meme apres 2 ticks.
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      name = :"P_proj_lock_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          spawner: ProjectPipeSpawner,
          task_queue: ProjectTaskQueueIssue8,
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "SLOT-FREEZE : un eng PIPE project sur une AUTRE brique (9) ne masque PAS l'orphelin #8 (scope precis)" do
      # L'eng possede SEULEMENT sa brique active (9), pas tout le repo -> un verrou #8 sans pod actif dessus
      # reste un VRAI orphelin -> reclame apres la grace 2-tick (sinon un orphelin legitime wedgerait).
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      name = :"P_proj_other_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          spawner: ProjectPipeSpawner,
          task_queue: ProjectTaskQueueIssue9,
        )

      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}
      Poller.force_poll(name)
      assert_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "G1 : verrou TENU pendant une éval gatekeeper ACTIVE (jamais réclamé, même après la grâce)" do
      # Fenêtre d'éval : le producteur de #8 est FINI (aucun pod vivant), le gatekeeper PERMANENT
      # porte la tâche d'éval (pod_id sans slug repo → invisible aux refs par pod_id). Sans le fix,
      # la ref paraissait orpheline → réclamée au 2e tick EN PLEINE ÉVAL → re-dispatch concurrent
      # (double workflow_run + verdict fantôme). Avec le fix : la ref est possédée par l'éval active
      # (gate_eval_owned_refs) → jamais réclamée, sur autant de ticks que dure l'éval.
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      name = :"P_g1_eval_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          spawner: StepStubSpawner,
          task_queue: GateEvalTaskQueue
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "G1 : une éval gatekeeper d'un AUTRE repo ne tient PAS le verrou (réclamé au 2e tick)" do
      # Multi-projet : la ref possédée vient du repo du resume_payload. Une éval en cours sur
      # lordzurp/autre-projet#8 ne masque pas l'orphelin lordzurp/lcars-test#8 — sinon toute éval
      # active gèlerait la réconciliation de TOUS les repos (wedge symétrique du fix). Couvre aussi
      # le cas « éval clobbée » (cleared) : une éval hors de list_active ne possède rien (même
      # chemin — la ref redevient orpheline → reclaim → re-dispatch → ré-escalade, self-heal).
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      name = :"P_g1_other_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          spawner: StepStubSpawner,
          task_queue: GateEvalOtherRepoTaskQueue
        )

      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}
      Poller.force_poll(name)
      assert_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "D1 — le poller SCOPE les listes par assigned_by=my_human (forge-side, issues ET PR)" do
      # Le scoping multi-user vit dans la LISTE (forge-side) : le poller passe SON humain aux DEUX endpoints
      # (/issues?type=issues ET ?type=pulls). decide/dispatch_review ne re-vérifient plus l'ownership.
      {name, pid} = start_step_poller({:ok, []}, {:ok, []})

      Poller.force_poll(name)

      assert_received {:scoped, :issues, "lordzurp"}
      assert_received {:scoped, :pulls, "lordzurp"}

      GenServer.stop(pid)
    end

    test "F-037 : erreur de LISTE per-repo → tally error MAIS pas de backoff (err_streak 0, forge up)" do
      # Un repo qui liste mal (500) ne backoff PAS toute la fleet : la DÉCOUVERTE a réussi (forge up), donc
      # err_streak/error_count restent à 0 (réservés à l'échec de découverte). L'erreur per-item vit dans la
      # TALLY (errors:1) + `last_tally_errors`.
      {name, pid} = start_step_poller({:error, {:http, 500, "boom"}})

      assert %{dispatched: 0, skipped: 0, errors: 1} = Poller.force_poll(name)
      assert %{err_streak: 0, error_count: 0, last_tally_errors: 1} = Poller.stats(name)

      GenServer.stop(pid)
    end

    test "F-037 : échec de DÉCOUVERTE (search_repos_by_topic) → backoff (err_streak + error_count +1)" do
      # La forge est DOWN — la découverte elle-même échoue. C'est le SEUL cas qui backoff (handle_poll_error).
      name = :"P_discover_err_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          human: "lordzurp",
          start_tick?: false,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_discover: {:error, {:http, 503, "down"}}],
          spawner: StepStubSpawner,
        )

      assert %{dispatched: 0, skipped: 0, errors: 1} = Poller.force_poll(name)
      assert %{err_streak: 1, error_count: 1} = Poller.stats(name)

      GenServer.stop(pid)
    end

    test "F-037 : découverte multi-repo → scan de CHAQUE repo, tally agrégée sur tous" do
      # Cœur du chantier : 2 repos découverts → le poller scanne les DEUX, tally additionnée. Issue assignée
      # routeless dans chaque repo → onboardée puis déférée (skip) ⇒ skipped:2 (1 par repo).
      issue = %{
        "number" => 1,
        "body" => "x",
        "labels" => [],
        "assignees" => [%{"login" => "lordzurp"}]
      }

      name = :"P_multi_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          human: "lordzurp",
          start_tick?: false,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [
            _test_repos: ["lordzurp/proj-a", "lordzurp/proj-b"],
            _test_issues: {:ok, [issue]}
          ],
          loader: StepStubLoader,
          spawner: StepStubSpawner,
        )

      assert %{dispatched: 0, skipped: 2, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "issue ROUTÉ (route-comment) + assignee → démarre → dispatche le rôle du step (workflow_map_role)" do
      # #8 cohérence : le routing vient de la ROUTE-COMMENT (gravée par create_issue), plus du label.
      # #10 routé qa-build:build (1er step = en file), assigné humain, bail libre → DÉMARRE → le poller
      # dispatche le rôle du step courant (build → engineer via workflow_map_role).
      issues = [
        %{
          "number" => 10,
          "body" => "neuf",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      name = :"P_routed_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [
            _test_issues: {:ok, issues},
            _test_routes: %{10 => {"qa-build", "build"}}
          ],
          loader: StepStubLoader,
          workflow_map_loader: StepStubWorkflowMapLoader,
          spawner: StepStubSpawner,
        )

      # tally = le contrat au niveau Poller (le spawn part dans la mailbox du GenServer, pas du test ;
      # le rôle dispatché par workflow_map_role est unit-testé dans step_dispatcher_test).
      assert %{dispatched: 1, skipped: 0, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end
  end

  # ============================================================
  # (WS3) Frontière d'admission par SCEAU : RETIRÉE. L'admission = l'appartenance à l'org — `list_org_repos`
  # ne rend QUE des repos de l'org fleet, tous admis d'office. Les anciens tests « repo tagué-seul écarté /
  # repo scellé admis » exerçaient le filtre `admitted_repos` de `do_poll`, supprimé : il n'existe PLUS de
  # repo « découvrable-mais-non-admis » (l'org EST la frontière, gérée EN AMONT par l'admin humain — LCARS
  # n'est pas du multi-tenant adversarial). Le « tous les repos découverts sont scannés » est couvert par le
  # test multi-repo de la section découverte.
  # ============================================================

  # ============================================================
  # Bail repo-serialise (incrément 3) : au plus 1 pipeline actif par repo.
  # ============================================================
  describe "mode step — bail repo-serialise" do
    # `extra_opts` surcharge les opts (Keyword.merge en dernier) : injecte un seam (`wake_recovery`) ou
    # remplace un défaut (`workflow_map_loader`) sans dupliquer le harnais.
    defp start_entry_poller(issues_response, routes, extra_opts \\ []) do
      name = :"P_lease_#{System.unique_integer([:positive])}"

      base = [
        name: name,
        repo: "lordzurp/lcars-test",
        human: "lordzurp",
        start_tick?: false,
        step_dispatch?: true,
        forge_client: StepStubForge,
        forge_opts: [_test_issues: issues_response, _test_routes: routes],
        loader: StepStubLoader,
        workflow_map_loader: StepStubWorkflowMapLoader,
        spawner: StepStubSpawner,
      ]

      {:ok, pid} = Poller.start_link(Keyword.merge(base, extra_opts))

      {name, pid}
    end

    test "un pipeline ENGAGÉ (route avancée) tient le bail et bloque un issue EN FILE" do
      # #8 : le bail se lit sur la ROUTE (state-machine), PLUS sur state:*. #11 routé qa-2:deploy (2e
      # step ≠ 1er = pipeline AVANCÉ entre deux step_runs) → ENGAGÉ → tient le bail ET son step courant est
      # dispatché (continue le step_run). #12 routé qa-build:build (1er step = EN FILE) → bail tenu → attend.
      issues = [
        %{
          "number" => 11,
          "body" => "en cours",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        },
        %{
          "number" => 12,
          "body" => "en file",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      {name, pid} =
        start_entry_poller({:ok, issues}, %{11 => {"qa-2", "deploy"}, 12 => {"qa-build", "build"}})

      assert %{dispatched: 1, skipped: 1, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "deux issues EN FILE -> un seul démarre, l'autre attend (bail pris dans le tick)" do
      issues = [
        %{
          "number" => 13,
          "body" => "file1",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        },
        %{
          "number" => 14,
          "body" => "file2",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      {name, pid} =
        start_entry_poller({:ok, issues}, %{
          13 => {"qa-build", "build"},
          14 => {"qa-build", "build"}
        })

      assert %{dispatched: 1, skipped: 1, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "bail libre (aucun pipeline engagé) -> le issue EN FILE démarre" do
      issues = [
        %{
          "number" => 15,
          "body" => "file",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      {name, pid} = start_entry_poller({:ok, issues}, %{15 => {"qa-build", "build"}})

      assert %{dispatched: 1, skipped: 0, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "wake raté sur le 1er issue PREND le bail intra-tick → le 2e ne démarre PAS (un seul pipeline)" do
      # Régression : l'ordre canonique du spawn est verrou → pod → enqueue → WAKE (le wake EN DERNIER). Donc
      # `{:error, {:wake_unreached, …}}` = pipeline DÉMARRÉ (verrou + pod + brief posés), seul le réveil tmux
      # a raté. Le pipeline DOIT tenir le bail repo-sérialisé. Deux issues du MÊME repo EN FILE dans le même
      # tick ; le wake de la 1re échoue (FailingWakeRecovery). Le 1er pipeline est démarré → bail PRIS → le 2e
      # issue est SKIPPÉ (un seul pipeline démarre). Le wake raté n'est PAS avalé : il reste compté en `errors`
      # (et alimente err_streak/telemetry).
      #
      # Régression prouvée : reviens à l'ancien `step_do_dispatch` (wake_unreached → errors SANS prendre le
      # bail) + `start_pipeline` qui ne prend le bail que si `dispatched` augmente → le bail reste libre → le 2e
      # issue DÉMARRE un 2e pipeline → le tally devient `skipped:0, errors:2` (deux feature-branches
      # concurrentes), l'assert `skipped:1` échoue.
      issues = [
        %{
          "number" => 16,
          "body" => "file1",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        },
        %{
          "number" => 17,
          "body" => "file2",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      {name, pid} =
        start_entry_poller(
          {:ok, issues},
          %{16 => {"qa-build", "build"}, 17 => {"qa-build", "build"}},
          wake_recovery: &FailingWakeRecovery.wake/3
        )

      # 1er issue : pipeline démarré mais wake injoignable → errors:1, bail PRIS. 2e issue : bail tenu →
      # skipped:1. Un SEUL pipeline démarre. Le wake raté est SURFACÉ (errors), pas avalé.
      assert %{dispatched: 0, skipped: 1, errors: 1} = Poller.force_poll(name)

      # Le wake raté n'est PAS avalé : il remonte dans le signal d'anomalie per-item `last_tally_errors`
      # (le streak/backoff est réservé à l'échec de DÉCOUVERTE en archi multi-repo — la forge est up ici).
      assert %{last_tally_errors: 1} = Poller.stats(name)

      GenServer.stop(pid)
    end

    test "pipeline routé-avancé à workflow_map NIL tient le bail (échec transitoire de workflow_map ne libère pas le bail)" do
      # Régression : le bail se lit sur la ROUTE (append-only, robuste), JAMAIS sur le succès du chargement de
      # la workflow_map. #18 routé qa-2:deploy (2e step ≠ 1er = pipeline AVANCÉ = ENGAGÉ) mais sa workflow_map échoue à
      # charger TRANSITOIREMENT (NilWorkflowMapForQa2Loader lève sur qa-2). Le pipeline reste ENGAGÉ (fail-closed) →
      # tient le bail. #19 routé qa-build:build (1er step = EN FILE, workflow_map qa-build charge OK), même repo →
      # bail tenu → SKIPPÉ. Aucun 2e pipeline ne démarre malgré la workflow_map-nil.
      #
      # Régression prouvée : reviens à `engaged = not is_nil(workflow_map) and not first_step?(...)` → la
      # workflow_map-nil de #18 le classe `engaged=false` → il sort du lease set → #19 voit le bail LIBRE → DÉMARRE un
      # 2e pipeline → le tally devient `dispatched:1` (au lieu de `dispatched:0, skipped:1`), l'assert échoue.
      issues = [
        %{
          "number" => 18,
          "body" => "avance",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        },
        %{
          "number" => 19,
          "body" => "file",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      {name, pid} =
        start_entry_poller(
          {:ok, issues},
          %{18 => {"qa-2", "deploy"}, 19 => {"qa-build", "build"}},
          workflow_map_loader: NilWorkflowMapForQa2Loader
        )

      # #18 engagé (workflow_map-nil mais route avancée → fail-closed) tient le bail : son step est dispatché mais
      # fail-loud (workflow_map manquante côté StepDispatcher → errors:1), le bail reste TENU. #19 → bail tenu →
      # skipped:1. Aucun 2e pipeline démarré (dispatched:0).
      assert %{dispatched: 0, skipped: 1, errors: 1} = Poller.force_poll(name)

      GenServer.stop(pid)
    end
  end

  # ============================================================
  # Chemin PR-driven (Corr.3 4-C) : les juges sont dispatches via les requested_reviewers.
  # ============================================================
  describe "mode step — dispatch juge PR-driven" do
    test "PR avec review demandee -> juge dispatche (chemin pulls)" do
      pulls = [
        %{
          "number" => 6,
          "assignees" => [%{"login" => "lordzurp"}],
          "head" => %{"ref" => "lcars/issue-42-engineer"},
          "requested_reviewers" => [%{"login" => "Qualifier"}],
          "labels" => []
        }
      ]

      {name, pid} = start_step_poller({:ok, []}, {:ok, pulls})

      assert %{dispatched: 1, skipped: 0, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "issue avec PR fleet ouverte -> producteur SKIP cote issue (pas de re-spawn)" do
      # #99 assigne engineer MAIS sa PR est ouverte -> phase juge : le chemin issue SKIP (sinon
      # re-spawn du producteur deja fini) ; le juge est dispatche par le chemin pulls.
      issues = [
        %{
          "number" => 99,
          "body" => "x",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      pulls = [
        %{
          "number" => 7,
          "assignees" => [%{"login" => "lordzurp"}],
          "head" => %{"ref" => "lcars/issue-99-engineer"},
          "requested_reviewers" => [%{"login" => "Reviewer"}],
          "labels" => []
        }
      ]

      {name, pid} = start_step_poller({:ok, issues}, {:ok, pulls})

      # issue #99 skip (PR ouverte) + juge reviewer dispatche (pull) = {dispatched:1, skipped:1}
      assert %{dispatched: 1, skipped: 1, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "PR sans juge demandé -> ADOPTION (le système pose les juges → dispatched)" do
      # requested_reviewers vide = PR non mise en place par le pipeline (humaine/fork, ou agent ayant
      # perdu ses reviewers). Gate agent-agnostique → adoption : on POSE les juges au lieu de skip. Compté
      # `dispatched` (retour `{:ok, {:adopted, ...}}`) ; les juges spawnent au tick suivant.
      pulls = [
        %{
          "number" => 8,
          "head" => %{"ref" => "lcars/issue-42-engineer"},
          "requested_reviewers" => [],
          "labels" => []
        }
      ]

      {name, pid} = start_step_poller({:ok, []}, {:ok, pulls})

      # dispatched: 1 = la PR a été adoptée (`{:ok, {:adopted, ...}}`). Le CALL request_review lui-même est
      # prouvé au niveau unit (StepDispatcherTest) ; ici on vérifie le tally poller (l'adoption = un dispatch).
      assert %{dispatched: 1, skipped: 0, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end
  end

  # ============================================================
  # MA-02 — refs de verrou REPO-QUALIFIÉES (collision cross-repo)
  # ============================================================

  describe "MA-02 — réconciliation multi-repo (clé de verrou repo-qualifiée)" do
    # Forge multi-repo : chaque repo a SA liste d'issues (`_test_issues_by_repo`). `remove_label` porte le
    # REPO (pour distinguer repoA#8 de repoB#8 — MÊME numéro). Le reste = StepStubForge.
    defmodule MultiRepoForge do
      def list_org_repos(_org, opts),
        do: {:ok, Keyword.get(opts, :_test_repos, [])}

      def list_open_issues(repo, opts) do
        Map.get(Keyword.get(opts, :_test_issues_by_repo, %{}), repo, {:ok, []})
      end

      def list_open_pulls(_repo, _opts), do: {:ok, []}
      def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
      def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
      def count_change_request_rounds(_repo, _index, _opts), do: {:ok, 0}
      def get_route(_repo, _n, _opts), do: :none
      def get_predecessor_result(_repo, _n, _opts), do: :none
      def get_issue(_repo, n, _opts), do: {:ok, %{"number" => n, "body" => "x"}}
      def pr_review_state(_repo, _index, _opts), do: {:ok, %{verdicts: %{}, reviewers: []}}
    # Adoption : pose des juges sur une PR orpheline (humaine/fork, ou agent ayant perdu ses reviewers).
    def request_review(_repo, index, reviewers, _opts),
      do: send(self(), {:requested_review, index, reviewers}) && :ok
      def post_route(_repo, _n, _p, _s, _opts), do: {:ok, :posted}

      def remove_label(repo, n, label, opts) do
        send(Keyword.get(opts, :_test_pid, self()), {:remove_label, repo, n, label})
        {:ok, :removed}
      end
    end

    # Un seul pod vivant : `repoB#8` (pod_id repo-scopé pour repoB). repoA n'a AUCUN pod.
    defmodule RepoBPodSpawner do
      def spawn_pod(_profile, issue_id, _opts), do: {:ok, "pod-#{issue_id}"}
      def list_pods, do: [%{pod_id: "owner-repoB-issue-8-engineer"}]
    end

    defmodule ActiveTaskQueue2 do
      def pod_status(_pod_id), do: {:ok, :running}
    end

    test "un pod vivant #8/repoB NE masque PAS l'orphelin #8/repoA (réclamé) ET ne fait PAS réclamer #8/repoB" do
      # État illégal AVANT MA-02 : la ref `{:issue, 8}` (non repo-qualifiée) du pod vivant repoB « possédait »
      # le 8 GLOBAL → l'orphelin repoA#8 paraissait possédé → JAMAIS réclamé (wedge) ; et la grace 2-tick se
      # contaminait cross-repo. Avec la clé `{repo, :issue, 8}` : repoA#8 est orphelin (aucun pod repoA),
      # repoB#8 est possédé (pod vivant repoB) → seul repoA#8 est réclamé après la grace.
      issue8 = fn ->
        %{"number" => 8, "body" => "x", "labels" => [%{"name" => "lcars-in-flight"}]}
      end

      issues_by_repo = %{
        "owner/repoA" => {:ok, [issue8.()]},
        "owner/repoB" => {:ok, [issue8.()]}
      }

      name = :"P_ma02_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          human: "lordzurp",
          start_tick?: false,
          step_dispatch?: true,
          forge_client: MultiRepoForge,
          forge_opts: [
            _test_repos: ["owner/repoA", "owner/repoB"],
            _test_issues_by_repo: issues_by_repo,
            _test_pid: self()
          ],
          loader: StepStubLoader,
          spawner: RepoBPodSpawner,
          task_queue: ActiveTaskQueue2,
        )

      # 1er tick : repoA#8 ET repoB#8 deviennent suspects (grace) — repoB#8 sera filtré (pod vivant) mais
      # n'est réclamé NI au 1er NI au 2e tick. Rien réclamé au 1er.
      Poller.force_poll(name)
      refute_received {:remove_label, _, 8, _}

      # 2e tick consécutif : orphelin CONFIRMÉ → SEUL repoA#8 est réclamé. repoB#8 JAMAIS (pod vivant).
      Poller.force_poll(name)
      assert_received {:remove_label, "owner/repoA", 8, "lcars-in-flight"}
      refute_received {:remove_label, "owner/repoB", 8, _}

      GenServer.stop(pid)
    end
  end

  # ============================================================
  # MA-01 (bug B) — dispatch_review skippe sur awaits-arch de l'ISSUE (poller-niveau)
  # ============================================================

  describe "MA-01 (bug B) — poller thread awaits_arch_ids aux pulls" do
    test "issue 42 awaits-arch + PR head lcars/issue-42-engineer avec reviewer -> juge NON dispatché (skip)" do
      # Sans le fix : l'escalade pose `lcars-awaits-arch` sur l'ISSUE 42, mais `dispatch_review` ne lit QUE
      # les labels de la PR → le reviewer demandé fait re-spawner le juge à CHAQUE tick (churn). Avec le fix :
      # le poller calcule le SET awaits-arch (issue 42, déjà listée → zéro I/O) et le thread aux pulls →
      # dispatch_review skippe → le juge n'est PAS dispatché.
      issues = [
        %{
          "number" => 42,
          "body" => "x",
          "labels" => [%{"name" => "lcars-awaits-arch"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      pulls = [
        %{
          "number" => 7,
          "head" => %{"ref" => "lcars/issue-42-engineer", "sha" => "abc"},
          "requested_reviewers" => [%{"login" => "qualifier"}],
          "labels" => []
        }
      ]

      {name, pid} = start_step_poller({:ok, issues}, {:ok, pulls})

      # issue 42 skip (awaits-arch, decide) + PR 7 skip (awaits_arch threadé) → dispatched:0.
      assert %{dispatched: 0, errors: 0} = Poller.force_poll(name)
      refute_received {:spawned, _, _}

      GenServer.stop(pid)
    end
  end
end
