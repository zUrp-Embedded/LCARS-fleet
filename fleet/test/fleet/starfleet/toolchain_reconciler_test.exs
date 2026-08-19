defmodule Fleet.Starfleet.ToolchainReconcilerTest do
  @moduledoc """
  Le déclencheur est une COMPARAISON, et ces cas défendent les endroits où elle peut mentir.

  Trois mensonges possibles, tous silencieux : conclure « à jour » quand la forge est injoignable,
  conclure « à jour » sur une boîte qui n'a jamais rien appliqué (LE CAS DU REBUILD — le marqueur
  meurt avec le conteneur, c'est voulu), et noter un SHA que le convergeur n'a pas réussi à poser.
  Les trois rendraient un état approuvé mais non appliqué — précisément ce que le rail entier
  existe pour supprimer.

  FORME : les témoins pilotent `check_now/1` — le hook `PeriodicCheck` qui REJOUE le chemin
  complet du tick sans re-armer. Une v1 exposait `reconcile/1` à la main « pour la testabilité »,
  la forme que `04` §6 condamne : des témoins qui passeraient inchangés prouveraient que la
  migration n'a pas eu lieu.
  """
  use ExUnit.Case, async: false

  alias Fleet.Starfleet.ToolchainReconciler, as: R

  defmodule ForgeUp do
    def branch_head(_repo, _branch, _opts), do: {:ok, :persistent_term.get({__MODULE__, :head}, "sha-1")}

    # La 2e passe (drain) : PRs scriptees, issue au verrou scriptable, gestes ENREGISTRES.
    def list_pulls(_repo, _opts), do: {:ok, :persistent_term.get({__MODULE__, :prs}, [])}

    def get_issue(_repo, _n, _opts) do
      labels = :persistent_term.get({__MODULE__, :issue_labels}, [%{"name" => "lcars-awaits-toolchain"}])
      {:ok, %{"labels" => labels}}
    end

    def remove_label(repo, n, label, _opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:removed, repo, n, label})
      {:ok, %{}}
    end

    def post_comment(repo, n, body, _opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:commented, repo, n, body})
      {:ok, %{}}
    end
  end

  defmodule ForgeDown do
    def branch_head(_repo, _branch, _opts), do: {:error, :econnrefused}
    def list_pulls(_repo, _opts), do: {:error, :econnrefused}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "lcars-recon-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev_root = System.get_env("LCARS_TOOLCHAIN_RUN_STATE")
    System.put_env("LCARS_TOOLCHAIN_RUN_STATE", root)
    :persistent_term.put({ForgeUp, :head}, "sha-1")
    :persistent_term.put({ForgeUp, :test_pid}, self())
    :persistent_term.put({ForgeUp, :prs}, [])

    prev_forge = Application.get_env(:lcars_fleet, :forge_client)
    prev_conv = Application.get_env(:lcars_fleet, :toolchain_converger)
    Application.put_env(:lcars_fleet, :forge_client, ForgeUp)

    # Le convergeur par défaut appellerait `sudo`. Ici il ENREGISTRE, parce que ce qu'on teste est
    # la décision de l'appeler et l'ordre dans lequel le SHA est noté — pas ce que root fait.
    test = self()

    Application.put_env(:lcars_fleet, :toolchain_converger, fn head, _opts ->
      send(test, {:converged, head})

      case :persistent_term.get({__MODULE__, :converger_result}, :ok) do
        :ok -> :ok
        other -> other
      end
    end)

    # Le GenServer REEL, nom unique, intervalle d'une heure : aucun tick ne tire pendant le test,
    # tout passe par `check_now` — le chemin du timer, rejoué à la demande.
    name = :"recon_#{System.unique_integer([:positive])}"
    pid = start_supervised!({R, name: name, interval_ms: 3_600_000})

    on_exit(fn ->
      if prev_root,
        do: System.put_env("LCARS_TOOLCHAIN_RUN_STATE", prev_root),
        else: System.delete_env("LCARS_TOOLCHAIN_RUN_STATE")

      restore(:forge_client, prev_forge)
      restore(:toolchain_converger, prev_conv)
      :persistent_term.erase({ForgeUp, :head})
      :persistent_term.erase({ForgeUp, :test_pid})
      :persistent_term.erase({ForgeUp, :prs})
      :persistent_term.erase({ForgeUp, :issue_labels})
      :persistent_term.erase({__MODULE__, :converger_result})
      File.rm_rf!(root)
    end)

    {:ok, root: root, server: pid}
  end

  defp restore(key, nil), do: Application.delete_env(:lcars_fleet, key)
  defp restore(key, val), do: Application.put_env(:lcars_fleet, key, val)

  defp converger_result(v), do: :persistent_term.put({__MODULE__, :converger_result}, v)

  describe "la comparaison" do
    test "boîte neuve (ou REBUILDÉE) : AUCUN SHA appliqué ⇒ elle converge, même si la branche n'a pas bougé",
         %{server: server} do
      # LE CAS DU REBUILD, et c'est pour lui que `nil` ≠ « à jour » ET que le marqueur vit avec le
      # conteneur : /usr est revenu à la baseline de l'image pendant que la branche, elle, n'a pas
      # changé d'un octet.
      assert R.applied_sha() == nil
      assert {:ok, :converged, "sha-1"} = R.check_now(server)
      assert_received {:converged, "sha-1"}
    end

    test "le SHA noté, la passe suivante ne fait RIEN", %{server: server} do
      {:ok, :converged, _} = R.check_now(server)
      assert R.applied_sha() == "sha-1"
      # On CONSOMME le message de la première passe : sans ça le `refute` ci-dessous attraperait
      # celle-là et le témoin passerait pour une raison qui n'est pas la sienne.
      assert_received {:converged, "sha-1"}

      assert {:ok, :up_to_date} = R.check_now(server)
      refute_received {:converged, _}
    end

    test "la branche bouge ⇒ nouvelle convergence", %{server: server} do
      {:ok, :converged, _} = R.check_now(server)
      :persistent_term.put({ForgeUp, :head}, "sha-2")

      assert {:ok, :converged, "sha-2"} = R.check_now(server)
      assert R.applied_sha() == "sha-2"
    end
  end

  describe "les trois façons de mentir, et ce qui les empêche" do
    test "forge injoignable : ce n'est PAS « à jour »", %{server: server} do
      Application.put_env(:lcars_fleet, :forge_client, ForgeDown)

      # Rendre `:up_to_date` ici ferait qu'une panne réseau se lise comme « rien à faire » — et sur
      # un rebuild la boîte resterait sans outillage en annonçant que tout va bien.
      assert {:error, {:branch_unreadable, :econnrefused}} = R.check_now(server)
      assert R.applied_sha() == nil
      refute_received {:converged, _}
    end

    test "convergeur en échec : le SHA appliqué reste INCHANGÉ", %{server: server} do
      converger_result({:error, :boom})

      assert {:error, :boom} = R.check_now(server)
      # Noter avant d'appliquer ferait d'un convergeur mort en route une boîte qui se croit à jour :
      # la passe suivante verrait « pas d'écart » et l'état approuvé resterait non appliqué.
      assert R.applied_sha() == nil

      converger_result(:ok)
      assert {:ok, :converged, "sha-1"} = R.check_now(server)
    end

    test "un échec puis une reprise n'exigent aucune intervention", %{server: server} do
      converger_result({:error, :transient})
      assert {:error, :transient} = R.check_now(server)

      converger_result(:ok)
      assert {:ok, :converged, _} = R.check_now(server)
      assert R.applied_sha() == "sha-1"
    end
  end

  describe "marqueur inécrivable" do
    test "convergé quand même, mais le SHA n'a nulle part où vivre — et ça se DIT", %{server: server} do
      # Un CHEMIN qui ne peut pas exister (fichier en travers) : mkdir_p et write échouent tous
      # les deux — le cas « répertoire non posé par le provisioning », sans toucher au FS réel.
      blocker =
        Path.join(System.tmp_dir!(), "lcars-recon-block-#{System.unique_integer([:positive])}")

      File.write!(blocker, "pas un dossier")
      on_exit(fn -> File.rm_rf!(blocker) end)
      System.put_env("LCARS_TOOLCHAIN_RUN_STATE", Path.join(blocker, "sub"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :converged, "sha-1"} = R.check_now(server)
        end)

      # Sans mémoire, la passe suivante reconvergera. C'est correct (la convergence est idempotente)
      # et ça doit être visible plutôt que d'être pris pour un cycle normal.
      assert R.applied_sha() == nil
      assert log =~ "INÉCRIVABLE"
    end
  end

  describe "la plomberie est à PeriodicCheck, pas ici" do
    test "le module ne porte AUCUN timer maison" do
      src = File.read!("lib/fleet/starfleet/toolchain_reconciler.ex")
      refute src =~ "Process.send_after"
      refute src =~ "defp schedule"
    end
  end
  describe "la seconde passe — le drain (une PR fermee ne fait pas bouger la branche)" do
    defp pr(attrs) do
      Map.merge(
        %{
          "number" => 7,
          "state" => "open",
          "merged" => false,
          "base" => %{"ref" => Fleet.Toolchain.branch()},
          "body" => "demande\n" <> Fleet.Toolchain.workitem_marker("fleet/morse", 42)
        },
        attrs
      )
    end

    test "PR MERGEE + branche appliquee => verrou retire + commentaire", %{server: server} do
      :persistent_term.put({ForgeUp, :prs}, [pr(%{"state" => "closed", "merged" => true})])

      assert {:ok, :converged, _} = R.check_now(server)
      assert_received {:removed, "fleet/morse", 42, "lcars-awaits-toolchain"}
      assert_received {:commented, "fleet/morse", 42, body}
      assert body =~ "APPLIQU"
    end

    test "PR MERGEE mais branche NON appliquee (convergeur en echec) => PAS de drain", %{server: server} do
      # Re-dispatcher un work-item AVANT que sa toolchain soit posee le renverrait au mur.
      converger_result({:error, :boom})
      :persistent_term.put({ForgeUp, :prs}, [pr(%{"state" => "closed", "merged" => true})])

      assert {:error, :boom} = R.check_now(server)
      refute_received {:removed, _, _, _}
    end

    test "PR FERMEE SANS MERGE => drain SANS condition, avec le refus commente", %{server: server} do
      # Il n'y a rien a attendre : la branche n'a pas bouge et ne bougera pas pour cette PR.
      converger_result({:error, :boom})
      :persistent_term.put({ForgeUp, :prs}, [pr(%{"state" => "closed", "merged" => false})])

      assert {:error, :boom} = R.check_now(server)
      assert_received {:removed, "fleet/morse", 42, "lcars-awaits-toolchain"}
      assert_received {:commented, "fleet/morse", 42, body}
      assert body =~ "REFUS"
    end

    test "PR OUVERTE => aucun geste", %{server: server} do
      :persistent_term.put({ForgeUp, :prs}, [pr(%{})])
      {:ok, :converged, _} = R.check_now(server)
      refute_received {:removed, _, _, _}
    end

    test "verrou DEJA absent => idempotent, aucun geste (pas de re-annonce a chaque tick)", %{server: server} do
      :persistent_term.put({ForgeUp, :prs}, [pr(%{"state" => "closed", "merged" => true})])
      :persistent_term.put({ForgeUp, :issue_labels}, [])

      {:ok, :converged, _} = R.check_now(server)
      refute_received {:removed, _, _, _}
      refute_received {:commented, _, _, _}
    end

    test "PR sans marqueur, ou d'une autre base => pas a nous, ni geste ni bruit", %{server: server} do
      :persistent_term.put({ForgeUp, :prs}, [
        pr(%{"body" => "posee a la main", "state" => "closed", "merged" => true}),
        pr(%{"base" => %{"ref" => "main"}, "state" => "closed", "merged" => true})
      ])

      {:ok, :converged, _} = R.check_now(server)
      refute_received {:removed, _, _, _}
    end
  end
end
