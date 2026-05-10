defmodule Fleet.Credentials.OAuthRefresher do
  @moduledoc """
  GenServer scheduler refresh OAuth (PoC-23 pattern, lead time 30min).

  Un GenServer par rôle, supervisé par
  `Fleet.Credentials.OAuthRefresher.Supervisor` (`:permanent`,
  `max_restarts: 3` / `max_seconds: 60`). Lit le coffre au boot via
  `init/1`, programme un `Process.send_after(:refresh, delta)` calculé
  depuis `expiresAt - lead_time`. Sur fire, refresh via SDK backend,
  atomic write coffre, broadcast, reschedule.

  ## Recovery BEAM crash

  Aucun état en mémoire qui ne soit reconstruit depuis le coffre :
  `init/1` lit `oauth_refresh_token` + `oauth_access_token` +
  `oauth_scopes` + `expires_at`, calcule le delta restant, relance le
  timer. Le supervisor `:permanent` redémarre. Si `expiresAt` déjà
  dépassé → refresh immédiat (`send(self(), :refresh)`).

  ## Token définitivement révoqué

  3 tentatives en 60s → supervisor stop, émet
  `auth.refresh_failed.permanent` vers `fleet_starfleet` (Cat 5
  terminal). Évite restart loop infini.

  ## Backend swappable (testabilité + bypass SDK)

  Comme `PlanValidator`, refresh effectif délégué à un backend
  configurable via `:fleet_credentials, :oauth_refresh_backend`.

  ## Atomic write coffre

  Délégué à `Fleet.Credentials.Store.write_atomic_coffre/2` (logique
  partagée avec `Bootstrap.Extractor`). 4 fichiers écrits chacun via
  `tmp + File.rename!/2` POSIX atomic.
  """

  use GenServer

  require Logger

  @lead_time_ms 1_800_000

  defmodule Backend do
    @moduledoc """
    Behaviour SDK refresh OAuth.

    Le backend prend un refresh_token et retourne le nouveau set de
    creds (`accessToken`, `refreshToken`, `expiresAt` ms epoch,
    `scopes`).
    """

    @callback refresh(refresh_token :: String.t()) ::
                {:ok,
                 %{
                   required(String.t()) => any()
                 }}
                | {:error, :unauthorized | term()}
  end

  # ============================================================
  # Public API
  # ============================================================

  @doc """
  Démarre un GenServer refresher pour un rôle donné.

  Invoqué par `Fleet.Credentials.OAuthRefresher.Supervisor` à
  l'application start (1 child per rôle découvert dans le coffre).
  """
  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(role) when is_binary(role) do
    GenServer.start_link(__MODULE__, role, name: name(role))
  end

  @doc """
  Renvoie le nom registry-via du refresher pour un rôle.
  """
  @spec name(String.t()) ::
          {:via, Registry, {Fleet.Credentials.Registry, {:refresher, String.t()}}}
  def name(role) when is_binary(role) do
    {:via, Registry, {Fleet.Credentials.Registry, {:refresher, role}}}
  end

  @doc """
  Force un refresh manuel (test/debug).
  """
  @spec force_refresh(String.t()) :: :ok
  def force_refresh(role) do
    GenServer.cast(name(role), :force_refresh)
  end

  # ============================================================
  # GenServer callbacks
  # ============================================================

  @impl GenServer
  def init(role) do
    case load_state(role) do
      {:ok, state} ->
        {:ok, state, {:continue, :schedule}}

      {:error, reason} ->
        {:stop, {:coffre_load_failed, reason}}
    end
  end

  @impl GenServer
  def handle_continue(:schedule, state) do
    schedule_refresh(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    case backend().refresh(state.refresh_token) do
      {:ok, new_creds} ->
        :ok = Fleet.Credentials.Store.write_atomic_coffre(state.role, new_creds)
        broadcast(state.role, :auth_refreshed)

        new_state = %{
          state
          | refresh_token: new_creds["refreshToken"],
            expires_at: new_creds["expiresAt"]
        }

        schedule_refresh(new_state)
        {:noreply, new_state}

      {:error, :unauthorized} ->
        broadcast(state.role, :auth_refresh_failed)
        {:stop, :auth_refresh_failed, state}

      {:error, reason} ->
        Logger.warning(
          "oauth refresh transient error role=#{state.role} reason=#{inspect(reason)}"
        )

        Process.send_after(self(), :refresh, retry_backoff_ms())
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_cast(:force_refresh, state) do
    send(self(), :refresh)
    {:noreply, state}
  end

  # ============================================================
  # Internals
  # ============================================================

  defp load_state(role) do
    with {:ok, refresh_token} <- read_file(role, "oauth_refresh_token"),
         {:ok, expires_at_raw} <- read_file(role, "expires_at") do
      case Integer.parse(String.trim(expires_at_raw)) do
        {expires_at, _} ->
          {:ok, %{role: role, refresh_token: String.trim(refresh_token), expires_at: expires_at}}

        :error ->
          {:error, {:expires_at_invalid, expires_at_raw}}
      end
    end
  end

  defp read_file(role, file) do
    case File.read(Fleet.Credentials.coffre_path(role, file)) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:coffre_file_unreadable, file, reason}}
    end
  end

  defp schedule_refresh(state) do
    delta_ms = state.expires_at - now_ms() - @lead_time_ms

    if delta_ms > 0 do
      Process.send_after(self(), :refresh, delta_ms)
    else
      send(self(), :refresh)
    end
  end

  defp broadcast(role, event) do
    Registry.dispatch(Fleet.Credentials.PubSub, {:auth, role}, fn entries ->
      for {pid, _} <- entries, do: send(pid, {event, role})
    end)
  end

  defp now_ms, do: :os.system_time(:millisecond)

  defp retry_backoff_ms do
    Application.get_env(:fleet_credentials, :refresh_retry_backoff_ms, 5_000)
  end

  defp backend do
    Application.get_env(
      :fleet_credentials,
      :oauth_refresh_backend,
      Fleet.Credentials.OAuthRefresher.ClaudeCodeBackend
    )
  end
end

defmodule Fleet.Credentials.OAuthRefresher.ClaudeCodeBackend do
  @moduledoc """
  Backend SDK production. Dispatch dynamique via `apply/3` car le
  nom de fonction réel côté SDK peut évoluer (PoC-23 documente
  le pattern, pas le binding exact). Caller responsibility :
  configurer `:fleet_credentials, :oauth_refresh_backend` à un
  backend réel quand le binding est tranché (chantier 8
  `fleet_claude_bridge`).

  Default behaviour ici : retourne `{:error, :not_wired_yet}` —
  compile-time safe, runtime fail-fast au premier refresh.
  """

  @behaviour Fleet.Credentials.OAuthRefresher.Backend

  @impl Fleet.Credentials.OAuthRefresher.Backend
  def refresh(_refresh_token) do
    {:error, :not_wired_yet}
  end
end
