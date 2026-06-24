defmodule Fleet.API.Rest do
  @moduledoc """
  Plug.Router HTTP `:8080` endpoints REST.

  ## Routes MVP

    * `GET /api/health` — readiness probe (200 dès Cowboy bind ; consommé par `lcars-readiness`)
    * `GET /api/readiness/deep` — état opérationnel LIVE via
      `Fleet.API.Readiness.deep/0` — anti-vert-creux
    * `GET /api/pipelines` / `tickets` / `pods` — lecture état (stubs MVP)
    * `POST /api/admin/spawn` — valide le cap-profile (400 si absent, 422 si
      inconnu) PUIS broadcast `admin.spawn.request` event + 202
    * `POST /api/config/update` — atomic write + git commit auto via
      `GitCommitter` (canon trace strate 1)

  ## Auth — AUCUNE (par design ; frontière = réseau/container)

  Pas d'auth applicative. Le HMAC `X-Auth-Token` (bearer statique sur la constante
  `"fleet-api-v1"` — pas une signature de requête) a été RETIRÉ :
  intra-container non-exposé = zéro surface, et une auth bricolée donne un faux sentiment
  de sécurité (pire que rien). **La frontière est l'isolation réseau** : ne PAS publier
  `:8080` hors du container (bind loopback / `docker exec`) ; tunnel (WireGuard/Tailscale)
  pour un accès distant. Threat-model assumé = LAN / humains de confiance.
  """

  use Plug.Router

  alias Fleet.API.GitCommitter
  alias Fleet.EventRouter.Bus

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  # Public health probe (200 dès Cowboy bind, consommé par `lcars-readiness`)
  get "/api/health" do
    send_json(conn, %{status: "ok", ts: DateTime.utc_now() |> DateTime.to_iso8601()})
  end

  # Readiness deep : état opérationnel LIVE (anti-vert-creux). Vue de câblage
  # interne (pas un probe public comme /api/health). 200 même si `status: degraded`
  # — la dégradation est une donnée, pas une erreur HTTP.
  get "/api/readiness/deep" do
    send_json(conn, Fleet.API.Readiness.deep())
  end

  get "/api/pipelines" do
    send_json(conn, %{pipelines: []})
  end

  get "/api/tickets" do
    send_json(conn, %{tickets: []})
  end

  get "/api/pods" do
    send_json(conn, %{pods: []})
  end

  post "/api/admin/spawn" do
    # Chokepoint « nouveau pod opérateur » : refusé pendant un drain de
    # shutdown (Fleet.Shutdown.Quiesce). 503 = indisponible temporairement.
    # REST est l'UNIQUE producteur de l'event `admin.spawn.request` (vérifié) —
    # gater ici couvre donc intégralement l'admission de pods top-level.
    if Fleet.Shutdown.Quiesce.quiescing?() do
      send_resp(conn, 503, ~s|{"error":"quiescing — shutdown drain in progress"}|)
    else
      do_admin_spawn(conn)
    end
  end

  defp do_admin_spawn(conn) do
    payload = conn.body_params || %{}

    # VALIDER le cap-profile AVANT l'ACK. Si le 202 partait dès le broadcast, un
    # `cap_profile_name` inexistant ne serait détecté QUE plus tard dans `PublishConsumer`, où
    # `CapProfile.load` KO = un simple warning, ZÉRO pod spawné. L'appelant (`lcars spawn <rôle>`)
    # verrait « mis en file (202) » pour un rôle qui ne produira jamais de pod → 202 menteur. Le
    # contrat HTTP doit être honnête : le cap-profile fait partie de l'admission, pas d'un best-effort
    # async. On le résout ICI (même loader que le consumer, source unique `Fleet.CapProfile.load/1`).
    case validate_cap_profile(payload) do
      :ok ->
        do_broadcast_spawn(conn, payload)

      {:error, :missing} ->
        send_resp(
          conn,
          400,
          ~s|{"error":"cap_profile_name (ou role) requis"}|
        )

      {:error, {:cap_profile, name, reason}} ->
        # 422 Unprocessable — la requête est bien formée mais le cap-profile nommé n'est pas chargeable
        # (absent / schema invalide) → AUCUN pod ne peut naître. Plus de 202 qui ment.
        send_resp(
          conn,
          422,
          Jason.encode!(%{error: "cap_profile inconnu : #{name}", reason: inspect(reason)})
        )
    end
  end

  # Résout le cap-profile demandé (`cap_profile_name` ou `role`, mêmes clés que
  # `PublishConsumer.handle_spawn_request`). Absent → `{:error, :missing}` (400) ; load KO →
  # `{:error, {:cap_profile, name, reason}}` (422) ; chargé → `:ok` (l'admission passe).
  defp validate_cap_profile(payload) do
    case Map.get(payload, "cap_profile_name") || Map.get(payload, "role") do
      name when is_binary(name) and name != "" ->
        case Fleet.CapProfile.load(name) do
          {:ok, _cap} -> :ok
          {:error, reason} -> {:error, {:cap_profile, name, reason}}
        end

      _ ->
        {:error, :missing}
    end
  end

  defp do_broadcast_spawn(conn, payload) do
    # Schéma canon %Fleet.Event{source: :api} (la struct, pas un map ad-hoc).
    event = %Fleet.Event{
      source: :api,
      type: :"admin.spawn.request",
      timestamp: DateTime.utc_now(),
      pod_id: nil,
      correlation_id: nil,
      payload: payload
    }

    case safe_broadcast(event) do
      :ok -> send_resp(conn, 202, ~s|{"status":"queued"}|)
      {:error, reason} -> send_resp(conn, 400, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  defp safe_broadcast(%Fleet.Event{} = event) do
    Bus.broadcast("fleet.events", event)
  rescue
    e in Fleet.Event.UnregisteredError -> {:error, e.message}
    e in [ArgumentError, FunctionClauseError] -> {:error, inspect(e)}
  end

  post "/api/config/update" do
    case conn.body_params do
      %{"file_path" => path, "content" => content} ->
        user_id = conn.assigns[:user_id] || "api-user"

        case GitCommitter.commit_config_change(path, content, user_id) do
          {:ok, sha} ->
            send_json(conn, %{commit_sha: sha})

          {:error, reason} ->
            send_resp(conn, 500, Jason.encode!(%{error: reason}))
        end

      _ ->
        send_resp(conn, 400, ~s|{"error":"missing file_path or content"}|)
    end
  end

  # Dashboard V2 Elixir natif. Mount Fleet.API.Dashboard sous
  # /dashboard (UI GET-only). Pas d'auth — comme toute l'API (cf. moduledoc § Auth).
  forward("/dashboard", to: Fleet.API.Dashboard)

  match _ do
    send_resp(conn, 404, ~s|{"error":"not found"}|)
  end

  defp send_json(conn, payload) do
    send_resp(conn, 200, Jason.encode!(payload))
  end
end
