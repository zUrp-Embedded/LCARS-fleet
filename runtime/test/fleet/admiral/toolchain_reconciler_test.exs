defmodule Fleet.Admiral.ToolchainReconcilerTest do
  @moduledoc """
  Le déclencheur est une COMPARAISON, et ces cas défendent les endroits où elle peut mentir.

  Trois mensonges possibles, tous silencieux : conclure « à jour » quand la forge est injoignable,
  conclure « à jour » sur un conteneur qui n'a jamais rien appliqué (LE CAS DU REBUILD — le marqueur
  meurt avec le conteneur, c'est voulu), et noter un SHA que le convergeur n'a pas réussi à poser.
  Les trois rendraient un état approuvé mais non appliqué — précisément ce que le rail entier
  existe pour supprimer.

  FORME : les témoins pilotent `check_now/1` — le hook `PeriodicCheck` qui REJOUE le chemin
  complet du tick sans re-armer. Une v1 exposait `reconcile/1` à la main « pour la testabilité »,
  la forme que `04` §6 condamne : des témoins qui passeraient inchangés prouveraient que la
  migration n'a pas eu lieu.
  """
  use ExUnit.Case, async: false

  alias Fleet.Forge.PayloadFixture

  alias Fleet.Admiral.ToolchainReconciler, as: R

  defmodule ForgeUp do
    def branch_head(_repo, _branch, _opts),
      do: {:ok, :persistent_term.get({__MODULE__, :head}, "sha-1")}

    # La 2e passe (drain) : PRs scriptees, issue au verrou scriptable, gestes ENREGISTRES.
    def list_pulls_for_base(_repo, _base, _opts),
      do: {:ok, :persistent_term.get({__MODULE__, :prs}, [])}

    def get_issue(_repo, _n, _opts) do
      labels =
        :persistent_term.get({__MODULE__, :issue_labels}, [%{"name" => "lcars-awaits-toolchain"}])

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
    def list_pulls_for_base(_repo, _base, _opts), do: {:error, :econnrefused}
  end

  setup do
    root = Fleet.TestEnv.tmp_path("lcars-recon")
    File.mkdir_p!(root)
    prev_root = System.get_env("LCARS_TOOLCHAIN_RUN_STATE")
    System.put_env("LCARS_TOOLCHAIN_RUN_STATE", root)
    :persistent_term.put({ForgeUp, :head}, "sha-1")
    :persistent_term.put({ForgeUp, :test_pid}, self())
    :persistent_term.put({ForgeUp, :prs}, [])

    prev_forge = Application.get_env(:lcars_fleet, :admiral_forge_client)
    prev_conv = Application.get_env(:lcars_fleet, :toolchain_converger)
    Application.put_env(:lcars_fleet, :admiral_forge_client, ForgeUp)

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

      restore(:admiral_forge_client, prev_forge)
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
    test "conteneur neuf (ou REBUILDÉ) : AUCUN SHA appliqué ⇒ il converge, même si la branche n'a pas bougé",
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
      Application.put_env(:lcars_fleet, :admiral_forge_client, ForgeDown)

      # Rendre `:up_to_date` ici ferait qu'une panne réseau se lise comme « rien à faire » — et sur
      # un rebuild le conteneur resterait sans outillage en annonçant que tout va bien.
      assert {:error, {:branch_unreadable, :econnrefused}} = R.check_now(server)
      assert R.applied_sha() == nil
      refute_received {:converged, _}
    end

    test "convergeur en échec : le SHA appliqué reste INCHANGÉ", %{server: server} do
      converger_result({:error, :boom})

      assert {:error, :boom} = R.check_now(server)

      # Noter avant d'appliquer ferait d'un convergeur mort en route un conteneur qui se croit à jour :
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
    test "convergé quand même, mais le SHA n'a nulle part où vivre — et ça se DIT", %{
      server: server
    } do
      # Un CHEMIN qui ne peut pas exister (fichier en travers) : mkdir_p et write échouent tous
      # les deux — le cas « répertoire non posé par le provisioning », sans toucher au FS réel.
      blocker =
        Fleet.TestEnv.tmp_path("lcars-recon-block")

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
      src = File.read!("lib/fleet/admiral/toolchain_reconciler.ex")
      refute src =~ "Process.send_after"
      refute src =~ "defp schedule"
    end
  end

  describe "la seconde passe — le drain (une PR fermee ne fait pas bouger la branche)" do
    # La forme complete vient de la capture reelle ; ce fichier n'enonce que les FAITS dont il
    # depend. Un champ qu'il ne nomme pas garde sa valeur reelle au lieu d'etre absent — un garde
    # qui le lirait ne retombe donc plus sur son repli sans le dire.
    defp pr(faits \\ []) do
      PayloadFixture.pull(
        [
          number: 7,
          state: "open",
          merged: false,
          base_ref: Fleet.Toolchain.branch(),
          body: "demande\n" <> Fleet.Toolchain.workitem_marker("fleet/morse", 42)
        ] ++ faits
      )
    end

    test "PR MERGEE + branche appliquee => verrou retire + commentaire", %{server: server} do
      :persistent_term.put({ForgeUp, :prs}, [pr(state: "closed", merged: true)])

      assert {:ok, :converged, _} = R.check_now(server)
      assert_received {:removed, "fleet/morse", 42, "lcars-awaits-toolchain"}
      assert_received {:commented, "fleet/morse", 42, body}
      assert body =~ "APPLIQU"
    end

    test "PR MERGEE mais branche NON appliquee (convergeur en echec) => PAS de drain", %{
      server: server
    } do
      # Re-dispatcher un work-item AVANT que sa toolchain soit posee le renverrait au mur.
      converger_result({:error, :boom})
      :persistent_term.put({ForgeUp, :prs}, [pr(state: "closed", merged: true)])

      assert {:error, :boom} = R.check_now(server)
      refute_received {:removed, _, _, _}
    end

    test "PR FERMEE SANS MERGE => drain SANS condition, avec le refus commente", %{server: server} do
      # Il n'y a rien a attendre : la branche n'a pas bouge et ne bougera pas pour cette PR.
      converger_result({:error, :boom})
      :persistent_term.put({ForgeUp, :prs}, [pr(state: "closed", merged: false)])

      assert {:error, :boom} = R.check_now(server)
      assert_received {:removed, "fleet/morse", 42, "lcars-awaits-toolchain"}
      assert_received {:commented, "fleet/morse", 42, body}
      assert body =~ "REFUS"
    end

    test "PR OUVERTE => aucun geste", %{server: server} do
      :persistent_term.put({ForgeUp, :prs}, [pr()])
      {:ok, :converged, _} = R.check_now(server)
      refute_received {:removed, _, _, _}
    end

    test "verrou DEJA absent => idempotent, aucun geste (pas de re-annonce a chaque tick)", %{
      server: server
    } do
      :persistent_term.put({ForgeUp, :prs}, [pr(state: "closed", merged: true)])
      :persistent_term.put({ForgeUp, :issue_labels}, [])

      {:ok, :converged, _} = R.check_now(server)
      refute_received {:removed, _, _, _}
      refute_received {:commented, _, _, _}
    end

    test "PR sans marqueur, ou d'une autre base => pas a nous, ni geste ni bruit", %{
      server: server
    } do
      :persistent_term.put({ForgeUp, :prs}, [
        pr(body: "posee a la main", state: "closed", merged: true),
        pr(base_ref: "main", state: "closed", merged: true)
      ])

      {:ok, :converged, _} = R.check_now(server)
      refute_received {:removed, _, _, _}
    end
  end

  describe "le SHA refusé est COLLANT (rc=2 du convergeur = document faux)" do
    test "rc=2 => gel : la passe suivante NE rappelle PAS le convergeur ; un nouveau head dégèle",
         %{server: server} do
      converger_result({:error, {:converger_failed, 2, "kind inattendu"}})

      assert {:error, {:converger_failed, 2, _}} = R.check_now(server)
      assert_received {:converged, "sha-1"}

      # Même head : GELÉ — sans ce gel, le rail reboucle toutes les 60 s sur une faute qu'aucun
      # rejeu ne répare (en re-téléchargeant l'installeur à chaque tour — audit 2026-08-19).
      assert {:error, {:manifest_rejected, "sha-1"}} = R.check_now(server)
      refute_received {:converged, _}

      # La branche bouge : le gel se PURGE, le nouveau document a droit à sa chance.
      converger_result(:ok)
      :persistent_term.put({ForgeUp, :head}, "sha-2")
      assert {:ok, :converged, "sha-2"} = R.check_now(server)
    end

    test "rc=3 (retryable) ne gèle PAS : le tick suivant rappelle le convergeur", %{
      server: server
    } do
      converger_result({:error, {:converger_failed, 3, "apt transitoire"}})
      assert {:error, {:converger_failed, 3, "apt transitoire"}} = R.check_now(server)
      assert_received {:converged, "sha-1"}

      assert {:error, {:converger_failed, 3, _}} = R.check_now(server)
      assert_received {:converged, "sha-1"}
    end
  end

  # ─── LE SUDO A DISPARU, ET AVEC LUI L'ARGUMENT ────────────────────────────────────────────────
  #
  # Le geste était `sudo -n /usr/local/bin/lcars-toolchain-converge <sha>`, autorisé par
  # `%fleet ALL=(root) NOPASSWD:` — un chemin `groupe → root` DIRECT, sur un groupe que le
  # convergeur d'humains repeuple depuis la forge toutes les 30 s. Il passe par `toolchain.sock`,
  # et le service y résout LUI-MÊME la tête de la branche protégée : ce module ne dit plus QUOI
  # appliquer, il dit « converge ».

  # Un serveur de socket unix qui rend UNE ligne puis ferme. `nil` = il ferme sans rien écrire.
  defp fake_privileged(reply) do
    path = Path.join(System.tmp_dir!(), "tc-#{System.unique_integer([:positive])}.sock")

    {:ok, listen} =
      :gen_tcp.listen(0, [{:ifaddr, {:local, path}}, :binary, packet: :line, active: false])

    {:ok, _} =
      Task.start(fn ->
        case :gen_tcp.accept(listen, 5_000) do
          {:ok, conn} ->
            if reply, do: :gen_tcp.send(conn, reply <> "\n")
            :gen_tcp.close(conn)

          _ ->
            :ok
        end
      end)

    Application.delete_env(:lcars_fleet, :toolchain_converger)
    Application.put_env(:lcars_fleet, :toolchain_socket, path)

    on_exit(fn ->
      _ = :gen_tcp.close(listen)
      _ = File.rm(path)
      Application.delete_env(:lcars_fleet, :toolchain_socket)
    end)

    path
  end

  describe "le SHA noté est celui qui a été APPLIQUÉ" do
    # ⚠ SANS CE TÉMOIN, LA PANNE EST MUETTE ET DÉFINITIVE. Entre notre lecture de la tête et la
    # résolution que le service fait de son côté, la branche peut avancer — le rail EXISTE pour que
    # des PR y atterrissent. Noter NOTRE tête ferait croire le conteneur à jour sur un état qu'il n'a
    # pas appliqué, et le tick suivant ne verrait AUCUN écart : plus jamais de convergence, et rien
    # ne le dirait.
    test "la branche a avancé pendant la convergence → c'est l'état APPLIQUÉ qui est noté", %{
      server: server
    } do
      fake_privileged("OK:sha-plus-recent")

      assert {:ok, :converged, "sha-plus-recent"} = R.check_now(server)
      assert R.applied_sha() == "sha-plus-recent"
    end

    # LE TÉMOIN DU TÉMOIN : sans lui, un module qui noterait n'importe quoi passerait le test
    # ci-dessus, et le cas nominal ne serait couvert par personne.
    test "cas nominal : le service rend la tête qu'on avait lue, elle est notée telle quelle", %{
      server: server
    } do
      fake_privileged("OK:sha-1")

      assert {:ok, :converged, "sha-1"} = R.check_now(server)
      assert R.applied_sha() == "sha-1"
    end
  end

  describe "la porte fermée et la porte gardée ne se disent pas pareil" do
    # ⚠ UNE SOCKET ABSENTE EST UN FAIT SYSTÈME, PAS UN REFUS. Les confondre envoie l'opérateur
    # chercher une autorisation manquante alors qu'il lui manque une unité qui tourne. Même
    # séparation que `Fleet.Credentials.Authority` tient côté credentials.
    test "socket absente → :privileged_unreachable, jamais un refus du convergeur", %{
      server: server
    } do
      Application.delete_env(:lcars_fleet, :toolchain_converger)
      Application.put_env(:lcars_fleet, :toolchain_socket, "/nonexistent/toolchain.sock")
      on_exit(fn -> Application.delete_env(:lcars_fleet, :toolchain_socket) end)

      assert {:error, {:privileged_unreachable, "/nonexistent/toolchain.sock", _}} =
               R.check_now(server)

      refute R.applied_sha() == "sha-1"
    end

    # ⚠ ET UNE LIGNE VIDE N'EST PAS UN SUCCÈS. Un service qui ferme avant de répondre rend une
    # chaîne vide ; la lire comme « appliqué » noterait un SHA jamais posé — exactement le succès
    # muet que tout ce rail refuse. Le chantier voisin a mesuré la même chose sur `socat`, qui rend
    # ZÉRO avec une sortie VIDE.
    test "le service ferme sans répondre → :converger_mute, jamais « appliqué »", %{
      server: server
    } do
      path = fake_privileged(nil)

      assert {:error, {:converger_mute, ^path, _}} = R.check_now(server)
      refute R.applied_sha() == "sha-1"
    end

    test "le service REFUSE → :converger_refused, avec la cause qu'il a nommée", %{server: server} do
      fake_privileged("FAIL:forge_unreachable")

      assert {:error, {:converger_refused, "forge_unreachable"}} = R.check_now(server)
      refute R.applied_sha() == "sha-1"
    end

    # ⚠ CE TÉMOIN A ÉTÉ AJOUTÉ PARCE QU'UNE MUTATION EST PASSÉE MUETTE, ET LA LEÇON VAUT PLUS QUE
    # LE CAS. Je croyais couvrir « réponse illisible » avec le service qui ferme sans écrire — mais
    # une socket fermée rend `{:error, :closed}`, PAS une ligne vide. Les deux situations empruntent
    # deux branches différentes, et seule la première était exercée : rendre `{:ok, _}` sur une
    # réponse inintelligible ne faisait rougir personne.
    #
    # C'est exactement le succès muet que ce rail refuse ailleurs : un service d'un autre lot, ou un
    # relais qui s'intercale, répondrait autre chose — et le conteneur noterait un SHA jamais appliqué.
    test "une réponse INCOMPRÉHENSIBLE n'est pas un succès", %{server: server} do
      path = fake_privileged("bonjour")

      assert {:error, {:converger_mute, ^path, "bonjour"}} = R.check_now(server)
      refute R.applied_sha() == "sha-1"
    end

    test "une ligne VIDE n'est pas un succès non plus", %{server: server} do
      path = fake_privileged("")

      assert {:error, {:converger_mute, ^path, ""}} = R.check_now(server)
      refute R.applied_sha() == "sha-1"
    end

    # ⚠ ET `OK:` SANS SHA NON PLUS. La garde `byte_size(sha) > 0` existe pour ça : un service qui
    # répond `OK:` tout court ferait écrire un marqueur VIDE, et `applied_sha/0` lit alors « aucun
    # SHA appliqué » — donc une reconvergence à chaque tick, indéfiniment, sans qu'une ligne le dise.
    test "« OK: » sans SHA n'est pas un succès", %{server: server} do
      path = fake_privileged("OK:")

      assert {:error, {:converger_mute, ^path, "OK:"}} = R.check_now(server)
      refute R.applied_sha() == "sha-1"
    end
  end
end
