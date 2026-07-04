defmodule Fleet.MCP.PodSocketAcceptor do
  @moduledoc """
  Accepteur de socket AF_UNIX pour UN pod : l'identité du pod EST le canal.

  Chaque pod a SA propre socket, montée dans son seul sandbox. Donc toute ligne
  reçue sur CETTE socket vient forcément de CE pod : le `pod_id` est l'état
  immuable de l'accepteur (porté au démarrage, depuis le nom du socket), jamais
  lu du wire. Il n'y a plus rien à prouver — pas de secret présenté, pas de
  `pod_id` à comparer : le canal discrimine. (L'ancien transport HTTP loopback
  était partagé par tous les pods ; le `pod_id` y était devinable, d'où l'ancienne
  capability. La socket per-pod ferme ce trou par construction.)

  Un accepteur = un process = une socket : il y a un vrai motif runtime (une
  socket est un état I/O qui persiste entre les lignes). Il possède le listen
  socket, boucle en `accept`, et sert chaque connexion en série — un seul client
  (le pont de CE pod) la joint, donc bloquer sur lui n'affecte que ce pod, jamais
  les autres (chacun a son propre accepteur). Supervisé par
  `Fleet.MCP.PodSocketSupervisor` (DynamicSupervisor) ; nommé dans le Registry
  `Fleet.MCP.PodSocketRegistry` (clé = `pod_id`) pour la résolution idempotente.

  ## Protocole

  JSON-RPC newline-framed (`{:packet, :line}`), un message = une ligne. Seul
  `method == "tools/call"` est servi ici : `initialize` / `tools/list` sont
  répondus localement par le pont stdio (`bin/fleet_mcp_stdio_bridge.py`). Le
  frame de réponse réutilise `Fleet.MCP.PodTools.handle_tool_call/3` :

    * `{:ok, content, _}`  → `result` = ce `content` (déjà au format MCP) ;
    * `{:error, reason, _}` → `result` = `%{"content" => [texte], "isError" => true}`
      (convention MCP : une erreur d'outil est un résultat avec `isError`, pas une
      erreur de protocole — le pod la lit comme du texte d'outil).
  """

  use GenServer

  require Logger

  alias Fleet.MCP.PodTools

  # Options de socket AF_UNIX stream, passive (on `recv` explicitement), une ligne
  # par message. `reuseaddr` est sans danger ici (un fichier socket résiduel est
  # quand même retiré au démarrage — cf. `rm_stale/1`).
  # `buffer` DOIT depasser la plus longue ligne JSON-RPC possible : avec `packet: :line`,
  # une ligne plus longue que le buffer (defaut inet ~1460 o) est livree TRONQUEE en
  # fragments, chaque fragment est un JSON invalide, et le serveur attendait ensuite une
  # ligne complete qui n'arrivait jamais -> hang silencieux, timeout 30 s cote pont,
  # payload d'outil > ~1,4 Ko PERDU (vu live 2026-07-04 : brief arch + summaries engineer/
  # reviewer). 1 MiB couvre tout payload realiste ; au-dela, handle_line repond -32700.
  @socket_opts [
    :binary,
    {:packet, :line},
    {:active, false},
    {:reuseaddr, true},
    {:buffer, 1_048_576}
  ]

  # Task.Supervisor (arbre `Fleet.MCP.Supervisor`) où chaque connexion acceptée est servie dans sa
  # propre Task. Sépare le SERVICE d'une connexion (potentiellement lent) de la BOUCLE d'accept.
  @conn_sup Fleet.MCP.ConnectionTaskSupervisor

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    pod_id = Keyword.fetch!(opts, :pod_id)
    GenServer.start_link(__MODULE__, opts, name: via(pod_id))
  end

  defp via(pod_id), do: {:via, Registry, {Fleet.MCP.PodSocketRegistry, pod_id}}

  @impl GenServer
  def init(opts) do
    pod_id = Keyword.fetch!(opts, :pod_id)
    path = Keyword.fetch!(opts, :socket_path)

    with :ok <- ensure_parent_dir(path),
         :ok <- rm_stale(path),
         {:ok, lsock} <- :gen_tcp.listen(0, [{:ifaddr, {:local, path}} | @socket_opts]) do
      {:ok, %{pod_id: pod_id, socket_path: path, lsock: lsock}, {:continue, :accept}}
    else
      {:error, reason} -> {:stop, {:socket_init_failed, reason}}
    end
  end

  @impl GenServer
  def handle_continue(:accept, %{lsock: lsock, pod_id: pod_id} = state) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        # CONCURRENT : chaque connexion est servie dans sa PROPRE Task, jamais inline ici. Servir
        # inline (l'ancien `serve(sock, pod_id)`) bloquait la boucle d'accept tant qu'UN handler pendait
        # (ex. un appel forge lent de ~30 s) : on ne revenait jamais à `accept`, donc toute connexion
        # suivante du pod restait dans le backlog kernel sans être servie → `readline` timeout côté pont
        # (le pod gelait entier). Une Task par connexion → on re-`accept` tout de suite ; un handler lent
        # n'affecte que sa connexion. `controlling_process` donne la socket au worker (l'accepteur peut
        # re-accept / mourir sans tuer les connexions en vol) ; transfert en échec (worker déjà mort) →
        # on ferme la socket plutôt que la fuir.
        case Task.Supervisor.start_child(@conn_sup, fn -> serve(sock, pod_id) end) do
          {:ok, pid} ->
            case :gen_tcp.controlling_process(sock, pid) do
              :ok -> :ok
              {:error, _} -> :gen_tcp.close(sock)
            end

          {:error, _} ->
            :gen_tcp.close(sock)
        end

        {:noreply, state, {:continue, :accept}}

      # Listen socket fermé = on nous a arrêtés (release) → stop net, pas une erreur.
      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, reason} ->
        {:stop, {:accept_error, reason}, state}
    end
  end

  # Sert une connexion ligne par ligne jusqu'à ce que le pair ferme (le pont fait
  # un appel = une ligne, puis lit la réponse ; il peut en enchaîner plusieurs sur
  # la même connexion). À la fermeture / erreur, on rend la main à la boucle accept.
  defp serve(sock, pod_id) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, line} ->
        case handle_line(line, pod_id) do
          nil -> :ok
          frame -> :gen_tcp.send(sock, frame)
        end

        serve(sock, pod_id)

      {:error, _reason} ->
        :gen_tcp.close(sock)
    end
  end

  # Decode la ligne JSON-RPC. Seul `tools/call` est dispatche vers PodTools. Une
  # notification sans `id` est ignoree (rien a repondre, contrat JSON-RPC). Un JSON
  # INVALIDE (ligne tronquee/cassee) -> reponse -32700 + warning : JAMAIS avale en
  # silence — l'avalement transformait toute ligne invalide en timeout 30 s
  # indistinguable cote pont, zero trace BEAM (vu live 2026-07-04). Un autre `method`
  # avec un `id` (anomalie : `initialize`/`tools/list` sont servis par le pont) -> -32601.
  defp handle_line(line, pod_id) do
    case Jason.decode(line) do
      {:ok, %{"method" => "tools/call", "id" => id, "params" => params}} ->
        encode(%{"jsonrpc" => "2.0", "id" => id, "result" => call_tool(params, pod_id)})

      {:ok, %{"method" => method, "id" => id}} when not is_nil(id) ->
        encode(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{
            "code" => -32_601,
            "message" => "method #{method} non servie par la socket pod"
          }
        })

      {:ok, _notification_sans_id} ->
        nil

      {:error, _decode_error} ->
        Logger.warning(
          "PodSocketAcceptor pod=#{pod_id} : ligne indecodable (#{byte_size(line)} o) -> -32700"
        )

        encode(%{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{"code" => -32_700, "message" => "parse error (ligne JSON invalide)"}
        })
    end
  end

  # `pod_id` vient de l'ÉTAT de l'accepteur (le canal), JAMAIS de `tool_args` : on
  # ne lit pas d'identité sur le wire. Le format du résultat suit la convention MCP.
  # Un tools/call lent doit etre VISIBLE cote serveur : avant 2026-07-04 un hang de
  # 30 s ne laissait AUCUNE trace BEAM (le pont loggue de son cote, mais le serveur
  # etait aveugle -> forensics impossible). Seuil volontairement haut : on trace
  # l'anomalie, pas le bruit.
  @slow_tool_warn_ms 5_000

  defp call_tool(params, pod_id) do
    tool = params["name"]
    tool_args = params["arguments"] || %{}

    {us, resp} =
      :timer.tc(fn -> PodTools.handle_tool_call(tool, tool_args, %{pod_id: pod_id}) end)

    ms = div(us, 1000)

    if ms > @slow_tool_warn_ms do
      Logger.warning("PodSocketAcceptor pod=#{pod_id} tools/call #{tool} LENT (#{ms} ms)")
    end

    case resp do
      {:ok, content, _state} ->
        content

      {:error, reason, _state} ->
        %{"content" => [%{"type" => "text", "text" => error_text(reason)}], "isError" => true}
    end
  end

  # PodTools.handle_tool_call ne renvoie que des atomes/tuples d'erreur (jamais un binaire) → une clause
  # suffit ; `inspect/1` rend toute raison lisible dans le champ text de la réponse MCP d'erreur.
  defp error_text(reason), do: inspect(reason)

  defp encode(map), do: Jason.encode!(map) <> "\n"

  defp ensure_parent_dir(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir, reason}}
    end
  end

  # Un fichier socket résiduel (crash antérieur) ferait échouer le bind
  # (`:eaddrinuse`). On le retire avant de réécouter ; absent = rien à faire.
  defp rm_stale(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:rm_stale, reason}}
    end
  end
end
