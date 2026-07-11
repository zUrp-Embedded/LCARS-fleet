defmodule Fleet.API.Rest do
  @moduledoc """
  Plug.Router HTTP REST endpoints (per-human port, laid down by bin/fleet_v2).

  ## MVP routes

    * `GET /api/health` — readiness probe (200 as soon as Cowboy binds; consumed by `lcars-readiness`)
    * `GET /api/version` — the deployed build stamp (`Fleet.API.BuildInfo`)
    * `GET /api/readiness/deep` — LIVE operational state via
      `Fleet.API.Readiness.deep/0` — anti-hollow-green
    * `GET /api/workflow_runs` / `issues` / `pods` — **501 not_implemented** (F-C118 : ex-empty-200
      menteurs ; l'observabilité réelle est servie par fleet_observation, deck :8091)
    * `POST /api/admin/spawn` — filters the payload by DTO allowlist (422 if an internal spawner
      field / an unknown key is present), validates the cap-profile (400 if absent, 422 if
      unknown / host-native), requires a `brief` for a one-shot cap-profile (422 otherwise — mirror
      of R18, avoids the lying 202) THEN broadcasts the `admin.spawn.request` event + 202. All the
      admission policy lives in `Fleet.API.SpawnAdmission`; this router maps the verdicts
      to HTTP statuses
    * `/dashboard` — forwarded to `Fleet.API.Dashboard` (the external web dashboard's entry)

  ## Auth — no-auth reads, guarded writes (not blanket no-auth)

  No application auth *for reads*. The `X-Auth-Token` HMAC (static bearer on the
  constant `"fleet-api-v1"` — not a request signature) was REMOVED: unexposed
  intra-container = zero surface, and a hand-rolled auth gives a false sense of security (worse
  than nothing). **The boundary is network isolation**: do NOT publish the API port outside the
  container (loopback bind / `docker exec`); tunnel (WireGuard/Tailscale) for remote
  access. Assumed threat-model = LAN / trusted humans.

  Reads (dashboard GET, observation) stay no-auth — legitimate, unchanged. **Config writing
  was removed**: there is no longer a generic write door onto the config repo.
  An active directive (cap-profiles, coord-policies, workflow_maps) is only modified via git/forge
  (the traced source of truth), never via a no-auth POST. The ONLY remaining write is
  `POST /api/admin/spawn`, which is NOT covered by a blanket no-auth: it keeps its own
  guards (DTO allowlist + host-native refused at admission).
  """

  use Plug.Router

  plug(:match)
  # length (E4): EXPLICIT body bound (the Plug 8MB default was implicit). 1 MB >> the biggest
  # legitimate POST (admin/spawn: cap-profile + brief).
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, length: 1_048_576)
  plug(:dispatch)

  # Public health probe (200 as soon as Cowboy binds, consumed by `lcars-readiness`)
  get "/api/health" do
    send_json(conn, %{status: "ok", ts: DateTime.utc_now() |> DateTime.to_iso8601()})
  end

  # Readiness deep: LIVE operational state (anti-hollow-green). Internal wiring
  # view (not a public probe like /api/health). 200 even if `status: degraded`
  # — degradation is data, not an HTTP error.
  get "/api/readiness/deep" do
    send_json(conn, Fleet.API.Readiness.deep())
  end

  # F-C118 — ces 3 lectures d'état étaient des empty-200 (MVP stubs) : un `{pods: []}` en 200 est
  # INDISTINGUABLE de « aucun pod » — un faux-succès sur surface PUBLIQUE. L'observabilité réelle (pods
  # live + projection événementielle) est servie par fleet_observation (`/api/pods`, `/api/projection`,
  # deck :8091). Ici : 501 honnête (not implemented sur CETTE surface) au lieu d'un vide menteur. On NE
  # câble PAS ici (ce serait doublonner fleet_observation = 2 SSoT), on ne supprime pas non plus (contrat
  # public — décision réservée) : on cesse juste de mentir.
  get "/api/workflow_runs" do
    not_implemented(conn, "workflow_runs")
  end

  get "/api/issues" do
    not_implemented(conn, "issues")
  end

  get "/api/pods" do
    not_implemented(conn, "pods")
  end

  # Version of the served build — short git SHA + dirty + ref + source (cf.
  # `Fleet.API.BuildInfo`). Makes the version OBSERVABLE (e2e, debug) without
  # deducing it. READ → legitimate no-auth, consistent with the § Auth above.
  get "/api/version" do
    send_json(conn, Fleet.API.BuildInfo.current())
  end

  post "/api/admin/spawn" do
    # "New operator pod" chokepoint: refused during a shutdown drain
    # (Fleet.Shutdown.Quiesce). 503 = temporarily unavailable.
    # REST is the ONLY producer of the `admin.spawn.request` event (verified) —
    # gating here therefore fully covers top-level pod admission.
    if Fleet.Shutdown.Quiesce.quiescing?() do
      send_resp(conn, 503, ~s|{"error":"quiescing — shutdown drain in progress"}|)
    else
      do_admin_spawn(conn)
    end
  end

  # ADMISSION VERDICT → HTTP mapping. All the POLICY (DTO allowlist, path-safe pod_id,
  # loadable cap-profile, host-native refused, one-shot brief R18) lives in
  # `Fleet.API.SpawnAdmission.admit/1` (extracted C4 2026-07-05, the WHY of each guard
  # is documented there); here we only translate each refusal into a status + JSON body.
  # A refusal = NOTHING was broadcast (admission precedes emission by construction).
  defp do_admin_spawn(conn) do
    raw = conn.body_params || %{}

    case Fleet.API.SpawnAdmission.admit(raw) do
      {:ok, payload} ->
        do_broadcast_spawn(conn, payload)

      {:error, {:forbidden_fields, fields}} ->
        # 422 Unprocessable — the request carries non-public fields (internal spawner opts /
        # seams / disk roots). Refused at the boundary, the consumer never interprets them.
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "unauthorized fields on /api/admin/spawn",
            forbidden: Enum.sort(fields)
          })
        )

      {:error, {:invalid_pod_id, value}} ->
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "invalid pod_id (expected [A-Za-z0-9._-], no '..')",
            value: inspect(value)
          })
        )

      {:error, {:invalid_issue_id, value}} ->
        # 422 — `issue_id` (optional forge/event correlation) was present but not a string. A raw
        # number/bool/list would be `to_string`-d downstream into the pod's correlation + logs.
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "invalid issue_id (expected a string)",
            value: inspect(value)
          })
        )

      {:error, :brief_required} ->
        # 422 — one-shot cap-profile without `brief`: the spawner would refuse (R18), the 202 would lie.
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "brief required (one-shot cap-profile)",
            reason:
              "one-shot lifetime_scope without `brief`: the pod would leave with no work (R18). Provide `brief`."
          })
        )

      {:error, :missing_cap_profile} ->
        # 400 Bad Request — the required field is missing (incomplete request, not invalid content).
        send_resp(
          conn,
          400,
          ~s|{"error":"cap_profile_name (or role) required"}|
        )

      {:error, {:cap_profile, name, reason}} ->
        # 422 — well-formed but the named cap-profile is not loadable → NO pod can
        # be born. No more lying 202.
        send_resp(
          conn,
          422,
          Jason.encode!(%{error: "unknown cap_profile: #{name}", reason: inspect(reason)})
        )

      {:error, {:host_native_forbidden, name}} ->
        # 422 — HOST-NATIVE cap-profile (`containment: none`): never reachable via this generic
        # no-auth spawn door (dedicated out-of-band path). Fail-closed by construction.
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "host-native cap_profile forbidden via /api/admin/spawn: #{name}",
            reason:
              "containment != bwrap — host-native goes through its dedicated path, not the spawn API"
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

  # Native Elixir V2 dashboard. Mounts Fleet.API.Dashboard under
  # /dashboard (GET-only UI). No auth — like the whole API (cf. moduledoc § Auth).
  forward("/dashboard", to: Fleet.API.Dashboard)

  match _ do
    send_resp(conn, 404, ~s|{"error":"not found"}|)
  end

  # R6: parameterizable status (200 default) — no more divergent inline send_resp+encode.
  defp send_json(conn, payload), do: send_json(conn, 200, payload)
  defp send_json(conn, status, payload), do: send_resp(conn, status, Jason.encode!(payload))

  # F-C118 — 501 explicite : la lecture d'état n'est PAS servie ici (surface publique) ; l'observabilité
  # réelle vit dans fleet_observation. Honnête, jamais un empty-200 qui se fait passer pour un état.
  defp not_implemented(conn, what) do
    send_json(conn, 501, %{
      error: "not_implemented",
      detail: "#{what} state-read is served by fleet_observation (deck :8091), not fleet_api"
    })
  end
end
