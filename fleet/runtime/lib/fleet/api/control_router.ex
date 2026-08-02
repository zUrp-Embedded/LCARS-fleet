defmodule Fleet.API.ControlRouter do
  @moduledoc """
  The human operator's WRITE door — `POST /api/admin/spawn`, served ONLY on the local AF_UNIX
  control socket (`:fleet_api, :control_socket`, `~/.lcars/run/api.sock`), never over TCP.

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
  pod_id, loadable cap-profile, host-native refused, one-shot brief required). This router only maps
  each verdict to an HTTP status + JSON body. A refusal = NOTHING was broadcast (admission
  precedes emission by construction). Quiescing (shutdown drain) → 503.

  **Last revised**: 2026-08-02
  """

  use Plug.Router

  require Logger

  plug(:match)
  # EXPLICIT body bound (Plug default 8 MB is implicit). 1 MB >> the biggest legitimate POST
  # (admin/spawn: cap-profile + brief).
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, length: 1_048_576)
  plug(:dispatch)

  post "/api/admin/spawn" do
    # "New operator pod" chokepoint: refused during a shutdown drain (Fleet.Shutdown.Quiesce).
    # REST is the ONLY producer of the `admin.spawn.request` event → gating here fully covers
    # top-level pod admission.
    if Fleet.Shutdown.Quiesce.quiescing?() do
      send_resp(conn, 503, ~s|{"error":"quiescing — shutdown drain in progress"}|)
    else
      do_admin_spawn(conn)
    end
  end

  match _ do
    send_resp(conn, 404, ~s|{"error":"not found"}|)
  end

  # ADMISSION VERDICT → HTTP mapping. Moved verbatim from `Fleet.API.Rest` (the write left TCP):
  # the WHY of each guard lives in `Fleet.API.SpawnAdmission.admit/1`.
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
    # The 202 must not LIE. `broadcast/1` goes over the lossy Bus (D1) and returns `:ok` even with
    # NO subscriber — so a dead/unsubscribed PublishConsumer (its restart window, a crash loop, the
    # gate off) made this door answer `202 queued` into the void: the operator believed a pod was on
    # the way, nothing took the command, and there is NO forge net for the admin-spawn path (unlike
    # the step rail's reconciliation). Unlike the work-item/pod.completed broadcasts, this command has
    # no durable backing, so we PRE-FLIGHT the rail's readiness (the same authority the readiness probe
    # reads) and refuse with 503 when the subscriber is not live — the 202 now means a live consumer
    # exists to take it. The residual TOCTOU (the consumer dying in the microseconds between the check
    # and the broadcast) is negligible against the real failure mode it closes (a consumer down for a
    # whole restart window). Seam `:spawn_dispatch_status_fun` for tests.
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
      :fleet_api,
      :spawn_dispatch_status_fun,
      &Fleet.Spawner.Application.spawn_dispatch_status/0
    )
  end

  # ── AF_UNIX control-socket listener ──

  @doc """
  Child-spec start for the AF_UNIX listener serving this router. Removes any stale socket file
  BEFORE binding (a previous instance's socket is not auto-removed on close → a restart would
  hit `eaddrinuse`; same reason as the MCP cold-boot sweep) and tightens the file to `0600`
  (defense-in-depth — the real boundary is the pod's mount namespace, which never contains the
  file). Returns `{:ok, pid}` of the EMBEDDED ranch tree, LINKED to the calling supervisor.

  The tree MUST be embedded — `Plug.Cowboy.child_spec` start, never `Plug.Cowboy.http`. The
  obvious `http/3` parks the listener under ranch's OWN application supervisor: the pid returned
  here gets a foreign parent, so our supervisor's shutdown signal has no authority over it (a
  supervisor only obeys its real parent) and the stop hangs on a 'DOWN' that never comes
  (`type: :supervisor` → shutdown `:infinity`), down to the launcher's fallback kill. Embedded,
  the ranch sup is a true child: the shutdown drains and the BEAM dies clean. (`Listener.cowboy_child`
  is not used on purpose: BindAddress governs NETWORK surfaces — an AF_UNIX path is not one — and
  the stale-socket rm + chmod must run at every (re)start, hence this MFA.)
  """
  @spec start_control_listener(Path.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_control_listener(sock, opts \\ []) when is_binary(sock) do
    # `chmod_fun` (test seam, default `&File.chmod/2`) — lets a test force the chmod to FAIL and prove the
    # fail-closed readiness (CI-12). The MFA child-spec start `[sock]` keeps working (opts defaults).
    chmod_fun = Keyword.get(opts, :chmod_fun, &File.chmod/2)

    _ = File.mkdir_p(Path.dirname(sock))
    _ = File.rm(sock)

    %{start: {m, f, a}} =
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: __MODULE__,
        # Unique per start, never a stable name: ranch keys transport options by ref in the
        # global `ranch_server` and clears them from an async 'DOWN' — a same-ref restart can
        # lose its own options to its predecessor's cleanup and bind elsewhere. The bind is
        # synchronous, so waiting for the socket to appear would hide that, not fix it.
        # Nothing addresses this listener by ref (the embedded tree stops through its owner).
        options: [
          ip: {:local, sock},
          port: 0,
          ref: {__MODULE__, System.unique_integer([:positive])}
        ]
      )

    case apply(m, f, a) do
      {:ok, pid} = ok ->
        # CI-12 (audit integrite 2026-07-20): the chmod is part of the READINESS COMMIT, not an
        # afterthought. This AF_UNIX socket is the ONLY admin WRITE door; `LCARS_API_SOCK` is overridable
        # and confidentiality vs OTHER host users rests on the 0600 mode (the pod mount-ns isolation covers
        # pods, not host peers). A swallowed chmod would announce "host-only" while the file kept its default
        # mode — a FALSE readiness. On failure: tear the listener down + remove the socket + return an error
        # (a host-readable admin door is NEVER announced ready).
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

            # The just-bound ranch tree is LINKED to us → unlink BEFORE shutting it down, else its exit
            # would take us with it.
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

  @doc "Child spec for the control-socket listener (`:fleet_api, :control_socket`)."
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
