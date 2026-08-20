defmodule Fleet.Forge.Client.ActionsTest do
  use ExUnit.Case, async: true

  alias Fleet.Forge.Client.Actions

  # LE STUB EST AU NIVEAU HTTP, ET C'EST LA CONDITION POUR QUE CES TESTS SERVENT A QUELQUE CHOSE.
  #
  # Ce que ce module ajoute n'est pas de la logique : c'est une CONNAISSANCE D'API — un paramètre de
  # requête sans lequel le run est introuvable, et un chemin de logs qui n'est pas celui qu'on
  # écrirait spontanément. Un stub au niveau fonction (« `dispatch_workflow` rend `{:ok, …}` »)
  # n'épinglerait rien de tout ça : il testerait que j'ai écrit ce que j'ai écrit.
  #
  # Donc on branche un `Plug` (même patron que `forge_client_ci_state_test`), et les assertions
  # portent sur L'URL ET LE CORPS qui partent réellement.
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

      # ⚠ LE RESULTAT NE PORTE QUE `run_id`, ET LE STUB REND POURTANT LES DEUX URL. C'est un refus,
      # pas un oubli : le contrat `forge.payload_fields_read` du dépôt inscrit que `html_url` n'a
      # AUCUN lecteur, parce qu'une URL rendue par la forge porte l'hôte qui a RÉPONDU — le
      # conteneur atteint `http://forge:3000` là où un navigateur atteint un port publié. Ce module
      # a été écrit en les lisant, le contrat l'a repris, et il avait raison.
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

      # Le nom du fichier de workflow EST la clé de l'endpoint — pas un nom d'affichage.
      assert path == "/api/v1/repos/fleet/p/actions/workflows/probe-test-relevance.yml/dispatches"

      # ⚠ L'ASSERTION QUI PORTE TOUT LE MODULE. Sans ce paramètre la forge rend 204, le run tourne
      # et personne ne peut le retrouver autrement qu'en listant et en devinant — avec une course
      # dès que deux juges sondent la même tête.
      assert query == "return_run_details=true"

      assert JSON.decode!(body) == %{
               "ref" => "refs/heads/main",
               "inputs" => %{"target" => "hello.py"}
             }
    end

    test "2xx SANS détails de run → erreur, PAS un succès (le runner tourne, personne ne peut le lire)" do
      # Une forge plus ancienne, ou un proxy qui mange la query : la requête PASSE, le run DÉMARRE,
      # et le corps est vide. C'est le cas où un `:ok` serait un mensonge opérationnel — il
      # annoncerait une mesure que rien ne pourra jamais collecter.
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

      # Bruyant, parce que l'effet de bord a EU LIEU : un `{:error, _}` silencieux laisserait croire
      # que rien n'a été déclenché.
      assert log =~ "[error]"
      assert log =~ "NO run details"
    end

    test "un VRAI 204 (corps vide, pas de JSON) prend le même chemin" do
      # ⚠ LE STUB CI-DESSUS ENVOIE `{}`, ET UN VRAI 204 N'A PAS DE CORPS. La branche exercée est la
      # même aujourd'hui — `""` comme `%{}` tombent dans le catch-all — mais rien ne le prouvait :
      # quelqu'un resserrant la clause sur les maps aurait laissé ce test vert pendant que la vraie
      # réponse de la forge cassait. Signalé en relecture, épinglé ici.
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
      # La forge répondrait 422 en nommant son schéma, pas la clé fautive. Refuser ici nomme
      # l'erreur réelle. Et le contre-test est l'absence de requête : sans lui, un refus posé APRÈS
      # l'appel passerait pour un refus posé avant.
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
      # Le contrat déclare `ActionWorkflowRunsResponse` (`{total_count, workflow_runs}`). Un repli
      # complaisant sur un tableau nu rendrait `[]` le jour où la clé change, et « aucun run » est
      # exactement la réponse que cette fonction ne doit jamais inventer.
      assert {:error, {:unexpected_runs_shape, _}} =
               Actions.runs_for_sha(
                 "fleet/p",
                 "abc",
                 [],
                 opts([{"/actions/runs", json(200, [])}])
               )
    end

    test "page partielle : la troncature est DITE (pas de plafond silencieux)" do
      routes = [
        {"/actions/runs", json(200, %{"total_count" => 30, "workflow_runs" => [%{"id" => 1}]})}
      ]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, [%{"id" => 1}]} = Actions.runs_for_sha("fleet/p", "abc", [], opts(routes))
        end)

      # Un run au-delà de la page se lit comme un run ABSENT. Le fait est le même, la conclusion
      # est opposée — donc on le dit.
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

      # ⚠ LE PIÈGE, ÉPINGLÉ PAR LA NÉGATIVE. `/runs/{id}/logs` n'est pas dans le contrat de la
      # forge — il rend 404, et un appelant lit ce 404 comme « pas de logs », ce qui est un AUTRE
      # fait que « les logs sont un étage plus bas ».
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

      # Un log partiel qui nomme son trou vaut mieux qu'une erreur qui jette les jobs ayant répondu.
      assert out =~ "je suis lisible"
      assert out =~ "logs unreadable"
    end

    test "aucun job → {:ok, \"\"} : « le runner n'a pas encore pris » n'est pas un échec" do
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

      # Les deux champs ne se replient pas l'un sur l'autre : un run inachevé n'a PAS de conclusion,
      # et un lecteur qui ne regarde que `conclusion` confond « pas encore » avec « pas bon ». C'est
      # la confusion exacte que le rail de merge a payée sur le 405 de Gitea (doc 16).
      assert_received {:req, "GET", "/api/v1/repos/fleet/p/actions/runs/9", _, _}
    end
  end
end
