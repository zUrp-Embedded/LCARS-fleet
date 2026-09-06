defmodule Fleet.MCP.ToolchainRequestTest do
  @moduledoc """
  L'IDENTITÉ EST LE CANAL, et c'est tout ce que ces cas défendent.

  Un pod bloqué demande un outil que le conteneur n'a pas. Ce que la demande devient — un diff qu'un
  humain signe, puis ce que root applique — rend la question « au nom de qui ? » plus lourde ici que
  partout ailleurs dans la surface MCP. Rien dans les arguments ne nomme un ticket : le work-item
  se DÉDUIT du `pod_id` que l'accepteur de socket a lié. Ces témoins épinglent qu'on ne peut pas
  contourner ça, et qu'on ne casse rien en le lisant.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools.Delegation.Toolchain
  alias Fleet.TaskQueue

  # UNE seule doublure, scriptée par le dictionnaire de processus : la délégation tourne dans le
  # processus appelant, donc un `Process.put` du test l'atteint. Elle ENREGISTRE ses appels, parce
  # que ce qui compte ici n'est pas seulement le retour mais la SÉQUENCE des écritures.
  defmodule Writer do
    @behaviour Fleet.MCP.PodTools.Delegation.ForgeWriter

    @impl true
    def create_branch(repo, branch, base, _opts) do
      send(self(), {:create_branch, repo, branch, base})
      Process.get(:create_branch_result, {:ok, %{}})
    end

    @impl true
    def put_file(repo, path, content, opts) do
      send(self(), {:put_file, repo, path, content, opts[:branch]})
      {:ok, %{}}
    end

    @impl true
    def schedule_auto_merge(repo, index, _opts) do
      send(self(), {:auto_merge_armed, repo, index})
      :ok
    end

    @impl true
    def add_label(repo, issue, label, _opts) do
      send(self(), {:add_label, repo, issue, label})
      Process.get(:add_label_result, {:ok, %{}})
    end

    @impl true
    def post_comment(repo, issue, body, _opts) do
      send(self(), {:post_comment, repo, issue, body})
      Process.get(:post_comment_result, {:ok, %{}})
    end

    @impl true
    def open_pr(repo, head, base, title, opts) do
      send(self(), {:open_pr, repo, head, base, title, Keyword.get(opts, :body, "")})

      # Le NUMERO NU — le contrat du client canonique ({:ok, integer}, 409 compris). Une v1 de ce
      # double rendait une map : vert ici, `"pr" => nil` en prod. Le double suit le client, jamais
      # l'inverse.
      {:ok, 412}
    end
  end

  setup do
    prev = Application.get_env(:lcars_fleet, :mcp_forge_client)
    Application.put_env(:lcars_fleet, :mcp_forge_client, Writer)

    # L'ADRESSE du work-item vient de l'IDENTITÉ du pod (le canal) : le résolveur est la couture.
    prev_resolver = Application.get_env(:lcars_fleet, :mcp_pod_resolver)

    Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
      {:ok, %{role: "engineer", repo: "fleet/morse"}}
    end)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:lcars_fleet, :mcp_forge_client, prev),
        else: Application.delete_env(:lcars_fleet, :mcp_forge_client)

      if prev_resolver,
        do: Application.put_env(:lcars_fleet, :mcp_pod_resolver, prev_resolver),
        else: Application.delete_env(:lcars_fleet, :mcp_pod_resolver)
    end)

    :ok
  end

  defp req(extra \\ %{}) do
    Map.merge(
      %{
        "ecosystem" => "python",
        "evidence" => "ModuleNotFoundError: No module named 'yaml'",
        "apt" => %{"packages" => ["python3-yaml"]}
      },
      extra
    )
  end

  defp enqueue!(pod_id) do
    {:ok, item} =
      TaskQueue.enqueue(pod_id, %{
        # Le format REEL (Pilot.IssueId.compose) — un "412" nu serait refuse par le miroir.
        issue_id: "issue-412",
        role: "engineer",
        brief: "compile le module morse"
      })

    item
  end

  describe "l'identité vient du canal, jamais des arguments" do
    test "sans `pod_id`, la demande est refusée — et typée" do
      # Un manifeste dont on ne connaît pas l'origine est un manifeste qu'aucun humain ne peut
      # juger et qu'aucun merge ne se laisse retracer.
      assert {:error, :pod_id_required} = Toolchain.request_toolchain(req(), nil)
      assert {:error, :pod_id_required} = Toolchain.request_toolchain(req(), "")
    end

    test "un pod sans work-item ET sans identité résolvable est refusé — typé" do
      # L'ABSENCE DE TICKET N'EST PLUS UN REFUS, l'absence d'IDENTITÉ l'est toujours : le manifeste
      # porte le rôle du demandeur, et un rôle inconnu rend la demande injugeable.
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ -> {:error, :pod_unknown} end)

      assert {:error, :pod_unknown} =
               Toolchain.request_toolchain(req(), "pod-sans-item-#{System.unique_integer()}")
    end
  end

  describe "l'anticipation — une demande qu'aucun ticket ne porte" do
    # ⚠ CE QUE CES TÉMOINS ACHÈTENT. Le cap-profile de l'architecte lui accorde `toolchain_request`
    # avec une raison écrite : « demander un outillage AVANT que les producers butent dessus ».
    # L'implémentation ouvrait sur `active_work_item/1` et refusait en `:no_active_work_item` —
    # l'arch n'a pas de work-item, il répond à l'humain. La capacité était donc MORTE pour son seul
    # usage déclaré, mesuré en vol le 2026-08-20 sur `architect-hello-world` (node absent).

    setup do
      Application.put_env(:lcars_fleet, :mcp_pod_resolver, fn _ ->
        {:ok, %{role: "architect", repo: "fleet/hello-world"}}
      end)

      :ok
    end

    test "un pod sans work-item ouvre quand même la PR" do
      pod = "architect-hello-#{System.unique_integer([:positive])}"

      assert {:ok, %{"status" => "toolchain_requested", "ecosystem" => "python", "pr" => 412}} =
               Toolchain.request_toolchain(req(), pod)

      assert_received {:open_pr, _repo, _head, _base, "[toolchain] python (anticipation)", _body}
    end

    test "la branche est celle du POD, dans un espace de noms qui ne croise pas les work-items" do
      pod = "architect-hello-#{System.unique_integer([:positive])}"
      {:ok, _} = Toolchain.request_toolchain(req(), pod)

      expected = Fleet.Toolchain.branch_for_pod(pod)
      assert_received {:create_branch, _repo, ^expected, _base}
      assert String.starts_with?(expected, "lcars/toolchain-pod-")

      # Le préfixe SÉPARE : deux clés d'espaces de noms indépendants ne peuvent pas atterrir sur
      # une même branche et s'écraser l'une l'autre.
      refute expected == Fleet.Toolchain.branch_for(pod)
    end

    test "AUCUN verrou, AUCUN commentaire — il n'y a pas de ticket à mettre en attente" do
      pod = "architect-hello-#{System.unique_integer([:positive])}"
      {:ok, _} = Toolchain.request_toolchain(req(), pod)

      refute_received {:add_label, _, _, _}
      refute_received {:post_comment, _, _, _}
    end

    test "le corps de PR ne porte PAS de marqueur de work-item, et le dit" do
      pod = "architect-hello-#{System.unique_integer([:positive])}"
      {:ok, _} = Toolchain.request_toolchain(req(), pod)

      assert_received {:open_pr, _repo, _head, _base, _title, body}

      # LE DRAIN LE SAIT DÉJÀ : une PR sans marqueur n'est pas la sienne, il la saute. C'est ce qui
      # rend le chemin sans ticket sûr en aval — pas une tolérance ajoutée pour l'occasion.
      assert :error = Fleet.Toolchain.parse_workitem_marker(body)

      # Et un admin qui merge doit savoir qu'il n'attend personne : une PR d'anticipation qui
      # ressemblerait à une PR de déblocage ferait espérer un re-dispatch qui n'arrivera jamais.
      assert body =~ "ANTICIPÉE"
      assert body =~ "AUCUN ticket en attente"
    end

    test "le manifeste porte le rôle du demandeur, sans issue ni work-item" do
      pod = "architect-hello-#{System.unique_integer([:positive])}"
      {:ok, _} = Toolchain.request_toolchain(req(), pod)

      assert_received {:put_file, _repo, "ops/toolchains.d/python.yaml", content, _branch}
      assert content =~ "role: architect"
      refute content =~ "work_item:"
      refute content =~ "issue:"
    end
  end

  describe "la lecture du work-item ne MUTE rien" do
    test "l'item reste `pending` — pas d'assignation fantôme" do
      pod = "pod-lecture-#{System.unique_integer([:positive])}"
      item = enqueue!(pod)
      assert item.state == :pending

      {:ok, _} = Toolchain.request_toolchain(req(), pod)

      # LE PIÈGE ÉVITÉ : `TaskQueue.get_for_pod/1` enregistre un poll ET fait passer l'item en
      # `:assigned` avec un broadcast. L'appeler ici émettrait une assignation que personne n'a
      # demandée et remettrait à zéro l'horloge de poll d'un pod qui, lui, n'a rien polé.
      still = Enum.find(TaskQueue.list_active(), &(&1.id == item.id))
      assert still.state == :pending
      assert is_nil(still.assigned_at)
    end
  end

  describe "la forme, et ce qui part sur la forge" do
    test "deux formes déclarées : refus, aucune écriture" do
      pod = "pod-2formes-#{System.unique_integer([:positive])}"
      enqueue!(pod)

      bad = req(%{"sysroot" => %{"arch" => "arm64", "sources" => [], "packages" => []}})

      assert {:error, {:toolchain_form, _}} = Toolchain.request_toolchain(bad, pod)
      refute_received {:create_branch, _, _, _}
      refute_received {:put_file, _, _, _, _}
    end

    test "la séquence est branche -> fichier -> PR, et le fichier va sur la BRANCHE" do
      pod = "pod-sequence-#{System.unique_integer([:positive])}"
      item = enqueue!(pod)

      assert {:ok, %{"status" => "toolchain_requested", "pr" => 412}} =
               Toolchain.request_toolchain(req(), pod)

      branch = Fleet.Toolchain.branch_for(item.id)
      base = Fleet.Toolchain.branch()

      # `assert_received` lit la boîte dans l'ordre d'arrivée : la séquence EST le contrat. Un
      # fichier écrit avant sa branche, ou sur `base` au lieu de la branche de demande, ferait
      # atterrir une déclaration non validée là où le convergeur la trouverait.
      assert_received {:create_branch, _repo, ^branch, ^base}
      assert_received {:put_file, _repo, "ops/toolchains.d/python.yaml", content, ^branch}
      assert_received {:open_pr, _repo, ^branch, ^base, "[toolchain] python", pr_body}

      # Le lien INVERSE : le corps de la PR nomme le work-item — c'est ce que la seconde passe du
      # réconciliateur lit pour drainer quand la PR se ferme sans faire bouger la branche.
      assert {:ok, "fleet/morse", 412} = Fleet.Toolchain.parse_workitem_marker(pr_body)

      assert content =~ "kind: ecosystem_enable"
      assert content =~ "ecosystem: python"
      # La traçabilité voyage AVEC le document : le merge doit pouvoir être retracé au ticket.
      # (Non cité : `issue-412` commence par une lettre — la citation de yaml_scalar ne vaut que
      # pour les scalaires à tête de chiffre.)
      assert content =~ ~s(issue: issue-412)
      assert content =~ "work_item: "
    end

    test "une branche déjà là n'est pas une erreur — c'est le second appel du même besoin" do
      pod = "pod-retry-#{System.unique_integer([:positive])}"
      enqueue!(pod)
      Process.put(:create_branch_result, {:error, {:http, 409, "already exists"}})

      # IDEMPOTENCE PAR LA BRANCHE : son nom dérive du work-item, donc un retry réécrit le même
      # fichier au lieu d'ouvrir une DEUXIÈME pull request pour un seul besoin.
      assert {:ok, %{"pr" => 412}} = Toolchain.request_toolchain(req(), pod)
      assert_received {:put_file, _, _, _, _}
    end

    test "le manifeste est keyé sur l'écosystème, pas sur la demande" do
      pod = "pod-eco-#{System.unique_integer([:positive])}"
      enqueue!(pod)

      {:ok, _} = Toolchain.request_toolchain(req(%{"ecosystem" => "rust"}), pod)
      assert_received {:put_file, _, "ops/toolchains.d/rust.yaml", _, _}
    end
  end

  describe "le verrou du work-item — le lien est écrit sur la forge, dans les deux sens" do
    test "la création pose `lcars-awaits-toolchain` + le commentaire à marqueur sur le ticket" do
      pod = "pod-verrou-#{System.unique_integer([:positive])}"
      enqueue!(pod)

      assert {:ok, %{"pr" => 412}} = Toolchain.request_toolchain(req(), pod)

      lock = Fleet.Toolchain.waiting_label()
      assert_received {:add_label, "fleet/morse", 412, ^lock}
      assert_received {:post_comment, "fleet/morse", 412, body}
      assert body =~ Fleet.Toolchain.marker(412)
    end

    test "échec du VERROU = échec de la demande (fail-loud, le pod ré-émet — chaîne idempotente)" do
      pod = "pod-verrou-ko-#{System.unique_integer([:positive])}"
      enqueue!(pod)
      Process.put(:add_label_result, {:error, {:http, 500, "boom"}})

      assert {:error, {:http, 500, _}} = Toolchain.request_toolchain(req(), pod)
      # Sans le verrou, le dispatcher re-proposerait un ticket dont la demande est en vol — le
      # refus force le ré-émit, et toute la chaîne amont se rejoue sans doublon.
      refute_received {:post_comment, _, _, _}
    end

    test "échec du COMMENTAIRE = demande OK quand même (best-effort — le drain se key sur le verrou)" do
      pod = "pod-comment-ko-#{System.unique_integer([:positive])}"
      enqueue!(pod)
      Process.put(:post_comment_result, {:error, :forge_down})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{"pr" => 412}} = Toolchain.request_toolchain(req(), pod)
        end)

      assert log =~ "commentaire de lien NON pos"
    end
  end

  describe "l'auto-merge — UN clic admin, gate par config, DEFAUT OFF" do
    test "defaut : PAS d'armement (sans protection de branche, l'armer mergerait sans signature)" do
      pod = "pod-am-off-#{System.unique_integer([:positive])}"
      enqueue!(pod)
      {:ok, _} = Toolchain.request_toolchain(req(), pod)
      refute_received {:auto_merge_armed, _, _}
    end

    test "config posee (par le geste d'installation, AVEC la protection) : la PR est armee" do
      prev = Application.get_env(:lcars_fleet, :toolchain_auto_merge)
      Application.put_env(:lcars_fleet, :toolchain_auto_merge, true)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:lcars_fleet, :toolchain_auto_merge, prev),
          else: Application.delete_env(:lcars_fleet, :toolchain_auto_merge)
      end)

      pod = "pod-am-on-#{System.unique_integer([:positive])}"
      enqueue!(pod)
      assert {:ok, %{"pr" => 412}} = Toolchain.request_toolchain(req(), pod)
      assert_received {:auto_merge_armed, _repo, 412}
    end
  end
end
