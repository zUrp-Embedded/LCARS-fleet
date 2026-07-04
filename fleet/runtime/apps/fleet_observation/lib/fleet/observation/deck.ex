defmodule Fleet.Observation.Deck do
  @moduledoc """
  Plug.Router de l'observation deck le port observation (per-humain).

  ## Routes

    * `GET /` — shell LCARS : header BRIDGE (LED santé + horloge) + les 7 decks
      (PODS live, les autres alimentés par la projection du read-model).
    * `GET /health` — sonde de vivacité du deck.
    * `GET /api/pods` — JSON des pods vivants (`Fleet.Spawner.list_pods/0`,
      projetés en vue JSON-safe). Lecture seule, no-auth, intra-release.
    * `GET /static/*` — assets (`priv/static/lcars-tva.css`, `assets/*.svg`).

  ## Frontière read

  `/api/pods` lit `Fleet.Spawner.list_pods/0` (Ring 1 read direct, snapshot live).
  `/api/projection` lit `Fleet.Observation.ReadModel` (projection du stream
  `%Fleet.Event{}`) ; le deck lit **la projection**, jamais
  l'état GenServer interne d'un tiers.
  """

  use Plug.Router

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

  # Tableau basique : un bloc fixe par rôle (`@dashboard_roles`), état du/des pod(s)
  # correspondant(s) rendu CÔTÉ SERVEUR (pas de JS). Auto-refresh par `<meta refresh>`.
  # Réutilise le même snapshot live que `/api/pods` (`Fleet.Spawner.list_pods/0`).
  get "/table" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, table_page())
  end

  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok", deck: "fleet_observation", port: Application.get_env(:fleet_observation, :http_port)}))
  end

  get "/api/pods" do
    known = display_roles()
    pods = Fleet.Spawner.list_pods() |> Enum.map(&pod_view(&1, known))
    body = Jason.encode!(%{pods: pods, count: length(pods)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # Projection event-dérivée (read-model) : alimente FLOW/GATEKEEPER/
  # STREAM/COORDINATION/DIAGNOSTICS/BRIDGE. Read ETS direct (bypass GenServer).
  get "/api/projection" do
    body = Jason.encode!(Fleet.Observation.ReadModel.projection())

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
  defp pod_view(info, known) do
    %{
      pod_id: info.pod_id,
      role: role_of(info, known),
      issue_id: Map.get(info, :issue_id),
      phase: info.phase,
      conditions: Map.get(info, :conditions, []),
      session_id: Map.get(info, :session_id),
      tmux_session: Map.get(info, :tmux_session)
    }
  end

  # Le rôle vit UNIQUEMENT sous `:role` (gravé au spawn = nom du cap-profile, la source unique). Hors
  # catalogue d'AFFICHAGE → nil : le client rend l'icône générique. Ce n'est PAS un masquage du pod
  # (le pod reste listé) ni une autorité de rôle runtime — juste le choix d'icône.
  defp role_of(info, known) do
    role = Map.get(info, :role)
    if is_binary(role) and role in known, do: role, else: nil
  end

  # Catalogue d'AFFICHAGE (rôle → icône SVG dédiée) DÉRIVÉ des assets réellement présents dans
  # `priv/static/assets` : tout `<role>.svg` déposé là est reconnu automatiquement → plus de liste codée
  # en dur à garder en sync avec les fichiers (la duplication liste↔assets disparaît, l'asset est l'autorité).
  # Exclusions : les `favicon*.svg` (chrome, pas un rôle) et `starfleet` (domaine système hors-bande,
  # l'asset existe mais aucun panel ne l'instrumente). `File.ls` KO (dir absent) → `[]` : dégradation sûre
  # (tous les pods en icône générique, jamais de crash). Résolu via `app_dir` = même priv que `Plug.Static`.
  defp display_roles do
    case File.ls(Application.app_dir(:fleet_observation, "priv/static/assets")) do
      {:ok, files} ->
        for f <- files,
            String.ends_with?(f, ".svg"),
            role = Path.rootname(f),
            not String.starts_with?(role, "favicon"),
            role != "starfleet",
            do: role

      _ ->
        []
    end
  end

  # ── Tableau basique `/table` (rendu serveur, zéro CSS) ───────────────────────

  # Une ligne fixe par rôle d'agent, TOUJOURS présente (« absent » si aucun pod vivant
  # ne le porte). La liste des rôles DÉRIVE du catalogue cap-profiles (`dashboard_roles/0`,
  # source unique du domaine), pas d'une constante. On groupe les pods vivants par `role`
  # (un même rôle peut en porter plusieurs : on les liste tous).
  # `border="1"` est le minimum pour que les cellules soient visibles.
  defp table_page do
    roles = dashboard_roles()
    by_role = Enum.group_by(Fleet.Spawner.list_pods(), &Map.get(&1, :role))
    rows = Enum.map_join(roles, "\n", &role_rows(&1, Map.get(by_role, &1, [])))

    """
    <!DOCTYPE html>
    <html lang="fr">
    <head>
    <meta charset="UTF-8">
    <meta http-equiv="refresh" content="3">
    <title>fleet pods</title>
    </head>
    <body>
    <table border="1">
    <tr><th>role</th><th>pod_id</th><th>phase</th><th>issue</th><th>conditions</th><th>tmux</th><th>session</th></tr>
    #{rows}
    </table>
    </body>
    </html>
    """
  end

  defp role_rows(role, []) do
    "<tr><td>#{h(role)}</td><td colspan=\"6\">— absent —</td></tr>"
  end

  defp role_rows(role, pods) do
    Enum.map_join(pods, "\n", fn p ->
      "<tr>" <>
        "<td>#{h(role)}</td>" <>
        "<td>#{h(Map.get(p, :pod_id))}</td>" <>
        "<td>#{h(Map.get(p, :phase))}</td>" <>
        "<td>#{h(Map.get(p, :issue_id))}</td>" <>
        "<td>#{h(Enum.join(Map.get(p, :conditions, []), ", "))}</td>" <>
        "<td>#{h(Map.get(p, :tmux_session))}</td>" <>
        "<td>#{h(Map.get(p, :session_id))}</td>" <>
        "</tr>"
    end)
  end

  # Rôles à afficher = catalogue cap-profiles (`Fleet.CapProfile.list/0`, source unique du domaine)
  # filtré aux rôles qui tournent comme POD de fleet (donc peuvent avoir un état). Trié pour un ordre
  # stable. Catalogue illisible → `[]` (dégradation sûre, jamais de crash du deck).
  defp dashboard_roles do
    case Fleet.CapProfile.list() do
      {:ok, names} ->
        names
        |> Enum.reject(&memory_x_role?/1)
        |> Enum.filter(&pod_role?/1)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  # Garde EN DUR temporaire (validée user) : `CapProfile.list/0` ramasse aussi les profils Memory-X
  # des sous-dossiers `monks/` / `archivistes/` — ce ne sont pas des rôles d'agent à afficher. Absente
  # de CE repo aujourd'hui (donc inerte ici) mais `list/0` scanne réellement ces sous-dossiers, donc ce
  # n'est pas une garde sur du vide : elle mord dès qu'un de ces profils existe. Propre à terme = un champ
  # sémantique (`monk_registry`/`monk_instance` non-nul), pas un préfixe de nom.
  defp memory_x_role?(name),
    do: String.starts_with?(name, "monk") or String.starts_with?(name, "archivist")

  # Rôle qui tourne comme POD de fleet (peut donc porter un état pod) : `host_native != true`.
  # Même discriminateur sémantique que `Fleet.Spawner.PermanentBoot.boot_at_start?/1` — exclut `starfleet`
  # (host-natif, boote via systemd, « n'a PAS de pod ») sans coder son nom en dur. Profil illisible → exclu.
  defp pod_role?(name) do
    case Fleet.CapProfile.load(name) do
      {:ok, %Fleet.CapProfile{spec: spec}} -> get_in(spec, ["invocation", "host_native"]) != true
      _ -> false
    end
  end

  # Échappe pour le HTML — toute valeur (atom phase, string, nil) → texte sûr.
  defp h(nil), do: ""
  defp h(v), do: v |> to_string() |> Plug.HTML.html_escape()

  defp page do
    """
    <!DOCTYPE html>
    <html lang="fr">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>LCARS // OBSERVATION DECK</title>
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
      .ev-list{font-family:monospace;font-size:12px;max-height:240px;overflow:auto}
      .ev-row{display:flex;gap:8px;padding:2px 6px;border-bottom:1px solid #223;white-space:nowrap}
      .ev-type{color:#f93;min-width:170px}
      .ev-src{color:#6cf;min-width:90px}
      .ev-pod{color:#9af;flex:1;overflow:hidden;text-overflow:ellipsis}
      .ev-ts{color:#668}
      .stat-row{display:flex;flex-wrap:wrap;gap:10px;font-family:monospace;font-size:12px;padding:6px}
      .stat{color:#9af}.stat b{color:#f93}
    </style>
    </head>
    <body>
    <div class="crt-overlay"></div>
    <div class="lcars-frame">
      <header class="lcars-header">
        <div class="bezel bezel-left"></div>
        <div class="head-strip">
          <span class="head-title">LCARS // OBSERVATION</span>
          <span class="head-sub">DECK — CORE REMÉDIÉ</span>
        </div>
        <div class="head-status">
          <span class="status-led" id="led-health"></span>
          <span class="head-clock" id="clock">--:--:--</span>
        </div>
        <div class="bezel bezel-right"></div>
      </header>

      <main class="lcars-main">
        #{deck("B1", "BRIDGE", ~s|<div class="stat-row" id="bridge-body"><span class="deck-soon">…</span></div>|)}
        #{deck("P1", "PODS", ~s|<div class="obs-grid" id="pods-grid"><div class="deck-soon">chargement…</div></div><div class="panel-meta" id="pods-count">— … —</div>|)}
        #{deck("F1", "FLOW", ~s|<div class="stat-row" id="flow-tasks"></div><div class="ev-list" id="flow-body"></div>|)}
        #{deck("G1", "GATEKEEPER", ~s|<div class="ev-list" id="gk-body"></div>|)}
        #{deck("C1", "COORDINATION", ~s|<div class="ev-list" id="coord-body"></div>|)}
        #{deck("S1", "STREAM", ~s|<div class="ev-list" id="stream-body"></div>|)}
        #{deck("D1", "DIAGNOSTICS", ~s|<div class="ev-list" id="diag-body"></div>|)}
      </main>

      <footer class="lcars-footer">
        <span class="footer-meta">fleet_observation • BL-026 read-frontier • PODS live + read-model (stream %Fleet.Event{})</span>
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
        + '<div class="pc-row"><span class="pc-k">issue</span>'+esc(p.issue_id)+'</div>'
        + '<div class="pc-row"><span class="pc-k">conditions</span>'+esc((p.conditions||[]).join(', '))+'</div>'
        + '<div class="pc-row"><span class="pc-k">tmux</span>'+esc(p.tmux_session)+'</div>'
        + '</div>';
    }
    function evRow(s){
      return '<div class="ev-row"><span class="ev-type">'+esc(s.type)+'</span>'
        + '<span class="ev-src">'+esc(s.source)+'</span>'
        + '<span class="ev-pod">'+esc(s.pod_id||'')+'</span>'
        + '<span class="ev-ts">'+esc((s.ts||'').slice(11,19))+'</span></div>';
    }
    function fillList(id, arr, empty){
      var el=document.getElementById(id);
      el.innerHTML = (arr && arr.length) ? arr.map(evRow).join('') : '<div class="deck-soon">'+empty+'</div>';
    }
    function n(counts,k){return (counts&&counts[k])||0;}
    async function refreshPods(){
      var led=document.getElementById('led-health');
      try{
        var j=await (await fetch('/api/pods')).json();
        led.classList.add('led-ok');
        document.getElementById('pods-count').textContent='— '+j.count+' actifs —';
        var g=document.getElementById('pods-grid');
        g.innerHTML = j.pods.length ? j.pods.map(podCard).join('') : '<div class="deck-soon">aucun pod actif</div>';
      }catch(e){led.classList.remove('led-ok');}
    }
    async function refreshProjection(){
      try{
        var p=await (await fetch('/api/projection')).json();
        var c=p.counts||{};
        document.getElementById('bridge-body').innerHTML =
          '<span class="stat">events <b>'+(p.total||0)+'</b></span>'
          +'<span class="stat">types <b>'+Object.keys(c).length+'</b></span>'
          +'<span class="stat">workflow_runs <b>'+(p.workflow_runs||[]).length+'</b></span>'
          +'<span class="stat">gatekeeper <b>'+(p.gatekeeper||[]).length+'</b></span>'
          +'<span class="stat">diag <b>'+(p.diagnostics||[]).length+'</b></span>';
        document.getElementById('flow-tasks').innerHTML =
          '<span class="stat">enqueued <b>'+n(c,'work_item.enqueued')+'</b></span>'
          +'<span class="stat">assigned <b>'+n(c,'work_item.assigned')+'</b></span>'
          +'<span class="stat">completed <b>'+n(c,'work_item.completed')+'</b></span>'
          +'<span class="stat">failed <b>'+n(c,'work_item.failed')+'</b></span>'
          +'<span class="stat">cleared <b>'+n(c,'work_item.cleared')+'</b></span>';
        fillList('flow-body', p.workflow_runs, 'aucun workflow_run observé');
        fillList('gk-body', p.gatekeeper, 'aucun verdict / escalade');
        fillList('coord-body', p.coordination, 'aucune coordination / issue');
        fillList('stream-body', p.stream, 'flux vide');
        fillList('diag-body', p.diagnostics, 'aucun signal diagnostic');
      }catch(e){}
    }
    function refresh(){refreshPods();refreshProjection();}
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
end
