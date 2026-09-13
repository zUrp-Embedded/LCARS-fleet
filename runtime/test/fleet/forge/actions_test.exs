defmodule Fleet.Forge.Client.ActionsTest do
  use ExUnit.Case, async: true

  alias Fleet.Forge.Client.Actions

  # Le Plug capture méthode, chemin, query et corps produits par Req. Un stub de fonction
  # masquerait les erreurs d'endpoint/paramètre ; ce test ne joint pas une vraie forge.
  defmodule Recorder do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(routes), do: routes

    @impl Plug
    def call(conn, routes) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:req, conn.method, conn.request_path, conn.query_string, body})

      {status, ctype, payload} =
        Enum.find_value(routes, {404, "application/json", "{}"}, fn {match, resp} ->
          if String.contains?(conn.request_path, match), do: resp
        end)

      conn
      |> Plug.Conn.put_resp_header("content-type", ctype)
      |> Plug.Conn.send_resp(status, payload)
    end
  end

  defp json(status, term), do: {status, "application/json", JSON.encode!(term)}
  defp text(status, s), do: {status, "text/plain", s}

  defp opts(routes),
    do: [base_url: "http://fake.test", token: "t", req_options: [plug: {Recorder, routes}]]

  defp drain do
    receive do
      {:req, _, _, _, _} -> drain()
    after
      0 -> :ok
    end
  end

  describe "dispatch_workflow/5 — nommer son run est la condition, pas un confort" do
    test "envoie return_run_details=true, le ref et les inputs, et rend le run" do
      routes = [
        {"/dispatches",
         json(200, %{
           "workflow_run_id" => 4242,
           "run_url" => "http://fake.test/api/v1/repos/fleet/p/actions/runs/4242",
           "html_url" => "http://fake.test/fleet/p/actions/runs/4242"
         })}
      ]

      # Garder les URL dans la fixture prouve leur exclusion du résultat : l'hôte de réponse
      # peut être interne au conteneur et inutilisable par un navigateur.
      assert {:ok, run_ref} =
               Actions.dispatch_workflow(
                 "fleet/p",
                 "probe-test-relevance.yml",
                 "refs/heads/main",
                 %{"target" => "hello.py"},
                 opts(routes)
               )

      assert run_ref == %{run_id: 4242}

      assert_received {:req, "POST", path, query, body}

      # L'endpoint attend le nom de fichier du workflow, pas son nom d'affichage.
      assert path == "/api/v1/repos/fleet/p/actions/workflows/probe-test-relevance.yml/dispatches"

      # Demander l'id au dispatch évite une recherche ambiguë entre runs concurrents sur la même tête.
      assert query == "return_run_details=true"

      assert JSON.decode!(body) == %{
               "ref" => "refs/heads/main",
               "inputs" => %{"target" => "hello.py"}
             }
    end

    test "2xx SANS détails de run → erreur, PAS un succès (le runner tourne, personne ne peut le lire)" do
      # Succès HTTP sans id exploitable : le dispatch a pu avoir lieu, mais reste non traçable.
      # La réponse simulée ne prouve pas qu'un runner ait commencé à travailler.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:dispatch_untrackable, "probe-test-relevance.yml"}} =
                   Actions.dispatch_workflow(
                     "fleet/p",
                     "probe-test-relevance.yml",
                     "main",
                     %{},
                     opts([{"/dispatches", json(204, %{})}])
                   )
        end)

      # L'erreur doit signaler le dispatch potentiellement effectué avant toute décision de retry.
      assert log =~ "[error]"
      assert log =~ "NO run details"
    end

    test "un VRAI 204 (corps vide, pas de JSON) prend le même chemin" do
      # Le cas précédent utilise {} ; un corps vide doit aussi être traité sans exiger une map.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:dispatch_untrackable, "probe-test-relevance.yml"}} =
                   Actions.dispatch_workflow(
                     "fleet/p",
                     "probe-test-relevance.yml",
                     "main",
                     %{},
                     opts([{"/dispatches", text(204, "")}])
                   )
        end)

      assert log =~ "NO run details"
    end

    test "input non-chaîne : refusé AVANT le fil — la forge n'est jamais appelée" do
      # L'absence de requête distingue un refus local d'un refus après effet de bord.
      drain()

      assert {:error, {:input_not_a_string, "rounds", 3}} =
               Actions.dispatch_workflow(
                 "fleet/p",
                 "probe.yml",
                 "main",
                 %{"rounds" => 3},
                 opts([])
               )

      refute_received {:req, _, _, _, _}
    end
  end

  describe "runs_for_sha/4 — la forge détient le registre, le rail ne tient aucun état" do
    test "head_sha part en filtre, les filtres s'ajoutent, l'enveloppe est déballée" do
      routes = [
        {"/actions/runs",
         json(200, %{
           "total_count" => 1,
           "workflow_runs" => [%{"id" => 7, "event" => "workflow_dispatch"}]
         })}
      ]

      assert {:ok, [%{"id" => 7}]} =
               Actions.runs_for_sha(
                 "fleet/p",
                 "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                 [event: "workflow_dispatch"],
                 opts(routes)
               )

      assert_received {:req, "GET", "/api/v1/repos/fleet/p/actions/runs", query, _}
      assert query =~ "head_sha=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
      assert query =~ "event=workflow_dispatch"
    end

    test "un tableau NU est refusé — accepter deux formes masquerait le jour où l'enveloppe bouge" do
      # Une forme inconnue doit rester distincte de « aucun run ». Le code exige workflow_runs
      # en liste ; total_count est seulement utilisé pour avertir d'une page partielle.
      assert {:error, {:unexpected_runs_shape, _}} =
               Actions.runs_for_sha(
                 "fleet/p",
                 "abc",
                 [],
                 opts([{"/actions/runs", json(200, [])}])
               )
    end

    test "probed?/3 — un dispatch MANUEL d'un autre workflow ne compte pas comme une sonde" do
      # workflow_dispatch inclut les actions manuelles : il faut aussi reconnaître le chemin.
      # Le prédicat actuel cherche seulement la sous-chaîne probe-, sans vérifier qui a lancé
      # le run ni son résultat ; ces fixtures distinguent ci.yml du chemin de sonde attendu.
      autre = [
        {"/actions/runs",
         json(200, %{
           "total_count" => 1,
           "workflow_runs" => [%{"id" => 3, "path" => ".gitea/workflows/ci.yml"}]
         })}
      ]

      assert {:ok, false} = Actions.probed?("fleet/p", "abc", opts(autre))

      sonde = [
        {"/actions/runs",
         json(200, %{
           "total_count" => 1,
           "workflow_runs" => [
             %{"id" => 4, "path" => ".gitea/workflows/probe-test-relevance.yml"}
           ]
         })}
      ]

      assert {:ok, true} = Actions.probed?("fleet/p", "abc", opts(sonde))
    end

    test "probed?/3 — un run dont le chemin est ILLISIBLE ne compte pas" do
      sans = [
        {"/actions/runs", json(200, %{"total_count" => 1, "workflow_runs" => [%{"id" => 9}]})}
      ]

      assert {:ok, false} = Actions.probed?("fleet/p", "abc", opts(sans))
    end

    test "page partielle : la troncature est DITE (pas de plafond silencieux)" do
      routes = [
        {"/actions/runs", json(200, %{"total_count" => 30, "workflow_runs" => [%{"id" => 1}]})}
      ]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, [%{"id" => 1}]} = Actions.runs_for_sha("fleet/p", "abc", [], opts(routes))
        end)

      # La troncature est seulement loguée ; la valeur de retour ne distingue pas la page partielle.
      assert log =~ "PARTIAL page"
    end
  end

  describe "run_logs/3 — les logs d'un run n'existent pas, ceux de ses jobs oui" do
    test "descend par /runs/{id}/jobs puis /jobs/{job_id}/logs, et NON par /runs/{id}/logs" do
      routes = [
        {"/actions/runs/9/jobs",
         json(200, %{
           "total_count" => 2,
           "jobs" => [%{"id" => 11, "name" => "probe"}, %{"id" => 12, "name" => "report"}]
         })},
        {"/actions/jobs/11/logs", text(200, "ligne un\n")},
        {"/actions/jobs/12/logs", text(200, "ligne deux\n")}
      ]

      assert {:ok, out} = Actions.run_logs("fleet/p", 9, opts(routes))

      assert out =~ "ligne un"
      assert out =~ "ligne deux"
      assert out =~ "job probe (11)"

      paths =
        Stream.repeatedly(fn ->
          receive do
            {:req, _, p, _, _} -> p
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(&(&1 != nil))

      assert "/api/v1/repos/fleet/p/actions/runs/9/jobs" in paths
      assert "/api/v1/repos/fleet/p/actions/jobs/11/logs" in paths

      # Refuser le raccourci /runs/{id}/logs : le client doit lire les logs par job.
      refute "/api/v1/repos/fleet/p/actions/runs/9/logs" in paths
    end

    test "un job illisible ne coule pas la lecture : sa section le dit, les autres survivent" do
      routes = [
        {"/actions/runs/9/jobs",
         json(200, %{"jobs" => [%{"id" => 11, "name" => "ok"}, %{"id" => 12, "name" => "ko"}]})},
        {"/actions/jobs/11/logs", text(200, "je suis lisible")},
        {"/actions/jobs/12/logs", json(500, %{"message" => "boom"})}
      ]

      assert {:ok, out} = Actions.run_logs("fleet/p", 9, opts(routes))

      # Une erreur de lecture devient une section explicite, sans perdre les autres logs.
      assert out =~ "je suis lisible"
      assert out =~ "logs unreadable"
    end

    test "aucun job → {:ok, \"\"} : « le runner n'a pas encore pris » n'est pas un échec" do
      # Aucun job retourné ne suffit pas à diagnostiquer l'état du runner malgré le titre.
      routes = [{"/actions/runs/9/jobs", json(200, %{"total_count" => 0, "jobs" => []})}]
      assert {:ok, ""} = Actions.run_logs("fleet/p", 9, opts(routes))
    end
  end

  describe "run/3" do
    test "status et conclusion voyagent SÉPARÉMENT" do
      routes = [
        {"/actions/runs/9",
         json(200, %{"id" => 9, "status" => "running", "conclusion" => "", "head_sha" => "abc"})}
      ]

      assert {:ok, %{"status" => "running", "conclusion" => ""}} =
               Actions.run("fleet/p", 9, opts(routes))

      # Le retour conserve status et conclusion séparément ; ce test ne vérifie pas leur
      # interprétation par le rail de merge (« pas encore terminé » versus « échec »).
      assert_received {:req, "GET", "/api/v1/repos/fleet/p/actions/runs/9", _, _}
    end
  end
end
