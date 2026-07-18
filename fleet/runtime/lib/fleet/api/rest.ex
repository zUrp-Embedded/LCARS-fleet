defmodule Fleet.API.Rest do
  @moduledoc """
  Plug.Router HTTP REST endpoints (per-human port, laid down by bin/fleet_v2).

  ## MVP routes

    * `GET /api/health` — readiness probe (200 as soon as Cowboy binds)
    * `GET /api/version` — the deployed build stamp (`Fleet.API.BuildInfo`)
    * `GET /api/readiness/deep` — LIVE operational state via
      `Fleet.API.Readiness.deep/0` — anti-hollow-green
    * `GET /api/workflow_runs` / `issues` / `pods` — **501 not_implemented** (F-C118: honest 501,
      never a lying empty-200; the real observability is served by fleet_observation, deck :8091)

  `POST /api/admin/spawn` is served ELSEWHERE — `Fleet.API.ControlRouter`, on the local AF_UNIX
  control socket, not on this TCP surface (see § Auth). This router is READ-only.

  ## Auth — READ-only TCP surface; the write lives off the network

  This TCP listener serves READS only (health / version / readiness + the 501 trio). No
  application auth on reads: they are low-risk, and a bwrap pod reading them is at worst
  information disclosure. The reads bind loopback by default (`BindAddress`); remote access =
  tunnel / named opt-in (`LCARS_BIND_HOST`).

  The one WRITE — `POST /api/admin/spawn` — is NOT on this TCP surface. It lives on the
  local AF_UNIX control socket (`Fleet.API.ControlRouter`, `~/.lcars/run/api.sock`), served
  host-side to `bin/lcars`. RATIONALE (A-21): a pod runs under bwrap with `--share-net`, so it
  SHARES the host netns — its `127.0.0.1` is the host's, and it could reach a no-auth TCP admin
  endpoint and re-obtain the spawner capability the MCP tool-gating denies it (confused deputy).
  A UNIX socket closes that BY CONSTRUCTION (the socket file is outside the pod's mount namespace
  — `--tmpfs /home` masks `~/.lcars`), the SAME move the repo already made for the pod-facing MCP
  transport (HTTP-loopback → AF_UNIX, "the identity IS the channel"). No auth token to manage.
  (A static `X-Auth-Token` bearer would be false security — and the premise
  "unexposed intra-container = zero surface" is itself false for a pod
  on the shared netns; the fix is to take the door off the network, not to bolt auth onto it.)

  **No config writing**: an active directive (cap-profiles, coord-policies,
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

  # F-C118 — an empty-200 on these 3 state reads would be a stub: a `{pods: []}` in 200 is
  # INDISTINGUISHABLE from "no pods" — a false success on a PUBLIC surface. The real observability
  # (live pods + event projection) is served by fleet_observation (`/api/pods`, `/api/projection`,
  # deck :8091). Here: an honest 501 (not implemented on THIS surface), never a lying emptiness.
  # We do NOT wire the reads here (that would duplicate fleet_observation = 2 SSoT) and we do not
  # remove the routes either (public contract — decision reserved): we just do not lie.
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

  # `POST /api/admin/spawn` is NOT served here: the one WRITE door lives OFF TCP on the
  # local AF_UNIX control socket (`Fleet.API.ControlRouter`), so a pod on the shared host netns
  # cannot reach it (A-21). This TCP surface is READ-ONLY. A stray POST here falls through to
  # the 404 below — honest, not a silent accept.

  match _ do
    send_resp(conn, 404, ~s|{"error":"not found"}|)
  end

  # Parameterizable status (200 default) — inline send_resp+encode calls would diverge.
  defp send_json(conn, payload), do: send_json(conn, 200, payload)
  defp send_json(conn, status, payload), do: send_resp(conn, status, Jason.encode!(payload))

  # F-C118 — explicit 501: the state read is NOT served here (public surface); the real
  # observability lives in fleet_observation. Honest — never an empty-200 posing as a state.
  defp not_implemented(conn, what) do
    send_json(conn, 501, %{
      error: "not_implemented",
      detail: "#{what} state-read is served by fleet_observation (deck :8091), not fleet_api"
    })
  end
end
