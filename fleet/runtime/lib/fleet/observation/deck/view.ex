defmodule Fleet.Observation.Deck.View do
  @moduledoc """
  PURE HTML rendering of the observation deck — the template (inline HTML + CSS + JS),
  separated from the controller (`Fleet.Observation.Deck`: Plug routing + role-catalogue
  derivation + live snapshots): ~85% of this file is template, zero router logic.

  Two views, two philosophies:

    * `page/0` — the LCARS "7 decks" shell: STATIC skeleton (no server
      data), all content is pulled client-side by the embedded JS
      (`fetch /api/pods` + `/api/projection`, 3 s refresh). 0-arity function:
      the page depends on NO state — the data flows through the JSON endpoints.
    * `table_page/2` — the basic table rendered SERVER-SIDE (zero CSS, zero
      JS, auto-refresh `<meta refresh>`): receives the data from the controller
      (roles + pods grouped by role) and does ONLY render them. Pure: same
      arguments ⇒ same HTML.

  Frontier: this module reads NEITHER the spawner NOR the read-model NOR the
  cap-profiles catalogue — all data arrives as an argument. The choice of WHAT to display
  (which roles, which pods) stays in `Deck`; here we decide only
  HOW to show it. Every value interpolated server-side goes through
  the `h/1` escaping (client-side, through `esc()` in the embedded JS).

  **Last revised**: 2026-07-21
  """

  @doc """
  Static LCARS shell: BRIDGE header (health LED + clock) + the 7 decks
  (PODS live, the others fed by the read-model projection). The embedded
  JS pulls `/api/pods` and `/api/projection` every 3 s — the page
  itself carries no server data.
  """
  @spec page() :: String.t()
  def page do
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
      .proj-status{font-family:monospace;font-size:12px;margin:0 10px;color:#668}
      .proj-status-bad{color:#f33;font-weight:bold}
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
          <span class="proj-status" id="proj-status"></span>
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
    function projStatus(txt){
      var s=document.getElementById('proj-status');
      if(!s)return;
      s.textContent=txt;
      s.className=txt?'proj-status proj-status-bad':'proj-status';
    }
    async function refreshProjection(){
      try{
        var p=await (await fetch('/api/projection')).json();
        // Surface the read-model status. A :deaf/:unavailable projection is a FROZEN stream, NOT a
        // quiet fleet — the empty decks below would otherwise read as a calm, healthy fleet (FR operator).
        projStatus(p._status && p._status!=='live'
          ? '⚠ projection '+p._status+' — flux figé, PAS une flotte calme'
          : '');
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
      }catch(e){
        // Don't swallow — a failed projection fetch means the dashboard is BLIND, not calm.
        projStatus('⚠ projection injoignable — dashboard aveugle');
      }
    }
    function refresh(){refreshPods();refreshProjection();}
    tick();setInterval(tick,1000);refresh();setInterval(refresh,3000);
    </script>
    </body>
    </html>
    """
  end

  @doc """
  Basic server-rendered table (zero CSS/JS, auto-refresh `<meta refresh>` 3 s).
  `roles` = the roles to display (a row ALWAYS present per role, "absent"
  if no live pod carries it); `pods_by_role` = the live pods grouped by
  role (a role can carry several: all listed). Pure — the controller
  (`Deck`, `/table` route) provides both. `border="1"` is the minimum for the
  cells to be visible.
  """
  @spec table_page([String.t()], %{optional(String.t() | nil) => [map()]}) :: String.t()
  def table_page(roles, pods_by_role) when is_list(roles) and is_map(pods_by_role) do
    rows = Enum.map_join(roles, "\n", &role_rows(&1, Map.get(pods_by_role, &1, [])))

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

  @doc """
  HTML shown when the role catalogue can NOT be read (F-C125). `Fleet.CapProfile.list/0` is DELIBERATELY
  fail-loud (an unreadable/corrupt catalogue ≠ an empty one), so the deck surfaces that error instead of a
  silent-empty table that would lie "no roles" during a broken cap-profile deploy. `reason` is an internal
  error term (`inspect`-ed), not client input.
  """
  def error_page(reason) do
    """
    <!DOCTYPE html>
    <html lang="fr">
    <head>
    <meta charset="UTF-8">
    <meta http-equiv="refresh" content="3">
    <title>fleet pods — catalogue illisible</title>
    </head>
    <body>
    <p style="color:#c00"><strong>⚠ catalogue de rôles illisible</strong></p>
    <p>#{inspect(reason)}</p>
    <p>(cap-profile catalogue error — ce n'est PAS « aucun rôle » : le déploiement cap-profile est cassé.)</p>
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

  # A deck = one LCARS panel section.
  defp deck(num, name, body) do
    ~s|<section class="panel"><div class="panel-head"><span class="panel-num">#{num}</span><span class="panel-name">#{name}</span></div><div class="panel-body">#{body}</div></section>|
  end

  # Escapes for HTML — any value (phase atom, string, nil) → safe text.
  defp h(nil), do: ""
  defp h(v), do: v |> to_string() |> Plug.HTML.html_escape()
end
