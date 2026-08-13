defmodule Fleet.API.ControlRouter do
  @moduledoc """
  The human operator's WRITE door — `POST /api/admin/spawn`, served ONLY on the local AF_UNIX
  control socket (`:lcars_fleet, :api_control_socket`, `~/.lcars/run/api.sock`), never over TCP.

  ## Why a UNIX socket, not TCP loopback

  This is the SAME move the repo already made for the pod-facing MCP transport: a shared HTTP
  loopback was replaced by an AF_UNIX socket because "the identity IS the channel". Here the
  reasoning is the mirror image. `/api/admin/spawn` is the one remaining WRITE (it spawns pods);
  its only legitimate client is `bin/lcars`, run host-side by the human. A pod runs under bwrap
  with `--share-net`, so it SHARES the host network namespace: its `127.0.0.1` is the host's, and
  it can reach any TCP loopback listener — including a no-auth admin endpoint. That is the confused
  deputy: a compromised/injected pod re-obtains the "spawner" capability the MCP tool-gating denies
  it, amplifying claude sessions on the human's subscription; bounded by `max_pods` but
  self-refilling. A UNIX socket closes that BY CONSTRUCTION: the socket file lives under
  `~/.lcars/run/`, which `--tmpfs /home` masks and no bind restores → it is simply not in the
  pod's mount namespace. The boundary is the filesystem, not a firewall or an auth token. The
  human's `lcars` runs host-side and reaches it via `curl --unix-socket`; the pod cannot.

  The READ surface (`/api/health`, `/api/version`, …) and the WS event stream stay on TCP
  (`Fleet.API.Rest` / `Fleet.API.WS`): they are low-risk (a browser dashboard needs TCP, and a
  pod reading them is read-only information disclosure, not the spawn amplification described above).

  ## Contract

  All the admission POLICY lives in `Fleet.API.SpawnAdmission.admit/1` (DTO allowlist, path-safe
  pod_id, loadable cap-profile, host-native refused, fleet-scope singleton free, one-shot brief
  required). This router only maps each verdict to an HTTP status + JSON body. A refusal = NOTHING
  was broadcast (admission precedes emission by construction). Quiescing (shutdown drain) → 503.
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

      {:error, {:forbidden_fields, fields}} ->
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "unauthorized fields on /api/admin/spawn",
            forbidden: Enum.sort(fields)
          })
        )

      {:error, {:invalid_pod_id, value}} ->
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "invalid pod_id (expected [A-Za-z0-9._-], no '..')",
            value: inspect(value)
          })
        )

      {:error, {:invalid_issue_id, value}} ->
        send_resp(
          conn,
          422,
          Jason.encode!(%{error: "invalid issue_id (expected a string)", value: inspect(value)})
        )

      {:error, :brief_required} ->
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "brief required (one-shot cap-profile)",
            reason:
              "one-shot lifetime_scope without `brief`: the pod would leave with no work. Provide `brief`."
          })
        )

      {:error, :missing_cap_profile} ->
        send_resp(conn, 400, ~s|{"error":"cap_profile_name (or role) required"}|)

      {:error, {:cap_profile, name, reason}} ->
        send_resp(
          conn,
          422,
          Jason.encode!(%{error: "unknown cap_profile: #{name}", reason: inspect(reason)})
        )

      {:error, {:role_reserved, name}} ->
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "reserved seat: #{name}",
            reason:
              "the role is declared in the catalogue as a ReservedSeat (kept identity, " <>
                "closed box) — not spawnable until its full CapabilityProfile exists"
          })
        )

      {:error, {:fleet_scope_occupied, name, pod_id}} ->
        send_resp(
          conn,
          409,
          Jason.encode!(%{
            error: "fleet-scope role already running: #{name} (pod #{pod_id})",
            reason:
              "role_index 0 is the fleet-level slot and there is exactly one per fleet. " <>
                "A second pod would be spawned, receive nothing, and escalate on a wake nobody " <>
                "answers. Talk to the running one through its terminal (`lcars attach #{pod_id}`) " <>
                "instead of spawning another."
          })
        )

      {:error, {:host_native_forbidden, name}} ->
        send_resp(
          conn,
          422,
          Jason.encode!(%{
            error: "host-native cap_profile forbidden via /api/admin/spawn: #{name}",
            reason:
              "containment != bwrap — host-native goes through its dedicated path, not the spawn API"
          })
        )
    end
  end

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

  # ── AF_UNIX control-socket listener ──

  @doc """
  Removes a stale socket, starts an embedded Ranch tree linked to the caller,
  and commits readiness only after chmod 0600 succeeds.
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
        # CI-12
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
