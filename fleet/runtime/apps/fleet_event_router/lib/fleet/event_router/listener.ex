defmodule Fleet.EventRouter.Listener do
  @moduledoc """
  Source UNIQUE du **child-spec Cowboy** des listeners HTTP du runtime — le pendant « spec » de
  `Fleet.EventRouter.BindAddress` (même concern : *comment on expose un listener*).

  Les trois surfaces HTTP du runtime — `fleet_api` (REST + WS), `fleet_observation` (deck) et le
  webhook Gitea de cette app — construisaient chacune le même triplet
  `BindAddress.ip()` → `options` → `{Plug.Cowboy, …}`. Il n'y a plus qu'UN builder : l'invariant
  « bind loopback par défaut, exposition = opt-in nommé » est appliqué ici PAR CONSTRUCTION (un
  listener passé par `cowboy_child/1` ne peut pas oublier l'`:ip` ; cf. le moduledoc de
  `BindAddress` pour le contrat de sécurité complet).

  Restent CHEZ CHAQUE APP (politique locale, pas la forme) :

    * le **gate de démarrage** (`:start_listener` / `:start_webhooks`) — l'hermétisme test
      (pas de bind de port en `mix test`) est un choix d'app ;
    * la **résolution du port** (`fetch_env!` fail-loud per-humain, ou défaut webhook) — la
      provenance du port est un contrat d'app (cf. `config/runtime.exs`).

  Zéro nouvelle arête : `fleet_event_router` porte déjà la dep `plug_cowboy` (webhook), et les
  deux apps consommatrices (`fleet_api`, `fleet_observation`) dépendent déjà d'event_router.
  """

  @doc """
  Child-spec Plug.Cowboy d'un listener HTTP, avec l'`:ip` résolue par
  `Fleet.EventRouter.BindAddress` (loopback par défaut ; exposition publique = opt-in nommé).

  Opts :

    * `:plug` (requis) — le module Plug servi.
    * `:port` (requis) — port TCP, résolu par l'appelant (fetch_env! per-humain / défaut webhook).
    * `:scheme` — défaut `:http`.
    * `:dispatch` — dispatch Cowboy optionnel (ex. la route WS de `fleet_api`), passé RAW
      (non pré-compilé) : Plug.Cowboy le compile en interne via `to_args/5`. Un dispatch DÉJÀ
      compilé serait re-compilé → segments décomposés réinterprétés comme paths bruts → `"ws"`
      sans slash → ArgumentError (bug PROD réel côté fleet_api, jamais vu en test où
      `start_listener: false` court-circuite le bind).
    * `:ref` — ref ranch optionnelle (plusieurs listeners d'un même plug dans le VM / tests).
    * `:surface_env` — nom de l'env var d'override de bind SPÉCIFIQUE à la surface (ex.
      `LCARS_WEBHOOK_BIND_HOST`), passé à `BindAddress.ip/1` ; absent → override global
      `LCARS_BIND_HOST` / loopback.
  """
  @spec cowboy_child(keyword()) :: {module(), keyword()}
  def cowboy_child(opts) do
    plug = Keyword.fetch!(opts, :plug)
    port = Keyword.fetch!(opts, :port)
    ip = Fleet.EventRouter.BindAddress.ip(Keyword.get(opts, :surface_env))

    options =
      [ip: ip, port: port]
      |> append_present(:dispatch, Keyword.get(opts, :dispatch))
      |> append_present(:ref, Keyword.get(opts, :ref))

    {Plug.Cowboy, scheme: Keyword.get(opts, :scheme, :http), plug: plug, options: options}
  end

  # Appende `{key, value}` en FIN de liste si non-nil (préserve l'ordre lisible ip → port → reste).
  defp append_present(options, _key, nil), do: options
  defp append_present(options, key, value), do: options ++ [{key, value}]
end
