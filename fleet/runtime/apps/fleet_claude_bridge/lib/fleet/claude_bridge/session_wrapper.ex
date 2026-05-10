defmodule Fleet.ClaudeBridge.SessionWrapper do
  @moduledoc """
  D5 wrap permissif `Session.new/1` + `Session.send/2`.

  Pas exposer pid `Session` aux pods workers (D4 mitigation consultant
  #381). Surface restreinte = 2 fonctions publiques. Ref opaque
  `%{adapter: :port, opaque: term()}` retournée au lieu du pid brut.

  ## Backend swappable

  Default `Fleet.ClaudeBridge.SessionWrapper.NotWiredYet` retourne
  `{:error, :not_wired_yet}` jusqu'à ce que `:claude_code` SDK soit
  câblé (post-pod 1.18 + chantier 7 `fleet_pod_runtime`). Tests via
  stub backend.
  """

  defmodule Backend do
    @moduledoc """
    Behaviour pour le backend session SDK.
    """

    @callback new(opts :: keyword()) :: {:ok, pid_or_ref :: term()} | {:error, term()}
    @callback send(session_ref :: term(), msg :: term()) :: :ok | {:error, term()}
  end

  @type ref :: %{adapter: :port, opaque: term()}

  @doc """
  Démarre une session SDK (wrappage permissif).

  Returns une `ref` opaque pour les pods workers.
  """
  @spec new(keyword()) :: {:ok, ref()} | {:error, term()}
  def new(opts \\ []) when is_list(opts) do
    case backend().new(opts) do
      {:ok, opaque} -> {:ok, %{adapter: :port, opaque: opaque}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Envoie un message à la session via la ref opaque.
  """
  @spec send(ref(), term()) :: :ok | {:error, term()}
  def send(%{adapter: :port, opaque: opaque}, msg) do
    backend().send(opaque, msg)
  end

  defp backend do
    Application.get_env(
      :fleet_claude_bridge,
      :session_backend,
      Fleet.ClaudeBridge.SessionWrapper.NotWiredYet
    )
  end
end

defmodule Fleet.ClaudeBridge.SessionWrapper.NotWiredYet do
  @moduledoc """
  Backend placeholder. Le wiring SDK réel
  `ClaudeCode.Session.new/1` + `ClaudeCode.Session.send/2` se fait
  post-upgrade pod env Elixir 1.18 + introduction `:claude_code` dep
  (chantier 7 `fleet_pod_runtime` consommateur primaire).
  """

  @behaviour Fleet.ClaudeBridge.SessionWrapper.Backend

  @impl Fleet.ClaudeBridge.SessionWrapper.Backend
  def new(_opts), do: {:error, :not_wired_yet}

  @impl Fleet.ClaudeBridge.SessionWrapper.Backend
  def send(_session_ref, _msg), do: {:error, :not_wired_yet}
end
