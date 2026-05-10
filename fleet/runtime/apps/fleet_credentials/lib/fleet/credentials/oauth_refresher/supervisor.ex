defmodule Fleet.Credentials.OAuthRefresher.Supervisor do
  @moduledoc """
  Supervisor des `Fleet.Credentials.OAuthRefresher` GenServers.

  Stratégie `:one_for_one` avec `max_restarts: 3, max_seconds: 60` :
  3 crashes en 60s sur un même refresher → arrêt définitif → émet
  `auth.refresh_failed.permanent` vers `fleet_starfleet` (Cat 5).

  ## Démarrage des children

  Au boot de l'application, scanne `Fleet.Credentials.creds_root/0`
  et démarre un refresher par sous-répertoire (= 1 par rôle).
  """

  use Supervisor

  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_args) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl Supervisor
  def init(:ok) do
    children = [
      {Registry, keys: :unique, name: Fleet.Credentials.Registry},
      {Registry, keys: :duplicate, name: Fleet.Credentials.PubSub}
      | refresher_children()
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
  end

  @doc """
  Démarre dynamiquement un refresher pour un rôle (utile quand un
  nouveau rôle est bootstrap après le démarrage).
  """
  @spec start_refresher(String.t()) :: Supervisor.on_start_child()
  def start_refresher(role) when is_binary(role) do
    Supervisor.start_child(
      __MODULE__,
      Supervisor.child_spec({Fleet.Credentials.OAuthRefresher, role},
        id: {:refresher, role},
        restart: :permanent
      )
    )
  end

  defp refresher_children do
    if Application.get_env(:fleet_credentials, :auto_start_refreshers, false) do
      Fleet.Credentials.creds_root()
      |> list_roles()
      |> Enum.map(fn role ->
        Supervisor.child_spec({Fleet.Credentials.OAuthRefresher, role},
          id: {:refresher, role},
          restart: :permanent
        )
      end)
    else
      []
    end
  end

  defp list_roles(root) do
    case File.ls(root) do
      {:ok, entries} ->
        Enum.filter(entries, fn entry -> File.dir?(Path.join(root, entry)) end)

      {:error, _} ->
        []
    end
  end
end
