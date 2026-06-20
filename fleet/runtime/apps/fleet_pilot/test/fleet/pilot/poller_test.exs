defmodule Fleet.Pilot.PollerTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Poller

  # Rail legacy (poll_once/4 → Routing → Dispatcher → Executor RAM) RETIRÉ (②.3 / BL-050). Ses tests
  # (`describe "poll_once/4"`, stubs `StubForge`/`StubInvoker`) sont partis avec. Seul le mode stage
  # subsiste ci-dessous (+ le lifecycle GenServer, partagé).

  describe "GenServer init / lifecycle" do
    test "crash si :repo manquant" do
      Process.flag(:trap_exit, true)

      assert {:error, {:missing_required_opt, :repo}} =
               Poller.start_link(name: :"P_no_repo_#{System.unique_integer([:positive])}")
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
    # (map n → {carte, stage}). Défaut :none (ticket non routé → A1 producteur).
    def get_route(_repo, n, opts) do
      case Map.get(Keyword.get(opts, :_test_routes, %{}), n) do
        {carte, stage} -> {:ok, {carte, stage}}
        _ -> :none
      end
    end

    def get_predecessor_result(_repo, _n, _opts), do: :none
    # Fix famine-d'info : build_judge_mandate lit le critère (body de l'issue) via get_issue.
    def get_issue(_repo, n, _opts), do: {:ok, %{"number" => n, "body" => "critère stub ##{n}"}}

    # ②.1d : par defaut aucun verdict de juge (les tests poller ne couvrent pas merge/rework) → tout
    # juge demandé est « pending » → dispatché.
    def pr_review_verdicts(_repo, _index, _opts), do: {:ok, %{}}
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
      do: {:ok, %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{}, spec: %{}}}

    # Corr.3 : juge de PR (qualifier/reviewer) -> mandate_kind: judge (mandat GateBrief desamorce).
    def load(role) when role in ["qualifier", "reviewer"],
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => role},
           spec: %{"mandate_kind" => "judge"}
         }}

    def load(_), do: {:error, :not_found}
  end

  # Loader de CARTE (load!/1) — distinct du loader CapProfile ci-dessus (load/1).
  defmodule StageStubCarteLoader do
    # 1-stage (producteur engineer) : un ticket routé ici (stage=build=1er) est EN FILE (pas démarré).
    def load!("qa-build") do
      %{"name" => "qa-build", "stages" => %{"build" => %{"role" => "engineer", "needs" => []}}}
    end

    # 2-stage : routé au 2e stage (deploy ≠ 1er) = pipeline AVANCÉ (entre deux hops) = ENGAGÉ.
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
    def spawn_pod(_profile, ticket_id, opts) do
      send(self(), {:spawned, ticket_id, opts})
      {:ok, "pod-#{ticket_id}"}
    end

    # Réconciliation (B) : aucun pod vivant par défaut → tout verrou `lcars-in-flight` est candidat
    # orphelin (réclamé après la grace 2-tick). Un stub avec list_pods absent ferait fail-safe (skip).
    def list_pods, do: []
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

      # #5.2 D2 — route nil → le poller ONBOARDE (grave la carte par défaut mandate-gate via Loader) puis
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

    test "D1 — le poller SCOPE les listes par assigned_by=my_human (forge-side, issues ET PR)" do
      # Le scoping multi-user vit dans la LISTE (forge-side) : le poller passe SON humain aux DEUX endpoints
      # (/issues?type=issues ET ?type=pulls). decide/dispatch_review ne re-vérifient plus l'ownership.
      {name, pid} = start_stage_poller({:ok, []}, {:ok, []})

      Poller.force_poll(name)

      assert_received {:scoped, :issues, "lordzurp"}
      assert_received {:scoped, :pulls, "lordzurp"}

      GenServer.stop(pid)
    end

    test "forge list en erreur → tally error + backoff (err_streak incrémenté)" do
      {name, pid} = start_stage_poller({:error, {:http, 500, "boom"}})

      assert %{dispatched: 0, skipped: 0, errors: 1} = Poller.force_poll(name)
      assert %{err_streak: 1, error_count: 1} = Poller.stats(name)

      GenServer.stop(pid)
    end

    test "ticket ROUTÉ (route-comment) + assignee → démarre → dispatche le rôle du stage (carte_role)" do
      # #8 cohérence : le routing vient de la ROUTE-COMMENT (gravée par create_ticket), plus du label.
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
  # Bail repo-serialise (incrément 3) : au plus 1 pipeline actif par repo.
  # ============================================================
  describe "mode stage — bail repo-serialise" do
    defp start_entry_poller(issues_response, routes) do
      name = :"P_lease_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
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
        )

      {name, pid}
    end

    test "un pipeline ENGAGÉ (route avancée) tient le bail et bloque un ticket EN FILE" do
      # #8 : le bail se lit sur la ROUTE (state-machine), PLUS sur state:*. #11 routé qa-2:deploy (2e
      # stage ≠ 1er = pipeline AVANCÉ entre deux hops) → ENGAGÉ → tient le bail ET son stage courant est
      # dispatché (continue le hop). #12 routé qa-build:build (1er stage = EN FILE) → bail tenu → attend.
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

    test "deux tickets EN FILE -> un seul démarre, l'autre attend (bail pris dans le tick)" do
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

    test "bail libre (aucun pipeline engagé) -> le ticket EN FILE démarre" do
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
end
