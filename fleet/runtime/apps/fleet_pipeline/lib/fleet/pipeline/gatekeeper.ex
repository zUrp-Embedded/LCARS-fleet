defmodule Fleet.Pipeline.Gatekeeper do
  @moduledoc """
  Boot + registration du **gatekeeper permanent** (juge unique, pod Type 3).

  Le gatekeeper est un pod permanent **work-session** (`lifetime_scope: forever`,
  cap-profile `gatekeeper.yaml`, `boot_at_start: false`) : il n'est PAS booté au
  démarrage de la fleet (≠ Type 1 `architect`), mais **à l'activation d'un
  pipeline** (`Fleet.Pipeline.start_pipeline`). Une fois booté, il vit pour la
  durée du travail et est adressé via **mandat MCP** (cf. `Fleet.Pipeline.Executor`,
  qui ne le possède pas). Source : DN `spawn/permanent-pods-boot` Type 3 +
  `orchestration/gatekeeper-exception` + `DEFINITION-pipeline-gatekeeper`.

  ## Registration

  Le `pod_id` du gatekeeper est registré en `:persistent_term` (singleton), lu
  par l'Executor via `pod_id/0`. Override config/test : `:fleet_pipeline,
  :gatekeeper_pod_id` (prioritaire — les tests de gate l'utilisent sans booter).

  ## ⚠ MVP singleton vs canon per-projet

  Le canon (`permanent-pods-boot` Type 3) prescrit **1 gatekeeper par projet
  actif**. Le runtime n'a pas encore de modèle « projet » → MVP **singleton
  work-session** (un gatekeeper pour le runtime). Le keying per-projet + le
  teardown `project.complete → terminate` sont des **raffinements** (gate-build,
  quand le modèle projet existe).

  ## Autoboot config-gated

  `ensure_booted/1` ne boote que si `:fleet_pipeline, :gatekeeper_autoboot` est
  vrai (défaut `true` ; `config/test.exs` le met à `false` pour l'hermétisme —
  les tests pipeline ne spawnent pas de gatekeeper sauf opt-in explicite).
  """

  require Logger

  @pt_key {__MODULE__, :pod_id}
  @pod_id "gatekeeper-permanent"
  @ticket_id "permanent-gatekeeper"

  @doc """
  `pod_id` du gatekeeper permanent à adresser, ou `nil` si aucun n'est booté.
  Override config (`:gatekeeper_pod_id`) prioritaire sur le registry runtime.
  """
  @spec pod_id() :: String.t() | nil
  def pod_id do
    Application.get_env(:fleet_pipeline, :gatekeeper_pod_id) ||
      :persistent_term.get(@pt_key, nil)
  end

  @doc """
  Assure qu'un gatekeeper permanent est booté + registré (idempotent). No-op si
  déjà up (registry ou override config) ou si l'autoboot est désactivé.

  Seams (tests) : `:loader` (défaut `&Fleet.CapProfile.load/1`), `:spawner`
  (défaut `&Fleet.Spawner.spawn_pod/3`).

  Returns `{:ok, pod_id}` | `{:ok, :disabled}` | `{:error, reason}`.
  """
  @spec ensure_booted(keyword()) :: {:ok, String.t() | :disabled} | {:error, term()}
  def ensure_booted(opts \\ []) when is_list(opts) do
    cond do
      not Application.get_env(:fleet_pipeline, :gatekeeper_autoboot, true) ->
        {:ok, :disabled}

      is_binary(pod_id()) ->
        {:ok, pod_id()}

      true ->
        boot(opts)
    end
  end

  @doc """
  Reboot du gatekeeper permanent : reap le holder survivant (cas ghost), dé-registre, re-boote frais.
  Sert de `respawn_fun` au re-roll de `Fleet.Pilot.WakeRecovery` quand le gatekeeper est injoignable
  (#5.2 — `ensure_booted` seul ne suffit pas : présence-based, il no-op sur un pod registré-mais-cassé).
  Mêmes returns que `ensure_booted/1`.
  """
  @spec reboot(keyword()) :: {:ok, String.t() | :disabled} | {:error, term()}
  def reboot(opts \\ []) when is_list(opts) do
    _ = Fleet.Spawner.PodTmux.kill_holder(@pod_id)
    _ = :persistent_term.erase(@pt_key)
    ensure_booted(opts)
  end

  defp boot(opts) do
    loader = Keyword.get(opts, :loader, &Fleet.CapProfile.load/1)
    spawner = Keyword.get(opts, :spawner, &Fleet.Spawner.spawn_pod/3)

    with {:ok, cp} <- loader.("gatekeeper"),
         :ok <- do_spawn(spawner, cp) do
      :persistent_term.put(@pt_key, @pod_id)
      Logger.info("fleet_pipeline gatekeeper permanent booté + registré pod=#{@pod_id}")
      {:ok, @pod_id}
    else
      {:error, reason} = err ->
        Logger.error("fleet_pipeline gatekeeper boot échoué: #{inspect(reason)}")
        err
    end
  end

  # `:already_started` = le gatekeeper est déjà vivant (idempotence) → succès.
  # NB race : `ensure_booted` n'est pas sérialisé (appelé dans le process
  # appelant de `start_pipeline`). Deux activations concurrentes peuvent passer
  # le check `is_binary(pod_id())` et appeler `do_spawn` en parallèle — le
  # spawner rattrape (le 2e reçoit `{:already_started, _}` sur le `@pod_id` stable)
  # → un seul pod spawné, les deux registrent le même pod_id. Sain (singleton).
  defp do_spawn(spawner, cp) do
    case spawner.(cp, @ticket_id, pod_id: @pod_id) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} = err -> err
    end
  end
end
