defmodule Fleet.Spawner.Pod.Egress do
  @moduledoc """
  The pod's ONLY way out to the network — a per-pod CONNECT proxy on an AF_UNIX socket, with a
  hostname allowlist.

  ## Why a proxy and not a firewall

  A pod is sealed with `bwrap --unshare-all` (no `--share-net`), so its namespace has no route to
  anywhere. That is total, and total is the problem: the vendor's API is on the other side of the
  same pipe as the open web. Filtering egress by host inside a network namespace needs
  `CAP_NET_ADMIN`, which this runtime does not have and must not want — it runs under the human's
  own UID.

  So the traffic leaves through the FILESYSTEM instead: a unix socket bound into the sandbox, a
  relay inside turning `localhost:<port>` into that socket, and this proxy on the other end
  deciding host by host. A unix socket is a mount, and mounts are what an unprivileged sandbox is
  made of. (Same shape as Anthropic's own `sandbox-runtime`, which is where the pattern was read
  rather than invented.)

  ## Why the allowlist is DATA and names no vendor

  No endpoint is written in this module, and none may be — not even in prose, because a host spelled
  in a comment is a host a reader copies. They come from the vendor that needs them
  (`Fleet.Spawner.Pod.Egress.Vendor`), so adding a second vendor is adding its launcher and its
  declaration — never editing a list in the middle of the runtime. A role that legitimately browses
  declares its own hosts on top; every other role gets the vendor's alone.

  ## What it enforces, and what it deliberately does not

  It reads the `CONNECT host:port` line and answers `200` or `403` on the host. It does NOT
  terminate TLS: no certificate is injected into the pod, and this proxy never sees a byte of the
  conversation it relays — it decides WHERE, never WHAT. A plain (non-CONNECT) request is refused
  rather than proxied, because HTTP in clear is not a thing this fleet needs and a second parser is
  a second place to be wrong.

  DNS DISAPPEARS FROM THE POD, and that is a property rather than a side effect: with no network
  namespace there is no resolver, so a hostname is only ever resolved HERE, after the allowlist has
  accepted it. Nothing in the pod can look a name up, which is one exfiltration channel that stops
  existing rather than being watched.

  ## Fail-closed, everywhere

  An empty allowlist refuses everything (a pod with no declared egress reaches nothing, rather than
  everything). A malformed request line is refused. A host that is not an exact match is refused —
  no suffix matching, no wildcards. A rule that has to reason about where a domain ends is a rule
  that will be wrong once, and the attacker only needs it to be wrong once.
  """

  require Logger

  @connect_re ~r/\ACONNECT ([A-Za-z0-9._-]+):(\d{1,5}) HTTP\/1\.[01]\r?\n/
  @accept "HTTP/1.1 200 Connection Established\r\n\r\n"
  @refuse "HTTP/1.1 403 Forbidden\r\n\r\nConnection blocked by the LCARS egress allowlist\r\n"
  @connect_timeout_ms 10_000

  @doc """
  Decides one CONNECT line against an allowlist.

  Split out of the socket handling because it is the WALL, and a wall you cannot call without a
  socket is a wall nobody tests by mutation. `{:ok, host, port}` or `{:refused, reason}`.
  """
  @spec decide(binary(), [String.t()]) ::
          {:ok, String.t(), :inet.port_number()} | {:refused, term()}
  def decide(request_line, allowed) when is_binary(request_line) and is_list(allowed) do
    case Regex.run(@connect_re, request_line) do
      [_, host, port] ->
        # EXACT match, downcased on both sides — a host is a name, not a pattern.
        if String.downcase(host) in Enum.map(allowed, &String.downcase/1),
          do: {:ok, host, String.to_integer(port)},
          else: {:refused, {:host_not_allowed, host}}

      nil ->
        {:refused, {:not_a_connect_request, String.slice(request_line, 0, 80)}}
    end
  end

  @doc """
  Starts the per-pod proxy on `socket_path`, serving `allowed` hosts. Returns the listening socket,
  which the caller closes to stop accepting.

  The socket file is removed first: a stale one from a pod that died without releasing it would
  make `listen` fail on an address that belongs to nobody.
  """
  # AF_UNIX caps a path at ~108 bytes, kernel-side, and the failure is a bare `:einval` that names
  # nothing. Measured the first time this ran: an ExUnit tmp_dir blew the limit and the error said
  # only "invalid argument". Real pod sockets live under a short root for exactly this reason (the
  # MCP socket already does); a caller that composes a long one gets told WHICH constraint it hit.
  @sun_path_max 100

  @spec start(Path.t(), [String.t()], keyword()) :: {:ok, port()} | {:error, term()}
  def start(socket_path, allowed, opts \\ []) when is_binary(socket_path) and is_list(allowed) do
    if byte_size(socket_path) > @sun_path_max do
      {:error, {:egress_socket_path_too_long, byte_size(socket_path), @sun_path_max}}
    else
      do_start(socket_path, allowed, opts)
    end
  end

  defp do_start(socket_path, allowed, opts) do
    _ = File.rm(socket_path)
    _ = File.mkdir_p(Path.dirname(socket_path))

    case :gen_tcp.listen(0, [
           :binary,
           ifaddr: {:local, socket_path},
           active: false,
           reuseaddr: true,
           packet: :raw
         ]) do
      {:ok, listen} ->
        pod_id = Keyword.get(opts, :pod_id, "?")
        spawn_link(fn -> accept_loop(listen, allowed, pod_id) end)
        {:ok, listen}

      {:error, reason} ->
        {:error, {:egress_listen_failed, socket_path, reason}}
    end
  end

  defp accept_loop(listen, allowed, pod_id) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        pid = spawn(fn -> serve(client, allowed, pod_id) end)
        :ok = :gen_tcp.controlling_process(client, pid)
        accept_loop(listen, allowed, pod_id)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("Egress[#{pod_id}]: accept failed (#{inspect(reason)}) — loop ends")
        :ok
    end
  end

  defp serve(client, allowed, pod_id) do
    with {:ok, line} <- :gen_tcp.recv(client, 0, @connect_timeout_ms),
         {:ok, host, port} <- decide(line, allowed),
         # The 4th argument of `:gen_tcp.connect/4` is a TIMEOUT, not options: passing a keyword
         # list there is a badarg, so the server process died and the pod saw a closed socket
         # instead of a named refusal — a wall that crashes reads exactly like a broken network.
         {:ok, upstream} <-
           :gen_tcp.connect(
             String.to_charlist(host),
             port,
             [:binary, active: false],
             @connect_timeout_ms
           ) do
      :ok = :gen_tcp.send(client, @accept)
      splice(client, upstream)
    else
      {:refused, reason} ->
        # The refusal is LOGGED, always: a wall that blocks silently is indistinguishable from a
        # network that is merely broken, and the pod will report the second.
        Logger.warning("Egress[#{pod_id}]: REFUSED #{inspect(reason)}")
        _ = :gen_tcp.send(client, @refuse)
        :gen_tcp.close(client)

      {:error, reason} ->
        Logger.warning("Egress[#{pod_id}]: upstream failed (#{inspect(reason)})")
        _ = :gen_tcp.send(client, @refuse)
        :gen_tcp.close(client)
    end
  end

  # Bytes both ways until either side hangs up. Two processes rather than one select loop: the
  # relay carries TLS records it cannot interpret, so there is nothing to be clever about.
  defp splice(a, b) do
    pid = self()
    spawn(fn -> pump(b, a, pid) end)
    pump(a, b, nil)
  end

  defp pump(from, to, _owner) do
    case :gen_tcp.recv(from, 0) do
      {:ok, data} ->
        case :gen_tcp.send(to, data) do
          :ok -> pump(from, to, nil)
          {:error, _} -> close_both(from, to)
        end

      {:error, _} ->
        close_both(from, to)
    end
  end

  defp close_both(a, b) do
    _ = :gen_tcp.close(a)
    _ = :gen_tcp.close(b)
    :ok
  end
end
