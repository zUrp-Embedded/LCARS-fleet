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
  the match is an exact name, or a `*.` SUBDOMAIN rule anchored on the right. Never a `contains`,
  never a bare suffix: the anchor is what stops `sentry.io.attacker.net` from passing `*.sentry.io`.
  """

  require Logger

  alias Fleet.Spawner.Pod.Egress.Vendor

  @connect_re ~r/\ACONNECT ([A-Za-z0-9._-]+):(\d{1,5}) HTTP\/1\.[01]\r?\n/
  @accept "HTTP/1.1 200 Connection Established\r\n\r\n"
  @refuse "HTTP/1.1 403 Forbidden\r\n\r\nConnection blocked by the LCARS egress allowlist\r\n"

  # A NON-CONNECT REQUEST IS NOT A BLOCKED HOST, AND ANSWERING BOTH WITH 403 COST A DIAGNOSIS.
  # `HTTP(S)_PROXY` covers everything a pod emits, and a plain `http://` origin makes the client
  # send an absolute-URI GET rather than a tunnel request. This proxy only tunnels, so that GET was
  # answered "blocked by the allowlist" — measured 2026-08-11: an architect's `git fetch` on the
  # forge got it, read it as the FORGE refusing, and wrote a diagnosis concluding the fleet account
  # was not a collaborator of the repo. The permissions were right. The sandbox was talking.
  #
  # 501 says WHOSE refusal it is and that nothing left the box. Read it as an answer to "should a
  # pod reach this over the network at all": its project arrives through its mounts, and the forge
  # through its MCP tools.
  @refuse_method "HTTP/1.1 501 Not Implemented\r\n\r\n" <>
                   "The LCARS pod proxy tunnels CONNECT only — plain HTTP is not proxied.\r\n" <>
                   "This is the SANDBOX refusing, not the destination: nothing was sent.\r\n"
  @connect_timeout_ms 10_000

  @doc """
  Provisions this pod's egress: resolves the allowlist, starts the proxy, returns the socket path.

  `{:ok, nil}` when the pod gets no proxy — a host-containment pod keeps the machine's own network
  (there is no namespace to seal), and asking it to route through a socket would break it for
  nothing.

  The ALLOWLIST is composed here and nowhere else: the vendor's declared hosts, plus the role's own
  only when its profile says `network: egress`. Fail-closed by construction — a profile that says
  nothing gets the vendor's list, which is what a pod needs to work and nothing more.
  """
  @spec provision(String.t(), Fleet.CapProfile.t(), Path.t()) ::
          {:ok, Path.t() | nil} | {:error, term()}
  def provision(pod_id, cap_profile, launcher_path) do
    path = socket_path(pod_id)

    # THE BASE MUST EXIST AND BE OURS TO WRITE. `bin/fleet_v2` creates it at start; if it is not
    # there, this fleet was not launched through its own launcher and there is nothing to
    # provision into. Declining QUIETLY is the difference between "no egress here" and an error
    # logged once per pod for a condition that is not a failure — a rail that shouts on a
    # configuration it cannot see is a rail nobody reads.
    cond do
      not Fleet.CapProfile.bwrap?(cap_profile) ->
        {:ok, nil}

      not File.dir?(Path.dirname(Path.dirname(path))) ->
        {:ok, nil}

      true ->
        provision_socket(pod_id, cap_profile, launcher_path, path)
    end
  end

  defp provision_socket(pod_id, cap_profile, launcher_path, path) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case start(path, allowlist(cap_profile, launcher_path), pod_id: pod_id) do
        {:ok, listen} ->
          :persistent_term.put({__MODULE__, pod_id}, listen)
          {:ok, path}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Closes this pod's proxy and removes its socket. Idempotent: a pod that never had one is a no-op.
  """
  @spec release(String.t()) :: :ok
  def release(pod_id) when is_binary(pod_id) do
    case :persistent_term.get({__MODULE__, pod_id}, nil) do
      nil ->
        :ok

      listen ->
        _ = :gen_tcp.close(listen)
        _ = :persistent_term.erase({__MODULE__, pod_id})
        _ = File.rm(socket_path(pod_id))
        _ = File.rmdir(Path.dirname(socket_path(pod_id)))
        :ok
    end
  end

  @doc """
  The hosts this pod may reach: the vendor's, plus — only when the role declares `network: egress` —
  the ones its cap-profile carries AND the ones a human APPROVED, converged onto the state volume.

  THREE SOURCES, TWO KEYS, AND NEITHER KEY IS ENOUGH. `network` says WHO may leave; the two lists
  say WHERE. A role that says nothing gets the vendor's list and nothing else, whatever sits on the
  volume — the fail-closed default holds at every layer rather than at one.

  WHY A THIRD SOURCE AT ALL, and it is not a convenience: the first two live IN THE IMAGE (the
  vendor declaration beside the launcher, the cap-profile inside the catalogue). A rebuild restores
  them as they were at build time, so an opening a human signed would be ERASED at the next nuke —
  silently, since a pod that reaches nothing looks exactly like a pod nobody opened. The converged
  file lives on the state volume, which survives, and that is the whole reason it exists.
  """
  @spec allowlist(Fleet.CapProfile.t(), Path.t()) :: [String.t()]
  def allowlist(cap_profile, launcher_path) do
    vendor = Vendor.hosts(launcher_path)

    case Fleet.CapProfile.network(cap_profile) do
      "egress" ->
        Enum.uniq(vendor ++ role_hosts(cap_profile) ++ converged_hosts(cap_profile))

      _vendor_only ->
        # THE FILE IS NOT READ HERE — but its PRESENCE is worth a word, because this exact pair
        # (an approved list, a role that cannot use it) is the one shape a human cannot diagnose
        # from the pod side: the merge landed, the file is there, and the pod still reaches nothing.
        warn_if_converged_but_sealed(cap_profile)
        vendor
    end
  end

  @doc """
  This pod's socket path — the SAME shape as its MCP socket, and for the same reason: a per-pod dir
  under a short base, so `sun_path` holds whatever the pod_id looks like. The base is never bound
  into a sandbox; a sibling's socket is a sibling's allowlist.
  """
  @spec socket_path(String.t()) :: Path.t()
  def socket_path(pod_id) when is_binary(pod_id) do
    base =
      Application.get_env(
        :lcars_fleet,
        :spawner_egress_sock_base,
        # DERIVE, plus recopie : `Fleet.Layout` declare la racine runtime depuis le 2026-08-28.
        # Spawner a Layout dans ses deps, donc l'arete est legale et le litteral disparait.
        Path.join(Fleet.Layout.runtime_root(), "egress")
      )

    Path.join([base, pod_id, "sock"])
  end

  defp role_hosts(%Fleet.CapProfile{spec: spec}) do
    spec
    |> get_in(["scope", "egress_hosts"])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  # ── The CONVERGED source ────────────────────────────────────────────────────────────────────
  #
  # `$LCARS_STORE_ROOT/state/egress.d/<role>.hosts`, one hostname per line, `#` comments — the SAME
  # grammar as the vendor declaration, parsed by the same function, because two parsers for one file
  # format is two places to disagree about what a comment is.
  #
  # THE ROOT IS READ FROM THE ENVIRONMENT AND NEVER DECLARED HERE. The compose owns the path
  # (`LCARS_STORE_ROOT`) and `deploy/lib/store.sh` owns the volume names. Re-deriving it here would
  # make two truths for one place, which is the defect this split exists to prevent.
  #
  # ABSENT IS SILENT, AND THAT IS DELIBERATE — but it is not the same silence as the vendor's.
  # There, a missing file is a WIRING HOLE and shouts. Here, a missing file is the NOMINAL state of
  # a box where nobody has approved anything yet. Two absences, two gravities.
  #
  # WHICH IS WHY THE MARKER EXISTS. Silence alone would cover five states, four of them faults:
  # nothing approved (nominal) · the converger never ran · the volume is not mounted · the volume
  # was purged · the path or role name is wrong. All render the same nothing, then a REFUSED on the
  # first call. `.applied` (written by the converger, carrying the SHA it applied) separates the
  # nominal silence from the four failures: marker present + no hosts = normal; marker absent = the
  # converger never came through here, and THAT is worth saying once.
  defp converged_hosts(cap_profile) do
    case converged_dir() do
      nil ->
        []

      dir ->
        role = Fleet.CapProfile.name(cap_profile)
        warn_unless_applied(dir)
        read_hosts(Path.join(dir, role <> ".hosts"))
    end
  end

  # The converged directory, or `nil` when this box has no store mounted (DR-023: a disabled
  # feature is not a precondition — no store means no extra hosts, never a refused spawn).
  defp converged_dir do
    case System.get_env("LCARS_STORE_ROOT") do
      root when is_binary(root) and root != "" ->
        dir = Path.join([root, "state", "egress.d"])
        if File.dir?(dir), do: dir, else: nil

      _unset ->
        nil
    end
  end

  # UNREADABLE IS NOT EMPTY. A file that exists and cannot be read is a fault, and returning the
  # vendor list quietly would render it as "nobody approved anything" — a partial allowlist that
  # looks like a nominal one is the failure this whole rail is built to refuse.
  defp read_hosts(path) do
    case File.read(path) do
      {:ok, body} ->
        Vendor.parse(body)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.error(
          "Egress: converged host file #{path} is present but UNREADABLE (#{inspect(reason)}) — " <>
            "this pod gets the vendor list ONLY. An approval may be in force and not applied."
        )

        []
    end
  end

  defp warn_unless_applied(dir) do
    marker = Path.join(dir, ".applied")

    unless File.exists?(marker) do
      Logger.warning(
        "Egress: #{dir} carries no `.applied` marker — the toolchain converger has never run on " <>
          "this box. An empty egress list here is NOT the nominal 'nothing approved yet': it is " <>
          "indistinguishable from a converger that never came, a volume never mounted, or a " <>
          "volume purged. The marker is what separates the four."
      )
    end

    :ok
  end

  # A converged file for a role that is not `egress`: the approval landed and does nothing.
  # Named on BOTH facts, because either alone sends the reader to the wrong side.
  defp warn_if_converged_but_sealed(cap_profile) do
    with dir when is_binary(dir) <- converged_dir(),
         role = Fleet.CapProfile.name(cap_profile),
         path = Path.join(dir, role <> ".hosts"),
         true <- File.exists?(path) do
      Logger.warning(
        "Egress: #{path} exists but role #{role} declares network=" <>
          "#{Fleet.CapProfile.network(cap_profile)} — the converged hosts are IGNORED. Two keys " <>
          "are required: the catalogue grants `network: egress`, the converged file names the " <>
          "hosts. This pod reaches its vendor and nothing else."
      )
    end

    :ok
  end

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
        if allowed?(host, allowed),
          do: {:ok, host, String.to_integer(port)},
          else: {:refused, {:host_not_allowed, host}}

      nil ->
        {:refused, {:not_a_connect_request, String.slice(request_line, 0, 80)}}
    end
  end

  # Which refusal the client gets, and the two are not interchangeable — cf. `@refuse_method`.
  defp refusal_for({:not_a_connect_request, _}), do: @refuse_method
  defp refusal_for(_), do: @refuse

  # Exact name, or a `*.` prefix that is a SUBDOMAIN rule anchored on the right — never a
  # `contains`. The first version refused every pattern on the grounds that "a rule reasoning about
  # where a domain ends will be wrong once"; true of a naive suffix test, and wrong as an argument
  # against any pattern at all: the vendor's own error reporting needs `*.sentry.io` and
  # `*.ingest.us.sentry.io`, so a matcher without subdomains cannot express the published list.
  #
  # `*.sentry.io` accepts `x.sentry.io`, and refuses `sentry.io.attacker.net` (the dot anchors the
  # END of the candidate) as well as bare `sentry.io` (declare it too if it is wanted — a wildcard
  # states "under this", not "this"). Pinned by mutation.
  defp allowed?(host, allowed) do
    h = String.downcase(host)

    Enum.any?(allowed, fn rule ->
      case String.downcase(rule) do
        "*." <> parent -> String.ends_with?(h, "." <> parent)
        exact -> h == exact
      end
    end)
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

    case :gen_tcp.listen(0, [
           :binary,
           ifaddr: {:local, socket_path},
           active: false,
           reuseaddr: true,
           packet: :raw
         ]) do
      {:ok, listen} ->
        pod_id = Keyword.get(opts, :pod_id, "?")

        # UNLINKED, deliberately. `spawn_link` from `provision/3` runs inside the POD's process, so
        # an acceptor dying abnormally would take the pod down with it — a proxy failing is a pod
        # that cannot reach its vendor, which is bad; a proxy failing that KILLS the pod is worse
        # and looks like something else entirely. Nothing leaks either way: `release/1` closes the
        # listener, and `accept_loop` ends on `{:error, :closed}`.
        spawn(fn -> accept_loop(listen, allowed, pod_id) end)
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
        _ = :gen_tcp.send(client, refusal_for(reason))
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
