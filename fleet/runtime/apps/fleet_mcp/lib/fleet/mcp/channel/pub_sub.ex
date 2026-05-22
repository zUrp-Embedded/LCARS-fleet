defmodule Fleet.MCP.Channel.PubSub do
  @moduledoc """
  Implémentation partagée des channels MCP au-dessus de `Phoenix.PubSub`
  `Fleet.PubSub` (instance canon — `Fleet.EventRouter.Bus`, chantier 11).

  **Fonctions pures, zéro process** (Iron Law) : le fan-out multi-subscriber
  est assuré par Phoenix.PubSub, JAMAIS sérialisé via un GenServer
  (anti-goulot DN §"Coût" + otp-thinking). `Fleet.MCP.Channels.FleetControl`
  et `FleetForge` ne sont que des façades `@behaviour Fleet.MCP.Channel`
  qui délèguent ici en passant leur nom de channel canon.

  Topic Phoenix.PubSub = le nom de channel/sous-topic tel quel (ex.
  `"fleet-control.coord.handoff"`). `subscribe/2` accepte `opts[:topic]`
  pour cibler un sous-topic précis (défaut = nom de channel racine).
  La référence de souscription retournée EST le topic (suffisant pour
  `unsubscribe/1` — pas d'état à tracker, cohérent Iron Law).
  """

  @pubsub Fleet.PubSub

  @spec subscribe(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def subscribe(channel_name, opts) when is_binary(channel_name) do
    topic = Keyword.get(opts, :topic, channel_name)

    case Phoenix.PubSub.subscribe(@pubsub, topic) do
      :ok -> {:ok, topic}
      {:error, _} = err -> err
    end
  end

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic)
  end

  @doc """
  Publie `event` sur le topic du channel. `event["topic"]` (si présent et
  binaire) cible un sous-topic ; sinon le nom de channel racine.

  Si un schema d'event est fourni (`opts[:schema_path]`), validation
  fail-fast `Fleet.MCP.Schema` AVANT publication (`{:error, :schema_invalid,
  errors}`). MVP canon : pas de schema per-channel dérivé encore → publi
  directe (validation activable sans changer l'interface).
  """
  @spec broadcast(String.t(), map(), keyword()) ::
          :ok | {:error, :schema_invalid, [String.t()]} | {:error, term()}
  def broadcast(channel_name, event, opts \\ [])
      when is_binary(channel_name) and is_map(event) do
    topic =
      case Map.get(event, "topic") do
        t when is_binary(t) and t != "" -> t
        _ -> channel_name
      end

    with :ok <- maybe_validate(event, Keyword.get(opts, :schema_path)) do
      Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end

  defp maybe_validate(_event, nil), do: :ok

  defp maybe_validate(event, schema_path) do
    case Fleet.MCP.Schema.validate(event, schema_path) do
      :ok -> :ok
      {:error, errors} -> {:error, :schema_invalid, errors}
    end
  end
end
