defmodule Fleet.Pilot.PollerTest do
  use ExUnit.Case, async: false

  # SYNC on purpose: a describe here flips the GLOBAL `:fleet_pilot, :require_onboarded`, which
  # every dispatch path reads. Async peers running in that window were refused with
  # `{:work_dir_missing, _}` — a flake that fires by timing, not by order, so a seed does not
  # reproduce it. The restore-on-exit is correct and was never the problem: the value is right
  # after the test, and wrong DURING it for everyone else.

  alias Fleet.Pilot.Poller

  # Legacy rail (poll_once/4 → Routing → Dispatcher → RAM Executor) REMOVED (②.3 / BL-050). Its
  # tests (`describe "poll_once/4"`, `StubForge`/`StubInvoker` stubs) left with it. Only step mode
  # remains below (+ the GenServer lifecycle, shared).

  # G6: workflow_map_loader that RAISES (map removed/renamed from the catalog) →
  # load_workflow_map_or_nil rescues.
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
  defmodule ArchFreeTQ do
    def list_active, do: []
    def pod_active_issue_id(_pod_id), do: {:ok, nil}
    def pod_status(_pod_id), do: {:ok, nil}
    def enqueue(_pod_id, _attrs), do: {:ok, %{id: "wi-arch"}}
  end

  defmodule ArchBusyTQ do
    def list_active, do: []
    def pod_active_issue_id(_pod_id), do: {:ok, nil}
    def pod_status(_pod_id), do: {:ok, :assigned}
    def enqueue(_pod_id, _attrs), do: {:ok, %{id: "wi-arch"}}
  end

  defmodule ArchPendingTQ do
    def list_active, do: []
    def pod_active_issue_id(_pod_id), do: {:ok, nil}
    def pod_status(_pod_id), do: {:ok, :pending}
    def enqueue(_pod_id, _attrs), do: {:ok, %{id: "wi-arch"}}
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
      issue = %{
        "number" => 42,
        "body" => "x",
        "labels" => [%{"name" => "lcars-awaits-arch"}],
        "assignees" => [%{"login" => "lordzurp"}]
      }

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
    test "A-10: 2 awaits-arch repos → EXACTLY 1 re-kick per throttle tick (not 1 per repo)" do
      issue = %{
        "number" => 42,
        "body" => "x",
        "labels" => [%{"name" => "lcars-awaits-arch"}],
        "assignees" => [%{"login" => "lordzurp"}]
      }

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
      issue = %{
        "number" => 42,
        "body" => "x",
        "labels" => [%{"name" => "lcars-awaits-arch"}],
        "assignees" => [%{"login" => "lordzurp"}]
      }

      {name, pid} = start_entry_poller({:ok, [issue]}, %{}, task_queue: ArchFreeTQ)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..2, do: Poller.force_poll(name)
        end)

      assert log =~ "mandate lordzurp/lcars-test#42 enqueued (arch was free)"

      GenServer.stop(pid)
    end

    # NEW state (2026-07-19): a PENDING mandate (offered but never fetched — the immediate
    # kick's wake was lost) → the net RE-WAKES without re-offering (re-enqueue would churn the
    # pending item). Closes the lost-wake liveness hole: pending no longer silences the net.
    test "PENDING arch mandate (never fetched) → re-wake ONLY, no new enqueue" do
      issue = %{
        "number" => 42,
        "body" => "x",
        "labels" => [%{"name" => "lcars-awaits-arch"}],
        "assignees" => [%{"login" => "lordzurp"}]
      }

      {name, pid} = start_entry_poller({:ok, [issue]}, %{}, task_queue: ArchPendingTQ)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..2, do: Poller.force_poll(name)
        end)

      assert log =~ "pending mandate never fetched → re-wake only"
      refute log =~ "enqueued (arch was free)"

      GenServer.stop(pid)
    end

    # Symmetric: the arch BUSY (an active work-item) serializes via the forge — NO new enqueue
    # AND NO wake (a busy arch already knows its mandate; re-waking it every throttle tick was
    # pure noise, observed live 2026-07-18). The backlog stays on the forge, re-offered + woken
    # next tick once the arch submits and the label drains.
    test "BUSY arch (active work-item) → NO enqueue, NO wake (it already knows its mandate)" do
      issue = %{
        "number" => 42,
        "body" => "x",
        "labels" => [%{"name" => "lcars-awaits-arch"}],
        "assignees" => [%{"login" => "lordzurp"}]
      }

      {name, pid} = start_entry_poller({:ok, [issue]}, %{}, task_queue: ArchBusyTQ)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..10, do: Poller.force_poll(name)
        end)

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
  defmodule StepStubForge do
    # L'admission lit les preconditions avant de DEMARRER un ticket : un stub sans cette lecture
    # ne peut pas voir la porte, et la laisserait disparaitre sans qu'un test rougisse.
    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}

    # LE RAIL CI, PREMISSE ET PAS SUJET. Les PR de ce module portent des labels vides : leur issue
    # n'a pas de carte gravee, donc la politique CI vient de la carte du PROJET — qui l'exige. Ces
    # tests mesurent la COMPTABILITE du poller (dispatched/skipped/errors) ; ils declarent donc un
    # rail vert et rien de plus. Le comportement de la porte elle-meme se mesure dans `CiGateTest`,
    # pas ici. Sans ces deux fonctions le stub ne decrit pas une forge : il plante.
    def get_pull(_repo, n, _opts) do
      {:ok,
       %{
         "number" => n,
         "state" => "open",
         "head" => %{"sha" => "p011e4c0ffee00000000"},
         "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end

    def commit_ci_state(_repo, _sha, _opts), do: {:ok, :success}

    # WS3 — the poller DISCOVERS its repos by org-membership (`list_org_repos`) BEFORE scanning.
    # Default = THE test repo (single-repo: 1 repo discovered → 1 `step_do_poll`). `_test_repos`
    # for multi-repo, `_test_discover` to simulate a failing discovery (forge down → backoff). No
    # more seal/admission: org-membership IS the admission (any repo returned here is scanned).
    def list_org_repos(_org, opts) do
      Keyword.get(
        opts,
        :_test_discover,
        {:ok, Keyword.get(opts, :_test_repos, ["lordzurp/lcars-test"])}
      )
    end

    # #5.2 D1 — the multi-user scoping is FORGE-SIDE: the poller passes `assigned_by=<my_human>`.
    # The stub CAPTURES this scoping (→ `:_test_pid`) to verify it, then returns `:_test_issues`
    # as-is.
    def list_open_issues(_repo, opts) do
      send(
        Keyword.get(opts, :_test_pid, self()),
        {:scoped, :issues, Keyword.get(opts, :assigned_by)}
      )

      Keyword.fetch!(opts, :_test_issues)
    end

    # Step mode ALSO lists PRs (judge path), scoped the same (assigned_by). Default {:ok, []}.
    def list_open_pulls(_repo, opts) do
      send(
        Keyword.get(opts, :_test_pid, self()),
        {:scoped, :pulls, Keyword.get(opts, :assigned_by)}
      )

      Keyword.get(opts, :_test_pulls, {:ok, []})
    end

    # Observable comme `remove_label` : la convergence du `wait/*` (BL-6-48) ecrit depuis le
    # Poller, donc le signal part vers le pid du TEST, pas vers la mailbox du GenServer.
    def add_label(_repo, n, label, opts) do
      send(Keyword.get(opts, :_test_pid, self()), {:add_label, n, label})
      {:ok, :added}
    end

    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    def start_stopwatch(_repo, _n, _opts), do: :ok
    def stop_stopwatch(_repo, _n, _opts), do: :ok

    # DELEGATION a la vraie fonction, et c'est deliberé : `route_from_labels/1` est PURE (zero I/O)
    # — la stubber reviendrait a re-implementer la regle de derivation dans le harnais, donc a
    # tester une copie au lieu du contrat. Les stubs existent pour couper les I/O, pas les regles.
    def route_from_labels(labels), do: Fleet.Forge.Client.route_from_labels(labels)

    # #8: the route lives in the route-comment (state-machine). Stub configurable via
    # `_test_routes` (map n → {workflow_map, step}). Default :none (unrouted issue → A1 producer).
    def get_route(_repo, n, opts) do
      case Map.get(Keyword.get(opts, :_test_routes, %{}), n) do
        {workflow_map, step} -> {:ok, {workflow_map, step}}
        # `:error` sentinel → transient forge failure (fail-closed lease test).
        :error -> {:error, :timeout}
        _ -> :none
      end
    end

    def get_predecessor_result(_repo, _n, _opts), do: :none
    # Info-starvation fix: build_judge_brief reads the criterion (issue body) via get_issue.
    def get_issue(_repo, n, _opts), do: {:ok, %{"number" => n, "body" => "criterion stub ##{n}"}}

    # ②.1d: by default no judge verdict (the poller tests do not cover merge/rework) → every
    # requested judge is "pending" → dispatched.
    def pr_review_verdicts(_repo, _index, _opts), do: {:ok, %{}}

    # F-E8: combined jury state — no verdict + empty jury (the poller tests do not cover merge) →
    # `requested` = the PR's `requested_reviewers` → every requested judge stays pending →
    # dispatched.
    def pr_review_state(_repo, _index, _opts), do: {:ok, %{verdicts: %{}, reviewers: []}}

    # Adoption: sets judges on an orphan PR (human/fork, or an agent that lost its reviewers).
    def request_review(_repo, index, reviewers, _opts),
      do: send(self(), {:requested_review, index, reviewers}) && :ok

    # MA-06: forge-native counter of rework rounds (the poller tests do not cover bounded rework).
    def count_change_request_rounds(_repo, _index, _opts), do: {:ok, 0}
    def post_route(_repo, _n, p, s, _opts), do: send(self(), {:route, p, s}) && {:ok, :posted}
    def set_assignee(_repo, _n, login, _opts), do: send(self(), {:assignee, login}) && {:ok, :set}

    # Reconciliation (B): the reclaim runs INSIDE the Poller GenServer → we route the signal to
    # the test pid (`:_test_pid` of the forge_opts), not `self()` (the Poller's mailbox).
    def remove_label(_repo, n, label, opts) do
      send(Keyword.get(opts, :_test_pid, self()), {:remove_label, n, label})

      # `_test_fail_remove_label` — the forge refuses the removal (outage): the reconciliation must
      # KEEP the ref suspect and retry NEXT tick (not restart the 2-tick grace from scratch).
      if Keyword.get(opts, :_test_fail_remove_label, false),
        do: {:error, :forge_down},
        else: {:ok, :removed}
    end
  end

  defmodule StepStubLoader do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{},
           spec: %{"brief_kind" => "worker", "invocation" => %{"lifetime_scope" => "pipe"}}
         }}

    # PR judge (qualifier/reviewer) -> brief_kind: judge (defused GateBrief brief).
    def load(role) when role in ["qualifier", "reviewer"],
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => role},
           spec: %{"brief_kind" => "judge"}
         }}

    def load(_), do: {:error, :not_found}
  end

  # WORKFLOW_MAP loader (load!/1) — distinct from the CapProfile loader above (load/1).
  defmodule StepStubWorkflowMapLoader do
    # 1-step (engineer producer): an issue routed here (step=build=1st) is QUEUED (not started).
    def load!("qa-build") do
      %{
        "name" => "qa-build",
        "ci" => "ignore",
        "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }
    end

    # 2-step: routed at the 2nd step (deploy ≠ 1st) = ADVANCED pipeline (between two step_runs) = ENGAGED.
    def load!("qa-2") do
      %{
        "name" => "qa-2",
        "ci" => "ignore",
        "steps" => %{
          "build" => %{"role" => "engineer", "needs" => []},
          "deploy" => %{"role" => "engineer", "needs" => ["build"]}
        }
      }
    end
  end

  defmodule StepStubSpawner do
    # PASSE-9 — real `Spawner.spawn_pod/3` shape = {:ok, pid()}, NEVER a string: a consumer
    # re-interpolating the pid would break in prod.
    def spawn_pod(_profile, issue_id, opts) do
      send(self(), {:spawned, issue_id, opts})
      {:ok, self()}
    end

    # Reconciliation (B): no live pod by default → every `lcars-in-flight` lock is an orphan
    # candidate (reclaimed after the 2-tick grace). A stub with list_pods absent would fail-safe
    # (skip).
    def list_pods, do: []

    # G4: the awaits-arch re-kick calls wake_pod — no-op stub (the tick must not crash when an
    # awaits-arch issue is present). A lost wake costs latency, never the backlog: the truth = the
    # `lcars-awaits-arch` label on the forge, re-read every tick, and this periodic re-kick
    # (@awaits_rekick_every throttle) IS the rail that re-derives the wake. The DECISION to
    # re-kick is tested via awaits_rekick?/2.
    def wake_pod(_pod_id), do: :ok
  end

  # F-037 / #25: a LIVE pod with a REPO-SCOPED pod_id (`<repo-slug>-issue-<n>-<role>`, real PodId format).
  defmodule LivePodSpawner do
    def spawn_pod(_profile, _issue_id, _opts), do: {:ok, self()}
    def list_pods, do: [%{pod_id: "lordzurp-lcars-test-issue-8-engineer"}]
  end

  # TaskQueue stub: the pod has an ACTIVE task → it legitimately OWNS its lock.
  defmodule ActiveTaskQueue do
    def pod_status(_pod_id), do: {:ok, :assigned}
  end

  # SLOT-FREEZE: a project-scoped PIPE eng (pod_id `<repo>-engineer`, WITHOUT `-issue-N-` — the
  # resident eng that handles N issues sequentially, 1 process = 1 Desktop slot).
  defmodule ProjectPipeSpawner do
    def spawn_pod(_profile, _issue_id, _opts), do: {:ok, self()}
    def list_pods, do: [%{pod_id: "lordzurp-lcars-test-engineer"}]
  end

  # TaskQueue stub: the project eng is working BRICK 8 (issue_id "issue-8") -> it owns #8.
  defmodule ProjectTaskQueueIssue8 do
    def pod_status(_pod_id), do: {:ok, :assigned}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-8"}
  end

  # TaskQueue stub: the project eng is working ANOTHER brick (9) -> it does NOT own #8.
  defmodule ProjectTaskQueueIssue9 do
    def pod_status(_pod_id), do: {:ok, :assigned}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-9"}
  end

  # The listener name is GLOBAL and this file is async: the name frees on the PREVIOUS test
  # process's DEATH, which is asynchronous — a register at the next test's first line can race
  # it (seed-dependent flake, measured in the gate). Bounded wait: the only possible owner is
  # the dying predecessor of THIS serial module, never a live peer.
  defp register_reap_listener!(tries \\ 50) do
    Process.register(self(), :reap_test_listener)
  rescue
    ArgumentError ->
      if tries == 0, do: raise("reap_test_listener never freed")
      Process.sleep(10)
      register_reap_listener!(tries - 1)
  end

  # Reap (B'): a live per-brick JUDGE pod + kill capture. `kill_pod` runs in the POLLER process →
  # the capture goes through the registered test listener (`:reap_test_listener`), same reason the
  # forge stub threads `_test_pid`.
  defmodule QuiescedJudgeSpawner do
    def spawn_pod(_profile, _issue_id, _opts), do: {:ok, self()}
    def list_pods, do: [%{pod_id: "lordzurp-lcars-test-issue-8-consultant"}]
    def wake_pod(_pod_id), do: :ok

    def kill_pod(pod_id) do
      if pid = Process.whereis(:reap_test_listener), do: send(pid, {:killed, pod_id})
      :ok
    end
  end

  # TaskQueue stub: the judge DELIVERED its verdict (terminal task) → no active task, owns nothing.
  # `enqueue`/`list_active`: the awaits-arch fixture also walks the arch-offer path on the tick.
  defmodule QuiescedTaskQueue do
    def pod_status(_pod_id), do: {:ok, :completed}
    def enqueue(_pod_id, _attrs), do: {:ok, %{id: "wi-arch"}}
    def list_active, do: []
  end

  # TaskQueue stub: the project eng DELIVERED #8 (task `:completed`) — martine + F-C050 configs.
  # `:completed` is TERMINAL (`WorkItem.active?/1` → false): a delivered eng NO LONGER owns its
  # lock. Two tests: martine (PR#6 open → issue excluded via pr_issue_ids, a dead judge's PR lock
  # is reclaimed) and F-C050 (NO PR → the ISSUE orphan, once masked by `:completed`, is finally
  # reclaimed). `pod_active_issue_id` returns "issue-8" but is no longer reached: the
  # `pod_has_active_task?` filter short-circuits before (a `:completed` is no longer active).
  defmodule ProjectTaskQueueCompletedIssue8 do
    def pod_status(_pod_id), do: {:ok, :completed}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-8"}
  end

  # Parked-admission TaskQueue stub: the pod was ADMITTED (task enqueued on issue-8) but its wake
  # never LANDED (`wake_unreached`) — the task is still `:pending`, never pulled. `:pending` is
  # "active" but NOT pulled: a PARKED admission owns no lock. Twin of ProjectTaskQueueCompletedIssue8,
  # `:pending` instead of `:completed`.
  defmodule ParkedPendingTaskQueue do
    def pod_status(_pod_id), do: {:ok, :pending}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-8"}
  end

  # G1 — TaskQueue stub: a PULLED GATEKEEPER EVAL (state :assigned — the gatekeeper pulled it)
  # carries brick #8 of THIS repo (self-describing MA-03 metadata: gate_eval + resume_n +
  # resume_payload.repository). No live pod otherwise (the producer is done): exactly the eval window.
  defmodule GateEvalTaskQueue do
    def pod_status(_pod_id), do: {:ok, nil}

    def list_active do
      [
        %{
          state: :assigned,
          metadata: %{
            "gate_eval" => true,
            "resume_n" => 8,
            "resume_payload" => %{"repository" => %{"full_name" => "lordzurp/lcars-test"}}
          }
        }
      ]
    end
  end

  # A gate-eval ADMITTED but never activated: enqueued (state :pending), the gatekeeper never pulled
  # it (wake lost, kick net exhausted). An eval without an executor owns nothing — twin of
  # GateEvalTaskQueue with :pending instead of :assigned (enqueued, never pulled).
  defmodule GateEvalPendingTaskQueue do
    def pod_status(_pod_id), do: {:ok, nil}

    def list_active do
      [
        %{
          state: :pending,
          metadata: %{
            "gate_eval" => true,
            "resume_n" => 8,
            "resume_payload" => %{"repository" => %{"full_name" => "lordzurp/lcars-test"}}
          }
        }
      ]
    end
  end

  # G1 — TaskQueue stub: a pulled eval exists but for ANOTHER repo → it does NOT own the #8 ref
  # of lordzurp/lcars-test (multi-project: the ref's repo comes from the resume_payload).
  defmodule GateEvalOtherRepoTaskQueue do
    def pod_status(_pod_id), do: {:ok, nil}

    def list_active do
      [
        %{
          state: :assigned,
          metadata: %{
            "gate_eval" => true,
            "resume_n" => 8,
            "resume_payload" => %{"repository" => %{"full_name" => "lordzurp/autre-projet"}}
          }
        }
      ]
    end
  end

  # Wake recovery that FAILS (unreachable pod, unrepaired re-roll) → `StepDispatcher.dispatch_issue`
  # surfaces `{:error, {:wake_unreached, …}}`: the pipeline IS started (lock + pod + brief set
  # upstream, canonical order), only the tmux wake failed. Used to prove the contract "failed wake
  # ⇒ lease TAKEN".
  defmodule FailingWakeRecovery do
    def wake(_pod_id, _respawn_fun, _opts), do: {:error, {:escalated, :not_found}}
  end

  # WORKFLOW_MAP loader that TRANSIENTLY FAILS on `qa-2` (workflow_map → nil) but loads `qa-build`
  # normally. Simulates a network/forge workflow_map load failure on a routed-advanced pipeline:
  # the lease must NOT be released because of it (fail-closed). `load!/1` RAISES for `qa-2` → the
  # poller (load_workflow_map_or_nil) AND the StepDispatcher (load_workflow_map) rescue it into
  # nil/`{:error}`.
  defmodule NilWorkflowMapForQa2Loader do
    def load!("qa-2"), do: raise("workflow_map qa-2 unavailable (simulated transient failure)")

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
        protection_reconciler: fn _repo, _opts -> :ok end,
        step_dispatch?: true,
        forge_client: StepStubForge,
        forge_opts: [
          _test_issues: issues_response,
          _test_pulls: pulls_response,
          _test_pid: self()
        ],
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
      Fleet.TestEnv.put_env_restoring(:fleet_pilot, :require_onboarded, true)
      :ok
    end

    test "a repo with no project directory is SKIPPED — and costs not one forge call" do
      # The check is local and runs BEFORE the listing, so an unserved repo also stops paying two
      # API calls per tick. Asserting the ABSENCE of the forge call is what pins the ORDER;
      # asserting only "no spawn" would pass with the check placed anywhere downstream.
      issues = [
        %{"number" => 7, "body" => "x", "labels" => [], "assignee" => %{"login" => "lordzurp"}}
      ]

      {name, pid} = start_step_poller({:ok, issues})

      log = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)

      refute_received {:scoped, :issues, _}
      refute_received {:spawned, _, _}
      assert log =~ "NOT ONBOARDED"
      assert log =~ "create / import / open / adopt"

      GenServer.stop(pid)
    end

    test "the warning fires ONCE per repo, not once per tick" do
      {name, pid} = start_step_poller({:ok, []})

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
      # It was a GREEN WITH TWO DIFFERENT CAUSES. On a box the root exists because the entrypoint
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

    test "NOT ONBOARDED is the gate's own verdict, and it needs no filesystem to be proven" do
      # The negative case carries the behaviour: the directory is absent (no test creates it any
      # more), the gate refuses, and it says what to do about it. What is NOT covered here, and is
      # named rather than left to be discovered: the POSITIVE case — an existing directory letting
      # the repo through — is a runtime fact and is proven on the BENCH, where a project is really
      # onboarded and the poller really dispatches.
      {name, pid} = start_step_poller({:ok, []})

      log = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)

      assert log =~ "NOT ONBOARDED"
      refute_received {:scoped, :issues, _}

      GenServer.stop(pid)
    end
  end

  describe "step mode — force_poll" do
    test "ROUTELESS assigned issue → onboarded onto the default workflow_map (skip, no spawn)" do
      issues = [
        %{
          "number" => 7,
          "body" => "fais le hello",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        }
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
        %{
          "number" => 7,
          "body" => "fais le hello",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        }
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

    test "reconciliation (B): orphan lock reclaimed at the 2nd tick (grace), not the 1st" do
      # #8 locked but NO live pod (StepStubSpawner.list_pods → []) = confirmed orphan.
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      {name, pid} = start_step_poller({:ok, issues})

      # 1st tick: #8 becomes a SUSPECT (2-tick grace) — NOT reclaimed yet.
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      # 2nd consecutive tick: orphan CONFIRMED → lock reclaimed (the next tick will re-dispatch).
      # frein-publish P3 — the log reports what was MEASURED (no live pod here), never the old
      # asserted "pod dead without completion" that declared dead a pipe idling between two
      # rework rounds (faceproof bench). The message is the diagnosis an operator will read.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Poller.force_poll(name)
          assert_received {:remove_label, 8, "lcars-in-flight"}
        end)

      assert log =~ "no live pod (dead/reaped)"
      refute log =~ "pod dead without completion"

      GenServer.stop(pid)
    end

    test "reap (B'): a QUIESCED judge pod (brick unlocked, no active task) is reaped at the 2nd tick, not the 1st" do
      # Live case 2026-07-19 (#5 zombie loop): consultant idle-at-prompt 16 min after its redirect
      # verdict. Here: #8 is parked awaits-arch (in-flight lifted by await_arch), the judge pod is
      # alive with a TERMINAL task → no reason to live → reaped after the 2-tick grace.
      register_reap_listener!()

      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-awaits-arch"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      name = :"P_reap_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          spawner: QuiescedJudgeSpawner,
          task_queue: QuiescedTaskQueue
        )

      # 1st tick: the pod becomes a SUSPECT (2-tick grace) — NOT reaped yet.
      Poller.force_poll(name)
      refute_received {:killed, _}

      # 2nd consecutive tick: quiesced CONFIRMED → reaped.
      Poller.force_poll(name)
      assert_received {:killed, "lordzurp-lcars-test-issue-8-consultant"}

      GenServer.stop(pid)
    end

    test "reap (B'): a pod whose brick STILL holds the in-flight lock is NEVER reaped" do
      register_reap_listener!()

      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      name = :"P_reap_locked_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          spawner: QuiescedJudgeSpawner,
          task_queue: QuiescedTaskQueue
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:killed, _}

      GenServer.stop(pid)
    end

    test "reap (B'): an ACTIVE-task pod is NEVER reaped even with its brick unlocked (mid-eval belt)" do
      # Gate-eval belt: a one-shot gatekeeper mid-eval works an issue whose lock may be lifted —
      # the active task (not the label) proves it is working. Same authority as the lock duty.
      register_reap_listener!()

      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      name = :"P_reap_active_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          spawner: QuiescedJudgeSpawner,
          task_queue: ActiveTaskQueue
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:killed, _}

      GenServer.stop(pid)
    end

    test "reap (B'): a RESIDENT project pod (no brick ref in its id) is structurally exempt" do
      # The resident eng (`<repo>-engineer`) has no `-issue-N-` ref: its lifecycle is the
      # slot-freeze, never the brick reap — even fully idle on a quiet repo.
      register_reap_listener!()

      name = :"P_reap_resident_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, []}, _test_pid: self()],
          loader: StepStubLoader,
          spawner: ProjectPipeSpawner,
          task_queue: QuiescedTaskQueue
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:killed, _}

      GenServer.stop(pid)
    end

    test "F-037: a LIVE pod with a REPO-SCOPED pod_id holds its lock (NO mis-reclaim)" do
      # Regression of the `parse_pod_ref` fix: pod_id = `<repo-slug>-issue-N-role` (repo-scoped,
      # PodId/#25). The old `^issue-`-anchored parse did NOT recognize it → empty
      # `live_owned_refs` → a LIVE pod's lock looked orphaned → mis-reclaimed after the grace.
      # Here the pod (active task on issue 8) is recognized as owner → its lock is NEVER
      # reclaimed, even after 2 ticks.
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
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          spawner: LivePodSpawner,
          task_queue: ActiveTaskQueue
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "SLOT-FREEZE: a project-scoped PIPE eng holds the lock of its ACTIVE BRICK (no mis-reclaim -> no loop)" do
      # Regression of the hello-avengers loop: the project pod `<repo>-engineer` (without
      # `-issue-N-`) was recognized as owner of NO lock (parse_pod_ref -> []) -> the poller
      # reclaimed its own -> re-dispatch loop. Here the eng (active task on #8 via its issue_id
      # "issue-8") is recognized as owner -> #8 NEVER reclaimed, even after 2 ticks.
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
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          spawner: ProjectPipeSpawner,
          task_queue: ProjectTaskQueueIssue8
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "SLOT-FREEZE: a project PIPE eng on ANOTHER brick (9) does NOT mask orphan #8 (precise scope)" do
      # The eng ONLY owns its active brick (9), not the whole repo -> a #8 lock without an active
      # pod on it stays a REAL orphan -> reclaimed after the 2-tick grace (otherwise a legitimate
      # orphan would wedge).
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
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          spawner: ProjectPipeSpawner,
          task_queue: ProjectTaskQueueIssue9
        )

      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}
      Poller.force_poll(name)
      assert_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "martine REGRESSION: a :completed engineer owning the issue does NOT protect a dead judge's PR lock" do
      # Bug (introduced then reverted the same day): an augmentation "PR whose parent issue is
      # owned = owned" protected the PR from the reclaim → a DEAD JUDGE's PR lock never reclaimed
      # (the PR lock in review belongs to the judge, not the producer) → judge never re-dispatched
      # = DEAD END (martine-o-matic PR#2). We do NOT derive the PR lock from issue ownership.
      # Since F-C050 the guard is DOUBLE: a `:completed` engineer does not even own its issue
      # anymore (`:completed` terminal). Here: engineer `:completed` on issue-8, PR#6 in review
      # whose judge is DEAD (no live pr-6-* pod). issue-8 is PR-backed → never reclaimed
      # (pr_issue_ids). The PR#6 lock MUST be reclaimed (2-tick grace).
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      pulls = [
        %{
          "number" => 6,
          "head" => %{"ref" => "lcars/issue-8-engineer"},
          "labels" => [%{"name" => "lcars-in-flight"}]
        }
      ]

      name = :"P_pr_orphan_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pulls: {:ok, pulls}, _test_pid: self()],
          loader: StepStubLoader,
          # LIVE project-scoped engineer, `:completed` task (delivered) on issue-8 — the martine config.
          spawner: ProjectPipeSpawner,
          task_queue: ProjectTaskQueueCompletedIssue8
        )

      # issue #8: PR-backed → excluded from the issue-orphan scan, ISSUE lock never reclaimed
      # (doctrine). PR #6: the judge is dead → orphan lock CONFIRMED, reclaimed after the 2-tick
      # grace (2nd poll).
      Poller.force_poll(name)
      refute_received {:remove_label, 6, _}
      Poller.force_poll(name)
      assert_received {:remove_label, 6, _}
      refute_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "F-C050: a :completed PIPE eng (publication LOST, NO PR) does NOT mask the orphan — reclaimed at the 2nd tick" do
      # F-C050: a lost OFFLOADED completion (BEAM crash/restart BEFORE the PR opening) leaves the
      # lcars-in-flight lock on the issue. The LIVE project eng whose LAST task is `:completed`
      # (delivered, publication lost) MASKED this lock forever (pod_has_active_task? counted
      # `:completed` as active) → silent permanent wedge (the poller never re-dispatches, the
      # brick is dead). `:completed` is TERMINAL (@active_states): a DELIVERED eng no longer owns
      # its lock → the orphan is reclaimed (2-tick grace), the next tick re-dispatches. Safe: the
      # legitimate publication window (push ≤30s) removes the label well before the 2nd tick
      # (grace ≈60s), and the completion sequence is idempotent (replay-safe open_pr,
      # no-op-if-absent unlock) → a late reclaim = harmless replay. DISTINCT from the martine case
      # (PR open): HERE no PR → no pr_issue_ids exclusion → the only rampart was (wrongly) the
      # `:completed` ownership.
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      name = :"P_c050_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          # NO _test_pulls → no PR: the publication was lost BEFORE open_pr.
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          # LIVE project eng, last task `:completed` (delivered) on issue-8 — publication lost.
          spawner: ProjectPipeSpawner,
          task_queue: ProjectTaskQueueCompletedIssue8
        )

      # 1st tick: #8 becomes a SUSPECT (2-tick grace), not reclaimed yet.
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      # 2nd tick: orphan CONFIRMED → lock reclaimed (a `:completed` no longer masks). Before the
      # fix: the `:completed` eng "owned" #8 → never reclaimed (this assert failed = the F-C050
      # wedge).
      Poller.force_poll(name)
      assert_received {:remove_label, 8, "lcars-in-flight"}

      GenServer.stop(pid)
    end

    test "a FAILED reclaim keeps the ref SUSPECT: the retry lands NEXT tick, not after a fresh 2-tick grace" do
      # remove_label refused by the forge (outage). The orphan was already CONFIRMED once — dropping
      # it from the suspects with the acted set would force tick3 to re-suspect and tick4 to retry
      # (while the log promised "retry next tick"). Kept suspect, the retry is genuinely at tick3.
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      name = :"P_reclaim_retry_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [
            _test_issues: {:ok, issues},
            _test_pid: self(),
            _test_fail_remove_label: true
          ],
          loader: StepStubLoader,
          spawner: StepStubSpawner,
          task_queue: QuiescedTaskQueue
        )

      # tick1: suspect (grace). tick2: confirmed → reclaim ATTEMPTED (fails). tick3: STILL suspect →
      # retry ATTEMPTED again. Two attempts across three ticks — the old code dropped the ref at
      # tick2 and re-suspected at tick3 (one single attempt in three ticks).
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}
      Poller.force_poll(name)
      assert_received {:remove_label, 8, "lcars-in-flight"}
      Poller.force_poll(name)
      assert_received {:remove_label, 8, "lcars-in-flight"}

      GenServer.stop(pid)
    end

    test "a parked admission (:pending task, wake never landed) does NOT mask the orphan — reclaimed at the 2nd tick" do
      # wake_unreached: the pod is spawned, the lock set, the brief ENQUEUED — but the wake never
      # reached the agent (send-keys lost, the ack-driven kick loop exhausted). The task stays
      # `:pending` (never pulled = never activated). `:pending` is an ACTIVE state, so before the fix
      # the pod "owned" its lock forever (the reconciliation counted a parked pod as a working owner)
      # → silent permanent wedge (the brick is admitted but nothing ever produces its completion). The
      # PULL (get_work_item → `:assigned`) is the durable ACK that the wake landed; a `:pending`-forever
      # admission does not own → the orphan is reclaimed (2-tick grace), the next dispatch re-attempts
      # activation. The nominal enqueue→pull window (seconds) is covered by the ~60s grace.
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      name = :"P_rf21_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          # LIVE instance pod (issue-8-engineer) whose task is `:pending` — admitted, never activated.
          spawner: LivePodSpawner,
          task_queue: ParkedPendingTaskQueue
        )

      # 1st tick: #8 becomes a SUSPECT (2-tick grace), not reclaimed yet.
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      # 2nd tick: orphan CONFIRMED → lock reclaimed (a `:pending` parked pod no longer masks). Before
      # the fix: the `:pending` pod "owned" #8 → never reclaimed (this assert failed = the parked wedge).
      Poller.force_poll(name)
      assert_received {:remove_label, 8, "lcars-in-flight"}

      GenServer.stop(pid)
    end

    test "G1: lock HELD during an ACTIVE gatekeeper eval (never reclaimed, even after the grace)" do
      # Eval window: #8's producer is DONE (no live pod), the PERMANENT gatekeeper carries the
      # eval task (pod_id without a repo slug → invisible to by-pod_id refs). Without the fix,
      # the ref looked orphaned → reclaimed at the 2nd tick MID-EVAL → concurrent re-dispatch
      # (double workflow_run + phantom verdict). With the fix: the ref is owned by the active eval
      # (gate_eval_owned_refs) → never reclaimed, for as many ticks as the eval lasts.
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
          protection_reconciler: fn _repo, _opts -> :ok end,
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

    test "a gate-eval stuck :pending (never pulled — no executor) does NOT hold the lock: reclaimed at the 2nd tick" do
      # The eval-without-executor wedge: the eval is enqueued and the lock is preserved IN ITS NAME,
      # but the gatekeeper never pulled it (wake lost, kick net exhausted) — nobody will ever judge,
      # and before the fix the reconciliation preserved the lock forever (a `:pending` eval counted
      # as ownership). The PULL is the activation proof: a never-pulled eval loses ownership on the
      # 2-tick grace → reclaim → the next dispatch re-escalates a FRESH eval (self-heal).
      issues = [
        %{
          "number" => 8,
          "body" => "x",
          "labels" => [%{"name" => "lcars-in-flight"}],
          "assignees" => [%{"login" => "lordzurp"}]
        }
      ]

      name = :"P_g1_pending_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          spawner: StepStubSpawner,
          task_queue: GateEvalPendingTaskQueue
        )

      # 1st tick: suspect (grace). 2nd tick: confirmed → reclaimed (before the fix: owned forever).
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}
      Poller.force_poll(name)
      assert_received {:remove_label, 8, "lcars-in-flight"}

      GenServer.stop(pid)
    end

    test "G1: a gatekeeper eval of ANOTHER repo does NOT hold the lock (reclaimed at the 2nd tick)" do
      # Multi-project: the owned ref comes from the resume_payload's repo. An eval in progress on
      # lordzurp/autre-projet#8 does not mask the orphan lordzurp/lcars-test#8 — otherwise any
      # active eval would freeze the reconciliation of ALL repos (the fix's symmetric wedge). Also
      # covers the "clobbered eval" (cleared) case: an eval outside list_active owns nothing (same
      # path — the ref becomes orphaned again → reclaim → re-dispatch → re-escalation, self-heal).
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
          protection_reconciler: fn _repo, _opts -> :ok end,
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

  # ============================================================
  # (WS3) SEAL admission boundary: REMOVED. Admission = org membership — `list_org_repos` ONLY
  # returns repos of the fleet org, all admitted outright. The old "tag-only repo discarded /
  # sealed repo admitted" tests exercised do_poll's `admitted_repos` filter, deleted: there is NO
  # "discoverable-but-not-admitted" repo anymore (the org IS the boundary, managed UPSTREAM by the
  # human admin — LCARS is not adversarial multi-tenant). "All discovered repos are scanned" is
  # covered by the discovery section's multi-repo test.
  # ============================================================

  # ============================================================
  # Repo-serialized lease (increment 3): at most 1 active pipeline per repo.
  # ============================================================
  describe "step mode — max_fan (serial IS this ceiling at 1)" do
    # These tests describe SERIALIZATION, so they must now DECLARE it: the `:repo_serialized_lease`
    # boolean they used to inherit is gone, and `max_fan` defaults to 5. Reading them at the default
    # would be reading a serialization story on a fan-out fleet — five reddened here saying exactly
    # that, which is the item working, not the item breaking.
    setup do
      Fleet.TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 1)
      :ok
    end

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

    # La route d'une issue est PORTEE PAR SES LABELS, pas servie par un stub (BL-6-40 Phase 2).
    # `list_open_issues` les rend avec l'issue ; `get_route` refaisait un GET par issue et par tick
    # pour une donnee deja en RAM.
    #
    # La migration tient ICI et les 15 sites d'appel ne bougent pas : ils continuent d'exprimer
    # leur intention en `%{numero => {carte, step}}`, forme lisible, et le harnais la PROJETTE en
    # labels `wfmap/*` + `stage/*` sur les issues correspondantes. Garder la forme d'appel etait la
    # bonne decision : elle dit ce que le test veut, pas comment la forge l'encode.
    #
    # ⚠ `_test_routes` est RETIRE en meme temps, et c'est ce qui donne le ROUGE (`[RR2]` du plan) :
    # laisse en place, le stub `get_route` continuerait a servir la route et les tests resteraient
    # verts VIA LE STUB — des labels mal formes ne se verraient qu'au branchement, loin de leur
    # cause.
    defp project_routes_onto_issues({:ok, issues}, routes) when map_size(routes) > 0 do
      {:ok,
       Enum.map(issues, fn issue ->
         case Map.get(routes, issue["number"]) do
           {map, step} ->
             existing = issue["labels"] || []

             Map.put(
               issue,
               "labels",
               existing ++
                 [
                   %{"name" => Fleet.Labels.wfmap_prefix() <> map},
                   %{"name" => Fleet.Labels.stage_prefix() <> step}
                 ]
             )

           # Une route non projetable (le sentinel `:error` de l'ancien stub) ne devient PAS un
           # label : l'issue reste routeless, ce qui est le seul etat que des labels peuvent dire.
           _ ->
             issue
         end
       end)}
    end

    defp project_routes_onto_issues(issues_response, _routes), do: issues_response

    defp start_entry_poller(issues_response, routes, extra_opts \\ []) do
      name = :"P_lease_#{System.unique_integer([:positive])}"

      base = [
        name: name,
        repo: "lordzurp/lcars-test",
        human: "lordzurp",
        start_tick?: false,
        protection_reconciler: fn _repo, _opts -> :ok end,
        step_dispatch?: true,
        forge_client: StepStubForge,
        forge_opts: [_test_issues: project_routes_onto_issues(issues_response, routes)],
        loader: StepStubLoader,
        workflow_map_loader: StepStubWorkflowMapLoader,
        spawner: StepStubSpawner
      ]

      {:ok, pid} = Poller.start_link(Keyword.merge(base, extra_opts))

      {name, pid}
    end

    # BL-6-47.3 — une enumeration de pods qui echoue est un fail-safe CORRECT (on ne reclame rien)
    # et une panne potentiellement DURABLE. Muette, elle etait indistinguable d'un tick sans rien a
    # reclamer : le `lcars-in-flight` survit a son pod indefiniment et personne ne l'apprend.
    defmodule FlakySpawner do
      def spawn_pod(p, i, o), do: StepStubSpawner.spawn_pod(p, i, o)
      def wake_pod(a, b), do: StepStubSpawner.wake_pod(a, b)

      def list_pods do
        case Agent.get(:pods_enum, & &1) do
          :ok -> []
          :boom -> raise "spawner injoignable"
        end
      end
    end

    test "enumeration des pods KO : on parle au FRANCHISSEMENT, une fois — pas a chaque tick" do
      parent = self()

      # Pas d'`on_exit` pour l'arreter : l'Agent est LIE au process de test, donc il meurt avec lui.
      # La version precedente faisait `if whereis, do: stop` — un nettoyage qui DOUBLE celui du lien
      # et court avec lui : `on_exit` s'execute apres la mort du test, le couple whereis/stop n'est
      # pas atomique, et la suite complete a exhibe la course que le fichier seul cachait.
      {:ok, _} = Agent.start_link(fn -> :boom end, name: :pods_enum)

      {name, _pid} =
        start_entry_poller({:ok, []}, %{},
          spawner: FlakySpawner,
          incident_fun: fn op, subject, reason, _o ->
            send(parent, {:incident, op, subject, reason}) && :recorded
          end
        )

      log1 = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)
      assert log1 =~ "Poller: pod enumeration FAILED"
      assert log1 =~ "an orphaned lock outlives its pod"
      assert_received {:incident, "pod_enumeration", _org, :spawner_unreachable}

      # Deuxieme tick EN PANNE : silence. Repeter le meme fait toutes les 30 s noierait la trace
      # qu'il existe pour lever — meme discipline que la jauge de mailbox.
      log2 = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)
      refute log2 =~ "pod enumeration FAILED"
      refute_received {:incident, "pod_enumeration", _, _}

      # La RECUPERATION se dit : sans elle, un operateur qui a vu l'alerte ne sait pas si c'est
      # resorbe ou si le rail est mort.
      Agent.update(:pods_enum, fn _ -> :ok end)
      log3 = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)
      assert log3 =~ "pod enumeration RECOVERED"
    end

    # BL-6-48 pas 3, moitie PR — le `wait/*` vit sur l'ISSUE, et le chemin PR ne l'a pas en main.
    # La map `issue → wait/*` est threadee depuis les issues deja listees, jumelle d'`awaits_arch_ids`.
    test "chemin PR : une issue qui AWAITS-ARCH ne patiente plus — son wait/* est RETIRE" do
      # Cas reellement atteignable, et semantiquement juste : `lcars-awaits-arch` porte deja
      # l'attente. Laisser `wait/role` a cote serait deux verites pour un fait — et un etat perime.
      issues = [
        %{
          "number" => 21,
          "body" => "x",
          "labels" => [
            %{"name" => Fleet.Labels.awaits_arch()},
            %{"name" => "wait/role"}
          ],
          "assignees" => [%{"login" => "lordzurp"}]
        }
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
      pulls = [%{"number" => 91, "head" => %{"ref" => "refs/pull/6/head"}}]

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
    end

    test "an ENGAGED pipeline (advanced route) holds the lease and blocks a QUEUED issue" do
      # #8: the lease is read from the ROUTE (state-machine), no longer state:*. #11 routed
      # qa-2:deploy (2nd step ≠ 1st = ADVANCED pipeline between two step_runs) → ENGAGED → holds
      # the lease AND its current step is dispatched (continues the step_run). #12 routed
      # qa-build:build (1st step = QUEUED) → lease held → waits.
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

    test "two QUEUED issues -> only one starts, the other waits (lease taken within the tick)" do
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

    test "a ticket in its JURY phase HOLDS the lease — a QUEUED one does not start beside it" do
      # The hole this repairs, and it was open in SERIAL, not revealed by the fan-out: the lease
      # counted only what it saw on its own rail (ENGAGED issues). A ticket that reached its jury
      # leaves the issues side — it is dispatched through the pulls — so it held nothing, and a
      # repo serialized to ONE workflow_run happily started a second.
      issues = [
        # #21 is in its jury phase: an open fleet PR carries it. Skipped on the issues rail (the
        # pulls rail advances it), but it IS in flight.
        %{
          "number" => 21,
          "body" => "en jury",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        },
        # #22 is QUEUED and routeless: with a free lease it would start.
        %{
          "number" => 22,
          "body" => "en attente",
          "labels" => [],
          "assignees" => [%{"login" => "lordzurp"}]
        }
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
      def request_review(_repo, index, reviewers, _opts),
        do: send(self(), {:requested_review, index, reviewers}) && :ok

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

      # issue 42 skip (awaits-arch, decide) + PR 7 skip (threaded awaits_arch) → dispatched:0.
      assert %{dispatched: 0, errors: 0} = Poller.force_poll(name)
      refute_received {:spawned, _, _}

      GenServer.stop(pid)
    end
  end
end
