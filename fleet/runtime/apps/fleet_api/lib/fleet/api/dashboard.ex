defmodule Fleet.Api.Dashboard do
  @moduledoc """
  Plug.Router dashboard V2 Elixir natif (chantier #594 D2).

  Per `work/beyond_#4/03_plan/plan-dashboard.md` ruling user 2026-05-20 :
  - Voie B (Plug+Cowboy+EEx) — `plug 1.19` + `plug_cowboy 2.8` déjà deps
  - Pas de proxy Python (`dashboard-server.py` v1.5 décommissionné D9)
  - Accès direct GenServers/Registry/PubSub intra-release (ADR-C 5-zéros)
  - Esthétique LCARS conservée (clean-room copy CSS, attribution
    `starfleet#1` + `starfleet#2`)

  ## Routes

    * `GET /dashboard` — render EEx layout `priv/dashboard/index.html.eex`
      (header LCARS + rail nav + main grid panels D3-D7 placeholders)
    * `GET /dashboard/static/*` — sert `priv/dashboard/static/` via
      `Plug.Static` (lcars-tva.css, futurs JS/images D3-D7)

  ## Auth

  Pas d'auth HTTP — dashboard intra-release accède aux GenServers/PubSub
  directement (ADR-C). Le `require_auth` plug de `Fleet.Api.Rest`
  whitelist `/dashboard*` (GET-only, no mutation).

  ## Sous-tickets

  D2 = squelette HTML + CSS + route. Sub-tickets dual-review D3-D7
  rempliront les panels (data sources, MEMORY-X, build status,
  coordination, OAUTH quota).
  """

  use Plug.Router

  # Static assets sous /dashboard/static (servis depuis priv/dashboard/static).
  # `at:` = URL prefix après le mount point parent. Le forward `/dashboard`
  # dans rest.ex consomme `/dashboard` prefix, donc ici on voit `/static/*`.
  plug(Plug.Static,
    at: "/static",
    from: {:fleet_api, "priv/dashboard/static"},
    gzip: false,
    only: ~w(lcars-tva.css favicon.ico)
  )

  plug(:match)
  plug(:dispatch)

  # GET /dashboard (forward consomme le prefix, on voit "/" ici)
  get "/" do
    template_path = template_path()
    body = EEx.eval_file(template_path, assigns: %{title: "LCARS // V2 MAINFRAME"})

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
