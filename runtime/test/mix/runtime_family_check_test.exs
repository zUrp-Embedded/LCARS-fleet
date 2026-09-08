defmodule Mix.Tasks.Lcars.Contracts.RuntimeFamilyCheckTest do
  @moduledoc """
  Sept murs de la famille `runtime`, prouves contre des arbres FABRIQUES.

  `gates.no_runtime_seam`, `spawn.has_brief`, `spawn.gates_wired`,
  `spawner.result_deadline_cancelled`, `verdict.worker_envelope_unwrapped`,
  `gatekeeper.not_an_ordering_step`, `workflow.loader_arity`. Aucun n'avait de temoin.

  ## Ce que cette famille garde, et pourquoi ces murs-la sont fragiles

  Ce sont des murs de PRESENCE : ils cherchent une garde, un appel, une transition, dans un fichier
  a chemin fixe. Trois modes de defaillance leur sont propres, et aucun ne se voit sur le depot :

  1. **le fichier disparait** — zero occurrence, donc « aucune violation », donc vert pour toujours
     sur un contrat qui n'existe plus ;
  2. **le marqueur migre dans la prose** — un `{:error, :brief_required}` cite dans un `@doc`
     satisfait un grep naif, et le mur atteste alors sa propre documentation (BND-111) ;
  3. **le marqueur passe en commentaire** — un `# defp normalize(...)` desactive compte encore.

  Les trois sont exercees ici, mur par mur, parce qu'un depot sain ne peut en produire aucune.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Runtime

  defp arbre(fichiers) do
    root = Fleet.TestEnv.tmp_path("murs_runtime")
    on_exit(fn -> File.rm_rf!(root) end)

    for {rel, contenu} <- fichiers do
      chemin = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(chemin))
      File.write!(chemin, contenu)
    end

    root
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "gates.no_runtime_seam — un jugement appartient a un role, pas a la machinerie" do
    defp gates(corps), do: [{"lib/fleet/workflow/gates.ex", "defmodule G do\n#{corps}end\n"}]

    test "des gardes pures → vert" do
      assert %{status: :pass, evidence: []} =
               Runtime.check_gates_no_runtime_seam(arbre(gates("  def eval(x), do: x > 0\n")))
    end

    test "une lecture d'app-env est nommee" do
      assert %{status: :fail, evidence: [ev]} =
               Runtime.check_gates_no_runtime_seam(
                 arbre(gates("  def eval(_), do: Application.get_env(:a, :b)\n"))
               )

      assert ev =~ "Application.get_env"
    end

    test "⚠ TROIS CONTOURNEMENTS QU'UN GREP NAIF LAISSERAIT PASSER" do
      # `Application.get_env`/`fetch_env` et `apply(` sont les deux formes evidentes. Le mur lit
      # l'AST justement pour attraper les autres : `get_all_env`, `compile_env`, et le dispatch par
      # cible non statique — qui est la forme la PLUS pure de l'injection de module qu'on refuse.
      for {code, attendu} <- [
            {"  def eval(_), do: Application.get_all_env(:a)\n", "Application.get_all_env"},
            {"  def eval(_), do: Application.compile_env(:a, :b)\n", "Application.compile_env"},
            {"  def eval(f), do: f.()\n", "fonction injectee"},
            {"  def eval(_), do: apply(M, :f, [])\n", "apply/3"}
          ] do
        assert %{status: :fail, evidence: ev} =
                 Runtime.check_gates_no_runtime_seam(arbre(gates(code)))

        assert Enum.any?(ev, &(&1 =~ attendu)), "#{attendu} non detecte pour #{inspect(code)}"
      end
    end

    test "⚠ LE FICHIER ABSENT EST UN ECHEC, pas « aucune couture trouvee »" do
      assert %{status: :fail, evidence: [ev]} = Runtime.check_gates_no_runtime_seam(arbre([]))
      assert ev =~ "INSTRUMENT BROKEN"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "spawn.has_brief — les trois refus du spawn, executables et non documentes" do
    # ⚠ LES TROIS TUPLES OUVRENT LEUR LIGNE, ET CE N'EST PAS DU STYLE. La confirmation du mur est
    # ancree a gauche (`~r/^\s*\{:error, :brief_required\}/`) : un `:no_brief -> {:error, …}` sur
    # UNE ligne ne compte pas. C'est ce que `mix format` produit sur une clause `->` dont le corps
    # depasse, donc la forme reelle du spawner — et l'ancre est ce qui distingue le RETOUR d'une
    # garde d'une mention du meme atome au fil d'une expression.
    @spawner_ok """
    defmodule Fleet.Spawner do
      def spawn_pod(o) do
        with {:ok, b} <- fetch_brief(o),
             {:ok, l} <- CapProfile.fetch_lifetime_scope(o),
             {:ok, i} <- CapProfile.fetch_interlocutor(o) do
          {:ok, {b, l, i}}
        else
          :no_brief ->
            {:error, :brief_required}

          :no_scope ->
            {:error, :cap_profile_no_lifetime_scope}

          :no_who ->
            {:error, :cap_profile_no_interlocutor}
        end
      end
    end
    """

    test "les cinq gardes presentes → vert" do
      assert %{status: :pass, evidence: []} =
               Runtime.check_spawn_has_brief(arbre([{"lib/fleet/spawner.ex", @spawner_ok}]))
    end

    test "un refus manquant est nomme" do
      sans =
        String.replace(@spawner_ok, "{:error, :cap_profile_no_interlocutor}", "{:error, :autre}")

      assert %{status: :fail, evidence: ev} =
               Runtime.check_spawn_has_brief(arbre([{"lib/fleet/spawner.ex", sans}]))

      assert Enum.any?(ev, &(&1 =~ "without interlocutor"))
    end

    test "⚠ BND-111 — UN MARQUEUR DANS UN `@doc` N'EST PAS UNE GARDE" do
      # LE FAUX-VERT QUE CE MUR EXISTE POUR REFUSER, ET IL EST SUBTIL : `{:error, :brief_required}`
      # figure legitimement dans la doc de valeur de retour du spawner. Un grep du fichier entier
      # est donc satisfait par la documentation de ce qu'il est cense verifier — le controleur
      # anti-faux-vert attesterait sa propre prose. Les lignes de heredoc `@doc` sont retirees avant
      # comparaison.
      documente = """
      defmodule Fleet.Spawner do
        @doc \"\"\"
        Rend {:error, :brief_required} si le one-shot n'a pas de brief,
        {:error, :cap_profile_no_lifetime_scope} et {:error, :cap_profile_no_interlocutor} sinon.
        \"\"\"
        def spawn_pod(o) do
          with {:ok, l} <- CapProfile.fetch_lifetime_scope(o),
               {:ok, i} <- CapProfile.fetch_interlocutor(o),
               do: {:ok, {l, i}}
        end
      end
      """

      assert %{status: :fail, evidence: ev} =
               Runtime.check_spawn_has_brief(arbre([{"lib/fleet/spawner.ex", documente}]))

      assert Enum.any?(ev, &(&1 =~ "brief_required"))
      assert Enum.any?(ev, &(&1 =~ "lifetime_scope"))
    end

    test "⚠ UN REFUS COMMENTE NE COMPTE PAS NON PLUS" do
      commente =
        String.replace(
          @spawner_ok,
          "        {:error, :brief_required}",
          "        # {:error, :brief_required}"
        )

      assert %{status: :fail, evidence: ev} =
               Runtime.check_spawn_has_brief(arbre([{"lib/fleet/spawner.ex", commente}]))

      assert Enum.any?(ev, &(&1 =~ "brief_required"))
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "spawn.gates_wired — deux faits conjoints dans DEUX fichiers" do
    defp cablage(pod, launch_env),
      do: [
        {"lib/fleet/spawner/pod.ex", "defmodule P do\n#{pod}end\n"},
        {"lib/fleet/spawner/pod/launch_env.ex", "defmodule LE do\n#{launch_env}end\n"}
      ]

    @pod_ok "  def do_allocate(c), do: CapProfile.validate(c)\n  def do_launch(o), do: LaunchEnv.build(o)\n"
    @le_ok "  def build(o), do: Fleet.Credentials.Gate.validate(o)\n"

    test "les trois cablages presents → vert" do
      assert %{status: :pass, evidence: []} =
               Runtime.check_spawn_gates_wired(arbre(cablage(@pod_ok, @le_ok)))
    end

    test "⚠ LA MOITIE DANS L'AUTRE FICHIER COMPTE — un mur d'un seul fichier n'en tiendrait aucune" do
      # `pod.ex` appelle `LaunchEnv.build`, et c'est `LaunchEnv.build` qui chaine
      # `Credentials.Gate.validate`. La porte est donc cablee au spawn par DEUX faits conjoints
      # dans deux fichiers : garder le premier seul laisse une delegation creuse.
      assert %{status: :fail, evidence: [ev]} =
               Runtime.check_spawn_gates_wired(arbre(cablage(@pod_ok, "  def build(o), do: o\n")))

      assert ev =~ "launch_env.ex"
      assert ev =~ "Credentials.Gate.validate"
    end

    test "la garde de containment manquante est nommee" do
      assert %{status: :fail, evidence: [ev]} =
               Runtime.check_spawn_gates_wired(
                 arbre(cablage("  def do_launch(o), do: LaunchEnv.build(o)\n", @le_ok))
               )

      assert ev =~ "CapProfile.validate"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "spawner.result_deadline_cancelled — le frein qui tue les pods permanents au cycle 2" do
    @pod_deadline """
    defmodule P do
      def arm(s), do: {:keep_state, s, [{:state_timeout, 60_000, :result_deadline}]}
      def got(s), do: {:next_state, :extracting, s}
    end
    """

    test "state_timeout + transition annulante, aucun rustine → vert" do
      assert %{status: :pass, evidence: []} =
               Runtime.check_result_deadline_cancelled(
                 arbre([{"lib/fleet/spawner/pod.ex", @pod_deadline}])
               )
    end

    test "sans la transition annulante, le deadline ne s'annule jamais" do
      sans = String.replace(@pod_deadline, "{:next_state, :extracting, s}", "{:keep_state, s}")

      assert %{status: :fail, evidence: [ev]} =
               Runtime.check_result_deadline_cancelled(
                 arbre([{"lib/fleet/spawner/pod.ex", sans}])
               )

      assert ev =~ ":extracting"
    end

    test "⚠ LA RUSTINE `forever -> 60_000` EST REFUSEE MEME QUAND TOUT LE RESTE EST VERT" do
      # Un mur qui ne verifierait que la presence des deux mecanismes laisserait revenir le
      # pansement qui les rendait inoffensifs. La troisieme preuve est une ABSENCE exigee, pas une
      # presence — et c'est la seule des trois de cette forme.
      avec = @pod_deadline <> "\n# \"forever\" -> 60_000\n"

      assert %{status: :fail, evidence: ev} =
               Runtime.check_result_deadline_cancelled(
                 arbre([{"lib/fleet/spawner/pod.ex", avec}])
               )

      assert Enum.any?(ev, &(&1 =~ "band-aid"))
    end

    test "un `:result_deadline` en COMMENTAIRE ne prouve pas l'armement" do
      commente =
        String.replace(
          @pod_deadline,
          "  def arm(s), do: {:keep_state, s, [{:state_timeout, 60_000, :result_deadline}]}",
          "  # {:state_timeout, 60_000, :result_deadline}"
        )

      assert %{status: :fail, evidence: ev} =
               Runtime.check_result_deadline_cancelled(
                 arbre([{"lib/fleet/spawner/pod.ex", commente}])
               )

      assert Enum.any?(ev, &(&1 =~ "not a :state_timeout"))
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "verdict.worker_envelope_unwrapped — la decision reste enfouie" do
    test "le depliage present → vert" do
      assert %{status: :pass} =
               Runtime.check_verdict_envelope_unwrapped(
                 arbre([
                   {"lib/fleet/pilot/step_run_consumer.ex",
                    "defmodule C do\n  def go(e), do: unwrap_worker_envelope(e)\nend\n"}
                 ])
               )
    end

    test "⚠ LE FICHIER SUPPRIME EST UN ECHEC — la route de verdict EST ce consommateur" do
      # Un `not File.exists?(abs) or …` rendrait le rail VERT si le fichier etait efface :
      # l'invariant disparu, et le mur d'accord. Son absence est elle-meme le defaut, et deplacer
      # le depliage ailleurs est un changement de design qui DOIT mettre ce mur a jour.
      assert %{status: :fail, evidence: ev} = Runtime.check_verdict_envelope_unwrapped(arbre([]))
      assert ev != []
    end

    test "un depliage COMMENTE ne compte pas" do
      assert %{status: :fail} =
               Runtime.check_verdict_envelope_unwrapped(
                 arbre([
                   {"lib/fleet/pilot/step_run_consumer.ex",
                    "defmodule C do\n  # unwrap_worker_envelope(e)\n  def go(e), do: e\nend\n"}
                 ])
               )
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "gatekeeper.not_an_ordering_step — un raisonneur LLM dans la mecanique" do
    defp carte(nom, contenu), do: {"priv/catalogue/workflow/workflow_maps/#{nom}.yaml", contenu}

    test "une carte sans etape gatekeeper → vert" do
      assert %{status: :pass, evidence: []} =
               Runtime.check_gatekeeper_not_a_step(
                 arbre([carte("std", "steps:\n  - role: engineer\n")])
               )
    end

    test "une etape `role: gatekeeper` est nommee, avec sa ligne" do
      assert %{status: :fail, evidence: [ev]} =
               Runtime.check_gatekeeper_not_a_step(
                 arbre([carte("std", "steps:\n  - role: engineer\n  - role: gatekeeper\n")])
               )

      assert ev =~ "std.yaml:3"
    end

    test "⚠ `target_role: gatekeeper` EST LEGITIME — l'ancre de gauche fait toute la difference" do
      # Le gatekeeper EST la cible d'exception d'une escalade. Sans l'ancre `\\brole:`, la
      # sous-chaine `role:` de `target_role:` produit un faux positif sur une carte parfaitement
      # canonique — et un mur qui accuse le nominal est un mur qu'on desactive.
      assert %{status: :pass, evidence: []} =
               Runtime.check_gatekeeper_not_a_step(
                 arbre([
                   carte(
                     "qa",
                     "steps:\n  - role: engineer\non_escalation:\n  target_role: gatekeeper\n"
                   )
                 ])
               )
    end

    test "⚠ UN CORPUS DE CARTES ABSENT EST UN ECHEC — le mur ne peut plus rien attester" do
      assert %{status: :fail, evidence: [ev]} = Runtime.check_gatekeeper_not_a_step(arbre([]))
      assert ev =~ "corpus absent"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  describe "workflow.loader_arity — une carte chargee sans son catalogue" do
    defp loader_appels(sites) do
      [
        {"lib/fleet/workflow/loader.ex",
         "defmodule Fleet.Workflow.Loader do\n  def load!(n, o), do: {n, o}\nend\n"}
        | sites
      ]
    end

    defp appelant(n, corps), do: {"lib/fleet/rail#{n}.ex", "defmodule R#{n} do\n#{corps}end\n"}

    defp cinq_binaires do
      for i <- 1..5, do: appelant(i, "  def go(n, o), do: Fleet.Workflow.Loader.load!(n, o)\n")
    end

    test "assez d'appels binaires et aucun unaire → vert" do
      assert %{status: :pass, evidence: []} =
               Runtime.check_workflow_loader_arity(arbre(loader_appels(cinq_binaires())))
    end

    test "un appel UNAIRE est nomme, avec son fichier et sa ligne" do
      sites =
        cinq_binaires() ++ [appelant(9, "  def go(n), do: Fleet.Workflow.Loader.load!(n)\n")]

      assert %{status: :fail, evidence: ev} =
               Runtime.check_workflow_loader_arity(arbre(loader_appels(sites)))

      assert Enum.any?(ev, &(&1 =~ "rail9.ex:2" and &1 =~ "load!(_)"))
    end

    test "⚠ LE TUBE EST DEPLIE — sinon l'arite se lit fausse DANS LES DEUX SENS" do
      # L'AST d'un `|>` garde la valeur tubee dans le noeud du pipe : lire l'arite sur le noeud
      # d'appel seul rend `n |> load!()` pour zero argument et `n |> load!(o)` pour un seul. Le
      # premier serait ignore (ni binaire ni unaire), le second accuse a tort.
      sites =
        cinq_binaires() ++
          [appelant(9, "  def go(n, o), do: n |> Fleet.Workflow.Loader.load!(o)\n")]

      assert %{status: :pass, evidence: []} =
               Runtime.check_workflow_loader_arity(arbre(loader_appels(sites)))

      unaire_tube =
        cinq_binaires() ++ [appelant(8, "  def go(n), do: n |> Fleet.Workflow.Loader.load!()\n")]

      assert %{status: :fail, evidence: ev} =
               Runtime.check_workflow_loader_arity(arbre(loader_appels(unaire_tube)))

      assert Enum.any?(ev, &(&1 =~ "rail8.ex"))
    end

    test "⚠ LA CAPTURE `&Loader.load!/1` COMPTE — un appel n'apparait nulle part dans l'AST" do
      sites =
        cinq_binaires() ++
          [appelant(7, "  def go, do: safe_load(&Fleet.Workflow.Loader.load!/1)\n")]

      assert %{status: :fail, evidence: ev} =
               Runtime.check_workflow_loader_arity(arbre(loader_appels(sites)))

      assert Enum.any?(ev, &(&1 =~ "&Loader.load!/1"))
    end

    test "trop peu d'appels binaires → INSTRUMENT BROKEN : le marcheur ne reconnait plus la forme" do
      sites = Enum.take(cinq_binaires(), 2)

      assert %{status: :fail, evidence: [ev]} =
               Runtime.check_workflow_loader_arity(arbre(loader_appels(sites)))

      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "expected 5+"
    end
  end
end
