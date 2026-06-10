defmodule Fleet.Observation.Deck do
  @moduledoc """
  Plug.Router de l'observation deck `:8091` (squelette BL-026, incrément B).

  ## Routes

    * `GET /` — shell LCARS : header BRIDGE (LED santé + horloge) + les 7 decks
      (PODS live, les autres en attente du read-model — incrément C).
    * `GET /health` — sonde de vivacité du deck.
    * `GET /api/pods` — JSON des pods vivants (`Fleet.Spawner.list_pods/0`,
      projetés en vue JSON-safe). Lecture seule, no-auth, intra-release.
    * `GET /static/*` — assets (`priv/static/lcars-tva.css`, `assets/*.svg`).

  ## Frontière (BL-026)

  Squelette : `/api/pods` lit `Fleet.Spawner.list_pods/0` (Ring 1 read direct).
  L'incrément C interpose `Fleet.Observation.ReadModel` (projection du stream
  `%Fleet.Event{}` + snapshot boot) ; le deck lira **la projection**, jamais
  l'état GenServer interne. cf. `DESIGN-observabilite.md`.
  """

  use Plug.Router

  # Rôles connus → icône SVG (priv/static/assets). starfleet exclu de l'affichage
  # (non-négo #2 : l'asset existe mais aucun panel starfleet).
  @known_roles ~w(architect consultant engineer gatekeeper qualifier reviewer vulcan)

  plug(Plug.Static,
    at: "/static",
    from: {:fleet_observation, "priv/static"},
    gzip: false,
    only: ~w(lcars-tva.css assets)
  )

  plug(:match)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page())
  end

  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok", deck: "fleet_observation", port: 8091}))
  end

  get "/api/pods" do
    pods = Fleet.Spawner.list_pods() |> Enum.map(&pod_view/1)
    body = Jason.encode!(%{pods: pods, count: length(pods)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "deck route not found"}))
  end

  # Vue JSON-safe d'un pod : sous-ensemble du `:info`. Le runtime peut mettre
  # des termes non-encodables (`last_error`/`last_result`) → exclus. `phase`
  # (atom) + listes/strings/nil s'encodent. `role` ajouté pour l'icône.
  defp pod_view(info) do
    %{
      pod_id: info.pod_id,
      role: role_of(info),
      ticket_id: Map.get(info, :ticket_id),
      phase: info.phase,
      conditions: Map.get(info, :conditions, []),
      session_id: Map.get(info, :session_id),
      tmux_session: Map.get(info, :tmux_session)
    }
  end

  # Le rôle peut vivre sous `:role` ou dans la métadonnée cap-profile. On reste
  # défensif : rôle inconnu → nil (le client affiche l'icône générique).
  defp role_of(info) do
    role = Map.get(info, :role) || get_in(info, [:cap_profile, "metadata", "name"])
    if is_binary(role) and role in @known_roles, do: role, else: nil
  end

  defp page do
    """
    <!DOCTYPE html>
    <html lang="fr">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>LCARS // OBSERVATION DECK :8091</title>
    <link rel="icon" href="/static/assets/favicon.svg">
    <link rel="stylesheet" href="/static/lcars-tva.css">
    <style>
      .obs-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:10px}
      .pod-card{border:1px solid #335;border-radius:4px;padding:8px;background:#0a0a14}
      .pod-card .pc-head{display:flex;align-items:center;gap:8px;margin-bottom:4px}
      .pod-card .pc-icon{width:22px;height:22px}
      .pod-card .pc-id{color:#f93;font-weight:bold;font-family:monospace}
      .pod-card .pc-row{font-family:monospace;font-size:12px;color:#9af;display:flex;gap:6px}
      .pod-card .pc-k{color:#668;width:80px;display:inline-block}
      .deck-soon{color:#668;font-family:monospace;font-size:12px;padding:8px}
      .led-ok{background:#3f3 !important}
      .glyph{font-weight:bold}
    </style>
    </head>
    <body>
    <div class="crt-overlay"></div>
    <div class="lcars-frame">
      <header class="lcars-header">
        <div class="bezel bezel-left"></div>
        <div class="head-strip">
          <span class="head-title">LCARS // OBSERVATION</span>
          <span class="head-sub">DECK :8091 — CORE REMÉDIÉ</span>
        </div>
        <div class="head-status">
          <span class="status-led" id="led-health"></span>
          <span class="head-clock" id="clock">--:--:--</span>
        </div>
        <div class="bezel bezel-right"></div>
      </header>

      <main class="lcars-main">
        #{deck("B1", "BRIDGE", soon("readiness deep · quiescence · débit events"))}
        #{deck("P1", "PODS", ~s|<div class="obs-grid" id="pods-grid"><div class="deck-soon">chargement…</div></div><div class="panel-meta" id="pods-count">— … —</div>|)}
        #{deck("F1", "FLOW", soon("mandats (pending/active/done/failed) · pipelines par état"))}
        #{deck("G1", "GATEKEEPER", soon("escalades Z3-B · verdicts · gate_evals"))}
        #{deck("C1", "COORDINATION", soon("routes Pilot · policies coord · MCP config"))}
        #{deck("S1", "STREAM", soon("tail live %Fleet.Event{} · critiques surlignés"))}
        #{deck("D1", "DIAGNOSTICS", soon("not_wired_yet · boot state · quota OAUTH"))}
      </main>

      <footer class="lcars-footer">
        <span class="footer-meta">fleet_observation • BL-026 read-frontier • incrément B (squelette) • PODS live, autres → read-model C</span>
      </footer>
    </div>

    <script>
    function tick(){var d=new Date();document.getElementById('clock').textContent=d.toTimeString().slice(0,8);}
    function esc(s){return (s==null?'':String(s)).replace(/[&<>]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;'}[c];});}
    function podCard(p){
      var icon = p.role ? '/static/assets/'+esc(p.role)+'.svg' : '/static/assets/favicon-minimal.svg';
      return '<div class="pod-card">'
        + '<div class="pc-head"><img class="pc-icon" src="'+icon+'" alt=""><span class="pc-id">'+esc(p.pod_id)+'</span></div>'
        + '<div class="pc-row"><span class="pc-k">phase</span><span class="glyph">'+esc(p.phase)+'</span></div>'
        + '<div class="pc-row"><span class="pc-k">ticket</span>'+esc(p.ticket_id)+'</div>'
        + '<div class="pc-row"><span class="pc-k">conditions</span>'+esc((p.conditions||[]).join(', '))+'</div>'
        + '<div class="pc-row"><span class="pc-k">tmux</span>'+esc(p.tmux_session)+'</div>'
        + '</div>';
    }
    async function refresh(){
      var led=document.getElementById('led-health');
      try{
        var r=await fetch('/api/pods');var j=await r.json();
        led.classList.add('led-ok');
        document.getElementById('pods-count').textContent='— '+j.count+' actifs —';
        var g=document.getElementById('pods-grid');
        g.innerHTML = j.pods.length ? j.pods.map(podCard).join('') : '<div class="deck-soon">aucun pod actif</div>';
      }catch(e){led.classList.remove('led-ok');}
    }
    tick();setInterval(tick,1000);refresh();setInterval(refresh,3000);
    </script>
    </body>
    </html>
    """
  end

  # Un deck = une section panel LCARS.
  defp deck(num, name, body) do
    ~s|<section class="panel"><div class="panel-head"><span class="panel-num">#{num}</span><span class="panel-name">#{name}</span></div><div class="panel-body">#{body}</div></section>|
  end

  defp soon(what),
    do: ~s|<div class="deck-soon">— en attente du read-model (incrément C) : #{what} —</div>|
end
