defmodule Fleet.API.Rest do
  @moduledoc """
  Plug.Router HTTP endpoints REST (port per-humain, posé par bin/fleet_v2).

  ## Routes MVP

    * `GET /api/health` — readiness probe (200 dès Cowboy bind ; consommé par `lcars-readiness`)
    * `GET /api/readiness/deep` — état opérationnel LIVE via
      `Fleet.API.Readiness.deep/0` — anti-vert-creux
    * `GET /api/workflow_runs` / `issues` / `pods` — lecture état (stubs MVP)
    * `POST /api/admin/spawn` — filtre le payload par allowlist DTO (422 si un champ interne du
      spawner / une clé inconnue est présent), valide le cap-profile (400 si absent, 422 si
      inconnu / host-native), exige un `brief` pour un cap-profile one-shot (422 sinon — miroir
      R18, évite le 202 menteur) PUIS broadcast `admin.spawn.request` event + 202. Toute la
      policy d'admission vit dans `Fleet.API.SpawnAdmission` ; ce routeur mappe les verdicts
      en statuts HTTP

  ## Auth — lecture no-auth, écriture gardée (pas de blanket no-auth)

  Pas d'auth applicative *pour la lecture*. Le HMAC `X-Auth-Token` (bearer statique sur la
  constante `"fleet-api-v1"` — pas une signature de requête) a été RETIRÉ : intra-container
  non-exposé = zéro surface, et une auth bricolée donne un faux sentiment de sécurité (pire
  que rien). **La frontière est l'isolation réseau** : ne PAS publier le port API hors du
  container (bind loopback / `docker exec`) ; tunnel (WireGuard/Tailscale) pour un accès
  distant. Threat-model assumé = LAN / humains de confiance.

  La lecture (dashboard GET, observation) reste no-auth — légitime, inchangé. **L'écriture de
  config a été retirée** : il n'existe plus de porte d'écriture générique sur le repo de config.
  Une directive active (cap-profiles, coord-policies, workflow_maps) ne se modifie QUE par git/forge
  (la source de vérité tracée), jamais par un POST no-auth. La SEULE écriture restante est
  `POST /api/admin/spawn`, qui n'est PAS couverte par un blanket no-auth : elle garde ses gardes
  propres (allowlist DTO + host-native refusé à l'admission).
  """

  use Plug.Router

  plug(:match)
  # length (E4) : borne EXPLICITE du body (le defaut Plug 8MB etait implicite). 1 MB >> le plus
  # gros POST legitime (admin/spawn : cap-profile + brief).
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, length: 1_048_576)
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

  get "/api/workflow_runs" do
    send_json(conn, %{workflow_runs: []})
  end

  get "/api/issues" do
    send_json(conn, %{issues: []})
  end

  get "/api/pods" do
    send_json(conn, %{pods: []})
  end

  # Version du build servi — SHA git court + dirty + ref + source (cf.
  # `Fleet.API.BuildInfo`). Rend la version CONSTATABLE (e2e, debug) sans la
  # déduire. LECTURE → no-auth légitime, cohérent avec le § Auth ci-dessus.
  get "/api/version" do
    send_json(conn, Fleet.API.BuildInfo.current())
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

  # Mapping VERDICT D'ADMISSION → HTTP. Toute la POLICY (allowlist DTO, pod_id path-safe,
  # cap-profile chargeable, host-native refusé, brief one-shot R18) vit dans
  # `Fleet.API.SpawnAdmission.admit/1` (extraite C4 2026-07-05, le POURQUOI de chaque garde
  # y est documenté) ; ici on ne fait que traduire chaque refus en statut + corps JSON.
  # Un refus = RIEN n'a été broadcasté (l'admission précède l'émission par construction).
  defp do_admin_spawn(conn) do
    raw = conn.body_params || %{}

    case Fleet.API.SpawnAdmission.admit(raw) do
      {:ok, payload} ->
        do_broadcast_spawn(conn, payload)

      {:error, {:forbidden_fields, fields}} ->
        # 422 Unprocessable — la requête porte des champs non publics (opts internes du spawner /
        # seams / racines disque). Refusé à la frontière, le consumer ne les interprète jamais.
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "champs non autorisés sur /api/admin/spawn",
            forbidden: Enum.sort(fields)
          })
        )

      {:error, {:invalid_pod_id, value}} ->
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "pod_id invalide (attendu [A-Za-z0-9._-], sans '..')",
            value: inspect(value)
          })
        )

      {:error, :brief_required} ->
        # 422 — cap-profile one-shot sans `brief` : le spawner refuserait (R18), le 202 mentirait.
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "brief requis (cap-profile one-shot)",
            reason:
              "lifetime_scope one-shot sans `brief` : le pod partirait sans travail (R18). Fournir `brief`."
          })
        )

      {:error, :missing_cap_profile} ->
        # 400 Bad Request — le champ requis manque (requête incomplète, pas un contenu invalide).
        send_resp(
          conn,
          400,
          ~s|{"error":"cap_profile_name (ou role) requis"}|
        )

      {:error, {:cap_profile, name, reason}} ->
        # 422 — bien formée mais le cap-profile nommé n'est pas chargeable → AUCUN pod ne peut
        # naître. Plus de 202 qui ment.
        send_resp(
          conn,
          422,
          Jason.encode!(%{error: "cap_profile inconnu : #{name}", reason: inspect(reason)})
        )

      {:error, {:host_native_forbidden, name}} ->
        # 422 — cap-profile HOST-NATIVE (`containment: none`) : jamais atteignable par cette porte
        # spawn générique no-auth (voie dédiée hors-bande). Fail-closed par construction.
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "cap_profile host-native interdit via /api/admin/spawn : #{name}",
            reason:
              "containment != bwrap — le host-native passe par sa voie dédiée, pas l'API spawn"
          })
        )
    end
  end

  defp do_broadcast_spawn(conn, payload) do
    case Fleet.API.SpawnAdmission.broadcast(payload) do
      :ok -> send_resp(conn, 202, ~s|{"status":"queued"}|)
      {:error, reason} -> send_json(conn, 400, %{error: inspect(reason)})
    end
  end

  # Dashboard V2 Elixir natif. Mount Fleet.API.Dashboard sous
  # /dashboard (UI GET-only). Pas d'auth — comme toute l'API (cf. moduledoc § Auth).
  forward("/dashboard", to: Fleet.API.Dashboard)

  match _ do
    send_resp(conn, 404, ~s|{"error":"not found"}|)
  end

  # R6 : status paramétrable (200 défaut) — plus de send_resp+encode inline divergents.
  defp send_json(conn, payload), do: send_json(conn, 200, payload)
  defp send_json(conn, status, payload), do: send_resp(conn, status, Jason.encode!(payload))
end
