defmodule Fleet.MCP.PodSocketAcceptor do
  @moduledoc """
  AF_UNIX socket acceptor for ONE pod: the pod's identity IS the channel.

  Each pod has ITS own socket, mounted into its sole sandbox. So every line
  received on THIS socket necessarily comes from THIS pod: the `pod_id` is the
  acceptor's immutable state (carried at startup, from the socket name), never
  read off the wire. There is nothing left to prove — no secret presented, no
  `pod_id` to compare: the channel discriminates (a SHARED transport would make
  the pod_id guessable; the per-pod socket closes that hole by construction).

  One acceptor = one process = one socket: there is a genuine runtime reason (a
  socket is I/O state that persists across lines). It owns the listen socket,
  loops on `accept`, and hands each accepted connection to a dedicated Task
  (`Fleet.MCP.ConnectionTaskSupervisor`) — the loop re-`accept`s
  immediately; a slow handler blocks only ITS connection, never the following
  ones nor the other pods (each has its own acceptor). Supervised by
  `Fleet.MCP.PodSocketSupervisor` (DynamicSupervisor); named in the Registry
  `Fleet.MCP.PodSocketRegistry` (key = `pod_id`) for idempotent resolution.

  ## Protocol

  JSON-RPC newline-framed (`{:packet, :line}`), one message = one line.
  `tools/call` AND `tools/list` are both served here (`tools/list` per F-C138 — the
  `deftool` schemas filtered to this pod's role-gated surface, see `list_tools/1`); only
  `initialize` is answered locally by the stdio bridge (`bin/fleet_mcp_stdio_bridge.py`). The
  response frame reuses `PodTools.handle_tool_call/3`:

    * `{:ok, content, _}`  → `result` = that `content` (already in MCP format);
    * `{:error, reason, _}` → `result` = `%{"content" => [text], "isError" => true}`
      (MCP convention: a tool error is a result with `isError`, not a protocol
      error — the pod reads it as tool text).
  """

  use GenServer

  require Logger

  alias Fleet.MCP.PodTools

  # Line buffer must contain a complete JSON-RPC frame; fragmented lines are invalid JSON.
  @socket_opts [
    :binary,
    {:packet, :line},
    {:active, false},
    {:reuseaddr, true},
    {:buffer, 1_048_576}
  ]

  # Mute connections eventually release shared Task capacity (D-07 config namespace).
  #
  # ⚠ FIGE A LA COMPILATION, ET C'EST LE SEUL ENDROIT QUI LE DIT. `compile_env` grave la valeur dans
  # le module : un `Application.put_env(:lcars_fleet, :mcp_socket_idle_timeout_ms, …)` a l'execution
  # est IGNORE, en silence. Tout le reste de ce sous-systeme lit par `get_env` (15 occurrences dans
  # `lib/fleet/mcp/`), donc ces deux plafonds RESSEMBLENT a des molettes et n'en sont pas.
  #
  # L'ecart est defendu, pas subi : `compile_env` est ce qui autorise l'usage en ATTRIBUT DE MODULE
  # (une garde de fonction ne peut pas appeler `get_env`), et une release refuse de demarrer si la
  # config de boot diverge de celle de la compilation — une protection qu'un `get_env` n'a pas. Les
  # basculer en `get_env` echangerait ces deux proprietes contre une molette que personne n'a
  # demandee : MESURE, aucune de ces deux cles n'apparait dans `config/`, `bin/`, `deploy/` ni
  # `test/`, et aucune variable d'environnement ne les expose.
  @idle_timeout_ms Application.compile_env(:lcars_fleet, :mcp_socket_idle_timeout_ms, 300_000)

  # Connection service is isolated from the accept loop.
  @conn_sup Fleet.MCP.ConnectionTaskSupervisor

  # Per-pod ceiling protects the fleet-wide connection pool.
  # Meme nature figee que `@idle_timeout_ms` ci-dessus, et pour les memes raisons — ces deux-la sont
  # les SEULS `compile_env` de tout `lib/`, ce qui rend leur exception d'autant plus facile a lire
  # comme un oubli si personne ne l'ecrit.
  @max_conns_per_pod Application.compile_env(:lcars_fleet, :mcp_max_conns_per_pod, 8)

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
    # F-C138: spawner threads the role-gated tool surface.
    tools = Keyword.get(opts, :tools, [])

    with :ok <- ensure_parent_dir(path),
         :ok <- rm_stale(path),
         {:ok, lsock} <- :gen_tcp.listen(0, [{:ifaddr, {:local, path}} | @socket_opts]),
         :ok <- restrict(path, lsock) do
      # Monitored live Tasks back the per-pod ceiling.
      {:ok, %{pod_id: pod_id, socket_path: path, lsock: lsock, tools: tools, conns: %{}},
       {:continue, :accept}}
    else
      {:error, reason} -> {:stop, {:socket_init_failed, reason}}
    end
  end

  # LA SOCKET EST UNE PORTE, SES PERMISSIONS EN SONT LA SERRURE.
  #
  # `:gen_tcp.listen` cree le noeud AF_UNIX au UMASK du processus : rien ne garantit qu'il soit
  # ferme. C'etait la seule porte de la famille sans serrure posee ici — le socket de controle fait
  # du `chmod 0600` une CONDITION DE READINESS, le sock-dir tmux est en 0700, celle-ci s'en
  # remettait aux permissions du home. Un home lisible par le groupe suffit alors a rendre la
  # socket MCP d'un pod joignable par un autre humain de la boite, et cette socket EST le canal
  # d'identite du pod (`pod_id` = etat de l'acceptor, jamais lu sur le fil).
  #
  # Fail-closed, comme son jumeau : une socket ouverte dont on n'a pas pu poser la serrure ne
  # demarre pas, et on la referme au lieu de laisser une porte sans verrou derriere soi.
  defp restrict(path, lsock) do
    case File.chmod(path, 0o600) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = :gen_tcp.close(lsock)
        _ = File.rm(path)
        {:error, {:chmod_failed, path, reason}}
    end
  end

  @impl GenServer
  def handle_info(:retry_accept, state), do: {:noreply, state, {:continue, :accept}}

  # Any connection termination frees its live slot.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | conns: Map.delete(state.conns, ref)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_continue(:accept, %{lsock: lsock, pod_id: pod_id} = state) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        # Blocking continue loop drains pending DOWNs before enforcing live capacity.
        state = reap_down(state)

        # Refuse per-pod excess before consuming shared pool capacity.
        if live_conns(state) >= @max_conns_per_pod do
          Logger.warning(
            "PodSocketAcceptor: pod=#{pod_id} connection REFUSED — #{@max_conns_per_pod} " <>
              "concurrent connections already served for this pod (leaking bridge?); the " <>
              "fleet-wide Task pool is NOT consumed by this pod's excess"
          )

          :gen_tcp.close(sock)
          {:noreply, state, {:continue, :accept}}
        else
          {:noreply, spawn_conn(sock, state), {:continue, :accept}}
        end

      {:error, :closed} ->
        {:stop, :normal, state}

      # FD exhaustion retries instead of cascading acceptor loss.
      {:error, reason} when reason in [:emfile, :enfile] ->
        Logger.error(
          "PodSocketAcceptor: pod=#{pod_id} accept #{inspect(reason)} (FD exhaustion) — retry in 1s"
        )

        Process.send_after(self(), :retry_accept, 1_000)
        {:noreply, state}

      {:error, reason} ->
        {:stop, {:accept_error, reason}, state}
    end
  end

  defp live_conns(%{conns: conns}), do: map_size(conns)

  # Non-blocking drain of monitored connection exits only.
  defp reap_down(state) do
    receive do
      {:DOWN, ref, :process, _pid, _reason} ->
        reap_down(%{state | conns: Map.delete(state.conns, ref)})
    after
      0 -> state
    end
  end

  # The monitored worker waits for `:go`, so recv cannot race socket ownership transfer.
  defp spawn_conn(sock, %{pod_id: pod_id, tools: tools} = state) do
    case Task.Supervisor.start_child(@conn_sup, fn -> await_go_then_serve(sock, pod_id, tools) end) do
      {:ok, pid} ->
        case :gen_tcp.controlling_process(sock, pid) do
          :ok ->
            send(pid, :go)
            ref = Process.monitor(pid)
            %{state | conns: Map.put(state.conns, ref, pid)}

          {:error, _} ->
            :gen_tcp.close(sock)
            state
        end

      {:error, reason} ->
        # Per-pod excess was already refused; this is fleet-wide saturation.
        Logger.warning(
          "PodSocketAcceptor: pod=#{pod_id} connection REFUSED (#{inspect(reason)}) — " <>
            "fleet-wide connection pool saturated"
        )

        :gen_tcp.close(sock)
        state
    end
  end

  # Frees a parked Task if its acceptor dies before transferring ownership.
  @go_timeout_ms 5_000

  defp await_go_then_serve(sock, pod_id, tools) do
    receive do
      :go -> serve(sock, pod_id, tools)
    after
      @go_timeout_ms ->
        Logger.warning(
          "PodSocketAcceptor: pod=#{pod_id} connection worker never got :go (acceptor gone?) — slot released"
        )
    end
  end

  # The deadline applies between frames, not while a tool call is executing.
  defp serve(sock, pod_id, tools) do
    case :gen_tcp.recv(sock, 0, @idle_timeout_ms) do
      {:ok, line} ->
        _ =
          case handle_line(line, pod_id, tools) do
            nil -> :ok
            frame -> :gen_tcp.send(sock, frame)
          end

        serve(sock, pod_id, tools)

      {:error, :timeout} ->
        Logger.warning(
          "PodSocketAcceptor: pod=#{pod_id} connection idle > #{div(@idle_timeout_ms, 1000)}s " <>
            "— closed (mute connections must not hold the fleet-wide Task pool)"
        )

        :gen_tcp.close(sock)

      {:error, _reason} ->
        :gen_tcp.close(sock)
    end
  end

  # Decode the JSON-RPC line. Only `tools/call` is dispatched to PodTools. A
  # notification with no `id` is ignored (nothing to answer, JSON-RPC contract). An
  # INVALID JSON (truncated/broken line) -> -32700 response + warning: NEVER swallowed
  # silently — swallowing turns every invalid line into a 30 s timeout
  # indistinguishable on the bridge side, zero BEAM trace. Another `method`
  # with an `id` (anomaly: `initialize` is answered by the bridge, `tools/list` is handled above) -> -32601.
  defp handle_line(line, pod_id, tools) do
    # THE POD IS UP, AND THIS IS THE ONLY IN-BAND PROOF THAT EXISTS DURING A COLD START. A line on
    # this socket means the pod's MCP client is connected — which happens at TUI init, before the
    # agent takes any turn, so LONG before the work-item poll that everything else waits on. The
    # kick loop consumes it: keys typed into a REPL that is not up yet are not lost, tmux buffers
    # them and the TUI replays each as its own submission (measured 2026-08-04: a scribe took 7
    # `engage` in its REPL, one per kick fired during the cold start).
    # Marked on EVERY line, not only the first: it is a cast into a `Map.put_new`, and marking on
    # `tools/list` alone would miss a pod that reconnects mid-life (fleet restart) without
    # re-listing.
    Fleet.TaskQueue.mark_connected(pod_id)

    case Jason.decode(line) do
      {:ok, %{"method" => "tools/call", "id" => id, "params" => params}} ->
        encode(%{"jsonrpc" => "2.0", "id" => id, "result" => call_tool(params, pod_id, tools)})

      # F-C138 — the pod socket serves `tools/list` (a bridge-side hard-coded catalogue would
      # DRIFT from the deftools). Single source: the schemas come from `PodTools.get_tools/0` (the
      # `deftool` authority), filtered to base (universal) plus whatever names were threaded at
      # spawn.
      #
      # DISCOVERY *AND* AUTHORIZATION SINCE 6-099, and the same list serves both: `call_tool/3`
      # refuses anything outside `base_tool_names() ++ threaded` before dispatch. This paragraph
      # used to read "DISCOVERY, NOT AUTHORIZATION: `tools/call` does not re-check this list, so a
      # pod that knows an off-list name calls it anyway" — exact, and it described the hole rather
      # than closing it.
      #
      # The per-tool barrier stays FIRST and untouched: the delegation tools carry a server-side
      # role gate (`require_architect`/`require_onboarder`, `Delegation`) and
      # `get_work_item`/`submit_result` derive their subject from the channel's pod_id, never from a
      # wire argument. INVARIANT, held by `mcp.tools_gated` in `lcars.contracts.check`: every tool is
      # role-gated or pod-scoped. The list is now a SECOND barrier, not a replacement — it buys what
      # the role gate cannot express, namely two variants of one role with different surfaces.
      # The bridge still forwards blindly; the refusal happens here.
      #
      # ⚠ LE DEMI-FILETE ETAIT VIDE DANS TOUS LES PROFILS LIVRES, ET IL A CESSE DE L'ETRE LE
      # 2026-08-20. Les noms viennent de `CapProfile.mcp_fleet_tools/1`, c'est-a-dire des entrees
      # `scope.allowedTools` prefixees `mcp__fleet__`. Ce paragraphe disait « pas un seul profil
      # canon n'en declare une » : `qualifier` et `reviewer` declarent desormais
      # `mcp__fleet__run_probe`, et ce sont les deux SEULS.
      #
      # Ce que ca change : la liste est maintenant un filtre qui MORD pour un outil — un pod dont le
      # profil ne le declare pas se voit refuser `run_probe` ici meme, avant tout dispatch.
      #
      # Ce que ca ne change pas : elle reste vide pour tous les autres, donc l'ecart historique
      # entre DECOUVERTE et INSTRUCTION tient — les agents travaillent depuis leur prompt, qui nomme
      # une douzaine d'outils que ce filtre ne connait pas. A lire comme la surface qu'un profil PEUT
      # restreindre, jamais comme la surface qu'un role A.
      {:ok, %{"method" => "tools/list", "id" => id}} ->
        encode(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => list_tools(tools)}})

      {:ok, %{"method" => method, "id" => id}} when not is_nil(id) ->
        encode(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{
            "code" => -32_601,
            "message" => "method #{method} not served by the pod socket"
          }
        })

      {:ok, _notification_sans_id} ->
        nil

      {:error, _decode_error} ->
        Logger.warning(
          "PodSocketAcceptor: pod=#{pod_id} undecodable line (#{byte_size(line)} B) -> -32700"
        )

        encode(%{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{"code" => -32_700, "message" => "parse error (invalid JSON line)"}
        })
    end
  end

  # Slow-call trace uses channel-owned identity, never a wire argument.
  @slow_tool_warn_ms 5_000

  # THE LIST NOW AUTHORIZES, IT NO LONGER ONLY DISPLAYS (6-099). `tools/list` filtered the surface
  # while `tools/call` dispatched anything: a pod that knew an off-list name called it, and the only
  # real barrier was the per-tool role gate. Two consequences, and the second is the one that had no
  # workaround: an omission in a profile hid a tool from discovery without preventing its use, and
  # two variants of the SAME role could not be given different MCP surfaces at all.
  #
  # ⚠ CE N'EST PAS UN RENVERSEMENT DE LA SEMANTIQUE GRAVEE de `scope.allowedTools`. Celle-ci
  # ("allowedTools is an INTENT, disallowedTools is a WALL") est MESUREE sur le CLI vendor, qui est
  # l'autre consommateur du meme champ et dont on ne controle pas le comportement. Ici on parle du
  # sous-ensemble `mcp__fleet__` servi par CETTE socket, qui est notre code : un champ, deux
  # consommateurs, et c'est dit aux deux bouts plutot que laisse a deviner.
  #
  # MESURE AVANT D'ARMER (le mur se prouve sur ce qu'il doit LAISSER PASSER) : les 8 roles worker
  # ne nomment dans leur SP que les deux outils de base ; `architect` et `starfleet` declarent
  # chacun un SUR-ENSEMBLE STRICT de ce que leur SP nomme. Aucun role ne perd un outil qu'il
  # utilise. Les gates de role (`require_architect`/`require_onboarder`) restent DEVANT, intacts :
  # ce contrôle s'ajoute, il ne remplace rien.
  defp call_tool(params, pod_id, threaded) do
    tool = params["name"]
    tool_args = params["arguments"] || %{}

    if authorized?(tool, threaded) do
      dispatch_tool(tool, tool_args, pod_id)
    else
      Logger.warning(
        "PodSocketAcceptor: pod=#{pod_id} tools/call #{inspect(tool)} REFUSED — outside this " <>
          "pod's declared MCP surface (base + scope.allowedTools)"
      )

      # Compte comme activite : un pod qui se fait refuser a AGI. Ne pas le compter ferait passer
      # pour mort un pod qui frappe a une porte fermee.
      mark_activity(pod_id)

      %{
        "content" => [%{"type" => "text", "text" => error_text({:tool_not_in_profile, tool})}],
        "isError" => true
      }
    end
  end

  defp authorized?(tool, threaded) when is_binary(tool),
    do: tool in PodTools.base_tool_names() or tool in threaded

  defp authorized?(_tool, _threaded), do: false

  defp dispatch_tool(tool, tool_args, pod_id) do
    {us, resp} =
      :timer.tc(fn -> safe_handle_tool_call(tool, tool_args, pod_id) end)

    ms = div(us, 1000)

    if ms > @slow_tool_warn_ms do
      Logger.warning("PodSocketAcceptor: pod=#{pod_id} tools/call #{tool} SLOW (#{ms} ms)")
    end

    mark_activity(pod_id)

    case resp do
      {:ok, content, _state} ->
        content

      {:error, reason, _state} ->
        %{"content" => [%{"type" => "text", "text" => error_text(reason)}], "isError" => true}
    end
  end

  # A COMPLETED tools/call is the only liveness signal that PROVES the pod acted, and the acceptor
  # was the only one holding it: `:timer.tc` above measured every call and kept none. The mtime of
  # this marker is that timestamp, made durable for a reader in another domain (`Pod.Liveness`)
  # that cannot call into MCP.
  #
  # Marked AFTER the call returns, deliberately: a mark posed on entry would keep re-arming the
  # deadline of a pod stuck INSIDE a tool, which is precisely the death the watchdog exists to
  # catch. Only completion is evidence.
  #
  # A failed touch is swallowed: a liveness HINT must never break the call it observes, and its
  # absence already reads as "no signal" downstream, never as silence.
  # No nil-guarded twin clause: `pod_id` is channel-owned and always a binary here, and dialyzer
  # says so. A defensive clause that can never fire is not a safety net, it is a claim that the
  # value might be something it cannot be.
  defp mark_activity(pod_id) do
    marker =
      pod_id
      |> Fleet.MCP.PodSocketSupervisor.socket_path()
      |> Fleet.Layout.pod_mcp_activity_marker()

    _ = File.touch(marker)
    :ok
  end

  # Forge mutations converge durably; single-flight only collapses concurrent retries.
  #
  # ⚠ CE SITE PORTAIT UNE LISTE DE CINQ MOTS NUS DANS UN SIGIL, pour ~17 mutateurs (6-106). Elle ne
  # ressemblait a aucune autre occurrence d'un nom d'outil (ni chaine citee, ni `mcp__fleet__`, ni
  # prose), donc le renommage objet-d'abord du 2026-08-11 l'a manquee EN SILENCE. Une liste qui ne
  # s'ecrit pas comme les autres est une liste qu'un renommage rate — et elle vivait LOIN des
  # definitions qu'elle pretendait couvrir, ce qui est l'autre moitie du probleme.
  #
  # L'effet vit desormais A COTE de chaque `deftool`, et son exhaustivite est prouvee par le gate.
  # Ici on ne fait plus que LIRE une decision prise la-bas.
  #
  # `:unknown` (un outil que `PodTools` ne declare pas) est traite comme une MUTATION : c'est la
  # direction sure — un mutateur non declare est protege en attendant que le gate le dise, plutot
  # que dispatche nu. Le cout d'une erreur dans ce sens est une latence sur des appels concurrents
  # identiques ; dans l'autre, c'est un effet forge duplique.
  @single_flight_effects [:mutation, :unknown]

  # SOC-RES-001: tool crashes become MCP error results instead of dropped connections.
  defp safe_handle_tool_call(tool, tool_args, pod_id) do
    handle = fn -> tool_handler().handle_tool_call(tool, tool_args, %{pod_id: pod_id}) end

    if PodTools.tool_effect(tool) in @single_flight_effects do
      key = {pod_id, tool, :crypto.hash(:sha256, :erlang.term_to_binary(tool_args))}
      Fleet.MCP.Idempotency.run(key, handle, succeeded?: &match?({:ok, _, _}, &1))
    else
      handle.()
    end
  rescue
    e -> {:error, {:tool_crashed, tool, Exception.message(e)}, %{pod_id: pod_id}}
  catch
    kind, reason -> {:error, {:tool_crashed, tool, {kind, reason}}, %{pod_id: pod_id}}
  end

  # Injectable seam exercises the SOC-RES-001 crash boundary.
  defp tool_handler, do: Application.get_env(:lcars_fleet, :mcp_tool_handler, PodTools)

  defp error_text(reason), do: inspect(reason)

  # F-C138: static schemas filtered to the universal and role-gated surface.
  defp list_tools(threaded) do
    allowed = PodTools.base_tool_names() ++ threaded
    PodTools.get_tools() |> Map.take(allowed) |> Map.values() |> Enum.map(&to_mcp_wire/1)
  end

  # Project ExMCP's internal schema onto the MCP wire shape at the socket boundary.
  defp to_mcp_wire(tool) do
    t = Map.new(tool, fn {k, v} -> {to_string(k), v} end)
    %{"name" => t["name"], "description" => t["description"], "inputSchema" => t["input_schema"]}
  end

  defp encode(map), do: Jason.encode!(map) <> "\n"

  # `File.mkdir_p/1` DISCARDS the error of every intermediate level and reports only the LEAF: it
  # recurses on the parent, drops that result, then calls make_dir on the child. A refusal two
  # levels up therefore surfaces as a bare `:enoent` on the child — an errno that reads as "absent
  # parent" while the parent is present and merely closed. MEASURED: mkdir_p("/run/lcars/mcp/pod_x")
  # under a root-owned `/run` yields `:enoent`, not `:eacces`, and points the operator at a
  # directory that was never the problem.
  #
  # So the errno alone cannot name the fault: carry the first component that does NOT exist plus
  # the writability of its parent. That pair separates the two cases the bare errno merges — a
  # level nobody created, versus a level we are not allowed to create under.
  # LE REPERTOIRE EST LA SERRURE QUE LA SOCKET N'A PAS ENCORE. `:gen_tcp.listen` cree le noeud
  # AF_UNIX au UMASK du processus et `restrict/2` le referme ensuite : entre les deux, le noeud
  # existe avec les droits de l'umask. Sous l'umask MESURE de cette flotte (`0002`) cela fait
  # `0775` — le bit d'ecriture groupe, donc `connect(2)` autorise — et une connexion etablie dans
  # cette fenetre RESTE ouverte apres le chmod : les droits d'une socket Unix ne sont verifies qu'a
  # la connexion. L'auteur tient alors le canal d'outils du pod sans etre ce pod.
  #
  # ⚠ La fenetre ne se ferme pas la ou on la voit. Le BEAM ne sait pas creer un noeud AF_UNIX avec
  # un mode ; il n'y a pas de `listen` atomique en `0600`. Ce qui se ferme, c'est la TRAVERSEE : un
  # parent en `0700` rend `<base>/<pod_id>/sock` inatteignable pour tout autre compte, quel que soit
  # le mode transitoire du noeud. Le `0600` final reste la seconde serrure, pas la premiere.
  #
  # LE JUMEAU EXISTE ET IL EST ATOMIQUE : `bin/bwrap_launch.sh` cree le sock-dir TMUX par
  # `install -d -m 0700`. Le meme launcher documente la divergence — « UNLIKE tmux: the socket file
  # (and its dir) is created OUTSIDE the sandbox by the BEAM BEFORE this launch … no `install -d` »
  # — sans voir que ce cote-ci n'a jamais pose de mode du tout. C'est le mode du jumeau qui arrive
  # ici, pas une regle nouvelle.
  #
  # `mkdir_p` + `chmod` n'est pas atomique non plus, mais son residu ne porte plus l'effet de la
  # fiche : dans cette fenetre-la, la socket n'existe pas encore. Ce qui reste est VERIFIE plutot
  # que suppose — on relit le mode avant de servir, et un repertoire qu'on n'a pas pu fermer ne
  # devient pas une porte ouverte : il devient un refus de demarrage.
  defp ensure_parent_dir(path) do
    dir = Path.dirname(path)

    with :ok <- mkdir_private(dir),
         :ok <- close_dir(dir) do
      verify_private(dir)
    end
  end

  defp mkdir_private(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir, reason, blame(dir)}}
    end
  end

  # Fail-closed, comme `restrict/2` sur la socket : un `chmod` refuse signifie que le repertoire ne
  # nous appartient pas, et c'est deja la reponse.
  defp close_dir(dir) do
    case File.chmod(dir, 0o700) do
      :ok -> :ok
      {:error, reason} -> {:error, {:chmod_dir, reason, blame(dir)}}
    end
  end

  # On RELIT ce qu'on vient de poser. Un repertoire pre-existant appartenant a un autre compte fait
  # echouer le `chmod` au-dessus ; celui-ci attrape ce que le premier ne voit pas — un mode qui n'est
  # pas celui demande, quelle qu'en soit la cause.
  defp verify_private(dir) do
    case File.stat(dir) do
      {:ok, %File.Stat{mode: mode}} ->
        case Bitwise.band(mode, 0o777) do
          0o700 -> :ok
          other -> {:error, {:dir_not_private, other, blame(dir)}}
        end

      {:error, reason} ->
        {:error, {:stat_dir, reason, blame(dir)}}
    end
  end

  defp blame(dir) do
    parts = Path.split(dir)

    missing =
      1..length(parts)
      |> Enum.map(&(parts |> Enum.take(&1) |> Path.join()))
      |> Enum.find(&(not File.exists?(&1)))

    case missing do
      # Every level exists: the refusal is on `dir` itself (mode, read-only mount, quota).
      nil ->
        %{dir: dir, first_missing: nil, under: dir, under_writable?: writable?(dir)}

      m ->
        %{
          dir: dir,
          first_missing: m,
          under: Path.dirname(m),
          under_writable?: writable?(Path.dirname(m))
        }
    end
  end

  defp writable?(dir) do
    match?({:ok, %File.Stat{access: access}} when access in [:write, :read_write], File.stat(dir))
  end

  defp rm_stale(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:rm_stale, reason}}
    end
  end
end
