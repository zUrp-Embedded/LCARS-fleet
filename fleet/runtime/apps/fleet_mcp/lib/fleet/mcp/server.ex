defmodule Fleet.MCP.Server do
  @moduledoc """
  Serveur MCP LCARS — wrapper opaque SDK ExMCP (DN ring4/fleet_mcp.md
  §"Contrat technique" + §"Test récursif D7-bis").

  **GenServer justifié** (Iron Law) : état mutable persistant = registre des
  channels + lifecycle ; supervisé par `Fleet.MCP.Supervisor`. Ce process
  porte UNIQUEMENT registration/lifecycle (bas débit). Le **broadcast
  fan-out NE passe PAS par ce GenServer** — il est délégué à Phoenix.PubSub
  via les `Fleet.MCP.Channel` (anti-goulot explicite : DN §"Coût" multi-
  subscriber + otp-thinking Iron Law "GenServer is a bottleneck by design").

  **Conformance ADR-C OBLIGATOIRE CI** (DN D7-bis ligne 338) : ce serveur
  ne doit JAMAIS démarrer côté pod (substrat système-side hors-bwrap). La
  garde lit `:boot_environment` — priorité opts > app env > défaut `:host`
  (défaut sûr ; signal pod exact non spécifié au canon → config-driven non-
  inférentiel, tracé run-journal #MCP1). `:pod` → refus `start_link`.
  """

  @behaviour Fleet.MCP.ServerBehaviour
  use GenServer

  @name __MODULE__

  # --- API publique opaque (4 fonctions, ServerBehaviour) ---

  @impl Fleet.MCP.ServerBehaviour
  @spec start_link(keyword()) :: GenServer.on_start() | {:error, :forbidden_in_pod}
  def start_link(opts \\ []) do
    case boot_environment(opts) do
      :pod -> {:error, :forbidden_in_pod}
      _host -> GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
    end
  end

  @impl Fleet.MCP.ServerBehaviour
  @spec register_channel(String.t(), keyword()) :: :ok | {:error, term()}
  def register_channel(name, opts \\ []) when is_binary(name) do
    register_channel(@name, name, opts)
  end

  @doc "Variante test-seam : cible un serveur explicite (nom/pid)."
  @spec register_channel(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def register_channel(server, name, opts) when is_binary(name) do
    GenServer.call(server, {:register_channel, name, opts})
  end

  @impl Fleet.MCP.ServerBehaviour
  @spec list_channels() :: [String.t()]
  def list_channels, do: list_channels(@name)

  @doc "Variante test-seam : cible un serveur explicite (nom/pid)."
  @spec list_channels(GenServer.server()) :: [String.t()]
  def list_channels(server), do: GenServer.call(server, :list_channels)

  @impl Fleet.MCP.ServerBehaviour
  @spec stop() :: :ok
  def stop, do: stop(@name)

  @doc "Variante test-seam : arrête un serveur explicite (nom/pid)."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    cond do
      is_pid(server) and Process.alive?(server) -> GenServer.stop(server, :normal)
      is_atom(server) and Process.whereis(server) -> GenServer.stop(server, :normal)
      true -> :ok
    end
  end

  @doc """
  Environnement de boot effectif : `opts[:boot_environment]` >
  `Application.get_env(:fleet_mcp, :boot_environment)` > `:host`.
  Exposé pour la conformance CI (test ADR-C).
  """
  @spec boot_environment(keyword()) :: atom()
  def boot_environment(opts \\ []) do
    Keyword.get(opts, :boot_environment) ||
      Application.get_env(:fleet_mcp, :boot_environment, :host)
  end

  # --- GenServer (registration/lifecycle uniquement) ---

  @impl GenServer
  def init(opts) do
    {:ok, %{channels: %{}, opts: opts}}
  end

  @impl GenServer
  def handle_call({:register_channel, name, copts}, _from, %{channels: ch} = state) do
    {:reply, :ok, %{state | channels: Map.put(ch, name, copts)}}
  end

  @impl GenServer
  def handle_call(:list_channels, _from, %{channels: ch} = state) do
    {:reply, Map.keys(ch) |> Enum.sort(), state}
  end
end
