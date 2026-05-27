defmodule Fleet.Credentials.PlanValidator do
  @moduledoc """
  Validation plan Pro/Max au boot pod (F-AC-VALIDATE).

  Consomme `ClaudeCode.Session.account_info/1` du SDK `guess/claude_code`
  pour vérifier que le compte authentifié dispose d'un plan Claude.ai
  Pro ou Max — refuse fail-fast sinon (raisons économiques LCARS v2).

  ## Bypass discipline SDK #2

  Le SDK-bridge (`fleet_claude_bridge`) a été SUPPRIMÉ (SDK/stream-json
  mort, ADR-G pivot tmux-REPL). `PlanValidator.ClaudeCodeBackend` reste
  un placeholder `:not_wired_yet` = tendril SDK à retriager (le chemin
  SDK `account_info` n'est plus le modèle de lancement).

  ## Backend swappable (testabilité)

  Le module utilise un backend `Fleet.Credentials.PlanValidator.Backend`
  configurable via `:fleet_credentials, :plan_validator_backend`.
  Default : `Fleet.Credentials.PlanValidator.ClaudeCodeBackend` (wrap
  réel SDK). Tests : `Fleet.Credentials.PlanValidator.StubBackend`
  (canned data, pas d'appel réseau).

  ## Exit codes

    * `:ok` — plan dans `["pro", "max"]`
    * `{:error, {:invalid_plan, current}}` — plan ≠ Pro/Max
    * `{:error, {:account_info_failed, reason}}` — appel SDK échoue
  """

  defmodule Backend do
    @moduledoc """
    Behaviour SDK : `account_info/1` renvoie les infos de compte du
    SDK Claude Code (`subscription_type` entre autres).
    """

    @callback account_info(access_token :: String.t()) ::
                {:ok, map()} | {:error, term()}
  end

  @valid_plans ["pro", "max"]

  @doc """
  Valide le plan associé à un access token.

  Délègue au backend configuré. Au runtime → SDK ClaudeCode ; en
  test → stub.
  """
  @spec validate_plan(String.t()) ::
          :ok
          | {:error, {:invalid_plan, String.t()}}
          | {:error, {:account_info_failed, term()}}
  def validate_plan(access_token) when is_binary(access_token) do
    case backend().account_info(access_token) do
      {:ok, %{"subscription_type" => plan}} when plan in @valid_plans ->
        :ok

      {:ok, %{"subscription_type" => other}} ->
        {:error, {:invalid_plan, to_string(other)}}

      {:error, reason} ->
        {:error, {:account_info_failed, reason}}
    end
  end

  defp backend do
    Application.get_env(
      :fleet_credentials,
      :plan_validator_backend,
      Fleet.Credentials.PlanValidator.ClaudeCodeBackend
    )
  end
end

defmodule Fleet.Credentials.PlanValidator.ClaudeCodeBackend do
  @moduledoc """
  Backend SDK production placeholder.

  Le SDK `guess/claude_code` expose `ClaudeCode.Session.account_info/1`
  mais prend un `session()` pid (pas un access_token string brut).
  Le binding réel se fait au chantier 6 (`fleet_spawner`) où la
  Session est démarrée avec les creds résolus, OU chantier 8
  (`fleet_claude_bridge`) si l'on opte pour un wrap SDK uniformisé.

  Default ici : `{:error, :not_wired_yet}` — compile-time safe,
  runtime fail-fast jusqu'à ce que le caller configure
  `:fleet_credentials, :plan_validator_backend` avec un backend
  réel.
  """

  @behaviour Fleet.Credentials.PlanValidator.Backend

  @impl Fleet.Credentials.PlanValidator.Backend
  def account_info(_access_token) do
    {:error, :not_wired_yet}
  end
end
