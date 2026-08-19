defmodule Fleet.MCP.ToolchainRequestTest do
  @moduledoc """
  L'IDENTITÉ EST LE CANAL, et c'est tout ce que ces cas défendent.

  Un pod bloqué demande un outil que la boîte n'a pas. Ce que la demande devient — un diff qu'un
  humain signe, puis ce que root applique — rend la question « au nom de qui ? » plus lourde ici que
  partout ailleurs dans la surface MCP. Rien dans les arguments ne nomme un ticket : le work-item
  se DÉDUIT du `pod_id` que l'accepteur de socket a lié. Ces témoins épinglent qu'on ne peut pas
  contourner ça, et qu'on ne casse rien en le lisant.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools.Delegation
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
    def open_pr(repo, head, base, title, _opts) do
      send(self(), {:open_pr, repo, head, base, title})
      {:ok, %{"number" => 412}}
    end
  end

  setup do
    prev = Application.get_env(:lcars_fleet, :mcp_forge_client)
    Application.put_env(:lcars_fleet, :mcp_forge_client, Writer)
    on_exit(fn ->
      if prev,
        do: Application.put_env(:lcars_fleet, :mcp_forge_client, prev),
        else: Application.delete_env(:lcars_fleet, :mcp_forge_client)
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
        issue_id: "412",
        role: "engineer",
        brief: "compile le module morse"
      })

    item
  end

  describe "l'identité vient du canal, jamais des arguments" do
    test "sans `pod_id`, la demande est refusée — et typée" do
      # Un manifeste dont on ne connaît pas l'origine est un manifeste qu'aucun humain ne peut
      # juger et qu'aucun merge ne se laisse retracer.
      assert {:error, :pod_id_required} = Delegation.request_toolchain(req(), nil)
      assert {:error, :pod_id_required} = Delegation.request_toolchain(req(), "")
    end

    test "un pod sans work-item actif ne peut pas demander" do
      assert {:error, :no_active_work_item} =
               Delegation.request_toolchain(req(), "pod-sans-item-#{System.unique_integer()}")
    end
  end

  describe "la lecture du work-item ne MUTE rien" do
    test "l'item reste `pending` — pas d'assignation fantôme" do
      pod = "pod-lecture-#{System.unique_integer([:positive])}"
      item = enqueue!(pod)
      assert item.state == :pending

      {:ok, _} = Delegation.request_toolchain(req(), pod)

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

      assert {:error, {:toolchain_form, _}} = Delegation.request_toolchain(bad, pod)
      refute_received {:create_branch, _, _, _}
      refute_received {:put_file, _, _, _, _}
    end

    test "la séquence est branche -> fichier -> PR, et le fichier va sur la BRANCHE" do
      pod = "pod-sequence-#{System.unique_integer([:positive])}"
      item = enqueue!(pod)

      assert {:ok, %{"status" => "toolchain_requested", "pr" => 412}} =
               Delegation.request_toolchain(req(), pod)

      branch = Fleet.Toolchain.branch_for(item.id)
      base = Fleet.Toolchain.branch()

      # `assert_received` lit la boîte dans l'ordre d'arrivée : la séquence EST le contrat. Un
      # fichier écrit avant sa branche, ou sur `base` au lieu de la branche de demande, ferait
      # atterrir une déclaration non validée là où le convergeur la trouverait.
      assert_received {:create_branch, _repo, ^branch, ^base}
      assert_received {:put_file, _repo, "ops/toolchains.d/python.yaml", content, ^branch}
      assert_received {:open_pr, _repo, ^branch, ^base, "[toolchain] python"}

      assert content =~ "kind: ecosystem_enable"
      assert content =~ "ecosystem: python"
      # La traçabilité voyage AVEC le document : le merge doit pouvoir être retracé au ticket.
      # CITÉ, et c'est juste : `issue_id` est une chaîne, et un scalaire qui commence par un chiffre
      # non cité se lit comme un nombre — `01` deviendrait `1`.
      assert content =~ ~s(issue: "412")
      assert content =~ "work_item: "
    end

    test "une branche déjà là n'est pas une erreur — c'est le second appel du même besoin" do
      pod = "pod-retry-#{System.unique_integer([:positive])}"
      enqueue!(pod)
      Process.put(:create_branch_result, {:error, {:http, 409, "already exists"}})

      # IDEMPOTENCE PAR LA BRANCHE : son nom dérive du work-item, donc un retry réécrit le même
      # fichier au lieu d'ouvrir une DEUXIÈME pull request pour un seul besoin.
      assert {:ok, %{"pr" => 412}} = Delegation.request_toolchain(req(), pod)
      assert_received {:put_file, _, _, _, _}
    end

    test "le manifeste est keyé sur l'écosystème, pas sur la demande" do
      pod = "pod-eco-#{System.unique_integer([:positive])}"
      enqueue!(pod)

      {:ok, _} = Delegation.request_toolchain(req(%{"ecosystem" => "rust"}), pod)
      assert_received {:put_file, _, "ops/toolchains.d/rust.yaml", _, _}
    end
  end
end
