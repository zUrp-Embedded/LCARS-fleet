defmodule Fleet.MCP.Channel do
  @moduledoc """
  Behaviour générique d'un channel MCP (DN ring4/fleet_mcp.md §"Contrat
  technique" — `Fleet.MCP.Channel`).

  Un channel = routage stateless au-dessus de Phoenix.PubSub (substrat
  interne native BEAM) + exposition transport pod-facing (stdio/http_sse,
  cf. canon `mcp-channels.yaml` — native_beam INTERDIT côté pod, ADR-C
  5 zéros). **Aucun process par channel** (Iron Law — pas d'état mutable
  propre, pas de concurrence interne : le fan-out est délégué à
  Phoenix.PubSub, pas sérialisé via un GenServer). Les impls canon :
  `Fleet.MCP.Channels.FleetControl` + `Fleet.MCP.Channels.FleetForge`.

  `broadcast/2` valide l'event (`Fleet.MCP.Schema`) avant publication —
  fail-fast `{:error, :schema_invalid, errors}` si non conforme.
  """

  @typedoc "Référence opaque de souscription (transport-dépendante)."
  @type subscription_ref :: term()

  @typedoc """
  Erreur de `broadcast/2` (F1 reviewer Lot 1 #558) : le 3-tuple
  `{:error, :schema_invalid, errors}` (validation event fail-fast,
  `Channel.PubSub.broadcast/3`) DOIT être admis par le contrat behaviour —
  sinon un consommateur pattern-matchant sur la spec crashe sur le 3-tuple.
  """
  @type broadcast_error ::
          {:error, term()} | {:error, :schema_invalid, [String.t()]}

  @callback subscribe(channel_name :: String.t(), opts :: keyword()) ::
              {:ok, subscription_ref()} | {:error, term()}
  @callback unsubscribe(ref :: subscription_ref()) :: :ok
  @callback broadcast(channel_name :: String.t(), event :: map()) ::
              :ok | broadcast_error()
end
