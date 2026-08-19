defmodule Fleet.Pilot.ToolchainReconcilerTest do
  @moduledoc """
  Le déclencheur est une COMPARAISON, et ces cas défendent les endroits où elle peut mentir.

  Trois mensonges possibles, tous silencieux : conclure « à jour » quand la forge est injoignable,
  conclure « à jour » sur une boîte qui n'a jamais rien appliqué, et noter un SHA que le convergeur
  n'a pas réussi à poser. Les trois rendraient un état approuvé mais non appliqué — précisément ce
  que le rail entier existe pour supprimer.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ToolchainReconciler, as: R

  defmodule ForgeUp do
    def branch_head(_repo, _branch, _opts), do: {:ok, Process.get(:head, "sha-1")}
  end

  defmodule ForgeDown do
    def branch_head(_repo, _branch, _opts), do: {:error, :econnrefused}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "lcars-recon-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "state"))
    prev_root = System.get_env("LCARS_STORE_ROOT")
    System.put_env("LCARS_STORE_ROOT", root)

    prev_forge = Application.get_env(:lcars_fleet, :forge_client)
    prev_conv = Application.get_env(:lcars_fleet, :toolchain_converger)
    Application.put_env(:lcars_fleet, :forge_client, ForgeUp)

    # Le convergeur par défaut appellerait `sudo`. Ici il ENREGISTRE, parce que ce qu'on teste est
    # la décision de l'appeler et l'ordre dans lequel le SHA est noté — pas ce que root fait.
    test = self()

    Application.put_env(:lcars_fleet, :toolchain_converger, fn head, _opts ->
      send(test, {:converged, head})
      Process.get(:converger_result, :ok)
    end)

    on_exit(fn ->
      if prev_root, do: System.put_env("LCARS_STORE_ROOT", prev_root), else: System.delete_env("LCARS_STORE_ROOT")
      restore(:forge_client, prev_forge)
      restore(:toolchain_converger, prev_conv)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  defp restore(key, nil), do: Application.delete_env(:lcars_fleet, key)
  defp restore(key, val), do: Application.put_env(:lcars_fleet, key, val)

  describe "la comparaison" do
    test "boîte neuve : AUCUN SHA appliqué ⇒ elle converge, même si la branche n'a pas bougé" do
      # LE CAS DU REBUILD, et c'est pour lui que `nil` ≠ « à jour » : /usr est revenu à la baseline
      # de l'image pendant que la branche, elle, n'a pas changé d'un octet.
      assert R.applied_sha() == nil
      assert {:ok, :converged, "sha-1"} = R.reconcile([])
      assert_received {:converged, "sha-1"}
    end

    test "le SHA noté, la passe suivante ne fait RIEN" do
      {:ok, :converged, _} = R.reconcile([])
      assert R.applied_sha() == "sha-1"
      # On CONSOMME le message de la première passe : sans ça le `refute` ci-dessous attraperait
      # celle-là et le témoin passerait pour une raison qui n'est pas la sienne.
      assert_received {:converged, "sha-1"}

      assert {:ok, :up_to_date} = R.reconcile([])
      refute_received {:converged, _}
    end

    test "la branche bouge ⇒ nouvelle convergence" do
      {:ok, :converged, _} = R.reconcile([])
      Process.put(:head, "sha-2")

      assert {:ok, :converged, "sha-2"} = R.reconcile([])
      assert R.applied_sha() == "sha-2"
    end
  end

  describe "les trois façons de mentir, et ce qui les empêche" do
    test "forge injoignable : ce n'est PAS « à jour »" do
      Application.put_env(:lcars_fleet, :forge_client, ForgeDown)

      # Rendre `:up_to_date` ici ferait qu'une panne réseau se lise comme « rien à faire » — et sur
      # un rebuild la boîte resterait sans outillage en annonçant que tout va bien.
      assert {:error, {:branch_unreadable, :econnrefused}} = R.reconcile([])
      assert R.applied_sha() == nil
      refute_received {:converged, _}
    end

    test "convergeur en échec : le SHA appliqué reste INCHANGÉ" do
      Process.put(:converger_result, {:error, :boom})

      assert {:error, :boom} = R.reconcile([])
      # Noter avant d'appliquer ferait d'un convergeur mort en route une boîte qui se croit à jour :
      # la passe suivante verrait « pas d'écart » et l'état approuvé resterait non appliqué.
      assert R.applied_sha() == nil

      Process.delete(:converger_result)
      assert {:ok, :converged, "sha-1"} = R.reconcile([])
    end

    test "un échec puis une reprise n'exigent aucune intervention" do
      Process.put(:converger_result, {:error, :transient})
      assert {:error, :transient} = R.reconcile([])

      Process.delete(:converger_result)
      assert {:ok, :converged, _} = R.reconcile([])
      assert R.applied_sha() == "sha-1"
    end
  end

  describe "sans magasin" do
    test "convergé quand même, mais le SHA n'a nulle part où vivre — et ça se DIT" do
      System.delete_env("LCARS_STORE_ROOT")

      assert {:ok, :converged, "sha-1"} = R.reconcile([])
      # Sans mémoire, la passe suivante reconvergera. C'est correct (la convergence est idempotente)
      # et ça doit être visible plutôt que d'être pris pour un cycle normal.
      assert R.applied_sha() == nil
    end
  end
end
