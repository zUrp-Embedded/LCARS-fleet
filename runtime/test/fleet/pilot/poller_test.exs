defmodule Fleet.Pilot.PollerTest do
  use ExUnit.Case, async: false

  # SYNC on purpose: a describe here flips the GLOBAL `:lcars_fleet, :pilot_require_onboarded`, which
  # every dispatch path reads. Async peers running in that window were refused with
  # `{:work_dir_missing, _}` — a flake that fires by timing, not by order, so a seed does not
  # reproduce it. The restore-on-exit is correct and was never the problem: the value is right
  # after the test, and wrong DURING it for everyone else.

  alias Fleet.Forge.PayloadFixture
  alias Fleet.Pilot.Poller

  # Legacy rail (poll_once/4 → Routing → Dispatcher → RAM Executor) REMOVED (②.3 / BL-050). Its
  # tests (`describe "poll_once/4"`, `StubForge`/`StubInvoker` stubs) left with it. Only step mode
  # remains below (+ the GenServer lifecycle, shared).

  # G6: workflow_map_loader that RAISES (map removed/renamed from the catalog) →
  # load_workflow_map_or_nil rescues.

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

      # Issue #42 routed BEYOND the 1st step ("deploy") → classify_issue loads the "ghostmap"
      # workflow_map → the loader RAISES (map removed from the catalog). `start_entry_poller` =
      # proven harness (discovery + repo admission OK); we inject the raising loader + a stub
      # incident_fun.
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

      # A missing map with the issue ENGAGED (lease held) would block the repo FOREVER with no
      # signal. Instead: the load failure ESCALATES (IncidentRegistry dedup → note then sysadmin
      # issue).
      assert_received {:incident, "workflow_map_load", "ghostmap",
                       {:workflow_map_load_failed, _msg}}

      GenServer.stop(pid)
    end
  end

  # task_queue stubs for the arch-offer tests: implement the 4 reads the poll tick does
  # (reconciliation `list_active`/`pod_active_issue_id`/`pod_status` + my arch-offer
  # `pod_status`/`enqueue`) → avoid touching the REAL broker in test. The arch's `pod_status` =
  # the "free vs busy" lever.
  #
  # ⚠ ET `enqueue/2` ANNONCE SON APPEL. Ces doublures etaient MUETTES, donc les temoins ci-dessous
  # ne pouvaient juger que le LOG : « le mandat a ete mis en file » etait prouve par la phrase qui
  # le dit, pas par la mise en file. Mutation jouee le 2026-09-07 — sauter `enqueue_mandate` en
  # gardant le log laissait le temoin FREE vert, et l'ajouter dans la branche BUSY laissait le
  # temoin BUSY vert. Un stub qui se tait ne peut pas etre pris en flagrant delit.
  #
  # Le pid du test voyage par l'env applicatif (`:_test_arch_pid`), comme `:_test_web_pid` le fait
  # deja : la doublure est appelee DANS le process du Poller, donc `self()` n'y est pas le test.
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
    # Design 2026-07-19: the net fires on the FIRST eligible tick (nil = never kicked) and
    # then caps itself by a cooldown SINCE THE LAST SENT KICK — never a sampling grid (a grid
    # made even a fresh escalation draw a 0-5 min latency lottery).
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
      # False-green regression: in prod the :spawner seam is NOT injected (nil), and an old
      # `when not is_nil(spawner)` guard made maybe_rekick_arch fall into a MUTE no-op → the
      # anti-"awaits-arch issue stuck forever" rail NEVER ran. This test exercises the nil path
      # (= prod) that the other setups (spawner: StepStubSpawner) do not cover.
      issue =
        PayloadFixture.issue(
          number: 42,
          body: "x",
          label_names: ["lcars-awaits-arch"],
          assignee_logins: ["lordzurp"]
        )

      # FREE arch (busy → deliberate silence since the offer-then-wake coupling): the wiring
      # under test is the nil-spawner path, exercised on the path that still wakes.
      {name, pid} = start_entry_poller({:ok, [issue]}, %{}, spawner: nil, task_queue: ArchFreeTQ)

      # Cooldown semantics: the net fires on the FIRST tick (last_arch_rekick_at nil).
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..2, do: Poller.force_poll(name)
        end)

      # nil spawner → the re-kick uses the REAL Fleet.Spawner: wake_pod(arch) on an unspawned arch
      # returns {:error, :not_found}, the tick does not crash, and ArchWake logs the UNREACHED
      # warning. No signal left → NO cooldown is armed (arming one would delay the retry for nothing).
      assert log =~ "ArchWake: [net]"
      assert log =~ "UNREACHED"
      refute log =~ "cooldown"

      GenServer.stop(pid)
    end

    # Regression acte4 A-10 — the re-kick lived INSIDE the per-repo loop with a loop-invariant
    # poll_count: R repos in awaits-arch = R wakes of the SAME arch (single pod) within the same
    # throttle tick, + R lines each claiming "throttle". The hoist into do_poll (cross-repo union,
    # decision ONCE) makes the trace honest. This case was NOT covered (the wiring test only
    # exercises ONE repo → the multiplication was invisible).
    # JG-067 — UN DEPOT QUI LEVE EMPORTAIT TOUS CEUX QUI LE SUIVAIENT. `safe_poll/2` capture bien,
    # mais AU-DESSUS du fold des depots : les depots situes apres celui qui a leve n'etaient pas
    # traites du tout pendant ce cycle. Et la cause est deterministe — le meme PR, le meme fichier,
    # le meme conflit pathologique — donc elle se represente a chaque tick : un seul depot malade
    # privait de service tous ceux qui le suivaient dans l'ordre d'iteration, indefiniment.
    #
    # Le filet descend d'un cran, par depot. Il ne remplace pas celui du dessus : une levee HORS du
    # fold reste un echec de tick avec son `err_streak` et son repli.
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

      # `forge_opts` replaced wholesale (Keyword.merge): same stub issues + 2-repo discovery.
      # The default spawner (StepStubSpawner.wake_pod → :ok) is kept — its wake REACHES, so the
      # re-kick fires and arms the fleet-global cooldown, which is what caps the 10 polls below to
      # ONE net line. (A nil/real spawner would fail wake_pod on the unspawned arch →
      # :wake_unreached → no cooldown → the throttle under test would never engage.)
      {name, pid} =
        start_entry_poller({:ok, [issue]}, %{},
          task_queue: ArchFreeTQ,
          forge_opts: [
            _test_issues: {:ok, [issue]},
            _test_routes: %{},
            _test_repos: ["fleet/repo-a", "fleet/repo-b"]
          ]
        )

      # 10 polls: the 1st fires (nil stamp), the cooldown blocks the other 9 → EXACTLY 1
      # fleet-global net line (the per-repo regression would have produced 2 on the 1st tick).
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

    # Serialize-via-forge: the arch is a context-long/unique worker (like the eng) → the forge is
    # its queue. If the arch is FREE, the poller ENQUEUES the arbitration mandate to it
    # (get_work_item stops returning {done:true} — probe #4).
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

      # LE MANDAT EST MIS EN FILE, pas seulement annonce. Sauter `enqueue_mandate` en gardant le
      # log laissait ce temoin vert (mutation jouee le 2026-09-07) : le log disait le geste, rien
      # ne le mesurait.
      assert_received {:arch_enqueue, _pod_id, _attrs}
      assert log =~ "mandate lordzurp/lcars-test#42 enqueued (arch was free)"

      GenServer.stop(pid)
    end

    # NEW state (2026-07-19): a PENDING mandate (offered but never fetched — the immediate
    # kick's wake was lost) → the net RE-WAKES without re-offering (re-enqueue would churn the
    # pending item). Closes the lost-wake liveness hole: pending no longer silences the net.
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

      # « no new enqueue » se mesure sur la FILE, pas sur l'absence d'une phrase : une mise en file
      # silencieuse aurait laisse les deux `refute` de log verts.
      refute_received {:arch_enqueue, _, _}
      assert log =~ "pending mandate never fetched → re-wake only"
      refute log =~ "enqueued (arch was free)"

      GenServer.stop(pid)
    end

    # Symmetric: the arch BUSY (an active work-item) serializes via the forge — NO new enqueue
    # AND NO wake (a busy arch already knows its mandate; re-waking it every throttle tick was
    # pure noise, observed live 2026-07-18). The backlog stays on the forge, re-offered + woken
    # next tick once the arch submits and the label drains.
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

      # « NO enqueue » est la moitie du nom, et elle n'etait tenue par rien : ajouter un
      # `enqueue_mandate` dans la branche BUSY laissait ce temoin vert, les deux `refute` ne
      # portant que sur des lignes de log que cette branche n'ecrit pas.
      refute_received {:arch_enqueue, _, _}

      # Bleed-proof (`capture_log` is GLOBAL — it catches a CONCURRENT test's ArchWake on ANOTHER repo):
      # scope to an ArchWake line naming THIS test's repo (`lcars-test`), not the bare shared token. A real
      # regression (this busy arch wrongly woken) logs `ArchWake … lcars-test`; another repo's net does not.
      refute log =~ ~r/ArchWake.*lcars-test/
      refute log =~ "(fleet-wide) → net"

      GenServer.stop(pid)
    end
  end

  describe "GenServer init / lifecycle" do
    test "F-037: init WITHOUT :repo succeeds (topic discovery, no fixed repo required anymore)" do
      # The poller no longer scans a hardcoded repo — it DISCOVERS its projects by topic. `:repo`
      # is therefore no longer required; the `my_human` scoping is (via :human here, otherwise
      # `Human.current!()`).
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

  # Forge stub for step mode: list (filter already applied on the real API side, here we return
  # as-is) + the write-ops touched by StepDispatcher.dispatch_issue (add_label / post_comment).

  describe "architect keeper — `forever` has to be someone's job" do
    # The arch was ensured on project-open and before an escalation wake, both EVENTS. A fleet
    # restart between them left the project with no arbiter and nothing said so — and the human,
    # who cannot be scheduled around, is exactly who finds an empty terminal in that window.
    test "a regular tick keeps the architect of a LIVE project" do
      issues = [PayloadFixture.issue(number: 7, body: "x", label_names: [], assignee_login: "l")]
      me = self()
      {name, _pid} = start_keeper_poller(issues, fn repo, _o -> send(me, {:kept, repo}) end)

      Poller.force_poll(name)
      assert_receive {:kept, "lordzurp/lcars-test"}, 1_000
    end

    test "a PARKED project gets NO architect — a stopped fleet needs no arbiter" do
      # And the site is chosen for it: here the marker has just been read in the listing this pass
      # already made, so the fact costs nothing. Any earlier site would have to buy it with a call.
      # Title built from the PROTOCOL's own prefix, never re-typed: a hand-copied marker still
      # parks in this test the day the prefix moves, and the test would keep passing on a fleet
      # that no longer parks at all.
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
    # The gate is OFF in the hermetic baseline (`config/test.exs`): the suite drives fictional
    # repos that exist nowhere on disk. Here it is turned back ON, which is the only way this
    # behaviour is pinned rather than assumed.
    setup do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_require_onboarded, true)
      :ok
    end

    # JG-059 — LE SUBSTRAT EST DECLARE PRESENT, et ce n'est pas une commodite de test. Ces cas
    # pinent le garde PAR DEPOT (« ce projet-la n'est pas onboarde »), pas la disparition de la
    # racine (« le sol a disparu, tous les depots sautent »). Les deux rendaient la meme phrase
    # avant JG-059 ; les separer exige de dire lequel des deux on exerce. La racine `ops` est un
    # LITTERAL de `Fleet.Layout` — un fait, une source — donc un test ne peut pas la deplacer et ne
    # doit pas ecrire dans `/home` : le seam est la seule facon de le dire.
    defp substrate_present, do: [substrate_present_fun: fn -> true end]

    test "a repo with no project directory is SKIPPED — and costs not one forge call" do
      # The check is local and runs BEFORE the listing, so an unserved repo also stops paying two
      # API calls per tick. Asserting the ABSENCE of the forge call is what pins the ORDER;
      # asserting only "no spawn" would pass with the check placed anywhere downstream.
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
      # THIS TEST USED TO MKDIR INTO `/home/`. It created the project directory under the real
      # `ops_root` so the positive case could go through, then removed it — on whatever machine ran
      # `mix test`. Two things were wrong with that, and only the second is about tidiness.
      #
      # It was a GREEN WITH TWO DIFFERENT CAUSES. On a container the root exists because the entrypoint
      # provisioned it; on a workstation it existed because that machine happened to have one from
      # an older layout. The same line passed for reasons that have nothing to do with each other,
      # and the day the layout was renamed it failed here for a reason that was not a defect — the
      # parent simply is not creatable under `/home` without root. Which is how a rename lured a
      # developer into provisioning the workstation to make a test pass.
      #
      # And the runtime NEVER runs on this machine. Nothing here serves a pod, so a test that needs
      # the real filesystem to be a runtime's filesystem is not measuring the runtime — it is
      # measuring the history of whoever's disk it landed on. That belongs on the bench.
      #
      # What stays here is the half that is genuinely hermetic: the gate's path is COMPOSED from
      # the layout authority, not hardcoded and not stubbed. `Fleet.Layout` is a compile-time
      # constant, so asserting the composition proves the same thing the mkdir was reaching for,
      # without a single write outside the repo.
      assert Path.join(Fleet.Layout.ops_root(), Fleet.Layout.project_name("lordzurp/lcars-test")) ==
               Path.join(Fleet.Layout.ops_root(), "lcars-test")

      assert String.starts_with?(Fleet.Layout.ops_root(), "/home/projects")
    end

    # JG-059 — « JAMAIS ONBOARDE » ET « LE SOL A DISPARU » RENDAIENT LA MEME PHRASE. Un projet absent
    # sous une racine PRESENTE est un fait ordinaire, qu'un humain resoudra. La RACINE elle-meme
    # absente — un montage tombe, une permission perdue — saute le rail d'etapes pour TOUS les
    # depots : la flotte tourne a vide, les cycles se succedent, la telemetrie rapporte des comptes
    # nuls, et rien ne distingue « aucun travail a faire » de « le substrat n'est plus la ».
    # JG-060 — LE JUMEAU ETAIT EFFACE, CELUI-CI NON. `:parked_logged` est supprime des qu'un depot
    # sort du parking ; `:not_onboarded_logged` ne l'etait NULLE PART. Une memoire d'affichage — « ne
    # crie qu'une fois » — devenait donc une memoire DEFINITIVE : un depot qui repassait en « non
    # onboarde » apres en etre sorti se taisait pour toute la vie du process, et la seconde
    # disparition de son arborescence ne laissait aucune trace.
    #
    # Le scenario de la fiche est « disparaitre, reapparaitre, redisparaitre ». Il se joue ici sur
    # `:pilot_require_onboarded` plutot que sur le systeme de fichiers : la racine est un litteral et
    # un test n'ecrit pas dans `/home`. Le fait exerce est le meme — le depot sort du garde, puis y
    # revient.
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
      # The negative case carries the behaviour: the directory is absent (no test creates it any
      # more), the gate refuses, and it says what to do about it. What is NOT covered here, and is
      # named rather than left to be discovered: the POSITIVE case — an existing directory letting
      # the repo through — is a runtime fact and is proven on the BENCH, where a project is really
      # onboarded and the poller really dispatches.
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

      # #5.2 D2 — nil route → the poller ONBOARDS (records the default brief-gate workflow_map via
      # the Loader) then DEFERS → skip (the next tick sees it routed → dispatch). The routed
      # dispatch is tested in the "recorded route" describe + step_dispatcher_test. At the Poller
      # level, the contract = the tally.
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
      # The multi-user scoping lives in the LISTING (forge-side): the poller passes ITS human to
      # BOTH endpoints (/issues?type=issues AND ?type=pulls). decide/dispatch_review no longer
      # re-verify ownership.
      {name, pid} = start_step_poller({:ok, []}, {:ok, []})

      Poller.force_poll(name)

      assert_received {:scoped, :issues, "lordzurp"}
      assert_received {:scoped, :pulls, "lordzurp"}

      GenServer.stop(pid)
    end

    test "F-037: per-repo LIST error → tally error BUT no backoff (err_streak 0, forge up)" do
      # A repo that lists badly (500) does NOT backoff the whole fleet: the DISCOVERY succeeded
      # (forge up), so err_streak/error_count stay at 0 (reserved for discovery failure). The
      # per-item error lives in the TALLY (errors:1) + `last_tally_errors`.
      {name, pid} = start_step_poller({:error, {:http, 500, "boom"}})

      assert %{dispatched: 0, skipped: 0, errors: 1} = Poller.force_poll(name)
      assert %{err_streak: 0, error_count: 0, last_tally_errors: 1} = Poller.stats(name)

      GenServer.stop(pid)
    end

    test "DECOUVERTE MULTI-ORG : une org illisible fait echouer le tick, jamais une liste partielle" do
      # L'org est le nom du catalogue, il y en a une par catalogue actif, et le poller les balaie
      # TOUTES. Une decouverte partielle ne se distingue pas de « pas de travail » pour les projets
      # de l'org manquante : elle ne casse rien, elle rend muet. D'ou le refus net.
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

    # LE JUMEAU DU TEMOIN CI-DESSUS, et la difference EST le sujet. Une org illisible cache
    # peut-etre des depots ; une org qui n'existe pas n'en porte aucun, donc la retirer ne rend rien
    # muet — la raison du fail-closed ne s'applique pas au 404. Mesure du 2026-08-15 au banc :
    # `enable web` sur une forge sans org `web` faisait tomber `fleet` AVEC lui (dispatch, filet
    # arch et recheck des protections compris), puis le backoff saturait a 300 s pour toujours.
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

      # `poll_count` est la preuve que le CORPS de la passe a tourne : la branche d'erreur ne
      # l'incremente pas. Sans lui, `err_streak == 0` passerait au vert sur une passe qui n'a rien
      # fait — l'assertion mesurerait son propre point de depart.
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
      # The forge is DOWN — the discovery itself fails. This is the ONLY case that backoffs
      # (handle_poll_error).
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
      # Heart of the effort: 2 repos discovered → the poller scans BOTH, tally summed. Routeless
      # assigned issue in each repo → onboarded then deferred (skip) ⇒ skipped:2 (1 per repo).
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
      # #8 coherence: the routing comes from the ROUTE-COMMENT (recorded by create_issue), no
      # longer the label. #10 routed qa-build:build (1st step = queued), human-assigned, free
      # lease → STARTS → the poller dispatches the current step's role (build → engineer via
      # workflow_map_role).
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
          # La route est PORTEE par les labels de l'issue (BL-6-40 Phase 2) — ce site construit ses
          # opts en direct, donc il projette lui-meme au lieu de passer par le harnais.
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
    # `extra_opts` overrides the opts (Keyword.merge last): injects a seam (`wake_recovery`) or
    # replaces a default (`workflow_map_loader`) without duplicating the harness.
    # A forge whose DISCOVERY is slow — the seam that makes the tick take longer than its own
    # interval. Everything else delegates to StepStubForge (generated, so this stays correct if the
    # stub gains a function; a hand-written mirror would rot the day someone adds one).
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
      # THE most expensive finding of its list by its proof: two generations of agents wrote the
      # same falsehood about this file, and one assertion would have killed it.
      #
      # ⚠ The falsehood was "the ticks stack up", and the FIRST version of this test tried to pin
      # its negation by asserting a small mailbox — which was itself hollow. Measured: with the
      # fault deliberately introduced (`schedule/1` moved BEFORE `safe_poll`), it stayed GREEN.
      # `Process.send_after` arms exactly ONE timer per handler pass, so the chain is single-in-
      # flight whatever the order; the order only shifts the effective period by the poll duration.
      # Nothing stacks, and no assertion on the tick order can show otherwise.
      #
      # What IS load-bearing, and what the code names two lines below the tick handler, is that a
      # SECOND chain must never be armed: injecting `:poll` from the webhook path "would create a
      # permanent PARALLEL CHAIN", which is why the hint uses a DEDICATED `:gitea_kick`. That is
      # the real property, and it is falsifiable — a `:poll` there re-enters the recurring handler
      # and the poller ticks forever from a hint.
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

      # And then nothing: the kick consumed no clock and started none. A `:poll` in place of
      # `:gitea_kick` lands in the recurring handler and arms the chain, so a single webhook would
      # make the poller tick forever.
      #
      # The window is 2.5 s and that number is not padding: `Backoff.jitter/1` clamps every delay to
      # a 1 s FLOOR ("no accidental busy-poll on a small interval"), so `interval_ms: 30` really
      # means ~1 s. A shorter window cannot see the fault — measured, the first version of this
      # assertion used 500 ms and stayed GREEN with `:gitea_kick` deliberately replaced by `:poll`.
      refute_receive :poll_started, 2_500

      GenServer.stop(pid)
    end
  end

  describe "step mode — max_fan (serial IS this ceiling at 1)" do
    # These tests describe SERIALIZATION, so they must now DECLARE it: the `:repo_serialized_lease`
    # boolean they used to inherit is gone, and `max_fan` defaults to 5. Reading them at the default
    # would be reading a serialization story on a fan-out fleet — five reddened here saying exactly
    # that, which is the item working, not the item breaking.
    setup do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 1)
      :ok
    end

    test "an ENGAGED pipeline (advanced route) holds the lease and blocks a QUEUED issue" do
      # #8: the lease is read from the ROUTE (state-machine), no longer state:*. #11 routed
      # qa-2:deploy (2nd step ≠ 1st = ADVANCED pipeline between two step_runs) → ENGAGED → holds
      # the lease AND its current step is dispatched (continues the step_run). #12 routed
      # qa-build:build (1st step = QUEUED) → lease held → waits.
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
      # The hole this repairs, and it was open in SERIAL, not revealed by the fan-out: the lease
      # counted only what it saw on its own rail (ENGAGED issues). A ticket that reached its jury
      # leaves the issues side — it is dispatched through the pulls — so it held nothing, and a
      # repo serialized to ONE workflow_run happily started a second.
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
      # Regression: the canonical spawn order is lock → pod → enqueue → WAKE (wake LAST). So
      # `{:error, {:wake_unreached, …}}` = pipeline STARTED (lock + pod + brief set), only the
      # tmux wake failed. The pipeline MUST hold the repo-serialized lease. Two issues of the SAME
      # repo QUEUED in the same tick; the 1st one's wake fails (FailingWakeRecovery). The 1st
      # pipeline is started → lease TAKEN → the 2nd issue is SKIPPED (a single pipeline starts).
      # The failed wake is NOT swallowed: it stays counted in `errors` (and feeds
      # err_streak/telemetry).
      #
      # Proven regression: go back to the old `step_do_dispatch` (wake_unreached → errors WITHOUT
      # taking the lease) + a `start_pipeline` that only takes the lease when `dispatched`
      # increases → the lease stays free → the 2nd issue STARTS a 2nd pipeline → the tally becomes
      # `skipped:0, errors:2` (two concurrent feature-branches), the `skipped:1` assert fails.
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

      # 1st issue: pipeline started but wake unreachable → errors:1, lease TAKEN. 2nd issue: lease
      # held → skipped:1. A SINGLE pipeline starts. The failed wake is SURFACED (errors), not
      # swallowed.
      assert %{dispatched: 0, skipped: 1, errors: 1} = Poller.force_poll(name)

      # The failed wake is NOT swallowed: it surfaces in the per-item anomaly signal
      # `last_tally_errors` (the streak/backoff is reserved for DISCOVERY failure in the
      # multi-repo architecture — the forge is up here).
      assert %{last_tally_errors: 1} = Poller.stats(name)

      GenServer.stop(pid)
    end

    test "routed-advanced pipeline with NIL workflow_map holds the lease (a transient workflow_map failure does not release the lease)" do
      # Regression: the lease is read from the ROUTE (append-only, robust), NEVER from the
      # workflow_map load's success. #18 routed qa-2:deploy (2nd step ≠ 1st = ADVANCED pipeline =
      # ENGAGED) but its workflow_map TRANSIENTLY fails to load (NilWorkflowMapForQa2Loader raises
      # on qa-2). The pipeline stays ENGAGED (fail-closed) → holds the lease. #19 routed
      # qa-build:build (1st step = QUEUED, qa-build workflow_map loads OK), same repo → lease held
      # → SKIPPED. No 2nd pipeline starts despite the nil workflow_map.
      #
      # Proven regression: go back to `engaged = not is_nil(workflow_map) and not
      # first_step?(...)` → #18's nil workflow_map classifies it `engaged=false` → it leaves the
      # lease set → #19 sees the lease FREE → STARTS a 2nd pipeline → the tally becomes
      # `dispatched:1` (instead of `dispatched:0, skipped:1`), the assert fails.
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

      # #18 engaged (nil workflow_map but advanced route → fail-closed) holds the lease: its step
      # is dispatched but fail-loud (workflow_map missing on the StepDispatcher side → errors:1),
      # the lease stays HELD. #19 → lease held → skipped:1. No 2nd pipeline started (dispatched:0).
      assert %{dispatched: 0, skipped: 1, errors: 1} = Poller.force_poll(name)

      GenServer.stop(pid)
    end

    # ❌ TEST SUPPRIME le 2026-08-03 (BL-6-40 Phase 2, `[R2]`) — et il faut savoir pourquoi, sinon
    # quelqu'un le reecrira.
    #
    # Il epinglait le fail-CLOSED de `classify_issue` quand `get_route` rendait une ERREUR
    # TRANSITOIRE : on garde le bail plutot que de risquer de perdre celui d'un workflow_run
    # avance. C'etait un vrai canari, avec sa regression prouvee.
    #
    # La route se DERIVE desormais des labels que `list_open_issues` rend deja
    # (`route_from_labels/1`, pure) : il n'y a plus d'appel reseau dans ce chemin, donc plus de
    # panne transitoire a couvrir. La branche `{:error, _}` n'existe plus — pas « n'arrive plus » :
    # `route_from_labels/1` ne rend que `{:ok, …}` ou `:none`.
    #
    # Le garder aurait produit un ECHEC (mesure : `dispatched:1` au lieu de `0`, l'issue #18 aux
    # labels vides devenant QUEUED donc dispatchable), pas un faux vert. La propriete qu'il tenait
    # n'est pas perdue : elle est devenue sans objet avec l'I/O qui la causait.
    #
    # Ce qui RESTE couvert, et qu'il ne faut pas confondre : le fail-closed sur workflow_map nil
    # d'un cote (le test juste au-dessus), et le meme fail-closed pour les appelants de
    # `get_route/3` — qui, eux, lisent encore le reseau.
  end

  # ============================================================
  # PR-driven path: the judges are dispatched via the requested_reviewers.
  # ============================================================
  describe "step mode — PR-driven judge dispatch" do
    # BL-6-48 pas 3, moitie PR — le `wait/*` vit sur l'ISSUE, et le chemin PR ne l'a pas en main.
    # La map `issue → wait/*` est threadee depuis les issues deja listees, jumelle d'`awaits_arch_ids`.
    test "chemin PR : une issue qui AWAITS-ARCH ne patiente plus — son wait/* est RETIRE" do
      # Cas reellement atteignable, et semantiquement juste : `lcars-awaits-arch` porte deja
      # l'attente. Laisser `wait/role` a cote serait deux verites pour un fait — et un etat perime.
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

      # Son head ne parse pas en feature-branch → aucun numero d'issue → aucune ecriture. Etiqueter
      # une PR etrangere reviendrait a ecrire sur le depot de quelqu'un d'autre.
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
      # #99 assigned engineer BUT its PR is open -> judge phase: the issue path SKIPS (otherwise
      # re-spawn of the already-finished producer); the judge is dispatched by the pulls path.
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
      # empty requested_reviewers = PR not set up by the pipeline (human/fork, or an agent that
      # lost its reviewers). Agent-agnostic gate → adoption: we SET the judges instead of
      # skipping. Counted `dispatched` (return `{:ok, {:adopted, ...}}`); the judges spawn on the
      # next tick.
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
      # Illegal state before MA-02: the live repoB pod's (non-repo-qualified) ref `{:issue, 8}`
      # "owned" the GLOBAL 8 → the repoA#8 orphan looked owned → NEVER reclaimed (wedge); and the
      # 2-tick grace contaminated cross-repo. With the `{repo, :issue, 8}` key: repoA#8 is an
      # orphan (no repoA pod), repoB#8 is owned (live repoB pod) → only repoA#8 is reclaimed after
      # the grace.
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

      # 1st tick: repoA#8 AND repoB#8 become suspects (grace) — repoB#8 will be filtered (live
      # pod) but is reclaimed NEITHER at the 1st NOR the 2nd tick. Nothing reclaimed at the 1st.
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
      # Without the fix: the escalation sets `lcars-awaits-arch` on ISSUE 42, but `dispatch_review`
      # only reads the PR's labels → the requested reviewer re-spawns the judge EVERY tick (churn).
      # With the fix: the poller computes the awaits-arch SET (issue 42, already listed → zero I/O)
      # and threads it to the pulls → dispatch_review skips → the judge is NOT dispatched.
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

      # First tick reconciles (boot-time reconciliation IS the feature); the second tick is
      # inside the period → throttled, no second pass. The old runtime had NO pass at all —
      # the rule projected at onboarding was never compared to the current jury again.
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

      # No `Process.alive?` probe: this poller is LINKED to the test process, so by the time
      # `on_exit` runs — in another process, after the test process died — it is already gone and
      # the probe answers `false`, making the whole teardown a no-op. When the death is still in
      # flight the probe answers `true` instead and `GenServer.stop` exits `:noproc` IN the
      # teardown, which marks a PASSED test FAILED (measured 2026-09-07: red in the full suite on
      # a loaded machine, green alone, same toolchain — an original flake, not a bump regression).
      # Same race as in `pool_slot_test.exs`. Nothing is bookkept here, so we do not probe: we
      # stop, and we tolerate a subject that has already left.
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
