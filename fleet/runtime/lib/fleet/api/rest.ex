defmodule Fleet.API.Rest do
  @moduledoc """
  Plug.Router HTTP REST endpoints (per-human port, laid down by bin/fleet_v2).

  ## MVP routes

    * `GET /api/health` — readiness probe (200 as soon as Cowboy binds)
    * `GET /api/version` — the deployed build stamp (`Fleet.API.BuildInfo`)
    * `GET /api/readiness/deep` — LIVE operational state via
      `Fleet.API.Readiness.deep/0` — anti-hollow-green
    * `GET /api/workflow_runs` / `issues` / `pods` — **501 not_implemented** (F-C118 : ex-empty-200
      menteurs ; l'observabilité réelle est servie par fleet_observation, deck :8091)

  `POST /api/admin/spawn` is served ELSEWHERE — `Fleet.API.ControlRouter`, on the local AF_UNIX
  control socket, not on this TCP surface (see § Auth). This router is READ-only.

  ## Auth — READ-only TCP surface; the write moved off the network

  This TCP listener now serves READS only (health / version / readiness + the 501 trio). No
  application auth on reads: they are low-risk, and a bwrap pod reading them is at worst
  information disclosure. The reads bind loopback by default (`BindAddress`); remote access =
  tunnel / named opt-in (`LCARS_BIND_HOST`).

  The one WRITE — `POST /api/admin/spawn` — is NO LONGER on this TCP surface. It moved onto the
  local AF_UNIX control socket (`Fleet.API.ControlRouter`, `~/.lcars/run/api.sock`), served
  host-side to `bin/lcars`. RATIONALE (A-21): a pod runs under bwrap with `--share-net`, so it
  SHARES the host netns — its `127.0.0.1` is the host's, and it could reach a no-auth TCP admin
  endpoint and re-obtain the spawner capability the MCP tool-gating denies it (confused deputy).
  A UNIX socket closes that BY CONSTRUCTION (the socket file is outside the pod's mount namespace
  — `--tmpfs /home` masks `~/.lcars`), the SAME move the repo already made for the pod-facing MCP
  transport (HTTP-loopback → AF_UNIX, "the identity IS the channel"). No auth token to manage.
  (The historical `X-Auth-Token` static bearer was rightly removed as false security — but the
  premise that removed it, "unexposed intra-container = zero surface", was itself false for a pod
  on the shared netns; the fix is to take the door off the network, not to bolt auth onto it.)

  **Config writing was removed**: an active directive (cap-profiles, coord-policies,
  workflow_maps) is only modified via git/forge (the traced source of truth), never via a POST.

  **Last revised**: 2026-07-18
  """

  use Plug.Router

  plug(:match)
  # length (E4): EXPLICIT body bound (the Plug 8MB default was implicit). 1 MB >> the biggest
  # legitimate POST (admin/spawn: cap-profile + brief).
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, length: 1_048_576)
  plug(:dispatch)

  # Public health probe (200 as soon as Cowboy binds)
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

  # `POST /api/admin/spawn` is NO LONGER served here: the one WRITE door moved OFF TCP onto the
  # local AF_UNIX control socket (`Fleet.API.ControlRouter`), so a pod on the shared host netns
  # cannot reach it (A-21). This TCP surface is now READ-ONLY. A stray POST here falls through to
  # the 404 below — honest, not a silent accept.

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
