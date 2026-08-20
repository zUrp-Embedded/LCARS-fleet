defmodule Fleet.MCP.PodTools.ProbeTest do
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools.Probe

  @moduledoc """
  Ce que le juge peut demander, et ce qu'il ne peut PAS choisir.

  `async: false` : ces tests posent les coutures d'application (`:mcp_pod_resolver`,
  `:forge_client`, `:forge_actions`), qui sont globales au nœud.
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
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :forge_client, ForgeStub)
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :forge_actions, ActionsStub)

    # Un juge de livrable : lié par `repo_id`, JAMAIS par `repo` — c'est l'état réel d'un pod
    # dispatché (le `slot_key` du spawner se clef sur l'id, cf. `Fleet.Spawner`).
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
      # ⚠ LE TEST QUI PORTE LE §10c. Un juge qui nommerait sa base nommerait celle qui l'arrange, et
      # la mesure censée le contraindre serait redevenue son opinion.
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
      # ⚠ CE MODULE NE SAIT PAS CE QUE « blind » VEUT DIRE, ET C'EST VOULU. Adoucir `blind` en
      # « pas concluant » ou durcir `inapplicable` en `blind` serait décider à la place du juge —
      # et `inapplicable` n'est SURTOUT pas un vert : c'est l'absence de mesure.
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
