defmodule Fleet.API.Dashboard do
  @moduledoc """
  Native Elixir V2 dashboard Plug.Router.

  Chosen path (native intra-release, no external Python proxy):
  - Path B (Plug+Cowboy+EEx) — `plug 1.19` + `plug_cowboy 2.8` already deps
  - No Python proxy (`dashboard-server.py` v1.5 decommissioned)
  - Direct GenServers/Registry/PubSub intra-release access (reads state via direct module calls, without network nor auth)
  - LCARS aesthetic preserved (clean-room CSS copy, attribution
    `starfleet#1` + `starfleet#2`)

  ## Routes

    * `GET /dashboard` — renders EEx layout `priv/dashboard/index.html.eex`
      (LCARS header + nav rail + main grid panel placeholders)
    * `GET /dashboard/static/*` — serves `priv/dashboard/static/` via
      `Plug.Static` (lcars-tva.css, future panel JS/images)

  ## Auth

  No HTTP auth — the intra-release dashboard accesses the GenServers/PubSub
  directly. The whole API is no-auth by design (boundary =
  container network isolation, cf. `Fleet.API.Rest` § Auth).

  ## State

  HTML + CSS + route skeleton in place. The panels (data sources,
  MEMORY-X, build status, coordination, OAUTH quota) remain to be
  filled in.
  """

  use Plug.Router
  require EEx

  # Template compiled ONCE at build (no `EEx.eval_file` per request =
  # re-read+recompilation on every hit, nor a runtime 500 on a missing template on an UN-
  # authenticated route). `function_from_file` generates `render_dashboard/1` at build; a missing template
  # breaks the BUILD (detected early), not a 500. `@external_resource` → recompiles if the `.eex` changes.
  @dashboard_template Path.expand("../../../priv/dashboard/index.html.eex", __DIR__)
  @external_resource @dashboard_template
  EEx.function_from_file(:defp, :render_dashboard, @dashboard_template, [:assigns])

  # Static assets under /dashboard/static (served from priv/dashboard/static).
  # `at:` = URL prefix after the parent mount point. The `/dashboard` forward
  # in rest.ex consumes the `/dashboard` prefix, so here we see `/static/*`.
  plug(Plug.Static,
    at: "/static",
    from: {:fleet_api, "priv/dashboard/static"},
    gzip: false,
    only: ~w(lcars-tva.css favicon.ico)
  )

  plug(:match)
  plug(:dispatch)

  # GET /dashboard (the forward consumes the prefix, we see "/" here)
  get "/" do
    body = render_dashboard(%{title: "LCARS // V2 MAINFRAME"})

    conn
    |> put_resp_content_type("text/html; charset=utf-8")
    |> send_resp(200, body)
  end

  match _ do
    send_resp(conn, 404, ~s|{"error":"dashboard route not found"}|)
  end

  # Helpers

  @doc false
  def template_path do
    Path.join(:code.priv_dir(:fleet_api) |> to_string(), "dashboard/index.html.eex")
  end
end
