defmodule Fleet.API.Application do
  @moduledoc """
  Superviseur de domaine (ex-callback Application de l'app umbrella — collapse Z2
  migration 2026-07-12 ; nom conservé pour zéro churn de références).

  Domain supervisor `fleet_api`.

  Starts the Cowboy listener (per-human port, bin/fleet_v2) with dispatch:

    - `/ws` → `Fleet.API.WS` (WebSocket handler)
    - `/_*` → `Fleet.API.Rest` (Plug.Router REST)

  ## Configuration

    * `:fleet_api, :http_port` — HTTP port (laid down by runtime.exs from FLEET_API_PORT, per-human; absent → fail-loud)
    * `:fleet_api, :start_listener` — boolean (default `true`).
      Tests can set it to `false` to start Cowboy manually.

  ## Strategy

  `:one_for_one` — Cowboy listener restart `:permanent`.
  Pre-registration of event atoms (created at compile-time, not derived from external input → no atom-exhaustion DoS leak).
  """

  use Supervisor

  # NB atom `admin.spawn.request`: created at compile-time by its real emission site —
  # `SpawnAdmission` (`Bus.emit(:api, :"admin.spawn.request", …)`, the literal atom as 2nd arg;
  # moved there from rest.ex at the C4 split) — no need for a dedicated pre-registration
  # attribute in this application.

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    children = listener_children()

    # F4 (E1): 3/60 intensity EXPLICIT (event_router/task_queue doctrine — 3/5 OTP too tight for a blip; the window is a CHOICE).
    opts = [strategy: :one_for_one, max_restarts: 3, max_seconds: 60]

    Supervisor.init(children, opts)
  end

  @doc """
  Post-boot side effects — called by `Fleet.Application` AFTER the root
  `Supervisor.start_link` returned `{:ok, _}` (i.e. the WHOLE fleet is up, this
  domain's Cowboy listener included). Currently: the build-info boot trace.
  Total — never raises.

  (The sd_notify `READY=1` branch was REMOVED (acte4 A-14): systemd deployment
  is retired (cf. `etc/README.md`), the fleet is launched by a human via
  `bin/fleet_v2` → `NOTIFY_SOCKET` is never set and the whole gen_udp branch
  was dead ceremony. If systemd ever returns, reintroduce a notify step HERE —
  the "never signal READY before the full fleet is up" placement is the invariant.)
  """
  def post_boot do
    log_build_info()
    :ok
  end

  # Boot trace: the version of the served build, readable in the logs of the
  # running fleet ("which commit is running?" observable, not deduced). Total —
  # `BuildInfo.current/0` never raises. Memoized: this first call at boot
  # fills the cache (a single `git` over the whole life of the BEAM).
  defp log_build_info do
    info = Fleet.API.BuildInfo.current()
    dirty = if info.dirty, do: "-dirty", else: ""
    require Logger

    Logger.info(
      "API: LCARS fleet — build #{info.sha}#{dirty} ref=#{info.ref} (source=#{info.source})"
    )
  end

  @doc """
  Cowboy listener child specs (public for the bind test: the listener's `:ip`
  is a security contract — loopback by default, named override only).
  Returns `[]` when `:start_listener` is `false`.
  """
  def listener_children do
    if Application.get_env(:fleet_api, :start_listener, true) do
      # No static default (A7): the port is per-human (bin/fleet_v2 → runtime.exs). fetch_env!
      # = fail-loud if the config is missing (in test start_listener=false → never reached).
      port = Application.fetch_env!(:fleet_api, :http_port)

      # RAW dispatch (not pre-compiled) — Plug.Cowboy compiles it
      # internally via to_args/5. Passing it ALREADY compiled made
      # cowboy re-compile the internal structure → decomposed segments
      # reinterpreted as raw paths → "ws" without a slash →
      # ArgumentError. Real PROD bug (not covered in test, where
      # start_listener:false short-circuits the listener bind — the
      # dispatch is never compiled).
      dispatch = [
        {:_,
         [
           {"/ws", Fleet.API.WS, []},
           {:_, Plug.Cowboy.Handler, {Fleet.API.Rest, []}}
         ]}
      ]

      # TCP listener = READ surface + WS (loopback by default via BindAddress; public exposure =
      # named opt-in LCARS_BIND_HOST). The WRITE (/api/admin/spawn) is NOT here — it moved onto
      # the AF_UNIX control socket below, off the network the pod shares (A-21, cf. Rest § Auth).
      tcp =
        Fleet.EventRouter.Listener.cowboy_child(
          plug: Fleet.API.Rest,
          port: port,
          dispatch: dispatch
        )

      [tcp | control_socket_child()]
    else
      []
    end
  end

  # AF_UNIX control socket serving `Fleet.API.ControlRouter` (`POST /api/admin/spawn`). Started
  # alongside the TCP listener when `:control_socket` is configured (per-human, runtime.exs). `[]`
  # when unset (e.g. a test, or a deploy with no write door) → the write door is simply ABSENT
  # (POST /api/admin/spawn 404s on the TCP listener; the control socket is the ONLY write door —
  # there is no "keep the write on TCP" mode).
  defp control_socket_child do
    case Application.get_env(:fleet_api, :control_socket) do
      sock when is_binary(sock) and sock != "" -> [Fleet.API.ControlRouter.child_spec(sock)]
      _ -> []
    end
  end
end
