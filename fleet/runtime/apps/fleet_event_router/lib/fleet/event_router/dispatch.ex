defmodule Fleet.EventRouter.Dispatch do
  @moduledoc """
  Dispatch table déclarative — `config/events.yaml` parsed
  `yaml_elixir` au boot. Pattern `event_type → [handler_module]`.

  Cohérent architecture-cible §L338 "core ne hardcode aucun event
  type — dispatche sur table déclarative". Extensible PR sans
  recompile.

  ## GenServer

  Subscribe `fleet.events` au boot, route les messages
  `{event_atom, event}` vers les handlers déclarés en YAML
  (`apply/3` strict — module doit déjà exister).

  ## Configuration

    * `:fleet_event_router, :events_yaml_path` — path catalogue YAML
      (default `priv/events.yaml`)
  """

  use GenServer

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    table = load_table()

    # R5/R08 — fail-loud au BOOT : un handler référencé dans events.yaml qui
    # n'existe pas = état invalide non-représentable (I-CBC). Refuser de booter
    # plutôt que tolérer un dispatch silencieusement no-op (warning runtime).
    # Verrou anti-récurrence de la classe « handler fantôme ».
    case validate_handlers(table) do
      :ok ->
        :ok = Fleet.EventRouter.Bus.subscribe()
        {:ok, table}

      {:error, missing} ->
        {:stop, {:phantom_handlers, missing}}
    end
  end

  defp validate_handlers(%{"events" => events}) when is_map(events) do
    missing =
      events
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.reject(&handler_loadable?/1)

    if missing == [], do: :ok, else: {:error, missing}
  end

  defp validate_handlers(_), do: :ok

  defp handler_loadable?(name) do
    match?({:ok, _}, safe_module(name))
  end

  @impl GenServer
  def handle_info({event_atom, event}, table) when is_atom(event_atom) do
    # Legacy format (broadcast/3 compat shim BL-021 chantier 1)
    handlers = Map.get(table["events"] || %{}, Atom.to_string(event_atom), [])

    Enum.each(handlers, fn handler_name ->
      dispatch_one(handler_name, event)
    end)

    {:noreply, table}
  end

  def handle_info(%Fleet.Event{type: type} = event, table) do
    # Schema canon strict (broadcast/2 + DN 11 C3.1+C3.2)
    handlers = Map.get(table["events"] || %{}, Atom.to_string(type), [])

    Enum.each(handlers, fn handler_name ->
      dispatch_one(handler_name, event)
    end)

    {:noreply, table}
  end

  def handle_info(_other, table), do: {:noreply, table}

  defp dispatch_one(handler_name, event) do
    case safe_module(handler_name) do
      {:ok, module} ->
        try do
          apply(module, :handle_event, [event])
        rescue
          e -> Logger.error("dispatch handler #{handler_name} crashed: #{inspect(e)}")
        end

      {:error, reason} ->
        Logger.warning("dispatch handler #{handler_name} unavailable: #{reason}")
    end
  end

  defp safe_module(handler_name) do
    full = "Elixir." <> handler_name

    try do
      module = String.to_existing_atom(full)
      if Code.ensure_loaded?(module), do: {:ok, module}, else: {:error, "not loaded"}
    rescue
      ArgumentError -> {:error, "unknown atom"}
    end
  end

  @doc """
  Recharge le catalogue YAML (helper test/runtime).
  """
  @spec reload() :: :ok
  def reload do
    GenServer.cast(__MODULE__, :reload)
  end

  @impl GenServer
  def handle_cast(:reload, state) do
    table = load_table()
    # R5 — symétrie avec le boot : un reload introduisant un handler fantôme est
    # rejeté (table précédente conservée), pas accepté silencieusement.
    case validate_handlers(table) do
      :ok ->
        {:noreply, table}

      {:error, missing} ->
        Logger.error("dispatch reload refusé — handlers fantômes: #{inspect(missing)}")
        {:noreply, state}
    end
  end

  defp load_table do
    path = events_yaml_path()

    case File.exists?(path) && YamlElixir.read_from_file(path) do
      {:ok, table} when is_map(table) ->
        preregister_atoms(table)
        register_authorized_types(table)
        table

      _ ->
        Logger.warning("fleet_event_router events.yaml missing or invalid at #{path}")
        %{"events" => %{}}
    end
  end

  defp preregister_atoms(%{"events" => events}) when is_map(events) do
    Enum.each(Map.keys(events), fn event_type -> _ = String.to_atom(event_type) end)
  end

  defp preregister_atoms(_), do: :ok

  defp register_authorized_types(%{"events" => events}) when is_map(events) do
    # DN 11 C3.2 : registry events.yaml = source de vérité pour broadcast/2 strict.
    # Set d'atomes inscrits dans events.yaml — broadcast/2 raise UnregisteredError si type hors set.
    set =
      events
      |> Map.keys()
      |> Enum.map(&String.to_atom/1)
      |> MapSet.new()

    Fleet.EventRouter.Bus.set_authorized_event_types(set)
  end

  defp register_authorized_types(_), do: :ok

  defp events_yaml_path do
    Application.get_env(
      :fleet_event_router,
      :events_yaml_path,
      Path.join(:code.priv_dir(:fleet_event_router) |> to_string(), "events.yaml")
    )
  end
end
