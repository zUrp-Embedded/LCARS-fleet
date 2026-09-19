defmodule Fleet.Admiral.ToolchainReconcilerTest do
  @moduledoc """
  Exercises manual passes with forge/convergence stubs and a temporary marker.
  Socket cases use a fake privileged service. Checks marker/result protocol, not
  package installation, container rebuild mounts, protected-branch policy or timers.
  Exit-code cases replay, through the fake service, the FAIL line that
  services/privileged-executor.py writes for a failed converger.
  """
  use ExUnit.Case, async: false

  alias Fleet.Forge.PayloadFixture

  alias Fleet.Admiral.ToolchainReconciler, as: R

  defmodule ForgeUp do
    def branch_head(_repo, _branch, _opts),
      do: {:ok, :persistent_term.get({__MODULE__, :head}, "sha-1")}

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

    def delete_branch(repo, branch, _opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:deleted, repo, branch})
      :persistent_term.get({__MODULE__, :delete_result}, {:ok, :deleted})
    end

    # Les branches que la forge porte : par defaut, aucune de la famille des demandes.
    def list_branches(_repo, _opts),
      do:
        {:ok,
         :persistent_term.get({__MODULE__, :branches}, [%{name: "main", sha: "s", message: ""}])}
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
    :persistent_term.put({ForgeUp, :delete_result}, {:ok, :deleted})

    prev_forge = Application.get_env(:lcars_fleet, :admiral_forge_client)
    prev_conv = Application.get_env(:lcars_fleet, :toolchain_converger)
    Application.put_env(:lcars_fleet, :admiral_forge_client, ForgeUp)

    # Record calls instead of invoking the privileged socket service.
    test = self()

    Application.put_env(:lcars_fleet, :toolchain_converger, fn head, _opts ->
      send(test, {:converged, head})

      case :persistent_term.get({__MODULE__, :converger_result}, :ok) do
        :ok -> :ok
        other -> other
      end
    end)

    # Long interval keeps these cases on the manual path, not periodic re-arming.
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
      # An absent marker simulates the comparison input after rebuild; no rebuild occurs.
      assert R.applied_sha() == nil
      assert {:ok, :converged, "sha-1"} = R.check_now(server)
      assert_received {:converged, "sha-1"}
    end

    test "le SHA noté, la passe suivante ne fait RIEN", %{server: server} do
      {:ok, :converged, _} = R.check_now(server)
      assert R.applied_sha() == "sha-1"
      # Consume the first call before asserting that the second pass does not repeat it.
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

      assert {:error, {:branch_unreadable, :econnrefused}} = R.check_now(server)
      assert R.applied_sha() == nil
      refute_received {:converged, _}
    end

    test "convergeur en échec : le SHA appliqué reste INCHANGÉ", %{server: server} do
      converger_result({:error, :boom})

      assert {:error, :boom} = R.check_now(server)

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
      # A temporary file blocks parent-directory creation and marker writing.
      blocker =
        Fleet.TestEnv.tmp_path("lcars-recon-block")

      File.write!(blocker, "pas un dossier")
      on_exit(fn -> File.rm_rf!(blocker) end)
      System.put_env("LCARS_TOOLCHAIN_RUN_STATE", Path.join(blocker, "sub"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :converged, "sha-1"} = R.check_now(server)
        end)

      assert R.applied_sha() == nil
      assert log =~ "INÉCRIVABLE"
    end
  end

  describe "la plomberie est à PeriodicCheck, pas ici" do
    test "le module ne porte AUCUN timer maison" do
      # Textual guard against several timer APIs, not an AST or behavior check.
      src = File.read!("lib/fleet/admiral/toolchain_reconciler.ex")

      code =
        for {l, i} <- Enum.with_index(String.split(src, "\n"), 1),
            not String.starts_with?(String.trim(l), "#"),
            do: {i, l}

      armes =
        for {i, l} <- code,
            Regex.match?(
              ~r/(send_after|send_interval|start_timer|:timer\.(apply_)?(after|interval))/,
              l
            ),
            do: "#{i}: #{String.trim(l)}"

      assert armes == [],
             "un timer maison est revenu dans ce module — la plomberie appartient a " <>
               "`PeriodicCheck` :\n" <> Enum.join(armes, "\n")

      # This only checks that PeriodicCheck occurs in source, not that it schedules.
      assert src =~ "PeriodicCheck",
             "plus aucune planification : le reconciliateur ne tourne plus, et l'absence de timer " <>
               "maison n'est plus une bonne nouvelle"
    end
  end

  describe "la seconde passe — le drain (une PR fermee ne fait pas bouger la branche)" do
    # Extend the captured forge payload with the facts needed by this scenario.
    defp pr(faits \\ []) do
      PayloadFixture.pull(
        [
          number: 7,
          state: "open",
          merged: false,
          base_ref: Fleet.Toolchain.branch(),
          head_ref: Fleet.Toolchain.branch_for("wi-42"),
          body: "demande\n" <> Fleet.Toolchain.workitem_marker("fleet/morse", 42)
        ] ++ faits
      )
    end

    # La branche de demande est la SEULE que le runtime cree sur le depot systeme, et elle part avec
    # sa PR (⚖ user 2026-09-16 : « pas laisser le systeme creer des branches a l'envie »).
    test "PR MERGEE + branche appliquee => la branche de demande est SUPPRIMEE du depot systeme",
         %{server: server} do
      :persistent_term.put({ForgeUp, :prs}, [pr(state: "closed", merged: true)])

      assert {:ok, :converged, _} = R.check_now(server)
      assert_received {:deleted, repo, "tool_request-wi-42"}
      assert repo == Fleet.Toolchain.ops_repo()
    end

    test "PR FERMEE SANS MERGE => la branche de demande est supprimee aussi", %{server: server} do
      :persistent_term.put({ForgeUp, :prs}, [pr(state: "closed", merged: false)])

      assert {:ok, _, _} = R.check_now(server)
      assert_received {:deleted, _, "tool_request-wi-42"}
    end

    test "PR MERGEE mais NON appliquee => la branche RESTE (le drain n'a pas eu lieu)", %{
      server: server
    } do
      converger_result({:error, :boom})
      :persistent_term.put({ForgeUp, :prs}, [pr(state: "closed", merged: true)])

      assert {:error, :boom} = R.check_now(server)
      refute_received {:deleted, _, _}
    end

    test "PR OUVERTE => la branche reste", %{server: server} do
      :persistent_term.put({ForgeUp, :prs}, [pr()])
      assert {:ok, _, _} = R.check_now(server)
      refute_received {:deleted, _, _}
    end

    test "une tete HORS de la famille tool_request-* n'est JAMAIS supprimee, drainee ou non", %{
      server: server
    } do
      :persistent_term.put({ForgeUp, :prs}, [
        pr(state: "closed", merged: false, head_ref: "feature/quelque-chose"),
        pr(state: "closed", merged: false, head_ref: Fleet.Toolchain.branch())
      ])

      assert {:ok, _, _} = R.check_now(server)
      assert_received {:removed, "fleet/morse", 42, _}
      refute_received {:deleted, _, _}
    end

    test "une suppression refusee par la forge est dite, le drain a eu lieu, et ne se rejoue pas",
         %{server: server} do
      :persistent_term.put({ForgeUp, :delete_result}, {:error, {:http, 500, "boom"}})
      :persistent_term.put({ForgeUp, :prs}, [pr(state: "closed", merged: false)])

      log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, _, _} = R.check_now(server) end)
      assert_received {:removed, "fleet/morse", 42, _}
      assert_received {:deleted, _, "tool_request-wi-42"}
      assert log =~ "NON supprimée"
      assert log =~ "à supprimer à la main"
    end

    # La liste des PR est `state=all` : une PR historique repasse a chaque tick. Sans verrou sur
    # son issue, elle est deja drainee — aucun DELETE, aucune ligne de journal.
    test "une PR deja drainee (verrou absent de l'issue) ne provoque ni DELETE ni journal a chaque tick",
         %{server: server} do
      :persistent_term.put({ForgeUp, :issue_labels}, [])
      :persistent_term.put({ForgeUp, :prs}, [pr(state: "closed", merged: false)])

      log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, _, _} = R.check_now(server) end)
      refute_received {:removed, _, _, _}
      refute_received {:deleted, _, _}
      refute log =~ "supprimée"
    end

    test "une branche deja absente au drain n'est pas annoncee supprimee", %{server: server} do
      :persistent_term.put({ForgeUp, :delete_result}, {:ok, :absent})
      :persistent_term.put({ForgeUp, :prs}, [pr(state: "closed", merged: false)])

      log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, _, _} = R.check_now(server) end)
      assert_received {:deleted, _, "tool_request-wi-42"}
      refute log =~ "supprimée ("
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
      converger_result({:error, :boom})
      :persistent_term.put({ForgeUp, :prs}, [pr(state: "closed", merged: true)])

      assert {:error, :boom} = R.check_now(server)
      refute_received {:removed, _, _, _}
    end

    test "PR FERMEE SANS MERGE => drain SANS condition, avec le refus commente", %{server: server} do
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
      fake_privileged([executor_reply(2), "OK:sha-2"])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:converger_failed, 2, ""}} = R.check_now(server)
        end)

      assert_receive :privileged_called

      # banc 2002 : la ligne « la passe suivante réessaiera » précédait celle du gel et la contredisait
      assert log =~ "gelé"
      refute log =~ "réessaiera"

      assert {:error, {:manifest_rejected, "sha-1"}} = R.check_now(server)
      refute_received :privileged_called

      :persistent_term.put({ForgeUp, :head}, "sha-2")
      assert {:ok, :converged, "sha-2"} = R.check_now(server)
      assert_receive :privileged_called
    end

    # 1 host dependency (target keyring included), 3 application failed, 4 forge unreadable or
    # lock held: each is repaired without a new merge, so none may freeze the head.
    for rc <- [1, 3, 4] do
      test "rc=#{rc} ne gèle PAS : le tick suivant rappelle le convergeur", %{server: server} do
        rc = unquote(rc)
        fake_privileged([executor_reply(rc), executor_reply(rc)])

        assert {:error, {:converger_failed, ^rc, ""}} = R.check_now(server)
        assert_receive :privileged_called

        assert {:error, {:converger_failed, ^rc, ""}} = R.check_now(server)
        assert_receive :privileged_called
      end
    end

    test "un refus du service lui-même ne porte pas de code : il ne gèle pas", %{server: server} do
      fake_privileged(["FAIL:busy", "FAIL:converger_failed:", "OK:sha-1"])

      assert {:error, {:converger_refused, "busy"}} = R.check_now(server)
      assert {:error, {:converger_refused, "converger_failed:"}} = R.check_now(server)
      assert {:ok, :converged, "sha-1"} = R.check_now(server)
    end
  end

  # The line is read from the executor's source: a change of its wire format turns this file
  # red instead of leaving the freeze tested against a shape the service never writes.
  defp executor_reply(rc) do
    src = File.read!("services/privileged-executor.py")

    case Regex.run(~r/done\(f"(FAIL:converger_failed:)\{proc\.returncode\}"\)/, src) do
      [_, prefix] ->
        prefix <> Integer.to_string(rc)

      nil ->
        flunk(
          "services/privileged-executor.py n'écrit plus `FAIL:converger_failed:{proc.returncode}` " <>
            "— accorder la lecture de ToolchainReconciler et ce témoin à la nouvelle ligne"
        )
    end
  end

  # Default transport connects without sending a SHA; the service chooses what to apply.

  # nil closes without a line, exercising a different result from an empty line.
  defp answer_once(conn, reply) do
    if reply, do: :gen_tcp.send(conn, reply <> "\n")
    :gen_tcp.close(conn)
  end

  # One connection per reply, in order. Once the replies are spent the listener closes, so an
  # unexpected extra call fails as unreachable instead of waiting for an answer.
  defp serve_replies(listen, [], _test), do: :gen_tcp.close(listen)

  defp serve_replies(listen, [reply | rest], test) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, conn} ->
        send(test, :privileged_called)
        answer_once(conn, reply)
        serve_replies(listen, rest, test)

      _accept_failed ->
        :gen_tcp.close(listen)
    end
  end

  defp fake_privileged(replies) when is_list(replies) do
    path = Path.join(System.tmp_dir!(), "tc-#{System.unique_integer([:positive])}.sock")

    {:ok, listen} =
      :gen_tcp.listen(0, [{:ifaddr, {:local, path}}, :binary, packet: :line, active: false])

    test = self()
    {:ok, _} = Task.start(fn -> serve_replies(listen, replies, test) end)

    Application.delete_env(:lcars_fleet, :toolchain_converger)
    Application.put_env(:lcars_fleet, :toolchain_socket, path)

    on_exit(fn ->
      _ = :gen_tcp.close(listen)
      _ = File.rm(path)
      Application.delete_env(:lcars_fleet, :toolchain_socket)
    end)

    path
  end

  defp fake_privileged(reply), do: fake_privileged([reply])

  describe "le SHA noté est celui qui a été APPLIQUÉ" do
    # The fake service reports a different SHA; the marker must preserve its response.
    test "la branche a avancé pendant la convergence → c'est l'état APPLIQUÉ qui est noté", %{
      server: server
    } do
      fake_privileged("OK:sha-plus-recent")

      assert {:ok, :converged, "sha-plus-recent"} = R.check_now(server)
      assert R.applied_sha() == "sha-plus-recent"
    end

    test "cas nominal : le service rend la tête qu'on avait lue, elle est notée telle quelle", %{
      server: server
    } do
      fake_privileged("OK:sha-1")

      assert {:ok, :converged, "sha-1"} = R.check_now(server)
      assert R.applied_sha() == "sha-1"
    end
  end

  describe "la porte fermée et la porte gardée ne se disent pas pareil" do
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

    # Closed socket, unrecognized line and empty line traverse distinct failure branches.
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

    # OK without a SHA must not create an empty marker and force endless reconvergence.
    test "« OK: » sans SHA n'est pas un succès", %{server: server} do
      path = fake_privileged("OK:")

      assert {:error, {:converger_mute, ^path, "OK:"}} = R.check_now(server)
      refute R.applied_sha() == "sha-1"
    end
  end

  # ⚠ LE DRAIN S'ACCROCHE AUX PR : une branche de demande qui n'en a JAMAIS eu — une demande morte
  # entre sa création et l'ouverture de sa PR — n'est vue par personne et reste pour toujours.
  # Mesuré le 2026-09-19 sur le banc 2005, et les trois `lcars/toolchain-*` de LCARS-beta.
  describe "les branches de demande SANS PR" do
    defp pose_branches(noms) do
      :persistent_term.put(
        {ForgeUp, :branches},
        Enum.map(noms, &%{name: &1, sha: "s", message: ""})
      )

      on_exit(fn -> :persistent_term.erase({ForgeUp, :branches}) end)
    end

    test "une orpheline vue DEUX passes de suite est supprimée", %{server: server} do
      pose_branches(["main", "tool_request", "tool_request-abandonnee"])

      # Première passe : elle est VUE, jamais touchée — la demande pourrait être en vol.
      {:ok, :converged, _} = R.check_now(server)
      refute_received {:deleted, _, "tool_request-abandonnee"}

      # Seconde : deux vues de suite, elle est abandonnée pour de bon.
      {:ok, :up_to_date} = R.check_now(server)
      assert_received {:deleted, "lcars/_ops", "tool_request-abandonnee"}
    end

    test "la branche PROTÉGÉE et les branches d'un autre monde ne sont JAMAIS touchées", %{
      server: server
    } do
      pose_branches(["main", "tool_request", "incidents", "feature/quelque-chose"])

      {:ok, :converged, _} = R.check_now(server)
      {:ok, :up_to_date} = R.check_now(server)

      refute_received {:deleted, _, _}
    end

    test "une branche qui PORTE une PR n'est pas balayée — le drain s'en occupe", %{
      server: server
    } do
      pose_branches(["main", "tool_request", "tool_request-avec-pr"])

      :persistent_term.put({ForgeUp, :prs}, [
        PayloadFixture.pull(
          number: 7,
          state: "open",
          merged: false,
          base_ref: Fleet.Toolchain.branch(),
          head_ref: "tool_request-avec-pr",
          body: "demande\n" <> Fleet.Toolchain.workitem_marker("fleet/p", 1)
        )
      ])

      {:ok, :converged, _} = R.check_now(server)
      {:ok, :up_to_date} = R.check_now(server)

      refute_received {:deleted, _, "tool_request-avec-pr"}
    end
  end
end
