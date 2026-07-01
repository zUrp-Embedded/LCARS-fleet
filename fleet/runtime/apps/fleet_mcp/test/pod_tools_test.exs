defmodule Fleet.MCP.PodToolsTest do
  @moduledoc """
  Couche tool MCP pod-facing (`Fleet.MCP.PodTools`) round-trip avec le **vrai broker**
  `Fleet.TaskQueue`.

  PUR Elixir : appelle `handle_tool_call/3` en direct (pas de transport, pas de claude).
  L'identité du pod vient du `state` (`%{pod_id: pod}`) — porté par l'accepteur de socket
  en prod (un pod = une socket, l'identité EST le canal), JAMAIS des arguments. Les tools
  privilégiés (`create_issue`/`create_project`/`get_issue_status`) résolvent le RÔLE
  depuis le pod_id via le seam `:pod_resolver` (modélise le registre du Spawner).
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TaskQueue

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  # State porté par l'accepteur de socket : l'identité = le canal, pas un champ du wire.
  defp pod_state(pod), do: %{pod_id: pod}

  test "round-trip get_work_item/submit_result d'un brief enqueué pour le pod" do
    pod = uniq("pod-rt")
    nonce = "rt-#{System.unique_integer([:positive])}"
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: nonce, role: "engineer"})

    # Canal IN : get_work_item renvoie le brief (brief = nonce) + work_item_id (correlation).
    assert {:ok, %{content: [%{"type" => "text", "text" => t1}]}, %{pod_id: ^pod}} =
             PodTools.handle_tool_call("get_work_item", %{}, pod_state(pod))

    assert {:ok, %{"done" => false, "work_item" => task}} = Jason.decode(t1)
    assert task["brief"] == nonce
    assert is_binary(task["work_item_id"])
    tid = task["work_item_id"]
    refute Map.has_key?(task, "_lcars_pod_id")

    # Canal OUT : submit_result encaisse le livrable → brief :completed (work_item_id REQUIS = celui rendu).
    assert {:ok, %{content: [%{"type" => "text"}]}, %{pod_id: ^pod}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"answer" => nonce}, "work_item_id" => tid},
               pod_state(pod)
             )

    assert {:ok, :completed} = TaskQueue.pod_status(pod)

    # Plus de brief actif → get_work_item suivant = done (le pod s'arrête).
    assert {:ok, %{content: [%{"text" => t2}]}, %{pod_id: ^pod}} =
             PodTools.handle_tool_call("get_work_item", %{}, pod_state(pod))

    assert {:ok, %{"done" => true}} = Jason.decode(t2)
  end

  test "get_work_item sans pod_id dans le state (anomalie accepteur) → erreur typée" do
    # Un pod_id absent du state = anomalie de l'accepteur (il DOIT toujours le porter), pas une fin de
    # brief. Ne JAMAIS masquer en done:true — sinon le pod s'arrête en croyant avoir fini.
    assert {:error, :pod_id_required, %{}} =
             PodTools.handle_tool_call("get_work_item", %{}, %{})
  end

  test "submit_result sans pod_id dans le state → erreur (le pod doit être identifié)" do
    assert {:error, :pod_id_required, %{}} =
             PodTools.handle_tool_call("submit_result", %{"payload" => %{"x" => 1}}, %{})
  end

  test "submit_result sans work_item_id → REFUS :work_item_id_required (plus de « dernière active » devinée)" do
    # work_item_id OBLIGATOIRE : le pod DOIT nommer la tâche qu'il clôt. Sans lui, le broker tomberait sur la
    # dernière active du pod_id. Le pod est identifié (state.pod_id) mais le corrélateur manque → refus net.
    pod = uniq("pod-notid")
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: "x"})
    assert {:ok, _, _} = PodTools.handle_tool_call("get_work_item", %{}, pod_state(pod))

    assert {:error, :work_item_id_required, %{pod_id: ^pod}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"x" => 1}},
               pod_state(pod)
             )
  end

  test "submit_result sans brief actif → erreur :no_active_task (le drop n'est pas masqué)" do
    # Un pod qui submit sans brief actif (jamais assigné, ou clos/réassigné depuis) → son livrable n'a
    # NULLE PART où aller = DROP. Doit ressortir isError, PAS {:ok "ok"} — sinon le pod croit son livrable
    # accepté. Symétrie avec :work_item_id_mismatch / :pod_id_required.
    pod = uniq("pod-no-task")

    assert {:error, :no_active_task, %{pod_id: ^pod}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"x" => 1}, "work_item_id" => "whatever"},
               pod_state(pod)
             )
  end

  test "submit_result en double (brief déjà clos) → {:ok ignoré}, PAS une erreur (idempotent)" do
    # Un re-submit après une tâche close n'est PAS un livrable perdu (le 1er submit EST encaissé) →
    # :ok "déjà reçu", idempotent. À NE PAS confondre avec :no_active_task.
    pod = uniq("pod-dbl")
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: "once"})

    assert {:ok, %{content: [%{"text" => t}]}, _} =
             PodTools.handle_tool_call("get_work_item", %{}, pod_state(pod))

    {:ok, %{"work_item" => %{"work_item_id" => tid}}} = Jason.decode(t)

    assert {:ok, %{content: [%{"type" => "text"}]}, _} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"a" => 1}, "work_item_id" => tid},
               pod_state(pod)
             )

    # 2e submit → idempotent ignoré, toujours :ok (livrable déjà encaissé, rien perdu).
    assert {:ok, %{content: [%{"type" => "text"}]}, _} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"a" => 2}, "work_item_id" => tid},
               pod_state(pod)
             )
  end

  test "tool inconnu / mauvais args → erreurs propres" do
    assert {:error, :unknown_tool, %{}} = PodTools.handle_tool_call("nope", %{}, %{})

    assert {:error, :invalid_arguments, _} =
             PodTools.handle_tool_call("submit_result", %{}, pod_state("p"))
  end

  describe "routage par pod (multi-pod pipeline)" do
    test "chaque pod ne voit QUE son propre brief (séparation structurelle par canal)" do
      pod_a = uniq("pod-A")
      pod_b = uniq("pod-B")
      {:ok, _} = TaskQueue.enqueue(pod_a, %{brief: "for-A"})
      {:ok, _} = TaskQueue.enqueue(pod_b, %{brief: "for-B"})

      assert {:ok, %{content: [%{"text" => tb}]}, _} =
               PodTools.handle_tool_call("get_work_item", %{}, pod_state(pod_b))

      assert {:ok, %{"done" => false, "work_item" => %{"brief" => "for-B"}}} = Jason.decode(tb)

      assert {:ok, %{content: [%{"text" => ta}]}, _} =
               PodTools.handle_tool_call("get_work_item", %{}, pod_state(pod_a))

      assert {:ok, %{"done" => false, "work_item" => %{"brief" => "for-A"}}} = Jason.decode(ta)
    end
  end

  # Stub forge (seam `:forge_client`) : enregistre create_issue + add_label, retourne le n°.
  defmodule StubForge do
    def create_issue(repo, title, body, opts) do
      send(self(), {:create_issue, repo, title, body, opts})
      {:ok, 77}
    end

    def add_label(repo, n, label, opts) do
      send(self(), {:add_label, repo, n, label, opts})
      {:ok, :added}
    end

    # Lecture (get_issue_status) : issue fictive ouverte, aucune PR — suffit à prouver que la GATE a
    # laissé passer (le contenu importe peu, on teste l'autorisation, pas la forge).
    def get_issue(_repo, _number, _opts), do: {:ok, %{"state" => "open"}}
    def list_open_pulls(_repo, _opts), do: {:ok, []}
  end

  # Stub d'onboarding (seam `:project_onboard`) : ne touche NI forge NI disque — rend un repo fictif. Sert
  # à prouver que la gate architecte laisse passer `create_project` sans exécuter la vraie séquence.
  defmodule StubOnboard do
    def onboard(name, _opts) do
      {:ok,
       %{
         repo: "fleet/#{name}",
         project_dir: "/tmp/projects/#{name}",
         work_dir: "/tmp/projects.work/#{name}"
       }}
    end
  end

  # Stub forge qui CAPTURE le repo interrogé par get_issue_status (preuve que le repo vient du `project`
  # passé en argument, pas d'une mémoire globale). L'état d'issue rendu est réglable par `:test_issue_state`.
  defmodule RecordingForge do
    def get_issue(repo, number, _opts) do
      send(self(), {:get_issue, repo, number})
      {:ok, %{"state" => Application.get_env(:fleet_mcp, :test_issue_state, "open")}}
    end

    def list_open_pulls(_repo, _opts), do: {:ok, []}
  end

  describe "get_issue_status (suivi arch — repo PASSÉ en `project`, plus de global mutable)" do
    setup do
      prev_forge = Application.get_env(:fleet_mcp, :forge_client)
      prev_resolver = Application.get_env(:fleet_mcp, :pod_resolver)

      Application.put_env(:fleet_mcp, :forge_client, RecordingForge)

      # Suivre un issue est un acte d'ARCHITECTE : le resolver grave le rôle architect sur le pod du canal.
      Application.put_env(:fleet_mcp, :pod_resolver, fn _pod_id -> {:ok, %{role: "architect"}} end)

      on_exit(fn ->
        restore(:forge_client, prev_forge)
        restore(:pod_resolver, prev_resolver)
        Application.delete_env(:fleet_mcp, :test_issue_state)
      end)

      :ok
    end

    test "lit l'état du repo PASSÉ dans `project` (pas d'un projet courant globalisé)" do
      pod = uniq("pod-arch")

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "get_issue_status",
                 %{"number" => 42, "project" => "fleet/specific"},
                 pod_state(pod)
               )

      # Le repo interrogé côté forge EST le `project` passé — pas un « dernier projet onboardé ». Deux projets
      # suivis en parallèle ne se contaminent plus via un global réécrit.
      assert_received {:get_issue, "fleet/specific", 42}
      assert {:ok, result} = Jason.decode(txt)
      assert result["repo"] == "fleet/specific"
      assert result["issue"] == 42
    end

    test "`delivered: true` quand l'issue est fermée (séquencement multi-issue)" do
      Application.put_env(:fleet_mcp, :test_issue_state, "closed")
      pod = uniq("pod-arch")

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "get_issue_status",
                 %{"number" => 7, "project" => "fleet/other"},
                 pod_state(pod)
               )

      assert {:ok, result} = Jason.decode(txt)
      assert result["issue_state"] == "closed"
      assert result["delivered"] == true
    end

    test "REFUSE si `project` omis — pas de routage par défaut (miroir create_issue)" do
      # Le pod est légitime (architecte) — c'est le `project` manquant qui refuse. Sans repo explicite,
      # get_issue_status lirait l'état du mauvais projet (le trou qu'on ferme).
      pod = uniq("pod-arch")

      assert {:error, {:project_required, msg}, _} =
               PodTools.handle_tool_call(
                 "get_issue_status",
                 %{"number" => 42},
                 pod_state(pod)
               )

      assert msg =~ "project"
      refute_received {:get_issue, _, _}
    end

    test "REFUSE si `project` vide" do
      pod = uniq("pod-arch")

      assert {:error, {:project_required, _}, _} =
               PodTools.handle_tool_call(
                 "get_issue_status",
                 %{"number" => 42, "project" => ""},
                 pod_state(pod)
               )

      refute_received {:get_issue, _, _}
    end
  end

  describe "create_issue (délégation arch → issue forge prêt pour le poller)" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      prev_forge = Application.get_env(:fleet_mcp, :forge_client)
      prev_resolver = Application.get_env(:fleet_mcp, :pod_resolver)
      prev_tokdir = Application.get_env(:fleet_credentials, :role_tokens_dir)
      Application.put_env(:fleet_mcp, :forge_client, StubForge)

      # Déléguer est un acte d'ARCHITECTE : le `:pod_resolver` doit rendre le rôle `architect` (sinon
      # `require_architect` refuse `:forbidden_not_architect`). Le token du compte architect doit aussi être
      # sur disque, sinon create_issue REFUSE (`:role_token_unavailable`, fail-closed).
      Application.put_env(:fleet_mcp, :pod_resolver, fn _pod_id -> {:ok, %{role: "architect"}} end)

      Application.put_env(:fleet_credentials, :role_tokens_dir, tmp)
      File.write!(Path.join(tmp, "architect.gitea_token"), "ARCH_TOKEN\n")

      on_exit(fn ->
        restore(:forge_client, prev_forge)
        restore(:pod_resolver, prev_resolver)

        if prev_tokdir,
          do: Application.put_env(:fleet_credentials, :role_tokens_dir, prev_tokdir),
          else: Application.delete_env(:fleet_credentials, :role_tokens_dir)
      end)

      :ok
    end

    test "pose l'issue (assignee humain) + label visu, SANS graver de route (découplage)" do
      pod = uniq("pod-arch")

      assert {:ok, %{content: [%{"text" => txt}]}, _} =
               PodTools.handle_tool_call(
                 "create_issue",
                 %{"title" => "T", "brief" => "fais X", "project" => "fleet/demo"},
                 pod_state(pod)
               )

      # assignee = l'humain owner (point fixe). Pas de labels DANS create_issue (Gitea veut des IDs).
      assert_received {:create_issue, "fleet/demo", "T", "fais X", opts}
      human = Fleet.Credentials.Human.current!()
      assert opts[:assignees] == [human]
      refute Keyword.has_key?(opts, :labels)

      # type:feature = étiquette de VISU (best-effort), JAMAIS du routing.
      assert_received {:add_label, "fleet/demo", 77, "type:feature", _}

      assert {:ok, result} = Jason.decode(txt)
      assert result["status"] == "issue_created"
      assert result["issue"] == "fleet/demo#77"
      assert result["assignee"] == human
    end

    test "`project` EXPLICITE → l'issue est posée DANS ce repo" do
      pod = uniq("pod-arch")

      assert {:ok, _, _} =
               PodTools.handle_tool_call(
                 "create_issue",
                 %{"title" => "T", "brief" => "fais X", "project" => "fleet/explicit"},
                 pod_state(pod)
               )

      assert_received {:create_issue, "fleet/explicit", "T", "fais X", _opts}
    end

    test "REFUSE si `project` omis — pas de routage par défaut" do
      # La bonne volonté ne s'impose pas : sans `project`, on REFUSE. Le pod est légitime (architecte) —
      # c'est le `project` manquant qui refuse, pas l'identité.
      pod = uniq("pod-arch")

      assert {:error, {:project_required, msg}, _} =
               PodTools.handle_tool_call(
                 "create_issue",
                 %{"title" => "T", "brief" => "fais X"},
                 pod_state(pod)
               )

      assert msg =~ "project"
      refute_received {:create_issue, _, _, _, _}
    end

    test "REFUSE si `project` vide" do
      pod = uniq("pod-arch")

      assert {:error, {:project_required, _}, _} =
               PodTools.handle_tool_call(
                 "create_issue",
                 %{"title" => "T", "brief" => "fais X", "project" => ""},
                 pod_state(pod)
               )

      refute_received {:create_issue, _, _, _, _}
    end
  end

  # ============================================================
  # Le rôle vient du SPAWN (résolu par pod_id du canal), jamais d'un champ du wire
  # ============================================================

  describe "rôle lié au spawn (résolu par pod_id) — seul architect délègue" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      prev_forge = Application.get_env(:fleet_mcp, :forge_client)
      prev_resolver = Application.get_env(:fleet_mcp, :pod_resolver)
      prev_tokdir = Application.get_env(:fleet_credentials, :role_tokens_dir)

      Application.put_env(:fleet_mcp, :forge_client, StubForge)

      # Token `architect` sur disque (cas légitime). Les tests qui veulent prouver un REFUS le font sur le
      # RÔLE (resolver ≠ architect ou pod inconnu), AVANT même que le token n'entre en jeu.
      Application.put_env(:fleet_credentials, :role_tokens_dir, tmp)
      File.write!(Path.join(tmp, "architect.gitea_token"), "ARCH_TOKEN\n")

      on_exit(fn ->
        restore(:forge_client, prev_forge)
        restore(:pod_resolver, prev_resolver)

        if prev_tokdir,
          do: Application.put_env(:fleet_credentials, :role_tokens_dir, prev_tokdir),
          else: Application.delete_env(:fleet_credentials, :role_tokens_dir)
      end)

      :ok
    end

    test "le spawn (résolu par pod_id) dit engineer → REFUS :forbidden_not_architect" do
      # Binding serveur `pod_id → role` : le pod p1 a été SPAWNÉ comme engineer. Le résolveur stub MODÉLISE
      # ce binding ET CAPTURE qu'on l'interroge bien par pod_id (du canal, jamais d'un champ du wire).
      # Déléguer est réservé à l'architecte → REFUS, AUCUNE issue.
      test_pid = self()

      Application.put_env(:fleet_mcp, :pod_resolver, fn pod_id ->
        send(test_pid, {:resolved_from, pod_id})

        if pod_id == "p1",
          do: {:ok, %{role: "engineer"}},
          else: {:error, :pod_unknown}
      end)

      assert {:error, :forbidden_not_architect, _} =
               PodTools.handle_tool_call(
                 "create_issue",
                 %{"title" => "T", "brief" => "fais X", "project" => "fleet/demo"},
                 %{pod_id: "p1"}
               )

      # Le résolveur a été interrogé avec le POD_ID du canal.
      assert_received {:resolved_from, "p1"}

      # Aucune issue créée par un engineer.
      refute_received {:create_issue, _, _, _, _}
    end

    test "le spawn dit architect → délégation acceptée, token ARCHITECT (rôle du spawn)" do
      Application.put_env(:fleet_mcp, :pod_resolver, fn _pod_id -> {:ok, %{role: "architect"}} end)

      assert {:ok, _, _} =
               PodTools.handle_tool_call(
                 "create_issue",
                 %{"title" => "T", "brief" => "fais X", "project" => "fleet/demo"},
                 %{pod_id: "p-arch"}
               )

      assert_received {:create_issue, "fleet/demo", "T", "fais X", opts}
      assert opts[:token] == "ARCH_TOKEN"
    end

    test "pod inconnu du Registry (resolver → :pod_unknown) → REFUS, PLUS de fallback token système" do
      # Un pod inconnu ne doit JAMAIS poster sous le compte système. Token architect PRÉSENT sur disque :
      # si le code repliait en système, il créerait l'issue. Le pod est irrésoluble → REFUS net, AUCUNE issue.
      Application.put_env(:fleet_mcp, :pod_resolver, fn _pod_id -> {:error, :pod_unknown} end)

      assert {:error, :pod_unknown, _} =
               PodTools.handle_tool_call(
                 "create_issue",
                 %{"title" => "T", "brief" => "fais X", "project" => "fleet/demo"},
                 %{pod_id: "ghost"}
               )

      refute_received {:create_issue, _, _, _, _}
    end

    test "pod prouvé architect mais token absent sur disque → REFUS :role_token_unavailable (fail-closed)" do
      # Le rôle est architect (autorisé) mais son compte n'a pas de token provisionné. On REFUSE plutôt que
      # poster en système. On efface le token architect posé par le setup pour ce cas.
      File.rm(
        Path.join(
          Application.get_env(:fleet_credentials, :role_tokens_dir),
          "architect.gitea_token"
        )
      )

      Application.put_env(:fleet_mcp, :pod_resolver, fn _pod_id -> {:ok, %{role: "architect"}} end)

      assert {:error, :role_token_unavailable, _} =
               PodTools.handle_tool_call(
                 "create_issue",
                 %{"title" => "T", "brief" => "fais X", "project" => "fleet/demo"},
                 %{pod_id: "p-arch2"}
               )

      refute_received {:create_issue, _, _, _, _}
    end
  end

  # ============================================================
  # Gate architecte serveur-side des tools privilégiés
  # ============================================================
  #
  # `create_project`, `create_issue`, `get_issue_status` exigent le rôle `architect` résolu depuis le
  # pod_id du canal. Tout rôle non architecte (engineer, reviewer, rôle nil/inconnu), un pod inconnu, ou un
  # state sans pod_id → REFUS sur les 3 tools ; architect → passe.
  describe "gate architecte (refus de tout rôle non architecte sur les tools privilégiés)" do
    @describetag :tmp_dir

    # Les 3 tools privilégiés avec un jeu d'arguments métier VALIDE (pour que seul le rôle décide du refus).
    @privileged_tools [
      {"create_project", %{"name" => "demo-proj"}},
      {"create_issue", %{"title" => "T", "brief" => "B", "project" => "fleet/demo"}},
      {"get_issue_status", %{"number" => 1, "project" => "fleet/demo"}}
    ]

    # Rôles non autorisés à déléguer/onboarder/suivre. `nil` modélise un pod sans rôle gravé (binding
    # incomplet) — doit AUSSI être refusé (fail-closed, jamais d'accès par rôle absent).
    @non_architect_roles ["engineer", "reviewer", "starfleet", "scout", nil]

    setup %{tmp_dir: tmp} do
      prev_forge = Application.get_env(:fleet_mcp, :forge_client)
      prev_onboard = Application.get_env(:fleet_mcp, :project_onboard)
      prev_resolver = Application.get_env(:fleet_mcp, :pod_resolver)
      prev_tokdir = Application.get_env(:fleet_credentials, :role_tokens_dir)

      Application.put_env(:fleet_mcp, :forge_client, StubForge)
      Application.put_env(:fleet_mcp, :project_onboard, StubOnboard)
      Application.put_env(:fleet_credentials, :role_tokens_dir, tmp)
      File.write!(Path.join(tmp, "architect.gitea_token"), "ARCH_TOKEN\n")

      on_exit(fn ->
        restore(:forge_client, prev_forge)
        restore(:project_onboard, prev_onboard)
        restore(:pod_resolver, prev_resolver)

        if prev_tokdir,
          do: Application.put_env(:fleet_credentials, :role_tokens_dir, prev_tokdir),
          else: Application.delete_env(:fleet_credentials, :role_tokens_dir)
      end)

      :ok
    end

    test "tout rôle NON architecte est REFUSÉ sur les 3 tools — sans aucun effet de bord" do
      for role <- @non_architect_roles do
        Application.put_env(:fleet_mcp, :pod_resolver, fn _pod_id -> {:ok, %{role: role}} end)

        for {tool, biz_args} <- @privileged_tools do
          pod = uniq("pod-#{role || "nil"}")

          assert {:error, :forbidden_not_architect, _} =
                   PodTools.handle_tool_call(tool, biz_args, pod_state(pod)),
                 "tool=#{tool} role=#{inspect(role)} aurait dû être REFUSÉ"
        end

        refute_received {:create_issue, _, _, _, _}
      end
    end

    test "pod inconnu (resolver → :pod_unknown) REFUSÉ sur les 3 tools (identité non résolue)" do
      Application.put_env(:fleet_mcp, :pod_resolver, fn _ -> {:error, :pod_unknown} end)

      for {tool, biz_args} <- @privileged_tools do
        pod = uniq("ghost")

        assert {:error, :pod_unknown, _} =
                 PodTools.handle_tool_call(tool, biz_args, pod_state(pod)),
               "tool=#{tool} pod inconnu aurait dû être REFUSÉ"
      end
    end

    test "state sans pod_id (anomalie accepteur) REFUSÉ sur les 3 tools → :pod_id_required" do
      # Le pod_id est porté par l'accepteur ; absent du state = anomalie → refus typé, jamais d'accès.
      for {tool, biz_args} <- @privileged_tools do
        assert {:error, :pod_id_required, _} =
                 PodTools.handle_tool_call(tool, biz_args, %{}),
               "tool=#{tool} sans pod_id aurait dû être REFUSÉ"
      end
    end

    test "architect → les 3 tools PASSENT la gate (pas de :forbidden / :pod_unknown)" do
      Application.put_env(:fleet_mcp, :pod_resolver, fn _pod_id -> {:ok, %{role: "architect"}} end)

      for {tool, biz_args} <- @privileged_tools do
        pod = uniq("pod-arch")
        result = PodTools.handle_tool_call(tool, biz_args, pod_state(pod))

        # architect → la gate laisse passer : résultat métier :ok (stubs forge/onboard).
        assert match?({:ok, _, _}, result),
               "tool=#{tool} : architect devrait passer la gate et obtenir un :ok métier (#{inspect(result)})"
      end
    end
  end

  defp restore(key, nil), do: Application.delete_env(:fleet_mcp, key)
  defp restore(key, val), do: Application.put_env(:fleet_mcp, key, val)
end
