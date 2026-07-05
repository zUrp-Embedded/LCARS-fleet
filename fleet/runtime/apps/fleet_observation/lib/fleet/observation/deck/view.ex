defmodule Fleet.Observation.Deck.View do
  @moduledoc """
  Rendu HTML PUR de l'observation deck — le gabarit (HTML + CSS + JS inline),
  séparé du contrôleur (`Fleet.Observation.Deck` : routing Plug + dérivation du
  catalogue de rôles + snapshots live). Extrait de `Deck` (éclatement C4
  2026-07-05) : ~85 % de ce fichier est du gabarit, zéro logique de routeur.

  Deux vues, deux philosophies :

    * `page/0` — le shell LCARS « 7 decks » : coquille STATIQUE (aucune donnée
      serveur), tout le contenu est tiré côté client par le JS embarqué
      (`fetch /api/pods` + `/api/projection`, refresh 3 s). Fonction 0-arité :
      la page ne dépend d'AUCUN état — la donnée passe par les endpoints JSON.
    * `table_page/2` — le tableau basique rendu CÔTÉ SERVEUR (zéro CSS, zéro
      JS, auto-refresh `<meta refresh>`) : reçoit les données du contrôleur
      (rôles + pods groupés par rôle) et ne fait QUE les rendre. Pure : mêmes
      arguments ⇒ même HTML.

  Frontière : ce module ne lit NI le spawner NI le read-model NI le catalogue
  cap-profiles — toute donnée arrive en argument. Le choix de QUOI afficher
  (quels rôles, quels pods) reste dans `Deck` ; ici on décide seulement de
  COMMENT le montrer. Toute valeur interpolée côté serveur passe par
  l'échappement `h/1` (côté client, par `esc()` dans le JS embarqué).
  """

  @doc """
  Shell LCARS statique : header BRIDGE (LED santé + horloge) + les 7 decks
  (PODS live, les autres alimentés par la projection du read-model). Le JS
  embarqué tire `/api/pods` et `/api/projection` toutes les 3 s — la page
  elle-même ne porte aucune donnée serveur.
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

  @doc """
  Tableau basique rendu serveur (zéro CSS/JS, auto-refresh `<meta refresh>` 3 s).
  `roles` = les rôles à afficher (une ligne TOUJOURS présente par rôle, « absent »
  si aucun pod vivant ne le porte) ; `pods_by_role` = les pods vivants groupés par
  rôle (un rôle peut en porter plusieurs : tous listés). Pure — le contrôleur
  (`Deck`, route `/table`) fournit les deux. `border="1"` est le minimum pour que
  les cellules soient visibles.
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

  # Un deck = une section panel LCARS.
  defp deck(num, name, body) do
    ~s|<section class="panel"><div class="panel-head"><span class="panel-num">#{num}</span><span class="panel-name">#{name}</span></div><div class="panel-body">#{body}</div></section>|
  end

  # Échappe pour le HTML — toute valeur (atom phase, string, nil) → texte sûr.
  defp h(nil), do: ""
  defp h(v), do: v |> to_string() |> Plug.HTML.html_escape()
end
