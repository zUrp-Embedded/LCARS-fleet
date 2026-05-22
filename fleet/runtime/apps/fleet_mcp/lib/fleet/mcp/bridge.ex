defmodule Fleet.MCP.Bridge do
  @moduledoc """
  Pont Phoenix.PubSub bus interne ↔ MCP channels externes (DN
  ring4/fleet_mcp.md §"Contrat technique" + canon
  `05_data-canon/config/mcp-bridge.yaml`).

  **GenServer justifié** (Iron Law) : état mutable persistant (mappings
  chargés + souscriptions actives) + concurrence (réagit aux messages
  Phoenix.PubSub via `handle_info`) + fault-isolation (supervisé,
  redémarrable). Direction MVP décisive : `pubsub_to_mcp` (fleet broadcast
  → push channel pod-facing).

  Politique de boot (deux gates distincts, DN + canon §"Gate runtime") :
  - **schema invalide** (fichier présent, structure non conforme
    `mcp-bridge-v1.json`) → fail-fast `{:stop, …}` (config corrompue =
    refus boot, cohérent refus-défaut canon).
  - **config absente/illisible** → *graceful degradation* : log warning,
    mappings vides, `{:ok, …}` (ne JAMAIS crash-looper l'umbrella si le
    fichier de config n'est pas déployé — canon mandate explicite).
  - **mapping non résolu** au runtime (template/topic non résoluble) →
    log warning + skip ce mapping (graceful, canon §"Gate runtime").
  """

  use GenServer
  require Logger

  @pubsub Fleet.PubSub
  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc "Contrat DN — idempotent : `:ok` si le bridge tourne."
  @spec init_bridges(GenServer.server()) :: :ok | {:error, :not_running}
  def init_bridges(server \\ @name) do
    alive? =
      cond do
        is_pid(server) -> Process.alive?(server)
        true -> not is_nil(Process.whereis(server))
      end

    if alive?, do: :ok, else: {:error, :not_running}
  end

  @doc "Mappings effectivement chargés (introspection/tests)."
  @spec mappings(GenServer.server()) :: %{pubsub_to_mcp: list(), mcp_to_pubsub: list()}
  def mappings(server \\ @name), do: GenServer.call(server, :mappings)

  @impl GenServer
  def init(opts) do
    path = config_path(opts)
    schema = Fleet.MCP.Schema.priv_schema("mcp-bridge-v1.json")

    case load_config(path, schema) do
      {:ok, %{"bridges" => bridges}} ->
        p2m = Map.get(bridges, "pubsub_to_mcp", [])
        m2p = Map.get(bridges, "mcp_to_pubsub", [])
        subscribe_pubsub_topics(p2m)
        {:ok, %{pubsub_to_mcp: p2m, mcp_to_pubsub: m2p, path: path}}

      {:degraded, reason} ->
        Logger.warning(
          "Fleet.MCP.Bridge: config indisponible (#{inspect(reason)}) — " <>
            "graceful degradation, 0 mapping actif"
        )

        {:ok, %{pubsub_to_mcp: [], mcp_to_pubsub: [], path: path}}

      {:invalid, errors} ->
        {:stop, {:bridge_config_invalid, errors}}
    end
  end

  @impl GenServer
  def handle_call(:mappings, _from, state) do
    {:reply, %{pubsub_to_mcp: state.pubsub_to_mcp, mcp_to_pubsub: state.mcp_to_pubsub}, state}
  end

  @impl GenServer
  def handle_info(event, state) when is_map(event) do
    etype = event["event_type"] || event["type"] || ""

    Enum.each(state.pubsub_to_mcp, fn m ->
      if glob_match?(m["event_type"], etype) do
        case resolve_template(m["mcp_channel_template"], event) do
          {:ok, channel_topic} ->
            Phoenix.PubSub.broadcast(@pubsub, channel_topic, event)

          :unresolved ->
            Logger.warning(
              "Fleet.MCP.Bridge: template non résolu " <>
                "#{inspect(m["mcp_channel_template"])} — skip (graceful)"
            )
        end
      end
    end)

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- privé ---

  defp config_path(opts) do
    Keyword.get(opts, :bridge_config_path) ||
      Application.get_env(:fleet_mcp, :bridge_config_path) ||
      "config/mcp-bridge.yaml"
  end

  defp load_config(path, schema) do
    with true <- File.exists?(path) || {:absent, path},
         {:ok, map} <- read_yaml(path),
         :ok <- Fleet.MCP.Schema.validate(map, schema) do
      {:ok, map}
    else
      {:absent, p} -> {:degraded, {:enoent, p}}
      {:error, %YamlElixir.FileNotFoundError{}} -> {:degraded, :enoent}
      {:error, :schema_unavailable} -> {:degraded, :schema_unavailable}
      {:error, errors} when is_list(errors) -> {:invalid, errors}
      {:error, reason} -> {:degraded, reason}
    end
  end

  defp read_yaml(path) do
    {:ok, YamlElixir.read_from_file!(path)}
  rescue
    e -> {:error, e}
  end

  defp subscribe_pubsub_topics(p2m) do
    p2m
    |> Enum.map(& &1["pubsub_topic"])
    |> Enum.uniq()
    |> Enum.each(fn
      t when is_binary(t) and t != "" -> Phoenix.PubSub.subscribe(@pubsub, t)
      _ -> :skip
    end)
  end

  # Glob minimal "a.b.*" / "a.b" — suffisant pour event_type canon.
  defp glob_match?(pattern, value) when is_binary(pattern) and is_binary(value) do
    cond do
      pattern == value ->
        true

      String.ends_with?(pattern, "*") ->
        String.starts_with?(value, String.trim_trailing(pattern, "*"))

      true ->
        false
    end
  end

  defp glob_match?(_, _), do: false

  # {target_role}/{assignee} résolus depuis les champs de l'event.
  defp resolve_template(template, event) when is_binary(template) do
    Regex.scan(~r/\{(\w+)\}/, template)
    |> Enum.reduce({:ok, template}, fn
      [_, key], {:ok, acc} ->
        case Map.get(event, key) do
          v when is_binary(v) and v != "" -> {:ok, String.replace(acc, "{#{key}}", v)}
          _ -> :unresolved
        end

      _, :unresolved ->
        :unresolved
    end)
  end

  defp resolve_template(_, _), do: :unresolved
end
