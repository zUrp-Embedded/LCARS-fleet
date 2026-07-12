defmodule Fleet.Starfleet.BootOrchestrator do
  @moduledoc """
  Post-readiness orchestrator — a fire-and-forget Task TRIGGERED by `Fleet.Application`
  AFTER the root `Supervisor.start_link` returned `{:ok, _}` (acte4 A-08): "post-readiness"
  is MECHANICAL (the whole fleet — pilot, api listener included — is provably up before the
  first permanent pod spawns; an aborted boot spawns nothing). It is NOT a supervised child:
  `run/1` never exits abnormally (rescue+catch below), and the resurrection rail for permanent
  pods is `PermanentWarden`, not a restart of this Task.

  Simplified architecture spec (Option (b): direct subscribe via supervised
  consumer GenServers in their respective apps):

  1. **Wire consumers** — handled by OTP (AuditConsumer/PublishConsumer
     started via their app's supervision tree, subscribe at `init/1`).
     No explicit action here — this is the "consumer self-subscribe"
     pattern accepted by the architecture.
  2. **boot_permanent_pods** — calls
     `Fleet.Spawner.PermanentBoot.boot_permanent_pods/0`.
  3. **Emits `fleet.boot_complete`** (or `partial`/`failed`) on the Bus
     with payload `{started_apps, permanent_pods, timestamp}`.

  ## Failure modes

  - boot_permanent_pods returns a partial list → emits
    `fleet.boot_partial` with `failed_pods` listed.
  - boot_permanent_pods raises → emits `fleet.boot_failed` with
    `reason`, the daemon stays up (degraded mode).
  - This Task NEVER crashes the daemon: rescue any exception,
    log + signal fleet.boot_failed, exit normally.

  ## Config-gated

    * `:fleet_starfleet, :start_boot_orchestrator` — boolean (default `true`), read by the
      ROOT trigger (`Fleet.Application`, via `Starfleet.Application.boot_enabled?/2`).
      `false` in test (hermetic — no real spawn); tests call `run/1` directly with stubs.
  """

  require Logger
  alias Fleet.EventRouter.Bus

  @doc """
  Orchestration sequence. Spawner backend injectable (test).
  Emits the `fleet.boot_complete|partial|failed` event depending on the outcome.

  Returns `:ok` = "the orchestration Task ran to completion" (it NEVER crashes the daemon — a
  crash would reboot the sequence into a permanent-respawn loop), NOT "the boot succeeded". The
  real outcome lives in the emitted `fleet.boot_*` event (observability only — each outcome is ALSO
  logged info/warning/error by `emit_*` before broadcasting, so a lost event never hides it); the durable
  fact "which permanent pods run" is re-derivable via the spawner registry + reconciled by
  `PermanentWarden`. A caller must NOT read `:ok` as boot success.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    boot_fn =
      Keyword.get(opts, :boot_permanent_pods, fn ->
        Fleet.Spawner.PermanentBoot.boot_permanent_pods()
      end)

    # Canonical gate for booting permanent pods (default true;
    # `LCARS_BOOT_PERMANENT_AT_START=false` disables it). Disabled →
    # we wire the consumers + emit boot_complete, but 0 permanent pod spawned.
    enabled? =
      Keyword.get(opts, :boot_permanent_enabled, Fleet.Spawner.PermanentBoot.auto_boot_enabled?())

    # Z2 collapse 2026-07-12 : the old filter keyed on "fleet_" OTP apps — post-collapse
    # there is ONE app (:lcars_fleet), the filter returned [] forever and the
    # `boot_complete.started_apps` payload silently LIED (empty fleet at every boot).
    # Filter on "lcars" = the honest single-app equivalent (the field was already
    # quasi-constant pre-collapse : the 14 apps were all deps of starfleet).
    started_apps =
      Application.started_applications()
      |> Enum.map(fn {a, _, _} -> a end)
      |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "lcars"))
      |> Enum.sort()

    Logger.info("BootOrchestrator: starting post-readiness sequence (boot_permanent=#{enabled?})")

    boot_result = if enabled?, do: safe_boot(boot_fn), else: {:ok, []}

    # Observability emissions (rescued inside `Bus.safe_emit`, cf. `emit_canon/2`) — returns
    # discarded deliberately: boot does not depend on the broadcast succeeding. A lost event costs
    # Bus visibility only — each outcome is logged by `emit_*` before broadcasting, and the durable
    # fact "which permanent pods run" is re-derived from the spawner registry by `PermanentWarden`.
    _ =
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
            # Vulcan finding: a malformed element (neither :ok nor :error) used to be counted OK
            # (`_ -> true`) → false fleet.boot_complete. Now classed as a failure.
            _ -> false
          end)

        case errs do
          [] -> {:ok, oks}
          _ -> {:partial, oks, errs}
        end

      # (No `{:ok, list}` clause: `PermanentBoot.boot_permanent_pods/0` yields a BARE list of
      # per-pod results or `{:error, _}` — never a wrapped list; such a clause was dead code.)
      {:error, reason} ->
        {:failed, reason}

      other ->
        {:failed, {:unexpected_return, other}}
    end
  rescue
    e -> {:failed, {:exception, Exception.message(e)}}
  catch
    # This is a `:transient` Task → an EXIT/THROW that escaped (a `boot_fn` that GenServer.call's a dead
    # process = exit, or a throw) would exit the Task ABNORMALLY → the supervisor RESTARTS it → a boot
    # reboot LOOP. The "NEVER crashes the daemon" contract must cover exit/throw, not just exceptions.
    kind, reason -> {:failed, {:caught, kind, reason}}
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

  # Canonical schema broadcast %Fleet.Event{source: :starfleet}, via the protected core
  # `Bus.safe_emit/4` (local duplicated rescue removed — the protected-emission policy has ONE
  # authority, Ring 0). `:silent`: this Task emits DURING boot — an UnregisteredError
  # (registry not yet populated) is the nominal case here, not an alarm. A MALFORMED event
  # (construction bug) is logged ERROR by safe_emit then neutralized — otherwise it would mask a
  # boot_failed/boot_partial silently, and this `:transient` Task must NEVER crash (a
  # crash restarts the whole boot sequence, re-spawning the permanent pods, and would loop on a
  # malformed event).
  defp emit_canon(type, payload) do
    Bus.safe_emit(:starfleet, type, [payload: payload],
      on_unregistered: :silent,
      context: "BootOrchestrator: lifecycle event NOT emitted"
    )
  end
end
