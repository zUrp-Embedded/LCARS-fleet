defmodule Fleet.Spawner.Pod.Egress do
  @moduledoc """
  CONNECT proxy for bwrap pods, reached through a per-pod AF_UNIX socket.
  An in-pod relay exposes it on localhost. The isolated network namespace has no
  external route; this permits vendor access without granting CAP_NET_ADMIN.

  Hostnames are checked before host-side DNS resolution. TLS is relayed without
  termination or certificate injection. Plain HTTP requests are refused with 501;
  host refusals and upstream connection errors receive 403.

  Matching is case-insensitive: exact names or `*.` subdomains anchored at the end,
  excluding the bare parent. An empty list permits no hosts. Vendor endpoints belong
  in `Egress.Vendor` declarations; `network: egress` adds profile and converged hosts.

  Explicit `network: open` returns the atom `:open`, accepting any CONNECT host while
  retaining the proxy and network isolation. A literal `*` in a host file cannot
  select that policy. Open access supports human-facing roles whose web destinations
  cannot be listed in advance; it is a per-role choice, logged during provisioning.
  """

  require Logger

  alias Fleet.CapProfile
  alias Fleet.Spawner.Pod.Egress.Vendor

  @connect_re ~r/\ACONNECT ([A-Za-z0-9._-]+):(\d{1,5}) HTTP\/1\.[01]\r?\n/
  @accept "HTTP/1.1 200 Connection Established\r\n\r\n"
  @refuse "HTTP/1.1 403 Forbidden\r\n\r\nConnection blocked by the LCARS egress allowlist\r\n"

  # Distinguish unsupported plain HTTP from a blocked host so callers do not misdiagnose
  # the sandbox’s refusal as destination authorization failure.
  @refuse_method "HTTP/1.1 501 Not Implemented\r\n\r\n" <>
                   "The LCARS pod proxy tunnels CONNECT only — plain HTTP is not proxied.\r\n" <>
                   "This is the SANDBOX refusing, not the destination: nothing was sent.\r\n" <>
                   "A pod installs no system package (apt & co.): ask with the `toolchain_request` " <>
                   "tool; a test suite that needs one is proved by the CI, not in the pod.\r\n"
  @connect_timeout_ms 10_000

  @doc """
  Resolves policy, starts the proxy and returns its socket path.
  Returns `{:ok, nil}` for host containment or an absent socket-base directory.
  Host pods retain the host network; bwrap pods without a proxy have no egress relay.
  """
  @spec provision(String.t(), CapProfile.t(), Path.t()) ::
          {:ok, Path.t() | nil} | {:error, term()}
  def provision(pod_id, cap_profile, launcher_path) do
    path = socket_path(pod_id)

    # bin/fleet normally creates the base. Absence disables provisioning rather than failing spawn.
    cond do
      not CapProfile.bwrap?(cap_profile) ->
        {:ok, nil}

      not File.dir?(Path.dirname(Path.dirname(path))) ->
        {:ok, nil}

      true ->
        provision_socket(pod_id, cap_profile, launcher_path, path)
    end
  end

  defp provision_socket(pod_id, cap_profile, launcher_path, path) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case start(path, note_policy(allowlist(cap_profile, launcher_path), cap_profile),
             pod_id: pod_id
           ) do
        {:ok, listen} ->
          :persistent_term.put({__MODULE__, pod_id}, listen)
          {:ok, path}

        {:error, _} = err ->
          err
      end
    end
  end

  # ⚠ INFO, NOT WARNING, AND THAT IS THE POINT (⚖ user 2026-09-17): every role now declares
  # `network: open`. A warning per pod would fire on every spawn, for a decision that was taken —
  # and a line that always fires stops being read, taking the lines that matter with it. This is a
  # lifecycle fact: the policy this pod runs under, recorded because the absence of blocked-host
  # logs does not explain itself. The day a role is closed again, ITS line changes here.
  defp note_policy(:open, cap_profile) do
    Logger.info(
      "Egress: role #{CapProfile.name(cap_profile)} runs with an OPEN allowlist (`network: open`) " <>
        "— every host is reachable. The pod is still sealed and still leaves through this proxy; " <>
        "what is gone is the host wall."
    )

    :open
  end

  defp note_policy(allowed, cap_profile) do
    Logger.info(
      "Egress: role #{CapProfile.name(cap_profile)} runs behind a host wall " <>
        "(`network: #{CapProfile.network(cap_profile)}`, #{length(allowed)} host(s) allowed)."
    )

    allowed
  end

  @doc """
  Closes the listener and attempts to remove its socket file/directory.
  Returns `:ok` even on filesystem cleanup failure; an unprovisioned pod is a no-op.
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
  Returns vendor hosts by default. `network: egress` adds profile hosts and
  `$LCARS_STORE_ROOT/state/egress.d/<role>.hosts`, deduplicated in that order.
  The state-volume declaration preserves approved additions across image rebuilds.
  `network: open` returns `:open`; the vendor file is still read before policy selection,
  but profile/converged lists do not contribute.
  """
  @spec allowlist(CapProfile.t(), Path.t()) :: [String.t()] | :open
  def allowlist(cap_profile, launcher_path) do
    vendor = Vendor.hosts(launcher_path)

    case CapProfile.network(cap_profile) do
      "open" ->
        :open

      "egress" ->
        Enum.uniq(vendor ++ role_hosts(cap_profile) ++ converged_hosts(cap_profile))

      _vendor_only ->
        # Warn if approved hosts exist but the role’s policy ignores them.
        warn_if_converged_but_sealed(cap_profile)
        vendor
    end
  end

  @doc """
  Returns `<spawner_egress_sock_base>/<pod_id>/sock`, defaulting beneath the runtime root.
  The short per-pod path limits Unix socket length; only the pod’s own directory is bound,
  since sharing the base would expose siblings’ proxy policies.
  """
  @spec socket_path(String.t()) :: Path.t()
  def socket_path(pod_id) when is_binary(pod_id) do
    base =
      Application.get_env(
        :lcars_fleet,
        :spawner_egress_sock_base,
        Path.join(Fleet.Layout.runtime_root(), "egress")
      )

    Path.join([base, pod_id, "sock"])
  end

  defp role_hosts(%CapProfile{spec: spec}) do
    spec
    |> get_in(["scope", "egress_hosts"])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  # Converged files use Vendor.parse’s host/comment grammar. Missing role files are normal;
  # in an existing egress.d, a missing .applied marker warns that convergence is unconfirmed.
  defp converged_hosts(cap_profile) do
    case converged_dir() do
      nil ->
        []

      dir ->
        role = CapProfile.name(cap_profile)
        warn_unless_applied(dir)
        read_hosts(Path.join(dir, role <> ".hosts"))
    end
  end

  # No mounted store/directory means no extra hosts, not a refused spawn.
  defp converged_dir do
    case System.get_env("LCARS_STORE_ROOT") do
      root when is_binary(root) and root != "" ->
        dir = Path.join([root, "state", "egress.d"])
        if File.dir?(dir), do: dir, else: nil

      _unset ->
        nil
    end
  end

  # Read failures are logged and contribute no converged hosts; vendor/profile hosts remain.
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
          "this container. An empty egress list here is NOT the nominal 'nothing approved yet': it is " <>
          "indistinguishable from a converger that never came, a volume never mounted, or a " <>
          "volume purged. The marker is what separates the four."
      )
    end

    :ok
  end

  defp warn_if_converged_but_sealed(cap_profile) do
    with dir when is_binary(dir) <- converged_dir(),
         role = CapProfile.name(cap_profile),
         path = Path.join(dir, role <> ".hosts"),
         true <- File.exists?(path) do
      Logger.warning(
        "Egress: #{path} exists but role #{role} declares network=" <>
          "#{CapProfile.network(cap_profile)} — the converged hosts are IGNORED. Two keys " <>
          "are required: the catalogue grants `network: egress`, the converged file names the " <>
          "hosts. This pod reaches its vendor and nothing else."
      )
    end

    :ok
  end

  @doc """
  Parses a CONNECT line and applies the host policy, independently of socket handling.
  Returns `{:ok, host, port}` or `{:refused, reason}`; no TLS or destination-content inspection.
  """
  @spec decide(binary(), [String.t()] | :open) ::
          {:ok, String.t(), :inet.port_number()} | {:refused, term()}
  def decide(request_line, allowed)
      when is_binary(request_line) and (is_list(allowed) or allowed == :open) do
    case Regex.run(@connect_re, request_line) do
      [_, host, port] ->
        if allowed == :open or allowed?(host, allowed),
          do: {:ok, host, String.to_integer(port)},
          else: {:refused, {:host_not_allowed, host}}

      nil ->
        {:refused, {:not_a_connect_request, String.slice(request_line, 0, 80)}}
    end
  end

  defp refusal_for({:not_a_connect_request, _}), do: @refuse_method
  defp refusal_for(_), do: @refuse

  # A *.parent rule requires a dotted suffix and excludes the bare parent itself.
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
  # Reject overlong paths by name instead of surfacing the kernel’s unhelpful :einval.
  @sun_path_max 100

  @spec start(Path.t(), [String.t()] | :open, keyword()) :: {:ok, port()} | {:error, term()}
  def start(socket_path, allowed, opts \\ [])
      when is_binary(socket_path) and (is_list(allowed) or allowed == :open) do
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

        # Unlinked so an acceptor failure does not kill the Pod process. Closing the listener
        # ends the accept loop; it does not explicitly close already accepted tunnels.
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

  # The host resolver appends its search list to a bare name: on a network whose DNS answers
  # every name under that suffix, a host that does not exist resolves and the wall opens. An IP
  # literal is used as is; a name the hosts file declares (/etc/hosts, a container's `extra_hosts`)
  # connects to that address; any other name is looked up absolute (trailing dot).
  defp upstream_address(host) do
    name = String.to_charlist(host)

    with {:error, _} <- :inet.parse_address(name),
         {:error, _} <- :inet_hosts.gethostbyname(name, :inet) do
      String.to_charlist(String.trim_trailing(host, ".") <> ".")
    else
      {:ok, {:hostent, _name, _aliases, :inet, 4, [ip | _]}} -> ip
      {:ok, ip} -> ip
    end
  end

  defp serve(client, allowed, pod_id) do
    with {:ok, line} <- :gen_tcp.recv(client, 0, @connect_timeout_ms),
         {:ok, host, port} <- decide(line, allowed),
         {:ok, upstream} <-
           :gen_tcp.connect(
             upstream_address(host),
             port,
             [:binary, active: false],
             @connect_timeout_ms
           ) do
      :ok = :gen_tcp.send(client, @accept)
      splice(client, upstream)
    else
      {:refused, reason} ->
        Logger.warning("Egress[#{pod_id}]: REFUSED #{inspect(reason)}")
        _ = :gen_tcp.send(client, refusal_for(reason))
        :gen_tcp.close(client)

      {:error, reason} ->
        Logger.warning("Egress[#{pod_id}]: upstream failed (#{inspect(reason)})")
        _ = :gen_tcp.send(client, @refuse)
        :gen_tcp.close(client)
    end
  end

  # Relay opaque TLS bytes in both directions; close both sockets on either-side failure.
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
