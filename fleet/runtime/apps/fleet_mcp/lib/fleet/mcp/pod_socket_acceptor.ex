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
  @socket_opts [:binary, {:packet, :line}, {:active, false}, {:reuseaddr, true}]

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
        serve(sock, pod_id)
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

  # Décode la ligne JSON-RPC. Seul `tools/call` est dispatché vers PodTools. Une
  # ligne vide / un JSON invalide / une notification sans `id` est ignorée
  # silencieusement (rien à répondre). Un autre `method` avec un `id` (anomalie :
  # `initialize`/`tools/list` devraient être servis par le pont) → erreur protocole.
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

      _ ->
        nil
    end
  end

  # `pod_id` vient de l'ÉTAT de l'accepteur (le canal), JAMAIS de `tool_args` : on
  # ne lit pas d'identité sur le wire. Le format du résultat suit la convention MCP.
  defp call_tool(params, pod_id) do
    tool = params["name"]
    tool_args = params["arguments"] || %{}

    case PodTools.handle_tool_call(tool, tool_args, %{pod_id: pod_id}) do
      {:ok, content, _state} ->
        content

      {:error, reason, _state} ->
        %{"content" => [%{"type" => "text", "text" => error_text(reason)}], "isError" => true}
    end
  end

  defp error_text(reason) when is_binary(reason), do: reason
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
