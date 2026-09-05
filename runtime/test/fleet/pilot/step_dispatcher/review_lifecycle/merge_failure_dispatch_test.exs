defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.MergeFailureDispatchTest do
  @moduledoc """
  A merge that fails, routed on its REAL cause through `dispatch_review/2`: a policy block
  re-dispatches the re-requested judge or escalates honestly; a git conflict climbs the ladder —
  tier 0 engine (probes stubbed here), tier 1 producer, tier 2 chief, tier 3 architect — and the
  face of the PR decides the worktree the conflict is resolved in.
  """
  # ⚠ `async: false` : ce fichier ECRIT `:pilot_conflict_diagnosis?`, `:pilot_conflict_diagnoser`,
  # `:pilot_conflict_applier` et `:pilot_conflict_exception_pass?` en env d'APPLICATION, qui est
  # globale au node. Pendant la fenetre — restauration `on_exit` comprise — tout test concurrent
  # qui lit ces cles lit la valeur de celui-ci. Mesure du 2026-08-17 : la meme forme a tue
  # `Pilot.ApplicationTest` sur une racine de catalogue temporaire qui ne lui appartenait pas, dans
  # le build d'image et pas sur la machine de dev — la collision depend du nombre de coeurs et de
  # l'ordre du seed, donc elle mord la ou ca coute le plus cher.
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepDispatcher

  import Fleet.Pilot.DispatcherBench

  describe "dispatch_review/2 — merge failure routing and the conflict ladder" do
    # ── The "machine reads the full forge state" angle: merge failure CLASSIFIED ──
    # Replaces the old catch-all "any failure = conflict → eng rebase" (impossible because
    # forge-blind → live dead end). The failure is re-read from the PR object (MergeOutcome) and
    # routed to its REAL cause.

    test "merge failure + REAL git conflict, budget available → producer CONFLICT-REWORK (tier 1), no escalation" do
      # Tier 1 (fleet/hello#3 retex 2026-07-19): the producer resolves ON its PR — bounded by
      # max_rework_rounds, counted via the [conflict-rework:pr-N markers posted by this path.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_route: {:ok, {"g", "build"}},
            _test_merge_result: {:error, {:http, 409, "conflict"}},
            _test_conflict_rounds: {:ok, 0},
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => false
            }
          ]
        )

      assert {:ok, _} = StepDispatcher.dispatch_review(pr, opts)

      # The PRODUCER is (re)spawned on its brick — the conflict is production work, not arbitrage.
      assert_received {:spawned, _, _}
      refute_received {:merged, _}
    end

    test "merge failure + REAL conflict, budget EXHAUSTED → honest arch escalation (tier 3)" do
      # A2 — the harness answers `_test_conflict_rounds` for EVERY marker prefix, so the seal's
      # conflict signal reads >0 here and it signs CHIEF: the signer needs its token for the merge
      # ATTEMPT to happen at all (it then fails on the 409, which is what this test is about).
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_resolver_role, "chief")
      Fleet.TestEnv.put_role_token!("chief", "CHIEF-TOKEN")

      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 409, "conflict"}},
            _test_route: {:ok, {"g", "build"}},
            # rounds ≥ budget (2, default loader) → no more automatic rework.
            _test_conflict_rounds: {:ok, 2},
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => false
            }
          ]
        )

      assert {:skipped, {:merge_blocked_escalated, 6}} = StepDispatcher.dispatch_review(pr, opts)
      refute_received {:spawned, _, _}
      refute_received {:merged, _}
    end

    test "merge failure + PR mergeable:true (POLICY: human re-request) → re-dispatches the re-requested judge" do
      # THE hello-kitty case: git-mergeable, but branch-protection refuses (a judge manually
      # re-requested reset the approvals counter). We re-dispatch that judge (the button finally
      # does its job), NO escalation, NO conflict treatment.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6,
          "head" => %{"ref" => "lcars/issue-42-engineer"}
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "Does not have enough approvals"}},
            _test_pull: %{"number" => 6, "state" => "open", "draft" => false, "mergeable" => true},
            _test_rerequested: ["qualifier"]
          ]
        )

      assert {:ok, {:spawned, _pod, "qualifier"}} = StepDispatcher.dispatch_review(pr, opts)
      refute_received {:merged, _}
    end

    test "merge failure + PR mergeable:true WITHOUT re-request → honest escalation (unliftable policy, no silent wedge)" do
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
            _test_rerequested: []
          ]
        )

      assert {:skipped, {:merge_blocked_escalated, 6}} = StepDispatcher.dispatch_review(pr, opts)
    end

    # Les deux seams de conflit (`:conflict_diagnoser` / `:conflict_applier`) existaient sans qu'un
    # seul test ne les injecte — une indirection dont le benefice, l'hermetisme, n'etait jamais
    # consomme (BL-6-42.2). Et la mesure a montre pire que « une seam inutilisee » : `tier0_decision`
    # (le routage PUR) etait deja teste, mais le CABLAGE — flag → diagnoser → decision → acte —
    # n'avait aucun test. Le trou tombait exactement entre une fonction prouvee et le monde, soit
    # la portion que ces seams existent pour rendre testable.
    # Les deux sondes rendent la forme REELLE d'un diagnostic (`files` + `totals`), pas seulement
    # les totaux que le routage consomme. Un fake qui rend une forme de seam inexistante n'affaiblit
    # pas un test, il l'INVERSE : celui-ci passait vert alors que le rendu du rapport, ajoute le
    # 2026-08-05, ne pouvait pas s'executer sur cette forme.
    defmodule AllSemanticProbe do
      def probe(_repo, _ref, _opts) do
        {:ok,
         %{
           files: %{
             "lib/a.ex" => %{
               hunks: [
                 %Fleet.Conflict.Hunk{
                   base_lines: [],
                   ours_lines: ["a"],
                   theirs_lines: ["b"],
                   start_line: 12,
                   type: :complex,
                   confidence: %Fleet.Conflict.ConfidenceScore{score: 10, label: :low},
                   explanation: "deux intentions distinctes",
                   trace: %Fleet.Conflict.DecisionTrace{
                     selected: :complex,
                     summary: "aucun motif trivial ne s'applique",
                     has_base: false
                   },
                   zdiff3: false
                 }
               ]
             }
           },
           totals: %{none_trivial?: true, total: 1, trivial: 0, complex: 1, writable: 0}
         }}
      end
    end

    defmodule AllWritableProbe do
      def probe(_repo, _ref, _opts) do
        {:ok,
         %{
           files: %{
             "lib/b.ex" => %{
               hunks: [
                 %Fleet.Conflict.Hunk{
                   base_lines: ["x"],
                   ours_lines: ["x", "y"],
                   theirs_lines: ["x"],
                   start_line: 3,
                   type: :one_side_change,
                   confidence: %Fleet.Conflict.ConfidenceScore{score: 90, label: :high},
                   explanation: "un seul cote a bouge",
                   trace: %Fleet.Conflict.DecisionTrace{
                     selected: :one_side_change,
                     summary: "la base prouve que seul `ours` a change",
                     has_base: true
                   },
                   zdiff3: false
                 }
               ]
             }
           },
           totals: %{all_writable?: true, total: 1, trivial: 1, complex: 0, writable: 1}
         }}
      end
    end

    defmodule BlindProbe do
      def probe(_repo, _ref, _opts), do: {:error, :cannot_diagnose}
    end

    defmodule ResolvingApplier do
      def apply(_repo, _ref, _opts), do: {:ok, :auto_resolved}
    end

    defp conflict_pr,
      do:
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6,
          # `pr_base_branch` n'est PAS une option du dispatch : `step_dispatcher` l'ECRASE depuis
          # l'objet PR (`get_in(pr, ["base","ref"])`), et c'est la bonne source — la face d'un PR
          # est une propriete du PR, pas du harnais. La poser en opts ne servait a rien.
          "base" => %{"ref" => "main"}
        })

    defp conflict_opts(extra) do
      dispatch_opts(
        Keyword.merge(
          [
            forge_opts: [
              _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
              _test_merge_result: {:error, {:http, 405, "conflit"}},
              _test_pull: %{
                "number" => 6,
                "state" => "open",
                "draft" => false,
                "mergeable" => false
              }
            ]
          ],
          extra
        )
      )
    end

    # La sonde qui ne diagnostique rien : elle CAPTURE les opts qu'on lui tend. Le rendu `:error`
    # renvoie le chemin sur le legacy, dont l'observable ne discrimine rien ici — c'est voulu, ce
    # test n'assure pas le routage mais l'ARGUMENT, et l'argument n'est visible que d'ici.
    defmodule DirCapturingProbe do
      def probe(_repo, _ref, opts) do
        send(self(), {:probe_opts, opts})
        {:error, :captured}
      end
    end

    test "la FACE de la PR decide le worktree ou son conflit est resolu" do
      # Le commentaire de `conflict_face_opts/1` decrit ce defaut comme repare : les helpers
      # tombaient sur leur defaut `origin/main` DANS le worktree de la face code, et sur une PR ops
      # cela resolvait un conflit en fusionnant la face CODE dans une branche doc — silencieusement,
      # en rapportant `{:ok, :auto_resolved}`. La reparation etait la, RIEN ne la tenait : renvoyer
      # la face ops vers `projects_root` laissait les 2451 tests verts (mesure 2026-08-08). Une
      # cicatrice ecrite en commentaire et non gardee se fait retirer par le prochain refactor, qui
      # lit un `case` a trois branches identiques a deux details pres et « simplifie ».
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, true)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, DirCapturingProbe)

      name = Fleet.Layout.project_name("lordzurp/lcars-test")

      ops_pr = Map.put(conflict_pr(), "base", %{"ref" => "ops"})
      _ = StepDispatcher.dispatch_review(ops_pr, conflict_opts([]))
      assert_received {:probe_opts, ops_opts}
      assert ops_opts[:dir] == Path.join(Fleet.Layout.ops_root(), name)
      assert ops_opts[:base_branch] == "origin/ops"

      # Et le jumeau code, sans quoi l'assertion ci-dessus passerait aussi si les deux faces
      # pointaient le meme arbre.
      _ = StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))
      assert_received {:probe_opts, code_opts}
      assert code_opts[:dir] == Path.join(Fleet.Layout.code_root(), name)
      assert code_opts[:base_branch] == "origin/main"
    end

    test "tier-0 : un conflit TOUT-SEMANTIQUE saute le producteur, et sans chief il atteint l'arch" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, true)
      # A1 — la passe chief a SON flag : sans lui, ce test n'exercerait plus ce que sa prose
      # affirme (le barreau tenté puis passé à l'arch) mais le chemin « pas armé ».
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_exception_pass?, true)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, AllSemanticProbe)

      # Le gain de tier-0 RACCOURCIT un chemin, il n'en casse aucun : un conflit dont rien n'est
      # trivial ne deviendra pas resoluble en y envoyant un producteur trois fois.
      #
      # Depuis le 2026-08-05 le cas va d'abord au CHIEF (L3), pas droit a l'arch (L4). Cette
      # fixture n'a pas de role `conflict_resolver` : la passe d'exception ne se dispatche pas, et
      # la ladder RETOMBE sur l'arch au lieu de laisser tomber le conflit. C'est exactement ce que
      # ce tuple prouve maintenant — pas le routage nominal, mais le fait que le dernier barreau
      # passe la main quand il ne peut pas etre grimpe.
      assert {:skipped, {:merge_blocked_escalated, 6}} =
               StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))

      # Et c'est LA le gain, pas le tuple : aucun round de producteur n'a ete brule.
      refute_received {:spawned, _issue, _opts}
    end

    test "A1 : passe chief DESARMEE (flag off) → escalade immediate, AUCUNE tentative de dispatch" do
      # Le kill-switch GitWand est ON (l'admin fait tourner le moteur) mais la passe chief — design
      # FLEET, flag propre — reste off : l'all-semantique escalade directement, et le log ne porte
      # AUCUNE trace d'un dispatch tenté. C'est la scission d'A1 : le choix admin n'éteint plus un
      # barreau de la fleet, et le barreau désarmé se dit dans le motif, pas en silence.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, true)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_exception_pass?, false)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, AllSemanticProbe)

      # La capture n'est plus LIEE : plus aucune assertion ne porte sur le texte du log (voir
      # ci-dessous). Elle reste pour avaler la sortie du dispatch, pas pour etre lue.
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:skipped, {:merge_blocked_escalated, 6}} =
                 StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))
      end)

      # ⚠ L'ANCIENNE FORME ÉTAIT `refute log =~ "chief exception pass NOT dispatched"` — une
      # assertion NÉGATIVE sur un libellé exact, donc verte le jour où la production renomme ce
      # message (revue 2026-08-19). Un test qui ne peut plus échouer ne garde plus rien.
      #
      # L'invariant réel est porté par les deux lignes ci-dessous, et aucune ne dérive avec un
      # texte : aucun pod n'a été demandé, et le motif d'escalade dit LEQUEL des chemins a mené là.
      # Deux observations qui ne dérivent avec aucun texte : la valeur de retour NOMME l'escalade,
      # et aucun pod n'a été demandé. Le fait que le motif dise LEQUEL des barreaux était désarmé
      # est épinglé là où un stub capture les commentaires (`verdict_exception_test`, « OFF
      # (explicite) » : `body =~ "n'est PAS armée"`) — le stub d'ICI est muet sur `post_comment`,
      # et le rendre bavard pour ce seul cas changerait la boîte aux lettres de 87 tests.
      refute_received {:spawned, _issue, _opts}
    end

    test "tier-0 : un conflit TOUT-ECRIVABLE est resolu par le runtime, sans pod" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, true)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, AllWritableProbe)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_applier, ResolvingApplier)

      # C'est ICI que la seam `:conflict_applier` gagne sa vie : sans injection, ce chemin exige un
      # vrai worktree git et ne serait jamais exerce.
      assert {:ok, {:auto_resolved, 6}} =
               StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))
    end

    test "A0 : sans jeton du rail MERGE, le rail conflit ne fait RIEN — il ne resout pas a moitie" do
      # ⚖ CE TEST A CHANGE D'OBJET AVEC LA SEPARATION DES RAILS (2026-08-20), ET SON ANCIEN OBJET
      # N'EXISTE PLUS.
      #
      # Il epinglait un chemin degrade precis : jeton `chief` absent → le tier 0 resout quand meme,
      # son rapport ne peut pas etre poste, et le warning devait NOMMER la reparation. Le commentaire
      # d'origine disait lui-meme ce que ca coutait : « le seal choisira rebase et sera mal classe »
      # — autrement dit, on resolvait un conflit puis on le rejetait en fusionnant sans son commit.
      #
      # Depuis que `chief` EST le rail de merge, ce chemin est INATTEIGNABLE : son jeton absent
      # arrete la tentative de merge, donc `route_merge_failure` n'est jamais appele, donc le moteur
      # tier-0 ne tourne pas du tout. Le rail conflit ne resout plus a moitie — il s'arrete d'un
      # bloc, sur son propre jeton, et le dit.
      #
      # C'est un GAIN, pas une perte de couverture : l'etat que l'ancien test decrivait etait
      # precisement celui ou le rail travaillait pour rien.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, true)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, AllWritableProbe)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_applier, ResolvingApplier)

      # La perte est FORCEE : un repertoire de jetons qui ne porte QUE celui du gatekeeper, donc
      # l'identite CHIEF est irresolvable et le rapport (avec son marqueur, seule marque du tier 0)
      # ne peut pas etre poste.
      Fleet.TestEnv.put_env_restoring(
        :lcars_fleet,
        :credentials_role_tokens_dir,
        Fleet.TestEnv.tmp_path("lcars-gk-only")
      )

      Fleet.TestEnv.put_role_token!("gatekeeper", "GK-TOKEN")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :role_token_unavailable} =
                   StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))
        end)

      # Le refus NOMME le role et la politique — un operateur sait quoi provisionner sans lire le
      # code. C'est tout ce que ce test garde de l'ancien : l'exigence que la panne PARLE.
      assert log =~ "chief"
      assert log =~ "fail-closed"

      # Et surtout : RIEN n'a ete tente. Pas de resolution orpheline, pas de merge de travers.
      refute log =~ "auto-resolved"
      refute log =~ "conflict-engine:pr-6"
    end

    # ❌ PAS de test pour la sonde MUETTE (`{:error, _}` → `:fall_through`), et la raison est
    # mesuree : dans ce harnais le chemin legacy converge sur le MEME observable que l'escalade
    # tier-0 — meme tuple de retour, et aucun spawn dans les deux cas. Un test ecrit ici
    # n'assertait rien. Le rendre discriminant demande de faire dispatcher un producteur au chemin
    # legacy, donc d'instrumenter le budget de rework du harnais : un geste de harnais, pas une
    # assertion. Non fait, plutot qu'un test vert qui ne separe rien.

    test "flag OFF : le diagnoser n'est meme pas consulte (le defaut reste le chemin legacy)" do
      # `conflict_diagnosis?` est false par defaut ; ce test epingle que le defaut ne traverse pas
      # tier-0 — sinon les trois tests ci-dessus prouveraient un chemin que la prod n'emprunte pas.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, false)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, AllWritableProbe)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_applier, ResolvingApplier)

      refute match?(
               {:ok, {:auto_resolved, 6}},
               StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))
             )
    end
  end
end
