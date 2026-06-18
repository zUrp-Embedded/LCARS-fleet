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
    # Bail repo : le mode stage liste TOUS les ouverts (list_open_issues), le filtre in-flight
    # est applique par decide. Le stub renvoie le `:_test_issues` configure tel quel.
    def list_open_issues(_repo, opts) do
      Keyword.fetch!(opts, :_test_issues)
    end

    # Corr.3 4-C : le mode stage liste AUSSI les PR ouvertes (chemin juge). Default {:ok, []}.
    def list_open_pulls(_repo, opts), do: Keyword.get(opts, :_test_pulls, {:ok, []})

    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    def get_route(_repo, _n, _opts), do: :none
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
    def load!("poc-cycle") do
      %{"name" => "poc-cycle", "stages" => %{"triage" => %{"role" => "architect", "needs" => []}}}
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
    test "issue assignée (humain) → spawn producteur (tally dispatched)" do
      issues = [
        %{
          "number" => 7,
          "body" => "fais le hello",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      {name, pid} = start_stage_poller({:ok, issues})

      # Le spawn tourne DANS le GenServer (force_poll → handle_call) : le
      # message du StageStubSpawner part dans SA mailbox, pas celle du test.
      # Au niveau Poller, le contrat = le tally. Le détail (ticket_id,
      # mandate) est unit-testé dans stage_dispatcher_test.
      assert %{dispatched: 1, skipped: 0, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "verrou lcars-in-flight → skip, pas de spawn" do
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "Engineer"}]
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
          "assignees" => [%{"login" => "Engineer"}]
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

    test "issue sans assignee (pas d'owner) → skip" do
      issues = [
        %{
          "number" => 9,
          "body" => "x",
          "labels" => [],
          "assignees" => []
        }
      ]

      {name, pid} = start_stage_poller({:ok, issues})

      assert %{dispatched: 0, skipped: 1, errors: 0} = Poller.force_poll(name)
      refute_received {:spawned, _, _}

      GenServer.stop(pid)
    end

    test "forge list en erreur → tally error + backoff (err_streak incrémenté)" do
      {name, pid} = start_stage_poller({:error, {:http, 500, "boom"}})

      assert %{dispatched: 0, skipped: 0, errors: 1} = Poller.force_poll(name)
      assert %{err_streak: 1, error_count: 1} = Poller.stats(name)

      GenServer.stop(pid)
    end

    test "ticket type: SANS assignee → ENTRÉE carte (route + 1er assignee) [A2.1]" do
      issues = [
        %{
          "number" => 10,
          "body" => "neuf",
          "labels" => [%{"name" => "type:poc"}],
          "assignees" => []
        }
      ]

      name = :"P_entry_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          start_tick?: false,
          stage_dispatch?: true,
          forge_client: StageStubForge,
          forge_opts: [_test_issues: {:ok, issues}],
          loader: StageStubLoader,
          carte_loader: StageStubCarteLoader,
          routing: %{"type:poc" => "poc-cycle"},
          spawner: StageStubSpawner,
          clock: fn :second -> 1_700_000_000 end
        )

      # pas d'assignee → pas de spawn, mais ENTRÉE réussie (route+assignee posés DANS le GenServer →
      # messages dans SA mailbox, pas celle du test ; le détail est unit-testé dans entry_test).
      # Au niveau Poller, le contrat = le tally : entrée comptée dispatched.
      assert %{dispatched: 1, skipped: 0, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end
  end

  # ============================================================
  # Bail repo-serialise (incrément 3) : au plus 1 pipeline actif par repo.
  # ============================================================
  describe "mode stage — bail repo-serialise" do
    defp start_entry_poller(issues_response) do
      name = :"P_lease_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          start_tick?: false,
          stage_dispatch?: true,
          forge_client: StageStubForge,
          forge_opts: [_test_issues: issues_response],
          loader: StageStubLoader,
          carte_loader: StageStubCarteLoader,
          routing: %{"type:poc" => "poc-cycle"},
          spawner: StageStubSpawner,
          clock: fn :second -> 1_700_000_000 end
        )

      {name, pid}
    end

    test "un pipeline en cours (ticket engagé via label) bloque l'entree d'un ticket neuf" do
      issues = [
        # #8.A : #11 déjà ENGAGÉ — signalé par le LABEL state:delivered (entre deux hops), PLUS par
        # l'assignee (= l'humain). Tient le bail → sera dispatché (advance). Bloque l'entrée de #12.
        %{
          "number" => 11,
          "body" => "en cours",
          "labels" => [%{"name" => "state:delivered"}],
          "assignees" => [%{"login" => "lordzurp"}]
        },
        # #12 neuf (type:poc, pas d'assignee) -> entree BLOQUEE par le bail.
        %{
          "number" => 12,
          "body" => "neuf",
          "labels" => [%{"name" => "type:poc"}],
          "assignees" => []
        }
      ]

      {name, pid} = start_entry_poller({:ok, issues})

      assert %{dispatched: 1, skipped: 1, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "deux tickets neufs -> un seul entre, l'autre attend (bail pris dans le tick)" do
      issues = [
        %{
          "number" => 13,
          "body" => "neuf1",
          "labels" => [%{"name" => "type:poc"}],
          "assignees" => []
        },
        %{
          "number" => 14,
          "body" => "neuf2",
          "labels" => [%{"name" => "type:poc"}],
          "assignees" => []
        }
      ]

      {name, pid} = start_entry_poller({:ok, issues})

      assert %{dispatched: 1, skipped: 1, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "bail libre (aucun ticket engage) -> le ticket neuf entre" do
      issues = [
        %{
          "number" => 15,
          "body" => "neuf",
          "labels" => [%{"name" => "type:poc"}],
          "assignees" => []
        }
      ]

      {name, pid} = start_entry_poller({:ok, issues})

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
          "assignees" => [%{"login" => "Engineer"}]
        }
      ]

      pulls = [
        %{
          "number" => 7,
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
