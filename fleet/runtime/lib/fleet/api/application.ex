defmodule Fleet.API.Application do
  @moduledoc """
  Application supervisor `fleet_api`.

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

  use Application

  # NB atom `api` (admin.spawn.request): created at compile-time by its real site
  # (rest.ex) — no need for a dedicated pre-registration attribute in this
  # application (the atom already exists via the `%Fleet.Event{type: :"admin.spawn.request"}`).

  @impl Application
  def start(_type, _args) do
    children = listener_children()

    # F4 (E1): 3/60 intensity EXPLICIT (event_router/task_queue doctrine — 3/5 OTP too tight for a blip; the window is a CHOICE).
    opts = [strategy: :one_for_one, max_restarts: 3, max_seconds: 60, name: Fleet.API.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _} = ok ->
        # A systemd `Type=notify` unit waits for sd_notify(READY=1). Emitted
        # AFTER Supervisor.start_link OK (Cowboy listener effectively bound
        # — otherwise `is-active = activating` until TimeoutStartSec=120s).
        # Inline gen_udp AF_UNIX SOCK_DGRAM (no Hex dep). NOTIFY_SOCKET
        # guard (no-op in dev/test without systemd). Rescue: never
        # crash the app on notify failure.
        notify_systemd_ready()
        log_build_info()
        ok

      err ->
        err
    end
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

  # Minimal sd_notify — protocol: open AF_UNIX SOCK_DGRAM, write
  # "READY=1\n" to $NOTIFY_SOCKET (Unix path). Abstract socket case
  # (\0/@ prefix) not handled (rare in practice for systemd).
  defp notify_systemd_ready do
    case System.get_env("NOTIFY_SOCKET") do
      socket when is_binary(socket) and socket != "" and binary_part(socket, 0, 1) == "/" ->
        try do
          {:ok, s} = :gen_udp.open(0, [:local, :binary])
          :ok = :gen_udp.send(s, {:local, socket}, 0, "READY=1\n")
          :gen_udp.close(s)
          require Logger
          Logger.info("API: sd_notify READY=1 sent to #{socket}")
          :ok
        rescue
          e ->
            require Logger
            Logger.warning("API: sd_notify failed (non-fatal): #{inspect(e)}")
            :ok
        end

      _ ->
        # NOTIFY_SOCKET absent/empty/abstract → no-op (dev, test, run
        # outside systemd, or unhandled abstract socket setup).
        :ok
    end
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

      # Child-spec via the single source Fleet.EventRouter.Listener: loopback bind by default
      # applied BY CONSTRUCTION (boundary = network isolation, cf. Rest § Auth: the only
      # remaining write, /api/admin/spawn, is no-auth but guarded — NEVER expose it on
      # 0.0.0.0 by default). The browser dashboard (:<port>/dashboard + /ws) becomes
      # local-only: remote access goes through a tunnel/reverse-proxy. Public exposure =
      # named opt-in (LCARS_BIND_HOST, via BindAddress).
      [
        Fleet.EventRouter.Listener.cowboy_child(
          plug: Fleet.API.Rest,
          port: port,
          dispatch: dispatch
        )
      ]
    else
      []
    end
  end
end
