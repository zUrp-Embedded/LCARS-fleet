defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGateTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGate
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx

  # The forge seam, reduced to the two reads the gate makes. Both answers are driven by `forge_opts`
  # so a test states its world in one place instead of defining a module per case.
  defmodule Forge do
    def get_pull(_repo, n, opts) do
      case Keyword.get(opts, :_pull, :default) do
        :default ->
          {:ok,
           %{
             "number" => n,
             "head" => %{"sha" => "cafebabe1234567890"},
             "updated_at" => Keyword.get(opts, :_updated_at, iso_now(0))
           }}

        other ->
          other
      end
    end

    def commit_ci_state(_repo, _sha, opts), do: Keyword.get(opts, :_ci, {:ok, :none})

    defp iso_now(age_sec) do
      DateTime.utc_now() |> DateTime.add(-age_sec, :second) |> DateTime.to_iso8601()
    end

    def iso_ago(age_sec), do: iso_now(age_sec)
  end

  # A forge that must NEVER be called: the `ignore` policy has to short-circuit BEFORE any network
  # read, otherwise "the card does not require the CI" would still cost two forge calls per tick.
  defmodule ForbiddenForge do
    def get_pull(_repo, _n, _opts), do: raise("get_pull called under an :ignore policy")
    def commit_ci_state(_repo, _sha, _opts), do: raise("commit_ci_state called under :ignore")
  end

  defp ctx(forge, forge_opts) do
    %Ctx{
      forge: forge,
      loader: nil,
      workflow_map_loader: fn _ -> {:ok, %{}} end,
      spawner: nil,
      task_queue: nil,
      resolver: fn _, _ -> {:ok, %{}} end,
      repo: "fleet/demo",
      forge_opts: forge_opts,
      wake_recovery: fn _, f, _ -> f.() end,
      opts: []
    }
  end

  defp decide(forge_opts, policy \\ :required, forge \\ Forge),
    do: CiGate.decide(42, "lcars/issue-7-engineer", ctx(forge, forge_opts), fn -> policy end)

  # The workflow probe is a SEAM on `ctx.opts`, like every other injected read on this rail: the
  # gate must be drivable without a forge, and "does this repo declare a workflow" is exactly the
  # kind of fact a test states rather than fetches.
  defp decide_with_lister(forge_opts, lister) do
    c = %{ctx(Forge, forge_opts) | opts: [list_dir_fun: lister]}
    CiGate.decide(42, "lcars/issue-7-engineer", c, fn -> :required end)
  end

  describe "the card governs" do
    test ":ignore short-circuits before touching the forge" do
      assert {:proceed, nil} = decide([], :ignore, ForbiddenForge)
    end
  end

  describe "the three states" do
    test "success -> proceed, and the FACT carries the sha the gate measured" do
      assert {:proceed, %{state: :success, sha: "cafebabe1234567890"}} =
               decide(_ci: {:ok, :success})
    end

    test "failure -> refuse, and the message names the sha (the marker keys on it)" do
      assert {:refuse, :ci_red, message} = decide(_ci: {:ok, :failure})
      assert message =~ "cafebabe"
      assert message =~ "ROUGE"
    end

    test "pending on a fresh head -> bounded wait, no judge" do
      assert {:wait, :ci_pending} = decide(_ci: {:ok, :pending})
    end

    test "NO status at all is NOT success — it waits like pending" do
      assert {:wait, :ci_pending} = decide(_ci: {:ok, :none})
    end
  end

  describe "the deadline is the point" do
    test "pending past the deadline escalates instead of waiting one more tick forever" do
      stale = Forge.iso_ago(CiGate.pending_deadline_sec() + 60)

      assert {:escalate, {:ci_stalled, :pending}, message} =
               decide(_ci: {:ok, :pending}, _updated_at: stale)

      assert message =~ "runner"
    end

    test "an absent rail past the deadline escalates under its OWN name (:none, not :pending)" do
      stale = Forge.iso_ago(CiGate.pending_deadline_sec() + 60)

      assert {:escalate, {:ci_stalled, :none}, _} = decide(_ci: {:ok, :none}, _updated_at: stale)
    end

    test "AUCUN workflow dans le depot → impasse nommee AU PREMIER TICK, pas au bout de 45 min" do
      # `:none` a deux causes et elles ne meritent pas la meme patience. « pas encore de statut »
      # est une course qui n'a pas rendu ; « aucun workflow ici » est un statut qui ne viendra
      # jamais. Mesure 2026-08-12 : un depot importe de GitHub, carte `ci: required`, trois quarts
      # d'heure d'attente avant de demander si un runner servait le label. Le runner allait bien.
      # Il n'y avait rien a executer, et c'etait lisible en une lecture.
      lister = fn "fleet/demo", _dir, _opts -> {:error, :not_found} end

      assert {:escalate, {:ci_impossible, :no_workflow}, msg} =
               decide_with_lister([_ci: {:ok, :none}], lister)

      # Le message dit les DEUX sorties, parce qu'aucune n'est evidente pour qui lit le ticket.
      assert msg =~ "AUCUN WORKFLOW"
      assert msg =~ ".gitea/workflows"
      assert msg =~ "ignore"
    end

    test "un workflow declare → l'attente bornee reprend ses droits (rien ne change)" do
      lister = fn
        "fleet/demo", ".gitea/workflows", _ -> {:ok, ["ci.yml"]}
        "fleet/demo", _, _ -> {:error, :not_found}
      end

      assert {:wait, :ci_pending} = decide_with_lister([_ci: {:ok, :none}], lister)
    end

    test "`.github/workflows` compte aussi — Gitea sert les deux" do
      lister = fn
        "fleet/demo", ".github/workflows", _ -> {:ok, ["build.yaml"]}
        "fleet/demo", _, _ -> {:error, :not_found}
      end

      assert {:wait, :ci_pending} = decide_with_lister([_ci: {:ok, :none}], lister)
    end

    test "un repertoire sans fichier de workflow n'est pas un rail" do
      # Le dossier existe et ne porte que du bruit : declarer l'emplacement n'est pas declarer un
      # workflow, et rien ne s'executera.
      lister = fn "fleet/demo", _dir, _ -> {:ok, ["README.md", ".keep"]} end

      assert {:escalate, {:ci_impossible, :no_workflow}, _} =
               decide_with_lister([_ci: {:ok, :none}], lister)
    end

    test "listing ILLISIBLE → on attend : inconnu n'est pas absent" do
      # Meme posture que partout ailleurs sur ce rail : une forge muette differe, elle ne fabrique
      # jamais un verdict. Escalader ici transformerait une panne reseau en impasse declaree.
      lister = fn "fleet/demo", _dir, _ -> {:error, {:http, 500, "boom"}} end

      assert {:wait, :ci_pending} = decide_with_lister([_ci: {:ok, :none}], lister)
    end

    test "just under the deadline still waits — the bound is a threshold, not a mood" do
      fresh = Forge.iso_ago(CiGate.pending_deadline_sec() - 60)
      assert {:wait, :ci_pending} = decide(_ci: {:ok, :pending}, _updated_at: fresh)
    end

    test "an unreadable date waits rather than escalating on a date it could not read" do
      # L'arbitrage d'origine tient et ce test le garde : une date illisible NE DOIT PAS escalader
      # (`{:escalate, {:ci_stalled, _}, _}` poserait `lcars-awaits-arch` et parquerait le ticket sur
      # une date qu'on n'a pas su lire). Ce qui a change, c'est le MOTIF : sans date, l'age vaut 0 et
      # `0 > @pending_deadline_sec` est faux A JAMAIS — l'echeance n'est pas lointaine, elle est
      # HORS D'ATTEINTE. Le motif le dit maintenant, au lieu de se confondre avec une CI qui tourne.
      assert {:wait, {:ci_deadline_unreachable, :no_pull_date}} =
               decide(_ci: {:ok, :pending}, _updated_at: "pas-une-date")
    end

    test "TEMOIN — une date LISIBLE et fraiche rend le motif ordinaire, pas celui-la" do
      # Sans ce temoin, rendre `{:ci_deadline_unreachable, _}` inconditionnellement passerait le test
      # ci-dessus : c'est lui qui prouve que les deux etats sont DISTINGUABLES.
      fresh = Forge.iso_ago(60)
      assert {:wait, :ci_pending} = decide(_ci: {:ok, :pending}, _updated_at: fresh)
    end

    test "le motif hors-d'atteinte porte l'etiquette de sa porte — il n'invente pas un mur" do
      # Meme `wait/ci` que ses deux voisins : du cote du ticket c'est le meme fait (arrete a la porte
      # CI). Un label neuf ferait croire a un nouveau mecanisme la ou il n'y a qu'un motif nomme.
      assert Fleet.Labels.wait_for({:ci_deadline_unreachable, :no_pull_date}) ==
               Fleet.Labels.wait_for({:ci_unreadable, :timeout})
    end
  end

  describe "unknown is never green" do
    test "an unreadable PR defers, it does not guess a state" do
      assert {:wait, {:ci_head_unreadable, :boom}} = decide(_pull: {:error, :boom})
    end

    test "a PR without a head sha defers under its own name" do
      assert {:wait, {:ci_head_unreadable, {:no_head_sha, _}}} =
               decide(_pull: {:ok, %{"number" => 42}})
    end

    test "an unreadable CI status defers — assuming green would spend a jury on unmeasured code" do
      assert {:wait, {:ci_unreadable, :timeout}} = decide(_ci: {:error, :timeout})
    end
  end

  # LA JOINTURE, ET ELLE N'ETAIT TENUE PAR PERSONNE. Les tests ci-dessus bouchent la policy
  # (`fn -> :required end`) : ils prouvent que la porte GATE sur `:required`, pas qu'une carte le
  # produise. `LoaderV25Test` prouve l'autre bout — `spec.ci` traverse `normalize/1`. Entre les
  # deux, `issue_card_ci/2` compare a un LITTERAL, et remplacer `"required"` par `"requis"` laissait
  # les 2443 tests verts (mesure 2026-08-08).
  #
  # C'est la classe « ecrivain et lecteur en desaccord d'identite » : la carte ECRIT un token, le
  # lecteur en attend un autre, et la porte se desarme sans que rien ne rougisse.
  describe "issue_card_ci/2 — la carte arme reellement la porte" do
    defmodule RoutingForge do
      @moduledoc false
      def get_route(_repo, 7, _opts), do: {:ok, {"standard-qa", "review"}}
      def get_route(_repo, 9, _opts), do: {:ok, {"workshop-direct", "build"}}
      def get_route(_repo, _n, _opts), do: :none
    end

    defp card_ctx(loader, opts \\ []) do
      %Ctx{
        forge: RoutingForge,
        loader: nil,
        workflow_map_loader: loader,
        spawner: nil,
        task_queue: nil,
        resolver: fn _, _ -> {:ok, %{}} end,
        repo: "fleet/demo",
        forge_opts: [],
        wake_recovery: fn _, f, _ -> f.() end,
        opts: opts
      }
    end

    defp canon_loader do
      canon = Application.app_dir(:lcars_fleet, "priv/catalogue/workflow/canon/workflow_maps")
      fn name -> Fleet.Workflow.Loader.load!(name, workflow_maps_root: canon) end
    end

    test "une carte canon qui declare `ci: required` rend :required — bout en bout" do
      # Le loader CANON, pas un litteral recopie : si la carte cesse de declarer `ci`, ou si le
      # loader cesse de le porter, ce test tombe.
      #
      # `safe_load/2` enveloppe DEJA le retour du loader : rendre `{:ok, map}` ici produirait
      # `{:ok, {:ok, map}}` et la clause `when is_map(map)` echouerait — un resultat par forme,
      # pas par contenu.
      #
      # ET L'ABSENCE D'ALARME EST LA MOITIE DE LA PROPRIETE. Mesure : renommer le litteral
      # `"required"` en `"requis"` dans `Roles.ci/1` laissait les 2449 tests verts, parce que la
      # carte tombait alors dans la clause de garde — qui repond `:required` elle aussi. Le
      # resultat seul ne peut donc pas distinguer « la carte a ete LUE » de « la carte n'a pas ete
      # comprise et on a ferme par defaut ». Le log, lui, le peut.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Fleet.Pilot.StepDispatcher.ReviewLifecycle.issue_card_ci(
                   "lcars/issue-7-engineer",
                   card_ctx(canon_loader())
                 ) == :required
        end)

      refute log =~ "no readable `ci` policy",
             "standard-qa declare `ci: required` : ce :required doit venir de la LECTURE de la " <>
               "carte, pas de la clause de garde qui rend la meme valeur quand elle ne comprend pas"
    end

    test "une carte canon qui declare `ci: ignore` rend :ignore — la derogation traverse aussi" do
      # Le jumeau du test ci-dessus, et il n'est pas decoratif : tant que `:ignore` etait ce que
      # rendaient AUSSI l'absence de champ, l'absence de carte et l'echec de lecture, il ne pouvait
      # rien distinguer. Maintenant qu'il est le seul chemin vers `:ignore`, il mesure la
      # DEROGATION — et workshop-direct est le cas ou elle est mecaniquement obligatoire (aucun runner
      # ne sert une PR basee sur ops).
      assert Fleet.Pilot.StepDispatcher.ReviewLifecycle.issue_card_ci(
               "lcars/issue-9-scribe",
               card_ctx(canon_loader())
             ) == :ignore
    end

    test "une carte qui ne declare RIEN ne prend PAS la branche permissive" do
      # LE RENVERSEMENT. Ce test assertait `:ignore` — il epinglait le defaut qu'on vient de tuer :
      # `spec.ci` etant desormais obligatoire au schema, une carte muette n'a pas pu passer par
      # `Loader.load!`. Repondre `:ignore` sur ce chemin reconstruirait exactement le trou ferme :
      # la carte non declaree prenant silencieusement la branche qui n'oppose rien.
      loader = fn _ -> %{"name" => "muette", "steps" => %{}} end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Fleet.Pilot.StepDispatcher.ReviewLifecycle.issue_card_ci(
                   "lcars/issue-7-engineer",
                   card_ctx(loader)
                 ) == :required
        end)

      assert log =~ "no readable `ci` policy",
             "l'alarme doit etre DITE : une carte qui contourne le schema est un defaut, pas un cas"
    end

    @tag :tmp_dir
    test "sans route gravee, la policy suit la carte du PROJET — comme le jury, enfin", %{
      tmp_dir: tmp
    } do
      # LA DIVERGENCE QUE LE COMMENTAIRE COUVRAIT. `issue_card_ci/2` se disait « lue exactement
      # comme son jury, par le meme fallback » ; son jumeau `issue_card_jury/2` lisait la carte du
      # PROJET, celui-ci rendait un `:ignore` en dur. Une PR sans route gravee — PR humaine, orphelin
      # adopte — etait donc jugee sous le jury du projet et sous AUCUNE politique CI, sur un projet
      # dont la carte en reclame une. L'issue 8 n'a pas de route (RoutingForge rend `:none`).
      proj = Path.join(tmp, "demo")
      File.mkdir_p!(proj)

      # La carte EXISTE avant d'etre declaree, et la declaration dit ou elle vit : depuis 6-125 une
      # `workflow_map` explicite que le loader ne sait pas resoudre est REFUSEE a l'ecriture. Le
      # fixture posait sa carte apres coup — donc, a l'instant de la declaration, `gated` n'existait
      # nulle part. L'ordre inverse n'etait pas gratuit, c'etait le trou que la fiche decrit.
      maps = Path.join(tmp, "maps")
      File.mkdir_p!(maps)

      File.write!(Path.join(maps, "gated.yaml"), """
      kind: WorkflowMap
      metadata:
        name: gated
      spec:
        max_rework_rounds: 1
        jury: [qualifier]
        ci: required
        steps:
          only:
            role: engineer
      """)

      :ok =
        Fleet.Project.Intensity.write(proj,
          intensity_level: "C2",
          intensity_justification: "x",
          workflow_map: "gated",
          workflow_maps_root: maps
        )

      ctx = card_ctx(canon_loader(), code_root: tmp, workflow_maps_root: maps)

      assert Fleet.Pilot.StepDispatcher.ReviewLifecycle.issue_card_ci(
               "lcars/issue-8-engineer",
               ctx
             ) == :required
    end
  end
end
