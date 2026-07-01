defmodule Fleet.MCP.Server do
  @moduledoc """
  Garde de boot de `fleet_mcp` : le serveur MCP est système-side, hors bwrap.

  **Invariant de containment** : `fleet_mcp` ne doit JAMAIS démarrer côté pod (le pod
  est CLIENT du serveur, pas son hôte). Ce process, supervisé par `Fleet.MCP.Supervisor`,
  porte la garde : `start_link/1` lit `:boot_environment` (priorité opts > app env >
  défaut `:host`) et refuse (`{:error, :forbidden_in_pod}`) si `:pod` → l'enfant échoue
  → le superviseur échoue → l'app ne boote pas dans un pod. Assertable par un test de
  conformance (`Process.whereis(Fleet.MCP.Server) == nil` côté pod).

  ## Pourquoi ce process existe (et n'est PAS supprimé)

  Son ancienne API `register_channel`/`list_channels` (registre de channels push) est
  **retirée** ici (0 appelant prod ; le push channel est mort — PoC Channel Anthropic
  KO). MAIS la garde de containment ci-dessus est **load-bearing** (testée par la
  conformance) : on retire le husk, on GARDE la garde. Le drive pod-facing
  (`get_work_item`/`submit_result`) vit dans `Fleet.MCP.PodTools`, pas ici.

  **GenServer sans état métier** : le process existe pour être l'enfant
  supervisé dont le `start_link` exécute la garde au boot (idle ensuite).
  """

  use GenServer

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start() | {:error, :forbidden_in_pod}
  def start_link(opts \\ []) do
    case boot_environment(opts) do
      :pod -> {:error, :forbidden_in_pod}
      _host -> GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
    end
  end

  @doc """
  Environnement de boot effectif : `opts[:boot_environment]` >
  `Application.get_env(:fleet_mcp, :boot_environment)` > `:host`.
  Exposé pour le test de conformance « zéro MCP server côté pod ».
  """
  @spec boot_environment(keyword()) :: atom()
  def boot_environment(opts \\ []) do
    Keyword.get(opts, :boot_environment) ||
      Application.get_env(:fleet_mcp, :boot_environment, :host)
  end

  @impl GenServer
  def init(opts), do: {:ok, %{opts: opts}}
end
