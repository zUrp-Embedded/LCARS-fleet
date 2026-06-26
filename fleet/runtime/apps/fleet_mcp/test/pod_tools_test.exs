defmodule Fleet.MCP.PodToolsTest do
  @moduledoc """
  Couche tool MCP pod-facing (`Fleet.MCP.PodTools`) round-trip avec le **vrai broker**
  `Fleet.TaskQueue` (ADR-G — remplace le stub in-memory).

  PUR Elixir : appelle `handle_tool_call/3` en direct (pas de transport, pas de claude).
  Le mandat enqueué pour un pod ressort via `get_task` (canal IN, avec `task_id` =
  correlation_id) et le livrable est encaissé via `submit_result` (canal OUT).
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TaskQueue

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  # Capability par-pod simulée : chaque pod a un secret DÉRIVÉ de son id (modèle de test). Le `:pod_resolver`
  # stubbé renvoie `{:ok, %{role, capability}}` pour ce mapping → un appel qui présente `cap_for(pod)` passe
  # la gate, un appel qui présente la capability d'un AUTRE pod (ou aucune) est refusé. C'est le registre
  # serveur-side `pod_id → capability` du vrai Spawner, modélisé sans Spawner réel.
  defp cap_for(pod), do: "CAP-" <> pod

  # Args wire complets d'un pod légitime : pod_id + SA capability (ce que le pont injecte).
  defp pod_args(pod, extra \\ %{}) do
    Map.merge(%{"_lcars_pod_id" => pod, "_lcars_pod_capability" => cap_for(pod)}, extra)
  end

  # Stub du résolveur d'identité serveur-side : reconnaît tout pod via sa capability dérivée. Un pod_id
  # passé sans capability connue reste résolu (le registre EXISTE), mais la capability présentée doit
  # matcher `cap_for/1` → c'est la comparaison serveur-side qui tranche.
  setup do
    prev = Application.get_env(:fleet_mcp, :pod_resolver)

    Application.put_env(:fleet_mcp, :pod_resolver, fn pod_id ->
      {:ok, %{role: "engineer", capability: cap_for(pod_id)}}
    end)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:fleet_mcp, :pod_resolver, prev),
        else: Application.delete_env(:fleet_mcp, :pod_resolver)
    end)

    :ok
  end

  test "round-trip get_task/submit_result d'un mandat enqueué pour le pod" do
    pod = uniq("pod-rt")
    nonce = "rt-#{System.unique_integer([:positive])}"
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: nonce, role: "engineer"})

    # Canal IN : get_task renvoie le mandat (brief = nonce) + task_id (correlation).
    assert {:ok, %{content: [%{"type" => "text", "text" => t1}]}, %{}} =
             PodTools.handle_tool_call("get_task", pod_args(pod), %{})

    assert {:ok, %{"done" => false, "task" => task}} = Jason.decode(t1)
    assert task["brief"] == nonce
    assert is_binary(task["task_id"])
    tid = task["task_id"]
    refute Map.has_key?(task, "_lcars_pod_id")

    # Canal OUT : submit_result encaisse le livrable → mandat :completed (task_id REQUIS = celui rendu).
    assert {:ok, %{content: [%{"type" => "text"}]}, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               pod_args(pod, %{"payload" => %{"answer" => nonce}, "task_id" => tid}),
               %{}
             )

    assert {:ok, :completed} = TaskQueue.pod_status(pod)

    # Plus de mandat actif → get_task suivant = done (le pod s'arrête).
    assert {:ok, %{content: [%{"text" => t2}]}, %{}} =
             PodTools.handle_tool_call("get_task", pod_args(pod), %{})

    assert {:ok, %{"done" => true}} = Jason.decode(t2)
  end

  test "get_task sans _lcars_pod_id (anomalie pont) → erreur typée (F045, symétrie submit_result)" do
    # F045 : un pod_id absent = erreur de config (LCARS_POD_ID perdu), pas une fin de
    # mandat. Ne JAMAIS masquer en done:true — sinon le pod s'arrête en croyant avoir fini.
    assert {:error, :pod_id_required, %{}} =
             PodTools.handle_tool_call("get_task", %{}, %{})
  end

  test "get_task sans capability (pont sans secret) → REFUS fail-closed" do
    # La capability prouve l'identité : sans elle, le serveur ne sert RIEN (un pod_id seul est devinable).
    pod = uniq("pod-nocap")

    assert {:error, :pod_capability_required, %{}} =
             PodTools.handle_tool_call("get_task", %{"_lcars_pod_id" => pod}, %{})
  end

  test "submit_result sans _lcars_pod_id → erreur (le pod doit être identifié)" do
    assert {:error, :pod_id_required, %{}} =
             PodTools.handle_tool_call("submit_result", %{"payload" => %{"x" => 1}}, %{})
  end

  test "submit_result sans capability → REFUS fail-closed (avant même le task_id)" do
    pod = uniq("pod-nocap2")

    assert {:error, :pod_capability_required, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               %{"payload" => %{"x" => 1}, "_lcars_pod_id" => pod, "task_id" => "t"},
               %{}
             )
  end

  test "submit_result sans task_id → REFUS :task_id_required (plus de « dernière active » devinée)" do
    # task_id OBLIGATOIRE : le pod DOIT nommer la tâche qu'il clôt. Sans lui, le broker tomberait sur la
    # dernière active du pod_id — le levier d'impersonation supprimé. Le pod est prouvé (capability OK) mais
    # le corrélateur manque → refus net.
    pod = uniq("pod-notid")
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: "x"})
    assert {:ok, _, _} = PodTools.handle_tool_call("get_task", pod_args(pod), %{})

    assert {:error, :task_id_required, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               pod_args(pod, %{"payload" => %{"x" => 1}}),
               %{}
             )
  end

  test "submit_result sans mandat actif → erreur :no_active_task (F046 : le drop n'est pas masqué)" do
    # F046 : un pod qui submit sans mandat actif (jamais assigné, ou clos/réassigné depuis) → son
    # livrable n'a NULLE PART où aller = DROP. Doit ressortir isError, PAS {:ok "ok"} — sinon le pod
    # croit son livrable accepté. Symétrie avec :task_id_mismatch / :pod_id_required (classe F045).
    pod = uniq("pod-no-task")

    assert {:error, :no_active_task, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               pod_args(pod, %{"payload" => %{"x" => 1}, "task_id" => "whatever"}),
               %{}
             )
  end

  test "submit_result en double (mandat déjà clos) → {:ok ignoré}, PAS une erreur (idempotent ≠ F046)" do
    # Verrouille l'asymétrie voulue : un re-submit après une tâche close n'est PAS un livrable perdu
    # (le 1er submit EST encaissé) → :ok "déjà reçu", idempotent. À NE PAS confondre avec :no_active_task.
    pod = uniq("pod-dbl")
    {:ok, _} = TaskQueue.enqueue(pod, %{brief: "once"})

    assert {:ok, %{content: [%{"text" => t}]}, _} =
             PodTools.handle_tool_call("get_task", pod_args(pod), %{})

    {:ok, %{"task" => %{"task_id" => tid}}} = Jason.decode(t)

    assert {:ok, %{content: [%{"type" => "text"}]}, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               pod_args(pod, %{"payload" => %{"a" => 1}, "task_id" => tid}),
               %{}
             )

    # 2e submit → idempotent ignoré, toujours :ok (livrable déjà encaissé, rien perdu).
    assert {:ok, %{content: [%{"type" => "text"}]}, %{}} =
             PodTools.handle_tool_call(
               "submit_result",
               pod_args(pod, %{"payload" => %{"a" => 2}, "task_id" => tid}),
               %{}
             )
  end

  test "tool inconnu / mauvais args → erreurs propres" do
    assert {:error, :unknown_tool, %{}} = PodTools.handle_tool_call("nope", %{}, %{})

    assert {:error, :invalid_arguments, %{}} =
             PodTools.handle_tool_call("submit_result", %{}, %{})
  end

  describe "routage par pod (multi-pod pipeline)" do
    test "chaque pod ne voit QUE son propre mandat" do
      pod_a = uniq("pod-A")
      pod_b = uniq("pod-B")
      {:ok, _} = TaskQueue.enqueue(pod_a, %{brief: "for-A"})
      {:ok, _} = TaskQueue.enqueue(pod_b, %{brief: "for-B"})

      assert {:ok, %{content: [%{"text" => tb}]}, %{}} =
               PodTools.handle_tool_call("get_task", pod_args(pod_b), %{})

      assert {:ok, %{"done" => false, "task" => %{"brief" => "for-B"}}} = Jason.decode(tb)

      assert {:ok, %{content: [%{"text" => ta}]}, %{}} =
               PodTools.handle_tool_call("get_task", pod_args(pod_a), %{})

      assert {:ok, %{"done" => false, "task" => %{"brief" => "for-A"}}} = Jason.decode(ta)
    end
  end

  describe "SEC-MCP-003 — impersonation par pod_id deviné (capability ferme le trou)" do
    test "pod B présente le pod_id de A SANS la capability de A → get_task REFUSÉ" do
      # POC d'impersonation : A a un mandat. B (qui devine le pod_id déterministe de A) POST le pod_id de A
      # pour LIRE son mandat. Mais B ne connaît PAS la capability de A (elle ne vit que dans l'env de A).
      # Avec la capability de B (la sienne), la comparaison serveur-side échoue → REFUS, le mandat de A reste
      # invisible à B.
      pod_a = uniq("victim-A")
      pod_b = uniq("attacker-B")
      {:ok, _} = TaskQueue.enqueue(pod_a, %{brief: "secret-de-A"})

      # B forge le pod_id de A mais ne peut présenter que SA propre capability.
      forged = %{"_lcars_pod_id" => pod_a, "_lcars_pod_capability" => cap_for(pod_b)}

      assert {:error, :pod_capability_mismatch, %{}} =
               PodTools.handle_tool_call("get_task", forged, %{})

      # Le mandat de A est intact : A peut toujours le lire avec SA capability.
      assert {:ok, %{content: [%{"text" => t}]}, %{}} =
               PodTools.handle_tool_call("get_task", pod_args(pod_a), %{})

      assert {:ok, %{"done" => false, "task" => %{"brief" => "secret-de-A"}}} = Jason.decode(t)
    end

    test "pod B présente le pod_id de A SANS la capability de A → submit_result REFUSÉ" do
      # A a un mandat actif. B veut le CLÔTURER à sa place (POST pod_id de A). Sans la capability de A,
      # la gate refuse AVANT toute mutation → le mandat de A reste actif, jamais clos par un tiers.
      pod_a = uniq("victim-sub-A")
      pod_b = uniq("attacker-sub-B")
      {:ok, task} = TaskQueue.enqueue(pod_a, %{brief: "à-livrer-par-A"})
      # A pull pour passer le mandat en :assigned (actif).
      assert {:ok, _, _} = PodTools.handle_tool_call("get_task", pod_args(pod_a), %{})

      forged = %{
        "_lcars_pod_id" => pod_a,
        "_lcars_pod_capability" => cap_for(pod_b),
        "payload" => %{"stolen" => true},
        "task_id" => task.id
      }

      assert {:error, :pod_capability_mismatch, %{}} =
               PodTools.handle_tool_call("submit_result", forged, %{})

      # Le mandat de A n'a PAS été clos par B.
      assert {:ok, :assigned} = TaskQueue.pod_status(pod_a)
    end
  end

  # Stub forge (seam `:forge_client`) : enregistre create_issue + post_route + add_label, retourne le n°.
  defmodule StubForge do
    def create_issue(repo, title, body, opts) do
      send(self(), {:create_issue, repo, title, body, opts})
      {:ok, 77}
    end

    def post_route(repo, n, carte, stage, opts) do
      send(self(), {:post_route, repo, n, carte, stage, opts})
      {:ok, :posted}
    end

    def add_label(repo, n, label, opts) do
      send(self(), {:add_label, repo, n, label, opts})
      {:ok, :added}
    end

    # Stub `last_worked_repo` (réglable par test via `:test_last_worked`, défaut `:none`). create_ticket
    # exige désormais `project` explicite et ne consulte plus ce « dernier travaillé » : le stub sert au
    # test « explicite prime » (il rend un repo concurrent que le `project` passé doit ignorer).
    def last_worked_repo(_human, _opts) do
      Application.get_env(:fleet_mcp, :test_last_worked, :none)
    end

    # Lecture (get_ticket_status) : issue fictive ouverte, aucune PR — suffit à prouver que la GATE a
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

  # Stub forge qui CAPTURE le repo interrogé par get_ticket_status (preuve que le repo vient du `project`
  # passé en argument, pas d'une mémoire globale). L'état d'issue rendu est réglable par `:test_issue_state`.
  defmodule RecordingForge do
    def get_issue(repo, number, _opts) do
      send(self(), {:get_issue, repo, number})
      {:ok, %{"state" => Application.get_env(:fleet_mcp, :test_issue_state, "open")}}
    end

    def list_open_pulls(_repo, _opts), do: {:ok, []}
  end

  describe "get_ticket_status (suivi arch — repo PASSÉ en `project`, plus de global mutable)" do
    setup do
      prev_forge = Application.get_env(:fleet_mcp, :forge_client)
      prev_resolver = Application.get_env(:fleet_mcp, :pod_resolver)

      Application.put_env(:fleet_mcp, :forge_client, RecordingForge)

      # Suivre un ticket est un acte d'ARCHITECTE : le resolver grave le rôle architect sur le pod prouvé.
      Application.put_env(:fleet_mcp, :pod_resolver, fn pod_id ->
        {:ok, %{role: "architect", capability: cap_for(pod_id)}}
      end)

      on_exit(fn ->
        restore(:forge_client, prev_forge)
        restore(:pod_resolver, prev_resolver)
        Application.delete_env(:fleet_mcp, :test_issue_state)
      end)

      :ok
    end

    test "lit l'état du repo PASSÉ dans `project` (pas d'un projet courant globalisé)" do
      pod = uniq("pod-arch")

      assert {:ok, %{content: [%{"text" => txt}]}, %{}} =
               PodTools.handle_tool_call(
                 "get_ticket_status",
                 pod_args(pod, %{"number" => 42, "project" => "fleet/specific"}),
                 %{}
               )

      # Le repo interrogé côté forge EST le `project` passé — pas un « dernier projet onboardé ». C'est le
      # cœur du fix : deux projets suivis en parallèle ne se contaminent plus via un global réécrit.
      assert_received {:get_issue, "fleet/specific", 42}
      assert {:ok, result} = Jason.decode(txt)
      assert result["repo"] == "fleet/specific"
      assert result["issue"] == 42
    end

    test "`delivered: true` quand l'issue est fermée (séquencement multi-ticket)" do
      Application.put_env(:fleet_mcp, :test_issue_state, "closed")
      pod = uniq("pod-arch")

      assert {:ok, %{content: [%{"text" => txt}]}, %{}} =
               PodTools.handle_tool_call(
                 "get_ticket_status",
                 pod_args(pod, %{"number" => 7, "project" => "fleet/other"}),
                 %{}
               )

      assert {:ok, result} = Jason.decode(txt)
      assert result["issue_state"] == "closed"
      assert result["delivered"] == true
    end

    test "REFUSE si `project` omis — pas de routage par défaut (miroir create_ticket)" do
      # Le pod est légitime (capability OK) ET architecte — c'est le `project` manquant qui refuse. Sans
      # repo explicite, get_ticket_status lirait l'état du mauvais projet (le trou qu'on ferme).
      pod = uniq("pod-arch")

      assert {:error, {:project_required, msg}, %{}} =
               PodTools.handle_tool_call(
                 "get_ticket_status",
                 pod_args(pod, %{"number" => 42}),
                 %{}
               )

      assert msg =~ "project"
      # Refus STRUCTUREL avant toute mécanique : aucune lecture forge tentée.
      refute_received {:get_issue, _, _}
    end

    test "REFUSE si `project` vide" do
      pod = uniq("pod-arch")

      assert {:error, {:project_required, _}, %{}} =
               PodTools.handle_tool_call(
                 "get_ticket_status",
                 pod_args(pod, %{"number" => 42, "project" => ""}),
                 %{}
               )

      refute_received {:get_issue, _, _}
    end
  end

  describe "create_ticket (délégation arch → ticket forge prêt pour le poller)" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      prev_forge = Application.get_env(:fleet_mcp, :forge_client)
      prev_resolver = Application.get_env(:fleet_mcp, :pod_resolver)
      prev_tokdir = Application.get_env(:fleet_credentials, :role_tokens_dir)
      Application.put_env(:fleet_mcp, :forge_client, StubForge)

      # Déléguer est un acte d'ARCHITECTE : le `:pod_resolver` doit rendre le rôle `architect` (sinon
      # `require_architect` refuse `:forbidden_not_architect`). Le token du compte architect doit aussi être
      # sur disque, sinon create_ticket REFUSE (`:role_token_unavailable`, fail-closed).
      Application.put_env(:fleet_mcp, :pod_resolver, fn pod_id ->
        {:ok, %{role: "architect", capability: cap_for(pod_id)}}
      end)

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

    test "#5.2 D2 — pose l'issue (assignee humain) + label visu, SANS graver de route (découplage)" do
      pod = uniq("pod-arch")

      assert {:ok, %{content: [%{"text" => txt}]}, %{}} =
               PodTools.handle_tool_call(
                 "create_ticket",
                 pod_args(pod, %{"title" => "T", "brief" => "fais X", "project" => "fleet/demo"}),
                 %{}
               )

      # assignee = l'humain owner (point fixe). Pas de labels DANS create_issue (Gitea veut des IDs).
      assert_received {:create_issue, "fleet/demo", "T", "fais X", opts}
      human = Fleet.Credentials.Human.current!()
      assert opts[:assignees] == [human]
      refute Keyword.has_key?(opts, :labels)

      # #5.2 D2 — DÉCOUPLAGE : create_ticket ne grave PLUS la route. Le SYSTÈME (poller) onboarde l'issue
      # routeless sur la carte par défaut. Donc AUCUN post_route ici.
      refute_received {:post_route, _, _, _, _, _}

      # type:feature = étiquette de VISU (best-effort), JAMAIS du routing.
      assert_received {:add_label, "fleet/demo", 77, "type:feature", _}

      assert {:ok, result} = Jason.decode(txt)
      assert result["status"] == "ticket_created"
      assert result["ticket"] == "fleet/demo#77"
      assert result["assignee"] == human
    end

    test "F-037 — `project` EXPLICITE → l'issue est posée DANS ce repo (ignore last_worked + delegation)" do
      # last_worked rendrait autre chose ; l'explicite prime.
      Application.put_env(:fleet_mcp, :test_last_worked, {:ok, "fleet/worked"})
      on_exit(fn -> Application.delete_env(:fleet_mcp, :test_last_worked) end)
      pod = uniq("pod-arch")

      assert {:ok, _, %{}} =
               PodTools.handle_tool_call(
                 "create_ticket",
                 pod_args(pod, %{
                   "title" => "T",
                   "brief" => "fais X",
                   "project" => "fleet/explicit"
                 }),
                 %{}
               )

      assert_received {:create_issue, "fleet/explicit", "T", "fais X", _opts}
    end

    test "REFUSE si `project` omis — pas de routage par défaut (F-TICKET-ROUTE-FOOTGUN)" do
      # La bonne volonté ne s'impose pas : sans `project`, on REFUSE (plus de fallback last_worked/delegation
      # qui misroutait silencieusement un ticket fraîchement délégué vers le mauvais projet). Le pod est
      # légitime (capability OK) — c'est le `project` manquant qui refuse, pas l'identité.
      pod = uniq("pod-arch")

      assert {:error, {:project_required, msg}, %{}} =
               PodTools.handle_tool_call(
                 "create_ticket",
                 pod_args(pod, %{"title" => "T", "brief" => "fais X"}),
                 %{}
               )

      assert msg =~ "project"
      refute_received {:create_issue, _, _, _, _}
    end

    test "REFUSE si `project` vide" do
      pod = uniq("pod-arch")

      assert {:error, {:project_required, _}, %{}} =
               PodTools.handle_tool_call(
                 "create_ticket",
                 pod_args(pod, %{"title" => "T", "brief" => "fais X", "project" => ""}),
                 %{}
               )

      refute_received {:create_issue, _, _, _, _}
    end
  end

  # ============================================================
  # MA-15 / SEC-MCP-003 — le rôle vient du SPAWN VÉRIFIÉ (capability), jamais du `_lcars_role` du wire
  # ============================================================

  describe "MA-15 — rôle lié au spawn prouvé (le `_lcars_role` du wire est ignoré, et seul architect délègue)" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      prev_forge = Application.get_env(:fleet_mcp, :forge_client)
      prev_resolver = Application.get_env(:fleet_mcp, :pod_resolver)
      prev_tokdir = Application.get_env(:fleet_credentials, :role_tokens_dir)

      Application.put_env(:fleet_mcp, :forge_client, StubForge)

      # Token `architect` sur disque (le cas légitime). Les tests qui veulent prouver un REFUS le font sur le
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

    test "wire prétend architect, le spawn (vérifié) dit engineer → REFUS :forbidden_not_architect" do
      # Binding serveur `pod_id → {role, capability}` : le pod p1 a été SPAWNÉ comme engineer (Registry du
      # Spawner). Le résolveur stub MODÉLISE ce binding ET CAPTURE qu'on l'interroge bien par pod_id (jamais
      # par le `_lcars_role`). Le pod MENT « architect » sur le fil non authentifié — sans effet : le rôle
      # autoritaire vient du spawn (engineer), et déléguer est réservé à l'architecte → REFUS, AUCUNE issue.
      test_pid = self()

      Application.put_env(:fleet_mcp, :pod_resolver, fn pod_id ->
        send(test_pid, {:resolved_from, pod_id})

        if pod_id == "p1",
          do: {:ok, %{role: "engineer", capability: "CAP-p1"}},
          else: {:error, :pod_unknown}
      end)

      assert {:error, :forbidden_not_architect, %{}} =
               PodTools.handle_tool_call(
                 "create_ticket",
                 %{
                   "title" => "T",
                   "brief" => "fais X",
                   "project" => "fleet/demo",
                   "_lcars_pod_id" => "p1",
                   "_lcars_pod_capability" => "CAP-p1",
                   # Le pod MENT : il prétend être architect sur le fil non authentifié → ignoré.
                   "_lcars_role" => "architect"
                 },
                 %{}
               )

      # Le résolveur a été interrogé avec le POD_ID (le spawn), PAS le `_lcars_role` du wire.
      assert_received {:resolved_from, "p1"}

      # Le mensonge du wire n'a RIEN ouvert : aucune issue créée par un engineer déguisé en architecte.
      refute_received {:create_issue, _, _, _, _}
    end

    test "spawn vérifié dit architect → délégation acceptée, token ARCHITECT (rôle du spawn)" do
      # Le pendant positif : quand le rôle gravé au spawn EST architect, la délégation passe et l'issue est
      # postée sous le token du compte architect (résolu depuis le rôle du spawn, jamais le wire).
      Application.put_env(:fleet_mcp, :pod_resolver, fn _pod_id ->
        {:ok, %{role: "architect", capability: "CAP-a"}}
      end)

      assert {:ok, _, %{}} =
               PodTools.handle_tool_call(
                 "create_ticket",
                 %{
                   "title" => "T",
                   "brief" => "fais X",
                   "project" => "fleet/demo",
                   "_lcars_pod_id" => "p-arch",
                   "_lcars_pod_capability" => "CAP-a"
                 },
                 %{}
               )

      assert_received {:create_issue, "fleet/demo", "T", "fais X", opts}
      assert opts[:token] == "ARCH_TOKEN"
    end

    test "pod inconnu du Registry (resolver → :pod_unknown) → REFUS, PLUS de fallback token système" do
      # Le trou supprimé : un pod inconnu ne doit JAMAIS poster sous le compte système. Token architect
      # PRÉSENT sur disque : si le code lisait le wire OU repliait en système, il créerait l'issue. Le pod
      # est irrésoluble (absent) → REFUS net (`:pod_unknown` propagé par require_architect), AUCUNE issue.
      Application.put_env(:fleet_mcp, :pod_resolver, fn _pod_id -> {:error, :pod_unknown} end)

      assert {:error, :pod_unknown, %{}} =
               PodTools.handle_tool_call(
                 "create_ticket",
                 %{
                   "title" => "T",
                   "brief" => "fais X",
                   "project" => "fleet/demo",
                   "_lcars_pod_id" => "ghost",
                   "_lcars_pod_capability" => "whatever",
                   "_lcars_role" => "architect"
                 },
                 %{}
               )

      # Aucune issue créée : le pod non prouvé ne délègue rien (ni sous architect, ni sous système).
      refute_received {:create_issue, _, _, _, _}
    end

    test "pod prouvé architect mais token absent sur disque → REFUS :role_token_unavailable (fail-closed)" do
      # Le rôle est architect (autorisé) mais son compte n'a pas de token provisionné. On REFUSE plutôt que
      # poster en système (le repli supprimé). On efface le token architect posé par le setup pour ce cas.
      File.rm(
        Path.join(
          Application.get_env(:fleet_credentials, :role_tokens_dir),
          "architect.gitea_token"
        )
      )

      Application.put_env(:fleet_mcp, :pod_resolver, fn _pod_id ->
        {:ok, %{role: "architect", capability: "CAP-x"}}
      end)

      assert {:error, :role_token_unavailable, %{}} =
               PodTools.handle_tool_call(
                 "create_ticket",
                 %{
                   "title" => "T",
                   "brief" => "fais X",
                   "project" => "fleet/demo",
                   "_lcars_pod_id" => "p-arch2",
                   "_lcars_pod_capability" => "CAP-x"
                 },
                 %{}
               )

      refute_received {:create_issue, _, _, _, _}
    end
  end

  # ============================================================
  # B2a — autorisation architecte serveur-side des tools privilégiés
  # ============================================================
  #
  # `create_project`, `create_ticket`, `get_ticket_status` exigent le rôle `architect` PROUVÉ (verify_pod +
  # rôle du spawn). Avant, la seule barrière était la visibilité côté pont (filtre client) ; un pod worker
  # qui reconstruit le JSON-RPC contournait. Ces tests verrouillent la gate serveur-side : tout rôle non
  # architecte (engineer, reviewer, rôle nil/inconnu) → REFUS sur les 3 tools ; architect → passe.
  describe "B2a — gate architecte (refus de tout rôle non architecte sur les tools privilégiés)" do
    @describetag :tmp_dir

    # Les 3 tools privilégiés avec un jeu d'arguments métier VALIDE (pour que seul le rôle décide du refus,
    # pas un mauvais argument). Chacun renvoie {tool, args_métier}.
    @privileged_tools [
      {"create_project", %{"name" => "demo-proj"}},
      {"create_ticket", %{"title" => "T", "brief" => "B", "project" => "fleet/demo"}},
      {"get_ticket_status", %{"number" => 1, "project" => "fleet/demo"}}
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

    test "tout rôle NON architecte (prouvé) est REFUSÉ sur les 3 tools — sans aucun effet de bord" do
      for role <- @non_architect_roles do
        # Le pod est PROUVÉ (capability OK) — c'est le RÔLE qui refuse, pas l'identité. Le resolver grave
        # `role` (y compris nil) sur le pod prouvé.
        Application.put_env(:fleet_mcp, :pod_resolver, fn pod_id ->
          {:ok, %{role: role, capability: cap_for(pod_id)}}
        end)

        for {tool, biz_args} <- @privileged_tools do
          pod = uniq("pod-#{role || "nil"}")

          assert {:error, :forbidden_not_architect, %{}} =
                   PodTools.handle_tool_call(tool, pod_args(pod, biz_args), %{}),
                 "tool=#{tool} role=#{inspect(role)} aurait dû être REFUSÉ"
        end

        # Aucun effet de bord : ni issue créée, ni onboarding (StubForge/StubOnboard send au mailbox).
        refute_received {:create_issue, _, _, _, _}
      end
    end

    test "pod inconnu (resolver → :pod_unknown) REFUSÉ sur les 3 tools (identité non prouvée)" do
      Application.put_env(:fleet_mcp, :pod_resolver, fn _ -> {:error, :pod_unknown} end)

      for {tool, biz_args} <- @privileged_tools do
        pod = uniq("ghost")

        assert {:error, :pod_unknown, %{}} =
                 PodTools.handle_tool_call(tool, pod_args(pod, biz_args), %{}),
               "tool=#{tool} pod inconnu aurait dû être REFUSÉ"
      end
    end

    test "architect prouvé → les 3 tools PASSENT la gate (pas de :forbidden / :pod_unknown)" do
      Application.put_env(:fleet_mcp, :pod_resolver, fn pod_id ->
        {:ok, %{role: "architect", capability: cap_for(pod_id)}}
      end)

      for {tool, biz_args} <- @privileged_tools do
        pod = uniq("pod-arch")
        result = PodTools.handle_tool_call(tool, pod_args(pod, biz_args), %{})

        # architect prouvé → la gate laisse passer : résultat métier :ok (stubs forge/onboard). Un refus
        # de rôle/identité ne matcherait pas {:ok, _, _}, donc cet assert le couvre — pas de `refute`
        # redondant (le type-narrowing le prouverait toujours-vrai = assertion morte).
        assert match?({:ok, _, _}, result),
               "tool=#{tool} : architect devrait passer la gate et obtenir un :ok métier (#{inspect(result)})"
      end
    end
  end

  defp restore(key, nil), do: Application.delete_env(:fleet_mcp, key)
  defp restore(key, val), do: Application.put_env(:fleet_mcp, key, val)
end
