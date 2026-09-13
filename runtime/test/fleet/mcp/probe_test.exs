defmodule Fleet.MCP.PodTools.ProbeTest do
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools.Probe

  @moduledoc """
  Probe subject derivation, declaration parsing and result preservation with injected
  forge callbacks. Serialized because :mcp_pod_resolver, :mcp_probe_forge_client and
  the shared :forge_actions configuration are node-global.
  """

  # ── Coutures ───────────────────────────────────────────────────────────────────────────────────

  defmodule ForgeStub do
    @moduledoc false
    def pr_refs(_repo, pr, _opts) do
      send(self(), {:pr_refs, pr})

      {:ok,
       %{
         head_sha: "head" <> String.duplicate("a", 36),
         base_sha: "base" <> String.duplicate("b", 36),
         head_ref: "lcars/issue-4-engineer",
         base_ref: "main"
       }}
    end

    def repo_full_name(id, _opts) do
      send(self(), {:repo_full_name, id})
      {:ok, "fleet/chifoumi"}
    end

    def get_file(repo, path, opts) do
      send(self(), {:get_file, repo, path, Keyword.get(opts, :ref)})

      {:ok,
       %{
         content: """
         # projet

         ## Test

         sh test.sh

         ## Harness

         tests/ conftest.py

         ## Gotchas

         rien
         """,
         sha: "x"
       }}
    end
  end

  defmodule ActionsStub do
    @moduledoc false
    def dispatch_workflow(repo, wf, ref, inputs, _opts) do
      send(self(), {:dispatch, repo, wf, ref, inputs})
      {:ok, %{run_id: 77}}
    end

    def run(_repo, _id, _opts), do: {:ok, %{"status" => "success", "conclusion" => "success"}}

    def run_logs(_repo, _id, _opts) do
      {:ok,
       """
       ===== job relevance (11) =====
       LCARS-PROBE probe=test-relevance base=bbb head=aaa
       ===== TÉMOIN =====
       LCARS-PROBE witness_exit=0
       LCARS-PROBE reverted_exit=1
       LCARS-PROBE verdict=relevant harness=tests/,conftest.py
       """}
    end
  end

  setup do
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :mcp_probe_forge_client, ForgeStub)
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :forge_actions, ActionsStub)

    # Numeric binding exercises dispatched pods that carry repo_id without a repository name.
    Fleet.TestEnv.put_env_restoring(
      :lcars_fleet,
      :mcp_pod_resolver,
      fn _pod_id -> {:ok, %{role: "qualifier", repo: nil, repo_id: 161}} end
    )

    :ok
  end

  defp judge_pod_id, do: Fleet.PodId.for_pr("fleet/chifoumi", 5, "qualifier")

  # ── Ce qui compte ──────────────────────────────────────────────────────────────────────────────

  describe "le sujet vient du CANAL, jamais du fil" do
    test "dépôt, PR, SHAs et chemins sont tous dérivés — le juge n'en fournit aucun" do
      assert {:ok, facts} = Probe.run(judge_pod_id(), "test-relevance")

      # Le dépôt : traduit depuis `repo_id`, parce qu'un pod dispatché n'a pas la chaîne.
      assert_received {:repo_full_name, 161}
      # La PR : lue dans le pod_id, par l'autorité qui l'a construit.
      assert_received {:pr_refs, 5}

      assert_received {:dispatch, "fleet/chifoumi", "probe-test-relevance.yml", "main", inputs}

      assert inputs["base_sha"] =~ "base"
      assert inputs["head_sha"] =~ "head"
      assert inputs["harness"] == "tests/ conftest.py"
      assert inputs["test_cmd"] == "sh test.sh"

      assert facts["verdict"] == "relevant"
      assert facts["run_id"] == 77
    end

    test "les déclarations sont lues AU SHA LIVRÉ, pas sur main" do
      # Une livraison qui déplace ses tests met à jour sa déclaration DANS LA MÊME PR. Lire `main`
      # mesurerait la livraison d'aujourd'hui avec la carte d'hier.
      assert {:ok, _} = Probe.run(judge_pod_id(), "test-relevance")
      assert_received {:get_file, "fleet/chifoumi", "CLAUDE.md", ref}
      assert ref =~ "head"
      refute ref == "main"
    end

    test "un juge NE PEUT PAS choisir sa base : ses inputs n'écrasent pas ceux du rail" do
      assert {:ok, _} =
               Probe.run(judge_pod_id(), "test-relevance", %{
                 "base_sha" => "la-base-qui-m-arrange",
                 "harness" => "tout/",
                 "mien" => "gardé"
               })

      assert_received {:dispatch, _, _, _, inputs}
      refute inputs["base_sha"] == "la-base-qui-m-arrange"
      refute inputs["harness"] == "tout/"
      # Ce qui n'entre pas en collision avec le rail, lui, passe : la sonde peut déclarer ses
      # propres entrées sans que ce module les connaisse.
      assert inputs["mien"] == "gardé"
    end

    test "un pod qui n'est pas juge d'une PR est refusé, pas sondé au hasard" do
      # Un producteur est minté `for_issue/3`. Sonder « la PR » d'un pod qui n'en a pas voudrait
      # dire en inventer une.
      producer = Fleet.PodId.for_issue("fleet/chifoumi", 4, "engineer")
      assert {:error, :not_a_deliverable_judge} = Probe.run(producer, "test-relevance")
    end
  end

  describe "le catalogue de sondes est une DONNÉE" do
    test "un nom inconnu est refusé en ÉNUMÉRANT ce qui existe" do
      # Un refus qui ne dit pas quoi écrire à la place renvoie l'appelant par le même appel.
      assert {:error, {:unknown_probe, "invente", known}} =
               Probe.run(judge_pod_id(), "invente")

      assert "test-relevance" in known
    end

    test "le nom public ne porte PAS le préfixe `probe-`, le fichier si" do
      # La garde de nommage vit dans le FICHIER (un contexte `probe-… / …` ne matche pas `CI / *`).
      # Le nom que le juge écrit n'a pas à la porter — et s'il la portait, un catalogue pourrait
      # pointer ailleurs et la contourner.
      assert {:ok, _} = Probe.run(judge_pod_id(), "test-relevance")
      assert_received {:dispatch, _, workflow, _, _}
      assert String.starts_with?(workflow, "probe-")
      refute String.starts_with?("test-relevance", "probe-")
    end
  end

  # Declaration cases below cover ambiguous headings and fenced examples beyond the nominal stub.
  describe "declarations/3 — ce que le parseur lit, et ce qu'il refuse de lire" do
    defp md_forge(content) do
      Module.create(
        :"Elixir.MdForge#{System.unique_integer([:positive])}",
        quote do
          def get_file(_repo, _path, _opts), do: {:ok, %{content: unquote(content), sha: "x"}}
        end,
        Macro.Env.location(__ENV__)
      )
      |> elem(1)
    end

    defp declared(content) do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :mcp_probe_forge_client, md_forge(content))
      {:ok, d} = Probe.declarations("fleet/p", "sha")
      d
    end

    test "⚠ LE TITRE DANS UN BLOC DE CODE N'EST PAS UN TITRE" do
      # The template documents Harness inside a fence; that example must not become a declaration.
      tpl = File.read!(Path.join(File.cwd!(), "priv/catalogue/project_template/main/CLAUDE.md"))

      # Le template SEUL ne déclare rien : c'est de la documentation, pas une déclaration.
      assert declared(tpl).harness == ""

      # Et sous la doc, la vraie déclaration est lue — elle seule.
      d = declared(tpl <> "\n## Harness\n\nsrc/tests/\n")
      assert d.harness == "src/tests/"
      refute d.harness =~ "À quoi elle sert"
    end

    test "⚠ `## Test suite` N'EST PAS `## Test` — le titre est le nom, seul sur sa ligne" do
      # A word boundary after Test also matches Test suite; require the entire heading.
      d = declared("## Test suite\n\nsh faux.sh\n\n## Test\n\nsh vrai.sh\n")
      assert d.test_cmd == "sh vrai.sh"

      # Et l'ordre inverse ne change rien : ce n'est pas « le premier qui commence par Test ».
      d2 = declared("## Test\n\nsh vrai.sh\n\n## Test suite\n\nsh faux.sh\n")
      assert d2.test_cmd == "sh vrai.sh"
    end

    test "TÉMOIN — un corps ENCADRÉ reste lisible" do
      # Ignoring fenced headings must not erase a legitimate fenced section body.
      d = declared("## Test\n\n```\nmix test\n```\n\n## Doc\n\nx\n")
      assert d.test_cmd == "mix test"
    end

    test "un `## Test` MULTI-LIGNES reste un script, il n'est pas aplati" do
      # Preserve two commands: flattening newlines would produce make build make test.
      d = declared("## Test\n\nmake build\nmake test\n\n## Doc\n\nx\n")
      assert d.test_cmd == "make build\nmake test"
    end

    test "section absente → chaîne vide, jamais une devinette" do
      d = declared("# projet\n\nrien de contractuel ici\n")
      assert d.harness == ""
      assert d.test_cmd == ""
    end

    test "`CLAUDE.md` absent → pas une erreur : c'est le cas `inapplicable`" do
      defmodule NoFile do
        @moduledoc false
        def get_file(_r, _p, _o), do: {:error, :not_found}
      end

      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :mcp_probe_forge_client, NoFile)
      assert {:ok, %{harness: "", test_cmd: ""}} = Probe.declarations("fleet/p", "sha")
    end
  end

  describe "facts/1 — on rapporte, on n'interprète pas" do
    test "les lignes tardives gagnent, et rien d'autre n'est décidé" do
      facts =
        Probe.facts("""
        bruit
        LCARS-PROBE probe=test-relevance base=b head=h
        LCARS-PROBE witness_exit=0
        LCARS-PROBE verdict=blind harness=tests/
        """)

      assert facts["verdict"] == "blind"
      assert facts["witness_exit"] == "0"
      assert facts["base"] == "b"
    end

    test "`blind` reste `blind` et `inapplicable` reste `inapplicable`" do
      # Preserve the measured verdict; inapplicable is absence of measurement, not success.
      assert Probe.facts("LCARS-PROBE verdict=blind")["verdict"] == "blind"

      inapp = Probe.facts("LCARS-PROBE verdict=inapplicable reason=head-suite-red")
      assert inapp["verdict"] == "inapplicable"
      assert inapp["reason"] == "head-suite-red"
    end

    test "aucun fait dans les logs → map VIDE, jamais un verdict inventé" do
      # L'absence de fait est un état lisible. Un défaut ici rendrait « la sonde n'a rien dit »
      # indiscernable de « la sonde a dit que tout va bien ».
      assert Probe.facts("des logs sans le moindre marqueur\n") == %{}
    end
  end

  describe "l'état du run voyage avec les faits" do
    defmodule Cancelled do
      @moduledoc false
      def dispatch_workflow(_r, _w, _ref, _i, _o), do: {:ok, %{run_id: 5}}
      def run(_r, _i, _o), do: {:ok, %{"status" => "cancelled", "conclusion" => "cancelled"}}
      def run_logs(_r, _i, _o), do: {:ok, "le runner a été interrompu avant toute mesure\n"}
    end

    test "run ANNULÉ sans le moindre fait → l'absence de verdict est EXPLICABLE" do
      # Run state distinguishes interruption from a probe that completed without facts.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :forge_actions, Cancelled)

      assert {:ok, facts} = Probe.run(judge_pod_id(), "test-relevance")

      refute Map.has_key?(facts, "verdict")
      assert facts["status"] == "cancelled"
      assert facts["conclusion"] == "cancelled"
    end
  end

  describe "l'attente est bornée, et son épuisement est DIT" do
    defmodule NeverEnds do
      @moduledoc false
      def dispatch_workflow(_r, _w, _ref, _i, _o), do: {:ok, %{run_id: 9}}
      def run(_r, _i, _o), do: {:ok, %{"status" => "running"}}
      def run_logs(_r, _i, _o), do: {:ok, "jamais atteint"}
    end

    test "un run qui ne finit pas rend {:probe_timeout, _}, pas une absence de fait" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :forge_actions, NeverEnds)

      assert {:error, {:probe_timeout, 9}} =
               Probe.run(judge_pod_id(), "test-relevance", %{}, max_wait_ms: 5, poll_ms: 1)
    end
  end
end
