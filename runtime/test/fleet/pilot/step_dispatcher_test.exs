defmodule Fleet.Pilot.StepDispatcherTest do
  # Serialized: these tests change global catalogue settings and publish persistent images.
  use ExUnit.Case, async: false

  alias Fleet.CapProfile.Image
  alias Fleet.Pilot.StepDispatcher
  alias Fleet.Pilot.StubTaskQueue
  alias Fleet.Test.BizCatalogueFixture
  alias Fleet.Workflow.Loader

  import Fleet.Pilot.DispatcherBench

  alias Fleet.Pilot.DispatcherBench.{
    CountingLoader,
    FailTaskQueue,
    StubForge,
    StubLoader,
    StubLoaderPipe,
    StubSpawner,
    StubSpawnerAlive,
    StubSpawnerPipe,
    WallStubForge
  }

  describe "decide/1 (pure gate)" do
    test "unlocked issue → :engage (role AND spawn/onboard action decided downstream)" do
      assert :engage = StepDispatcher.decide(eng_issue())
    end

    test "lcars-in-flight lock present → {:skip, :in_flight}" do
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-in-flight"}]})
      assert {:skip, :in_flight} = StepDispatcher.decide(payload)
    end

    test "HUMAN lock lcars-awaits-arch → {:skip, :awaits_arch} (A2.3b, no re-dispatch)" do
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-awaits-arch"}]})
      assert {:skip, :awaits_arch} = StepDispatcher.decide(payload)
    end

    test "verrou TOOLCHAIN lcars-awaits-toolchain → {:skip, :awaits_toolchain} — le drain est le re-dispatch" do
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-awaits-toolchain"}]})
      assert {:skip, :awaits_toolchain} = StepDispatcher.decide(payload)
    end

    test "F-C066: stage/merged label → {:skip, :merged} (TERMINAL merged brick, never re-engaged)" do
      # A merged marker prevents duplicate delivery if issue closing failed, independently of in-flight.
      payload = eng_issue(%{"labels" => [%{"name" => "stage/merged"}]})
      assert {:skip, :merged} = StepDispatcher.decide(payload)
    end

    test "stage/retired on an OPEN ticket → {:skip, :retired} — a retirement that could not close never re-dispatches" do
      # 2026-09-23: #12, retired by a supersede whose close was refused (412), was dispatched again
      # once its blocker merged. The stamp comes first now; the dispatcher must honour it alone.
      payload = eng_issue(%{"labels" => [%{"name" => "stage/retired"}]})
      assert {:skip, :retired} = StepDispatcher.decide(payload)
    end
  end

  describe "dispatch_issue/2 (effects, stubbed seams)" do
    test "F075: a single load(role) per dispatch (end of the probe+spawn double-load)" do
      payload = eng_issue()

      assert {:ok, {:spawned, _, "engineer"}} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(loader: CountingLoader))

      # Role resolution passes its loaded profile onward; decide/1 itself loads nothing.
      assert_received {:f075_loaded, "engineer"}
      refute_received {:f075_loaded, _}
    end

    test "spawn: order lock-label → pod (no more comment-lock), returns {:ok, {:spawned, pod, role}}" do
      payload = eng_issue()

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts())

      # Assert the order reaches spawn with its local delivery instructions.
      assert_received {:spawned, "issue-42", opts}
      assert opts[:brief] =~ "fais le hello"

      # Human desktop labels include the ticket number and remain distinct from technical pod ids.
      assert opts[:rc_name] == "lcars-test#42_engineer"

      # Pass the project slug separately so label formatting can change without parser coupling.
      assert opts[:project_slug] == "lcars-test"
      assert opts[:brief] =~ "git commit"

      # The clone hook adds the co-author trailer mechanically; the order must not request it.
      refute opts[:brief] =~ "Co-authored-by"

      # The eng's voice (outgoing info): the brief asks for a `summary` posted on the PR by the system.
      assert opts[:brief] =~ "summary"
      assert opts[:brief] =~ "Ta voix"
      # Blocked_dep: the brief tells the eng to mark `blocked: true` rather than guess/wedge.
      assert opts[:brief] =~ "blocked"

      # Deliver the same order through TaskQueue so the pod does not treat the run as idle bootstrap.
      assert_received {:enqueued, "lordzurp-lcars-test-engineer", attrs}
      assert attrs.brief =~ "fais le hello"
      assert attrs.role == "engineer"

      # Enqueued issue_id is canonical and distinct from pod_id; this assertion does not identify its constructor.
      assert attrs.issue_id == "issue-42"
      # Observe the wake request; the stub does not prove receipt by a pod.
      assert_received {:woke, "lordzurp-lcars-test-engineer"}
    end

    test "CI-01: draining → dispatch_issue = {:skipped, :draining}, NO spawn, NO lock (gate is the flag, not a block)" do
      payload = eng_issue()

      # Inject the drain flag and check absent spawn/enqueue; this stub does not observe add_label.
      assert {:skipped, :draining} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(quiescing?: fn -> true end))

      refute_received {:spawned, _, _}
      refute_received {:enqueued, _, _}

      # Explicit false provides the counterexample independently of global drain state.
      assert {:ok, {:spawned, _pod, "engineer"}} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(quiescing?: fn -> false end))

      assert_received {:spawned, _, _}
    end

    test "GATE slot_scope: engineer (project) already alive → DEFERS :role_busy (serialized, no rebrief)" do
      payload = eng_issue()

      # Partial pod_info lacks activity/readiness fields, so pipe admission conservatively defers.
      assert {:skipped, :role_busy} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(spawner: StubSpawnerAlive))

      assert_received {:pod_info, "lordzurp-lcars-test-engineer"}
      # Observe no spawn, enqueue or wake; this does not cover every possible side effect.
      refute_received {:spawned, _, _}
      refute_received {:enqueued, _, _}
      refute_received {:woke, _}
    end

    test "GATE slot_scope: engineer (project) alive → defers BEFORE lock/enqueue (nothing to compensate)" do
      # The refusing scope gate must not reach enqueue or compensation.
      assert {:skipped, :role_busy} =
               StepDispatcher.dispatch_issue(
                 eng_issue(),
                 dispatch_opts(spawner: StubSpawnerAlive, task_queue: FailTaskQueue)
               )

      refute_received {:removed_label, _}
      refute_received {:killed, _}
      refute_received {:enqueued, _, _}
    end

    test "F181: POST-lock failure (enqueue KO) → lock removed + pod killed (no stuck)" do
      payload = eng_issue()
      opts = dispatch_opts(task_queue: FailTaskQueue)

      assert {:error, {:enqueue_failed, :broker_down}} =
               StepDispatcher.dispatch_issue(payload, opts)

      # Check compensation calls; these stateless spies do not prove physical cleanup.
      assert_received {:spawned, "issue-42", _}
      assert_received {:killed, "lordzurp-lcars-test-engineer"}
      assert_received {:removed_label, "lcars-in-flight"}
    end

    test "CI-10: POST-lock failure + remove_label FAILS → honest 'lock removal FAILED' log, never the 'lock removed' lie" do
      payload = eng_issue()

      opts =
        dispatch_opts(
          task_queue: FailTaskQueue,
          forge_opts: [
            _test_route: {:ok, {"g", "build"}},
            _test_remove_label: {:error, :forge_down}
          ]
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:enqueue_failed, :broker_down}} =
                   StepDispatcher.dispatch_issue(payload, opts)
        end)

      # Removal was attempted and returned an error; scope log assertions to this pod.
      assert_received {:removed_label, "lcars-in-flight"}
      assert log =~ ~r/pod=lordzurp-lcars-test-engineer.*lock removal FAILED/
      refute log =~ ~r/pod=lordzurp-lcars-test-engineer.*\(lock removed/
    end

    # An escalated wake remains a typed error after admission, not a successful spawn result.
    test "MA-17: escalated wake (unreachable pod) → dispatch {:error,{:wake_unreached}}, NOT {:ok,{:spawned}}" do
      payload = eng_issue()

      # Inject recovery's result without executing its incident/forge path.
      escalating_wake = fn _pod_id, _respawn, _opts -> {:error, {:escalated, :dead}} end

      result =
        StepDispatcher.dispatch_issue(
          payload,
          dispatch_opts(wake_recovery: escalating_wake)
        )

      refute match?({:ok, {:spawned, _, _}}, result)

      assert {:error,
              {:wake_unreached, "lordzurp-lcars-test-engineer", "engineer", {:escalated, :dead}}} =
               result

      # Admission is retained after failed wake: no kill or label-removal compensation.
      assert_received {:spawned, "issue-42", _}
      assert_received {:enqueued, "lordzurp-lcars-test-engineer", _}
      refute_received {:removed_label, _}
      refute_received {:killed, _}
    end

    # A successful injected wake retains the normal success result.
    test "MA-17: wake OK → dispatch stays {:ok,{:spawned}} (honest dispatched tally)" do
      payload = eng_issue()
      clean_wake = fn _pod_id, _respawn, _opts -> :ok end

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(wake_recovery: clean_wake))

      refute_received {:removed_label, _}
      refute_received {:killed, _}
    end

    test "skip in_flight: no spawn" do
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-in-flight"}]})

      assert {:skipped, :in_flight} = StepDispatcher.dispatch_issue(payload, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "the step's FACE reaches the resolver as :base_branch — and its absence means code (THE default site)" do
      # The step selects its face; absence defaults here to code before reaching the resolver.
      payload = eng_issue()
      me = self()

      capturing_resolver = fn _repo, r_opts ->
        send(me, {:resolver_base, Keyword.get(r_opts, :base_branch)})
        {:ok, nil}
      end

      ops_loader = fn _name ->
        %{
          # Keep the role constant so the test distinguishes step face from role identity.
          "steps" => %{"build" => %{"role" => "engineer", "face" => "ops", "needs" => []}},
          "max_rework_rounds" => 2
        }
      end

      opts = dispatch_opts(project_resolver: capturing_resolver, workflow_map_loader: ops_loader)
      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts)
      assert_received {:resolver_base, "ops"}

      opts2 = dispatch_opts(project_resolver: capturing_resolver)
      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts2)
      assert_received {:resolver_base, "main"}
    end

    test "a ticket carrying a LOT clones from the lot, and its PR still lands on the FACE" do
      # Lot matter is the clone/gate starting point; the PR still targets the project face.
      sha = String.duplicate("ab", 20)
      me = self()

      payload =
        eng_issue(%{
          "body" => "traite le paquet\n\nLot: lcars/lot-morse-ui-v2 @ #{sha}"
        })

      capturing_resolver = fn _repo, r_opts ->
        send(
          me,
          {:bases, Keyword.get(r_opts, :base_branch), Keyword.get(r_opts, :gate_base_branch)}
        )

        {:ok, %{"base_sha" => sha}}
      end

      opts = dispatch_opts(project_resolver: capturing_resolver)
      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts)

      # Gate checks must exclude supplied matter commits and their author identities.
      assert_received {:bases, "lcars/lot-morse-ui-v2", nil}

      # An explicit destination prevents merging the producer's work back into its lot branch.
      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:project]["pr_base_branch"] == "main"
    end

    test "an ordinary ticket names NO gate base — the lot rail costs the common path nothing" do
      me = self()

      capturing_resolver = fn _repo, r_opts ->
        send(
          me,
          {:bases, Keyword.get(r_opts, :base_branch), Keyword.get(r_opts, :gate_base_branch)}
        )

        {:ok, nil}
      end

      opts = dispatch_opts(project_resolver: capturing_resolver)
      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(eng_issue(), opts)
      assert_received {:bases, "main", nil}
    end

    test "a lot pointer with an out-of-scheme ref STOPS the dispatch, never falls back to the face" do
      # A bad lot pointer must not start work from unrelated face content.
      payload = eng_issue(%{"body" => "Lot: refs/heads/evil @ #{String.duplicate("ab", 20)}"})

      opts = dispatch_opts(project_resolver: fn _repo, _o -> {:ok, nil} end)

      assert {:error, {:lot_pointer, {:invalid_lot_ref, "refs/heads/evil"}}} =
               StepDispatcher.dispatch_issue(payload, opts)
    end

    test "a lot branch that MOVED since the ticket was written → refused, the pinned sha is an anchor" do
      # A reused lot name must not make an older ticket consume newer matter.
      pinned = String.duplicate("ab", 20)
      moved = String.duplicate("cd", 20)
      payload = eng_issue(%{"body" => "Lot: lcars/lot-paquet-3 @ #{pinned}"})

      opts = dispatch_opts(project_resolver: fn _repo, _o -> {:ok, %{"base_sha" => moved}} end)

      assert {:error, {:lot_moved, {"lcars/lot-paquet-3", ^pinned, ^moved}}} =
               StepDispatcher.dispatch_issue(payload, opts)
    end

    # ⚠ SANS `:repo` DANS SES OPTS, UN PRODUCTEUR EST NE SANS DEPOT. `Spawner.pod_info/1` ne rend
    # que `Keyword.get(data.opts, :repo)`, et c'est CE champ que les outils MCP lisent : sans lui,
    # `request_toolchain` refuse en `:pod_repo_unbound`. Mesure du 2026-09-19, banc 2005 : le rail
    # d'outillage n'avait jamais ete parcouru parce qu'il ne POUVAIT pas l'etre. Le depot voyageait
    # bien jusqu'au dispatcher — il ne montait simplement pas dans le pod.
    test "le pod nait LIE a son depot : `:repo` est dans ses opts" do
      payload = eng_issue()

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts())

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:repo] == "lordzurp/lcars-test"
      # Le slug reste derive, il ne remplace pas le depot : deux faits, deux champs.
      assert spawn_opts[:project_slug] == "lcars-test"
    end

    test "resolved project → injected into spawn_opts (:project, F-03 pinned base_sha)" do
      payload = eng_issue()

      project = %{
        "repo_path" => "http://192.0.2.10/lordzurp/lcars-test.git",
        "base_branch" => "main",
        "base_sha" => "cafe1234"
      }

      opts = dispatch_opts(project_resolver: fn _repo, _opts -> {:ok, project} end)

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:project] == project
      assert spawn_opts[:brief] =~ "fais le hello"
    end

    test "recorded route → role derived from the workflow_map (step build=engineer) + pipeline/step injected (A2.1, #8)" do
      payload = eng_issue()

      workflow_map = %{
        "name" => "poc-cycle",
        "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"poc-cycle", "build"}}],
          workflow_map_loader: fn "poc-cycle" -> workflow_map end
        )

      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:workflow_map] == "poc-cycle"
      assert spawn_opts[:step] == "build"
    end

    test "#8: route on an UPSTREAM step (brief-review/consultant) → spawns the CONSULTANT, not the eng" do
      payload = eng_issue()

      # The routed step selects consultant; decide/1 only permits engagement.
      workflow_map = %{
        "name" => "brief-gate",
        "steps" => %{
          "brief-review" => %{"role" => "consultant", "needs" => []},
          "build" => %{"role" => "engineer", "needs" => ["brief-review"]}
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"brief-gate", "brief-review"}}],
          workflow_map_loader: fn "brief-gate" -> workflow_map end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-issue-42-consultant", "consultant"}} =
               StepDispatcher.dispatch_issue(payload, opts)
    end

    test "#8.B: brief_kind:judge AT THE STEP overrides a worker profile (engineer) → JUDGE brief" do
      payload = eng_issue()

      # Step judge override must suppress the worker delivery section.
      workflow_map = %{
        "name" => "g",
        "steps" => %{
          "review" => %{"role" => "engineer", "needs" => [], "brief_kind" => "judge"}
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"g", "review"}}],
          workflow_map_loader: fn "g" -> workflow_map end
        )

      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts)
      assert_received {:spawned, "issue-42", spawn_opts}
      refute spawn_opts[:brief] =~ "Livraison (git-native)"
    end

    test "#8.B: without brief_kind at the step → profile default (engineer=worker → worker brief)" do
      payload = eng_issue()

      workflow_map = %{
        "name" => "g",
        "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"g", "build"}}],
          workflow_map_loader: fn "g" -> workflow_map end
        )

      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts)
      assert_received {:spawned, "issue-42", spawn_opts}
      # "Livraison (git-native)" pins the FR user-facing brief section heading.
      assert spawn_opts[:brief] =~ "Livraison (git-native)"
    end

    test "SECURITY: out-of-vocab brief_kind at the step → raise (never silently falls back to worker)" do
      payload = eng_issue()

      # Unknown kinds must raise instead of silently supplying an executable worker order.
      workflow_map = %{
        "name" => "g",
        "steps" => %{
          "review" => %{"role" => "engineer", "needs" => [], "brief_kind" => "reviewer"}
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"g", "review"}}],
          workflow_map_loader: fn "g" -> workflow_map end
        )

      assert_raise ArgumentError, ~r/out of vocabulary \{worker, judge\}/, fn ->
        StepDispatcher.dispatch_issue(payload, opts)
      end
    end

    test "SECURITY: out-of-vocab judge_target (kind=judge) → raise (a judge's target is not inferred)" do
      payload = eng_issue()

      workflow_map = %{
        "name" => "g",
        "steps" => %{
          "review" => %{
            "role" => "engineer",
            "needs" => [],
            "brief_kind" => "judge",
            "judge_target" => "subject"
          }
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"g", "review"}}],
          workflow_map_loader: fn "g" -> workflow_map end
        )

      assert_raise ArgumentError, ~r/out of vocabulary \{brief, deliverable\}/, fn ->
        StepDispatcher.dispatch_issue(payload, opts)
      end
    end

    test "#8.E: judge_target:brief → brief in BRIEF framing (judges the issue.body, not a deliverable)" do
      # Distinct in-hand text verifies that brief judgment consumes the entry issue.
      payload = eng_issue(%{"body" => "MON BRIEF A JUGER"})

      workflow_map = %{
        "name" => "mg",
        "steps" => %{
          "brief-review" => %{
            "role" => "consultant",
            "needs" => [],
            "brief_kind" => "judge",
            "judge_target" => "brief"
          }
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"mg", "brief-review"}}],
          workflow_map_loader: fn "mg" -> workflow_map end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-issue-42-consultant", "consultant"}} =
               StepDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      brief = spawn_opts[:brief]

      assert brief =~ "Brief to judge"
      assert brief =~ "MON BRIEF A JUGER"
      refute brief =~ "Deliverable to judge (step outputs"
      refute brief =~ "Livraison (git-native)"
    end

    test "#5.2 D2 — ROUTELESS issue → onboarded onto the default workflow_map (skip), NO eng spawn" do
      payload = eng_issue()

      opts =
        dispatch_opts(
          forge_opts: [_test_route: :none],
          workflow_map_loader: fn "brief-gate" ->
            %{"steps" => %{"brief-review" => %{"role" => "consultant", "needs" => []}}}
          end
        )

      assert {:skipped, :onboarded} = StepDispatcher.dispatch_issue(payload, opts)

      # Observe route posting without spawning in this dispatch.
      assert_received {:routed, 42, "brief-gate", "brief-review"}
      refute_received {:spawned, _, _}
    end

    test "ROUTELESS issue with `genre/doc` → onboarded onto the OPS card, not the project's (chantier face-projet)" do
      # Workshop destination determines the route for this unrouted issue.
      payload = eng_issue(%{"labels" => [%{"name" => "destination/workshop"}]})

      opts =
        dispatch_opts(
          forge_opts: [_test_route: :none],
          workflow_map_loader: fn "workshop-direct" ->
            %{"steps" => %{"build" => %{"role" => "engineer", "face" => "ops", "needs" => []}}}
          end
        )

      assert {:skipped, :onboarded} = StepDispatcher.dispatch_issue(payload, opts)
      assert_received {:routed, 42, "workshop-direct", "build"}
      refute_received {:spawned, _, _}
    end

    test "6-125: a DECLARED card the catalogue no longer serves → no route posted, and a DURABLE incident" do
      # An unavailable declared card must not be replaced when writing a route.
      # This fixture observes the incident call, not durable registry storage.
      payload = eng_issue()

      opts =
        dispatch_opts(
          forge_opts: [_test_route: :none],
          workflow_map_loader: fn _name ->
            raise File.Error, reason: :enoent, action: "read file", path: "gone.yaml"
          end,
          incident_fun: fn op, subject, reason, o ->
            send(self(), {:incident, op, subject, reason, o[:reason_detail]})
            :recorded
          end
        )

      assert {:error, {:onboard, {:error, {:workflow_map_load_failed, name, _}}}} =
               StepDispatcher.dispatch_issue(payload, opts)

      refute_received {:routed, _, _, _}
      refute_received {:spawned, _, _}

      assert_received {:incident, "card", _repo, :declared_card_unloadable, detail}
      # Identify the missing card in the incident detail.
      assert detail =~ name
    end

    @tag :tmp_dir
    test "un catalogue SANS rail doc → aucune route, et un incident DURABLE", %{tmp_dir: tmp} do
      # A catalogue with no workshop producer supplies the missing-rail counterexample.
      # Incident persistence is outside this injected callback's scope.
      maps = Path.join(tmp, Fleet.Catalogue.rel(:workflow_maps))
      File.mkdir_p!(maps)
      File.write!(Path.join(tmp, "catalogue.yaml"), "api_version: 1\nname: sans-atelier\n")

      File.write!(Path.join(maps, "brief-gate.yaml"), """
      kind: WorkflowMap
      metadata:
        name: brief-gate
      spec:
        max_rework_rounds: 1
        jury: []
        ci: ignore
        steps:
          only:
            role: engineer
      """)

      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_root, tmp)

      payload = eng_issue(%{"labels" => [%{"name" => "destination/workshop"}]})

      opts =
        dispatch_opts(
          forge_opts: [_test_route: :none],
          incident_fun: fn op, subject, reason, o ->
            send(self(), {:incident, op, subject, reason, o[:reason_detail]})
            :recorded
          end
        )

      assert {:error, {:onboard, {:error, :no_doc_rail_in_catalogue}}} =
               StepDispatcher.dispatch_issue(payload, opts)

      refute_received {:routed, _, _, _}
      refute_received {:spawned, _, _}

      # Check the shared op and distinct reason; IncidentRegistry also includes reason in its signature.
      assert_received {:incident, "card", _repo, :no_doc_rail_in_catalogue, detail}
      assert detail =~ "rail doc"
    end

    test "route read failure → {:error, {:route_resolution, _}}, NO lock nor spawn" do
      payload = eng_issue()
      opts = dispatch_opts(forge_opts: [_test_route: {:error, :http_500}])

      assert {:error, {:route_resolution, :http_500}} =
               StepDispatcher.dispatch_issue(payload, opts)

      refute_received {:spawned, _, _}
    end

    test "project resolution failure → {:error}, NO lock set nor spawn" do
      payload = eng_issue()

      opts =
        dispatch_opts(project_resolver: fn _repo, _opts -> {:error, :ls_remote_timeout} end)

      assert {:error, {:project_resolution, :ls_remote_timeout}} =
               StepDispatcher.dispatch_issue(payload, opts)

      # This fixture verifies absence of spawn, not absence of every forge write.
      refute_received {:spawned, _, _}
    end

    # Pipe fixtures distinguish absent, busy, publishing and ready states before reset/rebrief.
    test "GATE pipe DEAD (1st issue): fresh spawn, NO reprovision" do
      Process.put(:pipe_state, :dead)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(eng_issue(), opts)

      assert_received {:spawned, "issue-42", _opts}
      refute_received {:reprovisioned, _, _, _}
    end

    test "GATE pipe BUSY (active task): DEFERS :role_busy, neither reprovision nor spawn (pod mid-work)" do
      Process.put(:pipe_state, :busy_active)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:skipped, :role_busy} = StepDispatcher.dispatch_issue(eng_issue(), opts)

      refute_received {:reprovisioned, _, _, _}
      refute_received {:spawned, _, _}
    end

    test "GATE pipe PUBLISHING (deliverable in flight): DEFERS :role_busy (no reset during the push)" do
      Process.put(:pipe_state, :publishing)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:skipped, :role_busy} = StepDispatcher.dispatch_issue(eng_issue(), opts)

      refute_received {:reprovisioned, _, _, _}
      refute_received {:spawned, _, _}
    end

    test "GATE pipe READY (idle + deliverable confirmed): COLD reprovision (base_sha + slug) THEN re-brief" do
      Process.put(:pipe_state, :ready)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(eng_issue(), opts)

      # Check reset arguments; selective receipt does not prove ordering relative to enqueue.
      assert_received {:reprovisioned, "lordzurp-lcars-test-engineer",
                       %{"base_sha" => "basesha1"}, [slug: _slug]}

      refute_received {:spawned, _, _}
      assert_received {:enqueued, "lordzurp-lcars-test-engineer", _}
      assert_received {:woke, "lordzurp-lcars-test-engineer"}
    end

    test "GATE pipe READY but reset KO -> DEFERS :role_busy (no rebrief on a dirty workspace)" do
      Process.put(:pipe_state, :ready)
      Process.put(:reprovision_result, {:error, {:reset_failed, :git_exit}})

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:skipped, :role_busy} = StepDispatcher.dispatch_issue(eng_issue(), opts)

      assert_received {:reprovisioned, _, _, _}
      refute_received {:enqueued, _, _}
      refute_received {:spawned, _, _}
    end

    test "GATE pipe pod_info RAISES (transient probe failure on a LIVE pipe): DEFERS :role_busy, NO destructive spawn (F-C059)" do
      # A raised probe is uncertainty, not evidence of absence that permits replacement.
      Process.put(:pipe_state, :raise)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:skipped, :role_busy} = StepDispatcher.dispatch_issue(eng_issue(), opts)

      refute_received {:reprovisioned, _, _, _}
      refute_received {:spawned, _, _}
    end

    test "GATE pipe pod_info UNREACHABLE (info call timed out, pod maybe ALIVE): DEFERS :role_busy, NO destructive spawn" do
      # Timeout must defer rather than treating a possibly living pipe as absent.
      Process.put(:pipe_state, :unreachable)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:skipped, :role_busy} = StepDispatcher.dispatch_issue(eng_issue(), opts)

      refute_received {:reprovisioned, _, _, _}
      refute_received {:spawned, _, _}
    end
  end

  describe "dispatch_review/2 — the PR gate, the judge, the adoption and the promotion" do
    @tag :tmp_dir
    @tag :requires_git
    test "provenance INCOHÉRENTE au sceau → escalade à l'architecte, pas une retentative muette à chaque tick",
         %{tmp_dir: tmp} do
      # Supply the chief token to reach the provenance check; an unrelated base must route to escalation.
      Fleet.TestEnv.put_role_token!("chief", "CHIEF-TOKEN")
      %{head: head, alien: alien} = Fleet.Test.ProvenanceWallHarness.harness(tmp, "lcars-test")
      :ok = Fleet.Test.ProvenanceWallHarness.statement(tmp, 42, head, alien, "lcars-test")

      opts =
        dispatch_opts(
          forge_client: WallStubForge,
          code_root: Path.join(tmp, "p"),
          ops_root: Path.join(tmp, "w"),
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved},
            _test_route: {:ok, {"g", "build"}},
            __head_sha__: head
          ]
        )

      assert {:skipped, {:merge_blocked_escalated, 6}} =
               StepDispatcher.dispatch_review(pr(), opts)

      assert_received {:merge_blocked_escalation, 42, body}
      assert body =~ "PROVENANCE"
      refute body =~ "non classifié"
      refute_received {:merged, _}
    end

    @tag :tmp_dir
    test "no_jury : la carte ADOPTÉE sur une PR orpheline est celle du catalogue DU PROJET, lue par le loader par défaut",
         %{tmp_dir: tmp} do
      # Exercise the binary default loader with a card in biz; deleting it would test only a fixture loader.
      %{install_dir: dir} = BizCatalogueFixture.write!(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [dir])
      :ok = Image.publish!()
      :ok = Loader.publish_image!()

      on_exit(fn ->
        Image.unpublish()
        Loader.unpublish_all_images()
      end)

      judge = BizCatalogueFixture.judge()

      # A jury-less project default makes a wrong-catalogue fallback distinguishable from biz's engraved jury.
      code_root = Path.join(tmp, "projects")
      BizCatalogueFixture.declare_project!(code_root, "boutique", "no-jury")

      opts =
        dispatch_opts(
          repo: "biz/boutique",
          code_root: code_root,
          forge_opts: [_test_route: {:ok, {"standard", "build"}}]
        )
        |> Keyword.delete(:workflow_map_loader)

      assert {:ok, {:adopted, 6, [^judge]}} =
               StepDispatcher.dispatch_review(pr(%{"requested_reviewers" => []}), opts)

      assert_received {:requested_review, 6, [^judge]}
    end

    @tag :tmp_dir
    test "the jury and the CI policy of a PR are read off ONE card: the engraved one, else the project's",
         %{tmp_dir: tmp} do
      # Strict and no-jury differ in both jury and CI; each reader must select the same applicable card.
      %{install_dir: dir} = BizCatalogueFixture.write!(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [dir])
      :ok = Image.publish!()
      :ok = Loader.publish_image!()

      on_exit(fn ->
        Image.unpublish()
        Loader.unpublish_all_images()
      end)

      judge = BizCatalogueFixture.judge()
      code_root = Path.join(tmp, "projects")
      BizCatalogueFixture.declare_project!(code_root, "boutique", "no-jury")

      ctx = fn route ->
        %Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx{
          forge: StubForge,
          loader: StubLoader,
          workflow_map_loader: &Loader.load!/2,
          spawner: StubSpawner,
          task_queue: StubTaskQueue,
          resolver: fn _r, _o -> {:ok, nil} end,
          repo: "biz/boutique",
          forge_opts: [_test_route: route],
          wake_recovery: &Fleet.Pilot.WakeRecovery.wake/3,
          opts: [code_root: code_root, repo: "biz/boutique"]
        }
      end

      alias Fleet.Pilot.StepDispatcher.ReviewLifecycle
      head = "lcars/issue-42-engineer"

      engraved = ctx.({:ok, {"strict", "build"}})
      assert ReviewLifecycle.issue_card_ci(head, engraved) == :required
      assert ReviewLifecycle.issue_card_jury_of(head, engraved) == [judge]

      routeless = ctx.(:none)
      assert ReviewLifecycle.issue_card_ci(head, routeless) == :ignore
      assert ReviewLifecycle.issue_card_jury_of(head, routeless) == []
    end

    test "PR with review requested -> spawns the judge (issue=ISSUE, lock on the PR)" do
      opts =
        dispatch_opts(
          forge_opts: [
            _test_route: {:ok, {"poc", "spec-review"}},
            _test_issue_body: "implémente le décodeur morse"
          ]
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-pr-6-qualifier", "qualifier"}} =
               StepDispatcher.dispatch_review(pr(), opts)

      # issue_id = the ISSUE (derived from head.ref lcars/issue-42-engineer), NOT the PR
      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:workflow_map] == "poc" and spawn_opts[:step] == "spec-review"

      assert spawn_opts[:brief] =~ "JUDGE"

      # A single-branch review clone lacks origin/main; instructions must use bootstrap's lcars/base.
      # The criterion must also reach the order.
      assert spawn_opts[:brief] =~ "git diff lcars/base...HEAD"
      refute spawn_opts[:brief] =~ "origin/main"
      assert spawn_opts[:brief] =~ "implémente le décodeur morse"

      # enqueue targets the pr-... pod_id; issue_id = the issue
      assert_received {:enqueued, "lordzurp-lcars-test-pr-6-qualifier", attrs}
      assert attrs.issue_id == "issue-42"
      assert attrs.role == "qualifier"
      assert_received {:woke, "lordzurp-lcars-test-pr-6-qualifier"}
    end

    test "PR judge with a Criteria: pointer → spawn_opts[:mandate] carries the mount (the fix, tested end-to-end)" do
      # A real criteria pointer makes dropped :mandate observable at the spawner seam.
      # This checks argument propagation, not physical mount creation.
      ops = Fleet.TestEnv.tmp_path("ops")
      work_dir = Path.join(ops, "lcars-test")
      File.mkdir_p!(Path.join(work_dir, "gate-briefs"))
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)
      {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.email", "h@l"])
      {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.name", "H"])
      File.write!(Path.join([work_dir, "gate-briefs", "crit.md"]), "L'ATTENDU")
      {_, 0} = System.cmd("git", ["-C", work_dir, "add", "."])
      {_, 0} = System.cmd("git", ["-C", work_dir, "commit", "-q", "-m", "criteria"])
      {sha, 0} = System.cmd("git", ["-C", work_dir, "rev-parse", "HEAD"])
      sha = String.trim(sha)
      on_exit(fn -> File.rm_rf(ops) end)

      body =
        "résumé\n\n" <>
          Fleet.Layout.criteria_pointer_line("gate-briefs/crit.md", sha, "acme/widget")

      opts =
        dispatch_opts(
          ops_root: ops,
          forge_opts: [_test_route: {:ok, {"poc", "spec-review"}}, _test_issue_body: body]
        )

      assert {:ok, {:spawned, _, "qualifier"}} = StepDispatcher.dispatch_review(pr(), opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      # The consumer half: role_dispatch put the mount build_brief surfaced into spawn_opts.
      assert %{ref: "gate-briefs/crit.md", sha: ^sha, ops_path: ops_path} = spawn_opts[:mandate]
      assert String.ends_with?(ops_path, "/lcars-test")
    end

    test "locked PR (lcars-in-flight) -> skip, no spawn" do
      pr = pr(%{"labels" => [%{"name" => "lcars-in-flight"}]})
      assert {:skipped, :in_flight} = StepDispatcher.dispatch_review(pr, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "PR without judge (orphan/human) -> ADOPTION: sets the judges, review next tick" do
      pr = pr(%{"requested_reviewers" => []})

      # With no observed jury, adopt the card's reviewers without spawning in this call.
      assert {:ok, {:adopted, _pr_number, reviewers}} =
               StepDispatcher.dispatch_review(pr, dispatch_opts())

      assert reviewers != []
      assert_received {:requested_review, _index, ^reviewers}
      refute_received {:spawned, _, _}
    end

    test "ZERO-JUDGE card (jury []) + no requested judge → NOMINAL sealed merge, NOT adoption" do
      # An explicitly empty jury permits merge without adoption; this stub skips the provenance-capability check.
      pr = pr(%{"requested_reviewers" => [], "number" => 6})

      assert {:ok, {:merged, 6}} =
               StepDispatcher.dispatch_review(pr, dispatch_opts(reviewer_roles: []))

      assert_received {:merged, 6}
      refute_received {:requested_review, _, _}
      refute_received {:spawned, _, _}
    end

    test "②.1d: all requested judges APPROVED -> PROMOTE (closing comment + FF merge, gatekeeper)" do
      # both requested judges each have a decisive APPROVED verdict → empty pending → all green → merge.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [_test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved}]
        )

      assert {:ok, {:merged, 6}} = StepDispatcher.dispatch_review(pr, opts)

      # Observe the merge call, without asserting Git strategy or actual closing.
      assert_received {:merged, 6}
      refute_received {:spawned, _, _}

      # Kill targets the completed issue id; targeting the shared project pod could kill another task.
      # The spy proves only the requested id, not whether a pod existed there.
      assert_received {:killed, "lordzurp-lcars-test-issue-42-engineer"}

      # Stopwatch target must be the parent issue; this spy does not prove label removal.
      assert_received {:stopped_watch, 42}
    end

    test "CI-08: promote unlock FAILS → honest 'issue lock NOT released' log (never the lie) + retry, still {:ok, {:merged}}" do
      # Merge success survives terminal unlock failure, which must be logged and retried.
      # Closed issues disappear from open-item polling, so that poll cannot repair their residual lock.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_remove_label: {:error, :forge_down}
          ]
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, {:merged, 6}} = StepDispatcher.dispatch_review(pr, opts)
        end)

      assert_received {:merged, 6}

      # Scope the expected failure log to this issue.
      assert log =~ "issue=#42 MERGED+SEALED+CLOSED but issue lock NOT released"
      # Assert the first failed attempt's log; this does not count all retries.
      assert log =~ "issue #42 unlock attempt 1/3 FAILED"

      refute log =~ "eng killed, issue lock released"
    end

    # A closed issue's residual lock has no automatic poller/warden cleanup.
    # The incident callback exposes this condition; the fixture does not prove durable persistence.
    test "JG-063: un verrou residuel ouvre un INCIDENT durable, et le log ne promet plus de rail" do
      test = self()

      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          escalate_fun: fn kind, subject, cause, sig, _o ->
            send(test, {:escalated, kind, subject, cause, sig})
            {:ok, 1}
          end,
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_remove_label: {:error, :forge_down}
          ]
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, {:merged, 6}} = StepDispatcher.dispatch_review(pr, opts)
        end)

      assert_received {:escalated, :issue_lock_residual, _subject, {:unlock_failed, _}, _sig},
                      "le verrou residuel n'a laisse qu'un log : rien de durable ne le dit"

      refute log =~ "warden/manual cleanup",
             "le log promet toujours un rail de rattrapage qui n'existe pas"

      assert log =~ "the cleanup is MANUAL: no rail reclaims it"
    end

    test "F-C061: a NON-jury login (human) among the reviewers is filtered (does not starve the jury) + LOUD" do
      # A pending non-jury account must not starve a fully approved jury.
      pr =
        pr(%{
          "requested_reviewers" => [
            %{"login" => "Qualifier"},
            %{"login" => "Reviewer"},
            %{"login" => "Lordzurp"}
          ],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [_test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved}]
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, {:merged, 6}} = StepDispatcher.dispatch_review(pr, opts)
        end)

      assert log =~ "F-C061" and log =~ "lordzurp"

      refute_received {:spawned, _, "lordzurp"}
    end

    test "F-C061: a REQUEST_CHANGES from a NON-jury login (human) does NOT trigger a stray rework" do
      # Non-jury changes-requested verdicts must not trigger rework.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_reviewers: ["qualifier", "reviewer", "lordzurp"],
            _test_verdicts: %{
              "qualifier" => :approved,
              "reviewer" => :approved,
              "lordzurp" => :changes_requested
            }
          ]
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, {:merged, 6}} = StepDispatcher.dispatch_review(pr, opts)
        end)

      assert log =~ "F-C061" and log =~ "lordzurp"
      refute_received {:spawned, _, "reviewer"}
    end

    test "PR flipped back to DRAFT (judge-dispatch guard) → skip, no review nor merge" do
      pr =
        pr(%{
          "number" => 6,
          "draft" => true,
          "requested_reviewers" => [%{"login" => "Qualifier"}]
        })

      assert {:skipped, :draft} = StepDispatcher.dispatch_review(pr, dispatch_opts())
      refute_received {:spawned, _, _}
      refute_received {:merged, _}
    end

    test "F-E8: judge dropped from requested_reviewers (but in the review-records) stays in the jury -> spawn, NO merge" do
      # Union stable review records with requested reviewers so a vanished pending request cannot enable merge.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved},
            _test_reviewers: ["qualifier", "reviewer"],
            _test_route: {:ok, {"poc", "review"}},
            _test_issue_body: "implémente le décodeur morse"
          ]
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-pr-6-reviewer", "reviewer"}} =
               StepDispatcher.dispatch_review(pr, opts)

      refute_received {:merged, _}
    end

    test "PR on a non-fleet branch -> skip (never misrouted)" do
      pr = pr(%{"head" => %{"ref" => "refs/pull/6/head"}})
      assert {:skipped, :not_fleet_branch} = StepDispatcher.dispatch_review(pr, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "F-C061: reviewer = non-jury login (human/unknown) ALONE → filtered + LOUD, NO silent skip" do
      # Filtering the only foreign request leaves no observed jury and must allow adoption.
      pr = pr(%{"requested_reviewers" => [%{"login" => "lordzurp"}]})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, {:adopted, _pr_number, reviewers}} =
                   StepDispatcher.dispatch_review(pr, dispatch_opts())

          assert reviewers != []
        end)

      assert log =~ "F-C061" and log =~ "lordzurp"
      refute_received {:spawned, _, "lordzurp"}
    end

    test "F181: POST-lock failure (enqueue KO) -> PR lock removed + pod killed" do
      # Successful CI is a premise allowing this test to reach the enqueue failure.
      opts =
        dispatch_opts(
          task_queue: FailTaskQueue,
          forge_opts: [_test_route: :none, _test_ci: :success]
        )

      assert {:error, {:enqueue_failed, :broker_down}} =
               StepDispatcher.dispatch_review(pr(), opts)

      assert_received {:killed, "lordzurp-lcars-test-pr-6-qualifier"}
      assert_received {:removed_label, "lcars-in-flight"}
    end

    test "MA-01 (bug B): the parent issue carries awaits-arch -> skip :awaits_arch, NO judge re-dispatch" do
      # Caller-supplied parent wait state suppresses PR dispatch.
      opts = dispatch_opts(awaits_arch_ids: MapSet.new([42]))

      assert {:skipped, :awaits_arch} = StepDispatcher.dispatch_review(pr(), opts)
      refute_received {:spawned, _, _}
      refute_received {:enqueued, _, _}
    end

    test "MA-01 (bug B): awaits_arch_ids does NOT contain the issue -> normal dispatch (back-compat)" do
      # Waiting on another issue must not suppress this one.
      opts =
        dispatch_opts(
          awaits_arch_ids: MapSet.new([99]),
          forge_opts: [_test_route: {:ok, {"poc", "spec-review"}}, _test_issue_body: "x"]
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-pr-6-qualifier", "qualifier"}} =
               StepDispatcher.dispatch_review(pr(), opts)
    end
  end

  describe "default_project_resolver/2 — deconflated gate_base_sha" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      forge = Path.join(tmp, "forge")
      src = Path.join(tmp, "src")
      File.mkdir_p!(forge)
      gg = fn args -> {_o, 0} = System.cmd("git", ["-C", src] ++ args, stderr_to_stdout: true) end

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", src], stderr_to_stdout: true)
      gg.(["config", "user.email", "engineer@lcars.local"])
      gg.(["config", "user.name", "LCARS-engineer"])
      File.write!(Path.join(src, "base.txt"), "c0")
      gg.(["add", "."])
      gg.(["commit", "-q", "-m", "c0"])

      # feature-branch (the producer's work, from C0)
      gg.(["checkout", "-q", "-b", "lcars/issue-3-engineer"])
      File.write!(Path.join(src, "feat.txt"), "feat")
      gg.(["add", "."])
      gg.(["commit", "-q", "-m", "feat"])
      {ft, 0} = System.cmd("git", ["-C", src, "rev-parse", "HEAD"], stderr_to_stdout: true)

      # `main` advances (parallel issue merged) → C1
      gg.(["checkout", "-q", "main"])
      File.write!(Path.join(src, "para.txt"), "para")
      gg.(["add", "."])
      gg.(["commit", "-q", "-m", "c1"])
      {m1, 0} = System.cmd("git", ["-C", src, "rev-parse", "HEAD"], stderr_to_stdout: true)

      # publish both branches into the bare = `<forge>/owner/proj.git` (base_url = `<forge>`)
      bare = Path.join(forge, "owner/proj.git")
      File.mkdir_p!(Path.dirname(bare))
      {_, 0} = System.cmd("git", ["clone", "-q", "--bare", src, bare], stderr_to_stdout: true)

      %{base_url: forge, feature_tip: String.trim(ft), main_c1: String.trim(m1)}
    end

    test "resolve (gate_base_branch=main): base_sha=feature_tip (clone) BUT gate_base_sha=main",
         ctx do
      assert {:ok, proj} =
               StepDispatcher.default_project_resolver("owner/proj",
                 base_branch: "lcars/issue-3-engineer",
                 gate_base_branch: "main",
                 forge_opts: [base_url: ctx.base_url]
               )

      # clone-base = feature tip (the pod starts from ITS work); gate-base = main (rebase target).
      assert proj["base_sha"] == ctx.feature_tip
      assert proj["gate_base_sha"] == ctx.main_c1
      refute proj["base_sha"] == proj["gate_base_sha"]
    end

    test "forward (without gate_base_branch): gate_base_sha == base_sha (clone-base, unchanged)",
         ctx do
      assert {:ok, proj} =
               StepDispatcher.default_project_resolver("owner/proj",
                 base_branch: "lcars/issue-3-engineer",
                 forge_opts: [base_url: ctx.base_url]
               )

      assert proj["base_sha"] == ctx.feature_tip
      assert proj["gate_base_sha"] == proj["base_sha"]
    end

    test "gate_base_branch EGAL a base_branch : une seule lecture, pas deux (BL-6-40 ampli 3)",
         ctx do
      # This stable fixture checks equal pins, not call count: two reads could also return equal SHAs.
      assert {:ok, proj} =
               StepDispatcher.default_project_resolver("owner/proj",
                 base_branch: "main",
                 gate_base_branch: "main",
                 forge_opts: [base_url: ctx.base_url]
               )

      assert proj["base_sha"] == ctx.main_c1
      assert proj["gate_base_sha"] == proj["base_sha"]
    end
  end
end
