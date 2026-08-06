defmodule Fleet.API.Rest do
  @moduledoc """
  Read-only TCP API for health, build information and operational readiness.

  State reads not owned by this runtime return 501 (`F-C118`); their authority is
  `fleet_observation`. The admin spawn write exists only on
  `Fleet.API.ControlRouter`'s AF_UNIX socket because pods share the host network
  namespace but not that socket's mount namespace.
  """

  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, length: 1_048_576)
  plug(:dispatch)

  get "/api/health" do
    send_json(conn, %{status: "ok", ts: DateTime.utc_now() |> DateTime.to_iso8601()})
  end

  get "/api/readiness/deep" do
    send_json(conn, Fleet.API.Readiness.deep())
  end

  # F-C118
  get "/api/workflow_runs" do
    not_implemented(conn, "workflow_runs")
  end

  get "/api/issues" do
    not_implemented(conn, "issues")
  end

  get "/api/pods" do
    not_implemented(conn, "pods")
  end

  get "/api/version" do
    send_json(conn, Fleet.API.BuildInfo.current())
  end

  match _ do
    send_resp(conn, 404, ~s|{"error":"not found"}|)
  end

  defp send_json(conn, payload), do: send_json(conn, 200, payload)
  defp send_json(conn, status, payload), do: send_resp(conn, status, Jason.encode!(payload))

  defp not_implemented(conn, what) do
    send_json(conn, 501, %{
      error: "not_implemented",
      detail: "#{what} state-read is served by fleet_observation (deck :8091), not fleet_api"
    })
  end
end
