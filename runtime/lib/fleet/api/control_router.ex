defmodule Fleet.API.ControlRouter do
  @moduledoc """
  Routes POST /api/admin/spawn on the configured AF_UNIX control socket.
  There is no HTTP authentication. Mode 0600 restricts access by UID; bwrap pods
  cannot see the default ~/.lcars/run socket when /home is masked and no bind restores
  it. This mount isolation is independent of network isolation and does not apply
  automatically to host-native profiles or arbitrary configured socket paths.

  Quiescence returns 503. SpawnAdmission checks the request before emission;
  refusals map to 400/409/422. A dispatch-readiness check precedes broadcast.
  A 202 acknowledges successful emission, not durable queuing or pod creation.
  """

  use Plug.Router

  require Logger

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, length: 1_048_576)
  plug(:dispatch)

  post "/api/admin/spawn" do
    if Fleet.Shutdown.Quiesce.quiescing?() do
      send_resp(conn, 503, ~s|{"error":"quiescing — shutdown drain in progress"}|)
    else
      do_admin_spawn(conn)
    end
  end

  match _ do
    send_resp(conn, 404, ~s|{"error":"not found"}|)
  end

  defp do_admin_spawn(conn) do
    raw = conn.body_params || %{}

    case Fleet.API.SpawnAdmission.admit(raw) do
      {:ok, payload} ->
        do_broadcast_spawn(conn, payload)

      {:error, cause} ->
        {status, corps} = admission_refusal(cause)
        send_resp(conn, status, Jason.encode!(corps))
    end
  end

  # Refusal reasons should help the operator act, especially when a fleet slot is occupied.
  defp admission_refusal({:forbidden_fields, fields}),
    do: {422, %{error: "unauthorized fields on /api/admin/spawn", forbidden: Enum.sort(fields)}}

  defp admission_refusal({:invalid_pod_id, value}),
    do:
      {422, %{error: "invalid pod_id (expected [A-Za-z0-9._-], no '..')", value: inspect(value)}}

  defp admission_refusal({:invalid_issue_id, value}),
    do: {422, %{error: "invalid issue_id (expected a string)", value: inspect(value)}}

  defp admission_refusal(:brief_required),
    do:
      {422,
       %{
         error: "brief required (one-shot cap-profile)",
         reason:
           "one-shot lifetime_scope without `brief`: the pod would leave with no work. Provide `brief`."
       }}

  defp admission_refusal(:missing_cap_profile),
    do: {400, %{error: "cap_profile_name (or role) required"}}

  defp admission_refusal({:cap_profile, name, reason}),
    do: {422, %{error: "unknown cap_profile: #{name}", reason: inspect(reason)}}

  defp admission_refusal({:role_reserved, name}),
    do:
      {422,
       %{
         error: "reserved seat: #{name}",
         reason:
           "the role is declared in the catalogue as a ReservedSeat (kept identity, " <>
             "closed box) — not spawnable until its full CapabilityProfile exists"
       }}

  defp admission_refusal({:fleet_scope_occupied, name, pod_id}),
    do:
      {409,
       %{
         error: "fleet-scope role already running: #{name} (pod #{pod_id})",
         reason:
           "role_index 0 is the fleet-level slot and there is exactly one per fleet. " <>
             "A second pod would be spawned, receive nothing, and escalate on a wake nobody " <>
             "answers. Talk to the running one through its terminal (`lcars attach #{pod_id}`) " <>
             "instead of spawning another."
       }}

  defp admission_refusal({:host_native_forbidden, name}),
    do:
      {422,
       %{
         error: "host-native cap_profile forbidden via /api/admin/spawn: #{name}",
         reason:
           "containment != bwrap — host-native goes through its dedicated path, not the spawn API"
       }}

  # Readiness reduces broadcasts to an absent/unsubscribed consumer. It cannot close
  # the race where the consumer dies after this check: no durable command outbox exists.
  # PublishConsumer attempts spawn.failed reporting for handled failures; that is not
  # a delivery guarantee for every acknowledged request.
  defp do_broadcast_spawn(conn, payload) do
    case dispatch_status_fun().() do
      {:degraded, info} ->
        Logger.warning(
          "ControlRouter: /api/admin/spawn refused 503 — spawn rail degraded (#{inspect(info)})"
        )

        send_resp(
          conn,
          503,
          Jason.encode!(%{error: "spawn dispatch rail unavailable", detail: info})
        )

      {:operational, _} ->
        case Fleet.API.SpawnAdmission.broadcast(payload) do
          :ok -> send_resp(conn, 202, ~s|{"status":"queued"}|)
          {:error, reason} -> send_resp(conn, 400, Jason.encode!(%{error: inspect(reason)}))
        end
    end
  end

  defp dispatch_status_fun do
    Application.get_env(
      :lcars_fleet,
      :api_spawn_dispatch_status_fun,
      &Fleet.Spawner.Application.spawn_dispatch_status/0
    )
  end

  @doc """
  Removes any existing path, starts a linked Ranch tree, then chmods the socket to
  0600. Returns success only after chmod succeeds. A returned chmod error unlinks,
  signals shutdown and attempts removal; it does not wait for termination. Directory
  creation/removal failures are ignored; binding precedes permission tightening.
  """
  @spec start_control_listener(Path.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_control_listener(sock, opts \\ []) when is_binary(sock) do
    chmod_fun = Keyword.get(opts, :chmod_fun, &File.chmod/2)

    _ = File.mkdir_p(Path.dirname(sock))
    _ = File.rm(sock)

    %{start: {m, f, a}} =
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: __MODULE__,
        # A unique ref isolates this start from its predecessor's async Ranch cleanup.
        options: [
          ip: {:local, sock},
          port: 0,
          ref: {__MODULE__, System.unique_integer([:positive])}
        ]
      )

    case apply(m, f, a) do
      {:ok, pid} = ok ->
        case chmod_fun.(sock, 0o600) do
          :ok ->
            Logger.info(
              "ControlRouter: admin control socket bound at #{sock} (AF_UNIX, host-only)"
            )

            ok

          {:error, reason} ->
            Logger.error(
              "ControlRouter: admin control socket #{sock} bound but chmod 0600 FAILED " <>
                "(#{inspect(reason)}) — tearing the listener down + removing the socket (a host-readable " <>
                "admin door is never announced ready)"
            )

            # Unlink before deliberately shutting down the linked child.
            Process.unlink(pid)
            Process.exit(pid, :shutdown)
            _ = File.rm(sock)
            {:error, {:chmod_failed, reason}}
        end

      {:error, reason} = err ->
        Logger.error(
          "ControlRouter: FAILED to bind admin control socket #{sock}: #{inspect(reason)}"
        )

        err
    end
  end

  @doc "Child spec for the control-socket listener (`:lcars_fleet, :api_control_socket`)."
  @spec child_spec(Path.t()) :: Supervisor.child_spec()
  def child_spec(sock) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_control_listener, [sock]},
      type: :supervisor,
      restart: :permanent
    }
  end
end
