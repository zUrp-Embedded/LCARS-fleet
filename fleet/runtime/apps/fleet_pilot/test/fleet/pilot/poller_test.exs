defmodule Fleet.Pilot.PollerTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Poller

  # Rail legacy (poll_once/4 → Routing → Dispatcher → Executor RAM) RETIRÉ (②.3 / BL-050). Ses tests
  # (`describe "poll_once/4"`, stubs `StubForge`/`StubInvoker`) sont partis avec. Seul le mode stage
  # subsiste ci-dessous (+ le lifecycle GenServer, partagé).

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
  # Mode STAGE — assignee-driven (DN forge-state-machine)
  # ============================================================

  # Forge stub pour le mode stage : list (filtre déjà appliqué côté API
  # réelle, ici on renvoie tel quel) + les write-ops touchées par
  # StageDispatcher.dispatch_issue (add_label / post_comment).
  defmodule StageStubForge do
    # F-037 — le poller DÉCOUVRE ses repos par topic AVANT de scanner. Défaut = LE repo de test (les tests
    # single-repo restent identiques : 1 repo découvert → 1 `stage_do_poll`). `_test_repos` pour le multi-repo,
    # `_test_discover` pour simuler une découverte en erreur (forge down → backoff).
    def search_repos_by_topic(_topic, opts) do
      Keyword.get(
        opts,
        :_test_discover,
        {:ok, Keyword.get(opts, :_test_repos, ["lordzurp/lcars-test"])}
      )
    end

    # F — frontière d'admission : le poller n'admet QUE les repos scellés système (`admitted?`). Défaut
    # `true` (les tests single-repo restent : repo découvert = repo admis). Override par `:_test_admitted`
    # (map repo → bool) pour exercer « topic seul (non admis) » vs « scellé système (admis) ».
    def admitted?(repo, _human, opts) do
      case Keyword.get(opts, :_test_admitted) do
        nil -> true
        admitted_map -> Map.get(admitted_map, repo, false)
      end
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

    # Corr.3 4-C : le mode stage liste AUSSI les PR (chemin juge), scopées pareil (assigned_by). Default {:ok, []}.
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
    # (map n → {carte, stage}). Défaut :none (issue non routé → A1 producteur).
    def get_route(_repo, n, opts) do
      case Map.get(Keyword.get(opts, :_test_routes, %{}), n) do
        {carte, stage} -> {:ok, {carte, stage}}
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

  defmodule StageStubLoader do
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

  # Loader de CARTE (load!/1) — distinct du loader CapProfile ci-dessus (load/1).
  defmodule StageStubCarteLoader do
    # 1-stage (producteur engineer) : un issue routé ici (stage=build=1er) est EN FILE (pas démarré).
    def load!("qa-build") do
      %{"name" => "qa-build", "stages" => %{"build" => %{"role" => "engineer", "needs" => []}}}
    end

    # 2-stage : routé au 2e stage (deploy ≠ 1er) = pipeline AVANCÉ (entre deux step_runs) = ENGAGÉ.
    def load!("qa-2") do
      %{
        "name" => "qa-2",
        "stages" => %{
          "build" => %{"role" => "engineer", "needs" => []},
          "deploy" => %{"role" => "engineer", "needs" => ["build"]}
        }
      }
    end
  end

  defmodule StageStubSpawner do
    def spawn_pod(_profile, issue_id, opts) do
      send(self(), {:spawned, issue_id, opts})
      {:ok, "pod-#{issue_id}"}
    end

    # Réconciliation (B) : aucun pod vivant par défaut → tout verrou `lcars-in-flight` est candidat
    # orphelin (réclamé après la grace 2-tick). Un stub avec list_pods absent ferait fail-safe (skip).
    def list_pods, do: []
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

  # Recovery de wake qui ÉCHOUE (pod injoignable, re-roll non réparé) → `StageDispatcher.dispatch_issue`
  # surface `{:error, {:wake_unreached, …}}` : le pipeline EST démarré (verrou + pod + brief posés en amont,
  # ordre canonique), seul le réveil tmux a raté. Sert à prouver le contrat « wake raté ⇒ bail PRIS ».
  defmodule FailingWakeRecovery do
    def wake(_pod_id, _respawn_fun, _opts), do: {:error, {:escalated, :not_found}}
  end

  # Loader de CARTE qui RATE TRANSITOIREMENT sur `qa-2` (carte → nil) mais charge `qa-build` normalement.
  # Simule un échec réseau/forge de chargement de carte sur un pipeline routé-avancé : le bail ne doit PAS
  # se libérer pour autant (fail-closed). `load!/1` LÈVE pour `qa-2` → le poller (load_carte_or_nil) ET le
  # StageDispatcher (load_carte) le rescue-ent en nil/`{:error}`.
  defmodule NilCarteForQa2Loader do
    def load!("qa-2"), do: raise("carte qa-2 indisponible (échec transitoire simulé)")

    def load!("qa-build"),
      do: %{
        "name" => "qa-build",
        "stages" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }
  end

  defp start_stage_poller(issues_response, pulls_response \\ {:ok, []}) do
    name = :"P_stage_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Poller.start_link(
        name: name,
        repo: "lordzurp/lcars-test",
        human: "lordzurp",
        start_tick?: false,
        stage_dispatch?: true,
        forge_client: StageStubForge,
        forge_opts: [
          _test_issues: issues_response,
          _test_pulls: pulls_response,
          _test_pid: self()
        ],
        loader: StageStubLoader,
        spawner: StageStubSpawner,
        clock: fn :second -> 1_700_000_000 end
      )

    {name, pid}
  end

  describe "mode stage — force_poll" do
    test "issue assignée ROUTELESS → onboardée sur la carte par défaut (skip, pas de spawn)" do
      issues = [
        %{
          "number" => 7,
          "body" => "fais le hello",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      {name, pid} = start_stage_poller({:ok, issues})

      # #5.2 D2 — route nil → le poller ONBOARDE (grave la carte par défaut brief-gate via Loader) puis
      # DÉFÈRE → skip (le tick suivant la voit routée → dispatch). Le dispatch routé est testé dans le
      # describe « route gravée » + stage_dispatcher_test. Au niveau Poller, le contrat = le tally.
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

      {name, pid} = start_stage_poller({:ok, issues})

      assert %{dispatched: 0, skipped: 1, errors: 0} = Poller.force_poll(name)
      refute_received {:spawned, _, _}

      GenServer.stop(pid)
    end

    test "réconciliation (B) : verrou orphelin réclamé au 2e tick (grace), pas au 1er" do
      # #8 verrouillé mais AUCUN pod vivant (StageStubSpawner.list_pods → []) = orphelin confirmé.
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      {name, pid} = start_stage_poller({:ok, issues})

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
          stage_dispatch?: true,
          forge_client: StageStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StageStubLoader,
          spawner: LivePodSpawner,
          task_queue: ActiveTaskQueue,
          clock: fn :second -> 1_700_000_000 end
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
          stage_dispatch?: true,
          forge_client: StageStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StageStubLoader,
          spawner: ProjectPipeSpawner,
          task_queue: ProjectTaskQueueIssue8,
          clock: fn :second -> 1_700_000_000 end
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
          stage_dispatch?: true,
          forge_client: StageStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StageStubLoader,
          spawner: ProjectPipeSpawner,
          task_queue: ProjectTaskQueueIssue9,
          clock: fn :second -> 1_700_000_000 end
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
      {name, pid} = start_stage_poller({:ok, []}, {:ok, []})

      Poller.force_poll(name)

      assert_received {:scoped, :issues, "lordzurp"}
      assert_received {:scoped, :pulls, "lordzurp"}

      GenServer.stop(pid)
    end

    test "F-037 : erreur de LISTE per-repo → tally error MAIS pas de backoff (err_streak 0, forge up)" do
      # Un repo qui liste mal (500) ne backoff PAS toute la fleet : la DÉCOUVERTE a réussi (forge up), donc
      # err_streak/error_count restent à 0 (réservés à l'échec de découverte). L'erreur per-item vit dans la
      # TALLY (errors:1) + `last_tally_errors`.
      {name, pid} = start_stage_poller({:error, {:http, 500, "boom"}})

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
          stage_dispatch?: true,
          forge_client: StageStubForge,
          forge_opts: [_test_discover: {:error, {:http, 503, "down"}}],
          spawner: StageStubSpawner,
          clock: fn :second -> 1_700_000_000 end
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
          stage_dispatch?: true,
          forge_client: StageStubForge,
          forge_opts: [
            _test_repos: ["lordzurp/proj-a", "lordzurp/proj-b"],
            _test_issues: {:ok, [issue]}
          ],
          loader: StageStubLoader,
          spawner: StageStubSpawner,
          clock: fn :second -> 1_700_000_000 end
        )

      assert %{dispatched: 0, skipped: 2, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "issue ROUTÉ (route-comment) + assignee → démarre → dispatche le rôle du stage (carte_role)" do
      # #8 cohérence : le routing vient de la ROUTE-COMMENT (gravée par create_issue), plus du label.
      # #10 routé qa-build:build (1er stage = en file), assigné humain, bail libre → DÉMARRE → le poller
      # dispatche le rôle du stage courant (build → engineer via carte_role).
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
          stage_dispatch?: true,
          forge_client: StageStubForge,
          forge_opts: [
            _test_issues: {:ok, issues},
            _test_routes: %{10 => {"qa-build", "build"}}
          ],
          loader: StageStubLoader,
          carte_loader: StageStubCarteLoader,
          spawner: StageStubSpawner,
          clock: fn :second -> 1_700_000_000 end
        )

      # tally = le contrat au niveau Poller (le spawn part dans la mailbox du GenServer, pas du test ;
      # le rôle dispatché par carte_role est unit-testé dans stage_dispatcher_test).
      assert %{dispatched: 1, skipped: 0, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end
  end

  # ============================================================
  # F — frontière d'admission : topic SEUL ne suffit pas, il faut le sceau système (`admitted?`).
  # ============================================================
  #
  # Le topic `lcars-fleet-<human>` (mutable) rend un repo DÉCOUVRABLE ; un user honnête peut se l'auto-
  # poser sur un repo qu'il possède. L'admission exige le marqueur d'onboarding posé PAR le bot système
  # (`ForgeClient.admitted?`, vérifié bot-authored server-side). Le poller n'admet/ne scanne QUE les repos
  # scellés ; un repo tagué mais non onboardé est ÉCARTÉ avant tout dispatch.
  describe "mode stage — frontière d'admission système (F)" do
    # `list_open_issues` envoie `{:scoped, :issues, _}` au pid de test SSI le repo est scanné → c'est notre
    # sonde « ce repo a-t-il franchi l'admission ». Un repo non admis NE déclenche PAS cet appel.
    defp start_admission_poller(repos, admitted_map, issue) do
      name = :"P_admit_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          human: "lordzurp",
          start_tick?: false,
          stage_dispatch?: true,
          forge_client: StageStubForge,
          forge_opts: [
            _test_repos: repos,
            _test_admitted: admitted_map,
            _test_issues: {:ok, [issue]},
            _test_pid: self()
          ],
          loader: StageStubLoader,
          spawner: StageStubSpawner,
          clock: fn :second -> 1_700_000_000 end
        )

      {name, pid}
    end

    @assigned_issue %{
      "number" => 1,
      "body" => "x",
      "labels" => [],
      "assignees" => [%{"login" => "lordzurp"}]
    }

    test "repo tagué mais SANS sceau système (topic seul) → ÉCARTÉ, jamais scanné/dispatché" do
      # LE finding : le repo porte le topic (découvert) mais `admitted? = false` (pas de marqueur bot). Il
      # ne doit PAS entrer dans la machine : aucun scan (`list_open_issues` jamais appelé → pas de `:scoped`),
      # zéro dispatch. Régression prouvée : retirer le filtre `admitted_repos` de `do_poll` (poller.ex) fait
      # repasser ce repo en scanné → `{:scoped, ...}` reçu + l'issue dispatchée. Le sceau EST la frontière.
      {name, pid} =
        start_admission_poller(
          ["lordzurp/evil-untagged"],
          %{"lordzurp/evil-untagged" => false},
          @assigned_issue
        )

      assert %{dispatched: 0, skipped: 0, errors: 0} = Poller.force_poll(name)
      refute_received {:scoped, :issues, _}
      refute_received {:spawned, _, _}

      GenServer.stop(pid)
    end

    test "repo SCELLÉ système (marqueur bot) → admis, scanné (issue traitée)" do
      # Le pendant : un repo avec `admitted? = true` (marqueur d'onboarding bot-authored) PASSE l'admission
      # → il est scanné (`:scoped` reçu) et son issue assignée traitée (ici routeless → onboardée+déférée).
      {name, pid} =
        start_admission_poller(["lordzurp/sealed"], %{"lordzurp/sealed" => true}, @assigned_issue)

      assert %{dispatched: 0, skipped: 1, errors: 0} = Poller.force_poll(name)
      assert_received {:scoped, :issues, "lordzurp"}

      GenServer.stop(pid)
    end

    test "mix découverte : seul le repo scellé est admis, le tagué-seul est écarté" do
      # 2 repos découverts par topic ; un seul porte le sceau. Le poller scanne UNIQUEMENT le scellé → une
      # seule sonde `:scoped` (le tagué-seul n'en produit aucune). L'isolation REPO devient le sceau système,
      # pas le topic mutable.
      {name, pid} =
        start_admission_poller(
          ["lordzurp/sealed", "lordzurp/evil-untagged"],
          %{"lordzurp/sealed" => true, "lordzurp/evil-untagged" => false},
          @assigned_issue
        )

      assert %{dispatched: 0, skipped: 1, errors: 0} = Poller.force_poll(name)
      assert_received {:scoped, :issues, "lordzurp"}
      refute_received {:scoped, :issues, _}

      GenServer.stop(pid)
    end
  end

  # ============================================================
  # Bail repo-serialise (incrément 3) : au plus 1 pipeline actif par repo.
  # ============================================================
  describe "mode stage — bail repo-serialise" do
    # `extra_opts` surcharge les opts (Keyword.merge en dernier) : injecte un seam (`wake_recovery`) ou
    # remplace un défaut (`carte_loader`) sans dupliquer le harnais.
    defp start_entry_poller(issues_response, routes, extra_opts \\ []) do
      name = :"P_lease_#{System.unique_integer([:positive])}"

      base = [
        name: name,
        repo: "lordzurp/lcars-test",
        human: "lordzurp",
        start_tick?: false,
        stage_dispatch?: true,
        forge_client: StageStubForge,
        forge_opts: [_test_issues: issues_response, _test_routes: routes],
        loader: StageStubLoader,
        carte_loader: StageStubCarteLoader,
        spawner: StageStubSpawner,
        clock: fn :second -> 1_700_000_000 end
      ]

      {:ok, pid} = Poller.start_link(Keyword.merge(base, extra_opts))

      {name, pid}
    end

    test "un pipeline ENGAGÉ (route avancée) tient le bail et bloque un issue EN FILE" do
      # #8 : le bail se lit sur la ROUTE (state-machine), PLUS sur state:*. #11 routé qa-2:deploy (2e
      # stage ≠ 1er = pipeline AVANCÉ entre deux step_runs) → ENGAGÉ → tient le bail ET son stage courant est
      # dispatché (continue le step_run). #12 routé qa-build:build (1er stage = EN FILE) → bail tenu → attend.
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
      # Régression prouvée : reviens à l'ancien `stage_do_dispatch` (wake_unreached → errors SANS prendre le
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

    test "pipeline routé-avancé à carte NIL tient le bail (échec transitoire de carte ne libère pas le bail)" do
      # Régression : le bail se lit sur la ROUTE (append-only, robuste), JAMAIS sur le succès du chargement de
      # la carte. #18 routé qa-2:deploy (2e stage ≠ 1er = pipeline AVANCÉ = ENGAGÉ) mais sa carte échoue à
      # charger TRANSITOIREMENT (NilCarteForQa2Loader lève sur qa-2). Le pipeline reste ENGAGÉ (fail-closed) →
      # tient le bail. #19 routé qa-build:build (1er stage = EN FILE, carte qa-build charge OK), même repo →
      # bail tenu → SKIPPÉ. Aucun 2e pipeline ne démarre malgré la carte-nil.
      #
      # Régression prouvée : reviens à `engaged = not is_nil(carte_map) and not first_stage?(...)` → la
      # carte-nil de #18 le classe `engaged=false` → il sort du lease set → #19 voit le bail LIBRE → DÉMARRE un
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
          carte_loader: NilCarteForQa2Loader
        )

      # #18 engagé (carte-nil mais route avancée → fail-closed) tient le bail : son stage est dispatché mais
      # fail-loud (carte manquante côté StageDispatcher → errors:1), le bail reste TENU. #19 → bail tenu →
      # skipped:1. Aucun 2e pipeline démarré (dispatched:0).
      assert %{dispatched: 0, skipped: 1, errors: 1} = Poller.force_poll(name)

      GenServer.stop(pid)
    end
  end

  # ============================================================
  # Chemin PR-driven (Corr.3 4-C) : les juges sont dispatches via les requested_reviewers.
  # ============================================================
  describe "mode stage — dispatch juge PR-driven" do
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

      {name, pid} = start_stage_poller({:ok, []}, {:ok, pulls})

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

      {name, pid} = start_stage_poller({:ok, issues}, {:ok, pulls})

      # issue #99 skip (PR ouverte) + juge reviewer dispatche (pull) = {dispatched:1, skipped:1}
      assert %{dispatched: 1, skipped: 1, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "PR sans review demandee -> skip (rien a dispatcher)" do
      pulls = [
        %{
          "number" => 8,
          "head" => %{"ref" => "lcars/issue-42-engineer"},
          "requested_reviewers" => [],
          "labels" => []
        }
      ]

      {name, pid} = start_stage_poller({:ok, []}, {:ok, pulls})

      assert %{dispatched: 0, skipped: 1, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end
  end

  # ============================================================
  # MA-02 — refs de verrou REPO-QUALIFIÉES (collision cross-repo)
  # ============================================================

  describe "MA-02 — réconciliation multi-repo (clé de verrou repo-qualifiée)" do
    # Forge multi-repo : chaque repo a SA liste d'issues (`_test_issues_by_repo`). `remove_label` porte le
    # REPO (pour distinguer repoA#8 de repoB#8 — MÊME numéro). Le reste = StageStubForge.
    defmodule MultiRepoForge do
      def search_repos_by_topic(_topic, opts),
        do: {:ok, Keyword.get(opts, :_test_repos, [])}

      # Tous les repos multi-repo de ce describe sont scellés système (admis) — le test isole la
      # réconciliation de verrou, pas l'admission (couverte dans le describe « frontière d'admission »).
      def admitted?(_repo, _human, _opts), do: true

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
          stage_dispatch?: true,
          forge_client: MultiRepoForge,
          forge_opts: [
            _test_repos: ["owner/repoA", "owner/repoB"],
            _test_issues_by_repo: issues_by_repo,
            _test_pid: self()
          ],
          loader: StageStubLoader,
          spawner: RepoBPodSpawner,
          task_queue: ActiveTaskQueue2,
          clock: fn :second -> 1_700_000_000 end
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

      {name, pid} = start_stage_poller({:ok, issues}, {:ok, pulls})

      # issue 42 skip (awaits-arch, decide) + PR 7 skip (awaits_arch threadé) → dispatched:0.
      assert %{dispatched: 0, errors: 0} = Poller.force_poll(name)
      refute_received {:spawned, _, _}

      GenServer.stop(pid)
    end
  end
end
