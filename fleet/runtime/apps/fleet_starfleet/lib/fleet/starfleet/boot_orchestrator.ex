defmodule Fleet.Starfleet.BootOrchestrator do
  @moduledoc """
  B10 / #583 Sprint 1 — orchestrateur post-readiness (Task `:transient`).

  Spec arch #583 simplifiée Sprint 1 (Option (b) subscribe direct via
  consumers GenServers supervisés dans leurs apps respectives) :

  1. **Wire consumers** : géré par OTP (AuditConsumer/PublishConsumer
     démarrés via supervision tree de leur app, subscribe au `init/1`).
     Pas d'action explicite ici — c'est le pattern "consumer self-subscribe"
     accepté arch.
  2. **boot_permanent_pods** : appelle
     `Fleet.Spawner.PermanentBoot.boot_permanent_pods/0`. Couvre C2.
  3. **Émet `fleet.boot_complete`** (ou `partial`/`failed`) sur Bus
     avec payload `{started_apps, permanent_pods, timestamp}`.

  ## Failure modes (anti-D2)

  - boot_permanent_pods retourne liste partielle → émet
    `fleet.boot_partial` avec `failed_pods` listés.
  - boot_permanent_pods raise → émet `fleet.boot_failed` avec
    `reason`, daemon reste up (mode degraded).
  - Cette Task ne crash JAMAIS le daemon : rescue any exception,
    log + signal fleet.boot_failed, exit normal.

  ## Config-gated

    * `:fleet_starfleet, :start_boot_orchestrator` — booléen
      (default `true`). Tests passent `false` pour démarrer
      manuellement avec stubs.
  """

  require Logger
  alias Fleet.EventRouter.Bus

  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) do
    Task.start_link(__MODULE__, :run, [opts])
  end

  @doc """
  Sequence d'orchestration. Spawner backend injectable (test).
  Émet event `fleet.boot_complete|partial|failed` selon issue.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    boot_fn =
      Keyword.get(opts, :boot_permanent_pods, fn ->
        Fleet.Spawner.PermanentBoot.boot_permanent_pods()
      end)

    # BL-028 : gate canon du boot des pods permanents (DN lcars-fleet_service §391,
    # défaut true ; `LCARS_BOOT_PERMANENT_AT_START=false` désactive). Désactivé →
    # on wire les consumers + émet boot_complete, mais 0 pod permanent spawné.
    enabled? =
      Keyword.get(opts, :boot_permanent_enabled, Fleet.Spawner.PermanentBoot.auto_boot_enabled?())

    started_apps =
      Application.started_applications()
      |> Enum.map(fn {a, _, _} -> a end)
      |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "fleet_"))
      |> Enum.sort()

    Logger.info(
      "BootOrchestrator: démarrage sequence post-readiness (boot_permanent=#{enabled?})"
    )

    boot_result = if enabled?, do: safe_boot(boot_fn), else: {:ok, []}

    case boot_result do
      {:ok, pods} ->
        emit_complete(started_apps, pods)

      {:partial, pods, failed} ->
        emit_partial(started_apps, pods, failed)

      {:failed, reason} ->
        emit_failed(reason)
    end

    :ok
  end

  # ---------------------------------------------------------------

  defp safe_boot(boot_fn) do
    case boot_fn.() do
      results when is_list(results) ->
        {oks, errs} =
          Enum.split_with(results, fn
            {:ok, _} -> true
            {:error, _} -> false
            # finding Vulcan : un élément malformé (ni :ok ni :error) était compté OK
            # (`_ -> true`) → faux fleet.boot_complete. Désormais classé en échec.
            _ -> false
          end)

        case errs do
          [] -> {:ok, oks}
          _ -> {:partial, oks, errs}
        end

      {:ok, pods} when is_list(pods) ->
        {:ok, pods}

      {:error, reason} ->
        {:failed, reason}

      other ->
        {:failed, {:unexpected_return, other}}
    end
  rescue
    e -> {:failed, {:exception, Exception.message(e)}}
  end

  defp emit_complete(apps, pods) do
    payload = %{
      "started_apps" => Enum.map(apps, &Atom.to_string/1),
      "permanent_pods" => length(pods)
    }

    Logger.info("BootOrchestrator: fleet.boot_complete pods=#{length(pods)}")
    emit_canon(:"fleet.boot_complete", payload)
  end

  defp emit_partial(apps, pods, failed) do
    payload = %{
      "started_apps" => Enum.map(apps, &Atom.to_string/1),
      "permanent_pods" => length(pods),
      "failed_pods" => Enum.map(failed, &inspect/1)
    }

    Logger.warning(
      "BootOrchestrator: fleet.boot_partial pods=#{length(pods)} failed=#{length(failed)}"
    )

    emit_canon(:"fleet.boot_partial", payload)
  end

  defp emit_failed(reason) do
    payload = %{"reason" => inspect(reason)}
    Logger.error("BootOrchestrator: fleet.boot_failed reason=#{inspect(reason)}")
    emit_canon(:"fleet.boot_failed", payload)
  end

  # BL-021 chantier 9 (B) — broadcast schema canon %Fleet.Event{source: :starfleet}.
  defp emit_canon(type, payload) do
    Bus.emit(:starfleet, type, payload: payload)
  rescue
    # UnregisteredError = boot-order toléré : registry pas encore peuplé, broadcast
    # rejeté, pas une alarme — silencieux.
    _e in Fleet.Event.UnregisteredError ->
      :ok

    # ArgumentError/FunctionClauseError = bug de CONSTRUCTION de l'event, PAS du boot.
    # Ne JAMAIS l'avaler en :ok muet : ça masquerait un boot_failed / boot_partial. On le
    # rend VISIBLE puis on neutralise — cette Task :transient ne doit JAMAIS crasher (un
    # crash relance toute la séquence boot, re-spawnant les pods permanents, et bouclerait
    # sur un event malformé).
    e in [ArgumentError, FunctionClauseError] ->
      Logger.error(
        "BootOrchestrator: event lifecycle #{type} NON émis — event malformé (bug de construction) : #{inspect(e)}"
      )

      :ok
  end
end
