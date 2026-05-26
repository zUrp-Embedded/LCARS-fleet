defmodule Fleet.Api.Application do
  @moduledoc """
  Application supervisor `fleet_api`.

  Démarre :

    1. `Fleet.Api.RelayHandler` GenServer (subscribe Bus +
       ETS pending refs)
    2. Cowboy listener `:8080` avec dispatch :
       - `/ws` → `Fleet.Api.Ws` (WebSocket handler)
       - `/_*` → `Fleet.Api.Rest` (Plug.Router REST)

  ## Configuration

    * `:fleet_api, :http_port` — port HTTP (default `8080`)
    * `:fleet_api, :start_listener` — booléen (default `true`).
      Tests peuvent set à `false` pour démarrer Cowboy manuellement.
    * `:fleet_api, :api_secret_path` — path secret HMAC (default
      `/etc/fleet/api-secret`)
    * `:fleet_api, :git_repo_path` — racine repo config
      (default `/var/lib/lcars/config`)

  ## Stratégie

  `:one_for_one` — RelayHandler restart `:permanent`, Cowboy listener
  restart `:permanent`. Pré-enregistrement atomes events (cohérent
  ch11 M1 atom-leak DoS).
  """

  use Application

  @api_event_atoms [
    :"admin.spawn.request",
    :permission_relay_request,
    :permission_relay_response
  ]

  @impl Application
  def start(_type, _args) do
    children = base_children() ++ listener_children()

    opts = [strategy: :one_for_one, name: Fleet.Api.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _} = ok ->
        # B9 #576 — Type=notify unit attend sd_notify(READY=1). Émis
        # APRÈS Supervisor.start_link OK (listener Cowboy bind effectif
        # — sinon `is-active = activating` jusqu'à TimeoutStartSec=120s).
        # Inline gen_udp AF_UNIX SOCK_DGRAM (pas de dep Hex). Guard
        # NOTIFY_SOCKET (no-op dev/test sans systemd). Rescue : ne
        # jamais crash l'app sur notify failure.
        notify_systemd_ready()
        ok

      err ->
        err
    end
  end

  # sd_notify minimal — protocole : ouvrir AF_UNIX SOCK_DGRAM, écrire
  # "READY=1\n" sur $NOTIFY_SOCKET (chemin Unix). Cas abstract socket
  # (préfixe \0/@) non géré (rare en pratique systemd).
  defp notify_systemd_ready do
    case System.get_env("NOTIFY_SOCKET") do
      socket when is_binary(socket) and socket != "" and binary_part(socket, 0, 1) == "/" ->
        try do
          {:ok, s} = :gen_udp.open(0, [:local, :binary])
          :ok = :gen_udp.send(s, {:local, socket}, 0, "READY=1\n")
          :gen_udp.close(s)
          require Logger
          Logger.info("Fleet.Api: sd_notify READY=1 sent to #{socket}")
          :ok
        rescue
          e ->
            require Logger
            Logger.warning("Fleet.Api: sd_notify failed (non-fatal): #{inspect(e)}")
            :ok
        end

      _ ->
        # NOTIFY_SOCKET absent/vide/abstract → no-op (dev, test, run
        # hors systemd, ou setup abstract socket non géré).
        :ok
    end
  end

  @doc """
  Liste des atomes events `api`-related pré-enregistrés. Cohérent ch11
  M1 atom-leak DoS mitigation (Bus `String.to_existing_atom/1`).
  """
  @spec api_event_atoms() :: [atom()]
  def api_event_atoms, do: @api_event_atoms

  defp base_children do
    # Vulcan #2 : GitCommitter GenServer sérialise les commits du repo
    # config (évite race conditions cross-caller sur snapshot/rename/
    # git add/commit/rollback). Pas de cycle, pas de state mutable —
    # juste un mutex de file FIFO.
    [Fleet.Api.GitCommitter, Fleet.Api.RelayHandler]
  end

  defp listener_children do
    if Application.get_env(:fleet_api, :start_listener, true) do
      port = Application.get_env(:fleet_api, :http_port, 8080)

      # Dispatch RAW (non pré-compilé) — Plug.Cowboy le compile en
      # interne via to_args/5. Le passer DÉJÀ compilé (ancienne
      # version) faisait re-compiler la structure interne cowboy →
      # segments décomposés réinterprétés comme paths bruts →
      # "ws" sans slash → ArgumentError. Bug réel prod, masqué en
      # test par start_listener:false. Fix prod (#576 d9aacfd0 ne
      # corrigeait QUE la régression test, pas ce bug-ci).
      dispatch = [
        {:_,
         [
           {"/ws", Fleet.Api.Ws, []},
           {:_, Plug.Cowboy.Handler, {Fleet.Api.Rest, []}}
         ]}
      ]

      [
        {Plug.Cowboy,
         scheme: :http, plug: Fleet.Api.Rest, options: [port: port, dispatch: dispatch]}
      ]
    else
      []
    end
  end
end
