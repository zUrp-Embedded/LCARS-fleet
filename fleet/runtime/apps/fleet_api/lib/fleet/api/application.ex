defmodule Fleet.API.Application do
  @moduledoc """
  Application supervisor `fleet_api`.

  Démarre le Cowboy listener (port per-humain, bin/fleet_v2) avec dispatch :

    - `/ws` → `Fleet.API.WS` (WebSocket handler)
    - `/_*` → `Fleet.API.Rest` (Plug.Router REST)

  ## Configuration

    * `:fleet_api, :http_port` — port HTTP (posé par runtime.exs depuis FLEET_API_PORT, per-humain ; absent → fail-loud)
    * `:fleet_api, :start_listener` — booléen (default `true`).
      Tests peuvent set à `false` pour démarrer Cowboy manuellement.

  ## Stratégie

  `:one_for_one` — Cowboy listener restart `:permanent`.
  Pré-enregistrement atomes events (créés au compile-time, pas dérivés d'entrée externe → pas de fuite d'atomes DoS).
  """

  use Application

  # NB atome `api` (admin.spawn.request) : créé au compile-time par son vrai site
  # (rest.ex) — pas besoin d'un attribut de pré-enregistrement dédié dans cette
  # application (l'atome existe déjà via le `%Fleet.Event{type: :"admin.spawn.request"}`).

  @impl Application
  def start(_type, _args) do
    children = listener_children()

    opts = [strategy: :one_for_one, name: Fleet.API.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _} = ok ->
        # Une unit systemd `Type=notify` attend sd_notify(READY=1). Émis
        # APRÈS Supervisor.start_link OK (listener Cowboy bind effectif
        # — sinon `is-active = activating` jusqu'à TimeoutStartSec=120s).
        # Inline gen_udp AF_UNIX SOCK_DGRAM (pas de dep Hex). Guard
        # NOTIFY_SOCKET (no-op dev/test sans systemd). Rescue : ne
        # jamais crash l'app sur notify failure.
        notify_systemd_ready()
        log_build_info()
        ok

      err ->
        err
    end
  end

  # Trace de boot : la version du build servi, lisible dans les logs de la fleet
  # qui tourne (« quel commit tourne ? » constatable, pas déduit). Totale —
  # `BuildInfo.current/0` ne lève jamais. Mémoïsé : ce premier appel au boot
  # remplit le cache (un seul `git` sur toute la vie du BEAM).
  defp log_build_info do
    info = Fleet.API.BuildInfo.current()
    dirty = if info.dirty, do: "-dirty", else: ""
    require Logger

    Logger.info("LCARS fleet — build #{info.sha}#{dirty} ref=#{info.ref} (source=#{info.source})")
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
          Logger.info("Fleet.API: sd_notify READY=1 sent to #{socket}")
          :ok
        rescue
          e ->
            require Logger
            Logger.warning("Fleet.API: sd_notify failed (non-fatal): #{inspect(e)}")
            :ok
        end

      _ ->
        # NOTIFY_SOCKET absent/vide/abstract → no-op (dev, test, run
        # hors systemd, ou setup abstract socket non géré).
        :ok
    end
  end

  @doc """
  Child specs du listener Cowboy (public pour le test de bind : l'`:ip` du listener
  est un contrat de sécurité — loopback par défaut, override nommé seulement).
  Retourne `[]` quand `:start_listener` est `false`.
  """
  def listener_children do
    if Application.get_env(:fleet_api, :start_listener, true) do
      # Pas de défaut statique (A7) : le port est per-humain (bin/fleet_v2 → runtime.exs). fetch_env!
      # = fail-loud si la config manque (en test start_listener=false → jamais atteint).
      port = Application.fetch_env!(:fleet_api, :http_port)

      # Dispatch RAW (non pré-compilé) — Plug.Cowboy le compile en
      # interne via to_args/5. Le passer DÉJÀ compilé faisait
      # re-compiler la structure interne cowboy → segments décomposés
      # réinterprétés comme paths bruts → "ws" sans slash →
      # ArgumentError. Bug PROD réel (pas couvert en test, où
      # start_listener:false court-circuite le bind du listener — le
      # dispatch n'est jamais compilé).
      dispatch = [
        {:_,
         [
           {"/ws", Fleet.API.WS, []},
           {:_, Plug.Cowboy.Handler, {Fleet.API.Rest, []}}
         ]}
      ]

      # Bind loopback par défaut (frontière = isolation réseau, cf. Rest § Auth : la seule
      # écriture restante, /api/admin/spawn, est no-auth mais gardée — ne JAMAIS l'exposer
      # 0.0.0.0 par défaut). Le dashboard navigateur (:<port>/dashboard + /ws)
      # devient local-only : un accès distant passe par un tunnel/reverse-proxy.
      # Exposition publique = opt-in nommé via Fleet.EventRouter.BindAddress (LCARS_BIND_HOST).
      ip = Fleet.EventRouter.BindAddress.ip()

      [
        {Plug.Cowboy,
         scheme: :http, plug: Fleet.API.Rest, options: [ip: ip, port: port, dispatch: dispatch]}
      ]
    else
      []
    end
  end
end
