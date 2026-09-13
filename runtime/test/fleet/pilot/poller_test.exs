defmodule Fleet.Pilot.PollerTest do
  use ExUnit.Case, async: false

  # Serialized because this file changes global onboarding, lease and fixture settings.
  # Restoring them after a test does not isolate readers during it.

  alias Fleet.Forge.PayloadFixture
  alias Fleet.Pilot.Poller

  import Fleet.Pilot.PollerBench

  alias Fleet.Pilot.PollerBench.{
    FailingWakeRecovery,
    NilWorkflowMapForQa2Loader,
    StepStubForge,
    StepStubLoader,
    StepStubSpawner,
    StepStubWorkflowMapLoader
  }

  defmodule RaisingWorkflowMapLoader do
    def load!(name), do: raise("workflow_map #{name} not found (removed from the catalog)")
  end

  describe "G6 — unreadable workflow_map → escalation (repo no longer silently blocked)" do
    test "workflow_map load RAISES during classify → incident_fun called (lease held BUT visible)" do
      parent = self()

      # An advanced route requires a card lookup; inject a raising loader while
      # keeping discovery/admission valid.
      {name, pid} =
        start_entry_poller(
          {:ok,
           [
             PayloadFixture.issue(
               number: 42,
               body: "x",
               label_names: [],
               assignee_logins: ["lordzurp"]
             )
           ]},
          %{42 => {"ghostmap", "deploy"}},
          workflow_map_loader: RaisingWorkflowMapLoader,
          incident_fun: fn op, subject, reason, _opts ->
            send(parent, {:incident, op, subject, reason})
            :recorded
          end
        )

      Poller.force_poll(name)

      # Verify the incident callback; this stub does not prove a sysadmin issue was opened.
      assert_received {:incident, "workflow_map_load", "ghostmap",
                       {:workflow_map_load_failed, _msg}}

      GenServer.stop(pid)
    end
  end

  # Queue doubles report enqueue calls so assertions observe effects, not only logs.
  # The test PID travels through global config because calls run inside the poller.
  defmodule ArchFreeTQ do
    def list_active, do: []
    def pod_active_issue_id(_pod_id), do: {:ok, nil}
    def pod_status(_pod_id), do: {:ok, nil}

    def enqueue(pod_id, attrs) do
      if p = Application.get_env(:lcars_fleet, :_test_arch_pid),
        do: send(p, {:arch_enqueue, pod_id, attrs})

      {:ok, %{id: "wi-arch"}}
    end
  end

  defmodule ArchBusyTQ do
    def list_active, do: []
    def pod_active_issue_id(_pod_id), do: {:ok, nil}
    def pod_status(_pod_id), do: {:ok, :assigned}

    def enqueue(pod_id, attrs) do
      if p = Application.get_env(:lcars_fleet, :_test_arch_pid),
        do: send(p, {:arch_enqueue, pod_id, attrs})

      {:ok, %{id: "wi-arch"}}
    end
  end

  defmodule ArchPendingTQ do
    def list_active, do: []
    def pod_active_issue_id(_pod_id), do: {:ok, nil}
    def pod_status(_pod_id), do: {:ok, :pending}

    def enqueue(pod_id, attrs) do
      if p = Application.get_env(:lcars_fleet, :_test_arch_pid),
        do: send(p, {:arch_enqueue, pod_id, attrs})

      {:ok, %{id: "wi-arch"}}
    end
  end

  describe "G4 — awaits_rekick?/3 (arch net cooldown)" do
    # The first eligible tick is immediate; cooldown follows the last successful net wake.
    test "issue waits AND never kicked (nil) → fire on the first tick" do
      assert Poller.awaits_rekick?(1, nil, 0)
      assert Poller.awaits_rekick?(3, nil, 999)
    end

    test "issue waits AND cooldown elapsed → fire" do
      assert Poller.awaits_rekick?(1, 0, 300_000)
      assert Poller.awaits_rekick?(2, 1_000, 400_000)
    end

    test "no waiting issue → NEVER a kick (even with cooldown elapsed)" do
      refute Poller.awaits_rekick?(0, nil, 0)
      refute Poller.awaits_rekick?(0, 0, 999_999)
    end

    test "issue waits BUT cooldown NOT elapsed → no kick (protection BEHIND the first kick)" do
      refute Poller.awaits_rekick?(1, 0, 1)
      refute Poller.awaits_rekick?(2, 0, 299_999)
      refute Poller.awaits_rekick?(1, 100_000, 350_000)
    end

    test "PROD WIRING (spawner nil): the re-kick runs with the REAL default Fleet.Spawner" do
      # Exercise nil → production default; a nil guard would silently disable the net.
      issue =
        PayloadFixture.issue(
          number: 42,
          body: "x",
          label_names: ["lcars-awaits-arch"],
          assignee_logins: ["lordzurp"]
        )

      # Use the free path so the test reaches wake, rather than deliberately skipping it.
      {name, pid} = start_entry_poller({:ok, [issue]}, %{}, spawner: nil, task_queue: ArchFreeTQ)

      # Cooldown semantics: the net fires on the FIRST tick (last_arch_rekick_at nil).
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..2, do: Poller.force_poll(name)
        end)

      # The real spawner cannot wake this absent architect. Expect failure without
      # a cooldown stamp, so subsequent eligible ticks can retry.
      assert log =~ "ArchWake: [net]"
      assert log =~ "UNREACHED"
      refute log =~ "cooldown"

      GenServer.stop(pid)
    end

    # A raising repository must not prevent later repositories from being attempted.
    # The escalation stub succeeds; failure of that handler is outside this case.
    defmodule RaisingForge do
      # Depot du milieu : il leve. Les deux autres se comportent normalement.
      def list_open_issues("fleet/repo-b", _opts), do: raise("conflit pathologique sur repo-b")

      def list_open_issues(repo, opts) do
        send(Keyword.get(opts, :_test_pid, self()), {:served, repo})
        Keyword.fetch!(opts, :_test_issues)
      end

      defdelegate list_open_pulls(repo, opts), to: Fleet.Pilot.PollerBench.StepStubForge
      defdelegate list_org_repos(org, opts), to: Fleet.Pilot.PollerBench.StepStubForge
      defdelegate issue_dependencies(repo, n, opts), to: Fleet.Pilot.PollerBench.StepStubForge
      defdelegate get_pull(repo, n, opts), to: Fleet.Pilot.PollerBench.StepStubForge
      defdelegate commit_ci_state(repo, sha, opts), to: Fleet.Pilot.PollerBench.StepStubForge
    end

    test "JG-067 : un depot qui leve ne prive plus de service ceux qui le SUIVENT" do
      test = self()

      {name, pid} =
        start_entry_poller({:ok, []}, %{},
          forge_client: RaisingForge,
          escalate_fun: fn kind, subject, cause, sig, _o ->
            send(test, {:escalated, kind, subject, cause, sig})
            {:ok, 1}
          end,
          forge_opts: [
            _test_issues: {:ok, []},
            _test_pid: self(),
            _test_repos: ["fleet/repo-a", "fleet/repo-b", "fleet/repo-c"]
          ]
        )

      _ = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)

      assert_received {:served, "fleet/repo-a"}

      assert_received {:served, "fleet/repo-c"},
                      "le depot qui SUIT celui qui a leve n'a pas ete servi — une seule PR " <>
                        "pathologique prive de service tout le reste de l'ordre d'iteration"

      assert_received {:escalated, :repo_poll_crash, "fleet/repo-b", {:poll_raised, _}, _sig},
                      "le depot en panne est saute EN SILENCE"

      GenServer.stop(pid)
    end

    test "A-10: 2 awaits-arch repos → EXACTLY 1 re-kick per throttle tick (not 1 per repo)" do
      issue =
        PayloadFixture.issue(
          number: 42,
          body: "x",
          label_names: ["lcars-awaits-arch"],
          assignee_logins: ["lordzurp"]
        )

      # Replace forge_opts with a two-repo fixture. Stub wakes return :ok so the
      # fleet-wide cooldown engages; a real absent architect would not arm it.
      {name, pid} =
        start_entry_poller({:ok, [issue]}, %{},
          task_queue: ArchFreeTQ,
          forge_opts: [
            _test_issues: {:ok, [issue]},
            _test_routes: %{},
            _test_repos: ["fleet/repo-a", "fleet/repo-b"]
          ]
        )

      # Count one aggregate net log; this does not assert one actual wake across two repos.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..10, do: Poller.force_poll(name)
        end)

      net_lines =
        log |> String.split("\n") |> Enum.count(&String.contains?(&1, "(fleet-wide) → net"))

      assert net_lines == 1,
             "expected EXACTLY 1 net line (fleet-global, cooldown-capped), saw #{net_lines}:\n#{log}"

      # and the logged count is the fleet-wide backlog (2 issues: one per repo)
      assert log =~ "2 issue(s) awaits-arch (fleet-wide)"

      GenServer.stop(pid)
    end

    # A free architect receives an arbitration work item derived from the forge backlog.
    test "FREE arch + awaits-arch issue → the poller ENQUEUES an arbitration mandate to the arch" do
      issue =
        PayloadFixture.issue(
          number: 42,
          body: "x",
          label_names: ["lcars-awaits-arch"],
          assignee_logins: ["lordzurp"]
        )

      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :_test_arch_pid, self())
      {name, pid} = start_entry_poller({:ok, [issue]}, %{}, task_queue: ArchFreeTQ)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..2, do: Poller.force_poll(name)
        end)

      # Observe the queue call as well as its log.
      assert_received {:arch_enqueue, _pod_id, _attrs}
      assert log =~ "mandate lordzurp/lcars-test#42 enqueued (arch was free)"

      GenServer.stop(pid)
    end

    # Pending work needs another wake without re-enqueueing the same mandate.
    test "PENDING arch mandate (never fetched) → re-wake ONLY, no new enqueue" do
      issue =
        PayloadFixture.issue(
          number: 42,
          body: "x",
          label_names: ["lcars-awaits-arch"],
          assignee_logins: ["lordzurp"]
        )

      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :_test_arch_pid, self())
      {name, pid} = start_entry_poller({:ok, [issue]}, %{}, task_queue: ArchPendingTQ)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..2, do: Poller.force_poll(name)
        end)

      # A silent enqueue would evade log-only assertions; check the queue spy.
      refute_received {:arch_enqueue, _, _}
      assert log =~ "pending mandate never fetched → re-wake only"
      refute log =~ "enqueued (arch was free)"

      GenServer.stop(pid)
    end

    # Assigned work suppresses both enqueue and wake; the forge retains awaiting tickets.
    test "BUSY arch (active work-item) → NO enqueue, NO wake (it already knows its mandate)" do
      issue =
        PayloadFixture.issue(
          number: 42,
          body: "x",
          label_names: ["lcars-awaits-arch"],
          assignee_logins: ["lordzurp"]
        )

      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :_test_arch_pid, self())
      {name, pid} = start_entry_poller({:ok, [issue]}, %{}, task_queue: ArchBusyTQ)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..10, do: Poller.force_poll(name)
        end)

      # Assert the absence of the queue effect, not merely a missing log.
      refute_received {:arch_enqueue, _, _}

      # Scope captured logs to this repository to avoid unrelated writers.
      # The wake assertion remains log-based; enqueue has a direct spy.
      refute log =~ ~r/ArchWake.*lcars-test/
      refute log =~ "(fleet-wide) → net"

      GenServer.stop(pid)
    end
  end

  describe "GenServer init / lifecycle" do
    test "F-037: init WITHOUT :repo succeeds (topic discovery, no fixed repo required anymore)" do
      # Organisation discovery replaces a fixed repo. Human scope remains required;
      # the historical test title still says topic discovery.
      name = :"P_no_repo_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end
        )

      assert Process.alive?(pid)
      assert %{poll_count: 0, error_count: 0, err_streak: 0} = Poller.stats(name)

      GenServer.stop(pid)
    end

    test "start succeeds with start_tick?: false (no scheduled tick)" do
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
  # STEP mode — assignee-driven (DN forge-state-machine)
  # ============================================================

  describe "architect keeper — `forever` has to be someone's job" do
    # Regular ticks check the registered architect between lifecycle events.
    test "a regular tick keeps the architect of a LIVE project" do
      issues = [PayloadFixture.issue(number: 7, body: "x", label_names: [], assignee_login: "l")]
      me = self()
      {name, _pid} = start_keeper_poller(issues, fn repo, _o -> send(me, {:kept, repo}) end)

      Poller.force_poll(name)
      assert_receive {:kept, "lordzurp/lcars-test"}, 1_000
    end

    test "a PARKED project gets NO architect — a stopped fleet needs no arbiter" do
      # The parked marker is already in the listing. Use the protocol's constructor
      # so fixture spelling follows production.
      parked = [
        PayloadFixture.issue(
          number: 1,
          body: "",
          title: Fleet.Forge.Protocol.parked_issue_title(),
          label_names: []
        )
      ]

      me = self()
      {name, _pid} = start_keeper_poller(parked, fn repo, _o -> send(me, {:kept, repo}) end)

      Poller.force_poll(name)
      refute_receive {:kept, _}, 300
    end
  end

  defp start_keeper_poller(issues, keeper) do
    name = :"P_keep_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Poller.start_link(
        name: name,
        repo: "lordzurp/lcars-test",
        human: "lordzurp",
        start_tick?: false,
        protection_reconciler: fn _repo, _opts -> :ok end,
        architect_keeper: keeper,
        step_dispatch?: true,
        forge_client: StepStubForge,
        forge_opts: [_test_issues: {:ok, issues}, _test_pulls: {:ok, []}, _test_pid: self()],
        loader: StepStubLoader,
        spawner: StepStubSpawner
      )

    {name, pid}
  end

  describe "admission — discovery is not admission" do
    # Enable the gate disabled by the test baseline for fictional repositories.
    setup do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_require_onboarded, true)
      :ok
    end

    # Declare the root present to isolate a missing project from missing substrate.
    # Do not provision the real layout just to exercise this branch.
    defp substrate_present, do: [substrate_present_fun: fn -> true end]

    test "a repo with no project directory is SKIPPED — and costs not one forge call" do
      # Check that issue listing is absent as well as spawn: this distinguishes
      # a pre-list guard from a later dispatch-only guard. Discovery still runs.
      issues = [
        PayloadFixture.issue(number: 7, body: "x", label_names: [], assignee_login: "lordzurp")
      ]

      {name, pid} = start_step_poller({:ok, issues}, {:ok, []}, substrate_present())

      log = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)

      refute_received {:scoped, :issues, _}
      refute_received {:spawned, _, _}
      assert log =~ "NOT ONBOARDED"
      assert log =~ "create / import / open / adopt"

      GenServer.stop(pid)
    end

    test "the warning fires ONCE per repo, not once per tick" do
      {name, pid} = start_step_poller({:ok, []}, {:ok, []}, substrate_present())

      first = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)
      second = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)

      assert first =~ "NOT ONBOARDED"
      # A ~30s cron that cries every tick teaches an operator to filter the rail out. Same stance
      # as the parked marker, same pdict memory.
      refute second =~ "NOT ONBOARDED"

      GenServer.stop(pid)
    end

    test "the gate names the REAL ops path — the composition, not a stub of itself" do
      # Check layout composition without creating real runtime directories.
      # This expression does not exercise Poller's positive filesystem admission.
      assert Path.join(Fleet.Layout.ops_root(), Fleet.Layout.project_name("lordzurp/lcars-test")) ==
               Path.join(Fleet.Layout.ops_root(), "lcars-test")

      assert String.starts_with?(Fleet.Layout.ops_root(), "/home/projects")
    end

    # Toggle the gate to exercise disappearance/recovery/disappearance logging
    # without modifying the real ops tree. This tests display-state reset, not mounts.
    test "JG-060 : un depot qui repasse en « non onboarde » est journalise A NOUVEAU" do
      {name, pid} = start_step_poller({:ok, []}, {:ok, []}, substrate_present())

      first = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)
      assert first =~ "NOT ONBOARDED"

      # Il sort du garde : le drapeau doit tomber avec lui.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_require_onboarded, false)
      _ = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)

      # Il y revient.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_require_onboarded, true)
      third = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)

      assert third =~ "NOT ONBOARDED",
             "la seconde disparition de l'arborescence est muette — la memoire d'affichage est " <>
               "devenue une memoire definitive"

      GenServer.stop(pid)
    end

    test "JG-059 : racine ABSENTE → message de SUBSTRAT + incident, jamais « NOT ONBOARDED »" do
      test = self()

      {name, pid} =
        start_step_poller({:ok, []}, {:ok, []},
          substrate_present_fun: fn -> false end,
          escalate_fun: fn kind, subject, cause, sig, _o ->
            send(test, {:escalated, kind, subject, cause, sig})
            {:ok, 1}
          end
        )

      log = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)

      refute log =~ "NOT ONBOARDED",
             "la disparition du substrat a ete rapportee comme un projet non onboarde"

      assert log =~ "ops root"
      assert log =~ "EVERY repo"

      assert_received {:escalated, :ops_root_missing, _root, {:ops_root_absent, _}, _sig},
                      "le substrat a disparu et rien de durable ne le dit"

      GenServer.stop(pid)
    end

    test "JG-059 : le message de substrat ne sort qu'UNE fois, pas une par depot" do
      {name, pid} =
        start_step_poller({:ok, []}, {:ok, []},
          substrate_present_fun: fn -> false end,
          escalate_fun: fn _k, _s, _c, _sig, _o -> {:ok, 1} end
        )

      first = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)
      second = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)

      assert first =~ "ops root"
      refute second =~ "ops root", "la panne de substrat crie a chaque tick"

      GenServer.stop(pid)
    end

    test "NOT ONBOARDED is the gate's own verdict, and it needs no filesystem to be proven" do
      # Covers a missing project only. Existing-directory admission requires a runtime
      # fixture outside this test; no positive filesystem behavior is proved here.
      {name, pid} = start_step_poller({:ok, []}, {:ok, []}, substrate_present())

      log = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)

      assert log =~ "NOT ONBOARDED"
      refute_received {:scoped, :issues, _}

      GenServer.stop(pid)
    end
  end

  describe "step mode — force_poll" do
    test "ROUTELESS assigned issue → onboarded onto the default workflow_map (skip, no spawn)" do
      issues = [
        PayloadFixture.issue(
          number: 7,
          body: "fais le hello",
          label_names: [],
          assignee_logins: ["lordzurp"]
        )
      ]

      {name, pid} = start_step_poller({:ok, issues})

      # Verify deferred routing via the tally; role spawning is tested separately.
      assert %{dispatched: 0, skipped: 1, errors: 0} = Poller.force_poll(name)
      refute_received {:spawned, _, _}

      GenServer.stop(pid)
    end

    test "BL-6-30: a PARKED repo (open marker issue) → FULL step-rail skip, zero tally, no onboard" do
      issues = [
        %{
          "number" => 3,
          "title" => Fleet.Forge.Protocol.parked_issue_title(),
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        },
        # An issue that would be ONBOARDED (routeless → default map recorded) on a live repo —
        # the skip must stop even that write, not just spawns.
        PayloadFixture.issue(
          number: 7,
          body: "fais le hello",
          label_names: [],
          assignee_logins: ["lordzurp"]
        )
      ]

      {name, pid} = start_step_poller({:ok, issues})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # ZERO across the tally: the repo is not walked at all (skipped would count items).
          assert %{dispatched: 0, skipped: 0, errors: 0} = Poller.force_poll(name)
        end)

      assert log =~ "PARKED"
      refute_received {:spawned, _, _}
      # The routeless onboard of #7 never ran (no route recorded on a parked repo).
      refute_received {:route, _, _}

      # Loud-once: the second tick over the same park stays silent.
      log2 = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)
      refute log2 =~ "PARKED"

      GenServer.stop(pid)
    end

    test "lcars-in-flight lock → skip, no spawn" do
      issues = [
        PayloadFixture.issue(
          number: 8,
          body: "x",
          label_names: ["lcars-in-flight"],
          assignee_logins: ["lordzurp"]
        )
      ]

      {name, pid} = start_step_poller({:ok, issues})

      assert %{dispatched: 0, skipped: 1, errors: 0} = Poller.force_poll(name)
      refute_received {:spawned, _, _}

      GenServer.stop(pid)
    end

    test "D1 — the poller SCOPES the lists by assigned_by=my_human (forge-side, issues AND PRs)" do
      # Verify assigned_by on both listing calls. Stubs do not implement forge-side filtering.
      {name, pid} = start_step_poller({:ok, []}, {:ok, []})

      Poller.force_poll(name)

      assert_received {:scoped, :issues, "lordzurp"}
      assert_received {:scoped, :pulls, "lordzurp"}

      GenServer.stop(pid)
    end

    test "F-037: per-repo LIST error → tally error BUT no backoff (err_streak 0, forge up)" do
      # Per-repo list failures affect tally, not fleet backoff after successful discovery.
      {name, pid} = start_step_poller({:error, {:http, 500, "boom"}})

      assert %{dispatched: 0, skipped: 0, errors: 1} = Poller.force_poll(name)
      assert %{err_streak: 0, error_count: 0, last_tally_errors: 1} = Poller.stats(name)

      GenServer.stop(pid)
    end

    test "DECOUVERTE MULTI-ORG : une org illisible fait echouer le tick, jamais une liste partielle" do
      # An unreadable organisation makes discovery incomplete and fails the pass.
      defmodule DemiForge do
        def list_org_repos("bonne", _opts), do: {:ok, [%{"full_name" => "bonne/p"}]}
        def list_org_repos("cassee", _opts), do: {:error, :boom}
        def list_open_issues(_r, _o), do: {:ok, []}
        def list_open_pulls(_r, _o), do: {:ok, []}
      end

      {:ok, pid} =
        Poller.start_link(
          orgs: ["bonne", "cassee"],
          human: "h",
          interval_ms: 60_000,
          forge_client: DemiForge,
          loader: fn -> %{} end
        )

      send(pid, :poll)
      stats = Poller.stats(pid)
      assert stats.err_streak >= 1, "une org illisible doit compter comme un echec de tick"
      assert stats.orgs == ["bonne", "cassee"]
    end

    # HTTP 404 is treated as absent, so other organisations remain serviceable.
    # This differs from an unreadable organisation that may conceal work.
    defmodule ForgeSansWeb do
      def list_org_repos("fleet", _opts), do: {:ok, ["fleet/p"]}
      def list_org_repos("web", _opts), do: {:error, {:http, 404, %{"message" => "GetOrgByName"}}}
      def list_open_issues(_r, _o), do: {:ok, []}
      def list_open_pulls(_r, _o), do: {:ok, []}
    end

    defp poller_sans_web do
      Poller.start_link(
        orgs: ["fleet", "web"],
        human: "h",
        interval_ms: 60_000,
        forge_client: ForgeSansWeb,
        loader: fn -> %{} end
      )
    end

    test "une org ABSENTE (404) est retiree et la passe REUSSIT — l'org saine n'est pas emportee" do
      {:ok, pid} = poller_sans_web()

      _ =
        ExUnit.CaptureLog.capture_log(fn ->
          send(pid, :poll)
          Poller.stats(pid)
        end)

      stats = Poller.stats(pid)

      # Check that the pass advanced, rather than merely retaining an initial zero streak.
      assert stats.poll_count == 1, "la passe doit aller au bout malgre l'org absente"
      assert stats.err_streak == 0, "une org absente n'est pas un echec de tick"
      assert stats.error_count == 0
    end

    test "l'absence est dite UNE FOIS, pas a chaque tick" do
      {:ok, pid} = poller_sans_web()

      premier =
        ExUnit.CaptureLog.capture_log(fn ->
          send(pid, :poll)
          Poller.stats(pid)
        end)

      second =
        ExUnit.CaptureLog.capture_log(fn ->
          send(pid, :poll)
          Poller.stats(pid)
        end)

      assert premier =~ "does NOT exist on the forge"

      assert premier =~ "lcars catalogue install web",
             "le refus doit nommer le geste qui le leve"

      refute second =~ "does NOT exist on the forge",
             "repeter la phrase a chaque tick la rend invisible aussi surement que se taire"
    end

    test "F-037: DISCOVERY failure (list_org_repos) → backoff (err_streak + error_count +1)" do
      # Discovery failure increments the streak; outer poll crashes do so too.
      name = :"P_discover_err_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_discover: {:error, {:http, 503, "down"}}],
          spawner: StepStubSpawner
        )

      assert %{dispatched: 0, skipped: 0, errors: 1} = Poller.force_poll(name)
      assert %{err_streak: 1, error_count: 1} = Poller.stats(name)

      GenServer.stop(pid)
    end

    test "F-037: multi-repo discovery → EACH repo scanned, tally aggregated over all" do
      # Aggregate both discovered repositories' tallies.
      issue =
        PayloadFixture.issue(number: 1, body: "x", label_names: [], assignee_logins: ["lordzurp"])

      name = :"P_multi_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [
            _test_repos: ["lordzurp/proj-a", "lordzurp/proj-b"],
            _test_issues: {:ok, [issue]}
          ],
          loader: StepStubLoader,
          spawner: StepStubSpawner
        )

      assert %{dispatched: 0, skipped: 2, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "ROUTED issue (route-comment) + assignee → starts → dispatches the step's role (workflow_map_role)" do
      # Seed qa-build/build through scoped labels; despite the historical title,
      # this case does not use a route comment.
      issues = [
        PayloadFixture.issue(
          number: 10,
          body: "neuf",
          label_names: [],
          assignee_logins: ["lordzurp"]
        )
      ]

      name = :"P_routed_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          # This direct setup projects route labels instead of using the shared harness.
          forge_opts: [
            _test_issues:
              {:ok,
               Enum.map(issues, fn
                 %{"number" => 10} = i ->
                   Map.put(
                     i,
                     "labels",
                     (i["labels"] || []) ++
                       [
                         %{"name" => "wfmap/qa-build"},
                         %{"name" => "stage/build"}
                       ]
                   )

                 i ->
                   i
               end)}
          ],
          loader: StepStubLoader,
          workflow_map_loader: StepStubWorkflowMapLoader,
          spawner: StepStubSpawner
        )

      # tally = the contract at the Poller level (the spawn goes to the GenServer's mailbox, not
      # the test's; the role dispatched by workflow_map_role is unit-tested in
      # step_dispatcher_test).
      assert %{dispatched: 1, skipped: 0, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end
  end

  describe "webhook kick — a hint arms no second tick chain" do
    # Slow discovery makes the poll longer than the nominal configured interval.
    # Delegate other stub functions automatically to avoid an incomplete mirror.
    defmodule SlowForge do
      @slow_ms 60

      def list_org_repos(org, opts) do
        send(Keyword.get(opts, :_test_pid, self()), :poll_started)
        Process.sleep(@slow_ms)
        StepStubForge.list_org_repos(org, opts)
      end

      for {fun, arity} <- StepStubForge.__info__(:functions), fun != :list_org_repos do
        args = Macro.generate_arguments(arity, __MODULE__)

        def unquote(fun)(unquote_splicing(args)),
          do: StepStubForge.unquote(fun)(unquote_splicing(args))
      end
    end

    test "a webhook hint NEVER arms a second tick chain (R3 parallel-chain, BL-6-44)" do
      # A webhook must not start a recurring tick chain. Timer-before-work versus
      # timer-after-work changes cadence, but does not itself create another chain;
      # mailbox size was therefore the wrong assertion.
      parent = self()

      {_name, pid} =
        start_entry_poller({:ok, []}, %{},
          start_tick?: false,
          interval_ms: 30,
          forge_client: SlowForge,
          forge_opts: [_test_issues: {:ok, []}, _test_routes: %{}, _test_pid: parent]
        )

      # `start_tick?: false` → NO chain running. The hint is the only thing that can poll.
      send(pid, %Fleet.Event{
        type: :"gitea.issues",
        source: :event_router,
        timestamp: DateTime.utc_now(),
        payload: %{}
      })

      # The debounced kick polls ONCE (1 s coalescence window + the slow poll).
      assert_receive :poll_started, 3_000

      # Backoff clamps delays to at least one second even with interval_ms: 30.
      # Wait beyond that floor to detect an accidental recurring chain.
      refute_receive :poll_started, 2_500

      GenServer.stop(pid)
    end
  end

  describe "step mode — max_fan (serial IS this ceiling at 1)" do
    # Set max_fan to 1 explicitly: the default fan-out does not serialize tickets.
    setup do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 1)
      :ok
    end

    test "an ENGAGED pipeline (advanced route) holds the lease and blocks a QUEUED issue" do
      # An advanced route holds a lease while continuing its current step;
      # a queued first step must wait under max_fan 1.
      issues = [
        PayloadFixture.issue(
          number: 11,
          body: "en cours",
          label_names: [],
          assignee_logins: ["lordzurp"]
        ),
        PayloadFixture.issue(
          number: 12,
          body: "en file",
          label_names: [],
          assignee_logins: ["lordzurp"]
        )
      ]

      {name, pid} =
        start_entry_poller({:ok, issues}, %{11 => {"qa-2", "deploy"}, 12 => {"qa-build", "build"}})

      assert %{dispatched: 1, skipped: 1, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "two QUEUED issues -> only one starts, the other waits (lease taken within the tick)" do
      issues = [
        PayloadFixture.issue(
          number: 13,
          body: "file1",
          label_names: [],
          assignee_logins: ["lordzurp"]
        ),
        PayloadFixture.issue(
          number: 14,
          body: "file2",
          label_names: [],
          assignee_logins: ["lordzurp"]
        )
      ]

      {name, pid} =
        start_entry_poller({:ok, issues}, %{
          13 => {"qa-build", "build"},
          14 => {"qa-build", "build"}
        })

      assert %{dispatched: 1, skipped: 1, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "a ticket in its JURY phase HOLDS the lease — a QUEUED one does not start beside it" do
      # A ticket in jury still occupies a workflow-run lease even though the PR path
      # now advances it. Otherwise serial admission could start a second ticket.
      issues = [
        # #21 is in its jury phase: an open fleet PR carries it. Skipped on the issues rail (the
        # pulls rail advances it), but it IS in flight.
        PayloadFixture.issue(
          number: 21,
          body: "en jury",
          label_names: [],
          assignee_logins: ["lordzurp"]
        ),
        # #22 is QUEUED and routeless: with a free lease it would start.
        PayloadFixture.issue(
          number: 22,
          body: "en attente",
          label_names: [],
          assignee_logins: ["lordzurp"]
        )
      ]

      pulls = [
        %{
          "number" => 90,
          "head" => %{"ref" => "lcars/issue-21-engineer"},
          "requested_reviewers" => [%{"login" => "reviewer"}]
        }
      ]

      {name, pid} =
        start_entry_poller({:ok, issues}, %{},
          forge_opts: [
            _test_issues: {:ok, issues},
            _test_pulls: {:ok, pulls},
            _test_pid: self()
          ]
        )

      # #21 skipped on the issues rail (its PR advances it), #22 skipped because the lease is HELD.
      # Before the repair #22 dispatched — a second workflow_run under a serialized lease.
      tally = Poller.force_poll(name)
      assert tally.skipped >= 2
      assert tally.errors == 0

      GenServer.stop(pid)
    end

    test "free lease (no engaged pipeline) -> the QUEUED issue starts" do
      issues = [
        PayloadFixture.issue(
          number: 15,
          body: "file",
          label_names: [],
          assignee_logins: ["lordzurp"]
        )
      ]

      {name, pid} = start_entry_poller({:ok, issues}, %{15 => {"qa-build", "build"}})

      assert %{dispatched: 1, skipped: 0, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "failed wake on the 1st issue TAKES the lease intra-tick → the 2nd does NOT start (a single pipeline)" do
      # Wake happens after lock, pod and enqueue. Failure still occupies the lease,
      # so another queued issue cannot start. Count it as an item error, not backoff.
      issues = [
        PayloadFixture.issue(
          number: 16,
          body: "file1",
          label_names: [],
          assignee_logins: ["lordzurp"]
        ),
        PayloadFixture.issue(
          number: 17,
          body: "file2",
          label_names: [],
          assignee_logins: ["lordzurp"]
        )
      ]

      {name, pid} =
        start_entry_poller(
          {:ok, issues},
          %{16 => {"qa-build", "build"}, 17 => {"qa-build", "build"}},
          wake_recovery: &FailingWakeRecovery.wake/3
        )

      # One started-but-unwoken run plus one blocked entry gives one error and one skip.
      assert %{dispatched: 0, skipped: 1, errors: 1} = Poller.force_poll(name)

      # Wake failure remains visible in last_tally_errors.
      assert %{last_tally_errors: 1} = Poller.stats(name)

      GenServer.stop(pid)
    end

    test "routed-advanced pipeline with NIL workflow_map holds the lease (a transient workflow_map failure does not release the lease)" do
      # A failed workflow lookup must not release an advanced route's lease.
      # Otherwise the queued sibling could start alongside already-engaged work.
      issues = [
        PayloadFixture.issue(
          number: 18,
          body: "avance",
          label_names: [],
          assignee_logins: ["lordzurp"]
        ),
        PayloadFixture.issue(
          number: 19,
          body: "file",
          label_names: [],
          assignee_logins: ["lordzurp"]
        )
      ]

      {name, pid} =
        start_entry_poller(
          {:ok, issues},
          %{18 => {"qa-2", "deploy"}, 19 => {"qa-build", "build"}},
          workflow_map_loader: NilWorkflowMapForQa2Loader
        )

      # The advanced issue reports a dispatch error while retaining its lease;
      # the queued sibling is skipped.
      assert %{dispatched: 0, skipped: 1, errors: 1} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    # Route classification now reads listed labels without network I/O, so a
    # transient get_route failure is outside this path. Workflow-load failure
    # remains covered above; callers of network get_route need their own tests.
  end

  # ============================================================
  # PR-driven path: the judges are dispatched via the requested_reviewers.
  # ============================================================
  describe "step mode — PR-driven judge dispatch" do
    # Forward the issue's wait label to the PR path without another read.
    test "chemin PR : une issue qui AWAITS-ARCH ne patiente plus — son wait/* est RETIRE" do
      # This fixture has wait/role but no awaits-arch label, despite the title.
      # It checks the target of wait-label removal, not an awaits-arch transition.
      issues = [
        PayloadFixture.issue(
          number: 21,
          body: "x",
          label_names: ["wait/role"],
          assignee_logins: ["lordzurp"]
        )
      ]

      pulls = [
        %{
          "number" => 90,
          "head" => %{"ref" => "lcars/issue-21-engineer"},
          "requested_reviewers" => [%{"login" => "reviewer"}]
        }
      ]

      {name, _pid} =
        start_entry_poller({:ok, issues}, %{},
          forge_opts: [
            _test_issues: {:ok, issues},
            _test_pulls: {:ok, pulls},
            _test_pid: self(),
            _test_route: {:ok, {"g", "build"}}
          ]
        )

      Poller.force_poll(name)

      # Le retrait porte sur l'ISSUE (21), jamais sur la PR (90) : le ticket est ce qu'un humain lit,
      # il survit a ses PR successives.
      assert_received {:remove_label, 21, "wait/role"}
      refute_received {:remove_label, 90, _}
    end

    test "chemin PR : une PR ETRANGERE n'ecrit rien — ce n'est pas notre ticket" do
      pulls = [PayloadFixture.pull(number: 91, head_ref: "refs/pull/6/head")]

      {name, _pid} =
        start_entry_poller({:ok, []}, %{},
          forge_opts: [
            _test_issues: {:ok, []},
            _test_pulls: {:ok, pulls},
            _test_pid: self()
          ]
        )

      Poller.force_poll(name)

      # An unrecognized branch has no parent issue for wait-label writes.
      refute_received {:add_label, _, _}
      refute_received {:remove_label, _, _}
    end

    test "PR with review requested -> judge dispatched (pulls path)" do
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

    test "issue with an open fleet PR -> producer SKIPPED on the issue side (no re-spawn)" do
      # An open fleet PR keeps its issue off producer dispatch while its judge runs.
      issues = [
        PayloadFixture.issue(
          number: 99,
          body: "x",
          label_names: [],
          assignee_logins: ["lordzurp"]
        )
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

      # issue #99 skip (PR open) + reviewer judge dispatched (pull) = {dispatched:1, skipped:1}
      assert %{dispatched: 1, skipped: 1, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    test "PR without a requested judge -> ADOPTION (the system sets the judges → dispatched)" do
      # This fixture exercises adoption and its tally; it does not establish why
      # the requested-reviewer list became empty.
      pulls = [
        %{
          "number" => 8,
          "head" => %{"ref" => "lcars/issue-42-engineer"},
          "requested_reviewers" => [],
          "labels" => []
        }
      ]

      {name, pid} = start_step_poller({:ok, []}, {:ok, pulls})

      # dispatched: 1 = the PR was adopted (`{:ok, {:adopted, ...}}`). The request_review CALL
      # itself is proven at unit level (StepDispatcherTest); here we verify the poller tally
      # (adoption = one dispatch).
      assert %{dispatched: 1, skipped: 0, errors: 0} = Poller.force_poll(name)

      GenServer.stop(pid)
    end
  end

  # ============================================================
  # MA-02 — REPO-QUALIFIED lock refs (cross-repo collision)
  # ============================================================

  describe "MA-02 — multi-repo reconciliation (repo-qualified lock key)" do
    # Multi-repo forge: each repo has ITS issue list (`_test_issues_by_repo`). `remove_label`
    # carries the REPO (to distinguish repoA#8 from repoB#8 — SAME number). The rest = StepStubForge.
    defmodule MultiRepoForge do
      def list_org_repos(_org, opts),
        do: {:ok, Keyword.get(opts, :_test_repos, [])}

      def list_open_issues(repo, opts) do
        Map.get(Keyword.get(opts, :_test_issues_by_repo, %{}), repo, {:ok, []})
      end

      def list_open_pulls(_repo, _opts), do: {:ok, []}
      def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
      def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
      def start_stopwatch(_repo, _n, _opts), do: :ok
      def stop_stopwatch(_repo, _n, _opts), do: :ok
      def count_change_request_rounds(_repo, _index, _opts), do: {:ok, 0}
      def get_route(_repo, _n, _opts), do: :none
      def get_predecessor_result(_repo, _n, _opts), do: :none
      def get_issue(_repo, n, _opts), do: {:ok, %{"number" => n, "body" => "x"}}
      def pr_review_state(_repo, _index, _opts), do: {:ok, %{verdicts: %{}, reviewers: []}}

      # Adoption: sets judges on an orphan PR (human/fork, or an agent that lost its reviewers).
      def request_review(_repo, index, reviewers, _opts) do
        send(self(), {:requested_review, index, reviewers})
        :ok
      end

      def post_route(_repo, _n, _p, _s, _opts), do: {:ok, :posted}

      def remove_label(repo, n, label, opts) do
        send(Keyword.get(opts, :_test_pid, self()), {:remove_label, repo, n, label})
        {:ok, :removed}
      end
    end

    # A single live pod: `repoB#8` (repo-scoped pod_id for repoB). repoA has NO pod.
    defmodule RepoBPodSpawner do
      def spawn_pod(_profile, _issue_id, _opts), do: {:ok, self()}
      def list_pods, do: [%{pod_id: "owner-repoB-issue-8-engineer"}]
    end

    defmodule ActiveTaskQueue2 do
      def pod_status(_pod_id), do: {:ok, :assigned}
    end

    test "a live pod #8/repoB does NOT mask orphan #8/repoA (reclaimed) AND does NOT get #8/repoB reclaimed" do
      # The same number in another repository must neither mask an orphan nor
      # authorize reclaiming its live neighbor. Preserve repository-qualified keys.
      issue8 = fn ->
        PayloadFixture.issue(number: 8, body: "x", label_names: ["lcars-in-flight"])
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
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: MultiRepoForge,
          forge_opts: [
            _test_repos: ["owner/repoA", "owner/repoB"],
            _test_issues_by_repo: issues_by_repo,
            _test_pid: self()
          ],
          loader: StepStubLoader,
          spawner: RepoBPodSpawner,
          task_queue: ActiveTaskQueue2
        )

      # First observation seeds grace; no lock should be removed yet.
      Poller.force_poll(name)
      refute_received {:remove_label, _, 8, _}

      # 2nd consecutive tick: orphan CONFIRMED → ONLY repoA#8 is reclaimed. repoB#8 NEVER (live pod).
      Poller.force_poll(name)
      assert_received {:remove_label, "owner/repoA", 8, "lcars-in-flight"}
      refute_received {:remove_label, "owner/repoB", 8, _}

      GenServer.stop(pid)
    end
  end

  # ============================================================
  # MA-01 (bug B) — dispatch_review skips on the ISSUE's awaits-arch (poller-level)
  # ============================================================

  describe "MA-01 (bug B) — poller threads awaits_arch_ids to the pulls" do
    test "issue 42 awaits-arch + PR head lcars/issue-42-engineer with reviewer -> judge NOT dispatched (skip)" do
      # Issue awaits-arch must reach PR dispatch even when the PR's own labels lack it.
      issues = [
        PayloadFixture.issue(
          number: 42,
          body: "x",
          label_names: ["lcars-awaits-arch"],
          assignee_logins: ["lordzurp"]
        )
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

      # issue 42 skip (awaits-arch, decide) + PR 7 skip (threaded awaits_arch) → dispatched:0.
      assert %{dispatched: 0, errors: 0} = Poller.force_poll(name)
      refute_received {:spawned, _, _}

      GenServer.stop(pid)
    end
  end

  describe "main-protection recheck — only what was reconciled is stamped" do
    test "the tick reconciles each repo's main protection ONCE per period (desired-state, throttled)" do
      parent = self()

      {name, _pid} =
        start_entry_poller({:ok, []}, %{},
          protection_reconciler: fn repo, _opts ->
            send(parent, {:protection_reconciled, repo})
            :ok
          end
        )

      Poller.force_poll(name)
      Poller.force_poll(name)

      # The second immediate tick must not repeat a successful protection check.
      assert_received {:protection_reconciled, repo}
      refute_received {:protection_reconciled, ^repo}

      # Stamped BECAUSE reconciled — the failure twin (« only what was reconciled is stamped »)
      # proves the other half.
      assert Map.has_key?(:sys.get_state(Process.whereis(name)).protection_rechecked, repo)
    end

    defp protection_poller(reconciler) do
      name = :"P_prot_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, []}],
          spawner: StepStubSpawner,
          protection_reconciler: reconciler
        )

      {name, pid}
    end

    test "a reconcile that FAILS is not stamped: the next tick retries it" do
      test = self()

      {name, pid} =
        protection_poller(fn repo, _opts ->
          send(test, {:reconcile, repo})
          {:error, :forge_unreadable}
        end)

      _ = Poller.force_poll(name)
      _ = Poller.force_poll(name)

      assert_received {:reconcile, "lordzurp/lcars-test"}
      assert_received {:reconcile, "lordzurp/lcars-test"}
      assert :sys.get_state(pid).protection_rechecked == %{}

      GenServer.stop(pid)
    end
  end

  describe "an org that comes BACK on the forge is said, once, and discovery resumes" do
    # The forge's answer for `web` is a switch the test flips between two ticks.
    defmodule ForgeWebSwitch do
      def list_org_repos("fleet", _opts), do: {:ok, ["fleet/p"]}

      def list_org_repos("web", _opts) do
        case Application.get_env(:lcars_fleet, :_test_web_org) do
          :present -> {:ok, ["web/q"]}
          _ -> {:error, {:http, 404, %{"message" => "GetOrgByName"}}}
        end
      end

      def list_open_issues(repo, _o) do
        if pid = Application.get_env(:lcars_fleet, :_test_web_pid),
          do: send(pid, {:scanned, repo})

        {:ok, []}
      end

      def list_open_pulls(_r, _o), do: {:ok, []}
    end

    test "absent then present: the return is logged and the org's repos are scanned again" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :_test_web_org, :absent)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :_test_web_pid, self())

      {:ok, pid} =
        Poller.start_link(
          name: :"P_orgback_#{System.unique_integer([:positive])}",
          orgs: ["fleet", "web"],
          human: "h",
          interval_ms: 60_000,
          forge_client: ForgeWebSwitch,
          loader: fn -> %{} end
        )

      # The linked poller may already be gone when on_exit runs. Stop directly and
      # tolerate exits; an alive? check would leave a check/stop race.
      on_exit(fn ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      gone =
        ExUnit.CaptureLog.capture_log(fn ->
          send(pid, :poll)
          Poller.stats(pid)
        end)

      assert gone =~ "does NOT exist on the forge"
      refute_received {:scanned, "web/q"}

      Application.put_env(:lcars_fleet, :_test_web_org, :present)

      back =
        ExUnit.CaptureLog.capture_log(fn ->
          send(pid, :poll)
          Poller.stats(pid)
        end)

      assert back =~ "now exists on the forge"
      assert back =~ "discovery resumes"
      assert_received {:scanned, "web/q"}

      again =
        ExUnit.CaptureLog.capture_log(fn ->
          send(pid, :poll)
          Poller.stats(pid)
        end)

      refute again =~ "now exists on the forge", "a return is said once, like an absence"

      GenServer.stop(pid)
    end
  end

  describe "resolve_orgs — the four ways the poller learns which orgs to scan" do
    defmodule QuietForge do
      def list_org_repos(_org, _opts), do: {:ok, []}
      def list_open_issues(_r, _o), do: {:ok, []}
      def list_open_pulls(_r, _o), do: {:ok, []}
    end

    defp orgs_of(opts) do
      {:ok, pid} =
        Poller.start_link(
          [
            name: :"P_orgs_#{System.unique_integer([:positive])}",
            human: "h",
            interval_ms: 60_000,
            forge_client: QuietForge,
            loader: fn -> %{} end
          ] ++ opts
        )

      orgs = Poller.stats(pid).orgs
      GenServer.stop(pid)
      orgs
    end

    test "`:orgs` (the form) wins" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_fleet_org, "envorg")
      assert orgs_of(orgs: ["a", "b"], org: "solo") == ["a", "b"]
    end

    test "`:org` (a singleton) next" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_fleet_org, "envorg")
      assert orgs_of(org: "solo") == ["solo"]
    end

    test "then the config knob `:pilot_fleet_org`" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_fleet_org, "envorg")
      assert orgs_of([]) == ["envorg"]
    end

    test "else the installed catalogues — the org IS the catalogue's name" do
      Fleet.TestEnv.restore_env_on_exit(:lcars_fleet, :pilot_fleet_org)
      Application.delete_env(:lcars_fleet, :pilot_fleet_org)
      orgs = orgs_of([])
      assert orgs == Fleet.Catalogue.installed_names()
      refute orgs == [], "a catalogue whose manifest lost its name would empty BOTH sides"
    end
  end
end
