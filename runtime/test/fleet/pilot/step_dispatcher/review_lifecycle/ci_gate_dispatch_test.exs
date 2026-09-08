defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGateDispatchTest do
  @moduledoc """
  The CI gate, seen through `dispatch_review/2`: a red CI is the producer's rework (counted on
  the ticket, never on a queue), a pending CI waits — bounded, and said when the bound is passed —
  and a card `ci: ignore` waits for nothing. The gate's own decision table is `CiGateTest`.
  """
  # `async: false`, inherited from the file these witnesses were cut from and not re-audited: the
  # bench itself writes no application env, but role tokens are files under a shared dir
  # (`Fleet.TestEnv.put_role_token!/2`), and this file is not the place to prove the rail is
  # parallel-safe.
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepDispatcher

  import Fleet.Pilot.DispatcherBench

  alias Fleet.Pilot.DispatcherBench.StubSpawnerAlive

  describe "dispatch_review/2 — the CI gate on the PR rail" do
    test "merge blocked by a RED CI → PRODUCER rework, not a human (the rung, 2026-08-03)" do
      # Measured on a live bench: a PR whose head carried `CI / ci (push)` = failure was PROMOTED —
      # nothing in the runtime read a commit status and the forge rule had `enable_status_check:
      # false`. Requiring the check closes the merge door; this test holds the other half, without
      # which the fix would only trade a silent promotion for a silent wedge.
      #
      # A red CI is not a human matter and does not re-converge: nothing changes until the producer
      # pushes a new commit. Sending it to the arch — which is what `{:policy, :no_rerequest}` did,
      # naming the absence of a re-request rather than the actual cause — summons a human for work
      # only the engineer can do.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{"number" => 6, "state" => "open", "draft" => false, "mergeable" => true},
            _test_rerequested: [],
            _test_route: {:ok, {"g", "build"}},
            _test_ci: :failure
          ]
        )

      # ⚠ CE TEMOIN ETAIT VERT SUR LE MAUVAIS FAIT. Il ne refusait QUE `{:merge_blocked_escalated,
      # _}` — une des DEUX formes d'escalade — pendant que la fixture, sans `_test_route`, faisait
      # echouer la lecture du budget et rendait `{:rework_exhausted_escalated, 6}` : l'architecte
      # etait saisi, exactement ce que le nom du test dit qui n'arrive pas. Un refus d'UNE forme ne
      # prouve pas le fait ; le fait, c'est qu'un POD est demande.
      assert {:ok, _} = StepDispatcher.dispatch_review(pr, opts)
      assert_received {:spawned, _issue, _opts}
    end

    test "CI rouge : le round est COMPTE sur le ticket — sinon le budget ne borne rien" do
      # `count_change_request_rounds` compte des reviews REQUEST_CHANGES ; un CI rouge n'en pose
      # AUCUNE. Le budget qui s'appuie dessus laisse donc passer une suite infinie de rounds, un pod
      # a chaque fois que le label `in_flight` retombe. Le marqueur EST le round depense.
      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            # `head.sha` COMME EN PRODUCTION : `head_sha/3` retombe sinon sur la REF de branche, et
            # le marqueur porterait un nom au lieu d'un sha. Le frein compte par PRÉFIXE, donc il
            # tiendrait quand même — mais la ligne postée sur le ticket mentirait au lecteur.
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => true,
              "head" => %{"sha" => "abcdef0123456789abcdef0123456789abcdef01"}
            },
            _test_rerequested: [],
            _test_route: {:ok, {"g", "build"}},
            _test_ci: :failure,
            _test_ci_reworks: {:ok, 0}
          ]
        )

      assert {:ok, _} =
               StepDispatcher.dispatch_review(
                 pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6}),
                 opts
               )

      assert_received {:spawned, _issue, _opts}
      assert_received {:ci_rework_marked, 42}
    end

    test "CI rouge mais le producteur est OCCUPE : rien n'est lance, donc RIEN n'est facture" do
      # LE ROUND SE PAIE A LA DEPENSE, PAS A L'INTENTION. `dispatch_rework` rend
      # `{:skipped, :role_busy}` sans rien lancer quand le pod du producteur travaille deja. Marquer
      # la viderait le budget de la carte sur une FILE D'ATTENTE : au tick suivant le producteur est
      # libre, mais le frein a compte des rounds que personne n'a joues, et l'architecte est saisi
      # pour un rework qui n'a jamais eu lieu.
      opts =
        dispatch_opts(
          spawner: StubSpawnerAlive,
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => true,
              "head" => %{"sha" => "abcdef0123456789abcdef0123456789abcdef01"}
            },
            _test_rerequested: [],
            _test_route: {:ok, {"g", "build"}},
            _test_ci: :failure,
            _test_ci_reworks: {:ok, 0}
          ]
        )

      StepDispatcher.dispatch_review(
        pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6}),
        opts
      )

      refute_received {:spawned, _issue, _opts}
      refute_received {:ci_rework_marked, 42}
    end

    test "A-09 (1) on the REVIEW rail: :role_busy short-circuits WITHOUT calling the resolver" do
      # The twin of `step_dispatcher_gate_order_test`'s A-09 (1): `prepare_dispatch` gates on the
      # scope decision BEFORE the network resolver, on the rework path (a project-scoped producer
      # already alive). Zero network on a busy tick, and no lock.
      me = self()

      opts =
        dispatch_opts(
          spawner: StubSpawnerAlive,
          project_resolver: fn _repo, _opts ->
            send(me, :resolver_called)
            {:ok, nil}
          end,
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            _test_route: {:ok, {"g", "build"}}
          ]
        )

      assert {:skipped, :role_busy} =
               StepDispatcher.dispatch_review(
                 pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6}),
                 opts
               )

      refute_received :resolver_called
      refute_received {:spawned, _, _}
    end

    test "CI rouge AU-DELA du budget : l'architecte est saisi, et aucun pod de plus" do
      # `max_rework_rounds` vaut 2 dans ces fixtures : deux rounds deja depenses ferment la porte.
      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            # `head.sha` COMME EN PRODUCTION : `head_sha/3` retombe sinon sur la REF de branche, et
            # le marqueur porterait un nom au lieu d'un sha. Le frein compte par PRÉFIXE, donc il
            # tiendrait quand même — mais la ligne postée sur le ticket mentirait au lecteur.
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => true,
              "head" => %{"sha" => "abcdef0123456789abcdef0123456789abcdef01"}
            },
            _test_rerequested: [],
            _test_route: {:ok, {"g", "build"}},
            _test_ci: :failure,
            _test_ci_reworks: {:ok, 2}
          ]
        )

      StepDispatcher.dispatch_review(
        pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6}),
        opts
      )

      refute_received {:spawned, _issue, _opts}
      # Et le round non joue n'est pas facture : on ne marque que ce qui a spawn.
      refute_received {:ci_rework_marked, 42}
    end

    test "CI rouge, compteur ILLISIBLE : on escalade, on ne boucle pas en aveugle" do
      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            # `head.sha` COMME EN PRODUCTION : `head_sha/3` retombe sinon sur la REF de branche, et
            # le marqueur porterait un nom au lieu d'un sha. Le frein compte par PRÉFIXE, donc il
            # tiendrait quand même — mais la ligne postée sur le ticket mentirait au lecteur.
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => true,
              "head" => %{"sha" => "abcdef0123456789abcdef0123456789abcdef01"}
            },
            _test_rerequested: [],
            _test_route: {:ok, {"g", "build"}},
            _test_ci: :failure,
            _test_ci_reworks: {:error, :forge_down}
          ]
        )

      StepDispatcher.dispatch_review(
        pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6}),
        opts
      )

      refute_received {:spawned, _issue, _opts}
    end

    test "merge blocked while the CI is still PENDING → the next tick asks again, nobody is summoned" do
      # A rail that has not finished is not a verdict. Escalating here would page a human for the
      # duration of every CI run, and dispatching rework would ask the producer to fix nothing.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{"number" => 6, "state" => "open", "draft" => false, "mergeable" => true},
            _test_rerequested: [],
            _test_ci: :pending
          ]
        )

      assert {:skipped, :ci_pending} = StepDispatcher.dispatch_review(pr, opts)
    end

    test "CI PENDANTE au-dela de la borne : l'attente s'arrete et le DIT — sinon elle est infinie" do
      # Sous une carte `ci: ignore`, ce site est le SEUL lecteur de la CI : le gate ne s'applique
      # pas. Un job qu'aucun runner ne reclame y attendait en silence, tick apres tick, pour
      # toujours — « une attente ressemble a du travail », exactement la panne que le gate borne
      # deja de son cote. Meme horloge, meme nombre, une seule doctrine.
      vieux =
        DateTime.utc_now()
        # La borne EN DUR, jamais lue dans le sujet : `ci_gate_test` porte le temoin qui la nomme
        # (mesure du 2026-09-07 — empruntee, elle rendait vert un passage de 45 min a 18 h).
        |> DateTime.add(-(45 * 60 + 60), :second)
        |> DateTime.to_iso8601()

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => true,
              "head" => %{"sha" => "abcdef0123456789abcdef0123456789abcdef01"},
              "updated_at" => vieux
            },
            _test_rerequested: [],
            _test_route: {:ok, {"g", "build"}},
            _test_ci: :pending
          ]
        )

      assert {:skipped, {:merge_blocked_escalated, 6}} =
               StepDispatcher.dispatch_review(
                 pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6}),
                 opts
               )

      refute_received {:spawned, _issue, _opts}
    end

    test "CI PENDANTE dont la DATE est illisible : on attend, on n'escalade pas sur ce qu'on n'a pas lu" do
      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => true,
              "head" => %{"sha" => "abcdef0123456789abcdef0123456789abcdef01"},
              "updated_at" => "pas une date"
            },
            _test_rerequested: [],
            _test_route: {:ok, {"g", "build"}},
            _test_ci: :pending
          ]
        )

      assert {:skipped, :ci_pending} =
               StepDispatcher.dispatch_review(
                 pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6}),
                 opts
               )
    end

    test "…mais une carte `ci: ignore` ne doit PAS attendre la CI, meme sur ce chemin" do
      # DEUX CICATRICES, UN SEUL DISCRIMINANT — l'ETAT, jamais la carte.
      #
      # 2026-08-10 : carte `ci: ignore`, deploiement SANS runner → wait/ci eternel. Cette fixture
      # modelisait ce monde avec `:pending` — FAUX etat : sans runner, AUCUN status n'existe et
      # `commit_ci_state` rend `:none`. La fixture racontait un autre monde que sa propre histoire.
      # 2026-08-18 (premier conflit reel au banc) : la protection de main exige `CI / *`
      # (independant de la carte) ; le court-circuit par la carte a classe :policy un 405
      # « status checks » TRANSITOIRE (runner pas encore couru sur le sha de la resolution) et
      # immobilise un humain pour 30 secondes d'attente. Le test jumeau ci-dessous epingle ce
      # cas-la : `:pending` = un rail COURT, on retick.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          workflow_map_loader: fn _name ->
            %{
              "steps" => %{"build" => %{"role" => "engineer", "needs" => []}},
              "max_rework_rounds" => 2,
              "ci" => "ignore"
            }
          end,
          forge_opts: [
            _test_route: {:ok, {"g", "build"}},
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{"number" => 6, "state" => "open", "draft" => false, "mergeable" => true},
            _test_rerequested: [],
            _test_ci: :none
          ]
        )

      refute match?({:skipped, :ci_pending}, StepDispatcher.dispatch_review(pr, opts)),
             "sans runner (:none), une carte `ci: ignore` ne doit jamais produire wait/ci"
    end

    test "A0.5 : un merge bloque par des status checks EN COURS retick — jamais une escalade arch" do
      # Le 405 « Not all required status checks successful » de la protection est un etat
      # transitoire quand un runner court (mesure au banc : 3 s apres la livraison de la
      # resolution d'un conflit). L'escalader en :policy immobilisait un humain pour 30 s
      # d'attente. La carte (`ci: ignore`) ne peut pas abroger le plancher de la forge.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result:
              {:error, {:http, 405, "Not all required status checks successful"}},
            _test_route: {:ok, {"g", "build"}},
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => true
            },
            _test_ci: :pending
          ]
        )

      assert {:skipped, :ci_pending} = StepDispatcher.dispatch_review(pr, opts)
      refute_received {:spawned, _, _}
    end
  end
end
