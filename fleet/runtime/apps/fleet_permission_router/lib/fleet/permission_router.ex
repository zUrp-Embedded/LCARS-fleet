defmodule Fleet.PermissionRouter do
  @moduledoc """
  Module `can_use_tool` callback decisions (Ring 3 gates sécurité).

  Invoqué par `Fleet.ClaudeBridge.PermissionAdapter` (chantier 8
  PROMOTED, F-ADP-2 mitigation closed) à chaque tool_call déclenché
  par claude -p en cours d'inférence. Couche sécurité irréductible —
  refus par défaut canon LCARS v1 §0 #1.

  ## 5 steps flow (architecture-cible §L559-565 figé)

    1. `Fleet.IpcFilter.filter_tool_call/2` (chantier 9 PROMOTED) —
       deny si REFUSE_PATTERN match
    2. Auto-allow si tool dans `cap_profile.spec.scope.allowedTools`
    3. Auto-deny si tool dans `cap_profile.spec.scope.disallowedTools`
       ou hors scope
    4. Relay user si `cap_profile.spec.invocation.policy == :show` et
       outil ambigu (PubSub broadcast + match ref + receive 30s
       timeout config)
    5. Sinon auto-deny par défaut (canon v1 §0 #1)

  ## Architecture

  GenServer minimaliste state-config (process raison runtime = step 4
  relay async blocant). State `%{relay_timeout_ms, default_action}`.

  Behaviour `Fleet.PermissionRouter.Callback` exposé (vendor-extensible).

  ## Configuration

    * `:fleet_permission_router, :relay_timeout_ms` — timeout step 4
      (default 30_000)
    * `:fleet_permission_router, :default_action` — action step 5
      (default `:deny` — canon, pas réouvrable)
    * `:fleet_permission_router, :relay_backend` — module
      `RelayBackend` (default `RelayBackend.NotWiredYet`, câblage
      chantier 11)
    * `:fleet_permission_router, :audit_log_path` — path log NDJSON
      (default `/var/log/fleet-audit.jsonl`)
  """

  use GenServer

  @behaviour Fleet.PermissionRouter.Callback

  defstruct relay_timeout_ms: 30_000, default_action: :deny

  @type t :: %__MODULE__{
          relay_timeout_ms: non_neg_integer(),
          default_action: :deny | :allow
        }

  @type decision ::
          :allow | {:allow, map()} | {:deny, String.t()} | :ask

  @doc """
  Démarre le routeur (GenServer nommé `__MODULE__`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc """
  `can_use_tool/3` — entrée publique du callback.

  Délègue à la GenServer via `GenServer.call` timeout `:infinity` —
  le timeout effectif (`receive after` step 4 relay) est porté par
  l'état runtime de la GenServer (`state.relay_timeout_ms`). Pas de
  double timeout pour éviter une race entre `GenServer.call` et le
  `receive` interne.
  """
  @spec can_use_tool(String.t(), map(), map()) :: decision()
  @impl Fleet.PermissionRouter.Callback
  def can_use_tool(tool_name, tool_input, context) do
    GenServer.call(__MODULE__, {:can_use_tool, tool_name, tool_input, context}, :infinity)
  end

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      relay_timeout_ms:
        Keyword.get(opts, :relay_timeout_ms) ||
          Application.get_env(:fleet_permission_router, :relay_timeout_ms, 30_000),
      default_action:
        Keyword.get(opts, :default_action) ||
          Application.get_env(:fleet_permission_router, :default_action, :deny)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:can_use_tool, tool_name, tool_input, context}, _from, state) do
    decision = decide(tool_name, tool_input, context, state)
    {:reply, decision, state}
  end

  defp decide(tool_name, tool_input, context, state) do
    tool_call = %{"name" => tool_name, "input" => tool_input}

    case Fleet.IpcFilter.filter_tool_call(tool_call, context) do
      {:deny, reason} ->
        {:deny, reason}

      :allow ->
        allowed = scope(context, "allowedTools")
        disallowed = scope(context, "disallowedTools")
        policy = invocation_policy(context)

        cond do
          tool_name in allowed ->
            :allow

          tool_name in disallowed ->
            {:deny, "tool in disallowedTools"}

          policy == :show ->
            relay_to_user(tool_name, tool_input, context, state)

          true ->
            log_audit(tool_call, context, "default_deny", :info)

            case state.default_action do
              :deny ->
                {:deny, "default deny — tool not in allowedTools and policy != :show"}

              :allow ->
                :allow
            end
        end
    end
  end

  defp scope(context, key) do
    cp = Map.get(context, :cap_profile) || Map.get(context, "cap_profile")
    spec = cp_spec(cp)
    get_in(spec, ["scope", key]) || []
  end

  defp invocation_policy(context) do
    cp = Map.get(context, :cap_profile) || Map.get(context, "cap_profile")
    spec = cp_spec(cp)

    case get_in(spec, ["invocation", "policy"]) do
      "show" -> :show
      :show -> :show
      _ -> :silent
    end
  end

  defp cp_spec(%Fleet.CapProfile{spec: spec}), do: spec
  defp cp_spec(%{spec: spec}), do: spec
  defp cp_spec(%{"spec" => spec}), do: spec
  defp cp_spec(_), do: %{}

  defp relay_to_user(tool_name, tool_input, context, state) do
    ref = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    payload = %{
      ref: ref,
      tool_name: tool_name,
      tool_input: tool_input,
      pod_id: Map.get(context, :pod_id) || Map.get(context, "pod_id"),
      ticket_id: Map.get(context, :ticket_id) || Map.get(context, "ticket_id")
    }

    relay_backend().relay_request(ref, payload)

    receive do
      {:permission_relay_response, %{ref: ^ref, decision: decision}} -> decision
    after
      state.relay_timeout_ms ->
        log_audit(
          %{"name" => tool_name, "input" => tool_input},
          context,
          "relay_timeout",
          :warning
        )

        {:deny, "relay timeout #{state.relay_timeout_ms}ms"}
    end
  end

  defp log_audit(tool_call, context, action, severity) do
    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      pod_id: Map.get(context, :pod_id) || Map.get(context, "pod_id"),
      ticket_id: Map.get(context, :ticket_id) || Map.get(context, "ticket_id"),
      tool_name: tool_call["name"],
      action: action,
      severity: severity,
      source: "fleet_permission_router"
    }

    case File.write(audit_log_path(), Jason.encode!(entry) <> "\n", [:append]) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.error("fleet_permission_router audit log failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp relay_backend do
    Application.get_env(
      :fleet_permission_router,
      :relay_backend,
      Fleet.PermissionRouter.RelayBackend.NotWiredYet
    )
  end

  defp audit_log_path do
    Application.get_env(:fleet_permission_router, :audit_log_path, "/var/log/fleet-audit.jsonl")
  end
end
