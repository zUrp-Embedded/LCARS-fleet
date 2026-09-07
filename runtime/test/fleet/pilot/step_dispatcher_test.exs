defmodule Fleet.Pilot.StepDispatcherTest do
  # ⚠ `async: false` : ce fichier ECRIT `:catalogue_root` / `:catalogue_install_dirs` en env
  # d'APPLICATION et publie les images (fixture biz), etat global au node. Pendant la fenetre —
  # restauration `on_exit` comprise — tout test concurrent qui lit ces cles lit la valeur de
  # celui-ci ; la mesure de cette classe de collision est chez `merge_failure_dispatch_test`.
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepDispatcher
  alias Fleet.Pilot.StubTaskQueue

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
      # Re-dispatcher un ticket dont la demande d'outillage est en vol relancerait un pod voue au
      # meme mur. Le reconciliateur retire le verrou au merge OU a la fermeture de la PR (B3).
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-awaits-toolchain"}]})
      assert {:skip, :awaits_toolchain} = StepDispatcher.decide(payload)
    end

    test "F-C066: stage/merged label → {:skip, :merged} (TERMINAL merged brick, never re-engaged)" do
      # A merged brick whose explicit close failed (issue left OPEN, lock possibly reclaimed by the
      # reconciliation) must NOT be re-dispatched → otherwise double-delivery. The `stage/merged`
      # label (set BEFORE the close) is the DURABLE guard, independent of the lcars-in-flight lock.
      payload = eng_issue(%{"labels" => [%{"name" => "stage/merged"}]})
      assert {:skip, :merged} = StepDispatcher.decide(payload)
    end
  end

  describe "dispatch_issue/2 (effects, stubbed seams)" do
    test "F075: a single load(role) per dispatch (end of the probe+spawn double-load)" do
      payload = eng_issue()

      assert {:ok, {:spawned, _, "engineer"}} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(loader: CountingLoader))

      # decide loads the profile and threads it; dispatch reuses it → load called EXACTLY once.
      assert_received {:f075_loaded, "engineer"}
      refute_received {:f075_loaded, _}
    end

    test "spawn: order lock-label → pod (no more comment-lock), returns {:ok, {:spawned, pod, role}}" do
      payload = eng_issue()

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts())

      # the brief = issue.body + the git-native DELIVERY instruction (local commit + trailer),
      # otherwise the pod "submits the contents" instead of committing → :no_deliverable_commit.
      assert_received {:spawned, "issue-42", opts}
      assert opts[:brief] =~ "fais le hello"

      # pod-seed: RC Desktop name = <project>#<ticket>_<role> (project = final segment of the repo
      # "lordzurp/lcars-test"). Exact label, distinct from the technical pod_id. With one eng per
      # ticket, the project alone no longer distinguishes two live pods of the same role — the
      # number is what the human reads to tell them apart in the Desktop list.
      assert opts[:rc_name] == "lcars-test#42_engineer"

      # …and the slug travels ALONGSIDE the label, never re-parsed out of it (see `project_slug`
      # below): that is what keeps the label free to change shape.
      assert opts[:project_slug] == "lcars-test"
      assert opts[:brief] =~ "git commit"

      # AUCUN trailer dans l'ordre de mission (2026-08-05). Il est pose MECANIQUEMENT par le hook
      # `prepare-commit-msg` installe au clone, donc le pod n'a aucune action a prendre dessus — et
      # ce sur quoi il n'a pas d'action n'a pas a exister dans son monde. L'ordre le DEMANDAIT (un
      # run de producteur refait le jour ou une ligne a atterri au milieu du message), puis l'a
      # brievement ANNONCE, ce qui etait la meme faute un cran plus discret.
      refute opts[:brief] =~ "Co-authored-by"

      # The eng's voice (outgoing info): the brief asks for a `summary` posted on the PR by the system.
      assert opts[:brief] =~ "summary"
      assert opts[:brief] =~ "Ta voix"
      # Blocked_dep: the brief tells the eng to mark `blocked: true` rather than guess/wedge.
      assert opts[:brief] =~ "blocked"

      # the brief is ENQUEUED in the TaskQueue (otherwise the pod thinks it's bootstrap → idle;
      # PASSE-9 bug)
      assert_received {:enqueued, "lordzurp-lcars-test-engineer", attrs}
      assert attrs.brief =~ "fais le hello"
      assert attrs.role == "engineer"

      # F071: locks the 2nd `IssueId.compose` site (enqueue_brief) — otherwise a return to the
      # literal "issue-#{number}" for `issue_id` would not be caught (pod_id ≠ issue_id).
      assert attrs.issue_id == "issue-42"
      # kick emitted — a failed wake would not be silent: spawn_step returns
      # `{:error, {:wake_unreached, …}}` (counted as errors by the poller, re-wake next tick).
      assert_received {:woke, "lordzurp-lcars-test-engineer"}
    end

    test "CI-01: draining → dispatch_issue = {:skipped, :draining}, NO spawn, NO lock (gate is the flag, not a block)" do
      payload = eng_issue()

      # Drain in progress (`quiescing?` seam true): dispatch_issue opens NO new producer — it skips BEFORE
      # decide/spawn → no `lcars-in-flight` label, no pod. The issue stays assigned+unlocked on the forge.
      assert {:skipped, :draining} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(quiescing?: fn -> true end))

      refute_received {:spawned, _, _}
      refute_received {:enqueued, _, _}

      # NOT draining (seam explicitly false → hermetic, independent of the global flag): the SAME issue
      # dispatches normally → the gate is the drain flag, never a blanket block.
      assert {:ok, {:spawned, _pod, "engineer"}} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(quiescing?: fn -> false end))

      assert_received {:spawned, _, _}
    end

    test "GATE slot_scope: engineer (project) already alive → DEFERS :role_busy (serialized, no rebrief)" do
      payload = eng_issue()

      # StubSpawnerAlive: pod_info → {:ok,_} = the project pod `<repo>-engineer` is ALREADY alive
      # (another issue of the repo in progress). The gate serializes project-scoped roles: we DEFER,
      # we do NOT rebrief a busy pod (that would wedge — a one-shot mid-task does not pull a 2nd
      # brief). The poller re-dispatches next tick; the pod dies at end of task → fresh spawn for
      # the next one.
      assert {:skipped, :role_busy} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(spawner: StubSpawnerAlive))

      # The gate CONSULTED pod_info (with the PROJECT id) to see the live pod...
      assert_received {:pod_info, "lordzurp-lcars-test-engineer"}
      # ...then DEFERRED without ANY side effect: no spawn, no enqueue, no wake.
      refute_received {:spawned, _, _}
      refute_received {:enqueued, _, _}
      refute_received {:woke, _}
    end

    test "GATE slot_scope: engineer (project) alive → defers BEFORE lock/enqueue (nothing to compensate)" do
      # The gate defers BEFORE setting the lock or enqueueing → the failing task_queue is NEVER
      # reached. So no lock to remove, no pod to kill: the deferral is side-effect free.
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

      # the pod had spawned → killed (otherwise orphan); the lcars-in-flight lock → removed
      # (otherwise the poller would skip the issue forever).
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

      # The compensation ATTEMPTED the removal (message sent) but it FAILED → the log names the FACT
      # (issue stays in-flight, reconciliation reclaims). Scoped to THIS pod (bleed-proof, capture_log is
      # global); NEVER the pre-CI-10 flat "lock removed" for this pod.
      assert_received {:removed_label, "lcars-in-flight"}
      assert log =~ ~r/pod=lordzurp-lcars-test-engineer.*lock removal FAILED/
      refute log =~ ~r/pod=lordzurp-lcars-test-engineer.*\(lock removed/
    end

    # MA-17 — escalated wake (unreachable pod, re-wake KO → {:error,{:escalated,_}}). A discarded
    # WakeRecovery.wake return (`_ = wake(...)`) → dispatch_issue returned {:ok,{:spawned}} → the
    # poller counted a LYING `dispatched:1/errors:0` (pod never woken). The `wake_recovery` seam
    # simulates the escalation; we assert the dispatch is NOT a silent success but
    # `{:error,{:wake_unreached,_}}`.
    test "MA-17: escalated wake (unreachable pod) → dispatch {:error,{:wake_unreached}}, NOT {:ok,{:spawned}}" do
      payload = eng_issue()

      # Seam: the wake recovery ESCALATES (equivalent to re-wake KO → starfleet). No real
      # IncidentRegistry/forge hits — we inject the unreachability verdict directly.
      escalating_wake = fn _pod_id, _respawn, _opts -> {:error, {:escalated, :dead}} end

      result =
        StepDispatcher.dispatch_issue(
          payload,
          dispatch_opts(wake_recovery: escalating_wake)
        )

      # THE finding: above all NOT a silent dispatch success (the poller counted it dispatched:1).
      refute match?({:ok, {:spawned, _, _}}, result)

      assert {:error,
              {:wake_unreached, "lordzurp-lcars-test-engineer", "engineer", {:escalated, :dead}}} =
               result

      # The pod AND the brief STAY in place (brief enqueued, re-wake/escalation covers): NO
      # compensation (this is not a post-lock failure, it is an unreachable wake). The lock holds.
      assert_received {:spawned, "issue-42", _}
      assert_received {:enqueued, "lordzurp-lcars-test-engineer", _}
      refute_received {:removed_label, _}
      refute_received {:killed, _}
    end

    # MA-17 — counter-proof: a CLEAN wake (:ok) keeps the dispatch a `{:ok,{:spawned}}` success
    # (the `dispatched` tally stays honest when the pod IS really woken).
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
      # chantier face-projet: the card step is the ONLY place the face is decided. `face: ops` →
      # the resolver is asked for ops; no face → main. Downstream nobody re-defaults (the
      # resolver raises without :base_branch — its own test) : this is the one site, so this test
      # is the one that guards the default.
      payload = eng_issue()
      me = self()

      capturing_resolver = fn _repo, r_opts ->
        send(me, {:resolver_base, Keyword.get(r_opts, :base_branch)})
        {:ok, nil}
      end

      ops_loader = fn _name ->
        %{
          # role engineer ON PURPOSE: the face belongs to the STEP, not the role (a card may put
          # any producer on any face) — and the StubLoader only knows the canon test roles.
          "steps" => %{"build" => %{"role" => "engineer", "face" => "ops", "needs" => []}},
          "max_rework_rounds" => 2
        }
      end

      opts = dispatch_opts(project_resolver: capturing_resolver, workflow_map_loader: ops_loader)
      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts)
      assert_received {:resolver_base, "ops"}

      # Face-less step (every pre-existing card) → the code face, decided here and only here.
      opts2 = dispatch_opts(project_resolver: capturing_resolver)
      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts2)
      assert_received {:resolver_base, "main"}
    end

    test "a ticket carrying a LOT clones from the lot, and its PR still lands on the FACE" do
      # The lot is the MATTER (docs, a directory, images) published as `lcars/lot-<slug>`. Two bases
      # that coincide on every other ticket separate here, and only here: the pod CLONES the lot,
      # and its PR LANDS on the face. The deliverable gate keeps the lot as its base — its question
      # is "does base..HEAD hold the pod's work and nothing else", and the pod started at the lot.
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

      # The clone base moves to the lot; the GATE base is left alone (it defaults to the clone
      # base — pointing it at the face would run the identity and co-author checks over the
      # MATTER commits, which the producer never made).
      assert_received {:bases, "lcars/lot-morse-ui-v2", nil}

      # And the lot is a STARTING POINT, not a destination: the PR base is named explicitly,
      # otherwise the completer opens it on the clone base and the work merges into the matter.
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
      # The fallback is the failure worth preventing: a producer starting from the head of its face
      # and working against matter it never saw, with nothing saying so.
      payload = eng_issue(%{"body" => "Lot: refs/heads/evil @ #{String.duplicate("ab", 20)}"})

      opts = dispatch_opts(project_resolver: fn _repo, _o -> {:ok, nil} end)

      assert {:error, {:lot_pointer, {:invalid_lot_ref, "refs/heads/evil"}}} =
               StepDispatcher.dispatch_issue(payload, opts)
    end

    test "a lot branch that MOVED since the ticket was written → refused, the pinned sha is an anchor" do
      # Re-publishing under a lot name already used moves the branch. Without this comparison the
      # older ticket would dispatch onto the newer matter, differing only by a sha nobody reads.
      pinned = String.duplicate("ab", 20)
      moved = String.duplicate("cd", 20)
      payload = eng_issue(%{"body" => "Lot: lcars/lot-paquet-3 @ #{pinned}"})

      opts = dispatch_opts(project_resolver: fn _repo, _o -> {:ok, %{"base_sha" => moved}} end)

      assert {:error, {:lot_moved, {"lcars/lot-paquet-3", ^pinned, ^moved}}} =
               StepDispatcher.dispatch_issue(payload, opts)
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

      # #8: the role NOW comes from the workflow_map (WorkflowMapNav.step_role), not a hardcoded
      # producer_role. Here the current step "build" carries role=engineer → engineer role (and
      # route injected, A2.1).
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

      # The workflow_map IS the state machine: the 1st step (root `needs:[]`) is
      # brief-review/consultant. decide() returned "engineer" (DN §1); workflow_map_role overrides
      # with the current step's role → consultant.
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

      # The step declares brief_kind:judge; the engineer role has a WORKER profile. The per-step
      # override must produce a JUDGE brief (defused), NOT the worker brief (issue body +
      # "Livraison git-native").
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

      # `reviewer` is NOT part of the {worker, judge} vocabulary. Falling back to the `_worker`
      # clause would produce an EXECUTABLE brief for a role that should have been defused.
      # Judge-ness is a security property: it is not inferred by omission → fail-loud.
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
      # F-S2-1: the brief = the ISSUE body at hand (payload), NOT a redundant get_issue.
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
      # BRIEF framing (subject:brief) + the brief to judge, NOT the deliverable framing.
      assert brief =~ "Brief to judge"
      assert brief =~ "MON BRIEF A JUGER"
      refute brief =~ "Deliverable to judge (step outputs"
      refute brief =~ "Livraison (git-native)"
    end

    test "#5.2 D2 — ROUTELESS issue → onboarded onto the default workflow_map (skip), NO eng spawn" do
      payload = eng_issue()

      # route :none (overrides the default route) + default workflow_map brief-gate (1st step
      # brief-review).
      opts =
        dispatch_opts(
          forge_opts: [_test_route: :none],
          workflow_map_loader: fn "brief-gate" ->
            %{"steps" => %{"brief-review" => %{"role" => "consultant", "needs" => []}}}
          end
        )

      assert {:skipped, :onboarded} = StepDispatcher.dispatch_issue(payload, opts)

      # the default workflow_map was RECORDED (next tick will dispatch the consultant); NO eng spawn.
      assert_received {:routed, 42, "brief-gate", "brief-review"}
      refute_received {:spawned, _, _}
    end

    test "ROUTELESS issue with `genre/doc` → onboarded onto the OPS card, not the project's (chantier face-projet)" do
      # The destination gate of the burn: the label is the INPUT, the engraved wfmap/* the OUTPUT — read
      # once, here. A face-projet mutation that drops the gate re-routes ops tickets down the code
      # path silently; this is the test that falls.
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
      # Le cas qui survit au refus d'onboarding (`Declaration.refute_unloadable_card/2`) : la carte
      # etait chargeable a la declaration, le catalogue l'a perdue depuis. Ce site ne se rabat PAS
      # — poser une route est durable, et une route sous une carte que personne n'a choisie fait
      # tourner le projet sous une criticite que personne n'a declaree. Il refuse, mais son refus
      # cesse d'etre muet : sans trace, l'issue echouait a chaque tick, indefiniment.
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
      # Le NOM EFFECTIF est dans la trace : un incident qui ne dit pas quelle carte manque envoie
      # l'operateur chercher dans tout le catalogue.
      assert detail =~ name
    end

    @tag :tmp_dir
    test "un catalogue SANS rail doc → aucune route, et un incident DURABLE", %{tmp_dir: tmp} do
      # LE JUMEAU DE 6-125, sur la moitie voisine. `refute_missing_rail/1` rend
      # `:no_doc_rail_in_catalogue` quand aucune carte du catalogue ne porte de producteur
      # `face: workshop`. Un deploiement a le DROIT de ne pas avoir de rail doc ; un ticket
      # documentaire dessus echouait alors a chaque tick, indefiniment, sans trace — le mode de
      # panne exact que la clause voisine a ete ecrite pour fermer.
      #
      # Le catalogue temporaire porte UNE carte, sans producteur `face: workshop` : la resolution
      # par PROPRIETE ne trouve rien et rend `nil`. C'est le seul chemin vers ce refus.
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

      # MEME `op` que la carte illisible : les deux disent « la resolution de carte de ce depot a
      # echoue », donc une seule signature de dedup et un seul ticket.
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

      # resolution BEFORE any forge write: no spawn, no orphan lock
      refute_received {:spawned, _, _}
    end

    # ====================================================================
    # SLOT-FREEZE — PIPE-aware gate: a PIPE engineer (resident) is re-briefed by its state.
    #   dead  -> fresh spawn; busy (active task OR :publishing) -> DEFERS; ready -> COLD
    #   reprovision + rebrief. (project["base_sha"] is passed at reset; the slug = the issue's
    #   feature branch.)
    # ====================================================================
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

      # cold reset called BEFORE the rebrief, with the project (base_sha) + the issue's slug.
      assert_received {:reprovisioned, "lordzurp-lcars-test-engineer",
                       %{"base_sha" => "basesha1"}, [slug: _slug]}

      # re-brief (live pod) -> enqueue + wake, NO fresh re-spawn.
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
      # F-C059: a pod_info raise left the state UNKNOWN → :error → :dead → serialize `:ok` → fresh
      # spawn that REAPS/kills the LIVE eng pipe + its context (the exact danger `pod_alive?`
      # guards with "assume ALIVE"). Fail-closed: uncertainty (raise) → DEFERS (mirror of
      # pod_alive?), never reset/kill.
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
      # The spawner's contract split: a live-but-slow pod whose info call times out is
      # :unreachable — the old flattening into :not_found read it as DEAD → fresh spawn on
      # the deterministic id → reap of the LIVING pipe eng + its context. Fail-closed like
      # the RAISE case: defer, never reset/kill.
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
      # 2026-09-05 — `promote_or_route` only re-routed `{:error, {:merge, _}}`; the wall's refusal
      # reached the poller as a bare error → `:keep`, no label, the same seal every tick forever.
      # The seal needs the chief token before it reaches the wall.
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
      # The engraved name `standard` exists in `biz` (jury `[code-reviewer]`) and not in the
      # bundled catalogue: a default loader that drops the catalogue cannot load it, falls back to
      # the project card, and adopts the DEFAULT jury on this PR. No `:workflow_map_loader` here:
      # the rail's own default is the subject.
      %{install_dir: dir} = Fleet.Test.BizCatalogueFixture.write!(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [dir])
      :ok = Fleet.CapProfile.Image.publish!()
      :ok = Fleet.Workflow.Loader.publish_image!()

      on_exit(fn ->
        Fleet.CapProfile.Image.unpublish()
        Fleet.Workflow.Loader.unpublish_all_images()
      end)

      judge = Fleet.Test.BizCatalogueFixture.judge()
      # The PROJECT declares the jury-less card: the rail's fallback (engraved card unloadable)
      # would adopt nobody, so `[judge]` can only come from the engraved `standard` read in `biz`.
      code_root = Path.join(tmp, "projects")
      Fleet.Test.BizCatalogueFixture.declare_project!(code_root, "boutique", "no-jury")

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
      # The engraved route names `strict` (jury `[code-reviewer]`, `ci: required`); the project
      # declares `no-jury` (jury `[]`, `ci: ignore`). Two readers, one resolution: both answers come
      # from `strict` when a route is engraved, both from `no-jury` when none is.
      %{install_dir: dir} = Fleet.Test.BizCatalogueFixture.write!(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [dir])
      :ok = Fleet.CapProfile.Image.publish!()
      :ok = Fleet.Workflow.Loader.publish_image!()

      on_exit(fn ->
        Fleet.CapProfile.Image.unpublish()
        Fleet.Workflow.Loader.unpublish_all_images()
      end)

      judge = Fleet.Test.BizCatalogueFixture.judge()
      code_root = Path.join(tmp, "projects")
      Fleet.Test.BizCatalogueFixture.declare_project!(code_root, "boutique", "no-jury")

      ctx = fn route ->
        %Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx{
          forge: StubForge,
          loader: StubLoader,
          workflow_map_loader: &Fleet.Workflow.Loader.load!/2,
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
      # defused judge brief (brief_kind: judge) — not an executable body
      assert spawn_opts[:brief] =~ "JUDGE"

      # Info-starvation fix (judge): empty predecessor (git-native) → the judge is POINTED at its
      # workspace AND receives the CRITERION (issue body, defused in context).
      #
      # ⚠ CETTE ASSERTION EPINGLAIT `origin/main`, et son commentaire donnait la bonne moitie du
      # raisonnement : « single-branch clone: the local ref `main` does not exist — live morse bug ».
      # Il s'arretait un cran trop tot. Sur une review, `RoleDispatch` pose `base_branch: head`,
      # donc le clone est `--branch <head>` et **`origin/main` n'y est pas non plus** ; la meme
      # revision inconnue revenait par l'autre porte (6-135). La base est desormais `lcars/base`,
      # posee par le bootstrap sur la base REELLE du travail, la meme pour tous les pods.
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
      # THE TEST THE ORIGINAL BUG NEEDED. The PR-judge path (role_dispatch) must set `:mandate` so
      # the spawner materializes the file the judge's order references. The other dispatch_review
      # tests use an INLINE body (no pointer) → mount is nil → `maybe_put(:mandate, nil)` is a no-op,
      # so deleting the fix line passes 3200 tests. This test carries a real `Criteria:` pointer, so
      # a missing `:mandate` (the original bug) is now RED.
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

      # requested == [] (neither requested_reviewers nor jury) = PR NOT set up by the pipeline
      # (typically human/fork discovered by the poller). Agent-agnostic gate → we SET the judges
      # instead of skipping `:no_verdict`. They spawn on the NEXT tick (not here →
      # `refute_received {:spawned}`).
      assert {:ok, {:adopted, _pr_number, reviewers}} =
               StepDispatcher.dispatch_review(pr, dispatch_opts())

      assert reviewers != []
      assert_received {:requested_review, _index, ^reviewers}
      refute_received {:spawned, _, _}
    end

    test "ZERO-JUDGE card (jury []) + no requested judge → NOMINAL sealed merge, NOT adoption" do
      # The card arbitrates the no-judge case: an empty jury makes `requested == []` the
      # nominal path → straight to the sealed merge (provenance wall inside merge_and_promote);
      # no judge laid, no judge spawned. `reviewer_roles: []` = the card's jury via the seam.
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

      # the FF merge was triggered on the PR (explicit close via merge_and_promote, no more Closes #N)
      assert_received {:merged, 6}
      refute_received {:spawned, _, _}

      # Die-on-promote: the kill-site targets `for_issue` (id `...-issue-42-engineer`). For the
      # one-shot project-scoped eng this is a PHANTOM pod_id → SAFE no-op (cf. step_dispatcher:
      # using for_repo here would kill the eng if it were coding ANOTHER issue). We assert the kill
      # CALL with the issue-keyed id (even if it no-ops), unconditional on the dispatcher side.
      assert_received {:killed, "lordzurp-lcars-test-issue-42-engineer"}

      # REGRESSION guard: this path (poller-driven merge, no-workflow_map) NEVER lifted the ISSUE
      # lock — only the PR lock lifted (via each judge's route(:reviewed), out-of-scope here).
      # `promote_pr` must now also lift the ISSUE (42): the entire brick is done at merge.
      assert_received {:stopped_watch, 42}
    end

    test "CI-08: promote unlock FAILS → honest 'issue lock NOT released' log (never the lie) + retry, still {:ok, {:merged}}" do
      # The merge/seal/close all succeed; only the TERMINAL issue unlock (remove_label) fails. The
      # promote genuinely succeeded → the return stays {:ok, {:merged}}, but the log must follow the
      # VERDICT (CI-08 — "le caller ne doit pas annoncer le retrait avant son verdict"): never the
      # blanket "issue lock released" lie, and the retrait is retried (last-chance: the closed issue is
      # no longer re-polled) before being surfaced LOUD.
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

      # The merge happened — the promote succeeded despite the unlock failure.
      assert_received {:merged, 6}

      # Verdict-following honest log (bleed-proof: scoped to THIS test's issue #42 + the new phrase).
      assert log =~ "issue=#42 MERGED+SEALED+CLOSED but issue lock NOT released"
      # The bounded retry was attempted (last-chance reconciliation).
      assert log =~ "issue #42 unlock attempt 1/3 FAILED"
      # The old blanket lie must NOT appear on the failure path.
      refute log =~ "eng killed, issue lock released"
    end

    # JG-063 — « warden/manual cleanup » DESIGNAIT UN RAIL QUI N'EXISTE PAS. Verifie : les deux
    # `warden` du depot portent sur les PODS, aucun ne retire d'etiquette de forge ; et le poller ne
    # lit que `list_open_issues/2`, donc cette issue FERMEE n'est plus jamais vue. La phrase
    # promettait un rattrapage automatique imaginaire, et « manual » suppose qu'un humain lise ce
    # log — ce que la doctrine D1 refuse pour tout ce qui est load-bearing.
    #
    # Le residu n'est pas benin : l'etiquette suggere un travail en cours qui n'existe pas, et le
    # chronometre fausse definitivement les metriques de duree de ce ticket.
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
      # A human (`Lordzurp`) reviews/is-requested on the PR (read suffices — verified live, the
      # forge does NOT prevent it). WITHOUT the filter: they have no verdict → `hd(pending)` =
      # lordzurp → `RoleDispatch.load_role_or_skip` fails → SILENT `{:skipped, :no_role}` → the
      # jury (qualifier + reviewer, all APPROVED) is STARVED, no merge. WITH the `reviewer_roles`
      # filter: lordzurp excluded from the jury → all judges approved → merge, and the non-jury
      # reviewer is signaled LOUD (not swallowed).
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
          # behavior: the non-jury human login does not starve the merge.
          assert {:ok, {:merged, 6}} = StepDispatcher.dispatch_review(pr, opts)
        end)

      # LOUD: the non-jury reviewer is signaled (F-C061), not silently absorbed.
      assert log =~ "F-C061" and log =~ "lordzurp"
      # never dispatched as a role.
      refute_received {:spawned, _, "lordzurp"}
    end

    test "F-C061: a REQUEST_CHANGES from a NON-jury login (human) does NOT trigger a stray rework" do
      # 2nd vector of the same hole: a human POSTS a verdict (not just requested) → they enter
      # `verdicts` AND the jury (REQUEST_CHANGES review-record). WITHOUT the filter:
      # `Map.take(verdicts, requested)` includes lordzurp → STRAY `dispatch_rework` (rework cycle
      # triggered by a human). WITH the `reviewer_roles` filter: lordzurp excluded from `requested`
      # → their voice does not count → the jury (qualifier + reviewer, approved) → merge. Human
      # login signaled LOUD.
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
          # the human REQUEST_CHANGES is IGNORED (no rework) → all-approved jury → merge.
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
      # Live bug PoC-7: Gitea made the reviewer VANISH from `requested_reviewers` WITHOUT them
      # voting (review-record still REQUEST_REVIEW). The volatile field only shows the qualifier
      # (who approved). WITHOUT the fix: requested=[qualifier], pending=[] → premature MERGE on 1
      # judge (half-jury). WITH it: the jury comes from the review-records
      # (`pr_review_state.reviewers` = [qualifier, reviewer]) → union → pending=[reviewer] → we
      # spawn the reviewer, NEVER a merge.
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
      # Old contract (F-C061 bug): an unknown login → SILENT `{:skipped, :no_role}`. New: a
      # non-jury login (here `lordzurp`, human) is FILTERED from the jury → the PR ends up without
      # a judge → ADOPTION (we set the jury, review next tick), and the foreign login is signaled
      # LOUD (never swallowed).
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
      # `_test_route: :none` means the ISSUE carries no engraved card, so the CI policy comes from
      # the PROJECT's declared card — which requires it. The green is a PREMISE of this test, not
      # its subject: it says "the CI rail is fine, the enqueue is what breaks".
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
      # The PR head=lcars/issue-42-engineer (issue 42) has a requested reviewer → WITHOUT the fix,
      # the judge would be re-spawned every tick. But issue 42 is in the `:awaits_arch_ids` SET
      # (escalation in progress) → `dispatch_review` skips (symmetric of `decide/1` on the issue
      # side) → end of churn.
      opts = dispatch_opts(awaits_arch_ids: MapSet.new([42]))

      assert {:skipped, :awaits_arch} = StepDispatcher.dispatch_review(pr(), opts)
      refute_received {:spawned, _, _}
      refute_received {:enqueued, _, _}
    end

    test "MA-01 (bug B): awaits_arch_ids does NOT contain the issue -> normal dispatch (back-compat)" do
      # Guard: the skip only triggers for the concerned issue. Issue 42 (PR head) absent from the
      # SET (here {99}) → normal judge dispatch. And default empty MapSet (other callers) →
      # unchanged.
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
      # Le chemin forward passe `gate_base_branch == base_branch` — le moduledoc dit qu'elles
      # coincident. On payait quand meme une SECONDE `ls-remote` (reseau, bornee a 15 s, DANS le
      # GenServer du poller) pour une valeur deja en main.
      #
      # Ce que ce test tient n'est PAS le compte d'appels (invisible d'ici) mais sa CONSEQUENCE
      # observable : les deux shas sont issus de la MEME lecture, donc rigoureusement egaux. Deux
      # `ls-remote` sur le meme ref a deux instants peuvent diverger si quelqu'un pousse entre les
      # deux — le pod clonerait une base et serait juge contre une autre, sans qu'aucune des deux
      # ne soit fausse. La reutilisation est donc plus CONSISTANTE, pas seulement plus rapide.
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
