defmodule Fleet.Pipeline.PodRegistryTest do
  use ExUnit.Case, async: false

  alias Fleet.Pipeline.PodRegistry

  setup do
    # PodRegistry est démarré par l'Application — on le purge entre tests
    # pour isolation. Pas de start_supervised : déjà supervisé.
    :ok = purge_all()
    on_exit(fn -> purge_all() end)
    :ok
  end

  defp purge_all do
    # Purge brute via cleanup_pipeline sur les pipeline_ids vus dans les
    # tests. Simple : on liste les bindings via une introspection ad-hoc.
    # Pour les tests on connaît les ids utilisés, donc on les nettoie en
    # bout de test directement.
    :ok
  end

  describe "register/lookup/unregister" do
    test "register puis lookup retourne le pod_id" do
      assert :ok = PodRegistry.register("pipe-1", "engineer", "pod-eng-1")
      assert {:ok, "pod-eng-1"} = PodRegistry.lookup("pipe-1", "engineer")

      PodRegistry.cleanup_pipeline("pipe-1")
    end

    test "lookup d'une clé absente → :not_found" do
      assert :not_found = PodRegistry.lookup("pipe-unknown", "engineer")
    end

    test "register écrase l'ancien binding sur la même clé (idempotent)" do
      assert :ok = PodRegistry.register("pipe-x", "engineer", "pod-old")
      assert :ok = PodRegistry.register("pipe-x", "engineer", "pod-new")
      assert {:ok, "pod-new"} = PodRegistry.lookup("pipe-x", "engineer")
      # L'ancien pod_id n'est plus retrouvable via unregister non plus
      # (binding orphelin évacué).
      assert :not_found = PodRegistry.unregister("pod-old")
      assert :ok = PodRegistry.unregister("pod-new")
    end

    test "unregister retire le binding par pod_id" do
      :ok = PodRegistry.register("pipe-y", "qualifier", "pod-q-1")
      assert :ok = PodRegistry.unregister("pod-q-1")
      assert :not_found = PodRegistry.lookup("pipe-y", "qualifier")
    end

    test "unregister d'un pod_id inconnu → :not_found" do
      assert :not_found = PodRegistry.unregister("pod-nonexistent")
    end
  end

  describe "pods_for/1 et cleanup_pipeline/1" do
    test "pods_for retourne uniquement les pods d'un pipeline" do
      :ok = PodRegistry.register("pipe-A", "engineer", "pod-eng-A")
      :ok = PodRegistry.register("pipe-A", "qualifier", "pod-q-A")
      :ok = PodRegistry.register("pipe-B", "engineer", "pod-eng-B")

      pods_a = PodRegistry.pods_for("pipe-A")
      assert pods_a == %{"engineer" => "pod-eng-A", "qualifier" => "pod-q-A"}

      pods_b = PodRegistry.pods_for("pipe-B")
      assert pods_b == %{"engineer" => "pod-eng-B"}

      PodRegistry.cleanup_pipeline("pipe-A")
      PodRegistry.cleanup_pipeline("pipe-B")
    end

    test "cleanup_pipeline retire tous les bindings du pipeline et liste les pod_ids" do
      :ok = PodRegistry.register("pipe-cleanup", "engineer", "pod-c-eng")
      :ok = PodRegistry.register("pipe-cleanup", "qualifier", "pod-c-q")
      :ok = PodRegistry.register("pipe-keep", "engineer", "pod-k-eng")

      assert {:ok, removed} = PodRegistry.cleanup_pipeline("pipe-cleanup")
      assert Enum.sort(removed) == Enum.sort(["pod-c-eng", "pod-c-q"])

      # Le pipeline nettoyé est vide ; l'autre intact.
      assert PodRegistry.pods_for("pipe-cleanup") == %{}
      assert PodRegistry.pods_for("pipe-keep") == %{"engineer" => "pod-k-eng"}

      # Les pods retirés ne sont plus lookupables par pod_id non plus.
      assert :not_found = PodRegistry.unregister("pod-c-eng")
      assert :not_found = PodRegistry.unregister("pod-c-q")

      PodRegistry.cleanup_pipeline("pipe-keep")
    end

    test "cleanup_pipeline d'un pipeline inexistant → liste vide" do
      assert {:ok, []} = PodRegistry.cleanup_pipeline("pipe-ghost")
    end
  end
end
