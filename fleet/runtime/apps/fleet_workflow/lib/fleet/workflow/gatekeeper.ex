defmodule Fleet.Workflow.Gatekeeper do
  @moduledoc """
  Boot + registration of the **singleton gatekeeper** (the fleet's single judge —
  one always-registered instance, NOT a system "permanent" pod: see the scope below).

  The gatekeeper is a **work-session** pod with scope `lifetime_scope: pipe`
  (cap-profile `gatekeeper.yaml`, `boot_at_start: false`): **bounded to the workflow run**,
  NOT `forever`/always-on. It is NOT booted at fleet startup (unlike the `architect`,
  which IS booted at start), but **on a workflow activation** (dispatched by the forge-driven rail
  when a non-decidable gate enqueues its eval brief),
  and lives for the duration of the work. Being non-`forever`, it arms the response watchdog
  (`:result_deadline`, default 300s for a non-`forever` scope; `Fleet.Spawner.Pod.Liveness`):
  stayed silent past the deadline while a task is expected → it is reclaimed
  (`transition_failed`; pod `:temporary`, no OTP relaunch) — whereas `forever` would never
  arm it. It is addressed via **MCP brief** — the caller that drives it does not
  own it (no supervision link: it is reached by its `pod_id`, not held as a
  child).

  ## Registration

  The gatekeeper's `pod_id` is registered in `:persistent_term` (singleton), read
  by the caller via `pod_id/0`. Config/test override: `:fleet_workflow,
  :gatekeeper_pod_id` (takes priority — gate tests use it without booting).

  ## ⚠ MVP singleton vs per-project target

  The target prescribes **1 gatekeeper per active project**. The runtime does not
  yet have a "project" model → MVP **singleton work-session** (one gatekeeper for
  the whole runtime). Per-project keying + the `project.complete → terminate`
  teardown are deferred **refinements**: they only make sense once the "project"
  model exists.

  ## Autoboot config-gated

  `ensure_booted/1` only boots if `:fleet_workflow, :gatekeeper_autoboot` is
  true (default `true`; `config/test.exs` sets it to `false` for hermeticity —
  workflow tests do not spawn a gatekeeper unless explicitly opted in).
  """

  require Logger

  @pt_key {__MODULE__, :pod_id}
  # Permanent singleton → BARE name by role (`gatekeeper`), no redundant `permanent` qualifier. It does
  # NOT match the PermanentWarden's `permanent-*` prefix — intended: the gatekeeper SELF-manages (boot +
  # `@pt_key` registry + reboot via wake_recovery), outside the generic warden. (The architect, by contrast,
  # IS warden-managed → it keeps `permanent-architect`, the prefix is its warden signal, not decoration.)
  @pod_id "gatekeeper"
  # Context pseudo-issue for the permanent pod (spawn arg distinct from pod_id; not a real issue).
  @issue_id "permanent-gatekeeper"

  @doc """
  `pod_id` of the permanent gatekeeper to address, or `nil` if none is booted.
  Config override (`:gatekeeper_pod_id`) takes priority over the runtime registry.
  """
  @spec pod_id() :: String.t() | nil
  def pod_id do
    Application.get_env(:fleet_workflow, :gatekeeper_pod_id) ||
      :persistent_term.get(@pt_key, nil)
  end

  @doc """
  Ensures a permanent gatekeeper is booted + registered (idempotent). No-op if
  already REGISTERED (the `:persistent_term` singleton or a config override) or if autoboot is disabled.

  ⚠ PRESENCE, not liveness (SOC-OTP-002): `{:ok, pod_id}` proves a pod_id is REGISTERED in
  `:persistent_term`, NOT that the gatekeeper process is ALIVE — a registered-but-DEAD pod no-ops here.
  For a LIVENESS-aware recovery (reap the ghost holder + de-register + re-boot), use `reboot/1` (the
  `respawn_fun` of `Fleet.Pilot.WakeRecovery` when the gatekeeper is unreachable).

  Seams (tests): `:loader` (default `&Fleet.CapProfile.load/1`), `:spawner`
  (default `&Fleet.Spawner.spawn_pod/3`).

  Returns `{:ok, pod_id}` | `{:ok, :disabled}` | `{:error, reason}`.
  """
  @spec ensure_booted(keyword()) :: {:ok, String.t() | :disabled} | {:error, term()}
  def ensure_booted(opts \\ []) when is_list(opts) do
    cond do
      not Application.get_env(:fleet_workflow, :gatekeeper_autoboot, true) ->
        {:ok, :disabled}

      is_binary(pod_id()) ->
        {:ok, pod_id()}

      true ->
        boot(opts)
    end
  end

  @doc """
  Reboot of the permanent gatekeeper: reap the surviving holder (ghost case), de-register, re-boot fresh.
  Serves as the `respawn_fun` for `Fleet.Pilot.WakeRecovery`'s re-roll when the gatekeeper is unreachable
  (`ensure_booted` alone is not enough: presence-based, it no-ops on a registered-but-broken pod).
  Same returns as `ensure_booted/1`.
  """
  @spec reboot(keyword()) :: {:ok, String.t() | :disabled} | {:error, term()}
  def reboot(opts \\ []) when is_list(opts) do
    killer = Keyword.get(opts, :killer, &Fleet.Spawner.PodTmux.kill_holder/1)
    _ = killer.(@pod_id)
    _ = :persistent_term.erase(@pt_key)
    ensure_booted(opts)
  end

  defp boot(opts) do
    loader = Keyword.get(opts, :loader, &Fleet.CapProfile.load/1)
    spawner = Keyword.get(opts, :spawner, &Fleet.Spawner.spawn_pod/3)

    with {:ok, cp} <- loader.("gatekeeper"),
         :ok <- do_spawn(spawner, cp) do
      :persistent_term.put(@pt_key, @pod_id)
      Logger.info("Gatekeeper: permanent booted + registered pod=#{@pod_id}")
      {:ok, @pod_id}
    else
      {:error, reason} = err ->
        Logger.error("Gatekeeper: boot failed: #{inspect(reason)}")
        err
    end
  end

  # `:already_started` = the gatekeeper is already alive (idempotence) → success.
  # NB race: `ensure_booted` is not serialized (called in the caller's process
  # on the gate-dispatch path). Two concurrent activations can pass
  # the `is_binary(pod_id())` check and call `do_spawn` in parallel — the
  # spawner catches up (the 2nd receives `{:already_started, _}` on the stable `@pod_id`)
  # → a single pod spawned, both register the same pod_id. Sound (singleton).
  defp do_spawn(spawner, cp) do
    case spawner.(cp, @issue_id, pod_id: @pod_id) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} = err -> err
    end
  end
end
