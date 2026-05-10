defmodule Fleet.EventRouter.Bus do
  @moduledoc """
  Bus events Phoenix.PubSub instance `Fleet.PubSub` topic
  `fleet.events` + sous-topics `fleet.events.<scope>.<id>` (ex relay
  ch10 `fleet.events.relay.<ref>`).

  ## API

    * `child_spec/1` — pour Application supervisor (instancie
      `Phoenix.PubSub` `Fleet.PubSub`)
    * `broadcast/3` — diffuse event NDJSON validé schema (soft : log
      + reject sans crash si invalide)
    * `subscribe/1` / `unsubscribe/1` — gestion abonnements topic

  ## Format event diffusé

      {String.to_atom(event_type), %{
        "ts" => ISO8601,
        "event_type" => string,
        "node_id" => string,
        "trace_id" => 16-hex string,
        "payload" => map,
        "ticket_id" => optional string,
        "pod_id" => optional string,
        "attempt_id" => optional string
      }}
  """

  require Logger

  @pubsub_name Fleet.PubSub
  @main_topic "fleet.events"

  @doc """
  Child spec Phoenix.PubSub pour Application supervisor.
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts), do: Phoenix.PubSub.child_spec(name: @pubsub_name)

  @doc """
  Diffuse un event sur le topic principal `fleet.events`.

  ## Inputs

    * `event_type` — string (ex: `"pod.allocate"`, `"refuse_pattern_match"`)
    * `payload` — map JSON-encodable
    * `opts` :
      * `:ticket_id` — string optionnel
      * `:pod_id` — string optionnel
      * `:attempt_id` — string optionnel
      * `:trace_id` — string optionnel (généré si absent)

  ## Returns

    * `:ok` — broadcast effectué
    * `{:error, reason}` — schema invalide (logged, pas crash)
  """
  @spec broadcast(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def broadcast(event_type, payload, opts \\ [])
      when is_binary(event_type) and is_map(payload) and is_list(opts) do
    event = build_event(event_type, payload, opts)

    case validate(event) do
      :ok ->
        Phoenix.PubSub.broadcast(
          @pubsub_name,
          @main_topic,
          {to_event_atom(event_type), event}
        )

      {:error, reason} ->
        Logger.error(
          "fleet_event_router schema invalide: #{inspect(reason)} event_type=#{inspect(event_type)}"
        )

        {:error, reason}
    end
  end

  @doc """
  S'abonne à un topic Phoenix.PubSub. Default `"fleet.events"`.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic \\ @main_topic) when is_binary(topic) do
    Phoenix.PubSub.subscribe(@pubsub_name, topic)
  end

  @doc """
  Désabonne du topic.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic \\ @main_topic) when is_binary(topic) do
    Phoenix.PubSub.unsubscribe(@pubsub_name, topic)
  end

  @doc """
  Diffuse un event vers un sous-topic `fleet.events.<scope>.<id>`
  (ex `fleet.events.relay.<ref>` pour ch10 step 4 relay matching ref).
  """
  @spec broadcast_subtopic(String.t(), term()) :: :ok | {:error, term()}
  def broadcast_subtopic(subtopic, message) when is_binary(subtopic) do
    Phoenix.PubSub.broadcast(@pubsub_name, "#{@main_topic}.#{subtopic}", message)
  end

  defp build_event(event_type, payload, opts) do
    %{
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "event_type" => event_type,
      "ticket_id" => opts[:ticket_id],
      "pod_id" => opts[:pod_id],
      "attempt_id" => opts[:attempt_id],
      "node_id" => Node.self() |> Atom.to_string(),
      "trace_id" => opts[:trace_id] || generate_trace_id(),
      "payload" => payload
    }
  end

  defp validate(event) do
    ExJsonSchema.Validator.validate(resolved_schema(), event)
  end

  defp resolved_schema do
    case :persistent_term.get({__MODULE__, :resolved_schema}, :undefined) do
      :undefined ->
        resolved = ExJsonSchema.Schema.resolve(Fleet.EventRouter.Schema.schema())
        :persistent_term.put({__MODULE__, :resolved_schema}, resolved)
        resolved

      resolved ->
        resolved
    end
  end

  defp to_event_atom(event_type) when is_binary(event_type) do
    String.to_existing_atom(event_type)
  rescue
    ArgumentError ->
      require Logger

      Logger.warning(
        "fleet_event_router unknown event_type atom: #{inspect(event_type)} — using :unknown_event fallback"
      )

      :unknown_event
  end

  @doc """
  Génère un `trace_id` 16-hex (8 bytes crypto strong).
  """
  @spec generate_trace_id() :: String.t()
  def generate_trace_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
